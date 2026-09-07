import Foundation
import SwiftUI
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
import PanelHostAPI
@testable import Afleet

/// Task 8: contract X7's host, its channel context and the placeholder tab (spec §7, gate G4).
///
/// Every scratch tree here is a `TempTree`, which refuses to build inside any config home, and
/// every identifier below is invented — a session is a hex-formatted index, a URL is under
/// `invented.example`, a working directory is `/invented/project`. No engine byte reaches a
/// committed file and no assertion compares one (§11).
///
/// Where an assertion would otherwise print a value carrying a config-home path, a session id or a
/// title, it is spelled as a boolean with a message this file wrote: `XCTAssertEqual` prints both
/// operands into the failure output, and that output is what a report quotes.
@MainActor
final class PanelHostTests: XCTestCase {

    // MARK: - G4a: registration and order

    /// The canonical order is the tab set's, not the registration order.
    func testTabsPresentInCanonicalOrderWhateverTheRegistrationOrder() throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.github))
        try host.register(StubPanelTab(.files))
        try host.register(StubPanelTab(.thread))

        XCTAssertEqual(host.available(for: PanelFixtures.context()), [.thread, .files, .github],
                       "the host presented its three registered tabs out of canonical order")
    }

    /// A second registration of one id is refused rather than shadowing the first.
    func testASecondRegistrationOfOneIDThrows() throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.files))

        XCTAssertThrowsError(try host.register(StubPanelTab(.files))) { error in
            XCTAssertEqual(error as? PanelHostError, .duplicateTab(.files),
                           "a duplicate registration threw the wrong error")
        }
        XCTAssertEqual(host.available(for: PanelFixtures.context()), [.files],
                       "the refused registration changed what the host presents")
    }

    /// The handover C6 takes: `unregister(.thread)` and then its own `register`.
    ///
    /// Both halves matter. Without the refusal, a second registration would silently shadow the
    /// first; without the handover, the duplicate check would make the seven ids permanently
    /// first-come and C6 could never register Thread over C5's placeholder.
    func testUnregisterThenRegisterHandsTheIDOver() async throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.thread, title: "C5's placeholder"))
        let successor = StubPanelTab(.thread, title: "a later child's thread")

        XCTAssertThrowsError(try host.register(successor),
                             "registering over the placeholder without unregistering it succeeded")

        await host.unregister(.thread)
        try host.register(successor)

        XCTAssertEqual(host.available(for: PanelFixtures.context()), [.thread],
                       "the successor is not the tab the host presents for .thread")
        XCTAssertEqual(host.title(for: .thread), "a later child's thread",
                       "the host reports the placeholder's title after the handover")
    }

    /// Cmd+1…7 is one-based over `available(for:)`, and an index outside it changes nothing.
    func testSelectIndexIsOneBasedOverAvailable() throws {
        let host = PanelHostModel()
        try host.register(StubPanelTab(.files))
        try host.register(StubPanelTab(.terminal))
        let context = PanelFixtures.context()

        host.selectIndex(3, in: context)
        XCTAssertNil(host.selected, "an out-of-range index selected a tab")

        host.selectIndex(1, in: context)
        XCTAssertEqual(host.selected, .files, "Cmd+1 did not select the first available tab")

        host.selectIndex(2, in: context)
        XCTAssertEqual(host.selected, .terminal, "Cmd+2 did not select the second available tab")

        host.selectIndex(3, in: context)
        XCTAssertEqual(host.selected, .terminal, "an out-of-range index moved the selection")
    }

    /// A tab that reports itself unavailable is absent for that channel and present for another.
    ///
    /// Both directions, so a tab that reported unavailable everywhere — or a host that ignored
    /// `isAvailable(in:)` — fails.
    func testAnUnavailableTabIsAbsentForThatChannelAndPresentForAnother() throws {
        let host = PanelHostModel()
        let welcome = PanelFixtures.key(0)
        try host.register(StubPanelTab(.files, availableIn: [welcome]))
        try host.register(StubPanelTab(.terminal))

        XCTAssertEqual(host.available(for: PanelFixtures.context(welcome)), [.files, .terminal],
                       "the tab is absent for the channel it reported itself available for")
        XCTAssertEqual(host.available(for: PanelFixtures.context(PanelFixtures.key(1))), [.terminal],
                       "the tab is present for a channel it reported itself unavailable for")
    }

    // MARK: - The session cache

    // MARK: - G4c: the popped-out window keeps its channel

    // MARK: - G4b: the context's capabilities

    // MARK: - Link routing

    // MARK: - G4d: the pane seam

}

