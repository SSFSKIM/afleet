import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
import Workbench
@testable import Afleet

/// C7.6 M6: the app's half of the Browser panel — the tab and its two link targets registered once,
/// the Developer *Web inspector* setting, and the decode the new field forces.
///
/// Every identifier here is invented: a session is a hex-formatted index, a config home and a
/// working directory are fixed invented paths, and every URL is loopback on a port nothing serves.
/// Nothing reaches the network and nothing reads `~/.claude` or `$CLAUDE_CONFIG_DIR` (§11, X9).
@MainActor
final class BrowserWiringTests: XCTestCase {

    // MARK: - Registration (Q4)

    /// The tab the app registers in its initialiser is the one the host offers a channel.
    ///
    /// Both halves matter and neither implies the other: `isRegistered` says an id is taken, and
    /// `available(for:)` is what the panel column draws, which additionally asks the tab whether it
    /// can render this channel. A Browser registered but unavailable would be a tab no window ever
    /// shows.
    func testTheBrowserTabIsRegisteredAndAvailableForAChannel() throws {
        let app = AppModel()

        XCTAssertTrue(app.panels.isRegistered(.browser), "no tab holds .browser after the app was built")
        XCTAssertTrue(app.panels.available(for: BrowserWiringFixtures.context()).contains(.browser),
                      "the host does not offer .browser to a channel")
        XCTAssertEqual(app.panels.title(for: .browser), PanelTabID.browser.defaultTitle,
                       "the registered tab is not the Browser's own")
    }

    // MARK: - Routing (G2's delivery half)

    /// A `.url` opened at `.currentPanel` through the app's own routing seam lands in the Browser.
    ///
    /// Asserted on what the panel *shows* — the tab set gained the page and the host moved its
    /// selection to the Browser — rather than on a recorder wired into the target, because a
    /// recorder would prove the test registered something and not that the app did. With no target
    /// registered, W5's fallback would hand the URL to the system browser and both assertions below
    /// would fail, which is the regression this exists for.
    func testAURLOpenedAtTheCurrentPanelReachesTheBrowserTab() async throws {
        let app = AppModel()
        await app.registerBrowserLinkTargets()
        app.panels.select(.thread)
        let url = BrowserWiringFixtures.url

        await app.panels.links.open(.url(url), from: .currentPanel)

        XCTAssertEqual(app.browserTab.model.selected?.url, url,
                       "the Browser's selected tab is not on the page the link named")
        XCTAssertEqual(app.panels.selected, .browser,
                       "the link did not bring the Browser tab into view")
    }

    /// Registering twice registers once. `launch()` runs again on *Check again*, and a second pass
    /// that added the two targets a second time would leave the registry with duplicates tying on
    /// specificity for every link the Browser claims.
    func testRegisteringTheLinkTargetsTwiceRegistersThemOnce() async throws {
        let app = AppModel()
        let base = try await settledTargetCount(app)
        await app.registerBrowserLinkTargets()
        let after = await app.panels.links.targetCount

        await app.registerBrowserLinkTargets()

        let again = await app.panels.links.targetCount
        XCTAssertEqual(after - base, 2,
                       "the Browser registered \(after - base) targets, not the .url and .pullRequest pair")
        XCTAssertEqual(again, after, "a second registration added \(again - after) more targets")
    }

    /// The app's registry is shared, and C7.5's Files tab and C7.7's Source Control tab each claim
    /// their targets from a `Task` spawned in `AppModel.init` — so a count read at an arbitrary
    /// moment is a race between three children. Waiting for all of them to land is what makes the
    /// Browser's two a *delta*. **Three since C7.7**: the Files pair plus one `.commit`. A count,
    /// never a target (§11).
    private func settledTargetCount(_ app: AppModel,
                                    file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
        let deadline = ContinuousClock().now + .seconds(10)
        while ContinuousClock().now < deadline {
            let count = await app.panels.links.targetCount
            if count >= 3 { return count }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the tabs registered in the initialiser never registered their link targets",
                file: file, line: line)
        return 0
    }

