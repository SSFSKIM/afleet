import Foundation
import SwiftUI
import XCTest
import AfleetCore
import FleetKit
import PanelHostAPI
import Workbench
@testable import Afleet

/// C7's W6 for the host: `panel.host.<configHomeHash>.<sessionId>` in the `workbench` namespace,
/// holding the tab a channel was last showing (spec §7's selection ownership; W6 names C5 as its
/// writer).
///
/// The selection was one in-memory property, so every channel showed whatever the last one showed
/// and a relaunch showed the default. These four legs are the document: the key shape, the write,
/// the restore, and the two cases that must change nothing — a channel with no document, and a
/// store that refuses the write.
///
/// Every identifier is invented and every tree is built under the process's temporary directory by
/// `PanelRig`; no assertion prints a path or a config home (§6.3, §11).
@MainActor
final class PanelHostDocumentTests: XCTestCase {

    /// Two channels, two selections, and each one is still there on the way back.
    ///
    /// The channels are `focusChannel`'d exactly as `PanelColumnView`'s `task(id:)` does it, which
    /// is the only thing that tells the host the main window has moved.
    func testEachChannelKeepsItsOwnSelectedTabOnTheWayBack() async throws {
        let rig = try await PanelRig(channels: 2)
        let host = try attachedHost(to: rig)

        host.focusChannel(rig.keys[0])
        host.select(.files)
        host.focusChannel(rig.keys[1])
        host.select(.terminal)
        XCTAssertEqual(host.selected, .terminal, "the second channel did not take its own selection")

        host.focusChannel(rig.keys[0])
        XCTAssertEqual(host.selected, .files, "returning to the first channel did not restore its tab")
        host.focusChannel(rig.keys[1])
        XCTAssertEqual(host.selected, .terminal, "returning to the second channel did not restore its tab")
    }

    /// The relaunch leg: a fresh host over the same store shows what the previous one selected, and
    /// the document it reads is under W6's key.
    ///
    /// The key is asserted from the store's own key list rather than rebuilt here, so the assertion
    /// cannot restate the implementation; its hash component is compared against the Files panel's
    /// spelling of the same hash, which is what "the same twelve-hex config-home hash the Files and
    /// Terminal documents use" means.
    func testAFreshHostOverTheSameStoreRestoresTheSelectionFromItsW6Document() async throws {
        let rig = try await PanelRig(channels: 2)
        let first = try attachedHost(to: rig)
        first.focusChannel(rig.keys[0])
        first.select(.files)

        let key = try await hostDocumentKey(in: rig)
        let session = rig.keys[0].session.description
        let hash = FilesPanelStore.configHomeHash(rig.keys[0].configHome)
        XCTAssertEqual(key, "panel.host.\(hash).\(session)",
                       "the host's document is not under W6's key for this channel")

        let second = try attachedHost(to: rig)
        second.select(.thread)
        second.focusChannel(rig.keys[0])
        try await settle(until: { second.selected == .files })
        XCTAssertEqual(second.selected, .files,
                       "a fresh host over the same store did not restore the channel's tab")
    }

    /// A channel nothing has ever selected a tab in keeps whatever the host is showing. A restore
    /// that guessed would move the window for a channel that never asked.
    func testAChannelWithNoDocumentKeepsTheCurrentDefault() async throws {
        let rig = try await PanelRig(channels: 2)
        let host = try attachedHost(to: rig)
        host.select(.thread)

        host.focusChannel(rig.keys[1])
        try await settle(until: { false })
        XCTAssertEqual(host.selected, .thread,
                       "a channel with no document moved the selection off the default")
    }

    /// The store refuses every write. The selection is the user's and lands at once; only the
    /// document is lost, and the channel is still remembered for the rest of the run.
    func testAStoreThatRefusesTheWriteDoesNotDisturbTheSelection() async throws {
        let rig = try await PanelRig(channels: 2)
        let host = try attachedHost(to: rig, document: RefusingScopedStore())

        host.focusChannel(rig.keys[0])
        host.select(.files)
        XCTAssertEqual(host.selected, .files, "a refused write took the selection with it")

        host.focusChannel(rig.keys[1])
        host.select(.terminal)
        host.focusChannel(rig.keys[0])
        try await settle(until: { false })
        XCTAssertEqual(host.selected, .files,
                       "a refused write cost the channel its selection for the rest of the run")
    }

    // MARK: - The rig

    /// A host attached to the rig's workspace with the four tabs these tests select between, so a
    /// `select` is never refused for an id nothing holds.
    private func attachedHost(to rig: PanelRig,
                              document: (any ScopedStore)? = nil) throws -> PanelHostModel {
        let host = PanelHostModel()
        host.attach(to: rig.workspace, timelines: rig.timelines, lifecycle: rig.lifecycle,
                    document: document)
        for id in [PanelTabID.thread, .files, .terminal, .browser] {
            try host.register(DocumentStubTab(id))
        }
        return host
    }

    /// The one `panel.host.…` key the `workbench` namespace holds, once the coalescing writer has
    /// landed it. A bounded wait, because the writer drains on its own interval.
    private func hostDocumentKey(in rig: PanelRig,
                                 file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let deadline = ContinuousClock().now + .seconds(10)
        while ContinuousClock().now < deadline {
            let keys = try await rig.workspace.store.keys(in: .workbench)
                .filter { $0.hasPrefix("panel.host.") }
            if keys.count == 1 { return keys[0] }
            XCTAssertLessThan(keys.count, 2, "one selection wrote \(keys.count) host documents",
                              file: file, line: line)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the host never wrote its W6 document", file: file, line: line)
        throw NoHostDocument()
    }

    /// Gives an asynchronous restore a bounded chance to land, and returns as soon as it has.
    ///
    /// The two negative legs pass `{ false }` deliberately: what they assert is that nothing moved,
    /// so they have to spend the whole window rather than return on a condition.
    private func settle(until done: () -> Bool) async throws {
        let deadline = ContinuousClock().now + .milliseconds(600)
        while ContinuousClock().now < deadline {
            if done() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// What the wait above throws when it times out, so the failure it has already recorded is the
/// test's verdict rather than a skip.
private struct NoHostDocument: Error {}

/// A tab with nothing in it: these tests drive selection and the document, and never a view.
private final class DocumentStubTab: PanelTab {
    let id: PanelTabID
    var title: String { id.defaultTitle }
    var systemImage: String { id.defaultSystemImage }

    init(_ id: PanelTabID) { self.id = id }

    func isAvailable(in context: ChannelContext) -> Bool { true }
    func makeSession(for context: ChannelContext) -> any PanelTabSession { DocumentStubSession() }
    func makeView(session: any PanelTabSession, context: ChannelContext,
                  surface: PanelSurface) -> AnyView { AnyView(EmptyView()) }
}

private final class DocumentStubSession: PanelTabSession {}

/// A scoped store that refuses everything, with an invented message. The failure a document write
/// can actually meet — a full disk, a store that moved — expressed as the only thing `ScopedStore`
/// can say about it.
private struct RefusingScopedStore: ScopedStore {
    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async throws -> T? {
        throw StoreError.io("an invented store failure")
    }
    func write<T: Codable & Sendable>(_ value: T, key: String) async throws {
        throw StoreError.io("an invented store failure")
    }
    func remove(key: String) async throws { throw StoreError.io("an invented store failure") }
    func keys() async throws -> [String] { throw StoreError.io("an invented store failure") }
}
