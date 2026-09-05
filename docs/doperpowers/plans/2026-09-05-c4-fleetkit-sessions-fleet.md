# C4: FleetKit Sessions and Fleet Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use doperpowers:subagent-driven-execution to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `FleetSessions` module of the `FleetKit` package: channel origins and holder detection, the ownership protocol, the lifecycle table with dormant eligibility, respawn, adopt, send-to-background, the terminal hatch as a pane request, the quiescent restart, the wedged state and the cap, the spawn preconditions with the one §6.12 write, the Activity query, the command router with `/logout`, the namespaced store, and a live gate against the installed CLI that also widens the config-home write allowlist.

**Architecture:** One SwiftPM target, `FleetSessions`, inside the `FleetKit` package whose manifest skeleton is already on `main`, depending on `FleetTimeline`, `ClaudeWire` and `AfleetCore`. `ChannelSupervisor` is an actor per channel that reaches its process through a `ProcessHandle` seam (`ClaudeProcess` conforms) and drives a constant `LifecycleTable` with every timer on an injected `Clock`. `FleetObserver` is an actor per ConfigHome that reads the registry, the job roster and `claude agents --json` and reconciles holders by pid. `Fleet` is the facade that owns supervisors, the observer, the store, the preconditions and the router and implements the X5 `LifecycleAPI`. Tests drive real `fake-claude` replays for every lifecycle row a real child can produce, a scripted handle for the one row it cannot, scripted registry and job files, and an in-process scripted `ProcessRunner` for CLI verbs.

**Tech Stack:** Swift 6.3.3, Swift Package Manager (`swift-tools-version: 6.2`, language mode 6, `platforms: [.macOS(.v26)]`), Foundation (`Process`, `FileManager`, `DispatchSource` vnode sources, `JSONDecoder`/`JSONEncoder`), Darwin (`kill`, `proc_pidinfo`, `open` with `O_NOFOLLOW`, `fsync`, `rename`, `openpty`), XCTest, `Tools/fake-claude/fake-claude` (Python 3) with the fixtures under `Fixtures/`, and the installed `claude` for the live gate under `/tmp/afleet-fixtures/config-home`.

**Spec:** `docs/doperpowers/specs/2026-09-05-c4-fleetkit-sessions-fleet.md` v2.2 (child of `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C4`, parent-pin `ee94449`; the parent's §6.11, §6.12, §7.1, §7.2, §7.4, §7.6, §7.7, §7.8 and §17.5 X1, X2, X3, X5, X6, X9, X10 bind this work, X5 and X6 as amended on 2026-09-05). Conflicts found during execution resolve against the spec; a wrong binding clause flows back to the parent as `[parent-impact]`, never a local override.

**Plan revision:** v2 (2026-09-05), after the plan's adversarial review (eleven findings, all folded into spec v2.2) and the merge of `main` at `71a9999` (the parent's X5 `PaneRequest.id`, C1's §6.12 spike, C2's `SessionStart.forkFrom`). Against v1: the store's constructor is validated-only, its namespace a closed enum, its atomicity tested through an injected file-ops seam and its schema handling per case (Task 1); the lifecycle table enumerates `(row, from, event, to)` scenarios with the disagreement transition as its own event, and mirror entries carry armed and running (Task 2); the pre-spawn check refuses every live holder, the post-handshake check excludes exactly the new pid, and pane exits match by `request.id` (Tasks 4, 5); cap slots are reservations with observed eviction outcomes, and `terminate() == nil` is injected through every terminating action (Tasks 5, 6, 8); the restart snapshots an actor-owned `SessionRuntimeState` and forking uses `forkFrom` with no skip (Task 6); consent reads the merged settings only, the §6.12 writer is descriptor-relative with six named symlink and mode tests (eight from v3), and the engine-side proof of a decline moves to the live suite (Tasks 7, 10); router entries carry typed strategies with fixture-backed multi-step tests (Task 8); G5 runs behind one serialised live budget and one suite-level config-home witness (Task 10); G2 asserts the same boundary cases as Task 2 (Task 11).

