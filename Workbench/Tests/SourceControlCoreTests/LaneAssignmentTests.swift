import Foundation
import XCTest
@testable import SourceControlCore

/// Milestone 4 — lane assignment, the core of gate G1.
///
/// Assertion style, as in `GitLogTests` and for the same reason: nothing here compares a value
/// that transitively reaches a runtime path or an environment, because `XCTAssertEqual` prints
/// both operands and every path in this suite lives under the system temporary directory, which on
/// macOS contains the machine account's hash (§6.3, §11). Lanes and edges are integers and
/// booleans; commit hashes are functions of the fixture's invented identity, invented messages and
/// fixed timestamps, and of nothing on this machine.
///
/// Every test below names **the lane of each commit it asserts**. An assertion on lane *counts*
/// alone — "at least two lanes exist" — passes for a wrong assignment, which is the composite's
/// own risk bullet and root spec §17.7's repeated failure mode. The discriminating question each
/// assertion answers is "what would this have to see in order to fail", and the answer is recorded
/// at the assertion.
///
/// The commit order every expectation below is derived from is `git log --topo-order --all`'s,
/// measured on `git` 2.55.0 against these exact four fixture shapes (transcripts in the ledger's
/// *Artifacts and Notes*). The fixtures are hermetic (D14) and their timestamps fixed, so that
/// order is deterministic rather than incidental.
final class LaneAssignmentTests: XCTestCase {

    private var tree: TempTree!

    override func setUpWithError() throws {
        tree = try TempTree()
    }

    override func tearDown() {
        tree?.remove()
        tree = nil
    }

    // MARK: - helpers

    /// The lane of the row holding `hash`, or `nil` when no row holds it.
    private func lane(of hash: String, in assignment: LaneAssignment) -> Int? {
        row(of: hash, in: assignment)?.lane
    }

    /// The row holding `hash`, or `nil` when no row holds it.
    private func row(of hash: String, in assignment: LaneAssignment) -> GraphRow? {
        assignment.rows.first {
            if case .commit(let commit) = $0.content { return commit.hash == hash }
            return false
        }
    }

    /// The edges leaving the row holding `hash`, or `[]` when no row holds it. Returning `[]`
    /// rather than failing is deliberate: an absent row then fails the *edge* assertion too,
    /// instead of the test passing because there was nothing to compare.
    private func edges(of hash: String, in assignment: LaneAssignment) -> [GraphRow.Edge] {
        row(of: hash, in: assignment)?.edges ?? []
    }

    private func edge(_ from: Int, _ to: Int, truncated: Bool = false) -> GraphRow.Edge {
        GraphRow.Edge(fromLane: from, toLane: to, truncated: truncated)
    }

    /// Every edge leaving a row must arrive somewhere on the row below: at that row's own dot, or
    /// at an edge of that row which carries the lane onward. An edge that does neither is a line
    /// drawn into empty space.
    ///
    /// Asserted over every fixture in this file rather than re-derived shape by shape, because a
    /// dangling line is wrong for every shape. This is the one property R3's F2, F3 and F4 each
    /// broke in a different way — a convergence never drawn, a pass-through replaced by a merge
    /// edge, and a working-tree edge that never reached `HEAD` — which is why they were one
    /// defect in the edge model rather than three.
    ///
    /// The final row is exempt only for `truncated` edges: there is no row below for them to land
    /// on, which is what the flag says. A *non*-truncated edge leaving the last row would be a
    /// line pointing at a row the assignment claims to have read.
    private func assertEveryEdgeLands(_ assignment: LaneAssignment,
                                      file: StaticString = #filePath, line: UInt = #line) {
        for (index, row) in assignment.rows.enumerated() {
            guard index + 1 < assignment.rows.count else {
                XCTAssertTrue(row.edges.allSatisfy(\.truncated),
                              "the last row carries an edge that is not truncated and so points "
                              + "at a row that does not exist",
                              file: file, line: line)
                continue
            }
            let below = assignment.rows[index + 1]
            for edge in row.edges {
                XCTAssertTrue(below.lane == edge.toLane
                                || below.edges.contains { $0.fromLane == edge.toLane },
                              "an edge leaving row \(index) into lane \(edge.toLane) reaches "
                              + "neither the dot nor any edge of the row below it",
                              file: file, line: line)
            }
        }
    }

    private func commits(_ fixture: GitFixture, limit: Int = GitLog.defaultLimit) async throws -> [GitCommit] {
        try await GitLog.commits(root: fixture.root, environment: fixture.environment,
                                 runner: ToolRunner(), limit: limit)
    }

