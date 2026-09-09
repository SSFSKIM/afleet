import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// Gate **G4**: the channel header reads back and never remembers (child spec §10).
///
/// Every engine answer here is **replayed from a committed fixture** — `control-shapes` and
/// `exit-plan-mode` for `get_settings` and the handshake, `zero-cost` for `get_context_usage`, which
/// is the only recording that carries that subtype — and every identifier the tests invent is
/// visibly nobody's. No assertion prints a path, a title or a value read out of a fixture: the
/// comparisons below are booleans and counts with messages written for them (§11).
@MainActor
final class HeaderReadoutTests: XCTestCase {

    // MARK: - G4's discriminating clause

    /// The readout is the engine's answer, not the last thing this app asked for, and not the
    /// answer before it either.
    ///
    /// Three modes are in play and they are all different: the first readback says one thing, a
    /// click asks for a second, and the second readback says a third. A header that echoed the click
    /// shows the click; a header that remembered its first answer shows the first. Only a header
    /// that displays the newest readback passes.
    func testTheReadoutIsTheAnswerAndNotTheRequest() async throws {
        let rig = try await Rig()
        await rig.double.stageSend("get_settings", .success(try Self.answer("control-shapes", to: "get_settings")))
        await rig.double.stageEngineReport(handshake: try Self.handshake("exit-plan-mode"), systemInitFrom: nil)

        await rig.model.refreshReadbacks()
        XCTAssertTrue(rig.model.readout.mode == .plan,
                      "the first readback did not reach the readout, so nothing that follows is a change")

        // The click: a mode this app asked the engine for, through the same lifecycle the readout
        // reads. It is recorded on the double's log, which is how the assertion below knows the
        // header had something to echo.
        let click = AnyControlRequest(subtype: "set_permission_mode", payload: .object(["mode": .string("acceptEdits")]))
        _ = try await rig.double.send(click, on: rig.key)

        // And the engine's answer, which agrees with neither.
        await rig.double.stageEngineReport(handshake: try Self.handshake("control-shapes"), systemInitFrom: nil)
        await rig.model.refreshReadbacks()

        XCTAssertTrue(rig.model.readout.mode == .default,
                      "the readout does not carry the mode the second readback named")
        XCTAssertFalse(rig.model.readout.mode == .acceptEdits,
                       "the readout carries the mode that was asked for rather than the one read back")
        XCTAssertFalse(rig.model.readout.mode == .plan,
                       "the readout kept its first answer instead of the newest one")
        XCTAssertTrue(rig.model.readout.model != nil,
                      "the answer's applied model did not reach the readout")

        let sent = await rig.double.sentSubtypes
        XCTAssertTrue(sent.contains("set_permission_mode"),
                      "the click never went out, so the readback had nothing to disagree with")
        XCTAssertEqual(sent.filter { $0 == "get_settings" }.count, 2,
                       "\(sent.filter { $0 == "get_settings" }.count) settings readback(s) were taken, not 2")
    }

    // MARK: - G4: the mode follows the process, not its launch

