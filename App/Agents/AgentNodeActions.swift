import AppKit
import Foundation
import Observation
import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI

/// What a user can do to one agent run from its node in the tree (root §8.8, gate G3).
///
/// **Everything here is X5, and none of it is a second opinion about a request** (contract Y5). Two
/// of the actions are the *same two control requests* `TaskCardModel` sends from the `taskRun` row
/// — `stop_task {task_id}` and `background_tasks {tool_use_id}` — and contract Y2's rule is that the
/// second host reuses the first's derivation rather than re-deriving it: eligibility is
/// `TaskCardModel.isEligible(_:)` over C3's registry mirror, and a refusal is worded by
/// `TaskCardModel.banner(for:)`. What is different here is only the **subject**: the card is built
/// over a `TaskRunItem` the timeline holds, and a tree node is not one.
///
/// **`{backgrounded: false}` is a success body and not a success.** It is the engine saying the
/// registry entry the panel read is stale or ineligible (§8.4, item 61's first arm), so the action
/// goes for that run, the read is dropped and rebuilt, and nothing reports that the run moved. A
/// handler that treated any non-throwing reply as success would tell the user their run is in the
/// background while it is still in the foreground, and no other assertion in this file would notice.
///
/// **The refusal is a different arm.** "Background tasks are disabled in this session." arrives as a
/// **control error**, before the engine consults its task registry at all, and §6.4's table says it
/// hides both backgrounding affordances for that process. So a control error disables backgrounding
/// for the whole channel, while any other failure is a banner and nothing more: a transport hiccup
/// is not the session refusing.
///
/// **One object per (tab, channel)**, held by the session, so the disabled reading and the confirm
/// in flight belong to the channel they were raised on.
@MainActor
@Observable
final class AgentNodeActions {

    private let lifecycle: any LifecycleAPI
    private let channel: ChannelKey
    /// The **channel's** link router — X7's `ChannelContext.links`, which is where a panel raises a
    /// link (child spec D12). Nothing here opens the file it names: C5's TCC fact binds and a `.file`
    /// link's target is the Files panel's, so this side raises the link and stops.
    private let links: (any LinkRouterCapability)?
    /// Where *Copy agent id* writes. The general board in the app; a named board under test, so a
    /// suite never touches the user's clipboard.
    private let pasteboard: NSPasteboard

    /// How the panel drops the derived read after the engine has contradicted it. The read is
    /// recomputed from the published timeline, so there is nothing to re-fetch — what has to happen
    /// is that the cached derivation stops being answered. Assigned by the session; the default
    /// refreshes nothing, which is right for an object built with no read behind it.
    var refresh: @MainActor () -> Void = {}

    /// Why the last request did not happen, or nil. The engine's own sentence where it sent one
    /// (§6.3, §11: a type name carries no path, no id and no title).
    private(set) var banner: RowBanner?

    /// The engine has refused backgrounding for **this process** (§6.4). Both affordances go: the
    /// per-node *Move to background* and the tree's *Background all*.
    private(set) var backgroundingDisabled = false

    /// Runs whose mirror row the engine has said is stale — `{backgrounded: false}` — each against
    /// **the `tool_use_id` that reply was about**. The affordance goes for that run alone, because
    /// that is the whole of what the reply said.
    ///
    /// **Against what the row was when the engine contradicted it, so the reading expires.** What
    /// `{backgrounded: false}` says is that *this* row is stale — not that the run can never be
    /// backgrounded. Held against the run alone it never came back: one reply took *Move to
    /// background* away for the life of the panel, including from a run the engine has since
    /// re-engaged and the registry is currently offering, with nothing on screen to say why.
    ///
    /// So the reading is held against the row, and a row the engine has moved on from supersedes
    /// it. Two things move: the run starting again — a fresh `task_started`, which is what
    /// re-engagement *is* — and the `tool_use` block being replaced. Either supersedes; neither
    /// changing does not, because a second press on the row the engine has already called stale is
    /// exactly the press this exists to withhold.
    ///
    /// Epoch-scoping the session-wide refusal stays filed as tracker 179; this is the half that
    /// costs a dictionary.
    private(set) var staleBackgrounding: [AgentRunID: StaleRow] = [:]

