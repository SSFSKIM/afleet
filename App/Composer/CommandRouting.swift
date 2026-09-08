import Foundation
import AfleetCore
import ClaudeWire
import PanelHostAPI
import FleetKit

/// The composer's half of contract **X10**: it renders C4's table and dispatches C4's `Routed`, and
/// it re-implements no mapping.
///
/// There is deliberately **no switch on a command name anywhere in this file**. Every behaviour below
/// is reached either from a `Routed` case `LifecycleAPI.route(_:on:)` returned or from a row of
/// `RouterTable`, and every sentence a user reads comes back from a `RouterTable` function verbatim.
/// The one class of copy this leaf writes is `ComposerModel.explanation(of: LifecycleError)` — a
/// refusal by afleet's own facade, which no table describes.

/// A lifecycle action afleet does not issue until the user has answered for it (spec §8.5's dispatch
/// table: *behind a confirm for `stopEverything`, `backgroundAll` and `logout`*).
///
/// A value over `LifecycleAction` rather than a flag per action, so they share one gate: each closes
/// shells or signs sessions out on this whole machine, and none of them may be reached by a mistyped
/// chord or an autocompleted line.
///
/// Task 8 added `sendToBackground`, which is the **header's** and not the router's. The gate is
/// shared — one pending confirmation per channel, answered in one place — while `init?(_:)` still
/// maps only the three the router's table puts behind a confirm, because a typed `/background` is a
/// `.lifecycle` row the composer issues directly and G1 asserts exactly that member sequence. The
/// menu item is the one that has to show the cost first, because it is the one that names the live
/// background tasks whose shells the handoff closes.
/// Task 11 added `trustDirectory`, which is not a lifecycle action at all: §7.7's `/cd` row answers an
/// untrusted directory with a **success envelope that changed nothing**, and the trust is granted only
/// by a second `set_cwd`. It shares this gate because it is the same kind of thing — something afleet
/// does not do until the user has answered for it — and the dialog that draws the other four draws it
/// with no change of its own.
enum ComposerConfirmation: Hashable, Sendable {
    case stopEverything
    case backgroundAll
    case logout
    case sendToBackground
    /// *Open in terminal*, when the channel has running background tasks. The handoff terminates the
    /// owned process before the pane request is answered, and a stream close kills every still-running
    /// local shell (X9, §7.4) — so the same confirm the handoff to a background job shows is shown here.
    /// A channel with nothing running is released without a dialog: there is no cost to state.
    case openInTerminal
    /// The directory the engine's `needs_trust` answer named, and the path the line asked for. Both,
    /// because the second call carries both and they are not interchangeable: `trusted_directory`
    /// must echo the **answer's** directory, which is the resolved one.
    case trustDirectory(directory: String, path: String)

    /// Nil for every action the **router** issues directly — a plain fork and a typed `/background`
    /// are the channel's own business. The header raises `.sendToBackground` itself.
    init?(_ action: LifecycleAction) {
        switch action {
        case .stopEverything: self = .stopEverything
        case .backgroundAll: self = .backgroundAll
        case .logout: self = .logout
        default: return nil
        }
    }

    /// The lifecycle action this confirm issues, and **nil for the one that issues none**: trusting a
    /// directory is a control request, so `confirmPending()` reads the case rather than every case
    /// being made to name an action it does not have.
    var action: LifecycleAction? {
        switch self {
        case .stopEverything: .stopEverything
        case .backgroundAll: .backgroundAll
        case .logout: .logout
        case .sendToBackground: .sendToBackground
        // Neither is a `LifecycleAction`: the terminal handoff is X5's own member and the trust is a
        // control request. `confirm(_:)` reads the case rather than every case being made to name an
        // action it does not have.
        case .openInTerminal, .trustDirectory: nil
        }
    }

    /// The case's name, for a note or an assertion that must carry no value (§11). Computed rather
    /// than a raw value, because one case carries the directory it is about.
    var rawValue: String {
        switch self {
        case .stopEverything: "stopEverything"
        case .backgroundAll: "backgroundAll"
        case .logout: "logout"
        case .sendToBackground: "sendToBackground"
        case .openInTerminal: "openInTerminal"
        case .trustDirectory: "trustDirectory"
        }
    }

