import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// The primary reducer over the committed recordings. Every assertion is over a recorded fixture or a named in-memory
/// mutation of one; nothing here writes, and no fixture byte is compared against a literal (C3 constraints).
final class RecordReducerTests: XCTestCase {

    // MARK: - The corpus

    /// Every main stream of every *recorded* fixture reduces to one chain: no branch, no orphan, and exactly as many
    /// rendered messages as the file has non-tool-result, non-meta `user` records — counted here by a walk of the
    /// records that shares no code with the reducer, so the two sides are a real comparison.
    ///
    /// The two synthetic fixtures are excluded and the exclusion is the point: `dialog-fable-overage` and
    /// `dialog-refusal-fallback` carry placeholder transcripts in which no record has a `parentUuid` at all, so every
    /// record is its own root. That is the engine's own "unchained transcript" shape (2.1.258 `warnIfTranscriptUnchained`,
    /// line 432626), not a conversation, and the corpus census names both files synthetic.
    func testEveryMainStreamReducesToOneChainWithNoBranchesOnTheCorpus() throws {
        var mainFiles = 0
        var totalMessages = 0
        for fixture in try FixtureCorpus.all() where !fixture.synthetic {
            for (stream, kind, url) in try fixture.transcriptFiles() {
                guard case .mainTranscript = kind else { continue }
                mainFiles += 1
                let records = try TranscriptReader(url: url).readAll().records
                let projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)

                XCTAssertEqual(projection.branches, [], "\(fixture.name): a main stream must reduce to one chain")
                XCTAssertEqual(projection.warnings.filter { $0.kind == .orphanHealed || $0.kind == .orphanUnhealed }, [],
                               "\(fixture.name): a main stream must carry no orphan")

                let rendered = projection.items.filter { $0.category == .userMessage || $0.category == .peerMessage }.count
                XCTAssertEqual(rendered, Self.promptRecordCount(records),
                               "\(fixture.name): rendered messages must equal the file's prompt records")
                totalMessages += rendered
            }
        }
        XCTAssertEqual(mainFiles, 15, "the corpus has fifteen recorded main transcripts")
        XCTAssertEqual(totalMessages, 30, "the recorded main transcripts carry thirty prompt records in all")
    }

    /// `plain-two-turn` has four assistant records in two `message.id` pairs, so two items; their `recordUUIDs`
    /// together are exactly the file's assistant uuids, and each item carries its pair's `message.id`.
    func testAssistantRecordsMergeByMessageID() throws {
        let (records, stream, url) = try Self.mainStream(of: "plain-two-turn")
        let projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)

        let merged: [AssistantMessageItem] = projection.items.compactMap {
            if case .assistantMessage(let item) = $0 { item } else { nil }
        }
        XCTAssertEqual(merged.count, 2)

        var assistantUUIDs: Set<String> = []
        var messageIDs: [String] = []
        for record in records {
            guard case .assistant(let assistant) = record else { continue }
            assistantUUIDs.insert(assistant.fields.uuid)
            if let id = assistant.fields.message.fields.id, !messageIDs.contains(id) { messageIDs.append(id) }
        }
        XCTAssertEqual(Set(merged.flatMap(\.recordUUIDs)), assistantUUIDs)
        XCTAssertEqual(merged.compactMap(\.messageID), messageIDs)
        XCTAssertEqual(merged.map { $0.id.key }, merged.map { $0.recordUUIDs[0] }, "the item's key is the first record's uuid")
    }

    /// Results join their calls: the recorded `Bash`, the recorded `Agent`s, and — corpus-wide — every tool use the
    /// leaf chain reaches, with its status decided by the joined result and by nothing else.
    func testToolCallsJoinTheirResults() throws {
        let (shellRecords, shellStream, shellURL) = try Self.mainStream(of: "background-shell")
        let shell = RecordReducer.reduce(shellRecords, stream: shellStream, sourceFile: shellURL)
        let bash = try XCTUnwrap(Self.toolCalls(shell).first { $0.name == "Bash" })
        XCTAssertEqual(bash.status, .completed)
        XCTAssertNotNil(bash.structuredResult, "toolUseResult is the structured half of the join")
        XCTAssertTrue((bash.result?.stringValue ?? "").contains("<artifacts>"),
                      "the background shell's result names the artifact token")

        let (nestedRecords, nestedStream, nestedURL) = try Self.mainStream(of: "nested-depth-2")
        let nested = RecordReducer.reduce(nestedRecords, stream: nestedStream, sourceFile: nestedURL)
        let agents = Self.toolCalls(nested).filter { $0.name == "Agent" }
        XCTAssertFalse(agents.isEmpty)
        XCTAssertEqual(Set(agents.map(\.status)), [.completed])

        // Corpus-wide. The file walk below shares no code with the reducer: it collects each file's tool-use ids, the
        // ids some `tool_result` block answers, and the leaf chain, and the reducer is held against all three.
        var projectedTotal = 0, completed = 0, denied = 0, failed = 0, running = 0
        for fixture in try FixtureCorpus.all() where !fixture.synthetic {
            for (stream, _, url) in try fixture.transcriptFiles() {
                let records = try TranscriptReader(url: url).readAll().records
                let walk = Self.toolWalk(records)
                guard !walk.opened.isEmpty else { continue }
                let projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)

                let projected = Set(Self.toolCalls(projection).map(\.toolUseID))
                    .union(Self.sentFiles(projection).map(\.toolUseID))
                let reachable = Set(walk.opened.filter { walk.chain.contains($0.value) }.map(\.key))
                XCTAssertEqual(projected, reachable,
                               "\(fixture.name)/\(stream.name.label): the projection opens exactly the chain's tool uses")

                // `walk.answered` is every id some `tool_result` block names anywhere in the file, on the leaf path or
                // off it, because a result completes its call wherever its record lies. So a projected call is open
                // exactly when the file holds no result for it at all.
                let open = Set(Self.toolCalls(projection).filter { $0.status == .running }.map(\.toolUseID))
                    .union(Self.sentFiles(projection).filter { $0.delivered == nil }.map(\.toolUseID))
                XCTAssertEqual(open, projected.subtracting(walk.answered),
                               "\(fixture.name)/\(stream.name.label): a call is open exactly when no result answers it")

                projectedTotal += projected.count
                for call in Self.toolCalls(projection) {
                    switch call.status {
                    case .completed: completed += 1
                    case .denied: denied += 1
                    case .failed: failed += 1
                    case .running: running += 1
                    }
                }
            }
        }
        // Grounded by the walk above: 26 tool uses on disk, 2 of them on the two agent files' off-chain parallel
        // branch, so 24 reach the projection — 23 tool cards and the one `send_user_file`. The off-chain result join
        // leaves these totals where they were, and that is a corpus fact rather than a coincidence: the corpus's only
        // two off-chain results answer those same two off-chain calls, so no on-chain call was ever left open by the
        // chain-only reading. `testAnOffChainToolResultStillCompletesItsCall_mutation` is what discriminates the rule.
        XCTAssertEqual(projectedTotal, 24)
        XCTAssertEqual([completed, denied, failed, running], [22, 1, 0, 0],
                       "every recorded call is answered; only permission-deny's is denied")
    }

    /// The one MCP tool whose call is an item of its own: `send-user-file` yields a `sentFile` and no tool card for it.
    func testSentFileItemsComeFromTheMCPToolRecords() throws {
        let (records, stream, url) = try Self.mainStream(of: "send-user-file")
        let projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)

        let sent = Self.sentFiles(projection)
        XCTAssertEqual(sent.count, 1)
        // The plan pinned `files.count == 1`; the recording carries two names in `input.files`, and the corpus wins.
        XCTAssertEqual(sent[0].files.count, 2)
        XCTAssertNotNil(sent[0].caption)
        XCTAssertEqual(sent[0].delivered, true)
        XCTAssertEqual(Self.toolCalls(projection).filter { $0.name == ItemBuilder.sendUserFileTool }, [])
    }

    /// Meta users and attachments are hidden, not rendered: `session-mirror-relocation` carries one `isMeta` user and
    /// fifteen attachments, and none of them reaches the timeline.
    func testMetaUsersAndAttachmentsAreHidden() throws {
        let (records, stream, url) = try Self.mainStream(of: "session-mirror-relocation")
        let projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)

        let metaUUIDs = Set(records.compactMap { record -> String? in
            guard case .user(let user) = record, user.fields.isMeta == true else { return nil }
            return user.fields.uuid
        })
        let attachmentUUIDs = Set(records.compactMap { record -> String? in
            guard case .attachment(let attachment) = record else { return nil }
            return attachment.fields.uuid
        })
        XCTAssertEqual(metaUUIDs.count, 1)
        XCTAssertEqual(attachmentUUIDs.count, 15)

        func hiddenUUIDs(_ reason: HiddenRecord.Reason) -> Set<String> {
            Set(projection.hidden.filter { $0.reason == reason }.compactMap {
                if case .uuid(let uuid) = $0.key.identity { uuid } else { nil }
            })
        }
        XCTAssertEqual(hiddenUUIDs(.isMeta), metaUUIDs)
        XCTAssertEqual(hiddenUUIDs(.attachment), attachmentUUIDs)

        let renderedUUIDs = Set(projection.items.map { $0.id.key })
        XCTAssertTrue(renderedUUIDs.isDisjoint(with: metaUUIDs.union(attachmentUUIDs)))
    }

    /// The chain ends where the last `last-prompt` says it does. The second half moves that `leafUuid` back to the
    /// first assistant record — the rewind shape, which no recording carries — and the tail becomes one `Branch`.
    func testLeafSelectionFollowsLastPrompt() throws {
        let (records, stream, url) = try Self.mainStream(of: "plain-two-turn")
        let recordedLeaf = try XCTUnwrap(Self.lastPromptLeaf(records))
        let projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)
        XCTAssertEqual(projection.session.leaf, recordedLeaf)
        guard case .assistantMessage(let last) = try XCTUnwrap(projection.items.last) else {
            return XCTFail("the recorded chain ends in an assistant message")
        }
        XCTAssertTrue(last.recordUUIDs.contains(recordedLeaf))

        let firstAssistant = try XCTUnwrap(records.compactMap { record -> String? in
            guard case .assistant(let assistant) = record else { return nil }
            return assistant.fields.uuid
        }.first)
        let promptIndex = try XCTUnwrap(records.lastIndex { record in
            guard case .sessionState(let state, _) = record else { return false }
            return state.fields.type == "last-prompt"
        })
        var rewound = records
        rewound[promptIndex] = try Breaks.setting(path: "leafUuid", in: records[promptIndex], to: .string(firstAssistant))

        let after = RecordReducer.reduce(rewound, stream: stream, sourceFile: url)
        XCTAssertEqual(after.session.leaf, firstAssistant)
        XCTAssertEqual(after.items.last?.id.key, firstAssistant)
        XCTAssertEqual(after.branches.count, 1)
        XCTAssertEqual(after.branches.first?.tail, recordedLeaf)
        XCTAssertEqual(after.branches.first?.count, 6, "six conversation records fall off the shortened chain")
    }

    /// `leafUuid: null` with `explicit: true` is the engine's *cleared to empty* (parity §35.4). `control-shapes`
    /// records the shape, but not as its file's last `last-prompt` — a further prompt carrying no `leafUuid` follows
    /// it — so the clear never decides that file's leaf. The path where it does is unwitnessed, and reaching it means
    /// clearing the recorded `last-prompt` of a file that ends on one.
    func testClearedToEmptyProducesAnEmptyProjection_mutation() throws {
        let (records, stream, url) = try Self.mainStream(of: "plain-two-turn")
        let promptIndex = try XCTUnwrap(records.lastIndex { record in
            guard case .sessionState(let state, _) = record else { return false }
            return state.fields.type == "last-prompt"
        })
        var cleared = records
        cleared[promptIndex] = try Breaks.setting(path: "leafUuid", in: records[promptIndex], to: .null)
        cleared[promptIndex] = try Breaks.setting(path: "explicit", in: cleared[promptIndex], to: .bool(true))

        let projection = RecordReducer.reduce(cleared, stream: stream, sourceFile: url)
        XCTAssertEqual(projection.items, [])
        XCTAssertTrue(projection.session.clearedToEmpty)
        XCTAssertNil(projection.session.leaf)
    }

    /// Rule 2's `rewound` clause. `control-shapes` writes four `last-prompt` records; the third carries
    /// `"rewound": true` and the fourth is silent about it, so the fact only survives as a latch — a rewind is
    /// something that happened, not a current state. `plain-two-turn` records no rewind anywhere and is the half that
    /// stops the assertion being a constant.
    func testRewoundIsLatchedOntoTheSessionState() throws {
        let (shapes, shapesStream, shapesURL) = try Self.mainStream(of: "control-shapes")
        let recorded = shapes.filter { record in
            guard case .sessionState(let state, _) = record else { return false }
            return state.fields.type == "last-prompt" && state.rewound
        }
        XCTAssertEqual(recorded.count, 1, "control-shapes records the rewind on exactly one of its last-prompt records")
        XCTAssertTrue(RecordReducer.reduce(shapes, stream: shapesStream, sourceFile: shapesURL).session.rewound)

        let (plain, plainStream, plainURL) = try Self.mainStream(of: "plain-two-turn")
        XCTAssertFalse(plain.contains { record in
            guard case .sessionState(let state, _) = record else { return false }
            return state.fields.type == "last-prompt" && state.rewound
        }, "plain-two-turn records no rewind")
        XCTAssertFalse(RecordReducer.reduce(plain, stream: plainStream, sourceFile: plainURL).session.rewound)
    }

    /// A `tool_result` completes its call by `tool_use_id` wherever its record lies: rule 4 decides which records
    /// produce items, and a result produces none — it completes an item another record already made. No recording
    /// carries an on-chain call whose only result is off-chain (checked: the corpus's two off-chain results answer
    /// off-chain calls), so the path is reached by naming an earlier leaf, which drops `background-shell`'s recorded
    /// result record off the chain while leaving the `Bash` call on it.
    func testAnOffChainToolResultStillCompletesItsCall_mutation() throws {
        let (records, stream, url) = try Self.mainStream(of: "background-shell")
        let opener = try XCTUnwrap(records.compactMap { record -> String? in
            guard case .assistant(let assistant) = record else { return nil }
            let opens = assistant.fields.message.fields.content.contains { if case .toolUse = $0 { true } else { false } }
            return opens ? assistant.fields.uuid : nil
        }.first, "background-shell's main transcript opens a tool call")
        let promptIndex = try XCTUnwrap(records.lastIndex { record in
            guard case .sessionState(let state, _) = record else { return false }
            return state.fields.type == "last-prompt"
        })
        var shortened = records
        shortened[promptIndex] = try Breaks.setting(path: "leafUuid", in: records[promptIndex], to: .string(opener))

        let projection = RecordReducer.reduce(shortened, stream: stream, sourceFile: url)
        XCTAssertEqual(projection.session.leaf, opener)
        let call = try XCTUnwrap(Self.toolCalls(projection).first { $0.name == "Bash" })
        XCTAssertEqual(call.status, .completed, "the result record is off the chain and still completes its call")
        XCTAssertNotNil(call.structuredResult)
        let answering = try XCTUnwrap(records.compactMap { record -> String? in
            guard case .user(let user) = record, case .blocks(let blocks) = user.fields.message.fields.content,
                  blocks.contains(where: { if case .toolResult = $0 { true } else { false } }) else { return nil }
            return user.fields.uuid
        }.first)
        XCTAssertTrue(projection.branches.contains { $0.head == answering },
                      "the answering record really did leave the chain")
        XCTAssertFalse(projection.items.contains { $0.id.key == answering },
                       "an off-chain record still produces no item of its own")
    }

    /// `continued-in` names its *destination* in `continuedInSessionId`; the record's own `sessionId` is this file's
    /// and is never the answer. Schema-derived — no fixture carries the kind — so Task 1's invented line is appended.
    func testContinuedInSetsSessionStateFromTheDestinationId_mutation() throws {
        let (records, stream, url) = try Self.mainStream(of: "plain-two-turn")
        let before = RecordReducer.reduce(records, stream: stream, sourceFile: url)

        let source = "11111111-1111-4111-8111-111111111111"
        let destination = "22222222-2222-4222-8222-222222222222"
        let line = #"{"type":"continued-in","timestamp":"2026-09-05T00:00:00.000Z","sessionId":"\#(source)","continuedInSessionId":"\#(destination)"}"#
        let continued = RecordDecoder.decode(line: Data(line.utf8))
        let after = RecordReducer.reduce(records + [continued], stream: stream, sourceFile: url)

        XCTAssertEqual(after.session.continuedIn, destination)
        XCTAssertNotEqual(after.session.continuedIn, source, "the source id is this file's own and is never read here")
        XCTAssertEqual(after.items, before.items, "a session-state record renders nothing")
        let hidden = try XCTUnwrap(after.hidden.first { $0.kind == "continued-in" })
        XCTAssertEqual(hidden.reason, .sessionState)
    }

    /// An orphan attaches to the nearest earlier record with the same `isSidechain` inside the heal window. Deleting a
    /// recorded assistant record from the middle of `plain-two-turn` orphans its child; no recording carries a gap.
    func testAnOrphanIsHealedToTheNearestEarlierRecord_mutation() throws {
        let (records, stream, url) = try Self.mainStream(of: "plain-two-turn")
        let leaf = try XCTUnwrap(Self.lastPromptLeaf(records))
        let leafParent = try XCTUnwrap(records.compactMap { record -> String? in
            guard record.uuid == leaf else { return nil }
            return WindowedTranscript.parentUUID(of: record)
        }.first)
        let deleted = try XCTUnwrap(records.firstIndex { $0.uuid == leafParent })
        let expectedHost = try XCTUnwrap(records[..<deleted].last { $0.isConversation }?.uuid)

        let broken = Breaks.dropping(recordAt: deleted, from: records)
        let projection = RecordReducer.reduce(broken, stream: stream, sourceFile: url)

        XCTAssertEqual(projection.warnings.filter { $0.kind == .orphanHealed }.count, 1)
        XCTAssertEqual(projection.warnings.filter { $0.kind == .orphanUnhealed }, [])
        XCTAssertEqual(projection.branches, [], "a healed orphan rejoins the one chain")

        let tree = ConversationTree(conversation: broken.filter(\.isConversation), healWindow: 5)
        XCTAssertEqual(tree.healed, [leaf])
        XCTAssertEqual(Array(tree.chain(to: leaf).suffix(2)), [expectedHost, leaf])
        XCTAssertTrue(projection.items.contains { $0.id.key == leaf })
    }

    /// `supersedes` on a later assistant record retracts the items the named uuids key. No recording carries the field.
    func testSupersedesRetractsItems_mutation() throws {
        let (records, stream, url) = try Self.mainStream(of: "plain-two-turn")
        let assistantUUIDs = records.compactMap { record -> String? in
            guard case .assistant(let assistant) = record else { return nil }
            return assistant.fields.uuid
        }
        let retracted = try XCTUnwrap(assistantUUIDs.first)
        let lastIndex = try XCTUnwrap(records.lastIndex { record in
            guard case .assistant = record else { return false }
            return true
        })
        var mutated = records
        mutated[lastIndex] = try Breaks.setting(path: "supersedes", in: records[lastIndex], to: .array([.string(retracted)]))

        let before = RecordReducer.reduce(records, stream: stream, sourceFile: url)
        let after = RecordReducer.reduce(mutated, stream: stream, sourceFile: url)
        XCTAssertTrue(before.items.contains { $0.id.key == retracted })
        XCTAssertFalse(after.items.contains { $0.id.key == retracted }, "the named item is gone")
        XCTAssertEqual(after.items.count, before.items.count - 1)
    }

    /// A `compact_boundary` with neither a preserved segment nor preserved messages is a hard truncation point: the
    /// boundary becomes the first item and what came before it is dropped. No fixture carries a `system` record, so a
    /// recorded attachment on the chain is renamed into one.
    func testCompactBoundaryHardTruncates_mutation() throws {
        let (records, stream, url) = try Self.mainStream(of: "plain-two-turn")
        let lastPrompt = try XCTUnwrap(records.last { record in
            guard case .user(let user) = record, user.fields.isMeta != true else { return false }
            if case .blocks(let blocks) = user.fields.message.fields.content {
                return !blocks.contains { if case .toolResult = $0 { true } else { false } }
            }
            return true
        })
        let boundaryUUID = try XCTUnwrap(WindowedTranscript.parentUUID(of: lastPrompt))
        let boundaryIndex = try XCTUnwrap(records.firstIndex { $0.uuid == boundaryUUID })

        var mutated = records
        mutated[boundaryIndex] = try Breaks.setting(path: "type", in: records[boundaryIndex], to: .string("system"))
        mutated[boundaryIndex] = try Breaks.setting(path: "subtype", in: mutated[boundaryIndex], to: .string("compact_boundary"))

        let projection = RecordReducer.reduce(mutated, stream: stream, sourceFile: url)
        guard case .compactBoundary(let boundary) = try XCTUnwrap(projection.items.first) else {
            return XCTFail("a hard boundary is the projection's first item")
        }
        XCTAssertTrue(boundary.hardTruncation)
        XCTAssertEqual(boundary.id.key, boundaryUUID)
        XCTAssertEqual(projection.items.map(\.category), [.compactBoundary, .userMessage, .assistantMessage],
                       "only the boundary and the last exchange remain")
    }

    /// `nested-depth-2` merges into one line: the depth-1 agent's run under the main stream's `Agent` call, and the
    /// depth-2 agent's run under the call the depth-1 agent itself made.
    func testMergeAttachesAgentItemsUnderTheirSpawningCall() throws {
        let fixture = try FixtureCorpus.named("nested-depth-2")
        var metadataByStream: [LogicalStream: AgentMetadataRecord] = [:]
        for (stream, url) in try fixture.metaFiles() {
            metadataByStream[stream] = try JSONDecoder().decode(AgentMetadataRecord.self, from: try Data(contentsOf: url))
        }
        var main: LogicalStream?
        var projections: [StreamProjection] = []
        for (stream, kind, url) in try fixture.transcriptFiles() {
            let records = try TranscriptReader(url: url).readAll().records
            var projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)
            projection.metadata = metadataByStream[stream]
            if case .mainTranscript = kind { main = stream }
            projections.append(projection)
        }
        let durable = RecordReducer.merge(projections, main: try XCTUnwrap(main))

        let runs: [TaskRunItem] = durable.items.compactMap { if case .taskRun(let run) = $0 { run } else { nil } }
        XCTAssertEqual(runs.map(\.agentType), ["general-purpose", "Explore"])
        XCTAssertEqual(runs.map(\.depth), [1, 2])
        XCTAssertEqual(runs.map(\.synthesised), [false, false])
        XCTAssertEqual(runs.map(\.kind), [.localAgent, .localAgent])

        let depthTwo = runs[1]
        XCTAssertEqual(depthTwo.provenance.agentID, depthTwo.taskID)
        XCTAssertEqual(durable.items.compactMap { $0.provenance.agentID }.contains(depthTwo.taskID), true)

        func index(ofToolUse id: String) throws -> Int {
            try XCTUnwrap(durable.items.firstIndex {
                if case .toolCall(let call) = $0 { call.toolUseID == id } else { false }
            })
        }
        func index(ofRun run: TaskRunItem) throws -> Int {
            try XCTUnwrap(durable.items.firstIndex { $0.id == run.id })
        }
        let depthOneCall = try index(ofToolUse: try XCTUnwrap(runs[0].toolUseID))
        let depthTwoCall = try index(ofToolUse: try XCTUnwrap(runs[1].toolUseID))
        XCTAssertLessThan(depthOneCall, try index(ofRun: runs[0]))
        XCTAssertLessThan(try index(ofRun: runs[0]), depthTwoCall)
        XCTAssertLessThan(depthTwoCall, try index(ofRun: runs[1]))

        let agentItems = durable.items.filter { $0.provenance.agentID == depthTwo.taskID && $0.category != .taskRun }
        XCTAssertFalse(agentItems.isEmpty)
        for item in agentItems {
            XCTAssertGreaterThan(try XCTUnwrap(durable.items.firstIndex { $0.id == item.id }), depthOneCall)
        }
    }

    /// Every hidden record names why it is hidden and where its bytes lie, and the locator really addresses them:
    /// each attachment's range reads back as that attachment's own JSON.
    func testHiddenRecordsCarryReasonsAndLocators() throws {
        let (_, stream, url) = try Self.mainStream(of: "plain-two-turn")
        let reader = TranscriptReader(url: url)
        let read = try reader.readAll()
        let keys = RecordKey.keys(for: read.records, in: stream)
        var options = RecordReducer.Options()
        for (key, range) in zip(keys, read.ranges) { options.locators[key] = RecordLocator(stream: stream, range: range) }

        let projection = RecordReducer.reduce(read.records, stream: stream, sourceFile: url, options: options)
        let durable = RecordReducer.merge([projection], main: stream)

        // Independent walk: every attachment, every session-state kind, every meta user is a hidden record.
        let expected = read.records.filter { record in
            record.kind == "attachment" || record.kind == "progress"
                || SessionStateVocabulary.kinds[record.kind] != nil
                || { if case .user(let u) = record { u.fields.isMeta == true } else { false } }()
        }
        XCTAssertEqual(projection.hidden.count, expected.count)
        XCTAssertEqual(projection.hidden.count, 25, "eleven attachments and fourteen session-state records")
        XCTAssertEqual(Set(projection.hidden.map(\.kind)), Set(expected.map(\.kind)))

        for (record, key) in zip(read.records, keys) where record.kind == "attachment" {
            let entry = try XCTUnwrap(durable.hidden(key), "every attachment is found by its key")
            XCTAssertEqual(entry.reason, .attachment)
            let locator = try XCTUnwrap(entry.locator)
            let bytes = try reader.read(at: locator.range.offset, length: locator.range.length)
            let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
            XCTAssertEqual(value["type"]?.stringValue, "attachment")
            XCTAssertEqual(value["uuid"]?.stringValue, record.uuid)
        }
    }

    /// Under an open window the first record whose parent lies before the window is a window root, not an orphan, and
    /// the projection of the suffix is the tail of the whole file's. The same suffix read as a closed window is the
    /// discriminating half: there the missing parent really is a loss, and it warns.
    func testWindowRootsAreNotOrphans() throws {
        let (_, stream, url) = try Self.mainStream(of: "nested-depth-2")
        let read = try TranscriptReader(url: url).readAll()
        let cut = try XCTUnwrap(read.records.indices.dropFirst().first { index in
            WindowedTranscript.isTurnStart(read.records[index])
                && WindowedTranscript.parentUUID(of: read.records[index]) != nil
        })
        let suffix = Array(read.records[cut...])

        var open = RecordReducer.Options()
        open.window = WindowMarker(earlierAvailable: true, continueBefore: read.ranges[cut].offset)
        let windowed = RecordReducer.reduce(suffix, stream: stream, sourceFile: url, options: open)
        XCTAssertEqual(windowed.warnings.filter { $0.kind == .orphanHealed || $0.kind == .orphanUnhealed }, [])
        XCTAssertEqual(windowed.branches, [])

        let whole = RecordReducer.reduce(read.records, stream: stream, sourceFile: url)
        let start = try XCTUnwrap(whole.items.firstIndex { $0.id.key == read.records[cut].uuid })
        XCTAssertEqual(windowed.items, Array(whole.items[start...]),
                       "the window's items are exactly the tail of the whole file's")

        let closed = RecordReducer.reduce(suffix, stream: stream, sourceFile: url)
        XCTAssertEqual(closed.warnings.filter { $0.kind == .orphanUnhealed }.count, 1,
                       "without the marker the same missing parent is an unhealable orphan")
    }

    /// A `tool_result` whose block id names no open call joins by `sourceToolAssistantUUID`. Unwitnessed on the corpus:
    /// every recorded result's block id matches, so the fallback is reached only by replacing that id with one that
    /// matches nothing. It cannot be *removed* instead — `ToolResultBlockFields.toolUseID` is a required `String`
    /// (`MessageFrames.swift:22`), so a stripped id makes the record undecodable and never reaches the join at all.
    func testToolResultWithAnUnmatchedBlockIDJoinsBySourceAssistantUUID_mutation() throws {
        var located: (fixture: String, stream: LogicalStream, url: URL, records: [TranscriptRecord], index: Int)?
        outer: for fixture in try FixtureCorpus.all() where !fixture.synthetic {
            for (stream, _, url) in try fixture.transcriptFiles() {
                let records = try TranscriptReader(url: url).readAll().records
                for (index, record) in records.enumerated() {
                    guard case .user(let user) = record, user.fields.sourceToolAssistantUUID != nil,
                          case .blocks(let blocks) = user.fields.message.fields.content,
                          blocks.contains(where: { if case .toolResult = $0 { true } else { false } }) else { continue }
                    located = (fixture.name, stream, url, records, index)
                    break outer
                }
            }
        }
        let found = try XCTUnwrap(located, "the corpus must carry a tool result naming its source assistant record")
        XCTAssertEqual(found.fixture, "ask-user-question", "the first such record, in fixture-name order")

        guard case .user(let user) = found.records[found.index] else { return XCTFail("located a user record") }
        let sourceAssistant = try XCTUnwrap(user.fields.sourceToolAssistantUUID)
        var mutated = found.records
        mutated[found.index] = try Breaks.setting(path: "message.content.0.tool_use_id", in: found.records[found.index],
                                                  to: .string("toolu_00000000000000000000000"))

        // The ids that record's own blocks opened, walked off the records: the item's `threadParent` is the *merged*
        // assistant item's key, which is the run's first record and need not be this one.
        let openedThere = found.records.compactMap { record -> [String]? in
            guard case .assistant(let assistant) = record, assistant.fields.uuid == sourceAssistant else { return nil }
            return assistant.fields.message.fields.content.compactMap {
                if case .toolUse(let use) = $0 { use.fields.id } else { nil }
            }
        }.flatMap { $0 }
        XCTAssertEqual(openedThere.count, 1, "the source assistant record opened exactly one call")

        let projection = RecordReducer.reduce(mutated, stream: found.stream, sourceFile: found.url)
        let call = try XCTUnwrap(Self.toolCalls(projection).first { $0.toolUseID == openedThere[0] })
        XCTAssertEqual(call.status, .completed, "the fallback completed the call the block id no longer names")
        XCTAssertNotEqual(call.toolUseID, "toolu_00000000000000000000000",
                          "the call is the recorded one, joined by the assistant record and not by the block id")
    }

    // MARK: - Helpers

    private static func mainStream(of name: String) throws -> ([TranscriptRecord], LogicalStream, URL) {
        let fixture = try FixtureCorpus.named(name)
        for (stream, kind, url) in try fixture.transcriptFiles() {
            guard case .mainTranscript = kind else { continue }
            return (try TranscriptReader(url: url).readAll().records, stream, url)
        }
        throw FixtureCorpus.Failure("fixture \(name) has no main transcript")
    }

    private static func toolCalls(_ projection: StreamProjection) -> [ToolCallItem] {
        projection.items.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
    }

    private static func sentFiles(_ projection: StreamProjection) -> [SentFileItem] {
        projection.items.compactMap { if case .sentFile(let sent) = $0 { sent } else { nil } }
    }

    private static func lastPromptLeaf(_ records: [TranscriptRecord]) -> String? {
        for record in records.reversed() {
            guard case .sessionState(let state, _) = record, state.fields.type == "last-prompt" else { continue }
            if let value = state.leafUuid { return value }
            return nil
        }
        return nil
    }

    /// A `user` record the timeline renders: not `isMeta`, not a bare carrier of tool results. Written here from the
    /// records, deliberately sharing nothing with the reducer.
    private static func promptRecordCount(_ records: [TranscriptRecord]) -> Int {
        records.reduce(into: 0) { total, record in
            guard case .user(let user) = record, user.fields.isMeta != true else { return }
            if case .blocks(let blocks) = user.fields.message.fields.content,
               blocks.contains(where: { if case .toolResult = $0 { true } else { false } }) { return }
            total += 1
        }
    }

    /// Tool-use id → the uuid of the assistant record that opened it, the ids some result answers, and the leaf chain,
    /// all walked straight off the records.
    private static func toolWalk(_ records: [TranscriptRecord]) -> (opened: [String: String], answered: Set<String>, chain: Set<String>) {
        var opened: [String: String] = [:]
        var answered: Set<String> = []
        var byUUID: [String: TranscriptRecord] = [:]
        for record in records {
            if let uuid = record.uuid { byUUID[uuid] = record }
            switch record {
            case .assistant(let assistant):
                for block in assistant.fields.message.fields.content {
                    if case .toolUse(let use) = block { opened[use.fields.id] = assistant.fields.uuid }
                }
            case .user(let user):
                if case .blocks(let blocks) = user.fields.message.fields.content {
                    for block in blocks { if case .toolResult(let result) = block { answered.insert(result.fields.toolUseID) } }
                }
            default:
                break
            }
        }
        var cursor = lastPromptLeaf(records) ?? records.last(where: \.isConversation)?.uuid
        var chain: Set<String> = []
        while let uuid = cursor, byUUID[uuid] != nil, !chain.contains(uuid) {
            chain.insert(uuid)
            cursor = byUUID[uuid].flatMap(WindowedTranscript.parentUUID(of:))
        }
        return (opened, answered, chain)
    }
}
