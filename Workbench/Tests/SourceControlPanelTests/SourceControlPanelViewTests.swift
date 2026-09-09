// SourceControlPanelTests: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// Plan T7. Spec Design §4 (the rendering contract), §6 (the detail and its two exclusions),
// §8 (the GitHub rows and the empty states), §11 (views that hold nothing), and gate G4 read at
// the view layer.
//
// **What a SwiftUI body renders is not a value a test can read**, so nothing here tries. Every
// surface these views draw is built from a pure function of the readout — the draw list the
// `Canvas` executes, the presentation of a notice, the badge a `ChecksState` becomes, the control
// a row offers — and the body does nothing but execute what those functions return. The
// assertions are therefore on the values the user's screen is made of, which is as close to
// "what is rendered" as this device gets, and each of them can fail (§17.7).
//
// §6.3/§11 hold over every line: an assertion names a subject a fixture authored, a lane, a
// segment, a count or a message written in this target's own sources — never a path, an
// environment, an author of this machine's, or a byte a tool printed.
import CoreGraphics
import Foundation
import XCTest
import AfleetCore
import LinkRouting
import PanelHostAPI
import SourceControlCore
@testable import SourceControlPanel

@MainActor
final class SourceControlPanelViewTests: XCTestCase {

    // MARK: - the harness

    private static let metrics = GraphMetrics()

    /// Invented, and the same branch `Samples/` is authored against.
    private static let branch = "feature/scope-control"

    /// `nonisolated` deliberately: handing a `GitRepository` to a main-actor method merges it into
    /// the main actor's region, after which every later `await repository.run(…)` is a send the
    /// compiler rejects.
    private nonisolated static func environment(_ repository: GitRepository) -> ResolvedEnvironment {
        ResolvedEnvironment(variables: repository.environment, shell: "/bin/zsh",
                            capturedAt: Date(timeIntervalSince1970: 1_614_800_000),
                            mode: .processFallback)
    }

    private func model(root: URL, environment: ResolvedEnvironment,
                       links: (any LinkRouterCapability)? = nil) -> SourceControlModel {
        SourceControlModel(cwd: root, environment: environment, runner: RecordingRunner(),
                           links: links, windowLimit: GitLog.defaultLimit,
                           watchesForChanges: false)
    }

    private func activatedModel(_ repository: GitRepository) async -> SourceControlModel {
        let model = model(root: repository.root, environment: Self.environment(repository))
        await model.activate()
        return model
    }

    /// `one` ← `two` on `main`, `feature` branching off `one`, and a `--no-ff` merge: the shape
    /// whose row `two` takes two edges back into one lane.
    private func mergeRepository(_ tree: ScratchTree) async throws -> GitRepository {
        let repository = try await GitRepository(tree, name: "merge")
        try await repository.commit("one", files: ["a.txt": "1"])
        try await repository.branch("feature")
        try await repository.commit("two", files: ["a.txt": "2"])
        try await repository.checkout("feature")
        try await repository.commit("side", files: ["b.txt": "1"])
        try await repository.checkout("main")
        _ = try await repository.merge(["feature"], message: "merge feature")
        return repository
    }

    /// A row built here rather than read from a repository, for the two properties a fixture
    /// cannot be relied on to produce on demand: a **truncated** edge, and two edges arriving in
    /// one lane beside a third leaving it.
    private func row(_ content: GraphRow.Content, lane: Int,
                     _ edges: [(Int, Int, Bool)]) -> SourceControlReadout.Row {
        SourceControlReadout.Row(
            content: content, lane: lane,
            edges: edges.map { GraphRow.Edge(fromLane: $0.0, toLane: $0.1, truncated: $0.2) },
            badges: [], isSelected: false)
    }

    private static let inventedCommit = GitCommit(
        hash: "1f0c3a9d5b7e2c4a6d8f0b1e3c5a7d9f2b4c6e80", parents: [], refs: [],
        authorName: GitRepository.authorName,
        authorTimestamp: Date(timeIntervalSince1970: 1_614_800_000), subject: "a row of its own")

    private func segments(_ ops: [GraphColumn.DrawOp]) -> [GraphSegment] {
        ops.compactMap { op -> GraphSegment? in
            if case .segment(let segment) = op { return segment }
            return nil
        }
    }

    private func dots(_ ops: [GraphColumn.DrawOp]) -> [GraphColumn.DrawOp] {
        ops.filter { op in
            if case .dot = op { return true }
            return false
        }
    }

    // MARK: - 1. the draw list (Design §4)

    /// The `Canvas` strokes exactly what `GraphGeometry` returns, in the order it returns it.
    ///
    /// Over a real merge, so the sequence under test is one an assignment actually produced. The
    /// list is compared **element for element and in order**: a column that gathered its segments
    /// into a set, or into a dictionary keyed by lane, satisfies a count and fails this.
    func testTheDrawListStrokesEverySegmentGeometryReturnsInOrder() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await activatedModel(try await mergeRepository(tree)).readout
        XCTAssertEqual(readout.rows.count, 4, "the merge fixture draws four rows")

