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
        let guardModel = QuitGuard(fleet: fleet, confirm: { channels, _ in seen.append(channels); return true })

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
        let guardModel = QuitGuard(fleet: fleet, confirm: { _, _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the confirmed arm lets the app exit")

        // Member names and never a key: an equality over the log itself would print a session id
        // on failure (§11).
        // The second `listed` is the pass's own re-census: a channel that gained a process while the
        // terminations ran is read there, and this fleet has none, so nothing follows it.
        XCTAssertEqual(fleet.memberSequence, ["listed", "terminated", "terminated", "listed", "shutdown"],
                       "the owned set is read, then each process is terminated, then the set is read again, "
                       + "then the fleet shuts down")
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
        let guardModel = QuitGuard(fleet: fleet, confirm: { _, _ in asks += 1; return true })

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
        let guardModel = QuitGuard(fleet: fleet, confirm: { _, _ in false })

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
        let guardModel = QuitGuard(fleet: fleet, confirm: { _, _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "a processless channel does not hold the app open")

        let terminated = fleet.terminatedTitles
        XCTAssertEqual(terminated.count, 1, "\(terminated.count) channel(s) were terminated; 1 had a process")
        XCTAssertTrue(terminated == ["f"],
                      "the terminated set and the owned-with-process set differ by "
                      + "\(Set(terminated).symmetricDifference(["f"]).count) channel(s)")
        XCTAssertEqual(fleet.memberSequence.last, "shutdown", "the shutdown still runs")
    }

    // MARK: - The census after the pass

    /// A channel that acquires a process while the pass is running is terminated before the shutdown.
    ///
    /// The census is one suspended read and nothing raises a spawn barrier over it: an open, an adopt
    /// or a pane exit can hand a channel a process after its entry was taken, and that channel is
    /// then skipped by a saved loop. `Fleet.shutdown()` terminates nothing — streams, timers and
    /// diagnostics only — so the process would live until the exit closed its pipe, with no
    /// deliberate ending at all.
    ///
    /// The double omits the arriving channel from the first census exactly as the race does, and the
    /// assertion is on the ordered log: the second channel is terminated, and before the shutdown.
    func testAChannelThatGainsAProcessDuringThePassIsStillTerminated() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: true)])
        // Lands after the first census is taken — the window the clause cannot close.
        fleet.arriving = [1: [.owned("b", busy: false)]]
        let guardModel = QuitGuard(fleet: fleet, confirm: { _, _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the clause ran to the end")

        let terminated = fleet.terminatedTitles
        XCTAssertEqual(terminated.count, 2,
                       "\(terminated.count) channel(s) were terminated; 2 owned channels had a process by the end")
        XCTAssertTrue(Set(terminated) == Set(["a", "b"]),
                      "the terminated set and the owned-with-process set differ by "
                      + "\(Set(terminated).symmetricDifference(["a", "b"]).count) channel(s)")
        let members = fleet.memberSequence
        guard let shutdownAt = members.firstIndex(of: "shutdown") else {
            return XCTFail("no shutdown was recorded")
        }
        XCTAssertEqual(members[shutdownAt...].filter { $0 == "terminated" }.count, 0,
                       "a terminate landed after the shutdown")
        XCTAssertEqual(members.last, "shutdown", "the shutdown is not the last thing the clause does")
    }

    /// **Busy work found only by a later census is warned about, once.** The first census was idle, so no dialog
    /// was shown; a channel that starts working in the window the re-census exists for has running shells the next
    /// pass closes, and X9 owes that warning whether the work was there at the first read or arrived after it.
    ///
    /// The discriminating arm is the decline: nothing that appeared after the first census is terminated, and the
    /// termination request is answered with a cancel. What was already ended in this quit stays ended, and a quit
    /// ends a channel dormant and resumable.
    ///
    /// Deliberate break: read `isBusy` in the first census only.
    func testBusyWorkFoundByALaterCensusIsAskedAboutOnceAndADeclineStopsTheQuit() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: false)])
        // Busy, and not in the first census: the window between the read and the pass that reads it.
        fleet.arriving = [1: [.owned("b", busy: true)]]
        var seen: [[QuitChannel]] = []
        let guardModel = QuitGuard(fleet: fleet, confirm: { channels, _ in seen.append(channels); return false })

        let mayExit = await guardModel.quit()

        XCTAssertFalse(mayExit, "a declined warning about newly found work still let the app exit")
        XCTAssertEqual(guardModel.askCount, 1, "the clause asked \(guardModel.askCount) time(s) about work it found late")
        let named = Set(seen.first?.map(\.title) ?? [])
        XCTAssertTrue(named == ["b"],
                      "the dialog named \(named.count) channel(s), and not the one that started working")
        XCTAssertTrue(fleet.terminatedTitles == ["a"],
                      "\(fleet.terminatedTitles.count) channel(s) were terminated; only the idle one the first pass "
                      + "had already taken should have been")
        XCTAssertFalse(fleet.memberSequence.contains("shutdown"), "the fleet shut down after a declined warning")
    }

    /// The other arm of the same rule: a user who has **already** accepted is not asked a second time when the
    /// re-census finds more busy work, and the passes run to the shutdown.
    func testAnAcceptedWarningIsNotRepeatedForWorkALaterCensusFinds() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: true)])
        fleet.arriving = [1: [.owned("b", busy: true)]]
        var asks = 0
        let guardModel = QuitGuard(fleet: fleet, confirm: { _, _ in asks += 1; return true })

        let mayExit = await guardModel.quit()

        XCTAssertTrue(mayExit, "the accepted quit did not reach the exit")
        XCTAssertEqual(asks, 1, "\(asks) dialog(s) reached the user for one quit; the clause asks once")
        XCTAssertEqual(fleet.terminatedTitles.count, 2,
                       "\(fleet.terminatedTitles.count) channel(s) were terminated; 2 had a process by the end")
        XCTAssertEqual(fleet.memberSequence.last, "shutdown", "the accepted quit did not shut the fleet down")
    }

    /// The re-census is **bounded**: a fleet that keeps acquiring processes is given three passes and
    /// then the app shuts down anyway.
    ///
    /// Quitting cannot become a loop the user cannot leave. What is left after the last pass — a
    /// spawn landing after the final census — is ended by the exit closing its pipe, which is the
    /// fact the whole clause rests on (tracker 196).
    func testTheCensusIsBoundedAndTheAppStillShutsDown() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: false)])
        fleet.arriving = [1: [.owned("b", busy: false)],
                          2: [.owned("c", busy: false)],
                          3: [.owned("d", busy: false)],
                          4: [.owned("e", busy: false)],
                          5: [.owned("f", busy: false)]]
        let guardModel = QuitGuard(fleet: fleet, confirm: { _, _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "a fleet that keeps spawning still lets the app exit")

        let passes = fleet.memberSequence.filter { $0 == "listed" }.count
        XCTAssertEqual(passes, 3, "the clause took \(passes) census(es); it is bounded to 3")
        XCTAssertEqual(fleet.terminatedTitles.count, 3,
                       "\(fleet.terminatedTitles.count) channel(s) were terminated across 3 bounded passes")
        XCTAssertEqual(fleet.memberSequence.last, "shutdown", "the app did not shut down after the bound was reached")
    }

    /// Each channel is terminated **once** across the passes: the repeat census exists to catch a
    /// channel that was missed, not to send a second `.quit` to one that was not.
    func testAChannelIsTerminatedOnceEvenWhenTheCensusReportsItAgain() async {
        // The double reports the same channel with a process on every census, as a fleet whose
        // state has not caught up would.
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: false)])
        let guardModel = QuitGuard(fleet: fleet, confirm: { _, _ in true })

        _ = await guardModel.quit()

        XCTAssertEqual(fleet.terminatedTitles.count, 1,
                       "\(fleet.terminatedTitles.count) terminate(s) reached a channel that had already been terminated")
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
        let guardModel = QuitGuard(fleet: QuitRig.termination(double), confirm: { _, _ in true })

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
        let guardModel = QuitGuard(fleet: termination, confirm: { channels, _ in seen.append(channels); return true })

        _ = await guardModel.quit()

        XCTAssertEqual(seen.count, 1, "the clause asked \(seen.count) time(s)")
        let named = Set(seen.first?.map(\.title) ?? [])
        XCTAssertEqual(named.count, 2, "the dialog named \(named.count) channel(s); 2 owned channels were busy")
        XCTAssertTrue(named == ["a", "b"],
                      "the named set and the busy owned set differ by "
                      + "\(named.symmetricDifference(["a", "b"]).count) channel(s)")
    }

    /// **A channel waiting on a decision is busy.**
    ///
    /// The engine has asked afleet something and is holding the conversation open for the answer; quitting ends that
    /// turn exactly as it ends a running one. A predicate that compared presence to `.busy` alone let the clause end
    /// a channel with a permission prompt on the screen without asking about it at all.
    ///
    /// Deliberate break: compare `state.presence == .busy` again.
    func testAChannelWaitingOnADecisionIsNamedInTheDialog() async {
        let double = ComposerLifecycleDouble()
        let deciding = QuitRig.key("a")
        let quiet = QuitRig.key("b")
        await double.setStates([
            QuitRig.state(deciding, origin: .owned(.ready), presence: .waiting(for: "an-invented-subtype")),
            QuitRig.state(quiet, origin: .owned(.ready), presence: .idle)
        ])
        await double.alwaysPerform(.success(QuitRig.state(quiet, origin: .owned(.dormant))))
        var seen: [[QuitChannel]] = []
        let termination = QuitRig.termination(double, titles: { QuitRig.title(of: $0) })
        let guardModel = QuitGuard(fleet: termination, confirm: { channels, _ in seen.append(channels); return true })

        _ = await guardModel.quit()

        XCTAssertEqual(seen.count, 1, "the clause asked \(seen.count) time(s) with a decision on the screen")
        let named = Set(seen.first?.map(\.title) ?? [])
        XCTAssertTrue(named == ["a"],
                      "the named set and the waiting set differ by \(named.symmetricDifference(["a"]).count) channel(s)")
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
        let guardModel = QuitGuard(fleet: QuitRig.termination(double), confirm: { _, _ in true })

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
        let guardModel = QuitGuard(fleet: termination, confirm: { channels, _ in seen.append(channels); return true })

        _ = await guardModel.quit()

        XCTAssertEqual(seen.count, 1, "the clause asked \(seen.count) time(s) with one live task in the fleet")
        let named = Set(seen.first?.map(\.title) ?? [])
        XCTAssertEqual(named.count, 1,
                       "the dialog named \(named.count) channel(s); 1 was busy, and only by its live task")
        XCTAssertTrue(named == ["a"],
                      "the named set and the busy set differ by \(named.symmetricDifference(["a"]).count) channel(s)")
        // The question was asked of the fleet, of every owned channel, and of nothing else.
        let asked = await double.calls.filter { if case .liveTaskIDs = $0 { return true } else { return false } }.count
        // Two owned channels, asked about on each of the clause's two censuses: the one the dialog is
        // built from and the one the pass takes afterwards.
        XCTAssertEqual(asked, 4, "the fleet was asked about \(asked) channel(s); 2 were owned, on 2 censuses")
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
        let guardModel = QuitGuard(fleet: termination, confirm: { _, _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the sequence ran")

        let terminated = QuitRig.terminatedKeys(await double.calls).count
        XCTAssertEqual(terminated, 2, "\(terminated) of 2 owned processes were terminated")
        let atShutdown = await counter.callsAtShutdown
        XCTAssertEqual(atShutdown, 2,
                       "\(atShutdown ?? -1) terminate(s) had landed when the shutdown ran; 2 were owed first")
    }

    // MARK: - The `!` commands the quit ends

    /// **The host commands are cancelled before the shutdown, and only on a quit that is going through.**
    ///
    /// A `!` is not a channel: it is afleet's own child, in a process group of its own, and `Fleet` has no
    /// member that names one. So the clause has to end them itself, on the same log the rest of its order is
    /// asserted on.
    ///
    /// Deliberate break: leave the cancel out, or move it after `shutdownForQuit()`.
    func testTheRunningHostCommandsAreCancelledBeforeTheShutdown() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: false)])
        let guardModel = QuitGuard(fleet: fleet, hostCommands: fleet, confirm: { _, _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the confirmed arm lets the app exit")

        XCTAssertEqual(fleet.memberSequence, ["listed", "terminated", "listed", "cancelled", "shutdown"],
                       "the owned process is terminated, then the host commands are cancelled, then the fleet "
                       + "shuts down")
    }

    /// The other arm: a declined quit leaves every `!` running, because the app is not exiting.
    func testADeclinedQuitCancelsNoHostCommand() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: true)])
        let guardModel = QuitGuard(fleet: fleet, hostCommands: fleet, confirm: { _, _ in false })

        let mayExit = await guardModel.quit()
        XCTAssertFalse(mayExit, "a cancelled quit does not let the app exit")

        XCTAssertEqual(fleet.cancelCount, 0,
                       "\(fleet.cancelCount) host-command cancellation(s) ran for a quit the user declined")
    }

    /// **A real `!` does not survive the quit.** The composer runs a command whose shell starts a `sleep` and
    /// waits for it, so there is a descendant in the child's own process group — the shape that outlives
    /// every ending short of a signal to the group. The whole thing is driven through the guard's seam, over
    /// the app's own registry, which is where a running host command is actually held.
    ///
    /// Failed before the fix: the quit shut the fleet down and returned with the `sleep` still on the
    /// machine, its budget and its escalation about to leave with the process that held them.
    ///
    /// The descendant is identified by the pid it wrote down and probed with `kill(pid, 0)`, exactly as
    /// `ShellEscapeTests` does; a pid is a count of nothing and names no path, session or environment (§11).
    /// The command's environment is the channel's own two variables and nothing of this runner's (X11).
    func testAQuitEndsARunningHostCommandAndItsDescendant() async throws {
        let tree = try TempTree()
        let work = try tree.directory("work")
        let pidFile = work.appending(path: "descendant-pid")
        let double = ComposerLifecycleDouble()
        let registry = ComposerRegistry()
        registry.lifecycle = double
        registry.contextProvider = { key, cwd in
            ComposerContextFixtures.context(key, cwd: cwd, shell: "/bin/sh",
                                            variables: ["PATH": "/usr/bin:/bin"])
        }
        let channel = QuitRig.key("a")
        let model = try XCTUnwrap(registry.model(for: channel, cwd: work), "the registry built no composer")
        model.draft = "!sleep 30 & printf '%s' \"$!\" > '\(pidFile.path)'; wait"

        let send = Task { @MainActor in await model.send() }
        defer { send.cancel() }
        guard let descendant = try await recordedPID(in: pidFile, within: 100) else {
            return XCTFail("the command recorded no descendant to probe")
        }
        defer { _ = kill(descendant, SIGKILL) }

        let fleet = QuitFleetDouble(channels: [])
        let guardModel = QuitGuard(fleet: fleet, hostCommands: registry, confirm: { _, _ in true })
        let mayExit = await guardModel.quit()

        XCTAssertTrue(mayExit, "the quit did not reach the exit")
        XCTAssertEqual(fleet.memberSequence.last, "shutdown", "the fleet was not shut down")
        let ended = try await died(descendant, within: 20)
        XCTAssertTrue(ended, "a host command's descendant outlived the quit by more than 2 second(s)")
    }

    // MARK: - Bounded probes

    /// The pid the command wrote down, waited for a tenth of a second at a time.
    private func recordedPID(in file: URL, within attempts: Int) async throws -> pid_t? {
        for _ in 0..<attempts {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Whether `pid` is gone, polled a tenth of a second at a time. The pid itself is never printed.
    private func died(_ pid: pid_t, within attempts: Int) async throws -> Bool {
        for _ in 0..<attempts {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return kill(pid, 0) != 0 && errno == ESRCH
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
            delegate.makeGuard = { QuitGuard(fleet: fleet, confirm: { _, _ in confirmed }) }

            let verdict = delegate.applicationShouldTerminate(NSApplication.shared)
            XCTAssertEqual(verdict, .terminateLater, "the hook defers while the guard decides")
            await replies.settle()

            XCTAssertEqual(replies.answers.count, 1, "the hook replied \(replies.answers.count) time(s)")
            XCTAssertEqual(replies.answers.first, expected, "the reply is the guard's own answer")
            XCTAssertEqual(fleet.terminatedTitles.count, expected ? 1 : 0,
                           "\(fleet.terminatedTitles.count) channel(s) were terminated on this arm")
        }
    }

    /// A second termination request while the first is still deciding is answered without a second
    /// dialog and without a second sequence.
    ///
    /// The guard's own `isQuitting` flag cannot do this: production `makeGuard` builds a fresh
    /// `QuitGuard` per request, so two requests are two instances and neither can see the other. Two
    /// concurrent sequences would ask twice, terminate twice and reply twice for one quit.
    func testASecondTerminationRequestIsNotASecondDialog() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: true)])
        let gate = QuitDialogGate()
        let delegate = AfleetQuitDelegate()
        let replies = QuitReplyRecorder()
        delegate.reply = { replies.note($0) }
        let built = QuitGuardCounter()
        delegate.makeGuard = {
            built.note()
            return QuitGuard(fleet: fleet, confirm: { _, _ in await gate.answer() })
        }

        let first = delegate.applicationShouldTerminate(NSApplication.shared)
        // The dialog is up; the second request arrives while it is.
        await gate.settleUntilAsked()
        let second = delegate.applicationShouldTerminate(NSApplication.shared)
        await gate.release(true)
        await replies.settle()

        XCTAssertEqual(first, .terminateLater, "the first request was not deferred")
        XCTAssertEqual(second, .terminateLater, "the second request answered while the first was still deciding")
        XCTAssertEqual(built.count, 1, "\(built.count) guard(s) were built for one quit")
        let asks = await gate.asks
        XCTAssertEqual(asks, 1, "the user was asked \(asks) time(s) for one quit")
        XCTAssertEqual(replies.answers.count, 1, "the hook replied \(replies.answers.count) time(s) for one quit")
        XCTAssertEqual(fleet.terminatedTitles.count, 1,
                       "\(fleet.terminatedTitles.count) terminate(s) ran for one quit")
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

    // MARK: - Panel state on the way to disk (C7.6 A7)

    /// The quit drains panel state that is still on its way to disk, **before** the shutdown.
    ///
    /// The Browser commits URL and title changes through a trailing window (C7.6 Q6), so an edit
    /// made in the last half-second lives in memory by design. `shutdown()` terminates nothing and
    /// knows nothing about it, and the terminations above end conversations rather than panels — so
    /// without this the app exits over its own unwritten tab set, which is what G3 rests on.
    func testTheQuitDrainsPanelStateBeforeItShutsDown() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: false, hasProcess: true)])
        var drained = 0
        var shutdownHadHappened: Bool?
        let guardModel = QuitGuard(fleet: fleet,
                                   drainPanels: {
                                       drained += 1
                                       shutdownHadHappened = fleet.memberSequence.contains("shutdown")
                                   },
                                   confirm: { _, _ in true })

        let mayExit = await guardModel.quit()

        XCTAssertTrue(mayExit, "nothing was busy, so the quit goes through")
        XCTAssertEqual(drained, 1, "the quit drained panel state \(drained) times, not once")
        XCTAssertEqual(shutdownHadHappened, false,
                       "the drain ran after the shutdown, which is after the writes could still land")
    }

    /// A declined quit drains nothing: the app is not going away, and the window is still open.
    func testADeclinedQuitDrainsNothing() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: true, hasProcess: true)])
        var drained = 0
        let guardModel = QuitGuard(fleet: fleet, drainPanels: { drained += 1 }, confirm: { _, _ in false })

        let mayExit = await guardModel.quit()

        XCTAssertFalse(mayExit, "a declined quit does not exit")
        XCTAssertEqual(drained, 0, "a declined quit drained panel state anyway")
    }

    // MARK: - A Terminal pane with a live child (tracker 354)

    /// **A running pane makes the quit ask, and the sentence names it.**
    ///
    /// The fleet is idle and every channel is dormant, so §7.4's own "busy" is false everywhere and
    /// the clause used to walk straight past to the shutdown — closing the pty descriptor of a
    /// command the user is watching, silently. The pane fact is read beside the fleet's, and either
    /// one is enough to put the dialog on screen.
    ///
    /// Deliberate break: read `quitChannels()` alone.
    func testARunningPaneMakesAnIdleFleetAskAndTheSentenceNamesThePanes() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: false, hasProcess: true)])
        let panes = QuitPanesDouble(census: QuitPaneCensus(paneCount: 2, channelCount: 1))
        var seen: [(channels: [QuitChannel], panes: QuitPaneCensus)] = []
        let guardModel = QuitGuard(fleet: fleet, panes: panes,
                                   confirm: { channels, panes in seen.append((channels, panes)); return true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the confirmed quit runs to the end")

        XCTAssertEqual(guardModel.askCount, 1,
                       "the clause asked \(guardModel.askCount) time(s) with a pane still running")
        XCTAssertEqual(seen.first?.channels.count, 0,
                       "\(seen.first?.channels.count ?? -1) channel(s) were named; the fleet was idle")
        XCTAssertEqual(seen.first?.panes.paneCount, 2,
                       "the dialog was handed \(seen.first?.panes.paneCount ?? -1) of 2 running panes")
        XCTAssertEqual(guardModel.lastAskedPanes.paneCount, 2,
                       "the guard recorded \(guardModel.lastAskedPanes.paneCount) of 2 panes it asked about")
        let sentence = QuitGuard.warning(guardModel.lastAsked, guardModel.lastAskedPanes)
        XCTAssertTrue(sentence.contains("2 Terminal pane(s) in 1 channel(s)"),
                      "the sentence did not name the running panes at all")
    }

    /// **Nothing running anywhere: no dialog.** The pane fact does not make the clause ask more
    /// often than §7.4 says, and a guard that asked whenever a panel existed would put an alert in
    /// front of every quit.
    func testWithNoLivePaneAndAnIdleFleetTheQuitDoesNotAsk() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: false, hasProcess: true)])
        let panes = QuitPanesDouble(census: .none)
        var asks = 0
        let guardModel = QuitGuard(fleet: fleet, panes: panes, confirm: { _, _ in asks += 1; return true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "nothing was running, so nothing stands between the app and exit")

        XCTAssertEqual(asks, 0, "\(asks) dialog(s) reached the user with nothing running")
        XCTAssertEqual(guardModel.askCount, 0, "the guard counted \(guardModel.askCount) ask(s)")
        XCTAssertEqual(fleet.memberSequence.last, "shutdown", "the shutdown still runs, and runs last")
    }

    /// **A confirmed quit tears the panes down before the app goes.**
    ///
    /// Order, not timing: the teardown is recorded against the fleet's own log, and what it must
    /// stand between is the terminations behind it and the shutdown in front. Without it the panes
    /// are ended by the exit dropping their descriptors, with nothing having gone through the path
    /// that reports a pane's exit and settles what its session had scheduled.
    func testAConfirmedQuitTearsThePanesDownBeforeTheShutdown() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: false, hasProcess: true)])
        let panes = QuitPanesDouble(census: QuitPaneCensus(paneCount: 1, channelCount: 1))
        var shutdownHadHappened: Bool?
        var terminationsHadRun: Int?
        panes.onTearDown = {
            shutdownHadHappened = fleet.memberSequence.contains("shutdown")
            terminationsHadRun = fleet.memberSequence.filter { $0 == "terminated" }.count
        }
        let guardModel = QuitGuard(fleet: fleet, panes: panes, confirm: { _, _ in true })

        let mayExit = await guardModel.quit()
        XCTAssertTrue(mayExit, "the confirmed quit runs to the end")

        XCTAssertEqual(panes.teardownCount, 1,
                       "the quit tore the panes down \(panes.teardownCount) time(s), not once")
        XCTAssertEqual(shutdownHadHappened, false, "the panes were torn down after the shutdown")
        XCTAssertEqual(terminationsHadRun, 1,
                       "\(terminationsHadRun ?? -1) of 1 termination(s) had run when the panes were torn down")
        XCTAssertEqual(fleet.memberSequence.last, "shutdown", "the shutdown is not the last thing the clause does")
    }

    /// A declined quit ends no pane: the app is not going away, and the command the user just chose
    /// to keep is still running.
    func testADeclinedQuitTearsDownNoPane() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: false, hasProcess: true)])
        let panes = QuitPanesDouble(census: QuitPaneCensus(paneCount: 1, channelCount: 1))
        let guardModel = QuitGuard(fleet: fleet, panes: panes, confirm: { _, _ in false })

        let mayExit = await guardModel.quit()

        XCTAssertFalse(mayExit, "a declined quit let the app exit")
        XCTAssertEqual(panes.teardownCount, 0, "a declined quit ended \(panes.teardownCount) pane set(s)")
        XCTAssertEqual(fleet.terminatedTitles.count, 0,
                       "\(fleet.terminatedTitles.count) channel(s) were terminated after a decline")
    }

    /// The two facts are asked in one dialog, and neither hides the other: a busy channel is still
    /// named by title while the panes are named by count.
    func testABusyChannelAndARunningPaneAreOneDialog() async {
        let fleet = QuitFleetDouble(channels: [.owned("a", busy: true, hasProcess: true)])
        let panes = QuitPanesDouble(census: QuitPaneCensus(paneCount: 3, channelCount: 2))
        var seen: [(channels: [QuitChannel], panes: QuitPaneCensus)] = []
        let guardModel = QuitGuard(fleet: fleet, panes: panes,
                                   confirm: { channels, panes in seen.append((channels, panes)); return true })

        _ = await guardModel.quit()

        XCTAssertEqual(guardModel.askCount, 1, "the clause asked \(guardModel.askCount) time(s) for one quit")
        XCTAssertEqual(seen.first?.channels.map(\.title), ["a"], "the busy channel was not named")
        XCTAssertEqual(seen.first?.panes.paneCount, 3,
                       "\(seen.first?.panes.paneCount ?? -1) of 3 running panes reached the dialog")
        let sentence = QuitGuard.warning(seen.first?.channels ?? [], seen.first?.panes ?? .none)
        XCTAssertTrue(sentence.contains("3 Terminal pane(s) in 2 channel(s)"), "the panes went unmentioned")
        XCTAssertTrue(sentence.contains("Open in terminal"), "the advice about keeping a conversation was dropped")
        XCTAssertTrue(sentence.contains("terminal of your own"),
                      "the advice still points the user at a pane this same quit ends")
    }
}

