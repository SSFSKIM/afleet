import Foundation
import XCTest
@testable import SourceControlPanel
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
        root = base.appending(path: "afleet-scm-\(UUID().uuidString)")
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
/// The private fixture builder this leaf's Wave A is handed: C7.3's equivalent lives in another
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
    static let authorName = "Sable Quintrell"
    static let authorEmail = "sable.quintrell@example.invalid"
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

    // MARK: - The shapes a graph needs (C7.7)
    //
    // C7.3's fixture has these and this target cannot import it. They are here rather than in a
    // task's own file because Wave A's four tasks are dispatched in parallel and share this file
    // read-only.

    /// Creates `name` at the current `HEAD` and leaves `HEAD` where it was.
    func branch(_ name: String) async throws {
        try await run(["branch", name])
    }

    /// Creates `name` at `ref`.
    func branch(_ name: String, from ref: String) async throws {
        try await run(["branch", name, ref])
    }

    func checkout(_ ref: String) async throws {
        try await run(["checkout", "--quiet", ref])
    }

    /// An annotated tag, which is a tag object rather than a lightweight ref — both decorate the
    /// same way through `%D`, and the annotated form is the one a repository is likelier to hold.
    func tag(_ name: String) async throws {
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        try await run(["tag", "-a", name, "-m", "tag \(name)"],
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
    }

    /// Merges `refs` into the current branch with a merge commit, always — `--no-ff` because a
    /// fast-forwardable merge produces no merge commit at all and the lane fixtures exist to have
    /// one. Two or more refs is an **octopus** merge, which is the three-parent shape.
    @discardableResult
    func merge(_ refs: [String], message: String) async throws -> String {
        commitCount += 1
        let stamp = "\(Self.baseTimestamp + commitCount) +0000"
        try await run(["merge", "--no-ff", "--no-edit", "-m", message] + refs,
                      extraEnvironment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
        let head = try await run(["rev-parse", "HEAD"])
        return head.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Detaches `HEAD` at `ref`, which is the shape whose `%D` carries a bare `HEAD` decoration
    /// with no arrow.
    func detach(_ ref: String) async throws {
        try await run(["checkout", "--quiet", "--detach", ref])
    }

    /// The repository-root path, for a test that has to hand a *subdirectory* as the channel's
    /// cwd — the case a reader that trusted its `cwd` gets wrong (C7.3's D13).
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A `ToolRunning` that runs the machine's own binary and records every invocation, tool included.
///
/// The tool is recorded as well as the arguments because two of this leaf's gates are assertions
/// about a **universe of invocations** and not about one call: G4 asserts that no `git` argument
/// vector this target can produce begins with a write verb, and G3 that no `gh` vector begins with
/// `auth`. Both are read off `invocations` across a whole suite, so a suite that recorded nothing
/// must fail rather than pass vacuously — which is what `assertOnlyReadVerbs` below is for.
final class RecordingRunner: ToolRunning, @unchecked Sendable {

    /// One invocation as this runner saw it. No environment and no cwd: a recorded environment is
    /// a dump, and §6.3 forbids one in an assertion.
    struct Invocation: Sendable, Equatable {
        let tool: Tool
        let arguments: [String]
        /// The first argument that is not an option, which is the verb — `git -c foo=bar log` is a
        /// `log`. Empty when there is none.
        var verb: String { arguments.first { !$0.hasPrefix("-") } ?? "" }
    }

    private let underlying: any ToolRunning
    private let lock = NSLock()
    private var recorded: [Invocation] = []

    /// Wraps the real runner by default; a stub is passed for the `gh` suites, which have no
    /// account to read and must not have one.
    init(underlying: any ToolRunning = ToolRunner()) {
        self.underlying = underlying
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        lock.withLock { recorded.append(Invocation(tool: tool, arguments: arguments)) }
        return try await underlying.run(tool, arguments: arguments, cwd: cwd,
                                        environment: environment, timeout: timeout)
    }

    var invocations: [Invocation] { lock.withLock { recorded } }

    func invocations(of tool: Tool) -> [Invocation] { invocations.filter { $0.tool == tool } }

    func verbs(of tool: Tool) -> [String] { invocations(of: tool).map(\.verb) }

    /// Every `cat-file blob` object name asked for — the `<rev>:<path>` form. The assertion for a
    /// case that is about a command **not** running: a gitlink is never blob-read.
    var blobObjectNames: [String] {
        invocations(of: .git).compactMap { invocation in
            let arguments = invocation.arguments
            guard arguments.count >= 3, arguments[0] == "cat-file", arguments[1] == "blob"
            else { return nil }
            return arguments[2]
        }
    }
}

/// A `ToolRunning` that answers from a script instead of spawning anything.
///
/// Every `gh` suite in this target runs on one of these: the machine's `gh` holds the author's own
/// token and its output would be a recorded account in a committed expectation (§11). The samples
/// under `Samples/` are authored documents with real field names and invented values, and this is
/// what serves them.
final class StubRunner: ToolRunning, @unchecked Sendable {

    /// What the stub answers for one invocation.
    enum Answer: Sendable {
        /// Exit zero with these bytes on stdout.
        case document(Data)
        /// Exit `code` with `stderr` behind it — the shape a `gh` that is not logged in produces.
        case failure(code: Int32, stderr: String)
        /// The binary is not on the resolved PATH.
        case binaryNotFound
    }

    /// Matched against the invocation's arguments joined by a space, by prefix, in order. The
    /// first match answers; an unmatched invocation is a failure the test sees rather than a
    /// silent empty document.
    private let script: [(prefix: String, answer: Answer)]
    private let lock = NSLock()
    private var recorded: [RecordingRunner.Invocation] = []

    init(_ script: [(String, Answer)]) {
        self.script = script.map { (prefix: $0.0, answer: $0.1) }
    }

    var invocations: [RecordingRunner.Invocation] { lock.withLock { recorded } }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        lock.withLock { recorded.append(RecordingRunner.Invocation(tool: tool, arguments: arguments)) }
        let line = arguments.joined(separator: " ")
        guard let match = script.first(where: { line.hasPrefix($0.prefix) }) else {
            throw ToolError.commandFailed(tool: tool, exitCode: 127,
                                          stderrTail: "the stub has no answer for this invocation")
        }
        switch match.answer {
        case .document(let data):
            return ToolOutput(stdout: data, stderr: Data(), exitCode: 0, timedOut: false)
        case .failure(let code, let stderr):
            return ToolOutput(stdout: Data(), stderr: Data(stderr.utf8), exitCode: code,
                              timedOut: false)
        case .binaryNotFound:
            throw ToolError.binaryNotFound(tool: tool)
        }
    }
}

/// The authored `gh` documents, read out of the test bundle.
enum GhSamples {

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json",
                                          subdirectory: "Samples") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
