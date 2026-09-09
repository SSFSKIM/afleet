import XCTest
@testable import SourceControlPanel
import SourceControlCore

/// The rendering contract of spec Design §4, asserted as values (gates G1.1 and G1.2).
///
/// Every assertion below names the lanes it expects rather than asserting that some lanes exist:
/// a row that vanished, an edge indexed away by destination lane (tracker 121) or a truncated line
/// stopped at the row that named it (tracker 119) all satisfy a count and fail these.
///
/// The metrics are one fixed value so that every expected coordinate can be written out. With
/// `leading` 8 and `laneWidth` 14 the centre of lane *i* is `15 + 14i`: lane 0 at **15**, lane 1 at
/// **29**, lane 2 at **43**. With `rowHeight` 24 a row's top is **0**, its centre **12** and its
/// bottom **24**, in the row's own coordinate space.
final class GraphGeometryTests: XCTestCase {

    static let metrics = GraphMetrics(laneWidth: 14, rowHeight: 24, leading: 8, dotRadius: 4)
    var metrics: GraphMetrics { Self.metrics }

    // MARK: - Fixtures

    /// A repository and the reads the panel makes of it, joined into an assignment.
    private func assignment(of repository: GitRepository, limit: Int = GitLog.defaultLimit)
        async throws -> LaneAssignment {
        let runner = RecordingRunner()
        let commits = try await GitLog.commits(root: repository.root,
                                               environment: repository.environment,
                                               runner: runner, limit: limit)
        let status = try await WorkingTreeStatus.read(root: repository.root,
                                                      environment: repository.environment,
                                                      runner: runner)
        return LaneAssignment.assign(commits: commits, headOID: status.headOID,
                                     workingTreeIsDirty: !status.isClean)
    }

    /// `one` ← `two` on `main`, `side` branching off `one`, and a `--no-ff` merge of the two.
    private func mergeRepository(_ tree: ScratchTree) async throws -> GitRepository {
        let repository = try await GitRepository(tree)
        try await repository.commit("one", files: ["a.txt": "1"])
        try await repository.branch("feature")
        try await repository.commit("two", files: ["a.txt": "2"])
        try await repository.checkout("feature")
        try await repository.commit("side", files: ["b.txt": "1"])
        try await repository.checkout("main")
        _ = try await repository.merge(["feature"], message: "merge feature")
        return repository
    }

