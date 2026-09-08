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
        XCTAssertEqual(edges(of: c3, in: assignment),
                       [edge(0, 0), edge(1, 1)],
                       "the first parent stays in lane 0 while lane 1 passes through to the same root")
        XCTAssertEqual(edges(of: c1, in: assignment), [],
                       "the root commit is parentless, so no edge leaves its row")
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

        // The discriminator: lane 1 runs straight down from the detached commit to the shared
        // root, beside lane 0's pass-through. An assignment that pointed the first parent at the
        // reservation lane 0 already holds would emit a single crossing edge here instead.
        XCTAssertEqual(edges(of: detached, in: assignment),
                       [edge(0, 0), edge(1, 1)],
                       "the detached commit's lane runs down to the root beside the branch's lane")
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
    }
}
