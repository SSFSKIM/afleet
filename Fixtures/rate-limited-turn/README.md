# rate-limited-turn

Two prompts the engine rejects before any model call, because the account's seven-day
usage window sits at 100 per cent. Recorded against `claude` 2.1.259 under the scratch
config home of §4.6. Serves acceptance item 21 (Activity shows a row for a rate-limit
event) and C2.G2 (every frame in every fixture decodes and re-encodes without loss), and
it is the only fixture that carries a `rate_limit_event`.

## Two things to know before you touch it

**This fixture is not re-recordable on demand.** Its precondition is a seven-day window
already spent. `make record SCENARIO=rate_limited_turn` against an account with quota left
will run two real turns and record something else entirely. Whoever needs to refresh it has
to wait for a window to be exhausted, which is not a state anyone can arrange politely.
That is also why it sits outside the census — see below.

**This is not `plain-two-turn`.** It superficially resembles it — two short prompts, no
tools — but nothing here reached a model, so it is evidence about rejection and about
nothing else. `plain-two-turn` remains **unrecorded**, and this fixture deliberately claims
none of its acceptance items (1, 2, 31, 56) and none of C3.G1. Do not substitute it.

## What the recording shows

Per prompt, in order: `command_lifecycle`, `system/init`, `system/status requesting`, a
`transcript_mirror`, then — on the **first** prompt only — a `rate_limit_event`, then a
replayed `user` frame, an `assistant` message, a second `transcript_mirror` and a `result`.

- `rate_limit_event.rate_limit_info` carries `status: "rejected"`,
  `rateLimitType: "seven_day"`, `overageStatus: "rejected"`,
  `overageDisabledReason: "out_of_credits"`, `isUsingOverage: false`, a `resetsAt` epoch
  and a `unifiedWindows` object keyed `five_hour` and `seven_day`.
- The **second prompt is rejected without a second `rate_limit_event`.** The event fires
  once for the session, not once per rejected turn, so a host that clears its banner on the
  next turn will clear it while the limit still applies. §8.4 says a banner stands "until
  the next event clears it", which this recording shows is not a per-turn signal.
- The reply is an `assistant` message whose `message.model` is the literal `"<synthetic>"` —
  the engine's own marker for a message no model produced, not a redaction placeholder.
  Its text is the limit notice.
- `result` is `subtype: "success"` with `is_error: true`, `duration_api_ms: 0` and zero
  usage. A rejected turn is **not** an error-subtyped result, so a host keying failure off
  `result.subtype` alone will read this as a clean turn.
- The session exits **1** after the second rejection.

**A rejected turn is written to the transcript.** Seventeen records land under
`transcript/_slug_/`, including both `user` prompts, both `<synthetic>` assistant replies,
the `attachment` records and `queue-operation`, `file-history-snapshot`, `atis-latch` and
`last-prompt`. Sixteen of them arrive mirrored across four `transcript_mirror` frames; the
seventeenth, `last-prompt`, is written at close. `initial/` and `artifacts/` are empty and
carry only their `.gitkeep`, and `streams.json` is `{}`, because the scenario resumes
nothing and no frame names an artifact.

## The one fixture not on the 2.1.259 baseline

Every other recorded fixture is pinned to `claude` 2.1.259, the protocol baseline the parent
declares. **This one is 2.1.260 permanently**, and that is not an oversight. It was recorded
in the window when the installed CLI had already been upgraded, and it cannot be re-recorded
on 2.1.259 or on anything else, because its precondition — a seven-day usage window sitting
at 100 per cent — is gone and is not something anyone can arrange. It also carries the
four-variable environment table that predates S15 settling
`CLAUDE_CODE_QUESTION_PREVIEW_FORMAT`, for the same reason.

Nothing rests on the difference. The fixture is `census: false`, so it never takes part in a
comparison against a binary, and it is evidence about one wire path — the shape of a rejected
turn — rather than about a version's frame inventory. A consumer should read its
`cli_version` and its `launch.env` as recorded rather than assuming the directory's.

## Why `census: false`

The drift ritual re-runs every census-participating scenario against the live binary. Once
the window resets this one would run two real turns and report the difference as enormous
drift — `make probe` failing for a reason that has nothing to do with the CLI changing,
which is exactly the kind of failure that teaches an operator to wave the gate through.
The fixture's precondition is not reproducible on demand, which is the property §4.7 uses
to keep synthetic fixtures out of the census; this one is genuinely recorded, so
`synthetic` stays `false`.