    /// A three-parent merge: two side branches and `main` all joined at one commit.
    private func octopusRepository(_ tree: ScratchTree) async throws -> GitRepository {
        let repository = try await GitRepository(tree)
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

    /// A detached `HEAD` sitting on an annotated tag behind `main`.
    private func detachedTagRepository(_ tree: ScratchTree) async throws -> GitRepository {
        let repository = try await GitRepository(tree)
        try await repository.commit("one", files: ["a.txt": "1"])
        try await repository.commit("two", files: ["a.txt": "2"])
        try await repository.tag("v1")
        try await repository.commit("three", files: ["a.txt": "3"])
        try await repository.detach("v1")
        return repository
    }

    /// Two tips whose parents both lie outside a two-commit window — the shape that puts a
    /// `truncated` edge on a row that is **not** the last one.
    private func windowedRepository(_ tree: ScratchTree) async throws -> GitRepository {
        let repository = try await GitRepository(tree)
        try await repository.commit("base", files: ["a.txt": "1"])
        try await repository.branch("side")
        try await repository.commit("main one", files: ["a.txt": "2"])
        try await repository.commit("main two", files: ["a.txt": "3"])
        try await repository.checkout("side")
        try await repository.commit("side one", files: ["b.txt": "1"])
        return repository
    }

    /// Hand-built commits, for a shape git will not readily produce on demand.
    private func commit(_ hash: String, parents: [String], subject: String = "",
                        refs: [GitRef] = []) -> GitCommit {
        GitCommit(hash: hash, parents: parents, refs: refs, authorName: GitRepository.authorName,
                  authorTimestamp: Date(timeIntervalSince1970: 1_614_800_000), subject: subject)
    }

    /// A hash of the right shape, invented (§11): the ordinal in forty hex digits.
    private func hash(_ ordinal: Int) -> String { String(format: "%040x", ordinal) }

    // MARK: - Reading segments back

    /// Every row's segments, as the panel computes them: from the row, its predecessor and nothing
    /// else. `isLastRow` is true only for the final row of the window.
    private func allSegments(_ assignment: LaneAssignment) -> [[GraphSegment]] {
        assignment.rows.indices.map { index in
            GraphGeometry.segments(for: assignment.rows[index],
                                   predecessor: index > 0 ? assignment.rows[index - 1] : nil,
                                   isLastRow: index == assignment.rows.count - 1,
                                   metrics: metrics)
        }
    }

    /// A segment as "half fromLane->toLane[T][!]", for multiset comparison without coordinates.
    private func signature(_ segment: GraphSegment) -> String {
        "\(segment.half == .upper ? "U" : "L") \(segment.fromLane)->\(segment.toLane)"
            + (segment.truncated ? "T" : "") + (segment.runsOffEnd ? "!" : "")
    }

    private func signatures(_ segments: [GraphSegment]) -> [String] {
        segments.map(signature).sorted()
    }

    private func edgeSignatures(_ edges: [GraphRow.Edge], half: String) -> [String] {
        edges.map { "\(half) \($0.fromLane)->\($0.toLane)" + ($0.truncated ? "T" : "") }.sorted()
    }

    /// Each row as "subject@lane" — G1.1's clause, which asks for *which* commits sit in which
    /// lane and not for a list of lane numbers.
    ///
    /// A subject is a repository-relative datum the fixture authored a line above (§6.3, §11);
    /// a hash is not, and would change every run besides. Read together with the lane, it is what
    /// separates the right assignment from a permutation of the rows that carries its lanes along
    /// with it and satisfies `rows.map(\.lane)` exactly.
    private func lanesBySubject(_ assignment: LaneAssignment) -> [String] {
        assignment.rows.map { row in
            switch row.content {
            case .workingTree: return "(working tree)@\(row.lane)"
            case .commit(let commit): return "\(commit.subject)@\(row.lane)"
            }
        }
    }

    // MARK: - Group 1 — every edge is drawn by exactly two adjacent rows

    /// The half-edge pairing, over one assignment: row *i* draws the lower half of each of its own
    /// edges and the upper half of each of its predecessor's, and no other row draws either.
    ///
    /// The last row is the one exception the contract names: its edges have no row below to take
    /// their upper half, so they run off the end (group 4).
    private func assertHalfEdgePairing(_ assignment: LaneAssignment, _ label: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let perRow = allSegments(assignment)
        for (index, row) in assignment.rows.enumerated() {
            let lower = perRow[index].filter { $0.half == .lower }
            XCTAssertEqual(lower.map { "L \($0.fromLane)->\($0.toLane)"
                                       + ($0.truncated ? "T" : "") }.sorted(),
                           edgeSignatures(row.edges, half: "L"),
                           "\(label): row \(index) must draw the lower half of each of its edges",
                           file: file, line: line)
            let upper = perRow[index].filter { $0.half == .upper }
            let expectedUpper = index == 0 ? [] :
                edgeSignatures(assignment.rows[index - 1].edges.map {
                    GraphRow.Edge(fromLane: $0.toLane, toLane: $0.toLane, truncated: $0.truncated)
                }, half: "U")
            XCTAssertEqual(upper.map { "U \($0.fromLane)->\($0.toLane)"
                                       + ($0.truncated ? "T" : "") }.sorted(), expectedUpper,
                           "\(label): row \(index) must draw the upper half of its predecessor's "
                           + "edges and of no others", file: file, line: line)

            let centre = metrics.rowHeight / 2
            for segment in lower {
                XCTAssertEqual(segment.start,
                               CGPoint(x: GraphGeometry.laneCentre(segment.fromLane,
                                                                   metrics: metrics), y: centre),
                               "\(label): a lower half starts at the row's centre in `fromLane`",
                               file: file, line: line)
                XCTAssertEqual(segment.end,
                               CGPoint(x: GraphGeometry.laneCentre(segment.toLane,
                                                                   metrics: metrics),
                                       y: metrics.rowHeight),
                               "\(label): a lower half ends at the row's bottom edge in `toLane`",
                               file: file, line: line)
            }
            for segment in upper {
                let x = GraphGeometry.laneCentre(segment.toLane, metrics: metrics)
                XCTAssertEqual(segment.start, CGPoint(x: x, y: 0),
                               "\(label): an upper half starts at the row's top edge",
                               file: file, line: line)
                XCTAssertEqual(segment.end, CGPoint(x: x, y: centre),
                               "\(label): an upper half ends at the row's centre",
                               file: file, line: line)
            }
        }

        // "and in no other": the total is each edge twice, less the last row's edges, which have
        // no row below to complete them.
        let edges = assignment.rows.reduce(0) { $0 + $1.edges.count }
        let last = assignment.rows.last?.edges.count ?? 0
        XCTAssertEqual(perRow.reduce(0) { $0 + $1.count }, edges * 2 - last,
                       "\(label): every edge is drawn by exactly two adjacent rows, except the "
                       + "last row's, which run off the end", file: file, line: line)
    }

    func testEveryEdgeOfTheMergeFixtureIsDrawnByExactlyTwoAdjacentRows() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let assignment = try await assignment(of: try await mergeRepository(tree))

        // The lanes this fixture is expected to occupy, named rather than counted: the merge in
        // lane 0 reaching into lane 1, `side` read at lane 1, and `two` taking both lines back.
        XCTAssertEqual(assignment.laneCount, 2)
        XCTAssertEqual(lanesBySubject(assignment),
                       ["merge feature@0", "side@1", "two@0", "one@0"],
                       "the fixture's own commits are not the ones sitting in these lanes")
        XCTAssertEqual(assignment.rows.map { $0.edges.map { [$0.fromLane, $0.toLane] } },
                       [[[0, 0], [0, 1]], [[0, 0], [1, 1]], [[0, 0], [1, 0]], []])
        assertHalfEdgePairing(assignment, "merge")

        // Row 1 in full, coordinates and all: two upper halves at the tops of lanes 0 and 1, from
        // the merge's two edges above, and two lower halves running straight down those lanes.
        XCTAssertEqual(allSegments(assignment)[1], [
            GraphSegment(half: .upper, fromLane: 0, toLane: 0, start: CGPoint(x: 15, y: 0),
                         end: CGPoint(x: 15, y: 12), truncated: false, runsOffEnd: false),
            GraphSegment(half: .upper, fromLane: 1, toLane: 1, start: CGPoint(x: 29, y: 0),
                         end: CGPoint(x: 29, y: 12), truncated: false, runsOffEnd: false),
            GraphSegment(half: .lower, fromLane: 0, toLane: 0, start: CGPoint(x: 15, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: false, runsOffEnd: false),
            GraphSegment(half: .lower, fromLane: 1, toLane: 1, start: CGPoint(x: 29, y: 12),
                         end: CGPoint(x: 29, y: 24), truncated: false, runsOffEnd: false),
        ])
        // `side` is read at lane 1, so its dot is at lane 1's centre and not lane 0's.
        XCTAssertEqual(GraphGeometry.dot(for: assignment.rows[1], metrics: metrics),
                       CGPoint(x: 29, y: 12))
        XCTAssertEqual(GraphGeometry.dot(for: assignment.rows[0], metrics: metrics),
                       CGPoint(x: 15, y: 12))
        XCTAssertEqual(GraphGeometry.width(laneCount: assignment.laneCount, metrics: metrics), 36)
    }

    func testEveryEdgeOfTheOctopusFixtureIsDrawnByExactlyTwoAdjacentRows() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let assignment = try await assignment(of: try await octopusRepository(tree))

        XCTAssertEqual(assignment.laneCount, 3)
        XCTAssertEqual(lanesBySubject(assignment), ["octopus@0", "two work@2", "one work@1", "main work@0", "root@0"],
                       "the fixture's own commits are not the ones sitting in these lanes")
        XCTAssertEqual(assignment.rows.map { $0.edges.map { [$0.fromLane, $0.toLane] } },
                       [[[0, 0], [0, 1], [0, 2]], [[0, 0], [1, 1], [2, 2]],
                        [[0, 0], [1, 1], [2, 2]], [[0, 0], [1, 0], [2, 0]], []])
        assertHalfEdgePairing(assignment, "octopus")

        // The octopus row reaches from lane 0 into lanes 1 and 2 — three lower halves, one per
        // parent, each ending at the bottom edge in its own lane.
        XCTAssertEqual(allSegments(assignment)[0], [
            GraphSegment(half: .lower, fromLane: 0, toLane: 0, start: CGPoint(x: 15, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: false, runsOffEnd: false),
            GraphSegment(half: .lower, fromLane: 0, toLane: 1, start: CGPoint(x: 15, y: 12),
                         end: CGPoint(x: 29, y: 24), truncated: false, runsOffEnd: false),
            GraphSegment(half: .lower, fromLane: 0, toLane: 2, start: CGPoint(x: 15, y: 12),
                         end: CGPoint(x: 43, y: 24), truncated: false, runsOffEnd: false),
        ])
        XCTAssertEqual(GraphGeometry.dot(for: assignment.rows[1], metrics: metrics),
                       CGPoint(x: 43, y: 12))
        XCTAssertEqual(GraphGeometry.width(laneCount: assignment.laneCount, metrics: metrics), 50)
    }

    func testEveryEdgeOfTheDetachedTagFixtureIsDrawnByExactlyTwoAdjacentRows() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let assignment = try await assignment(of: try await detachedTagRepository(tree))

        // One lane throughout: a detached `HEAD` behind `main` adds a decoration, not a lane.
        XCTAssertEqual(assignment.laneCount, 1)
        XCTAssertEqual(lanesBySubject(assignment), ["three@0", "two@0", "one@0"],
                       "the fixture's own commits are not the ones sitting in these lanes")
        XCTAssertEqual(assignment.rows.map { $0.edges.map { [$0.fromLane, $0.toLane] } },
                       [[[0, 0]], [[0, 0]], []])
        assertHalfEdgePairing(assignment, "detached tag")
        for row in assignment.rows {
            XCTAssertEqual(GraphGeometry.dot(for: row, metrics: metrics), CGPoint(x: 15, y: 12))
        }
    }

