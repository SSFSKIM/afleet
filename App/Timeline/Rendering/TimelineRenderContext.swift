import SwiftUI
import FleetKit
import PanelHostAPI

// MARK: - Collapse state

/// Which clusters and thinking blocks a channel has folded shut.
///
/// A reference type, and shared by every row of one channel, because folding is a property of the
/// *channel's* view state and not of the row that happens to draw the disclosure: a cluster folded
/// while it is off screen has to still be folded when it scrolls back, and the row value that drew
/// it has been discarded twenty times over by then.
///
/// Keyed by `ItemID.key` and never by the `ItemID` itself: the id carries the config home (§11), and
/// a set of them is a set of paths waiting for the first diagnostic that prints it.
@MainActor
@Observable
final class TimelineCollapseState {

    private var collapsedKeys: Set<String> = []

    func isCollapsed(_ id: ItemID) -> Bool { collapsedKeys.contains(id.key) }

    func toggle(_ id: ItemID) {
        if collapsedKeys.remove(id.key) == nil { collapsedKeys.insert(id.key) }
    }
}

// MARK: - The context

/// Everything a row needs that is not its item (child spec §2, §3).
///
/// **It is an environment value and not a second builder parameter.** Contract Y1's builder is
/// `@MainActor (TimelineRow) -> AnyView`, four leaves build against that signature, and C6.3 is
/// writing two of the thirteen builders in a parallel worktree right now. A new parameter would be
/// a signature change in a file two leaves both compile; a new field on a value they already
/// receive is not.
struct TimelineRenderContext {

    /// The channel these rows belong to. Rows carry it into every capability call, so a link opened
    /// from a row is attributed to the channel it was opened from and not to whatever is selected.
    let key: ChannelKey

    /// Where a file link from a tool row goes.
    ///
    /// **`PanelHostModel.links`, which is a plain `let`, and never `context(for:cwd:)`.** That
    /// method mutates the host to make a channel context, and calling it from inside a SwiftUI
    /// `body` mutates observed state during evaluation — tracker 67, and a row evaluates its body
    /// thirty times a second while a message streams.
    let links: any LinkRouterCapability

    /// Contract Y7 — the channel fold's raise site for the host signals no frame states.
    ///
    /// A row that answers something has to tell the fold it answered: `HostSignal.decisionAnswered`
    /// is what moves a decision card out of `.pending`, and the fold has always known how to apply
    /// it while nothing in the tree ever raised one. So the raise travels with the row's other
    /// capabilities, wired to `ChannelTimelineModel.signal(_:)` at the same place the link router is
    /// wired, and **not** defaulted to a no-op for a later leaf to replace. A defaulted capability
    /// nobody assigns is the failure this contract exists to prevent: every gate passes and the card
    /// stays pending for ever, which is tracker 129's shape exactly.
    let signal: @Sendable (HostSignal) async -> Void

    /// Contract Y7's third capability — **the app's one reservation set**, `AppModel.decisions`
    /// (spec §15).
    ///
    /// A request the engine is waiting on is answerable exactly once, and three surfaces can answer
    /// it: Activity's row, the Thread tab and this list's card. Each builds its own
    /// `DecisionAnswering` and they all reserve in *this* set, so the second click finds the id
    /// already taken and sends nothing, and a refused reply keeps its draft. A row that built a set
    /// of its own would disable only itself and reopen the double-answer window, which is what
    /// another leaf's tracker 300 records. It travels here rather than being reached for, because
    /// this value is the only thing a row is handed.
    let decisions: DecisionReservations

    /// The channel's X5 lifecycle, for the two cards another leaf owns whose actions leave this
    /// side: the decision card's `LifecycleAction.answer` and the task card's `stop_task` and
    /// `background_tasks`.
    ///
    /// Nil is a real answer here. A channel with no process — an archived one, or a host built
    /// without a workspace — has nothing to send to, and the rows then draw their reading and offer
    /// no action rather than offering one that goes nowhere.
    let lifecycle: (any LifecycleAPI)?

    /// Where a resolved refusal dialog's retracted uuids go, and what the list filters through
    /// before it draws (spec D11).
    ///
    /// **Both halves of one registry, deliberately.** The card writes into it when a dialog settles
    /// and `TimelineListView.retained(_:by:)` reads it when the rows reach the table; a registry
    /// with only one half wired either retracts nothing or filters nothing, and neither failure is
    /// visible from the other side.
    let retraction: RetractionRegistry

