import Foundation
import AfleetCore
import ClaudeWire

/// A control request with its spec's type erased: the subtype the engine sees and the payload that goes with it.
///
/// `Routed` has to carry a typed request without a generic parameter of its own, and it needs no more of the spec
/// than this. There is deliberately no answer decoder: every request the router builds goes out through
/// `RawControlRequest`, whose `Response` is `JSONValue`, and `RuntimeStateUpdater` reads the runtime record off the
/// subtype and the payload rather than off a decoded value. A decoder here would have no caller.
public struct AnyControlRequest: Hashable, Sendable {
    /// The subtype as the wire carries it, which for a `RawControlRequest` is its own and never the static one.
    public let subtype: String
    /// The request object minus `subtype`.
    public let payload: JSONValue

    public init<R: ControlRequestSpec>(_ spec: R) {
        subtype = RuntimeStateUpdater.subtype(of: spec)
        payload = spec.payload
    }
    public init(subtype: String, payload: JSONValue) { self.subtype = subtype; self.payload = payload }

    /// The spec `perform` sends. It carries the subtype per instance, which is what `OutboundEnvelope.encode` and
    /// `RuntimeStateUpdater` both read.
    public var raw: RawControlRequest { RawControlRequest(subtype: subtype, payload: payload) }
}

/// What the composer does with a line the user typed.
public enum Routed: Sendable {
    case controlRequest(AnyControlRequest)
    case strategy(RouteStrategy, arguments: [String])
    case lifecycle(LifecycleAction)
    case restart(RestartRequest)
    case text(String)
    case native(String)
    case refusedLocally(explanation: String)
}

/// The parent's §7.7 resolution order, over `RouterTable`: the local table first, then the handshake's
/// `terminal_slash_commands`, then the engine as text (contract X10).
public enum CommandRouter {

    /// Routes one composer line.
    ///
    /// `handshake` and `systemInit` are the engine's own report of what it offers; `runtime` is what the channel is
    /// currently running, which two commands need — `/fast` toggles the value the channel holds, and `/add-dir`
    /// appends to the list it was launched with rather than replacing it.
    public static func route(_ text: String, handshake: InitializeResponse? = nil,
                             systemInit: SystemInitFields? = nil,
                             runtime: SessionRuntimeState? = nil) -> Routed {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/") else { return .text(text) }
        let split = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(split[0])
        let rest = split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespaces) : ""
        let arguments = rest.isEmpty ? [] : [rest]

