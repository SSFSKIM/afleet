import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

final class WindowedTranscriptTests: XCTestCase {

    /// Under the shipping policy every committed file fits whole, so nothing is windowed and nothing is extended.
    func testAWholeFileReadIsClosed() throws {
        var files = 0
        for fixture in try FixtureCorpus.all() {
            for (_, _, url) in try fixture.transcriptFiles() {
                let reader = TranscriptReader(url: url)
                let result = try WindowedTranscript.read(reader)
                XCTAssertEqual(result.extensions, 0, "\(fixture.name)/\(url.lastPathComponent): a whole file needs no extension")
                XCTAssertFalse(result.window.earlierAvailable, "\(fixture.name)/\(url.lastPathComponent): nothing lies before offset 0")
                XCTAssertEqual(result.window.continueBefore, 0)
                XCTAssertEqual(result.records, try reader.readAll().records, "\(fixture.name)/\(url.lastPathComponent)")
                files += 1
            }
        }
        XCTAssertEqual(files, 20, "the corpus census of 2026-09-05: 20 transcript files")
    }

    /// A window that begins mid-turn is extended until its earliest chain record is a turn start.
    func testTheWindowExtendsBackToATurnStart() throws {
        let fixture = try FixtureCorpus.named("nested-depth-2")
        let url = try XCTUnwrap(try fixture.transcriptFiles().first { $0.1 == .mainTranscript(slug: "_slug_") }).2
        let reader = TranscriptReader(url: url)
        let whole = try reader.readAll()
        let size = try reader.byteLength()

        // A: cut exactly at the file's one tool-result `user` record — a `user` line that is not a turn start.
        let toolResultIndex = try XCTUnwrap(whole.records.indices.first { index in
            guard case .user(let user) = whole.records[index],
                  case .blocks(let blocks) = user.fields.message.fields.content else { return false }
            return blocks.contains { if case .toolResult = $0 { return true } else { return false } }
        }, "nested-depth-2's main file carries a tool-result user record")
        let toolResultOffset = whole.ranges[toolResultIndex].offset
        let cutAtToolResult = try WindowedTranscript.read(reader, policy: WindowPolicy(wholeFileUpTo: 0, initialTail: size - toolResultOffset, earlierStep: 2048))
        XCTAssertGreaterThanOrEqual(cutAtToolResult.extensions, 1, "a window opening on a tool result is not closed")
        try assertChainStartsAtATurnStart(cutAtToolResult, whole: whole)

        // B: cut at an `assistant` record whose turn's `user` record is one step earlier, so closure lands mid-file.
        let assistantIndex = try XCTUnwrap(whole.records.indices.last { index in
            guard case .assistant = whole.records[index], index >= 2 else { return false }
            return WindowedTranscript.isTurnStart(whole.records[index - 1])
        }, "nested-depth-2's main file carries an assistant that directly follows a turn start")
        let turnStartOffset = whole.ranges[assistantIndex - 1].offset
        let assistantOffset = whole.ranges[assistantIndex].offset
        let cutAtAssistant = try WindowedTranscript.read(reader, policy: WindowPolicy(
            wholeFileUpTo: 0, initialTail: size - assistantOffset, earlierStep: assistantOffset - turnStartOffset))
        XCTAssertEqual(cutAtAssistant.extensions, 1, "one step back reaches the turn start and closes the window")
        XCTAssertEqual(cutAtAssistant.records, Array(whole.records[(assistantIndex - 1)...]),
                       "the window is the whole-file suffix that begins at that turn start")
        XCTAssertEqual(cutAtAssistant.ranges, Array(whole.ranges[(assistantIndex - 1)...]))
        XCTAssertEqual(cutAtAssistant.window.continueBefore, turnStartOffset)
        try assertChainStartsAtATurnStart(cutAtAssistant, whole: whole)
    }

    /// A window is extended until it holds the leaf the file's `last-prompt` names, and no further than the rule needs.
    func testTheWindowExtendsUntilTheNamedLeafIsInside() throws {
        let file = SyntheticTranscript.linear(turns: 40, paddingBytes: 300_000, leafTurn: 10)
        XCTAssertGreaterThan(file.data.count, 8 * 1024 * 1024, "the test needs a file above the whole-file threshold")
        let tree = try TempTree()
        let url = try tree.write(file.data, session: XCTUnwrap(SessionID(SyntheticTranscript.sessionID)), slug: "-invented-slug")
        let reader = TranscriptReader(url: url)

        let policy = WindowPolicy()
        let result = try WindowedTranscript.read(reader, policy: policy)
        let expected = Closure(file).simulate(policy: policy)
        XCTAssertEqual(result.extensions, expected.extensions, "the extension count the file's own offsets predict")
        XCTAssertGreaterThan(result.extensions, 0, "a 4 MiB tail of a 12 MiB file does not reach turn 10")
        XCTAssertTrue(result.records.contains { $0.uuid == file.leafUUID }, "the named leaf is inside the closed window")
        XCTAssertEqual(WindowedTranscript.openReason(result.records), nil, "and the window is closed")
        XCTAssertEqual(result.ranges.first?.offset, file.ranges[expected.firstIndex].offset, "the window begins at a record the file wrote")
        XCTAssertTrue(file.turnStarts.contains(expected.firstIndex), "and that record is a turn start")
        XCTAssertEqual(result.records, Array(try reader.readAll().records[expected.firstIndex...]))
    }

