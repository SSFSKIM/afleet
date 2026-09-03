# C1: Probe suite, golden fixtures and fake-claude (2026-09-04)

> **Parent:** `2026-09-03-afleet-workspace-design.md §17 C1`. **Parent-pin:**
> `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md` at commit `9fd067c`.
> **Level:** wave-1 leaf of the afleet v1 roadmap, controlled track. **Branch:**
> `child/c1-probes-fixtures`, worktree `afleet-c1`; merges to `main` when G1 through G4
> pass. The parent's C1 section, §17.3 authority grades and contracts X8 and X9 are
> pre-landed here and are not re-litigated; this document settles only the residue.

## 1. Purpose

Every other child of the roadmap tests against evidence that this child produces. C1
turns the fourteen ad hoc scripts in `probes/` into the drift ritual the parent's §6.10
describes, records the golden fixtures every reducer, card and panel is tested against,
ships the `fake-claude` replayer that lets UI tests run without spending a token, and
answers the protocol spikes the parent delegated to it. After C1 lands: `make probe`
tells the team in under a minute whether the installed CLI still speaks the protocol the
app was built against; `Fixtures/` holds redacted, reviewed recordings that pair every
wire stream with the transcript the CLI wrote for it; `fake-claude` replays any of them
at any speed with any frame injected; and the parent's Revision Notes carry a dated
finding for each of S5, S6, S8 and S10 through S18. No other child asks the CLI a
question to learn a protocol fact.

## 2. Scope

**In:** `Tools/probe/` (census, record, snapshot, redact, verify, diff) and the root
`Makefile` targets that drive it; `Tools/fake-claude/`; `Fixtures/` with its review
checklist; the recording scenarios that produce G1's fixture list; the spike scenarios
and their findings; unit tests for the tools. **Out:** any Swift code (C2 owns the first
package); fixtures for acceptance items the G1 list does not name, which later children
record with the same tools when they need them; a hosted or continuous run of `make
probe`, which stays an on-demand ritual; and any write under Claude Code's config home
by anything in `Tools/`.

## 3. Grounding

The fourteen probes share one shape: a `subprocess.Popen` of the launch line, a reader
thread appending decoded frames to a list, `send` helpers for `user` frames and control
requests, an inline `can_use_tool` auto-allow, and ad hoc prints. Probes 05 through 11
already write an `OUT`/`IN` line log, which is the direct ancestor of the fixture format
below. Probe 04 computes a census of type and subtype counts; probes 10 and 11 print
per-run censuses. The evidence directory holds a redacted `system/init` frame, a set of
zero-cost control responses with the settings body removed by hand, and three prose
captures. The installed CLI is 2.1.259; `claude --help` lists 70 distinct flags. Python
3.14 is on `PATH` through Homebrew and the system `python3` is 3.9.6; GNU Make 3.81 is
present. `bun` and `node` exist but nothing here needs them. The repository's
`.gitignore` already excludes `/Fixtures/**/*.secret*`.

## 4. Design

### 4.1 Layout and language

```
Makefile                      probe, record, redact, verify-fixtures, test-tools
Tools/probe/probe.py          one CLI, subcommands below; Python 3.9+, stdlib only
Tools/probe/harness.py        launch line builder, frame reader, control correlation,
                              auto-answer policies, mini MCP server for S5
Tools/probe/census.py         census computation and diff
Tools/probe/redact.py         redaction rules, manifest, verifier
Tools/probe/scenarios/<name>.py   one recording or spike scenario each
Tools/probe/tests/            unittest suite for census, redaction, harness, fake-claude
Tools/fake-claude/fake-claude     executable replayer; Python 3.9+, stdlib only
Tools/fake-claude/tests/
Fixtures/<name>/              one directory per fixture (§4.4)
Fixtures/REVIEW.md            the second-review checklist (G4)
```

