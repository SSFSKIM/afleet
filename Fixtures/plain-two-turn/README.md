# plain-two-turn

The baseline: two short prompts, no tools, two real assistant turns. Recorded against
`claude` 2.1.260 under the scratch config home of §4.6. Serves acceptance items 1, 2, 31
and 56 and C3.G1, and it is the session `resume-no-replay` resumes.

## What the recording shows

Each prompt produces `command_lifecycle` queued/started, a `system/init`, a
`system/status requesting`, `transcript_mirror` frames, the replayed `user` frame, one or
more `assistant` messages and a `result success`. The replies are exactly `one` and `two`.
Seven `transcript_mirror` frames carry the session's 31 transcript records, and every
mirrored entry reproduces the file — this is the first fixture with real assistant turns,
so it is the first real test of the mirror-fidelity check, and it passes.

`system/init` is emitted at the **start of each turn**, not once at the handshake. That is
why a scenario cannot read `system/init.tools` before sending its first prompt, and it is
worth knowing before modelling the frame as session-scoped.

## Reading it

`initial/` and `artifacts/` are empty and hold only their `.gitkeep`; the scenario resumes
nothing and no frame names an artifact. `streams.json` is `{}` for the same reason — it
records the sizes of streams that existed at spawn, and none did.

The transcript is a good deal more than the four records the two exchanges suggest. Nine
distinct `attachment` kinds appear — `environment`, `model`, `deferred_tools_delta`,
`agent_listing_delta`, `skill_listing`, `total_tokens_reminder`, `session_context`, `date`,
`prompt_snapshot` — alongside `queue-operation`, `file-history-snapshot`, `atis-latch`,
`ai-title` and `last-prompt`. A consumer that models a transcript as user and assistant
records will drop most of the file.

The `environment` attachment records the working directory as
`/private/tmp/afleet-fixtures/plain-two-turn`, the resolved form of the scratch cwd and the
path the project slug is derived from. Nothing here comes from a real project. The
`session_context` attachment's `userEmail` and one `system-reminder` render are redacted to
`<email>`, and the redaction touched only the address.

**This fixture costs money to re-run.** It is `census: true` and `deterministic: false`, so
`make probe` re-runs it against the live binary and spends two `haiku` turns — about one US
cent — every time the drift ritual runs. That is the design §4.7 asks for; it is recorded
here so the cost is not a surprise.

Recorded on 2.1.260 rather than the 2.1.259 baseline the earlier fixtures carry, because the
CLI was upgraded between waves. The flag set `claude --help` declares is identical across
the two.
