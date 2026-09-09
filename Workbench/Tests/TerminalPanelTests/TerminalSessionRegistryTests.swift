import AfleetCore
import FleetKit
import Foundation
import PanelHostAPI
import TerminalCore
@testable import TerminalPanel
import XCTest

/// The registry's retention rule: a session lives while it has a pane, and not otherwise. Growth
/// is bounded by live panes — the real resource — rather than by channels ever visited, and the
/// host's LRU evicting a channel does not kill a user's running shell.
@MainActor
final class TerminalSessionRegistryTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { PaneTestChild.remove(directory) }
        directories = []
        try await super.tearDown()
    }

    private func fixture() throws -> PaneTestContext.Fixture {
        let directory = try PaneTestChild.temporaryDirectory()
        directories.append(directory)
        return PaneTestContext.fixture(session: SessionID(), cwd: directory)
    }

    func testTheSameChannelGetsTheSameSessionWhileItIsHeld() throws {
        let registry = TerminalSessionRegistry()
        let fixture = try fixture()

        let first = registry.session(for: fixture.context)
        let second = registry.session(for: fixture.context)

        XCTAssertTrue(first === second, "the host and the runner would hold two different sessions")
    }

    func testASessionWithALivePaneSurvivesItsOwnerReleasingIt() async throws {
        let registry = TerminalSessionRegistry()
        let fixture = try fixture()
        weak var observed: TerminalPanelSession?

        func openAndRelease() {
            let session = registry.session(for: fixture.context)
            observed = session
            session.openShellPane()
        }
        openAndRelease()
        await Task.yield()

        XCTAssertNotNil(observed, "the registry let a session with a running shell be deallocated")

        if let survivor = observed {
            for pane in survivor.panes { await survivor.close(pane) }
        }
    }

    func testASessionWithNoPanesDoesNotSurviveItsOwnerReleasingIt() async throws {
        let registry = TerminalSessionRegistry()
        let fixture = try fixture()
        weak var observed: TerminalPanelSession?

        func makeAndRelease() {
            observed = registry.session(for: fixture.context)
        }
        makeAndRelease()
        await Task.yield()

        XCTAssertNil(observed, "the registry grew by a channel that owns nothing")
    }

    /// A workspace goes away and its contexts go with it: the store a session writes through and
    /// the `reportPaneExit` it reports to both name a lifecycle nobody is listening to any more.
    /// Handing that session back for the same channel would put a new pane in the dead one, so an
    /// ask carrying a context the session was not made from replaces it.
    func testASessionMadeFromAnotherContextIsReplacedRatherThanHandedBack() async throws {
        let registry = TerminalSessionRegistry()
        let directory = try PaneTestChild.temporaryDirectory()
        directories.append(directory)
        let id = SessionID()
        // One channel, two contexts: the same key, and a store and a reporter of its own each,
        // which is what a rebound workspace hands the host.
        let before = PaneTestContext.fixture(session: id, cwd: directory)
        let after = PaneTestContext.fixture(session: id, cwd: directory)
        let stale = registry.session(for: before.context)
        stale.openShellPane()

        let fresh = registry.session(for: after.context)

        XCTAssertFalse(fresh === stale, "the registry handed back the previous workspace's session")
        await registry.settleRelease()
        XCTAssertTrue(stale.panes.isEmpty, "panes=\(stale.panes.count)")

        for pane in fresh.panes { await fresh.close(pane) }
    }

    /// The same rule from the owner's side: `AppModel.bindWorkspace` releases the registry, and a
    /// release ends the panes it held — a child nothing can reach again is a child nothing can
    /// ever close.
    func testReleasingTheRegistryClosesItsPanesAndTheNextAskIsANewSession() async throws {
        let registry = TerminalSessionRegistry()
        let fixture = try fixture()
        let session = registry.session(for: fixture.context)
        session.openShellPane()

        registry.release()
        await registry.settleRelease()

        XCTAssertTrue(session.panes.isEmpty, "panes=\(session.panes.count)")
        let fresh = registry.session(for: fixture.context)
        XCTAssertFalse(fresh === session, "a released session was handed out again")
    }

    /// A teardown is not a user action, and the document is the channel's rather than this
    /// session's. Releasing the registry through the user-close path persisted every removal as it
    /// went, so the last write a rebound workspace left behind named no shell and no selection —
    /// the channel's saved setup, overwritten by the act of putting it away.
    func testReleasingTheRegistryLeavesTheChannelsSavedShellsInTheDocument() async throws {
        let registry = TerminalSessionRegistry()
        let store = PaneTestContext.RecordingStore()
        let directory = try PaneTestChild.temporaryDirectory()
        directories.append(directory)
        let id = SessionID()
        let fixture = PaneTestContext.fixture(session: id, cwd: directory, store: store)
        let session = registry.session(for: fixture.context)
        session.openShellPane()
        session.openShellPane()
        session.restoreOnce()
        await session.settlePersistence()

        registry.release()
        await registry.settleRelease()
        await session.settlePersistence()

        let written = try await store.read(
            TerminalPanelState.self,
            key: TerminalPanelState.storeKey(for: fixture.key)
        )
        let document = try XCTUnwrap(written, "the channel's document is gone")
        XCTAssertEqual(document.panes.count, 2, "panes=\(document.panes.count)")
        XCTAssertEqual(document.selected, 1, "selected=\(String(describing: document.selected))")
    }

    /// The read of the W6 document is a suspension the release runs straight through. A session
    /// released inside it must come back to nothing: opening the saved shells after its owner has
    /// gone leaves children nobody accounts for, spawned after `settleRelease()` had already said
    /// the teardown was done.
    func testASessionReleasedInsideItsDocumentReadOpensNothing() async throws {
        let registry = TerminalSessionRegistry()
        let store = PaneTestContext.RecordingStore()
        let directory = try PaneTestChild.temporaryDirectory()
        directories.append(directory)
        let id = SessionID()
        let fixture = PaneTestContext.fixture(session: id, cwd: directory, store: store)
        try await store.write(
            TerminalPanelState(panes: [PersistedPane(cwd: directory.path)], selected: 0),
            key: TerminalPanelState.storeKey(for: fixture.key)
        )
        let writesBefore = await store.writtenKeys.count
        let session = registry.session(for: fixture.context)

        await store.holdReads()
        session.restoreOnce()
        await store.awaitHeldRead()
        registry.release()
        await registry.settleRelease()
        await store.releaseHeldRead()
        await session.settleRestore()
        await session.settlePersistence()

        XCTAssertTrue(session.panes.isEmpty, "panes=\(session.panes.count)")
        let writesAfter = await store.writtenKeys.count
        XCTAssertEqual(writesAfter, writesBefore, "writes=\(writesAfter - writesBefore) after the release")
    }

    /// The other side of the same rule: a teardown writes nothing of its own, and a close the
    /// *user* asked for is a removal from the channel's document however the session ends.
    ///
    /// A close suspends while its child is torn down, and a release arriving inside that
    /// suspension used to clear `panes` and mark the session released first — so the close came
    /// back, failed to find its pane, and persisted nothing. The shell the user had explicitly
    /// closed was still in the document, waiting to be restored. The two rules are reconciled by
    /// ordering rather than by trading one away: the teardown lets the closes already standing
    /// finish, and only then puts the session away.
    func testACloseStandingWhenTheSessionIsTornDownStillLeavesTheDocument() async throws {
        let registry = TerminalSessionRegistry()
        let store = PaneTestContext.RecordingStore()
        let home = try PaneTestChild.temporaryDirectory()
        let elsewhere = try PaneTestChild.temporaryDirectory()
        directories.append(contentsOf: [home, elsewhere])
        let fixture = PaneTestContext.fixture(session: SessionID(), cwd: home, store: store)
        let session = registry.session(for: fixture.context)
        session.openShellPane(cwd: home)
        let closing = session.openShellPane(cwd: elsewhere)
        session.restoreOnce()
        await session.settlePersistence()

        let close = Task { await session.close(closing) }
        await Task.yield()
        await Task.yield()
        registry.release()
        await registry.settleRelease()
        await close.value
        await session.settlePersistence()

        let written = try await store.read(
            TerminalPanelState.self,
            key: TerminalPanelState.storeKey(for: fixture.key)
        )
        let document = try XCTUnwrap(written, "the channel's document is gone")
        XCTAssertEqual(document.panes.count, 1, "panes=\(document.panes.count)")
        XCTAssertEqual(document.panes.first?.cwd, home.path,
                       "the document kept the shell the user closed and dropped the one they left")
    }

    func testTheRunnerPlacesAPaneInTheChannelTheContextNames() async throws {
        let registry = TerminalSessionRegistry()
        let jade = try fixture()
        let slate = try fixture()
        let runner = TerminalPaneRunner(registry: registry)
        let jadeSession = registry.session(for: jade.context)
        let slateSession = registry.session(for: slate.context)

        await runner.run(
            PaneRequest(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "sleep 5"],
                cwd: slate.cwd,
                environment: ["PATH": "/usr/bin:/bin"],
                purpose: .logs(JobShort(rawValue: "jd7"))
            ),
            in: slate.context
        )

        XCTAssertEqual(slateSession.panes.count, 1, "the named channel did not gain the pane")
        XCTAssertEqual(jadeSession.panes.count, 0, "the pane landed in another channel's session")

        for pane in slateSession.panes { await slateSession.close(pane) }
    }
}
