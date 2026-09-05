import Foundation
import AfleetCore
import ClaudeWire

/// One row of the Activity view: what happened, on which channel, and — where the transcript has one — which item
/// it links to.
public struct ActivityRow: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A decision the engine is waiting on. Answering it from Activity goes through the same `answer` path as
        /// the channel does.
        case decision(RequestID)
        case notification
        case failedResult
        case permissionDenied
        case rateLimitRefused
        /// A rate-limit report that refused nothing: a window's status, for the banner.
        case rateLimitInfo
        case authProblem
        case agentRunning(String)
        case agentFailed(String)
        /// The one item afleet writes itself: a crash, a ghost, or a fork whose engine never said which session it
        /// was. Carried whole so a new `SystemItem` case cannot be added without an arm here.
        case systemItem(SystemItem)
    }

    public var key: ChannelKey
    public var kind: Kind
    /// The transcript item this row links to, where one exists. A pending decision and a mirror entry have none.
    public var itemUUID: String?
    /// One short, structural word or the engine's own text: a subtype, a tool name, a task id, a status.
    public var text: String

    public init(key: ChannelKey, kind: Kind, itemUUID: String? = nil, text: String) {
        self.key = key; self.kind = kind; self.itemUUID = itemUUID; self.text = text
    }
}

/// The parent's Activity categories as one pure function over what the fleet already holds. It reads nothing and
/// asks nobody: the states are `LifecycleAPI.states()`, the mirror is C3's, and the frames are the recent window
/// each channel keeps.
public enum ActivityQuery {

    /// Rows in channel order, and within a channel: the pending decisions in ask order, then the frame-derived rows
    /// in frame order, then the running agents, then the channel's system item.
    public static func rows(states: [ChannelState],
                            mirrors: [ChannelKey: [any TaskMirrorReading]],
                            recent: [ChannelKey: [Frame]]) -> [ActivityRow] {
        var rows: [ActivityRow] = []
        for state in states {
            let key = state.key
            for decision in state.pendingDecisions {
                rows.append(ActivityRow(key: key, kind: .decision(decision.id), text: decision.subtype))
            }
            rows.append(contentsOf: frameRows(key: key, frames: recent[key] ?? []))
            for entry in mirrors[key] ?? [] where entry.isRunning {
                rows.append(ActivityRow(key: key, kind: .agentRunning(entry.taskID), text: entry.taskID))
            }
            if let item = state.systemItem {
                rows.append(ActivityRow(key: key, kind: .systemItem(item), text: word(for: item)))
            }
        }
        return rows
    }

    /// Every `SystemItem`, named. Exhaustive on purpose: a new case is a new row, and the compiler is what says so.
    private static func word(for item: SystemItem) -> String {
        switch item {
        case .crashed: "crashed"
        case .wedged: "wedged"
        case .forkIdentityTimedOut: "forkIdentityTimedOut"
        }
    }

    private static func frameRows(key: ChannelKey, frames: [Frame]) -> [ActivityRow] {
        var rows: [ActivityRow] = []
        for frame in frames {
            switch frame {
            case .result(let result):
                if result.isError {
                    rows.append(ActivityRow(key: key, kind: .failedResult, itemUUID: result.uuid,
                                            text: result.subtype))
                }
                for denial in result.permissionDenials?.arrayValue ?? [] {
                    rows.append(ActivityRow(key: key, kind: .permissionDenied, itemUUID: result.uuid,
                                            text: denial["tool_name"]?.stringValue ?? ""))
                }

            case .user(let user):
                // The spec's failed-result category is two things: a `result` frame's error subtypes, above, and
                // the `is_error` tool results the engine echoes on a user frame. A tool that failed is a failure
                // the user has to see whether or not the turn as a whole ended in one.
                guard case .blocks(let blocks) = user.message.content else { break }
                for block in blocks {
                    guard case .toolResult(let toolResult) = block, toolResult.isError == true else { continue }
                    rows.append(ActivityRow(key: key, kind: .failedResult, itemUUID: user.uuid,
                                            text: toolResult.toolUseID))
                }

            case .system(.permissionDenied(let denied)):
                rows.append(ActivityRow(key: key, kind: .permissionDenied, itemUUID: denied.uuid,
                                        text: denied.toolName))

            case .system(.notification(let note)):
                rows.append(ActivityRow(key: key, kind: .notification, itemUUID: note.uuid, text: note.text))

            case .system(.taskNotification(let notification)):
                // `completed | failed | stopped` (bundle 2.1.258, the one `task_notification` emitter). Only the
                // failure is an Activity row; a completion is the timeline's.
                guard notification.status == "failed" else { break }
                rows.append(ActivityRow(key: key, kind: .agentFailed(notification.taskID),
                                        itemUUID: notification.uuid, text: notification.taskID))

            case .rateLimitEvent(let event):
                // `status` alone decides. `overageStatus: "rejected"` with `org_level_disabled` is the
                // organisation declining to buy overage, not the engine refusing the user's turn, and rendering it
                // as a refusal would say the user had been cut off when they had not.
                let status = event.rateLimitInfo["status"]?.stringValue ?? ""
                rows.append(ActivityRow(key: key, kind: status == "rejected" ? .rateLimitRefused : .rateLimitInfo,
                                        itemUUID: event.uuid, text: status))

            case .authStatus(let status):
                if let error = status.error {
                    rows.append(ActivityRow(key: key, kind: .authProblem, itemUUID: status.uuid, text: error))
                } else {
                    // A healthy report is the answer to every earlier complaint on this channel: the problem the
                    // rows describe is over, and leaving them up would ask the user to fix what is already fixed.
                    rows.removeAll { $0.kind == .authProblem }
                }

            default:
                break
            }
        }
        return rows
    }
}
