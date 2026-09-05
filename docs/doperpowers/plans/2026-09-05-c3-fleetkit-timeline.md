# C3: FleetKit Timeline Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use doperpowers:subagent-driven-execution to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `FleetTimeline`, the pure data half of `FleetKit`: the transcript record model and reader, the record reducer and the wire reducer with their source arbitration, the timeline item model with its named category constants, the agent-run tree, the background-task registry mirror and output tailer, the transcript index with its head-and-tail read, the channel's recent-URL query, and the differential invariant as a test that runs against every fixture C1 recorded.

**Architecture:** One target `FleetTimeline` inside the `FleetKit` package, added only inside the manifest's C3 region, importing `AfleetCore` and `ClaudeWire` and reusing C2's `Lossless`, `JSONValue`, `ContentBlock`, `Message`, `Frame`, `WireEvent` and `ProcessEpoch`. Records and frames decode losslessly; identity is a record key (logical stream plus uuid or hash) and paths are aliases; the two reducers are pure value types producing one `DurableProjection` shape, so the invariant is a comparison of two values; three actors hold the long-lived state (`StreamIngestion` per channel, `TranscriptIndex` per config home, `TaskOutputTailer` per file). Nothing spawns a process; nothing writes under a config home; every test drives file inputs and frame streams directly.

**Tech Stack:** Swift 6.3.3, Swift Package Manager (`swift-tools-version: 6.2`, language mode 6, `platforms: [.macOS(.v26)]`), Foundation (`FileHandle`, `Data`, `JSONDecoder`/`JSONEncoder`, `FileManager`, `FSEvents` through `CoreServices` for the watcher only), CryptoKit (`SHA256` for uuid-less record identity), XCTest. No Python, no processes.

**Spec:** `docs/doperpowers/specs/2026-09-05-c3-fleetkit-timeline.md` v2 (child of `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C3`, parent-pin `ee94449`; the parent's §7.3 in full, §8.8's tree data model, §5's package edges and §17.5 X1, X3 (consumed), X4 (owned), X6 (the `IndexStorage` seam), X7 as amended 2026-09-05 (the recent-URL query), X8 and X9 bind this work).

## Global Constraints

- One package edit: `FleetKit/Package.swift` changes only between `// MARK: - C3 timeline group` and `// MARK: - end of C3 group` (parent X1, the skeleton on `main`). The two targets there stay `FleetTimeline` and `FleetTimelineTests`; no product is added; the umbrella already re-exports `FleetTimeline`.
- `FleetTimeline` imports `AfleetCore`, `ClaudeWire`, `Foundation`, `CryptoKit` and, in the one watcher file, `CoreServices`. Nothing else. A test greps the imports.
- Every manifest line: `// swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, every target `swiftSettings: [.swiftLanguageMode(.v6)]`. Strict concurrency is on from the first commit; no `@preconcurrency` imports.
- Every public type is `Sendable`; nothing is `@MainActor`. Actors: `StreamIngestion`, `TranscriptIndex`, `TaskOutputTailer`. `@unchecked Sendable` is permitted only where a type is a single-owner box whose stored state is reachable from exactly one place that serialises every access, and each use documents which mechanism serialises it (parent §17.7 as amended). In this target that is `TranscriptWatcher` (an FSEvents stream whose callback runs on one dispatch queue) and nothing else planned.
- Public initialisers on every value a downstream package constructs (Swift's synthesized memberwise initialisers are internal).
- `swift test --package-path FleetKit` must pass after every task. `FleetSessionsTests` and the umbrella keep building.
- Nothing in this target or its tests writes under any Claude Code config home (`~/.claude`, `$CLAUDE_CONFIG_DIR`, `/tmp/afleet-fixtures/config-home`); every transcript is opened read-only with `O_NOFOLLOW`; test trees live under `FileManager.default.temporaryDirectory` (parent X9). The one test that reads the author's real config home runs only with `AFLEET_LOCAL_INDEX=1`, reads, and prints counts, sizes and timings.
- Every fixture-driven assertion compares sets or exact sequences, never counts alone; where a count is asserted it is an equality against a pinned number that a second assertion grounds (the census, a fixture's own record count, a pinned name set).
- The discriminating-test rule of parent §17.7 applies to every gate test: this plan says, per test, what deliberate break demonstrates it red; the executor performs the break in memory or by a local uncommitted edit, quotes the failing assertion line in the ledger, restores, and only then commits the test.
- Assertions and diagnostics print identifiers, counts and shapes — fixture name, record kind, item id, field name, count — never a path under a home directory, a record's content, a title or an environment. `LogicalStream` is never logged (it carries the config home path).
- No engine byte enters a committed file except through `Fixtures/` as C1 redacted it. Tests construct nothing that pretends to be a recording; where a path is unwitnessed, the test mutates a recorded record in memory (a deletion, a type rename, a field edit) and its name says so.
- Commit after every task with a plain message; no attribution trailers.

---

## File Structure

```
FleetKit/
  Package.swift                                        (C3 region only: no change in v1 — both targets already declared)
  Sources/FleetTimeline/
    FleetTimeline.swift                                (module doc comment; replaces the placeholder)
    Model/Identity.swift                               LogicalStream, StreamName, TranscriptPath, RecordKey
    Model/TimelineItem.swift                           TimelineItem, ItemID, Provenance, TimelineCategory, the payload structs
    Model/ProjectionCategories.swift                   durable, overlay, comparedWireToFile, fileOnlyRecordKinds, comparedItemFields
    Model/ChannelTimeline.swift                        ChannelTimeline, SeenURL, URLSources, URLSourceKind, URLScanner
    Records/TranscriptRecord.swift                     TranscriptRecord, RecordDecoder
    Records/RecordFields.swift                         UserRecordFields … SystemRecordFields, AgentMetadataFields, SessionStateFields
    Records/SessionStateVocabulary.swift               the engine's record-kind table, transcribed
    Reader/LineScanner.swift                           newline scanning over Data, torn-tail rule
    Reader/TranscriptReader.swift                      readAll, readAppended(from:), readWindow(tailBytes:), readEarlier(before:), open rules
    Reader/HeadTailReader.swift                        the picker's 64 KiB read and its substring helpers
    Reduce/Projection.swift                            StreamProjection, DurableProjection, SessionState, Branch, ReadWarning, WindowMarker, TimelineChange
    Reduce/RecordReducer.swift                         tree, leaf, healing, merge rules
    Reduce/Overlay.swift                               Overlay, DecisionState, ClusterLabel, TurnAttribution, Banner
    Reduce/StreamingPreview.swift                      StreamingPreview from stream_event deltas
    Reduce/WireReducer.swift                           WireReducer, HostSignal
    Ingest/StreamIngestion.swift                       the actor, Mode, State, IngestionEffect
    Index/IndexEntry.swift                             IndexEntry, TitleSource, IndexSnapshot, IndexDelta
    Index/IndexStorage.swift                           IndexStorage protocol, InMemoryIndexStorage
    Index/TitlePrecedence.swift                        §35.19.7 precedence, the "Autonomous session" fallback
    Index/TranscriptIndex.swift                        the actor: build, update(changed:), entry
    Index/TranscriptWatcher.swift                      TranscriptWatching protocol, FSEvents implementation
    Agents/AgentRunTree.swift                          AgentRunNode, AgentRunTree, ParentSource
    Registry/RegistryMirror.swift                      RegistryEntry, TaskKind, TaskStatus, Placement, RegistryMirror
    Registry/TaskOutputTailer.swift                    TaskOutputTailer, OutputChunk, the trailer parser
    Diagnostics/TimelineNotice.swift                   TimelineNotice, TimelineDiagnosticsSink, NullTimelineDiagnostics, RecordingTimelineDiagnostics
  Tests/FleetTimelineTests/
    Support/FixtureCorpus.swift                        fixtures root from #filePath, per-fixture manifest, streams, transcript files, frames
    Support/TempTree.swift                             config-home-shaped temporary trees built from fixture snapshots
    Support/Breaks.swift                               in-memory mutation helpers used by the discrimination demonstrations
    Records/RecordModelTests.swift
    Reader/TranscriptReaderTests.swift
    Reader/HeadTailReaderTests.swift
    Invariant/MirrorFidelityTests.swift                check one
    Invariant/ProjectionEqualityTests.swift            check two and the overlay assertions
    Model/TimelineModelTests.swift
    Reduce/RecordReducerTests.swift
    Reduce/WireReducerTests.swift
    Registry/RegistryMirrorTests.swift
    Registry/TaskOutputTailerTests.swift
    Agents/AgentRunTreeTests.swift
    Ingest/IngestionTests.swift
    Model/ChannelTimelineQueryTests.swift
    Index/TranscriptIndexTests.swift
    Index/LocalHomeIndexTests.swift                    opt-in, AFLEET_LOCAL_INDEX=1
    ImportGraphTests.swift                             X1 grep test
```

The placeholder files `Sources/FleetTimeline/FleetTimeline.swift` and `Tests/FleetTimelineTests/Placeholder.swift` from the skeleton are replaced in Task 1; `Placeholder.swift` is deleted.

---

### Task 1: Streams, record keys, the record model and its vocabulary

**Files:**
- Modify: `FleetKit/Sources/FleetTimeline/FleetTimeline.swift` (replace the placeholder comment with the module doc)
- Create: `FleetKit/Sources/FleetTimeline/Model/Identity.swift`
- Create: `FleetKit/Sources/FleetTimeline/Records/RecordFields.swift`
- Create: `FleetKit/Sources/FleetTimeline/Records/SessionStateVocabulary.swift`
- Create: `FleetKit/Sources/FleetTimeline/Records/TranscriptRecord.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Support/FixtureCorpus.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Records/RecordModelTests.swift`
- Delete: `FleetKit/Tests/FleetTimelineTests/Placeholder.swift`

**Interfaces:**
- Consumes: from `ClaudeWire`: `Lossless`, `DeclaredKeys`, `JSONValue`, `AnyCodingKey`, `Message`, `UserMessage`, `MessageOrigin`, `ContentBlock`; from `AfleetCore`: `SessionID`.
- Produces: `LogicalStream`, `StreamName`, `TranscriptPath`, `RecordKey`, `TranscriptRecord`, `RecordDecoder.decode(line:)`, the `*RecordFields` structs, `SessionStateVocabulary.kinds`, and the test support `FixtureCorpus` (fixtures root, `Fixture` with `name`, `synthetic`, `sessionID`, `unmirroredPrefix`, `identityOnly`, `streamOffsets`, `transcriptFiles`). Every later task imports these.

- [ ] **Step 1: Identity**

`FleetKit/Sources/FleetTimeline/Model/Identity.swift`:

```swift
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

/// One record's identity: its stream plus its `uuid`, or a stable hash for a kind that has none (parent §7.3).
public struct RecordKey: Hashable, Sendable, Codable {
    public let stream: LogicalStream
    public let identity: Identity
    public enum Identity: Hashable, Sendable, Codable { case uuid(String), hash(String) }
    public init(stream: LogicalStream, identity: Identity) { self.stream = stream; self.identity = identity }
}
```

- [ ] **Step 2: Record fields**

`FleetKit/Sources/FleetTimeline/Records/RecordFields.swift`. Every struct is `Codable, Hashable, Sendable, DeclaredKeys` with an explicit `CodingKeys: String, CodingKey, CaseIterable`. Declared keys are the spec's lists; everything else lands in `Lossless.additional`.

```swift
import Foundation
import ClaudeWire

public struct UserRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var uuid: String; public var parentUuid: String?; public var logicalParentUuid: String?
    public var isSidechain: Bool?; public var isMeta: Bool?; public var isCompactSummary: Bool?; public var agentId: String?
    public var sessionId: String?; public var cwd: String?; public var timestamp: String?; public var version: String?
    public var gitBranch: String?; public var slug: String?; public var entrypoint: String?; public var userType: String?
    public var promptId: String?; public var promptSource: String?; public var permissionMode: String?
    public var toolUseResult: JSONValue?; public var sourceToolAssistantUUID: String?; public var toolDenialKind: String?
    public var origin: MessageOrigin?; public var queueSkipAttachments: Bool?; public var message: UserMessage
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, uuid, parentUuid, logicalParentUuid, isSidechain, isMeta, isCompactSummary, agentId, sessionId, cwd, timestamp,
             version, gitBranch, slug, entrypoint, userType, promptId, promptSource, permissionMode, toolUseResult,
             sourceToolAssistantUUID, toolDenialKind, origin, queueSkipAttachments, message
    }
}
public typealias UserRecord = Lossless<UserRecordFields>

public struct AssistantRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var uuid: String; public var parentUuid: String?; public var logicalParentUuid: String?
    public var isSidechain: Bool?; public var agentId: String?; public var sessionId: String?; public var cwd: String?
    public var timestamp: String?; public var version: String?; public var gitBranch: String?; public var slug: String?
    public var entrypoint: String?; public var userType: String?; public var requestId: String?; public var isApiErrorMessage: Bool?
    public var apiErrorStatus: JSONValue?; public var error: JSONValue?; public var effort: String?; public var quotaLimits: JSONValue?
    public var apiBlockIndex: Int?; public var attributionAgent: String?; public var attributionMcpServer: String?
    public var attributionMcpTool: String?; public var message: Message
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, uuid, parentUuid, logicalParentUuid, isSidechain, agentId, sessionId, cwd, timestamp, version, gitBranch, slug,
             entrypoint, userType, requestId, isApiErrorMessage, apiErrorStatus, error, effort, quotaLimits, apiBlockIndex,
             attributionAgent, attributionMcpServer, attributionMcpTool, message
    }
}
public typealias AssistantRecord = Lossless<AssistantRecordFields>

public struct AttachmentRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var uuid: String; public var parentUuid: String?; public var isSidechain: Bool?
    public var agentId: String?; public var sessionId: String?; public var cwd: String?; public var timestamp: String?
    public var version: String?; public var gitBranch: String?; public var slug: String?; public var entrypoint: String?
    public var userType: String?; public var rendered: JSONValue?; public var attachment: JSONValue
    public var attachmentType: String? { attachment["type"]?.stringValue }
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, uuid, parentUuid, isSidechain, agentId, sessionId, cwd, timestamp, version, gitBranch, slug, entrypoint, userType, rendered, attachment
    }
}
public typealias AttachmentRecord = Lossless<AttachmentRecordFields>

/// On-disk `system` records (`compact_boundary`, `informational`, `local_command`, `turn_duration`, `stop_hook_summary`, …).
/// None appears in the corpus; the fields are the bundle's writer fields and parity §35.1.
public struct SystemRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var subtype: String?; public var uuid: String; public var parentUuid: String?; public var logicalParentUuid: String?
    public var isSidechain: Bool?; public var agentId: String?; public var sessionId: String?; public var cwd: String?; public var timestamp: String?
    public var content: String?; public var level: String?; public var durationMs: Int?; public var toolUseID: String?
    public var preventContinuation: Bool?; public var compactMetadata: JSONValue?; public var isMeta: Bool?
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case type, subtype, uuid, parentUuid, logicalParentUuid, isSidechain, agentId, sessionId, cwd, timestamp, content, level,
             durationMs, toolUseID, preventContinuation, compactMetadata, isMeta
    }
}
public typealias SystemRecord = Lossless<SystemRecordFields>

/// `progress` is a conversation record the engine never stores as a message (parity §35.1). Modelled so it is recognised, never rendered.
public struct ProgressRecordFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var uuid: String; public var parentUuid: String?; public var timestamp: String?; public var data: JSONValue?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, uuid, parentUuid, timestamp, data }
}
public typealias ProgressRecord = Lossless<ProgressRecordFields>

/// The `.meta.json` body plus `type: "agent_metadata"`, as the mirror carries it (fixtures `explore-depth-1`, `nested-depth-2`).
public struct AgentMetadataFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String?; public var agentType: String; public var description: String; public var toolUseId: String?
    public var spawnDepth: Int?; public var parentAgentId: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, agentType, description, toolUseId, spawnDepth, parentAgentId }
}
public typealias AgentMetadataRecord = Lossless<AgentMetadataFields>

