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
/// A value over `LifecycleAction` rather than a flag per action, so the three share one gate: each
/// closes shells or signs sessions out on this whole machine, and none of them may be reached by a
/// mistyped chord or an autocompleted line.
enum ComposerConfirmation: String, Hashable, Sendable, CaseIterable {
    case stopEverything
    case backgroundAll
    case logout

    /// Nil for every action that needs no confirm — a plain fork and a send to background are the
    /// channel's own business and are issued directly.
    init?(_ action: LifecycleAction) {
        switch action {
        case .stopEverything: self = .stopEverything
        case .backgroundAll: self = .backgroundAll
        case .logout: self = .logout
        default: return nil
        }
    }

    var action: LifecycleAction {
        switch self {
        case .stopEverything: .stopEverything
        case .backgroundAll: .backgroundAll
        case .logout: .logout
        }
    }

    var title: String {
        switch self {
        case .stopEverything: "Stop everything in this channel?"
        case .backgroundAll: "Send every live channel to the background?"
        case .logout: "Sign out of every channel on this machine?"
        }
    }

    var message: String {
        switch self {
        case .stopEverything: "The running turn and every background task in this channel stop. Their shells close."
        case .backgroundAll: "Every channel afleet owns hands off to a background job and its window goes quiet."
        case .logout: "Every owned channel and every afleet-launched job on this machine signs out."
        }
    }

    var confirmTitle: String {
        switch self {
        case .stopEverything: "Stop Everything"
        case .backgroundAll: "Send to Background"
        case .logout: "Sign Out"
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
            return await issue { _ = try await self.lifecycle.send(request, on: self.key) }
        case .strategy(let strategy, let arguments):
            return await issue {
                _ = try await self.lifecycle.run(strategy, arguments: arguments, on: self.key, ui: self)
            }
        case .lifecycle(let action):
            return await dispatch(action: action)
        case .restart(let request):
            return await issue { _ = try await self.lifecycle.perform(.quiescentRestart(request), on: self.key) }
        case .text(let text):
            return await issue { _ = try await self.lifecycle.perform(.send(UserInput(text: text)), on: self.key) }
        case .native(let surface):
            // Nothing reaches the lifecycle: a picker, a list or the switcher is afleet's own screen.
            openSurface = surface
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

    /// The waiting confirm, answered yes. The only place the three destructive actions are issued.
    @discardableResult
    func confirmPending() async -> Bool {
        guard let pending = pendingConfirmation else { return false }
        pendingConfirmation = nil
        let issued = await issue { _ = try await self.lifecycle.perform(pending.action, on: self.key) }
        if issued, let line = confirmedLine, draft.hasPrefix(line) { draft = String(draft.dropFirst(line.count)) }
        confirmedLine = nil
        return issued
    }

    /// Answered no. Nothing has reached the lifecycle and the typed line stays where it was.
    func cancelPending() {
        pendingConfirmation = nil
        confirmedLine = nil
    }

    /// One X5 call, with this leaf's two refusal arms around it: a `LifecycleError` is explained
    /// inline and **never retried**, and anything else says the channel did not answer.
    private func issue(_ call: @escaping () async throws -> Void) async -> Bool {
        do {
            try await call()
            return true
        } catch let error as LifecycleError {
            refusal = Self.explanation(of: error)
            return false
        } catch {
            refusal = "The channel did not answer; your line is still in the field."
            return false
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
