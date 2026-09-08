import AppKit
import SwiftUI
import FleetKit

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
