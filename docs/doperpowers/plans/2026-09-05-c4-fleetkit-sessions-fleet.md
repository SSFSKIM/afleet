# C4: FleetKit Sessions and Fleet Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use doperpowers:subagent-driven-execution to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `FleetSessions` module of the `FleetKit` package: channel origins and holder detection, the ownership protocol, the lifecycle table with dormant eligibility, respawn, adopt, send-to-background, the terminal hatch as a pane request, the quiescent restart, the wedged state and the cap, the spawn preconditions with the one §6.12 write, the Activity query, the command router with `/logout`, the namespaced store, and a live gate against the installed CLI that also widens the config-home write allowlist.

**Architecture:** One SwiftPM target, `FleetSessions`, inside the `FleetKit` package whose manifest skeleton is already on `main`, depending on `FleetTimeline`, `ClaudeWire` and `AfleetCore`. `ChannelSupervisor` is an actor per channel that reaches its process through a `ProcessHandle` seam (`ClaudeProcess` conforms) and drives a constant `LifecycleTable` with every timer on an injected `Clock`. `FleetObserver` is an actor per ConfigHome that reads the registry, the job roster and `claude agents --json` and reconciles holders by pid. `Fleet` is the facade that owns supervisors, the observer, the store, the preconditions and the router and implements the X5 `LifecycleAPI`. Tests drive real `fake-claude` replays for every lifecycle row a real child can produce, a scripted handle for the one row it cannot, scripted registry and job files, and an in-process scripted `ProcessRunner` for CLI verbs.

**Tech Stack:** Swift 6.3.3, Swift Package Manager (`swift-tools-version: 6.2`, language mode 6, `platforms: [.macOS(.v26)]`), Foundation (`Process`, `FileManager`, `DispatchSource` vnode sources, `JSONDecoder`/`JSONEncoder`), Darwin (`kill`, `proc_pidinfo`, `open` with `O_NOFOLLOW`, `fsync`, `rename`, `openpty`), XCTest, `Tools/fake-claude/fake-claude` (Python 3) with the fixtures under `Fixtures/`, and the installed `claude` for the live gate under `/tmp/afleet-fixtures/config-home`.

