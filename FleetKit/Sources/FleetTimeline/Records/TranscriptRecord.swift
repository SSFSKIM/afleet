import Foundation
import CryptoKit
import ClaudeWire

public enum TranscriptRecord: Sendable, Hashable {
    case user(UserRecord), assistant(AssistantRecord), attachment(AttachmentRecord), system(SystemRecord), progress(ProgressRecord)
    /// The two uuid-less typed kinds carry the SHA-256 (hex) of the line's canonical JSON, computed by the decoder from the
    /// stage-one `JSONValue` (`canonicalData()`: sorted keys, normalised numbers), so a file line and a mirror entry with the same
    /// content in another key order are one key. `JSONEncoder` output is never hashed: its dictionary key order is per-process.
    case agentMetadata(AgentMetadataRecord, canonicalHash: String)
    case sessionState(SessionStateRecord, canonicalHash: String)
    case unknown(kind: String, JSONValue)
    case undecodable(raw: Data, byteOffset: Int, reason: String)

    public var kind: String {
        switch self {
        case .user: "user"; case .assistant: "assistant"; case .attachment: "attachment"; case .system: "system"; case .progress: "progress"
        case .agentMetadata: "agent_metadata"; case .sessionState(let s, _): s.type; case .unknown(let k, _): k; case .undecodable: "<undecodable>"
        }
    }
    public var uuid: String? {
        switch self {
        case .user(let r): r.uuid; case .assistant(let r): r.uuid; case .attachment(let r): r.uuid; case .system(let r): r.uuid; case .progress(let r): r.uuid
        default: nil
        }
    }
    public var isConversation: Bool { uuid != nil && SessionStateVocabulary.conversationKinds.contains(kind) }

    /// The content half of a uuid-less record's identity: the SHA-256 (hex) of the canonical JSON the decoder computed, or of the
    /// raw bytes of a line that never decoded. Never derived from a re-encoding (main's `JSONValue.canonicalData` names the hashing
    /// bytes). nil for a record with a uuid.
    public var contentHash: String? {
        if uuid != nil { return nil }
        switch self {
        case .agentMetadata(_, let h), .sessionState(_, let h): return h
        case .unknown(_, let v): return RecordDecoder.canonicalHash(of: v)
        case .undecodable(let raw, _, _): return RecordDecoder.hex(SHA256.hash(data: raw))
        default:   // a conversation kind without a uuid: canonical bytes of the lossless re-encoding, so even this key is stable
            let v = (try? JSONDecoder().decode(JSONValue.self, from: RecordDecoder.encode(self))) ?? .null
            return RecordDecoder.canonicalHash(of: v)
        }
    }
    /// uuid when the record has one (`ordinal` ignored); otherwise `contentHash` with the ordinal the applier assigned — the
    /// count of records with that hash already applied in the stream. No default on purpose: a caller that does not know the
    /// ordinal is not the applier and uses `RecordKey.keys(for:in:)` over the whole sequence instead.
    public func key(in stream: LogicalStream, ordinal: Int) -> RecordKey {
        if let uuid { return RecordKey(stream: stream, identity: .uuid(uuid)) }
        return RecordKey(stream: stream, identity: .hash(contentHash!, ordinal: ordinal))   // non-nil whenever uuid is nil, by construction above
    }
}

