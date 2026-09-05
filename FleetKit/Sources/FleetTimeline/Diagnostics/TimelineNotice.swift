import Foundation
import ClaudeWire

/// Everything this target reports about itself. Every case carries identifiers, counts and fixed vocabulary and
/// nothing else — no path, no title, no record byte (spec "Diagnostics (`Diagnostics/`)", parent §11). `LogicalStream`
/// is deliberately absent from every payload because it carries the config home path; the stream is named by its
/// `StreamName` instead. C2's `DiagnosticEvent` is a closed enum in a package below this one, so FleetKit owns its own
/// notice type and the app composes the two sinks.
public protocol TimelineDiagnosticsSink: Sendable {
    func record(_ notice: TimelineNotice)
}

public enum TimelineNotice: Sendable, Hashable {
    case mirrorErrorSwitchedToFileOnly(session: SessionID, stream: StreamName, epoch: ProcessEpoch)
    case mirrorGap(session: SessionID, stream: StreamName, missing: Int, epoch: ProcessEpoch)
    case mirrorRoutedElsewhere(session: SessionID, epoch: ProcessEpoch)
    case recordSkipped(session: SessionID, stream: StreamName, kind: String?, reason: SkipReason, byteOffset: Int)
    case unknownRecordKind(session: SessionID, kind: String)
    case orphanHealed(session: SessionID, stream: StreamName)
    case relocationFollowed(session: SessionID)
    case tapAligned(session: SessionID, stream: StreamName, claimed: Int, unclaimed: Int)
    case fileRewritten(session: SessionID, stream: StreamName, previousLength: Int, newLength: Int)
    /// `symlinkedProjectsSkipped` counts the slug entries under `projects/` that are symlinks. The build skips them
    /// because the engine's own lookup does, and reports how many so the app can surface the difference.
    case indexBuilt(files: Int, symlinkedProjectsSkipped: Int, durationMs: Int)
    case indexUpdated(changed: Int, durationMs: Int)

    public enum SkipReason: String, Sendable { case invalidJSON, tornTail, notAnObject }
}

/// The default sink: notices are computed and dropped.
public struct NullTimelineDiagnostics: TimelineDiagnosticsSink {
    public init() {}
    public func record(_ notice: TimelineNotice) {}
}

/// A sink that keeps every notice for a test to assert over.
///
/// `@unchecked Sendable` is sound here because the one mutable field is `notices`, and every read and every write of it
/// happens between `lock.lock()` and `lock.unlock()` of this instance's private `NSLock`. That lock is the serialising
/// mechanism: nothing else touches the array, and no reference to it escapes the locked region (the getter returns a
/// copy of the value type).
public final class RecordingTimelineDiagnostics: TimelineDiagnosticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimelineNotice] = []

    public init() {}

    public func record(_ notice: TimelineNotice) {
        lock.lock(); defer { lock.unlock() }
        storage.append(notice)
    }

    public var notices: [TimelineNotice] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
