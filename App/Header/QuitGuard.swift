import AppKit
import Foundation
import OSLog
import AfleetCore
import FleetKit

/// §7.4's *Quit* clause (tracker 71), and the one thing in this leaf that acts on the whole fleet
/// rather than on one channel.
///
/// An owned channel is the engine on afleet's stdio, and the engine treats stream close as
/// wind-down: it kills every still-running local shell and abandons its other background work. So
/// an owned conversation cannot outlive afleet, no quit dialog can offer to keep one, and the way
/// to keep a conversation is to release it first with *Open in terminal*. What quitting does
/// instead is end them deliberately, in the order the clause states: ask **once** if any owned
/// channel is busy, naming those channels; then, on confirmation or immediately when nothing is
/// busy, `perform(.quit)` on each owned channel **that has a process**, then `Fleet.shutdown()`, then
/// exit. `shutdown()` itself terminates nothing — streams, timers and diagnostics only — which is
/// why the termination pass comes first and separately.
///
/// **X5's invariant is absolute**: what a termination hook may end is exactly the set `Fleet` owns.
/// Foreign channels — anything running in the user's own terminal — and background jobs are never
/// touched, and the filter that makes that true lives in `FleetQuitTermination.quitChannels()`.
struct QuitChannel: Sendable, Hashable {
    let key: ChannelKey
    /// What the dialog calls this channel. A title is the product's own surface and the dialog is
    /// where the user reads one; no log line and no failure message prints it (§11).
    let title: String
    /// Ready, connecting or contended. A dormant owned channel has none and there is nothing in it
    /// to terminate, so the clause skips it — and it does not block the pass either.
    let hasProcess: Bool
    /// A turn running or running local shells. Not a second notion of busy, and not a surface's
    /// local count either: it is `ChannelState.presence` plus `LifecycleAPI.liveTaskIDs(of:)`, both
    /// read from the fleet, so a channel the user never opened is judged exactly like one on screen.
    let isBusy: Bool
}

/// The fleet as the quit path uses it: the owned set, one termination, and the shutdown. Three
/// members rather than `AppFleet` itself, so the clause can be driven headlessly against a recorded
/// call log — which is the only way "terminate every owned channel, then shut down, in that order"
/// is a fact a test can fail on.
protocol QuitFleet: Sendable {
    /// **Owned channels only.** A foreign or background-job channel never appears here, so nothing
    /// downstream has to remember not to touch one.
    func quitChannels() async -> [QuitChannel]
    func terminateForQuit(_ key: ChannelKey) async
    func shutdownForQuit() async
}

/// The clause itself, over the seam.
@MainActor
final class QuitGuard {

    private let fleet: any QuitFleet
    /// The dialog. Injected because an `NSAlert` cannot be answered in a headless runner, and
    /// because the clause's decision — ask once, and only about the busy owned channels — is worth
    /// asserting without one.
    private let confirm: @MainActor ([QuitChannel]) async -> Bool

    /// How many times this guard has put the dialog on screen. A count, and the floor "asks once"
    /// needs (§11).
    private(set) var askCount = 0
    /// The channels the last ask named, in the order the dialog listed them.
    private(set) var lastAsked: [QuitChannel] = []
    private var isQuitting = false

    init(fleet: any QuitFleet, confirm: @escaping @MainActor ([QuitChannel]) async -> Bool = QuitGuard.alert) {
        self.fleet = fleet
        self.confirm = confirm
    }

    /// Runs the clause. `true` means the app may exit.
    ///
    /// Reentrant only in the sense that a second termination request while the first is still on
    /// screen is refused rather than asked again: the clause says *once*, and two alerts over one
    /// quit would be two.
    func quit() async -> Bool {
        guard !isQuitting else { return false }
        isQuitting = true
        defer { isQuitting = false }

        let owned = await fleet.quitChannels()
        let busy = owned.filter(\.isBusy)
        if !busy.isEmpty {
            askCount += 1
            lastAsked = busy
            guard await confirm(busy) else { return false }
        }
        // **The census is repeated after the pass, and that is the whole answer to the race.** One
        // suspended read of the owned set is not atomic with the terminations that follow it: an
        // open, an adopt or a `paneExited` can hand a channel a process after its entry was taken or
        // after it was seen dormant, and a saved loop skips it. `shutdown()` terminates nothing, so
        // that channel would reach the exit with no deliberate ending at all.
        //
        // No spawn barrier and no new X5 surface: a barrier would be a lifecycle-wide lock taken at
        // the one moment the app is trying to stop, and the residual it would close is small. The
        // bound is three passes, because quitting must not become a loop the user cannot leave; what
        // lands after the last census is ended by the exit closing its pipe, which is the fact the
        // whole clause rests on (tracker 196).
        //
        // A channel is terminated **once**: the repeat exists to reach a channel that was missed, not
        // to send a second `.quit` to one that already had one.
        var terminated: Set<ChannelKey> = []
        var census = owned
        for pass in 0..<Self.terminationPasses {
            let pending = census.filter { $0.hasProcess && !terminated.contains($0.key) }
            if pending.isEmpty { break }
            for channel in pending {
                terminated.insert(channel.key)
                await fleet.terminateForQuit(channel.key)
            }
            if pass < Self.terminationPasses - 1 { census = await fleet.quitChannels() }
        }
        await fleet.shutdownForQuit()
        return true
    }

    /// How many times the clause reads the owned set and terminates what it finds.
    static let terminationPasses = 3

