import Foundation
import SwiftUI

/// Per-channel runtime state a tab owns: a terminal's PTY and panes, an editor's open
/// buffers and cursors. It is a reference type the **host retains** for as long as the channel
/// is registered, because SwiftUI owns `@State`, `@StateObject` and representable coordinators
/// through the rendered hierarchy and discards them when a subtree unmounts. A tab that kept
/// its pane in `@State` would lose it on every channel switch; the session is where it goes.
@MainActor public protocol PanelTabSession: AnyObject {}

/// Which of the window surfaces a panel is being drawn on (contract X7, amended at C7.6's fix
/// wave B).
///
/// A panel is rendered in the main window's column **and** in a popped-out window, and until this
/// existed neither one could tell which it was. That is harmless for a panel whose view is a
/// function of its session, and wrong for one that owns an `NSView`: an `NSView` has one superview,
/// so a web view drawn from both places is drawn in whichever asked last, and the other surface
/// shows an empty rectangle with no way to say why.
public enum PanelSurface: String, Sendable, Equatable, CaseIterable {
    case panel
    case poppedOutWindow
}

/// One panel tab. `id` is an instance property rather than `static` so `any PanelTab` can read
/// it without a generic. `makeView` returns `AnyView` because the host stores a heterogeneous
/// collection, and an `associatedtype Body: View` would make the protocol non-existential and
/// force a type-erasing wrapper anyway.
@MainActor public protocol PanelTab: AnyObject {
    var id: PanelTabID { get }
    var title: String { get }
    var systemImage: String { get }
    func isAvailable(in context: ChannelContext) -> Bool
    /// Called once per channel; the host retains the result and passes it back on every render.
    func makeSession(for context: ChannelContext) -> any PanelTabSession
    /// `surface` is where this instance is being drawn. A tab that owns a view rather than
    /// describing one needs it: see `PanelSurface`.
    func makeView(session: any PanelTabSession, context: ChannelContext,
                  surface: PanelSurface) -> AnyView
}