    /// The launch is what registers them, and it does so on a launch that reaches no workspace.
    ///
    /// `PanelHost.register` is synchronous and `LinkRouterCapability.register` is not, so the tab
    /// and its targets cannot both be taken in the initialiser; the targets are awaited at the top
    /// of the launch instead. That placement is the guarantee — it is strictly before the first
    /// `ChannelContext`, which is the only thing a `WorkspaceLink` can be opened through — and this
    /// is what would fail if a later edit moved the call under a workspace or dropped it.
    func testTheLaunchRegistersTheBrowsersLinkTargets() async throws {
        let temp = try TempTree()
        let configHome = try temp.directory("home")
        let sequence = LaunchSequence(
            storeRoot: temp.root.appending(path: "store", directoryHint: .isDirectory),
            diagnosticsRoot: temp.root.appending(path: "logs", directoryHint: .isDirectory),
            resolveEnvironment: { LaunchFixtures.environment(home: temp.root, configHome: configHome) },
            locateBinary: { _, _ in nil })
        let app = AppModel(sequence: sequence)
        let before = try await settledTargetCount(app)

        await app.launch()

        let after = await app.panels.links.targetCount
        XCTAssertEqual(before, 3,
                       "\(before) targets were registered before the launch, not the initialiser's three")
        XCTAssertEqual(after - before, 2,
                       "the launch added \(after - before) targets, not the Browser's two")
        XCTAssertNil(app.route.workspace,
                     "this launch is meant to reach no workspace, so a registration under one proves less")
    }

    /// **The channel a `.pullRequest` is resolved against is the one the click came from** (A5).
    ///
    /// Routing suspends on the way to the registry and again on the way back, and the main actor is
    /// free throughout — so a window that moves to another channel while a link is in flight would,
    /// with a provider that read the *current* selection when resolution begins, have channel A's
    /// pull-request number resolved against channel B's repository. The working directory `git` was
    /// asked to run in is the only thing that can tell the two apart, and it is a count-free,
    /// invented path (§11).
    func testAPullRequestResolvesAgainstTheChannelTheClickCameFrom() async throws {
        let rig = try WorkspaceRig()
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)
        let clicked = BrowserWiringFixtures.key(1)
        let movedTo = BrowserWiringFixtures.key(2)
        XCTAssertNotNil(app.panels.context(for: clicked, cwd: BrowserWiringFixtures.clickedCwd),
                        "the host could not build a context for the channel the click comes from")
        XCTAssertNotNil(app.panels.context(for: movedTo, cwd: BrowserWiringFixtures.movedToCwd),
                        "the host could not build a context for the channel the window moves to")
        app.panels.focusChannel(clicked)

        let runner = RecordingToolRunner()
        for target in BrowserWiring.makeLinkTargets(model: app.browserTab.model,
                                                    panels: app.panels,
                                                    runner: runner) {
            await app.panels.links.register(target)
        }

        // The race is driven, not hoped for. A yield is a request to the scheduler and proves
        // nothing about where the delivery got to: it could pass with the resolver having read its
        // context before the window ever moved, which is the case this test exists for (§17.7).
        // The barrier fires inside the routed call, once the origin has been captured and before
        // anything reads it, and holds the delivery there until this test lets it go.
        let barrier = RoutingBarrier()
        let captured = expectation(description: "the routed call captured the channel it came from")
        await barrier.expect(captured)
        app.panels.links.didCaptureOrigin = { await barrier.wait() }

        let delivery = Task { await app.panels.links.open(.pullRequest(7), from: .currentPanel) }
        await fulfillment(of: [captured], timeout: 5)
        XCTAssertTrue(runner.directories.isEmpty,
                      "the resolver read its context before the origin was captured, so the "
                      + "window moving below would not be a race at all")

        app.panels.focusChannel(movedTo)
        await barrier.release()
        await delivery.value

