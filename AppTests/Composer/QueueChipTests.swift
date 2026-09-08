import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 Task 5, gate **G3** — the queue chip.
///
/// A `command_lifecycle` sequence is replayed through a **real** `ChannelTimeline`: a committed
/// fixture's transcript is copied into a scratch config home, `ChannelTimelineModel` opens it over
/// `StreamIngestion`, and the frames are pushed onto the channel's own event tap. Nothing here folds
/// the wire and nothing here derives a queue — the ingestion holds the channel's only reducer
/// (contract X4 as amended), and every row this suite asserts on came out of `Overlay.queue.queued`.
///
/// Every scratch tree is a `TempTree`, which refuses to build inside any config home (X9). The
/// `command_lifecycle` lines are the suite's own invention; the one engine-recorded value any of them
/// carries — a user record's uuid, read out of the fixture at run time so a label has something real
/// to match — never reaches a committed file, and no assertion below prints a path, a title, a
/// session id or an engine byte (§11).
@MainActor
final class QueueChipTests: XCTestCase {

    // MARK: - The rows are the overlay's

    /// The chip's rows are `Overlay.queue.queued` in arrival order, and each row leaves when its id
    /// reaches a terminal state.
    ///
    /// Order is asserted rather than membership: the engine queues in arrival order and a chip that
    /// showed the queue as a set would tell the user the wrong message is next. The three ids are
    /// queued in one order and drained in another, so a chip that happened to sort or to reverse
    /// fails.
    func testRowsFollowTheQueuedListInArrivalOrder() async throws {
        let rig = try await Rig()
        let ids = Rig.inventedCommandUUIDs

        for id in ids { await rig.push(state: "queued", commandUUID: id) }
        let arrived = await rig.settle { $0.rows.count == ids.count }
        XCTAssertTrue(arrived, "the chip shows \(rig.chip.rows.count) row(s) for \(ids.count) queued command(s)")
        XCTAssertEqual(rig.chip.rows.map(\.id), ids,
                       "the chip's \(rig.chip.rows.count) row(s) are not in the engine's arrival order")

        // Drained out of order, and each terminal state is a different one: `completed`, the engine's
        // `refused`, and `started` followed by `completed`. `QueueState.apply` drops the id from both
        // lists on anything that is not `queued` or `started`.
        await rig.push(state: "completed", commandUUID: ids[1])
        let afterOne = await rig.settle { $0.rows.count == 2 }
        XCTAssertTrue(afterOne, "a completed command left \(rig.chip.rows.count) row(s), not 2")
        XCTAssertEqual(rig.chip.rows.map(\.id), [ids[0], ids[2]],
                       "the surviving \(rig.chip.rows.count) row(s) lost the order the engine queued them in")

        await rig.push(state: "refused", commandUUID: ids[2])
        await rig.push(state: "completed", commandUUID: ids[0])
        let drained = await rig.settle { $0.rows.isEmpty }
        XCTAssertTrue(drained, "the chip still shows \(rig.chip.rows.count) row(s) after every command reached a terminal state")

        await rig.finish()
    }

    /// A `started` id is not offered as cancellable-because-queued.
    ///
    /// `cancel_async_message` cancels a *queued* message; the engine answers `false` for one that has
    /// started, and offering the action would be offering something that cannot happen. The chip's
    /// rows are `queued` and never `started`, so this asserts the started id is gone from the rows
    /// while the still-queued one is not — a floor, so a chip that showed nothing at all could not
    /// pass by having no started row either.
    func testAStartedCommandIsNotOfferedAsQueued() async throws {
        let rig = try await Rig()
        let ids = Rig.inventedCommandUUIDs

        await rig.push(state: "queued", commandUUID: ids[0])
        await rig.push(state: "queued", commandUUID: ids[1])
        let queued = await rig.settle { $0.rows.count == 2 }
        XCTAssertTrue(queued, "\(rig.chip.rows.count) row(s) queued, not 2")

        await rig.push(state: "started", commandUUID: ids[0])
        let started = await rig.settle { $0.rows.count == 1 }
        XCTAssertTrue(started, "a started command left \(rig.chip.rows.count) row(s), not 1")
        XCTAssertFalse(rig.chip.rows.contains { $0.id == ids[0] },
                       "the started command is still one of the chip's \(rig.chip.rows.count) cancellable row(s)")
        XCTAssertTrue(rig.chip.rows.contains { $0.id == ids[1] },
                      "the still-queued command is not among the chip's \(rig.chip.rows.count) row(s)")
        // The fold has it, so the chip is reading `queued` and not merely an empty overlay.
        XCTAssertTrue(rig.timeline.timeline.overlay.queue.started.contains(ids[0]),
                      "the fold does not hold the started command, so the row's absence proves nothing")

        await rig.finish()
    }