// MARK: - Doubles

/// A tab whose availability, title and session accounting the test controls.
@MainActor
private final class StubPanelTab: PanelTab {
    let id: PanelTabID
    let title: String
    let systemImage: String
    /// Nil means available for every channel.
    private let availableIn: Set<ChannelKey>?
    private let counter: SessionCounter?

    init(_ id: PanelTabID, title: String? = nil, availableIn: Set<ChannelKey>? = nil,
         counter: SessionCounter? = nil) {
        self.id = id
        self.title = title ?? id.defaultTitle
        self.systemImage = id.defaultSystemImage
        self.availableIn = availableIn
        self.counter = counter
    }

    func isAvailable(in context: ChannelContext) -> Bool {
        availableIn.map { $0.contains(context.key) } ?? true
    }

    func makeSession(for context: ChannelContext) -> any PanelTabSession {
        counter?.made()
        return CountedSession(counter: counter)
    }

    func makeView(session: any PanelTabSession, context: ChannelContext) -> AnyView {
        AnyView(Text(verbatim: "a stub tab"))
    }
}

/// A session that says when it is made and when it goes.
@MainActor
private final class CountedSession: PanelTabSession {
    private let counter: SessionCounter?
    init(counter: SessionCounter?) { self.counter = counter }
    deinit { counter?.wentAway() }
}

/// The creation and release counts a stateful tab's sessions report.
///
/// `@unchecked Sendable` is sound because both mutable fields are read and written only inside
/// `lock`, this instance's private `NSLock`. A `deinit` is not isolated to any actor, so the
/// counter cannot live on one.
private final class SessionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0
    private var releases = 0

    var created: Int { lock.lock(); defer { lock.unlock() }; return creations }
    var released: Int { lock.lock(); defer { lock.unlock() }; return releases }

    func made() { lock.lock(); creations += 1; lock.unlock() }
    func wentAway() { lock.lock(); releases += 1; lock.unlock() }
}

// MARK: - Values

/// Every identifier these tests use. Invented throughout: a session is a hex-formatted index, a
/// config home is a fixed invented path, a URL is under `invented.example` (§11).
private enum PanelFixtures {

    static let configHome = URL(fileURLWithPath: "/invented/config-home")
    static let cwd = URL(fileURLWithPath: "/invented/project")

    /// A v4-shaped session id from an index, so twenty distinct channels read as twenty numbers.
    static func session(_ index: Int) -> SessionID {
        SessionID(String(format: "%08x-0000-4000-8000-%012x", index, index))!
    }

    static func key(_ index: Int, configHome: URL = PanelFixtures.configHome) -> ChannelKey {
        ChannelKey(configHome: configHome, session: session(index))
    }

    static func url(_ index: Int) -> URL {
        URL(string: "https://invented.example/page-\(index)")!
    }

    static let fileLink = WorkspaceLink.file(URL(fileURLWithPath: "/invented/project/file.swift"), line: nil)

    /// A context over stub capabilities, for the tests that are about the host and not about what
    /// the capabilities do.
    static func context(_ key: ChannelKey = PanelFixtures.key(0)) -> ChannelContext {
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

/// Capabilities that answer and do nothing, for a context built to exercise the host.
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

// MARK: - Rigs
