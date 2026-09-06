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
}