public enum RecordDecoder {
    /// Two stages, never throws: JSONValue first, typed model from the same bytes second. A mirror entry goes through the same
    /// function after `canonicalData()`, so the file and the mirror decode identically.
    public static func decode(line: Data, byteOffset: Int = 0) -> TranscriptRecord {
        // A top-level object whose `type` is one of the five conversation kinds needs no stage-one `JSONValue`: nothing
        // downstream asks for one, and no conversation kind takes a canonical hash from it. Materialising the whole tree
        // to read one string was over a third of a channel-open read. The probe decodes that one field and the fast path
        // is taken only when it yields such a kind — which is exactly the case in which the two-stage path below would
        // have reached the same `typed` call — so every other outcome, and every reason string, is decided as before.
        if let kind = try? JSONDecoder().decode(TypeProbe.self, from: line).type?.stringValue,
           conversationKinds.contains(kind) {
            return conversation(kind, line: line, byteOffset: byteOffset)
        }
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: line) }
        catch { return .undecodable(raw: line, byteOffset: byteOffset, reason: "invalid_json") }
        guard value.objectValue != nil else { return .undecodable(raw: line, byteOffset: byteOffset, reason: "not_an_object") }
        guard let kind = value["type"]?.stringValue else { return .unknown(kind: "<untyped>", value) }
        func typed<F: Codable & Sendable & DeclaredKeys>(_: F.Type, _ wrap: (Lossless<F>) -> TranscriptRecord) -> TranscriptRecord {
            Self.typed(F.self, line: line, byteOffset: byteOffset, kind: kind, wrap)
        }
        if conversationKinds.contains(kind) { return conversation(kind, line: line, byteOffset: byteOffset) }
        switch kind {
        case "agent_metadata": let h = canonicalHash(of: value); return typed(AgentMetadataFields.self) { .agentMetadata($0, canonicalHash: h) }
        default:
            if SessionStateVocabulary.kinds[kind] != nil { let h = canonicalHash(of: value); return typed(SessionStateFields.self) { .sessionState($0, canonicalHash: h) } }
            return .unknown(kind: kind, value)
        }
    }

    /// The five kinds that carry a uuid and no canonical hash.
    private static let conversationKinds: Set<String> = ["user", "assistant", "attachment", "system", "progress"]
    private struct TypeProbe: Decodable { var type: JSONValue? }

    private static func conversation(_ kind: String, line: Data, byteOffset: Int) -> TranscriptRecord {
        switch kind {
        case "user": typed(UserRecordFields.self, line: line, byteOffset: byteOffset, kind: kind, TranscriptRecord.user)
        case "assistant": typed(AssistantRecordFields.self, line: line, byteOffset: byteOffset, kind: kind, TranscriptRecord.assistant)
        case "attachment": typed(AttachmentRecordFields.self, line: line, byteOffset: byteOffset, kind: kind, TranscriptRecord.attachment)
        case "system": typed(SystemRecordFields.self, line: line, byteOffset: byteOffset, kind: kind, TranscriptRecord.system)
        default: typed(ProgressRecordFields.self, line: line, byteOffset: byteOffset, kind: kind, TranscriptRecord.progress)
        }
    }

    private static func typed<F: Codable & Sendable & DeclaredKeys>(
        _: F.Type, line: Data, byteOffset: Int, kind: String, _ wrap: (Lossless<F>) -> TranscriptRecord
    ) -> TranscriptRecord {
        do { return wrap(try JSONDecoder().decode(Lossless<F>.self, from: line)) }
        catch { return .undecodable(raw: line, byteOffset: byteOffset, reason: "decode_failure:\(kind)") }
    }
    /// The one hashing representation: SHA-256 (hex) of `value.canonicalData()` — sorted keys, normalised numbers.
    public static func canonicalHash(of value: JSONValue) -> String { hex(SHA256.hash(data: (try? value.canonicalData()) ?? Data())) }
    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    public static func decode(entry: JSONValue) -> TranscriptRecord {
        guard let data = try? entry.canonicalData() else { return .undecodable(raw: Data(), byteOffset: 0, reason: "invalid_json") }
        return decode(line: data)
    }
    /// One JSON line, no trailing newline. `.unknown` re-emits its value; `.undecodable` its raw bytes.
    public static func encode(_ record: TranscriptRecord) throws -> Data {
        let enc = JSONEncoder()
        switch record {
        case .user(let r): return try enc.encode(r); case .assistant(let r): return try enc.encode(r)
        case .attachment(let r): return try enc.encode(r); case .system(let r): return try enc.encode(r)
        case .progress(let r): return try enc.encode(r); case .agentMetadata(let r, _): return try enc.encode(r)
        case .sessionState(let r, _): return try enc.encode(r)
        case .unknown(_, let v): return try v.canonicalData()
        case .undecodable(let raw, _, _): return raw
        }
    }
}
