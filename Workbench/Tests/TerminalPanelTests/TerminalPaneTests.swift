import AppKit
import Darwin
import FleetKit
import Foundation
import TerminalCore
@testable import TerminalPanel
import XCTest

/// A real child, through a real pane, into a real grid. The mappings are asserted on their own in
/// `PaneSpawnTests`; what these cases add is that a pane wires them to a pty and a renderer the
/// way the S1 harness measured, and that what the child said comes back rendered.
@MainActor
final class TerminalPaneTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func attachedPane() async throws -> TerminalPane {
        let pane = TerminalPane()
        window = PaneTestChild.window(around: pane.surface.view)
        try await PaneTestChild.awaitAttachment(of: pane.surface)
        return pane
    }

    private func request(
        executable: URL,
        arguments: [String],
        cwd: URL,
        environment: [String: String],
        purpose: PanePurpose = .command
    ) -> PaneRequest {
        PaneRequest(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            environment: environment,
            purpose: purpose
        )
    }

    // MARK: G1 — the child's cwd, its environment and its PATH come back rendered

    func testChildRunsInTheRequestedDirectoryWithTheRequestedEnvironment() async throws {
        let directory = try PaneTestChild.temporaryDirectory()
        defer { PaneTestChild.remove(directory) }
        let pane = try await attachedPane()
        let request = request(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "pwd; echo $FOO; echo $PATH"],
            cwd: directory,
            environment: ["FOO": "afleet-pane-jade", "PATH": "/usr/bin:/bin"]
        )

        pane.start(request)

        guard case .running = pane.state else {
            XCTFail("state=\(pane.state) expected=running")
            return
        }
        try await PaneTestChild.waitUntil(seconds: 15, "pwd-line") {
            pane.surface.renderedViewportText()?.contains(directory.path) == true
        }
        try await PaneTestChild.waitUntil(seconds: 15, "FOO-line") {
            pane.surface.renderedViewportText()?.contains("afleet-pane-jade") == true
        }
        try await PaneTestChild.waitUntil(seconds: 15, "PATH-line") {
            pane.surface.renderedViewportText()?.contains("/usr/bin:/bin") == true
        }
        try await PaneTestChild.waitUntil(seconds: 15, "exit") {
            pane.state == .exited(.exited(code: 0))
        }
        await pane.close()
    }

    /// X11 and §6.3: the child's environment is compared **by name**, as sets. Nothing here reads
    /// or prints a value, and the failure message carries names only.
    func testChildEnvironmentIsTheRequestsNamesPlusTheTerminalOverlay() async throws {
        let directory = try PaneTestChild.temporaryDirectory()
        defer { PaneTestChild.remove(directory) }
        let pane = try await attachedPane()
        let requested = [
            "AFLEET_PANE_JADE": "carried",
            "AFLEET_PANE_COPPER": "carried",
            "PATH": "/usr/bin:/bin",
            "HOME": directory.path,
        ]
        // `/usr/bin/env` is the child itself, not a script run through a shell: a shell exports
        // names of its own (`PWD`, `SHLVL`) and the question here is what the pane handed over.
        let request = request(
            executable: URL(filePath: "/usr/bin/env"),
            arguments: [],
            cwd: directory,
            environment: requested
        )

        var expected = Set(requested.keys).union(["TERM"])
        if pane.surface.terminalDescription.terminfoDirectory != nil {
            expected.insert("TERMINFO_DIRS")
        }

        pane.start(request)
        try await PaneTestChild.waitUntil(seconds: 15, "environment-exit") {
            pane.state == .exited(.exited(code: 0))
        }
        // The wait is for every expected name to have been rendered, not for a fixed moment: the
        // child's last row reaches the grid some time after its status does, and sampling once
        // reads whatever had been parsed by then. A name that never arrives fails here, named.
        try await PaneTestChild.waitUntil(seconds: 15, "environment-names") {
            expected.isSubset(of: Self.reportedNames(in: pane.surface.renderedViewportText()))
        }

        let reported = Self.reportedNames(in: pane.surface.renderedViewportText())
        XCTAssertEqual(
            reported,
            expected,
            "unexpected=\(reported.subtracting(expected).sorted().joined(separator: ","))"
                + " missing=\(expected.subtracting(reported).sorted().joined(separator: ","))"
        )
        let hostOnly = Set(ProcessInfo.processInfo.environment.keys).subtracting(expected)
        XCTAssertTrue(
            reported.isDisjoint(with: hostOnly),
            "inherited=\(reported.intersection(hostOnly).sorted().joined(separator: ","))"
        )
        await pane.close()
    }

    /// Names only, never values: a rendered row is `NAME=VALUE`, and everything after the first
    /// `=` is discarded before anything is compared or printed.
    private static func reportedNames(in grid: String?) -> Set<String> {
        guard let grid else { return [] }
        var names: Set<String> = []
        for line in grid.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex ..< separator])
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  !name.first!.isNumber else { continue }
            names.insert(name)
        }
        return names
    }

    // MARK: §10 — a spawn that cannot execute is a pane state, never the caller's error

    func testUnexecutableRequestLeavesThePaneFailedAndThrowsNothing() async throws {
        let directory = try PaneTestChild.temporaryDirectory()
        defer { PaneTestChild.remove(directory) }
        let pane = try await attachedPane()
        let request = request(
            executable: directory.appending(path: "afleet-pane-absent"),
            arguments: [],
            cwd: directory,
            environment: [:]
        )

        pane.start(request)

        XCTAssertEqual(
            pane.state,
            .failed(.pty(.executableUnavailable)),
            "state=\(pane.state) expected=failed"
        )
        await pane.close()
    }

    // MARK: Design §2 — a suspended `.report` pane, and Continue

    func testStoppedPaneIsObservedAndContinueResumesTheChild() async throws {
        let directory = try PaneTestChild.temporaryDirectory()
        defer { PaneTestChild.remove(directory) }
        let pane = try await attachedPane()
        // The child stops *itself*: nothing outside the pane signals a process, and the pane's
        // own `continueStopped()` is the only signal this case sends (§7.8, X9).
        let script = PaneTestChild.selfTerminating(after: 30, """
        printf 'afleet-before-stop\\n'
        kill -STOP $$
        printf 'afleet-after-continue\\n'
        IFS= read -r hold
        """)
        let request = request(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            cwd: directory,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        pane.start(request)
        try await PaneTestChild.waitUntil(seconds: 15, "before-stop") {
            pane.surface.renderedViewportText()?.contains("afleet-before-stop") == true
        }
        try await PaneTestChild.waitUntil(seconds: 15, "stopped") {
            pane.state == .stopped(signal: SIGSTOP)
        }

        await pane.continueStopped()

        try await PaneTestChild.waitUntil(seconds: 15, "after-continue") {
            pane.surface.renderedViewportText()?.contains("afleet-after-continue") == true
        }
        await pane.close()
    }
}