    /// The channel's working directory, which is what a relative path in an item resolves against.
    ///
    /// Nil where the host cannot name one — a channel the index has no cwd for. A relative path is
    /// then not resolved at all, because resolving it against the app's own process directory would
    /// name a different file, and previewing or linking that would be a lie about the item.
    let cwd: URL?

    /// Where an `Agent` chip goes — contract Y4's seam, a no-op until C6.4 fills it.
    let agents: any AgentNavigating

    /// Which clusters and thinking blocks this channel has folded.
    let collapse: TimelineCollapseState

    /// Contract Y6 — this channel's composer, for the three behaviours it owns whose only surface is
    /// a row (§14, gate G6): the *Edit* action, the fork-fallback note, and the intercepted
    /// replacement a row draws **in place of** the frame's own text.
    ///
    /// **Nil is a real answer here and not an unwired capability.** A channel C5 lists read-only has
    /// no composer at all — `ChannelComposerMount` deliberately builds none, because every write in
    /// that leaf leaves through it — so a teammate's transcript offers no *Edit*, which is the gate
    /// the header's owned actions already carry (tracker 74). Undefaulted, on Y7's rule: a
    /// capability the construction site can forget to state is the failure these contracts exist to
    /// prevent.
    let composer: (any ComposerSite)?

    /// Which message this channel's *Edit* was last pressed on, so the composer's one note is drawn
    /// beside that message and not beside every message. Channel-scoped for `collapse`'s reason.
    let editing: TimelineEditState

    /// What a row needs to know about the items *around* it, gathered once per publish (§8, §9).
    ///
    /// A cluster names its members by `tool_use_id` and no member travels inside the cluster item; a
    /// thinking disclosure's duration is the span from the item before it, which is not on the item
    /// either; and an agent chip resolves a run id through the channel's tree. All three are reads
    /// of the same snapshot the rows were built from, so they are gathered where that snapshot is
    /// read rather than by handing every row the whole timeline.
    ///
    /// Defaulted, so a row drawn by a test that cares about none of them constructs no neighbourhood
    /// — and an empty one is the honest answer for a channel whose tree is nil, which is most of
    /// them (tracker 187).
    var neighbourhood = TimelineNeighbourhood()

    /// C3's overlay is stale — the process this channel's pending cards belong to has exited. It is
    /// the second half of D12's `.inert` reading, and a card cannot derive it: it is a property of
    /// the overlay and not of the item. Defaulted, because a row drawn outside a channel's publish
    /// has no overlay to be stale.
    var isOverlayStale: Bool = false

    /// `get_settings`' auto-scroll preference. Task 6 lands the readout that sets it; until then a
    /// channel follows its stream, which is what the engine's own renderer does.
    var autoScrollEnabled: Bool = true

    /// `get_settings`' `syntaxHighlightingDisabled`, inverted so the field reads as what it does.
    /// Parity §41.17 records it as an accessibility choice for some users, so it is a preference the
    /// renderer honours rather than a debug switch. Task 5 lands the readout that sets it; until
    /// then fenced blocks are highlighted, which is what the engine's own renderer does.
    var syntaxHighlightingEnabled: Bool = true
}

// MARK: - What a row builds through the context

/// The two objects a row cannot build for itself, built here (contract Y7, spec §15).
///
/// **They are built through the context rather than handed down ready-made** because both hold
/// per-surface state a row is entitled to its own copy of — a refusal banner, a card's in-flight
/// flag — while the state that must *not* be duplicated, the reservation set, is the context's and
/// is passed in. One shared set, one banner per card, is the split contract Y2 asks for.
extension TimelineRenderContext {

    /// The object a decision card's answer leaves by.
    ///
    /// Two things are wired here and each is a way for the mount to be silently wrong: the
    /// reservation set is **this context's**, so a second surface answering the same request finds
    /// the slot taken; and `raise` is **this context's `signal`**, so a successful answer reaches
    /// the channel's fold. The engine sends no frame back for an answer, so a raise that went
    /// nowhere would leave the card reading `.pending` for ever with every gate on both leaves
    /// green — which is the failure Y7 exists to prevent.
    ///
    /// Nil for a channel with no process: nothing to answer through, and the row draws its reading.
    @MainActor
    func makeAnswering() -> DecisionAnswering? {
        guard let lifecycle else { return nil }
        let answering = DecisionAnswering(lifecycle: lifecycle, reservations: decisions)
        answering.raise = { [signal] _, hostSignal in await signal(hostSignal) }
        return answering
    }

