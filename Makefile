default:
	@echo "Nothing to do, use 'make install'"

install:
	cp irc.rb /usr/local/bin/irc.rb
	chmod u+x /usr/local/bin/irc.rb