/// Every session-state kind shares one lossless shape; typed accessors read the fields the reducer and the index use.
public struct SessionStateFields: Codable, Hashable, Sendable, DeclaredKeys {
    public var type: String; public var sessionId: String?
    public enum CodingKeys: String, CodingKey, CaseIterable { case type, sessionId }
}
public typealias SessionStateRecord = Lossless<SessionStateFields>
public extension Lossless where Fields == SessionStateFields {
    var lastPrompt: String? { additional["lastPrompt"]?.stringValue }
    /// `nil` when the key is absent; `.some(nil)` when it was an explicit null (cleared to empty, parity §35.4).
    var leafUuid: String?? { additional["leafUuid"].map { $0.stringValue } }
    var explicit: Bool { additional["explicit"]?.boolValue ?? false }
    var rewound: Bool { additional["rewound"]?.boolValue ?? false }
    var aiTitle: String? { additional["aiTitle"]?.stringValue }
    var customTitle: String? { additional["customTitle"]?.stringValue }
    var summary: String? { additional["summary"]?.stringValue }
    var relocatedCwd: String? { additional["relocatedCwd"]?.stringValue }
    var mode: String? { additional["mode"]?.stringValue }
    var atis: String? { additional["atis"]?.stringValue }
    var continuedIn: String? { additional["continuedIn"]?.stringValue ?? additional["sessionId2"]?.stringValue }
    var agentName: String? { additional["agentName"]?.stringValue }
    var tag: String? { additional["tag"]?.stringValue }
    var messageId: String? { additional["messageId"]?.stringValue }
    var operation: String? { additional["operation"]?.stringValue }
    var costState: JSONValue? { fields.type == "cost-state" ? .object(additional) : nil }
}
```

Decision: `leafUuid` is `String??` on purpose — `last-prompt` with `leafUuid: null` and `explicit: true` is *cleared to empty*, which is different from a `last-prompt` without the key; `Lossless.explicitNulls` records the null and `additional` does not, so the accessor reads `explicitNulls.contains("leafUuid")` as `.some(nil)`. Implement it that way (the sketch above is the shape, not the final body).

- [ ] **Step 3: The vocabulary**

`FleetKit/Sources/FleetTimeline/Records/SessionStateVocabulary.swift`:

```swift
/// The engine's own record-kind table, transcribed from 2.1.258 `cli.pretty.js` lines 428922 (`dts`: fold policy) and
/// 429460 (`vbr`: dedup policy). The five conversation kinds are `Vr` at line 250499. A kind outside this set decodes as
/// `.unknown` and fails the vocabulary assertion, because a new kind is drift this child exists to notice.
public enum SessionStateVocabulary {
    public enum Fold: String, Sendable { case lastWins = "last-wins", accumulate, boundaryCleared = "boundary-cleared", transcript }
    public static let conversationKinds: Set<String> = ["user", "assistant", "attachment", "system", "progress"]
    public static let kinds: [String: Fold] = [
        "file-history-snapshot": .boundaryCleared, "file-history-delta": .boundaryCleared, "last-prompt": .boundaryCleared,
        "continued-in": .boundaryCleared, "marble-origami-commit": .boundaryCleared, "marble-origami-snapshot": .boundaryCleared,
        "marble-origami-reset": .boundaryCleared,
        "content-replacement": .accumulate, "fork-context-ref": .accumulate, "frame-link": .accumulate, "artifact-comment-monitor": .accumulate,
        "summary": .lastWins, "custom-title": .lastWins, "ended-by-model": .lastWins, "ai-title": .lastWins, "tag": .lastWins,
        "relocated": .lastWins, "agent-name": .lastWins, "agent-color": .lastWins, "agent-setting": .lastWins, "pr-link": .lastWins,
        "artifact-autoreact-ledger": .lastWins, "bridge-session": .lastWins, "history-suppression": .lastWins,
        "attribution-snapshot": .lastWins, "mode": .lastWins, "permission-mode": .lastWins, "isolation-latch": .lastWins,
        "atis-latch": .lastWins, "worktree-state": .lastWins, "cost-state": .lastWins, "queue-operation": .lastWins,
        "observer-ref": .lastWins,
    ]
    /// `agent_metadata` is the mirror's name for the sidecar and is neither conversation nor session state; it is routed on its own.
    public static let mirrorOnlyKinds: Set<String> = ["agent_metadata"]
    public static func isKnown(_ kind: String) -> Bool { conversationKinds.contains(kind) || kinds[kind] != nil || mirrorOnlyKinds.contains(kind) }
}
```

- [ ] **Step 4: The record enum and decoder**

`FleetKit/Sources/FleetTimeline/Records/TranscriptRecord.swift`:

```swift
import Foundation
import CryptoKit
import ClaudeWire

public enum TranscriptRecord: Sendable, Hashable {
    case user(UserRecord), assistant(AssistantRecord), attachment(AttachmentRecord), system(SystemRecord), progress(ProgressRecord)
    case agentMetadata(AgentMetadataRecord)
    case sessionState(SessionStateRecord)
    case unknown(kind: String, JSONValue)
    case undecodable(raw: Data, byteOffset: Int, reason: String)

    public var kind: String {
        switch self {
        case .user: "user"; case .assistant: "assistant"; case .attachment: "attachment"; case .system: "system"; case .progress: "progress"
        case .agentMetadata: "agent_metadata"; case .sessionState(let s): s.type; case .unknown(let k, _): k; case .undecodable: "<undecodable>"
        }
    }
    public var uuid: String? {
        switch self {
        case .user(let r): r.uuid; case .assistant(let r): r.uuid; case .attachment(let r): r.uuid; case .system(let r): r.uuid; case .progress(let r): r.uuid
        default: nil
        }
    }
    public var isConversation: Bool { uuid != nil && SessionStateVocabulary.conversationKinds.contains(kind) }

    /// uuid when the record has one; otherwise SHA-256 of the canonical JSON, hex.
    public func key(in stream: LogicalStream) -> RecordKey {
        if let uuid { return RecordKey(stream: stream, identity: .uuid(uuid)) }
        return RecordKey(stream: stream, identity: .hash(Self.hash(of: self)))
    }
    static func hash(of record: TranscriptRecord) -> String {
        let data = (try? RecordDecoder.encode(record)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum RecordDecoder {
    /// Two stages, never throws: JSONValue first, typed model from the same bytes second. A mirror entry goes through the same
    /// function after `canonicalData()`, so the file and the mirror decode identically.
    public static func decode(line: Data, byteOffset: Int = 0) -> TranscriptRecord {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: line) }
        catch { return .undecodable(raw: line, byteOffset: byteOffset, reason: "invalid_json") }
        guard value.objectValue != nil else { return .undecodable(raw: line, byteOffset: byteOffset, reason: "not_an_object") }
        guard let kind = value["type"]?.stringValue else { return .unknown(kind: "<untyped>", value) }
        func typed<F: Codable & Sendable & DeclaredKeys>(_: F.Type, _ wrap: (Lossless<F>) -> TranscriptRecord) -> TranscriptRecord {
            do { return wrap(try JSONDecoder().decode(Lossless<F>.self, from: line)) }
            catch { return .undecodable(raw: line, byteOffset: byteOffset, reason: "decode_failure:\(kind)") }
        }
        switch kind {
        case "user": return typed(UserRecordFields.self, TranscriptRecord.user)
        case "assistant": return typed(AssistantRecordFields.self, TranscriptRecord.assistant)
        case "attachment": return typed(AttachmentRecordFields.self, TranscriptRecord.attachment)
        case "system": return typed(SystemRecordFields.self, TranscriptRecord.system)
        case "progress": return typed(ProgressRecordFields.self, TranscriptRecord.progress)
        case "agent_metadata": return typed(AgentMetadataFields.self, TranscriptRecord.agentMetadata)
        default:
            if SessionStateVocabulary.kinds[kind] != nil { return typed(SessionStateFields.self, TranscriptRecord.sessionState) }
            return .unknown(kind: kind, value)
        }
    }
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
        case .progress(let r): return try enc.encode(r); case .agentMetadata(let r): return try enc.encode(r)
        case .sessionState(let r): return try enc.encode(r)
        case .unknown(_, let v): return try v.canonicalData()
        case .undecodable(let raw, _, _): return raw
        }
    }
}
```

Decision: a `user`, `assistant`, `attachment`, `system` or `progress` line whose typed decode fails is `.undecodable`, not `.unknown` — the kind is known and the shape is wrong, which is the alarm the parent's opacity rule wants; the reason string is a fixed vocabulary (`invalid_json`, `not_an_object`, `decode_failure:<kind>`) and never the decoder's message.

- [ ] **Step 5: The test-side corpus loader**

`FleetKit/Tests/FleetTimelineTests/Support/FixtureCorpus.swift`:

```swift
import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// `<repo>/Fixtures`, from this file: FleetKit/Tests/FleetTimelineTests/Support/FixtureCorpus.swift → up five.
enum FixtureCorpus {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    /// The config home every recording used; mirror `filePath` values resolve under it.
    static let recordedConfigHome = URL(fileURLWithPath: "/tmp/afleet-fixtures/config-home")
    static let committedCount = 18
    static let committedRecordedCount = 16
    /// Fixtures with at least one mirrored stream, pinned as names so a silent loss fails (spec G1).
    static let mirrored: Set<String> = [
        "ask-user-question", "background-shell", "control-shapes", "exit-plan-mode", "explore-depth-1", "nested-depth-2",
        "notification-hook", "permission-allow", "permission-deny", "plain-two-turn", "rate-limited-turn", "resume-no-replay",
        "send-user-file", "session-mirror-relocation", "session-mirror-resume",
    ]

    struct Fixture {
        let name: String; let dir: URL; let synthetic: Bool; let sessionID: SessionID
        let unmirroredPrefix: Int; let identityOnly: [String: [String]]     // scope → field paths (`mirror_identity_only`)
        let streamOffsets: [String: Int]                                    // streams.json: "<slug>/<file>" → byte offset
        var framesURL: URL { dir.appendingPathComponent("frames.ndjson") }
        /// Every JSONL under transcript/, resolved to its stream; `_slug_` is a slug like any other.
        func transcriptFiles() throws -> [(LogicalStream, TranscriptPath, URL)]
        func metaFiles() throws -> [(LogicalStream, URL)]
        /// Offset for a stream: streams.json keys are `<slug>/<relative path>`; match on the path's suffix.
        func offset(for path: URL) -> Int
        func frames() throws -> [RecordedFrame]
    }
    struct RecordedFrame { let index: Int; let t: Int; let direction: String; let value: JSONValue; let frame: Frame }

    static func all() throws -> [Fixture]       // sorted by name; asserts count == committedCount; fails on a dir missing frames.ndjson or fixture.json
    static func named(_ name: String) throws -> Fixture
}
```

Implement it fully: `fixture.json` parsed with `JSONDecoder` into `JSONValue`; `streams.json` likewise; `transcriptFiles()` walks `transcript/` recursively with `FileManager.enumerator`, keeps `.jsonl`, and resolves each through `TranscriptPath.resolve` after rewriting the fixture-relative path onto `recordedConfigHome/projects/<slug>/…` (the fixture's `transcript/<slug>/…` layout is the config home's `projects/` layout); `frames()` decodes each NDJSON line's envelope (`t`, `dir`, `frame`) and the frame through `FrameDecoder.decode(line: try frame.canonicalData())`, exactly as C2's `FixtureCorpusTests` does.

- [ ] **Step 6: The record-model tests**

`FleetKit/Tests/FleetTimelineTests/Records/RecordModelTests.swift`:

```swift
final class RecordModelTests: XCTestCase {
    /// Every record in every transcript file and every mirror entry round-trips key for key. The floor is the corpus's own
    /// record count, asserted as an equality so a loader that skipped a file cannot pass.
    func testEveryCorpusRecordRoundTripsLosslessly() throws {
        var fileRecords = 0, mirrorEntries = 0, kinds: Set<String> = []
        for fx in try FixtureCorpus.all() {
            for (_, _, url) in try fx.transcriptFiles() {
                for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    let original = try JSONDecoder().decode(JSONValue.self, from: Data(line))
                    let record = RecordDecoder.decode(line: Data(line))
                    if case .undecodable = record { XCTFail("\(fx.name): a record failed to decode"); continue }
                    if case .unknown(let k, _) = record { XCTFail("\(fx.name): unknown record kind \(k)"); continue }
                    let again = try JSONDecoder().decode(JSONValue.self, from: try RecordDecoder.encode(record))
                    XCTAssertTrue(again.numericallyEqual(original), "\(fx.name): \(record.kind) lost a key or value")
                    kinds.insert(record.kind); fileRecords += 1
                }
            }
            for f in try fx.frames() {
                guard case .transcriptMirror(let m) = f.frame else { continue }
                for entry in m.entries {
                    let record = RecordDecoder.decode(entry: entry)
                    if case .unknown(let k, _) = record { XCTFail("\(fx.name): unknown mirror kind \(k)") }
                    let again = try JSONDecoder().decode(JSONValue.self, from: try RecordDecoder.encode(record))
                    XCTAssertTrue(again.numericallyEqual(entry), "\(fx.name): mirrored \(record.kind) lost a key or value")
                    kinds.insert(record.kind); mirrorEntries += 1
                }
            }
        }
        XCTAssertEqual(fileRecords, 611)      // the corpus census of 2026-09-05 (spec Grounding); re-pin when C1 re-records
        XCTAssertEqual(mirrorEntries, 496)
        XCTAssertEqual(kinds, ["user", "assistant", "attachment", "queue-operation", "file-history-snapshot", "file-history-delta",
                               "atis-latch", "last-prompt", "ai-title", "mode", "relocated", "agent_metadata"])
    }
    func testKeysUseUUIDForConversationRecordsAndAHashOtherwise() throws { /* a `user` record keys by uuid; an `ai-title` keys by hash; two equal ai-title lines key equal; one differing byte keys differently */ }
    func testLeafUuidDistinguishesAbsentFromExplicitNull() throws { /* `{"type":"last-prompt","leafUuid":null,"explicit":true}` → .some(nil); without the key → nil */ }
    func testAKnownKindWithABrokenShapeIsUndecodableNotUnknown() throws { /* `{"type":"user"}` (no message) → .undecodable with reason "decode_failure:user" */ }
    func testResolveReadsSessionFromFileNameNotSlug() throws { /* main, agent jsonl, meta.json, a memory/MEMORY.md → nil, a tool-results file → nil, a slug that is not the cwd's */ }
    func testVocabularyMatchesTheBundleTables() { XCTAssertEqual(SessionStateVocabulary.kinds.count, 36); XCTAssertTrue(SessionStateVocabulary.isKnown("cost-state")); XCTAssertFalse(SessionStateVocabulary.isKnown("made-up")) }
}
```

Write the bodies in full. The pinned counts 611 and 496 and the twelve-kind set are the spec's Grounding; if the executor's count differs, the spec is wrong and the plan stops for the orchestrator rather than re-pinning.

- [ ] **Step 7: Run, demonstrate, commit**

Run: `swift test --package-path FleetKit --filter RecordModelTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 6 tests, with 0 failures`.
Demonstrate red: in `RecordDecoder.decode`, temporarily route `"ai-title"` to `.unknown`; the round-trip test must fail with `unknown record kind ai-title`. Restore. Quote the failing line in the ledger.

```bash
git rm -q FleetKit/Tests/FleetTimelineTests/Placeholder.swift
git add FleetKit/Sources/FleetTimeline FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: logical streams, record keys, the lossless record model and the engine's kind vocabulary"
```

---

### Task 2: The transcript reader and the head-and-tail reader

**Files:**
- Create: `FleetKit/Sources/FleetTimeline/Reader/LineScanner.swift`
- Create: `FleetKit/Sources/FleetTimeline/Reader/TranscriptReader.swift`
- Create: `FleetKit/Sources/FleetTimeline/Reader/HeadTailReader.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Support/TempTree.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Reader/TranscriptReaderTests.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Reader/HeadTailReaderTests.swift`

**Interfaces:**
- Consumes: from Task 1: `TranscriptRecord`, `RecordDecoder.decode(line:byteOffset:)`, `FixtureCorpus`.
- Produces: `TranscriptReader` (`readAll()`, `readAppended(from:)`, `readWindow(policy:)`, `readEarlier(before:)`, `ReadResult`, `WindowPolicy`, `ReaderError`), `LineScanner.lines(in:)`, `HeadTailReader` (`read(_:) -> HeadTail?`, `HeadTail`, the substring helpers `firstString(_:key:)`, `lastString(_:key:)`, `lastLineString(_:type:key:)`, `firstLineString(_:key:)`, `firstPrompt(_:)`), and the test support `TempTree` (a config-home-shaped tree under the temporary directory assembled from fixture snapshots, with `touch`, `append`, `remove`, `relocate`).

- [ ] **Step 1: Line scanning with the torn-tail rule**

`FleetKit/Sources/FleetTimeline/Reader/LineScanner.swift`:

```swift
import Foundation

