import AppKit
import Foundation
import HighlightKit
import Markdown
import OSLog
import SwiftUI
import FleetKit

// MARK: - The seam

/// What a renderer is handed: the rows, the message still streaming, and what changed since last time.
///
/// `changes` is not decoration. A renderer that reloads its whole table on every publish is the
/// thing §8.3's virtualisation exists to avoid, and the change set is how one row is reloaded
/// instead — `.inserted`, `.updated` and `.removed` each name an `ItemID`, and `.previewChanged`
/// names the streaming row without naming an item, because a preview is not an item yet.
struct TimelineRenderInput {
    var rows: [TimelineRow]
    var preview: StreamingPreview?
    var changes: [TimelineChange]

    init(rows: [TimelineRow] = [], preview: StreamingPreview? = nil, changes: [TimelineChange] = []) {
        self.rows = rows; self.preview = preview; self.changes = changes
    }
}

/// The one seam between the channel's model and whatever draws it (child spec §11).
///
/// It exists so that S7's fallback, if it is ever needed, **swaps the view and not the model**: the
/// items, the preview and the change set go in and a view comes out, and a `WKWebView` conformer
/// would take exactly the same input. `NativeTimelineRenderer` is its only conformer, and the
/// composite's risk section says plainly that the fallback is a second one and never a re-cut.
@MainActor
protocol TimelineRendering {
    func view(for input: TimelineRenderInput) -> AnyView
}

// MARK: - The native renderer

/// The native path: an `NSTableView` in an `NSScrollView`, one row per item, SwiftUI hosted per
/// visible row (child spec §3).
///
/// **Superseded 2026-09-08 (C6.1 Task 2).** What stood here said this was S7-minimal — a table and
/// the text pipeline, with the scroll behaviours to come. They are here now, in
/// `TimelineTableController`: one row per `ItemID`, heights cached per id, and a streaming delta that
/// reloads one row. The scroll behaviours land next, and Task 3 still lifts `MarkdownText` and
/// `CodeHighlighter` out of this file into their own.
///
/// One conformer, and one table per channel: the controller is held here, so the row heights and the
/// scroll position survive every body evaluation of the view above.
@MainActor
final class NativeTimelineRenderer: TimelineRendering {

    private let controller = TimelineTableController()

    func view(for input: TimelineRenderInput) -> AnyView {
        AnyView(TimelineTableRepresentable(controller: controller, input: input))
    }
}

// MARK: - One row's text

/// One row's content: the blocks that have settled, and the tail that has not.
///
/// **Frozen prefix, live tail** (§4). Settled blocks are attributed strings, parsed once and cached
/// by content; the tail is plain text in the same font and is never parsed, because parsing a
/// fragment thirty times a second is the cost the design exists to avoid.
struct RenderedRow: Identifiable {

    let key: String
    var id: String { key }

    /// The item this row draws, when the row came from a channel's timeline.
    ///
    /// Non-nil rows draw through contract Y1's registry, which is the whole of what the app shows;
    /// nil rows are the two that are not items — S7's corpus documents, and the message still
    /// streaming — and draw the markdown pipeline below directly.
    let item: TimelineRow?

    private(set) var settled: [NSAttributedString] = []
    private(set) var tail: String = ""
    private var pending: String
    /// What this row was built from, kept for the off-main warm-up `setRows` kicks off.
    let pendingSource: String

    /// How many characters of source this row has consumed. The streaming path appends only the
    /// fragment beyond it, so a publish carrying a whole message's text costs the delta and not the
    /// message.
    private(set) var consumedCharacters = 0

    init(key: String, source: String) {
        self.key = key
        self.item = nil
        self.pending = source
        self.pendingSource = source
    }

    /// A row of the channel's timeline. It carries no source text of its own: what it draws is
    /// whichever builder owns the item's kind, and that builder owns the item's own content.
    init(_ item: TimelineRow) {
        self.key = item.id.key
        self.item = item
        self.pending = ""
        self.pendingSource = ""
    }

    /// Parses everything this row arrived with. Called once, off the streaming path.
    mutating func settle(markdown: MarkdownText, highlighter: CodeHighlighter) {
        var phases = RenderPhases()
        consumeClosedBlocks(from: pending, markdown: markdown, highlighter: highlighter, phases: &phases)
        consumedCharacters = pending.count
        pending = ""
    }

