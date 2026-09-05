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
        XCTAssertTrue(durable.isDisjoint(with: overlay),
                      "a category is durable or overlay, never both: \(durable.intersection(overlay).map(\.rawValue).sorted())")
        XCTAssertEqual(durable.union(overlay).union([.opaque]), Set(TimelineCategory.allCases),
                       "durable ∪ overlay ∪ opaque must name every category exactly once")
        XCTAssertEqual(TimelineCategory.allCases.count, 13)
        XCTAssertTrue(ProjectionCategories.comparedWireToFile.isSubset(of: durable),
                      "check one only compares durable categories: \(ProjectionCategories.comparedWireToFile.subtracting(durable).map(\.rawValue).sorted())")
        // The 2026-09-05 parent amendment: the boundary is on the wire, so it is durable but not file-only.
        XCTAssertTrue(durable.contains(.compactBoundary))
        XCTAssertFalse(ProjectionCategories.comparedWireToFile.contains(.compactBoundary))
        XCTAssertFalse(ProjectionCategories.fileOnlyRecordKinds.contains(.system("compact_boundary")))
        XCTAssertEqual(ProjectionCategories.excludedItemFields, ["stop_reason", "usage", "signature", "timestamp"])
        XCTAssertEqual(ProjectionCategories.comparedItemFields.fields.count, 5)
    }

    // MARK: - The file-only matchers, against the corpus

    /// Every attachment in the corpus and both `isMeta` user records match a file-only matcher; no other record does.
    /// The count is pinned as an equality against the census (200 attachments + 2 meta users = 202) and grounded by
    /// the two per-kind equalities beside it, so a matcher that over- or under-matches cannot pass.
    func testFileOnlyMatchersRecogniseTheCorpusAttachmentsAndMetaUsers() throws {
        let matchers = ProjectionCategories.fileOnlyRecordKinds
        var matched = 0, attachments = 0, matchedAttachments = 0, metaUsers = 0, plainUsers = 0, records = 0
        var matchedKinds: Set<String> = []
        for fx in try FixtureCorpus.all() {
            for (_, _, url) in try fx.transcriptFiles() {
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
                        } else {
                            plainUsers += 1
                            XCTAssertFalse(hit, "\(fx.name): a plain user record must not match a file-only matcher")
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
        XCTAssertEqual(plainUsers, 69)
        XCTAssertEqual(matched, 202, "the file-only matchers must select exactly the 200 attachments and 2 isMeta users")
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
