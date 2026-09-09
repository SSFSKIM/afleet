import Foundation
import AfleetCore
import ClaudeWire
import FleetKit

/// *Edit* on a past user message: the conversation rewind, and *Fork from here* when the engine
/// refuses it (spec §8.5, C6.2 *Edit, rewind and “Fork from here”*, gate G4).
///
/// **This is not `/rewind`.** The slash command is a strategy that also moves files; *Edit* is one
/// `rewind_conversation` through `LifecycleAPI.send(_:on:)` and nothing else. No `rewind_files`
/// request is emitted here in either direction, on either answer.
///
/// **The request always carries `last_seen_user_message_uuid`, and its value is the newest user
/// message this composer has rendered — never the edit target's own uuid.** The probe
/// `spike_rewind_last_seen` measured all three arms on 2.1.263: naming the newest user message
/// honours a target from before the running process, omitting the field refuses it with
/// `"stale target"`, and naming the target itself refuses it with `"unseen later turn"`. The
/// obvious wrong value is therefore refused on every edit of an older message, and because a
/// refusal falls back to a fork the mistake would look like a working feature.
///
/// **The body is read, never the envelope.** A refusal arrives inside `control_response
/// {subtype: "success"}` with a body-level `error` string (fixture `rewind-turn`), so a composer
/// that decided from the envelope would report every refusal as a completed rewind.
@MainActor
extension ComposerModel {

    /// Every user message this channel's timeline has rendered, in the fold's own order.
    ///
    /// Read out of the `ChannelTimelineModel` the registry pointed this composer at — the channel's
    /// one fold (contract X4). There is no second place to learn what the user has been shown.
    var renderedUserMessages: [UserMessageItem] {
        guard let timelines else { return [] }
        return timelines.timeline.items.compactMap {
            if case .userMessage(let message) = $0, !message.promptUUID.isEmpty { message } else { nil }
        }
    }

    /// The uuid the request names as the last user message this host has seen: the newest rendered
    /// one, and nil only for a composer whose timeline holds no user message at all.
    var lastSeenUserMessageUUID: String? { renderedUserMessages.last?.promptUUID }

    /// The refusal dialog's *Edit the prompt*: the last prompt goes back into the field.
    ///
    /// **Only into an empty field, which is the engine's own guard** (`cli.pretty.js:523717`
    /// requires the input box to be empty before it restores). A user who typed while the dialog
    /// was up is looking at words the restore would silently replace, and the prompt they would
    /// lose is the one still visible in the conversation above.
    ///
    /// The text is the newest **main-stream** user message's, because that is the message the
    /// refused turn was for — the engine restores the last human-typed message of the conversation
    /// (`cli.pretty.js:523721`, whose predicate takes a human-origin user message and rejects the
    /// synthetic ones).
    ///
    /// **The stream filter is what makes it the user's prompt.** `renderedUserMessages` is the
    /// merged timeline, and a subagent's stream carries user messages of its own — the run's
    /// instructions, which the user never typed and which sort after the main thread's newest
    /// prompt for as long as the run is live. Restoring one of those would put another agent's
    /// errand in the field and call it the user's words. `isReplay` goes for the same reason: a
    /// replayed `--agent` opening prompt is the engine's, not this user's.
    func restoreLastPrompt() {
        guard draft.isEmpty, let last = Self.lastHumanPrompt(in: renderedUserMessages) else { return }
        draft = last.text
    }

    /// Which of the rendered user messages the restore takes: the newest on the **main** stream that
    /// is not a replay.
    ///
    /// A function over the list rather than a filter spelled inside `restoreLastPrompt`, because the
    /// choice is the whole of what this behaviour is and a choice buried in a mutation is a choice
    /// no test can put a disagreeing list in front of.
    static func lastHumanPrompt(in messages: [UserMessageItem]) -> UserMessageItem? {
        messages.last { $0.id.stream.name == .main && !$0.isReplay }
    }

    /// *Edit* on one rendered user message.
    ///
    /// Honoured → the field is prefilled with `prefillText` **exactly as the engine returned it**,
    /// and `HostSignal.rewound` is raised so the channel's fold drops the turn the engine dropped.
    /// Refused → the fallback below, on any body-level `error`, because the engine has ten of them
    /// and the composer's contract is that a refusal is never shown as a success.
    func edit(_ target: UserMessageItem) async {
        editNote = nil
        refusal = nil
        // What the field held when the edit was asked for. The request is an await and the user keeps typing across
        // it, so the prefill is written only over the words the edit began with: overwriting the ones typed since
        // would throw away input the user can see in front of them and never gave to anything.
        let draftWhenAsked = draft
        guard let lastSeen = lastSeenUserMessageUUID else {
            editNote = Self.noRenderedMessagesNote
            return
        }
        // The typed spec, not the raw form: ClaudeWire types this subtype and its initialiser
        // carries `last_seen_user_message_uuid`, so spelling the payload here would be a second
        // opinion about a shape C2 owns (contract Y5).
        let request = AnyControlRequest(RewindConversation(targetMessageUUID: target.promptUUID,
                                                          lastSeenUserMessageUUID: lastSeen))
        let answer: JSONValue
        do {
            answer = try await lifecycle.send(request, on: key)
        } catch let error as LifecycleError {
            editNote = Self.explanation(of: error)
            return
        } catch {
            editNote = "The conversation was not rewound; nothing was changed."
            return
        }

        guard answer["rewound"]?.boolValue == true else {
            await forkInstead(of: target, because: answer["error"]?.stringValue)
            return
        }

        if let prefill = answer["prefillText"]?.stringValue {
            if draft == draftWhenAsked { draft = prefill } else { editNote = Self.typedAheadNote }
        }
        // **The leaf the engine now holds is `precedingAssistantUuid`, not the target.** The
        // `rewind-turn` fixture measured it: after the honoured rewind the transcript's
        // `last-prompt.leafUuid` names the assistant record *before* the rewound turn, and the
        // turn's own three records are the abandoned branch below it. Raising the target instead
        // would leave the edited message standing in a timeline the engine has discarded. The
        // target is the fallback only for an answer that omits the field.
        let leaf = answer["precedingAssistantUuid"]?.stringValue ?? target.promptUUID
        await timelines?.signal(.rewound(toUUID: leaf))
        recordRewindSignal()
    }

