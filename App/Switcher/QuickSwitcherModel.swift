import Foundation
import Observation
import AfleetCore
import FleetKit

/// One line in the Cmd+K switcher.
///
/// The kind is carried rather than inferred from which optional is non-nil: a test asserts that all
/// three kinds appear, and "the one with a `session`" is a proxy for "a channel" that a job with a
/// session id would break.
struct SwitcherResult: Identifiable, Sendable {

    enum Kind: String, Hashable, Sendable, CaseIterable { case project, channel, job }

    let id: String
    let kind: Kind
    let title: String
    /// The second line: a working directory's last component, a job's state, a project's row count.
    let detail: String
    let systemImage: String
    /// Set for `.channel`, and for a `.job` that names one.
    let session: SessionID?
    /// Set for `.project`: the `ProjectSection.id` to scroll the sidebar to.
    let projectID: String?
    /// Set for `.job`.
    let job: JobShort?
    /// The tie-break, and the whole ordering when the query is empty.
    let lastActivity: Date
    /// `FuzzyMatch`'s score. Zero for a result the empty query returned, which is not ranked by
    /// match at all.
    let score: Int
}

/// Cmd+K: a fuzzy switcher over projects, channels and jobs (spec §4, §6).
///
/// **It searches the whole listed index, not the sidebar.** The thirty-day default is a rule about
/// what the sidebar shows without being asked; the switcher is the asking. `FleetBrowserModel`
/// keeps the rows the default hides in `archived`, so the corpus here is `allRows` — sections plus
/// archived — and a channel last touched two years ago is one query away even though no amount of
/// scrolling reaches it.
@MainActor
@Observable
final class QuickSwitcherModel {

    /// What an empty query returns: the most recently active channels, and nothing else. Not a
    /// scroll of the whole fleet — on this machine's own corpus that is three thousand rows, and a
    /// list of three thousand is not a switcher.
    static let emptyQueryLimit = 10

    var query: String = ""

    /// The result the arrow keys are on, by `SwitcherResult.id`. Held here rather than in the sheet
    /// because moving it is a walk over `results`, which is this model's list and not the view's.
    var highlighted: String?

    private let browser: FleetBrowserModel

    init(browser: FleetBrowserModel) {
        self.browser = browser
    }

    /// The current query's results, for the view to render.
    var results: [SwitcherResult] { results(for: query) }

    func results(for query: String) -> [SwitcherResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return recentChannels() }

