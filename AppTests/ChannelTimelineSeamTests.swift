import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.1 Task 0: the two seams a channel's timeline model owns, and tracker 66.
///
/// **The channel's wire fold is not here.** An earlier revision of this suite drove a `WireReducer`
/// of the app's own over a second `events(of:)` subscription; the architect moved that fold into
/// `StreamIngestion`, where one channel has one of them, so what the app owns is the raise site for
/// host signals and the republishing of what the fold produced.
///
/// **The corrective landed, so nothing here asserts against a double.** An earlier revision of the
/// two signal tests set a `model.ingestionSignal` closure and counted calls on it; that property is
/// gone, because `StreamIngestion.signal(_:)` exists and a seam in front of it would be indirection
/// with a nil hazard (tracker 129). What each test asserts now is the change the app can *see* in
/// `model.timeline` — a decision leaving `.pending`, a banner the fold raised, an overlay that
/// filled, a preview that was dropped — which is the behaviour the leaves downstream depend on and
/// not the fact that a closure ran.
///
/// Every config home here is a scratch tree under `TempTree`, which refuses to build inside any
/// config home; the fixture transcript is copied into it at run time. No assertion prints a path, a
/// session id or an engine byte (§11).
@MainActor
final class ChannelTimelineSeamTests: XCTestCase {

    // MARK: - One subscription

    /// The model takes **exactly one** `events(of:)` subscription for a channel, and it is not the
    /// Activity pump's.
    ///
    /// One channel, one wire fold, and it is `StreamIngestion`'s: the ingestion consumes the raw
    /// stream and holds the reducer. `LifecycleAPI.events(of:)` hands back a fresh unbounded fan-out
    /// per call, so a second consumer is *legal* — which is exactly why the count has to be asserted
    /// rather than assumed. A second subscription would be a second fold's worth of every frame in
    /// the channel, for a fold that no longer exists on this side.
    func testTheModelTakesOneEventSubscription() async throws {
        let rig = try await SeamRig(fixture: "background-shell")
        let key = rig.key

        // Task 6's pump, taking the app's one folded subscription, exactly as it does at launch.
        let pump = ChannelEventPump(key: key) { _, _ in }
        let taken = await rig.lifecycle.events(of: key)
        pump.start(try XCTUnwrap(taken, "the double answered no event stream for an owned channel"))
        let before = await rig.lifecycle.eventSubscriptions
        XCTAssertEqual(before.count, 1, "the pump's own subscription was not recorded: \(before.count) call(s)")

        await rig.open()

        let after = await rig.lifecycle.eventSubscriptions
        XCTAssertEqual(after.count - before.count, 1,
                       "the model took \(after.count - before.count) event subscription(s), not 1")
        XCTAssertEqual(after.filter { $0 == key }.count, after.count,
                       "\(after.filter { $0 != key }.count) subscription(s) named another channel")
        let fanOuts = await rig.lifecycle.fanOutCount(of: key)
        XCTAssertEqual(fanOuts, 2, "\(fanOuts) fan-out(s) are live on the channel, not 2")

        pump.stop()
        await rig.finish()
    }

    // MARK: - The host-signal seam

    /// An answered decision leaves `.pending`, which is the whole reason the raise site exists.
    ///
    /// `HostSignal` is modelled by C3 and was constructed nowhere in the tree until this leaf's seam
    /// commit: the fold has always known how to move a decision out of `.pending`, and nothing ever
    /// raised one. `ChannelTimelineModel.signal(_:)` is where they are raised, and C6.3 calls it by
    /// that name after a successful `perform(.answer)`.
    ///
    /// **The request is built and pushed rather than replayed from the fixture's own stream**, and
    /// that is deliberate. `permission-allow` opens three `mcp_message` requests that the inbound
    /// policy answers itself before its `can_use_tool` ask ever arrives, so a wait on "a decision
    /// exists" returns while every decision present is one the host never has to answer. Pushing the
    /// one request under test makes the condition exact: **a pending decision**, by id.
    func testAnAnsweredDecisionLeavesPending() async throws {
        let rig = try await SeamRig(fixture: "permission-allow")
        await rig.open()

        let id = RequestID(rawValue: "req_invented_c61_0001")
        let ask = try FixtureRunner.request("permission-allow", subtype: "can_use_tool", id: id.rawValue)
        guard case .request = FixtureRunner.event(for: ask) else {
            return XCTFail("the inbound policy does not surface a can_use_tool ask, so nothing here would be pending")
        }
        await rig.lifecycle.push(.request(ask), to: rig.key)

        let pending = await rig.settle { $0.timeline.overlay.decisions[ask.id]?.state == .pending }
        XCTAssertTrue(pending, "the pushed ask never became a pending decision the host has to answer")

        await rig.model.signal(.decisionAnswered(ask.id, outcome: .allowed))

        let answered = await rig.settle {
            if case .answered = $0.timeline.overlay.decisions[ask.id]?.state { return true }
            return false
        }
        XCTAssertTrue(answered, "an answered decision is still not out of .pending")
        XCTAssertEqual(rig.model.timeline.overlay.decisions[ask.id]?.state, .answered(outcome: "allowed"),
                       "the decision settled on an outcome the signal did not carry")
        await rig.finish()
    }

