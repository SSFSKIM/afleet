import Foundation

/// One tab as it survives a relaunch: what page it was on and what to call it before it loads.
///
/// Deliberately *not* here (ledger Q7): back/forward history, scroll offset, form state, and every
/// other thing WebKit holds per page. Cookies and site data are not in this document at all — they
/// live in the shared `WKWebsiteDataStore` and persist on their own.
public struct PersistedTab: Codable, Sendable, Equatable, Identifiable {

    /// Stable across a relaunch so a restored tab is the same tab, not a look-alike.
    public var id: UUID
    public var url: URL

    /// The last title the page reported, shown on a restored tab before it is first selected —
    /// which is the only reason it is persisted at all.
    public var title: String

    public init(id: UUID = UUID(), url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

/// The document at contract W6's `browser` key: "URLs, titles, order, selected index", versioned.
///
/// The version is a number this build compares against `currentSchemaVersion` and never a number it
/// migrates from: there is exactly one schema so far. What it buys is the *newer* direction — a
/// document a later build wrote is recognised as such and left alone rather than silently
/// overwritten with a downgrade (`BrowserTabStore.load`).
public struct BrowserTabSetDocument: Codable, Sendable, Equatable {

    /// What this build writes, and the ceiling above which a document is treated as another
    /// build's property.
    public static let currentSchemaVersion = 1

    /// How many tabs are persisted, newest by position. A tab strip has no hard cap (Q21); the
    /// document does, so that it stays a document.
    public static let persistedTabLimit = 50

    public var schemaVersion: Int
    /// The tab strip's order, left to right.
    public var tabs: [PersistedTab]
    /// Clamped into `tabs` on read; `tabs.isEmpty` is the only way to have no selection.
    public var selectedIndex: Int

    public init(schemaVersion: Int = BrowserTabSetDocument.currentSchemaVersion,
                tabs: [PersistedTab],
                selectedIndex: Int) {
        self.schemaVersion = schemaVersion
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }
}

/// The in-memory shape the panel works in: the same content, with "no selection" spelled as `nil`
/// rather than as an index into an empty array.
public struct BrowserTabSet: Sendable, Equatable {

    public var tabs: [PersistedTab]

    /// An index into `tabs`, or `nil` when there are none. Every path that produces a
    /// `BrowserTabSet` from a document keeps this invariant; the panel is free to rely on it.
    public var selection: Int?

    public static let empty = BrowserTabSet(tabs: [], selection: nil)

    public init(tabs: [PersistedTab], selection: Int?) {
        self.tabs = tabs
        self.selection = selection
    }

    /// The document to persist: at most `persistedTabLimit` tabs, newest by position, with the
    /// selection carried onto whichever of them survived.
    ///
    /// A selection inside the dropped prefix has no tab left to point at, so it clamps to the
    /// first persisted tab rather than to nothing — reopening on *a* page beats reopening on none.
    public func documentToPersist() -> BrowserTabSetDocument {
        let dropped = max(0, tabs.count - BrowserTabSetDocument.persistedTabLimit)
        let kept = Array(tabs.suffix(BrowserTabSetDocument.persistedTabLimit))
        let index = max(0, (selection ?? 0) - dropped)
        return BrowserTabSetDocument(tabs: kept,
                                     selectedIndex: kept.isEmpty ? 0 : min(index, kept.count - 1))
    }

    /// The set a document describes, with `selectedIndex` clamped into range and the same cap
    /// applied — a document holding more than the cap was not written by this build, and honouring
    /// it would let one grow without bound across versions.
    public init(document: BrowserTabSetDocument) {
        let kept = Array(document.tabs.suffix(BrowserTabSetDocument.persistedTabLimit))
        let dropped = document.tabs.count - kept.count
        if kept.isEmpty {
            self.init(tabs: [], selection: nil)
        } else {
            let index = max(0, document.selectedIndex - dropped)
            self.init(tabs: kept, selection: min(index, kept.count - 1))
        }
    }
}