        var found: [SwitcherResult] = []
        for section in browser.sections {
            guard let score = FuzzyMatch.best(of: [section.title, section.id], query: needle) else { continue }
            let rows = section.allRows
            found.append(SwitcherResult(id: "project:" + section.id,
                                        kind: .project,
                                        title: section.title,
                                        detail: rows.count == 1 ? "1 channel" : "\(rows.count) channels",
                                        systemImage: "folder",
                                        // A project is a place rather than a channel, so opening
                                        // one lands on its most recent channel — the row the
                                        // sidebar draws first under that heading.
                                        session: rows.max { Self.activity(of: $0) < Self.activity(of: $1) }?.id,
                                        projectID: section.id,
                                        job: nil,
                                        lastActivity: rows.map(Self.activity(of:)).max() ?? .distantPast,
                                        score: score))
        }
        for row in browser.allRows {
            let candidates = [row.title, row.cwd?.lastPathComponent, row.gitBranch, row.agentName]
            guard let score = FuzzyMatch.best(of: candidates.compactMap { $0 }, query: needle) else { continue }
            found.append(Self.result(for: row, score: score))
        }
        for job in browser.background {
            let candidates = [job.name, job.kind, job.short.rawValue, job.cwd?.lastPathComponent]
            guard let score = FuzzyMatch.best(of: candidates.compactMap { $0 }, query: needle) else { continue }
            found.append(Self.result(for: job, score: score))
        }
        return found.sorted(by: Self.ranked)
    }

    // MARK: - The highlight

    /// The result Return would open: the highlighted one, or the first when the highlight is stale
    /// because the query changed under it.
    var highlightedResult: SwitcherResult? {
        let list = results
        return list.first { $0.id == highlighted } ?? list.first
    }

    /// Down is `+1`, up is `-1`. Clamped rather than wrapping, so holding a key does not cycle.
    func moveHighlight(by delta: Int) {
        let list = results
        guard !list.isEmpty else {
            highlighted = nil
            return
        }
        let current = list.firstIndex { $0.id == highlighted } ?? 0
        highlighted = list[min(max(current + delta, 0), list.count - 1)].id
    }

    /// Re-opening the sheet starts from the top of the recent list rather than wherever the last
    /// query left the highlight.
    func reset() {
        query = ""
        highlighted = nil
    }

    // MARK: - Building results

    private func recentChannels() -> [SwitcherResult] {
        browser.allRows
            .sorted { Self.activity(of: $0) > Self.activity(of: $1) }
            .prefix(Self.emptyQueryLimit)
            .map { Self.result(for: $0, score: 0) }
    }

    private static func result(for row: ChannelRow, score: Int) -> SwitcherResult {
        SwitcherResult(id: "channel:" + row.id.description,
                       kind: .channel,
                       title: row.title,
                       detail: row.cwd?.lastPathComponent ?? "no working directory",
                       systemImage: row.originGlyph?.systemImage ?? OriginGlyph.archived.systemImage,
                       session: row.id,
                       projectID: nil,
                       job: nil,
                       lastActivity: activity(of: row),
                       score: score)
    }

    private static func result(for job: JobEntry, score: Int) -> SwitcherResult {
        SwitcherResult(id: "job:" + job.short.rawValue,
                       kind: .job,
                       title: job.name ?? job.kind,
                       detail: "\(job.kind) · \(job.state)",
                       systemImage: OriginGlyph.backgroundJob.systemImage,
                       session: job.sessionID,
                       projectID: nil,
                       job: job.short,
                       // A `JobEntry` carries no timestamp, so a job never wins a recency
                       // tie-break and never appears under an empty query.
                       lastActivity: .distantPast,
                       score: score)
    }

    /// A row's activity: the live half's when there is one, the transcript's mtime otherwise. A
    /// channel with a running process is more recent than its file, and the file is all a restored
    /// row has.
    ///
    /// **`.archived` is not a live half, so its timestamp is not activity.** C4 gives a supervisor a
    /// `lastActivity` of the clock at registration whether or not there is a process behind it, and
    /// the sidebar registers every listed transcript on the machine — so an archived channel's
    /// `lastActivity` says when afleet looked at it, not when anyone last used it. Rows are
    /// registered newest-first, which makes the *oldest* transcript carry the newest seeded
    /// timestamp, and ranking on it inverted Cmd+K's empty query exactly. The transcript's mtime is
    /// the honest answer for a channel with nothing running, and it is the only one such a row has.
    private static func activity(of row: ChannelRow) -> Date {
        guard let state = row.state, state.origin != .archived else { return row.mtime }
        return max(state.lastActivity, row.mtime)
    }

    /// Score first, recency second, then a stable name and id so two identical rows do not swap
    /// places between keystrokes.
    private static func ranked(_ left: SwitcherResult, _ right: SwitcherResult) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.lastActivity != right.lastActivity { return left.lastActivity > right.lastActivity }
        if left.title != right.title { return left.title < right.title }
        return left.id < right.id
    }
}

/// The switcher's match, scored so that a better *kind* of match always outranks a worse one
/// regardless of length or recency.
///
/// Four tiers, in descending order: the candidate starts with the query; the query starts a word
/// inside the candidate; the query appears anywhere inside it; the query's characters appear in
/// order with gaps. Each tier's band is wide enough that no within-tier adjustment can cross into
/// the tier below, which is what makes "a prefix match ranks above an infix match" a property of
/// the scoring rather than an accident of the two strings involved.
enum FuzzyMatch {

    /// The width of one tier's band. Larger than any adjustment applied inside a tier, which is
    /// capped at `adjustmentCeiling`.
    private static let tier = 1_000
    private static let adjustmentCeiling = 200

    /// The best score any of the candidates earns, or nil when none matches.
    static func best(of candidates: [String], query: String) -> Int? {
        candidates.compactMap { score($0, query: query) }.max()
    }

    static func score(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return nil }
        let text = candidate.lowercased()
        guard !text.isEmpty else { return nil }

        if text.hasPrefix(query) {
            return 4 * tier - min(text.count, adjustmentCeiling)
        }
        if let range = text.range(of: query) {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let onBoundary = startsAWord(text, at: range.lowerBound)
            return (onBoundary ? 3 : 2) * tier - min(offset, adjustmentCeiling)
        }
        guard let gaps = subsequenceGaps(text, query) else { return nil }
        return tier - min(gaps, adjustmentCeiling)
    }

    /// Whether the character before `index` ends a word, so the match begins one.
    private static func startsAWord(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !previous.isLetter && !previous.isNumber
    }

    /// The number of characters skipped while matching `query` as a subsequence of `text`, or nil
    /// when it is not one.
    private static func subsequenceGaps(_ text: String, _ query: String) -> Int? {
        var gaps = 0
        var remaining = Substring(query)
        for character in text {
            guard let next = remaining.first else { break }
            if character == next {
                remaining = remaining.dropFirst()
            } else {
                gaps += 1
            }
        }
        return remaining.isEmpty ? gaps : nil
    }
}