    /// Contract Y2's second host: the model behind `TaskCardView` on the `taskRun` row.
    ///
    /// **The registry mirror is empty, and that is a known gap rather than a placeholder.** §8.4
    /// offers *Move to background* only for a task C3's `RegistryMirror` knows, and no mirror is
    /// reachable from the timeline's read model — `ChannelTimeline` carries the overlay, the durable
    /// half and the preview, and the fold's mirror is inside the ingestion. So the card offers
    /// *Stop*, which reads the item's own status, and never offers the backgrounding action.
    /// Tracker 321.
    @MainActor
    func makeTaskCard(_ item: TaskRunItem) -> TaskCardModel? {
        guard let lifecycle else { return nil }
        return TaskCardModel(item: item, registry: RegistryMirror(), lifecycle: lifecycle, channel: key)
    }
}

// MARK: - The neighbourhood

/// The reads a row makes of the timeline it sits in, taken once per publish.
///
/// A value and not a closure: a closure over the model would let a row evaluate its body against a
/// timeline newer than the rows around it, and the three lookups here are cheap dictionaries built
/// from the snapshot the rows themselves came from.
struct TimelineNeighbourhood {

    /// Every tool call in the channel, by its `tool_use_id`. A cluster expands through this and an
    /// `Agent` chip finds its parallel siblings through it.
    var toolCalls: [String: ToolCallItem] = [:]

    /// The timestamp of the item before each item, by `ItemID.key`.
    ///
    /// Keyed by the **key string** and never by `ItemID`, which carries the config home (§11).
    var precedingTimestamps: [String: Date] = [:]

    /// The channel's agent-run tree, consulted by the chip for one thing only: the run id
    /// `AgentNavigating.show(run:in:)` takes.
    ///
    /// **Nil is the ordinary case, not the edge.** A channel opened from its files — every archived
    /// channel and every foreign session — has no tree at all (tracker 187 on `main`), so the chip
    /// is designed for nil: it renders from what the call carries and simply does not navigate,
    /// because navigating to a fabricated run id would land C6.4 on a node that does not exist.
    var agents: AgentRunTree?

    /// The neighbourhood of one channel's items.
    init(items: [TimelineItem] = [], agents: AgentRunTree? = nil) {
        self.agents = agents
        var previous: Date?
        for item in items {
            if case .toolCall(let call) = item { toolCalls[call.toolUseID] = call }
            if let previous { precedingTimestamps[item.id.key] = previous }
            previous = item.timestamp ?? previous
        }
    }

    /// The calls one cluster names, in the order the cluster names them, skipping any the channel
    /// does not hold.
    func members(of cluster: ToolClusterItem) -> [ToolCallItem] {
        cluster.toolUseIDs.compactMap { toolCalls[$0] }
    }
}

// MARK: - The environment value

private struct TimelineRenderContextKey: EnvironmentKey {
    /// Computed rather than stored: a stored default would be a non-`Sendable` global, and the
    /// answer for a subtree nobody injected into is "no context" rather than an invented one.
    static var defaultValue: TimelineRenderContext? { nil }
}

extension EnvironmentValues {
    /// The render context on the timeline's subtree.
    ///
    /// **Optional, and deliberately without an inert stand-in.** The alternative — a default context
    /// whose capabilities are empty closures — is what lets a row call a capability, succeed, and do
    /// nothing, which is the failure Y7 exists to prevent. With no default there is nothing to call:
    /// a row outside the timeline's subtree cannot reach a capability at all, so a mount that forgot
    /// to inject the context is a row that visibly has no affordance rather than one whose
    /// affordance silently goes nowhere. A preview or a reflection-only test sees nil and draws.
    var timelineContext: TimelineRenderContext? {
        get { self[TimelineRenderContextKey.self] }
        set { self[TimelineRenderContextKey.self] = newValue }
    }
}
