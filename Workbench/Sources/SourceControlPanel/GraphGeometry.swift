import CoreGraphics
import Foundation
import SourceControlCore

/// The sizes the graph column draws at. Nothing here is a `View`: a metrics value is the whole of
/// what turns a lane index into an x and a row into a y.
public struct GraphMetrics: Hashable, Sendable {

    /// The horizontal distance between two lanes' centres.
    public var laneWidth: Double
    /// The height of one row, in the row's own coordinate space: its top is 0 and its bottom is
    /// this.
    public var rowHeight: Double
    /// The inset before lane 0's slot begins.
    public var leading: Double
    public var dotRadius: Double

    public init(laneWidth: Double = 14, rowHeight: Double = 24, leading: Double = 8,
                dotRadius: Double = 4) {
        self.laneWidth = laneWidth
        self.rowHeight = rowHeight
        self.leading = leading
        self.dotRadius = dotRadius
    }
}

/// One line to stroke, in the coordinate space of the row that draws it.
///
/// A segment is half of a `GraphRow.Edge`: the row the edge leaves draws the **lower** half and
/// the row below draws the **upper** half. That split is what lets the graph live in a lazy list —
/// a row is drawable from itself and its predecessor, and nothing needs the whole assignment.
///
/// The lanes are carried alongside the points because they are what a caller reasons about — a
/// colour per lane, a hit test, an assertion — and recovering a lane from an x is a division that
/// can be wrong.
public struct GraphSegment: Hashable, Sendable {

    public enum Half: Hashable, Sendable {
        /// From the row's top edge down to its centre, in the lane the edge arrives in.
        case upper
        /// From the row's centre down to its bottom edge, from `fromLane` to `toLane`.
        case lower
    }

    public var half: Half
    /// The lane the segment starts in. For an upper half this equals `toLane`: an edge's arrival
    /// is already in its destination lane by the time it crosses the row boundary.
    public var fromLane: Int
    public var toLane: Int
    public var start: CGPoint
    public var end: CGPoint
    /// The edge's target lies outside the window the assignment read. It changes **nothing** about
    /// where this segment is drawn (tracker 119): a truncated line continues, and the lane repeats
    /// the same edge on every row below. A caller may tint it; it must not terminate it.
    public var truncated: Bool
    /// This lower half has no row below to take its upper half, because the row is the last of the
    /// window. The line runs off the end rather than landing on a dot — the one visual difference
    /// the contract draws, and it is about the row's position, not about `truncated`.
    public var runsOffEnd: Bool

    public init(half: Half, fromLane: Int, toLane: Int, start: CGPoint, end: CGPoint,
                truncated: Bool, runsOffEnd: Bool) {
        self.half = half
        self.fromLane = fromLane
        self.toLane = toLane
        self.start = start
        self.end = end
        self.truncated = truncated
        self.runsOffEnd = runsOffEnd
    }
}

/// One decoration beside a row, ordered and classified for display.
///
/// `GitRef.Kind` is the fact git reported; this is the display decision taken on top of it, kept
/// out of the view so that the ordering and the label are assertable values. No text is rendered
/// here — `label` is what a view draws, and the kind is what it draws it as.
public struct RefBadge: Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        case head
        case branch
        case remoteBranch(remote: String)
        case tag
    }

    public var kind: Kind
    /// The ref's own name, as `GitRef` carries it: for a remote-tracking branch, the branch part
    /// without the remote.
    public var name: String
    /// What a view draws: `origin/main` for a remote-tracking branch, the name otherwise. A local
    /// branch that happens to be *called* `origin/feature` gets the same label and a different
    /// kind, which is the distinction `--decorate=full` was amended into contract W7 to buy.
    public var label: String

    public init(kind: Kind, name: String, label: String) {
        self.kind = kind
        self.name = name
        self.label = label
    }
}

/// The rendering contract of the commit graph (spec Design §4), as a pure function.
///
/// No SwiftUI, no `Canvas`, no `View`: this turns a row, its predecessor and a metrics value into
/// the lines to stroke, and the drawing is a separate concern that consumes them. Three properties
/// hold, and each of them is a way the graph has been got wrong before:
///
/// - **A row draws two half-edges.** Row *i* draws the lower half of every edge in `rows[i].edges`
///   and the upper half of every edge in `rows[i-1].edges`. Every edge is drawn by exactly two
///   adjacent rows and by no other, so a viewport is drawable without the assignment around it.
/// - **Edges are a sequence, never a dictionary.** `rows[i].edges` may hold two edges arriving in
///   one `toLane` and both are drawn (tracker 121, and `GraphRow.Edge`'s own doc comment). This
///   file indexes edges by nothing.
/// - **`truncated` means the line continues** (tracker 119). It is drawn to the row's bottom edge
///   exactly like any other edge and no terminator is added.
public enum GraphGeometry {

