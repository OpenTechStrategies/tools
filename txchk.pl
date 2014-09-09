#!/usr/bin/perl
#
# A script to be called on crontab to notify users when they receive bitcoin transactions
#
use HTTP::Request;
use LWP::UserAgent;
use Cwd qw(realpath);

# Set up a client for making HTTP requests and don't bother verifying SSL certs
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;
$ua = LWP::UserAgent->new();

# Change to the directory the code's in
chdir $1 if realpath($0) =~ m|^(.+)/|;

# Sub to format numbers as 2dp with commas
sub dollar {
	my $x = (shift) + 0.0001;
	$x =~ s/^(.+?\...).+/$1/;
	$x =~ s/(\d)(?=\d\d\d\.)/$1,/;
	$x =~ s/(\d)(?=\d\d\d,)/$1,/;
	return $x;
}

# Get the current bitcoin price from blockchain.info
$src = $ua->get( "http://blockchain.info/ticker" )->content;
$btc = $src =~ /USD.+?15m.+?([0-9.]{3,})/ ? $1 : 'ERROR';

# Load the last balance data
%hist = ();
if(-e "txchk.hist") {
	open FH, '<', "txchk.hist";
	while(<FH>) { $hist{$1} = $2 if /^(.+) (\S+)$/ }
	close FH;
}

# Loop through each line in the config
$changed = 0;
open FH, '<', "txchk.conf";
while(<FH>) {

	# If the line has a bitcoin and email address,
	if( /^\s*(.+)\s+(\S+)\s*$/ ) {

		# Get the info from the config line
		($addr,$email) = ($1,$2);

		# Get the current bitcoin balance for the address from blockchain.info
		$raw = $addr =~ /^(\w+)/ ? $1 : $addr;
		$bal = $ua->get( "https://blockchain.info/q/addressbalance/$raw" )->content / 100000000;

		# If it's more than the last recorded balance,
		if( $bal > $hist{$addr} ) {

			# Get the transaction amount and update the recorded balance
			$tx = $bal - $hist{$addr};
			$hist{$addr} = $bal;
			$txd = dollar( $tx * $btc );
			$tx =~ s/(\d{8})\d+/$1/;		

			# Compose a message
			$msg = "You received $tx BTC (\$$txd) to address $addr\n\nThe current bitcoin price is \$" . dollar($btc) . " USD";

			# Send the info to the email address
			$tmp = "/tmp/mail.txt";
			open MSG,'>', $tmp;
			print MSG $msg;
			close MSG;
			$email =~ s/@/\\@/;
			qx( mail -s "You received $tx BTC" $email < $tmp );
			qx( rm -f $tmp );

			$changed = 1;
		}

		# If the balance has got less, update the recorded balance
		elsif( $bal < $hist{$addr} ) {
			$hist{$addr} = $bal;
			$changed = 1;
		}
	}
}
close FH;

# Update the historical data if any's changed
if($changed) {
	open FH, '>', "txchk.hist";
	print FH "$_ $hist{$_}\n" for keys %hist;
	close FH;
}