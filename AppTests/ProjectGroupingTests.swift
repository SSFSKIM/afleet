import Foundation
import XCTest
import AfleetCore
import FleetKit
@testable import Afleet

/// The sidebar's grouping and ordering authority: which section a row lands in, when a repository
/// sub-groups by worktree, what order sections appear in, and where the thirty-day line falls.
///
/// These read `sections` and `archived` directly. Every other test in this task reads `allRows`,
/// which flattens all of it away.
@MainActor
final class ProjectGroupingTests: XCTestCase {

    // MARK: - `.claude.json` order

    /// The project keys come back in the order they appear in the file — and only from inside the
    /// `projects` object.
    ///
    /// The decoy is the discriminating half. `/invented/repo-gamma` appears earlier in the document
    /// as the value of an unrelated field, which the previous implementation's document-wide search
    /// for a quoted key matched, sorting gamma to the front. Reading keys only from within the
    /// object cannot make that mistake.
    func testProjectOrderIsFileOrderAndIgnoresAPathAppearingAsAValue() throws {
        let home = try ScratchConfigHome()
        let text = """
        {"hasCompletedOnboarding":true,\
        "lastReleaseNotesSeen":"/invented/repo-gamma",\
        "projects":{\
        "/invented/repo-alpha":{"hasTrustDialogAccepted":true},\
        "/invented/repo-beta":{"hasTrustDialogAccepted":true},\
        "/invented/repo-gamma":{"hasTrustDialogAccepted":true}}}
        """
        try Data(text.utf8).write(to: home.root.appending(path: ".claude.json"))

        let order = ClaudeProjects.order(globalConfig: home.root.appending(path: ".claude.json"))
        XCTAssertEqual(order.count, 3, "the scan recovered \(order.count) project keys, not three")
        XCTAssertEqual(order, ["/invented/repo-alpha", "/invented/repo-beta", "/invented/repo-gamma"])
    }

    /// A nested object inside a project's own entry does not contribute keys, and neither does an
    /// object that follows `projects` at the top level.
    func testOnlyTheProjectsObjectsOwnKeysAreRead() throws {
        let home = try ScratchConfigHome()
        let text = """
        {"projects":{\
        "/invented/repo-alpha":{"hasTrustDialogAccepted":true,"mcpServers":{"invented-server":{"command":"x"}}},\
        "/invented/repo-beta":{"hasTrustDialogAccepted":false}},\
        "tipsHistory":{"invented-tip":1}}
        """
        try Data(text.utf8).write(to: home.root.appending(path: ".claude.json"))

        let order = ClaudeProjects.order(globalConfig: home.root.appending(path: ".claude.json"))
        XCTAssertEqual(order, ["/invented/repo-alpha", "/invented/repo-beta"])
        XCTAssertFalse(order.contains("mcpServers"))
        XCTAssertFalse(order.contains("invented-tip"))
    }