    /// The permission mode readback **follows `system/status`** and falls back to the handshake for
    /// the value the header opens with (child spec §10, corrected 2026-09-09).
    ///
    /// The three moves are the whole correction. The handshake gives the launch mode, which is what
    /// the header shows while nothing has changed. The recorded status frame — replayed from
    /// `exit-plan-mode`, the one fixture where a mode actually changes — names a different one, and
    /// the readout moves to it. Then a turn ends and the settings readback is taken again over the
    /// **same retained handshake**, and the readout does *not* fall back: a handshake is minted once
    /// per process, so a header that let it win would show the true mode for a few seconds and the
    /// launch mode for ever after.
    ///
    /// Discriminating: against the handshake-only readback this leaf shipped at Task 5, the second
    /// assertion fails — the frame passes and the readout never moves. A stale readback is not a
    /// smaller version of a correct one; it looks authoritative, which is the shape G4 exists to
    /// catch.
    func testTheModeFollowsAStatusFrameAndNotTheRetainedHandshake() async throws {
        let rig = try await Rig()
        let double = rig.double
        let key = rig.key
        await double.stageSend("get_settings", .success(try Self.answer("control-shapes", to: "get_settings")))
        await double.stageEngineReport(handshake: try Self.handshake("exit-plan-mode"), systemInitFrom: nil)

        rig.model.startReadbacks()
        // Waited on the *subscription*: the frame below is pushed to whoever is listening at the
        // time, so a test that enqueued it first would assert on a frame nothing received.
        let attached = await LaunchFixtures.waitAsync { await double.memberSequence.contains("events") }
        XCTAssertTrue(attached, "the header never subscribed, so no frame could reach it")
        let opened = await LaunchFixtures.waitAsync { @MainActor in rig.model.readout.mode == .plan }
        XCTAssertTrue(opened, "the handshake's mode never reached the readout, so nothing that follows is a change")

        let statuses = try Self.modeStatuses("exit-plan-mode")
        XCTAssertEqual(statuses.count, 1,
                       "the recording carries \(statuses.count) status frame(s) reporting a mode, not the 1 this replays")
        for status in statuses { double.enqueue(status, to: key) }

        let moved = await LaunchFixtures.waitAsync { @MainActor in rig.model.readout.mode == .acceptEdits }
        XCTAssertTrue(moved, "the readout did not follow the mode the recorded status frame reported")

        // The turn ends, the settings readback is taken again, and the retained handshake is still
        // the launch one. The live value stands.
        let results = try Self.results("plain-two-turn")
        XCTAssertGreaterThan(results.count, 0, "the fixture carried no result frame, so no readback is re-taken")
        for result in results { double.enqueue(result, to: key) }
        let polled = await LaunchFixtures.waitAsync { await Self.polls(double, of: "get_settings") >= 1 + results.count }
        let taken = await Self.polls(double, of: "get_settings")
        XCTAssertTrue(polled, "\(taken) settings readback(s) were taken, so the turns did not land")
        XCTAssertTrue(rig.model.readout.mode == .acceptEdits,
                      "the retained handshake folded the launch mode back over the live one")

        rig.model.close()
    }

    // MARK: - The subscription comes first (round 1, scalpel-5 #1)

    /// **The header subscribes before it takes its opening readback**, so a mode reported while that
    /// readback is in flight is not lost.
    ///
    /// `events(of:)` registers a future-only fan-out — the fleet's own contract, and the reason
    /// `engineReports(of:)` exists at all. The opening `get_settings` is a round trip to a process
    /// that may be mid-turn, and every frame the engine sends in that window goes to whoever is
    /// listening at the time. Subscribing after it therefore drops them, and the one frame that
    /// matters here is the only carrier of a mode change: the header would then show the launch mode
    /// until the next one arrives, which on a quiet channel is never.
    ///
    /// The readback is **parked on the wire** rather than merely slow, which is what makes the
    /// window a place and not a race. Discriminating twice over: the subscription is asserted to
    /// exist while the readback is still in flight, and the mode reported in that window is asserted
    /// to arrive.
    func testTheSubscriptionIsTakenBeforeTheOpeningReadback() async throws {
        let rig = try await Rig()
        let double = rig.double
        let key = rig.key
        await double.stageSend("get_settings", .success(try Self.answer("control-shapes", to: "get_settings")))
        await double.stageEngineReport(handshake: try Self.handshake("exit-plan-mode"), systemInitFrom: nil)
        await double.holdSend()

        rig.model.startReadbacks()
        let attached = await LaunchFixtures.waitAsync(upTo: .seconds(5)) {
            await double.memberSequence.contains("events")
        }
        XCTAssertTrue(attached, "the header had not subscribed while its opening readback was still in flight")

        // The frame the engine sends inside that window.
        let statuses = try Self.modeStatuses("exit-plan-mode")
        XCTAssertEqual(statuses.count, 1,
                       "the recording carries \(statuses.count) status frame(s) reporting a mode, not the 1 this replays")
        for status in statuses { double.enqueue(status, to: key) }
        await double.releaseSend()

        let moved = await LaunchFixtures.waitAsync(upTo: .seconds(5)) { @MainActor in
            rig.model.readout.mode == .acceptEdits
        }
        XCTAssertTrue(moved, "the mode reported while the opening readback was in flight never reached the readout")

        let members = await double.memberSequence
        let subscribed = try XCTUnwrap(members.firstIndex(of: "events"), "the header never subscribed at all")
        let asked = try XCTUnwrap(members.firstIndex(of: "send"), "the header never took a readback at all")
        XCTAssertLessThan(subscribed, asked, "the header asked the engine before it subscribed")

        rig.model.close()
    }