    private func head(_ fixture: GitFixture) async throws -> String {
        try await fixture.run(["rev-parse", "HEAD"]).stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 1. a merge

    /// `main` and `feature` diverge by one commit each and are merged with `--no-ff`.
    ///
    /// Layout: `c1` (root) ← `c2` on `feature`, `c1` ← `c3` on `main`, and `merge` with parents
    /// `[c3, c2]` in that order (git's first parent is the branch merged *into*).
    ///
    /// Measured topological order, `git` 2.55.0: `merge`, `c2`, `c3`, `c1`. Walking the ledger's
    /// algorithm over it: `merge` opens lane 0 and reserves lane 0 for its first parent `c3` and a
    /// new lane 1 for `c2`; `c2` is read at lane 1 and its first parent `c1` inherits lane 1; `c3`
    /// is read at lane 0 and its first parent `c1` inherits lane 0, so `c1` is now reserved twice;
    /// `c1` is read at the leftmost of those, lane 0, and the extra lane 1 is released at that row.
    ///
    /// What would have to be true for this to fail: any assignment that does not give the two
    /// sides of the merge distinct lanes, or that lets the first parent drift off its child's lane
    /// — which is exactly what the "always take a free lane" mutation does, moving `c1` to lane 1
    /// and collapsing `c3`'s two outgoing edges into one.
    func testAMergeGivesEachSideItsOwnLaneAndTheMergeRowAnEdgeIntoEach() async throws {
        let fixture = try await GitFixture(tree)
        let c1 = try await fixture.commit(message: "c1 root", files: ["a.txt": "a\n"])
        try await fixture.branch("feature")
        let c2 = try await fixture.commit(message: "c2 on feature", files: ["b.txt": "b\n"])
        try await fixture.checkout("main")
        let c3 = try await fixture.commit(message: "c3 on main", files: ["c.txt": "c\n"])
        try await fixture.merge(["feature"], message: "merge feature")
        let merge = try await head(fixture)

        let history = try await commits(fixture)
        // The floor: an empty history makes every lookup below return nil and every `nil == nil`
        // comparison hold, so the shape is asserted before anything is read out of it.
        XCTAssertEqual(history.count, 4, "the fixture built a history of a different size")

        let assignment = LaneAssignment.assign(commits: history, workingTreeIsDirty: false)
        XCTAssertEqual(assignment.rows.count, 4, "one row per commit, and no working-tree row")

        XCTAssertEqual(lane(of: merge, in: assignment), 0, "the merge commit is the first tip read and holds lane 0")
        XCTAssertEqual(lane(of: c3, in: assignment), 0, "the first parent of the merge keeps the merge's lane")
        XCTAssertEqual(lane(of: c2, in: assignment), 1, "the second parent of the merge opens lane 1")
        XCTAssertEqual(lane(of: c1, in: assignment), 0, "the shared root is read at the leftmost lane reserved for it")
        XCTAssertEqual(assignment.laneCount, 2, "two lanes are the high-water mark of this graph")

        XCTAssertEqual(edges(of: merge, in: assignment),
                       [edge(0, 0), edge(0, 1)],
                       "the merge row carries one edge into each parent's lane")
        // The two parents sit in different lanes, stated as the property rather than re-read from
        // the numbers above: this is the clause G1 names.
        XCTAssertNotEqual(lane(of: c3, in: assignment), lane(of: c2, in: assignment),
                          "the two parents of a merge must not share a lane")

        // The discriminator. At `c3`'s row lane 1 is still reserved for `c1` (from `c2`'s row) and
        // lane 0 is reserved for `c1` by `c3`'s own first-parent inheritance, so the row carries a
        // straight-down edge in each. An assignment that pointed `c3`'s first parent at the
        // already-reserved lane 1 instead would carry a single crossing edge here.
        // Both edges leaving this row end at the row below, which is the shared root read in
        // lane 0: the first parent's straight-down edge, and lane 1's line bending into lane 0
        // because that is where its target sits (R3 F2, D43). An implementation that released
        // lane 1's reservation without redirecting the line into it emits `edge(1, 1)` here and
        // draws a line stopping in the empty lane beside the root.
        XCTAssertEqual(edges(of: c3, in: assignment),
                       [edge(0, 0), edge(1, 0)],
                       "lane 1's line converges into the lane the shared root is read at")
        XCTAssertEqual(edges(of: c1, in: assignment), [],
                       "the root commit is parentless, so no edge leaves its row")
        assertEveryEdgeLands(assignment)
    }

    // MARK: - 2. an octopus merge

    /// Three branches merged in one commit.
    ///
    /// Layout: `r` (root) ← `a` on `main`, `r` ← `b1` on `b1`, `r` ← `c1` ← `c2` on `b2`, and
    /// `octopus` with parents `[a, b1, c2]`.
    ///
    /// Measured topological order, `git` 2.55.0: `octopus`, `c2`, `c1`, `b1`, `a`, `r`. The
    /// algorithm gives the octopus lane 0, its first parent `a` lane 0, `b1` lane 1 and `c2`
    /// lane 2; `c1` inherits `c2`'s lane 2; `r` is reserved from lane 2 (by `c1`), lane 1 (by
    /// `b1`) and lane 0 (by `a`) in turn, is read at the leftmost of those, and releases the other
    /// two at its row.
    ///
    /// What would have to be true for this to fail: three parents not getting three lanes, or the
    /// root drifting off lane 0 — which the "always take a free lane" mutation does, reading `r`
    /// at lane 2 because the lanes to its left were released early.
    func testAnOctopusMergeOpensThreeLanesAndCarriesThreeEdges() async throws {
        let fixture = try await GitFixture(tree)
        let root = try await fixture.commit(message: "r root", files: ["r.txt": "r\n"])
        try await fixture.branch("b1")
        let b1 = try await fixture.commit(message: "b1 work", files: ["b1.txt": "b1\n"])
        try await fixture.checkout("main")
        try await fixture.branch("b2")
        let c1 = try await fixture.commit(message: "c1 work", files: ["c1.txt": "c1\n"])
        let c2 = try await fixture.commit(message: "c2 work", files: ["c2.txt": "c2\n"])
        try await fixture.checkout("main")
        let a = try await fixture.commit(message: "a on main", files: ["a.txt": "a\n"])
        try await fixture.merge(["b1", "b2"], message: "octopus merge")
        let octopus = try await head(fixture)

        let history = try await commits(fixture)
        XCTAssertEqual(history.count, 6, "the fixture built a history of a different size")
        XCTAssertEqual(history.first?.parents.count, 3, "the newest row is the three-parent merge")

        let assignment = LaneAssignment.assign(commits: history, workingTreeIsDirty: false)

        XCTAssertEqual(lane(of: octopus, in: assignment), 0, "the octopus merge is the first tip read")
        XCTAssertEqual(lane(of: a, in: assignment), 0, "the first parent keeps the merge's lane")
        XCTAssertEqual(lane(of: b1, in: assignment), 1, "the second parent opens lane 1")
        XCTAssertEqual(lane(of: c2, in: assignment), 2, "the third parent opens lane 2")
        XCTAssertEqual(lane(of: c1, in: assignment), 2, "the third parent's own first parent keeps lane 2")
        XCTAssertEqual(lane(of: root, in: assignment), 0, "the shared root is read at the leftmost lane reserved for it")
        XCTAssertEqual(assignment.laneCount, 3, "three lanes are the high-water mark of this graph")

        XCTAssertEqual(edges(of: octopus, in: assignment),
                       [edge(0, 0), edge(0, 1), edge(0, 2)],
                       "three edges leave the octopus row, one into each parent's lane")

        // The discriminator, same shape as the merge test: at `b1`'s row lane 2 already holds a
        // reservation for the root and lane 1 gets one by first-parent inheritance, so both run
        // straight down. An assignment that reused the existing reservation for the first parent
        // would close lane 1 here and shift `c1` and the root leftward.
        XCTAssertEqual(edges(of: b1, in: assignment),
                       [edge(0, 0), edge(1, 1), edge(2, 2)],
                       "lane 1 runs straight down to the root while lanes 0 and 2 pass through")
        XCTAssertEqual(edges(of: root, in: assignment), [],
                       "the root commit is parentless, so no edge leaves its row")
        // The row directly above the root is `a`, and all three lanes reserved for the root
        // converge into the lane it is read at (R3 F2, D43).
        XCTAssertEqual(edges(of: a, in: assignment),
                       [edge(0, 0), edge(1, 0), edge(2, 0)],
                       "three lanes reaching the same root all bend into the lane it is read at")
        assertEveryEdgeLands(assignment)
    }

    // MARK: - 3. a detached tag

    /// A commit on no branch, reachable only through a tag.
    ///
    /// Layout: `c1` (root) ← `detached`, which carries the tag `v9` and nothing else, and
    /// `c1` ← `c2`, which carries `main`. Measured topological order, `git` 2.55.0: `c2`,
    /// `detached`, `c1` — `c2` is the newer tip. `c2` takes lane 0 and reserves it for `c1`;
    /// `detached` finds no lane reserved for it and no free lane, so it opens lane 1, and its
    /// first parent `c1` inherits lane 1; `c1` is read at lane 0 and releases lane 1.
    ///
    /// The commit appearing at all is what `--all` buys — without it a tag-only commit is not in
    /// the window and the whole row is missing.
    func testACommitReachableOnlyThroughATagAppearsAndOpensItsOwnLane() async throws {
        let fixture = try await GitFixture(tree)
        let c1 = try await fixture.commit(message: "c1 root", files: ["a.txt": "a\n"])
        try await fixture.detach("main")
        let detached = try await fixture.commit(message: "detached work", files: ["d.txt": "d\n"])
        try await fixture.tag("v9")
        try await fixture.checkout("main")
        let c2 = try await fixture.commit(message: "c2 on main", files: ["c.txt": "c\n"])

        let history = try await commits(fixture)
        XCTAssertEqual(history.count, 3, "the tag-only commit must be in the window that --all reads")

        let assignment = LaneAssignment.assign(commits: history, workingTreeIsDirty: false)

        XCTAssertEqual(lane(of: c2, in: assignment), 0, "the branch tip is the first tip read and holds lane 0")
        XCTAssertEqual(lane(of: detached, in: assignment), 1,
                       "a commit no lane is reserved for opens its own lane beside the branch")
        XCTAssertEqual(lane(of: c1, in: assignment), 0, "the shared root is read at the leftmost lane reserved for it")
        XCTAssertEqual(assignment.laneCount, 2, "two lanes are the high-water mark of this graph")

        // The tag travels with the row: this is what makes the row identifiable in the panel as
        // something other than an unreachable commit.
        let tagNames = row(of: detached, in: assignment).map { assignedRow -> [String] in
            guard case .commit(let commit) = assignedRow.content else { return [] }
            return commit.refs.filter { $0.kind == .tag }.map(\.name)
        }
        XCTAssertEqual(tagNames, ["v9"], "the tag-only commit carries its tag into the row")

        // The discriminator: both lanes end at the shared root on the row below — lane 0's
        // pass-through and lane 1's line bending into the lane the root is read at. Under the
        // pre-R3 edge model lane 1's line was emitted as `edge(1, 1)` and ended in the empty
        // lane beside the root, which is the connection F2 named (D43). The *lane* assertions
        // above are what pin the first-parent rule here; this one pins the convergence.
        XCTAssertEqual(edges(of: detached, in: assignment),
                       [edge(0, 0), edge(1, 0)],
                       "the detached commit's lane bends into the lane the shared root is read at")
        assertEveryEdgeLands(assignment)
    }

    // MARK: - 4. a dirty working tree, both directions

    /// Row zero is the working tree when the tree is dirty and is not there when it is clean.
    ///
    /// Both directions are asserted in one test on one repository, because a row that *always*
    /// appeared would pass the first assertion alone (D6, and G1's own wording).
    func testTheWorkingTreeRowIsPresentOnlyWhenTheTreeIsDirty() async throws {
        let fixture = try await GitFixture(tree)
        let first = try await fixture.commit(message: "c1 root", files: ["a.txt": "a\n"])
        let headCommit = try await fixture.commit(message: "c2 on main", files: ["b.txt": "b\n"])

        let history = try await commits(fixture)
        XCTAssertEqual(history.count, 2, "the fixture built a history of a different size")

        // Clean first, read from the real `git status` rather than asserted by construction.
        let clean = try await WorkingTreeStatus.read(root: fixture.root,
                                                     environment: fixture.environment,
                                                     runner: ToolRunner())
        XCTAssertTrue(clean.isClean, "a freshly committed fixture must have a clean working tree")

        let cleanAssignment = LaneAssignment.assign(commits: history, workingTreeIsDirty: !clean.isClean)
        XCTAssertEqual(cleanAssignment.rows.count, 2, "a clean tree contributes no row")
        XCTAssertFalse(cleanAssignment.rows.contains { $0.content == .workingTree },
                       "no working-tree row may exist while the tree is clean")
        XCTAssertEqual(lane(of: headCommit, in: cleanAssignment), 0, "HEAD holds lane 0")
        XCTAssertEqual(lane(of: first, in: cleanAssignment), 0, "the root keeps HEAD's lane as its first parent")

        // Now dirty it, with an untracked file: no commit, no index change, just a file on disk.
        try tree.file("repo/scratch.txt", "uncommitted\n")
        let dirty = try await WorkingTreeStatus.read(root: fixture.root,
                                                     environment: fixture.environment,
                                                     runner: ToolRunner())
        XCTAssertFalse(dirty.isClean, "an untracked file must make the working tree dirty")

        let dirtyAssignment = LaneAssignment.assign(commits: history, workingTreeIsDirty: !dirty.isClean)
        XCTAssertEqual(dirtyAssignment.rows.count, 3, "the dirty tree adds exactly one row")
        XCTAssertEqual(dirtyAssignment.rows.first?.content, .workingTree, "the working tree is row zero")
        XCTAssertEqual(dirtyAssignment.rows.first?.lane, 0, "the working-tree row sits in lane 0")
        XCTAssertEqual(dirtyAssignment.rows.first?.edges, [edge(0, 0)],
                       "one edge leaves the working-tree row, into the lane HEAD's row occupies")
        XCTAssertEqual(lane(of: headCommit, in: dirtyAssignment), 0,
                       "the commit rows keep the lanes they had; the working-tree row is prepended, not woven in")
        XCTAssertEqual(lane(of: first, in: dirtyAssignment), 0, "the root keeps HEAD's lane as its first parent")
        assertEveryEdgeLands(cleanAssignment)
        assertEveryEdgeLands(dirtyAssignment)
    }

    // MARK: - 5. the window

    /// A repository with more commits than the limit: the oldest row's edge to its unread parent
    /// carries `truncated`.
    ///
    /// This is required by D5 rather than incidental: `GitLog.commits` reads a window, so a parent
    /// hash outside it is the ordinary case and not a corruption. Without the flag the panel would
    /// draw a line ending in nothing.
    func testTheOldestRowsEdgeToAnUnreadParentIsTruncated() async throws {
        let fixture = try await GitFixture(tree)
        var hashes: [String] = []
        for index in 1...5 {
            hashes.append(try await fixture.commit(message: "w\(index)", files: ["w\(index).txt": "w\(index)\n"]))
        }

        let window = try await commits(fixture, limit: 3)
        XCTAssertEqual(window.count, 3, "the window must be shorter than the history it reads")

        let assignment = LaneAssignment.assign(commits: window, workingTreeIsDirty: false)
        XCTAssertEqual(assignment.rows.count, 3, "one row per commit in the window")
        XCTAssertEqual(assignment.laneCount, 1, "a linear history occupies exactly one lane")

        // Newest first: w5, w4, w3. Each keeps lane 0 by first-parent inheritance.
        XCTAssertEqual(lane(of: hashes[4], in: assignment), 0, "the newest commit holds lane 0")
        XCTAssertEqual(lane(of: hashes[3], in: assignment), 0, "the first parent keeps lane 0")
        XCTAssertEqual(lane(of: hashes[2], in: assignment), 0, "the oldest row in the window keeps lane 0")
        XCTAssertNil(lane(of: hashes[1], in: assignment), "a commit outside the window has no row")

        XCTAssertEqual(edges(of: hashes[4], in: assignment), [edge(0, 0, truncated: false)],
                       "an edge to a parent inside the window is not truncated")
        XCTAssertEqual(edges(of: hashes[3], in: assignment), [edge(0, 0, truncated: false)],
                       "an edge to a parent inside the window is not truncated")
        XCTAssertEqual(edges(of: hashes[2], in: assignment), [edge(0, 0, truncated: true)],
                       "the oldest row's edge points at a parent the window never read")
        assertEveryEdgeLands(assignment)
    }

    // MARK: - 6. the working-tree row attaches to HEAD, not to whatever was read first

    /// A repository whose newest tip is reachable only through a tag, with `HEAD` on an older
    /// commit: the working-tree row's edge must land in **`HEAD`'s** lane.
    ///
    /// Layout: `c1` (root) ← `c2`, which carries `HEAD -> main`, and `c1` ← `detached`, which is
    /// newer than `c2` and carries only the tag `v9`.
    ///
    /// Measured topological order, `git` 2.55.0: `detached`, `c2`, `c1` — the tag-only tip is
    /// listed **before** `HEAD -> main`, which is the whole point of this fixture. So `detached`
    /// takes lane 0, `c2` finds no lane reserved for it and no free lane and opens lane 1, and
    /// `c1` is read at the leftmost lane reserved for it, lane 0, releasing lane 1.
    ///
    /// What would have to be true for this to fail: an implementation that attaches the
    /// working-tree row to `rows.first` rather than to the row carrying a `.head` ref. That is a
    /// real defect and not a stylistic one — it draws the user's uncommitted changes hanging off
    /// an unrelated branch tip. The single-branch dirty-tree test above cannot see it, because
    /// there `rows.first` *is* `HEAD`.
    func testTheWorkingTreeRowAttachesToHeadsLaneWhenANewerTagOnlyTipIsReadFirst() async throws {
        let fixture = try await GitFixture(tree)
        let c1 = try await fixture.commit(message: "c1 root", files: ["a.txt": "a\n"])
        let c2 = try await fixture.commit(message: "c2 on main", files: ["b.txt": "b\n"])
        try await fixture.detach(c1)
        let detached = try await fixture.commit(message: "detached work", files: ["d.txt": "d\n"])
        try await fixture.tag("v9")
        try await fixture.checkout("main")
        let headHash = try await head(fixture)
        XCTAssertEqual(headHash, c2, "the fixture must leave HEAD on the older tip")

        let history = try await commits(fixture)
        XCTAssertEqual(history.count, 3, "the fixture built a history of a different size")
        // The premise, asserted rather than assumed: the first row read is *not* HEAD. Without
        // this the test could pass on a repository where the two coincide.
        XCTAssertEqual(history.first?.hash, detached,
                       "the newer tag-only tip must precede HEAD in --topo-order --all (git 2.55.0)")
        XCTAssertTrue(history.first?.refs.contains { $0.kind == .head } == false,
                      "the first row read carries no HEAD ref")

        try tree.file("repo/scratch.txt", "uncommitted\n")
        let dirty = try await WorkingTreeStatus.read(root: fixture.root,
                                                     environment: fixture.environment,
                                                     runner: ToolRunner())
        XCTAssertFalse(dirty.isClean, "an untracked file must make the working tree dirty")

        let assignment = LaneAssignment.assign(commits: history, workingTreeIsDirty: !dirty.isClean)
        XCTAssertEqual(assignment.rows.count, 4, "three commits plus the working-tree row")

        // The working tree is a child of `HEAD` and reserves its own lane for it, exactly as
        // rule 3 has a commit reserve its lane for its first parent (R3 F4, D44). So `HEAD`
        // is read in lane 0 even though it is not the first row read, and the tag-only tip —
        // which finds lane 0 already reserved — opens lane 1 beside it.
        XCTAssertEqual(lane(of: c2, in: assignment), 0, "HEAD is read in the lane the working tree reserved")
        XCTAssertEqual(lane(of: detached, in: assignment), 1,
                       "the tag-only tip, read first, finds lane 0 reserved and opens lane 1")
        XCTAssertEqual(lane(of: c1, in: assignment), 0, "the shared root is read at the leftmost lane reserved for it")
        XCTAssertEqual(assignment.laneCount, 2, "two lanes are the high-water mark of this graph")

        XCTAssertEqual(assignment.rows.first?.content, .workingTree, "the working tree is row zero")
        XCTAssertEqual(assignment.rows.first?.lane, 0, "the working-tree row sits in lane 0")
        XCTAssertEqual(assignment.rows.first?.edges, [edge(0, 0)],
                       "one edge leaves the working-tree row, into the lane it reserved for HEAD")

        // The discriminator F4 named. `HEAD` is **not** the row below the working tree — the
        // tag-only tip is — so the connection only exists if the reserved lane is carried
        // through that intervening row. An implementation that prepends a single edge after
        // assignment leaves lane 0 at this row belonging to the tag-only tip's own line, and the
        // working tree's connection dangles one row down.
        XCTAssertEqual(edges(of: detached, in: assignment),
                       [edge(0, 0), edge(1, 1)],
                       "the intervening row carries the working tree's reserved lane down to HEAD")
        assertEveryEdgeLands(assignment)
    }

    // MARK: - 7. a freed lane is reused

    /// A graph where three side lanes close well above the bottom of the window, and an older
    /// independent tip is read afterwards: it must land in the **leftmost freed** lane rather than
    /// in a new one.
    ///
    /// Lane recycling is what keeps the gutter narrow on a real repository, and no other fixture
    /// in this file exercises it: in each of them a lane is only ever released by the final root
    /// commit, so no row is ever placed after a lane frees. Both of the algorithm's "leftmost free
    /// lane" clauses — rule 1's, for a commit no lane is reserved for, and rule 4's, for a merge's
    /// further parent — are reached for the first time here.
    ///
    /// Layout: `base` (root); `o1` and `o2` are two children of `base`, merged into `sideMerge`
    /// with parents `[o2, o1]`; `m1` is a third child of `base`, with four children of its own —
    /// `p1`, `p2`, `p3` and `m2` — joined by an octopus merge with parents `[m2, p1, p2, p3]`.
    /// The octopus is the newest commit and `sideMerge` is older than `m1`.
    ///
    /// Measured topological order, `git` 2.55.0: `octopus`, `p3`, `p2`, `p1`, `m2`, `m1`,
    /// `sideMerge`, `o1`, `o2`, `base`. Note that it is not date order: `git` emits the octopus's
    /// parents in reverse, and `o1` ahead of the newer `o2`. Walking the ledger's algorithm over
    /// the measured order: the octopus opens lane 0 and lanes 1, 2, 3 for its three further
    /// parents; `p3`, `p2`, `p1` and `m2` each keep their lane and hand it to `m1`; `m1` is read
    /// at the leftmost of the four lanes reserved for it and **releases the other three**, leaving
    /// only lane 0 reserved for `base`. `sideMerge` is then read with no lane reserved for it and
    /// three free — it takes the leftmost, lane 1 — and its further parent `o1` takes the leftmost
    /// of the two still free, lane 2.
    ///
    /// What would have to be true for this to fail: a commit or a further parent that appends a
    /// new lane instead of reusing a freed one (`laneCount` becomes 5), or that takes the
    /// *rightmost* free lane instead of the leftmost (`sideMerge` at lane 3, `o1` at lane 3).
    func testAFreedLaneIsReusedByALaterTipAndByAFurtherParent() async throws {
        let fixture = try await GitFixture(tree)
        let base = try await fixture.commit(message: "base root", files: ["base.txt": "base\n"])
        try await fixture.branch("old1")
        let o1 = try await fixture.commit(message: "o1 work", files: ["o1.txt": "o1\n"])
        try await fixture.branch("old2", from: base)
        let o2 = try await fixture.commit(message: "o2 work", files: ["o2.txt": "o2\n"])
        try await fixture.merge(["old1"], message: "merge old1 into old2")
        let sideMerge = try await head(fixture)
        try await fixture.checkout("main")
        let m1 = try await fixture.commit(message: "m1 on main", files: ["m1.txt": "m1\n"])
        try await fixture.branch("p1b")
        let p1 = try await fixture.commit(message: "p1 work", files: ["p1.txt": "p1\n"])
        try await fixture.checkout("main")
        try await fixture.branch("p2b")
        let p2 = try await fixture.commit(message: "p2 work", files: ["p2.txt": "p2\n"])
        try await fixture.checkout("main")
        try await fixture.branch("p3b")
        let p3 = try await fixture.commit(message: "p3 work", files: ["p3.txt": "p3\n"])
        try await fixture.checkout("main")
        let m2 = try await fixture.commit(message: "m2 on main", files: ["m2.txt": "m2\n"])
        try await fixture.merge(["p1b", "p2b", "p3b"], message: "octopus merge")
        let octopus = try await head(fixture)

        let history = try await commits(fixture)
        XCTAssertEqual(history.count, 10, "the fixture built a history of a different size")
        // The premise this fixture exists for, asserted rather than assumed: the merge whose lane
        // is under test is read *after* the row that frees the lanes.
        XCTAssertEqual(history.map(\.hash),
                       [octopus, p3, p2, p1, m2, m1, sideMerge, o1, o2, base],
                       "the measured --topo-order --all of git 2.55.0 over this shape")

        let assignment = LaneAssignment.assign(commits: history, workingTreeIsDirty: false)
        XCTAssertEqual(assignment.laneCount, 4,
                       "four lanes are the high-water mark: the freed lanes are reused, not appended to")

        XCTAssertEqual(lane(of: octopus, in: assignment), 0, "the octopus is the first tip read")
        XCTAssertEqual(lane(of: m2, in: assignment), 0, "the first parent keeps the merge's lane")
        XCTAssertEqual(lane(of: p1, in: assignment), 1, "the second parent opens lane 1")
        XCTAssertEqual(lane(of: p2, in: assignment), 2, "the third parent opens lane 2")
        XCTAssertEqual(lane(of: p3, in: assignment), 3, "the fourth parent opens lane 3")
        XCTAssertEqual(lane(of: m1, in: assignment), 0,
                       "the shared parent is read at the leftmost lane reserved for it")
        XCTAssertEqual(edges(of: m1, in: assignment), [edge(0, 0)],
                       "lanes 1, 2 and 3 are released at this row, so only lane 0 leaves it")

        // The discriminators. Lanes 1, 2 and 3 are free and lane 0 is reserved for `base`.
        XCTAssertEqual(lane(of: sideMerge, in: assignment), 1,
                       "a later tip takes the leftmost freed lane, not a new one and not the rightmost")
        XCTAssertEqual(lane(of: o2, in: assignment), 1, "the merge's first parent keeps its lane")
        XCTAssertEqual(lane(of: o1, in: assignment), 2,
                       "the further parent takes the leftmost of the lanes still free")
        XCTAssertEqual(edges(of: sideMerge, in: assignment),
                       [edge(0, 0), edge(1, 1), edge(1, 2)],
                       "lane 0 passes through to the root while the merge reaches into lanes 1 and 2")
        XCTAssertEqual(lane(of: base, in: assignment), 0, "the root is read at the leftmost lane reserved for it")
        XCTAssertEqual(edges(of: base, in: assignment), [], "the root commit is parentless")
        assertEveryEdgeLands(assignment)
    }

    // MARK: - 8. two merges naming the same further parent

    /// Two merge commits that both name the same commit as a non-first parent: the second must
    /// point at the lane already reserved for it instead of opening another.
    ///
    /// This is rule 4's "unless some lane already holds a reservation for that parent's hash"
    /// clause, which no other fixture reaches. Without it a commit merged into two branches would
    /// widen the gutter by one lane per merge and then close them all at its own row.
    ///
    /// Layout: `base` (root); `s` on `shared`, a child of `base`; `x1`, another child of `base`,
    /// merged with `shared` into `sideMerge` with parents `[x1, s]`; `m1` on `main`, a third child
    /// of `base`, merged with `shared` into `mainMerge` with parents `[m1, s]`.
    ///
    /// Measured topological order, `git` 2.55.0: `mainMerge`, `m1`, `sideMerge`, `s`, `x1`,
    /// `base`. `mainMerge` takes lane 0 and opens lane 1 for `s`; `m1` keeps lane 0 and hands it
    /// to `base`; `sideMerge` finds no lane free, opens lane 2, gives lane 2 to its first parent
    /// `x1` — and finds `s` already reserved in lane 1, so it reaches sideways into lane 1 rather
    /// than opening a lane 3.
    ///
    /// What would have to be true for this to fail: an implementation that ignored the existing
    /// reservation, which opens a fourth lane and changes `sideMerge`'s outgoing edges.
    func testASecondMergeNamingTheSameFurtherParentReusesItsReservation() async throws {
        let fixture = try await GitFixture(tree)
        let base = try await fixture.commit(message: "base root", files: ["base.txt": "base\n"])
        try await fixture.branch("shared")
        let s = try await fixture.commit(message: "s work", files: ["s.txt": "s\n"])
        try await fixture.branch("sidex", from: base)
        let x1 = try await fixture.commit(message: "x1 work", files: ["x1.txt": "x1\n"])
        try await fixture.merge(["shared"], message: "merge shared into sidex")
        let sideMerge = try await head(fixture)
        try await fixture.checkout("main")
        let m1 = try await fixture.commit(message: "m1 on main", files: ["m1.txt": "m1\n"])
        try await fixture.merge(["shared"], message: "merge shared into main")
        let mainMerge = try await head(fixture)

        let history = try await commits(fixture)
        XCTAssertEqual(history.count, 6, "the fixture built a history of a different size")
        XCTAssertEqual(history.map(\.hash), [mainMerge, m1, sideMerge, s, x1, base],
                       "the measured --topo-order --all of git 2.55.0 over this shape")
        // Both merges must genuinely name `s` second, or the clause under test is never reached.
        XCTAssertEqual(history.first?.parents, [m1, s], "the newer merge's parents, in git's order")
        XCTAssertEqual(history.first(where: { $0.hash == sideMerge })?.parents, [x1, s],
                       "the older merge names the same commit as its own further parent")

        let assignment = LaneAssignment.assign(commits: history, workingTreeIsDirty: false)
        XCTAssertEqual(assignment.laneCount, 3,
                       "the second merge reuses the reservation instead of widening the graph to four lanes")

        XCTAssertEqual(lane(of: mainMerge, in: assignment), 0, "the newest merge is the first tip read")
        XCTAssertEqual(lane(of: m1, in: assignment), 0, "the first parent keeps the merge's lane")
        XCTAssertEqual(lane(of: s, in: assignment), 1, "the shared further parent is read in the lane opened for it")
        XCTAssertEqual(lane(of: sideMerge, in: assignment), 2,
                       "the older merge finds no lane free and opens lane 2")
        XCTAssertEqual(lane(of: x1, in: assignment), 2, "its first parent keeps lane 2")
        XCTAssertEqual(lane(of: base, in: assignment), 0, "the root is read at the leftmost lane reserved for it")

        // Two discriminators in one list. First: an edge reaching sideways from lane 2 into the
        // existing lane 1, and no fourth lane — an implementation that ignored the reservation
        // would carry `edge(2, 3)` here instead. Second, and the one R3's F3 named: lane 1 is
        // *also* the lane `mainMerge` opened for `s` two rows above, and that line passes
        // through this row on its own way down. Both must be drawn, so this row carries **two**
        // edges arriving in lane 1 (D43). An edge model allowing one edge per destination lane
        // cannot express that: it emitted `edge(2, 1)` alone and broke `mainMerge`'s line at
        // this row.
        XCTAssertEqual(edges(of: sideMerge, in: assignment),
                       [edge(0, 0), edge(1, 1), edge(2, 1), edge(2, 2)],
                       "the merge reaches into the shared parent's lane without erasing the line "
                       + "already running down it")
        assertEveryEdgeLands(assignment)
    }

    // MARK: - 9. a truncated lane runs to the bottom of the window

    /// A parent outside the window does not end its lane at the row that named it: it is never
    /// read, so the reservation is never released and the lane repeats a truncated straight-down
    /// edge on every row below.
    ///
    /// The window test above only covers the linear last-row case, where the truncated edge leaves
    /// the final row and there is nothing below it to check. This is the case a panel actually has
    /// to draw: a line that leaves the bottom of the viewport.
    ///
    /// Layout: `c1` (root) ← `c2` ← `c3` on `main`, and `c1` ← `detached`, newer than `c3` and
    /// tagged `v9`. Measured topological order, `git` 2.55.0: `detached`, `c3`, `c2`, `c1`; read
    /// with `limit: 3` the window is `detached`, `c3`, `c2` and `c1` is outside it. `detached`
    /// takes lane 0 and reserves it for the unread `c1`; `c3` opens lane 1 and reserves it for
    /// `c2`; `c2` keeps lane 1 and reserves it for the unread `c1`.
    ///
    /// What would have to be true for this to fail: an implementation that dropped a lane whose
    /// target is outside the window, which removes lane 0's edge from the two rows below the one
    /// that opened it.
    func testALaneWhoseParentIsOutsideTheWindowKeepsEmittingItsTruncatedEdge() async throws {
        let fixture = try await GitFixture(tree)
        let c1 = try await fixture.commit(message: "c1 root", files: ["a.txt": "a\n"])
        let c2 = try await fixture.commit(message: "c2 on main", files: ["b.txt": "b\n"])
        let c3 = try await fixture.commit(message: "c3 on main", files: ["c.txt": "c\n"])
        try await fixture.detach(c1)
        let detached = try await fixture.commit(message: "detached work", files: ["d.txt": "d\n"])
        try await fixture.tag("v9")
        try await fixture.checkout("main")

        let window = try await commits(fixture, limit: 3)
        XCTAssertEqual(window.map(\.hash), [detached, c3, c2],
                       "the measured --topo-order --all window of git 2.55.0 over this shape")

        let assignment = LaneAssignment.assign(commits: window, workingTreeIsDirty: false)
        XCTAssertEqual(assignment.laneCount, 2, "two lanes are the high-water mark of this window")
        XCTAssertNil(lane(of: c1, in: assignment), "the shared root is outside the window")

        XCTAssertEqual(lane(of: detached, in: assignment), 0, "the newest tip holds lane 0")
        XCTAssertEqual(lane(of: c3, in: assignment), 1, "the branch tip opens lane 1")
        XCTAssertEqual(lane(of: c2, in: assignment), 1, "its first parent keeps lane 1")

        // Lane 0's target is outside the window from the very first row, and the lane stays
        // occupied for all three: this is the assertion the linear window test cannot make.
        XCTAssertEqual(edges(of: detached, in: assignment), [edge(0, 0, truncated: true)],
                       "the tag-only tip's parent was never read")
        XCTAssertEqual(edges(of: c3, in: assignment),
                       [edge(0, 0, truncated: true), edge(1, 1, truncated: false)],
                       "lane 0 keeps running down past this row while lane 1 lands on the row below")
        XCTAssertEqual(edges(of: c2, in: assignment),
                       [edge(0, 0, truncated: true), edge(1, 1, truncated: true)],
                       "both lanes leave the bottom of the window, and neither ends at a row")
        assertEveryEdgeLands(assignment)
    }
}
