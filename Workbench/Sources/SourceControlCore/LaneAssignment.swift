import Foundation

/// One drawable row of the commit graph: what it holds, which lane its dot sits in, and the edges
/// that leave it downward toward the next row.
///
/// A *lane* is a horizontal slot numbered from zero; an *edge* is one of the vertical lines
/// between rows. Nothing here is a pixel: a lane is an index and a row is a position, and every
/// decision about width, colour and curvature belongs to the panel (C7.7).
public struct GraphRow: Hashable, Sendable {

    public enum Content: Hashable, Sendable {
        /// The working tree's own row, present only when the tree is dirty (D6). It is always
        /// row zero and always lane zero, and it makes no claim beyond "there are uncommitted
        /// changes sitting above `HEAD`".
        case workingTree
        case commit(GitCommit)
    }

    /// A line leaving this row downward.
    ///
    /// `fromLane` is where the line starts at this row and `toLane` where it arrives at the next:
    /// the two are equal for a lane running straight down, and differ where a merge's row reaches
    /// sideways into the lane it opened for a further parent.
    public struct Edge: Hashable, Sendable {
        public var fromLane: Int
        public var toLane: Int
        /// The commit this edge points at was not in the window `GitLog.commits` read (D5), so the
        /// line has no row to land on. A window is the ordinary case rather than a corruption, and
        /// a panel that did not know would draw a line ending in nothing.
        public var truncated: Bool

        public init(fromLane: Int, toLane: Int, truncated: Bool) {
            self.fromLane = fromLane
            self.toLane = toLane
            self.truncated = truncated
        }
    }

    public var content: Content
    public var lane: Int
    /// The edges leaving this row toward the next, ordered by the lane they arrive in.
    public var edges: [Edge]

    public init(content: Content, lane: Int, edges: [Edge]) {
        self.content = content
        self.lane = lane
        self.edges = edges
    }
}

/// A window of commits placed into lanes, ready to be drawn.
///
/// This is the whole of what turns `[GitCommit]` into a graph. It depends on exactly one property
/// of its input — that `git log --topo-order` never lists a commit before all of its children —
/// and on nothing about how git itself draws.
public struct LaneAssignment: Hashable, Sendable {

    public var rows: [GraphRow]
    /// The widest the graph ever gets: the high-water mark of the number of lanes in use, which is
    /// what a panel sizes its gutter from.
    public var laneCount: Int

    public init(rows: [GraphRow], laneCount: Int) {
        self.rows = rows
        self.laneCount = laneCount
    }

    /// Places `commits` — in the order `git log --topo-order` gave them, newest first — into lanes.
    ///
    /// The algorithm keeps one array, `lanes`, where `lanes[i]` is the hash that lane `i` is
    /// currently *reserved* for, or `nil` when the lane is free. A reservation is made by a child
    /// and consumed by the parent it names, so a lane is exactly "a line that is on its way down to
    /// a commit not yet read".
    ///
    /// For each commit, in order:
    ///
    /// 1. Its lane is the leftmost lane reserved for its hash. If no lane is reserved for it — a
    ///    branch tip, or a commit reachable only through a tag — it takes the leftmost free lane,
    ///    appending a new one when none is free.
    /// 2. That reservation is freed, and then every *other* lane also reserved for this hash is
    ///    released. A commit reached by two children closes the extra lanes at its own row, which
    ///    is where the two lines visibly converge.
    /// 3. The first parent reserves the commit's own lane. This is the rule the whole shape rests
    ///    on: it is what makes a line of history run straight down instead of wandering, and it is
    ///    what makes the *second* parent of a merge the side that gets a new lane. It reserves the
    ///    commit's lane even when another lane already holds a reservation for the same parent —
    ///    the duplicate is deliberate, and step 2 releases it at the parent's row.
    /// 4. Each further parent takes the leftmost free lane, unless some lane already holds a
    ///    reservation for that parent's hash, in which case no new lane is taken and the edge
    ///    points at the existing one.
    ///
    /// The edges leaving the row are then one per lane reserved after that update: from the
    /// commit's own lane for a lane this commit's parents occupy, and straight down for a lane
    /// merely passing through. An edge whose target hash is not among `commits` is `truncated`.
    ///
    /// When `workingTreeIsDirty`, a `.workingTree` row is prepended at lane 0 with one edge into
    /// the lane the first commit row occupies. That commit is `HEAD`, because `--topo-order` lists
    /// it first among the reachable tips; the row makes no other claim.
    public static func assign(commits: [GitCommit], workingTreeIsDirty: Bool) -> LaneAssignment {
        // Membership of the window, for the `truncated` flag. A parent outside it terminates its
        // lane's line at the last row that named it.
        let inWindow = Set(commits.map(\.hash))

        var lanes: [String?] = []
        var laneCount = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count + (workingTreeIsDirty ? 1 : 0))

        for commit in commits {
            // 1 and 2: find this commit's lane, then clear every reservation naming it.
            let lane: Int
            if let reserved = lanes.firstIndex(where: { $0 == commit.hash }) {
                lane = reserved
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                lane = free
            } else {
                lanes.append(nil)
                lane = lanes.count - 1
            }
            for index in lanes.indices where lanes[index] == commit.hash { lanes[index] = nil }

            // 3 and 4: reserve a lane for each parent. `parentLanes` is what distinguishes an edge
            // this row *creates* from one merely passing through it.
            var parentLanes = Set<Int>()
            for (position, parent) in commit.parents.enumerated() {
                if position == 0 {
                    lanes[lane] = parent
                    parentLanes.insert(lane)
                } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    parentLanes.insert(existing)
                } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                    lanes[free] = parent
                    parentLanes.insert(free)
                } else {
                    lanes.append(parent)
                    parentLanes.insert(lanes.count - 1)
                }
            }
            laneCount = max(laneCount, lanes.count)

            var edges: [GraphRow.Edge] = []
            for index in lanes.indices {
                guard let target = lanes[index] else { continue }
                edges.append(GraphRow.Edge(fromLane: parentLanes.contains(index) ? lane : index,
                                           toLane: index,
                                           truncated: !inWindow.contains(target)))
            }

            rows.append(GraphRow(content: .commit(commit), lane: lane, edges: edges))
        }

        if workingTreeIsDirty {
            let toHead = rows.first.map { [GraphRow.Edge(fromLane: 0, toLane: $0.lane, truncated: false)] } ?? []
            rows.insert(GraphRow(content: .workingTree, lane: 0, edges: toHead), at: 0)
            // A repository with no commits still draws its one dirty row somewhere.
            laneCount = max(laneCount, 1)
        }

        return LaneAssignment(rows: rows, laneCount: laneCount)
    }
}
