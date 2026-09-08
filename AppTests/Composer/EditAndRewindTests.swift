import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 Task 6, gate **G4** — *Edit*, the conversation rewind, and *Fork from here*.
///
/// Both legs come out of the `rewind-turn` fixture and neither is written down here: the recorded
/// `control_response` bodies are read out of `frames.ndjson` **at run time** and staged on the
/// lifecycle double, and the conversation itself is the fixture's own transcript, folded by a real
/// `StreamIngestion` in a scratch config home (X9). No engine byte reaches this file, and no
/// assertion below prints a path, a title, a session id or an environment (§11).
///
/// The arms the recording cannot produce — `"unseen later turn"`, an unrecognised refusal — are
/// injected as bodies of the fixture's own shape, which is what the spec's G4 asks for: the fixture
/// was recorded before `last_seen_user_message_uuid` existed and can only answer `"stale target"`.
@MainActor
final class EditAndRewindTests: XCTestCase {

    // MARK: - The honoured leg

    /// The engine honoured the rewind: the field carries `prefillText` **verbatim**, and
    /// `HostSignal.rewound` is raised exactly once.
    ///
    /// The prefill is compared against the string read out of the fixture's own response, so a
    /// composer that reconstructed the text from the edited message would fail even when the two
    /// happened to look alike — and a composer that raised the signal twice, or not at all, fails on
    /// the count.
    func testHonouredRewindPrefillsTheEngineTextAndRaisesTheSignalOnce() async throws {
        let rig = try await Rig()
        let messages = rig.renderedUserMessages()
        XCTAssertGreaterThanOrEqual(messages.count, 2,
                                    "the fixture folded \(messages.count) user message(s); this gate needs at least 2")
        let honoured = try Rig.recordedHonouredBody()
        let prefill = try XCTUnwrap(honoured["prefillText"]?.stringValue,
                                    "the recorded honoured body carries no `prefillText` to prefill from")

        await rig.lifecycle.stageSend("rewind_conversation", .success(honoured))
        rig.composer.draft = "what the user had half-typed"
        await rig.composer.edit(messages[messages.count - 1])

        XCTAssertEqual(rig.composer.draft, prefill,
                       "the field does not carry the \(prefill.count)-character prefill the engine returned")
        XCTAssertEqual(rig.composer.rewindSignalsRaised, 1,
                       "an honoured rewind raised \(rig.composer.rewindSignalsRaised) host signal(s), not exactly 1")
        XCTAssertNil(rig.composer.editNote,
                     "an honoured rewind left a note behind, which says a fork was opened when none was")
        let actions = await rig.lifecycle.actions
        XCTAssertTrue(actions.isEmpty, "an honoured rewind performed \(actions.count) lifecycle action(s), including a fork")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// The honoured rewind reaches the channel's **fold**, not merely the composer's own counter.
    ///
    /// The stake is the streaming preview: `HostSignal.rewound` is what clears the half-drawn turn
    /// the engine has just discarded, and a composer whose raise never arrived would leave it on
    /// screen. An invented `stream_event` opens a preview, the honoured answer is replayed, and the
    /// preview is gone afterwards. A floor first, so a test that never had a preview cannot pass by
    /// finding none.
    func testTheHonouredRewindClearsThePreviewTheEngineDiscarded() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()
        let leaf = try XCTUnwrap(rig.precedingAssistantRecord(before: target),
                                 "the chosen message has no preceding assistant record to rewind to")
        await rig.openAPreview()
        let opened = await rig.settleUntil { $0.timeline.preview != nil }
        XCTAssertTrue(opened, "no streaming preview was open, so its absence afterwards would prove nothing")

        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedHonouredBody(preceding: leaf)))
        await rig.composer.edit(target)

        XCTAssertNil(rig.timeline.timeline.preview,
                     "the honoured rewind left the discarded turn's preview on screen")
        XCTAssertEqual(rig.composer.rewindSignalsRaised, 1,
                       "an honoured rewind raised \(rig.composer.rewindSignalsRaised) host signal(s), not exactly 1")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// The mirror of the arm above: a **refused** rewind leaves the preview exactly where it was.
    ///
    /// This is the assertion the gate calls for in the negative — a preview cleared by a refused
    /// rewind is a timeline that disagrees with the engine, and nothing else in the app puts it back.
    func testARefusedRewindLeavesThePreviewAlone() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()
        await rig.openAPreview()
        let opened = await rig.settleUntil { $0.timeline.preview != nil }
        XCTAssertTrue(opened, "no streaming preview was open, so this arm proves nothing")

        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))
        await rig.composer.edit(target)

        XCTAssertNotNil(rig.timeline.timeline.preview,
                        "a refused rewind cleared the preview, which the engine did not discard")
        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "a refused rewind raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    // MARK: - The refusals

    /// The recorded `"stale target"` refusal: a fork is opened, a note is shown, and **no** host
    /// signal is raised.
    ///
    /// The not-raised arm is the one that matters. A preview left behind by a refused rewind is a
    /// timeline that disagrees with the engine about what the conversation holds, and nothing else
    /// in the app would ever put it back.
    func testTheRecordedStaleTargetRefusalForksAndRaisesNoSignal() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()
        let entry = try XCTUnwrap(rig.precedingAssistantKey(before: target),
                                  "the chosen message has no preceding assistant item, so this arm cannot run")

        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))
        await rig.composer.edit(target)

        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "a refused rewind raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        let actions = await rig.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "the refusal produced \(actions.count) lifecycle action(s), not exactly 1 fork")
        guard case .fork(let point)? = actions.first else {
            return XCTFail("the refusal's one action is not a fork")
        }
        let fork = try XCTUnwrap(point, "the fork carries no fork point, so it forks from the end")
        XCTAssertEqual(fork.entryUUID, entry,
                       "the fork's entry is not the assistant item immediately before the edited message")
        XCTAssertEqual(fork.dropsTurn, target.promptUUID,
                       "the fork does not drop the edited message's own turn")
        XCTAssertEqual(rig.composer.draft, target.text,
                       "the field does not carry the \(target.text.count)-character text of the edited message")
        let note = try XCTUnwrap(rig.composer.editNote, "the refused rewind showed no note at all")
        XCTAssertTrue(note.contains("not rewound") && note.contains("fork"),
                      "the \(note.count)-character note does not say the conversation was not rewound and a fork was opened")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// `"unseen later turn"` takes the identical path and says something different.
    ///
    /// Injected, because `rewind-turn` was recorded without `last_seen_user_message_uuid` and the
    /// engine only answers this string to a caller that sent one. Both notes are asserted to differ,
    /// so a composer with one sentence for every refusal fails while the path stays shared.
    func testUnseenLaterTurnTakesTheSamePathWithDifferentWording() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()

        await rig.lifecycle.stageSend("rewind_conversation", .success(Rig.refusal(reason: "unseen later turn")))
        await rig.composer.edit(target)

        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "a refused rewind raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        let actions = await rig.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "the refusal produced \(actions.count) lifecycle action(s), not exactly 1 fork")
        if case .fork(let point)? = actions.first {
            XCTAssertEqual(point?.dropsTurn, target.promptUUID, "the fork does not drop the edited message's own turn")
        } else {
            XCTFail("the refusal's one action is not a fork")
        }
        let note = try XCTUnwrap(rig.composer.editNote, "the refused rewind showed no note at all")
        XCTAssertNotEqual(note, ComposerModel.forkNote("stale target"),
                          "the two refusals are shown with the same \(note.count)-character wording")
        XCTAssertEqual(note, ComposerModel.forkNote("unseen later turn"),
                       "the note is not this refusal's own wording")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// A body-level `error` this leaf has never seen also falls back rather than reporting success.
    ///
    /// The engine has ten distinct refusal strings and this leaf knows two of them; a composer that
    /// recognised only its own two and treated the rest as honoured would show eight refusals as
    /// completed rewinds.
    func testAnUnrecognisedRefusalStillFallsBack() async throws {
        let rig = try await Rig()
        let target = try rig.messageWithAPrecedingAssistant()

        await rig.lifecycle.stageSend("rewind_conversation", .success(Rig.refusal(reason: "an invented reason")))
        await rig.composer.edit(target)

        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "an unrecognised refusal raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        let actions = await rig.lifecycle.actions
        XCTAssertEqual(actions.count, 1, "the unrecognised refusal produced \(actions.count) lifecycle action(s), not exactly 1 fork")
        let note = try XCTUnwrap(rig.composer.editNote, "the unrecognised refusal showed no note at all")
        XCTAssertEqual(note, ComposerModel.forkNote("an invented reason"),
                       "the \(note.count)-character note is not the unnamed-refusal wording")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    // MARK: - The payload

    /// Every request carries `last_seen_user_message_uuid`, and it is the **newest** rendered user
    /// message — not the edit target's own uuid.
    ///
    /// This is the arm that matters. The probe measured the field naming the target itself answering
    /// `"unseen later turn"`, so a composer that reached for the obvious value would be refused on
    /// every edit of an older message and would fall back to a fork every time — correct-looking in a
    /// smoke test with the feature gone. The oldest rendered message is edited so the two uuids
    /// differ, and both the equality and the inequality are asserted: substituting the target's uuid
    /// fails on both.
    func testTheRequestNamesTheNewestRenderedMessageAndNotTheTarget() async throws {
        let rig = try await Rig()
        let messages = rig.renderedUserMessages()
        XCTAssertGreaterThanOrEqual(messages.count, 2,
                                    "the fixture folded \(messages.count) user message(s); this arm needs at least 2")
        let target = try XCTUnwrap(messages.first, "the fixture folded no user message to edit")
        let newest = try XCTUnwrap(messages.last, "the fixture folded no newest user message")
        XCTAssertNotEqual(target.promptUUID, newest.promptUUID,
                          "the oldest and newest of the fold's \(messages.count) user message(s) are the same message")

        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))
        await rig.composer.edit(target)

        let subtypes = await rig.lifecycle.sentSubtypes
        XCTAssertEqual(subtypes, ["rewind_conversation"],
                       "editing sent \(subtypes.count) control request(s), not exactly 1 rewind_conversation")
        let sent = await rig.lifecycle.payload(ofFirst: "rewind_conversation")
        let payload = try XCTUnwrap(sent, "the rewind request carries no payload")
        XCTAssertEqual(payload["target_message_uuid"]?.stringValue, target.promptUUID,
                       "the request does not name the edited message under `target_message_uuid`")
        let lastSeen = try XCTUnwrap(payload["last_seen_user_message_uuid"]?.stringValue,
                                     "the request carries no `last_seen_user_message_uuid`, which refuses every older edit")
        XCTAssertEqual(lastSeen, newest.promptUUID,
                       "`last_seen_user_message_uuid` is not the newest of the fold's \(messages.count) rendered user message(s)")
        XCTAssertNotEqual(lastSeen, target.promptUUID,
                          "`last_seen_user_message_uuid` is the edit target's own uuid, which the engine refuses with `unseen later turn`")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    /// The same field is on the honoured leg's request too — presence is asserted on both arms, not
    /// only on the one that happens to be refused.
    func testTheHonouredRequestCarriesTheFieldAsWell() async throws {
        let rig = try await Rig()
        let newest = try XCTUnwrap(rig.renderedUserMessages().last, "the fixture folded no user message to edit")

        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedHonouredBody()))
        await rig.composer.edit(newest)

        let sent = await rig.lifecycle.payload(ofFirst: "rewind_conversation")
        let payload = try XCTUnwrap(sent, "the rewind request carries no payload")
        XCTAssertEqual(payload["last_seen_user_message_uuid"]?.stringValue, newest.promptUUID,
                       "the honoured leg's request does not carry the newest rendered message under `last_seen_user_message_uuid`")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }

    // MARK: - Nothing to fork from

    /// An edited message with no assistant record before it has no fork point: nothing is offered,
    /// the reason is shown, and no fork reaches the lifecycle.
    ///
    /// The fixture's own refused target is that message — the first conversational `user` record —
    /// so this arm is the recording's leg exactly as it was recorded.
    func testAMessageWithNoPrecedingAssistantOffersNoForkAndSaysWhy() async throws {
        let rig = try await Rig()
        let target = try XCTUnwrap(rig.renderedUserMessages().first, "the fixture folded no user message to edit")
        XCTAssertNil(rig.precedingAssistantKey(before: target),
                     "the fold put an assistant item before the conversation's first user message, so this arm proves nothing")

        await rig.lifecycle.stageSend("rewind_conversation", .success(try Rig.recordedRefusedBody()))
        await rig.composer.edit(target)

        let actions = await rig.lifecycle.actions
        XCTAssertTrue(actions.isEmpty, "a message with no fork point produced \(actions.count) lifecycle action(s)")
        XCTAssertEqual(rig.composer.rewindSignalsRaised, 0,
                       "a refused rewind raised \(rig.composer.rewindSignalsRaised) host signal(s)")
        let note = try XCTUnwrap(rig.composer.editNote, "no reason was shown for offering no fork")
        XCTAssertEqual(note, ComposerModel.noForkPointNote("stale target"),
                       "the \(note.count)-character note is not the no-fork-point reason")
        try await rig.assertNoFileRewind()
        await rig.finish()
    }
}

