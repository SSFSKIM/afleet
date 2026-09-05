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
> only the residue those sections leave to this child.

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
injected clock so no test waits on wall time. One test per row of the parent's §7.4 table,
each named for its row, and the suite asserts that the set of rows covered equals the set of
rows in the table constant the supervisor is built from, so a row added later without a test
fails the build:

- eager spawn on open of a recently active archived channel; history-only open of an older one; spawn-then-send on an older one when the user sends;
- connecting to ready when the post-handshake check is clean; connecting to foreign live, own process terminated, when the post-handshake check finds another holder (item 46 at the API level);
- ready to dormant after 30 minutes dormant-eligible, and *not* while a task in the registry mirror is running or its heartbeat is uncertain (item 18's two halves; the mirror is a C3 type, so until C3 lands this test feeds the supervisor a stand-in that conforms to X4's mirror-entry shape, and G2 replaces the stand-in);
- dormant to ready on send, same session id, one connecting glyph;
- respawn on non-zero exit with backoff 1 s, 2 s, 4 s, three attempts, each behind the ownership check, then the system item with exit code, stderr tail and *Reopen* (item 20);
- the cap of six: the seventh spawn reaps the least recently used dormant-eligible channel; with none eligible, no eviction and the header state carries the live count and *Send to background* (item 19);
- wedged when `terminate()` returns `nil`: no respawn under that session id, the escalation trace on a system item, *Reopen* spawning only after the ownership check finds no holder;
- adopt: `claude stop <short>`, wait for exit and roster removal, spawn `--resume`;
- send to background: `terminate()`, wait for exit and registry removal, `claude --bg --resume <id>`, the new job found in the roster by its `resumeSessionId` (item 16);
- open in terminal: `terminate()`, wait, return a `PaneRequest` whose purpose is `.hatch(id)`, whose arguments are the interactive `--resume <id>` line and whose environment is composed through ClaudeWire's launch configuration so the hatch resumes under the same config home; keep mirroring; re-adopt when the panel reports the `PaneExit` and the record is gone (the test plays the panel: it takes the request and reports the exit);
- foreign live in the user's terminal: send refused with the "running in your terminal" reason and *Fork* offered; record gone means archived;
- Contended after a handoff wait exceeds 10 s, and whenever desired and observed disagree; back to the matching origin when the holder set settles to zero or one;
- the quiescent restart: snapshot, terminate, wait, spawn with the carried flags and never `--agent`, re-send `apply_flag_settings`, verify every readback, composer disabled until each matches, a banner naming the setting that did not survive (items 58 and 63 at the API level, the mismatch half driven by `FAKE_CLAUDE_INIT` answering a different `current_permission_mode`).

Every spawn in every row is preceded by the pre-spawn ownership check and every handshake by
the post-handshake check, asserted by a recording holder-reader that the tests inject.

**G2 — dormant eligibility reads the registry mirror (required, blocked-by C3.G3).** With
C3's mirror driven by the `background-shell` fixture through `fake-claude`, a channel whose
mirror lists a running task is never reaped, and one whose mirror is empty and whose last
task frame is older than the heartbeat interval is. Until C3.G3 lands the stand-in of G1
stands and this gate is marked pending in the parent's tracking map.

