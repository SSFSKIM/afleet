import Foundation

public enum TestPaths: Sendable {
    /// ClaudeWire/Tests/Support, derived from this source file's location.
    public static var support: URL {
        URL(fileURLWithPath: #filePath)                       // .../ClaudeWire/Sources/WireTestSupport/TestPaths.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests").appendingPathComponent("Support")
    }
    public static var scriptedClaude: URL { support.appendingPathComponent("scripted-claude.py") }
    /// One sample line. The file on disk is newline-terminated like any text file; the terminator
    /// is trimmed here so the bytes match a line as it arrives on the wire, which is what
    /// `FrameDecoder.encode` promises to re-emit for an opaque frame.
    public static func sample(_ name: String) throws -> Data {
        var data = try Data(contentsOf: support.appendingPathComponent("Samples").appendingPathComponent("\(name).json"))
        if data.last == UInt8(ascii: "\n") { data.removeLast() }
        return data
    }
    public static func sampleNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("Samples").path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
}
