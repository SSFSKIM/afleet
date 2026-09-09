import Foundation
import Observation
import AfleetCore
import FleetKit

/// Which run each channel's Agents pane has open — app-scoped, one instance, keyed by `ChannelKey`
/// (child spec D5).
///
/// **Why it is not on the tab's session.** Contract Y4's `show(run:in:)` is synchronous and
/// app-scoped, and the thing it has to reach — the Agents session for that channel — is built
/// lazily by the host, on first render. A chip clicked in a channel whose Agents tab has never been
/// opened therefore has no session to write to. The store is what the navigation writes instead,
/// and what the session reads when it appears and observes thereafter, so the selection survives
/// the gap. It is the same shape as `ComposerRegistry` and `AppModel.decisions`: constructed once
/// in the composition root and handed to the tab at its registration.
@MainActor
@Observable
final class AgentSelectionStore {

    private var runs: [ChannelKey: AgentRunID] = [:]

    /// Nil clears the channel's selection rather than storing an absence, so a channel that has
    /// never been navigated to and one whose selection was cleared read the same.
    func select(_ run: AgentRunID?, in key: ChannelKey) {
        if let run { runs[key] = run } else { runs.removeValue(forKey: key) }
    }

    func selection(in key: ChannelKey) -> AgentRunID? { runs[key] }
}