    // MARK: - Group 2 — two edges arriving in one `toLane` both appear (tracker 121)

    /// A real repository already produces the converging pair: `two` is reached both by its own
    /// child and by the merge's second parent, so its row carries `0->0` and `1->0`.
    func testTwoEdgesConvergingOnOneLaneBothAppear() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let assignment = try await assignment(of: try await mergeRepository(tree))

        XCTAssertEqual(assignment.rows[2].edges.filter { $0.toLane == 0 }.count, 2,
                       "the fixture must actually carry two edges arriving in lane 0")
        let segments = allSegments(assignment)[2].filter { $0.half == .lower }
        XCTAssertEqual(segments, [
            GraphSegment(half: .lower, fromLane: 0, toLane: 0, start: CGPoint(x: 15, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: false, runsOffEnd: false),
            GraphSegment(half: .lower, fromLane: 1, toLane: 0, start: CGPoint(x: 29, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: false, runsOffEnd: false),
        ], "both lines converging on lane 0 are drawn; a renderer keyed by `toLane` keeps one")
        // And the row below draws two upper halves in lane 0, one per edge.
        XCTAssertEqual(allSegments(assignment)[3].filter { $0.half == .upper }.count, 2)
    }

    /// The other way one lane takes two edges (`LaneAssignment.Edge`'s doc comment): a merge
    /// reaching sideways into a lane another child already reserved, so that lane carries the
    /// merge's edge **and** the pass-through of the line already running down it.
    ///
    /// Hand-built, because it needs a tip read before the merge whose first parent is the merge's
    /// *second* parent — an ordering git produces only for a particular arrangement of dates.
    func testAMergeReachingIntoAReservedLaneDrawsBothThatEdgeAndThePassThrough() {
        let commits = [
            commit(hash(1), parents: [hash(3)], subject: "a tip on the shared parent"),
            commit(hash(2), parents: [hash(4), hash(3)], subject: "a merge reaching sideways"),
            commit(hash(3), parents: [hash(4)], subject: "the shared parent"),
            commit(hash(4), parents: [], subject: "the root"),
        ]
        let assignment = LaneAssignment.assign(commits: commits, headOID: nil,
                                               workingTreeIsDirty: false)
        XCTAssertEqual(assignment.rows.map(\.lane), [0, 1, 0, 0])
        XCTAssertEqual(assignment.rows[1].edges.map { [$0.fromLane, $0.toLane] },
                       [[0, 0], [1, 0], [1, 1]],
                       "lane 0 takes both the pass-through and the merge's sideways edge")

        let segments = allSegments(assignment)[1].filter { $0.half == .lower }
        XCTAssertEqual(segments, [
            GraphSegment(half: .lower, fromLane: 0, toLane: 0, start: CGPoint(x: 15, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: false, runsOffEnd: false),
            GraphSegment(half: .lower, fromLane: 1, toLane: 0, start: CGPoint(x: 29, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: false, runsOffEnd: false),
            GraphSegment(half: .lower, fromLane: 1, toLane: 1, start: CGPoint(x: 29, y: 12),
                         end: CGPoint(x: 29, y: 24), truncated: false, runsOffEnd: false),
        ], "the pass-through down lane 0 survives the merge that reaches into it")
        // The row below completes all three: two upper halves in lane 0, one in lane 1.
        XCTAssertEqual(signatures(allSegments(assignment)[2].filter { $0.half == .upper }),
                       ["U 0->0", "U 0->0", "U 1->1"])
        assertHalfEdgePairing(assignment, "sideways merge")
    }

    // MARK: - Group 3 — a truncated edge continues (tracker 119)

    func testATruncatedEdgeIsDrawnToTheRowsBottomEdgeAndReappearsOnTheRowBelow() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        // Two commits of a longer history: both tips' parents fall outside the window, so row 0
        // carries a truncated edge and is *not* the last row.
        let assignment = try await assignment(of: try await windowedRepository(tree), limit: 2)

        XCTAssertEqual(lanesBySubject(assignment), ["side one@0", "main two@1"],
                       "the fixture's own commits are not the ones sitting in these lanes")
        XCTAssertEqual(assignment.rows[0].edges.map { [$0.fromLane, $0.toLane] }, [[0, 0]])
        XCTAssertTrue(assignment.rows[0].edges[0].truncated,
                      "the fixture must actually carry a truncated edge on a non-last row")

        // Row 0: drawn to the bottom edge in lane 0, exactly like any other edge, and completed by
        // the row below rather than stopped at this row's centre.
        XCTAssertEqual(allSegments(assignment)[0], [
            GraphSegment(half: .lower, fromLane: 0, toLane: 0, start: CGPoint(x: 15, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: true, runsOffEnd: false),
        ])
        // Row 1: the same lane 0 line arrives from the top, and the assignment re-emits the edge,
        // so lane 0 goes on down.
        XCTAssertEqual(signatures(allSegments(assignment)[1]),
                       ["L 0->0T!", "L 1->1T!", "U 0->0T"])
        XCTAssertEqual(allSegments(assignment)[1].first { $0.half == .upper }?.end,
                       CGPoint(x: 15, y: 12))
        assertHalfEdgePairing(assignment, "windowed")
    }

    /// The naming half of the same property: no segment carries a terminator of any kind, and a
    /// truncated segment differs from an ordinary one only by its flag.
    func testATruncatedSegmentDiffersFromAnOrdinaryOneOnlyByItsFlag() {
        let ordinary = GraphRow(content: .commit(commit(hash(1), parents: [hash(2)])), lane: 0,
                                edges: [GraphRow.Edge(fromLane: 0, toLane: 0, truncated: false)])
        let truncated = GraphRow(content: .commit(commit(hash(1), parents: [hash(2)])), lane: 0,
                                 edges: [GraphRow.Edge(fromLane: 0, toLane: 0, truncated: true)])
        let one = GraphGeometry.segments(for: ordinary, predecessor: nil, isLastRow: false,
                                         metrics: metrics)
        let other = GraphGeometry.segments(for: truncated, predecessor: nil, isLastRow: false,
                                           metrics: metrics)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.map(\.start), other.map(\.start))
        XCTAssertEqual(one.map(\.end), other.map(\.end))
        XCTAssertEqual(other.map(\.truncated), [true])
    }

    // MARK: - Group 4 — the bottom row runs every edge off the end

    func testTheBottomRowOfTheWindowRunsEveryEdgeOffTheEnd() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let assignment = try await assignment(of: try await windowedRepository(tree), limit: 2)

        let last = allSegments(assignment)[1].filter { $0.half == .lower }
        XCTAssertEqual(last.map { [$0.fromLane, $0.toLane] }, [[0, 0], [1, 1]])
        for segment in last {
            XCTAssertEqual(segment.end.y, metrics.rowHeight)
            XCTAssertTrue(segment.runsOffEnd,
                          "the bottom row has no row below to take the upper half")
        }
        // And a row that is not the bottom one does not claim to run off the end.
        XCTAssertEqual(allSegments(assignment)[0].map(\.runsOffEnd), [false])
    }

    /// "Truncated **or not**": the bottom-row treatment is a fact about the row's position, not
    /// about the flag. Hand-built, because in a windowed read every bottom-row edge happens to be
    /// truncated as well.
    func testTheBottomRowRunsAnUntruncatedEdgeOffTheEndToo() {
        let row = GraphRow(content: .commit(commit(hash(1), parents: [hash(2)])), lane: 1,
                           edges: [GraphRow.Edge(fromLane: 1, toLane: 0, truncated: false),
                                   GraphRow.Edge(fromLane: 1, toLane: 1, truncated: true)])
        let segments = GraphGeometry.segments(for: row, predecessor: nil, isLastRow: true,
                                              metrics: metrics)
        XCTAssertEqual(segments, [
            GraphSegment(half: .lower, fromLane: 1, toLane: 0, start: CGPoint(x: 29, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: false, runsOffEnd: true),
            GraphSegment(half: .lower, fromLane: 1, toLane: 1, start: CGPoint(x: 29, y: 12),
                         end: CGPoint(x: 29, y: 24), truncated: true, runsOffEnd: true),
        ])
    }

    // MARK: - Group 5 — the working-tree row is row zero, lane zero, exactly when dirty

    func testTheWorkingTreeRowIsRowZeroLaneZeroExactlyWhenTheTreeIsDirty() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let repository = try await mergeRepository(tree)

        let clean = try await assignment(of: repository)
        XCTAssertFalse(clean.rows.contains { $0.content == .workingTree },
                       "a clean tree draws no working-tree row anywhere")

        try repository.write("a.txt", "an uncommitted edit")
        let dirty = try await assignment(of: repository)
        XCTAssertEqual(dirty.rows.first?.content, .workingTree)
        XCTAssertEqual(dirty.rows.first?.lane, 0)
        XCTAssertEqual(GraphGeometry.dot(for: dirty.rows[0], metrics: metrics),
                       CGPoint(x: 15, y: 12), "the working-tree dot sits in lane 0")
        // Its single edge runs down lane 0 to `HEAD`, and the row below takes the upper half.
        XCTAssertEqual(allSegments(dirty)[0], [
            GraphSegment(half: .lower, fromLane: 0, toLane: 0, start: CGPoint(x: 15, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: false, runsOffEnd: false),
        ])
        XCTAssertEqual(signatures(allSegments(dirty)[1].filter { $0.half == .upper }), ["U 0->0"])
        XCTAssertEqual(dirty.rows.count, clean.rows.count + 1)
        XCTAssertEqual(dirty.rows.dropFirst().map(\.lane), clean.rows.map(\.lane),
                       "the dirty row is prepended; it does not move the commits' lanes")
        assertHalfEdgePairing(dirty, "dirty merge")
    }

    // MARK: - Group 6 — geometry is a pure function of (row, predecessor, metrics)

    func testGeometryDoesNotDependOnTheNumberOfRows() {
        func chain(_ length: Int) -> LaneAssignment {
            LaneAssignment.assign(commits: (0..<length).map {
                commit(hash($0), parents: [hash($0 + 1)], subject: "commit \($0)")
            }, headOID: nil, workingTreeIsDirty: false)
        }
        let small = chain(5), large = chain(500)
        XCTAssertEqual(small.rows.count, 5)
        XCTAssertEqual(large.rows.count, 500)
        XCTAssertEqual(small.rows[2], large.rows[2], "the assignment itself agrees at row 2")

        // Row 2 is lane 0 throughout and interior to both windows, so its drawing is identical.
        let fromSmall = GraphGeometry.segments(for: small.rows[2], predecessor: small.rows[1],
                                               isLastRow: false, metrics: metrics)
        let fromLarge = GraphGeometry.segments(for: large.rows[2], predecessor: large.rows[1],
                                               isLastRow: false, metrics: metrics)
        XCTAssertEqual(fromSmall, fromLarge,
                       "no segment's coordinates depend on how many rows the window holds")
        XCTAssertEqual(fromSmall, [
            GraphSegment(half: .upper, fromLane: 0, toLane: 0, start: CGPoint(x: 15, y: 0),
                         end: CGPoint(x: 15, y: 12), truncated: false, runsOffEnd: false),
            GraphSegment(half: .lower, fromLane: 0, toLane: 0, start: CGPoint(x: 15, y: 12),
                         end: CGPoint(x: 15, y: 24), truncated: false, runsOffEnd: false),
        ])
    }

    func testMetricsScaleTheGeometryAndNothingElse() {
        let row = GraphRow(content: .commit(commit(hash(1), parents: [hash(2)])), lane: 2,
                           edges: [GraphRow.Edge(fromLane: 2, toLane: 1, truncated: false)])
        let wide = GraphMetrics(laneWidth: 20, rowHeight: 40, leading: 0, dotRadius: 5)
        // Lane centres at 10 and 30, centre y at 20, bottom at 40.
        XCTAssertEqual(GraphGeometry.segments(for: row, predecessor: nil, isLastRow: false,
                                              metrics: wide), [
            GraphSegment(half: .lower, fromLane: 2, toLane: 1, start: CGPoint(x: 50, y: 20),
                         end: CGPoint(x: 30, y: 40), truncated: false, runsOffEnd: false),
        ])
        XCTAssertEqual(GraphGeometry.dot(for: row, metrics: wide), CGPoint(x: 50, y: 20))
        XCTAssertEqual(GraphGeometry.width(laneCount: 3, metrics: wide), 60)
        XCTAssertEqual(GraphGeometry.width(laneCount: 0, metrics: wide), 20,
                       "a graph with no lanes still reserves one, so a lone row has a gutter")
    }

    // MARK: - Ref badges

    func testRefBadgesAreOrderedAndClassifiedForDisplay() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let assignment = try await assignment(of: try await detachedTagRepository(tree))
        guard case .commit(let tagged) = assignment.rows[1].content else {
            return XCTFail("row 1 is the tagged commit")
        }
        XCTAssertEqual(GraphGeometry.badges(for: tagged), [
            RefBadge(kind: .head, name: "HEAD", label: "HEAD"),
            RefBadge(kind: .tag, name: "v1", label: "v1"),
        ], "a detached HEAD on a tag draws both, HEAD first")

        guard case .commit(let tip) = assignment.rows[0].content else {
            return XCTFail("row 0 is the branch tip")
        }
        XCTAssertEqual(GraphGeometry.badges(for: tip),
                       [RefBadge(kind: .branch, name: "main", label: "main")])
    }

    func testRefBadgesDistinguishALocalBranchFromARemoteTrackingOne() {
        let decorated = commit(hash(1), parents: [], refs: [
            GitRef(kind: .tag, name: "v2"),
            GitRef(kind: .remoteBranch(remote: "origin"), name: "main"),
            GitRef(kind: .branch, name: "origin/feature"),
            GitRef(kind: .branch, name: "main"),
            GitRef(kind: .head, name: "HEAD"),
        ])
        XCTAssertEqual(GraphGeometry.badges(for: decorated), [
            RefBadge(kind: .head, name: "HEAD", label: "HEAD"),
            RefBadge(kind: .branch, name: "main", label: "main"),
            RefBadge(kind: .branch, name: "origin/feature", label: "origin/feature"),
            RefBadge(kind: .remoteBranch(remote: "origin"), name: "main", label: "origin/main"),
            RefBadge(kind: .tag, name: "v2", label: "v2"),
        ], "the local branch named `origin/feature` and the remote-tracking `origin/main` read "
           + "alike and are different kinds — the distinction `--decorate=full` buys")
    }

    func testACommitWithNoDecorationHasNoBadges() {
        XCTAssertEqual(GraphGeometry.badges(for: commit(hash(1), parents: [])), [])
    }
}
