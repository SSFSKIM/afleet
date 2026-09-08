import SwiftUI
import ClaudeWire

/// The engine's own next-prompt suggestion, shown as ghost text in the empty field and accepted by
/// Tab (spec C6.2 *Ghost text*, item 40).
///
/// **It is an observation, not a fold.** C3's reducer deliberately drops `prompt_suggestion` — it is
/// not a timeline item and making one would touch the differential invariant — so the composer reads
/// the frame off its own `events(of:)` subscription, which **is** X5. Nothing here runs a reducer,
/// keeps a projection or writes back into the timeline, so X4's one-fold rule is untouched.
///
/// The text is the frame's `suggestion` key (2.1.263 `cli.pretty.js:451213`), read through
/// ClaudeWire's typed `PromptSuggestionFields` rather than out of the raw object: the key's spelling
/// is C2's statement about the frame and this leaf keeps no second opinion about it.
///
/// Turning the setting on or off is `RestartRequest(promptSuggestions:)`, a quiescent restart,
/// because `--prompt-suggestions` is a launch flag (§7.7's matrix). That control is the header's
/// (Task 8); what lives here is the flag this model reads and the two behaviours over it.
extension ComposerModel {

    /// One `prompt_suggestion` frame.
    ///
    /// Dropped outright while the setting is off. A channel launched without `--prompt-suggestions`
    /// receives no such frame at all, so this arm is about the moment between a restart being asked
    /// for and its readback landing — and about never showing a suggestion the user turned off.
    ///
    /// Shown only while the field is empty. A suggestion is a whole prompt, not a completion of a
    /// half-written one; drawn behind typed words it would be an offer that cannot be taken without
    /// throwing them away.
    func noteSuggestion(_ frame: PromptSuggestionFrame) {
        guard promptSuggestionsEnabled else { return }
        let suggestion = frame.fields.suggestion
        ghostText = suggestion.isEmpty ? nil : suggestion
    }

    /// What the field draws behind the caret: the suggestion, while there is one and nothing is
    /// typed. A computed answer rather than a second stored flag, so the two can never disagree.
    var visibleGhostText: String? {
        guard let ghostText, draft.isEmpty else { return nil }
        return ghostText
    }

    /// Tab, with a suggestion showing: the ghost text becomes the draft, verbatim.
    ///
    /// Returns whether it accepted anything, because that is the answer the field needs in order to
    /// decide whether the keystroke was the composer's or AppKit's.
    @discardableResult
    func acceptGhostText() -> Bool {
        guard let suggestion = visibleGhostText else { return false }
        draft = suggestion
        ghostText = nil
        return true
    }
}

/// The suggestion, drawn under the field rather than inside the text view.
///
/// Inside would mean a second text storage overlaying the first, kept in step on every keystroke;
/// under it is one label that says the same thing and cannot drift. Advisory presentation, as the
/// spec's *Design inheritance* marks the composer's visual structure.
struct GhostTextView: View {

    @Bindable var model: ComposerModel

    var body: some View {
        if let suggestion = model.visibleGhostText {
            HStack(spacing: 6) {
                Text(suggestion)
                    .lineLimit(2)
                    .foregroundStyle(.tertiary)
                Text("Tab")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
        }
    }
}