    // MARK: - A restart replaces the process (round 1, scalpel-5 #2)

    /// **A new process resets the mode's precedence**, so the replacement's handshake is read.
    ///
    /// A live `system/status` mode outranks the retained handshake for the life of *that* process,
    /// which is the correction Task 8 made. A restart replaces the process while the channel model,
    /// its readout and its subscription all survive: the fleet mints a fresh handshake, the old
    /// live mode belongs to a process that no longer exists, and a precedence that never reset
    /// rejected the new handshake for ever. The header then shows a mode nothing is running.
    ///
    /// Discriminating: against a latched precedence the readout keeps the first process's mode and
    /// the last assertion fails. The floor is the middle assertion — the live mode really did
    /// outrank the handshake first, so this is a reset and not a header that never followed a frame.
    func testARestartResetsTheModePrecedence() async throws {
        let rig = try await Rig()
        let double = rig.double
        let key = rig.key
        await double.stageSend("get_settings", .success(try Self.answer("control-shapes", to: "get_settings")))
        await double.stageEngineReport(handshake: try Self.handshake("exit-plan-mode"), systemInitFrom: nil)

        rig.model.startReadbacks()
        let attached = await LaunchFixtures.waitAsync { await double.memberSequence.contains("events") }
        XCTAssertTrue(attached, "the header never subscribed, so no frame could reach it")
        let opened = await LaunchFixtures.waitAsync { @MainActor in rig.model.readout.mode == .plan }
        XCTAssertTrue(opened, "the first process's handshake never reached the readout")

        for status in try Self.modeStatuses("exit-plan-mode") { double.enqueue(status, to: key) }
        let moved = await LaunchFixtures.waitAsync { @MainActor in rig.model.readout.mode == .acceptEdits }
        XCTAssertTrue(moved, "the readout did not follow the first process's status frame")

        // The restart: a second epoch, and the handshake the fleet retains for it.
        let second = ProcessEpoch.first.next()
        await double.stageEngineReport(handshake: try Self.handshake("control-shapes"), systemInitFrom: nil)
        double.enqueue(try Self.handshake("control-shapes", epoch: second), to: key)
        let results = try Self.results("plain-two-turn", epoch: second)
        XCTAssertGreaterThan(results.count, 0, "the fixture carried no result frame, so no readback is re-taken")
        for result in results { double.enqueue(result, to: key) }

        let followed = await LaunchFixtures.waitAsync { @MainActor in rig.model.readout.mode == .default }
        XCTAssertTrue(followed,
                      "the readout kept the mode a process that has been replaced reported, so the precedence never reset")

        rig.model.close()
    }

    // MARK: - An idle replacement is read (round 2, scalpel-5 #1)

