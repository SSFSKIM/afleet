"""Two rewinds, one refused: `last-prompt.leafUuid` against file order (parent §7.3, C3).

C3's timeline reducer folds a transcript in file order and then has to answer *which leaf is
current*, because a rewound session's file holds two chains and only one of them is the
conversation. `plain-two-turn` shows the pointer at rest -- every `last-prompt` there names
the leaf that is also the last conversational record in the file -- and nothing in the corpus
showed the two disagreeing.

The recording asks for the rewind twice, because the first attempt found the boundary that
matters more than the disagreement does:

1. **A uuid read off the resumed transcript is refused.** `rewind_conversation` answers
   `success` -- the envelope is a success, not an error -- with a body of
   `{rewound: false, prefillText: null, precedingAssistantUuid: null, error: "stale target"}`,
   and nothing is written. This is the case afleet's *Edit and resend* is (§10 item 13, §7.3's
   edit-via-rewind): a user scrolls back to a message from before the current process and
   edits it. The engine will not rewind to it.
2. **A uuid this session sent is honoured.** The same request against the uuid the host put on
   its own `user` frame -- the id the engine writes onto the record, confirmed here -- is the
   case `control-shapes` recorded one shape of. Asking it second costs no model turn and is
   what produces the divergence C3 needs: the leaf moves back off the turn just recorded and
   that turn becomes an abandoned branch, still in the file, below the current leaf.

So the fixture holds the refusal, the acceptance, every frame either one put on the wire, and
the file on both sides of them. The scenario computes the chain reachable from the final
`last-prompt.leafUuid` by `parentUuid` and the records that are in the file and not on it,
because the abandoned branch is invisible to anyone reading the file as a list.

Reads of the file are taken after it settles, never straight after `wait_result`, because a
`result` frame does not mean the file has stopped growing: this fixture's first recording read
at the `result` and reported an off-chain turn that a record arriving afterwards would have
put back on the chain. The settle does not make the read authoritative -- see the README on
what this recording did and did not see about when a turn's closing `last-prompt` is written
-- it only stops the scenario from reporting a race as a finding.

No `unmirrored_prefix`. `session-mirror-resume` declares one because the resume it records
appends a record at the head of its range that the mirror never carries; this resume appends
none, and `verify` needed exactly zero on the recording. The count is a property of the run
and not of resuming in general, which is why it is declared per scenario and checked for
exactness in both directions -- a declaration nothing needs fails the gate just as a missing
one does, and this scenario failed its first recording that way.
"""
import glob
import json
import os
import time

META = {"name": "rewind-turn",
        "purpose": "resume plain-two-turn; rewind to the resumed transcript's first user message (refused, "
                   "\"stale target\"); one turn; rewind to that turn's own user message (honoured): a "
                   "last-prompt leaf that is not the file's last record, and the abandoned branch",
        "serves": ["C3.G1", "item 13"], "spikes": [], "census": False,
        "optional_pairs": ["system/thinking_tokens"], "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 2},
        "prompts": ["Reply with exactly the word: three"], "resume_of": "plain-two-turn", "setup": None}


def transcript_path(config_home, session_id):
    hits = glob.glob(os.path.join(config_home, "projects", "*", session_id + ".jsonl"))
    return hits[0] if len(hits) == 1 else None


def settled_records(path, quiet=3.0, timeout=30.0):
    """The file's records once its size has held still for `quiet` seconds.

    See the module docstring: a `result` frame is not the end of the file's growth, and a read
    taken at one can misreport the newest turn as an abandoned branch.
    """
    deadline, size, since = time.time() + timeout, -1, time.time()
    while time.time() < deadline:
        now = os.path.getsize(path)
        if now != size:
            size, since = now, time.time()
        elif time.time() - since >= quiet:
            break
        time.sleep(0.5)
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def first_user_uuid(recs):
    """The uuid of the first conversational user record: the first rewind's target.

    `isMeta` and `isSynthetic` user records are the engine's own injections (§7.3 hides them
    from the timeline), so targeting one would rewind to something the user never sent.
    """
    for r in recs:
        if r.get("type") == "user" and not r.get("isMeta") and not r.get("isSynthetic") and r.get("uuid"):
            return r["uuid"]
    return None


