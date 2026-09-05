import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// The wire reducer over the committed recordings, folded through `FixtureWireReplay` — C2's own `WireEventPolicy`
/// threaded exactly as the transport threads it. Nothing here writes, nothing launches a process, and no fixture byte
/// is compared against a literal: message content is compared as a canonical hash, everything else as identifiers,
/// counts and shapes (C3 constraints).
final class WireReducerTests: XCTestCase {

    // MARK: - Streaming preview

    /// `plain-two-turn`. The engine emits one `assistant` frame per finished content block, interleaved with the
    /// deltas of the block after it, so the preview is read at each `assistant` frame: the last one of a message has
    /// the message's text, and every one of them collapses the preview.
    ///
    /// This test also carries the replay's own completeness guard: the multiset of frame types the replay published
    /// for this fixture is compared against the recording's out-direction frames, so a class of event the replay
    /// silently stopped producing fails here rather than quietly emptying several other tests.
    func testStreamingPreviewAssemblesAndCollapses() throws {
        let fixture = try FixtureCorpus.named("plain-two-turn")
        var reducer = try FixtureWireReplay.reducer(for: fixture)
        let steps = try FixtureWireReplay.steps(for: fixture)

        var textBefore: [String] = []
        var nilAfter: [Bool] = []
        var published: [String: Int] = [:]
        for step in steps {
            for event in step.events {
                guard case .frame(let frame, _) = event else { continue }
                published[frame.typeName, default: 0] += 1
            }
            let carriesAssistant = step.events.contains { if case .frame(.assistant, _) = $0 { true } else { false } }
            if carriesAssistant { textBefore.append(reducer.preview?.text ?? "<no preview>") }
            FixtureWireReplay.apply(step, to: &reducer)
            if carriesAssistant { nilAfter.append(reducer.preview == nil) }
        }

        XCTAssertEqual(textBefore.count, 4, "plain-two-turn carries four assistant frames")
        XCTAssertEqual(nilAfter, [true, true, true, true], "every assistant frame collapses the preview")
        XCTAssertNil(reducer.preview, "the stream ended with no preview open")
        XCTAssertEqual(textBefore.map(\.isEmpty), [true, false, true, false],
                       "the first frame of a message precedes its text, the second follows it")

        let messages: [AssistantMessageItem] = reducer.durable.items.compactMap {
            if case .assistantMessage(let item) = $0 { item } else { nil }
        }
        XCTAssertEqual(messages.count, 2, "four assistant frames merge into two message.id groups")
        XCTAssertEqual(messages.map { $0.recordUUIDs.count }, [2, 2])
        XCTAssertEqual(messages.map { Self.hash(Self.text(of: $0.blocks)) },
                       [Self.hash(textBefore[1]), Self.hash(textBefore[3])],
                       "each item's text is the text its preview had assembled")

        var expected: [String: Int] = [:]
        for recorded in try fixture.frames() where recorded.direction == "out" {
            if case .controlRequest = recorded.frame { continue }
            if case .controlResponse = recorded.frame { continue }
            expected[recorded.frame.typeName, default: 0] += 1
        }
        expected["control_response"] = 1                       // `end-1`, the one host request the engine answered
        XCTAssertEqual(published, expected,
                       "the replay published exactly the recording's non-control frames plus the correlated response")
    }

    // MARK: - Result attribution

    /// `session-mirror-relocation` prompts four turns and relocates once; the relocation's own `result` carries
    /// `num_turns: 0` and belongs to no prompt. `nested-depth-2` prompts once and the two subagent results carry the
    /// session's own id and no parent, which is why attribution is host state and not a frame field.
    func testResultAttributionOnRelocationAndNestedAgents() throws {
        let relocation = try FixtureCorpus.named("session-mirror-relocation")
        let moved = try FixtureWireReplay.replay(relocation)
        XCTAssertEqual(moved.overlay.turns.map { Self.label(of: $0.attribution) },
                       ["prompted", "prompted", "relocation", "prompted", "prompted"])
        XCTAssertEqual(moved.overlay.turns.map(\.numTurns).filter { $0 == 0 }.count, 1,
                       "exactly one recorded result is the relocation's")

        let promptUUIDs = try Self.promptUUIDs(of: relocation)
        XCTAssertEqual(moved.overlay.turns.compactMap { Self.promptedUUID(of: $0.attribution) }, promptUUIDs,
                       "each prompted turn popped the oldest outstanding prompt, in order")
        XCTAssertTrue(moved.outstandingPrompts.isEmpty)

        let nested = try FixtureWireReplay.replay(FixtureCorpus.named("nested-depth-2"))
        XCTAssertEqual(nested.overlay.turns.map { Self.label(of: $0.attribution) },
                       ["prompted", "unprompted", "unprompted"])
    }

    // MARK: - Decisions

