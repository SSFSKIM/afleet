import Foundation

/// The address field's own state: the text in it, and whether the user is in the middle of typing.
///
/// It is a value type outside the view because the two rules it holds are both invisible from
/// inside SwiftUI, and both are things the panel got wrong once:
///
/// - **A page that navigates does not overwrite a draft.** Titles, history entries and a page's own
///   redirects all move the URL, and a field that followed every one of them would take the address
///   the user was halfway through typing away before `onSubmit` ever read it.
/// - **A field that is drawn over a settled page opens on that page.** The host gives each
///   (tab, channel) pair its own SwiftUI identity, so a channel switch rebuilds this state from
///   nothing while the shared tab set carries on unchanged. Nothing changes at that moment, so a
///   field that only followed changes would open blank on a page that is plainly on screen.
struct BrowserAddressField: Equatable {

    /// What the field shows, and what a submission reads.
    private(set) var text = ""

    /// Whether the user is composing an address right now. It begins at the first keystroke rather
    /// than at focus, because a field the user has merely tabbed into holds no draft to protect.
    private(set) var isEditing = false

    /// The field was drawn, or drawn again over a tab set that did not change.
    mutating func appeared(showing url: URL?) {
        guard !isEditing else { return }
        text = url?.absoluteString ?? ""
    }

    mutating func edited(to new: String) {
        text = new
        isEditing = true
    }

    /// The address was submitted: the draft is done, so the page's own URL may follow again.
    mutating func submitted() {
        isEditing = false
    }

    /// Focus left the field. Whatever was being composed is no longer being composed.
    mutating func focusEnded() {
        isEditing = false
    }

    /// The page moved. Ignored while a draft is being composed, and `nil` is ignored always: a web
    /// view between pages reports no URL, and that is not an address.
    mutating func pageChanged(to url: URL?) {
        guard !isEditing, let url else { return }
        text = url.absoluteString
    }

    /// A different tab is selected. It takes the field unconditionally, draft or not: the draft was
    /// for the tab the user just left, and a field showing it over another tab's page would submit
    /// into the wrong one.
    mutating func tabChanged(to url: URL?) {
        text = url?.absoluteString ?? ""
        isEditing = false
    }
}
