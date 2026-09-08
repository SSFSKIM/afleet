import Foundation
import WebKit

/// Serves `Bundle.module`'s resource root — `monaco/` and `bootstrap/` — over the
/// `afleet-editor` scheme (spec Design §6; contract W4 leaves the scheme name advisory).
///
/// Three kinds of request arrive here, and the third is the one the split build added:
///
/// 1. the document, `bootstrap/index.html`, and its stylesheet;
/// 2. the module entry `monaco/editor.js` and the five worker entries;
/// 3. **shared chunks fetched from inside a worker context** — `bun build --splitting` left
///    `editor.worker.js` a 156-byte shim that `import`s them, so a request for a chunk can
///    originate from a module worker rather than from the document. Nothing here distinguishes
///    the two, which is the point: the origin of the request does not change which file it names.
///
/// Files are memory-mapped rather than read, so a 2.3 MB chunk costs a mapping and not a copy on
/// the main thread.
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The scheme the configuration registers this handler for.
    static let scheme = "afleet-editor"

    /// The host every generated URL uses. It is not checked on the way in — the path is what
    /// selects a file — but it has to be *some* host for the URLs to be same-origin.
    static let host = "bundle"

    private let locator: EditorResourceLocator

    init(root: URL) {
        self.locator = EditorResourceLocator(root: root)
    }

    /// The URL a request for `relativePath` inside the resource root is spelled as.
    static func url(forResourcePath relativePath: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = relativePath.hasPrefix("/") ? relativePath : "/" + relativePath
        // The components above are all well-formed by construction; a failure here would be a
        // programming error in this file rather than anything a caller can provoke.
        return components.url!
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(EditorResourceLocator.Failure.emptyPath)
            return
        }

        do {
            let fileURL = try locator.existingFileURL(forRequestPath: url.path)
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let mimeType = EditorResourceLocator.mimeType(for: fileURL)

            let response = URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: EditorResourceLocator.textEncodingName(forMIMEType: mimeType)
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            // A refusal and a missing file present identically to the page: the load fails. The
            // distinction is kept in the error for the Web Inspector and for S3.
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Every task above completes synchronously inside `start`, so by the time WebKit can ask
        // for a stop there is nothing outstanding to cancel.
    }
}