    var title: String {
        switch self {
        case .stopEverything: "Stop everything in this channel?"
        case .backgroundAll: "Move this channel's running tools to the background?"
        case .logout: "Sign out of every channel on this machine?"
        case .sendToBackground: "Send this channel to the background?"
        case .openInTerminal: "Release this channel to your terminal?"
        case .trustDirectory: "Trust this directory?"
        }
    }

    var message: String {
        switch self {
        case .stopEverything: "The running turn and every background task in this channel stop. Their shells close."
        // What the verb does, and no more: one `background_tasks` with no `tool_use_id` on **this**
        // channel (`Fleet`'s `.backgroundAll` arm, and the parent's `/background-all` row). It is not
        // a handoff — nothing is replaced by a background job — and it records nothing, so a restart
        // leaves none of it behind.
        case .backgroundAll:
            "Every tool the current turn is running in this channel moves to the background. "
                + "Nothing stops, no session is handed off, and nothing survives a restart."
        case .logout: "Every owned channel and every afleet-launched job on this machine signs out."
        case .sendToBackground: "This channel's process is replaced by a background job; its local shells close."
        case .openInTerminal:
            "afleet's process for this channel ends and the conversation is handed to your terminal; "
                + "its local shells close."
        // The directory is what the user is being asked about, so it is named: a trust dialog that
        // hid it would be asking about nothing.
        case .trustDirectory(let directory, _):
            "This channel has not run in \(directory) before. Trusting it lets the engine work there."
        }
    }

    var confirmTitle: String {
        switch self {
        case .stopEverything: "Stop Everything"
        case .backgroundAll: "Move to Background"
        case .logout: "Sign Out"
        case .sendToBackground: "Send to Background"
        case .openInTerminal: "Open in Terminal"
        case .trustDirectory: "Trust and Change"
        }
    }
}

// MARK: - Dispatch

extension ComposerModel {

    /// Routes one line through X5 and dispatches whichever `Routed` case came back.
    ///
    /// `route` is the fleet's, not this file's: it reads the channel's own handshake, `system/init`
    /// and runtime record, which is why the terminal-only refusal and the pass-through are decided
    /// there and merely rendered here.
    ///
    /// Returns whether the line was disposed of. A confirm that is still waiting answers `false`,
    /// because nothing has happened yet and the words belong in the field until it does.
    @discardableResult
    func dispatch(routing line: String) async -> Bool {
        let routed = await lifecycle.route(line, on: key)
        confirmedLine = line
        return await dispatch(routed)
    }

