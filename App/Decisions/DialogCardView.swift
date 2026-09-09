import SwiftUI
import AfleetCore
import ClaudeWire
import FleetKit

/// How long the engine will wait for a dialog answer before it settles the request itself
/// (anchor 4, `cli.pretty.js:703269`, `:703282`, `:283307`).
///
/// **300 000 ms by default**, overridden by `CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS` and then by a
/// trusted `dialogExpiry` of `60s`, `5m`, `10m` or `never`; `never` starts no timer at all. On
/// expiry the engine injects `{behavior:"cancelled"}` on the user's behalf, so a card that showed
/// no deadline would leave the user working a control that had silently stopped being answerable.
///
/// afleet reads no settings file of its own, so `dialogExpiry` arrives only where a caller already
/// holds a trusted settings read; nothing under `App/` has one yet and the standard deadline passes
/// nil.
struct DialogDeadline: Sendable, Hashable {

    /// The engine's own default, in milliseconds.
    static let engineDefaultMilliseconds = 300_000

    /// Nil is `never`: the engine starts no timer and the card says so.
    var milliseconds: Int?

    /// What the engine will do with this dialog if nobody answers it, read from the same two
    /// overrides the engine reads and in the same order.
    init(environment: [String: String], dialogExpiry: String?) {
        if let raw = environment["CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS"], let parsed = Int(raw), parsed > 0 {
            milliseconds = parsed
        } else if let expiry = dialogExpiry {
            switch expiry {
            case "60s": milliseconds = 60_000
            case "5m": milliseconds = 300_000
            case "10m": milliseconds = 600_000
            case "never": milliseconds = nil
            default: milliseconds = Self.engineDefaultMilliseconds
            }
        } else {
            milliseconds = Self.engineDefaultMilliseconds
        }
    }

    /// The deadline a card gets when nobody names one: the engine's default, with whatever override
    /// this process's environment carries, which is the environment a spawned engine inherits.
    static var standard: DialogDeadline {
        DialogDeadline(environment: ProcessInfo.processInfo.environment, dialogExpiry: nil)
    }

    /// The sentence a pending dialog card carries.
    var text: String {
        guard let milliseconds else { return "This dialog does not expire." }
        let seconds = milliseconds / 1000
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return "This dialog expires in \(minutes) minute\(minutes == 1 ? "" : "s")."
        }
        return "This dialog expires in \(seconds) second\(seconds == 1 ? "" : "s")."
    }
}

/// The two dialog cards of §8.4's *Dialogs* table: `refusal_fallback_prompt` and
/// `fable_overage_consent_prompt` (item 62, acceptance G1f).
///
/// Both are drawn only while the engine is waiting: `DecisionCardView` renders D12's reading for
/// every other state, so a settled dialog never reaches this view. Every action is
/// `DecisionCard.answer(_:)`'s — this view chooses which one and nothing else — and each result
/// travels inside `{behavior:"completed", result: <...>}`, with closing the card sending
/// `{behavior:"cancelled"}` (anchors 2 and 3).
///
/// **A dialog kind afleet never declared does not reach here** and could not be answered if it did:
/// `InboundPolicy` leaves it unanswered, `WireReducer` opens it `.inert`, and every dialog action in
/// the mapping is guarded on the kind (§6.3).
struct DialogCardView: View {

    let card: DecisionCard
    let request: UserDialogRequest
    let presentation: DecisionCardView.Presentation
    let channel: ChannelKey
    let answering: DecisionAnswering
    /// Where a resolved refusal dialog's retracted uuids go (spec D11). The host that owns a
    /// timeline list hands one in; a host with no list to filter — Activity's row — passes none.
    let retraction: RetractionRegistry?
    /// Where *Edit the prompt* puts the prompt back (contract Y6's fourth site). The host that owns
    /// a composer hands one in; a host that has none — Activity's row, an agent node's card — passes
    /// none, on the same rule `retraction` follows, and the answer still goes out.
    let composer: (any ComposerSite)?
    let deadline: DialogDeadline

    init(card: DecisionCard,
         request: UserDialogRequest,
         presentation: DecisionCardView.Presentation,
         channel: ChannelKey,
         answering: DecisionAnswering,
         retraction: RetractionRegistry? = nil,
         composer: (any ComposerSite)? = nil,
         deadline: DialogDeadline = .standard) {
        self.card = card
        self.request = request
        self.presentation = presentation
        self.channel = channel
        self.answering = answering
        self.retraction = retraction
        self.composer = composer
        self.deadline = deadline
    }

    /// What *Set up usage credits…* says instead of opening a page.
    ///
    /// The payload carries **no URL** (spec D7, anchor 3) and the engine's console address is
    /// exactly the kind of fact that moves, so afleet neither invents one nor asserts one it has no
    /// evidence for. The action leaves the card pending, as §8.4 requires: the dialog is resolved
    /// only by *Switch to the default model* or *Not now*.
    static let creditsNote = "Usage credits are set up outside this session; the engine sent no address to open."

    private var isAnswering: Bool { answering.isAnswering(card.requestID) }

