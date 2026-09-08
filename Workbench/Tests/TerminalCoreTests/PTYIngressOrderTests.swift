import Foundation
@testable import TerminalCore
import XCTest

/// The surface-to-pty seam. A renderer hands over keystrokes and grid changes through synchronous
/// callbacks that cannot await, so the layer owes them an ordered handoff; these tests pin that
/// the child receives what the producer produced, in the order it produced it.
final class PTYIngressOrderTests: XCTestCase {
    private static let tokenCount = 200

    /// The token stream is produced from one synchronous context with no suspension point between
    /// tokens, which is exactly the shape of a renderer callback loop. Under one unstructured
    /// `Task` per token the tokens reach the actor in whatever order the pool schedules them.
    func testSynchronousSendsReachTheChildInTheOrderProduced() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: "/bin/stty raw -echo; printf 'ready;'; exec /bin/cat"
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }
        let (recorder, reader) = PTYTestChild.record(process.events)
        defer { reader.cancel() }
        try await PTYTestChild.waitUntil(seconds: 5) {
            recorder.snapshot.range(of: Data("ready;".utf8)) != nil
        }

        Self.produceTokens(count: Self.tokenCount, into: process)

        try await PTYTestChild.waitUntil(seconds: 10) {
            Self.tokens(in: recorder.snapshot).count >= Self.tokenCount + 1
        }
        let echoed = Array(Self.tokens(in: recorder.snapshot).dropFirst())

        XCTAssertTrue(
            echoed == Self.expectedTokens(count: Self.tokenCount),
            "ingress-order=shuffled"
        )
    }

    /// Resize is ordered against itself and against input: the report request is produced last, so
    /// the size the child reads back is the last grid produced, never a stale one that overtook it.
    func testSynchronousResizesReachTheChildInTheOrderProducedAndOrderedAgainstInput() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let script = """
        printf 'ready;'
        IFS= read -r reportProbe || :
        printf 'size=%s;' "$(/bin/stty size)"
        exec /bin/sleep 30
        """
        let process = try PTYProcess(
            spawning: PTYTestChild.request(cwd: directory, script: script)
        )
        defer { PTYTestChild.terminateAndReap(process) }
        let (recorder, reader) = PTYTestChild.record(process.events)
        defer { reader.cancel() }
        try await PTYTestChild.waitUntil(seconds: 5) {
            recorder.snapshot.range(of: Data("ready;".utf8)) != nil
        }

        Self.produceGrids(rowSteps: 30...48, into: process)

        try await PTYTestChild.waitUntil(seconds: 10) {
            recorder.snapshot.range(of: Data("size=".utf8)) != nil
        }
        let reported = Self.reportedSize(in: recorder.snapshot)

        XCTAssertTrue(reported == "48 100", "resize-order=stale-grid-won")
    }

    /// Synchronous by construction: no `await` appears between the sends, so any reordering the
    /// child sees was introduced by the layer and not by this producer.
    private static func produceTokens(count: Int, into process: PTYProcess) {
        for index in 0..<count {
            process.sendInput(Data(token(index).utf8))
        }
    }

    private static func produceGrids(rowSteps: ClosedRange<Int>, into process: PTYProcess) {
        for rows in rowSteps {
            process.sendResize(
                to: TerminalSize(rows: rows, columns: 100, pixelWidth: 1_000, pixelHeight: 800)
            )
        }
        process.sendInput(Data("report\n".utf8))
    }

    private static func token(_ index: Int) -> String {
        "t\(String(format: "%04d", index));"
    }

    private static func expectedTokens(count: Int) -> [String] {
        (0..<count).map { String(token($0).dropLast()) }
    }

    /// The child's own echo of the report request shares the stream with the report, so the size
    /// is read out of the stream by its markers rather than by position.
    private static func reportedSize(in output: Data) -> String? {
        let text = String(decoding: output, as: UTF8.self)
        guard let start = text.range(of: "size=") else { return nil }
        guard let end = text.range(of: ";", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// The child echoes a byte stream, so tokens are recovered by their separator rather than by
    /// delivery boundaries, which the pty is free to choose.
    private static func tokens(in output: Data) -> [String] {
        String(decoding: output, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .split(separator: ";", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }
}
