import Foundation
import Observation
import AfleetCore
import ClaudeWire
import PanelHostAPI
import FleetKit

/// The channel header's actions (spec §8.5's neighbour, C6.2 *The header's menus and actions*).
///
/// Beside C6.1's readbacks and Task 7's pickers, one menu per group: MCP, reload skills and plugins,
/// rename, fork, send to background, open in terminal, stop everything, background all, and the
/// per-channel *Prompt suggestions* toggle. Every one of them is one `LifecycleAPI` call and nothing
/// else (contract X5, Y5); this model holds no process, opens no transcript and writes no frame.
///
/// **Tracker 74: every owned action is gated on `ChannelRow.offersOwnedActions`,** and a row that is
/// read-only shows `readOnlyReason` **in place of** the actions rather than a disabled list. This is
/// the first surface in the codebase to consume either property. The gate is a property of this
/// model rather than of the view, because a menu is a view and a view is not where a "never spawn
/// against a teammate's session" guarantee should live.
///
/// It shares the composer's `ChannelSurfaceState` and its `SettingPickersModel` rather than owning
/// its own: §7.4's readback wait closes the *field* while a restart-required setting is being
/// applied, and a header with a second surface would be disabling a field that is not the one on
/// screen. The three destructive actions go through the composer's own `ComposerConfirmation` gate
/// for the same reason — one gate, not two.
@MainActor
@Observable
final class ChannelHeaderActionsModel {

    /// The channel's composer. The header reaches four things through it and derives none of them:
    /// the shared surface state, the pickers, the confirmation gate, and the channel's timeline —
    /// which is where the live background tasks *Send to background* names are read from.
    ///
    /// Strong, and there is no cycle to pay for it: the composer refers back only through the
    /// picker's bypass route, which captures this model weakly.
    @ObservationIgnored let composer: ComposerModel

    /// afleet's own store, for the one value this leaf writes: the bypass acceptance, in the
    /// `fleetKit` namespace (§7.8). Nil until a launch reaches a workspace.
    @ObservationIgnored let store: (any StateStore)?

    /// Where a `PaneRequest` is run — X7's host. Nil in a scene that has no panel host, where
    /// *Open in terminal* says so rather than handing the request nowhere.
    @ObservationIgnored var paneRunner: (@MainActor (PaneRequest) async throws -> Void)?

    /// The row this header is drawing, as the fleet browser built it. **The gate on every action**
    /// (`ChannelRow.offersOwnedActions`), and the source of `readOnlyReason`. Nil before the column
    /// has handed one down, which offers nothing — a menu that acted before it knew whose session it
    /// was would be the defect tracker 74 exists to close.
    var row: ChannelRow?

    /// What the last action had to say: a count the engine answered with, a confirmation, a refusal.
    /// Nil whenever the header has nothing to say. Counts and identifiers only, never a path, a
    /// title, a session id or an environment (§11) — the one exception being a rename, whose title
    /// is what the user just typed and is not read back from anywhere.
    private(set) var note: String?

    /// The MCP popover's servers, from `mcp_status` through `run(.mcpPopover, …)`. Empty until the
    /// popover has been opened; `isShowingMCP` is what says whether it is on screen.
    private(set) var mcpServers: [MCPPopover.Server] = []
    var isShowingMCP = false

    /// The bypass disclaimer, on screen from the first selection until it is answered. See
    /// `BypassGate.swift`; the order of what happens on acceptance is the whole content of §8.6.
    var isShowingBypassDisclaimer = false

    /// The rename sheet. The header holds the flag; the sheet holds the text, which is the user's
    /// and is never read back from anywhere.
    var isRenaming = false

    /// Whether afleet's store already holds the bypass acceptance. Read from the store, never
    /// assumed: it is what separates §8.6's first selection from every later one.
    private(set) var bypassAccepted = false

