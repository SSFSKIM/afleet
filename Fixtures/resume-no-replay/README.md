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

**A resume writes exactly one transcript record.** `initial/` holds the 31 records the
session had at spawn and `transcript/` holds 32; the one added is a `mode` record, and the
single `transcript_mirror` frame carries exactly that one entry. So a resume is not silent
on disk — it appends — but what it appends is session state, not conversation.

## Reading it

This is the only fixture so far with a populated `initial/`, which makes it the one that
exercises §4.4's stream-offset contract end to end. `streams.json` records
`171903` for the stream, exactly the byte size of the file under `initial/`, and the file
under `transcript/` is 171991 bytes whose first 171903 are byte-identical. `verify` checks
that the final file extends the initial one from the recorded offset, and here it has
something real to check. `artifacts/` is empty and holds only its `.gitkeep`; `initial/` has
no placeholder because it has real content.

The fixture reuses `plain-two-turn`'s scratch cwd and session id, because the CLI derives
the transcript slug from the working directory and a resume that runs elsewhere is a
different project to it. Re-recording this fixture therefore requires re-recording
`plain-two-turn` first, or at least leaving its scratch directory intact.

The recording spends no model tokens: no turn begins, so there is no `result` frame at all.

Recorded on 2.1.260 rather than the 2.1.259 baseline the earlier fixtures carry, because the
CLI was upgraded between waves. The flag set `claude --help` declares is identical across
the two.
