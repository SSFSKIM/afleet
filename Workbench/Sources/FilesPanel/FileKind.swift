import Foundation
import SourceControlCore

/// STUB — the declarations T2's suite is written against, before the decision exists.
/// Replaced in the next commit; here so the tests fail on their own assertions.
public enum FileKind: Equatable, Sendable {
    case code(language: String)
    case markdown
    case image
    case pdf
    case media
    case quickLook
    case binary

    public static let maximumReadableBytes = 0

    public static func of(url: URL, maximumBytes: Int = 0) -> FileKind { .binary }
}

/// STUB — see above.
public enum MonacoLanguage {
    public static let extensionMap: [String: String] = [:]
    public static let filenameMap: [String: String] = [:]
    public static func id(for url: URL) -> String { "" }
}
