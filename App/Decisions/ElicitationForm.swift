import Foundation
import ClaudeWire

/// The `requested_schema` of a form-mode elicitation, read into the controls a card can draw
/// (spec D8).
///
/// **The subset is stated, not guessed.** An object's properties of `string` (with `enum` becoming a
/// picker), `number`/`integer`, `boolean` and array-of-`string` are drawn as controls, because the
/// engine's own result type is `Record<string, string | number | boolean | string[]>`
/// (`cli.pretty.js:141932`) and those are exactly its inhabitants. Everything else — a nested
/// object, a `oneOf`, an array of non-strings — is a raw JSON field carrying the property's schema,
/// and the form says it is partial. A widening is a schema a real server sent, not a shape somebody
/// imagined.
struct ElicitationForm: Sendable, Hashable {

    struct Field: Sendable, Hashable, Identifiable {
        /// The property key, which is the key the result object is read back by.
        var name: String
        var title: String
        var description: String?
        var isRequired: Bool
        var control: Control
        var id: String { name }
    }

    enum Control: Sendable, Hashable {
        case text(default: String?)
        case picker(options: [String], default: String?)
        case number(isInteger: Bool, default: Double?)
        case toggle(default: Bool)
        /// Array of string. `options` is the item `enum` when the schema named one, and nil when the
        /// user types the values instead.
        ///
        /// `default` is **optional**, and the two empty cases it separates are different answers
        /// (scalpel-4#2): a property with no `default` starts unanswered, and one declaring
        /// `default: []` starts answered with "none of these". Collapsing them dropped a server's
        /// own explicit empty list out of `content`.
        case multiSelect(options: [String]?, default: [String]?)
        /// Outside the subset: the property's own schema, shown, and a JSON value typed by hand.
        case raw(schema: JSONValue)
    }

    /// In property-key order, so two renderings of one schema agree. JSON objects carry no order.
    var fields: [Field]

    /// True when any property fell outside the subset. The card says so rather than implying the
    /// form is the whole schema.
    var isPartial: Bool { fields.contains { if case .raw = $0.control { return true }; return false } }

    /// Nil for a schema that is not an object at all — a url-mode elicitation has no schema, and a
    /// schema of some other type has no properties to draw.
    ///
    /// **An object with no properties is a form.** It draws no control and its valid answer is the
    /// empty object, which is a thing the user can accept; refusing to build it left a request on
    /// screen with no way to answer it, and that is the one state §6.4 forbids.
    init?(_ schema: JSONValue?) {
        guard let schema else { return nil }
        let declared = schema["properties"]?.objectValue
        guard declared != nil || schema["type"]?.stringValue == "object" else { return nil }
        let properties = declared ?? [:]
        let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        fields = properties.keys.sorted().map { name in
            let property = properties[name] ?? .null
            return Field(name: name,
                         title: property["title"]?.stringValue ?? name,
                         description: property["description"]?.stringValue,
                         isRequired: required.contains(name),
                         control: Self.control(for: property))
        }
    }

    /// The keywords that compose a property out of other schemas. A property carrying one of them is
    /// not described by its `type` — the branches are — so it is outside the subset whatever the
    /// `type` says, and drawing a control from the `type` alone would drop the branches silently and
    /// leave the card claiming the form was whole.
    static let composition = ["oneOf", "anyOf", "allOf", "not"]

    private static func control(for property: JSONValue) -> Control {
        guard !Self.composition.contains(where: { property[$0] != nil }) else { return .raw(schema: property) }
        let fallback = property["default"]
        switch property["type"]?.stringValue {
        case "string":
            if let options = property["enum"]?.arrayValue?.compactMap(\.stringValue), !options.isEmpty {
                return .picker(options: options, default: fallback?.stringValue)
            }
            return .text(default: fallback?.stringValue)
        case "number":
            return .number(isInteger: false, default: fallback?.doubleValue)
        case "integer":
            return .number(isInteger: true, default: fallback?.doubleValue)
        case "boolean":
            return .toggle(default: fallback?.boolValue ?? false)
        case "array":
            guard let items = property["items"], items["type"]?.stringValue == "string"
            else { return .raw(schema: property) }
            let options = items["enum"]?.arrayValue?.compactMap(\.stringValue)
            return .multiSelect(options: (options?.isEmpty ?? true) ? nil : options,
                                default: fallback?.arrayValue?.compactMap(\.stringValue))
        default:
            return .raw(schema: property)
        }
    }

