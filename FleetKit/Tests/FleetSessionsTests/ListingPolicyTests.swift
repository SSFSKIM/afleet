import XCTest
@testable import FleetSessions

final class ListingPolicyTests: XCTestCase {
    func entry(entrypoint: String? = "cli", kind: String? = nil, sidechain: Bool = false, team: String? = nil, continuedIn: String? = nil) -> ListingPolicy.IndexEntry {
        .init(sessionID: "s", entrypoint: entrypoint, sessionKind: kind, isSidechain: sidechain, teamName: team, continuedIn: continuedIn)
    }
    func testOwnSDKCLISessionsAreListed() {
        XCTAssertEqual(ListingPolicy.include(entry(entrypoint: "sdk-cli")), .listed(.ownedCandidate))
        // The verdict above is also what `default` returns, so on its own it cannot tell the rule from its absence.
        // This entry can: `own-sdk-cli` runs before `sidechain`, so our own session is listed even when it is one.
        XCTAssertEqual(ListingPolicy.include(entry(entrypoint: "sdk-cli", sidechain: true)), .listed(.ownedCandidate))
    }
    func testSidechainsAreNotListed()              { XCTAssertEqual(ListingPolicy.include(entry(sidechain: true)), .excluded(.sidechain)) }
    func testContinuedTranscriptsFoldIntoTheirContinuation() { XCTAssertEqual(ListingPolicy.include(entry(continuedIn: "s2")), .excluded(.continuedIn("s2"))) }
    func testTeammateTranscriptsAreListedReadOnly() { XCTAssertEqual(ListingPolicy.include(entry(team: "alpha")), .listed(.readOnly(.teammate))) }
    func testEverythingElseIsListed()              { XCTAssertEqual(ListingPolicy.include(entry()), .listed(.ownedCandidate)) }
    func testTheRulesAreEnumerableForTheSidebar()  { XCTAssertEqual(ListingPolicy.rules.map(\.name), ["own-sdk-cli", "sidechain", "continued-in", "teammate", "default"]) }
    // Deliberate break for each: invert the rule -> its test names the wrong verdict.
}
