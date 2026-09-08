import Foundation
import XCTest
import AfleetCore
import ClaudeWire
import FleetKit
@testable import Afleet

/// C6.2 Task 4, gate **G2**'s `@` half: file mentions completed from the **engine's** index.
///
/// afleet spawns no process and reads no directory for this — the engine owns the index and afleet
/// asks it (spec §6.6's neighbour, C6.2 *`@` and `!`*). So every assertion below is about the
/// request that went out and the answer that came back, and the negative arms are the ones that
/// matter: a request carrying a second key, a request per keystroke, and an answer whose shape is
/// unknown must render nothing rather than trap (§6.3's opacity rule, applied to an answer).
@MainActor
final class FileMentionTests: XCTestCase {

    private func makeKey() -> ChannelKey {
        ChannelKey(configHome: URL(fileURLWithPath: "/invented/config-home"),
                   session: SidebarFixtures.session("e"))
    }

    private func makeModel(_ double: ComposerLifecycleDouble) -> ComposerModel {
        let model = ComposerModel(key: makeKey(), lifecycle: double, surface: ChannelSurfaceState())
        // Long enough that a second keystroke in the same test statement always lands inside the
        // window, so the cancellation arm asserts a count and never a race.
        model.mentionDebounce = .milliseconds(200)
        return model
    }

    /// An invented answer in the shape the CLI sends: `{suggestions: [{path}]}` with no `score`,
    /// which is what 2.1.263 omits. Every path here is invented.
    private static let answer = JSONValue.object([
        "suggestions": .array([
            .object(["path": .string("invented/one.swift")]),
            .object(["path": .string("invented/two.swift"), "score": .number(0.5)]),
        ])
    ])

