import Foundation
import ClaudeWire

/// Names one record kind the way the comparison needs to speak of it: a bare `type`, a `system` subtype, or a
/// `user` record distinguished by a flag. Matching is on the decoded record, never on a re-encoding.
public enum RecordKindMatcher: Hashable, Sendable {
    case kind(String)
    case system(String)
    /// A `user` record by its record-level `origin.kind` — `origin` is a key of the record, not a key under
    /// `message` — the engine's own injected messages, which reach the host through the transcript and the
    /// mirror but never as a `user` frame.
    case userOrigin(String)
    case userWhere(UserFlag)
    /// `sidechainRoot`: an agent stream's opening prompt — `isSidechain` with no `parentUuid`. Every main-stream
    /// root carries `isSidechain: false`, which is what makes the flag safe to express this way.
    public enum UserFlag: String, Sendable { case isMeta, sidechainRoot }

    public func matches(_ record: TranscriptRecord) -> Bool {
        switch self {
        case .kind(let name): return record.kind == name
        case .system(let subtype):
            guard case .system(let r) = record else { return false }
            return r.subtype == subtype
        case .userOrigin(let kind):
            guard case .user(let r) = record else { return false }
            return r.fields.origin?.fields.kind == kind
        case .userWhere(let flag):
            guard case .user(let r) = record else { return false }
            switch flag {
            case .isMeta: return r.isMeta == true
            case .sidechainRoot: return r.fields.isSidechain == true && r.fields.parentUuid == nil
            }
        }
    }
}

/// The fields the wire-to-file comparison reads off an item. Named, not derived, so adding a field to an item
/// does not silently widen or narrow what check one compares.
public struct ItemFieldSet: Hashable, Sendable, ExpressibleByArrayLiteral {
    public enum Field: Hashable, Sendable {
        case role, model, origin, toolDenialKind
        case contentBlocks(text: Bool, thinking: Bool, toolUseID: Bool, toolUseName: Bool, toolUseInput: Bool,
                           toolResultContent: Bool, toolResultIsError: Bool, image: Bool, document: Bool)
    }
    public let fields: Set<Field>
    public init(_ fields: Set<Field>) { self.fields = fields }
    public init(arrayLiteral elements: Field...) { self.fields = Set(elements) }
}

/// Contract X4's named constants: which categories persist, which are live overlay, what check one compares,
/// and which record kinds exist only in the file.
public enum ProjectionCategories {
    public static let durable: Set<TimelineCategory> = [.userMessage, .assistantMessage, .toolCall, .peerMessage, .sentFile, .compactBoundary, .taskRun]
    public static let overlay: Set<TimelineCategory> = [.cluster, .decision, .hookRun, .notification, .turnSummary]
    /// `.compactBoundary` is included, and that is the parent's 2026-09-05 amendment of §7.3's exclusion list
    /// carried through: the `compact-boundary` recording showed the engine emitting the boundary on the wire as a
    /// `system` frame of that subtype *and* mirroring the record, so it is compared like any other record rather
    /// than file-to-file only. Leaving it out left `ItemBuilder.addCompactBoundary`'s history truncation as
    /// common-mode code with no differential oracle. The comparison is vacuous on this branch's corpus, which
    /// carries no compaction, and becomes live when the branch merges onto a `main` that has the fixture.
    public static let comparedWireToFile: Set<TimelineCategory> = [.userMessage, .assistantMessage, .toolCall, .peerMessage, .sentFile, .taskRun, .compactBoundary]
    /// `.userOrigin("task-notification")` and `.userWhere(.sidechainRoot)` were added on 2026-09-05 after check two
    /// found them (parent revisions 7 and 8). Both name a record the engine writes to the transcript and mirrors,
    /// and that no `user` frame ever carries: an engine-injected task notification, and the prompt the `Task` tool
    /// hands a subagent. Every uuid of both was grepped across the recordings and appears on the wire only inside
    /// `transcript_mirror`. The wire reducer does not reduce mirror frames — that is `StreamIngestion`'s — so the
    /// two are file-only by exactly the definition this constant names.
    public static let fileOnlyRecordKinds: Set<RecordKindMatcher> = [
        .kind("attachment"), .system("turn_duration"), .system("stop_hook_summary"), .system("local_command"),
        .system("informational"), .userWhere(.isMeta),
        .userOrigin("task-notification"), .userWhere(.sidechainRoot)]
    public static let comparedItemFields: ItemFieldSet = [.role, .model, .origin, .toolDenialKind,
        .contentBlocks(text: true, thinking: true, toolUseID: true, toolUseName: true, toolUseInput: true,
                       toolResultContent: true, toolResultIsError: true, image: true, document: true)]
    /// Excluded on purpose and named so: `stop_reason` and `usage` differ between the mirror and the file of an agent stream
    /// (fixture declarations) and between streamed and final assistant frames; signatures are opaque; timestamps are compared
    /// separately within tolerance.
    public static let excludedItemFields: [String] = ["stop_reason", "usage", "signature", "timestamp"]
}
