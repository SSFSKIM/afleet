"""The synthetic `send-message-delivery` fixture (child C6.4, gate G4's fixture half).

One recording, six turns, whose last five are the five arms of acceptance item 51: the positive
path, a turn with no `SendMessage` call at all, a call naming a different agent, a refused resume,
and a `task_notification` for the target arriving after the relay with no further tool round. The state machine that reads them is
asserted separately over hand-built frame sequences; what *this* fixture asserts is the far
cheaper and far more falsifiable claim that the five sequences are shapes an engine can produce,
in one session, in order, replayable end to end.

**It is not reachable through `make synthetic`, deliberately.** That verb rebuilds the two dialog
fixtures whole -- signature included -- so a rebuild drops their review block back to unsigned.
Adding this fixture to it would make every build of this one invalidate a human review that this
child has no standing to re-sign. This module is a third target beside them, invoked on its own:

    python3 Tools/probe/synthetic/send_message.py [fixtures_root]

`fixtures_root` defaults to `/tmp/afleet-c64`, which is where this fixture is staged until a
reviewer walks `Fixtures/REVIEW.md` and signs it. It must not be built under `Fixtures/`:
`make verify-fixtures` runs over `Fixtures/*/` and refuses an unsigned directory, so an unsigned
build there turns the whole floor red.

Two properties this module owes the rest of the pipeline, the same two `dialogs.py` owes.

*The build is deterministic.* Rebuilding writes the same bytes on any machine, so a reviewer can
rerun it and diff the result against what they are being asked to sign. Nothing here reads the
clock, the environment or the host, and nothing runs the redactor over the frames: §4.5's rules
substitute the *recording* machine's home directory and hostname, which would make the output
differ between machines while removing nothing, because no byte here ever came off a machine.
`redaction.json` still carries the full six-rule manifest at zero counts, which is what §4.4 asks
for and what REVIEW.md item 4 has a reviewer confirm.

*Nothing is invented beyond the bundle.* Every field a frame carries is a claim a later child
builds a gate on, so a frame holds the keys the evidence shows and no more. A plausible-looking
field would enter the census as a required key no evidence supports.

What the evidence is, field by field, and why `hypothesis` clears.

- The **frame envelopes** -- `system/task_started`, `system/task_notification`, the `assistant`
  frame carrying a `tool_use` block, the `user` frame carrying a `tool_result` block, an agent's
  own `user` frame keyed by `parent_tool_use_id`, and `result` -- are the shapes the recorded
  corpus already carries, `nested-depth-2` above all. Those are not this fixture's claim to make.
- The **agent id shape** is `^a[0-9a-f]{16}$`, as the recorded corpus shows it. The two ids here
  are invented values of that shape.
- The **tool name and its input keys** are read at their definition sites in the pinned bundle:
  `chunk-q09s64jh.js` declares the name, and the input builder in `chunk-wa5bw6hk.js` declares
  `to` (required), `summary` (optional, bounded) and `message`, with `notify_when_idle` present
  only in the cross-session schema variant. `to` carries the agent id; there is no `agent_id` key.
  `ClaudeWire.SendMessageInput` already models exactly these three.
- The **result envelope** is read at the same site: the tool returns `{data: {success, message}}`
  and its result mapper `JSON.stringify`s that object into **one text block** of an ordinary
  `tool_result`. Both strings this fixture carries are the module's own templates, not paraphrases.

**The one thing a reader must not carry over from prose written before this reading**: a refused
resume is **not** an `is_error` `tool_result`. The stopped-by-user branch returns
`{success: false, message: ...}` and the mapper serialises it into an ordinary, non-error result.
`is_error: true` with a `<tool_use_error>` wrapper is what the *validate-input* refusals get --
an empty message, a malformed recipient, a structured frame sent where plain text is required --
which is a different failure with a different cause. That is exactly why the first and fourth
arms here are the discriminating pair: two non-error `tool_result`s, one saying `success: true`
and one saying `success: false`, which a host that reads only the error flag cannot tell apart.

`hypothesis: false` follows: nothing above is inferred. `synthetic: true` stays for the reason it
stays on the dialog fixtures -- how the engine reaches these shapes in sequence is unrecorded, and
a synthetic fixture is never baseline evidence by itself. `notes` lists what is still open, all of
it compositional rather than shape-level: which of the four schema variants a session advertised,
the optional sibling keys (`msg_id`, `resumedAgentId`, `pin`) that appear conditionally, the
values interpolated into the templates, and how a relayed message reaches the receiving run.
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

NAME = "send-message-delivery"

# Staged, not committed. `make verify-fixtures` walks `Fixtures/*/` and refuses an unsigned
# directory, so this fixture lives outside the tree until a reviewer signs it and enters the
# branch in one commit afterwards.
STAGING_ROOT = "/tmp/afleet-c64"

SID = "66666666-6666-4666-8666-666666666666"
CWD = "/private/tmp/afleet-fixtures/synthetic"
CLI_VERSION = "2.1.257-bundle"

# The engine's agent id shape, `^a[0-9a-f]{16}$`, with invented values. `TARGET` is the run every
# arm relays *to*; `OTHER` is the run the wrong-target arm's call names instead.
TARGET = "a1111111111111111"
TARGET_TOOL_USE = "toolu_invented_run01"
OTHER = "a2222222222222222"
OTHER_TOOL_USE = "toolu_invented_run02"

# One prompt uuid per arm. Each is the uuid afleet's own `sendPrompt` would have minted for that
# *Send message*, and it is the join between the relay record and the turn: the echo carries it,
# and the `result` that closes the turn is attributed to it.
PROMPTS = ["aaaaaaa1-1111-4111-8111-aaaaaaaaaaa1",
           "aaaaaaa2-2222-4222-8222-aaaaaaaaaaa2",
           "aaaaaaa3-3333-4333-8333-aaaaaaaaaaa3",
           "aaaaaaa4-4444-4444-8444-aaaaaaaaaaa4",
           "aaaaaaa5-5555-4555-8555-aaaaaaaaaaa5"]

SETUP_PROMPT_UUID = "aaaaaaa0-0000-4000-8000-aaaaaaaaaaa0"

# The five messages, one per arm. Distinct, so the positive arm's delivery cannot be read off a
# frame another arm's relay produced -- delivery is correlated one-to-one and a shared text would
# make the fixture unable to tell the two apart.
MESSAGES = ["an invented errand for the first arm",
            "an invented errand for the second arm",
            "an invented errand for the third arm",
            "an invented errand for the fourth arm",
            "an invented errand for the fifth arm"]

MODEL = "an-invented-model"

# The two result bodies, as the tool's own module writes them.
#
# `SendMessage` returns `{data: {success, message}}` and its result mapper JSON.stringify-s that
# object into one text block of an ordinary `tool_result`. Both `message` templates below are the
# module's own, carried rather than paraphrased for the reason `dialogs.py` carries the CLI's copy:
# a `message` a child renders is what a rendering test is written against, and invented copy would
# test nothing. Only the values interpolated into them -- the agent name -- are this fixture's.
#
# **Neither carries `is_error`, and the fourth arm is the reason that matters.** The engine sets
# `is_error` on a `SendMessage` result only for the validate-input refusals (an empty message, a
# malformed recipient, a structured frame where plain text is required). A refused *resume* is an
# ordinary non-error result whose body says `success: false`. So the first and the fourth arm are
# the discriminating pair: two non-error results a host that reads only the error flag cannot
# tell apart.


def _result_body(success, message):
    """The tool result's one text block: the module's `JSON.stringify` of `{success, message}`."""
    return [{"type": "text",
             "text": json.dumps({"success": success, "message": message}, separators=(",", ":"))}]


QUEUED = "Message queued for delivery to %s at its next tool round." % TARGET
QUEUED_OTHER = "Message queued for delivery to %s at its next tool round." % OTHER
REFUSED = ('Agent "%s" was stopped by the user and was not resumed. Treat its work as cancelled; '
           "only start a new agent for it if the user explicitly asks." % TARGET)

# The wrapper a relayed message arrives inside. Invented, and marked as such in `notes`: nothing
# in the evidence says the forwarded body is byte-identical to what the model passed, and afleet's
# own delivery test is written to tolerate exactly this -- a whole line of the original matching
# is enough, a mere mention is not.
FORWARD_PREFIX = "Relayed message:\n\n"


def _out(t, frame):
    return {"t": t, "dir": "out", "frame": frame}


def _init_pair(t):
    """The host's `initialize` and the CLI's answer, as every recording opens.

    Carried because a fixture with no initialize is a session nothing established, and the
    lifecycle check in `verify` reads request origins off exactly this pair.
    """
    return [{"t": t, "dir": "in", "frame": {"type": "control_request", "request_id": "init-1",
             "request": {"subtype": "initialize", "supportedDialogKinds": []}}},
            _out(t + 5, {"type": "control_response", "response": {"subtype": "success", "request_id": "init-1",
                 "response": {"commands": [], "models": [], "current_model": "opus",
                              "current_permission_mode": "default"}}})]


def _user(t, uid, text):
    """A human turn's prompt, echoed by the CLI. `origin.kind` is what makes it the user's."""
    return _out(t, {"type": "user", "uuid": uid, "parent_tool_use_id": None,
                    "session_id": SID, "origin": {"kind": "human"},
                    "message": {"role": "user", "content": text}})


def _assistant_text(t, uid, text):
    return _out(t, {"type": "assistant", "uuid": uid, "parent_tool_use_id": None, "session_id": SID,
                    "message": {"id": "msg_" + uid.replace("-", "")[:16], "type": "message",
                                "role": "assistant", "model": MODEL,
                                "content": [{"type": "text", "text": text}]}})


def _send_message_call(t, uid, tool_use_id, to, message, summary):
    """The main agent calling `SendMessage`.

    Three input keys and no more: `to` and `summary` are what the engine's own `Agent` tool result
    instructs the model to call with, and `message` is the third key `ClaudeWire.SendMessageInput`
    models -- optional there, and named in `notes` as the one input key no definition site on the
    pinned baseline confirms.
    """
    return _out(t, {"type": "assistant", "uuid": uid, "parent_tool_use_id": None, "session_id": SID,
                    "message": {"id": "msg_" + uid.replace("-", "")[:16], "type": "message",
                                "role": "assistant", "model": MODEL,
                                "content": [{"type": "tool_use", "id": tool_use_id, "name": "SendMessage",
                                             "input": {"to": to, "message": message, "summary": summary}}]}})


def _tool_result(t, uid, tool_use_id, content):
    """A `tool_result` block, with **no** `is_error` key.

    The engine writes `is_error` only when the call failed, and none of the routes this fixture
    shows is one: the queued route and the stopped-by-user refusal both come back as ordinary
    results whose body carries the outcome. A fixture that wrote `is_error: false` would put a
    key on the wire that the engine omits, and the census would record it as one a host may rely
    on being present.
    """
    return _out(t, {"type": "user", "uuid": uid, "parent_tool_use_id": None, "session_id": SID,
                    "message": {"role": "user",
                                "content": [{"type": "tool_result", "tool_use_id": tool_use_id,
                                             "content": content}]}})


def _forwarded(t, uid, text):
    """The relayed message arriving in the **target run's own** stream.

    `parent_tool_use_id` naming the run's spawning tool use is what routes a frame to that run,
    which is the whole discriminating half of the positive arm: the same text on the main stream
    is where the relay was *asked for* and is not delivery.
    """
    return _out(t, {"type": "user", "uuid": uid, "parent_tool_use_id": TARGET_TOOL_USE,
                    "session_id": SID, "subagent_type": "an-invented-agent",
                    "task_description": "an invented errand",
                    "message": {"role": "user", "content": FORWARD_PREFIX + text}})


def _task_started(t, uid, task_id, tool_use_id, description, subagent_type):
    return _out(t, {"type": "system", "subtype": "task_started", "task_id": task_id,
                    "tool_use_id": tool_use_id, "description": description,
                    "subagent_type": subagent_type, "spawn_depth": 1, "task_type": "local_agent",
                    "is_backgrounded": True, "uuid": uid, "session_id": SID})


def _task_notification(t, uid, task_id, tool_use_id, summary):
    """What hands a run's result back, and the fourth arm's whole evidence.

    `output_file` carries `fixture.ARTIFACT_TOKEN`, the same stand-in a recorded fixture's
    artifact paths are rewritten to, so this frame names no path.
    """
    return _out(t, {"type": "system", "subtype": "task_notification", "task_id": task_id,
                    "tool_use_id": tool_use_id, "status": "completed",
                    "output_file": fixture.ARTIFACT_TOKEN + "/" + task_id + ".output",
                    "summary": summary, "uuid": uid, "session_id": SID})


def _result(t, uid, text):
    """The frame that closes a turn.

    **`duration_ms` and `total_cost_usd` are written, unlike the dialog fixtures', and that is
    deliberate.** `ClaudeWire.ResultFields` requires both, with a note recorded at its definition
    site: the bundle spreads them in at every construction site and "no path emits a stream-json
    `result` frame lacking any of them". A frame that omitted them would therefore depict something
    the engine never sends, and -- because a required key that is missing makes the whole frame
    decode as opaque -- would silently cost this fixture the one thing it exists to show: which turn
    a `result` closes, which is what four of the five arms are read from. The values are synthetic
    and `notes` says so; the keys' presence is the bundle's guarantee, not this fixture's guess.

    `user_message_uuid` is written for the same reason it matters here: it is the frame's own claim
    about which prompt this turn answers.
    """
    return _out(t, {"type": "result", "subtype": "success", "result": text, "is_error": False,
                    "num_turns": 1, "duration_ms": 1000, "duration_api_ms": 900,
                    "total_cost_usd": 0.0, "stop_reason": "end_turn",
                    "user_message_uuid": uid, "uuid": "f" + uid[1:], "session_id": SID})


def frames():
    """Six turns: one that starts the two runs, then the five arms in order."""
    fr = _init_pair(0)
    t = 100

    # --- Turn 0: the two runs exist ------------------------------------------------------
    # The `Agent` tool round that really precedes a `task_started` is **not** modelled: its
    # result is engine copy this fixture will not invent, and no arm here reads it. What the arms
    # need is that the two runs exist, which is what `task_started` states.
    fr.append(_user(t, SETUP_PROMPT_UUID, "an invented request that starts two agents")); t += 50
    fr.append(_task_started(t, "bbbbbbb1-1111-4111-8111-bbbbbbbbbbb1", TARGET, TARGET_TOOL_USE,
                            "an invented errand", "an-invented-agent")); t += 50
    fr.append(_task_started(t, "bbbbbbb2-2222-4222-8222-bbbbbbbbbbb2", OTHER, OTHER_TOOL_USE,
                            "a second invented errand", "an-invented-other-agent")); t += 50
    fr.append(_result(t, SETUP_PROMPT_UUID, "an invented answer that started two agents")); t += 50

    # --- Arm 1: the positive path --------------------------------------------------------
    fr.append(_user(t, PROMPTS[0], "an invented composed relay prompt for the first arm")); t += 50
    fr.append(_assistant_text(t, "c1111111-1111-4111-8111-c11111111111",
                              "an invented sentence before the first arm's call")); t += 50
    fr.append(_send_message_call(t, "c1111112-1111-4111-8111-c11111111112", "toolu_invented_send01",
                                 TARGET, MESSAGES[0], "an invented recap of the first arm")); t += 50
    fr.append(_tool_result(t, "d1111111-1111-4111-8111-d11111111111", "toolu_invented_send01",
                           _result_body(True, QUEUED))); t += 50
    fr.append(_forwarded(t, "e1111111-1111-4111-8111-e11111111111", MESSAGES[0])); t += 50
    fr.append(_result(t, PROMPTS[0], "an invented answer for the first arm")); t += 50

    # --- Arm 2: no `SendMessage` call at all ---------------------------------------------
    fr.append(_user(t, PROMPTS[1], "an invented composed relay prompt for the second arm")); t += 50
    fr.append(_assistant_text(t, "c2222221-2222-4222-8222-c22222222221",
                              "an invented sentence answering without calling the tool")); t += 50
    fr.append(_result(t, PROMPTS[1], "an invented answer for the second arm")); t += 50

    # --- Arm 3: the call names a different agent -----------------------------------------
    fr.append(_user(t, PROMPTS[2], "an invented composed relay prompt for the third arm")); t += 50
    fr.append(_send_message_call(t, "c3333331-3333-4333-8333-c33333333331", "toolu_invented_send03",
                                 OTHER, MESSAGES[2], "an invented recap of the third arm")); t += 50
    fr.append(_tool_result(t, "d3333331-3333-4333-8333-d33333333331", "toolu_invented_send03",
                           _result_body(True, QUEUED_OTHER))); t += 50
    fr.append(_result(t, PROMPTS[2], "an invented answer for the third arm")); t += 50

    # --- Arm 4: a refused resume, with the model's reply ---------------------------------
    # An **ordinary, non-error** result whose body says `success: false`. This is the whole
    # discriminating half of the arm: the flag on the block says nothing, and a host that reads
    # only the flag calls this relayed and waits for a delivery that cannot come.
    fr.append(_user(t, PROMPTS[3], "an invented composed relay prompt for the fourth arm")); t += 50
    fr.append(_assistant_text(t, "c4444441-4444-4444-8444-c44444444441",
                              "an invented sentence the model explained the refusal with")); t += 50
    fr.append(_send_message_call(t, "c4444442-4444-4444-8444-c44444444442", "toolu_invented_send04",
                                 TARGET, MESSAGES[3], "an invented recap of the fourth arm")); t += 50
    fr.append(_tool_result(t, "d4444441-4444-4444-8444-d44444444441", "toolu_invented_send04",
                           _result_body(False, REFUSED))); t += 50
    fr.append(_result(t, PROMPTS[3], "an invented answer for the fourth arm")); t += 50

    # --- Arm 5: a `task_notification` for the target after the relay, no further round ----
    # The near miss this arm has to survive: the run was already running when the message was
    # sent, so its eventual terminal status is only evidence because the notification arrives
    # *after* the relay and nothing of the run's own carries the text.
    fr.append(_user(t, PROMPTS[4], "an invented composed relay prompt for the fifth arm")); t += 50
    fr.append(_send_message_call(t, "c5555551-5555-4555-8555-c55555555551", "toolu_invented_send05",
                                 TARGET, MESSAGES[4], "an invented recap of the fifth arm")); t += 50
    fr.append(_tool_result(t, "d5555551-5555-4555-8555-d55555555551", "toolu_invented_send05",
                           _result_body(True, QUEUED))); t += 50
    fr.append(_task_notification(t, "e5555551-5555-4555-8555-e55555555551", TARGET, TARGET_TOOL_USE,
                                 "an invented summary handed back")); t += 50
    fr.append(_result(t, PROMPTS[4], "an invented answer for the fifth arm")); t += 50
    return fr


def _prompts(fr):
    """The user messages the frames carry, which is what `prompts` truthfully means here.

    A recorded fixture takes `prompts` from the scenario's declaration of what `run()` sends.
    Nothing sent these, so the frames themselves are the only honest source, and REVIEW.md item 1
    has a reviewer check `prompts` against them. Only the human-origin frames: a `user` frame
    carrying a `tool_result` is the engine echoing a tool's answer, not a prompt.
    """
    return [rec["frame"]["message"]["content"] for rec in fr
            if rec["frame"].get("type") == "user" and (rec["frame"].get("origin") or {}).get("kind") == "human"]


NOTES = [
    "hand-written; the frame envelopes are shapes the recorded corpus already carries "
    "(nested-depth-2 for task_started, task_notification, tool_use and tool_result), and the "
    "agent ids are invented values of the ^a[0-9a-f]{16}$ shape that corpus shows",
    "the SendMessage tool name, its to/summary/message input keys and both result bodies are read "
    "at their definition sites in the pinned 2.1.257 bundle, so hypothesis is false: the tool "
    "returns {data: {success, message}} and its result mapper JSON.stringify-s that object into "
    "one text block of an ordinary tool_result",
    "a refused resume carries NO is_error: the stopped-by-user branch returns success: false in an "
    "ordinary result, and is_error is reserved for the validate-input refusals. The first and "
    "fourth arms are therefore two non-error results that differ only in that field, which is what "
    "a host reading only the error flag cannot tell apart",
    "still open, and compositional rather than shape-level: which of the four schema variants the "
    "session advertised (message is required in two of them and defaulted in the other two, and "
    "notify_when_idle exists only in the cross-session pair); the optional sibling keys msg_id, "
    "resumedAgentId and pin, which appear conditionally and are omitted here; the values "
    "interpolated into the two message templates, which are this fixture's own; and how a relayed "
    "message reaches the receiving run, which the fifth note below covers",
    "how a relayed message arrives on the target run's stream is this fixture's assumption: a user "
    "frame keyed by the run's parent_tool_use_id, inside an invented wrapper line. A recording "
    "should settle it; afleet's delivery test is written to tolerate a wrapper and to refuse a "
    "mere mention",
    "the Agent tool round that really precedes each task_started is not modelled: its result is "
    "engine copy about a spawn this fixture does not depict, and no arm reads it",
    "no process ran, so launch is empty and exit_code is null",
    "timestamps are synthetic deltas chosen so a replay is quick, not measured intervals, and the "
    "frames carry no per-frame timestamp field, so a replay orders them by arrival",
    "the result frames carry duration_ms, duration_api_ms and total_cost_usd with synthetic "
    "values, unlike the two dialog fixtures. ClaudeWire.ResultFields requires all three and its "
    "definition site records the bundle's guarantee that no path emits a result frame without "
    "them, so omitting them would depict a frame the engine never sends -- and would make the "
    "frame decode as opaque, costing the four arms that are read from which turn a result closes. "
    "usage, modelUsage and permission_denials stay absent: nothing measured them and no arm reads "
    "them",
    "message uuids are readable synthetic ids, not RFC 4122 uuids; the bundle types these fields "
    "as uuids",
    "transcript/ holds the session's user and assistant messages as delivered",
]

README = """# send-message-delivery (synthetic, shapes confirmed on the 2.1.257 bundle)

