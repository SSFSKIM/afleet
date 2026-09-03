import Foundation

public enum TestPaths {
    /// ClaudeWire/Tests/Support, derived from this source file's location.
    public static var support: URL {
        URL(fileURLWithPath: #filePath)                       // .../ClaudeWire/Sources/WireTestSupport/TestPaths.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests").appendingPathComponent("Support")
    }
    public static var scriptedClaude: URL { support.appendingPathComponent("scripted-claude.py") }
    public static func sample(_ name: String) throws -> Data {
        try Data(contentsOf: support.appendingPathComponent("Samples").appendingPathComponent("\(name).json"))
    }
    public static func sampleNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent("Samples").path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
}
