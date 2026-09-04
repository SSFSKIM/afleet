"""Hand-written dialog fixtures for S6 (spec §4.7), read out of the 2.1.257 bundle.

`chunk-1kg58a1a.js` carries both dialog declarations and the loop that consumes their answers:
`refusal_fallback_prompt` with payload {originalModel, fallbackModel, apiRefusalCategory?,
guidanceText?, retractedMessageUuids?} and result enum retry_fallback|edit_prompt|cancelled;
`fable_overage_consent_prompt` with payload {overagesEnabled, modelName?, balanceCents?,
currency?} and result enum consent|switch_default|cancelled. Both declare `default:
"cancelled"`, which is what makes the close path -- a `{"behavior": "cancelled"}` answer with
no `result` at all -- indistinguishable from an explicit `cancelled`, and both fixtures show
the pair so no consumer reads the missing field as a fifth outcome.

`chunk-sct99ax9.js` carries the frame schemas the answers produce: `assistant.supersedes`,
`system/model_refusal_fallback` and `system/model_consent_fallback`. It also carries a
`tombstone` schema, which is *not* used here: the same module's emitter filter drops the
event before the wire and the parity inventory rates it "Dropped (45.9.2)", so a fixture
carrying one would assert a frame no host can receive.

S6 has since extracted the same strings from the installed 2.1.259 binary --
`Tools/probe/spikes/extract_dialog_enums.py` finds each dialog kind and each frame subtype at
its own definition site and requires the payload keys, the enum values and `default:
"cancelled"` to sit inside a bounded window after it -- so both fixtures now carry
`hypothesis: false`. `synthetic: true` stays, because how the engine reaches these shapes is
still unrecorded and a synthetic fixture is never baseline evidence by itself. `CLI_VERSION`
still reads `2.1.257-bundle`: that bundle is where the frames were authored, and the cleared
flag is the separate claim that the installed baseline agrees with it.

Two properties this module owes the rest of the pipeline.

*The build is deterministic.* `make synthetic` rebuilds both fixtures byte for byte on any
machine, so a reviewer can rerun it and diff the result against what is committed. Nothing
here reads the clock, the environment or the host, and nothing runs the redactor over the
frames: §4.5's rules substitute the *recording* machine's home directory and hostname, which
would make the output differ between machines while removing nothing, because no byte here
ever came off a machine. `redaction.json` still carries the full six-rule manifest at zero
counts, which is what §4.4 asks for and what REVIEW.md item 4 has a reviewer confirm.

*Nothing is invented beyond the bundle.* Every field these fixtures carry is a claim later
children build gates on, so a frame holds the keys the
bundle shows and no more. A plausible-looking `result` frame with an invented `total_cost_usd`
would enter the census as a required key that no evidence supports.
"""
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import census   # noqa: E402
import fixture  # noqa: E402
import redact   # noqa: E402
import verify   # noqa: E402

SID_R = "44444444-4444-4444-8444-444444444444"
SID_F = "55555555-5555-4555-8555-555555555555"
CWD = "/private/tmp/afleet-fixtures/synthetic"
CLI_VERSION = "2.1.257-bundle"


def _init_pair(t):
    return [{"t": t, "dir": "in", "frame": {"type": "control_request", "request_id": "init-1", "request": {"subtype": "initialize",
             "supportedDialogKinds": ["refusal_fallback_prompt", "fable_overage_consent_prompt"]}}},
            {"t": t + 5, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "init-1",
             "response": {"commands": [], "models": [], "current_model": "opus", "current_permission_mode": "default"}}}}]