Both tools are Python with the standard library only, compatible with the system 3.9 so
they run on a machine with nothing installed. Python is chosen over Swift because the
probes are already Python and move in with a mechanical refactor, because `fake-claude`
must not depend on `ClaudeWire` (C2 tests against it, so a shared Swift package would
make the fixture layer depend on the code it validates), and because a script starts in
tens of milliseconds, which is what a UI smoke test wants from a fake engine. The tools
never import each other's internals: `fake-claude` reads the fixture format and nothing
else, so it can be rewritten in another language without touching `Tools/probe`.

### 4.2 The probe CLI

`Tools/probe/probe.py <subcommand>`:

- `census [--claude <path>] [--scenario <name>...]`: runs the zero-cost census (an
  `initialize`, the zero-cost control requests probe 04 already sends, `claude --version`
  and the flag list from `claude --help`) and, for each named scenario whose metadata
  says `census: true`, re-runs the scenario against the given binary and computes its
  census. Prints the censuses as JSON.
- `diff [--claude <path>]`: runs `census` for every fixture marked `census: true` and
  compares each result with the census stored in the matching fixture. Exit status is
  the number of drifted fixtures, capped at 125; output lists, per fixture, added and
  removed `(type, subtype)` pairs, changed top-level key sets per pair, changed
  `capabilities`, and added or removed flags. This is what `make probe` runs.
- `record <scenario> [--claude <path>] [--out Fixtures/<name>]`: runs one scenario
  through the harness, writes the raw capture to `Fixtures/<name>/raw/` (ignored by git
  through a `.gitignore` inside `Fixtures/` that excludes every `raw/` directory), then
  runs `snapshot`, `redact` and `verify` in sequence and leaves the reviewer with the
  redacted fixture plus a `redaction.json` manifest.
- `snapshot <fixture>`: copies the session's transcript files out of the config home the
  scenario used into `Fixtures/<name>/transcript/` (§4.4), rewriting the project slug.
- `redact <fixture>`: applies the rules of §4.5 in place, idempotently, and writes the
  manifest.
- `verify <fixture>...`: runs the scanners of §4.5 against everything in the fixture and
  fails on any hit; also checks the fixture's structural invariants (every `in`
  control_response has a preceding `out` control_request with that id and vice versa,
  timestamps are non-decreasing, `census.json` matches a recount of `frames.ndjson`).
  `make verify-fixtures` runs it on every fixture and is the pre-commit check.

Every subcommand takes `--claude <path>` and honours `AFLEET_CLAUDE_BINARY`; `make probe
CLAUDE=Tools/fake-claude/fake-claude FIXTURE=<name>` is how item 32's second half runs.

### 4.3 The harness

`harness.py` is the one place the launch line lives on the tooling side. It builds the
parent's §6.1 line from a `Launch` dataclass (session id or resume id, model, permission
mode, extra flags, environment table) and refuses to build a line that omits
`--permission-prompt-tool stdio`, so no scenario can accidentally record a denial
session. It sends the parent's §6.2 `initialize` payload by default and lets a scenario
override it. It correlates control requests by `request_id`, exposes
`request(subtype, **payload)` returning the response, and implements three answer
policies a scenario picks per request kind: `allow` (echo `updatedInput`), `deny`
(fixed message), and `script` (a callable). Its default handler for any inbound request
it does not know is the parent's §6.3 answer, an immediate error naming the subtype,
so recordings exhibit the same behaviour the app will. It embeds a minimal in-process
MCP server for `sdkMcpServers: ["afleet"]`: it answers the JSON-RPC `initialize`,
`tools/list` with one tool, `send_user_file {path}`, and `tools/call` by returning the
file's bytes as a resource, which is exactly what S5 needs to observe and what C2 will
implement in Swift. Every frame in both directions is appended to the raw capture with
a monotonic timestamp before anything else looks at it.

### 4.4 Fixture format (contract X8, concrete)