    // MARK: - Cancel

    /// Cancelling a row sends exactly one `cancel_async_message` naming that id, through X5.
    ///
    /// The payload key is asserted by name: it is snake_case on the wire, and a camelCase key would
    /// be a request the engine ignores while afleet showed a cancel that did nothing.
    func testCancellingSendsOneCancelAsyncMessageNamingTheRow() async throws {
        let rig = try await Rig()
        let ids = Rig.inventedCommandUUIDs
        for id in ids.prefix(2) { await rig.push(state: "queued", commandUUID: id) }
        let ready = await rig.settle { $0.rows.count == 2 }
        XCTAssertTrue(ready, "\(rig.chip.rows.count) row(s) to cancel from, not 2")

        await rig.chip.cancel(ids[1])

        let subtypes = await rig.lifecycle.sentSubtypes
        XCTAssertEqual(subtypes, ["cancel_async_message"],
                       "cancelling sent \(subtypes.count) control request(s), not exactly 1 of the right subtype")
        let payload = await rig.lifecycle.payload(ofFirst: "cancel_async_message")
        XCTAssertEqual(payload?["message_uuid"]?.stringValue, ids[1],
                       "the request does not carry the cancelled row's id under `message_uuid`")
        let actions = await rig.lifecycle.actions
        XCTAssertTrue(actions.isEmpty, "cancelling performed \(actions.count) lifecycle action(s)")

        await rig.finish()
    }

    /// `{cancelled: false}` refreshes the chip and shows **no** banner.
    ///
    /// The engine's own schema says `false` means the message was not in the queue — it already
    /// started. That is the queue's `{backgrounded: false}` (§8.4): nothing went wrong, so nothing is
    /// said. The absence is what is asserted, and a chip that surfaced the answer as an error fails.
    func testCancelledFalseShowsNoBanner() async throws {
        let rig = try await Rig()
        let ids = Rig.inventedCommandUUIDs
        await rig.push(state: "queued", commandUUID: ids[0])
        let ready = await rig.settle { $0.rows.count == 1 }
        XCTAssertTrue(ready, "\(rig.chip.rows.count) row(s) to cancel from, not 1")

        await rig.lifecycle.stageSend("cancel_async_message", .success(.object(["cancelled": .bool(false)])))
        await rig.chip.cancel(ids[0])

        XCTAssertNil(rig.chip.cancelFailure,
                     "a `cancelled: false` answer raised a banner, which the message already having started does not warrant")
        let sent = await rig.lifecycle.sentSubtypes
        XCTAssertEqual(sent.count, 1, "the declined cancel sent \(sent.count) request(s), not 1")

        await rig.finish()
    }

    /// No optimistic removal: a cancel whose answer has arrived but whose `command_lifecycle` has not
    /// leaves the row exactly where it was.
    ///
    /// This is the arm that matters. A cancel the engine declines must not vanish a message that is
    /// still going to run: the words would be gone from the chip while the turn that speaks them is
    /// still coming, and the user has no way back to them. Both answers are exercised — an accepted
    /// `{cancelled: true}` and a declined `{cancelled: false}` — because the rule is about the
    /// *`command_lifecycle`*, not about which answer came back.
    func testACancelRemovesNothingBeforeCommandLifecycleSaysSo() async throws {
        let rig = try await Rig()
        let ids = Rig.inventedCommandUUIDs
        for id in ids.prefix(2) { await rig.push(state: "queued", commandUUID: id) }
        let ready = await rig.settle { $0.rows.count == 2 }
        XCTAssertTrue(ready, "\(rig.chip.rows.count) row(s) to cancel from, not 2")

        await rig.lifecycle.stageSend("cancel_async_message", .success(.object(["cancelled": .bool(true)])))
        await rig.chip.cancel(ids[0])
        XCTAssertEqual(rig.chip.rows.map(\.id), Array(ids.prefix(2)),
                       "an answered cancel removed a row before `command_lifecycle` said the id left the queue")

        await rig.lifecycle.stageSend("cancel_async_message", .success(.object(["cancelled": .bool(false)])))
        await rig.chip.cancel(ids[1])
        XCTAssertEqual(rig.chip.rows.map(\.id), Array(ids.prefix(2)),
                       "a declined cancel removed a row the engine said was already running")

        // And it does leave, when the fold says so. Without this the assertions above would pass on a
        // chip that never removed anything at all.
        await rig.push(state: "completed", commandUUID: ids[0])
        let left = await rig.settle { $0.rows.map(\.id) == [ids[1]] }
        XCTAssertTrue(left, "the cancelled command still shows among \(rig.chip.rows.count) row(s) after its terminal state")

        await rig.finish()
    }

