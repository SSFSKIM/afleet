import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

// MARK: - The decision row, mounted on the render context

/// Contract Y1's `decision` row as the channel's list draws it — the card, answerable, with the
/// paths its input names as links (contract Y7, gate G7).
///
/// **Why this row exists beside `DecisionRowView`.** That row is the readable half another leaf
/// shipped while the per-row capability carrier did not exist: it draws the title, the summary and
/// D12's reading, and offers nothing, because `DecisionCardView` needs the request's `ChannelKey`
/// and a `DecisionAnswering` and a builder is handed neither. This row is the mount that supplies
/// them. It draws the other leaf's card and answers through the other leaf's mapping; what it adds
/// is the wiring, which is C6.1's half of the seam.
struct DecisionRow: View {

    let row: TimelineRow

    @Environment(\.timelineContext) private var context

    /// The object this row's answer leaves by, built once from the context.
    ///
    /// `@State` and not a per-evaluation construction: the object carries the refusal banner and a
    /// card evaluates its body many times a second while anything else on the channel streams, so a
    /// fresh one per evaluation would blank the reason an answer did not go the instant it appeared.
    @State private var answering: DecisionAnswering?

    var body: some View {
        DecisionRowContent(row: row, context: context, answering: answering)
            .task {
                // Built here rather than at `init`, because the context is an environment value and
                // there is none to read until the row is in the timeline's subtree.
                if answering == nil { answering = context?.makeAnswering() }
            }
    }
}

/// What the decision row draws, over capabilities handed in rather than read from the environment.
///
/// Split out so the mount is a value a test can construct and drive: `@Environment` and `@State`
/// read their defaults outside a render pass, so a row that only read them could not be shown to
/// answer anything.
struct DecisionRowContent: View {

    let row: TimelineRow
    let context: TimelineRenderContext?
    let answering: DecisionAnswering?

    var body: some View {
        switch row.item {
        case .decision(let item):
            if let context, let answering {
                answerable(DecisionCard(item), in: context, through: answering)
            } else {
                // No capabilities: an archived channel, or a row drawn outside the timeline's
                // subtree. The readable half is what is honest there — an affordance that cannot
                // send is worse than none, because it looks like the request was answered.
                DecisionRowView(row: row)
            }
        default:
            // The registry routes only `.decision` here, so this is unreachable in the app. It draws
            // the placeholder rather than nothing, for the registry default's own reason: a row that
            // vanishes is a row nobody can see is missing.
            PlaceholderRowView(row: row)
        }
    }

    /// The card, and beneath it the paths its tool input names.
    ///
    /// **The card is not passed `isActive`.** This is a list, and a keyboard default action is
    /// singular: a card that claimed Return because nothing told it not to would let one Return
    /// answer whichever row registered first. The Thread tab, which shows exactly one card the user
    /// opened, is the host that marks one active.
    @ViewBuilder
    private func answerable(_ card: DecisionCard,
                            in context: TimelineRenderContext,
                            through answering: DecisionAnswering) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DecisionCardView(card: card,
                             presentation: .full,
                             in: context.key,
                             isStale: context.isOverlayStale,
                             answering: answering,
                             retraction: context.retraction,
                             composer: context.composer,
                             agents: context.neighbourhood.agents)
            if let link = Self.linkedPath(of: card) {
                FileLinkLabel(path: link.path, line: link.line, context: context)
            }
        }
        .padding(.vertical, 2)
    }

    /// The path this card's request names, as gate G3 reads a tool row's: the same
    /// `FileLink.paths(in:)` derivation, over the input the engine is asking about.
    ///
    /// **One path, because every branch of that derivation names at most one** — a `Read`, an
    /// `Edit`, a `Write`, a `Glob` and a `Grep` each carry a single path, and every other input
    /// carries none. Singular rather than a list so the link is drawn by a branch and not by a
    /// `ForEach`, which keeps the affordance assertable: reflection does not enter a `ForEach`'s
    /// content closure, and a link the tests could only reach by rebuilding it is a link whose
    /// presence in the row nothing checks.
    ///
    /// The link is drawn beside the card rather than inside it because the card is another leaf's
    /// file, drawn from two hosts; this is the host that has a link capability to draw it with.
    static func linkedPath(of card: DecisionCard) -> (path: String, line: Int?)? {
        switch card.payload {
        case .permission(let tool), .question(let tool), .plan(let tool):
            return FileLink.paths(in: tool.typedInput).first
        case .elicitation, .dialog, .unmodelled:
            return nil
        }
    }
}