```
Fixtures/<name>/
  fixture.json        metadata: name, purpose, recorded_at, cli_version, launch (the
                      exact argv and environment table), prompts, serves (acceptance
                      items and spikes), census: true|false, synthetic: true|false,
                      review: {reviewer, date, checklist_version}
  frames.ndjson       one JSON object per line: {"t": <ms since first frame, int>,
                      "dir": "out"|"in", "frame": {...}}; "out" is CLI to host, "in" is
                      host to CLI; both directions are recorded so replay can wait for
                      the host
  transcript/         the session's files copied from <configHome>/projects/<slug>/:
                      <sessionId>.jsonl, <sessionId>/ (subagents, tool results), and
                      sidecars named <sessionId>*; paths are relative to projects/ and
                      the slug is replaced by the literal directory name `_slug_`, with
                      the original cwd recorded in fixture.json so fake-claude can
                      rewrite it
  census.json         the census of frames.ndjson plus the flag list and version at
                      recording time
  redaction.json      the manifest: each rule applied, the field paths it touched and
                      how many times; a fixture with an empty manifest is still valid
  README.md           optional prose about what the recording shows
```

Timestamps are relative and integer milliseconds because replay only needs deltas and
absolute times are a redaction hazard. Session ids stay as recorded because the
transcript snapshot, the `filePath` fields inside `transcript_mirror` frames and the
registry semantics all key on them. The census is a set-based structure: for each
`(type, subtype)` pair, the union of top-level keys seen, the count seen (informational,
never compared, because model output varies between runs), the `capabilities` object
from `system/init`, the CLI version and the sorted flag list. Comparison uses the pair
set, the key sets, the capabilities and the flags; counts are printed, not diffed.

A `synthetic: true` fixture is hand-written from the bundle's schemas rather than
recorded, is excluded from `diff`, and is allowed only for wire paths that cannot be
provoked on demand (§4.7 names them). Everything else is recorded.

### 4.5 Redaction and review

Redaction rules, applied to `frames.ndjson`, every file under `transcript/` and
`census.json`, in this order, each recorded in the manifest:

1. Account and identity: `account`, `apiKeySource` values other than `none`,
   `subscription_type`, `organization`, `user` and `email`-named fields anywhere are
   replaced by typed placeholders (`<account-uuid>`, `<email>`), and any string matching
   an email address anywhere becomes `<email>`.
2. Secrets: any field whose name contains `token`, `oauth`, `key`, `secret`,
   `credential`, `authorization` or `cookie` is replaced by `<redacted>`; any string
   matching `sk-ant-`, a JWT shape, or a 32-plus character hex or base64 run inside a
   URL query is replaced likewise; `update_environment_variables` frames are dropped
   whole with a tombstone line `{"t":..,"dir":"out","dropped":"update_environment_variables"}`.
3. Paths and host: the recording user's home directory becomes `~` in every string; the
   hostname, if it appears, becomes `<host>`; the scratch cwd is kept because it is
   synthetic and the transcript slug depends on it.
4. MCP bodies: `mcp_message` request and response bodies longer than 4 KB are truncated
   with a `"truncated": <bytes>` marker.
5. Settings bodies: `get_settings` responses keep their key lists and the `applied`
   object and drop every value, matching the evidence file already committed.
6. OAuth flow: `claude_authenticate` and `claude_oauth_*` responses keep their shape with
   URL query strings replaced by `<redacted>`.

`verify` re-scans for every pattern above and for two more that only a human can judge
in context, which it reports rather than fails: a proper name that matches the git
author and any string of the form `/Users/<x>` that is not `~`. `Fixtures/REVIEW.md` is
the human half: read `fixture.json`, grep `frames.ndjson` and the transcript for the
author's name and email, open every `tool_result` and transcript `attachment` record
and confirm the content came from the scratch repository, confirm the manifest lists
each rule, and sign the `review` block. A fixture without a signed review block fails
`verify`, so nothing unreviewed can be committed by accident.

The recording rule that makes review tractable: **scenarios run in a purpose-built
scratch repository with synthetic content**, created fresh under
`/tmp/afleet-fixtures/<name>/` by the scenario itself, so every file the model reads
and every path it touches is synthetic.

### 4.6 Recording isolation

Two isolation levels, chosen per scenario in `fixture.json`:

- **Setting isolation**, the default: the real config home, `--setting-sources ""` so no
  user allow rule silently approves a tool, `--strict-mcp-config` so no user or project
  MCP server joins the census, model `haiku` unless the scenario says otherwise,
  `--max-turns` set per scenario. This is the configuration this session's probes used
  and it is known to work with the machine's login.
