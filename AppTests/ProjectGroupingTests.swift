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

        let order = ClaudeProjects.order(configHome: home.root)
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

        let order = ClaudeProjects.order(configHome: home.root)
        XCTAssertEqual(order, ["/invented/repo-alpha", "/invented/repo-beta"])
        XCTAssertFalse(order.contains("mcpServers"))
        XCTAssertFalse(order.contains("invented-tip"))
    }

    /// The launch-path cost guard.
    ///
    /// Not a threshold this is expected to approach: the scan reads this document in about ten
    /// milliseconds, write included. The bound is 250 ms, which leaves the passing path a factor of
    /// twenty-five and still fails the shape this replaced by a factor of six — that one measured
    /// 1,537 ms here and 2,080 ms on the reviewer's machine. An earlier draft used one second, which
    /// was safe against false failures but left only 1.5x against the pre-fix code, close enough
    /// that a faster machine could have slipped under it and quietly stopped discriminating.
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
        let order = ClaudeProjects.order(configHome: home.root)
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(order.count, projectCount)
        XCTAssertEqual(order.first, "/invented/repo-0")
        XCTAssertEqual(order.last, "/invented/repo-\(projectCount - 1)")
        XCTAssertLessThan(elapsed, .milliseconds(250),
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
