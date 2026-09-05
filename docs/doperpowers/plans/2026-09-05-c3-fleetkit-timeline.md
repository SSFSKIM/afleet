# C3: FleetKit Timeline Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use doperpowers:subagent-driven-execution to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `FleetTimeline`, the pure data half of `FleetKit`: the transcript record model and reader, the record reducer and the wire reducer with their source arbitration, the timeline item model with its named category constants, the agent-run tree, the background-task registry mirror and output tailer, the transcript index with its head-and-tail read, the channel's recent-URL query, and the differential invariant as a test that runs against every fixture C1 recorded.

**Architecture:** One target `FleetTimeline` inside the `FleetKit` package, added only inside the manifest's C3 region, importing `AfleetCore` and `ClaudeWire` and reusing C2's `Lossless`, `JSONValue`, `ContentBlock`, `Message`, `Frame`, `WireEvent` and `ProcessEpoch`. Records and frames decode losslessly; identity is a record key (logical stream plus uuid, or hash plus occurrence ordinal) and paths are aliases; the two reducers are pure value types producing one `DurableProjection` shape, so the invariant is a comparison of two values; three actors hold the long-lived state (`StreamIngestion` per channel, `TranscriptIndex` per config home, `TaskOutputTailer` per file). Nothing spawns a process; nothing writes under a config home; every test drives file inputs and frame streams directly.

**Tech Stack:** Swift 6.3.3, Swift Package Manager (`swift-tools-version: 6.2`, language mode 6, `platforms: [.macOS(.v26)]`), Foundation (`FileHandle`, `Data`, `JSONDecoder`/`JSONEncoder`, `FileManager`, `FSEvents` through `CoreServices` for the watcher only), CryptoKit (`SHA256` for uuid-less record identity), XCTest. No Python, no processes.

**Spec:** `docs/doperpowers/specs/2026-09-05-c3-fleetkit-timeline.md` v2.5 (child of `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C3`, parent-pin `ee94449`; the parent's §7.3 in full, §8.8's tree data model, §5's package edges and §17.5 X1, X3 (consumed), X4 (owned), X6 (the `IndexStorage` seam), X7 as amended 2026-09-05 (the recent-URL query), X8 and X9 bind this work).

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
    Reader/TranscriptReader.swift                      ByteRange, ReadResult, WindowMarker, WindowPolicy; readAll, readAppended(from:), readWindow(policy:), readEarlier(before:), read(at:length:), open rules
    Reader/WindowedTranscript.swift                    the channel-open read: readWindow, then readEarlier until the window is closed; readEarlier(_:held:window:policy:) behind Load earlier
    Reader/HeadTailReader.swift                        the picker's 64 KiB read and its substring helpers
    Reduce/Projection.swift                            StreamProjection, DurableProjection, HiddenRecord, RecordLocator, SessionState, Branch, ReadWarning, TimelineChange
    Reduce/RecordReducer.swift                         tree, leaf, healing, merge rules
    Reduce/Overlay.swift                               Overlay, DecisionState, ClusterLabel, TurnAttribution, Banner
    Reduce/StreamingPreview.swift                      StreamingPreview from stream_event deltas
    Reduce/WireReducer.swift                           WireReducer, HostSignal
    Ingest/StreamIngestion.swift                       the actor, Mode, State, Effect, the tap consumer and its alignment
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
    Support/SyntheticTranscript.swift                  invented linear and rewound transcripts for the window and Load-earlier tests; never an engine byte
    Support/FixtureWireReplay.swift                    what ClaudeProcess would have pushed for a recording, through C2's WireEventPolicy (main at ca68f2e); host signals from the in-direction frames
    Records/RecordModelTests.swift
    Reader/TranscriptReaderTests.swift
    Reader/WindowedTranscriptTests.swift
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

/// One record's identity: its stream plus its `uuid`, or, for a kind that has none, the canonical-JSON hash *and* an occurrence
/// ordinal (parent §7.3; spec "Occurrence identity"). The engine writes byte-identical state records repeatedly and never
/// deduplicates them — 2.1.258 line 429460 `vbr` maps every state kind to "always" — so two equal `atis-latch` lines are two
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
    var continuedInSessionId: String? { additional["continuedInSessionId"]?.stringValue }   // 2.1.258 line 246351: the destination; this record's `sessionId` is the source, never read here
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
/// 429460 (`vbr`: dedup policy). Thirty-eight kinds in all: the five conversation kinds (`Vr` at line 250499) and the
/// thirty-three state kinds below. `dts` folds `progress` as "boundary-cleared", not "transcript" — `conversationKinds` is
/// the reducer's partition, not a `dts` fold class. `vbr` maps every state kind to "always" and only the five conversation
/// kinds to "dedup-transcript": the engine never content-deduplicates a state record, which is why `RecordKey` carries an
/// occurrence ordinal. A kind outside this set decodes as `.unknown` and fails the vocabulary assertion, because a new kind
/// is drift this child exists to notice.
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
        case "agent_metadata": let h = canonicalHash(of: value); return typed(AgentMetadataFields.self) { .agentMetadata($0, canonicalHash: h) }
        default:
            if SessionStateVocabulary.kinds[kind] != nil { let h = canonicalHash(of: value); return typed(SessionStateFields.self) { .sessionState($0, canonicalHash: h) } }
            return .unknown(kind: kind, value)
        }
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
        /// Every JSONL under `initial/` — the file as it stood before a resume recording — resolved the same way; empty without the directory.
        func initialFiles() throws -> [(LogicalStream, TranscriptPath, URL)]
        var hasInitial: Bool { get }
        func metaFiles() throws -> [(LogicalStream, URL)]
        /// Offset for a stream: streams.json keys are `<slug>/<relative path>`; match on the path's suffix; 0 when no key
        /// matches — a mirror that began with the file, as `session-mirror-relocation`'s empty `streams.json` records.
        func offset(for path: URL) -> Int
        func frames() throws -> [RecordedFrame]
    }
    struct RecordedFrame { let index: Int; let t: Int; let direction: String /* the envelope's `dir`: "in" or "out" */; let value: JSONValue; let frame: Frame }

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
    func testKeysUseUUIDForConversationRecordsAndAHashOtherwise() throws { /* a `user` record keys by uuid whatever ordinal it is given; an `ai-title` record's `key(in:ordinal: 3)` is `.hash(contentHash, ordinal: 3)`; two equal ai-title lines share `contentHash`; one differing byte hashes differently — how a sequence assigns ordinals is the multiplicity test's, not this one's */ }
    /// The same object in two key orders — the file's order and the mirror's — is one content hash, for an `ai-title` line and an
    /// `agent_metadata` line written by the test with invented values; and across the corpus every mirrored uuid-less entry
    /// hashes equal to the file line it mirrors (the property check one relies on; the key *sequence* is check one's own assertion).
    func testUUIDLessKeysAreCanonicalAcrossKeyOrderAndDelivery() throws { /* build `{"type":"ai-title","aiTitle":"t","sessionId":"s"}` and its reversed-key twin; `contentHash` equal; same for agent_metadata; then for every fixture, every uuid-less mirror entry's `contentHash` is among the paired file's hashes */ }
    /// The engine keeps repeated state records and so must the key (`vbr`, line 429460). Over every corpus transcript file,
    /// `RecordKey.keys(for:in:)` yields no duplicate key and as many keys as lines; the keys with `ordinal > 0`, counted
    /// independently by grouping the file's uuid-less lines by `contentHash`, number forty-eight across fourteen files in thirty
    /// groups (`atis-latch`, `ai-title`, `relocated`) — the census of 2026-09-05, re-pinned only when C1 re-records.
    func testRepeatedUUIDLessLinesKeepTheirMultiplicity() throws { /* per file: Set(keys).count == keys.count == records.count; sum of (group size − 1) over hash groups == count of keys with ordinal > 0; corpus totals 48 / 14 / 30 */ }
    /// Schema-derived, no fixture carries the kind: a `continued-in` line built from 2.1.258 line 246351's shape with invented ids.
    func testContinuedInReadsTheDestinationSessionId_mutation() throws { /* `{"type":"continued-in","timestamp":"2026-09-05T00:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","continuedInSessionId":"22222222-2222-4222-8222-222222222222"}` → `continuedInSessionId == "22222222-…"`, `fields.sessionId == "11111111-…"`; the same line without `continuedInSessionId` → nil, never the source id */ }
    func testLeafUuidDistinguishesAbsentFromExplicitNull() throws { /* `{"type":"last-prompt","leafUuid":null,"explicit":true}` → .some(nil); without the key → nil */ }
    func testAKnownKindWithABrokenShapeIsUndecodableNotUnknown() throws { /* `{"type":"user"}` (no message) → .undecodable with reason "decode_failure:user" */ }
    func testResolveReadsSessionFromFileNameNotSlug() throws { /* main, agent jsonl, meta.json, a memory/MEMORY.md → nil, a tool-results file → nil, a slug that is not the cwd's */ }
    /// The test's own transcription of `dts` (line 428922), typed out independently of the source file's literal — thirty-three
    /// state kinds with their fold, `progress` noted as "boundary-cleared" and left to `conversationKinds` — compared as an exact
    /// dictionary; and `vbr`'s five "dedup-transcript" kinds (line 429460), which must be exactly `conversationKinds`.
    func testVocabularyMatchesTheBundleTables() { /* let expectedDts: [String: Fold] = [ …33 entries… ]; XCTAssertEqual(SessionStateVocabulary.kinds, expectedDts); XCTAssertEqual(SessionStateVocabulary.kinds.count, 33); XCTAssertEqual(SessionStateVocabulary.conversationKinds, ["user", "assistant", "attachment", "system", "progress"]); XCTAssertEqual(kinds.count + conversationKinds.count, 38); XCTAssertTrue(Set(kinds.keys).isDisjoint(with: conversationKinds)); XCTAssertTrue(isKnown("cost-state")); XCTAssertFalse(isKnown("made-up")) */ }
}
```

Write the bodies in full. The pinned counts 611 and 496 and the twelve-kind set are the spec's Grounding; if the executor's count differs, the spec is wrong and the plan stops for the orchestrator rather than re-pinning.

- [ ] **Step 7: Run, demonstrate, commit**

Run: `swift test --package-path FleetKit --filter RecordModelTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 9 tests, with 0 failures`.
Demonstrate red: in `RecordDecoder.decode`, temporarily route `"ai-title"` to `.unknown`; the round-trip test must fail with `unknown record kind ai-title`. Then hash the raw line bytes instead of the canonical bytes → the reversed-key twin in `testUUIDLessKeysAreCanonicalAcrossKeyOrderAndDelivery` hashes differently. Then make `keys(for:in:)` assign ordinal 0 always → `testRepeatedUUIDLessLinesKeepTheirMultiplicity` finds forty-eight duplicate keys. Then read `sessionId` in the `continuedInSessionId` accessor → the `continued-in` mutation test sees the source id. Restore all four. Quote the failing lines in the ledger.

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
- Create: `FleetKit/Sources/FleetTimeline/Reader/WindowedTranscript.swift`
- Create: `FleetKit/Sources/FleetTimeline/Reader/HeadTailReader.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Support/TempTree.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Support/SyntheticTranscript.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Reader/WindowedTranscriptTests.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Reader/TranscriptReaderTests.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Reader/HeadTailReaderTests.swift`

**Interfaces:**
- Consumes: from Task 1: `TranscriptRecord`, `RecordDecoder.decode(line:byteOffset:)`, `FixtureCorpus`.
- Produces: `TranscriptReader` (`readAll()`, `readAppended(from:)`, `readWindow(policy:)`, `readEarlier(before:)`, `read(at:length:)`, `ByteRange`, `ReadResult` with `ranges` parallel to `records`, `WindowMarker`, `WindowPolicy`, `ReaderError`), `WindowedTranscript.read(_:policy:)` (the channel-open read with the closure rule) and `WindowedTranscript.readEarlier(_:held:window:policy:)` (one step back for *Load earlier*), `LineScanner.lines(in:)`, `HeadTailReader` (`read(_:) -> HeadTail?`, `HeadTail`, the substring helpers `firstString(_:key:)`, `lastString(_:key:)`, `lastLineString(_:type:key:)`, `firstLineString(_:key:)`, `firstPrompt(_:)`), and the test support `TempTree` (a config-home-shaped tree under the temporary directory assembled from fixture snapshots, with `add(_:slug:)`, `write(_:session:slug:)`, `touch`, `appendRaw`, `remove`, `relocate`, `setModificationDate`), and `SyntheticTranscript.linear(turns:paddingBytes:leafTurn:)` and `.rewound(turns:paddingBytes:rewindAfterTurn:thenTurns:)` (invented records, invented uuids, generated text — never an engine byte — for the tests that need a file above the whole-file threshold; `rewound` forks a second branch from an earlier turn and names that branch's leaf in a final `last-prompt`, the shape *Load earlier* must page through).

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

/// Where one record's bytes lie in its file. The reader is stream-less, so this is offset and length only; Task 4's
/// `RecordLocator` is a `ByteRange` plus the stream the ingestion knows.
public struct ByteRange: Sendable, Hashable, Codable {
    public var offset: Int
    public var length: Int
    public init(offset: Int, length: Int) { self.offset = offset; self.length = length }
}
public struct ReadResult: Sendable {
    public var records: [TranscriptRecord]
    public var ranges: [ByteRange]         // parallel to `records`: each record's bytes, for `read(at:length:)`
    public var length: Int                 // the byte length the read covered, i.e. the next `readAppended(from:)` offset
    public var window: WindowMarker?
    public init(records: [TranscriptRecord], ranges: [ByteRange], length: Int, window: WindowMarker? = nil) { self.records = records; self.ranges = ranges; self.length = length; self.window = window }
}
public struct WindowMarker: Sendable, Hashable, Codable {
    public var earlierAvailable: Bool
    public var continueBefore: Int          // byte offset at which `readEarlier(before:)` continues
    public init(earlierAvailable: Bool, continueBefore: Int) { self.earlierAvailable = earlierAvailable; self.continueBefore = continueBefore }
}
public struct WindowPolicy: Sendable, Hashable {
    public var wholeFileUpTo: Int          // above the local p99 (spec Grounding)
    public var initialTail: Int
    public var earlierStep: Int
    /// Declared memberwise with defaults: a declared `init()` suppresses the synthesised memberwise initialiser, and `.whole`
    /// and the tests' policies would not compile. `.init()` still means the defaults.
    public init(wholeFileUpTo: Int = 8 * 1024 * 1024, initialTail: Int = 4 * 1024 * 1024, earlierStep: Int = 4 * 1024 * 1024) { self.wholeFileUpTo = wholeFileUpTo; self.initialTail = initialTail; self.earlierStep = earlierStep }
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
    public func read(at offset: Int, length: Int) throws -> Data                // one record's bytes, for `StreamIngestion.rawRecord(for:)`
    public func byteLength() throws -> Int
}
```

Decisions: `open(2)` with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`, then `fstat` and refuse anything that is not `S_IFREG` (`ReaderError.notARegularFile`; `ELOOP` maps to `.symlinkRefused`); read with `pread` into a `Data` of the requested range; `readWindow` chooses the whole file when `byteLength() <= policy.wholeFileUpTo`, otherwise reads the last `policy.initialTail` bytes, drops everything before the first `\n` (a line start), and returns `WindowMarker(earlierAvailable: true, continueBefore: <offset of that line start>)`; `readEarlier(before:)` reads the `earlierStep` bytes ending at `before`, aligned the same way, with `earlierAvailable: false` when it reached offset 0. `ReadResult` carries `ranges: [ByteRange]` parallel to `records` — the reader is stream-less, and Task 4's `RecordLocator` wraps a range with the stream the ingestion knows. `TranscriptReader` deals in bytes and lines; the *closure* of a window is `WindowedTranscript`'s (Step 3), which is record-aware and is what `StreamIngestion.open` calls. The record decode passes `byteOffset` so `.undecodable` names where.

- [ ] **Step 3: The windowed read and its closure rule**

`FleetKit/Sources/FleetTimeline/Reader/WindowedTranscript.swift`:

```swift
import Foundation