        if let command = RouterTable.command(named: name) {
            return resolve(command, arguments: arguments, runtime: runtime, original: text)
        }
        if Self.slashed(systemInit?.terminalSlashCommands ?? []).contains(name) {
            return .refusedLocally(explanation: RouterTable.explanation(forTerminalOnly: name))
        }
        return .text(text)
    }

    /// What autocomplete offers: the engine's own commands merged with the local table, minus anything the engine
    /// says belongs to its terminal interface — those are hidden, not offered and then refused.
    public static func autocomplete(handshake: InitializeResponse? = nil,
                                    systemInit: SystemInitFields? = nil) -> [String] {
        let terminalOnly = Self.slashed(systemInit?.terminalSlashCommands ?? [])
        var names = Set(RouterTable.local.map(\.name))
        names.formUnion(Self.slashed(systemInit?.slashCommands ?? []))
        names.formUnion(Self.slashed((handshake?.commands ?? []).compactMap { $0["name"]?.stringValue }))
        return names.subtracting(terminalOnly).sorted()
    }

    /// The one spelling every command name is compared in.
    ///
    /// `system/init` names its commands **without** a leading slash (`vim`, `doctor`) — on every recorded fixture
    /// and in the bundle that builds the frame — while the composer's line and the local table always carry one.
    /// Comparing the two spellings makes the terminal-only refusal dead code and leaves the subtraction in
    /// `autocomplete` offering the very commands the engine said belong to its terminal.
    private static func slashed(_ names: [String]) -> Set<String> {
        Set(names.map { $0.hasPrefix("/") ? $0 : "/" + $0 })
    }

    /// The second `set_cwd` after a `needs_trust`. `trusted_directory` echoes the directory the *answer* named —
    /// the resolved one — and never the path the host asked for: that is what stops trust being granted to a
    /// directory other than the one the engine asked about (`session-mirror-relocation`, and the engine refuses
    /// `trust_accepted` without it).
    public static func continueCD(afterNeedsTrust directory: String, path: String) -> SetCwd {
        SetCwd(path: path, trustAccepted: true, trustedDirectory: directory)
    }

    // MARK: - Per-command argument parsing

    private static func resolve(_ command: LocalCommand, arguments: [String],
                                runtime: SessionRuntimeState?, original: String) -> Routed {
        let argument = arguments.first
        switch command.strategy {
        case .setModel:
            guard let argument else { return .native(picker(for: command)) }
            return .controlRequest(AnyControlRequest(SetModel(model: argument)))
        case .setPermissionMode:
            // Bare `/permissions` is the read-only rules view. A mode the engine does not know is a typo, and a typo
            // must not look like the bare form: it is refused here rather than sent or silently reinterpreted.
            guard let argument else { return .strategy(.permissionsView, arguments: []) }
            guard let mode = PermissionMode(rawValue: argument) else {
                return .refusedLocally(explanation: RouterTable.explanation(forUnknownMode: argument))
            }
            return .controlRequest(AnyControlRequest(SetPermissionMode(mode: mode)))
        case .applyFlagSetting(let key):
            // `/fast` is a toggle and needs no argument; every other flag takes a value, and sending an empty one
            // would write "" into the session's flag settings. With no argument the surface picks instead.
            guard let value = flagValue(key, argument, runtime) else { return .native(picker(for: command)) }
            return .controlRequest(AnyControlRequest(ApplyFlagSettings(settings: .object([key: value]))))
        case .renameSession:
            guard let argument else { return .text(original) }
            return .controlRequest(AnyControlRequest(RenameSession(title: argument)))
        case .setCwd:
            guard let argument else { return .text(original) }
            return .controlRequest(AnyControlRequest(SetCwd(path: argument)))
        case .interrupt:
            return .controlRequest(AnyControlRequest(Interrupt()))
        case .sideQuestion:
            guard let argument else { return .text(original) }
            return .controlRequest(AnyControlRequest(SideQuestion(question: argument)))
        case .restart:
            guard let argument else { return .text(original) }
            var directories = runtime?.addDirectories ?? []
            // A relative path is relative to the *channel's* directory. `URL(fileURLWithPath:)` with no base
            // resolves against afleet's own process cwd, which is not a directory the user has ever seen. The base
            // is hinted as a directory: a cwd that reached the runtime record as a plain file URL would otherwise
            // have its last component replaced rather than appended to.
            let base = (runtime?.cwd).map {
                URL(filePath: $0.path(percentEncoded: false), directoryHint: .isDirectory)
            }
            let added = URL(filePath: argument, relativeTo: base).standardizedFileURL
            if !directories.contains(added) { directories.append(added) }
            return .restart(RestartRequest(addDirectories: directories))
        case .lifecycle(let action):
            return .lifecycle(lifecycleAction(action))
        case .rewind, .login, .permissionsView, .mcpPopover, .memoryFiles:
            return .strategy(command.strategy, arguments: arguments)
        case .native(let surface):
            return .native(surface)
        case .text:
            return .text(original)
        }
    }

    /// `/fast` is a toggle over what the channel is running, so it always has a value; every other flag takes the
    /// word the user typed, and nil when they typed none.
    private static func flagValue(_ key: String, _ argument: String?, _ runtime: SessionRuntimeState?) -> JSONValue? {
        guard key == "fastMode" else { return argument.map(JSONValue.string) }
        if let argument { return .bool(argument == "on" || argument == "true") }
        let current = runtime?.flagSettings["fastMode"]?.boolValue ?? runtime?.fastModeObserved ?? false
        return .bool(!current)
    }

    /// The surface a command with no argument opens: `/model` -> `modelPicker`, `/effort` -> `effortPicker`.
    private static func picker(for command: LocalCommand) -> String {
        String(command.name.dropFirst()) + "Picker"
    }

    private static func lifecycleAction(_ name: LifecycleActionName) -> LifecycleAction {
        switch name {
        case .fork: .fork(at: nil)
        case .sendToBackground: .sendToBackground
        case .stopEverything: .stopEverything
        case .backgroundAll: .backgroundAll
        case .logout: .logout
        }
    }
}

// MARK: - What a strategy produces