    var body: some View {
        VStack(alignment: .leading, spacing: presentation == .full ? 8 : 4) {
            switch card.dialogKind {
            case .refusalFallback: refusal
            case .overageConsent: overage
            case nil: Text(card.summaryLine).font(presentation == .full ? .body : .callout)
            }
            if let banner = answering.banner {
                Text(banner.text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - The refusal-fallback dialog

    @ViewBuilder
    private var refusal: some View {
        let payload = card.refusalFallback ?? DecisionCard.RefusalFallback(retractedMessageUUIDs: [])
        Text("The model declined this prompt.").font(.body.weight(.semibold))
        if let models = Self.modelLine(payload) {
            Text(models).font(.callout).foregroundStyle(.secondary)
        }
        if let guidance = payload.guidanceText {
            Text(guidance).font(.callout)
        }
        // Nullable, not merely absent: a `null` category names nothing and draws nothing.
        if let category = Self.categoryLine(payload) {
            Text(category).font(.caption).foregroundStyle(.secondary)
        }
        if let retraction = Self.retractionLine(payload) {
            Text(retraction).font(.caption).foregroundStyle(.secondary)
        }
        Text(deadline.text).font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 8) {
            Button("Retry on the fallback model") { send(.retryOnFallbackModel) }
            Button("Edit the prompt") { send(.editPrompt) }
            Button("Keep the refusal") { send(.keepTheRefusal) }
            Button("Close") { send(.closeDialog) }
        }
        .disabled(isAnswering)
    }

    // MARK: - The overage-consent dialog

    @ViewBuilder
    private var overage: some View {
        let payload = card.overageConsent ?? DecisionCard.OverageConsent(overagesEnabled: false)
        Text(Self.headline(payload)).font(.body.weight(.semibold))
        if let balance = Self.balanceText(payload) {
            Text(balance).font(.callout).foregroundStyle(.secondary)
        }
        Text(deadline.text).font(.caption).foregroundStyle(.secondary)
        if !payload.overagesEnabled {
            Text(Self.creditsNote).font(.caption).foregroundStyle(.secondary)
        }
        HStack(spacing: 8) {
            // `consent` is offered only where the engine says billing is already on: a bare wire
            // reply enables nothing (§8.4's *Result* column, anchor 3).
            if payload.overagesEnabled {
                Button("Use usage credits") { send(.useUsageCredits) }
            } else {
                Button("Set up usage credits…") { send(.setUpUsageCredits) }
            }
            Button("Switch to the default model") { send(.switchToDefaultModel) }
            Button("Not now") { send(.notNow) }
            Button("Close") { send(.closeDialog) }
        }
        .disabled(isAnswering)
    }

    /// The two model names, where the payload carries both.
    static func modelLine(_ payload: DecisionCard.RefusalFallback) -> String? {
        guard let original = payload.originalModel, let fallback = payload.fallbackModel else { return nil }
        return "\(original) declined; \(fallback) can take it instead."
    }

    /// The refusal category, where one arrived. **Nullable, not merely absent** (anchor 2): an
    /// explicit `null` is read as a value and draws nothing, exactly as an omitted key does.
    static func categoryLine(_ payload: DecisionCard.RefusalFallback) -> String? {
        payload.apiRefusalCategory.map { "Category: \($0)" }
    }

    /// What this dialog will take back once it is settled — a count, never the messages themselves.
    static func retractionLine(_ payload: DecisionCard.RefusalFallback) -> String? {
        let count = payload.retractedMessageUUIDs.count
        guard count > 0 else { return nil }
        return "\(count) streamed message\(count == 1 ? "" : "s") will be taken back once this is settled."
    }

    /// What the overage card leads with. The model name is optional even though the engine feeds it
    /// today, so the card names no model rather than an empty one.
    static func headline(_ payload: DecisionCard.OverageConsent) -> String {
        "\(payload.modelName ?? "This model") needs usage credits to continue."
    }

    /// The balance line, or nil where the engine fed no balance. A missing `balanceCents` is not a
    /// zero balance: it is no reading at all, and the card says nothing rather than telling a user
    /// their account is empty.
    static func balanceText(_ payload: DecisionCard.OverageConsent) -> String? {
        guard let cents = payload.balanceCents else { return nil }
        let amount = String(format: "%.2f", Double(cents) / 100)
        guard let currency = payload.currency else { return "Balance: \(amount)" }
        return "Balance: \(amount) \(currency)"
    }

    // MARK: - Sending

    /// One action on its way out, and the retraction its **success** resolves.
    ///
    /// The registry is fed here and only here, on the path that raises `decisionAnswered` — not
    /// when the answer is scheduled. §8.4 retracts on a *resolution*, and an answer `perform`
    /// refused resolved nothing: the dialog is still open and the engine was never told. The
    /// registry has no rollback, so a uuid handed to it on dispatch is a streamed message deleted
    /// from the channel for a request that is still waiting. An action that puts nothing on the
    /// wire, which is *Set up usage credits…*, never reaches this closure at all.
    private func send(_ action: DecisionAction) {
        answering.send(action, on: card, in: channel) { [card, channel, retraction, composer] in
            retraction?.resolved(card, in: channel)
            // §8.4: `edit_prompt` alone puts the prompt back. It rides the success branch for the
            // retraction's reason turned around — a field refilled for an answer `perform` refused
            // is a prompt restored under a dialog that is still open — and only this action, because
            // the other three leave the conversation where it is.
            if action == .editPrompt { composer?.restoreLastPrompt() }
        }
    }
}
