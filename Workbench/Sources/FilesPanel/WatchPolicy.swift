// C7.5 spec Design §8: the conflict policy, as a pure function. The watcher decides nothing; it
// observes, and this decides. Keeping the decision here is what lets it be tested as a table with
// no file system in it, and what makes the plan's mutations meaningful.
import Foundation

/// What the session does about an observation of a watched file.
public enum WatchOutcome: Sendable, Equatable {
    /// Nothing happened that the buffer needs to know about.
    case ignore
    /// The file changed under a clean buffer: re-open it and restore the cursor.
    case refresh
    /// The file changed under a dirty buffer: raise the banner and let the user choose.
    case conflict
}

/// The rules, in order:
///
/// 1. `observed` carries the bytes of `lastWritten` → `.ignore`. **This is the save echo**, and it
///    is keyed on the digest rather than on a flag the save sets: one write produces no, one or
///    two vnode events depending on how it landed, and no flag has a clearing rule correct for
///    all three. A digest is right for all three without knowing which happened.
/// 2. `observed` carries the bytes of `lastLoaded` → `.ignore`: a touch, a metadata change, or a
///    write of identical bytes.
/// 3. Otherwise the file really differs from what the session knows: `.conflict` when the buffer
///    is dirty, `.refresh` when it is not.
///
/// A vanished file (`observed == nil`) carries no bytes, so it matches neither of the first two
/// rules and follows the third.
public func outcome(observed: FileSnapshot?,
                    lastLoaded: FileSnapshot,
                    lastWritten: FileSnapshot?,
                    isDirty: Bool) -> WatchOutcome {
    if let observed {
        if let lastWritten, observed.hasSameContents(as: lastWritten) { return .ignore }
        if observed.hasSameContents(as: lastLoaded) { return .ignore }
    }
    return isDirty ? .conflict : .refresh
}
