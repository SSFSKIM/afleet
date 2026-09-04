import XCTest
import WireTestSupport

final class ConsumerSmokeTests: XCTestCase {
    /// Builds and runs the external package; proves the public surface is constructible from outside the module.
    func testConsumerPackageBuildsAndRuns() throws {
        let pkg = TestPaths.support.deletingLastPathComponent().appendingPathComponent("ConsumerSmoke")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["swift", "run", "--package-path", pkg.path, "ConsumerSmoke"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, text.suffix(2000).description)
        XCTAssertTrue(text.contains("ConsumerSmoke: constructed every X2 and X3 value"), text.suffix(500).description)
    }
}
