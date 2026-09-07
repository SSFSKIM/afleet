// The consumer check. This file imports `PanelHostAPI` and `SwiftUI` and nothing else, on
// purpose: what it proves is the boundary that matters — a panel tab can be written without
// importing FleetKit and without importing ClaudeWire. SwiftUI is unavoidable because
// `makeView` returns `AnyView` and `PanelHostAPI` imports SwiftUI rather than re-exporting it.
//
// It is a compile-time assertion, so it declares a conformance and no test case. The suites
// that build a `ChannelKey` or a `SeenURL` import FleetKit as well; this one must not.
import PanelHostAPI
import SwiftUI

@MainActor final class ConsumerTabSession: PanelTabSession {
    var visitCount = 0
}

@MainActor final class ConsumerTab: PanelTab {
    let id: PanelTabID = .files
    var title: String { id.defaultTitle }
    var systemImage: String { id.defaultSystemImage }

    func isAvailable(in context: ChannelContext) -> Bool { true }

    func makeSession(for context: ChannelContext) -> any PanelTabSession { ConsumerTabSession() }

    func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView {
        (session as? ConsumerTabSession)?.visitCount += 1
        return AnyView(Text(verbatim: title))
    }
}