**Touch-up** (2026-09-05, after the coordinator's ruling on the coverage test): the full-table G1 coverage assertion moves to Task 12 as the gate check, demonstrated red there by deleting one scenario, so every checkpoint from Task 1 on reads 0 failures; the diagnostics vocabulary moves to Task 3 and the cap counter's file to Task 4 (their first consumers), `perform(_:)` is named in Task 6, and the router's strategy result types, `StrategyUI` and `AnyControlRequest` are declared in Task 8, so no task names a type a later task declares. Merged `main` at `6f3ea5a`; the WireEventPolicy corrective (`ca68f2e`) touches no internal this plan cites.

**Plan revision v3** (2026-09-05), after the plan's second adversarial review (twelve findings, all folded into spec v2.3). `ProcessHandle.events` is an existential `AsyncSequence<WireEvent, Never>`, the live conformance is a `LiveProcessHandle` wrapper over `ClaudeProcess` and the scripted handle's stream is an `AsyncStream` the test feeds, with a compile-level test (Task 4); the cap counter counts pending evictions, takes eligibility as a snapshot the supervisors push, decides without an await, and completes an eviction when the victim's own `release` arrives (Tasks 4, 5); the §6.12 writer opens the resolved root, verifies the descriptor with `F_GETPATH` and runs containment on that result, with two ancestor-swap tests so the six symlink tests become eight (Task 7); `SessionRuntimeState` carries `flagSettings` and `fastModeObserved`, the restart relaunches every launch field from the snapshot, re-applies the flag union, verifies every key against `effective_keys` and publishes `.ready` only after the readbacks (Task 6); `LifecycleAction.answer` and `LifecycleAPI.events(of:)` reach the wire through the supervisor, with `LifecycleError.decisionGone` (Tasks 2, 4, 9); `LiveBudget.run` reserves synchronously behind a continuation queue, with a zero-cost unit test (Task 10); G5's consent scenario accepts the marker server through the store first, the allowlist scenario reads the witness while the child runs and after it ends, asserts the turn's actions from the channel's events, and its deliberate break is `projects/` (Task 10); the store's file-ops seam splits `writeTemporary` into create, write, fsync and close so a fault lands after a partial write, and the config-home test aliases the home through a real symlink (Task 1); `procStart` is parsed and compared within one second, the `startedAt` window is the diagnosed fallback (Task 3); the `/cd` continuation replays `session-mirror-relocation` and compares the full payload (Task 8); send-to-background and open-in-terminal gain from-dormant scenarios (Task 5); the fork-collision test pushes `.sessionIdentityResolved` through the scripted handle (Task 6).

## Global Constraints

- One package: `FleetKit/` at the repository root, manifest `FleetKit/Package.swift` already on `main`. C4 owns the manifest and never edits inside the region between `// MARK: - C3 timeline group` and `// MARK: - end of C3 group`. `FleetSessions` depends on `FleetTimeline`, `ClaudeWire` and `AfleetCore` and imports nothing above them (parent X1); an import-grep test enforces it.
- `// swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, every target `swiftSettings: [.swiftLanguageMode(.v6)]`; strict concurrency from the first commit; no `@preconcurrency` imports.
- Every public type is `Sendable`; nothing is `@MainActor`. Actors: `ChannelSupervisor`, `FleetObserver`, `FileStateStore`, `Fleet`. `@unchecked Sendable` only where a type is a single-owner box whose state is reachable from one place that serialises every access, and the declaration says which mechanism (parent §17.7).
- Public initialisers on every value a downstream package constructs.
- `swift test --package-path FleetKit` passes after every task; `swift test --package-path ClaudeWire` and `--package-path AfleetCore` are untouched by this work and must still pass at the end.
- Nothing in `FleetSessions` or its tests writes under any Claude Code config home (`~/.claude`, `$CLAUDE_CONFIG_DIR`, `/tmp/afleet-fixtures/config-home`); the spawned `claude` may. The one project write is `LocalSettingsStore.decline` under the parent's §6.12 policy, exercised only under a temporary directory in tests (parent X9).
- Tests touch only processes they start themselves; never a session in the user's terminal; adoption is exercised only on jobs the test started (root `CLAUDE.md`).
- Live tests run only with `AFLEET_LIVE_CLI=1` and skip with a named reason otherwise; the two turn-spending scenarios also need `AFLEET_LIVE_CLI_TURNS=1`. Every live scenario runs through the suite's one `LiveBudget` (Task 10): scenarios are serialised; the model is pinned to `claude-haiku-4-5-20251001` on every turn-spending launch; every `ClaudeProcess` the suite launches carries `--max-turns` (1 handshake-only, 2 for the composed turn); the ceilings are two model turns and ten minutes of wall time for the whole suite; C2's usage reading is taken before the first scenario and before each turn-spending one, and a spent window skips with its reason; every `result` frame's `total_cost_usd` is summed and reported; a zero-cost scenario asks `get_session_cost` before ending its process and asserts `total_cost_usd == 0`, because a zero-turn launch emits no `result` frame.
- One config-home witness spans the whole live suite (class `setUp` to class `tearDown`) and a second brackets each scenario; any unexplained path in either fails the gate with the path named.
- The lifecycle table is data: `LifecycleTable.scenarios`, one `(row, from, event, to)` per from-state a parent §7.4 row admits and per outcome it can reach. Each row test declares the scenarios it drives and asserts, from the diagnostics sink, that exactly those transitions were observed; G1's coverage is set equality between the union of the declared sets and the table, never a count. That equality is asserted once, by Task 12's `LifecycleCoverageTests`, the gate check; Tasks 4 through 8 each assert exactly the scenarios they land, so every checkpoint before the gate is green.
- Pane exits are matched to the pending hatch by `PaneRequest.id`, never by value equality of the request.
- Every action that terminates a process calls `ChannelSupervisor.terminateOrWedge()` and stops at a `nil`; nothing else calls `process.terminate()`.
- `LocalSettingsStore` never opens a path by name after resolving it: every open, create and rename after the resolution is relative to a directory descriptor it holds open.
- `FileStateStore` has one initialiser and it validates the base directory against the config homes it is given; tests construct it the way production does.
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
    Store/StateStore.swift                       StateStore, StoreNamespace (closed enum), StoreError, SchemaStatus, StoreDiagnostic, StoreFileOperations
    Store/FileStateStore.swift                   the per-namespace JSON document store
    Store/FleetKitState.swift                    the fleetKit namespace's Codable values and keys
    Types/ChannelState.swift                     ChannelKey, ChannelState, Presence, ChannelBanner, HeaderNote, EscalationTrace, DesiredOwnership, SessionRuntimeState
    Types/Actions.swift                          LifecycleAction (fork(at: ForkPoint?), answer(RequestID, InboundAnswer)), SpawnPrecondition, ProjectMCPServer, RestartRequest, RestartSnapshot (typealias), LifecycleError
    Types/Panes.swift                            PanePurpose, PaneRequest (with id), PaneExit, JobShort
    Types/LifecycleAPI.swift                     the X5 protocol
    Lifecycle/LifecycleTable.swift               Row, Event, TerminatingAction, Transition, the (row, from, event, to) scenarios
    Lifecycle/DormantEligibility.swift           the pure function, TaskMirrorReading, MirrorEntryStandIn
    Lifecycle/ListingPolicy.swift                the sidebar listing rules over C3's index fields
    Lifecycle/ProcessHandle.swift                ProcessHandle protocol, LiveProcessHandle (the wrapper over ClaudeProcess), ProcessFactory
    Lifecycle/ChannelSupervisor.swift            the actor
    Lifecycle/FleetCapCounter.swift              the cap as reservations (Task 4; the eviction path in Task 5)
    Lifecycle/RuntimeState.swift                 RuntimeStateUpdater and Readback
    Fleet/Records.swift                          RegistryRecord, RosterRecord, JobRecord, AgentsRow
    Fleet/HolderReader.swift                     HolderReader protocol, FileHolderReader, ProcessLiveness
    Fleet/FleetObserver.swift                    the actor: watcher, poll, reconciliation, HolderSet publication
    Fleet/OriginResolver.swift                   holders + supervisor state -> ChannelOrigin and Presence
    Ownership/OwnershipCheck.swift               beforeSpawn, afterHandshake, awaitRelease
    Verbs/CLIVerbs.swift                         over ProcessRunner
    Preconditions/TrustReader.swift
    Preconditions/ProjectMCPConsent.swift
    Preconditions/LocalSettingsStore.swift       the §6.12 write, descriptor-relative
    Preconditions/ManagedSettingsReader.swift
    Preconditions/SpawnPreconditions.swift
    Router/RouterTable.swift                     LocalCommand, RouteStrategy, the §7.7 table as data, LaunchSettingMatrix
    Router/CommandRouter.swift                   route(), StrategyExecutor, RefusalInterceptor
    Router/LogoutPlan.swift
    Activity/ActivityQuery.swift
    Diagnostics/FleetDiagnostics.swift           FleetDiagnosticEvent, FleetDiagnosticsSink, NullFleetDiagnostics (Task 3); FileFleetDiagnostics (Task 9)
    Fleet.swift                                  the facade implementing LifecycleAPI
  Tests/FleetSessionsTests/
    Support/ScratchConfigHome.swift              a temporary config home with sessions/, jobs/, daemon/, .claude.json
    Support/ScriptedHolderFiles.swift            writes registry, roster and job records
    Support/ScriptedProcessRunner.swift          argv-pattern -> (stdout, exit), with file mutations
    Support/TestClock.swift                      a manual Clock
    Support/FaultingFileOperations.swift         the store's fault injector, LockedBox
    Support/LiveGate.swift                       LiveBudget, the usage reading, ConfigHomeWitness
    Support/FakeClaudeLaunch.swift               LaunchConfiguration + ResolvedEnvironment for a fixture replay
    Support/ScriptedProcessHandle.swift          the handle for the wedged rows, the decision tests and the fork collision; its events are an AsyncStream the test feeds
    Support/RecordingHolderReader.swift          records beforeSpawn/afterHandshake calls
    Support/RecordingDiagnostics.swift           collects the (row, from, event, to) transitions a test observed
    StoreTests.swift                             Task 1
    LifecycleTableTests.swift, DormantEligibilityTests.swift, ListingPolicyTests.swift   Task 2
    RecordsTests.swift, HolderReaderTests.swift, FleetObserverTests.swift, CLIVerbsTests.swift   Task 3
    LifecycleRowTests.swift (+Restart, +Logout)  G1's row tests, accumulated over Tasks 4-8
    ProcessHandleTests.swift                     the scripted handle's stream flows through the existential seam, Task 4
    DecisionTests.swift                          answers and the event fan-out through the supervisor, Task 4
    LifecycleCoverageTests.swift                 G1's gate: the union of declared scenarios equals the table, Task 12
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
- Create: `FleetKit/Tests/FleetSessionsTests/Support/FaultingFileOperations.swift` (the fault injector for the atomicity test, and `LockedBox`)
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
    /// Every store in this file is built the way production builds one: through the single validating initialiser.
    func makeStore(_ dir: URL, ops: any StoreFileOperations = DarwinStoreFileOperations(),
                   diagnostics: @escaping @Sendable (StoreDiagnostic) -> Void = { _ in }) throws -> FileStateStore {
        try FileStateStore(baseDirectory: dir, configHomes: [], fileOperations: ops, onDiagnostic: diagnostics)
    }

    func testWriteThenReadRoundTripsAndDottedKeysAreOrdinary() async throws {
        let store = try makeStore(try tempDir())
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
        let dir = try tempDir(); let store = try makeStore(dir)
        try await store.write(1, namespace: .fleetKit, key: "a")
        try await store.write(2, namespace: .afleet, key: "b")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(Set(names), ["state.fleetKit.json", "state.afleet.json"])
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("state.fleetKit.json"))) as? [String: Any]
        XCTAssertEqual(doc?["schemaVersion"] as? Int, FileStateStore.schemaVersion)
        XCTAssertEqual(Set((doc?["values"] as? [String: Any])?.keys ?? []), ["a"])
        // Deliberate break: write one document for all namespaces -> the file set is wrong.
    }
    func testAFailureAtWriteFsyncOrRenameLeavesTheOldOrTheNewDocumentNeverAPartialOne() async throws {
        let new = Array(repeating: "new", count: 5_000)
        for point in FaultingFileOperations.Point.allCases {          // .create, .write (after a 4 KiB prefix landed), .fsync, .close, .rename, .fsyncDirectory
            let dir = try tempDir()
            let ops = FaultingFileOperations(failAt: point)            // passes every call through to Darwin until armed
            let store = try makeStore(dir, ops: ops)
            try await store.write(["old"], namespace: .fleetKit, key: "k")
            ops.arm()
            do { try await store.write(new, namespace: .fleetKit, key: "k"); XCTFail("\(point): the write did not fail") }
            catch let e as StoreError { guard case .io = e else { return XCTFail("\(point): \(e)") } }
            // A reader opened fresh on the directory sees a whole document: the old one when the rename never happened,
            // the new one when the fault came after it. Never a partial file, never nothing.
            let seen = try await makeStore(dir).read([String].self, namespace: .fleetKit, key: "k")
            // Every fault before the rename leaves the old document readable; only a fault after it (the directory fsync) shows the new one.
            XCTAssertEqual(seen, point == .fsyncDirectory ? new : ["old"], "\(point): partial or missing document")
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["state.fleetKit.json"], "\(point): the staging file was not removed")
            XCTAssertEqual(ops.removed.count, point == .fsyncDirectory ? 0 : 1, "\(point): the staging file was not removed through the seam")
            // Deliberate break: write the document in place with `Data.write(to:)` -> the `.write` fault leaves a truncated file and the read throws.
        }
    }
    func testANewerSchemaVersionIsReadForUnderstoodKeysRefusesWritesAndRaisesTheBanner() async throws {
        let dir = try tempDir()
        let newer = #"{"schemaVersion": 999, "values": {"k": 1, "fromTheFuture": {"x": 1}}}"#
        try Data(newer.utf8).write(to: dir.appendingPathComponent("state.fleetKit.json"))
        let store = try makeStore(dir)
        XCTAssertEqual(try await store.read(Int.self, namespace: .fleetKit, key: "k"), 1)   // the keys this build understands are readable
        do { try await store.write(2, namespace: .fleetKit, key: "k"); XCTFail("rewrote a document from the future") }
        catch let e as StoreError { guard case .schemaTooNew(found: 999, supported: FileStateStore.schemaVersion) = e else { return XCTFail("\(e)") } }
        XCTAssertEqual(await store.schemaStatus(of: .fleetKit), .newer(found: 999))       // the banner's source
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("state.fleetKit.json"), encoding: .utf8), newer)
        // Deliberate break: refuse the read as well -> the first assertion throws; ignore schemaVersion on write -> the file changes.
    }
    func testAMalformedDocumentIsMovedAsideWithADiagnosticAndTheNamespaceStartsEmpty() async throws {
        let dir = try tempDir()
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("state.fleetKit.json"))
        let seen = LockedBox<[StoreDiagnostic]>([])
        let store = try makeStore(dir, diagnostics: { seen.append($0) })
        XCTAssertEqual(try await store.keys(in: .fleetKit), [])
        try await store.write(1, namespace: .fleetKit, key: "k")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains("state.fleetKit.json"))
        XCTAssertTrue(names.contains { $0.hasPrefix("state.fleetKit.json.malformed-") })
        XCTAssertEqual(seen.value, [.malformedMovedAside(namespace: .fleetKit)])
        // Deliberate break: overwrite the malformed file in place -> one entry in the listing and no diagnostic.
    }
    func testAnOlderSchemaVersionIsMigratedPerNamespaceOnRead() async throws {
        let dir = try tempDir()
        // Version 0 is the reserved pre-release version whose migration to 1 is the identity; it exists so the chain is real.
        try Data(#"{"schemaVersion": 0, "values": {"k": 1}}"#.utf8).write(to: dir.appendingPathComponent("state.fleetKit.json"))
        let store = try makeStore(dir)
        XCTAssertEqual(try await store.read(Int.self, namespace: .fleetKit, key: "k"), 1)
        XCTAssertEqual(await store.schemaStatus(of: .fleetKit), .migrated(from: 0))
        try await store.write(2, namespace: .fleetKit, key: "k")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("state.fleetKit.json"))) as? [String: Any]
        XCTAssertEqual(doc?["schemaVersion"] as? Int, FileStateStore.schemaVersion)
        // Deliberate break: skip the migration table for version 0 -> the status is `.current` and a later real migration never runs.
    }
    func testABaseDirectoryInsideAConfigHomeIsRejectedByTheOnlyInitialiser() throws {
        let home = try tempDir()
        XCTAssertThrowsError(try FileStateStore(baseDirectory: home.appendingPathComponent("afleet"), configHomes: [home])) { e in
            guard case StoreError.insideConfigHome = e as? StoreError ?? .io("") else { return XCTFail("\(e)") }
        }
        // A real alias of the config home: `alias -> <home>`; `alias/sub` lies inside the home only once the link is resolved.
        let alias = try tempDir().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        XCTAssertThrowsError(try FileStateStore(baseDirectory: alias.appendingPathComponent("sub"), configHomes: [home])) { e in
            guard case StoreError.insideConfigHome = e as? StoreError ?? .io("") else { return XCTFail("alias: \(e)") }
        }
        XCTAssertNoThrow(try FileStateStore(baseDirectory: try tempDir(), configHomes: [home]))
        // Deliberate break: compare paths without resolving symlinks -> the alias case fails to throw.
    }
    func testRemoveDeletesOneKeyAndLeavesTheRest() async throws {
        let store = try makeStore(try tempDir())
        try await store.write(1, namespace: .fleetKit, key: "a"); try await store.write(2, namespace: .fleetKit, key: "b")
        try await store.remove(namespace: .fleetKit, key: "a")
        XCTAssertEqual(try await store.keys(in: .fleetKit), ["b"])
        XCTAssertNil(try await store.read(Int.self, namespace: .fleetKit, key: "a"))
    }
}
```

`Support/FaultingFileOperations.swift`: `final class FaultingFileOperations: StoreFileOperations, @unchecked Sendable` (lock-serialised) wrapping `DarwinStoreFileOperations`; `enum Point: CaseIterable { case create, write, fsync, close, rename, fsyncDirectory }`; `arm()` makes the next call at `failAt` throw `POSIXError(.EIO)` once and pass everything else through; at `.write` the fault lands after the first 4 KiB of the payload has been written through Darwin, so the staging file is partial when the error surfaces; `removed: [URL]` records every `remove` the store asked for. `LockedBox<T>` is a lock-guarded value with `append` for arrays.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit 2>&1 | tail -5`
Expected: build error `cannot find 'FileStateStore' in scope`.

- [ ] **Step 3: Implement the store**

`FleetKit/Sources/FleetSessions/Store/StateStore.swift`:

```swift
import Foundation

/// Closed: a namespace is a package, and there are three (X6). A fourth is a spec change, not a call site.
public enum StoreNamespace: String, CaseIterable, Hashable, Codable, Sendable { case fleetKit, workbench, afleet }

public enum StoreError: Error, Equatable, Sendable {
    case schemaTooNew(found: Int, supported: Int)
    case insideConfigHome
    case emptyKey
    case io(String)                      // the underlying error's description; never a path
}

/// What the store reports about a namespace's document; the app turns `.newer` into the banner.
public enum SchemaStatus: Hashable, Sendable { case current, migrated(from: Int), newer(found: Int), absent }

public enum StoreDiagnostic: Hashable, Sendable {
    case malformedMovedAside(namespace: StoreNamespace)
    case migrated(namespace: StoreNamespace, from: Int)
    case newerSchema(namespace: StoreNamespace, found: Int)
}

/// The seam every byte the store writes goes through. Production is Darwin's calls; the atomicity test injects faults.
public protocol StoreFileOperations: Sendable {
    /// Creates `directory/name` with `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`, mode 0o600, and returns the open descriptor and the URL.
    func create(in directory: URL, named name: String) throws -> (fd: Int32, url: URL)
    func write(_ data: Data, to fd: Int32) throws            // the whole payload, looping on short writes
    func fsync(_ fd: Int32) throws
    func close(_ fd: Int32) throws
    func rename(_ from: URL, to: URL) throws
    func fsyncDirectory(_ directory: URL) throws
    func remove(_ file: URL) throws
}
public struct DarwinStoreFileOperations: StoreFileOperations { public init() {} /* open/write/fsync/rename/close as named */ }

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

- `public actor FileStateStore: StateStore` with exactly one initialiser, `public init(baseDirectory: URL, configHomes: [URL], fileOperations: any StoreFileOperations = DarwinStoreFileOperations(), onDiagnostic: @escaping @Sendable (StoreDiagnostic) -> Void = { _ in }) throws`: it resolves every path with `URL.resolvingSymlinksInPath()`, throws `StoreError.insideConfigHome` when the base equals or lies under any config home, and creates the directory with mode 0o700 if absent. There is no unvalidated constructor and no `static validated(...)`; tests and the app construct it the same way. `public func schemaStatus(of: StoreNamespace) -> SchemaStatus`.
- `public static let schemaVersion = 1`. Document path `<base>/state.<namespace>.json`; envelope `{"schemaVersion": 1, "values": {"<key>": <json>}}` encoded with `JSONEncoder` using `.sortedKeys` so a rewrite of unchanged state is byte-identical.
- Values are stored as `JSONValue`-agnostic raw JSON: encode `T` with `JSONEncoder`, decode with `JSONSerialization` into `Any`, and keep the namespace document as `[String: Any]` in memory per namespace; on `read`, re-serialise the value and decode `T`. (No dependency on `WireFrames.JSONValue` here; the store is below the wire.)
- Schema handling per case, decided on the first touch of a namespace: **missing** → an empty namespace, status `.absent`. **Malformed** (does not parse, or parses without `schemaVersion` and `values`) → the file is renamed to `state.<namespace>.json.malformed-<yyyyMMdd-HHmmss>` through the seam, `onDiagnostic(.malformedMovedAside)`, and the namespace starts empty. **Older** → `Migrations.chain(for: namespace)` is applied step by step from the found version to `schemaVersion` on read (version 0 → 1 is the identity and is the one entry the table starts with), status `.migrated(from:)`, `onDiagnostic(.migrated)`, and the next write persists the current version. **Newer** → reads return the keys this build understands, every write and remove throws `.schemaTooNew`, status `.newer(found:)`, `onDiagnostic(.newerSchema)`; the file is never rewritten.
- Every write goes through `fileOperations` and nothing else: serialise the whole namespace document, `create` `<base>/.state.<namespace>.json.tmp-<uuid>`, `write` the document to its descriptor, `fsync` it, `close` it, `rename` over the document, `fsyncDirectory`. Any failure at any step closes the descriptor if it is still open and removes the temporary file (best effort, through the seam) and throws `.io(description)`; the in-memory document is refreshed from disk on the next operation so the actor never believes a write that did not land.
- An empty key throws `.emptyKey`.
- Containment: the initialiser resolves the longest existing prefix of `baseDirectory` with `realpath(3)`, appends the remaining components and compares the result against each config home resolved the same way, so `alias/sub` with `alias -> <configHome>` is refused whether or not `sub` exists yet.

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
Expected: `Executed 8 tests, with 0 failures`.

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
- Produces: every X5 value type exactly as the spec's *Types* block (including `PaneRequest.id`, `SessionRuntimeState`, `LifecycleAction.fork(at: ForkPoint?)`, `LifecycleAction.answer(RequestID, InboundAnswer)`, `LifecycleError.decisionGone`), `LifecycleTable.Row`, `LifecycleTable.Event`, `LifecycleTable.Transition`, `LifecycleTable.scenarios`, `DormantEligibility.evaluate`, `TaskMirrorReading` (with `isArmed`), `MirrorEntryStandIn`, `ListingPolicy.include`; Tasks 4–9 build on them.

- [ ] **Step 1: Write the failing tests**

`LifecycleTableTests.swift` pins the table as data:

```swift
import XCTest
@testable import FleetSessions

final class LifecycleTableTests: XCTestCase {
    func testTheTableHasOneRowPerParentRowAndEveryRowHasAScenario() {
        // The parent's §7.4 table, in its order; its combined "handoff wait exceeds 10 s, or desired and observed disagree"
        // row is two rows here because the two are raised from different places and G1 must see both fire.
        let expected: Set<LifecycleTable.Row> = [
            .archivedRecentOpened, .archivedOlderOpened, .archivedOlderSent,
            .connectingClean, .connectingFoundHolder,
            .readyDormantEligible, .dormantSent, .dormantHolderAppeared,
            .terminateExhausted, .exitedNonZero, .capReached,
            .jobAdopt, .ownedSendToBackground, .ownedOpenInTerminal, .ownTabExited,
            .foreignRecordGone, .foreignSendRefused, .handoffTimedOut, .desiredObservedDisagree, .contendedSettled,
        ]
        XCTAssertEqual(Set(LifecycleTable.Row.allCases), expected)
        XCTAssertEqual(Set(LifecycleTable.scenarios.map(\.row)), expected)
        // Deliberate break: drop every `.terminateExhausted` scenario -> the second assertion names it.
    }
    func testScenariosAreConcreteAndDistinct() {
        XCTAssertEqual(Set(LifecycleTable.scenarios).count, LifecycleTable.scenarios.count, "a duplicated scenario")
        // No `.any`: every scenario names the from-state it applies to, so coverage can demand each one.
    }
    func testTheTwoContendedEventsAndEveryTerminatingActionAreInTheTable() {
        XCTAssertTrue(LifecycleTable.scenarios.contains { $0.event == .handoffTimedOut })
        XCTAssertTrue(LifecycleTable.scenarios.contains { $0.event == .desiredObservedDisagree })
        let actions = Set(LifecycleTable.scenarios.compactMap { if case .terminateReturnedNil(let a) = $0.event { a } else { nil } })
        XCTAssertEqual(actions, Set(LifecycleTable.TerminatingAction.allCases))
        // Deliberate break: fold the disagreement into `.handoffTimedOut` -> the second assertion fails.
    }
    func testLookupReturnsEveryCandidateForAFromStateAndEvent() {
        let c = LifecycleTable.transitions(for: .holderAppeared, from: .dormant)
        XCTAssertEqual(Set(c.map(\.to)), [.foreignUsersTerminal, .backgroundJob])
        XCTAssertTrue(LifecycleTable.transitions(for: .opened, from: .ready).isEmpty)
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
    func entry(_ id: String, running: Bool, armed: Bool = false) -> MirrorEntryStandIn { .init(taskID: id, isRunning: running, isArmed: armed, isBackground: true) }
    func testAllFiveConditionsClearMeansEligible() { XCTAssertTrue(DormantEligibility.evaluate(base()).isEligible) }
    func testEachConditionAloneBlocks() {
        var i = base(); i.turnRunning = true; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.turnRunning))
        i = base(); i.pendingDecisions = 1; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.pendingDecision))
        i = base(); i.queuedInput = 1; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.queuedInput))
        i = base(); i.mirror = [entry("t1", running: true)]; XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskRunning("t1")))
    }
    /// The boundary cases Task 11 repeats over C3's real mirror; the two tests must agree case for case.
    func testTheMirrorBoundaryCases() {
        var i = base(); i.mirror = [entry("t1", running: false, armed: true)]
        XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskArmed("t1")))                       // armed blocks
        i = base(); i.mirror = [entry("t1", running: true)]; i.lastTaskFrameAge = .seconds(31)
        XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskStateUncertain("t1")))              // running and stale is uncertainty
        i = base(); i.mirror = [entry("t1", running: true)]; i.lastTaskFrameAge = .seconds(29)
        XCTAssertEqual(DormantEligibility.evaluate(i), .blocked(.taskRunning("t1")))                     // running and fresh is a running task
        i = base(); i.mirror = []; i.lastTaskFrameAge = .seconds(3_600)
        XCTAssertTrue(DormantEligibility.evaluate(i).isEligible)                                          // an old frame with nothing running or armed is history
        i = base(); i.mirror = [entry("t0", running: false)]; i.lastTaskFrameAge = .seconds(3_600)
        XCTAssertTrue(DormantEligibility.evaluate(i).isEligible)                                          // a completed entry is history too
        // Deliberate break: make any stale frame uncertain regardless of the mirror -> the fourth case blocks and a channel
        // that finished a task an hour ago never reaps.
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
    case decisionGone(RequestID)                  // an answer for an id that is unknown, cancelled, already answered or from an older epoch
}
```

`RestartRequest` uses double optionals as the spec shows; document on each: outer `nil` = keep the current value, inner `nil` = the CLI default. `PaneRequest.init` takes `id: UUID = UUID()` first, so every request the supervisor builds is fresh; `PaneExit` carries the request whole and the lifecycle compares `exit.request.id` only. `LifecycleAction.fork(at: ForkPoint?)` uses ClaudeWire's `ForkPoint`. `SessionRuntimeState` lives in `Types/ChannelState.swift` beside `RestartRequest`; `RestartSnapshot` is its typealias.

- [ ] **Step 4: Implement the table, eligibility and listing policy**

`Lifecycle/LifecycleTable.swift`:

```swift
import Foundation

/// The parent's §7.4 table as data. `scenarios` enumerates every `(row, from, event, to)` the supervisor may take, one per
/// from-state a row admits and per outcome it can reach; it is what G1's coverage asserts over and what the supervisor
/// consults before every transition, so a transition not in the table is a diagnostic, never a silent change.
public enum LifecycleTable {
    public enum Row: String, CaseIterable, Hashable, Sendable {
        case archivedRecentOpened, archivedOlderOpened, archivedOlderSent
        case connectingClean, connectingFoundHolder
        case readyDormantEligible, dormantSent, dormantHolderAppeared
        case terminateExhausted, exitedNonZero, capReached
        case jobAdopt, ownedSendToBackground, ownedOpenInTerminal, ownTabExited
        case foreignRecordGone, foreignSendRefused, handoffTimedOut, desiredObservedDisagree, contendedSettled
    }
    /// Every path that calls `terminateOrWedge()`; the wedged row has one scenario per action so G1 injects the `nil` through each.
    public enum TerminatingAction: String, CaseIterable, Hashable, Sendable { case reap, sendToBackground, openInTerminal, restart, logout, capEviction }
    public enum Event: Hashable, Sendable {
        case opened, userSent, handshakeClean, handshakeFoundHolder, dormantTimerFired, holderAppeared
        case terminateReturnedNil(during: TerminatingAction), exitedNonZero, seventhSpawnNeeded, adopt, sendToBackground, openInTerminal
        case paneExitedAndRecordGone, recordDisappeared, sendRefused, handoffTimedOut, desiredObservedDisagree, holdersSettled
    }
    /// The names the table speaks in; `ChannelState.name` maps a state to one of these. No wildcard: every scenario is concrete.
    public enum StateName: String, Hashable, Sendable {
        case archivedRecent, archivedOlder, connecting, ready, dormant, wedged, backgroundJob, foreignUsersTerminal, foreignOwnTab, contended
    }
    public struct Transition: Hashable, Sendable {
        public let row: Row; public let from: StateName; public let event: Event; public let to: StateName
        public init(_ row: Row, _ from: StateName, _ event: Event, _ to: StateName) { self.row = row; self.from = from; self.event = event; self.to = to }
    }
    public static let scenarios: [Transition] = [
        .init(.archivedRecentOpened, .archivedRecent, .opened, .connecting),
        .init(.archivedOlderOpened, .archivedOlder, .opened, .archivedOlder),
        .init(.archivedOlderSent, .archivedOlder, .userSent, .connecting),
        .init(.connectingClean, .connecting, .handshakeClean, .ready),
        .init(.connectingFoundHolder, .connecting, .handshakeFoundHolder, .foreignUsersTerminal),   // a foreign holder: yield, released notice
        .init(.connectingFoundHolder, .connecting, .handshakeFoundHolder, .contended),              // one of our own pids: yield, contended
        .init(.readyDormantEligible, .ready, .dormantTimerFired, .dormant),
        .init(.dormantSent, .dormant, .userSent, .connecting),
        .init(.dormantHolderAppeared, .dormant, .holderAppeared, .foreignUsersTerminal),
        .init(.dormantHolderAppeared, .dormant, .holderAppeared, .backgroundJob),
    ] + TerminatingAction.allCases.flatMap { action in
        // A dormant channel holds no process; the actions that terminate run from ready (all six) or connecting (a restart or logout can catch a handshake).
        [Transition(.terminateExhausted, .ready, .terminateReturnedNil(during: action), .wedged)]
        + (action == .restart || action == .logout ? [Transition(.terminateExhausted, .connecting, .terminateReturnedNil(during: action), .wedged)] : [])
    } + [
        .init(.exitedNonZero, .ready, .exitedNonZero, .connecting),          // crash after ready: respawn with backoff
        .init(.exitedNonZero, .connecting, .exitedNonZero, .connecting),     // crash during the handshake: respawn with backoff
        .init(.exitedNonZero, .ready, .exitedNonZero, .ready),               // fourth crash of a channel that had been ready: item with Reopen
        .init(.exitedNonZero, .connecting, .exitedNonZero, .archivedOlder),  // fourth crash of a channel never ready in this series
        .init(.capReached, .ready, .seventhSpawnNeeded, .dormant),           // the victim; a refusal is no transition (header note only)
        .init(.capReached, .dormant, .seventhSpawnNeeded, .dormant),         // an already-dormant LRU victim: no process to reap, slot freed by release
        .init(.jobAdopt, .backgroundJob, .adopt, .connecting),
        .init(.ownedSendToBackground, .ready, .sendToBackground, .backgroundJob),
        .init(.ownedSendToBackground, .dormant, .sendToBackground, .backgroundJob),
        .init(.ownedOpenInTerminal, .ready, .openInTerminal, .foreignOwnTab),
        .init(.ownedOpenInTerminal, .dormant, .openInTerminal, .foreignOwnTab),
        .init(.ownTabExited, .foreignOwnTab, .paneExitedAndRecordGone, .connecting),
        .init(.foreignRecordGone, .foreignUsersTerminal, .recordDisappeared, .archivedRecent),
        .init(.foreignSendRefused, .foreignUsersTerminal, .sendRefused, .foreignUsersTerminal),
        .init(.handoffTimedOut, .backgroundJob, .handoffTimedOut, .contended),        // adopt: the job did not leave
        .init(.handoffTimedOut, .ready, .handoffTimedOut, .contended),                // send to background / open in terminal: our record did not leave
        .init(.handoffTimedOut, .dormant, .handoffTimedOut, .contended),
        .init(.handoffTimedOut, .foreignOwnTab, .handoffTimedOut, .contended),        // pane exit: the tab's record did not leave
        .init(.desiredObservedDisagree, .connecting, .desiredObservedDisagree, .contended),
        .init(.desiredObservedDisagree, .ready, .desiredObservedDisagree, .contended),
        .init(.desiredObservedDisagree, .dormant, .desiredObservedDisagree, .contended),
        .init(.contendedSettled, .contended, .holdersSettled, .archivedRecent),
        .init(.contendedSettled, .contended, .holdersSettled, .ready),
        .init(.contendedSettled, .contended, .holdersSettled, .dormant),
        .init(.contendedSettled, .contended, .holdersSettled, .foreignUsersTerminal),
        .init(.contendedSettled, .contended, .holdersSettled, .backgroundJob),
    ]
    /// Every candidate for a from-state and event; the supervisor picks the one whose `to` is the outcome it resolved
    /// and records it, and an empty answer is `.transitionNotInTable`.
    public static func transitions(for event: Event, from state: StateName) -> [Transition] {
        scenarios.filter { $0.from == state && $0.event == event }
    }
}
```

`Lifecycle/DormantEligibility.swift`:

```swift
import Foundation

/// C3's registry-mirror entry, as much of X4 as eligibility reads. C3's real type conforms in Task 11; until then
/// `MirrorEntryStandIn` does. Reading a protocol, not a concrete type, is what makes G2 a swap rather than a rewrite.
/// `isArmed` and `isRunning` are separate facts: an armed task has been announced and not started; a running one has
/// started or updated and not yet been notified complete.
public protocol TaskMirrorReading: Sendable {
    var taskID: String { get }
    var isRunning: Bool { get }
    var isArmed: Bool { get }
    var isBackground: Bool { get }
}
public struct MirrorEntryStandIn: TaskMirrorReading, Hashable, Sendable {
    public var taskID: String; public var isRunning: Bool; public var isArmed: Bool; public var isBackground: Bool
    public init(taskID: String, isRunning: Bool, isArmed: Bool = false, isBackground: Bool) { self.taskID = taskID; self.isRunning = isRunning; self.isArmed = isArmed; self.isBackground = isBackground }
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
    public enum Blocker: Hashable, Sendable { case wedged, turnRunning, pendingDecision, queuedInput, taskRunning(String), taskArmed(String), taskStateUncertain(String) }
    public enum Verdict: Hashable, Sendable { case eligible, blocked(Blocker); public var isEligible: Bool { self == .eligible } }
    /// The parent's five conditions plus the wedged exclusion (ruling of 2026-09-05), in this order; the first blocker wins.
    /// Uncertainty is a property of a *running* task whose last frame is older than its heartbeat: the mirror may have
    /// missed the completion. With nothing running or armed, an old frame is history and blocks nothing.
    public static func evaluate(_ i: Input) -> Verdict {
        if i.wedged { return .blocked(.wedged) }
        if i.turnRunning { return .blocked(.turnRunning) }
        if i.pendingDecisions > 0 { return .blocked(.pendingDecision) }
        if i.queuedInput > 0 { return .blocked(.queuedInput) }
        if let running = i.mirror.first(where: { $0.isRunning }) {
            if let age = i.lastTaskFrameAge, age > i.heartbeatInterval { return .blocked(.taskStateUncertain(running.taskID)) }
            return .blocked(.taskRunning(running.taskID))
        }
        if let armed = i.mirror.first(where: { $0.isArmed }) { return .blocked(.taskArmed(armed.taskID)) }
        return .eligible
    }
}
```

`Lifecycle/ListingPolicy.swift`: `IndexEntry {sessionID, entrypoint, sessionKind, isSidechain, teamName, continuedIn}` (all `String?`/`Bool`, mirroring the fields C3's index exposes; Task 11 adds an initialiser from C3's real entry type); `Verdict = .listed(Mode) | .excluded(Reason)` with `Mode = .ownedCandidate | .readOnly(.teammate)` and `Reason = .sidechain | .continuedIn(String)`; `rules: [Rule]` as data with `name` and a closure, evaluated in order: `own-sdk-cli` (entrypoint == "sdk-cli" → listed owned), `sidechain` (isSidechain → excluded), `continued-in` (continuedIn != nil → excluded), `teammate` (teamName != nil → listed read-only), `default` (listed owned). `include(_:)` returns the first rule's verdict.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:"`
Expected: `Executed 22 tests, with 0 failures` (8 from Task 1 plus 14 here).

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
- Create: `FleetKit/Sources/FleetSessions/Diagnostics/FleetDiagnostics.swift` (the event vocabulary, the sink protocol and the null sink; Task 9 adds the file sink)
- Create: `FleetKit/Tests/FleetSessionsTests/Support/ScratchConfigHome.swift`, `Support/ScriptedHolderFiles.swift`, `Support/ScriptedProcessRunner.swift`, `Support/TestClock.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/RecordsTests.swift`, `HolderReaderTests.swift`, `FleetObserverTests.swift`, `CLIVerbsTests.swift`

**Interfaces:**
- Consumes: from Task 2: `Holder`, `HolderSet`, `ChannelKey`, `Presence`, `ForeignPresence`, `JobShort`; from `WireEnvironment`: `ProcessRunner`, `ProcessOutput`, `FoundationProcessRunner`; from `AfleetCore`: `ConfigHome`, `ResolvedEnvironment`, `SessionID`, `ChannelOrigin`.
- Produces: `RegistryRecord`, `RosterRecord`, `JobRecord`, `AgentsRow` (Codable), `ProcessLiveness.evaluate(pid:startedAt:procStart:) -> ProcessLiveness.Verdict` with `isLive(...)`, `startTime(of:)` and `procStartToken(for:)`, `HolderReader` protocol with `FileHolderReader` (which records the liveness fallbacks on its diagnostics sink), `FleetObserver` (actor) with `snapshot()`, `holders(for:)`, `updates`, `reconcileNow()`, `OriginResolver.resolve(...)`, `CLIVerbs`; test support `ScratchConfigHome`, `ScriptedHolderFiles`, `ScriptedProcessRunner`, `TestClock`. Tasks 4–10 use all of them. Also `FleetDiagnosticEvent` (closed enum), `FleetDiagnosticsSink` and `NullFleetDiagnostics`, consumed by `CLIVerbs` here and by every later task.

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

`Support/ScriptedHolderFiles.swift`: `writeRegistry(pid:sessionID:kind:entrypoint:startedAt:procStart:status:waitingFor:name:)` writes `sessions/<pid>.json` with exactly the field names in `RegistryRecord`, where `procStart: ProcStartField = .correct` writes `ProcessLiveness.procStartToken(for: pid)` (the CLI's own format), `.absent` omits the field and `.literal(String)` writes what the test says; `removeRegistry(pid:)`; `writeJob(short:state:sessionID:resumeSessionID:cwd:pid:)` writes `jobs/<short>/state.json` and, when `pid` is given, adds `workers[<short>] = {pid, procStart: <the pid's token>}` to the roster; `stopJob(short:)` sets `state: "stopped"` and removes the worker. Pids used for "live foreign holders" are the test's own pid (alive, start time known) unless a test wants a dead holder, which uses pid 2_147_483_000 (never live).

`Support/ScriptedProcessRunner.swift`: `struct ScriptedProcessRunner: ProcessRunner` holding `rules: [(match: [String] -> Bool, respond: ([String]) throws -> ProcessOutput)]` and a `Recorder` of invocations (copy the recorder shape from `ClaudeWire/Sources/WireTestSupport/ScriptedRunner.swift`, which is not exported); a rule may mutate scripted files through a captured `ScriptedHolderFiles`. Default rules: `agents --json` → the JSON array built from the current scripted files (the same shape as `AgentsRow`); `stop <short>` → `stopJob(short)`, exit 0; `--bg --resume <id>` → creates a job with `resumeSessionId == id`, exit 0; `--bg --exec <cmd>` → creates a job with no `sessionId`; `auth logout` → exit 0; `auth status` → `{"loggedIn": false}`; anything else → exit 1.

- [ ] **Step 2: Write the failing tests**

`RecordsTests.swift`: decode a registry record with every field the CLI writes (the spec's *Grounding* list) plus an unknown field and assert the typed fields and that `RegistryRecord` keeps unknown keys out of the way (they are dropped; the record is read-only); decode the three job states and the roster; decode an `agents --json` array containing one job row with `state: "working"` and one interactive registry row without `state`; assert a record whose `pid` is a string is rejected as `nil` rather than thrown (the CLI's own reader drops mistyped fields). Deliberate break: mistype `sessionId` as `session_id` in `CodingKeys` → every decode fails.

`HolderReaderTests.swift`:
- `testALiveRegistryRecordIsAHolderAndADeadOneIsNot`: two records, one with the test's pid and its real start time, one with the never-live pid; the reader returns one holder. Deliberate break: skip liveness → two holders.
- `testAReusedPIDIsNotAHolder`: the test's pid with `startedAt` one day before the process started and `procStart: .absent` → not a holder, and the reader's sink recorded `.procStartAbsent(pid:)`; the same record with `procStart: .literal("scripted")` → not a holder, `.procStartUnparseable(pid:)`. Deliberate break: drop the start-time window → a holder.
- `testAWrongProcStartRejectsTheHolderEvenInsideTheStartedAtWindow`: the test's pid, `startedAt` now (inside the sixty-second window) and `procStart: .literal(<the pid's own token moved one minute later>)` → not a holder (`.startMismatch`), no fallback diagnostic; the correct token with `startedAt` one day off → a holder, because a present, parseable `procStart` is the comparison and the window is only the fallback. Deliberate break: consult the window whenever `startedAt` is inside it → the first half is a holder.
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
    public enum Fallback: Hashable, Sendable { case procStartAbsent, procStartUnparseable }
    public enum Verdict: Hashable, Sendable { case dead, live, liveByWindow(Fallback), startMismatch, unverifiable; public var isLive: Bool }
    /// `kill(pid, 0)` must succeed (or fail with EPERM, which still means a live process), else `.dead`. Then the process's
    /// start time from `proc_pidinfo(PROC_PIDTBSDINFO).pbi_start_tvsec` is compared with the record's `procStart`, the CLI's
    /// own token (bundle 515820: the trimmed `ps -o lstart=` string under `LC_ALL=C TZ=UTC`, e.g. `Fri Sep  5 03:12:41 2026`),
    /// parsed as `EEE MMM d HH:mm:ss yyyy` with `en_US_POSIX` and UTC after collapsing runs of spaces: `|pbi_start_tvsec - parsed| <= 1 s`
    /// is `.live`, anything else `.startMismatch`. Only when `procStart` is absent or does not parse does the sixty-second
    /// `window` around `startedAt` (milliseconds since the epoch) decide, as `.liveByWindow(reason)` or `.dead`; a record with
    /// neither a usable token nor a `startedAt` (a roster worker with a bad token) is `.unverifiable`, which is not live.
    public static func evaluate(pid: Int32, startedAt: Double?, procStart: String?, window: Duration = .seconds(60)) -> Verdict
    public static func isLive(pid: Int32, startedAt: Double?, procStart: String?, window: Duration = .seconds(60)) -> Bool   // evaluate(...).isLive
    public static func startTime(of pid: Int32) -> Date?
    /// The token the CLI would write for `pid`: `startTime(of:)` formatted the same way (the day padded to width two with a space).
    public static func procStartToken(for pid: Int32) -> String?
}
public struct HolderSnapshot: Sendable {
    public var holders: HolderSet; public var jobs: [JobShort: JobRecord]; public var skipped: Int
}
public protocol HolderReader: Sendable {
    /// Every holder under the config home right now: registry, roster+jobs, and (when `includeAgentsJSON`) the CLI listing.
    func read(configHome: ConfigHome, ownPIDs: Set<Int32>, includeAgentsJSON: Bool) async -> HolderSnapshot
}
public struct FileHolderReader: HolderReader {
    public init(verbs: CLIVerbs?, diagnostics: any FleetDiagnosticsSink = NullFleetDiagnostics())   // nil = never run agents --json (tests that do not want it); the sink receives the liveness fallbacks
}
```

Reconciliation in `FileHolderReader.read`: build holders from the registry (records whose `ProcessLiveness.evaluate(pid:startedAt:procStart:)` is `.live` or `.liveByWindow`, the latter recorded on the sink as `.procStartAbsent(pid:)` or `.procStartUnparseable(pid:)`), then jobs (live when the worker's pid and `procStart` pass the same evaluation; a worker has no `startedAt`, so a bad token there is `.unverifiable` and not a holder), merging by pid into one `Holder` whose `sources` union grows; then `agents --json` rows matched by pid, or by `(id, sessionId)` to a job when the row has no pid; a row matching nothing becomes a holder with source `[.agentsJSON]` only when it carries a pid that is live. `isOwnChild = ownPIDs.contains(pid)`. `presence` from `status`/`waitingFor`/`name` when present.

- [ ] **Step 5: Implement the observer, origin resolver and verbs**

`Fleet/FleetObserver.swift`: `public actor FleetObserver` with `init(configHome:reader:clock:ownPIDs: @Sendable () async -> Set<Int32>, pollInterval: .seconds(5), reconcileInterval: .seconds(60))`; `start()` arms a vnode `DispatchSource` on `sessions/`, `jobs/` and `daemon/` (file descriptors opened `O_EVTONLY`; events `.write | .delete | .rename | .link`) whose handler calls `refresh(agentsJSON: false)`, and two tasks sleeping on the clock: the poll (`refresh(agentsJSON: false)`) and the reconciliation (`refresh(agentsJSON: true)`); `refresh` reads through the `HolderReader`, and publishes the new `HolderSet` on `updates: AsyncStream<HolderSet>` only when it differs from the last; `snapshot()` returns the last; `holders(for session: SessionID) -> [Holder]`; `reconcileNow()` runs a refresh with `agentsJSON: true` synchronously and returns the snapshot (Tasks 4 and 5 call it from the ownership checks); `stop()` cancels the tasks and the sources.

`Fleet/OriginResolver.swift`: `static func resolve(key:, ownedState: OwnedView?, holders: [Holder], pendingHatch: Bool) -> (ChannelOrigin, Presence)` in the parent's order: owned when `ownedState` is non-nil; foreign live when a live registry holder that is not ours names the session (`.ownTerminalTab` when `pendingHatch`, else `.usersTerminal`); background job when a live job holder names it; else archived. Presence for foreign from `ForeignPresence`, `.unknown` when absent; for owned from `OwnedView {turnRunning, pendingDecisions, sessionStateRequiresAction}`.

`Diagnostics/FleetDiagnostics.swift` (created here because `CLIVerbs` and Task 4's supervisor record on it; Task 9 adds the file sink):

```swift
import Foundation
import WireFrames

/// FleetKit's own diagnostics vocabulary, one JSON line per event in the app's diagnostics directory beside C2's file.
/// Structural fields only: names, counts, ids, epochs, durations. Never a path under a config home, an environment,
/// a record or stdout (parent §6.3).
public enum FleetDiagnosticEvent: Sendable {
    case transition(row: String, from: String, event: String, to: String, session: String, epoch: UInt64?)   // the (row, from, event, to) the rig's RecordingDiagnostics collects
    case transitionNotInTable(event: String, from: String, to: String, session: String)
    case ownershipCheck(label: String, foreignHolders: Int, session: String)
    case handoffWait(outcome: String, waitedMs: Int, session: String)
    case verb(name: String, exitCode: Int32, durationMs: Int)
    case precondition(verdict: String, session: String)
    case declineWrite(outcome: String, servers: Int)
    case paneRequest(id: UUID, purpose: String, session: String?)
    case staleExit(id: UUID, purpose: String)
    case jobNotListedAfterBackground(session: String)
    case wedged(session: String, steps: Int)
    case procStartAbsent(pid: Int32)                    // liveness fell back to the startedAt window
    case procStartUnparseable(pid: Int32)
    case capDecision(decision: String, live: Int, reserved: Int)
    case evictionOutcome(outcome: String, victim: String)
    case logout(step: String, count: Int)
    case driftRefusalIntercepted(command: String)
    public var jsonValue: JSONValue { /* object with "event" plus the case's fields, keys in snake_case */ }
}
public protocol FleetDiagnosticsSink: Sendable { func record(_ event: FleetDiagnosticEvent) }
public struct NullFleetDiagnostics: FleetDiagnosticsSink { public init() {}; public func record(_ event: FleetDiagnosticEvent) {} }
```

`Verbs/CLIVerbs.swift`: `public struct CLIVerbs: Sendable { init(runner: any ProcessRunner, binary: URL, environment: [String: String], diagnostics: any FleetDiagnosticsSink, timeout: Duration = .seconds(20)) }` — the environment is `LaunchConfiguration(...).childEnvironment(over:configHome:)` for a dummy launch in the config home (Task 9's facade composes it once); methods as the spec's *CLI verbs* section; each records `.verb(name, exitCode, durationMs)`; a non-zero exit throws `LifecycleError.verbFailed`. `FleetDiagnosticsSink` is defined in Task 9; for this task define it minimally in `Diagnostics/FleetDiagnostics.swift` with the `verb` case and a `NullFleetDiagnostics`, and Task 9 extends it.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:"`
Expected: `Executed 41 tests, with 0 failures` (22 from before plus 19 here; adjust the number to the count actually written and quote it in the commit body).

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
- Create: `FleetKit/Sources/FleetSessions/Lifecycle/FleetCapCounter.swift` (the counter with reservations; Task 5 adds the eviction path)
- Create: `FleetKit/Tests/FleetSessionsTests/Support/FakeClaudeLaunch.swift`, `Support/RecordingHolderReader.swift`, `Support/ScriptedProcessHandle.swift`, `Support/RecordingDiagnostics.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/LifecycleRowTests.swift`, `ProcessHandleTests.swift`, `DecisionTests.swift`

**Interfaces:**
- Consumes: Task 2's types and table; Task 3's `FleetObserver`, `HolderReader`, `CLIVerbs`, `FleetDiagnosticsSink`, `TestClock`, `ScratchConfigHome`, `ScriptedHolderFiles`; `ClaudeWire`'s `ClaudeProcess`, `LaunchConfiguration`, `WireEvent`, `Handshake`, `ExitStatus`, `AfleetMCPServer`, `SendUserFileTool`, `NullDiagnostics`, `InboundRequest`, `RequestID`, `InboundAnswer`.
- Produces: `ProcessHandle`, `LiveProcessHandle`, `ProcessFactory`, `ChannelSupervisor` with `open()`, `send(_:)`, `answer(_:_:)`, `events() -> AsyncStream<WireEvent>`, `shutdown()`, `state`, `updates`, `reap()`, `handle(event:)`; `FleetCapCounter` with `acquire`, `confirm`, `rollback`, `release`, `setEligibility(_:_:)`, `noteActivity`, `markWedged`, `clearWedged`; `OwnershipCheck`; rows `archivedRecentOpened`, `archivedOlderOpened`, `archivedOlderSent`, `connectingClean`, `connectingFoundHolder`, `readyDormantEligible`, `dormantSent`, `dormantHolderAppeared`, `exitedNonZero` covered. Task 5 adds the rest.

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

`Support/ScriptedProcessHandle.swift`: `final class ScriptedProcessHandle: ProcessHandle, @unchecked Sendable` (lock-serialised) whose `spawn` returns a canned `Handshake`, whose `events` is an `AsyncStream<WireEvent>` whose continuation the test holds (`push(_ event: WireEvent)`, `finish()`; nothing outside ClaudeWire can construct or feed a `WireEventStream`, which is why the protocol's `events` is an existential), whose `terminate()` returns what the test set (`nil` for the wedged rows), whose `answer(_:_:)` appends `(id, answer)` to `answers` and throws what the test scripted (`answerError`), and whose `childProcessIdentifier` is a value the test chooses. Used only where the plan says: the wedged rows, the decision tests, the fork collision.

`ProcessHandleTests.swift`:
- `testTheScriptedHandleDeliversAPushedEvent`: construct a `ScriptedProcessHandle`, hold it as `any ProcessHandle`, start a task that iterates `events` (the existential `any AsyncSequence<WireEvent, Never> & Sendable`), `push(.requestCancelled(RequestID(rawValue: "r-1"), .first))`, `finish()` → the task observed exactly that event and then the end of the stream. The test exists to prove the seam compiles and flows before any row depends on it. Deliberate break: type `events` as `WireEventStream<WireEvent>` → the scripted handle cannot conform (the stream has no reachable initialiser) and the file does not build.

`DecisionTests.swift` (the scripted handle throughout, via `rig.useScriptedHandle(terminateReturns: .code(0, stderrTail: ""))`; the rig's scripted factory hands out a fresh handle per spawn and keeps them in `rig.scriptedHandles`; `allow` is one `InboundAnswer.permission` value the test builds; `r` is an `InboundRequest` built with ClaudeWire's public initialiser, id `d-1`, the handle's epoch, a `canUseTool` payload):
- `testAnswerResolvesAPendingDecisionOnlyAfterTheProcessAccepts`: ready; push `.request(r)` → `state.pendingDecisions == 1` and the channel is not dormant-eligible; `perform(.answer("d-1", allow))` (the scripted `answer` succeeds) → the handle's `answers == [("d-1", allow)]` and `pendingDecisions == 0`; with `answerError` set, the call throws that error, the id stays pending and no transition was recorded. Deliberate break: remove the id before awaiting `process.answer` → a failed answer leaves `pendingDecisions == 0` and the dormant timer may reap a channel with a live dialog.
- `testAnsweringACancelledDecisionThrowsDecisionGone`: push `.request(r)`, then `.requestCancelled("d-1", epoch)` → `pendingDecisions == 0`; `perform(.answer("d-1", allow))` throws `LifecycleError.decisionGone("d-1")` and `answers` is empty. Deliberate break: forward unknown ids to the process → the handle recorded an answer for a request the engine withdrew.
- `testADuplicateAnswerThrowsDecisionGone`: answer `d-1` once (recorded), then again → `decisionGone`, `answers.count == 1`.
- `testAnAnswerFromAnOlderEpochThrowsDecisionGoneAfterARespawn`: push `.request(r)` in epoch 1, then `.exited(.code(1, stderrTail: ""), epoch 1)` and `finish()`; advance the clock past the 1 s backoff so the supervisor respawns (epoch 2, the second scripted handle); `perform(.answer("d-1", allow))` → `decisionGone`; neither handle recorded an answer and `pendingDecisions == 0`. Deliberate break: keep `pendingDecisions` across an exit → the answer is forwarded to a process that never asked.
- `testTwoEventSubscribersSeeTheSameFrames`: two `supervisor.events()` streams taken before any push; push four events (three `.requestCancelled` with distinct ids, one `.request(r)`); both streams yield the same four events in order and `pendingDecisions == 1`; a third stream taken after the pushes sees only what follows; `rig.shutdown()` finishes every stream (as archiving the channel does). Deliberate break: hand the same continuation to every subscriber → the second stream is empty.

- [ ] **Step 2: Write the failing tests for this task's rows**

`LifecycleRowTests.swift` — the harness and the coverage map are the decision:

```swift
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// One test per parent §7.4 row, and one declared scenario set per test. `coverage` maps every test method to the
/// `(row, from, event, to)` scenarios it drives; each test ends with `rig.assertObserved(Self.coverage[#function]!)`,
/// which compares the transitions the supervisor recorded on the diagnostics sink with the declared set (extra
/// transitions fail too). Task 12's `LifecycleCoverageTests` asserts that the union of the declared sets equals
/// `LifecycleTable.scenarios`, so a row, a from-state or an outcome added to the table without a test that drives it
/// fails the gate; until then each task's tests assert exactly the scenarios it has landed.
final class LifecycleRowTests: XCTestCase {
    typealias T = LifecycleTable.Transition
    static let coverage: [String: Set<T>] = [
        "testArchivedRecentOpenedSpawnsEagerly": [T(.archivedRecentOpened, .archivedRecent, .opened, .connecting), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testArchivedOlderOpenedRendersHistoryOnly": [T(.archivedOlderOpened, .archivedOlder, .opened, .archivedOlder)],
        "testArchivedOlderSentSpawnsThenSends": [T(.archivedOlderSent, .archivedOlder, .userSent, .connecting), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testConnectingBecomesReadyWhenThePostHandshakeCheckIsClean": [T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testConnectingYieldsWhenThePostHandshakeCheckFindsAForeignHolder": [T(.connectingFoundHolder, .connecting, .handshakeFoundHolder, .foreignUsersTerminal)],
        "testTwoOwnProcessesOnOneSessionRefuseBeforeSpawnAndYieldAfterHandshake": [T(.connectingFoundHolder, .connecting, .handshakeFoundHolder, .contended)],
        "testReadyReapsAfterThirtyMinutesEligibleAndNotWhileATaskRuns": [T(.readyDormantEligible, .ready, .dormantTimerFired, .dormant)],
        "testDormantSendResumesUnderTheSameSessionID": [T(.dormantSent, .dormant, .userSent, .connecting), T(.connectingClean, .connecting, .handshakeClean, .ready)],
        "testDormantBecomesForeignOrJobWhenAHolderAppears": [T(.dormantHolderAppeared, .dormant, .holderAppeared, .foreignUsersTerminal), T(.dormantHolderAppeared, .dormant, .holderAppeared, .backgroundJob)],
        "testNonZeroExitRespawnsWithBackoffThenOffersReopen": [
            T(.exitedNonZero, .ready, .exitedNonZero, .connecting), T(.exitedNonZero, .connecting, .exitedNonZero, .connecting),
            T(.exitedNonZero, .ready, .exitedNonZero, .ready), T(.exitedNonZero, .connecting, .exitedNonZero, .archivedOlder),
            T(.connectingClean, .connecting, .handshakeClean, .ready)],
        // Task 5 adds: terminateExhausted for reap, sendToBackground, openInTerminal and capEviction; capReached (both);
        // jobAdopt; ownedSendToBackground (both); ownedOpenInTerminal (both); ownTabExited; foreignRecordGone;
        // foreignSendRefused; handoffTimedOut (four); desiredObservedDisagree (three); contendedSettled (five).
        // Task 6 adds terminateExhausted during restart (two); Task 8 adds terminateExhausted during logout (two).
    ]
    // Tasks 5, 6 and 8 add their test methods (Task 5 here, Tasks 6 and 8 in extension files) and their entries to this
    // literal; nothing is registered at runtime. Task 12's gate reads this dictionary.
}
```

The harness (`struct Rig`) each row test builds: a `ScratchConfigHome`, `ScriptedHolderFiles`, a `TestClock`, a `RecordingHolderReader` over a `FileHolderReader(verbs: CLIVerbs(runner: ScriptedProcessRunner(...)))`, a `FleetObserver`, a `ProcessFactory` that builds a real `ClaudeProcess` from `FakeClaudeLaunch` (default fixture `resume-no-replay`, session `.resume(fixtureSessionID, fork: false)`) wrapped in `LiveProcessHandle`, and the `ChannelSupervisor` for `ChannelKey(configHome: scratch.url, session: fixtureSessionID)` with `recentActivityCutoff` satisfied or not per test (a `Bool` the rig passes: whether the channel counts as recent, since C3's index is not here); a `RecordingDiagnostics` sink whose `transitions` are the `(row, from, event, to)` tuples the supervisor recorded, with `assertObserved(_ expected: Set<T>)` comparing them as a set (an unexpected extra transition fails as surely as a missing one); and `rig.useScriptedHandle(terminateReturns:)`, which swaps the factory for one that returns a fresh `ScriptedProcessHandle` per spawn (canned handshake, events pushed by the test through `rig.scriptedHandles.last!`, `terminate()` answering the value given; `nil` for the wedged rows). `rig.shutdown()` calls `ChannelSupervisor.shutdown()` on every supervisor the rig built: it finishes every subscriber stream and cancels the dormant timer, terminating nothing (the facade calls the same at app exit). The behaviours each row test asserts:

- `archivedRecentOpened`: `open()` → the reader recorded `beforeSpawn`; a process was spawned (factory called once); state `.owned(.connecting)` then `.owned(.ready)`. Deliberate break: skip the pre-spawn check → the reader's labels lack `beforeSpawn`.
- `archivedOlderOpened`: `open()` on a non-recent channel → factory never called; state `.archived`.
- `archivedOlderSent`: `send("hi")` on a non-recent channel → spawn, then the send goes after `.ready` (the fixture `plain-two-turn` replays a turn; assert a `.frame(.user)` or the `result` frame was observed after the handshake and that the `send` returned a uuid).
- `connectingClean`: after the handshake, the reader recorded `afterHandshake` with `ownPID == childPID` and the state is `.owned(.ready)`. Deliberate break: skip the post-handshake read → labels lack it.
- `testTwoOwnProcessesOnOneSessionRefuseBeforeSpawnAndYieldAfterHandshake` (row `connectingFoundHolder`, the own-pid scenario): two supervisors in one rig on one session id and one config home. First half: A is ready; B's `open()` → B's `beforeSpawn` sees A's pid (ours, `entrypoint: "sdk-cli"`) → no spawn (factory called once in total), B is `.owned(.contended)` with `banner == .contended(set)` naming A's pid; A untouched. Second half (the race): the recording reader's `onLabel("beforeSpawn")` hook hides A's record from B's pre-check once, so B spawns; B's `afterHandshake(session:, ownPID: B's child, epoch:)` sees A's pid, which is not the pid it excludes → B's process is terminated, B is `.owned(.contended)`; A's process is alive and A's state unchanged (assert A's `updates` published nothing). Deliberate break: exclude every own pid in `afterHandshake` → B keeps the session and two of our processes own one transcript.
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

/// What the supervisor needs from a process. The live conformance is `LiveProcessHandle`, a thin wrapper over
/// `ClaudeProcess`; the seam exists so the one row no real child can produce (wedged: `terminate()` returning nil), the
/// decision tests and the fork collision run against a scripted handle. `events` is an existential because ClaudeWire's
/// `WireEventStream` has an internal initialiser and can be neither constructed nor fed outside its module (`main`
/// `BoundedChannel.swift:110-118`); its failure type is `Never` because the stream's `next()` does not throw.
public protocol ProcessHandle: Sendable {
    var epoch: ProcessEpoch { get }
    var events: any AsyncSequence<WireEvent, Never> & Sendable { get }
    var childProcessIdentifier: Int32 { get async }
    var sessionID: SessionID? { get async }
    func spawn(handshakeTimeout: Duration) async throws -> Handshake
    func send(_ input: UserInput) async throws -> UUID
    func request<R: ControlRequestSpec>(_ spec: R, timeout: Duration?) async throws -> R.Response
    func requestRaw(subtype: String, payload: JSONValue, timeout: Duration?) async throws -> JSONValue
    func answer(_ id: RequestID, _ answer: InboundAnswer) async throws
    func terminate() async -> ExitStatus?
}
/// The live conformance. A retroactive `extension ClaudeProcess: ProcessHandle {}` cannot witness the existential `events`
/// with the actor's concrete `WireEventStream<WireEvent>`, so this wrapper forwards every member and exposes the very same
/// stream value as the existential: ClaudeWire's bounded channel and its backpressure are untouched, nothing is re-pumped.
public final class LiveProcessHandle: ProcessHandle {
    public let process: ClaudeProcess
    public init(_ process: ClaudeProcess) { self.process = process }
    public var epoch: ProcessEpoch { process.epoch }
    public var events: any AsyncSequence<WireEvent, Never> & Sendable { process.events }
    /* every other member forwards as `await process.<member>` */
}
public typealias ProcessFactory = @Sendable (ProcessEpoch, LaunchConfiguration) -> any ProcessHandle
```

`Ownership/OwnershipCheck.swift`: `struct OwnershipCheck` with `beforeSpawn(session:) async -> [Holder]` (calls `observer.reconcileNow(label: "beforeSpawn")` and returns **every** live holder naming the session, foreign or ours: before a spawn the supervisor holds no process, so there is no pid to excuse; a holder that is one of our own children, from a second supervisor or an older epoch, is returned too and the caller treats it as Contended rather than foreign live), `afterHandshake(session:, ownPID: Int32, epoch: ProcessEpoch) async -> [Holder]` (label `afterHandshake`; validates each holder through `ProcessLiveness` again and excludes exactly one pid, `ownPID`, the child this spawn started; every other pid, foreign or ours, is returned), `awaitRelease(previous: Holder, upTo: Duration) async -> ReleaseOutcome` (`.released` when the pid is dead *and* its registry or roster record is gone, polling the reader every 500 ms on the clock; `.timedOut` after `upTo`). `Holder.isOwnChild` stays informational for the sidebar; neither check reads it to excuse a holder.

`Lifecycle/ChannelSupervisor.swift` — decisions:

- `public actor ChannelSupervisor` with `init(key:, launchTemplate: LaunchConfiguration, factory: ProcessFactory, ownership: OwnershipCheck, observer: FleetObserver, clock: any Clock<Duration>, eligibilityInputs: @Sendable () async -> DormantEligibility.Input, fleet: FleetCapCounter, diagnostics: any FleetDiagnosticsSink, isRecent: Bool)`.
- State: `state: ChannelState`, `epoch: ProcessEpoch` (starts `.first`, `.next()` on every spawn), `process: (any ProcessHandle)?`, `activitySequence: UInt64` (the LRU key; incremented on every send, frame and decision), `turnRunning`, `pendingDecisions: Set<RequestID>`, `queuedInput: [UserInput]`, `pendingHatch: PaneRequest?`, `crashCount`, `dormantTimer: Task<Void, Never>?`, `subscribers: [UUID: AsyncStream<WireEvent>.Continuation]` (the fan-out `events()` returns).
- `updates: AsyncStream<ChannelState>` publishes after every transition; every transition goes through `apply(_ event: Event, to: StateName)`, which looks up `LifecycleTable.transitions(for: event, from: currentName)`, picks the candidate whose `to` matches, records `.transition(row, from, event, to)` on the diagnostics and mutates the state; no candidate records `.transitionNotInTable(event, fromName, toName)` and does nothing else.
- `spawn(reason:)`: `fleet.acquire(for: key)` first: `.refused(live:)` → `throw LifecycleError.capReached`; `.evict(victim, reservation)` → Task 5's eviction with its reported outcome; `.granted(reservation)` → continue. Then `ownership.beforeSpawn`; any holder → `fleet.rollback(reservation)`, no spawn, and the origin becomes foreign, job or contended (a holder that is ours) by `OriginResolver`; otherwise `epoch = epoch.next()`, `process = factory(epoch, launch)`, start the event pump task (`for await ev in process.events`, discarding events whose epoch is older than `epoch`), `spawn(handshakeTimeout: 30 s)`, then `ownership.afterHandshake(session:, ownPID: await process.childProcessIdentifier, epoch:)`; a holder → `terminateOrWedge()`, `fleet.rollback(reservation)`, `apply(.handshakeFoundHolder, to: .foreignUsersTerminal)` with `banner = .releasedToTerminal` for a foreign holder or `apply(.handshakeFoundHolder, to: .contended)` with `banner = .contended(set)` for one of ours; clean → `fleet.confirm(reservation)` and then, unless `reason == .restart` (Task 6 runs the readbacks first and applies the ready transition itself), `apply(.handshakeClean, to: .ready)` and `armDormantTimer()`.
- The event pump: `.frame(.result)` → `turnRunning = false`, `armDormantTimer()`; `.frame(.user)` from a send → `turnRunning = true`; every event is first yielded to every continuation in `subscribers`; `.request` → insert its id into `pendingDecisions`; `.requestCancelled` → remove it (an answer removes it only after `process.answer` returned, below); `.frame(.system(.initialize))` → `apiKeySource` and `mcpServers` recorded; `.sessionIdentityResolved(id)` → re-key (Task 6); `.exited(status, epoch)` → `handleExit`.
- `armDormantTimer()`: cancel the previous; `Task { try? await clock.sleep(for: .seconds(1800)); await self.dormantTimerFired() }`; `dormantTimerFired()` evaluates `DormantEligibility.evaluate(await eligibilityInputs())` merged with the supervisor's own counts; eligible → `reap()`; blocked → re-arm.
- Eligibility is pushed, never pulled: every change to `turnRunning`, `pendingDecisions`, `queuedInput`, `wedged` or the mirror reading re-evaluates `DormantEligibility.evaluate(...)` and calls `fleet.setEligibility(key, verdict)`, so the counter's decision never awaits a supervisor.
- `answer(_ id: RequestID, _ answer: InboundAnswer)` (the facade's `perform(.answer(id, answer), on:)`): the id must be in `pendingDecisions`, which is emptied on every exit, else `throw LifecycleError.decisionGone(id)` (unknown, cancelled, already answered, or asked by an older epoch's process); `try await process.answer(id, answer)`; only then remove the id and `noteActivity`. The channel, the shell's overlay and the Activity view answer through this and nothing else.
- `events() -> AsyncStream<WireEvent>`: a new unbounded stream per call, its continuation stored in `subscribers` under a fresh `UUID` and dropped on termination; the pump yields every event to every subscriber; archiving the channel or `shutdown()` finishes them all. This is the only way a wire frame leaves the supervisor: the facade's `events(of:)` (Task 9) returns it and the shell's preview and ephemeral overlay and C3's live feed consume it (parent lines 226-232 and 869-876: wire frames feed the overlay, decisions are answered by sending the control response, only the supervisor holds the process).
- `terminateOrWedge(during action: TerminatingAction) async -> TerminateOutcome` (`.exited(ExitStatus)` or `.wedged(EscalationTrace)`) is the only call site of `process.terminate()`: a `nil` applies `.terminateReturnedNil(during: action)` to `.wedged`, records the trace, and every caller returns at once on `.wedged` without running what would have followed an exit. `reap()`: `terminateOrWedge(during: .reap)`; `.wedged` → stop (Task 5 fills the wedged state); `.exited` → `apply(.dormantTimerFired, to: .dormant)`, `process = nil`, `fleet.release(key)`.
- `send(_ input)`: dormant → `apply(.dormantSent)` path: spawn (pre-check) and queue the input until `.ready`, then `process.send`; foreign → `throw LifecycleError.heldElsewhere` (Task 5's row); ready → send; archived older → spawn then send.
- `handleExit(status)`: clean exit after our own `terminate()` → nothing more; non-zero or signal while not terminating → `crashCount += 1`; if `crashCount <= 3` → sleep `[1, 2, 4][crashCount-1]` seconds on the clock, `spawn(reason: .respawn)`; else `state.systemItem = .crashed(exit:, reopenOffered: true)` and `apply(.exitedNonZero)` to ready-with-item or archived (archived when the channel was never ready in this epoch series).
- `fleet: FleetCapCounter` is a small actor shared by all supervisors whose slots are reservations: `acquire(for: ChannelKey) -> CapDecision {.granted(Reservation), .evict(victim: ChannelKey, Reservation), .refused(live: Int)}` decides in one synchronous actor turn (no `await` inside) from every occupied slot, `live.count + reserved.count + wedged.count + pendingEvictions.count < 6`, and from `eligibility: [ChannelKey: DormantEligibility.Verdict]`, a snapshot the supervisors push with `setEligibility(_ key:, _ verdict:)`; when it names a victim it moves the victim out of `live` into `pendingEvictions[r]` in the same turn; `confirm(Reservation)` turns a reservation into a live slot after a clean handshake; `rollback(Reservation)` drops it on any failure between acquire and confirm and returns a pending victim to `live`; `evictionOutcome(_ r: Reservation, _ outcome: EvictionOutcome {.evicted, .victimWedged, .victimBecameIneligible}) -> CapDecision` is how the evicting supervisor reports what it observed and learns whether it may proceed (Task 5); `release(key)` (a key in `live` leaves it; a key pending eviction completes that eviction; a key nowhere is a no-op), `noteActivity(key, sequence)`, `markWedged(key)`, `clearWedged(key)`. Task 4 implements the counter with reservations; Task 5 the eviction path.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit --filter LifecycleRowTests 2>&1 | grep -E "Executed|error:|failed"`
Expected: 10 row tests pass, each asserting exactly its declared scenarios, plus the scripted-handle test and the five decision tests; 0 failures. Run the whole package: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: ChannelSupervisor core, ownership checks with no excused holder, decision answers and the event fan-out, the first ten lifecycle row tests"
```

---

### Task 5: Handoffs, the terminal hatch, foreign and contended rows, wedged, the cap

**Files:**
- Modify: `FleetKit/Sources/FleetSessions/Lifecycle/ChannelSupervisor.swift`
- Modify: `FleetKit/Sources/FleetSessions/Ownership/OwnershipCheck.swift`
- Modify: `FleetKit/Sources/FleetSessions/Lifecycle/FleetCapCounter.swift` (the eviction path)
- Test: `FleetKit/Tests/FleetSessionsTests/LifecycleRowTests.swift` (the remaining eleven rows)

**Interfaces:**
- Consumes: Task 4's supervisor and check; Task 3's `CLIVerbs`, `ScriptedProcessRunner`, `ScriptedHolderFiles`; Task 2's `PaneRequest`, `PaneExit`, `PanePurpose`.
- Produces: `adopt()`, `sendToBackground()`, `openInTerminal() -> PaneRequest`, `attach(job:)`, `logs(job:)`, `paneExited(_:)`, `reopen()`, Contended handling, the wedged state, the reservation-based eviction path; after this task every scenario is landed but the four `terminateExhausted` ones during `.restart` (Task 6) and `.logout` (Task 8).

- [ ] **Step 1: Write the failing tests**

Add the entries to `coverage` (every scenario but the four `terminateExhausted` ones during `.restart` and `.logout`) and these tests:

- `testTerminateReturningNilMarksTheChannelWedgedAndReopenWaitsForNoHolder` (row `terminateExhausted`, `during: .reap`): `rig.useScriptedHandle(terminateReturns: nil)`; from ready, `reap()` → state `.owned(.dormant)` with `wedged == EscalationTrace(steps: [...], pid:, epoch:)`, `liveCount` still counts it, `DormantEligibility` for the channel reports `.blocked(.wedged)`, and a later `send` does *not* spawn; `reopen()` with a foreign holder present spawns nothing; `reopen()` with none spawns and clears `wedged`. Stated in the test's doc comment: this row runs against a scripted handle because SIGKILL cannot be refused. Deliberate break: treat `nil` as an exit → the channel respawns on `send`.
- `testTerminateReturningNilDuringSendToBackgroundRunsNoVerb` (`during: .sendToBackground`): ready on the scripted handle; `sendToBackground()` throws `LifecycleError.wedged(trace)`; the runner recorded no `--bg --resume`; `FleetKitKeys.ownJobShorts` unchanged; state wedged. Deliberate break: run the verb before checking the outcome → the runner shows `--bg`.
- `testTerminateReturningNilDuringOpenInTerminalReturnsNoPaneRequest` (`during: .openInTerminal`): `openInTerminal()` throws `LifecycleError.wedged(trace)`; no `.paneRequest` diagnostic; `pendingHatch == nil`; state wedged. Deliberate break: build the request before terminating → a request is returned for a process that is still alive.
- `testAVictimThatWedgesMidEvictionFreesNoSlot` (`during: .capEviction`, and row `capReached`): six ready channels, the LRU victim on the scripted handle; a seventh `open()` → the victim is wedged (trace, still counted), the counter received `.victimWedged`, and the seventh either takes the next eligible victim (its `terminate` observed, the seventh spawns) or, with no other eligible channel, is refused with `capReached(live: 6)` and spawned nothing; in both cases no channel spawned against the ghost's slot (`live + reserved + wedged + pendingEvictions` never exceeds 6). Deliberate break: count a wedged victim as evicted → the seventh spawns and the fleet holds seven processes' worth of slots.
- `testCapEvictsTheLeastRecentlyUsedEligibleChannelAndRefusesWhenNoneIsEligible` (row `capReached`): six supervisors ready (six `resume-no-replay` replays), activity sequences set so channel 3 is least recent; a seventh `open()` → channel 3 is reaped (its `terminate` observed), the counter received `.evicted`, and the seventh spawns; then make all six ineligible (each with a running `MirrorEntryStandIn`) and open an eighth → `LifecycleError.capReached(live: 6)`, no `terminate` on any, every state's `liveCount == 6` and `headerNote == .capReached(live: 6)`. Also: a wedged channel among the six is never the eviction pick even when least recent; and an already-dormant LRU channel is the victim without a reap (its slot is released, the `.capReached` dormant→dormant scenario). Deliberate break: pick by recency without the eligibility filter → the ineligible half evicts.
- `testTwoConcurrentOpensAtTheCapTakeDistinctVictimsOrOneIsRefused` (row `capReached`): six ready channels, two of them eligible; two new supervisors call `open()` concurrently (`async let`); afterwards exactly two victims were reaped and both newcomers are ready, or one victim was reaped, one newcomer is ready and the other threw `capReached`; never one victim and two ready newcomers; `fleet.live.count <= 6` at every `capDecision` diagnostic. Deliberate break: decide from `live.count` alone without reservations → both newcomers see five live after the first eviction and both spawn.
- `testAReleaseArrivingWhileTheVictimIsPendingCompletesTheEvictionAndNeverFreesASeventhSlot` (row `capReached`): six ready channels, one eligible victim V; a seventh `open()` picks V; the rig's `holdEviction(of: V)` suspends the evicting supervisor between V's observed exit and its `evictionOutcome` report; while it is held, V's own reap path calls `release(V)` and an eighth `open()` runs → the eighth is refused with `capReached(live: 6)` (V's slot is spoken for by the seventh's reservation), `release(V)` completed the eviction by moving the slot into `reserved[r]` without touching `live`, and when the barrier lifts the seventh's `evictionOutcome(r, .evicted)` is answered `.granted(r)` and it spawns; at no `capDecision` did `live + reserved + wedged + pendingEvictions` exceed 6, and a second `release(V)` is a no-op. Deliberate break: count only `live + reserved + wedged` → the eighth sees five and spawns, seven processes' worth of slots.
- `testAdoptStopsTheJobWaitsForRosterRemovalThenResumes` (row `jobAdopt`): a scripted job for the session with a roster worker; `adopt()` → the runner recorded `["stop", short]`, then the supervisor waited until the worker was gone (the scripted `stop` removes it), then `beforeSpawn` and a spawn with `.resume(id)`; state `.owned(.connecting)` → `.ready`. Deliberate break: spawn before the roster removal → the label order is wrong (`beforeSpawn` before the runner's `stop` completes).
- `testSendToBackgroundTerminatesWaitsForRegistryRemovalThenStartsAJob` (row `ownedSendToBackground`): ready → `sendToBackground()` → own process terminated, `awaitRelease` observed the own registry record gone (the scripted files mirror our child's record: the rig writes a registry record for the fake-claude pid at spawn and removes it on exit, standing in for what the real CLI does), runner recorded `["--bg", "--resume", id]`, the new job's short returned and its `resumeSessionId == id`, state `.backgroundJob`, and the short is stored under `FleetKitKeys.ownJobShorts`; from dormant (no process to terminate, no own holder to await) `sendToBackground()` issues the verb directly: the runner recorded `["--bg", "--resume", id]` and no `terminate` was observed, state `.backgroundJob`; the test's `coverage` entry lists both scenarios, `(.ownedSendToBackground, .ready, .sendToBackground, .backgroundJob)` and `(.ownedSendToBackground, .dormant, .sendToBackground, .backgroundJob)`. Deliberate break: skip the release wait → the verb runs while the record exists (assert order against the recorder's timestamps).
- `testOpenInTerminalReturnsAHatchPaneRequestUnderTheSameConfigHome` (row `ownedOpenInTerminal`): ready → `openInTerminal()` → own process terminated and released; the returned `PaneRequest` has `purpose == .hatch(id)`, `arguments == ["--resume", id.description]`, `executable == binary`, `cwd == channel cwd`, and its `environment["CLAUDE_CONFIG_DIR"] == scratch root path` with no other `CLAUDE*` key except those `LaunchConfiguration.childEnvironment` sets (assert the key set equals that function's output for the same inputs); state `.foreignLive(.ownTerminalTab)`; after a re-adopt, a second `openInTerminal()` returns a request equal to the first in every field but `id`; from dormant (no process, nothing to await) `openInTerminal()` returns the same request shape at once with no `terminate` observed, state `.foreignLive(.ownTerminalTab)`; the test's `coverage` entry lists both scenarios, `(.ownedOpenInTerminal, .ready, .openInTerminal, .foreignOwnTab)` and `(.ownedOpenInTerminal, .dormant, .openInTerminal, .foreignOwnTab)`. Deliberate break: build the environment from `ProcessInfo` → the key set differs.
- `testPaneExitReAdoptsWhenTheRecordIsGone` (row `ownTabExited`): after the hatch request, the rig writes a foreign registry record for the "terminal" (test pid), then `paneExited(PaneExit(request:, code: 0, observedAt:))`; the supervisor waits until the record is removed (the test removes it after the call), then `beforeSpawn` and a spawn; state `.owned(.connecting)`. Deliberate break: spawn on the exit without waiting for the record → the pre-spawn check finds the holder and the test's second expectation (spawn after removal) fails.
- `testAStaleExitFromAnIdenticalOlderHatchIsDiscardedByID` (row `ownTabExited`): hatch once (request R1), re-adopt through a pane exit, hatch again (request R2) with every field equal to R1 but `id`; report `PaneExit(request: R2, …)` first, then `PaneExit(request: R1, …)`, and in a second run the reverse order; in both runs exactly one re-adopt happens, it is driven by R2's exit, and R1's exit is recorded as `.staleExit` whether it arrives before or after; a value-equal request with a fresh `id` never matches. Deliberate break: compare `pendingHatch == exit.request` → R1's exit matches R2's pending hatch and the channel re-adopts twice or on the wrong exit.
- `testForeignRecordDisappearingArchivesTheChannel` (row `foreignRecordGone`): foreign live (foreign record present, no own process); remove the record; advance the poll → `.archived`.
- `testSendOnAForeignSessionIsRefusedWithForkOffered` (row `foreignSendRefused`): `send` throws `LifecycleError.heldElsewhere(set)`; state `banner == .heldElsewhere(set)`; no spawn; `desired` unchanged. Deliberate break: spawn anyway → the factory was called.
- `testHandoffTimeoutEntersContendedFromEveryHandoff` (row `handoffTimedOut`, four scenarios): adopt with a scripted `stop` that never removes the worker, advance the clock 10 s → from `backgroundJob` to `.owned(.contended)`, `banner == .contended(set)` naming the holder's pid; send to background from ready and from dormant with our own registry record scripted to stay → contended; a pane exit whose tab record never disappears → from `foreignOwnTab` to contended. Deliberate break: 10 s constant → the state is not contended at 10 s.
- `testDesiredOwnedWithAForeignHolderIsContendedFromEveryOwnedState` (row `desiredObservedDisagree`, three scenarios): with `desired == .owned`, a foreign holder appearing while connecting (between spawn and handshake, through the reader hook), while ready, and while dormant → `.owned(.contended)` with the banner, each recorded as the `.desiredObservedDisagree` event and not as a handoff timeout. Deliberate break: raise the disagreement only from ready → the connecting and dormant scenarios are missing from the observed set.
- `testContendedResolvesWhenHoldersSettle` (row `contendedSettled`): from contended, remove the foreign record and advance the poll → the matching origin (`.archived` when nothing holds it; `.foreignLive` when one foreign holder remains).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit --filter LifecycleRowTests 2>&1 | tail -5`
Expected: build errors for `adopt`, `sendToBackground`, `openInTerminal`, `paneExited`, `reopen`.

- [ ] **Step 3: Implement**

Decisions:

- `adopt()`: requires a live job holder for the session; `verbs.stop(short)`; `ownership.awaitRelease(previous: jobHolder, upTo: 10 s)` — `.timedOut` → `apply(.handoffTimedOut, to: .contended)` with `banner = .contended`; `.released` → `spawn(reason: .adopt)`.
- `sendToBackground()`: requires owned; `terminateOrWedge(during: .sendToBackground)` (`.wedged` → throw `LifecycleError.wedged(trace)`, nothing else runs); `awaitRelease(previous: ownHolder)` where `ownHolder` is the registry record whose pid is our child's (looked up before terminating); `verbs.backgroundResume(id, cwd)` → `JobShort`; store it in `FleetKitKeys.ownJobShorts`; `verbs.agentsJSON()` and the roster must list it, else `LifecycleError.verbFailed(verb: "--bg --resume", exitCode: 0)` with a diagnostic `.jobNotListedAfterBackground`; `apply(.ownedSendToBackground)`.
- `openInTerminal()`: requires owned; `terminateOrWedge(during: .openInTerminal)` (`.wedged` → throw `LifecycleError.wedged(trace)`, no request); `awaitRelease`; build `PaneRequest(id: UUID(), executable: launch.binary, arguments: ["--resume", key.session.description], cwd: launch.cwd, environment: launchTemplate.childEnvironment(over: environment, configHome: configHome), purpose: .hatch(key.session))`; `pendingHatch = request`; `apply(.ownedOpenInTerminal)`; return it. `attach(job:)`/`logs(job:)`: `PaneRequest(executable: binary, arguments: ["attach"|"logs", short.rawValue], cwd: job.cwd ?? launch.cwd, environment: same, purpose: .attach|.logs)`, no state change.
- `paneExited(_ exit)`: only when `pendingHatch?.id == exit.request.id`; otherwise record `.staleExit` and return (a value-equal request with another `id` is stale); wait for the hatch's registry record to disappear (`awaitRelease` on the foreign holder for the session, `upTo: 10 s`; timeout → contended); then `spawn(reason: .readopt)` → `apply(.ownTabExited)`.
- Contended: `enterContended(holders)` sets `.owned(.contended)`, `banner = .contended(HolderSet)`; the observer's updates drive `resolveContended()`: zero foreign holders → `.archived` (or re-spawn when `desired == .owned` and the user acts; no automatic respawn), one holder → the matching origin; `apply(.contendedSettled)`.
- Disagreement: on every `HolderSet` update, if `desired == .owned`, the channel is owned (connecting, ready or dormant), and a foreign holder names the session → `apply(.desiredObservedDisagree, to: .contended)` then `enterContended`; this is its own event and never reported as a handoff timeout.
- Wedged: `terminateOrWedge(during:)` is the single site; a `nil` from any of reap, send to background, open in terminal, restart (Task 6), logout (Task 8) or cap eviction → `state.wedged = EscalationTrace(steps: diagnosticsSteps, pid:, epoch:)`, `state.origin = .owned(.dormant)`, `state.systemItem = .wedged(trace, reopenOffered: true)`, `process = nil` but `fleet` keeps the count (`fleet.markWedged(key)`); `send` while wedged → `throw LifecycleError.wedged(trace)`; `reopen()` → `beforeSpawn`; holders → nothing (banner `.contended`); none → clear `wedged`, `fleet.clearWedged(key)`, spawn. The observer clears the ghost's count when its pid is dead and its record gone (`fleet.clearWedged` from the update handler).
- Cap: `FleetCapCounter` actor holds `live: Set<ChannelKey>`, `wedged: Set<ChannelKey>`, `reserved: [Reservation: ChannelKey]`, `pendingEvictions: [Reservation: ChannelKey]`, `lru: [ChannelKey: UInt64]`, `eligibility: [ChannelKey: DormantEligibility.Verdict]` (pushed by `setEligibility`, never pulled). `acquire(for key)` is one synchronous actor turn: if `live.count + reserved.count + wedged.count + pendingEvictions.count < 6` → `.granted(r)` with `reserved[r] = key`; else pick the least `lru` among `live` whose `eligibility` is `.eligible` (a wedged key is not in `live`; a pending victim has already left it) → remove the victim from `live`, `pendingEvictions[r] = victim`, answer `.evict(victim, r)` (the victim is spoken for: a concurrent `acquire` counts its slot and cannot pick it); none → `.refused(live: 6)`. The evicting supervisor calls the victim's `evict()`, a `reap()` that first re-evaluates the victim's own eligibility at reap time and answers `.victimBecameIneligible` without terminating when it changed, else terminates and returns the outcome, then awaits the `evictionBarrier` seam (production: nothing; the rig's `holdEviction(of:)` parks it), and reports `evictionOutcome(r, …)`: `.evicted` → the slot moves from `pendingEvictions` into `reserved[r]` and the answer is `.granted(r)`; `.victimWedged` → the victim moves to `wedged`, nothing is freed, and the counter re-runs the pick for the next eligible victim (`.evict(next, r)`) or answers `.refused`; `.victimBecameIneligible` → the victim returns to `live` and the same re-pick runs. `release(key)`: a key in `live` leaves it; a key in `pendingEvictions` completes that eviction (its slot moves into `reserved[r]`, `live` untouched, and the later `evictionOutcome(r, .evicted)` finds it done); a key nowhere is a no-op. `confirm(r)` after a clean handshake moves the reservation into `live`; `rollback(r)` on any failure drops it and returns any pending victim it held to `live`. Every decision is recorded as `.capDecision(decision:live:reserved:)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`
Expected: all row tests green, each asserting exactly its declared scenarios; 0 failures across the package.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: handoffs, the terminal hatch matched by id, foreign and contended rows, wedged from every action, the cap as reservations"
```

---

### Task 6: The quiescent restart and forking

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Lifecycle/RuntimeState.swift` (the `SessionRuntimeState` updater: which answer or frame sets which field; `Readback`)
- Modify: `FleetKit/Sources/FleetSessions/Lifecycle/ChannelSupervisor.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/RestartTests.swift`, `ForkTests.swift`, `LifecycleRowTests+Restart.swift`

**Interfaces:**
- Consumes: Task 5's supervisor; `ClaudeWire`'s `ApplyFlagSettings`, `GetSettings`, `InitializeResponse`, `SessionIdentity`, `WireEvent.sessionIdentityResolved`.
- Produces: `ChannelSupervisor.perform(_ request:) async throws -> Response` (the one door for a control request; every answer passes through the updater), `SessionRuntimeState` ownership on the supervisor with `runtimeState()` read access, `RuntimeStateUpdater.apply(answer:to:)`/`apply(frame:to:)` (including the `flagSettings` union and `fastModeObserved`), `quiescentRestart(_ request: RestartRequest)`, `Readback.verify(...) -> [String]` (the names that did not survive), `fork(at: ForkPoint?) -> ChannelKey` (provisional), `updates` publishing the re-keyed state.

- [ ] **Step 1: Write the failing tests**

`RestartTests.swift` (fixture `control-shapes` for the readbacks and the flag re-application; `FAKE_CLAUDE_INIT` only for the permission-mode mismatch, a value the initialize response does carry):
- `testRestartCarriesRuntimeValuesAndNeverAgent`: a ready channel whose runtime state holds permission mode `plan`, model `opus`, effort `low`, output style `default`, `--add-dir` list `["/tmp/a"]`, launched with `agent: "reviewer"`, the values having arrived through answers (`set_permission_mode`, `set_model`, `get_settings.applied`) and one `perform(ApplyFlagSettings(settings: ["fastMode": true]))`, so `flagSettings == ["fastMode": true]`, not through the launch template; `quiescentRestart(RestartRequest(addDirectories: ["/tmp/a", "/tmp/b"]))` → the factory received a `LaunchConfiguration` with `permissionMode == .plan`, `model == "opus"`, `effort == "low"`, `addDirectories == [/tmp/a, /tmp/b]`, `agent == nil`, `session == .resume(sameID, fork: false)`, and the epoch advanced; after the handshake the process received `apply_flag_settings {settings: {fastMode: true}}` (assert on the scripted `expect` in a `FAKE_CLAUDE_SCRIPT`, which makes the replay fail with exit 3 if the request never arrives) and then `get_settings`. Deliberate break: re-pass `--agent` → `agent != nil`.
- `testRestartWaitsForDormantEligibilityAndQueuesTheChange`: with a running task in the mirror, `quiescentRestart` returns at once with `state.pendingChange == request` and no terminate; when the task ends (mirror empty) and the dormant timer fires, the restart runs. Deliberate break: restart immediately → `terminate` observed while the task runs.
- `testAReadbackMismatchRaisesTheBannerAndKeepsConnecting`: `FAKE_CLAUDE_INIT` answering `current_permission_mode: "default"` against a snapshot of `plan` → `state.origin == .owned(.connecting)`, `banner == .settingDidNotSurvive("permissionMode")`; the user picking a value (`resolveSetting("permissionMode")`) clears it to `.ready`. Deliberate break: compare nothing → ready with no banner.
- `testControlAnswersThenRestartCarryTheChangedValues`: open with model `sonnet` and permission mode `default`; `perform(SetModel(model: "opus"))` and `perform(SetPermissionMode(mode: .plan))` against a `FAKE_CLAUDE_SCRIPT` whose `expect`/`answer` steps answer both with success; `runtimeState()` now reads `opus`/`plan`; `quiescentRestart(RestartRequest(addDirectories: ["/tmp/b"]))` → the factory's launch carries `model == "opus"` and `permissionMode == .plan`, not the values the channel was opened with. The same change through the router and the executor is Task 8's `testRouteChangeThenRestartCarriesTheChangedValuesEndToEnd`, once those exist. Deliberate break: snapshot the launch template → `sonnet`/`default`.
- `testRuntimeStateIsUpdatedByEachAnswerAndFrame`: table-driven over `RuntimeStateUpdater`: a `set_model` answer sets `model`; a `set_permission_mode` answer sets `permissionMode`; `get_settings.applied` sets `model`, `effort` and `outputStyle` when present (the control-shapes answer carries `model`, `effort`, `advisor`, `ultracode` and no fast-mode key); an `apply_flag_settings` request whose answer is the bare success merges its `settings` into `flagSettings` (two applies with different keys → both keys; a second apply of one key → the later value); `fast_mode_state` on the initialize response and on a `result` frame sets `fastModeObserved` (no other frame carries it); a `set_cwd` answer sets `cwd`; an accepted `add_directory` appends to `addDirectories`; the first `system/init` seeds `model`, `permissionMode`, `outputStyle`, `cwd` and `agent`; an unrelated answer changes nothing. Deliberate break: ignore `fast_mode_state` on `result` → the toggle made mid-turn is lost.
- `testReadbackReadsEachValueFromItsOwnSource`: a table-driven test over `Readback.verify(snapshot:, handshake:, settingsApplied:, effectiveKeys:)` with one mismatch at a time, asserting the returned name list equals exactly the mismatched name (`["model"]`, `["effort"]`, `["permissionMode"]`, `["outputStyle"]`, `["flagSettings.effortLevel"]` for a flag key missing from `effective_keys`, `["fastMode"]` for an observed-only fast mode the new handshake's `fast_mode_state` contradicts). Deliberate break: read model from the handshake instead of `get_settings.applied` → the `model` case passes with the wrong source, caught because the test's handshake carries a *different* model than `applied`.
- `testRestartRelaunchesTheCWDChangedBySetCwd`: open in `<proj>/a`; `perform(SetCwd(path: "<proj>/b"))` answered success by a `FAKE_CLAUDE_SCRIPT`; `quiescentRestart(RestartRequest())` → the factory's launch has `cwd == <proj>/b` while the template's `cwd` still reads `a`. Deliberate break: relaunch from the template's `cwd` → `a`.
- `testAnAddDirectoryMadeMidSessionSurvivesRestart`: template `addDirectories == ["/tmp/a"]`; an `add_directory` request for `/tmp/mid` answered success (scripted; the corpus records no such frame, stated in the doc comment) appends to the runtime state; `quiescentRestart(RestartRequest())` → the launch carries `["/tmp/a", "/tmp/mid"]`; `RestartRequest(addDirectories: ["/tmp/a", "/tmp/b"])` replaces the list instead. Deliberate break: build `addDirectories` from the template and the request only → `/tmp/mid` is dropped.
- `testEveryFlagSettingKeyIsReappliedAndPresentInEffectiveKeys` (fixture `control-shapes`): `perform(ApplyFlagSettings(settings: ["effortLevel": "low"]))` then `perform(ApplyFlagSettings(settings: ["fastMode": true]))` → `flagSettings` holds both keys; restart → after the new handshake exactly one `apply_flag_settings` carrying both keys (a scripted `expect`), then `get_settings`; the recorded answer's `effective_keys` lists `effortLevel`, so the script answers `get_settings` with `effective_keys` containing both keys (stated) and `Readback.verify` returns `[]`; an answer whose `effective_keys` lacks `fastMode` returns `["flagSettings.fastMode"]` and the banner names it. Deliberate break: re-apply only the last payload → `effortLevel` is missing from the request and the `expect` fails with exit 3.
- `testFastModeIsVerifiedFromEffectiveKeysWhenHostAppliedAndFromTheHandshakeWhenObserved`: (a) host-applied, `flagSettings == ["fastMode": true]` → verified solely by `effective_keys` containing `fastMode`, whatever the new handshake's `fast_mode_state` says; (b) observed only, `flagSettings` empty and `fastModeObserved == true` from a `result` frame → verified by the new handshake's `fast_mode_state == "on"`, and `"off"` yields `["fastMode"]`; (c) neither → nothing about fast mode is checked. Deliberate break: compare the handshake in case (a) → a host toggle the engine reports lazily fails a correct restart.
- `testReadyIsNotPublishedBeforeTheReadbacks`: collect `updates` during a restart against a `FAKE_CLAUDE_SCRIPT` that delays the `get_settings` answer; no `.owned(.ready)` state is published between the new handshake and that answer, the first `.ready` follows it, and with a mismatching answer `.ready` is never published. Deliberate break: let `spawn(reason: .restart)` apply `.handshakeClean` → `.ready` is published before `get_settings` is answered.

`ForkTests.swift`:
- `testForkIsKeyedProvisionallyUntilTheIdentityEventThenReKeyed`: `fork(at: nil)` on a ready channel → a new supervisor with `key.session` provisional (`state.identity == .awaitingFork(from:, provisional:)`), launch `.resume(source, fork: true)`; the scripted handle (a real fake-claude replay of `plain-two-turn` emits `auth_status` with the fixture's id, which for this test *is* the "new" id) → `.sessionIdentityResolved` → `state.key.session == fixture id`, `updates` published the re-keyed state once, captures untouched. Deliberate break: key the fork on the source id → the re-key never happens and the key equals the source.
- `testForkFromAMessageLaunchesForkFromWithTheClickedRecordAndTheDroppedTurn`: `fork(at: ForkPoint(entryUUID: "u-42", dropsTurn: "p-41"))` → the factory received `session == .forkFrom(source, at: ForkPoint(entryUUID: "u-42", dropsTurn: "p-41"))` and `identity == .awaitingFork(from: source, provisional:)`; C2's composer tests already pin the argv (`--resume <id> --fork-session --resume-session-at u-42 --resume-drops-turn p-41` through the token guard), so this test asserts the `SessionStart` value and adds no argument of its own; `fork(at: ForkPoint(entryUUID: "u-42"))` carries `dropsTurn == nil`. Deliberate break: launch `.resume(source, fork: true)` for a fork point → the session value differs.
- `testAForkWhoseIdentityCollidesWithAnOwnedSessionYields`: two supervisors A (ready on session S, a real replay) and F (a fork of another session, on the scripted handle with a canned handshake); the test pushes `.sessionIdentityResolved(S, F.epoch)` through F's event stream (a fork's identity resolves from the first `auth_status` frame and never from the initialize response, `main` `ClaudeProcess.swift:271-287`, so `FAKE_CLAUDE_INIT`, which patches only the init response, cannot script it); on that event F's post-handshake check sees A's pid, which is not F's own → F terminates its process (the scripted `terminate` observed), F is `.owned(.contended)` with the banner, the facade does not re-index F over A, and A's process and state are untouched. Deliberate break: skip the post-handshake check on re-key → two supervisors own S.

`LifecycleRowTests+Restart.swift` (an extension of `LifecycleRowTests`, entries added to `coverage`):
- `testTerminateReturningNilDuringRestartSpawnsNothing` (`during: .restart`, from ready and from connecting): the scripted handle refuses to die; `quiescentRestart(...)` → the channel is wedged with the trace, the factory was not called again, `state.pendingChange == nil` (the change is not silently queued behind a ghost), and `banner` is not `.settingDidNotSurvive`. Deliberate break: spawn after a `nil` → two processes for one session id.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit --filter "RestartTests|ForkTests" 2>&1 | tail -5`
Expected: build errors for `quiescentRestart`, `SessionRuntimeState`, `RuntimeStateUpdater`, `fork(at: ForkPoint?)`.

- [ ] **Step 3: Implement**

Decisions:
- The supervisor owns `runtime: SessionRuntimeState`, seeded from the launch template and the handshake. `perform(_ request: some ControlRequestSpec)` is the one door for a control request (Task 8's executor and the app both use it); every answer it returns first passes through `RuntimeStateUpdater.apply(answer:for request:to:)`, and every frame through `apply(frame:to:)`: `set_model` → `model`; `set_permission_mode` → `permissionMode`; `get_settings.applied` → `model`, `effort`, `outputStyle` when present; an `apply_flag_settings` sent through `perform` → its `settings` merged into `flagSettings` (the union of every payload, later values winning; the engine answers a bare success, so the payload is the record); `fast_mode_state` (initialize response, `result`; no other frame carries it) → `fastModeObserved`; `set_cwd` → `cwd`; an accepted `add_directory` → appended to `addDirectories`; the first `system/init` → `model`, `permissionMode`, `outputStyle`, `cwd`, `agent`; `RestartRequest` application → `addDirectories`, `environment`. The restart snapshot is a copy of `runtime` taken when the restart is decided; there is no second source of truth and no snapshot from the template.
- `quiescentRestart`: `DormantEligibility` blocked → `state.pendingChange = request`, return; eligible → `let snapshot = runtime`; `terminateOrWedge(during: .restart)` (`.wedged` → clear `pendingChange`, stop); `awaitRelease(own)`; the new launch takes every launch field from the snapshot: `cwd` (as changed by `set_cwd`), `addDirectories` (the template's plus every accepted `add_directory`, or the request's list when it carries one), `environment`, `model`, `permissionMode`, `effort`, with `agent = nil`; the template supplies only the invariants (binary, `settingSources`, `strictMCPConfig`, `worktree`, `allowBypass`, `promptSuggestions`), each overridden by the request when it names one (outer `nil` keeps, inner `nil` clears); `spawn(reason: .restart)`, which confirms the reservation and runs the post-handshake check but stops at the handshake without applying `.handshakeClean` or publishing; then `perform(ApplyFlagSettings(settings: snapshot.flagSettings))` when non-empty, then `perform(GetSettings())`; `Readback.verify`; empty → `apply(.handshakeClean, to: .ready)`, `armDormantTimer()`, publish; else `banner = .settingDidNotSurvive(firstName)` and the channel stays `.connecting`, never having published `.ready`, until `resolveSetting(name)`.
- `Readback.verify(snapshot:, handshake: InitializeResponse, settingsApplied: JSONValue, effectiveKeys: [String]) -> [String]`: `model` and `effort` from `settingsApplied["model"]`/`["effort"]`; `permissionMode` from `handshake.currentPermissionMode`; `outputStyle` from `handshake.outputStyle`; every key of `snapshot.flagSettings` must appear in `effectiveKeys`, a missing one reported as `flagSettings.<key>`; fast mode: when `flagSettings` carries `fastMode` that rule covers it and the handshake is not consulted; when it was only observed (`fastModeObserved != nil` and no `fastMode` key) `handshake.fastModeState == "on"` must equal it, reported as `fastMode`; names in that fixed order.
- Fork: `fork(at point: ForkPoint?) -> ChannelKey` creates a new `ChannelSupervisor` through a factory closure the facade injects (`spawnSibling`), with `session: point.map { .forkFrom(source, at: $0) } ?? .resume(source, fork: true)`; `ClaudeProcess` sets `identity = .awaitingFork(from: source, provisional:)` for both; on `.sessionIdentityResolved(id, epoch)` matching the current epoch: run `ownership.afterHandshake(session: id, ownPID:, epoch:)` against the *resolved* id (a collision with a session another supervisor owns yields exactly as a post-handshake holder does), then `key = ChannelKey(configHome:, session: id)`, `identity = .known(id)`, publish; the facade re-indexes the supervisor under the new key only when the check was clean.
- `--resume-session-at` and `--resume-drops-turn` are C2's: `SessionStart.forkFrom(_:at:)` (main `13c9ad4`) emits them through the line composer and the argv token guard (`b2ddd5d`). FleetKit appends no argument, defines no `ForkPoint` of its own, and skips no test; the v1 contingency is withdrawn.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed|skipped"`
Expected: 0 failures, no skips.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: the runtime-state model, the quiescent restart from it, forking through forkFrom with a provisional key"
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
- Produces: `TrustReader.isTrusted(root:configHome:)`, `ProjectRoot.canonical(for:)`, `ProjectMCPConsent.evaluate(...) -> [ServerVerdict]` (merged settings only), `LocalSettingsStore.decline(names:gitRoot:cwd:configHome:)` (descriptor-relative), `ManagedSettingsReader.isPending(configHome:)`, `SpawnPreconditions.evaluate(...) -> SpawnPrecondition`. The engine-side proof that a decline is honoured is Task 10's zero-cost scenario, not a test here.

- [ ] **Step 1: Write the failing tests**

`PreconditionTests.swift`, each under a temporary project directory the test creates (a git repository made by writing a `.git` directory with a `HEAD` file, no `git` binary needed):

- `testCanonicalRootIsTheRealPathWalkedUpToGit`: cwd `<proj>/a/b` → root `<proj>` realpath; a cwd with no `.git` above → itself; a `/tmp/...` path resolves to `/private/tmp/...` (compare against `URL.resolvingSymlinksInPath()`). Deliberate break: skip realpath → the `/tmp` case differs.
- `testUntrustedRootYieldsHistoryOnly`: no project entry → `.untrusted(root:)`; entry with `false` → `.untrusted`; `true` → passes to the next check. Deliberate break: treat a missing entry as trusted → spawn allowed.
- `testConsentIsComputedFromTheMergedSettingsOnlyReadOnly`: `.mcp.json` declares `a`, `b`, `c`, `d`, `e`; the local-settings store has `disabledMcpjsonServers: ["a"]`; `<root>/.claude/settings.json` has `enabledMcpjsonServers: ["b"]`; `<configHome>/settings.json` has `enabledMcpjsonServers: ["c"]`; the `.claude.json` project entry has `disabledMcpjsonServers: ["d"]`, `enabledMcpjsonServers: ["e"]` → verdicts `a: rejected(.localSettings)`, `b: approved(.projectSettings)`, `c: approved(.userSettings)`, `d: pending`, `e: pending` (the project entry is a legacy location the engine migrates and never reads for consent; spec *Preconditions* cites the bundle); with `enableAllProjectMcpServers: true` in the project settings, `d` and `e` are `approved(.projectSettings)`; with the launch's setting sources excluding `.user`, `c` is `pending`; a server both disabled locally and enabled in the project settings is `rejected`. After the evaluation the project tree and the scratch `.claude.json` are byte-identical to before (hash them). Deliberate break: read the project entry → `d` is rejected and `e` approved.
- `testAcceptRecordsTheHashAndDoesNotRepeatUntilTheEntryChanges`: accept `d` → the store holds `(root, "d", hash)`; re-evaluate → `d: approved(byAcceptance)`; change `d`'s command in `.mcp.json` → `d: pending` again. Deliberate break: key by name alone → the changed entry is still approved.
- `testDeclineWritesThroughTheCLIsOwnPolicy`: existing `.claude/settings.local.json` with keys `{"zeta": 1, "alpha": {"x": [1,2]}, "disabledMcpjsonServers": ["old"]}`; `decline(["d"])` → the file's `disabledMcpjsonServers == ["old", "d"]`, the shape C1's spike recorded the terminal's own dialog writing; every other top-level key's raw JSON text is byte-identical to before (compare substrings of the raw file); no file under `.claude/.cc-writes` remains; the directory listing of `.claude` equals `["settings.local.json"]` plus whatever existed before; a missing file is created with mode 0o644 and the single key. The proof that the engine honours the write is Task 10's two-launch scenario against the installed CLI; `fake-claude` runs no server, so no marker is asserted here. Deliberate break: rewrite the whole JSON through `JSONSerialization` → key order or number formatting changes and the byte comparison fails.
- `testDeclinePreservesTheModeAcrossTheRename`: existing files at 0o640 and at 0o600 → after `decline` the mode is unchanged in each case (`fstat` on the new inode), and the staging file was created 0o600 before `fchmod` (asserted through the injected `LocalSettingsStore.Hooks.afterStagingCreated`). Deliberate break: omit `fchmod` → the 0o640 file comes back 0o600.
- `testDeclineRefusesASymlinkedDotClaude`: `.claude` is a symlink to a directory outside the project → `LifecycleError.declineRefused(reason: "symlink")`; the target directory's listing and bytes unchanged; no spawn (`SpawnPreconditions` returns `.consentNeeded` still) and `banner == .mcpDeclineRefused("symlink")`. Deliberate break: open `.claude` without `O_NOFOLLOW` → the write lands in the target.
- `testDeclineRefusesASymlinkedStagingDirectory`: `.claude/.cc-writes` is a symlink to a directory outside the project → refused `symlink`; nothing created under the target; the target's listing unchanged. Deliberate break: `mkdir` the staging directory by path and open the staging file by path → the staging file appears in the target.
- `testDeclineRefusesASymlinkedTargetFile`: `.claude/settings.local.json` is a symlink to a file outside the project → refused `symlink`; the linked file's bytes and mode unchanged; no staging file remains. Deliberate break: read the existing file through `open(path)` → the read follows the link and the rename replaces the link with a regular file (the target survives, but the test's "refused" expectation fails first).
- `testDeclineRefusesAComponentSwappedAfterResolution`: `LocalSettingsStore.Hooks.afterResolve` replaces `<root>/.claude` with a symlink to a directory outside the project after `resolve` returned and before the first `openat`; the open with `O_DIRECTORY|O_NOFOLLOW` fails with `ELOOP` → refused `symlink`, nothing written anywhere. A second variant swaps `.cc-writes` between the `mkdirat` and the staging `openat`. Deliberate break: re-derive paths from the resolution and open by name → the write follows the swapped link.
- `testDeclineRefusesAnAncestorSwappedAfterResolve`: `Hooks.afterResolve` replaces an ancestor of the project root (`<tmp>/work` above `<tmp>/work/proj`) with a symlink into the scratch config home; step 2's `open(resolved, O_DIRECTORY|O_NOFOLLOW)` then yields a descriptor whose `F_GETPATH` differs from `resolved` and lies under the config home → refused `symlink` before any `mkdirat` or `openat`; the config home tree is byte-identical to before (hash it) and nothing exists under the swapped path. Deliberate break: run the containment check on the pre-open string and skip the `F_GETPATH` comparison → the writer proceeds on the config home's directory descriptor and the staging file lands there.
- `testDeclineWritesToTheOriginalDirectoryWhenAnAncestorIsSwappedAfterOpen`: the same swap in `Hooks.afterOpen`, once `rootFD` is open and verified → the write completes and `settings.local.json` lands in the original directory (reached through the still-open descriptor); nothing under the config home changes. Deliberate break: re-open the root by name in step 4 → the staging directory is created under the swapped target.
- `testDeclineRefusesAStagingDirectoryInsideTheConfigHome`: `.claude` is a real directory but `.claude/.cc-writes` is a symlink into the scratch config home → the `O_NOFOLLOW` open refuses `symlink` and nothing under the config home changes (witnessed by hashing it); and a project whose `.claude` resolves through a symlink into the config home is refused `insideConfigHome` from the opened root's `F_GETPATH`, before any `mkdirat` or `openat`. Deliberate break: check `insideConfigHome` on the store file only → the staging write lands in the config home.
- `testDeclineRefusesAStoreInsideTheConfigHome`: a project whose canonical root lies under the scratch config home → refused with reason `insideConfigHome`, nothing written.
- `testDeclineRefusesAForeignUIDAndUnparseableJSON`: the uid check is exercised by injecting an `ownerUID` function that reports a different uid for `<root>/.git`, then for the `.claude` descriptor's `fstat`, then for `.cc-writes` → refused `foreignUID` in each case; a `settings.local.json` containing `{` → refused `unparseable`, file untouched.
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
    /// Test seams. `ownerUID` is consulted for every ownership check (paths before the first open, descriptors after);
    /// `Hooks` lets a test act between steps (swap a component, inspect the staging file); production hooks do nothing.
    public var ownerUID: @Sendable (OwnershipSubject) -> uid_t?          // .path(URL) or .descriptor(Int32)
    public struct Hooks: Sendable { public var afterResolve: @Sendable (Resolution) -> Void; public var afterOpen: @Sendable (Int32) -> Void; public var afterStagingCreated: @Sendable (Int32) -> Void; public var afterStagingDirectory: @Sendable () -> Void }
    public init(ownerUID: @escaping @Sendable (OwnershipSubject) -> uid_t? = LocalSettingsStore.statOwner, hooks: Hooks = .none)

    /// `<root>/.claude/settings.local.json` when stat(root), lstat(root/.git) and lstat(root/.claude) are all owned by
    /// the effective uid and root is not the real home directory; otherwise `<cwd>/.claude/settings.local.json`,
    /// with the cwd file read as the legacy overlay when the store moved to the git root.
    public func resolve(gitRoot: URL?, cwd: URL) -> Resolution

    public enum Refusal: String, Error, Sendable { case unparseable, symlink, foreignUID, insideConfigHome, processLive, writeFailed, notADirectory }

    /// Steps, in order. The root is the one path opened by name, and its descriptor is verified with `F_GETPATH` before
    /// anything is checked or created; after it every open, create and rename is relative to a directory descriptor, so a
    /// component swapped for a symlink after resolution is refused (`ELOOP`/`ENOTDIR` → `symlink`), not followed. Any
    /// failure throws `Refusal` before or without touching the target.
    /// 1. `resolve`; `realpath(3)` the project root → `resolved` (the store and staging directories are `resolved/.claude`
    ///    and `resolved/.claude/.cc-writes` by construction). `hooks.afterResolve`.
    /// 2. `rootFD = open(resolved, O_DIRECTORY|O_NOFOLLOW)`; `fcntl(rootFD, F_GETPATH)` must equal `resolved` byte for byte
    ///    (else refuse `symlink`: an ancestor was swapped between the two calls); the `insideConfigHome` check runs on that
    ///    `F_GETPATH` result, never on a string computed before the open, refusing when it equals or lies under `configHome`;
    ///    `fstat(rootFD)` → directory, owned by the effective uid (else `foreignUID`). `hooks.afterOpen(rootFD)`.
    ///    `mkdirat(rootFD, ".claude", 0o755)` if absent (EEXIST is fine); `dirFD = openat(rootFD, ".claude", O_DIRECTORY|O_NOFOLLOW)`
    ///    (ELOOP/ENOTDIR → `symlink`; a non-directory → `notADirectory`); `fstat(dirFD)` → directory, same uid.
    /// 3. When the file exists: `fileFD = openat(dirFD, "settings.local.json", O_RDONLY|O_NOFOLLOW)` (ELOOP → `symlink`);
    ///    `fstat(fileFD)` → regular file, its mode is the mode to preserve (0o644 for a new file); read the raw text
    ///    through the descriptor. Parse with `JSONSerialization` only to find the `disabledMcpjsonServers` array's byte
    ///    range (a lightweight scanner over the raw text finds the top-level key and its bracketed value); refuse
    ///    `unparseable` on any parse error. Merge `names` into the array (stable order, no duplicates) and splice the new
    ///    array's JSON into the raw text at that range; when the key is absent, insert `"disabledMcpjsonServers": [...]`
    ///    before the final `}` with a leading comma when needed. Every other byte of the file is untouched.
    /// 4. `mkdirat(dirFD, ".cc-writes", 0o700)` if absent; `hooks.afterStagingDirectory`;
    ///    `stagingFD = openat(dirFD, ".cc-writes", O_DIRECTORY|O_NOFOLLOW)` (ELOOP → `symlink`); `fstat` → directory, same uid.
    /// 5. `tmpFD = openat(stagingFD, "settings.local.json.<uuid>", O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0o600)`;
    ///    `hooks.afterStagingCreated(tmpFD)`; write the new text whole; `fchmod(tmpFD, preservedMode)`; `fsync(tmpFD)`; close.
    /// 6. `renameat(stagingFD, "settings.local.json.<uuid>", dirFD, "settings.local.json")`; `fsync(dirFD)`; `unlinkat(dirFD,
    ///    ".cc-writes", AT_REMOVEDIR)` if empty (ignore ENOTEMPTY). Any error in 5–6 → `unlinkat(stagingFD, tmp, 0)`, refuse `writeFailed`.
    ///    Every descriptor is closed on every path out.
    public func decline(names: [String], gitRoot: URL?, cwd: URL, configHome: URL) throws -> Resolution
    public static func statOwner(_ subject: OwnershipSubject) -> uid_t?
}
```

`Preconditions/ProjectMCPConsent.swift`: `ServerVerdict = .rejected(ServerSource) | .approved(ServerSource) | .pending` with `ServerSource = .localSettings | .projectSettings | .userSettings | .acceptance`; `evaluate(root:cwd:configHome:settingSources:acceptances:) -> [ProjectMCPServer: ServerVerdict]` reading `.mcp.json` (`mcpServers` object; each entry's `entryHash` = SHA-256 over the canonical JSON of the entry) and the merged settings sources the engine's consent function reads (spec *Preconditions*: `disabledMcpjsonServers` → rejected; `enabledMcpjsonServers` or `enableAllProjectMcpServers` → approved; else pending), which are the resolved local store and its legacy overlay, `<root>/.claude/settings.json` and `<configHome>/settings.json`, each only when the launch's setting sources include it, all read-only. `.claude.json`'s `projects[<root>]` arrays are never read: the engine migrates them into local settings at startup and its consent decision does not consult them. Precedence: rejected wins over approved wins over pending.

`Preconditions/TrustReader.swift`: `ProjectRoot.canonical(for cwd: URL) -> (root: URL, gitRoot: URL?)` (realpath, walk up for `.git`); `TrustReader.isTrusted(root:configHome:) -> Bool` from `.claude.json` `projects[root.path].hasTrustDialogAccepted == true`.

`Preconditions/ManagedSettingsReader.swift`: `isPending(configHome:) -> Bool`: `remote-settings.json` absent → false; present and `remote-settings-consent.json` parses to an object whose `approvedHash` (or, failing that key, any string field) equals the SHA-256 of the payload file's bytes → false; anything else → true. The consent key name is a delegated unknown; the reader's doc comment says so and names the spec section.

`Preconditions/SpawnPreconditions.swift`: `evaluate(key:, cwd:, launch:, wedged:, foreignHolders:, store:) async -> (SpawnPrecondition, LaunchConfiguration)` in the spec's order; it returns the launch with `strictMCPConfig` set when the sources exclude `.local` and `.mcp.json` declares servers. `ChannelSupervisor.spawn` calls it before `beforeSpawn` and turns a non-`.ready` verdict into `LifecycleError.precondition(_)` plus the matching banner.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: spawn preconditions; consent from the merged settings only; the one §6.12 write on directory descriptors"
```

---

### Task 8: The command router, the flag matrix, refusal interception and `/logout` (G4)

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Router/RouterTable.swift`
- Create: `FleetKit/Sources/FleetSessions/Router/CommandRouter.swift`
- Create: `FleetKit/Sources/FleetSessions/Router/LogoutPlan.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/RouterTests.swift`, `LogoutPlanTests.swift`, `LifecycleRowTests+Logout.swift`

**Interfaces:**
- Consumes: Tasks 4–7; `ClaudeWire` request specs (`ApplyFlagSettings`, `SetCwd`, `SetModel`, `SetPermissionMode`, `RenameSession`, `RewindFiles`, `RewindConversation`, `ClaudeAuthenticate`, `ClaudeOAuthWaitForCompletion`, `GetSettings`, `MCPStatus`, `GetContextUsage`, `Interrupt`); `Handshake`; fixtures `control-shapes` and `zero-cost`.
- Produces: `RouterTable.local` with a `RouteStrategy` per entry, `LaunchSettingMatrix`, `CommandRouter.route(_:handshake:) -> Routed`, `StrategyExecutor.run(_:on:)` for the multi-step strategies, `RefusalInterceptor.intercept(_:) -> Intercepted?`, `LogoutPlan.build(...)`, `LogoutPlan.execute(...)`; the last `terminateExhausted` scenarios (during `.logout`) land here.

- [ ] **Step 1: Write the failing tests**

`RouterTests.swift`:
- `testTheLocalTableEqualsTheParentsRowsAsASet`: `Set(RouterTable.local.map(\.name)) == ["/model", "/permissions", "/effort", "/rename", "/add-dir", "/agent", "/cd", "/fast", "/config", "/login", "/logout", "/color", "/clear", "/rewind", "/fork", "/background", "/stop", "/tasks", "/mcp", "/memory", "/btw", "/agents", "/resume", "/compact", "/context", "/cost", "/usage"]` and `RouterTable.local.count == 27` (no duplicates). Deliberate break: duplicate `/model` → the count differs while the set matches, which is why both are asserted.
- `testRewindDryRunsSurfacesTheCountsThenAppliesAndRewindsTheConversation` (fixture `control-shapes` for the dry run and `rewind_conversation`; a `FAKE_CLAUDE_SCRIPT` `answer` step for the apply, which the corpus does not record, stated in the doc comment): route `/rewind <recorded uuid>` → `.strategy(.rewind(target))`; executing it sends `rewind_files {user_message_id, dry_run: true}` first and surfaces `RewindPreview(canRewind: true, filesChanged: [], insertions: 0, deletions: 0)` from the recorded answer for confirmation; nothing else is sent until `confirm()`; then `rewind_files {dry_run: false}` (scripted success) and `rewind_conversation {target_message_uuid}`, whose recorded answer yields `rewound == true` and `prefillText == "Reply with exactly the word: shapes"` for the composer. Deliberate break: send `rewind_conversation` before the dry run → the script's `expect` order fails the replay with exit 3.
- `testLoginReturnsTheTwoURLsThenWaitsForCompletion` (fixture `control-shapes` for `claude_authenticate` and the recorded `claude_oauth_wait_for_completion` error; a scripted answer for the completed account, stated): route `/login` → `.strategy(.login)`; executing it sends `claude_authenticate` and surfaces `LoginPrompt(manualURL:, automaticURL:)` from the recorded (redacted) answer, handing the automatic URL to the Browser tab through the injected opener; then `claude_oauth_wait_for_completion`; the recorded error "No active claude_authenticate flow" is surfaced as `LoginOutcome.noActiveFlow` (retry offered), and the scripted success answer yields `LoginOutcome.signedIn(account:)`. Deliberate break: open the manual URL → the opener received the wrong one.
- `testBarePermissionsOpensTheRulesViewFromGetSettings` (fixture `zero-cost`): route `/permissions` with no argument → `.strategy(.permissionsView)`; executing it sends `get_settings` and nothing else (no `set_permission_mode`), and produces `PermissionsView(rules:)` from the recorded answer's permission keys; `/permissions plan` routes to `set_permission_mode` instead. Deliberate break: send `set_permission_mode` for the bare form → the script's `expect` fails.
- `testMCPBuildsThePopoverFromMCPStatus` (fixture `zero-cost`): `/mcp` → `.strategy(.mcpPopover)`; executing it sends `mcp_status` and produces `MCPPopover(servers:)` with one row per recorded server carrying its name and status word. Deliberate break: read `get_settings` instead → no servers.
- `testMemoryOpensTheMemoryFilesFromGetContextUsage` (fixture `zero-cost`): `/memory` → `.strategy(.memoryFiles)`; executing it sends `get_context_usage` and returns the recorded `memoryFiles` paths for the Files tab, in the recorded order. Deliberate break: read `mcp_status` → empty.
- `testRouteChangeThenRestartCarriesTheChangedValuesEndToEnd`: Task 6's control-answer test through the front door: `CommandRouter.route("/model opus")` and `route("/permissions plan")` → `StrategyExecutor` → `supervisor.perform`; `runtimeState()` reads `opus`/`plan`; `quiescentRestart(...)` launches with them. Deliberate break: have the executor send through the process rather than `perform` → the runtime state is stale and the restart carries `sonnet`.
- `testEffortSendsApplyFlagSettingsAndReadsBackEffectiveKeys` (fixture `control-shapes`): route `/effort low` → `.controlRequest` whose spec encodes to `{"subtype":"apply_flag_settings","settings":{"effortLevel":"low"}}`; executing it against the replay yields the recorded success with no `response` key and then `get_settings` whose `effective_keys` contains `effortLevel`. Deliberate break: send `{effort: "low"}` → the replay refuses with exit 3 (unexpected host frame).
- `testCDIntoAnUntrustedDirectoryRepeatsWithTrustAcceptedAndTrustedDirectory` (fixture `session-mirror-relocation`, which records the accepted continuation; `control-shapes` records only a bare `set_cwd {path}` retry after `needs_trust`): route `/cd <the recorded sibling>` → first `set_cwd {path}` answered `needs_trust {directory}`; the router's follow-up after the user's trust answer is `continueCD(afterNeedsTrust:path:)`, which builds the second `set_cwd`; the discriminating assertion compares the second request's full payload, keys and values, with the fixture's recorded second `set_cwd` frame, `{path: <the original path>, trust_accepted: true, trusted_directory: <the directory from the answer>}`. fake-claude's recorded-input matcher (`_input_pred`, `fake_claude.py:470-480`) matches a control request by subtype only, so the replay accepts any second `set_cwd`; the payload comparison is the test. Deliberate break: omit `trusted_directory` → payload mismatch.
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

/// What a local command does, as a value the executor interprets. Single-request strategies name their spec; multi-step
/// strategies name the sequence, so a test checks each against the fixture that recorded it rather than checking that an
/// enum case is an enum case.
public enum RouteStrategy: Hashable, Sendable {
    case applyFlagSetting(key: String)            // apply_flag_settings {settings: {key: value}} then get_settings.effective_keys
    case setModel                                  // set_model {model}
    case setPermissionMode                         // set_permission_mode {mode}; the bare form is `.permissionsView`
    case renameSession                             // rename_session {title}
    case setCwd                                    // set_cwd {path}; needs_trust → repeat with trust_accepted + trusted_directory
    case interrupt                                 // interrupt
    case sideQuestion                              // side_question {prompt}
    case rewind                                    // rewind_files dry_run → confirm → rewind_files apply → rewind_conversation
    case login                                     // claude_authenticate → open automaticUrl → claude_oauth_wait_for_completion
    case permissionsView                           // get_settings → read-only rules view
    case mcpPopover                                // mcp_status → popover
    case memoryFiles                               // get_context_usage.memoryFiles → Files tab
    case lifecycle(LifecycleActionName)            // fork, sendToBackground, stopEverything, backgroundAll, logout
    case restart                                   // a RestartRequest built from the arguments
    case text                                      // pass through; frames render the result
    case native(String)                            // UI-only: picker, focus, tasks list, agents list
}
public enum LifecycleActionName: String, Hashable, Sendable { case fork, sendToBackground, stopEverything, backgroundAll, logout }
public enum ReadbackSource: String, Hashable, Sendable { case getSettingsApplied, getSettingsEffectiveKeys, handshakePermissionMode, fastModeState, none }
public struct LocalCommand: Hashable, Sendable {
    public let name: String; public let strategy: RouteStrategy; public let readback: ReadbackSource; public let explanation: String
}
public enum RouterTable {
    public static let local: [LocalCommand] = [
        .init(name: "/model", strategy: .setModel, readback: .getSettingsApplied, explanation: "Changes the model for this channel without a Claude turn."),
        .init(name: "/permissions", strategy: .setPermissionMode, readback: .handshakePermissionMode, explanation: "Changes the permission mode; on its own opens the read-only rules view."),
        .init(name: "/effort", strategy: .applyFlagSetting(key: "effortLevel"), readback: .getSettingsEffectiveKeys, explanation: "Changes the effort level; max cannot be set mid-session."),
        .init(name: "/rename", strategy: .renameSession, readback: .none, explanation: "Renames the channel and the transcript's title."),
        .init(name: "/add-dir", strategy: .restart, readback: .none, explanation: "Adds a directory by restarting this channel under the same session id."),
        .init(name: "/agent", strategy: .applyFlagSetting(key: "agent"), readback: .getSettingsEffectiveKeys, explanation: "Switches the agent from the next turn."),
        .init(name: "/cd", strategy: .setCwd, readback: .none, explanation: "Changes the working directory; an untrusted directory asks for trust first."),
        .init(name: "/fast", strategy: .applyFlagSetting(key: "fastMode"), readback: .fastModeState, explanation: "Turns fast mode on or off."),
        .init(name: "/config", strategy: .text, readback: .none, explanation: "Runs in the engine; the persisted setting is read back with get_settings."),
        .init(name: "/login", strategy: .login, readback: .none, explanation: "Signs in through the Browser tab."),
        .init(name: "/logout", strategy: .lifecycle(.logout), readback: .none, explanation: "Signs out every owned channel and afleet-launched job on this machine."),
        .init(name: "/color", strategy: .text, readback: .none, explanation: "Sent to the engine as text."),
        .init(name: "/clear", strategy: .text, readback: .none, explanation: "Clears the conversation; the timeline resets on conversation_reset."),
        .init(name: "/rewind", strategy: .rewind, readback: .none, explanation: "Rewinds the conversation and, after a dry run you confirm, the files."),
        .init(name: "/fork", strategy: .lifecycle(.fork), readback: .none, explanation: "Opens a new channel forked from this session."),
        .init(name: "/background", strategy: .lifecycle(.sendToBackground), readback: .none, explanation: "Hands this session to a background job."),
        .init(name: "/stop", strategy: .interrupt, readback: .none, explanation: "Stops the current turn; Stop everything also stops background tasks."),
        .init(name: "/tasks", strategy: .native("tasks"), readback: .none, explanation: "Shows the running tasks with per-task Stop."),
        .init(name: "/mcp", strategy: .mcpPopover, readback: .none, explanation: "Shows MCP servers and their state."),
        .init(name: "/memory", strategy: .memoryFiles, readback: .none, explanation: "Opens the memory files in the Files tab."),
        .init(name: "/btw", strategy: .sideQuestion, readback: .none, explanation: "Asks a side question without affecting the conversation."),
        .init(name: "/agents", strategy: .native("agents"), readback: .none, explanation: "Lists the agents from the handshake."),
        .init(name: "/resume", strategy: .native("switcher"), readback: .none, explanation: "Focuses the channel switcher."),
        .init(name: "/compact", strategy: .text, readback: .none, explanation: "Compacts in the engine; renders as a divider."),
        .init(name: "/context", strategy: .text, readback: .none, explanation: "Sent to the engine as text."),
        .init(name: "/cost", strategy: .text, readback: .none, explanation: "Sent to the engine as text."),
        .init(name: "/usage", strategy: .text, readback: .none, explanation: "Sent to the engine as text."),
    ]
    public static let bareRefusalPattern = #"^/([A-Za-z0-9:_-]+) isn't available in this environment\.$"#
}
public enum LaunchSettingMatrix {
    public static let runtimeMutable: Set<String> = ["model", "permissionMode", "effort", "agent", "sessionName", "thinkingTokens", "fastMode", "cwd"]
    public static let restartRequired: Set<String> = ["sessionId", "forkSession", "worktree", "streamFlags", "allowBypass", "settingSources", "promptSuggestions", "enableAuthStatus", "sessionMirror", "addDir", "childEnvironment"]
}
```

`Router/CommandRouter.swift`: `Routed = .controlRequest(AnyControlRequest) | .strategy(RouteStrategy, arguments: [String]) | .lifecycle(LifecycleAction) | .restart(RestartRequest) | .text(String) | .native(String) | .refusedLocally(explanation: String)`; `route(text, handshake, systemInit)`: split the first token; local table first (argument parsing per command: `/effort <level>` → `ApplyFlagSettings(settings: ["effortLevel": level])`; `/agent <name>` → `["agent": name]`; `/fast` → `["fastMode": true]` toggling on the runtime state's `fastMode`; `/cd <path>` → `SetCwd(path:)`; `/model <m>` → `SetModel`; `/permissions <mode>` → `SetPermissionMode`, bare → `.strategy(.permissionsView)`; `/rename <t>` → `RenameSession`; `/stop` → `Interrupt()`; `/rewind <uuid>`, `/login`, `/mcp`, `/memory`, `/btw <text>` → their strategies), then `systemInit.terminalSlashCommands` → `.refusedLocally`, then `.text`. `continueCD(afterNeedsTrust directory:, path:)` builds `SetCwd(path:, trustAccepted: true, trustedDirectory: directory)`. `StrategyExecutor.run(_ strategy:, on supervisor: ChannelSupervisor, ui: any StrategyUI)` runs the multi-step strategies exactly as the tests above describe, sending every request through `supervisor.perform` (so the runtime state is updated on the way), pausing at `ui.confirm(preview:)` for `.rewind` and handing URLs to `ui.open(url:)` for `.login`. `StrategyUI` is a small protocol (`open(url:)`, `confirm(preview:) async -> Bool`) the app implements and the tests script. The results are value types declared beside the executor: `RewindPreview {canRewind, filesChanged: [String], insertions, deletions}`, `RewindOutcome {rewound, prefillText: String?}`, `LoginPrompt {manualURL, automaticURL}`, `LoginOutcome {.noActiveFlow, .signedIn(account: String)}`, `PermissionsView {rules: [String: JSONValue]}`, `MCPPopover {servers: [(name: String, status: String)]}`, and `[String]` for the memory files. `AnyControlRequest` is a type-erased `ControlRequestSpec` (subtype, payload and a decoder for the answer) so `Routed` carries a typed spec without a generic parameter. `RefusalInterceptor` holds a drift counter (an actor-isolated `Int` on the facade) and matches the whole text against `bareRefusalPattern`.

`LifecycleRowTests+Logout.swift` (an extension of `LifecycleRowTests`, the last entries added to `coverage`): `testTerminateReturningNilDuringLogoutRunsNoAuthLogout` (`during: .logout`, from ready and from connecting): two owned channels, one on the scripted handle; `LogoutPlan.execute(.stop)` → the first channel terminated, the second wedged with the trace, the runner recorded **no** `["auth", "logout"]`, the plan's outcome is `.blocked(wedged: [key])` naming the channel, and the barrier is lifted. Deliberate break: run `auth logout` after a wedged terminate → a live process loses its credentials mid-turn. With this file every scenario in `LifecycleTable.scenarios` has a declaring test; Task 12's gate proves it.

`Router/LogoutPlan.swift`: `Census {owned: [ChannelKey], nonEligible: [(ChannelKey, [String])], ownJobs: [JobShort], foreign: [Holder]}`; `build(fleet:)`; `execute(choice: .wait | .stop, ...)` in the spec's order with the barrier (`Fleet.spawnBarrier = true` → every `spawn` throws `LifecycleError.logoutInProgress`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: the command router as data with typed strategies, the flag matrix, refusal interception, the logout plan"
```

---

### Task 9: Activity, diagnostics, the import graph, the `Fleet` facade

**Files:**
- Create: `FleetKit/Sources/FleetSessions/Activity/ActivityQuery.swift`
- Modify: `FleetKit/Sources/FleetSessions/Diagnostics/FleetDiagnostics.swift` (adds `FileFleetDiagnostics`)
- Create: `FleetKit/Sources/FleetSessions/Fleet.swift`
- Test: `FleetKit/Tests/FleetSessionsTests/ActivityQueryTests.swift`, `ImportGraphTests.swift`, `FleetFacadeTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `ActivityQuery.rows(...)`, `ActivityRow`, `FileFleetDiagnostics`, `public actor Fleet: LifecycleAPI` with `init(configHome:, environment:, binary:, store:, diagnosticsDirectory:, clock:, factory: ProcessFactory? = nil, runner: any ProcessRunner = FoundationProcessRunner())`, `events(of:)` (the supervisor's fan-out, nil when the key has no owned supervisor) and `perform(.answer(id, answer), on:)` delegating to the supervisor's `answer`.

- [ ] **Step 1: Write the failing tests**

`ActivityQueryTests.swift`: a table of inputs → rows: a pending decision → `.decision(key, requestID)`; a `result` with `is_error` → `.failedResult`; `permission_denials` entries and a `system/permission_denied` → `.permissionDenied`; a `rate_limit_event` with `status: "allowed"` and `overageStatus: "rejected"`, `overageDisabledReason: "org_level_disabled"` → **no** refusal row and a banner row of kind `.rateLimitInfo` (deliberate break: key on `overageStatus` → a refusal row appears); `status: "rejected"` → `.rateLimitRefused`; an `auth_status` with `error` → `.authProblem`, a healthy one clears it; a running mirror entry → `.agentRunning`, a failed `task_notification` → `.agentFailed`. Each row carries the `ChannelKey` and, when it exists, the item uuid.

`ImportGraphTests.swift`: grep every `import` line under `FleetKit/Sources/FleetSessions` and assert the set of imported modules is a subset of `["Foundation", "Darwin", "AfleetCore", "ClaudeWire", "WireFrames", "WireTransport", "WireEnvironment", "WireMCP", "WireDiagnostics", "FleetTimeline", "FleetSessions"]` and contains at least `AfleetCore` and `ClaudeWire` (the floor that proves the grep found the files). Deliberate break: import `Workbench` in a scratch file → the set gains a name.

`FleetFacadeTests.swift`: `Fleet` built over a `ScratchConfigHome` with the fake-claude factory: `states()` lists a channel after `open(key)`; `updates` publishes; `preconditions(for:)` runs; `events(of: key)` handed to two subscribers yields the replay's frames to both alike and returns nil for a key with no supervisor; `perform(.answer(id, allow), on: key)` for an id no process asked throws `decisionGone`; `openInTerminal` returns a request and `paneExited` re-adopts (facade-level replay of Task 5's row); `declineProjectServers` writes under a temporary project; the diagnostics file under a temporary directory has one JSON line per event with the key set `{event, ...structural}` and no key named `path`, `environment`, `stdout`, `record` (assert on key names). Deliberate break: log the pane request's environment → a forbidden key appears.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path FleetKit --filter "ActivityQueryTests|ImportGraphTests|FleetFacadeTests" 2>&1 | tail -5`
Expected: build errors naming `ActivityQuery`, `Fleet`.

- [ ] **Step 3: Implement**

`Diagnostics/FleetDiagnostics.swift` gains `public final class FileFleetDiagnostics: FleetDiagnosticsSink, @unchecked Sendable`: one JSON line per event (`jsonValue` from Task 3's enum) in the app's diagnostics directory beside C2's file, the same shape and rotation as ClaudeWire's `FileDiagnostics`, file name `fleet.log`, rotated once into `fleet.log.1`; a serial queue owns the handle.

`Activity/ActivityQuery.swift`: `ActivityRow {key, kind: Kind, itemUUID: String?, text: String}` with `Kind = decision(RequestID), notification, failedResult, permissionDenied, rateLimitRefused, rateLimitInfo, authProblem, agentRunning(String), agentFailed(String)`; `rows(states: [ChannelState], mirrors: [ChannelKey: [any TaskMirrorReading]], recent: [ChannelKey: [Frame]]) -> [ActivityRow]` pure.

`Fleet.swift`: the facade actor owning `[ChannelKey: ChannelSupervisor]`, the `FleetObserver`, `FleetCapCounter`, `StateStore`, `CLIVerbs` (environment composed once through `LaunchConfiguration(binary:cwd: configHome.root, session: .new(SessionID())).childEnvironment(over:configHome:)`), `SpawnPreconditions`, `CommandRouter`, `RefusalInterceptor`, `LogoutPlan`, `spawnBarrier`; implements every `LifecycleAPI` method by delegating to the supervisor for the key (`events(of:)` returns `await supervisor.events()` or nil; `.answer` is forwarded to `supervisor.answer`; the facade holds no process and no stream of its own), creating one on first use with `isRecent` supplied by the caller (`open(key, recent:)` is the facade's extra entry point; the protocol's `perform(.open)` uses the stored recency); `updates` merges every supervisor's stream; a fork re-keys the map on `sessionIdentityResolved`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`
Expected: 0 failures, no skips.

- [ ] **Step 5: Commit**

```bash
git add FleetKit
git commit -m "FleetSessions: the Activity query, FleetKit diagnostics, the import-graph test, the Fleet facade"
```

---

### Task 10: The live gate against the installed CLI (G5) and the write allowlist

**Files:**
- Test: `FleetKit/Tests/FleetSessionsTests/LiveFleetTests.swift`
- Create: `FleetKit/Tests/FleetSessionsTests/Support/LiveGate.swift` (the `LiveBudget` actor, the budget reading copied in shape from `ClaudeWire/Tests/ClaudeWireTests/LiveCLITests.swift`, which is not exported, and the config-home witness)

**Interfaces:**
- Consumes: the `Fleet` facade; the installed `claude` located through `BinaryLocator` from an `EnvironmentResolver` capture; `/tmp/afleet-fixtures/config-home`.
- Produces: the G5 verdicts and the widened allowlist `LiveGate.engineWrittenPaths`.

- [ ] **Step 1: Write the gate**

`Support/LiveGate.swift`: `skipUnlessLive()` throws `XCTSkip("set AFLEET_LIVE_CLI=1 to run against the installed CLI")`, then `XCTSkip("scratch config home has no login; run: CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home claude")` when none of `.credentials.json`, `credentials.json`, `.claude.json` exists there; `skipUnlessTurns()` for `AFLEET_LIVE_CLI_TURNS=1`; `LiveBudgetReading.read(getUsage:)` exactly as C2's (copied, with a comment naming the source file).

`LiveBudget` is one actor for the whole suite (a `static let` on `LiveFleetTests`), and every live scenario runs inside `budget.run(turns: Int, wallTime: Duration) { ... }`: the call reserves the scenario's turns and its projected wall time synchronously, before awaiting the body, and serialises callers through a continuation queue (a non-reentrant async lock: a second caller suspends inside `run` until the first body has returned, so an `await` inside a body never lets another body start); it refuses with `XCTSkip("live budget: N turns already spent of 2")` or `"...wall time"` when the request would cross the suite ceilings of **two model turns** and **ten minutes**; for `turns > 0` it first reads C2's usage through a zero-cost `ClaudeProcess` (`get_usage` after a fresh handshake, `--max-turns 1`, then `get_session_cost` asserted zero) and skips with the reading's `reason` when `isSpent`; it decorates every `LaunchConfiguration` the scenario builds through `budget.launch(_:)` with `maxTurns` (1 for `turns == 0`, else the scenario's `turns`) and, for `turns > 0`, `model: "claude-haiku-4-5-20251001"`, and it asserts on the way out that no launch bypassed the decoration (the factory counts); it sums `total_cost_usd` from every `result` frame the scenario's channels observed and reports `budget.summary` (turns used, cost sum, wall time) after the last scenario. Zero-cost scenarios call `budget.witnessZeroCost(process)` before ending each process: `get_session_cost` → `session.total_cost_usd == 0`, asserted, because a zero-turn launch emits no `result` frame (the `zero-cost` fixture is the evidence). `ConfigHomeWitness` records `{relative path: (size, mtime)}` for every regular file under the scratch home (hidden included) and `difference(from:)` returns created/modified/deleted relative paths; `engineWrittenPaths` is the spec's allowlist as prefix patterns: `sessions/`, `projects/`, `tasks/`, `jobs/`, `daemon/`, `daemon.log`, `history.jsonl`, `.claude.json`, `shell-snapshots/`, `session-env/`, `file-history/`, `statsig/`, `cache/`, `todos/`, `debug/`, `plugins/`, `backups/`, `plans/`, `ide/`, `logs/`, `history/`, `.credentials.json`, `.last-cleanup`, `.last-update-result.json`, `settings.json`; `unexplained(difference)` returns every path whose first component matches none. The suite-level witness is taken in `LiveFleetTests`' class `setUp` and compared in class `tearDown` (`XCTAssert` through a recorded failure on the last test when unexplained paths exist); each scenario takes its own before/after pair inside `budget.run`; a path unexplained in either reading fails with the path named, so a write between scenarios is caught as surely as one inside a scenario.

`LiveFleetTests.swift`:

- `testAForeignInteractiveSessionIsDetectedWithinFiveSecondsAndArchivedWhenItEnds`: `skipUnlessLive`; `budget.run(turns: 0)` (the interactive child is not a `ClaudeProcess`; it never receives a prompt); pick a directory the scratch `.claude.json` already trusts (the first `projects` key with `hasTrustDialogAccepted == true` whose path is under `/private/tmp/afleet-fixtures/`; recreate it if absent; skip with `XCTSkip("no trusted scratch directory")` when none); start `claude` (no `-p`) on a pty via `openpty` + `posix_spawn` with the child environment from `LaunchConfiguration.childEnvironment` (so `CLAUDE_CONFIG_DIR` is the scratch home) and `TERM=xterm-256color`; build a `Fleet` over the scratch home with the real `FoundationProcessRunner`; poll `states()` on wall time up to 5 s until a channel with `origin == .foreignLive(.usersTerminal)` appears whose `key.session` is the pid's registry record's session; assert it appeared, its presence is one of `idle/busy/waiting/unknown`; write `Ctrl-C` twice or `/exit\r` to the pty and wait for the child to exit; poll up to 10 s until the channel is `.archived`. Never sends a prompt. Deliberate break: filter registry records by `entrypoint == "sdk-cli"` → the interactive session is never detected.
- `testAnExecJobIsListedAsABackgroundJobAndStopRemovesIt`: `skipUnlessLive`; `budget.run(turns: 0)`; `fleet.verbs.backgroundExec("sleep 60", cwd: trustedDir)`; poll up to 5 s for `.backgroundJob`; `perform(.stopJob(short))`; poll until the job holder is gone; record in the test log whether the exec job's `state.json` carried a `sessionId` (the delegated unknown), as a one-line `XCTContext.runActivity` note with the boolean only.
- `testADeclinedProjectServerIsNotSpawnedByTheEngine` (G3's engine-side proof; zero cost): `skipUnlessLive`; `budget.run(turns: 0)`; in a trusted scratch directory, write a `.mcp.json` declaring one stdio server `marker` whose command is `/bin/sh -c 'touch <dir>/marker-<uuid>; exec sleep 30'`; `acceptProjectServers([marker], project: dir)` through the facade (the store-only accept, so Task 7's consent gate does not stop A at `.consentNeeded`; the marker then proves the engine's own promotion, not the gate's); launch A through the `Fleet` with no decline on record (`--max-turns 1` from the budget) → handshake, `MCPStatus`, `witnessZeroCost`, terminate; assert the marker file exists (the headless path promoted the pending server and spawned its command, parent §6.12) and remove it; then `LocalSettingsStore.decline(["marker"])` through the facade's consent verb (the decline outranks the recorded acceptance, Task 7's precedence); launch B identically → handshake, `MCPStatus`, `witnessZeroCost`, terminate; assert no marker file exists and that the project tree differs from before only by `.claude/settings.local.json`; record both `mcp_status` answers as `XCTContext` notes carrying server counts and status words only (the shape for a rejected server is unrecorded, so it is not asserted). Deliberate break: skip the decline write → B spawns the marker too.
- `testTwoOverlappingScenariosRunOneAtATimeWithAtomicAccounting` (a unit test over a fresh `LiveBudget` with a two-turn ceiling; zero cost, runs without the live flag): two `budget.run(turns: 1)` bodies started with `async let`, each recording entry and exit on a shared counter and suspending on a continuation the test resumes; at no point are two bodies inside at once, the second body starts only after the first has returned, and a third `run(turns: 1)` issued while the first two are queued is refused with the budget skip because both turns were reserved at call time, not at body start. Deliberate break: account the turn when the body returns → the third call is admitted.
- `testAdoptingAConversationJobResumesItOwned`: `skipUnlessLive`, `skipUnlessTurns`; `budget.run(turns: 1)`; `claude --bg --model claude-haiku-4-5-20251001 "Reply with exactly: pong"` (plus `--max-turns 1` when `claude --bg --help` lists the flag, checked once at zero cost and recorded) through the runner; poll for the job; `perform(.adopt)`; assert the runner recorded `stop`, the job left the roster, the channel became `.owned(.ready)` under the job's `sessionId`, and the post-handshake check found no holder. One short turn.
- `testTheWriteAllowlistHoldsAcrossHooksABackgroundShellASubagentAndRelocation`: `skipUnlessLive`, `skipUnlessTurns`; `budget.run(turns: 1)` (the launch carries `--max-turns 2` because the subagent's reply arrives inside the one turn); witness before; open a new owned channel in the trusted directory with the Notification hook registered (C2's default `InitializeConfiguration`) and subscribe to `fleet.events(of: key)` before sending; send one `haiku` prompt: `Run "sleep 20 &" as a background shell, then use an Explore subagent to list the files in this directory, then reply "done".`; when the `result` arrives, `/cd` into a second trusted scratch directory (`set_cwd`) and wait for its answer; take the live witness reading now, while the child still runs; terminate; take the final reading. Assert from the channel's events that the prompt's actions ran, each named on failure: a `system/task_started` with `task_type == "local_bash"` (the background shell, as C1's `background-shell` fixture records), a `system/task_started` with `task_type == "local_agent"` (the subagent, as `explore-depth-1` records) and an inbound `hook_callback` request with `callback_id == "afleet.notification"` (the Notification hook, as `notification-hook` records); a missing one fails with its kind named. Both readings must be fully explained, `unexplained(difference).isEmpty` for each with the offending relative paths in the message; the live reading must touch `sessions/` (the child's own record exists only while it runs) and the final reading `projects/` (the transcript), the floor on "the reading looked at the right tree". Deliberate break: remove `projects/` from the allowlist → the transcript is unexplained in the final reading (it is always written, so this is the discriminating demonstration and is run once). `tasks/` stays on the list as inherited from C2's observed set but is no demonstration: a background shell's output lives under the engine's temp artifacts tree, `<artifacts>/<slug>/<session>/tasks/<id>.output` (`Tools/probe/fixture.py:23,217`), not under the config home.
- `testTheAllowlistNamesNothingTheEngineIsNotKnownToWrite`: a unit test over `engineWrittenPaths` asserting the set equals the spec's list exactly, so an addition is deliberate.

- [ ] **Step 2: Run without the live flag**

Run: `swift test --package-path FleetKit --filter LiveFleetTests 2>&1 | grep -E "Executed|skipped"`
Expected: `Executed 7 tests, with 5 tests skipped and 0 failures` (the allowlist unit test and the budget unit test run).

- [ ] **Step 3: Run the live gate once**

Run: `AFLEET_LIVE_CLI=1 swift test --package-path FleetKit --filter LiveFleetTests 2>&1 | grep -E "Test Case|Executed|skipped|error"`
Expected: the three zero-turn tests pass, each with a `get_session_cost` reading of 0 in its log; the two turn tests skip with `set AFLEET_LIVE_CLI_TURNS=1`. Before the first live run, read the scratch account's window with C2's reading; the coordinator's last reading was 98% at 02:55Z resetting 06:00Z, and a spent window skips, not fails.
Then, once: `AFLEET_LIVE_CLI=1 AFLEET_LIVE_CLI_TURNS=1 swift test --package-path FleetKit --filter LiveFleetTests 2>&1 | grep -E "Test Case|Executed|skipped|error"`
Expected: all seven pass, or the budget skip names the spent window. Quote the summary line, `budget.summary` (turns used, the summed `total_cost_usd` from the `result` frames, wall time) and the three zero readings in the commit body; do not retry a failed turn — report it.

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

`MirrorEligibilityTests.swift` (G2): drive C3's reducer with the `background-shell` fixture through a fake-claude replay under a `ChannelSupervisor`, with C3's entry conforming to `TaskMirrorReading` (`isArmed` from the announced-not-started state, `isRunning` from started-or-updated-not-complete). The boundary cases are the same five as Task 2's `testTheMirrorBoundaryCases`, asserted case for case against the real mirror: while an entry is armed, advance the clock 30 min → no `terminate` (`.blocked(.taskArmed)`); while it runs with fresh frames → no `terminate` (`.taskRunning`); while it runs and the last task frame is older than the heartbeat → no `terminate` and the blocker is `.taskStateUncertain` (the second half of the fixture, paced by `FAKE_CLAUDE_SPEED` and the clock); after the `task_notification` empties the mirror and the heartbeat interval passes with no frames, advance → `terminate` observed (stale history is not uncertainty); a mirror holding only a completed entry with an old frame → `terminate` observed. Deliberate break: feed the supervisor the empty stand-in instead of the mirror → the first half reaps; treat any old frame as uncertainty → the fourth case never reaps.

`StoreIndexStorageTests.swift`: `save` then `load` round-trips C3's snapshot type; a store from the future refuses; `load` on an empty store returns `nil`.

- [ ] **Step 2: Implement, run, commit**

Run: `swift test --package-path FleetKit 2>&1 | grep -E "Executed|error:|failed"`; expected 0 failures.

```bash
git add FleetKit
git commit -m "FleetSessions: G2 over C3's registry mirror; IndexStorage over the store"
```

---

### Task 12: Final verification against the spec's acceptance

**Files:**
- Test: `FleetKit/Tests/FleetSessionsTests/LifecycleCoverageTests.swift` (G1's gate)
- The spec's `## Outcomes & Retrospective` is written by the controller at finish, not here.

- [ ] **Step 1: Clean build of every package**

```bash
rm -rf FleetKit/.build ClaudeWire/.build AfleetCore/.build
swift test --package-path AfleetCore 2>&1 | grep -E "Executed .* tests"
swift test --package-path ClaudeWire 2>&1 | grep -E "Executed .* tests"
swift test --package-path FleetKit 2>&1 | grep -E "Executed .* tests|skipped"
```
Expected: every line reads `0 failures`; FleetKit's skips are exactly the five live tests, each with its named reason; nothing else skips.

- [ ] **Step 2: G1's gate, red then green**

`LifecycleCoverageTests.swift`:

```swift
final class LifecycleCoverageTests: XCTestCase {
    /// The gate: the union of every declared scenario set equals the table, both ways, and every declaring method exists.
    func testEveryScenarioInTheTableIsDeclaredByARowTest() {
        let declared = LifecycleRowTests.coverage.values.reduce(into: Set<LifecycleTable.Transition>()) { $0.formUnion($1) }
        let table = Set(LifecycleTable.scenarios)
        XCTAssertEqual(table.subtracting(declared), [], "scenarios in the table no test drives")
        XCTAssertEqual(declared.subtracting(table), [], "declared scenarios the table does not contain")
        for name in LifecycleRowTests.coverage.keys {
            XCTAssertTrue(LifecycleRowTests.instancesRespond(to: Selector(name)), "coverage names a test that does not exist: \(name)")
        }
    }
}
```

Demonstrate red first: delete one entry from a declared set in `LifecycleRowTests.coverage` (the `.foreignSendRefused` scenario, say) and run

```bash
swift test --package-path FleetKit --filter LifecycleCoverageTests 2>&1 | grep -E "scenarios in the table|failed|Executed"
```
Expected: one failure naming the deleted `(row, from, event, to)`. Restore the entry and run

```bash
swift test --package-path FleetKit --filter "LifecycleCoverageTests|LifecycleRowTests" 2>&1 | grep -E "Test Case .*(passed|failed)|Executed"
```
Expected: the gate passes and one passed line per method name in `LifecycleRowTests.coverage`, including the `+Restart` and `+Logout` extension tests; 0 failures. Commit: `git commit -m "FleetSessions: G1's coverage gate over the lifecycle table"`.

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

Record the counts, the skips with their reasons, `budget.summary` (turns, summed cost, wall time) and the three zero-cost readings, and the state of Task 11 in the plan's ledger (`.doperpowers/sde/2026-09-05-c4-fleetkit-sessions-fleet/progress.md`); the controller writes the spec's Outcomes. No commit unless a file changed.

---

## Self-review notes

- Spec coverage: Purpose → Tasks 4–9; G1 → Tasks 4–8 (the gate in Task 12); G2 → Task 11; G3 → Task 7; G4 → Task 8; G5 → Task 10; store (X6) → Task 1; X5 types and pane protocol → Tasks 2, 5; listing policy → Task 2; Activity → Task 9; diagnostics → Tasks 3, 9; verbs cadence → Task 3; wedged exclusions → Tasks 2, 5; wedged from every terminating action → Tasks 5, 6, 8; the cap as reservations → Tasks 4, 5; ownership with no excused holder → Task 4; `PaneRequest.id` → Tasks 2, 5; runtime state and the restart → Task 6; `forkFrom` → Task 6; consent from the merged settings only → Task 7; the descriptor-relative §6.12 writer → Task 7; the engine-side decline proof → Task 10; typed router strategies → Task 8; the live budget and the suite-level witness → Task 10; `IndexStorage` → Task 11; the write allowlist → Task 10; `LifecycleAction.answer` and `LifecycleAPI.events(of:)` → Tasks 2, 4, 9; the `procStart` comparison → Task 3; `flagSettings`, `fastModeObserved` and the restart readbacks → Task 6.
- Interface consistency: `TaskMirrorReading` (Task 2) is consumed by Tasks 4, 5, 9 and satisfied by C3's type in Task 11; `PaneRequest`/`PaneExit` (Task 2) are produced by Task 5 and exercised by Task 9's facade test; `CLIVerbs` (Task 3) is consumed by Tasks 5, 8, 10; `FleetDiagnosticsSink` is introduced minimally in Task 3 and completed in Task 9.
- No open item remains from v1: the fork-point flags landed as C2's `SessionStart.forkFrom` (`main` `13c9ad4`) and Task 6 uses them with no skip. Two steps in Task 8 run against scripted `fake-claude` answers because the corpus lacks the frames (the `rewind_files` apply and the completed `claude_oauth_wait_for_completion`), and each test says so; a completed login cannot be recorded without a real OAuth flow, and the rewind apply was never captured. Two facts G5 records rather than asserts: the `mcp_status` shape for a rejected server, and whether `claude --bg` accepts `--max-turns`.