    /// The streaming append. Only a **closed** block is parsed; the rest stays in the tail.
    mutating func append(_ fragment: String, markdown: MarkdownText, highlighter: CodeHighlighter,
                         phases: inout RenderPhases) {
        consumeClosedBlocks(from: tail + fragment, markdown: markdown, highlighter: highlighter, phases: &phases)
        consumedCharacters += fragment.count
    }

    /// Splits at the last block boundary, parses what closed, keeps the rest as the tail.
    ///
    /// The **open-fence re-prepend** of parity §41.17 lives here: when the settled prefix ends
    /// inside an open fenced block, the fence's opening line goes back onto the tail so the
    /// fragment still lexes as code rather than flickering between code and prose mid-stream.
    private mutating func consumeClosedBlocks(from text: String, markdown: MarkdownText,
                                              highlighter: CodeHighlighter, phases: inout RenderPhases) {
        guard let boundary = text.range(of: "\n\n", options: .backwards) else { tail = text; return }
        let closed = String(text[text.startIndex..<boundary.lowerBound])
        var remainder = String(text[boundary.upperBound...])

        if Self.fenceIsOpen(in: closed), let fence = Self.lastFenceLine(in: closed) {
            // The split fell inside a fence: hand the whole thing to the tail rather than lexing a
            // fragment as prose, and re-prepend the opening line so what is drawn is still code.
            tail = fence + "\n" + remainder
            return
        }
        guard !closed.isEmpty else { tail = text; return }

        let highlightStart = RenderClock.start()
        let attributed = markdown.attributed(closed, highlighter: highlighter, phases: &phases)
        _ = highlightStart
        settled.append(attributed)
        tail = remainder
        remainder = ""
    }