        XCTAssertEqual(runner.directories, [BrowserWiringFixtures.clickedCwd],
                       "the lookup ran in a directory the click did not come from")
    }

    // MARK: - Persistence (G3's app half, W6)

    /// The tab set the panel holds reaches the workspace's own store, under W6's key in the
    /// `workbench` namespace.
    ///
    /// The Browser tab is built in `AppModel.init`, before any launch has a store, so what it
    /// persists through is bound later — and this is the assertion that the binding happens. It
    /// reads back through `StateStore` directly rather than through the panel, so what is asserted
    /// is the document on the workspace's own store and not the panel's memory of it.
    func testTheBrowsersTabSetReachesTheWorkspaceStore() async throws {
        let rig = try WorkspaceRig()
        let app = AppModel()
        app.bindWorkspace(rig.workspace, lifecycle: rig.lifecycle)

        app.browserTab.model.openNewTab(url: BrowserWiringFixtures.url)
        await app.browserTab.model.flush()

        let document = try await rig.workspace.store.read(BrowserTabSetDocument.self,
                                                         namespace: .workbench,
                                                         key: BrowserTabStore.storeKey)
        let persisted = try XCTUnwrap(document, "nothing was written under the Browser's store key")
        XCTAssertEqual(persisted.tabs.map(\.url), [BrowserWiringFixtures.url],
                       "the persisted set is not the one tab the panel opened")
    }

    // MARK: - The Developer setting (Q15)

    /// A settings document written by a build that had no `webInspector` still decodes, with the
    /// four fields it did write intact.
    ///
    /// This is the trap the field forces: `DeveloperSettings` had a synthesised `Decodable`, under
    /// which a new non-optional field makes every earlier document fail to decode — and
    /// `AfleetSettingsStore.read` answers a decode failure with the defaults, so the user's binary
    /// override, capture switch and watcher switch would all silently revert on the first launch of
    /// the new build.
    func testASettingsDocumentWrittenBeforeTheWebInspectorFieldStillDecodes() throws {
        let document = Data("""
        {"developer":{"binaryPathOverride":"/invented/bin/claude","rawFrameCapture":true,\
        "transcriptWatcherStopped":true,"isolatedSettingsForNewChannels":true},\
        "notifications":{"permissionRequests":false,"turnCompleted":true,"channelFailed":false}}
        """.utf8)

        let settings = try JSONDecoder().decode(AfleetSettings.self, from: document)

        XCTAssertEqual(settings.developer.binaryPathOverride, "/invented/bin/claude",
                       "the binary override did not survive the decode")
        XCTAssertTrue(settings.developer.rawFrameCapture, "rawFrameCapture did not survive the decode")
        XCTAssertTrue(settings.developer.transcriptWatcherStopped,
                      "transcriptWatcherStopped did not survive the decode")
        XCTAssertTrue(settings.developer.isolatedSettingsForNewChannels,
                      "isolatedSettingsForNewChannels did not survive the decode")
        XCTAssertFalse(settings.developer.webInspector,
                       "a document that never named the web inspector decoded as having it on")
    }

    /// The toggle round-trips: what Settings writes is what the next launch reads.
    func testTheWebInspectorToggleRoundTripsThroughTheStore() async throws {
        let store = JSONMemoryStore()
        var settings = await AfleetSettingsStore.read(from: store)
        XCTAssertFalse(settings.developer.webInspector, "an empty store did not read as the closed default")

        settings.developer.webInspector = true
        try await AfleetSettingsStore.write(settings, to: store)

        let read = await AfleetSettingsStore.read(from: store)
        XCTAssertTrue(read.developer.webInspector, "the toggle did not survive a write and a read")
        XCTAssertEqual(read, settings, "the document that came back is not the one that went in")
    }
}

// MARK: - Values and doubles

/// Invented throughout (§11): a hex-formatted session index, a fixed invented config home and
/// working directory, and a loopback URL on a port nothing serves — so a regression that sent it to
/// the system browser or to a real load would still reach nothing.
private enum BrowserWiringFixtures {

    static let configHome = URL(fileURLWithPath: "/invented/config-home")
    static let cwd = URL(fileURLWithPath: "/invented/project")
    static let clickedCwd = URL(fileURLWithPath: "/invented/project-clicked")
    static let movedToCwd = URL(fileURLWithPath: "/invented/project-moved-to")
    static let url = URL(string: "http://127.0.0.1:1/invented-page")!

    static func key(_ index: Int = 0) -> ChannelKey {
        ChannelKey(configHome: configHome,
                   session: SessionID(String(format: "%08x-0000-4000-8000-%012x", index, index))!)
    }

    static func context(_ key: ChannelKey = BrowserWiringFixtures.key()) -> ChannelContext {
        ChannelContext(key: key,
                       session: key.session,
                       cwd: cwd,
                       environment: ResolvedEnvironment(variables: ["PATH": "/usr/bin"],
                                                        shell: "/bin/zsh", capturedAt: Date(), mode: .login),
                       store: NullScopedStore(),
                       links: NullLinkRouter(),
                       recentURLs: NullRecentURLFeed(),
                       reportPaneExit: { _ in })
    }
}

/// A workspace over a scratch config home, built by hand.
///
/// Built rather than launched because what is under test is one binding: a `LaunchSequence` would
/// add a binary probe, a version gate and a sign-in gate, each of which can fail for reasons that
/// say nothing about where the Browser's document goes. The store is the real `FileStateStore`, so
/// the document asserted on is one that was encoded and written to disk.
@MainActor
private struct WorkspaceRig {

