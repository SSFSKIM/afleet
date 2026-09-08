import Foundation
import PanelHostAPI

/// What went wrong with the tab-set document, as a value the panel can show in a row of its own.
///
/// It names a kind and never a payload — no path, no key, no underlying error's description — for
/// the reason W5's routing fallback does the same: a diagnostic is allowed to say what happened,
/// not to publish what it happened to.
public enum BrowserTabStoreError: Sendable, Equatable {

    /// The stored document was written by a build with a schema this one does not know. The panel
    /// opened empty and will not write over it.
    case documentFromANewerBuild(found: Int)

    /// The document could not be decoded. The panel opened empty; the next write replaces it.
    case documentUnreadable

    /// The store refused a write. What the user sees is unchanged; the document is behind.
    case writeFailed
}

/// Reads and writes the Browser panel's shared tab set at contract W6's `browser` key.
///
/// **The key is `browser`, not `workbench.browser`.** A panel cannot name a namespace at all: the
/// host binds `workbench` when it constructs the `ChannelContext` and passes keys through unchanged
/// (W6 as amended 2026-09-09 at C7.5's gate; ledger Q19). This type writes one key and reads no
/// other.
///
/// **When a write happens** (Q6). A structural change — a tab opened, closed, reordered or
/// selected — is what a user does and then quits, so it is written at once. A URL or a title commit
/// arrives several times per navigation, so it is written through a trailing window; the last
/// commit inside the window wins and a structural change inside it supersedes the window entirely.
///
/// The window's sleep is injected rather than taken from a clock, because a test that waits 500 ms
/// to learn that one write happened is a test that waits 500 ms to learn nothing else.
public actor BrowserTabStore {

    /// W6's key, verbatim.
    public static let storeKey = "browser"

    /// Q6's trailing window.
    public static let coalescingWindow: Duration = .milliseconds(500)

    /// What the panel is showing. A failed write never changes it: the document falls behind, the
    /// user does not lose a tab.
    public private(set) var current: BrowserTabSet = .empty

    /// The panel-local error row, or `nil`. Cleared by the next write that succeeds.
    public private(set) var lastError: BrowserTabStoreError?

    private let store: any ScopedStore
    private let sleep: @Sendable (Duration) async -> Void

    /// Set when `load` found a document from a newer build. Every write is refused from then on,
    /// for the process's lifetime: the newer build's document is its property.
    private var writesRefused = false

    private var pendingEdit: BrowserTabSet?
    private var windowIsOpen = false

    /// Persistence runs in order behind this chain; see `persist`.
    private var writeChain: Task<Void, Never> = Task {}

    private var errorObserver: ErrorObserver?

    /// The task an open window is running in. Held so a test can tell the difference between "the
    /// superseded window wrote nothing" and "the superseded window has not run yet" — from a write
    /// count alone the two look identical.
    private var windowTask: Task<Void, Never>?

    /// Bumped by every structural change, so a window opened before it can tell that it has been
    /// superseded and return without writing.
    private var generation = 0

    public init(store: any ScopedStore,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.store = store
        self.sleep = sleep
    }

    // MARK: Reading

    /// Reads the persisted set, clamping the selection and applying the cap.
    ///
    /// Nothing here throws. A panel that cannot read its tab set opens with none; a channel that
    /// cannot be told about it is not a channel this failure belongs in (§10).
    @discardableResult
    public func load() async -> BrowserTabSet {
        current = .empty
        do {
            // **The version is read before the shape.** A later build is free to rename or drop
            // every field this one knows, so decoding the version-1 document first turns a newer
            // document into an *unreadable* one — and an unreadable document is one this build then
            // writes over, which is exactly the protection the version exists to give.
            guard let probe = try await store.read(SchemaProbe.self, key: Self.storeKey) else {
                return current
            }
            guard probe.schemaVersion <= BrowserTabSetDocument.currentSchemaVersion else {
                writesRefused = true
                lastError = .documentFromANewerBuild(found: probe.schemaVersion)
                return current
            }
            guard let document = try await store.read(BrowserTabSetDocument.self, key: Self.storeKey) else {
                return current
            }
            current = BrowserTabSet(document: document)
            return current
        } catch {
            lastError = .documentUnreadable
            current = .empty
            return current
        }
    }

    /// The one field every version of this document has, on its own.
    ///
    /// Decoded before the version-specific shape so that "which build wrote this" is answered by
    /// the payload and never inferred from whether this build could read the rest of it.
    private struct SchemaProbe: Codable, Sendable {
        var schemaVersion: Int
    }

    // MARK: Writing

    /// A tab opened, closed, reordered or selected: written immediately, and any window still open
    /// behind it is superseded — the structural set already carries whatever the window held.
    public func commitStructuralChange(_ set: BrowserTabSet) async {
        current = set
        generation += 1
        pendingEdit = nil
        windowIsOpen = false
        await persist(set)
    }

    /// A URL or a title: coalesced into one write at the end of a trailing window.
    public func commitEdit(_ set: BrowserTabSet) {
        current = set
        pendingEdit = set
        guard !windowIsOpen else { return }
        windowIsOpen = true
        let opened = generation
        windowTask = Task { [sleep] in
            await sleep(Self.coalescingWindow)
            await self.closeWindow(opened: opened)
        }
    }

    /// Writes whatever a window is holding, now. The panel calls this when it is going away, so a
    /// title typed into the last half-second is not the one thing a relaunch forgets.
    public func flushPendingEdits() async {
        if let pending = pendingEdit {
            pendingEdit = nil
            windowIsOpen = false
            generation += 1
            await persist(pending)
        }
        // And whatever a window already handed to the store, pending or not. A drain that returned
        // in front of a write in flight would let the app exit mid-write, which is the one thing a
        // drain exists to prevent.
        await writeChain.value
    }

    /// Told the error row after every write, so the panel's own copy follows the write rather than
    /// the call that scheduled it.
    public typealias ErrorObserver = @Sendable (BrowserTabStoreError?) async -> Void

    /// Installs `observer` and tells it what the row says now. One observer: the model that owns
    /// this store is the only thing that renders it.
    public func observeErrors(_ observer: @escaping ErrorObserver) async {
        errorObserver = observer
        await observer(lastError)
    }

    /// Returns once the window in flight, if any, has run to its decision. Nothing in the panel
    /// needs this; the supersede test does, and a seam is cheaper than a sleep.
    func settle() async {
        await windowTask?.value
    }

    private func closeWindow(opened: Int) async {
        // A structural change (or an explicit flush) has been through since this window opened, and
        // wrote a set that already includes everything the window was holding. Returning without
        // touching `windowIsOpen` is deliberate: a *newer* window may be open by now, and clearing
        // the flag here would let a third commit open a second one alongside it.
        guard opened == generation else { return }
        windowIsOpen = false
        guard let pending = pendingEdit else { return }
        pendingEdit = nil
        await persist(pending)
    }

    /// Every write, in submission order.
    ///
    /// **The two write paths are not otherwise ordered.** `closeWindow` has already taken the
    /// pending edit by the time it suspends on the store, so the generation check can no longer
    /// invalidate a write that is on its way; a structural change entering during that suspension
    /// submits a newer snapshot behind it; and `ScopedStore` promises nothing about which of two
    /// writes completes first. The chain is what makes the last snapshot submitted the last one
    /// written, and it is also what `flushPendingEdits` waits on.
    private func persist(_ set: BrowserTabSet) async {
        guard !writesRefused else { return }
        let task = Task { [previous = writeChain] in
            await previous.value
            await self.write(set)
        }
        writeChain = task
        await task.value
    }

    /// One write, and the error row that follows it.
    private func write(_ set: BrowserTabSet) async {
        do {
            try await store.write(set.documentToPersist(), key: Self.storeKey)
            lastError = nil
        } catch {
            lastError = .writeFailed
        }
        // The panel is told by the write that happened and not by the call that scheduled one: a
        // coalesced commit returns half a second before its write, so a caller sampling `lastError`
        // at the commit samples the write before it.
        await errorObserver?(lastError)
    }
}