        for (index, row) in readout.rows.enumerated() {
            let predecessor = index == 0 ? nil : readout.rows[index - 1]
            let isLastRow = index == readout.rows.count - 1
            let expected = GraphGeometry.segments(
                for: GraphRow(content: row.content, lane: row.lane, edges: row.edges),
                predecessor: predecessor.map {
                    GraphRow(content: $0.content, lane: $0.lane, edges: $0.edges)
                },
                isLastRow: isLastRow, metrics: Self.metrics)
            let drawn = segments(GraphColumn.drawList(row: row, predecessor: predecessor,
                                                      isLastRow: isLastRow,
                                                      metrics: Self.metrics))
            XCTAssertEqual(drawn, expected,
                           "row \(index) strokes \(drawn.count) segments where the geometry "
                           + "returns \(expected.count), or strokes them in another order")
        }
    }

    /// Tracker 121, at the drawing layer: two edges arriving in one `toLane` are both stroked.
    ///
    /// The row is authored rather than read, so the case is exact: two edges converge on lane 0
    /// and a third leaves lane 0 for lane 1 — a list keyed by `toLane` holds two of the three, and
    /// one keyed by `fromLane` holds two others.
    func testTwoEdgesArrivingInOneLaneAreBothStroked() {
        let subject = row(.commit(Self.inventedCommit), lane: 0,
                          [(0, 0, false), (1, 0, false), (0, 1, false)])
        let drawn = segments(GraphColumn.drawList(row: subject, predecessor: nil, isLastRow: false,
                                                  metrics: Self.metrics))

        XCTAssertEqual(drawn.map { "\($0.fromLane)->\($0.toLane)" }, ["0->0", "1->0", "0->1"],
                       "a draw list keyed by a lane drops one of these three")
        XCTAssertEqual(drawn.filter { $0.toLane == 0 }.count, 2,
                       "both lines converging on lane 0 are stroked")
        XCTAssertEqual(Set(drawn.map(\.start)).count, 2,
                       "the two arrivals start at different lane centres")
    }

    /// The same clause across the row boundary: the **upper** halves of a predecessor whose edges
    /// converge are both stroked by the row below.
    func testBothUpperHalvesOfAConvergingPredecessorAreStroked() {
        let predecessor = row(.commit(Self.inventedCommit), lane: 0,
                              [(0, 0, false), (1, 0, false)])
        let subject = row(.commit(Self.inventedCommit), lane: 0, [(0, 0, false)])
        let drawn = segments(GraphColumn.drawList(row: subject, predecessor: predecessor,
                                                  isLastRow: false, metrics: Self.metrics))

        XCTAssertEqual(drawn.filter { $0.half == .upper }.count, 2,
                       "the row below strokes an upper half for each of its predecessor's edges")
        XCTAssertEqual(drawn.map(\.half), [.upper, .upper, .lower],
                       "the upper halves are stroked before the lower, so a row draws top to "
                       + "bottom")
    }

    /// Tracker 119, at the drawing layer: a truncated edge is stroked exactly like any other and
    /// **no terminator is added**.
    ///
    /// The comparison is against the same row with the flag cleared: same endpoints, same op
    /// count. A column that capped a truncated line — a dot at its end, a shorter stroke — differs
    /// in one of the two.
    func testATruncatedEdgeIsStrokedLikeAnyOtherAndCarriesNoTerminator() {
        let truncated = row(.commit(Self.inventedCommit), lane: 0, [(0, 0, true)])
        let plain = row(.commit(Self.inventedCommit), lane: 0, [(0, 0, false)])
        let truncatedOps = GraphColumn.drawList(row: truncated, predecessor: nil, isLastRow: false,
                                                metrics: Self.metrics)
        let plainOps = GraphColumn.drawList(row: plain, predecessor: nil, isLastRow: false,
                                            metrics: Self.metrics)

        XCTAssertEqual(truncatedOps.count, plainOps.count,
                       "a truncated edge added \(truncatedOps.count - plainOps.count) drawing "
                       + "operations; `truncated` means the line continues, not that it ends")
        XCTAssertEqual(dots(truncatedOps).count, 1,
                       "the only dot a row draws is its own; a truncated edge earns no second one")
        let truncatedSegment = try? XCTUnwrap(segments(truncatedOps).first)
        let plainSegment = try? XCTUnwrap(segments(plainOps).first)
        XCTAssertEqual(truncatedSegment?.start, plainSegment?.start)
        XCTAssertEqual(truncatedSegment?.end, plainSegment?.end,
                       "a truncated line stops short of the row's bottom edge")
        XCTAssertEqual(truncatedSegment.map { Double($0.end.y) }, Self.metrics.rowHeight,
                       "a lower half runs to the row's bottom edge")
        XCTAssertEqual(truncatedSegment?.truncated, true,
                       "the flag reaches the stroke, so a column may tint it")
    }

    /// The one visual difference the contract does draw, and it is about the row's position rather
    /// than about `truncated`: the last row of the window has no row below to take its upper
    /// halves.
    func testTheLastRowsEdgesRunOffTheEnd() {
        let subject = row(.commit(Self.inventedCommit), lane: 0, [(0, 0, false)])
        let last = segments(GraphColumn.drawList(row: subject, predecessor: nil, isLastRow: true,
                                                 metrics: Self.metrics))
        let middle = segments(GraphColumn.drawList(row: subject, predecessor: nil, isLastRow: false,
                                                   metrics: Self.metrics))

        XCTAssertEqual(last.map(\.runsOffEnd), [true])
        XCTAssertEqual(middle.map(\.runsOffEnd), [false])
    }

    /// The dot is drawn last — over the lines, not under them — and sits in the row's own lane.
    /// The working tree's row is marked, because it is the one row that is not a commit.
    func testTheDotIsStrokedLastInTheRowsOwnLane() {
        let commitRow = row(.commit(Self.inventedCommit), lane: 2, [(2, 2, false)])
        let ops = GraphColumn.drawList(row: commitRow, predecessor: nil, isLastRow: false,
                                       metrics: Self.metrics)
        guard case .dot(let centre, let lane, let isWorkingTree) = try? XCTUnwrap(ops.last) else {
            return XCTFail("the last operation a row draws is its dot")
        }
        XCTAssertEqual(lane, 2)
        XCTAssertFalse(isWorkingTree)
        XCTAssertEqual(centre, GraphGeometry.dot(for: GraphRow(content: commitRow.content,
                                                               lane: commitRow.lane,
                                                               edges: commitRow.edges),
                                                 metrics: Self.metrics))

        let treeRow = row(.workingTree, lane: 0, [(0, 0, false)])
        let treeOps = GraphColumn.drawList(row: treeRow, predecessor: nil, isLastRow: false,
                                           metrics: Self.metrics)
        guard case .dot(_, _, let marked) = try? XCTUnwrap(treeOps.last) else {
            return XCTFail("the working tree's row draws a dot too")
        }
        XCTAssertTrue(marked, "the working tree's row is drawn as the one row that is not a commit")
    }

    /// The gutter the column reserves is the assignment's, for the lane count the readout carries.
    func testTheColumnsWidthIsTheGeometrysForTheReadoutsLaneCount() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await activatedModel(try await mergeRepository(tree)).readout

        XCTAssertEqual(GraphColumn.width(for: readout, metrics: Self.metrics),
                       GraphGeometry.width(laneCount: readout.laneCount, metrics: Self.metrics))
        XCTAssertGreaterThan(GraphColumn.width(for: readout, metrics: Self.metrics),
                             GraphGeometry.width(laneCount: 1, metrics: Self.metrics),
                             "the merge fixture's gutter is wider than a single lane's")
    }

    // MARK: - 2. the detail pane's rows (Design §6)

    /// A repository carrying every file kind the detail pane has a row for.
    private func detailRepository(_ tree: ScratchTree) async throws -> GitRepository {
        let inner = try await GitRepository(tree, name: "inner")
        try await inner.commit("the submodule's own commit", files: ["inner.txt": "inner\n"])
        let repository = try await GitRepository(tree, name: "detail")
        try await repository.commit("the first commit",
                                    files: ["README.md": "loom\n", "src/one.txt": "one\n",
                                            "src/gone.txt": "gone\n"])
        try repository.write("assets/blob.bin", bytes: Data([0x00, 0x01, 0x02, 0x00, 0xff]))
        try await repository.commit("a binary file")
        try await repository.addSubmodule(inner, at: "vendor/inner")
        // The working tree now carries one of each: a modification, an add, a delete, a rename,
        // a binary whose bytes changed and a gitlink that names another commit.
        try await repository.commitInsideSubmodule(at: "vendor/inner", files: ["more.txt": "more\n"])
        try repository.write("assets/blob.bin", bytes: Data([0x00, 0x09, 0x09, 0x00, 0x01]))
        try repository.write("README.md", "loom, edited\n")
        try repository.write("src/added.txt", "added\n")
        // Staged, because `git diff HEAD` — which is what the working tree's list is, and not
        // `status` (Design §6) — reports what the tree has that `HEAD` does not, and an untracked
        // file is in neither side of that comparison.
        try await repository.run(["add", "src/added.txt"])
        try repository.remove("src/gone.txt")
        try await repository.rename("src/one.txt", to: "src/renamed.txt")
        return repository
    }

    /// The parent rows a selected commit shows are that commit's parents, and each is offered as a
    /// row the user can select.
    func testTheDetailPanesParentRowsAreTheSelectedCommitsParents() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await mergeRepository(tree)
        let model = await activatedModel(repository)
        let merge = try XCTUnwrap(model.readout.rows.first { $0.commit?.subject == "merge feature" },
                                  "the merge fixture's own merge commit is not on screen")
        await model.select(commit: try XCTUnwrap(merge.commit?.hash))

        guard case .commit(let detail) = try XCTUnwrap(model.readout.detail) else {
            return XCTFail("selecting a commit shows a commit's detail")
        }
        let pane = SourceControlPanelView.detailPresentation(for: .commit(detail))
        XCTAssertEqual(pane.hash, detail.hash, "the pane shows the full hash")
        XCTAssertEqual(pane.abbreviatedHash, String(detail.hash.prefix(8)))
        XCTAssertEqual(pane.authorName, GitRepository.authorName)
        XCTAssertNotNil(pane.authorDate)
        XCTAssertEqual(pane.subject, "merge feature")
        XCTAssertEqual(pane.parents.map(\.hash), detail.parents,
                       "the parent rows are the commit's own parents, in its own order")
        XCTAssertEqual(pane.parents.count, 2, "a merge commit has two parents")
        XCTAssertEqual(pane.parents.map(\.abbreviated),
                       detail.parents.map { String($0.prefix(8)) })
        for parent in pane.parents {
            XCTAssertEqual(SourceControlPanelView.control(forParent: parent.hash).action,
                           .selectParentCommit,
                           "a parent row is selectable, which is a navigation and not a checkout")
        }
    }

    /// Each changed-file row carries its status, its kind, its counts and whether it offers a
    /// diff — asserted by content over a corpus with one of each shape.
    func testEachChangedFileRowCarriesItsStatusKindCountsAndWhetherItOffersADiff() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let model = await activatedModel(try await detailRepository(tree))
        await model.selectWorkingTree()
        let detail = try XCTUnwrap(model.readout.detail)
        let rows = SourceControlPanelView.detailPresentation(for: detail).files
        func file(_ path: String) throws -> SourceControlPanelView.FileRowPresentation {
            try XCTUnwrap(rows.first { $0.path == path },
                          "the working tree's list has no row for the fixture's \(path); it "
                          + "lists \(rows.map(\.path).sorted().joined(separator: ", "))")
        }

        let modified = try file("README.md")
        XCTAssertEqual(modified.statusLabel, "Modified")
        XCTAssertEqual(modified.statusGlyph, "M")
        XCTAssertEqual(modified.kindLabel, nil, "an ordinary file's kind is not called out")
        XCTAssertEqual(modified.additions, "+1")
        XCTAssertEqual(modified.deletions, "−1")
        XCTAssertTrue(modified.opensADiff)
        XCTAssertNil(modified.exclusionReason)

        let added = try file("src/added.txt")
        XCTAssertEqual(added.statusLabel, "Added")
        XCTAssertEqual(added.statusGlyph, "A")
        XCTAssertEqual(added.additions, "+1")
        XCTAssertTrue(added.opensADiff)

        let deleted = try file("src/gone.txt")
        XCTAssertEqual(deleted.statusLabel, "Deleted")
        XCTAssertEqual(deleted.statusGlyph, "D")
        XCTAssertEqual(deleted.deletions, "−1")
        XCTAssertTrue(deleted.opensADiff)

        let renamed = try file("src/renamed.txt")
        XCTAssertEqual(renamed.statusGlyph, "R")
        XCTAssertTrue(renamed.statusLabel.hasPrefix("Renamed"),
                      "a rename says so and names the side it came from")
        XCTAssertTrue(renamed.statusLabel.contains("src/one.txt"),
                      "a rename's row names the old path, which is the side the link does not "
                      + "carry")
        XCTAssertTrue(renamed.opensADiff)
    }

    /// The two kinds the pane offers no diff for, and the reason each row carries instead
    /// (Design §6). A row with a reason offers **no control at all**, which is what a link that
    /// resolved to nothing would have cost.
    func testAGitlinkRowAndABinaryRowOfferNoDiffAndCarryTheStatedReason() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let model = await activatedModel(try await detailRepository(tree))
        await model.selectWorkingTree()
        let rows = SourceControlPanelView
            .detailPresentation(for: try XCTUnwrap(model.readout.detail)).files

        let gitlink = try XCTUnwrap(rows.first { $0.kindLabel == "Submodule" },
                                    "the working tree's list carries no submodule row")
        XCTAssertFalse(gitlink.opensADiff)
        XCTAssertEqual(gitlink.exclusionReason, SourceControlReadout.submoduleReason)
        XCTAssertNil(SourceControlPanelView.control(for: gitlink),
                     "a submodule row offers no control, so there is nothing to click")

        let binary = try XCTUnwrap(rows.first { $0.isBinary },
                                   "the working tree's list carries no binary row")
        XCTAssertFalse(binary.opensADiff)
        XCTAssertEqual(binary.exclusionReason, SourceControlReadout.binaryReason)
        XCTAssertEqual(binary.additions, "—", "git counted no lines in a binary file")
        XCTAssertEqual(binary.deletions, "—")
        XCTAssertNil(SourceControlPanelView.control(for: binary))

        // And a row that is neither still offers one, so the exclusion is discriminating rather
        // than a pane that never opens anything.
        let plain = try XCTUnwrap(rows.first { $0.opensADiff })
        XCTAssertEqual(SourceControlPanelView.control(for: plain)?.action, .openFileDiff)
    }

    // MARK: - 3. the GitHub rows (Design §8)

    private func gitHubRepository(_ tree: ScratchTree) async throws -> GitRepository {
        let repository = try await GitRepository(tree, name: "github")
        try await repository.commit("the first commit", files: ["README.md": "loom\n"])
        try await repository.branch(Self.branch)
        try await repository.checkout(Self.branch)
        return repository
    }

    private func gitHubModel(cwd: URL, environment: [String: String],
                             gh script: [(String, StubRunner.Answer)]) -> GitHubModel {
        GitHubModel(cwd: cwd, environment: environment,
                    runner: ViewTestSplitRunner(git: RecordingRunner(), gh: StubRunner(script)),
                    links: nil)
    }

    /// `notRead` renders as *not read* and never as a rollup — the state that exists so a row
    /// cannot show "passing" for checks nobody asked about.
    ///
    /// Driven through a real read: *All open* reads checks for the selected pull request only, so
    /// the unselected rows are the panel's own `notRead` rather than a value invented here.
    func testAPullRequestRowWhoseChecksWereNotReadNeverRendersARollup() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await gitHubRepository(tree)
        let model = gitHubModel(cwd: repository.root, environment: repository.environment,
                                gh: [("pr list --state open --limit",
                                      .document(try GhSamples.data("all-open-pull-requests"))),
                                     ("pr checks", .document(try GhSamples.data("checks-passing"))),
                                     ("issue list", .document(try GhSamples.data("issues")))])
        await model.appear()
        await model.select(scope: .allOpen)

        let rows = model.readout.pullRequests
        XCTAssertEqual(rows.count, 3, "the authored all-open document lists three pull requests")
        for row in rows {
            let badge = GitHubPanelView.badge(for: row.checks)
            XCTAssertEqual(row.checks, .notRead)
            XCTAssertFalse(badge.isRollup,
                           "a row whose checks were never read rendered a rollup")
            XCTAssertEqual(badge.text, "Checks not read")
            XCTAssertNotEqual(badge.tone, GitHubPanelView.badge(for: .read(.passing)).tone,
                              "not read is drawn as passing")
        }
    }

    /// Each of the five rollups renders distinguishably — text and tone, pairwise distinct — and
    /// none of them is `notRead`'s.
    func testEachOfTheFiveRollupsRendersDistinguishably() {
        let badges = CheckRollup.allCases.map { GitHubPanelView.badge(for: .read($0)) }
        XCTAssertEqual(badges.count, 5, "the rollup is five-valued and every value has a badge")
        XCTAssertEqual(Set(badges.map(\.text)).count, 5,
                       "two rollups render the same words")
        XCTAssertEqual(Set(badges.map(\.tone)).count, 5,
                       "two rollups render the same tone, so a glance cannot tell them apart")
        XCTAssertTrue(badges.allSatisfy(\.isRollup))
        for rollup in CheckRollup.allCases {
            XCTAssertEqual(GitHubPanelView.badge(for: .read(rollup)).text, rollup.label,
                           "the badge draws the words the readout carries and none of its own")
        }
        // The one distinction that matters most: no checks is not passing.
        XCTAssertNotEqual(GitHubPanelView.badge(for: .read(.none)).tone,
                          GitHubPanelView.badge(for: .read(.passing)).tone)
        XCTAssertFalse(GitHubPanelView.badge(for: .notRead).isRollup)
    }

    /// The rows themselves, over the authored branch-scoped document: number, title, author,
    /// draft state, review decision, the rollup, and the issue section beside them.
    func testThePullRequestAndIssueRowsRenderWhatTheReadoutCarries() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await gitHubRepository(tree)
        let model = gitHubModel(cwd: repository.root, environment: repository.environment,
                                gh: [("pr list", .document(try GhSamples.data("branch-pull-requests"))),
                                     ("pr checks", .document(try GhSamples.data("checks-failing"))),
                                     ("issue list", .document(try GhSamples.data("issues")))])
        await model.appear()
        let readout = model.readout

        let rows = GitHubPanelView.pullRequestPresentations(for: readout)
        XCTAssertEqual(rows.map(\.number), [204, 207])
        XCTAssertEqual(rows.map(\.title), readout.pullRequests.map(\.title))
        XCTAssertEqual(rows.map(\.author), ["fennel-varro", rows[1].author])
        XCTAssertEqual(rows.map(\.badge.text), ["Checks failing", "Checks failing"],
                       "a branch-scoped list reads checks for every row it lists")
        XCTAssertEqual(rows.map(\.reviewDecision), readout.pullRequests.map(\.reviewDecision))
        XCTAssertEqual(rows.first(where: { $0.isDraft })?.number, 207,
                       "the authored document's draft is the one row drawn as a draft")

        let issues = GitHubPanelView.issuePresentations(for: readout)
        XCTAssertEqual(issues.map(\.number), [312, 305])
        XCTAssertEqual(issues.map(\.title), readout.issues.map(\.title))
        XCTAssertFalse(issues.contains { $0.relativeDate.isEmpty },
                       "an issue row draws when it was last updated")

        let checks = GitHubPanelView.checkPresentations(for: readout)
        XCTAssertTrue(checks.isEmpty, "nothing is selected, so no check list is drawn")
    }

    /// The check list of the **selected** pull request, in the order `gh` printed it.
    func testTheSelectedPullRequestsCheckListIsDrawnInTheOrderItWasRead() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await gitHubRepository(tree)
        let model = gitHubModel(cwd: repository.root, environment: repository.environment,
                                gh: [("pr list", .document(try GhSamples.data("branch-pull-requests"))),
                                     ("pr checks", .document(try GhSamples.data("checks-failing"))),
                                     ("issue list", .document(try GhSamples.data("issues")))])
        await model.appear()
        await model.select(pullRequest: 204)

        let checks = GitHubPanelView.checkPresentations(for: model.readout)
        XCTAssertEqual(checks.map(\.name), model.readout.selectedChecks.map(\.name))
        XCTAssertEqual(checks.map(\.state), model.readout.selectedChecks.map(\.bucket.label))
        XCTAssertTrue(checks.contains { $0.state == "Failed" },
                      "the authored failing document has a failed check in it")
        XCTAssertTrue(checks.allSatisfy { !$0.name.isEmpty })
    }

    // MARK: - 4. every empty and error state (Design §8, root spec §10)

    /// The three the gate names, each read out of a model that actually reached that state, with
    /// its message, its hint and its placement.
    func testTheGitHubTabsThreeEmptyStatesRenderTheirMessageHintAndPlacement() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await gitHubRepository(tree)

        // `gh` is not there. An *install* hint, and never the login one.
        let missing = gitHubModel(cwd: repository.root, environment: repository.environment,
                                  gh: [("", .binaryNotFound)])
        await missing.appear()
        guard case .emptyState(let message, let hint) =
            GitHubPanelView.presentation(for: missing.readout) else {
            return XCTFail("a `gh` that is not there replaces the tab rather than sitting above it")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(hint, GitHubReadout.installHint)
        XCTAssertNotEqual(hint, GitHubReadout.authenticationHint,
                          "a missing binary sent the user to re-authenticate")

        // `gh` is there and not signed in. The login hint, in the words the user types.
        let loggedOut = gitHubModel(cwd: repository.root, environment: repository.environment,
                                    gh: [("", .failure(code: 1, stderr: "not logged in"))])
        await loggedOut.appear()
        guard case .emptyState(_, let loginHint) =
            GitHubPanelView.presentation(for: loggedOut.readout) else {
            return XCTFail("a logged-out `gh` replaces the tab")
        }
        XCTAssertEqual(loginHint, GitHubReadout.authenticationHint)

        // The channel's folder is in no repository at all: an empty state with no remedy, because
        // there is none this tab can offer.
        let outside = gitHubModel(cwd: tree.root, environment: repository.environment, gh: [])
        await outside.appear()
        guard case .emptyState(let outsideMessage, let outsideHint) =
            GitHubPanelView.presentation(for: outside.readout) else {
            return XCTFail("a folder in no repository replaces the tab")
        }
        XCTAssertFalse(outsideMessage.isEmpty)
        XCTAssertNil(outsideHint, "a hint was invented for a state that has no remedy")
    }

    /// Every remaining `GitHubReadout` notice, by placement, message and hint — the ones whose
    /// hint is nil included, because a view that dropped the nil case renders nothing at all for
    /// them.
    func testEveryGitHubNoticeIsPresentedAtItsOwnPlacementWithItsOwnHint() {
        let notices: [GitHubReadout.Notice] = [
            GitHubReadout.notice(for: .notARepository),
            GitHubReadout.notice(for: .toolMissing(.gh)),
            GitHubReadout.notice(for: .toolMissing(.git)),
            GitHubReadout.notice(for: .notAuthenticated),
            GitHubReadout.notice(for: .commandFailed(tool: .gh, exitCode: 1)),
            GitHubReadout.notice(for: .timedOut(tool: .gh)),
            GitHubReadout.notice(for: .unreadable(tool: .gh)),
            GitHubReadout.notice(for: .unavailable(tool: .git)),
        ].compactMap { $0 }
        XCTAssertEqual(notices.count, 8, "every failure this tab has a case for has a notice")

        for notice in notices {
            let presentation = GitHubPanelView.presentation(for: notice)
            switch (notice.placement, presentation) {
            case (.emptyState, .emptyState(let message, let hint)),
                 (.row, .banner(let message, let hint)):
                XCTAssertEqual(message, notice.message,
                               "the presented message is not the readout's")
                XCTAssertEqual(hint, notice.hint, "the presented hint is not the readout's")
            default:
                XCTFail("a notice was presented at a placement other than its own")
            }
        }
        XCTAssertTrue(notices.contains { $0.hint == nil },
                      "this corpus must include a notice with no hint at all")
        XCTAssertEqual(GitHubPanelView.presentation(for: nil as GitHubReadout.Notice?), .none,
                       "a tab with nothing to say draws no area at all")
    }

    /// The Source Control tab's own area: the empty state a folder in no repository reaches, and
    /// every notice the panel can raise, each at its placement with its hint.
    func testTheSourceControlPanelsEmptyStateAndEveryNoticeArePresentedAtTheirPlacement() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await gitHubRepository(tree)
        let outside = model(root: tree.root, environment: Self.environment(repository))
        await outside.activate()

        guard case .emptyState(let message, let hint) =
            SourceControlPanelView.presentation(for: outside.readout) else {
            return XCTFail("a folder in no repository replaces the panel rather than sitting above it")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(hint, SourceControlReadout.lookAgainHint,
                       "the empty state carries the one action that gets out of it")

        let notices: [SourceControlReadout.Notice] = [
            SourceControlReadout.notice(for: .commitNotFound(hash: String(repeating: "a", count: 40))),
            SourceControlReadout.notice(for: .ambiguousPrefix(prefix: "abcd", matches: 2)),
            SourceControlReadout.notice(for: .noRepository(hash: String(repeating: "b", count: 40))),
            SourceControlReadout.notice(for: .notReadable(hash: String(repeating: "c", count: 40),
                                                          tool: .git)),
            SourceControlReadout.notice(for: .searchInterrupted(hash: String(repeating: "d", count: 40))),
        ]
        for notice in notices {
            let presentation = SourceControlPanelView.presentation(for: notice)
            switch (notice.placement, presentation) {
            case (.emptyState, .emptyState(let message, let hint)),
                 (.row, .banner(let message, let hint)):
                XCTAssertEqual(message, notice.message)
                XCTAssertEqual(hint, notice.hint)
            default:
                XCTFail("a notice was presented at a placement other than its own")
            }
        }
        XCTAssertTrue(notices.contains { $0.hint == nil },
                      "this corpus must include a notice with no hint at all")
        XCTAssertTrue(notices.contains { $0.placement == .emptyState },
                      "this corpus must include one that replaces the panel")
        XCTAssertEqual(SourceControlPanelView.presentation(for: nil as SourceControlReadout.Notice?),
                       .none)
    }

    // MARK: - 5. G4 at the view layer (§9.2 binding)

    // MARK: - G1.4: the click, through a real registry, to the tab that owns `.diff`

    /// C7.5's Files target as far as this leaf can see it: it claims `.diff` and records what it
    /// was handed.
    ///
    /// A **recording target on a real `LinkRouter`** and not a capability double, because the
    /// double answers `open` itself and so passes whether or not a receiving target exists: a
    /// panel that withdrew `.files` a line before emitting still satisfies it, and in the app that
    /// click opens no diff. What C7.5's own target then draws is proved at C7.5 (its G3), and this
    /// leaf imports no panel.
    private func recordingDiffTarget(into received: ReceivedLinks) -> LinkTarget {
        LinkTarget(tab: .files, specificity: 60,
                   handles: { link in
                       if case .diff = link { return true }
                       return false
                   },
                   open: { link, destination in received.record(link, destination) })
    }

    /// Clicking a file in the **working tree's** list: the control the row draws is performed, and
    /// what arrives at the registered target is the working-tree diff of that path.
    func testClickingAWorkingTreeFileReachesTheDiffTargetThroughARealRouter() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await detailRepository(tree)
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let received = ReceivedLinks()
        await router.register(recordingDiffTarget(into: received))
        let session = model(root: repository.root, environment: Self.environment(repository),
                            links: TabRouterCapability(router: router))
        await session.activate()
        await session.selectWorkingTree()
        let root = try XCTUnwrap(session.state.root, "the fixture's repository did not read")
        let rows = SourceControlPanelView
            .detailPresentation(for: try XCTUnwrap(session.readout.detail)).files
        let row = try XCTUnwrap(rows.first { $0.path == "README.md" },
                                "the working tree's list has no row for the modified file")
        let control = try XCTUnwrap(SourceControlPanelView.control(for: row),
                                    "a modified file offers no diff to click")

        await control.perform(on: session)

        XCTAssertEqual(received.links.count, 1,
                       "the click reached no registered target, or reached more than one")
        XCTAssertEqual(received.links.first?.link,
                       .diff(DiffRef(repository: root, path: "README.md",
                                     base: .workingTreeAgainstHEAD)),
                       "the link that arrived is not this row's working-tree diff")
        XCTAssertEqual(received.links.first?.destination, .currentPanel)
    }

    /// Clicking a file in a **commit's** list carries that commit's base, and a Cmd-click carries
    /// its own destination — both over the same real registry (§9.4).
    func testClickingACommitsFileReachesTheDiffTargetWithThatCommitsBase() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await detailRepository(tree)
        let router = LinkRouter(externalOpener: { _ in }, diagnostic: { _ in })
        let received = ReceivedLinks()
        await router.register(recordingDiffTarget(into: received))
        let session = model(root: repository.root, environment: Self.environment(repository),
                            links: TabRouterCapability(router: router))
        await session.activate()
        let root = try XCTUnwrap(session.state.root, "the fixture's repository did not read")
        let hash = try XCTUnwrap(session.readout.rows.compactMap(\.commit)
                                    .first { $0.subject == "the first commit" }?.hash,
                                 "the fixture's own first commit is not on screen")
        await session.select(commit: hash)
        let rows = SourceControlPanelView
            .detailPresentation(for: try XCTUnwrap(session.readout.detail)).files
        let row = try XCTUnwrap(rows.first { $0.path == "README.md" },
                                "the commit's list has no row for the file it added")
        let control = try XCTUnwrap(SourceControlPanelView.control(for: row))

        await control.perform(on: session, from: .newWindow)

        XCTAssertEqual(received.links.count, 1, "the click reached no registered target")
        XCTAssertEqual(received.links.first?.link,
                       .diff(DiffRef(repository: root, path: "README.md",
                                     base: .commitAgainstParent(hash))),
                       "the link that arrived does not name the selected commit's own base")
        XCTAssertEqual(received.links.first?.destination, .newWindow,
                       "a Cmd-click asked for a window of its own and the link did not say so")
    }

    /// Every control either view offers is one of its readout's actions, and every action the
    /// readout declares is offered by some surface of the view.
    ///
    /// The assertion is on the view's **own** control surface: each control the body draws is
    /// built by one of the functions below and by no other, so this reads the same values the
    /// screen is made of rather than restating T6's inventory. Both directions can fail — a
    /// control drawn for an action the inventory does not hold, and an action declared and
    /// offered nowhere — and the second is what a `Commit` button added to the enum "for later"
    /// would trip.
    func testEveryControlTheSourceControlViewOffersIsOneOfItsReadoutsActions() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await detailRepository(tree)
        let loaded = await activatedModel(repository)
        await loaded.selectWorkingTree()
        let dirty = loaded.readout
        await loaded.select(commit: try XCTUnwrap(dirty.rows.compactMap(\.commit).first?.hash))
        let selected = loaded.readout
        let empty = model(root: tree.root, environment: Self.environment(repository))
        await empty.activate()

        var offered: Set<SourceControlReadout.Action> = []
        for readout in [dirty, selected, empty.readout] {
            let controls = SourceControlPanelView.controls(for: readout)
            for control in controls {
                XCTAssertTrue(SourceControlReadout.Action.allCases.contains(control.action),
                              "a control offers an action the readout's inventory does not hold")
            }
            offered.formUnion(controls.map(\.action))
        }
        XCTAssertEqual(offered, Set(SourceControlReadout.Action.allCases),
                       "the actions the readout declares and the ones the view offers differ: "
                       + "\(offered.symmetricDifference(Set(SourceControlReadout.Action.allCases)).map(\.rawValue).sorted())")
        XCTAssertTrue(SourceControlPanelView.controls(for: dirty)
                        .contains { $0.action == .selectWorkingTree },
                      "a dirty tree's row zero is selectable")
    }

    func testEveryControlTheGitHubViewOffersIsOneOfItsReadoutsActions() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await gitHubRepository(tree)
        let model = gitHubModel(cwd: repository.root, environment: repository.environment,
                                gh: [("pr list", .document(try GhSamples.data("branch-pull-requests"))),
                                     ("pr checks", .document(try GhSamples.data("checks-passing"))),
                                     ("issue list", .document(try GhSamples.data("issues")))])
        await model.appear()
        let listed = model.readout
        await model.select(pullRequest: 204)
        let selected = model.readout
        let outside = gitHubModel(cwd: tree.root, environment: repository.environment, gh: [])
        await outside.appear()

        var offered: Set<GitHubReadout.Action> = []
        for readout in [listed, selected, outside.readout] {
            let controls = GitHubPanelView.controls(for: readout)
            for control in controls {
                XCTAssertTrue(GitHubReadout.Action.allCases.contains(control.action),
                              "a control offers an action the readout's inventory does not hold")
            }
            offered.formUnion(controls.map(\.action))
        }
        XCTAssertEqual(offered, Set(GitHubReadout.Action.allCases),
                       "the actions the readout declares and the ones the view offers differ: "
                       + "\(offered.symmetricDifference(Set(GitHubReadout.Action.allCases)).map(\.rawValue).sorted())")
        XCTAssertEqual(GitHubPanelView.controls(for: listed).filter { $0.action == .openPullRequest }
                        .count, 2,
                       "each listed pull request offers exactly one way to open it")
    }

    // MARK: - 6. G4 at the surface itself: the one door, over the view sources (§9.2, binding)

    /// **No interactive element in either view file acts except through a `Control`.**
    ///
    /// The two tests above read `controls(for:)`, which is a *helper's* list. A `Button` written
    /// straight into a body, with no `Control` behind it, leaves both of them green while a
    /// forbidden action sits on the user's screen — and §9.2 is binding, so the gate cannot rest
    /// there. A SwiftUI body is not a value this device can read, so the surface is asserted where
    /// it is written: over the two files' own source text, reached through `#filePath`.
    ///
    /// Four things are asserted of each file, and each of them can fail:
    ///
    /// 1. every call this file makes on the session lies inside `Control.perform`;
    /// 2. every interactive element's action closure calls `perform`;
    /// 3. every `perform` this file declares takes or stores a `Control` — which is what makes 2
    ///    mean the door and not a coincidence of spelling;
    /// 4. no element outside a reader's vocabulary is named at all, and the one command-click
    ///    gesture is the pinned line that forwards its modifier's own action.
    ///
    /// It **fails when it scans nothing**: an unreadable file throws, and a file with no session
    /// call or no interactive element in it is a scan that asserted nothing and says so.
    func testNeitherViewFileActsOnTheSessionOutsideTheControlDoor() throws {
        var scanned: [(name: String, calls: Int, elements: Int)] = []
        for name in PanelViewSource.files {
            let source = try PanelViewSource.read(name)
            let door = try XCTUnwrap(source.controlDoor(),
                                     "\(name) declares no single Control.perform, so this scan has "
                                     + "no door to measure anything against")

            let calls = source.sessionCallSites()
            XCTAssertFalse(calls.isEmpty,
                           "\(name): no call on the session was found at all — the scan asserted "
                           + "nothing rather than passing")
            for site in calls where !door.body.contains(site) {
                XCTFail("\(name):\(source.line(at: site)) calls a method on the session outside "
                        + "Control.perform")
            }

            let elements = source.interactiveElements()
            XCTAssertFalse(elements.isEmpty,
                           "\(name): no interactive element was found at all — the scan asserted "
                           + "nothing rather than passing")
            for element in elements {
                guard let body = source.actionClosure(after: element.index) else {
                    XCTFail("\(name):\(source.line(at: element.index)) builds a \(element.token) "
                            + "whose action this scan could not read")
                    continue
                }
                XCTAssertTrue(body.contains("perform("),
                              "\(name):\(source.line(at: element.index)) builds a \(element.token) "
                              + "that acts without a Control")
            }

            for site in source.performDeclarations() where site != door.declaration {
                XCTAssertTrue(source.trimmedLine(at: site).contains("Control"),
                              "\(name):\(source.line(at: site)) declares a `perform` that is not "
                              + "about a Control, so an element could act through it")
            }

            for token in PanelViewSource.forbiddenElements {
                guard let first = source.occurrences(of: token).first else { continue }
                XCTFail("\(name):\(source.line(at: first)) offers `\(token)`, which no Control "
                        + "builds and no reader needs")
            }
            let gestures = source.occurrences(of: "simultaneousGesture")
            XCTAssertEqual(gestures.map(source.trimmedLine(at:)),
                           [PanelViewSource.commandClickLine],
                           "\(name) attaches a gesture this gate has not read: the only one it "
                           + "admits is the command-click that forwards its modifier's own action")

            scanned.append((name, calls.count, elements.count))
        }

        XCTAssertEqual(scanned.map(\.name), PanelViewSource.files,
                       "the gate scanned "
                       + scanned.map { "\($0.name): \($0.calls) session calls, "
                                     + "\($0.elements) interactive elements" }
                                .joined(separator: "; ")
                       + " — not both view files")
    }

}

