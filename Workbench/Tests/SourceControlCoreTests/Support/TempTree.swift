import Foundation
import XCTest

/// A scratch directory tree under the process's temporary directory, for tests that need real
/// files on disk.
///
/// X9 and tracker entry 24 (ledger Q15/D15): nothing this child writes may land inside a Claude
/// Code config home. A temporary directory is normally nowhere near one, but `TMPDIR` is
/// settable, so the resolved root is canonicalised and compared against every config home before
/// a single directory is created. When it does resolve inside one the initialiser throws
/// `XCTSkip` rather than writing.
///
/// This is C5's `AppTests/Support/TempTree.swift` re-created rather than imported: a test target
/// cannot import another target's test bundle, and W1 fences each leaf to its own region.
struct TempTree {

    /// The three config homes a scratch tree may never resolve inside, canonicalised.
    static func configHomes(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var homes = [URL(filePath: NSHomeDirectory()).appending(path: ".claude"),
                     URL(filePath: "/tmp/afleet-fixtures/config-home")]
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            homes.append(URL(filePath: configured))
        }
        return homes.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    /// The root of this tree. Created by `init`, and unique to it.
    let root: URL

    init() throws {
        try self.init(temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    /// The injectable form. `temporaryDirectory` is the directory the tree is created under;
    /// `configHomes` is the forbidden set. Both default to the real ones.
    ///
    /// Both sides are canonicalised here, not just the temporary directory. Comparing a resolved
    /// path against an unresolved one is a guard that fails open: the two spell one directory two
    /// ways, no prefix matches, and the tree is created inside the config home it was meant to
    /// refuse.
    init(temporaryDirectory: URL, configHomes: [URL] = TempTree.configHomes()) throws {
        let base = temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let components = base.pathComponents
        let forbidden = configHomes.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        for home in forbidden where components.starts(with: home.pathComponents) {
            throw XCTSkip("temporary directory resolves inside a config home")
        }
        root = base.appending(path: "afleet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Writes `contents` at `relativePath`, creating every intermediate directory.
    @discardableResult
    func file(_ relativePath: String, _ contents: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates `relativePath` as a directory, with every intermediate directory.
    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes the whole tree. Called from a test's teardown; a failure to remove is not a test
    /// failure, because the tree is unique per initialiser and the system reclaims it.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
