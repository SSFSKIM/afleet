import AppKit
import Foundation
import HighlightKit
import Markdown
import OSLog
import SwiftUI
import AfleetCore
import FleetKit
import PanelHostAPI

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
/// `TimelineTableController`: bottom anchoring, sticky-to-bottom with a silent re-pin, scroll
/// anchoring on the item nearest the viewport top, and the jump-to-bottom affordance with its unseen
/// count.
///
/// **Superseded again 2026-09-09 (C6.1 Task 3).** What stood here said Task 3 would lift
/// `MarkdownText` and `CodeHighlighter` into files of their own. It did not, and the reason is the
/// rule the plan states more than once: one markdown renderer, one highlighter, one cache. Moving
/// two working types across a file boundary buys a shorter file and risks a second of each; Task 3
/// extended them in place — the sanitiser, the escaped HTML, the native tables, the two `marked`
/// overrides and the split's re-prepend — and put the one genuinely new concept, the untrusted-text
/// sanitiser, in `TextSanitiser.swift` beside them.
///
/// One conformer, and one table per channel: the controller is held here, so the row heights and the
/// scroll position survive every body evaluation of the view above.
@MainActor
final class NativeTimelineRenderer: TimelineRendering {

    private let controller = TimelineTableController()

    func view(for input: TimelineRenderInput) -> AnyView {
        AnyView(TimelineListSurface(controller: controller, input: input))
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

    /// Parses everything this row holds, its tail included. For text that has **stopped arriving**.
    ///
    /// `settle` is the streaming reading: it parses to the last closed block boundary and leaves the
    /// rest as plain text, because a fragment still growing is not a document yet. A durable item is
    /// not growing — nothing further will arrive to close its last block — so the boundary rule
    /// would leave a message ending in `**Done**` drawing its own asterisks for ever, with no later
    /// pass to finalise it. The rule is the live tail's alone (§4), and this is its other side.
    mutating func finalise(markdown: MarkdownText, highlighter: CodeHighlighter) {
        var phases = RenderPhases()
        let remaining = tail + pending
        tail = ""
        consumedCharacters += pending.count
        pending = ""
        settle(remaining, markdown: markdown, highlighter: highlighter, phases: &phases)
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
        // Sanitised here, which is the one place both halves pass through: the settled prefix goes
        // on to the markdown pipeline and the tail is drawn as plain text without ever reaching it
        // (§5). The character counts the streaming path keeps are of the *raw* fragment and are not
        // affected — they index the preview's own text, not this.
        let text = TextSanitiser.sanitise(text)
        guard let boundary = text.range(of: "\n\n", options: .backwards) else { tail = text; return }
        let closed = String(text[text.startIndex..<boundary.lowerBound])
        let remainder = String(text[boundary.upperBound...])

        if Self.fenceIsOpen(in: closed), let opening = Self.lastFenceLineIndex(in: closed) {
            // The split fell inside a fence. The **re-prepend** of parity §41.17: the split moves
            // back to the fence's own opening line, so the tail begins with the fence and still
            // lexes as code rather than flickering between code and prose mid-stream.
            //
            // What is before the fence *has* closed and settles here. Handing the whole text to the
            // tail instead would be safe; handing the tail the fence line alone, as this did before
            // Task 3, dropped every character between the last boundary and the fence — a streaming
            // message quietly lost the paragraph it opened with.
            let lines = closed.split(separator: "\n", omittingEmptySubsequences: false)
            settle(lines[..<opening].joined(separator: "\n"), markdown: markdown,
                   highlighter: highlighter, phases: &phases)
            tail = lines[opening...].joined(separator: "\n") + "\n\n" + remainder
            return
        }
        guard !closed.isEmpty else { tail = text; return }

        settle(closed, markdown: markdown, highlighter: highlighter, phases: &phases)
        tail = remainder
    }

    /// Parses one closed block into the settled prefix. Empty text settles nothing: a block boundary
    /// at the very start of a fragment is a boundary and not a block.
    private mutating func settle(_ block: String, markdown: MarkdownText, highlighter: CodeHighlighter,
                                 phases: inout RenderPhases) {
        let block = block.trimmingCharacters(in: .newlines)
        guard !block.isEmpty else { return }
        settled.append(markdown.attributed(block, highlighter: highlighter, phases: &phases))
    }

    /// An odd number of fence openings means the last one is still open.
    static func fenceIsOpen(in text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("```") }.count % 2 == 1
    }

