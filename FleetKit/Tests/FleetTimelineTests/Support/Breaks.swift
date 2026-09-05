import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

/// Deliberate, in-memory corruptions of a recorded sequence, so a gate test can be shown red without a fixture ever
/// changing on disk (parent §17.7's discriminating-test rule; C3 constraint: the corpus is never edited).
/// Every helper round-trips through `RecordDecoder`, so what a test compares is a real record, not a hand-built one.
enum Breaks {
    /// The sequence without the record at `index` — a mirror that lost a delivery.
    static func dropping(recordAt index: Int, from records: [TranscriptRecord]) -> [TranscriptRecord] {
        var out = records
        out.remove(at: index)
        return out
    }

    /// The record with the dotted `field` path set to `value` — a mirror that disagrees with the file about one field.
    /// Every path component must already exist and name an object, so a typo in a break is a failure, not a silent no-op.
    static func mutating(field: String, in record: TranscriptRecord, to value: JSONValue) throws -> TranscriptRecord {
        RecordDecoder.decode(entry: try set(field.split(separator: ".").map(String.init), in: try record.jsonValue(), to: value))
    }

    /// The record with its `type` rewritten — a kind the vocabulary never declared.
    static func renamingKind(of record: TranscriptRecord, to kind: String) throws -> TranscriptRecord {
        RecordDecoder.decode(entry: try set(["type"], in: try record.jsonValue(), to: .string(kind)))
    }

    private static func set(_ path: [String], in value: JSONValue, to new: JSONValue) throws -> JSONValue {
        guard let head = path.first else { return new }
        guard var object = value.objectValue, let child = object[head] else {
            throw FixtureCorpus.Failure("Breaks: the path component \(head) is not an object key of this record")
        }
        object[head] = try set(Array(path.dropFirst()), in: child, to: new)
        return .object(object)
    }
}