/// One of this panel's two view files, read as text for the gate above.
///
/// Line comments are blanked **in place** rather than removed, so a sentence in a doc comment can
/// neither trip an assertion nor satisfy one while every offset — and so every line number this
/// type reports — stays the file's own. Nothing here ever puts a path in an assertion: a finding
/// names a file by its own name and a line number (§6.3, §11).
struct PanelViewSource {

    /// The files this gate is about. Both are C7.7's; no other target is read.
    static let files = ["SourceControlPanelView.swift", "GitHubPanelView.swift"]

    /// Elements a reader has no use for. Not "everything SwiftUI can do" — a list that tried to be
    /// that would be a list of what was thought of — but every element that *originates* an action
    /// or an edit and that neither view builds today, so adding one is a decision this gate makes
    /// someone take deliberately.
    static let forbiddenElements = [
        "Toggle(", "TextField(", "SecureField(", "TextEditor(", "Picker(", "DatePicker(",
        "ColorPicker(", "Stepper(", "Slider(", "Menu(", "NavigationLink(", "Link(",
        ".contextMenu", ".onTapGesture", ".onLongPressGesture", ".onSubmit", ".onKeyPress",
        ".draggable", ".dropDestination", ".onDrag", ".onDrop", ".swipeActions",
    ]

    /// The one gesture either file attaches, pinned: it forwards the action its modifier was
    /// handed, and the use sites of that modifier are interactive elements the scan checks like
    /// any other.
    static let commandClickLine =
        "content.simultaneousGesture(TapGesture().modifiers(.command).onEnded(action))"

