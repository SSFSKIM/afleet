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
| `rewind-turn` | a resume of `plain-two-turn`, `rewind_conversation` at the resumed transcript's first user record (refused, `rewound: false`, `error: "stale target"`), one turn, then the same request at that turn's own user record (honoured): a `last-prompt.leafUuid` that is not the file's last record, and the abandoned branch below it | item 13; C3.G1 |
| `compact-boundary` | a resume of `plain-two-turn` and `/compact` sent as a user message: the `system/compact_boundary` frame with its `compact_metadata`, the record on disk with its `compactMetadata`, the `isCompactSummary` user record and the mirror entries carrying them | C3.G1, C3.G3 |

The last two rows are the 2026-09-05 follow-up wave, added after C1's own close at C3's
request, and they take the catalogue to **twenty fixtures: eighteen recorded and two
synthetic**. Neither takes part in the census (`census: false`): each consumes its own
precondition the way `resume-no-replay` does -- a rewind and a compaction both change the
session they were recorded against, so re-running either against the transcript it left
cannot reproduce what was recorded. The retrospective figures further down this document say
sixteen recorded and eighteen in total; those are the record of what was true at C1's close
and are left standing, in the same way §4.7's earlier cost figures were.

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

A follow-up spike carries the same shape and is written up the same way:
`spike-mcp-decline-files` (C4's, on the parent's §6.12) drives the interactive CLI on a
pseudo-terminal, declines a project `.mcp.json` server at the engine's own consent dialog and
diffs the project directory and the scratch config home across the run, so the finding names
the files that changed and the keys they gained. Its write-up is
`Tools/probe/spikes/mcp-decline-files.md`, the first prose finding kept beside the extraction
script in that directory; §4.9's Revision Note on the parent carries the same answer in the
parent's own words.

Recording is a deliberate act: `make record SCENARIO=<name>` runs one scenario; the
unit tests never touch a live binary. Everything records on `haiku` with `--max-turns`
between 2 and 6; a full re-record of the catalogue is about twenty short sessions,
which is the price of a baseline bump. The **ritual** has a price of its own, which this
paragraph originally left out: `make probe` re-runs every census scenario against a live
binary, measured at roughly 0.13 USD across the nine census fixtures of wave B and rising
with each model-driven fixture added. It stays an on-demand ritual (§6.10 of the parent),
not something run per commit, and the two figures should be budgeted separately.

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

## 8. Deferred

Work this child scoped out deliberately, recorded so it is a decision rather than an
oversight.

- **The recording's identity inputs are not carried in the fixture.** `verify`'s rule 3
  checks the home directory and hostname of the machine *performing the verification*,
  defaulting the hostname to the local one, so off the recording machine the check holds
  only if a reviewer passes `--hostname` by hand and not at all for the home path. A
  fixture could instead persist the identity inputs its recording ran under -- OS account,
  the configured Git author name, e-mail and local part, and the recording hostname -- and
  `verify` could then apply rule 3 in full on any machine, which is what a public
  repository's reviewers will actually be doing. It is deferred rather than dismissed
  because the shape needs thought this wave did not have: the inputs are themselves the
  identifiers being protected, so storing them means storing a hash or a length rather than
  the strings, and a fixture that names what to look for is a fixture that says what the
  author's name is. The present arrangement is stated and tested (Revision Note,
  2026-09-04): enforced at record time, held at verify time on the recording machine, and
  opportunistic elsewhere.

- **A twelfth checklist item, recommended and not taken: read every field whose *name*
  suggests an identity or a tenant and confirm its value is a placeholder.** Raised by the
  reviewer of `rewind-turn` on 2026-09-05, from the case that produced it: `ownerAccountUuid`
  and `ownerOrganizationUuid` reached two fixtures unredacted, and neither half of the gate
  saw them. `verify`'s scanners re-run the redactor's own rules, so they inherited its blind
  spot exactly; item 2 greps for a fixed list of known literals and an opaque uuid matches
  none of them; item 4 pointed nowhere because no container had been replaced. What found it
  was a name-shaped search nobody was asked to run. The redactor fix closes this one pair of
  names, and the reviewer's point is the general one: a fail-open scanner plus a checklist
  that greps for known literals leaves opaque identifiers invisible to both halves.
  Not taken here because REVIEW.md's own rule makes it a corpus-wide act — adding an item
  means bumping `verify.CHECKLIST_VERSION` to 4, which refuses every one of the twenty
  fixtures signed at version 3 until each is re-walked, including the two this wave signed.
  That is the gate owner's decision, not a follow-up wave's, and it is recorded here with the
  reasoning intact so whoever takes it does not have to rediscover why.

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
- Observation: `claude --help` on 2.1.259 **declares** 68 distinct long flags, not the 70
  first counted here, and the parent's launch line uses one that `--help` omits
  (`--session-mirror`). Evidence: the recorded `zero-cost` census. `--all` and
  `--permission-prompt-tool` bring the naive count to 70, but on 2.1.259 each appears only
  inside another flag's description prose — `--permission-prompt-tool` inside the
  description of `--permission-prompts` — and `census.flags_from_help` anchors on the
  two-space declaration column deliberately, so a flag merely mentioned is not
  fingerprinted as one the CLI declares. Impact: the census records the flag list from
  `--help` and separately asserts acceptance of each launch flag by spawning with it, so
  hidden flags are covered; the number in this document was the estimate and the census is
  the measurement.

- Observation: Under `--replay-user-messages` the CLI re-emits every `control_response`
  the host sends straight back on stdout. Evidence: the `zero-cost` recording shows each of
  the three `mcp_message` round trips as the host's answer travelling in and the identical
  body travelling out a few milliseconds later; the mechanism is the stdin loop's
  `control_response` branch in the 2.1.258 bundle, `if (C.replayUserMessages)
  bt.enqueue(d)`. Impact: the parent's §6.1 launch line always carries the flag, so every
  recording made here contains these. `verify`'s lifecycle check read them as second
  answers and failed the first live recording with three "duplicate response" errors; it
  now reads a response travelling the same way as the request it names as an echo, which
  it can only be, since the answer is by definition the other direction. A host reading
  its own answers back off the stream must expect them.

- Observation: The CLI mirrors every record it writes. Evidence: with the slug bug below
  fixed, `verify`'s mirror-fidelity check passes on the `send-user-file` recording, where
  eleven mirrored entries across three `transcript_mirror` frames reproduce all eleven
  records of the session transcript exactly, with nothing in `initial/`. Impact: the check
  was written on that assumption and no probe had confirmed it; it is now confirmed on one
  real session, including record types the host does not otherwise see (`queue-operation`,
  `attachment`, `file-history-snapshot`, `atis-latch`, `last-prompt`).

- Observation: The CLI derives a project slug from the **resolved** working directory.
  Evidence: every scenario runs in `/tmp/afleet-fixtures/<name>`, `/tmp` is a symlink to
  `/private/tmp` on macOS, and the CLI wrote
  `projects/-private-tmp-afleet-fixtures-send-user-file/`. Impact: a fixture's slug is the
  resolved one, so any consumer computing it from `fixture.json`'s recorded `cwd` without
  resolving disagrees with the fixture it is reading — which is how the mirror check came
  to report a stream named `-private_slug_/…` as missing. `fixture.slug_of` and
  `fake-claude`'s copy both resolve first. This binds C3: a replayer that materialises a
  session under the unresolved slug lays it down where no real CLI would look.

- Observation: `diff` decided whether a fixture takes part in the census only after loading
  its scenario module, so the skip was unreachable for the fixtures it exists for. Evidence:
  `make probe` reported both hand-written dialog fixtures as `FAILED to run (FileNotFoundError:
  no scenario dialog-fable-overage)` on a tree where nothing was wrong. Impact: the test that
  covered the skip used a fixture whose module did exist, which is why it passed; the
  question is now asked of `fixture.json` alone, before anything is loaded.

- Observation: An empty fixture directory does not survive a commit. Evidence: `git
  ls-files Fixtures/` listed no `initial/` entry for any fixture, while `verify` requires
  `initial/` and `transcript/` to be directories. Impact: a fixture recorded by a scenario
  that resumes nothing and starts no turn — `zero-cost` leaves all three empty — passed the
  gate on the recording machine, where `record` had just made the directories, and would
  have failed `missing initial/` on every clone. `write_fixture` now places a `.gitkeep`,
  and everything that walks those directories skips it by name, `fake-claude`'s
  materialiser and final-state comparison included.

- Observation: The account's weekly rate limit was reached during wave A, on 2026-09-04,
  and no model tokens were available for the rest of it. Evidence: the `zero-cost`
  fixture's own `get_usage` response, recorded minutes before the first paid attempt,
  carries `rate_limits.seven_day.utilization: 100` and
  `{"kind": "weekly_all", "percent": 100, "severity": "critical", "is_active": true,
  "resets_at": "2026-09-06T15:00:00Z"}`, with `extra_usage.disabled_reason:
  "out_of_credits"` and the five-hour window at 29 per cent. Impact: `send-user-file`,
  `plain-two-turn` and therefore `resume-no-replay` could not be recorded. A rate-limited
  turn is not an error frame: it returns `result` with `subtype: "success"`,
  `is_error: true` and the limit text as `result`, and it emits `system/init` and writes a
  full transcript first, which is why the wave still produced protocol evidence.

- Observation: A turn the engine rejects on a spent rate-limit window is a complete wire
  path that costs nothing to record, and four of its details would defeat a hand-written
  fixture. Evidence: `rate-limited-turn`, recorded twice with identical results. The
  `rate_limit_event` fires **once for the session**, not once per rejected turn — the second
  prompt is rejected in silence. The reply is an `assistant` message whose `message.model` is
  the literal `"<synthetic>"`, the engine's own marker for a message no model produced and
  not a redaction placeholder. `result` is `subtype: "success"` with `is_error: true`,
  `duration_api_ms: 0` and zero usage, so a consumer keying failure off the subtype alone
  reads a rejected turn as a clean one. And a rejected turn **is** written to the transcript
  in full — seventeen records including both prompts, both synthetic replies and the usual
  `attachment`, `queue-operation`, `file-history-snapshot`, `atis-latch` and `last-prompt` —
  sixteen of them arriving mirrored live. Impact: item 21 and C2.G2 gain their only
  `rate_limit_event` evidence; §8.4's "until the next event clears it" is confirmed as the
  right rule precisely because there is no second event.

- Observation: The identity rule redacted a counter. Evidence:
  `result.subagent_stats.killed.user` counts subagents the user killed and sits beside
  `killed.parent` and `killed.system`, and the rule rewrote the count as the string
  `<user>` in every `result` frame of the first `rate-limited-turn` recording. Impact: the
  loss is not cosmetic — C2.G2 asks that every frame decode and re-encode without loss, and
  a `Codable` model typing the field `Int` cannot read a string back. Neither name nor type
  separates it from a numeric account id (`user_id: 7` is identity and is an int), so the
  exemption is written as the single path it applies to, with the scanner exempted in step.

- Observation: The recording baseline is a **binary path**, not "the installed CLI".
  Evidence: `claude` auto-updated from 2.1.259 to 2.1.260 mid-wave and four fixtures silently
  followed it. The recorded corpus is now pinned to
  `~/.local/share/claude/versions/2.1.259`, which every fixture records in
  `launch.argv[0]`. Impact: §4.6's isolation was never enough on its own — a scenario can be
  isolated from the user's configuration and still be recorded against a binary nobody chose.
  The pin is also fragile in a way the fixtures are not: `~/.local/share/claude/versions/`
  is pruned by future upgrades, so the 2.1.259 file can vanish. That is the argument for the
  fixtures being the durable evidence and the binary merely the instrument — a corpus that
  can only be re-derived from a binary that may not exist is not a baseline. A child should
  still read `cli_version` per fixture rather than assuming one number for the directory,
  because of the exception below.

