# C4: `FleetKit` sessions and fleet (2026-09-05)

> **Parent:** `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C4`.
> **Parent-pin:** that path at commit `ee94449` ("FleetKit: manifest skeleton with the C3 and
> C4 target groups; X1 records the split"). **Level name:** child, wave 2 of the v1 roadmap.
> **Track:** controlled. **Branch:** `child/c4-sessions-fleet`, worktree `../afleet-c4`;
> merges to `main` when G1, G3, G4 and G5 pass. G2 is blocked by C3.G3 and follows the
> parent's §17.6 rule for a gate pending another child: it becomes evaluable when C3's
> registry mirror lands, this child may merge with it pending and marked in the tracking
> map, and a later failure is a corrective task on C4 flagged to C5 and C6. This document
> treats the parent's §17 C4 section and its binding inheritance (§6.11, §6.12, §7.1, §7.2,
> §7.4, §7.6's query definition, §7.7, §7.8; contracts X1, X2, X3, X5, X6, X9, X10, with X5
> and X6 as the parent amended them on 2026-09-05 from C7's decomposing run: the Terminal
> panel never spawns `claude` on its own initiative, X5 hands it pane requests and receives
> pane exits; X6 admits dotted keys and a per-namespace schema version) as landed and records
> only the residue those sections leave to this child. `main` was merged into the child branch
> on 2026-09-05 (merge `71a9999`, `main` at `b2ddd5d`), which brought the parent's X5 `id`
> amendment from the plan review, C1's §6.12 spike (`Tools/probe/spikes/mcp-decline-files.md`)
> and the C2 corrective `SessionStart.forkFrom`; v2.2 is written against that tree. v2.4 also
> reads `main` at `6994ff8`, which carries the C2 corrective `LaunchConfiguration.maxTurns`
> (`1458568`, emitting `--max-turns <n>`) that G5's live budget depends on.

## Purpose

afleet shows every Claude Code session on the machine as a channel and lets the user act on
each one without ever competing with the terminal that may already hold it. Between the wire
layer that speaks to one process (C2) and the shell that renders channels (C5, C6) sits the
layer that decides *which* process should exist, *when*, under *whose* ownership, and with
*what* preconditions satisfied. C4 builds that layer as the `FleetSessions` module of the
`FleetKit` package: detection of the four channel origins from the registry, the job roster
and `claude agents --json`; the ownership protocol with its epochs, pre-spawn and
post-handshake checks and quiescent handoffs; the lifecycle table with dormant eligibility,
reap, respawn, adopt, send-to-background, open-in-terminal, the quiescent restart with
snapshot and readback, and the wedged state; the spawn preconditions (trust, project MCP
consent with the one write afleet ever makes to a Claude Code-owned file, managed
settings, the `--strict-mcp-config` rule); the Activity query; the command router with the
flag matrix, refusal interception and the global `/logout`; and the namespaced store that
every upper package persists through. When C4 is done, the app shell can open, send to,
background, adopt and restart a channel by calling one API, and every rule that keeps two
writers off one transcript is enforced below the UI where it cannot be forgotten.

## Acceptance

The parent's gates restated as observable behaviour, each with the test target that proves
it. Every test that proves a fix is demonstrated failing against the pre-fix code before it is
accepted (parent §17.7); where a failure cannot be executed, the substitute is a trace
assertion that the dangerous path was never entered, stated as such. Counts compare as sets.

