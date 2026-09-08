import Foundation
import GhosttyTerminal
@testable import TerminalCore
import XCTest

final class EnvironmentOverlayTests: XCTestCase {
    func testOverlayChangesExactlyDeclaredNamesAndPreservesEveryOtherRequestVariable() {
        let carriedName = "AFLEET_REQUESTED_JADE"
        let requestEnvironment = [
            "TERM": "request-terminal",
            "TERMINFO_DIRS": "request-database",
            carriedName: "carried-value",
        ]
        let terminal = TerminalDescription(
            term: "renderer-terminal",
            terminfoDirectory: URL(filePath: "/invented/renderer-database")
        )

        let overlaid = terminalEnvironment(overlaying: requestEnvironment, for: terminal)
        let allNames = Set(requestEnvironment.keys).union(overlaid.keys)
        let changedNames = Set(allNames.filter { requestEnvironment[$0] != overlaid[$0] })
        let expectedNames: Set<String> = ["TERM", "TERMINFO_DIRS"]

        XCTAssertTrue(
            changedNames == expectedNames,
            "changed-name-set=\(changedNames.sorted().joined(separator: ","))"
        )
        XCTAssertTrue(overlaid["TERM"] == terminal.term, "TERM=absent")
        XCTAssertTrue(
            overlaid["TERMINFO_DIRS"] == "/invented/renderer-database:request-database",
            "TERMINFO_DIRS=absent"
        )
        XCTAssertTrue(
            overlaid[carriedName] == requestEnvironment[carriedName],
            "\(carriedName)=absent"
        )
    }

    func testOverlayWithoutTerminfoDirectoryLeavesRequestedSearchPathUntouched() {
        let requestEnvironment = [
            "TERM": "request-terminal",
            "TERMINFO_DIRS": "request-database",
        ]
        let terminal = TerminalDescription(term: "renderer-terminal", terminfoDirectory: nil)

        let overlaid = terminalEnvironment(overlaying: requestEnvironment, for: terminal)
        let allNames = Set(requestEnvironment.keys).union(overlaid.keys)
        let changedNames = Set(allNames.filter { requestEnvironment[$0] != overlaid[$0] })

        XCTAssertTrue(changedNames == ["TERM"], "changed-name-set=\(changedNames.sorted().joined(separator: ","))")
        XCTAssertTrue(overlaid["TERM"] == terminal.term, "TERM=absent")
        XCTAssertTrue(
            overlaid["TERMINFO_DIRS"] == requestEnvironment["TERMINFO_DIRS"],
            "TERMINFO_DIRS=request-value-absent"
        )
    }

    func testSpawnOverlaysTerminalDescriptionByName() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        guard let terminfoDirectory = GhosttyRuntimeResources.terminfoDirectoryURL else {
            XCTFail("TERMINFO_DIRS=absent")
            return
        }
        let terminal = TerminalDescription(
            term: "xterm-ghostty",
            terminfoDirectory: terminfoDirectory
        )
        let script = """
        printf 'TERM=%s\\n' "$TERM"
        if [ "${TERMINFO_DIRS+x}" = x ]; then
          printf 'TERMINFO_DIRS=present\\n'
        else
          printf 'TERMINFO_DIRS=absent\\n'
        fi
        printf 'overlay-ready\\n'
        IFS= read -r hold
        """
        let process = try PTYProcess(
            spawning: PTYSpawnRequest(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", script],
                cwd: directory,
                environment: [:],
                size: TerminalSize(rows: 24, columns: 80, pixelWidth: 640, pixelHeight: 480),
                terminal: terminal
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }

        let output = try await PTYTestChild.output(from: process.events, until: "overlay-ready")
        let tokens = Set(output.split(separator: "\n").map(String.init))
        XCTAssertTrue(tokens.contains("TERM=\(terminal.term)"), "TERM=absent")
        XCTAssertTrue(tokens.contains("TERMINFO_DIRS=present"), "TERMINFO_DIRS=absent")
    }

    func testSpawnedChildResolvesOverlaidTerminalDescription() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        guard let terminfoDirectory = GhosttyRuntimeResources.terminfoDirectoryURL else {
            XCTFail("TERMINFO_DIRS=absent")
            return
        }
        let terminal = TerminalDescription(
            term: "xterm-ghostty",
            terminfoDirectory: terminfoDirectory
        )
        let script = """
        if /usr/bin/infocmp -1 "$TERM" >/dev/null 2>&1; then
          printf 'TERM=resolved\\n'
        else
          printf 'TERM=unresolved\\n'
        fi
        printf 'infocmp-ready\\n'
        IFS= read -r hold
        """
        let process = try PTYProcess(
            spawning: PTYSpawnRequest(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", script],
                cwd: directory,
                environment: [:],
                size: TerminalSize(rows: 24, columns: 80, pixelWidth: 640, pixelHeight: 480),
                terminal: terminal
            )
        )
        defer { PTYTestChild.terminateAndReap(process) }

        let output = try await PTYTestChild.output(from: process.events, until: "infocmp-ready")
        let tokens = Set(output.split(separator: "\n").map(String.init))
        XCTAssertTrue(tokens.contains("TERM=resolved"), "TERM=unresolved")
    }
}
