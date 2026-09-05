import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// Contract X4: the shapes C6's renderer and C4's store read, and the named constants that say which of them
/// persist, which are overlay, and which records exist only in the file.
final class TimelineModelTests: XCTestCase {

    // MARK: - The category constants

    func testCategorySetsPartitionAsTheSpecSays() {
        let durable = ProjectionCategories.durable, overlay = ProjectionCategories.overlay
        // The regression guard: each set equals its spec literal exactly. The structural assertions below say
        // what the spec cares about, but they hold under real violations too — moving `.cluster` from overlay
        // into durable keeps disjointness, coverage and the subset property all intact.
        XCTAssertEqual(durable,
                       [.userMessage, .assistantMessage, .toolCall, .peerMessage, .sentFile, .compactBoundary, .taskRun],
                       "durable is exactly the spec's seven categories")
        XCTAssertEqual(overlay,
                       [.cluster, .decision, .hookRun, .notification, .turnSummary],
                       "overlay is exactly the spec's five categories")
        XCTAssertEqual(ProjectionCategories.comparedWireToFile,
                       [.userMessage, .assistantMessage, .toolCall, .peerMessage, .sentFile, .taskRun, .compactBoundary],
                       "check one compares exactly the spec's seven categories")
        XCTAssertTrue(durable.isDisjoint(with: overlay),
                      "a category is durable or overlay, never both: \(durable.intersection(overlay).map(\.rawValue).sorted())")
        XCTAssertEqual(durable.union(overlay).union([.opaque]), Set(TimelineCategory.allCases),
                       "durable ∪ overlay ∪ opaque must name every category exactly once")
        XCTAssertEqual(TimelineCategory.allCases.count, 13)
        XCTAssertTrue(ProjectionCategories.comparedWireToFile.isSubset(of: durable),
                      "check one only compares durable categories: \(ProjectionCategories.comparedWireToFile.subtracting(durable).map(\.rawValue).sorted())")
        // The 2026-09-05 parent amendment carried through: the boundary is on the wire, so it is durable, it is not
        // file-only, and it is compared like any other record. Vacuous on this branch's corpus, live at merge.
        XCTAssertTrue(durable.contains(.compactBoundary))
        XCTAssertTrue(ProjectionCategories.comparedWireToFile.contains(.compactBoundary))
        XCTAssertFalse(ProjectionCategories.fileOnlyRecordKinds.contains(.system("compact_boundary")))
        XCTAssertEqual(ProjectionCategories.excludedItemFields, ["stop_reason", "usage", "signature", "timestamp"])
        // Set equality against the full literal, every `contentBlocks` flag spelled out: a count alone would
        // survive flipping any one of the nine booleans, so check one could silently stop comparing a field.
        XCTAssertEqual(ProjectionCategories.comparedItemFields.fields,
                       [.role, .model, .origin, .toolDenialKind,
                        .contentBlocks(text: true, thinking: true, toolUseID: true, toolUseName: true, toolUseInput: true,
                                       toolResultContent: true, toolResultIsError: true, image: true, document: true)],
                       "comparedItemFields is exactly the spec's four scalars plus all nine content-block flags on")
    }

    // MARK: - The .system matchers

    /// The corpus holds no `system` record on disk, so the four `.system(...)` matchers are only proved
    /// negatively there. This exercises them against an invented system record built in Swift — no fixture,
    /// no engine byte — and pins that the arm keys off the record's `subtype`, never its `type`.
    func testSystemMatchersKeyOffSubtypeOfAnInventedSystemRecord() {
        func systemRecord(subtype: String?) -> TranscriptRecord {
            .system(SystemRecord(fields: SystemRecordFields(
                type: "system", subtype: subtype, uuid: "c4d0a1e6-0000-4000-8000-0000000000f1",
                parentUuid: nil, sessionId: "3f6e2a55-0000-4000-8000-0000000000f2",
                timestamp: "2026-09-05T00:00:00.000Z")))
        }
        let record = systemRecord(subtype: "turn_duration")

        XCTAssertTrue(RecordKindMatcher.system("turn_duration").matches(record),
                      ".system(\"turn_duration\") must match a system record of that subtype")
        XCTAssertFalse(RecordKindMatcher.system("informational").matches(record),
                       ".system(\"informational\") must not match a record of another subtype")
        XCTAssertTrue(ProjectionCategories.fileOnlyRecordKinds.contains(where: { $0.matches(record) }),
                      "a turn_duration system record is file-only")

        let noSubtype = systemRecord(subtype: nil)
        for matcher in ProjectionCategories.fileOnlyRecordKinds {
            if case .system(let subtype) = matcher {
                XCTAssertFalse(matcher.matches(noSubtype),
                               ".system(\"\(subtype)\") must not match a system record with no subtype")
            }
        }

        XCTAssertFalse(RecordKindMatcher.kind("turn_duration").matches(record),
                       "the subtype is not the record's kind: .kind(\"turn_duration\") must not match")
        XCTAssertTrue(RecordKindMatcher.kind("system").matches(record), "the record's kind is \"system\"")
    }