    /// The launch-path cost guard.
    ///
    /// Not a threshold this is expected to approach: the scan reads this document in about ten
    /// milliseconds, write included. The bound is 500 ms — a factor of fifty over the passing path,
    /// and still a factor of three below the shape this replaced, which measured 1,537 ms here and
    /// 2,080 ms on the reviewer's machine.
    ///
    /// Both margins are sized against a measured number rather than a guessed one. Tracker 56
    /// records this suite taking over ten minutes under load where it normally takes thirty
    /// seconds — a factor of twenty — so a passing-path margin has to clear twenty with room to
    /// spare or it is a flake waiting for a busy machine. Two earlier drafts got this wrong in
    /// opposite directions: one second left only 1.5x against the pre-fix code, close enough that a
    /// faster machine could slip under it and leave the assertion unable to fail, and 250 ms left
    /// only 25x on the passing path, which that same factor of twenty very nearly eats.
    ///
    /// The timing is the weaker of the two guards on this change and is here for the regression a
    /// correctness test cannot see. `testProjectOrderIsFileOrderAndIgnoresAPathAppearingAsAValue` is
    /// the deterministic one. The correctness assertions come first here too, so a scan that
    /// returned nothing could not pass by being fast.
    func testProjectOrderOverALargeDocumentIsNotOnTheCriticalPath() throws {
        let home = try ScratchConfigHome()
        let projectCount = 306
        var entries: [String] = []
        for n in 0..<projectCount {
            // Padded so the document lands near the 514 KB the measurement was taken on.
            let filler = String(repeating: "invented-", count: 150)
            entries.append(#""/invented/repo-\#(n)":{"hasTrustDialogAccepted":true,"exampleFiles":["\#(filler)"]}"#)
        }
        let text = #"{"hasCompletedOnboarding":true,"projects":{"# + entries.joined(separator: ",") + "}}"
        let data = Data(text.utf8)
        try data.write(to: home.root.appending(path: ".claude.json"))
        XCTAssertGreaterThan(data.count, 400_000, "the document is \(data.count) bytes, too small to be the case under test")

        let clock = ContinuousClock()
        let start = clock.now
        let order = ClaudeProjects.order(globalConfig: home.root.appending(path: ".claude.json"))
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(order.count, projectCount)
        XCTAssertEqual(order.first, "/invented/repo-0")
        XCTAssertEqual(order.last, "/invented/repo-\(projectCount - 1)")
        XCTAssertLessThan(elapsed, .milliseconds(500),
                          "reading \(projectCount) project keys from \(data.count) bytes took \(Self.ms(elapsed)) ms")
    }

    // MARK: - Worktree sub-grouping

    /// Two checkouts of one repository are one section with a group per worktree, and a third
    /// unrelated repository stays its own section.
    func testWorktreesOfOneRepositoryBecomeOneSection() throws {
        let tree = try TempTree()
        let repository = try tree.directory("repo-alpha")
        try tree.directory("repo-alpha/.git")
        let first = try tree.directory("worktrees/feature-one")
        let second = try tree.directory("worktrees/feature-two")
        try Data("gitdir: \(repository.path)/.git/worktrees/feature-one\n".utf8)
            .write(to: first.appending(path: ".git"))
        try Data("gitdir: \(repository.path)/.git/worktrees/feature-two\n".utf8)
            .write(to: second.appending(path: ".git"))
        let other = try tree.directory("repo-beta")
        try tree.directory("repo-beta/.git")

        let rows = [Self.row("1", cwd: repository), Self.row("2", cwd: first),
                    Self.row("3", cwd: second), Self.row("4", cwd: other)]
        let sections = ProjectGrouping().sections(from: rows, paths: PathMemo())

        XCTAssertEqual(sections.count, 2, "grouping produced \(sections.count) sections, not two")
        let alpha = try XCTUnwrap(sections.first { $0.title == "repo-alpha" })
        let beta = try XCTUnwrap(sections.first { $0.title == "repo-beta" })
        XCTAssertEqual(alpha.rows.count, 1, "the repository root's own row is not in the section body")
        XCTAssertEqual(alpha.worktrees.map(\.title), ["feature-one", "feature-two"])
        XCTAssertEqual(alpha.allRows.count, 3)
        XCTAssertEqual(Set(alpha.allRows.map(\.id)), Set([Self.session("1"), Self.session("2"), Self.session("3")]))
        // The floor: beta is a real section with a real row, so the split above is a split and not
        // an accident of one bucket being empty.
        XCTAssertEqual(beta.allRows.map(\.id), [Self.session("4")])
        XCTAssertTrue(beta.worktrees.isEmpty)
    }

    /// A worktree's `gitdir` may be relative, and it is relative to the worktree, not to whatever
    /// directory the app happens to have been launched from.
    ///
    /// `git worktree add` writes a relative `gitdir` whenever the repository was cloned or the
    /// worktree created with relative paths configured, so this is an ordinary checkout and not a
    /// contrived one. Resolving it against the process's working directory names a repository that
    /// is somewhere else entirely — usually nowhere — so both checkouts group under a path that
    /// does not exist and the real repository becomes a section of its own.
    ///
    /// The discriminating clause is the identity, not the count: the one section's id is the real
    /// repository directory, which no resolution against the process's own directory can produce.
    func testARelativeGitdirResolvesAgainstTheWorktreeAndNotTheProcess() throws {
        let tree = try TempTree()
        let repository = try tree.directory("repo-alpha")
        try tree.directory("repo-alpha/.git")
        let first = try tree.directory("worktrees/feature-one")
        let second = try tree.directory("worktrees/feature-two")
        // Relative to the worktree directory that holds the `.git` file, which is what git writes.
        try Data("gitdir: ../../repo-alpha/.git/worktrees/feature-one\n".utf8)
            .write(to: first.appending(path: ".git"))
        try Data("gitdir: ../../repo-alpha/.git/worktrees/feature-two\n".utf8)
            .write(to: second.appending(path: ".git"))

        let rows = [Self.row("1", cwd: repository), Self.row("2", cwd: first), Self.row("3", cwd: second)]
        let sections = ProjectGrouping().sections(from: rows, paths: PathMemo())

        XCTAssertEqual(sections.count, 1, "grouping produced \(sections.count) sections, not one")
        let alpha = try XCTUnwrap(sections.first)
        XCTAssertEqual(alpha.id, CanonicalPath.string(repository),
                       "the section is not the repository the worktrees point at")
        XCTAssertEqual(alpha.rows.count, 1, "the repository root's own row is not in the section body")
        XCTAssertEqual(alpha.worktrees.map(\.title), ["feature-one", "feature-two"])
        XCTAssertEqual(alpha.allRows.count, 3)
    }

    /// One checkout is not a sub-grouping: a lone worktree's rows sit in its section's body.
    func testASingleCheckoutIsNotSubGrouped() throws {
        let tree = try TempTree()
        let repository = try tree.directory("repo-alpha")
        try tree.directory("repo-alpha/.git")
        let only = try tree.directory("worktrees/feature-one")
        try Data("gitdir: \(repository.path)/.git/worktrees/feature-one\n".utf8)
            .write(to: only.appending(path: ".git"))

        let sections = ProjectGrouping().sections(from: [Self.row("1", cwd: only)], paths: PathMemo())
        XCTAssertEqual(sections.count, 1)
        let section = try XCTUnwrap(sections.first)
        XCTAssertEqual(section.rows.count, 1, "the lone checkout's row was pushed into a sub-group")
        XCTAssertTrue(section.worktrees.isEmpty)
        XCTAssertEqual(section.title, "repo-alpha", "the section is the repository, not the checkout")
    }

    /// The memo is what stops the grouping re-probing the filesystem on every rebuild. Grouping the
    /// same rows twice through one memo probes nothing the second time.
    /// The section ids SwiftUI hashes are native Swift strings, not lazily bridged `NSString`s.
    ///
    /// **Found by sampling the running app against a real config home of 306 projects**, where the
    /// main thread sat at 100 percent inside `OutlineListCoordinator.diffRows` with
    /// `Dictionary.lookup`, `_StringGutsSlice._normalizedHash` and `-[NSPathStore2 characterAtIndex:]`
    /// at the top of the profile. `PathMemo`'s two answers become `ProjectSection.id` and
    /// `WorktreeGroup.id`, and SwiftUI hashes both into its `ForEach` identity dictionary on every
    /// list diff; hashing a bridged path string costs one Objective-C message per character with
    /// NFC normalisation on top.
    ///
    /// The trigger is narrow and is why nothing caught it earlier: `CanonicalPath.string` returns a
    /// native string when `realpath` succeeds on the first probe and a bridged one only when it had
    /// to walk up and re-append components — that is, for a **directory that no longer exists**. A
    /// config home that has accumulated hundreds of projects is full of those.
    ///
    /// Contiguity is the assertion rather than a stopwatch: a native Swift string yields a
    /// contiguous UTF-8 buffer and a lazily bridged `NSString` does not, so this is the property
    /// itself and not a proxy for it. The third clause is the floor — the raw `CanonicalPath`
    /// answer for the same path *is* non-contiguous, which is what proves the memo is the thing
    /// making the difference and that the first two assertions could have failed.
    func testSectionIDsAreNativeStringsAndNotBridgedPathStores() throws {
        let tree = try TempTree()
        // A directory that does not exist, which is the branch that bridges.
        let missing = tree.root.appending(path: "vanished-repo/checkout", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path),
                       "the fixture path exists, so the bridging branch is not the one under test")

        let memo = PathMemo()
        let root = memo.root(of: missing)
        let repository = memo.repository(of: root)
        XCTAssertTrue(Self.isNative(root), "a section id is a bridged NSString and SwiftUI hashes it per character")
        XCTAssertTrue(Self.isNative(repository), "a worktree group id is a bridged NSString")

        XCTAssertFalse(Self.isNative(CanonicalPath.string(missing)),
                       "CanonicalPath no longer bridges, so this test measures nothing")
    }

