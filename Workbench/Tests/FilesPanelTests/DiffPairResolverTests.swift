import Foundation
import XCTest
@testable import FilesPanel
import AfleetCore
import EditorCore
import SourceControlCore

/// Spec Design §5 and gate G3's headless half: for each `DiffRef.Base`, over repositories built
/// with the machine's own `git` under a temporary directory, the resolved pair is asserted by its
/// **contents** — and the two cases that are about a command *not* running are asserted by the
/// runner's record.
///
/// No assertion names a path (§6.3, §11); the repositories carry invented names throughout.
final class DiffPairResolverTests: XCTestCase {

    private var tree: ScratchTree!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tree = try ScratchTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
        super.tearDown()
    }

    private func resolver(_ repository: GitRepository, runner: any ToolRunning,
                          language: @escaping DiffPairResolver.LanguageForPath
                              = DiffPairResolver.plaintext) -> DiffPairResolver {
        DiffPairResolver(runner: runner, environment: repository.environment, language: language)
    }

    /// The two sides of a `.pair`, or a failure naming what came back instead.
    private func sides(_ resolution: DiffPairResolution,
                       file: StaticString = #filePath, line: UInt = #line) throws
        -> (original: String, modified: String) {
        guard case .pair(let command) = resolution,
              case .showDiff(_, let original, let modified, _) = command else {
            // The case, never the value: a resolution carries a path and both sides' contents, and
            // an assertion message is a published byte (§6.3, §11).
            XCTFail("expected a pair, got a no-text-diff state", file: file, line: line)
            throw XCTSkip("no pair")
        }
        return (original, modified)
    }

    // MARK: - 1. the working tree against HEAD

    func testTheWorkingTreeAgainstHeadPairsTheCommittedTextWithTheWorkingText() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.txt": "committed\n"])
        try repository.write("notes.txt", "working\n")

        let reference = DiffRef(repository: repository.root, path: "notes.txt",
                                base: .workingTreeAgainstHEAD)
        let pair = try sides(try await resolver(repository, runner: ToolRunner()).resolve(reference))

        XCTAssertEqual(pair.original, "committed\n")
        XCTAssertEqual(pair.modified, "working\n")
    }

    func testALinkPointingIntoASubdirectoryIsResolvedAtTheRepositoryRoot() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["module/notes.txt": "committed\n"])
        try repository.write("module/notes.txt", "working\n")

        // The `repository` a link carries is documented as the working-tree root; a subdirectory
        // must resolve to the same pair rather than to a path that does not exist.
        let reference = DiffRef(repository: repository.root.appending(path: "module"),
                                path: "module/notes.txt", base: .workingTreeAgainstHEAD)
        let pair = try sides(try await resolver(repository, runner: ToolRunner()).resolve(reference))

        XCTAssertEqual(pair.original, "committed\n")
        XCTAssertEqual(pair.modified, "working\n")
    }

    // MARK: - 2. a named commit against the working tree

    func testACommitBasePairsThatCommitsTextWithTheWorkingText() async throws {
        let repository = try await GitRepository(tree)
        let first = try await repository.commit("first", files: ["notes.txt": "first\n"])
        try await repository.commit("second", files: ["notes.txt": "second\n"])
        try repository.write("notes.txt", "working\n")

        let reference = DiffRef(repository: repository.root, path: "notes.txt",
                                base: .commit(first))
        let pair = try sides(try await resolver(repository, runner: ToolRunner()).resolve(reference))

        XCTAssertEqual(pair.original, "first\n", "the original side is that commit's text")
        XCTAssertEqual(pair.modified, "working\n")
    }

    // MARK: - 3. a commit against its first parent

    func testACommitAgainstItsParentPairsTheParentsTextWithTheCommitsText() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("first", files: ["notes.txt": "first\n"])
        let second = try await repository.commit("second", files: ["notes.txt": "second\n"])
        try repository.write("notes.txt", "working\n")

        let reference = DiffRef(repository: repository.root, path: "notes.txt",
                                base: .commitAgainstParent(second))
        let pair = try sides(try await resolver(repository, runner: ToolRunner()).resolve(reference))

        XCTAssertEqual(pair.original, "first\n")
        XCTAssertEqual(pair.modified, "second\n",
                       "the modified side is the commit, not the working tree")
    }

    // MARK: - 4. an added file has no original side

    func testAnAddedFileHasNoOriginalSideAndNoBlobIsReadForOne() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["notes.txt": "kept\n"])
        try repository.write("arrival.txt", "new\n")
        try await repository.run(["add", "arrival.txt"])

        let runner = RecordingRunner()
        let reference = DiffRef(repository: repository.root, path: "arrival.txt",
                                base: .workingTreeAgainstHEAD)
        let pair = try sides(try await resolver(repository, runner: runner).resolve(reference))

        XCTAssertEqual(pair.original, "", "an added file has no original side")
        XCTAssertEqual(pair.modified, "new\n")
        XCTAssertFalse(runner.blobObjectNames.contains { $0.hasSuffix(":arrival.txt") },
                       "the emptiness came from the changed-file list, not from a swallowed read")
    }

    // MARK: - 5. a deleted file has no modified side

    func testADeletedFileHasNoModifiedSide() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["departure.txt": "was here\n"])
        try await repository.run(["rm", "--quiet", "departure.txt"])

        let reference = DiffRef(repository: repository.root, path: "departure.txt",
                                base: .workingTreeAgainstHEAD)
        let pair = try sides(try await resolver(repository, runner: ToolRunner()).resolve(reference))

        XCTAssertEqual(pair.original, "was here\n")
        XCTAssertEqual(pair.modified, "", "a deleted file has no modified side")
    }

    // MARK: - 6. a renamed file reads its original side at the old path

    func testARenamedFileReadsItsOriginalSideAtTheOldPath() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["former.txt": "carried across\n"])
        try await repository.rename("former.txt", to: "latter.txt")

        let runner = RecordingRunner()
        let reference = DiffRef(repository: repository.root, path: "latter.txt",
                                base: .workingTreeAgainstHEAD)
        let pair = try sides(try await resolver(repository, runner: runner).resolve(reference))

        XCTAssertEqual(pair.original, "carried across\n")
        XCTAssertEqual(pair.modified, "carried across\n")
        XCTAssertTrue(runner.blobObjectNames.contains { $0.hasSuffix(":former.txt") },
                      "the original side is read at the old path")
        XCTAssertFalse(runner.blobObjectNames.contains { $0.hasSuffix(":latter.txt") },
                       "a pair keyed on the new path is the defect this case exists for")
    }

    // MARK: - 7. a root commit has no parent to read

    func testARootCommitAgainstItsParentAttemptsNoParentRead() async throws {
        let repository = try await GitRepository(tree)
        let root = try await repository.commit("seed", files: ["origin.txt": "the beginning\n"])

        let runner = RecordingRunner()
        let reference = DiffRef(repository: repository.root, path: "origin.txt",
                                base: .commitAgainstParent(root))
        let pair = try sides(try await resolver(repository, runner: runner).resolve(reference))

        XCTAssertEqual(pair.original, "", "a root commit lists its whole tree as added")
        XCTAssertEqual(pair.modified, "the beginning\n")
        XCTAssertFalse(runner.verifiedRevisions.contains { $0.hasSuffix("^") },
                       "no parent revision is even resolved")
        XCTAssertFalse(runner.blobObjectNames.contains { $0.contains("^") })
    }

    // MARK: - 8. binary content and a gitlink

    func testABinaryFileOffersNoTextDiff() async throws {
        let repository = try await GitRepository(tree)
        try repository.write("mark.bin", bytes: Data([0x00, 0x01, 0x02, 0x00, 0x03]))
        try await repository.commitStaged("seed")
        try repository.write("mark.bin", bytes: Data([0x00, 0x09, 0x09, 0x00, 0x04]))

        let runner = RecordingRunner()
        let reference = DiffRef(repository: repository.root, path: "mark.bin",
                                base: .workingTreeAgainstHEAD)
        let resolution = try await resolver(repository, runner: runner).resolve(reference)

        XCTAssertEqual(resolution, .noTextDiff(.binaryContent))
        XCTAssertFalse(runner.blobObjectNames.contains { $0.hasSuffix(":mark.bin") },
                       "no side of a binary change is read")
    }

    func testASubmoduleGitlinkIsNeverBlobRead() async throws {
        let inner = try await GitRepository(tree, name: "inner")
        try await inner.commit("seed", files: ["inner.txt": "inner\n"])
        let outer = try await GitRepository(tree, name: "outer")
        try await outer.commit("seed", files: ["outer.txt": "outer\n"])
        try await outer.addSubmodule(inner, at: "vendor")
        try await outer.commitInsideSubmodule(at: "vendor", files: ["inner.txt": "advanced\n"])

        let runner = RecordingRunner()
        let reference = DiffRef(repository: outer.root, path: "vendor",
                                base: .workingTreeAgainstHEAD)
        let resolution = try await resolver(outer, runner: runner).resolve(reference)

        XCTAssertEqual(resolution, .noTextDiff(.submodule))
        XCTAssertFalse(runner.blobObjectNames.contains { $0.hasSuffix(":vendor") },
                       "a gitlink names a commit; neither side of it is a blob")
    }

    // MARK: - 9. a path the base did not change

    func testAPathTheBaseDidNotChangeIsANamedStateRatherThanAnEmptyDiff() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["moved.txt": "one\n", "still.txt": "unchanged\n"])
        try repository.write("moved.txt", "two\n")

        let reference = DiffRef(repository: repository.root, path: "still.txt",
                                base: .workingTreeAgainstHEAD)
        let resolution = try await resolver(repository, runner: ToolRunner()).resolve(reference)

        XCTAssertEqual(resolution, .noTextDiff(.pathUnchangedByBase))
    }

    // MARK: - 10. the emitted command

    func testTheProductIsAShowDiffCommandCarryingThePathAndTheLanguage() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["main.swift": "let one = 1\n"])
        try repository.write("main.swift", "let two = 2\n")

        let reference = DiffRef(repository: repository.root, path: "main.swift",
                                base: .workingTreeAgainstHEAD)
        let asked = DiffPairResolver(runner: ToolRunner(), environment: repository.environment,
                                     language: { $0.hasSuffix(".swift") ? "swift" : "plaintext" })
        let resolution = try await asked.resolve(reference)

        XCTAssertEqual(resolution, .pair(.showDiff(path: "main.swift", original: "let one = 1\n",
                                                   modified: "let two = 2\n", language: "swift")))
    }

    func testTheInjectedLanguageDefaultsToPlaintext() async throws {
        let repository = try await GitRepository(tree)
        try await repository.commit("seed", files: ["main.swift": "let one = 1\n"])
        try repository.write("main.swift", "let two = 2\n")

        let reference = DiffRef(repository: repository.root, path: "main.swift",
                                base: .workingTreeAgainstHEAD)
        let resolution = try await resolver(repository, runner: ToolRunner()).resolve(reference)

        guard case .pair(.showDiff(_, _, _, let language)) = resolution else {
            return XCTFail("expected a pair, got a no-text-diff state")
        }
        XCTAssertEqual(language, "plaintext", "the seam's stub until the real map is wired in")
    }

    // MARK: - the decode, which spec Design §5 records as deliberate

    func testAnInvalidByteIsReplacedRatherThanRefused() async throws {
        let repository = try await GitRepository(tree)
        try repository.write("prose.txt", bytes: Data("clean\n".utf8))
        try await repository.commitStaged("seed")
        try repository.write("prose.txt", bytes: Data([0x63, 0x6C, 0x80, 0x61, 0x6E, 0x0A]))

        let reference = DiffRef(repository: repository.root, path: "prose.txt",
                                base: .workingTreeAgainstHEAD)
        let pair = try sides(try await resolver(repository, runner: ToolRunner()).resolve(reference))

        XCTAssertEqual(pair.original, "clean\n")
        XCTAssertEqual(pair.modified, "cl\u{FFFD}an\n",
                       "a diff of a file with one bad byte is shown, not refused")
    }
}
