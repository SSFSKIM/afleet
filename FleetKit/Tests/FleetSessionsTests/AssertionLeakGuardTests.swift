import XCTest

/// The assertion-leak guard for this test target (tech-debt tracker entry 75, spec §6.3).
///
/// `FileManager.temporaryDirectory` carries the account hash of the machine that ran the suite, so an
/// `XCTAssertEqual` over two paths rooted there prints it on every failure — as does a failure message that
/// interpolates a resolved path. Both were swept out of this target once; this test is what stops them coming
/// back, by scanning the target's own sources for the two shapes the sweep was mechanical over:
///
/// 1. an `XCTAssertEqual`/`XCTAssertNotEqual` with a `.path` or `temporaryDirectory` operand on the same line;
/// 2. an `XCTAssert…`/`XCTFail` message that interpolates a `.path` or `.path(percentEncoded:)`.
///
/// The scan is deliberately line-based and syntactic rather than clever: it over-approximates, which is the
/// property that makes it a guard. A site that genuinely needs to survive it is named in `exempt` below with
/// its reason — the list is empty, and every entry added to it should be argued for in review.
///
/// The rewrite this guard protects: spell the assertion as a boolean carrying its own message, and let the
/// message name a count or the relation ("the two resolved roots differ") rather than the values. Where a
/// locator is genuinely needed, use a relative component or an index, never an absolute path.
final class AssertionLeakGuardTests: XCTestCase {

    /// Site → why it may print a path. Empty by design.
    private static let exempt: [String: String] = [:]

    private var targetRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }

    func testNoAssertionInThisTargetCanPrintAResolvedPath() throws {
        var offenders: [String] = []
        var scanned = 0
        let ownName = URL(fileURLWithPath: #filePath).lastPathComponent

        let walker = try XCTUnwrap(FileManager.default.enumerator(at: targetRoot,
                                                                  includingPropertiesForKeys: nil),
                                   "the target's source directory is not enumerable")
        for case let url as URL in walker {
            guard url.pathExtension == "swift", url.lastPathComponent != ownName else { continue }
            scanned += 1
            let relative = url.lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let site = "\(relative):\(offset + 1)"
                guard Self.exempt[site] == nil else { continue }
                if Self.leaksThroughEquality(line) || Self.leaksThroughMessage(line) {
                    offenders.append(site)
                }
            }
        }

        // The floor: a scan that read nothing would report no offender and prove nothing.
        XCTAssertGreaterThan(scanned, 0, "the guard scanned no source file at all")
        XCTAssertEqual(offenders.count, 0,
                       "\(offenders.count) assertion(s) can print a resolved path: \(offenders.joined(separator: ", "))")
    }

    /// Shape 1: an equality whose printed operands may be paths.
    private static func leaksThroughEquality(_ line: Substring) -> Bool {
        guard line.contains("XCTAssertEqual(") || line.contains("XCTAssertNotEqual(") else { return false }
        return mentionsAPath(line)
    }

    /// Shape 2: an assertion or failure whose message interpolates a path.
    private static func leaksThroughMessage(_ line: Substring) -> Bool {
        guard line.contains("XCTAssert") || line.contains("XCTFail") else { return false }
        guard line.contains("\\(") else { return false }
        return mentionsAPath(line)
    }

    private static func mentionsAPath(_ line: Substring) -> Bool {
        if line.contains("temporaryDirectory") { return true }
        // `.path` as a whole member: `.path`, `.path(percentEncoded:` — but not `.pathExtension`.
        var rest = line[...]
        while let hit = rest.range(of: ".path") {
            let after = hit.upperBound
            if after == rest.endIndex { return true }
            let next = rest[after]
            if !next.isLetter && !next.isNumber && next != "_" { return true }
            rest = rest[after...]
        }
        return false
    }
}