    /// A native Swift string exposes a contiguous UTF-8 buffer; a lazily bridged `NSString` does not.
    private static func isNative(_ string: String) -> Bool {
        string.utf8.withContiguousStorageIfAvailable { _ in true } ?? false
    }

    func testThePathMemoIsNotReprobedOnASecondGrouping() throws {
        let tree = try TempTree()
        let repository = try tree.directory("repo-alpha")
        try tree.directory("repo-alpha/.git")
        let rows = [Self.row("1", cwd: repository), Self.row("2", cwd: repository)]
        let memo = PathMemo()

        _ = ProjectGrouping().sections(from: rows, paths: memo)
        let afterFirst = memo.probeCount
        XCTAssertGreaterThan(afterFirst, 0, "the first grouping probed nothing, so there is nothing to re-probe")
        _ = ProjectGrouping().sections(from: rows, paths: memo)
        XCTAssertEqual(memo.probeCount, afterFirst,
                       "the second grouping added \(memo.probeCount - afterFirst) fresh probes")
    }

    /// A directory that does not exist yet is answered, re-derived once it appears, and costs one
    /// derivation per rebuild in the meantime and not a full one.
    ///
    /// §8.2's worktree creation is what produces the case: the row is drawn at
    /// `<repo>/.claude/worktrees/<name>` before the CLI has made the checkout, and the fallback
    /// answer for a missing path is the repository itself. Settling that answer would group the
    /// checkout's channel into the repository's own rows for the life of the process; re-deriving it
    /// every rebuild would put a `realpath` and an upward walk back on the main actor for every row
    /// whose directory is gone, which on a real config home is hundreds of them. So it is held
    /// provisionally, and the gate is one `stat`.
    func testAMissingDirectoryIsAnsweredProvisionallyAndSettledWhenItAppears() throws {
        let tree = try TempTree()
        let repository = try tree.directory("repo-beta")
        try tree.directory("repo-beta/.git")
        let checkout = repository.appending(path: ".claude/worktrees/invented", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.path),
                       "the checkout already exists, so this test measures nothing")