    /// The registry row a `{backgrounded: false}` was about, as the two facts on a node's content
    /// that move when the engine re-engages the run or names another block. A payload-free value:
    /// a count and an id that is already on the node, and nothing derived from either is reported.
    struct StaleRow: Hashable, Sendable {
        let toolUseID: String?
        let startedCount: Int

        init(_ content: AgentNodeContent) {
            toolUseID = content.backgroundToolUseID
            startedCount = content.startedCount
        }
    }

    /// A request is on the wire. The actions disable on it, so two clicks send once.
    private(set) var inFlight = false

    /// What the last `background_tasks` round trip concluded. `.stale` is deliberately not `.moved`:
    /// the distinction is the one this action exists to keep.
    enum BackgroundOutcome: Hashable, Sendable { case moved, stale, refused }

    private(set) var lastBackgrounding: BackgroundOutcome?

    /// Where a *Send message* is recorded (item 51, contract Y8). App-scoped and handed in: the row
    /// that draws the delivery state is on the **main timeline**, which outlives this panel session,
    /// so a registry of this object's own would hold a state nothing on the channel column could
    /// read. Nil for a panel built before a launch reached a workspace, and *Send message* is then
    /// absent for the same reason every other action is.
    private let relay: AgentRelayRegistry?

    /// How the `HostSignal.promptSent` raise that is inseparable from a send reaches the channel's
    /// fold — `ChannelFold.raise`, this channel's own.
    ///
    /// A send that skipped the raise would leave the turn it caused reducing as `.unprompted`: the
    /// fold would disagree with the engine about who asked for it, and this leaf's own `noCall` arm
    /// reads `TurnAttribution.prompted` to know the turn closed. So the two are one function here,
    /// exactly as `ComposerModel.post(_:)` makes them one.
    private let raiseSignal: (ChannelKey, HostSignal) async -> Void

    init(lifecycle: any LifecycleAPI, channel: ChannelKey,
         links: (any LinkRouterCapability)? = nil, pasteboard: NSPasteboard = .general,
         relay: AgentRelayRegistry? = nil,
         raiseSignal: @escaping (ChannelKey, HostSignal) async -> Void = { _, _ in }) {
        self.lifecycle = lifecycle
        self.channel = channel
        self.links = links
        self.pasteboard = pasteboard
        self.relay = relay
        self.raiseSignal = raiseSignal
    }

    // MARK: - What a node offers

    /// *Stop* exists while the run is running and nowhere else — `TaskCardModel.offersStop`'s rule,
    /// read off the node rather than off a `TaskRunItem`.
    func offersStop(_ content: AgentNodeContent) -> Bool {
        content.status == .running && !inFlight
    }

    /// *Move to background* — §8.8's clause, which is §8.4's over the tree's subject.
    ///
    /// The eligibility half is the mirror's and is decided once, where the node's content is built:
    /// `AgentNodeContent.backgroundToolUseID` is non-nil exactly when `TaskCardModel.isEligible(_:)`
    /// says the run is running, in the foreground, of a kind the engine can move, and has a
    /// `tool_use_id` to name. What this object adds is the three facts the mirror cannot know — a
    /// request already in flight, a session that refused, and a row the engine has called stale.
    func offersMoveToBackground(_ content: AgentNodeContent) -> Bool {
        guard !backgroundingDisabled, !inFlight, content.backgroundToolUseID != nil else { return false }
        return staleBackgrounding[content.id] != StaleRow(content)
    }

    // MARK: - The two control requests

