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

    /// Whether this channel is one afleet may act on — C5's `ChannelRow.offersOwnedActions`, the
    /// gate tracker 74 puts on every owned action and the one the composer mount already asks.
    ///
    /// **Separate from `lifecycle`, because they answer different questions.** The lifecycle is
    /// *what* a request would leave by; this is whether the channel is ours to send one on at all. A
    /// colleague's transcript is read out of a file and draws the same rows the owner's does —
    /// including a task that was running when the file was written — so without this gate a row
    /// offers an action X5 refuses as `notOwned` after it has been pressed. An affordance that is
    /// there, does nothing, and explains itself only afterwards is the failure Y7 is about.
    let isOwned: Bool

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

    /// Who the assistant's messages on this surface are by, when the surface is not the channel's
    /// own thread.
    ///
    /// **Nil is the default and is the channel's own reading**, so nothing about the channel column
    /// moves: a row drawn without one is authored exactly as it was before this field existed. An
    /// agent run's transcript supplies one, because acceptance item 38 wants a subagent's messages
    /// authored by the *agent type* with the *run's* badge and never by "Claude" — and that is a
    /// property of the surface rather than of any row. Every row of one run shares it, and a row
    /// that derived it for itself would have to reach the channel's run tree from inside a message.
    var authorship: TimelineAuthorship?
}

/// Who a surface's assistant messages are by, and on which model (root §8.8, item 38).
///
/// Two strings and nothing else: the fields a row's frame already draws. It carries no run id, no
/// node and no tree — a value that carried the run would put a task id inside every row's context
/// for the first diagnostic that prints one (§11), and the row has no use for it.
struct TimelineAuthorship: Equatable, Sendable {

    /// The name above the message. Sanitised by whoever built it, at the boundary where the wire
    /// string became content — this value re-strips nothing and inherits the strip.
    let author: String

    /// The badge beside the name, or nil where the surface knows of none and the row should fall
    /// back to the message's own model.
    let badge: String?
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
    /// **The registry mirror is the channel's own, read from the same snapshot the rows came from.**
    /// §8.4 offers *Move to background* only for a running Bash call or agent run C3's
    /// `RegistryMirror` knows, with a `tool_use_id` to name in the `background_tasks` request, so a
    /// card built over an empty mirror can only ever offer *Stop* — which is what this did until the
    /// mirror reached `ChannelTimeline` (tracker 321). It comes through the neighbourhood, with the
    /// other reads of the timeline a row makes, and **not** from `ChannelEventPump.mirror`, which is
    /// Activity's: reaching that from a row would be the second capability path C6's cut exists to
    /// prevent. A channel with no fold carries an empty mirror and the action is absent, which is
    /// the same reading it had before — absent rather than wrong.
    ///
    /// This is contract Y2's rule, held by both hosts at once: the Thread tab's card and this one
    /// are the same component over the same mirror, so they offer the same action on the same run.
    ///
    /// **Gated on the channel as well as on the process.** `TaskCardModel.offersStop` reads the
    /// item's status alone, and a `taskRun` item is read out of the transcript — so a colleague's
    /// session shows a running task as readily as ours does. Nil for a channel afleet does not own,
    /// and the row then draws its reading, which is exactly what it draws for an archived one.
    /// **`refresh` is wired to this channel's own neighbourhood.** §8.4's `{backgrounded: false}` arm is
    /// the engine saying the entry the card was reading is stale or ineligible, and the card then takes
    /// whatever the timeline now says the run is. Left at its default the closure answers nil and the
    /// card keeps the item and the mirror it was built with, which is the reading the engine has just
    /// contradicted. It reads the neighbourhood — the same snapshot the row itself came from — so the
    /// card cannot be handed a run from a publish the rows around it never saw.
    @MainActor
    func makeTaskCard(_ item: TaskRunItem) -> TaskCardModel? {
        guard offersTaskCard, let lifecycle else { return nil }
        let card = TaskCardModel(item: item, registry: neighbourhood.registry, lifecycle: lifecycle, channel: key)
        card.refresh = { [taskRuns = neighbourhood.taskRuns, taskID = item.taskID] in taskRuns[taskID] }
        return card
    }

    /// Whether a task on this channel gets a card at all — the gate above, named so that the row
    /// keying its cached card can ask the same question the builder answers. A card is `@State`
    /// behind an identity, so a gate the identity cannot see is a card that outlives it.
    var offersTaskCard: Bool { isOwned && lifecycle != nil }
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