    /// **A replacement process that says nothing has its mode read anyway.**
    ///
    /// Clearing the live precedence on a new epoch is only half of a restart: the mode standing in
    /// the readout is still the one the *replaced* process reported, and nothing re-reads it. A
    /// handshake is not a turn end, so the one thing that re-takes a readback never fires, and an
    /// idle replacement — one that runs no turn after it comes up — leaves the header naming a mode
    /// nothing is running. So an epoch increase re-takes the readback itself.
    ///
    /// Discriminating against the wave-C fix, which reset the precedence and stopped there: the last
    /// assertion fails, because no `result` frame follows the restart here. The existing restart test
    /// feeds the replacement's turns and so cannot tell the two apart. The count is the second half —
    /// two readbacks, the opening one and the one the epoch took, and no turn ended in between.
    func testARestartWithNoTurnEndStillReadsTheReplacementsMode() async throws {
        let rig = try await Rig()
        let double = rig.double
        let key = rig.key
        await double.stageSend("get_settings", .success(try Self.answer("control-shapes", to: "get_settings")))
        await double.stageEngineReport(handshake: try Self.handshake("exit-plan-mode"), systemInitFrom: nil)

        rig.model.startReadbacks()
        let attached = await LaunchFixtures.waitAsync { await double.memberSequence.contains("events") }
        XCTAssertTrue(attached, "the header never subscribed, so no frame could reach it")
        let opened = await LaunchFixtures.waitAsync { @MainActor in rig.model.readout.mode == .plan }
        XCTAssertTrue(opened, "the first process's handshake never reached the readout")

        for status in try Self.modeStatuses("exit-plan-mode") { double.enqueue(status, to: key) }
        let moved = await LaunchFixtures.waitAsync { @MainActor in rig.model.readout.mode == .acceptEdits }
        XCTAssertTrue(moved, "the readout did not follow the first process's status frame")

        // The restart, and nothing after it: the fleet retains the replacement's handshake, one
        // event carries the new epoch, and no turn ends on the new process.
        await double.stageEngineReport(handshake: try Self.handshake("control-shapes"), systemInitFrom: nil)
        double.enqueue(try Self.handshake("control-shapes", epoch: ProcessEpoch.first.next()), to: key)

        let followed = await LaunchFixtures.waitAsync { @MainActor in rig.model.readout.mode == .default }
        XCTAssertTrue(followed,
                      "an idle replacement left the readout showing the mode the replaced process reported")

        let taken = await Self.polls(double, of: "get_settings")
        XCTAssertEqual(taken, 2,
                       "\(taken) settings readback(s) were taken, not the opening one and the one the new epoch took")

        rig.model.close()
    }

    // MARK: - The rendering preferences (round 1, scalpel-4 #7)

    /// **`get_settings`' two rendering preferences reach the render context.**
    ///
    /// Parity §41.8 and §41.17 name `autoScrollEnabled` and `syntaxHighlightingDisabled`, and this
    /// leaf's own plan says both are read from the settings readback. The context declared them and
    /// the readback dropped them, so the controller was handed `true` for both whatever the reader
    /// had set — and `syntaxHighlightingDisabled` is an accessibility choice, not a debug switch.
    ///
    /// The answer is **invented rather than replayed**: the committed recordings' settings bodies
    /// are redacted down to their keys because they are somebody's own preferences (§11), so what a
    /// fixture could contribute here is the key spelling, which the parity map already states.
    ///
    /// Both arms: the defaults are what the engine's own renderer does, and the answer moves them.
    func testTheRenderingPreferencesReachTheRenderContext() async throws {
        let rig = try await Rig()
        await rig.double.stageSend("get_settings",
                                   .success(Self.settingsAnswer(autoScroll: false, highlightingDisabled: true)))
        let app = AppModel(registry: RowRegistry())

        let before = TimelineListView(model: rig.model).context(in: app)
        XCTAssertTrue(before.autoScrollEnabled && before.syntaxHighlightingEnabled,
                      "the preferences do not open as the engine's own defaults, so the change below proves nothing")

        await rig.model.refreshReadbacks()
        let after = TimelineListView(model: rig.model).context(in: app)
        XCTAssertFalse(after.autoScrollEnabled, "the answer's auto-scroll preference never reached the render context")
        XCTAssertFalse(after.syntaxHighlightingEnabled,
                       "the answer's syntax-highlighting preference never reached the render context")
    }

    /// A `get_settings` body carrying the two preferences, invented throughout (§11). The shape is
    /// the recorded one — `applied` for what the engine resolved, `effective` for the merged
    /// settings files, which is where both preference keys live.
    static func settingsAnswer(autoScroll: Bool, highlightingDisabled: Bool) -> JSONValue {
        .object(["applied": .object(["model": .string("an-invented-model"), "effort": .null]),
                 "effective": .object(["autoScrollEnabled": .bool(autoScroll),
                                       "syntaxHighlightingDisabled": .bool(highlightingDisabled)])])
    }

    // MARK: - The meter, polled because nothing pushes it