What it shows: acceptance item 51's five arms, as six turns of one session. A first turn starts
two agent runs; each of the five that follow is one *Send message* and what the model did next.

1. **The positive path.** The main agent calls `SendMessage` naming the target run, the call comes
   back `success: true`, and the message text then appears in the **target run's own** stream --
   a `user` frame keyed by that run's `parent_tool_use_id`. Only the third of those three is
   delivery; the first two are the engine queueing something.
2. **No `SendMessage` call at all.** The model answers in prose and the turn closes. Nothing was
   relayed and nothing said so.
3. **A call naming a different agent.** The model answered the request, and answered it about
   someone else. This is the arm a host that advances on "a `SendMessage` happened" gets wrong.
4. **A refused resume.** The target was stopped by the user, so the call comes back
   `success: false` -- in an **ordinary, non-error** `tool_result` -- with the model's own reply
   in the same turn.
5. **A `task_notification` for the target after the relay, with no further tool round.** The
   message was queued and the run ended without ever taking it.

**Arms 1 and 4 are the discriminating pair, and the reason this fixture is worth a review walk.**
Both are non-error `tool_result`s. The engine sets `is_error` on a `SendMessage` result only for
its validate-input refusals -- an empty message, a malformed recipient, a structured frame where
plain text is required -- and a refused *resume* is not one of those: the stopped-by-user branch
returns `{success: false, message: ...}` and the result mapper serialises it like any other
success. A host that reads only the error flag reports a message as relayed to an agent that will
never take it, which is precisely the silent failure item 51 exists to make visible.

