import Foundation
import XCTest
@testable import FilesPanel
import SourceControlCore

/// Spec Design §3: the tree enumerates lazily, sorts directories first then by localized name,
/// re-enumerates only on an explicit refresh, hides dotfiles behind a toggle, lists symbolic links
/// without following them, filters over loaded nodes only, and classifies a directory's entries
/// with **one** batched `check-ignore` whose failure is a panel-local state rather than an
/// exception.
///
/// Every tree these tests build lives under `FileManager.default.temporaryDirectory`: `open(2)` on
/// the user's content directories is TCC-gated on this machine, so a test reads only what it
/// created. No assertion names a path (§6.3, §11) — names, counts and sets only.
@MainActor
final class FileTreeTests: XCTestCase {

    private var tree: ScratchTree!

    override func setUp() async throws {
        try await super.setUp()
        tree = try ScratchTree()
    }

    override func tearDown() async throws {
        tree?.remove()
        tree = nil
        try await super.tearDown()
    }

    /// The environment a tree gets when the test is not about git at all: the process's `PATH`, so
    /// `git` resolves, and nothing else.
    private var plainEnvironment: [String: String] {
        ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
    }

    private func names(_ nodes: [FileTree.Node]) -> [String] { nodes.map(\.name) }

    // MARK: - 1. laziness and order

    func testAListingIsDirectoriesFirstThenLocalizedNameAndIsNotReEnumeratedUntilRefresh() async throws {
        try tree.file("zebra.txt")
        try tree.file("Apple.txt")
        try tree.directory("widgets")
        try tree.directory("Alcove")
        let model = FileTree(root: tree.root, environment: plainEnvironment, runner: ToolRunner())

        let first = await model.children(of: tree.root)
        XCTAssertEqual(names(first), ["Alcove", "widgets", "Apple.txt", "zebra.txt"],
                       "directories come first, then localized name")

        try tree.file("mango.txt")
        let second = await model.children(of: tree.root)
        XCTAssertEqual(names(second), names(first), "a loaded directory is not re-enumerated")

        await model.refresh(tree.root)
        let third = await model.children(of: tree.root)
        XCTAssertEqual(names(third), ["Alcove", "widgets", "Apple.txt", "mango.txt", "zebra.txt"],
                       "an explicit refresh re-enumerates")
    }

    func testASubdirectoryIsEnumeratedOnlyWhenItIsAskedFor() async throws {
        try tree.file("nested/inner.txt")
        let model = FileTree(root: tree.root, environment: plainEnvironment, runner: ToolRunner())

        _ = await model.children(of: tree.root)
        XCTAssertFalse(model.isLoaded(tree.root.appending(path: "nested")),
                       "listing a directory does not enumerate its children")

        let inner = await model.children(of: tree.root.appending(path: "nested"))
        XCTAssertEqual(names(inner), ["inner.txt"])
    }

    // MARK: - 2. dotfiles

    func testDotfilesAreAbsentByDefaultAndPresentWithTheToggle() async throws {
        try tree.file(".hidden")
        try tree.file("visible.txt")
        let model = FileTree(root: tree.root, environment: plainEnvironment, runner: ToolRunner())

        let withoutDotfiles = await model.children(of: tree.root)
        XCTAssertEqual(names(withoutDotfiles), ["visible.txt"])

        model.showsHiddenFiles = true
        let withDotfiles = await model.children(of: tree.root)
        XCTAssertEqual(names(withDotfiles), [".hidden", "visible.txt"],
                       "the toggle reveals dotfiles without re-enumerating")
    }

    // MARK: - 3. symbolic links

    func testASymbolicLinkIsListedMarkedAndNeverFollowedInto() async throws {
        try tree.directory("inner")
        try tree.file("inner/leaf.txt")
        // A link pointing at its own ancestor: the case an unguarded walk descends forever.
        try tree.symlink("inner/upwards", to: "..")
        let model = FileTree(root: tree.root, environment: plainEnvironment, runner: ToolRunner())
        let inner = tree.root.appending(path: "inner")

        let listing = await model.children(of: inner)
        XCTAssertEqual(names(listing), ["leaf.txt", "upwards"],
                       "a link is listed and does not sort as a directory")
        let link = try XCTUnwrap(listing.first { $0.name == "upwards" })
        XCTAssertTrue(link.isSymbolicLink, "the link is marked")
        XCTAssertFalse(link.isDirectory, "a link is never offered as an expandable directory")

        let followed = await model.children(of: link.url)
        XCTAssertEqual(followed.count, 0, "expanding a link enumerates nothing")
        XCTAssertFalse(model.isLoaded(link.url), "and nothing about it is cached")
    }

    // MARK: - 4. the filter

