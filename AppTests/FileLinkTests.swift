import Foundation
import SwiftUI
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

    // MARK: - The channel's directory (round 1, scalpel-3 #5)

    /// **A relative path opens under the channel's own working directory**, never under whatever
    /// directory the app process happens to be running in.
    ///
    /// The engine writes relative paths into tool inputs — `Edit` and `Read` carry whatever the
    /// model typed — and `TimelineRenderContext.cwd` is the channel's own directory precisely so
    /// that they can be resolved. `open` ignored it, so `realpath`/`URL(filePath:)` resolved against
    /// the test runner's directory and the link named a file in a different project, or none.
    ///
    /// Both arms, because either alone proves nothing: a relative path lands under the channel's
    /// directory, and an absolute one is untouched by it. The third arm is the rule the context's
    /// own documentation states: with no directory to resolve against, a relative path is not
    /// resolved at all rather than resolved somewhere else. Every path here is invented and under
    /// the process's temporary tree (X9), and no assertion prints one (§11).
    func testARelativePathResolvesAgainstTheChannelsDirectory() async throws {
        let temp = try TempTree()
        let project = try temp.directory("an-invented-project")
        let router = RecordingLinkRouter()
        let context = InventedItems.context(links: router, cwd: project)

        FileLink.open("notes/an-invented-file.txt", line: 7, in: context)
        try await Self.settle(router, until: 1)
        var opened = await router.opened
        guard case .file(let relative, let line)? = opened.first else {
            return XCTFail("the relative path produced \(opened.count) link(s) and none of them a file link")
        }
        XCTAssertEqual(line, 7, "the link's line reads \(line.map(String.init) ?? "none")")
        XCTAssertTrue(relative.path.hasPrefix(project.path + "/"),
                      "the relative link resolved outside the channel's own directory")
        XCTAssertEqual(relative.lastPathComponent, "an-invented-file.txt",
                       "the resolved link names a different file")

        // The floor: an absolute path is not re-rooted under the channel's directory.
        let absolute = temp.root.appending(path: "elsewhere/an-invented-file.txt")
        FileLink.open(absolute.path, line: nil, in: context)
        try await Self.settle(router, until: 2)
        opened = await router.opened
        guard case .file(let unchanged, _)? = opened.last else {
            return XCTFail("the absolute path produced \(opened.count) link(s) and the last is not a file link")
        }
        XCTAssertFalse(unchanged.path.hasPrefix(project.path + "/"),
                       "an absolute path was re-rooted under the channel's directory")

        // A channel the index has no directory for: nothing is opened, rather than something else.
        let homeless = InventedItems.context(links: router)
        FileLink.open("notes/an-invented-file.txt", line: nil, in: homeless)
        for _ in 0..<20 { await Task.yield() }
        let count = await router.opened.count
        XCTAssertEqual(count, 2,
                       "\(count) link(s) reached the router, so a relative path with no directory opened something")
    }

    // MARK: - What the label draws (round 2, sweep#2)

    /// **The name a link draws is sanitised; the path it opens is not** (spec §12).
    ///
    /// `display` is engine-supplied text — a tool input's `file_path` — and it reached `Text`
    /// through nothing but a split and a join. A bidi override in a filename reverses what follows
    /// it, so a name ending `\u{202E}txt.exe` draws as though it ended `exe.txt`, and a zero-width
    /// mark splits a name that reads as one. The destination is the other half of the rule: the
    /// link must still open the file the call actually named, so sanitising is on what is drawn
    /// and on nothing else. Every scalar here is invented text (§11).
    func testTheDrawnNameIsSanitisedAndTheLinkStillOpensTheRealPath() async throws {
        let name = "an-invented-file\u{202E}txt\u{200B}.exe"
        let path = "/an-invented-project/" + name
        let router = RecordingLinkRouter()
        let context = InventedItems.context(links: router)

        let body = FileLinkLabel(path: path, context: context).body
        let drawn = ViewTree.values(of: String.self, in: body).filter { $0.contains("an-invented-file") }
        XCTAssertEqual(drawn.count, 1, "the label drew \(drawn.count) name(s)")
        let stripped = drawn.filter { $0.unicodeScalars.contains(where: TextSanitiser.isStripped) }
        XCTAssertEqual(stripped.count, 0,
                       "\(stripped.count) of the label's drawn string(s) still carry a stripped scalar")
        XCTAssertEqual(drawn.first, "an-invented-project/an-invented-filetxt.exe",
                       "the label drew a name of \(drawn.first?.unicodeScalars.count ?? 0) scalar(s)")

        // The destination is the real path, sanitised of nothing: pressing the link opens the file
        // the call named, not a different one.
        let button = try XCTUnwrap(ViewTree.values(of: Button<Text>.self, in: body).first,
                                   "the label drew no link to press")
        XCTAssertTrue(ViewTree.press(button), "the link's action could not be invoked")
        try await Self.settle(router, until: 1)
        let opened = await router.opened
        guard case .file(let url, _)? = opened.first else {
            return XCTFail("the link produced \(opened.count) link(s) and none of them a file link")
        }
        XCTAssertEqual(url.lastPathComponent, name,
                       "the link opened a name of \(url.lastPathComponent.unicodeScalars.count) scalar(s)")
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