    /// One `get_context_usage` per `result` frame, plus the one the header takes when it opens, and
    /// none on a timer.
    ///
    /// The quiet stretch at the end is the discriminating half: a poller on an interval keeps
    /// counting while nothing happens, and this asserts the count does not move.
    func testTheContextMeterPollsAfterAResult() async throws {
        let rig = try await Rig()
        let double = rig.double
        let key = rig.key
        await double.stageSend("get_settings", .success(try Self.answer("control-shapes", to: "get_settings")))
        await double.stageSend("get_context_usage", .success(try Self.answer("zero-cost", to: "get_context_usage")))
        await double.stageEngineReport(handshake: try Self.handshake("control-shapes"), systemInitFrom: nil)

        rig.model.startReadbacks()
        // Waited on the *subscription*, not on the readback alone: the frames below are pushed to
        // whoever is listening at the time, so a test that enqueued them before the header attached
        // would be asserting on frames nothing received. And then on the opening reading itself,
        // because the subscription is taken **first** (scalpel-5 #1): the two are no longer one
        // event, and reading the count at the subscription reads it before the readback lands.
        let attached = await LaunchFixtures.waitAsync { await double.memberSequence.contains("events") }
        XCTAssertTrue(attached, "the header never subscribed, so no turn could reach it")
        let took = await LaunchFixtures.waitAsync { await Self.polls(double, of: "get_context_usage") >= 1 }
        let onOpen = await Self.polls(double, of: "get_context_usage")
        XCTAssertTrue(took, "the header took \(onOpen) context reading(s) on open, not 1")
        XCTAssertEqual(onOpen, 1, "the header took \(onOpen) context reading(s) on open, not 1")

        let results = try Self.results("plain-two-turn")
        XCTAssertEqual(results.count, 2,
                       "the fixture carried \(results.count) result frame(s), not the 2 this test polls on")
        for result in results { double.enqueue(result, to: key) }

        let polled = await LaunchFixtures.waitAsync { await Self.polls(double, of: "get_context_usage") == 3 }
        let afterTurns = await Self.polls(double, of: "get_context_usage")
        XCTAssertTrue(polled,
                      "\(afterTurns) context reading(s) were taken, not the 3 that two turns and one open make")

        // Nothing pushes this readback and no timer is armed: a full second of quiet moves nothing.
        try await Task.sleep(for: .seconds(1))
        let quiet = await Self.polls(double, of: "get_context_usage")
        XCTAssertEqual(quiet, 3,
                       "\(quiet) context reading(s) after a second of quiet, so something is polling on a timer")

        let usage = try XCTUnwrap(rig.model.readout.context, "the replayed answer produced no context meter")
        XCTAssertGreaterThan(usage.maxTokens, 0, "the meter's window came back as \(usage.maxTokens) tokens")
        XCTAssertGreaterThan(usage.percentage, 0, "the meter reads \(usage.percentage) percent of a window that is not empty")
        XCTAssertGreaterThan(usage.categories.count, 0,
                             "the answer's breakdown produced \(usage.categories.count) categories")
        XCTAssertTrue(usage.isAutoCompactEnabled, "the recorded answer has auto-compaction on and the meter lost it")

        rig.model.close()
    }

    // MARK: - Contract Y5, asserted mechanically

