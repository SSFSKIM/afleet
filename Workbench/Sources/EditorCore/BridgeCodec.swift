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

/// The six `type` strings of W4's host-to-editor half, named once so the JSON encoder and the
/// bridged-object encoder below cannot drift apart.
fileprivate enum EditorCommandType: String {
    case open, setText, gotoLine, setTheme, showDiff, save
}

extension EditorCommand: Codable {

    private enum CodingKeys: String, CodingKey {
        case type, path, language, text, line, column, name, original, modified
    }

    fileprivate typealias MessageType = EditorCommandType

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

// MARK: - Host to editor, as WebKit marshals it

extension EditorCommand {

    /// The same six messages as the object `callAsyncJavaScript` marshals into the page.
    ///
    /// The wire is unchanged — `bridge.js` reads the same flat tagged shape off the same field
    /// names — but the buffer never becomes JavaScript source on the way there. Handed to
    /// `evaluateJavaScript` a command carrying a file had to be encoded, escaped into a string
    /// literal and concatenated into a script WebKit then parsed as source; handed to
    /// `callAsyncJavaScript` as an argument it is marshalled as data. A test asserts this object
    /// is field-for-field what the encoder above produces, so the two cannot drift.
    var bridgedObject: [String: Any] {
        switch self {
        case let .open(path, language, text, line):
            var object: [String: Any] = [
                "type": MessageType.open.rawValue, "path": path, "language": language, "text": text,
            ]
            if let line { object["line"] = line }
            return object
        case let .setText(text):
            return ["type": MessageType.setText.rawValue, "text": text]
        case let .gotoLine(line, column):
            var object: [String: Any] = ["type": MessageType.gotoLine.rawValue, "line": line]
            if let column { object["column"] = column }
            return object
        case let .setTheme(name):
            return ["type": MessageType.setTheme.rawValue, "name": name]
        case let .showDiff(path, original, modified, language):
            return [
                "type": MessageType.showDiff.rawValue, "path": path,
                "original": original, "modified": modified, "language": language,
            ]
        case .save:
            return ["type": MessageType.save.rawValue]
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

/// The five `type` strings of W4's editor-to-host half, named once so the JSON decoder and the
/// bridged-object decoder below cannot drift apart.
fileprivate enum EditorEventType: String {
    case ready, dirty, saveRequested, cursor, error
}

extension EditorEvent: Codable {

    private enum CodingKeys: String, CodingKey {
        case type, path, isDirty, text, line, column, message
    }

    fileprivate typealias MessageType = EditorEventType

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

// MARK: - Editor to host, as WebKit bridges it

extension EditorEvent {

    /// The same five messages, read straight out of the object a `WKScriptMessageHandler`
    /// receives — an `NSDictionary` of `NSString`s and `NSNumber`s, already parsed by WebKit.
    ///
    /// It lives beside the `Codable` conformance because the shapes must not be stated twice:
    /// the fields, their names and their optionality are the ones above, and the two routes are
    /// tested against each other message by message. What it buys is `saveRequested`, which
    /// carries a whole file: the JSON route serialises that buffer back out and parses it again,
    /// on the main actor, for nothing (spec Revision Note of 2026-09-08).
    init?(bridgedObject object: [String: Any]) {
        guard let raw = object["type"] as? String, let type = EditorEventType(rawValue: raw) else {
            return nil
        }
        switch type {
        case .ready:
            self = .ready
        case .dirty:
            guard let path = object["path"] as? String,
                  let isDirty = object["isDirty"] as? Bool
            else { return nil }
            self = .dirty(path: path, isDirty: isDirty)
        case .saveRequested:
            guard let path = object["path"] as? String,
                  let text = object["text"] as? String
            else { return nil }
            self = .saveRequested(path: path, text: text)
        case .cursor:
            guard let line = object["line"] as? Int,
                  let column = object["column"] as? Int
            else { return nil }
            self = .cursor(line: line, column: column)
        case .error:
            guard let message = object["message"] as? String else { return nil }
            self = .error(message: message)
        }
    }
}
