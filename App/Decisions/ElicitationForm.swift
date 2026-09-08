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
        case multiSelect(options: [String]?, default: [String])
        /// Outside the subset: the property's own schema, shown, and a JSON value typed by hand.
        case raw(schema: JSONValue)
    }

    /// In property-key order, so two renderings of one schema agree. JSON objects carry no order.
    var fields: [Field]

    /// True when any property fell outside the subset. The card says so rather than implying the
    /// form is the whole schema.
    var isPartial: Bool { fields.contains { if case .raw = $0.control { return true }; return false } }

    /// Nil for a schema that is not an object with properties — a url-mode elicitation has no schema
    /// at all, and a form with no field is not a form.
    init?(_ schema: JSONValue?) {
        guard let schema, let properties = schema["properties"]?.objectValue, !properties.isEmpty else { return nil }
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

    private static func control(for property: JSONValue) -> Control {
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
            guard let items = property["items"], items["type"]?.stringValue == "string",
                  property["oneOf"] == nil else { return .raw(schema: property) }
            let options = items["enum"]?.arrayValue?.compactMap(\.stringValue)
            return .multiSelect(options: (options?.isEmpty ?? true) ? nil : options,
                                default: fallback?.arrayValue?.compactMap(\.stringValue) ?? [])
        default:
            return .raw(schema: property)
        }
    }

    /// What a field starts as, before the user touches anything.
    static func initialValue(_ control: Control) -> JSONValue? {
        switch control {
        case .text(let value): value.map(JSONValue.string)
        case .picker(_, let value): value.map(JSONValue.string)
        case .number(let isInteger, let value): value.map { isInteger ? .integer(Int64($0)) : .number($0) }
        case .toggle(let value): .bool(value)
        case .multiSelect(_, let value): value.isEmpty ? nil : .array(value.map(JSONValue.string))
        case .raw: nil
        }
    }

    /// The `content` an accept carries: one key per field the user gave a value for, as a sibling of
    /// `action` (anchor 10). A field left empty is absent rather than null, because a null is an
    /// answer and an untouched optional field is not.
    static func content(_ values: [String: JSONValue]) -> JSONValue {
        .object(values.filter { $0.value != .null })
    }

    /// A raw field's typed text as JSON, and as a string when it does not parse. The point of the
    /// raw field is that a schema outside the subset can still be answered (§6.4).
    static func rawValue(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) { return parsed }
        return .string(trimmed)
    }

    /// The one line a raw field shows: the property's schema, so the user can see what was asked for.
    static func schemaText(_ schema: JSONValue) -> String {
        (try? schema.canonicalData()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
