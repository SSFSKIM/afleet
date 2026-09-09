// TerminalPanel: owned by C7.4 (docs/doperpowers/specs/2026-09-09-c7.4-terminal-panel.md).
import AppKit
import Observation
import SwiftUI
import TerminalCore

/// The pane's renderer, in one window at a time (spec Design §8).
///
/// This host registers a claimant while it is mounted and withdraws it when it goes away. The top
/// of the stack draws the surface; every other mounted host draws a statement instead, because an
/// `NSView` moved into a second hierarchy leaves the first one blank and says nothing about it.
struct PaneSurfaceHost: View {

    let pane: TerminalPane

    /// This host's claim, and the pane it holds it against. `@State` and not the session's,
    /// because it is a fact about *this* mounted view and dies with it.
    @State private var holder = PaneClaimHolder()

    var body: some View {
        Group {
            if holder.holdsView(of: pane) {
                PaneSurfaceView(surface: pane.surface)
            } else {
                elsewhere
            }
        }
        .onAppear { holder.register(for: pane) }
        // A host handed a different pane re-registers against it, and the holder withdraws from
        // the pane it registered with. The selected pane's subtree carries the pane's identity, so
        // an ordinary selection change rebuilds this host rather than arriving here — this is what
        // makes the remaining cases safe rather than what carries the selection.
        .onChange(of: ObjectIdentifier(pane)) { holder.register(for: pane) }
        .onDisappear { holder.withdraw() }
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

/// One mounted host's place in one pane's claimant stack — the claimant **and the pane it was
/// registered against**, kept together so a withdrawal can never name a different stack.
///
/// The pair is the whole of it. SwiftUI reuses a host's `@State` for the next value of its
/// parameters, so a holder that remembered only its `Claimant` would ask a *different* pane's
/// stack whether it held the view — and be told no, drawing "showing in another window" over the
/// pane the user just selected — while its withdrawal took a claim out of a stack it never
/// entered and left one behind in the stack it did.
@MainActor
@Observable
final class PaneClaimHolder {

    private struct Registration {
        let pane: TerminalPane
        let claimant: PaneViewClaim.Claimant
    }

    private var registration: Registration?

    /// Registers this host against `pane`, withdrawing first from whatever pane it last held.
    /// Registering again for the same pane changes nothing: a host holds one claim at a time.
    func register(for pane: TerminalPane) {
        if let registration {
            guard registration.pane !== pane else { return }
            registration.pane.viewClaim.withdraw(registration.claimant)
        }
        registration = Registration(pane: pane, claimant: pane.viewClaim.register())
    }

    /// Withdraws from the pane this host registered with, and from no other. Idempotent.
    func withdraw() {
        guard let registration else { return }
        registration.pane.viewClaim.withdraw(registration.claimant)
        self.registration = nil
    }

    /// Whether this host is the one drawing `pane`: false while it holds nothing, false while the
    /// pane it holds is not the one being drawn, and false while another host holds the view.
    func holdsView(of pane: TerminalPane) -> Bool {
        guard let registration, registration.pane === pane else { return false }
        return pane.viewClaim.holds(registration.claimant)
    }
}

/// The surface's own `NSView`, unwrapped. It carries no state of its own: the pane owns the
/// surface, the read loop and the child, and this only puts the view on screen.
struct PaneSurfaceView: NSViewRepresentable {

    let surface: GhosttyTerminalSurface

    func makeNSView(context: Context) -> NSView { surface.view }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
