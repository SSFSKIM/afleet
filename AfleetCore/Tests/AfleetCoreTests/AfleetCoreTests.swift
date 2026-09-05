import XCTest
import AfleetCore

final class AfleetCoreTests: XCTestCase {
    func testSessionIDParsesAnyCaseAndPrintsLowercase() {
        let id = SessionID("0F3A6E2C-9B1D-4E5F-8A7B-1C2D3E4F5A6B")
        XCTAssertNotNil(id)
        XCTAssertEqual(id?.description, "0f3a6e2c-9b1d-4e5f-8a7b-1c2d3e4f5a6b")
        XCTAssertNil(SessionID("not-a-uuid"))
        XCTAssertNotEqual(SessionID(), SessionID())
    }

    func testSessionIDCodableRoundTrip() throws {
        let id = SessionID()
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(id.description)\"")
        XCTAssertEqual(try JSONDecoder().decode(SessionID.self, from: data), id)
    }

    func testDiffRefAndWorkspaceLinkAreHashable() {
        let repo = URL(fileURLWithPath: "/tmp/repo")
        let a = WorkspaceLink.diff(DiffRef(repository: repo, path: "a.swift", base: .workingTreeAgainstHEAD))
        let b = WorkspaceLink.diff(DiffRef(repository: repo, path: "a.swift", base: .commitAgainstParent("abc123")))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Set([a, a, b]).count, 2)
        XCTAssertEqual(WorkspaceLink.file(URL(fileURLWithPath: "/tmp/x"), line: 12),
                       WorkspaceLink.file(URL(fileURLWithPath: "/tmp/x"), line: 12))
    }

    func testResolvedEnvironmentDerivesPath() {
        let env = ResolvedEnvironment(variables: ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/x"],
                                      shell: "/bin/zsh", capturedAt: Date(timeIntervalSince1970: 0),
                                      mode: .interactiveLogin)
        XCTAssertEqual(env.path, ["/opt/homebrew/bin", "/usr/bin"])
        XCTAssertEqual(ResolvedEnvironment(variables: [:], shell: "/bin/sh", capturedAt: .init(), mode: .processFallback).path, [])
    }

    func testConfigHomeCodable() throws {
        let home = ConfigHome(root: URL(fileURLWithPath: "/tmp/cfg"), source: .environment, projectDirName: "p")
        let data = try JSONEncoder().encode(home)
        XCTAssertEqual(try JSONDecoder().decode(ConfigHome.self, from: data), home)
        XCTAssertEqual(ConfigHome.Source.default.rawValue, "default")
    }

    func testChannelOriginCases() {
        let origins: [ChannelOrigin] = [.owned(.connecting), .owned(.ready), .owned(.dormant), .owned(.contended),
                                        .foreignLive(.usersTerminal), .foreignLive(.ownTerminalTab), .backgroundJob, .archived]
        XCTAssertEqual(Set(origins).count, 8)
    }
}
