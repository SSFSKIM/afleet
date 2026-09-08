import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// The Thread tab, drawn: one thread, its anchor's content, and the one thing §7.5 lets the user do
/// with it (spec §7.5, acceptance G2).
///
/// Each kind draws its own content and its own action word, and the reply control is the same one
/// line of text everywhere it appears — D10's seam, kept narrow on purpose so C6.2's composer has
/// somewhere to land later without a second implementation being in the way.
struct ThreadView: View {

    let model: ThreadModel

    /// **The content scrolls; the header and the reply do not.**
    ///
    /// A thread's content is unbounded — a tool call's whole input and whole output, a plan, a
    /// question card, a side question's accumulated exchanges — and the panel column it is drawn in
    /// adds no scroll container of its own, so a `VStack` alone puts the overflow somewhere the user
    /// cannot reach. That is worse than an awkward layout for this tab in particular: the reply
    /// field is the last thing in the stack, so the one control §7.5 gives the thread is the first
    /// thing to go off the bottom. Keeping the header and the reply outside the scroll view is what
    /// makes them reachable whatever the anchor holds.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let anchor = model.anchor {
                header(anchor)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        content(anchor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.offersReply { replyField(anchor) }
                if let banner = model.banner {
                    Text(banner.text).font(.caption).foregroundStyle(.secondary)
                }
                if let banner = model.answering.banner {
                    Text(banner.text).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No thread open.").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - The thread

    @ViewBuilder
    private func header(_ anchor: ThreadAnchor) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ThreadView.name(of: anchor.kind)).font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(anchor.title).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Close") { model.close() }
        }
    }

    /// The five kinds' content, as §7.5's *Content* column words each one.
    @ViewBuilder
    private func content(_ anchor: ThreadAnchor) -> some View {
        switch anchor {
        case .toolDetail(let call):
            toolDetail(call)
        case .task(let task):
            // Stop only: the task card's own action, hosted rather than reimplemented (D15).
            TaskCardView(model: task)
        case .decision:
            // The fold's card, not the anchor's snapshot: what §8.4 draws is `DecisionItem.state`,
            // and a card answered anywhere would otherwise go on offering its buttons here.
            if let card = model.openDecision {
                DecisionCardView(card: card, presentation: .full, in: model.channel,
                                 answering: model.answering)
            }
        case .sideQuestion(let thread):
            sideQuestion(thread)
        case .sentFile(let sent):
            sentFile(sent)
        }
    }

    /// §7.5: full input, full output, the structured result and the call's timing.
    @ViewBuilder
    private func toolDetail(_ call: ToolCallItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(call.name) \(ThreadReply.shortID(call.toolUseID))")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if let timing = ThreadView.timing(of: call) {
                Text(timing).font(.caption).foregroundStyle(.secondary)
            }
            field("Input", ThreadView.json(call.rawInput))
            if let result = call.result { field("Output", ThreadView.json(result)) }
            if let structured = call.structuredResult {
                field("Structured result", ThreadView.json(structured))
            }
        }
    }

    /// §7.5: the question and answer pairs, and nothing tool-shaped.
    @ViewBuilder
    private func sideQuestion(_ thread: SideQuestionThread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(thread.anchorText).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(thread.exchanges.enumerated()), id: \.offset) { _, exchange in
                VStack(alignment: .leading, spacing: 2) {
                    Text(exchange.question).font(.callout.weight(.semibold))
                    Text(exchange.response ?? "No answer came back.").font(.callout)
                    if let notice = exchange.fallbackNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let banner = thread.banner {
                Text(banner.text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// §7.5: the preview and the caption.
    @ViewBuilder
    private func sentFile(_ sent: SentFileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = sent.caption { Text(caption).font(.callout) }
            Text("\(sent.files.count) file(s)").font(.caption).foregroundStyle(.secondary)
            if sent.delivered == true {
                Text("Delivered").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// One line of text, and the action word this kind uses for it. No router, no `@`, no `!`, no
    /// attachments — every one of those is C6.2's composer (D10).
    @ViewBuilder
    private func replyField(_ anchor: ThreadAnchor) -> some View {
        HStack(spacing: 8) {
            TextField(ThreadView.placeholder(for: anchor.kind), text: draftBinding)
                .textFieldStyle(.roundedBorder)
            Button(ThreadView.action(for: anchor.kind)) { model.send() }
                .disabled(ThreadView.isBlocked(anchor, model: model))
        }
    }

    /// Whether this kind's one action is already on the wire. Each kind leaves by its own seam and
    /// each keeps its own in-flight flag, so the disable has to ask the anchor: `isPosting` covers
    /// the two posting kinds alone, and a side question that read it would offer *Ask* again while
    /// the first ask was still out — losing the second question, which `ThreadModel.send()` can
    /// only refuse.
    static func isBlocked(_ anchor: ThreadAnchor, model: ThreadModel) -> Bool {
        switch anchor {
        case .sideQuestion(let thread):
            return thread.isAsking
        case .decision:
            // Nothing to send while this request's answer is on the wire, and nothing to send at
            // all once it is settled: D12's card is no longer answerable, and a reply is an answer.
            guard let card = model.openDecision, case .pending = card.state else { return true }
            return model.answering.isAnswering(card.requestID)
        default:
            return model.isPosting
        }
    }

    private var draftBinding: Binding<String> {
        let model = model
        return Binding(get: { model.draft }, set: { model.draft = $0 })
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    // MARK: - Words

    static func name(of kind: ThreadKind) -> String {
        switch kind {
        case .toolDetail: "Tool"
        case .task: "Task"
        case .decision: "Decision"
        case .sideQuestion: "Side question"
        case .sentFile: "Sent file"
        }
    }

    /// The action word. A side question is *asked*; every other reply is *sent*.
    static func action(for kind: ThreadKind) -> String {
        kind == .sideQuestion ? "Ask" : "Send"
    }

    static func placeholder(for kind: ThreadKind) -> String {
        switch kind {
        case .decision: "Reply instead of choosing"
        case .sideQuestion: "Ask on the side"
        default: "Reply in the main session"
        }
    }

    /// What the thread says about when the call ran. The item carries its start; a call still
    /// running says so, because a card that showed a duration it does not have would be inventing
    /// one.
    static func timing(of call: ToolCallItem) -> String? {
        guard let timestamp = call.timestamp else { return nil }
        let started = timestamp.formatted(date: .omitted, time: .standard)
        return call.status == .running ? "Started \(started), still running" : "Started \(started)"
    }

    static func json(_ value: JSONValue) -> String {
        guard let data = try? value.canonicalData(), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
