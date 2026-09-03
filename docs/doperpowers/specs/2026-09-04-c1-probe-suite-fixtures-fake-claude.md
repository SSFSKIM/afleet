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
probe`, which stays an on-demand ritual; any unredacted capture on disk, even
git-ignored; and any write under Claude Code's config home by anything in `Tools/`.

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
  through the harness with the redaction rules of §4.5 applied to every frame in memory
  as it arrives, so no unredacted byte is ever written. The redacted stream is held in
  memory; a scenario that declares a large expected volume spills to a mode-0600
  temporary file in a private directory outside the worktree, deleted when the run ends.
  On completion it runs `snapshot`, assembles the fixture in a temporary directory and
  renames it into `Fixtures/<name>/` in one step, then runs `verify` and leaves the
  reviewer with the redacted fixture plus its `redaction.json` manifest. There is no
  `raw/` directory and no `.gitignore` exception for one.
- `snapshot <fixture>`: copies the session's transcript files out of the config home the
  scenario used into `Fixtures/<name>/transcript/` (§4.4), rewriting the project slug.
- `redact <fixture>`: applies the rules of §4.5 in place, idempotently, and writes the
  manifest.
- `verify <fixture>...`: runs the scanners of §4.5 against every file in the fixture and
  fails on any hit; also checks the structural invariants. Request lifecycles are
  checked as a state machine: every `control_request`, in either direction, must end in
  a `control_response` in the opposite direction with the same `request_id`, or, for a
  CLI-originated request, in a CLI `control_cancel_request` with that id, which itself
  needs no reply; a response arriving after a cancel is permitted only when
  `fixture.json` lists the id under `late_responses`. Timestamps are non-decreasing,
  `census.json` matches a recount of `frames.ndjson`, every `<artifacts>/` token in a
  frame or record resolves to a file under `artifacts/`, and `streams.json` offsets fall
  inside the corresponding files under `initial/`. `make verify-fixtures` runs it on
  every fixture and is the pre-commit check.

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
`notifications/initialized`, `ping`, `tools/list` with one tool, and `tools/call`. The
tool is `send_user_file {files: [string], caption?: string, status: "normal" |
"proactive", display?: "render" | "attach"}`, the schema of the built-in `SendUserFile`
that the parity inventory says a replacement must mirror
(`docs/tui-parity/areas/13-10-23-context-memory-session-tools.md`, the `SendUserFile`
rows) and the schema C2 implements in Swift; `tools/call` resolves each path against the
scratch cwd, requires that it exists, and returns a text result naming the files sent.
A JSON-RPC notification is answered, as the SDK does, with an outer `mcp_response` of
`{"jsonrpc":"2.0","result":{},"id":0}`. Every frame in both directions passes through
the redactor of §4.5 and is then appended to the in-memory capture with a monotonic
timestamp before anything else looks at it.

### 4.4 Fixture format (contract X8, concrete)

```
Fixtures/<name>/
  fixture.json        metadata: name, purpose, recorded_at, cli_version, launch (the
                      exact argv, plus the names and values of the child-environment
                      variables the parent's §6.1 table names — an allowlist, never the
                      full environment), prompts, serves (acceptance items and spikes),
                      census: true|false, synthetic: true|false, hypothesis: true|false
                      (a synthetic fixture whose shapes are not yet confirmed on the
                      baseline binary), late_responses: [request ids], review:
                      {reviewer, date, checklist_version}
  frames.ndjson       one JSON object per line: {"t": <ms since first frame, int>,
                      "dir": "out"|"in", "frame": {...}}; "out" is CLI to host, "in" is
                      host to CLI; both directions are recorded so replay can wait for
                      the host
  initial/            the transcript state at spawn, relative to projects/ with the slug
                      rewritten to `_slug_`: empty for a new session; for a resume, the
                      prior session files exactly as they were before the CLI appended
                      anything
  streams.json        per logical stream (the main <sessionId>.jsonl, each subagent
                      file, each sidecar), the byte offset at which the recorded appends
                      begin; zero for streams that did not exist at spawn
  transcript/         the final state of the same files after the last frame
  artifacts/          files the CLI wrote outside the transcript that a frame or record
                      names — background task output files under
                      /private/tmp/claude-<uid>/<slug>/<session>/tasks/ above all — each
                      stored under a tokenised relative path; the frames and records
                      carry `<artifacts>/<relative path>` in place of the absolute path
  census.json         the census of frames.ndjson plus the flag list and version at
                      recording time
  redaction.json      the manifest: each rule applied, the field paths it touched and
                      how many times; a fixture with an empty manifest is still valid
  README.md           optional prose about what the recording shows
