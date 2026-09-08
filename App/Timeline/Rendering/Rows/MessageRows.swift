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
    /// **Main-actor isolated**, because two of the contents built into one are: contract Y6's sites
    /// read `ComposerModel`, which is a `@MainActor` observable, and a plain closure could not call
    /// them. Every `RowFrame` is built inside a `body`, so the isolation costs nothing and states
    /// what was already true.
    @ViewBuilder var content: @MainActor () -> Body

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
/// its attachments named rather than inlined, and contract Y6's first two sites — *Edit*, and the
/// note the composer writes when a rewind was refused and a fork opened instead (§14, gate G6).
struct UserMessageRow: View {

    let item: UserMessageItem

    @Environment(\.timelineContext) private var context

    var body: some View {
        UserMessageBody(item: item, context: context)
    }
}

/// The user row's content, with the context handed in rather than read from the environment.
///
/// Split out for the reason `AgentChip.content(for:in:)` is a function: an `@Environment` value is
/// not populated in a constructed view, so affordances decided inline in a `body` are affordances no
/// test can reach — and Y6 exists because exactly that kind of seam shipped with every gate on both
/// sides of it green.
struct UserMessageBody: View {

    let item: UserMessageItem
    let context: TimelineRenderContext?

    var body: some View {
        RowFrame(author: "You", timestamp: item.timestamp, alignment: .trailing) { content }
    }

    /// Walked directly by this row's own tests: `RowFrame` takes its content as a closure, and
    /// `Mirror` does not descend into one.
    @ViewBuilder @MainActor var content: some View {
        MarkdownBody(key: item.id.key, source: MessageText.text(of: item.blocks, fallback: item.text))
        let attachments = MessageText.attachments(in: item.blocks)
        if !attachments.isEmpty {
            Text(attachments.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        // **Y6 site 1.** The row calls `edit(_:)` and stops there: the `rewind_conversation` carrying
        // `last_seen_user_message_uuid`, the refusal read from the body rather than the envelope, and
        // the *Fork from here* fallback are all the composer's. Absent for a channel with no
        // composer, which is every read-only listing.
        if let context, let composer = context.composer {
            Button("Edit") {
                // Recorded before the call, so the note a refusal produces has a message to sit
                // beside whichever way the request goes.
                context.editing.note(edited: item.id)
                Task { await composer.edit(item) }
            }
            .buttonStyle(.link)
            .font(.caption2)
        }
        // **Y6 site 2.** One note, beside the one message it is about.
        if let note = ComposerSites.note(for: item, in: context) {
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// The model's message: its badge from `AssistantMessageItem.model`, its text blocks through §5, its
/// thinking blocks folded into the disclosure below, and a superseded chain marked as retracted.
struct AssistantMessageRow: View {

    let item: AssistantMessageItem

    @Environment(\.timelineContext) private var context

    var body: some View {
        AssistantMessageBody(item: item, context: context)
    }
}

/// The assistant row's content, with the context handed in — `UserMessageBody`'s reason, and one
/// more: contract Y6's third site is a **substitution**, and the assertion that matters is that the
/// frame's own text appears nowhere in the row, which is a walk of this value.
struct AssistantMessageBody: View {

    let item: AssistantMessageItem
    let context: TimelineRenderContext?

    var body: some View {
        RowFrame(author: "Claude", badge: item.model, timestamp: item.timestamp) { content }
    }

    @ViewBuilder @MainActor var content: some View {
        if let context, let summary = ThinkingDisclosure.summary(of: item, in: context) {
            ThinkingDisclosure(id: item.id, summary: summary)
        }
        // **Y6 site 3.** One string, and by construction there is no shape of this row that draws
        // both: §7.7 has afleet *replace* the engine's drift refusal, and a replacement drawn beside
        // the original leaves the refusal on screen telling the user to go to the terminal.
        let text = ComposerSites.text(of: item, in: context)
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
