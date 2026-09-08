import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// §7.4's *Quit* clause (tracker 71), the last of C6.2.
///
/// Two levels, and both are needed. `QuitGuard` over a recording `QuitFleet` is where the clause's
/// **order** is asserted — ask once, then terminate every owned channel with a process, then shut
/// down — because one ordered log is the only thing that can fail a guard that does all three in
/// the wrong sequence. `FleetQuitTermination` over C6.2's `ComposerLifecycleDouble` is where the
/// **mapping** is asserted: which origins are owned, which of them have a process, and that a
/// foreign or background-job channel reaches X5 with nothing at all.
///
/// Every identifier here is invented and no assertion prints a title, a path or a session id (§11).
@MainActor
final class QuitGuardTests: XCTestCase {

    // MARK: - The clause, over a recorded call log

    /// A busy owned channel is asked about **once**, and the channels the dialog names are exactly
    /// the busy owned ones — compared both ways, with a floor so an empty ask cannot pass.
    func testABusyOwnedChannelIsAskedAboutOnceAndNamesExactlyTheBusyChannels() async {
        let fleet = QuitFleetDouble(channels: [
            .owned("a", busy: true),
            .owned("c", busy: false),
            .owned("b", busy: true)
        ])
        var seen: [[QuitChannel]] = []
        let guardModel = QuitGuard(fleet: fleet, confirm: { channels in seen.append(channels); return true })

        let mayExit = await guardModel.quit()

        XCTAssertTrue(mayExit, "the confirmed arm lets the app exit")
        XCTAssertEqual(guardModel.askCount, 1, "the clause asks once")
        XCTAssertEqual(seen.count, 1, "one dialog reached the user")
        let named = Set(seen.first?.map(\.title) ?? [])
        let expected: Set<String> = ["a", "b"]
        XCTAssertEqual(named.count, 2, "the dialog named \(named.count) channel(s); 2 were busy")
        XCTAssertTrue(named == expected,
                      "the dialog named \(named.subtracting(expected).count) channel(s) that were not busy "
                      + "and missed \(expected.subtracting(named).count) that were")
    }

    /// On confirmation: `terminate()` on each owned channel with a process, **then**
    /// `Fleet.shutdown()`, in that order on one log.
    func testConfirmationTerminatesEveryOwnedProcessAndThenShutsDown() async {
        let fleet = QuitFleetDouble(channels: [
            .owned("a", busy: true, hasProcess: true),
            .owned("c", busy: false, hasProcess: true)
        ])
        let guardModel = QuitGuard(fleet: fleet, confirm: { _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the confirmed arm lets the app exit")

        // Member names and never a key: an equality over the log itself would print a session id
        // on failure (§11).
        XCTAssertEqual(fleet.memberSequence, ["listed", "terminated", "terminated", "shutdown"],
                       "the owned set is read, then each process is terminated, then the fleet shuts down")
        let terminated = fleet.terminatedTitles
        XCTAssertEqual(terminated.count, 2, "\(terminated.count) channel(s) were terminated; 2 had a process")
        XCTAssertTrue(Set(terminated) == Set(["a", "c"]),
                      "the terminated set and the owned-with-process set differ by "
                      + "\(Set(terminated).symmetricDifference(["a", "c"]).count) channel(s)")
        let members = fleet.memberSequence
        guard let shutdownAt = members.firstIndex(of: "shutdown") else {
            return XCTFail("no shutdown was recorded")
        }
        let afterShutdown = members[shutdownAt...].filter { $0 == "terminated" }.count
        XCTAssertEqual(afterShutdown, 0, "\(afterShutdown) terminate(s) landed after the shutdown")
    }

    /// Nothing busy: no dialog at all, and the same termination sequence runs.
    func testWithNothingBusyThereIsNoDialogAndTheSequenceStillRuns() async {
        let fleet = QuitFleetDouble(channels: [.owned("c", busy: false), .owned("d", busy: false)])
        var asks = 0
        let guardModel = QuitGuard(fleet: fleet, confirm: { _ in asks += 1; return true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "nothing was busy, so nothing stands between the app and exit")

        XCTAssertEqual(asks, 0, "\(asks) dialog(s) reached the user with nothing busy")
        XCTAssertEqual(guardModel.askCount, 0, "the guard counted \(guardModel.askCount) ask(s) with nothing busy")
        XCTAssertEqual(fleet.terminatedTitles.count, 2,
                       "\(fleet.terminatedTitles.count) of 2 owned processes were terminated")
        XCTAssertEqual(fleet.memberSequence.last, "shutdown", "the shutdown still runs, and runs last")
    }

    /// Cancelling terminates nothing and does not exit.
    func testCancellingTheDialogTerminatesNothingAndDoesNotExit() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: true), .owned("c", busy: false)])
        let guardModel = QuitGuard(fleet: fleet, confirm: { _ in false })

