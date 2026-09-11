import Foundation
import Observation
import AfleetCore
import FleetKit
import PanelHostAPI

/// What has to be settled before a channel may spawn, and the two things a user can do about it
/// (root spec §6.11 and §6.12, acceptance G4).
///
/// One object over `LifecycleAPI.preconditions(for:)`. It answers the two verdicts this child
/// renders — `consentNeeded`, which raises the sheet, and `untrusted`, which makes the channel
/// history-only — and it renders every refusal as a `RowBanner`. Every other verdict is somebody
/// else's surface and this model draws nothing for it.
///
/// **It writes nothing.** *Accept* is `acceptProjectServers`, which only remembers the acceptance in
/// afleet's own store; *Decline* is `declineProjectServers`, the one Claude Code-owned file afleet
/// writes — and C4 is what writes it. No path under a config home is opened here, and trust is
/// never written at all (§6.11).
///
/// The three actions that reach the fleet — accept, decline and the terminal handoff — are
/// synchronous and claim `isAnswering` before they return, for the reason
/// `DecisionAnswering.send(_:on:in:)` claims its request id before it returns: the second of two
/// clicks in one run-loop turn must find the first already on the wire.
@MainActor
@Observable
final class PrecommitModel {

    /// §6.11's sentence, in the spec's own words. It names the project in words and carries no
    /// path: `untrusted` carries a root, §11 forbids surfacing one, and that root reaches only
    /// `openInTerminal`, which resolves the directory itself.
    static let untrustedSentence = "This project has not been trusted in Claude Code."

    /// One evaluation of one channel: the channel a verdict was read for, the project directory a
    /// decline is recorded against, and the number that says which evaluation it was.
    ///
    /// A value rather than two independent properties because the two are only ever meaningful
    /// together. A selection that moves starts a new evaluation while the previous one is still
    /// suspended in `preconditions(for:)`, and a model that assigned the channel and the project on
    /// the way *in* would already be holding B's project when A's verdict arrived — so an accept
    /// taken from the sheet A raised would record A's servers against B's project. Both are
    /// therefore published with the verdict they belong to, and `id` is what tells a late result it
    /// is late.
    struct Evaluation: Sendable {
        let id: Int
        let channel: ChannelKey
        let project: URL
    }

    /// What the sheet was shown with: an evaluation, the project the *fleet* read the servers for,
    /// and the servers §6.12 is asking about, as one value. The sheet's three answers carry it back,
    /// so none can be paired with a project the user never saw. `id` is the evaluation's, which is
    /// what makes a superseded sheet a different item to SwiftUI and gets it taken down.
    ///
    /// **`project` is the verdict's, not the evaluation's** (scalpel-3#1). The mount supplies the
    /// row's directory and the fleet reads the launch's own `cwd`; a relocation parts the two, and
    /// a decline is a write into the project's `.claude/settings.local.json`. The project a verdict
    /// was computed for is the only one an answer to it may name, so it comes from
    /// `SpawnPrecondition.consentNeeded` and never from `evaluation.project`, which stays what it
    /// is — the context fence that says which sheet is current.
    struct ConsentRequest: Identifiable, Sendable {
        let evaluation: Evaluation
        let project: URL
        let servers: [ProjectMCPServer]
        var id: Int { evaluation.id }
    }

    private let lifecycle: any LifecycleAPI
    private let panels: any PanelHost
    /// Where the pane afleet asked for is announced to have ended (§14 item 47, tracker 314).
    ///
    /// Nil is legal and means *re-read as soon as the request has been handed over*, which is what
    /// this model did before the trust review was a pane of its own. Every test that is about the
    /// handoff rather than about the timing leaves it nil.
    private let paneExits: PaneExitAnnouncer?

    /// The evaluation the verdict on screen belongs to. Nil until `evaluate(channel:project:)` has
    /// published one.
    private(set) var evaluation: Evaluation?

    /// The number of the evaluation that has been *started* last, which is not always the one on
    /// screen: a result whose number is not this one is a result the user has already navigated
    /// away from, and is dropped rather than published.
    private var started = 0

    /// The last verdict. `.ready` until one has been read, which is what a channel with no
    /// precondition looks like and is what draws nothing.
    private(set) var precondition: SpawnPrecondition = .ready

