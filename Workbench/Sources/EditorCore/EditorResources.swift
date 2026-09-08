import Foundation

/// The module's own resources, resolved through `Bundle.module`.
///
/// `Resources/bootstrap` is hand-written and `Resources/monaco` is generated; both are
/// declared `.copy`, so a web bundle's directory layout survives into the resource bundle
/// unrewritten and these are plain path joins rather than `url(forResource:)` lookups.
public enum EditorResources {

    /// The root the scheme handler serves, and the directory the file-URL route grants read
    /// access to. Both `monaco/` and `bootstrap/` sit directly inside it, which is why the
    /// served URL space is rooted here rather than at either of them.
    public static var resourceRootURL: URL? {
        Bundle.module.resourceURL
    }

    /// The generated Monaco bundle: the document entry, the five worker entries, the shared
    /// chunks, the stylesheets and the codicon font.
    public static var monacoDirectoryURL: URL? {
        resourceRootURL?.appendingPathComponent("monaco", isDirectory: true)
    }

    /// The directory `.copy` put the hand-written bootstrap in.
    public static var bootstrapDirectoryURL: URL? {
        resourceRootURL?.appendingPathComponent("bootstrap", isDirectory: true)
    }

    /// The document `MonacoEditorView` navigates to.
    public static var bootstrapDocumentURL: URL? {
        bootstrapDirectoryURL?.appendingPathComponent("index.html", isDirectory: false)
    }

    /// The editor-side half of the W4 bridge.
    public static var bridgeScriptURL: URL? {
        bootstrapDirectoryURL?.appendingPathComponent("bridge.js", isDirectory: false)
    }
}