/// The channel-open read for one file: `readWindow`, then `readEarlier` until the window is *closed*, which means both
/// (a) the leaf the file names (`last-prompt.leafUuid`, else the last conversation record) lies inside the window, and
/// (b) the earliest record of the leaf's chain inside the window is a turn start — a `user` record that is neither a tool
/// result nor `isMeta` — or the file's first record. A chain record whose parent lies before a still-open window is a window
/// root, not an orphan; the reducer receives the marker and emits no orphan warning for it. Closure is bounded: every
/// extension is one `earlierStep`, and it stops at offset 0.
public enum WindowedTranscript {
    public struct Result: Sendable { public var records: [TranscriptRecord]; public var ranges: [ByteRange]; public var length: Int; public var window: WindowMarker; public var extensions: Int }
    public static func read(_ reader: TranscriptReader, policy: WindowPolicy = .init()) throws -> Result
    /// *Load earlier* (`StreamIngestion.loadEarlier`, Task 10): one `earlierStep` back from `window.continueBefore`, then the same
    /// closure loop over `held` ∪ new. The result holds only the new records and ranges, in file order, to be prepended, and the
    /// moved marker; `length` is the caller's, unchanged. At `continueBefore == 0` it returns nothing and a closed marker.
    public static func readEarlier(_ reader: TranscriptReader, held: [TranscriptRecord], window: WindowMarker, policy: WindowPolicy = .init()) throws -> Result
    /// The rule alone, over decoded records, testable without a file: nil when closed, else why not.
    static func openReason(_ records: [TranscriptRecord]) -> OpenReason?
    enum OpenReason: Equatable { case leafNotInWindow(String), chainStartsMidTurn(String) }
}
```

Decisions: the loop is `readWindow(policy:)`, then `while window.earlierAvailable, let _ = openReason(records) { readEarlier(before: window.continueBefore); prepend; extensions += 1 }`. `openReason` walks parents from the leaf through the records it has; when the walk leaves the window it looks at the last record it reached — a turn start closes the window, anything else is `.chainStartsMidTurn`; a named leaf it never met is `.leafNotInWindow`. A whole-file read (`earlierAvailable == false`) is closed by definition. That a linear file is *not* read back to its root is deliberate: the leaf path of a never-rewound transcript is the whole file, and reading it whole would make the 4 MiB window a fiction on the 109 MB local maximum; *Load earlier* is `StreamIngestion.loadEarlier()` (Task 10), which continues from `continueBefore` through `readEarlier(_:held:window:policy:)` by the same rule, one step at a time; C6 reads nothing itself. The spec's phrase "until the leaf path is closed" is given this meaning in its v2.2 Revision Note.

- [ ] **Step 4: The head-and-tail reader**

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

- [ ] **Step 5: Temporary trees and synthetic transcripts for tests**

`FleetKit/Tests/FleetTimelineTests/Support/TempTree.swift`: a class that creates `<tmp>/afleet-c3-<uuid>/projects/`, empty, with `add(_ fixture:, slug:) -> URL` (copy the fixture's `transcript/` under `projects/<slug>/`, sidecars included, and return the main file URL — one fixture or the whole corpus), `write(_ data: Data, session: SessionID, slug: String) -> URL` (place an invented file: the synthetic transcripts), `setModificationDate(_:_:)`, `slug(for:)`, `touch(_:)` (append a newline-terminated record copied from the same file's last line with a fresh uuid — a *repeat*, never new content), `appendRaw(_:to:)`, `remove(_:)`, `relocate(session:from:to:)` (move the file and the sidecar directory), `symlink(_:to:)`, and `deinit` removing the tree. The root is `FileManager.default.temporaryDirectory`, never a config home.

`FleetKit/Tests/FleetTimelineTests/Support/SyntheticTranscript.swift`:

```swift
/// Invented transcripts for the tests that need a file above the whole-file threshold. Every uuid is `00000000-0000-4000-8000-`
/// plus a twelve-digit counter, the session id is `33333333-3333-4333-8333-333333333333`, every text is generated ASCII; no
/// engine byte. Records are the shapes Task 1 decodes: a human `user` (`message.role == "user"`, a string `message.content`),
/// an `assistant` (`message.id`, one text block), a `last-prompt` (`lastPrompt`, `leafUuid`), all with `parentUuid`,
/// `isSidechain: false`, `sessionId`, `timestamp` and `type`.
enum SyntheticTranscript {
    struct File {
        let data: Data
        let ranges: [ByteRange]          // one per record, in file order — what the reader must report byte for byte
        let turnStarts: [Int]            // indices into `ranges` of every human `user` record
        let leafUUID: String             // what the final `last-prompt` names
        let leafIndex: Int               // that record's index into `ranges`
    }
    /// `turns` turns, each a human `user` record whose `message.content` is `paddingBytes` bytes long, one uuid-less `atis-latch`
    /// record with fixed invented fields (byte-identical in every turn, so identical canonical hashes straddle every window boundary)
    /// and an `assistant` reply, the `user` and `assistant` records chained by `parentUuid` from the first; the final record is a `last-prompt` whose `leafUuid` is turn `leafTurn`'s `user` uuid.
    static func linear(turns: Int, paddingBytes: Int, leafTurn: Int) -> File
    /// `turns` turns as above, then `thenTurns` more whose first `user` record's `parentUuid` is turn `rewindAfterTurn`'s assistant
    /// — a rewind, the first branch's tail left in the file as the engine leaves it — and a final `last-prompt` whose `leafUuid`
    /// is the second branch's last `user` uuid.
    static func rewound(turns: Int, paddingBytes: Int, rewindAfterTurn: Int, thenTurns: Int) -> File
    /// One turn of a session that queues input, as six lines each ending in `\n`: a human `user` (uuid), two `queue-operation`
    /// records (`operation` `enqueue` then `dequeue`, distinct `timestamp`s, so their hashes differ), a `file-history-snapshot`
    /// (`messageId` = the `user` uuid), an `assistant` (`message.id`) and a `last-prompt` naming the `user` uuid. `turn` seeds the
    /// uuid counter and the timestamps, so turns 1 and 2 never collide; the ingestion's straddle tests (Task 10) write prefixes of
    /// these lines and frame the rest.
    static func queuedTurnLines(turn: Int) -> [Data]
}
```

The two file generators return the `ranges` the reader must report, so a window test computes the extension count it expects from the file it wrote, never from the reader under test.

- [ ] **Step 6: Tests**

`TranscriptReaderTests`: `testReadAllDecodesEveryLineOfEveryCorpusFile` (records per file equal the line count of non-empty lines, asserted per file, and the total equals Task 1's 611 for the transcript files alone); `testATornTailIsHeldBackAndCompletedByTheNextAppend` (copy a file, append half a record without a newline → `readAppended` returns 0 records and does not advance past the partial; append the rest plus `\n` → 1 record, offset at the end); `testASealedTailIsSkipped` (a leading `\n` before a record yields no empty record); `testOneCorruptLineYieldsOneUndecodable` (insert a non-JSON line mid-file → exactly one `.undecodable` with that line's byte offset, every other record intact); `testWindowAlignsToALineStart` (policy with `wholeFileUpTo: 0`, `initialTail: 2000` on `nested-depth-2`'s main file: the first record is complete, `continueBefore` equals its byte offset, `readEarlier` from there returns the preceding records and reaches 0 with `earlierAvailable: false`, and the union equals `readAll`); `testSymlinkAndDirectoryAreRefused`.

`HeadTailReaderTests`: `testReadsHeadAndTailAndStatOfEveryCorpusFile` (size equals the file's byte count; for a file under 64 KiB head equals tail equals the whole file); `testHelpersMatchTheEngineOnTheCorpus` (on `session-mirror-relocation`: `lastLineString(tail, type: "relocated", key: "relocatedCwd")` returns a string and `firstLineString(head, key: "cwd")` returns a different one; on `plain-two-turn`: `firstPrompt(head)` equals the first prompt in `fixture.json`'s `prompts[0]`; `lastString(tail, key: "aiTitle")` is non-nil where an `ai-title` record exists); `testFirstPromptSkipsToolResultsMetaAndCompactSummary` (mutate a copied head in memory: put a `tool_result` user line and an `isMeta` user line before the prompt → still the prompt).

`WindowedTranscriptTests`: `testAWholeFileReadIsClosed` (every corpus main file under the default policy: `extensions == 0`, `earlierAvailable == false`, records equal `readAll`); `testTheWindowExtendsBackToATurnStart` (on `nested-depth-2`'s main file, the test computes from `LineScanner`'s offsets an `initialTail` that cuts exactly at a tool-result `user` record; `read` with `wholeFileUpTo: 0` → the earliest chain record in the result is a human `user` record, `extensions >= 1`, and the records equal the `readAll` suffix from that record on); `testTheWindowExtendsUntilTheNamedLeafIsInside` (`SyntheticTranscript.linear(turns: 40, paddingBytes: 300_000, leafTurn: 10)` — about 12 MiB, above the whole-file threshold — whose last record is a `last-prompt` naming the tenth turn's `user` uuid: the result contains that uuid, its chain start is a turn start, and `extensions` equals the number the generator's offsets predict, asserted exactly); `testClosureStopsAtOffsetZero` (`wholeFileUpTo: 0, initialTail: 1` on `plain-two-turn` → offset 0 reached, `earlierAvailable == false`, records equal `readAll`); `testRangesAddressEveryRecord` (for every corpus file, `read(at:length:)` on each range returns bytes that decode to the same `JSONValue` as the record's line); `testLoadEarlierPrependsUntilClosedAndReachesOffsetZero` (`SyntheticTranscript.rewound(turns: 30, paddingBytes: 300_000, rewindAfterTurn: 12, thenTurns: 10)` — above the whole-file threshold, its `last-prompt` naming the second branch's leaf — read with the default policy, then `readEarlier(_:held:window:policy:)` repeatedly, prepending, until `earlierAvailable == false`: the assembled records equal `readAll`'s, the assembled ranges are distinct and cover every record exactly once, each step's new records end where the previous window began, and the step count equals what the generator's offsets predict).

- [ ] **Step 7: Run, demonstrate, commit**

Run: `swift test --package-path FleetKit --filter "TranscriptReaderTests|HeadTailReaderTests|WindowedTranscriptTests" 2>&1 | grep -E "Executed|failed"`
Expected: `Executed 15 tests, with 0 failures`.
Demonstrate red: make `LineScanner` return the partial as a line (drop the hold-back) → `testATornTailIsHeldBackAndCompletedByTheNextAppend` fails on the first assertion. Make `openReason` return nil unconditionally → `testTheWindowExtendsBackToATurnStart` fails on the first chain record's kind (a tool result) and `testTheWindowExtendsUntilTheNamedLeafIsInside` fails on `contains(leaf)`. Make `WindowedTranscript.readEarlier(_:held:window:policy:)` return no records and the marker unmoved → `testLoadEarlierPrependsUntilClosedAndReachesOffsetZero` never reaches offset 0 (`read` does not call it, so the other window tests stay green). Give every range the next record's offset → `testRangesAddressEveryRecord` fails on the first record, the only test that reads `ranges`. Restore all four.

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
                // Both sequences are numbered from the same start, so occurrence ordinals agree wherever the hashes do.
                XCTAssertEqual(RecordKey.keys(for: conversation, in: stream), RecordKey.keys(for: expected, in: stream),
                               "\(fx.name)/\(stream.name.label): mirrored identity sequence differs from the file's appended range")
                let allowed = mask.allowed(for: stream, path: url)
                for (m, f) in zip(conversation, expected) {
                    let diff = IdentityMask.differingPaths(try m.jsonValue(), try f.jsonValue()).subtracting(allowed)
                    XCTAssertTrue(diff.isEmpty, "\(fx.name)/\(stream.name.label): \(m.kind) differs at \(diff.sorted()) — not declared identity-only")
                    recordsCompared += 1
                }
                for case .agentMetadata(let meta, _) in entries {
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
        XCTAssertEqual(streamsCompared, 18)         // 15 main streams, plus one agent stream in explore-depth-1 and two in nested-depth-2; the relocation's one stream under two paths is counted once and adds nothing
        XCTAssertGreaterThanOrEqual(recordsCompared, 400)  // grounded: 496 mirrored entries minus 3 agent_metadata minus nothing else; the exact figure is asserted by RecordModelTests
    }
}
```

`TranscriptRecord.jsonValue()` is a small test-side extension: `JSONDecoder().decode(JSONValue.self, from: RecordDecoder.encode(self))`. Compute `streamsCompared` from the corpus during execution and pin the exact number; the 18 above is the plan's arithmetic (15 main streams + 1 + 2 agent streams; the relocation's second path folds into its one stream and adds nothing) and must be confirmed, not trusted.

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
public struct ToolCallItem: Hashable, Sendable, Codable { …; public var toolUseID: String; public var name: String; public var rawInput: JSONValue   // `input: ToolInput` is computed below: ToolInput is not Codable on main
    public var result: JSONValue?; public var isError: Bool?; public var structuredResult: JSONValue?; public var denialKind: String?
    public var messageID: String?; public var status: Status; public enum Status: String, Sendable, Codable { case running, completed, failed, denied }; public init(...) }
extension ToolCallItem { /// Typed on demand from the stored raw input; never a stored field (`ToolInput` is `Hashable, Sendable` only).
    public var input: ToolInput { ToolInput.parse(name: name, input: rawInput) } }
public struct ToolClusterItem: Hashable, Sendable, Codable { …; public var toolUseIDs: [String]; public var label: String?; public init(...) }
public struct TaskRunItem: Hashable, Sendable, Codable { …; public var taskID: String; public var kind: TaskKind; public var description: String
    public var status: TaskStatus; public var summary: String?; public var outputFile: URL?; public var usage: JSONValue?; public var toolUseID: String?
    public var agentType: String?; public var depth: Int?; public var synthesised: Bool; public init(...) }