def chain_from(recs, leaf):
    """The uuids from `leaf` back to the root, following `parentUuid`."""
    by_uuid = {r["uuid"]: r for r in recs if r.get("uuid")}
    seen, cur = [], leaf
    while cur and cur in by_uuid and cur not in seen:
        seen.append(cur)
        cur = by_uuid[cur].get("parentUuid")
    return list(reversed(seen))


def describe(ctx, label, recs, extra=""):
    leaves = [r.get("leafUuid") for r in recs if r.get("type") == "last-prompt"]
    leaf = leaves[-1] if leaves else None
    chain = chain_from(recs, leaf)
    order = [r["uuid"] for r in recs if r.get("uuid")]
    abandoned = [u for u in order if u not in set(chain)]
    ctx["notes"].append("%s: %d records, %d of them uuid-carrying%s" % (label, len(recs), len(order), extra))
    ctx["notes"].append("  last-prompt leaves in file order: %s" % leaves)
    ctx["notes"].append("  current leaf %s is record %s of %d in file order; the file's last uuid-carrying "
                        "record is %s, which is %s the current leaf"
                        % (leaf, order.index(leaf) + 1 if leaf in order else "ABSENT", len(order),
                           order[-1] if order else None, "also" if order and order[-1] == leaf else "NOT"))
    ctx["notes"].append("  chain from the leaf to the root, %d records: %s" % (len(chain), chain))
    ctx["notes"].append("  in the file and not on that chain, %d: %s" % (len(abandoned), abandoned))
    ctx["notes"].append("  their record types: %s" % [r.get("type") for r in recs if r.get("uuid") in set(abandoned)])
    return recs


def rewind(session, ctx, label, target):
    mark = len(session.frames())
    resp = session.request("rewind_conversation", target_message_uuid=target, timeout=60)
    body = resp.get("response") if resp.get("subtype") == "success" else resp.get("error")
    ctx["notes"].append("rewind_conversation %s, target %s -> envelope %s, body %s"
                        % (label, target, resp.get("subtype"),
                           json.dumps(body) if isinstance(body, dict) else str(body)[:300]))
    ctx["notes"].append("  frames on the wire from the request to its response: %s"
                        % [(f.get("dir"), (f.get("frame") or {}).get("type"),
                            (f.get("frame") or {}).get("subtype")) for f in session.frames()[mark:]])
    return resp


def run(session, ctx):
    home = ctx["config_home"]
    sid = (session.system_init or {}).get("session_id") or ctx["launch"].resume
    path = transcript_path(home, sid)
    ctx["notes"].append("session %s; transcript %s" % (sid, "found" if path else "NOT FOUND under the config home"))
    if not path:
        return

    before = describe(ctx, "on disk at the resume", settled_records(path, quiet=1.0, timeout=5.0))
    target = first_user_uuid(before)
    rewind(session, ctx, "at the resumed transcript's first user record", target)
    describe(ctx, "on disk after that rewind", settled_records(path, quiet=1.0, timeout=5.0))

    sent = session.send_user(META["prompts"][0])
    session.wait_result(timeout=180)
    ctx["notes"].append("the host put uuid %s on its own user frame" % sent)
    after_turn = describe(ctx, "on disk after the turn", settled_records(path))
    ctx["notes"].append("the engine wrote the host's uuid onto the record: %s"
                        % (sent in [r.get("uuid") for r in after_turn]))

    rewind(session, ctx, "at the user record this session sent", sent)
    describe(ctx, "on disk after that rewind", settled_records(path, quiet=2.0, timeout=15.0))
