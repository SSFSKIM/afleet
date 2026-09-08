import Foundation
import PanelHostAPI
import SwiftUI

/// The Workbench's Browser tab (contract X7), registered once by the app.
///
/// It owns the single `BrowserModel` — the window-wide tab set (Q5) — and hands each channel a
/// `BrowserTabSession` that holds nothing but that channel's quick-open state (Q20). Availability
/// is unconditional: a browser needs nothing from a channel to be a browser, and quick-open is the
/// one part that reads the channel at all.
@MainActor
public final class BrowserTab: PanelTab {

    public let id: PanelTabID = .browser
    public let model: BrowserModel

    public init(model: BrowserModel) {
        self.model = model
    }

    public var title: String { id.defaultTitle }
    public var systemImage: String { id.defaultSystemImage }

    public func isAvailable(in context: ChannelContext) -> Bool { true }

    public func makeSession(for context: ChannelContext) -> any PanelTabSession {
        BrowserTabSession(recentURLs: context.recentURLs)
    }

    public func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView {
        guard let session = session as? BrowserTabSession else { return AnyView(EmptyView()) }
        return AnyView(BrowserPanelView(model: model, session: session, surface: .panel))
    }
}
