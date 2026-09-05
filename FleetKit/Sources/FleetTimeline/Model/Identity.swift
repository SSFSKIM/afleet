import Foundation
import AfleetCore

/// A transcript stream's identity: config home, session, stream name. Paths are aliases of it (parent §7.3).
public struct LogicalStream: Hashable, Sendable, Codable {
    public let configHome: URL
    public let sessionID: SessionID
    public let name: StreamName
    public init(configHome: URL, sessionID: SessionID, name: StreamName) {
        self.configHome = configHome.standardizedFileURL; self.sessionID = sessionID; self.name = name
    }
}

public enum StreamName: Hashable, Sendable, Codable {
    case main
    case agent(taskID: String)
    /// The engine's file name for the stream: `main` or `agent-<taskId>` (parent §7.3's wording).
    public var label: String { switch self { case .main: "main"; case .agent(let id): "agent-\(id)" } }
}

/// What a path under `<configHome>/projects/` names. `resolve` is the only place a path becomes a stream.
public enum TranscriptPath: Sendable, Hashable {
    case mainTranscript(slug: String)
    case agentTranscript(slug: String, taskID: String)
    case agentMetadata(slug: String, taskID: String)

    /// `<configHome>/projects/<slug>/<sessionId>.jsonl`, `…/<sessionId>/subagents/agent-<taskId>.jsonl` or `….meta.json`.
    /// The session id is read from the file name or the sidecar directory, never from the slug. Anything else is nil.
    public static func resolve(_ path: URL, under configHome: URL) -> (LogicalStream, TranscriptPath)? {
        let root = configHome.standardizedFileURL.appendingPathComponent("projects", isDirectory: true).path
        let p = path.standardizedFileURL.path
        guard p.hasPrefix(root + "/") else { return nil }
        let parts = p.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 2:
            let slug = parts[0], file = parts[1]
            guard file.hasSuffix(".jsonl"), let id = SessionID(String(file.dropLast(6))) else { return nil }
            return (LogicalStream(configHome: configHome, sessionID: id, name: .main), .mainTranscript(slug: slug))
        case 4:
            let slug = parts[0], file = parts[3]
            guard let id = SessionID(parts[1]), parts[2] == "subagents", file.hasPrefix("agent-") else { return nil }
            if file.hasSuffix(".jsonl") {
                let task = String(file.dropFirst(6).dropLast(6))
                return (LogicalStream(configHome: configHome, sessionID: id, name: .agent(taskID: task)), .agentTranscript(slug: slug, taskID: task))
            }
            if file.hasSuffix(".meta.json") {
                let task = String(file.dropFirst(6).dropLast(10))
                return (LogicalStream(configHome: configHome, sessionID: id, name: .agent(taskID: task)), .agentMetadata(slug: slug, taskID: task))
            }
            return nil
        default: return nil
        }
    }

    /// The path a stream lives at under a slug. Used at spawn to construct an agent's transcript path (parent §8.8) and by tests.
    public static func path(of stream: LogicalStream, slug: String) -> URL {
        let projects = stream.configHome.appendingPathComponent("projects").appendingPathComponent(slug)
        switch stream.name {
        case .main: return projects.appendingPathComponent("\(stream.sessionID).jsonl")
        case .agent(let task): return projects.appendingPathComponent("\(stream.sessionID)").appendingPathComponent("subagents").appendingPathComponent("agent-\(task).jsonl")
        }
    }
}

/// One record's identity: its stream plus its `uuid`, or, for a kind that has none, the canonical-JSON hash *and* an occurrence
/// ordinal (parent §7.3; spec "Occurrence identity"). The engine writes byte-identical state records repeatedly and never
/// deduplicates them — 2.1.258 line 429460 `vbr` gives no state kind a dedup policy — so two equal `atis-latch` lines are two
/// records with two keys. The ordinal is the count of records with that hash already applied in the stream when this one is
/// applied; a record cannot know it, the applier assigns it, and a published key never renumbers except across the rewrite
/// rebuild in Task 10.
public struct RecordKey: Hashable, Sendable, Codable {
    public let stream: LogicalStream
    public let identity: Identity
    public enum Identity: Hashable, Sendable, Codable { case uuid(String), hash(String, ordinal: Int) }
    public init(stream: LogicalStream, identity: Identity) { self.stream = stream; self.identity = identity }
    /// Keys for a sequence applied in this order: each uuid-less record's ordinal is the number of earlier records in the
    /// sequence with the same `contentHash`. Whole-file reads, the tests and check one use this; `StreamIngestion` numbers
    /// incrementally as deliveries arrive.
    public static func keys(for records: [TranscriptRecord], in stream: LogicalStream) -> [RecordKey] {
        var seen: [String: Int] = [:]
        return records.map { record in
            guard let hash = record.contentHash else { return record.key(in: stream, ordinal: 0) }
            defer { seen[hash, default: 0] += 1 }
            return record.key(in: stream, ordinal: seen[hash, default: 0])
        }
    }
}
