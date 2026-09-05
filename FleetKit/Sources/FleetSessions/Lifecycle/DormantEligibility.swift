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
