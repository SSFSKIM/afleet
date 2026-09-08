import AppKit
import SwiftUI
import FleetKit

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

    func makeNSView(context: Context) -> NSScrollView {
        controller.apply(input)
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        controller.apply(input)
    }
}