The five messages differ from each other on purpose: delivery is correlated one-to-one, and a
fixture whose arms shared a text could not distinguish the arm that received a frame from the arm
that did not.

Serves acceptance item 51 and gate G4 of child C6.4.

**These shapes are synthetic, and confirmed against the pinned bundle.** Nothing here was
recorded. The frame envelopes -- `system/task_started`, `system/task_notification`, an `assistant`
frame carrying a `tool_use` block, a `user` frame carrying a `tool_result` block, an agent's own
`user` frame keyed by `parent_tool_use_id`, and `result` -- are shapes the recorded corpus already
carries, and the agent ids are invented values of the `^a[0-9a-f]{16}$` shape it shows. The tool
name, its `to` / `summary` / `message` input keys, the `{data: {success, message}}` return and the
`JSON.stringify`-into-one-text-block result mapper are all read at their own definition sites in
the pinned 2.1.257 modules, as are both `message` templates carried here. So `fixture.json`
carries `hypothesis: false`. `synthetic: true` stays, and with it the exclusion from `diff`: how
the engine reaches these shapes in this sequence is unrecorded, and a synthetic fixture is never
baseline evidence by itself.

What a recording should still settle, none of it about the shapes above:

1. **Which schema variant the session advertised.** The input builder produces four, selected by
   whether cross-session messaging and agent teams are enabled: `message` is required in two and
   defaulted in the other two, and `notify_when_idle` exists only in the cross-session pair. This
   fixture carries `to`, `summary` and `message`, which every variant admits.