    // MARK: - The file-only matchers, against the corpus

    /// Every attachment in the corpus, both `isMeta` user records, the four engine-injected task notifications and
    /// the three subagent opening prompts match a file-only matcher; no other record does. The total is pinned as an
    /// equality against the census (200 + 2 + 4 + 3 = 209) and grounded by a per-shape equality for each of the four
    /// user shapes beside it, so a matcher that over- or under-matches cannot pass. The negative that matters most is
    /// the last one: no main-stream root matches `.sidechainRoot`, which is what makes that flag expressible at all.
    ///
    /// The two user matchers were added on 2026-09-05 by parent revisions 7 and 8, after check two found both shapes
    /// present in the transcript and absent from every `user` frame.
    func testFileOnlyMatchersRecogniseTheCorpusAttachmentsAndMetaUsers() throws {
        let matchers = ProjectionCategories.fileOnlyRecordKinds
        var matched = 0, attachments = 0, matchedAttachments = 0, records = 0
        var metaUsers = 0, taskNotifications = 0, sidechainRoots = 0, plainUsers = 0, mainRoots = 0
        var matchedKinds: Set<String> = []
        var byFixture: [String: Int] = [:]
        for fx in try FixtureCorpus.all() {
            for (_, kind, url) in try fx.transcriptFiles() {
                let isAgentStream: Bool = if case .agentTranscript = kind { true } else { false }
                for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    let record = RecordDecoder.decode(line: Data(line))
                    records += 1
                    let hit = matchers.contains { $0.matches(record) }
                    if hit { matched += 1; matchedKinds.insert(record.kind) }
                    switch record {
                    case .attachment:
                        attachments += 1
                        if hit { matchedAttachments += 1 }
                    case .user(let r):
                        if r.isMeta == true {
                            metaUsers += 1
                            XCTAssertTrue(hit, "\(fx.name): an isMeta user record is file-only and must match")
                        } else if r.fields.origin?.fields.kind == "task-notification" {
                            taskNotifications += 1
                            byFixture[fx.name, default: 0] += 1
                            XCTAssertTrue(RecordKindMatcher.userOrigin("task-notification").matches(record),
                                          "\(fx.name): an engine-injected task notification is file-only and must match")
                        } else if r.fields.isSidechain == true && r.fields.parentUuid == nil {
                            sidechainRoots += 1
                            XCTAssertTrue(isAgentStream,
                                          "\(fx.name): a sidechain root must lie on an agent stream, not the main one")
                            XCTAssertTrue(RecordKindMatcher.userWhere(.sidechainRoot).matches(record),
                                          "\(fx.name): a subagent's opening prompt is file-only and must match")
                        } else {
                            plainUsers += 1
                            XCTAssertFalse(hit, "\(fx.name): a plain user record must not match a file-only matcher")
                            // The negative the `.sidechainRoot` flag rests on: a main-stream root is a root too, and
                            // must not be swept up. Every main-stream root in the corpus carries `isSidechain: false`.
                            if !isAgentStream, r.fields.parentUuid == nil {
                                mainRoots += 1
                                XCTAssertNotEqual(r.fields.isSidechain, true,
                                                  "\(fx.name): a main-stream root must not read as a sidechain root")
                                XCTAssertFalse(RecordKindMatcher.userWhere(.sidechainRoot).matches(record),
                                               "\(fx.name): .sidechainRoot must not match a main-stream root")
                            }
                        }
                    default: break
                    }
                }
            }
        }
        XCTAssertEqual(records, 611)                                    // the corpus census of 2026-09-05
        XCTAssertEqual(attachments, 200)
        XCTAssertEqual(matchedAttachments, attachments, "every attachment record must match .kind(\"attachment\")")
        XCTAssertEqual(metaUsers, 2)
        XCTAssertEqual(taskNotifications, 4)
        XCTAssertEqual(byFixture, ["background-shell": 1, "explore-depth-1": 1, "nested-depth-2": 2],
                       "the four task notifications are these fixtures' and no others'")
        XCTAssertEqual(sidechainRoots, 3, "one opening prompt per agent transcript: explore-depth-1 has one, nested-depth-2 two")
        XCTAssertEqual(plainUsers, 62)
        XCTAssertGreaterThan(mainRoots, 0, "the .sidechainRoot negative would be vacuous with no main-stream root")
        XCTAssertEqual(matched, 209,
                       "the file-only matchers must select exactly the 200 attachments, 2 isMeta users, 4 task notifications and 3 sidechain roots")
        XCTAssertEqual(matchedKinds, ["attachment", "user"], "no other kind on disk is file-only in this corpus")
    }

    // MARK: - Task vocabulary

    func testTaskKindAndStatusNormalisation() {
        let wireKinds = ["local_bash", "local_agent", "remote_agent", "in_process_teammate", "local_workflow",
                         "monitor_mcp", "monitor_ws", "mcp_task", "dream", "auto_mode_scan"]
        XCTAssertEqual(TaskKind(wire: "local_bash"), .localBash)
        XCTAssertEqual(TaskKind(wire: "auto_mode_scan"), .autoModeScan)
        for wire in wireKinds {
            let kind = TaskKind(wire: wire)
            XCTAssertEqual(kind.wire, wire, "\(wire) did not round-trip through TaskKind")
            if case .other = kind { XCTFail("\(wire) is one of the ten engine kinds, not .other") }
        }
        XCTAssertEqual(Set(wireKinds).count, 10)

        let unknown = TaskKind(wire: "quantum_tunnel")
        XCTAssertEqual(unknown, .other("quantum_tunnel"))
        XCTAssertEqual(unknown.wire, "quantum_tunnel", "an unknown kind round-trips through .other unchanged")

        XCTAssertEqual(TaskStatus(wire: "killed"), .stopped)            // parity §20.8.4: one state, two spellings
        XCTAssertEqual(TaskStatus(wire: "stopped"), .stopped)
        XCTAssertEqual(TaskStatus(wire: "pending"), .running)
        XCTAssertEqual(TaskStatus(wire: "running"), .running)
        XCTAssertEqual(TaskStatus(wire: "completed"), .completed)
        XCTAssertEqual(TaskStatus(wire: "failed"), .failed)
        XCTAssertEqual(TaskStatus(wire: "flibbertigibbet"), .running, "an unknown status must not crash and must read as live")
    }

    // MARK: - Codable and Hashable

    /// Every payload struct survives a `JSONEncoder`/`JSONDecoder` round trip equal and hashes equal, so a projection
    /// snapshot can be persisted. `ToolCallItem` stores the raw input and types it on demand: a Bash input decoded back
    /// out of JSON still computes to `.bash`.
    func testItemsAreCodableAndHashable() throws {
        let stream = Self.aStream()
        let id = ItemID(stream: stream, key: "item-1")
        let parent = ItemID(stream: stream, key: "item-0")
        let when = Date(timeIntervalSinceReferenceDate: 1_000)
        let provenance = Provenance(stream: stream, agentID: "agent-1", sourceFile: nil, epoch: .first,
                                    records: [RecordKey(stream: stream, identity: .uuid("a37cf8e2-0000-4000-8000-000000000001")),
                                              RecordKey(stream: stream, identity: .hash("beef", ordinal: 2))],
                                    origin: .file)
        let block = try Self.textBlock("a block the test built, not a recording")

        try roundTrip(UserMessageItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                      blocks: [block], text: "hello", isReplay: true, promptUUID: "p-1"), "UserMessageItem")
        try roundTrip(AssistantMessageItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                           messageID: "msg_1", model: "a-model", blocks: [block], stopReason: "end_turn",
                                           isStreaming: false, supersededBy: nil, recordUUIDs: ["u1", "u2"]), "AssistantMessageItem")
        try roundTrip(ToolClusterItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                      toolUseIDs: ["t1", "t2"], label: "reads"), "ToolClusterItem")
        try roundTrip(TaskRunItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                  taskID: "b0000001", kind: .localBash, description: "a shell", status: .running,
                                  summary: nil, outputFile: nil, usage: .object(["tool_uses": .integer(2)]),
                                  toolUseID: "t1", agentType: nil, depth: 0, synthesised: false), "TaskRunItem")
        try roundTrip(TaskRunItem(id: id, provenance: provenance, taskID: "z1", kind: .other("quantum_tunnel"),
                                  description: "an unmodelled kind", status: .stopped), "TaskRunItem(.other)")
        try roundTrip(DecisionItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                   requestID: RequestID(rawValue: "req-1"), kind: .permission, title: "Allow?",
                                   toolUseID: "t1", agentID: nil, state: .answered(outcome: "allow"),
                                   payload: .object(["tool_name": .string("Bash")])), "DecisionItem")
        try roundTrip(DecisionItem(id: id, provenance: provenance, requestID: RequestID(rawValue: "req-2"), kind: .other,
                                   title: "Unmodelled", state: .policyAnswered(error: "no handler"), payload: .null),
                      "DecisionItem(.policyAnswered)")
        try roundTrip(HookRunItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                  hookID: "h1", hookName: "notify", event: "Notification", outcome: "ok", exitCode: 0), "HookRunItem")
        try roundTrip(NotificationItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                       key: "n1", text: "a notice", level: "info", fileOnly: true), "NotificationItem")
        try roundTrip(PeerMessageItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                      originKind: "teammate", from: "peer-1", name: "Peer", blocks: [block], text: "hi"), "PeerMessageItem")
        try roundTrip(CompactBoundaryItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                          trigger: "auto", hardTruncation: false, preTokens: 100, postTokens: 10,
                                          logicalParentUUID: "u0"), "CompactBoundaryItem")
        try roundTrip(SentFileItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                   toolUseID: "t1", files: ["one.txt"], caption: "a caption", delivered: true), "SentFileItem")
        try roundTrip(TurnSummaryItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                      subtype: "success", durationMs: 1234, costUSD: 0.5, numTurns: 2,
                                      stopReason: "end_turn", usage: nil, permissionDenials: nil,
                                      attribution: .prompted(uuid: "p-1")), "TurnSummaryItem")
        try roundTrip(TurnSummaryItem(id: id, provenance: provenance, subtype: "success", durationMs: 0, costUSD: 0,
                                      numTurns: 0, attribution: .unprompted), "TurnSummaryItem(.unprompted)")
        try roundTrip(OpaqueItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                 type: "system", subtype: "a_subtype_the_host_does_not_model", reason: "unknown_subtype",
                                 value: .object(["k": .bool(true)])), "OpaqueItem")

        // A hidden record with and without a locator.
        let key = RecordKey(stream: stream, identity: .uuid("a37cf8e2-0000-4000-8000-000000000002"))
        try roundTrip(HiddenRecord(key: key, kind: "attachment", timestamp: when, reason: .attachment,
                                   locator: RecordLocator(stream: stream, range: ByteRange(offset: 40, length: 120))),
                      "HiddenRecord(with locator)")
        try roundTrip(HiddenRecord(key: key, kind: "attachment", timestamp: when, reason: .attachment, locator: nil),
                      "HiddenRecord(no locator)")
        try roundTrip(Branch(head: "u1", tail: "u9", count: 4), "Branch")
        try roundTrip(ReadWarning(kind: .undecodable, stream: .agent(taskID: "t1"), byteOffset: 17, recordKind: "user"), "ReadWarning")
        try roundTrip(SessionState(), "SessionState")

        // The tool call, and the typed input the decoded copy computes.
        let call = ToolCallItem(id: id, timestamp: when, threadParent: parent, provenance: provenance,
                                toolUseID: "t1", name: "Bash", rawInput: .object(["command": .string("echo one"),
                                                                                  "description": .string("say one")]),
                                result: .string("one"), isError: false, structuredResult: nil, denialKind: nil,
                                messageID: "msg_1", status: .completed)
        if case .bash(let before) = call.input { XCTAssertEqual(before.command, "echo one") }
        else { XCTFail("a Bash tool call must type as .bash before encoding, got \(call.name)") }
        try roundTrip(call, "ToolCallItem")
        let decodedCall = try JSONDecoder().decode(ToolCallItem.self, from: JSONEncoder().encode(call))
        guard case .bash(let bash) = decodedCall.input else {
            return XCTFail("the decoded tool call's input must still type as .bash")
        }
        XCTAssertEqual(bash.command, "echo one")
        XCTAssertEqual(bash.description, "say one")

        // And the wrapping enum, whose accessors read the payload's four common fields.
        let item = TimelineItem.toolCall(call)
        try roundTrip(item, "TimelineItem.toolCall")
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.timestamp, when)
        XCTAssertEqual(item.threadParent, parent)
        XCTAssertEqual(item.provenance, provenance)
        XCTAssertEqual(item.category, .toolCall)
        XCTAssertEqual(Set(TimelineCategory.allCases.map(\.rawValue)).count, 13)
    }

    // MARK: - Helpers

    private func roundTrip<T: Codable & Hashable>(_ value: T, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(back, value, "\(label) did not survive a Codable round trip", file: file, line: line)
        XCTAssertEqual(Set([value, back]).count, 1, "\(label) hashes two equal values apart", file: file, line: line)
    }

    /// A genuine `.text` `ContentBlock` built from a value the test constructed — no engine byte, no JSON literal.
    private static func textBlock(_ text: String) throws -> ContentBlock {
        let value = JSONValue.object(["type": .string("text"), "text": .string(text)])
        return try JSONDecoder().decode(ContentBlock.self, from: try value.canonicalData())
    }

    /// A stream under the temporary directory: no test in this target names a config home (parent X9).
    private static func aStream() -> LogicalStream {
        LogicalStream(configHome: FileManager.default.temporaryDirectory.appendingPathComponent("afleet-timeline-model"),
                      sessionID: SessionID(uuid: UUID(uuidString: "1b9b7f4c-0000-4000-8000-00000000000a")!),
                      name: .main)
    }
}
