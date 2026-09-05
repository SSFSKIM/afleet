import Foundation
import ClaudeWire

/// What the host did that no frame states. The wire reducer cannot learn any of these from the engine's output: a
/// prompt is something the host wrote, an answer is something the host decided, a rewind and a relocation are host
/// actions the engine only reports the consequences of, and a process replacement is the host's own bookkeeping.
public enum HostSignal: Sendable, Hashable {
    case promptSent(uuid: String, at: Date)
    case decisionAnswered(RequestID, outcome: DecisionOutcome)
    case rewound(toUUID: String)
    case processReplaced(ProcessEpoch)
    /// `set_cwd` was answered: the agent tree's slug follows. The host sends the same path to
    /// `StreamIngestion.relocated(mainPath:)`.
    case relocated(mainPath: URL)
}

/// How a decision ended. `label` is the word `DecisionItem.State.answered(outcome:)` carries, so the item's state and
/// this value cannot drift apart.
public enum DecisionOutcome: Sendable, Hashable, Codable {
    case allowed
    case denied(message: String?)
    case answered(summary: String)
    case cancelled

    public var label: String {
        switch self {
        case .allowed: "allowed"
        case .denied: "denied"
        case .answered(let summary): summary
        case .cancelled: "cancelled"
        }
    }
}

/// A one-line notice about the channel rather than about the conversation: a rate limit, an auth prompt, an API retry,
/// a model swap, a protocol mismatch, or a mirror the engine could not write.
public struct Banner: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case rateLimit, auth, apiRetry, modelFallback, compatibility, mirrorFileOnly
    }
    public var kind: Kind
    public var text: String
    public var epoch: ProcessEpoch
    public var at: Date
    public init(kind: Kind, text: String, epoch: ProcessEpoch, at: Date) {
        self.kind = kind; self.text = text; self.epoch = epoch; self.at = at
    }
}

/// The engine's prompt queue as `command_lifecycle` reports it. `queued` and `started` hold command uuids in arrival
/// order; a command that reaches any terminal state leaves both.
public struct QueueState: Sendable, Hashable, Codable {
    public var queued: [String]
    public var started: [String]
    public var lastState: String?
    public init(queued: [String] = [], started: [String] = [], lastState: String? = nil) {
        self.queued = queued; self.started = started; self.lastState = lastState
    }

    /// The five states the schema declares plus `refused`. `queued` and `started` move the id between the two lists;
    /// every terminal state drops it from both, so a finished command leaves no residue.
    public mutating func apply(state: String, commandUUID id: String) {
        lastState = state
        switch state {
        case "queued":
            if !queued.contains(id) { queued.append(id) }
            started.removeAll { $0 == id }
        case "started":
            queued.removeAll { $0 == id }
            if !started.contains(id) { started.append(id) }
        default:
            queued.removeAll { $0 == id }
            started.removeAll { $0 == id }
        }
    }
}

/// The wire-only half of the projection: everything the engine says that the transcript never records, plus the rows
/// whose live state only a running process has. `processReplaced` resets it; `exited` marks it stale.
///
/// It is a value with no order of its own: `items` renders it, and Task 11 merges that with the durable half.
public struct Overlay: Sendable, Hashable {
    public var turns: [TurnSummaryItem]
    /// By the engine's `hook_id`.
    public var hooks: [String: HookRunItem]
    public var notifications: [NotificationItem]
    /// By the item id of the first call the summary names.
    public var clusters: [ItemID: ToolClusterItem]
    public var decisions: [RequestID: DecisionItem]
    public var queue: QueueState
    public var stale: Bool
    public var banners: [Banner]
    /// ClaudeWire's payload of `SystemFrame.sessionStateChanged`; the last frame wins and no item is made from it.
    public var sessionState: SessionStateChanged?

    public init(turns: [TurnSummaryItem] = [], hooks: [String: HookRunItem] = [:],
                notifications: [NotificationItem] = [], clusters: [ItemID: ToolClusterItem] = [:],
                decisions: [RequestID: DecisionItem] = [:], queue: QueueState = QueueState(),
                stale: Bool = false, banners: [Banner] = [], sessionState: SessionStateChanged? = nil) {
        self.turns = turns; self.hooks = hooks; self.notifications = notifications; self.clusters = clusters
        self.decisions = decisions; self.queue = queue; self.stale = stale; self.banners = banners
        self.sessionState = sessionState
    }

    public static let empty = Overlay()

    /// The overlay as items, for Task 11's merge. The three dictionaries have no arrival order to preserve, so each is
    /// rendered in a stable key order; the two arrays keep theirs.
    public var items: [TimelineItem] {
        var out: [TimelineItem] = []
        out.append(contentsOf: decisions.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { decisions[$0] }.map(TimelineItem.decision))
        out.append(contentsOf: clusters.keys.sorted { $0.key < $1.key }.compactMap { clusters[$0] }.map(TimelineItem.cluster))
        out.append(contentsOf: turns.map(TimelineItem.turnSummary))
        out.append(contentsOf: notifications.map(TimelineItem.notification))
        out.append(contentsOf: hooks.keys.sorted().compactMap { hooks[$0] }.map(TimelineItem.hookRun))
        return out
    }
}
