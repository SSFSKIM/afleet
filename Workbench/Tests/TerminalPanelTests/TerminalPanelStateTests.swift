import AfleetCore
import FleetKit
import Foundation
import PanelHostAPI
import TerminalCore
@testable import TerminalPanel
import XCTest

/// W6's document: the one key it is written under, that only shell panes reach it, and what an
/// absent or unreadable document restores to (spec Design §7; gate G4.2).
@MainActor
final class TerminalPanelStateTests: XCTestCase {
    private var directories: [URL] = []
    private var openSessions: [TerminalPanelSession] = []

    /// The first 12 lowercase hex characters of SHA-256 over `/invented/config-home`, computed
    /// once and written down. It is spelled to match ClaudeWire's `RawCapture.configHomeHash`,
    /// which Workbench may not import (X1), so this vector is the only thing holding the two
    /// spellings together — a change to either side fails here.
    private let configHomeHashVector = "a7520a8c9a48"

    override func tearDown() async throws {
        for session in openSessions {
            for pane in session.panes { await session.close(pane) }
        }
        openSessions = []
        for directory in directories { PaneTestChild.remove(directory) }
        directories = []
        try await super.tearDown()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = try PaneTestChild.temporaryDirectory()
        directories.append(directory)
        return directory
    }

    private func makeSession(
        cwd: URL,
        session id: SessionID,
        store: PaneTestContext.RecordingStore
    ) -> TerminalPanelSession {
        let fixture = PaneTestContext.fixture(session: id, cwd: cwd, store: store)
        let session = TerminalPanelSession(context: fixture.context)
        openSessions.append(session)
        return session
    }

    // MARK: Group 2 — the key

    func testTheStoreKeyIsPanelTerminalConfigHomeHashSessionID() throws {
        let id = SessionID(uuid: try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")))
        let key = ChannelKey(configHome: PaneTestContext.configHome, session: id)

        XCTAssertEqual(TerminalPanelState.configHomeHash(key.configHome), configHomeHashVector,
                       "the config-home hash spelling changed")
        XCTAssertEqual(TerminalPanelState.storeKey(for: key),
                       "panel.terminal.\(configHomeHashVector).\(id.description)",
                       "the W6 key changed shape")
    }

    func testTheSessionWritesUnderThatKeyAndNoOther() async throws {
        let store = PaneTestContext.RecordingStore()
        let id = SessionID(uuid: try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")))
        let session = makeSession(cwd: try temporaryDirectory(), session: id, store: store)

        session.openShellPane()
        await session.settlePersistence()

        let written = try await store.keys()
        XCTAssertEqual(written, ["panel.terminal.\(configHomeHashVector).\(id.description)"],
                       "the session wrote a key W6 does not name")
    }

    // MARK: Group 3 — only shell panes are persisted

    func testOnlyShellPanesArePersistedAndRestored() async throws {
        let store = PaneTestContext.RecordingStore()
        let id = SessionID()
        let home = try temporaryDirectory()
        let elsewhere = try temporaryDirectory()
        let writer = makeSession(cwd: home, session: id, store: store)

        writer.openShellPane()
        writer.openShellPane(cwd: elsewhere)
        writer.run(PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "sleep 5"],
            cwd: home,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .attach(JobShort(rawValue: "jd7"))
        ))
        await writer.settlePersistence()

        let document = try await store.read(
            TerminalPanelState.self,
            key: TerminalPanelState.storeKey(for: ChannelKey(configHome: PaneTestContext.configHome, session: id))
        )
        let persisted = try XCTUnwrap(document, "nothing was persisted")
        XCTAssertEqual(persisted.panes.count, 2, "an X5-originated pane reached the document")
        XCTAssertEqual(persisted.panes.map(\.cwd), [home.path, elsewhere.path],
                       "the recorded directories are not the shell panes'")

        let restored = makeSession(cwd: home, session: id, store: store)
        await restored.restore()

        XCTAssertEqual(restored.panes.count, 2, "the restore did not reopen the two shell panes")
        // Compared by path: `URL(fileURLWithPath:)` appends a trailing slash for a directory that
        // exists, so two URLs naming one directory are not equal values, and the directory is what
        // this assertion is about.
        XCTAssertEqual(restored.panes.compactMap { $0.spawn?.cwd.path }, [home.path, elsewhere.path],
                       "the restored panes are not at their recorded directories")
        XCTAssertTrue(restored.panes.allSatisfy { $0.request == nil },
                      "the restore reopened a pane that carries a PaneRequest")
    }

