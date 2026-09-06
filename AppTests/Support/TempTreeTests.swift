import Foundation
import XCTest

/// Tracker entry 24's closer: a scratch tree refuses to exist inside a config home.
final class TempTreeTests: XCTestCase {

    func testTempTreeSkipsWhenTemporaryDirectoryIsInsideAConfigHome() throws {
        // An invented config home, itself under the temporary directory, so that a future
        // demonstration of this test failing cannot write into a real config home.
        let fakeConfigHome = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appending(path: "afleet-fake-config-home-\(UUID().uuidString)")
        let inside = fakeConfigHome.appending(path: "tmp")

        // The forbidden branch: a temporary directory under a config home is a skip, not a write.
        XCTAssertThrowsError(try TempTree(temporaryDirectory: inside, configHomes: [fakeConfigHome])) { error in
            XCTAssertTrue(error is XCTSkip, "expected XCTSkip, got \(type(of: error))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeConfigHome.path(percentEncoded: false)),
                       "the refused tree wrote a directory inside a config home")

        // The ordinary branch: an unrelated temporary directory produces a usable tree.
        let tree = try TempTree(temporaryDirectory: FileManager.default.temporaryDirectory,
                                configHomes: [fakeConfigHome])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.root.path(percentEncoded: false)),
                      "the accepted tree did not create its root")
        try tree.file("a/b.txt", "1")
        try tree.directory("c")
        let entries = try FileManager.default.contentsOfDirectory(atPath: tree.root.path(percentEncoded: false))
        XCTAssertEqual(entries.count, 2, "expected 2 entries directly under the root")
        try FileManager.default.removeItem(at: tree.root)
    }

    /// I1's closer, and the discriminating case for it. `TempTree.init` canonicalises the
    /// temporary directory it is handed but compared the injected config homes exactly as passed,
    /// so the two sides could name one directory under two spellings, the prefix comparison would
    /// not match, and the guard would fail open — silently, writing the thing X9 forbids.
    ///
    /// The shape used here is a config home reached through a symlink, which is the general case
    /// and the one `CLAUDE_CONFIG_DIR` can take. It is not the `/var` versus `/private/var` shape
    /// one might expect: Foundation's `resolvingSymlinksInPath` normalises `/private/var` *to*
    /// `/var` and `/private/tmp` to `/tmp`, so those two spellings converge on their own and the
    /// asymmetry never shows. What does not converge is any other symlink in the path.
    ///
    /// Everything here lives under the temporary directory and nothing names a real config home,
    /// so removing the guard to watch this fail writes somewhere harmless (tracker entry 52).
    func testAConfigHomeReachedThroughASymlinkStillCatchesTheTree() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: "afleet-temptree-\(UUID().uuidString)")
        let realHome = sandbox.appending(path: "config-home")
        let scratch = realHome.appending(path: "scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // The same config home, named through a symlink beside it.
        let linkedHome = sandbox.appending(path: "config-home-link")
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)

        // The floor: if the two spellings already coincided this case would prove nothing.
        XCTAssertNotEqual(linkedHome.standardizedFileURL.path(percentEncoded: false),
                          linkedHome.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false),
                          "the symlink did not survive, so this case is not discriminating")

        // The tree is asked for a directory inside the linked home, and the home is injected in
        // its unresolved spelling. Only canonicalising both sides catches it.
        XCTAssertThrowsError(try TempTree(temporaryDirectory: linkedHome.appending(path: "scratch"),
                                          configHomes: [linkedHome])) { error in
            XCTAssertTrue(error is XCTSkip, "expected XCTSkip, got \(type(of: error))")
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path(percentEncoded: false))
        XCTAssertEqual(entries.count, 0, "the refused tree wrote inside a config home")
    }
}