/// Splits transcript bytes into complete lines. The engine seals a torn tail by writing a leading `\n` before the next
/// record (parity §35.1), so an empty line is skipped, and a final run of bytes without a terminator is *held back*: it is
/// returned as `partial` and never decoded, because the next append will complete it.
public enum LineScanner {
    public struct Scan: Sendable { public var lines: [(offset: Int, bytes: Data)]; public var consumed: Int; public var partial: Data? }
    public static func scan(_ data: Data, base: Int = 0) -> Scan {
        var lines: [(Int, Data)] = []; var start = data.startIndex
        while let nl = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var line = data[start..<nl]
            while let first = line.first, first <= 32 { line = line.dropFirst() }      // the engine's own whitespace skip (`Qr`, line 250499)
            if !line.isEmpty { lines.append((base + (start - data.startIndex), Data(line))) }
            start = data.index(after: nl)
        }
        let rest = data[start...]
        return Scan(lines: lines.map { (offset: $0.0, bytes: $0.1) }, consumed: start - data.startIndex, partial: rest.isEmpty ? nil : Data(rest))
    }
}
```

- [ ] **Step 2: The reader**

`FleetKit/Sources/FleetTimeline/Reader/TranscriptReader.swift`:

```swift
import Foundation

public enum ReaderError: Error, Sendable, Equatable { case notARegularFile, symlinkRefused, unreadable(code: Int32) }

public struct ReadResult: Sendable {
    public var records: [TranscriptRecord]
    public var length: Int                 // the byte length the read covered, i.e. the next `readAppended(from:)` offset
    public var window: WindowMarker?
    public init(records: [TranscriptRecord], length: Int, window: WindowMarker? = nil) { self.records = records; self.length = length; self.window = window }
}
public struct WindowMarker: Sendable, Hashable, Codable {
    public var earlierAvailable: Bool
    public var continueBefore: Int          // byte offset at which `readEarlier(before:)` continues
    public init(earlierAvailable: Bool, continueBefore: Int) { self.earlierAvailable = earlierAvailable; self.continueBefore = continueBefore }
}
public struct WindowPolicy: Sendable, Hashable {
    public var wholeFileUpTo: Int = 8 * 1024 * 1024        // above the local p99 (spec Grounding)
    public var initialTail: Int = 4 * 1024 * 1024
    public var earlierStep: Int = 4 * 1024 * 1024
    public init() {}
    public static let whole = WindowPolicy(wholeFileUpTo: .max, initialTail: .max, earlierStep: .max)
}

/// One transcript file, opened `O_RDONLY | O_NOFOLLOW` on every call; a symlink or a non-regular file is refused.
public struct TranscriptReader: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func readAll() throws -> ReadResult                                   // whole file; partial tail held back
    public func readAppended(from offset: Int) throws -> ReadResult             // bytes after `offset`; `length` is the new offset
    public func readWindow(policy: WindowPolicy = .init()) throws -> ReadResult // whole file under the threshold; else the tail window, aligned back to a line start
    public func readEarlier(before offset: Int, policy: WindowPolicy = .init()) throws -> ReadResult
    public func byteLength() throws -> Int
}
```

Decisions: `open(2)` with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`, then `fstat` and refuse anything that is not `S_IFREG` (`ReaderError.notARegularFile`; `ELOOP` maps to `.symlinkRefused`); read with `pread` into a `Data` of the requested range; `readWindow` chooses the whole file when `byteLength() <= policy.wholeFileUpTo`, otherwise reads the last `policy.initialTail` bytes, drops everything before the first `\n` (a line start), and returns `WindowMarker(earlierAvailable: true, continueBefore: <offset of that line start>)`; `readEarlier(before:)` reads the `earlierStep` bytes ending at `before`, aligned the same way, with `earlierAvailable: false` when it reached offset 0. Leaf-path closure (the window extended backwards until the leaf chain is closed) is the reducer's job in Task 5, not the reader's: the reader deals in bytes and lines. The record decode passes `byteOffset` so `.undecodable` names where.

- [ ] **Step 3: The head-and-tail reader**

`FleetKit/Sources/FleetTimeline/Reader/HeadTailReader.swift`:

```swift
import Foundation

/// The picker's read, exactly (2.1.258 `ihe`, line 13803; `od = 65536`): the first and last 64 KiB and the stat.
public struct HeadTail: Sendable, Hashable { public var mtime: Date; public var size: Int64; public var head: String; public var tail: String }
public protocol HeadTailReading: Sendable { func read(_ url: URL) throws -> HeadTail? }
public struct HeadTailReader: HeadTailReading {
    public static let chunk = 65_536
    public init() {}
    public func read(_ url: URL) throws -> HeadTail?      // nil for a non-file; O_NOFOLLOW; the tail read starts at max(0, size - 64 KiB)

    // The engine's substring helpers, same semantics, same names in the doc comments (`G1`, `Gf`, `Ose`, `VQ`, `Ett`):
    /// `G1`: first occurrence of `"key":"…"` (or `"key": "…"`) anywhere in `text`, JSON-unescaped.
    public static func firstString(_ text: String, key: String) -> String?
    /// `Gf`: last occurrence, JSON-unescaped.
    public static func lastString(_ text: String, key: String) -> String?
    /// `Ose`: scanning lines from the end, the first line that contains `"key":` and (when given) `"type":"<type>"`, parsed as JSON, its string field `key`.
    public static func lastLineString(_ text: String, type: String?, key: String) -> String?
    /// `VQ`: scanning lines from the start, the first line containing `"key":`, parsed, its string field `key`.
    public static func firstLineString(_ text: String, key: String) -> String?
    /// `Ett`: the first `user` line that is not a tool_result, not `isMeta`, not `isCompactSummary`; its content string or first text block, else "".
    public static func firstPrompt(_ head: String) -> String
}
```

- [ ] **Step 4: Temporary trees for tests**

`FleetKit/Tests/FleetTimelineTests/Support/TempTree.swift`: a class that creates `<tmp>/afleet-c3-<uuid>/projects/` and copies a fixture's `transcript/` under it, with `slug(for:)`, `touch(_:)` (append a newline-terminated record copied from the same file's last line with a fresh uuid — a *repeat*, never new content), `appendRaw(_:to:)`, `remove(_:)`, `relocate(session:from:to:)` (move the file and the sidecar directory), `symlink(_:to:)`, and `deinit` removing the tree. The root is `FileManager.default.temporaryDirectory`, never a config home.

- [ ] **Step 5: Tests**

`TranscriptReaderTests`: `testReadAllDecodesEveryLineOfEveryCorpusFile` (records per file equal the line count of non-empty lines, asserted per file, and the total equals Task 1's 611 for the transcript files alone); `testATornTailIsHeldBackAndCompletedByTheNextAppend` (copy a file, append half a record without a newline → `readAppended` returns 0 records and does not advance past the partial; append the rest plus `\n` → 1 record, offset at the end); `testASealedTailIsSkipped` (a leading `\n` before a record yields no empty record); `testOneCorruptLineYieldsOneUndecodable` (insert a non-JSON line mid-file → exactly one `.undecodable` with that line's byte offset, every other record intact); `testWindowAlignsToALineStart` (policy with `wholeFileUpTo: 0`, `initialTail: 2000` on `nested-depth-2`'s main file: the first record is complete, `continueBefore` equals its byte offset, `readEarlier` from there returns the preceding records and reaches 0 with `earlierAvailable: false`, and the union equals `readAll`); `testSymlinkAndDirectoryAreRefused`.

`HeadTailReaderTests`: `testReadsHeadAndTailAndStatOfEveryCorpusFile` (size equals the file's byte count; for a file under 64 KiB head equals tail equals the whole file); `testHelpersMatchTheEngineOnTheCorpus` (on `session-mirror-relocation`: `lastLineString(tail, type: "relocated", key: "relocatedCwd")` returns a string and `firstLineString(head, key: "cwd")` returns a different one; on `plain-two-turn`: `firstPrompt(head)` equals the first prompt in `fixture.json`'s `prompts[0]`; `lastString(tail, key: "aiTitle")` is non-nil where an `ai-title` record exists); `testFirstPromptSkipsToolResultsMetaAndCompactSummary` (mutate a copied head in memory: put a `tool_result` user line and an `isMeta` user line before the prompt → still the prompt).

- [ ] **Step 6: Run, demonstrate, commit**

Run: `swift test --package-path FleetKit --filter "TranscriptReaderTests|HeadTailReaderTests" 2>&1 | grep -E "Executed|failed"`
Expected: `Executed 9 tests, with 0 failures`.
Demonstrate red: make `LineScanner` return the partial as a line (drop the hold-back) → `testATornTailIsHeldBackAndCompletedByTheNextAppend` fails on the first assertion. Restore.

```bash
git add FleetKit/Sources/FleetTimeline/Reader FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: transcript reader with torn-tail hold-back and bounded windows; the picker's head-and-tail read"
```

---

### Task 3: Check one of the invariant — mirror fidelity on every fixture

**Files:**
- Create: `FleetKit/Tests/FleetTimelineTests/Support/Breaks.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Invariant/MirrorFidelityTests.swift`

**Interfaces:**
- Consumes: Task 1's `FixtureCorpus`, `TranscriptRecord`, `RecordDecoder`, `RecordKey`, `TranscriptPath.resolve`; Task 2's `TranscriptReader`.
- Produces: `MirrorReplay` (test-side): `streams(of fixture) -> [LogicalStream: [TranscriptRecord]]` from mirror frames in order, and `appendedFileRecords(of fixture) -> [LogicalStream: (records: [TranscriptRecord], url: URL)]`; the `IdentityMask` used again by Task 9. `Breaks` holds the in-memory mutation helpers (`dropping(recordAt:)`, `mutating(field:in:)`, `renamingKind(of:to:)`).

- [ ] **Step 1: The replay helpers**

Inside `MirrorFidelityTests.swift` (or `Support/MirrorReplay.swift` if it grows past a screen):

```swift
enum MirrorReplay {
    /// Mirror entries per stream, in frame order. `filePath` resolves under the recorded config home; the stream — not the path —
    /// is the key, which is what makes the relocation fixture one stream under two paths.
    static func mirroredStreams(_ fx: FixtureCorpus.Fixture) throws -> [LogicalStream: [TranscriptRecord]] {
        var out: [LogicalStream: [TranscriptRecord]] = [:]
        for f in try fx.frames() {
            guard case .transcriptMirror(let m) = f.frame,
                  let (stream, _) = TranscriptPath.resolve(URL(fileURLWithPath: m.filePath), under: FixtureCorpus.recordedConfigHome)
            else { continue }
            out[stream, default: []].append(contentsOf: m.entries.map(RecordDecoder.decode(entry:)))
        }
        return out
    }
    /// File records in the appended range: from the stream's streams.json offset to end of file.
    static func appendedFileRecords(_ fx: FixtureCorpus.Fixture) throws -> [LogicalStream: (records: [TranscriptRecord], url: URL)] {
        var out: [LogicalStream: ([TranscriptRecord], URL)] = [:]
        for (stream, _, url) in try fx.transcriptFiles() {
            out[stream] = (try TranscriptReader(url: url).readAppended(from: fx.offset(for: url)).records, url)
        }
        return out
    }
}

/// `mirror_identity_only`: scope → field paths that may differ. A scope matches a stream when the stream's file path contains it.
struct IdentityMask {
    let scopes: [String: [String]]
    func allowed(for stream: LogicalStream, path: URL) -> Set<String>
    /// The dotted paths at which two lossless-encoded JSON values differ, ignoring `allowed`.
    static func differingPaths(_ a: JSONValue, _ b: JSONValue, prefix: String = "") -> Set<String>
}
```

- [ ] **Step 2: The test**

```swift
final class MirrorFidelityTests: XCTestCase {
    /// Spec G1, check one. Identity sequences equal exactly per stream after the declared unmirrored prefix; fields equal
    /// except at declared paths; agent_metadata entries equal the .meta.json; the mirrored-fixture set equals the pinned set.
    func testMirroredEntriesEqualTheAppendedFileRecordsOnEveryFixture() throws {
        var mirroredNames: Set<String> = []; var streamsCompared = 0; var recordsCompared = 0
        for fx in try FixtureCorpus.all() {
            let mirrored = try MirrorReplay.mirroredStreams(fx)
            if mirrored.isEmpty { continue }
            mirroredNames.insert(fx.name)
            let files = try MirrorReplay.appendedFileRecords(fx)
            let mask = IdentityMask(scopes: fx.identityOnly)
            var prefixSkipped = 0
            for (stream, entries) in mirrored {
                let conversation = entries.filter { if case .agentMetadata = $0 { return false }; return true }
                guard let (fileRecords, url) = files[stream] else { XCTFail("\(fx.name): mirror names a stream with no file: \(stream.name.label)"); continue }
                // The unmirrored prefix is at the head of the appended range and only on the main stream (spec Grounding; verify.py).
                var expected = fileRecords
                if case .main = stream.name, fx.unmirroredPrefix > 0 { expected.removeFirst(fx.unmirroredPrefix); prefixSkipped += fx.unmirroredPrefix }
                XCTAssertEqual(conversation.map { $0.key(in: stream) }, expected.map { $0.key(in: stream) },
                               "\(fx.name)/\(stream.name.label): mirrored identity sequence differs from the file's appended range")
                let allowed = mask.allowed(for: stream, path: url)
                for (m, f) in zip(conversation, expected) {
                    let diff = IdentityMask.differingPaths(try m.jsonValue(), try f.jsonValue()).subtracting(allowed)
                    XCTAssertTrue(diff.isEmpty, "\(fx.name)/\(stream.name.label): \(m.kind) differs at \(diff.sorted()) — not declared identity-only")
                    recordsCompared += 1
                }
                for case .agentMetadata(let meta) in entries {
                    guard case .agent(let task) = stream.name else { XCTFail("\(fx.name): agent_metadata on the main stream"); continue }
                    let sidecar = try fx.metaFiles().first { $0.0 == stream }.map { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: $0.1)) }
                    XCTAssertNotNil(sidecar, "\(fx.name): no .meta.json for agent \(task)")
                    var body = try meta.jsonValue().objectValue ?? [:]; body["type"] = nil
                    XCTAssertTrue(JSONValue.object(body).numericallyEqual(sidecar ?? .null), "\(fx.name): agent_metadata differs from .meta.json for \(task)")
                }
                streamsCompared += 1
            }
            XCTAssertEqual(prefixSkipped, fx.unmirroredPrefix, "\(fx.name): unmirrored_prefix \(fx.unmirroredPrefix) declared, \(prefixSkipped) used")
        }
        XCTAssertEqual(mirroredNames, FixtureCorpus.mirrored)
        XCTAssertEqual(streamsCompared, 19)         // 15 fixtures, plus one extra stream in explore-depth-1 and two in nested-depth-2, plus the relocation's one stream under two paths counted once
        XCTAssertGreaterThanOrEqual(recordsCompared, 400)  // grounded: 496 mirrored entries minus 3 agent_metadata minus nothing else; the exact figure is asserted by RecordModelTests
    }
}
```

`TranscriptRecord.jsonValue()` is a small test-side extension: `JSONDecoder().decode(JSONValue.self, from: RecordDecoder.encode(self))`. Compute `streamsCompared` from the corpus during execution and pin the exact number; the 19 above is the plan's arithmetic (15 main streams + 1 + 2 agent streams + the relocation's second path folds into its one stream) and must be confirmed, not trusted.

