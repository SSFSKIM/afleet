import Foundation
import AfleetCore

public enum BinaryLocator {
    /// Settings override → first executable `claude` on the captured PATH → ~/.local/bin/claude → nil.
    public static func locate(in env: ResolvedEnvironment, override: URL?) -> URL? {
        if let override, isRunnable(override) { return override }
        for dir in env.path {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("claude")
            if isRunnable(candidate) { return candidate }
        }
        let home = env.variables["HOME"] ?? NSHomeDirectory()
        let local = URL(fileURLWithPath: home).appendingPathComponent(".local/bin/claude")
        return isRunnable(local) ? local : nil
    }

    /// `isExecutableFile` is true of any searchable directory, so a directory named `claude` on the PATH
    /// would otherwise be handed back as the binary.
    private static func isRunnable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return fm.isExecutableFile(atPath: url.path)
    }
}