    // MARK: Group 4 — an absent or unreadable document

    func testAnAbsentDocumentRestoresToOneShellPane() async throws {
        let session = makeSession(cwd: try temporaryDirectory(),
                                  session: SessionID(),
                                  store: PaneTestContext.RecordingStore())

        await session.restore()

        XCTAssertEqual(session.panes.count, 1, "an absent document did not restore to one shell pane")
        XCTAssertEqual(session.selectedIndex, 0, "the restored pane was not selected")
    }

    func testAnUnknownSchemaVersionRestoresToOneShellPaneAndDoesNotThrow() async throws {
        let store = PaneTestContext.RecordingStore()
        let id = SessionID()
        let home = try temporaryDirectory()
        let key = ChannelKey(configHome: PaneTestContext.configHome, session: id)
        try await store.write(
            TerminalPanelState(
                schemaVersion: TerminalPanelState.currentSchemaVersion + 41,
                panes: [PersistedPane(cwd: home.path), PersistedPane(cwd: home.path)],
                selected: 1
            ),
            key: TerminalPanelState.storeKey(for: key)
        )
        let session = makeSession(cwd: home, session: id, store: store)

        await session.restore()

        XCTAssertEqual(session.panes.count, 1, "an unknown schemaVersion was restored from anyway")
        XCTAssertEqual(session.selectedIndex, 0, "the restored pane was not selected")
    }

    // MARK: Group 5 — the restore and the first mutation are ordered

    /// X7's amendment lets a `PaneRequest` name a channel no window is showing, so the pane runner
    /// can be the first thing that ever touches a session. Its pane is not persistable, so the
    /// document that session would write is an empty one — over the channel's saved shells, before
    /// anything has read them. The read has to come first, whoever asks for the write.
    func testAPaneRequestBeforeTheFirstRenderLeavesTheChannelsSavedShellsIntact() async throws {
        let store = PaneTestContext.RecordingStore()
        let id = SessionID()
        let home = try temporaryDirectory()
        let elsewhere = try temporaryDirectory()
        let key = ChannelKey(configHome: PaneTestContext.configHome, session: id)
        try await store.write(
            TerminalPanelState(panes: [PersistedPane(cwd: home.path), PersistedPane(cwd: elsewhere.path)],
                               selected: 1),
            key: TerminalPanelState.storeKey(for: key)
        )
        let session = makeSession(cwd: home, session: id, store: store)

        session.run(PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", PaneTestChild.selfTerminating(after: 30, "sleep 30")],
            cwd: home,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .hatch(id)
        ))
        await session.settlePersistence()

        // The first render, which is `TerminalPanelTab.makeView` calling `restoreOnce()`.
        session.restoreOnce()
        await session.settleRestore()
        await session.settlePersistence()