- **Config-home isolation**, preferred once the login question at the gate is settled:
  `CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home`, a scratch home logged in once
  by hand, so recordings leave nothing in the real `~/.claude`, the census sees no user
  plugins, skills or memory files, and S13's trust write and S17's agent definitions
  land in a throwaway `.claude.json`. The harness never writes into either home; the CLI
  does what it does.

Both levels use a fresh scratch cwd per recording. Nothing in `Tools/` ever deletes or
edits files under either config home, including the probe sessions' own transcripts;
the scratch home is deleted as a whole by the person who created it when they choose.

### 4.7 Scenario catalogue

Each scenario is a file under `Tools/probe/scenarios/` that declares its metadata and a
`run(harness)` function. G1's fixture list maps to these recordings, all under the
parent's launch line with `--session-mirror` present:

| Fixture | Scenario | Serves |
|---|---|---|
| `plain-two-turn` | two short prompts, no tools | items 1, 2, 31, 56; C3.G1 |
| `permission-allow` | Write in the scratch cwd, answered allow | items 4, 5; C2.G2 |
| `permission-deny` | same prompt, answered deny with a message | item 41 |
| `ask-user-question` | a prompt that makes Claude ask, answered through `updatedInput.answers` | item 6, 57 (with S15) |
| `exit-plan-mode` | `--permission-mode plan`, a plan, approved with `setMode` | item 7 |
| `explore-depth-1` | one Explore agent | items 9, 38, 49; C3.G3 |
| `nested-depth-2` | a general-purpose agent that spawns Explore (S16) | items 49, 52 |
| `background-shell` | `run_in_background` Bash, the `task_notification` and the auto-turn | items 61, 15's data; C3.G3 |
| `session-mirror-relocation` | two turns, `set_cwd` to a trusted sibling, two more, resume, one more (S14) | items 56, 64; C3.G3, C3.G4 |
| `send-user-file` | the in-process MCP round trip (S5) | item 29; C2.G3 |
| `control-shapes` | `apply_flag_settings {effortLevel}` with readback, `rewind_conversation`, `set_cwd` needing trust, `claude_authenticate` family shapes (S8) | items 11, 13; C4.G4 |
| `resume-no-replay` | `--resume` of `plain-two-turn`, `initialize`, six idle seconds | item 1; S2's record |
| `dialog-refusal-fallback` and `dialog-fable-overage` | **synthetic** (S6): every result value, the close path, the tombstones after a refusal, `model_consent_fallback`, `overagesEnabled` both ways, an undeclared kind left to `control_cancel_request` | item 62 |
| `notification-hook` | `Notification` registered through `initialize.hooks`, a permission ask left waiting past the idle threshold (S18) | item 53 |

