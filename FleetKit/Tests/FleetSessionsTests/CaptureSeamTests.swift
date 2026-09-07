import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetSessions

/// The seam behind Settings' *raw frame capture* (parent §11): what `Fleet` builds when no factory is injected is
/// the only thing that decides whether a spawned process captures at all, and `FleetVersion` and the tool list that
/// factory names are internal to this package, so no caller outside it can rebuild the factory to say so.
///
/// Nothing here spawns. Constructing a `ClaudeProcess` starts no child and touches no file, which is what lets the
/// argument it was handed be read straight off the process the factory returned.
final class CaptureSeamTests: XCTestCase {
    private var root: URL!
    private var home: ScratchConfigHome!
    private var cwd: URL!

    override func setUpWithError() throws {
        home = try ScratchConfigHome()
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appending(path: "afleet-capture-seam-\(UUID().uuidString)")
        cwd = base.appending(path: "afleet-capture-seam-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cwd)
        home.removeAll()
    }

    /// On and off in one run, through one factory: the provider is asked at every spawn rather than read once when
    /// the fleet is built, so a channel opened after the toggle changes is built the new way.
    func testTheDefaultFactoryHandsEverySpawnWhateverTheProviderAnswers() async throws {
        let capture = RawCapture(root: root, configHome: home.configHome)
        let box = ProviderBox(capture)
        let factory = Fleet.liveFactory(environment: environment, configHome: home.configHome,
                                        wireSink: NullDiagnostics(), capture: { box.value })

        let on = try XCTUnwrap(factory(.first, launch()) as? LiveProcessHandle,
                               "the default factory built something other than the live handle")
        let given = await on.process.capture
        XCTAssertTrue(given === capture, "the process was built with a capture the provider never gave")

        box.value = nil
        let off = try XCTUnwrap(factory(ProcessEpoch.first.next(), launch()) as? LiveProcessHandle)
        let afterOff = await off.process.capture
        XCTAssertNil(afterOff, "a spawn after the toggle went off was still given a capture")

        XCTAssertEqual(box.calls, 2, "the provider was not asked once per spawn")
    }

    /// The default is off, so a fleet built by a caller that says nothing about capture writes no frame to disk.
    func testTheFactoryCapturesNothingWhenNobodyAsksForIt() async throws {
        let factory = Fleet.liveFactory(environment: environment, configHome: home.configHome,
                                        wireSink: NullDiagnostics(), capture: { nil })
        let handle = try XCTUnwrap(factory(.first, launch()) as? LiveProcessHandle)
        let given = await handle.process.capture
        XCTAssertNil(given)
    }

    // MARK: - Support

    private var environment: ResolvedEnvironment {
        ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin", "HOME": cwd.path], shell: "/bin/zsh",
                            capturedAt: .init(), mode: .processFallback)
    }

    private func launch() -> LaunchConfiguration {
        LaunchConfiguration(binary: cwd.appending(path: "claude"), cwd: cwd, session: .new(SessionID()))
    }

    /// What the app's Developer toggle is on this side of the seam: a value the provider reads when it is asked,
    /// and a count of how often it was asked.
    private final class ProviderBox: @unchecked Sendable {   // `lock` serialises both fields
        private let lock = NSLock()
        private var stored: RawCapture?
        private var asked = 0

        init(_ capture: RawCapture?) { stored = capture }

        var value: RawCapture? {
            get { lock.lock(); defer { lock.unlock() }; asked += 1; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return asked }
    }
}
