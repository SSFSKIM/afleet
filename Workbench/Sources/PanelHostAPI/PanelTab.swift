import Foundation
import SwiftUI

/// Per-channel runtime state a tab owns: a terminal's PTY and panes, an editor's open
/// buffers and cursors. It is a reference type the **host retains** for as long as the channel
/// is registered, because SwiftUI owns `@State`, `@StateObject` and representable coordinators
/// through the rendered hierarchy and discards them when a subtree unmounts. A tab that kept
/// its pane in `@State` would lose it on every channel switch; the session is where it goes.
@MainActor public protocol PanelTabSession: AnyObject {}

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
    func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView
}
