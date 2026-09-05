# C2: `AfleetCore` and `ClaudeWire` (2026-09-04)

> **Parent:** `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C2`.
> **Parent-pin:** that path at commit `9fd067c` ("Spec: §6.10 counts the fourteen probe
> scripts"). **Level name:** child, wave 1 of the v1 roadmap. **Track:** controlled.
> **Branch:** `child/c2-core-wire`, worktree `../afleet-c2`; merges to `main` when G1, G3
> and G4 pass. G2 is blocked by C1.G1: it becomes evaluable when that gate lands, the child
> may merge with it pending, marked in the parent's tracking map (parent §17.6), and a later
> failure is a corrective task on C2 flagged to C3 and C4. This document treats the parent's
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
  seconds for exit, sends SIGTERM, waits up to five seconds more, sends SIGKILL, and
  emits `.exited` only once the process exit is observed, in that order, observed
  against one scripted stand-in that ignores `end_session` and another that ignores
  both `end_session` and SIGTERM (§6.7 as amended on `main`); the in-process MCP server
  answers the full sequence `initialize`, `notifications/initialized` (acknowledged as
  `mcp_response {jsonrpc: "2.0", result: {}, id: 0}`), `ping`, `tools/list`,
  `tools/call`, an unknown method (JSON-RPC error `-32601`) and a cancelled call; with
  the event consumer suspended and a stand-in emitting frames faster than they are
  drained, no frame is lost, the stand-in blocks on its pipe and resident memory stays
  under the buffer bound; every frame that decoded as a typed frame before redaction
  decodes to the same typed case after it; and `Tests/ConsumerSmoke`, a separate package
  that imports only `ClaudeWire`, builds and constructs every X3 value through public
  initialisers.
- **G2 (required, blocked-by C1.G1) — nothing known is lost, nothing unknown is
  dropped.** For every fixture in `Fixtures/`, every NDJSON line decodes to a `Frame`;
  re-encoding a decoded known frame reproduces every key the fixture line had, with
  equal values; lines whose `type` or `subtype` is not modelled decode to
  `Frame.opaque` carrying the raw line and a parsed `JSONValue`; the count of opaque
  frames per fixture equals the census's count of unmodelled types. This is the
  ClaudeWire half of the parent's acceptance item 36. The gate is evaluable when C1.G1
  lands with its complete catalogue; until then the hand-written samples and the stand-in
  are development aids, not evidence, and the child may merge with G2 pending, marked in
  the parent's tracking map; a later failure is a corrective task on C2 flagged to C3
  and C4 (parent §17.6).
- **G3 (required) — it works against the installed CLI.** With `AFLEET_LIVE_CLI=1`, a
  test spawns `claude` 2.1.259 with `CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home`,
  the scratch config home the user logged into once by hand (gate decision 2026-09-04),
  in a working directory created under the system temporary directory, with
  `--setting-sources ""`; it diffs the scratch config home before and after and asserts
  that the only changes are files the spawned `claude` wrote (its transcript, registry
  record and `.claude.json`), nothing created by the test; it completes the handshake,
  sees `mcp__afleet__send_user_file`
  in the first turn's `system/init.tools` observed on the event stream, asks the model to send a
  file and receives the
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
  Sources/WireFrames/      JSONValue, JSONRPCMessage, ProcessEpoch, RequestID, Frame and
                           every typed frame, inbound request and answer shapes, outbound
                           request specs, ShellEnvelope
  Sources/WireTransport/   ClaudeProcess, LaunchConfiguration, InitializeConfiguration,
                           correlation, InboundPolicy, exit observation
  Sources/WireMCP/         AfleetMCPServer, MCPTool, SendUserFileTool (the JSON-RPC value
                           type lives in WireFrames)
  Sources/WireEnvironment/ EnvironmentResolver, ConfigHome derivation, BinaryLocator,
                           VersionGate, ProtocolBaseline
  Sources/WireDiagnostics/ DiagnosticsSink, FileDiagnostics, RawCapture, Redactor
  Sources/ClaudeWire/      @_exported imports of the five modules
  Tests/<Module>Tests/     one test target per module
  Tests/Support/           scripted-claude.py and hand-written frame samples
  Tests/ConsumerSmoke/     a separate SwiftPM package that imports only ClaudeWire and
                           constructs every X3 value (G1)
Tools/fetch-typings.sh
```

Module dependency order inside ClaudeWire: `WireFrames` depends on `AfleetCore` alone;
`WireMCP`, `WireEnvironment` and `WireDiagnostics` depend on `WireFrames` only;
`WireTransport` depends on all four. `InboundRequest` and `InboundAnswer` are
`WireFrames` types and reference only `WireFrames` types, which is why `ProcessEpoch`,
`RequestID` and `JSONRPCMessage` live there rather than in the transport or MCP modules:
nothing imports upward, and G1 proves it by building the manifests together with
`Tests/ConsumerSmoke`. No module imports anything outside `AfleetCore` and Foundation.
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

`OwnedState` and `ForeignHost` enumerate the states named in the parent's §7.4 table;
`contended` is modelled as an owned sub-state rather than a fifth origin (gate decision
2026-09-04), which C4 may overturn with a Revision Note if its lifecycle code reads
better otherwise. `DiffRef` is adopted (gate decision 2026-09-04) as the X2 addition the
parent's §9.6 names without defining; it is filed on the parent at merge (see Parent
revisions below). Every type here has a public memberwise initialiser. `AfleetCore` has
no I/O, no dependencies and no functions beyond initialisers and string conversion.

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
`subtype` strings select the model; the typed model is then decoded by `JSONDecoder` from
the same bytes (a `JSONValue`-backed `Decoder` would buy nothing observable), and every
typed model keeps its undeclared keys in an `additional` bag so re-encoding is lossless. Any failure
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
// All of these are WireFrames types; ProcessEpoch and JSONRPCMessage are defined there too.
public struct RequestID: Hashable, Sendable { public let rawValue: String; public init(rawValue: String) }
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

**`Handshake.pending` is a wire fact; nothing renders from it.** It is the engine's own
report, recorded verbatim, of the requests it re-arms inside the initialize response. The
only surface a consumer may render prompts from is the event stream: the engine re-sends
each of those as a live `control_request` right after the handshake, they pass through the
inbound policy like any other, and only the ones policy surfaces become request events. A
consumer that reads this array to display prompts is not resolving an ambiguity in the
contract, it is violating the contract — it will double-show a prompt the stream is also
delivering, or show one the policy already answered on its behalf.

**One instance, one process, one epoch.** A `ClaudeProcess` is created for exactly one
spawn with the epoch FleetKit assigns; it cannot be respawned. Respawn and quiescent
restart create a new instance with a higher epoch, so "discard events from a superseded
process" is a comparison on `ProcessEpoch`, never a flag.

```swift
public struct ProcessEpoch: Hashable, Comparable, Codable, Sendable {   // defined in WireFrames
  public let rawValue: UInt64
  public init(rawValue: UInt64)
  public static let first: ProcessEpoch                // rawValue 1
  public func next() -> ProcessEpoch                   // rawValue + 1; FleetKit owns the progression
}

public enum SessionStart: Hashable, Sendable { case new(SessionID), resume(SessionID, fork: Bool) }
public struct ChildEnvironmentOptions: Hashable, Sendable {
  public var forkSubagents: Bool, automodeDecisionLog: Bool, questionPreviewFormat: String?
  public init(forkSubagents: Bool = true, automodeDecisionLog: Bool = false, questionPreviewFormat: String? = nil)
}

public struct LaunchConfiguration: Hashable, Sendable {
  public init(binary: URL, cwd: URL, session: SessionStart, model: String? = nil,
              permissionMode: PermissionMode? = nil, agent: String? = nil, effort: String? = nil,
              name: String? = nil, addDirectories: [URL] = [], worktree: Worktree? = nil,
              allowBypass: Bool = false, promptSuggestions: Bool = false,
              settingSources: [SettingSource]? = nil, strictMCPConfig: Bool = false,
              environment: ChildEnvironmentOptions = .init())
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
  public var configHomeOverride: URL?              // tests and C1 recordings only: sets CLAUDE_CONFIG_DIR in the child; FleetKit never sets it (§6.9)
  public func arguments() -> [String]              // §6.1, fixed order
  public func childEnvironment(over base: ResolvedEnvironment) -> [String: String]  // §6.1 table applied; REMOTE, CONTAINER_ID, ENTRYPOINT removed
}

public struct InitializeConfiguration: Hashable, Sendable {  // §6.2, defaults are the parent's payload
  public init(supportedDialogKinds: [String] = ["refusal_fallback_prompt", "fable_overage_consent_prompt"],
              perTaskStopAffordance: Bool = true, agentProgressSummaries: Bool = true,
              sdkMcpServers: [String] = ["afleet"],
              hooks: [HookEvent: [HookCallbackMatcher]] = .afleetDefaults)  // Notification + ConfigChange
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
  public let pending: [InboundRequest]             // re-armed once from pending_permission_requests and pending_user_dialog_requests
}

public actor ClaudeProcess {
  public init(epoch: ProcessEpoch, launch: LaunchConfiguration, environment: ResolvedEnvironment,
              configHome: ConfigHome, initialize: InitializeConfiguration = .init(),
              policy: InboundPolicy? = nil,      // nil derives the §6.3 policy from `initialize` (declared kinds, registered hook ids)
              mcpServer: AfleetMCPServer, diagnostics: any DiagnosticsSink, capture: RawCapture?,
              eventBufferCapacity: Int = 4096)
  public nonisolated let events: WireEventStream<WireEvent>   // an AsyncSequence over a bounded, lossless channel; iterate with for await
  public func spawn(handshakeTimeout: Duration = .seconds(30)) async throws -> Handshake  // launches, writes initialize, waits for its response only
  public func send(_ input: UserInput) async throws -> UUID
  public func send(raw frame: JSONValue) async throws
  public func request<R: ControlRequestSpec>(_ request: R, timeout: Duration? = nil) async throws -> R.Response
  public func requestRaw(subtype: String, payload: JSONValue, timeout: Duration? = nil) async throws -> JSONValue
  public func cancel(_ id: RequestID) async         // sends control_cancel_request for an outbound request
  public func answer(_ id: RequestID, _ answer: InboundAnswer) async throws
  public func terminate() async                    // §6.7 sequence; returns only after the exit is observed
  public var status: ProcessStatus { get }         // launching, handshaking, running, terminating, exited(ExitStatus)
}
```

Every value a downstream package constructs has a public initialiser above; Swift's
synthesised memberwise initialisers are internal, so none of X3 relies on them.

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
`.hostToolInvoked` when a tool call had a host-side effect. `oauth_token_refresh` and
`host_auth_token_refresh` are deliberately not modelled: the CLI installs those two
inbound requests only when `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH` is set and
`CLAUDE_CODE_ENTRYPOINT` is `claude-desktop`, `local-agent` or `claude-vscode`
(`docs/tui-parity/areas/06-08-02-models-auth-bootstrap.md`, the SDK-driven token refresh
row), and afleet sets neither. Should one ever arrive, the unknown-subtype error is the
correct decline: the CLI refreshes its own stored login, and a host that cannot own the
credential must not pretend to.

**Transport mechanics.** `Process` with three pipes. The stdin side is a bounded queue:
`send` and `request` suspend until their bytes have been written to the pipe, so a
caller cannot outrun the child and `EPIPE` surfaces as the crash path on the call that
hit it. The stdout reader splits on `\n`, tolerates a final unterminated line at exit,
and hands each line to the decoder and the raw tap; `events` is a `WireEventStream`, an
`AsyncSequence` over a bounded lossless channel (4,096 frames by default, configurable at
init); `AsyncStream` cannot suspend its producer, which is why the type is not
`AsyncStream`. When the channel is full the reader stops reading, so the CLI blocks on its
own pipe write. Nothing is ever dropped and
memory is bounded; the cost is that a stalled consumer pauses the engine, which is the
right failure for a reducer that drains a frame in microseconds and is the failure the
stress test in G1 provokes on purpose. There is no disk spool. A stderr reader fills a
64 KiB ring whose tail rides `.exited`; `keep_alive` frames reset an inactivity timer
used only for diagnostics. `spawn()` fails with `WireError.handshakeTimeout(stderrTail:)`
after 30 s, or `WireError.launchFailed` when the binary cannot be executed.

**`terminate()`**: write `end_session` as a control request without awaiting its
response beyond the wait window, close stdin, wait up to five seconds for the process
to exit, send SIGTERM, wait up to five seconds more, send SIGKILL. `status` stays
`.terminating` until `Process` reports termination, and `.exited` is emitted only on
that observation, never on a timer, so FleetKit's handoff, ownership release and
respawn always wait on a real exit and two holders can never coexist because a child
ignored a signal. Each escalation step is a diagnostic event (`terminateEscalated`
with the step reached); a SIGKILLed child reports signal 9. The steps are
`never_launched`, `end_session`, `stdin_close_requested`,
`graceful_phase_deadline_exceeded`, `no_live_child_to_signal`, `SIGTERM`, `SIGKILL` and
`exit_not_observed`. `stdin_close_requested` is named for the request rather than the
result: the writer serialises on one queue, so when the `end_session` write is parked on
a pipe the child has stopped reading, the close is queued behind it and the descriptor is
still open at that moment. `graceful_phase_deadline_exceeded` says the five-second
graceful budget ran out with the write and close still outstanding, and the escalation
went on anyway. `exit_not_observed` says the escalation is exhausted and no exit was
seen; `terminate()` returns `nil`, `status` stays `.terminating`, and the event stream is
left open, because it ends only on an observed exit and this layer does not synthesise
one. This is the parent's §6.7 sequence as amended on `main` on 2026-09-04 (gate
decision: SIGKILL accepted).

The lifecycle notice `mcp_delivery_abandoned` (reasons `cancelled` and `write_failed`)
records an `mcp_message` answer that was composed but never reached the engine, so a
delivery event is only ever emitted for a delivery that happened. The parent deliberately
does not enumerate lifecycle notices — its constraint is on the structural fields every
diagnostic line carries, which these satisfy — so the vocabulary lives here.

### `WireMCP`: the in-process server

A minimal JSON-RPC 2.0 codec (`JSONRPCMessage` = request, notification, response,
error) and an `AfleetMCPServer` actor that implements `initialize`,
`notifications/initialized`, `ping`, `tools/list` and `tools/call` for a registry of
`MCPTool`s. It is transport-agnostic: `handle(_ message: JSONRPCMessage) async ->
MCPReply`, where `MCPReply` is `.response(JSONRPCMessage)` for a request and
`.notificationAck` for a notification. `ClaudeProcess` carries a response back under
`response.mcp_response` and encodes a notification acknowledgement as `mcp_response:
{"jsonrpc": "2.0", "result": {}, "id": 0}`, because every `mcp_message` arrives inside a
`control_request` that must be answered: the pinned SDK answers non-request messages
exactly that way (`sdk.mjs` 0.3.259, the `mcp_message` branch) and the CLI's own schema
describes the field as "for a JSON-RPC notification, a response with an empty result".
An unknown method answers JSON-RPC error `-32601`; `notifications/cancelled` is
acknowledged and cancels the named in-flight tool call's task. Server info is `afleet`
with the app's version; capabilities declare tools only. `SendUserFileTool` has the parent's §6.8 schema,
`{files: [string], caption?: string, status: "normal" | "proactive", display?: "render" |
"attach"}` with `files` and `status` required, mirroring the built-in tool so the model's
prompt-trained behaviour transfers; it resolves each path against the channel's cwd
(absolute paths are taken as given, anywhere the file is readable, which is the built-in
tool's domain and the model's own Read reach), requires that the file exists and is
readable, returns a text result naming the files sent, and reports a
`HostToolInvocation.sentFile(paths:, caption:, status:, display:)` that FleetKit turns
into the sent-file item. A tool call whose arguments fail the schema is a JSON-RPC
`-32602`; a runtime failure such as an unreadable file is an `isError` result. Later tools register the same way. No MCP SDK dependency: the
five methods are a few hundred lines, and the control-frame carriage does not fit any
SDK's transport abstraction.

### `WireEnvironment`: environment, ConfigHome, binary, version

`EnvironmentResolver.resolve(shell:timeout:)` runs `$SHELL -l -i -c 'printf
"__AFLEET_ENV__\0"; env -0'` with stdin from `/dev/null`, a pseudo-`TERM` of `dumb`, and
a five-second timeout; on timeout or a non-zero exit it retries with `-l -c`; if that
fails too it returns the app's own environment tagged `.processFallback` so the app can
warn rather than refuse to start. Parsing discards every byte up to and including the
first `__AFLEET_ENV__` NUL-terminated sentinel, so a banner an interactive rc file
prints cannot fuse with the first variable, then splits the remainder on NUL and keeps
tokens matching `^[A-Za-z_][A-Za-z0-9_]*=`; a missing sentinel counts as a failed
capture and falls through the ladder. It records `capturedAt`, the shell and the mode.
The resolver is a `Sendable` value with an injectable process runner; the unit tests
cover a banner with `PATH` as the first variable, a banner with `CLAUDE_CONFIG_DIR`
first, a banner without a trailing newline, the timeout and the fallback paths.

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
replaces the value of any **string-valued** field whose name contains `token`, `oauth`,
`key` or `secret` (case-insensitive) with `"<redacted>"`, leaving numbers, booleans,
arrays and objects untouched and exempting the usage counters by exact name
(`input_tokens`, `output_tokens`, `cache_read_input_tokens`,
`cache_creation_input_tokens`, `thinking_tokens`, `max_tokens`, `tokens`); credential
paths that are known are matched by path as well (`account.*`, any `access_token`,
`refresh_token`, `authorization`, `oauth*`). It truncates MCP JSON-RPC bodies to 4 KB and
re-serialises; a line that does not parse is not captured and is counted in
diagnostics. Redaction happens before any write, so the on-disk file never holds an
unredacted byte (§11, X9). The substring rule as the parent first wrote it would have
turned `usage.input_tokens` and its siblings, present in every assistant frame, into
strings and made every redacted assistant frame undecodable; the parent's §11 is
amended on `main` to the string-valued rule, and a test asserts that every frame typed
before redaction decodes to the same typed case after it.

### Tests before C1's fixtures exist

`ClaudeWire/Tests/Support/scripted-claude.py` is a protocol stand-in for transport tests,
not a fixture player: it answers `initialize`, echoes user frames as `assistant` frames,
and takes scenario flags to emit an unknown control subtype, a malformed `can_use_tool`,
a declared and an undeclared `request_user_dialog`, a `control_cancel_request`, to ignore
`end_session`, to ignore both `end_session` and SIGTERM (it traps the signal and keeps
running until SIGKILL), to flood stdout with frames faster than a suspended consumer
drains them, to exit with a chosen code, and to print stderr. G1 runs against it, and
against `Tests/ConsumerSmoke`, the external package that proves the public API is
constructible from outside.
Frame-model tests use hand-written samples for every modelled type, drawn from the
parity evidence's captured frames and the bundle spec. When C1's `fake-claude` and
`Fixtures/` land, G2 replaces the samples with the corpus and the stand-in stays for the
scenarios a recording cannot produce. Live tests (G3) are one XCTest class tagged by the
`AFLEET_LIVE_CLI` environment variable; they set `CLAUDE_CONFIG_DIR` to the scratch
config home at `/tmp/afleet-fixtures/config-home`, which the user logs into once by hand
and which C1's recordings share, spawn in a fresh directory under the system temporary
directory so the CLI's own transcript lands under a disposable project slug inside the
scratch home, pass `--setting-sources ""` so no hook or MCP server joins, diff the
scratch home before and after to prove the test itself created nothing there, and cost
one short model turn per run. The test is skipped with a message naming the login step
when the scratch home has no credentials.

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
`InboundRequest`, `InboundAnswer`, `ControlRequestSpec`, `ProcessEpoch` and `Frame` as
written here, with the public initialisers shown; `Tests/ConsumerSmoke` is the
executable statement of what C3 and C4 may construct.
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

## Parent revisions

Filed on the parent by its tending session on 2026-09-04, listed here for the lineage
check at recomposition: §6.7's `terminate()` sequence gains SIGTERM, a five-second
wait and SIGKILL, with exit reported only when observed; §11's capture redaction rule
reads "string-valued fields named like token, oauth, key or secret, usage counters
exempt"; §17.6 states that a gate blocked by another child's gate is evaluable when that
gate lands and a child may merge with it pending, marked in the tracking map. To file
at merge, under X2's additions rule: `DiffRef` as defined above; `ChannelOrigin`'s
sub-states as enumerated above; `.typings/` in `.gitignore`.

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
- Decision: Environment capture is interactive-login first, behind a NUL-terminated
  sentinel that discards banner output, then login-only, then the process environment,
  each tagged in `CaptureMode`.
  Rationale: §6.9 wants `.zshrc` to apply, interactive rc files can print, a banner
  without a trailing newline would otherwise fuse with the first variable and silently
  drop `PATH` or `CLAUDE_CONFIG_DIR`, and a failed capture must not stop the app from
  opening history. Rejected: login-only capture; filtering tokens by shape alone;
  failing hard when the shell hangs.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: Binary lookup order is settings override, PATH from the captured
  environment, `~/.local/bin/claude`.
  Rationale: PATH is what the terminal runs; the parent names `~/.local/bin/claude`
  as the known install location, kept as the fallback. Rejected: the fixed path first.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: Redaction is structural, applies the name rule to string values only with
  the usage counters exempt and credential paths matched explicitly, precedes every
  write, and is checked by a typed-before-typed-after assertion; unparseable lines are
  not captured.
  Rationale: Regex redaction over raw text misses nested fields and can corrupt JSON;
  the bare substring rule would have rewritten `input_tokens` and its siblings into
  strings and broken every assistant frame's decoding; the capture exists to make
  fixtures, which must both parse and stay typed. Rejected: text-level redaction;
  capture-then-redact; the substring rule as first written (a `[parent-impact]`, now
  amended on `main`).
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: A scripted Python stand-in for transport tests until C1's `fake-claude`
  lands, with scenarios for ignoring `end_session`, ignoring SIGTERM too, and flooding a
  suspended consumer; live tests behind `AFLEET_LIVE_CLI=1` under the scratch config
  home.
  Rationale: G1 must be provable in wave 1 without fixtures, and scenarios such as
  ignoring signals or out-running the reducer cannot be recorded; the scratch home, which
  the user logs into once, keeps test writes out of the real config home and lets the
  test prove by diff that it created nothing there. Rejected: waiting for C1; mocking
  `Process` entirely; spawning under the real config home with isolated settings
  (rejected at the gate, 2026-09-04).
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
- Decision: `ProcessEpoch`, `RequestID` and `JSONRPCMessage` are `WireFrames` types, and
  G1 builds an external consumer package that imports only `ClaudeWire`.
  Rationale: `InboundRequest` carries the epoch and `InboundAnswer` carries a JSON-RPC
  reply; placing those types above `WireFrames` would make the frame module import the
  transport and MCP modules that depend on it, and the package would not build. The
  consumer package is the only proof that the public surface is constructible from
  outside the module. Rejected: moving `InboundRequest` and `InboundAnswer` into
  `WireTransport` (C3 and C4 would then import transport types to read a request);
  trusting synthesised memberwise initialisers, which are internal.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: `terminate()` escalates `end_session`, stdin close, SIGTERM, SIGKILL with
  five-second waits, keeps `.terminating` until the exit is observed, and emits `.exited`
  only then.
  Rationale: A child that ignores SIGTERM would otherwise be reported dead while alive,
  and FleetKit's ownership release or respawn would create two holders of one session
  with concurrent transcript writes. Accepted at the gate as an amendment to the parent's
  §6.7 (2026-09-04). Rejected: reporting `.exited` on the SIGTERM timer; stopping at
  SIGTERM and leaving the zombie to the lifecycle layer.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: JSON-RPC notifications are acknowledged with an outer `mcp_response` of
  `{jsonrpc: "2.0", result: {}, id: 0}`; `handle` returns `MCPReply.notificationAck`.
  Rationale: Every `mcp_message` is a control request that needs a control response; a
  nil reply would leave `notifications/initialized` unanswered and stall the server's
  initialisation. The shape is the pinned SDK's own (`sdk.mjs` 0.3.259) and matches the
  CLI schema's description. Rejected: answering with a success that lacks
  `mcp_response`; not answering.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: Both transport directions are bounded in memory; a full event buffer stops
  the stdout reader so the CLI blocks on its pipe; stdin sends suspend until written.
  Rationale: Frames must never be dropped and memory must never grow without bound; the
  pipe's own backpressure gives both at once, and a paused engine is the right failure
  when the reducer, which drains in microseconds, has stalled. Rejected: an unbounded
  buffer; dropping oldest frames; an ordered disk spool (complexity for a consumer that
  never falls behind in practice).
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: `oauth_token_refresh` and `host_auth_token_refresh` are not modelled.
  Rationale: The CLI installs them only with `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH` and a
  first-party entrypoint, neither of which afleet sets, and the CLI refreshes its own
  login; if one ever arrived, the unknown-subtype error is the correct decline.
  Rejected: typed shapes and host callbacks for a credential the host must not own.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: G2 is evaluable when C1.G1 lands and the child may merge with it pending,
  marked in the parent's tracking map.
  Rationale: Decided at the parent (§17.6): C1's catalogue needs the user's manual login
  and real recording time, and holding all of wave 2 for it costs more than a later
  corrective task on C2, which C3 and C4 are flagged for. Rejected: merging on partial
  fixtures as if G2 had passed; blocking the merge on the complete catalogue.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: Live tests use the scratch config home `/tmp/afleet-fixtures/config-home`,
  logged into once by the user, with the working directory under the system temporary
  directory.
  Rationale: Gate decision 2026-09-04, shared with C1's recordings: nothing test-owned
  is created under any config home, the real history stays clean, and the before-and-
  after diff makes the never-write rule a checked property. Rejected: the real config
  home with isolated settings.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: `AfleetCore/` and `ClaudeWire/` live at the repository root.
  Rationale: Gate decision 2026-09-04; the parent's `swift test --package-path
  ClaudeWire` then reads literally. Rejected: a `Packages/` folder with the gate
  reworded.
  Date/Author: 2026-09-04 / Claude for kimmi
- Decision: `DiffRef` is adopted as defined above; `contended` is an owned sub-state.
  Rationale: Gate decision 2026-09-04. `DiffRef` gives the Source Control panel its three
  diff kinds under X2's additions rule; the sub-state keeps X2's four origins and leaves
  C4 free to overturn it with a Revision Note. Rejected: leaving `DiffRef` undefined for
  C7; a fifth top-level origin.
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
- Observation: The pinned SDK answers a JSON-RPC notification delivered by `mcp_message`
  with a dummy response, `{jsonrpc: "2.0", result: {}, id: 0}`, rather than with nothing.
  Evidence: the `mcp_message` branch of `sdk.mjs` 0.3.259 (`if (r.onmessage)
  r.onmessage(n.message); return {mcp_response: {jsonrpc: "2.0", result: {}, id: 0}}`) and
  the CLI schema text "for a JSON-RPC notification, a response with an empty result".
  Impact: `MCPReply.notificationAck` and its fixed outer encoding.
- Observation: A name-substring redaction rule on `token` hits `usage.input_tokens`,
  `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens` and
  `thinking_tokens`, which every assistant and result frame carries as numbers.
  Evidence: the `usage` object in the parity evidence's captured frames and the typings'
  `NonNullableUsage`. Impact: the rule applies to string values only with the counters
  exempt; the parent's §11 wording is amended on `main`.
- Observation: The two token-refresh inbound requests are entrypoint-gated.
  Evidence: `docs/tui-parity/areas/06-08-02-models-auth-bootstrap.md`, "installed only
  when `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH` is set and `CLAUDE_CODE_ENTRYPOINT` ∈
  {claude-desktop, local-agent, claude-vscode}". Impact: not modelled; the unknown-subtype
  error is the decline if one ever arrives.
- Observation: The extracted bundle's SPEC chapter files under
  `~/claude-code-bundle/2.1.257/SPEC/` were no longer on disk on 2026-09-04; the bundle
  source (`cli.pretty.js`, `modules/`), the fetched SDK package and `docs/tui-parity/`
  remain. Impact: existing SPEC citations in this document are kept as written; new
  citations point at sources that can be opened.

## Outcomes & Retrospective

Measured on 2026-09-05 at `821a259` on `child/c2-core-wire`, seventy-one commits above
`main`. That tip is a history rewrite of the pre-rewrite tip with an identical tree; every
hash quoted in the working ledger before the rewrite is historical and no longer resolves.
Every figure below is an observed output. Where a claim could not be demonstrated by
running something, it says so rather than borrowing the authority of the ones that could.

### The gates

**G1 — passes.** `swift test --package-path ClaudeWire` reports
`Executed 225 tests, with 4 tests skipped and 0 failures (0 unexpected)`, and
`swift test --package-path AfleetCore` reports `Executed 6 tests, with 0 failures
(0 unexpected)`. The four skips are the live tests, which skip without the opt-in
variable. A clean-build run with both build directories deleted was taken two commits
earlier, at the equivalent of `6a370bf`, and reported 224 with the same four skips and no
failures; the single added test is the guard described under G2's neighbour below. The
external consumer package that imports only `ClaudeWire` builds as part of the suite.

One caveat, stated because the number above is a single observation of a suite that is not
perfectly deterministic. Across four consecutive runs at the tip, two were clean, one hit
`ProcessRunnerTests` failing with an exit code of `-1` after an eleven-second stall, and
one aborted with the test bundle missing under `dlopen`. The second is a known flake
already carried as debt with its mechanism diagnosed — a starved `waitUntilExit()` on the
global queue, which returns `-1` — and it is not a test any gate names. The third is not a
test result at all: a clean build was deleting and rebuilding the build directory in the
same worktree while the run was in progress. Neither is a defect in the shipped code, and
neither was discovered by this run: the flake was recorded during the task sequence.

**G2 — passes, and two independent assertions agree on the same ten frames.** The corpus
test reports `18 fixtures (16 recorded, 2 synthetic), 1353 frames (152 in, 1201 out), 1343
round-tripped`. Three fixtures have their counts compared as sets rather than as totals
because their census accumulates across re-recordings. The ten frames that do not
round-trip are exactly the ten in the pinned synthetic-findings set, which is asserted as
an exact set rather than as a count — so a regression in a frame that only a synthetic
fixture represents now fails the build instead of printing to a console. That pinning was
demonstrated by mutating a synthetic fixture in a way that moved a finding from one missing
key to another while the total stayed at ten: a threshold assertion would have passed, and
the set comparison went red naming both keys.

**G3 — passed when run, and its most important limitation is unverified rather than
verified.** The live pass ran under the scratch config home with the opt-in variable set,
completed the handshake, observed the in-process tool in the first turn's tool list, asked
the model to send a file and received the host-invocation event, exercised the version gate
against fabricated and real version strings, and diffed the config home before and after,
finding only files the spawned engine wrote. Nothing was created under the user's own
config home. The limitation: the handshake test's real difference was a single modified
path, so the write allowlist rests almost entirely on one turn's writes and is untested
against hooks, plugins, background shells, editor integration, subagents and session
relocation. That is the most consequential thing this child did not establish.

**G4 — passes.** `git ls-files` matches nothing under the typings directory, nothing under
`node_modules/`, and no `*.d.ts`. The drift test that reads the typings skips rather than
fails when the directory is absent, which was verified by parking the directory.

### What the review rounds and waves changed

The fourteen planned tasks were each executed, reviewed by an independent reviewer, fixed
and re-reviewed. That sequence found roughly twenty-one defects in the plan and spec
themselves, including several that would have shipped: a JSON-RPC identifier that could not
be mapped being classified as a notification, producing a silent hang; a timeout that did
not bound the operation it named; a termination path that, called before launch, would have
signalled the whole process group; and five wrong wire key names taken from a schema rather
than from a recording.

Because the finished diff ran to 142 files, the branch then went to a six-lens review panel
rather than a single reviewer. It returned thirty-two findings — sixteen at the top
priority — and independently rediscovered both findings an earlier adversarial pass had
found by hand. **Every one of the thirty-two held at the code; none was dismissed as
mistaken.** They were cleared in four sequential waves, never in parallel, so that exactly
one worker owned the tree at a time:

- **Wave A** — the two publication blockers, plus payload reaching the metadata log, a
  process identifier reused across a wait before a kill, a caller-supplied string that
  could become a command-line flag, and four capture-to-disk defects including one that
  could hand a directory to a recursive delete.
- **Wave B1** — the two rulings this child escalated, plus redaction parity and the
  synthetic-findings pinning.
- **Wave B2** — thirteen process-lifecycle and tool-server defects: a termination path that
  could wait forever before escalating, a terminal exit event that could never be
  published, pending requests bypassing the inbound policy, and delivery events that could
  claim a file was sent when the write had failed.
- **Closing batch** — the width of the unknown-suggestion fallback, a diagnostic step
  renamed to describe a state the system is actually in, and the spec text.

### What the child taught the parent

The details are in the parent's own Revision Notes and are not restated here. In outline:
the environment scrub is a property about nesting markers and not a list of names, and the
pass-through set is the opposite case for a reason that is written down; always injecting
the config home changes the engine's own gate on the project directory name, so the
resolved record and not the environment must be the source; a session's identity comes from
the frame the engine sends before the first user turn, and a forked session's identity is
genuinely unknown until then, which the type now says rather than guessing; the metadata log
carries no payload, enforced by the type rather than by call-site discipline; and a test
assertion that dumps a value on failure is a disclosure whenever that value is an
environment or a configuration blob. Two gaps in the sibling workstream's redactor were
found here and fixed there.

### What surprised us

- **A test can agree with a wrong model for eleven tasks.** The scripted stand-in was
  written to the spec's assumption that the engine announces itself at startup. It does
  not; it waits for the first user turn. Every transport test passed against a model that
  would have timed out on every real launch, and only the live gate could catch it.
- **A parity test that could not fail.** The test written to detect divergence between two
  redactors passed an empty correlation map, so it could not observe the divergence it
  existed to detect. Removing the fix and running it printed `Executed 1 test, with 0
  failures` with the defect fully present.
- **Decoding and round-tripping have different answers.** A modelled permission variant
  carrying an unmodelled key decoded into its typed case, because the decoder ignores keys
  it was not asked for — and silently dropped that key on re-encode, because the encoder
  writes only what it models. The half everyone would test held; the half nobody would test
  did not.
- **Observing a deadlock can dissolve it.** The first test for a terminal event parked on a
  full channel read the event stream to look for it — and a reader that arrives to look is a
  reader that drains, which frees the slot and releases the parked write.

### What we would do differently

Audit the evidence under a ruling before generalising from it: this controller took a
ruling's conclusion, built a principle on top, and had to reverse both when the premise
turned out to be an artefact of a search that looked for four names. Treat a build as a
mutation in a shared worktree, not just an edit. When two test harnesses write to one
stream, select the summary line by name instead of by position. And search the working
ledger before escalating anything as new — one item here was raised as an open question
when the ledger already held its diagnosis.

### Debt deferred, and where it is logged

Eight findings from the review panel were judged real but not worth acting on in this
child, together with the `ProcessRunner` flake and its diagnosis. All are recorded in the
execution ledger under this plan, each with the finding identifier, the site and the reason
for deferring. None sits on a path any gate names.

### Spend

The working ledger records two model turns across the whole child alongside nine zero-cost
process spawns, but its own parenthetical enumerates three occasions. That discrepancy is
reported rather than resolved by picking a number; the true figure is two or three, and no
turn was spent outside the live gate and its one wasted retry.

## Revision Notes

- 2026-09-05: Closing batch. Three vocabulary entries added to the `terminate()`
  enumeration above: the escalation steps `graceful_phase_deadline_exceeded` and
  `exit_not_observed`, and the lifecycle notice `mcp_delivery_abandoned` with its reasons
  `cancelled` and `write_failed`. The step `stdin_closed` is renamed
  `stdin_close_requested` in the same enumeration, because on the parked-write path the
  descriptor is not closed at the moment the step is recorded and a diagnostic that names a
  state the system is not in teaches the reader something false.
- 2026-09-05: `VersionGate.check` now takes the `ResolvedEnvironment`. That is a
  source-breaking change to a pre-1.0 internal API, accepted with no compatibility shim:
  only tests call it, and the project's simplicity rule prefers changing the code over
  carrying a shim for a caller that does not exist.
- 2026-09-05: A modelled `PermissionUpdate` variant carrying an unmodelled key decodes into
  its typed case and keeps that key in the case's `extras`, which re-encode after the
  modelled keys. `.unknown` remains the answer to a variant this build does not model and
  only to that: a decoder too wide loses the control a familiar variant drives, which is the
  same forward-compatibility failure `.unknown` exists to prevent, one level down.
- 2026-09-04: v1, written at dispatch against parent commit `9fd067c`.
- 2026-09-04: v2 after the parent's review, the human gate and a Codex adversarial review.
  Gate decisions folded in: SIGKILL after SIGTERM with exit reported only when observed
  (§6.7 amended on `main`), `DiffRef` adopted, `contended` as an owned sub-state,
  packages at the repository root, live tests under the scratch config home. Review
  findings: `ProcessEpoch`, `RequestID` and `JSONRPCMessage` moved to `WireFrames` and an
  external consumer package added to G1; public initialisers for every downstream value;
  notification acknowledgement as `mcp_response {result: {}, id: 0}` and the full MCP
  sequence in G1; string-valued redaction with the usage counters exempt and a
  typed-after-redaction assertion (§11 amended on `main`); bounded transport buffers with
  pipe backpressure and a flood test; sentinel-delimited environment capture; G2 stated
  as evaluable at C1.G1 with merge allowed pending (§17.6); the token-refresh requests
  recorded as unreachable for afleet. The "Questions for the human gate" section is
  removed.
- 2026-09-04: v3 at planning. Planning's hostile read changed three things: `events` is a
  `WireEventStream<WireEvent>` (an `AsyncSequence` over a bounded channel) rather than
  `AsyncStream`, which cannot suspend its producer and so cannot give the bounded lossless
  buffer G1 requires; typed models decode with `JSONDecoder` from the same bytes rather
  than from the parsed `JSONValue`, and keep undeclared keys in an `additional` bag, which
  is what makes G2's lossless re-encoding provable; `LaunchConfiguration` gains
  `configHomeOverride` for tests and recordings only. X3's consumers iterate `events` with
  `for await` exactly as before. Plan:
  `docs/doperpowers/plans/2026-09-04-c2-afleetcore-claudewire.md`.
- 2026-09-04: v3, after the plan's Codex review. `send_user_file` restated with the parent's
  full schema (`status`, `display?`) and the built-in tool's path domain; every settlement
  in the transport (outbound correlation, handshake, exit waits) goes through a
  single-resume `Waiter` registered before the write, never a continuation raced in a task
  group; `tools/call` runs off the reader so cancellation can reach it; `Lossless` also
  preserves declared keys that were explicit nulls; `mcp_reconnect`, `mcp_toggle`,
  `update_settings` and `mcp_call` payloads corrected to the typings' keys; the
  `ClaudeWire` umbrella re-exports `AfleetCore` so a consumer imports one module.
- 2026-09-04: Outbound cancellation, two facts read from the engine binary during execution
  (`~/claude-code-bundle/2.1.258/cli.pretty.js`; C1 confirms both against the 2.1.259
  recording, after which this note cites the fixture instead). First, the abortable set above
  is correct as written: the stdin loop's `control_cancel_request` handler aborts only
  requests registered in its abort map, and the only host-reachable subtypes that register
  are `mcp_call` and `side_question` (`remote_tools_announce` also registers but is
  cloud-worker only). For every other subtype a host cancel is a no-op — the binary logs
  `control_cancel_request for unknown request <id> — nothing pending, ignoring` — and the
  request runs on to its normal answer. `ClaudeProcess.cancel(_:)` therefore documents that
  the CLI ignores the frame for non-abortable subtypes, so no caller expects the request to
  stop. Second, after honouring a cancel the CLI still emits an error `control_response`
  (`mcp_call cancelled by client: <server>`, `Side question cancelled`). A response whose
  `request_id` the pending map has already forgotten is therefore ordinary traffic, not
  drift: the correlation path drops it with at most a diagnostic, never a `WireError` and
  never an opaque-census entry. The CLI's own schema text states the rule symmetrically — a
  requester ignores responses for request ids it is not waiting on.
- 2026-09-04: Frame-model errata found during execution by reading the engine's zod schema
  registry rather than the typings, each confirmed by an independent reviewer against the
  same source. `command_lifecycle` carries `state` (one of queued, started, completed,
  cancelled, discarded, refused), not `event`; there is no `event` key on that frame.
  `mirror_error.key` is an object (`projectKey`, `sessionId`, optional `subpath`), not a
  string. `tool_progress.elapsed_time_seconds` is an integer. `files_persisted` carries
  `files` of `{filename, file_id}` and `failed` of `{filename, error}`.
  `compact_boundary`'s `preserved_segment` and `preserved_messages` are objects. `request_id`
  is nullable on both `model_refusal_fallback` and `model_refusal_no_fallback`, which makes
  four declared nullable-but-required fields across the modelled frames rather than the three
  the plan named, with a fifth inside `tool_progress.subagent_retry` that needs no declaration
  of its own because it sits within a `JSONValue`. `conversation_reset` was checked and the plan was right: the wire key is
  `new_conversation_id`, and the parity doc's `newConversationId` is a client-side internal.
  Wire evidence is taken from the engine's own schemas; a hand-written sample that agrees
  with a wrong model proves nothing, which is how two of these survived review of the tables.
- 2026-09-04: `ShellEnvelope`'s neutraliser is syntactic, and the forged-prefix arm of it is
  weaker than the rest — recorded as a known limit rather than left as a believed-solved
  problem. The tag and turn-marker arms are substitutions the engine cannot re-read: a control
  tag loses its `<` to an entity and a `Human:` turn marker loses its colon, so neither can be
  parsed back into a control token by anything downstream. The forged-prefix arm instead
  inserts a zero-width space before markers such as `[harness note]` and the subagent hand-back
  line. That defeats the line-start regular expression the engine matches on, which is what the
  test asserts, but it does not change what the text *looks like*: a model reading the
  transcript still sees a line that reads as a harness note. The defence is therefore against
  the parser, not against the reader, and it should not be described as preventing prompt
  injection through shell output. Two smaller limits sit beside it: the entity escaping is
  reversible, so a downstream consumer that HTML-decodes envelope text would reassemble the
  original control tag (nothing in the current path decodes entities), and the envelope's own
  `[afleet: N bytes of stdout omitted]` notice is not itself neutralised, so stream content can
  forge the one trusted marker the envelope injects. All three are cheap to close if the threat
  model ever demands it — a visible replacement rather than a zero-width one, a non-reversible
  escape, and neutralising the notice form — and none is closed today. Found by review of the
  C2 implementation; the parent's §6.6 wording should not claim more than this.
- 2026-09-04: Two `WireMCP` decisions revisited against the engine binary during execution, one
  amended and one left pinned with its rationale corrected. First, `send_user_file` now coerces a
  bare-string `files` into a one-element array, matching the built-in tool
  (`~/claude-code-bundle/2.1.258/cli.pretty.js:485919`, where `files` is
  `preprocess(e => typeof e === "string" ? [e] : e, array(string()).min(1))`). The design's
  rationale for mirroring the built-in is that the model's prompt-trained behaviour transfers, and
  that rationale reaches further than the schema: the model learned against a runtime that accepts
  the bare string, so its output distribution includes that deviation precisely because the
  deviation was never punished. The advertised JSON Schema says `array` in both implementations —
  the converter selects the output direction, so the preprocess is invisible to the model — which
  means mirroring the schema but not the tolerance reproduces only the half that does not matter.
  A bare `"a.txt"` means exactly `["a.txt"]`, so rejecting it buys no disambiguation and converts
  an unambiguous request into a failed tool call that costs a model turn in the G3 path. This
  amends the plan's mandated assertion; `-32602` still answers `files: []`, `files: 5`,
  `files: [1, 2]`, a bad `status`, a bad `display`, and an unknown tool name. Second, the
  cancellation reply keeps JSON-RPC code `-32800`, but the spec should not claim it is MCP's: the
  engine's MCP error enum (`cli.pretty.js:143539`) is `ConnectionClosed -32000`,
  `RequestTimeout -32001` and the standard sets, and `-32800` appears nowhere in the binary — it is
  LSP's code. It is inert rather than correct: the engine deletes its response handler before
  sending `notifications/cancelled` (`474443`), so the reply reaches `_onresponse` (`474336`),
  falls through to `474347`, and is raised on the client's error channel as an unknown-message-ID
  string without ever being parsed for its code. Any value would behave identically today. Left
  pinned so the wire bytes stay predictable, recorded here so a later reader does not mistake it
  for a protocol citation.
- 2026-09-04: The in-process MCP server no longer echoes the client's `protocolVersion` back
  unchanged. The engine sends the newest entry of its own supported list
  (`cli.pretty.js:679251`) and validates the answer with `if (!r.includes(a.protocolVersion))
  throw` (`679254`), so echoing could never fail that check — but it meant afleet asserted it
  spoke whatever version the engine named, and that list now leads with `2025-11-25` (`143537`),
  a revision newer than the surface afleet implements. A future revision making a new behaviour
  mandatory would have been silently agreed to. The server now declares its own supported set and
  answers with the client's version only when it is in that set, falling back to `2025-06-18`
  otherwise. This is the same class of drift the version gate covers for the CLI itself.
- 2026-09-04: G3 is split, because the scratch config home has no inference budget until
  2026-09-06 15:00 UTC. C1's zero-cost `get_usage` capture at 23:20Z records seven-day
  utilization at 100 with `resets_at` 2026-09-06T15:00Z, five-hour at 29, and extra usage
  disabled. The home is logged in — this is a budget limit, not a credential one — which matters
  because the acceptance text's skip condition tests for credentials and would therefore not
  fire: left as written, the round-trip test would spawn, ask for a turn, receive a limit notice
  and fail, which is both a false negative and a wasted spawn. The gate is therefore evaluated in
  two halves. The half that needs no inference is evaluable now and permanently: spawning the
  installed 2.1.259 binary under `CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home`, completing
  the initialize handshake, seeing `mcp__afleet__send_user_file` in the first turn's
  `system/init.tools` observed on the event stream, the
  before-and-after diff proving the test itself created nothing under the scratch home,
  `VersionGate` accepting 2.1.259 and refusing a fabricated older string, `EnvironmentResolver`
  returning the login shell's PATH, `CLAUDE_CONFIG_DIR` becoming `ConfigHome.root` with
  `source == .environment`, and `end_session`. The half that needs a model turn — asking the
  model to send a file and receiving the `hostToolInvoked` event with the turn completing
  normally — skips before spawning, with a message naming the reset, and is recorded as pending
  rather than passing. It becomes evaluable at the reset without any code change. C1's fixture
  recordings for G2 are blocked by the same limit, so G2 remains pending C1.G1 as already
  planned.
- 2026-09-04: The budget constraint in the preceding note has cleared and that note's conclusion
  is superseded: the scratch config home is now logged into an account with capacity (seven-day
  utilization 54, five-hour 12, confirmed by a real two-turn recording under it), so G3's
  turn-dependent half runs and is expected to pass rather than being recorded as pending. The
  split itself stands, because it is better structure independent of budget — it makes the
  inference-free half of the gate provable on its own and permanently, rather than leaving the
  whole gate hostage to a single model turn. One design consequence is worth stating, since it is
  the part that would otherwise rot: the guard on the turn-dependent half must read a live signal
  — a zero-cost `get_usage` showing seven-day utilization at 100, or a `rate_limit_event` with
  status rejected observed on the spawn — and never a hard-coded reset timestamp. A test that
  skips on a fixed date stops testing the moment that date passes, and does so silently, which is
  the failure mode the gate exists to prevent. Live spawns stay at the minimum the gate needs,
  because C1's fixture recordings share the account.
- 2026-09-05: `Handshake` loses `systemInit` and `spawn()` completes on the `initialize` response
  alone, because the engine does not emit `system/init` until a user message is submitted. As
  written, `spawn()` waited for both and would therefore have timed out on every real launch — the
  normal case, since a channel is opened before its user types. The evidence is unambiguous across
  C1's corpus: in all sixteen recorded fixtures the `initialize` response is the first frame out,
  `system/init` never precedes the first inbound `user` frame, and the two fixtures that submit no
  message — `zero-cost` and `resume-no-replay` — contain no `system/init` at all. The engine source
  agrees: the frame is built inside the per-turn query path, not the initialize handler. The
  parent's §7.3 already said `system/init` opens every *turn*; this was C2 misreading §6.2 and X3,
  not a contradiction in the parent. `system/init` now reaches consumers only as
  `.frame(.system(.init(…)))` on the event stream. The field is **removed rather than made
  optional**: one that is nil on essentially every launch invites reads that work in a fabricated
  test and fail in production.
  Two things this incident established that outlive the fix. First, it survived eleven tasks of
  review because the scripted stand-in emitted `system/init` immediately, having been written to the
  same assumption as this document — every transport test agreed with a wrong model and passed. The
  stand-in's contract is therefore now explicit: its default scenario models the recorded engine, and
  behaviour it emits that no fixture shows is a defect in the stand-in. Second, this is the class of
  defect G1 cannot catch by construction, since G1 is defined as provable without the real CLI. G3
  found it on its first live run.
  A consequence worth stating separately, because it bears on §6.12 and on anything reading
  `mcp_servers` — and stated more precisely than this note first had it, which mis-scoped the
  timing. The engine drives its JSON-RPC handshake against the in-process server **before** it
  answers our control `initialize`, not after. `Fixtures/zero-cost` and `plain-two-turn` both record
  the same opening: our `initialize` control request, then the engine's `mcp_message` carrying a
  JSON-RPC `initialize` toward our server, then our answer, and only then the engine's
  `control_response` completing the handshake — frame 2 before frame 4, at t=887/888/891 ms and
  t=770/770/773 ms respectively. So the engine will not answer `initialize` until the host has
  answered the server's JSON-RPC `initialize`, which is a **host constraint**: an inbound loop that
  starts only after `spawn()` returns deadlocks. These are two facts about two different events and both hold.
  The bring-up **starts** inside the handshake, which is the constraint above. The server is not
  **connected** at frame 4: `notifications/initialized` is frame 7, after the engine's response, and
  `tools/list` does not arrive until frame 11 — with the first user message or the first outbound
  request (t=892 ms in `zero-cost`, t=774 ms in `plain-two-turn`). The live measurement is the
  observable consequence of that tail: an `mcp_status` issued immediately after `spawn()` returned an
  empty server list, with connected appearing about 0.9 s later. So the host must serve the bring-up
  during the handshake, and the server reports connected only after the bring-up completes, which is
  after `spawn()` returns. Consumers wait for the server rather than assume it.
- 2026-09-05: **Acceptance verified. G1, G2, G3 and G4 all pass.** Every run below was taken
  from a deleted `.build` on both packages: an incremental green is not evidence here, because
  removing a stored property once left a stale build that crashed with signal 11 while
  `swift build` reported success on a tree that would not compile.
  **G1 passes.** `AfleetCore` builds clean and runs 6 tests with 0 failures. `ClaudeWire`
  builds clean with zero warnings and runs 186 tests with 0 failures. Every test the gate
  names as its evidence was confirmed present and passing *by name*, not inferred from a
  total: `LaunchConfigurationTests` (all five, covering the token-for-token argument vector,
  every optional flag in order, the child environment table and the scrubbed `CLAUDE_*`
  variables), `InitializeConfigurationTests.testDefaultPayloadIsByteEqualToParentSection62`,
  `ClaudeProcessTests.testUnknownRequestAnsweredWithinOneSecondAndSurfacedAsPolicyEvent`,
  `testDeclaredDialogSurfacesUndeclaredIsLeftUnanswered`,
  `testMalformedKnownRequestNamesTheField`, `testMCPSequenceIsAnsweredInsideTheTransport`,
  all seven of `ClaudeProcessTerminationTests`,
  `ClaudeProcessFloodTests.testFloodWithSuspendedConsumerLosesNothingAndBoundsMemory`,
  `RedactorTests.testTypedFramesStayTypedAfterRedaction`, and `ConsumerSmokeTests`. The
  consumer package also builds and runs standalone, printing
  `ConsumerSmoke: constructed every X2 and X3 value`. One qualification, recorded rather than
  silenced: across five full non-live runs, `ProcessRunnerTests.testLargeOutputIsFullyRead`
  failed once, reporting `exitCode == -1` with output complete and `timedOut == false` after
  31 s against a 30 s timeout. The cause is `FoundationProcessRunner` observing child exit
  through a blocking `waitUntilExit()` dispatched to `DispatchQueue.global()`: under
  thread-pool starvation on a loaded machine the `exited` flag is never set and the call
  settles on its timeout instead. Ten isolated runs of that test all passed. The runner still
  returns within timeout plus grace with complete output, so the defect is bounded; it is
  carried as debt, and it is not one of G1's named evidence tests.
  **G2 passes, and is no longer pending.** C1 merged, so the gate is evaluable:
  `FixtureCorpusTests.testEveryFixtureDecodesLosslessly` runs over 18 fixtures (16 recorded, 2
  synthetic), 1353 frames, 152 in and 1201 out. 1343 round-tripped; the remaining 10 are named
  findings confined to the two synthetic fixtures, every one of them a `result` frame omitting
  `duration_ms`, which the bundle settles as constructor partiality rather than engine
  behaviour. Zero frames in the whole corpus were opaque, and the sixteen recorded fixtures are
  held to the strict rule that every line decodes typed and re-encodes with every key and value
  intact. **The limit worth naming:** G2's clause that unmodelled types and subtypes decode to
  `Frame.opaque` is, against this corpus, a zero-equals-zero shadow — no fixture contains an
  unmodelled type or subtype, so the assertion compares an empty set against an empty set. That
  clause is verified by the hand-written samples, not by the corpus, and it should not be
  "fixed" by fabricating a fixture into a recorded corpus.
  **G3 passes, in both halves, on one live pass.** The whole suite was run once with
  `AFLEET_LIVE_CLI=1` from a clean build — one pass, deliberately, because the account is
  shared with C1 — and returned `Executed 186 tests, with 0 failures`, zero skipped. The
  inference-free half spawned `claude` under
  `CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home` in a temporary working directory with
  `--setting-sources ""`, saw `mcp_status` list exactly `["send_user_file"]` for the `afleet`
  server, and terminated on `end_session` alone with one clean exit. The turn-dependent half
  spent its single `haiku` turn: exactly one `system/init`, its `tools` carrying
  `mcp__afleet__send_user_file`, the model asking permission for that tool, exactly one
  `hostToolInvoked` naming `hello.txt`, and one non-error result. Neither budget guard fired.
  Three spawns of the binary in total: one `claude --version` and two protocol sessions.
  The installed CLI is **2.1.261** against a `ProtocolBaseline.version` of `2.1.259`; every
  version assertion is at-or-above the baseline, never equality, so the gap is not a failure —
  but nothing here was tested against 2.1.259 itself.
  **The config-home allowlist held on its first real test.** `engineWrittenNames` had until now
  been proven only against synthetic differences. In this pass it was exercised against real
  engine writes and reported nothing unexplained. The exercise was uneven and that matters: the
  handshake test's real difference was a single modified path, while the model-turn test's was
  substantial — the engine's transcript under `projects/`, asserted by name for the launched
  session. If the turn-dependent half is ever skipped for budget, the allowlist is effectively
  unexercised that run, and a green G3 should not then be read as evidence about it. It is also
  unproven against sessions using hooks, plugins, background shells, IDE integration, subagents
  or session relocation, any of which could write under names nobody has watched the engine
  write.
  **G4 passes.** `Tools/fetch-typings.sh` was run from a deleted `.typings/` and fetched
  `typings 0.3.259 at .typings/package/sdk.d.ts`. `git ls-files` matches nothing under
  `.typings/`, `node_modules/` or any `*.d.ts`; `git status --porcelain` is silent with the
  typings on disk; and `git add --all --dry-run .` over the whole tree stages none of them, so
  they are not merely untracked but unstageable. `.gitignore:7` is `.typings/`. With the
  directory parked, both `TypingsDriftTests` cases skip with a named reason rather than fail;
  with it present, both pass.
  **X9 holds.** Both live tests take a config-home reading before their own setup and assert
  that window empty, and another after the child exits asserting that window empty too; both
  passed, and the witness's own non-vacuity is proven by `LiveGateMachineryTests`. Every session
  these tests launched wrote its transcript under the scratch home only — three
  `afleet-live-*` project directories there, and no match for `afleet-live` or `afleet-c2`
  anywhere under `~/.claude/projects`. The only references to a real home in either package are
  three `NSHomeDirectory()` reads used to derive paths and one in a test comparison; none
  writes. A bare `find ~/.claude -newer <marker>` does report activity, but it is not
  attributable to these packages: this verification runs *inside* a Claude Code session whose
  own config home is `~/.claude`, alongside its daemon, and neither can be separated from the
  tests by timestamp — which is why the three readings above, which can, are the evidence.
  **Carried, unresolved.** Beyond the two limits named above: the scripted stand-in remains a
  minimal model rather than a replica — it emits no `system/status`, `command_lifecycle`,
  `transcript_mirror`, `stream_event` or `system/thinking_tokens`, all of which every recording
  contains, and `FixtureCorpusTests` covers those by reading the recordings directly. The
  corpus is also silent about the marker-free launch mode, since its harness strips three named
  `CLAUDE_*` variables only. Parent items 29, 33, 34, 36 and 48 stay open; their UI halves
  belong to C5 and C6. Parent revisions to file at merge are unchanged. Full command-by-command
  evidence:
  `.doperpowers/sde/2026-09-04-c2-afleetcore-claudewire/task-14-report.md`.