// MARK: - Support

/// One channel over the `rewind-turn` fixture: a real `TranscriptIndex`, a real `StreamIngestion`
/// behind C6.1's `ChannelTimelineModel`, a real `ComposerModel`, and one `ComposerLifecycleDouble`
/// serving as X5.
///
/// The same shape as `QueueChipTests`' rig and for the same reason — a `LaunchSequence` adds a
/// binary probe and two gates that say nothing about a rewind. The scratch tree is a `TempTree`,
/// which refuses to build inside any config home (X9).
@MainActor
private final class Rig {

    let temp: TempTree
    let home: ScratchConfigHome
    let workspace: Workspace
    let lifecycle: ComposerLifecycleDouble
    let timelines: ChannelTimelineRegistry
    let composers: ComposerRegistry
    let key: ChannelKey

    enum RigError: Error { case noMainTranscript, noRecordedLeg, noMessageWithAPrecedingAssistant }

    var timeline: ChannelTimelineModel { timelines.model(for: key) }
    var composer: ComposerModel { composers.model(for: key)! }

    init(fixture: String = "rewind-turn") async throws {
        temp = try TempTree()
        home = try ScratchConfigHome(tree: temp)
        let projects = home.root.appending(path: "projects", directoryHint: .isDirectory)

        guard let main = try Self.mainTranscript(of: fixture) else { throw RigError.noMainTranscript }
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
        await lifecycle.openEvents(of: key)
        await lifecycle.alwaysPerform(.success(ActivityFixtures.state(key)))

        timelines = ChannelTimelineRegistry()
        timelines.attach(to: workspace, lifecycle: lifecycle)
        composers = ComposerRegistry()
        composers.attach(to: workspace,
                         timeline: { [timelines] in timelines.model(for: $0) },
                         lifecycle: lifecycle)

        await timelines.model(for: key).open(row())
        _ = composers.model(for: key)
    }

