"""S14 and S13: mirrored entries equal the transcript's appends across a set_cwd relocation
(items 56, 64; C3.G3, C3.G4).

The catalogue's `session-mirror-relocation` row is two fixtures. A fixture is one process and
the row's resume is a second one, so the relocation half is here and the resume half is
`session_mirror_resume`, which imports the comparison below rather than keeping a second copy
of it.

The sibling directory is named after the session, so every run relocates into a directory the
scratch config home has never trusted. A fixed name is trusted from the first recording
onwards, and the drift ritual would then compare a needs-trust answer against a trusted one --
a difference that says nothing about the binary.
"""
import json
import os


def mirror_matches_file(session, config_home):
    """Concatenate `transcript_mirror` entries per `filePath` and compare with the file's
    records, record for record. Reports per stream rather than asserting: what the scenario
    exists to record is what the mirror did, and a mismatch is evidence, not a crash."""
    per_file = {}
    for rec in session.frames():
        f = rec.get("frame") or {}
        if f.get("type") == "transcript_mirror":
            per_file.setdefault(f["filePath"], []).extend(f.get("entries", []))
    report = []
    for path, entries in sorted(per_file.items()):
        real = os.path.expanduser(path.replace("~/.claude", config_home, 1)) if path.startswith("~/.claude") else path
        if not os.path.isfile(real):
            report.append("%s: file missing" % path)
            continue
        with open(real, encoding="utf-8") as fh:
            records = [json.loads(l) for l in fh if l.strip()]
        tail = records[-len(entries):] if entries else []
        report.append("%s: %d mirrored, file has %d records, tail equal: %s"
                      % (os.path.basename(path), len(entries), len(records), tail == entries))
    return report


META = {"name": "session-mirror-relocation",
        "purpose": "two turns, set_cwd to a sibling (trust accepted when asked), two more turns",
        "serves": ["item 56", "item 64", "C3.G3", "C3.G4"], "spikes": ["S13", "S14"], "census": True,
        "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 4},
        "prompts": ["Reply with exactly: m1", "Reply with exactly: m2", "Reply with exactly: m3", "Reply with exactly: m4"],
        "resume_of": None, "setup": None}


def run(session, ctx):
    for p in META["prompts"][:2]:
        session.send_user(p)
        session.wait_result(timeout=120)
    sibling = os.path.join(os.path.dirname(ctx["cwd"]),
                           "session-mirror-relocation-sibling-%s" % (session.system_init or {}).get("session_id", "unknown"))
    os.makedirs(sibling, exist_ok=True)
    r = session.request("set_cwd", path=sibling)
    body = r.get("response") or {}
    ctx["notes"].append("set_cwd sibling -> %s %s" % (r.get("subtype"), json.dumps(body)[:200]))
    if body.get("status") == "needs_trust" or body.get("needs_trust"):
        r2 = session.request("set_cwd", path=sibling, trust_accepted=True)
        ctx["notes"].append("set_cwd trust_accepted -> %s %s"
                            % (r2.get("subtype"), json.dumps(r2.get("response") or r2.get("error"))[:200]))
    for p in META["prompts"][2:]:
        session.send_user(p)
        session.wait_result(timeout=120)
    errors = [f for f in session.frames() if f.get("frame", {}).get("subtype") == "mirror_error"]
    ctx["notes"].append("mirror_error frames: %d" % len(errors))
    ctx["notes"] += mirror_matches_file(session, ctx["config_home"])
    cfg = os.path.join(ctx["config_home"], ".claude.json")
    if os.path.isfile(cfg):
        with open(cfg, encoding="utf-8") as fh:
            projects = (json.load(fh).get("projects") or {})
        ctx["notes"].append("scratch .claude.json trust for the sibling: %s"
                            % (projects.get(sibling) or {}).get("hasTrustDialogAccepted"))
