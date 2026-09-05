import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// Spec G1, check one: the mirror is the file. Whatever the engine delivered on `transcript_mirror` during a recording
/// equals what the paired transcript file gained during that same recording — first by record identity in order, then
/// field for field, with only the fixture's own `mirror_identity_only` declarations excused.
final class MirrorFidelityTests: XCTestCase {
    /// Identity sequences equal exactly per stream after the declared unmirrored prefix; fields equal except at declared
    /// paths; `agent_metadata` entries equal the `.meta.json`; the mirrored-fixture set equals the pinned set. No fixture
    /// is excluded, and the three totals at the end are exact equalities, so a stream or a record that stopped being
    /// compared fails here rather than passing quietly.
    func testMirroredEntriesEqualTheAppendedFileRecordsOnEveryFixture() throws {
        var mirroredNames: Set<String> = []
        var streamsCompared = 0
        var recordsCompared = 0
        var metadataCompared = 0
        for fx in try FixtureCorpus.all() {
            let mirrored = try MirrorReplay.mirroredStreams(fx)
            if mirrored.isEmpty { continue }
            mirroredNames.insert(fx.name)
            let files = try MirrorReplay.appendedFileRecords(fx)
            let mask = IdentityMask(scopes: fx.identityOnly)
            var prefixSkipped = 0
            for (stream, entries) in mirrored.sorted(by: { $0.key.name.label < $1.key.name.label }) {
                let conversation = entries.filter { if case .agentMetadata = $0 { return false }; return true }
                guard let (fileRecords, url) = files[stream] else {
                    XCTFail("\(fx.name): mirror names a stream with no file: \(stream.name.label)"); continue
                }
                XCTAssertFalse(conversation.isEmpty && fileRecords.isEmpty,
                               "\(fx.name)/\(stream.name.label): a mirrored stream compared nothing at all")
                // The unmirrored prefix is at the head of the appended range and only on the main stream (spec Grounding; verify.py).
                var expected = fileRecords
                if case .main = stream.name, fx.unmirroredPrefix > 0 {
                    XCTAssertGreaterThanOrEqual(expected.count, fx.unmirroredPrefix,
                                                "\(fx.name)/\(stream.name.label): the appended range is shorter than the declared unmirrored prefix")
                    expected.removeFirst(min(fx.unmirroredPrefix, expected.count))
                    prefixSkipped += fx.unmirroredPrefix
                }
                // Both sequences are numbered from the same start, so occurrence ordinals agree wherever the hashes do.
                XCTAssertEqual(RecordKey.keys(for: conversation, in: stream), RecordKey.keys(for: expected, in: stream),
                               "\(fx.name)/\(stream.name.label): mirrored identity sequence differs from the file's appended range")
                let allowed = mask.allowed(for: stream, path: url)
                for (m, f) in zip(conversation, expected) {
                    let diff = IdentityMask.unmasked(IdentityMask.differingPaths(try m.jsonValue(), try f.jsonValue()), allowed: allowed)
                    XCTAssertTrue(diff.isEmpty, "\(fx.name)/\(stream.name.label): \(m.kind) differs at \(diff.sorted()) — not declared identity-only")
                    recordsCompared += 1
                }
                // `agent_metadata` has no file line: the mirror writes the sidecar's body with `type` added (Task 1's hash proof).
                for entry in entries {
                    guard case .agentMetadata = entry else { continue }
                    guard case .agent(let task) = stream.name else {
                        XCTFail("\(fx.name): agent_metadata on the main stream"); continue
                    }
                    let sidecar = try (try fx.metaFiles().first { $0.0 == stream })
                        .map { try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: $0.1)) }
                    XCTAssertNotNil(sidecar, "\(fx.name): no .meta.json for agent \(task)")
                    var body = try entry.jsonValue().objectValue ?? [:]
                    body["type"] = nil
                    XCTAssertTrue(JSONValue.object(body).numericallyEqual(sidecar ?? .null),
                                  "\(fx.name): agent_metadata differs from .meta.json for \(task)")
                    metadataCompared += 1
                }
                streamsCompared += 1
            }
            XCTAssertEqual(prefixSkipped, fx.unmirroredPrefix, "\(fx.name): unmirrored_prefix \(fx.unmirroredPrefix) declared, \(prefixSkipped) used")
        }
        XCTAssertEqual(mirroredNames, FixtureCorpus.mirrored)
        // 17 main streams, plus one agent stream in explore-depth-1 and two in nested-depth-2; the relocation's one stream
        // under two `filePath` values is counted once and adds nothing, which is what makes a path an alias and not an identity.
        XCTAssertEqual(streamsCompared, 20)
        // The census of 2026-09-06 (twenty fixtures): 521 mirrored entries, of which 3 are `agent_metadata`, leaves 518
        // compared against file records.
        XCTAssertEqual(recordsCompared, 518)
        XCTAssertEqual(metadataCompared, 3)
    }
}