// MARK: - Support

/// The `QuitFleet` the clause's order is asserted on: one ordered log for all three members, and for the
/// host-command cancellation that has to land between the last of them and the shutdown.
@MainActor
final class QuitFleetDouble: QuitFleet, QuitHostCommands, @unchecked Sendable {

    enum Call: Hashable {
        case listed
        case terminated(ChannelKey)
        case cancelledHostCommands
        case shutdown
    }

    private var channels: [QuitChannel]
    private(set) var log: [Call] = []

    /// Channels that acquire a process **after** the nth census has been taken (counted from 1) — a
    /// spawn landing in the window between the read and the pass that reads it, which is the race
    /// the repeat census exists for. They are not in that census's answer and are in every later one.
    var arriving: [Int: [QuitChannel]] = [:]
    /// How many censuses have been taken. A count (§11).
    private(set) var censusCount = 0

    /// The members called, in order, with no key attached. The spelling every ordering assertion
    /// uses, because it cannot print a session id on failure (§11) — the same convention
    /// `ComposerLifecycleDouble.memberSequence` follows.
    var memberSequence: [String] {
        log.map { call in
            switch call {
            case .listed: "listed"
            case .terminated: "terminated"
            case .cancelledHostCommands: "cancelled"
            case .shutdown: "shutdown"
            }
        }
    }

