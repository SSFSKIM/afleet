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

    /// Resize is ordered against itself: the size the child reads back is the last grid produced,
    /// never a stale one that overtook it. Ordering against *input* is deliberately not claimed —
    /// grids ride their own lane so a write blocked on a child that is not reading cannot hold
    /// them — so the report request is produced once the grid lane has drained, which is this
    /// producer's own sequencing and not an ordering the layer promises.
    func testSynchronousResizesReachTheChildInTheOrderProduced() async throws {
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
        try await PTYTestChild.waitUntil(seconds: 5) {
            process.ingressDiagnostics.pendingResizeCount == 0
        }
        process.sendInput(Data("report\n".utf8))

        try await PTYTestChild.waitUntil(seconds: 10) {
            recorder.snapshot.range(of: Data("size=".utf8)) != nil
        }
        let reported = Self.reportedSize(in: recorder.snapshot)

        XCTAssertTrue(reported == "48 100", "resize-order=stale-grid-won")
    }

    /// A paste into a child that is not reading fills the pty's input queue and suspends the
    /// write. The grid must still reach the child: a resize is an `ioctl` on the master, and the
    /// only thing standing between it and the kernel used to be that blocked transfer.
    func testResizeReachesANonReadingChildWhileAPasteIsBlocked() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        // Raw mode is load-bearing, and was measured: a canonical-mode tty *discards* input past
        // its own queue rather than holding it, so 4 MiB pasted into a non-reading canonical child
        // is swallowed and no write ever suspends. In raw mode — the mode a full-screen TUI puts
        // its tty in, which is where a paste actually lands — the master write blocks, which is
        // the condition this test needs.
        //
        // The child never reads its input, so the paste below cannot drain. It still writes: the
        // WINCH trap reports the size the kernel gave the slave, which is the child's own reading
        // of the resize rather than the master's echo of what was asked for.
        let script = """
        /bin/stty raw -echo
        trap 'printf "winch=%s;" "$(/bin/stty size)"' WINCH
        printf 'ready;'
        /bin/sleep 30 &
        wait
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

        // Two pastes: the first is taken by the drain and suspends inside the write, the second
        // can only still be queued if that transfer is genuinely blocked. The queued byte count
        // is therefore the proof of the condition this test is about.
        process.sendInput(Self.paste)
        process.sendInput(Self.paste)
        // Exactly one payload left queued means the drain has taken the other and not returned:
        // the transfer is inside the write, suspended on a pty queue the child is not emptying.
        try await PTYTestChild.waitUntil(seconds: 5) {
            process.ingressDiagnostics.queuedInputByteCount == Self.paste.count
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(
            process.ingressDiagnostics.queuedInputByteCount,
            Self.paste.count,
            "paste-transfer=not-blocked"
        )

        let sentAt = ContinuousClock.now
        process.sendResize(
            to: TerminalSize(rows: 40, columns: 100, pixelWidth: 1_000, pixelHeight: 800)
        )
        do {
            try await PTYTestChild.waitUntil(seconds: 3) {
                recorder.snapshot.range(of: Data("winch=40 100;".utf8)) != nil
            }
        } catch {
            XCTFail("resize-behind-blocked-paste=held")
            return
        }
        print("resize-through-blocked-paste applied-in=\(sentAt.duration(to: .now))")
    }

    /// `sendInput` cannot block its caller and has nowhere to return an error, so the bound on a
    /// producer that outruns a child that never reads is a refusal: whole payloads, counted.
    func testInputBacklogIsBoundedAndRefusedPayloadsAreCounted() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let process = try PTYProcess(
            spawning: PTYTestChild.request(
                cwd: directory,
                script: "printf 'ready;'; exec /bin/sleep 30"
            )
        )
        var needsTeardown = true
        defer { if needsTeardown { PTYTestChild.terminateAndReap(process) } }
        let (recorder, reader) = PTYTestChild.record(process.events)
        defer { reader.cancel() }
        try await PTYTestChild.waitUntil(seconds: 5) {
            recorder.snapshot.range(of: Data("ready;".utf8)) != nil
        }

        for _ in 0..<Self.pasteCount {
            process.sendInput(Self.paste)
        }
        let diagnostics = process.ingressDiagnostics

        XCTAssertLessThanOrEqual(
            diagnostics.queuedInputByteCount,
            PTYProcess.ingressInputBacklogByteLimit,
            "input-backlog=unbounded"
        )
        XCTAssertGreaterThan(diagnostics.refusedInputCount, 0, "refused-input-count=0")
        XCTAssertEqual(
            diagnostics.refusedInputByteCount,
            diagnostics.refusedInputCount * Self.paste.count,
            "refused-input-bytes=partial"
        )

        // Termination discards the backlog rather than leaving a drain suspended on a write to a
        // descriptor that is gone.
        await process.teardown()
        needsTeardown = false
        XCTAssertEqual(
            process.ingressDiagnostics.queuedInputByteCount,
            0,
            "input-backlog-after-teardown=retained"
        )
    }

    /// Larger than any pty input queue, and free of newlines so a canonical-mode child cannot
    /// consume a line of it.
    private static let paste = Data(repeating: UInt8(ascii: "A"), count: 256 * 1024)
    private static let pasteCount = 12

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