    /// Three states over three sources: `permission-allow`'s recorded allow, `permission-deny`'s recorded deny (the
    /// policy surfaces the request and never answers it — the host's own `behavior: deny` response is the answer),
    /// and `.policyAnswered`, which is reachable only through a `writeAnswer` effect carrying an error and so is
    /// driven by a constructed inbound request with an invented id and an unmodelled subtype: no engine bytes.
    func testDecisionLifecycle() throws {
        for (name, expected) in [("permission-allow", "allowed"), ("permission-deny", "denied")] {
            let fixture = try FixtureCorpus.named(name)
            var reducer = try FixtureWireReplay.reducer(for: fixture)
            let steps = try FixtureWireReplay.steps(for: fixture)
            var sawPending = false
            for step in steps {
                FixtureWireReplay.apply(step, to: &reducer)
                if reducer.overlay.decisions.values.contains(where: { $0.state == .pending }) { sawPending = true }
            }
            XCTAssertTrue(sawPending, "\(name): the can_use_tool request was surfaced as pending")
            let decisions = reducer.overlay.decisions.values.sorted { $0.requestID.rawValue < $1.requestID.rawValue }
            XCTAssertEqual(decisions.count, 1, "\(name) records exactly one decision")
            XCTAssertEqual(decisions.first?.kind, .permission, "\(name) asks about a Write")
            XCTAssertEqual(decisions.first?.state, .answered(outcome: expected))
        }

        // The unmodelled subtype: the policy answers it itself with an error and publishes `.policyAnswered`.
        let fixture = try FixtureCorpus.named("permission-allow")
        var reducer = try FixtureWireReplay.replay(fixture)
        let trace = try FixtureWireReplay.trace(for: fixture)
        let invented = RequestID(rawValue: "afleet-invented-request-0001")
        let line = JSONValue.object([
            "type": .string("control_request"),
            "request_id": .string(invented.rawValue),
            "request": .object(["subtype": .string("afleet_invented_unmodelled_subtype")]),
        ])
        let constructed = FrameDecoder.decode(line: try line.canonicalData())
        let effects = try FixtureWireReplay.wirePolicy(for: fixture)
            .effects(for: constructed, in: trace.context, receivedAt: .now)
        XCTAssertEqual(effects.map { $0.kind.description },
                       ["markSeen", "writeAnswer", "publish(policyAnswered)"])
        for effect in effects {
            guard case .publish(let event) = effect else { continue }
            _ = reducer.apply(event, at: Date(timeIntervalSince1970: 0))
        }
        let answered = try XCTUnwrap(reducer.overlay.decisions[invented])
        XCTAssertEqual(answered.kind, .other, "an unmodelled payload has no kind the host names")
        guard case .policyAnswered(let error) = answered.state else {
            return XCTFail("the constructed request did not land in .policyAnswered")
        }
        XCTAssertFalse(error.isEmpty, "the policy's error message reached the item")
    }

    /// `tool_use_summary` labels the cluster its `preceding_tool_use_ids` name, keyed by the first of them.
    /// **No fixture carries the frame**: the frame here is schema-shaped, decoded through `FrameDecoder`, and the
    /// tool-use ids in it are read off a replayed fixture at run time so that no engine byte is written into this file.
    func testToolUseSummaryLabelsTheCluster() throws {
        let fixture = try FixtureCorpus.named("explore-depth-1")
        XCTAssertTrue(try fixture.frames().allSatisfy { if case .toolUseSummary = $0.frame { false } else { true } },
                      "the corpus is still free of tool_use_summary frames; this test's frame is constructed")
        var reducer = try FixtureWireReplay.replay(fixture)
        let calls: [String] = reducer.durable.items.compactMap {
            if case .toolCall(let call) = $0, call.provenance.agentID == nil { call.toolUseID } else { nil }
        }
        XCTAssertFalse(calls.isEmpty, "the main stream made at least one tool call to cluster")

        let line = JSONValue.object([
            "type": .string("tool_use_summary"),
            "summary": .string("afleet invented cluster label"),
            "preceding_tool_use_ids": .array(calls.map(JSONValue.string)),
            "uuid": .string("00000000-0000-4000-8000-00000000c105"),
            "session_id": .string("00000000-0000-4000-8000-0000000005e5"),
        ])
        _ = reducer.apply(.frame(FrameDecoder.decode(line: try line.canonicalData()), .first),
                          at: Date(timeIntervalSince1970: 0))

        let key = ItemID(stream: reducer.stream, key: try XCTUnwrap(calls.first))
        let cluster = try XCTUnwrap(reducer.overlay.clusters[key], "the cluster is keyed by the first preceding call")
        XCTAssertEqual(cluster.toolUseIDs, calls)
        XCTAssertEqual(cluster.label, "afleet invented cluster label")
        XCTAssertEqual(reducer.overlay.clusters.count, 1)
    }

    // MARK: - Agent streams

    /// `explore-depth-1`: every frame carrying a `parent_tool_use_id` is attributed to the agent stream the run tree
    /// resolves, never to the main stream.
    func testForwardedFramesLandOnTheAgentStream() throws {
        let reducer = try FixtureWireReplay.replay(FixtureCorpus.named("explore-depth-1"))
        let taskID = try XCTUnwrap(reducer.agents.roots.first, "the run tree holds the depth-1 agent")
        let agentStream = LogicalStream(configHome: reducer.stream.configHome,
                                        sessionID: reducer.stream.sessionID, name: .agent(taskID: taskID))

        let attributed = reducer.durable.items.filter { $0.provenance.agentID == taskID }
        XCTAssertFalse(attributed.isEmpty, "forwarded frames produced items")
        XCTAssertTrue(attributed.allSatisfy { $0.id.stream == agentStream },
                      "no item attributed to the agent sits on the main stream's id")
        XCTAssertTrue(attributed.contains { if case .assistantMessage = $0 { true } else { false } })
        XCTAssertTrue(attributed.contains { if case .toolCall = $0 { true } else { false } })

        let mainItems = reducer.durable.items.filter { $0.id.stream == reducer.stream }
        XCTAssertFalse(mainItems.isEmpty, "the main stream kept its own items")
        XCTAssertTrue(mainItems.allSatisfy { $0.provenance.agentID == nil })

        XCTAssertNotNil(reducer.agents.node(taskID)?.model, "a forwarded assistant frame set the model badge")
        XCTAssertTrue(reducer.durable.items.contains { if case .taskRun(let run) = $0 { run.taskID == taskID } else { false } },
                      "the merge spliced the agent's run row into the line")
    }

