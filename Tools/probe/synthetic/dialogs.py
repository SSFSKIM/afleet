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
`tombstone`, `system/model_refusal_fallback` and `system/model_consent_fallback`.

They stay `hypothesis: true` until the same strings are extracted from the installed 2.1.259
binary.

Two properties this module owes the rest of the pipeline.

*The build is deterministic.* `make synthetic` rebuilds both fixtures byte for byte on any
machine, so a reviewer can rerun it and diff the result against what is committed. Nothing
here reads the clock, the environment or the host, and nothing runs the redactor over the
frames: §4.5's rules substitute the *recording* machine's home directory and hostname, which
would make the output differ between machines while removing nothing, because no byte here
ever came off a machine. `redaction.json` still carries the full six-rule manifest at zero
counts, which is what §4.4 asks for and what REVIEW.md item 4 has a reviewer confirm.

*Nothing is invented beyond the bundle.* These fixtures are `hypothesis: true`, and every
field they carry is a claim later children will build gates on, so a frame holds the keys the
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


def _tombstone(t, sid, uid, target_uuid, target_text):
    """`{type: "tombstone", message, uuid, session_id}` (chunk-sct99ax9.js).

    The decline branch yields one per already-streamed message before it resets the turn:
    `for (let sk of Xo) yield {type:"tombstone", message: sk}`. The schema types `message` as
    opaque -- "The internal Message being tombstoned. Wire shape pending a dedicated schema"
    -- so what sits there is the one part of this frame a recording still has to settle, and
    the fixture carries the smallest thing a consumer could evict by: the message's own uuid.
    """
    return {"t": t, "dir": "out", "frame": {
        "type": "tombstone",
        "message": {"type": "assistant", "uuid": target_uuid,
                    "message": {"role": "assistant", "content": [{"type": "text", "text": target_text}]}},
        "uuid": uid, "session_id": sid}}


def _result(t, text, subtype="success", is_error=False):
    f = {"type": "result", "subtype": subtype, "result": text, "num_turns": 1}
    if is_error:
        f["is_error"] = True
    return {"t": t, "dir": "out", "frame": f}


PARTIAL_TEXT = "partial text before the refusal"


def refusal_frames():
    """The four dialog answers and what `chunk-1kg58a1a.js` emits after each.

    The branch is a single `if (result !== "retry_fallback")` in the refusal-fallback loop, so
    three of the four answers -- `edit_prompt`, `cancelled` and the close path, which the
    dialog schema's `default: "cancelled"` collapses onto `cancelled` -- share a tail and only
    differ in what follows the tombstones. That collapse is itself something a host has to
    know, so the fixture shows the close path and `cancelled` producing the same frames rather
    than eliding one of them.
    """
    p = {"originalModel": "claude-fable-5-1", "fallbackModel": "claude-opus-5", "apiRefusalCategory": "safety",
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
                "request_id": None, "api_refusal_category": "safety", "api_refusal_explanation": None,
                "retracted_message_uuids": [partial], "refused_user_message_uuid": uid,
                "content": "Claude Fable 5.1 declined this request; retried on Claude Opus 5.",
                "uuid": "s-%d" % n, "session_id": SID_R}}); t += 50
            fr.append(_result(t, "answer from the fallback model")); t += 50
        else:
            fr.append(_tombstone(t, SID_R, "tomb-%d" % n, partial, PARTIAL_TEXT)); t += 50
            if choice == "cancelled":
                # Only the `cancelled` branch builds the refusal notice; `edit_prompt` aborts
                # the turn instead and emits nothing between the tombstones and the result.
                fr.append(_assistant(t, "a-refusal-%d" % n, SID_R,
                                     "Claude Fable 5.1's safeguards flagged this message. Edit your last message, or try a different model.")); t += 50
            fr.append(_result(t, "refusal", subtype="error_during_execution", is_error=True)); t += 50
    fr.append(_user(t, "u-undeclared", "prompt that triggers an undeclared kind")); t += 50
    fr += _dialog(t, "dlg-undeclared", "undeclared_probe_kind", {}, None); t += 1600
    fr.append(_result(t, "continued after the CLI cancelled its own dialog"))
    return fr


