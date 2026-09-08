import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 gate **G5**: the bypass gate, exactly §8.6, and **the order is the whole content**.
///
/// Every assertion below is on the double's one ordered call log, which records the store write
/// beside the lifecycle calls precisely so the three steps can be ordered against each other. Two
/// logs could not: the write happens on afleet's store and the other two on the wire, and "the write
/// came first" is not a claim either log can make alone.
///
/// **X9 runs through all of it.** afleet's own store is a real `FileStateStore` under a `TempTree`,
/// wired to C5's `AppFileWrites` seam, and every arm asserts that the seam saw zero paths under any
/// config home. `settings.json` is the CLI's and is never touched, on any arm.
@MainActor
final class BypassGateTests: XCTestCase {

    // MARK: - Rig

    /// A header over a real store, with the store's writes recorded in the lifecycle double's log and
    /// its bytes reported through the `AppFileWrites` seam.
    private func makeHeader(_ double: ComposerLifecycleDouble,
                            recorder: AppWriteRecorder,
                            accepted: Bool = false,
                            settings: JSONValue? = nil) async throws -> ChannelHeaderActionsModel {
        let tree = try TempTree()
        let store = try FileStateStore(baseDirectory: tree.directory("store"),
                                       configHomes: TempTree.configHomes(),
                                       fileOperations: SeamedStoreFileOperations(writes: recorder.seam))
        if accepted {
            // Staged directly on the inner store, so the arm's own log starts empty.
            try await store.write(true, namespace: .fleetKit, key: FleetKitKeys.bypassAccepted)
        }
        trees.append(tree)
        let key = HeaderRig.key()
        await double.alwaysPerform(.success(HeaderRig.replaced(key)))
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try settings ?? PickerReadbackTests.recordedBody("get_settings")))
        let header = HeaderRig.header(double, key: key,
                                      store: RecordingBypassStore(inner: store, double: double))
        await header.pickers.refresh()
        return header
    }

    /// The trees stay alive for the test's duration; a `TempTree` removes its root when it goes.
    private var trees: [TempTree] = []

    override func tearDown() async throws {
        trees = []
        try await super.tearDown()
    }

    /// The three steps of §8.6, projected out of the ordered log. Everything else — the readbacks the
    /// restart takes, the picker's own reads — is dropped, so the assertion is about the order of the
    /// three and not about how many requests the readback gate happens to make.
    private func steps(of double: ComposerLifecycleDouble) async -> [String] {
        await double.calls.compactMap { call in
            switch call {
            case .storeWrite(let namespace, let key): "store:\(namespace.rawValue)/\(key)"
            case .perform(_, .quiescentRestart): "restart"
            case .send(_, let subtype, _) where subtype == SetPermissionMode.subtype: "mode"
            default: nil
            }
        }
    }

    // MARK: - 1. Availability

    /// The header offers the mode exactly when the picker does — Task 7's gating over
    /// `get_settings`, which is the engine's own **string** comparison against `"disable"`.
    ///
    /// Read and not reimplemented: the assertion is that the two answers agree across all three
    /// arms, so a header that carried a second copy of the rule would have to keep it in step or
    /// fail here.
    func testTheHeaderOffersBypassExactlyWhenThePickerDoes() async throws {
        let arms: [(String, JSONValue, Bool)] = [
            ("the key absent", try PickerReadbackTests.settings(bypass: nil, in: .effective), true),
            ("another value", try PickerReadbackTests.settings(bypass: "allow", in: .effective), true),
            ("the string disable in effective", try PickerReadbackTests.settings(bypass: "disable", in: .effective), false),
            ("the string disable in a source", try PickerReadbackTests.settings(bypass: "disable", in: .sources), false),
        ]
        for (name, body, offered) in arms {
            let double = ComposerLifecycleDouble()
            let recorder = AppWriteRecorder()
            let header = try await makeHeader(double, recorder: recorder, settings: body)

            XCTAssertEqual(header.offersBypassMode, offered, "with \(name) the header answered the other way")
            XCTAssertEqual(header.offersBypassMode, header.pickers.modeOptions.contains(.bypassPermissions),
                           "with \(name) the header and the picker disagree about the mode being offered")
        }
    }

    /// A channel whose settings disable the mode reaches nothing when it is selected anyway.
    func testSelectingADisabledBypassModeReachesNothing() async throws {
        let double = ComposerLifecycleDouble()
        let recorder = AppWriteRecorder()
        let header = try await makeHeader(double, recorder: recorder,
                                          settings: try PickerReadbackTests.settings(bypass: "disable", in: .effective))
        let before = await double.memberSequence.count

        await header.selectBypassMode()

        let after = await double.memberSequence.count
        XCTAssertEqual(after, before, "a disabled mode reached \(after - before) further lifecycle member(s)")
        XCTAssertFalse(header.isShowingBypassDisclaimer, "a disabled mode raised the disclaimer")
        XCTAssertEqual(recorder.pathsUnderAConfigHome().count, 0, "a refused selection wrote under a config home")
    }

    // MARK: - 2. Declining

    /// **Declining leaves the mode unavailable, restarts nothing and writes nothing.**
    ///
    /// Asserted as an **empty call log** and not as "no restart": a decline that wrote the acceptance,
    /// or read the engine, or sent anything at all, fails here. The log is cleared of the rig's own
    /// readbacks first, so the zero is the decline's own.
    func testDecliningWritesNothingAndPerformsNothing() async throws {
        let double = ComposerLifecycleDouble()
        let recorder = AppWriteRecorder()
        let header = try await makeHeader(double, recorder: recorder)
        await header.selectBypassMode()
        XCTAssertTrue(header.isShowingBypassDisclaimer, "the first selection did not show the disclaimer")
        let atDisclaimer = await double.memberSequence.count

        header.declineBypassMode()

        let after = await double.memberSequence
        XCTAssertEqual(after.count, atDisclaimer,
                       "declining reached \(after.count - atDisclaimer) lifecycle member(s): "
                       + after.suffix(from: min(atDisclaimer, after.count)).joined(separator: ", "))
        // Drained first. A decline that deferred its write to a detached task is still a decline
        // that writes, and a log read on the next line would not have seen it — the first version of
        // this test read the log immediately and a mutation that wrote from a `Task` passed it.
        for _ in 0..<200 { await Task.yield() }
        let writes = await double.calls.filter { if case .storeWrite = $0 { true } else { false } }
        XCTAssertEqual(writes.count, 0, "declining wrote \(writes.count) value(s) into afleet's store")
        let keys = try await XCTUnwrap(header.store, "the arm has no store to read back").keys(in: .fleetKit)
        XCTAssertFalse(keys.contains(FleetKitKeys.bypassAccepted),
                       "declining left an acceptance among the namespace's \(keys.count) key(s)")
        XCTAssertFalse(header.isShowingBypassDisclaimer, "the disclaimer stayed up after it was declined")
        XCTAssertFalse(header.bypassAccepted, "declining recorded an acceptance")
        XCTAssertEqual(recorder.pathsUnderAConfigHome().count, 0, "declining wrote under a config home")
        XCTAssertEqual(recorder.namedTheCLIsSettings.count, 0, "declining named the CLI's settings document")
    }

    // MARK: - 3. Accepting

    /// **Accepting, in order and with nothing between**: the acceptance is written to
    /// `FleetKitKeys.bypassAccepted` in the `fleetKit` namespace, then exactly one
    /// `perform(.quiescentRestart(RestartRequest(allowBypass: true)))`, then exactly one
    /// `set_permission_mode {mode: "bypassPermissions"}`.
    ///
    /// The assertion is an **equality on the projected sequence**, which is why it discriminates: a
    /// mode switch issued before or beside the restart produces a different sequence, and a second
    /// restart or a second mode switch produces a longer one. `testTheModeIsNotIssuedWhileTheRestartIsStillInFlight`
    /// is the concurrency half — the sequence above would still be produced by an implementation that
    /// started both at once and happened to record them in this order.
    func testAcceptingWritesThenRestartsThenSetsTheModeInThatOrder() async throws {
        let double = ComposerLifecycleDouble()
        let recorder = AppWriteRecorder()
        let header = try await makeHeader(double, recorder: recorder)
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        await header.selectBypassMode()

        await header.acceptBypassMode()

        let steps = await steps(of: double)
        XCTAssertEqual(steps, ["store:fleetKit/\(FleetKitKeys.bypassAccepted)", "restart", "mode"],
                       "§8.6's three steps arrived as \(steps.count) step(s): " + steps.joined(separator: " → "))

        let restarts = await double.actions.compactMap { action -> RestartRequest? in
            if case .quiescentRestart(let request) = action { return request }
            return nil
        }
        XCTAssertEqual(restarts.count, 1, "accepting issued \(restarts.count) restart(s)")
        XCTAssertEqual(restarts.first?.allowBypass, true, "the restart did not carry the launch flag")

        let sent = await double.payload(ofFirst: SetPermissionMode.subtype)
        let payload = try XCTUnwrap(sent, "no set_permission_mode reached the wire")
        XCTAssertEqual(payload["mode"]?.stringValue, PermissionMode.bypassPermissions.rawValue,
                       "the mode switch asked for a mode other than the bypass one")
        XCTAssertTrue(header.bypassAccepted, "the acceptance was not recorded")
        XCTAssertEqual(recorder.pathsUnderAConfigHome().count, 0, "accepting wrote under a config home")
        XCTAssertEqual(recorder.namedTheCLIsSettings.count, 0, "accepting named the CLI's settings document")
    }

    /// The concurrency half of the ordering claim: while the restart is still in flight, **no** mode
    /// switch has been issued.
    ///
    /// The double holds `perform` open, so the accepting task suspends inside the restart. An
    /// implementation that issued the two in parallel — two unawaited tasks, or a `send` before the
    /// `perform` had returned — would have recorded `mode` by now, and this reads the log at exactly
    /// that moment. The sequence equality above cannot fail on such an implementation; this can.
    func testTheModeIsNotIssuedWhileTheRestartIsStillInFlight() async throws {
        let double = ComposerLifecycleDouble()
        let recorder = AppWriteRecorder()
        let header = try await makeHeader(double, recorder: recorder)
        await header.selectBypassMode()
        await double.holdPerform()

        let accepting = Task { @MainActor in await header.acceptBypassMode() }
        // Wait for the restart to be inside the double rather than for a duration.
        while await double.callersHeldInPerform == 0 { await Task.yield() }

        let held = await steps(of: double)
        XCTAssertEqual(held, ["store:fleetKit/\(FleetKitKeys.bypassAccepted)", "restart"],
                       "with the restart still in flight the log already holds \(held.count) step(s): "
                       + held.joined(separator: " → "))

        await double.releasePerform()
        await accepting.value

        let complete = await steps(of: double)
        XCTAssertEqual(complete, ["store:fleetKit/\(FleetKitKeys.bypassAccepted)", "restart", "mode"],
                       "after the restart returned the log holds \(complete.count) step(s): "
                       + complete.joined(separator: " → "))
        XCTAssertEqual(recorder.pathsUnderAConfigHome().count, 0, "the held restart wrote under a config home")
    }

    /// **A second selection while one acceptance is in flight is refused, not taken.**
    ///
    /// §8.6's order writes the acceptance *first*, so a second selection arriving across the restart
    /// finds it already recorded and takes item 4's path — the mode alone — to a process the
    /// prerequisite restart has not replaced yet. The engine reads the mode's availability off the
    /// launch line, so that request is one afleet must not make.
    ///
    /// Failed before the fix: with the restart held open, the second selection sent the mode.
    func testASecondSelectionIsRefusedWhileAnAcceptanceIsInFlight() async throws {
        let double = ComposerLifecycleDouble()
        let recorder = AppWriteRecorder()
        let header = try await makeHeader(double, recorder: recorder)
        await header.selectBypassMode()
        await double.holdPerform()

        let accepting = Task { @MainActor in await header.acceptBypassMode() }
        while await double.callersHeldInPerform == 0 { await Task.yield() }

        await header.selectBypassMode()

        let held = await steps(of: double)
        XCTAssertEqual(held, ["store:fleetKit/\(FleetKitKeys.bypassAccepted)", "restart"],
                       "a second selection across the restart left \(held.count) step(s): "
                       + held.joined(separator: " → "))

        await double.releasePerform()
        await accepting.value

        let complete = await steps(of: double)
        XCTAssertEqual(complete, ["store:fleetKit/\(FleetKitKeys.bypassAccepted)", "restart", "mode"],
                       "the acceptance and the refused selection left \(complete.count) step(s): "
                       + complete.joined(separator: " → "))
        XCTAssertEqual(recorder.pathsUnderAConfigHome().count, 0, "the refused selection wrote under a config home")
    }

    /// A restart the lifecycle refused stops the sequence there: no mode switch is issued against a
    /// process that was never launched with the flag.
    func testARefusedRestartIssuesNoModeSwitch() async throws {
        let double = ComposerLifecycleDouble()
        let recorder = AppWriteRecorder()
        let header = try await makeHeader(double, recorder: recorder)
        await header.selectBypassMode()
        await double.alwaysPerform(.failure(.busy(.restart)))

        await header.acceptBypassMode()

        let steps = await steps(of: double)
        XCTAssertEqual(steps, ["store:fleetKit/\(FleetKitKeys.bypassAccepted)", "restart"],
                       "a refused restart left \(steps.count) step(s): " + steps.joined(separator: " → "))
        XCTAssertEqual(recorder.pathsUnderAConfigHome().count, 0, "a refused restart wrote under a config home")
    }

    /// The engine's own refusal string reaches the surface. §8.6's validator has three arms and
    /// afleet renders whichever one fired rather than guessing.
    func testTheEnginesOwnRefusalStringIsWhatTheHeaderShows() async throws {
        let double = ComposerLifecycleDouble()
        let recorder = AppWriteRecorder()
        let header = try await makeHeader(double, recorder: recorder)
        await double.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await double.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        await double.stageSend(SetPermissionMode.subtype, .failure(.controlError("an invented validator refusal")))
        await header.selectBypassMode()

        await header.acceptBypassMode()

        let note = try XCTUnwrap(header.note, "a refused mode switch said nothing")
        XCTAssertEqual(note, "an invented validator refusal",
                       "the header wrote its own \(note.count)-character sentence instead of the engine's")
    }

    // MARK: - 4. The second time

    /// With the acceptance already in the store, selecting bypass sends `set_permission_mode` and
    /// performs **no** restart — and shows no disclaimer, which was answered once and for all.
    func testASecondSelectionSendsTheModeAndRestartsNothing() async throws {
        let double = ComposerLifecycleDouble()
        let recorder = AppWriteRecorder()
        let header = try await makeHeader(double, recorder: recorder, accepted: true)

        await header.selectBypassMode()

        let steps = await steps(of: double)
        XCTAssertEqual(steps, ["mode"],
                       "a second selection took \(steps.count) step(s): " + steps.joined(separator: " → "))
        XCTAssertFalse(header.isShowingBypassDisclaimer, "a second selection showed the disclaimer again")
        XCTAssertEqual(header.restartsIssued, 0, "a second selection issued \(header.restartsIssued) restart(s)")
        let writes = await double.calls.filter { if case .storeWrite = $0 { true } else { false } }
        XCTAssertEqual(writes.count, 0, "a second selection wrote \(writes.count) value(s) into the store")
    }

    // MARK: - 5. X9, across every arm

    /// Across **every** arm of the gate, C5's `AppFileWrites` seam receives zero paths under any
    /// config home — while having received a non-zero number of writes overall.
    ///
    /// The second half is what makes the first mean anything: a seam that saw nothing at all would
    /// report zero config-home paths for a gate that never wrote a byte, and this suite would then be
    /// proving nothing. One recorder across all four arms, so the number is the gate's whole write
    /// surface.
    func testEveryArmWritesOnlyIntoAfleetsOwnStore() async throws {
        let recorder = AppWriteRecorder()

        // Declining.
        let declining = ComposerLifecycleDouble()
        let declined = try await makeHeader(declining, recorder: recorder)
        await declined.selectBypassMode()
        declined.declineBypassMode()

        // Accepting.
        let accepting = ComposerLifecycleDouble()
        let accepted = try await makeHeader(accepting, recorder: recorder)
        await accepting.stageSend("list_models", .success(try PickerReadbackTests.recordedBody("list_models")))
        await accepting.stageSend("get_settings", .success(try PickerReadbackTests.recordedBody("get_settings")))
        await accepted.selectBypassMode()
        await accepted.acceptBypassMode()

        // The second time.
        let again = ComposerLifecycleDouble()
        let second = try await makeHeader(again, recorder: recorder, accepted: true)
        await second.selectBypassMode()

        // A settings body that disables the mode outright.
        let disabled = ComposerLifecycleDouble()
        let refused = try await makeHeader(disabled, recorder: recorder,
                                           settings: try PickerReadbackTests.settings(bypass: "disable", in: .effective))
        await refused.selectBypassMode()

        let underAHome = recorder.pathsUnderAConfigHome()
        XCTAssertEqual(underAHome.count, 0,
                       "\(underAHome.count) of the gate's \(recorder.paths.count) write(s) landed under a config home")
        XCTAssertGreaterThan(recorder.paths.count, 0,
                            "the write seam saw \(recorder.paths.count) path(s), so the config-home count proves nothing")
        XCTAssertEqual(recorder.namedTheCLIsSettings.count, 0,
                       "\(recorder.namedTheCLIsSettings.count) write(s) named the CLI's own settings document")

        // And the proof the comparison discriminates, taken from the same recording rather than from
        // a second run: held against the store's own root as if it were a config home, every write is
        // reported.
        let root = try XCTUnwrap(recorder.paths.first?.deletingLastPathComponent(), "no write to hold up")
        let narrowed = recorder.pathsUnderAConfigHome([root])
        XCTAssertGreaterThan(narrowed.count, 0, "a home the writes are known to lie under explained none of them")
    }
}