    /// Whether the last verdict **for each channel** was `untrusted`.
    ///
    /// **The untrusted-to-ready flip belongs to the channel, not to one observation point.** Trust
    /// is granted outside afleet and three things can be the first to notice: the re-read a pane's
    /// exit drives, the re-read an answer drives, and `evaluate` — which runs on every selection
    /// *and* on every return to the front, so switching apps while the trust dialog is open is
    /// itself an observation. Hanging item 47's spawn off only one of them drops it whenever another
    /// gets there first, which is what a trip out of the app does.
    ///
    /// It is still not a general auto-spawn on selection: the flip needs a *previous* verdict for
    /// **this same channel** that was untrusted, and a channel the user has just clicked onto has
    /// none.
    ///
    /// **One entry per channel, not one slot for the model.** A single slot was erased by a click to
    /// another channel and back — the intervening evaluation overwrote it — so the flip was lost for
    /// exactly the user who went to look at something else while the trust dialog was open. Bounded
    /// by the channels this column has evaluated, and cleared with the context by `invalidate()`.
    private var untrustedChannels: Set<ChannelKey> = []

    /// Why the last action did not happen, and the evaluation it did not happen under.
    ///
    /// **A banner belongs to one evaluation.** The actions that reach the fleet all fail
    /// asynchronously, and a
    /// refusal that arrived after the selection moved would draw one channel's failure above another
    /// channel's conversation — the same pairing `Evaluation` exists to prevent one step further on.
    /// Storing the number the refusal was raised under is what makes the fence a property of the
    /// value rather than of whoever remembered to clear it.
    private var raised: (evaluation: Int, banner: RowBanner)?

    /// Why the last action did not happen, or nil — and nil for every banner an earlier evaluation
    /// raised, so a new evaluation clears the old one's refusal by arriving.
    var banner: RowBanner? {
        guard let raised, raised.evaluation == started else { return nil }
        return raised.banner
    }

    /// The channel whose consent sheet the user waved away with *Not now* (tracker 170).
    ///
    /// Per channel and not per evaluation: the verdict is re-read whenever the selection moves or
    /// the app comes back to the front, and a dismissal that a re-read undid would put the sheet
    /// back up in front of a user who had just declined to answer it. Nothing is written and the
    /// verdict is untouched — the channel stays in `consentNeeded`, unspawned — so the only thing
    /// this suppresses is the modal.
    private var deferredChannel: ChannelKey?

    /// True while an accept, a decline or a terminal handoff is on the wire. Every affordance
    /// disables on it, so nothing is sent twice.
    private(set) var isAnswering = false

    /// The channels whose trust-review pane is open.
    ///
    /// **Separate from `isAnswering`, which is released at the handover.** That slot protects a
    /// second *request* reaching the host and its job is done once the request is handed over; this
    /// one protects the single pending review the supervisor holds. A second press while the pane is
    /// open would mint a second request and overwrite that slot, so the first pane's exit would
    /// match nothing and the channel would wait for a pane nobody is going to close. One press, one
    /// pane, until the pane ends.
    ///
    /// **Keyed on the channel and not on the evaluation's number.** The evaluation is re-made on
    /// every selection and on every return to the front, so a number would stop matching the moment
    /// the user switched applications — which is precisely when the trust dialog is on screen and a
    /// second press is most likely. A set rather than one slot for the same reason the flip's memory
    /// is a dictionary: a click to another channel and back must not forget what is open here.
    private var reviewsInFlight: Set<ChannelKey> = []

    /// Whether §6.11's action is offered. The banner reads it, so one press means one pane.
    var canReviewTrust: Bool {
        guard !isAnswering else { return false }
        guard let evaluation else { return true }
        return !reviewsInFlight.contains(evaluation.channel)
    }

    init(lifecycle: any LifecycleAPI, panels: any PanelHost, paneExits: PaneExitAnnouncer? = nil) {
        self.lifecycle = lifecycle
        self.panels = panels
        self.paneExits = paneExits
    }

    // MARK: - The verdict

    /// The sheet, or nil when no sheet is up: the pending servers and the evaluation they were read
    /// for, which the sheet's three answers hand back.
    var consentRequest: ConsentRequest? {
        guard let evaluation, deferredChannel != evaluation.channel,
              case .consentNeeded(let project, let servers) = precondition else { return nil }
        return ConsentRequest(evaluation: evaluation, project: project, servers: servers)
    }

    /// §6.11: an untrusted project opens history-only. Nothing here spawns and nothing offers to.
    var isHistoryOnly: Bool {
        if case .untrusted = precondition { return true }
        return false
    }

