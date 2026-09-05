import Foundation
import ClaudeWire

/// The session-state records folded into one value (parity §35.4; the vocabulary is `SessionStateVocabulary`).
public struct SessionState: Hashable, Sendable, Codable {
    public var customTitle: String?
    public var aiTitle: String?
    public var agentName: String?
    public var summary: String?
    public var leaf: String?
    public var clearedToEmpty: Bool
    public var relocatedCwd: String?
    public var mode: String?
    public var costState: JSONValue?
    public var continuedIn: String?
    public var tag: String?
    public var atisLatch: String?
    public init() {
        self.customTitle = nil; self.aiTitle = nil; self.agentName = nil; self.summary = nil
        self.leaf = nil; self.clearedToEmpty = false; self.relocatedCwd = nil; self.mode = nil
        self.costState = nil; self.continuedIn = nil; self.tag = nil; self.atisLatch = nil
    }
}

/// Where one record's bytes lie: the stream and the reader's `ByteRange` (Task 2), which `TranscriptReader.read(at:length:)` takes.
public struct RecordLocator: Hashable, Sendable, Codable {
    public var stream: LogicalStream
    public var range: ByteRange
    public init(stream: LogicalStream, range: ByteRange) { self.stream = stream; self.range = range }
}

/// A record the projection does not render and the raw view may show. The payload stays on disk: `StreamIngestion.rawRecord(for:)`
/// reads it through the locator on demand, so C6 never touches JSONL and memory stays bounded. `locator` is nil for a record
/// the mirror delivered before the file held it; the ingestion serves that one from the record it retained until the file catches up.
public struct HiddenRecord: Hashable, Sendable, Codable {
    public var key: RecordKey
    public var kind: String
    public var timestamp: Date?
    public var reason: Reason
    public var locator: RecordLocator?
    public enum Reason: String, Sendable, Codable { case attachment, isMeta, isSynthetic, progress, sessionState, unknownKind }
    public init(key: RecordKey, kind: String, timestamp: Date? = nil, reason: Reason, locator: RecordLocator? = nil) {
        self.key = key; self.kind = kind; self.timestamp = timestamp; self.reason = reason; self.locator = locator
    }
}

/// A superseded chain of record uuids the projection kept out of the rendered line (parent §7.3).
public struct Branch: Hashable, Sendable, Codable {
    public var head: String
    public var tail: String
    public var count: Int
    public init(head: String, tail: String, count: Int) { self.head = head; self.tail = tail; self.count = count }
}

/// Something the read could not do cleanly. Carries `StreamName`, never `LogicalStream`: a warning may be logged
/// and `LogicalStream` holds the config-home path (C3 constraints).
public struct ReadWarning: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case undecodable, orphanHealed, orphanUnhealed, unknownKind }
    public var kind: Kind
    public var stream: StreamName
    public var byteOffset: Int?
    public var recordKind: String?
    public init(kind: Kind, stream: StreamName, byteOffset: Int? = nil, recordKind: String? = nil) {
        self.kind = kind; self.stream = stream; self.byteOffset = byteOffset; self.recordKind = recordKind
    }
}

/// One stream's projection, before the durable merge across a logical session's streams.
public struct StreamProjection: Hashable, Sendable {
    public var stream: LogicalStream
    public var items: [TimelineItem]
    public var hidden: [HiddenRecord]
    public var branches: [Branch]
    public var session: SessionState
    public var warnings: [ReadWarning]
    public var window: WindowMarker?
    public var metadata: AgentMetadataRecord?
    public init(stream: LogicalStream, items: [TimelineItem] = [], hidden: [HiddenRecord] = [], branches: [Branch] = [],
                session: SessionState = SessionState(), warnings: [ReadWarning] = [], window: WindowMarker? = nil,
                metadata: AgentMetadataRecord? = nil) {
        self.stream = stream; self.items = items; self.hidden = hidden; self.branches = branches
        self.session = session; self.warnings = warnings; self.window = window; self.metadata = metadata
    }
}

/// A logical session's durable projection: every stream's items merged into one line C6 renders.
public struct DurableProjection: Hashable, Sendable {
    public var items: [TimelineItem]
    public var hidden: [HiddenRecord]
    public var branches: [Branch]
    public var session: SessionState
    public var warnings: [ReadWarning]
    public var window: WindowMarker?
    public var streams: [LogicalStream]
    public init(items: [TimelineItem] = [], hidden: [HiddenRecord] = [], branches: [Branch] = [],
                session: SessionState = SessionState(), warnings: [ReadWarning] = [], window: WindowMarker? = nil,
                streams: [LogicalStream] = []) {
        self.items = items; self.hidden = hidden; self.branches = branches; self.session = session
        self.warnings = warnings; self.window = window; self.streams = streams
    }
    public static let empty = DurableProjection()
    public func items(in categories: Set<TimelineCategory>) -> [TimelineItem] { items.filter { categories.contains($0.category) } }
    public func hidden(_ key: RecordKey) -> HiddenRecord? { hidden.first { $0.key == key } }
}

/// What changed between two projections, at the granularity C4's store publishes and C6 animates.
public enum TimelineChange: Hashable, Sendable {
    case inserted(ItemID), updated(ItemID), removed(ItemID), previewChanged, overlayChanged, sessionStateChanged
}
