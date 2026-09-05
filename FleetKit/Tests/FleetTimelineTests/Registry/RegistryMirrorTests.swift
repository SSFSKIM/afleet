import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// The registry mirror folded from the recorded task frames. Every fold below runs on the recording's own clock —
/// `now = Date(timeIntervalSince1970: t / 1000)` from the `frames.ndjson` envelope — so no assertion waits on wall time.
final class RegistryMirrorTests: XCTestCase {

    // MARK: - The fixture's task events

    /// One thing the mirror folds: a `system` task frame, or the Bash `tool_result` text that binds the output file.
    enum TaskEvent {
        case system(SystemFrame, Date)
        case bashResult(text: String, toolUseID: String, Date)

        var at: Date {
            switch self { case .system(_, let d): d; case .bashResult(_, _, let d): d }
        }
        var subtype: String {
            switch self { case .system(let f, _): f.subtype; case .bashResult: "tool_result" }
        }
    }

    /// Every task event of a fixture, in `t` order (ties broken by the frame's position, which is the recorded order).
    /// A `user` frame contributes only when a `tool_result` block carries the background-Bash sentence.
    static func taskEvents(_ fixture: FixtureCorpus.Fixture) throws -> [TaskEvent] {
        let wanted: Set<String> = ["task_started", "task_updated", "task_progress", "task_notification", "background_tasks_changed"]
        var out: [(Int, Int, TaskEvent)] = []
        for recorded in try fixture.frames() {
            let at = Date(timeIntervalSince1970: Double(recorded.t) / 1000)
            switch recorded.frame {
            case .system(let system) where wanted.contains(system.subtype):
                out.append((recorded.t, recorded.index, .system(system, at)))
            case .user(let user):
                guard case .blocks(let blocks) = user.message.fields.content else { continue }
                for block in blocks {
                    guard case .toolResult(let result) = block, let text = result.content?.stringValue else { continue }
                    guard text.contains("with ID: "), text.contains("Output is being written to: ") else { continue }
                    out.append((recorded.t, recorded.index, .bashResult(text: text, toolUseID: result.toolUseID, at)))
                }
            default: continue
            }
        }
        return out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// Fold a prefix of the events into a fresh mirror. `upTo` is the count of events applied, so a caller can walk the
    /// recording row by row; `dropping` removes a subtype from an otherwise identical fold.
    static func fold(_ events: [TaskEvent], upTo: Int? = nil, dropping: String? = nil,
                     epoch: ProcessEpoch = .first) -> RegistryMirror {
        var mirror = RegistryMirror()
        for event in events.prefix(upTo ?? events.count) where event.subtype != dropping {
            switch event {
            case .system(let frame, let at): _ = mirror.apply(frame, at: at, epoch: epoch)
            case .bashResult(let text, let toolUseID, let at):
                mirror.observe(bashToolResult: text, toolUseID: toolUseID, at: at, epoch: epoch)
            }
        }
        return mirror
    }

    // MARK: - Tests

    /// `background-shell`, one event at a time. Each row asserts the state that row alone produces, so a fold that only
    /// happens to reach the right end state fails somewhere in the middle.
    func testBackgroundShellRowByRow() throws {
        let fixture = try FixtureCorpus.named("background-shell")
        let events = try Self.taskEvents(fixture)
        XCTAssertEqual(events.map(\.subtype),
                       ["background_tasks_changed", "task_started", "tool_result",
                        "background_tasks_changed", "task_updated", "task_notification"],
                       "background-shell's recorded task-event sequence")

        // Row 1 — the engine lists the task before any task_started names it: a minimal entry, live, not yet started.
        var mirror = RegistryMirror()
        guard case .system(let listing, let listedAt) = events[0] else { return XCTFail("row 1 is a system frame") }
        let touchedByListing = mirror.apply(listing, at: listedAt, epoch: .first)
        let id = try XCTUnwrap(mirror.entries.keys.sorted().first, "background_tasks_changed creates the entry it names")
        XCTAssertEqual(touchedByListing, [id], "a listing reports the id it listed")
        XCTAssertEqual(mirror.entries.count, 1)
        XCTAssertEqual(mirror.entries[id]?.kind, .localBash)
        XCTAssertEqual(mirror.entries[id]?.listedByEngine, true)
        XCTAssertEqual(mirror.entries[id]?.startedCount, 0, "no task_started has arrived yet")
        XCTAssertEqual(mirror.liveWork(asOf: events[0].at).map(\.id), [id])

        // Row 2 — task_started arms it.
        mirror = Self.fold(events, upTo: 2)
        var entry = try XCTUnwrap(mirror.entries[id])
        XCTAssertEqual(mirror.entries.count, 1, "task_started reuses the listed entry, it does not add one")
        XCTAssertEqual(entry.kind, .localBash)
        XCTAssertEqual(entry.placement, .background)
        XCTAssertEqual(entry.status, .running)
        XCTAssertEqual(entry.listedByEngine, true)
        XCTAssertEqual(entry.notified, false)
        XCTAssertEqual(entry.startedCount, 1)
        XCTAssertNil(entry.outputFile, "no frame has named the output file yet")
        XCTAssertEqual(entry.lastFrameAt, events[1].at)
        XCTAssertEqual(mirror.liveWork(asOf: events[1].at).map(\.id), [id])
        let toolUseID = try XCTUnwrap(entry.toolUseID)
        XCTAssertEqual(mirror.entry(forToolUse: toolUseID)?.id, id)

        // Row 3 — the Bash tool_result binds the output file, before any task frame carries it.
        mirror = Self.fold(events, upTo: 3)
        entry = try XCTUnwrap(mirror.entries[id])
        let boundFile = try XCTUnwrap(entry.outputFile, "the tool_result sentence binds the output file")
        XCTAssertEqual(entry.status, .running)
        XCTAssertEqual(entry.notified, false)

        // Row 4 — the engine unlists it; nothing else moves, and it is still live work. The empty payload names no id,
        // so the frame must report the one it unlisted: Task 8's reducer learns what changed from this return value.
        mirror = Self.fold(events, upTo: 3)
        guard case .system(let unlisting, let unlistedAt) = events[3] else { return XCTFail("row 4 is a system frame") }
        XCTAssertEqual(mirror.apply(unlisting, at: unlistedAt, epoch: .first), [id],
                       "an empty background_tasks_changed reports the id it unlisted")
        entry = try XCTUnwrap(mirror.entries[id])
        XCTAssertEqual(entry.listedByEngine, false)
        XCTAssertEqual(entry.status, .running, "background_tasks_changed is a liveness cross-check, not a status")
        XCTAssertEqual(entry.notified, false)
        XCTAssertEqual(mirror.liveWork(asOf: events[3].at).map(\.id), [id])

        // Row 5 — task_updated completes it and stamps end_time; still live, because the host has not been notified.
        mirror = Self.fold(events, upTo: 5)
        entry = try XCTUnwrap(mirror.entries[id])
        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.notified, false)
        let endedAt = try XCTUnwrap(entry.endedAt, "patch.end_time sets endedAt")
        XCTAssertEqual(mirror.liveWork(asOf: events[4].at).map(\.id), [id],
                       "a completed but un-notified task is still live work")
        XCTAssertEqual(mirror.evictable(asOf: endedAt.addingTimeInterval(31)), [],
                       "an un-notified entry is never evictable, however old")

        // Row 6 — task_notification: notified, summarised, output file confirmed, and out of live work.
        mirror = Self.fold(events, upTo: 6)
        entry = try XCTUnwrap(mirror.entries[id])
        guard case .system(let last, _) = events[5], case .taskNotification(let notification) = last else {
            return XCTFail("the last event is the task_notification")
        }
        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.notified, true)
        XCTAssertEqual(entry.listedByEngine, false)
        XCTAssertEqual(entry.outputFile, URL(fileURLWithPath: notification.outputFile))
        XCTAssertEqual(entry.outputFile, boundFile, "the notification confirms the file the tool_result already bound")
        XCTAssertEqual(entry.summary, notification.summary)
        XCTAssertEqual(entry.endedAt, endedAt, "the notification does not move an endedAt task_updated already set")
        XCTAssertEqual(mirror.liveWork(asOf: events[5].at), [])
        XCTAssertEqual(mirror.evictable(asOf: endedAt.addingTimeInterval(31)), [id])
        XCTAssertEqual(mirror.evictable(asOf: endedAt.addingTimeInterval(29)), [], "inside the 30s grace")
    }

    /// `nested-depth-2` starts two distinct tasks. Re-arming one — the same recorded `task_started` applied a second
    /// time — counts a start, and never a second entry.
    func testTaskStartedRepeatsAreTheSameEntry() throws {
        let fixture = try FixtureCorpus.named("nested-depth-2")
        let events = try Self.taskEvents(fixture)
        var mirror = Self.fold(events)
        let ids = mirror.entries.keys.sorted()
        XCTAssertEqual(ids.count, 2, "nested-depth-2 records two distinct task ids")
        XCTAssertEqual(mirror.entries.values.filter { $0.startedCount == 1 }.count, 2)

        guard let replay = events.compactMap({ event -> (SystemFrame, Date)? in
            guard case .system(let frame, let at) = event, case .taskStarted = frame else { return nil }
            return (frame, at)
        }).first else { return XCTFail("nested-depth-2 records a task_started") }
        guard case .taskStarted(let started) = replay.0 else { return XCTFail("unreachable") }

        let touched = mirror.apply(replay.0, at: replay.1, epoch: .first)
        XCTAssertEqual(touched, [started.taskID])
        XCTAssertEqual(mirror.entries.keys.sorted(), ids, "a repeat re-arms; it does not add an entry")
        XCTAssertEqual(mirror.entries[started.taskID]?.startedCount, 2)
        XCTAssertEqual(mirror.entries[started.taskID]?.status, .running, "a re-arm runs again")
        XCTAssertEqual(mirror.entries[started.taskID]?.notified, false)
    }

    /// `killed` is unwitnessed in the corpus, so this edits a recorded `task_updated` patch in memory — one field, from
    /// `completed` to `killed` — and decodes the edit back through `FrameDecoder`. It must land on `.stopped`.
    func testKilledNormalisesToStoppedFromAnEditedPatch() throws {
        let fixture = try FixtureCorpus.named("background-shell")
        var edited: JSONValue?
        for recorded in try fixture.frames() {
            guard case .system(let system) = recorded.frame, case .taskUpdated = system else { continue }
            var object = try XCTUnwrap(recorded.value.objectValue)
            var patch = try XCTUnwrap(object["patch"]?.objectValue)
            XCTAssertEqual(patch["status"]?.stringValue, "completed", "the recorded patch completes the task")
            patch["status"] = .string("killed")
            object["patch"] = .object(patch)
            edited = .object(object)
        }
        let value = try XCTUnwrap(edited, "background-shell records a task_updated")
        guard case .system(let system) = FrameDecoder.decode(line: try value.canonicalData()),
              case .taskUpdated(let updated) = system else {
            return XCTFail("the edited patch still decodes as system/task_updated")
        }

        var mirror = RegistryMirror()
        let at = Date(timeIntervalSince1970: 0)
        _ = mirror.apply(.taskUpdated(updated), at: at, epoch: .first)
        XCTAssertEqual(mirror.entries[updated.taskID]?.status, .stopped, "killed and stopped are one state")
    }

    /// The same `background-shell` fold with only the notification dropped: the entry stays live work. The full fold is
    /// asserted beside it, so the difference is attributable to the dropped frame and to nothing else.
    func testLiveWorkIncludesStartedButNotNotified() throws {
        let fixture = try FixtureCorpus.named("background-shell")
        let events = try Self.taskEvents(fixture)
        let full = Self.fold(events)
        let withoutNotification = Self.fold(events, dropping: "task_notification")

        let id = try XCTUnwrap(full.entries.keys.sorted().first)
        XCTAssertEqual(withoutNotification.entries.keys.sorted(), full.entries.keys.sorted(),
                       "the two folds differ by one frame, not by their entries")
        XCTAssertEqual(withoutNotification.entries[id]?.status, .completed, "task_updated already completed it")
        XCTAssertEqual(withoutNotification.entries[id]?.notified, false)
        XCTAssertEqual(withoutNotification.liveWork(asOf: events[5].at).map(\.id), [id])
        XCTAssertEqual(full.liveWork(asOf: events[5].at), [], "the notification is what ends the work")

        let endedAt = try XCTUnwrap(withoutNotification.entries[id]?.endedAt)
        XCTAssertEqual(withoutNotification.evictable(asOf: endedAt.addingTimeInterval(31)), [],
                       "un-notified work is never evicted")
        XCTAssertEqual(full.evictable(asOf: endedAt.addingTimeInterval(31)), [id])
    }

    /// An agent task is a registry row like any other: `explore-depth-1` spawns one `local_agent` at depth 1.
    func testAgentTasksAreRegistryEntriesToo() throws {
        let fixture = try FixtureCorpus.named("explore-depth-1")
        let events = try Self.taskEvents(fixture)
        let started = events.compactMap { event -> TaskStarted? in
            guard case .system(let frame, _) = event, case .taskStarted(let s) = frame else { return nil }
            return s
        }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.spawnDepth, 1, "the recorded task_started carries spawn_depth")

        let mirror = Self.fold(events)
        XCTAssertEqual(mirror.entries.count, 1)
        let entry = try XCTUnwrap(mirror.entries[try XCTUnwrap(started.first?.taskID)])
        XCTAssertEqual(entry.kind, .localAgent)
        XCTAssertEqual(entry.placement, .background)
        XCTAssertEqual(entry.status, .completed)
        XCTAssertEqual(entry.notified, true)
        XCTAssertEqual(entry.listedByEngine, false)
        XCTAssertGreaterThan(entry.description.count, 0)
    }

    /// `tool_progress` is UNWITNESSED — no fixture in the corpus carries the frame — so the line below is invented from
    /// the published schema, with invented identifiers, and decoded through `FrameDecoder` rather than hand-built. It
    /// must move `lastFrameAt` and nothing else, and must not conjure an entry for a task id the mirror does not know.
    func testToolProgressMovesLastFrameAtOnlyOnAnUnwitnessedFrame() throws {
        let fixture = try FixtureCorpus.named("background-shell")
        let events = try Self.taskEvents(fixture)
        let running = Self.fold(events, upTo: 3)          // started, file bound, not yet completed
        let id = try XCTUnwrap(running.entries.keys.sorted().first)
        let before = try XCTUnwrap(running.entries[id])

        let later = before.lastFrameAt.addingTimeInterval(2)
        var mirror = running
        mirror.apply(toolProgress: try Self.inventedToolProgress(taskID: id), at: later)
        let after = try XCTUnwrap(mirror.entries[id])
        XCTAssertEqual(after.lastFrameAt, later)
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.notified, before.notified)
        XCTAssertEqual(after.listedByEngine, before.listedByEngine)
        XCTAssertEqual(after.startedCount, before.startedCount)
        XCTAssertEqual(after.endedAt, before.endedAt)
        XCTAssertEqual(after.description, before.description)
        var expected = before
        expected.lastFrameAt = later
        XCTAssertEqual(after, expected, "lastFrameAt is the only field tool_progress moves")
        XCTAssertEqual(mirror.liveWork(asOf: later.addingTimeInterval(1)).map(\.id), [id])

        var unknown = running
        unknown.apply(toolProgress: try Self.inventedToolProgress(taskID: "invented-task-id-not-in-the-mirror"), at: later)
        XCTAssertEqual(unknown, running, "a tool_progress for an unknown task id creates nothing and moves nothing")
    }

    /// A schema-shaped `tool_progress` line built from invented identifiers. Only `task_id` comes from the fold, so no
    /// recorded byte is written into this file.
    static func inventedToolProgress(taskID: String) throws -> ToolProgressFrame {
        let line = JSONValue.object([
            "type": .string("tool_progress"),
            "tool_use_id": .string("toolu_inventedToolUseIdentifier01"),
            "tool_name": .string("Bash"),
            "parent_tool_use_id": .null,
            "elapsed_time_seconds": .number(1.5),
            "task_id": .string(taskID),
            "heartbeat": .bool(true),
            "uuid": .string("00000000-0000-4000-8000-00000000c3a1"),
            "session_id": .string("00000000-0000-4000-8000-00000000c3a2"),
        ])
        guard case .toolProgress(let frame) = FrameDecoder.decode(line: try line.canonicalData()) else {
            throw FixtureCorpus.Failure("the invented tool_progress line did not decode as a tool_progress frame")
        }
        return frame
    }
}
