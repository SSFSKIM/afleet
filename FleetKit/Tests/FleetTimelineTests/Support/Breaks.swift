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

    /// The record with the dotted `path` set, where the last component may be a key the recorded shape never carried
    /// and any component may be an array index. A sibling of `mutating(field:in:to:)`, which names object keys only
    /// and requires every component to exist already; appended here (Task 5) so a mutation test can add a field the
    /// engine writes but no fixture does — a `system` subtype, a `supersedes` list, an explicit `leafUuid` null.
    static func setting(path: String, in record: TranscriptRecord, to value: JSONValue) throws -> TranscriptRecord {
        RecordDecoder.decode(entry: try put(path.split(separator: ".").map(String.init), in: try record.jsonValue(), to: value))
    }

    private static func put(_ path: [String], in value: JSONValue, to new: JSONValue) throws -> JSONValue {
        guard let head = path.first else { return new }
        let rest = Array(path.dropFirst())
        if var object = value.objectValue {
            object[head] = try put(rest, in: object[head] ?? .object([:]), to: new)
            return .object(object)
        }
        if var array = value.arrayValue, let index = Int(head), array.indices.contains(index) {
            array[index] = try put(rest, in: array[index], to: new)
            return .array(array)
        }
        throw FixtureCorpus.Failure("Breaks: the path component \(head) names neither an object key nor a live array index")
    }
}
