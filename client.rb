#!/usr/bin/env ruby

require "socket"
require "io/console"

###############################################################################
# Basic IRC socket wrapper. Parses incoming messages, sends out outgoing
# messages as string.

class IRC
	def initialize(addr, port)
		# Save connection data
		@addr = addr
		@port = port
		@callback = nil
		@err = nil
	end

	def on_message(&callback)
		@callback = callback
	end

	def on_error(&callback)
		@err = callback
	end

	def open()
		@buffer = ""
		@socket = TCPSocket.new(@addr, @port)
		listen()
	end

	def listen()
		Thread.new do
			while @socket do
				begin
					IO.select([@socket])
					@buffer += @socket.recv(128)

					# Parse any full messages
					if @callback then
						while (@buffer[/.+\r\n/]) do
							# Get message without packet delimeter
							message = @buffer[/.+\r\n/][0...-2]
							# Execute the callback
							@callback.call(message)
							# Consume the message
							@buffer[/.+\r\n/] = ""
						end
					end
				rescue IO::WaitReadable
					# Read timeout. This is normal, just reschedule
				rescue => ex
					# Everything else is treated as a connection problem
					@err.call(ex) if @err
					close()
				end
			end
		end
	end

	def send(msg)
		if @socket then
			@socket.send(msg + "\r\n", 0)
		end
	end

	def close()
		if @socket then
			@socket.close()
			@socket = nil
		end
	end

	def is_open?
		@socket != nil
	end
end

################################################################################
# Event loop

class EventLoop
	def initialize()
		# Create control pipe.
		@control_read, @control_write = IO.pipe

		# Control signal handler.
		control = lambda {
			loop do
				begin
					signal = @control_read.read_nonblock(1)

					case signal
					when "1"
						@running = false # Stop running.
					end
				rescue
					break
				end
			end
		}

		# Add control fd as default signal.
		@fds = { @control_read => control }
	end

	def add(fd, job)
		@fds[fd] = job
		if @running == true then
			@control_write.write("2")
		end
	end

	def remove(fd)
		fds[fd] = nil
		if @running == true then
			@control_write.write("2")
		end
	end

	def run()
		@running = true

		# Event loop. Wait for any read fds to become active, then execute the
		# associated job and consume the data from fd.
		while @running do
			rs = IO.select(@fds.keys)

			if r = rs[0] then
				if r != nil && r.length > 0 then
					# Find the job associated with fd.
					job = @fds[r[0]]
					if job then
						job.call()
					end

					# Consume any data left.
					begin
						r[0].read_nonblock(1)
					rescue IO::WaitReadable
						# Do nothing
					rescue => ex
						puts "Unexpected error: #{ex.class} \"#{ex.message}\""
						break
					end
				end
			end
		end
	end

	def stop()
		@control_write.write("1")
	end
end

################################################################################
# IRC client wrapper. Strict interface for sending and receiving messages

