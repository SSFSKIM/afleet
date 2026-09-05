"""A compaction, on the wire and on disk: `system/compact_boundary` and its record (parent §7.3, C3).

§7.3 makes the compact boundary a timeline item of its own and puts `compact_boundary` on the
list of `system` records that reach the file and never the wire -- a list that decides which
records C3's differential invariant compares file-to-file rather than against the wire
reducer. Nothing in the corpus had a compaction in it, so both halves of that clause were
unobserved: whether the record carries `compactMetadata` on disk, and whether anything named
`compact_boundary` also travels as a frame.

The recording resumes `plain-two-turn` and sends `/compact` as a user message, which is the
only way a host on this protocol can ask for one -- there is no control request for it. Two
things could happen and both are evidence: the engine runs the compaction and writes the
boundary and its summary, or it declines the slash command headless, in which case the notes
say so and the fixture is evidence that a host cannot trigger a compaction this way. The
scenario asserts nothing either way; it reports what the file and the wire hold afterwards.

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

COMPACT = "/compact"

META = {"name": "compact-boundary",
        "purpose": "resume plain-two-turn and send /compact: the compact_boundary record, its "
                   "compactMetadata, the summary record and whatever the wire carries",
        "serves": ["C3.G1", "C3.G3"], "spikes": [], "census": False,
        "optional_pairs": ["system/thinking_tokens"], "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 4},
        "prompts": [COMPACT], "resume_of": "plain-two-turn", "setup": None}


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


def summarise(rec):
    """A record reduced to its shape: keys, and the key set of anything nested one level.

    The compaction summary is model text about the conversation, and the conversation is
    synthetic here, but the same rule holds as everywhere else -- a note quotes the shape and
    lets the fixture carry the bytes.
    """
    out = {"type": rec.get("type"), "subtype": rec.get("subtype"), "keys": sorted(rec.keys())}
    for k in ("compactMetadata", "message"):
        if isinstance(rec.get(k), dict):
            out[k + "_keys"] = sorted(rec[k].keys())
    return out


def run(session, ctx):
    home = ctx["config_home"]
    sid = (session.system_init or {}).get("session_id") or ctx["launch"].resume
    path = transcript_path(home, sid)
    ctx["notes"].append("session %s; transcript %s" % (sid, "found" if path else "NOT FOUND under the config home"))
    before = records(path) if path else []
    ctx["notes"].append("records on disk before /compact: %d" % len(before))

    mark = len(session.frames())
    session.send_user(COMPACT)
    result = session.wait_result(timeout=300)
    ctx["notes"].append("result after /compact: subtype=%s is_error=%s num_turns=%s result=%r"
                        % ((result or {}).get("subtype"), (result or {}).get("is_error"),
                           (result or {}).get("num_turns"), str((result or {}).get("result"))[:300]))

    new = [f for f in session.frames()[mark:] if "frame" in f]
    ctx["notes"].append("frames after /compact, in order: %s"
                        % [((f["frame"].get("type")), f["frame"].get("subtype")) for f in new])
    compact_frames = [f["frame"] for f in new if f["frame"].get("subtype") == "compact_boundary"
                      or "compact" in str(f["frame"].get("subtype") or "")]
    ctx["notes"].append("frames whose subtype names a compaction: %d%s"
                        % (len(compact_frames),
                           "" if not compact_frames else "; keys: %s"
                           % [sorted(f.keys()) for f in compact_frames]))
    mirrors = [f["frame"] for f in new if f["frame"].get("type") == "transcript_mirror"]
    mirrored_types = []
    for f in mirrors:
        # A mirror frame's `entries` are the records themselves, not envelopes around them.
        for entry in (f.get("entries") or []):
            if isinstance(entry, dict):
                mirrored_types.append((entry.get("type"), entry.get("subtype")))
    ctx["notes"].append("transcript_mirror frames after /compact: %d; record (type, subtype) they carried: %s"
                        % (len(mirrors), mirrored_types))

    after = records(path) if path else []
    appended = after[len(before):]
    ctx["notes"].append("records on disk after /compact: %d (%d appended); the file %s"
                        % (len(after), len(appended),
                           "grew" if len(after) > len(before) else
                           "shrank -- local garbage collection rewrote it" if len(after) < len(before) else
                           "did not change"))
    ctx["notes"].append("appended record shapes: %s" % json.dumps([summarise(r) for r in appended])[:3000])
    boundaries = [r for r in after if r.get("subtype") == "compact_boundary"]
    ctx["notes"].append("compact_boundary records on disk: %d%s"
                        % (len(boundaries),
                           "" if not boundaries else "; shapes: %s" % json.dumps([summarise(r) for r in boundaries])))
    summaries = [r for r in appended if r.get("isCompactSummary") or r.get("type") == "summary"]
    ctx["notes"].append("records marked as a compaction summary: %d%s"
                        % (len(summaries),
                           "" if not summaries else "; shapes: %s" % json.dumps([summarise(r) for r in summaries])))
