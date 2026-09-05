import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

final class RecordModelTests: XCTestCase {

    // MARK: - The corpus

    /// Every record in every transcript file and every mirror entry round-trips key for key. The floor is the corpus's own
    /// record count, asserted as an equality so a loader that skipped a file cannot pass.
    func testEveryCorpusRecordRoundTripsLosslessly() throws {
        var fileRecords = 0, mirrorEntries = 0, kinds: Set<String> = []
        for fx in try FixtureCorpus.all() {
            for (_, _, url) in try fx.transcriptFiles() {
                for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    let original = try JSONDecoder().decode(JSONValue.self, from: Data(line))
                    let record = RecordDecoder.decode(line: Data(line))
                    if case .undecodable(_, _, let reason) = record {
                        XCTFail("\(fx.name): a record failed to decode (\(reason))"); continue
                    }
                    if case .unknown(let k, _) = record { XCTFail("\(fx.name): unknown record kind \(k)"); continue }
                    let again = try JSONDecoder().decode(JSONValue.self, from: try RecordDecoder.encode(record))
                    XCTAssertTrue(again.numericallyEqual(original), "\(fx.name): \(record.kind) lost a key or value")
                    kinds.insert(record.kind); fileRecords += 1
                }
            }
            for f in try fx.frames() {
                guard case .transcriptMirror(let m) = f.frame else { continue }
                for entry in m.entries {
                    let record = RecordDecoder.decode(entry: entry)
                    if case .unknown(let k, _) = record { XCTFail("\(fx.name): unknown mirror kind \(k)") }
                    if case .undecodable(_, _, let reason) = record {
                        XCTFail("\(fx.name): a mirror entry failed to decode (\(reason))"); continue
                    }
                    let again = try JSONDecoder().decode(JSONValue.self, from: try RecordDecoder.encode(record))
                    XCTAssertTrue(again.numericallyEqual(entry), "\(fx.name): mirrored \(record.kind) lost a key or value")
                    kinds.insert(record.kind); mirrorEntries += 1
                }
            }
        }
        XCTAssertEqual(fileRecords, 760)      // the corpus census of 2026-09-06 (twenty fixtures); re-pin when C1 re-records
        XCTAssertEqual(mirrorEntries, 521)
        // `system`, `bridge-session`, `cost-state` and `permission-mode` joined the census with `rewind-turn` and
        // `compact-boundary`; the boundary is the corpus's first `system` record of any subtype.
        XCTAssertEqual(kinds, ["user", "assistant", "attachment", "system", "queue-operation", "file-history-snapshot",
                               "file-history-delta", "atis-latch", "bridge-session", "cost-state", "last-prompt",
                               "ai-title", "mode", "permission-mode", "relocated", "agent_metadata"])
    }

    // MARK: - Keys

    func testKeysUseUUIDForConversationRecordsAndAHashOtherwise() throws {
        let stream = Self.aStream()
        let user = try Self.firstRecordedRecord(ofKind: "user")
        let uuid = try XCTUnwrap(user.uuid, "the corpus's user records carry a uuid")
        XCTAssertNil(user.contentHash, "a record with a uuid has no content hash")
        XCTAssertEqual(user.key(in: stream, ordinal: 0).identity, .uuid(uuid))
        XCTAssertEqual(user.key(in: stream, ordinal: 7).identity, .uuid(uuid),
                       "a uuid key ignores the ordinal it is handed")

        let title = try Self.firstRecordedRecord(ofKind: "ai-title")
        XCTAssertNil(title.uuid, "ai-title is one of the kinds the engine writes without a uuid")
        let hash = try XCTUnwrap(title.contentHash)
        XCTAssertEqual(title.key(in: stream, ordinal: 3).identity, .hash(hash, ordinal: 3))
        XCTAssertEqual(title.key(in: stream, ordinal: 3).stream, stream)

        // Two *distinct* byte-identical lines of the same file — different byte offsets, so a hash that took
        // position or record identity into account would separate them — are one content hash.
        let (first, second) = try Self.twoByteEqualLines(ofKind: "ai-title")
        XCTAssertNotEqual(first.offset, second.offset, "the two lines must be distinct occurrences, not one line read twice")
        XCTAssertEqual(first.line, second.line, "the two lines must be byte-identical for this to be a hash test")
        let firstHash = RecordDecoder.decode(line: first.line, byteOffset: first.offset).contentHash
        let secondHash = RecordDecoder.decode(line: second.line, byteOffset: second.offset).contentHash
        XCTAssertNotNil(firstHash)
        XCTAssertEqual(firstHash, secondHash, "two byte-identical uuid-less lines must share one content hash")
        let edited = RecordDecoder.decode(entry: try Self.editing(title, key: "aiTitle", to: .string("a title this recording does not carry")))
        XCTAssertEqual(edited.kind, "ai-title")
        XCTAssertNotEqual(edited.contentHash, hash, "one differing field must hash differently")
    }

    /// The same object in two key orders — the file's order and the mirror's — is one content hash, for an `ai-title` line and an
    /// `agent_metadata` line written by the test with invented values; and across the corpus every mirrored uuid-less entry
    /// hashes equal to the file line it mirrors.
    func testUUIDLessKeysAreCanonicalAcrossKeyOrderAndDelivery() throws {
        // Invented values, schema shape only: no engine byte is involved.
        let title = #"{"type":"ai-title","aiTitle":"t","sessionId":"11111111-1111-4111-8111-111111111111"}"#
        let titleReversed = #"{"sessionId":"11111111-1111-4111-8111-111111111111","aiTitle":"t","type":"ai-title"}"#
        XCTAssertEqual(RecordDecoder.decode(line: Data(title.utf8)).contentHash,
                       RecordDecoder.decode(line: Data(titleReversed.utf8)).contentHash)
        let meta = #"{"type":"agent_metadata","agentType":"Explore","description":"d","toolUseId":"toolu_invented","spawnDepth":1}"#
        let metaReversed = #"{"spawnDepth":1,"toolUseId":"toolu_invented","description":"d","agentType":"Explore","type":"agent_metadata"}"#
        XCTAssertEqual(RecordDecoder.decode(line: Data(meta.utf8)).contentHash,
                       RecordDecoder.decode(line: Data(metaReversed.utf8)).contentHash)

        // The corpus property: every uuid-less mirror entry hashes to a line in the file it mirrors.
        var checked = 0
        var missing: Set<String> = []          // "<fixture>/<kind>" for anything the paired file does not carry
        for fx in try FixtureCorpus.all() {
            var byStream: [LogicalStream: Set<String>] = [:]
            for (stream, _, url) in try fx.transcriptFiles() {
                var hashes: Set<String> = []
                for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    if let hash = RecordDecoder.decode(line: Data(line)).contentHash { hashes.insert(hash) }
                }
                byStream[stream] = hashes
            }
            for f in try fx.frames() {
                guard case .transcriptMirror(let m) = f.frame else { continue }
                let path = URL(fileURLWithPath: m.filePath)
                guard let (stream, _) = TranscriptPath.resolve(path, under: FixtureCorpus.recordedConfigHome) else {
                    XCTFail("\(fx.name): a mirror filePath did not resolve to a stream"); continue
                }
                for entry in m.entries {
                    let record = RecordDecoder.decode(entry: entry)
                    // `agent_metadata` is the sidecar's body with `type` added by the mirror writer, so it has no matching
                    // line in the `.jsonl` the frame names; it is checked against its own sidecar below.
                    guard record.kind != "agent_metadata", let hash = record.contentHash else { continue }
                    checked += 1
                    if !(byStream[stream] ?? []).contains(hash) { missing.insert("\(fx.name)/\(record.kind)") }
                }
            }
        }
        XCTAssertEqual(missing, [], "a mirrored uuid-less entry hashed unlike every line of the file it mirrors")
        XCTAssertEqual(checked, 188, "the census of 2026-09-06: uuid-less mirror entries other than agent_metadata")

        // The one mirrored kind whose file form differs: the sidecar plus `type`, and the mirror agree by hash.
        var sidecars = 0
        for name in ["explore-depth-1", "nested-depth-2"] {
            let fx = try FixtureCorpus.named(name)
            var expected: Set<String> = []
            for (_, url) in try fx.metaFiles() {
                var body = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: url)).objectValue)
                body["type"] = .string("agent_metadata")
                expected.insert(RecordDecoder.canonicalHash(of: .object(body)))
            }
            for f in try fx.frames() {
                guard case .transcriptMirror(let m) = f.frame else { continue }
                for entry in m.entries where entry["type"]?.stringValue == "agent_metadata" {
                    let hash = try XCTUnwrap(RecordDecoder.decode(entry: entry).contentHash)
                    XCTAssertTrue(expected.contains(hash), "\(name): a mirrored agent_metadata matched no sidecar")
                    sidecars += 1
                }
            }
        }
        XCTAssertEqual(sidecars, 3, "the census of 2026-09-05: three mirrored agent_metadata entries")
    }

    /// The engine keeps repeated state records and so must the key (`vbr`, line 429460). Over every corpus transcript file,
    /// `RecordKey.keys(for:in:)` yields no duplicate key and as many keys as lines; the keys with `ordinal > 0`, counted
    /// independently by grouping the file's uuid-less lines by `contentHash`, number forty-eight across fourteen files in thirty
    /// groups (`atis-latch`, `ai-title`, `relocated`) — the census of 2026-09-05, re-pinned only when C1 re-records.
    func testRepeatedUUIDLessLinesKeepTheirMultiplicity() throws {
        var repeats = 0, groups = 0, filesWithRepeats = 0
        var repeatedKinds: Set<String> = []
        for fx in try FixtureCorpus.all() {
            for (stream, _, url) in try fx.transcriptFiles() {
                var records: [TranscriptRecord] = []
                for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    records.append(RecordDecoder.decode(line: Data(line)))
                }
                let keys = RecordKey.keys(for: records, in: stream)
                XCTAssertEqual(keys.count, records.count, "\(fx.name): a record lost its key")
                XCTAssertEqual(Set(keys).count, keys.count, "\(fx.name): two records share one key")

                // The independent count: group the uuid-less lines by content hash; every occurrence after the first is a repeat.
                var byHash: [String: [TranscriptRecord]] = [:]
                for record in records where record.uuid == nil { byHash[record.contentHash!, default: []].append(record) }
                let repeated = byHash.filter { $0.value.count > 1 }
                let laterOccurrences = repeated.values.reduce(0) { $0 + $1.count - 1 }
                let ordinalsAboveZero = keys.filter { if case .hash(_, let o) = $0.identity { return o > 0 }; return false }.count
                XCTAssertEqual(laterOccurrences, ordinalsAboveZero,
                               "\(fx.name): the applier's ordinals disagree with the file's hash groups")
                if !repeated.isEmpty {
                    filesWithRepeats += 1; groups += repeated.count; repeats += laterOccurrences
                    for records in repeated.values { repeatedKinds.insert(records[0].kind) }
                }
            }
        }
        XCTAssertEqual(repeats, 65)
        XCTAssertEqual(groups, 41)
        XCTAssertEqual(filesWithRepeats, 16)
        XCTAssertEqual(repeatedKinds, ["atis-latch", "ai-title", "bridge-session", "last-prompt", "mode",
                                       "permission-mode", "relocated"])
    }

    // MARK: - Accessors and decode policy

    /// Schema-derived, no fixture carries the kind: a `continued-in` line built from 2.1.258 line 246351's shape with invented ids.
    func testContinuedInReadsTheDestinationSessionId_mutation() throws {
        let source = "11111111-1111-4111-8111-111111111111"
        let destination = "22222222-2222-4222-8222-222222222222"
        let line = #"{"type":"continued-in","timestamp":"2026-09-05T00:00:00.000Z","sessionId":"\#(source)","continuedInSessionId":"\#(destination)"}"#
        guard case .sessionState(let record, _) = RecordDecoder.decode(line: Data(line.utf8)) else {
            return XCTFail("continued-in must decode as a session-state record")
        }
        XCTAssertEqual(record.continuedInSessionId, destination)
        XCTAssertEqual(record.fields.sessionId, source)

        let without = #"{"type":"continued-in","timestamp":"2026-09-05T00:00:00.000Z","sessionId":"\#(source)"}"#
        guard case .sessionState(let bare, _) = RecordDecoder.decode(line: Data(without.utf8)) else {
            return XCTFail("continued-in must decode as a session-state record")
        }
        XCTAssertNil(bare.continuedInSessionId, "the destination is absent, so it must not fall back to the source")
        XCTAssertEqual(bare.fields.sessionId, source)
    }

    func testLeafUuidDistinguishesAbsentFromExplicitNull() throws {
        let cleared = #"{"type":"last-prompt","leafUuid":null,"explicit":true}"#
        guard case .sessionState(let record, _) = RecordDecoder.decode(line: Data(cleared.utf8)) else {
            return XCTFail("last-prompt must decode as a session-state record")
        }
        if let leaf = record.leafUuid {
            XCTAssertNil(leaf, "the recorded clear reads as .some(nil)")
        } else {
            XCTFail("an explicit null is a recorded clear, not an absent key")
        }
        XCTAssertTrue(record.explicit)

        let absent = #"{"type":"last-prompt","explicit":true}"#
        guard case .sessionState(let bare, _) = RecordDecoder.decode(line: Data(absent.utf8)) else {
            return XCTFail("last-prompt must decode as a session-state record")
        }
        XCTAssertTrue(bare.leafUuid == nil, "an absent key reads as nil, never as a clear")

        let carried = #"{"type":"last-prompt","leafUuid":"55555555-5555-4555-8555-555555555555"}"#
        guard case .sessionState(let held, _) = RecordDecoder.decode(line: Data(carried.utf8)) else {
            return XCTFail("last-prompt must decode as a session-state record")
        }
        XCTAssertEqual(held.leafUuid, .some("55555555-5555-4555-8555-555555555555"))

        // A key present with a non-string, non-null value is malformed; it must not be mistaken for a clear.
        for malformed in [#"{"type":"last-prompt","leafUuid":7}"#, #"{"type":"last-prompt","leafUuid":{"a":1}}"#] {
            guard case .sessionState(let odd, _) = RecordDecoder.decode(line: Data(malformed.utf8)) else {
                return XCTFail("last-prompt must decode as a session-state record")
            }
            XCTAssertTrue(odd.leafUuid == nil, "a non-string, non-null leafUuid is not an explicit clear")
        }
    }

    func testAKnownKindWithABrokenShapeIsUndecodableNotUnknown() throws {
        guard case .undecodable(_, let offset, let reason) = RecordDecoder.decode(line: Data(#"{"type":"user"}"#.utf8), byteOffset: 42) else {
            return XCTFail("a user record without a message is undecodable, not unknown")
        }
        XCTAssertEqual(reason, "decode_failure:user")
        XCTAssertEqual(offset, 42)

        // The contrast: an unrecognised kind stays opaque rather than becoming an alarm.
        guard case .unknown(let kind, _) = RecordDecoder.decode(line: Data(#"{"type":"a-kind-the-engine-does-not-write"}"#.utf8)) else {
            return XCTFail("an unrecognised kind is unknown, not undecodable")
        }
        XCTAssertEqual(kind, "a-kind-the-engine-does-not-write")
        XCTAssertFalse(SessionStateVocabulary.isKnown(kind))
    }

    func testResolveReadsSessionFromFileNameNotSlug() throws {
        let home = FixtureCorpus.recordedConfigHome
        let projects = home.appendingPathComponent("projects")
        let session = "33333333-3333-4333-8333-333333333333"
        let sessionID = try XCTUnwrap(SessionID(session))

        let main = projects.appendingPathComponent("-invented-slug").appendingPathComponent("\(session).jsonl")
        let resolvedMain = try XCTUnwrap(TranscriptPath.resolve(main, under: home))
        XCTAssertEqual(resolvedMain.0, LogicalStream(configHome: home, sessionID: sessionID, name: .main))
        XCTAssertEqual(resolvedMain.1, .mainTranscript(slug: "-invented-slug"))

        // A different slug for the same session id is the same logical stream: the slug is not identity.
        let elsewhere = projects.appendingPathComponent("-another-slug").appendingPathComponent("\(session).jsonl")
        XCTAssertEqual(try XCTUnwrap(TranscriptPath.resolve(elsewhere, under: home)).0, resolvedMain.0)
        XCTAssertEqual(try XCTUnwrap(TranscriptPath.resolve(elsewhere, under: home)).1, .mainTranscript(slug: "-another-slug"))

        let agentDir = projects.appendingPathComponent("-invented-slug").appendingPathComponent(session).appendingPathComponent("subagents")
        let agent = agentDir.appendingPathComponent("agent-a0invented1.jsonl")
        let resolvedAgent = try XCTUnwrap(TranscriptPath.resolve(agent, under: home))
        XCTAssertEqual(resolvedAgent.0, LogicalStream(configHome: home, sessionID: sessionID, name: .agent(taskID: "a0invented1")))
        XCTAssertEqual(resolvedAgent.1, .agentTranscript(slug: "-invented-slug", taskID: "a0invented1"))
        XCTAssertEqual(resolvedAgent.0.name.label, "agent-a0invented1")
        XCTAssertEqual(TranscriptPath.path(of: resolvedAgent.0, slug: "-invented-slug").standardizedFileURL, agent.standardizedFileURL)

        let meta = agentDir.appendingPathComponent("agent-a0invented1.meta.json")
        let resolvedMeta = try XCTUnwrap(TranscriptPath.resolve(meta, under: home))
        XCTAssertEqual(resolvedMeta.0, resolvedAgent.0)
        XCTAssertEqual(resolvedMeta.1, .agentMetadata(slug: "-invented-slug", taskID: "a0invented1"))

        XCTAssertEqual(TranscriptPath.path(of: resolvedMain.0, slug: "-invented-slug").standardizedFileURL, main.standardizedFileURL)

        // Everything else under projects/ is not a transcript stream.
        for other in [projects.appendingPathComponent("-invented-slug").appendingPathComponent("memory").appendingPathComponent("MEMORY.md"),
                      projects.appendingPathComponent("-invented-slug").appendingPathComponent(session).appendingPathComponent("tool-results").appendingPathComponent("t.json"),
                      projects.appendingPathComponent("-invented-slug").appendingPathComponent("not-a-uuid.jsonl"),
                      projects.appendingPathComponent("-invented-slug").appendingPathComponent("\(session).jsonl.tmp"),
                      projects.appendingPathComponent("\(session).jsonl"),
                      home.appendingPathComponent("history").appendingPathComponent("\(session).jsonl")] {
            XCTAssertNil(TranscriptPath.resolve(other, under: home), "\(other.lastPathComponent) is not a transcript stream")
        }
    }

    // MARK: - The vocabulary

    /// The test's own transcription of `dts` (2.1.258 `cli.pretty.js` line 428922), typed out independently of the source
    /// file's literal, compared as an exact dictionary; and `vbr`'s five "dedup-transcript" kinds (line 429460), which must
    /// be exactly `conversationKinds` (`Vr`, line 250499).
    func testVocabularyMatchesTheBundleTables() {
        // dts, minus the five kinds it folds as conversation records (`user`, `assistant`, `system`, `attachment` as
        // "transcript" and `progress` as "boundary-cleared"), which `conversationKinds` owns instead.
        let expectedDts: [String: SessionStateVocabulary.Fold] = [
            "file-history-snapshot": .boundaryCleared,
            "file-history-delta": .boundaryCleared,
            "last-prompt": .boundaryCleared,
            "continued-in": .boundaryCleared,
            "marble-origami-commit": .boundaryCleared,
            "marble-origami-snapshot": .boundaryCleared,
            "marble-origami-reset": .boundaryCleared,
            "content-replacement": .accumulate,
            "fork-context-ref": .accumulate,
            "frame-link": .accumulate,
            "artifact-comment-monitor": .accumulate,
            "summary": .lastWins,
            "custom-title": .lastWins,
            "ended-by-model": .lastWins,
            "ai-title": .lastWins,
            "tag": .lastWins,
            "relocated": .lastWins,
            "agent-name": .lastWins,
            "agent-color": .lastWins,
            "agent-setting": .lastWins,
            "pr-link": .lastWins,
            "artifact-autoreact-ledger": .lastWins,
            "bridge-session": .lastWins,
            "history-suppression": .lastWins,
            "attribution-snapshot": .lastWins,
            "mode": .lastWins,
            "permission-mode": .lastWins,
            "isolation-latch": .lastWins,
            "atis-latch": .lastWins,
            "worktree-state": .lastWins,
            "cost-state": .lastWins,
            "queue-operation": .lastWins,
            "observer-ref": .lastWins,
        ]
        XCTAssertEqual(SessionStateVocabulary.kinds, expectedDts)
        XCTAssertEqual(SessionStateVocabulary.kinds.count, 33)

        // vbr's "dedup-transcript" kinds, transcribed from line 429460; every other kind there is "always" or
        // "route-by-agent", i.e. never content-deduplicated.
        let dedupTranscript: Set<String> = ["user", "assistant", "attachment", "system", "progress"]
        XCTAssertEqual(SessionStateVocabulary.conversationKinds, dedupTranscript)
        XCTAssertEqual(SessionStateVocabulary.kinds.count + SessionStateVocabulary.conversationKinds.count, 38)
        XCTAssertTrue(Set(SessionStateVocabulary.kinds.keys).isDisjoint(with: SessionStateVocabulary.conversationKinds))
        XCTAssertTrue(SessionStateVocabulary.isKnown("cost-state"))
        XCTAssertTrue(SessionStateVocabulary.isKnown("progress"))
        XCTAssertTrue(SessionStateVocabulary.isKnown("agent_metadata"))
        XCTAssertFalse(SessionStateVocabulary.isKnown("made-up"))
    }

    // MARK: - Helpers

    private static func aStream() -> LogicalStream {
        LogicalStream(configHome: FixtureCorpus.recordedConfigHome,
                      sessionID: SessionID(uuid: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!),
                      name: .main)
    }

    /// The first record of a kind in the corpus, in fixture then file then line order. Engine bytes stay in memory.
    private static func firstRecordedRecord(ofKind kind: String) throws -> TranscriptRecord {
        for fx in try FixtureCorpus.all() {
            for (_, _, url) in try fx.transcriptFiles() {
                for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    let record = RecordDecoder.decode(line: Data(line))
                    if record.kind == kind { return record }
                }
            }
        }
        throw FixtureCorpus.Failure("no \(kind) record in the corpus")
    }

    struct RecordedLine { let line: Data; let offset: Int }

    /// The first two byte-identical occurrences of a kind within one corpus transcript file, with the byte offset
    /// each was read at. The census of 2026-09-05 pins thirty such groups across fourteen files.
    private static func twoByteEqualLines(ofKind kind: String) throws -> (RecordedLine, RecordedLine) {
        for fx in try FixtureCorpus.all() {
            for (_, _, url) in try fx.transcriptFiles() {
                var seen: [Data: Int] = [:]
                var offset = 0
                for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
                    defer { offset += line.count + 1 }
                    guard !line.isEmpty else { continue }
                    let bytes = Data(line)
                    guard RecordDecoder.decode(line: bytes).kind == kind else { continue }
                    if let earlier = seen[bytes] {
                        return (RecordedLine(line: bytes, offset: earlier), RecordedLine(line: bytes, offset: offset))
                    }
                    seen[bytes] = offset
                }
            }
        }
        throw FixtureCorpus.Failure("no two byte-identical \(kind) lines in one corpus file")
    }

    /// A recorded record with one field replaced, in memory: the mutation the discriminating tests need without inventing a recording.
    private static func editing(_ record: TranscriptRecord, key: String, to value: JSONValue) throws -> JSONValue {
        let encoded = try RecordDecoder.encode(record)
        var object = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: encoded).objectValue)
        object[key] = value
        return .object(object)
    }
}
