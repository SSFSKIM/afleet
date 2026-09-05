import XCTest
import AfleetCore
import FleetTimeline
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

    /// The initialiser from C3's real entry: the five fields the policy reads, and nothing else of the index.
    func testAnEntryReadFromC3sIndexCarriesTheFiveFieldsThePolicyReads() {
        let session = SessionID(), continuation = SessionID()
        let indexed = FleetTimeline.IndexEntry(
            sessionID: session, path: URL(fileURLWithPath: "/tmp/afleet-listing-tests/\(session).jsonl"),
            slug: "proj", title: "a title", titleSource: .firstPrompt, preview: "a preview",
            mtime: Date(timeIntervalSince1970: 1_699_000_000), size: 2_048,
            entrypoint: "sdk-cli", sessionKind: "main", isSidechain: true, teamName: "alpha",
            continuedIn: continuation)

        let read = ListingPolicy.IndexEntry(indexed)

        XCTAssertEqual(read, ListingPolicy.IndexEntry(sessionID: session.description, entrypoint: "sdk-cli",
                                                      sessionKind: "main", isSidechain: true, teamName: "alpha",
                                                      continuedIn: continuation.description))
        XCTAssertEqual(ListingPolicy.include(read), .listed(.ownedCandidate), "our own session, sidechain or not")
        // Deliberate break: read `continuedIn` as the entry's own session id -> the two ids swap and the equality fails.
    }
}