    /// The seven cases of `Routed`, each to the X5 member the spec's table names.
    @discardableResult
    func dispatch(_ routed: Routed) async -> Bool {
        switch routed {
        case .controlRequest(let request):
            // §7.4 and §8.6 bind the three settings the pickers own to **one path each**, whichever
            // surface asked for the change: the same request, the same readback, and for
            // `bypassPermissions` the same disclaimer, acceptance write and prerequisite restart. A
            // typed line that sent the request itself skipped all three and left the header showing a
            // value the engine had already moved past.
            if let handled = await pickers.apply(routed: request) { return handled }
            return await sendRouted(request)
        case .strategy(let strategy, let arguments):
            // What the field held when the command was issued. A strategy is an await — `/rewind`'s
            // is two, with a confirmation sheet between them — and the field stays editable across
            // it, so the prefill an honoured rewind hands back is written only over the words the
            // command was issued with. This is *Edit*'s rule (`EditAndRewind`), which this path did
            // not have: it overwrote whatever had been typed since.
            let draftWhenIssued = draft
            do {
                let outcome = try await lifecycle.run(strategy, arguments: arguments, on: key, ui: self)
                present(outcome, draftWhenIssued: draftWhenIssued)
                return true
            } catch {
                refuse(error)
                return false
            }
        case .lifecycle(let action):
            return await dispatch(action: action)
        case .restart(let request):
            // §7.4: a restart-required setting closes the field first, replaces the process, and then
            // re-opens it only once every readback matches — a mismatch banners and keeps it closed.
            // The gate is `SettingPickersModel`'s, over the `ChannelSurfaceState` the header shares,
            // and the two readbacks it takes are why this row reaches four members rather than two.
            // The same predicate every other entry point asks, and the same reason: a restart-required
            // change replaces a process, and one may not begin over another or on a connecting channel.
            if let refused = await pickers.refusal(of: .settingChange) {
                refusal = refused
                return false
            }
            let before = await lifecycle.state(of: key)
            let operation = pickers.beginRestart(reason: "This channel is restarting to apply the setting.",
                                                 expecting: pickers.currentSnapshot)
            let after: ChannelState
            do {
                after = try await lifecycle.perform(.quiescentRestart(request), on: key)
            } catch {
                // The same fact the header's restart path reads: `quiescentRestart` spawns the
                // replacement before it restores and re-reads the settings, so an error can arrive
                // with a new process connecting on the other end. Re-opening the field there lets a
                // send into that process's queued input with no readiness transition to flush it.
                await pickers.restartFailed(await lifecycle.state(of: key), operation)
                refuse(error)
                return false
            }
            // A busy channel records the change for the dormant timer and answers success with the
            // old process still on the other end; a readback confirmed there would release the field
            // over a restart that has not happened.
            guard SettingPickersModel.replacedTheProcess(after, from: before) else {
                await pickers.noteQueuedRestart(operation)
                return true
            }
            _ = await pickers.confirmReadback(operation)
            return true
        case .text(let text):
            // A pass-through is a prompt like any other: the user typed a line and a turn runs for
            // it. So it goes through `post(_:)` — `sendPrompt`, and the `HostSignal.promptSent` raise
            // that attributes the turn it causes. While it was issued as `perform(.send)` with no
            // raise — as it was until Task 7 — the turn reduced as `.unprompted`.
            //
            // **With whatever is attached**, on exactly the terms a plain send carries them: an
            // engine command is still a message, and images left behind here would ride the next one
            // instead — a picture answering a question the user has already moved on from.
            let images = attachments
            guard await post(UserInput(text: text, images: images)) else { return false }
            dropAttachments(images)
            ghostText = nil
            return true
        case .native(let surface):
            // Nothing reaches the lifecycle: a picker, a list or the switcher is afleet's own screen.
            openSurface = surface
            // The two picker surfaces are the header's own and open here. Every other destination is
            // another leaf's screen, and the app's one way to ask for one by name is the workspace's
            // link router — which today answers a `.command` nothing has claimed with a diagnostic
            // rather than with silence (tracker 207).
            if !pickers.present(surface) {
                await context?.links.open(.command(surface), from: .currentPanel)
            }
            return true
        case .refusedLocally(let explanation):
            // Verbatim from `RouterTable`. The composer does not paraphrase it and does not add to it.
            refusal = explanation
            return false
        }
    }

    /// One lifecycle action, behind the confirm when it is one of the three that need one.
    @discardableResult
    func dispatch(action: LifecycleAction) async -> Bool {
        if let confirmable = ComposerConfirmation(action) {
            pendingConfirmation = confirmable
            return false
        }
        return await issue { _ = try await self.lifecycle.perform(action, on: self.key) }
    }

    /// The whole of a waiting confirm, taken out of the model in one synchronous step.
    ///
    /// **The affirmative button and the dialog's dismissal are two separate calls**, and SwiftUI makes the
    /// dismissal — which is `cancelPending()` — before the affirmative's work has a chance to run. An action that
    /// read `pendingConfirmation` when its `Task` began therefore read the value the dismissal had already cleared
    /// and did nothing at all. So the answer is taken whole, at the moment the user gives it, and what follows may
    /// clear the model without erasing it.
    struct ClaimedConfirmation {
        let confirmation: ComposerConfirmation
        /// The line that raised it, so an issued confirm clears the field it was typed in.
        let line: String?
        /// What this confirm does when it is not a `LifecycleAction` this model can issue on its own — the header's
        /// terminal handoff, which needs the window's pane runner.
        let work: (@MainActor () async -> Bool)?
    }

    /// Takes the waiting confirm, and leaves nothing behind: a `cancelPending()` arriving after this one has nothing
    /// left to clear, which is exactly what makes the dismissal harmless.
    func claimPending() -> ClaimedConfirmation? {
        guard let pending = pendingConfirmation else { return nil }
        let claim = ClaimedConfirmation(confirmation: pending, line: confirmedLine, work: confirmedWork)
        pendingConfirmation = nil
        confirmationDetail = nil
        confirmedLine = nil
        confirmedWork = nil
        return claim
    }

    /// The waiting confirm, answered yes: claimed synchronously, run in a task.
    ///
    /// The two halves are separate members because the claim has to happen in the button's own call — before the
    /// dialog's dismissal, which is the very next thing SwiftUI does — while the work cannot.
    func answerPending() {
        guard let claim = claimPending() else { return }
        Task { await confirm(claim) }
    }