    // MARK: - Reading the fold

    /// The fold's user messages, in its own order. The test's own walk, so the composer's answer is
    /// compared against the timeline rather than against itself.
    func renderedUserMessages() -> [UserMessageItem] {
        timeline.timeline.items.compactMap {
            if case .userMessage(let message) = $0, !message.promptUUID.isEmpty { message } else { nil }
        }
    }

    /// The `ItemID.key` of the assistant item immediately before `target`, computed here by walking
    /// the fold backwards.
    func precedingAssistantKey(before target: UserMessageItem) -> String? {
        let items = timeline.timeline.items
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return nil }
        for item in items[..<index].reversed() {
            if case .assistantMessage(let assistant) = item { return assistant.id.key }
        }
        return nil
    }

    /// The last record of the assistant item immediately before `target` — the uuid the engine's own
    /// leaf names after it honours a rewind to that turn.
    func precedingAssistantRecord(before target: UserMessageItem) -> String? {
        let items = timeline.timeline.items
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return nil }
        for item in items[..<index].reversed() {
            if case .assistantMessage(let assistant) = item { return assistant.recordUUIDs.last ?? assistant.id.key }
        }
        return nil
    }

    /// The **oldest** user message the fold rendered that has an assistant item before it, so a fork
    /// point exists and the target is not the newest message either.
    func messageWithAPrecedingAssistant() throws -> UserMessageItem {
        for message in renderedUserMessages() where precedingAssistantKey(before: message) != nil {
            return message
        }
        throw RigError.noMessageWithAPrecedingAssistant
    }

    /// Opens a streaming preview by pushing one invented `message_start` onto the channel's tap.
    ///
    /// The ids are this suite's own repeated nibbles and the frame is decoded by the production
    /// decoder, as a real one would be; nothing engine-recorded is spelled here (§11).
    func openAPreview() async {
        let line = Data(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_invented0000","type":"message","role":"assistant","content":[],"model":"an-invented-model"}},"session_id":"\#(key.session.description)","uuid":"00000000-0000-4000-8000-0000000000b1"}"#.utf8)
        let frame = FrameDecoder.decode(line: line)
        guard case .streamEvent = frame else {
            return XCTFail("the invented line did not decode as a stream_event frame")
        }
        lifecycle.enqueue(.frame(frame, .first), to: key)
    }

    /// Waits, bounded, for the channel's fold to satisfy `predicate`, and **returns whether it did**
    /// so the caller asserts the outcome.
    func settleUntil(_ predicate: @MainActor (ChannelTimelineModel) -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate(timeline) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(timeline)
    }

    /// Zero `rewind_files` requests, on every arm. *Edit* is not `/rewind`.
    func assertNoFileRewind(file: StaticString = #filePath, line: UInt = #line) async throws {
        let subtypes = await lifecycle.sentSubtypes
        XCTAssertFalse(subtypes.contains("rewind_files"),
                       "the edit path sent a file rewind among its \(subtypes.count) control request(s)",
                       file: file, line: line)
    }

    // MARK: - The recording

    /// The recorded honoured body: `{rewound: true, targetMessageUuid, prefillText, precedingAssistantUuid}`.
    static func recordedHonouredBody() throws -> JSONValue {
        try recordedBody { $0["rewound"]?.boolValue == true }
    }

    /// The recorded honoured body with its `precedingAssistantUuid` replaced by a record this fold
    /// actually holds. Every other key, `prefillText` included, is the recording's own.
    static func recordedHonouredBody(preceding uuid: String) throws -> JSONValue {
        guard case .object(var body) = try recordedHonouredBody() else { throw RigError.noRecordedLeg }
        body["precedingAssistantUuid"] = .string(uuid)
        return .object(body)
    }

    /// The recorded refusal: `{rewound: false, prefillText: null, precedingAssistantUuid: null, error}`,
    /// inside a `control_response {subtype: "success"}` envelope.
    static func recordedRefusedBody() throws -> JSONValue {
        try recordedBody { $0["error"]?.stringValue != nil }
    }

    /// A refusal of the recording's own shape carrying another of the engine's reasons. The two
    /// null-valued keys are kept because a composer that read them instead of `error` must fail here
    /// exactly as it fails on the recorded leg.
    static func refusal(reason: String) -> JSONValue {
        .object(["rewound": .bool(false), "prefillText": .null,
                 "precedingAssistantUuid": .null, "error": .string(reason)])
    }

    /// Reads the fixture's `frames.ndjson` and returns the first `control_response` body matching
    /// `predicate`. Nothing read here is written anywhere; it lives for the duration of one test.
    private static func recordedBody(_ predicate: (JSONValue) -> Bool) throws -> JSONValue {
        let url = fixtures.appending(path: "rewind-turn").appending(path: "frames.ndjson")
        let decoder = JSONDecoder()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(JSONValue.self, from: data),
                  record["frame"]?["type"]?.stringValue == "control_response",
                  let response = record["frame"]?["response"],
                  response["subtype"]?.stringValue == "success",
                  let body = response["response"], predicate(body)
            else { continue }
            return body
        }
        throw RigError.noRecordedLeg
    }

    // MARK: - Teardown and fixtures

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
