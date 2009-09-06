#!/usr/bin/perl
#
# wikid.pl - Organic Design Wiki Daemon
#
# - Version 2.00 started on 2007-04-26
# - Version 3.00 started on 2009-04-29
#
# - See http://www.organicdesign.co.nz/Talk:Wikid.pl
#
# - copyright © 2007 Aran Dunkley
# - license GNU General Public Licence 2.0 or later
#
use POSIX qw(strftime setsid);
use FindBin qw($Bin);
use HTTP::Request;
use LWP::UserAgent;
use Expect;
use Net::SCP::Expect;
use Net::XMPP;
use IO::Socket;
use IO::Select;
use MIME::Base64;
use Sys::Hostname;
use DBI;
use PHP::Serialization qw(serialize unserialize);
require "$Bin/wiki.pl";

# Daemon parameters
$::daemon   = 'wikid';
$::host     = uc( hostname );
$::name     = hostname;
$::port     = 1729;
$::ver      = '3.6.1'; # 2009-09-07
$::dir      = $Bin;
$::log      = "$::dir/$::daemon.log";
$::wkfile   = "$::dir/$::daemon.work";
my $motd    = "Hail Earthlings! $::daemon-$::ver is in the heeeeeouse! (rock)";

# Wiki - try and determine wikidb from wiki's localsettings.php
if ( -e '/var/www/domains/localhost/LocalSettings.php' ) {
	my $ls = readFile( '/var/www/domains/localhost/LocalSettings.php' );
	$::dbname = $1 if $ls =~ /\$wgDBname\s*=\s*['"](.+?)["']/;
	$::dbpre  = $1 if $ls =~ /\$wgDBprefix\s*=\s*['"](.+?)["']/;
	$::short  = $1 if $ls =~ /\$wgShortName\s*=\s*['"](.+?)["']/;
}

# IRC server
$ircserver  = 'irc.organicdesign.co.nz';
$ircport    = 6667;
$ircchannel = '#organicdesign';
$ircpass    = '*****';

# Override default with config file (this is included again at the end so that it can replace event functions)
require "$Bin/$::daemon.conf";
$::dbname = $wgDBname if defined $wgDBname;
$::dbuser = $wgDBuser if defined $wgDBuser;
$::dbpass = $wgDBpassword if defined $wgDBpassword;
$::dbpre  = $wgDBprefix if defined $wgDBprefix;
$::name   = $name if $name;
$::port   = $port if $port;
$wikiuser = $::name unless $wikiuser;
$ircuser  = $::name unless $ircuser;

# Run as a daemon (see daemonise.pl article for more details and references regarding perl daemons)
open STDIN, '/dev/null';
open STDOUT, ">>$::log";
open STDERR, ">>$::log";
defined ( my $pid = fork ) or die "Can't fork: $!";
exit if $pid;
setsid or die "Can't start a new session: $!";
umask 0;
$0 = "$::daemon ($::name)";

# Install the service into init.d and rc2-5.d if --install arg passed
if ( $ARGV[0] eq '--install' ) {
	writeFile( my $target = "/etc/init.d/$::daemon.sh", "#!/bin/sh\n/usr/bin/perl $::dir/$::daemon.pl\n" );
	symlink $target, "/etc/rc$_.d/S99$::daemon" for 2..5;
	chmod 0755, "/etc/init.d/$::daemon.sh";
	logAdd( "$::daemon.sh added to /etc/init.d" );
}

# Remove the named service and exit
if ( $ARGV[0] eq '--remove' ) {
	unlink "/etc/rc$_.d/S99$::daemon" for 2..5;
	unlink "/etc/init.d/$::daemon.sh";
	logAdd( "$::daemon.sh removed from /etc/init.d" );
	exit(0);
}

