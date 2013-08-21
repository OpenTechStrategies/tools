#!/usr/bin/python2.7
# Copyright (C) 2013 Aran Dunkley
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
import os
import sys
import re
import ConfigParser
import smtplib

# Get dir containing the code (must be the home dir of the user running the scripts and receiving the mails)
path = os.path.dirname(os.path.dirname(__file__))

# Import modules from bmwrapper (expected to be in the same dir as bm-imap)
sys.path.append( path + '/bmwrapper' )
from bminterface import *
from incoming import *

# Get the mappings of email addresses to Bitmessage addresses
config = ConfigParser.SafeConfigParser()
config.read(os.path.dirname(__file__) + '/.config')
gateway = config.get('settings','gateway')
emails = dict(config.items('addresses'))

# Loop through the Bitmessage messages
msgCount = bminterface.listMsgs()
print "%i messages to parse" % (msgCount)
for msgID in range(msgCount):
	print "Parsing message %i" % (msgID+1)

	# Get the Bitmessage message
	dateTime, toAddress, fromAddress, subject, body = bminterface.get(msgID)

	# Get the To and From raw Bitmessage addresses
	toBM = re.match(r'^(.+)@', toAddress).group(1)
	fromBM = re.match(r'^(.+)@', fromAddress).group(1)

	# Find the user in the list that has the matching Bitmessage address, or use first user if none match
	toAddress = emails.keys()[emails.values().index(toBM if toBM in emails.values() else 0)]

	# Format the email addresses to use the Bitmessage address as the friendly name and compose the message
	toAddress = toBM + ' <' + toAddress + '>'
	fromAddress = fromBM + ' <' + gateway + '>'
	msg = makeEmail(dateTime, toAddress, fromAddress, subject, body)

	# Add a reply-to field so that replies come back to the gateway, but the To field uses the @bm.addr format
	msg = re.sub('^(From:.+?)$', '\1\nReply-To: ' + toBM + ' <' + gateway + '>', msg, re.MULTILINE)

	# Send the message to the local address
	try:
		smtpObj = smtplib.SMTP('localhost')
		smtpObj.sendmail(fromAddress, toAddress, msg)
		print 'Successfully forwarded to ' + toAddress
		bminterface.markForDelete(msgID)
	except SMTPException:
		print 'Error: unable to forward to ' + toAddress

bminterface.cleanup()



