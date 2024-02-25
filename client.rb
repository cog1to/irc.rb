#!/usr/bin/env ruby

require "socket"
require "io/console"

###############################################################################
# Settings

SYSTEM_USER = "SYSTEM"

Switch = Struct.new(:on, :off) do end
Style = Struct.new(:time, :nick, :text)

SETTINGS = {
	:buffer_size => 1000,
	:history_size => 20,
	:formatting => {
		"\002" => Switch.new("\033[1m", "\033[22m"), # Bold
		"\035" => Switch.new("\033[3m", "\033[23m"), # Italic
		"\037" => Switch.new("\033[4m", "\033[24m"), # Underline
		"\036" => Switch.new("\033[9m", "\033[29m"), # Strikethrough
		"\021" => Switch.new("", "")	# Monospace (not supported)
	},
	:styles => {
		:message => Style.new("\033[90m", "\033[31m", nil),
		:ctcp		 => Style.new("\033[33m", "\033[33m\033[1m", "\033[33m"),
		:dcc		 => Style.new("\033[32m", "\033[32m\033[1m", "\033[32m"),
		:action  => Style.new("\033[90m", "\033[34m\033[1m", "\033[34m"),
		:join		 => Style.new("\033[90m", "\033[35m\033[1m", "\033[35m"),
		:part		 => Style.new("\033[90m", "\033[35m\033[1m", "\033[35m"),
		:kick		 => Style.new("\033[90m", "\033[35m\033[1m", "\033[35m"),
		:ban		 => Style.new("\033[90m", "\033[35m\033[1m", "\033[35m"),
		:system  => Style.new("\033[90m", "\033[0m\033[1m", "\033[1m"),
		:self		 => Style.new("\033[90m", "\033[39;49m\033[1m", nil),
		:mode		 => Style.new("\033[90m", "\033[31m", nil),
		:users		=> Style.new("\033[90m", "\033[31m", "\033[32m"),
	},
}

module Color
	module_function

	# Matching of IRC colors to 16 terminal colors
	def foreground(code)
		case code
		when "1", "01" # Black
			return "30"
		when "2", "02" # Blue
			return "34"
		when "3", "03" # Green
			return "32"
		when "4", "04" # Red
			return "31"
		when "5", "05" # Brown
			return "31"
		when "6", "06" # Magenta
			return "35"
		when "7", "07" # Orange
			return "91"
		when "8", "08" # Yellow
			return "33"
		when "9", "09" # Light green
			return "92"
		when "10"			 # Cyan
			return "36"
		when "11"			 # Light cyan
			return "96"
		when "12"			 # Light blue
			return "94"
		when "13"			 # Pink
			return "95"
		when "14"			 # Grey
			return "90"
		when "15"			 # Light grey
			return "97"
		when "99"			 # Default
			return "0"
		end
	end

	def term(code)
		return Color::foreground(code)
	end

	def esc(code)
		return "\033[" + Color::foreground(code) + "m"
	end
end

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

class Signals
	def initialize()
		@read_fd, @write_fd = IO.pipe
		@queue = Queue.new
	end

	def fd
		return @read_fd
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

	def subscribe()
		Signal.trap("SIGWINCH") do
			@queue << :winch
			@write_fd << "1"
		end

		Signal.trap("INT") do
			@queue << :int
			@write_fd << "1"
		end
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
# Models