- [ ] **Step 3: Demonstrate red, four ways, then commit**

Using `Breaks`, in memory only, one at a time, quoting each failing assertion in the ledger:
1. Drop the third mirrored entry of `plain-two-turn`'s main stream → identity-sequence assertion fails.
2. Mutate `message.usage.output_tokens` in one mirrored `assistant` entry of `plain-two-turn` → field assertion fails naming `message.usage.output_tokens`; the same mutation on `nested-depth-2`'s depth-2 agent stream passes (declared).
3. Rename the kind of one mirrored `ai-title` to `made-up` → `RecordModelTests` (Task 1) fails on vocabulary; this test's identity sequence also fails, because the hash changes.
4. Remove `"resume-no-replay"` from `FixtureCorpus.mirrored` → the set equality fails, proving the pin is load-bearing.

Run: `swift test --package-path FleetKit --filter MirrorFidelityTests 2>&1 | grep -E "Executed|failed"`
Expected: `Executed 1 test, with 0 failures`.

```bash
git add FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: the invariant's first check — mirrored entries equal the file's appended records on every fixture"
```

---

### Task 4: The timeline item model and its named constants (contract X4)

**Files:**
- Create: `FleetKit/Sources/FleetTimeline/Model/TimelineItem.swift`
- Create: `FleetKit/Sources/FleetTimeline/Model/ProjectionCategories.swift`
- Create: `FleetKit/Sources/FleetTimeline/Reduce/Projection.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Model/TimelineModelTests.swift`

**Interfaces:**
- Consumes: Task 1's `LogicalStream`, `RecordKey`; from `ClaudeWire`: `ContentBlock`, `ToolInput`, `JSONValue`, `ProcessEpoch`, `RequestID`.
- Produces: `TimelineItem` and its thirteen payload structs, `ItemID`, `Provenance`, `TimelineCategory`, `ProjectionCategories` (`durable`, `overlay`, `comparedWireToFile`, `fileOnlyRecordKinds`, `comparedItemFields`), `RecordKindMatcher`, `ItemFieldSet`, `StreamProjection`, `DurableProjection`, `SessionState`, `Branch`, `ReadWarning`, `TimelineChange`. Tasks 5, 8, 9, 11 build on these; C6 reads them.

- [ ] **Step 1: Items**

`FleetKit/Sources/FleetTimeline/Model/TimelineItem.swift` — the parent's §7.3 enum, with payloads:

```swift
import Foundation
import ClaudeWire

public struct ItemID: Hashable, Sendable, Codable {
    public let stream: LogicalStream; public let key: String
    public init(stream: LogicalStream, key: String) { self.stream = stream; self.key = key }
}
public struct Provenance: Hashable, Sendable, Codable {
    public var stream: LogicalStream; public var agentID: String?; public var sourceFile: URL?
    public var epoch: ProcessEpoch?; public var records: Set<RecordKey>; public var origin: Origin
    public enum Origin: String, Sendable, Codable { case file, mirror, wire, synthesised }
    public init(stream: LogicalStream, agentID: String? = nil, sourceFile: URL? = nil, epoch: ProcessEpoch? = nil, records: Set<RecordKey> = [], origin: Origin)
}
public enum TimelineCategory: String, CaseIterable, Sendable, Codable {
    case userMessage, assistantMessage, toolCall, cluster, taskRun, decision, hookRun, notification, peerMessage, compactBoundary, sentFile, turnSummary, opaque
}

public struct UserMessageItem: Hashable, Sendable, Codable { public var id: ItemID; public var timestamp: Date?; public var threadParent: ItemID?; public var provenance: Provenance
    public var blocks: [ContentBlock]; public var text: String; public var isReplay: Bool; public var promptUUID: String; public init(...) }
public struct AssistantMessageItem: Hashable, Sendable, Codable { …; public var messageID: String?; public var model: String?; public var blocks: [ContentBlock]
    public var stopReason: String?; public var isStreaming: Bool; public var supersededBy: String?; public var recordUUIDs: [String]; public init(...) }
public struct ToolCallItem: Hashable, Sendable, Codable { …; public var toolUseID: String; public var name: String; public var input: ToolInput; public var rawInput: JSONValue
    public var result: JSONValue?; public var isError: Bool?; public var structuredResult: JSONValue?; public var denialKind: String?
    public var messageID: String?; public var status: Status; public enum Status: String, Sendable, Codable { case running, completed, failed, denied }; public init(...) }
public struct ToolClusterItem: Hashable, Sendable, Codable { …; public var toolUseIDs: [String]; public var label: String?; public init(...) }
public struct TaskRunItem: Hashable, Sendable, Codable { …; public var taskID: String; public var kind: TaskKind; public var description: String
    public var status: TaskStatus; public var summary: String?; public var outputFile: URL?; public var usage: JSONValue?; public var toolUseID: String?
    public var agentType: String?; public var depth: Int?; public var synthesised: Bool; public init(...) }
public struct DecisionItem: Hashable, Sendable, Codable { …; public var requestID: RequestID; public var kind: Kind; public var title: String; public var toolUseID: String?
    public var agentID: String?; public var state: State; public var payload: JSONValue
    public enum Kind: String, Sendable, Codable { case permission, question, plan, dialog, elicitation }
    public enum State: Hashable, Sendable, Codable { case pending, answered(outcome: String), cancelled, policyAnswered(error: String), inert } ; public init(...) }
public struct HookRunItem: Hashable, Sendable, Codable { …; public var hookID: String; public var hookName: String; public var event: String; public var outcome: String?; public var exitCode: Int?; public init(...) }
public struct NotificationItem: Hashable, Sendable, Codable { …; public var key: String; public var text: String; public var level: String; public var fileOnly: Bool; public init(...) }
public struct PeerMessageItem: Hashable, Sendable, Codable { …; public var originKind: String; public var from: String?; public var name: String?; public var blocks: [ContentBlock]; public var text: String; public init(...) }
public struct CompactBoundaryItem: Hashable, Sendable, Codable { …; public var trigger: String?; public var hardTruncation: Bool; public var preTokens: Int?; public var postTokens: Int?; public var logicalParentUUID: String?; public init(...) }
public struct SentFileItem: Hashable, Sendable, Codable { …; public var toolUseID: String; public var files: [String]; public var caption: String?; public var delivered: Bool?; public init(...) }
public struct TurnSummaryItem: Hashable, Sendable, Codable { …; public var subtype: String; public var durationMs: Int; public var costUSD: Double; public var numTurns: Int
    public var stopReason: String?; public var usage: JSONValue?; public var permissionDenials: JSONValue?; public var attribution: TurnAttribution; public init(...) }
public enum TurnAttribution: Hashable, Sendable, Codable { case prompted(uuid: String), relocation, unprompted }
public struct OpaqueItem: Hashable, Sendable, Codable { …; public var type: String?; public var subtype: String?; public var reason: String; public var value: JSONValue; public init(...) }

public enum TimelineItem: Identifiable, Hashable, Sendable, Codable {
    case userMessage(UserMessageItem), assistantMessage(AssistantMessageItem), toolCall(ToolCallItem), cluster(ToolClusterItem)
    case taskRun(TaskRunItem), decision(DecisionItem), hookRun(HookRunItem), notification(NotificationItem), peerMessage(PeerMessageItem)
    case compactBoundary(CompactBoundaryItem), sentFile(SentFileItem), turnSummary(TurnSummaryItem), opaque(OpaqueItem)
    public var id: ItemID { get }; public var timestamp: Date? { get }; public var threadParent: ItemID? { get }
    public var provenance: Provenance { get }; public var category: TimelineCategory { get }
}
```

Every `…` above stands for the four common fields (`id`, `timestamp`, `threadParent`, `provenance`), written out in each struct; every struct has a public memberwise initialiser written out. `TaskKind` and `TaskStatus` are defined in Task 6's file; declare them here in `TimelineItem.swift` now (Task 6 uses them) — they are model, not registry:

```swift
public enum TaskKind: Hashable, Sendable, Codable {
    case localBash, localAgent, remoteAgent, inProcessTeammate, localWorkflow, monitorMCP, monitorWS, mcpTask, dream, autoModeScan, other(String)
    public init(wire: String)      // "local_bash" → .localBash … anything else → .other(wire)
    public var wire: String { get }
}
public enum TaskStatus: String, Sendable, Codable { case running, completed, failed, stopped
    public init(wire: String)      // "killed" → .stopped (parity §20.8.4); "pending"/"running" → .running; unknown → .running with no crash
}
```

- [ ] **Step 2: The constants**

`FleetKit/Sources/FleetTimeline/Model/ProjectionCategories.swift` — exactly the spec's block:

```swift
public enum RecordKindMatcher: Hashable, Sendable {
    case kind(String), system(String), userWhere(UserFlag)
    public enum UserFlag: String, Sendable { case isMeta }
    public func matches(_ record: TranscriptRecord) -> Bool
}
public struct ItemFieldSet: Hashable, Sendable, ExpressibleByArrayLiteral {
    public enum Field: Hashable, Sendable { case role, model, origin, toolDenialKind
        case contentBlocks(text: Bool, thinking: Bool, toolUseID: Bool, toolUseName: Bool, toolUseInput: Bool, toolResultContent: Bool, toolResultIsError: Bool, image: Bool, document: Bool) }
    public let fields: Set<Field>
}
public enum ProjectionCategories {
    public static let durable: Set<TimelineCategory> = [.userMessage, .assistantMessage, .toolCall, .peerMessage, .sentFile, .compactBoundary, .taskRun]
    public static let overlay: Set<TimelineCategory> = [.cluster, .decision, .hookRun, .notification, .turnSummary]
    public static let comparedWireToFile: Set<TimelineCategory> = [.userMessage, .assistantMessage, .toolCall, .peerMessage, .sentFile, .taskRun]
    public static let fileOnlyRecordKinds: Set<RecordKindMatcher> = [
        .kind("attachment"), .system("turn_duration"), .system("stop_hook_summary"), .system("local_command"),
        .system("informational"), .system("compact_boundary"), .userWhere(.isMeta)]
    public static let comparedItemFields: ItemFieldSet = [.role, .model, .origin, .toolDenialKind,
        .contentBlocks(text: true, thinking: true, toolUseID: true, toolUseName: true, toolUseInput: true, toolResultContent: true, toolResultIsError: true, image: true, document: true)]
    /// Excluded on purpose and named so: `stop_reason` and `usage` differ between the mirror and the file of an agent stream
    /// (fixture declarations) and between streamed and final assistant frames; signatures are opaque; timestamps are compared
    /// separately within tolerance.
    public static let excludedItemFields: [String] = ["stop_reason", "usage", "signature", "timestamp"]
}
```

- [ ] **Step 3: Projection values**

`FleetKit/Sources/FleetTimeline/Reduce/Projection.swift`:

```swift
public struct SessionState: Hashable, Sendable, Codable {
    public var customTitle: String?; public var aiTitle: String?; public var agentName: String?; public var summary: String?
    public var leaf: String?; public var clearedToEmpty: Bool; public var relocatedCwd: String?; public var mode: String?
    public var costState: JSONValue?; public var continuedIn: String?; public var tag: String?; public var atisLatch: String?
    public init()
}
public struct Branch: Hashable, Sendable, Codable { public var head: String; public var tail: String; public var count: Int }   // record uuids
public struct ReadWarning: Hashable, Sendable, Codable { public enum Kind: String, Sendable, Codable { case undecodable, orphanHealed, orphanUnhealed, unknownKind }
    public var kind: Kind; public var stream: StreamName; public var byteOffset: Int?; public var recordKind: String? }
public struct StreamProjection: Hashable, Sendable {
    public var stream: LogicalStream; public var items: [TimelineItem]; public var hidden: [RecordKey]; public var branches: [Branch]
    public var session: SessionState; public var warnings: [ReadWarning]; public var window: WindowMarker?; public var metadata: AgentMetadataRecord?
}
public struct DurableProjection: Hashable, Sendable {
    public var items: [TimelineItem]; public var hidden: [RecordKey]; public var branches: [Branch]; public var session: SessionState
    public var warnings: [ReadWarning]; public var window: WindowMarker?; public var streams: [LogicalStream]
    public init(...)
    public static let empty: DurableProjection
    public func items(in categories: Set<TimelineCategory>) -> [TimelineItem]
}
public enum TimelineChange: Hashable, Sendable { case inserted(ItemID), updated(ItemID), removed(ItemID), previewChanged, overlayChanged, sessionStateChanged }
```

- [ ] **Step 4: Tests**

`TimelineModelTests`: `testCategorySetsPartitionAsTheSpecSays` (`durable ∩ overlay == []`, `durable ∪ overlay ∪ [.opaque] == all thirteen`, `comparedWireToFile ⊆ durable`); `testFileOnlyMatchersRecogniseTheCorpusAttachmentsAndMetaUsers` (every attachment record in the corpus matches; both `isMeta` user records match; no plain user record matches; the count of matching records equals 200 + 2); `testTaskKindAndStatusNormalisation` (`"local_bash"` → `.localBash`, `"killed"` → `.stopped`, an unknown kind round-trips through `.other`); `testItemsAreCodableAndHashable` (each payload struct encodes and decodes equal through `JSONEncoder`).

Run: `swift test --package-path FleetKit --filter TimelineModelTests 2>&1 | grep -E "Executed|failed"` → `Executed 4 tests, with 0 failures`.
Demonstrate red: remove `.userWhere(.isMeta)` from `fileOnlyRecordKinds` → the matcher count test fails at 200 ≠ 202.

```bash
git add FleetKit/Sources/FleetTimeline FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: the timeline item model, the X4 category constants and the projection values"
```

---

### Task 5: The record reducer — tree, leaf path, healing, merge rules

**Files:**
- Create: `FleetKit/Sources/FleetTimeline/Reduce/RecordReducer.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Reduce/RecordReducerTests.swift`

**Interfaces:**
- Consumes: Task 1's records and keys; Task 2's reader; Task 4's items, constants and projection values.
- Produces: `RecordReducer.reduce(_:stream:options:) -> StreamProjection`, `RecordReducer.merge(_:main:) -> DurableProjection`, `RecordReducer.Options`, and the internal `ConversationTree` used by Task 8's rewind handling.

- [ ] **Step 1: The reducer**

```swift
public struct RecordReducer: Sendable {
    public struct Options: Sendable, Hashable {
        public var hideMeta = true
        public var healWindow: TimeInterval = 5            // parity §35.13; the bundle constant is read at execution and pinned here with its line
        public var window: WindowMarker? = nil
        public init() {}
    }
    public static func reduce(_ records: [TranscriptRecord], stream: LogicalStream, sourceFile: URL? = nil, origin: Provenance.Origin = .file, options: Options = .init()) -> StreamProjection
    public static func merge(_ streams: [StreamProjection], main: LogicalStream) -> DurableProjection
}

/// The conversation as the engine keeps it: records by uuid, children by parentUuid, the leaf, the chain.
struct ConversationTree {
    var byUUID: [String: TranscriptRecord]; var children: [String: [String]]; var order: [String]   // file order of conversation uuids
    var roots: [String]; var healed: [String]; var unhealed: [String]
    init(conversation: [TranscriptRecord], healWindow: TimeInterval)
    /// Root-to-leaf chain for a leaf; the leaf is `last-prompt.leafUuid`, else the last conversation record in file order.
    func chain(to leaf: String?) -> [String]
    func branches(excluding chain: Set<String>) -> [Branch]
}
```

Rules to implement, in this order (spec "The record reducer", 1–8):

