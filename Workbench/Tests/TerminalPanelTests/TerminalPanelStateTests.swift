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
}
