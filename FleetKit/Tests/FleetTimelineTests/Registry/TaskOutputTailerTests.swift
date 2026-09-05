import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// The output tailer, exercised on a copy of `background-shell`'s recorded task-output artifact and on invented files
/// under the temporary directory. Every wait here is bounded by a watchdog that stops the tailer, so a tailer that
/// never yields fails the count assertion instead of hanging the suite.
final class TaskOutputTailerTests: XCTestCase {

    /// `background-shell`'s single recorded task-output artifact, copied into a fresh temporary tree. The recording is
    /// never opened for writing; the copy is what the tailer reads.
    private func copiedArtifact(_ tree: TempTree, fixture name: String = "background-shell") throws -> URL {
        let fixture = try FixtureCorpus.named(name)
        let artifacts = fixture.dir.appendingPathComponent("artifacts")
        var found: [URL] = []
        if let walker = FileManager.default.enumerator(at: artifacts, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker where url.pathExtension == "output" { found.append(url) }
        }
        XCTAssertEqual(found.count, 1, "fixture \(name) records exactly one task-output artifact")
        let source = try XCTUnwrap(found.first)
        let destination = tree.root.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// A one-shot read of a finished output file yields the whole file and the trailer's exit code.
    func testSnapshotYieldsTheOutputAndTheExitCode() async throws {
        let tree = try TempTree()
        let url = try copiedArtifact(tree)
        let raw = try Data(contentsOf: url)
        let tailer = TaskOutputTailer(path: url)

        let chunk = try await tailer.snapshot()
        XCTAssertEqual(chunk.offset, 0)
        XCTAssertEqual(chunk.text, String(decoding: raw, as: UTF8.self), "the snapshot is the whole file")
        XCTAssertEqual(chunk.exitCode, 0, "the recorded trailer's exit code")
        XCTAssertFalse(chunk.truncatedByEngine)
        // The command's own output precedes the trailer: strip the trailer line and what is left is not empty.
        let lines = chunk.text.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.filter { !$0.isEmpty && !$0.hasPrefix("[") }
        XCTAssertEqual(body.count, 1, "one line of command output before the trailer")
        XCTAssertGreaterThan(try XCTUnwrap(body.first).count, 0)
    }

    /// Three appends, the trailer last, each driven by the arrival of the previous chunk: three chunks, contiguous
    /// offsets, the exit code only on the last, and deletion ends the stream.
    func testChunksFollowAppendsAndFinishOnDeletion() async throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("invented-task.output")
        let appends = ["alpha\n", "beta\n", "\n[exited with code 0]\n"]
        try Data(appends[0].utf8).write(to: url)

        let tailer = TaskOutputTailer(path: url, pollInterval: .milliseconds(10))
        let stream = await tailer.chunks()
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); await tailer.stop() }
        defer { watchdog.cancel() }

        var received: [OutputChunk] = []
        for await chunk in stream {
            received.append(chunk)
            if received.count < appends.count {
                try tree.appendRaw(Data(appends[received.count].utf8), to: url)
            } else if received.count == appends.count {
                try tree.remove(url)
            }
        }

        XCTAssertEqual(received.count, 3, "one chunk per append, then the stream ends on deletion")
        XCTAssertEqual(received.map(\.text), appends)
        XCTAssertEqual(received.map(\.offset), [0, 6, 11], "each chunk names the byte offset its text began at")
        XCTAssertEqual(received.map(\.exitCode), [nil, nil, 0], "only the settled trailer yields an exit code")
        XCTAssertEqual(received.map(\.truncatedByEngine), [false, false, false])
    }

    /// The engine creates the output file after it announces the task, so the tailer waits rather than finishing.
    func testAbsentFileIsWaitedFor() async throws {
        let tree = try TempTree()
        let url = tree.root.appendingPathComponent("not-yet.output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the file does not exist when the tailer starts")

        let tailer = TaskOutputTailer(path: url, pollInterval: .milliseconds(10))
        let stream = await tailer.chunks()
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); await tailer.stop() }
        defer { watchdog.cancel() }
        let writer = Task {
            try? await Task.sleep(for: .milliseconds(150))
            try? Data("late arrival\n".utf8).write(to: url)
        }
        defer { writer.cancel() }

        var first: OutputChunk?
        for await chunk in stream { first = chunk; break }
        await tailer.stop()

        let chunk = try XCTUnwrap(first, "a tailer that gave up on the absent file would end its stream with no chunk")
        XCTAssertEqual(chunk.text, "late arrival\n")
        XCTAssertEqual(chunk.offset, 0)
    }

    /// A `localAgent` entry's output file is a symlink into the agent's transcript sidecar; a consumer must open that
    /// stream through the ingestion, not tail its bytes. So a symlink is refused, exactly as the transcript reader
    /// refuses one.
    func testSymlinkIsRefused() async throws {
        let tree = try TempTree()
        let target = tree.root.appendingPathComponent("real.output")
        try Data("visible through the link\n".utf8).write(to: target)
        let link = tree.root.appendingPathComponent("linked.output")
        try tree.symlink(link, to: target)

        let tailer = TaskOutputTailer(path: link, pollInterval: .milliseconds(10))
        do {
            _ = try await tailer.snapshot()
            XCTFail("snapshot of a symlink must throw")
        } catch {
            XCTAssertEqual(error as? ReaderError, .symlinkRefused)
        }

        let stream = await tailer.chunks()
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); await tailer.stop() }
        defer { watchdog.cancel() }
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0, "a symlink ends the stream with no chunk")
    }

    /// The trailer is a whole final line of an exact shape. The same words anywhere else in the output are output.
    func testTrailerParserAcceptsOnlyTheExactShape() {
        XCTAssertEqual(OutputTrailer.parse("[exited with code 3]").exitCode, 3)
        XCTAssertEqual(OutputTrailer.parse("[exited with code 3]\n").exitCode, 3)
        XCTAssertEqual(OutputTrailer.parse("alpha\n\n[exited with code 0]\n").exitCode, 0)
        XCTAssertEqual(OutputTrailer.parse("alpha\n[exited with code 137]\n").exitCode, 137)

        XCTAssertNil(OutputTrailer.parse("the child exited with code 3 before we looked\n").exitCode,
                     "the words mid-text are output, not a trailer")
        XCTAssertNil(OutputTrailer.parse("[exited with code 3] and then more\n").exitCode)
        XCTAssertNil(OutputTrailer.parse("alpha [exited with code 3]\n").exitCode,
                     "the trailer is a whole line, not a line's tail")
        XCTAssertNil(OutputTrailer.parse("[exited with code ]\n").exitCode)
        XCTAssertNil(OutputTrailer.parse("[exited with code seven]\n").exitCode)
        XCTAssertNil(OutputTrailer.parse("alpha\n").exitCode)
        XCTAssertNil(OutputTrailer.parse("").exitCode)

        XCTAssertFalse(OutputTrailer.parse("alpha\n[exited with code 0]\n").truncated)
        XCTAssertTrue(OutputTrailer.parse("[output omitted: it could not be written to disk]\n").truncated)
        XCTAssertNil(OutputTrailer.parse("[output omitted: it could not be written to disk]\n").exitCode)
    }
}
