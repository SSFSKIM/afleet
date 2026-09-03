"""Fixture verification (spec §4.2 `verify`): structure, lifecycle, redaction, review block.

This is the mechanical half of "redacted before disk and reviewed before commit". It is a
gate, so two things matter more than brevity: it fails closed, and it does not crash. A
malformed fixture is the input it exists to catch, so a line it cannot parse becomes a
finding rather than a traceback -- a verifier that dies on bad input leaves the reviewer
with no verdict at all, which reads the same as a pass to anyone in a hurry.

Findings are safe to print and to store: `redact.scan` and `redact.scan_report_only` name
the rule and the position they fired at and never the material, and everything this module
adds around them is composed from fixture-relative paths, request ids and counts.
"""
import json
import os
import socket

import census
import fixture
import redact

REVIEW_KEYS = ("reviewer", "date", "checklist_version")

# The two fixture files that fingerprint *names* rather than values. Every position in
# them, key and value alike, holds a protocol identifier, a field path or a count, so the
# scanner's structural predicates -- "a field named `user` must hold a placeholder" -- have
# nothing to bind to and misfire on ordinary content: a `user` frame becomes the census
# pair key `user`, and redacting an `email` field leaves `...email` as a manifest path.
# Both are also redacted by construction, since the census is computed from already-redacted
# frames and `Redactor._hit` scrubs every manifest path it records. They are scanned as text
# instead, which still applies every pattern rule of §4.5 -- an address, a secret shape, a
# home directory or a hostname anywhere in either file still fails.
NAMES_ONLY_FILES = ("census.json", "redaction.json")


def _lifecycle(frames, late_ok):
    errors = []
    state = {}   # rid -> (origin, status) origin in {"cli","host"}; status in {"open","closed","cancelled","dropped"}
    subtype = {}
    for rec in frames:
        if "dropped" in rec:
            if rec.get("request_id"):
                state[rec["request_id"]] = ("cli", "dropped")
            continue
        f, d = rec.get("frame") or {}, rec.get("dir")
        t = f.get("type")
        if t == "control_request":
            rid = f.get("request_id"); origin = "cli" if d == "out" else "host"
            state[rid] = (origin, "open"); subtype[rid] = (f.get("request") or {}).get("subtype")
        elif t == "control_response":
            rid = (f.get("response") or {}).get("request_id")
            origin, status = state.get(rid, (None, None))
            if origin is None:
                errors.append("response to unknown request %s" % rid)
            elif status == "dropped":
                continue
            elif status == "cancelled":
                if rid not in late_ok:
                    errors.append("late response to cancelled request %s not listed in late_responses" % rid)
            elif status == "closed":
                errors.append("duplicate response to %s" % rid)
            else:
                expected_dir = "in" if origin == "cli" else "out"
                if d != expected_dir:
                    errors.append("response to %s travels the wrong direction" % rid)
                state[rid] = (origin, "closed")
        elif t == "control_cancel_request":
            rid = f.get("request_id")
            origin, status = state.get(rid, (None, None))
            if origin is None:
                errors.append("cancel for unknown request %s" % rid)
            elif status == "open":
                state[rid] = (origin, "cancelled")
    for rid, (origin, status) in state.items():
        if status == "open" and not (origin == "host" and subtype.get(rid) == "end_session"):
            errors.append("unanswered request %s (%s)" % (rid, subtype.get(rid)))
    return errors


def _walk_files(d):
    for root, _, files in os.walk(d):
        for f in files:
            yield os.path.join(root, f)


def _read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _records(path):
    with open(path) as fh:
        return [json.loads(line) for line in fh if line.strip()]


def _artifact_tokens(line, into):
    for part in line.split(fixture.ARTIFACT_TOKEN + "/")[1:]:
        token = part.split('"')[0].split("'")[0].split()
        if token:
            into.add(token[0])


