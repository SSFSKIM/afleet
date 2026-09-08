import Foundation
import XCTest
@testable import Afleet

/// C6.1 Task 3: untrusted text is stripped before it is laid out (child spec §5, parity §41.7).
///
/// **Why this suite exists at all.** The engine sanitises at paint time and the host is handed the
/// raw text, so every one of the code points below reaches afleet intact unless something here
/// removes it. A bidi override inside a tool result reorders the characters around it on screen: the
/// text a reader sees is not the text the tool produced, which is a spoof and not a cosmetic defect.
///
/// Every input is invented, and none of it comes from a recording (§11).
final class TextSanitiserTests: XCTestCase {

    /// The strip set, and — the floor — what has to survive it.
    ///
    /// The second half is not decoration: a sanitiser with `return ""` in it passes every assertion
    /// about what is gone. So a CJK paragraph, ordinary emoji, accented Latin and the two `Cc`
    /// scalars markdown is made of are asserted to come back untouched.
    func testTheSanitiserStripsTheParitySet() {
        // One scalar per class parity §41.7 names, with an ASCII letter between them so a failure
        // says which class survived.
        let cases: [(String, Unicode.Scalar)] = [
            ("Cc, a C0 control", "\u{0007}"),
            ("Cc, a C1 control", "\u{0085}"),
            ("Cf, a soft hyphen", "\u{00AD}"),
            ("Cf, a zero-width space", "\u{200B}"),
            ("Cf, a zero-width joiner", "\u{200D}"),
            ("Cf, the byte-order mark", "\u{FEFF}"),
            ("a bidi override, right-to-left", "\u{202E}"),
            ("a bidi override, left-to-right", "\u{202D}"),
            ("a bidi isolate", "\u{2066}"),
            ("a line separator", "\u{2028}"),
            ("a paragraph separator", "\u{2029}"),
            ("the braille blank", "\u{2800}"),
            ("Co, the private-use area", "\u{E000}"),
            ("Co, a supplementary private-use plane", "\u{F0000}"),
            ("Cn, an unassigned code point", "\u{0378}"),
            ("a default-ignorable, the Mongolian vowel separator", "\u{180E}"),
        ]
        for (name, scalar) in cases {
            let attacked = "a" + String(Character(scalar)) + "b"
            let cleaned = TextSanitiser.sanitise(attacked)
            XCTAssertEqual(cleaned, "ab",
                           "\(name) survived: \(cleaned.unicodeScalars.count) scalar(s) came back, not 2")
        }
        // The floor said twice, because the assertions above are all about absence.
        XCTAssertEqual(cases.count, 16, "the strip set lost a class: \(cases.count) case(s) were run")

        let survivors = "日本語の段落です。café — naïve 😀 👍 ✅\ta line\nand another"
        XCTAssertEqual(TextSanitiser.sanitise(survivors), survivors,
                       "ordinary text lost \(survivors.unicodeScalars.count - TextSanitiser.sanitise(survivors).unicodeScalars.count) scalar(s)")

        // A whole attacked paragraph, and a count rather than a spelling of what came out.
        let paragraph = "run\u{202E}this\u{200B}command\u{FEFF}now\u{2800}\u{E000}"
        let cleaned = TextSanitiser.sanitise(paragraph)
        XCTAssertEqual(cleaned.unicodeScalars.count, 17,
                       "the attacked paragraph came back with \(cleaned.unicodeScalars.count) scalar(s)")
        // §41.7's passes are iterated up to ten times because each pass can expose the next. One
        // scalar-wise pass over the union is the same fixed point, and this is what says so.
        XCTAssertEqual(TextSanitiser.sanitise(cleaned), cleaned,
                       "a second pass removed \(cleaned.unicodeScalars.count - TextSanitiser.sanitise(cleaned).unicodeScalars.count) more scalar(s), so one pass is not a fixed point")
    }
}