public struct DecisionItem: Hashable, Sendable, Codable { …; public var requestID: RequestID; public var kind: Kind; public var title: String; public var toolUseID: String?
    public var agentID: String?; public var state: State; public var payload: JSONValue
    public enum Kind: String, Sendable, Codable { case permission, question, plan, dialog, elicitation, other }   // `other`: a subtype the host does not model, reached only through `.policyAnswered`
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
    /// `compact_boundary` is deliberately absent: the parent amended §7.3's exclusion list on
    /// 2026-09-05 after the `compact-boundary` recording showed the engine emitting the boundary
    /// on the wire as a `system` frame of that subtype and mirroring the record, so it is compared
    /// like any other record rather than file-to-file only.
    public static let fileOnlyRecordKinds: Set<RecordKindMatcher> = [
        .kind("attachment"), .system("turn_duration"), .system("stop_hook_summary"), .system("local_command"),
        .system("informational"), .userWhere(.isMeta)]
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
/// Where one record's bytes lie: the stream and the reader's `ByteRange` (Task 2), which `TranscriptReader.read(at:length:)` takes.
public struct RecordLocator: Hashable, Sendable, Codable { public var stream: LogicalStream; public var range: ByteRange; public init(stream: LogicalStream, range: ByteRange) }
/// A record the projection does not render and the raw view may show. The payload stays on disk: `StreamIngestion.rawRecord(for:)`
/// reads it through the locator on demand, so C6 never touches JSONL and memory stays bounded. `locator` is nil for a record
/// the mirror delivered before the file held it; the ingestion serves that one from the record it retained until the file catches up.
public struct HiddenRecord: Hashable, Sendable, Codable {
    public var key: RecordKey; public var kind: String; public var timestamp: Date?; public var reason: Reason; public var locator: RecordLocator?
    public enum Reason: String, Sendable, Codable { case attachment, isMeta, isSynthetic, progress, sessionState, unknownKind }
    public init(...)
}
public struct Branch: Hashable, Sendable, Codable { public var head: String; public var tail: String; public var count: Int }   // record uuids
public struct ReadWarning: Hashable, Sendable, Codable { public enum Kind: String, Sendable, Codable { case undecodable, orphanHealed, orphanUnhealed, unknownKind }
    public var kind: Kind; public var stream: StreamName; public var byteOffset: Int?; public var recordKind: String? }
public struct StreamProjection: Hashable, Sendable {
    public var stream: LogicalStream; public var items: [TimelineItem]; public var hidden: [HiddenRecord]; public var branches: [Branch]
    public var session: SessionState; public var warnings: [ReadWarning]; public var window: WindowMarker?; public var metadata: AgentMetadataRecord?
}
public struct DurableProjection: Hashable, Sendable {
    public var items: [TimelineItem]; public var hidden: [HiddenRecord]; public var branches: [Branch]; public var session: SessionState
    public var warnings: [ReadWarning]; public var window: WindowMarker?; public var streams: [LogicalStream]
    public init(...)
    public static let empty: DurableProjection
    public func items(in categories: Set<TimelineCategory>) -> [TimelineItem]
    public func hidden(_ key: RecordKey) -> HiddenRecord?
}
public enum TimelineChange: Hashable, Sendable { case inserted(ItemID), updated(ItemID), removed(ItemID), previewChanged, overlayChanged, sessionStateChanged }
```

- [ ] **Step 4: Tests**

`TimelineModelTests`: `testCategorySetsPartitionAsTheSpecSays` (`durable ∩ overlay == []`, `durable ∪ overlay ∪ [.opaque] == all thirteen`, `comparedWireToFile ⊆ durable`); `testFileOnlyMatchersRecogniseTheCorpusAttachmentsAndMetaUsers` (every attachment record in the corpus matches; both `isMeta` user records match; no plain user record matches; the count of matching records equals 200 + 2); `testTaskKindAndStatusNormalisation` (`"local_bash"` → `.localBash`, `"killed"` → `.stopped`, an unknown kind round-trips through `.other`); `testItemsAreCodableAndHashable` (each payload struct — a `ToolCallItem` whose `rawInput` is a `Bash` input among them — encodes and decodes equal through `JSONEncoder`/`JSONDecoder`, and `input` on the decoded copy is `.bash`; a `HiddenRecord` with and without a locator round-trips too).

Run: `swift test --package-path FleetKit --filter TimelineModelTests 2>&1 | grep -E "Executed|failed"` → `Executed 4 tests, with 0 failures`.
Demonstrate red: remove `.userWhere(.isMeta)` from `fileOnlyRecordKinds` → the matcher count test fails at 200 ≠ 202. Store `ToolInput` as a field of `ToolCallItem` → the target does not compile (`ToolInput` is `Hashable, Sendable` only on main); that build failure is the red for the Codable test, quote it.

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
        public var locators: [RecordKey: RecordLocator] = [:]      // from the reader; a mirror-delivered record has none yet
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

1. Partition: conversation records (`isConversation`) into the tree; `sessionState`, `agentMetadata`, `progress`, `unknown`, `undecodable` aside. Session state folds by `SessionStateVocabulary.kinds[kind]`: `.lastWins` overwrites the matching `SessionState` field; `.accumulate` appends (file-history and content-replacement are kept in `hidden` only); `.boundaryCleared` behaves as last-wins for `last-prompt` and for `continued-in`, whose `continuedInSessionId` sets `session.continuedIn` — the destination; the record's `sessionId` is this file's own id and is never read for it (the boundary clearing is the engine's compaction bookkeeping, not this reducer's).
2. Leaf: the last `last-prompt` in file order sets `session.leaf` (its `leafUuid`) or `session.clearedToEmpty` (explicit null with `explicit: true`); `rewound: true` is recorded on the state; no `last-prompt` → the last conversation record's uuid.
3. Tree and healing: a record whose `parentUuid` is missing is attached to the nearest earlier record in file order with the same `isSidechain` whose `timestamp` is within `healWindow`, and a `ReadWarning(.orphanHealed)` is emitted; failing that it becomes a root with `.orphanUnhealed`. Under an open window (`options.window?.earlierAvailable == true`) the earliest conversation record of the window whose parent is missing is a *window root*: no healing and no warning, because its parent lies before the window and Task 2's closure rule put the window's start at a turn boundary.
4. Items are produced from the chain only; `branches` from the rest. `progress` records, `attachment`s, `user` records with `isMeta` (when `hideMeta`), session-state records and `unknown` kinds become `HiddenRecord`s with the matching `Reason` and the locator `options.locators[key]` (nil when the mirror delivered the record before the file held it). `undecodable`: a `ReadWarning(.undecodable)` and an `OpaqueItem` with `reason: "undecodable"` so the channel shows a warning row (parent §10). `unknown` also emits `.unknownKind`.
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
- `testContinuedInSetsSessionStateFromTheDestinationId_mutation`: append Task 1's invented `continued-in` line (source `11111111-…`, destination `22222222-…`) to `plain-two-turn` in memory → `session.continuedIn == "22222222-2222-4222-8222-222222222222"`, the record is in `hidden` with `reason == .sessionState`, and the items are unchanged; schema-derived, since no fixture carries the kind.
- `testAnOrphanIsHealedToTheNearestEarlierRecord_mutation`: delete one assistant record from the middle of `plain-two-turn` → its child user record is healed onto the preceding record, one `orphanHealed` warning, no branch.
- `testSupersedesRetractsItems_mutation`: add `supersedes: [<uuid>]` to a later assistant record → the named item disappears.
- `testCompactBoundaryHardTruncates_mutation`: insert a `system`/`compact_boundary` record without preserved fields before the last exchange → only the boundary and the last exchange remain.
- `testMergeAttachesAgentItemsUnderTheirSpawningCall`: `nested-depth-2` merged yields two `taskRun` items with `agentType` `general-purpose` and `Explore`, the second's provenance `agentID` equals the depth-2 task id, and its items sit after the depth-1 call in order.
- `testHiddenRecordsCarryReasonsAndLocators`: `plain-two-turn` read with `readAll`, its `ranges` wrapped into `RecordLocator`s under `RecordKey.keys(for:in:)` and passed in `options.locators`: every attachment is in `hidden` with `reason == .attachment` and a locator whose `read(at:length:)` bytes decode to a `JSONValue` with `type == "attachment"` and the record's uuid; the hidden count equals an independent walk of the file; `hidden(key)` finds each.
- `testWindowRootsAreNotOrphans`: reduce the suffix of `nested-depth-2`'s main file from a turn start the test locates, with `options.window = WindowMarker(earlierAvailable: true, continueBefore: cut)` → no orphan warnings and the items equal the suffix of the whole-file items; the same suffix with `window = nil` yields orphan warnings — the discriminating half, inside one test.
- `testToolResultWithAnUnmatchedBlockIDJoinsBySourceAssistantUUID_mutation`: the first corpus `tool_result` record carrying `sourceToolAssistantUUID` (the test locates it; the ledger names the fixture): replace its block's `tool_use_id` in memory with an invented id that matches no call — `ToolResultBlockFields.toolUseID` is a required `String` (`MessageFrames.swift:22`), so the id cannot be stripped without making the record undecodable, which would never reach the fallback — and keep `sourceToolAssistantUUID` → the referenced assistant's sole call is `completed`; unwitnessed on the corpus (every recorded result's block id matches) and named so.

Run: `swift test --package-path FleetKit --filter RecordReducerTests 2>&1 | grep -E "Executed|failed"` → `Executed 15 tests, with 0 failures`.
Demonstrate red: comment out the `sourceToolAssistantUUID` fallback → `testToolCallsJoinTheirResults` still passes on the corpus (every result has a block id) — so that fallback is *not* discriminated by recorded data; say so in the ledger — `testToolResultWithAnUnmatchedBlockIDJoinsBySourceAssistantUUID_mutation` in the list above is what discriminates it: with the fallback removed the referenced call stays `running`, the block id being unmatched by construction. Then break the merge (key items by uuid instead of `message.id`) → `testAssistantRecordsMergeByMessageID` fails with four items instead of two. Read `sessionId` where the fold rule reads `continuedInSessionId` → `testContinuedInSetsSessionStateFromTheDestinationId_mutation` sees the source id (Task 1's accessor test exercises the accessor, not the fold, and stays green).

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

`RegistryMirrorTests` (fold the `background-shell` system frames in `t` order with `now = Date(timeIntervalSince1970: t/1000)`): `testBackgroundShellRowByRow` — after the first `background_tasks_changed` + `task_started`: one entry, `.localBash`, `.background`, `.running`, `listedByEngine == true`, `notified == false`, in `liveWork`; after the Bash `tool_result` observe: `outputFile` non-nil; after the second `background_tasks_changed` (empty) + `task_updated(completed)` + `task_notification`: `status == .completed`, `notified == true`, `listedByEngine == false`, `outputFile` equals the notification's path, `endedAt` set, not in `liveWork`, in `evictable(asOf: endedAt + 31)` and not at `+ 29`; `testTaskStartedRepeatsAreTheSameEntry` (`nested-depth-2`: two distinct ids; replay one `task_started` twice → `startedCount == 2`, entries still two); `testKilledNormalisesToStopped` (a `task_updated` patch with `status: "killed"` → `.stopped`); `testLiveWorkIncludesStartedButNotNotified` (drop the notification from the fold → still live); `testAgentTasksAreRegistryEntriesToo` (`explore-depth-1`: one `.localAgent` entry with `spawn_depth`-bearing `task_started`); `testToolProgressMovesLastFrameAtOnly` (a `tool_progress` frame built from an invented, schema-shaped line decoded through `FrameDecoder` — no fixture carries one; unwitnessed and named so — for the running shell: `lastFrameAt == now`, `status`, `notified` and `listedByEngine` unchanged, still in `liveWork(asOf: now + 1)`; the same frame for an unknown task id changes nothing).

`TaskOutputTailerTests` (on a copy of the `background-shell` artifact under the temporary directory): `testSnapshotYieldsTheOutputAndTheExitCode` (`text` starts with `bg-done`, `exitCode == 0`); `testChunksFollowAppendsAndFinishOnDeletion` (write the file in three appends with the trailer last; three chunks; delete → stream ends); `testAbsentFileIsWaitedFor` (start before creating; first chunk arrives after creation); `testSymlinkIsRefused`; `testTrailerParserAcceptsOnlyTheExactShape` (`[exited with code 3]` → 3; `exited with code` mid-text → nil).

Run: `swift test --package-path FleetKit --filter "RegistryMirrorTests|TaskOutputTailerTests" 2>&1 | grep -E "Executed|failed"` → `Executed 11 tests, with 0 failures`.
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
- Produces: `AgentRunNode`, `AgentRunNode.ParentSource`, `AgentRunTree` with `apply(taskStarted:at:)`, `apply(taskProgress:at:)`, `apply(taskUpdated:at:)`, `apply(taskNotification:at:)`, `apply(agentMetadata:for:)`, `apply(metaFile:)`, `apply(toolProgress:at:)`, `observe(parentToolUseID:carryingToolUseIDs:)` (the two-step join input), `observe(assistantModel:agentID:)`, `node(_:)`, `node(withToolUse:)`, `roots`, `children(of:)`, `isParked(_:)`, `transcriptURL(of:)` (computed from the tree's current `slug`), `relocate(slug:)`.

- [ ] **Step 1: The tree**

```swift
public struct AgentRunNode: Hashable, Sendable, Identifiable, Codable {
    public let id: String
    public var agentType: String?; public var description: String; public var model: String?
    public var status: TaskStatus; public var depth: Int; public var parent: String?; public var parentSource: ParentSource
    public var activityLine: String?; public var lastToolName: String?; public var elapsedOrigin: Date; public var endedAt: Date?
    public var toolUseID: String?; public var children: [String]; public var startedCount: Int          // no stored path: see transcriptURL(of:)
    public enum ParentSource: String, Sendable, Codable { case agentMetadata, metaFile, twoStepJoin, none }
    public init(...)
}
public struct AgentRunTree: Hashable, Sendable {
    public private(set) var nodes: [String: AgentRunNode]
    public var roots: [String] { get }                              // depth-1 nodes in start order
    public private(set) var slug: String                            // the current alias; relocation replaces it
    public init(configHome: URL, sessionID: SessionID, slug: String)
    public mutating func apply(taskStarted f: TaskStarted, at now: Date)      // only task_type == "local_agent"; repeat → startedCount += 1
    public mutating func apply(taskProgress f: TaskProgress, at now: Date)
    public mutating func apply(taskUpdated f: TaskUpdated, at now: Date)
    public mutating func apply(taskNotification f: TaskNotification, at now: Date)
    public mutating func apply(toolProgress f: ToolProgressFrame, at now: Date)   // lastToolName and activityLine of the node whose toolUseID == f.parentToolUseID; nothing else
    public mutating func apply(agentMetadata m: AgentMetadataRecord, for stream: LogicalStream)     // parentAgentId → parent (.agentMetadata) when unset
    public mutating func apply(metaFile url: URL) throws                                          // same, source .metaFile
    /// The two-step join's input: every frame's (parent_tool_use_id, the tool_use ids of its blocks). Records which tool-use id was
    /// carried by a frame whose parent is which tool-use id, so a node whose toolUseID appears under a parent tool-use id gets its parent.
    public mutating func observe(parentToolUseID: String?, carryingToolUseIDs: [String])
    public mutating func observe(assistantModel model: String, agentID: String)
    public func isParked(_ id: String) -> Bool        // terminal status with a child still running
    public func node(_ id: String) -> AgentRunNode?                     // by task id; nil when unknown
    public func node(withToolUse toolUseID: String) -> AgentRunNode?    // the node whose spawning Task tool-use id (`toolUseID`) matches; nil when unknown — the wire reducer's route for forwarded frames
    /// `<configHome>/projects/<slug>/<sessionId>/subagents/agent-<id>.jsonl` under the tree's *current* slug, computed on every call;
    /// nil for an unknown id. Nothing stale can be stored because nothing is stored.
    public func transcriptURL(of id: String) -> URL?
    public mutating func relocate(slug: String)
}
```

Decisions: the parent link is set by the first source that answers, and a later source does not overwrite an earlier one but is checked: if it disagrees, the node keeps the first answer and a `ReadWarning`-shaped conflict is exposed as `conflicts: [String]` on the tree for the test to assert empty on the corpus. The two-step join: a node's `toolUseID` is the block that spawned it; find the frame that carried that block (`carryingToolUseIDs` contains it) and read its `parentToolUseID`; the node whose `toolUseID` equals that value is the parent. `transcriptURL(of:)` is `TranscriptPath.path(of: LogicalStream(configHome:, sessionID:, name: .agent(taskID:)), slug: slug)` from the tree's current `slug`, so `relocate(slug:)` moves every node's path at once. `Provenance.sourceFile` on an item is the path at production time; the current alias is asked of the tree or of `StreamIngestion.paths`, never read from an item. Status from `task_updated`/`task_notification` through `TaskStatus(wire:)`.

- [ ] **Step 2: Tests**

`AgentRunTreeTests`: `testNestedDepth2FromTaskFramesAndMirrorMetadata` (fold `nested-depth-2`'s system frames and the `agent_metadata` mirror entries in `t` order: two nodes; the depth-2 node's `parent` equals the depth-1 id with `parentSource == .agentMetadata`; the depth-1 node has `parent == nil`, `.none`); `testMetaFileGivesTheSameParent` (fold task frames only, then `apply(metaFile:)` for both sidecars → same parent, `.metaFile`); `testTwoStepJoinGivesTheSameParentWhenBothAreWithheld` (fold task frames and `observe` every `assistant`/`user` frame's `parent_tool_use_id` and block ids → same parent, `.twoStepJoin`); `testAllThreeSourcesAgreeAndConflictsAreEmpty`; `testARepeatedTaskStartedIsTheSameNode`; `testAShellCreatesNoNode` (`background-shell`: zero nodes); `testModelComesFromTheRunsOwnFrames` (`explore-depth-1`: `observe(assistantModel:)` from the forwarded frames' `message.model` gives the node a model; before it, nil); `testTranscriptPathFollowsTheSlug` (`transcriptURL(of:)` equals the fixture's agent file path under the recorded config home and the fixture's slug; after `relocate(slug: "_other_")` every node's URL is under `_other_`, and ids, parents and statuses are unchanged; an unknown id is nil); `testToolProgressSetsTheAgentsLastTool` (a constructed `tool_progress` frame whose `parent_tool_use_id` is the depth-1 node's tool-use id → that node's `lastToolName`; the depth-2 node untouched; unwitnessed and named so); `testNodeWithToolUseFindsTheSpawnedNode` (`nested-depth-2` folded from its task frames: `node(withToolUse:)` of the depth-1 `Agent` call's tool-use id is the depth-1 node and of the depth-2 call's is the depth-2 node, `node(_:)` by each task id agrees, and an invented tool-use id and an invented task id are both nil).

Run: `swift test --package-path FleetKit --filter AgentRunTreeTests 2>&1 | grep -E "Executed|failed"` → `Executed 10 tests, with 0 failures`.
Demonstrate red: make `apply(agentMetadata:)` ignore `parentAgentId` → the first test fails with `parent == nil`; make the join read `parentToolUseID` of the spawning frame instead of the carrying frame → the third test fails; cache the URL on the node at spawn → the relocation half of `testTranscriptPathFollowsTheSlug` fails; match `node(withToolUse:)` against the node id instead of `toolUseID` → the lookup test gets nil for both nodes.

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
- Create: `FleetKit/Tests/FleetTimelineTests/Support/FixtureWireReplay.swift`
- Create: `FleetKit/Tests/FleetTimelineTests/Reduce/WireReducerTests.swift`

**Pinned dependency:** `FixtureWireReplay` (Step 3) consumes `WireEventPolicy` from `ClaudeWire`'s `WireTransport`, on `main` at merge `ca68f2e` (branch commit `f187499`): `ClaudeWire/Sources/WireTransport/WireEventPolicy.swift` — `init(policy:handshakeRequestID:)`, `Context {pendingOutbound, pendingInbound, seenInbound, epoch}`, `Effect` with a payload-free `.kind`, `effects(for:in:receivedAt:)` and `effects(deciding:)` — with `WireEvent.kind` and `ClaudeProcess.wireEvents`. It is the transport's frame-to-event policy as a pure function over a snapshot `Context`: the caller applies the effects it returns, and `ClaudeProcess` is that caller, so the actor and this replay agree by construction; the five `WireEventPolicyFixtureTests` on `main` are the parity witness, and no separate parity test is written here because no fake-claude Swift harness exists to drive the actor in-process. A control request becomes `.request`, `.policyAnswered`, `.unansweredDialog`, an MCP route or a silent answer; a cancel becomes `.requestCancelled` when the id is pending; every other frame is `.frame`. C3 does not duplicate any of it.

**Interfaces:**
- Consumes: Task 4's items and projection values; Task 5's merge and tool-join rules (shared through internal helpers in `RecordReducer` — extract `ItemBuilder` into `Reduce/ItemBuilder.swift` if the two reducers would otherwise duplicate the block-to-item logic; the file is internal); Task 6's `RegistryMirror`; Task 7's `AgentRunTree`; from `ClaudeWire`: `WireEvent`, `Frame`, `SystemFrame`, `InboundRequest`, `StreamEventFrame`, `ToolUseSummaryFrame`, `ResultFrame`, `CommandLifecycleFrame`, `ToolProgressFrame`, `RequestID`, `ProcessEpoch`; test-side, from `ClaudeWire` at the pin: `WireEventPolicy` (`init(policy:handshakeRequestID:)`, `.Context`, `.Effect`, `effects(for:in:receivedAt:)`, `effects(deciding:)`), `InboundPolicy`, `InboundRequest.parse(frame:epoch:receivedAt:)`.
- Produces: `WireReducer` (`init(stream:slug:seed:)`, `apply(_: WireEvent) -> [TimelineChange]`, `apply(_: HostSignal) -> [TimelineChange]`, `durable`, `overlay`, `preview`, `registry`, `agents`), `HostSignal`, `Overlay` (declared in full in Step 1: `turns`, `hooks`, `notifications`, `clusters`, `decisions`, `queue`, `stale`, `banners`, `sessionState`, `empty`, `items`), `StreamingPreview`, `Banner`, `DecisionOutcome`; test-side `FixtureWireReplay`.

- [ ] **Step 0: Preflight the pin**

```bash
git merge-base --is-ancestor ca68f2e HEAD || { echo 'WireEventPolicy pin ca68f2e missing from HEAD'; exit 1; }
test -f ClaudeWire/Sources/WireTransport/WireEventPolicy.swift
```

If either line fails the executor stops here and reports; it does not write a copy of the policy.

- [ ] **Step 1: Host signals and overlay values**

```swift
public enum HostSignal: Sendable, Hashable {
    case promptSent(uuid: String, at: Date)
    case decisionAnswered(RequestID, outcome: DecisionOutcome)
    case rewound(toUUID: String)
    case processReplaced(ProcessEpoch)
    case relocated(mainPath: URL)                   // set_cwd answered: the agent tree's slug follows; the host sends the same path to StreamIngestion.relocated(mainPath:)
}
public enum DecisionOutcome: Sendable, Hashable, Codable { case allowed, denied(message: String?), answered(summary: String), cancelled }
public struct Banner: Sendable, Hashable, Codable { public enum Kind: String, Sendable, Codable { case rateLimit, auth, apiRetry, modelFallback, compatibility, mirrorFileOnly }
    public var kind: Kind; public var text: String; public var epoch: ProcessEpoch; public var at: Date }
public struct QueueState: Sendable, Hashable, Codable { public var queued: [String]; public var started: [String]; public var lastState: String? }
public struct Overlay: Sendable, Hashable {                // the wire-only half: reset by `processReplaced`, marked stale by `exited`
    public var turns: [TurnSummaryItem]
    public var hooks: [String: HookRunItem]                  // by hook id
    public var notifications: [NotificationItem]
    public var clusters: [ItemID: ToolClusterItem]           // by the first preceding call's item id
    public var decisions: [RequestID: DecisionItem]
    public var queue: QueueState
    public var stale: Bool
    public var banners: [Banner]
    /// ClaudeWire's payload of `SystemFrame.sessionStateChanged` (`SystemFrames.swift:303`, `Lossless<SessionStateChangedFields>`);
    /// the last frame wins; nil in `.empty`. No item is made from it.
    public var sessionState: SessionStateChanged?
    public static let empty: Overlay                          // every collection empty, `queue` empty, `stale == false`, `sessionState == nil`
    public var items: [TimelineItem] { get }                  // decisions, clusters, turns, notifications and hooks as items, for Task 11's merge
    public init(...)
}
```

`StreamingPreview`: `messageID: String?`, `blocks: [PreviewBlock]` where a block accumulates `text_delta`, `thinking_delta` or `input_json_delta` by `index` from `content_block_start` through `content_block_stop`; `signature_delta` is ignored; `message_delta` carries `stop_reason`; `message_stop` marks complete. `apply(event: JSONValue)` returns whether anything visible changed.

- [ ] **Step 2: The reducer**

```swift
public struct WireReducer: Sendable {
    /// `seed`: the durable projection the file already holds when the channel opens (a resume) — what `StreamIngestion.open` returned.
    public init(stream: LogicalStream, slug: String, seed: DurableProjection = .empty)
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
  - `.user(f)`: `isSynthetic == true` → a `HiddenRecord(reason: .isSynthetic, locator: nil)` in `durable.hidden`; tool-result content → completes calls; otherwise `UserMessageItem` (`isReplay` from the frame) or `PeerMessageItem` by `origin.kind`; `agents.observe(…)` for the join.
  - `.streamEvent(f)`: `preview.apply(f.event)`; `.previewChanged`.
  - `.toolProgress(f)`: `registry.apply(toolProgress: f, at: now)` (moves `lastFrameAt` of the entry for `f.taskID`, else of the entry whose tool-use id is `f.parentToolUseID ?? f.toolUseID`) and `agents.apply(toolProgress: f, at: now)`; no item and no change emitted. No fixture carries the frame: unwitnessed, tested on a constructed frame.
  - `.result(f)`: `TurnSummaryItem` with `attribution`: `.relocation` when `numTurns == 0`; `.prompted(uuid)` popping the oldest `outstandingPrompts` when non-empty; else `.unprompted`. Appended to `overlay.turns`.
  - `.system(.initialize)`: turn boundary only (no item). `.system(.taskStarted/.taskUpdated/.taskProgress/.taskNotification/.backgroundTasksChanged)`: `registry.apply`, `agents.apply`; a `task_notification` synthesises a `TaskRunItem(synthesised: true, provenance.origin: .synthesised)` into `durable.items` for a non-agent task and updates the existing agent `TaskRunItem` for an agent. `.system(.hookStarted/.hookProgress/.hookResponse)`: `overlay.hooks[hookID]`. `.system(.notification)`: `overlay.notifications`. `.system(.permissionDenied)`: marks the tool call `.denied` with `denialKind`. `.system(.compactBoundary)`: `CompactBoundaryItem` into `durable` (the wire side of the same record; compared file-to-file only per the constant, so it never enters check two). `.system(.status/.apiRetry/.modelRefusalFallback/.modelRefusalNoFallback/.modelConsentFallback)`: banners. `.system(.mirrorError)`: `Banner(.mirrorFileOnly)` — the ingestion switch itself is Task 10's. `.system(.localCommandOutput)`: `NotificationItem(key: "local_command_output", fileOnly: false)`. `.system(.sessionStateChanged(s))`: `overlay.sessionState = s` (the last frame wins; no item). `.system(.opaque)` and every other subtype: `OpaqueItem`.
  - `.toolUseSummary(f)`: `overlay.clusters[<id of the first preceding call>]` labelled.
  - `.commandLifecycle(f)`: `overlay.queue` by `state`.
  - `.rateLimitEvent`, `.authStatus`: banners. `.promptSuggestion`, `.conversationReset`, `.keepAlive`, `.controlResponse`, `.controlCancelRequest`, `.controlRequest`: no item (`conversation_reset` clears `durable` to empty and records `session.leaf = nil`). `.transcriptMirror`: **ignored here** (Task 10's). `.opaque`: `OpaqueItem`.
- `.request(r)`: `DecisionItem(state: .pending)` keyed by `r.id` with `kind` by payload case (`canUseTool` → `.permission`, or `.question` when `toolName == "AskUserQuestion"`, `.plan` when `"ExitPlanMode"`; `requestUserDialog` → `.dialog`; `elicitation` → `.elicitation`; `unknown`/`malformed` → no decision, an `OpaqueItem`), `agentID` from the payload, `toolUseID` likewise.
- `.requestCancelled(id, _)`: state `.cancelled`. `.policyAnswered(r, error)`: the item for `r.id` moves to `.policyAnswered(error:)` — created in that state when none is pending, `kind` by payload as for `.request` and `.other` for an `unknown` payload, since the policy answers such a request itself and never surfaces it as `.request`. `.unansweredDialog(r)`: `.inert`.
- `.hostToolInvoked(inv, _)`: marks the matching `SentFileItem.delivered = true` when its tool-use id is known, else queues by name for the next `SentFileItem`.
- `.exited`: `overlay.stale = true`, `preview = nil`, every `.pending` decision → `.inert`, running registry entries keep their state (C4 decides).
- `HostSignal.promptSent`: push the uuid. `.decisionAnswered`: `.answered(outcome:)`. `.rewound(toUUID:)`: drop every durable item after the item whose record uuid equals `toUUID`, drop preview, mark `session.leaf`. `.processReplaced`: `overlay = .empty` with `stale = false`, `preview = nil`, prompts cleared; `durable` untouched. `.relocated(mainPath:)`: `agents.relocate(slug:)` with the slug `TranscriptPath.resolve(mainPath, under: stream.configHome)` yields; a path that does not resolve to this session is ignored and counted in `overlay.banners` as a `.compatibility` banner.

Timestamps: from the frame's `timestamp` when present, else `now`.

- [ ] **Step 3: The fixture replay (test support)**

`FleetKit/Tests/FleetTimelineTests/Support/FixtureWireReplay.swift`:

```swift
/// What `ClaudeProcess` would have pushed for a recorded fixture, reproduced from the recording rather than by re-running it.
/// Out-direction frames go through C2's `WireEventPolicy` at `ca68f2e` — the same function the transport calls, over a
/// `Context` this replay threads exactly as the actor does — so a control request is never a `.frame` here either;
/// in-direction frames are what the host did and become `HostSignal`s.
enum FixtureWireReplay {
    struct Step { let t: Int; let events: [WireEvent]; let signal: HostSignal? }
    /// `InboundPolicy.default(declaredDialogKinds:registeredHookCallbackIDs:)` from the fixture's own `initialize` request
    /// (the first in-direction control_request: `supportedDialogKinds`, every `hooks.*[].hookCallbackIds`).
    static func policy(for fx: FixtureCorpus.Fixture) throws -> InboundPolicy
    /// `WireEventPolicy(policy: policy(for: fx), handshakeRequestID: <that initialize request's id>)` — the value the transport builds.
    static func wirePolicy(for fx: FixtureCorpus.Fixture) throws -> WireEventPolicy
    static func steps(for fx: FixtureCorpus.Fixture, epoch: ProcessEpoch = .first) throws -> [Step]
    /// A reducer seeded from `initial/` when the fixture has one — the record reducer's merged projection of those files,
    /// which is what `StreamIngestion.open` hands the wire reducer on a resume — else empty.
    static func reducer(for fx: FixtureCorpus.Fixture) throws -> WireReducer
    static func replay(_ fx: FixtureCorpus.Fixture) throws -> WireReducer       // reducer(for:), then every step in `t` order
}
```

The in-direction mapping (host side, C3's own): a `user` frame → `HostSignal.promptSent(uuid:at:)`; a `control_response` answering a request the replay surfaced → `HostSignal.decisionAnswered(id, outcome:)` (`behavior: allow` → `.allowed`, `deny` → `.denied(message:)`, a dialog, question or plan answer → `.answered(summary: <subtype>)`); the `initialize` request and interrupts → nothing. The out-direction mapping is `WireEventPolicy`'s. The replay holds one `WireEventPolicy.Context` per recording and walks the frames in `t` order: an in-direction `control_request` the host wrote adds its id to `pendingOutbound` (the sender populates that set in the actor, so the replay does it here); an out-direction frame goes to `effects(for:in:receivedAt:)`, and the replay applies the state effects to its context (`settleOutbound` and `dropUncorrelated` remove from `pendingOutbound`, `markSeen` adds to `seenInbound`, `markPending` and `clearPending` edit `pendingInbound`), discards `writeAnswer`, `recordPolicyAnswer`, `routeToMCP` and `cancelMCPTask` (the actor's side effects, not events), and on `settleHandshake(body)` does what the actor does with the body's re-armed requests (`markSeen`, then `effects(deciding:)`); only the `.publish(event)` effects reach the reducer, in order. Three behaviours the replay therefore reproduces and the tests below pin: the engine echoes every host-written `control_response` on its stdout, and those ids are in no pending set, so they are `dropUncorrelated` and produce no event; a `control_response` with an error body whose id is pending is a normal `settleOutbound` and one `.frame` event; every `control_cancel_request` yields `cancelMCPTask`, plus `clearPending` and `.requestCancelled` only when the id is in `pendingInbound`.

- [ ] **Step 4: Tests**

`WireReducerTests`, folding each fixture through `FixtureWireReplay.replay` (Step 3): `testStreamingPreviewAssemblesAndCollapses` (`plain-two-turn`: after the deltas of the first message the preview has the text; after the `assistant` frames it is nil and the item's text equals the preview's); `testResultAttributionOnRelocationAndNestedAgents` (`session-mirror-relocation`: five turns, attributions `[prompted, prompted, relocation, prompted, prompted]`; `nested-depth-2`: `[prompted, unprompted, unprompted]`); `testDecisionLifecycle` (`permission-allow`: the `can_use_tool` request → `.pending`; the replay's `HostSignal.decisionAnswered(id, .allowed)` → `.answered(outcome: "allowed")`; `permission-deny`: `WireEventPolicy` surfaces its `can_use_tool` as `.request` and never answers it, the host's recorded `behavior: deny` response is the answer — `HostSignal.decisionAnswered(id, .denied(message:))` → `.answered(outcome: "denied")`; and `.policyAnswered(error:)`, reached only through a `writeAnswer` effect carrying an error: one constructed inbound `control_request` with an invented unknown subtype (no engine bytes; `RequestID` and session id invented), pushed through `wirePolicy(for:)`'s `effects(for:in:receivedAt:)` on the replay's final `Context` — the policy answers it with an error at once and publishes `.policyAnswered(r, error)` — and that event applied to the reducer → a decision item for the id in `.policyAnswered(error:)` with `kind == .other`); `testToolUseSummaryLabelsTheCluster`; `testForwardedFramesLandOnTheAgentStream` (`explore-depth-1`: items with `provenance.agentID` equal to the task id exist and none of them is on the main stream's id); `testTaskNotificationSynthesisesACompletionItem` (`background-shell`: one `taskRun` with `synthesised == true` after the notification, none before); `testSyntheticUsersAreHidden_mutation` (set `isSynthetic: true` on a user frame in memory → hidden, no item; unwitnessed on the wire and named so); `testRewoundTruncatesTheDurableHalf_mutation`; `testProcessReplacedResetsOverlayNotProjection`; `testCommandLifecycleDrivesQueueState` (from `control-shapes` or any fixture that carries the frames; if none does, a constructed frame with the schema's five states and the test says so); `testToolProgressHeartbeatMovesLastFrameAt` (`background-shell` replayed up to the shell's `task_started`, then a constructed `tool_progress` frame for it at `now` → `registry` shows `lastFrameAt == now` and `liveWork(asOf: now + 1)` still lists it; unwitnessed on the corpus and named so); `testRelocationSignalRebindsAgentTranscriptPaths` (`nested-depth-2` replayed, then `.relocated(mainPath:)` under `_other_` → both nodes' `transcriptURL(of:)` under `_other_`, nothing else changed); `testASeededReducerContinuesTheFileProjection` (`session-mirror-resume`: `FixtureWireReplay.reducer(for:)` seeded from `initial/`, then the steps → the durable items in `comparedWireToFile` equal the record reducer's over `transcript/` — check two's shape on the one fixture where the seed matters; without the seed the first five assistant groups are missing, asserted as the counter-case); `testEchoedControlResponsesProduceNoEvent` (over every recorded fixture, the count of `.frame` events whose frame is a `control_response` equals the count of out-direction `control_response`s whose id the host's own requests carry, and every echo of a host-written answer yields no event — the replay's context shows the id absent from `pendingOutbound`; and a correlated response with an error body — constructed from the schema against a host request the replay marked pending, since the corpus may carry none, and the test says so — settles as `settleOutbound` and one `.frame`); `testCancelFramesYieldCancelMCPTaskAndRequestCancelledWhenPending` (a `control_cancel_request` for an id in `pendingInbound` — from `permission-allow` if its recording carries one, else constructed and named so — yields `cancelMCPTask`, `clearPending` and `.requestCancelled`; the same frame for an unknown id yields `cancelMCPTask` and `.frame` only); `testSessionStateChangedLandsInTheOverlay` (a constructed `session_state_changed` frame — `Lossless(fields: SessionStateChangedFields(...))` with the synthetic session id and an invented uuid, since no fixture carries the frame — applied to a `plain-two-turn` reducer → `overlay.sessionState` equals it, no item and no durable change; a second frame replaces it; `HostSignal.processReplaced` clears it to nil; unwitnessed and named so).

Run: `swift test --package-path FleetKit --filter WireReducerTests 2>&1 | grep -E "Executed|failed"` → `Executed 16 tests, with 0 failures`.
Demonstrate red: attribute every result `.prompted` when any prompt was ever sent (drop the pop) → the relocation attribution test fails at index 2. Route forwarded frames to the main stream → the agent-stream test fails. Drop the `.toolProgress` route → the heartbeat test fails on `lastFrameAt`. Leave `pendingOutbound` empty in the replay → `testEchoedControlResponsesProduceNoEvent` fails: the constructed correlated error-body response is `dropUncorrelated` and yields no `.frame`. Apply every context effect but `markPending` → `testCancelFramesYieldCancelMCPTaskAndRequestCancelledWhenPending` fails: the pending id's cancel yields `cancelMCPTask` and `.frame` with no `.requestCancelled`; no other test reads either. Drop the `.sessionStateChanged` route → the overlay test finds nil.

```bash
git add FleetKit/Sources/FleetTimeline/Reduce FleetKit/Tests/FleetTimelineTests
git commit -m "FleetTimeline: the wire reducer — durable half, streaming preview, overlay and host signals"
```

---

### Task 9: Check two of the invariant — projection equality and the overlay assertions

**Files:**
- Create: `FleetKit/Tests/FleetTimelineTests/Invariant/ProjectionEqualityTests.swift`

**Interfaces:**
- Consumes: Task 3's `FixtureCorpus`, `Breaks`, `IdentityMask.differingPaths`; Task 5's `RecordReducer`; Task 8's `WireReducer` and `FixtureWireReplay` (and, through it, `WireEventPolicy` at the pin Task 8 preflights); Task 4's `ProjectionCategories`.
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

    /// Every fixture's compared-item count, pinned by name so each outcome is stated: zero for `zero-cost`, the `initial/`
    /// snapshot's items for `resume-no-replay`, and so on. Filled from the first run, cross-checked by `IndependentCount`,
    /// and re-pinned only after a confirmed re-recording.
    private static let expectedComparedItems: [String: Int] = [ /* eighteen names → counts */ ]

    func testWireAndRecordProjectionsAgreeOnEveryFixture() throws {
        var findings: Set<String> = []; var comparedPerFixture: [String: Int] = [:]
        let all = try FixtureCorpus.all()
        for fx in all {                                                   // all eighteen: no skip, no exclusion list
            let wire = try FixtureWireReplay.replay(fx)                   // seeded from initial/ when present; control requests through C2's policy
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
        // (assistant message.ids + non-tool-result non-meta users + tool_use blocks + send_user_file calls + agent runs),
        // and equals the pinned outcome for that name. A comparison that matched nothing cannot pass either assertion.
        for fx in all { XCTAssertEqual(comparedPerFixture[fx.name], try IndependentCount.comparedItems(fx), "\(fx.name): the comparison did not see every item") }
        XCTAssertEqual(comparedPerFixture, Self.expectedComparedItems)
        XCTAssertEqual(Set(comparedPerFixture.keys), Set(all.map(\.name)))
    }

    func testOverlayRendersDecisionsClustersAndTurnCostFromWireFramesAlone() throws {
        // Over all eighteen fixtures through FixtureWireReplay: every can_use_tool / request_user_dialog / elicitation request the policy
        // surfaced (or left unanswered) has a DecisionItem in the state the recording implies (answered by the host's control_response,
        // policyAnswered for a policy error, inert for an undeclared dialog, cancelled for a control_cancel_request); the count per fixture
        // equals an independent count of out-direction control_request frames of those subtypes; every tool_use_summary labelled a
        // cluster whose ids equal preceding_tool_use_ids; every result frame has a TurnSummaryItem with its duration_ms and
        // total_cost_usd (synthetic results lack them → pinned findings).
    }
}
```

`IndependentCount.comparedItems(fx)` walks the raw records with `JSONValue` only (no reducer) so the floor is independent of the code under test.

- [ ] **Step 3: Demonstrate red, three ways, then commit**

1. Change one `tool_result` block's `tool_use_id` in memory (wire side) on `background-shell` → a `<presence>` difference for the tool call.
2. Edit one `text` block on the file side of `plain-two-turn` → a difference at `contentBlocks.text`.
3. Make `WireReducer` skip forwarded `assistant` frames → `explore-depth-1` and `nested-depth-2` fail on agent-stream items.
4. Make `FixtureWireReplay.reducer(for:)` ignore `initial/` → `session-mirror-resume` fails by presence on its first five assistant groups and `resume-no-replay` on every item.
5. Deliver control requests as `.frame(.controlRequest)` instead of through `WireEventPolicy` → the overlay test finds no decision items on `permission-allow`.
Also confirm the sixth: remove `.taskRun` from `comparedWireToFile` → the independent count no longer matches, proving the floor is bound to the constant.

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
- Consumes: Tasks 1, 2, 5 (`SyntheticTranscript.queuedTurnLines` included); Task 8's test-side `FixtureWireReplay.steps(for:epoch:)`; Task 9's `ProjectionComparison`; from `ClaudeWire`: `WireEvent`, `Frame`, `SystemFrame`, `TranscriptMirrorFrame`, `MirrorError`, `ExitStatus`, `ProcessEpoch`.
- Produces: `TimelineNotice`, `TimelineDiagnosticsSink`, `NullTimelineDiagnostics`, `RecordingTimelineDiagnostics` (a lock-guarded test double, `@unchecked Sendable` documented), `StreamIngestion` (`Mode`, `State`, `Effect`, `open(file:events:policy:)`, `effects`, `fileChanged(_:at:)`, `relocated(mainPath:)`, `loadEarlier()`, `rawRecord(for:)`, `close()`, `projection`, `state`, `offsets`, `paths`; the tap's entry points `apply(mirror:epoch:at:)`, `mirrorError(_:epoch:)` and `processExited(_:)` and the pure `align(buffered:tail:readStart:)` are internal), `RawRecordError` (`unknownKey`, `staleLocator`).

- [ ] **Step 1: Notices**

Exactly the spec's enum, plus the sink protocol, `NullTimelineDiagnostics`, and `RecordingTimelineDiagnostics` (`final class`, an `NSLock` around `notices: [TimelineNotice]`; the doc comment names the lock as the serialising mechanism). No case carries a path, a `LogicalStream`, a title or a record.

- [ ] **Step 2: The actor**

```swift
public actor StreamIngestion {
    public enum Mode: Sendable { case filePrimary, mirrorPrimary }
    public enum State: Sendable, Hashable { case both, fileOnly(since: ProcessEpoch), mirrorOnly }   // mirrorOnly: opened on a main path that does not exist yet
    public struct Effect: Sendable { public var applied: [RecordKey]; public var duplicates: Int; public var routedElsewhere: Int; public var changes: [TimelineChange]; public var stateChange: State? }
    public init(session: SessionID, configHome: URL, mode: Mode, diagnostics: any TimelineDiagnosticsSink = NullTimelineDiagnostics(), mirrorGapWindow: Duration = .seconds(2), tapSettle: Duration = .milliseconds(20))
    /// Owns the ordering between the channel's tap — one subscription of C4's per-subscriber fan-out, see `receive` — and the file:
    /// starts a task consuming `events` into a buffer, reads the file (a main path that does not exist yet is `.mirrorOnly`, not an error),
    /// waits until the tap has been quiet for `tapSettle`, aligns the buffer against the read's tail (`align(buffered:tail:readStart:)`),
    /// applies what the alignment did not claim, and from then on applies each tap event as it arrives until the sequence ends
    /// or `close()`. Returns the projection with the buffer applied. The buffered frames' effects and every later one go to
    /// `effects`, one per frame. A second `open` on one actor is a programmer error (`precondition`). An error thrown after the
    /// consuming task started cancels it and finishes `effects` before it propagates.
    public func open(file mainPath: URL, events: some AsyncSequence<WireEvent, Never> & Sendable, policy: WindowPolicy = .init()) async throws -> DurableProjection
    /// Every effect this actor produces, in order — the tap's and the direct calls' alike (`AsyncStream`, unbounded: a dropped
    /// effect would be a dropped `TimelineChange`). One consumer: C6, or the test.
    public nonisolated let effects: AsyncStream<Effect>
    public func fileChanged(_ path: URL, at now: Date = Date()) async -> Effect
    public func relocated(mainPath: URL) async
    public func close()                                            // cancels the consuming task and the gap sweep, finishes `effects`; every query still answers
    /// *Load earlier* — the C6 contract behind the affordance, since C6 reads no JSONL: continues from the main stream's window
    /// marker through `WindowedTranscript.readEarlier(_:held:window:policy:)`, prepends the records with fresh occurrence
    /// ordinals and locators, moves the marker; `applied` lists the prepended keys. An empty effect when `earlierAvailable == false`.
    public func loadEarlier() async throws -> Effect
    public var projection: DurableProjection { get }
    public var state: State { get }
    /// The raw view's read: the record's bytes through `TranscriptReader.read(at:length:)` at its locator, decoded to `JSONValue`
    /// and verified — the decoded record's uuid, or its `contentHash`, must be the key's, else `RawRecordError.staleLocator` (a
    /// locator from before a rewrite this actor has not yet seen; never another record's bytes); a record the mirror delivered
    /// before the file held it is served from the retained record until `fileChanged` sees it on disk. `RawRecordError.unknownKey`
    /// for a key this ingestion never applied. Nothing is cached; the projection stays payload-free.
    public func rawRecord(for key: RecordKey) async throws -> JSONValue
    public enum RawRecordError: Error, Sendable, Equatable { case unknownKey, staleLocator }
    public var offsets: [LogicalStream: Int] { get }
    public var paths: [LogicalStream: URL] { get }                 // the current aliases, for whoever needs a path (C6's Open transcript)

    // The tap's entry points — internal; the consuming task calls them and nothing outside the module does.
    func receive(_ event: WireEvent) async
    func apply(mirror frame: TranscriptMirrorFrame, epoch: ProcessEpoch, at now: Date) -> Effect
    func mirrorError(_ error: MirrorError, epoch: ProcessEpoch) -> Effect
    func processExited(_ epoch: ProcessEpoch) async -> Effect
    func sweepGaps(at now: Date)                                 // the mirror-gap deadline's body; armed by `fileChanged` under `mirrorPrimary`
    struct TailRecord: Sendable { var uuid: String?; var hash: String; var range: Range<Int> }        // one record the open read, in file order
    struct BufferedEntry: Sendable { var frame: Int; var entry: Int; var uuid: String?; var hash: String }  // one buffered mirror entry, in arrival order
    struct Alignment: Sendable, Equatable { var claims: [Int: Int]; var cursor: Int }                 // buffered position → tail index; the cursor in bytes
    /// Pure. Two identities are equal when both carry the same uuid, or neither carries one and the hashes are equal. Returns the
    /// claimed pairs and the cursor: the end offset of the last claimed record, or the read's start offset when nothing was claimed.
    static func align(buffered: [BufferedEntry], tail: [TailRecord], readStart: Int) -> Alignment
}
```

Internal state: `records: [LogicalStream: [TranscriptRecord]]` in *file* order — by locator offset, with the records the mirror delivered and the file has not yet shown after the last located one in delivery order, so a `loadEarlier` prepend is ordinary insertion and the reducer's last-wins folds see the file's order once the file has caught up — `applied: [LogicalStream: Set<RecordKey>]`, `paths: [LogicalStream: URL]`, `offsets`, `fileIdentity: [LogicalStream: (dev: dev_t, ino: ino_t, length: Int)]` (captured by `fstat` at open, or at the first `fileChanged` that finds a file `open` did not, and refreshed after a rebuild; absent while a stream has no file), `tailAnchor: [LogicalStream: (range: Range<Int>, sha256: Data)]` (the byte range and SHA-256 of the raw line of the last file-located record, refreshed after every append read and every rebuild; absent while the stream has no located record), `epoch: ProcessEpoch` (the greatest the tap has shown; `.first` before any event), `window: WindowMarker?` for the main stream, `locators: [RecordKey: RecordLocator]` (every record the file has shown, from the reader's parallel `ranges` plus the stream), `ordinals: [LogicalStream: [String: Int]]` (per content hash, the ordinals applied so far — the next one to assign), `cursor: [LogicalStream: Int]` (the byte offset the tap alignment fixed; the read's start until it runs), `fileUnclaimed: [LogicalStream: [String: [RecordKey]]]` (uuid-less records the file applied at or past the cursor that no mirror delivery has claimed, in file order) and `mirrorUnclaimed: [LogicalStream: [String: [RecordKey]]]` (uuid-less records the mirror applied that no file line has confirmed, in delivery order) — the two sides of the occurrence rule: each source's uuid-less delivery claims the other side's earliest unclaimed record of its hash, or is new — `tap: Task<Void, Never>?` and `buffer: [(TranscriptMirrorFrame, ProcessEpoch, Date)]?` (non-nil from the start of `open` until the alignment ran: a mirror frame arriving while it is non-nil is buffered, every other event is handled at once), `pendingFromFile: [LogicalStream: [RecordKey: Date]]` (under `mirrorPrimary` only: records the watcher applied that no mirror delivery has confirmed, with the time seen; an entry leaves on either mirror-side claim path), `gapSweep: Task<Void, Never>?` (the mirror-gap deadline, armed when an entry is added and none is armed), `metadata: [LogicalStream: AgentMetadataRecord]`. The projection is recomputed by `RecordReducer.reduce` per stream and `merge` after every effect (the reducers are pure and the corpus is small; incremental reduction is a later optimisation and is *not* planned here). The arbitration table from the spec is the implementation, row by row:

- `open(file:events:policy:)`: `buffer = []` and `tap = Task { for await event in events { await self.receive(event) } }` first; then `fstat` the main file — `ENOENT` is not an error: the main stream is created at offset 0 and cursor 0 with no `fileIdentity`, `state = .mirrorOnly`, nothing is read, and the settle and alignment below run over an empty tail (every buffered entry unclaimed) — otherwise capture its `(st_dev, st_ino)` and length in `fileIdentity`; read it through `WindowedTranscript.read(TranscriptReader(url: mainPath), policy:)` (Task 2's closure rule), apply with the ordinals `RecordKey.keys(for:in:)` assigns (seeding `ordinals`), record each locator (`RecordLocator(stream:, range:)` from the parallel `ranges`), set `offsets[main] = length`, keep the marker in `window`, and pass it and `locators` in the reducer's options; discover `<sessionId>/subagents/agent-*.jsonl` beside it and open each whole; read every `.meta.json` into `metadata`. Then settle — `repeat { let n = buffer.count; try await Task.sleep(for: tapSettle) } while buffer.count != n` (the suspension is what lets the consuming task run) — then, per stream the buffered frames name, `align(buffered:tail:readStart:)` over that stream's buffered entries and the records the read applied: a claimed entry is a counted duplicate (its record is applied and located already), `cursor[stream]` is set from the result, and `fileUnclaimed[stream]` is seeded with the read's *unclaimed* uuid-less records at or past the cursor in file order; then `buffer = nil` and each buffered frame goes through `apply(mirror:)` with its claimed entries counted, not applied — one `Effect` per frame on `effects` — and one `TimelineNotice.tapAligned(session:stream:claimed:unclaimed:)` per stream that had buffered entries. `align` itself: the anchors are the buffered uuid entries whose uuid the tail holds, taken in buffer order with strictly increasing tail indices (one that goes backwards is not a write-order record and is skipped); with at least one anchor, each anchor claims its record and the uuid-less buffered entries between consecutive fixed points — the read's start, each anchor, the read's end — claim the tail's unclaimed uuid-less records between the same fixed points by hash, in order (the first unclaimed record of that hash after the previous claim within the span), while a uuid entry the tail does not hold stays unclaimed; with no anchor, k is the largest count such that the first k buffered identities equal the tail's last k identities, and those k pairs are claimed. The cursor is the end offset of the last claimed record, or the read's start offset when nothing was claimed. A claim never creates a record, a wrong claim costs only the latency until the watcher shows the line, and a missed claim is a phantom, so ties go to claiming. After the read, `tailAnchor[main]` is the last located record's range and digest. Any error thrown inside `open` after `tap` started — an unreadable file, a directory at the path — cancels `tap` and finishes `effects` before it rethrows, so no consuming task outlives a failed open.
- `receive(_:)` (the consuming task's call): `.frame(.transcriptMirror(f), epoch)` → buffered while `buffer != nil`, else `apply(mirror: f, epoch:, at: Date())`; `.frame(.system(.mirrorError(e)), epoch)` → `mirrorError(e, epoch:)`; `.exited(_, epoch)` → `processExited(epoch)`; before any of these, `epoch` is raised to the event's, and an event whose epoch is greater than a `fileOnly(since:)`'s → `state = .both` (`processReplaced`; the next effect carries the `stateChange`); every other event is not this actor's and is left alone — the tap is one subscription of C4's per-subscriber fan-out (`LifecycleAPI.events(of:)`, C4 spec v2.3 on `child/c4-sessions-fleet`: each call yields an independent `AsyncStream<WireEvent>` carrying every event in order), C6 takes a separate subscription for the channel's `WireReducer`, and `open` never receives ClaudeWire's single-consumer `WireEventStream`, so ignoring an `assistant`, `user`, `stream_event`, `result` or `request` event here loses nothing. Every effect goes to `effects`.
- `apply(mirror:)`: resolve `filePath` under `configHome`; a different session → `routedElsewhere += 1` and `TimelineNotice.mirrorRoutedElsewhere`; state `fileOnly` for this epoch → ignore; `agentMetadata` entries → `metadata[stream]`; each other entry: a uuid record whose key is applied → `duplicates += 1` and `pendingFromFile[stream][key]` removed; a uuid-less entry whose hash has an entry in `fileUnclaimed[stream]` → claim the first (remove it; `duplicates += 1`; its locator is bound already; its `pendingFromFile` entry removed), else apply it with ordinal `ordinals[stream][h]` (then incremented) and append its key to `mirrorUnclaimed[stream][h]`; a stream with no open file → create it with offset 0 and cursor 0 (lazy agent stream). Nothing is presumed about when `open` ran relative to the entry: a line the open already read was claimed by the alignment or sits in `fileUnclaimed`, and is never applied twice. Under `mirrorPrimary` the mirror is applied first and the watcher's read confirms; under `filePrimary` the same code runs — the mode only decides which delivery the *renderer* waits for, which is a C6 concern, and here it decides whether a mirror gap counts as a fault (only under `mirrorPrimary`).
- `fileChanged`: resolve; a stream with no `fileIdentity` (the main stream under `.mirrorOnly`, or a lazily opened agent stream) whose file now exists → capture its identity and read it from 0 by the append rule below (mirror-unclaimed records claimed, locators bound), and when the main stream was `.mirrorOnly`, `state = .both` carried as the effect's `stateChange`; a file that still does not exist → an empty effect. Otherwise `fstat` first, then `pread` the stream's `tailAnchor` range before any append read — a length shorter than `offsets[stream]`, a `(st_dev, st_ino)` other than `fileIdentity`'s, a short read of the anchor's range, or a digest other than the anchor's, is the rewrite arm (parent §7.3: garbage collection after a hard compaction rewrites the file to drop what precedes the boundary, SPEC 35.8, 35.5.13; and the engine's `performRemoveByUuid` — bundle 2.1.258 `cli.pretty.js` 430606–430644, 2.1.257 line 156853 — opens the transcript `r+`, truncates at the removed line and writes the suffix back in place, so the inode survives and, with the watcher's 0.1 s latency, one coalesced event can arrive after later appends pushed the length past the old offset; length and identity alone would accept that, and every rewind after it would corrupt the projection): rebuild the stream whole through `WindowedTranscript.read` — `records`, `applied`, `locators`, `ordinals`, `fileUnclaimed`, `mirrorUnclaimed`, `cursor` (the new length) and `window` for that stream replaced, `fileIdentity`, `offsets` and `tailAnchor` refreshed, `pendingFromFile` cleared — emit one `TimelineNotice.fileRewritten(session:stream:previousLength:newLength:)`, leave `state` alone, and return the effect (`applied` = the rebuilt keys); this is the only event that renumbers a published key, and `rawRecord`'s verification remains the backstop only for a key queried between the rewrite and the next `fileChanged`. Otherwise `readAppended(from: offsets[stream])`; each record: a uuid record → record its locator (this is what closes a mirror-delivered record's nil locator in the next projection), applied → `duplicates += 1` and skip, else apply; a uuid-less record whose hash has an entry in `mirrorUnclaimed[stream]` → bind the locator to the first (remove it; `duplicates += 1`), else apply with ordinal `ordinals[stream][h]` (then incremented), record the locator and append its key to `fileUnclaimed[stream][h]`; after the read `tailAnchor[stream]` is the last located record's range and digest; a newly applied record under `mirrorPrimary` is remembered as `pendingFromFile[stream][key] = now`, and when `gapSweep` is nil it is armed: `Task { try? await Task.sleep(for: mirrorGapWindow); await self.sweepGaps(at: Date()) }`.
- `sweepGaps(at:)` (the deadline's body, actor-isolated): `gapSweep = nil`; per stream, the entries older than `mirrorGapWindow` are removed and counted, and a non-zero count switches `state` to `.fileOnly(since: epoch)` — once; a stream swept while already `fileOnly` only counts — and emits one `Effect` on `effects` with no keys and the `stateChange`, with one `TimelineNotice.mirrorGap(session:stream:missing:epoch:)` per stream swept, no file event required (the coalesced watcher event that would have caught it may never come); while any entry remains, the sweep re-arms for the time the oldest remaining entry has left. Under `filePrimary` nothing is kept and nothing is armed.
- `mirrorError` (from the tap's `system` frame): `.fileOnly(since: epoch)` + `TimelineNotice.mirrorErrorSwitchedToFileOnly`; idempotent within the epoch.
- `relocated(mainPath:)`: rebind `paths[main]` and every agent stream's path under the new slug; offsets, locators and `fileIdentity` unchanged (a locator is stream plus range and the stream did not change; a rename keeps the inode, so the next `fileChanged` does not take the rewrite arm); `TimelineNotice.relocationFollowed`. The host sends `HostSignal.relocated(mainPath:)` to the channel's `WireReducer` in the same breath; this actor holds no reducer.
- `processExited` (from the tap's `.exited`): for every stream that has a file (a `.mirrorOnly` main stream or a lazily opened agent stream whose file does not exist yet is skipped), `readAppended(from:)` and apply what is missing by the `fileChanged` rule, then clear `fileUnclaimed` and `mirrorUnclaimed` and set `cursor` to the stream's offset (`ordinals` stay: the next epoch's mirror carries only later appends, matched afresh from there); a `.both` state stays; a `fileOnly` state persists until the tap's first event under a greater epoch (`processReplaced`: `receive` resets `state = .both` when it sees an epoch greater than `since`).
- `loadEarlier`: `window == nil` or `earlierAvailable == false` → an empty effect; else `WindowedTranscript.readEarlier(reader, held: records[main], window:, policy:)`, prepend its records to `records[main]` with fresh ordinals (`ordinals` for each hash, incremented; a prepended record never enters `fileUnclaimed`, which holds lines at or past the cursor), record their locators, replace `window` with the moved marker, `Effect.applied` = the prepended keys in file order.
- `close()`: cancel `tap` and `gapSweep`, finish `effects`; `projection`, `state`, `offsets`, `paths` and `rawRecord` keep answering.

- [ ] **Step 3: Tests**

`IngestionTests`, driving every frame through a synthetic tap: `SyntheticTap` (fileprivate in the test file) wraps `AsyncStream<WireEvent>.makeStream()` with `send(_ frame: Frame, epoch: ProcessEpoch = .first)`, `exited(epoch: ProcessEpoch = .first)` (an `ExitStatus.code(0, stderrTail: "")`) and `finish()` on the continuation, `nextEffect(within: Duration = .seconds(1))` awaits one element of `ingestion.effects` under a bound and fails the test on timeout, so every assertion runs after the actor applied the frame, and `terminated: Bool` is set from the stream continuation's `onTermination` (the consuming task ended its iteration); "send" below means `send` then `nextEffect()`. No test calls `apply`, `mirrorError`, `processExited` or `sweepGaps` — they are internal — and none but the two mirror-gap tests (a 50 ms window, bounded waits) is timing-dependent: a frame sent before `open` is buffered and aligned, a frame sent after it is applied on arrival, and the assertions below hold either way (the `tapAligned` counts are what tell the two paths apart).
- `testRelocationReplaysWithNoDuplicateAndNoMissingRecord` (G3): in a `TempTree`, place `session-mirror-relocation`'s final file at the original slug truncated to `fx.offset(for:)` — 0, because its `streams.json` is empty: the mirror began with the file, so the file starts empty and every one of its fifty-three lines is mirrored — `open` it on a tap, send the recording's `transcript_mirror` frames in order, calling `relocated(mainPath:)` before sending the first frame that names the new path (the moment `set_cwd` answered, in the real flow), then write the complete file at the new path, remove the old one, and call `fileChanged` on the new path. Assert: the main stream's keys equal `RecordKey.keys(for: readAll(final), in: main)` exactly — the repeated `atis-latch` and `relocated` lines included, each with its own ordinal; every applied key has a locator and the locators are distinct; `duplicates == 53`, one per mirrored entry (the file confirmed every one: twenty-eight uuid records by uuid, twenty-five uuid-less by occurrence); `rawRecord` of the last `relocated` key reads through the new path and returns that line. Then the other order under `mirrorPrimary`: the complete file at the new path first and `fileChanged`, then the mirror frames → the same keys, `duplicates == mirrored count` again, no `mirrorGap`.
- `testResumeCarriesTheOffsetAndTheFileClosesTheUnmirroredRecord` (G3): `session-mirror-resume`: place `initial/` content at the path, `open` it on a tap (offset = the `streams.json` value, the file's length), send the three mirror frames (eight records), assert one record is still missing versus `transcript/`, call `fileChanged` after copying the final file over → the `atis-latch` is applied from the file, `duplicates == 8` (matching is per hash and per unclaimed occurrence, so the unmirrored `atis-latch` is one more occurrence of its own content and displaces none of the eight matches), final keys equal `RecordKey.keys(for:in:)` of the file's.
- `testMirrorAloneDrivesTheReducer` (G4): for every fixture in `FixtureCorpus.mirrored` except `session-mirror-resume` and `resume-no-replay`: open on an empty file with a tap, send mirror frames only, never call `fileChanged`; the projection equals `RecordReducer` over the final files (`ProjectionComparison.compare` empty); for `session-mirror-resume` assert the *inequality* (one record short) so the counter-case is stated.
- `testMirrorErrorSwitchesToFileOnlyForTheEpoch` (G4): send C2's `system_mirror_error` sample decoded through `FrameDecoder`, as `.frame(.system(.mirrorError), .first)` → `state == .fileOnly(since: .first)`, one notice recorded, later mirror frames sent under `.first` are ignored (`applied` unchanged), `fileChanged` still applies, and a mirror frame sent under `.first.next()` is applied again with `stateChange == .both`.
- `testMirrorGapUnderMirrorPrimarySwitchesToFileOnly`: `mirrorPrimary` with `mirrorGapWindow: .milliseconds(50)`; open a `TempTree` copy of `plain-two-turn` on a tap, append one line and call `fileChanged` once — no mirror frame, no further call — taking that call's effect from `effects`; then `nextEffect()` alone, bounded → the sweep's effect: no keys, `stateChange == .fileOnly(since: .first)`; `state == .fileOnly(since: .first)` and exactly one `mirrorGap(missing: 1)` notice recorded. The deadline is the actor's; the test advances no clock.
- `testATimelyMirrorClearsThePendingGap`: the same window; append a line and `fileChanged`, then send a mirror frame carrying that record inside the window → `duplicates == 1`; sleep past the window (100 ms), append a second line, `fileChanged`, and send its mirror frame → `state == .both` throughout, no `mirrorGap` notice, and every element `effects` yielded (four: two calls, two frames) has `stateChange == nil` — the sweep that ran at the first window found nothing pending.
- `testARoutedElsewhereMirrorIsCountedNotApplied`: a mirror frame whose `filePath` names another session id.
- `testLazyAgentStreamsOpenFromTheMirror`: `nested-depth-2` mirror-only → three streams present, two agent `metadata` entries set.
- `testProcessExitedReconcilesFromTheFile`: send all but the last two mirror frames of `plain-two-turn`, then `exited(epoch: .first)` on the tap with the complete file in place → the effect applies the missing records, keys equal.
- `testNoticesCarryNoPathsOrPayload`: encode every recorded notice's fields; assert no value contains `/` or a record uuid other than the session id — a shape check.
- `testRawRecordReadsAnAttachmentByLocatorAndAMirrorOnlyMetaRecordFromMemory`: open a `TempTree` copy of `plain-two-turn`; `rawRecord(for:)` of an attachment's key equals the file's line decoded to `JSONValue` and the projection's `HiddenRecord` for it has a locator; send a `transcript_mirror` frame the test builds (`Lossless(fields: TranscriptMirrorFields(...))`) carrying a synthetic `user` record with `isMeta: true` and an invented uuid → `rawRecord` serves it, its `HiddenRecord.locator` is nil; append the same line to the copy and `fileChanged` → the locator is set and `rawRecord` is unchanged; an unknown key throws `RawRecordError.unknownKey`.
- `testRepeatedUUIDLessLinesAreAppliedOnceEach` (G3): `session-mirror-resume`'s final file, whose thirty-six uuid-less lines repeat an `atis-latch`, an `ai-title` and a `relocated` line. Opened whole: the applied uuid-less keys number exactly thirty-six, the locators are distinct, and the projection equals the reducer's over `readAll`. Then mirror-only from an empty file on a tap, sending `transcript_mirror` frames the test builds from the file's own lines in file order (the fixture's bytes, framed as the engine frames them — the recording's three frames carry only its last eight lines), where the old content-only rule dropped every repeat: the same keys and count, `duplicates == 0`; then the file written in place and `fileChanged` → every uuid-less line binds its locator to the mirror's key by occurrence, `duplicates` equals the file's line count, and no new key appears.
- `testAStraddleWithAUUIDAnchorClaimsTheLinesTheOpenRead` (G3): `SyntheticTranscript.queuedTurnLines(turn: 1)` gives `[u1, q1, q2, s1, a1, p1]` — a `user`, two `queue-operation`s, a `file-history-snapshot`, an `assistant`, a `last-prompt`. `TempTree.write` the first five lines (through `a1`); on a fresh tap, *before* `open`, send (without awaiting) one `transcript_mirror` frame whose entries are lines two through six (`q1` … `p1`) — the write-then-emit straddle: the read holds the frame's first four entries, and the frame has a uuid anchor, `a1`, after its three uuid-less ones — then `open`. The first effect: `duplicates == 4` (`q1`, `q2`, `s1` claimed between the read's start and the anchor, `a1` by uuid), `applied == [p1's key]`, and one `tapAligned(claimed: 4, unclaimed: 1)` notice. Append `p1` to the file and `fileChanged` → `duplicates == 1`, `applied` empty. Final: the stream's keys equal `RecordKey.keys(for: readAll(file), in: main)`, every key located exactly once, and `hidden` holds exactly two `queue-operation` records and one `file-history-snapshot`.
- `testAStraddleWithoutAnAnchorClaimsTheLongestMatchingPrefix` (G3): the same six lines; the file holds the first four (through `s1`); the frame sent before `open` is again `q1` … `p1`, so no buffered uuid entry is in the file and the alignment falls to the longest prefix — the frame's first three identities equal the file's last three → `duplicates == 3`, `applied == [a1, p1]` in that order, `tapAligned(claimed: 3, unclaimed: 2)`. Append `a1` and `p1`, `fileChanged` → `duplicates == 2` (`a1` by uuid, `p1` by the earliest unclaimed mirror record of its hash), `applied` empty. The same final assertions.
- `testAReopenMidEpochAlignsWhileFramesKeepArriving` (G3): turn 1's six lines and turn 2's (`queuedTurnLines(turn: 2)`: `u2, q3, q4, s2, a2, p2`) are the write sequence; the file holds turn 1 plus `u2, q3` when a *new* ingestion opens it — C6 re-opening the channel's timeline while the turn runs; the earlier ingestion, closed, plays no part — and its tap already holds one frame `[u2, q3, q4]`. After `open`: `duplicates == 2` (`u2` the anchor, `q3` after it), `applied == [q4]`, `tapAligned(claimed: 2, unclaimed: 1)`. Then, with `open` returned, the frames keep arriving: send `[s2, a2]` → `applied == [s2, a2]`; append `q4, s2` to the file and `fileChanged` → `duplicates == 2`, `applied` empty; send `[p2]` → `applied == [p2]`; append `a2, p2` and `fileChanged` → `duplicates == 2`. Final: keys equal `RecordKey.keys(for: readAll(file), in: main)`, every key located exactly once, `hidden` holds four `queue-operation`s and two `file-history-snapshot`s, and the projection equals `RecordReducer` over `readAll`.
- `testAFileRewriteRebuildsTheStreamAndInvalidatesStaleLocators`: open a `TempTree` copy of `plain-two-turn`; keep the key and locator of an attachment in the first third and of one in the last third; rewrite the copy in three variants, each its own run — a rename-over without its first N lines (new inode; N chosen to drop the first-third attachment), a truncate-and-rewrite in place without those lines (same inode, shorter), and the engine's own shape (same inode, not shorter: through one `r+` descriptor as `performRemoveByUuid` does, truncate at the start of the last-third attachment's line, write the suffix that followed it back in place, then append enough invented records that the length exceeds the old offset; here the first-third attachment survives) — and call `fileChanged` once: exactly one `fileRewritten` notice with the old and new lengths, `state` unchanged, the projection equals `RecordReducer` over `readAll` of the new file, the surviving attachment's `rawRecord` returns its record through its new locator, the dropped attachment's key throws `unknownKey`; and, in a fourth run, without calling `fileChanged` after the rewrite, `rawRecord` of a key whose bytes moved throws `staleLocator`, never another record's `JSONValue`.
- `testLoadEarlierPaginatesToTheRootAndMatchesReadAll`: open a file `TempTree.write` places from `SyntheticTranscript.rewound(turns: 30, paddingBytes: 300_000, rewindAfterTurn: 12, thenTurns: 10)` under the default policy (`earlierAvailable == true`) and capture the main stream's keys — the suffix; call `loadEarlier()` until it returns an empty effect: each effect's `applied` keys are new, prepended and located. After the last call: the suffix keys are unchanged, as a sequence; the prepended `atis-latch` records — one per turn, byte-identical, so their canonical hash straddles every page boundary — carry distinct keys whose ordinals for that hash continue in application order (the suffix's occurrences hold the lowest ordinals, each page back the next ones; the ordinal set for the hash is `0..<n`, n the file's count of that line); `rawRecord` of a prepended `atis-latch` key returns that record through the actor's ordinal (the locator bound at prepend); the final projection equals the reducer's over `readAll` in content — `ProjectionComparison.compare` empty over `items` and `session`, and the multiset of canonical hashes of `hidden` equal — and *not* by `RecordKey` numbering: `RecordKey.keys(for:in:)` over `readAll` numbers occurrences in file order, while the actor numbers in application order (the suffix first, then each page back), which is exactly what keeps a published key stable across a prepend (spec, Decision Log); every record's locator is present exactly once; `window.earlierAvailable == false`; one more call returns an empty effect.
- `testTheWholeWireStreamThroughTheTapYieldsOnlyMirrorEffects`: `session-mirror-relocation`'s complete final file in a `TempTree` at its new slug; `open` it on a tap, then send every `WireEvent` of `FixtureWireReplay.steps(for:)` flattened in `t` order — `assistant`, `user`, `stream_event`, `result`, `.request` and the `transcript_mirror` frames alike, the tap carrying what the fan-out carries — and `finish()`. Collect exactly M effects, M being the test's own count of `transcript_mirror` frames among those events, each bounded: they are the only effects (the count is the assertion — a `receive` that reacted to any other event would yield more, one that dropped mirror frames fewer); `routedElsewhere` sums to 0 (the new-slug path resolves to the same session); `duplicates` sums to 53, every entry claimed against the read as the relocation test's second half already shows; no `applied` key; the projection equals `RecordReducer` over `readAll`; after `close()`, `effects` yields nothing more.
- `testOpenOnAMissingMainFileIsMirrorOnlyUntilTheFileAppears`: `filePrimary`; a `TempTree` whose slug directory exists and holds no file at the synthetic session's main path; `open` on a tap → no throw, `state == .mirrorOnly`, `projection.items` empty, `offsets[main] == 0`; send one `transcript_mirror` frame the test builds from `queuedTurnLines(turn: 1)`'s `u1` and `q1` → `applied.count == 2`, no locator for either (`rawRecord(u1)` served from memory); write the file with `u1`, `q1` and `s1`, `fileChanged` → `duplicates == 2`, `applied == [s1's key]`, `stateChange == .both`, `state == .both`, every key located, and `rawRecord(u1)` now reads through the bound locator (the file's line decoded).
- `testAFailedOpenEndsTheConsumingTaskAndFinishesEffects`: a directory at the main path (the read fails; `fstat` does not); `open` on a tap throws; then `tap.terminated == true` under a bounded wait, iterating `effects` completes with no element, and a frame sent afterwards produces nothing.

Run: `swift test --package-path FleetKit --filter IngestionTests 2>&1 | grep -E "Executed|failed"` → `Executed 20 tests, with 0 failures`.
Demonstrate red: key `applied` by path instead of stream → the relocation test double-applies after the rebind; skip the epoch check in `mirrorError` handling → the epoch test fails on the next-epoch entry; serve `rawRecord` from the locator one line off → the attachment half fails on `uuid`; on the mirror side, treat any applied occurrence of a hash as the duplicate instead of consulting `fileUnclaimed` → the mirror-only half of `testRepeatedUUIDLessLinesAreAppliedOnceEach` drops the repeats, while the relocation and resume tests stay green because the file's delivery re-applies what the mirror dropped — the reason the multiplicity test exists; apply the buffered frames as new records, skipping both `align` and the `fileUnclaimed` claim for them → the three straddle tests fail on their first effect and on multiplicity: each straddled `queue-operation` is applied twice, so the keys exceed `RecordKey.keys(for:in:)` by the straddle and `hidden` carries a `queue-operation` the file does not (the phantom queued item; the projection's last-wins fold of the kind hides it from `session`, which is why the tests assert keys and hidden records), while every other test stays green because none of them sends a frame over content the open read — the reason the three exist; make `align` claim nothing and leave the live `fileUnclaimed` claim in place → the straddle tests' `tapAligned` assertions fail on `claimed: 0` while their multiplicity assertions stay green, which is the live rule being the backstop and the alignment the precise path; skip the `fstat` on `fileChanged` → the rewrite test's projection keeps the dropped lines and the survivor's `rawRecord` throws `staleLocator` where the test expects its record; skip the tail-anchor `pread` → the rewrite test's third variant keeps the removed line and reads the appended records from the stale offset (mid-line), while its first two variants stay green; return an empty effect from `loadEarlier` → the pagination test never reaches offset 0; number prepended ordinals in file order → the pagination test's suffix keys change after the first `loadEarlier`; react to a non-mirror event in `receive` (an effect per `assistant` frame) → the whole-stream test collects more than M effects, and end the consuming task on the first non-mirror event → fewer; treat `ENOENT` at `open` as an error → the missing-file test throws at `open`; leave `tap` running on a failed `open` → the failed-open test's `terminated` stays false and `effects` never finishes; check the gap only inside `fileChanged` (v4's rule) → `testMirrorGapUnderMirrorPrimarySwitchesToFileOnly`'s bounded `nextEffect()` times out, no second call coming; never remove a `pendingFromFile` entry on a mirror claim → `testATimelyMirrorClearsThePendingGap` sees a `mirrorGap` and a `.fileOnly` effect.

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
    // Internal: `candidates: [SessionID: Set<URL>]` — every main file the actor has seen carry the id, filled by `build()` for each
    // file it read and by every `update` for each URL it resolved; an update's survivors are decided over this set.
}
```

`build()`: list `configHome.root/projects/` (top-level directories only); for each slug list its entries and keep `*.jsonl` files whose stem is a UUID (`TranscriptPath.resolve` agrees) and note `<uuid>/` directories for `hasSubagents` (a directory whose name is a UUID and which contains `subagents/`); never descend otherwise; read each file through the `HeadTailReading` in a `withThrowingTaskGroup` bounded to `concurrency`; produce an `IndexEntry` per file (every file read joins `candidates[id]`; when two files carry one id the later `mtime` wins the entry) with the field sources: `cwd` = `lastLineString(tail, type: "relocated", key: "relocatedCwd") ?? firstLineString(head, key: "cwd")`; `gitBranch` = `lastString(tail, "gitBranch") ?? firstString(head, "gitBranch")`; `customTitle` = `lastString(tail, "customTitle")`; `aiTitle` = `lastString(tail, "aiTitle")`; `summary` = `lastString(tail, "summary")`; `agentName` = `lastString(tail, "agentName")`; `tag` = last `tag` line's `tag`; `lastPrompt` = `lastLineString(tail, type: "last-prompt", key: "lastPrompt")`; `firstPrompt` = `firstPrompt(head)`; `clearedToEmpty` = the last `last-prompt` line in the tail has `"leafUuid":null` and `"explicit":true`; `entrypoint` = `firstString(head, "entrypoint")`; `sessionKind` = `firstString(head, "sessionKind")`; `isSidechain` = head contains `"isSidechain":true` before any `"isSidechain":false`; `teamName` = `firstString(head, "teamName")`; `continuedIn` = `lastLineString(tail, type: "continued-in", key: "continuedInSessionId")` parsed as a session id (2.1.258 line 246351: the destination; that line's `sessionId` is this file's own id and is never read for it); `createdAt` = `firstString(head, "timestamp")` parsed; `preview` = `lastPrompt ?? summary ?? firstPrompt ?? ""` truncated to 200 characters; `title` from `TitlePrecedence`; `mtime`/`size` from the read; `turnCount` nil. Emit `TimelineNotice.indexBuilt(files:durationMs:)`.

`update(changed:)`: resolve every URL first, then decide per session id, because two files can carry one id (a later snapshot of a session, or the same session at a new slug after a relocation with the old file not yet gone): for each id named by a `.mainTranscript` URL, take `candidates[id] ∪ named` (the named URLs join `candidates` first), `stat` them all and drop the vanished from the set; none left → `removed` (and the id leaves `candidates`); some left → the entry is rebuilt from the survivor whose `mtime` is latest (ties by the entry's current path) — even when the batch named only the file that vanished and the survivor is an alias only the build saw, `updated` when the id had an entry — whatever order `changed` named the URLs, and even when the entry's old path is now gone — and `added` when it did not; a stamp equal to the entry's (`mtime` and `size`, same path) → skipped. A session is never `removed` and `added` in one update. URLs that resolve to agent files or metadata only flip `hasSubagents` on their session. Emit `indexUpdated(changed:durationMs:)`. Discovery of files whose directory was not named is *not* attempted in `update`; the watcher names directories and the app passes the directory's new files.

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

`TranscriptIndexTests` over a `TempTree` assembled from every fixture's `transcript/` (each fixture under its own slug named after the fixture, agent sidecars included, plus a `memory/MEMORY.md` under one slug and a stray `notes.txt` under another): `testOneEntryPerLogicalSessionAndNothingElse` (entry ids equal the set of main-file session ids in the corpus — fifteen, not seventeen, because `plain-two-turn` and `resume-no-replay` are two snapshots of one session and so are `session-mirror-relocation` and `session-mirror-resume`; the tree adds the two resume fixtures last and sets their copies' modification dates a second later (`setModificationDate`; a `touch` would append a record), so each shared id's entry carries the later snapshot's path, asserted; the memory dir, the text file, the agent files and `.meta.json` produce no entry; `hasSubagents` true for exactly `explore-depth-1` and `nested-depth-2`'s sessions); `testTitlePrecedenceOnTheCorpus` (for each entry, the title equals the test's own precedence walk over a full parse of the file — an independent computation — and `titleSource` names the winning source; at least one entry wins by `aiTitle` and at least one by `firstPrompt`, asserted as a set of sources seen); `testRelocatedCwdOverridesTheRecordedOne` (the relocation session's `cwd` equals the `relocatedCwd` of its last `relocated` record, not the head's `cwd`); `testUpdateReReadsOnlyChangedFiles` (a counting `HeadTailReading` wrapper: after `build`, `touch` one file and `update(changed:)` with three URLs → reads == 1, `updated == [that id]`; remove a file → `removed`; add a copied file under a new UUID name → `added`); `testClearedToEmptyIsReadFromTheTail_mutation` (append a cleared `last-prompt` line to a copy); `testSnapshotRoundTripsThroughStorage` (`InMemoryIndexStorage`: `persist` then a new index's `loadPersisted` equals); `testNoDropRuleIsApplied` (an entry whose head says `"entrypoint":"sdk-cli"` — every fixture, since the harness is sdk-cli — is present with `entrypoint == "sdk-cli"`); `testALaterSnapshotOfASessionUpdatesItsEntry` (build with `plain-two-turn`'s file only; copy `resume-no-replay`'s file over it and `update(changed:)` → `updated == [id]`, `added` empty, the entry's `size` is the later file's); `testRelocationToANewSlugUpdatesThePathNeverRemovesAndAdds` (build with `session-mirror-relocation`'s file under the old slug; move it to the new slug and call `update(changed: [old, new])`, then in a fresh index `update(changed: [new, old])` → in both orders `updated == [id]`, `removed` and `added` empty, `path` is the new URL); `testWhenTwoFilesCarryOneIdTheLaterMtimeWins` (both slugs hold a copy, the new one touched later; `update(changed: [old, new])` and `[new, old]` both leave `path` at the new URL and one `updated`); `testDeletingTheWinnerAloneFallsBackToTheSurvivingAlias` (build over old- and new-slug copies of `session-mirror-relocation`'s transcript, the new copy's modification date set later, so the entry's `path` is the new URL; delete only the new file and `update(changed: [new])` → `updated == [id]`, `removed` and `added` empty, `entry(id)` present with `path` at the old URL; then delete the old file and `update(changed: [old])` → `removed == [id]`, `entry(id) == nil`).

Run: `swift test --package-path FleetKit --filter TranscriptIndexTests 2>&1 | grep -E "Executed|failed"` → `Executed 11 tests, with 0 failures`.
Demonstrate red: make `update` re-read every named file regardless of stamps → `testUpdateReReadsOnlyChangedFiles` fails at reads == 3; make `cwd` ignore `relocated` → the relocation test fails; in `build`, keep the earlier-`mtime` file when two carry one id → the entry-count test fails on the shared ids' paths (the entry map is keyed by `SessionID`, so a path-keyed build cannot compile); emit `removed` when an id's named file is gone without stat-ing its other files → `testRelocationToANewSlugUpdatesThePathNeverRemovesAndAdds` fails in its `[old, new]` order with `removed == [id]`, while the two-file test, whose files both exist, stays green; when both files exist, rebuild from the file named last instead of the later `mtime` → `testWhenTwoFilesCarryOneIdTheLaterMtimeWins` fails in its `[new, old]` order with `path` at the old URL, while the relocation test, with one file left, stays green; decide an update over the named files and the entry's current path alone, forgetting the build's other file → `testDeletingTheWinnerAloneFallsBackToTheSurvivingAlias` fails at its first update with `removed == [id]`, while the two-file test, whose batch names both files, stays green.

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
- `testLargestTranscriptHistoryUnderOneSecond`: pick the entry with the largest `size`; `WindowedTranscript.read(TranscriptReader(url:))` then `RecordReducer.reduce` on it with the marker; print `size=<bytes> records=<n> window=<earlierAvailable> extensions=<e> ms=<t>`; assert < 1000.
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
Expected: `0 failures`, and by name: `testRelocationReplaysWithNoDuplicateAndNoMissingRecord`, `testResumeCarriesTheOffsetAndTheFileClosesTheUnmirroredRecord`, `testNestedDepth2FromTaskFramesAndMirrorMetadata`, `testTwoStepJoinGivesTheSameParentWhenBothAreWithheld`, `testBackgroundShellRowByRow`, `testSnapshotYieldsTheOutputAndTheExitCode`, `testMirrorAloneDrivesTheReducer`, `testMirrorErrorSwitchesToFileOnlyForTheEpoch`, `testAStraddleWithAUUIDAnchorClaimsTheLinesTheOpenRead`, `testAStraddleWithoutAnAnchorClaimsTheLongestMatchingPrefix`, `testAReopenMidEpochAlignsWhileFramesKeepArriving`, `testTheWholeWireStreamThroughTheTapYieldsOnlyMirrorEffects`.

- [ ] **Step 6: X1 and X9 spot checks**

Run: `swift test --package-path FleetKit --filter ImportGraphTests 2>&1 | grep -E "Executed|failed"; git diff main -- FleetKit/Package.swift | grep -E '^[-+][^-+]' | grep -v 'C3' | head`
Expected: `1 test, with 0 failures`; the manifest diff is empty (v1 adds no target) or confined to the C3 region.
X9 is checked by a recursive fingerprint taken before and after the whole suite and reported as counts and digests only — never a path. C1's scratch config home is nobody else's, so any change there is ours; the author's real home is written legitimately by live Claude Code sessions while the suite runs, so for it the check is the count of files modified since the run started whose path carries a name only these tests use.

Before `swift test` (Step 3):
```bash
x9()  { find "$1" -type f -exec stat -f '%m %z %N' {} + 2>/dev/null | sort | shasum -a 256 | cut -c1-16; }
x9n() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }
S=/tmp/afleet-fixtures/config-home; H="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p /tmp/afleet-review && touch /tmp/afleet-review/c3-x9-start
echo "scratch before: files=$(x9n "$S") digest=$(x9 "$S")"
```
After the suite:
```bash
echo "scratch after:  files=$(x9n "$S") digest=$(x9 "$S")"
IDS=$(python3 -c "import json,glob; print('|'.join(json.load(open(f))['session_id'] for f in glob.glob('Fixtures/*/fixture.json')))")
echo "home files touched by test names since start: $(find "$H" -type f -newer /tmp/afleet-review/c3-x9-start 2>/dev/null | grep -c -E "_slug_|_other_|FleetTimelineTests|$IDS")"
```
Expected: the two scratch lines carry the same `files=` and `digest=`, and the last line ends in `0`.
Demonstrate the check itself once, in a scratch config-home-shaped tree under the temporary directory: take the digest, write one file three levels down (`projects/x/y/z.jsonl`), take it again → the two digests differ (a depth-one `find` would have missed it). Quote both digests in the ledger; they are digests of a scratch tree, not paths.

- [ ] **Step 7: The ledger of demonstrations**

Confirm the plan's ledger holds one quoted red run per gate test named in Tasks 1 through 12 (the "Demonstrate red" steps), plus Task 13's own: the fingerprint flip in Step 6. A test without a quoted demonstration is not accepted; write the demonstration now, restore, and only then proceed.

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

1. **Pinned corpus counts.** Tasks 1 and 3 pin 611 file records, 496 mirrored entries, twelve record kinds, fifteen mirrored fixtures and (to be confirmed at execution) nineteen compared streams; Task 1 also pins forty-eight repeated uuid-less lines in thirty groups across fourteen files, and Task 12 pins fifteen logical sessions across seventeen main files. A C1 re-recording moves these; the executor re-pins only after the orchestrator confirms the re-recording, never to make a red run green.
2. **Recomputing the projection on every effect.** `StreamIngestion` re-reduces its streams after each applied batch rather than reducing incrementally. On the corpus and on the local p99 file this is milliseconds; on the 109 MB maximum the bounded window keeps it under the second G2 asks for. Incremental reduction is deliberately not planned; if C6's live rendering needs it, it is a follow-up on C3 with the invariant as its guard.
3. **The orphan-healing constant.** Written as five seconds from parity §35.13; Task 5's executor reads the bundle for the constant and pins it with a line number in the doc comment, and the spec's Delegated unknowns entry is closed in the same commit.
4. **`ItemBuilder` extraction.** Task 8 may extract the shared block-to-item logic from Task 5 into an internal `Reduce/ItemBuilder.swift` so the two reducers cannot drift. Do it if the duplication would exceed a screen; the invariant test is what proves they agree either way.
5. **Ten tests per task is a floor, not a target.** The counts in the "Run" lines are the plan's expectation; an executor who needs one more test to discriminate a rule adds it and reports the new count.
6. **What "closed" means for the bounded window.** The spec's "extended backwards until the leaf path is closed" is given this meaning (Task 2, spec v2.2): the named leaf is inside the window and the window's earliest chain record is a turn start or the file's first record — not that the chain reaches its root, which for a never-rewound file is the whole file and would void the 4 MiB window. Records whose parent lies before an open window are window roots, not orphans. Overrule before Task 2 if the renderer should instead read to the root.
7. **The `WireEventPolicy` pin.** Tasks 8 and 9 consume `WireEventPolicy` from `WireTransport`, on `main` at merge `ca68f2e` (branch commit `f187499`); Task 8's Step 0 preflights `git merge-base --is-ancestor ca68f2e HEAD` and stops if the pin is missing. The five `WireEventPolicyFixtureTests` on `main` are the parity witness between the actor and the function, which agree by construction; no separate parity test is written, because no fake-claude Swift harness exists to drive the actor in-process. C3 still duplicates none of that logic.

## Revision Notes

- 2026-09-05: controller ruling during Task 8, recorded so the departure is not read as an omission.
  Step 2's routing table lists `.system(.status)` among the subtypes that become banners. The
  implementation narrows it: a `status` frame raises a banner only when it carries `compact_error`.
  Upheld, because `Banner.Kind` has no `status` case and the engine emits the frame several times a
  turn, so a banner per status frame would be interface noise rather than information. The narrowing
  is pinned in both directions by `testStatusBannersOnlyWhenACompactionFailed` and stated in a source
  comment at the `.status` arm.

- 2026-09-05: parent amendment applied mid-execution, before Task 4 was dispatched.
  `ProjectionCategories.fileOnlyRecordKinds` (Task 4, Step 2) drops `.system("compact_boundary")`:
  the engine emits the boundary on the wire as a `system` frame of that subtype and mirrors the
  record, so it is not file-only. The rest of the list is unchanged, and no pin, count or checkpoint
  moves — this branch's corpus carries no `compact_boundary` record. Task 5's rule 8 and Task 8's
  `.system(.compactBoundary)` route are unaffected: `.compactBoundary` was never in
  `comparedWireToFile`, so check two's item set does not change.

- 2026-09-05: v5, third Codex pass (spec v2.5; ten findings, nine folded, one half-dismissed by
  the coordinator). Task 10: `receive` states the seam — the tap is one subscription of C4's
  per-subscriber fan-out (`LifecycleAPI.events(of:)`), C6 takes a separate one for the
  `WireReducer`, `open` never receives ClaudeWire's `WireEventStream` — and leaves events that
  are not this actor's alone; `open` on a missing main path is `.mirrorOnly` (offset 0, cursor
  0, no `fileIdentity`) and the first `fileChanged` that finds the file moves to `.both`; an
  error inside `open` cancels `tap` and finishes `effects`; `pendingFromFile` is
  `[LogicalStream: [RecordKey: Date]]`, removed on both mirror-side claim paths, and the gap is
  swept by the actor's own `gapSweep` task through `sweepGaps(at:)` with no file event
  required, cancelled by `close()`; `tailAnchor` (range and SHA-256 of the last file-located
  record's raw line, `pread` before every append read) closes the same-inode, non-shrinking
  rewrite `performRemoveByUuid` produces; `epoch` is tracked. Four tests added — the
  relocation's whole `WireEvent` list through the tap, a missing main file, a failed `open`,
  a timely mirror clearing the gap — the gap test rewritten on the actor's deadline, the
  rewrite test given the engine's in-place variant, the pagination test given identical
  uuid-less lines across every page (Task 2's generators place one `atis-latch` per turn) and
  compared by content, not key numbering; `SyntheticTap` gains a bounded `nextEffect` and
  `terminated`; checkpoint 20. Task 7: `node(_:)` and `node(withToolUse:)` declared, one
  lookup test, checkpoint 10. Task 8: `Overlay` declared in full (with `sessionState:
  SessionStateChanged?`), `.policyAnswered` creates the item with `kind: .other` (Task 4's
  `DecisionItem.Kind` gains `other`), `testDecisionLifecycle` reads `permission-deny`'s `deny`
  as the host's answer and reaches `.policyAnswered` through a constructed unknown-subtype
  request, one `session_state_changed` test, checkpoint 16; the preflight is kept. Task 12:
  `candidates` per session id, one fallback test, checkpoint 11. Task 3's pin is 18 streams;
  Task 5's checkpoint is 15 with the `sourceToolAssistantUUID` mutation in the list under an
  unmatched, not stripped, block id. The floors read 9 + 15 + 15 + 16 + 20 + 11.
- 2026-09-05: v4, coordinator ruling on the open-before-mirror precondition (spec v2.4). Task 10:
  `open(file:events:policy:)` takes the channel's tap, starts consuming it into a buffer before
  the read, settles for `tapSettle` (20 ms default), aligns the buffer against the read's tail
  through the pure `align(buffered:tail:readStart:)` (uuid anchors fix the cursor; uuid-less entries
  between fixed points match by hash in order; no anchor → the longest k with the first k
  buffered identities equal to the tail's last k), seeds `fileUnclaimed` from the cursor and
  applies the rest as mirror entries; `receive(_:)` dispatches later tap events. The per-source
  counters (`fromFile`/`fromMirror`/`ordinalByAppendIndex`) are replaced by `ordinals` plus the
  two unclaimed maps, `fileUnclaimed` and `mirrorUnclaimed`, which state the same rule as
  sets: a uuid-less delivery claims the other side's earliest unclaimed record of its hash or
  is new. `apply(mirror:)`, `mirrorError` and `processExited` are internal; `effects`,
  `close()` and `TimelineNotice.tapAligned` are added; the precondition sentence is gone from
  the `apply(mirror:)` row. Every Task 10 test drives frames through a `SyntheticTap`; three
  tests are added — an anchored straddle, an unanchored one, and a re-open mid-epoch while
  frames keep arriving — over `SyntheticTranscript.queuedTurnLines(turn:)`, which Task 2 Step 5
  now declares. Task 10's checkpoint is `Executed 16 tests`; the floors read 9 + 15 + 14 + 15 +
  16 + 10. Two more deliberate breaks: applying the buffer without the alignment (the phantom
  queued item), and an `align` that claims nothing (caught by the `tapAligned` counts alone).
  Produces line: `IngestionEffect` corrected to `Effect`, the nested type both documents declare. Task 13 Step 5's by-name list names the three straddle tests.
- 2026-09-05: v3, declaration audit before the third review (no design change; test floors unchanged at 9 + 15 + 14 + 15 + 13 + 10). `SyntheticTranscript` declared (Task 2, Step 5: `File` with `ranges`, `linear(turns:paddingBytes:leafTurn:)`, `rewound(turns:paddingBytes:rewindAfterTurn:thenTurns:)`), having been used in Tasks 2 and 10 without a declaration; `TempTree` gains `add(_:slug:)`, `write(_:session:slug:)` and `setModificationDate(_:_:)`, which Tasks 10 and 12 needed; `WindowMarker` moved in the file list to the reader, where Task 2 declares it; `FixtureCorpus.Fixture.offset(for:)` defined for a path `streams.json` does not name. Task 10: `duplicates` counts a re-delivered uuid record on the file side too; the relocation test opens an empty file (its `streams.json` is empty) and expects fifty-three duplicates, one per mirrored entry; the multiplicity test no longer feeds a mirror over content the open already read — the matching rule's precondition (open before the epoch's first mirror entry, at an offset no later than that entry) is stated beside the rule and in the spec — and builds its whole-file mirror frames from the file's lines. Demonstrate-red passes: Task 1's ordinal break now falls to the multiplicity test alone; Tasks 2, 5 and 8 name breaks for the tests v3 added; Task 10's hash-alone break is narrowed to the mirror side and its `fstat` break says `staleLocator`; Task 12's type-impossible break is replaced and its URL-order break split so each of the two update tests has its own.
- 2026-09-05: v3, after the Codex adversarial review of v2 (eight findings, all verified real and accepted, each shaped by a coordinator ruling), against spec v2.3 and a merge of `main` at `ca68f2e` (C2's `WireEventPolicy` corrective; the fixture set is still eighteen). Task 1: `RecordKey.Identity.hash(_:ordinal:)` with the ordinal assigned in application order by `RecordKey.keys(for:in:)` or the ingestion, grounded in `vbr` (line 429460: state kinds are never deduplicated); `TranscriptRecord.contentHash` and `key(in:ordinal:)`; the `continued-in` accessor reads `continuedInSessionId` (line 246351); the vocabulary is thirty-eight kinds, thirty-three state, and the test asserts the exact `dts` dictionary against its own transcription, `progress` folded `boundary-cleared`; a multiplicity test pinning forty-eight repeats in thirty groups across fourteen files and a schema-derived `continued-in` mutation test with invented ids. Task 2: `ByteRange` and `ReadResult.ranges` declared here, stream-less; `WindowPolicy` takes a memberwise initialiser with defaults (the declared `init()` suppressed it and `.whole` did not compile); `WindowedTranscript.readEarlier(_:held:window:policy:)` and `SyntheticTranscript.rewound` for the pagination test. Task 3: both sides keyed by `RecordKey.keys(for:in:)`. Task 4: `RecordLocator {stream, range}` wraps Task 2's range. Task 5: `continued-in` sets `session.continuedIn` from the destination id, with a mutation test. Task 8: the C2 dependency is a pin — `ca68f2e`, `f187499`, the file and its API — with a Step 0 preflight; the replay threads a `WireEventPolicy.Context`, populates `pendingOutbound` for host-written requests, applies state effects, keeps only `.publish`, and two tests pin the echo drop, the correlated error-body settlement and the cancel behaviours; the five `WireEventPolicyFixtureTests` are the parity witness. Task 10: file order for `records`, `fileIdentity` captured at open, the rewrite arm on `fileChanged` (shorter length or changed `(st_dev, st_ino)` → rebuild whole, `TimelineNotice.fileRewritten`, `State` unchanged), per-source occurrence matching of appends by hash, `rawRecord` verified against the key with `RawRecordError.staleLocator`, `loadEarlier()` as the C6 contract behind *Load earlier*; the relocation test rewritten from the `streams.json` offset with distinct locators and a `rawRecord` through the new path, the resume test's `duplicates == 8` re-derived, and three tests added (multiplicity, rewrite in both variants, pagination to the root). Task 12: `continuedIn` from `continuedInSessionId`; `update(changed:)` decides per session id with the later `mtime` winning in either order; fifteen logical sessions pinned and three update tests added. Questions 1 and 7 updated. Test floors: 9 + 15 + 14 + 15 + 13 + 10 across the touched tasks.
- 2026-09-05: v2, after the Codex adversarial review of v1 (eight findings, all accepted, two shaped by the coordinator's rulings) and a merge of `main` (C2's fork-point flags, X5's pane-request id, C1's rewind and compaction scenarios with recordings pending; the fixture set is still eighteen). Task 1: uuid-less records key by the SHA-256 of the line's canonical JSON computed at decode, never a `JSONEncoder` re-encoding, with a key-order test. Task 2: `WindowedTranscript.read` owns the window's closure with the turn-start rule (Questions 6), a `>8 MiB` synthetic-transcript test, and `read(at:length:)` plus per-record locators. Task 4: `ToolCallItem` stores `rawInput` and computes `input` (`ToolInput` is not Codable on main); `HiddenRecord` with a `Reason` and a `RecordLocator` replaces bare keys. Task 5: window roots are not orphans; hidden records carry locators. Tasks 6, 7, 8: `tool_progress` routed to the registry and the tree; agent transcript paths computed from the tree's current slug with `relocate(slug:)` and `HostSignal.relocated(mainPath:)`. Tasks 8, 9: the fixture replay goes through C2's `WireEventPolicy` (a corrective the coordinator dispatches; Questions 7), resume fixtures are seeded from `initial/`, all eighteen fixtures are compared with a per-name pinned outcome, and the reducer takes a `seed`. Task 10: `rawRecord(for:)` and `paths`. Task 13: the X9 check is a recursive before-and-after fingerprint reported as counts and digests. Test floors: 14 + 5 + 13 + 11 + 9 + 13 + 10 across the touched tasks.
- 2026-09-05: v1, written from spec v2 at parent-pin `ee94449`. Thirteen tasks; the record model and reader first, the invariant's first check at Task 3 and its second at Task 9, the index and its opt-in measurement last, as ruled.
