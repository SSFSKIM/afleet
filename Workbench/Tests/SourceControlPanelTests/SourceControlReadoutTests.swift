// SourceControlPanelTests: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// Gate G1.1's readout clause: the lanes the panel *draws* are read from `SourceControlReadout` and
// never from `LaneAssignment` directly, over a merge / octopus / detached-tag corpus.
//
// `GraphGeometryTests` proves the other half — that an assignment becomes the right segments. This
// file proves the trip in between: that a real `SourceControlModel`, having read a real repository
// with the machine's own `git`, carries the assignment's lanes, its edge *sequence*, its lane count
// and each row's ref badges out through the value the view draws from. Nothing here reads
// `model.state.assignment`; every assertion is on `model.readout`, because a readout that dropped
// every one of those fields — one lane, no edges, no badges — is a panel that draws a straight
// column and would satisfy any assertion made one layer below it (§17.7).
//
// §6.3/§11 hold over every line: an assertion names a subject the fixture authored, a lane, an edge
// or a count, and never a path, an environment or a byte a tool printed. Every repository is built
// under `FileManager.default.temporaryDirectory`.
import Foundation
import XCTest
import AfleetCore
import SourceControlCore
@testable import SourceControlPanel

@MainActor
final class SourceControlReadoutTests: XCTestCase {

    // MARK: - The harness

    /// `nonisolated` deliberately: handing a `GitRepository` to a main-actor method merges it into
    /// the main actor's region, after which every later `await repository.run(…)` is a send the
    /// compiler rejects. This reads a value out of it instead.
    private nonisolated static func environment(_ repository: GitRepository) -> ResolvedEnvironment {
        ResolvedEnvironment(variables: repository.environment, shell: "/bin/zsh",
                            capturedAt: Date(timeIntervalSince1970: 1_614_800_000),
                            mode: .processFallback)
    }

    /// A model over a repository root, with the machine's own `git` behind a recorder and the watch
    /// off — an FSEvents delivery arriving mid-assertion is a re-read nobody asked for.
    private func model(root: URL, environment: ResolvedEnvironment) -> SourceControlModel {
        SourceControlModel(cwd: root, environment: environment, runner: RecordingRunner(),
                           links: nil, windowLimit: GitLog.defaultLimit, watchesForChanges: false)
    }

    /// The readout of one activated model over `repository` — the whole of what these tests read.
    private func readout(of repository: GitRepository) async -> SourceControlReadout {
        let model = model(root: repository.root, environment: Self.environment(repository))
        await model.activate()
        return model.readout
    }

    // MARK: - The corpus (G1.1 names all three shapes)

