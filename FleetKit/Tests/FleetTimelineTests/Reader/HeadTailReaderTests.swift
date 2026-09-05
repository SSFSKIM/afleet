import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

final class HeadTailReaderTests: XCTestCase {

    /// Every committed transcript file: the stat is the file's, and a file that fits in one chunk has head == tail == all of it.
    func testReadsHeadAndTailAndStatOfEveryCorpusFile() throws {
        let reader = HeadTailReader()
        var small = 0, large = 0
        for fixture in try FixtureCorpus.all() {
            for (_, _, url) in try fixture.transcriptFiles() {
                let data = try Data(contentsOf: url)
                let read = try XCTUnwrap(reader.read(url), "\(fixture.name)/\(url.lastPathComponent): a regular file must read")
                XCTAssertEqual(read.size, Int64(data.count), "\(fixture.name)/\(url.lastPathComponent): size is the file's byte count")
                XCTAssertEqual(read.head, String(decoding: data.prefix(HeadTailReader.chunk), as: UTF8.self),
                               "\(fixture.name)/\(url.lastPathComponent): head is the first chunk")
                if data.count <= HeadTailReader.chunk {
                    XCTAssertEqual(read.head, read.tail, "\(fixture.name)/\(url.lastPathComponent): one chunk covers the file")
                    XCTAssertEqual(read.tail, String(decoding: data, as: UTF8.self))
                    small += 1
                } else {
                    XCTAssertEqual(read.tail, String(decoding: data.suffix(HeadTailReader.chunk), as: UTF8.self),
                                   "\(fixture.name)/\(url.lastPathComponent): tail is the last chunk")
                    large += 1
                }
                let stated = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                XCTAssertEqual(read.mtime.timeIntervalSince1970, stated.timeIntervalSince1970, accuracy: 0.002,
                               "\(fixture.name)/\(url.lastPathComponent): mtime is the file's")
            }
        }
        XCTAssertEqual(small + large, 20, "the corpus census of 2026-09-05: 20 transcript files")
        XCTAssertGreaterThan(small, 0, "the corpus carries files under one chunk")
        XCTAssertGreaterThan(large, 0, "and files over it")
        XCTAssertNil(try reader.read(FixtureCorpus.root), "a directory is not a file the picker reads")
    }

