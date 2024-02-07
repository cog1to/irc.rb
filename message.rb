class Message
  def initialize(prefix, command, params, is_emote, tags)
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
        return Message.new(nil, "ACTION", tmp, true, tags)
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

		return Message.new(prefix, command, params, is_emote, tags)
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

msg1 = Message.from_string(":aint WHISPER #chat :hello, my name is aint")
puts "#{msg1.prefix}, #{msg1.command}, #{msg1.params}, #{msg1.is_emote?}"

msg1 = Message.from_string("ISIRCX")
puts "#{msg1.prefix}, #{msg1.command}, #{msg1.params}, #{msg1.is_emote?}"

msg1 = Message.from_string("WHISPER #chat")
puts "#{msg1.prefix}, #{msg1.command}, #{msg1.params}, #{msg1.is_emote?}"

msg1 = Message.from_string("USER aint 0 *")
puts "#{msg1.prefix}, #{msg1.command}, #{msg1.params}, #{msg1.is_emote?}"

msg1 = Message.from_string("SAY :custom text")
puts "#{msg1.prefix}, #{msg1.command}, #{msg1.params}, #{msg1.is_emote?}"

msg1 = Message.from_string("\001ACTION waves goodbye\001")
puts "#{msg1.prefix}, #{msg1.command}, #{msg1.params}, #{msg1.is_emote?}"

msg1 = Message.from_string("@tag1:value1 SAY :custom text")
puts "#{msg1.prefix}, #{msg1.command}, #{msg1.params}, #{msg1.is_emote?}, #{msg1.tags}"

msg1 = Message.from_string("@style=bold;color=red SAY :custom text")
puts "#{msg1.prefix}, #{msg1.command}, #{msg1.params}, #{msg1.is_emote?}, #{msg1.tags}"