    /// The production dialog. Titles are what the user needs to recognise the conversation they are
    /// about to end, and the dialog is the surface they belong on.
    static func alert(_ channels: [QuitChannel]) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit afleet?"
        alert.informativeText = """
            \(channels.count) channel(s) are still working, and quitting ends them: \
            \(channels.map(\.title).joined(separator: ", ")).
            To keep a conversation running, cancel and release it with Open in terminal first.
            """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The clause over the real fleet.
///
/// It takes `LifecycleAPI` and a shutdown closure rather than `AppFleet`, so the mapping below —
/// which origins are owned, which of them have a process, and which X5 action a `terminate()` is —
/// can be exercised against C6.2's recording double.
struct FleetQuitTermination: QuitFleet {

    let lifecycle: any LifecycleAPI
    /// `Fleet.shutdown()`. A closure because `shutdown()` is `AppFleet`'s and not `LifecycleAPI`'s.
    let shutdown: @Sendable () async -> Void
    /// The channel's title, from the row the fleet browser already built. Nil for a channel with no
    /// row, which the dialog names by the placeholder below rather than by a session id (§11).
    let title: @MainActor @Sendable (ChannelKey) -> String?

    static let unnamed = "an untitled channel"

    func quitChannels() async -> [QuitChannel] {
        var channels: [QuitChannel] = []
        for state in await lifecycle.states() {
            // X5's invariant, spelled once: foreign live, background job and archived all fall out
            // here, and nothing below can reach one.
            guard case .owned(let owned) = state.origin else { continue }
            // §7.4's "busy", second half: the fleet's own running-or-armed task ids, not a count a
            // surface kept locally. A channel with no composer has no local count and would have
            // been judged by presence alone; X5 answers for it too.
            let tasks = await lifecycle.liveTaskIDs(of: state.key)
            let name = await MainActor.run { title(state.key) } ?? Self.unnamed
            channels.append(QuitChannel(key: state.key,
                                        title: name,
                                        // §7.4: ready and connecting each assert a process, and a
                                        // contended channel is one whose process afleet still holds;
                                        // dormant is the resting state of every processless one.
                                        hasProcess: owned != .dormant,
                                        isBusy: state.presence == .busy || !tasks.isEmpty))
        }
        return channels
    }

    /// `terminate()` on one owned channel: X5's `.quit`, once, and nothing else.
    ///
    /// `.quit` is §7.4's own verb, landed on `main` for this clause: per channel, unconditional,
    /// `maySpawn: false`, and gated on no eligibility check — so it ends a channel with a turn in
    /// flight, with a background shell still working, or mid-spawn, which is exactly the set the
    /// dialog just asked about. It therefore throws neither `notEligible` nor `busy`, and there is
    /// nothing here to escalate.
    ///
    /// **Why no escalation, recorded so it is not reintroduced.** An earlier form reaped, and on a
    /// refusal ran `.stopEverything` and reaped again. Its failure path — a reap still refused after
    /// the stop — exited with no SIGTERM, no SIGKILL and **no wedge record**, which regresses §6.7:
    /// every terminating action here is one `terminateOrWedge` and the wedged row has to know what
    /// was attempted. It optimised the happy path and left the failure path recording nothing.
    ///
    /// Any other error is a count in the log and the pass continues: at exit the pipe closes and the
    /// engine winds the channel down anyway, which is the fact the whole clause rests on.
    func terminateForQuit(_ key: ChannelKey) async {
        do {
            _ = try await lifecycle.perform(.quit, on: key)
        } catch {
            Self.log.error("quit: \(1, privacy: .public) channel(s) refused the terminate; the exit closes the pipe regardless")
        }
    }

    /// Counts only, never a key or a title (§11).
    private static let log = Logger(subsystem: "com.afleet.app", category: "quit")

    func shutdownForQuit() async { await shutdown() }
}

/// The `applicationShouldTerminate` hook, and the only reason `AfleetApp` carries a delegate.
///
/// The guard is built at quit time rather than at launch: `bindWorkspace` may not have run when the
/// window first appears, and a guard captured before it would hold no fleet.
@MainActor
final class AfleetQuitDelegate: NSObject, NSApplicationDelegate {

    /// How the app answers the termination request once the guard has decided. Injected so the hook
    /// itself can be run in a test without terminating the test host.
    var reply: @MainActor (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }
    /// Built on demand from the app's own composition. Nil before a launch reached a workspace,
    /// which is a quit with nothing owned and nothing to end.
    var makeGuard: (@MainActor () -> QuitGuard?)?

    /// The guard deciding the quit that is already in flight, held here **because the delegate is the
    /// only thing both requests share**. `makeGuard` answers a fresh `QuitGuard` per call — it has to,
    /// since a guard captured before `bindWorkspace` would hold no fleet — so the guard's own
    /// `isQuitting` flag cannot coalesce anything: two requests would be two instances, two dialogs,
    /// two termination sequences and two replies for one quit.
    private var inFlight: QuitGuard?

    /// A second request while one is deciding is deferred on the first one's answer: the app is
    /// already being asked whether it may exit, and `reply(toApplicationShouldTerminate:)` answers
    /// that question once for the process.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if inFlight != nil { return .terminateLater }
        guard let quitGuard = makeGuard?() else { return .terminateNow }
        inFlight = quitGuard
        Task { @MainActor in
            let answer = await quitGuard.quit()
            inFlight = nil
            reply(answer)
        }
        return .terminateLater
    }
}

extension QuitGuard {

    /// The app's own guard: the fleet the launch reached — which answers both halves of "busy" —
    /// and the titles the fleet browser already built.
    static func forApp(_ model: AppModel) -> QuitGuard? {
        guard let fleet = model.composers.fleet else { return nil }
        let browser = model.browser
        return QuitGuard(fleet: FleetQuitTermination(
            lifecycle: fleet,
            shutdown: { await fleet.shutdown() },
            title: { key in browser?.row(key.session)?.title }))
    }
}
