import Foundation
import Observation
import AfleetCore
import ClaudeWire
import FleetKit

/// One channel's composer (spec §8.5, C6.2 "The shape: two models, one seam").
///
/// It holds the draft, the inline refusal shown above the field, and the channel's
/// `ChannelSurfaceState` — the one thing it shares with the header. It holds no process, opens no
/// transcript and writes no frame: every write is one `LifecycleAPI` call (contract X5, Y5), and
/// the only ClaudeWire value this file constructs is `UserInput`.
///
/// **The draft is cleared only when `perform` returns.** A composer that emptied the field first and
/// put the words back on a refusal is a composer that loses them the one time the put-back is the
/// buggy line; clearing after the call cannot lose them at all.
@MainActor
@Observable
final class ComposerModel {

    let key: ChannelKey

    /// Shared with the channel header; see `ChannelSurfaceState`.
    let surface: ChannelSurfaceState

    /// What is typed. Bound to the field.
    var draft: String = ""

    /// The inline surface above the field: a refusal, in this leaf's own words for a
    /// `LifecycleError` and verbatim from `RouterTable` for a locally refused command (Task 3).
    private(set) var refusal: String?

    @ObservationIgnored private let lifecycle: any LifecycleAPI
    @ObservationIgnored private var events: Task<Void, Never>?

    /// Where this channel's frames arrive. Task 1 subscribes and hands each one here; the ghost
    /// text, the queue chip and the drift interception are what later tasks read out of it. Nothing
    /// parses a frame yet, deliberately — a speculative decoder written before its consumer is a
    /// second opinion about the stream that no test constrains.
    @ObservationIgnored var onEvent: (@MainActor (WireEvent) -> Void)?

    init(key: ChannelKey, lifecycle: any LifecycleAPI, surface: ChannelSurfaceState) {
        self.key = key
        self.lifecycle = lifecycle
        self.surface = surface
    }

    // MARK: - Sending

    /// The whole send path: one `perform(.send(UserInput))` and nothing else (spec §8.5, "Sending is
    /// always `perform(.send(UserInput))` and never anything else").
    ///
    /// A blank draft is not a send and not a refusal either — the engine would answer a whitespace
    /// user frame with a turn, and a composer that spends one on a stray Enter is worse than a
    /// composer that does nothing.
    ///
    /// A `LifecycleError` is explained inline and **never retried**. The lifecycle refused for a
    /// reason it knows and this model does not; re-issuing would either duplicate the message or
    /// spin against a channel that is busy for as long as it is busy.
    func send() async {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft
        refusal = nil
        do {
            _ = try await lifecycle.perform(.send(UserInput(text: text)), on: key)
            // Only the words that were sent. A keystroke that landed during the await is the user's
            // next message, not part of the one the engine now has.
            if draft.hasPrefix(text) { draft = String(draft.dropFirst(text.count)) }
        } catch let error as LifecycleError {
            refusal = Self.explanation(of: error)
        } catch {
            refusal = "The message was not sent; it is still in the field."
        }
    }

    /// Why a send was refused, as a sentence naming what the lifecycle named. This leaf writes this
    /// copy: a `LifecycleError` is afleet's own refusal, not the engine's, so X10's "render the
    /// table, write no copy" rule does not reach it.
    static func explanation(of error: LifecycleError) -> String {
        switch error {
        case .busy(let operation):
            "This channel is already running \(operation.rawValue); your message is still in the field."
        case .notEligible(let blocker):
            "This channel is not ready — \(name(of: blocker)); your message is still in the field."
        case .notOwned:
            "afleet does not own this channel, so it cannot send; your message is still in the field."
        case .capReached(let live):
            "\(live) channel(s) are already live; your message is still in the field."
        case .logoutInProgress:
            "A logout is running; your message is still in the field."
        default:
            "The message was not sent; it is still in the field."
        }
    }

    /// The blocker, named. The task id travels with the three task blockers because "a background
    /// task is running" without saying which one leaves the reader nothing to act on; it is an
    /// engine-assigned identifier and not a path, a title or a session id (§11).
    static func name(of blocker: DormantEligibility.Blocker) -> String {
        switch blocker {
        case .wedged: "the channel is wedged"
        case .turnRunning: "a turn is running"
        case .pendingDecision: "a decision is waiting to be answered"
        case .queuedInput: "input is already queued"
        case .taskRunning(let id): "a background task is running (\(id))"
        case .taskArmed(let id): "a background task is armed (\(id))"
        case .taskStateUncertain(let id): "a background task's state is uncertain (\(id))"
        }
    }

    // MARK: - The event subscription

    /// Takes this channel's fan-out of `events(of:)` — which **is** X5, not a reach around it — and
    /// holds it until `stop()`. Idempotent: a second call while one loop runs is ignored, because
    /// two fan-outs would deliver every frame twice.
    func start() {
        guard events == nil else { return }
        events = Task { @MainActor [weak self] in
            guard let self, let stream = await self.lifecycle.events(of: self.key) else { return }
            for await event in stream {
                if Task.isCancelled { return }
                self.onEvent?(event)
            }
        }
    }

    func stop() {
        events?.cancel()
        events = nil
    }
}
