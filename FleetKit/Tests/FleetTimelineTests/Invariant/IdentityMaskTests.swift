import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// `IdentityMask` and `Breaks` are the two support pieces check one leans on, and the corpus exercises neither: every
/// recorded mirror entry agrees with its file line at every field, so `differingPaths` returns nothing anywhere and
/// the mask is never asked to excuse anything. Check one's whole field-comparison arm therefore passes with bodies
/// that return the empty set unconditionally, and `Breaks`' recursive setter has no caller that reaches its throw.
/// These tests are what make all of that falsifiable, which matters beyond this task: Task 9's check two reuses
/// `IdentityMask` for the file-versus-wire comparison.
///
/// Every JSON value in the mask tests is invented — no engine byte, and identifiers that name nothing recorded. The
/// `Breaks` test drives a recorded record, as C3's constraints require of any mutation test.
final class IdentityMaskTests: XCTestCase {

    // MARK: - Invented values

    /// The shape the mask has to reason about: a nested `message.usage` object, an array of blocks, and a sibling key
    /// whose name is a prefix of `usage`. The three parameters are the three places a difference can be planted.
    private static func invented(outputTokens: Int64 = 7, note: String = "one", text: String = "alpha") -> JSONValue {
        .object([
            "type": .string("assistant"),
            "uuid": .string("0000aaaa-0000-4000-8000-00000000aaaa"),
            "message": .object([
                "id": .string("msg_inventedAAAAAAAAAAAA"),
                "usage": .object(["input_tokens": .integer(11), "output_tokens": .integer(outputTokens)]),
                "usageExtra": .object(["note": .string(note)]),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
        ])
    }

    // MARK: - differingPaths

    /// (a) A planted difference is reported at exactly its deep dotted path, and nowhere else; an untouched pair
    /// reports nothing. Array elements are addressed by index, and a key present on one side only is reported at its
    /// own path rather than recursed into.
    func testDifferingPathsNamesThePlantedDifferenceAndOnlyIt() {
        let base = Self.invented()
        XCTAssertEqual(IdentityMask.differingPaths(base, base), [])
        XCTAssertEqual(IdentityMask.differingPaths(base, Self.invented(outputTokens: 8)),
                       ["message.usage.output_tokens"])
        XCTAssertEqual(IdentityMask.differingPaths(base, Self.invented(text: "beta")),
                       ["message.content.0.text"])
        XCTAssertEqual(IdentityMask.differingPaths(base, Self.invented(note: "two")),
                       ["message.usageExtra.note"])

        var trimmed = base.objectValue!
        trimmed["uuid"] = nil
        XCTAssertEqual(IdentityMask.differingPaths(base, .object(trimmed)), ["uuid"],
                       "a key on one side only is reported at its own path")
    }

    // MARK: - unmasked

    /// (b) and (c): a declared scope covers itself and everything beneath it, and covers nothing else. The same planted
    /// mutation is excused under `message.usage` and unexcused under a declaration that does not contain it.
    func testUnmaskedExcusesOnlyWhatTheScopeDeclares() {
        let differing = IdentityMask.differingPaths(Self.invented(), Self.invented(outputTokens: 8))
        XCTAssertEqual(differing, ["message.usage.output_tokens"])

        XCTAssertEqual(IdentityMask.unmasked(differing, allowed: ["message.usage"]), [],
                       "a declared object declares everything beneath it")
        XCTAssertEqual(IdentityMask.unmasked(differing, allowed: ["message.usage.output_tokens"]), [],
                       "a declared path declares itself")
        XCTAssertEqual(IdentityMask.unmasked(differing, allowed: ["message.content"]), differing,
                       "an undeclared path is not excused by an unrelated declaration")
        XCTAssertEqual(IdentityMask.unmasked(differing, allowed: []), differing)
    }

    /// (d) The sibling-prefix case, which is what the `.` boundary in `unmasked` is for: declaring `message.usage`
    /// must not reach `message.usageExtra`, whose path merely starts with the declared string.
    func testADeclaredScopeDoesNotReachAPrefixSibling() {
        let sibling = IdentityMask.differingPaths(Self.invented(), Self.invented(note: "two"))
        XCTAssertEqual(sibling, ["message.usageExtra.note"])
        XCTAssertEqual(IdentityMask.unmasked(sibling, allowed: ["message.usage"]), sibling,
                       "message.usage declares the usage object, not every sibling whose name it prefixes")
        XCTAssertEqual(IdentityMask.unmasked(sibling, allowed: ["message.usageExtra"]), [])
    }

    // MARK: - Breaks

    /// `Breaks.mutating(field:in:to:)` recurses down a dotted path of object keys and throws where a component names
    /// no key — the guard that makes a typo in a break a failure instead of a silent no-op. Driven here against a
    /// recorded record, with `differingPaths` proving the edit landed at the named path and changed nothing else.
    func testBreaksSetsADeepFieldAndThrowsOnAPathThatNamesNoKey() throws {
        let fixture = try FixtureCorpus.named("background-shell")
        var assistant: TranscriptRecord?
        for (_, kind, url) in try fixture.transcriptFiles() {
            guard case .mainTranscript = kind else { continue }
            assistant = try TranscriptReader(url: url).readAll().records.first {
                if case .assistant(let record) = $0 { return record.fields.message.fields.usage != nil }
                return false
            }
        }
        let record = try XCTUnwrap(assistant, "background-shell's main transcript carries an assistant record with usage")

        let mutated = try Breaks.mutating(field: "message.usage.output_tokens", in: record, to: .integer(999_999))
        XCTAssertEqual(IdentityMask.differingPaths(try record.jsonValue(), try mutated.jsonValue()),
                       ["message.usage.output_tokens"],
                       "the recursive set edits the named leaf and leaves every sibling alone")

        XCTAssertThrowsError(try Breaks.mutating(field: "message.usage.notAKeyTheEngineWrites",
                                                 in: record, to: .integer(1)),
                             "a path component that is not an object key must throw, not append")
    }
}