1. Partition: conversation records (`isConversation`) into the tree; `sessionState`, `agentMetadata`, `progress`, `unknown`, `undecodable` aside. Session state folds by `SessionStateVocabulary.kinds[kind]`: `.lastWins` overwrites the matching `SessionState` field; `.accumulate` appends (file-history and content-replacement are kept in `hidden` only); `.boundaryCleared` behaves as last-wins for `last-prompt` (the boundary clearing is the engine's compaction bookkeeping, not this reducer's).
2. Leaf: the last `last-prompt` in file order sets `session.leaf` (its `leafUuid`) or `session.clearedToEmpty` (explicit null with `explicit: true`); `rewound: true` is recorded on the state; no `last-prompt` → the last conversation record's uuid.
3. Tree and healing: a record whose `parentUuid` is missing is attached to the nearest earlier record in file order with the same `isSidechain` whose `timestamp` is within `healWindow`, and a `ReadWarning(.orphanHealed)` is emitted; failing that it becomes a root with `.orphanUnhealed`.
4. Items are produced from the chain only; `branches` from the rest. `progress` records: `hidden`. `attachment`: `hidden`. `user` with `isMeta` (when `hideMeta`): `hidden`. `undecodable`: a `ReadWarning(.undecodable)` and an `OpaqueItem` with `reason: "undecodable"` so the channel shows a warning row (parent §10). `unknown`: `hidden` plus `.unknownKind`.
5. Assistant merge by `message.id` across consecutive records in the chain: one `AssistantMessageItem`, `id.key` = first record's uuid, `recordUUIDs` in order, blocks concatenated in record order, `model` from the first, `stopReason` from the last; `supersedes` (read from `additional["supersedes"]`) removes the named uuids' items and marks `supersededBy`.
6. Tool calls: every `toolUse` block opens a `ToolCallItem` (`id.key` = tool-use id, `threadParent` = the assistant item's id); a `user` record whose content has a `toolResult` block with that id completes it (`result`, `isError`, `structuredResult` = `toolUseResult`, `denialKind` = `toolDenialKind`, `status` = denied when `toolDenialKind` is set, failed when `isError`, else completed); when the block id matches nothing, `sourceToolAssistantUUID` names the assistant record and the single open call in it is completed. A `user` record consisting only of tool results produces no `UserMessageItem`. `mcp__afleet__send_user_file` tool uses produce a `SentFileItem` instead of a `ToolCallItem` (`files` from `input.files`, `caption` from `input.caption`, `delivered` from the result's `isError == false`).
7. Users: `origin.kind` absent or `"human"` → `UserMessageItem` (`promptUUID` = uuid, `text` = string content or concatenated text blocks); otherwise `PeerMessageItem`.
8. System records: `compact_boundary` → `CompactBoundaryItem` (`hardTruncation` when `compactMetadata` has neither `preserved_segment`/`preservedSegment` nor `preserved_messages`/`preservedMessages`); after a hard boundary the items before it in the chain are dropped and the boundary is the first item; `informational`, `local_command`, `turn_duration`, `stop_hook_summary` → `NotificationItem(fileOnly: true)`.
9. `merge`: main items first in chain order; each agent stream's items are attached under the `ToolCallItem`/`TaskRunItem` whose tool-use id equals the stream's `metadata.toolUseId` (a `TaskRunItem` is synthesised from the metadata with `kind: .localAgent`, `synthesised: false`, provenance `.file`), ordered by timestamp among main items, `provenance.agentID` = task id, `sourceFile` set; `branches`, `hidden`, `warnings` concatenated; `session` from the main stream; `window` from the main stream.

Timestamps: ISO 8601 from the record's `timestamp`, parsed with `ISO8601DateFormatter` configured with fractional seconds, falling back to without; nil when absent.

- [ ] **Step 2: Tests**

`RecordReducerTests`, each over recorded fixtures or a named mutation:
- `testEveryMainStreamReducesToOneChainWithNoBranchesOnTheCorpus`: for every fixture with a transcript, `branches` is empty, `warnings` has no orphan entries, and the number of `userMessage` + `peerMessage` items equals the file's non-tool-result, non-meta `user` record count (computed independently by walking the records in the test).
- `testAssistantRecordsMergeByMessageID`: `plain-two-turn` yields exactly two `assistantMessage` items whose `recordUUIDs` together equal the file's assistant uuids (set equality), each with the file's `message.id`.
- `testToolCallsJoinTheirResults`: `background-shell` yields a `toolCall` named `Bash` whose `structuredResult` is non-nil and whose result text contains the artifact token; `nested-depth-2`'s main stream yields `Agent` calls completed; every `toolUse` block id in the corpus is either completed or, when the file ends before its result, `running` — asserted as set equality between open ids and ids with no result record.
- `testSentFileItemsComeFromTheMCPToolRecords`: `send-user-file` yields one `sentFile` item with `files.count == 1` and no `toolCall` named `mcp__afleet__send_user_file`.
- `testMetaUsersAndAttachmentsAreHidden`: `session-mirror-relocation` has one `isMeta` user in `hidden` and zero `userMessage` items for it; all 15 attachments are in `hidden`.
- `testLeafSelectionFollowsLastPrompt`: on `plain-two-turn`, the chain ends at the `leafUuid` of the last `last-prompt`; mutate that `leafUuid` in memory to the first assistant record's uuid → the projection ends there and the remainder is one `Branch` (the rewind shape, unwitnessed by recording and stated so in the test name suffix `_mutation`).
- `testClearedToEmptyProducesAnEmptyProjection_mutation`: append an in-memory `last-prompt` with `leafUuid: null, explicit: true` → zero items, `session.clearedToEmpty == true`.
- `testAnOrphanIsHealedToTheNearestEarlierRecord_mutation`: delete one assistant record from the middle of `plain-two-turn` → its child user record is healed onto the preceding record, one `orphanHealed` warning, no branch.
- `testSupersedesRetractsItems_mutation`: add `supersedes: [<uuid>]` to a later assistant record → the named item disappears.
- `testCompactBoundaryHardTruncates_mutation`: insert a `system`/`compact_boundary` record without preserved fields before the last exchange → only the boundary and the last exchange remain.
- `testMergeAttachesAgentItemsUnderTheirSpawningCall`: `nested-depth-2` merged yields two `taskRun` items with `agentType` `general-purpose` and `Explore`, the second's provenance `agentID` equals the depth-2 task id, and its items sit after the depth-1 call in order.

Run: `swift test --package-path FleetKit --filter RecordReducerTests 2>&1 | grep -E "Executed|failed"` → `Executed 11 tests, with 0 failures`.
Demonstrate red: comment out the `sourceToolAssistantUUID` fallback → `testToolCallsJoinTheirResults` still passes on the corpus (every result has a block id) — so that fallback is *not* discriminated by recorded data; say so in the ledger and cover it by the mutation `testToolResultWithoutBlockIDJoinsBySourceAssistantUUID_mutation` (strip the block id in memory) added to the list above, making twelve tests. Then break the merge (key items by uuid instead of `message.id`) → `testAssistantRecordsMergeByMessageID` fails with four items instead of two.

```bash
git add FleetKit/Sources/FleetTimeline/Reduce FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: the record reducer — tree, leaf path, healing, merge and join rules"
```

---

### Task 6: The background-task registry mirror and the output tailer

**Files:**
- Create: `FleetKit/Sources/FleetTimeline/Registry/RegistryMirror.swift`
- Create: `FleetKit/Sources/FleetTimeline/Registry/TaskOutputTailer.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Registry/RegistryMirrorTests.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Registry/TaskOutputTailerTests.swift`

**Interfaces:**
- Consumes: Task 4's `TaskKind`, `TaskStatus`; from `ClaudeWire`: `SystemFrame`, `TaskStarted`, `TaskUpdated`, `TaskProgress`, `TaskNotification`, `BackgroundTasksChanged`, `ToolProgressFrame`, `ProcessEpoch`.
- Produces: `RegistryEntry`, `RegistryEntry.Placement`, `RegistryMirror` (`apply(_:at:epoch:)`, `apply(toolProgress:at:)`, `observe(bashToolResult:toolUseID:)`, `liveWork(asOf:)`, `evictable(asOf:grace:)`, `entry(forToolUse:)`), `TaskOutputTailer`, `OutputChunk`, `OutputTrailer.parse(_:)`. Task 8 folds frames into the mirror; C4 calls `liveWork(asOf:)`.

- [ ] **Step 1: The mirror**

```swift
public struct RegistryEntry: Hashable, Sendable, Identifiable, Codable {
    public let id: String; public var kind: TaskKind; public var placement: Placement
    public var description: String; public var toolUseID: String?; public var outputFile: URL?
    public var status: TaskStatus; public var startedAt: Date; public var endedAt: Date?; public var lastFrameAt: Date
    public var notified: Bool; public var listedByEngine: Bool; public var epoch: ProcessEpoch
    public var summary: String?; public var usage: JSONValue?; public var startedCount: Int
    public enum Placement: String, Sendable, Codable { case foreground, background }
    public init(...)
}
public struct RegistryMirror: Hashable, Sendable {
    public private(set) var entries: [String: RegistryEntry]
    public init()
    /// Folds task_started, task_updated, task_progress, task_notification, background_tasks_changed. Other subtypes are ignored.
    public mutating func apply(_ frame: SystemFrame, at now: Date, epoch: ProcessEpoch) -> [String]     // the task ids touched
    public mutating func apply(toolProgress: ToolProgressFrame, at now: Date)
    /// "Command running in background with ID: <id>. Output is being written to: <path>." — binds the file before any task frame names it.
    public mutating func observe(bashToolResult text: String, toolUseID: String, at now: Date, epoch: ProcessEpoch)
    public func liveWork(asOf now: Date) -> [RegistryEntry]      // status == .running, or started and !notified
    public func evictable(asOf now: Date, grace: TimeInterval = 30) -> [String]   // notified, terminal, endedAt + grace < now, !listedByEngine
    public func entry(forToolUse id: String) -> RegistryEntry?
}
```

Fold rules (parity §20.8, fixture `background-shell`): `task_started` creates or re-arms (`startedCount += 1`, `status = .running`, `notified = false`), `kind = TaskKind(wire: task_type ?? "local_bash")`, `placement = is_backgrounded == true ? .background : .foreground`; `task_updated.patch.status` sets `status` through `TaskStatus(wire:)` and `patch.end_time` (epoch milliseconds) sets `endedAt`; `task_progress` sets `lastFrameAt` and keeps `description` current; `task_notification` sets `status` (already normalised by the engine to `stopped`), `notified = true`, `summary`, `usage`, `outputFile` when `output_file` is non-empty, `endedAt` if unset; `background_tasks_changed` sets `listedByEngine = true` for every id in `tasks` and `false` for every other entry, creating a minimal entry for an id it names that has no `task_started` yet (kind from `task_type`, description from the payload); every frame for an id sets `lastFrameAt = now`. The Bash `tool_result` text is matched with the two literal anchors `with ID: ` and `Output is being written to: ` and creates a `.localBash` background entry when none exists.

- [ ] **Step 2: The tailer**

```swift
public struct OutputChunk: Sendable, Hashable { public var text: String; public var exitCode: Int32?; public var truncatedByEngine: Bool; public var offset: Int }
public enum OutputTrailer {
    /// `\n[exited with code N]\n` at end of file (parity §20.10.5; fixture `background-shell`); the omission notice `[output omitted: it could not be written to disk]`.
    public static func parse(_ tail: String) -> (exitCode: Int32?, truncated: Bool)
}
public actor TaskOutputTailer {
    public init(path: URL, pollInterval: Duration = .milliseconds(250), readLimit: Int = 16 * 1024 * 1024)
    public func chunks() -> AsyncStream<OutputChunk>        // starts polling; absent file → wait; deleted file → finish the stream
    public func stop()
    public func snapshot() throws -> OutputChunk            // one read of everything so far
}
```

Decisions: polling with `stat` + `pread` from the last offset (FSEvents is not used for a file outside the config home that may live a few seconds); the file is opened `O_NOFOLLOW` and a symlink ends the stream with no chunk and a thrown `ReaderError.symlinkRefused` from `snapshot()`; the trailer is parsed only when the last bytes read end with `]\n` and the file has not grown across two polls; `readLimit` matches the engine's 16 MiB cap and stops reading beyond it with `truncatedByEngine` set when the omission notice is present.

- [ ] **Step 3: Tests**

`RegistryMirrorTests` (fold the `background-shell` system frames in `t` order with `now = Date(timeIntervalSince1970: t/1000)`): `testBackgroundShellRowByRow` — after the first `background_tasks_changed` + `task_started`: one entry, `.localBash`, `.background`, `.running`, `listedByEngine == true`, `notified == false`, in `liveWork`; after the Bash `tool_result` observe: `outputFile` non-nil; after the second `background_tasks_changed` (empty) + `task_updated(completed)` + `task_notification`: `status == .completed`, `notified == true`, `listedByEngine == false`, `outputFile` equals the notification's path, `endedAt` set, not in `liveWork`, in `evictable(asOf: endedAt + 31)` and not at `+ 29`; `testTaskStartedRepeatsAreTheSameEntry` (`nested-depth-2`: two distinct ids; replay one `task_started` twice → `startedCount == 2`, entries still two); `testKilledNormalisesToStopped` (a `task_updated` patch with `status: "killed"` → `.stopped`); `testLiveWorkIncludesStartedButNotNotified` (drop the notification from the fold → still live); `testAgentTasksAreRegistryEntriesToo` (`explore-depth-1`: one `.localAgent` entry with `spawn_depth`-bearing `task_started`).

`TaskOutputTailerTests` (on a copy of the `background-shell` artifact under the temporary directory): `testSnapshotYieldsTheOutputAndTheExitCode` (`text` starts with `bg-done`, `exitCode == 0`); `testChunksFollowAppendsAndFinishOnDeletion` (write the file in three appends with the trailer last; three chunks; delete → stream ends); `testAbsentFileIsWaitedFor` (start before creating; first chunk arrives after creation); `testSymlinkIsRefused`; `testTrailerParserAcceptsOnlyTheExactShape` (`[exited with code 3]` → 3; `exited with code` mid-text → nil).

Run: `swift test --package-path FleetKit --filter "RegistryMirrorTests|TaskOutputTailerTests" 2>&1 | grep -E "Executed|failed"` → `Executed 10 tests, with 0 failures`.
Demonstrate red: make `task_notification` not set `notified` → `testBackgroundShellRowByRow` fails on `liveWork` still containing the task. Make the trailer parser accept any `exited with code` substring → `testTrailerParserAcceptsOnlyTheExactShape` fails.

```bash
git add FleetKit/Sources/FleetTimeline/Registry FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: the registry mirror folded from task frames, and the output-file tailer with the exit trailer"
```

---

### Task 7: The agent-run tree

**Files:**
- Create: `FleetKit/Sources/FleetTimeline/Agents/AgentRunTree.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Agents/AgentRunTreeTests.swift`

**Interfaces:**
- Consumes: Task 1's `AgentMetadataRecord`, `LogicalStream`, `TranscriptPath.path(of:slug:)`; Task 4's `TaskStatus`; from `ClaudeWire`: `TaskStarted`, `TaskProgress`, `TaskUpdated`, `TaskNotification`, `AssistantFrame`.
- Produces: `AgentRunNode`, `AgentRunNode.ParentSource`, `AgentRunTree` with `apply(taskStarted:at:)`, `apply(taskProgress:at:)`, `apply(taskUpdated:at:)`, `apply(taskNotification:at:)`, `apply(agentMetadata:for:)`, `apply(metaFile:)`, `observe(frame:)` (the two-step join input), `observe(assistantModel:agentID:)`, `node(_:)`, `roots`, `children(of:)`, `isParked(_:)`, `transcriptURL(for:slug:configHome:sessionID:)`.

- [ ] **Step 1: The tree**

