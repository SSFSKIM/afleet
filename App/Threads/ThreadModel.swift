import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI

/// What a thread is opened on: §7.5's five anchors, and nothing else.
///
/// The table is closed, and each case carries the value the thread draws from rather than an id to
/// look one up by, so a thread cannot be opened on something the host cannot render. The task case
/// carries C6.3's own `TaskCardModel` because the Task thread's one action — *Stop* — is the card's,
/// and a second stop path in the thread would be the duplicate D15 exists to prevent.
@MainActor
enum ThreadAnchor {
    case toolDetail(ToolCallItem)
    case task(TaskCardModel)
    case decision(DecisionCard)
    case sideQuestion(SideQuestionThread)
    case sentFile(SentFileItem)

    var kind: ThreadKind {
        switch self {
        case .toolDetail: .toolDetail
        case .task: .task
        case .decision: .decision
        case .sideQuestion: .sideQuestion
        case .sentFile: .sentFile
        }
    }

    /// The line the thread's header draws. It names the tool, the task or the decision — never a
    /// path and never a session (§11).
    var title: String {
        switch self {
        case .toolDetail(let call): call.name
        case .task(let model): model.item.description
        case .decision(let card): card.summaryLine
        case .sideQuestion: "Side question"
        case .sentFile: ThreadReply.sentFileTool
        }
    }
}

/// The five kinds as a value a test and a header can both name.
enum ThreadKind: String, CaseIterable, Hashable, Sendable {
    case toolDetail, task, decision, sideQuestion, sentFile
}

/// How §7.5's two posting kinds address the main session.
enum ThreadReply {

    /// The sent-file item's tool, as it reads to a person. `WireReducer` builds the item from
    /// `mcp__afleet__send_user_file` (`FleetTimeline/Reduce/ItemBuilder.swift`), and the item keeps
    /// its tool-use id but not that name, so the prefix names the call rather than the MCP route.
    static let sentFileTool = "send_user_file"

    /// §7.5's `<short id>`: the tail of the tool-use id. The engine's ids are a fixed prefix and a
    /// long random body, so the tail is the part that distinguishes two calls in one turn.
    static func shortID(_ toolUseID: String) -> String {
        String(toolUseID.suffix(6))
    }

    /// `Re: <tool> <short id>: <text>` — the one line either posting thread sends.
    static func prefixed(tool: String, toolUseID: String, text: String) -> String {
        "Re: \(tool) \(shortID(toolUseID)): \(text)"
    }
}

/// One channel's Thread tab: the open thread, the half-written reply and the one seam either leaves
/// by (spec §7.5, D10; acceptance G2).
///
/// **One thread at a time, Slack-style.** `open(_:)` replaces whatever was open; there is no stack
/// and no set, because §7.5 says one and a tab that kept several would need a second selection
/// surface nothing in the design has.
///
/// **This object is the `PanelTabSession` the host retains per (tab, channel)**, which is what makes
/// the open thread survive a channel switch: SwiftUI discards a subtree's `@State` when the subtree
/// unmounts, and a channel switch unmounts this one.
///
/// **What it does not build (D10).** The reply field is one line of text. There is no router, no
/// `@`, no `!`, no attachments and no slash handling: every one of those is C6.2's composer, and a
/// second one here would be the duplicate that seam was recorded to prevent. The three answerable
/// kinds do not even send text — a reply *is* the card's textual outcome, so it goes through the
/// same `DecisionCard.answer(_:)` the buttons go through.
///
/// **Who opens a thread.** Nothing inside this tab does: an anchor arrives from the surface the user
/// clicked — the timeline's tool row, its decision row, *Ask on the side* on a message — and those
/// affordances are C6.1's and C6.2's. This child ships the tab, the five kinds and every reply
/// behaviour; the call sites arrive with the leaves that own the rows.
@MainActor
@Observable
final class ThreadModel: PanelTabSession {

    let channel: ChannelKey

    /// X5. Every answer, every send and every control request in this tab goes through it.
    @ObservationIgnored private let lifecycle: any LifecycleAPI

    /// The one object a card's answer leaves by, shared with the card's own buttons so a reply and a
    /// click cannot answer one request two different ways (contract Y2).
    let answering: DecisionAnswering

    private(set) var anchor: ThreadAnchor?

