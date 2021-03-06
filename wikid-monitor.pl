#!/usr/bin/perl
#
# wikid-monitor.pl - A cronjob for notifying about problems with the local wiki daemon (wikid.pl)
#
# - See http://www.organicdesign.co.nz/wikid
#
#
# Copyright (C) 2011 Aran Dunkley and others.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
# http://www.gnu.org/copyleft/gpl.html
#
$wikid = "/var/www/tools/wikid";
require( "$wikid.conf" );
$pidfile = "$wikid.pid";
$errfile = "$wikid.err";

if( $ps = qx( ps ax | grep "wikid ($name)" | grep -v grep ) ) {

	if( $ps =~ /^(\d+)/ ) {
		open FH,'>', $pidfile;
		print FH $1;
		close FH;
	}

} else {

	if( -e $pidfile ) {
		$subject = "$name has stopped running!";
		$err = "The wiki daemon ($name) running on $domain has stopped! following is the last ten lines of the log:\n\n";
		$err .= qx( tail -n 10 $wikid.log );
		open FH,'>', $errfile;
		print FH $err;
		close FH;
		qx( mail -s "$subject" aran\@organicdesign.co.nz < $errfile );
		qx( rm -f $errfile );
		qx( rm -f $pidfile );
	}

}