    func testTheFilterIsCaseInsensitiveOverLoadedNodesOnlyAndClearingItRestoresTheListing() async throws {
        try tree.file("Report.md")
        try tree.file("report-draft.md")
        try tree.file("summary.txt")
        try tree.directory("reports")
        try tree.file("reports/deep-report.md")
        let model = FileTree(root: tree.root, environment: plainEnvironment, runner: ToolRunner())

        let unfiltered = await model.children(of: tree.root)
        XCTAssertEqual(unfiltered.count, 4)

        model.filter = "REPORT"
        let filtered = await model.children(of: tree.root)
        XCTAssertEqual(Set(names(filtered)), ["reports", "Report.md", "report-draft.md"],
                       "a case-insensitive substring over the loaded names")
        XCTAssertEqual(names(filtered), names(unfiltered).filter { $0 != "summary.txt" },
                       "the filter subsets the listing without reordering it")
        XCTAssertFalse(model.isLoaded(tree.root.appending(path: "reports")),
                       "the filter is not a search: it loads nothing")

        model.filter = ""
        let restored = await model.children(of: tree.root)
        XCTAssertEqual(names(restored), names(unfiltered), "clearing restores order and count")
    }

    /// A directory whose own name does not match is still the way to a loaded node that does.
    /// The column flattens what `children(of:)` answers, so a directory dropped here takes every
    /// loaded descendant off the screen with it and the filter appears to match nothing.
    func testTheFilterKeepsADirectoryWhoseLoadedDescendantMatches() async throws {
        try tree.file("src/main.swift")
        try tree.file("src/nested/deep.swift")
        try tree.file("docs/guide.md")
        let model = FileTree(root: tree.root, environment: plainEnvironment, runner: ToolRunner())
        // Expanded the way the column expands: every directory is asked for by the URL its own
        // node carries, which is the key the listing is held under.
        let atRoot = await model.children(of: tree.root)
        let source = try XCTUnwrap(atRoot.first { $0.name == "src" })
        let inSourceUnfiltered = await model.children(of: source.url)
        let nested = try XCTUnwrap(inSourceUnfiltered.first { $0.name == "nested" })
        _ = await model.children(of: nested.url)

        model.filter = "main"

        var top = names(await model.children(of: tree.root))
        var inSource = names(await model.children(of: source.url))
        XCTAssertEqual(top, ["src"],
                       "the way to a loaded match was filtered away with the directories")
        XCTAssertEqual(inSource, ["main.swift"],
                       "the match itself is still listed under its directory")

        model.filter = "deep"
        top = names(await model.children(of: tree.root))
        inSource = names(await model.children(of: source.url))
        XCTAssertEqual(top, ["src"], "a match two levels down keeps its ancestors")
        XCTAssertEqual(inSource, ["nested"],
                       "the intermediate directory is kept for the match below it")

        model.filter = "nothing-here"
        top = names(await model.children(of: tree.root))
        XCTAssertEqual(top, [], "a filter nothing matches still empties the listing")
    }

    // MARK: - 4b. turning the ignore toggle on

    /// The column keys its enumeration on `hidesIgnoredFiles`, so the moment that property moves
    /// it rebuilds its rows from whatever the cache holds *then*. A toggle published before the
    /// classification it pays for therefore rebuilds over unclassified entries, and nothing later
    /// moves the key again: the ignored rows stay on screen until something else refreshes.
    /// So the toggle is published only once the answer is in the listing.
    func testTurningTheIgnoreToggleOnPublishesItOnlyOnceTheClassificationIsInTheListing() async throws {
        let repository = try await GitRepository(tree)
        try repository.write(".gitignore", "*.log\n")
        try repository.write("noisy.log", "noise\n")
        try repository.write("kept.txt", "kept\n")
        let model = FileTree(root: repository.root, environment: repository.environment,
                             runner: ToolRunner(), hidesIgnoredFiles: false)
        _ = await model.children(of: repository.root)
        XCTAssertTrue(model.entries(of: repository.root).allSatisfy { !$0.isIgnored },
                      "the premise did not hold: the listing was already classified")

        let toggling = Task { await model.setHidesIgnoredFiles(true) }
        let deadline = ContinuousClock().now + .seconds(20)
        while !model.hidesIgnoredFiles, ContinuousClock().now < deadline { await Task.yield() }
        // Read synchronously, at the first moment a view observing the toggle would rebuild.
        let ignoredWhenTheTogglePublished =
            Set(model.entries(of: repository.root).filter(\.isIgnored).map(\.name))
        await toggling.value

        XCTAssertTrue(model.hidesIgnoredFiles, "the toggle never published")
        XCTAssertEqual(ignoredWhenTheTogglePublished, ["noisy.log"],
                       "the toggle published before the classification it pays for")
        let visible = names(await model.children(of: repository.root))
        XCTAssertEqual(visible, ["kept.txt"])
    }

    // MARK: - 5. the gitignore batch