class Message
  def initialize(prefix, command, params = [], is_emote = false, tags = {})
    @prefix = prefix
    @command = command
    @params = params
    @is_emote = is_emote
    @tags = tags
  end

	def self.from_string(msg)
		tmp = msg.dup
		is_emote = false
		prefix = ""
		command = ""
		params = []
    tags = {}

		# IRC message format: [@tags] [:prefix] command [params] [:last_param]
    # For emotes, message is usually wrapped in ^A control bytes.
    # TODO: Rewrite with a regexp maybe.

    # Check for tags
    if tmp[0] == "@" then
      begin
        tags_string = tmp[1...tmp.index(" ")]
        tags = tags_string.split(";").map { |tag| tag.split("=") }.to_h
      rescue ArgumentError
        tags = {}
      ensure
        tmp[0..tmp.index(" ")] = ""
      end
    end

		# Check for prefix
		if tmp[0] == ":" then
			prefix = tmp[/:[^ ]+/][1..-1]
			tmp[/:[^ ]+ /] = ""
		end

		# Check for emotes. Emotes are DCC protocl extension, they have a special
		# format of "^AACTION action text^A".
		if tmp[0] == "\001" && tmp[-1] == "\001" then
			tmp = tmp[1, tmp.length - 2]
			if tmp[/\AACTION/] then
				tmp[/\AACTION /] = ""
				return Message.new(nil, "ACTION", tmp, true)
			end
		end

		# Get command. Command is non-optional.
		if tmp.index(" ") then
			command = tmp[/\A[^ ]+/]
			tmp[/\A[^ ]+ /] = ""
		else
			command = tmp
			tmp = ""
		end

		# Get params, if any.
		while tmp.index(" ") != nil && tmp[0] != ":" do
			params << tmp[0, tmp.index(" ")]
			tmp[0..tmp.index(" ")] = ""
		end

		# Get last param.
		if tmp.length > 0 then
			if tmp[0] == ":" then
				params << tmp[1..-1]
			else
				params << tmp
			end
		end

		return Message.new(prefix, command, params, is_emote)
	end

	# Getters

	def prefix
		@prefix
	end

	def command
		@command
	end

	def params
		@params
	end

	def is_emote?
		@is_emote
	end

  def tags
    @tags
  end
end

class Client
	def initialize(host, port, user, pass)
		@host = host
		@port = port
		@user = user
		@pass = pass
		@state = :closed
		@queue = Queue.new
		@read_fd, @write_fd = IO.pipe
	end

	def state
		return @state
	end

	def next
		if !@queue.empty? then
			return @queue.pop
		else
			return nil
		end
	end

	def empty?
		return @queue.empty?
	end

	def fd
		return @read_fd
	end

	def connect
		if @state != :closed then
			return false
		end

		@state = :connecting
		begin
			@irc = IRC.new(@host, @port)
			@irc.on_message { |msg| handle_message(msg) }
			@irc.on_error { |err| handle_error(err) }
			@irc.open()
		rescue
			@state = :closed
		end
	end

	def disconnect
		if @state == :closed || @irc.is_open? == false then
			return
		end

		# Close connection, reset state.
		@irc.close()
		@state = :closed
	end

	def send(msg)
		if @state != :connected then
			return
		end

		@irc.send(msg)
	end

	def handle_message(msg)
		parsed = Message.from_string(msg)

		# Handle message if it's an internal logic.
		if parsed.command == "PING" then
      @irc.send("PONG :#{parsed.params[0]}")
			return
		else
      if @state == :connecting then
        @state = :registering
        # Registration
        @irc.send("PASS #{@pass}") if @pass
        @irc.send("NICK #{@user}")
        @irc.send("USER #{@user} 0 * :#{@user}")
      elsif @state == :registering && parsed.command == "001" then
				@state = :connected
			end
		end

		# Add message to queue and signal the event loop
		@queue << parsed
		@write_fd.write("1")
	end

	def handle_error(err)
		puts err
		# TODO
	end
end

################################################################################
# App logic.

###########
# Testing #
###########

# Setup - enable raw mode
STDIN.raw!
# Setup - create IRC client
client = Client.new("irc.rizon.net", 6667, "aint", nil)

# Setup event loop
ev = EventLoop.new()

# Echo, but exit on "q"
buffer = ""
handle = lambda {
	char = STDIN.read(1)

	case char
	when "q"
    client.disconnect()
		ev.stop()
  when "\r"
    puts "\r\n*** sending command '#{buffer}'\r\n"
    client.send(buffer)
    buffer = ""
	else
    print char
    buffer += char
	end
}
ev.add(STDIN, handle)

# IRC
handle_message = lambda {
	while client.empty? == false do
		msg = client.next
		puts "#{msg.prefix} :: #{msg.command} :: #{msg.params}\r\n"
	end
}
ev.add(client.fd, handle_message)
client.connect()

# Enter the loop
ev.run()
