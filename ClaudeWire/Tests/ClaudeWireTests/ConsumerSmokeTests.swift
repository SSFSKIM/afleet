import XCTest
import WireTestSupport

final class ConsumerSmokeTests: XCTestCase {
    /// Builds and runs the external package; proves the public surface is constructible from outside the module.
    ///
    /// The build gets a fresh scratch path per run. Sharing one would let an incremental build decide the
    /// consumer needs no recompile after a change confined to the umbrella's `@_exported` list — which it does
    /// decide, observably — so a warm tree could pass while the current sources would not compile. It also
    /// keeps an untracked build tree from accumulating inside the repository.
    func testConsumerPackageBuildsAndRuns() throws {
        let pkg = TestPaths.support.deletingLastPathComponent().appendingPathComponent("ConsumerSmoke")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("afleet-consumer-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", "run", "--package-path", pkg.path, "--scratch-path", scratch.path, "ConsumerSmoke"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run()
        // Drained before waiting: a cold build easily exceeds the pipe buffer, and the other order deadlocks.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, text.suffix(2000).description)
        XCTAssertTrue(text.contains("ConsumerSmoke: constructed every X2 and X3 value"), text.suffix(500).description)
    }
}