    // MARK: - Both send arms

    /// A send while a turn is running produces one `perform(.send)` **and** a chip; a send with no
    /// turn running produces one `perform(.send)` and **no** chip.
    ///
    /// Both arms, so a chip that is always on cannot pass. What separates them is the engine: a
    /// message sent into a running turn is queued and the engine says so with `command_lifecycle`,
    /// and a message sent into an idle channel is not. The composer raises nothing either way — it
    /// cannot, because `perform(.send)` drops the uuid `HostSignal.promptSent` needs (the
    /// `[parent-impact]` on this leaf's spec) — so the chip is the fold's answer and not afleet's
    /// guess about it.
    func testBothSendArms() async throws {
        let rig = try await Rig()
        let idle = try XCTUnwrap(rig.composer, "the registry built no composer for the channel")

        // Arm one: no turn running. The engine queues nothing.
        idle.draft = "an invented first message"
        await idle.send()
        var actions = await rig.lifecycle.actions
        var sends = actions.filter { if case .send = $0 { return true }; return false }
        XCTAssertEqual(sends.count, 1, "an idle send performed \(sends.count) `.send` action(s), not 1")
        XCTAssertTrue(rig.chip.rows.isEmpty,
                      "a send with no turn running showed \(rig.chip.rows.count) chip row(s)")

        // Arm two: a turn is running, so the engine queues the message and says so.
        idle.draft = "an invented second message"
        await idle.send()
        actions = await rig.lifecycle.actions
        sends = actions.filter { if case .send = $0 { return true }; return false }
        XCTAssertEqual(sends.count, 2, "the queued send performed \(sends.count) `.send` action(s) in total, not 2")
        await rig.push(state: "queued", commandUUID: Rig.inventedCommandUUIDs[0])

        let chipped = await rig.settle { $0.rows.count == 1 }
        XCTAssertTrue(chipped, "a send the engine queued showed \(rig.chip.rows.count) chip row(s), not 1")

        await rig.finish()
    }

    // MARK: - Labels

    /// A queued uuid that matches a `userMessage` row shows that row's text; one that matches nothing
    /// is an **unlabelled row that is present**, not a hidden one.
    ///
    /// A queued message the user cannot see is worse than one without a label, so the negative arm
    /// asserts presence and not merely a nil label. The matched uuid is read out of the fixture's own
    /// timeline at run time — it is the uuid the engine would echo — and never written down here.
    func testLabelsComeFromTheTimelineAndAnUnmatchedIDIsStillARow() async throws {
        let rig = try await Rig()
        let known = try XCTUnwrap(rig.firstUserMessage(),
                                  "the fixture's transcript carries no user message for a label to come from")
        let unknown = Rig.inventedCommandUUIDs[0]

        await rig.push(state: "queued", commandUUID: known.promptUUID)
        await rig.push(state: "queued", commandUUID: unknown)
        let both = await rig.settle { $0.rows.count == 2 }
        XCTAssertTrue(both, "the chip shows \(rig.chip.rows.count) row(s) for 2 queued commands")

        let labelled = try XCTUnwrap(rig.chip.rows.first { $0.id == known.promptUUID },
                                     "the queued command matching a user message has no row at all")
        XCTAssertEqual(labelled.label, known.text,
                       "the row's label is not the text of the user message its uuid names")
        XCTAssertFalse(known.text.isEmpty, "the fixture's user message is empty, so the label proves nothing")

        let unmatched = try XCTUnwrap(rig.chip.rows.first { $0.id == unknown },
                                      "a queued command with no timeline item was hidden instead of shown unlabelled")
        XCTAssertNil(unmatched.label, "a queued command with no timeline item was given a label from somewhere")

        await rig.finish()
    }
}

// MARK: - Support