    /// The channel still needs consent and the sheet is not up, because the user answered *Not now*.
    /// The banner this draws is the way back to the sheet: §6.12's decision is still unanswered and
    /// the channel still cannot spawn, so the affordance may not disappear with the modal.
    var isConsentDeferred: Bool {
        guard let evaluation, deferredChannel == evaluation.channel,
              case .consentNeeded = precondition else { return false }
        return true
    }

    /// Reads the precondition for a channel. The only call that asks the fleet anything before a
    /// user has clicked.
    ///
    /// **The verdict and the channel it was read for are published together, or not at all.** Two
    /// evaluations can be in flight at once — the column re-runs this whenever the selection moves,
    /// and nothing orders their completions — so a result that arrives after a later evaluation
    /// started is dropped here. Publishing it would put one channel's servers on screen beside
    /// another channel's project, which is the pair the two answers below act on.
    func evaluate(channel: ChannelKey, project: URL) async {
        started += 1
        let id = started
        let verdict = await lifecycle.preconditions(for: channel)
        // **Two fences, because they catch different things.** The generation catches a read the
        // model itself superseded; cancellation catches the one it did not — a mount whose channel
        // went away starts no new evaluation, so `started` never moves and the generation alone
        // would let A's consent publish over a column that has no channel at all.
        guard id == started, !Task.isCancelled else { return }
        evaluation = Evaluation(id: id, channel: channel, project: project)
        raised = nil
        await applyVerdict(verdict, for: Evaluation(id: id, channel: channel, project: project))
    }

    /// Publishes a verdict and, when it is this channel's own untrusted-to-ready flip, spawns.
    ///
    /// One place, so the three observations that can notice trust being granted cannot disagree
    /// about what follows — see `untrustedChannels`.
    private func applyVerdict(_ verdict: SpawnPrecondition, for evaluation: Evaluation) async {
        let wasUntrusted = untrustedChannels.contains(evaluation.channel)
        precondition = verdict
        if case .untrusted = verdict {
            untrustedChannels.insert(evaluation.channel)
        } else {
            untrustedChannels.remove(evaluation.channel)
        }
        guard wasUntrusted, verdict == .ready else { return }
        await spawnAfterTrust(evaluation)
    }

    /// Drops the verdict on screen, because the context it was read for is gone.
    ///
    /// The mount calls this when it has no channel or no project to evaluate: leaving the last
    /// verdict up would draw one channel's trust banner above a column showing nothing, and — since
    /// the generation is what tells a late result it is late — would let a read still in flight
    /// publish into that same emptiness. Bumping the generation is what makes both impossible.
    func invalidate() {
        started += 1
        evaluation = nil
        precondition = .ready
        raised = nil
        deferredChannel = nil
        // The flip's memory and the open reviews go with the context they were about: a verdict
        // remembered across an empty column would fire on whatever channel is selected next, and a
        // review whose column is gone has no banner left to disable.
        untrustedChannels.removeAll()
        reviewsInFlight.removeAll()
    }

    // MARK: - §6.12, the consent sheet's three answers

    /// *Accept*: the store remembers the acceptance per project and server hash, and nothing is
    /// written to disk. The verdict is re-read afterwards, so the sheet closes because the fleet
    /// stopped asking rather than because the view decided it had.
    func accept(_ request: ConsentRequest) {
        guard isCurrent(request.evaluation), claim() else { return }
        Task {
            defer { isAnswering = false }
            await lifecycle.acceptProjectServers(request.servers, project: request.project)
            clear(request.evaluation)
            await reread(request.evaluation)
        }
    }

    /// *Decline*: exactly the names the user declined, recorded through C4 in the project's
    /// `.claude/settings.local.json`. A refusal is fail-closed and says so.
    func decline(_ request: ConsentRequest) {
        guard isCurrent(request.evaluation), claim() else { return }
        Task {
            defer { isAnswering = false }
            do {
                try await lifecycle.declineProjectServers(request.servers.map(\.name),
                                                          project: request.project)
                clear(request.evaluation)
                await reread(request.evaluation)
            } catch let error as LifecycleError {
                raise(Self.banner(for: error), for: request.evaluation)
            } catch {
                raise(RowBanner(text: "The project-server decline did not complete: \(type(of: error))."),
                      for: request.evaluation)
            }
        }
    }

