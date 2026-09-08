import SwiftUI
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// The task card of §8.4, over a **`TimelineItem.taskRun`** and not a decision (spec D15).
///
/// `DecisionItem.Kind` has no `task` case and `WireReducer.kind(of:)` never produces one: a task is
/// reduced from `task_started` / `task_updated` / `task_notification`, not from an inbound request.
/// So this card's two actions are **control requests, not answers** — `stop_task {task_id}` and
/// `background_tasks {tool_use_id}` — and they go through `LifecycleAPI.send(_:on:)`. Nothing here
/// constructs an `InboundAnswer`, which is why `DecisionCard.answer(_:)` stays the one place that
/// does.
///
/// **Item 61's two arms arrive on two different paths, and that is the whole point of this model.**
/// A `{backgrounded: false}` **success** body means the entry is stale or ineligible: the card
/// refreshes, the action disappears, and no banner is raised. The sentence "Background tasks are
/// disabled in this session." arrives as a **control error** instead, before the engine consults its
/// task registry at all (`cli.pretty.js:418533`, `:452940`), so it raises the banner. A model that
/// read only the success body would never raise it.
@MainActor
@Observable
final class TaskCardModel {

    private let lifecycle: any LifecycleAPI
    private let channel: ChannelKey

    /// The item, as the card currently reads it. Replaced by `refresh` after the engine says the
    /// registry entry is not what the card thought; the card holds no status of its own.
    private(set) var item: TaskRunItem
    /// C3's registry mirror. §8.4 offers *Move to background* only for a task this knows.
    private(set) var registry: RegistryMirror
    private(set) var banner: RowBanner?
    /// The engine has said this task cannot be backgrounded — either `{backgrounded: false}` or a
    /// refusal. Either way the action goes; the two differ in whether a banner came with it.
    private(set) var backgroundingUnavailable = false
    /// A control request is on the wire. The actions disable on it, so two clicks send once.
    private(set) var inFlight = false

    /// How the host re-reads the item after the engine contradicts it. The default answers nil,
    /// which is what a host with no timeline wants: the card keeps what it has.
    var refresh: @MainActor () async -> TaskRunItem? = { nil }

    init(item: TaskRunItem, registry: RegistryMirror, lifecycle: any LifecycleAPI, channel: ChannelKey) {
        self.item = item
        self.registry = registry
        self.lifecycle = lifecycle
        self.channel = channel
    }

    // MARK: - What the card knows

    /// The registry mirror's entry for this task, or nil for a run the mirror never saw.
    var entry: RegistryEntry? { registry.entries[item.taskID] }

    var status: TaskStatus { entry?.status ?? item.status }

    var isRunning: Bool { status == .running }

    /// Per-task *Stop* exists while the task is running and nowhere else.
    var offersStop: Bool { isRunning && !inFlight }

    /// *Move to background* — §8.4's narrow clause, spelled out.
    ///
    /// It exists only for a **running** Bash call or agent run the **registry mirror knows**, with a
    /// `tool_use_id` to name in the request, and only while it is in the foreground. A `Read`, an
    /// `Edit`, a `WebSearch` or any other plain call is not in the mirror and does not have a task
    /// kind that can be moved, so it never offers the action — which is the clause a card that
    /// offered the action on everything would get wrong without any other symptom.
    var offersMoveToBackground: Bool {
        guard !backgroundingUnavailable, !inFlight, let entry else { return false }
        guard entry.status == .running, entry.placement == .foreground, entry.toolUseID != nil else { return false }
        return Self.isBackgroundable(entry.kind)
    }

    /// The task kinds the engine can move to the background: a local shell, and an agent run.
    static func isBackgroundable(_ kind: TaskKind) -> Bool {
        switch kind {
        case .localBash, .localAgent, .remoteAgent, .inProcessTeammate: true
        default: false
        }
    }

    /// How long the run has been going, from the mirror's own clock: to its end when it has one, and
    /// to `now` while it is running.
    func elapsedText(at now: Date = Date()) -> String? {
        guard let entry else { return nil }
        let end = entry.endedAt ?? now
        let seconds = max(0, Int(end.timeIntervalSince(entry.startedAt).rounded()))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }

    // MARK: - The two control requests

    /// Per-task *Stop*: `stop_task {task_id}`, whose success body is `{}` (anchor 11).
    func stop() async {
        await send(AnyControlRequest(StopTask(taskID: item.taskID)))
    }

    /// *Move to background*: `background_tasks {tool_use_id}` → `{backgrounded: <bool>}`.
    ///
    /// `false` is a success body and refreshes the card with no banner. The disabled sentence is a
    /// control error and lands in the `catch`, where the banner is raised.
    func moveToBackground() async {
        guard let toolUseID = entry?.toolUseID else { return }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let reply = try await lifecycle.send(AnyControlRequest(BackgroundTasks(toolUseID: toolUseID)), on: channel)
            banner = nil
            guard reply["backgrounded"]?.boolValue == false else { return }
            // The entry the card was reading is stale or ineligible: the action goes, and the card
            // takes whatever the timeline now says the run is (§8.4, item 61's first arm).
            backgroundingUnavailable = true
            if let fresh = await refresh() { item = fresh }
        } catch {
            backgroundingUnavailable = true
            banner = Self.banner(for: error)
        }
    }

    private func send(_ request: AnyControlRequest) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            _ = try await lifecycle.send(request, on: channel)
            banner = nil
        } catch {
            banner = Self.banner(for: error)
        }
    }

    /// The engine's own sentence when it sent one, and the error's type when it did not. A type name
    /// carries no path, no id and no title (§6.3, §11).
    static func banner(for error: any Error) -> RowBanner {
        if case WireError.controlError(let reason) = error { return RowBanner(text: reason) }
        if let lifecycle = error as? LifecycleError { return RowBanner(lifecycle) }
        return RowBanner(text: "The request failed: \(type(of: error)).")
    }
}

/// One task run, drawn: what it is, how long it has been going, and the two things a user can do
/// with it. C6.1's `taskRun` row hosts this view and C6.4 mounts the same one on an Agents node
/// (spec D15, ruled).
struct TaskCardView: View {

    @State private var model: TaskCardModel

    init(model: TaskCardModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(model.item.description).font(.body.weight(.semibold))
                Text(TaskCardView.name(of: model.status)).font(.caption).foregroundStyle(.secondary)
                if let elapsed = model.elapsedText() {
                    Text(elapsed).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let summary = model.item.summary {
                Text(summary).font(.callout)
            }
            HStack(spacing: 8) {
                if model.offersStop {
                    Button("Stop") { Task { await model.stop() } }
                }
                if model.offersMoveToBackground {
                    Button("Move to background") { Task { await model.moveToBackground() } }
                }
            }
            if let banner = model.banner {
                Text(banner.text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func name(of status: TaskStatus) -> String {
        switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}