    /// A window that can never close still stops: it reaches offset 0 and becomes the whole file.
    func testClosureStopsAtOffsetZero() throws {
        let fixture = try FixtureCorpus.named("plain-two-turn")
        let url = try XCTUnwrap(try fixture.transcriptFiles().first).2
        let reader = TranscriptReader(url: url)
        let result = try WindowedTranscript.read(reader, policy: WindowPolicy(wholeFileUpTo: 0, initialTail: 1, earlierStep: 4 * 1024 * 1024))
        XCTAssertFalse(result.window.earlierAvailable, "the walk stopped because it reached offset 0")
        XCTAssertEqual(result.window.continueBefore, 0)
        XCTAssertEqual(result.records, try reader.readAll().records)
        XCTAssertEqual(result.ranges, try reader.readAll().ranges)
    }

    /// Every reported range addresses exactly the bytes of the record it stands beside.
    func testRangesAddressEveryRecord() throws {
        var checked = 0
        for fixture in try FixtureCorpus.all() {
            for (_, _, url) in try fixture.transcriptFiles() {
                let reader = TranscriptReader(url: url)
                let result = try reader.readAll()
                for (index, range) in result.ranges.enumerated() {
                    let bytes = try reader.read(at: range.offset, length: range.length)
                    XCTAssertEqual(RecordDecoder.decode(line: bytes, byteOffset: range.offset), result.records[index],
                                   "\(fixture.name)/\(url.lastPathComponent): range \(index) does not address its record")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 611, "the corpus census of 2026-09-05: every record addressed by its range")
    }

    /// *Load earlier*, step by step, from a rewound file: every step prepends the records that lie before the window,
    /// and the walk ends at offset 0 having assembled the whole file exactly once.
    func testLoadEarlierPrependsUntilClosedAndReachesOffsetZero() throws {
        let file = SyntheticTranscript.rewound(turns: 30, paddingBytes: 300_000, rewindAfterTurn: 12, thenTurns: 10)
        XCTAssertGreaterThan(file.data.count, 8 * 1024 * 1024, "the test needs a file above the whole-file threshold")
        let tree = try TempTree()
        let url = try tree.write(file.data, session: XCTUnwrap(SessionID(SyntheticTranscript.sessionID)), slug: "-invented-slug")
        let reader = TranscriptReader(url: url)

        let policy = WindowPolicy()
        let expected = Closure(file).simulate(policy: policy)
        let opened = try WindowedTranscript.read(reader, policy: policy)
        XCTAssertEqual(opened.extensions, expected.extensions, "the opening read's extension count the file predicts")

        var held = opened.records
        var ranges = opened.ranges
        var window = opened.window
        var steps: [Int] = []
        while window.earlierAvailable {
            // Bounded on purpose: a step that fails to move the marker would otherwise spin here for ever.
            guard steps.count < 64 else { return XCTFail("Load earlier did not reach offset 0 in 64 steps") }
            let previousStart = window.continueBefore
            let earlier = try WindowedTranscript.readEarlier(reader, held: held, window: window, policy: policy)
            XCTAssertGreaterThan(earlier.records.count, 0, "a step that reports earlier bytes must return records")
            let last = try XCTUnwrap(earlier.ranges.last)
            XCTAssertEqual(last.offset + last.length + 1, previousStart, "each step's new records end where the window began")
            steps.append(earlier.extensions)
            held = earlier.records + held
            ranges = earlier.ranges + ranges
            window = earlier.window
        }
        XCTAssertEqual(window.continueBefore, 0, "the walk ends at the start of the file")
        XCTAssertEqual(steps, expected.calls, "the step counts the file's own offsets predict")
        XCTAssertEqual(ranges, file.ranges, "the assembled ranges cover every record the generator wrote, exactly once")
        XCTAssertEqual(Set(ranges).count, ranges.count, "and no range was reported twice")
        XCTAssertEqual(held, try reader.readAll().records, "the assembled records are the whole file, in order")

        let exhausted = try WindowedTranscript.readEarlier(reader, held: held, window: window, policy: policy)
        XCTAssertEqual(exhausted.records.count, 0, "at offset 0 there is nothing left to load")
        XCTAssertFalse(exhausted.window.earlierAvailable)
    }

    // MARK: - Helpers

    private func assertChainStartsAtATurnStart(_ result: WindowedTranscript.Result, whole: ReadResult,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(WindowedTranscript.openReason(result.records), "the window must be closed", file: file, line: line)
        let leaf = try XCTUnwrap(WindowedTranscript.namedLeaf(result.records), file: file, line: line)
        var byUUID: [String: TranscriptRecord] = [:]
        for record in result.records { if let uuid = record.uuid { byUUID[uuid] = record } }
        var current = try XCTUnwrap(byUUID[leaf], file: file, line: line)
        while let parent = WindowedTranscript.parentUUID(of: current), let next = byUUID[parent] { current = next }
        XCTAssertTrue(WindowedTranscript.isTurnStart(current) || WindowedTranscript.parentUUID(of: current) == nil,
                      "the earliest chain record in the window is a turn start or the file's first record",
                      file: file, line: line)
        XCTAssertTrue(whole.records.contains(current), file: file, line: line)
    }

    /// The closure rule of the child spec (v2.2) restated over a synthetic file's own bytes and its own reported
    /// offsets. It shares no code with `WindowedTranscript`, so the step counts it predicts are the file's, not the
    /// reader's.
    private struct Closure {
        let file: SyntheticTranscript.File
        private let uuids: [String?]
        private let parents: [String?]
        private let indexOf: [String: Int]

        init(_ file: SyntheticTranscript.File) {
            self.file = file
            var uuids: [String?] = [], parents: [String?] = [], indexOf: [String: Int] = [:]
            for (position, range) in file.ranges.enumerated() {
                let line = file.data.subdata(in: range.offset..<(range.offset + range.length))
                let object = (try? JSONDecoder().decode(JSONValue.self, from: line))?.objectValue ?? [:]
                let uuid = object["uuid"]?.stringValue
                uuids.append(uuid)
                parents.append(object["parentUuid"]?.stringValue)
                if let uuid { indexOf[uuid] = position }
            }
            self.uuids = uuids; self.parents = parents; self.indexOf = indexOf
        }

        /// The first record index at or after a byte offset.
        func firstIndex(atOrAfter offset: Int) -> Int? { file.ranges.firstIndex { $0.offset >= offset } }

        /// Both halves of the rule for a window that begins at record `first`.
        func isClosed(from offset: Int) -> Bool {
            guard let first = firstIndex(atOrAfter: offset), first <= file.leafIndex else { return false }
            var position = file.leafIndex
            while true {
                guard let parent = parents[position] else { return true }        // the chain's own root
                guard let next = indexOf[parent], next >= first else { return file.turnStarts.contains(position) }
                position = next
            }
        }

        /// The smallest line start at or after `offset`, the way the reader's probe finds it.
        func aligned(_ offset: Int) -> Int { file.ranges.first { $0.offset >= offset }?.offset ?? file.data.count }

        /// One `readEarlier`, including the step doubling a record longer than one step forces.
        func stepBack(from start: Int, policy: WindowPolicy) -> (next: Int, earlier: Bool) {
            var step = max(1, policy.earlierStep)
            while true {
                if step >= start { return (0, false) }
                let candidate = aligned(start - step)
                if candidate < start { return (candidate, true) }
                step = min(start, step * 2)
            }
        }

        /// The opening read's extension count, then one entry per *Load earlier* call with that call's own step count.
        func simulate(policy: WindowPolicy) -> (extensions: Int, calls: [Int], firstIndex: Int) {
            let size = file.data.count
            var start = 0
            var earlier = false
            if size > policy.wholeFileUpTo, policy.initialTail < size {
                start = aligned(size - policy.initialTail)
                earlier = true
            }
            var extensions = 0
            while earlier && !isClosed(from: start) {
                (start, earlier) = stepBack(from: start, policy: policy); extensions += 1
            }
            let opening = firstIndex(atOrAfter: start) ?? 0      // where the opening read's window begins
            var calls: [Int] = []
            while earlier {
                var inner = 0
                repeat {
                    (start, earlier) = stepBack(from: start, policy: policy); inner += 1
                } while earlier && !isClosed(from: start)
                calls.append(inner)
            }
            return (extensions, calls, opening)
        }
    }
}
