#!/usr/bin/env ruby

require "io/console"

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

###########
# Testing #
###########

# Setup - enable raw mode
STDIN.raw!

# Setup event loop
ev = EventLoop.new()

# Echo, but exit on "q"
handle = lambda {
	char = STDIN.read(1)

	case char
	when "q"
		ev.stop()
	else
		print char
	end
}
ev.add(STDIN, handle)

# Enter the loop
ev.run()
