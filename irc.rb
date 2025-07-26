#!/usr/bin/env ruby

require "socket"
require "io/console"
require 'optparse'

###############################################################################
# Styling

module Term
	Switch = Struct.new(:on, :off, :raw)

	Styles = {
		:bold          => Switch.new("\033[1m", "\033[22m", "1"),
		:italic        => Switch.new("\033[3m", "\033[23m", "3"),
		:underline     => Switch.new("\033[4m", "\033[24m", "4"),
		:strikethrough => Switch.new("\033[9m", "\033[29m", "9"),
		:reverse       => Switch.new("\033[7m", "\033[27m", "7")
	}

	Colors16FG = {
		:base    => "39",
		:black   => "30",
		:red     => "31",
		:green   => "32",
		:yellow  => "33",
		:blue    => "34",
		:magenta => "35",
		:cyan    => "36",
		:white   => "37",
		:bright_black   => "90",
		:bright_red     => "91",
		:bright_green   => "92",
		:bright_yellow  => "93",
		:bright_blue    => "94",
		:bright_magenta => "95",
		:bright_cyan    => "96",
		:bright_white   => "97"
	}

	Colors16BG = {
		:base    => "49",
		:black   => "40",
		:red     => "41",
		:green   => "42",
		:yellow  => "43",
		:blue    => "44",
		:magenta => "45",
		:cyan    => "46",
		:white   => "47",
		:bright_black   => "100",
		:bright_red     => "101",
		:bright_green   => "102",
		:bright_yellow  => "103",
		:bright_blue    => "104",
		:bright_magenta => "105",
		:bright_cyan    => "106",
		:bright_white   => "107"
	}

	module_function
	def color(palette, code)
		case code
		when "1", "01" # Black
			return palette[:black]
		when "2", "02" # Blue
			return palette[:blue]
		when "3", "03" # Green
			return palette[:green]
		when "4", "04" # Red
			return palette[:red]
		when "5", "05" # Brown
			return palette[:red]
		when "6", "06" # Magenta
			return palette[:magenta]
		when "7", "07" # Orange
			return palette[:bright_red]
		when "8", "08" # Yellow
			return palette[:yellow]
		when "9", "09" # Light green
			return palette[:bright_green]
		when "10"      # Cyan
			return palette[:cyan]
		when "11"      # Light cyan
			return palette[:bright_cyan]
		when "12"      # Light blue
			return palette[:bright_blue]
		when "13"      # Pink
			return palette[:bright_magenta]
		when "14"      # Grey
			return palette[:bright_black]
		when "15"      # Light grey
			return palette[:bright_white]
		else           # Default
			return palette[:base]
		end
	end

	def foreground(code)
		color(Colors16FG, code)
	end

	def background(code)
		color(Colors16BG, code)
	end

	def from_irc(code, style = nil)
		splitted = code.split(",")
		if splitted[1] then
			return "\033[#{style ? style.raw + ";" : ""}#{foreground(splitted[0])};#{background(splitted[1])}m"
		else
			return "\033[#{style ? style.raw + ";" : ""}#{foreground(splitted[0])}m"
		end
	end
end

Style = Struct.new(:time, :nick, :text)

def style(color, style = nil)
	if color && style then
		return "\033[#{Term::Colors16FG[color]}m" + Term::Styles[style].on
	elsif color then
		return "\033[#{Term::Colors16FG[color]}m"
	elsif style then
		return Term::Styles[style].on
	end
	return nil
end

###############################################################################
# Settings

CHAT_EVENTS_STYLE = Style.new(
	style(:bright_black),
	style(:magenta, :bold),
	style(:magenta)
)

SYSTEM_USER = "SYSTEM"