    /// `one` ← `two` on `main`, `feature` branching off `one` with `side`, and a `--no-ff` merge.
    private func mergeRepository(_ tree: ScratchTree) async throws -> GitRepository {
        // Named, because a `ScratchTree` shared by two fixtures would otherwise hand both the same
        // directory and the second `git init` would build its history on top of the first's.
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

    /// A three-parent merge: two side branches and `main` joined at one commit.
    private func octopusRepository(_ tree: ScratchTree) async throws -> GitRepository {
        let repository = try await GitRepository(tree, name: "octopus")
        try await repository.commit("root", files: ["a.txt": "1"])
        try await repository.branch("one")
        try await repository.branch("two")
        try await repository.checkout("one")
        try await repository.commit("one work", files: ["one.txt": "1"])
        try await repository.checkout("two")
        try await repository.commit("two work", files: ["two.txt": "1"])
        try await repository.checkout("main")
        try await repository.commit("main work", files: ["main.txt": "1"])
        _ = try await repository.merge(["one", "two"], message: "octopus")
        return repository
    }

    /// A detached `HEAD` sitting on an annotated tag behind `main` — the shape whose `%D` carries a
    /// bare `HEAD`, a `tag:` and a branch on two different rows.
    private func detachedTagRepository(_ tree: ScratchTree) async throws -> GitRepository {
        let repository = try await GitRepository(tree, name: "detached-tag")
        try await repository.commit("one", files: ["a.txt": "1"])
        try await repository.commit("two", files: ["a.txt": "2"])
        try await repository.tag("v1")
        try await repository.commit("three", files: ["a.txt": "3"])
        try await repository.detach("v1")
        return repository
    }

    // MARK: - Reading the readout back

    /// Each row as `subject@lane`, in the order the panel lists them.
    ///
    /// **By subject and not by row index**, which is G1.1's own clause: a permutation that carried
    /// the rows and their lanes together satisfies `rows.map(\.lane)` exactly, and that is how a
    /// sibling defect hid. A subject is a datum the fixture authored three lines above (§6.3, §11);
    /// a hash is not, and would differ every run besides.
    private func lanesBySubject(_ readout: SourceControlReadout) -> [String] {
        readout.rows.map { row in
            if row.isWorkingTree { return "(working tree)@\(row.lane)" }
            return "\(row.commit?.subject ?? "(no commit)")@\(row.lane)"
        }
    }

    /// Every row's edges as an **ordered** sequence of `from->to`, with `T` for a truncated one.
    ///
    /// Ordered and not a set, and per row rather than pooled: two edges may arrive in one `toLane`
    /// — the merge fixture's `two` takes back both lines — and both must survive the trip out to
    /// the view. A readout that kept one edge per destination lane disconnects a line at that row
    /// (tracker 121) and fails here.
    private func edgesByRow(_ readout: SourceControlReadout) -> [[String]] {
        readout.rows.map { row in
            row.edges.map { "\($0.fromLane)->\($0.toLane)" + ($0.truncated ? "T" : "") }
        }
    }

    /// Each row's badges as `kind:label`, in the readout's own order.
    private func badges(_ row: SourceControlReadout.Row?) -> [String] {
        (row?.badges ?? []).map { badge in
            switch badge.kind {
            case .head: "head:\(badge.label)"
            case .branch: "branch:\(badge.label)"
            case .remoteBranch(let remote): "remote(\(remote)):\(badge.label)"
            case .tag: "tag:\(badge.label)"
            }
        }
    }

    private func row(subject: String, in readout: SourceControlReadout)
        -> SourceControlReadout.Row? {
        readout.rows.first { $0.commit?.subject == subject }
    }

    /// G1.1's third clause: the gutter the panel sizes from must hold every lane a row occupies.
    private func assertLaneCountCovers(_ readout: SourceControlReadout, _ label: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let widest = readout.rows.map(\.lane).max() ?? -1
        let arrivals = readout.rows.flatMap { $0.edges.flatMap { [$0.fromLane, $0.toLane] } }
                                   .max() ?? -1
        XCTAssertGreaterThan(readout.laneCount, widest,
                             "\(label): the readout counts \(readout.laneCount) lanes while a row "
                             + "sits in lane \(widest)", file: file, line: line)
        XCTAssertGreaterThan(readout.laneCount, arrivals,
                             "\(label): the readout counts \(readout.laneCount) lanes while an "
                             + "edge reaches lane \(arrivals)", file: file, line: line)
    }

    // MARK: - 1. which commit sits in which lane

    func testTheMergeFixtureReachesTheReadoutWithItsCommitsInTheirOwnLanes() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await readout(of: try await mergeRepository(tree))

        // Root spec item 27's own wording — at least two *distinct* lanes — and then which commits
        // they hold: the merge in lane 0 reaching into lane 1, `side` read at lane 1, and `two`
        // taking both lines back into lane 0.
        XCTAssertGreaterThanOrEqual(Set(readout.rows.map(\.lane)).count, 2,
                                    "a repository with a merge commit draws at least two lanes")
        XCTAssertEqual(lanesBySubject(readout), ["merge feature@0", "side@1", "two@0", "one@0"],
                       "the fixture's own commits are not the ones the readout puts in these lanes")
        XCTAssertEqual(row(subject: "side", in: readout)?.lane, 1,
                       "the branch's commit is drawn beside the first-parent line, not on it")
    }

