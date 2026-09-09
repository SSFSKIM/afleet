import AppKit
import Darwin
import Foundation
import Synchronization
import TerminalCore
import XCTest

/// The house helpers for a pane test, written fresh: `TerminalCoreTests` is a test target and
/// cannot be imported, so what is shared with it is the style and not the code.
enum PaneTestChild {
    enum Failure: Error {
        case timedOut
        case surfaceNeverAttached
    }

    /// Every config home the engine may be using, derived from the values handed in. Pure, so the
    /// rule can be checked before a directory exists (spec §7.8, contract X9).
    static func configHomeRoots(homeDirectory: URL, environment: [String: String]) -> [URL] {
        var roots = [
            homeDirectory.appending(path: ".claude"),
            URL(filePath: "/tmp/afleet-fixtures/config-home"),
        ]
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            roots.append(URL(filePath: configured))
        }
        return roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    static func isForbidden(_ candidate: URL, roots: [URL]) -> Bool {
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        return roots.contains { candidate in
            resolved.path == candidate.path || resolved.path.hasPrefix(candidate.path + "/")
        }
    }

    /// A short directory under the system temporary root. Short on purpose: a pane test reads the
    /// child's `pwd` back off a rendered grid, and a path longer than the grid is wide comes back
    /// wrapped across two rows and no longer compares.
    static func temporaryDirectory() throws -> URL {
        let fileManager = FileManager.default
        let root = try canonicalURL(URL(filePath: "/tmp"))
            .appending(path: "afleet-pane-\(String(UUID().uuidString.prefix(8)).lowercased())")
        let forbidden = configHomeRoots(
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        // Checked before anything is created: a rule that is wrong must not leave a directory
        // inside a config home while it is being found out.
        guard !isForbidden(root, roots: forbidden) else {
            throw XCTSkip("temporary test root resolved inside a config home")
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A guard clause for a script meant to sit idle: nothing may outlive the test process.
    static func selfTerminating(after seconds: Int, _ script: String) -> String {
        "( sleep \(seconds); kill -KILL $$ ) &\n" + script
    }

    // MARK: The window

    /// A pane renders into a real window because the adapter holds every byte back until a view
    /// has attached a surface, and `renderedViewportText()` answers `nil` until then. The window
    /// is ordered back rather than made key: the test needs layout, not focus.
    @MainActor
    static func window(around view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderBack(nil)
        return window
    }

    /// Returns once the surface has a viewport to read, which is also when it has attached and
    /// reported its real grid. The bound is a watchdog on the harness and decides no assertion.
    @MainActor
    static func awaitAttachment(of surface: GhosttyTerminalSurface) async throws {
        try await waitUntil(seconds: 10, "surface-attachment") {
            surface.renderedViewportText() != nil
        }
    }

    // MARK: Waiting

    /// Polls `condition` until it holds. Every wait in this target is fulfilled by the thing it
    /// waits for; `seconds` is a watchdog that bounds the harness and decides no assertion.
    @MainActor
    static func waitUntil(
        seconds: Double,
        _ subject: String,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else {
            XCTFail("\(subject)=never")
            throw Failure.timedOut
        }
    }

    /// Runs `body` and reports whether it returned before the deadline.
    ///
    /// The loser of the race is abandoned rather than cancelled: the question this helper is
    /// asked — did `close()` return at all — is not one a cancellation could answer, and a task
    /// group would wait for the losing child anyway and turn the bound into no bound at all.
    static func completes(
        withinSeconds seconds: Double,
        _ body: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let isDelivered = Mutex(false)
            let deliver: @Sendable (Bool) -> Void = { didComplete in
                let isFirst = isDelivered.withLock { delivered -> Bool in
                    guard !delivered else { return false }
                    delivered = true
                    return true
                }
                guard isFirst else { return }
                continuation.resume(returning: didComplete)
            }
            Task.detached {
                await body()
                deliver(true)
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                deliver(false)
            }
        }
    }

    // MARK: The child, seen from outside

    /// A pid together with what tells it apart from whatever process comes to hold the number
    /// next: the kernel's own start time for it. A reaped pid is reusable at once, so a bare pid
    /// is not a thing a test may conclude anything from.
    struct ChildIdentity: Equatable, Sendable {
        let pid: pid_t
        let startedAtSeconds: Int64
        let startedAtMicroseconds: Int32
    }

    static func identity(ofChild pid: pid_t) -> ChildIdentity? {
        guard pid > 1, let information = processInformation(pid: pid) else { return nil }
        let startedAt = information.kp_proc.p_un.__p_starttime
        return ChildIdentity(
            pid: pid,
            startedAtSeconds: Int64(startedAt.tv_sec),
            startedAtMicroseconds: Int32(startedAt.tv_usec)
        )
    }

    /// The same process, and not yet a zombie: what a test means by "the child is still running".
    static func isRunning(_ identity: ChildIdentity) -> Bool {
        guard let information = processInformation(pid: identity.pid) else { return false }
        let startedAt = information.kp_proc.p_un.__p_starttime
        return Int64(startedAt.tv_sec) == identity.startedAtSeconds
            && Int32(startedAt.tv_usec) == identity.startedAtMicroseconds
            && information.kp_proc.p_stat != Int8(SZOMB)
    }

    private static func processInformation(pid: pid_t) -> kinfo_proc? {
        var information = kinfo_proc()
        var byteCount = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = name.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &information, &byteCount, nil, 0)
        }
        guard result == 0, byteCount != 0 else { return nil }
        return information
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard url.path.withCString({ realpath($0, &resolved) }) != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        let end = resolved.firstIndex(of: 0) ?? resolved.endIndex
        let bytes = resolved[..<end].map { UInt8(bitPattern: $0) }
        return URL(filePath: String(decoding: bytes, as: UTF8.self))
    }
}
