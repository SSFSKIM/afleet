// C7.5 spec Design §10: the tab X7's host registers, and where the session is activated.
import Foundation
import SwiftUI
import PanelHostAPI

/// The Files tab.
///
/// `.files` is held by nothing, so the app registers this with a plain `register` rather than
/// X7's unregister-then-register handover. Everything the panel remembers lives on the
/// `FilesPanelSession` the host retains per (tab, channel); the views below hold only what SwiftUI
/// may discard without loss — which row is expanded, and the `NSView` a representable made.
@MainActor
public final class FilesTab: PanelTab {

    public let id: PanelTabID = .files
    public var title: String { id.defaultTitle }
    public var systemImage: String { id.defaultSystemImage }

    public init() {}

    /// Available for every channel: a channel has a working directory, and that is the whole of
    /// what this tab needs.
    public func isAvailable(in context: ChannelContext) -> Bool { true }

    /// Builds the session and **activates** it.
    ///
    /// Design §9 puts the two link-target registrations at the moment the session is created, and
    /// this is that moment: `makeSession` is called once per (tab, channel) by the host, while
    /// `activate()` is `async` and `makeSession` is not, so the activation is spawned here. Doing
    /// it from the view instead would register a second pair of targets on every remount, because
    /// a channel switch unmounts and remounts the subtree while the host keeps this session.
    public func makeSession(for context: ChannelContext) -> any PanelTabSession {
        let session = FilesPanelSession(context: context)
        Task { await session.activate() }
        return session
    }

    public func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView {
        guard let session = session as? FilesPanelSession else { return AnyView(EmptyView()) }
        return AnyView(FilesPanelView(session: session))
    }
}