    /// What the door is: the declaration of `Control.perform` and the byte range of its body.
    struct Door {
        let declaration: Int
        let body: Range<Int>
    }

    /// An element that originates an action, and the token the finding names it by.
    struct Element {
        let token: String
        let index: Int
    }

    let name: String
    private let characters: [Character]

    enum ScanFailure: Error, CustomStringConvertible {
        case unreadable(String)

        var description: String {
            switch self {
            case .unreadable(let name):
                return "\(name) was not readable beside this test's own sources, so G4's surface "
                     + "scan asserted nothing"
            }
        }
    }

    /// Reads `name` out of the package this test file itself lives in: the test file is at
    /// `Workbench/Tests/SourceControlPanelTests/`, and the sources three levels up at
    /// `Workbench/Sources/SourceControlPanel/`.
    static func read(_ name: String, testFile: StaticString = #filePath) throws -> PanelViewSource {
        let workbench = URL(filePath: "\(testFile)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = workbench.appending(path: "Sources/SourceControlPanel/\(name)")
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else {
            throw ScanFailure.unreadable(name)
        }
        return PanelViewSource(name: name, characters: Array(Self.blankingLineComments(raw)))
    }

    private init(name: String, characters: [Character]) {
        self.name = name
        self.characters = characters
    }

    /// Replaces every `//` tail with spaces, leaving the newlines and every offset in place.
    private static func blankingLineComments(_ raw: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        var inComment = false
        var previous: Character?
        for character in raw {
            if inComment {
                out.append(character == "\n" ? character : " ")
                if character == "\n" { inComment = false }
                previous = character
                continue
            }
            if inString {
                out.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                previous = character
                continue
            }
            if character == "\"" { inString = true; out.append(character); previous = character; continue }
            if character == "/", previous == "/" {
                out.removeLast()
                out.append("  ")
                inComment = true
                previous = character
                continue
            }
            out.append(character)
            previous = character
        }
        return out
    }

    // MARK: - reading it

    /// Every index at which `token` occurs.
    func occurrences(of token: String) -> [Int] {
        let needle = Array(token)
        guard !needle.isEmpty, characters.count >= needle.count else { return [] }
        return (0...(characters.count - needle.count)).filter { start in
            !zip(needle.indices, needle).contains { characters[start + $0.0] != $0.1 }
        }
    }

    /// The one-based line `index` falls on.
    func line(at index: Int) -> Int {
        characters[..<min(index, characters.count)].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// The whole line `index` falls on, trimmed. It is this repository's own source and never a
    /// byte a tool printed.
    func trimmedLine(at index: Int) -> String {
        var start = min(index, characters.count - 1)
        while start > 0, characters[start - 1] != "\n" { start -= 1 }
        var end = start
        while end < characters.count, characters[end] != "\n" { end += 1 }
        return String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// `Control.perform`: the one place either file is allowed to call the session.
    func controlDoor() -> Door? {
        let declarations = occurrences(of: "func perform(on session:")
        guard declarations.count == 1, let declaration = declarations.first,
              let body = bracedBody(after: declaration) else { return nil }
        return Door(declaration: declaration, body: body)
    }

    /// Every index at which this file calls a method on the session — `session.<name>(`. A
    /// property read (`session.readout`) is not one: the parenthesis is what makes it a call.
    func sessionCallSites() -> [Int] {
        occurrences(of: "session.").filter { start in
            if start > 0, Self.isIdentifier(characters[start - 1]) { return false }
            var index = start + "session.".count
            var sawName = false
            while index < characters.count, Self.isIdentifier(characters[index]) {
                sawName = true
                index += 1
            }
            guard sawName else { return false }
            while index < characters.count, characters[index] == " " { index += 1 }
            return index < characters.count && characters[index] == "("
        }
    }

    /// Every element in this file that originates an action: a `Button`, and a use of one of the
    /// command-click view modifiers.
    func interactiveElements() -> [Element] {
        let buttons = occurrences(of: "Button").filter { start in
            if start > 0, Self.isIdentifier(characters[start - 1]) { return false }
            let after = start + "Button".count
            return after >= characters.count || !Self.isIdentifier(characters[after])
        }
        return (buttons.map { Element(token: "Button", index: $0) }
                + occurrences(of: ".modifier(").map { Element(token: ".modifier", index: $0) })
            .sorted { $0.index < $1.index }
    }

    /// Every declaration of something named `perform` — a function or a stored closure.
    func performDeclarations() -> [Int] {
        (occurrences(of: "func perform") + occurrences(of: "let perform")
            + occurrences(of: "var perform")).sorted()
    }

    /// The body of the action closure an element opens, or nil when there is none within reach —
    /// which is a finding and not a pass: an element whose action this scan cannot read is one it
    /// cannot vouch for.
    func actionClosure(after index: Int) -> String? {
        var start = index
        let bound = min(characters.count, index + Self.actionReach)
        while start < bound, characters[start] != "{" { start += 1 }
        guard start < bound, let body = bracedBody(after: start - 1) else { return nil }
        return String(characters[body])
    }

    /// How far past an element's name its action closure may open. A `Button(label)` opens one on
    /// the same line and a `Button {` opens one immediately; nothing legitimate here is further.
    private static let actionReach = 200

    /// The `{ … }` that follows `index`, brace-matched, ignoring braces inside string literals.
    private func bracedBody(after index: Int) -> Range<Int>? {
        var cursor = index + 1
        while cursor < characters.count, characters[cursor] != "{" { cursor += 1 }
        guard cursor < characters.count else { return nil }
        let start = cursor + 1
        var depth = 0
        var inString = false
        var escaped = false
        while cursor < characters.count {
            let character = characters[cursor]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return start..<cursor }
            }
            cursor += 1
        }
        return nil
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

/// `git` for real and `gh` from a script, so this file's GitHub tests never touch the machine's
/// own account (§11). `GitHubModelTests` holds a private one of these; a test target's private
/// type is not shared, and duplicating four lines is cheaper than widening that file's surface.
private final class ViewTestSplitRunner: ToolRunning, @unchecked Sendable {
    private let git: any ToolRunning
    private let gh: any ToolRunning

    init(git: any ToolRunning, gh: any ToolRunning) {
        self.git = git
        self.gh = gh
    }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        try await (tool == .gh ? gh : git).run(tool, arguments: arguments, cwd: cwd,
                                               environment: environment, timeout: timeout)
    }
}
