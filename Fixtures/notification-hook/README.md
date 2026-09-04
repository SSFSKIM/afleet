# notification-hook

The `Notification` hook, registered through `initialize.hooks` as `afleet.notification`,
firing while a `can_use_tool` permission ask is left unanswered. Recorded against the pinned
baseline `~/.local/share/claude/versions/2.1.259` on 2026-09-04, session
`c16c57e7-5cc9-4d8f-98bc-d632e92b09c3`, `--max-turns 3`, `haiku`, config-home isolation,
exit 0. Serves acceptance item 53; it is S18's evidence.

**It fires, and quickly.** The `can_use_tool` for `Write` arrives at t=3595 ms and the
`hook_callback` at t=9601 ms, so the idle threshold that raises the notification is **about
six seconds** — the scenario's 75-second budget was never approached and the ask waited 6.1 s
of it. The scenario then allowed the tool and the session ended `result/success`.

**The callback and its input.** One `hook_callback` in the whole capture, `callback_id`
`afleet.notification` (the `ConfigChange` hook registered in the same handshake never fired,
which is why the scenario keys on the id rather than taking the first callback). Its `input`
has seven fields:

```json
{"session_id": "…", "transcript_path": "…/projects/<slug>/<session>.jsonl",
 "cwd": "/private/tmp/afleet-fixtures/notification-hook",
 "prompt_id": "be2e27c3-…", "hook_event_name": "Notification",
 "message": "Claude needs your permission to use Write",
 "notification_type": "permission_prompt"}
```

`message` is the notification text ready to display and `notification_type` classifies it, so
a host has everything it needs for a native banner without correlating back to the ask —
though `prompt_id` and `session_id` are there if it wants to. `transcript_path` is an absolute
path rooted at the config home, not a token.

**The answer is accepted.** The host replied `{"continue": true}` and the CLI emitted no error
frame and no second request; the identical body travelling back out is the
`--replay-user-messages` echo every recording in this corpus carries.

69 frames, a 29-record main transcript reproduced by its mirror exactly, and nothing under
`initial/` or `artifacts/`.
