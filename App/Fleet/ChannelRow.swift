import Foundation
import AfleetCore
import FleetKit

/// One line in the fleet browser.
///
/// The row is split down the middle on purpose (spec §4). Its **static half** — title, preview,
/// working directory, branch, agent, time — comes from C3's `IndexEntry` and survives a relaunch
/// because the index snapshot does. Its **live half** — origin, presence, pending decisions,
/// banner, system item — comes from a `ChannelState` and survives nothing, because a `ChannelState`
/// is a statement about a process that exists right now.
///
/// **Ruling 3, and tracker entry 21's closer:** a restored row carries *no* origin. `state` is nil
/// until `LifecycleAPI.updates` delivers one, and every live accessor below reads through it, so
/// there is no field an origin could be remembered in. A model that persisted an origin would show
/// a green dot at launch for a session whose process died last week.
struct ChannelRow: Identifiable, Sendable {

    // MARK: - Identity

    let key: ChannelKey
    var id: SessionID { key.session }

    // MARK: - The static half, from `IndexEntry`

    var title: String
    var titleSource: TitleSource
    var preview: String
    /// The entry's own working directory, already the relocated one where C3 found a `relocated`
    /// record. Nil when the transcript never carried a `cwd`; such a row is never registered,
    /// because a `ChannelKey` with no seed runs in the config home and every precondition then
    /// refuses it (spec §3).
    var cwd: URL?
    var gitBranch: String?
    var agentName: String?
    var mtime: Date
    /// §8.2's thirty-day rule over `mtime`, evaluated against the model's clock at build time.
    var isRecent: Bool
    /// Whether the row may offer an owned action. `ListingPolicy` decides; the row never re-reads
    /// the rule that produced it.
    var mode: ListingPolicy.Mode
    /// The name of the `ListingPolicy` rule that listed this row, so the UI can explain a listing
    /// as readily as an exclusion.
    var decidingRule: String
    /// True while the row is painted from the persisted snapshot and the fresh build has not yet
    /// replaced it. `restore(from:)` sets it; `apply(_ snapshot:)` clears it.
    var isProvisional: Bool

    // MARK: - The live half, from `ChannelState`

    /// Nil until a `ChannelState` for this session arrives on `LifecycleAPI.updates`.
    var state: ChannelState?
    /// The last failed action's explanation. Set by `FleetBrowserModel.perform`, never retried.
    var banner: RowBanner?

    // MARK: - Derived

    /// Nil for a row with no `ChannelState`. This is the accessor ruling 3 is about.
    var originGlyph: OriginGlyph? { state.map { OriginGlyph($0.origin) } }
    var origin: ChannelOrigin? { state?.origin }
    var presence: Presence? { state?.presence }
    var pendingDecisionCount: Int { state?.pendingDecisions.count ?? 0 }
    var systemItem: SystemItem? { state?.systemItem }
    var channelBanner: ChannelBanner? { state?.banner }

    /// A row with no live state is archived — spec §7.1's "otherwise".
    var isArchived: Bool { state == nil && (!isRecent || cwd == nil) }

    /// A teammate's transcript is read-only: the row offers open-in-terminal and nothing that
    /// would spawn against someone else's session.
    var offersOwnedActions: Bool { mode == .ownedCandidate }

    var readOnlyReason: ListingPolicy.ReadOnlyReason? {
        if case .readOnly(let reason) = mode { return reason }
        return nil
    }
}

/// The glyph a row shows for its origin (X2). A closed mapping over `ChannelOrigin` so a new origin
/// is a compile error here rather than a blank row.
enum OriginGlyph: String, Hashable, Sendable {
    case connecting, ready, dormant, contended
    case usersTerminal, ownTerminalTab
    case backgroundJob
    case archived

    init(_ origin: ChannelOrigin) {
        switch origin {
        case .owned(.connecting): self = .connecting
        case .owned(.ready): self = .ready
        case .owned(.dormant): self = .dormant
        case .owned(.contended): self = .contended
        case .foreignLive(.usersTerminal): self = .usersTerminal
        case .foreignLive(.ownTerminalTab): self = .ownTerminalTab
        case .backgroundJob: self = .backgroundJob
        case .archived: self = .archived
        }
    }

    /// The SF Symbol the sidebar draws. Task 5 owns the view; the mapping lives with the glyph so
    /// there is one answer to "what does this origin look like".
    var systemImage: String {
        switch self {
        case .connecting: "circle.dotted"
        case .ready: "circle.fill"
        case .dormant: "circle"
        case .contended: "exclamationmark.triangle.fill"
        case .usersTerminal: "terminal.fill"
        case .ownTerminalTab: "terminal"
        case .backgroundJob: "gearshape.fill"
        case .archived: "archivebox"
        }
    }
}