        // `beginGeneration()` is what a rebuild does, and `sections(from:paths:)` calls it; a test
        // that drives the memo directly stands in for the rebuild by calling it too.
        let memo = PathMemo()
        memo.beginGeneration()
        let firstAnswer = memo.root(of: checkout)
        XCTAssertGreaterThan(memo.probeCount, 0, "the first ask derived nothing")
        // The walk finds the repository's own `.git`, which is the answer that must not be settled.
        // Asked before the count is taken, because it is a distinct key and derives once itself.
        XCTAssertTrue(firstAnswer == memo.root(of: repository),
                      "a missing checkout did not fall back to its repository")
        let afterFirst = memo.probeCount

        // A second rebuild while it is still missing re-derives nothing.
        memo.beginGeneration()
        let secondAnswer = memo.root(of: checkout)
        XCTAssertTrue(secondAnswer == firstAnswer, "the provisional answer changed while the path was still missing")
        XCTAssertEqual(memo.probeCount, afterFirst,
                       "a still-missing directory cost \(memo.probeCount - afterFirst) fresh derivation(s)")

        // The CLI makes the checkout. The next rebuild derives again, and settles.
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        memo.beginGeneration()
        let settled = memo.root(of: checkout)
        XCTAssertGreaterThan(memo.probeCount, afterFirst,
                            "the directory appeared and the memo kept its provisional answer")
        XCTAssertTrue(settled == CanonicalPath.string(checkout) || settled == firstAnswer,
                      "the settled answer is neither the checkout nor the repository")
        let afterSettling = memo.probeCount
        memo.beginGeneration()
        _ = memo.root(of: checkout)
        XCTAssertEqual(memo.probeCount, afterSettling, "a settled answer was derived again")
    }

    /// A rebuild asks the filesystem **once per distinct missing path**, not once per row.
    ///
    /// The gate that keeps a missing directory from being re-derived is a `stat`, and a `stat` per
    /// row per rebuild on the main actor is the cost `PathMemo` exists to remove: a project the user
    /// worked in has several channels, and `root(of:)` is asked once for each of them. Counted under
    /// its own counter for exactly this clause — a cost no test can see is a cost that grows.
    func testAMissingProjectIsStattedOncePerRebuildAndNotOncePerRow() throws {
        let tree = try TempTree()
        let missing = tree.root.appending(path: "vanished/checkout", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path),
                       "the fixture path exists, so nothing here is missing")
        let rows = [Self.row("1", cwd: missing), Self.row("2", cwd: missing), Self.row("3", cwd: missing)]
        let memo = PathMemo()

        _ = ProjectGrouping().sections(from: rows, paths: memo)
        let afterFirst = memo.existenceCheckCount
        _ = ProjectGrouping().sections(from: rows, paths: memo)
        let added = memo.existenceCheckCount - afterFirst

        // One root and one repository question for the one distinct path, whatever the row count.
        XCTAssertLessThanOrEqual(added, 2,
                                 "a rebuild over three rows of one missing project cost \(added) existence checks")
        XCTAssertGreaterThan(added, 0, "the gate is not being asked at all, so this measures nothing")
    }

    /// **Two questions about one path are two questions**, so a generation that asks both pays one
    /// existence check for each.
    ///
    /// The memo's per-rebuild gate is keyed by (question, path). Keyed by the path alone, a path both
    /// questions were asked about would make the second skip its own stat and answer from a
    /// provisional value that a directory appearing would never refresh.
    ///
    /// **That collision is not reachable today, and the keying is not what prevents it.** The two
    /// lookups are keyed by strings that differ: `root(of:)` uses `cwd.path`, which carries a
    /// trailing slash for a directory URL, and `repository(of:)` is handed the canonical string,
    /// which does not. So the fix is the correct keying rather than a repair of an observed break,
    /// and what this holds is the keying itself — see tracker 455 for the trailing slash the two
    /// currently rely on.
    func testAGenerationAsksEachQuestionAboutAPathOnce() throws {
        let tree = try TempTree()
        let missing = tree.root.appending(path: "vanished/checkout", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path),
                       "the fixture path exists, so nothing here is missing")

        let memo = PathMemo()
        memo.beginGeneration()
        let root = memo.root(of: missing)
        _ = memo.repository(of: root)

        memo.beginGeneration()
        let before = memo.existenceCheckCount
        _ = memo.root(of: missing)
        _ = memo.repository(of: root)
        XCTAssertEqual(memo.existenceCheckCount - before, 2,
                       "a generation asking both questions paid "
                       + "\(memo.existenceCheckCount - before) existence check(s), not one each")

        // And asking the same question twice in one generation pays nothing more.
        _ = memo.root(of: missing)
        _ = memo.repository(of: root)
        XCTAssertEqual(memo.existenceCheckCount - before, 2,
                       "a repeated question in one generation paid a second check")
    }

    // MARK: - Ordering

    /// Pinned first; then the user's own `sectionOrder`; then `.claude.json`'s order; then most
    /// recent activity. Each rung is asserted by a section that would sort differently without it.
    func testPinnedFirstThenUserOrderThenTheProjectsMapThenActivity() throws {
        let tree = try TempTree()
        let alpha = try tree.directory("repo-alpha")
        let beta = try tree.directory("repo-beta")
        let gamma = try tree.directory("repo-gamma")
        let delta = try tree.directory("repo-delta")
        let now = Date()

        // gamma is pinned; beta is first in the user's order; alpha is first in .claude.json;
        // delta is in neither list and is the most recently active of the remainder.
        let rows = [
            Self.row("1", cwd: alpha, mtime: now.addingTimeInterval(-400)),
            Self.row("2", cwd: beta, mtime: now.addingTimeInterval(-300)),
            Self.row("3", cwd: gamma, mtime: now.addingTimeInterval(-200)),
            Self.row("4", cwd: delta, mtime: now.addingTimeInterval(-100)),
        ]
        let grouping = ProjectGrouping(
            projectOrder: [CanonicalPath.string(alpha), CanonicalPath.string(beta)],
            grouping: SidebarGrouping(pinned: [Self.session("3")],
                                      sectionOrder: [CanonicalPath.string(beta)]))

        let sections = grouping.sections(from: rows, paths: PathMemo())
        XCTAssertEqual(sections.count, 4, "grouping produced \(sections.count) sections, not four")
        XCTAssertEqual(sections.map(\.title), ["repo-gamma", "repo-beta", "repo-alpha", "repo-delta"])
        XCTAssertTrue(sections[0].isPinned)
        XCTAssertFalse(sections[1].isPinned, "a section with no pinned row reported itself pinned")
    }

    /// With no order given at all, sections fall back to most recent activity first.
    func testWithNoOrderAtAllSectionsSortByActivity() throws {
        let tree = try TempTree()
        let older = try tree.directory("repo-older")
        let newer = try tree.directory("repo-newer")
        let now = Date()
        let rows = [Self.row("1", cwd: older, mtime: now.addingTimeInterval(-9000)),
                    Self.row("2", cwd: newer, mtime: now.addingTimeInterval(-10))]

        let sections = ProjectGrouping().sections(from: rows, paths: PathMemo())
        XCTAssertEqual(sections.map(\.title), ["repo-newer", "repo-older"])
    }

    // MARK: - The thirty-day split

    /// A channel inside the window sits in its project section; one outside it with nothing live
    /// behind it sits under Archived; and a `ChannelState` pulls an old one back into its section,
    /// because a channel with a process behind it is not archived whatever its mtime says.
    func testTheThirtyDaySplitAndWhatALiveStateDoesToIt() async throws {
        let tree = try TempTree()
        let project = try tree.directory("repo-alpha")
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let now = Date()
        let fresh = SidebarFixtures.session("1")
        let stale = SidebarFixtures.session("2")
        let staleButLive = SidebarFixtures.session("3")

        let model = FleetBrowserModel(lifecycle: LifecycleDouble(), configHome: home, now: { now })
        model.apply(SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(fresh, configHome: home, cwd: project.path, mtime: now.addingTimeInterval(-3600)),
            SidebarFixtures.entry(stale, configHome: home, cwd: project.path,
                                  mtime: now.addingTimeInterval(-(ChannelRegistrar.recencyWindow + 3600))),
            SidebarFixtures.entry(staleButLive, configHome: home, cwd: project.path,
                                  mtime: now.addingTimeInterval(-(ChannelRegistrar.recencyWindow + 3600))),
        ]))

        XCTAssertEqual(model.allRows.count, 3, "the model painted \(model.allRows.count) rows, not three")
        XCTAssertEqual(Set(model.archived.map(\.id)), Set([stale, staleButLive]))
        XCTAssertEqual(Set(model.sections.flatMap(\.allRows).map(\.id)), Set([fresh]))

        model.apply(SidebarFixtures.state(ChannelKey(configHome: home, session: staleButLive),
                                          origin: .owned(.ready)))
        XCTAssertEqual(Set(model.archived.map(\.id)), Set([stale]),
                       "a channel with a live ChannelState stayed under Archived")
        XCTAssertEqual(Set(model.sections.flatMap(\.allRows).map(\.id)), Set([fresh, staleButLive]))
    }

    /// A listed row whose transcript named no working directory has no project to sit under, so it
    /// renders archived — which is also the registration path's answer for it.
    func testARowWithNoWorkingDirectoryRendersArchived() throws {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        let homeless = SidebarFixtures.session("4")
        let placed = SidebarFixtures.session("5")
        let now = Date()
        let model = FleetBrowserModel(lifecycle: LifecycleDouble(), configHome: home, now: { now })
        model.apply(SidebarFixtures.snapshot(configHome: home, entries: [
            SidebarFixtures.entry(homeless, configHome: home, cwd: nil, mtime: now),
            SidebarFixtures.entry(placed, configHome: home, cwd: "/invented/project-alpha", mtime: now),
        ]))

        XCTAssertEqual(model.archived.map(\.id), [homeless])
        XCTAssertEqual(model.sections.flatMap(\.allRows).map(\.id), [placed])
        XCTAssertEqual(model.listedWithoutCWD, 1)
    }

    // MARK: - Support

    static func session(_ nibble: String) -> SessionID { SidebarFixtures.session(nibble) }

    static func row(_ nibble: String, cwd: URL, mtime: Date = Date()) -> ChannelRow {
        let home = URL(fileURLWithPath: "/invented/config-home", isDirectory: true)
        return ChannelRegistrar.row(for: SidebarFixtures.entry(session(nibble), configHome: home,
                                                               cwd: cwd.path, mtime: mtime),
                                    configHome: home, mode: .ownedCandidate, rule: "default", now: Date())
    }

    static func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }
}