    /// Text typed into a numeric control as the JSON value an answer would carry, and nil when the
    /// card cannot carry it.
    static func numberValue(_ text: String, isInteger: Bool) -> JSONValue? {
        Double(text.trimmingCharacters(in: .whitespaces)).flatMap { numberValue($0, isInteger: isInteger) }
    }

    /// A parsed number as the JSON value an answer would carry.
    ///
    /// **The trapping conversion is never run on a number this card did not choose.**
    /// `Int64(_: Double)` traps on a non-finite value and on one outside `Int64`'s range, and every
    /// number reaching an integer control comes from the user's typing or a server's `default` —
    /// `1e20` and `nan` are legal to write in both places. A value that cannot be carried is refused
    /// with the field left empty, which is the same state as a field never filled in: absent from
    /// `content`, and a required field that cannot be accepted.
    static func numberValue(_ value: Double, isInteger: Bool) -> JSONValue? {
        guard value.isFinite else { return nil }
        guard isInteger else { return .number(value) }
        return int64(value).map(JSONValue.integer)
    }

    /// A double as an `Int64` when it is one, and nil when the conversion would trap.
    static func int64(_ value: Double) -> Int64? {
        guard value.isFinite, value >= -9223372036854775808.0, value < 9223372036854775808.0 else { return nil }
        return Int64(value)
    }

    /// A numeric control's text for a value: the integer spelling where the value is one, and
    /// nothing at all where the value could not be sent — so the field shows what an accept carries.
    static func spell(_ value: Double, isInteger: Bool) -> String {
        guard value.isFinite else { return "" }
        if isInteger { return int64(value).map(String.init) ?? "" }
        if value == value.rounded(), let exact = int64(value) { return String(exact) }
        return String(value)
    }

    /// What a field starts as, before the user touches anything.
    static func initialValue(_ control: Control) -> JSONValue? {
        switch control {
        case .text(let value): value.map(JSONValue.string)
        case .picker(_, let value): value.map(JSONValue.string)
        case .number(let isInteger, let value): value.flatMap { numberValue($0, isInteger: isInteger) }
        case .toggle(let value): .bool(value)
        // `[]` is a value here and `nil` is not: see `Control.multiSelect`.
        case .multiSelect(_, let value): value.map { .array($0.map(JSONValue.string)) }
        case .raw: nil
        }
    }

    /// The `content` an accept carries: one key per field the user gave a value for, as a sibling of
    /// `action` (anchor 10).
    ///
    /// **A null here was typed, so it stays.** An untouched field is absent because the card never
    /// puts a value in for it, not because nulls are filtered — and a raw field holding `null` is a
    /// property answered with the one value a nullable schema asks for. Filtering it made a required
    /// nullable property unanswerable and dropped an optional one without saying so.
    static func content(_ values: [String: JSONValue]) -> JSONValue {
        .object(values)
    }

    /// What a raw field's typed text is: nothing, a value, or a mistake.
    ///
    /// The raw field exists so that a schema outside the subset can still be answered (§6.4), and
    /// most such schemas accept a bare string — so text that is not JSON is carried as a string,
    /// which is what a user typing `an invented phrase` into a `oneOf` field means.
    ///
    /// **Text that was written as JSON and does not parse is a mistake, not a string**
    /// (scalpel-4#3). `{"a": 1` used to reach the server as the *literal text* `{"a": 1`, and a
    /// server asking for an object then received a string that looks like a half-typed one. The
    /// discriminator is the opening character, because that is what makes the intent unambiguous:
    /// `{`, `[` and `"` open the three JSON forms a bare word cannot be mistaken for, and nothing
    /// else can begin a JSON object, array or string.
    enum RawEntry: Sendable, Hashable {
        case empty
        case malformed
        case value(JSONValue)
    }

    /// The characters that begin a JSON object, array or string.
    static let jsonOpeners: Set<Character> = ["{", "[", "\""]

    static func rawEntry(_ text: String) -> RawEntry {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return .empty }
        if let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) { return .value(parsed) }
        return jsonOpeners.contains(first) ? .malformed : .value(.string(trimmed))
    }

    /// The one line a raw field shows: the property's schema, so the user can see what was asked for.
    static func schemaText(_ schema: JSONValue) -> String {
        (try? schema.canonicalData()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