```

Timestamps are relative and integer milliseconds because replay only needs deltas and
absolute times are a redaction hazard. Session ids stay as recorded because the
transcript snapshot, the `filePath` fields inside `transcript_mirror` frames and the
registry semantics all key on them. `initial/`, `streams.json` and `transcript/`
together let a replay reproduce the filesystem the app saw: the state at open, the
appends in order, and the state at the end, which is what the parent's append-range
invariant and C3's mirror tests compare against.

**The census** is a set-based fingerprint. For each frame it records the `(type,
subtype)` pair and the frame's top-level key set, and one level down per discriminated
payload: for `control_request` and `control_response` frames the key set of `request`
and `response` keyed by the request's `subtype`; for `assistant` and `user` frames the
key set of `message` and the set of content-block types; for `system` frames nothing
further than the frame's own keys, which already carry the payload. It also records the
`capabilities` object from `system/init`, the CLI version and the sorted flag list from
`claude --help`, and per-pair counts as information only. Comparison distinguishes two
kinds of scenario. Deterministic scenarios (the zero-cost census, `resume-no-replay`,
the control-shape probes) compare pair sets, key sets, capabilities and flags exactly.
Model-driven scenarios compare *required shapes*: the keys present in every recording of
that scenario, accumulated across re-recordings in `census.json`; they alarm on a removed
pair, a removed required key or a new pair, and never on an optional key or a count,
because the model's choices vary between runs. This nested, required-versus-optional
fingerprint extends the top-level-keys census the parent's §6.10 describes; the parent
records the extension as a Revision Note at merge.

A `synthetic: true` fixture is hand-written from schemas rather than recorded, is
excluded from `diff`, and is allowed only for wire paths that cannot be provoked on
demand (§4.7 names them). A synthetic fixture whose shapes have not yet been confirmed
against the installed baseline binary is also `hypothesis: true`; `verify` accepts it,
and every gate that rests on it stays provisional until the hypothesis flag is cleared
by evidence from the baseline (§4.7). Everything else is recorded.

### 4.5 Redaction and review

Redaction rules, applied to every file in the fixture — `frames.ndjson`,
`fixture.json`, everything under `initial/`, `transcript/` and `artifacts/`, and
`census.json` — in this order, each recorded in the manifest. They run in memory on each
frame as the harness receives it and on each file as `snapshot` copies it, so the first
byte written under `Fixtures/` is already redacted; `redact` re-runs them idempotently
on a committed fixture.

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

Two isolation levels, chosen per scenario in `fixture.json`; both run every scenario in
a fresh synthetic scratch cwd:

- **Config-home isolation**, the default (settled at the gate):
  `CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home`, a scratch home the user logs
  into once by hand before the first recording. Recordings leave nothing in the real
  `~/.claude`; the census sees no user plugins, skills or memory files; S13's trust
  write and S17's agent definitions land in a throwaway `.claude.json`. Setting sources
  default to `--setting-sources ""` for a stable census, and a scenario that needs the
  project source (S17's `.claude/agents/` in the scratch cwd) widens it, which is safe
  under the scratch home. `--strict-mcp-config` keeps the census free of MCP servers,
  with the S5 exception in §4.7. Model `haiku` unless the scenario says otherwise,
  `--max-turns` set per scenario.
- **Setting isolation**, the fallback for a machine whose scratch home is not logged
  in: the real config home with `--setting-sources ""` and `--strict-mcp-config`, the
  configuration this session's probes used. It leaves one transcript per recording under
  the real `~/.claude/projects` and is used only when the default cannot be.

Nothing in `Tools/` ever creates, edits or deletes a file under either config home,
including the probe sessions' own transcripts, which `snapshot` copies and never moves;
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
| `background-shell` | `run_in_background` Bash, the `task_notification` and the auto-turn; the task output file bundled under `artifacts/` with its path tokenised | items 61, 15's data; C3.G3 |
| `session-mirror-relocation` | two turns, `set_cwd` to a trusted sibling, two more, resume, one more (S14) | items 56, 64; C3.G3, C3.G4 |
| `send-user-file` | the in-process MCP round trip (S5): two files with a caption and `status: "normal"`, the JSON-RPC request and response recorded; the scenario first confirms that the SDK server registers under `--strict-mcp-config` and drops that flag for this scenario if it does not, recording which | item 29; C2.G3 |
| `control-shapes` | `apply_flag_settings {effortLevel}` with readback, `rewind_conversation`, `set_cwd` needing trust, `claude_authenticate` family shapes (S8) | items 11, 13; C4.G4 |
| `resume-no-replay` | `--resume` of `plain-two-turn`, `initialize`, six idle seconds | item 1; S2's record |
| `dialog-refusal-fallback` and `dialog-fable-overage` | **synthetic, `hypothesis: true` until confirmed** (S6): every result value, the close path, the tombstones after a refusal, `model_consent_fallback`, `overagesEnabled` both ways, an undeclared kind left to `control_cancel_request` | item 62 (provisional until S6 closes) |
| `notification-hook` | `Notification` registered through `initialize.hooks`, a permission ask left waiting past the idle threshold (S18) | item 53 |

S6 closes only on baseline evidence: the dialog payload shapes and result enums are
extracted from the installed 2.1.259 binary's embedded source under
`~/.local/share/claude/versions/2.1.259` (the same strings the 2.1.257 bundle modules
carry: `refusal_fallback_prompt` with `retry_fallback | edit_prompt | cancelled`,
`fable_overage_consent_prompt` with `consent | switch_default | cancelled`), the
extraction is recorded in the finding, and only then are the two fixtures' `hypothesis`
flags cleared and item 62 taken off provisional. A synthetic fixture never counts as
baseline evidence by itself.

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
| `FAKE_CLAUDE_SCRIPT` | path to a JSON list of duplex steps (below) |
| `FAKE_CLAUDE_INIT` | path to a JSON object that replaces the recorded `initialize` response |
| `FAKE_CLAUDE_CONFIG_HOME` | when set, the fixture's `initial/` state is materialised there before replay and the mirrored appends and artifacts are written in step with replay |
| `FAKE_CLAUDE_VERSION` | what `--version` prints; defaults to the fixture's recorded version |

Replay is reactive, not a timed dump. The replayer walks `frames.ndjson`: an `out` line
is emitted after its delta from the previous line, scaled by the speed factor; an `in`
line blocks until the host sends a frame that matches it, where a `control_response`
matches by `request_id`, a `user` frame matches any `user` frame (the text is not
compared, and a mismatch is logged to stderr), and a host `control_request` matches by
subtype, after which the replayer emits the recorded response with the host's
`request_id` substituted. **Host traffic the fixture and the script do not expect fails
the replay** with a stderr line naming the frame and exit code 3; a generic success
answer for named subtypes is available only through an explicit script rule. An
`interrupt` outside the recording is likewise a failure unless a rule allows it, which
is what the parent's interrupt items script. `--version` prints the version; `--help`
prints the flag list from the fixture's census so a census run against fake-claude sees
the recorded flags. After the last line the replayer waits for stdin to close or
`end_session`, then exits 0; a closed stdin mid-replay exits 0 immediately, like the
CLI.

**Scripts are duplex.** `FAKE_CLAUDE_SCRIPT` is a JSON list of steps, applied in order
around the recording:

```
{"at": <ms> | "after": <out-frame index>, "emit": {frame}}          inject a frame
{"expect": {matcher}, "timeout_ms": <n>}                           require host traffic
{"answer": {frame}}                                                 reply to the last match
{"rule": "generic-success", "subtypes": ["<subtype>", ...]}         permit unseen requests
```

A matcher names a frame `type`, and optionally `subtype`, `request_id` (or `"$last"`
for the id of the last emitted `control_request`), and JSON fields that must be equal. An
`expect` that times out fails the replay; an `answer` that follows an `expect` for a host
`control_request` is emitted with the host's `request_id`. This is how item 32's invented
frame type, the malformed-payload and unknown-request items of the parent's §14, and the
"host must have answered with this error" assertions are produced without a live binary.

**Materialisation.** `fake-claude materialize <fixture> <configHome> [--cwd <path>]`
lays down the fixture's `initial/` state under `<configHome>/projects/<slug-of-cwd>/`,
rewriting `_slug_` and the `cwd` fields inside the records, so a channel opens with
exactly the history the app saw at spawn. During replay with `FAKE_CLAUDE_CONFIG_HOME`
set, each `transcript_mirror` frame's `entries` are appended to the matching stream at
the moment the frame is emitted, starting at the offsets in `streams.json`, and each
artifact is written under a `tasks/` directory beneath the fake home when the frame that
names it is emitted; the fake home's path replaces the `<artifacts>` token in emitted
frames. A tool test asserts that after a full replay the files under the fake home equal
`transcript/` plus `artifacts/` byte for byte, which is what C3.G3, C3.G4 and item 56
rest on.

**Materialisation writes only into a home fake-claude created.** The destination must
be a directory `materialize` creates itself, or one it created earlier and marked with
an `.afleet-fake-home` file at its root. Before writing, the destination path is
resolved through every symlink and refused if it equals or lies within the real
`~/.claude`, the resolved value of `CLAUDE_CONFIG_DIR` in fake-claude's own
environment, or any existing directory without the marker; it is also refused if a
transcript with the fixture's session id already exists there. The refusal is a
non-zero exit with the reason on stderr, before any write. These checks are the X9
guarantee for the one tool that writes transcript files at all.

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
checking order, blocking on `in` lines, script steps (`emit` at time and index,
`expect` with timeout, `answer`, and the failure on unexpected host traffic),
`--version`, `--help`, materialisation refusals (a symlink into `~/.claude`, a directory
without the marker, an existing transcript) and the final-filesystem equality after
materialise-plus-replay; `verify`'s lifecycle checks on crafted frame lists (answered,
cancelled, cancelled-then-late without and with the `late_responses` entry, orphaned);
and `record`'s no-unredacted-byte property, proven by streaming a planted secret and a
planted email through the harness and asserting neither ever appears in any file the run
created. These tests are C1's own; the parent's item 36
runs them as part of the repository's test target once C5's project exists, and until
then `make test-tools` is the gate.

## 5. Acceptance

Restated from the parent's C1 section as observable behaviour; G1 through G4 are
required.

- **G1 Fixtures.** `Fixtures/` contains the thirteen recorded fixtures and two synthetic
  ones of §4.7, each with a signed review block, and `make verify-fixtures` exits 0.
  Each fixture carries `initial/`, `streams.json` and `transcript/`; each recorded
  fixture's `frames.ndjson` contains `transcript_mirror` frames whose entries, appended
  from the recorded offsets onto `initial/`, reproduce `transcript/`; `nested-depth-2`
  holds two subagent files and their `.meta.json`; `background-shell` holds the task
  output file under `artifacts/` and its `task_notification` names it by token;
  `send-user-file` holds the JSON-RPC `tools/call` request and response with two files.
  The two dialog fixtures carry `hypothesis: true` until S6 closes.
- **G2 Census.** `make probe` against the installed 2.1.259 exits 0 and prints a zero
  diff for every `census: true` fixture, using exact comparison for deterministic
  scenarios and required-shape comparison for model-driven ones. `make probe
  CLAUDE=Tools/fake-claude/fake-claude FIXTURE=plain-two-turn` with a script that emits
  a frame of type `afleet_invented` exits 1 and prints exactly one added pair; the same
  run with a script that removes a required key from `system/init` exits 1 and names
  the key.
- **G3 Findings.** The parent document in this branch carries a dated `C1/S<n>:`
  Revision Note for each of S5, S6, S8, S10, S11, S12, S13, S14, S15, S16, S17 and
  S18, each naming the clause it settles; S6's note either records the 2.1.259
  extraction that cleared the two fixtures' `hypothesis` flags or states that S6 stays
  open and item 62 provisional; this document's Surprises section names any
  `[parent-impact]`.
- **G4 Redaction.** `Tools/probe/redact.py` exists and is what `record` and `snapshot`
  run before any write; `Fixtures/REVIEW.md` exists; `verify` fails a fixture whose
  review block is unsigned, one that contains a planted email address, and one with an
  unresolved request lifecycle, and passes every committed fixture; no `raw/` directory
  exists under `Fixtures/`; the no-unredacted-byte test of §4.10 passes.
- **Tool tests.** `make test-tools` passes on the system `python3` (3.9) and on 3.14.

## 6. Edges and contracts

- **Blocked by:** nothing.
- **Blocks:** C2.G2 (every fixture decodes), C3.G1 (the differential test), C6's
  fixture-driven gates, and every child whose spike C1 answers (S14 and S17 for C4's
  restart rule, S15 for C6's question card, S16 for C6's Agents leaf, S18 for C5's
  notification route, S10 through S13 for C4).
- **Owns:** X8, the fixture and fake-claude format of §4.4 and §4.8: the directory
  layout with `initial/`, `streams.json`, `transcript/` and `artifacts/`, the
  `<artifacts>` token, the nested required-versus-optional census, and the duplex
  script format. Changes after the first consumer lands need a Revision Note here and
  on the parent; additive fields are free.
- **Bound by:** X9. Nothing in `Tools/` writes under a config home: the harness only
  reads and copies transcripts, and `materialize` refuses every destination it did not
  create and mark (§4.8). Fixtures are redacted before the first byte reaches disk and
  reviewed before commit; `submit_feedback` is never sent by any scenario; the typings
  are never committed (C1 does not fetch them at all).

## 7. Delegated unknowns

Empirical residue that execution answers, not this document: whether the scratch config
home's login persists across CLI upgrades or needs repeating; whether the SDK MCP server
registers under `--strict-mcp-config` (settled by the first S5 run); whether the idle
threshold for the waiting-permission notification can be reached inside a scenario's
budget or needs a setting (S18); whether `os.openpty` is enough for the interactive
`claude --resume` in S12 or the scenario must drive `script(1)`; and the memory budget at
which `record` spills to its temporary file, set from the largest recorded scenario.

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

- Decision: Scenarios run in a fresh synthetic scratch repository under a scratch
  config home (`CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home`) that the user logs
  into once by hand; setting isolation on the real config home is the fallback level.
  Rationale: Redaction is tractable only when the model reads synthetic files; the
  scratch home keeps the census and the user's history clean and gives S13 and S17 a
  throwaway `.claude.json`; the user chose it at the gate. Rejected: the real config
  home by default (about twenty `/tmp` projects would appear as archived channels and
  the census would see the user's plugins and skills); recording in real projects;
  recording with the user's settings active.
  Date/Author: 2026-09-04 / kimmi with Claude

- Decision: Synthetic fixtures are permitted only for wire paths that cannot be
  provoked on demand, marked and excluded from the census, and carry `hypothesis: true`
  until their shapes are confirmed from the installed baseline binary's embedded
  source; S6 closes only on that evidence.
  Rationale: The dialog cards need fixtures for every enum value and no live trigger
  exists, but the two hand-written fixtures come from the 2.1.257 bundle and the
  baseline is 2.1.259, so they are schema hypotheses until the 2.1.259 strings are
  extracted. Rejected: leaving S6 unanswered; recording until a refusal happens; closing
  S6 on the 2.1.257 bundle alone.
  Date/Author: 2026-09-04 / kimmi with Claude

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

- Decision: Redaction runs in memory before any write; `record` keeps no `raw/`
  directory, and `fixture.json` records an allowlist of launch variables.
  Rationale: The parent's rule is redacted before disk; a git-ignored plaintext capture
  is still indexed, backed up and copyable, and the full environment table is itself
  identity data. Rejected: a git-ignored `raw/` directory; redacting after the fact.
  Date/Author: 2026-09-04 / kimmi with Claude

- Decision: `fake-claude materialize` writes only into a directory it created and
  marked, after symlink resolution, and refuses the real config home, the resolved
  `CLAUDE_CONFIG_DIR`, unmarked directories and existing transcripts.
  Rationale: It is the one tool that writes transcript files; without the refusal it
  could overwrite or duplicate the original recording session in the real home.
  Rejected: trusting the caller's path; a warning instead of a refusal.
  Date/Author: 2026-09-04 / kimmi with Claude

- Decision: The harness's MCP tool mirrors `SendUserFile`'s schema, `files`, `caption?`,
  `status` and `display?`, and answers JSON-RPC notifications with the SDK's empty
  result under `mcp_response`.
  Rationale: The parent binds the tool as `send_user_file(files, caption?)`, the parity
  inventory says to mirror the built-in tool's `status` and `display` axes so the
  model's trained behaviour transfers, and C2 implements the same shape; a `{path}`
  schema would validate C2 against an incompatible fixture. Rejected: a single `path`
  argument.
  Date/Author: 2026-09-04 / kimmi with Claude

- Decision: X8 records the filesystem as well as the wire: `initial/`, `streams.json`,
  `transcript/` and `artifacts/` with tokenised paths; replay materialises the initial
  state and appends in recorded order; a test asserts the final state.
  Rationale: A final snapshot copied before replay and then appended to again puts
  future turns on screen at open and duplicates every record; task output files live
  under `/private/tmp`, not the transcript, so a fixture without them points item 61 at
  a missing file. Rejected: a final snapshot only; excluding task artifacts.
  Date/Author: 2026-09-04 / kimmi with Claude

- Decision: The census fingerprints one level down per discriminated payload and
  compares exactly for deterministic scenarios and by required shape for model-driven
  ones; this extends the parent's §6.10 shape and is filed as a parent Revision Note.
  Rationale: The fields the app decodes in control traffic sit under `request` and
  `response`, invisible to a frame-level key set; one observed union of a model-driven
  run would call conditional frames and optional keys drift. Rejected: frame-level keys
  only; exact comparison everywhere; repeated sampling as the only mitigation.
  Date/Author: 2026-09-04 / kimmi with Claude

- Decision: `verify` checks request lifecycles as a state machine that accepts a
  cancellation as a terminal state.
  Rationale: The undeclared-dialog fixture must show a request that is never answered
  and ends in `control_cancel_request`; a pairing rule would reject the very fixture G1
  requires. Rejected: the pairing rule with a per-fixture exemption list.
  Date/Author: 2026-09-04 / kimmi with Claude

- Decision: fake-claude scripts are duplex (`emit`, `expect`, `answer`, `rule`), and
  unexpected host traffic fails the replay by default.
  Rationale: An injection without an expectation cannot prove the host answered an
  unknown request with the required error, and generic success for unseen requests
  would let a test pass while the host misbehaves. Rejected: emit-only injection with
  generic success.
  Date/Author: 2026-09-04 / kimmi with Claude

- Decision: The `control-shapes` scenario calls `claude_authenticate` to capture the
  response shape and abandons the flow.
  Rationale: The shapes are needed for S8 and the fixture; the URLs are redacted and no
  login completes. Rejected: modelling the shapes from the bundle source only.
  Date/Author: 2026-09-04 / kimmi with Claude

## Surprises & Discoveries

- Observation: The committed probe 10 never passes `--session-mirror`; it only listens
  for `transcript_mirror` frames. Evidence: `grep session-mirror probes/10-*.py` matches
  only the print statement. Impact: S14 needs a new scenario, as the parent already
  notes; the mirror flag has never been exercised in this repository.
- Observation: `claude --help` on 2.1.259 lists 70 distinct flags, and the parent's
  launch line uses one that `--help` omits (`--session-mirror`). Impact: the census
  records the flag list from `--help` and separately asserts acceptance of each launch
  flag by spawning with it, so hidden flags are covered.

- Observation: The extracted bundle's SPEC chapter files under
  `~/claude-code-bundle/2.1.257/SPEC/` are no longer on disk on 2026-09-04; the bundle
  source (`cli.pretty.js`, `modules/`) and `docs/tui-parity/` remain. Impact: chapter
  citations inherited from the parent are kept as recorded; new facts in this document
  cite the parity files or the bundle modules, and S6's baseline evidence comes from the
  installed binary's embedded source rather than a chapter.

## Outcomes & Retrospective

Pending — written at finish.

## Revision Notes

- 2026-09-04: v1, written at dispatch from the parent's §17 C1 at commit `9fd067c`.
- 2026-09-04: v2 after the parent's Codex review of v1 (eight findings, all accepted)
  and the gate answers. Redaction now precedes every write and `raw/` is gone (§4.2,
  §4.5); `materialize` refuses every destination it did not create and mark (§4.8, X9);
  the harness's MCP tool mirrors `SendUserFile`'s schema and the S5 scenario checks
  `--strict-mcp-config` (§4.3, §4.7); X8 gains `initial/`, `streams.json`, `artifacts/`
  and the final-state test (§4.4, §4.8); the census fingerprints nested payloads with
  required-versus-optional comparison (§4.4); `verify` checks request lifecycles as a
  state machine (§4.2); the S6 fixtures are schema hypotheses until the 2.1.259
  extraction (§4.7); scripts are duplex and unexpected traffic fails replay (§4.8). Gate
  answers folded in: scratch config home by default, synthetic fixtures under the
  hypothesis rule, the `claude_authenticate` capture, Python standard library; the
  questions section is removed. Acceptance G1, G2 and G4 restated accordingly.
- 2026-09-04: Planning corrections. (1) The CLI emits `transcript_mirror.entries` as parsed
  records, not raw lines (bundle `chunk-sct99ax9.js`, `entries: R(de())`), so fake-claude
  re-serialises them and the final-state check of §4.8 compares transcript files record
  for record and artifacts byte for byte. (2) fake-claude scripts gain an additive step,
  `{"patch": {matcher}, "remove": [keys]}`, which strips keys from matching replayed
  frames, so G2's removed-required-key case is producible without a live binary. (3)
  `keep_alive` frames are excluded from the census; they carry nothing and their timing
  varies. Plan: `docs/doperpowers/plans/2026-09-04-c1-probe-suite-fixtures-fake-claude.md`.
- 2026-09-04: Planning split the tooling into `fixture.py` (layout, snapshot, streams,
  artifacts, assembly) and `verify.py` (structural, lifecycle, redaction and review
  checks) beside the four modules §4.1 names, so both are unit-testable without a live
  binary; `probe.py` remains the only composition point. Discovery runs one
  `unittest discover` per tool because `Tools/fake-claude` is not an importable
  package name.
- 2026-09-04: `verify`'s scanners return findings that are themselves safe to print and to
  store. `scan` passes every finding through the same redaction rules before returning it,
  which is sound because it only ever reports what those rules would change; the two
  report-only checks of §4.5 name the rule and the position instead of echoing the author's
  name or a foreign home path, which redaction by definition leaves alone. No consumer of
  `verify` therefore carries a rule about where findings may be written. The guarantee
  extends only to the patterns the scanner was given — a pattern it does not hold cannot be
  scrubbed back out of a finding — so `scan` defaults the hostname to the local one. Rule 3's
  hostname half is accordingly enforced at record time, and at verify time holds on the
  recording machine and only opportunistically elsewhere, where a cross-machine review has to
  pass the recording hostname explicitly.
- 2026-09-04: The census fingerprints a `control_response` at two levels, not one.
  `payload_keys` and `required_payload_keys` hold the `response` envelope — the key set
  §4.4 names — and a new `body_keys` and `required_body_keys` hold the body that envelope
  wraps. The envelope is what tells a success from an error: `subtype` and `request_id` are
  always present, `response` appears on success and `error` on failure, so recording the
  body in the envelope's place left the two indistinguishable. The body fields accumulate
  only over the frames of a pair that actually carry a body and are omitted entirely when
  none does; `merge_required` likewise skips a side that has none rather than intersecting
  against it. That rule — an absent body is never folded in as an empty one — is what the
  design turns on. The required sets are intersections, so a single error response would
  otherwise empty the required body set for that pair permanently and the required-shape
  check could never alarm on it again; and errors are ordinary traffic here, not an edge
  case, since `control-shapes` hands `claude_oauth_callback` an invalid code on purpose
  (§4.7) and the zero-cost census draws them too. The same distinction now holds at the top
  level: `flags` is `null` when `claude --help` was never captured and `[]` when it answered
  and declared nothing, and `diff` reports a one-sided gap as not captured rather than as
  every flag removed. Exact comparison reads the required sets as well as the unions, since
  a key that goes from always present to sometimes present leaves the union untouched.
  Nothing needs migrating: no `census.json` recorded before this change exists, `Fixtures/`
  holds only its placeholder, and no later run should accumulate onto a stale file.
- 2026-09-04: §4.8's environment table is missing a row. `FAKE_CLAUDE_CWD` names the cwd a
  replay presents as its own and defaults to the process's working directory. A replay runs in
  a scratch directory while the transcript it materialises belongs to the recorded scenario's
  cwd, so the slug the mirror paths carry cannot be derived from where the process happens to
  run; without the variable a materialised home and a replaying process disagree about which
  project directory they are talking about.
- 2026-09-04: The mirror rewrite of §4.8 is a rule about the root standing in front of
  `/projects/<slug>/`, not about `~/.claude`, which is one instance of it. Every scenario
  records under the scratch `CLAUDE_CONFIG_DIR` of §4.6, and §4.5's rule 3 substitutes only the
  recording user's home for `~`, deliberately leaving a synthetic `/tmp` path alone — so a
  recorded `transcript_mirror.filePath` is rooted at that scratch home, and a replayer
  recognising only `~/.claude/projects/` resolves the path outside the fake home and refuses its
  own first mirror frame, taking C3.G3, C3.G4 and item 56 down with it. Whatever root precedes
  the recorded slug becomes the fake home's. The same clause's "starting at the offsets in
  `streams.json`" holds logically but not literally: materialisation rewrites the slug and the
  recorded cwd inside the records it lays down, so the bytes on disk are not the recorded bytes
  and the recorded offset no longer marks the end of the initial state. Appends begin after the
  bytes materialisation actually wrote for that stream, with the `streams.json` offset standing
  in for a stream `initial/` does not hold — which by §4.4 is a stream that did not exist at
  spawn, whose offset is zero. A computed start beyond the end of the file is refused by name
  rather than padded, because that combination means the fixture was never materialised into
  that home and no replay from it could reproduce the final state.
- 2026-09-04: §4.4's `fixture.json` enumeration is the metadata the format's design turns
  on, not the whole record `record` writes, and against the constraint that field names are
  exactly those of §4.4 and §4.7 that difference reads as a contradiction rather than as a
  summary. Eight omitted fields are written and each is load-bearing. `cwd` holds the
  recording's scratch cwd, and `verify`'s mirror check derives the recording slug from it: a
  recorded `transcript_mirror.filePath` names the slug the CLI wrote under, so without the
  cwd there is nothing to rewrite that slug into the `_slug_` token space with and no
  mirrored stream resolves to a file under `transcript/`. `session_id` is what `snapshot`
  resolves a session's transcript files by, and what a resuming scenario reads out of the
  fixture it resumes to learn which session that is; §4.4's own note that session ids stay as
  recorded already presumes the field. `deterministic` chooses between this section's two
  comparisons, exact and required-shape, so its absence is not a default but a silent
  downgrade of the strict gate to the permissive one — the ambiguity `diff` already refuses
  to resolve by defaulting. `scenario` names the module that produced the fixture, which
  `diff` re-runs against a binary and which need not equal the fixture's name — §4.7 names
  two fixtures on one row. `isolation` records which of §4.6's two levels the recording used,
  which §4.6 already says is chosen per scenario in `fixture.json`; the enumeration never
  caught up. `spikes` records which of §4.7's spikes the recording informs, so a finding can
  be walked back to its evidence. `notes` and `exit_code` carry what the scenario observed
  about its own run — S5's dropped `--strict-mcp-config`, a transcript that was not there to
  snapshot, the exit status under §6.7's shutdown — which is the difference between a fixture
  a reviewer can judge and one they have to re-derive. §4.4's list plus `deterministic` is
  the contract's required core: `verify` fails a fixture that omits any of them, by presence
  and not by value, so a hand-written synthetic fixture cannot arrive with the census
  comparison quietly relaxed. The rest sit beside them.