    /// Whether *Prompt suggestions* is on for this channel. The header's copy of the composer's own
    /// flag, moved only when the restart that applies it has been confirmed.
    var promptSuggestionsEnabled: Bool { composer.promptSuggestionsEnabled }

    /// How many restarts this header has issued. A count, and the floor an ordering assertion needs
    /// to tell "restarted once" from "restarted twice" (§11).
    private(set) var restartsIssued = 0

    init(composer: ComposerModel, store: (any StateStore)? = nil) {
        self.composer = composer
        self.store = store
        // §8.6's gate is this model's, and the mode picker is where the click arrives.
        composer.pickers.bypassRoute = { [weak self] in await self?.selectBypassMode() }
    }

    // MARK: - What the header is allowed to do

    var key: ChannelKey { composer.key }
    var surface: ChannelSurfaceState { composer.surface }
    var pickers: SettingPickersModel { composer.pickers }
    var lifecycle: any LifecycleAPI { composer.lifecycle }

    /// Whether this header offers owned actions at all. `ListingPolicy` decided it and the row
    /// carries it; nothing here re-reads the rule that produced it.
    var offersOwnedActions: Bool { row?.offersOwnedActions ?? false }

    /// Why this row offers none, when it offers none. The view shows this sentence **in place of**
    /// the actions; a disabled menu would still be a menu of things afleet must never do to someone
    /// else's session.
    var readOnlyExplanation: String? {
        guard let reason = row?.readOnlyReason else { return nil }
        switch reason {
        case .teammate:
            return "This conversation belongs to a teammate. afleet reads it and never acts on it."
        }
    }

    /// The row the header is drawing, adopted. Called on every body evaluation, so a row that turns
    /// read-only while the channel is on screen closes the menu with it.
    func adopt(row: ChannelRow?) { self.row = row }

    // MARK: - The menu

    /// The MCP popover: `run(.mcpPopover, …)`, rendering the servers the strategy answered with.
    ///
    /// The strategy is C4's and issues `mcp_status` itself; the header names the row and renders the
    /// answer, and re-implements neither (contract X10).
    func showMCPServers() async {
        guard gate() else { return }
        do {
            let outcome = try await lifecycle.run(.mcpPopover, arguments: [], on: key, ui: composer)
            guard case .mcp(let popover) = outcome else {
                note = "The channel answered something other than an MCP status."
                return
            }
            mcpServers = popover.servers
            isShowingMCP = true
            note = "\(popover.servers.count) MCP server(s)."
        } catch {
            note = Self.refusal(error)
        }
    }

    /// *Reload skills*: `reload_skills` → `{skills: […]}`. The engine sends no count and no error
    /// field, so the count is the array's length and there is nothing else to report.
    func reloadSkills() async {
        guard gate() else { return }
        guard let body = await answer(AnyControlRequest(ReloadSkills())) else { return }
        let skills = body["skills"]?.arrayValue?.count ?? 0
        note = "\(skills) skill(s) loaded."
    }

    /// *Reload plugins*: `reload_plugins` → `{commands, agents, plugins, mcpServers, error_count}`.
    /// Every count the engine sent, and its own error count beside them.
    func reloadPlugins() async {
        guard gate() else { return }
        guard let body = await answer(AnyControlRequest(ReloadPlugins())) else { return }
        func count(_ key: String) -> Int {
            if let number = body[key]?.intValue { return Int(number) }
            return body[key]?.arrayValue?.count ?? 0
        }
        let errors = body["error_count"]?.intValue.map(Int.init) ?? 0
        note = "\(count("commands")) command(s), \(count("agents")) agent(s), \(count("plugins")) plugin(s), "
            + "\(count("mcpServers")) MCP server(s), \(errors) error(s)."
    }

