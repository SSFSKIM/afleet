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
    /// **Corrected 2026-09-09 (C6.1 Task 8): the handshake is the initial value, not the source.**
    /// `system/status` carries `permissionMode` — `StatusFields` models it and the engine populates
    /// it: across the corpus's 40 status frames exactly one carries a value, and it is in the one
    /// recording where a mode actually changes. So the readout **follows status frames** and falls
    /// back to the handshake for the value it opens with. A readback retained for the life of a
    /// process is stale in a way that looks authoritative: "the header shows what the engine said at
    /// startup" fails in the same shape as "the header shows what the user last clicked", which is
    /// what G4 exists to catch.
    ///
    /// What still holds, and is why this is not `get_settings`: that answer is
    /// `{applied: {model, effort, advisor, ultracode}, effective, sources}` (2.1.257
    /// `cli.pretty.js:178217`, and both recordings that carry the subtype — `control-shapes` and
    /// `zero-cost`), where `effective` is the merged *settings files*, so a mode read out of it would
    /// be what a file asks for and not what the process is running.
    var mode: PermissionMode?

    /// Whether the mode on screen came from a `system/status` frame.
    ///
    /// The precedence this records **is** the correction. The handshake is retained per process and
    /// never reissued, so without it the next settings readback — one per turn end — would fold the
    /// launch mode back over a live one, and the header would show the true value for a few seconds
    /// and the stale one for ever after.
    private(set) var modeIsLive = false

    /// `get_settings.applied.effort`, falling back to the `effortLevel` the answer's `effective` map
    /// carries. Nil is a value and not an absence: the engine reports `null` for the default.
    var effort: String?

    /// `get_context_usage`. Nil until the first answer — **nothing pushes this** (parity §41.15.4:
    /// `autocompact_state` is emitted only under `CLAUDE_CODE_REMOTE`), so it is polled after each
    /// `result` frame and never on a timer.
    var context: ContextUsage?

    /// Parity §41.8's `autoScrollEnabled`, from the answer's `effective` map — the merged settings
    /// files, which is where the reader's own preference lives. True until an answer says otherwise,
    /// which is both the engine's default and what its own renderer does.
    var autoScrollEnabled = true

    /// Parity §41.17's `syntaxHighlightingDisabled`, inverted so the field reads as what it does. It
    /// is an accessibility choice for some readers rather than a debug switch, so it is honoured.
    var syntaxHighlightingEnabled = true

    /// True while the engine has answered nothing at all. What an archived channel looks like: the
    /// branch alone.
    var isEngineSilent: Bool { model == nil && mode == nil && effort == nil && context == nil }

    /// Folds one `get_settings` answer in. Whole-value, because the answer is the truth about the
    /// process: a field the engine now reports as absent is absent here too.
    mutating func apply(_ settings: SettingsReadback) {
        model = settings.model
        effort = settings.effort
        // Whole-value for the same reason as the two above: `effective` is the merged settings
        // files, so a key no file sets is absent, and absent means the engine's own default.
        autoScrollEnabled = settings.autoScrollEnabled ?? true
        syntaxHighlightingEnabled = settings.syntaxHighlightingEnabled ?? true
        // The mode comes from a second report, and a channel whose retained handshake is not
        // available yet must not blank a mode an earlier one gave. Nor may the handshake — which is
        // minted once per process — overwrite a mode a `system/status` frame has since reported.
        guard !modeIsLive, let mode = settings.mode else { return }
        self.mode = mode
    }

    /// The live readback: the mode a `system/status` frame reported.
    ///
    /// It outranks the handshake from the moment it arrives, and it is the only writer that sets
    /// `modeIsLive` — so the header follows the process rather than remembering its launch.
    mutating func apply(liveMode mode: PermissionMode) {
        self.mode = mode
        modeIsLive = true
    }

    /// The process these readbacks were taken from, as the events name it.
    ///
    /// **On the readout, and not on the subscription that observes it.** A subscription ends when
    /// the channel archives and a later one starts from nothing, while this readout — and the live
    /// precedence in it — is what the registry retains across both. An epoch held per subscription
    /// makes the first event a new subscription sees its own baseline, so a live mode belonging to a
    /// process that is already gone goes on outranking the replacement's handshake, at the opening
    /// readback and at every settings poll after it. Recorded beside the mode it is a claim about,
    /// it outlives the subscription with it.
    private(set) var processEpoch: ProcessEpoch?

    /// Records the process an event belongs to, and answers whether it is a **newer** one than these
    /// readbacks were taken from — which is a restart, and the caller's cue to read them again.
    ///
    /// **The live precedence is a claim about one process and it retires with that process.** The
    /// live mode came from a `system/status` frame the exited engine sent; the replacement mints its
    /// own handshake and reports nothing until something changes, so a precedence that never reset
    /// would reject that handshake for ever and the header would show a mode nothing is running.
    ///
    /// The mode itself is left standing rather than blanked: X5's rule is that a readback stands
    /// until a newer one replaces it. Clearing the precedence is only half of that, which is why
    /// this answers rather than returning nothing — a handshake is not a turn end, so a replacement
    /// that runs no turn would keep the replaced process's mode until one arrives, which on an idle
    /// channel is never. The reading itself belongs to the caller: it is a round trip, and this is a
    /// value.
    ///
    /// The first epoch seen is a baseline and not a replacement, and the comparison is monotone, so
    /// a straggler from the process before resets nothing.
    mutating func observed(epoch: ProcessEpoch) -> Bool {
        defer { processEpoch = max(processEpoch ?? epoch, epoch) }
        guard let known = processEpoch, epoch > known else { return false }
        modeIsLive = false
        return true
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

    /// The two rendering preferences the answer's `effective` map carries. Optional, because absent
    /// is a real answer — no settings file sets the key — and it is the caller that knows what the
    /// engine's default for each one is.
    var autoScrollEnabled: Bool?
    var syntaxHighlightingEnabled: Bool?

    /// `answer` is the `get_settings` body; `handshake` is the channel's retained
    /// `InitializeResponse`, and nil when the fleet has none for this channel.
    init(answer: JSONValue, handshake: InitializeResponse?) {
        let applied = answer["applied"]
        model = applied?["model"]?.stringValue
        // `applied.effort` is the effort the engine resolved and the value `Readback.verify`
        // compares a restart against; `effective.effortLevel` is the flag setting a host applied,
        // which is the only one of the two `control-shapes` carries after an `apply_flag_settings`.
        let effective = answer["effective"]
        effort = applied?["effort"]?.stringValue ?? effective?["effortLevel"]?.stringValue
        mode = handshake?.currentPermissionMode
        // Both are settings-file keys, so both are read off `effective` and neither is in `applied`:
        // `autoScrollEnabled` is in the live answer's key list, and `syntaxHighlightingDisabled` is
        // settings-file-only (parity §41.17). Read as what each key states, and inverted here rather
        // than at the reader, so nothing downstream has to remember which way round the name runs.
        autoScrollEnabled = effective?["autoScrollEnabled"]?.boolValue
        syntaxHighlightingEnabled = effective?["syntaxHighlightingDisabled"]?.boolValue.map { !$0 }
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