- Observation: `rate-limited-turn` is permanently off the baseline, at 2.1.260 and with the
  four-variable environment table that predates S15. Evidence: it was recorded in the window
  between the upgrade and the pin, and its precondition — a seven-day usage window at 100 per
  cent — is gone. Impact: it cannot be re-recorded on 2.1.259 or on anything else, ever.
  Nothing rests on the difference: it is `census: false`, so it never takes part in a
  comparison, and it is evidence about the shape of one rejected turn rather than about a
  version's frame inventory. Recorded here and in its README so it does not read as an
  oversight.

- Observation: 2.1.259 and 2.1.260 are census-identical, which is the first drift measurement
  the ritual has made between two real versions. Evidence: `make probe` against the installed
  2.1.260, with the corpus pinned to 2.1.259, reports `ok` for all three census fixtures and
  exits 0; a field-level comparison of the two versions' `zero-cost` censuses shows zero
  differences across pairs, `keys`, `required_keys`, `payload_keys`, `required_payload_keys`,
  `body_keys`, `required_body_keys`, `capabilities` and the 68 declared flags. Impact: the
  patch bump changed nothing the census fingerprints, so the earlier worry that `zero-cost`
  passed "by luck" is settled by measurement. Note what this does *not* establish: a run that
  finds nothing cannot demonstrate that the ritual would find something. The ritual's
  sensitivity is evidenced separately, by the `fake-claude` injections — an invented frame
  type reported as exactly one added pair, and a stripped required key reported by name.

- Observation: An SDK MCP tool listed in `system/init.tools` is not immediately invocable.
  Evidence: `send-user-file`. `mcp__afleet__send_user_file` appears in the tool list, and the
  model's first act is nonetheless `ToolSearch {"query": "select:mcp__afleet__send_user_file"}`
  to fetch its schema; the `tool_result` for that fetch is a `tool_reference` block rather
  than text, and the transcript carries `deferred_tools_delta` and `deferred_tools_record`
  attachments around it. Impact: a host modelling the first turn as "listed, therefore
  called" will mis-read it, and the extra turn is a real cost on every scenario that drives
  an SDK MCP tool. Also on the wire: `tools/call` params carry a `_meta` the host never
  declared, holding `claudecode/toolUseId` and a `progressToken`.

- Observation: A transcript holds far more than its exchanges. Evidence: `plain-two-turn`'s
  two prompts and two replies produce thirty-one records — nine distinct `attachment` kinds
  (`environment`, `model`, `deferred_tools_delta`, `agent_listing_delta`, `skill_listing`,
  `total_tokens_reminder`, `session_context`, `date`, `prompt_snapshot`) alongside
  `queue-operation`, `file-history-snapshot`, `atis-latch`, `ai-title` and `last-prompt`.
  Impact: C3's reducer must account for all of them; a consumer modelling a transcript as
  user and assistant records drops most of the file. A resume adds exactly one more, of type
  `mode` (`resume-no-replay`).

- Observation: The mirror-fidelity check holds on every recording with real turns.
  Evidence: `send-user-file` (34 records), `plain-two-turn` (31 records across seven mirror
  frames) and `resume-no-replay` (one `mode` record appended to a populated `initial/`) all
  pass it. Impact: with the earlier slug defect fixed, nothing remains unconfirmed about the
  check's premise, and `resume-no-replay` is the first fixture to exercise §4.4's
  stream-offset contract against real bytes — `streams.json` records 171903, exactly the
  size of the file under `initial/`, and the final file's first 171903 bytes are identical.

- Observation: `plain-two-turn` makes the drift ritual cost money. Evidence: it is
  `census: true`, so `make probe` re-runs it against the live binary and spends two `haiku`
  turns, about one US cent, every time. Impact: the drift ritual is no longer free, and the
  same account pays for the agents working on this repository. Recorded so the cost is a
  decision rather than a surprise.

- Observation: A session's **first** resume appends one `mode` record to its transcript and
  mirrors it; no later resume of that session appends or mirrors anything. Evidence: three
  experiments against a session already resumed once — idling fifteen seconds rather than
  six, closing the session, and resuming with a different `--permission-mode` — each
  produced zero `transcript_mirror` frames and left the transcript at 32 records with one
  `mode` record. So the write is not on a timer, not at close, and not a write-on-change of
  the mode. The mechanism was not located in the extracted bundle; this is recorded
  behaviour, not a reading of the source. Impact: C3's reducer must expect one non-history
  append across a resume and must not render it as conversation, and `resume-no-replay`
  cannot take part in the census — `diff` resumes the session `plain-two-turn` recorded,
  which the fixture itself has already resumed, so the mirror never comes back and the strict
  comparison reports `removed pair transcript_mirror` for a reason that has nothing to do
  with the binary.

- Observation: The extracted bundle's SPEC chapter files under
  `~/claude-code-bundle/2.1.257/SPEC/` are no longer on disk on 2026-09-04; the bundle
  source (`cli.pretty.js`, `modules/`) and `docs/tui-parity/` remain. Impact: chapter
  citations inherited from the parent are kept as recorded; new facts in this document
  cite the parity files or the bundle modules, and S6's baseline evidence comes from the
  installed binary's embedded source rather than a chapter.

- Observation: A completed `set_cwd` moves the session's transcript, so one file has two paths
  in one recording. Evidence: `session-mirror-relocation`. The answer carries
  `transcript_relocated: true`, and afterwards `projects/<old slug>/` holds no file for the
  session while `projects/<new slug>/` holds it under the same session-id name; the mirror
  frames name the old path for the first thirty entries and the new one for the rest, and the
  transcript's records carry both `cwd` values. Impact: `verify`'s mirror-fidelity check keyed a
  stream by its path and so split one file into two streams, one of which no fixture can hold —
  it now resolves a mirrored path to the transcript file the name belongs to, falling back to
  the path when the name is ambiguous. `snapshot` needs no change: it finds the file by session
  id wherever it ended up. The parent's own record-ingestion decision already keys on *logical
  stream* rather than file path, which is exactly the distinction this makes concrete.

- Observation: A resume appends one transcript record that is never mirrored.
  Evidence: `session-mirror-resume`. Between the state at spawn and the first mirrored entry
  the CLI appends exactly one record — an `ai-title` duplicating the title the session already
  had on the session's first resume, an `atis-latch` on a later one. Everything after it is
  mirrored in order. Impact: **[parent-impact]** on §7.3's invariant clause, "the records
  delivered in `transcript_mirror` frames during the recording equal, by record identity, the
  file's records in the byte range appended during that same recording". That is true of every
  fresh session recorded here and false of every resume, by exactly one record at the head of
  the range. The clause is binding prose and is not edited here; the parent's tending session
  reconciles it. X8 gains `unmirrored_prefix: <int>` in `fixture.json` to express it — declared
  by the scenario in `META`, never inferred from the frames, and checked for exactness in both
  directions, so a second unmirrored record still fails the gate and a declaration nothing needs
  is reported as stale. Same shape and same reasoning as `late_responses` and
  `withdrawn_requests`.

- Observation: `claude_oauth_wait_for_completion` does not hang, so the occasion
  `withdrawn_requests` was added for did not arise. Evidence: `control-shapes` sends it with no
  login in progress and it answers within milliseconds, with the error `No active
  claude_authenticate flow`. The scenario's ten-second wait never expires, no
  `control_cancel_request` is sent and the fixture declares nothing. Impact: the reading of the
  binary that motivated the field stands unchallenged — it was about what a cancel does, not
  about what this request does — but the field is now an unexercised escape. It is kept: the
  reasoning behind it is a property of every host-originated subtype outside the CLI's
  three-entry abort map, and this request simply turned out to have an answer ready. A later
  scenario that reaches a request with no answer ready is what will exercise it.

- Observation: A capped model-driven scenario's `result` pair is not reproducible when the
  model chooses how many turns to spend. Evidence: `exit-plan-mode`. Approving a plan hands the
  work back to the model, which starts implementing; recorded at `--max-turns 5` the session hit
  the cap and ended `result/error_max_turns`, and `make probe` re-running the same scenario at
  the same cap finished and ended `result/success`. §4.4 alarms on an added and on a removed
  pair in required mode as well as exact, deliberately, so `deterministic: false` is not an
  escape. Impact: `exit-plan-mode` is `census: false`, the third instance of the exclusion rule
  and the first whose cause is not a consumed precondition. The rule generalises accordingly:
  what a scenario cannot be expected to reproduce may be a precondition it used up or an outcome
  the model picks. Every later catalogue entry whose length the model chooses —
  `background-shell`, `nested-depth-2`, `explore-depth-1` — should be recorded expecting this.

- Observation: `ExitPlanMode` is a deferred tool and its plan file is written inside the config
  home. Evidence: `exit-plan-mode`. The model spends a turn on
  `ToolSearch {"query": "select:ExitPlanMode"}` before it can call the tool, the same extra turn
  `send-user-file` records for an SDK MCP tool, and the ask's `input` carries `planFilePath`
  pointing at `<config home>/plans/plan-<slug>.md`, a file the CLI wrote there itself. Impact:
  the plan card may read that file and must never write it (X9); and the deferred-tool turn is a
  real cost on every scenario that drives a tool the model has not already fetched.

- Observation: `can_use_tool` does not have one key set. Evidence: the three permission
  recordings. A `Write` ask carries `description`, `display_name`, `input`,
  `permission_suggestions`, `subtype`, `tool_name`, `tool_use_id`; an `AskUserQuestion` and an
  `ExitPlanMode` ask carry `display_name`, `input`, `requires_user_interaction`, `subtype`,
  `tool_name`, `tool_use_id` — no `permission_suggestions` and no `description`. The
  `decision_reason_type` field the recording plan expected on the `Write` ask is not present on
  2.1.259 at all. Impact: the census's required-key sets are per pair, so a corpus holding only
  one of these shapes would record its optional fields as required; C2's model for the ask must
  make `permission_suggestions`, `description` and `requires_user_interaction` optional.

- Observation: A pair's *presence* varies run to run for a model-driven scenario, and the
  census had no way to say so. Evidence: `system/thinking_tokens` appears in five of the ten
  recorded fixtures and not the other five, carries real content
  (`estimated_tokens`, `estimated_tokens_delta`, sometimes `user_message_uuid`), and is emitted
  only when the model actually produces thinking tokens — which is the model's choice, not the
  binary's. `make probe` against the *same* 2.1.259 the fixtures were recorded on reported
  `session-mirror-relocation: added pair system/thinking_tokens` on one operator's runs and
  nothing on another's, from the same commit. Impact: the census modelled optionality at three
  levels — `keys`/`required_keys`, and the same pairing for payload and body keys — and not at
  the level of the pair, so a frame the model emits sometimes could only read as *added* or
  *removed*, both of which alarm. That gap is the common cause behind more than one exclusion,
  and an intermittently red gate is worse than a red one, because it is the kind people re-run
  rather than read. §4.4 and X8 are amended (Revision Notes) to give a pair the same
  required-versus-optional treatment its keys already had.

