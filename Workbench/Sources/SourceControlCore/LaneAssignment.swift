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
    /// sideways into the lane it opened for a further parent, or where a line bends into the lane
    /// the parent it is on its way to turned out to be read at.
    ///
    /// **Several edges may arrive in the same `toLane`, and one lane may be left by several
    /// edges.** A destination lane is not a key (D43): where a merge reaches into a lane another
    /// child already reserved, that lane carries both the merge's edge and the pass-through of
    /// the line already running down it, and where two lanes converge on one parent both bend
    /// into that parent's lane. A consumer that indexed edges by `toLane` would silently drop one
    /// of each pair and disconnect a line at that row.
    public struct Edge: Hashable, Sendable {
        public var fromLane: Int
        public var toLane: Int
        /// The commit this edge points at was not in the window `GitLog.commits` read (D5), so the
        /// line has no row to land on. A window is the ordinary case rather than a corruption, and
        /// a panel that did not know would draw a line ending in nothing.
        ///
        /// It means "this edge's target is outside the read window", **not** "this line ends
        /// here": the lane stays occupied and repeats its truncated edge on every row below,
        /// because the parent is never read and so never releases the reservation. A consumer
        /// that read it the second way would stop drawing a line that in fact continues off the
        /// bottom of the viewport (tracker 119).
        public var truncated: Bool

        public init(fromLane: Int, toLane: Int, truncated: Bool) {
            self.fromLane = fromLane
            self.toLane = toLane
            self.truncated = truncated
        }
    }

    public var content: Content
    public var lane: Int
    /// The edges leaving this row toward the next, ordered by the lane they arrive in and then by
    /// the lane they leave from. The order is total and deterministic — no two edges of a row
    /// share both endpoints — so two assignments of the same window compare equal.
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

    /// What a lane is currently holding: the hash of a commit not yet read, and the claim's
    /// provenance.
    ///
    /// Provenance is not decoration. Two lanes can be reserved for the same commit, and the one it
    /// is read at decides which of its children's lines runs straight down and which bends
    /// sideways. Without this flag the choice would be "leftmost", which is a fact about the order
    /// tips happened to be read in rather than about the graph, and it can bend a first-parent line
    /// — see rule 1 below.
    private struct Reservation {
        var hash: String
        /// The reservation was made by rule 3 — a child naming this commit as its **first** parent,
        /// or the working-tree row, which is `HEAD`'s child under the same rule (D44) — rather than
        /// by rule 4, for a merge's further parent.
        var isFirstParent: Bool
    }

    /// Places `commits` — in the order `git log --topo-order` gave them, newest first — into lanes.
    ///
    /// The algorithm keeps one array, `lanes`, where `lanes[i]` is the hash that lane `i` is
    /// currently *reserved* for, or `nil` when the lane is free. A reservation is made by a child
    /// and consumed by the parent it names, so a lane is exactly "a line that is on its way down to
    /// a commit not yet read".
    ///
    /// When `workingTreeIsDirty`, a `.workingTree` row is prepended **before** the loop, at lane 0,
    /// and it reserves lane 0 for `headOID` — it is a child of `HEAD` and takes the same rule 3
    /// every commit does (D44). That is what makes the connection reach: `HEAD` need not be the row
    /// below, because `--topo-order --all` orders the tips by date and a tag-only commit newer than
    /// `HEAD` is listed ahead of it (measured on `git` 2.55.0), and a reserved lane is carried down
    /// through every intervening row by the pass-through rule below while a single prepended edge
    /// would dangle one row down. `HEAD` is then read in lane 0 rather than wherever it fell, and
    /// the tips read before it open lanes beside it.
    ///
    /// `headOID` is `HEAD`'s object id — `WorkingTreeStatus.headOID`, which `git status
    /// --porcelain=v2 --branch` prints as a header. It is matched by hash rather than by looking
    /// for a row carrying a `.head` ref, so a configuration that suppresses the decoration
    /// (`log.excludeDecoration`, tracker 122) cannot silently move the working tree's edge.
    ///
    /// Two cases have no row to reach, and neither invents one:
    ///
    /// - `headOID` is outside the window `commits` covers — the ordinary consequence of `skip`, or
    ///   of a `limit` shorter than the distance to `HEAD`. The row's single edge is then
    ///   `truncated`, pointing at a commit this assignment did not read, and **no lane is
    ///   reserved**. Reserving would occupy lane 0 for a hash no row ever releases, pushing the
    ///   whole graph one lane right and drawing a full-height line beside it; substituting the
    ///   first commit read — as this did before — draws the user's uncommitted changes as belonging
    ///   to an unrelated commit, which is a wrong answer rather than a missing one.
    /// - `headOID` is `nil`: `HEAD` is unborn, so there is no commit the working tree sits above.
    ///   The row is drawn alone, with no edge at all.
    ///
    /// For each commit, in order:
    ///
    /// 1. Its lane is the leftmost lane holding a **first-parent** reservation for its hash; if no
    ///    lane holds one, the leftmost lane reserved for it at all. If no lane is reserved for it —
    ///    a branch tip, or a commit reachable only through a tag — it takes the leftmost free lane,
    ///    appending a new one when none is free.
    ///
    ///    Provenance decides the tie because W7's rule is about first parents, not about lane
    ///    numbers: a commit takes the lane of the child that named it as its *first* parent. A
    ///    topological order may reach a commit from a merge's further parent before any child names
    ///    it first — `M(parents: [P, X])`, then an unrelated tip `C(parent: X)`, then `X` — and
    ///    reading `X` at the merge's side lane would bend `C`'s first-parent line sideways, which is
    ///    the one thing rule 3 exists to prevent. The further-parent lane is released at `X`'s row
    ///    like any other duplicate, so the merge's line converges on `X` (step 2) instead.
    /// 2. That reservation is freed, and then every *other* lane also reserved for this hash is
    ///    released — and, on the row above, every edge that arrived in one of those released lanes
    ///    is redirected to end in the lane this commit was read at. A commit reached by two
    ///    children closes the extra lanes at its own row, and the redirection is what makes the two
    ///    lines visibly converge *on the commit* rather than stop in the empty lanes beside it
    ///    (D43).
    /// 3. The first parent reserves the commit's own lane. This is the rule the whole shape rests
    ///    on: it is what makes a line of history run straight down instead of wandering, and it is
    ///    what makes the *second* parent of a merge the side that gets a new lane. It reserves the
    ///    commit's lane even when another lane already holds a reservation for the same parent —
    ///    the duplicate is deliberate, and step 2 releases it at the parent's row.
    /// 4. Each further parent takes the leftmost free lane, unless some lane already holds a
    ///    reservation for that parent's hash, in which case no new lane is taken and the edge
    ///    points at the existing one.
    ///
    /// The edges leaving the row are then the union of two sets, which is the whole of the edge
    /// model:
    ///
    /// - one **pass-through** `i → i` for every lane `i` that held a reservation before this
    ///   commit's parents were assigned and was not released at this row: a line merely running
    ///   past, which this row must not interrupt;
    /// - one edge `lane → p` for every lane `p` this commit's parents occupy.
    ///
    /// The two sets overlap in destination, and both edges are kept: a merge reaching into a lane
    /// another child already reserved (rule 4's clause) leaves that lane carrying the merge's edge
    /// *and* the pass-through of the line already running down it. Keeping one edge per
    /// destination lane cannot represent that pair, and dropping the pass-through disconnects the
    /// older line at this row (D43). An edge whose target hash is not among `commits` is
    /// `truncated`.
    public static func assign(commits: [GitCommit], headOID: String?,
                              workingTreeIsDirty: Bool) -> LaneAssignment {
        // Membership of the window, for the `truncated` flag. A parent outside it is never read,
        // so its reservation is never released: the lane stays occupied to the bottom of the
        // window, emitting a truncated straight-down edge on every row below the one that named
        // it. That is the wanted rendering — a line leaving a viewport does continue.
        let inWindow = Set(commits.map(\.hash))

        var lanes: [Reservation?] = []
        var laneCount = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count + (workingTreeIsDirty ? 1 : 0))

        if workingTreeIsDirty {
            // The row `HEAD` points at is the row the uncommitted changes sit above, and it is not
            // necessarily the row below — see the note on the ordering above.
            let edges: [GraphRow.Edge]
            switch headOID {
            case .some(let head) where inWindow.contains(head):
                lanes = [Reservation(hash: head, isFirstParent: true)]
                edges = [GraphRow.Edge(fromLane: 0, toLane: 0, truncated: false)]
            case .some:
                // `HEAD` is a real commit that this window does not cover: the line leaves the
                // top of the graph rather than landing on a row, and reserves nothing.
                edges = [GraphRow.Edge(fromLane: 0, toLane: 0, truncated: true)]
            case .none:
                // An unborn `HEAD`: there is no commit the uncommitted changes sit above.
                edges = []
            }
            // A repository with no commits still draws its one dirty row somewhere.
            laneCount = 1
            rows.append(GraphRow(content: .workingTree, lane: 0, edges: edges))
        }

        for commit in commits {
            // 1: find this commit's lane. A first-parent reservation outranks a further-parent one
            // wherever both name this commit, so that the child whose line runs straight down keeps
            // it; among equals, the leftmost.
            let lane: Int
            if let claimed = lanes.firstIndex(where: {
                $0?.hash == commit.hash && $0?.isFirstParent == true
            }) {
                lane = claimed
            } else if let reserved = lanes.firstIndex(where: { $0?.hash == commit.hash }) {
                lane = reserved
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                lane = free
            } else {
                lanes.append(nil)
                lane = lanes.count - 1
            }

            // 2: release every reservation naming this commit, and bend the lines that were on
            // their way into the released lanes into the lane the commit was actually read at.
            var released: Set<Int> = []
            for index in lanes.indices where lanes[index]?.hash == commit.hash {
                if index != lane { released.insert(index) }
                lanes[index] = nil
            }
            if !released.isEmpty, var above = rows.last {
                above.edges = above.edges.map { edge in
                    guard released.contains(edge.toLane) else { return edge }
                    return GraphRow.Edge(fromLane: edge.fromLane, toLane: lane,
                                         truncated: edge.truncated)
                }
                above.edges.sort { ($0.toLane, $0.fromLane) < ($1.toLane, $1.fromLane) }
                rows[rows.count - 1] = above
            }

            // The lanes a line is already running down, read before rule 3 and 4 add this row's
            // own. Rules 3 and 4 only ever write to a lane that is free or to this commit's own
            // (just released), so these indices keep their hashes below.
            let passingThrough = lanes.indices.filter { lanes[$0] != nil }

            // 3 and 4: reserve a lane for each parent.
            var parentLanes = Set<Int>()
            for (position, parent) in commit.parents.enumerated() {
                if position == 0 {
                    lanes[lane] = Reservation(hash: parent, isFirstParent: true)
                    parentLanes.insert(lane)
                } else if let existing = lanes.firstIndex(where: { $0?.hash == parent }) {
                    // The existing reservation keeps its own provenance: reaching sideways into a
                    // lane does not make this row that parent's first child.
                    parentLanes.insert(existing)
                } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                    lanes[free] = Reservation(hash: parent, isFirstParent: false)
                    parentLanes.insert(free)
                } else {
                    lanes.append(Reservation(hash: parent, isFirstParent: false))
                    parentLanes.insert(lanes.count - 1)
                }
            }
            laneCount = max(laneCount, lanes.count)

            var edges: [GraphRow.Edge] = []
            for index in passingThrough {
                edges.append(GraphRow.Edge(fromLane: index, toLane: index,
                                           truncated: !inWindow.contains(lanes[index]!.hash)))
            }
            for target in parentLanes {
                edges.append(GraphRow.Edge(fromLane: lane, toLane: target,
                                           truncated: !inWindow.contains(lanes[target]!.hash)))
            }
            // No two edges of a row share both endpoints — `parentLanes` is a set, and a lane this
            // commit's parents occupy is either free before the row or the commit's own, so it is
            // never among `passingThrough` — so the order is total.
            edges.sort { ($0.toLane, $0.fromLane) < ($1.toLane, $1.fromLane) }

            rows.append(GraphRow(content: .commit(commit), lane: lane, edges: edges))
        }

        return LaneAssignment(rows: rows, laneCount: laneCount)
    }
}
