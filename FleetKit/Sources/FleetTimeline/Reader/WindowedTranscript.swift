import Foundation
import ClaudeWire

/// The channel-open read for one file: `readWindow`, then `readEarlier` until the window is *closed*, which means both
/// (a) the leaf the file names (`last-prompt.leafUuid`, else the last conversation record) lies inside the window, and
/// (b) the earliest record of the leaf's chain inside the window is a turn start — a `user` record that is neither a tool
/// result nor `isMeta` — or the file's first record. A chain record whose parent lies before a still-open window is a window
/// root, not an orphan; the reducer receives the marker and emits no orphan warning for it. Closure is bounded twice:
/// every extension is one `earlierStep` and it stops at offset 0, and the window may not grow past
/// `policy.closureBudget` bytes in the search — a leaf the window cannot reach must not turn opening a channel into a
/// whole-file read. A read that stops on the budget says so in `closureBudgetExhausted` and leaves a marker that
/// still points earlier, so the rest is reachable through `loadEarlier()`.
public enum WindowedTranscript {
    public struct Result: Sendable {
        public var records: [TranscriptRecord]
        public var ranges: [ByteRange]
        public var length: Int
        public var window: WindowMarker
        public var extensions: Int
        /// The closure loop stopped on `policy.closureBudget` rather than on the rule or on offset 0. The window is
        /// usable — it is a suffix of the file, with a marker that points earlier — but the leaf's chain does not
        /// start on a turn start inside it, so the first rows may open mid-turn.
        public var closureBudgetExhausted: Bool
        public init(records: [TranscriptRecord], ranges: [ByteRange], length: Int, window: WindowMarker,
                    extensions: Int, closureBudgetExhausted: Bool = false) {
            self.records = records; self.ranges = ranges; self.length = length; self.window = window; self.extensions = extensions
            self.closureBudgetExhausted = closureBudgetExhausted
        }
    }

    public static func read(_ reader: TranscriptReader, policy: WindowPolicy = .init()) throws -> Result {
        let first = try reader.readWindow(policy: policy)
        var records = first.records
        var ranges = first.ranges
        var window = first.window ?? closed
        var extensions = 0
        var exhausted = false
        while window.earlierAvailable, openReason(records) != nil {
            if held(ranges) >= policy.closureBudget { exhausted = true; break }
            let step = try reader.readEarlier(before: window.continueBefore, policy: policy)
            records = step.records + records
            ranges = step.ranges + ranges
            window = step.window ?? closed
            extensions += 1
        }
        return Result(records: records, ranges: ranges, length: first.length, window: window, extensions: extensions,
                      closureBudgetExhausted: exhausted)
    }

    /// *Load earlier* (`StreamIngestion.loadEarlier`, Task 10): one `earlierStep` back from `window.continueBefore`, then the same
    /// closure loop over `held` ∪ new. The result holds only the new records and ranges, in file order, to be prepended, and the
    /// moved marker; `length` is the caller's, unchanged — the value here is 0 and is not the caller's append offset.
    /// At `continueBefore == 0` it returns nothing and a closed marker.
    public static func readEarlier(_ reader: TranscriptReader, held: [TranscriptRecord], window: WindowMarker,
                                   policy: WindowPolicy = .init()) throws -> Result {
        guard window.earlierAvailable, window.continueBefore > 0 else {
            return Result(records: [], ranges: [], length: 0, window: closed, extensions: 0)
        }
        var records: [TranscriptRecord] = []
        var ranges: [ByteRange] = []
        var marker = window
        var extensions = 0
        var exhausted = false
        repeat {
            let step = try reader.readEarlier(before: marker.continueBefore, policy: policy)
            records = step.records + records
            ranges = step.ranges + ranges
            marker = step.window ?? closed
            extensions += 1
            // The same budget, over what this call prepends: one `loadEarlier` is one operator gesture and must not
            // become the whole-file read the initial window refused.
            if self.held(ranges) >= policy.closureBudget { exhausted = true; break }
        } while marker.earlierAvailable && openReason(records + held) != nil
        return Result(records: records, ranges: ranges, length: 0, window: marker, extensions: extensions,
                      closureBudgetExhausted: exhausted)
    }