```swift
public struct AgentRunNode: Hashable, Sendable, Identifiable, Codable {
    public let id: String
    public var agentType: String?; public var description: String; public var model: String?
    public var status: TaskStatus; public var depth: Int; public var parent: String?; public var parentSource: ParentSource
    public var activityLine: String?; public var lastToolName: String?; public var elapsedOrigin: Date; public var endedAt: Date?
    public var toolUseID: String?; public var transcript: URL?; public var children: [String]; public var startedCount: Int
    public enum ParentSource: String, Sendable, Codable { case agentMetadata, metaFile, twoStepJoin, none }
    public init(...)
}
public struct AgentRunTree: Hashable, Sendable {
    public private(set) var nodes: [String: AgentRunNode]
    public var roots: [String] { get }                              // depth-1 nodes in start order
    public init(configHome: URL, sessionID: SessionID, slug: String)
    public mutating func apply(taskStarted f: TaskStarted, at now: Date)      // only task_type == "local_agent"; repeat → startedCount += 1
    public mutating func apply(taskProgress f: TaskProgress, at now: Date)
    public mutating func apply(taskUpdated f: TaskUpdated, at now: Date)
    public mutating func apply(taskNotification f: TaskNotification, at now: Date)
    public mutating func apply(agentMetadata m: AgentMetadataRecord, for stream: LogicalStream)     // parentAgentId → parent (.agentMetadata) when unset
    public mutating func apply(metaFile url: URL) throws                                          // same, source .metaFile
    /// The two-step join's input: every frame's (parent_tool_use_id, the tool_use ids of its blocks). Records which tool-use id was
    /// carried by a frame whose parent is which tool-use id, so a node whose toolUseID appears under a parent tool-use id gets its parent.
    public mutating func observe(parentToolUseID: String?, carryingToolUseIDs: [String])
    public mutating func observe(assistantModel model: String, agentID: String)
    public func isParked(_ id: String) -> Bool        // terminal status with a child still running
}
```

Decisions: the parent link is set by the first source that answers, and a later source does not overwrite an earlier one but is checked: if it disagrees, the node keeps the first answer and a `ReadWarning`-shaped conflict is exposed as `conflicts: [String]` on the tree for the test to assert empty on the corpus. The two-step join: a node's `toolUseID` is the block that spawned it; find the frame that carried that block (`carryingToolUseIDs` contains it) and read its `parentToolUseID`; the node whose `toolUseID` equals that value is the parent. `transcript` is `TranscriptPath.path(of: LogicalStream(configHome:, sessionID:, name: .agent(taskID:)), slug:)`. Status from `task_updated`/`task_notification` through `TaskStatus(wire:)`.

- [ ] **Step 2: Tests**

`AgentRunTreeTests`: `testNestedDepth2FromTaskFramesAndMirrorMetadata` (fold `nested-depth-2`'s system frames and the `agent_metadata` mirror entries in `t` order: two nodes; the depth-2 node's `parent` equals the depth-1 id with `parentSource == .agentMetadata`; the depth-1 node has `parent == nil`, `.none`); `testMetaFileGivesTheSameParent` (fold task frames only, then `apply(metaFile:)` for both sidecars → same parent, `.metaFile`); `testTwoStepJoinGivesTheSameParentWhenBothAreWithheld` (fold task frames and `observe` every `assistant`/`user` frame's `parent_tool_use_id` and block ids → same parent, `.twoStepJoin`); `testAllThreeSourcesAgreeAndConflictsAreEmpty`; `testARepeatedTaskStartedIsTheSameNode`; `testAShellCreatesNoNode` (`background-shell`: zero nodes); `testModelComesFromTheRunsOwnFrames` (`explore-depth-1`: `observe(assistantModel:)` from the forwarded frames' `message.model` gives the node a model; before it, nil); `testTranscriptPathIsConstructedAtSpawn` (equals the fixture's agent file path under the recorded config home and the fixture's slug).

Run: `swift test --package-path FleetKit --filter AgentRunTreeTests 2>&1 | grep -E "Executed|failed"` → `Executed 8 tests, with 0 failures`.
Demonstrate red: make `apply(agentMetadata:)` ignore `parentAgentId` → the first test fails with `parent == nil`; make the join read `parentToolUseID` of the spawning frame instead of the carrying frame → the third test fails.

```bash
git add FleetKit/Sources/FleetTimeline/Agents FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: the agent-run tree with the metadata, sidecar and two-step-join parent sources"
```

---

### Task 8: The wire reducer — durable half, streaming preview, overlay, host signals

**Files:**
- Create: `FleetKit/Sources/FleetTimeline/Reduce/Overlay.swift`
- Create: `FleetKit/Sources/FleetTimeline/Reduce/StreamingPreview.swift`
- Create: `FleetKit/Sources/FleetTimeline/Reduce/WireReducer.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Reduce/WireReducerTests.swift`

**Interfaces:**
- Consumes: Task 4's items and projection values; Task 5's merge and tool-join rules (shared through internal helpers in `RecordReducer` — extract `ItemBuilder` into `Reduce/ItemBuilder.swift` if the two reducers would otherwise duplicate the block-to-item logic; the file is internal); Task 6's `RegistryMirror`; Task 7's `AgentRunTree`; from `ClaudeWire`: `WireEvent`, `Frame`, `SystemFrame`, `InboundRequest`, `StreamEventFrame`, `ToolUseSummaryFrame`, `ResultFrame`, `CommandLifecycleFrame`, `RequestID`, `ProcessEpoch`.
- Produces: `WireReducer` (`init(stream:configHome:slug:)`, `apply(_: WireEvent) -> [TimelineChange]`, `apply(_: HostSignal) -> [TimelineChange]`, `durable`, `overlay`, `preview`, `registry`, `agents`), `HostSignal`, `Overlay` (`decisions: [RequestID: DecisionItem]`, `clusters: [ItemID: ToolClusterItem]`, `turns: [TurnSummaryItem]`, `notifications: [NotificationItem]`, `hooks: [String: HookRunItem]`, `banners: [Banner]`, `queue: QueueState`, `stale: Bool`), `StreamingPreview`, `Banner`, `DecisionOutcome`.

- [ ] **Step 1: Host signals and overlay values**

```swift
public enum HostSignal: Sendable, Hashable {
    case promptSent(uuid: String, at: Date)
    case decisionAnswered(RequestID, outcome: DecisionOutcome)
    case rewound(toUUID: String)
    case processReplaced(ProcessEpoch)
}
public enum DecisionOutcome: Sendable, Hashable, Codable { case allowed, denied(message: String?), answered(summary: String), cancelled }
public struct Banner: Sendable, Hashable, Codable { public enum Kind: String, Sendable, Codable { case rateLimit, auth, apiRetry, modelFallback, compatibility, mirrorFileOnly }
    public var kind: Kind; public var text: String; public var epoch: ProcessEpoch; public var at: Date }
public struct QueueState: Sendable, Hashable, Codable { public var queued: [String]; public var started: [String]; public var lastState: String? }
public struct Overlay: Sendable, Hashable { … as in Interfaces …; public static let empty: Overlay; public var items: [TimelineItem] { get } }
```

`StreamingPreview`: `messageID: String?`, `blocks: [PreviewBlock]` where a block accumulates `text_delta`, `thinking_delta` or `input_json_delta` by `index` from `content_block_start` through `content_block_stop`; `signature_delta` is ignored; `message_delta` carries `stop_reason`; `message_stop` marks complete. `apply(event: JSONValue)` returns whether anything visible changed.

- [ ] **Step 2: The reducer**

```swift
public struct WireReducer: Sendable {
    public init(stream: LogicalStream, slug: String)
    public private(set) var durable: DurableProjection
    public private(set) var overlay: Overlay
    public private(set) var preview: StreamingPreview?
    public private(set) var registry: RegistryMirror
    public private(set) var agents: AgentRunTree
    public private(set) var outstandingPrompts: [String]        // uuids from promptSent not yet closed by a result
    public mutating func apply(_ event: WireEvent, at now: Date = Date()) -> [TimelineChange]
    public mutating func apply(_ signal: HostSignal, at now: Date = Date()) -> [TimelineChange]
}
```

