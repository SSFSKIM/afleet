import XCTest
import WireFrames
import WireTestSupport

/// Parent C2.G2, against C1's recorded corpus: every NDJSON line of every fixture decodes to a
/// `Frame`; re-encoding a known frame reproduces every key the line had with equal values; a line
/// whose type or subtype is not modelled decodes to `.opaque` carrying the raw line and a parsed
/// `JSONValue`; and the opaque count per fixture equals the census's count of unmodelled pairs.
///
/// The gate is split three ways along `fixture.json`'s `synthetic` flag. Losslessness and the
/// opaque counts are asserted over all twenty fixtures, because both are meaningful for a
/// constructed frame. "A modelled type decodes typed" is asserted over the recorded fixtures only:
/// a recording is authoritative about what the engine sends, while a construction is authoritative
/// only about the shape it was built to exercise, and its silence about a field says the
/// constructor had nothing to put there rather than that the engine omits it. A synthetic frame
/// that does not decode typed is reported as a named finding — fixture, line, field — so the case
/// where the cause is *not* deliberate partiality is something we would learn rather than tolerate.
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
    private static let committedFixtureCount = 20
    /// Of those twenty, the ones `fixture.json` marks as recorded rather than synthetic.
    private static let committedRecordedFixtureCount = 18

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
        // Equality, not a floor: with `>=`, deleting one fixture and adding another nets to green.
        XCTAssertEqual(dirs.count, Self.committedFixtureCount,
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

    /// A frame in a synthetic fixture that does not decode typed, named so it is reported rather
    /// than silently tolerated. Deliberate partiality is the expected cause; anything else is how
    /// we would learn that a synthetic fixture broke.
    private struct SyntheticFinding: CustomStringConvertible {
        let fixture: String, line: Int, pair: String, field: String, why: String
        var description: String { "\(fixture):\(line) \(pair) — no typed decode at '\(field)': \(why)" }
        /// Fixture, line, census pair and the missing key — everything that identifies the finding, and
        /// nothing that is only the decoder's phrasing of it.
        var identity: String { "\(fixture):\(line) \(pair) \(field)" }
    }

    /// Every synthetic frame that does not decode typed, by name.
    ///
    /// Asserted as an equality rather than printed, and rather than counted. Printed, a regression in a frame
    /// that only a synthetic fixture carries stayed green with the breakage in console output; counted, a new
    /// finding could hide behind one that had gone away. Equality fails in both directions: a frame that
    /// stops decoding lands here as an addition, and one that starts decoding — because the model was
    /// relaxed, or the fixture rewritten — as a removal that has to be taken out on purpose.
    ///
    /// All ten are the same shortfall: a synthetic `result` frame built without `duration_ms`.
    private static let expectedSyntheticFindings: Set<String> = [
        "dialog-fable-overage:7 result/success duration_ms",
        "dialog-fable-overage:13 result/success duration_ms",
        "dialog-fable-overage:19 result/success duration_ms",
        "dialog-fable-overage:25 result/success duration_ms",
        "dialog-fable-overage:31 result/success duration_ms",
        "dialog-refusal-fallback:9 result/success duration_ms",
        "dialog-refusal-fallback:14 result/error_during_execution duration_ms",
        "dialog-refusal-fallback:20 result/error_during_execution duration_ms",
        "dialog-refusal-fallback:26 result/error_during_execution duration_ms",
        "dialog-refusal-fallback:30 result/success duration_ms",
    ]

    /// Why a finding is a finding and not a reason to relax the model. Printed with the findings so
    /// the reader is not left to infer it from the fixture counts: what makes a field required is
    /// the engine's guarantee in the bundle, not the number of recordings that happened to show it.
    private static let findingsPreamble = """
        A synthetic fixture is authoritative only about the shape it was built to exercise, so a \
        field it omits says the constructor had nothing to put there — not that the engine omits it. \
        For the `result` frames below the bundle settles it: 2.1.258 `cli.pretty.js` builds every \
        stream-json result through `$W` (line 35141), which spreads `duration_ms` and `uuid` last, \
        over a `common` carrying `session_id` and `total_cost_usd` at all six call sites.
        """

    /// `fixture.json`'s `synthetic` flag. A recorded fixture is authoritative about what the engine
    /// sends; a synthetic one is authoritative only about the shape it was constructed to exercise,
    /// and its silence about a field is a fact about the constructor, not about the engine. Absent
    /// or unreadable reads as recorded, which is the strict side.
    private func isSynthetic(_ dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("fixture.json")),
              let meta = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        return meta["synthetic"]?.boolValue ?? false
    }

    // MARK: - the gate

    func testEveryFixtureDecodesLosslessly() throws {
        let dirs = try fixtureDirectories()
        var corpusLines = 0, corpusRoundTrips = 0, corpusIn = 0, corpusOut = 0
        var recordedFixtures = 0, syntheticFixtures = 0
        var findings: [SyntheticFinding] = []
        var singleRunCensusMissing: [String] = []

        for dir in dirs {
            let name = dir.lastPathComponent
            let synthetic = isSynthetic(dir)
            if synthetic { syntheticFixtures += 1 } else { recordedFixtures += 1 }
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
            var roundTrips = 0, partial = 0
            for (index, frameValue) in frameValues.enumerated() {
                let pair = Self.pairName(frameValue, subtypes)
                observedByPair[pair, default: 0] += 1
                let raw = try frameValue.canonicalData()
                let decoded = FrameDecoder.decode(line: raw)
                switch decoded {
                case .opaque(let o):
                    XCTAssertNotEqual(o.reason, .invalidJSON, "\(name):\(index + 1) recorded a frame that is not JSON")
                    // Losslessness holds for every fixture: an opaque frame re-emits its raw bytes
                    // and keeps a parsed value, whether it is opaque because the type is unmodelled
                    // or because a modelled type did not decode. The raw-bytes half is weak on
                    // purpose here — the decoder is handed `canonicalData()` rather than the
                    // recorded line's own bytes, so it only says the decoder echoes what it was
                    // given. What a recorded line's bytes survive `FrameDecoder` unchanged is
                    // asserted in `WireFramesTests`, against samples loaded byte for byte.
                    XCTAssertEqual(o.raw, raw, "\(name):\(index + 1) opaque frame did not keep its raw line")
                    XCTAssertTrue(o.value.numericallyEqual(frameValue), "\(name):\(index + 1) opaque frame did not keep a parsed value")
                    if case .decodeFailure(let field, let why) = o.reason {
                        // "A modelled type decodes typed" is asserted against recorded fixtures only.
                        // In a synthetic fixture the same shortfall is a named finding: reported, not
                        // swallowed and not fatal, because a synthetic frame may be deliberately
                        // partial — and if it is ever partial for some other reason, this is where
                        // that shows up.
                        if synthetic {
                            findings.append(.init(fixture: name, line: index + 1, pair: pair, field: field, why: why))
                            partial += 1
                        } else {
                            XCTFail("\(name):\(index + 1) modelled frame \(pair) failed to decode at '\(field)': \(why)")
                            opaqueByPair[pair, default: 0] += 1
                        }
                    } else {
                        opaqueByPair[pair, default: 0] += 1
                    }
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
            // Every line was accounted for exactly once, findings included: this is the floor on
            // what was *compared*, not merely on whether the loop ran, and it is what keeps a
            // finding from being a free pass — a frame counted as a finding is a frame not counted
            // as round-tripped.
            XCTAssertEqual(roundTrips + opaqueByPair.values.reduce(0, +) + partial, lines.count, "\(name): frames went uncounted")
            XCTAssertGreaterThan(roundTrips, 0, "\(name): no frame was round-tripped")
            if !synthetic {
                XCTAssertEqual(partial, 0, "\(name) is recorded, so no frame may be excused as deliberately partial")
                XCTAssertEqual(roundTrips, lines.count, "\(name): every recorded line must decode typed and round-trip")
            }

            // The census names every pair it recorded. Requiring the sets to be equal means the
            // decoder was exercised on each one: a pass that skipped, say, every control_response
            // would fail here even though it round-tripped hundreds of other frames.
            let census = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: dir.appendingPathComponent("census.json")))
            let pairs = try XCTUnwrap(census["pairs"]?.objectValue, "\(name)/census.json has no pairs object")
            XCTAssertFalse(pairs.isEmpty, "\(name)/census.json records no pairs")
            // `census.py` excludes keep_alive from a census by construction, so a keep_alive frame
            // is the one pair allowed to be observed and absent from the census — and only when the
            // census does in fact omit it. Excusing the pair unconditionally would let the exclusion
            // stop being true without anything noticing.
            let observedPairs = Set(observedByPair.keys)
            if observedPairs.contains("keep_alive") {
                XCTAssertFalse(pairs.keys.contains("keep_alive"), "\(name): census.py excludes keep_alive, but this census records it")
            }
            XCTAssertEqual(observedPairs.subtracting(["keep_alive"]), Set(pairs.keys),
                           "\(name): pairs decoded do not match the census's pairs")

            // G2's count check, split in two because only one half is unconditionally sound.
            //
            // `opaqueByPair` counts frames opaque because nothing models their type or subtype; a
            // synthetic frame excused as a named finding is not one of those and is counted apart.
            //
            // The *set* comparison holds for every fixture. The *count* comparison does not: the
            // census's `count` accumulates across re-recordings (`census.merge_required` sums them),
            // so for a fixture recorded more than once it is a count of evidence, not of this file's
            // lines, and the first unmodelled pair to appear in one of those would fail this
            // assertion spuriously. The test decides for itself which censuses are single-run — the
            // census's total equals the fixture's line count — and compares counts only there.
            var expected: [String: Int] = [:]
            for (pair, entry) in pairs where !Self.isModelled(pair: pair) {
                expected[pair] = Int(entry["count"]?.intValue ?? 0)
            }
            XCTAssertEqual(Set(expected.keys), Set(opaqueByPair.keys), "\(name): census unmodelled pairs vs opaque pairs")
            let censusTotal = pairs.values.reduce(0) { $0 + Int($1["count"]?.intValue ?? 0) }
            if censusTotal == lines.count {
                XCTAssertEqual(expected, opaqueByPair, "\(name): census unmodelled counts vs opaque counts")
            } else {
                singleRunCensusMissing.append("\(name) (census totals \(censusTotal) against \(lines.count) lines)")
            }

            corpusLines += lines.count; corpusRoundTrips += roundTrips; corpusIn += inCount; corpusOut += outCount
        }

        XCTAssertGreaterThan(corpusRoundTrips, 0, "no frame in the whole corpus was round-tripped")
        XCTAssertEqual(corpusRoundTrips + findings.count, corpusLines, "every line is either round-tripped, opaque or a named finding")
        // The floor on the split itself. Exempting synthetic fixtures from "decodes typed" is only
        // safe while the exemption stays small and deliberate: a `fixture.json` that stopped parsing
        // would read every fixture as synthetic and turn the strict gate off everywhere without
        // failing anything.
        XCTAssertEqual(recordedFixtures, Self.committedRecordedFixtureCount,
                       "\(recordedFixtures) fixtures were treated as recorded; the corpus has \(Self.committedRecordedFixtureCount)")
        XCTAssertEqual(recordedFixtures + syntheticFixtures, dirs.count)
        if !singleRunCensusMissing.isEmpty {
            print("G2: counts compared by set only for \(singleRunCensusMissing.count) fixtures whose census accumulates across re-recordings: \(singleRunCensusMissing.sorted().joined(separator: ", "))")
        }

        print("G2: \(dirs.count) fixtures (\(recordedFixtures) recorded, \(syntheticFixtures) synthetic), \(corpusLines) frames (\(corpusIn) in, \(corpusOut) out), \(corpusRoundTrips) round-tripped")
        XCTAssertEqual(Set(findings.map(\.identity)), Self.expectedSyntheticFindings, """
            the set of synthetic frames that do not decode typed changed.
            \(Self.findingsPreamble)
            found:
            \(findings.map { "  - \($0)" }.sorted().joined(separator: "\n"))
            """)
        // Ten findings over ten distinct lines: the set above would also hold if one line produced two
        // findings and another none, which is not the corpus this describes.
        XCTAssertEqual(findings.count, Self.expectedSyntheticFindings.count)
    }
}
