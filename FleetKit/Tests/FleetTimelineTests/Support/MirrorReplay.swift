import Foundation
import XCTest
import AfleetCore
import ClaudeWire
@testable import FleetTimeline

extension TranscriptRecord {
    /// The record's lossless JSON. `RecordDecoder.encode` is the one re-encoding path, so a mirror entry and the file
    /// line it mirrors, having decoded through the same decoder, encode to the same value when they carry the same content.
    func jsonValue() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: RecordDecoder.encode(self))
    }
}

/// Replays a recording's `transcript_mirror` frames and the paired transcript files into the two sequences check one
/// compares. Nothing here writes, and nothing here is asserted against a literal fixture byte.
enum MirrorReplay {
    /// Mirror entries per stream, in frame order. `filePath` resolves under the recorded config home; the stream — not the
    /// path — is the key, which is what makes the relocation fixture one stream under two paths.
    static func mirroredStreams(_ fx: FixtureCorpus.Fixture) throws -> [LogicalStream: [TranscriptRecord]] {
        var out: [LogicalStream: [TranscriptRecord]] = [:]
        for f in try fx.frames() {
            guard case .transcriptMirror(let m) = f.frame,
                  let (stream, _) = TranscriptPath.resolve(URL(fileURLWithPath: m.filePath), under: FixtureCorpus.recordedConfigHome)
            else { continue }
            out[stream, default: []].append(contentsOf: m.entries.map(RecordDecoder.decode(entry:)))
        }
        return out
    }

    /// File records in the appended range: from the stream's `streams.json` offset to end of file.
    static func appendedFileRecords(_ fx: FixtureCorpus.Fixture) throws -> [LogicalStream: (records: [TranscriptRecord], url: URL)] {
        var out: [LogicalStream: (records: [TranscriptRecord], url: URL)] = [:]
        for (stream, _, url) in try fx.transcriptFiles() {
            out[stream] = (try TranscriptReader(url: url).readAppended(from: fx.offset(for: url)).records, url)
        }
        return out
    }
}

/// `mirror_identity_only`: scope → field paths that may differ. A scope matches a stream when the stream's file path
/// contains it, so `"subagents/"` names every agent stream of the fixture that declared it.
struct IdentityMask {
    let scopes: [String: [String]]

    /// The declared paths for this stream. The stream is part of the signature because a scope is a statement about a
    /// stream's identity; today every declared scope is decided by the path alone.
    func allowed(for stream: LogicalStream, path: URL) -> Set<String> {
        var out: Set<String> = []
        for (scope, paths) in scopes where path.path.contains(scope) { out.formUnion(paths) }
        _ = stream
        return out
    }

    /// The dotted paths at which two lossless-encoded JSON values differ. A key present on one side only is reported at
    /// its own path rather than recursed into; arrays of unequal length are reported whole, since index-wise paths would
    /// name positions that do not correspond.
    static func differingPaths(_ a: JSONValue, _ b: JSONValue, prefix: String = "") -> Set<String> {
        func step(_ prefix: String, _ key: String) -> String { prefix.isEmpty ? key : prefix + "." + key }
        switch (a, b) {
        case (.object(let x), .object(let y)):
            var out: Set<String> = []
            for key in Set(x.keys).union(y.keys) {
                guard let l = x[key], let r = y[key] else { out.insert(step(prefix, key)); continue }
                out.formUnion(differingPaths(l, r, prefix: step(prefix, key)))
            }
            return out
        case (.array(let x), .array(let y)) where x.count == y.count:
            var out: Set<String> = []
            for (i, pair) in zip(x, y).enumerated() { out.formUnion(differingPaths(pair.0, pair.1, prefix: step(prefix, String(i)))) }
            return out
        default:
            return a.numericallyEqual(b) ? [] : [prefix]
        }
    }

    /// The differing paths the mask does not excuse. A declared path covers itself and everything beneath it: declaring
    /// `message.usage` declares the object, so a difference at `message.usage.output_tokens` is inside the declaration.
    static func unmasked(_ differing: Set<String>, allowed: Set<String>) -> Set<String> {
        differing.filter { path in !allowed.contains { path == $0 || path.hasPrefix($0 + ".") } }
    }
}
