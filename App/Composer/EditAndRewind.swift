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

    /// *Edit* on one rendered user message.
    ///
    /// Honoured → the field is prefilled with `prefillText` **exactly as the engine returned it**,
    /// and `HostSignal.rewound` is raised so the channel's fold drops the turn the engine dropped.
    /// Refused → the fallback below, on any body-level `error`, because the engine has ten of them
    /// and the composer's contract is that a refusal is never shown as a success.
    func edit(_ target: UserMessageItem) async {
        editNote = nil
        refusal = nil
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

        if let prefill = answer["prefillText"]?.stringValue { draft = prefill }
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
    /// `precedingAssistantUuid` is `null`: `entryUUID` is the `ItemID.key` of the assistant item
    /// immediately before the edited message — the last record the fork keeps, inclusive — and
    /// `dropsTurn` is the edited message's `promptUUID`, the turn the truncation discards.
    ///
    /// The wording distinguishes the two known refusals; the path does not.
    private func forkInstead(of target: UserMessageItem, because reason: String?) async {
        guard let entry = precedingAssistantKey(before: target) else {
            editNote = Self.noForkPointNote(reason)
            return
        }
        do {
            _ = try await lifecycle.perform(.fork(at: ForkPoint(entryUUID: entry, dropsTurn: target.promptUUID)),
                                            on: key)
            draft = target.text
            editNote = Self.forkNote(reason)
        } catch let error as LifecycleError {
            editNote = Self.explanation(of: error)
        } catch {
            editNote = "The conversation was not rewound and no fork was opened."
        }
    }

    /// The `ItemID.key` of the assistant item immediately preceding `target` in the fold's order, and
    /// nil when the edited message is the first thing in the conversation — which is a message with
    /// no fork point at all, not a fork from the beginning.
    private func precedingAssistantKey(before target: UserMessageItem) -> String? {
        guard let timelines else { return nil }
        let items = timelines.timeline.items
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return nil }
        for item in items[..<index].reversed() {
            if case .assistantMessage(let assistant) = item { return assistant.id.key }
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

    static let noRenderedMessagesNote =
        "This channel has shown no messages yet, so there is nothing to rewind to."
}
