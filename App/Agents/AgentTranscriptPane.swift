import Foundation
import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

/// One agent run's transcript, beside the tree (root §8.8, gate G2).
///
/// **C6.1's renderer over a filtered row set, and not a second model** (child spec D4). The rows are
/// the channel's own items whose `Provenance.agentID` names this run, handed to a
/// `NativeTimelineRenderer` the session owns through `TimelineRenderInput`. The app holds one
/// `ChannelTimelineModel` per channel and a second would be a second subscription to the same fold,
/// which is what the C6 cut exists to prevent — and the tree and the items have to come from one
/// read, or a node could point at an item this pane has not seen.
///
/// **A filter, never a reduction** (§7.3). Nothing here derives an item, re-orders one or edits one;
/// what the pane adds is its own framing above the rows.
struct AgentTranscriptPane: View {

    let model: AgentsModel

    /// The app, for the capabilities a row needs and for the one `ChannelTimelineRegistry`. Read
    /// from the environment rather than stored, which is `TimelineListView`'s route and the reason
    /// this leaf's tab stores neither a host nor a registry.
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        let run = model.selectedRun
        let input = run.map { model.input(of: $0, retainedBy: app?.timelines.model(for: model.channel).retraction) }
        if let sentence = Self.sentence(for: model.selection, rows: input?.rows.count ?? 0) {
            AgentTranscriptEmptyState(sentence: sentence)
        } else if let run, let input, let content = model.read.content(of: run) {
            VStack(alignment: .leading, spacing: 0) {
                AgentTranscriptHeader(content: content)
                model.transcript.view(for: input)
                    .environment(\.timelineContext, app.map { app in
                        Self.context(for: content, in: app,
                                     channel: app.timelines.model(for: model.channel), model: model)
                    })
            }
        }
    }

    /// Which sentence the pane draws instead of a transcript, or nil when it draws one.
    ///
    /// Pure and static, so what the pane says is a function of the selection and a count that a test
    /// can call without a render pass — the discipline the tree's `visibleRows` follows, and for the
    /// same reason: a rendered hierarchy can only be asked what is on screen, not why.
    ///
    /// Three sentences for three facts. "Nothing is open", "this run produced nothing" and "that run
    /// is not in this channel" are different things to be told, and a pane that worded any two of
    /// them the same would tell the user the wrong one.
    static func sentence(for selection: AgentsModel.Selection, rows: Int) -> String? {
        switch selection {
        case .none: AgentTranscriptEmptyState.noSelection
        case .unknownRun: AgentTranscriptEmptyState.unknownRun
        case .run: rows == 0 ? AgentTranscriptEmptyState.noItems : nil
        }
    }

    /// The context this pane's rows are drawn through — the app's objects, the channel's model, the
    /// collapse and edit state the session owns so a fold survives a body evaluation, and **the
    /// run's authorship**.
    ///
    /// Static and given the channel model rather than reaching for it, for `AgentRenderContext`'s
    /// reason: the value a test asserts about has to be the value the body draws through, and a
    /// second expression that assembled the same fields would prove nothing about this one.
    static func context(for content: AgentNodeContent, in app: AppModel, channel: ChannelTimelineModel,
                        model: AgentsModel) -> TimelineRenderContext {
        AgentRenderContext.context(in: app, channel: channel,
                                   collapse: model.transcriptCollapse, editing: model.transcriptEditing,
                                   authorship: authorship(of: content))
    }

    /// The run's authorship, as every row of its transcript draws it (item 38, gate G2).
    ///
    /// The same two answers the header states, and deliberately the same expressions: the framing at
    /// the top of the pane and the name over each message are one claim about whose words these are,
    /// and two derivations of it could disagree.
    static func authorship(of content: AgentNodeContent) -> TimelineAuthorship {
        TimelineAuthorship(author: AgentTranscriptHeader.author(of: content), badge: content.model)
    }
}

// MARK: - The pane's framing

/// Who the run's messages are by, and on which model (root §8.8, item 38).
///
/// **Supplied once, by the pane** (child spec D4). §8.8 wants a subagent's messages authored by the
/// agent type and never by "Claude", with the run's own model badge. That is framing over the whole
/// transcript, not a per-row edit: a row-level rewrite would mean editing C6.1's message rows, which
/// this leaf does not own, and would have to be re-derived by every row.
///
/// **Nothing here is status- or elapsed-shaped.** A node a metadata source created before any
/// `task_started` takes its status and instant from the projection's `taskRun` row and gets no
/// `endedAt` (tracker 407), so a running timer drawn from it would run for ever on a run that
/// finished before the app opened. The tree's row is where a run's status and elapsed span are
/// drawn, from the same content value, and this header states neither.
struct AgentTranscriptHeader: View {

    let content: AgentNodeContent

    /// A run whose type no source has named yet. Never "Claude": the messages are the subagent's,
    /// and naming the assistant would be the exact misattribution item 38 is about.
    static let unknownType = "Subagent"
    /// A run no assistant frame has arrived for. The badge is the run's own model, set by
    /// `agents.observe(assistantModel:agentID:)` from the run's own frames — nothing else on the
    /// wire carries it — so a run that has not spoken has no model, and borrowing the channel
    /// header's would state the wrong one with the same confidence as the right one.
    static let unknownModel = "Model not reported"

    static func author(of content: AgentNodeContent) -> String { content.agentType ?? unknownType }

    static func badge(of content: AgentNodeContent) -> String { content.model ?? unknownModel }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.author(of: content))
                .font(.headline)
            Text(Self.badge(of: content))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The three sentences the pane draws in place of a transcript, worded apart for the reason the
/// tree's two are: a user told "this run has produced nothing" when the truth is "that run is not in
/// this channel" has been misinformed about which of the two happened.
struct AgentTranscriptEmptyState: View {

    let sentence: String

    static let noSelection = "Select an agent run to read its transcript."

    static let noItems = "This run has produced nothing the transcript can show yet."

    static let unknownRun = "That agent run is not in this channel."

    var body: some View {
        VStack {
            Text(sentence)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