    func testTheOctopusFixtureReachesTheReadoutWithItsThreeLanesNamed() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await readout(of: try await octopusRepository(tree))

        XCTAssertEqual(lanesBySubject(readout),
                       ["octopus@0", "two work@2", "one work@1", "main work@0", "root@0"],
                       "the fixture's own commits are not the ones the readout puts in these lanes")
        XCTAssertEqual(Set(readout.rows.map(\.lane)), [0, 1, 2],
                       "an octopus merge's three parents occupy three lanes")
    }

    func testTheDetachedTagFixtureReachesTheReadoutAsOneLane() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await readout(of: try await detachedTagRepository(tree))

        // One line of history read from two tips: `main` at `three`, and the detached `HEAD` and
        // its tag at `two`. Every row is on the first-parent line, so every row is lane 0 — a
        // count assertion cannot tell this fixture from a broken one, which is why the subjects
        // are named.
        XCTAssertEqual(lanesBySubject(readout), ["three@0", "two@0", "one@0"],
                       "the fixture's own commits are not the ones the readout puts in these lanes")
        XCTAssertTrue(readout.isDetachedHead, "`HEAD` is on no branch in this fixture")
        // The one lane is a lane the readout must actually count: every row of this fixture is
        // lane 0, so the subjects alone cannot tell it from a readout that reports one lane for
        // every shape.
        XCTAssertEqual(readout.laneCount, 1)
    }

    // MARK: - 2. the edges the readout carries

    func testTheReadoutCarriesEveryEdgeOfTheMergeFixtureInOrder() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await readout(of: try await mergeRepository(tree))

        XCTAssertEqual(edgesByRow(readout),
                       [["0->0", "0->1"], ["0->0", "1->1"], ["0->0", "1->0"], []],
                       "the readout's edges are not the ones the merge's rows leave")
        // The row where the two lines converge: two edges arriving in `toLane` 0, from lanes 0 and
        // 1, and both are carried. A readout keyed by destination lane holds one.
        XCTAssertEqual(row(subject: "two", in: readout)?.edges.map(\.toLane), [0, 0],
                       "both lines converging on `two` must survive the trip to the view")
        XCTAssertEqual(row(subject: "two", in: readout)?.edges.map(\.fromLane), [0, 1])
        XCTAssertEqual(row(subject: "merge feature", in: readout)?.edges,
                       [GraphRow.Edge(fromLane: 0, toLane: 0, truncated: false),
                        GraphRow.Edge(fromLane: 0, toLane: 1, truncated: false)],
                       "the merge row reaches from its own lane into the one it opened")
    }

    func testTheReadoutCarriesEveryEdgeOfTheOctopusFixtureInOrder() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await readout(of: try await octopusRepository(tree))

        XCTAssertEqual(edgesByRow(readout),
                       [["0->0", "0->1", "0->2"], ["0->0", "1->1", "2->2"],
                        ["0->0", "1->1", "2->2"], ["0->0", "1->0", "2->0"], []],
                       "the readout's edges are not the ones the octopus's rows leave")
        // Three lines converge on `root`, so the row above it leaves three edges all arriving in
        // lane 0 — the same "a destination lane is not a key" clause, at width three.
        XCTAssertEqual(row(subject: "main work", in: readout)?.edges.map(\.toLane), [0, 0, 0])
    }

    func testTheReadoutCarriesTheDetachedTagFixturesStraightLine() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await readout(of: try await detachedTagRepository(tree))

        XCTAssertEqual(edgesByRow(readout), [["0->0"], ["0->0"], []],
                       "one line running down lane 0 and ending at the root commit")
        XCTAssertFalse(readout.rows.flatMap(\.edges).contains { $0.truncated },
                       "no parent of this fixture lies outside the window read")
    }

    // MARK: - 3. the lane count the gutter is sized from

    func testTheReadoutsLaneCountIsTheRealOneForEveryShapeInTheCorpus() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }

        let merge = await readout(of: try await mergeRepository(tree))
        XCTAssertEqual(merge.laneCount, 2, "the merge fixture is two lanes wide")
        assertLaneCountCovers(merge, "merge")

        let octopus = await readout(of: try await octopusRepository(tree))
        XCTAssertEqual(octopus.laneCount, 3, "the octopus fixture is three lanes wide")
        assertLaneCountCovers(octopus, "octopus")

        let detached = await readout(of: try await detachedTagRepository(tree))
        XCTAssertEqual(detached.laneCount, 1, "the detached-tag fixture is one lane wide")
        assertLaneCountCovers(detached, "detached tag")
    }

    // MARK: - 4. the ref badges beside the rows

    func testTheDetachedTagFixturesBadgesReachTheReadoutWithTheirKinds() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await readout(of: try await detachedTagRepository(tree))

        // `two` carries both decorations this shape exists for: a bare `HEAD`, because it is
        // detached, and the annotated tag it was detached at. `HEAD` first, then the tag, which is
        // the display order the panel fixes so a row does not reorder its badges between reads.
        XCTAssertEqual(badges(row(subject: "two", in: readout)), ["head:HEAD", "tag:v1"],
                       "the detached `HEAD` and its tag must both reach the row that carries them")
        XCTAssertEqual(badges(row(subject: "three", in: readout)), ["branch:main"],
                       "the branch tip's own badge must reach its row, as a branch")
        XCTAssertEqual(badges(row(subject: "one", in: readout)), [],
                       "an undecorated commit carries no badge")
    }

    func testTheMergeFixturesBranchBadgesReachTheReadout() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let readout = await readout(of: try await mergeRepository(tree))

        // `HEAD -> main` on the merge commit is two refs and so two badges; `feature` sits on the
        // branch's own tip, in lane 1.
        XCTAssertEqual(badges(row(subject: "merge feature", in: readout)),
                       ["head:HEAD", "branch:main"],
                       "an attached `HEAD` reaches the readout as `HEAD` and as its branch")
        XCTAssertEqual(badges(row(subject: "side", in: readout)), ["branch:feature"],
                       "the side branch's badge must reach the row it decorates")
    }

    // MARK: - 5. the working-tree row

    func testRowZeroIsTheWorkingTreesWhenTheTreeIsDirtyAndAbsentWhenItIsClean() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await mergeRepository(tree)

        let clean = await readout(of: repository)
        XCTAssertFalse(clean.hasWorkingTreeRow, "a clean tree has no row zero")
        XCTAssertEqual(clean.rows.first?.commit?.subject, "merge feature",
                       "row zero is the newest commit while the tree is clean")
        XCTAssertFalse(clean.rows.contains { $0.isWorkingTree })

        try repository.write("a.txt", "uncommitted")
        let dirty = await readout(of: repository)
        XCTAssertTrue(dirty.hasWorkingTreeRow, "a dirty tree draws its own row zero")
        XCTAssertEqual(lanesBySubject(dirty),
                       ["(working tree)@0", "merge feature@0", "side@1", "two@0", "one@0"],
                       "the working tree's row sits above `HEAD` in lane 0, and the commits keep "
                       + "the lanes they had")
        XCTAssertEqual(dirty.rows.first?.edges,
                       [GraphRow.Edge(fromLane: 0, toLane: 0, truncated: false)],
                       "the working tree's one edge runs down to the commit `HEAD` names")
        XCTAssertNil(dirty.rows.first?.abbreviatedHash, "the working tree's row has no hash")
        XCTAssertEqual(dirty.laneCount, 2)
    }
}