    let temp: TempTree
    let workspace: Workspace
    let lifecycle: LifecycleDouble

    init() throws {
        temp = try TempTree()
        let home = try ScratchConfigHome(tree: temp)
        lifecycle = LifecycleDouble()
        workspace = Workspace(
            configHome: home.configHome,
            environment: LaunchFixtures.environment(home: temp.root, configHome: home.root),
            binary: try temp.file("bin/claude", "#!/bin/sh\nexit 0\n"),
            installed: SemanticVersion(major: 2, minor: 1, patch: 263),
            store: try FileStateStore(baseDirectory: temp.root.appending(path: "store", directoryHint: .isDirectory),
                                      configHomes: [home.root]),
            index: TranscriptIndex(configHome: home.configHome, storage: InMemoryIndexStorage()),
            fleet: StubFleet(),
            watcher: nil,
            changes: nil,
            diagnostics: DiagnosticsComposer(directory: temp.root.appending(path: "logs",
                                                                            directoryHint: .isDirectory)),
            rawCapture: nil)
    }
}

/// A store that keeps the encoded bytes, so a round trip through it is a round trip through the
/// coder — which is the half of the settings document under test.
private actor JSONMemoryStore: StateStore {
    private var documents: [String: Data] = [:]

    private func slot(_ namespace: StoreNamespace, _ key: String) -> String { "\(namespace.rawValue)/\(key)" }

    func read<T: Codable & Sendable>(_ type: T.Type, namespace: StoreNamespace, key: String) async throws -> T? {
        guard let data = documents[slot(namespace, key)] else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func write<T: Codable & Sendable>(_ value: T, namespace: StoreNamespace, key: String) async throws {
        documents[slot(namespace, key)] = try JSONEncoder().encode(value)
    }

    func remove(namespace: StoreNamespace, key: String) async throws {
        documents[slot(namespace, key)] = nil
    }

    func keys(in namespace: StoreNamespace) async throws -> [String] {
        let prefix = "\(namespace.rawValue)/"
        return documents.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    func appendUnique(_ element: String, namespace: StoreNamespace, key: String) async throws {
        var current = (try await read([String].self, namespace: namespace, key: key)) ?? []
        guard !current.contains(element) else { return }
        current.append(element)
        try await write(current, namespace: namespace, key: key)
    }
}

private struct NullScopedStore: ScopedStore {
    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? { nil }
    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {}
    func remove(key: String) async throws {}
    func keys() async throws -> [String] { [] }
}

private struct NullLinkRouter: LinkRouterCapability {
    func register(_ target: LinkTarget) async {}
    func unregister(tab: PanelTabID) async {}
    func open(_ link: WorkspaceLink, from destination: LinkDestination) async {}
}

private struct NullRecentURLFeed: RecentURLFeed {
    func current(limit: Int) async -> [SeenURL] { [] }
    var updates: AsyncStream<[SeenURL]> { AsyncStream { $0.finish() } }
}

/// A `ToolRunning` that runs nothing and records the directory it was asked to run in.
///
/// It answers the one command the route reaches — `git rev-parse --show-toplevel` — with a failure,
/// because what is under test is *which repository was asked about* and a resolver that got that far
/// has already read its channel. The row that failure produces is the panel's own (§10).
private final class RecordingToolRunner: ToolRunning, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: [URL] = []

    var directories: [URL] { lock.lock(); defer { lock.unlock() }; return stored }

    func run(_ tool: Tool, arguments: [String], cwd: URL, environment: [String: String],
             timeout: Duration) async throws -> ToolOutput {
        record(cwd)
        return ToolOutput(stdout: Data(), stderr: Data("fatal: not a git repository\n".utf8),
                          exitCode: 128, timedOut: false)
    }

    private func record(_ cwd: URL) {
        lock.lock(); defer { lock.unlock() }
        stored.append(cwd)
    }
}

/// The barrier that test suspends the routed call at: it reports that the call has reached the
/// point being asserted about, and holds it there until the test has changed the world under it.
actor RoutingBarrier {

    private var arrival: XCTestExpectation?
    private var held: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func expect(_ expectation: XCTestExpectation) { arrival = expectation }

    func wait() async {
        arrival?.fulfill()
        arrival = nil
        guard !isReleased else { return }
        await withCheckedContinuation { held = $0 }
    }

    func release() {
        isReleased = true
        held?.resume()
        held = nil
    }
}
