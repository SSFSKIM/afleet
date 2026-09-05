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
        if systemInit?.terminalSlashCommands?.contains(name) == true {
            return .refusedLocally(explanation: RouterTable.explanation(forTerminalOnly: name))
        }
        return .text(text)
    }

    /// What autocomplete offers: the engine's own commands merged with the local table, minus anything the engine
    /// says belongs to its terminal interface — those are hidden, not offered and then refused.
    public static func autocomplete(handshake: InitializeResponse? = nil,
                                    systemInit: SystemInitFields? = nil) -> [String] {
        let terminalOnly = Set(systemInit?.terminalSlashCommands ?? [])
        var names = Set(RouterTable.local.map(\.name))
        for command in systemInit?.slashCommands ?? [] { names.insert(command) }
        for command in handshake?.commands ?? [] {
            guard let name = command["name"]?.stringValue else { continue }
            names.insert(name.hasPrefix("/") ? name : "/" + name)
        }
        return names.subtracting(terminalOnly).sorted()
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
            guard let argument else { return .native("modelPicker") }
            return .controlRequest(AnyControlRequest(SetModel(model: argument)))
        case .setPermissionMode:
            // Bare `/permissions` is the read-only rules view; a mode the engine does not know is not sent at all.
            guard let argument, let mode = PermissionMode(rawValue: argument) else {
                return .strategy(.permissionsView, arguments: [])
            }
            return .controlRequest(AnyControlRequest(SetPermissionMode(mode: mode)))
        case .applyFlagSetting(let key):
            return .controlRequest(AnyControlRequest(ApplyFlagSettings(settings: .object([key: flagValue(key, argument, runtime)]))))
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
            let added = URL(fileURLWithPath: argument)
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

    /// `/fast` is a toggle over what the channel is running; every other flag takes the word the user typed.
    private static func flagValue(_ key: String, _ argument: String?, _ runtime: SessionRuntimeState?) -> JSONValue {
        guard key == "fastMode" else { return .string(argument ?? "") }
        if let argument { return .bool(argument == "on" || argument == "true") }
        let current = runtime?.flagSettings["fastMode"]?.boolValue ?? runtime?.fastModeObserved ?? false
        return .bool(!current)
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

/// The `rewind_conversation` answer. `prefillText` is the prompt to put back in the composer.
public struct RewindOutcome: Hashable, Sendable {
    public var rewound: Bool
    public var prefillText: String?
    public init(rewound: Bool, prefillText: String?) { self.rewound = rewound; self.prefillText = prefillText }
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

/// Bare `/permissions`: the read-only view over what `get_settings` reports as applied.
public struct PermissionsView: Hashable, Sendable {
    public var rules: [String: JSONValue]
    public init(rules: [String: JSONValue]) { self.rules = rules }
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
    /// Puts the dry run's counts in front of the user and answers whether to apply them.
    func confirm(preview: RewindPreview) async -> Bool
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
            let preview = RewindPreview(try await supervisor.perform(RewindFiles(userMessageID: target, dryRun: true)))
            // Nothing else goes out until the user has seen the counts and said yes.
            guard await ui.confirm(preview: preview) else { return .rewind(preview, nil) }
            _ = try await supervisor.perform(RewindFiles(userMessageID: target, dryRun: false))
            let answer = try await supervisor.perform(RewindConversation(targetMessageUUID: target))
            return .rewind(preview, RewindOutcome(rewound: answer["rewound"]?.boolValue ?? false,
                                                  prefillText: answer["prefillText"]?.stringValue))

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
            return .permissions(PermissionsView(rules: settings["applied"]?.objectValue ?? [:]))

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

/// One replaced drift refusal.
public struct Intercepted: Hashable, Sendable {
    public let command: String
    public let replacement: String
    public init(command: String, replacement: String) { self.command = command; self.replacement = replacement }
}

/// Catches the engine's bare refusal of a command afleet routes locally, replaces it with afleet's own explanation
/// and counts it for the drift log.
///
/// The match is against the *whole* assistant text and nothing less. The same sentence inside a longer answer is the
/// model talking about the command, and replacing that would rewrite an answer the engine meant.
public actor RefusalInterceptor {
    private let diagnostics: any FleetDiagnosticsSink
    private let expression: NSRegularExpression?
    private var drift = 0

    public init(diagnostics: any FleetDiagnosticsSink = NullFleetDiagnostics()) {
        self.diagnostics = diagnostics
        self.expression = try? NSRegularExpression(pattern: RouterTable.bareRefusalPattern)
    }

    /// How many refusals have been intercepted since the fleet started: the drift signal that says the engine and
    /// the local table have moved apart.
    public var driftCount: Int { drift }

    public func intercept(_ text: String) -> Intercepted? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expression else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = expression.firstMatch(in: trimmed, range: range), match.numberOfRanges == 2,
              let nameRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        let command = "/" + String(trimmed[nameRange])
        drift += 1
        diagnostics.record(.driftRefusalIntercepted(command: command))
        return Intercepted(command: command, replacement: RouterTable.explanation(forTerminalOnly: command))
    }
}