**G3 — the preconditions (required).** Under a temporary project directory the test creates:
an untrusted root (no `hasTrustDialogAccepted: true` under its canonical key in the scratch
`.claude.json`) yields the `.untrusted` precondition and no spawn (item 47's logic); a
`.mcp.json` declaring a pending server yields `.consentNeeded` naming it and no spawn; a
decline writes `disabledMcpjsonServers` into the project's `.claude/settings.local.json`
through the parent's §6.12 resolver and write policy, with every other key byte-for-byte
untouched, a staging file under `.claude/.cc-writes`, an `O_NOFOLLOW` open, and the
existing mode preserved; a marker-file sentinel proves the declined server's command never
ran; a `.claude` that is a symlink to a directory outside the project makes the decline write
nothing, leave the symlink target unchanged, spawn nothing and report the `/mcp` banner; a
project whose store resolves inside the ConfigHome (the `CLAUDE_CONFIG_DIR`-inside-project
case) refuses the write the same way; isolated setting sources with a declared `.mcp.json`
server add `--strict-mcp-config` to the launch and the header reason; a pending
managed-settings pair under the scratch ConfigHome yields `.managedSettingsPending` and no
spawn (item 55). Nothing else in the package ever writes under a project directory, asserted
by a test that diffs the project tree across every other precondition path.

**G4 — the router (required).** The router table is data; a test asserts that the set of
local commands in the table equals the set the parent's §7.7 table names, with no
duplicates, and that every entry maps to one of the mechanisms the parent lists. Against the
`control-shapes` fixture: `/effort low` sends `apply_flag_settings {effortLevel}` and reads
back `get_settings.effective_keys`; `/cd` into an untrusted directory receives `needs_trust`
and, after the trust answer, repeats the call with `trust_accepted: true` and
`trusted_directory`; `/rename` sends `rename_session`; `/model` sends `set_model`. A
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
with `AFLEET_LIVE_CLI=1`, under `/tmp/afleet-fixtures/config-home`, after C2's budget reader
finds every usage window below exhaustion, and touches only processes the test starts. The
foreign-session half spends no model turn: the test starts an interactive `claude` on a
pseudo-terminal in a directory the scratch config home already trusts (recreated if absent;
the test never writes trust), and within five seconds the fleet reports a foreign live
channel with the record's `status`; the test then ends its own pty child and the channel
turns archived when the record is gone. The job half prefers `claude --bg --exec "sleep 60"`,
which spends nothing: the roster lists it, the fleet reports a background job, `claude stop
<short>` through the real runner removes it. Adoption of a job with a conversation costs one
short `haiku` turn (`claude --bg --model claude-haiku-4-5-20251001 "Reply with exactly:
pong"`), runs only when `AFLEET_LIVE_CLI_TURNS=1` is also set, and asserts that adopt stops the
job, resumes the same session id owned, and that the next handshake is clean. The
config-home diff of C2's live gate is taken across the whole of G5: the set of relative paths
the engine wrote is reported, never their contents, and compared against the allowlist that
G5 widens (see *The write allowlist* below).

## Grounding

Read on `main` at `ee94449` before this spec was written, so the residue decisions rest on
what exists rather than on the plan's picture of it.

- **`ClaudeProcess` (C2, X3).** One instance per spawn with the epoch FleetKit assigns;
  `spawn()` returns a `Handshake` when the `initialize` response arrives and nothing from
  `system/init`; `events` is a bounded lossless `WireEventStream<WireEvent>` with
  `.handshakeCompleted`, `.sessionIdentityResolved` (a fork's real id, once), `.frame`,
  `.request`, `.requestCancelled`, `.policyAnswered`, `.unansweredDialog`,
  `.hostToolInvoked`, `.stderr`, `.exited`; `terminate()` returns `ExitStatus?` where `nil`
  means the escalation exhausted with no exit observed, `status` stays `.terminating` and the
  stream stays open; `sessionID` is `nil` for a fork until `.sessionIdentityResolved`;
  `childProcessIdentifier` is the child's pid. `Handshake.pending` is a wire fact nothing
  renders from. `LaunchConfiguration` composes the §6.1 line and the child environment,
  rejects option-shaped values, and carries `configHomeOverride` for tests only.
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
  `messagingSocketPath`, `name`, `nameSource`, `nameSince`, and for a `bg` process with a job
  directory `jobId`; TUI processes add `status`, `waitingFor`, `state`, `detail`, `tempo`;
  headless ones never do (parity 38.2, probes 12 and 12b, `spike-contention`). The CLI's own
  reader validates a holder by pid liveness and its `procStart` token (bundle cleanup path
  over `daemon/roster.json`). The scratch config home's `sessions/` is empty at rest.
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
  `enabledMcpjsonServers`, `disabledMcpjsonServers` per project; `remote-settings.json` and
  `remote-settings-consent.json` are absent there and unrecorded in the corpus.
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
  Lifecycle/      ChannelSupervisor (actor), LifecycleTable, DormantEligibility, RestartSnapshot, Readback
  Preconditions/  SpawnPreconditions, TrustReader, ProjectMCPConsent, LocalSettingsStore (the §6.12 write), ManagedSettingsReader
  Activity/       ActivityQuery, ActivityRow
  Router/         CommandRouter, RouterTable, LaunchSettingMatrix, RefusalInterceptor, LogoutPlan
  Store/          StateStore (protocol), FileStateStore, FleetKitState (the namespace's Codable types)
  Verbs/          CLIVerbs (agents --json, stop, --bg --resume, --bg --exec, auth status, auth logout) over ProcessRunner
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
  public var wedged: EscalationTrace?                        // non-nil only in the wedged row
  public var presence: Presence                              // idle, busy, waiting(for:), unknown
  public var lastActivity: Date
  public var apiKeySource: String?                           // from the first system/init, kept per channel for the header
  public var liveCount: Int                                  // owned processes live across the fleet, for the cap header
  public var banner: ChannelBanner?                          // releasedToTerminal, contended(HolderSet), settingDidNotSurvive(String), mcpDeclineRefused(String), managedSettingsPending, untrusted
  public var headerNote: HeaderNote?                         // projectServersOff, capReached(live:)
  public var pendingChange: RestartRequest?                  // "applies when the current work finishes"
}

public enum Presence: Hashable, Sendable { case idle, busy, waiting(for: String?), unknown }
public struct ForeignPresence: Hashable, Sendable { public var status: String; public var waitingFor: String?; public var name: String? }
public struct EscalationTrace: Hashable, Sendable { public var steps: [String]; public var pid: Int32; public var epoch: ProcessEpoch }   // the terminate_escalated steps, in order
public struct ProjectMCPServer: Hashable, Sendable { public var name: String; public var command: String; public var arguments: [String]; public var entryHash: String }
public struct RestartRequest: Hashable, Sendable {
  public var addDirectories: [URL]?; public var settingSources: [SettingSource]??; public var allowBypass: Bool?
  public var promptSuggestions: Bool?; public var worktree: Worktree??; public var environment: ChildEnvironmentOptions?   // nil = keep the current value
}
public struct RestartSnapshot: Hashable, Sendable {
  public var permissionMode: PermissionMode?; public var model: String?; public var effort: String?; public var fastMode: Bool
  public var outputStyle: String?; public var addDirectories: [URL]; public var environment: ChildEnvironmentOptions
}
public struct AgentsRow: Hashable, Codable, Sendable {      // one element of `claude agents --json`
  public var pid: Int32?; public var id: String?; public var cwd: String; public var kind: String; public var startedAt: Double
  public var sessionId: String?; public var name: String?; public var status: String?; public var waitingFor: String?; public var state: String?
}
public struct JobShort: Hashable, Codable, Sendable { public let rawValue: String }

public enum SpawnPrecondition: Hashable, Sendable {
  case ready
  case untrusted(root: URL)
  case consentNeeded([ProjectMCPServer])                     // name, command, args summary, hash
  case managedSettingsPending
  case contended(HolderSet)
  case wedged(EscalationTrace)
}

public enum LifecycleAction: Hashable, Sendable {
  case open, send(UserInput), reap, adopt, sendToBackground, fork(at: UUID?)
  case quiescentRestart(RestartRequest), stopEverything, backgroundAll, logout, reopen
  case stopJob(JobShort), respawnJob(JobShort), removeJob(JobShort)      // CLI verbs, no PTY (parent X5 as amended 2026-09-05)
}

// Design inheritance from the parent's X5 as amended on 2026-09-05 (C7's decomposing run): the Terminal
// panel never spawns `claude` for a session on its own initiative. X5 performs the ownership work of
// §7.2 rule 5 and hands the panel a pane request; the panel runs it and reports the exit back through
// X5, which owns the re-adoption of §7.4's hatch rows. `attach` and `logs` are panes; `stop`,
// `respawn` and `rm` are verbs above.
public enum PanePurpose: Hashable, Sendable { case hatch(SessionID), attach(JobShort), logs(JobShort), shell, command }
public struct PaneRequest: Hashable, Sendable {
  public var executable: URL; public var arguments: [String]; public var cwd: URL
  public var environment: [String: String]                   // composed by C4 through LaunchConfiguration.childEnvironment (§6.1, X11)
  public var purpose: PanePurpose
}
public struct PaneExit: Hashable, Sendable { public var request: PaneRequest; public var code: Int32; public var observedAt: Date }

public protocol LifecycleAPI: Sendable {                     // what C5, C6 and C7 call; nothing else spawns
  func state(of key: ChannelKey) async -> ChannelState?
  func states() async -> [ChannelState]
  func preconditions(for key: ChannelKey) async -> SpawnPrecondition
  func perform(_ action: LifecycleAction, on key: ChannelKey) async throws -> ChannelState
  func openInTerminal(_ key: ChannelKey) async throws -> PaneRequest     // §7.4 open-in-terminal row up to the handoff; purpose .hatch
  func attach(_ job: JobShort) async throws -> PaneRequest               // `claude attach <short>`; purpose .attach
  func logs(_ job: JobShort) async throws -> PaneRequest                 // `claude logs <short>`; purpose .logs
  func paneExited(_ exit: PaneExit) async                                // the panel's report; X5 re-adopts a hatch whose record is gone
  func isDormantEligible(_ key: ChannelKey) async -> Bool
  func declineProjectServers(_ names: [String], project: URL) async throws        // the §6.12 write
  func acceptProjectServers(_ servers: [ProjectMCPServer], project: URL) async   // store only
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

- **registry**: every `<configHome>/sessions/<pid>.json` that parses; a record is *live* when
  `kill(pid, 0)` succeeds and the process's start time, read through `proc_pidinfo`, lies
  within sixty seconds of the record's `startedAt`; a dead record is ignored, never deleted;
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
otherwise *archived*. Presence for foreign channels comes from the record's `status` and
`waitingFor` when present and is `.unknown` when absent, which is every headless holder.
Presence for an owned channel is afleet's own turn state: `busy` from a send until its
`result`, `waiting` while a decision is pending, `idle` otherwise; a `session_state_changed`
frame, when one arrives, maps `requires_action` to `waiting` and is otherwise recorded and
ignored, because the corpus has never shown one.

Watching: a dispatch vnode source on `sessions/`, `jobs/` and `daemon/`, plus a five-second
poll that re-reads everything, because in-place edits of a registry record (a TUI's status
change) do not fire a directory source. Every read is a snapshot with `observedAt`;
`FleetObserver` publishes a new `HolderSet` only when it differs from the last.

### Ownership (`Ownership/`)

`OwnershipCheck.beforeSpawn(key)` re-reads all three sources synchronously and returns the
foreign holders; any holder means no spawn and the channel takes the matching origin.
`OwnershipCheck.afterHandshake(key, ownPID)` re-reads and validates each holder's pid and
start time; a foreign holder means yield: `terminate()` our process, origin `.foreignLive`,
the "Opened in your terminal; afleet released this session" notice. Both are recorded on an
injected `HolderReader` so G1 can assert they ran around every spawn. Rule 5's quiescent
handoff is one function, `awaitRelease(previous holder, upTo: 10 s)`, that waits for the
process exit *and* the record's disappearance and returns `.released` or `.timedOut`, on
which the channel becomes Contended. Rule 6: `perform(.send)` on a held session throws
`LifecycleError.heldElsewhere(HolderSet)` and the state offers `fork`.

### Lifecycle (`Lifecycle/`)

`ChannelSupervisor` is one actor per channel, owning at most one `ClaudeProcess` at a time
and the channel's epoch progression (`ProcessEpoch.first`, then `.next()` on every spawn).
Frames, exits and holder events tagged with an older epoch are discarded on entry. The
supervisor is built from `LifecycleTable`, a constant array of rows `(from, event, to)` that
mirrors the parent's table exactly and is what G1's coverage test reads; a transition not in
the table is a programming error surfaced as a diagnostic, never a silent state change.

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

**Wedged.** When `terminate()` returns `nil` the channel enters `.owned(.dormant)` with
`wedged` set to the escalation trace the diagnostics recorded and `liveCount` still counting
the ghost; no respawn happens under that session id; `.reopen` runs the pre-spawn ownership
check and spawns only when it finds no holder, clearing `wedged`. The wedged channel is
released from the live count only when a later observation finds the ghost's registry record
gone and its pid dead.

**Respawn** on a non-zero exit: three attempts at 1 s, 2 s and 4 s, each behind the pre-spawn
check; the fourth failure produces the system item with the exit code, the stderr tail from
`ExitStatus` and *Reopen*, and the channel is archived if it was never ready in this epoch
series, else owned-ready with the item.

**The cap.** A fleet-wide counter of live owned processes; at six, a seventh spawn asks the
fleet for its least recently used dormant-eligible channel and reaps it; a wedged channel is
excluded from eviction as it is from eligibility, and the cap rule reads the same trace
(ruling of 2026-09-05); none eligible means
no eviction, the spawn is refused with `LifecycleError.capReached(live: 6)`, and every
channel's `liveCount` reads six so the header can show it and offer *Send to background*.

**Quiescent restart** takes a `RestartRequest` (`addDirectories`, `settingSources`,
`allowBypass`, `promptSuggestions`, `worktree`, environment options) and runs: wait for
dormant eligibility (queueing with the "applies when the current work finishes" state);
`RestartSnapshot` from the session object (permission mode, model, effort, fast mode, output
style, the cumulative `--add-dir` list and the environment table); `terminate()`; await
release; spawn `--resume <id>` under the same key with `--permission-mode`, `--model`,
`--effort` and every cumulative flag, never `--agent`; after the handshake re-send
`apply_flag_settings` for the process-local values; `Readback` verifies model and effort from
`get_settings.applied`, permission mode from the handshake's `current_permission_mode`, fast
mode from the initialize response's `fast_mode_state`, output style from `output_style`; the
state stays `.connecting` until every readback matches, and a mismatch sets
`ChannelState.banner = .settingDidNotSurvive(name)` and keeps the composer disabled until the
user picks a value. `apiKeySource` is re-read from the relaunch's first `system/init`.

**Open in terminal, attach and logs** follow the parent's X5 as amended: `openInTerminal`
runs `terminate()`, awaits release, marks the channel `.foreignLive(.ownTerminalTab)` with the
pending hatch recorded, and returns a `PaneRequest` whose executable is the located binary,
whose arguments are `["--resume", id]` (the interactive line, none of §6.1's print-mode
flags), whose cwd is the channel's, and whose environment is
`LaunchConfiguration.childEnvironment(over: resolved, configHome:)` for that channel, so the
hatch resumes under the same config home and the same scrubbed, re-injected environment as
the owned process did. `attach(job)` and `logs(job)` return requests for `claude attach
<short>` and `claude logs <short>` with the job's cwd and the same environment, and change no
ownership. The panel runs the request and calls `paneExited`; for a `.hatch` the supervisor
then waits for the registry record to disappear (rule 5's release) and spawns `--resume <id>`
owned, which is §7.4's re-adoption row; a `PaneExit` for a request the supervisor no longer
tracks (an older epoch, a channel already re-adopted) is recorded and ignored. The panel
never spawns `claude` for a session on its own initiative, and no other package receives a
`PaneRequest` for a session.

**Fork** spawns `--resume <id> --fork-session` (with `--resume-session-at <uuid>` and
`--resume-drops-turn` when forking from a message) as a new channel whose key is provisional
until `.sessionIdentityResolved`; the supervisor re-keys the channel on that event and
publishes the new state, and captures follow C2's provisional-name rule on their own.

### Preconditions (`Preconditions/`)

`SpawnPreconditions.evaluate(project cwd, launch)` runs in this order and returns the first
failure: wedged; contended (a foreign holder from the pre-spawn check); managed settings
pending; untrusted; consent needed. Only `.ready` spawns.

- **Trust** (`TrustReader`): canonical root = the real path of the channel directory walked
  up to the first entry containing `.git` (file or directory), else the real path itself;
  read `projects[<root>].hasTrustDialogAccepted` from `<configHome>/.claude.json`; anything
  but `true` is untrusted. Read-only; re-read when the app asks after a terminal pane exits.
- **Project MCP consent** (`ProjectMCPConsent`): parse `<root>/.mcp.json`; for each server
  compute rejected, approved or pending from two locations read-only, as ruled on 2026-09-05
  after the coordinator verified in the bundle that the engine's own decline dialog writes
  through its local-settings writer and that the per-project entry in `.claude.json` is a
  second location the engine consults: **rejected** when either the local-settings store's
  `disabledMcpjsonServers` or the project entry's names the server; **approved** when any
  settings source or the project entry lists it in `enabledMcpjsonServers` or sets
  `enableAllProjectMcpServers`; else **pending**. The write goes only through §6.12's path
  below; a C1 zero-cost probe (a TUI decline under the scratch home, diffing the files that
  change) will make the read precedence recorded rather than inferred. Pending servers with a hash of their entry that the FleetKit store has not
  recorded as accepted yield `.consentNeeded`. *Accept* records `(project, name, hash)` in
  the store and writes nothing. *Decline* is `LocalSettingsStore.decline(names, root)`: the
  parent's store resolution and write policy line by line, executed only while no owned
  process for the project is running, followed by a re-read through the same resolver
  before any spawn is allowed. Fail closed: unparseable JSON, a symlink at the target or its
  parent, a foreign uid, a store inside the ConfigHome, or any write error means
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
`ActivityRow`s in the parent's categories: pending decisions, notifications, failed results
(`result` error subtypes and `is_error` tool results), permission denials
(`result.permission_denials` and `system/permission_denied`), rate-limit banners (decided by
`status` alone; `overageStatus: "rejected"` with `org_level_disabled` never renders as a
refusal), auth state from `auth_status`, running and failed agent runs from the mirror. Each
row carries its `ChannelKey` and, where one exists, the item uuid, so C6 links it; answering a
decision from Activity goes through the same `answer` path as the channel.

### Router (`Router/`, contract X10, owned)

`RouterTable` is data: `[LocalCommand]` with `name`, `mechanism` (`.controlRequest(spec
builder)`, `.lifecycle(LifecycleAction)`, `.restart(RestartRequest builder)`, `.text`,
`.native(NativeAction)`), `readback`, and `explanation`. `CommandRouter.route(text,
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
public struct StoreNamespace: RawRepresentable, Hashable, Codable, Sendable { public static let fleetKit, workbench, afleet: StoreNamespace }
public actor FileStateStore: StateStore { public init(baseDirectory: URL) }
```

One JSON document per namespace, `<base>/state.<namespace>.json`, with an envelope
`{schemaVersion, values: {key: json}}`; every write re-serialises the namespace document
to a temporary file in the same directory and renames it into place; a document whose
`schemaVersion` is newer than the reader's is refused with an error rather than rewritten.
Keys are non-empty strings in which dots are ordinary characters and imply no hierarchy;
the schema version is per namespace and nothing else is versioned. This is design
inheritance from the parent's X6 as amended on 2026-09-05: Workbench persists under
`workbench.browser` and `workbench.panel.<configHomeHash>.<sessionId>` in its own namespace,
and a test writes and reads back both key shapes through the API. The app injects
`baseDirectory` (`~/Library/Application Support/afleet/` in production, a temporary
directory in tests); nothing about the store knows a ConfigHome, and a base
directory inside one is rejected at construction (X9). `FleetKitState` holds the namespace's
own `Codable` types: channel grouping and pins, section order and collapse, unread cursors
per session, `DesiredOwnership` per channel, project-server acceptances `(project, name,
hash)`, afleet-launched job shorts, the bypass disclaimer acceptance, the fixture-recorded
baseline and the last census. FleetKit never models Workbench or Afleet state.

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
id`, then confirmed in the roster), `backgroundExec(command, cwd)`, `respawn(short)`, `remove(short)`, `authStatus()`,
`authLogout()`; `attach` and `logs` are never run here, because they need a PTY and are pane
requests (X5 as amended). Every verb call is a diagnostic event carrying the verb, exit code and
duration and never its stdout. Tests inject `ScriptedProcessRunner`, which maps an argv
pattern to `(stdout, exit)` and may mutate the scripted holder files so that `stop` removes a
worker from the roster and marks the job stopped, and `--bg --resume` creates a job with the
right `resumeSessionId`.

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
path patterns, what the engine is known to write: `sessions/<pid>.json` and its `.key`
sibling, `projects/<slug>/<sid>.jsonl` and the `<sid>/` sidecar tree, `tasks/`,
`jobs/<short>/`, `daemon/`, `history.jsonl`, `.claude.json`, `shell-snapshots/`,
`session-env/`, `file-history/`, `statsig/` and `cache/`. An observed path outside the
allowlist fails the gate with the path named, because either the allowlist or the never-write
claim is wrong and both deserve a look. The turn-spending scenario behind
`AFLEET_LIVE_CLI_TURNS=1` sends one `haiku` prompt asking for a background shell and an
Explore subagent under a channel with the Notification hook registered, so hooks, a
background shell and a subagent all write in one turn; session relocation is covered by
`set_cwd` against a second trusted directory in the same turn's channel. Editor integration
is not reachable from afleet and is stated as untested.

## Contracts

**Owned by C4.** X5 Lifecycle API, exactly `LifecycleAPI`, `ChannelState`,
`SpawnPrecondition`, `LifecycleAction`, `PaneRequest`, `PanePurpose`, `PaneExit`,
`HolderSet` and `ChannelKey` above, with public initialisers on every value a downstream
package constructs; the pane protocol and the verb-versus-pane split are inherited from the
parent's X5 as amended on 2026-09-05, not chosen here. X6 Store namespaces, exactly
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
the five-second poll rather than FSEvents (advisory means); the `TaskMirrorReading`
protocol through which C4 consumes X4's mirror, so C3's landing replaces a stand-in rather
than an interface; and the `IndexStorage` seam between C3 and C4 as ruled (declared in `FleetTimeline`,
implemented here), which needs no X2 change. The delegated unknown about `.claude.json`'s per-project server arrays is
reported for the reconciling architect rather than acted on.

## Delegated unknowns

- The registry record's `procStart` format. C4 validates a holder by pid liveness and process
  start time within sixty seconds of `startedAt`, which needs no format; a C1 corrective
  recording of a registry snapshot would let a later revision compare `procStart` exactly.
- The `remote-settings.json` and `remote-settings-consent.json` shapes. Modelled from the
  bundle's chapter 48 §2.9 at plan time; fail closed; a real payload, if one is ever
  observed, becomes a C1 recording.
- Whether `claude --bg --exec` produces a job with a `sessionId` that `--resume` accepts. G5
  observes and records it; adoption of a conversation job is the turn-spending path.
- Whether the CLI reads the per-project `enabledMcpjsonServers` and `disabledMcpjsonServers`
  arrays in `.claude.json` in addition to the local-settings store. The scratch home carries
  both arrays on every project entry; the parent's rule names the local-settings store only,
  and C4 follows the parent, recording the observation for the reconciling architect.
- What a headless child writes under the config home across hooks, background shells,
  subagents and relocation, beyond the one turn C2 measured. G5's allowlist reading answers
  it for one composed turn.

## Questions for the human gate

Answered on 2026-09-05; kept as the record of what was asked. (1) Nothing moves to
`AfleetCore`; C3's `IndexStorage` is implemented here over `FileStateStore`. (2) Yes to the
one composed turn behind `AFLEET_LIVE_CLI_TURNS=1`, after the budget check; at most two short
turns in total. (3) One document per namespace, filed on the parent's §7.8.

1. **Where does the store protocol live?** §7.3 says C3's transcript index caches into the
   store, but `FleetTimeline` cannot import `FleetSessions`. Recommendation: `StateStore`
   and `StoreNamespace` move to `AfleetCore` as an X2 addition (a Revision Note on the
   parent), `FileStateStore` stays in C4, and C3 receives an instance by injection. The
   alternative, C3 keeping its cache in memory only, costs the cold-index budget on every
   launch.
2. **Spend one live turn to widen the write allowlist?** Recommendation: yes, once, behind
   `AFLEET_LIVE_CLI_TURNS=1`, on `haiku`, after the budget check; the never-write claim is
   the project's central safety promise and one composed turn is the cheapest evidence that
   exists. Total live spend for C4 is then at most two short turns.
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
  and an injected `Clock`.
  Rationale: the parent's table is the specification; making it the code's data lets G1
  assert coverage by set equality and lets every timer be advanced by a test. Rejected: a
  single fleet actor with a state map (one hot actor for six processes' frames); wall-clock
  tests with shortened constants (the constants are the behaviour).
  Date/Author: 2026-09-05 / C4 dispatch.
- Decision: holder liveness is pid liveness plus process start time within sixty seconds of
  the record's `startedAt`.
  Rationale: the CLI validates with `procStart`, whose format the corpus has not recorded,
  and inventing it is forbidden; start time from `proc_pidinfo` detects pid reuse just as
  well. Rejected: pid liveness alone (pid reuse would fabricate a holder); parsing
  `procStart` (unrecorded format).
  Date/Author: 2026-09-05 / C4 dispatch.
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
  `enabledMcpjsonServers` and `disabledMcpjsonServers` arrays. Evidence: read-only
  inspection of `/tmp/afleet-fixtures/config-home/.claude.json`. Impact: listed as a
  delegated unknown; the parent's rule stands.
- Observation: `jobs/<short>/state.json` carries `resumeSessionId`. Evidence: the three
  stopped S12 jobs in the scratch home. Impact: send-to-background finds its new job without
  parsing `--bg`'s stderr note.

## Outcomes & Retrospective

Pending — written at finish.

## Revision Notes

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
