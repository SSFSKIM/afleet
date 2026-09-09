import AppKit
import Observation
import SwiftUI

/// Whether the keyboard is pointed **into the panel** (spec §8.5, §8.7; tracker 350).
///
/// One observable fact, owned above both children and read by one view. It exists because two
/// keys — Escape and Shift+Tab — are the composer's *and* are ordinary keys a full-screen TUI in a
/// Terminal pane needs: `claude --resume` reads Escape, an editor reads Shift+Tab. A
/// `.keyboardShortcut` is a command-table binding, and a command table is consulted before the
/// key event ever reaches the first responder; the pane's renderer answers `performKeyEquivalent`
/// with false for every ordinary key it has not bound, which is correct of it and is also why the
/// composer won the key. So the composer's bindings have to *not be there* while the panel holds
/// the keyboard, rather than being declined after the fact.
///
/// **The fact is computed here rather than reported by either child**, which is what keeps the
/// closer inside C5's shell: `PanelHostAPI` grows no member, `TerminalCore` and `TerminalPanel` are
/// untouched, and the composer reads a boolean it does not have to understand.
///
/// **Regions are geometric, and that is a measured choice, not a shortcut.** The natural test —
/// "is the first responder a descendant of the panel column's view?" — has no view to be a
/// descendant of: SwiftUI flattens `NSViewRepresentable`s into siblings under the window's one
/// hosting view, so a marker placed around the panel column is laid out *beside* the pane's
/// surface and not above it. Measured on this machine: with a marker installed as the panel's
/// `.background`, `paneSurface.isDescendant(of: marker)` is false and so is the same question
/// asked of the marker's superview. What the marker does carry is the column's rect, and the
/// surface's rect lies inside it. The descendant test is still asked first, for the case where a
/// real container does exist and for a region that is its own responder; the rect is the fallback
/// that holds under the flattening.
@MainActor
@Observable
final class PanelKeyboardFocus {

    /// The one fact. False whenever no panel is drawn, no window is key, or the responder is
    /// somewhere else — the composer's field, the sidebar, the timeline.
    private(set) var keyboardIsInPanel = false

    /// The drawn panel regions, weakly: a region is an `NSView` SwiftUI owns, and a region whose
    /// view has gone is not a place the keyboard can be.
    @ObservationIgnored private var regions: [WeakRegion] = []
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var responderObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var observedWindow: NSWindow?

    init() {}

