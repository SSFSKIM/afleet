# session-mirror-resume

`--resume` of the session `session-mirror-relocation` recorded, after that session had been
relocated by `set_cwd`, plus one more turn. Serves acceptance item 64 and C3.G3; the
resume half of spike S14. The catalogue's relocation row is these two fixtures because a
fixture is one process and the row's resume is a second one.

What it shows:

- **A resume finds a relocated session.** The scenario's cwd is the *original* scratch
  directory, but the transcript now lives under the sibling's project slug. `--resume
  <session id>` resolves it anyway, so a host does not have to know where a relocated
  session's file went.
- **Nothing is replayed.** As `resume-no-replay` records for a plain session, the resume
  emits no history frames; the fixture's `initial/` holds the 64 records the session
  already had and `transcript/` holds 73.
- **The mirror keeps up across the resume.** The eight records the new turn appends all
  arrive mirrored, in order, and `verify`'s mirror-fidelity check passes.
- **One record per resume is written and never mirrored.** Exactly one record is appended
  at the head of the range before the mirror carries anything. On this recording, a later
  resume of the session, it is an `atis-latch`; on the same session's *first* resume it
  was an `ai-title` duplicating the title the session already had. The count is the stable
  fact, not the type, so `fixture.json` declares `unmirrored_prefix: 1` and `verify`
  checks that count exactly — a second unmirrored record still fails the gate, and a
  declaration nothing needs is reported as stale. This is the one place found so far where
  the CLI writes a transcript record it does not mirror, and it qualifies the wave-A
  observation that the CLI mirrors every record it writes.
- **No `mode` record.** This is not the session's first resume, and per wave A's finding
  only a first resume appends one.

Recorded on 2.1.259 under the scratch config home, model `haiku`, `--max-turns 2`; the
turn ends `result/success` and the session exits 0. `artifacts/` is empty.
