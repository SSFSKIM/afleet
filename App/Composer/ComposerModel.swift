import Foundation
import Observation
import AfleetCore
import ClaudeWire
import PanelHostAPI
import FleetKit

/// One channel's composer (spec §8.5, C6.2 "The shape: two models, one seam").
///
/// It holds the draft, the inline refusal shown above the field, and the channel's
/// `ChannelSurfaceState` — the one thing it shares with the header. It holds no process, opens no
/// transcript and writes no frame: every write is one `LifecycleAPI` call (contract X5, Y5), and
/// the only ClaudeWire value this file constructs is `UserInput`.
///
/// **The draft is cleared only when the X5 call returns.** A composer that emptied the field first and
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
    var refusal: String?

    /// The named surface a `.native` row asked for — `modelPicker`, `effortPicker`, `tasks`,
    /// `agents`, `switcher`. The name is the table's own string, never a literal written here: the
    /// composer opens what the row names and re-implements no mapping (contract X10).
    var openSurface: String?

    /// A `LifecycleAction` the router produced that afleet does not issue until the user answers.
    /// Nil whenever nothing is waiting; see `ComposerConfirmation`.
    var pendingConfirmation: ComposerConfirmation?

    /// What the pending confirmation adds to its own sentence — the header's *Send to background*
    /// names the live background tasks whose shells the handoff closes. Nil for every confirm that
    /// has nothing to add, and cleared with the confirmation it belongs to.
    var confirmationDetail: String?

    /// The `/rewind` dry run in front of the user, and the answer `StrategyUI.confirm` is suspended
    /// on. Both live here because the sheet is drawn by the composer's own view.
    var rewindPreview: RewindPreview?
    @ObservationIgnored var rewindAnswer: CheckedContinuation<RewindChoice, Never>?

    /// The engine's own report of what it offers, taken off this channel's event stream: the
    /// handshake's `commands`, and `system/init`'s `slash_commands` and `terminal_slash_commands`.
    ///
    /// They are held rather than folded into anything. Autocomplete and the terminal-only refusal
    /// are `CommandRouter`'s answers over exactly these two values (X10), and a composer that
    /// summarised them would be keeping a second opinion about what the engine offers.
    var handshake: InitializeResponse?
    var systemInit: SystemInitFields?

    /// One per channel (spec §7.7). Every **complete** assistant text goes through it; a hit is
    /// replaced and counted, a miss changes nothing. The matching is C4's and is not re-implemented.
    @ObservationIgnored let interceptor: RefusalInterceptor

    /// The replacement for each assistant message this channel's interceptor caught, keyed by the
    /// frame's own uuid — an engine-assigned identifier and not a path, a title or a session (§11).
    var interceptedReplacements: [String: String] = [:]

    /// The most recent interception, shown above the field so afleet's own explanation is visible
    /// whether or not a timeline row has asked for the replacement yet.
    var lastInterception: Intercepted?

    /// What *Edit* has to say about a rewind that did not happen (`EditAndRewind`): the fork it
    /// opened instead, or why it could offer none. Nil whenever nothing is being said.
    var editNote: String?

    /// How many `HostSignal.rewound` raises this composer has made. A **count**, never a uuid (§11),
    /// and the arm that separates an honoured rewind from a refused one: a refusal that raised the
    /// signal would leave the timeline disagreeing with the engine about what the conversation holds.
    private(set) var rewindSignalsRaised = 0

    /// Counts one raise. `edit(_:)` lives in `EditAndRewind.swift`, and `private(set)` is file-scoped
    /// in Swift, so the increment is spelled here rather than the property being left open to write.
    func recordRewindSignal() { rewindSignalsRaised += 1 }

    /// The channel's timeline — C6.1's model, read only, pointed here by `ComposerRegistry`.
    ///
    /// *Edit* reads three things out of it and derives none of them: which user messages have been
    /// rendered, which assistant item precedes the edited one, and where to raise the host signal an
    /// honoured rewind produces. Weak, because the composer must not keep a released channel's fold
    /// alive.
    @ObservationIgnored weak var timelines: ChannelTimelineModel?

    /// The channel's context, for the Browser route `StrategyUI.open(url:)` takes and, from Task 4,
    /// the `!` escape's directory and environment. Set when the composer appears; nil for a channel
    /// the panel host has never drawn, where there is no Browser tab to hand a URL to.
    @ObservationIgnored var context: ChannelContext?

    /// Where Shift+Tab's cycle currently stands (`ComposerShortcuts`).
    ///
    /// A cursor, not a readback, and nothing displays it: §7.4 says a displayed setting comes from
    /// the engine, and Task 7's picker replaces this with the handshake's own `permissionMode`.
    var permissionMode: PermissionMode = .default

    /// The paths the engine's index answered the current `@` token with, in its own order
    /// (`FileMentions`). Empty whenever no popover is showing; nothing here is derived from disk.
    var fileSuggestions: [String] = []

    /// The `file_suggestions` query in flight, held so the next keystroke can cancel it.
    @ObservationIgnored var mentionTask: Task<Void, Never>?

    /// How long a keystroke waits before its query goes out. A stored value rather than a constant so
    /// a test can widen the window and assert the cancellation on a **count of requests** rather than
    /// on timing.
    @ObservationIgnored var mentionDebounce: Duration = .milliseconds(120)

    /// True from the moment a send is accepted until its X5 call returns.
    ///
    /// The field fires `send()` from a detached `Task`, so two quick Return presses are two calls
    /// with nothing between them: both would clear the blank-draft guard, both would read the same
    /// draft, and the engine would get the message twice. A second press is **dropped, never
    /// queued** — a queued one would send the same words again the moment the first returned, which
    /// is the same defect with a delay in front of it.
    private(set) var isSending = false

    /// The queue chip for this channel (`QueueChip`). Built here so it shares the composer's
    /// lifetime and its `LifecycleAPI`; it reads the channel's timeline and nothing of this model's.
    let queue: QueueChipModel

    /// The three setting pickers (`SettingPickers`), whose displayed values are engine readbacks.
    /// Built here for the same reason the chip is: one per channel, over this composer's X5, sharing
    /// the `ChannelSurfaceState` §7.4's readback gate closes the field through.
    let pickers: SettingPickersModel

    /// Whether *Prompt suggestions* is on for this channel (`GhostText`). **Off by default**: the
    /// flag is `--prompt-suggestions` on the launch line (§7.7's matrix), so a channel that was not
    /// launched with it receives no `prompt_suggestion` frame at all, and one that was still shows
    /// nothing until the user asks for it.
    var promptSuggestionsEnabled = false

    /// The suggestion the engine offered after the last turn, shown as ghost text and accepted by
    /// Tab. Nil whenever there is nothing to accept. An observation off `events(of:)` and not a fold:
    /// nothing is written back into the timeline (X4).
    var ghostText: String?

    /// The images pasted or dropped onto the field, in the order they arrived (`Attachments`). They
    /// travel on the next `UserInput` and are dropped when it is sent.
    var attachments: [ImageAttachment] = []

    /// What the attachment tray has to say about something it would not take — a cap reached, an
    /// image that could not be converted. Nil whenever it has nothing to say.
    var attachmentNote: String?

    /// X5, and the only way anything in this file reaches the engine. Internal rather than private
    /// because the shortcuts are an extension in `ComposerShortcuts.swift`; Swift has no narrower
    /// scope than the module for that, and every caller is inside `App/Composer/`.
    @ObservationIgnored let lifecycle: any LifecycleAPI
    @ObservationIgnored private var events: Task<Void, Never>?

    /// Where this channel's frames arrive for anything outside the model — the queue chip and the
    /// ghost text of later tasks. The model's own reading of the stream is `observe(_:)`, which the
    /// loop calls after this hook.
    @ObservationIgnored var onEvent: (@MainActor (WireEvent) -> Void)?

    /// The line that raised `pendingConfirmation`, so an answered confirm clears the field it was
    /// typed in and a cancelled one leaves the words where the user can see them.
    @ObservationIgnored var confirmedLine: String?

    init(key: ChannelKey, lifecycle: any LifecycleAPI, surface: ChannelSurfaceState,
         diagnostics: any FleetDiagnosticsSink = NullFleetDiagnostics()) {
        self.key = key
        self.lifecycle = lifecycle
        self.surface = surface
        self.interceptor = RefusalInterceptor(diagnostics: diagnostics)
        self.queue = QueueChipModel(key: key, lifecycle: lifecycle)
        self.pickers = SettingPickersModel(key: key, lifecycle: lifecycle, surface: surface)
    }

    // MARK: - Sending

    /// The whole send path: one `sendPrompt(UserInput)` and nothing else (spec §8.5, "Sending is
    /// always `perform(.send(UserInput))` and never anything else" — X5's `sendPrompt` **is** that
    /// path, differing only in answering the minted uuid rather than the channel's state).
    ///
    /// A blank draft is not a send and not a refusal either — the engine would answer a whitespace
    /// user frame with a turn, and a composer that spends one on a stray Enter is worse than a
    /// composer that does nothing.
    ///
    /// A `LifecycleError` is explained inline and **never retried**. The lifecycle refused for a
    /// reason it knows and this model does not; re-issuing would either duplicate the message or
    /// spin against a channel that is busy for as long as it is busy.
    ///
    /// A line beginning `/` is a command and goes to `route(_:on:)` instead (`CommandRouting`), which
    /// answers with what afleet does about it. The composer decides nothing about the line itself.
    func send() async {
        guard !isSending else { return }
        // §7.4: the field is closed while a restart is in flight and while a readback is
        // unconfirmed. The view already disables the text view, but the refusal belongs to the model
        // too — a send reaching a process that is being replaced is the defect the gate exists for,
        // and a view is not the place that guarantee should live.
        guard !surface.isDisabled else { return }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft
        refusal = nil
        openSurface = nil
        isSending = true
        defer { isSending = false }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("!") {
            // Host-side, and never a turn: what the command wrote is posted as one ordinary user
            // frame (§6.6). Cleared on the same terms as any other send.
            if await runShellEscape(text), draft.hasPrefix(text) { draft = String(draft.dropFirst(text.count)) }
            return
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            // Cleared only when the dispatch went through, on the same terms as a plain send: a
            // refused command leaves the words where the user can fix them.
            if await dispatch(routing: text), draft.hasPrefix(text) { draft = String(draft.dropFirst(text.count)) }
            return
        }
        let images = attachments
        guard await post(UserInput(text: text, images: images)) else { return }
        // Only the words that were sent. A keystroke that landed during the await is the user's
        // next message, not part of the one the engine now has.
        if draft.hasPrefix(text) { draft = String(draft.dropFirst(text.count)) }
        // The images that went with the message. Anything attached during the await is the next
        // message's, on exactly the terms the draft is.
        dropAttachments(images.count)
        ghostText = nil
    }

    /// **The one place a `UserInput` becomes a prompt.** All three user-initiated sends in this leaf
    /// come through here: the plain send above, the router's `.text` pass-through (`CommandRouting`)
    /// and the `!` escape's post of what a host command wrote (`ShellEscape`).
    ///
    /// `sendPrompt` is `perform(.send)`'s path — same preconditions, same refusals — answering the
    /// uuid the supervisor minted for the user frame instead of the channel's state. That uuid is the
    /// whole reason the member exists: it is what the engine will echo, and the host cannot mint it
    /// or read it from below X5 without breaking contract Y5.
    ///
    /// **The raise is inseparable from the call**, which is why the two are one function rather than
    /// a convention three call sites are expected to keep. Each of the three causes a turn, so a site
    /// that sent without raising would leave that turn reducing as `.unprompted` — the channel's fold
    /// disagreeing with the engine about who asked for it. Raised **after** the call succeeds and
    /// never before: a refused send that had already raised it would leave the reducer holding a
    /// prompt the engine was never given. The uuid is lowercased because that is the spelling the
    /// frame carries onto the wire, so the signal and the echo name the same prompt.
    ///
    /// A `LifecycleError` is explained inline and **never retried**, exactly as `issue(_:)` does for
    /// every other X5 member.
    @discardableResult
    func post(_ input: UserInput) async -> Bool {
        do {
            let minted = try await lifecycle.sendPrompt(input, on: key)
            await timelines?.signal(.promptSent(uuid: minted.uuidString.lowercased(), at: Date()))
            return true
        } catch let error as LifecycleError {
            refusal = Self.explanation(of: error)
            return false
        } catch {
            refusal = "The message was not sent; it is still in the field."
            return false
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
            // After the subscription and before the first frame: what the engine already reported
            // and will not report again (`LateMountMetadata`).
            await self.seedEngineReports()
            for await event in stream {
                if Task.isCancelled { return }
                self.onEvent?(event)
                await self.observe(event)
            }
        }
    }

    func stop() {
        queue.stop()
        events?.cancel()
        events = nil
        mentionTask?.cancel()
        mentionTask = nil
    }
}
