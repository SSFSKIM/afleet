import Foundation

/// The bridge vocabulary of contract W4 — "this vocabulary and no other".
///
/// The wire is one flat tagged JSON object per message,
/// `{"type": "open", "path": …, "language": …, "text": …, "line": …}`, because the other
/// side is hand-written JavaScript that a Swift-shaped nested encoding would only make
/// harder to read (spec §5). Host-to-editor goes out through `evaluateJavaScript`;
/// editor-to-host arrives on the `WKScriptMessageHandler` named `afleet`.
///
/// The canonical spelling of the vocabulary is this file and the `bridge.js` it is tested
/// against. Consumers import it; nobody restates it.

// MARK: - Host to editor

public enum EditorCommand: Sendable, Hashable {
    /// Open `path` in `language` with `text`, optionally revealing `line`.
    case open(path: String, language: String, text: String, line: Int?)
    /// Replace the buffer's contents.
    case setText(text: String)
    /// Reveal `line`, optionally at `column`.
    case gotoLine(line: Int, column: Int?)
    /// A Monaco built-in theme name (`vs`, `vs-dark`, `hc-black`, `hc-light`).
    case setTheme(name: String)
    /// Show `original` against `modified` in the diff editor.
    case showDiff(path: String, original: String, modified: String, language: String)
    /// Ask the editor for the buffer; it answers with `saveRequested`.
    case save
}

extension EditorCommand: Codable {

    private enum CodingKeys: String, CodingKey {
        case type, path, language, text, line, column, name, original, modified
    }

    private enum MessageType: String {
        case open, setText, gotoLine, setTheme, showDiff, save
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let type = MessageType(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown EditorCommand type \(raw)")
        }
        switch type {
        case .open:
            self = .open(path: try container.decode(String.self, forKey: .path),
                         language: try container.decode(String.self, forKey: .language),
                         text: try container.decode(String.self, forKey: .text),
                         line: try container.decodeIfPresent(Int.self, forKey: .line))
        case .setText:
            self = .setText(text: try container.decode(String.self, forKey: .text))
        case .gotoLine:
            self = .gotoLine(line: try container.decode(Int.self, forKey: .line),
                             column: try container.decodeIfPresent(Int.self, forKey: .column))
        case .setTheme:
            self = .setTheme(name: try container.decode(String.self, forKey: .name))
        case .showDiff:
            self = .showDiff(path: try container.decode(String.self, forKey: .path),
                             original: try container.decode(String.self, forKey: .original),
                             modified: try container.decode(String.self, forKey: .modified),
                             language: try container.decode(String.self, forKey: .language))
        case .save:
            self = .save
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .open(path, language, text, line):
            try container.encode(MessageType.open.rawValue, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(language, forKey: .language)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(line, forKey: .line)
        case let .setText(text):
            try container.encode(MessageType.setText.rawValue, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .gotoLine(line, column):
            try container.encode(MessageType.gotoLine.rawValue, forKey: .type)
            try container.encode(line, forKey: .line)
            try container.encodeIfPresent(column, forKey: .column)
        case let .setTheme(name):
            try container.encode(MessageType.setTheme.rawValue, forKey: .type)
            try container.encode(name, forKey: .name)
        case let .showDiff(path, original, modified, language):
            try container.encode(MessageType.showDiff.rawValue, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(original, forKey: .original)
            try container.encode(modified, forKey: .modified)
            try container.encode(language, forKey: .language)
        case .save:
            try container.encode(MessageType.save.rawValue, forKey: .type)
        }
    }
}

// MARK: - Editor to host

public enum EditorEvent: Sendable, Hashable {
    /// The editor is constructed and will accept commands.
    case ready
    /// The buffer's modified flag changed.
    case dirty(path: String, isDirty: Bool)
    /// The answer to `save`: the buffer as it stands.
    case saveRequested(path: String, text: String)
    /// The primary cursor moved.
    case cursor(line: Int, column: Int)
    /// Something the editor could not do. The host decides what to show.
    case error(message: String)
}

extension EditorEvent: Codable {

    private enum CodingKeys: String, CodingKey {
        case type, path, isDirty, text, line, column, message
    }

    private enum MessageType: String {
        case ready, dirty, saveRequested, cursor, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let type = MessageType(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown EditorEvent type \(raw)")
        }
        switch type {
        case .ready:
            self = .ready
        case .dirty:
            self = .dirty(path: try container.decode(String.self, forKey: .path),
                          isDirty: try container.decode(Bool.self, forKey: .isDirty))
        case .saveRequested:
            self = .saveRequested(path: try container.decode(String.self, forKey: .path),
                                  text: try container.decode(String.self, forKey: .text))
        case .cursor:
            self = .cursor(line: try container.decode(Int.self, forKey: .line),
                           column: try container.decode(Int.self, forKey: .column))
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready:
            try container.encode(MessageType.ready.rawValue, forKey: .type)
        case let .dirty(path, isDirty):
            try container.encode(MessageType.dirty.rawValue, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(isDirty, forKey: .isDirty)
        case let .saveRequested(path, text):
            try container.encode(MessageType.saveRequested.rawValue, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
        case let .cursor(line, column):
            try container.encode(MessageType.cursor.rawValue, forKey: .type)
            try container.encode(line, forKey: .line)
            try container.encode(column, forKey: .column)
        case let .error(message):
            try container.encode(MessageType.error.rawValue, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