    /// The reply field's text. It lives here rather than in the view for the same reason the anchor
    /// does — the host retains this object across a channel switch and SwiftUI does not retain the
    /// view's storage.
    var draft: String = ""

    /// Why the last reply did not go, or nil. A card's own refusal renders through `answering`.
    private(set) var banner: RowBanner?

    /// A posted reply is on the wire. The Send button disables on it, so two presses post once.
    private(set) var isPosting = false

    init(channel: ChannelKey, lifecycle: any LifecycleAPI) {
        self.channel = channel
        self.lifecycle = lifecycle
        self.answering = DecisionAnswering(lifecycle: lifecycle)
    }

    // MARK: - One thread at a time

    /// Opens a thread, replacing whatever was open (§7.5, Slack-style). The draft goes with the
    /// thread it was written for: a half-typed reply carried into the next thread would post text
    /// about one anchor against another.
    func open(_ anchor: ThreadAnchor) {
        self.anchor = anchor
        draft = ""
        banner = nil
    }

    func close() {
        anchor = nil
        draft = ""
        banner = nil
    }

    /// §7.5's *Reply* column: four of the five kinds take one, and a task takes **stop only**.
    var offersReply: Bool {
        switch anchor {
        case .task, .none: false
        default: true
        }
    }

    // MARK: - Sending what the user typed

    /// The reply, on its way to wherever this kind's reply goes.
    ///
    /// Three of the five answer the card in hand through `DecisionCard.answer(_:)`; two post a plain
    /// line to the main session; the task kind takes no reply at all. Nothing here constructs an
    /// `InboundAnswer` — the mapping does — and nothing here routes the text.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let anchor else { return }
        switch anchor {
        case .decision(let card):
            guard let action = card.replyAction(text: text) else {
                banner = RowBanner(text: "This decision cannot be answered with a reply.")
                return
            }
            banner = nil
            draft = ""
            answering.send(action, on: card, in: channel)
        case .toolDetail(let call):
            post(ThreadReply.prefixed(tool: call.name, toolUseID: call.toolUseID, text: text))
        case .sentFile(let sent):
            post(ThreadReply.prefixed(tool: ThreadReply.sentFileTool, toolUseID: sent.toolUseID, text: text))
        case .sideQuestion(let thread):
            draft = ""
            Task { await thread.ask(text, through: lifecycle, on: channel) }
        case .task:
            // §7.5: stop only. The card's own *Stop* is the action; there is no reply to post.
            break
        }
    }

    /// D10's plain text send: `perform(.send(UserInput(text:)))` and nothing else — no router, no
    /// attachments, no composer.
    private func post(_ line: String) {
        guard !isPosting else { return }
        isPosting = true
        draft = ""
        Task { [lifecycle, channel] in
            defer { self.isPosting = false }
            do {
                _ = try await lifecycle.perform(.send(UserInput(text: line)), on: channel)
                self.banner = nil
            } catch let error as LifecycleError {
                self.banner = RowBanner(error)
            } catch {
                self.banner = RowBanner(text: "The reply failed: \(type(of: error)).")
            }
        }
    }
}

extension DecisionCard {

    /// §7.5's Decision row: *replying instead of clicking is the card's textual outcome*.
    ///
    /// It picks an action out of the closed set the buttons already use — a permission card denies
    /// with the text as the `message`, a plan card rejects with it as feedback, a question card
    /// answers *Other* with it — so the answer a reply produces is the answer `DecisionCard.answer(_:)`
    /// produces and this child still has exactly one mapping (spec D10, item 37).
    ///
    /// Nil for a card whose kind §7.5 gives no textual outcome: an elicitation, either dialog, and a
    /// payload this build does not model. Those are answered by their own controls or not at all.
    func replyAction(text: String) -> DecisionAction? {
        switch payload {
        case .permission:
            .deny(message: text)
        case .plan:
            .rejectPlan(feedback: text)
        case .question(let tool):
            // *Other* on the first question the engine asked. `answers` is keyed by raw question
            // text (anchor 9), so a reply needs a question to key itself by; an ask that carried
            // none cannot be answered by typing.
            QuestionPrompt.list(in: tool.fields.inputObject).first.map { prompt in
                .answerQuestion([QuestionResponse(question: prompt.question, selections: [text])])
            }
        case .elicitation, .dialog, .unmodelled:
            nil
        }
    }
}