    /// A relocation reaches the fold, and a repeat of the same move does not.
    ///
    /// `relocated` is the one signal C6.1 raises itself, because it owns the path the index reports.
    /// C3's `signal(.relocated:)` performs the path rebind itself — it calls `relocated(mainPath:)`
    /// and says so at its own definition — so the model raises the signal and nothing else; raising
    /// it *and* calling the rebind ran the rebind twice (tracker 130).
    ///
    /// **The witness is a banner, and it has to be.** A resolvable move changes the fold's `slug` and
    /// its agent tree, both of which are the reducer's own state behind an actor the model holds
    /// privately; there is no consequence of a *successful* relocation this side can read. An
    /// unresolvable one raises a `.compatibility` banner, which lands in `timeline.overlay.banners`
    /// and is visible here — so a path that does not name this session's main transcript is what
    /// proves the signal arrived at all. C3's own suite asserts the rebind.
    func testARelocationReachesTheFold() async throws {
        let rig = try await SeamRig(fixture: "background-shell")
        await rig.open()

        let before = rig.model.timeline.overlay.banners.count
        XCTAssertEqual(before, 0, "the channel raised \(before) banner(s) before the move")

        // Under the scratch home but not this session's main transcript, so the fold refuses it and
        // says so. A resolvable path would be reduced silently and prove nothing.
        let elsewhere = rig.transcriptDestination
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "invented-not-this-session", directoryHint: .isDirectory)
            .appending(path: "00000000-0000-4000-8000-0000000000ff.jsonl")
        await rig.model.transcriptMoved(to: elsewhere)

        let raised = await rig.settle { $0.timeline.overlay.banners.count == 1 }
        XCTAssertTrue(raised, "a relocation raised \(rig.model.timeline.overlay.banners.count) banner(s), not 1")
        XCTAssertEqual(rig.model.timeline.overlay.banners.first?.kind, .compatibility,
                       "the fold raised a banner of a kind a refused relocation does not produce")

