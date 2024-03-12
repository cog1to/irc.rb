default:
	@echo "Nothing to do, use 'make install'"

tls:
	@echo "Applying TLS support patch"
	git apply patches/enable-tls.patch

install:
	cp irc.rb /usr/local/bin/irc.rb
	chmod u+x /usr/local/bin/irc.rb