    isolated deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        responderObservation?.invalidate()
    }

    // MARK: - The regions

    /// A panel region has appeared. Called by `PanelKeyboardRegion` as SwiftUI makes its view.
    func register(_ region: PanelKeyboardRegionView) {
        prune()
        guard !regions.contains(where: { $0.view === region }) else { return }
        regions.append(WeakRegion(view: region))
        refresh()
    }

    /// A panel region has gone. Idempotent: SwiftUI may dismantle a view it has already released.
    func withdraw(_ region: PanelKeyboardRegionView) {
        regions.removeAll { $0.view === region || $0.view == nil }
        refresh()
    }

    // MARK: - The recompute

    /// Recomputes the fact against whichever window is key.
    func refresh() { refresh(in: NSApp?.keyWindow) }

    /// Recomputes the fact against `window`, which production always resolves as the key window.
    ///
    /// Taking the window rather than reading it is what makes the fact assertable: a test builds an
    /// `NSWindow`, points the keyboard at a view in it and asks, without any window having to
    /// become key in a headless run — which is the one thing an XCTest process cannot arrange.
    func refresh(in window: NSWindow?) {
        prune()
        let next = Self.isInPanel(window: window, regions: regions.compactMap(\.view))
        guard next != keyboardIsInPanel else { return }
        keyboardIsInPanel = next
    }

    /// Whether the keyboard, in `window`, is inside one of `regions`.
    ///
    /// A region that spans its window — a popped-out panel, which is a window with nothing in it
    /// but a panel — answers yes on the window alone: there is no composer in that window for the
    /// keyboard to be in, and a window whose responder is the window itself is still a window whose
    /// every key belongs to the panel.
    static func isInPanel(window: NSWindow?, regions: [PanelKeyboardRegionView]) -> Bool {
        guard let window else { return false }
        let here = regions.filter { $0.window === window }
        guard !here.isEmpty else { return false }
        if here.contains(where: \.spansWindow) { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        return here.contains { region in
            if responder === region || responder.isDescendant(of: region) { return true }
            let area = region.convert(region.bounds, to: nil)
            let spot = responder.convert(NSPoint(x: responder.bounds.midX, y: responder.bounds.midY), to: nil)
            return area.contains(spot)
        }
    }

    // MARK: - The triggers

    /// Starts watching the two things that can move the fact: which window is key, and where that
    /// window's keyboard is pointed.
    ///
    /// AppKit posts no notification for a first-responder change, so the second is KVO on
    /// `NSWindow.firstResponder`. It is undocumented as observable and it *is* observed here on
    /// evidence rather than on hope: every `makeFirstResponder(_:)` — grant, hand-back and
    /// resignation alike — emits a change on this machine. The observation is re-aimed whenever the
    /// key window changes, because only the key window's responder can receive a key.
    ///
    /// Idempotent: a second call re-arms nothing.
    func startObserving() {
        guard windowObservers.isEmpty else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.observeKeyWindowResponder()
                    self.refresh()
                }
            }
            windowObservers.append(observer)
        }
        observeKeyWindowResponder()
        refresh()
    }

    private func observeKeyWindowResponder() {
        let window = NSApp?.keyWindow
        guard window !== observedWindow else { return }
        responderObservation?.invalidate()
        observedWindow = window
        responderObservation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func prune() { regions.removeAll { $0.view == nil } }

    private struct WeakRegion {
        weak var view: PanelKeyboardRegionView?
    }
}

/// A drawn panel's claim on the keyboard, as an `NSView` with no appearance and no behaviour.
///
/// It draws nothing and accepts nothing: its whole content is its identity, its window and its
/// rect. It never becomes first responder — `NSView` refuses by default and nothing here overrides
/// that — so the region can never be the thing it is asked about.
final class PanelKeyboardRegionView: NSView {

    /// Whether this region is its window entire — true for a popped-out panel window, false for the
    /// panel column beside a conversation.
    var spansWindow = false

    /// The fact this region reports into, so the static teardown — which is handed no
    /// representable — can withdraw from the right one.
    weak var focus: PanelKeyboardFocus?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A region registers before SwiftUI puts it in a window, and "which window" is half the
        // question. This is the moment the other half arrives.
        focus?.refresh()
    }
}

/// Installs a panel region wherever a panel is drawn: `.background(PanelKeyboardRegion(…))` on the
/// panel column, and on the popped-out panel scene.
///
/// A background rather than an overlay, so nothing here can take a click away from the panel.
struct PanelKeyboardRegion: NSViewRepresentable {

    let focus: PanelKeyboardFocus
    /// True for a window that holds nothing but a panel; see `PanelKeyboardFocus.isInPanel`.
    var spansWindow = false

    func makeNSView(context: Context) -> PanelKeyboardRegionView {
        let view = PanelKeyboardRegionView()
        view.spansWindow = spansWindow
        view.focus = focus
        focus.register(view)
        return view
    }

    /// A region that has just been laid out may have moved, and the rect is what the fallback test
    /// reads. Re-asking is cheap and idempotent — the fact only publishes when it changes.
    func updateNSView(_ view: PanelKeyboardRegionView, context: Context) {
        view.spansWindow = spansWindow
        view.focus = focus
        focus.refresh()
    }

    static func dismantleNSView(_ view: PanelKeyboardRegionView, coordinator: ()) {
        view.focus?.withdraw(view)
    }
}