    /// The four substring helpers against recorded bytes, each read the way the picker reads it.
    func testHelpersMatchTheEngineOnTheCorpus() throws {
        let reader = HeadTailReader()

        let relocation = try FixtureCorpus.named("session-mirror-relocation")
        let relocationURL = try XCTUnwrap(try relocation.transcriptFiles().first).2
        let relocated = try XCTUnwrap(reader.read(relocationURL))
        let recordedCwd = try XCTUnwrap(HeadTailReader.firstLineString(relocated.head, key: "cwd"),
                                        "the first line carrying a cwd names the session's directory")
        let relocatedCwd = try XCTUnwrap(HeadTailReader.lastLineString(relocated.tail, type: nil, key: "relocatedCwd"),
                                         "the last line carrying a relocatedCwd names where the session moved to")
        XCTAssertNotEqual(recordedCwd, relocatedCwd, "a relocation moved the session, so the two differ")
        // The engine's type prefilter (`V`, line 13408) is written unspaced — `"type":"relocated"` — and the committed
        // recordings are pretty-printed with a space, so the typed lookup finds nothing in them. Against the same record
        // re-encoded compactly, as the engine writes it, the typed lookup does find it. The record is the recording's;
        // only its whitespace is the test's.
        XCTAssertNil(HeadTailReader.lastLineString(relocated.tail, type: "relocated", key: "relocatedCwd"),
                     "the recording spells the key with a space, which the engine's unspaced prefilter never matches")
        let compact = try TranscriptReader(url: relocationURL).readAll().records
            .filter { $0.kind == "relocated" }
            .map { String(decoding: try JSONDecoder().decode(JSONValue.self, from: RecordDecoder.encode($0)).canonicalData(), as: UTF8.self) }
            .joined(separator: "\n")
        XCTAssertEqual(HeadTailReader.lastLineString(compact, type: "relocated", key: "relocatedCwd"), relocatedCwd,
                       "written as the engine writes it, the typed lookup returns the same value")

        let plain = try FixtureCorpus.named("plain-two-turn")
        let plainURL = try XCTUnwrap(try plain.transcriptFiles().first).2
        let head = try XCTUnwrap(reader.read(plainURL))
        let prompts = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: plain.dir.appendingPathComponent("fixture.json")))["prompts"]?.arrayValue)
        XCTAssertEqual(HeadTailReader.firstPrompt(head.head), prompts[0].stringValue,
                       "the picker's first prompt is the prompt the recording says it sent first")
        XCTAssertNotNil(HeadTailReader.lastString(head.tail, key: "aiTitle"), "this recording carries an ai-title record")
        XCTAssertEqual(HeadTailReader.firstString(head.head, key: "sessionId"), plain.sessionID.description,
                       "the first sessionId in the head is the recording's session")
        XCTAssertNil(HeadTailReader.firstString(head.head, key: "aKeyNoRecordCarries"))
    }

    /// A tool result, an `isMeta` notice and a compact summary in front of the prompt do not become the prompt.
    /// The three decoys are the recording's own prompt line with one field changed in memory (parent §11).
    func testFirstPromptSkipsToolResultsMetaAndCompactSummary() throws {
        let plain = try FixtureCorpus.named("plain-two-turn")
        let url = try XCTUnwrap(try plain.transcriptFiles().first).2
        let head = try XCTUnwrap(HeadTailReader().read(url))
        let prompt = HeadTailReader.firstPrompt(head.head)
        XCTAssertFalse(prompt.isEmpty, "the recording's head carries a prompt to find")

        let promptLine = try XCTUnwrap(head.head.split(separator: "\n").first { $0.contains("\"type\": \"user\"") || $0.contains("\"type\":\"user\"") })
        let object = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(promptLine.utf8)).objectValue)

        func mutated(_ edit: (inout [String: JSONValue]) -> Void) throws -> String {
            var copy = object
            edit(&copy)
            return String(decoding: try JSONValue.object(copy).canonicalData(), as: UTF8.self)
        }
        let toolResult = try mutated {
            $0["uuid"] = .string("00000000-0000-4000-8000-000000000001")
            $0["message"] = .object(["role": .string("user"),
                                     "content": .array([.object(["type": .string("tool_result"),
                                                                 "tool_use_id": .string("toolu_invented"),
                                                                 "content": .string("a result no prompt should become")])])])
        }
        let meta = try mutated {
            $0["uuid"] = .string("00000000-0000-4000-8000-000000000002")
            $0["isMeta"] = .bool(true)
            $0["message"] = .object(["role": .string("user"), "content": .string("a meta notice no prompt should become")])
        }
        let compactSummary = try mutated {
            $0["uuid"] = .string("00000000-0000-4000-8000-000000000003")
            $0["isCompactSummary"] = .bool(true)
            $0["message"] = .object(["role": .string("user"), "content": .string("a compact summary no prompt should become")])
        }
        for decoy in [toolResult, meta, compactSummary] {
            XCTAssertEqual(HeadTailReader.firstPrompt(decoy + "\n" + head.head), prompt, "a decoy in front of the prompt is skipped")
        }
        XCTAssertEqual(HeadTailReader.firstPrompt([toolResult, meta, compactSummary].joined(separator: "\n") + "\n" + head.head), prompt,
                       "and all three together are skipped")
        XCTAssertEqual(HeadTailReader.firstPrompt([toolResult, meta, compactSummary].joined(separator: "\n")), "",
                       "with nothing but decoys there is no prompt")
    }
}
