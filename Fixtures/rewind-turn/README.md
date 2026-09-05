# rewind-turn

A resume of `plain-two-turn` that asks for a conversation rewind twice — once at a message
read out of the resumed transcript, which the engine refuses, and once at the message this
session itself sent, which it honours — with one short `haiku` turn between them. Recorded
2026-09-05 on 2.1.259 under the scratch config home, in the scratch cwd
`/tmp/afleet-fixtures/plain-two-turn`, session `8cc24a21-6251-4783-b526-3957214d26a6`.

Serves `C3.G1` and the parent's item 13 (*Edit and resend*), and is the corrective recording
C3 asked C1 for against parent §7.3.

## What it shows

**The refusal.** `rewind_conversation {target_message_uuid}` at the uuid of the resumed
transcript's first conversational `user` record answers with a **success envelope** carrying

```json
{"rewound": false, "prefillText": null, "precedingAssistantUuid": null, "error": "stale target"}
```

Nothing is written: settled reads either side of the request return the same 58 records. Note the shape: this is
`control_response {subtype: "success"}` with a body-level `error` string, not a
`control_response {subtype: "error"}`. A host that decides success from the envelope alone
reads a refused rewind as a completed one. The body also lacks `targetMessageUuid`, which the
honoured leg carries — the two bodies are not the same shape.

`control-shapes` recorded this request once, with `rewound: true` in its frames but nothing
about the effect on disk and no refusal to compare it against; this fixture records both legs
and what each one did to the file.

**The acceptance.** The same request at the uuid the host put on its own `user` frame answers

```json
{"rewound": true, "targetMessageUuid": "<the message this session sent>",
 "prefillText": "<that message's text>", "precedingAssistantUuid": "<the assistant record before it>"}
```

`prefillText` is the composer prefill §10 item 13 describes, returned by the engine rather
than reconstructed by the host.

**The divergence C3 needs.** After the honoured rewind the file holds 27 uuid-carrying
records and the current `last-prompt.leafUuid` is **record 24 of 27**: the leaf names
`precedingAssistantUuid`, the assistant record from *before* the rewound turn. The three
records the turn wrote — a `user` and two `assistant` — remain in the file below the leaf and
are unreachable from it by `parentUuid`. They are the abandoned branch, and nothing in the
file's order marks them as abandoned. A reducer that folds this file in order and shows the
last record shows a turn the conversation has discarded.

**The uuid contract.** The uuid the host puts on its outbound `user` frame is the uuid the
engine writes onto the transcript record. The scenario asserts this in `notes` because the
whole rewind mechanism depends on it: it is how a host names a message it wants to rewind to.

## Both rewinds emit nothing but their own response

The wire between each request and its response carries the request and the response and
nothing else — no `system` frame, no `transcript_mirror`, no `result`. The honoured rewind's
only effect visible outside the response is one appended `last-prompt` record, and it does
arrive mirrored.

## A `last-prompt` also arrives after `end_session`

The last frame in the recording is a `transcript_mirror` carrying one `last-prompt`, emitted
*after* the `end_session` response. It names the same post-rewind leaf, so the final
`transcript/` (66 records, 27 uuid-carrying) still shows the leaf at record 24 of 27 with the
same three-record abandoned branch below it — the divergence is the fixture's resting state,
not a mid-run moment.

The turn's *own* closing `last-prompt`, the one that would have named the turn's last
assistant, never appears in this recording at all: it was not there three settled seconds
after the `result`, the rewind wrote the next one, and the close wrote a second naming the
same leaf. So a consumer cannot treat "a `result` arrived" as "the turn's records are all on
disk", and a fixture that reads at `result` reports a race as a finding — the discarded first
recording of this fixture did exactly that. Whether the closing `last-prompt` would have
arrived on its own had no rewind intervened is not answered here.

## What this recording does not settle

Whether `stale target` is about the resume specifically or about any target outside the
messages the current process created, and whether `--fork-session` or `--resume-session-at`
changes the answer.

## One frame a reader will ask about

`frames.ndjson` carries a `rate_limit_event` during the turn with
`rate_limit_info.status: "allowed"` and the five-hour window at 0.02 utilisation. It is the
engine's informational report, not a rejection — `rate-limited-turn` is the fixture for a
turn the limiter refuses — and it records that this recording was made on a fresh window.

## Reading the transcript

`initial/` is the session as it stood at this spawn: 58 records, 24 of them uuid-carrying,
already holding **two** earlier turns from the discarded recordings of this fixture (one at
06:01:27 and one at 06:02:02), and two pairs of `bridge-session` records. Those turns are
ordinary history here — both are on the chain at the resume, and the file holds no abandoned
records at that point — and the recording's own appends begin after them, at the offset
`streams.json` names.
