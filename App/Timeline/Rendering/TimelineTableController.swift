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

    /// The text the preview row was last drawn from, which is what says whether the next preview
    /// under the same key **continues** this one or is a second incarnation of it (§4).
    ///
    /// C3 clears the preview on the `assistant` frame and lets a later `content_block_start` open a
    /// fresh one, and a preview with no message id keys the same either time — so "same key, no
    /// shorter" is not continuation, and reading it as one splices the new message's tail onto the
    /// old message's body. Continuation is a prefix, which coalescing cannot forge.
    private var previewText = ""

    /// What the table draws: the items, then the streaming preview if there is one.
    ///
    /// **Reached by index and not as an array on every hot path.** Materialising this concatenates
    /// the whole history into a fresh array, and the table asks for a row far more often than it
    /// asks for a list of them: `numberOfRows`, `viewFor` and `heightOfRow` are each called per
    /// visible row per layout, and `heightOfRow` asked for the array *before* it consulted its
    /// cache — so N height queries on a channel of N messages copied N messages N times, which is
    /// the one shape §8.3 forbids. The three accessors below answer the same questions in index
    /// arithmetic; this property stays for the callers that genuinely want the list.
    var rows: [RenderedRow] { previewRow.map { itemRows + [$0] } ?? itemRows }

    /// How many rows the table holds: the items, and the preview when there is one.
    var rowCount: Int { itemRows.count + (previewRow == nil ? 0 : 1) }

    /// The row at a table index, or nil for an index the table does not hold. The preview sits one
    /// past the last item, which is where `applyPreview` inserts and removes it.
    func row(at index: Int) -> RenderedRow? {
        if itemRows.indices.contains(index) { return itemRows[index] }
        return index == itemRows.count ? previewRow : nil
    }

    /// The table index of a row key, or nil for a key this table no longer holds.
    func index(ofKey key: String) -> Int? {
        if let previewRow, previewRow.key == key { return itemRows.count }
        return itemRows.firstIndex { $0.key == key }
    }

    /// Row heights by the row's own key. `ItemID` carries a config-home path and is never logged; it
    /// is a dictionary key here and nothing else.
    private var heights: [String: CGFloat] = [:]

    /// The width every cached height was measured at. A height is a function of the id *and* the
    /// width; a window dragged narrower keeps drawing wrapped text at its old height unless the
    /// cache goes with the width.
    private var measuredWidth: CGFloat?

    /// The rows the table currently has mounted, by key, so a reload updates the view a row already
    /// has rather than building a second one and dropping the SwiftUI state that was in the first.
    private var hosts: [String: TimelineRowHostView] = [:]

    /// How many times a hosted row has told the table its content changed size. Counted for the same
    /// reason `reloadedRows` is: an invalidation path nothing can read is a path nothing can hold.
    private(set) var hostedHeightNotes = 0

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

    /// The shared pipeline, not a second one: the row builders under `Rows/` parse through
    /// `MarkdownText.shared` and a table with a cache of its own would parse every message twice —
    /// once to draw it and once to measure it.
    private let markdown = MarkdownText.shared
    private let highlighter = CodeHighlighter.shared

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
        // The table follows the viewport's width, which is what makes a row's measured width the
        // width it is drawn at — and what makes the width invalidation below have something to say.
        tableView.autoresizingMask = [.width]
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(tableResized),
                                               name: NSView.frameDidChangeNotification,
                                               object: tableView)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // The sticky-to-bottom rule reads the viewport, so the viewport has to say when it moved.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportMoved),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        // A document view is not resized by its clip view, so the table's width is followed here.
        // Without it a window dragged narrower draws every row at the width it had when it was wide
        // and clips the right-hand half of each of them.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportResized),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Applying a publish

    /// One publish, applied: the items reconciled by key, the preview appended to, and the scroll
    /// position either held on its anchor or followed to the bottom.
    func apply(_ input: TimelineRenderInput, context: TimelineRenderContext? = nil) {
        let contextChanged = Self.differs(self.context, context)
        self.context = context
        // The reader's syntax-highlighting preference, honoured on the publish that carries it. A
        // settled block holds its styled code inside it, so the parsed-block cache goes with the
        // flip — otherwise a channel already on screen keeps drawing highlighted code after the
        // preference turned highlighting off.
        if highlighter.setEnabled(context?.syntaxHighlightingEnabled ?? true) { preferenceChanged() }
        reloadedRows = []
        var anchor = anchorAtViewportTop()
        let previousKeys = itemRows.map(\.key)
        let appended = applyItems(input) + applyPreview(input.preview)
        // The preview the reader was anchored to has become an item: the anchor moves with it, or
        // the correction below finds no anchored row and anything that arrived above the
        // replacement in the same publish shoves the reader's place down by its whole height.
        if let held = anchor, held.key.hasPrefix("preview:"), previewRow == nil,
           let replacement = Self.firstAppendedKey(previous: previousKeys, incoming: itemRows.map(\.key)) {
            anchor = ViewportAnchor(key: replacement, offset: held.offset)
        }
        // A row that survived this publish keeps its view, so a context that changed — a cwd the
        // channel has just learnt, an overlay that has gone stale, a neighbourhood rebuilt around a
        // new item — has to reach the roots that view already holds.
        pruneHosts()
        if contextChanged { refreshHostedRoots() }
        settleScroll(anchor: anchor, appended: appended)
    }

    /// The first key this publish appended **after** everything the previous publish held, which is
    /// where the message that was streaming lands. Keys inserted above the old tail are a backfill
    /// and are not the preview's replacement.
    static func firstAppendedKey(previous: [String], incoming: [String]) -> String? {
        let before = Set(previous)
        guard let tail = previous.last, let position = incoming.firstIndex(of: tail) else {
            return incoming.first { !before.contains($0) }
        }
        return incoming[incoming.index(after: position)...].first { !before.contains($0) }
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
            previewText = ""
            tableView.removeRows(at: IndexSet(integer: index), withAnimation: [])
            return 0
        }
        let key = Self.previewKey(for: preview)
        // **A prefix, and not a length.** Two incarnations of the preview arrive under one key
        // whenever the reducer clears it and a `content_block_start` opens a nil-id one again, and
        // coalescing can hide the clear entirely; only text that still begins with what is on
        // screen is the same message going on.
        if let existing = previewRow, existing.key == key, preview.text.hasPrefix(previewText) {
            let fragment = String(preview.text.dropFirst(existing.consumedCharacters))
            guard !fragment.isEmpty else { return 0 }
            previewText = preview.text
            appendToLastRow(fragment)
            return 0
        }
        let hadPreview = previewRow != nil
        var built = RenderedRow(key: key, source: preview.text)
        built.settle(markdown: markdown, highlighter: highlighter)
        previewRow = built
        previewText = preview.text
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
        guard index >= 0, let anchored = row(at: index) else { return nil }
        return ViewportAnchor(key: anchored.key, offset: tableView.rect(ofRow: index).minY - visible.minY)
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
        guard let anchor, let index = index(ofKey: anchor.key) else { return }
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
        reloadedRows = Array(0..<rowCount)

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
        let index = rowCount - 1
        guard var row = self.row(at: index) else { return RenderPhases() }
        var phases = RenderPhases()

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

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let rendered = self.row(at: row) else { return Self.emptyRowHeight }
        if let cached = heights[rendered.key] { return cached }
        heightMeasurements += 1
        let width = max(tableView.bounds.width, Self.measuringWidth)
        measuredWidth = width
        let measured = height(of: rendered, width: width)
        heights[rendered.key] = measured
        return measured
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let rendered = self.row(at: row) else { return nil }
        let key = rendered.key
        // SwiftUI hosted per visible row, which is what contract Y1's `AnyView` builder requires and
        // what S7's `hosting` signpost measures — and **the same host across reloads of one key**.
        // A card's in-flight guard and a question's half-typed draft are SwiftUI state, which lives
        // in the hosting view: a fresh one per reload throws them away, and a message streaming
        // beside a card reloads thirty times a second.
        if let existing = hosts[key] {
            existing.update(root: root(for: rendered), context: context)
            return existing
        }
        let host = TimelineRowHostView(key: key, root: root(for: rendered), context: context)
        host.onHeightChange = { [weak self] key, height in self?.hostedRow(key, measured: height) }
        hosts[key] = host
        return host
    }

    /// One row's SwiftUI content: whichever builder owns the item's kind (contract Y1), handed the
    /// render context on its own subtree, or the markdown pipeline for the two rows that are not
    /// items.
    func root(for row: RenderedRow) -> AnyView {
        // The **streaming preview takes the same context as an item** (contract Y7). It was returned
        // bare, so a link pressed in the message being streamed reached the router with no context,
        // was declined, and fell through to the system — where a relative destination names a file in
        // the app's own directory or none at all. The reader cannot tell a streaming message from a
        // settled one, and the link has to behave the same in both.
        guard let item = row.item else {
            return AnyView(TimelineMarkdownRow(row: row).environment(\.timelineContext, context))
        }
        return AnyView(body(for: item))
    }

    /// One item's row, drawn by whichever builder owns its kind (contract Y1) and handed the render
    /// context on its own subtree.
    private func body(for item: TimelineRow) -> some View {
        TimelineRowSlot(row: item).environment(\.timelineContext, context)
    }

    /// Drops the hosts of rows this publish no longer holds. A host outlives its row only as far as
    /// the end of the publish that removed it.
    private func pruneHosts() {
        guard !hosts.isEmpty else { return }
        let live = Set(rows.map(\.key))
        hosts = hosts.filter { live.contains($0.key) }
    }

    /// Hands every mounted row the context again. Only the rows the table has actually built are
    /// touched, which is the visible ones.
    private func refreshHostedRoots() {
        guard !hosts.isEmpty else { return }
        let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, host) in hosts {
            guard let row = byKey[key] else { continue }
            host.update(root: root(for: row), context: context)
        }
    }

    /// A hosted row reporting the height of what it is actually drawing (§3).
    ///
    /// The only invalidation this table had accompanied a reload it issued itself, so a disclosure
    /// opening, a card mounting asynchronously and anything else that changes a row's size without a
    /// publish behind it was drawn into the height the row had before.
    ///
    /// **The growth moves the document, so it settles the scroll exactly as a publish does.** A row
    /// that grows adds its whole difference to the table's height with no publish behind it: a
    /// viewport pinned to the bottom keeps its old offset and is no longer at the bottom — and once
    /// it is not, every later publish holds it where the growth left it instead of following the
    /// stream. The anchor is taken before the height moves and settled after it, the two calls
    /// `apply` makes around its own commit, so an unpinned reader keeps the row they were on too.
    func hostedRow(_ key: String, measured height: CGFloat) {
        let height = max(Self.emptyRowHeight, ceil(height))
        guard abs((heights[key] ?? -1) - height) > 1 else { return }
        let anchor = anchorAtViewportTop()
        heights[key] = height
        hostedHeightNotes += 1
        guard let index = index(ofKey: key) else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        // Nothing was appended: growth is not arrival, and a row growing out of sight is not an
        // unseen message.
        settleScroll(anchor: anchor, appended: 0)
    }

    /// The viewport's width changed: the table follows it, and the heights follow the table.
    @objc private func viewportResized() {
        let width = scrollView.contentView.bounds.width
        if width > 0, abs(tableView.frame.width - width) > 1 {
            tableView.setFrameSize(NSSize(width: width, height: tableView.frame.height))
        }
        tableResized()
    }

    /// The table's width changed, so every cached height was measured at a width that is gone.
    @objc private func tableResized() {
        let width = max(tableView.bounds.width, Self.measuringWidth)
        guard let measuredWidth, abs(measuredWidth - width) > 1 else { return }
        self.measuredWidth = nil
        heights = [:]
        for host in hosts.values { host.widthChanged() }
        let count = rowCount
        guard count > 0 else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<count))
    }

    /// Whether two render contexts draw differently.
    ///
    /// The value's own fields — including the two capabilities a row's affordances are gated on,
    /// ownership and the composer — are compared where they are values, and by identity where they
    /// are the channel-scoped objects a row shares — a context carrying a *different* collapse state or
    /// reservation set is a different channel's context, and a row holding the old one would fold
    /// and answer into an object nothing else reads.
    static func differs(_ previous: TimelineRenderContext?, _ next: TimelineRenderContext?) -> Bool {
        guard let previous else { return next != nil }
        guard let next else { return true }
        if previous.key != next.key || previous.cwd != next.cwd { return true }
        if previous.isOverlayStale != next.isOverlayStale
            || previous.autoScrollEnabled != next.autoScrollEnabled
            || previous.syntaxHighlightingEnabled != next.syntaxHighlightingEnabled
            || previous.isOwned != next.isOwned { return true }
        // The composer is a capability, not one of the shared channel objects below: contract Y6
        // gates *Edit* on it, so a channel that acquires or loses one changes what every mounted
        // user message offers. Compared by identity, which is what a reference has — and nil
        // against non-nil, which is the adoption and the release themselves.
        if previous.composer !== next.composer { return true }
        if previous.neighbourhood.toolCalls != next.neighbourhood.toolCalls
            || previous.neighbourhood.precedingTimestamps != next.neighbourhood.precedingTimestamps
            || previous.neighbourhood.taskRuns != next.neighbourhood.taskRuns
            || previous.neighbourhood.agents != next.neighbourhood.agents { return true }
        // The registry's *eligibility* and never the mirror: a mounted `taskRun` row keys its card on
        // whether the mirror makes the run backgroundable, and a card built before the run's
        // `task_started` reached the fold can only learn otherwise if the context it re-keys against
        // reaches it. Comparing the whole mirror would put every heartbeat through this instead
        // (tracker 406).
        if previous.neighbourhood.eligibility != next.neighbourhood.eligibility { return true }
        return previous.collapse !== next.collapse
            || previous.editing !== next.editing
            || previous.retraction !== next.retraction
            || previous.decisions !== next.decisions
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

// MARK: - One mounted row

/// The view one row of the table is drawn by: an `NSHostingView` that **survives the row's reloads**
/// and reports the height of what it is actually drawing.
///
/// Two properties the table cannot have without it. A reload that builds a fresh hosting view throws
/// away everything SwiftUI keeps for the row — a card's in-flight guard, a question's draft — so the
/// host is kept and its root is updated instead. And a row whose content changes size with no
/// publish behind it (a disclosure opening, a card mounting asynchronously) has to say so, or it is
/// drawn into the height it had before.
///
/// **The width is pinned on the SwiftUI side**, exactly as the controller's own measurement pins it:
/// `fittingSize` is the compressed layout size, and an unpinned row reports the height of its
/// longest line rather than of the text as it wraps. `NSHostingView.intrinsicContentSize` is the
/// same trap by another name — it is the content's *ideal* size and ignores the width the row is
/// drawn at.
@MainActor
final class TimelineRowHostView: NSView {

    private let hosting: MeasuringHostingView
    private(set) var key: String

    /// The context the root this view currently holds was built against.
    private(set) var renderedContext: TimelineRenderContext?

    /// Told when the content's height changed, with the row's key and the new height.
    var onHeightChange: ((String, CGFloat) -> Void)?

    /// The row's own content, before the width is pinned onto it.
    private var content: AnyView

    /// The width the root currently pins, and the height last reported for it.
    private var pinnedWidth: CGFloat
    private var reported: CGFloat?

    init(key: String, root: AnyView, context: TimelineRenderContext?) {
        self.key = key
        self.renderedContext = context
        self.content = root
        self.pinnedWidth = TimelineTableController.measuringWidth
        hosting = MeasuringHostingView(rootView: Self.pinned(root, to: pinnedWidth))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        addSubview(hosting)
        // Content that grows after it is mounted arrives here, one run loop later: SwiftUI raises
        // the invalidation while it is laying out, and the new size is readable after it.
        hosting.onInvalidate = { [weak self] in
            Task { @MainActor in self?.remeasure() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The row this view draws, again: the same hosting view, a new root, and whatever SwiftUI keeps
    /// for the row kept.
    func update(root: AnyView, context: TimelineRenderContext?) {
        renderedContext = context
        content = root
        hosting.rootView = Self.pinned(content, to: pinnedWidth)
        remeasure()
    }

    /// The width every measurement was made at is gone, so the next one is reported whatever it says.
    func widthChanged() { reported = nil }

    override func layout() {
        super.layout()
        let width = max(bounds.width, TimelineTableController.measuringWidth)
        if abs(width - pinnedWidth) > 1 {
            pinnedWidth = width
            reported = nil
            hosting.rootView = Self.pinned(content, to: width)
        }
        remeasure()
    }

    /// Reports the content's height when it has moved. The comparison is this view's own last report
    /// and not the table's cache, so a row mounted and never resized reports once.
    func remeasure() {
        let height = ceil(hosting.fittingSize.height)
        guard height > 0 else { return }
        if let reported, abs(reported - height) <= 1 { return }
        reported = height
        onHeightChange?(key, height)
    }

    private static func pinned(_ content: AnyView, to width: CGFloat) -> AnyView {
        AnyView(content.frame(width: width, alignment: .leading))
    }
}

/// The hosting view that says when its content's size changed.
///
/// SwiftUI invalidates the intrinsic content size whenever the hosted body's ideal size moves, which
/// is the one signal a row's content gives that no publish carries.
private final class MeasuringHostingView: NSHostingView<AnyView> {

    var onInvalidate: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onInvalidate?()
    }
}
