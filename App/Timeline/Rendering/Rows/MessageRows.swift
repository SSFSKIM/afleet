import Foundation
import SwiftUI
import ClaudeWire
import FleetKit

// MARK: - Shared chrome

/// The frame every row of the conversation shares: an author line, a timestamp and a body.
///
/// One layout rather than eleven, because the eleven kinds differ in what they say and not in how a
/// reader scans them — parity §41.16.3 makes the same point about the terminal's gutters, where the
/// indentation depth is the only cue for nesting.
struct RowFrame<Body: View>: View {

    let author: String
    var badge: String?
    var timestamp: Date?
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: () -> Body

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 6) {
                Text(author).font(.caption.weight(.semibold))
                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let timestamp {
                    Text(timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// Markdown, drawn through the pipeline §5 owns, and never a second parser.
///
/// `RenderedRow` is the type that already knows how to split a source into settled blocks, draw a
/// table through TextKit and leave everything else to SwiftUI; a row builder that re-implemented any
/// of that would be a second renderer with its own bugs. The parse is cached by content, so building
/// this value on every body evaluation costs a dictionary lookup.
struct MarkdownBody: View {

    let key: String
    let source: String

    var body: some View {
        TimelineMarkdownRow(row: settled)
    }

    private var settled: RenderedRow {
        var row = RenderedRow(key: key, source: source)
        row.settle(markdown: .shared, highlighter: .shared)
        return row
    }
}

// MARK: - The three message kinds

/// The person's own message (§8): right-aligned authorship, its text through the markdown pipeline,
/// and its attachments named rather than inlined.
struct UserMessageRow: View {

    let item: UserMessageItem

    var body: some View {
        RowFrame(author: "You", timestamp: item.timestamp, alignment: .trailing) {
            MarkdownBody(key: item.id.key, source: MessageText.text(of: item.blocks, fallback: item.text))
            let attachments = MessageText.attachments(in: item.blocks)
            if !attachments.isEmpty {
                Text(attachments.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The model's message: its badge from `AssistantMessageItem.model`, its text blocks through §5, its
/// thinking blocks folded into the disclosure below, and a superseded chain marked as retracted.
struct AssistantMessageRow: View {

    let item: AssistantMessageItem

    @Environment(\.timelineContext) private var context

    var body: some View {
        RowFrame(author: "Claude", badge: item.model, timestamp: item.timestamp) {
            if let context, let summary = ThinkingDisclosure.summary(of: item, in: context) {
                ThinkingDisclosure(id: item.id, summary: summary)
            }
            let text = MessageText.text(of: item.blocks, fallback: "")
            if !text.isEmpty {
                MarkdownBody(key: item.id.key, source: text)
                    .opacity(item.supersededBy == nil ? 1 : 0.5)
            }
            if item.supersededBy != nil {
                Text("Superseded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A message from something that is neither the reader nor the main agent — a teammate, a task
/// notification, a subagent's forwarded text. Authored by its `originKind` (§8).
struct PeerMessageRow: View {

    let item: PeerMessageItem

    var body: some View {
        RowFrame(author: item.name ?? item.from ?? item.originKind,
                 badge: item.originKind,
                 timestamp: item.timestamp) {
            MarkdownBody(key: item.id.key, source: MessageText.text(of: item.blocks, fallback: item.text))
        }
    }
}

// MARK: - Reading a message's blocks

/// What a message's content blocks say, and what they carry that is not prose.
enum MessageText {

    /// Every text block, joined. Thinking is deliberately excluded: it has its own disclosure, and a
    /// message whose thinking was inlined here would read as if the model had said it out loud.
    static func text(of blocks: [ContentBlock], fallback: String) -> String {
        let texts = blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text.fields.text }
            return nil
        }
        return texts.isEmpty ? fallback : texts.joined(separator: "\n\n")
    }

    /// The thinking blocks, in order.
    static func thinking(in blocks: [ContentBlock]) -> [String] {
        blocks.compactMap { block in
            if case .thinking(let thought) = block { return thought.fields.thinking }
            if case .redactedThinking = block { return "(redacted)" }
            return nil
        }
    }

    /// Attachments named as tokens rather than drawn (parity §41.24.1's placeholder grammar): an
    /// image the reader pasted is one atomic thing in the composer and stays one here.
    static func attachments(in blocks: [ContentBlock]) -> [String] {
        blocks.compactMap { block in
            switch block {
            case .image: "[image]"
            case .document(let doc): doc.fields.title.map { "[\($0)]" } ?? "[document]"
            default: nil
            }
        }
    }
}
