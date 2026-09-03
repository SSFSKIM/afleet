# C2: `AfleetCore` and `ClaudeWire` (2026-09-04)

> **Parent:** `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C2`.
> **Parent-pin:** that path at commit `9fd067c` ("Spec: §6.10 counts the fourteen probe
> scripts"). **Level name:** child, wave 1 of the v1 roadmap. **Track:** controlled.
> **Branch:** `child/c2-core-wire`, worktree `../afleet-c2`; merges to `main` when G1, G3
> and G4 pass and G2 passes against C1's first fixtures. This document treats the parent's
> §17 C2 section and its binding inheritance (§5, §6.1 through §6.9) as landed; it
> records only the residue those sections leave to this child.

## Purpose

afleet hosts the unmodified `claude` binary over its headless stream-json protocol.
Everything above the wire — timeline, fleet, panels, shell — assumes a layer that speaks
that protocol exactly, tags every event with the process it came from, answers every
inbound control request one way or another, never loses a frame it does not understand,
and launches the binary with the terminal's own environment. C2 builds that layer as the
two bottom SwiftPM packages of the parent's §5: `AfleetCore`, the value types every
package shares, and `ClaudeWire`, the frame models, the `ClaudeProcess` actor, the
in-process MCP server, diagnostics and capture, the version gate, and login-shell
environment and ConfigHome resolution. When C2 is done, FleetKit (C3, C4) can be written
against a typed API and tested against `fake-claude` without ever touching a socket, a
pipe or a shell.

## Acceptance

The parent's gates, restated as observable behaviour. Each gate names the test target
that proves it.

- **G1 (required) — the wire layer behaves as §6.1 through §6.7 say, without the real
  CLI.** `swift test --package-path ClaudeWire` passes and includes tests that assert:
  the argument vector `LaunchConfiguration.arguments()` produces for a new channel, a
  resumed channel and a forked channel equals the §6.1 line token for token, in order,
  with every optional flag exercised at least once; the child environment equals the
  resolved login environment plus the §6.1 table (the six variables under their
  settings) minus `CLAUDE_CODE_REMOTE`, `CLAUDE_CODE_CONTAINER_ID` and
  `CLAUDE_CODE_ENTRYPOINT`; the first stdin line is the §6.2 `initialize` payload,
  byte-equal after canonical JSON ordering; an inbound request with an unknown subtype
  is answered within one second with a `control_response` error reading
  `subtype <x> not supported by afleet <version>` and surfaced as a policy event, not
  as a request; a `request_user_dialog` whose `dialog_kind` is not declared is never
  answered and is surfaced as an event; a known subtype whose payload fails to decode is
  answered with an error naming the failing field and surfaced as a malformed request;
  every frame, request, stderr line and exit event carries the epoch the process was
  created with; `terminate()` sends `end_session`, closes stdin, waits up to five
  seconds for exit, then sends SIGTERM, in that order, observed against a scripted
  stand-in that ignores `end_session` (§6.7).
- **G2 (required, blocked-by C1.G1) — nothing known is lost, nothing unknown is
  dropped.** For every fixture in `Fixtures/`, every NDJSON line decodes to a `Frame`;
  re-encoding a decoded known frame reproduces every key the fixture line had, with
  equal values; lines whose `type` or `subtype` is not modelled decode to
  `Frame.opaque` carrying the raw line and a parsed `JSONValue`; the count of opaque
  frames per fixture equals the census's count of unmodelled types. This is the
  ClaudeWire half of the parent's acceptance item 36.
- **G3 (required) — it works against the installed CLI.** With `AFLEET_LIVE_CLI=1`, a
  test spawns `claude` 2.1.259 in a temporary directory under the user's real ConfigHome
  with `--setting-sources ""`, completes the handshake, sees `mcp__afleet__send_user_file`
  in `system/init.tools`, asks the model to send a file and receives the
  `hostToolInvoked` event naming that file with the model's turn completing normally
  (S5's mechanism; the wire half of item 29); `VersionGate` refuses a fabricated
  `claude --version` output older than the baseline and accepts 2.1.259 and a newer
  string (item 33's logic); `EnvironmentResolver` returns the login shell's PATH, and a
  `CLAUDE_CONFIG_DIR` exported in `~/.zshrc` becomes `ConfigHome.root` with
  `source == .environment` (items 34 and 48, wire half).
- **G4 (required) — the typings never enter the repository.** `Tools/fetch-typings.sh`
  runs `npm pack @anthropic-ai/claude-agent-sdk@0.3.259` into `.typings/`, which is
  gitignored; `git ls-files` shows nothing under `.typings/`, `node_modules/` or any
  `*.d.ts`; the optional drift test that reads the typings is skipped, not failed, when
  the directory is absent.

Parent items C2 touches but does not close: 29, 33, 34, 36, 48 (their UI halves belong
to C5 and C6).

## Grounding

Measured 2026-09-04 in the worktree. Swift 6.3.3 with Swift Package Manager 6.3.3 and
macOS SDK 26.5; `swift package init` works; strict concurrency is the Swift 6 language
mode default. The pinned typings unpack to `sdk.d.ts` (8,721 lines: 253 type aliases,
102 `SDK*` types, a 39-member `SDKMessage` union, 66 distinct `subtype` literals, 33
`HookEvent` values) and `sdk-tools.d.ts` (4,131 lines, 82 interfaces, about 40 tool
input shapes). macOS's `/usr/bin/env` supports `-0`, so §6.9's NUL-separated capture
works without GNU coreutils. The `initialize` response carries
`pending_permission_requests` and `pending_user_dialog_requests`; the `interrupt`
response carries `still_queued` and `cancelled` when `system/init.capabilities` lists
`interrupt_receipt_v1`; `control_response` is `{subtype: success, request_id,
response?}` or `{subtype: error, request_id, error}` in both directions.

## Design

### Packages and targets

Two packages at the repository root, so the parent's `swift test --package-path
ClaudeWire` reads literally.

```
AfleetCore/
  Package.swift            products: AfleetCore
  Sources/AfleetCore/      SessionID, WorkspaceLink, DiffRef, ResolvedEnvironment,
                           ConfigHome, ChannelOrigin
  Tests/AfleetCoreTests/
ClaudeWire/
  Package.swift            products: ClaudeWire (umbrella); depends on AfleetCore only
  Sources/WireFrames/      JSONValue, Frame and every typed frame, inbound request and
                           answer shapes, outbound request specs, ShellEnvelope
  Sources/WireTransport/   ClaudeProcess, LaunchConfiguration, InitializeConfiguration,
                           correlation, InboundPolicy, epochs, exit observation
  Sources/WireMCP/         JSON-RPC 2.0 codec, AfleetMCPServer, MCPTool, SendUserFileTool
  Sources/WireEnvironment/ EnvironmentResolver, ConfigHome derivation, BinaryLocator,
                           VersionGate, ProtocolBaseline
  Sources/WireDiagnostics/ DiagnosticsSink, FileDiagnostics, RawCapture, Redactor
  Sources/ClaudeWire/      @_exported imports of the five modules
  Tests/<Module>Tests/     one test target per module
  Tests/Support/           scripted-claude.py and hand-written frame samples
Tools/fetch-typings.sh
```

Module dependency order inside ClaudeWire: `WireFrames` ← `WireMCP` ← `WireTransport`;
`WireEnvironment` and `WireDiagnostics` depend on `WireFrames` only; `WireTransport`
depends on all four. No module imports anything outside `AfleetCore` and Foundation.
Every public type is `Sendable`; processes and the MCP server are actors; nothing in
these packages is `@MainActor`. This is the concurrency convention the parent's §17.7
asks C2 to set: actors own I/O, values cross actor boundaries, upper layers add
`@MainActor` at the view-model line.

### `AfleetCore` (contract X2, owned)

```swift
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let uuid: UUID
  public init()                         // new channel
  public init?(_ string: String)        // any case; description is lowercase
}

public enum WorkspaceLink: Hashable, Sendable {
  case file(URL, line: Int?), diff(DiffRef), url(URL), commit(String),
       pullRequest(Int), command(String)
}
public struct DiffRef: Hashable, Sendable {        // §9.6 names it, defines nothing
  public var repository: URL                       // working-tree root
  public var path: String                          // repository-relative
  public var base: Base
  public enum Base: Hashable, Sendable {
    case workingTreeAgainstHEAD, commit(String), commitAgainstParent(String)
  }
}

public struct ResolvedEnvironment: Hashable, Codable, Sendable {
  public var variables: [String: String]
  public var shell: String                         // $SHELL that produced it
  public var capturedAt: Date
  public var mode: CaptureMode
  public enum CaptureMode: String, Codable, Sendable {
    case interactiveLogin, login, processFallback  // §6.9's primary, fallback, last resort
  }
  public var path: [String]                        // derived from variables["PATH"]
}

public struct ConfigHome: Hashable, Codable, Sendable {
  public var root: URL
  public var source: Source
  public var projectDirName: String?               // CLAUDE_CODE_PROJECT_DIR_NAME, only with source == .environment
  public enum Source: String, Codable, Sendable { case environment, `default` }
}

public enum ChannelOrigin: Hashable, Sendable {
  case owned(OwnedState), foreignLive(ForeignHost), backgroundJob, archived
  public enum OwnedState: Hashable, Sendable { case connecting, ready, dormant, contended }
  public enum ForeignHost: Hashable, Sendable { case usersTerminal, ownTerminalTab }
}
```

`OwnedState` and `ForeignHost` enumerate the states named in the parent's §7.4 table.
`DiffRef` is an addition X2 permits with a Revision Note on the parent; it is filed at
merge (see Parent revisions below). `AfleetCore` has no I/O, no dependencies and no
functions beyond initialisers and string conversion.

### `WireFrames`: frame models

**Hand-written, not generated.** The typings are the reference, the Swift models are our
own: one `Codable` struct per `SDKMessage` member and per control request and response
shape we send or receive, named after the typings' names minus the `SDK` prefix
(`AssistantFrame`, `ResultFrame`, `TaskStartedFrame`, `CanUseToolRequest`, …), each
with explicit `CodingKeys` so a Swift test can compare declared keys against a census.
Unpublished subtypes (`side_question`, `rewind_conversation`, `end_session`,
`generate_session_title`, the three `claude_*` auth requests, `transcript_mirror`,
`model_consent_fallback`) are modelled from the bundle source and the parity evidence,
as the parent's §6.3 says, and pinned by C1's fixtures under G2.

**`JSONValue`** is the escape hatch everywhere a shape is open: `null`, `bool`,
`integer(Int64)`, `number(Double)`, `string`, `array`, `object([String: JSONValue])`,
with an order-preserving encoder for tests. Tool inputs (`sdk-tools.d.ts`) are typed
only for the tools whose cards need fields — `Bash`, `Edit`, `Write`, `Read`, `Glob`,
`Grep`, `Agent`, `AskUserQuestion`, `ExitPlanMode`, `WebFetch`, `WebSearch`,
`TaskStop`, `SendMessage` — as `ToolInput` cases; every other tool is
`.other(name, JSONValue)`. Message content is `ContentBlock` (`text`, `thinking`,
`redactedThinking`, `toolUse`, `toolResult`, `image`, `document`, `.opaque(JSONValue)`).

**Two-stage decoding.** A line is parsed once into `JSONValue`; the `type` and
`subtype` strings select the model; the model decodes from the same value. Any failure
yields `Frame.opaque(OpaqueFrame(raw:, value:, reason:))` with
`reason ∈ {unknownType, unknownSubtype, decodeFailure(field:, description:)}`. Opacity
is for one-way frames; inbound `control_request` lines always produce an
`InboundRequest`, whose payload is `.unknown` or `.malformed` when decoding fails, so
the transport can answer them (§6.3). Decoded frames do not retain their raw bytes;
opaque frames do; the transport offers a raw-line tap for capture and diagnostics.

```swift
public enum Frame: Sendable {
  case assistant(AssistantFrame), user(UserFrame), streamEvent(StreamEventFrame),
       result(ResultFrame), system(SystemFrame), toolProgress(ToolProgressFrame),
       toolUseSummary(ToolUseSummaryFrame), rateLimitEvent(RateLimitEventFrame),
       authStatus(AuthStatusFrame), promptSuggestion(PromptSuggestionFrame),
       conversationReset(ConversationResetFrame), transcriptMirror(TranscriptMirrorFrame),
       commandLifecycle(CommandLifecycleFrame), keepAlive,
       controlRequest(ControlRequestFrame), controlResponse(ControlResponseFrame),
       controlCancelRequest(ControlCancelFrame), opaque(OpaqueFrame)
}
public enum SystemFrame: Sendable {   // one case per modelled system subtype …
  case initialize(SystemInit), sessionStateChanged(SessionStateChanged),
       permissionDenied(PermissionDenied), taskStarted(TaskStarted), taskUpdated(TaskUpdated),
       taskProgress(TaskProgress), taskNotification(TaskNotification),
       backgroundTasksChanged(BackgroundTasksChanged), hookStarted(HookStarted),
       hookProgress(HookProgress), hookResponse(HookResponse), compactBoundary(CompactBoundary),
       status(StatusFrame), apiRetry(APIRetry), controlRequestProgress(ControlRequestProgress),
       modelRefusalFallback(ModelRefusalFallback), modelRefusalNoFallback(ModelRefusalNoFallback),
       modelConsentFallback(ModelConsentFallback), localCommandOutput(LocalCommandOutput),
       pluginInstall(PluginInstall), thinkingTokens(ThinkingTokens),
       workerShuttingDown(WorkerShuttingDown), commandsChanged(CommandsChanged),
       notification(NotificationFrame), filesPersisted(FilesPersisted), memoryRecall(MemoryRecall),
       elicitationComplete(ElicitationComplete), mirrorError(MirrorError),
       informational(Informational), error(ErrorFrame), errorDuringExecution(ErrorDuringExecution),
       seedReadState(SeedReadState)
  case opaque(subtype: String, JSONValue)         // … and the fallback
}
```

**Inbound requests and answers.**

```swift
public struct RequestID: Hashable, Sendable { public let rawValue: String }
public struct InboundRequest: Sendable, Identifiable {
  public let id: RequestID; public let epoch: ProcessEpoch
  public let receivedAt: ContinuousClock.Instant
  public let payload: Payload
  public enum Payload: Sendable {
    case canUseTool(CanUseToolRequest), requestUserDialog(UserDialogRequest),
         elicitation(ElicitationRequest), hookCallback(HookCallbackRequest),
         mcpMessage(MCPMessageRequest),
         unknown(subtype: String, JSONValue), malformed(subtype: String, field: String, JSONValue)
  }
}
public enum InboundAnswer: Sendable {
  case permission(PermissionResult)               // allow(updatedInput, updatedPermissions, classification) | deny(message, interrupt, classification)
  case dialog(DialogAnswer)                       // completed(result: JSONValue) | cancelled
  case elicitation(ElicitationAnswer)             // accept(content) | decline | cancel
  case hookContinue(HookOutput)                   // .empty by default
  case mcpResponse(JSONRPCMessage)                // carried under response.mcp_response
  case error(String)
}
```

`PermissionResult`, `PermissionUpdate` (with `destination ∈ {userSettings,
projectSettings, localSettings, session, cliArg}`) and `PermissionMode` follow the
typings exactly, because FleetKit's card answer mapping (§8.4, binding) is written in
those terms.

**Outbound requests** are typed specs: `protocol ControlRequestSpec: Sendable {
associatedtype Response: Decodable & Sendable; static var subtype: String { get }; var
payload: JSONValue { get } }`, one struct per row of the parent's §6.4 outbound table
(`Interrupt`, `SetPermissionMode`, `SetModel`, `ListModels`, `SetMaxThinkingTokens`,
`ApplyFlagSettings`, `RenameSession`, `SetCwd`, `GetSettings`, `ClaudeAuthenticate`,
`ClaudeOAuthCallback`, `ClaudeOAuthWaitForCompletion`, `MCPAuthenticate`,
`MCPOAuthCallbackURL`, `MCPClearAuth`, `RewindConversation`, `RewindFiles`,
`GetContextUsage`, `GetSessionCost`, `GetUsage`, `GetBinaryVersion`, `StopTask`,
`BackgroundTasks`, `SideQuestion`, `FileSuggestions`, `MCPStatus`, `MCPSetServers`,
`MCPReconnect`, `MCPToggle`, `ReloadSkills`, `ReloadPlugins`, `EndSession`,
`GenerateSessionTitle`, `UpdateSettings`, `MCPCall`), plus `RawControlRequest(subtype:,
payload:)` whose response is `JSONValue`, for probes and for subtypes a newer CLI adds
before the models catch up. `Interrupt.Response` carries `still_queued` and
`cancelled`, both optional.

**`UserInput` and `ShellEnvelope`.** `UserInput(text:, images:)` becomes the §6.6 user
frame: client-minted `uuid`, `parent_tool_use_id: null`, `origin: {kind: "human"}`,
content as a string or text and image blocks. `ShellEnvelope.wrap(command:, stdout:,
stderr:)` is a pure function implementing §6.6's neutraliser in full — the tag list,
the turn-marker escape, the forged-prefix defusal, U+FFFD replacement, the 64 KiB per
stream cap with its notice, separate elements — and lives here so C4 and C6 call one
implementation; its test fixture is the adversarial output of parent item 60.

### `WireTransport`: `ClaudeProcess` (contract X3, owned)

**One instance, one process, one epoch.** A `ClaudeProcess` is created for exactly one
spawn with the epoch FleetKit assigns; it cannot be respawned. Respawn and quiescent
restart create a new instance with a higher epoch, so "discard events from a superseded
process" is a comparison on `ProcessEpoch`, never a flag.

```swift
public struct ProcessEpoch: Hashable, Comparable, Codable, Sendable { public let rawValue: UInt64 }

public struct LaunchConfiguration: Hashable, Sendable {
  public var binary: URL
  public var cwd: URL
  public var session: SessionStart                 // .new(SessionID) | .resume(SessionID, fork: Bool)
  public var model: String?
  public var permissionMode: PermissionMode?
  public var agent: String?
  public var effort: String?
  public var name: String?
  public var addDirectories: [URL]
  public var worktree: Worktree?                   // .unnamed | .named(String)
  public var allowBypass: Bool                     // --allow-dangerously-skip-permissions
  public var promptSuggestions: Bool
  public var settingSources: [SettingSource]?      // nil = CLI default; [] = --setting-sources ""
  public var strictMCPConfig: Bool
  public var environment: ChildEnvironmentOptions  // forkSubagents = true, automodeDecisionLog = false, questionPreviewFormat: String? = nil
  public func arguments() -> [String]              // §6.1, fixed order
  public func childEnvironment(over base: ResolvedEnvironment) -> [String: String]  // §6.1 table applied; REMOTE, CONTAINER_ID, ENTRYPOINT removed
}

public struct InitializeConfiguration: Hashable, Sendable {  // §6.2, defaults are the parent's payload
  public var supportedDialogKinds: [String]
  public var perTaskStopAffordance: Bool
  public var agentProgressSummaries: Bool
  public var sdkMcpServers: [String]
  public var hooks: [HookEvent: [HookCallbackMatcher]]
  public func payload() -> JSONValue
}

public enum WireEvent: Sendable {
  case handshakeCompleted(Handshake, ProcessEpoch)
  case frame(Frame, ProcessEpoch)
  case request(InboundRequest)                     // needs an answer from above
  case requestCancelled(RequestID, ProcessEpoch)   // control_cancel_request arrived
  case policyAnswered(InboundRequest, error: String)   // answered by InboundPolicy, shown as opaque item
  case unansweredDialog(InboundRequest)            // undeclared kind, left for the CLI's deadline
  case hostToolInvoked(HostToolInvocation, ProcessEpoch)  // e.g. send_user_file(files, caption)
  case stderr(String, ProcessEpoch)
  case exited(ExitStatus, ProcessEpoch)            // code or signal, stderr tail
}

public struct Handshake: Sendable {
  public let initialize: InitializeResponse        // commands, agents, models, output styles, account, current model and mode, session_state, pid
  public let systemInit: SystemInit                // tools, skills, plugins, agents, slash_commands, mcp_servers, capabilities, version, apiKeySource, messaging_socket_path
  public let pending: [InboundRequest]             // re-armed once from pending_permission_requests and pending_user_dialog_requests
}

public actor ClaudeProcess {
  public init(epoch: ProcessEpoch, launch: LaunchConfiguration, environment: ResolvedEnvironment,
              configHome: ConfigHome, initialize: InitializeConfiguration = .init(),
              policy: InboundPolicy = .default, mcpServer: AfleetMCPServer,
              diagnostics: any DiagnosticsSink, capture: RawCapture?)
  public nonisolated let events: AsyncStream<WireEvent>
  public func spawn() async throws -> Handshake    // launches, writes initialize, waits ≤ 30 s for its response and system/init
  public func send(_ input: UserInput) async throws -> UUID
  public func send(raw frame: JSONValue) async throws
  public func request<R: ControlRequestSpec>(_ request: R, timeout: Duration? = nil) async throws -> R.Response
  public func requestRaw(subtype: String, payload: JSONValue, timeout: Duration? = nil) async throws -> JSONValue
  public func cancel(_ id: RequestID) async         // sends control_cancel_request for an outbound request
  public func answer(_ id: RequestID, _ answer: InboundAnswer) async throws
  public func terminate() async                    // §6.7 sequence
  public var status: ProcessStatus { get }         // launching, handshaking, running, terminating, exited(ExitStatus)
}
```

**Correlation.** Outbound `request_id`s are UUID strings; a pending map resolves the
matching `control_response` into the spec's `Response` or throws
`WireError.controlError(message)` on `subtype: error`. There is no default deadline,
because the transport has none and `side_question` legitimately runs for minutes; a
caller may pass one, and Swift task cancellation sends `control_cancel_request` for the
abortable subtypes (`side_question`, `mcp_call`) and simply forgets the others. Inbound
requests enter a pending table keyed by `request_id`; `answer()` writes the
`control_response` and removes them; a `control_cancel_request` removes them and emits
`.requestCancelled`; process exit drops the table, and the event stream ends after
`.exited`. `WireError.processExited` is thrown for any send after exit.

**`InboundPolicy`** is the §6.3 rule as data: `unknownSubtype → .errorImmediately`,
`malformedKnown → .errorNamingField`, `undeclaredDialog → .leaveUnanswered`, and the set
of declared dialog kinds it reads from `InitializeConfiguration`. `hook_callback` for a
callback id the host did not register is answered with an empty continue and logged,
per the parent's §6.4 row; registered ids are surfaced as `.request` for FleetKit to
act on and then answer. `mcp_message` never reaches FleetKit: the transport routes it to
the `AfleetMCPServer` actor and answers with `mcp_response` itself, emitting
`.hostToolInvoked` when a tool call had a host-side effect.

**Transport mechanics.** `Process` with three pipes; a stdin writer task fed by an
`AsyncStream<Data>` that serialises writes and surfaces `EPIPE` as the crash path; a
stdout reader that splits on `\n`, tolerates a final unterminated line at exit, and
hands each line to the decoder and the raw tap; a stderr reader into a 64 KiB ring
whose tail rides `.exited`; `keep_alive` frames reset an inactivity timer used only for
diagnostics. `events` buffers without dropping (frames are never dropped), which is
safe because the consumer is FleetKit's reducer, not a UI. `spawn()` fails with
`WireError.handshakeTimeout(stderrTail:)` after 30 s, or `WireError.launchFailed` when
the binary cannot be executed.

**`terminate()`**: write `end_session` as a control request without awaiting its
response beyond the wait window, close stdin, wait up to five seconds for exit, then
SIGTERM; the instance is then `exited`. The parent's sequence stops at SIGTERM; a
SIGKILL five seconds later is proposed below, not assumed.

### `WireMCP`: the in-process server

A minimal JSON-RPC 2.0 codec (`JSONRPCMessage` = request, notification, response,
error) and an `AfleetMCPServer` actor that implements `initialize`,
`notifications/initialized`, `ping`, `tools/list` and `tools/call` for a registry of
`MCPTool`s. It is transport-agnostic: `handle(_ message: JSONRPCMessage) async ->
JSONRPCMessage?` returns the reply (or nil for notifications), and `ClaudeProcess`
carries replies back under `response.mcp_response`. Server info is `afleet` with the
app's version; capabilities declare tools only. `SendUserFileTool` has input schema
`{files: [string], caption?: string}`; it resolves each path against the channel's cwd,
requires that the file exists and is readable, returns a text result naming the files
sent, and reports a `HostToolInvocation.sentFile(paths:, caption:)` that FleetKit turns
into the sent-file item. Later tools register the same way. No MCP SDK dependency: the
five methods are a few hundred lines, and the control-frame carriage does not fit any
SDK's transport abstraction.

### `WireEnvironment`: environment, ConfigHome, binary, version

`EnvironmentResolver.resolve(shell:timeout:)` runs `$SHELL -l -i -c 'env -0'` with stdin
from `/dev/null`, a pseudo-`TERM` of `dumb`, and a five-second timeout; on timeout or a
non-zero exit it retries with `-l -c`; if that fails too it returns the app's own
environment tagged `.processFallback` so the app can warn rather than refuse to start.
Parsing takes only NUL-separated tokens matching `^[A-Za-z_][A-Za-z0-9_]*=`, which
skips banners an interactive rc file may print, and records `capturedAt`, the shell and
the mode. The resolver is a `Sendable` value with an injectable process runner so the
banner, timeout and fallback paths are unit-tested with scripted shells.

`ConfigHome.derive(from:)` implements §6.9: `CLAUDE_CONFIG_DIR` from the captured
variables when set (tilde-expanded, standardised, source `.environment`), else
`<captured HOME>/.claude` (source `.default`); `CLAUDE_CODE_PROJECT_DIR_NAME` is kept
only alongside an environment-sourced root. `BinaryLocator.locate(in:override:)`
returns the settings override when present, else the first executable `claude` on the
captured PATH, else `~/.local/bin/claude` if executable, else nil (the onboarding
screen's trigger). `VersionGate.check(binary:)` runs `claude --version`, parses the
leading dotted version, and returns `.accepted(installed)`, `.tooOld(installed,
baseline)` or `.unparseable(output)`; `ProtocolBaseline.version` is `2.1.259` and is
the single constant C1's census and the Settings screen also read. Newer versions are
accepted; capability tokens from `SystemInit.capabilities` are exposed as a `Set<String>`
for feature gating, never compared as versions.

### `WireDiagnostics`: metadata log and opt-in capture

`DiagnosticsSink` receives `DiagnosticEvent`s: per frame the direction, type, subtype,
byte size, epoch and request id; per inbound answer the behaviour and classification
without payload; process lifecycle and handshake timings. `FileDiagnostics` appends JSON
lines to `~/Library/Logs/afleet/diagnostics.log` and rotates at 25 MB into one
predecessor, keeping the parent's 50 MB budget. `RawCapture` is created only when the
Developer setting is on; it writes redacted lines to
`capture/<configHomeHash>/<session-id>.ndjson` (`configHomeHash` = first twelve hex
characters of SHA-256 over the ConfigHome path) under a 0700 directory as 0600 files,
enforces the 200 MB budget oldest-first, and exposes `prune(keeping: Set<SessionID>)`
for FleetKit to call when a transcript disappears. `Redactor` is structural: it parses
the line, removes account fields and whole `update_environment_variables` frames,
replaces the value of any key whose name contains `token`, `oauth`, `key` or `secret`
(case-insensitive) with `"<redacted>"`, truncates MCP JSON-RPC bodies to 4 KB, and
re-serialises; a line that does not parse is not captured and is counted in
diagnostics. Redaction happens before any write, so the on-disk file never holds an
unredacted byte (§11, X9).

### Tests before C1's fixtures exist

`ClaudeWire/Tests/Support/scripted-claude.py` is a protocol stand-in for transport tests,
not a fixture player: it answers `initialize`, echoes user frames as `assistant` frames,
and takes scenario flags to emit an unknown control subtype, a malformed `can_use_tool`,
a declared and an undeclared `request_user_dialog`, a `control_cancel_request`, to ignore
`end_session`, to exit with a chosen code, and to print stderr. G1 runs against it.
Frame-model tests use hand-written samples for every modelled type, drawn from the
parity evidence's captured frames and the bundle spec. When C1's `fake-claude` and
`Fixtures/` land, G2 replaces the samples with the corpus and the stand-in stays for the
scenarios a recording cannot produce. Live tests (G3) are one XCTest class tagged by the
`AFLEET_LIVE_CLI` environment variable, spawn in a fresh temporary directory so the
CLI's own transcript lands under a disposable project slug, pass `--setting-sources ""`
so the user's hooks and MCP servers stay out, and cost one short model turn per run.

### `Tools/fetch-typings.sh`

`npm pack @anthropic-ai/claude-agent-sdk@0.3.259 --pack-destination .typings/` and an
extraction into `.typings/package/`; `.typings/` joins `.gitignore`. The optional drift
test `TypingsDriftTests` reads `.typings/package/sdk.d.ts`, extracts the discriminant
literals and top-level keys per message type with a regular-expression pass (no
TypeScript toolchain), compares them with the Swift models' `CodingKeys`, and is skipped
with `XCTSkip` when the directory is absent, so CI and fresh checkouts stay green and
nothing derived from the typings is ever committed.

## Contracts

**Owned by C2.** X2 `AfleetCore` value types, exactly the shapes above. X3 Wire API,
exactly `ClaudeProcess`, `LaunchConfiguration`, `InitializeConfiguration`, `WireEvent`,
`InboundRequest`, `InboundAnswer`, `ControlRequestSpec` and `Frame` as written here.
X11 Environment injection: `ResolvedEnvironment` is captured once per app launch by
`EnvironmentResolver`, and `LaunchConfiguration.childEnvironment(over:)` is the only
place the child environment is composed; Workbench and the app receive the same value
and add nothing.

**Bound by C2.** X1: `ClaudeWire` depends on `AfleetCore` alone, enforced by
`Package.swift` and a test that greps `import` statements. X8: `ClaudeProcess` needs no
knowledge of `fake-claude`; a `LaunchConfiguration` whose `binary` points at
`Tools/fake-claude` runs it unchanged, and G2 reads fixtures in X8's NDJSON form. X9:
nothing in these packages writes under `ConfigHome.root`; `RawCapture` writes only
under the parent's owned-files table; typings are fetched, never committed;
`CLAUDE_CODE_ENTRYPOINT` is stripped from the child environment.

## Delegated unknowns

None of the parent's spikes are assigned to C2. C2 consumes: S5's mechanism is G3 here;
S8's request and response shapes are pinned by C1's fixtures and until then are modelled
from the bundle source and parity evidence; S14's `--session-mirror` frames are modelled
as `TranscriptMirrorFrame` and their primacy is C3's concern. One empirical unknown is
C2's own: whether `-l -i -c` under the user's zsh configuration completes inside five
seconds on a cold start; the resolver's fallback ladder makes either outcome
non-fatal, and the measured time is logged in diagnostics.

## Parent revisions to file at merge

Revision Notes on the parent, per its X2 rule for additions and the child's duty to
report overturned advisory content: `DiffRef` defined as above; `ChannelOrigin`'s
sub-states enumerated as above; `.typings/` added to `.gitignore`; and, if approved
below, SIGKILL appended to §6.7's sequence.

## Questions for the human gate

1. **SIGKILL after SIGTERM.** §6.7's binding sequence ends at SIGTERM. A binary that
   ignores SIGTERM would leave a zombie that FleetKit's respawn cannot replace.
   Recommendation: SIGKILL five seconds after SIGTERM, filed as a `[parent-impact]`
   note because it extends binding content.
2. **`DiffRef` shape.** The parent names it and leaves it undefined; the shape above
   serves the Source Control panel's three diff kinds. Recommendation: adopt it; C7 may
   extend it with a Revision Note.
3. **Live-CLI tests use the real ConfigHome.** A temporary ConfigHome would need its
   own login. G3 therefore spawns under the user's ConfigHome with `--setting-sources
   ""` in a disposable directory; the CLI writes one transcript there per run.
   Recommendation: accept; it is what the fourteen probes already do.
4. **Packages at the repository root.** `AfleetCore/` and `ClaudeWire/` at the root
   match the parent's `swift test --package-path ClaudeWire`; a `Packages/` folder would
   be tidier but needs the gate reworded. Recommendation: root.
5. **`contended` as an owned sub-state.** X2 lists four origins; the parent's §7.4 has a
   Contended state. Modelling it under `.owned` keeps X2's four cases; C4 may prefer a
   fifth top-level case. Recommendation: sub-state, C4 overturns with a Revision Note
   if the lifecycle code reads better otherwise.

## Decision Log

- Decision: Frame models are hand-written Swift with explicit `CodingKeys`, checked
  against the fixture census (G2) and, optionally, against the fetched typings.
  Rationale: A TypeScript-to-Swift generator would be its own project (unions,
  intersections, generics) and would produce unidiomatic types without the opaque
  fallback, epoch tagging and `JSONValue` seams the design needs; the census already
  catches drift. Rejected: generating Swift from `sdk.d.ts`; a JSON-schema
  intermediate; `AnyCodable`-style untyped frames.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: One `ClaudeProcess` instance per spawn, epoch supplied at init, never
  restarted in place.
  Rationale: Epoch comparison then needs no mutable flag, and every event carries the
  epoch of the process that produced it by construction. Rejected: a restartable actor
  that increments its own epoch.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: Two-stage decoding through `JSONValue` with opaque fallback for one-way
  frames and `.unknown`/`.malformed` payloads for inbound requests.
  Rationale: §6.3 requires that unknown frames are never dropped and unknown requests
  are always answered; a single `Decodable` pass cannot distinguish the two. Rejected:
  decoding straight from bytes with a catch-all.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: Typed `ControlRequestSpec`s plus `RawControlRequest`; no default timeout,
  optional per call; cancellation sends `control_cancel_request` only for abortable
  subtypes.
  Rationale: The transport has no deadline and some requests run for minutes; typed
  specs make the router's rows compile-checked while the raw path keeps probes and new
  subtypes reachable. Rejected: a stringly-typed `request(subtype:)` API only; a
  blanket 30 s timeout.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: `mcp_message` is answered inside ClaudeWire by the `AfleetMCPServer` actor
  with a hand-rolled JSON-RPC codec; host effects surface as `hostToolInvoked`.
  Rationale: Five JSON-RPC methods do not justify an MCP SDK whose transports assume
  sockets or stdio; routing inside the transport keeps the 70 s `mcp_message` bound
  away from FleetKit. Rejected: `modelcontextprotocol/swift-sdk`; surfacing raw
  JSON-RPC to FleetKit.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: Environment capture is interactive-login first with a token filter, then
  login-only, then the process environment, each tagged in `CaptureMode`.
  Rationale: §6.9 wants `.zshrc` to apply, interactive rc files can print, and a failed
  capture must not stop the app from opening history. Rejected: login-only capture;
  failing hard when the shell hangs.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: Binary lookup order is settings override, PATH from the captured
  environment, `~/.local/bin/claude`.
  Rationale: PATH is what the terminal runs; the parent names `~/.local/bin/claude`
  as the known install location, kept as the fallback. Rejected: the fixed path first.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: Redaction is structural and precedes every write; unparseable lines are not
  captured.
  Rationale: Regex redaction over raw text misses nested fields and can corrupt JSON;
  the capture exists to make fixtures, which must parse anyway. Rejected: text-level
  redaction; capture-then-redact.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: A scripted Python stand-in for transport tests until C1's `fake-claude`
  lands; live tests behind `AFLEET_LIVE_CLI=1`.
  Rationale: G1 must be provable in wave 1 without fixtures, and scenarios such as
  ignoring `end_session` cannot be recorded. Rejected: waiting for C1; mocking `Process`
  entirely.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: ClaudeWire is five single-purpose modules under one umbrella product;
  AfleetCore is one module.
  Rationale: §5 asks for small targets; consumers import `ClaudeWire` once. Rejected:
  one flat module; a package per module.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: `ShellEnvelope` lives in `WireFrames`.
  Rationale: The neutraliser is protocol text that two upper children would otherwise
  each implement. Rejected: FleetKit's router owning it; duplicating it in the composer.
  Date/Author: 2026-09-04 / Claude for kimmi

## Surprises & Discoveries

- Observation: The `initialize` response can carry in-flight requests.
  Evidence: `ControlResponse.pending_permission_requests` and
  `pending_user_dialog_requests` in `sdk.d.ts` 0.3.259, documented as re-arming a client
  that joins an initialised session. Impact: `Handshake.pending` re-arms them once and
  tolerates the same `request_id` arriving again as a live frame.
- Observation: macOS's BSD `env` accepts `-0`.
  Evidence: `/usr/bin/env -0` on macOS 26.5.2 prints NUL-separated pairs. Impact: §6.9's
  capture needs no GNU tool.
- Observation: `interrupt` has a receipt only on CLIs advertising `interrupt_receipt_v1`.
  Evidence: the `interrupt()` doc comment and `SDKControlInterruptRequest` in the
  typings. Impact: `Interrupt.Response` fields are optional and FleetKit's `still_queued`
  handling gates on the capability token.

## Outcomes & Retrospective

Pending — written at finish.

## Revision Notes

- 2026-09-04: v1, written at dispatch against parent commit `9fd067c`.
