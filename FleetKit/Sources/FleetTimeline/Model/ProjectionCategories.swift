import Foundation
import ClaudeWire

/// Names one record kind the way the comparison needs to speak of it: a bare `type`, a `system` subtype, or a
/// `user` record distinguished by a flag. Matching is on the decoded record, never on a re-encoding.
public enum RecordKindMatcher: Hashable, Sendable {
    case kind(String)
    case system(String)
    case userWhere(UserFlag)
    public enum UserFlag: String, Sendable { case isMeta }

    public func matches(_ record: TranscriptRecord) -> Bool {
        switch self {
        case .kind(let name): return record.kind == name
        case .system(let subtype):
            guard case .system(let r) = record else { return false }
            return r.subtype == subtype
        case .userWhere(let flag):
            guard case .user(let r) = record else { return false }
            switch flag { case .isMeta: return r.isMeta == true }
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
    public static let comparedWireToFile: Set<TimelineCategory> = [.userMessage, .assistantMessage, .toolCall, .peerMessage, .sentFile, .taskRun]
    /// `compact_boundary` is deliberately absent: the parent amended §7.3's exclusion list on
    /// 2026-09-05 after the `compact-boundary` recording showed the engine emitting the boundary
    /// on the wire as a `system` frame of that subtype and mirroring the record, so it is compared
    /// like any other record rather than file-to-file only.
    public static let fileOnlyRecordKinds: Set<RecordKindMatcher> = [
        .kind("attachment"), .system("turn_duration"), .system("stop_hook_summary"), .system("local_command"),
        .system("informational"), .userWhere(.isMeta)]
    public static let comparedItemFields: ItemFieldSet = [.role, .model, .origin, .toolDenialKind,
        .contentBlocks(text: true, thinking: true, toolUseID: true, toolUseName: true, toolUseInput: true,
                       toolResultContent: true, toolResultIsError: true, image: true, document: true)]
    /// Excluded on purpose and named so: `stop_reason` and `usage` differ between the mirror and the file of an agent stream
    /// (fixture declarations) and between streamed and final assistant frames; signatures are opaque; timestamps are compared
    /// separately within tolerance.
    public static let excludedItemFields: [String] = ["stop_reason", "usage", "signature", "timestamp"]
}