- Observation: The census's coverage question, answered from eleven recordings. Of the pairs a
  model-driven recording produces, three classes behave differently under re-run. **Stable
  regardless of the model**: the handshake, the in-process server's bring-up, `auth_status`,
  `rate_limit_event`, `system/init`, `transcript_mirror`, `user`, `stream_event`, and every
  `control_request`/`control_response` pair the *scenario* sends — these are the wire contract
  and they reproduce, which is why `control-shapes`, the fixture that pins §6.4, is the most
  reliable census member in the corpus. **Emitted at the model's discretion**:
  `system/thinking_tokens` and, by the same argument, anything else the engine emits only when
  the model takes a particular path. These are handled by declaration or accumulation and stay
  in the census with their key sets still checked. **Determined by how many turns the model
  chooses to spend**: the `result` pair, which is `result/success` or `result/error_max_turns`
  depending on whether the session fit inside `--max-turns`. This last class is the one that is
  genuinely not reproducible, and it is not the same gap: the two `result` pairs are mutually
  exclusive outcomes rather than one optional frame, and declaring both optional would make the
  census blind to whether the recording completed at all — which is a distinction worth keeping.
  So the pattern is not "model-driven recordings are unstable"; it is that a scenario is
  reproducible exactly when nothing the *model* decides can change how many turns it takes.
  `exit-plan-mode` fails that test because approving a plan hands the work back to the model,
  and it stays outside the census after the pair-optionality fix, which removed one of its three
  drift lines and neither of the two about `result`. A scenario that would otherwise fail it can
  usually be repaired at the source, by giving the model no reason to spend a variable number of
  turns, which is what every other fixture in the corpus does and why eight of nine census
  members hold.

- Observation: A subagent's mirror carries entries that are not records of the stream it names.
  Evidence: `explore-depth-1` and `nested-depth-2`. Every `transcript_mirror` frame for
  `subagents/agent-<id>.jsonl` opens with an entry of type `agent_metadata`, and the `.jsonl`
  never receives it: it is the neighbouring `agent-<id>.meta.json` sidecar's content, field for
  field, with a `type` added. The engine emits one when the agent starts and another each time
  an auto-turn re-engages it, so neither the count nor the position is fixed. Impact: **no
  parent impact -- §7.3 already prescribes exactly this, and these recordings are the first
  confirmation of it on the wire.** The invariant clause reads "the records delivered in
  `transcript_mirror` frames during the recording equal, by record identity, the file's records
  in the byte range appended during that same recording: not the whole file, because the mirror
  never carries history, **and with `agent_metadata` entries compared against the paired
  `.meta.json` instead**", and §7.3's source-arbitration paragraph already names "the
  `agent_metadata` record the CLI mirrors into the transcript stream when it writes a
  `.meta.json` (*SPEC 18.25.2*), which the reducer treats as its own record type rather than
  expecting it in a JSONL". So `verify` holding the entry against the sidecar is compliance with
  the clause and not a deviation from it, and the field-for-field equality this check used to
  apply was `verify.py`'s own addition on top of the spec -- the Decision Log rejects "whole-file
  equality as the invariant" in as many words. This entry was first written as a
  `[parent-impact]` on a quotation that stopped one clause short of the sentence that disproves
  it, which is the error worth recording: the clause was read second-hand from an earlier
  Surprises entry in this document rather than from §7.3, and a truncated quotation removes
  exactly the half that would have stopped it. What the recordings do add is the wire evidence
  the clause never had, and one detail it does not state -- the entry arrives at the *head* of a
  subagent stream's mirror and again on each re-engagement, so a host reading the mirror has
  `parentAgentId` and the agent's type before the sidecar file exists, which is what §8.8's tree
  needs at spawn time.

- Observation: The mirror-fidelity check's premise -- that a mirrored record equals the record
  on disk -- is true of every main stream in the corpus and **not** of an agent stream.
  Evidence: `explore-depth-1`, recorded three times against the same binary. In one recording
  two of eleven subagent records differed from their mirrored copies in `message.stop_reason`
  (`null` against `end_turn`) and `message.usage` (a partial object against the finalised one);
  in the others every record agreed. The divergence is permanent, not a flush race: the file was
  still in the partial state long after the process exited. The two are snapshots of one mutable
  record taken at different moments, the file is written once and never rewritten, and which
  snapshot each takes is timing. Impact: a count of diverging records would rot on the next
  recording -- but *which* fields can disagree is not a race and does not rot, so the escape
  names them. `mirror_identity_only` maps a stream scope to the field paths that may differ:
  `{"subagents/": ["message.stop_reason", "message.usage"]}` on both agent scenarios. Those
  streams are compared by record identity, which is §7.3's own comparison -- "logical stream
  ... plus record `uuid`, or a stable hash of the record for uuid-less records", with the
  Decision Log rejecting whole-file equality outright -- and every field outside the declared
  list is still compared, so a genuinely corrupt agent mirror fails. A declared scope that
  matches a stream which is not an agent sidecar is refused, because the match is a substring
  test and a scope of `.jsonl` would otherwise relax every stream in the fixture. Count, order
  and identity stay strict and main streams are untouched. For C3 the consequence is that
  neither side is authoritative for an agent run's usage numbers, and a reducer that reconciles
  them must pick one deliberately.

- Observation: `task_started` does not have one shape, and a task id is not seen once.
  Evidence: `background-shell` and `nested-depth-2`. A `local_bash` task's `task_started` carries
  `task_id`, `tool_use_id`, `description`, `is_backgrounded`, `task_type`, `uuid` and
  `session_id` and **no `spawn_depth` and no `subagent_type`**; a `local_agent` task's carries
  both plus `prompt`. And in one `nested-depth-2` recording the engine emitted a second
  `task_started` for the *same* `task_id` when an auto-turn re-engaged the backgrounded depth-1
  agent. Impact: the census's per-pair required-key sets would have recorded the agent fields as
  required had only agent scenarios been recorded, which is the same lesson `can_use_tool` taught
  wave B; and the scenario helper that waits for tasks to settle compared started and ended ids
  as **sets**, so the earlier notification read as settling the later start. That recording
  closed two seconds into the re-engagement, sent `end_session` under a live agent -- the failure
  the global constraint names -- and ended `result/error_during_execution`. The helper now counts
  occurrences and waits for ten seconds with nothing outstanding.

- Observation: A backgrounded agent brings up a `system/init` and a `result` of its own.
  Evidence: `explore-depth-1` records two of each for one prompt, `nested-depth-2` three of each
  for one prompt with two agents, `background-shell` two `result` frames for one prompt and one
  shell. Impact: a host completing a turn on every `result` frame counts two turns for one
  prompt, and one keying session identity off `system/init` sees a second handshake that is not
  one. `CLAUDE_CODE_FORK_SUBAGENT=1` is on every launch line, so this is the normal case for
  afleet and not an edge.

- Observation: The `Notification` hook's idle threshold is about six seconds, not a minute.
  Evidence: `notification-hook`. The `can_use_tool` arrives at t=3595 ms and the `hook_callback`
  for `afleet.notification` at t=9601 ms. Impact: the plan budgeted 75 seconds and treated a
  no-fire as the finding; the real threshold is an order of magnitude below that, so item 53
  needed no provisional clause and the C5 setting question the plan anticipated does not arise.
  The threshold is the binary's; afleet's §8.7 toggle governs whether a banner is shown, not when
  the engine raises one.

- Observation: A scenario's `notes` are written before `record` tokenises the capture.
  Evidence: `background-shell`'s note quotes `output_file` as
  `/private/tmp/claude-501/.../tasks/<id>.output` while the same value in `frames.ndjson` reads
  `<artifacts>/...`. Impact: nothing under `frames.ndjson`, `transcript/` or `artifacts/` is
  affected and the raw form is useful evidence about the real path, but `notes` is the one field
  of `fixture.json` where a path is not in the token space, and a consumer reading it as
  tokenised text would be wrong. Recorded rather than repaired: the notes are prose for a
  reviewer, and redaction -- which is the rule that matters -- does run on them.

- Observation: A spike run from inside a Claude Code session inherits that session's own
  markers, and one of them turns transcript saving off in the interactive CLI. Evidence:
  `spike-contention`. The interactive holder rendered the resumed session's history and never
  registered, and its status line read `Transcript saving is off -- inherited
  CLAUDE_CODE_CHILD_SESSION marker`. With every `CLAUDE*` variable dropped from the holder's
  environment, the same run registered a second record under the same `sessionId` -- the
  observation S12's whole finding rests on, and it was silently absent one run earlier.
  Impact: `harness.Launch.environment` drops three variables (`CLAUDE_CODE_REMOTE`,
  `CLAUDE_CODE_CONTAINER_ID`, `CLAUDE_CODE_ENTRYPOINT`) and inherits the rest, so every
  recording in the corpus was made with the recording agent's `CLAUDECODE`,
  `CLAUDE_CODE_SESSION_ID` and `CLAUDE_CODE_CHILD_SESSION` set. Nothing in the corpus is known
  to be wrong because of it -- the print-mode path wrote its transcripts and registered its
  sessions in every recording and in every spike here -- but it is inheritance nobody chose,
  and the same class of marker is what made one spike observation come back empty and
  plausible. The spike scenario builds its own terminal environment by dropping the whole
  `CLAUDE` prefix rather than a list, since a list needs extending each time the hosting CLI
  gains a marker. Recorded rather than repaired in the harness: that changes the environment
  every future recording is made in while the corpus was recorded under the present one, which
  is a wave's decision and not a spike's.

- Observation: An interactive `claude --resume` never reaches the session it names until the
  workspace-trust prompt is answered. Evidence: `spike-contention`'s first run opened on
  "Quick safety check: Is this a project you created or one you trust?" for
  `/private/tmp/afleet-fixtures/plain-two-turn` and exited 1 on the default choice, "No,
  exit", without registering anything -- although eleven headless recordings had already run
  in that directory under the same config home. Impact: trust is a *terminal* gate rather than
  a session gate. Print mode resumes an untrusted directory without a word, and S13's
  wire-side `needs_trust` belongs to `set_cwd` alone, so afleet's *Open in terminal* can hand
  a user a session that stops on a dialog afleet never saw and never will. The spike had to
  answer the prompt before the contention question underneath it could be asked at all.

- Observation: S17 makes `--agent` runtime-mutable and one parent table still calls it
  restart-required. Evidence: `apply_flag_settings {settings: {agent}}` changed the next
  turn's system prompt (parent Revision Note `C1/S17`). Impact: **[parent-impact]** on §7.7's
  launch-settings table, whose Restart-required row lists `--agent` beside `--worktree` and
  the stream flags. The `/agent` row in the same section already said the question was open
  "until spike S17 shows it takes effect", so the design anticipated the move and the two
  halves of §7.7 now disagree with each other. Binding prose is not edited here; the parent's
  tending session reconciles them.

- Observation: The two name-based secret exemptions are tested before any value test, so they
  now exempt containers as well as scalars. Evidence: `_is_secret_key` returns False on
  `SECRET_EXEMPT` and `USAGE_COUNTERS` before it looks at the value, and since rule 2 was
  widened to replace a container the same exemption reaches one. Impact: `{"projectKey": {...}}`
  and `{"hookCallbackIds": {...}}` would now survive whole where before only their string forms
  did. Recorded rather than narrowed: both names earned their exemption from a cited structural
  role that a container form would serve as well as a scalar one, no corpus frame carries either
  as a container, and narrowing them by type would put a type test back into a module whose
  whole lesson is that names and types are the wrong instruments and position is the right one.
  A reader meeting this should know it is the consequence of an ordering, not an oversight.

