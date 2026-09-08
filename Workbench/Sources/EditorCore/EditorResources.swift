import Foundation

/// The module's own resources, resolved through `Bundle.module`.
///
/// `Resources/bootstrap` is hand-written and `Resources/monaco` is generated; both are
/// declared `.copy`, so a web bundle's directory layout survives into the resource bundle
/// unrewritten and these are plain path joins rather than `url(forResource:)` lookups.
public enum EditorResources {

    /// The directory `.copy` put the hand-written bootstrap in.
    public static var bootstrapDirectoryURL: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("bootstrap", isDirectory: true)
    }

    /// The editor-side half of the W4 bridge.
    public static var bridgeScriptURL: URL? {
        bootstrapDirectoryURL?.appendingPathComponent("bridge.js", isDirectory: false)
    }
}
