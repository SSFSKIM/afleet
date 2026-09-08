// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import AppKit
import SwiftUI
import TerminalCore

/// The pane's renderer, in one window at a time (spec Design §8).
///
/// This host registers a claimant while it is mounted and withdraws it when it goes away. The top
/// of the stack draws the surface; every other mounted host draws a statement instead, because an
/// `NSView` moved into a second hierarchy leaves the first one blank and says nothing about it.
struct PaneSurfaceHost: View {

    let pane: TerminalPane

    /// This host's place in the pane's claimant stack. `@State` and not the session's, because it
    /// is a fact about *this* mounted view and dies with it.
    @State private var claimant: PaneViewClaim.Claimant?

    var body: some View {
        Group {
            if let claimant, pane.viewClaim.holds(claimant) {
                PaneSurfaceView(surface: pane.surface)
            } else {
                elsewhere
            }
        }
        .onAppear {
            guard claimant == nil else { return }
            claimant = pane.viewClaim.register()
        }
        .onDisappear {
            // Identity-checked: SwiftUI may mount the new host before it dismantles this one, so a
            // withdrawal removes itself wherever it sits and never pops the top.
            if let claimant { pane.viewClaim.withdraw(claimant) }
            claimant = nil
        }
    }

    private var elsewhere: some View {
        VStack(spacing: 6) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("This pane is showing in another window.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The surface's own `NSView`, unwrapped. It carries no state of its own: the pane owns the
/// surface, the read loop and the child, and this only puts the view on screen.
struct PaneSurfaceView: NSViewRepresentable {

    let surface: GhosttyTerminalSurface

    func makeNSView(context: Context) -> NSView { surface.view }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