Routing, by `WireEvent` case:
- `.handshakeCompleted`, `.sessionIdentityResolved`, `.stderr`: no change (stderr is C4's).
- `.frame(frame, epoch)`:
  - `.assistant(f)`: forwarded frames (`parentToolUseID != nil`) are attributed to the agent stream `.agent(taskID:)` resolved through the tree (`agents.node(withToolUse: parentToolUseID)`), else to the main stream; the item is built by the same block rules as Task 5 (merge by `message.id`, tool calls opened, `supersedes` applied, `mcp__afleet__send_user_file` → `SentFileItem`); `preview` for that `message.id` is dropped; `agents.observe(assistantModel:agentID:)` when forwarded; `agents.observe(parentToolUseID:carryingToolUseIDs:)` always.
  - `.user(f)`: `isSynthetic == true` → hidden (a `RecordKey` in `durable.hidden`); tool-result content → completes calls; otherwise `UserMessageItem` (`isReplay` from the frame) or `PeerMessageItem` by `origin.kind`; `agents.observe(…)` for the join.
  - `.streamEvent(f)`: `preview.apply(f.event)`; `.previewChanged`.
  - `.result(f)`: `TurnSummaryItem` with `attribution`: `.relocation` when `numTurns == 0`; `.prompted(uuid)` popping the oldest `outstandingPrompts` when non-empty; else `.unprompted`. Appended to `overlay.turns`.
  - `.system(.initialize)`: turn boundary only (no item). `.system(.taskStarted/.taskUpdated/.taskProgress/.taskNotification/.backgroundTasksChanged)`: `registry.apply`, `agents.apply`; a `task_notification` synthesises a `TaskRunItem(synthesised: true, provenance.origin: .synthesised)` into `durable.items` for a non-agent task and updates the existing agent `TaskRunItem` for an agent. `.system(.hookStarted/.hookProgress/.hookResponse)`: `overlay.hooks[hookID]`. `.system(.notification)`: `overlay.notifications`. `.system(.permissionDenied)`: marks the tool call `.denied` with `denialKind`. `.system(.compactBoundary)`: `CompactBoundaryItem` into `durable` (the wire side of the same record; compared file-to-file only per the constant, so it never enters check two). `.system(.status/.apiRetry/.modelRefusalFallback/.modelRefusalNoFallback/.modelConsentFallback)`: banners. `.system(.mirrorError)`: `Banner(.mirrorFileOnly)` — the ingestion switch itself is Task 10's. `.system(.localCommandOutput)`: `NotificationItem(key: "local_command_output", fileOnly: false)`. `.system(.sessionStateChanged)`: `overlay.sessionState`. `.system(.opaque)` and every other subtype: `OpaqueItem`.
  - `.toolUseSummary(f)`: `overlay.clusters[<id of the first preceding call>]` labelled.
  - `.commandLifecycle(f)`: `overlay.queue` by `state`.
  - `.rateLimitEvent`, `.authStatus`: banners. `.promptSuggestion`, `.conversationReset`, `.keepAlive`, `.controlResponse`, `.controlCancelRequest`, `.controlRequest`: no item (`conversation_reset` clears `durable` to empty and records `session.leaf = nil`). `.transcriptMirror`: **ignored here** (Task 10's). `.opaque`: `OpaqueItem`.
- `.request(r)`: `DecisionItem(state: .pending)` keyed by `r.id` with `kind` by payload case (`canUseTool` → `.permission`, or `.question` when `toolName == "AskUserQuestion"`, `.plan` when `"ExitPlanMode"`; `requestUserDialog` → `.dialog`; `elicitation` → `.elicitation`; `unknown`/`malformed` → no decision, an `OpaqueItem`), `agentID` from the payload, `toolUseID` likewise.
- `.requestCancelled(id, _)`: state `.cancelled`. `.policyAnswered(r, error)`: `.policyAnswered(error:)`. `.unansweredDialog(r)`: `.inert`.
- `.hostToolInvoked(inv, _)`: marks the matching `SentFileItem.delivered = true` when its tool-use id is known, else queues by name for the next `SentFileItem`.
- `.exited`: `overlay.stale = true`, `preview = nil`, every `.pending` decision → `.inert`, running registry entries keep their state (C4 decides).
- `HostSignal.promptSent`: push the uuid. `.decisionAnswered`: `.answered(outcome:)`. `.rewound(toUUID:)`: drop every durable item after the item whose record uuid equals `toUUID`, drop preview, mark `session.leaf`. `.processReplaced`: `overlay = .empty` with `stale = false`, `preview = nil`, prompts cleared; `durable` untouched.

Timestamps: from the frame's `timestamp` when present, else `now`.

- [ ] **Step 3: Tests**

`WireReducerTests`, folding each fixture's frames as `WireEvent.frame(frame, .first)` in `t` order (in-direction `user` frames become `HostSignal.promptSent(uuid:)` first, since that is what the host did): `testStreamingPreviewAssemblesAndCollapses` (`plain-two-turn`: after the deltas of the first message the preview has the text; after the `assistant` frames it is nil and the item's text equals the preview's); `testResultAttributionOnRelocationAndNestedAgents` (`session-mirror-relocation`: five turns, attributions `[prompted, prompted, relocation, prompted, prompted]`; `nested-depth-2`: `[prompted, unprompted, unprompted]`); `testDecisionLifecycle` (`permission-allow`: the `can_use_tool` request → `.pending`; `HostSignal.decisionAnswered(.allowed)` → `.answered`; `permission-deny` with `.policyAnswered` event → `.policyAnswered`); `testToolUseSummaryLabelsTheCluster`; `testForwardedFramesLandOnTheAgentStream` (`explore-depth-1`: items with `provenance.agentID` equal to the task id exist and none of them is on the main stream's id); `testTaskNotificationSynthesisesACompletionItem` (`background-shell`: one `taskRun` with `synthesised == true` after the notification, none before); `testSyntheticUsersAreHidden_mutation` (set `isSynthetic: true` on a user frame in memory → hidden, no item; unwitnessed on the wire and named so); `testRewoundTruncatesTheDurableHalf_mutation`; `testProcessReplacedResetsOverlayNotProjection`; `testCommandLifecycleDrivesQueueState` (from `control-shapes` or any fixture that carries the frames; if none does, a constructed frame with the schema's five states and the test says so).

Run: `swift test --package-path FleetKit --filter WireReducerTests 2>&1 | grep -E "Executed|failed"` → `Executed 10 tests, with 0 failures`.
Demonstrate red: attribute every result `.prompted` when any prompt was ever sent (drop the pop) → the relocation attribution test fails at index 2. Route forwarded frames to the main stream → the agent-stream test fails.

```bash
git add FleetKit/Sources/FleetTimeline/Reduce FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: the wire reducer — durable half, streaming preview, overlay and host signals"
```

---

### Task 9: Check two of the invariant — projection equality and the overlay assertions

**Files:**
- Create: `FleetKit/Tests/FleetTimelineTests/Invariant/ProjectionEqualityTests.swift`

**Interfaces:**
- Consumes: Task 3's `FixtureCorpus`, `Breaks`, `IdentityMask.differingPaths`; Task 5's `RecordReducer`; Task 8's `WireReducer`; Task 4's `ProjectionCategories`.
- Produces: `ProjectionComparison.compare(wire:file:) -> [Difference]` (test-side), reused by Task 10's G4 test.

- [ ] **Step 1: The comparison**

```swift
struct Difference: CustomStringConvertible { let itemID: ItemID; let category: TimelineCategory; let field: String; var description: String { "\(category) \(itemID.stream.name.label)/\(itemID.key) at \(field)" } }
enum ProjectionComparison {
    /// Both projections filtered to `comparedWireToFile`, keyed by `ItemID`; subagent task runs keyed by agent id. Missing on either
    /// side is a difference at field "<presence>"; then each pair compares on `comparedItemFields`; timestamps within one second
    /// when both present. Returns the differences; the caller asserts empty and prints them.
    static func compare(wire: DurableProjection, file: DurableProjection) -> [Difference]
    static func itemsCompared(_ p: DurableProjection) -> Int
}
```

- [ ] **Step 2: The test**

```swift
final class ProjectionEqualityTests: XCTestCase {
    /// Synthetic fixtures are run and their outcome pinned by name: recorded fixtures are asserted equal.
    /// Fill this set from the first run against the two dialogs and never loosen it without a Decision Log entry.
    private static let expectedSyntheticFindings: Set<String> = [ /* "<fixture> <category> <stream>/<key> at <field>" … */ ]

    func testWireAndRecordProjectionsAgreeOnEveryFixture() throws {
        var findings: Set<String> = []; var comparedPerFixture: [String: Int] = [:]
        for fx in try FixtureCorpus.all() {
            let frames = try fx.frames()
            guard frames.contains(where: { if case .assistant = $0.frame { return true }; return false }) else { continue }   // zero-cost, resume-no-replay compare nothing and are counted below
            var wire = WireReducer(stream: LogicalStream(configHome: FixtureCorpus.recordedConfigHome, sessionID: fx.sessionID, name: .main), slug: "_slug_")
            for f in frames {
                if f.direction == "in", case .user(let u) = f.frame, let uuid = u.uuid { _ = wire.apply(.promptSent(uuid: uuid, at: Date(timeIntervalSince1970: Double(f.t) / 1000))) ; continue }
                if f.direction == "in" { continue }
                _ = wire.apply(.frame(f.frame, .first), at: Date(timeIntervalSince1970: Double(f.t) / 1000))
            }
            var streams: [StreamProjection] = []
            for (stream, _, url) in try fx.transcriptFiles() {
                streams.append(RecordReducer.reduce(try TranscriptReader(url: url).readAll().records, stream: stream, sourceFile: url))
            }
            let file = RecordReducer.merge(streams, main: LogicalStream(configHome: FixtureCorpus.recordedConfigHome, sessionID: fx.sessionID, name: .main))
            let diffs = ProjectionComparison.compare(wire: wire.durable, file: file)
            comparedPerFixture[fx.name] = ProjectionComparison.itemsCompared(file)
            if fx.synthetic { for d in diffs { findings.insert("\(fx.name) \(d)") } }
            else { XCTAssertTrue(diffs.isEmpty, "\(fx.name): \(diffs.prefix(5).map(\.description))") }
        }
        XCTAssertEqual(findings, Self.expectedSyntheticFindings)
        // What was found: per fixture, the compared item count equals an independent walk of the file's records
        // (assistant message.ids + non-tool-result non-meta users + tool_use blocks + send_user_file calls + agent runs).
        for fx in try FixtureCorpus.all() where comparedPerFixture[fx.name] != nil {
            XCTAssertEqual(comparedPerFixture[fx.name], try IndependentCount.comparedItems(fx), "\(fx.name): the comparison did not see every item")
        }
        XCTAssertEqual(Set(comparedPerFixture.keys), Set(FixtureCorpus.mirrored).union(["dialog-fable-overage", "dialog-refusal-fallback"]).subtracting(["resume-no-replay"]))
    }

    func testOverlayRendersDecisionsClustersAndTurnCostFromWireFramesAlone() throws {
        // permission-allow, permission-deny, ask-user-question, exit-plan-mode, dialog-*: every can_use_tool / request_user_dialog /
        // elicitation request id has a DecisionItem; every tool_use_summary labelled a cluster whose ids equal preceding_tool_use_ids;
        // every result frame has a TurnSummaryItem with its duration_ms and total_cost_usd (synthetic results lack them → pinned findings).
    }
}
```

`IndependentCount.comparedItems(fx)` walks the raw records with `JSONValue` only (no reducer) so the floor is independent of the code under test.

- [ ] **Step 3: Demonstrate red, three ways, then commit**

1. Change one `tool_result` block's `tool_use_id` in memory (wire side) on `background-shell` → a `<presence>` difference for the tool call.
2. Edit one `text` block on the file side of `plain-two-turn` → a difference at `contentBlocks.text`.
3. Make `WireReducer` skip forwarded `assistant` frames → `explore-depth-1` and `nested-depth-2` fail on agent-stream items.
Also confirm the fourth: remove `.taskRun` from `comparedWireToFile` → the independent count no longer matches, proving the floor is bound to the constant.

Run: `swift test --package-path FleetKit --filter ProjectionEqualityTests 2>&1 | grep -E "Executed|failed"` → `Executed 2 tests, with 0 failures`.

```bash
git add FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: the invariant's second check — wire and record projections agree item for item; overlay from wire frames alone"
```

---

### Task 10: Diagnostics notices and `StreamIngestion` — source arbitration, relocation, mirror errors

**Files:**
- Create: `FleetKit/Sources/FleetTimeline/Diagnostics/TimelineNotice.swift`
- Create: `FleetKit/Sources/FleetTimeline/Ingest/StreamIngestion.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Ingest/IngestionTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 2, 5; Task 9's `ProjectionComparison`; from `ClaudeWire`: `TranscriptMirrorFrame`, `MirrorError`, `ProcessEpoch`.
- Produces: `TimelineNotice`, `TimelineDiagnosticsSink`, `NullTimelineDiagnostics`, `RecordingTimelineDiagnostics` (a lock-guarded test double, `@unchecked Sendable` documented), `StreamIngestion` (`Mode`, `State`, `open(mainPath:policy:)`, `apply(mirror:epoch:)`, `fileChanged(_:)`, `mirrorError(_:epoch:)`, `relocated(mainPath:)`, `processExited(_:)`, `projection`, `state`, `offsets`), `IngestionEffect`.

- [ ] **Step 1: Notices**

Exactly the spec's enum, plus the sink protocol, `NullTimelineDiagnostics`, and `RecordingTimelineDiagnostics` (`final class`, an `NSLock` around `notices: [TimelineNotice]`; the doc comment names the lock as the serialising mechanism). No case carries a path, a `LogicalStream`, a title or a record.

- [ ] **Step 2: The actor**

```swift
public actor StreamIngestion {
    public enum Mode: Sendable { case filePrimary, mirrorPrimary }
    public enum State: Sendable, Hashable { case both, fileOnly(since: ProcessEpoch), mirrorOnly }
    public struct Effect: Sendable { public var applied: [RecordKey]; public var duplicates: Int; public var routedElsewhere: Int; public var changes: [TimelineChange]; public var stateChange: State? }
    public init(session: SessionID, configHome: URL, mode: Mode, diagnostics: any TimelineDiagnosticsSink = NullTimelineDiagnostics(), mirrorGapWindow: Duration = .seconds(2))
    public func open(mainPath: URL, policy: WindowPolicy = .init()) async throws -> DurableProjection
    public func apply(mirror frame: TranscriptMirrorFrame, epoch: ProcessEpoch, at now: Date = Date()) -> Effect
    public func fileChanged(_ path: URL, at now: Date = Date()) async -> Effect
    public func mirrorError(_ error: MirrorError, epoch: ProcessEpoch) -> Effect
    public func relocated(mainPath: URL) async
    public func processExited(_ epoch: ProcessEpoch) async -> Effect
    public var projection: DurableProjection { get }
    public var state: State { get }
    public var offsets: [LogicalStream: Int] { get }
}
```

Internal state: `records: [LogicalStream: [TranscriptRecord]]` in application order, `applied: [LogicalStream: Set<RecordKey>]`, `paths: [LogicalStream: URL]`, `offsets`, `pendingFromFile: [LogicalStream: [(RecordKey, Date)]]` (file records seen by the watcher that no mirror delivered yet), `metadata: [LogicalStream: AgentMetadataRecord]`. The projection is recomputed by `RecordReducer.reduce` per stream and `merge` after every effect (the reducers are pure and the corpus is small; incremental reduction is a later optimisation and is *not* planned here). The arbitration table from the spec is the implementation, row by row:

- `open`: read the main file (`readWindow(policy:)`), apply, set `offsets[main] = length`; discover `<sessionId>/subagents/agent-*.jsonl` beside it and open each whole; read every `.meta.json` into `metadata`.
- `apply(mirror:)`: resolve `filePath` under `configHome`; a different session → `routedElsewhere += 1` and `TimelineNotice.mirrorRoutedElsewhere`; state `fileOnly` for this epoch → ignore; `agentMetadata` entries → `metadata[stream]`; each other entry: key already applied → `duplicates += 1`; else append and apply; a stream with no open file → create it with offset 0 (lazy agent stream). Under `mirrorPrimary` the mirror is applied first and the watcher's read confirms; under `filePrimary` the same code runs — the mode only decides which delivery the *renderer* waits for, which is a C6 concern, and here it decides whether a mirror gap counts as a fault (only under `mirrorPrimary`).
- `fileChanged`: resolve; `readAppended(from: offsets[stream])`; each record: applied → skip; else apply and, under `mirrorPrimary`, remember it in `pendingFromFile`; a pending entry older than `mirrorGapWindow` that the mirror still has not delivered → switch to `.fileOnly(since:)` with `TimelineNotice.mirrorGap(missing:)`.
- `mirrorError`: `.fileOnly(since: epoch)` + `TimelineNotice.mirrorErrorSwitchedToFileOnly`; idempotent within the epoch.
- `relocated(mainPath:)`: rebind `paths[main]` and every agent stream's path under the new slug; offsets unchanged; `TimelineNotice.relocationFollowed`.
- `processExited`: for every stream, `readAppended(from:)` and apply what is missing; a `.both` state stays; a `fileOnly` state persists until `processReplaced` (the caller constructs a new epoch; the actor resets `state = .both` when it sees an epoch greater than `since`).

- [ ] **Step 3: Tests**

`IngestionTests`:
- `testRelocationReplaysWithNoDuplicateAndNoMissingRecord` (G3): with a `TempTree` holding `session-mirror-relocation`'s final file under the sibling slug, `open` on the *original* path fails (no file) — so instead: open with the file at the original slug (copy it there), then feed the mirror frames in order, calling `relocated(mainPath:)` when the first mirror frame with the new path arrives (the moment `set_cwd` answered, in the real flow), then move the file in the tree and call `fileChanged` on the new path; assert `records[main]` keys equal the file's key sequence exactly and `duplicates` equals the number of mirrored entries (every one already applied by the file read? no — the file was copied *complete*; so use the fixture's own timeline: start from an *empty* file at the original path, feed mirror frames, and at the end assert equality with the final file; then run again with the file complete first and assert `duplicates == mirrored count`). Both orders are asserted.
- `testResumeCarriesTheOffsetAndTheFileClosesTheUnmirroredRecord` (G3): `session-mirror-resume`: place `initial/` content at the path, `open` (offset = the `streams.json` value), feed the mirror frames (eight records), assert one record is still missing versus `transcript/`, call `fileChanged` after copying the final file over → the `atis-latch` is applied from the file, `duplicates == 8`, final keys equal the file's.
- `testMirrorAloneDrivesTheReducer` (G4): for every fixture in `FixtureCorpus.mirrored` except `session-mirror-resume` and `resume-no-replay`: open on an empty file, feed mirror frames only, never call `fileChanged`; the projection equals `RecordReducer` over the final files (`ProjectionComparison.compare` empty); for `session-mirror-resume` assert the *inequality* (one record short) so the counter-case is stated.
- `testMirrorErrorSwitchesToFileOnlyForTheEpoch` (G4): feed C2's `system_mirror_error` sample decoded through `FrameDecoder` → `state == .fileOnly(since: .first)`, one notice recorded, later mirror entries for that epoch are ignored (`applied` unchanged), `fileChanged` still applies, and a mirror entry under epoch `.first.next()` is applied again.
- `testMirrorGapUnderMirrorPrimarySwitchesToFileOnly`: `mirrorPrimary`, a file append delivered by `fileChanged` with no mirror frame, clock advanced past the window → `.fileOnly`, `mirrorGap(missing: 1)`.
- `testARoutedElsewhereMirrorIsCountedNotApplied`: a mirror frame whose `filePath` names another session id.
- `testLazyAgentStreamsOpenFromTheMirror`: `nested-depth-2` mirror-only → three streams present, two agent `metadata` entries set.
- `testProcessExitedReconcilesFromTheFile`: drop the last two mirror frames of `plain-two-turn`, call `processExited(.first)` with the complete file in place → applied, keys equal.
- `testNoticesCarryNoPathsOrPayload`: encode every recorded notice's fields; assert no value contains `/` or a record uuid other than the session id — a shape check.

Run: `swift test --package-path FleetKit --filter IngestionTests 2>&1 | grep -E "Executed|failed"` → `Executed 9 tests, with 0 failures`.
Demonstrate red: key `applied` by path instead of stream → the relocation test double-applies after the rebind; skip the epoch check in `mirrorError` handling → the epoch test fails on the next-epoch entry.

```bash
git add FleetKit/Sources/FleetTimeline/Diagnostics FleetKit/Sources/FleetTimeline/Ingest FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: typed notices and the stream ingestion — one idempotent path for file and mirror, relocation and mirror errors"
```

---

### Task 11: `ChannelTimeline` and the recent-URL query (X4 and X7 as amended)

**Files:**
- Create: `FleetKit/Sources/FleetTimeline/Model/ChannelTimeline.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Model/ChannelTimelineQueryTests.swift`

**Interfaces:**
- Consumes: Task 4's items; Task 8's `Overlay`, `StreamingPreview`.
- Produces: `ChannelTimeline` (`durable`, `overlay`, `preview`, `items`, `recentURLs(limit:)`), `SeenURL`, `URLSources.contributing`, `URLSourceKind`, `URLScanner.urls(in:)`. C7's Browser leaf calls `recentURLs`; C6 holds a `ChannelTimeline`.

- [ ] **Step 1: The read model and the scanner**

Exactly the spec's block for `ChannelTimeline`, `SeenURL`, `URLSources`, `URLSourceKind`, plus:

```swift
public enum URLScanner {
    /// `http://` or `https://` then characters up to whitespace or one of `"'<>` `)` `]`; trailing `.,;:!?` trimmed; parsed with
    /// `URL(string:)`, failures dropped. Order of appearance preserved; duplicates within one text preserved (the caller de-duplicates).
    public static func urls(in text: String) -> [URL]
}
```

`ChannelTimeline.items`: `durable.items` with the overlay's items (`overlay.items`: decisions, clusters, turns, notifications, hooks) merged by timestamp, stable for ties (durable first), preview excluded. `recentURLs(limit:)`: walk `items` in order; for each item whose kind is in `URLSources.contributing` (tool-call result text, assistant text blocks, `NotificationItem` with `key == "local_command_output"` or a file-only `local_command`), scan; first sighting records `firstSeen`/`firstSeenAt`, every sighting updates `lastSeen`/`lastSeenAt`; sort by `lastSeenAt` descending with item order as the tiebreak; take `limit`.

- [ ] **Step 2: Tests**

`ChannelTimelineQueryTests`: `testSyntheticDialogAssistantTextYieldsItsURLs` (`dialog-refusal-fallback` through `WireReducer` → `recentURLs(limit: 10)` contains exactly the URL set the test computes independently with a regex over the frames' assistant text; named as the synthetic shape it is); `testToolResultAndLocalCommandOutputContribute` (constructed `ToolCallItem` and `NotificationItem` values — our own types, not recordings — with URLs; both found); `testUserMessagesAndThinkingDoNotContribute`; `testDeDuplicationAndMostRecentFirst` (the same URL in two items → one `SeenURL`, `firstSeen` the earlier, order by the later); `testLimit`; `testScannerTrimsTrailingPunctuationAndClosingBrackets` (`(https://example.test/a).` → `https://example.test/a`); `testItemsMergeOverlayByTimestamp`.

Run: `swift test --package-path FleetKit --filter ChannelTimelineQueryTests 2>&1 | grep -E "Executed|failed"` → `Executed 7 tests, with 0 failures`.
Demonstrate red: add `.userMessage` to the contributing set → `testUserMessagesAndThinkingDoNotContribute` fails.

```bash
git add FleetKit/Sources/FleetTimeline/Model FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: ChannelTimeline and the recent-URL query over the rendered items"
```

---

### Task 12: The transcript index — discovery, head-and-tail entries, titles, incremental update, storage seam, watcher

**Files:**
- Create: `FleetKit/Sources/FleetTimeline/Index/IndexEntry.swift`
- Create: `FleetKit/Sources/FleetTimeline/Index/IndexStorage.swift`
- Create: `FleetKit/Sources/FleetTimeline/Index/TitlePrecedence.swift`
- Create: `FleetKit/Sources/FleetTimeline/Index/TranscriptIndex.swift`
- Create: `FleetKit/Sources/FleetTimeline/Index/TranscriptWatcher.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Index/TranscriptIndexTests.swift`

**Interfaces:**
- Consumes: Task 1's `TranscriptPath`, `SessionID`; Task 2's `HeadTailReader`, `HeadTailReading`; Task 1's `SessionStateVocabulary`; `AfleetCore.ConfigHome`.
- Produces: `IndexEntry`, `TitleSource`, `IndexSnapshot`, `IndexDelta`, `IndexStorage`, `InMemoryIndexStorage`, `TitlePrecedence.title(for:)`, `TranscriptIndex` (`build()`, `update(changed:)`, `entry(_:)`, `snapshot`), `TranscriptWatching`, `TranscriptWatcher`. C4 implements `IndexStorage` (spec Contracts, X6) and reads `IndexEntry`'s flags for its listing policy.

- [ ] **Step 1: Entries, storage, titles**

`IndexEntry`, `IndexSnapshot`, `IndexStorage`, `InMemoryIndexStorage` exactly as the spec's block; `IndexDelta { added: [SessionID]; updated: [SessionID]; removed: [SessionID]; durationMs: Int }`; `IndexSnapshot.schemaVersion = 1`.

```swift
public enum TitleSource: String, Sendable, Codable { case agentName, customTitle, aiTitle, summary, firstPrompt, fallback }
public enum TitlePrecedence {
    /// §35.19.7 (`getLogDisplayTitle`): agentName → customTitle → aiTitle → summary → firstPrompt → "Autonomous session" → sessionId.slice(0,8).
    /// XML-ish blocks (`<…>…</…>`) are stripped from the chosen string; empty after stripping falls through.
    public static func title(agentName: String?, customTitle: String?, aiTitle: String?, summary: String?, firstPrompt: String?, sessionID: SessionID) -> (String, TitleSource)
    public static let autonomousSession = "Autonomous session"
}
```

- [ ] **Step 2: The index actor**

```swift
public actor TranscriptIndex {
    public init(configHome: ConfigHome, storage: any IndexStorage, reader: any HeadTailReading = HeadTailReader(), concurrency: Int = 16, diagnostics: any TimelineDiagnosticsSink = NullTimelineDiagnostics())
    public func build() async throws -> IndexSnapshot
    public func update(changed: [URL]) async -> IndexDelta
    public func entry(_ id: SessionID) -> IndexEntry?
    public var snapshot: IndexSnapshot { get }
    public func loadPersisted() async throws -> IndexSnapshot?      // storage.load(); adopted as the snapshot when its configHome matches
    public func persist() async throws                              // storage.save(snapshot)
}
```

`build()`: list `configHome.root/projects/` (top-level directories only); for each slug list its entries and keep `*.jsonl` files whose stem is a UUID (`TranscriptPath.resolve` agrees) and note `<uuid>/` directories for `hasSubagents` (a directory whose name is a UUID and which contains `subagents/`); never descend otherwise; read each file through the `HeadTailReading` in a `withThrowingTaskGroup` bounded to `concurrency`; produce an `IndexEntry` per file with the field sources: `cwd` = `lastLineString(tail, type: "relocated", key: "relocatedCwd") ?? firstLineString(head, key: "cwd")`; `gitBranch` = `lastString(tail, "gitBranch") ?? firstString(head, "gitBranch")`; `customTitle` = `lastString(tail, "customTitle")`; `aiTitle` = `lastString(tail, "aiTitle")`; `summary` = `lastString(tail, "summary")`; `agentName` = `lastString(tail, "agentName")`; `tag` = last `tag` line's `tag`; `lastPrompt` = `lastLineString(tail, type: "last-prompt", key: "lastPrompt")`; `firstPrompt` = `firstPrompt(head)`; `clearedToEmpty` = the last `last-prompt` line in the tail has `"leafUuid":null` and `"explicit":true`; `entrypoint` = `firstString(head, "entrypoint")`; `sessionKind` = `firstString(head, "sessionKind")`; `isSidechain` = head contains `"isSidechain":true` before any `"isSidechain":false`; `teamName` = `firstString(head, "teamName")`; `continuedIn` = `lastLineString(tail, type: "continued-in", key: "sessionId")` parsed as a session id when it differs from the file's; `createdAt` = `firstString(head, "timestamp")` parsed; `preview` = `lastPrompt ?? summary ?? firstPrompt ?? ""` truncated to 200 characters; `title` from `TitlePrecedence`; `mtime`/`size` from the read; `turnCount` nil. Emit `TimelineNotice.indexBuilt(files:durationMs:)`.

`update(changed:)`: for each URL resolving to `.mainTranscript`, `stat`; missing → removed; stamp unchanged (`mtime` and `size` equal the entry's) → skipped; otherwise re-read that file alone and replace the entry (added when new). URLs that resolve to agent files or metadata only flip `hasSubagents` on their session. Emit `indexUpdated(changed:durationMs:)`. Discovery of files whose directory was not named is *not* attempted in `update`; the watcher names directories and the app passes the directory's new files.

- [ ] **Step 3: The watcher**

```swift
public protocol TranscriptWatching: Sendable { var changes: AsyncStream<[URL]> { get }; func start() throws; func stop() }
/// FSEvents over `<configHome>/projects` (kFSEventStreamCreateFlagFileEvents | NoDefer, latency 0.1 s), callback on a private serial
/// queue that is the one serialising mechanism for its mutable state (`@unchecked Sendable`, documented). Paths are coalesced per
/// callback batch and delivered as one array; a directory event delivers the directory URL.
public final class TranscriptWatcher: TranscriptWatching, @unchecked Sendable { public init(configHome: URL) }
```

No test drives FSEvents; `TranscriptWatcherTests` are not written. A smoke check in Task 13 starts and stops it against a temporary tree and confirms one event arrives after a `touch`, behind the same opt-in variable as the local test, because FSEvents latency makes it a timing test.

- [ ] **Step 4: Tests (default suite)**

`TranscriptIndexTests` over a `TempTree` assembled from every fixture's `transcript/` (each fixture under its own slug named after the fixture, agent sidecars included, plus a `memory/MEMORY.md` under one slug and a stray `notes.txt` under another): `testOneEntryPerSessionFileAndNothingElse` (entry ids equal the set of main-file session ids in the corpus, seventeen; the memory dir, the text file, the agent files and `.meta.json` produce no entry; `hasSubagents` true for exactly `explore-depth-1` and `nested-depth-2`'s sessions); `testTitlePrecedenceOnTheCorpus` (for each entry, the title equals the test's own precedence walk over a full parse of the file — an independent computation — and `titleSource` names the winning source; at least one entry wins by `aiTitle` and at least one by `firstPrompt`, asserted as a set of sources seen); `testRelocatedCwdOverridesTheRecordedOne` (the relocation session's `cwd` equals the `relocatedCwd` of its last `relocated` record, not the head's `cwd`); `testUpdateReReadsOnlyChangedFiles` (a counting `HeadTailReading` wrapper: after `build`, `touch` one file and `update(changed:)` with three URLs → reads == 1, `updated == [that id]`; remove a file → `removed`; add a copied file under a new UUID name → `added`); `testClearedToEmptyIsReadFromTheTail_mutation` (append a cleared `last-prompt` line to a copy); `testSnapshotRoundTripsThroughStorage` (`InMemoryIndexStorage`: `persist` then a new index's `loadPersisted` equals); `testNoDropRuleIsApplied` (an entry whose head says `"entrypoint":"sdk-cli"` — every fixture, since the harness is sdk-cli — is present with `entrypoint == "sdk-cli"`).

Run: `swift test --package-path FleetKit --filter TranscriptIndexTests 2>&1 | grep -E "Executed|failed"` → `Executed 7 tests, with 0 failures`.
Demonstrate red: make `update` re-read every named file regardless of stamps → `testUpdateReReadsOnlyChangedFiles` fails at reads == 3; make `cwd` ignore `relocated` → the relocation test fails.

```bash
git add FleetKit/Sources/FleetTimeline/Index FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: the transcript index — head-and-tail entries, title precedence, incremental update, the storage seam and the watcher"
```

---

### Task 13: The opt-in local measurement, the import-graph test, and final verification against the spec's acceptance

**Files:**
- Create: `FleetKit/Tests/FleetTimelineTests/Index/LocalHomeIndexTests.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/ImportGraphTests.swift`
- Modify: `docs/doperpowers/specs/2026-09-05-c3-fleetkit-timeline.md` (Revision Notes only)

- [ ] **Step 1: The opt-in measurement (G2, S4)**

`LocalHomeIndexTests`: every test begins `guard ProcessInfo.processInfo.environment["AFLEET_LOCAL_INDEX"] == "1" else { throw XCTSkip("set AFLEET_LOCAL_INDEX=1 to measure the local config home; read-only") }`. The config home is `CLAUDE_CONFIG_DIR` from the environment when set, else `~/.claude`; it is opened read-only and nothing under it is created, touched or removed — the incremental-update measurement `touch`es a *copy* of one file placed under the temporary directory and passes that URL through a second index built over a temporary tree that holds only that copy, because touching the real home is forbidden.
- `testColdBuildUnderHalfASecond`: five builds with `InMemoryIndexStorage`, each on a fresh actor; print `files=<n> median_ms=<m> min_ms=<a> max_ms=<b>`; assert median < 500.
- `testIncrementalUpdateUnderFiftyMilliseconds`: on the temporary copy tree, one `touch`, `update(changed:)`; print and assert < 50 ms.
- `testLargestTranscriptHistoryUnderOneSecond`: pick the entry with the largest `size`; `TranscriptReader(url:).readWindow()` then `RecordReducer.reduce` on it; print `size=<bytes> records=<n> window=<earlierAvailable> ms=<t>`; assert < 1000.
- `testWatcherDeliversOneEventForOneTouch`: on the temporary tree, start `TranscriptWatcher`, touch, await one batch containing the file within two seconds, stop.
Output discipline: the four `print`s above are the only output; no path, title or record is printed.

- [ ] **Step 2: The import-graph test (X1)**

`ImportGraphTests.testFleetTimelineImportsOnlyWhatX1Allows`: grep every `.swift` under `FleetKit/Sources/FleetTimeline` for `^import `; the set of modules must be a subset of `["Foundation", "CryptoKit", "AfleetCore", "ClaudeWire", "CoreServices"]`, and `CoreServices` may appear only in `Index/TranscriptWatcher.swift`; also assert `FleetKit/Package.swift` outside the C3 region is byte-identical to `main`'s (`git show main:FleetKit/Package.swift` compared after cutting the region).

- [ ] **Step 3: G1, quoted from the spec — "`DifferentialInvariantTests` runs over every directory under `Fixtures/`… both checks"**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|failed|skipped"`
Expected: `with 0 failures`; skips only in `LocalHomeIndexTests` (four, without the flag). Confirm by name that `MirrorFidelityTests.testMirroredEntriesEqualTheAppendedFileRecordsOnEveryFixture` and `ProjectionEqualityTests` (both tests) ran and passed, and quote their summary lines. Grep for the summary by name (`Executed .* tests`), never by tail position — `swift test` prints two harness summaries.

- [ ] **Step 4: G2, quoted — "the median of five cold builds under 500 ms, an incremental update after one `touch` under 50 ms, and the channel history of the largest local transcript produced in under one second"**

Run: `AFLEET_LOCAL_INDEX=1 swift test --package-path FleetKit --filter LocalHomeIndexTests 2>&1 | grep -E "Executed|failed|files=|size=|median"`
Expected: `Executed 4 tests, with 0 failures` and the four measurement lines. Record the numbers (counts and milliseconds only) in the spec's Revision Notes. If a number misses, the gate fails and the plan stops for the orchestrator; do not widen the budget.

- [ ] **Step 5: G3 and G4, quoted — the three fixtures and the mirror-only and mirror-error cases**

Run: `swift test --package-path FleetKit --filter "IngestionTests|AgentRunTreeTests|RegistryMirrorTests|TaskOutputTailerTests" 2>&1 | grep -E "Executed|failed"`
Expected: `0 failures`, and by name: `testRelocationReplaysWithNoDuplicateAndNoMissingRecord`, `testResumeCarriesTheOffsetAndTheFileClosesTheUnmirroredRecord`, `testNestedDepth2FromTaskFramesAndMirrorMetadata`, `testTwoStepJoinGivesTheSameParentWhenBothAreWithheld`, `testBackgroundShellRowByRow`, `testSnapshotYieldsTheOutputAndTheExitCode`, `testMirrorAloneDrivesTheReducer`, `testMirrorErrorSwitchesToFileOnlyForTheEpoch`.

- [ ] **Step 6: X1 and X9 spot checks**

Run: `swift test --package-path FleetKit --filter ImportGraphTests 2>&1 | grep -E "Executed|failed"; git diff main -- FleetKit/Package.swift | grep -E '^[-+][^-+]' | grep -v 'C3' | head`
Expected: `1 test, with 0 failures`; the manifest diff is empty (v1 adds no target) or confined to the C3 region.
Run: `find ~/.claude -newer FleetKit/Package.swift -maxdepth 1 2>/dev/null | head; find /tmp/afleet-fixtures/config-home -newer FleetKit/Package.swift -maxdepth 1 2>/dev/null | head`
Expected: no output from either.

- [ ] **Step 7: The ledger of demonstrations**

Confirm the plan's ledger holds one quoted red run per gate test named in Tasks 1 through 12 (the "Demonstrate red" steps). A test without a quoted demonstration is not accepted; write the demonstration now, restore, and only then proceed.

- [ ] **Step 8: Record and commit**

Append to the spec's `## Revision Notes`:

```
- <date>: Plan executed. G1 passes (check one over <s> streams and <r> records; check two over <i> items; <n> tests in FleetTimelineTests, <k> skipped without AFLEET_LOCAL_INDEX). G2 measured on the local config home: <files> files, cold median <m> ms, incremental <u> ms, largest transcript <bytes> bytes in <t> ms. G3 and G4 pass by the tests named in the plan's Task 13. Unwitnessed paths tested by mutation: <list>. Parent revisions to file at merge: none beyond the six already filed.
```

```bash
git add docs/doperpowers/specs/2026-09-05-c3-fleetkit-timeline.md FleetKit/Tests/FleetTimelineTests
git commit -m "C3: opt-in local measurement, import-graph test, acceptance results recorded"
```

---

## Questions left for the human

Each was answered with the recommendation below and the plan proceeds on it; overrule before execution if you disagree.

1. **Pinned corpus counts.** Tasks 1 and 3 pin 611 file records, 496 mirrored entries, twelve record kinds, fifteen mirrored fixtures and (to be confirmed at execution) nineteen compared streams. A C1 re-recording moves these; the executor re-pins only after the orchestrator confirms the re-recording, never to make a red run green.
2. **Recomputing the projection on every effect.** `StreamIngestion` re-reduces its streams after each applied batch rather than reducing incrementally. On the corpus and on the local p99 file this is milliseconds; on the 109 MB maximum the bounded window keeps it under the second G2 asks for. Incremental reduction is deliberately not planned; if C6's live rendering needs it, it is a follow-up on C3 with the invariant as its guard.
3. **The orphan-healing constant.** Written as five seconds from parity §35.13; Task 5's executor reads the bundle for the constant and pins it with a line number in the doc comment, and the spec's Delegated unknowns entry is closed in the same commit.
4. **`ItemBuilder` extraction.** Task 8 may extract the shared block-to-item logic from Task 5 into an internal `Reduce/ItemBuilder.swift` so the two reducers cannot drift. Do it if the duplication would exceed a screen; the invariant test is what proves they agree either way.
5. **Ten tests per task is a floor, not a target.** The counts in the "Run" lines are the plan's expectation; an executor who needs one more test to discriminate a rule adds it and reports the new count.

## Revision Notes

- 2026-09-05: v1, written from spec v2 at parent-pin `ee94449`. Thirteen tasks; the record model and reader first, the invariant's first check at Task 3 and its second at Task 9, the index and its opt-in measurement last, as ruled.