    private static let closed = WindowMarker(earlierAvailable: false, continueBefore: 0)

    /// The bytes a window spans: the last record's end less the first record's start. The span, not the sum of the
    /// lengths, because that is what the read has to hold.
    private static func held(_ ranges: [ByteRange]) -> Int {
        guard let first = ranges.first, let last = ranges.last else { return 0 }
        return (last.offset + last.length) - first.offset
    }

    // MARK: - The rule

    /// The rule alone, over decoded records, testable without a file: nil when closed, else why not.
    static func openReason(_ records: [TranscriptRecord]) -> OpenReason? {
        // A window with no conversation record at all names no leaf, so half (a) of the rule cannot hold: it is open,
        // and the caller extends it or stops at offset 0. `<none>` is the diagnostic, never a record's content.
        guard let leaf = namedLeaf(records) else { return .leafNotInWindow("<none>") }
        var byUUID: [String: TranscriptRecord] = [:]
        byUUID.reserveCapacity(records.count)
        for record in records { if let uuid = record.uuid { byUUID[uuid] = record } }
        guard var current = byUUID[leaf] else { return .leafNotInWindow(leaf) }
        for _ in 0...records.count {
            guard let parent = parentUUID(of: current) else { return nil }          // the chain's own root
            guard let next = byUUID[parent] else {                                  // the walk left the window here
                return isTurnStart(current) ? nil : .chainStartsMidTurn(current.uuid ?? leaf)
            }
            current = next
        }
        return .chainStartsMidTurn(current.uuid ?? leaf)            // a parent cycle: bounded, and the caller's loop stops at 0
    }

    enum OpenReason: Equatable { case leafNotInWindow(String), chainStartsMidTurn(String) }

    /// The leaf the window's own records name: the last `last-prompt` that carries one, else the last conversation record.
    /// A `last-prompt` whose `leafUuid` is an explicit clear names nothing, so the fallback applies (parity §35.4).
    static func namedLeaf(_ records: [TranscriptRecord]) -> String? {
        for record in records.reversed() {
            guard case .sessionState(let state, _) = record, state.fields.type == "last-prompt" else { continue }
            if let leaf = state.leafUuid, let uuid = leaf { return uuid }
            break
        }
        for record in records.reversed() where record.isConversation { return record.uuid }
        return nil
    }

    static func parentUUID(of record: TranscriptRecord) -> String? {
        switch record {
        case .user(let r): r.fields.parentUuid
        case .assistant(let r): r.fields.parentUuid
        case .attachment(let r): r.fields.parentUuid
        case .system(let r): r.fields.parentUuid
        case .progress(let r): r.fields.parentUuid
        default: nil
        }
    }

    /// The `logicalParentUuid` a record declares. Only a `compact_boundary` carries one on this corpus: the engine's
    /// writer sets `parentUuid: null, logicalParentUuid: <previous leaf>` on a boundary and the ordinary pair on
    /// every other record (2.1.258 `cli.pretty.js` line 430982), so it is the boundary's only link to the half of
    /// the conversation before it.
    static func logicalParentUUID(of record: TranscriptRecord) -> String? {
        switch record {
        case .user(let r): r.fields.logicalParentUuid
        case .assistant(let r): r.fields.logicalParentUuid
        case .system(let r): r.fields.logicalParentUuid
        default: nil
        }
    }

    /// A turn start: a `user` record that is neither a tool result nor `isMeta` — the same three conditions the engine's
    /// own first-prompt scan applies (2.1.258 `Ett`, line 13464, and `F5`).
    static func isTurnStart(_ record: TranscriptRecord) -> Bool {
        guard case .user(let user) = record else { return false }
        if user.fields.isMeta == true { return false }
        if user.fields.isCompactSummary == true { return false }
        if case .blocks(let blocks) = user.fields.message.fields.content {
            for block in blocks { if case .toolResult = block { return false } }
        }
        return true
    }
}