    /// The x of lane `lane`'s centre. Lanes are slots of `laneWidth` beginning at `leading`, so
    /// lane 0's centre is half a lane in.
    public static func laneCentre(_ lane: Int, metrics: GraphMetrics) -> Double {
        metrics.leading + (Double(lane) + 0.5) * metrics.laneWidth
    }

    /// The lines row `row` strokes, in its own coordinate space: y is 0 at its top, `rowHeight` at
    /// its bottom, and the dots sit on the centre line between them.
    ///
    /// `predecessor` is `rows[i-1]` — `nil` for the first row of the window, which has nothing
    /// arriving from above. `isLastRow` is true only for the final row of the whole window, whose
    /// edges no row below completes.
    ///
    /// The upper halves come first, so a caller stroking in order draws each row top to bottom.
    /// Within each half the assignment's own edge order is kept, which `LaneAssignment` documents
    /// as total and deterministic.
    public static func segments(for row: GraphRow, predecessor: GraphRow?, isLastRow: Bool,
                                metrics: GraphMetrics) -> [GraphSegment] {
        let centre = metrics.rowHeight / 2
        var segments: [GraphSegment] = []
        segments.reserveCapacity(row.edges.count + (predecessor?.edges.count ?? 0))

        // The upper halves: every edge the row above sent down arrives in its own `toLane` and
        // runs from this row's top edge to its centre. Iterated as a sequence — two edges of the
        // row above may arrive in the same lane, and both are drawn.
        for edge in predecessor?.edges ?? [] {
            let x = laneCentre(edge.toLane, metrics: metrics)
            segments.append(GraphSegment(half: .upper, fromLane: edge.toLane, toLane: edge.toLane,
                                         start: CGPoint(x: x, y: 0), end: CGPoint(x: x, y: centre),
                                         truncated: edge.truncated, runsOffEnd: false))
        }

        // The lower halves: every edge leaving this row, from its `fromLane` at the centre to its
        // `toLane` at the bottom edge. A truncated edge is drawn no differently.
        for edge in row.edges {
            segments.append(GraphSegment(
                half: .lower, fromLane: edge.fromLane, toLane: edge.toLane,
                start: CGPoint(x: laneCentre(edge.fromLane, metrics: metrics), y: centre),
                end: CGPoint(x: laneCentre(edge.toLane, metrics: metrics), y: metrics.rowHeight),
                truncated: edge.truncated, runsOffEnd: isLastRow))
        }
        return segments
    }

    /// The centre of the row's dot: its lane, on the row's centre line. The working-tree row is
    /// lane 0 like any other row, and takes no special case here.
    public static func dot(for row: GraphRow, metrics: GraphMetrics) -> CGPoint {
        CGPoint(x: laneCentre(row.lane, metrics: metrics), y: metrics.rowHeight / 2)
    }

    /// The width the graph gutter needs for `laneCount` lanes. An assignment with no lanes at all
    /// still reserves one, so that a single row is not drawn against the text.
    public static func width(laneCount: Int, metrics: GraphMetrics) -> Double {
        metrics.leading + Double(max(laneCount, 1)) * metrics.laneWidth
    }

    /// The decorations of `commit`, ordered for display: `HEAD` first, then local branches, then
    /// remote-tracking branches, then tags, and each class by its label.
    ///
    /// The order is fixed here rather than left as git printed it because `%D`'s order is git's
    /// own and a row that reordered its badges between reads would flicker.
    public static func badges(for commit: GitCommit) -> [RefBadge] {
        func rank(_ kind: RefBadge.Kind) -> Int {
            switch kind {
            case .head: 0
            case .branch: 1
            case .remoteBranch: 2
            case .tag: 3
            }
        }
        return commit.refs.map { ref in
            switch ref.kind {
            case .head:
                RefBadge(kind: .head, name: ref.name, label: ref.name)
            case .branch:
                RefBadge(kind: .branch, name: ref.name, label: ref.name)
            case .remoteBranch(let remote):
                RefBadge(kind: .remoteBranch(remote: remote), name: ref.name,
                         label: "\(remote)/\(ref.name)")
            case .tag:
                RefBadge(kind: .tag, name: ref.name, label: ref.name)
            }
        }.sorted { one, other in
            (rank(one.kind), one.label) < (rank(other.kind), other.label)
        }
    }
}
