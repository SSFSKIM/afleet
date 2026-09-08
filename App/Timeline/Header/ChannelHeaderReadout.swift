import Foundation
import AfleetCore
import ClaudeWire
import FleetKit

// MARK: - The readout

/// The five things the channel header reads back (child spec §10): the branch, the model, the
/// permission mode, the effort and the context meter.
///
/// **A value, not a set of accessors on a view.** The same reason `ChannelHeader` is one: what a
/// test asserts on is what the view draws, and there is no second derivation to disagree with the
/// first. `HeaderReadoutView` renders this and computes nothing of its own.
///
/// **Every field here is an engine readback or an index fact — never a value this app last asked
/// for.** That is gate G4's discriminating clause and the reason the type has no writable input
/// besides the two `apply` calls below: a picker's click is a request, the answer is what is true of
/// the process, and `apply_flag_settings` answers with no body at all (`control-shapes`), so a
/// header that echoed the click would be showing something the engine may simply have refused.
struct ChannelHeaderReadout: Hashable, Sendable {

    /// `ChannelRow.gitBranch`, which C3's index reads from the transcript's own `gitBranch` field.
    /// No control request, and the one readback an archived channel still carries.
    var branch: String?

    /// `get_settings.applied.model` — the canonical id the engine resolved, not the alias asked for.
    var model: String?

    /// The engine's own report of the mode it is running.
    ///
    /// **From the handshake, and this is not the source §10 names.** The child spec says model, mode
    /// and effort all come from `get_settings`; the engine does not report the mode there. Its
    /// `get_settings` answer is `{applied: {model, effort, advisor, ultracode}, effective, sources}`
    /// (2.1.257 `cli.pretty.js:178217`, and both recordings that carry the subtype — `control-shapes`
    /// and `zero-cost`), where `effective` is the merged *settings files*, so a mode read out of it
    /// would be what a file asks for and not what the process is running. `InitializeResponse`'s
    /// `current_permission_mode` is the readback the engine offers, which is what
    /// `Readback.verify` compares a restart against and what C6.2's picker displays. Reported to the
    /// leaf owner; see the task report.
    var mode: PermissionMode?

    /// `get_settings.applied.effort`, falling back to the `effortLevel` the answer's `effective` map
    /// carries. Nil is a value and not an absence: the engine reports `null` for the default.
    var effort: String?

    /// `get_context_usage`. Nil until the first answer — **nothing pushes this** (parity §41.15.4:
    /// `autocompact_state` is emitted only under `CLAUDE_CODE_REMOTE`), so it is polled after each
    /// `result` frame and never on a timer.
    var context: ContextUsage?

    /// True while the engine has answered nothing at all. What an archived channel looks like: the
    /// branch alone.
    var isEngineSilent: Bool { model == nil && mode == nil && effort == nil && context == nil }

    /// Folds one `get_settings` answer in. Whole-value, because the answer is the truth about the
    /// process: a field the engine now reports as absent is absent here too.
    mutating func apply(_ settings: SettingsReadback) {
        model = settings.model
        effort = settings.effort
        // The mode comes from a second report, and a channel whose retained handshake is not
        // available yet must not blank a mode an earlier one gave.
        if let mode = settings.mode { self.mode = mode }
    }
}

// MARK: - The `get_settings` answer

/// What one `get_settings` answer and the channel's handshake say about model, effort and mode.
///
/// Parsed here rather than in the poller so the parse is a pure function of two engine reports and a
/// test can hand it a replayed answer without a lifecycle at all.
struct SettingsReadback: Hashable, Sendable {
    var model: String?
    var effort: String?
    var mode: PermissionMode?

    /// `answer` is the `get_settings` body; `handshake` is the channel's retained
    /// `InitializeResponse`, and nil when the fleet has none for this channel.
    init(answer: JSONValue, handshake: InitializeResponse?) {
        let applied = answer["applied"]
        model = applied?["model"]?.stringValue
        // `applied.effort` is the effort the engine resolved and the value `Readback.verify`
        // compares a restart against; `effective.effortLevel` is the flag setting a host applied,
        // which is the only one of the two `control-shapes` carries after an `apply_flag_settings`.
        effort = applied?["effort"]?.stringValue ?? answer["effective"]?["effortLevel"]?.stringValue
        mode = handshake?.currentPermissionMode
    }
}

// MARK: - The context meter

/// The `get_context_usage` answer, as the meter draws it.
///
/// The recorded shape is `zero-cost`'s: `percentage`, `totalTokens`, `maxTokens`, `rawMaxTokens`,
/// `autoCompactThreshold`, `isAutoCompactEnabled`, `autocompactSource` and a per-category
/// breakdown, plus a `gridRows` pre-render for the TUI's own squares that this app does not draw.
struct ContextUsage: Hashable, Sendable {

    /// One row of the answer's `categories`. The engine's colour names are the TUI's palette keys
    /// and are deliberately not carried: this app's meter colours its own segments.
    struct Category: Hashable, Sendable {
        var name: String
        var tokens: Int
    }

    var percentage: Int
    var totalTokens: Int
    var maxTokens: Int
    /// The token count auto-compaction fires at, when the engine reports one.
    var autoCompactThreshold: Int?
    var isAutoCompactEnabled: Bool
    var categories: [Category]

    /// Nil for an answer that carries no totals — an error body, or a subtype this engine build does
    /// not answer. A meter drawn from a body with no `totalTokens` would read zero and look like a
    /// fresh session.
    init?(answer: JSONValue) {
        guard let total = Self.integer(answer["totalTokens"]), let max = Self.integer(answer["maxTokens"]) else {
            return nil
        }
        totalTokens = total
        maxTokens = max
        percentage = Self.integer(answer["percentage"]) ?? 0
        autoCompactThreshold = Self.integer(answer["autoCompactThreshold"])
        isAutoCompactEnabled = answer["isAutoCompactEnabled"]?.boolValue ?? false
        categories = (answer["categories"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue, let tokens = Self.integer(row["tokens"]) else { return nil }
            return Category(name: name, tokens: tokens)
        }
    }

    /// `JSONValue.intValue` answers only for `.integer`; a percentage that arrived as `10.0` decodes
    /// as `.integer` today and as `.number` on any build that writes a fraction, and a meter that
    /// silently read zero for the second would be wrong in exactly the place it matters.
    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .integer(let i): Int(i)
        case .number(let d): d.isFinite ? Int(d) : nil
        default: nil
        }
    }
}
