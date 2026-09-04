import XCTest
import WireFrames
import WireTestSupport

/// Parent C2.G2, against C1's recorded corpus: every NDJSON line of every fixture decodes to a
/// `Frame`; re-encoding a known frame reproduces every key the line had with equal values; a line
/// whose type or subtype is not modelled decodes to `.opaque` carrying the raw line and a parsed
/// `JSONValue`; and the opaque count per fixture equals the census's count of unmodelled pairs.
///
/// Both recorded directions are checked. An `in` frame is one afleet sends and a fixture recorded;
/// it has to decode and round-trip exactly like an `out` frame, because the same models are used to
/// write it.
///
/// The corpus was recorded by a harness that strips three named `CLAUDE_*` variables only, so every
/// fixture carries the engine's session markers. It is recorded engine behaviour, not marker-free
/// behaviour, and nothing here should be read as evidence about the marker-free mode.
final class FixtureCorpusTests: XCTestCase {
    /// `<repo>/Fixtures`, from `ClaudeWire/Tests/Support`.
    private var fixturesRoot: URL {
        TestPaths.support.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// The corpus committed alongside this test. This is the floor that makes the whole test
    /// non-vacuous: every assertion below lives inside a loop over fixtures and then a loop over
    /// lines, so a wrong root, an empty listing or a filter that matches nothing would satisfy all
    /// of them by checking nothing. A count floor here, the file-presence check in
    /// `fixtureDirectories()`, the per-fixture line accounting and the census pair-set equality are
    /// four independent places a corpus that silently went missing fails instead of passing.
    private static let committedFixtureCount = 18

    /// Every subdirectory of `Fixtures/`, each required to carry both files. A directory missing
    /// one is a failure, not something to filter out: filtering is how a corpus disappears quietly.
    private func fixtureDirectories() throws -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: fixturesRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            XCTFail("no Fixtures directory at \(fixturesRoot.path)")
            return []
        }
        let names = try fm.contentsOfDirectory(atPath: fixturesRoot.path).sorted()
        var dirs: [URL] = []
        for name in names {
            let url = fixturesRoot.appendingPathComponent(name)
            var sub: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &sub), sub.boolValue else { continue }   // Fixtures/REVIEW.md
            for file in ["frames.ndjson", "census.json"] {
                XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent(file).path), "\(name) has no \(file)")
            }
            dirs.append(url)
        }
        XCTAssertGreaterThanOrEqual(dirs.count, Self.committedFixtureCount,
                                    "found \(dirs.count) fixtures under \(fixturesRoot.path); the committed corpus has \(Self.committedFixtureCount)")
        return dirs
    }

    // MARK: - census pair naming

    /// `request_id` → the subtype of its `control_request`, over the whole fixture and both
    /// directions. The census names a `control_response` after the request it answers, which is the
    /// only place that subtype is written down; reproducing the naming here is what lets the pair
    /// sets be compared at all (`Tools/probe/census.py: request_subtypes`).
    private static func requestSubtypes(_ frames: [JSONValue]) -> [String: String] {
        var out: [String: String] = [:]
        for frame in frames where frame["type"]?.stringValue == "control_request" {
            if let id = frame["request_id"]?.stringValue, let sub = frame["request"]?["subtype"]?.stringValue { out[id] = sub }
        }
        return out
    }

    /// The census's name for a frame (`Tools/probe/census.py: pair_of`): `type`, or `type/subtype`,
    /// with the control envelopes named after the inner request's subtype.
    private static func pairName(_ frame: JSONValue, _ requestSubtypes: [String: String]) -> String {
        let type = frame["type"]?.stringValue ?? "\(String(describing: frame["type"]))"
        switch type {
        case "control_request": return "control_request/" + (frame["request"]?["subtype"]?.stringValue ?? "?")
        case "control_response":
            let id = frame["response"]?["request_id"]?.stringValue ?? ""
            return "control_response/" + (requestSubtypes[id] ?? "?")
        default:
            guard let subtype = frame["subtype"]?.stringValue else { return type }
            return "\(type)/\(subtype)"
        }
    }

    /// Whether ClaudeWire models a census pair. A control envelope is modelled as an envelope
    /// whatever its inner subtype, so only the type half is consulted for those.
    static func isModelled(pair: String) -> Bool {
        let parts = pair.split(separator: "/", maxSplits: 1).map(String.init)
        let type = parts[0]
        let topLevel: Set<String> = ["assistant", "user", "stream_event", "result", "tool_progress", "tool_use_summary",
                                     "rate_limit_event", "auth_status", "prompt_suggestion", "conversation_reset",
                                     "transcript_mirror", "command_lifecycle", "keep_alive",
                                     "control_request", "control_response", "control_cancel_request"]
        if type == "system" { return parts.count == 2 && SystemFrame.knownSubtypes.contains(parts[1]) }
        return topLevel.contains(type)
    }

    // MARK: - the gate

    func testEveryFixtureDecodesLosslessly() throws {
        let dirs = try fixtureDirectories()
        var corpusLines = 0, corpusRoundTrips = 0, corpusIn = 0, corpusOut = 0

        for dir in dirs {
            let name = dir.lastPathComponent
            let text = try String(contentsOf: dir.appendingPathComponent("frames.ndjson"), encoding: .utf8)
            let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            XCTAssertFalse(lines.isEmpty, "\(name)/frames.ndjson has no lines")

            // Pass one: the envelope of every line, so the request-id map covers the whole fixture
            // before any frame is named.
            var frameValues: [JSONValue] = []
            var inCount = 0, outCount = 0
            for (index, line) in lines.enumerated() {
                let entry = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                guard let frame = entry["frame"], frame.objectValue != nil else {
                    XCTFail("\(name):\(index + 1) has no frame object"); continue
                }
                switch entry["dir"]?.stringValue {
                case "in": inCount += 1
                case "out": outCount += 1
                default: XCTFail("\(name):\(index + 1) has no in/out direction")
                }
                frameValues.append(frame)
            }
            XCTAssertEqual(frameValues.count, lines.count, "\(name): lines were dropped before decoding")
            XCTAssertGreaterThan(inCount, 0, "\(name): no inbound frames were examined")
            XCTAssertGreaterThan(outCount, 0, "\(name): no outbound frames were examined")

            // Pass two: decode, round-trip, and count.
            let subtypes = Self.requestSubtypes(frameValues)
            var observedByPair: [String: Int] = [:], opaqueByPair: [String: Int] = [:]
            var roundTrips = 0
            for (index, frameValue) in frameValues.enumerated() {
                let pair = Self.pairName(frameValue, subtypes)
                observedByPair[pair, default: 0] += 1
                let raw = try frameValue.canonicalData()
                let decoded = FrameDecoder.decode(line: raw)
                switch decoded {
                case .opaque(let o):
                    XCTAssertNotEqual(o.reason, .invalidJSON, "\(name):\(index + 1) recorded a frame that is not JSON")
                    if case .decodeFailure(let field, let why) = o.reason {
                        XCTFail("\(name):\(index + 1) modelled frame \(pair) failed to decode at '\(field)': \(why)")
                    }
                    XCTAssertEqual(o.raw, raw, "\(name):\(index + 1) opaque frame did not keep its raw line")
                    XCTAssertTrue(o.value.numericallyEqual(frameValue), "\(name):\(index + 1) opaque frame did not keep a parsed value")
                    opaqueByPair[pair, default: 0] += 1
                case .system(.opaque(let subtype, let value)):
                    XCTAssertTrue(value.numericallyEqual(frameValue), "\(name):\(index + 1) opaque system frame did not keep a parsed value")
                    opaqueByPair["system/\(subtype)", default: 0] += 1
                default:
                    let again = try JSONDecoder().decode(JSONValue.self, from: FrameDecoder.encode(decoded))
                    let rewritten = try again.canonicalData()
                    XCTAssertTrue(again.numericallyEqual(frameValue),
                                  "\(name):\(index + 1) \(pair) lost a key or a value on re-encode\n  was: \(String(decoding: raw, as: UTF8.self))\n  now: \(String(decoding: rewritten, as: UTF8.self))")
                    roundTrips += 1
                }
            }
            // Every line was accounted for exactly once: this is the floor on what was *compared*,
            // not merely on whether the loop ran.
            XCTAssertEqual(roundTrips + opaqueByPair.values.reduce(0, +), lines.count, "\(name): frames went uncounted")
            XCTAssertGreaterThan(roundTrips, 0, "\(name): no frame was round-tripped")

            // The census names every pair it recorded. Requiring the sets to be equal means the
            // decoder was exercised on each one: a pass that skipped, say, every control_response
            // would fail here even though it round-tripped hundreds of other frames.
            let census = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: dir.appendingPathComponent("census.json")))
            let pairs = try XCTUnwrap(census["pairs"]?.objectValue, "\(name)/census.json has no pairs object")
            XCTAssertFalse(pairs.isEmpty, "\(name)/census.json records no pairs")
            // keep_alive is excluded from a census by construction (census.py), so it is excluded here.
            XCTAssertEqual(Set(observedByPair.keys).subtracting(["keep_alive"]), Set(pairs.keys),
                           "\(name): pairs decoded do not match the census's pairs")

            // G2's count check. The census's `count` accumulates across re-recordings
            // (`census.merge_required`), so it is a count of *evidence*, not of this file's lines;
            // for an unmodelled pair the only value either side can hold is nothing at all, and
            // that is what is asserted.
            var expected: [String: Int] = [:]
            for (pair, entry) in pairs where !Self.isModelled(pair: pair) {
                expected[pair] = Int(entry["count"]?.intValue ?? 0)
            }
            XCTAssertEqual(expected, opaqueByPair, "\(name): census unmodelled counts vs opaque counts")

            corpusLines += lines.count; corpusRoundTrips += roundTrips; corpusIn += inCount; corpusOut += outCount
        }

        XCTAssertGreaterThan(corpusRoundTrips, 0, "no frame in the whole corpus was round-tripped")
        XCTAssertEqual(corpusRoundTrips, corpusLines, "every recorded frame is modelled today, so every line should have round-tripped")
        print("G2: \(dirs.count) fixtures, \(corpusLines) frames (\(corpusIn) in, \(corpusOut) out), \(corpusRoundTrips) round-tripped")
    }
}
