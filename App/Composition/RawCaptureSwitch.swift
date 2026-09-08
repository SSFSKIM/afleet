import Foundation
import ClaudeWire
import AfleetCore

/// Settings' Developer toggle *Capture raw frames*, as the thing a spawn can ask (parent §11).
///
/// C2 owns the capture itself — the hashed directory under `<diagnostics root>/capture`, the redaction that runs
/// before any byte reaches disk, the 0700/0600 modes and the 200 MB budget. This owns only the answer to "is it on
/// right now", because the seam FleetKit exposes is synchronous: `Fleet`'s default process factory asks at every
/// spawn, and a spawn cannot await the store. So the persisted setting is mirrored here — written by the launch that
/// read it and by Settings when the user changes it — and read from whichever thread is opening a channel.
///
/// One `RawCapture` for the life of the launch rather than one per spawn: the budget, the open handles and the
/// per-session redaction correlations are all directory-wide state, and two instances over one directory would each
/// enforce the budget against files the other is still writing. Constructing it touches no file; the first write
/// creates the tree.
///
/// `@unchecked Sendable` is sound because the one mutable field is read and written only inside `lock`.
final class RawCaptureSwitch: @unchecked Sendable {
    /// The capture this hands out while the toggle is on. §11's tree is `<diagnostics root>/capture`, and
    /// `RawCapture` puts the config-home hash below it.
    let capture: RawCapture
    private let lock = NSLock()
    private var enabled: Bool

    init(diagnosticsRoot: URL, configHome: ConfigHome, enabled: Bool) {
        capture = RawCapture(root: RawCaptureSwitch.captureRoot(under: diagnosticsRoot), configHome: configHome)
        self.enabled = enabled
    }

    /// The capture tree under a diagnostics directory. Named here because *Delete diagnostics* removes it and the
    /// launch declares it to X9's write seam, and neither should spell the directory itself.
    static func captureRoot(under diagnosticsRoot: URL) -> URL {
        diagnosticsRoot.appending(path: "capture", directoryHint: .isDirectory)
    }

    /// What Settings writes when the user moves the toggle. The next channel opened captures, or stops capturing;
    /// the ones already running keep the answer they were spawned with, because a `ClaudeProcess` is handed its
    /// capture once.
    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }

    /// The seam `Fleet.init(capture:)` takes: asked once per spawn, on whatever thread is spawning.
    var provider: @Sendable () -> RawCapture? {
        { [self] in isOn ? capture : nil }
    }
}