    /// One `@` token produces exactly one `file_suggestions` whose payload holds `query` and nothing
    /// else — no `limit`, no `cwd`.
    func testOneMentionSendsOneFileSuggestionsCarryingOnlyTheQuery() async {
        let double = ComposerLifecycleDouble()
        await double.stageSend("file_suggestions", .success(Self.answer))
        let model = makeModel(double)

        model.draft = "look at @inven"
        model.draftDidChange()
        await model.mentionTask?.value

        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes, ["file_suggestions"],
                       "one `@` token sent \(subtypes.count) control request(s)")
        guard let payload = await double.payload(ofFirst: "file_suggestions"),
              let keys = payload.objectValue.map({ Set($0.keys) }) else {
            return XCTFail("`file_suggestions` went out with a payload that is not an object")
        }
        XCTAssertEqual(keys, ["query"],
                       "the request carries \(keys.count) key(s) instead of `query` alone")
        XCTAssertEqual(payload["query"]?.stringValue, "inven",
                       "the request's query is not the \(5)-character token that was typed")
    }

    /// The popover's rows are `suggestions[].path`, in the engine's order, `score` ignored.
    func testSuggestionsRenderFromThePathOfEachAnswerEntry() async {
        let double = ComposerLifecycleDouble()
        await double.stageSend("file_suggestions", .success(Self.answer))
        let model = makeModel(double)

        model.draft = "@inven"
        model.draftDidChange()
        await model.mentionTask?.value

        XCTAssertEqual(model.fileSuggestions, ["invented/one.swift", "invented/two.swift"],
                       "the popover holds \(model.fileSuggestions.count) row(s) instead of the 2 the answer named")
    }

    /// An answer afleet does not recognise renders nothing and does not trap. Three shapes, because
    /// each fails a different guard: a bare string, an object with no `suggestions`, and an entry
    /// with no `path`.
    func testUnrecognisedAnswerShapesRenderNothingAndDoNotTrap() async {
        for (index, shape) in [JSONValue.string("an invented answer"),
                               .object(["files": .array([.string("invented/one.swift")])]),
                               .object(["suggestions": .array([.object(["name": .string("invented/one.swift")])])])]
            .enumerated() {
            let double = ComposerLifecycleDouble()
            await double.stageSend("file_suggestions", .success(shape))
            let model = makeModel(double)

            model.draft = "@inven"
            model.draftDidChange()
            await model.mentionTask?.value

            XCTAssertEqual(model.fileSuggestions.count, 0,
                           "answer shape \(index + 1) of 3 rendered \(model.fileSuggestions.count) row(s)")
            let subtypes = await double.sentSubtypes
            XCTAssertEqual(subtypes.count, 1,
                           "answer shape \(index + 1) of 3 produced \(subtypes.count) request(s)")
        }
    }

    /// A request that fails is the same: nothing renders, nothing traps.
    func testAFailedRequestRendersNothing() async {
        let double = ComposerLifecycleDouble()
        await double.stageSend("file_suggestions", .failure(.processExited))
        let model = makeModel(double)

        model.draft = "@inven"
        model.draftDidChange()
        await model.mentionTask?.value

        XCTAssertEqual(model.fileSuggestions.count, 0,
                       "a refused request rendered \(model.fileSuggestions.count) row(s)")
    }

    /// The second keystroke cancels the first query. Asserted on the **count of requests**, never on
    /// timing: two keystrokes inside one debounce window are one request, and its query is the
    /// second token.
    func testASecondKeystrokeCancelsTheQueryInFlight() async {
        let double = ComposerLifecycleDouble()
        await double.stageSend("file_suggestions", .success(Self.answer))
        let model = makeModel(double)

        model.draft = "@in"
        model.draftDidChange()
        model.draft = "@inven"
        model.draftDidChange()
        await model.mentionTask?.value

        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes.count, 1,
                       "two keystrokes inside one debounce window sent \(subtypes.count) request(s)")
        let surviving = await double.payload(ofFirst: "file_suggestions")?["query"]?.stringValue
        XCTAssertEqual(surviving, "inven", "the surviving request is not the second keystroke's token")
    }

    /// A draft with no `@` token asks nothing and clears whatever was showing. The negative arm: an
    /// `@` in the middle of a word is not a mention, so `invented@example` sends no request.
    func testADraftWithNoMentionTokenAsksNothingAndClearsTheRows() async {
        let double = ComposerLifecycleDouble()
        await double.stageSend("file_suggestions", .success(Self.answer))
        let model = makeModel(double)
        model.draft = "@inven"
        model.draftDidChange()
        await model.mentionTask?.value
        XCTAssertEqual(model.fileSuggestions.count, 2, "the first query rendered \(model.fileSuggestions.count) row(s)")

        model.draft = "invented@example and nothing else"
        model.draftDidChange()
        await model.mentionTask?.value

        XCTAssertEqual(model.fileSuggestions.count, 0,
                       "a draft with no mention token left \(model.fileSuggestions.count) row(s) showing")
        let subtypes = await double.sentSubtypes
        XCTAssertEqual(subtypes.count, 1,
                       "a draft with no mention token brought the request count to \(subtypes.count)")
    }

    /// Accepting a row replaces the token that opened the popover and closes it. The engine's index
    /// is asked again only when the user types another `@`.
    func testAcceptingASuggestionReplacesTheTokenAndClosesThePopover() async {
        let double = ComposerLifecycleDouble()
        await double.stageSend("file_suggestions", .success(Self.answer))
        let model = makeModel(double)
        model.draft = "look at @inven"
        model.draftDidChange()
        await model.mentionTask?.value

        model.accept(suggestion: "invented/one.swift")

        XCTAssertEqual(model.draft, "look at @invented/one.swift ",
                       "accepting a row left a \(model.draft.count)-character draft")
        XCTAssertEqual(model.fileSuggestions.count, 0,
                       "accepting a row left \(model.fileSuggestions.count) row(s) showing")
    }

    /// The rows are drawn: the composer's body holds the mention list, so the model above is what
    /// drives a view rather than a value nothing reads.
    func testTheComposerBodyHoldsTheMentionList() async {
        let double = ComposerLifecycleDouble()
        let model = makeModel(double)
        let body = ComposerViewTree.body(of: ComposerView(model: model))
        XCTAssertNotNil(ComposerViewTree.view(named: "FileMentionView", in: body),
                        "the composer's body does not hold the mention list")
    }
}