        // Idempotent: the coordinator forwards the entry's path on every index update, and only a
        // path that actually moved is worth raising.
        await rig.model.transcriptMoved(to: elsewhere)
        let again = rig.model.timeline.overlay.banners.count
        XCTAssertEqual(again, 1, "a repeated relocation to the same path left \(again) banner(s)")
        await rig.finish()
    }

    /// A card answered **from Activity** moves the channel's decision out of `.pending`.
    ///
    /// This is the clause tracker 157 left open: the raise existed, both hosts performed answers
    /// through it, and nothing ever assigned it — so a card answered from Activity stayed pending
    /// on screen for ever, because the engine sends no frame back for an answer. Activity does not
    /// need the per-row render context to close it: it holds no `ChannelTimelineModel`, but the
    /// app's one registry does, and a provider over that registry is what the composition root
    /// hands it.
    ///
    /// The whole path is exercised — the row's own button, Activity's answering object, the
    /// lifecycle double, the raise, the fold — because every shorter version of this test passed
    /// while the app did not.
    func testAnAnswerFromActivityLeavesNoPendingDecision() async throws {
        let rig = try await SeamRig(fixture: "permission-allow")
        await rig.open()

        let shell = ShellModel()
        shell.isApplicationActive = true
        let router = NotificationRouter(poster: RecordingPoster(),
                                        lifecycle: rig.lifecycle,
                                        isInView: { _ in false },
                                        preferences: { NotificationPreferences() })
        let activity = ActivityModel(lifecycle: rig.lifecycle,
                                     configHome: rig.home.configHome.root,
                                     shell: shell,
                                     router: router,
                                     store: nil)
        activity.timeline = { [registry = rig.registry] key in registry.model(for: key) }

        let ask = try FixtureRunner.request("permission-allow", subtype: "can_use_tool",
                                            id: "req_invented_c63_activity_0001")
        await rig.lifecycle.setStates([ActivityFixtures.state(rig.key, pending: [ActivityFixtures.pending(ask)])])
        await rig.lifecycle.always(.success(ActivityFixtures.state(rig.key)))
        await activity.start()
        await rig.lifecycle.push(.request(ask), to: rig.key)

        let pending = await rig.settle { $0.timeline.overlay.decisions[ask.id]?.state == .pending }
        XCTAssertTrue(pending, "the pushed ask never became a pending decision the host has to answer")
        await activity.whenSettled { model in model.items.contains { $0.card != nil } }
        let item = try XCTUnwrap(activity.items.first { $0.card != nil },
                                 "Activity offered no inline answer for a plain permission ask")

        let body = ActivityRowView(item: item, title: "an invented channel",
                                   activity: activity, shell: shell).body
        let card = try XCTUnwrap(CardTree.permissionBody(in: body), "the row drew no permission card")
        let button = try XCTUnwrap(ViewTree.button("Allow once", in: card), "the row drew no Allow once")
        XCTAssertTrue(ViewTree.press(button), "the Allow once button carried no action")
        await activity.answering.whenIdle()

        let settled = await rig.settle { model in
            model.timeline.overlay.decisions.values.allSatisfy { $0.state != .pending }
        }
        let stillPending = rig.model.timeline.overlay.decisions.values.filter { $0.state == .pending }
        XCTAssertTrue(settled, "\(stillPending.count) decision(s) are still pending after answering from Activity")

        activity.stop()
        await rig.finish()
    }

    // MARK: - The pipeline

    /// The overlay reaches the app at all — which, before the seam commit, it never did.
    ///
    /// `publish()` built `ChannelTimeline(durable:)` alone, so `overlay` was `.empty` and `preview`
    /// was nil in every running channel on the machine: C3's fold had no consumer anywhere. This
    /// pushes `background-shell`'s own recorded events and asserts the live half arrived. Counts
    /// only, never text (§11).
    func testTheOverlayReachesTheTimeline() async throws {
        let rig = try await SeamRig(fixture: "background-shell")
        await rig.open()

        XCTAssertTrue(rig.model.timeline.overlay.items.isEmpty,
                      "the overlay held \(rig.model.timeline.overlay.items.count) item(s) before any event was pushed")

        for event in try FixtureRunner.events("background-shell") {
            await rig.lifecycle.push(event, to: rig.key)
        }

        // Settle on the shape this asserts, not on a weaker one. `background-shell` carries two
        // `result` frames, so two turn summaries are what the live half must end with; waiting for
        // "any overlay item" returns on the first notification and asserts the turns before they
        // have arrived, which is a flake rather than a finding.
        let filled = await rig.settle { $0.timeline.overlay.turns.count == 2 }
        XCTAssertTrue(filled, "the overlay carries \(rig.model.timeline.overlay.turns.count) turn summary/-ies, not the 2 the fixture records")
        XCTAssertFalse(rig.model.timeline.overlay.items.isEmpty, "the overlay projected no items at all")
        await rig.finish()
    }

    /// A cluster's key names the tool call it summarises, so a row can find its members.
    ///
    /// **The `tool_use_summary` frame is invented, and it has to be.** No fixture in the corpus
    /// carries one — `FleetKit/Tests/FleetTimelineTests/Invariant/ProjectionEqualityTests.swift`
    /// asserts that as an invariant, with a comment telling whoever adds one to *read* it rather
    /// than construct it — so the labelled arm of every cluster test injects a frame, and only the
    /// counts-and-elapsed fallback is exercised by any recording (tracker 128). This asserts the one
    /// thing the renderer depends on: `Overlay.clusters` is keyed by the first call's `ItemID`, and
    /// that key matches a `toolCall` the durable half holds.
    func testClusterKeysMatchToolCallIDs() async throws {
        let rig = try await SeamRig(fixture: "background-shell")
        await rig.open()
        for event in try FixtureRunner.events("background-shell") {
            await rig.lifecycle.push(event, to: rig.key)
        }
        let ready = await rig.settle { !$0.timeline.durable.items.isEmpty }
        XCTAssertTrue(ready, "the fixture produced no durable items to summarise")

        let calls = rig.model.timeline.durable.items.compactMap { item -> String? in
            if case .toolCall(let call) = item { return call.toolUseID }
            return nil
        }
        let lead = try XCTUnwrap(calls.first, "the fixture carries no tool call for a summary to name")

        // Decoded from a line rather than built with a memberwise initialiser, because
        // `ToolUseSummaryFields`' is internal to ClaudeWire — and decoding is also how a real one
        // would arrive, so the invented frame goes through the production decoder like any other.
        let line = Data(#"{"type":"tool_use_summary","summary":"an invented summary","preceding_tool_use_ids":["\#(lead)"],"uuid":"00000000-0000-4000-8000-0000000000c1","session_id":"\#(rig.key.session.description)"}"#.utf8)
        guard case .toolUseSummary = FrameDecoder.decode(line: line) else {
            return XCTFail("the invented summary line did not decode as a tool_use_summary frame")
        }
        await rig.lifecycle.push(.frame(FrameDecoder.decode(line: line), .first), to: rig.key)

        let labelled = await rig.settle { !$0.timeline.overlay.clusters.isEmpty }
        XCTAssertTrue(labelled, "the injected summary produced no cluster")

        // The renderer looks a cluster up by the item id of the call it leads. Compare the `key`
        // halves: an `ItemID` carries the config-home path and never belongs in a message (§11).
        let clusterKeys = Set(rig.model.timeline.overlay.clusters.keys.map(\.key))
        let callKeys = Set(calls)
        XCTAssertFalse(clusterKeys.isEmpty, "no cluster key to compare")
        XCTAssertTrue(clusterKeys.isSubset(of: callKeys),
                      "\(clusterKeys.subtracting(callKeys).count) cluster key(s) name no tool call in the durable half")
        await rig.finish()
    }

    /// The streaming preview is dropped when its own message arrives, so no message is drawn twice.
    ///
    /// The preview is what the channel shows while an assistant message streams; the `assistant`
    /// frame carrying the same `message.id` is what settles it. A renderer that kept both would draw
    /// the message twice — once as a preview and once as the settled item — which is why the drop is
    /// asserted rather than assumed.
    func testThePreviewIsDroppedWhenItsAssistantFrameArrives() async throws {
        let rig = try await SeamRig(fixture: "background-shell")
        await rig.open()

        let events = try FixtureRunner.events("background-shell")
        guard let firstAssistant = events.firstIndex(where: { event in
            if case .frame(.assistant, _) = event { return true }
            return false
        }) else { return XCTFail("the fixture carries no assistant frame, so nothing settles a preview") }

        for event in events[..<firstAssistant] { await rig.lifecycle.push(event, to: rig.key) }
        let streaming = await rig.settle { $0.timeline.preview != nil }
        XCTAssertTrue(streaming, "the fixture's stream events opened no preview")

        await rig.lifecycle.push(events[firstAssistant], to: rig.key)
        let settled = await rig.settle { $0.timeline.preview == nil }
        XCTAssertTrue(settled, "the assistant frame did not drop the preview it settles")
        await rig.finish()
    }

    // MARK: - Tracker 66

    /// A channel whose index entry is momentarily absent is retried rather than latched.
    ///
    /// The entry is absent because the transcript was not there when the channel was first opened —
    /// deleted between listing and opening, or written a moment later. `hasOpened` used to be set
    /// before the lookup, so the guard that prevents a second ingestion had already fired and the
    /// channel reported "could not be read" for the life of the model, which the registry retains
    /// across every switch away and back.
    func testAMissingIndexEntryIsRetried() async throws {
        let rig = try await SeamRig(fixture: "background-shell", placeTranscript: false)

        await rig.open()
        XCTAssertNotNil(rig.model.failure, "opening a channel with no index entry reported no failure")
        XCTAssertTrue(rig.model.items.isEmpty, "a channel with no index entry read \(rig.model.items.count) items")
        XCTAssertFalse(rig.model.hasOpened, "a failed lookup still marked the channel opened")

        // The transcript appears, the index sees it, and the column's next appearance opens again.
        try rig.placeTranscript()
        _ = try await rig.workspace.index.build()
        await rig.open()

        XCTAssertNil(rig.model.failure, "the retried open still reports a failure")
        XCTAssertFalse(rig.model.items.isEmpty, "the retried open read \(rig.model.items.count) items")
        XCTAssertTrue(rig.model.hasOpened, "the successful open did not mark the channel opened")
        await rig.finish()
    }
}