/// The `rewind_files {dry_run: true}` answer, as the confirmation sheet reads it.
public struct RewindPreview: Hashable, Sendable {
    public var canRewind: Bool
    public var filesChanged: [String]
    public var insertions: Int
    public var deletions: Int
    public init(canRewind: Bool, filesChanged: [String], insertions: Int, deletions: Int) {
        self.canRewind = canRewind; self.filesChanged = filesChanged
        self.insertions = insertions; self.deletions = deletions
    }
    init(_ answer: JSONValue) {
        self.init(canRewind: answer["canRewind"]?.boolValue ?? false,
                  filesChanged: answer["filesChanged"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                  insertions: Int(answer["insertions"]?.intValue ?? 0),
                  deletions: Int(answer["deletions"]?.intValue ?? 0))
    }
}

/// What the confirmation sheet answered. `/rewind` is two independent rewinds — the conversation and the working
/// tree — and the sheet says which of them the user asked for.
public enum RewindChoice: Hashable, Sendable {
    /// Nothing is sent. The read-only dry run has already run and touched nothing.
    case cancel
    case conversationOnly
    case conversationAndFiles
}

/// The `rewind_files {dry_run: false}` answer: `{canRewind: true, skippedLinks}` when the revert ran and
/// `{canRewind: false, error}` when the engine would not (2.1.258 `cli.pretty.js:153445-153460`).
/// `skippedLinks` counts tracked paths the engine left alone, which the surface says rather than reporting a clean
/// revert of everything the dry run listed.
public struct RewindFilesOutcome: Hashable, Sendable {
    public var canRewind: Bool
    public var skippedLinks: Int
    public var error: String?
    public init(canRewind: Bool, skippedLinks: Int, error: String? = nil) {
        self.canRewind = canRewind; self.skippedLinks = skippedLinks; self.error = error
    }
    init(_ answer: JSONValue) {
        self.init(canRewind: answer["canRewind"]?.boolValue ?? false,
                  skippedLinks: Int(answer["skippedLinks"]?.intValue ?? 0),
                  error: answer["error"]?.stringValue)
    }
}

/// The `rewind_conversation` answer. `prefillText` is the prompt to put back in the composer.
///
/// `error` is the body-level reason inside a *success* envelope — `"stale target"` for any message the running
/// process did not itself send, which after a reopen is every earlier message (fixture `rewind-turn`). A host that
/// read the envelope alone would report a refused rewind as done, so the body is what is read and the reason is
/// carried to the surface.
public struct RewindOutcome: Hashable, Sendable {
    public var rewound: Bool
    public var prefillText: String?
    public var error: String?
    /// The files half: present only when the user asked for it *and* the conversation rewind was honoured.
    public var files: RewindFilesOutcome?
    /// Parent §8.5 item 13: a refused rewind is never reported as done, and what is offered instead is
    /// *Fork from here* at the message's preceding assistant record.
    public var offersForkFromHere: Bool { !rewound }
    public init(rewound: Bool, prefillText: String?, error: String? = nil, files: RewindFilesOutcome? = nil) {
        self.rewound = rewound; self.prefillText = prefillText; self.error = error; self.files = files
    }
}

/// The two URLs `claude_authenticate` answers with, as strings: the recorded pair carries a redaction marker in its
/// query, so a `URL` here would be a value the corpus cannot produce.
public struct LoginPrompt: Hashable, Sendable {
    public var manualURL: String
    public var automaticURL: String
    public init(manualURL: String, automaticURL: String) {
        self.manualURL = manualURL; self.automaticURL = automaticURL
    }
}

public enum LoginOutcome: Hashable, Sendable {
    case signedIn(account: String)
    /// The wait failed; the recorded case is the engine's "No active claude_authenticate flow", and the affordance
    /// either way is the same one: offer the sign-in again. The reason is carried so the surface can say which.
    case noActiveFlow(reason: String)
}

/// Bare `/permissions`: the read-only view built from the `get_settings` answer.
///
/// It carries the **whole** answer rather than a `rules` field, because no answer anywhere in the corpus lists a
/// permission rule: `zero-cost`'s `get_settings.applied` is `{model, effort, advisor, ultracode}`, which are flag
/// settings. Naming a field `rules` and filling it from `applied` would have the surface render the model and the
/// effort level under a permissions heading. When a recording that carries allow and deny rules exists, the view
/// reads them out of this same body and nothing here changes shape.
public struct PermissionsView: Hashable, Sendable {
    /// The engine's `get_settings` answer, verbatim.
    public var settings: JSONValue
    /// What the engine reports as applied — the only settings state the corpus records.
    public var applied: [String: JSONValue] { settings["applied"]?.objectValue ?? [:] }
    public init(settings: JSONValue) { self.settings = settings }
}

public struct MCPPopover: Hashable, Sendable {
    public struct Server: Hashable, Sendable {
        public var name: String
        public var status: String
        public init(name: String, status: String) { self.name = name; self.status = status }
    }
    public var servers: [Server]
    public init(servers: [Server]) { self.servers = servers }
}

/// What a strategy handed back. Every case names the value the surface renders; nothing here is a wire frame.
public enum StrategyOutcome: Sendable {
    /// The preview the user saw, and the rewind that followed it — nil when the user declined.
    case rewind(RewindPreview, RewindOutcome?)
    case login(LoginPrompt, LoginOutcome)
    case permissions(PermissionsView)
    case mcp(MCPPopover)
    case memory([String])
    /// A single-request strategy's answer, as the engine sent it.
    case answered(JSONValue)
    /// Nothing to run here: `.text`, `.native` and `.lifecycle` are the surface's or the facade's, not the
    /// executor's.
    case notARequest
}

/// The two things a multi-step strategy needs from the app: a browser tab, and an answer to a confirmation.
public protocol StrategyUI: Sendable {
    /// Hands a URL to the Browser tab.
    func open(url: String) async
    /// Puts the dry run's counts in front of the user and answers how much of the rewind they asked for.
    func confirm(preview: RewindPreview) async -> RewindChoice
}

/// Runs a `RouteStrategy` against one channel.
///
/// Every request goes through `ChannelSupervisor.perform`, never through the process, so each answer passes through
/// `RuntimeStateUpdater` on the way out and the quiescent restart relaunches from what the user actually changed.
public enum StrategyExecutor {