SETTINGS = {
	:buffer_size => 1000,
	:history_size => 20,
	:download_dir => "~/downloads/DCC".force_encoding("UTF-8"),
	:packet_size => (1024 * 1024),
	:download_step => 0.01,
	:formatting => {
		"\002" => Term::Styles[:bold],
		"\026" => Term::Styles[:reverse],
		"\035" => Term::Styles[:italic],
		"\037" => Term::Styles[:underline],
		"\036" => Term::Styles[:strikethrough],
		"\021" => Term::Switch.new("", "") # Monospace (not supported)
	},
	:styles => {
		:message => Style.new(style(:bright_black), style(:red), nil),
		:ctcp    => Style.new(style(:yellow), style(:yellow, :bold), style(:yellow)),
		:dcc     => Style.new(style(:green), style(:green, :bold), style(:green)),
		:action  => Style.new(style(:blue), style(:blue, :bold), style(:blue)),
		:join    => CHAT_EVENTS_STYLE,
		:part    => CHAT_EVENTS_STYLE,
		:kick    => CHAT_EVENTS_STYLE,
		:ban     => CHAT_EVENTS_STYLE,
		:system  => Style.new(style(:bright_black), style(:base, :bold), style(:base, :bold)),
		:self    => Style.new(style(:bright_black), style(:base, :bold), nil),
		:mode    => Style.new(style(:bright_black), style(:red), nil),
		:users   => Style.new(style(:bright_black), style(:red), nil),
		:error   => Style.new(style(:bright_black), style(:red), style(:red, :bold))
	},
}

###############################################################################
# Arguments

options = {
	:port => 6667,
	:server => "irc.rizon.net",
}

OptionParser.new do |opt|
	opt.on("-c", "--server SERVER") { |o|
		options[:server] = o
	}
	opt.on("-p", "--port PORT") { |o|
		options[:port] = o.to_i
	}
	opt.on("-u", "--user USER") { |o|
		options[:user] = o
	}
	opt.on("-s", "--pass PASS") { |o|
		options[:pass] = o
	}
	opt.on("-h", "--help") {
		puts opt
		exit
	}
end.parse!

if options[:user] == nil then
	puts "User not specified. Either modify the default options or provide a username with '-u'"
	exit
end

if options[:port] == nil || options[:port] <= 0 then
	puts "Bad port number #{options[:port]}"
	exit
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
		@socket = TCPSocket.new(@addr, @port, connect_timeout: 30)
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
			begin
				@socket.send(msg + "\r\n", 0)
			rescue => ex
				@err.call(ex) if @err
				close()
			end
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

		Signal.trap("TERM") do
			@queue << :term
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

class CTCP
	attr_reader :command, :params

	def initialize(command, params = nil)
		@command = command
		@params = params
	end
end

