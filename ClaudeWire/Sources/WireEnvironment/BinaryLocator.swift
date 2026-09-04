import Foundation
import AfleetCore

public enum BinaryLocator {
    /// Settings override → first executable `claude` on the captured PATH → ~/.local/bin/claude → nil.
    public static func locate(in env: ResolvedEnvironment, override: URL?) -> URL? {
        let fm = FileManager.default
        if let override, fm.isExecutableFile(atPath: override.path) { return override }
        for dir in env.path {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("claude")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let home = env.variables["HOME"] ?? NSHomeDirectory()
        let local = URL(fileURLWithPath: home).appendingPathComponent(".local/bin/claude")
        return fm.isExecutableFile(atPath: local.path) ? local : nil
    }
}