class Message
	def initialize(prefix, command, params = [], type = :message, tags = {}, time)
		@prefix = prefix
		@command = command
		@params = params
		@type = type
		@tags = tags
		@time = time
	end

	def self.from_string(msg)
		tmp = msg.dup
		type = :message
		prefix = ""
		command = ""
		params = []
		tags = {}
		time = Time.now

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
			last_param = ""
			if tmp[0] == ":" then
				last_param = tmp[1..-1]
			else
				last_param = tmp
			end

			# Special case for handling "emotes" and CTCP protocol.
			if last_param[0] == "\001" && last_param[-1] == "\001" then
				last_param = last_param[1...-1]
				if last_param[/\AACTION /] then
					type = :action
					last_param = last_param[7..-1]
				elsif last_param[/\ADCC /] then
					type = :dcc
				else
					type = :ctcp
				end
			end

			params << last_param
		end

		return Message.new(prefix, command, params, type, tags, time)
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

	def type
		@type
	end

	def tags
		@tags
	end

	def nick
		if @prefix then
			if @prefix["!"] then
				return @prefix[0, @prefix.index("!")]
			else
				return @prefix
			end
		end

		return ""
	end

	def format(cols, user)
		case @command
		when "PRIVMSG"
			case @type
			when :message
				return format_internal(
					cols,
					@params[1..-1].join(" "),
					user == nick ? SETTINGS[:styles][:self] : SETTINGS[:styles][:message]
				)
			when :ctcp
				return format_internal(
					cols,
					"sent CTCP #{params[1..-1].join(" ")} request",
					SETTINGS[:styles][:ctcp]
				)
			when :action
				return format_internal(cols, params[-1], SETTINGS[:styles][:action])
			end
		when "JOIN"
			return format_internal(
				cols,
				"has joined \002#{params[-1]}\002",
				SETTINGS[:styles][:join]
			)
		when "PART"
			return format_internal(
				cols,
				"has left \002#{params[-1]}\002",
				SETTINGS[:styles][:part]
			)
		when "KICK"
			return format_internal(
				cols,
				"kicked \002#{params[1]}\002 [#{params[2..-1].join(" ")}]",
				SETTINGS[:styles][:kick]
			)
		when "QUIT"
			return format_internal(
				cols,
				"has quit",
				SETTINGS[:styles][:part]
			)
		when "MODE"
			return format_internal(
				cols,
				"set mode #{params[1]} for #{params[0]}",
				SETTINGS[:styles][:mode]
			)
		when "353"
			return format_internal(
				cols,
				"Users: #{params[3..-1].join(", ")}",
				SETTINGS[:styles][:users]
			)
		when "332"
			return format_internal(
				cols,
				"Topic: #{params[2..-1].join(" ")}"
			)
		when "333"
			return format_internal(
				cols,
				"Topic in #{params[1]} set by #{params[2]} at #{Time.at(params[3].to_i)}"
			)
		when "NOTICE", "001", "002", "003", "004", "375", "372", "376"
			return format_internal(cols, @params[1..-1].join(" "))
		when "SYSTEM"
			return format_internal(
				cols,
				@params[0..-1].join(" "),
				SETTINGS[:styles][:system]
			)
		else
			return format_internal(cols, @command + " " + @params.join(" "))
		end
	end

	private

	def format_internal(cols, text, style = SETTINGS[:styles][:message])
		time = "%02d:%02d" % [@time.hour, @time.min]
		visible_text = text
		prefix_length = time.length + 1

		time_style = style.time
		nick_style = style.nick
		text_style = style.text ? style.text : ""

		idx, count, start, last_break = 0, 0, 0, 0
		line = ""; lines = []; escape = ""; format = []
		is_escape = false
		while idx <= visible_text.length do
			if (idx == 0) then
				# First line start with time and sender's nickname.
				line = "#{time_style}#{time}\033[0m #{nick_style}#{nick}\033[0m #{text_style}"
				count += time.length + nick.length + 2
			elsif (count == 0) then
				# Subsequent lines start with padding.
				line = " " * prefix_length + text_style
				count += prefix_length

				# If we got line break while in formatted text, repeat the format.
				if format.length > 0 then
					format.each do |x|
						if x["\003"] then
							line << "\033[#{Color::term(x[1..-1])}m"
						else
							line << SETTINGS[:formatting][x].on
						end
					end
				end
			end

			# If we got to the end of the terminal line, append line to the output.
			if (count == cols || idx == visible_text.length) then
				if idx == visible_text.length || last_break == start then
					last_break = idx
				end

				# Format line from `start` to `last_break`.
				i = start
				while (i < last_break) do
					# Convert formatting and color sequences to terminal escape sequences.
					if (visible_text[i] == "\003") then
						if format.any?{ |s| s["\003"] } then
							index = format.index { |s| s["\003"] }
							format.delete_at(index)
							line << (text_style != "" ? text_style : "\033[39;49m")
							i = i + 1
						else
							escape, i = "\003", i + 1
						end
						next
					end

					if escape.length > 0 then
						if "0123456789"[visible_text[i]] != nil then
							escape += visible_text[i]
							if escape.length == 3 then
								format << escape
								line << "\033[#{Color::term(escape[1..-1])}m"
								escape = ""
							end
							i = i + 1
							next
						else
							format << escape
							line << "\033[#{Color::term(escape[1..-1])}m"
							escape = ""
						end
					end

					if (SETTINGS[:formatting].keys.index(visible_text[i]) != nil) then
						if format.any? { |s| s == visible_text[i] } then
							format -= [visible_text[i]]
							line += SETTINGS[:formatting][visible_text[i]].off
						else
							format << visible_text[i]
							line += SETTINGS[:formatting][visible_text[i]].on
						end
						i += 1
						next
					end

					# Add symbol to the line
					line << visible_text[i]
					i += 1
				end

				# Append formatted line.
				lines << line + "\033[0m"
				# Advance `start` to `last_break`.
				start = last_break
				idx, count = start, 0

				# End of message.
				break if idx == visible_text.length
			elsif visible_text[idx] == "\003" then
				# Skip color sequence.
				if is_escape == false then
					seq, idx = 0, idx + 1
					while ("01234567890".index(visible_text[idx]) != nil && seq < 2) do
						seq, idx = seq + 1, idx + 1
					end
					is_escape = true
				else
					is_escape, idx = false, idx + 1
				end
			elsif ["\002", "\035", "\036", "\037"].index(visible_text[idx]) != nil then
				# Skip formatting.
				idx += 1
			elsif visible_text[idx] == " " then
				# Remember as last word-wrap break.
				idx, count = idx + 1, count + 1
				last_break = idx
			else
				# Normal symbol, just append to the current segment length.
				idx, count = idx + 1, count + 1
			end
		end

		return lines
	end