    /// *Stop*: `stop_task {task_id}` with the node's own id, on the node's channel.
    ///
    /// It takes the node's content and not a bare string, so a caller cannot hand it the run's
    /// `tool_use_id`: the two are different namespaces and both are `String`.
    func stop(_ content: AgentNodeContent) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            _ = try await lifecycle.send(AnyControlRequest(StopTask(taskID: content.id)), on: channel)
            banner = nil
        } catch {
            banner = TaskCardModel.banner(for: error)
        }
    }

    /// *Move to background*: `background_tasks {tool_use_id}` → `{backgrounded: <bool>}`.
    ///
    /// The three arms are the three things the engine can say, and they are three different
    /// outcomes: moved, stale, refused. Nothing is concluded from the call having returned.
    func moveToBackground(_ content: AgentNodeContent) async {
        guard let toolUseID = content.backgroundToolUseID, !inFlight, !backgroundingDisabled else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let reply = try await lifecycle.send(AnyControlRequest(BackgroundTasks(toolUseID: toolUseID)),
                                                 on: channel)
            banner = nil
            guard reply["backgrounded"]?.boolValue == false else {
                lastBackgrounding = .moved
                return
            }
            // The entry the panel read is stale or ineligible. The action goes for this run, the
            // derived read is dropped so the next body takes whatever the timeline now says, and
            // nothing reports success.
            lastBackgrounding = .stale
            staleBackgrounding[content.id] = StaleRow(content)
            refresh()
        } catch {
            lastBackgrounding = .refused
            note(error)
        }
    }

    /// The engine's refusal when this session does no background work at all — root §8.4's table and
    /// parity §20.13.2, where `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` removes the capability from the
    /// process. It arrives as a control **error**, before the task registry is consulted, which is
    /// why it cannot be read out of a `{backgrounded: false}` body.
    static let backgroundingRefusal = "Background tasks are disabled in this session."

    /// Whether a failure is that refusal, rather than any other way a request can fail.
    ///
    /// **Matched on the sentence and not merely on "a control error on a backgrounding request".**
    /// §6.4 hides both affordances for the *process*, and this reading is not undone until the panel
    /// is rebuilt — so a transient control error that hid them would take backgrounding away from a
    /// channel that can still do it, with nothing to put it back. The sentence is the engine's own
    /// and is what the table names.
    static func refusesBackgrounding(_ error: any Error) -> Bool {
        guard case WireError.controlError(let reason) = error else { return false }
        return reason.contains(backgroundingRefusal)
    }

    /// What a failed backgrounding request leaves behind: the engine's own sentence as a banner, and
    /// — only for the refusal — the session-wide reading that hides both affordances (§6.4).
    private func note(_ error: any Error) {
        banner = TaskCardModel.banner(for: error)
        if Self.refusesBackgrounding(error) { backgroundingDisabled = true }
    }

    // MARK: - The two that send nothing

    /// *Open transcript file*: one `WorkspaceLink.file` on the channel's router (child spec D12).
    ///
    /// The url is `AgentRunTree.transcriptURL(of:)`, composed from the config home, the session id
    /// and the tree's *current* slug on every call — so it answers during the run and not only at
    /// completion (parity §18.25), and a project that is renamed moves every run's path at once.
    ///
    /// **No descriptor is opened on it here.** C5's TCC fact binds — a read of a file under the
    /// config home is the user's grant to spend — and the `.file` link's target is the Files panel's,
    /// which is the one reader this app has for a transcript. Raising the link is the whole action.
    ///
    /// Fire-and-forget for `FileLink`'s reason: `LinkRouterCapability.open` is `async` and a button's
    /// action is not.
    func openTranscript(at url: URL) {
        guard let links else { return }
        Task { await links.open(.file(url, line: nil), from: .currentPanel) }
    }

    // MARK: - The two channel-wide actions, and the confirm in front of them

    /// The confirm this channel is waiting on, or nil. One at a time, and the **panel's own** —
    /// never the composer's, which a popped-out window and a read-only channel both lack (D14).
    private(set) var pending: AgentTreeConfirm?

    /// Which raise the confirm slot currently belongs to.
    ///
    /// **Only *Stop everything* suspends before it can present.** It takes the fleet's census first,
    /// because the count is what its dialog is for, and everything that touches the slot — the other
    /// button, the affirmative, the decline — happens synchronously while that census is in the air.
    /// So a census that came back late could write its dialog over a *Background all* the user
    /// raised after pressing it, and the affirmative would then stop every running task for someone
    /// who asked to background them. That is work `--resume` cannot restore, decided by a race.
    ///
    /// The counter moves on every one of those events, and a census whose number has moved answers
    /// nothing: the slot belongs to whoever took it last, and a stale raise is dropped rather than
    /// resolved. A generation and not a "is anything pending" check, because the second cannot tell
    /// a slot that was taken and released from one that was never touched.
    private var raise = 0

    /// Raises *Stop everything*'s confirm **after taking the census**, because the count is what the
    /// dialog is for: the user is being told the size of the work they are about to end.
    ///
    /// The census is X5's own — `LifecycleAPI.liveTaskIDs(of:)`, the fleet's fact — and not the
    /// fold's, for the reason the header's handoff takes it there: the action ends work in a channel
    /// whether or not this window has ever drawn its timeline, and a fold-derived count answers
    /// "nothing is running" for every one of those. A count reaches the dialog and the ids do not
    /// (§6.3, §11).
    func requestStopEverything() async {
        raise += 1
        let mine = raise
        let live = await lifecycle.liveTaskIDs(of: channel)
        // Someone took the slot while the census was in the air. This dialog is for a press the user
        // has moved on from, and presenting it now would replace what they are looking at.
        guard mine == raise else { return }
        pending = .stopEverything(liveTaskCount: live.count)
    }

    /// *Background all*'s confirm. No census: the action stops nothing, so there is no cost to size.
    func requestBackgroundAll() {
        raise += 1
        pending = .backgroundAll
    }

    /// Takes the waiting confirm whole and leaves nothing behind, so a dismissal arriving after this
    /// has nothing left to clear.
    func claimPending() -> AgentTreeConfirm? {
        raise += 1
        defer { pending = nil }
        return pending
    }

    /// The waiting confirm, answered yes: **claimed synchronously**, run in a task.
    ///
    /// The two halves are separate calls because SwiftUI runs the dialog's dismissal — which is
    /// `cancelPending()` — before the affirmative button's own work has a chance to begin. An action
    /// that read `pending` when its `Task` started would read a value already cleared and do nothing.
    func answerPending() {
        guard let claim = claimPending() else { return }
        Task { await perform(claim) }
    }

    /// Declined. **Nothing is performed** — the clause the confirm exists for, and the one a dialog
    /// wired to a no-op would pass every other way.
    func cancelPending() {
        raise += 1
        pending = nil
    }

    /// A claimed confirm, run. The only place either action is issued, and neither is reimplemented:
    /// `Fleet` owns what *Stop everything* and *Background all* mean (contract Y5).
    private func perform(_ confirm: AgentTreeConfirm) async {
        do {
            _ = try await lifecycle.perform(confirm.action, on: channel)
            banner = nil
        } catch {
            // *Background all* is `background_tasks` with no `tool_use_id`, so it meets the same
            // refusal the per-node action does and hides the same two affordances. *Stop everything*
            // cannot, which `refusesBackgrounding(_:)` decides by the sentence rather than by which
            // button was pressed.
            note(error)
        }
    }

    /// *Copy agent id*: the node's id on the pasteboard, and nothing logged (child spec D12).
    ///
    /// It is the one place a task id legitimately leaves the app, at the user's explicit request.
    /// §11's rule is about reports, not about the user's own clipboard — so this writes the id and
    /// records, prints and traces nothing about it.
    func copyAgentID(_ content: AgentNodeContent) {
        pasteboard.clearContents()
        pasteboard.setString(content.id, forType: .string)
    }

    // MARK: - Send message (item 51)

    /// *Send message* exists wherever there is somewhere to record what became of it. It is offered
    /// for a completed run as readily as for a running one — resuming a completed agent is the whole
    /// of what item 51's own scenario does, and the engine's refusal to resume one is an arm this
    /// leaf draws rather than a case it withholds the affordance for.
    func offersSendMessage(_ content: AgentNodeContent) -> Bool { relay != nil && !inFlight }

    /// Asks the main agent to relay `text` to this run, and records that it asked.
    ///
    /// **The send is X5 and nothing else** (contract Y5): `sendPrompt(UserInput, on:)` followed by
    /// the `HostSignal.promptSent` raise that is inseparable from it, which is `ComposerModel.post`'s
    /// pattern — the raise **after** the call succeeds, never before, so a refused send leaves the
    /// fold holding no prompt the engine was never given.
    ///
    /// **Nothing here concludes anything about delivery.** The record opens `.pending` and the state
    /// is derived from the frames afterwards; a send that reported success on the call returning is
    /// exactly the silent non-delivery item 51 exists to prevent.
    ///
    /// `retryOf` is the record this send is retrying, and it is *lineage* rather than a mutation: the
    /// failed record keeps its state and its place, and this one records what it descended from.
    @discardableResult
    func sendMessage(_ text: String, to content: AgentNodeContent,
                     retryOf: AgentRelayRecord.ID? = nil) async -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relay, !message.isEmpty, !inFlight else { return false }
        inFlight = true
        defer { inFlight = false }
        return await Self.relay(message, to: content, through: send, recordingIn: relay, retryOf: retryOf,
                                reporting: { [weak self] banner in self?.banner = banner })
    }

    /// The send's app-scoped half, as one value: the fleet, the channel and the fold's raise. All
    /// three outlive this object, which is what lets a *Retry* run after the panel is gone.
    private var send: AgentRelaySend {
        AgentRelaySend(lifecycle: lifecycle, channel: channel, raiseSignal: raiseSignal)
    }

    /// The send itself, **held by nothing that a panel host can evict**.
    ///
    /// The relay registry is app-scoped because the delivery state is drawn on the main timeline's
    /// row, which outlives the Agents tab — so the *Retry* the row offers has to outlive it too. A
    /// resend that captured this object captures a per-(tab, channel) session the host releases the
    /// moment the channel's panel is dropped or *Check again* rebuilds the workspace: the record
    /// goes on offering *Retry*, and pressing it sends nothing at all. So the resend captures the
    /// three app-scoped capabilities and takes the registry as an argument; the panel is reached
    /// only through `report`, which is weak and does nothing more than word a banner on a surface
    /// that may no longer be on screen.
    @MainActor
    @discardableResult
    static func relay(_ message: String, to content: AgentNodeContent, through send: AgentRelaySend,
                      recordingIn relay: AgentRelayRegistry, retryOf: AgentRelayRecord.ID? = nil,
                      reporting report: @escaping @MainActor (RowBanner?) -> Void) async -> Bool {
        do {
            let minted = try await send.lifecycle.sendPrompt(UserInput(text: prompt(relaying: message, to: content)),
                                                             on: send.channel)
            await send.raiseSignal(send.channel, .promptSent(uuid: minted.uuidString.lowercased(), at: Date()))
            report(nil)
            relay.open(promptUUID: minted.uuidString.lowercased(),
                       target: content.id,
                       textDigest: AgentRelayDigest.of(message),
                       in: send.channel,
                       retryOf: retryOf,
                       // *Retry* re-sends by this same path. The text lives in this capture and
                       // nowhere a report can reach (§11); the record keeps a digest. The registry
                       // arrives as an argument rather than in the capture, so the closure the
                       // registry stores does not hold the registry.
                       resend: { previous, registry in
                           await AgentNodeActions.relay(message, to: content, through: send,
                                                        recordingIn: registry, retryOf: previous,
                                                        reporting: report)
                       })
            return true
        } catch let error as LifecycleError {
            // afleet's own refusal rather than the engine's, worded where C5 already words it.
            report(RowBanner(error))
            return false
        } catch {
            report(TaskCardModel.banner(for: error))
            return false
        }
    }

    /// The prompt afleet composes — an **ordinary main-session user message**, because that is the
    /// only path there is: no host-initiated resume or messaging control exists (parity §18.25), so
    /// the main agent's own `SendMessage` tool is the relay and asking for it is asking the model.
    ///
    /// It names the run by the id the engine minted, because without agent teams an agent is
    /// addressable by nothing else (parity §18.26), and it names the type and description so the
    /// sentence reads as a request about a run the user can see rather than about an opaque id.
    ///
    /// **It does not impersonate anything** (§7.8): it is the user's own message, in the user's own
    /// turn, saying what the user asked for.
    static func prompt(relaying message: String, to content: AgentNodeContent) -> String {
        let named = [content.agentType, content.description.isEmpty ? nil : "“\(content.description)”"]
            .compactMap { $0 }
            .joined(separator: ", ")
        let subject = named.isEmpty ? "the agent with id \(content.id)"
                                    : "the agent with id \(content.id) (\(named))"
        return """
        Use your SendMessage tool to send the message below to \(subject). \
        Send the message exactly as written, and add nothing to it.

        \(message)
        """
    }
}

