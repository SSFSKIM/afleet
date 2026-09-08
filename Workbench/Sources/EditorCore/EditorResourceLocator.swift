import Foundation

/// The pure half of the `afleet-editor` scheme handler: a request path in, a file URL and a
/// MIME type out, or a refusal.
///
/// It is separate from `EditorSchemeHandler` because it is the only half that can be wrong in a
/// way a test can witness. The handler around it opens a file and hands bytes to WebKit; this
/// decides *which* file, and "which file" is where a traversal (`../../../etc/passwd`, or the
/// same thing percent-encoded) would get served if the containment rule were merely implied by
/// `URL`'s own normalisation rather than asserted.
///
/// The rule is **fail closed**: a path that does not resolve strictly inside the resource root
/// is refused, and refusal is the default outcome of anything unexpected. Nothing here touches
/// the filesystem except to canonicalise symlinks, so it is testable without a bundle.
struct EditorResourceLocator: Sendable {

    /// Why a request was refused. `notFound` is the handler's, not this type's, but it lives
    /// here so the scheme task has one error vocabulary to report.
    enum Failure: Error, Equatable {
        /// The path had no usable components at all (`/`, or empty).
        case emptyPath
        /// The path resolved outside the resource root, or tried to.
        case escapesRoot
        /// The path resolved inside the root but names nothing that exists.
        case notFound
    }

    /// The directory every served file must live under: `Bundle.module`'s resource root, which
    /// `.copy` fills with `monaco/` and `bootstrap/`.
    let root: URL

    /// The root reduced to the form containment is checked against: symlinks resolved, `.` and
    /// `..` removed. Computed once, because every request compares against it.
    private let canonicalRootPath: String

    init(root: URL) {
        self.root = root
        self.canonicalRootPath = Self.canonicalPath(of: root)
    }

    /// Resolve a request URL's path against the root.
    ///
    /// The host is deliberately ignored: the bundle is a single origin and the host component
    /// carries no information the path does not. What matters is that whatever the path spells,
    /// the answer is inside the root or there is no answer.
    func fileURL(forRequestPath requestPath: String) throws -> URL {
        // `URL.path` percent-decodes already; decoding again is defensive against a caller that
        // passes the raw string. A literal `%` makes the second decode fail, which is why the
        // original is kept rather than the refusal being made from a decoding failure.
        let decoded = requestPath.removingPercentEncoding ?? requestPath

        // A NUL truncates a C string somewhere below Foundation; refuse rather than find out.
        guard !decoded.contains("\0") else { throw Failure.escapesRoot }

        let components = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let meaningful = components.filter { $0 != "." }
        guard !meaningful.isEmpty else { throw Failure.emptyPath }

        // The literal refusal, before any normalisation can make a traversal look innocent.
        // `foo/../bar` inside the root would be harmless; it is still refused, because a
        // legitimate request from the bundle never contains one and narrowing the rule to
        // "escaping traversals only" buys nothing but a way to be wrong.
        guard !meaningful.contains("..") else { throw Failure.escapesRoot }

        var candidate = root
        for component in meaningful {
            candidate.appendPathComponent(component)
        }

        // And the containment check itself, which is what catches a traversal that arrived by
        // some spelling the component scan did not anticipate — an encoded separator, or a
        // symlink inside the bundle pointing out of it.
        let canonical = Self.canonicalPath(of: candidate)
        guard canonical == canonicalRootPath || canonical.hasPrefix(canonicalRootPath + "/") else {
            throw Failure.escapesRoot
        }

        return URL(fileURLWithPath: canonical)
    }

    /// Resolve, then require the file to exist and be a regular file. Directories are refused:
    /// there is no index-of behaviour and a directory read would hand WebKit nonsense.
    func existingFileURL(forRequestPath requestPath: String) throws -> URL {
        let url = try fileURL(forRequestPath: requestPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { throw Failure.notFound }
        return url
    }

    private static func canonicalPath(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - MIME types

    /// The MIME type a file is served with, by extension.
    ///
    /// Only the types the committed bundle actually contains have to be right, and getting one
    /// of them wrong is not a subtle failure: WebKit refuses a module script that is not
    /// JavaScript and drops a stylesheet that is not `text/css`, so the editor simply does not
    /// come up. Anything unrecognised is served as an opaque byte stream rather than refused —
    /// a wrong guess here should not be able to hide a file that exists.
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js", "mjs", "cjs": return "text/javascript"
        case "css": return "text/css"
        case "html", "htm": return "text/html"
        case "json", "map": return "application/json"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    /// The encoding name that accompanies the MIME type, or `nil` for binary payloads. The
    /// bundle is UTF-8 throughout; a font is not text at all.
    static func textEncodingName(forMIMEType mimeType: String) -> String? {
        if mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType == "image/svg+xml" {
            return "utf-8"
        }
        return nil
    }
}
