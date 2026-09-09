import Foundation
import XCTest
@testable import FilesPanel
import SourceControlCore

/// A scratch directory tree under the process's temporary directory, for tests that need real
/// files on disk.
///
/// X9: nothing this child writes may land inside a Claude Code config home. A temporary directory
/// is normally nowhere near one, but `TMPDIR` is settable, so the resolved root is canonicalised
/// and compared against every config home before a single directory is created; when it does
/// resolve inside one the initialiser throws `XCTSkip` rather than writing.
///
/// This is `SourceControlCoreTests/Support/TempTree.swift` re-created rather than imported: a test
/// target cannot import another target's test bundle, and W1 fences each leaf to its own region.
/// Both comparisons below are carried whole because each was measured — a path that does not exist
/// yet resolves to nothing, and a macOS volume does not distinguish case, so a guard written with
/// either half alone fails open.
struct ScratchTree {

    /// The config homes a scratch tree may never resolve inside, canonicalised.
    static func configHomes(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [URL] {
        var homes = [URL(filePath: NSHomeDirectory()).appending(path: ".claude"),
                     URL(filePath: "/tmp/afleet-fixtures/config-home")]
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            homes.append(URL(filePath: configured))
        }
        return homes.map(canonical)
    }

    /// `url` resolved through its nearest **existing** ancestor, with the components below it
    /// re-appended. `resolvingSymlinksInPath()` resolves nothing in a path that does not exist,
    /// which is precisely the path this type is about to create.
    static func canonical(_ url: URL) -> URL {
        let manager = FileManager.default
        var missing: [String] = []
        var existing = url.standardized
        while !manager.fileExists(atPath: existing.path(percentEncoded: false)) {
            let parent = existing.deletingLastPathComponent().standardized
            guard parent.pathComponents.count < existing.pathComponents.count else { break }
            missing.append(existing.lastPathComponent)
            existing = parent
        }
        var resolved = URL(filePath: realpath(existing.path(percentEncoded: false))
                           ?? existing.resolvingSymlinksInPath().path(percentEncoded: false))
        for component in missing.reversed() { resolved = resolved.appending(path: component) }
        return resolved
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `base` is `home` or lies inside it, by filesystem identity first — macOS mounts
    /// the data volume twice, so one directory has two spellings that share no components — and by
    /// case-insensitive components second, for the paths that do not exist yet and so have no
    /// inode to compare.
    static func contains(_ home: URL, _ base: URL) -> Bool {
        if sharesIdentity(home, base) { return true }
        let inside = base.pathComponents, outside = home.pathComponents
        guard inside.count >= outside.count else { return false }
        for (mine, theirs) in zip(inside, outside) where !sameComponent(mine, theirs) { return false }
        return true
    }

    private static func sharesIdentity(_ home: URL, _ base: URL) -> Bool {
        guard let target = identity(home) else { return false }
        var candidate = base.standardized
        while true {
            if let found = identity(candidate), found == target { return true }
            let parent = candidate.deletingLastPathComponent().standardized
            guard parent.pathComponents.count < candidate.pathComponents.count else { return false }
            candidate = parent
        }
    }

    private static func identity(_ url: URL) -> (dev_t, ino_t)? {
        var status = stat()
        guard lstat(url.path(percentEncoded: false), &status) == 0 else { return nil }
        return (status.st_dev, status.st_ino)
    }

    private static func sameComponent(_ one: String, _ other: String) -> Bool {
        one.precomposedStringWithCanonicalMapping
            .compare(other.precomposedStringWithCanonicalMapping, options: [.caseInsensitive])
            == .orderedSame
    }

    /// The root of this tree, created by `init` and unique to it.
    let root: URL

    init() throws {
        try self.init(temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    init(temporaryDirectory: URL, configHomes: [URL] = ScratchTree.configHomes()) throws {
        let base = ScratchTree.canonical(temporaryDirectory)
        for home in configHomes.map(ScratchTree.canonical) where ScratchTree.contains(home, base) {
            throw XCTSkip("temporary directory resolves inside a config home")
        }
        root = base.appending(path: "afleet-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relativePath: String, _ contents: String = "") throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func symlink(_ relativePath: String, to destination: String) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path(percentEncoded: false),
                                                   withDestinationPath: destination)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// A real repository inside a `ScratchTree`, built with the machine's own `git`.
///
/// The private fixture builder T1 and T5 are told to write: C7.3's equivalent lives in another
/// target's test sources and a test target cannot import another's, so this is a deliberate
/// duplicate of the parts these two tasks need (filed as a tracker entry at close-out).
///
/// Every invocation runs with the global and system configuration disabled, the system
/// *gitattributes* tier disabled too, a fixed `TZ` and `LC_ALL`, `HOME` inside the tree, the
/// terminal prompt off, fixed dates and an **invented** identity — never the machine's (§11).
/// Without that a developer's own configuration (`init.defaultBranch`, `commit.gpgsign`,
/// `diff.renames`, `core.excludesFile`, `core.hooksPath`) changes the bytes these tests read and
/// makes the suite pass or fail by accident of the machine.
final class GitRepository {

    /// Invented, and deliberately not resembling any real person (§11).
    static let authorName = "Marlow Quill"
    static let authorEmail = "marlow.quill@example.invalid"
    /// A fixed instant, so a commit's bytes do not depend on when the suite ran; each commit adds
    /// its ordinal so that two commits with the same tree and message still get distinct hashes.
    static let baseTimestamp = 1_614_800_000

    /// Names the subcommand and the exit code and nothing else: stderr from a command run in a
    /// temporary directory carries the machine account's own name (§6.3, §11).
    struct Failure: Error, CustomStringConvertible {
        let subcommand: String
        let exitCode: Int32
        var description: String { "the fixture's \(subcommand) exited \(exitCode)" }
    }

    let root: URL
    private(set) var environment: [String: String]
    private let runner = ToolRunner()
    private var commitCount = 0

    init(_ tree: ScratchTree, name: String = "repo") async throws {
        root = try tree.directory(name)
        let home = try tree.directory("\(name)-home")
        // `PATH` is the test process's, because the fixture has to find the machine's `git`; every
        // other variable is authored here. The dictionary is exhaustive — `ToolRunner` passes
        // exactly what it is given — so anything not listed is absent from the child.
        environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": home.path(percentEncoded: false),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_ATTR_NOSYSTEM": "1",
            "TZ": "UTC",
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": Self.authorName,
            "GIT_AUTHOR_EMAIL": Self.authorEmail,
            "GIT_COMMITTER_NAME": Self.authorName,
            "GIT_COMMITTER_EMAIL": Self.authorEmail,
        ]
        try await run(["init", "-b", "main"])
        try await run(["config", "user.name", Self.authorName])
        try await run(["config", "user.email", Self.authorEmail])
    }

    @discardableResult
    func run(_ arguments: [String], in directory: URL? = nil,
             extraEnvironment: [String: String] = [:]) async throws -> ToolOutput {
        var environment = self.environment
        for (key, value) in extraEnvironment { environment[key] = value }
        let output = try await runner.run(.git, arguments: arguments, cwd: directory ?? root,
                                          environment: environment, timeout: .seconds(30))
        guard output.exitCode == 0 else {
            throw Failure(subcommand: arguments.first ?? "", exitCode: output.exitCode)
        }
        return output
    }

    /// Writes `files`, stages everything and commits; returns the new `HEAD`.
    @discardableResult
    func commit(_ message: String, files: [String: String] = [:]) async throws -> String {
        for (path, contents) in files { try write(path, contents) }
        return try await commitStaged(message)
    }

    /// Commits whatever is in the working tree, without writing anything first.
    @discardableResult
    func commitStaged(_ message: String) async throws -> String {
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        try await run(["add", "-A"])
        try await run(["commit", "--allow-empty", "-m", message],
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
        let head = try await run(["rev-parse", "HEAD"])
        return head.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ relativePath: String, _ contents: String) throws {
        try write(relativePath, bytes: Data(contents.utf8))
    }

    /// Raw bytes, which is the one thing a `String` cannot express: a **binary** file, whose
    /// `--numstat` counts git prints as `-` and from which `FileChange.isBinary` is derived.
    func write(_ relativePath: String, bytes: Data) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: root.appending(path: relativePath))
    }

    /// A staged move: the shape whose original side lives at the *old* path.
    func rename(_ from: String, to: String) async throws {
        try await run(["mv", from, to])
    }

    /// Adds `other` as a **submodule** and commits it. A submodule is the one entry that is
    /// neither a file nor a link: git records a *gitlink*, mode `160000`, whose object is a commit
    /// in another repository, and neither side of it can be blob-read.
    ///
    /// `protocol.file.allow=always` is scoped to this one command line because git refuses the
    /// `file` transport for submodules by default (CVE-2022-39253); the source is another
    /// repository in the same scratch tree and nothing here reaches the network.
    func addSubmodule(_ other: GitRepository, at relativePath: String) async throws {
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        try await run(["-c", "protocol.file.allow=always", "submodule", "add", "--quiet",
                       other.root.path(percentEncoded: false), relativePath])
        try await run(["commit", "-m", "add a submodule"],
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
    }

    /// Commits inside the submodule checked out at `relativePath`, which leaves the superproject
    /// carrying exactly one change: the gitlink now names a different commit.
    func commitInsideSubmodule(at relativePath: String, files: [String: String]) async throws {
        let inner = root.appending(path: relativePath)
        for (path, contents) in files {
            let url = inner.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        try await run(["add", "-A"], in: inner)
        try await run(["commit", "-m", "advance the submodule"], in: inner,
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
    }
}

/// A `ToolRunning` that runs the machine's own `git` and records every argument vector it was
/// asked for.
///
/// The recording is the assertion for the two cases that are about a command **not** running: an
/// added file whose original side must never be blob-read, and a gitlink that is never blob-read
/// at all. A test that only compared texts would pass on a resolver that read and swallowed.
final class RecordingRunner: ToolRunning, @unchecked Sendable {

    private let underlying = ToolRunner()
    private let lock = NSLock()
    private var recorded: [[String]] = []

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        lock.withLock { recorded.append(arguments) }
        return try await underlying.run(tool, arguments: arguments, cwd: cwd,
                                        environment: environment, timeout: timeout)
    }

    var invocations: [[String]] { lock.withLock { recorded } }

    /// Every `cat-file blob` object name this runner was asked for — the `<rev>:<path>` form.
    var blobObjectNames: [String] {
        invocations.compactMap { arguments in
            guard arguments.count >= 3, arguments[0] == "cat-file", arguments[1] == "blob"
            else { return nil }
            return arguments[2]
        }
    }

    /// Every revision this runner was asked to verify. A parent revision is resolved before it is
    /// read, so a resolver that "tried the parent and swallowed the failure" is visible here even
    /// when no blob was ever asked for.
    var verifiedRevisions: [String] {
        invocations.compactMap { arguments in
            guard arguments.first == "rev-parse", arguments.contains("--verify") else { return nil }
            return arguments.last
        }
    }
}