    /// A claimed confirm, run. The only place the three destructive actions are issued, the only place trust is
    /// granted for a directory, and the only place a confirmed handoff is performed.
    @discardableResult
    func confirm(_ claim: ClaimedConfirmation) async -> Bool {
        let issued: Bool
        if let action = claim.confirmation.action {
            issued = await issue { _ = try await self.lifecycle.perform(action, on: self.key) }
        } else if case .trustDirectory(let directory, let path) = claim.confirmation {
            issued = await grantTrust(directory: directory, path: path)
        } else if let work = claim.work {
            issued = await work()
        } else {
            issued = false
        }
        if issued, let line = claim.line, draft.hasPrefix(line) { draft = String(draft.dropFirst(line.count)) }
        return issued
    }

    /// §7.7's `/cd` row, second half: the same `set_cwd` again, carrying `trust_accepted` **and**
    /// `trusted_directory` echoing the directory the engine's own answer named.
    ///
    /// The echo is the whole point — `trust_accepted` alone is refused, and echoing the path the host
    /// asked for rather than the one the engine resolved would grant trust to a different directory.
    /// `CommandRouter.continueCD` builds it, so this file builds no request of its own (X10).
    private func grantTrust(directory: String, path: String) async -> Bool {
        let request = AnyControlRequest(CommandRouter.continueCD(afterNeedsTrust: directory, path: path))
        do {
            let answer = try await lifecycle.send(request, on: key)
            editNote = Self.directoryNote(answer)
            adoptDirectory(answer)
            return true
        } catch {
            refuse(error)
            return false
        }
    }

    /// What the second `set_cwd` did, without naming the directory a second time: the user has just
    /// been asked about it and the answer's own `cwd` is a path (§11). `transcript_relocated` is
    /// worth saying because the conversation's records moved with it (§7.3).
    static func directoryNote(_ answer: JSONValue) -> String {
        guard answer["status"]?.stringValue == "ok" else {
            return "The channel's directory did not change."
        }
        return answer["transcript_relocated"]?.boolValue == true
            ? "The channel's directory changed, and its transcript moved with it."
            : "The channel's directory changed."
    }

    /// **A directory change is taken the moment the engine confirms it**, from either half of §7.7's `/cd`
    /// row: the plain `set_cwd` and the `trust_accepted` one that follows a `needs_trust`.
    ///
    /// The `!` escape runs in `context.cwd`, and the context is otherwise refreshed from a **later** browser-row
    /// update — so a shell command submitted between the confirmation and that update ran in the directory the
    /// channel had just left, which is the one thing in this leaf that cannot be undone afterwards. The registry
    /// re-resolves the context; nothing here builds one.
    ///
    /// `{status: "ok", cwd: <resolved>}` is the accepted answer and a `needs_trust` one carries no `cwd`
    /// (`RuntimeState`, from the `control-shapes` recording), so the presence of `cwd` is the whole test — and it
    /// is the engine's own resolved directory rather than the path the host asked for.
    private func adoptDirectory(_ answer: JSONValue) {
        guard let resolved = answer["cwd"]?.stringValue else { return }
        didChangeDirectory?(URL(fileURLWithPath: resolved))
    }

    /// One routed control request, with its **answer read**.
    ///
    /// The only answer this leaf reads anything out of is `set_cwd`'s: `{status: "needs_trust",
    /// directory}` is a success envelope that changed nothing (§7.7's `/cd` row), so a dispatch that
    /// looked only at "it did not throw" reported a directory change that never happened and dropped
    /// the line. Everything else answers with a body the pickers or a strategy read, or with nothing.
    private func sendRouted(_ request: AnyControlRequest) async -> Bool {
        do {
            let answer = try await lifecycle.send(request, on: key)
            guard request.subtype == SetCwd.subtype else { return true }
            guard answer["status"]?.stringValue == "needs_trust",
                  let directory = answer["directory"]?.stringValue
            else {
                adoptDirectory(answer)
                return true
            }
            // Nothing has changed yet, so the line stays in the field until the question is answered.
            pendingConfirmation = .trustDirectory(directory: directory,
                                                  path: request.payload["path"]?.stringValue ?? directory)
            return false
        } catch {
            refuse(error)
            return false
        }
    }