        let written = try await store.read(TerminalPanelState.self, key: TerminalPanelState.storeKey(for: key))
        let document = try XCTUnwrap(written, "nothing was persisted")
        XCTAssertEqual(document.panes.count, 2, "panes=\(document.panes.count)")
        XCTAssertEqual(document.panes.map(\.cwd), [home.path, elsewhere.path],
                       "the document no longer records the channel's saved shells")
        XCTAssertEqual(session.panes.count, 3, "panes=\(session.panes.count)")
    }

    /// The read is a suspension like any other, and a pane can be opened inside it. Neither half
    /// may be lost: the pane is still there and still the one the session shows, and the shells the
    /// document recorded are all in what is written back.
    func testAPaneOpenedDuringTheStoreReadSurvivesTheRestoreAndReachesTheDocument() async throws {
        let store = PaneTestContext.RecordingStore()
        let id = SessionID()
        let home = try temporaryDirectory()
        let elsewhere = try temporaryDirectory()
        let key = ChannelKey(configHome: PaneTestContext.configHome, session: id)
        try await store.write(
            TerminalPanelState(panes: [PersistedPane(cwd: home.path), PersistedPane(cwd: home.path)],
                               selected: 1),
            key: TerminalPanelState.storeKey(for: key)
        )
        let session = makeSession(cwd: home, session: id, store: store)

        await store.holdReads()
        session.restoreOnce()
        await store.awaitHeldRead()
        let opened = session.openShellPane(cwd: elsewhere)
        await store.releaseHeldRead()
        await session.settleRestore()
        await session.settlePersistence()

        XCTAssertTrue(session.panes.contains { $0 === opened }, "the pane opened during the read is gone")
        XCTAssertEqual(session.panes.count, 3, "panes=\(session.panes.count)")
        XCTAssertTrue(session.selectedPane === opened,
                      "the restore reselected over the pane opened during its own read")
        let written = try await store.read(TerminalPanelState.self, key: TerminalPanelState.storeKey(for: key))
        let document = try XCTUnwrap(written, "nothing was persisted")
        XCTAssertEqual(document.panes.count, 3, "panes=\(document.panes.count)")
        XCTAssertTrue(document.panes.contains { $0.cwd == elsewhere.path },
                      "the pane opened during the read never reached the document")
    }

    /// The default pane belongs to a session that has done nothing yet, and to no other. A user
    /// who opened a pane inside the held read and closed it again has said what they want the tab
    /// to hold — nothing — and `close()` and the view both say that closing the last pane leaves
    /// none. A restore that read emptiness as "this session has never had a pane" opened a shell
    /// over that answer and persisted it.
    func testAPaneClosedDuringTheReadIsNotReplacedByADefaultShell() async throws {
        let store = PaneTestContext.RecordingStore()
        let session = makeSession(cwd: try temporaryDirectory(), session: SessionID(), store: store)

        await store.holdReads()
        session.restoreOnce()
        await store.awaitHeldRead()
        let opened = session.openShellPane()
        await session.close(opened)
        await store.releaseHeldRead()
        await session.settleRestore()
        await session.settlePersistence()

        XCTAssertTrue(session.panes.isEmpty, "panes=\(session.panes.count)")
        XCTAssertNil(session.selectedIndex, "selected=\(String(describing: session.selectedIndex))")
    }

    // MARK: Group 6 — the selection is an index into what is persisted

    /// Only shell panes are persisted, so a selection recorded as an index into the full stack is
    /// read back at restore as an index into a shorter array and names a different pane. With a
    /// request pane in front of two shells it is off by exactly one, every time.
    func testTheSelectionIsPersistedAsAnIndexIntoThePersistedPanes() async throws {
        let store = PaneTestContext.RecordingStore()
        let id = SessionID()
        let home = try temporaryDirectory()
        let alpha = try temporaryDirectory()
        let beta = try temporaryDirectory()
        let key = ChannelKey(configHome: PaneTestContext.configHome, session: id)
        let session = makeSession(cwd: home, session: id, store: store)

        session.run(PaneRequest(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", PaneTestChild.selfTerminating(after: 30, "sleep 30")],
            cwd: home,
            environment: ["PATH": "/usr/bin:/bin"],
            purpose: .logs(JobShort(rawValue: "jsel"))
        ))
        session.openShellPane(cwd: alpha)
        session.openShellPane(cwd: beta)
        session.select(1)
        await session.settlePersistence()

        let written = try await store.read(TerminalPanelState.self, key: TerminalPanelState.storeKey(for: key))
        let document = try XCTUnwrap(written, "nothing was persisted")
        XCTAssertEqual(document.selected, 0, "selected=\(String(describing: document.selected))")

        let restored = makeSession(cwd: home, session: id, store: store)
        await restored.restore()

        XCTAssertEqual(restored.selectedIndex, 0, "selected=\(String(describing: restored.selectedIndex))")
        XCTAssertEqual(restored.selectedPane?.spawn?.cwd.path, alpha.path,
                       "the restore selected a pane the session did not have selected")
    }
}
