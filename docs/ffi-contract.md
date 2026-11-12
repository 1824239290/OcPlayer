# OcPlayer Core FFI contract

The public ABI is the C header in `include/ocplayer_core.h`. Calls use UTF-8 JSON
strings and return heap allocated strings owned by the caller. Every returned
string must be released with `ocp_string_free`.

`ocp_call` returns this envelope:

```json
{"ok":true,"code":0,"retryable":false,"message":"","data":{}}
```

The first event after creating a core is `core.ready`. Events are consumed in
FIFO order with `ocp_poll_event`; the function returns `1` for an event, `0`
when the queue is empty, and `-1` on an invalid call.

The initial P0 commands are `ping`, `core.getVersion`, `settings.get`,
`settings.set`, and the playback lifecycle commands. Playback commands are
currently accepted by the state machine and represented as events; media
engine integration is introduced in P1.