def verify_fixture(path, home=None, author=None, hostname=None):
    errors, warnings = [], []
    home = home or os.path.expanduser("~")
    # The scanner can only scrub a pattern it holds, so rule 3's hostname half needs one
    # named here; the local host is right on the recording machine and a cross-machine
    # review passes the recording host explicitly (spec Revision Note, 2026-09-04).
    hostname = hostname or socket.gethostname()
    for f in fixture.REQUIRED_FILES:
        if not os.path.isfile(os.path.join(path, f)):
            errors.append("missing %s" % f)
    for d in ("initial", "transcript"):
        if not os.path.isdir(os.path.join(path, d)):
            errors.append("missing %s/" % d)
    if errors:
        return errors, warnings
    fx = fixture.load(path)
    meta, frames = fx["meta"], fx["frames"]
    if meta.get("name") != os.path.basename(os.path.normpath(path)):
        errors.append("fixture.json name %r does not match directory" % meta.get("name"))
    review = meta.get("review") or {}
    if not all(review.get(k) for k in REVIEW_KEYS):
        errors.append("review block is not signed (needs reviewer, date, checklist_version)")
    if meta.get("hypothesis") and not meta.get("synthetic"):
        errors.append("hypothesis: true requires synthetic: true")
    # frames structure
    last_t = -1
    for i, rec in enumerate(frames):
        if not isinstance(rec.get("t"), int) or rec["t"] < last_t:
            errors.append("frames.ndjson line %d: timestamp not a non-decreasing int" % (i + 1))
        last_t = rec.get("t", last_t)
        if rec.get("dir") not in ("in", "out"):
            errors.append("frames.ndjson line %d: dir must be in|out" % (i + 1))
        if "frame" not in rec and "dropped" not in rec:
            errors.append("frames.ndjson line %d: neither frame nor dropped" % (i + 1))
    errors += _lifecycle(frames, set(meta.get("late_responses") or []))
    # census recount (recorded fixtures only)
    if not meta.get("synthetic"):
        recount = census.census([r["frame"] for r in frames if "frame" in r], version=meta.get("cli_version"))
        # `verify` never runs `claude --help`, so it holds no evidence about the flag list or
        # the version and carries the recorded values across verbatim -- `None` included,
        # which `census.diff` reads as "not captured" rather than as an empty list. The
        # comparison then says only what it can: census.json against frames.ndjson.
        recount["flags"] = fx["census"].get("flags")
        recount["version"] = fx["census"].get("version")
        drift = census.diff(fx["census"], recount, "exact" if meta.get("deterministic") else "required")
        if drift:
            errors.append("census.json does not match a recount: %s" % "; ".join(drift))
    # artifacts tokens
    art_dir = os.path.join(path, "artifacts")
    needed = set()
    for rec in frames:
        for s in fixture._strings(rec):
            if fixture.ARTIFACT_TOKEN in s:
                _artifact_tokens(s, needed)
    for fpath in _walk_files(os.path.join(path, "transcript")):
        with open(fpath, errors="replace") as fh:
            for line in fh:
                if fixture.ARTIFACT_TOKEN in line:
                    _artifact_tokens(line, needed)
    for rel in sorted(needed):
        if not os.path.isfile(os.path.join(art_dir, rel)):
            errors.append("artifacts/%s named by a frame or record is missing" % rel)
    # mirror fidelity: initial records + mirrored entries per stream == transcript records (recorded fixtures)
    if not meta.get("synthetic"):
        rec_slug = fixture.slug_of(meta["cwd"]) if meta.get("cwd") else None
        mirrored = {}
        for rec in frames:
            f = rec.get("frame") or {}
            if f.get("type") == "transcript_mirror" and "/projects/" in f.get("filePath", ""):
                stream = f["filePath"].split("/projects/", 1)[1]
                if rec_slug:
                    stream = stream.replace(rec_slug, fixture.SLUG_TOKEN, 1)
                mirrored.setdefault(stream, []).extend(f.get("entries", []))
        for stream, entries in mirrored.items():
            init_path = os.path.join(path, "initial", stream)
            final_path = os.path.join(path, "transcript", stream)
            if not os.path.isfile(final_path):
                errors.append("mirror names stream %s but transcript/%s is missing" % (stream, stream)); continue
            try:
                head = _records(init_path) if os.path.isfile(init_path) else []
                got = _records(final_path)
            except ValueError:
                errors.append("transcript/%s is not valid JSONL and cannot be compared with the mirror" % stream)
                continue
            want = head + entries
            if got != want:
                errors.append("mirror entries for %s do not reproduce transcript/%s (%d mirrored + %d initial vs %d records)" % (stream, stream, len(entries), len(head), len(got)))
    # streams offsets
    initial_sizes = fixture.stream_sizes(os.path.join(path, "initial"))
    for stream, off in fx["streams"].items():
        if off > initial_sizes.get(stream, 0):
            errors.append("streams.json offset for %s exceeds the file under initial/" % stream)
    for stream in initial_sizes:
        tpath = os.path.join(path, "transcript", stream)
        if os.path.isfile(tpath):
            with open(os.path.join(path, "initial", stream), "rb") as a, open(tpath, "rb") as b:
                if not b.read().startswith(a.read()):
                    errors.append("transcript/%s does not extend initial/%s" % (stream, stream))
    # redaction scan on every file
    for fpath in _walk_files(path):
        rel = os.path.relpath(fpath, path)
        try:
            text = _read_text(fpath)
        except UnicodeDecodeError:
            # A file the scanners cannot read is a file the reviewer cannot read either.
            # `snapshot` and `collect_artifacts` stub undecodable content rather than store
            # it, so one reaching a fixture is a hole in the gate's coverage, not a file to
            # skip past.
            errors.append("%s: not UTF-8 text, so no redaction rule can be checked against it" % rel)
            continue
        except OSError as exc:
            errors.append("%s: unreadable (%s)" % (rel, exc.strerror))
            continue
        objs = []
        if rel in NAMES_ONLY_FILES:
            objs.append(text)
        elif fpath.endswith((".json", ".jsonl", ".ndjson")):
            for line in (text.splitlines() if fpath.endswith((".jsonl", ".ndjson")) else [text]):
                if line.strip():
                    try:
                        objs.append(json.loads(line))
                    except ValueError:
                        objs.append(line)
        else:
            objs.append(text)
        for o in objs:
            for hit in redact.scan(o, home, hostname=hostname):
                errors.append("%s: %s" % (rel, hit))
        for w in redact.scan_report_only(text, author, home):
            warnings.append("%s: %s" % (rel, w))
    return errors, warnings