    /// How many times the quit asked for the host commands to be ended. A count (§11).
    var cancelCount: Int { log.filter { $0 == .cancelledHostCommands }.count }

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
        await MainActor.run {
            log.append(.listed)
            censusCount += 1
            let answer = channels
            channels += arriving[censusCount] ?? []
            return answer
        }
    }

    nonisolated func terminateForQuit(_ key: ChannelKey) async {
        await MainActor.run { log.append(.terminated(key)) }
    }

    nonisolated func shutdownForQuit() async {
        await MainActor.run { log.append(.shutdown) }
    }

    func cancelHostCommands() async { log.append(.cancelledHostCommands) }
}

@MainActor
extension QuitChannel {
    /// One owned channel, named by an invented title.
    static func owned(_ title: String, busy: Bool, hasProcess: Bool = true) -> QuitChannel {
        QuitChannel(key: QuitRig.key(title), title: title, hasProcess: hasProcess, isBusy: busy)
    }
}

/// The dialog, held open so a second termination request can arrive while the first is deciding.
actor QuitDialogGate {
    private(set) var asks = 0
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    /// The `confirm` closure the guard is built with.
    func answer() async -> Bool {
        asks += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Yields until the dialog has been put up, so the second request lands while it is on screen.
    func settleUntilAsked() async {
        for _ in 0..<2_000 where asks == 0 { await Task.yield() }
    }

    func release(_ answer: Bool) async {
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume(returning: answer) }
    }
}

