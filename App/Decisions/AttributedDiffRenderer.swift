import SwiftUI

/// The line-level difference, remembered by the two sides it was computed from (scalpel-5#1).
///
/// `CollectionDifference` is a longest-common-subsequence, which is quadratic in the two sides' line
/// counts; `view` is called from a `body`, and a `body` is re-evaluated on every invalidation of
/// anything the card observes. Keying by the *content* rather than by the card is what makes an
/// entry safe to keep: equal sides are the same sides, so a hit cannot be a stale answer about a
/// file that has since changed.
///
/// **The key is the content itself and not a digest of it.** A digest would need either a
/// cryptographic hash — which would widen the app target's import list, and that list is amended
/// only by the commit authorised to amend it (X1) — or a 64-bit hash, whose collision draws one
/// change's diff under another change's card. `Dictionary` already hashes and then compares for
/// equality, which is exact, and the strings cost no more than the `[DiffLine]` beside them: those
/// lines *are* the file's lines.
///
/// Bounded by the count of entries, because what it holds is the sides of cards on screen — a
/// handful of decisions at a time — and the oldest goes first.
@MainActor
enum DiffLineCache {

    static let limit = 8

    struct Sides: Hashable {
        var before: String
        var after: String
    }

    private static var entries: [Sides: [DiffLine]] = [:]
    private static var order: [Sides] = []

    /// How many differences have actually been computed. This is the trace a test asserts on: a
    /// cache that silently stopped hitting is invisible in the lines it returns and visible here.
    private(set) static var computations = 0

    static func lines(before: String, after: String) -> [DiffLine] {
        let key = Sides(before: before, after: after)
        if let hit = entries[key] { return hit }
        computations += 1
        let lines = AttributedDiffRenderer.lines(before: before, after: after)
        entries[key] = lines
        order.append(key)
        if order.count > limit { entries.removeValue(forKey: order.removeFirst()) }
        return lines
    }

    /// Empties the cache and the counter, so one test's differences are not another test's hits.
    static func reset() {
        entries = [:]
        order = []
        computations = 0
    }
}

/// The shipped `DiffRendering`: a line-level `CollectionDifference`, drawn as attributed text.
///
/// Line-level and not character-level because that is the unit the engine's own inputs are
/// written in — a `Write` is a whole file and an `Edit` is a run of lines — and because
/// `CollectionDifference` over `[String]` is the standard library's own longest-common-
/// subsequence, so nothing here re-implements a diff.
struct AttributedDiffRenderer: DiffRendering {

    /// The change, line by line, in file order.
    ///
    /// `CollectionDifference` reports removals against offsets in `before` and insertions
    /// against offsets in `after`, so the two are walked together rather than concatenated: a
    /// removal is emitted when the before-side cursor reaches its offset, an insertion when the
    /// after-side cursor reaches its own, and everything else is a line both sides still have.
    static func lines(before: String, after: String) -> [DiffLine] {
        let old = split(before)
        let new = split(after)
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }

        var lines: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if let removed = removals[oldIndex] {
                lines.append(DiffLine(kind: .removed, text: removed,
                                      beforeNumber: oldIndex + 1, afterNumber: nil))
                oldIndex += 1
            } else if let inserted = insertions[newIndex] {
                lines.append(DiffLine(kind: .added, text: inserted,
                                      beforeNumber: nil, afterNumber: newIndex + 1))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                lines.append(DiffLine(kind: .context, text: old[oldIndex],
                                      beforeNumber: oldIndex + 1, afterNumber: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            } else {
                // Unreachable for a difference the standard library produced: every line one
                // side has and the other does not is in one of the two maps. Breaking rather
                // than trusting that keeps a malformed difference from spinning here.
                break
            }
        }
        return lines
    }

    /// A text's lines. An empty text is no lines at all, not one empty line — otherwise a write
    /// to a new file would open with a phantom removal of nothing.
    static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    func view(before: String, after: String, path: String) -> AnyView {
        let lines = DiffLineCache.lines(before: before, after: after)
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(Self.attributed(line))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
        )
    }

    /// One line, with its marker and its colour.
    static func attributed(_ line: DiffLine) -> AttributedString {
        var text = AttributedString("\(marker(line.kind))\(line.text)")
        switch line.kind {
        case .added:
            text.foregroundColor = .green
        case .removed:
            text.foregroundColor = .red
        case .context:
            text.foregroundColor = .secondary
        }
        return text
    }

    static func marker(_ kind: DiffLineKind) -> String {
        switch kind {
        case .added: "+ "
        case .removed: "- "
        case .context: "  "
        }
    }
}