def fable_frames():
    fr = _init_pair(0)
    t = 100
    cases = [(True, {"behavior": "completed", "result": "consent"}), (False, {"behavior": "completed", "result": "consent"}),
             (True, {"behavior": "completed", "result": "switch_default"}), (True, {"behavior": "completed", "result": "cancelled"}),
             (False, {"behavior": "cancelled"})]
    for n, (enabled, answer) in enumerate(cases):
        fr.append(_user(t, "u%d" % n, "prompt %d" % n)); t += 50
        payload = {"overagesEnabled": enabled, "modelName": "Fable 5", "balanceCents": 0 if enabled else None, "currency": "USD" if enabled else None}
        fr += _dialog(t, "fab-%d" % n, "fable_overage_consent_prompt", payload, answer); t += 300
        choice = answer.get("result", "cancelled")
        if not (choice == "consent" and enabled):
            fr.append({"t": t, "dir": "out", "frame": {"type": "system", "subtype": "model_consent_fallback", "choice": choice,
                       "original_model": "claude-fable-5-1", "original_model_name": "Fable 5", "fallback_model": "claude-opus-5",
                       "persisted_as_default": choice == "switch_default", "content": "Switched to Opus for this session.",
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


REFUSAL_README = """# dialog-refusal-fallback (synthetic, hypothesis)

What it shows: the CLI asking the host to resolve a model refusal. Four turns each stream a
partial assistant message, open a `request_user_dialog` of kind `refusal_fallback_prompt`
whose payload names that partial in `retractedMessageUuids`, and answer it a different way.

- `retry_fallback`: the retry runs, and its `assistant` frame carries `supersedes` naming
  the partial it replaces. The turn then ends with a `system/model_refusal_fallback` notice
  (`direction: "retry"`), whose `retracted_message_uuids` repeats the same retraction -- the
  two are documented as idempotent with each other, so a host may act on whichever arrives.
- `edit_prompt`: one `tombstone` frame per already-streamed message, then nothing. The CLI
  aborts the turn so the user can edit, and emits no notice.
- `cancelled`: the same tombstones, then an `assistant` frame carrying the refusal prose the
  CLI composes for the user.
- The close path, `{"behavior": "cancelled"}` with no `result` at all: identical to
  `cancelled`, because the dialog schema declares `default: "cancelled"`. A host that treats
  a missing `result` as a distinct outcome would be wrong, which is why both appear here.

A fifth turn opens a dialog of a kind the host never declared in
`initialize.supportedDialogKinds`. The host must leave it alone -- an error-shaped answer to
a parked dialog is swallowed -- and the CLI retires it itself with `control_cancel_request`,
the one shape in which a lifecycle closes without a response (spec §4.2).

Serves item 62 and spike S6.

**These shapes are hypotheses.** Nothing here was recorded. Every field is read out of the
2.1.257 bundle: `chunk-1kg58a1a.js` for the dialog kind, its
`{originalModel, fallbackModel, apiRefusalCategory?, guidanceText?, retractedMessageUuids?}`
payload, its `retry_fallback | edit_prompt | cancelled` result enum with `default:
"cancelled"`, and the decline branch that yields the tombstones; `chunk-sct99ax9.js` for the
`assistant.supersedes`, `tombstone` and `system/model_refusal_fallback` schemas. The baseline
binary is 2.1.259, so `fixture.json` carries `synthetic: true` and `hypothesis: true`, the
fixture is excluded from `diff`, and every gate resting on it stays provisional until S6
extracts the same strings from the installed 2.1.259 binary and clears the flag (spec §4.7).
A synthetic fixture is never baseline evidence by itself.

Three things S6 should settle, because the bundle does not:

1. The `tombstone` frame's `message` field. Its schema types it as opaque and says the wire
   shape is pending, so the fixture carries only the tombstoned message's own uuid.
2. The `result` subtypes on the decline legs. `error_during_execution` is this fixture's
   assumption, not a bundle reading; the decline branch's own code says nothing about it.
3. The gap before the CLI retires the undeclared-kind dialog. It is 1.5 s here so a replay is
   quick; the real dialog park deadline is five minutes by default per the parent's
   investigation, and no gate should read the fixture's timing as the deadline.

`system/model_refusal_no_fallback` is deliberately **absent**. Its own schema says it is "not
emitted when the retry ran or the user declined the retry dialog" -- it covers the case where
no dialog was shown at all, which is not the case this fixture records.

Rebuild with `make synthetic`, which overwrites this directory and drops the review block
back to unsigned; walk `Fixtures/REVIEW.md` and `make sign` again afterwards.
"""

FABLE_README = """# dialog-fable-overage (synthetic, hypothesis)

What it shows: the CLI asking the host for consent before spending past a Fable balance.
Five turns each open a `request_user_dialog` of kind `fable_overage_consent_prompt` and cover
every outcome the enum allows -- `consent` with `overagesEnabled` true and again false,
`switch_default`, `cancelled`, and the close path `{"behavior": "cancelled"}` with no
`result`. Every outcome other than consenting while overages are already enabled is followed
by a `system/model_consent_fallback` frame naming the original and fallback models and
whether the choice was persisted as the default.

Serves item 62 and spike S6.

**These shapes are hypotheses.** Nothing here was recorded. Every field is read out of the
2.1.257 bundle modules -- `chunk-1kg58a1a.js` for the dialog kind, its
`{overagesEnabled, modelName?, balanceCents?, currency?}` payload and its
`consent | switch_default | cancelled` result enum with `default: "cancelled"`, and
`chunk-sct99ax9.js` for the `system/model_consent_fallback` schema, whose ten fields this
fixture's frames carry exactly. The baseline binary is 2.1.259, so `fixture.json` carries
`synthetic: true` and `hypothesis: true`, the fixture is excluded from `diff`, and every gate
resting on it stays provisional until S6 extracts the same strings from the installed 2.1.259
binary and clears the flag (spec §4.7). A synthetic fixture is never baseline evidence by
itself.

Two readings this fixture encodes, which S6 should confirm on a recording. First, the second
turn: consenting while `overagesEnabled` is false still produces a `model_consent_fallback`,
because the schema says `choice: "consent"` appears there "only when the gate could not
honor it". Second, the fifth turn: the close path carries no `result` and the schema's
`default: "cancelled"` makes it behave as `cancelled`, so the two produce the same frames.
The message uuids here are readable synthetic ids rather than RFC 4122 uuids, and the
timestamps are chosen for a fast replay rather than measured.

Rebuild with `make synthetic`, which overwrites this directory and drops the review block
back to unsigned; walk `Fixtures/REVIEW.md` and `make sign` again afterwards.
"""


COMMON_NOTES = ["hand-written from the 2.1.257 bundle modules; shapes unconfirmed on 2.1.259",
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
                "census": False, "deterministic": False, "isolation": "none", "synthetic": True, "hypothesis": True,
                "late_responses": [], "withdrawn_requests": [],
                "notes": list(COMMON_NOTES) + list(extra_notes),
                "exit_code": None,
                "review": {"reviewer": "", "date": "", "checklist_version": 1}}
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
                   "every refusal_fallback_prompt result, the close path, the tombstones and supersedes after a refusal, an undeclared kind cancelled by the CLI",
                   ["item 62"], REFUSAL_README,
                   ["the tombstone frame's message field is opaque in the bundle schema; only the tombstoned uuid is carried",
                    "the result subtype on the decline legs is this fixture's assumption, not a bundle reading",
                    "the 1.5s gap before the CLI retires the undeclared-kind dialog stands in for the dialog park "
                    "deadline, which the parent's investigation records as five minutes by default",
                    "system/model_refusal_no_fallback is deliberately absent: its schema says it is not emitted "
                    "when the user declined the retry dialog"])]