    /// *Not now*: the sheet goes away and **nothing is recorded anywhere** (tracker 170, ruled).
    ///
    /// §6.12 has exactly one write in it and it is the decline. Dismissal is not a decline: the
    /// channel keeps its `consentNeeded` verdict, no acceptance is remembered, nothing is written
    /// under the project's `.claude/`, and no child is spawned. What the user gets back is the
    /// column, with the banner that re-opens this sheet — because a decision that is still
    /// outstanding may not lose its affordance along with its modal.
    func notNow(_ request: ConsentRequest) {
        guard isCurrent(request.evaluation) else { return }
        deferredChannel = request.evaluation.channel
    }

    /// The banner's way back into the sheet a *Not now* dismissed.
    func resumeConsent() {
        deferredChannel = nil
    }

    // MARK: - §6.11, the trust action

    /// *Review trust in terminal*: C4's `PaneRequest`, handed to the host **unchanged, `id`
    /// included**. C4 accepts a `PaneExit` only for the id it is waiting on, so a request rebuilt
    /// here would have its exit discarded and the re-read of trust would never happen.
    func reviewTrustInTerminal() {
        // The same fence the sheet's two answers take. The banner this was pressed on was drawn for
        // the evaluation on screen, and an evaluation already in flight means that is no longer the
        // one the model holds: the press would then hand the host a channel the user is not looking
        // at, and the pane would open on somebody else's project.
        guard let evaluation, isCurrent(evaluation), canReviewTrust, claim() else { return }
        Task {
            var declared: UUID?
            do {
                // X5's own verb, not the hatch: the channel has no process to hand over, which is
                // why this banner is drawn at all (tracker 314).
                let request = try await lifecycle.reviewTrustInTerminal(evaluation.channel)
                // Declared before the pane runs, because a spawn that never executes is reported at
                // once — the panel synthesises exit code 127 — and a wait armed afterwards would
                // have missed it.
                declared = request.id
                await paneExits?.expect(request.id)
                reviewsInFlight.insert(evaluation.channel)
                try await panels.run(request, for: evaluation.channel)
                clear(evaluation)
                // **The in-flight slot is released here and not at the exit.** What it protects is
                // a second request reaching the host, and by this line the request has been handed
                // over. What keeps one press to one pane afterwards is `reviewsInFlight`, which the
                // exit clears.
                isAnswering = false
                // Trust is granted in Claude Code's own dialog, **inside that pane**, and no state
                // afleet holds changes when it is — so the verdict can only be re-read from the
                // global config document afterwards. `run` returns when the pane *starts*, so this
                // waits for the exit the panel reports through `paneExited`: not a timer, and not a
                // second source of truth, but a listener on the one path the exit already takes.
                await paneExits?.whenExited(request.id)
                reviewsInFlight.remove(evaluation.channel)
                await rereadAfterReview(evaluation)
            } catch let error as PanelHostError {
                // Raised *before* the slot is released: a surface — or a test — that waits for the
                // model to go idle must find the banner already there.
                raise(Self.banner(for: error), for: evaluation)
                await release(declared, of: evaluation)
                isAnswering = false
            } catch let error as LifecycleError {
                raise(RowBanner(error), for: evaluation)
                await release(declared, of: evaluation)
                isAnswering = false
            } catch {
                raise(RowBanner(text: "The terminal handoff did not complete: \(type(of: error))."),
                      for: evaluation)
                await release(declared, of: evaluation)
                isAnswering = false
            }
        }
    }

    /// Gives back everything a failed review took: the declared pane id, and the one-press slot.
    private func release(_ declared: UUID?, of evaluation: Evaluation) async {
        reviewsInFlight.remove(evaluation.channel)
        guard let declared else { return }
        await paneExits?.withdraw(declared)
    }

    // MARK: - Refusals

    /// §6.12's fail-closed banner. `declineRefused` is the unparseable-JSON, symlink, foreign-uid
    /// and write-error path: nothing was written and nothing spawned, and the way forward is the
    /// terminal's own `/mcp` flow rather than another click here. The reason is the store's own
    /// kind word — never a path (§11).
    private static func banner(for error: LifecycleError) -> RowBanner {
        guard case .declineRefused(let reason) = error else { return RowBanner(error) }
        return RowBanner(text: "Nothing was written and nothing spawned: the decline was refused (\(reason)). "
                       + "Review this project's MCP servers in your terminal with /mcp.")
    }

