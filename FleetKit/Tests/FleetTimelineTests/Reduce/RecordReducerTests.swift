import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// The primary reducer over the committed recordings. Every assertion is over a recorded fixture or a named in-memory
/// mutation of one; nothing here writes, and no fixture byte is compared against a literal (C3 constraints).
final class RecordReducerTests: XCTestCase {

    // MARK: - The corpus

    /// Every main stream of every *recorded* fixture reduces to one rendered chain, and the chains it does not render
    /// are named one by one. This is the first witness of the child spec's leaf-path ruling (human-gate question 1,
    /// decided "leaf path, with branches kept for a later affordance"): until `rewind-turn` and `compact-boundary`
    /// joined the corpus, no recording held a chain the leaf excludes, so the ruling had nothing to be right about.
    /// Both now do — each carries the same abandoned turn, three records the honoured rewind left below the leaf —
    /// and the census below states each one by fixture name and record count rather than asserting an empty set.
    ///
    /// The rendered-message clause is the ruling's other half: rendered messages equal the file's prompt records
    /// *on the leaf path*, so the prompt that lies on an abandoned branch is subtracted. The walk that counts them
    /// shares no code with the reducer, so the two sides are a real comparison.
    ///
    /// The two synthetic fixtures are excluded and the exclusion is the point: `dialog-fable-overage` and
    /// `dialog-refusal-fallback` carry placeholder transcripts in which no record has a `parentUuid` at all, so every
    /// record is its own root. That is the engine's own "unchained transcript" shape (2.1.258 `warnIfTranscriptUnchained`,
    /// line 432626), not a conversation, and the corpus census names both files synthetic.
    func testEveryMainStreamReducesToOneChainWithNoBranchesOnTheCorpus() throws {
        var mainFiles = 0
        var totalMessages = 0
        var census: [String: [Int]] = [:]
        for fixture in try FixtureCorpus.all() where !fixture.synthetic {
            for (stream, kind, url) in try fixture.transcriptFiles() {
                guard case .mainTranscript = kind else { continue }
                mainFiles += 1
                let records = try TranscriptReader(url: url).readAll().records
                let projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)

                if !projection.branches.isEmpty { census[fixture.name] = projection.branches.map(\.count) }
                XCTAssertEqual(projection.warnings.filter { $0.kind == .orphanHealed || $0.kind == .orphanUnhealed }, [],
                               "\(fixture.name): a main stream must carry no orphan")

                let rendered = projection.items.filter { $0.category == .userMessage || $0.category == .peerMessage }.count
                XCTAssertEqual(rendered, Self.promptRecordCount(records, on: Self.leafChain(records)),
                               "\(fixture.name): rendered messages must equal the file's prompt records on the leaf path")
                totalMessages += rendered
            }
        }
        XCTAssertEqual(mainFiles, 17, "the corpus has seventeen recorded main transcripts")
        // Every branch in the corpus, by fixture and by records per branch. `rewind-turn` records the rewind that
        // made the branch; `compact-boundary` resumes that same session, so its file inherits the same three records.
        // Every other recorded main stream is one chain, which the equality states by their absence from the census.
        XCTAssertEqual(census, ["rewind-turn": [3], "compact-boundary": [3]],
                       "the corpus's branches, one line per fixture that has any")
        XCTAssertEqual(totalMessages, 40, "the recorded main transcripts carry forty prompt records on their leaf paths")
    }

    /// A soft compaction is one chain, not two.
    ///
    /// `compact-boundary`'s boundary record carries `parentUuid: null` and names its only link back in
    /// `logicalParentUuid` — the pair the engine's own writer puts on a boundary and on nothing else
    /// (2.1.258 `cli.pretty.js` line 430982) — so a reducer that follows `parentUuid` alone reads the file as two
    /// trees and renders the post-boundary tail only. The recording preserves a segment, so it is a *soft* boundary
    /// and rule 6 keeps the half before it; the boundary item then sits between the two halves in leaf-chain order.
    func testASoftCompactBoundaryContinuesTheChainThroughItsLogicalParent() throws {
        let (records, stream, url) = try Self.mainStream(of: "compact-boundary")
        let projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)

        // The boundary, read off the records: exactly one, no `parentUuid`, a `logicalParentUuid` this same file
        // carries, and metadata that names a preserved segment — so the hard/soft decision must come out soft.
        let boundaries = records.compactMap { record -> SystemRecord? in
            if case .system(let system) = record, system.fields.subtype == "compact_boundary" { system } else { nil }
        }
        XCTAssertEqual(boundaries.count, 1, "the recording holds one compaction")
        let boundary = try XCTUnwrap(boundaries.first)
        XCTAssertNil(boundary.fields.parentUuid, "the boundary starts a new parentUuid chain")
        let logical = try XCTUnwrap(boundary.fields.logicalParentUuid, "and carries its only link back as logicalParentUuid")
        XCTAssertTrue(records.contains { $0.uuid == logical }, "which names a record of this same file")
        XCTAssertFalse(ItemBuilder.isHardTruncation(compactMetadata: boundary.fields.compactMetadata),
                       "this compaction preserved a segment, so nothing before it is dropped")

        // One chain. The only branch is the abandoned turn the rewind left in this session before the compaction —
        // not the twenty-seven records that precede the boundary, which is what a parentUuid-only walk yields.
        XCTAssertEqual(projection.branches.map(\.count), [3],
                       "the pre-boundary half is on the chain; only the abandoned turn is a branch")

        let rendered = projection.items.filter { $0.category == .userMessage || $0.category == .peerMessage }.count
        XCTAssertEqual(rendered, Self.promptRecordCount(records, on: Self.leafChain(records)),
                       "every prompt on the leaf path is rendered, on both sides of the boundary")
        XCTAssertGreaterThan(rendered, Self.promptRecordCount(records, on: Self.postBoundaryUUIDs(records)),
                             "and that is strictly more than the post-boundary tail alone")

        // Position: the boundary item is preceded by items the file wrote before it and followed by items it wrote
        // after, so the two halves are on one line with the boundary between them.
        var positionOf: [String: Int] = [:]
        for (index, record) in records.enumerated() { if let uuid = record.uuid { positionOf[uuid] = index } }
        let boundaryPosition = try XCTUnwrap(positionOf[boundary.fields.uuid])
        let placed = projection.items.compactMap { item in positionOf[item.id.key].map { (item, $0) } }
        let boundaryIndex = try XCTUnwrap(placed.firstIndex { $0.0.category == .compactBoundary },
                                          "the boundary is rendered")
        XCTAssertGreaterThan(boundaryIndex, 0, "the pre-boundary half is rendered before it")
        XCTAssertLessThan(boundaryIndex, placed.count - 1, "and the post-boundary half after it")
        XCTAssertTrue(placed[..<boundaryIndex].allSatisfy { $0.1 < boundaryPosition },
                      "every item before the boundary comes from a record the file wrote before it")
        XCTAssertTrue(placed[(boundaryIndex + 1)...].allSatisfy { $0.1 > boundaryPosition },
                      "and every item after it from a record the file wrote after it")
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
        // Grounded by the walk above: 26 tool uses on disk and all 26 reach the projection — 25 tool cards and the one
        // `send_user_file`. The last two are the parallel `Bash` calls of `explore-depth-1`'s and `nested-depth-2`'s
        // agent streams, whose opening assistant records lie off the `parentUuid` chain but share a `message.id` with
        // a record on it, so rule 4's group production renders them and the off-chain results complete them. Nothing
        // recorded is left running: 25 completed cards, 1 denied (`permission-deny`), 0 failed, 0 running.
        XCTAssertEqual(projectedTotal, 26)
        XCTAssertEqual([completed, denied, failed, running], [24, 1, 0, 0],
                       "every recorded call is answered; only permission-deny's is denied")
    }

    /// Rule 4's unit of production is the `message.id` group, so a parallel tool call whose opening `assistant` record
    /// lies off the `parentUuid` chain is still rendered, and the off-chain result completes it (the engine's `kns`,
    /// 2.1.258 `cli.pretty.js` line 432695).
    ///
    /// `nested-depth-2`'s depth-2 agent stream is the fixture this rule exists for: it is one of the corpus's only two
    /// branch points, and the branch is exactly a parallel pair — a second `assistant` record repeating the first's
    /// `message.id` with a second `tool_use` block, and the `user` record answering it. Under a chain-only reading
    /// that call was absent from the projection altogether. `explore-depth-1`'s agent stream carries the same shape
    /// and is checked alongside it.
    func testAParallelCallOffTheChainIsRegroupedByItsMessageID() throws {
        for (fixture, depth) in [("nested-depth-2", 2), ("explore-depth-1", 1)] {
            let (records, stream, url) = try Self.agentStream(of: fixture, depth: depth)
            let label = "\(fixture)/depth \(depth)"

            // The branch, walked off the records: an assistant record off the chain whose `message.id` is on it.
            let walk = Self.toolWalk(records)
            var chain: Set<String> = []
            var cursor = records.last(where: \.isConversation)?.uuid
            var byUUID: [String: TranscriptRecord] = [:]
            for record in records { if let uuid = record.uuid { byUUID[uuid] = record } }
            while let uuid = cursor, byUUID[uuid] != nil, !chain.contains(uuid) {
                chain.insert(uuid)
                cursor = byUUID[uuid].flatMap(WindowedTranscript.parentUUID(of:))
            }
            let assistants = records.compactMap { record -> AssistantRecord? in
                if case .assistant(let assistant) = record { assistant } else { nil }
            }
            let onChainIDs = Set(assistants.filter { chain.contains($0.fields.uuid) }.compactMap { $0.fields.message.fields.id })
            let offChainSiblings = assistants.filter {
                !chain.contains($0.fields.uuid) && $0.fields.message.fields.id.map(onChainIDs.contains) == true
            }
            XCTAssertEqual(offChainSiblings.count, 1, "\(label): one assistant record repeats an on-chain message.id")
            let sibling = try XCTUnwrap(offChainSiblings.first)
            let siblingCalls = sibling.fields.message.fields.content.compactMap {
                if case .toolUse(let use) = $0 { use.fields.id } else { nil }
            }
            XCTAssertEqual(siblingCalls.count, 1, "\(label): the off-chain record opens exactly one call")
            let parallelCall = siblingCalls[0]
            XCTAssertFalse(chain.contains(try XCTUnwrap(walk.opened[parallelCall])),
                           "\(label): the record opening it really is off the parentUuid chain")

            let projection = RecordReducer.reduce(records, stream: stream, sourceFile: url)
            let call = try XCTUnwrap(Self.toolCalls(projection).first { $0.toolUseID == parallelCall },
                                     "\(label): the parallel call is rendered")
            XCTAssertEqual(call.status, .completed, "\(label): its off-chain result completes it")
            XCTAssertNotNil(call.result, "\(label): with the result block's own content")

            // The group is one item: both records' uuids, both records' keys, and the blocks in file order.
            let group = assistants.filter { $0.fields.message.fields.id == sibling.fields.message.fields.id }
            let item = try XCTUnwrap(projection.items.compactMap { item -> AssistantMessageItem? in
                if case .assistantMessage(let assistant) = item,
                   assistant.recordUUIDs.contains(sibling.fields.uuid) { assistant } else { nil }
            }.first, "\(label): the off-chain record folds into the item its group keys")
            XCTAssertEqual(item.recordUUIDs, group.map { $0.fields.uuid }, "\(label): every record of the group, in file order")
            XCTAssertEqual(item.id.key, group[0].fields.uuid, "\(label): the group's first record keys the item")
            XCTAssertEqual(item.provenance.records.count, group.count, "\(label): every record of the group is provenance")
            XCTAssertEqual(item.blocks.count, group.reduce(0) { $0 + $1.fields.message.fields.content.count },
                           "\(label): the group's blocks concatenated")

            XCTAssertEqual(projection.branches, [],
                           "\(label): the branch was the group and its result, and both are back on the line")
        }
    }

    /// The other side of the same rule, and the one no recording reaches: a `message.id` group with **no** record on
    /// the chain is not produced. Reached by naming an earlier leaf in `nested-depth-2`'s depth-2 agent stream — the
    /// file records no `last-prompt`, so the mutation appends one — which leaves the first group straddling the chain
    /// (rendered whole, parallel call and all) and drops two later groups off it entirely.
    func testAMessageIDGroupWithNoRecordOnTheChainIsNotProduced_mutation() throws {
        let (records, stream, url) = try Self.agentStream(of: "nested-depth-2", depth: 2)
        var byUUID: [String: TranscriptRecord] = [:]
        for record in records { if let uuid = record.uuid { byUUID[uuid] = record } }

        // The earlier leaf: the first `user` record on the file's own chain that carries a tool result — the earliest
        // point that still leaves whole later groups behind. (The file's *first* tool-result record in file order is
        // the parallel branch's own, which is off the chain and would name a leaf the file never had.)
        var recorded: Set<String> = []
        var walker = records.last(where: \.isConversation)?.uuid
        while let uuid = walker, byUUID[uuid] != nil, !recorded.contains(uuid) {
            recorded.insert(uuid)
            walker = byUUID[uuid].flatMap(WindowedTranscript.parentUUID(of:))
        }
        let leaf = try XCTUnwrap(records.compactMap { record -> String? in
            guard case .user(let user) = record, recorded.contains(user.fields.uuid),
                  case .blocks(let blocks) = user.fields.message.fields.content,
                  blocks.contains(where: { if case .toolResult = $0 { true } else { false } }) else { return nil }
            return user.fields.uuid
        }.first)
        let line = #"{"type":"last-prompt","timestamp":"2026-09-05T00:00:00.000Z","leafUuid":"\#(leaf)"}"#
        let shortened = records + [RecordDecoder.decode(line: Data(line.utf8))]

        // What the shortened chain reaches, walked off the records: the groups it touches, and the calls they open.
        var chain: Set<String> = []
        var cursor: String? = leaf
        while let uuid = cursor, byUUID[uuid] != nil, !chain.contains(uuid) {
            chain.insert(uuid)
            cursor = byUUID[uuid].flatMap(WindowedTranscript.parentUUID(of:))
        }
        let assistants = records.compactMap { record -> AssistantRecord? in
            if case .assistant(let assistant) = record { assistant } else { nil }
        }
        let renderedIDs = Set(assistants.filter { chain.contains($0.fields.uuid) }.compactMap { $0.fields.message.fields.id })
        func calls(of assistant: AssistantRecord) -> [String] {
            assistant.fields.message.fields.content.compactMap { if case .toolUse(let use) = $0 { use.fields.id } else { nil } }
        }
        let produced = Set(assistants.filter { $0.fields.message.fields.id.map(renderedIDs.contains) == true }.flatMap(calls))
        let withheld = Set(assistants.filter { $0.fields.message.fields.id.map(renderedIDs.contains) != true }.flatMap(calls))
        XCTAssertFalse(withheld.isEmpty, "the shortened chain must leave at least one whole group behind")
        let opener = Self.toolWalk(records).opened
        XCTAssertTrue(produced.contains { opener[$0].map { !chain.contains($0) } == true },
                      "and must still pull one off-chain record in, so both directions are exercised")

        let projection = RecordReducer.reduce(shortened, stream: stream, sourceFile: url)
        XCTAssertEqual(projection.session.leaf, leaf)
        let rendered = Set(Self.toolCalls(projection).map(\.toolUseID))
        XCTAssertEqual(rendered, produced, "only the groups the chain touches are produced")
        XCTAssertTrue(rendered.isDisjoint(with: withheld), "a group with no record on the chain opens nothing")

        let withheldRecords = Set(assistants.filter { $0.fields.message.fields.id.map(renderedIDs.contains) != true }
                                    .map { $0.fields.uuid })
        XCTAssertFalse(withheldRecords.isEmpty)
        let inItems = Set(projection.items.compactMap { item -> [String]? in
            if case .assistantMessage(let assistant) = item { assistant.recordUUIDs } else { nil }
        }.flatMap { $0 })
        XCTAssertTrue(inItems.isDisjoint(with: withheldRecords), "and produces no assistant item of its own")
        let branched = Set(projection.branches.map(\.head))
        XCTAssertFalse(branched.isEmpty, "its records land in branches instead")
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
        // Six conversation records fall off the shortened `parentUuid` chain, and one comes straight back: the second
        // record of the first assistant's own `message.id`. Rule 4 produces the whole group when any of its records is
        // on the chain, so that record is rendered — it folds into the item the first record keys, which is why
        // `items.last` is still the first assistant above — and only five stay in the branch.
        XCTAssertEqual(after.branches.first?.count, 5,
                       "the leaf's `message.id` group is rendered whole; the rest of the tail is the branch")
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
    /// off-chain calls, and rule 4's group production now renders both), so the path is reached with two named
    /// mutations of `background-shell`: naming an earlier leaf, which drops the recorded result record off the chain
    /// while leaving the `Bash` call on it, and re-parenting that record onto the first prompt, so the group
    /// regrouping does not pull it back with its call's own `message.id` group.
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
        let answeringIndex = try XCTUnwrap(records.firstIndex { record in
            guard case .user(let user) = record, case .blocks(let blocks) = user.fields.message.fields.content
            else { return false }
            return blocks.contains { if case .toolResult = $0 { true } else { false } }
        })
        let firstPrompt = try XCTUnwrap(records.compactMap { record -> String? in
            guard case .user(let user) = record, WindowedTranscript.parentUUID(of: record) == nil else { return nil }
            return user.fields.uuid
        }.first)
        var shortened = records
        shortened[promptIndex] = try Breaks.setting(path: "leafUuid", in: records[promptIndex], to: .string(opener))
        shortened[answeringIndex] = try Breaks.setting(path: "parentUuid", in: records[answeringIndex],
                                                       to: .string(firstPrompt))

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

    /// Tech-debt entry 23, against the first transcript in the corpus where physical order and chain order part.
    ///
    /// For an open window `ConversationTree` exempts the *first* record with a missing parent in physical file order
    /// as the window root, on the ground that Task 2's closure put the window's start at a turn boundary. A resume
    /// after a rewind breaks that ground: `compact-boundary`'s file is the pre-rewind chain, then the abandoned turn
    /// the rewind left behind, then the new turn's records — so a tail short enough to begin inside the abandoned
    /// turn hands the one exemption to a record the leaf path does not contain. The entry's worry is that the live
    /// chain's own boundary is then eligible for five-second orphan healing and attaches to the abandoned branch,
    /// putting discarded turns ahead of the active ones in a window closure declared valid.
    ///
    /// The tail below begins inside the abandoned turn, which the assertions establish before they test anything, and
    /// the hazard does not fire — for a reason particular to this file rather than a general one, which is why entry
    /// 23 stays open. The abandoned record does take the one exemption, exactly as the entry says. The record it
    /// would otherwise have protected is the `compact_boundary`, and a boundary declares no `parentUuid` at all: with
    /// its `logicalParentUuid` lying before the window it becomes a root outright and never reaches the five-second
    /// healing branch that the entry's closer exists to keep it away from. So the corpus still holds no oracle for
    /// the shape the entry describes — a live chain whose boundary declares a `parentUuid` the window does not hold —
    /// and this test is the regression witness for the one shape it does hold. `rewind-turn` cannot produce the
    /// other: its file ends with the abandoned turn, so no window that reaches it holds any later live record.
    func testABoundedTailBeginningInsideAnAbandonedBranchKeepsTheLiveChainOffIt() throws {
        let fixture = try FixtureCorpus.named("compact-boundary")
        let url = try XCTUnwrap(try fixture.transcriptFiles().first { if case .mainTranscript = $0.1 { true } else { false } }).2
        let stream = try XCTUnwrap(try fixture.transcriptFiles().first { if case .mainTranscript = $0.1 { true } else { false } }).0
        let reader = TranscriptReader(url: url)
        let whole = try reader.readAll().records
        let abandoned = Set(whole.compactMap(\.uuid)).subtracting(Self.leafChain(whole))
        XCTAssertEqual(abandoned.count, 3, "the file carries the rewind's abandoned turn and nothing else off the path")

        // A tail that starts partway through the abandoned turn: the byte budget is expressed as a fraction of the
        // file rather than as a recorded offset, and the premise is asserted rather than assumed.
        let length = try reader.byteLength()
        let policy = WindowPolicy(wholeFileUpTo: 0, initialTail: length / 12, earlierStep: 512)
        let result = try WindowedTranscript.read(reader, policy: policy)
        XCTAssertTrue(result.window.earlierAvailable, "the window must be open for the exemption to exist at all")
        let inWindow = result.records.compactMap(\.uuid)
        XCTAssertTrue(abandoned.contains(where: inWindow.contains),
                      "the premise: the window reaches into the abandoned turn")
        XCTAssertFalse(abandoned.allSatisfy(inWindow.contains),
                       "and begins inside it rather than before it")

        var options = RecordReducer.Options()
        options.window = result.window
        let projection = RecordReducer.reduce(result.records, stream: stream, sourceFile: url, options: options)

        XCTAssertEqual(projection.warnings.filter { $0.kind == .orphanHealed || $0.kind == .orphanUnhealed }, [],
                       "the abandoned record took the exemption and the live chain's boundary needed none")
        let rendered = Set(projection.items.map { $0.id.key })
        XCTAssertTrue(rendered.isDisjoint(with: abandoned),
                      "and no abandoned record is rendered ahead of the active ones")
        XCTAssertTrue(rendered.contains { Self.leafChain(whole).contains($0) },
                      "while the live chain inside the window still is")
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

    /// The agent stream a fixture's `.meta.json` sidecars put at `spawnDepth`.
    private static func agentStream(of name: String, depth: Int) throws -> ([TranscriptRecord], LogicalStream, URL) {
        let fixture = try FixtureCorpus.named(name)
        var wanted: Set<LogicalStream> = []
        for (stream, url) in try fixture.metaFiles() {
            let metadata = try JSONDecoder().decode(AgentMetadataRecord.self, from: try Data(contentsOf: url))
            if metadata.fields.spawnDepth == depth { wanted.insert(stream) }
        }
        for (stream, _, url) in try fixture.transcriptFiles() where wanted.contains(stream) {
            return (try TranscriptReader(url: url).readAll().records, stream, url)
        }
        throw FixtureCorpus.Failure("fixture \(name) has no agent stream at depth \(depth)")
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

    /// A `user` record the timeline renders, counted over the uuids `on` names: not one of the three flags the
    /// engine folds into `isSynthetic`, and not a bare carrier of tool results. Written here from the records,
    /// deliberately sharing nothing with the reducer.
    private static func promptRecordCount(_ records: [TranscriptRecord], on rendered: Set<String>) -> Int {
        records.reduce(into: 0) { total, record in
            guard case .user(let user) = record, rendered.contains(user.fields.uuid) else { return }
            if user.fields.isMeta == true || user.fields.isCompactSummary == true { return }
            if user.additional["isVisibleInTranscriptOnly"]?.boolValue == true { return }
            if case .blocks(let blocks) = user.fields.message.fields.content,
               blocks.contains(where: { if case .toolResult = $0 { true } else { false } }) { return }
            total += 1
        }
    }

    /// The leaf path, walked off the records: from the file's leaf up by `parentUuid`, and by `logicalParentUuid`
    /// where a record declares no `parentUuid` at all — which on this corpus is the compact boundary and nothing
    /// else. Written here rather than borrowed from `ConversationTree`, so the two sides are a real comparison.
    private static func leafChain(_ records: [TranscriptRecord]) -> Set<String> {
        var byUUID: [String: TranscriptRecord] = [:]
        for record in records where record.isConversation { if let uuid = record.uuid { byUUID[uuid] = record } }
        var cursor = lastPromptLeaf(records) ?? records.last(where: \.isConversation)?.uuid
        if let uuid = cursor, byUUID[uuid] == nil { cursor = records.last(where: \.isConversation)?.uuid }
        var chain: Set<String> = []
        while let uuid = cursor, let record = byUUID[uuid], !chain.contains(uuid) {
            chain.insert(uuid)
            cursor = WindowedTranscript.parentUUID(of: record) ?? WindowedTranscript.logicalParentUUID(of: record)
        }
        return chain
    }

    /// Every record the file wrote at or after its `compact_boundary`, by file order. The vacuity guard for the
    /// clause above: a reducer that stopped at the boundary would render exactly these.
    private static func postBoundaryUUIDs(_ records: [TranscriptRecord]) -> Set<String> {
        guard let index = records.firstIndex(where: { record in
            if case .system(let system) = record { system.fields.subtype == "compact_boundary" } else { false }
        }) else { return Set(records.compactMap(\.uuid)) }
        return Set(records[index...].compactMap(\.uuid))
    }

    /// Tool-use id → the uuid of the assistant record that opened it, the ids some result answers, and the set of
    /// records the projection renders, all walked straight off the records. The rendered set is the leaf chain plus
    /// every assistant record sharing a `message.id` with a record on it (rule 4's group), re-derived here rather than
    /// borrowed from the reducer, so the two sides are a real comparison.
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
        let chain = leafChain(records)

        var messageIDsOnChain: Set<String> = []
        for record in records {
            guard case .assistant(let assistant) = record, chain.contains(assistant.fields.uuid),
                  let id = assistant.fields.message.fields.id else { continue }
            messageIDsOnChain.insert(id)
        }
        var rendered = chain
        for record in records {
            guard case .assistant(let assistant) = record, let id = assistant.fields.message.fields.id,
                  messageIDsOnChain.contains(id) else { continue }
            rendered.insert(assistant.fields.uuid)
        }
        return (opened, answered, rendered)
    }
}
