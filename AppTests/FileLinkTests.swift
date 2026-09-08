import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// C6.1 Task 4, gate G3: a path in a tool row is a link, and canonicalising it opens no descriptor.
@MainActor
final class FileLinkTests: XCTestCase {

    /// G3. A `Read` row emits exactly one `WorkspaceLink.file`, whose line is `ReadInput.offset`
    /// where the call carried one and **nil** where it did not — a fabricated line 1 would scroll a
    /// reader away from the top of a file they asked to see whole.
    ///
    /// **The trace assertion, stated as such.** "No descriptor was opened" cannot be asserted from
    /// the link that came out, so it is measured by the one behaviour that separates the two
    /// implementations: the path canonicalised is a **FIFO**, which `open(2)` blocks on until a
    /// writer appears and `realpath(3)`/`stat` resolve immediately. A canonicaliser that opened a
    /// descriptor would hang here rather than fail, so the call is made off the main thread with a
    /// bounded wait and the timeout is the failure.
    func testAReadRowEmitsAFileLinkWithItsLine() async throws {
        let temp = try TempTree()
        let fifo = temp.root.appending(path: "an-invented-fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0, "the trace assertion's FIFO could not be made")

        let resolved = try await Self.offMain { FileLink.canonical(fifo.path) }
        XCTAssertNotNil(resolved, "canonicalising a FIFO produced no URL")
        XCTAssertTrue(resolved?.lastPathComponent == "an-invented-fifo",
                      "the canonical URL names a different last component")

        let router = RecordingLinkRouter()
        let context = InventedItems.context(links: router)
        let withOffset = InventedItems.toolCall("Read",
                                                input: .object(["file_path": .string(fifo.path),
                                                                "offset": .integer(42)]))
        let paths = FileLink.paths(in: withOffset)
        XCTAssertEqual(paths.count, 1, "a Read row named \(paths.count) path(s)")
        XCTAssertEqual(paths.first?.line, 42, "the link's line reads \(paths.first?.line ?? -1)")

        FileLink.open(paths[0].path, line: paths[0].line, in: context)
        try await Self.settle(router, until: 1)
        var opened = await router.opened
        XCTAssertEqual(opened.count, 1, "the router received \(opened.count) link(s)")
        XCTAssertEqual(Self.line(of: opened.first), 42,
                       "the router was given line \(Self.line(of: opened.first).map(String.init) ?? "none")")

        // The other arm: no offset, no line.
        let withoutOffset = InventedItems.toolCall("Read", input: .object(["file_path": .string(fifo.path)]))
        let plain = FileLink.paths(in: withoutOffset)
        XCTAssertNil(plain.first?.line, "a Read with no offset was given a line anyway")
        FileLink.open(plain[0].path, line: plain[0].line, in: context)
        try await Self.settle(router, until: 2)
        opened = await router.opened
        XCTAssertEqual(opened.count, 2, "the router received \(opened.count) link(s) after the second open")
        XCTAssertNil(Self.line(of: opened.last), "the second link carried a line the call never named")

        // The floor: both links are file links, so a router that received two of something else
        // would not pass the two assertions above by accident.
        XCTAssertEqual(opened.filter { if case .file = $0 { return true } else { return false } }.count, 2,
                       "\(opened.count) link(s) reached the router and not all were file links")
    }

    // MARK: - Helpers

    private static func line(of link: WorkspaceLink?) -> Int? {
        guard case .file(_, let line) = link else { return nil }
        return line
    }

    /// Runs a synchronous call off the main thread with a bounded wait, so a call that blocks fails
    /// the test instead of hanging the suite.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { work() }
        let deadline = Date().addingTimeInterval(2)
        while !task.isCancelled {
            if Date() > deadline {
                task.cancel()
                throw Blocked()
            }
            if case .some(let value) = await withTaskGroup(of: T?.self, returning: T?.self, body: { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(50)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }) {
                return value
            }
        }
        throw Blocked()
    }

    /// Waits for the router to have received a given number of links, and asserts it did.
    private static func settle(_ router: RecordingLinkRouter, until count: Int) async throws {
        for _ in 0..<100 {
            if await router.opened.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the router received \(await router.opened.count) link(s), waiting for \(count)")
    }

    private struct Blocked: Error, CustomStringConvertible {
        var description: String { "canonicalising a FIFO did not return within 2 seconds" }
    }
}
