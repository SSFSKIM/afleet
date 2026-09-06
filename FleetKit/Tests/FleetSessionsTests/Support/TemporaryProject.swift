import Foundation
import Darwin
import XCTest

/// A project tree the test owns outright, laid out as `<base>/work/proj` so a test can swap the `work` ancestor for
/// a symlink and watch the writer refuse. `.git` is a directory holding a `HEAD` file: §6.12's canonical-root walk
/// asks only whether the entry exists, so no `git` binary is involved.
///
/// Every path here is a `realpath`, because `URL.standardizedFileURL` rewrites `/private/var` back to `/var` and
/// silently undoes symlink resolution; a containment check written against that value compares two different
/// spellings of one directory and passes when it should refuse.
final class TemporaryProject {
    /// The directory the whole fixture lives in: what `remove()` deletes.
    let base: URL
    /// `<base>/work`, the ancestor an ancestor-swap test replaces.
    let work: URL
    /// `<base>/work/proj`, the project root.
    let root: URL

    init(git: Bool = true) throws {
        let container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "afleet-c4-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        base = URL(filePath: TemporaryProject.realpath(container), directoryHint: .isDirectory)
        work = base.appending(path: "work")
        root = work.appending(path: "proj")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if git {
            let dotGit = root.appending(path: ".git")
            try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: dotGit.appending(path: "HEAD"))
        }
    }

    func remove() {
        // The ancestor-swap tests leave a symlink where `work` was; removing the link is enough, and the tree it
        // pointed at belongs to whoever created it.
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Writing the inputs

    func writeMCPJSON(_ servers: [String: Any]) throws {
        try write(["mcpServers": servers], to: root.appending(path: ".mcp.json"))
    }

    func writeProjectSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: root.appending(path: ".claude"), withIntermediateDirectories: true)
        try write(object, to: root.appending(path: ".claude/settings.json"))
    }

    func writeLocalSettings(_ object: [String: Any], mode: Int? = nil) throws {
        try FileManager.default.createDirectory(at: root.appending(path: ".claude"), withIntermediateDirectories: true)
        let file = root.appending(path: ".claude/settings.local.json")
        try write(object, to: file)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
    }

    /// Raw bytes, for the unparseable case and for the byte-identity comparison.
    func writeLocalSettingsRaw(_ text: String, mode: Int? = nil) throws {
        try FileManager.default.createDirectory(at: root.appending(path: ".claude"), withIntermediateDirectories: true)
        let file = root.appending(path: ".claude/settings.local.json")
        try Data(text.utf8).write(to: file)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
    }

    var localSettingsFile: URL { root.appending(path: ".claude/settings.local.json") }
    var stagingDirectory: URL { root.appending(path: ".claude/.cc-writes") }

    func localSettingsRaw() throws -> String {
        String(decoding: try Data(contentsOf: localSettingsFile), as: UTF8.self)
    }

    func localSettingsObject() throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: Data(contentsOf: localSettingsFile)) as? [String: Any]) ?? [:]
    }

    private func write(_ object: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    }

    /// A NUL-terminated C buffer as a Swift string; `String(cString:)` over an array is deprecated.
    static func decode(_ buffer: [CChar]) -> String { decodeCString(buffer) }

    static func realpath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard url.path(percentEncoded: false).withCString({ Darwin.realpath($0, &buffer) }) != nil else {
            return url.path(percentEncoded: false)
        }
        return decode(buffer)
    }
}

/// A structural digest of a directory tree: relative path -> what is there. A symlink digests as its target, a
/// directory as the word `dir`, a file as the SHA-256 of its bytes and its permission bits. Comparing two of these
/// is how a symlink test proves the refusal happened *before* any write rather than merely that the call threw.
enum TreeDigest {
    static func of(_ directory: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = directory.path(percentEncoded: false)
        guard let walker = FileManager.default.enumerator(at: directory,
                                                          includingPropertiesForKeys: nil,
                                                          options: []) else { return out }
        for case let url as URL in walker {
            let path = url.path(percentEncoded: false)
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
            var st = stat()
            guard lstat(path, &st) == 0 else { out[relative] = "gone"; continue }
            let mode = String(format: "%04o", st.st_mode & 0o7777)
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                out[relative] = "dir \(mode)"
            case S_IFLNK:
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                let n = readlink(path, &buffer, buffer.count - 1)
                out[relative] = "link \(n > 0 ? decodeCString(buffer) : "?")"
            default:
                let bytes = (try? Data(contentsOf: URL(filePath: path))) ?? Data()
                out[relative] = "file \(mode) \(bytes.count) \(ContentHashForTests.hex(bytes))"
            }
        }
        return out
    }

    /// The listing of one directory, sorted; `nil` when it is not a readable directory.
    static func listing(of directory: URL) -> [String]? {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?.sorted()
    }
}

/// The tests' own digest, deliberately not `ContentHash`: a test that hashed with the type under test could not tell
/// a broken hash from an unchanged tree.
enum ContentHashForTests {
    static func hex(_ data: Data) -> String {
        // FNV-1a, 64-bit. Structural identity is all a tree comparison needs, and it borrows nothing from the
        // implementation it is checking.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// Watches a directory across a body of work and fails the test when anything under it moved. The whole-package
/// property `testNothingElseInThePackageWritesUnderAProject` is this, called from the rig's teardown as well as
/// around every precondition path that is not the one §6.12 write.
struct TreeWitness {
    let directory: URL
    let before: [String: String]

    init(_ directory: URL) {
        self.directory = directory
        self.before = TreeDigest.of(directory)
    }

    func assertUnchanged(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let after = TreeDigest.of(directory)
        guard after != before else { return }
        let added = after.keys.filter { before[$0] == nil }.sorted()
        let removed = before.keys.filter { after[$0] == nil }.sorted()
        let changed = after.keys.filter { before[$0] != nil && before[$0] != after[$0] }.sorted()
        XCTFail("\(what) changed: added \(added); removed \(removed); changed \(changed)", file: file, line: line)
    }
}

/// Shared by `TemporaryProject.realpath` and `TreeDigest`'s symlink arm.
func decodeCString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
