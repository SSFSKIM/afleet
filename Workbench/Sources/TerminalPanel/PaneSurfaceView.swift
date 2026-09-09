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

/// The container one mounted representable owns, and the surface view it holds while it holds it.
///
/// A container of its own per representable is what keeps two hosts' lifetimes from crossing over
/// one `NSView`. SwiftUI may make the incoming host's view before it dismantles the outgoing one's,
/// and a teardown that removed the surface view unconditionally would take it out of the hierarchy
/// the incoming host had already put it in — with nothing left to notice: `updateNSView` is handed
/// the container, and the container it is handed is not the one the view is missing from.
final class PaneSurfaceContainer: NSView {

    /// One container that has taken a surface view, and the view it took. Both weak: a container
    /// SwiftUI has dropped is not a host anything may be handed back to.
    private struct Mounted {
        weak var container: PaneSurfaceContainer?
        weak var surfaceView: NSView?
    }

    /// Every container currently standing over a surface, oldest first — the AppKit counterpart of
    /// the claimant stack, and the only way an outgoing host can name the host that is still there.
    private static var mounted: [Mounted] = []

    /// Whether the surface this container has taken is still owed the keyboard. A container is
    /// made and adopts before SwiftUI puts it in a window, so the request outlives the moment.
    private(set) var owesSurfaceFocus = false

    /// The surface view this container took, so a focus request paid later names that view and not
    /// whatever happens to be in the hierarchy by then.
    private weak var adoptedSurfaceView: NSView?

    /// How many times this container has actually handed the keyboard to its surface. Diagnostic:
    /// it exists so "adopting asks for the focus" is an assertion rather than a recollection.
    private(set) var focusHandoffCount = 0

    /// Takes the surface view, from whichever container was holding it, **and takes the keyboard
    /// with it**. This is the adoption that answers a person asking for this pane: SwiftUI makes a
    /// container for it, and a pane the user asked for is a pane they mean to type into.
    ///
    /// The two arms below take the same view and leave the keyboard alone, because neither of them
    /// is a request. A hand-off and a repair happen while the user is somewhere else entirely — the
    /// composer, most often — and moving the focus there would send the next keystrokes into
    /// whatever the pane is running.
    func adopt(_ surfaceView: NSView) {
        adopt(surfaceView, takingFocus: true)
    }

    private func adopt(_ surfaceView: NSView, takingFocus: Bool) {
        guard surfaceView.superview !== self else { return }
        surfaceView.removeFromSuperview()
        surfaceView.frame = bounds
        surfaceView.autoresizingMask = [.width, .height]
        addSubview(surfaceView)
        Self.record(self, over: surfaceView)
        // The view moving here is the one moment the focus question is knowable: nothing above this
        // sees that the keyboard is still pointed at whatever it was pointed at before.
        adoptedSurfaceView = surfaceView
        owesSurfaceFocus = takingFocus
        if takingFocus { takeSurfaceFocus() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeSurfaceFocus()
    }

    /// Makes the surface first responder, if one is owed the keyboard and there is a window to ask.
    private func takeSurfaceFocus() {
        guard owesSurfaceFocus, let window, let surfaceView = adoptedSurfaceView,
              surfaceView.superview === self
        else { return }
        owesSurfaceFocus = false
        focusHandoffCount += 1
        window.makeFirstResponder(surfaceView)
    }

    /// Takes it only while nobody holds it. This is the repair arm: a host that is still mounted
    /// after the host that held the view went away puts it back, and a host that is merely being
    /// laid out again never pulls it out of a newer one.
    func adoptIfUnheld(_ surfaceView: NSView) {
        guard surfaceView.superview == nil else { return }
        adopt(surfaceView, takingFocus: false)
    }

    /// Removes the surface view **only if this container is still the one holding it** — the whole
    /// of the overlap rule: a host removes what it added, and never what its successor added — and
    /// then **hands it to whichever host is still standing**.
    ///
    /// The hand-off is the other ordering, and the repair arm alone does not cover it: a surviving
    /// host laid out *before* this teardown saw the view held here and left it alone, correctly,
    /// and there is no second update owed to it. Dropping the view there leaves the pane blank in
    /// the window that still shows it, for as long as nothing else happens to redraw.
    /// **The stack is left before the guard is asked.** A container is dismantled whether or not it
    /// still holds the view, and one that lost the view to a newer host earlier is exactly the
    /// container that returns here — so a forget below the guard left a dismantled host standing in
    /// the list, to be chosen as the survivor by the next hand-off while the host that really was
    /// drawing the pane got nothing.
    func relinquish(_ surfaceView: NSView) {
        Self.forget(self)
        guard surfaceView.superview === self else { return }
        surfaceView.removeFromSuperview()
        owesSurfaceFocus = false
        adoptedSurfaceView = nil
        Self.survivingHost(over: surfaceView)?.adopt(surfaceView, takingFocus: false)
    }

    /// The newest container other than this one that is standing over `surfaceView` **in a window**.
    ///
    /// The window is the whole of what "still standing" means to a person: a container SwiftUI has
    /// released without dismantling is in none, and handing it the pane puts the surface in a view
    /// hierarchy nothing draws while the window still showing the tab shows an empty pane.
    private static func survivingHost(over surfaceView: NSView) -> PaneSurfaceContainer? {
        prune()
        return mounted.last { $0.surfaceView === surfaceView && $0.container?.window != nil }?.container
    }

    private static func record(_ container: PaneSurfaceContainer, over surfaceView: NSView) {
        prune()
        mounted.removeAll { $0.container === container }
        mounted.append(Mounted(container: container, surfaceView: surfaceView))
    }

    private static func forget(_ container: PaneSurfaceContainer) {
        mounted.removeAll { $0.container === container }
    }

    /// Drops the entries whose container or surface has been deallocated. There is no deinit to do
    /// this from — a container SwiftUI drops without dismantling is released with nothing said —
    /// so the list is swept whenever it is touched.
    private static func prune() {
        mounted.removeAll { $0.container == nil || $0.surfaceView == nil }
    }
}

/// The surface's `NSView`, in a container of this representable's own. It carries no state beyond
/// that container: the pane owns the surface, the read loop and the child, and this only puts the
/// view on screen. The claim decides which host is eligible to render; where the view is attached
/// is this type's, and the two are not the same question (spec Design §8).
struct PaneSurfaceView: NSViewRepresentable {

    let surface: GhosttyTerminalSurface

    /// The surface, held so the static teardown — which is handed no representable — can name the
    /// view it is being asked to release.
    @MainActor
    final class Coordinator {
        let surface: GhosttyTerminalSurface

        init(surface: GhosttyTerminalSurface) { self.surface = surface }
    }

    func makeCoordinator() -> Coordinator { Coordinator(surface: surface) }

    func makeNSView(context: Context) -> PaneSurfaceContainer { makeContainer() }

    func updateNSView(_ container: PaneSurfaceContainer, context: Context) {
        container.adoptIfUnheld(surface.view)
    }

    static func dismantleNSView(_ container: PaneSurfaceContainer, coordinator: Coordinator) {
        container.relinquish(coordinator.surface.view)
    }

    /// This representable's own container, holding the surface view. Named so that "each host gets
    /// its own" is an assertion rather than a claim about code SwiftUI alone can call.
    func makeContainer() -> PaneSurfaceContainer {
        let container = PaneSurfaceContainer()
        container.adopt(surface.view)
        return container
    }
}