2. **The optional sibling keys.** `msg_id`, `resumedAgentId` and `pin` join the result object
   conditionally. Whether a given run emits them is not decidable from the module, so none is
   written here rather than a guess being written.
3. **The values interpolated into the two templates.** Only the templates are read; the agent name
   substituted into them is this fixture's own invented id.
4. **How a relayed message reaches the target run**, and what wrapper it arrives inside. This
   fixture shows it as a `user` frame on the run's own stream with an invented prefix line.
   afleet's own delivery test is deliberately written to tolerate a wrapper and to refuse a mere
   mention, which is what makes the fixture's guess here safe to be wrong about.

**`verify` may warn that the account name appears in `frames.ndjson`.** On a machine whose
account name is an ordinary English word, the scanner's own caveat applies: the only hit here is
that word inside the engine's stopped-by-user refusal template, which is the same on every
machine. Nothing in this fixture came off anybody's home directory. Item **2** of `REVIEW.md` —
the identity grep — asks a reviewer to judge exactly this, and the judgement is that it
identifies nobody. (Item 4 is `redaction.json`, which this fixture satisfies separately.)

The `Agent` tool round that really precedes each `task_started` is deliberately **absent**: its
result is engine copy about a spawn this fixture does not depict, and no arm reads it. What the
arms need is that the two runs exist, which is what `task_started` states.

