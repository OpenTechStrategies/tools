import json
import datetime
import time
import email.utils
import re
import inspect

class Message(object):
	"""
	Class representing a Bitmessage message
	"""
	date     = None
	toAddr   = None
	fromAddr = None
	subject  = None
	body     = None

	# This is set if the body content should be encrypted when sent
	passwd = None

	# This is set by syb-classes if data cannot be decoded, or it's found to be invalid
	invalid = False

	"""
	Determine the correct class for the message and instantiate it
	"""
	def __new__(self, msg):
		if self.__class__.__name__ == 'Message':

			# Determine what class it should be
			cls = Message.getClass(msg)
			if cls.__class__.__name__ != 'Message':

				# Change the Message class an instance of the returned class
				self = cls(msg)

				# If the instance has determined it's not a valid message of it's type, return None
				if bgmsg.invalid: return None

		return object.__new__(self, msg)

	"""
	Initialise the Bitmessage message containing all the message attributes and data
	"""
	def __init__(self, msg):
		self.date = email.utils.formatdate(time.mktime(datetime.datetime.fromtimestamp(float(msg['receivedTime'])).timetuple()))
		self.toAddr = msg['toAddress']
		self.fromAddr = msg['fromAddress']
		self.subject = msg['subject'].decode('base64')
		self.body = msg['message'].decode('base64')
		return None

	"""
	Check if the passed BM-message is one of ours and if so what Message sub-class it is
	- returns a class that can be used for instatiation, e.g. bg_msg = getMessageClass(bm_msg)(bm_msg)
	"""
	@staticmethod
	def getClass(msg):
		subject = msg['subject'].decode('base64')
		match = re.match(app.name + "-([0-9.]+):(\w+) ", subject)
		if match:
			c = match.group(2)
			if c in globals():
				if Message in inspect.getmro(globals()[c]): return globals()[c]
			print "Class '" + c + "' is not a Message sub-class"
		return Message

	"""
	Set the current message's class in the subject line for the recipient
	"""
	def setClass(self, cls):
		self.subject = app.title + ': ' + cls + ' ' + app.msg('bg-msg-subject')

	"""
	Send the message
	"""
	def send(self):
		if 'bm' in app.state and app.state['bm'] is BM_CONNECTED:
			subject = self.subject.encode('base64')
			body = self.body.encode('base64')
			if self.toAddr: app.api.sendMessage(self.toAddr, self.fromAddr, subject, body)
			else: app.api.sendBroadcast(self.fromAddr, subject, body)
		else: print "Not sending " + (self.__class__.__name__) + " message to " + self.group.name + ", Bitmessage not running"

	"""
	Reply to the messge
	"""
	def reply(self): pass

	"""
	Read the messages from Bitmessage and update the passed local mailbox with Message instances of the correct sub-class
	TODO: this just reads all messages and replaces all in the local box, it should update not replace
	"""
	@staticmethod
	def getMessages(mailbox):
		if mailbox is None:
			if 'bm' in app.state and app.state['bm'] is BM_CONNECTED:
				messages = json.loads(app.api.getAllInboxMessages())
				mailbox = []
				for msgID in range(len(messages['inboxMessages'])):
					mailbox.append(Message(messages['inboxMessages'][msgID]))
				print str(len(mailbox)) + ' messages retrieved.'
			else: print "Not getting messages, Bitmessage not running"


class BitgroupMessage(Message):
	"""
	An "abstract" class representing a Bitgroup message that extends the basic Bitmessage message to exhibit properties
	- determines if its incoming or outgoing
	- adds the group instance that its broadcast to
	- encodes and encrypts the data for outgoing messages
	- decodes and decrypts the data for incoming messages
	"""

	# The decoded data of the message content
	data = None

	# The group the message is to
	group = None

	# Whether the message is incoming or outgoing
	incoming = False
	outgoing = False

	def __init__(self, param):

		# It's an outgoing message, set up the new message to broadcast an encrypted message to the group
		if param.__class__.__name__ == 'Group':
			self.outgoing = True
			self.group = param
			self.passwd = param.passwd
			self.fromAddr = param.prvaddr
			self.toAddr = None
			self.setClass(self.__class__.__name__)

		# Message is incoming
		else:
			self.incoming = True

			# Only instantiate base-class and decode the body if it's an incoming message
			Message.__init__(self, param)

			# Set the message's group instance from the To address
			for g in app.groups:
				if g.prvaddr == self.toAddr:
					self.group = Group(self.toAddr)

			# Bail if we don't have an instance for this group
			# - this could only happen if we're subscribed to a group's private address that we're not a member of
			if self.group is None:
				print "Message received for a group we're not a member of!"
				# TODO: should unsubscribe from this group's private address
				self.invalid = True
				return None

			# Decode the body data (try as plain unencrypted if decrypting fails)
			try: self.data = json.loads(app.decrypt(self.body, self.group.passwd))
			except:
				try: self.data = json.loads(self.body)
				except:
					print "No valid data found (or couldn't decrypt it) in message content!"
					self.invalid = True
					return None

		return None

	"""
	The send message method first encodes the data into the body before calling the base-class's send method
	"""
	def send(self):

		# Set the body to the JSON encoded data
		self.body = json.dumps(self.data)

		# Encrypt it if the passwd is set - by default it will have been set
		if self.passwd: self.body = app.encrypt(self.body, self.passwd)

		# Call the parent class's send method
		Message.send(self)


class Invitation(BitgroupMessage):
	"""
	Handles the Bitgroup invitation workflow
	"""
	def __init__(self, param):
		BitgroupMessage.__init__(self, param)
		return None

	def accept(self): pass


class Post(BitgroupMessage):
	"""
	General informational post to the group
	"""
	def __init__(self, param, subject, body):
		BitgroupMessage.__init__(self, param)

		# TODO: Incoming post
		if self.incoming:
			pass

		# Outgoing post, put the subject and body into the data
		else:
			self.data = {
				'subject': subject,
				'body': body
			}

		return None


class Changes(BitgroupMessage):
	"""
	Handles the group data synchronisation for offline users
	"""
	group = None
	lastSync = 0

	def __init__(self, param, ts = None):
		BitgroupMessage.__init__(self, param)

		# TODO: Incoming changes
		if self.incoming:
			pass

		# Outgoing, set the message up as a broadcast to the members
		else:

			# Get the changes since the last changes for this group were sent (or since passed timestamp)
			if ts is None:
				ts = self.lastSync
				self.lastSync = app.timestamp()
			self.data = self.group.changes(ts)

		return None


class Presence(BitgroupMessage):
	"""
	TODO: Broadcasts presence information for updating members online status
	"""

	def __init__(self, param):
		BitgroupMessage.__init__(self, param)
		
		# Incoming presence message from a newly connected peer
		if self.incoming: self.group.addPeer(data)

		# Outgoing presence message, add our data to the message
		else:
			data = {
				'peer': app.peer,
				'user': app.user.info(),
				'ip': app.ip,
				'port': app.server.port,
				'last': 0 # timestamp of last data
			}

		return None