    func testTheGitignoreBatchNamesWhichEntriesAreIgnored() async throws {
        let repository = try await GitRepository(tree)
        try repository.write(".gitignore", "build/\n*.log\n")
        try repository.write("keep.txt", "kept\n")
        try repository.write("notes.log", "noisy\n")
        // A name carrying a newline is in the fixture because line-oriented output is the whole
        // reason the batch is spelled the way it is.
        try repository.write("odd\nname.log", "also noisy\n")
        try repository.write("build/out.o", "artifact\n")
        try repository.write("src/main.swift", "source\n")

        let model = FileTree(root: repository.root, environment: repository.environment,
                             runner: ToolRunner())
        let visible = await model.children(of: repository.root)

        XCTAssertEqual(model.gitignore, .available)
        XCTAssertEqual(names(visible), ["src", "keep.txt"], "ignored entries are hidden")
        let ignored = Set(model.entries(of: repository.root).filter(\.isIgnored).map(\.name))
        XCTAssertEqual(ignored, ["build", "notes.log", "odd\nname.log"],
                       "the classification names which entries are ignored")
    }

    func testOneDirectoryIsClassifiedByOneInvocation() async throws {
        let repository = try await GitRepository(tree)
        try repository.write(".gitignore", "*.log\n")
        for index in 0..<12 { try repository.write("file-\(index).log", "noise\n") }

        let runner = RecordingRunner()
        let model = FileTree(root: repository.root, environment: repository.environment,
                             runner: runner)
        _ = await model.children(of: repository.root)

        let batches = runner.invocations.filter { $0.first == "check-ignore" }
        XCTAssertEqual(batches.count, 1, "one process for a listing, not one per row")
    }

    // MARK: - 6. nothing matched is a normal answer

    func testNothingIgnoredIsANormalAnswerRatherThanAFailure() async throws {
        let repository = try await GitRepository(tree)
        try repository.write(".gitignore", "never-created/\n")
        try repository.write("alpha.txt", "a\n")
        try repository.write("beta.txt", "b\n")

        let model = FileTree(root: repository.root, environment: repository.environment,
                             runner: ToolRunner())
        let visible = await model.children(of: repository.root)

        XCTAssertEqual(model.gitignore, .available, "an exit of 1 means nothing matched")
        XCTAssertEqual(names(visible), ["alpha.txt", "beta.txt"], "the listing is complete")
        XCTAssertTrue(model.entries(of: repository.root).allSatisfy { !$0.isIgnored })
    }

    // MARK: - 7. no repository, and no git

    func testADirectoryInNoRepositoryDisablesTheToggleAndListsEverything() async throws {
        try tree.file("alpha.txt")
        try tree.file("beta.txt")
        let model = FileTree(root: tree.root, environment: plainEnvironment, runner: ToolRunner())

        let visible = await model.children(of: tree.root)

        XCTAssertEqual(model.gitignore, .unavailable)
        XCTAssertTrue(model.hidesIgnoredFiles, "the preference is kept; it is the answer that is missing")
        XCTAssertEqual(names(visible), ["alpha.txt", "beta.txt"])
    }

    func testNoGitOnTheResolvedPathDisablesTheToggleAndListsEverything() async throws {
        let repository = try await GitRepository(tree)
        try repository.write(".gitignore", "*.log\n")
        try repository.write("noisy.log", "noise\n")
        try repository.write("kept.txt", "kept\n")
        var environment = repository.environment
        environment["PATH"] = tree.root.appending(path: "no-tools").path(percentEncoded: false)

        let model = FileTree(root: repository.root, environment: environment, runner: ToolRunner())
        let visible = await model.children(of: repository.root)

        XCTAssertEqual(model.gitignore, .unavailable)
        XCTAssertEqual(names(visible), ["kept.txt", "noisy.log"],
                       "everything is listed when the classification cannot be asked for")
    }

    // MARK: - 8. a negation pattern

    /// A negation pattern re-includes the file it names, and the record that says so is **not**
    /// the `::` of a record that matched nothing: it carries the negated pattern in its pattern
    /// field. Measured on this machine's git 2.55.0 with `*.log` then `!keep.log` (tabs shown):
    ///
    ///     .gitignore:1:*.log<TAB>./noisy.log
    ///     .gitignore:2:!keep.log<TAB>./keep.log
    ///     ::<TAB>./kept.txt
    ///
    /// The same measurement fixes what the fixture may claim: `build/` followed by
    /// `!build/keep.me` re-includes nothing, because a file whose parent directory is excluded
    /// cannot be re-included — that record's pattern is `build/`, and the entry really is ignored.
    func testANegationPatternReIncludesTheFileItNames() async throws {
        let repository = try await GitRepository(tree)
        try repository.write(".gitignore", "*.log\n!keep.log\nbuild/\n!build/keep.me\n")
        try repository.write("noisy.log", "noise\n")
        try repository.write("keep.log", "kept\n")
        try repository.write("kept.txt", "kept\n")
        try repository.write("build/keep.me", "artifact\n")

        let model = FileTree(root: repository.root, environment: repository.environment,
                             runner: ToolRunner())
        let visible = await model.children(of: repository.root)

        XCTAssertEqual(model.gitignore, .available)
        XCTAssertEqual(names(visible), ["keep.log", "kept.txt"],
                       "a file a negation pattern re-includes is listed")
        let ignored = Set(model.entries(of: repository.root).filter(\.isIgnored).map(\.name))
        XCTAssertEqual(ignored, ["build", "noisy.log"],
                       "an excluded directory stays excluded, a negation inside it or not")
    }
}