        let mayExit = await guardModel.quit()
        XCTAssertFalse(mayExit, "a cancelled quit does not let the app exit")

        XCTAssertEqual(guardModel.askCount, 1, "the user was asked once")
        XCTAssertEqual(fleet.terminatedTitles.count, 0,
                       "\(fleet.terminatedTitles.count) channel(s) were terminated after a cancel")
        XCTAssertFalse(fleet.memberSequence.contains("shutdown"), "the fleet was shut down after a cancel")
    }

    /// An owned channel with no process is not terminated — there is nothing to terminate — and does
    /// not stop the pass reaching the ones that do have one, or the shutdown.
    func testAnOwnedChannelWithNoProcessIsSkippedButDoesNotBlockTheSequence() async {
        let fleet = QuitFleetDouble(channels: [
            .owned("e", busy: false, hasProcess: false),
            .owned("f", busy: false, hasProcess: true)
        ])
        let guardModel = QuitGuard(fleet: fleet, confirm: { _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "a processless channel does not hold the app open")

        let terminated = fleet.terminatedTitles
        XCTAssertEqual(terminated.count, 1, "\(terminated.count) channel(s) were terminated; 1 had a process")
        XCTAssertTrue(terminated == ["f"],
                      "the terminated set and the owned-with-process set differ by "
                      + "\(Set(terminated).symmetricDifference(["f"]).count) channel(s)")
        XCTAssertEqual(fleet.memberSequence.last, "shutdown", "the shutdown still runs")
    }

    // MARK: - The mapping, over C6.2's recording double

    /// **Foreign and background-job channels receive nothing.** Asserted on the one ordered X5 log,
    /// with the owned arm as the floor: a guard that reached nothing at all would fail the first
    /// assertion, so the empty half cannot pass vacuously.
    func testForeignAndBackgroundChannelsReachX5WithNothing() async throws {
        let double = ComposerLifecycleDouble()
        let owned = QuitRig.key("a")
        let foreign = QuitRig.key("b")
        let job = QuitRig.key("c")
        let archived = QuitRig.key("d")
        await double.setStates([
            QuitRig.state(owned, origin: .owned(.ready)),
            QuitRig.state(foreign, origin: .foreignLive(.usersTerminal), presence: .busy),
            QuitRig.state(job, origin: .backgroundJob, presence: .busy),
            QuitRig.state(archived, origin: .archived)
        ])
        await double.alwaysPerform(.success(QuitRig.state(owned, origin: .owned(.dormant))))
        let guardModel = QuitGuard(fleet: QuitRig.termination(double), confirm: { _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the sequence ran")

        let keys = QuitRig.terminatedKeys(await double.calls)
        XCTAssertEqual(keys.count, 1, "\(keys.count) channel(s) were terminated; 1 was owned with a process")
        XCTAssertTrue(keys.contains(owned), "the owned channel is the one that was terminated")
        let verbs = await double.actions
        XCTAssertEqual(verbs.filter(QuitRig.isQuit).count, 1,
                       "\(verbs.filter(QuitRig.isQuit).count) of \(verbs.count) terminating action(s) were `.quit`")
        XCTAssertEqual(verbs.filter(QuitRig.isReap).count, 0,
                       "\(verbs.filter(QuitRig.isReap).count) terminating action(s) reached for the eligibility-gated reap")
        for untouchable in [foreign, job, archived] {
            let count = await double.calls.filter { QuitRig.key(of: $0) == untouchable }.count
            XCTAssertEqual(count, 0, "\(count) X5 call(s) reached a channel afleet does not own")
        }
    }

    /// The dialog names a busy *owned* channel and never a busy foreign one, and a channel with
    /// running background tasks is busy even when its presence is idle — the two halves of "a turn
    /// running or running local shells", read from the two places this leaf already reads them.
    func testBusyIsTheTurnOrTheRunningShellsAndOnlyForOwnedChannels() async {
        let double = ComposerLifecycleDouble()
        let turning = QuitRig.key("a")
        let shelling = QuitRig.key("b")
        let quiet = QuitRig.key("c")
        let foreign = QuitRig.key("d")
        await double.setStates([
            QuitRig.state(turning, origin: .owned(.ready), presence: .busy),
            QuitRig.state(shelling, origin: .owned(.ready), presence: .idle),
            QuitRig.state(quiet, origin: .owned(.ready), presence: .idle),
            QuitRig.state(foreign, origin: .foreignLive(.usersTerminal), presence: .busy)
        ])
        await double.alwaysPerform(.success(QuitRig.state(quiet, origin: .owned(.dormant))))
        // The fleet's own answer, not a surface's count: `b` has no composer in this test and never
        // will, and X5 still reports its running shells.
        await double.stageLiveTasks(["invented-task-1", "invented-task-2"], for: shelling)
        var seen: [[QuitChannel]] = []
        let termination = QuitRig.termination(double, titles: { QuitRig.title(of: $0) })
        let guardModel = QuitGuard(fleet: termination, confirm: { channels in seen.append(channels); return true })

        _ = await guardModel.quit()

        XCTAssertEqual(seen.count, 1, "the clause asked \(seen.count) time(s)")
        let named = Set(seen.first?.map(\.title) ?? [])
        XCTAssertEqual(named.count, 2, "the dialog named \(named.count) channel(s); 2 owned channels were busy")
        XCTAssertTrue(named == ["a", "b"],
                      "the named set and the busy owned set differ by "
                      + "\(named.symmetricDifference(["a", "b"]).count) channel(s)")
    }

    /// **Exactly one X5 call per owned channel with a process, and it is never `.reap`.**
    ///
    /// §7.4's *Quit* is the bare terminate: `.quit` is unconditional, gated on no eligibility check
    /// and refuses neither `notEligible` nor `busy`, so a channel with a turn in flight and a
    /// background shell still working — precisely what the dialog just asked about — is ended by one
    /// call. The arm this replaces escalated a refused `.reap` through `.stopEverything`; its own
    /// failure path exited with no signal and **no wedge record**, which §6.7 does not allow.
    ///
    /// The `.reap` half is the discriminator: a composer back on the eligibility-gated verb fails
    /// here even though the channel is still, in the end, terminated.
    func testEachOwnedProcessIsTerminatedByExactlyOneUnconditionalQuit() async {
        let double = ComposerLifecycleDouble()
        let busy = QuitRig.key("a")
        let quiet = QuitRig.key("b")
        let dormant = QuitRig.key("c")
        await double.setStates([
            QuitRig.state(busy, origin: .owned(.ready), presence: .busy),
            QuitRig.state(quiet, origin: .owned(.connecting)),
            QuitRig.state(dormant, origin: .owned(.dormant))
        ])
        await double.alwaysPerform(.success(QuitRig.state(busy, origin: .owned(.dormant))))
        let guardModel = QuitGuard(fleet: QuitRig.termination(double), confirm: { _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the confirmed quit completes")

        let actions = await double.actions
        XCTAssertEqual(actions.count, 2,
                       "\(actions.count) terminating action(s) were performed; 2 owned channels had a process")
        XCTAssertEqual(actions.filter(QuitRig.isQuit).count, 2,
                       "\(actions.filter(QuitRig.isQuit).count) of \(actions.count) action(s) were the unconditional quit")
        XCTAssertEqual(actions.filter(QuitRig.isReap).count, 0,
                       "\(actions.filter(QuitRig.isReap).count) action(s) reached for the eligibility-gated reap")
        let keys = Set(QuitRig.terminatedKeys(await double.calls))
        XCTAssertEqual(keys.count, 2, "\(keys.count) distinct channel(s) were terminated; 2 had a process")
        XCTAssertEqual(keys.intersection([dormant]).count, 0,
                       "\(keys.intersection([dormant]).count) processless channel(s) were terminated")
    }

    /// **The arm `liveTaskIDs(of:)` exists to close.** A channel with **no composer** — one the user
    /// never opened, so there is no timeline model and no local count to read — whose fleet reports a
    /// running task is named in the dialog all the same, because busy is asked of X5 and not of a
    /// surface. Its presence is idle, so a clause that judged by presence alone would let the app
    /// end a working channel without asking.
    ///
    /// Nothing in this test builds a `ComposerModel` or a `ComposerRegistry`; that absence is the
    /// premise.
    func testAChannelWithNoComposerIsNamedWhenTheFleetReportsALiveTask() async {
        let double = ComposerLifecycleDouble()
        let unopened = QuitRig.key("a")
        let quiet = QuitRig.key("b")
        await double.setStates([
            QuitRig.state(unopened, origin: .owned(.ready), presence: .idle),
            QuitRig.state(quiet, origin: .owned(.ready), presence: .idle)
        ])
        await double.stageLiveTasks(["invented-task-1"], for: unopened)
        await double.alwaysPerform(.success(QuitRig.state(quiet, origin: .owned(.dormant))))
        var seen: [[QuitChannel]] = []
        let termination = QuitRig.termination(double, titles: { QuitRig.title(of: $0) })
        let guardModel = QuitGuard(fleet: termination, confirm: { channels in seen.append(channels); return true })

        _ = await guardModel.quit()

        XCTAssertEqual(seen.count, 1, "the clause asked \(seen.count) time(s) with one live task in the fleet")
        let named = Set(seen.first?.map(\.title) ?? [])
        XCTAssertEqual(named.count, 1,
                       "the dialog named \(named.count) channel(s); 1 was busy, and only by its live task")
        XCTAssertTrue(named == ["a"],
                      "the named set and the busy set differ by \(named.symmetricDifference(["a"]).count) channel(s)")
        // The question was asked of the fleet, of every owned channel, and of nothing else.
        let asked = await double.calls.filter { if case .liveTaskIDs = $0 { return true } else { return false } }.count
        XCTAssertEqual(asked, 2, "the fleet was asked about \(asked) channel(s); 2 were owned")
    }

    /// The X5 call log is read for order as well as for membership: every terminate lands before the
    /// shutdown closure runs.
    func testEveryTerminateLandsBeforeTheShutdown() async {
        let double = ComposerLifecycleDouble()
        let first = QuitRig.key("a")
        let second = QuitRig.key("b")
        await double.setStates([
            QuitRig.state(first, origin: .owned(.ready)),
            QuitRig.state(second, origin: .owned(.connecting))
        ])
        await double.alwaysPerform(.success(QuitRig.state(first, origin: .owned(.dormant))))
        let counter = QuitShutdownCounter()
        let termination = FleetQuitTermination(lifecycle: double,
                                               shutdown: { await counter.note(await double.performCount) },
                                               title: { QuitRig.title(of: $0) })
        let guardModel = QuitGuard(fleet: termination, confirm: { _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the sequence ran")

        let terminated = QuitRig.terminatedKeys(await double.calls).count
        XCTAssertEqual(terminated, 2, "\(terminated) of 2 owned processes were terminated")
        let atShutdown = await counter.callsAtShutdown
        XCTAssertEqual(atShutdown, 2,
                       "\(atShutdown ?? -1) terminate(s) had landed when the shutdown ran; 2 were owed first")
    }

    // MARK: - The hook

    /// `applicationShouldTerminate` itself, run headlessly: it hands the answer to the injected
    /// reply rather than to `NSApplication`, so the decision is observable without terminating the
    /// test host. A quit the guard permits replies `true`; a cancelled one replies `false`.
    func testTheTerminationHookRepliesWithTheGuardsAnswer() async {
        for (confirmed, expected) in [(true, true), (false, false)] {
            let fleet = QuitFleetDouble(channels: [.owned("a", busy: true)])
            let delegate = AfleetQuitDelegate()
            let replies = QuitReplyRecorder()
            delegate.reply = { replies.note($0) }
            delegate.makeGuard = { QuitGuard(fleet: fleet, confirm: { _ in confirmed }) }

            let verdict = delegate.applicationShouldTerminate(NSApplication.shared)
            XCTAssertEqual(verdict, .terminateLater, "the hook defers while the guard decides")
            await replies.settle()

            XCTAssertEqual(replies.answers.count, 1, "the hook replied \(replies.answers.count) time(s)")
            XCTAssertEqual(replies.answers.first, expected, "the reply is the guard's own answer")
            XCTAssertEqual(fleet.terminatedTitles.count, expected ? 1 : 0,
                           "\(fleet.terminatedTitles.count) channel(s) were terminated on this arm")
        }
    }

    /// With no guard to build — a quit before a launch reached a workspace — the hook terminates now
    /// rather than deferring on a decision nobody will make.
    func testTheHookTerminatesNowWhenThereIsNoFleetToEnd() {
        let delegate = AfleetQuitDelegate()
        let replies = QuitReplyRecorder()
        delegate.reply = { replies.note($0) }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow,
                       "a quit with no workspace behind it is not deferred")
        XCTAssertEqual(replies.answers.count, 0, "\(replies.answers.count) deferred repl(ies) were made")
    }
}

// MARK: - Support

/// The `QuitFleet` the clause's order is asserted on: one ordered log for all three members.
@MainActor
final class QuitFleetDouble: QuitFleet, @unchecked Sendable {

    enum Call: Hashable {
        case listed
        case terminated(ChannelKey)
        case shutdown
    }

    private let channels: [QuitChannel]
    private(set) var log: [Call] = []

    /// The members called, in order, with no key attached. The spelling every ordering assertion
    /// uses, because it cannot print a session id on failure (§11) — the same convention
    /// `ComposerLifecycleDouble.memberSequence` follows.
    var memberSequence: [String] {
        log.map { call in
            switch call {
            case .listed: "listed"
            case .terminated: "terminated"
            case .shutdown: "shutdown"
            }
        }
    }

    init(channels: [QuitChannel]) { self.channels = channels }

    /// The titles of the channels that were terminated, in order. A title invented by this test, and
    /// what makes the terminated set readable without a session id.
    var terminatedTitles: [String] {
        log.compactMap { call in
            guard case .terminated(let key) = call else { return nil }
            return channels.first { $0.key == key }?.title
        }
    }

    nonisolated func quitChannels() async -> [QuitChannel] {
        await MainActor.run { log.append(.listed); return channels }
    }

    nonisolated func terminateForQuit(_ key: ChannelKey) async {
        await MainActor.run { log.append(.terminated(key)) }
    }

    nonisolated func shutdownForQuit() async {
        await MainActor.run { log.append(.shutdown) }
    }
}

@MainActor
extension QuitChannel {
    /// One owned channel, named by an invented title.
    static func owned(_ title: String, busy: Bool, hasProcess: Bool = true) -> QuitChannel {
        QuitChannel(key: QuitRig.key(title), title: title, hasProcess: hasProcess, isBusy: busy)
    }
}

/// How many X5 calls had been made when the shutdown ran — the positional half of the ordering
/// assertion, over the double's own log.
actor QuitShutdownCounter {
    private(set) var callsAtShutdown: Int?
    func note(_ count: Int) { callsAtShutdown = count }
}

/// The hook's replies. A class rather than a local `var` because the hook answers from a detached
/// task, and `settle()` is what a test awaits instead of sleeping.
@MainActor
final class QuitReplyRecorder {
    private(set) var answers: [Bool] = []
    func note(_ answer: Bool) { answers.append(answer) }
    /// Yields until the hook's task has run. The task is main-actor and enqueued before this call,
    /// so one hop past it is enough.
    func settle() async {
        for _ in 0..<8 where answers.isEmpty { await Task.yield() }
    }
}

@MainActor
enum QuitRig {

    static func key(_ nibble: String) -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session(String(nibble.prefix(1))))
    }

    /// The invented title of a channel, recovered from its key so an assertion can name the channel
    /// it means without reading a real row.
    static func title(of key: ChannelKey) -> String? {
        for nibble in ["a", "b", "c", "d", "e", "f"] where key == QuitRig.key(nibble) { return nibble }
        return nil
    }

    static func state(_ key: ChannelKey, origin: ChannelOrigin, presence: Presence = .idle) -> ChannelState {
        ChannelState(key: key,
                     origin: origin,
                     desired: .owned,
                     observed: HolderSet(holders: [], observedAt: Date(timeIntervalSince1970: 0)),
                     epoch: .first,
                     identity: .known(key.session),
                     presence: presence,
                     lastActivity: Date(timeIntervalSince1970: 0))
    }

    static func termination(_ double: ComposerLifecycleDouble,
                            titles: @escaping @MainActor @Sendable (ChannelKey) -> String? = { _ in nil })
    -> FleetQuitTermination {
        FleetQuitTermination(lifecycle: double, shutdown: {}, title: titles)
    }

    /// The channels a recorded log terminated, in order — every `perform`, whatever action it
    /// carried, so a pass that reached for the wrong verb still shows up here and is caught by
    /// `isQuit` below rather than silently vanishing from the count.
    static func terminatedKeys(_ calls: [ComposerLifecycleDouble.Call]) -> [ChannelKey] {
        calls.compactMap { call in
            guard case .perform(let key, _) = call else { return nil }
            return key
        }
    }

    static func isQuit(_ action: LifecycleAction?) -> Bool {
        if case .quit = action { return true }
        return false
    }

    static func isReap(_ action: LifecycleAction?) -> Bool {
        if case .reap = action { return true }
        return false
    }

    /// The channel one recorded X5 call was made on, so "this key received nothing" is a claim over
    /// the whole log rather than over one member.
    static func key(of call: ComposerLifecycleDouble.Call) -> ChannelKey? {
        switch call {
        case .perform(let key, _), .sendPrompt(let key, _), .route(let key, _), .send(let key, _, _),
             .run(let key, _, _), .openInTerminal(let key), .events(let key), .preconditions(let key),
             .liveTaskIDs(let key), .engineReports(let key), .resolveSetting(let key, _):
            key
        case .storeWrite:
            nil
        }
    }
}