/// How many guards the hook built. A count, and the whole of what coalescing means for a delegate
/// whose `makeGuard` answers a fresh instance every time.
@MainActor
final class QuitGuardCounter {
    private(set) var count = 0
    func note() { count += 1 }
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
    /// Yields until the hook's task has answered. Bounded rather than timed: the guard's own awaits
    /// are main-actor hops, and a hook that never replies fails on the count rather than hanging.
    func settle() async {
        for _ in 0..<2_000 where answers.isEmpty { await Task.yield() }
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
        case .perform(let key, _), .sendPrompt(let key, _), .fork(let key, _), .route(let key, _), .send(let key, _, _),
             .run(let key, _, _), .openInTerminal(let key), .events(let key), .preconditions(let key),
             .liveTaskIDs(let key), .engineReports(let key), .resolveSetting(let key, _),
             .resolvedForkKey(let key):
            key
        case .storeWrite:
            nil
        }
    }
}

/// The Terminal panel the quit reads and ends, recorded.
///
/// A census it is handed rather than one it computes: what this file asserts is the clause's own
/// decision, and the count's own truth — that an exited child is not a running pane — belongs to the
/// registry and is asserted there.
@MainActor
final class QuitPanesDouble: QuitTerminalPanes {

    var census: QuitPaneCensus
    /// How many times the clause read the pane fact. A count (§11).
    private(set) var censusReads = 0
    /// How many times it ended the panes. A count.
    private(set) var teardownCount = 0
    /// Run inside the teardown, so what the rest of the clause had done by then can be read off its
    /// own log rather than guessed at from a clock.
    var onTearDown: (@MainActor () -> Void)?

    init(census: QuitPaneCensus) { self.census = census }

    func livePaneCensus() -> QuitPaneCensus {
        censusReads += 1
        return census
    }

    func tearDownPanesForQuit() async {
        teardownCount += 1
        onTearDown?()
    }
}