class Message
	attr_reader :prefix, :command, :params, :type, :tags, :time, :ctcp, :dcc

	def initialize(
		prefix,
		command,
		params = [],
		type = :message,
		tags = {},
		time,
		ctcp,
		dcc
	)
		@prefix = prefix
		@command = command
		@params = params
		@type = type
		@tags = tags
		@time = time
		@ctcp = ctcp
		@dcc = dcc
	end

	def self.from_string(msg)
		tmp = msg.dup
		type = :message
		prefix = ""
		command = ""
		params = []
		tags = {}
		time = Time.now
		ctcp = nil
		dcc = nil

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
					dcc_params = last_param[4..-1].scan(/(".+?"|.+?)( |\Z)/).map { |x| x[0] }
					dcc = CTCP.new(dcc_params[0], dcc_params[1..-1])
				else
					type = :ctcp
					ctcp_params = last_param.split(" ")
					ctcp = CTCP.new(ctcp_params[0], ctcp_params[1..-1])
				end
			end

			params << last_param
		end

		return Message.new(prefix, command, params, type, tags, time, ctcp, dcc)
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
		when "PRIVMSG", "NOTICE"
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
					"sent 'CTCP #{params[1..-1].join(" ")}' request to \002#{params[0]}\002",
					SETTINGS[:styles][:ctcp]
				)
			when :dcc
				return format_internal(
					cols,
					"sent '#{params[1..-1].join(" ")}' request to \002#{params[0]}\002",
					SETTINGS[:styles][:dcc]
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
			suffix = (params[1] != nil ? " with message \"#{params[1]}\"" : "")
			return format_internal(
				cols,
				"has left \002#{params[0]}\002#{suffix}",
				SETTINGS[:styles][:part]
			)
		when "KICK"
			return format_internal(
				cols,
				"kicked \002#{params[1]}\002 [#{params[2..-1].join(" ")}]",
				SETTINGS[:styles][:kick]
			)
		when "QUIT"
			suffix = ((params[0] != nil && params[0] != "") ? " with message \"#{params[0]}\"" : "")
			return format_internal(
				cols,
				"has quit#{suffix}",
				SETTINGS[:styles][:part]
			)
		when "MODE"
			return format_internal(
				cols,
				"set mode \002#{params[1]}\002 for \002#{params[0]}\002",
				SETTINGS[:styles][:mode]
			)
		when "353"
			return format_internal(
				cols,
				"Users: #{params[-1].split(" ").map{ |u| "\00303#{u}\003" }.join(", ")}",
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
		when "NICK"
			return format_internal(
				cols,
				"changed name to \00304#{params[0]}\017"
			)
		when "NOTICE", "001", "002", "003", "004", "375", "372", "376", "251",
			"252", "253", "254", "255", "265", "266"
			return format_internal(cols, @params[1..-1].join(" "))
		when "SYSTEM"
			return format_internal(
				cols,
				@params[0..-1].join(" "),
				SETTINGS[:styles][:system]
			)
		when /4\d\d/
			return format_internal(
				cols,
				"ERROR \00399\002#{@command}\002\003: #{@params[1..-1].join(" ")}",
				SETTINGS[:styles][:error]
			)
		else
			return format_internal(cols, @command + " " + @params.join(" "))
		end
	end

	def update(params)
		@params = params
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
		line = ""; lines = []; format = []

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
							line << Term::from_irc(x[1..-1])
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
						end

						i = i + 1

						if m = /\A\d\d?(,\d\d?)?/.match(visible_text[i..-1]) then
							line << Term::from_irc(m[0])
							format.each { |f| line << SETTINGS[:formatting][f].on }
							format.append("\003" + m[0])
							i = i + m[0].length
						else
							line << (text_style != "" ? text_style : "\033[39;49m")
							format.each { |f| line << SETTINGS[:formatting][f].on }
						end

						next
					elsif (visible_text[i] == "\017") then
						format.each { |f|
							if f["\003"] then
								line << (text_style != "" ? text_style : "\033[39;49m")
							else
								line << SETTINGS[:formatting][f].off
							end
						}
						format.clear

						i = i + 1
						next
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
			elsif (visible_text[idx] == "\003" || visible_text[idx] == "\017") then
				# Skip color sequence.
				if (visible_text[idx] == "\003") then
					idx += 1
					if m = /\A\d\d?(,\d\d?)?/.match(visible_text[idx..-1]) then
						idx += m[0].length
					end
				else
					idx = idx + 1
				end
			elsif ["\002", "\026", "\035", "\036", "\037"].index(visible_text[idx]) != nil then
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
	attr_reader :host, :user, :state

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
		@state = :closed
		@irc.close()
	end

	def close(message)
		if @state == :closed then
			return
		end

		@state = :closing
		@irc.send("QUIT" + ((message != nil && message != "") ? " :#{message}" : ""))
	end

	def send(msg)
		if @state != :connected then
			return
		end

		@irc.send(msg)
	end

	def handle_message(msg)
		parsed = Message.from_string(msg)
		response = nil

		if parsed.command == "ERROR" && state == :closing then
			disconnect()
			@on_close.call()
			return
		elsif parsed.command == "PRIVMSG" && parsed.type == :ctcp then
			if parsed.ctcp != nil &&
				parsed.ctcp.command == "VERSION" &&
				parsed.ctcp.params.length == 0
			then
				response = Message.new(
					@user,
					"NOTICE",
					[parsed.nick, "\001VERSION irc.rb 0.1\001"],
					:ctcp,
					{},
					Time.now,
					CTCP.new("VERSION", "irc.rb 0.1"),
					nil
				)
				@irc.send("NOTICE #{parsed.nick} \001VERSION irc.rb 0.1\001")
			end
		elsif parsed.command == "PING" then
			# Ping request, just pong back.
			@irc.send("PONG :#{parsed.params[0]}")
			return
		elsif parsed.command == "PONG" then
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
				start_ping
			end
		end

		# Add message to queue and signal the event loop
		@queue << parsed
		@queue << response if response != nil
		@write_fd.write("1")
	end

	def handle_error(err)
		if @state != :closed then
			# TODO: Error handling
			reconnect
		end
	end

	private
	def start_ping
		Thread.new do
			while @state == :connected do
				send("PING :#{Time.now.to_i}")
				sleep(30)
			end
		end
	end

	def reconnect
		disconnect()
		connect()
	end
end

class InputHandler
	def initialize(ev)
		@event_loop = ev
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

	def on_append=(callback)
		@on_append = callback
	end

	def handle_input()
		while true
			begin
				char = STDIN.read_nonblock(1)

				if @escape then
					case char
					when "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ";", "?", "[",
						"A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "S", "T",
						"f", "m", "i", "n", "h", "l", "s", "u", "~"
						@escape_buf << char

						KNOWN_CONTROLS.each { |key, value|
							if key.class == String && @escape_buf == key then
								@on_control.call(value) if @on_control != nil && value
								@escape = false
							elsif key.class == Regexp && key.match(@escape_buf) then
								@on_control.call(value) if @on_control != nil && value
								@escape = false
							end
						}

						@escape_buf = "" if @escape == false
					else
						@escape = false # Unknown or invalid escape sequence
						@escape_buf = ""
					end
				else
					case char
					when "\t"
						@on_control.call(:TAB) if @on_control != nil
					when "\r"
						@on_submit.call() if @on_submit != nil
					when 3.chr, 26.chr
						# CTRL-C, CTRL-Z
						@on_stop.call() if @on_stop != nil
						break
					when 127.chr
						@on_control.call(:BACKSPACE) if @on_control != nil
					when 27.chr
						# Escape sequence detected.
						@escape = true
					else
						@on_append.call(char) if @on_append != nil
					end
				end
			rescue IO::EAGAINWaitReadable
				# No more to read, break, finish handler.
				break
			rescue => ex
				retry
			end
		end
	end

	KNOWN_CONTROLS = {
		"[3~" => :DELETE,
		"[5~" => :PAGE_UP,
		"[6~" => :PAGE_DOWN,
		"[D"  => :ARROW_LEFT,
		"[C"  => :ARROW_RIGHT,
		"[A"  => :ARROW_UP,
		"[B"  => :ARROW_DOWN,
		/\[1?[A-Z]/ => nil,
		/\[\d+~/ => nil,
	}
end

class DccClient
	class Update
	end

	class Resume < Update
		attr_reader :nick, :file, :port, :size

		def initialize(nick, file, port, size)
			@nick = nick
			@file = file
			@port = port
			@size = size
		end
	end

	class Progress < Update
		attr_reader :nick, :file, :percent

		def initialize(nick, file, percent)
			@nick = nick
			@file = file
			@percent = percent
		end
	end

	class Error < Update
		attr_reader :error, :nick

		def initialize(nick, error)
			@nick = nick
			@error = error
		end
	end

	class Connection
		attr_reader :ipaddr, :size

		def initialize(ipaddr, size)
			@ipaddr = ipaddr
			@size = size
		end
	end

	def initialize()
		@read_fd, @write_fd = IO.pipe
		@queue = Queue.new()
		@updates = Queue.new()
		@running = false
		@connections = {}
	end

	# Events

	def fd()
		return @read_fd
	end

	def empty?
		return @updates.empty?
	end

	def next
		if @updates.empty?
			return nil
		else
			return @updates.pop
		end
	end

	# Control

	def add(msg)
		@queue << msg
	end

	def start()
		@running = true
		Thread.new do
			while @running do
				begin
					msg = @queue.pop
					download(msg)
				end
			end
		end
	end

	def stop()
		@queue.clear()
		@running = false
	end

	private

	def download(message)
		room = message.nick
		filename = message.dcc.params[0]
		if filename[/\A".+"\Z/] then
			filename = filename[1...-1].force_encoding("UTF-8")
		end

		begin
			path = File.expand_path("#{SETTINGS[:download_dir]}/#{filename}")
			port, result = 0, nil
			total, finished, packets = 0, false, 0

			# Check if file exists.
			existing_size = File.size?(path)
			mode = "w"

			if message.dcc.command == "SEND" then
				# Parse connection info.
				ipnumber = message.dcc.params[1].to_i
				ipaddr = (0..3)
					.map { |x| (ipnumber >> (8 * x)) & 0xFF }
					.reverse
					.map { |x| "#{x}" }
					.join(".")
				port = message.dcc.params[2].to_i
				size = message.dcc.params[3].to_i

				if @connections[port] == nil then
					# If initial SEND request, extract connection info.
					@connections[port] = Connection.new(ipaddr, size)

					# If file exists, send RESUME request.
					if existing_size != nil && existing_size > 0 then
						send_resume(room, filename, port, existing_size)
						return
					end
				else
					# If we've already got connection info, that means Resume is not
					# supported. Start download from scratch.
					@connections[port] = Connection.new(ipaddr, size)
				end
			elsif message.dcc.command == "ACCEPT" then
				# Resume accepted, proceed to download.
				port = message.dcc.params[1].to_i
				total = existing_size
				mode = "a"
			else
				send_error(room, "Download error: unsupported command #{message.dcc.command}")
				return
			end

			if @connections[port] == nil then
				# Unknown connection request, ignore
				return
			end

			connection = @connections[port]
			size = connection.size
			buffer = "".force_encoding("BINARY")
			socket = TCPSocket.new(connection.ipaddr, port)
			progress, prev_progress = 0.0, 0.0

			send_progress(room, filename, 0)
			send_progress(room, filename, total / size)

			# Start downloading
			File.open(path, mode) { |file|
				session_total = 0
				while @running do
					begin
						result = IO.select([socket], nil, nil, 60)
						if result == nil then
							break
						end

						readbuf = socket.recv(SETTINGS[:packet_size])
						read, total = readbuf.bytesize, total + readbuf.bytesize
						session_total = session_total + readbuf.size
						buffer = buffer + readbuf

						packet_count = session_total / SETTINGS[:packet_size]
						if (size == total) then
							# Write the rest of the file.
							file.write(buffer)
							# Ack received bytes.
							socket.send([total].pack("N"), 0)
							# Get out of the loop.
							finished = true
							break
						elsif (packet_count > packets) then
							# Write one packet to the file.
							file.write(buffer[0, SETTINGS[:packet_size]])
							# Remove packet from the buffer.
							buffer = buffer[SETTINGS[:packet_size]..-1]
							# Increase packet count.
							packets = packet_count
							# Ack received bytes.
							socket.send([packet_count * SETTINGS[:packet_size]].pack("N"), 0)
						end

						progress = total.to_f / size
						if ((progress - prev_progress) > SETTINGS[:download_step]) then
							prev_progress = progress
							send_progress(room, filename, progress)
						end
					rescue IO::WaitReadable
						# Read timeout.
					rescue Errno::ECONNRESET
						if !finished then
							# Report file download error.
							send_error(room, "Download error: connection reset")
						end
						break
					rescue => ex
						if finished == false then
							# Report file download error.
							send_error(room, "Error downloading file: #{ex}")
						end
						break
					end
				end
			}

			socket.close()
			if @running && finished then
				send_progress(room, filename, 1.0)
			else
				send_error(
					room,
					"Download interrupted" + (result == nil ? ": socket read timeout" : "")
				)
			end
			@connections.delete(port)
		rescue => ex
			send_error(room, "Error downloading file: #{ex.class}: #{ex.message}")
			if port > 0 then
				@connections.delete(port)
			end
		end
	end

	def send_error(room, message)
		@updates << Error.new(room, "Download error: connection reset")
		@write_fd.write("1")
	end

	def send_progress(room, filename, progress)
		@updates << Progress.new(room, filename, progress)
		@write_fd.write("1")
	end

	def send_resume(room, filename, port, size)
		@updates << Resume.new(room, filename, port, size)
		@write_fd.write("1")
	end
end

################################################################################
# App logic.

class Room
	attr_accessor :title, :progress_message
	attr_reader :messages

	def initialize(title)
		@title = title
		@messages = []
		@is_read = true
		@is_left = false
		@users = []
	end

	def add(message)
		@messages << message
	end

	def add_users(users)
		for user in users do
			add_user(user)
		end
	end

	def add_user(user)
		if @users.find_index { |x| /[~&@%+]?#{Regexp.quote(user)}/.match(x) } == nil then
			@users << user
		end
	end

	def remove_user_if_present(user)
		if index = @users.find_index { |x| /[~&@%+]?#{Regexp.quote(user)}/.match(x) } then
			return (@users.delete_at(index) != nil)
		else
			return false
		end
	end

	def rename_user_if_present(user, name)
		if index = @users.find_index { |x| /[~&@%+]?#{Regexp.quote(user)}/.match(x) } then
			return ((@users[index] = name) != nil)
		else
			return false
		end
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
end

class App
	def initialize(client)
		@client = client
		@signals = Signals.new()
		@dcc = DccClient.new()
		@event_loop = EventLoop.new
		@input = InputHandler.new(@event_loop)

		# Add close callback.
		@client.on_close = lambda {
			@event_loop.stop()
		}

		# Add client events.
		@event_loop.add(client.fd, lambda { handle_message })

		# Add signals.
		@event_loop.add(@signals.fd, lambda { handle_signal })

		# Add DCC events.
		@event_loop.add(@dcc.fd, lambda { handle_dcc_update })

		# Initial state.
		@rooms = []
		@buffer = []
		@offset = 0
		@history = []
		@history_offset = 0
		@first_message = true
		@input_buffer = ""
		@input_offset = 0

		# Get current size.
		size = (`stty size`).split(" ").map { |x| Integer(x) }
		@size = { :lines => size[0], :cols => size[1] }

		# Subscribe to events.
		add_input
		@signals.subscribe()

		# Start DCC thread.
		@dcc.start()
	end

	def handle_message()
		while @client.empty? == false do
			msg = @client.next

			if (msg.command == "PRIVMSG" || msg.command == "NOTICE") then
				if msg.params[0] == nil then
					next # Bad format
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
					if room = @rooms.find { |x| x.title.downcase == name.downcase } then
						room.add(msg)
					else
						room = Room.new(name)
						room.add(msg)
						@rooms << room
					end

					# Print to screen or mark room as unread.
					if room != @active_room then
						room.is_read = false
					else
						update_buffer(msg)
					end
					@dirty = true

					# Handle DCC transfer.
					if (msg.type == :dcc) then
						handle_dcc(msg, room)
					end
				end
			elsif (
				msg.command == "JOIN" ||
				msg.command == "PART" ||
				msg.command == "MODE" ||
				msg.command == "353" ||
				msg.command == "332" ||
				msg.command == "333"
			) then
				# Room name.
				name = ""
				if ["JOIN", "PART"].any? { |x| x == msg.command } then
					name = msg.params[0]
				elsif msg.command == "353" then
					name = msg.params[2]
				elsif msg.command == "332" || msg.command == "333" then
					name = msg.params[1]
				elsif msg.command == "MODE" then
					if (msg.nick == @client.user) then
						name = @rooms[0].title
					else
						name = msg.params[0]
					end
				end

				# If we've left the room, delete it from the list.
				if (msg.command == "PART" && msg.nick == @client.user) then
					if room = @rooms.find { |x| x.title.downcase == name.downcase } then
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
					if room = @rooms.find { |x| x.title.downcase == name.downcase } then
						room.is_left = false
						room.add(msg)
						# QUESTION: Do we want to mark room unread for these messages?
					else
						room = Room.new(name)
						room.add(msg)
						@dirty = true
						@rooms << room
					end

					# Add users to the room.
					if (msg.command == "353") then
						users = msg.params[-1].split(" ")
						room.add_users(users)
					elsif (msg.command == "JOIN") then
						room.add_user(msg.nick)
					elsif (msg.command == "PART") then
						room.remove_user_if_present(msg.nick)
					end

					# Make room active if it's the one we're expecting to join.
					if (@expected_room != nil) && @expected_room.downcase == name.downcase then
						change_room(room)
						@expected_room = nil
					elsif room == @active_room then
						update_buffer(msg)
					end
				end
			elsif (msg.command == "NICK") then
				# Rename the user in all rooms he's part of.
				for room in @rooms do
					if room.title == msg.nick ||
						(room.rename_user_if_present(msg.nick, msg.params[0]) != false) then
						room.add(msg)
						# If the user is renamed in the active room, redraw.
						if room == @active_room then
							update_buffer(msg)
						end
						# If the room is private chat with the user, rename the room.
						if (room.title == msg.nick) then
							room.title = msg.params[0]
							draw_tabs
						end
					end
				end
			elsif (msg.command == "366") then
				# Ignore
			elsif (msg.command == "KICK") then
				channel, user = msg.params[0], msg.params[1]

				if room = @rooms.find { |x| x.title.downcase == channel.downcase } then
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
				# Remove user from any room we know he was part of.
				for room in @rooms do
					if room.title == msg.nick || (room.remove_user_if_present(msg.nick) != false) then
						room.add(msg)
						# If the user is removed from the active room, redraw.
						if room == @active_room then
							update_buffer(msg)
						end
					end
				end
			elsif (msg.command == "401") then
				if @active_room then
					@active_room.add(msg)
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

	def handle_dcc(message, room)
		if message.dcc.command == "SEND" || message.dcc.command == "ACCEPT" then
			@dcc.add(message)
		end
	end

	def handle_dcc_update()
		while @dcc.empty? == false do
			update = @dcc.next

			case update
			when DccClient::Resume
				if room = @rooms.find { |x| x.title.downcase == update.nick.downcase } then
					text = "DCC RESUME \"#{update.file}\" #{update.port} #{update.size}"
					# Echo message and send to client.
					message = Message.new(
						@client.user,
						"PRIVMSG",
						[update.nick, text],
						:dcc,
						{},
						Time.now,
						nil,
						CTCP.new("RESUME", "\"#{update.file}\" #{update.port} #{update.size}")
					)
					room.add(message)
					if @active_room == room then
						update_buffer(message)
						redraw
					end
				end
				@client.send("PRIVMSG #{update.nick} :\001DCC RESUME \"#{update.file}\" #{update.port} #{update.size}\001")
			when DccClient::Error
				system_message(update.error, update.nick, true, false)
			when DccClient::Progress
				if update.percent == 0.0 then
					system_message(
						sprintf("Download started: '%s'", update.file),
						update.nick,
						false,
						false
					)
				elsif update.percent == 1.0 then
					system_message(
						sprintf("Download finished: '%s'", update.file),
						update.nick,
						false,
						true
					)
				else
					system_message(
						sprintf(
							"'%s': %.0f%%",
							update.file,
							update.percent*100
						),
						update.nick,
						false,
						false
					)
				end
			end
		end
	end

	def system_message(text, user, error, finished)
		# Find or create a room
		room = @rooms.find { |x| x.title == user }
		if room == nil then
			room = Room.new(user)
			@rooms << room
		end

		if error then
			# Add error message.
			message = Message.new(
				SYSTEM_USER,
				SYSTEM_USER,
				[text],
				:system,
				{},
				Time.now,
				nil, nil
			)
			room.add(message)
		else
			# Find progress message or create one
			message = room.progress_message
			if message == nil then
				message = Message.new(
					SYSTEM_USER,
					SYSTEM_USER,
					[text],
					:system,
					{},
					Time.now,
					nil, nil
				)
				room.add(message)
				room.progress_message = message
			else
				message.update([text])
			end
		end

		# Remove progress message if we're finished or encountered an error.
		if finished || error then
			room.progress_message = nil
		end

		# Redraw or mark unread
		if (room == @active_room) then
			layout_buffer
			redraw
		else
			room.is_read = room.is_read? && !(finished || error)
			draw_tabs
			draw_input
		end
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

		length, active_found, format = 0, false, ""
		last_idx, start_idx = nil, 0
		@rooms.each do |room|
			room_str = "#{room.title}"
			room_str += (room.is_read? ? " " : "*") + " "

			if length + room_str.length > @size[:cols] then
				if active_found then
					break
				else
					# Remember "start of the page" room index
					start_idx = @rooms.index(room)
					# Reset line length, since we're starting new page
					length = 0
					# If there are unread rooms on the previous page, enable bold
					format = (@rooms[0..(last_idx + 1)].any? {
						|r| !r.is_read?
					}) ? "\033[1m" : ""
					# Print previous page symbol
					printf("\033[1;1H#{format}<")
				end
			end

			last_idx = @rooms.index(room)

			# Enable bold for active room
			if (room == @active_room) then
				format = "\033[1m"
				active_found = true
			else
				format = "\033[22m"
			end

			# Print current room
			print(
				format +
				room_str[0, [room_str.length + 2, @size[:cols] - length].min] +
				"\033[22m"
			)
			length += (room.title.length + 2)
		end

		# Fill the rest of the line
		if last_idx < (@rooms.length - 1) then
			# If there are rooms on the previous page, add extra padding for "<"
			pad = start_idx > 0 ? 1 : 0
			# If there are unread rooms on the next page, enable bold for ">"
			format = (@rooms[(last_idx + 1)..-1].any? { |r| !r.is_read? }) ? "\033[1m" : ""
			# Fill up to the end of the line + next page symbol
			print(" " * (@size[:cols] - length - 1 - pad) + format + ">")
		else
			# No pages after this one, just fill with blanks
			print " " * [@size[:cols] - length, 0].max
		end

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

		# Draw current content.
		content = @history_offset < 0 ? @history[@history_offset] : @input_buffer
		line = content[([0, content.length - @size[:cols] + 4].max)..-1]
		print("\033[#{@size[:lines]};1H>> #{line}\033[0K")

		# Move cursor back.
		if @input_offset > 0 then
			print("\033[#{@input_offset}D")
		end
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
				# Can't leave the server room.
				if @rooms[0] == @active_room then
					return
				end

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
						Time.now,
						nil,
						nil
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
				message = Message.new(
					@client.user,
					"PRIVMSG",
					[text],
					:action,
					{},
					Time.now,
					nil, nil
				)
				@client.send("PRIVMSG #{@active_room.title} :\001ACTION #{text}\001")

				@active_room.add(message)
				update_buffer(message)
				redraw
			elsif text[/\A\/nick /] then
				text[/\A\/nick /] = ""
				if text != "" then
					@client.send("NICK #{text}")
					update_buffer(message)
					redraw
				end
			elsif text[/\A\/(quit|exit)/] then
				text[/\A\/(quit|exit) ?/] = ""
				@client.close(text)
			elsif text == "/ping" then
				@client.send("PING :#{Time.now.to_i}")
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
					Time.now,
					nil, nil
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
					Time.now,
					nil, nil
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
					Time.now,
					nil, nil
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
					@client.close(nil)
				when :term
					@client.close(nil)
			end
		end
	end

	# Input

	def add_input
		@input.on_stop = lambda {
			@client.close(nil)
			@event_loop.stop()
		}

		@input.on_submit = lambda {
			# Reset history offset, append command to history
			@history << @input_buffer
			if @history.length > SETTINGS[:history_size] then
				@history[1, @history.length - 1]
			end
			@history_offset = 0

			# Reset buffer and send
			text, @input_buffer, @input_offset = @input_buffer, "", 0
			parse_and_send(text)

			# Redraw the input
			draw_input
		}

		@input.on_control = lambda { |x|
			case x
			when :ARROW_UP
				@input_offset = 0
				@history_offset = [-@history.length, @history_offset - 1].max
				if @history_offset < 0 then
					@input_buffer = @history[@history_offset].dup
				else
					@input_buffer = ""
				end
				draw_input
			when :ARROW_DOWN
				@input_offset = 0
				@history_offset = [@history_offset + 1, 0].min
				if @history_offset < 0 then
					@input_buffer = @history[@history_offset].dup
				else
					@input_buffer = ""
				end
				draw_input
			when :BACKSPACE
				@history_offset = 0
				if (@input_buffer.length > 0) then
					if (@input_offset < @input_buffer.length) then
						@input_buffer.slice!(
							[@input_buffer.length - @input_offset - 1, 0].max
						)
					else
						@input_buffer.slice!(0)
					end
					@input_offset = [@input_buffer.length, @input_offset].min
				end
				draw_input
			when :DELETE
				@history_offset = 0
				if (@input_buffer.length > 0) then
					if (@input_offset == 0) then
						@input_buffer.slice!(@input_buffer.length - 1)
					else
						@input_buffer.slice!(
							[@input_buffer.length - @input_offset, 0].max
						)
					end
					@input_offset = [0, @input_offset - 1].max
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
			when :ARROW_LEFT
				old_offset = @input_offset.dup
				@input_offset = [@input_buffer.length, @input_offset + 1].min
				print("\033[1D") if (old_offset != @input_offset)
			when :ARROW_RIGHT
				old_offset = @input_offset.dup
				@input_offset = [0, @input_offset - 1].max
				print("\033[1C") if (old_offset != @input_offset)
			end
		}

		@input.on_append = lambda { |x|
			@input_buffer.insert(@input_buffer.length - @input_offset, x)
			@history_offset = 0
			draw_input
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

error = nil
begin
	# Setup - enable raw mode
	stty_orig = `stty -g`
	`stty raw -echo`
	# Enable alternate screen buffer mode.
	STDOUT.puts "\033[?1049h"

	# Setup
	client = Client.new(options[:server], options[:port], options[:user], options[:pass])
	app = App.new(client)

	# Start run loop
	app.run()
rescue => ex
	error = ex
ensure
	# Restore terminal settings
	`stty #{stty_orig}`
	# Disable alternate screen buffer mode.
	STDOUT.puts "\033[?1049l"
end

# Print an error, if set
if error then
	STDERR.puts "Error: #{error.class} - '#{error.message}'"
	STDERR.puts error.backtrace
end