**Spec:** `docs/doperpowers/specs/2026-09-05-c4-fleetkit-sessions-fleet.md` v2.1 (child of `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C4`, parent-pin `ee94449`; the parent's §6.11, §6.12, §7.1, §7.2, §7.4, §7.6, §7.7, §7.8 and §17.5 X1, X2, X3, X5, X6, X9, X10 bind this work, X5 and X6 as amended on 2026-09-05). Conflicts found during execution resolve against the spec; a wrong binding clause flows back to the parent as `[parent-impact]`, never a local override.

## Global Constraints

- One package: `FleetKit/` at the repository root, manifest `FleetKit/Package.swift` already on `main`. C4 owns the manifest and never edits inside the region between `// MARK: - C3 timeline group` and `// MARK: - end of C3 group`. `FleetSessions` depends on `FleetTimeline`, `ClaudeWire` and `AfleetCore` and imports nothing above them (parent X1); an import-grep test enforces it.
- `// swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, every target `swiftSettings: [.swiftLanguageMode(.v6)]`; strict concurrency from the first commit; no `@preconcurrency` imports.
- Every public type is `Sendable`; nothing is `@MainActor`. Actors: `ChannelSupervisor`, `FleetObserver`, `FileStateStore`, `Fleet`. `@unchecked Sendable` only where a type is a single-owner box whose state is reachable from one place that serialises every access, and the declaration says which mechanism (parent §17.7).
- Public initialisers on every value a downstream package constructs.
- `swift test --package-path FleetKit` passes after every task; `swift test --package-path ClaudeWire` and `--package-path AfleetCore` are untouched by this work and must still pass at the end.
- Nothing in `FleetSessions` or its tests writes under any Claude Code config home (`~/.claude`, `$CLAUDE_CONFIG_DIR`, `/tmp/afleet-fixtures/config-home`); the spawned `claude` may. The one project write is `LocalSettingsStore.decline` under the parent's §6.12 policy, exercised only under a temporary directory in tests (parent X9).
- Tests touch only processes they start themselves; never a session in the user's terminal; adoption is exercised only on jobs the test started (root `CLAUDE.md`).
- Live tests run only with `AFLEET_LIVE_CLI=1` and skip with a named reason otherwise; the two turn-spending scenarios also need `AFLEET_LIVE_CLI_TURNS=1`; every live scenario runs C2's budget check first and skips when a window is spent.
- The lifecycle table is data (`LifecycleTable.Row`, one case per parent §7.4 row) and G1's coverage is asserted by set equality over the rows, never by a count.
- Every timer is driven by the injected `any Clock<Duration>`; no test sleeps on wall time to move the lifecycle; no instant comparisons in `FleetSessions` (durations are slept, recency is a sequence counter).
- The discriminating-test rule of parent §17.7 applies to every gate test: each test in this plan names the deliberate break that demonstrates it red, and the executor performs that break once before accepting the test green.
- Assertions and diagnostics print identifiers, counts and shapes: a session id, a pid, a row name, a set of key names or relative paths. Never a filesystem path under a config home, an environment, a record's contents or a process table (parent §6.3).
- The `FleetSessions` target reads C3's mirror only through the `TaskMirrorReading` protocol defined in Task 2; C3's real types replace the stand-in in Task 11.
- Commit after every task with a plain message; no attribution trailers.

---

## File Structure

```
FleetKit/
  Package.swift                                  (on main; C4 edits only outside C3's region; no change planned)
  Sources/FleetSessions/
    Store/StateStore.swift                       StateStore, StoreNamespace, StoreError
    Store/FileStateStore.swift                   the per-namespace JSON document store
    Store/FleetKitState.swift                    the fleetKit namespace's Codable values and keys
    Types/ChannelState.swift                     ChannelKey, ChannelState, Presence, ChannelBanner, HeaderNote, EscalationTrace, DesiredOwnership
    Types/Actions.swift                          LifecycleAction, SpawnPrecondition, ProjectMCPServer, RestartRequest, RestartSnapshot, LifecycleError
    Types/Panes.swift                            PanePurpose, PaneRequest, PaneExit, JobShort
    Types/LifecycleAPI.swift                     the X5 protocol
    Lifecycle/LifecycleTable.swift               Row (CaseIterable), the transition table, TransitionEvent
    Lifecycle/DormantEligibility.swift           the pure function, TaskMirrorReading, MirrorEntryStandIn
    Lifecycle/ListingPolicy.swift                the sidebar listing rules over C3's index fields
    Lifecycle/ProcessHandle.swift                ProcessHandle protocol, ProcessFactory, ClaudeProcess conformance
    Lifecycle/ChannelSupervisor.swift            the actor
    Lifecycle/RestartSnapshot.swift              snapshot and Readback
    Fleet/Records.swift                          RegistryRecord, RosterRecord, JobRecord, AgentsRow
    Fleet/HolderReader.swift                     HolderReader protocol, FileHolderReader, ProcessLiveness
    Fleet/FleetObserver.swift                    the actor: watcher, poll, reconciliation, HolderSet publication
    Fleet/OriginResolver.swift                   holders + supervisor state -> ChannelOrigin and Presence
    Ownership/OwnershipCheck.swift               beforeSpawn, afterHandshake, awaitRelease
    Verbs/CLIVerbs.swift                         over ProcessRunner
    Preconditions/TrustReader.swift
    Preconditions/ProjectMCPConsent.swift
    Preconditions/LocalSettingsStore.swift       the §6.12 write
    Preconditions/ManagedSettingsReader.swift
    Preconditions/SpawnPreconditions.swift
    Router/RouterTable.swift                     LocalCommand, the §7.7 table as data, LaunchSettingMatrix
    Router/CommandRouter.swift                   route(), RefusalInterceptor
    Router/LogoutPlan.swift
    Activity/ActivityQuery.swift
    Diagnostics/FleetDiagnostics.swift           FleetDiagnosticEvent, FleetDiagnosticsSink, FileFleetDiagnostics
    Fleet.swift                                  the facade implementing LifecycleAPI
  Tests/FleetSessionsTests/
    Support/ScratchConfigHome.swift              a temporary config home with sessions/, jobs/, daemon/, .claude.json
    Support/ScriptedHolderFiles.swift            writes registry, roster and job records
    Support/ScriptedProcessRunner.swift          argv-pattern -> (stdout, exit), with file mutations
    Support/TestClock.swift                      a manual Clock
    Support/FakeClaudeLaunch.swift               LaunchConfiguration + ResolvedEnvironment for a fixture replay
    Support/ScriptedProcessHandle.swift          the handle for the wedged row
    Support/RecordingHolderReader.swift          records beforeSpawn/afterHandshake calls
    StoreTests.swift                             Task 1
    LifecycleTableTests.swift, DormantEligibilityTests.swift, ListingPolicyTests.swift   Task 2
    RecordsTests.swift, HolderReaderTests.swift, FleetObserverTests.swift, CLIVerbsTests.swift   Task 3
    LifecycleRowTests.swift                      G1, accumulated over Tasks 4-6
    PreconditionTests.swift                      G3, Task 7
    RouterTests.swift, LogoutPlanTests.swift     G4, Task 8
    ActivityQueryTests.swift, ImportGraphTests.swift, FleetFacadeTests.swift   Task 9
    LiveFleetTests.swift                         G5, Task 10
```

Dependency order: Task 1 (store) → Task 2 (types, table, eligibility, listing) → Task 3 (records, holder reader, observer, verbs) → Task 4 (supervisor core, first G1 rows) → Task 5 (handoffs, foreign, contended, wedged, cap) → Task 6 (restart, fork) → Task 7 (preconditions) → Task 8 (router, logout) → Task 9 (activity, diagnostics, facade, import graph) → Task 10 (live gate) → Task 11 (after C3 lands: G2 and IndexStorage) → Task 12 (final verification).

---

### Task 1: The store (contract X6)

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Store/StateStore.swift`
- Create: `FleetKit/Sources/FleetSessions/Store/FileStateStore.swift`
- Create: `FleetKit/Sources/FleetSessions/Store/FleetKitState.swift`
- Delete: `FleetKit/Sources/FleetSessions/FleetSessions.swift` (the placeholder; the target now has real sources)
- Delete: `FleetKit/Tests/FleetSessionsTests/Placeholder.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/StoreTests.swift`

**Interfaces:**
- Consumes: `AfleetCore.SessionID`, `AfleetCore.ConfigHome`.
- Produces: `StateStore`, `StoreNamespace`, `StoreError`, `FileStateStore`, `FleetKitState` and its keys; Tasks 4, 6, 7, 8 and 9 persist through them; Task 11 implements C3's `IndexStorage` over `FileStateStore`.

- [ ] **Step 1: Write the failing tests**

`FleetKit/Tests/FleetSessionsTests/StoreTests.swift`:

```swift
import XCTest
import AfleetCore
@testable import FleetSessions

final class StoreTests: XCTestCase {
    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("afleet-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    struct Pins: Codable, Equatable, Sendable { var sessions: [SessionID] }

    func testWriteThenReadRoundTripsAndDottedKeysAreOrdinary() async throws {
        let store = FileStateStore(baseDirectory: try tempDir())
        let pins = Pins(sessions: [SessionID(), SessionID()])
        try await store.write(pins, namespace: .fleetKit, key: "pins")
        try await store.write("tabs", namespace: .workbench, key: "workbench.browser")
        try await store.write(3, namespace: .workbench, key: "workbench.panel.ab12cd34.\(SessionID())")
        let back = try await store.read(Pins.self, namespace: .fleetKit, key: "pins")
        XCTAssertEqual(back, pins)
        let keys = try await store.keys(in: .workbench)
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.contains("workbench.browser"))
        XCTAssertTrue(keys.contains { $0.hasPrefix("workbench.panel.ab12cd34.") })
        // Deliberate break: split keys on "." into a hierarchy -> the two workbench keys collide or nest and the count or the prefix check fails.
    }
    func testEachNamespaceIsItsOwnDocumentWithASchemaVersion() async throws {
        let dir = try tempDir(); let store = FileStateStore(baseDirectory: dir)
        try await store.write(1, namespace: .fleetKit, key: "a")
        try await store.write(2, namespace: .afleet, key: "b")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(Set(names), ["state.fleetKit.json", "state.afleet.json"])
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("state.fleetKit.json"))) as? [String: Any]
        XCTAssertEqual(doc?["schemaVersion"] as? Int, FileStateStore.schemaVersion)
        XCTAssertEqual(Set((doc?["values"] as? [String: Any])?.keys ?? []), ["a"])
        // Deliberate break: write one document for all namespaces -> the file set is wrong.
    }
    func testAWriteIsAtomicNoPartialDocumentIsEverVisible() async throws {
        let dir = try tempDir(); let store = FileStateStore(baseDirectory: dir)
        try await store.write(Array(repeating: "x", count: 10_000), namespace: .fleetKit, key: "big")
        // The temporary file is written beside the document and renamed; after the write nothing but the document remains.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(Set(names), ["state.fleetKit.json"])
        // Deliberate break: write the document in place with `Data.write(to:)` and leave the staging name -> a second entry appears.
    }
    func testANewerSchemaVersionIsRefusedNotRewritten() async throws {
        let dir = try tempDir()
        let newer = #"{"schemaVersion": 999, "values": {"k": 1}}"#
        try Data(newer.utf8).write(to: dir.appendingPathComponent("state.fleetKit.json"))
        let store = FileStateStore(baseDirectory: dir)
        do { _ = try await store.read(Int.self, namespace: .fleetKit, key: "k"); XCTFail("read a document from the future") }
        catch let e as StoreError { guard case .schemaTooNew(found: 999, supported: FileStateStore.schemaVersion) = e else { return XCTFail("\(e)") } }
        do { try await store.write(2, namespace: .fleetKit, key: "k"); XCTFail("rewrote a document from the future") }
        catch let e as StoreError { guard case .schemaTooNew = e else { return XCTFail("\(e)") } }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("state.fleetKit.json"), encoding: .utf8), newer)
        // Deliberate break: ignore schemaVersion on read -> the first `do` block does not throw.
    }
    func testABaseDirectoryInsideAConfigHomeIsRejectedAtConstruction() throws {
        let home = try tempDir()
        XCTAssertThrowsError(try FileStateStore.validated(baseDirectory: home.appendingPathComponent("afleet"), configHomes: [home])) { e in
            guard case StoreError.insideConfigHome = e as? StoreError ?? .io("") else { return XCTFail("\(e)") }
        }
        XCTAssertNoThrow(try FileStateStore.validated(baseDirectory: try tempDir(), configHomes: [home]))
        // Deliberate break: compare paths without resolving symlinks and pass a /tmp vs /private/tmp pair -> the first assertion fails to throw.
    }
    func testRemoveDeletesOneKeyAndLeavesTheRest() async throws {
        let store = FileStateStore(baseDirectory: try tempDir())
        try await store.write(1, namespace: .fleetKit, key: "a"); try await store.write(2, namespace: .fleetKit, key: "b")
        try await store.remove(namespace: .fleetKit, key: "a")
        XCTAssertEqual(try await store.keys(in: .fleetKit), ["b"])
        XCTAssertNil(try await store.read(Int.self, namespace: .fleetKit, key: "a"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit 2>&1 | tail -5`
Expected: build error `cannot find 'FileStateStore' in scope`.

- [ ] **Step 3: Implement the store**

`FleetKit/Sources/FleetSessions/Store/StateStore.swift`:

```swift
import Foundation

public struct StoreNamespace: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fleetKit = StoreNamespace(rawValue: "fleetKit")
    public static let workbench = StoreNamespace(rawValue: "workbench")
    public static let afleet = StoreNamespace(rawValue: "afleet")
}

public enum StoreError: Error, Equatable, Sendable {
    case schemaTooNew(found: Int, supported: Int)
    case insideConfigHome
    case emptyKey
    case io(String)                      // the underlying error's description; never a path
}

/// X6. Keys are non-empty strings; a dot is an ordinary character and implies no hierarchy.
/// One schema version per namespace; nothing else is versioned.
public protocol StateStore: Sendable {
    func read<T: Codable & Sendable>(_ type: T.Type, namespace: StoreNamespace, key: String) async throws -> T?
    func write<T: Codable & Sendable>(_ value: T, namespace: StoreNamespace, key: String) async throws
    func remove(namespace: StoreNamespace, key: String) async throws
    func keys(in namespace: StoreNamespace) async throws -> [String]
}
```

`FleetKit/Sources/FleetSessions/Store/FileStateStore.swift` — decisions the executor implements:

- `public actor FileStateStore: StateStore` with `public init(baseDirectory: URL)` (creates the directory with mode 0o700 if absent) and `public static func validated(baseDirectory: URL, configHomes: [URL]) throws -> FileStateStore`, which resolves every path with `URL.resolvingSymlinksInPath()` and throws `StoreError.insideConfigHome` when the base equals or lies under any config home.
- `public static let schemaVersion = 1`. Document path `<base>/state.<namespace>.json`; envelope `{"schemaVersion": 1, "values": {"<key>": <json>}}` encoded with `JSONEncoder` using `.sortedKeys` so a rewrite of unchanged state is byte-identical.
- Values are stored as `JSONValue`-agnostic raw JSON: encode `T` with `JSONEncoder`, decode with `JSONSerialization` into `Any`, and keep the namespace document as `[String: Any]` in memory per namespace; on `read`, re-serialise the value and decode `T`. (No dependency on `WireFrames.JSONValue` here; the store is below the wire.)
- A document whose `schemaVersion` is greater than `schemaVersion` throws `.schemaTooNew` from every operation and is never rewritten. A missing document is an empty namespace.
- Every write: serialise the whole namespace document, write it to `<base>/.state.<namespace>.json.tmp-<uuid>`, `fsync` the descriptor, `rename` over the document, then `fsync` the directory. Any failure removes the temporary file and throws `.io(description)`.
- An empty key throws `.emptyKey`.

`FleetKit/Sources/FleetSessions/Store/FleetKitState.swift`:

```swift
import Foundation
import AfleetCore

/// The fleetKit namespace's own values (parent §7.8). FleetKit never models Workbench or Afleet state.
public enum FleetKitKeys {
    public static let grouping = "sidebar.grouping"            // SidebarGrouping
    public static let unreadCursors = "channels.unread"        // [String: String]  channel key description -> last seen item uuid
    public static let desiredOwnership = "channels.desired"    // [String: DesiredOwnership]
    public static let projectServerAcceptances = "mcp.accepted"   // [ProjectServerAcceptance]
    public static let ownJobShorts = "jobs.own"                // [String]  shorts afleet itself sent to background
    public static let bypassAccepted = "bypass.accepted"       // Bool
    public static let recordedBaseline = "baseline.recorded"   // String  the CLI version the fixtures were recorded on
    public static let lastCensus = "census.last"               // CensusSummary
    public static let timelineIndex = "timeline.index"         // C3's index snapshot, through IndexStorage (Task 11)
}
public struct SidebarGrouping: Codable, Hashable, Sendable {
    public var pinned: [SessionID]; public var sectionOrder: [String]; public var collapsed: Set<String>
    public init(pinned: [SessionID] = [], sectionOrder: [String] = [], collapsed: Set<String> = []) { self.pinned = pinned; self.sectionOrder = sectionOrder; self.collapsed = collapsed }
}
public struct ProjectServerAcceptance: Codable, Hashable, Sendable {
    public var projectRoot: String; public var serverName: String; public var entryHash: String
    public init(projectRoot: String, serverName: String, entryHash: String) { self.projectRoot = projectRoot; self.serverName = serverName; self.entryHash = entryHash }
}
public struct CensusSummary: Codable, Hashable, Sendable {
    public var cliVersion: String; public var takenAt: Date; public var newInboundSubtypes: [String]
    public init(cliVersion: String, takenAt: Date, newInboundSubtypes: [String]) { self.cliVersion = cliVersion; self.takenAt = takenAt; self.newInboundSubtypes = newInboundSubtypes }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:"`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: the namespaced store, one document per namespace"
```

---

### Task 2: X5 value types, the lifecycle table, dormant eligibility, the listing policy

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Types/ChannelState.swift`
- Create: `FleetKit/Sources/FleetSessions/Types/Actions.swift`
- Create: `FleetKit/Sources/FleetSessions/Types/Panes.swift`
- Create: `FleetKit/Sources/FleetSessions/Types/LifecycleAPI.swift`
- Create: `FleetKit/Sources/FleetSessions/Lifecycle/LifecycleTable.swift`
- Create: `FleetKit/Sources/FleetSessions/Lifecycle/DormantEligibility.swift`
- Create: `FleetKit/Sources/FleetSessions/Lifecycle/ListingPolicy.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/LifecycleTableTests.swift`, `DormantEligibilityTests.swift`, `ListingPolicyTests.swift`

**Interfaces:**
- Consumes: from Task 1, nothing yet; from `ClaudeWire`: `ProcessEpoch`, `UserInput`, `PermissionMode`, `SettingSource`, `Worktree`, `ChildEnvironmentOptions`; from `AfleetCore`: `ChannelOrigin`, `SessionID`.
- Produces: every X5 value type exactly as the spec's *Types* block, `LifecycleTable.Row` and `LifecycleTable.rows`, `DormantEligibility.evaluate`, `TaskMirrorReading`, `MirrorEntryStandIn`, `ListingPolicy.include`; Tasks 4–9 build on them.

- [ ] **Step 1: Write the failing tests**

`LifecycleTableTests.swift` pins the table as data:

```swift
import XCTest
@testable import FleetSessions

final class LifecycleTableTests: XCTestCase {
    func testTheTableHasOneRowPerParentRowAndEveryRowIsReachable() {
        // The parent's §7.4 table, in its order. Set equality over names, not a count.
        let expected: Set<LifecycleTable.Row> = [
            .archivedRecentOpened, .archivedOlderOpened, .archivedOlderSent,
            .connectingClean, .connectingFoundHolder,
            .readyDormantEligible, .dormantSent, .dormantHolderAppeared,
            .terminateExhausted, .exitedNonZero, .capReached,
            .jobAdopt, .ownedSendToBackground, .ownedOpenInTerminal, .ownTabExited,
            .foreignRecordGone, .foreignSendRefused, .handoffTimedOutOrDisagree, .contendedSettled,
        ]
        XCTAssertEqual(Set(LifecycleTable.Row.allCases), expected)
        XCTAssertEqual(Set(LifecycleTable.rows.map(\.row)), expected)
        // Deliberate break: drop `.terminateExhausted` from `rows` -> the second assertion names it.
    }
    func testEveryRowNamesAFromStateAnEventAndAToState() {
        for r in LifecycleTable.rows {
            XCTAssertFalse(r.from.isEmpty, "\(r.row)"); XCTAssertFalse(r.to.isEmpty, "\(r.row)")
        }
    }
}
```

`DormantEligibilityTests.swift`:

```swift
import XCTest
import WireFrames
@testable import FleetSessions

final class DormantEligibilityTests: XCTestCase {
    func base() -> DormantEligibility.Input {
        .init(turnRunning: false, pendingDecisions: 0, queuedInput: 0, mirror: [], lastTaskFrameAge: nil, heartbeatInterval: .seconds(30), wedged: false)
    }
    func testAllFiveConditionsClearMeansEligible() { XCTAssertTrue(DormantEligibility.evaluate(base()).isEligible) }
    func testEachConditionAloneBlocks() {
        var i = base(); i.turnRunning = true; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.turnRunning))
        i = base(); i.pendingDecisions = 1; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.pendingDecision))
        i = base(); i.queuedInput = 1; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.queuedInput))
        i = base(); i.mirror = [MirrorEntryStandIn(taskID: "t1", isRunning: true, isBackground: true)]; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskRunning("t1")))
        i = base(); i.lastTaskFrameAge = .seconds(31); XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskStateUncertain))
        // Deliberate break for the last: compare age < interval instead of > -> `.blocked(.taskStateUncertain)` is not produced.
    }
    func testAnOldTaskFrameWithinTheHeartbeatIsNotUncertain() {
        var i = base(); i.lastTaskFrameAge = .seconds(29); XCTAssertTrue(DormantEligibility.evaluate(i).isEligible)
    }
    func testAWedgedChannelIsNeverEligible() {
        var i = base(); i.wedged = true; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.wedged))
        // Deliberate break: remove the wedged check -> eligible, and the cap in Task 5 would evict a ghost.
    }
}
```

`ListingPolicyTests.swift` enumerates each rule with an entry that exercises it and its negation:

```swift
import XCTest
@testable import FleetSessions

final class ListingPolicyTests: XCTestCase {
    func entry(entrypoint: String? = "cli", kind: String? = nil, sidechain: Bool = false, team: String? = nil, continuedIn: String? = nil) -> ListingPolicy.IndexEntry {
        .init(sessionID: "s", entrypoint: entrypoint, sessionKind: kind, isSidechain: sidechain, teamName: team, continuedIn: continuedIn)
    }
    func testOwnSDKCLISessionsAreListed()          { XCTAssertEqual(ListingPolicy.include(entry(entrypoint: "sdk-cli")), .listed(.ownedCandidate)) }
    func testSidechainsAreNotListed()              { XCTAssertEqual(ListingPolicy.include(entry(sidechain: true)), .excluded(.sidechain)) }
    func testContinuedTranscriptsFoldIntoTheirContinuation() { XCTAssertEqual(ListingPolicy.include(entry(continuedIn: "s2")), .excluded(.continuedIn("s2"))) }
    func testTeammateTranscriptsAreListedReadOnly() { XCTAssertEqual(ListingPolicy.include(entry(team: "alpha")), .listed(.readOnly(.teammate))) }
    func testEverythingElseIsListed()              { XCTAssertEqual(ListingPolicy.include(entry()), .listed(.ownedCandidate)) }
    func testTheRulesAreEnumerableForTheSidebar()  { XCTAssertEqual(ListingPolicy.rules.map(\.name), ["own-sdk-cli", "sidechain", "continued-in", "teammate", "default"]) }
    // Deliberate break for each: invert the rule -> its test names the wrong verdict.
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit 2>&1 | tail -5`
Expected: build errors naming `LifecycleTable`, `DormantEligibility`, `ListingPolicy`.

- [ ] **Step 3: Implement the value types**

`Types/ChannelState.swift`, `Types/Actions.swift`, `Types/Panes.swift`, `Types/LifecycleAPI.swift`: exactly the spec's *Types* block (`ChannelKey`, `DesiredOwnership`, `Holder`, `HolderSet`, `ChannelState`, `Presence`, `ForeignPresence`, `EscalationTrace`, `SpawnPrecondition`, `ProjectMCPServer`, `LifecycleAction`, `RestartRequest`, `RestartSnapshot`, `AgentsRow` goes to Task 3, `JobShort`, `PanePurpose`, `PaneRequest`, `PaneExit`, `LifecycleAPI`), each with a public memberwise initialiser written out. Additions the spec names in prose:

```swift
public enum ChannelBanner: Hashable, Sendable {
    case releasedToTerminal                       // "Opened in your terminal; afleet released this session"
    case contended(HolderSet)
    case settingDidNotSurvive(String)             // the setting's name
    case mcpDeclineRefused(String)                // the reason word: unparseable, symlink, foreignUID, insideConfigHome, writeFailed
    case managedSettingsPending
    case untrusted
    case heldElsewhere(HolderSet)                 // send refused; Fork offered
}
public enum HeaderNote: Hashable, Sendable { case projectServersOff, capReached(live: Int) }
public enum LifecycleError: Error, Hashable, Sendable {
    case heldElsewhere(HolderSet)
    case capReached(live: Int)
    case precondition(SpawnPrecondition)
    case wedged(EscalationTrace)
    case handoffTimedOut(HolderSet)
    case declineRefused(reason: String)
    case notOwned
    case verbFailed(verb: String, exitCode: Int32)
}
```

`RestartRequest` uses double optionals as the spec shows; document on each: outer `nil` = keep the current value, inner `nil` = the CLI default.

- [ ] **Step 4: Implement the table, eligibility and listing policy**

`Lifecycle/LifecycleTable.swift`:

```swift
import Foundation

/// The parent's §7.4 table as data. `Row` is the coverage key G1 asserts over; `rows` is what the supervisor
/// consults before every transition, so a transition not in the table is a diagnostic, never a silent change.
public enum LifecycleTable {
    public enum Row: String, CaseIterable, Hashable, Sendable {
        case archivedRecentOpened, archivedOlderOpened, archivedOlderSent
        case connectingClean, connectingFoundHolder
        case readyDormantEligible, dormantSent, dormantHolderAppeared
        case terminateExhausted, exitedNonZero, capReached
        case jobAdopt, ownedSendToBackground, ownedOpenInTerminal, ownTabExited
        case foreignRecordGone, foreignSendRefused, handoffTimedOutOrDisagree, contendedSettled
    }
    public enum Event: Hashable, Sendable {
        case opened, userSent, handshakeClean, handshakeFoundHolder, dormantTimerFired, holderAppeared
        case terminateReturnedNil, exitedNonZero(code: Int32), seventhSpawnNeeded, adopt, sendToBackground, openInTerminal
        case paneExitedAndRecordGone, recordDisappeared, sendRefused, handoffTimedOut, desiredObservedDisagree, holdersSettled
    }
    public struct Transition: Hashable, Sendable {
        public let row: Row; public let from: Set<StateName>; public let event: Event; public let to: Set<StateName>
        public init(row: Row, from: Set<StateName>, event: Event, to: Set<StateName>) { self.row = row; self.from = from; self.event = event; self.to = to }
    }
    /// The names the table speaks in; `ChannelState.name` maps a state to one of these.
    public enum StateName: String, Hashable, Sendable {
        case archivedRecent, archivedOlder, connecting, ready, dormant, wedged, backgroundJob, foreignUsersTerminal, foreignOwnTab, contended, any
    }
    public static let rows: [Transition] = [
        .init(row: .archivedRecentOpened, from: [.archivedRecent], event: .opened, to: [.connecting]),
        .init(row: .archivedOlderOpened, from: [.archivedOlder], event: .opened, to: [.archivedOlder]),
        .init(row: .archivedOlderSent, from: [.archivedOlder], event: .userSent, to: [.connecting]),
        .init(row: .connectingClean, from: [.connecting], event: .handshakeClean, to: [.ready]),
        .init(row: .connectingFoundHolder, from: [.connecting], event: .handshakeFoundHolder, to: [.foreignUsersTerminal]),
        .init(row: .readyDormantEligible, from: [.ready], event: .dormantTimerFired, to: [.dormant]),
        .init(row: .dormantSent, from: [.dormant], event: .userSent, to: [.ready]),
        .init(row: .dormantHolderAppeared, from: [.dormant], event: .holderAppeared, to: [.foreignUsersTerminal, .backgroundJob]),
        .init(row: .terminateExhausted, from: [.connecting, .ready, .dormant], event: .terminateReturnedNil, to: [.wedged]),
        .init(row: .exitedNonZero, from: [.connecting, .ready, .dormant], event: .exitedNonZero(code: -1), to: [.ready, .archivedOlder]),
        .init(row: .capReached, from: [.ready], event: .seventhSpawnNeeded, to: [.dormant]),
        .init(row: .jobAdopt, from: [.backgroundJob], event: .adopt, to: [.connecting]),
        .init(row: .ownedSendToBackground, from: [.ready, .dormant], event: .sendToBackground, to: [.backgroundJob]),
        .init(row: .ownedOpenInTerminal, from: [.ready, .dormant], event: .openInTerminal, to: [.foreignOwnTab]),
        .init(row: .ownTabExited, from: [.foreignOwnTab], event: .paneExitedAndRecordGone, to: [.connecting]),
        .init(row: .foreignRecordGone, from: [.foreignUsersTerminal], event: .recordDisappeared, to: [.archivedRecent]),
        .init(row: .foreignSendRefused, from: [.foreignUsersTerminal], event: .sendRefused, to: [.foreignUsersTerminal]),
        .init(row: .handoffTimedOutOrDisagree, from: [.any], event: .handoffTimedOut, to: [.contended]),
        .init(row: .contendedSettled, from: [.contended], event: .holdersSettled, to: [.archivedRecent, .ready, .dormant, .foreignUsersTerminal, .backgroundJob]),
    ]
    /// The exit event's code is not part of the row's identity; the table stores a placeholder and matching ignores the payload.
    public static func transition(for event: Event, from state: StateName) -> Transition? {
        rows.first { t in (t.from.contains(state) || t.from.contains(.any)) && sameKind(t.event, event) }
    }
    static func sameKind(_ a: Event, _ b: Event) -> Bool {
        switch (a, b) { case (.exitedNonZero, .exitedNonZero): return true; default: return a == b }
    }
}
```

`Lifecycle/DormantEligibility.swift`:

```swift
import Foundation

/// C3's registry-mirror entry, as much of X4 as eligibility reads. C3's real type conforms in Task 11; until then
/// `MirrorEntryStandIn` does. Reading a protocol, not a concrete type, is what makes G2 a swap rather than a rewrite.
public protocol TaskMirrorReading: Sendable {
    var taskID: String { get }
    var isRunning: Bool { get }          // started or updated and not yet notified complete
    var isBackground: Bool { get }
}
public struct MirrorEntryStandIn: TaskMirrorReading, Hashable, Sendable {
    public var taskID: String; public var isRunning: Bool; public var isBackground: Bool
    public init(taskID: String, isRunning: Bool, isBackground: Bool) { self.taskID = taskID; self.isRunning = isRunning; self.isBackground = isBackground }
}

public enum DormantEligibility {
    public struct Input: Sendable {
        public var turnRunning: Bool; public var pendingDecisions: Int; public var queuedInput: Int
        public var mirror: [any TaskMirrorReading]; public var lastTaskFrameAge: Duration?; public var heartbeatInterval: Duration; public var wedged: Bool
        public init(turnRunning: Bool, pendingDecisions: Int, queuedInput: Int, mirror: [any TaskMirrorReading], lastTaskFrameAge: Duration?, heartbeatInterval: Duration, wedged: Bool) {
            self.turnRunning = turnRunning; self.pendingDecisions = pendingDecisions; self.queuedInput = queuedInput; self.mirror = mirror
            self.lastTaskFrameAge = lastTaskFrameAge; self.heartbeatInterval = heartbeatInterval; self.wedged = wedged
        }
    }
    public enum Blocker: Hashable, Sendable { case wedged, turnRunning, pendingDecision, queuedInput, taskRunning(String), taskStateUncertain }
    public enum Verdict: Hashable, Sendable { case eligible, blocked(Blocker); public var isEligible: Bool { self == .eligible } }
    /// The parent's five conditions plus the wedged exclusion (ruling of 2026-09-05), in this order; the first blocker wins.
    public static func evaluate(_ i: Input) -> Verdict {
        if i.wedged { return .blocked(.wedged) }
        if i.turnRunning { return .blocked(.turnRunning) }
        if i.pendingDecisions > 0 { return .blocked(.pendingDecision) }
        if i.queuedInput > 0 { return .blocked(.queuedInput) }
        if let running = i.mirror.first(where: { $0.isRunning }) { return .blocked(.taskRunning(running.taskID)) }
        if let age = i.lastTaskFrameAge, age > i.heartbeatInterval { return .blocked(.taskStateUncertain) }
        return .eligible
    }
}
```

`Lifecycle/ListingPolicy.swift`: `IndexEntry {sessionID, entrypoint, sessionKind, isSidechain, teamName, continuedIn}` (all `String?`/`Bool`, mirroring the fields C3's index exposes; Task 11 adds an initialiser from C3's real entry type); `Verdict = .listed(Mode) | .excluded(Reason)` with `Mode = .ownedCandidate | .readOnly(.teammate)` and `Reason = .sidechain | .continuedIn(String)`; `rules: [Rule]` as data with `name` and a closure, evaluated in order: `own-sdk-cli` (entrypoint == "sdk-cli" → listed owned), `sidechain` (isSidechain → excluded), `continued-in` (continuedIn != nil → excluded), `teammate` (teamName != nil → listed read-only), `default` (listed owned). `include(_:)` returns the first rule's verdict.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:"`
Expected: `Executed 18 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: X5 value types, the lifecycle table as data, dormant eligibility, the listing policy"
```

---

### Task 3: Records, holder reading, the observer, CLI verbs

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Fleet/Records.swift`
- Create: `FleetKit/Sources/FleetSessions/Fleet/HolderReader.swift`
- Create: `FleetKit/Sources/FleetSessions/Fleet/FleetObserver.swift`
- Create: `FleetKit/Sources/FleetSessions/Fleet/OriginResolver.swift`
- Create: `FleetKit/Sources/FleetSessions/Verbs/CLIVerbs.swift`
- Create: `FleetKit/Tests/FleetSessionsTests/Support/ScratchConfigHome.swift`, `Support/ScriptedHolderFiles.swift`, `Support/ScriptedProcessRunner.swift`, `Support/TestClock.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/RecordsTests.swift`, `HolderReaderTests.swift`, `FleetObserverTests.swift`, `CLIVerbsTests.swift`

**Interfaces:**
- Consumes: from Task 2: `Holder`, `HolderSet`, `ChannelKey`, `Presence`, `ForeignPresence`, `JobShort`; from `WireEnvironment`: `ProcessRunner`, `ProcessOutput`, `FoundationProcessRunner`; from `AfleetCore`: `ConfigHome`, `ResolvedEnvironment`, `SessionID`, `ChannelOrigin`.
- Produces: `RegistryRecord`, `RosterRecord`, `JobRecord`, `AgentsRow` (Codable), `ProcessLiveness.isLive(pid:startedAt:)`, `HolderReader` protocol with `FileHolderReader`, `FleetObserver` (actor) with `snapshot()`, `holders(for:)`, `updates`, `reconcileNow()`, `OriginResolver.resolve(...)`, `CLIVerbs`; test support `ScratchConfigHome`, `ScriptedHolderFiles`, `ScriptedProcessRunner`, `TestClock`. Tasks 4–10 use all of them.

- [ ] **Step 1: Write the test support**

`Support/TestClock.swift` — a manual `Clock`; the code is the decision:

```swift
import Foundation

/// A Clock whose time moves only when a test says so. `advance(by:)` resumes every sleeper whose deadline has passed,
/// in deadline order, and yields between resumptions so a resumed task can arm its next sleep before the clock moves on.
public final class TestClock: Clock, @unchecked Sendable {   // `lock` serialises every access to `_now` and `waiters`
    public struct Instant: InstantProtocol, Sendable {
        public var offset: Duration
        public func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var waiters: [(deadline: Instant, id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    public init() {}
    public var now: Instant { lock.lock(); defer { lock.unlock() }; return _now }
    public var minimumResolution: Duration { .zero }
    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if deadline <= _now { lock.unlock(); c.resume(); return }
                waiters.append((deadline, id, c)); lock.unlock()
            }
        } onCancel: {
            lock.lock(); let i = waiters.firstIndex { $0.id == id }; let w = i.map { waiters.remove(at: $0) }; lock.unlock()
            w?.continuation.resume(throwing: CancellationError())
        }
    }
    /// Moves time forward and lets every sleeper whose deadline passed run, one at a time.
    public func advance(by d: Duration) async {
        lock.lock(); let target = _now.advanced(by: d); lock.unlock()
        while true {
            lock.lock()
            guard let i = waiters.indices.min(by: { waiters[$0].deadline < waiters[$1].deadline }), waiters[i].deadline <= target else { _now = target; lock.unlock(); break }
            let w = waiters.remove(at: i); _now = w.deadline; lock.unlock()
            w.continuation.resume()
            await Task.yield(); await Task.yield()
        }
    }
    public var sleeperCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }
}
```

`Support/ScratchConfigHome.swift`: creates `<tmp>/afleet-c4-home-<uuid>/` with `sessions/` (0o700), `jobs/`, `daemon/roster.json` (`{"proto":1,"supervisorPid":<test pid>,"updatedAt":0,"workers":{}}`), an empty `projects/`, and `.claude.json` (`{"projects": {}}`); exposes `configHome: ConfigHome` (source `.environment`), `url`, `trust(root: URL)` (writes `projects[<realpath>].hasTrustDialogAccepted = true` — into the *scratch* file, which is not a config home the rule protects because the test created it), `removeAll()` in teardown. It asserts at construction that the path is not under `~/.claude`, `$CLAUDE_CONFIG_DIR` or `/tmp/afleet-fixtures/config-home`.

`Support/ScriptedHolderFiles.swift`: `writeRegistry(pid:sessionID:kind:entrypoint:startedAt:status:waitingFor:name:)` writes `sessions/<pid>.json` with exactly the field names in `RegistryRecord`; `removeRegistry(pid:)`; `writeJob(short:state:sessionID:resumeSessionID:cwd:pid:)` writes `jobs/<short>/state.json` and, when `pid` is given, adds `workers[<short>] = {pid, procStart: "scripted"}` to the roster; `stopJob(short:)` sets `state: "stopped"` and removes the worker. Pids used for "live foreign holders" are the test's own pid (alive, start time known) unless a test wants a dead holder, which uses pid 2_147_483_000 (never live).

`Support/ScriptedProcessRunner.swift`: `struct ScriptedProcessRunner: ProcessRunner` holding `rules: [(match: [String] -> Bool, respond: ([String]) throws -> ProcessOutput)]` and a `Recorder` of invocations (copy the recorder shape from `ClaudeWire/Sources/WireTestSupport/ScriptedRunner.swift`, which is not exported); a rule may mutate scripted files through a captured `ScriptedHolderFiles`. Default rules: `agents --json` → the JSON array built from the current scripted files (the same shape as `AgentsRow`); `stop <short>` → `stopJob(short)`, exit 0; `--bg --resume <id>` → creates a job with `resumeSessionId == id`, exit 0; `--bg --exec <cmd>` → creates a job with no `sessionId`; `auth logout` → exit 0; `auth status` → `{"loggedIn": false}`; anything else → exit 1.

- [ ] **Step 2: Write the failing tests**

`RecordsTests.swift`: decode a registry record with every field the CLI writes (the spec's *Grounding* list) plus an unknown field and assert the typed fields and that `RegistryRecord` keeps unknown keys out of the way (they are dropped; the record is read-only); decode the three job states and the roster; decode an `agents --json` array containing one job row with `state: "working"` and one interactive registry row without `state`; assert a record whose `pid` is a string is rejected as `nil` rather than thrown (the CLI's own reader drops mistyped fields). Deliberate break: mistype `sessionId` as `session_id` in `CodingKeys` → every decode fails.

`HolderReaderTests.swift`:
- `testALiveRegistryRecordIsAHolderAndADeadOneIsNot`: two records, one with the test's pid and its real start time, one with the never-live pid; the reader returns one holder. Deliberate break: skip liveness → two holders.
- `testAReusedPIDIsNotAHolder`: the test's pid with `startedAt` one day before the process started; not a holder. Deliberate break: drop the start-time window → a holder.
- `testAJobIsLiveOnlyWhileTheRosterNamesItsWorker`: a job in `working` with a roster worker (test pid) is a holder; after `stopJob` it is not. Deliberate break: read `state.json` alone → still a holder.
- `testOwnChildrenAreMarkedNotForeign`: a record whose pid is in the `ownPIDs` set the reader is given is a holder with `isOwnChild == true` and absent from `HolderSet.foreign`.
- `testAgentsJSONRowsReconcileByPIDNotByUnion`: the scripted `agents --json` lists the same job as the roster (same pid); the holder set has one holder with `sources == [.roster, .agentsJSON]`. Deliberate break: union by session id → two holders.
- `testUnreadableAndMalformedFilesAreSkippedAndCounted`: a truncated `sessions/x.json` and a non-numeric filename are skipped; the reader's `skipped` count is 2 and no throw. Deliberate break: throw on malformed → the test throws.

`FleetObserverTests.swift` (with `TestClock`):
- `testTheFivesecondPollSeesAnInPlaceStatusChange`: write a record with `status: "idle"`, start the observer, rewrite the same file with `status: "busy"`, advance the clock by five seconds, read `holders(for:)`; presence is `.busy`. Deliberate break: remove the poll → presence stays idle after any advance.
- `testANewRecordIsSeenWithoutWaitingForThePoll`: after start, write a new record; within one second of real time (the vnode source is real) the observer publishes an update. This is the one test in the package that waits on wall time, bounded at two seconds, because the vnode source is the thing under test.
- `testAgentsJSONRunsOnlyOnReconciliationNotOnThePoll`: advance the clock by 55 seconds in five-second steps; the scripted runner recorded zero `agents --json` calls; advance five more; exactly one. Deliberate break: call it on the poll → eleven calls.
- `testUpdatesArePublishedOnlyOnChange`: three polls over unchanged files publish nothing; the count of published `HolderSet`s stays at one (the initial).

`CLIVerbsTests.swift`: `agentsJSON()` decodes the scripted array; `stop` records the invocation `["stop", "<short>"]` and the environment passed is the resolved environment with `CLAUDE_CONFIG_DIR` set to the scratch home (asserted by key presence and value equality to the scratch root, never printed); `backgroundResume` returns the short of the job whose `resumeSessionId` matches; a non-zero exit throws `LifecycleError.verbFailed(verb:exitCode:)`; a diagnostic event per verb carries `verb`, `exitCode`, `durationMs` and no other keys (assert the key set). Deliberate break for the last: add stdout to the event → the key set differs.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit 2>&1 | tail -5`
Expected: build errors naming `RegistryRecord`, `FileHolderReader`, `FleetObserver`, `CLIVerbs`.

- [ ] **Step 4: Implement records, liveness and the reader**

`Fleet/Records.swift` — the shapes are the decision:

```swift
import Foundation

/// `<configHome>/sessions/<pid>.json` as the CLI writes it (parity 38.2; bundle 2.1.258 registry writer). Read-only.
public struct RegistryRecord: Codable, Hashable, Sendable {
    public var pid: Int32; public var sessionId: String; public var cwd: String; public var startedAt: Double
    public var procStart: String?; public var version: String?; public var kind: String; public var entrypoint: String?
    public var name: String?; public var nameSource: String?; public var jobId: String?; public var parkedJobId: String?
    public var status: String?; public var waitingFor: String?; public var state: String?; public var detail: String?; public var tempo: String?
    public var messagingSocketPath: String?
    public init(pid: Int32, sessionId: String, cwd: String, startedAt: Double, procStart: String? = nil, version: String? = nil, kind: String, entrypoint: String? = nil,
                name: String? = nil, nameSource: String? = nil, jobId: String? = nil, parkedJobId: String? = nil, status: String? = nil, waitingFor: String? = nil,
                state: String? = nil, detail: String? = nil, tempo: String? = nil, messagingSocketPath: String? = nil) { /* memberwise */ }
}
/// `<configHome>/daemon/roster.json`.
public struct RosterRecord: Codable, Hashable, Sendable {
    public struct Worker: Codable, Hashable, Sendable { public var pid: Int32?; public var procStart: String? }
    public var proto: Int?; public var supervisorPid: Int32?; public var updatedAt: Double?; public var workers: [String: Worker]
}
/// `<configHome>/jobs/<short>/state.json`, the fields C4 reads.
public struct JobRecord: Codable, Hashable, Sendable {
    public var state: String; public var tempo: String?; public var template: String?; public var backend: String?
    public var sessionId: String?; public var resumeSessionId: String?; public var cwd: String?; public var intent: String?
    public var createdAt: String?; public var updatedAt: String?; public var needs: String?
    public static let terminalStates: Set<String> = ["done", "failed", "stopped"]
}
/// One element of `claude agents --json` (bundle 2.1.258 `printAgentsJson`).
public struct AgentsRow: Codable, Hashable, Sendable {
    public var pid: Int32?; public var id: String?; public var cwd: String; public var kind: String; public var startedAt: Double
    public var sessionId: String?; public var name: String?; public var status: String?; public var waitingFor: String?; public var state: String?
}
```

Decoding rule (the CLI's own reader is defensive): decode each file with a tolerant decoder that maps a wrong-typed *optional* field to `nil` and rejects the file only when a required field (`pid`, `sessionId`, `kind`, `startedAt` for the registry; `state` for a job; `workers` for the roster) is missing or mistyped. Implement with a custom `init(from:)` on `RegistryRecord` using `decodeIfPresent` inside `try?` for optionals. Filenames not matching `^\d+\.json$` are skipped. A file larger than 262,144 bytes is skipped.

`Fleet/HolderReader.swift`:

```swift
import Foundation
import AfleetCore
import Darwin

public enum ProcessLiveness {
    /// `kill(pid, 0)` succeeds (or fails with EPERM, which still means a live process) and the process's start time,
    /// from `proc_pidinfo(PROC_PIDTBSDINFO).pbi_start_tvsec`, lies within `window` of `startedAt` (milliseconds since the epoch).
    public static func isLive(pid: Int32, startedAt: Double, window: Duration = .seconds(60)) -> Bool
    public static func startTime(of pid: Int32) -> Date?
}
public struct HolderSnapshot: Sendable {
    public var holders: HolderSet; public var jobs: [JobShort: JobRecord]; public var skipped: Int
}
public protocol HolderReader: Sendable {
    /// Every holder under the config home right now: registry, roster+jobs, and (when `includeAgentsJSON`) the CLI listing.
    func read(configHome: ConfigHome, ownPIDs: Set<Int32>, includeAgentsJSON: Bool) async -> HolderSnapshot
}
public struct FileHolderReader: HolderReader {
    public init(verbs: CLIVerbs?)      // nil = never run agents --json (tests that do not want it)
}
```

Reconciliation in `FileHolderReader.read`: build holders from the registry (live records only), then jobs (live when the roster worker's pid is live), merging by pid into one `Holder` whose `sources` union grows; then `agents --json` rows matched by pid, or by `(id, sessionId)` to a job when the row has no pid; a row matching nothing becomes a holder with source `[.agentsJSON]` only when it carries a pid that is live. `isOwnChild = ownPIDs.contains(pid)`. `presence` from `status`/`waitingFor`/`name` when present.

- [ ] **Step 5: Implement the observer, origin resolver and verbs**

`Fleet/FleetObserver.swift`: `public actor FleetObserver` with `init(configHome:reader:clock:ownPIDs: @Sendable () async -> Set<Int32>, pollInterval: .seconds(5), reconcileInterval: .seconds(60))`; `start()` arms a vnode `DispatchSource` on `sessions/`, `jobs/` and `daemon/` (file descriptors opened `O_EVTONLY`; events `.write | .delete | .rename | .link`) whose handler calls `refresh(agentsJSON: false)`, and two tasks sleeping on the clock: the poll (`refresh(agentsJSON: false)`) and the reconciliation (`refresh(agentsJSON: true)`); `refresh` reads through the `HolderReader`, and publishes the new `HolderSet` on `updates: AsyncStream<HolderSet>` only when it differs from the last; `snapshot()` returns the last; `holders(for session: SessionID) -> [Holder]`; `reconcileNow()` runs a refresh with `agentsJSON: true` synchronously and returns the snapshot (Tasks 4 and 5 call it from the ownership checks); `stop()` cancels the tasks and the sources.

`Fleet/OriginResolver.swift`: `static func resolve(key:, ownedState: OwnedView?, holders: [Holder], pendingHatch: Bool) -> (ChannelOrigin, Presence)` in the parent's order: owned when `ownedState` is non-nil; foreign live when a live registry holder that is not ours names the session (`.ownTerminalTab` when `pendingHatch`, else `.usersTerminal`); background job when a live job holder names it; else archived. Presence for foreign from `ForeignPresence`, `.unknown` when absent; for owned from `OwnedView {turnRunning, pendingDecisions, sessionStateRequiresAction}`.

`Verbs/CLIVerbs.swift`: `public struct CLIVerbs: Sendable { init(runner: any ProcessRunner, binary: URL, environment: [String: String], diagnostics: any FleetDiagnosticsSink, timeout: Duration = .seconds(20)) }` — the environment is `LaunchConfiguration(...).childEnvironment(over:configHome:)` for a dummy launch in the config home (Task 9's facade composes it once); methods as the spec's *CLI verbs* section; each records `.verb(name, exitCode, durationMs)`; a non-zero exit throws `LifecycleError.verbFailed`. `FleetDiagnosticsSink` is defined in Task 9; for this task define it minimally in `Diagnostics/FleetDiagnostics.swift` with the `verb` case and a `NullFleetDiagnostics`, and Task 9 extends it.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:"`
Expected: `Executed 36 tests, with 0 failures` (18 from before plus 18 here; adjust the number to the count actually written and quote it in the commit body).

- [ ] **Step 7: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: holder records, liveness, the fleet observer, CLI verbs, test support"
```

---

### Task 4: `ChannelSupervisor` core and the first lifecycle rows

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Lifecycle/ProcessHandle.swift`
- Create: `FleetKit/Sources/FleetSessions/Lifecycle/ChannelSupervisor.swift`
- Create: `FleetKit/Sources/FleetSessions/Ownership/OwnershipCheck.swift`
- Create: `FleetKit/Tests/FleetSessionsTests/Support/FakeClaudeLaunch.swift`, `Support/RecordingHolderReader.swift`, `Support/ScriptedProcessHandle.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/LifecycleRowTests.swift`

**Interfaces:**
- Consumes: Task 2's types and table; Task 3's `FleetObserver`, `HolderReader`, `CLIVerbs`, `TestClock`, `ScratchConfigHome`, `ScriptedHolderFiles`; `ClaudeWire`'s `ClaudeProcess`, `LaunchConfiguration`, `WireEvent`, `Handshake`, `ExitStatus`, `AfleetMCPServer`, `SendUserFileTool`, `NullDiagnostics`.
- Produces: `ProcessHandle`, `ProcessFactory`, `ChannelSupervisor` with `open()`, `send(_:)`, `state`, `updates`, `reap()`, `handle(event:)`; `OwnershipCheck`; rows `archivedRecentOpened`, `archivedOlderOpened`, `archivedOlderSent`, `connectingClean`, `connectingFoundHolder`, `readyDormantEligible`, `dormantSent`, `dormantHolderAppeared`, `exitedNonZero` covered. Task 5 adds the rest.

- [ ] **Step 1: Write the test support**

`Support/FakeClaudeLaunch.swift`:

```swift
import Foundation
import AfleetCore
import ClaudeWire

/// A launch of `Tools/fake-claude/fake-claude` replaying one fixture. `FAKE_CLAUDE_*` names do not begin with `CLAUDE`,
/// so they survive the child-environment scrub; the fixture's own session id is used so `auth_status.session_id` matches.
enum FakeClaudeLaunch {
    static var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static var binary: URL { repoRoot.appendingPathComponent("Tools/fake-claude/fake-claude") }
    static func fixture(_ name: String) -> URL { repoRoot.appendingPathComponent("Fixtures").appendingPathComponent(name) }
    static func sessionID(of fixture: String) throws -> SessionID {
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: self.fixture(fixture).appendingPathComponent("fixture.json"))) as! [String: Any]
        return SessionID(meta["session_id"] as! String)!
    }
    static func environment(fixture: String, script: URL? = nil, initOverride: URL? = nil, speed: Double = 50) -> ResolvedEnvironment {
        var vars = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        vars["FAKE_CLAUDE_FIXTURE"] = self.fixture(fixture).path
        vars["FAKE_CLAUDE_SPEED"] = String(speed)
        if let script { vars["FAKE_CLAUDE_SCRIPT"] = script.path }
        if let initOverride { vars["FAKE_CLAUDE_INIT"] = initOverride.path }
        return ResolvedEnvironment(variables: vars, shell: "/bin/zsh", capturedAt: .init(), mode: .processFallback)
    }
    static func launch(fixture: String, cwd: URL, session: SessionStart) -> LaunchConfiguration {
        LaunchConfiguration(binary: binary, cwd: cwd, session: session)
    }
}
```

`Support/RecordingHolderReader.swift`: wraps `FileHolderReader` and records every `read` with its `includeAgentsJSON` flag and a label the supervisor passes through (`beforeSpawn`, `afterHandshake`, `poll`, `reconcile`, `release`), so a test asserts the sequence `[beforeSpawn, afterHandshake]` around a spawn by set and order.

`Support/ScriptedProcessHandle.swift`: `final class ScriptedProcessHandle: ProcessHandle, @unchecked Sendable` (lock-serialised) whose `spawn` returns a canned `Handshake`, whose `events` is a `WireEventStream` fed by the test, whose `terminate()` returns what the test set (`nil` for the wedged row) and whose `childProcessIdentifier` is a value the test chooses. Used only where the plan says.

- [ ] **Step 2: Write the failing tests for this task's rows**

`LifecycleRowTests.swift` — the harness and the coverage map are the decision:

```swift
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// One test per parent §7.4 row. `coverage` maps every row to the method that proves it; `testCoverageIsTotal`
/// asserts set equality over the rows and that each named method exists, so a row without a test fails the build.
final class LifecycleRowTests: XCTestCase {
    static let coverage: [LifecycleTable.Row: String] = [
        .archivedRecentOpened: "testArchivedRecentOpenedSpawnsEagerly",
        .archivedOlderOpened: "testArchivedOlderOpenedRendersHistoryOnly",
        .archivedOlderSent: "testArchivedOlderSentSpawnsThenSends",
        .connectingClean: "testConnectingBecomesReadyWhenThePostHandshakeCheckIsClean",
        .connectingFoundHolder: "testConnectingYieldsWhenThePostHandshakeCheckFindsAHolder",
        .readyDormantEligible: "testReadyReapsAfterThirtyMinutesEligibleAndNotWhileATaskRuns",
        .dormantSent: "testDormantSendResumesUnderTheSameSessionID",
        .dormantHolderAppeared: "testDormantBecomesForeignOrJobWhenAHolderAppears",
        .exitedNonZero: "testNonZeroExitRespawnsWithBackoffThenOffersReopen",
        // Task 5 adds: terminateExhausted, capReached, jobAdopt, ownedSendToBackground, ownedOpenInTerminal, ownTabExited,
        //              foreignRecordGone, foreignSendRefused, handoffTimedOutOrDisagree, contendedSettled
    ]
    func testCoverageIsTotal() {
        XCTAssertEqual(Set(Self.coverage.keys), Set(LifecycleTable.Row.allCases), "rows without a test")
        for (row, name) in Self.coverage {
            XCTAssertTrue(LifecycleRowTests.instancesRespond(to: Selector(name)), "\(row) names a test that does not exist: \(name)")
        }
        // Deliberate break: remove one entry from `coverage` -> the first assertion names the row.
    }
    // Until Task 5 lands, `testCoverageIsTotal` is expected red and the task's commit message says so; Task 5 turns it green.
}
```

The harness (`struct Rig`) each row test builds: a `ScratchConfigHome`, `ScriptedHolderFiles`, a `TestClock`, a `RecordingHolderReader` over a `FileHolderReader(verbs: CLIVerbs(runner: ScriptedProcessRunner(...)))`, a `FleetObserver`, a `ProcessFactory` that builds a real `ClaudeProcess` from `FakeClaudeLaunch` (default fixture `resume-no-replay`, session `.resume(fixtureSessionID, fork: false)`), and the `ChannelSupervisor` for `ChannelKey(configHome: scratch.url, session: fixtureSessionID)` with `recentActivityCutoff` satisfied or not per test (a `Bool` the rig passes: whether the channel counts as recent, since C3's index is not here). The behaviours each row test asserts:

- `archivedRecentOpened`: `open()` → the reader recorded `beforeSpawn`; a process was spawned (factory called once); state `.owned(.connecting)` then `.owned(.ready)`. Deliberate break: skip the pre-spawn check → the reader's labels lack `beforeSpawn`.
- `archivedOlderOpened`: `open()` on a non-recent channel → factory never called; state `.archived`.
- `archivedOlderSent`: `send("hi")` on a non-recent channel → spawn, then the send goes after `.ready` (the fixture `plain-two-turn` replays a turn; assert a `.frame(.user)` or the `result` frame was observed after the handshake and that the `send` returned a uuid).
- `connectingClean`: after the handshake, the reader recorded `afterHandshake` and the state is `.owned(.ready)`. Deliberate break: skip the post-handshake read → labels lack it.
- `connectingFoundHolder`: the scripted files gain a foreign registry record for the session (test pid, `entrypoint: "cli"`) *between* `beforeSpawn` and `afterHandshake` (the recording reader exposes a hook `onLabel("beforeSpawn") { files.writeRegistry(...) }`); the supervisor terminates its own process (an `.exited` event arrives), state becomes `.foreignLive(.usersTerminal)` with `banner == .releasedToTerminal` and `desired == .owned`. Deliberate break: ignore the post-handshake result → state stays ready and the process is still running (assert `childProcessIdentifier` is dead via `kill(pid, 0) != 0`).
- `readyDormantEligible`: ready channel, eligible; advance the clock 29 min → still ready; 1 more min → `terminate()` ran and the state is `.owned(.dormant)`; second half: with the eligibility input carrying a running `MirrorEntryStandIn`, advance 30 min → still ready and no `terminate`. Deliberate break: do not reset/check eligibility at the timer → the second half reaps.
- `dormantSent`: from dormant, `send("hi")` → `beforeSpawn` recorded, a new process with the *next* epoch, same session id (`.resume(sameID)` in the launch the factory received), state passes through `.connecting` once and the send is delivered after the handshake. Deliberate break: reuse the old epoch → the epoch assertion fails.
- `dormantHolderAppeared`: from dormant, write a foreign registry record and advance the poll → `.foreignLive(.usersTerminal)`; alternatively a job record → `.backgroundJob`.
- `exitedNonZero`: after ready, the test sends `kill(childPID, SIGKILL)`; the supervisor observes `.exited(.signal(9))`, records `beforeSpawn`, sleeps 1 s on the clock, respawns; the test kills again and advances 2 s, again and 4 s; after the fourth kill no respawn and the state carries `systemItem == .crashed(exit: .signal(9), reopenOffered: true)` and `reopenOffered`. Assert the sequence of sleeps requested from the clock is `[1 s, 2 s, 4 s]` (the `TestClock` records requested durations). Deliberate break: backoff constant → the recorded durations differ.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit --filter LifecycleRowTests 2>&1 | tail -5`
Expected: build error `cannot find 'ChannelSupervisor' in scope`.

- [ ] **Step 4: Implement the seam, the ownership check and the supervisor**

`Lifecycle/ProcessHandle.swift`:

```swift
import Foundation
import AfleetCore
import ClaudeWire

/// What the supervisor needs from a process. `ClaudeProcess` conforms as-is; the seam exists so the one row no real
/// child can produce (wedged: `terminate()` returning nil) runs against a scripted handle.
public protocol ProcessHandle: Sendable {
    var epoch: ProcessEpoch { get }
    var events: WireEventStream<WireEvent> { get }
    var childProcessIdentifier: Int32 { get async }
    var sessionID: SessionID? { get async }
    func spawn(handshakeTimeout: Duration) async throws -> Handshake
    func send(_ input: UserInput) async throws -> UUID
    func request<R: ControlRequestSpec>(_ spec: R, timeout: Duration?) async throws -> R.Response
    func requestRaw(subtype: String, payload: JSONValue, timeout: Duration?) async throws -> JSONValue
    func answer(_ id: RequestID, _ answer: InboundAnswer) async throws
    func terminate() async -> ExitStatus?
}
extension ClaudeProcess: ProcessHandle {}
public typealias ProcessFactory = @Sendable (ProcessEpoch, LaunchConfiguration) -> any ProcessHandle
```

`Ownership/OwnershipCheck.swift`: `struct OwnershipCheck` with `beforeSpawn(session:) async -> [Holder]` (calls `observer.reconcileNow(label: "beforeSpawn")` and returns `foreign` holders naming the session), `afterHandshake(session:, ownPID:) async -> [Holder]` (label `afterHandshake`; validates each holder through `ProcessLiveness` again), `awaitRelease(previous: Holder, upTo: Duration) async -> ReleaseOutcome` (`.released` when the pid is dead *and* its registry or roster record is gone, polling the reader every 500 ms on the clock; `.timedOut` after `upTo`).

`Lifecycle/ChannelSupervisor.swift` — decisions:

- `public actor ChannelSupervisor` with `init(key:, launchTemplate: LaunchConfiguration, factory: ProcessFactory, ownership: OwnershipCheck, observer: FleetObserver, clock: any Clock<Duration>, eligibilityInputs: @Sendable () async -> DormantEligibility.Input, fleet: FleetCapCounter, diagnostics: any FleetDiagnosticsSink, isRecent: Bool)`.
- State: `state: ChannelState`, `epoch: ProcessEpoch` (starts `.first`, `.next()` on every spawn), `process: (any ProcessHandle)?`, `activitySequence: UInt64` (the LRU key; incremented on every send, frame and decision), `turnRunning`, `pendingDecisions: Set<RequestID>`, `queuedInput: [UserInput]`, `pendingHatch: PaneRequest?`, `crashCount`, `dormantTimer: Task<Void, Never>?`.
- `updates: AsyncStream<ChannelState>` publishes after every transition; every transition goes through `apply(row:to:)`, which asserts `LifecycleTable.transition(for:from:)` exists for the current `StateName` and records `.transition(row, fromName, toName)` on the diagnostics; a missing row records `.transitionNotInTable(event, fromName)` and does nothing else.
- `spawn(reason:)`: `ownership.beforeSpawn`; any holder → `apply(.connectingFoundHolder...)` is *not* used here — a pre-spawn holder means no spawn and the origin becomes foreign or job by `OriginResolver`; otherwise `epoch = epoch.next()`, `process = factory(epoch, launch)`, start the event pump task (`for await ev in process.events`, discarding events whose epoch is older than `epoch`), `spawn(handshakeTimeout: 30 s)`, then `ownership.afterHandshake`; a holder → `terminate()` own process, `apply(.connectingFoundHolder)` with `banner = .releasedToTerminal`; clean → `apply(.connectingClean)` and `armDormantTimer()`.
- The event pump: `.frame(.result)` → `turnRunning = false`, `armDormantTimer()`; `.frame(.user)` from a send → `turnRunning = true`; `.request` → insert into `pendingDecisions`; `.requestCancelled`/answered → remove; `.frame(.system(.initialize))` → `apiKeySource` and `mcpServers` recorded; `.sessionIdentityResolved(id)` → re-key (Task 6); `.exited(status, epoch)` → `handleExit`.
- `armDormantTimer()`: cancel the previous; `Task { try? await clock.sleep(for: .seconds(1800)); await self.dormantTimerFired() }`; `dormantTimerFired()` evaluates `DormantEligibility.evaluate(await eligibilityInputs())` merged with the supervisor's own counts; eligible → `reap()`; blocked → re-arm.
- `reap()`: `terminate()`; `nil` → `apply(.terminateExhausted)` (Task 5 fills the wedged handling; here record it); an exit → `apply(.readyDormantEligible)`, `process = nil`, `fleet.release(key)`.
- `send(_ input)`: dormant → `apply(.dormantSent)` path: spawn (pre-check) and queue the input until `.ready`, then `process.send`; foreign → `throw LifecycleError.heldElsewhere` (Task 5's row); ready → send; archived older → spawn then send.
- `handleExit(status)`: clean exit after our own `terminate()` → nothing more; non-zero or signal while not terminating → `crashCount += 1`; if `crashCount <= 3` → sleep `[1, 2, 4][crashCount-1]` seconds on the clock, `spawn(reason: .respawn)`; else `state.systemItem = .crashed(exit:, reopenOffered: true)` and `apply(.exitedNonZero)` to ready-with-item or archived (archived when the channel was never ready in this epoch series).
- `fleet: FleetCapCounter` is a small actor (`acquire(key, lruKey:) -> CapDecision {.granted, .evict(ChannelKey), .refused(live:)}`, `release(key)`, `noteActivity(key, sequence)`) shared by all supervisors; Task 5 implements the eviction path, Task 4 the counter.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit --filter LifecycleRowTests 2>&1 | grep -E "Executed|error:|failed"`
Expected: 9 row tests pass and `testCoverageIsTotal` fails naming the ten rows Task 5 owns. Run the whole package: every other test passes.

- [ ] **Step 6: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: ChannelSupervisor core, ownership checks, the first nine lifecycle rows (coverage test red until the handoff rows land)"
```

---

### Task 5: Handoffs, the terminal hatch, foreign and contended rows, wedged, the cap

**Files:**
- Modify: `FleetKit/Sources/FleetSessions/Lifecycle/ChannelSupervisor.swift`
- Modify: `FleetKit/Sources/FleetSessions/Ownership/OwnershipCheck.swift`
- Create: `FleetKit/Sources/FleetSessions/Lifecycle/FleetCapCounter.swift` (move the counter here from Task 4 if it was inlined)
- Test: `FleetKit/Tests/FleetSessionsTests/LifecycleRowTests.swift` (the remaining ten rows)

**Interfaces:**
- Consumes: Task 4's supervisor and check; Task 3's `CLIVerbs`, `ScriptedProcessRunner`, `ScriptedHolderFiles`; Task 2's `PaneRequest`, `PaneExit`, `PanePurpose`.
- Produces: `adopt()`, `sendToBackground()`, `openInTerminal() -> PaneRequest`, `attach(job:)`, `logs(job:)`, `paneExited(_:)`, `reopen()`, Contended handling, the wedged state, `FleetCapCounter.evictIfNeeded`; the coverage test turns green.

- [ ] **Step 1: Write the failing tests**

Add the ten entries to `coverage` and these tests:

- `testTerminateReturningNilMarksTheChannelWedgedAndReopenWaitsForNoHolder` (row `terminateExhausted`): the factory returns a `ScriptedProcessHandle` whose `terminate()` returns `nil`; from ready, `reap()` → state `.owned(.dormant)` with `wedged == EscalationTrace(steps: [...], pid:, epoch:)`, `liveCount` still counts it, `DormantEligibility` for the channel reports `.blocked(.wedged)`, and a later `send` does *not* spawn; `reopen()` with a foreign holder present spawns nothing; `reopen()` with none spawns and clears `wedged`. Stated in the test's doc comment: this row runs against a scripted handle because SIGKILL cannot be refused. Deliberate break: treat `nil` as an exit → the channel respawns on `send`.
- `testCapEvictsTheLeastRecentlyUsedEligibleChannelAndRefusesWhenNoneIsEligible` (row `capReached`): six supervisors ready (six `resume-no-replay` replays), activity sequences set so channel 3 is least recent; a seventh `open()` → channel 3 is reaped (its `terminate` observed) and the seventh spawns; then make all six ineligible (each with a pending `MirrorEntryStandIn` running) and open an eighth → `LifecycleError.capReached(live: 6)`, no `terminate` on any, every state's `liveCount == 6` and `headerNote == .capReached(live: 6)`. Also: a wedged channel among the six is never the eviction pick even when least recent. Deliberate break: pick by recency without the eligibility filter → the ineligible half evicts.
- `testAdoptStopsTheJobWaitsForRosterRemovalThenResumes` (row `jobAdopt`): a scripted job for the session with a roster worker; `adopt()` → the runner recorded `["stop", short]`, then the supervisor waited until the worker was gone (the scripted `stop` removes it), then `beforeSpawn` and a spawn with `.resume(id)`; state `.owned(.connecting)` → `.ready`. Deliberate break: spawn before the roster removal → the label order is wrong (`beforeSpawn` before the runner's `stop` completes).
- `testSendToBackgroundTerminatesWaitsForRegistryRemovalThenStartsAJob` (row `ownedSendToBackground`): ready → `sendToBackground()` → own process terminated, `awaitRelease` observed the own registry record gone (the scripted files mirror our child's record: the rig writes a registry record for the fake-claude pid at spawn and removes it on exit, standing in for what the real CLI does), runner recorded `["--bg", "--resume", id]`, the new job's short returned and its `resumeSessionId == id`, state `.backgroundJob`, and the short is stored under `FleetKitKeys.ownJobShorts`. Deliberate break: skip the release wait → the verb runs while the record exists (assert order against the recorder's timestamps).
- `testOpenInTerminalReturnsAHatchPaneRequestUnderTheSameConfigHome` (row `ownedOpenInTerminal`): ready → `openInTerminal()` → own process terminated and released; the returned `PaneRequest` has `purpose == .hatch(id)`, `arguments == ["--resume", id.description]`, `executable == binary`, `cwd == channel cwd`, and its `environment["CLAUDE_CONFIG_DIR"] == scratch root path` with no other `CLAUDE*` key except those `LaunchConfiguration.childEnvironment` sets (assert the key set equals that function's output for the same inputs); state `.foreignLive(.ownTerminalTab)`. Deliberate break: build the environment from `ProcessInfo` → the key set differs.
- `testPaneExitReAdoptsWhenTheRecordIsGone` (row `ownTabExited`): after the hatch request, the rig writes a foreign registry record for the "terminal" (test pid), then `paneExited(PaneExit(request:, code: 0, observedAt:))`; the supervisor waits until the record is removed (the test removes it after the call), then `beforeSpawn` and a spawn; state `.owned(.connecting)`. A `PaneExit` for a request from an older epoch is ignored (recorded as `.staleExit`). Deliberate break: spawn on the exit without waiting for the record → the pre-spawn check finds the holder and the test's second expectation (spawn after removal) fails.
- `testForeignRecordDisappearingArchivesTheChannel` (row `foreignRecordGone`): foreign live (foreign record present, no own process); remove the record; advance the poll → `.archived`.
- `testSendOnAForeignSessionIsRefusedWithForkOffered` (row `foreignSendRefused`): `send` throws `LifecycleError.heldElsewhere(set)`; state `banner == .heldElsewhere(set)`; no spawn; `desired` unchanged. Deliberate break: spawn anyway → the factory was called.
- `testHandoffTimeoutAndDisagreementEnterContended` (row `handoffTimedOutOrDisagree`): adopt with a scripted `stop` that never removes the worker; advance the clock 10 s → `.owned(.contended)`, `banner == .contended(set)` naming the holder's pid; second half: ready channel with `desired == .owned` and a foreign holder appearing → `.owned(.contended)` and the banner. Deliberate break: 10 s constant → the state is not contended at 10 s.
- `testContendedResolvesWhenHoldersSettle` (row `contendedSettled`): from contended, remove the foreign record and advance the poll → the matching origin (`.archived` when nothing holds it; `.foreignLive` when one foreign holder remains).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit --filter LifecycleRowTests 2>&1 | tail -5`
Expected: build errors for `adopt`, `sendToBackground`, `openInTerminal`, `paneExited`, `reopen`.

- [ ] **Step 3: Implement**

Decisions:

- `adopt()`: requires a live job holder for the session; `verbs.stop(short)`; `ownership.awaitRelease(previous: jobHolder, upTo: 10 s)` — `.timedOut` → `apply(.handoffTimedOutOrDisagree)` with `banner = .contended`; `.released` → `spawn(reason: .adopt)`.
- `sendToBackground()`: requires owned; `terminate()`; `awaitRelease(previous: ownHolder)` where `ownHolder` is the registry record whose pid is our child's (looked up before terminating); `verbs.backgroundResume(id, cwd)` → `JobShort`; store it in `FleetKitKeys.ownJobShorts`; `verbs.agentsJSON()` and the roster must list it, else `LifecycleError.verbFailed(verb: "--bg --resume", exitCode: 0)` with a diagnostic `.jobNotListedAfterBackground`; `apply(.ownedSendToBackground)`.
- `openInTerminal()`: requires owned; `terminate()`; `awaitRelease`; build `PaneRequest(executable: launch.binary, arguments: ["--resume", key.session.description], cwd: launch.cwd, environment: launchTemplate.childEnvironment(over: environment, configHome: configHome), purpose: .hatch(key.session))`; `pendingHatch = request`; `apply(.ownedOpenInTerminal)`; return it. `attach(job:)`/`logs(job:)`: `PaneRequest(executable: binary, arguments: ["attach"|"logs", short.rawValue], cwd: job.cwd ?? launch.cwd, environment: same, purpose: .attach|.logs)`, no state change.
- `paneExited(_ exit)`: only when `pendingHatch == exit.request`; otherwise record `.staleExit` and return; wait for the hatch's registry record to disappear (`awaitRelease` on the foreign holder for the session, `upTo: 10 s`; timeout → contended); then `spawn(reason: .readopt)` → `apply(.ownTabExited)`.
- Contended: `enterContended(holders)` sets `.owned(.contended)`, `banner = .contended(HolderSet)`; the observer's updates drive `resolveContended()`: zero foreign holders → `.archived` (or re-spawn when `desired == .owned` and the user acts; no automatic respawn), one holder → the matching origin; `apply(.contendedSettled)`.
- Disagreement: on every `HolderSet` update, if `desired == .owned`, the channel is owned-ready or dormant, and a foreign holder names the session → `enterContended`.
- Wedged: `reap()`/any `terminate()` returning `nil` → `state.wedged = EscalationTrace(steps: diagnosticsSteps, pid:, epoch:)`, `state.origin = .owned(.dormant)`, `state.systemItem = .wedged(trace, reopenOffered: true)`, `process = nil` but `fleet` keeps the count (`fleet.markWedged(key)`); `send` while wedged → `throw LifecycleError.wedged(trace)`; `reopen()` → `beforeSpawn`; holders → nothing (banner `.contended`); none → clear `wedged`, `fleet.clearWedged(key)`, spawn. The observer clears the ghost's count when its pid is dead and its record gone (`fleet.clearWedged` from the update handler).
- Cap: `FleetCapCounter` actor holds `live: Set<ChannelKey>`, `wedged: Set<ChannelKey>`, `lru: [ChannelKey: UInt64]`, `eligibility: [ChannelKey: @Sendable () async -> Bool]`; `acquire(for key)`: if `live.count + wedged.count < 6` → `.granted`; else pick the least `lru` among `live - wedged` whose eligibility closure returns true → `.evict(that)`; none → `.refused(live: 6)`. The evicting supervisor calls the victim's `reap()` and waits for its `.owned(.dormant)` before spawning.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`
Expected: `testCoverageIsTotal` green; all row tests green; quote the `Executed N tests, with 0 failures` line in the commit body.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: handoffs, the terminal hatch as a pane request, foreign and contended rows, wedged, the cap; G1 coverage total"
```

---

### Task 6: The quiescent restart and forking

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Lifecycle/RestartSnapshot.swift`
- Modify: `FleetKit/Sources/FleetSessions/Lifecycle/ChannelSupervisor.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/RestartTests.swift`, `ForkTests.swift`

**Interfaces:**
- Consumes: Task 5's supervisor; `ClaudeWire`'s `ApplyFlagSettings`, `GetSettings`, `InitializeResponse`, `SessionIdentity`, `WireEvent.sessionIdentityResolved`.
- Produces: `quiescentRestart(_ request: RestartRequest)`, `RestartSnapshot.take(from:)`, `Readback.verify(...) -> [String]` (the names that did not survive), `fork(at:) -> ChannelKey` (provisional), `updates` publishing the re-keyed state.

- [ ] **Step 1: Write the failing tests**

`RestartTests.swift` (fixture `control-shapes` for the readbacks, `FAKE_CLAUDE_INIT` for the mismatch):
- `testRestartCarriesRuntimeValuesAndNeverAgent`: a ready channel whose session object holds permission mode `plan`, model `opus`, effort `low`, fast mode on, output style `default`, `--add-dir` list `["/tmp/a"]`, launched with `agent: "reviewer"`; `quiescentRestart(RestartRequest(addDirectories: ["/tmp/a", "/tmp/b"]))` → the factory received a `LaunchConfiguration` with `permissionMode == .plan`, `model == "opus"`, `effort == "low"`, `addDirectories == [/tmp/a, /tmp/b]`, `agent == nil`, `session == .resume(sameID, fork: false)`, and the epoch advanced; after the handshake the process received `apply_flag_settings {settings: {fastMode: true}}` (assert on the scripted `expect` in a `FAKE_CLAUDE_SCRIPT`, which makes the replay fail with exit 3 if the request never arrives) and then `get_settings`. Deliberate break: re-pass `--agent` → `agent != nil`.
- `testRestartWaitsForDormantEligibilityAndQueuesTheChange`: with a running task in the mirror, `quiescentRestart` returns at once with `state.pendingChange == request` and no terminate; when the task ends (mirror empty) and the dormant timer fires, the restart runs. Deliberate break: restart immediately → `terminate` observed while the task runs.
- `testAReadbackMismatchRaisesTheBannerAndKeepsConnecting`: `FAKE_CLAUDE_INIT` answering `current_permission_mode: "default"` against a snapshot of `plan` → `state.origin == .owned(.connecting)`, `banner == .settingDidNotSurvive("permissionMode")`; the user picking a value (`resolveSetting("permissionMode")`) clears it to `.ready`. Deliberate break: compare nothing → ready with no banner.
- `testReadbackReadsEachValueFromItsOwnSource`: a table-driven test over `Readback.verify(snapshot:, handshake:, settingsApplied:)` with one mismatch at a time, asserting the returned name list equals exactly the mismatched name (`["model"]`, `["effort"]`, `["permissionMode"]`, `["fastMode"]`, `["outputStyle"]`). Deliberate break: read model from the handshake instead of `get_settings.applied` → the `model` case passes with the wrong source, caught because the test's handshake carries a *different* model than `applied`.

`ForkTests.swift`:
- `testForkIsKeyedProvisionallyUntilTheIdentityEventThenReKeyed`: `fork(at: nil)` on a ready channel → a new supervisor with `key.session` provisional (`state.identity == .awaitingFork(from:, provisional:)`), launch `.resume(source, fork: true)`; the scripted handle (a real fake-claude replay of `plain-two-turn` emits `auth_status` with the fixture's id, which for this test *is* the "new" id) → `.sessionIdentityResolved` → `state.key.session == fixture id`, `updates` published the re-keyed state once, captures untouched. Deliberate break: key the fork on the source id → the re-key never happens and the key equals the source.
- `testForkFromAMessagePassesTheInclusiveFlags`: `fork(at: uuid)` → launch arguments contain `--resume-session-at <uuid>` and `--resume-drops-turn <uuid>`; this needs a `LaunchConfiguration` field C2 does not have — see Decisions.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit --filter "RestartTests|ForkTests" 2>&1 | tail -5`
Expected: build errors for `quiescentRestart`, `RestartSnapshot`, `fork`.

- [ ] **Step 3: Implement**

Decisions:
- `RestartSnapshot.take(from session: SessionObject)` reads the supervisor's session object (`permissionMode` from the last `set_permission_mode` answer or the handshake, `model`/`effort` from the last `get_settings.applied`, `fastMode` from the last `fast_mode_state`, `outputStyle` from the initialize response, `addDirectories` and `ChildEnvironmentOptions` from the current launch).
- `quiescentRestart`: `DormantEligibility` blocked → `state.pendingChange = request`, return; eligible → snapshot; `terminate()`; `awaitRelease(own)`; new launch = template with the request applied (outer `nil` keeps, inner `nil` clears), `permissionMode/model/effort` from the snapshot, `agent = nil`; spawn; after `.ready`: `process.request(ApplyFlagSettings(settings: ["fastMode": true]))` when the snapshot had fast mode on; `process.request(GetSettings())`; `Readback.verify`; empty → `.ready`; else `banner = .settingDidNotSurvive(firstName)`, stay `.connecting` until `resolveSetting(name)`.
- `Readback.verify(snapshot:, handshake: InitializeResponse, settingsApplied: JSONValue) -> [String]`: `model` and `effort` from `settingsApplied["model"]`/`["effort"]`; `permissionMode` from `handshake.currentPermissionMode`; `fastMode` from `handshake.fastModeState == "on"`; `outputStyle` from `handshake.outputStyle`; names in that fixed order.
- Fork: `fork(at uuid: UUID?) -> ChannelKey` creates a new `ChannelSupervisor` through a factory closure the facade injects (`spawnSibling`), with `session: .resume(source, fork: true)`, `identity = .awaitingFork(from: source, provisional: SessionID())`; on `.sessionIdentityResolved(id, epoch)` matching the current epoch: `key = ChannelKey(configHome:, session: id)`, `identity = .known(id)`, publish; the facade re-indexes the supervisor under the new key.
- `--resume-session-at` and `--resume-drops-turn`: `LaunchConfiguration` has no field for them (C2 modelled the §6.1 line). Do **not** patch ClaudeWire from this branch. Add `FleetSessions.ForkPoint {messageUUID: UUID}` and carry it on the supervisor; the arguments are appended by the facade's `ProcessFactory` through `LaunchConfiguration.extraArguments` **if and only if** C2 has such a field on `main` at execution time; otherwise the executor files a `[parent-impact]` note on X3 ("`LaunchConfiguration` needs `resumeSessionAt: UUID?` and `resumeDropsTurn: UUID?`, both refused without `--resume`") and `testForkFromAMessagePassesTheInclusiveFlags` is written against the intended arguments and marked `XCTSkip("blocked on X3 fork-point flags")` with the note's date. This is the one deliberate skip in the package below the live gate, and it is reported in the task's commit body.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed|skipped"`
Expected: 0 failures; at most 1 skipped (the fork-point flags), named.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: the quiescent restart with snapshot and readback, forking with a provisional key"
```

---

### Task 7: Spawn preconditions and the one §6.12 write (G3)

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Preconditions/TrustReader.swift`
- Create: `FleetKit/Sources/FleetSessions/Preconditions/ProjectMCPConsent.swift`
- Create: `FleetKit/Sources/FleetSessions/Preconditions/LocalSettingsStore.swift`
- Create: `FleetKit/Sources/FleetSessions/Preconditions/ManagedSettingsReader.swift`
- Create: `FleetKit/Sources/FleetSessions/Preconditions/SpawnPreconditions.swift`
- Modify: `FleetKit/Sources/FleetSessions/Lifecycle/ChannelSupervisor.swift` (spawn consults `SpawnPreconditions` first)
- Test: `FleetKit/Tests/FleetSessionsTests/PreconditionTests.swift`

**Interfaces:**
- Consumes: Task 1's store (acceptances), Task 5's supervisor, `ScratchConfigHome`.
- Produces: `TrustReader.isTrusted(root:configHome:)`, `ProjectRoot.canonical(for:)`, `ProjectMCPConsent.evaluate(...) -> [ServerVerdict]`, `LocalSettingsStore.decline(names:root:configHome:)`, `ManagedSettingsReader.isPending(configHome:)`, `SpawnPreconditions.evaluate(...) -> SpawnPrecondition`.

- [ ] **Step 1: Write the failing tests**

`PreconditionTests.swift`, each under a temporary project directory the test creates (a git repository made by writing a `.git` directory with a `HEAD` file, no `git` binary needed):

- `testCanonicalRootIsTheRealPathWalkedUpToGit`: cwd `<proj>/a/b` → root `<proj>` realpath; a cwd with no `.git` above → itself; a `/tmp/...` path resolves to `/private/tmp/...` (compare against `URL.resolvingSymlinksInPath()`). Deliberate break: skip realpath → the `/tmp` case differs.
- `testUntrustedRootYieldsHistoryOnly`: no project entry → `.untrusted(root:)`; entry with `false` → `.untrusted`; `true` → passes to the next check. Deliberate break: treat a missing entry as trusted → spawn allowed.
- `testConsentIsComputedFromBothLocationsReadOnly`: `.mcp.json` declares `a`, `b`, `c`, `d`; local-settings store has `disabledMcpjsonServers: ["a"]`; the `.claude.json` project entry has `disabledMcpjsonServers: ["b"]`, `enabledMcpjsonServers: ["c"]`; a user settings file sets nothing → verdicts `a: rejected`, `b: rejected`, `c: approved`, `d: pending`; with `enableAllProjectMcpServers: true` in the project settings, `d: approved`. After the evaluation the project tree and the scratch `.claude.json` are byte-identical to before (hash them). Deliberate break: read only the local store → `b` is pending.
- `testAcceptRecordsTheHashAndDoesNotRepeatUntilTheEntryChanges`: accept `d` → the store holds `(root, "d", hash)`; re-evaluate → `d: approved(byAcceptance)`; change `d`'s command in `.mcp.json` → `d: pending` again. Deliberate break: key by name alone → the changed entry is still approved.
- `testDeclineWritesThroughTheCLIsOwnPolicy`: existing `.claude/settings.local.json` with keys `{"zeta": 1, "alpha": {"x": [1,2]}, "disabledMcpjsonServers": ["old"]}` and mode 0o640; `decline(["d"])` → the file's `disabledMcpjsonServers == ["old", "d"]`; every other top-level key's raw JSON text is byte-identical to before (compare substrings of the raw file); mode still 0o640; no file under `.claude/.cc-writes` remains; the directory listing of `.claude` equals `["settings.local.json"]` plus whatever existed before. A marker-file server: `.mcp.json` declares `d` with command `sh -c 'touch <proj>/marker'`; after decline and a spawn of `fake-claude` (which never runs servers), the marker is absent — asserted, and stated as the negative half; the positive half (a real engine honouring the decline) is G5's `mcp_status` check. Deliberate break: rewrite the whole JSON through `JSONSerialization` → key order or number formatting changes and the byte comparison fails.
- `testDeclineRefusesASymlinkedDotClaude`: `.claude` is a symlink to a directory outside the project → `LifecycleError.declineRefused(reason: "symlink")`; the target directory's listing and bytes unchanged; no spawn (`SpawnPreconditions` returns `.consentNeeded` still) and `banner == .mcpDeclineRefused("symlink")`. Deliberate break: open without `O_NOFOLLOW` → the write lands in the target.
- `testDeclineRefusesAStoreInsideTheConfigHome`: a project whose canonical root lies under the scratch config home → refused with reason `insideConfigHome`, nothing written.
- `testDeclineRefusesAForeignUIDAndUnparseableJSON`: the uid check is exercised by injecting an `owner(of:)` function that reports a different uid for `<root>/.git` → refused `foreignUID`; a `settings.local.json` containing `{` → refused `unparseable`, file untouched.
- `testDeclineRunsOnlyWhileNoOwnedProcessIsLiveAndReReadsBeforeSpawn`: with a live owned process for the project, `decline` throws `LifecycleError.declineRefused(reason: "processLive")`; after the process is gone it succeeds and `SpawnPreconditions` re-reads the store through `LocalSettingsStore.resolve` before returning `.ready` (assert the resolver was called twice via an injected counter).
- `testIsolatedSourcesWithDeclaredServersAddStrictMCPConfig`: `settingSources: []` and a `.mcp.json` with one server → the launch carries `strictMCPConfig == true` and the state `headerNote == .projectServersOff`; with no `.mcp.json` → `false`. Deliberate break: add the flag unconditionally → the second half fails.
- `testManagedSettingsPendingBlocksTheSpawn`: `remote-settings.json` present and no consent file → `.managedSettingsPending`, no spawn, `banner == .managedSettingsPending`; both present with a consent record whose hash matches the payload → passes; an unparseable pair → pending (fail closed). Deliberate break: treat an unparseable consent file as consent → the third half spawns.
- `testPreconditionOrderIsWedgedContendedManagedUntrustedConsent`: a project failing every check at once returns `.wedged` first; clearing each in turn returns the next in the spec's order. Deliberate break: reorder → the sequence differs.
- `testNothingElseInThePackageWritesUnderAProject`: hash the project tree before and after every other precondition path and every lifecycle row test's rig teardown → equal. (Implemented as a helper the rig calls.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit --filter PreconditionTests 2>&1 | tail -5`
Expected: build errors naming `TrustReader`, `ProjectMCPConsent`, `LocalSettingsStore`.

- [ ] **Step 3: Implement**

`Preconditions/LocalSettingsStore.swift` — the one dangerous path, so the algorithm is the decision:

```swift
import Foundation
import Darwin

/// The parent's §6.12 store resolution and write policy (SPEC 03 §4.4, §13.2-13.3). This is the only Claude Code-owned
/// file afleet writes, and it is written the way the CLI writes it. Every failure is a refusal with a reason word;
/// nothing is ever half-written.
public struct LocalSettingsStore: Sendable {
    public struct Resolution: Hashable, Sendable { public var storeDirectory: URL; public var storeFile: URL; public var legacyOverlay: URL?; public var atGitRoot: Bool }
    public var ownerUID: @Sendable (URL) -> uid_t?          // lstat-based; injectable for the foreign-uid test
    public init(ownerUID: @escaping @Sendable (URL) -> uid_t? = LocalSettingsStore.lstatOwner)

    /// `<root>/.claude/settings.local.json` when stat(root), lstat(root/.git) and lstat(root/.claude) are all owned by
    /// the effective uid and root is not the real home directory; otherwise `<cwd>/.claude/settings.local.json`,
    /// with the cwd file read as the legacy overlay when the store moved to the git root.
    public func resolve(gitRoot: URL?, cwd: URL) -> Resolution

    public enum Refusal: String, Error, Sendable { case unparseable, symlink, foreignUID, insideConfigHome, processLive, writeFailed, notADirectory }

    /// Steps, in order; any failure throws `Refusal` before or without touching the target:
    /// 1. `resolve`; refuse `insideConfigHome` when `storeFile` lies under `configHome` (real paths).
    /// 2. Read the raw file text if it exists; parse with `JSONSerialization` only to find the `disabledMcpjsonServers`
    ///    array's byte range (a lightweight scanner over the raw text finds the top-level key and its bracketed value);
    ///    refuse `unparseable` on any parse error. Merge `names` into the array (stable order, no duplicates) and splice
    ///    the new array's JSON into the raw text at that range; when the key is absent, insert `"disabledMcpjsonServers": [...]`
    ///    before the final `}` with a leading comma when needed. Every other byte of the file is untouched.
    /// 3. `mkdir(storeDirectory, 0o755)` if absent (refuse `notADirectory` if a non-directory exists).
    /// 4. `open(storeDirectory, O_DIRECTORY | O_NOFOLLOW)` and, when the file exists, `open(storeFile, O_RDONLY | O_NOFOLLOW)`;
    ///    ENOTDIR/ELOOP → refuse `symlink`.
    /// 5. `fstat` the existing file for its mode (default 0o644 for a new file).
    /// 6. `mkdir(storeDirectory/.cc-writes, 0o700)` if absent; write the new text to `.cc-writes/settings.local.json.<uuid>`;
    ///    `fchmod` to the preserved mode; `fsync`; `rename` over `storeFile`; `fsync` the directory fd; remove the
    ///    staging directory if empty. Any error → remove the staging file, refuse `writeFailed`.
    public func decline(names: [String], gitRoot: URL?, cwd: URL, configHome: URL) throws -> Resolution
    public static func lstatOwner(_ url: URL) -> uid_t?
}
```

`Preconditions/ProjectMCPConsent.swift`: `ServerVerdict = .rejected(ServerSource) | .approved(ServerSource) | .pending` with `ServerSource = .localSettings | .projectEntry | .userSettings | .projectSettings | .acceptance`; `evaluate(root:cwd:configHome:acceptances:) -> [ProjectMCPServer: ServerVerdict]` reading `.mcp.json` (`mcpServers` object; each entry's `entryHash` = SHA-256 over the canonical JSON of the entry), the resolved local store and legacy overlay, `<root>/.claude/settings.json`, `<configHome>/settings.json`, and `.claude.json`'s `projects[<root>]` entry, all read-only; precedence: rejected wins over approved wins over pending.

`Preconditions/TrustReader.swift`: `ProjectRoot.canonical(for cwd: URL) -> (root: URL, gitRoot: URL?)` (realpath, walk up for `.git`); `TrustReader.isTrusted(root:configHome:) -> Bool` from `.claude.json` `projects[root.path].hasTrustDialogAccepted == true`.

`Preconditions/ManagedSettingsReader.swift`: `isPending(configHome:) -> Bool`: `remote-settings.json` absent → false; present and `remote-settings-consent.json` parses to an object whose `approvedHash` (or, failing that key, any string field) equals the SHA-256 of the payload file's bytes → false; anything else → true. The consent key name is a delegated unknown; the reader's doc comment says so and names the spec section.

`Preconditions/SpawnPreconditions.swift`: `evaluate(key:, cwd:, launch:, wedged:, foreignHolders:, store:) async -> (SpawnPrecondition, LaunchConfiguration)` in the spec's order; it returns the launch with `strictMCPConfig` set when the sources exclude `.local` and `.mcp.json` declares servers. `ChannelSupervisor.spawn` calls it before `beforeSpawn` and turns a non-`.ready` verdict into `LifecycleError.precondition(_)` plus the matching banner.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: spawn preconditions; trust and consent read-only from both locations; the one §6.12 write"
```

---

### Task 8: The command router, the flag matrix, refusal interception and `/logout` (G4)

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Router/RouterTable.swift`
- Create: `FleetKit/Sources/FleetSessions/Router/CommandRouter.swift`
- Create: `FleetKit/Sources/FleetSessions/Router/LogoutPlan.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/RouterTests.swift`, `LogoutPlanTests.swift`

**Interfaces:**
- Consumes: Tasks 4–7; `ClaudeWire` request specs; `Handshake`; fixture `control-shapes`.
- Produces: `RouterTable.local`, `LaunchSettingMatrix`, `CommandRouter.route(_:handshake:) -> Routed`, `RefusalInterceptor.intercept(_:) -> Intercepted?`, `LogoutPlan.build(...)`, `LogoutPlan.execute(...)`.

- [ ] **Step 1: Write the failing tests**

`RouterTests.swift`:
- `testTheLocalTableEqualsTheParentsRowsAsASet`: `Set(RouterTable.local.map(\.name)) == ["/model", "/permissions", "/effort", "/rename", "/add-dir", "/agent", "/cd", "/fast", "/config", "/login", "/logout", "/color", "/clear", "/rewind", "/fork", "/background", "/stop", "/tasks", "/mcp", "/memory", "/btw", "/agents", "/resume", "/compact", "/context", "/cost", "/usage"]` and `RouterTable.local.count == 27` (no duplicates). Deliberate break: duplicate `/model` → the count differs while the set matches, which is why both are asserted.
- `testEveryEntryMapsToAListedMechanism`: each entry's `mechanism` is one of the enum's cases and its `readback` names a source among `getSettingsApplied`, `getSettingsEffectiveKeys`, `handshakePermissionMode`, `fastModeState`, `none`.
- `testEffortSendsApplyFlagSettingsAndReadsBackEffectiveKeys` (fixture `control-shapes`): route `/effort low` → `.controlRequest` whose spec encodes to `{"subtype":"apply_flag_settings","settings":{"effortLevel":"low"}}`; executing it against the replay yields the recorded success with no `response` key and then `get_settings` whose `effective_keys` contains `effortLevel`. Deliberate break: send `{effort: "low"}` → the replay refuses with exit 3 (unexpected host frame).
- `testCDIntoAnUntrustedDirectoryRepeatsWithTrustAcceptedAndTrustedDirectory` (fixture `control-shapes`): route `/cd <recorded sibling>` → first `set_cwd {path}` answered `needs_trust`; the router's follow-up after the user's trust answer is `set_cwd {path, trust_accepted: true, trusted_directory: <the directory from the answer>}`; assert the second request's payload keys `== ["path", "trust_accepted", "trusted_directory"]`. Deliberate break: omit `trusted_directory` → the replay refuses.
- `testRenameAndModelMapToTheirRequests`: `/rename hello` → `rename_session {title: "hello"}`; `/model sonnet` → `set_model {model: "sonnet"}`.
- `testTerminalOnlyCommandsAreHiddenAndRefusedWithAnExplanation`: a handshake whose first `system/init` carried `terminal_slash_commands: ["/vim"]` → `route("/vim")` is `.refusedLocally(explanation:)` and autocomplete omits it. Deliberate break: check `commands` instead → `/vim` routes as text.
- `testUnknownLocalCommandFallsThroughAsText`: `/definitely-not-a-command x` → `.text`.
- `testTheBareRefusalIsInterceptedReplacedAndCounted`: an assistant frame whose text is exactly `/vim isn't available in this environment.` → `RefusalInterceptor` returns `.intercepted(command: "/vim", replacement: <afleet's explanation>)` and the drift counter is 1; a frame containing that sentence inside a longer answer is not intercepted. Deliberate break: match by prefix → the second half intercepts.
- `testAddDirBuildsARestartRequestAndTheMatrixClassifiesEverySetting`: `/add-dir /tmp` → `.restart(RestartRequest(addDirectories: [.../tmp]))`; `LaunchSettingMatrix.runtimeMutable == ["model", "permissionMode", "effort", "agent", "sessionName", "thinkingTokens", "fastMode", "cwd"]` and `restartRequired == ["sessionId", "forkSession", "worktree", "streamFlags", "allowBypass", "settingSources", "promptSuggestions", "enableAuthStatus", "sessionMirror", "addDir", "childEnvironment"]` as sets.

`LogoutPlanTests.swift`:
- `testTwoIdleOwnedChannelsAreListedAndTerminatedBeforeLogout`: `LogoutPlan.build` lists both; `execute` → both `terminate` observed before the runner recorded `["auth", "logout"]`; the barrier refused a spawn attempted mid-plan (`LifecycleError.precondition(.contended...)` is wrong here — use `LifecycleError.logoutInProgress`, add the case); result `.success(exited: [id1, id2], foreignLeftRunning: [])`. Deliberate break: run logout first → order assertion.
- `testALiveTaskAndAnOwnJobAreListedWaitHoldsStopSendsStopTaskFirst`: one channel with a running mirror task, one own job; the plan lists the task and the job; `.wait` returns `.waiting(on: [taskID])` without acting; `.stop` sends `interrupt {cancel_queued: true}` then `stop_task {task_id}` (assert both requests reached the replay through a `FAKE_CLAUDE_SCRIPT` with a `generic-success` rule for both subtypes, in that order), stops the job (`["stop", short]`) and observes roster removal before `auth logout`; a foreign registry record is named in `foreignLeftRunning`. Deliberate break: skip roster verification → `auth logout` precedes the worker's removal in the recorder.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit --filter "RouterTests|LogoutPlanTests" 2>&1 | tail -5`
Expected: build errors naming `RouterTable`, `CommandRouter`, `LogoutPlan`.

- [ ] **Step 3: Implement the table**

`Router/RouterTable.swift` — the table is the decision; explanations are afleet's copy and must read as below:

```swift
import Foundation
import AfleetCore
import ClaudeWire

public enum RouteMechanism: Hashable, Sendable {
    case controlRequest(subtype: String)          // built by CommandRouter from the arguments
    case lifecycle(String)                        // a LifecycleAction name: fork, sendToBackground, stopEverything, backgroundAll, logout
    case restart                                  // a RestartRequest built from the arguments
    case text                                     // pass through; frames render the result
    case native(String)                           // UI-only: picker, popover, focus, files tab
}
public enum ReadbackSource: String, Hashable, Sendable { case getSettingsApplied, getSettingsEffectiveKeys, handshakePermissionMode, fastModeState, none }
public struct LocalCommand: Hashable, Sendable {
    public let name: String; public let mechanism: RouteMechanism; public let readback: ReadbackSource; public let explanation: String
}
public enum RouterTable {
    public static let local: [LocalCommand] = [
        .init(name: "/model", mechanism: .controlRequest(subtype: "set_model"), readback: .getSettingsApplied, explanation: "Changes the model for this channel without a Claude turn."),
        .init(name: "/permissions", mechanism: .controlRequest(subtype: "set_permission_mode"), readback: .handshakePermissionMode, explanation: "Changes the permission mode; on its own opens the read-only rules view."),
        .init(name: "/effort", mechanism: .controlRequest(subtype: "apply_flag_settings"), readback: .getSettingsEffectiveKeys, explanation: "Changes the effort level; max cannot be set mid-session."),
        .init(name: "/rename", mechanism: .controlRequest(subtype: "rename_session"), readback: .none, explanation: "Renames the channel and the transcript's title."),
        .init(name: "/add-dir", mechanism: .restart, readback: .none, explanation: "Adds a directory by restarting this channel under the same session id."),
        .init(name: "/agent", mechanism: .controlRequest(subtype: "apply_flag_settings"), readback: .getSettingsEffectiveKeys, explanation: "Switches the agent from the next turn."),
        .init(name: "/cd", mechanism: .controlRequest(subtype: "set_cwd"), readback: .none, explanation: "Changes the working directory; an untrusted directory asks for trust first."),
        .init(name: "/fast", mechanism: .controlRequest(subtype: "apply_flag_settings"), readback: .fastModeState, explanation: "Turns fast mode on or off."),
        .init(name: "/config", mechanism: .text, readback: .none, explanation: "Runs in the engine; the persisted setting is read back with get_settings."),
        .init(name: "/login", mechanism: .controlRequest(subtype: "claude_authenticate"), readback: .none, explanation: "Signs in through the Browser tab."),
        .init(name: "/logout", mechanism: .lifecycle("logout"), readback: .none, explanation: "Signs out every owned channel and afleet-launched job on this machine."),
        .init(name: "/color", mechanism: .text, readback: .none, explanation: "Sent to the engine as text."),
        .init(name: "/clear", mechanism: .text, readback: .none, explanation: "Clears the conversation; the timeline resets on conversation_reset."),
        .init(name: "/rewind", mechanism: .controlRequest(subtype: "rewind_conversation"), readback: .none, explanation: "Rewinds the conversation and, after a dry run, the files."),
        .init(name: "/fork", mechanism: .lifecycle("fork"), readback: .none, explanation: "Opens a new channel forked from this session."),
        .init(name: "/background", mechanism: .lifecycle("sendToBackground"), readback: .none, explanation: "Hands this session to a background job."),
        .init(name: "/stop", mechanism: .controlRequest(subtype: "interrupt"), readback: .none, explanation: "Stops the current turn; Stop everything also stops background tasks."),
        .init(name: "/tasks", mechanism: .native("tasks"), readback: .none, explanation: "Shows the running tasks with per-task Stop."),
        .init(name: "/mcp", mechanism: .controlRequest(subtype: "mcp_status"), readback: .none, explanation: "Shows MCP servers and their state."),
        .init(name: "/memory", mechanism: .controlRequest(subtype: "get_context_usage"), readback: .none, explanation: "Opens the memory files in the Files tab."),
        .init(name: "/btw", mechanism: .controlRequest(subtype: "side_question"), readback: .none, explanation: "Asks a side question without affecting the conversation."),
        .init(name: "/agents", mechanism: .native("agents"), readback: .none, explanation: "Lists the agents from the handshake."),
        .init(name: "/resume", mechanism: .native("switcher"), readback: .none, explanation: "Focuses the channel switcher."),
        .init(name: "/compact", mechanism: .text, readback: .none, explanation: "Compacts in the engine; renders as a divider."),
        .init(name: "/context", mechanism: .text, readback: .none, explanation: "Sent to the engine as text."),
        .init(name: "/cost", mechanism: .text, readback: .none, explanation: "Sent to the engine as text."),
        .init(name: "/usage", mechanism: .text, readback: .none, explanation: "Sent to the engine as text."),
    ]
    public static let bareRefusalPattern = #"^/([A-Za-z0-9:_-]+) isn't available in this environment\.$"#
}
public enum LaunchSettingMatrix {
    public static let runtimeMutable: Set<String> = ["model", "permissionMode", "effort", "agent", "sessionName", "thinkingTokens", "fastMode", "cwd"]
    public static let restartRequired: Set<String> = ["sessionId", "forkSession", "worktree", "streamFlags", "allowBypass", "settingSources", "promptSuggestions", "enableAuthStatus", "sessionMirror", "addDir", "childEnvironment"]
}
```

`Router/CommandRouter.swift`: `Routed = .controlRequest(RawControlRequest or a typed spec wrapped as `AnyControlRequest`) | .lifecycle(LifecycleAction) | .restart(RestartRequest) | .text(String) | .native(String) | .refusedLocally(explanation: String)`; `route(text, handshake, systemInit)`: split the first token; local table first (argument parsing per command: `/effort <level>` → `ApplyFlagSettings(settings: ["effortLevel": level])`; `/agent <name>` → `["agent": name]`; `/fast` → `["fastMode": true]` toggling on the session's state; `/cd <path>` → `SetCwd(path:)`; `/model <m>` → `SetModel`; `/permissions <mode>` → `SetPermissionMode`, bare → `.native("permissions")`; `/rename <t>` → `RenameSession`; `/stop` → `Interrupt()`), then `systemInit.terminalSlashCommands` → `.refusedLocally`, then `.text`. `continueCD(afterNeedsTrust directory:, path:)` builds `SetCwd(path:, trustAccepted: true, trustedDirectory: directory)`. `RefusalInterceptor` holds a drift counter (an actor-isolated `Int` on the facade) and matches the whole text against `bareRefusalPattern`.

`Router/LogoutPlan.swift`: `Census {owned: [ChannelKey], nonEligible: [(ChannelKey, [String])], ownJobs: [JobShort], foreign: [Holder]}`; `build(fleet:)`; `execute(choice: .wait | .stop, ...)` in the spec's order with the barrier (`Fleet.spawnBarrier = true` → every `spawn` throws `LifecycleError.logoutInProgress`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: the command router as data, the flag matrix, refusal interception, the logout plan"
```

---

### Task 9: Activity, diagnostics, the import graph, the `Fleet` facade

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Activity/ActivityQuery.swift`
- Create/Modify: `FleetKit/Sources/FleetSessions/Diagnostics/FleetDiagnostics.swift`
- Create: `FleetKit/Sources/FleetSessions/Fleet.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/ActivityQueryTests.swift`, `ImportGraphTests.swift`, `FleetFacadeTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `ActivityQuery.rows(...)`, `ActivityRow`, `FleetDiagnosticEvent` (closed enum), `FleetDiagnosticsSink`, `FileFleetDiagnostics`, `public actor Fleet: LifecycleAPI` with `init(configHome:, environment:, binary:, store:, diagnosticsDirectory:, clock:, factory: ProcessFactory? = nil, runner: any ProcessRunner = FoundationProcessRunner())`.

- [ ] **Step 1: Write the failing tests**

`ActivityQueryTests.swift`: a table of inputs → rows: a pending decision → `.decision(key, requestID)`; a `result` with `is_error` → `.failedResult`; `permission_denials` entries and a `system/permission_denied` → `.permissionDenied`; a `rate_limit_event` with `status: "allowed"` and `overageStatus: "rejected"`, `overageDisabledReason: "org_level_disabled"` → **no** refusal row and a banner row of kind `.rateLimitInfo` (deliberate break: key on `overageStatus` → a refusal row appears); `status: "rejected"` → `.rateLimitRefused`; an `auth_status` with `error` → `.authProblem`, a healthy one clears it; a running mirror entry → `.agentRunning`, a failed `task_notification` → `.agentFailed`. Each row carries the `ChannelKey` and, when it exists, the item uuid.

`ImportGraphTests.swift`: grep every `import` line under `FleetKit/Sources/FleetSessions` and assert the set of imported modules is a subset of `["Foundation", "Darwin", "AfleetCore", "ClaudeWire", "WireFrames", "WireTransport", "WireEnvironment", "WireMCP", "WireDiagnostics", "FleetTimeline", "FleetSessions"]` and contains at least `AfleetCore` and `ClaudeWire` (the floor that proves the grep found the files). Deliberate break: import `Workbench` in a scratch file → the set gains a name.

`FleetFacadeTests.swift`: `Fleet` built over a `ScratchConfigHome` with the fake-claude factory: `states()` lists a channel after `open(key)`; `updates` publishes; `preconditions(for:)` runs; `openInTerminal` returns a request and `paneExited` re-adopts (facade-level replay of Task 5's row); `declineProjectServers` writes under a temporary project; the diagnostics file under a temporary directory has one JSON line per event with the key set `{event, ...structural}` and no key named `path`, `environment`, `stdout`, `record` (assert on key names). Deliberate break: log the pane request's environment → a forbidden key appears.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit --filter "ActivityQueryTests|ImportGraphTests|FleetFacadeTests" 2>&1 | tail -5`
Expected: build errors naming `ActivityQuery`, `Fleet`.

- [ ] **Step 3: Implement**

`Diagnostics/FleetDiagnostics.swift`:

```swift
import Foundation
import WireFrames

/// FleetKit's own diagnostics vocabulary, one JSON line per event in the app's diagnostics directory beside C2's file.
/// Structural fields only: names, counts, ids, epochs, durations. Never a path under a config home, an environment,
/// a record or stdout (parent §6.3).
public enum FleetDiagnosticEvent: Sendable {
    case transition(row: String, from: String, to: String, session: String, epoch: UInt64?)
    case transitionNotInTable(event: String, from: String, session: String)
    case ownershipCheck(label: String, foreignHolders: Int, session: String)
    case handoffWait(outcome: String, waitedMs: Int, session: String)
    case verb(name: String, exitCode: Int32, durationMs: Int)
    case precondition(verdict: String, session: String)
    case declineWrite(outcome: String, servers: Int)
    case paneRequest(purpose: String, session: String?)
    case staleExit(purpose: String)
    case jobNotListedAfterBackground(session: String)
    case wedged(session: String, steps: Int)
    case capDecision(decision: String, live: Int)
    case logout(step: String, count: Int)
    case driftRefusalIntercepted(command: String)
    public var jsonValue: JSONValue { /* object with "event" plus the case's fields, keys in snake_case */ }
}
public protocol FleetDiagnosticsSink: Sendable { func record(_ event: FleetDiagnosticEvent) }
public struct NullFleetDiagnostics: FleetDiagnosticsSink { public init() {}; public func record(_ event: FleetDiagnosticEvent) {} }
/// Same shape and rotation as ClaudeWire's FileDiagnostics; file name `fleet.log`, rotated once into `fleet.log.1`.
public final class FileFleetDiagnostics: FleetDiagnosticsSink, @unchecked Sendable { /* serial queue owns the handle */ }
```

`Activity/ActivityQuery.swift`: `ActivityRow {key, kind: Kind, itemUUID: String?, text: String}` with `Kind = decision(RequestID), notification, failedResult, permissionDenied, rateLimitRefused, rateLimitInfo, authProblem, agentRunning(String), agentFailed(String)`; `rows(states: [ChannelState], mirrors: [ChannelKey: [any TaskMirrorReading]], recent: [ChannelKey: [Frame]]) -> [ActivityRow]` pure.

`Fleet.swift`: the facade actor owning `[ChannelKey: ChannelSupervisor]`, the `FleetObserver`, `FleetCapCounter`, `StateStore`, `CLIVerbs` (environment composed once through `LaunchConfiguration(binary:cwd: configHome.root, session: .new(SessionID())).childEnvironment(over:configHome:)`), `SpawnPreconditions`, `CommandRouter`, `RefusalInterceptor`, `LogoutPlan`, `spawnBarrier`; implements every `LifecycleAPI` method by delegating to the supervisor for the key, creating one on first use with `isRecent` supplied by the caller (`open(key, recent:)` is the facade's extra entry point; the protocol's `perform(.open)` uses the stored recency); `updates` merges every supervisor's stream; a fork re-keys the map on `sessionIdentityResolved`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`
Expected: 0 failures, at most the one named skip from Task 6.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: the Activity query, FleetKit diagnostics, the import-graph test, the Fleet facade"
```

---

### Task 10: The live gate against the installed CLI (G5) and the write allowlist

**Files:**
- Test: `FleetKit/Tests/FleetSessionsTests/LiveFleetTests.swift`
- Create: `FleetKit/Tests/FleetSessionsTests/Support/LiveGate.swift` (budget reading and config-home diff, copied in shape from `ClaudeWire/Tests/ClaudeWireTests/LiveCLITests.swift`, which is not exported)

**Interfaces:**
- Consumes: the `Fleet` facade; the installed `claude` located through `BinaryLocator` from an `EnvironmentResolver` capture; `/tmp/afleet-fixtures/config-home`.
- Produces: the G5 verdicts and the widened allowlist `LiveGate.engineWrittenPaths`.

- [ ] **Step 1: Write the gate**

`Support/LiveGate.swift`: `skipUnlessLive()` throws `XCTSkip("set AFLEET_LIVE_CLI=1 to run against the installed CLI")`, then `XCTSkip("scratch config home has no login; run: CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home claude")` when none of `.credentials.json`, `credentials.json`, `.claude.json` exists there; `skipUnlessTurns()` for `AFLEET_LIVE_CLI_TURNS=1`; `LiveBudgetReading.read(getUsage:)` exactly as C2's (copied, with a comment naming the source file); `budgetOrSkip(fleet)` spawns nothing new: it runs `get_usage` over a zero-cost `ClaudeProcess` (`resume-no-replay`-style handshake with `--max-turns 1` is not needed; a fresh `--session-id` handshake and `get_usage` spend nothing, as C2's `zero-cost` fixture proved) and skips with the reading's `reason` when `isSpent`; `ConfigHomeWitness` records `{relative path: (size, mtime)}` for every regular file under the scratch home (hidden included) and `difference(from:)` returns created/modified/deleted relative paths; `engineWrittenPaths` is the spec's allowlist as prefix patterns: `sessions/`, `projects/`, `tasks/`, `jobs/`, `daemon/`, `daemon.log`, `history.jsonl`, `.claude.json`, `shell-snapshots/`, `session-env/`, `file-history/`, `statsig/`, `cache/`, `todos/`, `debug/`, `plugins/`, `backups/`, `plans/`, `ide/`, `logs/`, `history/`, `.credentials.json`, `.last-cleanup`, `.last-update-result.json`, `settings.json`; `unexplained(difference)` returns every path whose first component matches none.

`LiveFleetTests.swift`:

- `testAForeignInteractiveSessionIsDetectedWithinFiveSecondsAndArchivedWhenItEnds`: `skipUnlessLive`; pick a directory the scratch `.claude.json` already trusts (the first `projects` key with `hasTrustDialogAccepted == true` whose path is under `/private/tmp/afleet-fixtures/`; recreate it if absent; skip with `XCTSkip("no trusted scratch directory")` when none); start `claude` (no `-p`) on a pty via `openpty` + `posix_spawn` with the child environment from `LaunchConfiguration.childEnvironment` (so `CLAUDE_CONFIG_DIR` is the scratch home) and `TERM=xterm-256color`; build a `Fleet` over the scratch home with the real `FoundationProcessRunner`; poll `states()` on wall time up to 5 s until a channel with `origin == .foreignLive(.usersTerminal)` appears whose `key.session` is the pid's registry record's session; assert it appeared, its presence is one of `idle/busy/waiting/unknown`; write `Ctrl-C` twice or `/exit\r` to the pty and wait for the child to exit; poll up to 10 s until the channel is `.archived`. Never sends a prompt. Deliberate break: filter registry records by `entrypoint == "sdk-cli"` → the interactive session is never detected.
- `testAnExecJobIsListedAsABackgroundJobAndStopRemovesIt`: `skipUnlessLive`; `fleet.verbs.backgroundExec("sleep 60", cwd: trustedDir)`; poll up to 5 s for `.backgroundJob`; `perform(.stopJob(short))`; poll until the job holder is gone; record in the test log whether the exec job's `state.json` carried a `sessionId` (the delegated unknown), as a one-line `XCTContext.runActivity` note with the boolean only.
- `testAdoptingAConversationJobResumesItOwned`: `skipUnlessLive`, `skipUnlessTurns`, `budgetOrSkip`; `claude --bg --model claude-haiku-4-5-20251001 "Reply with exactly: pong"` through the runner; poll for the job; `perform(.adopt)`; assert the runner recorded `stop`, the job left the roster, the channel became `.owned(.ready)` under the job's `sessionId`, and the post-handshake check found no holder. One short turn.
- `testTheWriteAllowlistHoldsAcrossHooksABackgroundShellASubagentAndRelocation`: `skipUnlessLive`, `skipUnlessTurns`, `budgetOrSkip`; witness before; open a new owned channel in the trusted directory with the Notification hook registered (C2's default `InitializeConfiguration`), send one `haiku` prompt: `Run "sleep 20 &" as a background shell, then use an Explore subagent to list the files in this directory, then reply "done".`; when the `result` arrives, `/cd` into a second trusted scratch directory (`set_cwd`) and wait for its answer; terminate; witness after; assert `unexplained(difference).isEmpty` with the offending relative paths in the message; assert the difference is non-empty (the gate saw writes at all) and that it touched `projects/` (the transcript) and `sessions/` (the record) as a floor on "the reading looked at the right tree". Deliberate break: remove `tasks/` from the allowlist → the background shell's output file is unexplained (this break is the discriminating demonstration and is run once).
- `testTheAllowlistNamesNothingTheEngineIsNotKnownToWrite`: a unit test over `engineWrittenPaths` asserting the set equals the spec's list exactly, so an addition is deliberate.

- [ ] **Step 2: Run without the live flag**

Run: `swift test --package-path FleetKit --filter LiveFleetTests 2>&1 | grep -E "Executed|skipped"`
Expected: `Executed 5 tests, with 4 tests skipped and 0 failures` (the allowlist unit test runs).

- [ ] **Step 3: Run the live gate once**

Run: `AFLEET_LIVE_CLI=1 swift test --package-path FleetKit --filter LiveFleetTests 2>&1 | grep -E "Test Case|Executed|skipped|error"`
Expected: the two zero-turn tests pass; the two turn tests skip with `set AFLEET_LIVE_CLI_TURNS=1`.
Then, once: `AFLEET_LIVE_CLI=1 AFLEET_LIVE_CLI_TURNS=1 swift test --package-path FleetKit --filter LiveFleetTests 2>&1 | grep -E "Test Case|Executed|skipped|error"`
Expected: all five pass, or the budget skip names the spent window. Quote the summary line and the two turns' `total_cost_usd` (from the `result` frames) in the commit body; do not retry a failed turn — report it.

- [ ] **Step 4: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: the live gate against the installed CLI; the config-home write allowlist widened across one composed turn"
```

---

### Task 11: After C3 lands — G2 and `IndexStorage`

This task is executable only after `child/c3-timeline` merges to `main` and this branch merges `main`. If C4 reaches its merge first, the task is left open, G2 is marked pending in the parent's tracking map (parent §17.6), and this task becomes the corrective task on C4 flagged to C5 and C6.

**Files:**
- Modify: `FleetKit/Sources/FleetSessions/Lifecycle/DormantEligibility.swift` (conform C3's mirror entry to `TaskMirrorReading`)
- Modify: `FleetKit/Sources/FleetSessions/Lifecycle/ListingPolicy.swift` (an initialiser from C3's index entry)
- Create: `FleetKit/Sources/FleetSessions/Store/StoreIndexStorage.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/MirrorEligibilityTests.swift`, `StoreIndexStorageTests.swift`

**Interfaces:**
- Consumes: from C3 (`FleetTimeline`): the registry-mirror entry type and its reducer, `IndexStorage` (load and save an index snapshot), the index entry type with `entrypoint`, `sessionKind`, `isSidechain`, `teamName`, `continuedIn`.
- Produces: `extension <C3 mirror entry>: TaskMirrorReading`, `StoreIndexStorage: IndexStorage` over `FileStateStore` at `fleetKit` / `FleetKitKeys.timelineIndex`, `ListingPolicy.IndexEntry.init(<C3 entry>)`.

- [ ] **Step 1: Write the failing tests**

`MirrorEligibilityTests.swift` (G2): drive C3's reducer with the `background-shell` fixture through a fake-claude replay under a `ChannelSupervisor`; while the mirror lists the running task, advance the clock 30 min → no `terminate`; after the `task_notification` empties the mirror and the heartbeat interval passes with no frames, advance → `terminate` observed. Deliberate break: feed the supervisor the empty stand-in instead of the mirror → the first half reaps.

`StoreIndexStorageTests.swift`: `save` then `load` round-trips C3's snapshot type; a store from the future refuses; `load` on an empty store returns `nil`.

- [ ] **Step 2: Implement, run, commit**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`; expected 0 failures.

```bash
git add FleetKit
git commit -m "FleetSessions: G2 over C3's registry mirror; IndexStorage over the store"
```

---

### Task 12: Final verification against the spec's acceptance

**Files:** none created; the spec's `## Outcomes & Retrospective` is written by the controller at finish, not here.

- [ ] **Step 1: Clean build of every package**

```bash
rm -rf FleetKit/.build ClaudeWire/.build AfleetCore/.build
swift test --package-path AfleetCore 2>&1 | grep -E "Executed .* tests"
swift test --package-path ClaudeWire 2>&1 | grep -E "Executed .* tests"
swift test --package-path FleetKit 2>&1 | grep -E "Executed .* tests|skipped"
```
Expected: every line reads `0 failures`; FleetKit's skips are exactly the four live tests plus, if still blocked, the fork-point flags test, each with its named reason.

- [ ] **Step 2: G1 by name**

```bash
swift test --package-path FleetKit --filter LifecycleRowTests 2>&1 | grep -E "Test Case .*(passed|failed)|Executed"
```
Expected: `testCoverageIsTotal` passed and one passed line per row name in `LifecycleRowTests.coverage`.

- [ ] **Step 3: G3 and G4 by name**

```bash
swift test --package-path FleetKit --filter "PreconditionTests|RouterTests|LogoutPlanTests" 2>&1 | grep -E "Executed|failed"
```
Expected: `0 failures`.

- [ ] **Step 4: G5 once, as Task 10 Step 3**, quoting the summary lines. Do not retry.

- [ ] **Step 5: The never-write and identity scans**

```bash
git grep -n -E "/Users/[a-z]+" -- FleetKit | grep -v -E "/Users/(probe|alice|someone)" ; echo "identity grep exit $?"
git ls-files FleetKit | grep -E "\.d\.ts$|node_modules|\.typings" ; echo "typings exit $?"
ls -la /tmp/afleet-fixtures/config-home/sessions | wc -l
```
Expected: the identity grep prints nothing (exit 1); no typings tracked (exit 1); the scratch home's `sessions/` holds no record from a test process that is still running (count is the two directory entries only).

- [ ] **Step 6: Record**

Record the counts, the skips with their reasons, the two live turns' cost, and the state of Task 11 in the plan's ledger (`.doperpowers/sde/2026-09-05-c4-fleetkit-sessions-fleet/progress.md`); the controller writes the spec's Outcomes. No commit unless a file changed.

---

## Self-review notes

- Spec coverage: Purpose → Tasks 4–9; G1 → Tasks 4–5 (coverage total in Task 5); G2 → Task 11; G3 → Task 7; G4 → Task 8; G5 → Task 10; store (X6) → Task 1; X5 types and pane protocol → Tasks 2, 5; listing policy → Task 2; Activity → Task 9; diagnostics → Tasks 3, 9; verbs cadence → Task 3; wedged exclusions → Tasks 2, 5; consent from both locations → Task 7; `IndexStorage` → Task 11; the write allowlist → Task 10.
- Interface consistency: `TaskMirrorReading` (Task 2) is consumed by Tasks 4, 5, 9 and satisfied by C3's type in Task 11; `PaneRequest`/`PaneExit` (Task 2) are produced by Task 5 and exercised by Task 9's facade test; `CLIVerbs` (Task 3) is consumed by Tasks 5, 8, 10; `FleetDiagnosticsSink` is introduced minimally in Task 3 and completed in Task 9.
- One open item the plan could not settle: the two fork-point flags (`--resume-session-at`, `--resume-drops-turn`) have no field on C2's `LaunchConfiguration`; Task 6 files the `[parent-impact]` and skips one test by name rather than patching ClaudeWire from this branch.