    /// What a strategy answered, in front of the user.
    ///
    /// Every case carries a value the strategy read off the engine, and a dispatch that dropped it
    /// left a cleared line and nothing to show for it. The surface is the composer's own note, the one
    /// *Edit* already writes to: a permissions view, an MCP popover and a memory list are panels of
    /// their own, which this leaf does not draw (tracker 206). Counts and the engine's own sentences
    /// only — a memory file is a path and a signed-in account is an address, and neither is named
    /// here (§11).
    /// `draftWhenIssued` is what the field held when the command went out, for the one arm that
    /// writes into the field. Nil means "write it": a caller that is not dispatching a typed line has
    /// no typing to protect.
    func present(_ outcome: StrategyOutcome, draftWhenIssued: String? = nil) {
        switch outcome {
        case .rewind(let preview, let done):
            editNote = Self.rewindNote(preview, done)
            // The prompt the engine handed back for an honoured rewind, exactly as it sent it — the
            // same prefill *Edit* puts in the field, on *Edit*'s terms: only over the words the
            // command was issued with, and otherwise the typing is kept and the note says so.
            if done?.rewound == true, let prefill = done?.prefillText {
                if let draftWhenIssued, draft != draftWhenIssued {
                    editNote = Self.typedAheadNote
                } else {
                    draft = prefill
                }
            }
        case .login(_, let done):
            switch done {
            case .signedIn: editNote = "Signed in."
            case .noActiveFlow(let reason): editNote = reason
            }
        case .permissions(let view):
            editNote = "\(view.applied.count) applied setting(s): "
                + view.applied.keys.sorted().joined(separator: ", ") + "."
        case .mcp(let popover):
            editNote = "\(popover.servers.count) MCP server(s)."
        case .memory(let files):
            editNote = "\(files.count) memory file(s)."
        case .answered, .notARequest:
            break
        }
    }

    /// `/rewind`'s outcome as a sentence: what a revert would have changed, or what it did, or that it
    /// was refused and what is offered instead (parent §8.5 item 13). Counts and the engine's own
    /// reason; never a file name.
    static func rewindNote(_ preview: RewindPreview, _ done: RewindOutcome?) -> String {
        guard let done else {
            return "Nothing was rewound. A revert would have changed \(preview.filesChanged.count) file(s)."
        }
        guard done.rewound else {
            let reason = done.error.map { ": \($0)" } ?? "."
            return "The conversation was not rewound\(reason) Fork from here is offered on that message."
        }
        guard let files = done.files else { return "The conversation was rewound." }
        return "The conversation was rewound; \(files.skippedLinks) file(s) were left as they were."
    }

    /// Answered no. Nothing has reached the lifecycle and the typed line stays where it was.
    func cancelPending() {
        pendingConfirmation = nil
        confirmationDetail = nil
        confirmedLine = nil
        confirmedWork = nil
    }

    /// One X5 call, with this leaf's two refusal arms around it: a `LifecycleError` is explained
    /// inline and **never retried**, and anything else says the channel did not answer.
    func issue(_ call: @escaping () async throws -> Void) async -> Bool {
        do {
            try await call()
            return true
        } catch {
            refuse(error)
            return false
        }
    }

    /// The same two arms, for the branches that read their own answer and so cannot hand the call to
    /// `issue(_:)`. One spelling of the refusal, in one place.
    func refuse(_ error: any Error) {
        if let lifecycle = error as? LifecycleError {
            refusal = Self.explanation(of: lifecycle)
        } else {
            refusal = "The channel did not answer; your line is still in the field."
        }
    }
}

// MARK: - Autocomplete

extension ComposerModel {

    /// What autocomplete offers, from `CommandRouter.autocomplete(handshake:systemInit:)` **verbatim**
    /// over the two values this channel's stream reported.
    ///
    /// No list is written here and none is cached: the engine's own commands merged with the local
    /// table, minus everything the engine declared terminal-only, is one function's answer and this
    /// is the call to it (X10).
    var completions: [String] {
        CommandRouter.autocomplete(handshake: handshake, systemInit: systemInit)
    }

    /// Those matching what has been typed so far. The filter is a prefix on the whole line's first
    /// token, which is presentation and not routing — what each name *does* is still the table's.
    func completions(matching line: String) -> [String] {
        let token = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard token.hasPrefix("/") else { return [] }
        return completions.filter { $0.hasPrefix(token) }
    }