Rebuild with `python3 Tools/probe/synthetic/send_message.py <fixtures_root>`, which overwrites the
directory and drops the review block back to unsigned; walk `Fixtures/REVIEW.md` and `make sign`
again afterwards. It is **not** part of `make synthetic`, which owns the two dialog fixtures: a
build of this fixture must never invalidate their review.
"""


def build(fixtures_root):
    """Write the fixture under `fixtures_root` and return its directory."""
    fr = frames()
    work = tempfile.mkdtemp(prefix="afleet-synth-")
    try:
        initial = os.path.join(work, "initial")
        transcript = os.path.join(work, "transcript", fixture.SLUG_TOKEN)
        artifacts = os.path.join(work, "artifacts")
        os.makedirs(initial)
        os.makedirs(transcript)
        os.makedirs(artifacts)
        # The file the fifth arm's `task_notification` names. `verify` requires that an artifact a
        # frame names is present -- a fixture that named one and shipped without it would let a
        # reviewer sign for content nothing can read.
        with open(os.path.join(artifacts, TARGET + ".output"), "w", encoding="utf-8") as fh:
            fh.write("an invented result the run handed back\n")
        with open(os.path.join(transcript, SID + ".jsonl"), "w", encoding="utf-8") as fh:
            for rec in fr:
                f = rec["frame"]
                if f.get("type") in ("user", "assistant"):
                    fh.write(json.dumps({"type": f["type"], "uuid": f.get("uuid"), "cwd": CWD,
                                         "message": f["message"]}) + "\n")
        meta = {"name": NAME, "scenario": None,
                "purpose": "acceptance item 51's five delivery arms as five turns of one session: "
                           "the positive path, no SendMessage call, a call naming another agent, a "
                           "refused resume in a non-error tool_result, and a task_notification "
                           "after the relay",
                "serves": ["item 51"], "spikes": [], "recorded_at": "2026-09-09T00:00:00Z",
                "cli_version": CLI_VERSION, "session_id": SID, "cwd": CWD,
                "launch": {"argv": [], "env": {}}, "prompts": _prompts(fr),
                "census": False, "deterministic": False, "isolation": "none",
                "synthetic": True, "hypothesis": False,
                "late_responses": [], "withdrawn_requests": [],
                "notes": list(NOTES), "exit_code": None,
                "review": {"reviewer": "", "date": "", "checklist_version": verify.CHECKLIST_VERSION}}
        c = census.census([r["frame"] for r in fr], version=CLI_VERSION)
        dest = fixture.write_fixture(fixtures_root, NAME, meta, fr, c, redact.Redactor().manifest(),
                                     initial, os.path.join(work, "transcript"), artifacts)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    # After the atomic assembly rather than inside it, for the reason `dialogs.py` gives: a rebuild
    # replaces the directory whole, and a README the rebuild deleted would leave the fixture's only
    # prose behind on the second run.
    with open(os.path.join(dest, fixture.DOC_FILE), "w", encoding="utf-8") as fh:
        fh.write(README)
    return dest


def main(argv):
    root = argv[1] if len(argv) > 1 else STAGING_ROOT
    dest = build(root)
    # A count and never the destination (root §6.3, §11): a generator run states how much it
    # wrote, and the caller passed the root in, so the path is nothing this line has to tell them.
    files = sum(len(names) for _, _, names in os.walk(dest))
    print("built 1 fixture directory, %d file(s)" % files)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