end


################################################################################
# IRC client wrapper. Strict interface for sending and receiving messages

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

	def on_close=(callback)
		@on_close = callback
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

	def host
		return @host
	end

	def user
		return @user
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
		@state = :closed
		@irc.close()
	end

	def close
		if @state != :connected then
			return
		end

		@state = :closing
		@irc.send("QUIT")
	end

	def send(msg)
		if @state != :connected then
			return
		end

		@irc.send(msg)
	end

	def handle_message(msg)
		parsed = Message.from_string(msg)

		if parsed.command == "ERROR" && state == :closing then
			disconnect()
			@on_close.call()
			return
		elsif parsed.command == "PING" then
			# Ping request, just pong back.
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
		if @state != :closed then
			puts "#{err.class}: #{err}"
		end
			# TODO: Error handling
	end
end

class InputHandler
	def initialize(ev, client)
		@event_loop = ev
		@client = client
		@buffer = ""
		@escape = false
		@escape_buf = ""

		# Add input listener
		ev.add(STDIN, lambda {
			handle_input()
		})
	end

	def on_stop=(callback)
		@on_stop = callback
	end

	def on_control=(callback)
		@on_control = callback
	end

	def on_submit=(callback)
		@on_submit = callback
	end

	def buffer
		@buffer.dup
	end

	def buffer=(str)
		@buffer = str
	end

	def handle_input()
		while true
			begin
				char = STDIN.read_nonblock(1)

				if @escape then
					case char
					when "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ";", "?", "["
						@escape_buf << char
					when "A"
						@on_control.call(:ARROW_UP) if @on_control != nil
						@escape_buf = ""
						@escape = false
					when "B"
						@on_control.call(:ARROW_DOWN) if @on_control != nil
						@escape_buf = ""
						@escape = false
					when "C"
						@escape_buf = ""
						@escape = false
						on_control.call(:ARROW_RIGHT) if @on_control != nil
					when "D"
						@escape_buf = ""
						@escape = false
						@on_control.call(:ARROW_LEFT) if @on_control != nil
					when "E", "F", "G", "H", "J", "K", "S", "T"
						@escape = false
						@escape_buf = ""
					when "f", "m", "i", "n", "h", "l", "s", "u"
						@escape = false
						@escape_buf = ""
					when "~"
						@escape_buf << char
						@escape = false

						# Known sequences:
						if @escape_buf == "[5~" then
							@on_control.call(:PAGE_UP) if @on_control != nil
						elsif @escape_buf == "[6~" then
							@on_control.call(:PAGE_DOWN) if @on_control != nil
						elsif @escape_buf == "[3~"
							# Delete code
							print "\b \b"
							@buffer = @buffer[0...-1]
						end

						@escape_buf = ""
					else
						@escape = false # Unknown or invalid escape sequence
						@escape_buf = ""
					end
				else
					case char
					when "\t"
						@on_control.call(:TAB) if @on_control != nil
					when "\r"
						if @on_submit then
							# Clear line and send to the server.
							print "\033[1K\033[0E"
							value = @buffer.dup
							@buffer = ""
							@on_submit.call(value)
						end
					when 3.chr, 26.chr
						# CTRL-C, CTRL-Z
						if @on_stop != nil then
							@on_stop.call()
						end
					when 127.chr
						# Backspace.
						print "\b \b"
						@buffer = @buffer[0...-1]
					when 27.chr
						# Escape sequence detected.
						@escape = true
					else
						# Echo and add to the buffer.
						print char
						@buffer += char
					end
				end
			rescue
				break
			end
		end
	end
end

################################################################################
# App logic.

class Room
	def initialize(title)
		@title = title
		@messages = []
		@is_read = true
		@is_left = false
	end

	def add(message)
		@messages << message
	end

	def clear()
		@messages = []
	end

	def is_read?
		@is_read
	end

	def is_read=(value)
		@is_read = value
	end

	def is_left?
		@is_left
	end

	def is_left=(value)
		@is_left = value
	end

	def messages
		@messages
	end

	def title
		@title
	end

	def title=(value)
		@title = value
	end
end

class App
	def initialize(client)
		@client = client
		@signals = Signals.new()
		@event_loop = EventLoop.new
		@input = InputHandler.new(@event_loop, client)

		# Add close callback.
		@client.on_close = lambda {
			@event_loop.stop()
		}

		# Add client events.
		@event_loop.add(client.fd, lambda { handle_message })

		# Add signals.
		@event_loop.add(@signals.fd, lambda { handle_signal })

		# Initial state
		@rooms = []
		@buffer = []
		@offset = 0
		@history = []
		@history_offset = 0
		@first_message = true
		size = (`stty size`).split(" ").map { |x| Integer(x) }
		@size = { :lines => size[0], :cols => size[1] }

		# Subscribe to events.
		add_input
		@signals.subscribe()
	end

	def handle_message()
		while @client.empty? == false do
			msg = @client.next

			# TODO handle room messages, i.e. user list, topic, mode, kick
			if (msg.command == "PRIVMSG" || msg.command == "NOTICE") then
				if msg.params[0] == nil then
					abort # Bad format
				else
					# First message on connect will be from the host.
					if @first_message then
						@active_room.title = msg.nick
						@first_message = false
						@dirty = true
					end

					# Room name. Special case for "Global" announcements and "*" messages.
					name = ""
					if msg.nick == "Global" then
						name = @rooms[0].title
					elsif @client.user == msg.params[0] then
						name = msg.nick
					elsif msg.params[0] == "*" then
						name = @rooms[0].title
					else
						name = msg.params[0]
					end

					# Create room if it doesn't exist, otherwise append the message.
					room = nil
					if room = @rooms.find { |x| x.title == name } then
						room.add(msg)
					else
						room = Room.new(name)
						room.add(msg)
						@rooms << room
					end

					if room != @active_room then
						room.is_read = false
					else
						update_buffer(msg)
					end
					@dirty = true
				end
			elsif (
				msg.command == "JOIN" ||
				msg.command == "PART" ||
				msg.command == "MODE" ||
				msg.command == "353"
			) then
				# Room name.
				name = ""
				if ["JOIN", "PART"].any? { |x| x == msg.command } then
					name = msg.params[-1]
				elsif msg.command == "353" then
					name = msg.params[2]
				elsif msg.command == "MODE" then
					if (msg.nick == @client.user) then
						name = @rooms[0].title
					else
						name = msg.params[0]
					end
				end

				# If we've left the room, delete it from the list.
				if (msg.command == "PART" && msg.nick == @client.user) then
					if room = @rooms.find { |x| x.title == name } then
						if @active_room == room then
							change_room(@rooms[[@rooms.index(@active_room) - 1, 0].max])
						end
						@rooms.delete(room)
					end

					clear
					layout_buffer
					@dirty = true
				else
					# Create room if it doesn't exist, otherwise append the message.
					room = nil
					if room = @rooms.find { |x| x.title == name } then
						room.is_left = false
						room.add(msg)
					else
						room = Room.new(name)
						room.add(msg)
						@dirty = true
						@rooms << room
					end

					# Make room active if it's the one we're expecting to join.
					if @expected_room == name then
						change_room(room)
					elsif room == @active_room then
						update_buffer(msg)
					end
				end
			elsif (msg.command == "366") then
				# Ignore
			elsif (msg.command == "KICK") then
				channel, user = msg.params[0], msg.params[1]

				if room = @rooms.find { |x| x.title == channel } then
					room.add(msg)
					if user == @client.user then
						room.is_left = true
					end

					if @active_room != room then
						room.is_read = false
						draw_tabs
					else
						update_buffer(msg)
					end
				end
			elsif (msg.command == "QUIT") then
				if room = @active_room then
					room.add(msg)
					update_buffer(msg)
				end
			else
				if @active_room then
					@active_room.add(msg)
					update_buffer(msg)
				end
			end
		end

		redraw
	end

	def run()
		@client.connect()

		# If we're connected, create a main room.
		@active_room = Room.new(@client.host)
		@rooms << @active_room
		@dirty = true
		redraw

		# Start a runloop.
		@event_loop.run()
	end

	# UI

	def update_buffer(msg)
		if @size == nil then
			return
		end

		lines = msg.format(@size[:cols], @client.user)

		@buffer = @buffer + lines
		if @buffer.length > SETTINGS[:buffer_size] then
			start = @buffer.length - SETTINGS[:buffer_size]
			length = SETTINGS[:buffer_size]
			@buffer = @buffer[start, length]
		end
	end

	def layout_buffer
		if @active_room == nil then
			return
		end
		if @size == nil then
			return
		end

		@buffer.clear
		@active_room.messages.each do |m| update_buffer(m) end
	end

	def redraw
		if @dirty then
			draw_tabs
			draw_room
			draw_input
			@dirty = false
		else
			draw_room
			draw_input
		end
	end

	def draw_tabs
		if @size == nil then
			return
		end

		# Go to first line, toggle green background
		printf("\033[1;1H\033[30;42m")

		length = 0
		@rooms.each do |room|
			room_str = "#{room.title}"
			if (room == @active_room) then
				room_str = "\033[1m#{room_str}\033[22m"
			end
			room_str += (room.is_read? ? " " : "*") + " "
			print room_str[0, [room_str.length, @size[:cols] - length].min]
			length += (room.title.length + 2)

			break if length >= @size[:cols]
		end

		# Fill the rest of the line
		print " " * [@size[:cols] - length, 0].max

		# Reset text settings
		printf("\033[0m")
	end

	def draw_room
		if @active_room == nil then
			return
		end
		if @size == nil then
			return
		end

		# Fill the viewport with lines from buffer.
		(0...@size[:lines] - 2).each { |i|
			print "\033[#{2 + i};1H"
			if i < (@buffer.length - @offset) then
				if ((@buffer.length - @offset) < (@size[:lines] - 2)) then
					print @buffer[i]
				else
					print @buffer[(@buffer.length - @offset - @size[:lines] + 2) + i]
				end
			end
			print "\033[0K"
		}
	end

	def draw_input
		if @size == nil then
			return
		end

		content = @history_offset < 0 ? @history[@history_offset] : @input.buffer
		print("\033[#{@size[:lines]};1H#{content}\033[0K")
	end

	# Sending

	def parse_and_send(text)
		if text[0] == "/" then
			if text == "/join" || text[/\A\/join /] then
				channels_and_keys = text.split(" ")[1..-1]
				if channels_and_keys.length > 0 then
					# Remember first channel in the list, we'll switch to it on join.
					if first_channel = channels_and_keys[0].split(",")[0] then
						@expected_room = first_channel
					end
					@client.send("JOIN #{channels_and_keys.join(" ")}")
				elsif @active_room != nil && @active_room.title[0] == "#" && @active_room.is_left? then
					@client.send("JOIN #{@active_room.title}")
				end
			elsif text == "/part" || text == "/q" then
				if @active_room.is_left? then
					# If we're already kicked, close the tab.
					index = [@rooms.index(@active_room) - 1, 0].max
					@rooms.delete(@active_room)
					change_room(@rooms[index])
					redraw
				elsif @active_room.title[0] == "#" then
					@client.send("PART #{@active_room.title}")
				elsif room = @active_room then
					# Close and delete current room.
					if room != @rooms[0] then
						index = [@rooms.index(@active_room) - 1, 0].max
						@rooms.delete(room)
						change_room(@rooms[index])
						redraw
					end
				end
			elsif text[/\A\/msg /] then
				params = text.split(" ", 3)
				user, message_text = params[1], params[2]

				# Find or create room.
				room = @rooms.find { |x| x.title == user }
				if room == nil then
					room = Room.new(user)
					@rooms << room
				end

				if message_text then
					# Echo message and send to client.
					message = Message.new(
						@client.user,
						"PRIVMSG",
						[user, message_text],
						:message,
						{},
						Time.now
					)
					room.add(message)
					update_buffer(message)
					@client.send("PRIVMSG #{user} :#{message_text}")
				end

				# Update buffer.
				change_room(room)
				redraw
			elsif text[/\A\/me /] then
				if @active_room == nil then
					return
				end

				text[/\A\/me /] = ""
				message = Message.new(@client.user, "PRIVMSG", [text], :action, {}, Time.now)
				@client.send("PRIVMSG #{@active_room.title} :\001ACTION #{text}\001")

				@active_room.add(message)
				update_buffer(message)
				redraw
			elsif text == "/quit" then
				@client.close()
			elsif text[/\A\/kick /] then
				if @active_room != nil then
					return
				end

				_, who, kick_msg = text.split(" ", 3)

				command = "KICK #{@active_room.title} #{who}"
				if kick_msg != nil then
					command += " :#{kick_msg}"
				end

				@client.send(command)

				message = Message.new(
					@client.user,
					"KICK",
					[@active_room.title, who, kick_msg],
					:message,
					{},
					Time.now
				)

				redraw
			elsif text[/\A\/mode /] then
				if @active_room == nil then
					return
				end

				_, params = text.split(" ", 2)
				@client.send("MODE #{@active_room.title} #{params}")
			end
		else
			if @active_room == nil then
				return
			end

			if @active_room.is_left? then
				message = Message.new(
					SYSTEM_USER,
					SYSTEM_USER,
					["You've left this room"],
					:system,
					{},
					Time.now
				)

				@active_room.add(message)
				update_buffer(message)
			else
				# Echo the message to current channel
				message = Message.new(
					@client.user,
					"PRIVMSG",
					[@active_room.title, text],
					:message,
					{},
					Time.now
				)
				@active_room.add(message)
				update_buffer(message)

				# Send the message to client.
				@client.send("PRIVMSG #{@active_room.title} :#{text}")
			end

			redraw
		end
	end

	# Signals

	def handle_signal
		while @signals.empty? == false do
			msg = @signals.next

			case msg
				when :winch
					size = (`stty size`).split(" ").map { |x| Integer(x) }
					@size = { :lines => size[0], :cols => size[1] }
					@dirty = true
					clear
					layout_buffer
					redraw
				when :int
					@client.close()
			end
		end
	end

	# Input

	def add_input
		@input.on_stop = lambda {
			@client.close()
			@event_loop.stop()
		}

		@input.on_submit = lambda { |text|
			# Reset history offset, append command to history
			@history << text
			if @history.length > SETTINGS[:history_size] then
				@history[1, @history.length - 1]
			end
			@history_offset = 0

			parse_and_send(text)

			# Redraw the input
			draw_input
		}

		@input.on_control = lambda { |x|
			case x
			when :ARROW_UP
				@history_offset = [-@history.length, @history_offset - 1].max
				if @history_offset < 0 then
					@input.buffer = @history[@history_offset]
				else
					@input.buffer = ""
				end
				draw_input
			when :ARROW_DOWN
				@history_offset = [@history_offset + 1, 0].min
				if @history_offset < 0 then
					@input.buffer = @history[@history_offset]
				else
					@input.buffer = ""
				end
				draw_input
			when :PAGE_UP
				@offset = [
					@offset + @size[:lines] / 2,
					[@buffer.length - (@size[:lines] - 2), 0].max
				].min
				redraw
			when :PAGE_DOWN
				@offset = [@offset - @size[:lines] / 2, 0].max
				redraw
			when :TAB
				if @active_room != nil && @rooms.length > 0 then
					index = @rooms.index { |x| x == @active_room }
					change_room(@rooms[(index + 1) % @rooms.length])
					redraw
				end
			end
		}
	end

	def clear
		print "\033[2J"
	end

	def change_room(room)
		@offset = 0
		@active_room = room
		@active_room.is_read = true

		clear
		layout_buffer
		@dirty = true
	end
end

##################
# Initialization #
##################

# Setup - enable raw mode
stty_orig = `stty -g`
`stty raw -echo`

# Setup - app event loop
client = Client.new("irc.rizon.net", 6667, "aint1", nil)
app = App.new(client)
app.run()

# Restore terminal settings
`stty #{stty_orig}`
