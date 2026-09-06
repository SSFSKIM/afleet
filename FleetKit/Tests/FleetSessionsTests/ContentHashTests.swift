import Foundation
import XCTest
@testable import FleetSessions

final class ContentHashTests: XCTestCase {
    /// The canonical form Task 7 hashes: sorted keys, no whitespace, slashes unescaped. The entry is invented,
    /// never an engine byte (§11), and the digest was computed with `printf '%s' '<bytes>' | shasum -a 256`.
    func testSHA256HexMatchesAPinnedVector() throws {
        let canonical = #"{"args":["-y","@example/marker-server"],"command":"npx","env":{"MARKER_DIR":"/tmp/marker"}}"#
        let pinned = "4870945a32634bf7de261a41193d9cbbf330c8f0a086d7f463703d27802e6b02"
        XCTAssertEqual(ContentHash.sha256Hex(Data(canonical.utf8)), pinned)

        // The same entry with its keys in another order canonicalises to exactly those bytes. Foundation escapes
        // `/` unless told not to, which is why `.withoutEscapingSlashes` is named alongside `.sortedKeys`.
        let raw: [String: Any] = [
            "command": "npx",
            "env": ["MARKER_DIR": "/tmp/marker"],
            "args": ["-y", "@example/marker-server"],
        ]
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), canonical)
        XCTAssertEqual(ContentHash.sha256Hex(data), pinned)
        // Deliberate break: drop `.withoutEscapingSlashes` -> the canonical bytes differ and the digest does not match.
    }
}
