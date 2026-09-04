import Foundation

public enum ProtocolBaseline {
    public static let version = "2.1.259"
    public static let afleetVersion = "0.1.0"
    public static var baseline: SemanticVersion { SemanticVersion(parsing: version)! }
}

public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public init(major: Int, minor: Int, patch: Int) { self.major = major; self.minor = minor; self.patch = patch }
    /// Parses the leading dotted version of a string such as "2.1.259 (Claude Code)" or "3.0.0-beta.1".
    public init?(parsing s: String) {
        let head = s.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isNumber || $0 == "." }
        let parts = head.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        self.init(major: parts[0], minor: parts[1], patch: parts[2])
    }
    public var description: String { "\(major).\(minor).\(patch)" }
    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
}

public enum VersionVerdict: Sendable { case accepted(SemanticVersion), tooOld(installed: SemanticVersion, baseline: SemanticVersion), unparseable(output: String) }

public struct VersionGate: Sendable {
    public let runner: any ProcessRunner
    public init(runner: any ProcessRunner = FoundationProcessRunner()) { self.runner = runner }
    public func check(binary: URL) async -> VersionVerdict {
        let out = (try? await runner.run(binary, arguments: ["--version"], environment: ProcessInfo.processInfo.environment, timeout: .seconds(10)))
        let text = String(decoding: out?.stdout ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let installed = SemanticVersion(parsing: text) else { return .unparseable(output: text) }
        return installed < ProtocolBaseline.baseline ? .tooOld(installed: installed, baseline: ProtocolBaseline.baseline) : .accepted(installed)
    }
}