/// What a *Send message* needs that is **not** the panel's: X5's fleet, the channel it acts on, and
/// the fold's `HostSignal.promptSent` raise that is inseparable from the send (contract Y5).
///
/// A value rather than three captures, so the retry path and the first press take the same three
/// things by the same name — and so that what a stored resend closure holds is legible at the one
/// place it is built.
@MainActor
struct AgentRelaySend {
    let lifecycle: any LifecycleAPI
    let channel: ChannelKey
    let raiseSignal: (ChannelKey, HostSignal) async -> Void
}

/// The actions on the open node, drawn (gate G3).
///
/// Stored as a value the row holds rather than built inside a `ForEach` closure, for the reason
/// `AgentOutline`'s rows are: `Mirror` does not enter a closure, so a test can only be told what a
/// surface offers if the surface holds it.
///
/// They are drawn for the **open** node rather than on every row: the tree is a list of short rows
/// and four buttons on each would be a different surface. The affordances a run does not have are
/// absent rather than disabled — an offer the engine would refuse is worse than no offer.
struct AgentNodeActionBar: View {

    let content: AgentNodeContent
    let actions: AgentNodeActions
    /// Where this run's transcript is, as C3 composes it. Nil for a run whose tree does not hold one,
    /// and the affordance is then absent rather than pointing at a path nobody answered for.
    var transcriptURL: URL?
    /// What became of the messages already relayed to this run (item 51). Drawn on the node as well
    /// as on the main timeline's row, because the node is where the user acted; the row is where
    /// contract Y8 makes sure they meet it without opening this tab at all.
    var relays: [AgentRelayReading] = []

    @State private var composing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            buttons
            ForEach(Array(relays.enumerated()), id: \.offset) { _, reading in
                AgentRelayNote(reading: reading)
            }
        }
        .sheet(isPresented: $composing) {
            SendMessageSheet(content: content, actions: actions, dismiss: { composing = false })
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            if actions.offersStop(content) {
                Button("Stop") { Task { await actions.stop(content) } }
            }
            if actions.offersMoveToBackground(content) {
                Button("Move to Background") { Task { await actions.moveToBackground(content) } }
            }
            if let transcriptURL {
                Button("Open Transcript File") { actions.openTranscript(at: transcriptURL) }
            }
            Button("Copy Agent ID") { actions.copyAgentID(content) }
            // *Send message*, with a delivery state behind it. Absent — rather than drawn and inert
            // — where there is nowhere to record what became of it: an affordance that sent a prompt
            // and concluded success the moment the call returned is exactly the silent
            // non-delivery item 51 exists to refuse.
            if actions.offersSendMessage(content) {
                Button("Send Message…") { composing = true }
            }
        }
        .font(.caption)
    }
}