    /// `background-shell`: the shell's `task_notification` is the only source of a completion row, so the row appears
    /// at that frame and not before.
    func testTaskNotificationSynthesisesACompletionItem() throws {
        let fixture = try FixtureCorpus.named("background-shell")
        var reducer = try FixtureWireReplay.reducer(for: fixture)
        var beforeNotification = -1
        for step in try FixtureWireReplay.steps(for: fixture) {
            let notifies = step.events.contains {
                if case .frame(.system(.taskNotification), _) = $0 { true } else { false }
            }
            if notifies { beforeNotification = Self.synthesised(in: reducer).count }
            FixtureWireReplay.apply(step, to: &reducer)
        }
        XCTAssertEqual(beforeNotification, 0, "no synthesised row existed before the notification")
        let runs = Self.synthesised(in: reducer)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .completed)
        XCTAssertEqual(runs.first?.provenance.origin, .synthesised)
        XCTAssertEqual(runs.first?.kind, .localBash)
        XCTAssertNotNil(runs.first?.outputFile, "the notification bound the task's output file")
        XCTAssertEqual(reducer.registry.entries.count, 1)
        XCTAssertEqual(runs.first?.taskID, reducer.registry.entries.keys.first)
    }

    // MARK: - Unwitnessed paths

    /// **No fixture carries a `user` frame with `isSynthetic`.** The frame here is a recorded one with that flag set
    /// in memory, decoded back through `FrameDecoder`: it is hidden with reason `isSynthetic` and renders nothing.
    func testSyntheticUsersAreHidden_mutation() throws {
        let fixture = try FixtureCorpus.named("plain-two-turn")
        XCTAssertTrue(try fixture.frames().allSatisfy { recorded in
            if case .user(let user) = recorded.frame { user.isSynthetic == nil } else { true }
        }, "the corpus is still free of synthetic user frames; this test mutates one")

        let recorded = try XCTUnwrap(try fixture.frames().first { recorded in
            recorded.direction == "out" && { if case .user = recorded.frame { true } else { false } }()
        })
        var object = try XCTUnwrap(recorded.value.objectValue)
        object["isSynthetic"] = .bool(true)
        let mutated = FrameDecoder.decode(line: try JSONValue.object(object).canonicalData())

        var reducer = try FixtureWireReplay.reducer(for: fixture)
        _ = reducer.apply(.frame(mutated, .first), at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(reducer.durable.items.isEmpty, "a synthetic user renders nothing")
        XCTAssertEqual(reducer.durable.hidden.map(\.reason), [.isSynthetic])
        XCTAssertEqual(reducer.durable.hidden.map(\.kind), ["user"])
        XCTAssertNil(reducer.durable.hidden.first?.locator, "the wire delivered it, so no byte range names it")

        var unmutated = try FixtureWireReplay.reducer(for: fixture)
        _ = unmutated.apply(.frame(recorded.frame, .first), at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(unmutated.durable.items.count, 1, "the same frame without the flag renders")
        XCTAssertTrue(unmutated.durable.hidden.isEmpty)
    }

    /// **No fixture carries a rewind.** The signal is applied after a full replay of `plain-two-turn`: everything
    /// after the item the named record produced goes, and the leaf follows.
    func testRewoundTruncatesTheDurableHalf_mutation() throws {
        var reducer = try FixtureWireReplay.replay(FixtureCorpus.named("plain-two-turn"))
        let before = reducer.durable.items.map(\.id)
        XCTAssertEqual(before.count, 4, "two prompts and two merged assistant messages")

        let firstMessage = try XCTUnwrap(reducer.durable.items.compactMap {
            if case .assistantMessage(let item) = $0 { item } else { nil }
        }.first)
        let target = try XCTUnwrap(firstMessage.recordUUIDs.first)
        _ = reducer.apply(.rewound(toUUID: target), at: Date(timeIntervalSince1970: 0))

        // Compared as booleans throughout this file: an `ItemID` holds a `LogicalStream`, which carries the config
        // home path and is never logged (C3 constraint 12), so a diagnostic names item keys and counts only.
        XCTAssertTrue(reducer.durable.items.map(\.id) == Array(before.prefix(2)),
                      "kept \(reducer.durable.items.map(\.id.key)) of \(before.map(\.key))")
        XCTAssertEqual(reducer.durable.session.leaf, target)
        XCTAssertNil(reducer.preview)
    }

    /// A replacement process resets the wire-only half and leaves the durable half exactly where it was.
    func testProcessReplacedResetsOverlayNotProjection() throws {
        var reducer = try FixtureWireReplay.replay(FixtureCorpus.named("background-shell"))
        let items = reducer.durable.items
        XCTAssertFalse(items.isEmpty)
        XCTAssertFalse(reducer.overlay.turns.isEmpty)
        XCTAssertFalse(reducer.overlay.banners.isEmpty)
        XCTAssertNotEqual(reducer.overlay.queue.lastState, nil)

        _ = reducer.apply(.processReplaced(ProcessEpoch.first.next()), at: Date(timeIntervalSince1970: 0))
        // Compared as a boolean: an `Overlay` carries `ItemID`s (and so a `LogicalStream` and the config home path)
        // and engine-authored banner text, and XCTest prints both operands of a failing `XCTAssertEqual`. The message
        // names counts and shapes only (C3 constraint 12), as Task 8's fix wave did at four other sites.
        let after = reducer.overlay
        XCTAssertTrue(after == .empty, """
            the overlay was not reset: decisions \(after.decisions.count), clusters \(after.clusters.count), \
            turns \(after.turns.count), notifications \(after.notifications.count), hooks \(after.hooks.count), \
            banners \(after.banners.count), queue \(after.queue.queued.count)/\(after.queue.started.count), \
            stale \(after.stale), sessionState \(after.sessionState != nil)
            """)
        XCTAssertFalse(reducer.overlay.stale)
        XCTAssertNil(reducer.preview)
        XCTAssertTrue(reducer.outstandingPrompts.isEmpty)
        XCTAssertTrue(reducer.durable.items == items,
                      "the durable half is untouched: \(reducer.durable.items.map(\.id.key)) vs \(items.map(\.id.key))")
    }

    /// `command_lifecycle` drives the queue. `plain-two-turn` carries two commands through `queued`, `started` and
    /// `completed`, so both transitions and the terminal drop are witnessed by the corpus.
    func testCommandLifecycleDrivesQueueState() throws {
        let fixture = try FixtureCorpus.named("plain-two-turn")
        var reducer = try FixtureWireReplay.reducer(for: fixture)
        var states: [String] = []
        var queuedDepth: [Int] = []
        var startedDepth: [Int] = []
        for step in try FixtureWireReplay.steps(for: fixture) {
            var lifecycle: String?
            for event in step.events {
                guard case .frame(.commandLifecycle(let f), _) = event else { continue }
                lifecycle = f.state
            }
            FixtureWireReplay.apply(step, to: &reducer)
            guard let lifecycle else { continue }
            states.append(lifecycle)
            queuedDepth.append(reducer.overlay.queue.queued.count)
            startedDepth.append(reducer.overlay.queue.started.count)
        }
        XCTAssertEqual(states, ["queued", "started", "completed", "queued", "started", "completed"])
        XCTAssertEqual(queuedDepth, [1, 0, 0, 1, 0, 0])
        XCTAssertEqual(startedDepth, [0, 1, 0, 0, 1, 0])
        XCTAssertEqual(reducer.overlay.queue.lastState, "completed")
        XCTAssertTrue(reducer.overlay.queue.queued.isEmpty)
        XCTAssertTrue(reducer.overlay.queue.started.isEmpty)
    }

    /// **No fixture carries a `tool_progress` frame.** `background-shell` is replayed up to its `task_started` and a
    /// schema-shaped heartbeat is then constructed for the row that fold produced; the task id is read off the
    /// registry at run time so no recorded identifier is written into this file.
    func testToolProgressHeartbeatMovesLastFrameAt() throws {
        let fixture = try FixtureCorpus.named("background-shell")
        XCTAssertTrue(try fixture.frames().allSatisfy { if case .toolProgress = $0.frame { false } else { true } },
                      "the corpus is still free of tool_progress frames; this test's frame is constructed")

        var reducer = try FixtureWireReplay.reducer(for: fixture)
        for step in try FixtureWireReplay.steps(for: fixture) {
            FixtureWireReplay.apply(step, to: &reducer)
            if !reducer.registry.entries.isEmpty { break }
        }
        let taskID = try XCTUnwrap(reducer.registry.entries.keys.first)
        let before = try XCTUnwrap(reducer.registry.entries[taskID])

        let now = Date(timeIntervalSince1970: 2_000_000)
        _ = reducer.apply(.frame(.toolProgress(try RegistryMirrorTests.inventedToolProgress(taskID: taskID)), .first),
                          at: now)
        let after = try XCTUnwrap(reducer.registry.entries[taskID])
        XCTAssertEqual(after.lastFrameAt, now)
        XCTAssertNotEqual(before.lastFrameAt, now)
        var expected = before
        expected.lastFrameAt = now
        // Compared as a boolean, not with XCTAssertEqual: a failing struct comparison would print the entry's
        // recorded description into the diagnostic, and a diagnostic prints identifiers and shapes only.
        XCTAssertTrue(after == expected, "the heartbeat moved lastFrameAt and nothing else")
        XCTAssertEqual(reducer.registry.liveWork(asOf: now.addingTimeInterval(1)).map(\.id), [taskID])
    }

    /// `nested-depth-2`: one relocation signal moves every agent's transcript URL and changes nothing else, because
    /// no node stores a path.
    func testRelocationSignalRebindsAgentTranscriptPaths() throws {
        var reducer = try FixtureWireReplay.replay(FixtureCorpus.named("nested-depth-2"))
        let taskIDs = reducer.agents.nodes.keys.sorted()
        XCTAssertEqual(taskIDs.count, 2)
        XCTAssertTrue(taskIDs.allSatisfy { reducer.agents.transcriptURL(of: $0)?.path.contains("/_slug_/") == true })
        let items = reducer.durable.items
        let overlay = reducer.overlay

        let moved = FixtureCorpus.recordedConfigHome
            .appendingPathComponent("projects").appendingPathComponent("_other_")
            .appendingPathComponent("\(reducer.stream.sessionID).jsonl")
        _ = reducer.apply(.relocated(mainPath: moved), at: Date(timeIntervalSince1970: 0))

        for id in taskIDs {
            let url = try XCTUnwrap(reducer.agents.transcriptURL(of: id))
            XCTAssertTrue(url.path.contains("/_other_/"), "agent \(id) moved with the slug")
            XCTAssertFalse(url.path.contains("/_slug_/"))
        }
        XCTAssertTrue(reducer.durable.items == items,
                      "a relocation renames nothing in the projection: \(reducer.durable.items.map(\.id.key))")
        XCTAssertTrue(reducer.overlay == overlay,
                      "and adds no banner when the path resolves to this session: \(reducer.overlay.banners.count) banners")

        // A path that names another session is ignored and counted.
        let elsewhere = FixtureCorpus.recordedConfigHome
            .appendingPathComponent("projects").appendingPathComponent("_other_")
            .appendingPathComponent("00000000-0000-4000-8000-00000000beef.jsonl")
        _ = reducer.apply(.relocated(mainPath: elsewhere), at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(reducer.overlay.banners.count, overlay.banners.count + 1)
        XCTAssertEqual(reducer.overlay.banners.last?.kind, .compatibility)
        XCTAssertTrue(try XCTUnwrap(reducer.agents.transcriptURL(of: taskIDs[0])).path.contains("/_other_/"))
    }

    /// `session-mirror-resume` is the one fixture where the seed matters: `initial/` holds five assistant groups the
    /// recording never re-sends. Seeded, the wire's durable half equals the record reducer's over `transcript/` in
    /// every compared category — check two's shape on one fixture. Unseeded, those five groups are simply missing.
    func testASeededReducerContinuesTheFileProjection() throws {
        let fixture = try FixtureCorpus.named("session-mirror-resume")
        let seeded = try FixtureWireReplay.replay(fixture)

        var projections: [StreamProjection] = []
        var main: LogicalStream?
        for (stream, kind, url) in try fixture.transcriptFiles() {
            let records = try TranscriptReader(url: url).readAll().records
            projections.append(RecordReducer.reduce(records, stream: stream, sourceFile: url))
            if case .mainTranscript = kind { main = stream }
        }
        let fromFile = RecordReducer.merge(projections, main: try XCTUnwrap(main))

        XCTAssertEqual(Self.digest(seeded.durable.items), Self.digest(fromFile.items),
                       "the seeded wire projection matches the record reducer item for item")
        XCTAssertEqual(Self.digest(fromFile.items).count, 12, "the compared line is twelve items long")

        let unseeded = try Self.replayWithoutSeed(fixture)
        let missing = Self.digest(fromFile.items).count - Self.digest(unseeded.durable.items).count
        XCTAssertGreaterThan(missing, 0, "without the seed the file's earlier items are absent")
        XCTAssertEqual(Self.digest(unseeded.durable.items),
                       Array(Self.digest(fromFile.items).suffix(Self.digest(unseeded.durable.items).count)),
                       "what the wire alone produced is the tail of the file's line")
        let seedGroups = try FixtureWireReplay.seed(for: fixture).items.filter {
            if case .assistantMessage = $0 { true } else { false }
        }
        XCTAssertEqual(seedGroups.count, 5, "the seed supplies the five assistant groups the wire never re-sends")
    }

    /// **No fixture carries a `conversation_reset` frame.** The frame clears the durable half outright, and the
    /// half a resume seeded is part of it: `session-mirror-resume`'s seed is real, so its items, hidden records and
    /// branches are asserted non-empty first and the reset must leave nothing of any of them.
    func testConversationResetClearsTheWholeDurableHalf_unwitnessed() throws {
        for fixture in try FixtureCorpus.all() {
            XCTAssertTrue(try fixture.frames().allSatisfy { if case .conversationReset = $0.frame { false } else { true } },
                          "the corpus is still free of conversation_reset frames; this test's frame is constructed")
        }
        let fixture = try FixtureCorpus.named("session-mirror-resume")
        var reducer = try FixtureWireReplay.replay(fixture)

        XCTAssertFalse(reducer.durable.items.isEmpty, "the seeded projection has items to lose")
        XCTAssertFalse(reducer.durable.hidden.isEmpty, "the seed contributed hidden records")
        XCTAssertNotNil(reducer.durable.session.leaf, "the seed named a leaf")
        let seeded = try FixtureWireReplay.seed(for: fixture)
        XCTAssertFalse(seeded.hidden.isEmpty, "and those hidden records came from initial/, not from the wire")

        let line = JSONValue.object([
            "type": .string("conversation_reset"),
            "new_conversation_id": .string("00000000-0000-4000-8000-00000000c0de"),
            "uuid": .string("00000000-0000-4000-8000-00000000c0d1"),
            "session_id": .string("00000000-0000-4000-8000-0000000005e5"),
        ])
        _ = reducer.apply(.frame(FrameDecoder.decode(line: try line.canonicalData()), .first),
                          at: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(reducer.durable.items.isEmpty, "items: \(reducer.durable.items.count)")
        XCTAssertTrue(reducer.durable.hidden.isEmpty, "hidden: \(reducer.durable.hidden.count)")
        XCTAssertTrue(reducer.durable.branches.isEmpty, "branches: \(reducer.durable.branches.count)")
        XCTAssertTrue(reducer.durable.warnings.isEmpty, "warnings: \(reducer.durable.warnings.count)")
        XCTAssertNil(reducer.durable.window)
        XCTAssertNil(reducer.durable.session.leaf)
        XCTAssertEqual(reducer.durable.session, SessionState())
        XCTAssertNil(reducer.preview)

        // `session-mirror-resume`'s transcript is one clean chain, so its seed's `branches`, `warnings` and `window`
        // are structurally empty and the four assertions above them would pass vacuously. A seed built here from
        // invented identifiers populates all five, so the reset is asserted against something in every field.
        let stream = LogicalStream(configHome: FixtureCorpus.recordedConfigHome,
                                   sessionID: fixture.sessionID, name: .main)
        let key = RecordKey(stream: stream, identity: .uuid("00000000-0000-4000-8000-0000000000a1"))
        let populated = DurableProjection(
            items: [.notification(NotificationItem(id: ItemID(stream: stream, key: "invented-seed-item"),
                                                   provenance: Provenance(stream: stream, origin: .file),
                                                   key: "invented", text: "", level: "info", fileOnly: true))],
            hidden: [HiddenRecord(key: key, kind: "attachment", reason: .attachment)],
            branches: [Branch(head: "00000000-0000-4000-8000-0000000000b1",
                              tail: "00000000-0000-4000-8000-0000000000b2", count: 2)],
            session: { var state = SessionState(); state.leaf = "00000000-0000-4000-8000-0000000000c1"; return state }(),
            warnings: [ReadWarning(kind: .undecodable, stream: .main, byteOffset: 0)],
            window: WindowMarker(earlierAvailable: true, continueBefore: 128),
            streams: [stream])
        var loaded = WireReducer(stream: stream, slug: "_slug_", seed: populated)
        XCTAssertEqual([loaded.durable.items.count, loaded.durable.hidden.count,
                        loaded.durable.branches.count, loaded.durable.warnings.count], [1, 1, 1, 1])
        XCTAssertNotNil(loaded.durable.window)
        _ = loaded.apply(.frame(FrameDecoder.decode(line: try line.canonicalData()), .first),
                         at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual([loaded.durable.items.count, loaded.durable.hidden.count,
                        loaded.durable.branches.count, loaded.durable.warnings.count], [0, 0, 0, 0],
                       "the reset cleared every collection the seed had populated")
        XCTAssertNil(loaded.durable.window)
        XCTAssertNil(loaded.durable.session.leaf)
    }

    /// `system/status` is deliberately not a banner on its own: `Banner.Kind` has no `status` case and the frame
    /// arrives several times a turn. Both directions are pinned here, so the narrowing cannot be read as an
    /// omission. The corpus witnesses the quiet direction; **no fixture carries `compact_error`**, so the loud one
    /// is a constructed frame with an invented identifier.
    func testStatusBannersOnlyWhenACompactionFailed() throws {
        let fixture = try FixtureCorpus.named("plain-two-turn")
        let statusFrames = try fixture.frames().filter {
            if case .system(.status) = $0.frame { true } else { false }
        }
        XCTAssertEqual(statusFrames.count, 2, "plain-two-turn carries two status frames, none of them a failure")
        XCTAssertTrue(statusFrames.allSatisfy {
            if case .system(.status(let f)) = $0.frame { f.compactError == nil } else { false }
        }, "the corpus is still free of compact_error; the failing frame below is constructed")

        var reducer = try FixtureWireReplay.replay(fixture)
        let quiet = reducer.overlay.banners
        XCTAssertFalse(quiet.isEmpty, "the recording did raise other banners, so the assertion below is not vacuous")
        XCTAssertFalse(quiet.contains { $0.kind == .compatibility },
                       "two status frames without compact_error raised no banner")

        let line = JSONValue.object([
            "type": .string("system"),
            "subtype": .string("status"),
            "status": .string("compacting"),
            "compact_error": .string("afleet invented compaction failure"),
            "uuid": .string("00000000-0000-4000-8000-000000005747"),
            "session_id": .string("00000000-0000-4000-8000-0000000005e5"),
        ])
        _ = reducer.apply(.frame(FrameDecoder.decode(line: try line.canonicalData()), .first),
                          at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(reducer.overlay.banners.count, quiet.count + 1, "the failing status frame raised one banner")
        XCTAssertEqual(reducer.overlay.banners.last?.kind, .compatibility)
        XCTAssertEqual(reducer.overlay.banners.last?.text, "afleet invented compaction failure")
    }

    // MARK: - The policy's own bookkeeping

    /// The engine echoes every host-written `control_response` on its stdout. Those ids are in no pending set — they
    /// answered the *engine's* requests — so they are `dropUncorrelated` and produce no event; a response whose id
    /// the host's own request put in `pendingOutbound` is a `settleOutbound` and one `.frame`.
    ///
    /// The two sides are derived independently: the expected multiset from the recording's raw frames and the
    /// replay's seed set, the actual one from the events the replay published.
    func testEchoedControlResponsesProduceNoEvent() throws {
        var totalEchoed = 0
        var totalCorrelated = 0
        var errorBodies = 0
        for fixture in try FixtureCorpus.all() where !fixture.synthetic {
            let trace = try FixtureWireReplay.trace(for: fixture)
            let publishedFrames: [Frame] = trace.steps.flatMap(\.events).compactMap {
                if case .frame(let frame, _) = $0 { frame } else { nil }
            }
            var actual: [String: Int] = [:]
            for frame in publishedFrames { actual[frame.typeName, default: 0] += 1 }

            var expected: [String: Int] = [:]
            for recorded in try fixture.frames() where recorded.direction == "out" {
                switch recorded.frame {
                case .controlRequest:
                    continue                                   // never a frame event
                case .controlResponse(let response):
                    guard response.requestID != trace.handshakeRequestID else { continue }
                    guard trace.hostRequestIDs.contains(response.requestID) else { continue }
                    expected["control_response", default: 0] += 1
                    if case .error = response.body { errorBodies += 1 }
                default:
                    expected[recorded.frame.typeName, default: 0] += 1
                }
            }
            XCTAssertEqual(actual, expected, "fixture \(fixture.name): published frames differ from the recording")
            totalCorrelated += expected["control_response"] ?? 0

            // Every answer the host itself wrote: its id must be absent from the replay's `pendingOutbound` seed and
            // no event may carry its echo.
            let publishedResponseIDs = Set(publishedFrames.compactMap { frame -> RequestID? in
                if case .controlResponse(let response) = frame { response.requestID } else { nil }
            })
            let hostWritten = Set(try fixture.frames().filter { $0.direction == "in" }.compactMap { recorded -> RequestID? in
                if case .controlResponse(let response) = recorded.frame { response.requestID } else { nil }
            })
            totalEchoed += hostWritten.count
            for id in hostWritten {
                XCTAssertFalse(trace.hostRequestIDs.contains(id),
                               "fixture \(fixture.name): \(id) is an answer, not a host request")
                XCTAssertFalse(publishedResponseIDs.contains(id),
                               "fixture \(fixture.name): the echo of \(id) produced an event")
            }
        }
        XCTAssertEqual(totalEchoed, 57, "the recorded corpus writes 57 control_responses, every one of them echoed")
        XCTAssertEqual(totalCorrelated, 39, "and the engine answers 39 host requests other than the handshake")
        XCTAssertEqual(errorBodies, 2,
                       "control-shapes records two correlated error bodies, so no error response is constructed here")
    }

    /// A `control_cancel_request` always yields `cancelMCPTask` and a `.frame`; it yields `clearPending` and
    /// `.requestCancelled` only when the id is one the host is holding. The corpus witnesses the pending case in
    /// `dialog-refusal-fallback`, whose undeclared dialog kind the policy leaves unanswered and then cancels; the
    /// unknown-id case is a constructed cancel frame with an invented id.
    func testCancelFramesYieldCancelMCPTaskAndRequestCancelledWhenPending() throws {
        let fixture = try FixtureCorpus.named("dialog-refusal-fallback")
        let trace = try FixtureWireReplay.trace(for: fixture)
        let cancel = ["clearPending", "publish(requestCancelled)", "cancelMCPTask", "publish(frame)"]
        let windows = (0...(trace.effectKinds.count - cancel.count)).map { Array(trace.effectKinds[$0..<($0 + cancel.count)]) }
        XCTAssertEqual(windows.filter { $0 == cancel }.count, 1,
                       "the pending id's cancel clears it, announces it, cancels the task and still shows the frame")

        var reducer = try FixtureWireReplay.reducer(for: fixture)
        var sawInert = false
        for step in trace.steps {
            FixtureWireReplay.apply(step, to: &reducer)
            if reducer.overlay.decisions.values.contains(where: { $0.state == .inert }) { sawInert = true }
        }
        XCTAssertTrue(sawInert, "the undeclared dialog kind was left unanswered and shown inert")
        XCTAssertEqual(reducer.overlay.decisions.values.filter { $0.state == .cancelled }.count, 1)

        let invented = RequestID(rawValue: "afleet-invented-cancel-0001")
        let line = JSONValue.object([
            "type": .string("control_cancel_request"),
            "request_id": .string(invented.rawValue),
        ])
        let constructed = FrameDecoder.decode(line: try line.canonicalData())
        let effects = try FixtureWireReplay.wirePolicy(for: fixture)
            .effects(for: constructed, in: trace.context, receivedAt: .now)
        XCTAssertEqual(effects.map { $0.kind.description }, ["cancelMCPTask", "publish(frame)"],
                       "an unknown id is cancelled in the MCP server and shown, and nothing is announced")
        XCTAssertFalse(trace.context.pendingInbound.contains(invented))
    }

    /// **No fixture carries a `session_state_changed` frame.** Two schema-shaped frames with invented identifiers are
    /// applied to a replayed `plain-two-turn`: the last wins, no item is made, and a process replacement clears it.
    func testSessionStateChangedLandsInTheOverlay() throws {
        let fixture = try FixtureCorpus.named("plain-two-turn")
        for other in try FixtureCorpus.all() {
            XCTAssertTrue(try other.frames().allSatisfy {
                if case .system(.sessionStateChanged) = $0.frame { false } else { true }
            }, "the corpus is still free of session_state_changed frames; this test's frames are constructed")
        }
        var reducer = try FixtureWireReplay.replay(fixture)
        let items = reducer.durable.items

        func constructed(_ mode: String, uuid: String) throws -> Frame {
            FrameDecoder.decode(line: try JSONValue.object([
                "type": .string("system"),
                "subtype": .string("session_state_changed"),
                "state": .object(["mode": .string(mode)]),
                "uuid": .string(uuid),
                "session_id": .string("00000000-0000-4000-8000-0000000005e5"),
            ]).canonicalData())
        }

        let first = try constructed("afleet-invented-mode-one", uuid: "00000000-0000-4000-8000-000000005701")
        let changes = reducer.apply(.frame(first, .first), at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(reducer.overlay.sessionState?.state, .object(["mode": .string("afleet-invented-mode-one")]))
        XCTAssertTrue(reducer.durable.items == items,
                      "no item is made from the frame: \(reducer.durable.items.count) items, was \(items.count)")
        XCTAssertTrue(changes.contains(.sessionStateChanged))
        XCTAssertFalse(changes.contains { if case .inserted = $0 { true } else { false } })

        let second = try constructed("afleet-invented-mode-two", uuid: "00000000-0000-4000-8000-000000005702")
        _ = reducer.apply(.frame(second, .first), at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(reducer.overlay.sessionState?.state, .object(["mode": .string("afleet-invented-mode-two")]))
        XCTAssertEqual(reducer.overlay.sessionState?.uuid, "00000000-0000-4000-8000-000000005702",
                       "the last frame wins")

        _ = reducer.apply(.processReplaced(ProcessEpoch.first.next()), at: Date(timeIntervalSince1970: 0))
        XCTAssertNil(reducer.overlay.sessionState)
    }

    // MARK: - Helpers

    private static func label(of attribution: TurnAttribution) -> String {
        switch attribution {
        case .prompted: "prompted"
        case .relocation: "relocation"
        case .unprompted: "unprompted"
        }
    }

    private static func promptedUUID(of attribution: TurnAttribution) -> String? {
        if case .prompted(let uuid) = attribution { return uuid }
        return nil
    }

    /// The uuids of the prompts the host wrote, in recording order — the other side of the attribution.
    private static func promptUUIDs(of fixture: FixtureCorpus.Fixture) throws -> [String] {
        try fixture.frames().filter { $0.direction == "in" }.compactMap { recorded in
            if case .user(let user) = recorded.frame { user.uuid } else { nil }
        }
    }

    private static func synthesised(in reducer: WireReducer) -> [TaskRunItem] {
        reducer.durable.items.compactMap {
            if case .taskRun(let run) = $0, run.synthesised { run } else { nil }
        }
    }

    private static func text(of blocks: [ContentBlock]) -> String {
        blocks.compactMap { if case .text(let block) = $0 { block.fields.text } else { nil } }.joined()
    }

    /// A canonical hash, so a failure prints a shape and never a recorded sentence (C3 constraint 12).
    private static func hash(_ text: String) -> String {
        String(RecordDecoder.canonicalHash(of: .string(text)).prefix(12))
    }

    /// The compared half of a projection as identifiers and hashes: the categories `ProjectionCategories`
    /// names, with content reduced to a hash of the blocks minus the opaque thinking signature.
    private static func digest(_ items: [TimelineItem]) -> [String] {
        items.filter { ProjectionCategories.comparedWireToFile.contains($0.category) }.map { item in
            switch item {
            case .userMessage(let i): "user|\(i.id.key)|\(blocksHash(i.blocks))"
            case .assistantMessage(let i):
                "assistant|\(i.id.key)|\(i.model ?? "-")|\(i.recordUUIDs.joined(separator: "+"))|\(blocksHash(i.blocks))"
            case .toolCall(let i): "tool|\(i.toolUseID)|\(i.name)|\(i.status.rawValue)|\(i.denialKind ?? "-")"
            case .peerMessage(let i): "peer|\(i.id.key)|\(i.originKind)|\(blocksHash(i.blocks))"
            case .sentFile(let i): "sentFile|\(i.toolUseID)|\(i.files.count)|\(i.delivered.map(String.init) ?? "-")"
            case .taskRun(let i): "taskRun|\(i.taskID)|\(i.status.rawValue)|\(i.synthesised)"
            default: "\(item.category.rawValue)|\(item.id.key)"
            }
        }
    }

    private static func blocksHash(_ blocks: [ContentBlock]) -> String {
        guard let data = try? JSONEncoder().encode(blocks),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return "?" }
        return String(RecordDecoder.canonicalHash(of: withoutSignatures(value)).prefix(12))
    }

    private static func withoutSignatures(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, child) in object where key != "signature" { out[key] = withoutSignatures(child) }
            return .object(out)
        case .array(let array):
            return .array(array.map(withoutSignatures))
        default:
            return value
        }
    }

    /// The same walk with no seed, for the counter-case.
    private static func replayWithoutSeed(_ fixture: FixtureCorpus.Fixture) throws -> WireReducer {
        let stream = LogicalStream(configHome: FixtureCorpus.recordedConfigHome,
                                   sessionID: fixture.sessionID, name: .main)
        var reducer = WireReducer(stream: stream, slug: try FixtureWireReplay.slug(of: fixture))
        for step in try FixtureWireReplay.steps(for: fixture) { FixtureWireReplay.apply(step, to: &reducer) }
        return reducer
    }
}
