import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

final class TranscriptReaderTests: XCTestCase {

    /// Every committed transcript file, read whole: one record per non-empty line, per file, and the corpus total is
    /// Task 1's census figure for the transcript files alone.
    func testReadAllDecodesEveryLineOfEveryCorpusFile() throws {
        var total = 0
        for fixture in try FixtureCorpus.all() {
            for (_, _, url) in try fixture.transcriptFiles() {
                let expected = try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }.count
                let result = try TranscriptReader(url: url).readAll()
                XCTAssertEqual(result.records.count, expected, "\(fixture.name)/\(url.lastPathComponent): records per non-empty line")
                XCTAssertEqual(result.ranges.count, result.records.count, "\(fixture.name): ranges are parallel to records")
                let undecodable = result.records.filter { if case .undecodable = $0 { return true } else { return false } }
                XCTAssertEqual(undecodable.count, 0, "\(fixture.name)/\(url.lastPathComponent): a recorded line did not decode")
                total += result.records.count
            }
        }
        XCTAssertEqual(total, 611, "the corpus census of 2026-09-05: records across the 20 transcript files")
    }

    /// A record delivered in two appends is never decoded half-written: the first append advances nothing, the second
    /// yields exactly one record.
    func testATornTailIsHeldBackAndCompletedByTheNextAppend() throws {
        let tree = try TempTree()
        let fixture = try FixtureCorpus.named("plain-two-turn")
        let url = try tree.add(fixture, slug: "-invented-slug")
        let reader = TranscriptReader(url: url)

        let whole = try reader.readAll()
        let complete = whole.length
        XCTAssertEqual(complete, try reader.byteLength(), "the recording ends on a newline, so the whole file is consumed")

        // A repeat of the file's own last line, delivered in two pieces: no invented content, just a torn write.
        let line = try XCTUnwrap(LineScanner.scan(try Data(contentsOf: url)).lines.last).bytes
        try tree.appendRaw(line.prefix(line.count / 2), to: url)
        let torn = try reader.readAppended(from: complete)
        XCTAssertEqual(torn.records.count, 0, "a line without its terminator is held back, never decoded")
        XCTAssertEqual(torn.length, complete, "the held-back tail must not advance the append offset")

        var rest = Data(line.suffix(from: line.startIndex + line.count / 2))
        rest.append(UInt8(ascii: "\n"))
        try tree.appendRaw(rest, to: url)
        let completed = try reader.readAppended(from: complete)
        XCTAssertEqual(completed.records.count, 1, "the next append completes the record")
        XCTAssertEqual(completed.length, try reader.byteLength(), "and the offset moves to the end of the file")
        XCTAssertEqual(completed.records[0], RecordDecoder.decode(line: line, byteOffset: complete),
                       "the record decoded from the two halves is the record the whole line decodes to")
    }

    /// The engine seals a torn tail by writing a leading `\n` before the next record; that empty line is not a record.
    func testASealedTailIsSkipped() throws {
        let tree = try TempTree()
        let fixture = try FixtureCorpus.named("plain-two-turn")
        let url = try tree.add(fixture, slug: "-invented-slug")
        let reader = TranscriptReader(url: url)
        let before = try reader.readAll()

        let line = try XCTUnwrap(LineScanner.scan(try Data(contentsOf: url)).lines.last).bytes
        var sealed = Data([UInt8(ascii: "\n")])
        sealed.append(line)
        sealed.append(UInt8(ascii: "\n"))
        try tree.appendRaw(sealed, to: url)

        let appended = try reader.readAppended(from: before.length)
        XCTAssertEqual(appended.records.count, 1, "the seal is a line terminator, not an empty record")
        let after = try reader.readAll()
        XCTAssertEqual(after.records.count, before.records.count + 1, "and the whole-file read agrees")
        XCTAssertEqual(Array(after.records.prefix(before.records.count)), before.records, "no earlier record moved")
    }

    /// One unparseable line becomes exactly one `.undecodable` naming its byte offset; its neighbours are untouched.
    func testOneCorruptLineYieldsOneUndecodable() throws {
        let tree = try TempTree()
        let fixture = try FixtureCorpus.named("plain-two-turn")
        let source = try Data(contentsOf: XCTUnwrap(try fixture.transcriptFiles().first).2)
        let lines = LineScanner.scan(source).lines
        let cut = try XCTUnwrap(lines.dropFirst(5).first).offset          // a line start in the middle of the file

        let corrupt = Data("this line is not json at all\n".utf8)
        var mutated = source.prefix(cut)
        mutated.append(corrupt)
        mutated.append(source.suffix(from: source.startIndex + cut))
        let url = try tree.write(Data(mutated), session: fixture.sessionID, slug: "-invented-slug")

        let result = try TranscriptReader(url: url).readAll()
        var offsets: [Int] = []
        for (index, record) in result.records.enumerated() {
            if case .undecodable(_, let offset, let reason) = record {
                offsets.append(offset)
                XCTAssertEqual(reason, "invalid_json")
                XCTAssertEqual(result.ranges[index], ByteRange(offset: cut, length: corrupt.count - 1))
            }
        }
        XCTAssertEqual(offsets, [cut], "exactly one undecodable record, at the inserted line's byte offset")
        let original = try TranscriptReader(url: XCTUnwrap(try fixture.transcriptFiles().first).2).readAll()
        XCTAssertEqual(result.records.filter { if case .undecodable = $0 { return false } else { return true } },
                       original.records, "every other record survived the corruption unchanged")
    }

    /// A window begins at a line start, its marker points there, and one step earlier reaches offset 0 and rejoins.
    func testWindowAlignsToALineStart() throws {
        let fixture = try FixtureCorpus.named("nested-depth-2")
        let url = try XCTUnwrap(try fixture.transcriptFiles().first { $0.1 == .mainTranscript(slug: "_slug_") }).2
        let reader = TranscriptReader(url: url)
        let whole = try reader.readAll()

        let window = try reader.readWindow(policy: WindowPolicy(wholeFileUpTo: 0, initialTail: 2000, earlierStep: 4 * 1024 * 1024))
        let marker = try XCTUnwrap(window.window)
        XCTAssertTrue(marker.earlierAvailable)
        XCTAssertGreaterThan(window.records.count, 0, "2000 bytes of this file span at least one whole record")
        XCTAssertEqual(marker.continueBefore, window.ranges[0].offset, "the marker is the first record's byte offset")
        XCTAssertTrue(whole.ranges.contains(window.ranges[0]), "and that offset is a line start of the whole file")

        let earlier = try reader.readEarlier(before: marker.continueBefore)
        let earlierMarker = try XCTUnwrap(earlier.window)
        XCTAssertFalse(earlierMarker.earlierAvailable, "one 4 MiB step reaches the start of a 188 KiB file")
        XCTAssertEqual(earlierMarker.continueBefore, 0)
        XCTAssertEqual(earlier.records + window.records, whole.records, "the two halves are the whole file, in order")
        XCTAssertEqual(earlier.ranges + window.ranges, whole.ranges)
    }

    func testSymlinkAndDirectoryAreRefused() throws {
        let tree = try TempTree()
        let fixture = try FixtureCorpus.named("plain-two-turn")
        let real = try tree.add(fixture, slug: "-invented-slug")

        let link = tree.projects.appendingPathComponent("a-symlink.jsonl")
        try tree.symlink(link, to: real)
        XCTAssertThrowsError(try TranscriptReader(url: link).readAll()) { error in
            XCTAssertEqual(error as? ReaderError, .symlinkRefused, "a symlink is refused by O_NOFOLLOW, not followed")
        }
        XCTAssertThrowsError(try TranscriptReader(url: tree.projects).readAll()) { error in
            XCTAssertEqual(error as? ReaderError, .notARegularFile)
        }
        XCTAssertNoThrow(try TranscriptReader(url: real).readAll(), "the file the symlink pointed at is readable")
    }
}
