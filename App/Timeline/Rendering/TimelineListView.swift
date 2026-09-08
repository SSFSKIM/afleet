import AppKit
import SwiftUI
import FleetKit

// MARK: - What the channel column mounts

/// The channel's timeline, and the one expression `ChannelColumnView` draws in place of C5's
/// placeholder `List` (child spec §3).
///
/// **Superseded 2026-09-08 (C6.1).** C5's column drew `List(model.rows) { TimelineRowSlot(row: $0) }`
/// and its own comments said the timeline had no markdown, no cards and no streaming because C6
/// would replace them. This is that replacement: an `NSTableView` in an `NSScrollView`, virtualized
/// by `ItemID`, bottom-anchored, and reloading one row for a streaming delta rather than
/// re-evaluating a content closure over the whole collection.
///
/// It reaches `AppModel` through the environment rather than through an initialiser argument, which
/// is the opposite of the choice C6.2's composer mount made and is made for the same reason: the
/// column's outer body is shared by three leaves and `RootView` is closed, so the two capabilities
/// this leaf needs travel the one route that adds no argument to a view another leaf owns.
struct TimelineListView: View {

    let model: ChannelTimelineModel

    @Environment(AppModel.self) private var app: AppModel?

    /// The renderer, and with it the table, the row heights and the scroll position. `@State`
    /// because a SwiftUI view *value* preserves nothing across a body evaluation and all three have
    /// to survive one; the column keys this view by the channel, so a channel switch gets its own.
    @State private var renderer = NativeTimelineRenderer()

    /// Folding is the channel's view state and outlives every row that draws a disclosure.
    @State private var collapse = TimelineCollapseState()

    var body: some View {
        // No change set: the model republishes the whole timeline and states no diff, so the table
        // computes one by key. When the model does start naming its changes the table prefers them.
        renderer.view(for: TimelineRenderInput(rows: model.rows, preview: model.timeline.preview))
            .environment(\.timelineContext, app.map(context(in:)))
    }

    /// Contract Y1's per-row capabilities and contract Y7's raise, injected on this subtree and
    /// nowhere else.
    ///
    /// **Both capabilities are the running objects', not stand-ins.** `links` is
    /// `PanelHostModel.links`, a plain `let`, and never `context(for:cwd:)`, which mutates the host
    /// inside `body` (tracker 67). `signal` is this channel's own model, so a row that raises one
    /// reaches the fold that owns the channel and not a closure a later leaf is expected to replace.
    ///
    /// It takes the model rather than reading the environment property, so the one construction the
    /// view performs is a function a test can call and exercise — a capability wired to nothing
    /// passes any assertion that only reads the value back.
    func context(in app: AppModel) -> TimelineRenderContext {
        TimelineRenderContext(key: model.key,
                              links: app.panels.links,
                              signal: { [model] signal in await model.signal(signal) },
                              agents: app.agentNavigation,
                              collapse: collapse,
                              neighbourhood: TimelineNeighbourhood(items: model.timeline.items,
                                                                   agents: model.timeline.agents))
    }
}

// MARK: - The surface the renderer returns

/// The table, with the jump-to-bottom affordance over it.
struct TimelineListSurface: View {

    let controller: TimelineTableController
    let input: TimelineRenderInput

    var body: some View {
        ZStack(alignment: .bottom) {
            TimelineTableRepresentable(controller: controller, input: input)
            JumpToBottomPill(scroll: controller.scroll) { controller.scrollToBottom() }
        }
    }
}

/// The affordance parity §41.8 names, showing what arrived while the reader was away.
///
/// It is an affordance and not the mechanism: scrolling back to the bottom re-pins silently, so this
/// button is a shortcut for a reader who does not want to scroll, never the only way back.
struct JumpToBottomPill: View {

    let scroll: TimelineScrollState
    let jump: () -> Void

    var body: some View {
        if !scroll.isPinnedToBottom {
            Button(action: jump) {
                Label(scroll.unseenCount > 0 ? "\(scroll.unseenCount) new" : "Jump to latest",
                      systemImage: "arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - The representable

/// The `NSViewRepresentable` half. Deliberately thin: it hands the input and the render context to
/// the controller and the controller owns the table, because a SwiftUI view value preserves nothing
/// across a subtree unmount and the row heights and the scroll position have to survive one.
struct TimelineTableRepresentable: NSViewRepresentable {

    let controller: TimelineTableController
    let input: TimelineRenderInput

    /// Read here and handed down, because the rows below are hosted by AppKit: SwiftUI's environment
    /// does not cross an `NSHostingView` the table made itself, so this is the last point at which
    /// the context can be picked up and carried across.
    @Environment(\.timelineContext) private var renderContext

    func makeNSView(context: Context) -> NSScrollView {
        controller.apply(input, context: renderContext)
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        controller.apply(input, context: renderContext)
    }
}