    // MARK: - The fallback

    /// *Fork from here*, taken on **every** refusal: `"stale target"`, `"unseen later turn"` and any
    /// other body-level `error`.
    ///
    /// The fork point comes from the channel's own items, because the refusal's
    /// `precedingAssistantUuid` is `null`: `entryUUID` is the **last record** of the assistant item immediately
    /// before the edited message — the last record the fork keeps, inclusive — and `dropsTurn` is the edited
    /// message's `promptUUID`, the turn the truncation discards.
    ///
    /// **The prefill belongs to the fork, not to this channel.** X5's `fork(at:on:)` answers the sibling's key —
    /// `perform(.fork)` answers this channel's state and names the sibling nowhere — and the edited message's text
    /// goes into that channel's composer, which the registry hands it whenever that composer is first built. This
    /// composer's own draft is left exactly as the user left it: a prefill written here is a message the user
    /// believes is going into the fork and which the engine receives on the conversation they edited away from.
    ///
    /// **And it belongs to the fork's own identity, not to the id the spawn was minted under.** `fork(at:on:)`
    /// answers while the sibling is still keyed on a provisional session the engine has not confirmed, and the fleet
    /// re-keys the channel when `auth_status` brings its own id. The registry keys both the pending prefill and the
    /// selection by that key, and the browser lists the fork under the resolved id — so handing off the provisional
    /// one selects nothing and strands the draft under a channel that never appears. `resolvedForkKey(of:)` is X5's
    /// answer to which channel this fork became, and it is what the handoff names.
    ///
    /// The **note** stays here, because this is the channel the user is looking at and the note is what explains
    /// where the edit went.
    ///
    /// The wording distinguishes the two known refusals; the path does not.
    private func forkInstead(of target: UserMessageItem, because reason: String?) async {
        guard let entry = precedingAssistantRecord(before: target) else {
            editNote = Self.noForkPointNote(reason)
            return
        }
        do {
            let provisional = try await lifecycle.fork(at: ForkPoint(entryUUID: entry, dropsTurn: target.promptUUID),
                                                       on: key)
            // Said before the identity is waited on: the fork is open either way, and this sentence is what the user
            // is owed for the edit they just made rather than something that arrives with the engine's `auth_status`.
            editNote = Self.forkNote(reason)
            handOffToFork?(await lifecycle.resolvedForkKey(of: provisional), target.text)
        } catch let error as LifecycleError {
            editNote = Self.explanation(of: error)
        } catch {
            editNote = "The conversation was not rewound and no fork was opened."
        }
    }

    /// The **last record** of the assistant item immediately preceding `target` in the fold's order, and nil when
    /// the edited message is the first thing in the conversation — which is a message with no fork point at all,
    /// not a fork from the beginning.
    ///
    /// **The last record, not the item's key.** `ItemBuilder` merges an assistant message's records into one item
    /// keyed by the *first* of them and keeps them all in `recordUUIDs`; the `rewind-turn` fixture has two per
    /// assistant message. `entryUUID` is the last record the fork **keeps**, inclusive, so naming the item's key
    /// would cut the preceding turn in half — dropping records the user still sees while `dropsTurn` claims only
    /// the edited turn was discarded.
    private func precedingAssistantRecord(before target: UserMessageItem) -> String? {
        guard let timelines else { return nil }
        let items = timelines.timeline.items
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return nil }
        for item in items[..<index].reversed() {
            if case .assistantMessage(let assistant) = item { return assistant.recordUUIDs.last ?? assistant.id.key }
        }
        return nil
    }

    // MARK: - What the composer says

    /// The two known refusals read differently to the user; every other one is named as a refusal
    /// without pretending to explain it. None of these prints a path, a title or a session (§11).
    static func forkNote(_ reason: String?) -> String {
        switch reason {
        case "stale target":
            "The conversation was not rewound — the engine could not reach that message — so a fork was opened from just before it instead."
        case "unseen later turn":
            "The conversation was not rewound — a later turn arrived that afleet had not shown yet — so a fork was opened from just before that message instead."
        default:
            "The conversation was not rewound, so a fork was opened from just before that message instead."
        }
    }

    static func noForkPointNote(_ reason: String?) -> String {
        switch reason {
        case "stale target":
            "The conversation was not rewound — the engine could not reach that message — and there is no reply before it to fork from, so nothing was changed."
        case "unseen later turn":
            "The conversation was not rewound — a later turn arrived that afleet had not shown yet — and there is no reply before that message to fork from, so nothing was changed."
        default:
            "The conversation was not rewound, and there is no reply before that message to fork from, so nothing was changed."
        }
    }

    /// The honoured rewind whose prefill was **not** written, because the user typed while the request was in
    /// flight. Their own words stay in the field and the engine's are not silently dropped without saying so.
    static let typedAheadNote =
        "The conversation was rewound. You typed while that was in flight, so what you typed was kept and the "
        + "edited message was not put back in the field."

    static let noRenderedMessagesNote =
        "This channel has shown no messages yet, so there is nothing to rewind to."
}
