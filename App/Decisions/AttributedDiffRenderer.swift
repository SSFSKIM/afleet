import SwiftUI

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
        let lines = Self.lines(before: before, after: after)
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