    /// *Rename*: `rename_session {title}`.
    ///
    /// **The success body is empty** — the engine's declared response schema for this subtype is
    /// `null` (2.1.263 `cli.pretty.js:452980-452992`) — so the confirmation is the *absence of an
    /// error* and the title the user typed, and never a readback. A header that waited for one would
    /// wait for ever and report a rename that in fact succeeded as a failure.
    func rename(to title: String) async {
        guard gate() else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            note = "A title of \(trimmed.count) character(s) is not a rename."
            return
        }
        guard await answer(AnyControlRequest(RenameSession(title: trimmed))) != nil else { return }
        note = "Renamed to “\(trimmed)”."
    }

    /// *Fork*: a whole-conversation fork, which is `perform(.fork(at: nil))`. *Fork from here* is the
    /// composer's, on a message (`EditAndRewind`), and carries a `ForkPoint`; this one carries none.
    func fork() async {
        guard gate() else { return }
        await perform(.fork(at: nil))
    }

    /// *Send to background*, **behind a confirm naming any live task**. Nothing reaches the
    /// lifecycle until the confirm is answered: a stream close kills every still-running local shell
    /// (§7.4), so this is the one channel action whose cost the user has to see first.
    ///
    /// The confirm is the composer's `ComposerConfirmation`, which the two stop actions also use.
    func sendToBackground() {
        guard gate() else { return }
        composer.confirmationDetail = backgroundConfirmationDetail
        composer.pendingConfirmation = .sendToBackground
    }

    /// The live background tasks this channel has, by the engine's own task id, read out of the
    /// channel's timeline — C3's one fold (contract X4), the same place the queue chip reads.
    ///
    /// A task id is an engine-assigned identifier and not a path, a title or a session id, so it may
    /// be named (§11). Empty is a real answer and is what the confirm says when the channel has
    /// nothing running.
    var liveTaskIDs: [String] {
        guard let timeline = composer.timelines?.timeline else { return [] }
        return Self.liveTaskIDs(in: timeline.items)
    }

    /// The running tasks among a channel's items, in the fold's own order.
    ///
    /// A **running** task and no other status: a completed, failed or stopped run has no shell left
    /// for the handoff to close, and naming one would tell the user this costs something it does not.
    static func liveTaskIDs(in items: [TimelineItem]) -> [String] {
        items.compactMap { item in
            guard case .taskRun(let task) = item, task.status == .running else { return nil }
            return task.taskID
        }
    }

    /// What the *Send to background* confirm says, with the live tasks named.
    var backgroundConfirmationDetail: String { Self.confirmationDetail(forLiveTasks: liveTaskIDs) }

    /// The sentence, over the ids. Counts and engine-assigned task ids only (§11).
    static func confirmationDetail(forLiveTasks ids: [String]) -> String {
        guard !ids.isEmpty else {
            return "This channel hands off to a background job. Nothing is running in it right now."
        }
        return "\(ids.count) background task(s) are running and their shells close with the handoff: "
            + ids.joined(separator: ", ")
    }

    /// *Open in terminal*: X5's handoff request, run by X7's host.
    ///
    /// **Behind the same confirm *Send to background* shows, when the channel has running background tasks.**
    /// `handOff` terminates the owned process before it answers the pane request, and stream close kills every
    /// still-running local shell (§7.4, X9): a release that ended a user's running work without saying so is exactly
    /// what that rule forbids. A channel with nothing running is released with no dialog — there is no cost to state.
    func openInTerminal() async {
        guard gate() else { return }
        // X5's own answer and not the fold's, which is what *Send to background* reads: the handoff ends the
        // channel's process wherever the menu was opened from, including a channel this window has never drawn a
        // timeline for, and the fleet answers for that one too (§7.4's "busy", second half).
        let live = await lifecycle.liveTaskIDs(of: key)
        guard live.isEmpty else {
            composer.confirmationDetail = Self.confirmationDetail(forLiveTasks: live)
            composer.confirmedWork = { [weak self] in await self?.handOff() ?? false }
            composer.pendingConfirmation = .openInTerminal
            return
        }
        await handOff()
    }

    /// The handoff itself, which nothing but `openInTerminal()` and the confirm it raises reaches.
    /// Answers whether the channel was handed off, which is what the confirm reports.
    ///
    /// **The first production caller of `PanelHostModel.run(_:)`** (tracker 72 recorded it as
    /// uncalled). That method throws `PanelHostError.noPaneRunner` until C7's Terminal leaf lands, so
    /// the refusal is surfaced as an inline note naming the tab — item 47's degradation stated by the
    /// composite, and not a silent skip.
    @discardableResult
    private func handOff() async -> Bool {
        do {
            let request = try await lifecycle.openInTerminal(key)
            guard let paneRunner else {
                note = "There is no panel host in this window to run \(PanelTabID.terminal.defaultTitle) in."
                return false
            }
            try await paneRunner(request)
            note = "Handed off to \(PanelTabID.terminal.defaultTitle)."
            return true
        } catch let error as PanelHostError {
            note = Self.explanation(of: error)
            return false
        } catch {
            note = Self.refusal(error)
            return false
        }
    }

    /// *Stop everything* and *Background all*, both behind the composer's confirm. The action is
    /// issued in `ComposerModel.confirmPending()` and nowhere else.
    func stopEverything() async { await confirmable(.stopEverything) }
    func backgroundAll() async { await confirmable(.backgroundAll) }

    private func confirmable(_ action: LifecycleAction) async {
        guard gate() else { return }
        await composer.dispatch(action: action)
    }

    /// What `noPaneRunner` says, naming the tab the request was for.
    ///
    /// The tab's own `defaultTitle` rather than a word written here: the name of a panel is
    /// `PanelTabID`'s and a second spelling of it would drift.
    static func explanation(of error: PanelHostError) -> String {
        switch error {
        case .noPaneRunner(let tab):
            "The \(tab.defaultTitle) panel is not available yet, so this channel was not handed off."
        case .duplicateTab(let tab):
            "The \(tab.defaultTitle) panel is already registered."
        }
    }

    // MARK: - Plumbing

    /// Tracker 74's gate, in one place. Every action calls it first and does nothing when it answers
    /// false, so a read-only row reaches no lifecycle member at all.
    @discardableResult
    func gate() -> Bool {
        guard offersOwnedActions else {
            note = readOnlyExplanation ?? "afleet does not act on this channel."
            return false
        }
        note = nil
        return true
    }

    /// One control request through X5, answering its body. A refusal is a note and is **never
    /// retried**, on the same terms as every other X5 call in this leaf.
    func answer(_ request: AnyControlRequest) async -> JSONValue? {
        do {
            return try await lifecycle.send(request, on: key)
        } catch {
            note = Self.refusal(error)
            return nil
        }
    }

    /// One lifecycle action through X5, with the same two refusal arms.
    @discardableResult
    func perform(_ action: LifecycleAction) async -> Bool {
        do {
            _ = try await lifecycle.perform(action, on: key)
            return true
        } catch {
            note = Self.refusal(error)
            return false
        }
    }

    /// Why an action did not happen. A `LifecycleError` is afleet's own refusal and reuses the
    /// composer's copy for it; anything else is the channel not answering.
    static func refusal(_ error: any Error) -> String {
        if let lifecycle = error as? LifecycleError { return ComposerModel.explanation(of: lifecycle) }
        return "The channel did not answer; nothing was changed."
    }

    /// Counted by the restart path (`RestartRequiredSettings`), so an ordering assertion can read a
    /// number rather than infer one.
    func countRestart() { restartsIssued += 1 }

    /// Sets the note from a path outside this file (`BypassGate`, `RestartRequiredSettings`), which
    /// Swift's file-private `private(set)` does not otherwise reach.
    func say(_ sentence: String?) { note = sentence }

    /// Records what the store says about the bypass acceptance. Written by `BypassGate`.
    func noteBypassAccepted(_ accepted: Bool) { bypassAccepted = accepted }
}