def _dialog(t, rid, kind, payload, answer):
    frames = [{"t": t, "dir": "out", "frame": {"type": "control_request", "request_id": rid,
               "request": {"subtype": "request_user_dialog", "dialog_kind": kind, "payload": payload}}}]
    if answer is None:
        frames.append({"t": t + 1500, "dir": "out", "frame": {"type": "control_cancel_request", "request_id": rid}})
    else:
        frames.append({"t": t + 200, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": answer}}})
    return frames


def _user(t, uid, text):
    return {"t": t, "dir": "in", "frame": {"type": "user", "uuid": uid, "parent_tool_use_id": None, "origin": {"kind": "human"},
                                           "message": {"role": "user", "content": text}}}


def _assistant(t, uid, sid, text, **extra):
    """The `assistant` frame as `chunk-1kg58a1a.js`'s stream-json mapper emits it: `type`,
    `message`, `parent_tool_use_id` (always, always null on the main thread), `uuid`,
    `session_id`, and `supersedes` only when the message replaces earlier wire uuids."""
    f = {"type": "assistant", "uuid": uid, "parent_tool_use_id": None, "session_id": sid,
         "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}
    f.update(extra)
    return {"t": t, "dir": "out", "frame": f}


def _result(t, text, subtype="success", is_error=False):
    """Both `result` schemas require `is_error`, so it is always written even when false.

    The rest of what those schemas require -- `duration_ms`, `total_cost_usd`, `usage`,
    `modelUsage` and the rest -- is deliberately absent: this fixture has no measurements to
    put there and a fabricated zero would enter the census as a shape nothing observed. The
    fields present are the ones whose value is known from the branch that produced the frame.
    """
    return {"t": t, "dir": "out", "frame": {"type": "result", "subtype": subtype, "result": text,
                                            "is_error": is_error, "num_turns": 1}}


PARTIAL_TEXT = "partial text before the refusal"

# The category the fixture sends decides which safeguards sentence the CLI writes:
# `Xte(e){return e==="cyber"||e==="bio"}` selects the broad-safeguards sentence and anything
# else selects the "safe, normal conversations" one. `bio` therefore commits both content
# strings below to the first branch. Separately, `mTe` appends `\n\nDetails: `[<category>]``
# for *any* non-empty category, so the suffix is not branch-specific and is always present.
CATEGORY = "bio"
SAFEGUARDS = ("Our intentionally broad safeguards allow us to deliver more capabilities faster, but can "
              "sometimes flag legitimate coding, cybersecurity, and biology tasks.")
DETAILS = "\n\nDetails: `[%s]`" % CATEGORY

# `chunk-1kg58a1a.js` assembles the refusal message from a prefix, that sentence, an edit hint
# and a "learn more" URL -- the last two chosen by a predicate this fixture cannot evaluate --
# and then the Details suffix. What is readable verbatim is carried; the rest is marked, and
# the README lists it as something a recording has to settle. Inventing the URL would put a
# string a rendering test could be written against into a fixture that never saw one.
REFUSAL_PROSE = ("[placeholder: a short prefix label] Fable 5's safeguards flagged this message "
                 "(https://www.anthropic.com/legal/aup). " + SAFEGUARDS +
                 " [placeholder: an edit hint and a learn-more URL, both chosen by a branch this fixture "
                 "cannot resolve]" + DETAILS)


def refusal_frames():
    """The four dialog answers and what `chunk-1kg58a1a.js` emits after each.

    The branch is a single `if (result !== "retry_fallback")` in the refusal-fallback loop, so
    three of the four answers -- `edit_prompt`, `cancelled` and the close path, which the
    dialog schema's `default: "cancelled"` collapses onto `cancelled` -- share a tail. That
    collapse is itself something a host has to know, so the fixture shows the close path and
    `cancelled` producing the same frames rather than eliding one of them.

    What the decline legs deliberately do *not* carry is a retraction frame. The CLI's decline
    branch yields internal `tombstone` events, but `Gxn` in the same module lists `tombstone`
    among the event types the stream-json emitter filters out, its schema is annotated
    `@internal ... From internal QueryEvent 'tombstone'`, and `docs/tui-parity` rates it
    "Dropped (45.9.2)". So the wire carries no retraction signal on a decline at all, and the
    host's own eviction of `retractedMessageUuids` on resolution is the whole mechanism.
    §4.7's "tombstones after a refusal" is the parent's timeline sense of the word, which its
    §8.4 resolves to the `supersedes` rule -- not a frame type.
    """
    # `bio` rather than an invented category, and rather than one outside {cyber, bio}: the
    # per-category fallback map is keyed by exactly those two, and a category with no entry in
    # it is the case that routes to `model_refusal_no_fallback` instead of offering this dialog
    # at all. Choosing a category to dodge the broad-safeguards copy branch would have bought
    # the general sentence at the price of a dialog that might never be shown. `cyber` is the
    # other member and takes the same copy branch, differing in `saw_cyber_refusal` and in the
    # learn-more URL, so `bio` is the cheaper of the two to model.
    p = {"originalModel": "claude-fable-5-1", "fallbackModel": "claude-opus-5", "apiRefusalCategory": CATEGORY,
         "guidanceText": "The model declined; retry on the fallback model or edit your prompt."}
    fr = _init_pair(0)
    t = 100
    for n, answer in enumerate([{"behavior": "completed", "result": "retry_fallback"},
                                {"behavior": "completed", "result": "edit_prompt"},
                                {"behavior": "completed", "result": "cancelled"},
                                {"behavior": "cancelled"}]):
        partial, uid = "a-partial-%d" % n, "u%d" % n
        fr.append(_user(t, uid, "prompt %d" % n)); t += 50
        fr.append(_assistant(t, partial, SID_R, PARTIAL_TEXT)); t += 50
        fr += _dialog(t, "dlg-%d" % n, "refusal_fallback_prompt", dict(p, retractedMessageUuids=[partial]), answer); t += 300
        # `{"behavior": "cancelled"}` carries no `result`; the dialog schema's `default` makes
        # it `cancelled`, which is why the close path takes the `cancelled` tail below.
        choice = answer.get("result", "cancelled")
        if choice == "retry_fallback":
            fr.append(_assistant(t, "a-retry-%d" % n, SID_R, "answer from the fallback model", supersedes=[partial])); t += 50
            # The end-of-turn notice the `supersedes` schema calls idempotent with it.
            fr.append({"t": t, "dir": "out", "frame": {
                "type": "system", "subtype": "model_refusal_fallback", "trigger": "refusal", "direction": "retry",
                "scope": "session", "original_model": "claude-fable-5-1", "fallback_model": "claude-opus-5",
                "request_id": None, "api_refusal_category": CATEGORY, "api_refusal_explanation": None,
                # From the module's own notice builder: the category-selected safeguards
                # sentence, `Switched to <fallback>.`, a learn-more URL the fixture cannot
                # resolve, and the Details suffix.
                "retracted_message_uuids": [partial], "refused_user_message_uuid": uid,
                "content": ("Fable 5's safeguards flagged this message. " + SAFEGUARDS +
                            " Switched to Opus 5. [placeholder: a learn-more URL]" + DETAILS),
                "uuid": "s-%d" % n, "session_id": SID_R}}); t += 50
            fr.append(_result(t, "answer from the fallback model")); t += 50
        else:
            # No frame stands between the answer and the result on a decline: the CLI's
            # retraction events do not reach the wire, and `edit_prompt` only aborts the turn.
            if choice == "cancelled":
                # Only the `cancelled` branch builds a refusal message for the user.
                fr.append(_assistant(t, "a-refusal-%d" % n, SID_R, REFUSAL_PROSE)); t += 50
            fr.append(_result(t, "refusal", subtype="error_during_execution", is_error=True)); t += 50
    fr.append(_user(t, "u-undeclared", "prompt that triggers an undeclared kind")); t += 50
    fr += _dialog(t, "dlg-undeclared", "undeclared_probe_kind", {}, None); t += 1600
    fr.append(_result(t, "continued after the CLI cancelled its own dialog"))
    return fr


def _consent_content(persisted):
    """`model_consent_fallback.content`, from the template the module builds it with.

    Carried rather than paraphrased because the frame's `content` is what a decision card
    renders, so a child's rendering test written against invented copy would test nothing --
    and would miss that the real string ends in a `/model to change` instruction naming a
    slash command a GUI has to rewrite. The clause varies with `persisted_as_default`, so one
    string for every frame would have asserted that a persisted swap can say "for this
    session". The two model names substituted in are this fixture's synthetic models.
    """
    return ("Switched to Opus 5 %s · Fable 5 requires usage credits · /model to change"
            % ("— now your default model" if persisted else "for this session"))


def fable_frames():
    """Every outcome of the consent prompt, with `overagesEnabled` both ways.

    `consent` is only ever answered against `overagesEnabled: true`. The parent's §8.4 offers
    it "only when `overagesEnabled` is true, because a bare wire reply never enables billing",
    and its acceptance item 62 has the false branch stay pending until *Switch to the default
    model* or *Not now* -- so a leg answering `consent` to a false payload would depict a reply
    afleet is specified never to send, and a conforming host replaying this fixture would
    diverge from it. The false branch is covered instead by `switch_default` and by the close
    path, which is what item 62 actually asks for.
    """
    fr = _init_pair(0)
    t = 100
    cases = [(True, {"behavior": "completed", "result": "consent"}),
             (False, {"behavior": "completed", "result": "switch_default"}),
             (True, {"behavior": "completed", "result": "switch_default"}),
             (True, {"behavior": "completed", "result": "cancelled"}),
             (False, {"behavior": "cancelled"})]
    for n, (enabled, answer) in enumerate(cases):
        fr.append(_user(t, "u%d" % n, "prompt %d" % n)); t += 50
        payload = {"overagesEnabled": enabled, "modelName": "Fable 5", "balanceCents": 0 if enabled else None, "currency": "USD" if enabled else None}
        fr += _dialog(t, "fab-%d" % n, "fable_overage_consent_prompt", payload, answer); t += 300
        choice = answer.get("result", "cancelled")
        if not (choice == "consent" and enabled):
            persisted = choice == "switch_default"
            fr.append({"t": t, "dir": "out", "frame": {"type": "system", "subtype": "model_consent_fallback", "choice": choice,
                       "original_model": "claude-fable-5-1", "original_model_name": "Fable 5", "fallback_model": "claude-opus-5",
                       "persisted_as_default": persisted, "content": _consent_content(persisted),
                       "uuid": "mcf-%d" % n, "session_id": SID_F}}); t += 50
        fr.append(_assistant(t, "a-%d" % n, SID_F, "answer")); t += 50
        fr.append(_result(t, "answer")); t += 50
    return fr


def _prompts(frames):
    """The user messages the frames carry, which is what `prompts` truthfully means here.

    A recorded fixture takes `prompts` from the scenario's declaration of what `run()` sends.
    Nothing sent these, so the frames themselves are the only honest source, and REVIEW.md
    item 1 has a reviewer check `prompts` against them.
    """
    return [rec["frame"]["message"]["content"] for rec in frames if rec["frame"].get("type") == "user"]


REFUSAL_README = """# dialog-refusal-fallback (synthetic, shapes confirmed on 2.1.259)

What it shows: the CLI asking the host to resolve a model refusal. Four turns each stream a
partial assistant message, open a `request_user_dialog` of kind `refusal_fallback_prompt`
whose payload names that partial in `retractedMessageUuids`, and answer it a different way.

- `retry_fallback`: the retry runs, and its `assistant` frame carries `supersedes` naming
  the partial it replaces. The turn then ends with a `system/model_refusal_fallback` notice
  (`direction: "retry"`), whose `retracted_message_uuids` repeats the same retraction -- the
  two are documented as idempotent with each other, so a host may act on whichever arrives.
- `edit_prompt`: nothing at all between the answer and the result. The CLI aborts the turn so
  the user can edit.
- `cancelled`: an `assistant` frame carrying the refusal prose the CLI composes for the user.
- The close path, `{"behavior": "cancelled"}` with no `result` at all: identical to
  `cancelled`, because the dialog schema declares `default: "cancelled"`. A host that treats
  a missing `result` as a distinct outcome would be wrong, which is why both appear here.

**The decline legs carry no retraction signal on the wire, and that is the point.** The CLI's
decline branch does yield internal `tombstone` events, but they never reach a stream-json
host: the emitter's own filter lists `tombstone` among the event types it drops, the schema
is annotated `@internal ... From internal QueryEvent 'tombstone'`, and this repository's
parity inventory rates it "Dropped (45.9.2)" with a D verdict, listing a wire tombstone among
the signals the CLI still ought to add. So on `edit_prompt`, on `cancelled` and on the close
path there is nothing to react to, and the only mechanism a host has is the one the dialog
payload describes: evict the uuids in `retractedMessageUuids` yourself, on resolution --
"your own response (any choice) or `control_cancel_request` retirement, never on receipt", and
idempotently. Only the retry leg gets a wire signal, through `supersedes` and the notice's
`retracted_message_uuids`. A host that waits for a frame before evicting will leave the
refused partial on screen forever on three of the four outcomes.

A fifth turn opens a dialog of a kind the host never declared in
`initialize.supportedDialogKinds`. The host must leave it alone -- an error-shaped answer to
a parked dialog is swallowed -- and the CLI retires it itself with `control_cancel_request`,
the one shape in which a lifecycle closes without a response (spec §4.2).

**Whether that fifth turn can happen at all is open.** The parent's S6 and §6.3 mandate
modelling it, so the frames are not wrong to be here, but the parity inventory finds that
only three dialog families cross the wire and that every other kind "resolves to its declared
default immediately, whatever the host declares in `supportedDialogKinds`" -- which would mean
an undeclared kind never reaches a host to be left unanswered. `undeclared_probe_kind` is also
a synthetic placeholder: no binary contains that string, and a recording would have to
substitute a real kind outside the forwarded set. A recording should settle both.

**The fixture exercises the broad-safeguards copy branch, and only that one.** The CLI picks
the safeguards sentence from the refusal category: `cyber` and `bio` get "Our intentionally
broad safeguards allow us to deliver more capabilities faster, but can sometimes flag
legitimate coding, cybersecurity, and biology tasks", and every other category gets "This
sometimes happens with safe, normal conversations". This fixture sends `bio`, so both of its
copy strings carry the first sentence. The second branch is real and is **not covered here**;
a host rendering refusal copy should expect either. The category also drives a `Details:
`[<category>]`` suffix, which is appended for any non-empty category and so is present on both
branches and on both frames.

`bio` rather than a category from the other branch because the per-category fallback map is
keyed by exactly `cyber` and `bio`: a category with no entry in it is the case that routes to
`model_refusal_no_fallback` rather than offering this dialog at all, so picking a category to
obtain the general sentence would have bought copy coverage at the cost of a dialog that might
never be shown.

Serves item 62 and spike S6.

**These shapes are synthetic, and confirmed against the baseline.** Nothing here was recorded. Every field is read out of the
2.1.257 bundle: `chunk-1kg58a1a.js` for the dialog kind, its
`{originalModel, fallbackModel, apiRefusalCategory?, guidanceText?, retractedMessageUuids?}`
payload, its `retry_fallback | edit_prompt | cancelled` result enum with `default:
"cancelled"`, the decline branch, and the copy builders; `chunk-sct99ax9.js` for the
`assistant.supersedes` and `system/model_refusal_fallback` schemas. S6 then found
each of those definitions exactly once in the installed 2.1.259 baseline binary, with every
payload key, every enum value and `default: "cancelled"` inside its own definition's window,
so `fixture.json` carries `hypothesis: false` (spec §4.7). `synthetic: true` stays, and with
it the exclusion from `diff`: a synthetic fixture is never baseline evidence by itself, and
the list below is what no schema states and therefore what the extraction could not reach.

What a recording should settle, because no schema states it:

1. **Both `content` strings are partly placeholders.** The CLI assembles the refusal prose
   from a prefix, a category-dependent safeguards sentence, an edit hint and a learn-more URL.
   Only the safeguards sentence is readable verbatim; the rest is marked `[placeholder: ...]`
   in the frames rather than invented, because a rendering test written against invented copy
   would test nothing. The `model_refusal_fallback` notice is in the same position. The
   `edit_prompt` hint in the real copy names a keystroke and `/model`, both of which a GUI has
   to rewrite.
2. **The decline legs' `result` frames, subtype and text alike.** Both
   `subtype: "error_during_execution"` and the `"result": "refusal"` string are this fixture's
   assumptions; the decline branch's own code says nothing about either, and a host must not
   read `"refusal"` as a value the engine emits. The frames here also carry only `subtype`,
   `result`, `is_error` and `num_turns` -- the schemas require durations, costs and usage too,
   and a fabricated zero would be worse than an absence.
3. **The gap before the CLI retires the undeclared-kind dialog.** It is 1.5 s here so a replay
   is quick; the real dialog park deadline is five minutes by default per the parent's
   investigation, and no gate should read the fixture's timing as the deadline.
4. **Whether an undeclared kind is forwarded at all**, and what real kind to use in place of
   `undeclared_probe_kind`. See above.

`system/model_refusal_no_fallback` is deliberately **absent**. Its own schema says it is "not
emitted when the retry ran or the user declined the retry dialog" -- it covers the case where
no dialog was shown at all, which is not the case this fixture records.

Rebuild with `make synthetic`, which overwrites this directory and drops the review block
back to unsigned; walk `Fixtures/REVIEW.md` and `make sign` again afterwards.
"""

FABLE_README = """# dialog-fable-overage (synthetic, shapes confirmed on 2.1.259)

What it shows: the CLI asking the host for consent before spending past a Fable balance.
Five turns each open a `request_user_dialog` of kind `fable_overage_consent_prompt` and cover
every outcome the enum allows, with `overagesEnabled` both ways -- `consent`,
`switch_default` against a false payload and again against a true one, `cancelled`, and the
close path `{"behavior": "cancelled"}` with no `result`. Every outcome other than consenting
while overages are already enabled is followed by a `system/model_consent_fallback` frame
naming the original and fallback models and whether the choice was persisted as the default.

`consent` appears only against `overagesEnabled: true`, deliberately. The parent's §8.4 offers
that action "only when `overagesEnabled` is true, because a bare wire reply never enables
billing", and acceptance item 62 has the false branch stay pending until *Switch to the
default model* or *Not now*. A leg answering `consent` to a false payload would depict a reply
afleet is specified never to send, and a conforming host replaying this fixture would diverge
from it. The engine does have a behaviour there -- `model_consent_fallback`'s schema says
`choice: "consent"` reaches it "only when the gate could not honor it" -- but that is engine
behaviour afleet cannot trigger, so it belongs in an S6 finding rather than in a fixture
afleet replays against.

Serves item 62 and spike S6.

**These shapes are synthetic, and confirmed against the baseline.** Nothing here was recorded. Every field is read out of the
2.1.257 bundle modules -- `chunk-1kg58a1a.js` for the dialog kind, its
`{overagesEnabled, modelName?, balanceCents?, currency?}` payload and its
`consent | switch_default | cancelled` result enum with `default: "cancelled"`, and
`chunk-sct99ax9.js` for the `system/model_consent_fallback` schema, whose ten fields this
fixture's frames carry exactly. S6 then found both definitions in the installed 2.1.259
baseline binary, the dialog with its four payload keys, its `consent | switch_default |
cancelled` result enum and `default: "cancelled"`, and the frame with the same enum on
`choice` beside `original_model`, `original_model_name`, `fallback_model` and
`persisted_as_default`, so `fixture.json` carries `hypothesis: false` (spec §4.7).
`synthetic: true` stays, and with it the exclusion from `diff`: a synthetic fixture is never
baseline evidence by itself.

Each `model_consent_fallback.content` is built from the template the CLI builds it with --
`Switched to <fallback> <"— now your default model" | "for this session"> · <original>
requires usage credits · /model to change` -- so the clause tracks `persisted_as_default`
rather than contradicting it, and the `/model to change` instruction a GUI has to rewrite is
visible. The two model display names substituted into the template are this fixture's own
synthetic models.

One reading a recording should confirm: the fifth turn's close path carries no `result`,
and the schema's `default: "cancelled"` makes it behave as `cancelled`, so it and the fourth
turn produce the same frames. The message uuids here are readable synthetic ids rather than
RFC 4122 uuids, and the timestamps are chosen for a fast replay rather than measured.

Rebuild with `make synthetic`, which overwrites this directory and drops the review block
back to unsigned; walk `Fixtures/REVIEW.md` and `make sign` again afterwards.
"""


COMMON_NOTES = ["hand-written from the 2.1.257 bundle modules; the payload shapes, result enums and frame "
                "subtypes were then confirmed at their own definition sites in the installed 2.1.259 binary (S6)",
                "no process ran, so launch is empty and exit_code is null",
                "message uuids are readable synthetic ids, not RFC 4122 uuids; the bundle types these fields as uuids",
                "timestamps are synthetic deltas chosen so a replay is quick, not measured intervals",
                "transcript/ holds the session's user and assistant messages as delivered; whether the CLI "
                "removes a tombstoned or superseded message from its own history file is unknown and unmodelled"]


def _write(root, name, sid, frames, purpose, serves, readme, extra_notes=()):
    work = tempfile.mkdtemp(prefix="afleet-synth-")
    try:
        initial = os.path.join(work, "initial"); transcript = os.path.join(work, "transcript", fixture.SLUG_TOKEN)
        os.makedirs(initial); os.makedirs(transcript)
        with open(os.path.join(transcript, sid + ".jsonl"), "w", encoding="utf-8") as fh:
            for rec in frames:
                f = rec["frame"]
                if f.get("type") in ("user", "assistant"):
                    fh.write(json.dumps({"type": f["type"], "uuid": f.get("uuid"), "cwd": CWD, "message": f["message"]}) + "\n")
        meta = {"name": name, "scenario": None, "purpose": purpose, "serves": serves, "spikes": ["S6"], "recorded_at": "2026-09-04T00:00:00Z",
                "cli_version": CLI_VERSION, "session_id": sid, "cwd": CWD, "launch": {"argv": [], "env": {}}, "prompts": _prompts(frames),
                "census": False, "deterministic": False, "isolation": "none", "synthetic": True, "hypothesis": False,
                "late_responses": [], "withdrawn_requests": [],
                "notes": list(COMMON_NOTES) + list(extra_notes),
                "exit_code": None,
                "review": {"reviewer": "", "date": "", "checklist_version": verify.CHECKLIST_VERSION}}
        c = census.census([r["frame"] for r in frames], version=CLI_VERSION)
        dest = fixture.write_fixture(root, name, meta, frames, c, redact.Redactor().manifest(),
                                     initial, os.path.join(work, "transcript"), None)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    # After the atomic assembly rather than inside it, because `write_fixture` owns the file
    # set §4.4 requires and `README.md` is the one optional member. It is written here at all
    # -- rather than by hand once, as a recorded fixture's would be -- because `make synthetic`
    # replaces this directory whole, and a README that a rebuild silently deleted would leave
    # the fixture's only prose behind on the second run.
    with open(os.path.join(dest, "README.md"), "w", encoding="utf-8") as fh:
        fh.write(readme)
    return dest


def build(fixtures_root):
    return [_write(fixtures_root, "dialog-fable-overage", SID_F, fable_frames(),
                   "every fable_overage_consent_prompt outcome, overagesEnabled both ways, model_consent_fallback",
                   ["item 62"], FABLE_README),
            _write(fixtures_root, "dialog-refusal-fallback", SID_R, refusal_frames(),
                   "every refusal_fallback_prompt result, the close path, supersedes on the retry leg and no wire retraction on the declines, an undeclared kind cancelled by the CLI",
                   ["item 62"], REFUSAL_README,
                   ["the decline legs carry no wire retraction signal by design: tombstone is an internal event "
                    "the stream-json emitter filters out, so evicting retractedMessageUuids on resolution is the "
                    "host's only mechanism",
                    "both content strings are partly [placeholder: ...]; the CLI assembles them from parts this "
                    "fixture cannot resolve, and invented copy would be worse than a marked gap",
                    "the result subtype on the decline legs is this fixture's assumption, not a bundle reading",
                    "the 1.5s gap before the CLI retires the undeclared-kind dialog stands in for the dialog park "
                    "deadline, which the parent's investigation records as five minutes by default",
                    "whether an undeclared kind reaches the host at all is open; undeclared_probe_kind is a "
                    "synthetic placeholder no binary contains",
                    "system/model_refusal_no_fallback is deliberately absent: its schema says it is not emitted "
                    "when the user declined the retry dialog"])]
