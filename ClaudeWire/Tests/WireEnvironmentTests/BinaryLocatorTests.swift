import XCTest
import AfleetCore
import WireEnvironment

final class BinaryLocatorTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-bin-\(UUID().uuidString)")
        for d in ["a", "b", "home/.local/bin"] { try FileManager.default.createDirectory(at: tmp.appendingPathComponent(d), withIntermediateDirectories: true) }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }
    private func exe(_ rel: String) throws -> URL {
        let u = tmp.appendingPathComponent(rel); try Data("#!/bin/sh\n".utf8).write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path); return u
    }
    private func env(path: [String]) -> ResolvedEnvironment {
        .init(variables: ["PATH": path.joined(separator: ":"), "HOME": tmp.appendingPathComponent("home").path], shell: "/bin/zsh", capturedAt: .init(), mode: .login)
    }
    func testOverrideWinsThenPathThenLocalBin() throws {
        let inB = try exe("b/claude")
        XCTAssertEqual(BinaryLocator.locate(in: env(path: [tmp.appendingPathComponent("a").path, tmp.appendingPathComponent("b").path]), override: nil), inB)
        let override = try exe("a/claude-override")
        XCTAssertEqual(BinaryLocator.locate(in: env(path: []), override: override), override)
        let local = try exe("home/.local/bin/claude")
        XCTAssertEqual(BinaryLocator.locate(in: env(path: [tmp.appendingPathComponent("a").path]), override: nil), local)
    }
    func testNonExecutableIsSkipped() throws {
        let u = tmp.appendingPathComponent("a/claude"); try Data().write(to: u)   // not executable
        XCTAssertNil(BinaryLocator.locate(in: env(path: [tmp.appendingPathComponent("a").path]), override: nil))
    }
}
