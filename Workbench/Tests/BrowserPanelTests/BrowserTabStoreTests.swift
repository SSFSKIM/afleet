import Foundation
import XCTest
import PanelHostAPI
@testable import BrowserPanel

/// C7.6 milestone 1: the persisted tab set (the headless half of gate G3).
///
/// Every URL below is invented — `.invalid` and `.test` are reserved by RFC 2606 and 6761 and can
/// never resolve — and no test here reaches a real store, a disk or a network (§11, and the
/// ledger's Q17 layer 1). Counts are asserted; paths never are.
///
/// No test waits on wall clock. The coalescing window's sleep is a `ManualSleeper` the test drives,
/// and every wait for a write is fulfilled by the observed write itself.
final class BrowserTabStoreTests: XCTestCase {

    // MARK: Fixtures

    private static func tab(_ name: String) -> PersistedTab {
        PersistedTab(id: UUID(), url: URL(string: "https://\(name).example.invalid/")!, title: name)
    }

    private static func set(_ names: [String], selection: Int?) -> BrowserTabSet {
        BrowserTabSet(tabs: names.map(tab), selection: selection)
    }

    private func makeStore() -> (BrowserTabStore, InMemoryScopedStore, ManualSleeper) {
        let backing = InMemoryScopedStore()
        let sleeper = ManualSleeper()
        return (BrowserTabStore(store: backing, sleep: sleeper.sleep), backing, sleeper)
    }

    // MARK: Q6 — the document

    func testARoundTripPreservesTabOrderAndSelection() async throws {
        let (store, backing, _) = makeStore()
        let original = Self.set(["one", "two", "three"], selection: 1)
        await store.commitStructuralChange(original)
        await backing.waitForWriteAttempts(1)

        let reopened = BrowserTabStore(store: backing, sleep: { _ in })
        let restored = await reopened.load()
        XCTAssertEqual(restored, original, "order and selection survive a round trip through the store")
        let keys = await backing.writtenKeys
        XCTAssertEqual(keys, [BrowserTabStore.storeKey])
    }

    /// Q19: the host binds the `workbench` namespace and the key does not restate it.
    func testTheDocumentIsWrittenAtTheBareBrowserKey() async throws {
        XCTAssertEqual(BrowserTabStore.storeKey, "browser")
        let (store, backing, _) = makeStore()
        await store.commitStructuralChange(Self.set(["one"], selection: 0))
        await backing.waitForWriteAttempts(1)
        let keys = await backing.writtenKeys
        XCTAssertEqual(keys, ["browser"], "never workbench.browser: the host bound the namespace")
    }