# Initialise services, current work, logins and connections
serverInitialise();
ircInitialise();
wikiLogin( $wiki, $wikiuser, $wikipass );
if ( $::dbuser ) {
	$::db = DBI->connect( "DBI:mysql:$::dbname", $::dbuser, $::dbpass );
	my $msg = defined $::db ? "Connected '$::dbuser' to DBI:mysql:$::dbname" : "Could not connect '$::dbuser' to '$::dbname': " . DBI->errstr;
	logAdd( $msg );
	logIRC( $msg );
}
%::streams = ();
workInitialise();
logIRC( $motd );

# Initialise watched files list
# TODO: this list should be drawn from shared record index
my @files = ( '/var/log/auth.log', '/var/log/syslog', '/var/log/svn.log' );
my %files = ();
for ( @files ) {
	if ( -e $_ ) {
		my @stat = stat $_;
		$files{$_} = $stat[7];
	}
}


#---------------------------------------------------------------------------------------------------------#
# MAIN SERVER & CRON LOOP
my $i = 0;
while( 1 ) {

	# Check one of the files in the list for size change each iteration
	my $file = $files[ $i = $i < $#files ? $i + 1 : 0 ];
	my @stat = stat $file;
	my $size = $stat[7];
	if ( $size != $files{$file} ) {
		onFileChanged( $file, $files{$file}, $size );
		$files{$file} = $size;
	}

	# Handle current socket connections
	serverHandleConnections();

	# Handle current IRC connections
	ircHandleConnections();

	# Execute a job from the current work
	workExecute();
	
	sleep( 0.1 );

}


#---------------------------------------------------------------------------------------------------------#
# GENERAL SUPPORT FUNCTIONS

# Output a comment to the wiki and IRC channel
sub notify {
	my $comment = shift;
	wikiAppend( $wiki, 'Server log', "\n*" . localtime() . " : $comment", "\n$comment" );
	logIRC( $comment );
}

# Read and return content from passed file
sub readFile {
	my $file = shift;
	if ( open FH, '<', $file ) {
		binmode FH;
		sysread FH, ( my $out ), -s $file;
		close FH;
		return $out;
	}
}

# Write passed content to passed file
sub writeFile {
	my $file = shift;
	if ( open FH,'>', $file ) {
		binmode FH;
		print FH shift;
		close FH;
		return $file;
	}
}

# Read in and execute a snippet
sub declare {
	$::subname = shift;
	if (open FH,'<',$::subname) {
		logAdd("Declaring \"$::subname\"") unless $@;
		binmode FH;
		sysread FH, (my $code), -s $::subname;
		close FH;
		eval $code;
		logAdd("\"$::subname\" failed: $@") if $@;
	}
	else { logAdd("Couldn't declare $::subname!") }
	$::subname = '';
}

# Function for spawning a child to execute a function by name
sub spawn {
	my $subname = shift;
	my $subref = eval '\&$subname';
	$SIG{CHLD} = 'IGNORE';
	if (defined(my $pid = fork)) {
		if ($pid) { logAdd("Spawned child ($pid) for \"$subname\"") }
		else {
			$::subname = $subname;
			$0 = "$::daemon: $::name ($subname)";
			&$subref(@_);
			exit;
		}
	}
	else { logAdd("Cannot fork a child for \"$subname\": $!") }
}

# Function to start an instance of this daemon
sub start {
	qx( "/etc/init.d/$::daemon.sh" );
}


#---------------------------------------------------------------------------------------------------------#
# SERVER FUNCTIONS

# Initialise server listening on our port
sub serverInitialise {
	$::server = new IO::Socket::INET( Listen => 1, LocalPort => $::port, Proto => 'tcp', ReuseAddr => 1 )
		or die "Port $::port in use, exiting.";
	$::select = new IO::Select $::server;
	logAdd( "Listening on port $::port" );
}

# Handle streams from select list needing attention
sub serverHandleConnections {
	for my $handle ( $::select->can_read( 1 ) ) {
		my $stream = fileno $handle;

		# Handle is the server, set up a new stream
		if ( $handle == $::server ) {
			my $newhandle = $::server->accept;
			$stream = fileno $newhandle;
			$::select->add($newhandle);
			$::streams{$stream}{buffer} = '';
			$::streams{$stream}{handle} = $newhandle;
			logAdd( "New connection: Stream$stream", 'main/new' );
		}

		# Handle is an existing stream with data to read
		# NOTE: we should disconnect after certain size limit
		# - Process (and remove) all complete messages from this peer's buffer
		elsif ( sysread $handle, my $input, 10000 ) {
			$::streams{$stream}{buffer} .= $input;
			if ( $::streams{$stream}{buffer} =~ s/^(.*\r?\n\r?\n\x00)//s ) {
				serverProcessMessage( $stream, $_ ) for split /\r?\n\r?\n\x00/, $1;
			}
		}

		# Handle is an existing stream with no more data to read
		else { serverDisconnect( $handle ) }

	}
}

# Close a handle and clean up
sub serverDisconnect {
	my $stream = shift;
	my $handle = $::streams{$stream}{handle};
	return unless defined $handle;
	$::select->remove( $handle );
	delete $::streams{$stream};
	$handle->close();
	logAdd( "Stream$stream disconnected." );
}

# Process an incoming HTTP message
sub serverProcessMessage {
	my ( $stream, $msg ) = @_;
	my $handle = $::streams{$stream}{handle};
	my $headers = '';
	my $http = '200 OK';
	my $respond = 1;
	my $date = strftime "%a, %d %b %Y %H:%M:%S %Z", localtime;
	my $response = 'done';

	# Extract info from the HTTP request
	my ( $title, $ver ) =
		$msg =~ /(GET|POST)\s+(.*?)\s+(HTTP\/[0-9.]+)/s ? ( $2, $3 ) : ( 'default', 'HTTP/1.1' );

	# If request authenticates service it, else return 401
	if ( $ct =~ /^cmd/ ? ( $msg =~ /Authorization: Basic (\w+)/ and decode_base64( $1 ) eq "$::name:$::password" ) : 1 ) {

		# Call event handler for received event if one exists
		if ( $::data = $title =~ /^(.+?)\?(.+)$/s ? $2 : '' ) {
			$title    = $1;
			$::data   = unserialize( $::data );
			$::script = $$::data{'wgScript'};
			$::site   = $$::data{'wgSitename'};
			$::event  = "on$title";
			if ( $::script and defined &$::event ) {
				logAdd( "Processing \"$title\" hook from $::site" );
				&$::event;
			} else { logAdd( "Unknown event \"$title\" received!" ) }
		}

	} else { $http = "401 Authorization Required\r\nWWW-Authenticate: Basic realm=\"private\"" }

	# Send response back to requestor
	if ( $respond ) {
		$headers = "$ver $http\r\nDate: $date\r\nServer: $::daemon::$::name\r\n$headers";
		$headers .= "Content-Type: $ct\r\n";
		$headers .= "Connection: close\r\n";
		$headers .= "Content-Length: " . ( length $response ) . "\r\n";
		print $handle "$headers\r\n$response";
		serverDisconnect( $stream );
	}
}

#---------------------------------------------------------------------------------------------------------#
# IRC FUNCTIONS

sub ircInitialise {
	return unless $::ircserver;

	$::ircsock = IO::Socket::INET->new(
		PeerAddr => $::ircserver,
		PeerPort => $::ircport,
		Proto    => 'tcp'
	) or die "could not connect to the IRC server ($ircserver:$ircport)";

	print $::ircsock "PASS $ircpass\nNICK $ircuser\nUSER $ircuser 0 0 :$::daemon\n";

	while ( <$::ircsock> ) {

		# if the server asks for a ping
		print $::ircsock "PONG :" . ( split( / :/, $_ ) )[1] if /^PING/;

		# end of MOTD section
		if ( / (376|422) / ) {
			print $::ircsock "NICKSERV :identify $ircuser $ircpass\n";
			last;
		}
	}

	# Wait for a few secs and join the channel
	sleep 3;
	print $::ircsock "JOIN $ircchannel\n";

	$::ircselect = new IO::Select $::ircsock;
	logAdd( "$ircuser connected to $ircserver:$ircport" );
}

# Handle streams from select list needing attention
sub ircHandleConnections {
	return unless $::ircserver;
	for my $handle ( $::ircselect->can_read( 1 ) ) {
		my $stream = fileno $handle;
		if ( sysread $handle, my $data, 100 ) {

			# Append the data to the appropriate stream
			$::streams{$stream} = exists( $::streams{$stream} ) ? $::streams{$stream} . $data : $data;

			# Remove and process any complete messages in the stream
			if ( $::streams{$stream} =~ s/^(.*\r?\n)//s ) {
				for ( split /\r?\n/, $1 ) {

					( $command, $text ) = split( / :/, $_ );

					# Respond to pings if any
					if ( $command eq 'PING' ) {
						$text =~ s/[\r\n]//g;
						print $handle "PONG $text\n";
						next;
					}

					# Extract info and tidy
					my( $nick, $type, $chan ) = split( / /, $_ );
					my( $nick, $host ) = split( /!/, $nick );
					$nick =~ s/://;
					$text =~ s/[:\r\n]+//;

					# Process if the line is a message in the channel
					if ( $chan eq $ircchannel ) {
						$ts = localtime();
						$ts = $1 if $ts =~ /(\d\d:\d\d:\d\d)/;
						logAdd( "[IRC/$nick] $text" ) if $ircserver eq '127.0.0.1';

						# Perform an action if it exists
						if ( $text =~ /^($ircuser|$::daemon) (.+)$/i ) {
							$title = ucfirst $2;
							$::action = "do$title";
							if ( defined &$::action ) {
								$msg = "Processing \"$title\" action issued by $nick";
								logIRC( $msg );
								logAdd( $msg );
								&$::action;
							} else {
								$msg = "Unknown action \"$title\" requested!";
								logIRC( $msg );
								logAdd( $msg );
							}
						}
					}
				}
			}
		}

		# Stream closed, try reconnecting
		else {
			logAdd( "Disconnected from $::ircserver:$::ircport" );
			serverDisconnect( $handle );
			sleep 5;
			ircInitialise();
		}
	}
}

# Output a comment into the IRC channel
sub logIRC {
	my $msg = shift;
	print $::ircsock "PRIVMSG $ircchannel :$msg\n" if $::ircsock;
	return $msg;
}



#---------------------------------------------------------------------------------------------------------#
# FILE EVENTS

sub onFileChanged {
	my $file    = shift;
	my $oldsize = shift;
	my $newsize = shift;
	my $text    = '';
	my $msg     = '';
	my @userfilter = ( 'root', 'nobody', 'fit', 'Bender', 'dcs', 'kg-lan', 'od-lan' );

	# Read in difference
	if ( $newsize > $oldsize and open FH, '<', $file ) {
		binmode FH;
		seek FH, $oldsize, 0;
		sysread FH, $text, $newsize - $oldsize;
		close FH;
	}
	
	# User SSH start
	$msg = "$1 shelled in to $::host" if $text =~ /session opened for user ([-_a-z0-9]+) by/ && !grep $_ eq $1, @userfilter;

	# User SSH stop
	$msg = "$1 shelled out of $::host" if $text =~ /session closed for user ([-_a-z0-9]+)/ && !grep $_ eq $1, @userfilter;

	# Su to root
	$msg = "$1 is now root on $::host" if $text =~ /Successful su for root by ([-_a-z0-9]+)/;

	# VPN connection
	$msg = "VPN connection established from $1" if $text =~ /Peer Connection Initiated with ([0-9.]+):/;

	# Unison synchronisation of file changes completed
	$msg = $text if $text =~ /Synchronization complete/;

	# SVN commits
	$msg = $text if $text =~ /repo updated to revision/;

	logIRC( $msg ) if $msg;

}



#---------------------------------------------------------------------------------------------------------#
# WIKI EVENTS
# $::script, $::site, $::event, $::data available

sub onStartJob {
	$::job = $::data;
	workStartJob( $$::job{'type'}, -e $$::job{'id'} ? $$::job{'id'} : undef );
}

sub onStopJob {
	my $id = $$::data{'id'};
	if ( workStopJob( $id ) ) {
		my $msg = "Job $id cancelled";
		logIRC( $msg );
		logAdd( $msg );
	}
}

sub onPauseJobToggle {
	my $id = $$::data{'id'};
	workSetJobFromId( $id );
	$$::job{'paused'} = $$::job{'paused'} ? 0 : 1;
	workSave();
	$msg = "Job $id " . ( $$::job{'paused'} ? '' : 'un' ) . "paused";
	logIRC( $msg );
	logAdd( $msg );
}

sub onUserLoginComplete {
	my $user = $$::data{'args'}[0]{'mName'};
	logIRC( "$user logged in to $::site" ) if $user;
}

sub onPrefsPasswordAudit {
	if ( $$::data{'args'}[2] eq 'success' ) {
		my $user = $$::data{'args'}[0]{'mName'};
		my $pass = $$::data{'args'}[1];
		doUpdateAccount( $user, $pass );
	}
}

sub onAddNewAccount {
	my $user = $$::data{'args'}[0]{'mName'};
	my $pass = $$::data{'REQUEST'}{'wpPassword'};
	doUpdateAccount( $user, $pass ) if $user and $pass;
}

sub onRevisionInsertComplete {
	my %revision = %{$$::data{'args'}[0]};
	return if $revision{'mMinorEdit'};
	my $id      = $revision{'mId'};
	my $page    = $revision{'mPage'};
	my $user    = $revision{'mUserText'};
	my $parent  = $revision{'mParentId'};
	my $comment = $revision{'mComment'};
	my $title   = $$::data{'REQUEST'}{'title'};
	if ( $page and $user ) {
		if ( lc $user ne lc $wikiuser ) {
			my $action = $parent ? 'changed' : 'created';
			my $utitle = $title;
			$title  =~ s/_/ /g;
			$utitle =~ s/ /_/g;
			$comment =~ s/\\("')/$1/g;
			$comment = " ($comment)" if $comment;
			logIRC( "\"$title\" $action by $user$comment" );
		}
	} else { logAdd( "Not processing (page='$page', user='$user', title='$title')" ) }
}


#---------------------------------------------------------------------------------------------------------#
# ACTIONS

# Synchronise the unix system passwords and samba passwords with the wiki users and passwords
# - users must be in the wiki group for their passwd to be valid (updatable by this action)
# - the samba passwords are built from the system passwords
sub doUpdateAccount {
	my $user = lc shift;
	my $pass = shift;
	$user =~ s/ /_/g;

	# if the @users array exists, bail unless user is in it
	return if defined @::users and not grep /$user/i, @::users;

	# If unix account exists, change its password
	if ( -d "/home/$user" ) {
		logIRC( "Updating unix account details for user \"$user\"" );
		my $exp = Expect->spawn( "passwd $user" );
		$exp->expect( 5,
			[ qr/password:/ => sub { my $exp = shift; $exp->send( "$pass\n" ); exp_continue; } ],
			[ qr/password:/ => sub { my $exp = shift; $exp->send( "$pass\n" ); } ],
		);
		$exp->soft_close();
	}

	# Unix account doesn't exist, create now
	else {
		logIRC( "Creating unix account for user \"$user\"" );
		my $exp = Expect->spawn( "adduser $user" );
		$exp->expect( 5,
			[ qr/password:/ => sub { my $exp = shift; $exp->send( "$pass\n" ); exp_continue; } ],
			[ qr/password:/ => sub { my $exp = shift; $exp->send( "$pass\n\n\n\n\n\n" ); exp_continue; } ],
			[ qr/\[\]:/     => sub { my $exp = shift; $exp->send( "\n" ); exp_continue; } ],
			[ qr/\[\]:/     => sub { my $exp = shift; $exp->send( "\n" ); exp_continue; } ],
			[ qr/\[\]:/     => sub { my $exp = shift; $exp->send( "\n" ); exp_continue; } ],
			[ qr/\[\]:/     => sub { my $exp = shift; $exp->send( "\n" ); exp_continue; } ],
			[ qr/\[\]:/     => sub { my $exp = shift; $exp->send( "\n" ); exp_continue; } ],
			[ qr/correct?/  => sub { my $exp = shift; $exp->send( "Y\n" ); } ],
		);
		$exp->soft_close();
	}

	# Update the samba passwd too
	if ( my $exp = Expect->spawn( "smbpasswd -a $user" ) ) {
		logIRC( "Synchronising samba account" );
		$exp->expect( 5,
			[ qr/password:/ => sub { my $exp = shift; $exp->send( "$pass\n" ); exp_continue; } ],
			[ qr/password:/ => sub { my $exp = shift; $exp->send( "$pass\n" ); } ],
		);
		$exp->soft_close();
	}

	# Restart samba
	#logIRC( ":Restarting Samba server..." );
	#$exp = Expect->spawn( "/etc/init.d/samba restart" );
	#$exp->soft_close();
	
	logIRC( "Done." );
}

# Output information about self
sub doInfo {
	logIRC( "I'm a $::daemon version $::ver listening on port $::port." );
	logIRC( "There are currently $n jobs in progress" ) unless ( $n = $#::work ) < 0;
}

# Update and restart
sub doUpdate {
	logIRC( "Updating code-base and tools..." );
	my $result = qx( "cd /var/www/tools && svn update" );
	logIRC( $result );	
	my $exp = Expect->spawn( "/etc/init.d/wikid" );
	$exp->soft_close();
}

# Restart
sub doRestart {
	logIRC( "Restarting..." );
	logAdd( "Closing handles..." );
	serverDisconnect $_ for keys %$::streams;
	logAdd( "Stopping listeners..." );
	$::server->shutdown(2);
	$::ircsock->shutdown(2);
	spawn "start";
	exit(0);
}


#---------------------------------------------------------------------------------------------------------#
# JOBS

# Read in or initialise the persistent work hash
sub workInitialise {
	if ( -e $::wkfile ) {
		workLoad();
	} else {
		@::work = ();
		$::wptr = 0;
		for ( keys %:: ) { push @types, $1 if defined &$_ and /^main(\w+)$/ }
		workSave();
		my $msg = "Work file created with job types " . join ', ', @types;
		logAdd( $msg );
		logIRC( $msg );
	}
}

# Set the global $::job hash from passed job ID
# - returns index of job in work array
sub workSetJobFromId {
	my $id = shift;
	my $i = -1;
	for ( 0 .. $#::work ) {
		if ( $::work[$_]{'id'} eq $id ) {
			$::job = $::work[$_];
			$i = $_;
		}
	}
	if ( $i < 0 ) {
		my $msg = "Job $id not found in work list!";
		logAdd( $msg );
		logIRC( $msg );
	}
	return $i;
}

# Call current jobs "main" then rotates work pointer and saves state if returned success
sub workExecute {

	# Bail if no work items
	return if $#::work < 0;

	# Move work pointer to next item and set $::job
	$::job = $::work[$::wptr%($#::work+1)];

	# Bail if the job is paused
	return if $$::job{'paused'};

	# Bail if the job has no "main" to call
	my $main = 'main' . $$::job{'type'};
	return unless defined &$main;

	# Call the job's "main" and check for success
	if ( &$main == 1 ) {

		# Increment the *global* work pointer
		$::wptr++;

		# Increment the *job* work pointer and stop if finished
		if ( ++$$::job{'wptr'} >= $$::job{'length'} ) {
			my $id = $$::job{'id'};
			my $msg = "Job $id has finished successfully";
			logAdd( $msg );
			logIRC( $msg );
			workStopJob();
		}

		# Write back the changes to the work file
		workSave();

	} else {

		# Log an error and stop the job if its "main" doesn't return success
		my $msg = $main . "() did not return success on iteration " . $$::job{'wptr'};
		workLogError( $msg );
		workStopJob();
		logAdd( $msg );
		logIRC( $msg );
	}
}

# Add a new job to the work queue
# - called with Type, ID (if ID not supplied, a GUID is created)
# - the new job created is $::job
# - returns the job ID
sub workStartJob {
	my $type = shift;
	my $id   = shift || wikiGuid();
	my $init = "init$type";
	my $main = "main$type";

	if ( defined &$main ) {

		# Add the new job to the work hash
		$$::job{'id'}        = $id;
		$$::job{'type'}      = $type;
		$$::job{'user'}      = $::wikiuser;
		$$::job{'start'}     = time();
		$$::job{'finish'}    = 0;
		$$::job{'progress'}  = 0;
		$$::job{'revisions'} = 0;
		$$::job{'length'}    = 0;
		$$::job{'paused'}    = 0;
		$$::job{'status'}    = '';
		$$::job{'errors'}    = '';
		push @::work, $::job;

		# Execute the init if defined
		&$init if defined &$init;

		# Write changes to work file
		workSave();

		my $msg = "$type job started with ID $id";
		logAdd( $msg );
		logIRC( $msg );

	} else {

		# Unkown job type

	}
}

# Remove a job from the work queue (called to cancel and when finished)
# - if no job ID is passed, then the ID of $::job is used
sub workStopJob {
	my $id = shift;
	$id = $$::job{'id'} unless $id;
	my $i = workSetJobFromId( $id );
	return 0 if $i < 0;

	# Execute the job type's stop function if defined
	my $stop = 'stop' . $$::job{'type'};
	&$stop if defined &$stop;

	# Append final job info to log
	$entry = "[$id]\n";
	$entry .= "   Type      : " . $$::job{'type'}      . "\n";
	$entry .= "   User      : " . $$::job{'user'}      . "\n";
	$entry .= "   Start     : " . $$::job{'start'}     . "\n";
	$entry .= "   Finish    : " . time()               . "\n";
	$entry .= "   Progress  : " . $$::job{'progress'}  . "\n";
	$entry .= "   Revisions : " . $$::job{'revisions'} . "\n";
	$entry .= "   Length    : " . $$::job{'length'}    . "\n";
	$entry .= "   Status    : " . $$::job{'status'}    . "\n";
	$entry .= "   Errors    : " . $$::job{'errors'}    . "\n\n";
	open WKLOGH, '>>', "$::wkfile.log" or die "Can't open $::wkfile.log for writing!";
	print WKLOGH $entry;
	close WKLOGH;

	# Remove the item from work list and write changes to work file
	my @tmp = ();
	for ( 0 .. $#::work ) { push @tmp, $::work[$_] if $i ne $_ }
	@::work = @tmp;
	workSave();
	return 1;
}

# Read the contents of the work file into the local work array, work pointer and work types array
sub workLoad {
	my $tmp  = unserialize( readFile( $::wkfile ) );
	@::work  = @{$$tmp[0]};
	$::wptr  = $$tmp[1];
	@::types = @{$$tmp[2]};
}

# Write the work array and pointer to the work file
sub workSave {
	writeFile( $::wkfile, serialize( [ \@::work, $::wptr, \@::types ] ) );
}

# Add a line to a jobs error log
sub workLogError {
	my $err = shift;
	$$::job{'errors'} .= $$::job{'errors'} ? "|$err" : $err;
	return $err;
}


# Include the config again so that it can replace default functions
require "$Bin/$::daemon.conf";