    /// Every task run in the channel, by its `task_id` — what a card re-reads when the engine
    /// contradicts the item it was built with (§8.4's `{backgrounded: false}` arm).
    var taskRuns: [String: TaskRunItem] = [:]

    /// The timestamp of the item before each item, by `ItemID.key`.
    ///
    /// Keyed by the **key string** and never by `ItemID`, which carries the config home (§11).
    var precedingTimestamps: [String: Date] = [:]

    /// The channel's agent-run tree, consulted by the chip for one thing only: the run id
    /// `AgentNavigating.show(run:in:)` takes.
    ///
    /// **Nil means the channel has not opened yet, and the chip is designed for it**: it renders
    /// from what the call carries and simply does not navigate, because navigating to a fabricated
    /// run id would land C6.4 on a node that does not exist. It is no longer the ordinary reading
    /// for a channel opened from its files — those are fed from their `.meta.json` sidecars and
    /// carry a tree like any other (tracker 187, closed).
    var agents: AgentRunTree?

    /// The channel's background-task registry mirror, for the one thing §8.4 gates on it: whether a
    /// task card offers *Move to background*, and the `tool_use_id` the request names.
    ///
    /// Here rather than a field of its own on the context, because it is a read of the published
    /// timeline taken once per publish, which is exactly what this value is for. Empty for a channel
    /// with no fold, which offers the action on nothing.
    var registry = RegistryMirror()

    /// The part of that mirror anything downstream is allowed to compare — what a card can read of it.
    /// The cache below and the table's reload comparison are both keyed by this and never by the
    /// mirror, so a run's heartbeat costs nothing and a run's *eligibility* still re-keys the card.
    private(set) var eligibility = TaskCardEligibility()

    /// The neighbourhood of one channel's items.
    init(items: [TimelineItem] = [], agents: AgentRunTree? = nil, registry: RegistryMirror = RegistryMirror()) {
        self.agents = agents
        self.registry = registry
        self.eligibility = TaskCardEligibility(registry)
        var previous: Date?
        for item in items {
            if case .toolCall(let call) = item { toolCalls[call.toolUseID] = call }
            if case .taskRun(let run) = item { taskRuns[run.taskID] = run }
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

/// The channel's neighbourhood, rebuilt only when the items behind it moved.
///
/// **Why a cache and not a construction.** Building one traverses every item in the channel and
/// fills two dictionaries from them, and `ChannelTimeline.items` merges and sorts the durable and
/// overlay halves to hand it that traversal. The list's body evaluates on every streaming publish —
/// thirty a second while a message streams — and a preview delta changes no item at all, so what
/// was paid per delta grew with the history the reader had accumulated, which is the growth §8.3
/// forbids. Held for the channel's lifetime and asked per publish.
///
/// The key is the published timeline with its preview and its registry mirror taken off, and the
/// mirror's *eligibility* beside it: any change that can move an item, an overlay or the agent tree
/// changes the first, and the preview alone does not. Comparing it is cheap where it matters — the
/// collections behind an unchanged half are the same storage, which their equality answers on
/// identity without walking them.
///
/// **The mirror is out of the key on purpose.** `RegistryMirror` stamps `lastFrameAt` on every task
/// frame, so a chatty agent moved the key thirty times a second and paid an O(items) rebuild for each
/// — the growth §8.3 forbids, reintroduced by a field a card reads four values out of. What the card
/// can read is `TaskCardEligibility`, and that is what is compared. The reused neighbourhood keeps the
/// mirror it was built with, which differs from the current one only in what nothing reads.
@MainActor
final class TimelineNeighbourhoodCache {

    /// How many neighbourhoods this cache has had to build. Counted for the reason the table's
    /// reloads are: a cost nothing can read is a cost nothing can hold.
    private(set) var builds = 0

    private var key: ChannelTimeline?
    private var cached = TimelineNeighbourhood()

    func neighbourhood(for timeline: ChannelTimeline) -> TimelineNeighbourhood {
        var key = timeline
        key.preview = nil
        key.registry = RegistryMirror()
        let eligibility = TaskCardEligibility(timeline.registry)
        if let held = self.key, held == key, eligibility == cached.eligibility { return cached }
        cached = TimelineNeighbourhood(items: timeline.items, agents: timeline.agents, registry: timeline.registry)
        self.key = key
        builds += 1
        return cached
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