**G1 — the lifecycle table, row by row (required).** `swift test --package-path FleetKit
--filter FleetSessionsTests` drives `ChannelSupervisor` against `fake-claude` under a scratch
ConfigHome that a test builds itself (never the user's, never `/tmp/afleet-fixtures/config-home`),
with scripted registry records, job state files and a scripted `claude` verb runner, and an
injected clock so no test waits on wall time. The table constant the supervisor is built from
enumerates every transition as a `(row, from, event, to)` scenario, one entry per from-state a
row admits and per to-state it can reach; each row test declares the scenarios it drove and
asserts the transition it observed by `(from, event, to)`, and the suite asserts that the set
of scenarios covered equals the set of scenarios in the table, so a row, a from-state or an
outcome added later without a test fails the build. **The table holds 58 scenarios** as of the
whole-branch fix wave (55 at the end of the twelve tasks; ruling 1 added `readyExitedClean` and
a crash-exhaustion row from connecting and retargeted the ready-crash row, and `scalpel-1#11`
added `foreignRecordGone` from `backgroundJob`), and `LifecycleCoverageTests` asserts the set
equality in both directions with the method-parity check running key to test only. The
scenarios, grouped by row:

- eager spawn on open of a recently active archived channel; history-only open of an older one; spawn-then-send on an older one when the user sends;
- connecting to ready when the post-handshake check is clean; connecting to foreign live, own process terminated, when the post-handshake check finds another holder (item 46 at the API level);
- ready to dormant after 30 minutes dormant-eligible, and *not* while a task in the registry mirror is running or its heartbeat is uncertain (item 18's two halves; the mirror is a C3 type, so until C3 lands this test feeds the supervisor a stand-in that conforms to X4's mirror-entry shape, and G2 replaces the stand-in);
- dormant to ready on send, same session id, one connecting glyph;
- respawn on non-zero exit with backoff 1 s, 2 s, 4 s, three attempts, each behind the ownership check, then the system item with exit code, stderr tail and *Reopen* (item 20);
- the cap of six: the seventh spawn reaps the least recently used dormant-eligible live channel, recency read from the counter's own fleet-wide activity clock (one stamp per send, engine frame and decision, never a per-supervisor sequence); a dormant channel holds no slot, so it is never a victim; with none eligible, no eviction and the header state carries the live count and *Send to background* (item 19). Acquiring a slot is a reservation the counter grants or refuses atomically, so two channels opened at the cap at the same moment evict two distinct victims or one of them is refused, never both spawning against one freed slot; an eviction returns the outcome the counter observed, and a victim that wedges mid-eviction frees no slot, so the counter moves to the next eligible victim or refuses. The counter counts every occupied slot, live, reserved, wedged and pending eviction, and decides from an eligibility snapshot the supervisors push, so its decision never awaits a supervisor and a victim leaves the live set the moment it is named. Three tests pin it: two concurrent opens at the cap; a victim whose termination report carries no exit during eviction, after which the seventh channel is refused or takes the next victim and never spawns on the ghost's slot; and a victim whose own release arrives while its eviction is still pending, which completes the eviction without freeing a seventh slot;
- wedged when the handle's `terminate()` returns a `TerminationReport` whose `exit` is `nil` (its `steps` are the escalation trace, ClaudeWire's `terminateEscalated` diagnostics for the epoch as captured by the sink the process factory installs): no respawn under that session id, the escalation trace on a system item, *Reopen* spawning only after the ownership check finds no holder. No real child can produce this row, because SIGKILL cannot be refused (C2 recorded the same limit); the supervisor therefore drives its process through a `ProcessHandle` protocol whose live conformance is a thin `LiveProcessHandle` wrapper over `ClaudeProcess` and whose `events` is an existential `AsyncSequence<WireEvent, Never>` (ClaudeWire's `WireEventStream` can be neither constructed nor fed outside its module), and the row runs against a scripted handle whose `events` is an `AsyncStream` the test feeds and whose `terminate()` returns a scripted report with a `nil` exit and the scripted steps, stated as such in the test. The fault is injected through every action that terminates, not only the reap: reap, send to background, open in terminal, the quiescent restart, `/logout` and cap eviction each get a scenario in which the report's exit is `nil`, and each asserts that nothing that would have followed a real exit happens: no `PaneRequest` is returned, no `--bg --resume` or `stop` verb runs, `auth logout` does not run, no replacement process spawns, and the channel is wedged with the trace;
- adopt: `claude stop <short>`, wait for exit and roster removal, spawn `--resume`;
- send to background: `terminate()`, wait for exit and registry removal, the ownership check once more immediately before the launch, `claude --bg --resume <id>`, the new job found in the roster by its `resumeSessionId` (item 16); a holder that appears between the release and that recheck preempts the handoff: nothing launches, the origin resolves from the holder (foreign, job, or contended for an own pid), the banner is set and the caller gets `LifecycleError.heldElsewhere`;
- open in terminal: `terminate()`, wait, the same recheck before the request is built (a holder means no request and `LifecycleError.heldElsewhere`), return a `PaneRequest` whose purpose is `.hatch(id)`, whose arguments are the interactive `--resume <id>` line and whose environment is composed through ClaudeWire's launch configuration so the hatch resumes under the same config home; keep mirroring; re-adopt when the panel reports the `PaneExit` and the record is gone (the test plays the panel: it takes the request and reports the exit);
- foreign live in the user's terminal: send refused with the "running in your terminal" reason and *Fork* offered; record gone means archived;
- Contended after a handoff wait exceeds 10 s; and, as a transition of its own with its own event, Contended whenever desired and observed disagree (a foreign holder named while `desired` is owned, from connecting, ready or dormant); back to the matching origin when the holder set settles to zero or one;
- the quiescent restart: the values to carry come from the channel's runtime-state model, an actor-owned record of permission mode, model, effort, output style, cwd, agent, the cumulative `--add-dir` list, the environment options, the union of every `apply_flag_settings` payload the host sent and the fast-mode state the engine reported, that every control response and frame updates (a `set_model` answer, a `set_permission_mode` answer, `get_settings.applied`, an `apply_flag_settings` sent through the API, `fast_mode_state`, `set_cwd`, an accepted `add_directory`), not from the launch template; snapshot it, terminate, wait, spawn with every launch field from the snapshot and never `--agent`, re-send the flag union, verify every readback (`model` and `effort` from `applied`, permission mode and output style from the new handshake, every flag key present among the keys of `effective`, fast mode from `effective` when the host applied it and from the new handshake when it was only observed), `.ready` published only after the readbacks, composer disabled until each matches, a banner naming the setting that did not survive (items 58 and 63 at the API level, the mismatch half driven by `FAKE_CLAUDE_INIT` answering a different `current_permission_mode`). One end-to-end test routes `/model` and `/permissions` through the command router, then restarts, and asserts the relaunch carries the changed values, not the ones the channel was opened with.

Forking is exercised beside the table because the parent's table has no fork row: a plain
fork launches `SessionStart.resume(source, fork: true)`; *Fork from here* launches
`SessionStart.forkFrom(source, at: ForkPoint(entryUUID:dropsTurn:))` with the clicked
record's uuid and the discarded turn's prompt uuid, so `--resume-session-at` and
`--resume-drops-turn` come from C2's line composer and nothing here appends arguments; both
are keyed provisionally until `.sessionIdentityResolved`.

Every spawn in every row is preceded by the pre-spawn ownership check and every handshake by
the post-handshake check, asserted by a recording holder-reader that the tests inject. The
pre-spawn check refuses on *every* live holder of the session, our own children included (a
second supervisor's process, an older epoch's ghost); the post-handshake check excludes
exactly one pid, the child this spawn started, and treats any other pid of ours as a holder.
Two tests pin that: two own processes on one session id (the second supervisor refuses
before spawn; if a race slipped it through, its post-handshake check yields and the first
keeps the session), and a fork whose resolved identity collides with a session another
supervisor owns (the fork yields; the owner is untouched; a fork never publishes `.ready`
before its identity resolves, so the collision is the `connecting` row and the fork's slot
moves from the provisional id to the resolved one only on a clean check). Pane exits are
matched to the pending hatch by `PaneRequest.id`, never by value: a test opens two hatches
with identical fields in sequence and reports their exits in reverse order; the stale exit
is discarded and the live one re-adopts.

**G2 — dormant eligibility reads the registry mirror (required, blocked-by C3.G3).** With
C3's mirror driven by the `background-shell` fixture through `fake-claude`, a channel whose
mirror lists a running task is never reaped, and one whose mirror is empty and whose last
task frame is older than the heartbeat interval is. The mirror entry carries `armed` and
`running` as separate facts, and the two eligibility tests, the unit test over the stand-in
and the mirror-driven test here, assert the same boundary cases: an armed task blocks; a
running task blocks; a running task whose last frame is older than its heartbeat interval is
uncertain and blocks; an empty mirror, or one with neither a running nor an armed entry,
whose last task frame is old is stale history, not uncertainty, and is eligible. Until C3.G3
lands the stand-in of G1 stands and this gate is marked pending in the parent's tracking map.

**G3 — the preconditions (required).** Under a temporary project directory the test creates:
an untrusted root (no `hasTrustDialogAccepted: true` under its canonical key in the scratch
`.claude.json`) yields the `.untrusted` precondition and no spawn (item 47's logic); a
`.mcp.json` declaring a pending server yields `.consentNeeded` naming it and no spawn, where
rejected, approved and pending are computed from the merged settings sources alone (the
project's local-settings store, the project settings file and the user settings file, with
`disabledMcpjsonServers` winning over `enabledMcpjsonServers` and
`enableAllProjectMcpServers`), never from the `.claude.json` project entry, because the
engine's consent decision reads only the effective settings (*Preconditions* below cites the
bundle); a decline writes `disabledMcpjsonServers` into the project's
`.claude/settings.local.json`, the file and key C1's spike recorded the terminal's own
dialog writing, through the parent's §6.12 resolver and write policy, with every other key
byte-for-byte untouched, the existing mode preserved, and every open, create and rename made
relative to a directory descriptor the writer holds (`.claude` opened
`O_DIRECTORY|O_NOFOLLOW` and `fstat`ed for type and ownership, the staging directory made
with `mkdirat` and opened the same way, the staging file created with `openat` and
`O_NOFOLLOW|O_EXCL`, the target read with `openat` and `O_NOFOLLOW`, and `renameat` within
the one directory descriptor), so a symlink placed anywhere on the path after resolution is
refused rather than followed; the writer's tests cover a `.claude` that is a symlink to a
directory outside the project, a `.cc-writes` that is a symlink, a `settings.local.json`
that is a symlink, a path component swapped for a symlink between resolution and the open,
mode preservation across the rename, and a staging directory that would resolve inside the
ConfigHome, each writing nothing, leaving every symlink target unchanged, spawning nothing
and reporting the `/mcp` banner; a project whose store resolves inside the ConfigHome (the
`CLAUDE_CONFIG_DIR`-inside-project case) refuses the write the same way; isolated setting
sources with a declared `.mcp.json` server add `--strict-mcp-config` to the launch and the
header reason; a pending managed-settings pair under the scratch ConfigHome yields
`.managedSettingsPending` and no spawn (item 55). Nothing else in the package ever writes
under a project directory, asserted by a test that diffs the project tree across every other
precondition path. The proof that the engine honours a decline is not a marker under
`fake-claude`, which runs no server and so proves nothing; it is a zero-cost scenario in
G5's suite against the installed CLI: in a directory the scratch config home already trusts,
a `.mcp.json` declares one stdio server whose command writes a marker file (stdio because
only a spawned command leaves a marker; http and sse entries are listed and consent-gated
the same way, with nothing to witness); launch A, with the marker accepted through the
store-only accept and no decline recorded, and launch B, after a decline written through the
§6.12 writer, differ in nothing else; each runs to the handshake, is asked `mcp_status` and
`get_session_cost`, and is ended with no turn; the marker exists after A and not after B
(the headless path promotes a pending project server to approved and spawns its command,
parent §6.12), both `get_session_cost` answers read `total_cost_usd == 0`, and the two
`mcp_status` answers are recorded as diagnostics counts, not asserted to a shape, because
the answer for a rejected server is unrecorded in the corpus.

**G4 — the router (required).** The router table is data; a test asserts that the set of
local commands in the table equals the set the parent's §7.7 table names, with no
duplicates. Each entry carries a typed strategy whose cases name the exact request sequence
or lifecycle action the command runs, so the mechanism test is a check of each strategy's
behaviour against the fixture that recorded it, not an assertion that an enum value is one of
the enum's values. Against the `control-shapes` fixture: `/effort low` sends
`apply_flag_settings {effortLevel}` and reads back the key names of `get_settings.effective`,
which the engine answers as an **object** of key to value; `/cd` into
an untrusted directory receives `needs_trust` and, after the trust answer, repeats the call
with `trust_accepted: true` and `trusted_directory`; `/rename` sends `rename_session`;
`/model` sends `set_model`; `/rewind <uuid>` sends `rewind_files {user_message_id, dry_run:
true}` first, surfaces the recorded `canRewind`, `filesChanged`, `insertions` and `deletions`
for confirmation, and only after confirmation sends `rewind_files {dry_run: false}` and
`rewind_conversation {target_message_uuid}`, reading `rewound` and `prefillText` from the
answer; `/login` sends `claude_authenticate`, receives `manualUrl` and `automaticUrl`, hands
the automatic one to the Browser tab and then waits on `claude_oauth_wait_for_completion`,
whose only recorded answer is the error "No active claude_authenticate flow", so the
completed-login step runs against a scripted `fake-claude` answer and the test says so.
Against the `zero-cost` fixture: `/mcp` sends `mcp_status` and produces the popover model
from its answer; `/memory` sends `get_context_usage` and opens `memoryFiles`; bare
`/permissions` sends `get_settings` and produces the read-only rules view. A
command listed in the handshake's `terminal_slash_commands` is hidden and refused locally with
its explanation; an unknown local command falls through as text; the bare refusal text
`/<name> isn't available in this environment.` is intercepted, replaced and counted. `/logout`
runs the census and barrier: with two idle owned channels the plan lists both and terminates
them before `claude auth logout` runs; with a running background shell in one and an
afleet-launched job the plan lists the task and the job, *Wait* holds, *Stop* sends
`stop_task` first, the job is stopped and gone from the roster before logout runs, and the
foreign-session warning names the registry record left running (items 11 and 59 at the API
level, verbs through the scripted runner).

**G5 — against the installed CLI (required; live; skips with a named reason).** Runs only
with `AFLEET_LIVE_CLI=1`, under `/tmp/afleet-fixtures/config-home`, and touches only
processes the test starts. The suite owns one serialised live budget: scenarios run one at a
time through it; the model is pinned to `claude-haiku-4-5-20251001` on every turn-spending
launch; every `ClaudeProcess` the suite launches carries `--max-turns` with a cap the
scenario states (1 for a handshake-only scenario and for adoption, 12 for the composed
prompt), because the flag caps agentic turns inside one prompt, not prompts, and ends the
turn with a `result` of subtype `error_max_turns` at the limit (bundle 36222
`turnCount`/`maxTurns`; C1's `exit-plan-mode` fixture records the subtype), which every
scenario treats as a failure naming it; the suite's ceilings are five model turns (two
reserved for adoption, two for the composed scenario, one for the restart readback) and twenty
minutes of wall time in total,
and the budget refuses a scenario that would cross either; C2's usage reader is consulted
before the first scenario and again before each turn-spending one, and a spent window skips
with its reason; every `result` frame any scenario observes has its `total_cost_usd` summed,
and the sum is reported after the run. Zero-cost scenarios are witnessed, not assumed: a
zero-turn launch emits no `result` frame, so each asks `get_session_cost` before ending its
process and asserts the cost is zero. Corrected in execution (Task 10): `get_session_cost`'s
answer carries the rendered text and not a `total_cost_usd` field, so the numeric assertion
reads `session.total_cost_usd` from `get_usage`, and the gate asks both. The foreign-session half spends no model turn:
the test starts an interactive `claude` on a pseudo-terminal in a directory the scratch
config home already trusts (recreated if absent; the test never writes trust), and within
five seconds the fleet reports a foreign live channel with the record's `status`; the test
then ends its own pty child and the channel turns archived when the record is gone. The job
half prefers `claude --bg --exec "sleep 60"`, which spends nothing: the roster lists it,
`jobs()` returns it with `sessionID == nil` recorded as the delegated unknown (an exec job
is no channel, because channels are keyed by session), and `performJob(.stop, short)`
through the real runner removes it. The consent half is the two-launch marker scenario G3
names, zero cost, the marker accepted through the store-only accept before launch A so the
consent gate does not stop A and the marker proves the engine's own promotion. Adoption of a
job with a conversation reserves two short `haiku` turns (`claude --bg --model
claude-haiku-4-5-20251001 "Reply with exactly: pong"`; the recipe carried `--max-turns 1`
until 2026-09-06, when the gate showed it self-defeating: the job reaches a terminal state
about three and a half seconds after creation and leaves the roster before `jobs()`, which
filters terminal records, can list it. `claude --bg` does forward `--max-turns`, bundle
824274's forwarded-flag set, and a `--bg` job is a CLI verb rather than a `ClaudeProcess`, so
dropping the flag from this one line leaves the per-launch cap rule untouched), runs only when `AFLEET_LIVE_CLI_TURNS=1`
is also set, and asserts that adopt stops the job, resumes the same session id owned, that
the next handshake is clean, and then that *Send to background* hands the owned channel
back: `--bg --resume <id>` ran, the roster lists a new job for the session, the channel
reads `.backgroundJob`, and the test stops that job through `performJob(.stop, short)`; the
second turn is the reservation for a resumed job that runs one. The **restart readback** scenario, the eighth, is the one place an engine
witness is worth a cent: it spends one short `haiku` turn (`--max-turns 1`) so a transcript
exists, then routes `/model` to a second alias and `/add-dir <scratch directory>` — a
restart-required setting — so a quiescent restart runs, and asserts that `.ready` is published
with no `settingDidNotSurvive` banner, that the relaunch argv carries the new model and the
directory, and that the `get_settings` answer's `effective` is an **object** and not a
synthesised key list, read through the diagnostics sink or an injected readback observer. It
exists because the restart readback is the class of defect a fixture-driven suite cannot catch:
the stand-ins agreed with the code rather than with the engine. One config-home witness
spans the whole of G5, taken before the first live scenario and after the last, and a second
reading brackets each scenario: the set of relative paths the engine created, modified or
deleted is reported, never their contents, and compared against the allowlist that G5 widens
(see *The write allowlist* below); any unexplained change in the suite-level reading or in
any scenario's fails the gate with the path named, so a write between scenarios is caught as
surely as a write inside one.

## Grounding

Read on `main` at `ee94449` before this spec was written, so the residue decisions rest on
what exists rather than on the plan's picture of it.

- **`ClaudeProcess` (C2, X3).** One instance per spawn with the epoch FleetKit assigns;
  `spawn()` returns a `Handshake` when the `initialize` response arrives and nothing from
  `system/init`; `events` is a bounded lossless `WireEventStream<WireEvent>` (a struct with
  an internal initialiser whose `next()` does not throw, so nothing outside ClaudeWire
  constructs or feeds one; `BoundedChannel.swift:110-118`) with `.handshakeCompleted`,
  `.sessionIdentityResolved` (a fork's real id, once), `.frame`, `.request`,
  `.requestCancelled`, `.policyAnswered`, `.unansweredDialog`, `.hostToolInvoked`,
  `.stderr`, `.exited`; `terminate()` returns `ExitStatus?` where `nil` means the escalation
  exhausted with no exit observed, `status` stays `.terminating` and the stream stays open;
  `sessionID` is `nil` for a fork until `.sessionIdentityResolved`; `childProcessIdentifier`
  is the child's pid. `Handshake.pending` is a wire fact nothing renders from.
  `LaunchConfiguration` composes the §6.1 line and the child environment, rejects
  option-shaped values, and carries `configHomeOverride` for tests only.
- **Typed frames C4 reads.** `SystemInit` (`apiKeySource`, `mcpServers`, `slashCommands`,
  `terminalSlashCommands`, `model`, `permissionMode`, `fastModeState`, `effort`),
  `SessionStateChanged` (`state`, a free `JSONValue`), `PermissionDenied`, the five task
  frames and `BackgroundTasksChanged` (C3 reduces them into the mirror; C4 reads the
  mirror), `ResultFrame` (`subtype`, `isError`, `permissionDenials`, `fastModeState`),
  `RateLimitEventFrame`, `AuthStatusFrame`. The corpus contains **no**
  `session_state_changed` frame; the only sample is C2's bundle-shaped one with
  `state: "requires_action"`.
- **Typed requests C4 sends.** `SetModel`, `SetPermissionMode`, `ApplyFlagSettings`,
  `GetSettings`, `RenameSession`, `SetCwd`, `Interrupt`, `StopTask`, `BackgroundTasks`,
  `MCPStatus`, `EndSession` (the transport's own), `ClaudeAuthenticate` and its two
  companions, `GetUsage`, plus `RawControlRequest` for anything the router passes through.
- **`WireEnvironment`.** `EnvironmentResolver.resolve(shell:)`, `ConfigHome.derive(from:)`,
  `BinaryLocator.locate(in:override:)`, `VersionGate.check(binary:environment:)`, and the
  `ProcessRunner` protocol (`run(_:arguments:environment:timeout:) -> ProcessOutput`) with
  `FoundationProcessRunner`. C4 reuses `ProcessRunner` for every CLI verb.
- **`FleetKit/Package.swift`.** `FleetTimeline` (C3) and `FleetSessions` (C4, depends on
  `FleetTimeline`, `ClaudeWire`, `AfleetCore`), umbrella `FleetKit`; C4 owns the manifest and
  edits outside C3's marked region.
- **The registry.** `<configHome>/sessions/<pid>.json`, written by every eligible process
  including afleet's own headless children (`kind: "interactive"`, `entrypoint: "sdk-cli"`),
  unlinked on exit; fields `pid`, `sessionId`, `cwd`, `startedAt`, `procStart`, `version`,
  `peerProtocol`, `peerFeatures`, `kind` (`interactive` or `bg`), `entrypoint`, `pidDomain`,
  `messagingSocketPath`, `name`, `nameSource`, `nameSince`, and for a `bg` process with a
  job directory `jobId`; TUI processes add `status`, `waitingFor`, `state`, `detail`,
  `tempo`; headless ones never do (parity 38.2, probes 12 and 12b, `spike-contention`). The
  CLI's own reader validates a holder by pid liveness and its `procStart` token (bundle
  12922/44087/44114, the `zm(pid, procStart)` comparison over the registry and
  `daemon/roster.json`); the record is written with `procStart` as the trimmed `ps -o
  lstart=` string under `LC_ALL=C TZ=UTC`, like `Fri Sep 5 03:12:41 2026` (bundle 515820),
  beside `startedAt` in milliseconds (515624). The scratch config home's `sessions/` is
  empty at rest.
- **The roster and jobs.** `<configHome>/daemon/roster.json` is `{proto, supervisorPid,
  updatedAt, workers}` with `workers` keyed by job short, each carrying `pid` and
  `procStart` while live; `<configHome>/jobs/<short>/state.json` carries `state` (`starting`,
  `resuming`, `adopted`, `crashed`, `working`, `blocked`, `done`, `failed`, `stopped`),
  `tempo`, `template` (`bg`), `backend`, `sessionId`, `resumeSessionId`, `cwd`, `intent`,
  `respawnFlags`, `children`, `needs`, `block`, timestamps; three stopped jobs from S12 sit
  in the scratch home now. `exit-cause` and `exit-detail` are destructive to read and are
  never read.
- **`claude agents --json`** (bundle `printAgentsJson`, 2.1.258): a bare JSON array sorted by
  `startedAt`; job rows `{pid?, id, cwd, kind: "background", startedAt, sessionId, name?,
  status?, waitingFor?, state}` where `state` is `working`, `blocked`, `done`, `failed` or
  `stopped`, and registry rows not represented by a job `{pid, cwd, kind: "background" |
  "interactive", startedAt, sessionId?, name?, status?, waitingFor?}`. It lists afleet's own
  children too, which is why the parent says the two reads name one holder by two words and
  are reconciled by pid rather than unioned.
- **`fake-claude`.** Configured by environment: `FAKE_CLAUDE_FIXTURE`, `FAKE_CLAUDE_SPEED`,
  `FAKE_CLAUDE_SCRIPT` (steps: `expect`, `emit`, `answer`, `after`/`at`, a `generic-success`
  rule, `patch`/`remove`), `FAKE_CLAUDE_INIT` (replaces the recorded `initialize` response),
  `FAKE_CLAUDE_CONFIG_HOME` (a marked fake home it materialises transcripts into),
  `FAKE_CLAUDE_CWD`; `materialize <fixture> <configHome>` lays down a fixture's `initial/`
  transcripts under a marked directory and refuses the real config home. It answers
  `end_session` with success and exit 0, exits 0 on stdin close, exit 3 on unexpected host
  traffic, and it emulates **no** CLI verb: no `agents --json`, `stop`, `--bg`, `auth`.
- **Trust and consent state.** The scratch `.claude.json` keys `projects` by resolved path
  (`/private/tmp/...`, never `/tmp/...`) with `hasTrustDialogAccepted`,
  `enabledMcpjsonServers`, `disabledMcpjsonServers` per project; the two arrays are a legacy
  location the engine migrates into local settings at startup and never consults for the
  consent decision (*Preconditions*); `remote-settings.json` and
  `remote-settings-consent.json` are absent there and unrecorded in the corpus.
- **C1's §6.12 spike** (`Tools/probe/spikes/mcp-decline-files.md`, 2.1.259, zero cost): a
  TUI decline under the scratch home writes exactly `<project>/.claude/settings.local.json`
  with the single key `disabledMcpjsonServers: [name]`; the project entry in `.claude.json`
  is created by the trust dialog with empty consent arrays that stay empty across the
  decline; `enableAllProjectMcpServers` never appears; at exit the project entry gains
  per-session counters (`lastSessionId`, `lastCost`, `lastDuration` and their kin). Left
  unsettled there: store resolution when the git root lies above the cwd, the multi-server
  dialog, the "all future servers" leg, and preservation of unrecognised keys.
- **Fixtures C4 drives.** `control-shapes` (router readbacks, `set_cwd` trust exchange,
  `claude_authenticate` family), `background-shell` (a running task for eligibility),
  `notification-hook` (a permission ask left pending), `plain-two-turn` and
  `resume-no-replay` (a clean resume with no turn), `session-mirror-relocation`,
  `zero-cost`.

## Design

### Package, targets and files

One target, `FleetSessions`, with a folder per concern; the manifest gains nothing until a
concern needs a separate module, which none does. Every public type is `Sendable`; actors
serialise mutable state; nothing is `@MainActor`.

```
FleetKit/Sources/FleetSessions/
  Fleet/          FleetObserver (actor), HolderReader, RegistryRecord, JobRecord, AgentsRow, OriginResolver
  Ownership/      OwnershipCheck, HolderSet, ProcessLiveness
  Lifecycle/      ChannelSupervisor (actor), LifecycleTable, DormantEligibility, RestartSnapshot, Readback, ProcessHandle (LiveProcessHandle, CapturingDiagnostics), FleetCapCounter
  Preconditions/  SpawnPreconditions, TrustReader, ProjectMCPConsent, LocalSettingsStore (the §6.12 write), ManagedSettingsReader
  Activity/       ActivityQuery, ActivityRow
  Router/         CommandRouter, RouterTable, LaunchSettingMatrix, RefusalInterceptor, LogoutPlan
  Store/          StateStore (protocol), FileStateStore, FleetKitState (the namespace's Codable types)
  Support/        ContentHash (sha256Hex over CryptoKit: the .mcp.json entry hash and the managed-settings payload hash)
  Verbs/          CLIVerbs (agents --json, stop, --bg --resume, --bg --exec, respawn, rm, auth status, auth logout) over ProcessRunner
FleetKit/Tests/FleetSessionsTests/
  Support/        ScratchConfigHome, ScriptedHolderFiles, ScriptedProcessRunner, TestClock, FakeClaudeLaunch
  <one file per concern>, LifecycleRowTests (G1), PreconditionTests (G3), RouterTests (G4), LiveFleetTests (G5)
```

### Types (contract X5, owned)

```swift
public struct ChannelKey: Hashable, Codable, Sendable { public let configHome: URL; public let session: SessionID }

public enum DesiredOwnership: String, Codable, Sendable { case owned, mirror, none }

public struct Holder: Hashable, Sendable {                 // one observed holder of a session
  public enum Source: Hashable, Sendable { case registry, roster, agentsJSON }
  public var pid: Int32; public var sessionID: SessionID; public var sources: Set<Source>
  public var kind: String; public var entrypoint: String?; public var jobShort: String?
  public var isOwnChild: Bool                                // pid equals a live ClaudeProcess of ours
  public var isJob: Bool { sources.contains(.roster) || jobShort != nil }   // evidence, not branch order: OriginResolver classifies by it
  public var presence: ForeignPresence?                     // status, waitingFor, name when the record carries them
}
public struct HolderSet: Hashable, Sendable { public var holders: [Holder]; public var observedAt: Date
  public var foreign: [Holder] { holders.filter { !$0.isOwnChild } } }

public struct ChannelState: Hashable, Sendable {
  public var key: ChannelKey
  public var origin: ChannelOrigin                           // X2; `.owned(.contended)` is the Contended state
  public var desired: DesiredOwnership
  public var observed: HolderSet
  public var epoch: ProcessEpoch?
  public var identity: SessionIdentity                       // ClaudeWire's: .known(id), or .awaitingFork(from:provisional:) until .sessionIdentityResolved
  public var wedged: EscalationTrace?                        // non-nil only in the wedged row
  public var systemItem: SystemItem?                         // crashed(exit:reopenOffered:) after the respawn budget; wedged(trace, reopenOffered:)
  public var presence: Presence                              // idle, busy, waiting(for:), unknown
  public var pendingDecisions: [PendingDecision]             // ask order; emptied on every exit; the Activity decision rows read it
  public var lastActivity: Date
  public var apiKeySource: String?                           // from the first system/init, kept per channel for the header
  public var liveCount: Int                                  // owned processes live across the fleet, for the cap header
  public var banner: ChannelBanner?                          // releasedToTerminal, contended(HolderSet), settingDidNotSurvive(String), mcpDeclineRefused(String), managedSettingsPending, untrusted, heldElsewhere(HolderSet)
  public var headerNote: HeaderNote?                         // projectServersOff, capReached(live:)
  public var pendingChange: RestartRequest?                  // "applies when the current work finishes"
}

public enum Presence: Hashable, Sendable { case idle, busy, waiting(for: String?), unknown }
public struct ForeignPresence: Hashable, Sendable { public var status: String; public var waitingFor: String?; public var name: String? }
public struct EscalationTrace: Hashable, Sendable { public var steps: [String]; public var pid: Int32; public var epoch: ProcessEpoch }   // the terminate_escalated steps, in order
public struct TerminationReport: Hashable, Sendable { public var exit: ExitStatus?; public var steps: [String] }   // ProcessHandle.terminate(); nil exit is the wedged row; steps are the captured terminate_escalated steps of the epoch
public struct PendingDecision: Hashable, Sendable { public var id: RequestID; public var subtype: String; public var epoch: ProcessEpoch; public var askedAt: Date }   // from the InboundRequest; askedAt stamped by the supervisor
public enum SystemItem: Hashable, Sendable { case crashed(exit: ExitStatus, reopenOffered: Bool); case wedged(EscalationTrace, reopenOffered: Bool) }   // ExitStatus is Hashable (ClaudeWire WireEvent.swift:47)
public struct ProjectMCPServer: Hashable, Sendable {
  public enum Transport: Hashable, Sendable { case stdio(command: String, arguments: [String]); case http(url: String); case sse(url: String); case other(type: String) }
  public var name: String; public var transport: Transport   // parsed from the raw entry: no `type` and a `command` is stdio; `type` http/sse carries a url; anything else is other, still listed and gated
  public var entryHash: String                               // SHA-256 (ContentHash.sha256Hex) over the canonical JSON of the whole raw entry, so any field change reopens consent
}
public struct RestartRequest: Hashable, Sendable {
  public var addDirectories: [URL]?; public var settingSources: [SettingSource]??; public var allowBypass: Bool?
  public var promptSuggestions: Bool?; public var worktree: Worktree??; public var environment: ChildEnvironmentOptions?   // nil = keep the current value
}
public struct SessionRuntimeState: Hashable, Sendable {  // actor-owned by the supervisor; every control response and frame that changes a value updates it
  public var permissionMode: PermissionMode?; public var model: String?; public var effort: String?
  public var outputStyle: String?; public var cwd: URL; public var agent: String?
  public var addDirectories: [URL]; public var environment: ChildEnvironmentOptions
  public var flagSettings: [String: JSONValue]   // the union of every apply_flag_settings payload sent through perform
  public var fastModeObserved: Bool?             // fast_mode_state from the handshake and every result frame
}
public typealias RestartSnapshot = SessionRuntimeState      // the copy the quiescent restart takes at the moment it decides to restart
public struct AgentsRow: Hashable, Codable, Sendable {      // one element of `claude agents --json`
  public var pid: Int32?; public var id: String?; public var cwd: String; public var kind: String; public var startedAt: Double
  public var sessionId: String?; public var name: String?; public var status: String?; public var waitingFor: String?; public var state: String?
}
public struct JobShort: Hashable, Codable, Sendable { public let rawValue: String }
public struct JobEntry: Hashable, Sendable {                 // one roster job, reconciled with `agents --json` when read; an exec job has no session
  public var short: JobShort; public var state: String; public var kind: String; public var sessionID: SessionID?; public var cwd: URL?; public var name: String?
}
public enum JobVerb: Hashable, Sendable { case stop, respawn, remove }
public enum LifecycleError: Error, Hashable, Sendable {
  case heldElsewhere(HolderSet), capReached(live: Int), precondition(SpawnPrecondition), wedged(EscalationTrace)
  case handoffTimedOut(HolderSet), declineRefused(reason: String), notOwned, verbFailed(verb: String, exitCode: Int32)
  case decisionGone(RequestID)                               // an answer for an id that is unknown, cancelled, already answered or from an older epoch
  case answerFailed(RequestID, reason: String)               // the write to the process failed; the id was consumed first and is not restored
  case logoutInProgress                                      // the spawn barrier while a LogoutPlan runs
}

public enum SpawnPrecondition: Hashable, Sendable {
  case ready
  case untrusted(root: URL)
  case consentNeeded([ProjectMCPServer])                     // name, transport summary, hash
  case managedSettingsPending
  case contended(HolderSet)
  case wedged(EscalationTrace)
}

public enum LifecycleAction: Sendable {                                   // Sendable only: InboundAnswer is not Hashable
  case open, send(UserInput), reap, adopt, sendToBackground, fork(at: ForkPoint?)   // nil = plain fork; ForkPoint is ClaudeWire's {entryUUID, dropsTurn?}
  case quiescentRestart(RestartRequest), stopEverything, backgroundAll, logout, reopen
  case answer(RequestID, InboundAnswer)         // the one path a decision is answered through; LifecycleError.decisionGone when the id is gone
}                                                 // the job verbs are LifecycleAPI.performJob(_:_:): a job is keyed by short, and an exec job has no session

// Design inheritance from the parent's X5 as amended on 2026-09-05 (C7's decomposing run): the Terminal
// panel never spawns `claude` for a session on its own initiative. X5 performs the ownership work of
// §7.2 rule 5 and hands the panel a pane request; the panel runs it and reports the exit back through
// X5, which owns the re-adoption of §7.4's hatch rows. `attach` and `logs` are panes; `stop`,
// `respawn` and `rm` are `performJob` verbs below (parent X5 as amended 2026-09-05), no PTY.
public enum PanePurpose: Hashable, Sendable { case hatch(SessionID), attach(JobShort), logs(JobShort), shell, command }
public struct PaneRequest: Hashable, Sendable {
  public var id: UUID                                        // opaque, fresh per request (parent X5 as amended after the plan review)
  public var executable: URL; public var arguments: [String]; public var cwd: URL
  public var environment: [String: String]                   // composed by C4 through LaunchConfiguration.childEnvironment (§6.1, X11)
  public var purpose: PanePurpose
}
public struct PaneExit: Hashable, Sendable { public var request: PaneRequest; public var code: Int32; public var observedAt: Date }
// The lifecycle accepts an exit only when `exit.request.id` is the id it is waiting on; two requests with identical
// fields are two requests, and a late exit from an older pane is discarded (parent X5).

public protocol LifecycleAPI: Sendable {                     // what C5, C6 and C7 call; nothing else spawns
  func state(of key: ChannelKey) async -> ChannelState?
  func states() async -> [ChannelState]
  func preconditions(for key: ChannelKey) async -> SpawnPrecondition
  func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState
  func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest     // §7.4 open-in-terminal row up to the handoff; purpose .hatch
  func attach(_ job: JobShort) async throws -> PaneRequest               // `claude attach <short>`; purpose .attach
  func logs(_ job: JobShort) async throws -> PaneRequest                 // `claude logs <short>`; purpose .logs
  func paneExited(_ exit: PaneExit) async                                // the panel's report; X5 re-adopts a hatch whose record is gone
  func jobs() async -> [JobEntry]                                        // every roster job, conversation or exec, with or without a session
  func performJob(_ verb: JobVerb, _ short: JobShort) async throws       // `claude stop|respawn|rm <short>` through the runner; no PTY
  func isDormantEligible(_ key: ChannelKey) async -> Bool
  func declineProjectServers(_ names: [String], project: URL) async throws        // the §6.12 write
  func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async   // store only
  func events(of key: ChannelKey) async -> AsyncStream<WireEvent>?           // nil unless owned; a fresh unbounded fan-out per call, finished when the channel archives
  var updates: AsyncStream<ChannelState> { get }             // every transition, coalesced per channel
}
```

`ChannelOrigin.owned(.contended)` stays where X2 put it: Contended is entered from an owned
channel's handoff and resolves back to an origin, and the lifecycle reads correctly with it
there. A foreign-live channel that was ours a moment ago is `.foreignLive(.usersTerminal)`
with `desired` still `.owned` until the user forks or the record disappears; the disagreement
between `desired` and `observed` is exactly the parent's rule 1 and is what the banner reads.

### Origins and detection (`Fleet/`)

`FleetObserver` is one actor per ConfigHome. It reads three sources and reconciles them by
pid into one `HolderSet` per session id:

- **registry**: every `<configHome>/sessions/<pid>.json` that parses; a record is *live*
  when `kill(pid, 0)` succeeds and the process's start time, read through `proc_pidinfo`,
  matches the record's `procStart` token within one second (the token parsed as `EEE MMM d
  HH:mm:ss yyyy`, `en_US_POSIX`, UTC, runs of spaces collapsed); when `procStart` is absent
  or does not parse the sixty-second window around `startedAt` decides instead, each
  fallback recorded as its own diagnostic; a dead record is ignored, never deleted;
- **roster and jobs**: `daemon/roster.json`'s `workers` for live jobs (pid and short), and
  every `jobs/<short>/state.json` for state, `sessionId`, `resumeSessionId` and `cwd`; a job
  is *live* when its short is in the roster's workers with a live pid, and *terminal*
  otherwise; `exit-cause` and `exit-detail` are never opened;
- **`claude agents --json`**: run through `CLIVerbs` at the pre-spawn check, on adopt, on
  send-to-background, at the `/logout` census, and on a sixty-second reconciliation, never on
  the five-second poll, because each run boots the CLI (ruling of 2026-09-05); parsed as the
  array above; rows are matched to registry and job holders by pid, and a row with no pid by
  `(id, sessionId)` to a job. Five-second detection of a foreign session comes from the vnode
  source and the file poll over `sessions/`, `daemon/` and `jobs/`, as the parent's §7.1
  names.

Origin per channel, in the parent's order: *owned* when `ChannelSupervisor` holds a live
`ClaudeProcess` for the key; *foreign live* when a live registry holder names the session id
and is not our child (`.ownTerminalTab` when the supervisor handed the session to a Terminal
tab it is still tracking, else `.usersTerminal`); *background job* when a live job names it;
otherwise *archived*. The resolver classifies a holder by evidence, not by which branch runs
first: `Holder.isJob` is true when the holder's sources include the roster or it carries a
`jobShort`; the foreign branch considers only holders with `isJob == false` and the job
branch only those with it; the parent's precedence (owned, foreign, job, archived) still
decides a session with several holders. The reader sets `jobShort` on a holder it merged
from a registry record and a roster entry, so a conversation job's worker, present in both
files, is a job and never a foreign terminal. Presence for foreign channels comes from the
record's `status` and `waitingFor` when present and is `.unknown` when absent, which is
every headless holder. Presence for an owned channel is afleet's own turn state: `busy` from
a send until its `result`, `waiting` while a decision is pending, `idle` otherwise; a
`session_state_changed` frame, when one arrives, maps `requires_action` to `waiting` and is
otherwise recorded and ignored, because the corpus has never shown one.

Watching: a dispatch vnode source on `sessions/`, `jobs/` and `daemon/`, plus a five-second
poll that re-reads everything, because in-place edits of a registry record (a TUI's status
change) do not fire a directory source. Every read is a snapshot with `observedAt`;
`FleetObserver` publishes a new `HolderSet` only when it differs from the last.

### Ownership (`Ownership/`)

`OwnershipCheck.beforeSpawn(key)` re-reads all three sources synchronously and returns
*every* live holder naming the session, our own children included: before a spawn the
supervisor holds no process, so any pid at all, foreign, a second supervisor's, or an older
epoch's ghost, means no spawn, and the channel takes the origin the holder implies (a holder
that is ours is Contended, not foreign live). `OwnershipCheck.afterHandshake(key,
ownPID:epoch:)` re-reads, validates each holder's pid and `procStart` token, and excludes
exactly one pid, the child this spawn started; any other holder, foreign or ours, means
yield: `terminate()` our process, origin `.foreignLive` for a foreign holder or
`.owned(.contended)` for one of ours, the "Opened in your terminal; afleet released this
session" notice for the former. `isOwnChild` on a `Holder` is informational for the sidebar;
the checks never use it to excuse a holder. Both are recorded on an injected `HolderReader`
so G1 can assert they ran around every spawn. Rule 5's quiescent handoff is one function,
`awaitRelease(previous holder, upTo: 10 s)`, that waits for the process exit *and* the
record's disappearance and returns `.released` or `.timedOut`, on which the channel becomes
Contended. After `.released`, `sendToBackground` and `openInTerminal` run
`beforeSpawn(session:)` once more, immediately before `--bg --resume` and before the
`PaneRequest` is built, from ready and from dormant alike (dormant has no process and no
wait, so there the recheck is the only check); any holder means no launch and no request:
the origin resolves through `OriginResolver` (foreign, job, or contended for an own pid),
the banner is set and the caller gets `LifecycleError.heldElsewhere(holders)`. The window
between a returned `PaneRequest` and the panel's spawn remains and is accepted (Decision
Log, 2026-09-05). Rule 6: `perform(.send)` on a held session throws
`LifecycleError.heldElsewhere(HolderSet)` and the state offers `fork`.

### Lifecycle (`Lifecycle/`)

`ChannelSupervisor` is one actor per channel, owning at most one `ClaudeProcess` at a time
and the channel's epoch progression (`ProcessEpoch.first`, then `.next()` on every spawn).
Frames, exits and holder events tagged with an older epoch are discarded on entry. The
supervisor is built from `LifecycleTable`, a constant array of scenarios `(row, from, event,
to)`, one per from-state a parent row admits and per outcome it can reach, that mirrors the
parent's table exactly and is what G1's coverage test reads; the parent's "handoff wait
exceeds 10 s, or desired and observed disagree" row is two events in the table,
`handoffTimedOut` and `desiredObservedDisagree`, each with its own scenarios, because they
are raised from different places and G1 must see both fire. A transition not in the table is
a programming error surfaced as a diagnostic, never a silent state change.

Time comes from an injected `any Clock<Duration>`; production passes `ContinuousClock`,
tests a manual clock, so the thirty-minute reap, the one-two-four-second backoff, the
ten-second handoff and the five-second poll are all advanced by the test.

**Dormant eligibility** is a pure function over `(turn state, pending decisions, queued
input, mirror entries, last task frame time, heartbeat interval, wedged trace, now)`, exactly
the parent's five conditions, with "uncertainty counts as running", and a wedged channel is
never eligible: there is no live process of ours to reap and a ghost may still hold the
transcript (ruling of 2026-09-05). The mirror is C3's
`RegistryMirrorEntry` (X4); until C3 lands, the supervisor takes it through a protocol,
`TaskMirrorReading`, that G1's stand-in conforms to and G2 replaces with the real mirror.
In production the fold is a `ChannelTaskMirror` per channel, built by `Fleet.build`, written by
that channel's own event pump through C3's `apply(_:at:epoch:)`, and read back by the one
`eligibilityInputs` closure every decision goes through — the thirty-minute reap, the cap
eviction, `perform(.reap)`, and `/logout`'s census and its *Stop*, which reads it again at the
moment the stop is sent. "Last task frame time" is the host's own reading and is stamped on the
**injected** clock, not on C3's wall-clock `lastFrameAt`: it is the quantity the heartbeat rule
compares, and a wall-clock one could not be moved by a test. The fold is forgotten when the child
exits, because a background shell is that child's own and dies with it.

**Wedged.** When the handle's `terminate()` returns a `TerminationReport` whose `exit` is
`nil` the channel enters `.owned(.dormant)` with `wedged` set to `EscalationTrace(steps:
report.steps, pid:, epoch:)`, the steps being ClaudeWire's `terminateEscalated` diagnostics
for the current epoch (`ClaudeProcess`'s vocabulary: `never_launched`,
`graceful_phase_deadline_exceeded`, `end_session`, `stdin_close_requested`,
`no_live_child_to_signal`, `SIGTERM`, `SIGKILL`, `exit_not_observed`) as captured by the
`CapturingDiagnostics` sink the process factory installs on every `ClaudeProcess` and
forwards to the fleet's ClaudeWire sink, and `liveCount` still counting the ghost; no
respawn happens under that session id; `.reopen` runs the pre-spawn ownership check and
spawns only when it finds no holder, clearing `wedged`. The wedged channel is released from
the live count only when a later observation finds the ghost's registry record gone and its
pid dead. Every action that terminates goes through one function, `terminateOrWedge()`, and
stops at a `nil` exit: the reap does not mark the channel dormant, send to background does
not run `--bg --resume`, open in terminal returns no `PaneRequest` and throws
`LifecycleError.wedged`, the quiescent restart does not spawn, `/logout` does not run `auth
logout` while any listed channel is wedged and reports it, and cap eviction reports the
victim as wedged so the counter frees no slot. G1 injects the `nil` through each of those
paths.

**Respawn** on a non-zero exit: three attempts at 1 s, 2 s and 4 s, each behind the pre-spawn
check; the fourth failure produces the system item with the exit code, the stderr tail from
`ExitStatus` and *Reopen*, and the channel is archived if it was never ready in this epoch
series, else owned-ready with the item.

**The cap.** A fleet-wide counter, `FleetCapCounter`, whose slots are reservations: a spawn
asks `acquire(for:)`, and the counter, in one synchronous actor turn that awaits no
supervisor, counts every occupied slot, live, reserved, wedged and pending eviction, and
decides from an eligibility snapshot each supervisor pushes on every change to its turn,
pending decisions, queued input, wedged flag or mirror reading: it either grants a
reservation when the count is below six, or names the least recently used dormant-eligible
live channel as the victim, least by the counter's own `activityClock` (a fleet-wide
`UInt64`; `noteActivity(key)` stamps `lru[key]` with it and advances it, and supervisors
call it, fire-and-forget, on every send, engine frame and decision, so stamps from different
supervisors compare), moves it out of the live set in the same turn and reserves the slot
against that eviction, or refuses. The evicting supervisor re-evaluates the victim's
eligibility at reap time, reaps it and reports the observed outcome back, `evicted`,
`victimWedged` or `victimBecameIneligible`; only `evicted` turns the reservation into a live
slot, a wedged victim frees nothing and the counter picks the next eligible victim or
refuses, an ineligible victim returns to the live set and the same re-pick runs, a victim
whose own release arrives while its eviction is pending completes that eviction into the
waiting reservation without touching the live set, and any failure between reservation and
handshake (a pre-spawn holder, a spawn error, a yield) rolls the reservation back and
returns a pending victim to the live set. Two concurrent opens at the cap therefore take two
distinct victims or one is refused; they never both spawn against one freed slot, and no
decision ever counts fewer than six occupied slots while six exist. A wedged channel is
excluded from eviction as it is from eligibility, and the cap rule reads the same trace
(ruling of 2026-09-05); none eligible means no eviction, the spawn is refused with
`LifecycleError.capReached(live: 6)`, and every channel's `liveCount` reads six so the
header can show it and offer *Send to background*. Dormant channels hold no slot: `reap()`
released it, so a dormant channel is never a victim, and only a wedged ghost keeps a count
without a process, until its record is gone and its pid dead. A fork holds its slot under
the provisional key until its identity resolves, when `rekey(provisional, to: id)` moves the
`reserved`, `live`, `lru`, `eligibility` and `wedged` entries in one counter turn; a
collision found at that point rolls the provisional reservation back instead.

**Runtime state.** The supervisor owns a `SessionRuntimeState` (permission mode, model,
effort, output style, cwd, agent, the cumulative `--add-dir` list, the environment options,
`flagSettings`, the union of every `apply_flag_settings` payload the host sent through
`perform`, and `fastModeObserved`, the `fast_mode_state` the engine last reported), seeded
from the launch and the handshake and updated by every answer and frame that changes a
value: a `set_model` answer, a `set_permission_mode` answer, `get_settings.applied` after an
`apply_flag_settings`, the `settings` of every `apply_flag_settings` the host sent (the
engine answers a bare success, so the payload is the record), `fast_mode_state` on the
initialize response and on every `result` (no other frame carries it), a `set_cwd` answer,
an accepted `add_directory`, the first `system/init`. The router's runtime-mutable commands
change the model through it, so what a later restart carries is what the channel is running,
not what it was opened with.

**Quiescent restart** takes a `RestartRequest` (`addDirectories`, `settingSources`,
`allowBypass`, `promptSuggestions`, `worktree`, environment options) and runs: wait for
dormant eligibility (queueing with the "applies when the current work finishes" state);
snapshot the runtime state; `terminate()` (a `nil` wedges and stops here); await release;
spawn `--resume <id>` with every launch field from the snapshot, `cwd` as changed by
`set_cwd`, `addDirectories` as the template's plus every accepted `add_directory` (or the
request's list), `environment`, `model`, `permissionMode`, `effort`, and never `--agent`,
the template supplying only the invariants (binary, setting sources, strict MCP config,
worktree, bypass allowance, prompt suggestions) unless the request overrides one; the
relaunch stops at the handshake without publishing `.ready`; then `apply_flag_settings` with
the whole `flagSettings` union when it is non-empty, then `get_settings`; then verify every
readback: `model` and `effort` from `applied`, permission mode and output style from the new
handshake, every key of `flagSettings` present among the keys of `effective`, and fast mode from
`effective` carrying `fastMode` when the host applied it or from the new handshake's
`fast_mode_state` against `fastModeObserved` when it was only observed. Only when every
readback matches does the channel publish `.ready`; otherwise it stays `.connecting` with a
banner naming the first setting that did not survive and keeps the composer disabled until
the user picks a value. `apiKeySource` is re-read from the relaunch's first `system/init`.

**Open in terminal, attach and logs** follow the parent's X5 as amended: `openInTerminal`
runs `terminate()`, awaits release, runs the ownership check once more (a holder now means
no request, the holder's origin and `LifecycleError.heldElsewhere`), marks the channel
`.foreignLive(.ownTerminalTab)` with the pending hatch recorded, and returns a `PaneRequest`
whose executable is the located binary, whose arguments are `["--resume", id]` (the
interactive line, none of §6.1's print-mode flags), whose cwd is the channel's, and whose
environment is `LaunchConfiguration.childEnvironment(over: resolved, configHome:)` for that
channel, so the hatch resumes under the same config home and the same scrubbed, re-injected
environment as the owned process did. `attach(job)` and `logs(job)` return requests for
`claude attach <short>` and `claude logs <short>` with the job's cwd and the same
environment, and change no ownership. The panel runs the request and calls `paneExited`; for
a `.hatch` the supervisor then waits for the registry record to disappear (rule 5's release)
and spawns `--resume <id>` owned, which is §7.4's re-adoption row; a `PaneExit` for a
request the supervisor no longer tracks (an older epoch, a channel already re-adopted) is
recorded and ignored. The panel never spawns `claude` for a session on its own initiative,
and no other package receives a `PaneRequest` for a session.

**Fork** spawns a new channel whose key is provisional until `.sessionIdentityResolved`, and
the channel stays `.connecting` until then: while `identity == .awaitingFork` the supervisor
does not apply `handshakeClean` when the spawn's handshake returns and skips the
provisional-id ownership check (meaningless for a random id), though frames already fan out
to subscribers. On the identity event for the current epoch, in order:
`ownership.afterHandshake(session: id, ownPID:, epoch:)` against the resolved id, where a
holder takes the existing `connectingFoundHolder` rows (terminate, `fleet.rollback`, foreign
or contended, no re-index); clean: `fleet.rekey(provisional, to: id)`, the facade
re-indexes, `identity = .known(id)`, `apply(.handshakeClean → .ready)`, publish. An identity
not resolved within `handshakeTimeout` is failed by a *supervisor-side identity deadline*, a
timer the supervisor arms on its injected clock when it enters the awaiting-fork branch and
cancels when the identity resolves; on expiry it terminates through `terminateOrWedge`, rolls
the fork's reservation back and fails the channel as a spawn error does. Corrected in
execution (Task 6 review): C2's handshake-timeout path cannot cover this, because
`ClaudeProcess.spawn` returns at the initialize response and cancels its timer in a `defer`,
while a fork's id resolves later off the frame reader. Without the deadline a fork whose
engine never emits `auth_status` sits in `.connecting` for ever, holding a live process and a
cap slot the counter can never reclaim. Making `ClaudeProcess.spawn` wait for `auth_status`
would be the wrong closure: it is C2's to own, and it would hold every fork's handshake open
while frames already need to be fanning out.
Captures follow C2's provisional-name rule on their own. A plain fork launches
`SessionStart.resume(source, fork: true)`. *Fork from here* launches
`SessionStart.forkFrom(source, at: ForkPoint(entryUUID: <the clicked record's uuid>,
dropsTurn: <the discarded turn's prompt uuid>))`, the C2 corrective's shape (parent Revision
Note of 2026-09-05, `13c9ad4`), and C2's line composer emits `--resume-session-at` and
`--resume-drops-turn`; FleetKit appends no argument of its own and the earlier contingency
(an `extraArguments` field or a skipped test) is withdrawn. A fork whose resolved identity
is a session another supervisor already owns yields to that owner through that check, from
`.connecting`, never having published `.ready`.

### Preconditions (`Preconditions/`)

`SpawnPreconditions.evaluate(project cwd, launch)` runs in this order and returns the first
failure: wedged; contended (a foreign holder from the pre-spawn check); managed settings
pending; untrusted; consent needed. Only `.ready` spawns.

- **Trust** (`TrustReader`): canonical root = the real path of the channel directory walked
  up to the first entry containing `.git` (file or directory), else the real path itself;
  read `projects[<root>].hasTrustDialogAccepted` from `<configHome>/.claude.json`; anything
  but `true` is untrusted. Read-only; re-read when the app asks after a terminal pane exits.
- **Project MCP consent** (`ProjectMCPConsent`): parse `<root>/.mcp.json` (each entry's
  transport from its raw shape: no `type` and a `command` is `.stdio(command:arguments:)`,
  `type` `http` or `sse` is `.http(url:)` or `.sse(url:)`, anything else is `.other(type:)`,
  still listed and still gated; `entryHash` is SHA-256 over the canonical JSON of the whole
  raw entry, so a change to args, env, headers or url reopens consent, and the consent
  file's arrays hold names, the same for every transport); for each server compute rejected,
  approved or pending from the merged settings sources only, read-only, the way the engine
  does. The bundle settles the sources (2.1.257 `cli.pretty.js`, chunk `1kg58a1a`, the
  project-server consent function at pretty lines 94640–94682): it reads the merged
  effective settings that the settings loader returns from disk; `disabledMcpjsonServers`
  naming the server is **rejected**; otherwise, when the project root is trusted,
  `enabledMcpjsonServers` naming it or `enableAllProjectMcpServers` in the merged settings
  is **approved**, and when untrusted the same two keys are consulted per enabled source
  with the project-settings source skipped; anything else is **pending**. The per-project
  arrays in `.claude.json` are not read there: they are a legacy location that the startup
  migration (`migrateEnableAllProjectMcpServersToSettings`, pretty lines 503739–503785)
  copies into local settings when non-empty and clears, so the v2 rule that read them was
  reading a file the engine had already emptied. C1's spike confirms the write side: the
  terminal's decline writes exactly the local-settings store's `disabledMcpjsonServers` and
  nothing in `.claude.json`. The same function's caller promotes a *pending* server to
  approved on the non-interactive path when the project-settings source is enabled, which is
  why the parent's §6.12 says a pending server's command is spawned at startup and why the
  write must land before the child exists. Precedence in afleet's reader, therefore:
  rejected wins over approved wins over pending; the sources are the resolved local-settings
  store (plus the legacy overlay at the cwd when the store moved to the git root),
  `<root>/.claude/settings.json` and `<configHome>/settings.json`, each only when the
  launch's setting sources include it. Pending servers with a hash of their entry that the
  FleetKit store has not recorded as accepted yield `.consentNeeded`. *Accept* records
  `(project, name, hash)` in the store and writes nothing. *Decline* is
  `LocalSettingsStore.decline(names, root)`: the parent's store resolution and write policy
  line by line, executed only while no owned process for the project is running, followed by
  a re-read through the same resolver before any spawn is allowed. The writer works on
  directory descriptors, never on paths after resolution: it opens the resolved root with
  `O_DIRECTORY|O_NOFOLLOW`, requires the descriptor's `F_GETPATH` to equal the resolved path
  (an ancestor swapped in between is refused as a symlink) and runs the config-home
  containment check on that `F_GETPATH` result rather than on any string computed before the
  open, then opens `.claude` relative to it with `O_DIRECTORY|O_NOFOLLOW`, `fstat`s it for
  type and ownership, `mkdirat`s and opens `.cc-writes` the same way, creates the staging
  file with `openat` and `O_NOFOLLOW|O_EXCL`, reads the existing target through `openat`
  with `O_NOFOLLOW`, `fchmod`s the staging file to the target's mode, `fsync`s, `renameat`s
  within the one directory descriptor and `fsync`s the directory. Fail closed: unparseable
  JSON, a symlink at the target, its parent, the staging directory or any component swapped
  after resolution, a foreign uid on the root, `.git`, `.claude` or `.cc-writes`, a store or
  staging directory inside the ConfigHome, or any write error means
  `LifecycleError.declineRefused(reason)` and the `/mcp` banner. When the launch's setting
  sources exclude `local` and `.mcp.json` declares servers, the launch gains
  `strictMCPConfig = true` and the state carries `headerNote = .projectServersOff`.
- **Managed settings** (`ManagedSettingsReader`): a payload is pending when
  `<configHome>/remote-settings.json` exists and `remote-settings-consent.json` does not
  record consent for it. The consent record's shape is unrecorded in the corpus; the reader
  is written from the bundle's chapter 48 §2.9 at plan time, treats an unparseable pair as
  pending (fail closed) and is listed under *Delegated unknowns*.

### Activity (`Activity/`)

`ActivityQuery.rows(states, mirrors, recentFrames)` is a pure function producing
`ActivityRow`s in the parent's categories: pending decisions (one row per
`ChannelState.pendingDecisions` entry, in ask order, carrying the request id and subtype),
notifications, failed results (`result` error subtypes and `is_error` tool results),
permission denials (`result.permission_denials` and `system/permission_denied`), rate-limit
banners (decided by `status` alone; `overageStatus: "rejected"` with `org_level_disabled`
never renders as a refusal), auth state from `auth_status`, running and failed agent runs
from the mirror. Each row carries its `ChannelKey` and, where one exists, the item uuid, so
C6 links it; answering a decision from Activity goes through the same `answer` path as the
channel.

### Router (`Router/`, contract X10, owned)

`RouterTable` is data: `[LocalCommand]` with `name`, `strategy` (a closed `RouteStrategy`
whose cases name the exact request or request sequence the command runs: single requests such
as `.setModel` and `.setPermissionMode`, multi-step `.rewind` and `.login`, the read-only
`.permissionsView`, `.mcpPopover` and `.memoryFiles`, `.lifecycle(action)`, `.restart`,
`.text` and `.native(name)`), `readback`, and `explanation`. `CommandRouter.route(text,
handshake)` resolves in the parent's order: local table, then `terminal_slash_commands`
(hidden and refused with the explanation), then pass-through as text. Autocomplete merges
the handshake's `commands` with the local table. `RefusalInterceptor` matches the exact bare
refusal `/<name> isn't available in this environment.` on an assistant frame, replaces it with
afleet's explanation, and counts it for the drift log. `LaunchSettingMatrix` is the
runtime-mutable versus restart-required table; `/add-dir` builds a `RestartRequest`.
`/logout` builds a `LogoutPlan`: raise the spawn barrier; census owned channels and
afleet-launched jobs (jobs whose `state.json.cwd` and `resumeSessionId` match a channel afleet
sent to background, remembered in the store); list non-eligible channels with their live
tasks; *Wait* or *Stop* (`interrupt {cancel_queued: true}` plus `stop_task` per mirror id);
stop jobs with `claude stop <short>` and verify roster removal; terminate owned channels;
`claude auth logout` through the runner; report success when every listed process has
exited; name foreign registry records as keeping their token.

### Store (`Store/`, contract X6, owned)

```swift
public protocol StateStore: Sendable {
  func read<T: Codable & Sendable>(_ type: T.Type, namespace: StoreNamespace, key: String) async throws -> T?
  func write<T: Codable & Sendable>(_ value: T, namespace: StoreNamespace, key: String) async throws
  func remove(namespace: StoreNamespace, key: String) async throws
  func keys(in namespace: StoreNamespace) async throws -> [String]
}
public enum StoreNamespace: String, CaseIterable, Hashable, Codable, Sendable { case fleetKit, workbench, afleet }   // closed: a namespace is a package, and there are three
public protocol StoreFileOperations: Sendable {             // the seam the atomicity tests inject faults through; production is Darwin's calls
  func create(in directory: URL, named: String) throws -> (fd: Int32, url: URL)   // O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW, 0o600
  func write(_ data: Data, to fd: Int32) throws
  func fsync(_ fd: Int32) throws
  func close(_ fd: Int32) throws
  func rename(_ from: URL, to: URL) throws
  func fsyncDirectory(_ directory: URL) throws
}
public actor FileStateStore: StateStore {
  /// The only public construction. Resolves every path and throws `StoreError.insideConfigHome` when the base equals
  /// or lies under any of `configHomes`; there is no unvalidated initialiser for production or tests to reach.
  public init(baseDirectory: URL, configHomes: [URL], fileOperations: any StoreFileOperations = DarwinStoreFileOperations()) throws
}
```

One JSON document per namespace, `<base>/state.<namespace>.json`, with an envelope
`{schemaVersion, values: {key: json}}`; every write re-serialises the namespace document to
a temporary file in the same directory and renames it into place through the file-ops seam,
and the atomicity claim is tested by injecting a failure at the create, at the write (after
part of the payload has landed), at the `fsync`, at the `close`, at the `rename` and at the
directory `fsync`, and asserting, after each, that a reader sees the whole old document (the
whole new one only after the rename), never a partial file, that the staging file was
removed through the seam, and that a base directory reached through a real symlink alias of
the config home is refused by the initialiser. The schema version is handled per case: a
missing document is an empty namespace; a document that does not parse, or parses without
the envelope, is moved aside to `state.<namespace>.json.malformed-<timestamp>` with a
diagnostic and the namespace starts empty; an older `schemaVersion` runs that namespace's
migration chain on read and is rewritten at the current version on the next write; a newer
`schemaVersion` is read for the keys this build understands, every write to that namespace
is refused with `StoreError.schemaTooNew`, and the state carries a banner saying a newer
afleet wrote it. Keys are non-empty strings in which dots are ordinary characters and imply
no hierarchy; the schema version is per namespace and nothing else is versioned. This is
design inheritance from the parent's X6 as amended on 2026-09-05: Workbench persists under
`workbench.browser` and `workbench.panel.<configHomeHash>.<sessionId>` in its own namespace,
and a test writes and reads back both key shapes through the API. The app injects
`baseDirectory` (`~/Library/Application Support/afleet/` in production, a temporary
directory in tests) together with the config homes it knows; nothing about the store reads a
ConfigHome, and a base directory inside one is rejected by the one constructor there is
(X9). `FleetKitState` holds the namespace's own `Codable` types: channel grouping and pins,
section order and collapse, unread cursors per session, `DesiredOwnership` per channel,
project-server acceptances `(project, name, hash)`, afleet-launched job shorts, the bypass
disclaimer acceptance, the fixture-recorded baseline and the last census. FleetKit never
models Workbench or Afleet state.

### C3's index storage

C3 declares `IndexStorage` in `FleetTimeline`, a two-function protocol that loads and saves an
index snapshot. `FleetSessions` implements it as `StoreIndexStorage` over `FileStateStore`
under the `fleetKit` namespace, key `timeline.index`, and the app injects that instance into
C3's index. Nothing moves to `AfleetCore` (ruling of 2026-09-05).

### Sidebar listing policy (contract X5)

C3's index exposes `entrypoint`, `sessionKind`, `isSidechain`, `teamName` and `continuedIn`
per transcript and applies none of the engine's picker drop rules; which transcripts become
channels is C4's policy under X5 (ruling of 2026-09-05). `ListingPolicy.include(entry)` is a
pure function: afleet's own `sdk-cli` sessions are listed; sidechains are not; a transcript
with `continuedIn` set is listed under its continuation only; teammate transcripts
(`teamName` set) are listed read-only under their project, never as owned candidates,
because agent teams as members are out of scope; every other entry is listed. The policy is
data the sidebar can show as an explanation, and a test enumerates each rule with an entry
that exercises it and its negation.

### CLI verbs (`Verbs/`)

`CLIVerbs` wraps `ProcessRunner` with the resolved environment, the located binary and a
per-verb timeout: `agentsJSON() -> [AgentsRow]`, `stop(short)`, `backgroundResume(id, cwd)
-> JobShort` (found by diffing `jobs/*/state.json` before and after for `resumeSessionId ==
id`, then confirmed in the roster), `backgroundExec(command, cwd)`, `respawn(short)`,
`remove(short)`, `authStatus()`, `authLogout()`; `attach` and `logs` are never run here,
because they need a PTY and are pane requests (X5 as amended). `LifecycleAPI.jobs()` reads
the roster (reconciled with `agents --json` when read) into `JobEntry`s, exec jobs included
with `sessionID == nil`, and `performJob(_:_:)` maps `.stop`, `.respawn` and `.remove` onto
`stop`, `respawn` and `remove`; channels stay keyed by session, so a conversation job is
both a `.backgroundJob` channel and a `JobEntry`, and an exec job is a `JobEntry` only.
Every verb call is a diagnostic event carrying the verb, exit code and duration and never
its stdout. Tests inject `ScriptedProcessRunner`, which maps an argv pattern to `(stdout,
exit)` and may mutate the scripted holder files so that `stop` removes a worker from the
roster and marks the job stopped, and `--bg --resume` creates a job with the right
`resumeSessionId`.

### Diagnostics

`WireDiagnostics.DiagnosticEvent` is a closed enumeration owned by C2, so FleetKit records
its own events through its own sink type, `FleetDiagnostics`, that writes the same one-line
JSON shape (`event`, structural fields, epoch where one applies) into the app's diagnostics
directory beside C2's file. Lifecycle transitions, ownership-check outcomes, handoff waits,
verb calls and precondition verdicts are events; none carries a payload, a path under a
config home, or stdout.

### The write allowlist, widened

C2's live gate proved the never-write rule for one turn. G5 takes the same before-and-after
reading of `/tmp/afleet-fixtures/config-home` across every live scenario it runs and reports
the set of relative paths the engine created or modified. The allowlist C4 ships names, as
top-level names, what the engine is known to write, C2's observed set plus the trees this
child exercises: `sessions/`, `projects/`, `tasks/`, `jobs/`, `daemon/`, `todos/`,
`statsig/`, `shell-snapshots/`, `session-env/`, `file-history/`, `debug/`, `plugins/`,
`cache/`, `backups/`, `plans/`, `ide/`, `logs/`, `history/`, `.claude.json`,
`.credentials.json`, `.last-cleanup`, `.last-update-result.json`, `daemon.log`,
`daemon.lock`, `daemon.status.json`, `history.jsonl` and `settings.json`; a unit test pins the
set exactly so an addition is deliberate. `daemon.lock` and `daemon.status.json` were added on
2026-09-06 by the gate itself naming them on its first live run: they are writes of the daemon
subsystem the list already carries through `daemon/` and `daemon.log`, and the gate reporting
them is the allowlist working as designed. An observed path outside the allowlist fails the gate with the path named,
because either the allowlist or the never-write claim is wrong and both deserve a look. The
turn-spending scenario behind `AFLEET_LIVE_CLI_TURNS=1` sends one `haiku` prompt asking for
a five-second background shell and an Explore subagent under a channel with the Notification
hook registered, so hooks, a background shell and a subagent all write in one prompt; the
test answers the decisions itself, the Notification hook's callback first and the held
`can_use_tool` after it, waits after the prompt's `result` for the shell's
`task_notification` and the engine's automatic follow-up turn (the `background-shell`
fixture shows that second `result`; a channel is never closed over a running task), and only
then relocates with `set_cwd` against a second trusted directory in the same channel. The
witness is read twice, once while the child is still live and once after it has ended, and
both readings must be fully explained; the child's own `sessions/` record is the floor of
the live reading and the transcript under `projects/` the floor of the final one, so the
demonstration that the allowlist discriminates removes `projects/`. The test also asserts
from the channel's own events that the prompt's actions ran: a `task_started` for the
background shell, a `task_started` for the subagent and the Notification hook's callback,
each named when missing, that the hook was answered before the permission, and that both
`result`s are `success`. Editor integration is not reachable from afleet and is stated as
untested.

## Contracts

**Owned by C4.** X5 Lifecycle API, exactly `LifecycleAPI`, `ChannelState`,
`SpawnPrecondition`, `LifecycleAction`, `PaneRequest` (with its opaque `id`), `PanePurpose`,
`PaneExit`, `HolderSet` and `ChannelKey` above, with public initialisers on every value a
downstream package constructs; the pane protocol, the `id` and the verb-versus-pane split
are inherited from the parent's X5 as amended on 2026-09-05, not chosen here. X6 Store
namespaces, exactly
`StateStore`, `StoreNamespace` and `FileStateStore` above. X10 Command router table,
exactly `RouterTable`, `LaunchSettingMatrix`, `CommandRouter.route` and
`RefusalInterceptor`; the composer renders them and re-implements no mapping. X1's FleetKit
manifest.

**Bound by C4.** X1: `FleetSessions` imports `FleetTimeline`, `ClaudeWire` and `AfleetCore`
and nothing above them, enforced by the manifest and an import-grep test. X2:
`ChannelOrigin` with `contended` under `owned`, `SessionID`, `ConfigHome`,
`ResolvedEnvironment` as they are. X3: every process action goes through `ClaudeProcess`;
`Handshake.pending` is never read for display; `system/init` is read off the stream; a fork's
id waits for `.sessionIdentityResolved`; `terminate()`'s `nil` is the wedged row. X9: nothing
in `FleetSessions` or its tests writes under any ConfigHome; the one project write is
`LocalSettingsStore.decline` under the parent's §6.12 policy; foreign sessions are never
signalled; adoption is offered only for jobs; `submit_feedback` is never sent. X4 (consumed):
the mirror entry and agent-run node shapes are C3's; C4 reads them through
`TaskMirrorReading`.

## Parent revisions

To file on the parent at merge, each as a dated Revision Note, unless the human gate decides
otherwise: the store layout as one document per namespace under the parent's directory (the
file format is advisory inheritance); the directory watcher as a dispatch vnode source plus
the five-second poll rather than FSEvents (advisory means); the `TaskMirrorReading` protocol
through which C4 consumes X4's mirror, so C3's landing replaces a stand-in rather than an
interface; and the `IndexStorage` seam between C3 and C4 as ruled (declared in
`FleetTimeline`, implemented here), which needs no X2 change.
`LifecycleAction.answer(RequestID, InboundAnswer)`, `LifecycleAPI.events(of:)`,
`LifecycleAPI.jobs()` and `LifecycleAPI.performJob(_:_:)` (the job verbs moved off
`perform(on:)`, because an exec job has no session key) are surface additions to X5 (the
parent names only the state and action vocabulary); the parent's Revision Note at merge
records them. Nothing about §6.12 flows back: the bundle read and C1's spike confirm the
parent's rule that the local-settings store is the only source the rejection gate reads, and
this document's v2 widening to the `.claude.json` project entry is withdrawn in v2.2.

### From the whole-branch review of 2026-09-06

Four parent impacts the architect applies at merge, all of them consequences of the rulings
recorded in the Decision Log.

**§7.4, the lifecycle table.** Three amendments, one principle.

- **A new row**, `(readyExitedClean, Owned ready, exitedClean, Owned dormant)`: a child that ends
  cleanly on its own. The slot is released and no system item is written, because a clean exit is
  not a crash. The table has no row for this at all today.
- **The crash row's *To*** becomes "Owned, dormant or Archived (older)": dormant when the series
  had reached ready, archived-older when it never did, from ready and from connecting alike.
- **One sentence of principle**: dormant is the resting state of every processless owned channel,
  and a spawn that does not complete leaves the channel where it started. Never leave a channel in
  ready or connecting with no process. The restore is not a row of its own — it is the
  `adoptOrigin` idiom, "nothing of ours changed, the attempt did not happen".

**§8.5, the composer.** `/rewind` sends `rewind_conversation` before it touches a single file, and
`rewind_files {dry_run: false}` only when the conversation rewind was honoured *and* the user asked
for the files as well. §8.5's refusal design is unchanged and is the parent's: the engine's `error`
string is surfaced and *Fork from here* is offered (item 13). What changes is only that no file is
reverted ahead of a refusal. The paragraph's "shows the counts before applying" stays true — the
`dry_run: true` preview is read-only and still runs first — and the sheet now answers with three
choices rather than a yes/no, because the two rewinds are independent.

**X5, the action and error vocabulary.** `LifecycleError.busy(LifecycleOperation)` is an addition
C5 and C6 must know about: every lifecycle action a surface can invoke may now throw it, and the
right response is to leave the channel alone and let the user retry, never to retry automatically.
`LifecycleOperation` (`spawn, handOff, restart, reopen, adopt, evict, reap`) comes with it. Two
entry points refuse without throwing, because their signatures cannot: `reap()` returns silently
and `evict()` answers `.victimBecameIneligible` — a channel already running an operation of its own
is not a victim.

`LifecycleError.notEligible(DormantEligibility.Blocker)` is the **second** addition beside it, and
C5 and C6 must know about it too: `perform(.reap)` — the *Reap* a surface offers — is now refused
whenever the channel is not dormant-eligible, and the error names the blocker (a turn in flight, a
decision on screen, queued input, a wedge, or a background task by id) so the surface can say what
is holding the channel rather than "not now". The refusal is on the facade only;
`ChannelSupervisor.reap()` stays the unconditional terminate the thirty-minute timer and a test
teardown use.

**`get_settings`'s answer shape, throughout the parent.** The root spec still specifies
`effective_keys` and `sources_keys` (§ lines 474, 1075, 1078, 3773-3774, 3966). The recorded
answer carries `effective` — an object whose *keys* are the setting names — and `sources`, an
array whose entries each hold a `settings` map; both redactors, C1's fixtures and this child's
restart readback now read that shape, and the reader that read `effective_keys` was a false
mismatch that parked a successful relaunch behind a banner that never cleared (ruling 5's
corrective, and `2b06be9` on `main`). Nothing in the parent's *design* changes — the readback
still compares the keys the engine reports against the keys the restart applied — only the two
field names the protocol contract states. The architect owns the edit at merge, as with the §7.4,
§8.5 and X5 impacts above; it is recorded here because the contradiction is otherwise handed to
nobody.

## Delegated unknowns

- The `remote-settings.json` and `remote-settings-consent.json` shapes. Modelled from the
  bundle's chapter 48 §2.9 at plan time; fail closed; a real payload, if one is ever
  observed, becomes a C1 recording.
- Whether `claude --bg --exec` produces a job with a `sessionId` that `--resume` accepts. G5
  lists the exec job through `jobs()` and records `sessionID == nil` as the observation;
  adoption of a conversation job is the turn-spending path.
- The `mcp_status` answer for a project server that was rejected through
  `disabledMcpjsonServers` (omitted, or listed with a status word). G5's consent scenario
  records the two answers' shapes as counts; the marker file is the assertion.
- The completed answer of `claude_oauth_wait_for_completion`. The corpus records only the
  "No active claude_authenticate flow" error; the router's login strategy is tested to that
  point against the fixture and past it against a scripted answer, stated as such.
- What a headless child writes under the config home across hooks, background shells,
  subagents and relocation, beyond the one turn C2 measured. G5's allowlist reading answers
  it for one composed prompt and the engine's follow-up turn after its background shell.

## Questions for the human gate

Answered on 2026-09-05; kept as the record of what was asked. (1) Nothing moves to
`AfleetCore`; C3's `IndexStorage` is implemented here over `FileStateStore`. (2) Yes to the
one composed turn behind `AFLEET_LIVE_CLI_TURNS=1`, after the budget check; at most two
short turns in total (raised to four in v2.4: adoption reserves two because a resumed job
may run a turn, and the composed prompt reserves two because the engine follows a background
shell's completion with a turn of its own). (3) One document per namespace, filed on the
parent's §7.8.

1. **Where does the store protocol live?** §7.3 says C3's transcript index caches into the
   store, but `FleetTimeline` cannot import `FleetSessions`. Recommendation: `StateStore`
   and `StoreNamespace` move to `AfleetCore` as an X2 addition (a Revision Note on the
   parent), `FileStateStore` stays in C4, and C3 receives an instance by injection. The
   alternative, C3 keeping its cache in memory only, costs the cold-index budget on every
   launch.
2. **Spend one live turn to widen the write allowlist?** Recommendation: yes, once, behind
   `AFLEET_LIVE_CLI_TURNS=1`, on `haiku`, after the budget check; the never-write claim is
   the project's central safety promise and one composed turn is the cheapest evidence that
   exists. Total live spend for C4 is then at most five short turns (adoption two, composed two,
   restart readback one).
3. **Store layout.** The parent's §7.8 names one `state.json`; this child chooses one document
   per namespace under the same directory so three packages never contend for one file. The
   file format is advisory inheritance; if the single file is preferred, the change is local.

## Decision Log

- Decision: one `FleetSessions` target with a folder per concern.
  Rationale: the concerns share the channel state type and the supervisor; module walls
  between them would multiply public surface with no consumer. Rejected: a target per
  concern (seven targets for one consumer); folding everything into `FleetKit` (C3 and C4
  would then contend for one module).
  Date/Author: 2026-09-05 / C4 dispatch.
- Decision: `ChannelSupervisor` is an actor per channel driven by a constant `LifecycleTable`
  and an injected `Clock`, and it reaches its process through a `ProcessHandle` protocol that
  `ClaudeProcess` conforms to.
  Rationale: the parent's table is the specification; making it the code's data lets G1
  assert coverage by set equality and lets every timer be advanced by a test. The seam exists
  for one row: a wedged channel needs `terminate()` to return `nil`, which no real child can
  cause, so that row runs against a scripted handle; every other row runs against a real
  stand-in process. Rejected: a single fleet actor with a state map (one hot actor for six
  processes' frames); wall-clock tests with shortened constants (the constants are the
  behaviour); skipping the wedged row (the one row whose bug would leave a ghost holding a
  transcript).
  Date/Author: 2026-09-05 / C4 dispatch; seam added at planning. v2.3: the conformance is a
  `LiveProcessHandle` wrapper and `events` an existential, see the entry below.
- Decision: holder liveness is pid liveness plus process start time within sixty seconds of
  the record's `startedAt`.
  Rationale: the CLI validates with `procStart`, whose format the corpus has not recorded,
  and inventing it is forbidden; start time from `proc_pidinfo` detects pid reuse just as
  well. Rejected: pid liveness alone (pid reuse would fabricate a holder); parsing
  `procStart` (unrecorded format).
  Date/Author: 2026-09-05 / C4 dispatch. Superseded in v2.3: `procStart` is the comparison and
  the window the fallback, see the entry below.
- Decision: CLI verbs run through `WireEnvironment.ProcessRunner`, scripted in tests by an
  in-process `ScriptedProcessRunner`; `fake-claude` is not extended.
  Rationale: X8 scopes `fake-claude` to the stream-json process; verbs are separate
  invocations whose observable effects are files, which a scripted runner can produce
  deterministically without a second Python tool. Rejected: a C1 corrective to teach
  `fake-claude` verbs (a second contract for the same stand-in); shelling out to a shim
  script (a process per verb in every test).
  Date/Author: 2026-09-05 / C4 dispatch.
- Decision: the store is one JSON document per namespace with temp-file-and-rename and a
  schema version in the envelope.
  Rationale: three packages persist independently; one document per namespace makes each
  write atomic for its owner and each migration local. Rejected: a single `state.json`
  (cross-package write contention, one migration for all); SQLite (deferred by the parent
  until search).
  Date/Author: 2026-09-05 / C4 dispatch.
- Decision: the router table is data with a set-equality test against the parent's §7.7
  rows.
  Rationale: X10 says the composer never re-implements a mapping; a table it can enumerate is
  the only way to keep that true, and set equality catches both a missing and a duplicated
  row where a count would not. Rejected: a switch statement (not enumerable by the
  composer's autocomplete).
  Date/Author: 2026-09-05 / C4 dispatch.
- Decision: G5's foreign-session half uses an interactive `claude` on a pseudo-terminal in a
  directory the scratch home already trusts, and its job half prefers `--bg --exec`.
  Rationale: both spend no model turn; the trust prompt would otherwise block the terminal
  holder (C1's Surprise), and afleet never writes trust. Rejected: starting a session in the
  user's terminal (root CLAUDE.md forbids touching it); a prompt job by default (a turn per
  run).
  Date/Author: 2026-09-05 / C4 dispatch.
- Decision: owned-channel presence derives from afleet's own turn and decision state;
  `session_state_changed` is consumed only for `requires_action`.
  Rationale: the corpus has no such frame, so a design that waited for it would render
  unknown presence on every owned channel. Rejected: presence from `session_state_changed`
  alone.
  Date/Author: 2026-09-05 / C4 dispatch.
- Decision: FleetKit records its diagnostics through its own sink type with the same line
  shape as C2's.
  Rationale: `DiagnosticEvent` is a closed enumeration owned by C2; asking C2 to open it
  would put FleetKit's vocabulary in ClaudeWire. Rejected: wrapping lifecycle events into
  `captureSkipped(reason:)` or another free-form case (the bypass shape the parent's §6.3
  forbids).
  Date/Author: 2026-09-05 / C4 dispatch.
- Decision: a directory watcher is a dispatch vnode source plus the five-second poll rather
  than FSEvents.
  Rationale: three directories, no recursion, no dependency; in-place edits are covered by
  the poll either way. Advisory inheritance overturned locally; noted for the parent.
  Rejected: FSEvents (a stream for what a vnode source does).
  Date/Author: 2026-09-05 / C4 dispatch.
- Decision: project MCP consent is computed from the merged settings sources only, and the
  proof that a decline is honoured is a two-launch zero-cost scenario against the installed
  CLI.
  Rationale: the engine's consent function reads the effective settings and nothing else
  (bundle citation under *Preconditions*); the `.claude.json` arrays are migrated away at
  startup, so reading them could only disagree with the engine. `fake-claude` runs no server,
  so a marker under it proves nothing; two real launches differing only in the declined key,
  with the marker present after exactly one and `get_session_cost` at zero on both, is the
  cheapest evidence that the write reaches the engine. Rejected: reading the project entry
  as a second source (v2's rule; overturned by the bundle and the spike); a marker test under
  `fake-claude` (tautological).
  Date/Author: 2026-09-05 / C4 plan review, ruling 1.
- Decision: the §6.12 writer works on directory descriptors (`O_DIRECTORY|O_NOFOLLOW`,
  `fstat`, `mkdirat`, `openat` with `O_NOFOLLOW|O_EXCL`, `renameat`), never on paths after
  resolution.
  Rationale: a path checked and then opened by name can be swapped for a symlink between the
  two; only descriptor-relative operations make the check and the use one object. Rejected:
  `O_NOFOLLOW` on the final open alone (leaves the staging directory and every component
  open to a swap).
  Date/Author: 2026-09-05 / C4 plan review, ruling 2.
- Decision: the pre-spawn check refuses on every live holder, and the post-handshake check
  excludes exactly the pid this spawn started.
  Rationale: "foreign" cannot be defined as "not one of our pids" when two of our supervisors,
  or an old epoch's ghost, can hold one session; the only pid a check may excuse is the one it
  just created. Rejected: excusing every own child (two own processes on one transcript).
  Date/Author: 2026-09-05 / C4 plan review, ruling 3.
- Decision: cap slots are reservations granted in one counter turn; eviction reports its
  observed outcome and a wedged victim frees no slot.
  Rationale: two concurrent opens at the cap otherwise both count the same freed slot; a
  reservation makes the decision atomic and a reported outcome keeps the counter honest when
  the victim does not die. Rejected: check-then-evict-then-count (the race the review named).
  Date/Author: 2026-09-05 / C4 plan review, ruling 6.
- Decision: the store's namespace is a closed enum, its only constructor validates the base
  against the config homes, file operations go through an injected seam, and schema versions
  are handled per case (missing, malformed, older, newer).
  Rationale: a namespace is a package and there are three; an unvalidated constructor is a
  path around X9 that a test would eventually take; an atomicity claim without a fault
  injector is a listing check; "refuse a newer document" without saying what a reader does
  loses the user's state on a downgrade. Rejected: an open `RawRepresentable` namespace; a
  convenience `init(baseDirectory:)`.
  Date/Author: 2026-09-05 / C4 plan review, ruling 7.
- Decision: the supervisor owns a `SessionRuntimeState` updated from control answers and
  frames, and the restart snapshots it.
  Rationale: a restart that carries the launch template re-applies the values the channel was
  opened with and silently reverts every `/model` and `/permissions` since; the model must be
  what the channel is running. Rejected: snapshotting the template plus a diff of routed
  commands (a second source of truth).
  Date/Author: 2026-09-05 / C4 plan review, ruling 9.
- Decision: router entries carry a typed strategy and the mechanism test runs each strategy
  against the fixture that recorded it; multi-step commands are fixture-backed.
  Rationale: asserting that an enum value is a case of its enum tests nothing; the parent's
  §7.7 rows for `/rewind`, `/login`, `/permissions`, `/mcp` and `/memory` are sequences, and
  the corpus records their frames. Rejected: the tautological mapping test.
  Date/Author: 2026-09-05 / C4 plan review, ruling 10.
- Decision: G5 runs behind one serialised live budget with a haiku pin, `--max-turns` on
  every launch, ceilings on turns and wall time, summed `result` costs, `get_session_cost` as
  the zero-cost witness, and one suite-level config-home witness.
  Rationale: per-test budget checks let independent tests each spend "one turn"; a zero-turn
  launch emits no `result` frame, so zero cost needs a request that answers it; a per-test
  witness misses writes between tests. Rejected: per-test budget and witness.
  Date/Author: 2026-09-05 / C4 plan review, ruling 11.

- Decision: `ProcessHandle.events` is `any AsyncSequence<WireEvent, Never> & Sendable`; the
  live conformance is a `LiveProcessHandle` wrapper over `ClaudeProcess`; the scripted
  handle's stream is an `AsyncStream` the test feeds.
  Rationale: `WireEventStream` has an internal initialiser and a non-throwing `next()`
  (`BoundedChannel.swift:110-118`); nothing outside ClaudeWire can construct or feed one, so
  a scripted handle typed on it could never exist, and a retroactive conformance cannot
  witness the existential with the actor's concrete stream. The wrapper exposes the same
  stream value, so backpressure is untouched. Rejected: re-pumping the events through an
  `AsyncStream` inside the live handle (loses the bounded channel's backpressure); making
  `WireEventStream`'s initialiser public (a ClaudeWire change for a test seam).
  Date/Author: 2026-09-05 / C4 plan review 2, ruling 1.
- Decision: the cap counter counts `live + reserved + wedged + pendingEvictions`, takes
  eligibility as a snapshot the supervisors push, decides synchronously, moves a victim out
  of `live` at selection, re-checks the victim at reap time and lets the victim's own
  `release` complete a pending eviction.
  Rationale: with the victim still counted in `live` and eligibility pulled through an
  `await`, a second `acquire` racing the first eviction could see the freed slot twice and a
  seventh process could exist; a synchronous decision over every occupied slot closes the
  window. Rejected: a global lock around open (serialises unrelated opens); counting the
  victim twice.
  Date/Author: 2026-09-05 / C4 plan review 2, ruling 2.
- Decision: the §6.12 writer opens the resolved root, requires `fcntl(F_GETPATH)` to equal
  the resolved path, and runs the config-home containment check on that result; two
  ancestor-swap tests join the symlink suite (eight).
  Rationale: a string check before the open guards a path the open no longer refers to when
  an ancestor is swapped for a symlink in between; verifying the descriptor closes the race
  the descriptor-relative design exists for. Rejected: `O_NOFOLLOW_ANY` (macOS 12+ only on
  the final open, not the ancestors); re-resolving after the open (the same race one step
  later).
  Date/Author: 2026-09-05 / C4 plan review 2, ruling 3.
- Decision: `SessionRuntimeState` records `flagSettings` (the union of every
  `apply_flag_settings` payload) and `fastModeObserved`; the restart relaunches every launch
  field from the snapshot, re-applies the union, verifies every key against the keys of `effective`
  and publishes `.ready` only after the readbacks.
  Rationale: `get_settings.applied` carries no fast-mode key and `fast_mode_state` is
  reported only by the initialize response and `result` frames; a single boolean could
  neither be re-applied faithfully nor verified from one source. Relaunching `cwd` from the
  template after a `set_cwd` would silently move the session back. Rejected: verifying fast
  mode from the handshake alone (the engine reports a host toggle lazily); publishing
  `.ready` at the handshake and revoking it.
  Date/Author: 2026-09-05 / C4 plan review 2, ruling 4.
- Decision: `LifecycleAction.answer(RequestID, InboundAnswer)` and
  `LifecycleAPI.events(of:)` are the API's answer and live-event surface; `LifecycleAction`
  is `Sendable` only.
  Rationale: only the supervisor holds the process, so the channel, the overlay and the
  Activity view had no path to answer a decision or observe a frame; `InboundAnswer` is not
  `Hashable`, so the action enum cannot stay `Hashable` once it carries one. Rejected:
  exposing the process handle (breaks the single-holder rule); a separate answer protocol
  beside the API.
  Date/Author: 2026-09-05 / C4 plan review 2, ruling 5.
- Decision: `LiveBudget.run` reserves turns and projected wall time synchronously before
  awaiting the body and serialises callers through a continuation queue.
  Rationale: an actor method that awaits its body is reentrant; two scenarios could both
  pass the ceiling check before either accounted its turns. Rejected: a Task-local flag
  (does not survive the await).
  Date/Author: 2026-09-05 / C4 plan review 2, ruling 6.
- Decision: G5's consent scenario accepts the marker through the store-only accept before
  launch A; the allowlist scenario reads the witness while the child is live and after it
  ends, asserts the turn's actions from the channel's events, and its deliberate break
  removes `projects/`.
  Rationale: without the accept, Task 7's consent gate stops A at `.consentNeeded` and the
  marker never proves the engine's promotion; the child's own `sessions/` record exists only
  while it runs; a background shell writes under the engine's temp artifacts tree, not the
  config home, so `tasks/` could never be the discriminating demonstration. Rejected:
  bypassing the gate for the test (tests a path production never takes).
  Date/Author: 2026-09-05 / C4 plan review 2, ruling 7.
- Decision: the store's file-operations seam is `create`, `write`, `fsync`, `close`,
  `rename`, `fsyncDirectory`, `remove`; the config-home alias test uses a real symlink.
  Rationale: a whole-file `writeTemporary` could only fail before or after the payload,
  never after a partial write, which is the case atomicity exists for; a `/tmp` versus
  `/private/tmp` pair tests the platform's alias, not an arbitrary one. Rejected: faulting
  inside Darwin's write through a custom `FileHandle`.
  Date/Author: 2026-09-05 / C4 plan review 2, ruling 8.
- Decision: holder liveness compares the process start time with the record's `procStart`
  token within one second; the sixty-second `startedAt` window is the fallback only when the
  token is absent or unparseable, each fallback its own diagnostic.
  Rationale: the CLI writes `procStart` as the trimmed `ps -o lstart=` string under
  `LC_ALL=C TZ=UTC` (bundle 515820) and validates holders with it (12922/44087/44114); a
  one-second comparison on the same token is the reader's own rule, not a guess, and a wrong
  token inside the window is not a holder. Rejected: the window alone (accepts a reused pid
  whose record is fresh).
  Date/Author: 2026-09-05 / C4 plan review 2, ruling 9.
- Decision: after `awaitRelease` returns `.released`, `sendToBackground` and
  `openInTerminal` run the pre-spawn ownership check once more, immediately before `--bg
  --resume` and before the `PaneRequest` is built; a holder found there preempts the handoff
  (`handoffPreempted`, from ready and from dormant, to the holder's origin: foreign, job, or
  contended for an own pid) with the banner set and `LifecycleError.heldElsewhere` thrown.
  The window between a returned `PaneRequest` and the panel's spawn is accepted.
  Rationale: nothing looked at the session between the release and the launch, so a holder
  that appeared in that gap met a second writer; the recheck closes the gap FleetKit
  controls. The residual window is IPC latency: the panel spawns on receipt, and the hatched
  CLI's own post-handshake check is not ours to run. Rejected: a lease the panel returns
  before spawning (a protocol for a window measured in milliseconds).
  Date/Author: 2026-09-05 / C4 plan review 3, ruling 1.
- Decision: a fork stays `.connecting` until `.sessionIdentityResolved`: while `identity ==
  .awaitingFork` the handshake does not apply `handshakeClean` and the provisional-id
  ownership check is skipped; on the identity event the check runs against the resolved id,
  a holder takes the `connectingFoundHolder` rows, and a clean check rekeys the cap slot
  (`FleetCapCounter.rekey(provisional, to: id)`), re-indexes, and only then applies
  `handshakeClean` to `.ready`.
  Rationale: a fork that published ready on the handshake had no row for the collision
  (`handshakeFoundHolder` exists only from connecting, and the table records
  `transitionNotInTable`), and its slot stayed under a provisional key no release could
  name. Rejected: a `readyFoundHolder` row (a second collision path for one event).
  Date/Author: 2026-09-05 / C4 plan review 3, ruling 3.
- Decision: a dormant channel holds no cap slot and is never a cap victim; the `capReached`
  dormant row is deleted; recency for the victim is the counter's fleet-wide
  `activityClock`, stamped through `noteActivity(key)` on every send, engine frame and
  decision, not a per-supervisor sequence.
  Rationale: `reap()` releases the slot, so the row described the eviction of nothing and
  contradicted the counter's own accounting; only a wedged ghost keeps a count without a
  process. Per-supervisor sequences compared across supervisors ranked a channel by its own
  event count, so a channel that had received ten frames outranked one touched a moment ago.
  Rejected: keeping the row as a no-op transition (a scenario no test could drive honestly);
  `Date` comparison for recency (the package compares no instants).
  Date/Author: 2026-09-05 / C4 plan review 3, rulings 4 and 5.
- Decision: `answer(id, answer)` consumes the id before the write: `decisionGone` when it is
  not pending; the id removed and eligibility pushed; then `process.answer`. A failed write
  is recorded as `answerWriteFailed` and thrown as `LifecycleError.answerFailed(id,
  reason:)`, and the id is not restored; the scripted handle consumes on failure too.
  Rationale: `ClaudeProcess.answer` removes `pendingInbound[id]` before `writeAnswer`
  (ClaudeProcess.swift:396–399), so after a failed write every retry throws
  `unknownRequest`; keeping the id pending on our side left the channel ineligible for
  dormancy forever over a dialog the engine had already forgotten, and a failed write means
  the pipe is gone and an exit follows. Rejected: restoring the id on failure (mirrors
  nothing in ClaudeWire).
  Date/Author: 2026-09-05 / C4 plan review 3, ruling 6.
- Decision: jobs are listed and driven by short, not by session: `LifecycleAPI.jobs() ->
  [JobEntry]` and `performJob(_ verb: JobVerb, _ short:)` replace the `stopJob`,
  `respawnJob` and `removeJob` actions; `OriginResolver` classifies holders by
  `Holder.isJob` (a roster source or a job short) rather than by branch order; the live
  adoption scenario sends the adopted channel back to a job and stops it.
  Rationale: an exec job has no session, so a session-keyed `perform(on:)` could not name
  it, while the parent requires jobs listed, adopted and sent back; a conversation job's
  worker appears in both the registry and the roster, and branch order alone read it as a
  foreign terminal. Rejected: a synthetic session key for exec jobs (a channel with nothing
  to open).
  Date/Author: 2026-09-05 / C4 plan review 3, ruling 9.
- Decision: every live launch states its `--max-turns` cap per scenario (consent 1, adoption
  1, composed 12) through `budget.launch(_:maxTurns:)`; a `result` of subtype
  `error_max_turns` fails the scenario naming it; `claude --bg` receives `--max-turns`
  without a `--help` probe; the suite ceiling is four model turns.
  Rationale: `--max-turns` caps agentic turns inside one prompt and ends the turn with
  `error_max_turns` at the limit (bundle 36222 `turnCount`/`maxTurns`); it is not a prompt
  count, so a composed prompt with Bash, a subagent and a reply needs room, and a cap hit
  must fail rather than pass quietly. Bundle 824274's forwarded-flag set includes
  `--max-turns` for `--bg`, so the probe answered a settled question. Adoption and the
  composed prompt each reserve two turns because a resumed job may run one and the engine
  follows a background shell's completion with a turn of its own. Rejected: one cap for
  every launch (it either starves the composed prompt or lets a handshake-only launch run
  twelve turns).
  Date/Author: 2026-09-05 / C4 plan review 3, rulings 10 and 11.
- Decision: the cap counter's bounded quantity is `live + reserved - pendingEvictions`, not
  `live + reserved + wedged + pendingEvictions`, and `capDecision` carries `pendingEvictions`
  so the invariant can be asserted at every decision with no per-kind exception.
  Rationale: found in execution, when two evictions are pinned open at once. A pending
  eviction is not an extra occupant: it is precisely the slot that one outstanding
  reservation is waiting for, so counting both double-counts one slot and the naive sum
  reads seven at the moment a victim is named. The earlier formulation held only because no
  test pinned two evictions open simultaneously. Subtracting the pending evictions states
  what the counter actually enforces, so the cap tests assert the invariant itself rather
  than the weaker consequence "process-holding slots never exceed six". This is a child
  means, not a parent impact: the parent says only that six channels may be live and that a
  seventh spawn evicts the least recently used dormant-eligible channel, and both still hold.
  Rejected: asserting `live + reserved <= 6` on granted decisions only and tolerating seven
  on an evict decision (a per-kind exception that hides the one case worth watching).
  Date/Author: 2026-09-05 / C4 Task 5 review, architect ruling.
- Decision: `contendedSettled` enumerates six scenarios, not five; the sixth is
  `(.contended, .holdersSettled, .archivedOlder)`.
  Rationale: the parent's row is `| Contended | holder set settles to zero or one |
  re-evaluate | the matching origin |`, and an archived channel older than the recency
  cutoff is a matching origin, so the target was already inside the parent's wildcard; C4's
  concrete enumeration had under-covered it. Found in execution: deriving the settle target
  from the channel's own recency instead of hardcoding `archivedRecent` made the missing row
  reachable, and a refused transition left the channel contended with its banner already
  cleared and no way out. Two changes follow: the row exists, and `resolveContended` clears
  `banner` and `contendedFrom` only after `apply` returns true, so a refused transition
  leaves no partial state — the same discipline `handleExit` was given in Task 4. This is a
  child means, not a parent impact; the same under-enumeration pattern as
  `TerminatingAction.postHandshakeYield`.
  Rejected: hardcoding `archivedRecent` (it silently promotes an old channel's recency
  merely for having passed through Contended).
  Date/Author: 2026-09-05 / C4 Task 5 second review, architect ruling.
- Decision: `/logout` blocks, with nothing signed out, when any owned channel is wedged before
  the plan starts or wedges during it, or when an afleet-launched job is still listed in the
  roster after the removal wait; a refused `auth logout` is reported as `signOutFailed` with
  the exit and reason, never as success.
  Rationale: found in execution. A wedged channel is `.owned`, so a census that listed on
  origin alone took the ghost for an ordinary channel, and the terminate's sentinel return
  reported it as exited — `auth logout` then ran behind a live process, taking the token out
  from under it. The same fact holds for a roster worker that will not leave: it is a live
  process holding a token, so it earns the same answer rather than a softer one, which is
  also what the parent's §7.7 requires when it says success is reported only "when every
  listed process has exited". The block is checked twice, once at the census and once on each
  terminate's answer, because the two ask different questions — "should this plan start?" and
  "did a channel wedge while it ran?" — and a plan that cannot finish must not first run its
  irreversible stop phase (`interrupt`, `stop_task` per mirror id, `claude stop` per job).
  Rejected: a third success list for jobs that would not leave (it contradicts §7.7's sentence
  and reports a sign-out that did not happen); one guard rather than two (the stop phase's
  work is irreversible and would be done for a sign-out that never runs).
  Date/Author: 2026-09-05 / C4 Task 8 review, architect ruling.
- Decision: `holderAppeared` gains four scenarios from the two archived states, so an archived
  channel whose session a foreign holder claims becomes foreign live or a background job.
  Rationale: found by G5's live gate, which could never report a foreign interactive session at
  all. A registered channel starts `.archived`, and `holdersChanged` consulted `OriginResolver`
  only from `.dormant`, so an archived channel with a live foreign holder stayed archived for
  ever. That contradicts two sentences already in this spec — the origin rule ("*foreign live*
  when a live registry holder names the session id and is not our child") and G5's own
  acceptance sentence ("within five seconds the fleet reports a foreign live channel with the
  record's `status`") — so the concrete table had under-enumerated an origin rule the spec
  states generally. The same under-enumeration pattern as `TerminatingAction.postHandshakeYield`
  and `contendedSettled`'s sixth scenario, and a child means rather than a parent impact: the
  parent's §7.4 does not model an archived channel at all, and its origin rule is what C4 is
  implementing. Rule 1 does not fire on the way: it requires `desired == .owned`, which a
  channel that was registered but never opened does not have.
  Rejected: leaving detection to the facade by synthesising a channel outside the table (it puts
  a state change where the diagnostics and the coverage gate cannot see it).
  Date/Author: 2026-09-06 / C4 Task 10 live gate, G5 finding 2.
- Decision: the live suite's wall-time ceiling is twenty minutes, not ten, each scenario declares
  at least the sum of its own bounded waits, and the ceiling accumulates actual elapsed time
  rather than the declaration.
  Rationale: found by the Task 10 re-review. Wall time is not the scarce resource — model turns
  are, and `--max-turns` plus the four-turn ceiling bound those independently — but the ten-minute
  figure was tight enough to do harm in two directions at once. Declaring honestly pushed the five
  scenarios past ten minutes, so the composed scenario, the most valuable one and last in
  alphabetical order, would have been refused on admission after adoption had already spent its
  two turns; declaring optimistically meant the ceiling refused nothing at all, and once an
  overrun became a failure it meant a scenario that passed every substantive assertion could be
  reddened for being slow, with its turns already gone. Twenty minutes covers the observed actuals
  with room, and a declaration that is a fact about the code rather than a guess makes the overrun
  failure informative instead of arbitrary.
  Rejected: keeping ten minutes and shortening the scenarios' internal deadlines (it trades a
  budget problem for flakiness against a real engine under load); dropping the overrun failure and
  relying on accumulation alone (accumulation self-corrects the ceiling but says nothing about a
  scenario whose own waits have run away).
  Date/Author: 2026-09-06 / C4 Task 10 re-review.
- Decision: G5's adoption scenario makes its background job the way production does — open a
  channel owned, send one cheap prompt so a transcript exists, `sendToBackground`, then adopt it
  back — rather than creating the job with a `claude --bg` verb.
  Rationale: three recipes were tried against the installed CLI and each fell for its own reason,
  and the reasons are engine facts worth keeping. (1) `--bg --model haiku --max-turns 1 "pong"`:
  the job reached a terminal state 3.5 s after creation and `Fleet.jobs()`, which filters terminal
  records, never saw it. The cap looked like the cause. (2) A bare promptless `claude --bg`: it
  mints and carries its own session id, reaches no model, stays resident, and `jobs()` does list
  it — but `perform(.adopt)` resumes through afleet's own print-mode launch, and that refuses a
  session with no transcript. (3) The prompted recipe with the cap dropped: it ends 3.9 s after
  creation anyway. So the cap was never what ended it — **a background conversation job given a
  prompt is a one-shot runner that answers and exits, while a session handed to the daemon without
  a prompt stays resident idle until stopped.** Adoption targets resident jobs, so racing a CLI
  verb was testing a job the product model does not own; the earlier greens were a race won against
  a warm daemon. Building the job through the facade removes the timing window and exercises both
  parent-required verbs on a real conversation job in the order §7.4 describes.
  Two facts pinned against installed CLI **2.1.261** (the bundle authority is 2.1.258 and the
  fixtures 2.1.259; the 2.1.258 reading does not distinguish the two resume paths that 2.1.261
  clearly does): the residency rule above, and the three resume paths — `--bg --resume` by full
  uuid accepts a transcript-less session and keeps its id, by short id it starts a copy, and
  `-p --resume` refuses outright with "No conversation found with session ID", a `result` of
  subtype `error_during_execution`, `total_cost_usd` 0 and exit 1. A transcript is written when the
  prompt is **submitted**, not when the turn completes, which is why a fast adopt of a prompted job
  costs nothing.
  What the live gate bought, and the argument for having run it: four product defects, every one in
  shipped lifecycle code and every one invisible to a unit suite that was already 190 tests green —
  `52d7405` an archived channel never learning it had a foreign holder; `57f0233` a supervisor built
  after its holder already existed never hearing about it, which is the *ordinary* case once C5
  registers channels from C3's index; `ea72912` the daemon re-claiming a session's existing job
  short, so a "new short" filter rejected the one job the call was about and §7.4's own
  adopt-then-send-back round trip could never have completed; and `6c06209` our own dying child
  read as a stranger inside the release window, leaving a channel holding a job it could not show.
  Each has a CLI-free discriminating test with its break performed. Cumulative live spend to the
  point of this decision: `total_cost_usd 0.593697`, plus two sub-cent prompt turns the harness's
  own summing cannot see.
  Rejected: all three earlier recipes, on the evidence above.
  Date/Author: 2026-09-06 / C4 Task 10, settled after four live runs.

- Decision (**ruling 1**): a processless *owned* channel rests in **dormant**, always.
  Rationale: the parent's own words settle it — `ready` and `connecting` each assert a process,
  live or being launched, and `dormant` is "owned, no process, a send resumes it under the same
  id". There is one resting state for a processless owned channel and it is dormant, so the table
  gains a clean-exit row `(.readyExitedClean, .ready, .exitedClean, .dormant)`, the ready crash row
  retargets from ready to dormant, `(.exitedNonZero, .connecting, .exitedNonZero, .dormant)` joins
  the two exhaustion rows, and a spawn that does not complete restores the resting origin the
  channel left rather than parking it in connecting — the `adoptOrigin` idiom, no row of its own.
  `reopen()` acts on every processless owned channel whose system item offers *Reopen* and takes
  the send row of the resting state, which is the first read of `reopenOffered`. The table moves
  from 55 scenarios to **57** and G1's set-equality count moves with it.
  One deviation from the ruling's stated mechanism, found in execution and kept: the handshake
  catch restores only when this supervisor ended the epoch itself. `ClaudeProcess.processDidExit`
  settles the handshake waiter *before* it pushes `.exited`, so the catch always runs ahead of
  `handleExit`; an unconditional restore would leave the crash row with no candidate and make every
  handshake-phase crash a `transitionNotInTable` diagnostic. On every other failure an exit is on
  its way and `handleExit` owns the outcome, which reaches the same resting state through case 4.
  One residual violation was left open by the wave's worker 2 and closed by its worker 4, on the
  architect's ruling: a child that exits **cleanly** inside the post-handshake window left the
  channel connecting with no process, because `handleExit` takes `.exitedClean` only from ready and
  the finalisation's own guard returned with nothing but the rollback. Both post-handshake guards
  now call `restoreResting(ifEpochIs: mine)` beside the rollback. The guard inside `restoreResting`
  is what keeps this off the paths that do have an exit on their way: a parked respawn or a newer
  epoch refuses it. The invariant is the ruling's, so a known one-line violation of it does not
  survive the wave that establishes it.
  Rejected: patching each of the five findings where it was found (five different answers to one
  design question); leaving a wedged or crashed channel in ready with `process == nil`; leaving the
  clean-exit case open because the triage's wording for `scalpel-1#5` did not name it.
  Date/Author: 2026-09-06 / reconciling architect, executed by the fix wave's workers 1 and 4.

- Decision (**ruling 2**): one in-flight marker per channel — `inFlight: LifecycleOperation?` —
  and refusal, not queueing. Rationale: `spawning` and `handingOff` were two booleans covering two
  of eleven public entry points, and the alternative on the table was a FIFO lease across a
  1,483-line actor. Nothing waits on a marker, so nothing can deadlock; and the product semantics
  want refusal (a double-click on *Send to background*) or merge (two restart-required changes),
  never a queued second handoff. The marker is set synchronously after each entry's pure guards
  and cleared by `defer`; a second entrant throws `LifecycleError.busy(operation)`. Two exceptions
  keep today's behaviour: `send` behind a spawn queues, because the channel is connecting and
  queueing is what the user means there, and `quiescentRestart` behind a restart merges into
  `pendingChange`. `answer` and `perform(controlRequest)` are exempt: they mutate no lifecycle
  state. `deliver` now sets `turnRunning` before `await handle.send`, which with the eviction, the
  reap and the restart all taking the marker before their eligibility check closes both halves of
  the eligibility-to-termination window.
  Rejected: the FIFO lease (a structural change at the merge gate, and a boundary taken in the
  wrong place deadlocks the fleet); leaving the comment at `ChannelSupervisor.swift:346-347`
  promising a serialisation nothing implemented.
  Date/Author: 2026-09-06 / reconciling architect, executed by the fix wave's worker 1.

- Decision (**ruling 3**): `/rewind` sends `rewind_conversation` **first**, and
  `rewind_files {dry_run: false}` only on `rewound: true` and only when the user asked for the
  files as well. Rationale: as shipped, an ordinary `/rewind` reverted the user's working tree and
  then had the conversation rewind refused, leaving the two halves inconsistent with no signal —
  `rewind_conversation` honours only a target the running process itself sent, which after a reopen
  is every earlier message, and it refuses with `rewound: false` and a body-level `error` inside a
  *success* envelope. The reorder is safe on an engine fact rather than on hope: `rewind_files`
  resolves its checkpoint through `fileHistory` keyed by the user message id
  (`Oze(n.fileHistory, id)`, then `Pze(...)`, 2.1.258 `cli.pretty.js:153445-153460`) and never
  through the message array, so the checkpoint outlives the conversation rewind. On a refusal the
  engine's `error` string is surfaced and *Fork from here* is offered exactly as parent §8.5 and
  item 13 design it; on success `skippedLinks` is surfaced rather than reporting a clean revert.
  The confirmation sheet answers `RewindChoice` — cancel, conversation only, or conversation and
  files — because the two rewinds are independent and the engine's own `/rewind` offers the same
  three.
  Rejected: keeping the shipped order (it modifies the working tree on the ordinary path);
  supplying `last_seen_user_message_uuid`, which the finding asked for on a premise the bundle
  refutes — the field is optional, and the refusal design is the parent's, not this child's.
  Date/Author: 2026-09-06 / reconciling architect, executed by the fix wave's worker 3.

- Decision (**ruling 4**): the restart readback reads the key names of `get_settings.effective`,
  and the shape is fixed at its source rather than worked around here. Rationale: the redactor
  replaced the whole `effective` field before anything reached disk, so no recording carried the
  engine's answer and every restart test scripted a synthesised `effective_keys` and called it "the
  recorded shape" — a green suite over an unproven path. The corrective landed on `main` first:
  both redactors keep `effective` as an object with its keys and every value `"<redacted>"`, and
  `sources` as `[{source, settings: {key: "<redacted>"}}]`; `control-shapes` and `zero-cost` were
  migrated and independently re-signed; C4 merged `main` before Group E. In C4:
  `ReadbackSource.getSettingsEffectiveKeys` becomes `.getSettingsEffective`, every scripted
  `get_settings` answer builds the live shape, and `snapshot.model` resolves through the
  handshake's `models[].{value, resolvedModel}` table before comparing with `applied.model`.
  Rejected: fixing the reader against the bundle alone and leaving the fixtures as they were.
  Date/Author: 2026-09-06 / reconciling architect, cross-child with C1 and C2.

- Decision (**ruling 5**): the task mirror is wired per channel in this child, not deferred.
  Rationale: an unwired mirror means the thirty-minute reap, the cap eviction and `/logout` cannot
  see a running background shell — the exact loss parent §7.4's dormant-eligibility paragraph
  exists to prevent — and that is not debt to carry across a merge. The inputs are wire frames the
  supervisor already pumps and Task 11's `MirrorFold` rig already shows the fold: `Fleet.build`
  gives each supervisor a `RegistryMirror` fed from its own pump through C3's `apply(_:at:epoch:)`,
  `eligibilityInputs` reads the live mirror and its `lastFrameAt`, and `liveTaskIDs()` reads the
  same mirror at the moment *Stop* executes rather than replaying census-time ids.
  As executed: the fold is `ChannelTaskMirror`, one per channel, built in `Fleet.build` and written
  by the supervisor's own `handle(event:)` — the five task subtypes through C3's
  `apply(_:at:epoch:)` and `tool_progress` through its heartbeat fold. It is read back by the same
  closure `Fleet.build` hands the supervisor, so `eligibilityInputs`, `liveTaskIDs()`, the
  thirty-minute reap, the cap eviction and `perform(.reap)` all read one object as of the moment
  each of them asks. A frame that touched a task row pushes the verdict; nothing else does.
  Two facts had to be settled in execution. **The age is stamped on the injected clock.** C3's
  `lastFrameAt` is a wall-clock `Date` and this child's lifecycle runs on an injected
  `any Clock<Duration>`, so an age derived from `Date()` would be a quantity no manual clock can
  move and every test of the heartbeat rule would have to sleep on wall time. Each folded frame
  therefore also takes a `ClockStamp` — an instant captured inside a generic function and handed
  back as a `@Sendable () -> Duration`, because `any Clock<Duration>` cannot surface its `Instant`
  — and `lastTaskFrameAge` is that stamp's age, read when it is asked for. C3's `Date` still stamps
  the rows, which is what `evictable(asOf:)` and every row time mean. **The mirror is forgotten
  when the child exits.** A background shell is a child of the engine's process and dies with it,
  while a row nobody notifies is live for ever, so a mirror carried across an exit would leave the
  channel unreapable and un-evictable on a fact that stopped being true; `handleExit` resets it
  beside `unresolvedSettings`.
  Rejected: carrying it as tracker debt behind a stand-in mirror; a second subscription to
  `events()` from the facade (the supervisor's pump is already the one place every frame passes,
  and a subscription taken after `build` can miss the frames of a spawn that has already started);
  comparing `Date()` against C3's stamp.
  Date/Author: 2026-09-06 / reconciling architect, executed by the fix wave's worker 4.

- Decision: a spawn composes every launch field from the runtime record **except `agent`**.
  Rationale: Group D's rule is that `--resume` restores the conversation and nothing else, so a
  `/model`, a `/permissions`, an `/effort`, a `/cd` or an `/add-dir` has to be put back on the
  command line of every child this channel launches. `agent` is the one field that must not be:
  re-passing `--agent` replays the agent's `initialPrompt` as a user turn (parent §7.4), which is
  why the quiescent restart clears it — and composing it from `runtime.agent`, which still holds
  the name for the header, would put the flag back on the very next respawn after a restart. The
  triage's "compose from the runtime record" reads as unconditional; it is not.
  Rejected: composing `agent` with the rest and clearing it again in the restart's own override
  (two writers of one field, and every non-restart spawn would still replay the prompt); dropping
  `runtime.agent` so nothing can compose it (the header names the agent a channel is running).
  Date/Author: 2026-09-06 / fix wave's worker 2, recorded by worker 4.

- Decision: the live budget rises from four short turns to **five**, and the fifth buys an eighth
  scenario, "restart readback".
  Rationale: the whole-branch review's closing paragraph named the pattern — the suite is green
  because the stand-ins agree with the code rather than with the engine — and the restart readback
  is where that pattern cost the most: the reader, the fixtures and every test agreed on a shape the
  engine does not send. One `--max-turns 1` turn gives the scenario a transcript; `/model` to a
  second alias and `/add-dir <scratch directory>` make a quiescent restart run; the scenario asserts
  `.ready` with no `settingDidNotSurvive` banner, the relaunch argv, and that `effective` arrives as
  an object. Five short `haiku` turns remain far inside the twenty-minute wall declaration, which is
  derived the same way as the others.
  Rejected: witnessing the shape from the migrated fixtures alone (they are the thing under
  suspicion); leaving the ceiling at four and folding the assertion into the composed scenario,
  which would couple two independent failures into one turn.
  Date/Author: 2026-09-06 / reconciling architect.

## Surprises & Discoveries

- Observation: `fake-claude` emulates no CLI verb. Evidence: `Tools/fake-claude/fake_claude.py`
  handles `materialize`, `--version`, `--help` and replay only. Impact: C4's verbs get a
  scripted `ProcessRunner`; G1's "scripted registry and roster files" in the parent are
  files plus a scripted runner.
- Observation: the corpus contains no `session_state_changed` frame. Evidence:
  `grep` over `Fixtures/*/frames.ndjson`. Impact: owned presence is derived locally; the
  frame is recorded when seen.
- Observation: `claude agents --json` lists registry sessions that have no job, including
  afleet's own headless children, as `kind: "interactive"` rows. Evidence: bundle
  `printAgentsJson` (2.1.258). Impact: the three reads are reconciled by pid, and a child of
  ours appearing in the listing is not a foreign holder.
- Observation: every project entry in the scratch `.claude.json` carries
  `enabledMcpjsonServers` and `disabledMcpjsonServers` arrays, and the engine never reads
  them for consent. Evidence: read-only inspection of
  `/tmp/afleet-fixtures/config-home/.claude.json`; bundle 2.1.257, the consent function
  (chunk `1kg58a1a`, pretty 94640–94682) reading the merged settings, and the startup
  migration (pretty 503739–503785) that empties the arrays into local settings; C1's spike,
  where the arrays stay empty across a decline. Impact: v2's two-location rule is withdrawn;
  consent is computed from settings only.
- Observation: a zero-turn headless launch emits no `result` frame, so `total_cost_usd`
  cannot be read from the stream for a handshake-only scenario. Evidence: the `zero-cost`
  fixture has no `result` frame and answers `get_session_cost` with `total_cost_usd: 0`.
  Impact: every zero-cost scenario asks `get_session_cost` before ending its process; the
  spike's `lastCost` in the project entry is corroboration, not the witness.
- Observation: the corpus records `rewind_files {dry_run: true}` answering `{canRewind,
  filesChanged, insertions, deletions}`, `rewind_conversation` answering `{rewound,
  targetMessageUuid, prefillText, precedingAssistantUuid}`, `claude_authenticate` answering
  `{manualUrl, automaticUrl}` and `claude_oauth_wait_for_completion` answering only the
  "No active claude_authenticate flow" error (`control-shapes`); `mcp_status` and
  `get_context_usage` answer in `zero-cost`. Impact: the router's multi-step strategies are
  fixture-backed to those points and scripted past them.
- Observation: `jobs/<short>/state.json` carries `resumeSessionId`. Evidence: the three
  stopped S12 jobs in the scratch home. Impact: send-to-background finds its new job without
  parsing `--bg`'s stderr note.

- Observation: the §6.12 writer's config-home containment check must run on the *store
  directory's* descriptor, not only on the project root's. Evidence: found by the Task 7
  review, which demonstrated it by running a probe. With `CLAUDE_CONFIG_DIR=<project>/.claude`
  the project root is not under the config home, so a root-only check passes and `decline`
  writes `<configHome>/settings.local.json` — a write into a Claude Code config home, the one
  rule the child is organised around. The execution plan's step 2 asked for the check on the
  root alone, and the test that claimed to cover the case built the project *inside* the
  config home instead, which is the opposite arrangement and the one the root check already
  catches. Impact: the containment predicate now runs additionally on the `F_GETPATH` of the
  `.claude` directory descriptor and of the staging directory descriptor, after each is
  opened and `fstat`ed, so the discipline "never a string computed before the open" is kept;
  both arrangements have their own named test. The lesson generalises past this instance: a
  containment check belongs on every descriptor a write can reach, not only on the one the
  path resolution started from.

## Outcomes & Retrospective

C4 is built. `FleetSessions` carries the namespaced store, the X5 value types, the lifecycle
table as data, the channel supervisor with its ownership checks and cap counter, the handoffs
and the terminal hatch, the quiescent restart and forking, the spawn preconditions with the one
permitted project write, the command router and `/logout`, the Activity query, C3's
`IndexStorage`, and the `Fleet` facade that C5, C6 and C7 call. The package builds clean at
**415 tests, 10 skipped, 0 failures, zero warnings**.

**Gates.** G1 passes, with a coverage gate proving all **58** lifecycle scenarios have a
declaring test — a reviewer reproduced each of its three failure modes independently. G2 passes
against C3's real registry mirror, five boundary cases agreeing case for case with the stand-in.
G3 and G4 pass. G5 has **all eight scenarios green together** against the installed CLI,
twice — the eighth, the restart readback, has now met an engine and is what proves ruling 4's
`effective_keys` corrective.

**The merge-evidence runs, 2026-09-06, against installed CLI 2.1.263.** Run five times. The CLI
auto-updated from 2.1.261 to 2.1.263 between the child's earlier live work and these runs; the
2.1.263 bundle is extracted and every engine fact this document cites holds there. The first four
failures across runs one to three had four causes, all now named and none of them the engine
being slow.

| run | at | verdict | wall | turns | spend |
| --- | --- | --- | --- | --- | --- |
| 1 | pre-`66b3832` | five of eight | — | 5 of 5 | — |
| 2 | pre-`66b3832` | six of eight | 246.464 s | 5 of 5 | 0.248624 |
| 3 | `66b3832` | seven of eight | 240.628 s | 5 of 5 | 0.173372 |
| 4 | `aa8d791` | **eight of eight** | 136.568 s | 5 of 5 | 0.170528 |
| 5 | `883860f` | **eight of eight** | 132.279 s | 5 of 5 | 0.185419 |

Run 4 is the merge evidence. Run 5 is the tip's own witness, taken after the mutation budget came
down to thirty seconds, so the gate has been measured at the budgets that ship.

*Run 5, at the tip:*

| scenario | verdict | wall |
| --- | --- | --- |
| declined project server (G3's engine proof) | passed | 19.841 s |
| adopting a conversation job and sending it back | passed | 26.772 s |
| foreign interactive session detected and archived | passed | 3.589 s |
| exec job listed and stopped | passed | 5.129 s |
| quiescent restart, the engine reads its settings back | passed | 22.785 s |
| the allowlist names nothing the engine is not known to write | passed | 0.018 s |
| the write allowlist across hooks, a background shell, a subagent and relocation | passed | 53.895 s |
| two overlapping scenarios, atomic accounting | passed | 0.249 s |

`Executed 8 tests, with 0 failures in 132.279 seconds`, and
`budget.summary: turns used 5 of 5; total_cost_usd 0.185419; wall time 130.318 s of 1200.0;
launches decorated 14, bypassed 0`.

**The four causes, none of them a guess.**

1. **The browser-flow login never completes onboarding.** `claude auth login` stores credentials
   but does not set `hasCompletedOnboarding`, so run 1's interactive child sat on the theme
   picker and never reached its registry write. Completing the wizard interactively moved the
   foreign-session scenario from failing at 42.3 s to passing at **3.332 s**, comfortably inside
   G5's five-second detection claim, and it holds at 3.589 s at the tip. Environmental, not a
   product defect, but it is a precondition the gate depends on and C5 should expect it too.
2. **The transient daemon's first-ever start in a fresh home**, roughly sixty seconds on run 1.
   Also environmental, and it does not recur once the home has been used: the 2.1.263 daemon
   exits five idle seconds after its last client and boots again in about 0.3 s.
3. **The observer consumed adopt's own release.** `adopt()` runs `claude stop <short>` and waits
   for the job's holder to disappear, and `holdersChanged` archives on exactly that
   disappearance, taking `.backgroundJob` — the only from-state `.adopt` has — away between the
   wait and the transition. `adopt()` then returned having spawned nothing and thrown nothing:
   §7.4's round trip silently did not happen, and the caller was handed a channel resting
   archived. Fixed in `66b3832` by giving the record-disappeared branch the same `inFlight == nil`
   guard rule 1 already carried; the observer's own poll re-drives the archive once the operation
   has finished. `LifecycleRowTests.testAdoptSurvivesAHolderPollLandingOnTheJobsOwnRelease` drives
   the poll deterministically through `OwnershipCheck`'s `onReleased` seam. The scenario went
   46.020 s failing to 32.333 s passing.
4. **The runner learned a child's exit on a starved dispatch worker.** `ProcessRunner` called
   Foundation's `waitUntilExit()` from a block on `DispatchQueue.global()`, which does not
   overcommit. A live suite of eight scenarios driving pty children fills that pool, the block
   never runs, the exit is never observed, and the verb is failed by its own timer long after the
   child has exited successfully — reported as `exitCode: -1`. The daemon log of run 3 settles
   it: job `78a58ac5` spawned at 08:31:38.787 and `settled (killed)` at 08:31:39.873, so the
   spawn, the listing and the stop all finished inside 1.1 s, every client had disconnected by
   08:31:39.9, and the daemon logged nothing for the remaining eighty-nine seconds of a 94.781 s
   failure. Fixed in `aa8d791` by taking the exit from `process.terminationHandler`, which needs
   no thread of ours and cannot be starved;
   `testTheChildsExitIsSeenEvenWithEveryDispatchWorkerBlocked` holds the pool deliberately and
   measures 7.06 s with a false failure before against 0.005 s and exit 0 after. A second latent
   defect found on the way — settlement waiting for end-of-file on the pipes, which a surviving
   grandchild holds open — is fixed in `fdb4446`. Both live in the process runner every verb
   shares, so this is a C2 corrective this branch carries.

**A correction this document owes its reader.** Runs 1 and 2 were read at the time as tracker
entry 27, a cold or contended daemon, and the mutation budget was raised from twenty seconds to
ninety on that reading. Run 3 falsified it: the same scenario failed the same way at the new
ceiling, which is what a budget that was never the constraint looks like. Entry 27's seventy
seconds was cause 4, not contention. With cause 4 fixed the mutation budget is **thirty seconds**
against measurements of about one — `--bg --exec` 1.1 s, `stop` 0.70 s, `rm` 0.7 s from a shell,
and 5.129 s for the whole spawn-list-stop-confirm scenario with a cold daemon inside it — and
reads stay at twenty. The split itself stands on its own reasoning: a read that hangs costs a
stale listing, while a mutation abandoned mid-request leaves the daemon honouring a change afleet
has already given up on, which is precisely what run 2 recorded when a twenty-second `stop` was
SIGTERMed two seconds before the daemon logged `settled (killed)`.

What the runs establish beyond the eight verdicts:

- **The eighth scenario passes.** It reports `get_settings keys ["applied", "effective",
  "sources"]; effective is an object` — the live witness that ruling 4's corrective was right and
  that `effective_keys` was a redactor artifact. That is the one class of defect a fixture-driven
  suite structurally cannot catch.
- **The write-allowlist claim holds**, across a hook, a background shell, a subagent and a
  relocation, with both witness readings explained, and the deliberate narrowing still
  discriminates (`without projects/ the final reading leaves 3 path(s) unexplained`).
- **Both zero-cost launches read zero** on every run, and every launch was decorated with none
  bypassed — 14 of 14 on runs 4 and 5 — so no child escaped its turn cap.
- Two delegated unknowns are answered: an exec job **does** carry a session id on 2.1.263, and
  `mcp_status` reports a rejected project server by omitting it rather than listing it with a
  status word.

Cumulative measured live spend across the whole child is `total_cost_usd 1.576469` over five
runs, plus two sub-cent prompt turns the harness could not see because they ran on `--bg` jobs
rather than on an observed channel. No run exceeded five turns or came near the twenty-minute
wall ceiling; the longest was 244.3 s.

**Previously unwitnessed, now witnessed:** the eight green *together*, twice, at
`aa8d791` and again at the tip.

**What the live gate bought, and why it was worth its cost.** Four product defects, every one in
shipped lifecycle code and every one invisible to a unit suite that was already 190 tests green:
an archived channel never learning it had a foreign holder; a supervisor built after its holder
already existed never hearing about it, which is the *ordinary* case once C5 registers channels
from C3's index; the daemon re-claiming a session's existing job short, which made §7.4's own
adopt-then-send-back round trip impossible; and our own dying child read as a stranger inside
the release window, leaving a channel holding a job it could not show. It also settled engine
facts no fixture records — that a background conversation job given a prompt is a one-shot
runner while a promptless one stays resident, that a transcript is written when the prompt is
submitted rather than when the turn completes, and that the three `--resume` paths differ.

**What the whole-branch reviews bought.** Three rounds, and the shape of them is the lesson. The
first found **48** confirmed findings on a suite that was green: triage kept **33**, logged
**12**, scoped out **3**, and refuted **0**. Five architect rulings and four workers landed
them. The second review, over the fix diff alone, found **10** — four Criticals forming three
fixes, one of which had been ruled fixable in round one and fell between two workers. The third
round fixed all three and found nothing new. The sharpest single finding was that
`effective_keys` existed only because the fixture redactor synthesised it: against a real engine
every restart carrying a flag setting would have falsely reported the setting lost, and no
fixture-driven test could have caught it, because the fixtures were the thing at fault.

**The retrospective, in one sentence.** The defects clustered where a unit suite cannot reach —
what happens when a child exits during an `await`, what a relaunch carries that a restart does
not, and what the engine actually answers — and the suite was green because the stand-ins agreed
with the code rather than with the engine. Three practices earned their keep against that: the
discriminating-test rule, which made every fix show its own failure first; recording engine facts
against a pinned CLI version with the bundle offset beside them; and running the live gate at all,
which is the only reason the redactor artifact was ever found.


## Revision Notes

- 2026-09-08 corrective on `main` from C6.2's `[parent-impact]`: X5 gains `quit` and
  `liveTaskIDs(of:)`. Parent §7.4's *Quit* clause — terminate every owned channel that has a
  process, then `Fleet.shutdown()`, then exit — was added at C5's merge, after C4's FleetKit
  had merged, so the facade never received the verb: the only terminate it exposed was
  `perform(.reap)`, whose dormant-eligibility gate refuses precisely the busy channels a quit
  dialog has just warned about, and a literal implementation of the clause would have
  terminated nothing. `LifecycleAction.quit` runs `ChannelSupervisor.terminateForQuit()`,
  which is the bare `endProcess(during: .quit)` — no gate, and no `inFlight` guard, because a
  quit must end a channel whose spawn or restart is mid-flight too — and `.quit` joins
  `LifecycleTable.TerminatingAction` with the restart's and logout's from-states, ready and
  connecting, so a ghost the quit leaves behind is recorded under the action that left it. It
  is not a typed command: `LifecycleActionName` is unchanged and the host's quit path is the
  only caller. `liveTaskIDs(of:)` answers the channel's running-or-armed background task ids,
  `[]` for an unknown key, because §7.4's "busy" is the fleet's own fact: a surface reads
  `presence` and this rather than a count it kept locally, so a channel that was spawned but
  never viewed is judged the same as one on screen.

- 2026-09-08: `LifecycleAPI` gains `sendPrompt(_:on:)`, answering the uuid the engine will echo
  for the user message. `ChannelSupervisor.send` has always minted and returned it and
  `perform(.send)` has always discarded it, so the composer had no way to raise
  `HostSignal.promptSent(uuid:at:)` before the echo arrived — C3's `StreamIngestion.signal(_:)`
  had a receiver and no sender — and reaching below the facade for the supervisor is contract
  Y5's refusal. What was discarded is the idea of widening `perform`'s return into a richer
  result: `perform` is one door over eleven actions whose answer is the channel's state, and
  paying every caller of every action for one action's extra fact is the wrong trade, so the
  prompt gets its own member on the same path — same barrier check, same supervisor call, same
  `busy` and `heldElsewhere` refusals — and `perform(.send)` is left exactly as it was.

- 2026-09-08: `RouterTable`'s terminal-only copy ended with "Open this session in your
  terminal to use it." — the one sentence parent §7.7 says the router never shows — and
  `RefusalInterceptor` reused it verbatim on the drift path, where §7.7 asks instead for what
  the command does here or why it is absent. Worse, the engine has **two** refusal sentences,
  not one: 2.1.263 `cli.pretty.js:540254` builds the bare `/<name> isn't available in this
  environment.` that `bareRefusalPattern` matches (*A-28*), while `cli.pretty.js:540305` builds
  `/<name> opens an interactive panel and isn't available in this environment. Run it from the
  Claude Code terminal instead.` for a command whose UX is a full-screen panel — anchored at
  both ends, the pattern missed it, so that whole class reached the channel unintercepted,
  uncounted, and carrying the forbidden instruction (C6.2's `[parent-impact]` filing against
  X10). The table now carries a per-command reason for each name the recorded
  `terminal_slash_commands` lists and a clean fallback for the rest, a separate
  `explanation(forDrift:shape:)` that prefers the local row's own explanation, and
  `interactivePanelRefusalPattern` beside the bare one; the interceptor matches both, replaces
  both and counts them apart under a `RefusalShape` the drift log records as `refusal_shape`.
  `RouterTests` scans every text the table can produce for the forbidden shapes and pins both
  interceptions — the panel half failed first, returning nil with the drift count at zero.

- 2026-09-07: `Fleet.fanOut` hands every published `HolderSet` to every supervisor, and
  `ChannelSupervisor.holdersChanged` narrowed the set to its own session, wrote `state.observed`
  and then published on every path where no transition applied. One holder change anywhere
  therefore cost one published `ChannelState` per registered channel, for the life of the
  process. C5 measured it against a real config home: 13,250 published states across 2,671
  sessions on one launch, none of them a repeat, 99.8% of them for channels whose narrowed
  holder view had not changed at all (its tracker entry 60). `updates` is "every transition,
  coalesced per channel", and a state whose only difference is a fresh `observed.observedAt` is
  not a transition — C6 subscribes to the same stream and has none of the sidebar's coalescing.
  The rule now enforced: a supervisor publishes on a holder set only when its own narrowed view
  changed (compared as a `Set<Holder>`, ignoring the stamp) or a transition was taken. Every
  transition still publishes through `apply`, every evaluation in the method still runs on every
  call — the suppressed archive depends on the next tick re-evaluating — and `state.observed` is
  still written on every call, stamp included. `fanOut` still walks every supervisor; the walk is
  a filter per supervisor and was never the cost. `HolderFanOutTests` pins both halves: a holder
  change on A's session publishes nothing on B, and the same set read twice publishes once. The
  seeding half of C5's entry 60 — a channel publishing each intermediate step of its own
  seeding — remains open there.

- 2026-09-07: `TrustReader.isTrusted` read `<configHome>/.claude.json`, but the engine resolves
  that document as `join(CLAUDE_CONFIG_DIR ?? homedir(), ".claude.json")` (2.1.263
  `cli.pretty.js:298330`) while the config home is `CLAUDE_CONFIG_DIR ?? join(homedir(),
  ".claude")` (`:298581`) — two different expressions, coinciding only when the variable is set.
  On an ordinary installation the document is therefore `~/.claude.json`, the home's *sibling*,
  and `<configHome>/.claude.json` names a file the engine never reads: every project resolved
  untrusted and no channel could spawn owned. The reader now takes the document location
  (`isTrusted(root:globalConfig:)`) and `SpawnPreconditions.evaluate` takes the launch's
  `ConfigHome` and derives it through `ConfigHome.globalConfig`; `ManagedSettingsReader` and the
  consent resolver still take `key.configHome`, which is a bare root and genuinely names the
  home. C5 found it (its tracker entry 59). No test could see it because every home a test
  builds is environment-shaped, so the two spellings coincided; the new default-shaped case in
  `PreconditionTests` — a temporary stand-in for `HOME` with `.claude/` as the root and
  `.claude.json` beside it — was red at `.untrusted` before the fix and `.ready` after.

- 2026-09-07: G5's trusted-directory selector excluded the config home by comparing paths
  canonicalised with `resolvingSymlinksInPath()`, which resolves `/private/tmp/X` back to
  `/tmp/X` only when `X` exists. A trust entry naming a not-yet-created directory beneath the
  scratch home therefore kept its `/private/tmp` spelling while the home itself lost it, no
  prefix matched, and the exclusion failed open on exactly the path it exists to refuse — the
  live suite would have created a directory inside a config home. C5 found it through its own
  port's test (C5 tracker entry 69) and fixed its copy by canonicalising through `realpath(3)`
  over the longest existing prefix with the missing components put back; the same helper is now
  local to `Support/LiveGate.swift`, and the selector is extracted there as
  `trustedDirectories(inDocument:underRoot:excluding:)` with `LiveGateTrustSelectorTests`
  pinning it — red at two candidates before the fix, green at one after. It was never exploited:
  no fixture trust entry has ever named such a path.

- 2026-09-07: `FileFleetDiagnostics` held one `FileHandle` open for the sink's whole life and
  tracked its own offset, the same fault C2's `FileDiagnostics` carried and fixed in the same
  commit. The app's *Delete diagnostics* unlinks `fleet.log`, and `Fleet` builds this sink
  internally from the diagnostics directory it is handed, so the app cannot reach it to
  reopen: it kept appending to an unlinked inode until the next relaunch and the user's
  following diagnostics were lost to a file with no name. C5 found it. Closed in `c31bebd`:
  each write opens the log `O_WRONLY | O_APPEND | O_CREAT` at mode 0600, writes the line and
  closes, so a deleted log is recreated by the next record; a missing directory is recreated
  on one retry. `flush()` still means `synchronize()`, now on the file the written lines went
  to. The single-writer rotation into `fleet.log.1` is unchanged except that its size check
  reads the file's current size, the offset having gone with the handle. No public signature
  changed, so no facade or supervisor call site moved. The discriminating test — record,
  unlink, record, assert the log is back holding exactly the second line — was written red
  first.

- 2026-09-06, after the merge: the router had no door on the facade. `CommandRouter.route` and
  `StrategyExecutor.send`/`.run` all take a `ChannelSupervisor`, which `Fleet` owns and never
  hands out, so a surface holding a `ChannelKey` — which is all C6's composer holds — could not
  route a slash command or execute what a routed line named. C5 found it while inventorying the
  API; C6 would have hit it on its first slash command. Nothing failed at the time because the
  router tests drive the executor on a supervisor they build themselves. Closed in `ace7a7b` by
  three operations on `Fleet` and on `LifecycleAPI`, each resolving the key the way
  `perform(_:on:)` does and delegating: `route(_ text: String, on: ChannelKey) async -> Routed`,
  `send(_ request: AnyControlRequest, on: ChannelKey) async throws -> JSONValue` and
  `run(_ strategy: RouteStrategy, arguments: [String], on: ChannelKey, ui: any StrategyUI) async
  throws -> StrategyOutcome`. No routing logic is re-implemented and no state is kept twice.
  `send` and `run` refuse an unregistered key with `LifecycleError.notOwned`; `route` is a pure
  function of the line, so an unregistered key resolves against the local table alone. One field
  was added under them, deliberately: `ChannelSupervisor` kept the newest handshake and the
  runtime record but dropped each `system/init` after reading `apiKeySource` off it, and
  `terminal_slash_commands` lives only there — without it §7.7's second resolution step is dead
  through the facade and a command the engine says belongs to its terminal interface would be
  sent for the engine to refuse. The report is now kept beside `lastHandshake` and handed out,
  with the other two, by `routingContext()`.

- 2026-09-06, later: the merge-evidence runs closed out at **eight of eight, twice**, and two
  product defects were found by running them that no unit suite had reached. Runs 1 and 2 were
  read at the time as tracker entry 27 — a cold or contended daemon — and the mutation budget was
  raised to ninety seconds on that reading. Run 3 falsified it by failing the same scenario the
  same way at the new ceiling. The real causes were the observer archiving a channel on the very
  release `adopt()` was waiting for, which made §7.4's round trip a silent no-op (`66b3832`), and
  `ProcessRunner` learning a child's exit from `waitUntilExit()` on the non-overcommitting global
  dispatch queue, so a loaded suite starved the pool and failed verbs whose children had already
  succeeded (`aa8d791`, with the end-of-file settlement defect found alongside it in `fdb4446` —
  both C2 correctives this branch carries). The mutation budget came down to thirty seconds on
  the corrected measurements (`883860f`) and run 5 re-measured the gate at the budgets that ship.
  The lesson worth carrying to C5: a timeout is a symptom, and widening one that then fails at
  the new boundary is evidence that the waiting party is not waiting on what you think.

- 2026-09-06: the whole-branch review rounds, after the twelve tasks were complete and green.
  Round one, a Codex code-review panel over `main..HEAD` (77 files, 17,004 insertions; one native
  sweep, five derived scalpel lenses, one binding verifier): verdict `incorrect`, **48**
  verifier-confirmed findings, 33 at P1. Triage bucketed them **33 fix-now / 12 tech debt / 3 out
  of scope / 0 wrong** — zero refutations after a deliberate hunt for them, because where a
  finding failed it failed on scope or severity, never on the facts. The architect issued five
  rulings (the resting state of a processless owned channel; one in-flight marker rather than a
  FIFO lease; the rewind order; the redactor corrective and the eighth live scenario; wiring the
  task mirror per channel), and a four-worker fix wave landed them. Round two, the same panel over
  the fix diff (`--base 4f2102d`): **10** findings, four Criticals forming **three** fixes — the
  logout barrier on background handoffs, which had been ruled fixable in round one and was dropped
  between two workers, and two instances of "the last await is not the last guard", closed by one
  shared helper. Round three fixed all **three** and raised nothing new. The wave is eight commits
  on this branch — `5612fa8`, the merge `c8ffae4`, `83bd61e`, `7cdcbb8`, `26eeee9`, `732ef10`,
  `8723846`, `8aac7a9` — and the merge brought two more from `main`, C1/C2's redactor corrective
  `2b06be9` and its fixture re-signing `0733c8c`. Tracker entries 26 through 46 are C4's, with 29
  closed by ruling 2. One note for the record: the coordinator's summary counted eleven fix-wave
  commits; the branch carries eight of C4's own plus the two inherited through the merge.

- 2026-09-05: v1, written at dispatch against parent commit `ee94449`.
- 2026-09-05: v1 amended the same day, before any plan, with the coordinator's flow-back
  from C7's decomposing run as design inheritance: X5's pane protocol (`PaneRequest`,
  `PaneExit`, `openInTerminal`, `attach`, `logs`, `paneExited`; `stop`, `respawn`, `rm` as
  verb actions) and X6's dotted keys with a per-namespace schema version, including
  Workbench's two key shapes. The parent's amended X5 and X6 text is the authority; this
  document's lineage check at recomposition compares against it.
- 2026-09-05: v2 at acceptance, from the coordinator's rulings. The three questions are
  answered as recorded above. `claude agents --json` leaves the five-second poll and runs at
  the pre-spawn check, adopt, send-to-background, the `/logout` census and a sixty-second
  reconciliation. A wedged channel is excluded from dormant eligibility and from cap
  eviction, and both rules read the trace. Project MCP consent is computed read-only from
  both the local-settings store and the project entry in `.claude.json`, written only
  through §6.12; a C1 probe will record the precedence. The sidebar listing policy is C4's
  under X5, over the fields C3's index exposes, and is added to the Design.
- 2026-09-05: v2.1 at planning. Planning's hostile read found one overclaim in this
  document: "every row of §7.4 including wedged reachable from a scripted `fake-claude`
  scenario". The wedged row is not, because SIGKILL cannot be refused; G1 and the Decision
  Log now say the supervisor drives its process through a `ProcessHandle` seam and that one
  row runs against a scripted handle. The write allowlist is restated as top-level names,
  C2's observed set plus the trees this child exercises, pinned by a unit test. Plan:
  `docs/doperpowers/plans/2026-09-05-c4-fleetkit-sessions-fleet.md`.
- 2026-09-05: v2.2 after the plan's adversarial review (eleven findings, all folded) and a
  merge of `main` (`71a9999`). Consent is computed from the merged settings sources only, with
  the bundle's consent function and startup migration cited and C1's §6.12 spike as the write
  side; the `fake-claude` marker test is replaced by a two-launch zero-cost scenario against
  the installed CLI witnessed by `get_session_cost`. The §6.12 writer is descriptor-relative
  throughout, with six named symlink and mode tests. The pre-spawn check refuses on every
  live holder and the post-handshake check excludes exactly the new pid. `PaneRequest` gains
  the parent's opaque `id`. G1 covers `(row, from, event, to)` scenarios, splits the
  disagreement transition into its own event, and injects `terminate() == nil` through every
  terminating action. Cap slots are reservations with observed eviction outcomes. The store's
  namespace is a closed enum, its constructor is validated-only, atomicity is tested through
  an injected file-ops seam, and schema versions are handled per case. Mirror entries carry
  armed and running, and G2's boundary cases match the unit test's. The supervisor owns a
  `SessionRuntimeState`; the restart snapshots it, and a route-then-restart test proves it.
  Forking uses `SessionStart.forkFrom` and the planned skip is withdrawn. The router carries
  typed strategies with fixture-backed multi-step tests. G5 runs behind one serialised live
  budget and one suite-level config-home witness. The delegated unknown about the
  `.claude.json` arrays is closed.
- 2026-09-05: touch-up after v2.2, with the plan's. The Router paragraph now names
  `RouteStrategy` as the entry's typed strategy, as the Decision Log already did; the plan's
  G1 coverage assertion moves to its final task as a gate so every checkpoint is green.
  Merged `main` at `6f3ea5a`; the WireEventPolicy corrective (`ca68f2e`) touches no internal
  this document cites.
- v2.3 (2026-09-05, after the plan's second adversarial review; twelve findings, all
  folded): `ProcessHandle.events` is an existential with a `LiveProcessHandle` live
  conformance; the cap counter counts pending evictions and decides from pushed eligibility;
  the §6.12 writer verifies the root descriptor with `F_GETPATH`; `SessionRuntimeState`
  gains `flagSettings` and `fastModeObserved` and the restart relaunches every field from
  the snapshot and verifies against the keys of `effective`; `LifecycleAction.answer` and
  `LifecycleAPI.events(of:)` are added and `LifecycleAction` is `Sendable` only;
  `LiveBudget.run` reserves synchronously; G3/G5 accept the marker through the store first
  and the allowlist scenario reads twice, asserts the actions from events and breaks on
  `projects/`; the store seam splits the staging write; `procStart` is the liveness
  comparison with the window as the diagnosed fallback; the `/cd` continuation is replayed
  from `session-mirror-relocation` and compared by full payload; send-to-background and
  open-in-terminal gain from-dormant scenarios; the fork collision is scripted through
  `.sessionIdentityResolved`. Surface additions are recorded in the parent's Revision Note
  at merge.
- v2.4 (2026-09-05, after the plan's third adversarial review; fifteen findings, all
  folded): the handoffs recheck ownership before the launch and before the pane request
  (`handoffPreempted`, six scenarios) and the residual pane window is accepted;
  `ProjectMCPServer` carries a `Transport` (stdio, http, sse, other) and the entry hash
  covers the whole raw entry; a fork stays connecting until its identity resolves and the
  counter rekeys its slot; the dormant cap-victim row is deleted; recency is the counter's
  fleet-wide activity clock; an answer consumes its id before the write and a failed write
  is `answerFailed`; `terminate()` returns a `TerminationReport` whose steps are captured
  `terminateEscalated` diagnostics; `ChannelState` gains `pendingDecisions`, `systemItem`
  and `identity`, with `PendingDecision`, `SystemItem`, `TerminationReport` and
  `LifecycleError` declared in the Types block; `LifecycleAPI` gains `jobs()` and
  `performJob(_:_:)` with `JobEntry` and `JobVerb`, and `LifecycleAction` loses the three
  job verbs; `Holder.isJob` drives the resolver; `--max-turns` is stated per live scenario,
  forwarded to `--bg` unprobed, and the live ceiling is four turns; the composed scenario
  answers its own decisions and waits for the shell's follow-up turn;
  `ContentHash.sha256Hex` over CryptoKit with a pinned vector. Surface additions are
  recorded in the parent's Revision Note at merge.
