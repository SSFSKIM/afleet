// SourceControlPanel: owned by C7.7 (docs/doperpowers/specs/2026-09-09-c7.7-scm-panel.md).
// Design §4: the row-sized `Canvas` that strokes what `GraphGeometry` returns, and nothing it
// worked out for itself.
import CoreGraphics
import SwiftUI
import SourceControlCore

/// The graph gutter of one row.
///
/// **It computes no geometry.** Every point it strokes comes from `GraphGeometry`, which owns the
/// contract Design §4 states and which `GraphGeometryTests` proves; this type turns that sequence
/// into a `Canvas`'s strokes and does nothing else. The split is what makes the drawing assertable:
/// `drawList` is a pure function of a row, its predecessor and a metrics value, so a test reads the
/// operations the canvas will execute rather than a rendered image (§17.7).
///
/// One row draws itself and the *upper* halves of its predecessor's edges, which is what lets the
/// graph live in a lazy list: the panel hands each row the row above it and no view ever needs the
/// whole assignment.
struct GraphColumn: View {

    /// One thing the canvas does, in the row's own coordinate space.
    ///
    /// A **sequence**, deliberately, and not a dictionary keyed by lane: a row may hold two edges
    /// arriving in one `toLane` and both are stroked (tracker 121). The vocabulary is closed at
    /// two cases because the contract draws exactly two things — a line, and the row's own dot.
    /// A truncated edge is a `.segment` like any other and adds no operation of its own: it means
    /// the line continues, not that it ends (tracker 119).
    enum DrawOp: Hashable, Sendable {
        case segment(GraphSegment)
        /// The row's own dot, drawn last so it sits over the lines rather than under them.
        /// `isWorkingTree` is the one row that is not a commit, drawn hollow.
        case dot(centre: CGPoint, lane: Int, isWorkingTree: Bool)
    }

    /// What the canvas executes, in order.
    ///
    /// The upper halves come first, then the lower ones — `GraphGeometry`'s own order, kept — and
    /// the dot last. Nothing is de-duplicated, re-ordered or keyed on the way through.
    static func drawList(row: SourceControlReadout.Row, predecessor: SourceControlReadout.Row?,
                         isLastRow: Bool, metrics: GraphMetrics) -> [DrawOp] {
        let graphRow = row.graphRow
        var ops = GraphGeometry.segments(for: graphRow, predecessor: predecessor?.graphRow,
                                         isLastRow: isLastRow, metrics: metrics)
            .map(DrawOp.segment)
        ops.append(.dot(centre: GraphGeometry.dot(for: graphRow, metrics: metrics),
                        lane: row.lane, isWorkingTree: row.isWorkingTree))
        return ops
    }

    /// The gutter's width for the assignment the readout carries.
    static func width(for readout: SourceControlReadout, metrics: GraphMetrics = GraphMetrics())
        -> Double {
        GraphGeometry.width(laneCount: readout.laneCount, metrics: metrics)
    }

    /// Lane colours, so two lines crossing a row can be told apart. Indexed modulo the palette:
    /// a repository with more lanes than colours repeats them, which is what every graph does.
    static let lanePalette: [Color] = [.accentColor, .orange, .purple, .teal, .pink, .green]

    static func colour(ofLane lane: Int) -> Color {
        lanePalette[((lane % lanePalette.count) + lanePalette.count) % lanePalette.count]
    }

    let row: SourceControlReadout.Row
    let predecessor: SourceControlReadout.Row?
    let isLastRow: Bool
    var metrics = GraphMetrics()
    let width: Double

    var body: some View {
        // Computed here rather than inside the canvas's closure: the list is the value a test
        // reads, and the closure's only job is to stroke it.
        let ops = Self.drawList(row: row, predecessor: predecessor, isLastRow: isLastRow,
                                metrics: metrics)
        Canvas { context, _ in
            for op in ops {
                switch op {
                case .segment(let segment):
                    var path = Path()
                    path.move(to: segment.start)
                    // A bend is drawn as a curve rather than a corner, so a merge reaching into
                    // the lane it opened reads as one line. The control points are on the two
                    // endpoints' own lanes, so nothing here invents a position.
                    if segment.fromLane == segment.toLane {
                        path.addLine(to: segment.end)
                    } else {
                        let midpoint = (segment.start.y + segment.end.y) / 2
                        path.addCurve(to: segment.end,
                                      control1: CGPoint(x: segment.start.x, y: midpoint),
                                      control2: CGPoint(x: segment.end.x, y: midpoint))
                    }
                    context.stroke(path, with: .color(Self.colour(ofLane: segment.toLane)),
                                   lineWidth: 1.5)
                case .dot(let centre, let lane, let isWorkingTree):
                    let radius = metrics.dotRadius
                    let box = CGRect(x: centre.x - radius, y: centre.y - radius,
                                     width: radius * 2, height: radius * 2)
                    let circle = Path(ellipseIn: box)
                    if isWorkingTree {
                        context.stroke(circle, with: .color(Self.colour(ofLane: lane)),
                                       lineWidth: 1.5)
                    } else {
                        context.fill(circle, with: .color(Self.colour(ofLane: lane)))
                    }
                }
            }
        }
        .frame(width: width, height: metrics.rowHeight)
        .accessibilityHidden(true)
    }
}

extension SourceControlReadout.Row {

    /// The row as `GraphGeometry` takes it. The readout carries the assignment's own fields, so
    /// this is a re-wrap and never a second lane calculation.
    var graphRow: GraphRow {
        GraphRow(content: content, lane: lane, edges: edges)
    }
}