- Observation: `SECRET_STRUCTURE_PATHS` matches as a trailing-segment suffix, so its entries
  exempt `effective_keys`, `sources_keys` and `sources_keys.keys` at *any* depth, not only in
  the `get_settings` response the comment justifies them from. Evidence: `_path_exempt` strips
  list indices and tests `bare == c or bare.endswith("." + c)`, which is the same matching the
  older `behaviors.key` and `subagent_stats.killed.user` entries use. Impact: a
  `sources_keys` field appearing somewhere else in the protocol would be exempt without anyone
  deciding it should be. It is left as it is because the suffix matching is the module's
  existing convention and writing these three anchored to a full path would make them the only
  entries that behave differently, which is a worse trap than the widening; and because the
  names are rule 5's own output, so a field of that name in another position is far more likely
  to be the redactor's own than the engine's. Worth knowing before adding a fourth entry: an
  entry here is a claim about a *name at any depth*, not about the one place you found it.

- 2026-09-05, from the follow-up wave's `compact-boundary`: **the engine puts
  `compact_boundary` on the wire.** §7.3 lists it among the `system` records that reach the
  file and never the wire, and therefore among the kinds C3's differential invariant compares
  file-to-file only. The recording carries a `system` frame with `subtype: "compact_boundary"`,
  keys `type, subtype, session_id, uuid, logical_parent_uuid, compact_metadata`, and the same
  record arrives in a `transcript_mirror`. Impact: **[parent-impact]** on §7.3's exclusion
  list, which should lose `compact_boundary`; while it stands, the differential test never
  compares a record the wire does deliver. The list was written before any compaction had been
  recorded, which is exactly the case it could not have been checked against.

- 2026-09-05, from the same recording: **a compaction is a paid turn that reports itself as no
  turn at all.** The `result` after `/compact` is `subtype: "success"`, `is_error: false`,
  `num_turns: 0`, `result: ""`, with an all-zero `usage` block and `total_cost_usd` about
  0.0059. A host that counts turns from `num_turns` or sums tokens from `usage` sees nothing;
  only the cost field shows the summary was generated. And the boundary record on disk carries
  `parentUuid: null` with the link back in `logicalParentUuid`, so a reducer following
  `parentUuid` alone reads one file as two disjoint trees.

- 2026-09-05, from the same wave: **an exact-match key set cannot deliver rule 1's
  "anywhere".** `bridge-session` transcript records carry `ownerAccountUuid` and
  `ownerOrganizationUuid`, and `IDENTITY_KEYS` -- which matched the normalised key exactly, by
  deliberate design, because `user` as a substring would swallow the `UserPromptSubmit` hook
  key -- walked past both. Two fixtures were written with a live account uuid and a live
  organization uuid in them and `verify` passed both, because `verify` re-scans for the same
  rules and inherited the same blind spot. The fix widens `account` and `organization` to
  substring matches alongside `email`, in a new `IDENTITY_SUBSTRINGS`, with a regression test on
  the `bridge-session` shape. It changed no other fixture: a scan of the whole corpus found
  those two key names and no other non-exact `account`- or `organization`-containing key
  anywhere, so no signature was invalidated beyond the two fixtures being recorded. The general
  lesson is the one the account-name surprise already taught in a different key: a rule keyed on
  a name catches the names it was told about, and every prefix a future record invents is a new
  silent hole. Whether the remaining `bridgeSessionId` should also go is left as a reviewer's
  judgement and recorded in the fixture's README rather than settled here.

## Outcomes & Retrospective

Measured on 2026-09-04 at `865e55a` on `child/c1-probes-fixtures`, against the declared
baseline binary `~/.local/share/claude/versions/2.1.259`. Every figure below is an
observed output, not a restatement of intent; where §5's wording no longer describes
what was built, the adaptation is named rather than either side being bent to fit.

### The gates

**Tool tests — pass on both interpreters.** `PYTHON=/usr/bin/python3 make test-tools`
(Python 3.9.6) and `PYTHON=/opt/homebrew/bin/python3 make test-tools` (Python 3.14.6)
each exit 0, each printing `Ran 225 tests … OK` for `Tools/probe/tests` and
`Ran 22 tests … OK` for `Tools/fake-claude/tests`.

**G1 Fixtures — pass, against a catalogue larger than §5 describes.**
`make verify-fixtures` prints `all fixtures pass` and exits 0 over all eighteen fixture
directories. §5 says "the thirteen recorded fixtures and two synthetic ones of §4.7";
`Fixtures/` holds **sixteen recorded and two synthetic**. The three beyond the original
table are `rate-limited-turn` (Surprises: an unplanned zero-cost recording of a rejected
turn), `session-mirror-resume` (Revision Notes: §4.7's relocation row is two processes
and therefore two fixtures) and `notification-hook` (in §4.7's table but not in the
count §5 inherited). Every fixture carries a signed `review` block, an `initial/`
directory and a `streams.json`; every recorded fixture with a turn carries at least one
`transcript_mirror` frame, `zero-cost` carrying none because it starts no turn.
`resume-no-replay` carries exactly one, the `mode` record a first resume appends. Both
dialog fixtures now read `hypothesis: false`, S6's extraction having closed. The four
by-hand checks hold: `Fixtures/nested-depth-2/transcript/_slug_/*/subagents/` holds
`agent-a4bd7d1f17a7e8011.jsonl`, `agent-a558f55cd34e3996f.jsonl` and both `.meta.json`
sidecars; `Fixtures/background-shell/artifacts/` holds the task output file, and the
`task_notification` names it as
`<artifacts>/…/tasks/bcdsdgryt.output`; `Fixtures/send-user-file/frames.ndjson` carries
the `tools/call` request with `{"files": ["a.txt", "b.txt"], "caption": "two files",
"status": "normal"}` and the matching response. Verification emits 45 report-only
warnings and no failures: 42 are the account-name check of §4.5's third report-only
rule, which is by design a finding for a human rather than a failure, and three record
that a subagent stream's `agent_metadata` entry was checked against its `.meta.json`
sidecar rather than against the stream, which is §7.3's own prescription.

**G2 Census — pass in both halves.** `make probe
CLAUDE=$HOME/.local/share/claude/versions/2.1.259` exits 0: `ok` on all thirteen census
fixtures (`ask-user-question`, `background-shell`, `control-shapes`, `explore-depth-1`,
`nested-depth-2`, `notification-hook`, `permission-allow`, `permission-deny`,
`plain-two-turn`, `send-user-file`, `session-mirror-relocation`,
`session-mirror-resume`, `zero-cost`), with `exit-plan-mode`, `rate-limited-turn` and
`resume-no-replay` skipped as `census: false` and the two dialog fixtures skipped as
synthetic. G2's wording says "against the installed 2.1.259"; the installed `claude`
is 2.1.260 and the corpus is pinned to the 2.1.259 binary path, so the gate is run
against the pin, which is what the Revision Notes make the baseline.

The two fake-claude injections both alarm and both exit 1. A script emitting
`{"type": "afleet_invented", "x": 1}` after the third out frame produces
`plain-two-turn: DRIFT (1 difference)` / `added pair afleet_invented` — exactly one
added pair, as the gate asks. A script patching `system/init` with
`"remove": ["capabilities"]` produces `plain-two-turn: DRIFT (2 differences)` /
`system/init: removed required keys capabilities` and `capabilities: not captured in
observed`. The second line is the same removal seen at the census's top level, where
`capabilities` is lifted out of `system/init`, so one stripped key legitimately shows
twice; the key is named, which is what the gate requires. Two notes on the commands.
`plain-two-turn` is the fixture to use here because it is the first recording with a
`system/init` frame at all — before it existed, G2's second half was not demonstrable.
And run through `make`, both injections report `exit=2` rather than `exit=1`: that is
`make`'s own status for a failed recipe. Run directly, `probe.py diff` exits 1.

**G3 Findings — pass.** `grep -n 'C1/S\|C1/G' docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md`
returns fifteen dated notes on the parent in this branch: `C1/S2`, `C1/S5` (twice — the
registration half and a later `completed` note for the `tools/call` half), `C1/S6`,
`C1/S8`, `C1/S10`, `C1/S11`, `C1/S12`, `C1/S13`, `C1/S14`, `C1/S15`, `C1/S16`,
`C1/S17`, `C1/S18` and `C1/G2`. That is all twelve §5 names plus S2 and the drift note.
Each was read for the clause it settles, not merely for existing: fourteen of the
fifteen cite a parent section by number (§6.1, §6.2, §6.4, §6.5, §6.8, §7.2, §7.3, §7.4, §7.7, §8.2, §8.4,
§8.7, §8.8, §15), and `C1/S11` names its clause the way §4.9 asks instead — "settles how
*Fork from here* is implemented", the parent's C1 wording. Two `[parent-impact]` entries
are named in Surprises: §7.3's mirror-equality invariant, which is false of a resume by
exactly one record at the head of the range, and §7.7's launch-settings table, whose
Restart-required row still lists `--agent` that S17 showed is runtime-mutable. A third,
on `agent_metadata`, was withdrawn during wave C after §7.3 was read to the end of the
sentence; that withdrawal is itself recorded.

One inaccuracy was found and fixed here rather than handed on. The `C1/S5, completed`
and `C1/S2` notes were written before the pin and cited `2.1.260` for `send-user-file`
and `resume-no-replay`, both of which were re-recorded at 2.1.259 when the corpus was
pinned; both now name 2.1.259. The findings themselves were never affected, but a wrong
version inside a protocol finding is the kind of error that survives, because it looks
like evidence — and the point of pinning the corpus was that a later reader can take a
version at face value. This is a factual slip in C1's own note about C1's own fixture,
which needs none of the parent's judgement; the parent's tending session reconciles
conflicts between a child's findings and binding prose, which this is not. **The other
thirteen notes were checked the same way and needed no correction**: every fixture a note
names carries the version the note claims, and the only two remaining mentions of 2.1.260
are deliberate — `C1/G2` *is* the 2.1.259-against-2.1.260 drift measurement, and `C1/S15`
records that the `setQuestionPreviewFormat` branch is present verbatim in both installed
versions while citing its own fixture at 2.1.259.

**G4 Redaction — pass.** The five named tests, fully qualified so an empty selection
cannot pass silently, print `Ran 5 tests … OK`:
`test_record_no_unredacted_byte_reaches_disk_and_review_is_unsigned`,
`test_unsigned_review_fails`, `test_planted_email_fails_in_any_file`,
`test_orphaned_request_fails` and `test_collect_artifacts_and_tokenise`. `find Fixtures
-type d -name raw` returns nothing. `Fixtures/REVIEW.md` exists at checklist version 2,
and `verify` passes every committed fixture.

### Spikes: what closed, and what closed only halfway

All thirteen spikes the child owned produced a finding on the parent. Five settle a
question completely — S2 (a resume replays nothing), S5 (the SDK server registers under
`--strict-mcp-config`, so the scenario's fallback launch was never needed, and the
`tools/call` round trip is recorded), S13, S14 and S18 (the `Notification` hook's idle
threshold is about six seconds, an order of magnitude inside the budget, so item 53
needed no provisional clause and the C5 setting question does not arise). S15's answer
is a value: `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT` is compared by equality against
`"markdown"` and `"html"` and nothing else, and `markdown` is now on every launch line.

Four settle one half and say so. S6 confirms both dialog kinds structurally on the
2.1.259 binary, which is enough to clear `hypothesis` on the two fixtures and take item
62 off provisional — but the decline legs' `result` subtype, the placeholder copy, the
park deadline and whether an undeclared kind reaches a host at all still need a
recording. S17 settles both of its halves positively while recording that no readback
exists for a session-carried agent (`system/init.agent` is absent even under `--agent`),
and that the companion flag `--resume-drops-turn` was read from the binary's option
table and never exercised. S8's control-response reasoning is anchored on bundle strings
and confirmed on the recording, but `withdrawn_requests`, the field S8's investigation
motivated, remains an unexercised escape: `claude_oauth_wait_for_completion` answers in
milliseconds and never needed withdrawing. S12 answers the contention question but only
after the workspace-trust prompt, which is a terminal gate the wire never shows — so
afleet's *Open in terminal* can hand a user a session that stops on a dialog afleet
never sees.

