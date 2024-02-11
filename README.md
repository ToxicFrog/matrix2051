# Matrix2051

This is a fork of [progval's Matrix2051](https://github.com/progval/matrix2051),
an IRC<->Matrix proxy which allows connecting unmodified IRC clients to Matrix.

It has been modified for my use cases, which mostly orient around using weechat
with a [custom script](./m51weechat.lua) as the client, and using matrix primarily
as a bridge to other protocols rather than as a chat system in its own right.

This is not production-ready; it is tested to a standard of "works on my machine",
and some of the changes made to improve it for my *specific* use cases may damage
its *general* usability.

## Changes

- Channels are not autojoined; normal IRC /join and /part commands are used to join or leave channels
- /mjoin can be used to join channels in matrix (you must still /join them afterwards to participate from IRC)
- /list is implemented and lists all channels the matrix server has synced
- `m.bridge` events are supported for bridged rooms, and the IRC channel name will be based on the bridge information when no matrix canonical alias is set for it
- bridged DMs will show up as channels with a `@` prefix

## Planned Changes

- improved support for DMs and threads
- improved rendering of emoji, blockquote, and spoilers
- client-side support for strikethrough and code blocks
- client-side support for replies, edits, and deletes, where possible
