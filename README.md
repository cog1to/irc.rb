## irc.rb - single-file primitive IRC client

I wrote this client as an excercise to practice some Ruby. There isn't any
grand idea or plan behind this, I just wanted to have a small portable IRC
client.

Right now the inner logic of the client uses pipes, which is a Unix-only
mechanism, if I understand it correctly, so the client should not work on
Windows. Linux and MacOS are ok though.

### Bugs

Expect a lot of bugs. This is a fun/education project. I don't intend to write
a perfect IRC client with perfect compliance to all modern IRC standards. Feel
free to report and/or create pull requests.

### Usage

`irc.rb -c <server> -u <username> [-p <port>] [-s <password>]`

### Interface

The window has a tabs list on top, the text area displaying messages in a tab
that is currently active, and an input field at the bottom. Active tab is
printed in **bold**, and a tab that has new unread messages is printed with `*`
symbol at the end.

You can switch tabs by using **tab** key.

Hitting **return** will send a `PRIVMSG` to the currenly open tab, which is
either a channel or a private conversation with another user.

Hitting **up** and **down** arrows will scroll through command history in the
input.

Hitting **page up** and **page down** will scroll through tab/channel message
history.

### Commands

- `/join <channel>` - join a channel. When channel tab is active, any input will
be sent to the channel using `PRIVMSG` command.
- `/part` or `/q` - leave currently opened channel/private conversation.
- `/msg <user> <text>` - private message to a user/channel. Creates a new tab
for the conversation if one doesn't exist yet.
- `/me <text>` - standard "emote" command.
- `/quit` - closes the connection and stops the program.
- `/mode <mode>` - standard IRC MODE command. The syntax is the same.
- `/kick <user>` - kick a user from a channel.

### Configuration

There are a few settings you can tweak. All settings are grouped in the
`SETTINGS` hashmap, just open the file and edit it as you like.

### Theme/colors

Look up styles and colors in the `SETTINGS` hash. For convenience, styles
reference the colors defined in the `Term` module at the beginning of the file.
Right now only `term16` colors are supported. I intend to expand it to `term256`
at some point.

### DCC

There's a basic DCC support, all `DCC SEND` requests are auto-accepted and saved
into the `download_dir` path defined in `SETTINGS` hash.

### TLS support

TLS support can be added by applying the 'patches/enable-tls.patch', or
executing `make tls`. It requires `openssl` gem.

### Unicode/Wide character support.

A basic support of CJK and other wide characters can be added by applying
'patches/unicode.patch' or executing `make unicode`. The patch requires
`unicode` gem.

### License

GNUGPLv3