    /// Which line of `text` opens the fence that is still open.
    static func lastFenceLineIndex(in text: String) -> Int? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .lastIndex { $0.hasPrefix("```") }
    }

    /// A cheap height, measured from the laid-out attributed text plus the tail.
    ///
    /// A block carrying a real table is measured by TextKit instead: `boundingRect` lays out runs
    /// and knows nothing about the cells a paragraph style puts them in, so a table measured that
    /// way is a row too short to hold it.
    func height(forWidth width: CGFloat) -> CGFloat {
        let joined = NSMutableAttributedString()
        var tables: CGFloat = 0
        for block in settled where TimelineTextMeasure.holdsATable(block) {
            tables += TimelineTextMeasure.height(of: block, width: width - 24)
        }
        for block in settled where !TimelineTextMeasure.holdsATable(block) {
            joined.append(block); joined.append(NSAttributedString(string: "\n"))
        }
        if !tail.isEmpty {
            joined.append(NSAttributedString(string: tail,
                                             attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        }
        guard joined.length > 0 else { return max(18, tables + 8) }
        let bounds = joined.boundingRect(with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(18, ceil(bounds.height) + tables + 8)
    }
}

/// The SwiftUI body a row hosts. Deliberately trivial: everything expensive already happened and is
/// cached, and the whole point of §3 is that the body does no work a cache could have done.
struct TimelineMarkdownRow: View {

    let row: RenderedRow

    /// The channel this row is drawn in, for the one thing a settled block cannot decide for
    /// itself: where a link goes. Nil outside the timeline's subtree, and a link is then drawn and
    /// does nothing, which is contract Y7's rule for every other affordance here.
    @Environment(\.timelineContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(row.settled.enumerated()), id: \.offset) { _, block in
                if TimelineTextMeasure.holdsATable(block) {
                    // A table lives in the paragraph style, and SwiftUI's `Text` draws an
                    // `AttributedString`'s fonts and colours and drops its paragraph styles. So the
                    // one block kind whose structure would be lost is drawn by the one thing that
                    // lays a text table out (§5).
                    TimelineTextKitBlock(block: block, context: context)
                } else {
                    Text(AttributedString(block))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        // SwiftUI activates an `AttributedString`'s link through this, and the default hands it
        // straight to the system. A destination the walk carried is not a system URL yet — it may be
        // a path, and it may be relative — so the routing decision is made here, against this row's
        // own channel, and only what the router declines to own falls through to the system.
        .environment(\.openURL, OpenURLAction { [context] url in
            TimelineLinkDestination.open(url, in: context) ? .handled : .systemAction
        })
    }
}

/// A settled block that carries a real table, drawn by TextKit.
///
/// Deliberately narrow: only a block with a table takes this path, so every other block keeps the
/// SwiftUI text rendering the rest of the surface is built on and nothing about the row's ordinary
/// cost changes.
struct TimelineTextKitBlock: NSViewRepresentable {

    let block: NSAttributedString
    /// The channel, for a link inside a table cell. `NSTextView`'s own default for a `.link`
    /// attribute is to hand it to `NSWorkspace`, which for a path — relative or not — is either
    /// nothing or the wrong file, and in neither case is it the router every other link goes
    /// through. The coordinator below intercepts it for that reason.
    var context: TimelineRenderContext?

    func makeCoordinator() -> Coordinator { Coordinator(context: context) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(block)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.context = self.context
        view.textStorage?.setAttributedString(block)
    }

    /// The text view's delegate, for link activation and nothing else.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var context: TimelineRenderContext?

        init(context: TimelineRenderContext?) { self.context = context }

        func textView(_ view: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(TimelineLinkDestination.url(for:))
            else { return false }
            return TimelineLinkDestination.open(url, in: context)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: TimelineTextMeasure.height(of: block, width: width))
    }
}

/// Laying text out to ask how tall it is, for the one block kind `boundingRect` cannot measure.
enum TimelineTextMeasure {

    /// Whether any run of this block belongs to a table cell.
    static func holdsATable(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            guard let style = value as? NSParagraphStyle else { return }
            if style.textBlocks.contains(where: { $0 is NSTextTableBlock }) { found = true; stop.pointee = true }
        }
        return found
    }

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}

// MARK: - Where a markdown link goes

/// A markdown link's destination: carried through the parse as written, resolved at activation.
///
/// **The split is the whole point.** The parsed block is cached by its own text and that cache is
/// shared by every channel (§5), so nothing channel-shaped may enter it — a relative destination
/// resolved against one channel's working directory would be served to another. So the walk stores
/// the destination exactly as the author wrote it and the row resolves it when a reader presses it,
/// against the context that row was drawn in.
///
/// Activation goes through contract Y7's link capability, which is the same route
/// `FileLink.open` takes for the paths a tool row shows: one router decides whether a `.file` opens
/// a panel and a `.url` reaches a Browser tab or the system, and a second route here would be a
/// second answer to that question.
enum TimelineLinkDestination {

    /// The URL a destination is carried as, or nil for one there is nothing to carry.
    ///
    /// A destination with no scheme stays scheme-less and relative: `URL(filePath:)` would resolve
    /// it against the *process's* directory, which names a file the channel never meant.
    static func url(for destination: String) -> URL? {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return nil }
        if destination.hasPrefix("~") {
            return URL(filePath: (destination as NSString).expandingTildeInPath)
        }
        return URL(string: destination)
    }

    /// Which `WorkspaceLink` a carried destination is, given the channel it was drawn in.
    ///
    /// Nil where there is nothing to open: a relative path in a channel whose working directory the
    /// index cannot name, which is the same answer `TimelineRenderContext.cwd` documents — resolving
    /// it against anything else would open a different file and call it the reader's.
    static func link(for url: URL, cwd: URL?) -> WorkspaceLink? {
        guard url.scheme != "file" else { return .file(url, line: nil) }
        if let scheme = url.scheme, !scheme.isEmpty { return .url(url) }
        let path = url.relativePath
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return .file(URL(filePath: path), line: nil) }
        guard let cwd else { return nil }
        return .file(cwd.appending(path: path), line: nil)
    }

    /// Opens one carried destination, and answers whether there was anything to open.
    ///
    /// Fire-and-forget for `FileLink.open`'s reason: the capability is `async`, a press is not, and
    /// awaiting it would hold the main actor open for a panel that may be constructing a session.
    @MainActor
    @discardableResult
    static func open(_ url: URL, in context: TimelineRenderContext?) -> Bool {
        guard let context, let link = link(for: url, cwd: context.cwd) else { return false }
        let links = context.links
        Task { await links.open(link, from: .currentPanel) }
        return true
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

    /// **One markdown renderer, one cache** (§5). The table's own rows and the row builders under
    /// `Rows/` both parse through this instance, so a block parsed for a message is not parsed again
    /// when the same message is measured, and the bound below is a bound on the whole app rather
    /// than on one channel's table.
    static let shared = MarkdownText()

    private let lock = NSLock()
    private var cache: [String: NSAttributedString] = [:]
    /// Bounded: a day-long channel must not accumulate a transcript of attributed strings.
    private var order: [String] = []
    private let capacity = 512
    private var parses = 0

    /// Which cold highlights each cached block was built over, for the entries that were built over
    /// any. A settled block holds its styled code *inside* it (§6), so a block parsed while its
    /// fence's highlight was still in flight holds the plain fallback for ever unless something
    /// notices the fill landed. This is what notices.
    ///
    /// Read at the cache rather than written by the highlighter: the fill is a detached task and a
    /// callback into this cache would be a second lock ordering. An entry with no pending highlights
    /// — every block that is not a fence, which is nearly all of them — costs the read nothing.
    private var pendingHighlights: [String: Set<CodeHighlighter.Key>] = [:]

    /// Which styling the cache holds. Bumped by every `clear`, so a build that started under the old
    /// preference cannot write its result into the cache the new one is filling (§6).
    private var stylingGeneration = 0

    /// The styling a build should be written back under. Read before the build, checked at the
    /// write; between the two is the window a preference flip lands in.
    var styling: Int {
        lock.lock(); defer { lock.unlock() }
        return stylingGeneration
    }

    /// How many blocks this cache has actually parsed, cumulatively.
    ///
    /// Instrumentation and not decoration: §4's claim is that nothing expensive runs per delta, and
    /// "parsed once per content" stays a claim while nothing counts the parses. A cache that
    /// returned one constant for every key satisfies any assertion made on the rendered text alone.
    var parseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return parses
    }

    /// Cache-first. A miss parses here, which is what §4 bounds by only ever handing this a block
    /// that has just closed rather than a whole document.
    ///
    /// The **sanitiser runs first** and the cache is keyed by what it returned (§5). Keying by the
    /// raw text would hold two entries for two strings that draw identically, and would leave the
    /// unsanitised text sitting in a key for the next reader to pick up.
    func attributed(_ source: String, highlighter: CodeHighlighter, phases: inout RenderPhases) -> NSAttributedString {
        let source = TextSanitiser.sanitise(source)
        if let hit = read(source, highlighter: highlighter) { return hit }
        let start = RenderClock.start()
        var pending: Set<CodeHighlighter.Key> = []
        let built = Self.build(source, highlighter: highlighter, phases: &phases, pending: &pending)
        phases.markdown += RenderClock.since(start)
        write(source, built, pending: pending)
        return built
    }

    /// Parses off the main thread and fills the cache, so the measured path is the cached one.
    /// This is §6's "never on the main thread" for the warm case; a miss on the streaming path is
    /// a single just-closed block and is bounded by that.
    ///
    /// **The styling is read before the build and checked at the write.** A preference flip clears
    /// this cache, and a build that began before the flip carries the old styling inside it; a write
    /// that did not check would repopulate the freshly cleared cache with exactly what the flip
    /// existed to remove.
    func warm(_ sources: [String], highlighter: CodeHighlighter) async {
        await Task.detached(priority: .utility) { [self] in
            for source in sources.map(TextSanitiser.sanitise) where read(source, highlighter: highlighter) == nil {
                var phases = RenderPhases()
                var pending: Set<CodeHighlighter.Key> = []
                let styling = self.styling
                let built = Self.build(source, highlighter: highlighter, phases: &phases, pending: &pending)
                write(source, built, pending: pending, ifStyling: styling)
            }
        }.value
    }

    /// Drops every parsed block.
    ///
    /// One caller: the syntax-highlighting preference flipping. A settled block holds its styled
    /// code inside it, so a cache kept across that flip keeps drawing highlighted code after the
    /// reader turned highlighting off.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
        order = []
        pendingHighlights = [:]
        stylingGeneration += 1
    }

    /// A cached block, unless the highlight it settled without has since landed.
    ///
    /// The staleness check is here rather than at the fill because it costs nothing to the blocks
    /// that are not fences: an entry with no pending highlights is returned on the dictionary read
    /// alone. A block whose highlight *has* landed is dropped and reported as a miss, so the caller
    /// rebuilds it over the styled code — and a visible row picks that up on the controller's next
    /// reload of it.
    private func read(_ key: String, highlighter: CodeHighlighter) -> NSAttributedString? {
        lock.lock()
        guard let hit = cache[key] else { lock.unlock(); return nil }
        let pending = pendingHighlights[key] ?? []
        lock.unlock()
        // Outside our lock: `isCached` takes the highlighter's, and one lock is never held while
        // the other is taken.
        guard !pending.isEmpty, pending.contains(where: highlighter.isCached) else { return hit }
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: key)
        pendingHighlights.removeValue(forKey: key)
        order.removeAll { $0 == key }
        return nil
    }

    private func write(_ key: String, _ value: NSAttributedString, pending: Set<CodeHighlighter.Key>) {
        lock.lock(); defer { lock.unlock() }
        store(key, value, pending: pending)
    }

    /// The off-main write, refused when the styling it was built under is gone.
    ///
    /// Answers whether it wrote, so a caller — and a test — can tell a refusal from a write.
    @discardableResult
    func write(_ key: String, _ value: NSAttributedString, pending: Set<CodeHighlighter.Key>,
               ifStyling styling: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard styling == stylingGeneration else { return false }
        store(key, value, pending: pending)
        return true
    }

    /// The write itself. Called with the lock held.
    private func store(_ key: String, _ value: NSAttributedString, pending: Set<CodeHighlighter.Key>) {
        parses += 1
        if cache[key] == nil {
            order.append(key)
            if order.count > capacity {
                let evicted = order.removeFirst()
                cache.removeValue(forKey: evicted)
                pendingHighlights.removeValue(forKey: evicted)
            }
        }
        cache[key] = value
        if pending.isEmpty { pendingHighlights.removeValue(forKey: key) } else { pendingHighlights[key] = pending }
    }

    // MARK: The walk

    /// One block of markdown, built into attributed text.
    ///
    /// Raw HTML is **escaped and never passed through**: the terminal passes it through
    /// unsanitised and parity §41.17 names that as the one row a GUI must not copy, because it is
    /// a rendering-injection hazard.
    static func build(_ source: String, highlighter: CodeHighlighter, phases: inout RenderPhases) -> NSAttributedString {
        var pending: Set<CodeHighlighter.Key> = []
        return build(source, highlighter: highlighter, phases: &phases, pending: &pending)
    }

    /// The same build, reporting which highlights it settled *without* — the fences whose styled
    /// form was still being made when the block was built. The cache keeps them so it can tell,
    /// later, that this block is no longer what the source would render as.
    static func build(_ source: String, highlighter: CodeHighlighter, phases: inout RenderPhases,
                      pending: inout Set<CodeHighlighter.Key>) -> NSAttributedString {
        let document = Document(parsing: source, options: .parseBlockDirectives)
        // The source's own lines, carried down the walk. One override needs them: cmark truncates a
        // table row wider than its header before the tree exists, so how wide a row *was written* is
        // a question only the source can answer.
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let out = NSMutableAttributedString()
        for child in document.children {
            append(child, to: out, highlighter: highlighter, indent: 0, lines: lines, phases: &phases,
                   pending: &pending)
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private static func append(_ markup: Markup, to out: NSMutableAttributedString,
                               highlighter: CodeHighlighter, indent: Int, lines: [String],
                               phases: inout RenderPhases, pending: inout Set<CodeHighlighter.Key>) {
        switch markup {
        case let heading as Heading:
            let size: CGFloat = [24, 20, 17, 15, 14, 13][max(0, min(5, heading.level - 1))]
            out.append(NSAttributedString(string: plain(heading) + "\n",
                                          attributes: [.font: NSFont.boldSystemFont(ofSize: size)]))

        case let code as CodeBlock:
            let language = code.language?.lowercased()
            let start = RenderClock.start()
            let styled = highlighter.styling(code: code.code, language: language)
            phases.highlight += RenderClock.since(start)
            if let cold = styled.cold { pending.insert(cold) }
            out.append(styled.text)

        case let quote as BlockQuote:
            for child in quote.children {
                append(child, to: out, highlighter: highlighter, indent: indent + 1, lines: lines,
                       phases: &phases, pending: &pending)
            }

        case let list as UnorderedList:
            for (offset, item) in list.listItems.enumerated() {
                _ = offset
                out.append(NSAttributedString(string: String(repeating: "    ", count: indent) + "• ",
                                              attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                for child in item.children {
                    append(child, to: out, highlighter: highlighter, indent: indent + 1, lines: lines,
                           phases: &phases, pending: &pending)
                }
            }

        case let list as OrderedList:
            // **Numbered from the list's own start** (§5). A list written `4.` continues an earlier
            // one — which is how a procedure's fifth step reaches a reader — and numbering from the
            // enumeration's offset renumbered it from one, quietly naming a different step.
            let start = Int(clamping: list.startIndex)
            for (offset, item) in list.listItems.enumerated() {
                out.append(NSAttributedString(string: String(repeating: "    ", count: indent) + "\(start + offset). ",
                                              attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                for child in item.children {
                    append(child, to: out, highlighter: highlighter, indent: indent + 1, lines: lines,
                           phases: &phases, pending: &pending)
                }
            }

        case let table as Markdown.Table:
            appendTable(table, to: out, lines: lines)

        case let html as HTMLBlock:
            // **Escaped, never passed through** (§5). The terminal emits `token.text` unescaped and
            // parity §41.17 names that as the one row a GUI must not copy. Note what the default arm
            // below would do with this node instead: an `HTMLBlock` has no children, so its
            // plain-text projection is empty and the block would vanish silently — which is not
            // escaping either.
            out.append(NSAttributedString(string: html.rawHTML.trimmingCharacters(in: .newlines) + "\n",
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

    // MARK: Tables

    /// A GFM table as a **real table** (§5), or the paragraph the engine bails to.
    ///
    /// **The `marked` override, reproduced post-parse** (parity §41.17): a row with more cells than
    /// its header bails the whole table to a paragraph. cmark does not — it truncates the row to the
    /// header's width and says nothing — so without this a reader loses a cell rather than seeing an
    /// ugly table, which is the worse of the two failures.
    private static func appendTable(_ table: Markdown.Table, to out: NSMutableAttributedString,
                                    lines: [String]) {
        guard !hasARowWiderThanItsHeader(table, in: lines) else {
            out.append(NSAttributedString(string: sourceText(of: table, in: lines) + "\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            return
        }
        let columns = table.maxColumnCount
        guard columns > 0 else { return }
        let layout = NSTextTable()
        layout.numberOfColumns = columns
        layout.layoutAlgorithm = .automaticLayoutAlgorithm
        layout.collapsesBorders = true
        layout.hidesEmptyCells = false

        var row = 0
        appendRow(table.head.cells.map { inline($0) }, header: true, row: &row, in: layout, to: out)
        for bodyRow in table.body.rows {
            appendRow(bodyRow.cells.map { inline($0) }, header: false, row: &row, in: layout, to: out)
        }
    }

    private static func appendRow(_ cells: [NSAttributedString], header: Bool, row: inout Int,
                                  in layout: NSTextTable, to out: NSMutableAttributedString) {
        for (column, content) in cells.enumerated() {
            let block = NSTextTableBlock(table: layout, startingRow: row, rowSpan: 1,
                                         startingColumn: column, columnSpan: 1)
            block.setBorderColor(.separatorColor)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setWidth(4, type: .absoluteValueType, for: .padding)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            let cell = NSMutableAttributedString(attributedString: content)
            cell.append(NSAttributedString(string: "\n"))
            let whole = NSRange(location: 0, length: cell.length)
            cell.addAttribute(.paragraphStyle, value: style, range: whole)
            if header { cell.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: whole) }
            out.append(cell)
        }
        row += 1
    }

    /// Whether any body row was **written** with more cells than the header has.
    ///
    /// Counted from the source line and not from the tree, because the tree no longer holds the
    /// answer: cmark has already dropped the extra cell by the time anything here sees it.
    static func hasARowWiderThanItsHeader(_ table: Markdown.Table, in lines: [String]) -> Bool {
        guard let head = table.head.range?.lowerBound.line, let header = line(head, in: lines) else {
            return false
        }
        let width = cellCount(in: header)
        for row in table.body.rows {
            guard let number = row.range?.lowerBound.line, let text = line(number, in: lines) else { continue }
            if cellCount(in: text) > width { return true }
        }
        return false
    }

    /// One line of the source, by cmark's own one-based numbering.
    private static func line(_ number: Int, in lines: [String]) -> String? {
        let index = number - 1
        return lines.indices.contains(index) ? lines[index] : nil
    }

    /// How many cells one row of table source declares. A `\|` is an escaped pipe and not a cell
    /// boundary, which is the rule the engine's own tokenizer follows.
    static func cellCount(in line: String) -> Int {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var count = 1
        var escaped = false
        for character in trimmed {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { count += 1 }
        }
        return count
    }

    /// The lines a table was written on, for the paragraph it bails to.
    private static func sourceText(of table: Markdown.Table, in lines: [String]) -> String {
        guard let range = table.range else { return plain(table) }
        let first = max(0, range.lowerBound.line - 1)
        let last = min(lines.count, range.upperBound.line)
        guard first < last else { return plain(table) }
        return lines[first..<last].joined(separator: "\n")
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
                out.append(emphasised(strong, with: .bold))
            case let emphasis as Emphasis:
                out.append(emphasised(emphasis, with: .italic))
            case let strike as Strikethrough:
                out.append(struckThrough(strike))
            case let link as Markdown.Link:
                // The destination travels with the label. Without it the run is blue text that
                // does nothing: §5 says links are real and clickable, and a renderer that drew only
                // the label made every labelled link in model output unusable. Carried **as
                // written**, because resolving a relative one needs the channel's working
                // directory, and this string is the key of a cache shared by every channel.
                var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13),
                                                                 .foregroundColor: NSColor.linkColor]
                if let destination = link.destination,
                   let url = TimelineLinkDestination.url(for: destination) {
                    attributes[.link] = url
                }
                out.append(NSAttributedString(string: plain(link), attributes: attributes))
            case is SoftBreak:
                // A break node has no children, so the default arm's plain-text projection of it is
                // the empty string and the two words either side would be concatenated. The engine
                // renders with `breaks` **off** (§5), which makes a soft break a space.
                out.append(NSAttributedString(string: " ",
                                              attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            case is LineBreak:
                out.append(NSAttributedString(string: "\n",
                                              attributes: [.font: NSFont.systemFont(ofSize: 13)]))
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

    /// Emphasis **applied over** the runs under it, rather than replacing them.
    ///
    /// The two arms used to build one run from the node's plain-text projection, which is lossy in
    /// both directions: a nested link kept its label and lost its destination — blue text that does
    /// nothing — and an `InlineHTML` node, having no children, projected to the empty string, so
    /// `**a <b>b</b> c**` reached the reader with its tags gone. Walking the children through
    /// `inline` keeps every attribute they carry and adds the trait on top of the fonts they
    /// already have, which is also what nests one emphasis inside another.
    private static func emphasised(_ markup: Markup,
                                   with trait: NSFontDescriptor.SymbolicTraits) -> NSAttributedString {
        let content = NSMutableAttributedString(attributedString: inline(markup))
        let whole = NSRange(location: 0, length: content.length)
        // Collected before anything is written: mutating an attribute inside its own enumeration
        // rewrites the ranges the enumeration is walking.
        var runs: [(NSRange, NSFont)] = []
        content.enumerateAttribute(.font, in: whole) { value, range, _ in
            runs.append((range, value as? NSFont ?? NSFont.systemFont(ofSize: 13)))
        }
        for (range, font) in runs {
            let descriptor = font.fontDescriptor
                .withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            guard let restyled = NSFont(descriptor: descriptor, size: font.pointSize) else { continue }
            content.addAttribute(.font, value: restyled, range: range)
        }
        return content
    }

    /// `del` matches only `~~x~~` — the first of the two reproducible `marked` overrides
    /// (parity §41.17).
    ///
    /// cmark's GFM extension accepts a single tilde as a delimiter and the engine's vendored
    /// tokenizer does not, so `~one~` reads as struck-through text here and as literal characters in
    /// the terminal. The delimiter's width is not on the node, but it is the distance from the
    /// node's own start to its first child's, which is one column for `~` and two for `~~`.
    private static func struckThrough(_ strike: Strikethrough) -> NSAttributedString {
        let content = NSMutableAttributedString(attributedString: inline(strike))
        guard delimiterWidth(of: strike) > 1 else {
            let literal = NSMutableAttributedString(string: "~",
                                                    attributes: [.font: NSFont.systemFont(ofSize: 13)])
            literal.append(content)
            literal.append(NSAttributedString(string: "~", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
            return literal
        }
        content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                             range: NSRange(location: 0, length: content.length))
        return content
    }

    /// How many tildes opened this node. Two when the source range is unavailable, which is the
    /// reading that changes nothing.
    static func delimiterWidth(of strike: Strikethrough) -> Int {
        guard let outer = strike.range, let inner = strike.child(at: 0)?.range else { return 2 }
        return inner.lowerBound.column - outer.lowerBound.column
    }

    /// A node's text, with the whitespace its break nodes stand for.
    ///
    /// Headings, emphasis and link labels are projected through here rather than walked, so a break
    /// inside any of them reaches a reader only if this reproduces it — a childless node otherwise
    /// projects to the empty string and joins the words either side of it into one.
    private static func plain(_ markup: Markup) -> String {
        if let text = markup as? Markdown.Text { return text.string }
        if let code = markup as? InlineCode { return code.code }
        if markup is SoftBreak { return " " }
        if markup is LineBreak { return "\n" }
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

    /// One highlighter and one grammar set, for the reason `MarkdownText.shared` is one cache.
    static let shared = CodeHighlighter()

    private let lock = NSLock()
    private var cache: [Key: NSAttributedString] = [:]
    /// The keys in least-recently-used order, oldest first — the bound below, and what makes it a
    /// bound by *use*: a block still being scrolled past survives, and one drawn once an hour ago
    /// does not.
    private var order: [Key] = []
    /// **Bounded, for `MarkdownText`'s reason and one more.** This cache is process-wide and holds
    /// the source and its styled form for every fenced block the app has ever drawn, so a session
    /// left open all day accumulated a transcript's worth of attributed strings that nothing ever
    /// released. Entries rather than bytes: a code block is bounded by the message that carried it,
    /// so counting them is the same question with less arithmetic.
    private let capacity = 256
    private var inFlight: Set<Key> = []
    private let highlighter = Highlighter()
    private var enabled = true
    private var requests = 0
    private var mainThreadRuns = 0
    private var offMainRuns = 0

    struct Key: Hashable { let code: String; let language: String }

    /// `syntaxHighlightingDisabled` from `get_settings` is honoured — parity §41.17 records it as
    /// an accessibility choice for some users. The render context carries it and the table sets it
    /// on every publish; it defaults to on until Task 5's readout lands.
    ///
    /// Read and written under the same lock as the cache, because `styled` is called from the main
    /// actor and the preference is set from there while a detached highlight is in flight.
    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    /// Sets the preference and answers whether it changed, so a caller knows when the markdown
    /// cache it shares this pipeline with has to be dropped.
    @discardableResult
    func setEnabled(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled != value else { return false }
        enabled = value
        cache = [:]
        order = []
        return true
    }

    /// How many highlights have been asked for, cumulatively. §6 says an open fenced block is not
    /// highlighted until its closing fence arrives, and this is what says so in a count.
    var highlightRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    /// How many highlights ran on the main thread, and how many off it. §6's "never on the main
    /// thread" is a property of where the work executes, which no assertion over the *result* can
    /// see: these two counts are the trace that can.
    var mainThreadHighlights: Int {
        lock.lock(); defer { lock.unlock() }
        return mainThreadRuns
    }

    var offMainHighlights: Int {
        lock.lock(); defer { lock.unlock() }
        return offMainRuns
    }

    /// The styled code, and whether what came back was the **cold fallback**.
    ///
    /// One call path, for the reason there is one highlighter: a caller that keeps its result — the
    /// markdown cache does, inside a settled block — needs to know that what it holds will be
    /// superseded, and no assertion over the returned string can tell a fallback from a language
    /// with one colour. The key comes back so the holder can ask later whether the fill has landed;
    /// nil means what came back is final.
    func styling(code: String, language: String?) -> (text: NSAttributedString, cold: Key?) {
        let plain = NSAttributedString(string: code,
                                       attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        guard isEnabled, let language, highlighter.hasLanguage(named: language) else { return (plain, nil) }
        count(request: 1)
        let key = Key(code: code, language: language)
        if let hit = cached(key) { return (hit, nil) }
        guard claim(key) else { return (plain, key) }
        Task.detached(priority: .userInitiated) { [self] in
            let styled = highlighter.attributedString(for: code, language: language)
            countThread()
            store(key, styled, releasing: true)
        }
        return (plain, key)
    }

    /// Whether this key's styled form is in the cache now. The markdown cache's staleness check,
    /// and the only thing it asks of the highlighter.
    func isCached(_ key: Key) -> Bool { cached(key) != nil }

    /// Fills the cache off-main before a measurement, so the measured path is the cached one.
    func warm(_ blocks: [(code: String, language: String?)]) async {
        await Task.detached(priority: .utility) { [self] in
            for block in blocks {
                guard isEnabled, let language = block.language,
                      highlighter.hasLanguage(named: language) else { continue }
                let key = Key(code: block.code, language: language)
                guard cached(key) == nil else { continue }
                let styled = highlighter.attributedString(for: block.code, language: language)
                countThread()
                store(key, styled, releasing: false)
            }
        }.value
    }

    // The lock is only ever taken inside these three synchronous members. `NSLock.lock()` is
    // unavailable from an asynchronous context — it blocks a cooperative thread — so the async
    // paths above call these rather than taking it themselves.
    private func cached(_ key: Key) -> NSAttributedString? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[key] else { return nil }
        touch(key)
        return hit
    }

    /// True when this caller is the one that should do the work; false when another already is.
    private func claim(_ key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(key).inserted
    }

    private func count(request: Int) {
        lock.lock(); defer { lock.unlock() }
        requests += request
    }

    /// Records where one highlight actually ran. Called from inside the work, which is the only
    /// place that knows.
    private func countThread() {
        let onMain = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        if onMain { mainThreadRuns += 1 } else { offMainRuns += 1 }
    }

    private func store(_ key: Key, _ value: NSAttributedString, releasing: Bool) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = value
        touch(key)
        if order.count > capacity, let evicted = order.first {
            order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        if releasing { inFlight.remove(key) }
    }

    /// Moves a key to the most-recently-used end. Called with the lock held.
    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}