Spikes without a fixture of their own produce findings only: S10 (`-p -w probe-wt`),
S11 (`--resume-session-at` inclusivity), S12 (a second holder against a registry record;
needs a pseudo-terminal for the interactive `claude --resume`, which the harness opens
with `os.openpty`), S13 (`set_cwd` with `trust_accepted` under the scratch config home),
S15 (the accepted values of `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT`, found first in the
bundle source and then confirmed on a recorded `ask-user-question`), S17
(`apply_flag_settings {agent}` then a turn; then `--resume` of an `--agent` session with
an `initialPrompt`, with the agent defined in the scratch cwd's `.claude/agents/`).

Recording is a deliberate act: `make record SCENARIO=<name>` runs one scenario; the
unit tests never touch a live binary. Everything records on `haiku` with `--max-turns`
between 2 and 6; a full re-record of the catalogue is about twenty short sessions,
which is the price of a baseline bump.

### 4.8 fake-claude

`Tools/fake-claude/fake-claude` is launched by the app or a test with the real launch
line; it accepts and ignores every CLI flag and reads its own configuration from the
environment, because the caller controls argv:

| Variable | Meaning |
|---|---|
| `FAKE_CLAUDE_FIXTURE` | fixture directory to replay (required for a session) |
| `FAKE_CLAUDE_SPEED` | speed factor; `0` means no delays, `1` real time, `10` ten times faster |
| `FAKE_CLAUDE_INJECT` | path to a JSON list of `{"at": <ms> | "after": <out-frame index>, "frame": {...}}` |
| `FAKE_CLAUDE_INIT` | path to a JSON object that replaces the recorded `initialize` response |
| `FAKE_CLAUDE_CONFIG_HOME` | when set, the transcript snapshot is materialised there before replay and appended in step with `transcript_mirror` frames |
| `FAKE_CLAUDE_VERSION` | what `--version` prints; defaults to the fixture's recorded version |

Replay is reactive, not a timed dump. The replayer walks `frames.ndjson`: an `out` line
is emitted after its delta from the previous line, scaled by the speed factor; an `in`
line blocks until the host sends a frame that matches it, where a `control_response`
matches by `request_id`, a `user` frame matches any `user` frame (the text is not
compared, and a mismatch is logged to stderr), and a host `control_request` matches by
subtype, after which the replayer emits the recorded response with the host's
`request_id` substituted. A host request the fixture never saw gets a generic success
response, or the recorded shape from another fixture when `FAKE_CLAUDE_INIT` style
overrides are given; an `interrupt` is answered with success and replay continues,
which is a stated limitation. `--version` prints the version; `--help` prints the flag
list from the fixture's census so a census run against fake-claude sees the recorded
flags. After the last line the replayer waits for stdin to close or `end_session`, then
exits 0; a closed stdin mid-replay exits 0 immediately, like the CLI. Injected frames
are emitted at their time or after the numbered `out` frame, unchanged, which is how
item 32's invented frame type and the malformed-payload items of §14 are produced.

`fake-claude materialize <fixture> <configHome> [--cwd <path>]` copies the transcript
snapshot into `<configHome>/projects/<slug-of-cwd>/`, rewriting `_slug_` and the `cwd`
fields inside the records, so a channel opens with history before anything is replayed.
During replay with `FAKE_CLAUDE_CONFIG_HOME` set, each `transcript_mirror` frame's
`entries` are appended to the materialised file at the moment the frame is emitted, so
the file watcher and the mirror agree, which is what C3.G4 and item 56 exercise.

### 4.9 Findings flow back

Each spike ends with a dated Revision Note appended to the parent document's Revision
Notes in this branch, prefixed `C1/S<n>:`, naming the clause it settles in the words the
parent's C1 section uses (S14's build-flag promotion, S17's restart rule, S15's
environment value, S13's `/cd` trust dialog, S12's Contended wording, S10's *New
isolated session*, S11's *Fork from here*, S18's hook input shape, S5's mechanism, S6's
payload shapes, S8's request and response shapes). A finding that contradicts binding
content is also written as `[parent-impact]` in this document's Surprises section with
the affected clause; C1 never edits binding design prose, and the parent's tending
session reconciles it at merge. Findings live on the branch until the merge carries
them to `main`; a Revision Note tail conflict at merge is resolved by keeping both.

### 4.10 Testing the tools

`make test-tools` runs `python3 -m unittest discover Tools`: census computation and
diff on synthetic frame lists (added pair, removed pair, changed key set, changed flag,
count changes ignored); redaction on a crafted fixture containing every pattern, with
idempotence (`redact(redact(x)) == redact(x)`) and manifest counts; the harness's answer
policies and unknown-request error against an in-process fake stream; fake-claude
replaying a tiny hand-written fixture against a test host that answers `can_use_tool`,
checking order, blocking on `in` lines, injection at time and index, `--version`,
`--help`, and materialise-plus-append. These tests are C1's own; the parent's item 36
runs them as part of the repository's test target once C5's project exists, and until
then `make test-tools` is the gate.

## 5. Acceptance

Restated from the parent's C1 section as observable behaviour; G1 through G4 are
required.

- **G1 Fixtures.** `Fixtures/` contains the thirteen recorded fixtures and two synthetic
  ones of §4.7, each with a signed review block, and `make verify-fixtures` exits 0.
  Each fixture's `frames.ndjson` contains `transcript_mirror` frames and its
  `transcript/` holds the matching session file; `nested-depth-2` holds two subagent
  files and their `.meta.json`; `background-shell` holds the task output file path
  inside its `task_notification`.
- **G2 Census.** `make probe` against the installed 2.1.259 exits 0 and prints a zero
  diff for every `census: true` fixture. `make probe CLAUDE=Tools/fake-claude/fake-claude
  FIXTURE=plain-two-turn` with an injection file adding a frame of type
  `afleet_invented` exits 1 and prints exactly one added pair.
- **G3 Findings.** The parent document in this branch carries a dated `C1/S<n>:`
  Revision Note for each of S5, S6, S8, S10, S11, S12, S13, S14, S15, S16, S17 and
  S18, each naming the clause it settles, and this document's Surprises section names
  any `[parent-impact]`.
- **G4 Redaction.** `Tools/probe/redact.py` exists and is what `record` runs;
  `Fixtures/REVIEW.md` exists; `verify` fails a fixture whose review block is unsigned
  and one that contains a planted email address, and passes every committed fixture.
- **Tool tests.** `make test-tools` passes on the system `python3` (3.9) and on 3.14.

## 6. Edges and contracts

- **Blocked by:** nothing.
- **Blocks:** C2.G2 (every fixture decodes), C3.G1 (the differential test), C6's
  fixture-driven gates, and every child whose spike C1 answers (S14 and S17 for C4's
  restart rule, S15 for C6's question card, S16 for C6's Agents leaf, S18 for C5's
  notification route, S10 through S13 for C4).
- **Owns:** X8, the fixture and fake-claude format of §4.4 and §4.8. Changes after the
  first consumer lands need a Revision Note here and on the parent; additive fields
  are free.
- **Bound by:** X9. Nothing in `Tools/` writes under a config home; fixtures are
  redacted and reviewed before commit; `submit_feedback` is never sent by any scenario;
  the typings are never committed (C1 does not fetch them at all).

## 7. Delegated unknowns

Empirical residue that execution answers, not this document: whether a scratch
`CLAUDE_CONFIG_DIR` shares the machine's keychain login or needs its own (settled by the
first recording under it); whether the idle threshold for the waiting-permission
notification can be reached inside a scenario's budget or needs a setting (S18);
whether `os.openpty` is enough for the interactive `claude --resume` in S12 or the
scenario must drive `script(1)`; and the exact byte budget at which a fixture's raw
capture becomes unwieldy in git, which sets the truncation rule for long
`stream_event` runs if one is ever needed (none is expected at `--max-turns` 6).