/// Why the last action on this row did not happen.
///
/// Spec §4: `busy` leaves the channel alone and tells the user to retry — **never an automatic
/// retry** — and `notEligible` names the blocker rather than saying "not now". Both structured
/// fields are kept beside the sentence so a test can assert what was named without matching prose.
struct RowBanner: Hashable, Sendable {
    var text: String
    /// Set only for `LifecycleError.busy`.
    var operation: LifecycleOperation?
    /// Set only for `LifecycleError.notEligible`.
    var blocker: DormantEligibility.Blocker?

    init(text: String, operation: LifecycleOperation? = nil, blocker: DormantEligibility.Blocker? = nil) {
        self.text = text
        self.operation = operation
        self.blocker = blocker
    }

    init(_ error: LifecycleError) {
        switch error {
        case .busy(let operation):
            self.init(text: "Another \(operation.rawValue) is already running on this channel. Try again in a moment.",
                      operation: operation)
        case .notEligible(let blocker):
            self.init(text: Self.sentence(for: blocker), blocker: blocker)
        case .heldElsewhere:
            self.init(text: "Another process is holding this session.")
        case .capReached(let live):
            self.init(text: "The live-process cap is reached; \(live) are running.")
        case .precondition(let precondition):
            self.init(text: "A precondition refused this channel: \(Self.name(of: precondition)).")
        case .wedged:
            self.init(text: "This channel's process did not stop and is wedged.")
        case .handoffTimedOut:
            self.init(text: "The handoff to your terminal timed out.")
        case .declineRefused(let reason):
            self.init(text: "The project-server decline was refused: \(reason).")
        case .notOwned:
            self.init(text: "afleet does not own this channel.")
        case .verbFailed(let verb, let exitCode):
            self.init(text: "`claude \(verb)` exited \(exitCode).")
        case .verbTimedOut(let verb, let afterMs, let childState):
            self.init(text: "`claude \(verb)` outlasted \(afterMs) ms; the child was \(childState).")
        case .decisionGone(let id):
            self.init(text: "That decision is no longer open (\(id)).")
        case .answerFailed(_, let reason):
            self.init(text: "The answer could not be written: \(reason).")
        case .logoutInProgress:
            self.init(text: "A logout is running; no channel may spawn until it finishes.")
        }
    }

    /// Every blocker names what is holding the channel. `taskRunning`, `taskArmed` and
    /// `taskStateUncertain` carry a task id and the sentence carries it through: "not now" is
    /// exactly the answer spec §4 forbids.
    private static func sentence(for blocker: DormantEligibility.Blocker) -> String {
        switch blocker {
        case .wedged: "This channel is wedged and cannot be reaped."
        case .turnRunning: "A turn is still running in this channel."
        case .pendingDecision: "A decision is waiting for an answer in this channel."
        case .queuedInput: "Input is still queued in this channel."
        case .taskRunning(let id): "Background task \(id) is still running."
        case .taskArmed(let id): "Background task \(id) is armed and has not started."
        case .taskStateUncertain(let id): "Background task \(id) has not reported since its last heartbeat."
        }
    }

    /// A precondition's kind, never its payload: `untrusted(root:)` carries a path and §11 forbids
    /// one in any surfaced string.
    private static func name(of precondition: SpawnPrecondition) -> String {
        switch precondition {
        case .ready: "ready"
        case .untrusted: "untrusted"
        case .consentNeeded(let servers): "consent needed for \(servers.count) project servers"
        case .managedSettingsPending: "managed settings pending"
        case .contended: "contended"
        case .wedged: "wedged"
        }
    }
}

/// One project in the sidebar: a repository root and the channels running inside it.
///
/// `rows` are the channels whose working directory *is* the repository root. `worktrees` hold the
/// rest, one group per checkout, and are non-empty only when the repository root really does hold
/// several — spec §4's "worktree sub-grouping when one repository root holds several".
struct ProjectSection: Identifiable, Sendable {
    /// The canonical repository root path. Stable across relaunches, which is what makes it usable
    /// as a `SidebarGrouping.sectionOrder` and `collapsed` key.
    let id: String
    var root: URL
    var title: String
    var isPinned: Bool
    var rows: [ChannelRow]
    var worktrees: [WorktreeGroup]

    /// Every row of the section, the root's own first.
    var allRows: [ChannelRow] { rows + worktrees.flatMap(\.rows) }
}

/// One checkout under a repository root.
struct WorktreeGroup: Identifiable, Sendable {
    let id: String
    var root: URL
    var title: String
    var rows: [ChannelRow]
}
