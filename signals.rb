require 'io/console'

Signal.trap("SIGWINCH") do
	size = (`stty size`).split(" ").map { |x| Integer(x) }
	puts "#{size[0]} x #{size[1]}"
end

Signal.trap("TERM") do
  puts "term"
end

Signal.trap("INT") do
  puts "term"
  exit
end

Signal.trap("ABRT") do
  puts "abrt"
  exit
end

Signal.trap("TSTP") do
  puts "tstp"
  exit
end

while true do
  sleep 0.1
end
