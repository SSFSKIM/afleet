"""A rewind and the chain it abandons: `last-prompt.leafUuid` against file order (parent §7.3, C3).

C3's timeline reducer folds a transcript in file order and then has to answer *which leaf is
current*, because a rewound session's file holds two chains and only one of them is the
conversation. `plain-two-turn` shows the pointer at rest -- every `last-prompt` record there
names the leaf that is also the last conversational record in the file -- and nothing in the
corpus showed the two disagreeing. This recording makes them disagree: it resumes that
session, rewinds the conversation to the *first* turn's user message, and sends one short
prompt, so the file ends holding the abandoned second turn above a new chain hung off the
rewind point.

What the recording is evidence for is therefore the whole of it: the `rewind_conversation`
response fields, every frame the wire carried between the request going out and the next
turn's `result`, and the file's shape afterwards -- the chain reachable from the final
`last-prompt.leafUuid` by `parentUuid`, and the records that are in the file and not on it.
The scenario computes all three into `notes` rather than leaving a reader to re-derive them
from `transcript/`, because the abandoned branch is invisible to anyone reading the file as
a list.

`rewind_conversation` is already recorded once, in `control-shapes`, where it is one shape in
a sweep and no turn follows it. This is the other half: the same request with a conversation
on either side of it.

`unmirrored_prefix: 1` for the same reason `session-mirror-resume` declares it: a resume
appends one record at the head of the range that the mirror never carries.
"""
import glob
import json
import os

META = {"name": "rewind-turn",
        "purpose": "resume plain-two-turn, rewind to the first turn's user message, then one turn: "
                   "a last-prompt leaf that is not the file's last record, and the abandoned branch",
        "serves": ["C3.G1", "item 13"], "spikes": [], "census": False,
        "optional_pairs": ["system/thinking_tokens"], "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 2}, "unmirrored_prefix": 1,
        "prompts": ["Reply with exactly the word: three"], "resume_of": "plain-two-turn", "setup": None}


def transcript_path(config_home, session_id):
    hits = glob.glob(os.path.join(config_home, "projects", "*", session_id + ".jsonl"))
    return hits[0] if len(hits) == 1 else None


def records(path):
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
    """The uuid of the first conversational user record: the rewind target.

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


def run(session, ctx):
    home = ctx["config_home"]
    sid = (session.system_init or {}).get("session_id") or ctx["launch"].resume
    path = transcript_path(home, sid)
    ctx["notes"].append("session %s; transcript %s" % (sid, "found" if path else "NOT FOUND under the config home"))
    if not path:
        return
    before = records(path)
    target = first_user_uuid(before)
    ctx["notes"].append("records on disk before the rewind: %d; rewind target (first user record) uuid: %s"
                        % (len(before), target))
    ctx["notes"].append("last-prompt leaves before the rewind, in file order: %s"
                        % [r.get("leafUuid") for r in before if r.get("type") == "last-prompt"])

    mark = len(session.frames())
    resp = session.request("rewind_conversation", target_message_uuid=target, timeout=60)
    body = resp.get("response") if resp.get("subtype") == "success" else resp.get("error")
    ctx["notes"].append("rewind_conversation -> %s %s" % (resp.get("subtype"), json.dumps(body)[:400]
                                                          if isinstance(body, dict) else str(body)[:400]))
    after_rewind = session.frames()[mark:]
    ctx["notes"].append("frames on the wire between the rewind request and its response: %s"
                        % [(f.get("dir"), (f.get("frame") or {}).get("type"), (f.get("frame") or {}).get("subtype"))
                           for f in after_rewind])
    mid = records(path)
    ctx["notes"].append("records on disk immediately after the rewind: %d (was %d); the file %s"
                        % (len(mid), len(before), "grew" if len(mid) > len(before)
                           else "shrank" if len(mid) < len(before) else "did not change"))

    session.send_user(META["prompts"][0])
    session.wait_result(timeout=180)

    after = records(path)
    leaves = [r.get("leafUuid") for r in after if r.get("type") == "last-prompt"]
    leaf = leaves[-1] if leaves else None
    chain = chain_from(after, leaf)
    order = [r["uuid"] for r in after if r.get("uuid")]
    on_chain = set(chain)
    abandoned = [u for u in order if u not in on_chain]
    ctx["notes"].append("records on disk after the turn: %d; last-prompt leaves in file order: %s" % (len(after), leaves))
    ctx["notes"].append("final leafUuid: %s; it is record %s of %d in file order"
                        % (leaf, order.index(leaf) + 1 if leaf in order else "ABSENT", len(order)))
    ctx["notes"].append("chain from that leaf to the root, %d records: %s" % (len(chain), chain))
    ctx["notes"].append("records in the file and not on that chain (the abandoned branch), %d: %s"
                        % (len(abandoned), abandoned))
    ctx["notes"].append("record types on the abandoned branch: %s"
                        % [r.get("type") for r in after if r.get("uuid") in set(abandoned)])
    ctx["notes"].append("the file's last uuid-carrying record is %s, which is %s the current leaf"
                        % (order[-1] if order else None, "also" if order and order[-1] == leaf else "NOT"))