    /// True while the draft is a command line and the popover has something to offer.
    var isCompleting: Bool { !completions(matching: draft).isEmpty && !draft.contains(" ") }
}

// MARK: - Reading the stream

extension ComposerModel {

    /// What the composer takes off its own `events(of:)` subscription: the two engine reports the
    /// router needs, and every complete assistant text for the drift interceptor.
    ///
    /// Nothing here reduces anything into a timeline. This leaf observes the stream; C6.1 renders it.
    func observe(_ event: WireEvent) async {
        switch event {
        case .handshakeCompleted(let handshake, _):
            self.handshake = handshake.initialize
            // The mode picker's readback: `current_permission_mode` is the engine's own report and
            // the only one that exists for permission mode (§7.4). Recorded, never queried — noting
            // a handshake reaches no lifecycle member, so a channel that has just connected does not
            // spend two control requests before anything has asked for a picker.
            // A handshake is also the first moment a channel that was archived when its picker was
            // drawn has a process to answer to, so this is where an unanswered refresh is retaken.
            await pickers.noteHandshake(handshake.initialize)
        case .frame(let frame, _):
            await observe(frame)
        case .sessionIdentityResolved, .request, .requestCancelled, .policyAnswered, .unansweredDialog,
             .hostToolInvoked, .stderr, .exited:
            break
        }
    }

    private func observe(_ frame: Frame) async {
        switch frame {
        case .system(.initialize(let initialize)):
            systemInit = initialize.fields
        case .assistant(let assistant):
            await interceptDrift(in: assistant)
        case .promptSuggestion(let suggestion):
            noteSuggestion(suggestion)
        default:
            break
        }
    }

    /// One complete assistant message through the channel's `RefusalInterceptor`.
    ///
    /// A **complete** message and never a `stream_event` delta: the match is against the whole text,
    /// and a delta is by construction a fragment of one, so feeding deltas would either match nothing
    /// or match a sentence the engine had not finished writing.
    private func interceptDrift(in frame: AssistantFrame) async {
        let text = Self.completeText(of: frame)
        guard !text.isEmpty, let hit = await interceptor.intercept(text) else { return }
        interceptedReplacements[frame.fields.uuid] = hit.replacement
        lastInterception = hit
    }

    /// The message's text as one string. Only `text` blocks: a thinking or tool-use block is not
    /// something the engine said to the user, and including one could only make a whole-string match
    /// fail on a refusal that is genuinely the whole message.
    static func completeText(of frame: AssistantFrame) -> String {
        frame.fields.message.fields.content
            .compactMap { if case .text(let block) = $0 { block.fields.text } else { nil } }
            .joined()
    }
}

// MARK: - StrategyUI

/// The two things a multi-step strategy asks the app for (`FleetKit.StrategyUI`): a browser tab and
/// an answer to `/rewind`'s confirmation.
extension ComposerModel: StrategyUI {

    /// Hands the URL to the Browser tab as a `WorkspaceLink.url`, through the channel context's own
    /// link-routing capability. The composer registers no target and opens no window itself: routing
    /// is the host's, because a `.newWindow` destination has to pop a tab out before delivery.
    ///
    /// A string that is not a URL, and a channel the panel host has never drawn, both open nothing —
    /// there is no Browser tab to hand it to, and inventing an external open would take the user out
    /// of the app for a sign-in that belongs inside it.
    func open(url: String) async {
        guard let parsed = URL(string: url), let links = context?.links else { return }
        await links.open(.url(parsed), from: .currentPanel)
    }

    /// Puts the dry run's counts in front of the user and answers with what they chose.
    ///
    /// Nothing is sent while this is suspended: `StrategyExecutor` runs the read-only dry run first
    /// and waits here before any rewind goes out. A second preview arriving while one is unanswered
    /// cancels the first rather than dropping its continuation, which would hang the strategy behind
    /// it for ever.
    func confirm(preview: RewindPreview) async -> RewindChoice {
        await withCheckedContinuation { continuation in
            rewindAnswer?.resume(returning: .cancel)
            rewindPreview = preview
            rewindAnswer = continuation
        }
    }

    /// The sheet's answer. Called by the view; the strategy resumes with exactly this choice.
    func answerRewind(_ choice: RewindChoice) {
        rewindPreview = nil
        rewindAnswer?.resume(returning: choice)
        rewindAnswer = nil
    }
}
