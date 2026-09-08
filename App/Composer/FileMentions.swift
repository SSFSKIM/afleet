import SwiftUI
import Foundation
import AfleetCore
import ClaudeWire
import FleetKit

/// `@` file mentions, completed from the **engine's** index (spec §6.6's neighbour, C6.2 *`@` and
/// `!`*).
///
/// afleet spawns no process and reads no directory for this. The engine already indexes the project
/// and answers `file_suggestions {query}` with `{suggestions: [{path, score?}]}` — the CLI omits
/// `score` — so afleet asks it and renders the answer. A file list of afleet's own would be a second
/// index to keep in step, and reading the project directory is the very thing C5's TCC finding says
/// not to do.
///
/// The request goes out through `LifecycleAPI.send(_:on:)` as `AnyControlRequest`'s raw form, which
/// the plan names as the sanctioned route beside the five ClaudeWire types this leaf constructs.
/// `ClaudeWire` does carry a typed `FileSuggestions` spec; constructing it would be a sixth type
/// against a closed list, and the raw form puts exactly the same object on the wire — `query` and
/// nothing else: no `limit`, no `cwd`.
extension ComposerModel {

    /// The subtype, for the tests that assert what went to the wire. The *request* is built from
    /// C2's typed `FileSuggestions` spec, not from this string: ClaudeWire types the subtype and its
    /// one key, and a leaf spelling them itself is a second opinion about a shape C2 owns. The raw
    /// form stays for the subtypes ClaudeWire does not type — `cancel_async_message` is the leaf's
    /// only one (tracker 142).
    static let fileSuggestionsSubtype = FileSuggestions.subtype

    /// The `@` token the cursor is in, or nil when the draft has none.
    ///
    /// A token only at the start of the draft or after whitespace: `invented@example` is an address
    /// and not a mention, and completing it would open a popover over an email the user is typing.
    /// The query runs to the end of the draft, so a token with a space in it has already ended.
    static func mentionQuery(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace else { return nil }
        }
        let query = draft[draft.index(after: at)...]
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return String(query)
    }

    /// Called on every keystroke. Debounced, and the query in flight is cancelled by the next one:
    /// a request per keystroke would ask the engine to index-search four times for one word, and the
    /// answer to a token the user has already moved past would race the answer to the one they are
    /// looking at.
    func draftDidChange() {
        mentionTask?.cancel()
        guard let query = Self.mentionQuery(in: draft) else {
            fileSuggestions = []
            mentionTask = nil
            return
        }
        mentionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // `try?` swallows the cancellation the sleep throws, so the check below is what stops a
            // cancelled keystroke from asking anything.
            try? await Task.sleep(for: self.mentionDebounce)
            guard !Task.isCancelled else { return }
            await self.requestFileSuggestions(query)
        }
    }

    /// One `file_suggestions`, and what it answered.
    ///
    /// An answer whose shape afleet does not recognise renders nothing rather than trapping — §6.3's
    /// opacity rule applied to an answer — and so does a refused request. There is nothing to show
    /// and nothing that can be inferred, and a popover is not worth a crash.
    func requestFileSuggestions(_ query: String) async {
        let request = AnyControlRequest(FileSuggestions(query: query))
        let answer = try? await lifecycle.send(request, on: key)
        guard !Task.isCancelled else { return }
        fileSuggestions = answer.map(Self.suggestedPaths(in:)) ?? []
    }

    /// `suggestions[].path`, in the engine's own order. `score` is read by nothing: the engine ranked
    /// the list before sending it, and the CLI omits the field anyway.
    static func suggestedPaths(in answer: JSONValue) -> [String] {
        guard let entries = answer["suggestions"]?.arrayValue else { return [] }
        return entries.compactMap { $0["path"]?.stringValue }
    }

    /// A chosen row, put in place of the token that opened the popover.
    func accept(suggestion: String) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[draft.startIndex..<at]) + "@" + suggestion + " "
        fileSuggestions = []
        mentionTask?.cancel()
        mentionTask = nil
    }

    /// True while a mention popover has something to offer.
    var isMentioning: Bool { !fileSuggestions.isEmpty }
}

/// The mention popover above the field: the engine's paths, in the engine's order.
///
/// It writes no sentence of its own and holds no list of its own — every row is a path the engine
/// answered with.
struct FileMentionView: View {

    @Bindable var model: ComposerModel

    var body: some View {
        if model.isMentioning {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.fileSuggestions, id: \.self) { path in
                        Button {
                            model.accept(suggestion: path)
                        } label: {
                            Text(path)
                                .font(.callout.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 180)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
