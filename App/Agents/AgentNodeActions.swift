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

    /// Runs whose mirror row the engine has said is stale — `{backgrounded: false}`. The affordance
    /// goes for that run alone, because that is the whole of what the reply said.
    private(set) var staleBackgrounding: Set<AgentRunID> = []

    /// A request is on the wire. The actions disable on it, so two clicks send once.
    private(set) var inFlight = false

    /// What the last `background_tasks` round trip concluded. `.stale` is deliberately not `.moved`:
    /// the distinction is the one this action exists to keep.
    enum BackgroundOutcome: Hashable, Sendable { case moved, stale, refused }

    private(set) var lastBackgrounding: BackgroundOutcome?

    init(lifecycle: any LifecycleAPI, channel: ChannelKey,
         links: (any LinkRouterCapability)? = nil, pasteboard: NSPasteboard = .general) {
        self.lifecycle = lifecycle
        self.channel = channel
        self.links = links
        self.pasteboard = pasteboard
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
        guard !backgroundingDisabled, !inFlight, !staleBackgrounding.contains(content.id) else { return false }
        return content.backgroundToolUseID != nil
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
            staleBackgrounding.insert(content.id)
            refresh()
        } catch {
            lastBackgrounding = .refused
            banner = TaskCardModel.banner(for: error)
            // §6.4: the session's own refusal, which arrives as a control error. A transport failure
            // is not the session refusing and hides nothing.
            if case WireError.controlError = error { backgroundingDisabled = true }
        }
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

    /// Raises *Stop everything*'s confirm **after taking the census**, because the count is what the
    /// dialog is for: the user is being told the size of the work they are about to end.
    ///
    /// The census is X5's own — `LifecycleAPI.liveTaskIDs(of:)`, the fleet's fact — and not the
    /// fold's, for the reason the header's handoff takes it there: the action ends work in a channel
    /// whether or not this window has ever drawn its timeline, and a fold-derived count answers
    /// "nothing is running" for every one of those. A count reaches the dialog and the ids do not
    /// (§6.3, §11).
    func requestStopEverything() async {
        let live = await lifecycle.liveTaskIDs(of: channel)
        pending = .stopEverything(liveTaskCount: live.count)
    }

    /// *Background all*'s confirm. No census: the action stops nothing, so there is no cost to size.
    func requestBackgroundAll() { pending = .backgroundAll }

    /// Takes the waiting confirm whole and leaves nothing behind, so a dismissal arriving after this
    /// has nothing left to clear.
    func claimPending() -> AgentTreeConfirm? {
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
    func cancelPending() { pending = nil }

    /// A claimed confirm, run. The only place either action is issued, and neither is reimplemented:
    /// `Fleet` owns what *Stop everything* and *Background all* mean (contract Y5).
    private func perform(_ confirm: AgentTreeConfirm) async {
        do {
            _ = try await lifecycle.perform(confirm.action, on: channel)
            banner = nil
        } catch {
            banner = TaskCardModel.banner(for: error)
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

    var body: some View {
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
            // *Send message* is Task 7's: the relay carries a delivery state concluded from the
            // agent's own frames, and an affordance that sent a prompt with no state behind it would
            // report success the moment the call returned — which is the conclusion item 51 exists to
            // refuse. The affordance is drawn and inert until that machine lands.
            Button("Send Message…") {}
                .disabled(true)
        }
        .font(.caption)
    }
}
