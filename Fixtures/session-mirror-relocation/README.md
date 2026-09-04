# session-mirror-relocation

Two turns, a `set_cwd` into an untrusted sibling directory with the trust step completed,
then two more turns. Serves acceptance items 56 and 64 and C3.G3 and C3.G4; the
relocation half of spikes S13 and S14. The catalogue's relocation row is recorded as two
fixtures — this one and `session-mirror-resume` — because a fixture is one process and
the row's resume is a second one.

What it shows:

**The trust handshake (S13).** `set_cwd {path}` into a directory the scratch config home
has never seen answers `success` with `{"status": "needs_trust", "directory": "<the
resolved path>"}`. Repeating the call with `trust_accepted: true` alone is **refused**:
the CLI answers the error `set_cwd: invalid request — trust_accepted requires
trusted_directory (echo the directory from the needs_trust response)`. The accepted form
carries both, and the echoed directory is the resolved one the first answer named — which
is what stops a host granting trust to a directory other than the one it was asked about.
The complete call answers `{"status": "ok", "cwd", "changed": true,
"transcript_relocated": true}`, and the scratch `.claude.json` afterwards holds
`hasTrustDialogAccepted: true` for the sibling, keyed by the **resolved** path.

**The relocation moves the transcript (S14).** `transcript_relocated: true` is literal.
The session's JSONL file is moved out of `projects/<old slug>/` and into `projects/<new
slug>/`, keeping its session-id file name. So one session file is named by two paths
across one recording: the mirror frames before the relocation carry the old path and the
ones after carry the new one, and the old path holds no file at all by the end. The
fixture's `transcript/_slug_/<session>.jsonl` is that one file at its final location, and
its records carry both `cwd` values.

**The mirror survives it.** No `mirror_error` frame is emitted, and `verify`'s
mirror-fidelity check passes: the mirrored entries from both paths, concatenated in frame
order, reproduce the 53 records of the final transcript exactly. `verify` was taught to
follow the move for this fixture — it keys a mirrored stream by the transcript file the
name resolves to rather than by the path alone.

**A relocation emits a `result` frame of its own.** `subtype: "success"`, `num_turns: 0`,
an empty `result`, for a turn nobody sent. A host tracking turn completion off `result`
frames will see one arrive with no prompt behind it; the scenario drains it explicitly,
and the note records that it did.

The sibling directory is named after the session id so that every run of this scenario
relocates into a directory the scratch config home has never trusted. A fixed name would
be trusted from the first recording onwards and the drift ritual would compare a
needs-trust answer against a trusted one.

Recorded on 2.1.259 under the scratch config home, model `haiku`, `--max-turns 4`; all
four turns end `result/success` and the session exits 0. `initial/` is empty because the
session is new, `artifacts/` because nothing was written outside the transcript, and
`streams.json` is `{}` for the same reason as `initial/`.
