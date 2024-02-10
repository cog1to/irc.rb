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

  def lines(cols)
    str = to_s.tr("\001", "").tr("\002", "")
    lines = str.length / cols
    return lines + ((str.length - (lines * cols)) > 0 ? 1 : 0)
  end

  def to_s
    "#{nick} :: #{@command} :: #{@params.join(" ")}"
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

  def host
    return @host
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
    if @state != :closed then
      puts "#{err.class}: #{err}"
    end
    # TODO
  end
end

class InputHandler
  def initialize(ev, client)
    @event_loop = ev
    @client = client
    @buffer = ""
    @escape = false

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

  def buffer
    @buffer.dup
  end

  def handle_input()
    while true
      begin
        char = STDIN.read_nonblock(1)

        if @escape then
          case char
          when 51.chr
            # Delete code
            @escape = false
            print "\b \b"
            @buffer = @buffer[0...-1]
          when "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ";", "?"
            # Skip
          when "A"
            # Arrow up.
            if on_control != nil then
              on_control(:ARROW_UP)
            end
          when "B"
            # Arrow down.
            if on_control != nil then
              on_control(:ARROW_DOWN)
            end
          when "C", "D", "E", "F", "G", "H", "J", "K", "S", "T"
            @escape = false # Sequence end
          when "f", "m", "i", "n", "h", "l", "s", "u"
            @escape = false # Sequence end
          else
            @escape = false # Invalid escape sequence
          end
        else
          case char
          when "\r"
            # Clear line and send to the server.
            print "\033[1K\033[0E"
            @client.send(@buffer)
            @buffer = ""
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
    @is_active = false
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

  def is_active
    @is_active
  end

  def messages
    @messages
  end

  def title
    @title
  end
end

class App
  def initialize(client)
    @client = client
    @event_loop = EventLoop.new
    @input = InputHandler.new(@event_loop, client)
    @event_loop.add(client.fd, lambda { handle_message })
    @rooms = []

    add_signals
    add_input
  end

  def handle_message()
    while @client.empty? == false do
      msg = @client.next
      if @active_room then
        @active_room.add(msg)
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

  def redraw
    if @dirty then
      clear
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
        room_str = "*#{room_str}"
      end
      room_str += (room.is_read? ? "-" : "*") + " "
      print room_str[0, [room_str.length, @size[:cols] - length].min]
      length += room_str.length

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

    # Get each message's length
    messages = @active_room.messages.map { |m| [m, m.lines(@size[:cols])] }.reverse!

    # Draw each message from the bottom
    y = @size[:lines]
    idx = 0
    while (y > 2 && idx < messages.length) do
      m = messages[idx]
      str = m[0].to_s
        .gsub(/\001(.+?)\001/, "\033[31m\\1\033[0m")
        .gsub(/\002(.+?)\002/, "\033[1m\\1\033[0m")

      if (y - m[1] > 1) then
        print("\033[#{y - m[1]};1H#{str}\033[0m\033[0K")
      elsif str.length <= @size[:cols] then
        print("\033[2;1H#{str}\033[0m\033[0K")
      else
        print("\033[2;1H#{str[@size[:cols]..-1]}\033[0m\033[0K")
      end

      # Advance cursor
      idx += 1
      y -= m[1]
    end
  end

  def draw_input
    if @size == nil then
      return
    end

    print("\033[#{@size[:lines]};1H#{@input.buffer}")
  end

  # Signals

  def add_signals
    # Initial size
    size = (`stty size`).split(" ").map { |x| Integer(x) }
    @size = { :lines => size[0], :cols => size[1] }

    # Size change signal
    Signal.trap("SIGWINCH") do
      size = (`stty size`).split(" ").map { |x| Integer(x) }
      @size = { :lines => size[0], :cols => size[1] }
      @dirty = true
      redraw
    end

    # Interrupt
    Signal.trap("INT") do
      @client.disconnect()
      @event_loop.stop()
    end
  end

  def add_input
    @input.on_stop = lambda {
      @client.disconnect()
      @event_loop.stop()
    }

    @input.on_control = lambda { |x|
      case x
      when :ARROW_UP
        # TODO: Scrollback support
      when :ARROW_DOWN
        # TODO: Scrollback support
      end

      redraw
    }
  end

  def clear
    print "\033[2J"
  end
end

##################
# Initialization #
##################

# Setup - enable raw mode
stty_orig = `stty -g`
%x{stty raw -echo}

# Setup - app event loop
client = Client.new("irc.rizon.net", 6667, "aint", nil)
app = App.new(client)
app.run()

# Restore terminal settings
`stty #{stty_orig}`