    /// One routed control request.
    @discardableResult
    public static func send(_ request: AnyControlRequest, on supervisor: ChannelSupervisor) async throws -> JSONValue {
        try await supervisor.perform(request.raw)
    }

    @discardableResult
    public static func run(_ strategy: RouteStrategy, arguments: [String] = [],
                           on supervisor: ChannelSupervisor, ui: any StrategyUI) async throws -> StrategyOutcome {
        switch strategy {
        case .rewind:
            guard let target = arguments.first else { return .notARequest }
            // The dry run reports what a revert would change and changes nothing.
            let preview = RewindPreview(try await supervisor.perform(RewindFiles(userMessageID: target, dryRun: true)))
            // Nothing else goes out until the user has seen the counts and answered the sheet.
            let choice = await ui.confirm(preview: preview)
            guard choice != .cancel else { return .rewind(preview, nil) }

            // The conversation first, always. `rewind_conversation` refuses any target the running process did not
            // itself send, and applying the files ahead of it would leave that ordinary refusal with the user's
            // working tree reverted under a conversation that never moved — silently, inside a success envelope.
            // Safe because `rewind_files` resolves its checkpoint through the engine's file history keyed by the
            // message id and never through the message array (2.1.258 `cli.pretty.js:153445-153460`), so the
            // checkpoint outlives the conversation rewind.
            let answer = try await supervisor.perform(RewindConversation(targetMessageUUID: target))
            let rewound = answer["rewound"]?.boolValue ?? false
            let prefill = answer["prefillText"]?.stringValue
            let refusal = answer["error"]?.stringValue
            guard rewound, choice == .conversationAndFiles else {
                return .rewind(preview, RewindOutcome(rewound: rewound, prefillText: prefill, error: refusal))
            }
            let applied = try await supervisor.perform(RewindFiles(userMessageID: target, dryRun: false))
            return .rewind(preview, RewindOutcome(rewound: true, prefillText: prefill,
                                                  files: RewindFilesOutcome(applied)))

        case .login:
            let urls = try await supervisor.perform(ClaudeAuthenticate())
            let prompt = LoginPrompt(manualURL: urls["manualUrl"]?.stringValue ?? "",
                                     automaticURL: urls["automaticUrl"]?.stringValue ?? "")
            // The automatic URL is the one that completes without the user copying a code back.
            await ui.open(url: prompt.automaticURL)
            do {
                let done = try await supervisor.perform(ClaudeOAuthWaitForCompletion())
                let account = done["account"]?["email"]?.stringValue ?? ""
                return .login(prompt, .signedIn(account: account))
            } catch let error as WireError {
                guard case .controlError(let reason) = error else { throw error }
                return .login(prompt, .noActiveFlow(reason: reason))
            }

        case .permissionsView:
            let settings = try await supervisor.perform(GetSettings())
            return .permissions(PermissionsView(settings: settings))

        case .mcpPopover:
            let status = try await supervisor.perform(MCPStatus())
            let servers = (status["mcpServers"]?.arrayValue ?? []).map {
                MCPPopover.Server(name: $0["name"]?.stringValue ?? "", status: $0["status"]?.stringValue ?? "")
            }
            return .mcp(MCPPopover(servers: servers))

        case .memoryFiles:
            let usage = try await supervisor.perform(GetContextUsage())
            return .memory(usage["memoryFiles"]?.arrayValue?.compactMap(\.stringValue) ?? [])

        case .setModel, .setPermissionMode, .applyFlagSetting, .renameSession, .setCwd, .interrupt, .sideQuestion,
             .lifecycle, .restart, .text, .native:
            // These are routed as a `.controlRequest`, a `.lifecycle`, a `.restart` or a `.text`; the executor is
            // for the sequences, and a caller that reaches here has bypassed `route`.
            return .notARequest
        }
    }
}

/// One replaced drift refusal, with the shape of the engine sentence it replaced.
public struct Intercepted: Hashable, Sendable {
    public let command: String
    public let replacement: String
    public let shape: RefusalShape
    public init(command: String, replacement: String, shape: RefusalShape) {
        self.command = command; self.replacement = replacement; self.shape = shape
    }
}

/// Catches the engine's refusal of a command afleet routes locally, replaces it with afleet's own explanation and
/// counts it for the drift log.
///
/// Both of the engine's refusal sentences are caught, not one: the interactive-panel refusal ends by telling the
/// user to run the command from the Claude Code terminal, which §7.7 says afleet never shows, so a shape that is
/// not matched is a shape whose forbidden instruction reaches the channel. Each is counted under its own shape so
/// the drift log says which of the two moved.
///
/// The match is against the *whole* assistant text and nothing less. The same sentence inside a longer answer is the
/// model talking about the command, and replacing that would rewrite an answer the engine meant.
public actor RefusalInterceptor {
    /// Both patterns are literals in this package, so their compiling is a fact about the source and not about
    /// anything at run time. A `try?` here would turn a broken pattern into an interceptor that silently never
    /// intercepts and a drift counter that reads zero for ever, which is the failure this whole mechanism exists to
    /// notice.
    private static let expressions: [(RefusalShape, NSRegularExpression)] = [
        (.bare, try! NSRegularExpression(pattern: RouterTable.bareRefusalPattern)),
        (.interactivePanel, try! NSRegularExpression(pattern: RouterTable.interactivePanelRefusalPattern)),
    ]

    private let diagnostics: any FleetDiagnosticsSink
    private var drift: [RefusalShape: Int] = [:]

    public init(diagnostics: any FleetDiagnosticsSink = NullFleetDiagnostics()) {
        self.diagnostics = diagnostics
    }

    /// How many refusals have been intercepted since the fleet started: the drift signal that says the engine and
    /// the local table have moved apart.
    public var driftCount: Int { drift.values.reduce(0, +) }

    /// The same count for one of the two shapes.
    public func driftCount(of shape: RefusalShape) -> Int { drift[shape] ?? 0 }

    public func intercept(_ text: String) -> Intercepted? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for (shape, expression) in Self.expressions {
            guard let match = expression.firstMatch(in: trimmed, range: range), match.numberOfRanges == 2,
                  let nameRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let command = "/" + String(trimmed[nameRange])
            drift[shape, default: 0] += 1
            diagnostics.record(.driftRefusalIntercepted(command: command, shape: shape.rawValue))
            return Intercepted(command: command,
                               replacement: RouterTable.explanation(forDrift: command, shape: shape),
                               shape: shape)
        }
        return nil
    }
}