    func testASelectedIndexPastTheEndClampsToTheLastTab() async throws {
        let (store, backing, _) = makeStore()
        await backing.seed(json: """
            {"schemaVersion":1,"selectedIndex":9,"tabs":[
              {"id":"11111111-1111-4111-8111-111111111111","url":"https://a.example.invalid/","title":"a"},
              {"id":"22222222-2222-4222-8222-222222222222","url":"https://b.example.invalid/","title":"b"}
            ]}
            """, key: BrowserTabStore.storeKey)
        let restored = await store.load()
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.selection, 1, "an out-of-range index clamps to the last tab, never to nil")
    }

    func testANegativeSelectedIndexClampsToTheFirstTab() async throws {
        let (store, backing, _) = makeStore()
        await backing.seed(json: """
            {"schemaVersion":1,"selectedIndex":-4,"tabs":[
              {"id":"11111111-1111-4111-8111-111111111111","url":"https://a.example.invalid/","title":"a"}
            ]}
            """, key: BrowserTabStore.storeKey)
        let restored = await store.load()
        XCTAssertEqual(restored.selection, 0)
    }

    func testAnEmptyTabListYieldsNoSelection() async throws {
        let (store, backing, _) = makeStore()
        await backing.seed(json: #"{"schemaVersion":1,"selectedIndex":0,"tabs":[]}"#,
                           key: BrowserTabStore.storeKey)
        let restored = await store.load()
        XCTAssertTrue(restored.tabs.isEmpty)
        XCTAssertNil(restored.selection, "no tabs means no selection — not index zero of nothing")
    }

    func testAnAbsentDocumentOpensEmpty() async throws {
        let (store, _, _) = makeStore()
        let restored = await store.load()
        let error = await store.lastError
        XCTAssertEqual(restored, BrowserTabSet.empty)
        XCTAssertNil(error, "a first launch is not an error")
    }

    // MARK: Q6 — a document from a newer build

    func testADocumentFromANewerBuildReadsAsEmpty() async throws {
        let (store, backing, _) = makeStore()
        await backing.seed(json: """
            {"schemaVersion":2,"selectedIndex":0,"tabs":[
              {"id":"33333333-3333-4333-8333-333333333333","url":"https://c.example.invalid/","title":"c"}
            ]}
            """, key: BrowserTabStore.storeKey)
        let restored = await store.load()
        let error = await store.lastError
        XCTAssertTrue(restored.tabs.isEmpty, "a schema this build does not know opens empty")
        XCTAssertEqual(error, .documentFromANewerBuild(found: 2))
    }

    func testADocumentFromANewerBuildRefusesEverySubsequentWrite() async throws {
        let (store, backing, sleeper) = makeStore()
        await backing.seed(json: #"{"schemaVersion":2,"selectedIndex":0,"tabs":[]}"#,
                           key: BrowserTabStore.storeKey)
        _ = await store.load()

        await store.commitStructuralChange(Self.set(["one"], selection: 0))
        await store.commitEdit(Self.set(["renamed"], selection: 0))
        await sleeper.waitForSleep()
        await sleeper.advance()
        await store.flushPendingEdits()

        let attempts = await backing.attemptedWrites
        let error = await store.lastError
        let live = await store.current
        XCTAssertEqual(attempts, 0, "the newer build's document is preserved: not one write is attempted")
        XCTAssertEqual(error, .documentFromANewerBuild(found: 2))
        XCTAssertEqual(live.tabs.count, 1, "the panel still works in memory; only the document is left alone")
    }

    // MARK: Q6 — the fifty-tab cap

    func testSixtyTabsPersistAsTheNewestFiftyInOrder() async throws {
        let (store, backing, _) = makeStore()
        let names = (0..<60).map { "t\($0)" }
        await store.commitStructuralChange(Self.set(names, selection: 59))
        await backing.waitForWriteAttempts(1)

        let document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        let live = await store.current
        XCTAssertEqual(document?.tabs.count, 50)
        XCTAssertEqual(document?.tabs.map(\.title), Array(names.suffix(50)),
                       "the newest fifty by position, in the strip's order")
        XCTAssertEqual(document?.selectedIndex, 49, "the selection follows the tabs it survived with")
        XCTAssertEqual(live.tabs.count, 60, "the cap is a persistence cap; live tabs are uncapped (Q21)")
    }

    func testASelectionInsideTheDroppedPrefixClampsToTheFirstPersistedTab() async throws {
        let (store, backing, _) = makeStore()
        await store.commitStructuralChange(Self.set((0..<60).map { "t\($0)" }, selection: 3))
        await backing.waitForWriteAttempts(1)
        let document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(document?.selectedIndex, 0)
    }

    // MARK: Q6 — when writes happen

    func testTenTitleChangesInsideTheWindowProduceOneWrite() async throws {
        let (store, backing, sleeper) = makeStore()
        for index in 0..<10 {
            await store.commitEdit(BrowserTabSet(tabs: [Self.tab("title\(index)")], selection: 0))
        }
        await sleeper.waitForSleep()
        let duringWindow = await backing.attemptedWrites
        XCTAssertEqual(duringWindow, 0, "nothing is written while the window is open")

        await sleeper.advance()
        await backing.waitForWriteAttempts(1)

        let attempts = await backing.attemptedWrites
        let durations = await sleeper.requestedDurations
        let document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(attempts, 1, "ten commits, one write")
        XCTAssertEqual(durations, [BrowserTabStore.coalescingWindow],
                       "one trailing window, and it is the window the ledger names")
        XCTAssertEqual(document?.tabs.first?.title, "title9", "the last commit inside the window wins")
    }

    func testAStructuralChangeInsideTheWindowWritesImmediately() async throws {
        let (store, backing, sleeper) = makeStore()
        for index in 0..<5 {
            await store.commitEdit(BrowserTabSet(tabs: [Self.tab("title\(index)")], selection: 0))
        }
        await sleeper.waitForSleep()

        await store.commitStructuralChange(Self.set(["opened", "andAnother"], selection: 1))
        let afterStructural = await backing.attemptedWrites
        var document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(afterStructural, 1, "a tab opened is written at once, not in 500 ms")
        XCTAssertEqual(document?.tabs.map(\.title), ["opened", "andAnother"])

        // The superseded window must not fire a second, stale write behind it. `settle` waits for
        // that window to reach its decision, so a count taken here means "wrote nothing" and not
        // "has not run yet".
        await sleeper.advance()
        await store.settle()

        var total = await backing.attemptedWrites
        document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(total, 1, "the superseded window wrote nothing behind the structural change")
        XCTAssertEqual(document?.tabs.map(\.title), ["opened", "andAnother"],
                       "and did not put the stale title back over it")

        // And the next edit still gets a window of its own.
        await store.commitEdit(BrowserTabSet(tabs: [Self.tab("afterwards")], selection: 0))
        await sleeper.waitForSleep()
        await sleeper.advance()
        await backing.waitForWriteAttempts(2)

        total = await backing.attemptedWrites
        document = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(total, 2)
        XCTAssertEqual(document?.tabs.map(\.title), ["afterwards"])
    }

    func testAnEditCommittedAfterAWindowClosesOpensANewWindow() async throws {
        let (store, backing, sleeper) = makeStore()
        await store.commitEdit(BrowserTabSet(tabs: [Self.tab("first")], selection: 0))
        await sleeper.waitForSleep()
        await sleeper.advance()
        await backing.waitForWriteAttempts(1)

        await store.commitEdit(BrowserTabSet(tabs: [Self.tab("second")], selection: 0))
        await sleeper.waitForSleep()
        await sleeper.advance()
        await backing.waitForWriteAttempts(2)

        let attempts = await backing.attemptedWrites
        let durations = await sleeper.requestedDurations
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(durations.count, 2, "a closed window does not stay closed against the next edit")
    }

    // MARK: Q6 — a store that throws

    func testAThrowingStoreLeavesTheInMemorySetIntactAndReportsTheError() async throws {
        let (store, backing, _) = makeStore()
        await backing.setFailsWrites(true)
        let wanted = Self.set(["kept", "alsoKept"], selection: 1)

        await store.commitStructuralChange(wanted)

        let live = await store.current
        let error = await store.lastError
        let attempts = await backing.attemptedWrites
        let stored = try await backing.document(BrowserTabSetDocument.self, key: BrowserTabStore.storeKey)
        XCTAssertEqual(live, wanted, "a failed write does not roll back what the user sees")
        XCTAssertEqual(error, .writeFailed, "and it does not throw at a caller that cannot handle it")
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(stored)
    }

    func testASuccessfulWriteClearsAPreviousWriteError() async throws {
        let (store, backing, _) = makeStore()
        await backing.setFailsWrites(true)
        await store.commitStructuralChange(Self.set(["one"], selection: 0))
        let firstError = await store.lastError
        XCTAssertEqual(firstError, .writeFailed)

        await backing.setFailsWrites(false)
        await store.commitStructuralChange(Self.set(["one", "two"], selection: 1))
        let secondError = await store.lastError
        XCTAssertNil(secondError, "the panel-local error row clears when the store recovers")
    }
}