    /// An odd number of fence openings means the last one is still open.
    static func fenceIsOpen(in text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("```") }.count % 2 == 1
    }

    static func lastFenceLine(in text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .last { $0.hasPrefix("```") }.map(String.init)
    }

    /// A cheap height, measured from the laid-out attributed text plus the tail.
    func height(forWidth width: CGFloat) -> CGFloat {
        let joined = NSMutableAttributedString()
        for block in settled { joined.append(block); joined.append(NSAttributedString(string: "\n")) }
        if !tail.isEmpty {
            joined.append(NSAttributedString(string: tail,
                                             attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        }
        guard joined.length > 0 else { return 18 }
        let bounds = joined.boundingRect(with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(18, ceil(bounds.height) + 8)
    }
}

/// The SwiftUI body a row hosts. Deliberately trivial: everything expensive already happened and is
/// cached, and the whole point of §3 is that the body does no work a cache could have done.
struct TimelineMarkdownRow: View {

    let row: RenderedRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(row.settled.enumerated()), id: \.offset) { _, block in
                Text(AttributedString(block))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !row.tail.isEmpty {
                // The live tail: plain text in the same font, never parsed (§4).
                Text(row.tail)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Phase attribution

/// Where a frame's time went. S7's verdict turns on this split: a p99 blown by hosting is the
/// child spec's branch 2 — an AppKit fast path for message rows, which is a Y1 amendment — and a
/// p99 blown by parsing or highlighting is branch 3, which the `WKWebView` fallback does fix. A
/// spike that reported one number could only ever recommend the fallback.
struct RenderPhases {
    var hosting: TimeInterval = 0
    var markdown: TimeInterval = 0
    var highlight: TimeInterval = 0

    static func + (a: RenderPhases, b: RenderPhases) -> RenderPhases {
        RenderPhases(hosting: a.hosting + b.hosting,
                     markdown: a.markdown + b.markdown,
                     highlight: a.highlight + b.highlight)
    }
}

/// A monotonic clock and the signposter Instruments reads.
///
/// `OSSignposter` rather than `os_signpost`: contract X1's import allowlist admits `OSLog` and not
/// `os`, and the signposter is the OSLog-module spelling of the same instrument.
enum RenderClock {
    static func start() -> ContinuousClock.Instant { ContinuousClock.now }
    static func since(_ instant: ContinuousClock.Instant) -> TimeInterval {
        Double((ContinuousClock.now - instant).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - instant).components.seconds)
    }
}

// MARK: - Markdown

/// Markdown into attributed text, parsed once per content (§5).
///
/// **The cache is the design, not an optimisation.** §4's whole claim is that nothing expensive
/// runs per delta, and the way that is true is that a settled block's attributed string is built
/// once and looked up thereafter. Keyed by the block's own text, so equality is checked and a hash
/// collision cannot return the wrong block.
///
/// `@unchecked Sendable` is sound because every read and every write of `cache` happens between
/// `lock.lock()` and `lock.unlock()` of this instance's private `NSLock`; that lock is the
/// serialising mechanism.
final class MarkdownText: @unchecked Sendable {

    private let lock = NSLock()
    private var cache: [String: NSAttributedString] = [:]
    /// Bounded: a day-long channel must not accumulate a transcript of attributed strings.
    private var order: [String] = []
    private let capacity = 512

    /// Cache-first. A miss parses here, which is what §4 bounds by only ever handing this a block
    /// that has just closed rather than a whole document.
    func attributed(_ source: String, highlighter: CodeHighlighter, phases: inout RenderPhases) -> NSAttributedString {
        if let hit = read(source) { return hit }
        let start = RenderClock.start()
        let built = Self.build(source, highlighter: highlighter, phases: &phases)
        phases.markdown += RenderClock.since(start)
        write(source, built)
        return built
    }

    /// Parses off the main thread and fills the cache, so the measured path is the cached one.
    /// This is §6's "never on the main thread" for the warm case; a miss on the streaming path is
    /// a single just-closed block and is bounded by that.
    func warm(_ sources: [String], highlighter: CodeHighlighter) async {
        await Task.detached(priority: .utility) { [self] in
            for source in sources where read(source) == nil {
                var phases = RenderPhases()
                write(source, Self.build(source, highlighter: highlighter, phases: &phases))
            }
        }.value
    }

    private func read(_ key: String) -> NSAttributedString? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private func write(_ key: String, _ value: NSAttributedString) {
        lock.lock(); defer { lock.unlock() }
        if cache[key] == nil {
            order.append(key)
            if order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
        }
        cache[key] = value
    }

    // MARK: The walk

    /// One block of markdown, built into attributed text.
    ///
    /// Raw HTML is **escaped and never passed through**: the terminal passes it through
    /// unsanitised and parity §41.17 names that as the one row a GUI must not copy, because it is
    /// a rendering-injection hazard.
    static func build(_ source: String, highlighter: CodeHighlighter, phases: inout RenderPhases) -> NSAttributedString {
        let document = Document(parsing: source, options: .parseBlockDirectives)
        let out = NSMutableAttributedString()
        for child in document.children {
            append(child, to: out, highlighter: highlighter, indent: 0, phases: &phases)
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private static func append(_ markup: Markup, to out: NSMutableAttributedString,
                               highlighter: CodeHighlighter, indent: Int, phases: inout RenderPhases) {
        switch markup {
        case let heading as Heading:
            let size: CGFloat = [24, 20, 17, 15, 14, 13][max(0, min(5, heading.level - 1))]
            out.append(NSAttributedString(string: plain(heading) + "\n",
                                          attributes: [.font: NSFont.boldSystemFont(ofSize: size)]))

        case let code as CodeBlock:
            let language = code.language?.lowercased()
            let start = RenderClock.start()
            let styled = highlighter.styled(code: code.code, language: language)
            phases.highlight += RenderClock.since(start)
            out.append(styled)

        case let quote as BlockQuote:
            for child in quote.children {
                append(child, to: out, highlighter: highlighter, indent: indent + 1, phases: &phases)
            }

        case let list as UnorderedList:
            for (offset, item) in list.listItems.enumerated() {
                _ = offset
                out.append(NSAttributedString(string: String(repeating: "    ", count: indent) + "• ",
                                              attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                for child in item.children {
                    append(child, to: out, highlighter: highlighter, indent: indent + 1, phases: &phases)
                }
            }

        case let list as OrderedList:
            for (offset, item) in list.listItems.enumerated() {
                out.append(NSAttributedString(string: String(repeating: "    ", count: indent) + "\(offset + 1). ",
                                              attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                for child in item.children {
                    append(child, to: out, highlighter: highlighter, indent: indent + 1, phases: &phases)
                }
            }

        case let table as Markdown.Table:
            // Native tables are Task 2's; a monospaced row here costs what laying one out costs,
            // which is what the spike needs and is not what ships.
            out.append(NSAttributedString(string: plain(table) + "\n",
                                          attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))

        case let paragraph as Paragraph:
            out.append(inline(paragraph))
            out.append(NSAttributedString(string: "\n"))

        default:
            let text = plain(markup)
            if !text.isEmpty { out.append(NSAttributedString(string: text + "\n",
                                                             attributes: [.font: NSFont.systemFont(ofSize: 13)])) }
        }
    }

    /// A paragraph's inline runs: emphasis, strong, inline code and link labels.
    private static func inline(_ markup: Markup) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for child in markup.children {
            switch child {
            case let text as Markdown.Text:
                out.append(NSAttributedString(string: text.string,
                                              attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            case let code as InlineCode:
                out.append(NSAttributedString(string: code.code,
                                              attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                           .backgroundColor: NSColor.quaternarySystemFill]))
            case let strong as Strong:
                out.append(NSAttributedString(string: plain(strong),
                                              attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
            case let emphasis as Emphasis:
                out.append(NSAttributedString(string: plain(emphasis),
                                              attributes: [.font: NSFont(descriptor: NSFont.systemFont(ofSize: 13).fontDescriptor.withSymbolicTraits(.italic), size: 13) ?? NSFont.systemFont(ofSize: 13)]))
            case let link as Markdown.Link:
                out.append(NSAttributedString(string: plain(link),
                                              attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                           .foregroundColor: NSColor.linkColor]))
            case let html as InlineHTML:
                // Escaped, never passed through (§5).
                out.append(NSAttributedString(string: html.rawHTML,
                                              attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            default:
                out.append(NSAttributedString(string: plain(child),
                                              attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            }
        }
        return out
    }

    private static func plain(_ markup: Markup) -> String {
        if let text = markup as? Markdown.Text { return text.string }
        if let code = markup as? InlineCode { return code.code }
        return markup.children.map(plain).joined()
    }
}

// MARK: - Highlighting

/// Syntax highlighting, off the main thread and cached (§6).
///
/// **A miss renders unhighlighted and fills behind you**, which is not a degradation to apologise
/// for: it is exactly what §6 specifies for an open fenced block, and it is what a fence tagged
/// with a language no grammar covers renders as anyway. So the fallback path is the ordinary path
/// and is exercised on every unknown language rather than kept for a rainy day.
///
/// `@unchecked Sendable` on the same terms as `MarkdownText`: one `NSLock`, every access inside it.
final class CodeHighlighter: @unchecked Sendable {

    private let lock = NSLock()
    private var cache: [Key: NSAttributedString] = [:]
    private var inFlight: Set<Key> = []
    private let highlighter = Highlighter()

    struct Key: Hashable { let code: String; let language: String }

    /// `syntaxHighlightingDisabled` from `get_settings` is honoured — parity §41.17 records it as
    /// an accessibility choice. Task 5's readout sets it; it defaults to on.
    var isEnabled = true

    func styled(code: String, language: String?) -> NSAttributedString {
        let plain = NSAttributedString(string: code,
                                       attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        guard isEnabled, let language, highlighter.hasLanguage(named: language) else { return plain }
        let key = Key(code: code, language: language)
        if let hit = cached(key) { return hit }
        guard claim(key) else { return plain }
        Task.detached(priority: .userInitiated) { [self] in
            store(key, highlighter.attributedString(for: code, language: language), releasing: true)
        }
        return plain
    }

    /// Fills the cache off-main before a measurement, so the measured path is the cached one.
    func warm(_ blocks: [(code: String, language: String?)]) async {
        await Task.detached(priority: .utility) { [self] in
            for block in blocks {
                guard let language = block.language, highlighter.hasLanguage(named: language) else { continue }
                let key = Key(code: block.code, language: language)
                guard cached(key) == nil else { continue }
                store(key, highlighter.attributedString(for: block.code, language: language), releasing: false)
            }
        }.value
    }

    // The lock is only ever taken inside these three synchronous members. `NSLock.lock()` is
    // unavailable from an asynchronous context — it blocks a cooperative thread — so the async
    // paths above call these rather than taking it themselves.
    private func cached(_ key: Key) -> NSAttributedString? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    /// True when this caller is the one that should do the work; false when another already is.
    private func claim(_ key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(key).inserted
    }

    private func store(_ key: Key, _ value: NSAttributedString, releasing: Bool) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = value
        if releasing { inFlight.remove(key) }
    }
}