## 8. Questions for the human gate

Each with the recommendation the plan will follow unless overruled.

1. **Recording home.** Record under a dedicated scratch config home that you log into
   once by hand (recommended: keeps probe sessions out of your real history and keeps
   your plugins, skills and memory files out of the census), or under the real config
   home with setting sources disabled, which needs no login step but leaves about twenty
   probe transcripts under `~/.claude/projects` that afleet will later list as archived
   channels of `/tmp` projects.
2. **Synthetic dialog fixtures.** Allow hand-written fixtures for the two dialog kinds,
   marked `synthetic: true` and excluded from the census (recommended: neither a
   refusal fallback nor the overage prompt can be provoked on demand), or keep S6 open
   until one occurs naturally in a capture.
3. **OAuth shape capture.** Let the `control-shapes` scenario call `claude_authenticate`
   to capture the response shape and then abandon the flow (recommended: harmless, the
   URLs are redacted, no login completes), or model those shapes from the bundle source
   only.
4. **Tooling language.** Python 3 standard library for both tools (recommended, §4.1),
   or Swift executables in a `Tools` package for a single-language repository at the
   cost of a build step and a dependency direction that has to be policed.

## Decision Log

- Decision: Python 3 standard library, compatible with the system 3.9, for `Tools/probe`
  and `Tools/fake-claude`.
  Rationale: The probes are Python and move in mechanically; fake-claude must not depend
  on ClaudeWire; a script starts fast enough for UI smoke tests; nothing to install.
  Rejected: Swift executables (build step, dependency direction to police); TypeScript
  on bun (would tempt a runtime dependency on the all-rights-reserved typings).
  Date/Author: 2026-09-04 / Claude for kimmi