/// One channel with a real ingestion, a real timeline model, a real composer, and one
/// `ComposerLifecycleDouble` serving both as X5 and as the channel's event tap.
///
/// Built by hand rather than through `LaunchSequence`, like `ChannelTimelineSeamTests`' rig, and for
/// the same reason: a launch adds a binary probe, a version gate and a sign-in gate, none of which
/// say anything about a queue.
@MainActor
private final class Rig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: ComposerLifecycleDouble
    let timelines: ChannelTimelineRegistry
    let composers: ComposerRegistry
    let key: ChannelKey

    /// The one way this rig fails to build: the named fixture records no main transcript, so there is
    /// no channel to open. A case and not a message, so nothing here can print a path (§11).
    enum RigError: Error { case noMainTranscript }

    /// How many frames this rig has pushed, so each invented frame carries a uuid of its own.
    private var pushed = 0

    /// Invented command uuids — repeated nibbles, this suite's own, never the engine's (§11).
    static let inventedCommandUUIDs = ["00000000-0000-4000-8000-0000000000a1",
                                       "00000000-0000-4000-8000-0000000000a2",
                                       "00000000-0000-4000-8000-0000000000a3"]

    var timeline: ChannelTimelineModel { timelines.model(for: key) }
    var composer: ComposerModel? { composers.model(for: key) }
    var chip: QueueChipModel { composer!.queue }

    init(fixture: String = "plain-two-turn") async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)

        guard let main = try Self.mainTranscript(of: fixture) else {
            throw RigError.noMainTranscript
        }
        let destination = projects
            .appending(path: "\(fixture)-\(main.slug)", directoryHint: .isDirectory)
            .appending(path: "\(main.session).jsonl")
        key = ChannelKey(configHome: home.configHome.root, session: main.session)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: main.slugDirectory, to: destination.deletingLastPathComponent())

        let index = TranscriptIndex(configHome: home.configHome, storage: InMemoryIndexStorage())
        _ = try await index.build()
        let store = try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                       configHomes: [home.root])
        let watcher = StubWatcher()
        let feed = TranscriptChangeFeed(source: watcher.changes)
        await feed.start()

        lifecycle = ComposerLifecycleDouble()
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
        // An owned channel, so `events(of:)` really answers and the pushed frames really reach the
        // ingestion's tap.
        await lifecycle.openEvents(of: key)
        // Every send succeeds; this suite is about the chip, not about the refusal arms Task 1 owns.
        await lifecycle.alwaysPerform(.success(ActivityFixtures.state(key)))

        timelines = ChannelTimelineRegistry()
        timelines.attach(to: workspace, lifecycle: lifecycle)
        composers = ComposerRegistry()
        composers.attach(to: workspace,
                         timeline: { [timelines] in timelines.model(for: $0) },
                         lifecycle: lifecycle)

        await timelines.model(for: key).open(row())
        // Building the composer is what points its chip at the timeline.
        _ = composers.model(for: key)
    }

    /// Pushes one invented `command_lifecycle` frame onto the channel's tap.
    ///
    /// Decoded from a line rather than built with a memberwise initialiser, because
    /// `CommandLifecycleFields`' is internal to ClaudeWire — and decoding is also how a real one
    /// arrives, so the invented frame goes through the production decoder like any other.
    func push(state: String, commandUUID: String) async {
        pushed += 1
        let uuid = "00000000-0000-4000-8000-" + String(format: "%012x", pushed)
        let line = Data(#"{"type":"command_lifecycle","state":"\#(state)","command_uuid":"\#(commandUUID)","uuid":"\#(uuid)","session_id":"\#(key.session.description)"}"#.utf8)
        let frame = FrameDecoder.decode(line: line)
        guard case .commandLifecycle = frame else {
            return XCTFail("the invented line did not decode as a command_lifecycle frame")
        }
        lifecycle.enqueue(.frame(frame, .first), to: key)
    }

    /// The first `userMessage` the fixture's transcript produced, for the label arm.
    func firstUserMessage() -> UserMessageItem? {
        for item in timeline.timeline.items {
            if case .userMessage(let message) = item, !message.promptUUID.isEmpty { return message }
        }
        return nil
    }

    /// Waits, bounded, for the chip to satisfy `predicate`, and **returns whether it did** so the
    /// caller asserts the outcome. A wait whose result is discarded is not an assertion.
    func settle(_ predicate: @MainActor (QueueChipModel) -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate(chip) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(chip)
    }

    func finish() async {
        await lifecycle.finishEvents(of: key)
        composers.release(key)
        timelines.release(key)
    }

    func row() -> ChannelRow {
        ChannelRow(key: key,
                   title: "an invented channel",
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
                   state: ActivityFixtures.state(key))
    }

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures")
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
