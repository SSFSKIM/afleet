import XCTest
import WireFrames

final class IdentifierTests: XCTestCase {
    func testEpochProgression() {
        XCTAssertEqual(ProcessEpoch.first.rawValue, 1)
        XCTAssertEqual(ProcessEpoch.first.next().rawValue, 2)
        XCTAssertLessThan(ProcessEpoch.first, ProcessEpoch.first.next())
        XCTAssertEqual(ProcessEpoch(rawValue: 7).next(), ProcessEpoch(rawValue: 8))
    }
    func testRequestIDIsHashableByValue() {
        XCTAssertEqual(RequestID(rawValue: "a"), RequestID(rawValue: "a"))
        XCTAssertEqual(Set([RequestID(rawValue: "a"), RequestID(rawValue: "a")]).count, 1)
    }
}
