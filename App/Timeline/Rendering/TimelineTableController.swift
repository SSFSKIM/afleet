import AppKit
import OSLog
import SwiftUI
import FleetKit

// MARK: - What the pill reads

/// The two things the jump-to-bottom affordance draws, published to SwiftUI.
///
/// Separate from the controller because the controller is an `NSObject` the table delegates to and
/// the pill is a SwiftUI view: an observable box is the whole of what crosses between them, and it
/// keeps `@Observable` off a type that is also a data source.
@MainActor
@Observable
final class TimelineScrollState {
    /// Whether the viewport is at the bottom, and therefore whether new items follow.
    var isPinnedToBottom = true
    /// How many rows have arrived since the viewport left the bottom. Zero while pinned.
    var unseenCount = 0
}

// MARK: - The table

/// One channel's table: rows keyed by `ItemID`, heights cached per id and invalidated only for the
/// ids a publish names, and a streaming delta that reloads one row (child spec §3).
///
/// **Why the reload is counted.** `reloadedRows` is not instrumentation bolted on for a test; it is
/// the property §3 is about. A `List` re-evaluates its content over the whole collection on every
/// change to the array it was given, and the array the model publishes is rebuilt whole on every
/// delta — so "one row reloaded" is the claim that separates this table from the thing it replaced,
/// and a claim nothing can read is a claim nothing can hold.
@MainActor
final class TimelineTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let scrollView = NSScrollView()
    let tableView = NSTableView()

    /// What the jump-to-bottom pill reads.
    let scroll = TimelineScrollState()

    /// The item rows, in the order the timeline holds them. The streaming preview is not one of them
    /// — it is not an item yet — and `rows` appends it.
    private(set) var itemRows: [RenderedRow] = []

    /// The row the message currently streaming draws into, kept across publishes so a delta appends
    /// a fragment rather than rebuilding the message (§4).
    private(set) var previewRow: RenderedRow?

    /// What the table draws: the items, then the streaming preview if there is one.
    var rows: [RenderedRow] { previewRow.map { itemRows + [$0] } ?? itemRows }

    /// Row heights by the row's own key. `ItemID` carries a config-home path and is never logged; it
    /// is a dictionary key here and nothing else.
    private var heights: [String: CGFloat] = [:]

    /// How many heights this controller has had to measure, cumulatively. A cache dropped wholesale
    /// on every publish re-measures the whole table, and this is what says so in a count.
    private(set) var heightMeasurements = 0

    /// The row indices the **last** `apply` reloaded. Reset on every publish, so it is bounded by
    /// the table and reads as what this update cost: one index for a streaming delta, every index
    /// for the whole-table reload §3 exists to avoid.
    private(set) var reloadedRows: [Int] = []

    /// The per-row capabilities. They arrive as an environment value on the list's subtree and are
    /// handed on from here to each hosted row, because these rows are hosted by AppKit: SwiftUI's
    /// environment does not cross an `NSHostingView` the table made itself.
    private var context: TimelineRenderContext?

    private let markdown = MarkdownText()
    private let highlighter = CodeHighlighter()

    /// How close to the document's bottom still counts as the bottom. A tolerance and not an
    /// equality, because a fractional row height leaves the viewport a hair short of the end.
    static let bottomTolerance: CGFloat = 2

    /// The width a height is measured at before the table has one. A row measured at zero width is
    /// infinitely tall and would poison the cache for the row's whole life.
    static let measuringWidth: CGFloat = 320

    static let emptyRowHeight: CGFloat = 18

    /// `nonisolated` because the one line it writes is written from the warm-up's detached task,
    /// which is where the counts it reports become final. `Logger` is `Sendable`.
    nonisolated private static let log = Logger(subsystem: "com.afleet.app", category: "timeline-render")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("timeline"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = false
        tableView.backgroundColor = .textBackgroundColor
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // The sticky-to-bottom rule reads the viewport, so the viewport has to say when it moved.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportMoved),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Applying a publish

    /// One publish, applied: the items reconciled by key, the preview appended to, and the scroll
    /// position either held on its anchor or followed to the bottom.
    func apply(_ input: TimelineRenderInput, context: TimelineRenderContext? = nil) {
        self.context = context
        // The reader's syntax-highlighting preference, honoured on the publish that carries it. A
        // settled block holds its styled code inside it, so the parsed-block cache goes with the
        // flip — otherwise a channel already on screen keeps drawing highlighted code after the
        // preference turned highlighting off.
        if highlighter.setEnabled(context?.syntaxHighlightingEnabled ?? true) { preferenceChanged() }
        reloadedRows = []
        let anchor = anchorAtViewportTop()
        let appended = applyItems(input) + applyPreview(input.preview)
        settleScroll(anchor: anchor, appended: appended)
    }

    /// The syntax-highlighting preference flipped: everything already built from it is dropped.
    ///
    /// An item's row holds no text of its own — its content is its builder's, and a builder reaches
    /// the pipeline through the caches this drops — so a reload is the whole of what those rows
    /// need. A row that *does* carry source is re-settled here. The streaming preview is
    /// deliberately left alone: rebuilding it would reset the character count the delta path indexes
    /// the preview's text by and replay text already on screen, and the message it is drawing lands
    /// as a durable item within the turn.
    private func preferenceChanged() {
        markdown.clear()
        for index in itemRows.indices where !itemRows[index].pendingSource.isEmpty {
            var rebuilt = RenderedRow(key: itemRows[index].key, source: itemRows[index].pendingSource)
            rebuilt.settle(markdown: markdown, highlighter: highlighter)
            itemRows[index] = rebuilt
        }
        heights = [:]
        tableView.reloadData()
    }

    /// The item half. Returns how many rows were appended.
    @discardableResult
    private func applyItems(_ input: TimelineRenderInput) -> Int {
        let incoming = input.rows.map(RenderedRow.init)
        let previous = itemRows
        let keys = incoming.map(\.key)
        let previousKeys = previous.map(\.key)
        // A publish that changed only the preview must not cost the item half anything at all.
        if keys == previousKeys, Self.areUnchanged(previous, incoming) { return 0 }

        // The ids this publish names. `changes` is the model's own answer and is preferred; a
        // publish that names none — the whole array republished, which is what the model does today
        // — is diffed here, because the alternative is a table reload for a one-character delta.
        let named = Self.namedKeys(in: input.changes) ?? Self.changedKeys(from: previous, to: incoming)
        // Heights survive for every id this publish did **not** name (§3).
        for key in named { heights.removeValue(forKey: key) }

        if keys == previousKeys {
            itemRows = incoming
            reload(keys: named, in: keys)
            return 0
        }
        if !previousKeys.isEmpty, keys.starts(with: previousKeys) {
            // An append, which is what a channel does all day: the new rows are inserted and the old
            // ones are not touched, so a thousand-row channel does not re-measure a thousand rows to
            // show one message.
            itemRows = Array(incoming.prefix(previousKeys.count))
            reload(keys: named.intersection(previousKeys), in: keys)
            for row in incoming.dropFirst(previousKeys.count) { appendRow(row) }
            return keys.count - previousKeys.count
        }
        // A removal, a reorder, or a first render: the one case that costs a table.
        setRows(incoming)
        return max(0, keys.count - previousKeys.count)
    }

    /// The streaming half (§4). Returns how many rows were appended.
    @discardableResult
    private func applyPreview(_ preview: StreamingPreview?) -> Int {
        let index = itemRows.count
        guard let preview else {
            // The durable message landed and the preview was dropped; the row goes with it, and the
            // durable item's own row is already in `itemRows`, so the message never blinks.
            guard previewRow != nil else { return 0 }
            previewRow = nil
            tableView.removeRows(at: IndexSet(integer: index), withAnimation: [])
            return 0
        }
        let key = Self.previewKey(for: preview)
        if let existing = previewRow, existing.key == key, preview.text.count >= existing.consumedCharacters {
            let fragment = String(preview.text.dropFirst(existing.consumedCharacters))
            guard !fragment.isEmpty else { return 0 }
            appendToLastRow(fragment)
            return 0
        }
        let hadPreview = previewRow != nil
        var built = RenderedRow(key: key, source: preview.text)
        built.settle(markdown: markdown, highlighter: highlighter)
        previewRow = built
        heights.removeValue(forKey: key)
        guard hadPreview else {
            tableView.insertRows(at: IndexSet(integer: index), withAnimation: [])
            return 1
        }
        reload(IndexSet(integer: index))
        return 0
    }

    /// A streaming preview's row key. Not an `ItemID`: a preview is not an item, and keying it by
    /// the message id is what lets one message's deltas land in one row.
    static func previewKey(for preview: StreamingPreview) -> String {
        "preview:" + (preview.messageID ?? "streaming")
    }

    /// The ids a change set names, or nil when it names none.
    static func namedKeys(in changes: [TimelineChange]) -> Set<String>? {
        var keys: Set<String> = []
        for change in changes {
            switch change {
            case .inserted(let id), .updated(let id), .removed(let id): keys.insert(id.key)
            default: continue
            }
        }
        return keys.isEmpty ? nil : keys
    }

    /// The keys that arrived, left, or changed value between two row lists.
    static func changedKeys(from previous: [RenderedRow], to incoming: [RenderedRow]) -> Set<String> {
        let before = Dictionary(previous.map { ($0.key, $0.item) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(incoming.map { ($0.key, $0.item) }, uniquingKeysWith: { first, _ in first })
        var keys = Set(before.keys).symmetricDifference(after.keys)
        for (key, item) in after where before[key] != nil && before[key] != item { keys.insert(key) }
        return keys
    }

    /// Whether two row lists of the same keys draw the same thing.
    static func areUnchanged(_ previous: [RenderedRow], _ incoming: [RenderedRow]) -> Bool {
        previous.count == incoming.count
            && zip(previous, incoming).allSatisfy { $0.item == $1.item }
    }

    private func reload(keys: Set<String>, in order: [String]) {
        guard !keys.isEmpty else { return }
        reload(IndexSet(order.indices.filter { keys.contains(order[$0]) }))
    }

    private func reload(_ indices: IndexSet) {
        guard !indices.isEmpty else { return }
        tableView.noteHeightOfRows(withIndexesChanged: indices)
        tableView.reloadData(forRowIndexes: indices, columnIndexes: IndexSet(integer: 0))
        reloadedRows.append(contentsOf: indices)
    }

    // MARK: - The scroll behaviours (§3, parity §41.8)

    private struct ViewportAnchor {
        let key: String
        /// How far below the viewport's top edge the anchored row sits. Signed: the row nearest the
        /// top is usually part-scrolled off it.
        let offset: CGFloat
    }

    /// The item nearest the viewport top, remembered before a commit.
    private func anchorAtViewportTop() -> ViewportAnchor? {
        guard !scroll.isPinnedToBottom else { return nil }
        let visible = scrollView.contentView.documentVisibleRect
        let index = tableView.row(at: NSPoint(x: 1, y: visible.minY + 1))
        let all = rows
        guard index >= 0, all.indices.contains(index) else { return nil }
        return ViewportAnchor(key: all[index].key, offset: tableView.rect(ofRow: index).minY - visible.minY)
    }

    /// Puts the viewport back where the reader left it — at the bottom if it was pinned there, and
    /// otherwise on the anchor, corrected by however far the anchored row moved.
    ///
    /// Without the correction, content arriving above the viewport shoves the reader's place down by
    /// exactly the height of what arrived, which is the third of parity §41.8's three behaviours and
    /// the one a naive list gets wrong.
    private func settleScroll(anchor: ViewportAnchor?, appended: Int) {
        tableView.layoutSubtreeIfNeeded()
        if scroll.isPinnedToBottom, context?.autoScrollEnabled ?? true {
            scrollToBottom()
            return
        }
        if appended > 0 { scroll.unseenCount += appended }
        guard let anchor, let index = rows.firstIndex(where: { $0.key == anchor.key }) else { return }
        let target = tableView.rect(ofRow: index).minY - anchor.offset
        scrollTo(y: target)
    }

    /// What the jump-to-bottom pill does, and what a pinned viewport does on every publish.
    func scrollToBottom() {
        tableView.layoutSubtreeIfNeeded()
        scrollTo(y: max(0, tableView.bounds.height - scrollView.contentView.bounds.height))
        scroll.unseenCount = 0
        scroll.isPinnedToBottom = true
    }

    private func scrollTo(y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// True while the viewport is at the document's bottom.
    var isAtBottom: Bool {
        let visible = scrollView.contentView.documentVisibleRect
        return visible.maxY >= tableView.bounds.height - Self.bottomTolerance
    }

    /// The **silent re-pin** (§3): scrolling back to the bottom re-arms the follow and clears the
    /// unseen count. There is no affordance to press and no state for a caller to set — a reader who
    /// returns to the bottom simply gets the stream back.
    @objc private func viewportMoved() {
        let atBottom = isAtBottom
        scroll.isPinnedToBottom = atBottom
        if atBottom { scroll.unseenCount = 0 }
    }

    // MARK: - The S7 path

    /// Replaces the whole table: the one case a publish cannot do row by row — a removal, a reorder
    /// or a first render — and the spike's entry point, whole documents in, parsed once.
    func setRows(_ rows: [RenderedRow]) {
        itemRows = rows
        for index in itemRows.indices { itemRows[index].settle(markdown: markdown, highlighter: highlighter) }
        // A rebuilt table is not a reason to re-measure a row that is still in it: only the heights
        // of keys that left are dropped.
        let surviving = Set(rows.map(\.key))
        heights = heights.filter { surviving.contains($0.key) }
        tableView.reloadData()
        reloadedRows = Array(self.rows.indices)

        // §6's "never on the main thread": a fenced block that missed the cache above rendered
        // unhighlighted, which is the correct thing to draw and the wrong thing to leave. The fill
        // runs off-main and the next reload of that row picks it up. A row that carries an item has
        // no source of its own — its content is its builder's — so only the rows that do are warmed.
        let sources = rows.map(\.pendingSource).filter { !$0.isEmpty }
        guard !sources.isEmpty else { return }
        let markdown = self.markdown
        let highlighter = self.highlighter
        Task.detached(priority: .utility) {
            await highlighter.warm(Self.fences(in: sources))
            await markdown.warm(sources, highlighter: highlighter)
            // What the warm-up cost, in counts and never in content (§11). It is the pipeline's own
            // account of §4 and §6 — how many blocks were parsed, how many highlights were asked for
            // and how many of them ran anywhere near the main thread — and it is what a slow channel
            // is read from rather than guessed at.
            Self.log.debug("timeline warm: \(markdown.parseCount, privacy: .public) parse(s), \(highlighter.highlightRequests, privacy: .public) highlight request(s), \(highlighter.offMainHighlights, privacy: .public) off-main, \(highlighter.mainThreadHighlights, privacy: .public) on-main")
        }
    }

    /// Every fenced block in a set of documents, for the warm-up.
    static func fences(in documents: [String]) -> [(code: String, language: String?)] {
        var out: [(code: String, language: String?)] = []
        for document in documents {
            var lines = document.split(separator: "\n", omittingEmptySubsequences: false)[...]
            while let open = lines.firstIndex(where: { $0.hasPrefix("```") }) {
                let language = String(lines[open].dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let rest = lines[lines.index(after: open)...]
                guard let close = rest.firstIndex(where: { $0.hasPrefix("```") }) else { break }
                out.append((rest[rest.startIndex..<close].joined(separator: "\n"), language.isEmpty ? nil : language))
                lines = rest[rest.index(after: close)...]
            }
        }
        return out
    }

    /// Adds a row and inserts it, rather than reloading the table around it.
    func appendRow(_ row: RenderedRow) {
        itemRows.append(row)
        tableView.insertRows(at: IndexSet(integer: itemRows.count - 1), withAnimation: [])
    }

    /// The streaming path (§4): the fragment goes onto whichever row is streaming — the preview when
    /// there is one, and otherwise the last row, which is what the spike drives — and **one row**
    /// reloads.
    ///
    /// Returns the phase costs of this one update, which is what S7 attributes a slow frame to.
    @discardableResult
    func appendToLastRow(_ fragment: String) -> RenderPhases {
        let all = rows
        guard let index = all.indices.last else { return RenderPhases() }
        var phases = RenderPhases()
        var row = all[index]

        let parse = RenderClock.start()
        row.append(fragment, markdown: markdown, highlighter: highlighter, phases: &phases)
        phases.markdown += RenderClock.since(parse) - phases.highlight
        if previewRow != nil { previewRow = row } else { itemRows[index] = row }

        let host = RenderClock.start()
        heights.removeValue(forKey: row.key)
        reload(IndexSet(integer: index))
        phases.hosting += RenderClock.since(host)
        return phases
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let all = rows
        guard all.indices.contains(row) else { return Self.emptyRowHeight }
        let key = all[row].key
        if let cached = heights[key] { return cached }
        heightMeasurements += 1
        let measured = height(of: all[row], width: max(tableView.bounds.width, Self.measuringWidth))
        heights[key] = measured
        return measured
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let all = rows
        guard all.indices.contains(row) else { return nil }
        // SwiftUI hosted per visible row, which is what contract Y1's `AnyView` builder requires and
        // what S7's `hosting` signpost measures.
        let hosting: NSView = all[row].item.map { NSHostingView(rootView: body(for: $0)) }
            ?? NSHostingView(rootView: TimelineMarkdownRow(row: all[row]))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }

    /// One item's row, drawn by whichever builder owns its kind (contract Y1) and handed the render
    /// context on its own subtree.
    private func body(for item: TimelineRow) -> some View {
        TimelineRowSlot(row: item).environment(\.timelineContext, context)
    }

    private func height(of row: RenderedRow, width: CGFloat) -> CGFloat {
        guard let item = row.item else { return row.height(forWidth: width) }
        // The width is pinned on the SwiftUI side rather than on the hosting view: `fittingSize`
        // is the compressed layout size, and a hosted row with no width constraint compresses to
        // its longest line rather than wrapping to the column.
        let hosting = NSHostingView(rootView: body(for: item).frame(width: width))
        return max(Self.emptyRowHeight, ceil(hosting.fittingSize.height))
    }
}
