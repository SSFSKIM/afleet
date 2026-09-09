import Foundation
import SwiftUI
import AfleetCore
import FleetKit

/// The cards the engine is waiting on **for one run**, drawn on that run's node (root §8.8's item
/// 52, child spec D6, contract Y2).
///
/// **This leaf builds no card and writes no answer mapping.** It hosts C6.3's `DecisionCardView`
/// with a `DecisionAnswering` the session was handed, and that is the whole of Y2: one component,
/// one mapping, two hosts. A second card here would be a second opinion about what *Allow* means,
/// and the two hosts would send different bytes for the same button.
///
/// **The reservation set is the app's one set and the raise is the channel's fold** — both are
/// wired where the session is built. Two reservation sets would each succeed locally and both reach
/// the wire, and the second answer comes back `decisionGone`: an error about afleet's own
/// bookkeeping dressed as an error about the engine. And the engine sends no frame back for an
/// answer, so the fold's `signal(_:)` is the only thing that can move an item out of `.pending`.
///
/// **The cards are held, not built in a `ForEach` closure**, for the reason `AgentOutline`'s rows
/// are: `Mirror` does not enter a closure, and "this node hosts the shared component" is a claim
/// that has to be checkable.
struct AgentNodeDecisions: View {

    /// What the run is, so the card says whose permission this is (item 52). A subagent's request
    /// arrives on the channel like any other, and a card with no attribution leaves the user
    /// answering for work they cannot place.
    let label: String
    let cards: [DecisionCardView]

    /// The run's own type and errand, both already sanitised at the content boundary (D11).
    ///
    /// The type where the run named one, because that is what the user recognises; the description
    /// beside it, because two runs of one type are otherwise the same sentence twice. A run that has
    /// named neither says so rather than borrowing "Claude" — the request is the subagent's.
    static func label(of content: AgentNodeContent) -> String {
        let type = content.agentType.flatMap { $0.isEmpty ? nil : $0 } ?? AgentTranscriptHeader.unknownType
        return content.description.isEmpty ? type : "\(type) — \(content.description)"
    }

    /// The node's cards, built through C6.3's component and nothing else.
    ///
    /// `retraction` is deliberately **nil**: the registry is where a resolved refusal dialog's
    /// retracted uuids go so a *list* can filter them, and a node draws its own waiting cards rather
    /// than a list of the channel's rows. C6.3's own rule is that a host with no list to filter
    /// passes none.
    static func cards(for items: [DecisionItem], in channel: ChannelKey,
                      answering: DecisionAnswering, isStale: Bool) -> [DecisionCardView] {
        items.map {
            DecisionCardView(card: DecisionCard($0), presentation: .compact, in: channel,
                             isStale: isStale, answering: answering)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    card
                }
            }
        }
    }
}