// MARK: - Support

/// One channel over a scratch config home, with a committed fixture's transcript on disk.
///
/// Built by hand rather than through `LaunchSequence`, like `ChannelTimelineModelTests`' own rig: a
/// launch adds a binary probe, a version gate and a sign-in gate, each of which can fail for reasons
/// that say nothing about these seams.
@MainActor
private struct SeamRig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: LifecycleDouble
    let registry: ChannelTimelineRegistry
    let key: ChannelKey
    let transcriptSource: URL
    let transcriptDestination: URL

    var model: ChannelTimelineModel { registry.model(for: key) }

    init(fixture: String, placeTranscript: Bool = true) async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)

        guard let main = try Self.mainTranscript(of: fixture) else {
            throw Bail("fixture \(fixture) carries no main transcript")
        }
        transcriptSource = main.slugDirectory
        transcriptDestination = projects
            .appending(path: "\(fixture)-\(main.slug)", directoryHint: .isDirectory)
            .appending(path: "\(main.session).jsonl")
        key = ChannelKey(configHome: home.configHome.root, session: main.session)
        if placeTranscript { try Self.place(source: transcriptSource, at: transcriptDestination) }

        let index = TranscriptIndex(configHome: home.configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        let watcher = StubWatcher()
        let feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        lifecycle = LifecycleDouble()
        workspace = Workspace(configHome: home.configHome,
                              environment: LaunchFixtures.environment(home: temp.root, configHome: home.root),
                              binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
                              installed: SemanticVersion(major: 2, minor: 1, patch: 263),
                              store: store,
                              index: index,
                              fleet: StubFleet(),
                              watcher: watcher,
                              changes: feed,
                              diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs", directoryHint: .isDirectory)),
                              rawCapture: nil)
        registry = ChannelTimelineRegistry()
        registry.attach(to: workspace, lifecycle: lifecycle)
        // An owned channel, so `events(of:)` really answers and the subscription count is real.
        await lifecycle.openEvents(of: key)
    }

    /// Puts the fixture's transcript on disk after the fact, for the retry test.
    func placeTranscript() throws {
        try Self.place(source: transcriptSource, at: transcriptDestination)
    }

    private static func place(source: URL, at destination: URL) throws {
        let slug = destination.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: slug.path) else { return }
        try FileManager.default.createDirectory(at: slug.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: slug)
    }

    func open() async { await model.open(row()) }
    func finish() async { await lifecycle.finishEvents(of: key) }

    /// Waits, bounded, for the model to satisfy `predicate`, and **returns whether it did** so the
    /// caller asserts the outcome. A wait whose result is discarded is not an assertion: it would
    /// turn a wedge into a pass on whatever clause came after it.
    func settle(_ predicate: @MainActor (ChannelTimelineModel) -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate(model) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(model)
    }

    func row() -> ChannelRow {
        ChannelRow(key: key,
                   title: "a recorded channel",
                   titleSource: .firstPrompt,
                   preview: "invented preview",
                   cwd: URL(fileURLWithPath: "/invented/project"),
                   gitBranch: nil,
                   agentName: nil,
                   mtime: Date(),
                   isRecent: true,
                   mode: .ownedCandidate,
                   decidingRule: "invented",
                   isProvisional: false,
                   state: SidebarFixtures.state(key, origin: .owned(.ready)))
    }

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    static func mainTranscript(of name: String) throws -> (session: SessionID, slug: String, slugDirectory: URL)? {
        let transcripts = fixtures.appending(path: name).appending(path: "transcript")
        guard let slugs = try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)
        else { return nil }
        for slug in slugs {
            let files = (try? FileManager.default.contentsOfDirectory(at: slug, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let session = TranscriptPath.mainTranscript(fileName: file.lastPathComponent) else { continue }
                return (session, slug.lastPathComponent, slug)
            }
        }
        return nil
    }
}

private struct Bail: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