- Decision: Fixtures record both directions with relative millisecond timestamps, and
  replay is reactive, blocking on recorded host inputs.
  Rationale: A timed dump cannot wait for a permission answer or a second prompt; the
  probes' `OUT`/`IN` logs already have this shape. Rejected: outbound-only fixtures with
  scripted pauses; absolute timestamps.
  Date/Author: 2026-09-04 / Claude for kimmi

- Decision: The census compares sets (type and subtype pairs, key sets, capabilities,
  flags) and prints counts without comparing them.
  Rationale: Model output varies run to run, so counts would produce false drift; the
  drift signal is a new or vanished shape. Rejected: count-exact censuses; a single
  committed baseline file separate from the fixtures.
  Date/Author: 2026-09-04 / Claude for kimmi

- Decision: fake-claude takes its configuration from environment variables and ignores
  argv; `--version` and `--help` answer from the fixture.
  Rationale: The app controls argv with the real launch line; the version gate and the
  census must see plausible answers. Rejected: a custom argv the app would have to
  special-case.
  Date/Author: 2026-09-04 / Claude for kimmi

- Decision: fake-claude materialises the transcript snapshot and appends mirror entries
  in step with `transcript_mirror` frames when a config home is given.
  Rationale: The app renders history from the file and C3 arbitrates mirror against
  file; a replay that produced frames without the file would test half the reducer.
  Rejected: fixtures that ship only frames; a separate file-writer tool.
  Date/Author: 2026-09-04 / Claude for kimmi

- Decision: Scenarios run in a fresh synthetic scratch repository, with setting
  isolation by default and config-home isolation preferred once the login question is
  settled.
  Rationale: Redaction is tractable only when the model reads synthetic files; setting
  isolation is proven on this machine; config-home isolation keeps the census and the
  user's history clean. Rejected: recording in real projects; recording with the
  user's settings active.
  Date/Author: 2026-09-04 / Claude for kimmi

- Decision: Synthetic fixtures are permitted only for wire paths that cannot be
  provoked on demand, marked and excluded from the census, pending the gate.
  Rationale: The dialog cards need fixtures for every enum value and no live trigger
  exists. Rejected: leaving S6 unanswered; recording until a refusal happens.
  Date/Author: 2026-09-04 / Claude for kimmi

- Decision: Spike findings are dated `C1/S<n>:` Revision Notes on the parent in this
  branch, with `[parent-impact]` recorded here for anything binding.
  Rationale: The parent's G3 asks for Revision Notes on the parent; the branch is the
  only place C1 can write, and the merge carries them. Rejected: a findings file the
  tending session transcribes; editing binding prose from the child.
  Date/Author: 2026-09-04 / Claude for kimmi

- Decision: `verify` refuses fixtures without a signed review block.
  Rationale: The parent's redaction rule requires a second review; a mechanical refusal
  is the only way to make "reviewed before commit" a property rather than a habit.
  Rejected: a checklist alone.
  Date/Author: 2026-09-04 / Claude for kimmi

## Surprises & Discoveries

- Observation: The committed probe 10 never passes `--session-mirror`; it only listens
  for `transcript_mirror` frames. Evidence: `grep session-mirror probes/10-*.py` matches
  only the print statement. Impact: S14 needs a new scenario, as the parent already
  notes; the mirror flag has never been exercised in this repository.
- Observation: `claude --help` on 2.1.259 lists 70 distinct flags, and the parent's
  launch line uses one that `--help` omits (`--session-mirror`). Impact: the census
  records the flag list from `--help` and separately asserts acceptance of each launch
  flag by spawning with it, so hidden flags are covered.

## Outcomes & Retrospective

Pending — written at finish.

## Revision Notes

- 2026-09-04: v1, written at dispatch from the parent's §17 C1 at commit `9fd067c`.
