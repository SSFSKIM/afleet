# resume-no-replay

S2's record. `--resume` of `plain-two-turn`'s session, the §6.2 `initialize` handshake, six
idle seconds, then close. Recorded against `claude` 2.1.260 under the scratch config home of
§4.6. Serves acceptance item 1.

## What the recording shows

**No history is replayed.** In the six seconds after the handshake the CLI emitted **zero**
`assistant` and zero `user` frames, though the resumed session's transcript holds 31
records including two complete exchanges. The whole capture is the `initialize` request and
its answer, the three `mcp_message` frames that bring the in-process server up, one
`auth_status`, the `end_session` exchange, and a single `transcript_mirror`.

That is the finding §7.3's record-reducer-primary design rests on: a host that resumes a
session and waits for the stream to tell it what happened will wait forever. History comes
from the transcript file, and only from there.

## The trailing `mode` record, and when the CLI writes it

A resume is not silent on disk. This one appends exactly one record —
`{"type": "mode", "mode": "normal", "sessionId": …}` — and the lone `transcript_mirror`
frame carries exactly that entry. It is session state, not conversation, and a host
watching the transcript across a resume must not mistake the append for history.

It is written **once per session, on that session's first resume, and never again.** That
was measured rather than assumed, with three experiments against this same session after it
had been resumed once:

- Resuming again and idling **fifteen** seconds — two and a half times the window this
  scenario uses — produced no mirror frame before or after close, and appended nothing.
- Closing the session did not flush one either: the count was zero both before and after
  `close()`.
- Resuming with a different `--permission-mode` (`plan` rather than the recorded `normal`)
  also appended nothing, so it is not a write-on-change of the mode itself.

In all three the transcript stayed at 32 records with exactly one `mode` record. So the
record is not written on a timer, not written at close, and not written when the mode
changes; it accompanies a session's first resume alone. The mechanism was not located in the
extracted bundle, so this is recorded behaviour rather than a reading of the source.

## Why `census: false`

**The scenario consumes its own precondition**, and that is why it cannot take part in the
drift ritual. `diff` re-runs a census scenario against the live binary, resuming the very
session named in `plain-two-turn`'s `fixture.json` — a session this recording has already
resumed. By the finding above, no second `mode` record is ever written for it, so no
`transcript_mirror` is emitted and the strict comparison reports `removed pair
transcript_mirror`. That is true of the run and says nothing whatever about the CLI.

Neither obvious repair works. Waiting for the mirror with a bounded timeout fails, because
on a re-run there is no mirror to wait for and the wait would expire every time. Closing
before the record can be written would make the census reproducible only by racing the other
way, and it would cost S2 its evidence: the six idle seconds *are* the finding, and a
shorter window proves less. Marking the fixture `deterministic: false` does not help either
— §4.4 has a removed pair alarm in required mode too, deliberately.

Restoring the precondition means recording a fresh `plain-two-turn` first, which is not
something a gate can do for itself. So the honest answer is the one `rate-limited-turn`
already uses in a milder form: **a scenario leaves the census when re-running it cannot be
expected to reproduce what was recorded.** There the precondition was an exhausted
rate-limit window nobody could arrange; here it is consumed by the act of recording.

## Reading it

This is the only fixture with a populated `initial/`, which makes it the one that exercises
§4.4's stream-offset contract end to end. `streams.json` records `171871` for the stream,
exactly the byte size of the file under `initial/`, and the file under `transcript/` is
longer by the one `mode` record, its preceding bytes identical. `verify` checks that the
final file extends the initial one from the recorded offset, and here it has something real
to check. `artifacts/` is empty and holds only its `.gitkeep`; `initial/` has no placeholder
because it has real content.

The fixture reuses `plain-two-turn`'s scratch cwd and session id, because the CLI derives
the transcript slug from the working directory and a resume that runs elsewhere is a
different project to it. Re-recording therefore means re-recording `plain-two-turn` first,
to get a session that has never been resumed, and then this one.

The recording spends no model tokens: no turn begins, so there is no `result` frame at all.

Recorded against the **pinned** 2.1.259 binary at
`~/.local/share/claude/versions/2.1.259`, which is the protocol baseline the parent declares
and the version C2 pins `ProtocolBaseline.version` to. The installed `claude` is 2.1.260;
the corpus stays at 2.1.259 deliberately, so that C1's evidence agrees with the declared
baseline and so that `make probe` against the installed binary is a real drift measurement
rather than a binary compared with itself. `launch.argv[0]` records the pinned path.
