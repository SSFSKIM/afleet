import Foundation
@testable import TerminalCore
import XCTest

final class PTYSizeTests: XCTestCase {
    func testChildSeesExactInitialAndResizedDimensionsAndSIGWINCH() async throws {
        let directory = try PTYTestChild.temporaryDirectory()
        defer { PTYTestChild.remove(directory) }
        let script = """
        trap 'printf "winch=received\\n"' WINCH
        printf 'initial=%s\\n' "$(/bin/stty size)"
        printf 'resize-ready\\n'
        IFS= read -r resizeProbe || :
        printf 'resized=%s\\n' "$(/bin/stty size)"
        printf 'resize-reported\\n'
        while :; do IFS= read -r hold || :; done
        """
        let process = try PTYProcess(
            spawning: PTYTestChild.request(cwd: directory, script: script)
        )
        defer { PTYTestChild.terminateAndReap(process) }
        let (recorder, reader) = PTYTestChild.record(process.events)
        defer { reader.cancel() }

        try await PTYTestChild.waitUntil(seconds: 3) {
            recorder.snapshot.range(of: Data("resize-ready".utf8)) != nil
        }
        let initialOutput = decoded(recorder.snapshot)
        let initialLine = initialOutput
            .split(separator: "\n")
            .map(String.init)
            .first { $0.hasPrefix("initial=") }
        XCTAssertEqual(
            initialLine,
            "initial=24 80",
            "the pty did not preserve the exact requested initial size 24x80"
        )

        try await process.resize(
            to: TerminalSize(rows: 40, columns: 100, pixelWidth: 1_000, pixelHeight: 800)
        )
        try await process.write(Data("report-size\n".utf8))
        try await PTYTestChild.waitUntil(seconds: 3) {
            recorder.snapshot.range(of: Data("resize-reported".utf8)) != nil
        }
        let resizedOutput = decoded(recorder.snapshot)
        let resizedLine = resizedOutput
            .split(separator: "\n")
            .map(String.init)
            .first { $0.hasPrefix("resized=") }
        XCTAssertEqual(
            resizedLine,
            "resized=40 100",
            "the child did not read the exact resized dimensions 40x100"
        )
        XCTAssertTrue(
            resizedOutput.split(separator: "\n").contains("winch=received"),
            "the child did not trap SIGWINCH after resize"
        )
    }

    private func decoded(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
    }
}
