import AppKit
import Foundation
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
/// busy, `terminate()` each owned channel **that has a process**, then `Fleet.shutdown()`, then
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
    /// A turn running or running local shells. Not a second notion of busy: it is the presence the
    /// sidebar and the composer already read, plus the live background tasks the *Send to
    /// background* confirm already names.
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
        for channel in owned where channel.hasProcess {
            await fleet.terminateForQuit(channel.key)
        }
        await fleet.shutdownForQuit()
        return true
    }

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
    /// The channel's running background tasks, as the *Send to background* confirm already counts
    /// them. Reads a composer that already exists and constructs nothing.
    let liveTaskCount: @MainActor @Sendable (ChannelKey) -> Int
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
            let tasks = await MainActor.run { liveTaskCount(state.key) }
            let name = await MainActor.run { title(state.key) } ?? Self.unnamed
            channels.append(QuitChannel(key: state.key,
                                        title: name,
                                        // §7.4: ready and connecting each assert a process, and a
                                        // contended channel is one whose process afleet still holds;
                                        // dormant is the resting state of every processless one.
                                        hasProcess: owned != .dormant,
                                        isBusy: state.presence == .busy || tasks > 0))
        }
        return channels
    }

    /// `terminate()` on one owned channel: X5's `.reap`.
    ///
    /// **`perform(.reap)` is gated on dormant eligibility** — `Fleet` refuses the reap the *user*
    /// asked for on a channel with a turn in flight or a background shell still working — and the
    /// channels the quit dialog just asked about are exactly the ineligible ones. There is no
    /// unconditional terminate on X5 (`ChannelSupervisor.reap()` is not reachable through the
    /// facade), so a refused reap is followed by `.stopEverything`, which interrupts the turn and
    /// stops each running task, and then by the reap again. That is what the user confirmed when
    /// they were told quitting ends these channels; it is not a second policy. Filed for the
    /// architect as the one place §7.4 asks for a capability X5 does not publish.
    func terminateForQuit(_ key: ChannelKey) async {
        do {
            _ = try await lifecycle.perform(.reap, on: key)
        } catch LifecycleError.notEligible {
            _ = try? await lifecycle.perform(.stopEverything, on: key)
            _ = try? await lifecycle.perform(.reap, on: key)
        } catch {
            // Every other refusal is final and the exit is not held for it: at exit the pipe closes
            // and the engine winds the channel down anyway, which is the fact the whole clause rests
            // on.
        }
    }

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let quitGuard = makeGuard?() else { return .terminateNow }
        Task { @MainActor in reply(await quitGuard.quit()) }
        return .terminateLater
    }
}

extension QuitGuard {

    /// The app's own guard: the fleet the launch reached, the live tasks the composers already know
    /// about, and the titles the fleet browser already built.
    static func forApp(_ model: AppModel) -> QuitGuard? {
        guard let fleet = model.composers.fleet else { return nil }
        let composers = model.composers
        let browser = model.browser
        return QuitGuard(fleet: FleetQuitTermination(
            lifecycle: fleet,
            shutdown: { await fleet.shutdown() },
            liveTaskCount: { key in composers.liveTaskCount(for: key) },
            title: { key in browser?.row(key.session)?.title }))
    }
}
