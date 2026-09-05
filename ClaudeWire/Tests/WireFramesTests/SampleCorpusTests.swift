import XCTest
import WireFrames
import WireTestSupport

/// Every sample decodes typed (except the two deliberately unknown ones) and re-encodes without losing a key or value.
final class SampleCorpusTests: XCTestCase {
    func testEverySampleRoundTrips() throws {
        let unknown: Set<String> = ["unknown_type", "system_unknown_subtype"]
        var typed = 0
        for name in try TestPaths.sampleNames() {
            let raw = try TestPaths.sample(name)
            let frame = FrameDecoder.decode(line: raw)
            switch frame {
            case .opaque(let o): XCTAssertTrue(unknown.contains(name), "\(name) unexpectedly opaque: \(o.reason)")
            case .system(.opaque): XCTAssertTrue(unknown.contains(name), "\(name) unexpectedly opaque system")
            default: typed += 1
            }
            let again = try JSONDecoder().decode(JSONValue.self, from: try FrameDecoder.encode(frame))
            XCTAssertTrue(again.numericallyEqual(try JSONDecoder().decode(JSONValue.self, from: raw)), "\(name) not lossless")
        }
        XCTAssertGreaterThanOrEqual(typed, 45)
    }
}