    /// Item 47's refusals, each naming what did not happen rather than what went wrong.
    ///
    /// `noPaneRunner` was written when C7.4 had not landed and the Terminal tab did not exist; the
    /// app now registers one at launch, so it is a defence rather than a path, and the sentence
    /// still tells a user of a build without the panel what to do instead. `noChannelContext` is
    /// C7.4's addition: the host resolves the channel **the caller named** — this model names its
    /// evaluation's — and a channel the host has never rendered has no context to run a pane in.
    private static func banner(for error: PanelHostError) -> RowBanner {
        switch error {
        case .noPaneRunner:
            RowBanner(text: "afleet has no Terminal pane yet, so it could not open one. "
                    + "Run `claude` in your own terminal, in this project, to review its trust.")
        case .noChannelContext:
            RowBanner(text: "This channel is not open in a window, so there was nowhere to put the "
                    + "pane. Select the channel and try again.")
        case .duplicateTab:
            RowBanner(text: "The Terminal pane is registered twice; the handoff was refused.")
        }
    }

    /// Publishes a refusal under the evaluation it belongs to, or drops it because the surface has
    /// moved on and there is nothing left for it to be about.
    private func raise(_ banner: RowBanner, for evaluation: Evaluation) {
        guard isCurrent(evaluation) else { return }
        raised = (evaluation.id, banner)
    }

    /// Clears a refusal this evaluation had raised. Under the same fence, so an action that
    /// succeeded after the selection moved does not clear the new context's banner.
    private func clear(_ evaluation: Evaluation) {
        guard isCurrent(evaluation) else { return }
        raised = nil
    }

    /// Takes the in-flight slot, or refuses because one is already taken.
    private func claim() -> Bool {
        guard !isAnswering else { return false }
        isAnswering = true
        return true
    }

    /// Whether an answer's evaluation is still the one on screen. An answer taken from a sheet the
    /// user has navigated past acts on a project that is no longer shown, so it does nothing.
    private func isCurrent(_ evaluation: Evaluation) -> Bool { evaluation.id == started }

    /// Re-reads the verdict for the evaluation an answer belongs to, under the same fence
    /// `evaluate` publishes under: an answer's re-read landing after the selection moved would
    /// replace the new channel's verdict with the old channel's.
    /// The re-read a **pane exit** earns, fenced on the evaluation's **channel** rather than on its
    /// generation number.
    ///
    /// The generation is the right fence for an answer taken from a sheet: a later evaluation means
    /// the user has navigated past the thing they answered. It is the wrong fence here, because the
    /// decoration's `.task(id:)` keys on `isApplicationActive` — so switching to another application
    /// while the trust dialog is open bumps the generation for the *same* channel, and item 47's
    /// spawn would be dropped exactly when the user does the thing the dialog asks for. What matters
    /// is that the channel this review was started for is still the one on screen.
    private func rereadAfterReview(_ evaluation: Evaluation) async {
        let verdict = await lifecycle.preconditions(for: evaluation.channel)
        guard self.evaluation?.channel == evaluation.channel else { return }
        await applyVerdict(verdict, for: evaluation)
    }

    private func reread(_ evaluation: Evaluation) async {
        let verdict = await lifecycle.preconditions(for: evaluation.channel)
        guard isCurrent(evaluation) else { return }
        await applyVerdict(verdict, for: evaluation)
    }

    /// The owned spawn a trust flip earns (§14 item 47's second half).
    ///
    /// Nothing else would spawn it: trust is granted outside afleet, no state afleet holds changes
    /// when it is, and the channel is history-only precisely because the user has not been able to
    /// send. `applyVerdict` is the one caller and it is what scopes this to the flip — a channel
    /// whose previous verdict for itself was untrusted, now ready — so a `.ready` read on a channel
    /// the user has merely clicked onto spawns nothing.
    private func spawnAfterTrust(_ evaluation: Evaluation) async {
        do {
            _ = try await lifecycle.perform(.open, on: evaluation.channel)
        } catch let error as LifecycleError {
            raiseForChannel(RowBanner(error), of: evaluation)
        } catch {
            raiseForChannel(RowBanner(text: "The channel did not open after trust was granted: "
                                    + "\(type(of: error))."), of: evaluation)
        }
    }

    /// A refusal the **channel** still owns, for the spawn a trust flip earns: the generation may
    /// have moved for a reason that is not the user navigating away — see `rereadAfterReview`.
    private func raiseForChannel(_ banner: RowBanner, of evaluation: Evaluation) {
        guard self.evaluation?.channel == evaluation.channel else { return }
        raised = (started, banner)
    }
}