    /// No file under `App/Timeline/` constructs a ClaudeWire request spec.
    ///
    /// Y5 is invisible at the call site: `send` takes an `AnyControlRequest` and both spellings of
    /// one compile. The only way this stays true as the leaf grows is a check over the text.
    func testNoClaudeWireSpecIsConstructed() throws {
        let root = FixtureRunner.repositoryRoot.appending(path: "App/Timeline")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
                                       "App/Timeline could not be walked")
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for spec in ["GetSettings(", "GetContextUsage("] where text.contains(spec) {
                // The file's name and never its path (§11).
                offenders.append("\(url.lastPathComponent):\(spec)")
            }
        }
        XCTAssertGreaterThan(scanned, 0, "the scan read no Swift files, so finding nothing proves nothing")
        XCTAssertTrue(offenders.isEmpty, "\(offenders.count) ClaudeWire spec construction(s) under App/Timeline: \(offenders)")
    }

    // MARK: - X5's refusal rule

    /// A `LifecycleError.busy` refusal leaves the last readback on screen and is not retried.
    func testABusyRefusalLeavesTheLastReadbackStanding() async throws {
        let rig = try await Rig()
        await rig.double.stageSend("get_settings", .success(try Self.answer("control-shapes", to: "get_settings")))
        await rig.double.stageSend("get_context_usage", .success(try Self.answer("zero-cost", to: "get_context_usage")))
        await rig.double.stageEngineReport(handshake: try Self.handshake("control-shapes"), systemInitFrom: nil)

        await rig.model.refreshReadbacks()
        XCTAssertFalse(rig.model.readout.isEngineSilent, "the first readback left the header with nothing on it")
        let before = rig.model.readout

        await rig.double.stageSendRefusal("get_settings", LifecycleError.busy(.restart))
        await rig.double.stageSendRefusal("get_context_usage", LifecycleError.busy(.restart))
        await rig.model.refreshReadbacks()

        XCTAssertTrue(rig.model.readout == before, "the refusal changed the readout instead of leaving it standing")
        let settings = await Self.polls(rig.double, of: "get_settings")
        let context = await Self.polls(rig.double, of: "get_context_usage")
        XCTAssertEqual(settings, 2, "\(settings) settings readback(s) were issued, so the refusal was retried")
        XCTAssertEqual(context, 2, "\(context) context readback(s) were issued, so the refusal was retried")
    }

    // MARK: - A channel with no process

    /// An archived channel asks for nothing, and carries the branch alone.
    func testAnArchivedChannelIssuesNoControlRequest() async throws {
        let rig = try await Rig(origin: .archived, live: false)
        rig.model.startReadbacks()
        await rig.model.refreshReadbacks()

        let sent = await rig.double.sentSubtypes
        XCTAssertTrue(sent.isEmpty, "\(sent.count) control request(s) went out for a channel with no process")
        XCTAssertTrue(rig.model.readout.isEngineSilent, "an archived channel's readout carries an engine value")
        XCTAssertEqual(rig.model.readout.branch, Rig.branch, "the archived channel's readout lost its branch")
    }

    // MARK: - The branch

    /// The branch is the index entry's, carried through the row and never asked for.
    func testTheBranchComesFromTheIndex() async throws {
        let rig = try await Rig()
        XCTAssertEqual(rig.model.readout.branch, Rig.branch, "the readout does not carry the index entry's branch")

        // It follows the entry rather than being latched: a rebase under a selected channel moves it.
        let moved = Rig.entry(rig.key, branch: "invented-branch-two")
        rig.model.adopt(ChannelHeader(row: Rig.row(rig.key, entry: moved, origin: .owned(.ready))))
        XCTAssertEqual(rig.model.readout.branch, "invented-branch-two", "the readout did not follow the entry's branch")

        let sent = await rig.double.sentSubtypes
        XCTAssertTrue(sent.isEmpty, "\(sent.count) control request(s) went out for a readback the index already holds")
    }

    // MARK: - The rig

    /// One channel over a recording lifecycle double, with no workspace: nothing here opens a
    /// transcript, so nothing here reads or writes any config home (X9).
    @MainActor
    struct Rig {

        static let branch = "invented-branch-one"

        let key: ChannelKey
        let double: ComposerLifecycleDouble
        let model: ChannelTimelineModel

        init(origin: ChannelOrigin = .owned(.ready), live: Bool = true) async throws {
            key = ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                             session: SidebarFixtures.session("c"))
            double = ComposerLifecycleDouble()
            // The fleet owns a supervisor for a live channel, which is what makes `events(of:)`
            // answer with a stream and `engineReports(of:)` with the retained handshake.
            if live { await double.openEvents(of: key) }
            model = ChannelTimelineModel(key: key, workspace: nil, lifecycle: double)
            model.adopt(ChannelHeader(row: Self.row(key, entry: Self.entry(key, branch: Self.branch), origin: origin)))
        }

        /// An index entry with an invented branch, which is where a branch comes from.
        static func entry(_ key: ChannelKey, branch: String) -> IndexEntry {
            IndexEntry(sessionID: key.session,
                       path: URL(fileURLWithPath: "/invented/config-home/projects/invented/transcript.jsonl"),
                       slug: "invented", cwd: "/invented/project", title: "invented title",
                       titleSource: .firstPrompt, preview: "invented preview", gitBranch: branch,
                       mtime: Date(timeIntervalSince1970: 0), size: 1)
        }

        /// The row the column hands the model, built from the entry the way `ChannelRegistrar`
        /// builds one: the branch is the entry's field and never a literal written here.
        ///
        /// **Presence is pinned.** C4 recomputes it in `ChannelSupervisor.publish()`, so a row that
        /// inherited whatever a double happened to publish would be asserting on somebody else's
        /// default.
        static func row(_ key: ChannelKey, entry: IndexEntry, origin: ChannelOrigin) -> ChannelRow {
            var row = ChannelRow(key: key, title: entry.title, titleSource: entry.titleSource,
                                 preview: entry.preview, cwd: entry.cwd.map { URL(fileURLWithPath: $0) },
                                 gitBranch: entry.gitBranch, agentName: entry.agentName, mtime: entry.mtime,
                                 isRecent: true, mode: .ownedCandidate, decidingRule: "invented-rule",
                                 isProvisional: false)
            var state = SidebarFixtures.state(key, origin: origin)
            state.presence = .idle
            row.state = state
            return row
        }
    }

    /// How many readbacks of one subtype the double has been asked for. A count, never a value.
    static func polls(_ double: ComposerLifecycleDouble, of subtype: String) async -> Int {
        await double.sentSubtypes.filter { $0 == subtype }.count
    }

    // MARK: - Reading the recordings

    /// The body the engine answered one control request with, matched by the request id the
    /// recording carries. Answers are matched to their ask rather than guessed at by shape.
    static func answer(_ fixture: String, to subtype: String) throws -> JSONValue {
        let (asked, answers) = try exchange(fixture)
        let id = try XCTUnwrap(asked[subtype], "fixture \(fixture) carries no control request of subtype \(subtype)")
        return try XCTUnwrap(answers[id], "fixture \(fixture) carries no answer to its \(subtype) request")
    }

    /// The channel's handshake, as the fleet retains it: the recorded `initialize` answer, wrapped
    /// the way `ClaudeProcess` wraps one.
    static func handshake(_ fixture: String, epoch: ProcessEpoch = .first) throws -> WireEvent {
        let raw = try answer(fixture, to: "initialize")
        return .handshakeCompleted(Handshake(initialize: InitializeResponse(raw: raw), pending: []), epoch)
    }

    /// The fixture's `system/status` frames that **report a permission mode**, as events.
    ///
    /// Almost none do: across the corpus's 40 status frames exactly one carries a value, in the one
    /// recording where a mode actually changes. Hence the filter, rather than taking whichever
    /// status frame comes first.
    static func modeStatuses(_ fixture: String) throws -> [WireEvent] {
        try FixtureRunner.frames(fixture).compactMap { frame in
            guard case .system(.status(let status)) = frame, status.fields.permissionMode != nil else { return nil }
            return .frame(frame, .first)
        }
    }

    /// The fixture's `result` frames, as the events a channel's consumers see.
    static func results(_ fixture: String, epoch: ProcessEpoch = .first) throws -> [WireEvent] {
        try FixtureRunner.frames(fixture).compactMap { frame in
            if case .result = frame { return .frame(frame, epoch) }
            return nil
        }
    }

    /// Every control request's subtype-to-id, and every answer by the id it answers. One pass, both
    /// directions of the recording: an ask is written into the engine and its answer comes back out.
    private static func exchange(_ fixture: String) throws -> (asked: [String: String], answers: [String: JSONValue]) {
        let url = FixtureRunner.directory(fixture).appending(path: "frames.ndjson")
        let text = try String(contentsOf: url, encoding: .utf8)
        var asked: [String: String] = [:]
        var answers: [String: JSONValue] = [:]
        for line in text.split(separator: "\n") {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            guard let frame = value["frame"] else { continue }
            switch frame["type"]?.stringValue {
            case "control_request":
                if let subtype = frame["request"]?["subtype"]?.stringValue,
                   let id = frame["request_id"]?.stringValue { asked[subtype] = id }
            case "control_response":
                if let id = frame["response"]?["request_id"]?.stringValue,
                   let body = frame["response"]?["response"] { answers[id] = body }
            default: continue
            }
        }
        return (asked, answers)
    }
}