Two census members are worth watching rather than trusting. `exit-plan-mode` left the
census because approving a plan hands the work back to the model and the turn count is
the model's to choose. `nested-depth-2` produced `added pair
result/error_during_execution` on one run against 2.1.260 and is the member most likely
to flap again; a second flap of the same pair is the evidence that would take it out of
the census rather than something to declare optional.

### Live recordings and cost

Sixteen recorded fixtures survive in the corpus, from at least twenty-four live
recording runs — eight were discarded to defects the recording itself exposed rather
than to flakiness. Nine short `haiku` turns went to the four live spikes;
`spike-contention` spends nothing because it sends no prompt. `zero-cost` is the fixture
that proves a whole session can be recorded for nothing: its own `get_session_cost`
answer reads `Total cost: $0.0000 … Usage: 0 input, 0 output, 0 cache read, 0 cache
write`.

The measured spend across the child is **about 2.5 USD**: roughly 0.03 in wave A, 1.05
in wave B, 1.4 in wave C, 0.04 in the spike wave, plus about 0.25 for the single
verification run of the ritual made for this section.

**The split matters more than the total, and it is the number whoever budgets a baseline
bump needs.** §4.7 costed a full re-record of the catalogue and never costed the gate.
`make probe` re-runs every census scenario against a live binary and now costs **roughly
0.25 USD per run** across thirteen census fixtures — measured at 0.13 across wave B's
nine, so it scales with the catalogue and with how many fixtures drive subagents. Wave C
spent about 0.13 on seven recordings and about 1.25 on five ritual runs: the drift ritual
is an order of magnitude more expensive than the recordings it guards. It stays an
on-demand ritual (parent §6.10), never a per-commit gate.

### What surprised

The full list is in Surprises & Discoveries above; five of them change how a consumer
must read this corpus.

- **The baseline is a binary path, not "the installed CLI".** `claude` auto-updated from
  2.1.259 to 2.1.260 mid-wave and four fixtures silently followed it. The corpus is now
  pinned to `~/.local/share/claude/versions/2.1.259`, recorded in every fixture's
  `launch.argv[0]`. That directory is pruned by future upgrades, which is the argument
  for the fixtures being the durable evidence and the binary merely the instrument.
- **A transcript holds far more than its exchanges.** `plain-two-turn`'s two prompts and
  two replies produce thirty-one records across nine distinct `attachment` kinds plus
  `queue-operation`, `file-history-snapshot`, `atis-latch`, `ai-title` and `last-prompt`.
  A reducer modelling a transcript as user and assistant records drops most of the file.
- **A backgrounded agent brings up a `system/init` and a `result` of its own.** With
  `CLAUDE_CODE_FORK_SUBAGENT=1` on every launch line this is the normal case, so a host
  completing a turn on every `result` counts two turns for one prompt.
- **A mirrored record is not always the record on disk.** For agent sidecar streams the
  mirror and the file are two snapshots of one mutable record; `message.stop_reason` and
  `message.usage` can disagree permanently. Neither side is authoritative for an agent
  run's usage numbers.
- **A redaction rule that keys on *what* a value is only catches values it was told
  about.** The account name sat in the owner column of every `ls -l` line and walked past
  three rules; the fix is positional. On this machine the name is an innocuous English
  word, which is exactly why it survived review twice and exactly why the fix must not
  depend on that luck.

### What the next owner should know

- **The scratch config home is logged into a different account than the one this child
  started on.** `/tmp/afleet-fixtures/config-home` now holds credentials issued on
  2026-09-04 for a `claude_max` organisation on the `default_claude_max_20x` rate-limit
  tier, with `hasExtraUsageEnabled: false`. Wave A ran on the earlier login, whose
  seven-day window it exhausted.
- **`rate-limited-turn` can never be re-recorded, and is not a stale fixture to
  refresh.** Its precondition is a spent weekly window, and that window is gone with the
  account. It is the one fixture at 2.1.260 and the one carrying the four-variable
  `launch.env` that predates S15. Nothing rests on the difference: it is `census: false`,
  it never takes part in a comparison, and it is evidence about the shape of one rejected
  turn rather than about a version's frame inventory. Do not treat its version tag as a
  defect to fix.
- **The recording environment inherits the driving agent's `CLAUDE_CODE_*` markers, and
  this is a fidelity caveat C2 and C3 must carry.** `harness.Launch.environment` drops
  three variables (`CLAUDE_CODE_REMOTE`, `CLAUDE_CODE_CONTAINER_ID`,
  `CLAUDE_CODE_ENTRYPOINT`) and inherits the rest, so every recording in this corpus was
  made with the recording agent's `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` and
  `CLAUDE_CODE_CHILD_SESSION` set. One of those markers turns transcript saving off in
  the interactive CLI, and it hid S12's central observation for a full run — the run came
  back empty and plausible. Nothing in the corpus is known to be wrong because of it; the
  print-mode path wrote its transcripts and registered its sessions in every recording
  and every spike. But **the app will spawn the CLI with no such parent**, so the
  recording environment and the app environment differ, and a differential test that
  finds a disagreement here should suspect the inheritance before it suspects the
  engine. It is recorded rather than repaired because changing the environment table
  changes the environment every future recording is made in, while this corpus was
  recorded under the present one — a wave's decision, not a spike's.
- **`launch.env` is recorded evidence about one recording, read from the fixture and
  never recomputed.** C2 should assert ClaudeWire's own builder against the spec's §6.1
  table, and must not assert a committed fixture's `launch.env` against its own constant.
- **S5's fallback launch was never needed.** The SDK MCP server does register under
  `--strict-mcp-config` on 2.1.259, so `send-user-file` records the flag present; the
  scenario's conditional drop is untaken code kept for a future baseline.

### Not verified here

The `hypothesis` flags on the two dialog fixtures were cleared by a structural
extraction from the 2.1.259 binary, not by a recording; how the engine reaches those
shapes on the wire is still unobserved. `make probe` was run once for this section
rather than repeatedly, so this verification adds one data point to the ritual's
history and cannot speak to flapping. And a ritual run that finds nothing still cannot
demonstrate that the ritual would find something — the sensitivity evidence is the two
fake-claude injections above, not the clean live run.

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
- 2026-09-04: X8 gains `withdrawn_requests: [request ids]` in `fixture.json`, beside
  `late_responses`, and it joins §4.4's required core. `verify` honours an entry only when
  three things hold together: the id belongs to a host-originated request, the fixture carries
  a `control_cancel_request` for that id travelling host to CLI — `"dir": "in"` in §4.4's
  vocabulary, because a cancel always names one of the sender's own in-flight requests and so
  travels the same way as the request it withdraws — and the id is listed. Miss any one and the
  request is unanswered exactly as before: an undeclared cancel still fails, a declaration
  without a cancel frame still fails, and a CLI-originated request is untouched by the list.
  The list is written from a scenario's explicit cancel path and never inferred from the
  frames, which is the property that keeps it a declaration about what the host intended rather
  than a blanket amnesty the recorder grants itself. A response that does arrive for a
  withdrawn id closes the lifecycle as an ordinary settlement and needs no `late_responses`
  entry; `late_responses` keeps its existing, narrower meaning, licensing one response after a
  CLI cancel of a CLI-originated request. This supersedes nothing in §4.2: a cancel still does
  not end a host-originated lifecycle, and `withdrawn_requests` is the narrow declared escape
  that the strictness always implied.
- 2026-09-04: The occasion for `withdrawn_requests`, and the reading of the binary behind it.
  `control-shapes` fires `claude_oauth_wait_for_completion` and cancels after ten seconds when
  nothing comes back; that request answers only when the flow promise settles, so it can stay
  open past the cancel and on through `generate_session_title` and `end_session` — an
  unanswered host request in the middle of a recording, which the tolerance for a single
  unwritten frame at the tail deliberately does not cover. Without a declared withdrawal the
  scenario cannot record at all. The reading, from `cli.pretty.js` in the 2.1.258 bundle and
  therefore provisional: the CLI's own schema text for `control_cancel_request` says it tells
  the other side that the sender no longer needs the answer to one of its own in-flight
  `control_request`s, which is the same meaning in both directions and is never itself a reply;
  the stdin handler maps the frame to an abort on the in-flight request, but the abort map is
  populated by exactly three host subtypes, `mcp_call`, `side_question` and
  `remote_tools_announce`, so for every other host subtype the cancel is a no-op and the
  request runs on to whatever answer it would have produced; and even for those three the CLI
  still emits an error `control_response` after the abort. A host-originated request therefore
  always terminates in a response and a host cancel frame is never terminal, which is why
  §4.2's asymmetry stands and why a withdrawal is a declaration about the host rather than a
  claim about the wire. The `control-shapes` recording is the binding evidence; until it exists
  these are readings of a binary, not protocol facts, and the finding they resolve into belongs
  on the parent document as S8, written by whoever records it.
- 2026-09-04: Control-response envelope facts, bundle-derived, and the one shape a host must
  never send. A host error response carries `subtype` exactly `"error"` and `error` as a bare
  string; the stdio transport rejects with `Error(e.response.error)` without a type check, and
  the subtype test is a strict equality against that literal, so anything whose subtype is not
  exactly `"error"` is treated as success and fed to the pending request's schema. A response
  whose payload will not parse is dropped with a log and leaves the request pending
  (`dropped control_response with malformed response payload`). **An error-shaped response to a
  pending `request_user_dialog` is swallowed**: `ignoresErrorShapedDialogResponse` returns early
  unless the response subtype is `error` and the pending request is a non-forwarded
  `request_user_dialog`, and otherwise logs `Ignoring error-shaped control_response for parked
  request_user_dialog` with "not a human choice; dialog stays parked", fires
  `tengu_request_user_dialog_response_ignored`, and drops the answer. The request stays
  outstanding and only the dialog park deadline recovers it, which the parent's investigation
  records as five minutes by default and configurable to never. A host that declares dialog
  kinds in its §6.2 handshake -- which afleet and therefore `harness.py` does, unlike this
  repository's earlier probes, which declared none and so never received a dialog request at
  all -- must never answer one with an error. `harness.py` settles a crashed
  `request_user_dialog` policy with `{behavior: "cancelled"}` for a declared kind, leaves an
  undeclared kind for the binary's deadline, and settles a crashed `elicitation` policy with
  `{action: "cancel"}`; every other subtype keeps the error envelope, which does settle.
  Anchored on the strings above rather than line numbers; the two strings and the method name
  are present in every extracted bundle from 2.1.220 through 2.1.258, and the parent confirms
  them in the installed 2.1.259. Carried to the parent's S8 finding when `control-shapes`
  records.
- 2026-09-04: S6's baseline extraction closes; the two synthetic dialog fixtures leave
  `hypothesis`. `Tools/probe/spikes/extract_dialog_enums.py` reads
  `~/.local/share/claude/versions/2.1.259` (200,225,968 bytes, JavaScript embedded) and tests
  structurally rather than by presence: for each shape it locates that shape's *own*
  definition site and requires every payload key, enum value and default to fall inside a
  bounded window after it, so a hit ties the fields to that definition and not merely to a
  200 MB file. Four sites, each found exactly once, every needle in window. The dialogs read
  `kind:"refusal_fallback_prompt",payload:m(()=>c({originalModel:i(),fallbackModel:i(),apiRefusalCategory:i().nullable().optional(),guidanceText:i().optional(),retractedMessageUuids:R(i()).optional()...})),result:m(()=>ee(["retry_fallback","edit_prompt","cancelled"])),default:"cancelled"`
  and
  `kind:"fable_overage_consent_prompt",payload:m(()=>c({overagesEnabled:M(),modelName:tp(hKt).optional(),balanceCents:A().nullable().optional(),currency:i().nullable().optional()})),result:m(()=>ee(["consent","switch_default","cancelled"])),default:"cancelled"`
  -- payload keys, result enums and `default: "cancelled"` identical to the 2.1.257 reading
  `synthetic/dialogs.py` records, and identical to the payload keys the two fixtures send.
  The frames those answers produce are confirmed at their own definitions too:
  `subtype:x("model_consent_fallback"),choice:ee(["consent","switch_default","cancelled"])`
  with `original_model`, `original_model_name`, `fallback_model` and `persisted_as_default`,
  and `subtype:x("model_refusal_fallback"),trigger:x("refusal"),direction:ee(["retry","revert","sticky"]),scope:ee(["session","local"])`
  with `request_id`, `api_refusal_category`, `api_refusal_explanation`,
  `retracted_message_uuids` and `refused_user_message_uuid`. One correction to the plan the
  script came from: it expected `model_consent_fallback` inside the overage *dialog's* window.
  It is not there and should not be -- it is a stream-json system subtype carrying a schema of
  its own, so the script checks it at that schema instead. Widening the dialog's window until
  the string appeared would have proved only that a 200 MB file contains it. §4.7's condition
  is met, so both fixtures carry `hypothesis: false` and item 62 is no longer provisional;
  `synthetic: true` stays, and with it the `diff` exclusion, because how the engine reaches
  these shapes is still unrecorded. `cli_version` stays `2.1.257-bundle`: that bundle is where
  the frames were authored, and the cleared flag is the separate claim that the installed
  baseline agrees. Anchored on the quoted strings rather than offsets, which drift with every
  build. This settles S6's extraction half only; the questions the schemas do not state --
  the decline legs' `result` subtype, the placeholder copy, the park deadline, whether an
  undeclared kind reaches a host at all -- still need a recording, and S10, S11, S12 and S17
  still need live sessions, so their notes belong on the parent when those can run.
- 2026-09-04: A turn rejected on a spent rate-limit window is recordable at zero cost — the
  engine refuses before any model call — and `rate-limited-turn` records it. The fixture is
  `census: false` with `synthetic: false`. §4.7 excludes synthetic fixtures from the drift
  ritual because their content was never on the wire; this one's exclusion rests on the
  neighbouring property, that its **precondition** is not reproducible on demand. `diff`
  re-runs a census scenario against the live binary, so once the window resets this scenario
  would run two real turns and report the difference as drift — a gate failing for a reason
  unrelated to the CLI, which is how an operator learns to wave a gate through. The rule the
  two cases share: a scenario stays out of the census when re-running it cannot be expected
  to reproduce what was recorded.
- 2026-09-04: Wave A complete. `zero-cost`, `send-user-file`, `plain-two-turn` and
  `resume-no-replay` are recorded, reviewed, signed and committed, alongside
  `rate-limited-turn` from the interrupted attempt. S5 and S2 are both settled on the parent.
  The three model-driven recordings cost about 0.034 USD in total and each succeeded on its
  first attempt.
- 2026-09-04: The census-exclusion rule now has two instances and one statement. A scenario
  leaves the census when re-running it cannot be expected to reproduce what was recorded.
  `rate-limited-turn` qualifies because its precondition — an exhausted seven-day window —
  is not something anyone can arrange; `resume-no-replay` qualifies because its precondition,
  a session that has never been resumed, is consumed by the act of recording it. The rule
  generalises §4.7's existing exclusion of synthetic fixtures, whose content was never on the
  wire at all, and it is the reason neither fixture is instead marked `deterministic: false`:
  §4.4 alarms on a removed pair in required mode as well as exact, deliberately, so the
  permissive comparison is not an escape from an unreproducible recording.
- 2026-09-04: The recorded corpus is pinned to the binary at
  `~/.local/share/claude/versions/2.1.259` rather than to whatever `claude` resolves to, and
  every fixture records that path in `launch.argv[0]`. The parent declares 2.1.259 as the
  protocol baseline and C2 pins `ProtocolBaseline.version` to it, so a corpus recorded against
  2.1.260 would have put C1's evidence at odds with the baseline — repairable only by editing
  binding parent prose, which §4.9 forbids this child. Re-recording four fixtures instead cost
  cents and touched nothing outside this document's scope, and **there is accordingly no
  `[parent-impact]` from the upgrade**: pinning removes the conflict rather than deferring it.
  `rate-limited-turn` is the one permanent exception, for reasons recorded in Surprises and in
  its README.
- 2026-09-04: X8 states what `launch.env` is. **It is recorded evidence about one recording,
  read from the fixture and never recomputed.** Every consumer — `verify`, `fake-claude`'s
  materialise, and whatever C2 reads for X8 — takes the table from `fixture.json`;
  `harness.DEFAULT_ENV_TABLE` is an input to `record` when building a *new* launch line and
  has no other reader. The consequences are the point: a fixture recorded under a smaller
  table stays valid forever, growing the constant invalidates nothing, and two waves
  recording concurrently need not coordinate on it. `rate-limited-turn` is the standing
  instance — it carries the four-variable table that predates S15 and can never be
  re-recorded.

  The property already held when it was written down; what it lacked was being stated and
  tested, so it could have been broken tomorrow by someone reasonable. It is now pinned by
  `test_a_committed_fixture_keeps_the_env_table_it_was_recorded_with`, which verifies a
  fixture whose `launch.env` disagrees with the live constant in both directions — missing a
  variable the constant has, and carrying one it never had — and which was checked against a
  deliberate mutation that recomputes the table, to confirm it fails when it should. The one
  place a fixture assertion is legitimately coupled to the constant is
  `test_record_...`'s check that a *freshly recorded* fixture agrees with the table it was
  just built from; that is true at the moment of recording only, and the assertion now says
  so where a reader will see it.

  This does not touch C2's acceptance. The parent asks C2 to assert "the launch line of §6.1
  and the environment table byte for byte" of *ClaudeWire's own builder against the spec*,
  which is a different assertion from anything about a fixture's recorded table, and both are
  correct. C2 should not assert a committed fixture's `launch.env` against its own constant;
  that is the reading this note exists to prevent.

  The occasion: the table gained `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT` between two recordings
  of the same wave, leaving half the corpus on four variables and half on five. That was
  repaired by re-recording, but the repair is not the lesson — the rule above is, because it
  makes the situation a non-event rather than a discipline to remember.
- 2026-09-04: The catalogue's `session-mirror-relocation` row is recorded as two fixtures,
  `session-mirror-relocation` and `session-mirror-resume`, because a fixture is one process and
  the row's resume is a second one; G1 counts fourteen recorded fixtures. `session_mirror_resume`
  imports the mirror comparison its sibling defines rather than keeping a second copy, so
  `load_scenario` puts the scenario directory it was given on `sys.path` before loading —
  the directory it was given, so a scenario set named by `AFLEET_SCENARIO_DIR` imports its own
  siblings and not the installed ones.
- 2026-09-04: X8 gains `unmirrored_prefix: <int>` in `fixture.json` and `unmirrored_prefix` as a
  `META` key, joining `late_responses` and `withdrawn_requests` as a scenario-declared escape
  from a strict check. It states how many records the engine appends at the head of this
  recording's appended range without mirroring them. `verify` consumes them only at the head of
  the range and only up to the declared count, and then requires the total consumed to equal the
  declaration exactly, so the escape can neither hide a larger gap nor rot into a stale
  allowance. It is not in `REQUIRED_META`: it defaults to zero and every fixture recorded before
  it is unaffected. The occasion is the record a resume never mirrors (Surprises).
- 2026-09-04: `harness.DEFAULT_ENV_TABLE` gains
  `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT: "markdown"`, the value S15 settles. The parent's §6.1
  table lists the variable as "always, once S15 settles", so it belongs on every launch line
  rather than in one scenario's override — which is also what spares `ask-user-question` the
  second recording the budget discipline exists to avoid. Fixtures recorded after this carry
  five entries in `launch.env` instead of four; `Fixtures/REVIEW.md` item 1 allows six, no census
  compares `env`, and `verify` does not read it, so the corpus tolerates the split. Only
  `rate-limited-turn`, which can never be re-recorded, stays at four.
- 2026-09-04: Wave B complete. `permission-allow`, `permission-deny`, `ask-user-question`,
  `exit-plan-mode`, `control-shapes`, `session-mirror-relocation` and `session-mirror-resume`
  are recorded, reviewed, signed and committed against 2.1.259, the declared baseline, and S8,
  S13, S14 and S15 are settled on the parent. Twelve recorded fixtures and two synthetic ones;
  nine take part in the census. `make probe` exits 0 against 2.1.259 and, run again against the
  installed 2.1.260, exits 0 with no drift — the corpus's first comparison across a real version
  bump, and the first evidence that a passing census means the binary held rather than that the
  census compared a binary with itself. The wave cost about 0.65 USD: 0.17 in the seven
  committed recordings, 0.05 in four discarded first attempts, and 0.43 in three full `make
  probe` runs. A second round after the first drift report added a discarded recording and three
  more probe runs, bringing the wave to about 1.05 USD. The ritual is the expensive half, at
  roughly 0.13 a run across nine census fixtures and rising with every model-driven fixture
  added — worth stating plainly, since §4.7 budgeted the price of a baseline bump and not the
  price of the gate, and since a flapping gate is paid for in whole re-runs. Three scenarios needed a second recording, each for a defect the first recording
  exposed rather than for flakiness: `exit-plan-mode`'s turn budget, `session-mirror-relocation`'s
  trust call and its two path comparisons, and `session-mirror-resume`'s unmirrored record.
- 2026-09-04: §4.4 and X8 are amended: a census pair carries the same required-versus-optional
  distinction its key sets already carried, at both levels the design has for keys. The
  **accumulated** half is `merge_required`'s, and it needs nobody: a pair present in one
  recording of a scenario and absent from another is marked `optional` in the merged census, the
  flag is sticky so a later recording carrying the pair does not un-learn it, and required-mode
  `diff` then stays silent about that pair in either direction. Without it, accumulation could
  not converge — folding an intermittent pair into the baseline only moves the alarm from
  "added" to "removed", so a re-recording flips which direction the gate is wrong in rather than
  fixing it. The **declared** half is `optional_pairs` in a scenario's `META`, read by `diff`
  and, like `resume_of`, never written into a fixture, because it is a property of the scenario
  and not of any one recording — so declaring it costs no re-recording, which matters when the
  evidence for it came from a live `diff` run that no recording reproduced. The two divide
  cleanly: the flag is optionality the corpus has evidence for, the declaration is optionality
  the operator has evidence for that the corpus does not. Exact mode is untouched in both
  halves: a deterministic scenario replays identical frames, its census never accumulates, and
  an optional pair there is real drift. `system/thinking_tokens` is declared on all eight
  model-driven census scenarios, wave A's two included.
- 2026-09-04: §4.7 gains the measured price of the drift ritual beside the price of a baseline
  bump. The section costed a full re-record of the catalogue and never costed `make probe`
  itself, which re-runs every census scenario against a live binary at roughly 0.13 USD for wave
  B's nine fixtures and grows with the catalogue. It stays on-demand rather than continuous, so
  the figure is a budgeting fact and not an argument for changing the ritual.
- 2026-09-04: Wave C complete. `explore-depth-1`, `nested-depth-2`, `background-shell` and
  `notification-hook` are recorded, reviewed, signed and committed against 2.1.259, and S16 and
  S18 are settled on the parent -- S18 positively and with room to spare, which retires the
  plan's contingency for it. Sixteen recorded fixtures and two synthetic ones; thirteen take
  part in the census. All four of this wave's scenarios are `census: true`: the forecast that
  `background-shell` and `nested-depth-2` would have to leave it over a model-chosen turn count
  did not materialise, because each prompt names the tool, the delegation and the exact reply
  and, for the two whose agents are backgrounded, says that the reply belongs to the turn after
  the agent reports. Every recording ended `result/success`. The rule that a scenario is
  reproducible exactly when nothing the model decides can change how many turns it takes held,
  and pinning the prompt was the cheaper half of it -- no fixture needed `optional_pairs` beyond
  the `system/thinking_tokens` every model-driven scenario declares.

  The wave cost roughly 1.4 USD, and the split matters more than the total: about 0.13 in seven
  recordings -- four committed, three discarded to defects the recording exposed -- and the rest
  in five runs of the drift ritual at about 0.25 each. §4.7's figure of 0.13 a run was measured
  across wave B's nine census fixtures; thirteen, two of them driving subagents, is close to
  double, and the ritual is now an order of magnitude more expensive than the recordings it
  guards. It stays on-demand.

  Three defects in the wave's own tooling, each found by a recording and each fixed at its
  cause. The settle helper compared task ids as sets and so read a re-engaged agent as settled,
  which sent `end_session` under a live agent. `unwritten_prefix`, added on this wave's first
  observation, was wrong twice -- as a head-position count, because the engine re-emits
  `agent_metadata` mid-stream, and then as a rule about entries with no `uuid`, because
  `ai-title`, `atis-latch`, `file-history-snapshot`, `last-prompt` and `queue-operation` have
  none and are written to the file. It is superseded by holding an `agent_metadata` entry
  against the `.meta.json` it claims to be, which is an assertion rather than an escape. Only
  `mirror_identity_only` remains a declaration, because what it licenses -- a field-level
  disagreement between an agent's sidecar file and its mirror -- has no stable count. It names
  the fields rather than licensing all of them: the count is a race, the field set is not.
- 2026-09-04: The drift ritual after wave C, and the one line it produced. `make probe` was run
  five times, all after the last fixture commit. The first found `nested-depth-2` clean and the
  second reported it as `removed pair control_request/can_use_tool` and its response: nothing in
  that scenario's prompt drives a permission ask, the recording happened to produce one and the
  re-run against the same binary did not. That is optionality the operator has evidence for and
  the corpus does not, which is `optional_pairs`, and it was declared on `explore-depth-1` and
  `background-shell` at the same time on the same argument rather than after each had flapped
  once. **Runs three and four then exited 0 across all thirteen census fixtures, back to back.**

  Run five, against the installed 2.1.260 with the corpus pinned to 2.1.259, exited 2 on one
  line: `nested-depth-2: added pair result/error_during_execution`. It is recorded as drift data
  rather than repaired, and honestly it is more likely to be about the scenario than about the
  binary -- the same subtype came out of a discarded 2.1.259 recording of this scenario, where
  the cause was the settle helper closing the session under a re-engaged agent, and the fix for
  that waits a fixed ten seconds rather than proving anything. So this is the census's
  class-three risk (an outcome the model's turn count decides) showing up in the one fixture of
  this wave that has two agents to wait for, and `nested-depth-2` is the census member to watch:
  a second flap of the same pair is the evidence that would take it out of the census, alongside
  `exit-plan-mode`, rather than something to declare optional. The reason is not that the two
  `result` pairs are mutually exclusive -- within one recording they are not, since this wave's
  own finding is that each forked agent brings up a `result` of its own and `nested-depth-2`
  carries three. It is that declaring the error pair optional would leave the required
  `result/success` passing while a genuinely failed sub-result went unreported, which is the one
  thing the census exists to catch. **An outcome pair is never incidental to the outcome**, and
  that is what separates it from `system/thinking_tokens` or an incidental permission ask, which
  are frames the model may or may not produce along the way. The wave-B classification stands
  with this refinement: class two is declarable because an absent frame changes nothing about
  whether the run succeeded, and class three is not because that is precisely what it changes.

  The one-line qualification on wave B's G2 note still holds and is worth repeating with a
  second version pair behind it: a ritual run that finds nothing cannot demonstrate that the
  ritual would find something. What this wave adds is the converse -- two of the five runs found
  something, both times a property of a recording rather than of a binary, which is the failure
  mode that erodes a gate fastest if it is waved through.
- 2026-09-04: §4.5 gains a seventh substitution and a third report-only check, both about the
  account name, and the split between them is the point. A directory listing carries the
  recording user's account name in the owner column of every line, which is not the home
  directory, not the hostname and not an identity-named field, so rules 1 to 3 walked past it;
  `exit-plan-mode` and `explore-depth-1` carried it in `frames.ndjson`, in a session transcript,
  in a **subagent** transcript and in an `artifacts/` file. On this machine the name is `new`,
  an innocuous English word, which is exactly why it survived review twice and exactly why the
  fix must not depend on that luck -- on another machine it is a person's name. So the rule is
  **positional**: a ten-character mode string followed by a link count is a strong enough anchor
  that the owner and group columns can be replaced with `<user>` and `<group>` without knowing
  what account name to look for, which is what makes it hold on any machine. A blanket
  substitution of the account string would have been the wrong instrument for the same reason
  the hostname rule carries a length guard -- substituting `new` everywhere would corrupt every
  fixture whose prose contains the word. The unstructured occurrences go to `scan_report_only`,
  beside the author's name and a foreign `/Users/` path, which is the module's existing division
  of labour: hard redaction where position makes it certain, a human where judgement is needed.
  That check reports **once per file with a line count**, not once per line as the author's name
  does, because `new` occurs 120 times across the corpus and a per-line finding would bury the
  two checks already living there under a hundred lines nobody reads. Both fixtures were
  re-redacted in place; `verify` now fails an unredacted owner column as a hard finding. The
  general lesson, which is what belongs in the rules rather than this incident: a redaction rule
  that keys on *what* a value is can only catch values it was told about, and one that keys on
  *where* a value sits catches the ones nobody thought of.
- 2026-09-04: The `spike` subcommand lands and the four live spikes run. §4.2 gains a ninth
  subcommand and the scenario contract a `fixture` key: `probe.py spike <name>` runs a
  scenario the ordinary way and prints its `notes`, writing nothing under `Fixtures/`, and
  `record` now refuses a scenario declaring `fixture: False` rather than spending real turns
  on a directory no reviewer will ever walk. S10, S11, S12 and S17 are settled on the parent,
  and S6's parent note is written there from the extraction already committed, so all twelve
  of G3's findings now sit on the parent. The wave cost about 0.04 USD in nine short `haiku`
  turns; `spike-contention` sends no prompt at all and spends nothing. Two scenarios take
  their variable from the environment rather than from an edit to their own source --
  `AFLEET_SPIKE_RESUME_AT` on S11, `AFLEET_SPIKE_TUI_KEYS` and `AFLEET_SPIKE_TUI_FIRST` on
  S12 -- because each needs two runs differing by one input, and a shared worktree is the
  wrong place to leave a file half-edited between them. Three corrections to the plan the
  scenarios came from, each found by running them. S12 read the registry only after its
  interactive holder had exited, which answers a different question than the one asked; it
  now samples from inside the hold. S12 also spawned a bare `claude`, which resolves to
  whatever the symlink points at rather than the pinned 2.1.259 baseline, and inherited the
  running agent's environment (Surprises). And S11 was to be run twice with a hand-edited
  `META`; the environment variable above replaces that.
- 2026-09-04: X8 gains `mirror_identity_only` in `fixture.json`, beside `late_responses`,
  `withdrawn_requests` and `unmirrored_prefix`, and like them it is declared by the scenario and
  never inferred. It is a mapping from a stream-path substring to the field paths that may
  differ between the mirror and the file on the streams it matches, and it is the only one of
  the four that is not a count, for a reason the others do not have: an agent's sidecar file and
  its mirror are two snapshots of one record taken at different moments, so *whether* they
  disagree is timing and a count would rot on the next recording, while *which* fields can
  disagree is a property of the engine and is stated. `verify` compares a matched stream by
  record identity -- §7.3's own definition, logical stream plus record `uuid` or a stable hash
  for uuid-less records -- and still compares every field the declaration does not name, so
  count, order, identity and all other content stay strict. Two guards keep the escape from
  widening: a scope that matches a stream which is not an agent sidecar is an error, because the
  match is a substring test and `.jsonl` or an empty string would otherwise relax everything;
  and a scope nothing matches is reported as stale. It is not in `REQUIRED_META`, defaults to
  empty, and every fixture recorded before it is unaffected. The occasion is in Surprises.

  A correction that belongs beside it, because it is the reason this note exists at all. Wave C
  first recorded the `agent_metadata` entries as a `[parent-impact]` on §7.3. They are not one:
  §7.3's invariant clause already ends "and with `agent_metadata` entries compared against the
  paired `.meta.json` instead", and its source-arbitration paragraph already names the entry as
  a record type of its own. The clause had been quoted from an earlier Surprises entry in this
  document rather than read in §7.3, and the quotation stopped one clause short of the sentence
  that disproves it. §4.9 flows these entries to the parent and G3 has this document name its
  parent impacts, so a wrong one sends a later agent to fix a clause that is already correct.
  The rule this leaves behind: quote a parent clause from the parent, and read to the end of the
  sentence.
- 2026-09-04: `redact` adds to the manifest on disk instead of replacing it, and a substitution
  that changes nothing is not counted. The two are one fix. §4.4 has `redaction.json` record
  "each rule applied, the field paths it touched and how many times", and REVIEW item 4 has a
  reviewer read it as that -- but `redact` re-runs the rules over a fixture whose bytes are
  already redacted, where everything the recording caught now matches nothing, so writing a
  fresh manifest turned the file from a record of what was redacted into a record of what the
  last re-run happened to find. `exit-plan-mode` lost the `userEmail`, tool-description and
  `account` substitutions that way and kept only the listings; both affected fixtures were
  re-derived from their pre-redaction bytes in one pass and now carry the full history, fifteen
  and eighteen identity substitutions.
  The second half is what makes the sum stable rather than merely additive. Most rules cannot
  match their own output, so a re-run contributes zero and the merge is a no-op -- but the owner
  column rule can, since `<user>` and `<group>` sit exactly where a name and a group sat, so
  counting matches rather than *changes* would have inflated the manifest by six on every
  re-run. Counting only a substitution that changed the string makes `make redact` a
  byte-for-byte no-op on a committed fixture, manifest included, which is the property §4.5's
  "idempotently" was always claiming.
- 2026-09-04: v3, execution complete; gates verified as listed in Outcomes. G1, G2, G3, G4
  and the tool tests all pass, measured at `865e55a` against the pinned 2.1.259 binary. Two
  adaptations are recorded there rather than resolved against §5's wording: G1's count says
  thirteen recorded fixtures and the corpus holds sixteen, and G2 is run against the pinned
  binary path rather than "the installed 2.1.259", which is 2.1.260. One inaccuracy was
  found and fixed rather than handed to the parent's tending session: the `C1/S5, completed`
  and `C1/S2` notes cited 2.1.260 for two fixtures re-recorded at 2.1.259 when the corpus was
  pinned, and both now name 2.1.259. The other thirteen C1 notes were checked the same way
  and needed no correction. Nothing binding on the parent is edited by this: a version tag in
  a C1 note is C1's own record of C1's own fixture.
- 2026-09-05: A leak-lens review of the branch, and seven fixes with a regression test each.
  Five are about a rule that was narrower than the property it claimed. **Rule 2 replaces a
  secret-named field whatever its value's type**: it replaced strings only, so
  `{"authorization": {"value": "Bearer .."}}`, `{"cookies": [{"value": ..}]}` and
  `{"api_keys": {...}}` reached disk and, because `scan` shares the predicate, passed the gate
  as well. The widening needed three exemptions to keep protocol structure, and each is written
  where the thing it protects actually lives rather than as a type test: a null value is left
  alone, as the identity rule has always left one alone; rule 5's own `effective_keys` and
  `sources_keys` output and `Redactor.manifest`'s own `rules.secrets` key are exempt **by
  path**, beside the existing `behaviors.key`; and the `*_tokens`-and-int counter exemption
  becomes "the only secret word in the name is `token` and no leaf of the value is a string",
  which is what actually separates a counter from a credential and which the corpus needed in
  four name shapes the old rule missed (`cacheReadInputTokens`, `estimated_tokens_delta`,
  `progressToken`, and `usage.output_tokens_details`, a dict of counters). `verify`'s
  names-only reshaping of `census.json` and `redaction.json` now goes all the way down, because
  a pair record holds protocol key sets one level below the pair name. One preservation
  assertion moved: a dict of strings under a bare `key` is now redacted whole, which costs a
  nested `projectKey` its exemption in that one position and is the only place the widening
  chooses redaction over structure. Nothing in the corpus has that shape.
  **`redact_tree` refuses a symlink or any irregular file by `lstat`, and `verify` fails a
  fixture holding one anywhere** -- `_redact_file` reads and truncates through an ordinary
  `open()`, so a tracked link made `make redact` rewrite whatever it pointed at, and a link is
  content the reviewer signs for without having seen. **`sign` records a SHA-256 of the fixture
  tree and `verify` recomputes it**, and requires `checklist_version` to equal the current
  constant exactly; the block previously attested three truthy strings bound to nothing, so any
  file could be edited after review while the signature went on passing. **The
  last-record-is-unwritten exemption is replaced by evidence**: the harness catches the failing
  write and annotates that capture record, and `verify` honours only the annotation, so a
  truncated recording ending with a request the host really did send no longer passes by
  sitting in the same place. **`fake-claude` creates materialised inodes with `O_EXCL` and
  refuses an append to a file whose link count is not one** -- `safe_path` rejects a symlink,
  but a hard link is a second name for an inode and every canonical-path check still sees a
  file under the fake root. **The harness launches the CLI with `start_new_session=True` and
  escalates with `killpg`**, so §6.7's SIGTERM and SIGKILL reach the background descendants
  `background-shell` records rather than the CLI alone. **`record` keeps
  `mirror_identity_only` a mapping** -- `list(...)` kept only its keys, so re-recording either
  agent scenario wrote a shape `verify` refuses -- **and validates the new fixture in a staging
  directory before it replaces the previous one**, which is the half that mattered: validation
  used to run after the old directory was already gone.

  On the corpus: fifteen fixtures are stamped with the digest of trees unchanged since their
  attestations, and three -- `exit-plan-mode`, `explore-depth-1` and `nested-depth-2` -- were
  re-walked against `Fixtures/REVIEW.md` and signed afresh, because `f6e3bad` re-redacted two
  of them and `865e55a` then edited all three's READMEs, two `redaction.json` manifests and two
  `fixture.json` declarations, after each had been signed. Stamping those would have bound a
  signature to bytes nobody walked, on the day the mechanism was introduced. The walk found
  nothing wrong: every countable claim in the three READMEs -- frame counts, per-subtype counts,
  transcript record counts, sidecar field sets, substitution totals -- matches the fixture in
  front of it. `Fixtures/REVIEW.md` gains a paragraph on what the digest binds and does not move
  its version, because neither the digest nor the exact-version check asks the reviewer for
  anything the ten items did not already ask.

  One finding from the review is dismissed rather than fixed: the `"Claude reviewer for kimmi"`
  signature is not an identity disclosure to redact. `kimmi` is the author's own public handle
  and appears in every Decision Log entry of the committed specs; §4.5's identity rules protect
  a recording's incidental identity data, not a reviewer's deliberate signature, and `verify`
  already masks it so it does not warn on every run. The other half of that finding -- carrying
  a recording's identity inputs so rule 3 can be applied off-machine -- is §8's first Deferred
  entry.
- 2026-09-05: The review of the leak wave, approved with one merge blocker, and what closing it
  cost. **`record` can no longer sign what it records.** Wiring `--reviewer` into `sign` -- which
  now stamps a current checklist version and a valid tree digest -- would have produced a review
  block byte-identical to a reviewed one, hollowing out the gate fix 3 exists to harden in the
  same commit that hardened it. The bypass predated the wave but was distinguishable while
  `record` hard-coded `checklist_version: 1`, which the new exact-version check catches on sight;
  the wiring threw that tell away. The option is gone from the subparser and from `record`'s
  signature, so signing is the deliberate second act `Fixtures/REVIEW.md` line 3 and the `make
  sign` target both describe. No fixture was ever signed that way.

  Four smaller repairs travel with it. The `unwritten` annotation is read only off a record
  travelling `in` and honours only a host-originated request, which is all the harness can ever
  produce and is what stops a mark on an outbound record excusing a CLI request the host never
  answered. `sign` refuses a tree holding a symlink *before* it hashes, because `tree_digest`
  reads each entry with an ordinary `open()` and `sign` runs before `verify` in the operator's
  workflow. The two `fake-claude` `_create_new` calls that sit inside a `not os.path.exists()`
  guard now turn a lost race into the same clean refusal materialisation gives rather than a
  traceback.

  **The manifest now distinguishes a container replacement from a scalar one**, and this is the
  one that matters. Rule 2 replaces a secret-named container whole, which can take a structural
  field nested inside it -- a `projectKey` under a `key` container is the case that would hurt.
  The wave's justification for that trade was that nothing in the corpus has the shape, and the
  review was right that this is a fact about eighteen recordings against one engine version and
  not a property of the protocol: if the case ever arrives, the loss is silent, because
  `redaction.json` shows the secrets count rise by one and nothing says a subtree went with it.
  `Redactor._hit` takes a `subtree` flag and the manifest carries a `subtrees` map per rule,
  written only when non-empty, so REVIEW item 4 now sends a reviewer to the path by name. That
  converts an invisible loss into a visible one, which is the property that actually matters; it
  does not make the trade unnecessary.

  The larger alternative is recorded here and deliberately not built: a recursive walk that
  preserves a secret-named container's structure while redacting every leaf inside it. It is the
  right answer *if the case arrives* -- it would keep a nested `projectKey` while still replacing
  every credential under the container -- and it is wrong to build now, because `scan` would have
  to mirror the walk exactly or the two halves of §4.5's one-predicate rule diverge, and there is
  nothing in the corpus to test either half against. A recording that nests a structural field
  under a secret-named container is the evidence that should trigger it, and `subtrees` in
  `redaction.json` is how a reviewer will notice that recording.

  `Fixtures/REVIEW.md` goes to **version 3** and every one of the eighteen fixtures was re-walked
  and re-signed, because two items changed: item 4 gains the `subtrees` reading, and a new item
  11 covers the `unwritten` annotation, which is new reviewable content a reviewer can hand-edit
  rather than a restatement. That is the rule the file states about itself, and the wave declined
  to bump for the digest precisely so that bumping would still mean something here.

  **The re-walk found two stale README claims**, which is item 8 doing the job it exists for and
  the first time this corpus has been walked end to end since the 2.1.259 re-recordings.
  `send-user-file`'s README said its transcript holds 34 records; it holds 33. `resume-no-replay`'s
  said `streams.json` records 171871 bytes; it records 173315, and the transcript is 173403 bytes
  and 32 records against the initial 31. Both numbers date from before `79a02f7` and `0c03f6f`
  re-recorded those fixtures, and both are corrected in the README rather than anywhere else --
  the claims' *shape* was right in each case and only the figures had moved, which is exactly the
  failure item 8 predicts of a README carried across a re-recording. Two Surprises entries in this
  document quote the older figures as observations made at the time; they are left as the record
  of what was seen then. The check that caught them is worth keeping: every integer in a README
  held against the counts computed from the fixture, with the unmatched ones read by hand.

- 2026-09-05: follow-up wave for C3 and C4, on `worktree-agent-aaf78bf28064267d9`. Adds the
  spike `spike-mcp-decline-files` with its finding under `Tools/probe/spikes/`, which cost
  nothing, and the two scenarios C3's corrective recordings need, `rewind-turn` and
  `compact-boundary`. The recordings themselves are not in this commit: the scratch account's
  five-hour window read 98 per cent utilisation at the wave's usage check, which is the
  condition this wave was dispatched to stop on, so the two model turns were not spent. Each
  scenario is one `make record` away once the window resets.
- 2026-09-05: the follow-up wave's two recordings landed after the scratch account's five-hour
  window reset. `rewind-turn` and `compact-boundary` are in the catalogue at §4.7, taking it to
  twenty, and both were reviewed and signed by agents other than the recording run. The wave
  also found and fixed a redaction hole (`IDENTITY_SUBSTRINGS`, Surprises) and recorded a
  `[parent-impact]` on §7.3's file-only exclusion list, which should lose `compact_boundary`.
- 2026-09-06: **rule 5 keeps the engine's shape.** Corrective on `main`. §4.5's rule 5 replaced
  a `get_settings` answer's `effective` object with a synthesised list called `effective_keys`
  and its `sources` list with `sources_keys: [{source, keys}]`. Neither name exists on the wire:
  2.1.258 `cli.pretty.js` builds the answer in `aRn()` as `{effective: {<setting name>: <value>},
  sources: [{source, settings: {<setting name>: <value>}}]}`, and the `get_settings` handler adds
  `applied: {model, effort, advisor, ultracode}` and, when the settings files carry errors,
  `errors`. Two committed fixtures therefore carried a key no engine sends, and a consumer that
  learned to read it from the fixture would fail against a real engine — which is the whole
  point of a fixture reversed. The principle the rule now states in one line: **redaction
  replaces values and never changes a shape or a key name.** `effective` keeps its keys with
  every value replaced by `<redacted>` whatever its type, `sources` keeps `source` and the
  setting names under `settings`, and a value that is not a map has no shape to keep and is
  replaced whole. The rule carries a one-time upgrade of the older shape, so `make redact`
  migrated `control-shapes` and `zero-cost` in place and idempotently, losslessly: what the old
  rule kept was the setting names, and the new shape carries the same names. `probe.py` carries
  the same rename into `census.json`'s body key list, from the same shared map, so a migrated
  fixture still matches `verify`'s recount of its own frames. The exemption these two paths used
  to need in `SECRET_STRUCTURE_PATHS` is **gone**, and the reason is worth keeping: they needed
  it only because the invented names contained "key" and carried lists of strings. A setting
  name now sits in key position, where the secrets rule replaces a value and never a key, so
  nothing has to be exempted to protect it — and the observation two entries above, about an
  entry here being a claim about a name at any depth, applies to two fewer names. Both fixtures
  are unsigned again by construction and await a reviewer's walk of `Fixtures/REVIEW.md`.
  Witness, at no model cost: `make probe FIXTURE=zero-cost` against the pinned 2.1.259 the
  corpus was recorded with reports `ok`, so the live answer's census matches the migrated
  fixture exactly; the same run against the installed 2.1.261 also reports `ok`, so there is no
  drift in this shape between the two versions.

