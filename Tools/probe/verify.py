"""Fixture verification (spec §4.2 `verify`): structure, lifecycle, redaction, review block.

This is the mechanical half of "redacted before disk and reviewed before commit". It is a
gate, so three things matter more than brevity.

*It fails closed.* Where a check cannot decide, it reports. Where a file cannot be read by
the scanners, that is itself the finding, because content the tooling is blind to is content
a reviewer signs for without having seen.

*It does not crash.* A malformed fixture is the input it exists to catch, so a line it
cannot parse becomes a finding rather than a traceback. A verifier that dies on bad input
leaves the reviewer with no verdict at all, which reads the same as a pass to anyone in a
hurry.

*It needs no binary.* Every check here compares one part of a fixture against another, so it
holds for a synthetic fixture as much as a recorded one. §4.4 excludes synthetic fixtures
from `diff`, the live-binary drift command; nothing here is that command.

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

# §4.4's `fixture.json` enumeration, plus `deterministic`, which the same section's census
# paragraph names in prose. Required by presence and not by value: a missing `deterministic`
# reads as false and silently picks the permissive census comparison over the strict one,
# which is precisely the downgrade `census.diff` refuses to allow at its own boundary. A
# recorded fixture gets these from `record`; a hand-written synthetic one is where the
# omission is real.
REQUIRED_META = ("name", "purpose", "recorded_at", "cli_version", "launch", "prompts", "serves",
                 "census", "deterministic", "synthetic", "hypothesis", "late_responses", "review")

# The two fixture files that carry protocol *names* in key position: `census.json` is keyed
# by `(type, subtype)` pair names and `redaction.json` by the field paths a rule touched. The
# scanner's structural predicates ask of a key "must this field's value be a placeholder?",
# which has no answer for a name promoted into key position -- a `user` frame becomes the
# census key `pairs.user`, and redacting an `email` field leaves `...email` as a manifest
# path, so both misfire on ordinary content. `_names_only` moves exactly those names into
# value position, where they get the pattern rules and nothing else, and leaves every real
# value in the file under every predicate. `capabilities` is why the line is drawn at the key
# and not at the file: the census copies it verbatim out of `system/init`, §4.4 calls it an
# object, and a hand-written synthetic fixture is the one place its contents were never near
# the redactor.
NAMES_ONLY_FILES = ("census.json", "redaction.json")


# ---- request lifecycle (§4.2)

def _lifecycle(frames, late_ok):
    errors = []
    state = {}      # rid -> (origin, status); origin in {"cli","host"}, status in {"open","closed","cancelled","dropped"}
    subtype = {}
    opened_at = {}
    # Once the host closes stdin nothing more can travel host to CLI, so the index of the
    # last inbound record is the point past which an unanswered host request is explicable.
    last_inbound = max((i for i, rec in enumerate(frames) if rec.get("dir") == "in"), default=-1)
    # The very last record, when it is a host request, may be one the harness recorded but
    # never managed to write. `Session._send_locked` records and writes as one step while
    # holding the write lock -- which is what keeps capture order and wire order the same --
    # so a child that exits between the two leaves exactly one frame in the capture that
    # never reached the wire. That is a legitimate recording, and the tail is the only place
    # it can sit, because the failing write raises and nothing the host sent follows it. A gap
    # anywhere earlier means the recording is wrong, and a second unmatched trailing request
    # means something other than one failed final write.
    unwritten = None
    if frames and frames[-1].get("dir") == "in":
        tail = frames[-1].get("frame") or {}
        if tail.get("type") == "control_request":
            unwritten = tail.get("request_id")
    for i, rec in enumerate(frames):
        if "dropped" in rec:
            if rec.get("request_id"):
                state[rec["request_id"]] = ("cli", "dropped")
            continue
        f, d = rec.get("frame") or {}, rec.get("dir")
        t = f.get("type")
        if t == "control_request":
            rid = f.get("request_id"); origin = "cli" if d == "out" else "host"
            state[rid] = (origin, "open"); subtype[rid] = (f.get("request") or {}).get("subtype")
            opened_at[rid] = i
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
                # Closed either way: `late_responses` licenses one late answer to a cancelled
                # request, not a stream of them, so a second reads as the duplicate it is.
                state[rid] = (origin, "closed")
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
            elif origin != "cli" or d != "out":
                # §4.2 ends a lifecycle without a response in exactly one shape: the CLI
                # cancelling its own request. Anything else leaves the request open, so a host
                # request that is never answered cannot be excused by a cancel line carrying
                # its id.
                #
                # `harness.Session.cancel` sends the other shape, and the `control-shapes`
                # scenario uses it on a `claude_oauth_wait_for_completion` that does not come
                # back, so the first recording of that scenario meets this error by design.
                # Strict on purpose: whether the CLI answers a request the host has cancelled is
                # a protocol fact, so §4.2 is amended by a recording that shows one, not by a
                # reading of what cancellation probably does. A hit here is evidence for S8, not
                # a fixture defect to work around.
                errors.append("cancel for %s travels %s against a %s-originated request; only the CLI may cancel its own"
                              % (rid, d, origin))
            elif status == "open":
                state[rid] = (origin, "cancelled")
    for rid, (origin, status) in state.items():
        if status != "open":
            continue
        if rid is not None and rid == unwritten:
            continue
        # The other carve-out, and it too is about a mechanism rather than about a subtype: the
        # harness sends `end_session` and closes stdin in the same breath (§6.7), so that
        # response may legitimately never be captured. The reasoning holds only while nothing
        # further travels host to CLI -- a fixture with later inbound traffic still had an
        # open stream, and a missing response there is a real gap.
        if origin == "host" and subtype.get(rid) == "end_session" and opened_at.get(rid) == last_inbound:
            continue
        errors.append("unanswered request %s (%s)" % (rid, subtype.get(rid)))
    return errors


# ---- reading

def _walk_files(d):
    for root, _, files in os.walk(d):
        for f in files:
            yield os.path.join(root, f)


def _read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _records(path):
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


# ---- the checks, one section each

def _check_present(path):
    errors = []
    for f in fixture.REQUIRED_FILES:
        if not os.path.isfile(os.path.join(path, f)):
            errors.append("missing %s" % f)
    for d in ("initial", "transcript"):
        if not os.path.isdir(os.path.join(path, d)):
            errors.append("missing %s/" % d)
    return errors


def _check_meta(path, meta):
    errors = ["fixture.json is missing %s (spec §4.4)" % k for k in REQUIRED_META if k not in meta]
    if meta.get("name") != os.path.basename(os.path.normpath(path)):
        errors.append("fixture.json name %r does not match directory" % meta.get("name"))
    review = meta.get("review") or {}
    if not all(review.get(k) for k in REVIEW_KEYS):
        errors.append("review block is not signed (needs reviewer, date, checklist_version)")
    if meta.get("hypothesis") and not meta.get("synthetic"):
        errors.append("hypothesis: true requires synthetic: true")
    return errors


def _check_frames(frames):
    errors = []
    last_t = -1
    for i, rec in enumerate(frames):
        if isinstance(rec.get("t"), int) and rec["t"] >= last_t:
            last_t = rec["t"]
        else:
            # A bad value does not become the new floor. Adopting it would either wave through
            # every record after it or condemn every well-formed one, and both cost the
            # reviewer the one line that is actually wrong.
            errors.append("frames.ndjson line %d: timestamp not a non-decreasing int" % (i + 1))
        if rec.get("dir") not in ("in", "out"):
            errors.append("frames.ndjson line %d: dir must be in|out" % (i + 1))
        if "frame" not in rec and "dropped" not in rec:
            errors.append("frames.ndjson line %d: neither frame nor dropped" % (i + 1))
    return errors


def _check_census(fx):
    """`census.json` against `frames.ndjson`, for every fixture including a synthetic one.

    Both sides live inside the fixture, so this needs no binary and says the same thing about
    a hand-written fixture as about a recorded one -- and a hand-written census is exactly the
    one that nothing else in the pipeline has ever read.
    """
    meta, recorded = fx["meta"], fx["census"]
    errors = []
    if recorded.get("version") != meta.get("cli_version"):
        errors.append("census.json version %r does not match fixture.json cli_version %r"
                      % (recorded.get("version"), meta.get("cli_version")))
    recount = census.census([r["frame"] for r in fx["frames"] if "frame" in r])
    # `verify` never runs `claude --help`, so it holds no evidence about the flag list and
    # carries the recorded value across verbatim -- `None` included, which `census.diff` reads
    # as "not captured" rather than as an empty list. The version is not compared through the
    # recount at all; it is checked against fixture.json above, which is the claim worth
    # making about it.
    recount["flags"] = recorded.get("flags")
    drift = census.diff(recorded, recount, "exact" if meta.get("deterministic") else "required")
    if drift:
        errors.append("census.json does not match a recount: %s" % "; ".join(drift))
    return errors


def _artifact_tokens(text, into):
    """Every `<artifacts>/…` path a frame string or a record line names.

    A token ends where its JSON string ends, not at the first space. Every file in a fixture
    that carries one is JSON, and truncating at a space turns an artifact path containing a
    space into a missing-artifact failure the reviewer has to override -- which is how a gate
    stops being read.
    """
    for part in text.split(fixture.ARTIFACT_TOKEN + "/")[1:]:
        token = part.split('"')[0].split("'")[0].strip()
        if token:
            into.add(token)


def _check_artifacts(path, frames):
    needed = set()
    for rec in frames:
        for s in fixture._strings(rec):
            if fixture.ARTIFACT_TOKEN in s:
                _artifact_tokens(s, needed)
    # `initial/` as well as `transcript/`: a resume fixture's `initial/` holds a prior
    # session's records, and those name artifacts a replay has to resolve too.
    for sub in ("initial", "transcript"):
        for fpath in _walk_files(os.path.join(path, sub)):
            with open(fpath, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if fixture.ARTIFACT_TOKEN in line:
                        _artifact_tokens(line, needed)
    art_dir = os.path.join(path, "artifacts")
    return ["artifacts/%s named by a frame or record is missing" % rel
            for rel in sorted(needed) if not os.path.isfile(os.path.join(art_dir, rel))]


def _check_mirror(path, fx):
    """Mirrored entries reproduce the transcript: `initial/` records plus every mirrored
    entry, in order, are the `transcript/` records.

    Recorded fixtures only. A synthetic fixture is written from schemas rather than off a
    filesystem, so it may legitimately declare no transcript at all; the census recount has no
    such excuse, which is why that one runs unconditionally and this does not.
    """
    meta, frames = fx["meta"], fx["frames"]
    if meta.get("synthetic"):
        return []
    errors = []
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
            errors.append("mirror names stream %s but transcript/%s is missing" % (stream, stream))
            continue
        try:
            head = _records(init_path) if os.path.isfile(init_path) else []
            got = _records(final_path)
        except ValueError:
            errors.append("transcript/%s is not valid JSONL and cannot be compared with the mirror" % stream)
            continue
        want = head + entries
        if got != want:
            errors.append("mirror entries for %s do not reproduce transcript/%s (%d mirrored + %d initial vs %d records)"
                          % (stream, stream, len(entries), len(head), len(got)))
    return errors


def _check_streams(path, fx):
    errors = []
    initial_sizes = fixture.stream_sizes(os.path.join(path, "initial"))
    for stream, off in fx["streams"].items():
        if not isinstance(off, int) or off < 0:
            errors.append("streams.json offset for %s is not a non-negative integer" % stream)
        elif off > initial_sizes.get(stream, 0):
            errors.append("streams.json offset for %s exceeds the file under initial/" % stream)
    for stream in initial_sizes:
        tpath = os.path.join(path, "transcript", stream)
        if os.path.isfile(tpath):
            with open(os.path.join(path, "initial", stream), "rb") as a, open(tpath, "rb") as b:
                if not b.read().startswith(a.read()):
                    errors.append("transcript/%s does not extend initial/%s" % (stream, stream))
    return errors


# ---- the §4.5 scanners over every file

def _names_only(rel, obj):
    """A names-only file reshaped so its name-bearing keys sit in value position.

    Returns None when the file is not one of them or does not have the shape, in which case
    the caller scans it unchanged -- the safe direction, since an unreshaped scan over-reports
    rather than under-reports.
    """
    if not isinstance(obj, dict):
        return None
    if rel == "census.json":
        pairs = obj.get("pairs")
        if not isinstance(pairs, dict):
            return None
        # `capabilities`, `flags` and `version` stay exactly where they are: they hold values
        # copied off the wire, which is what the structural predicates are for.
        return dict(obj, pairs=list(pairs.values()) + list(pairs.keys()))
    if rel == "redaction.json":
        rules = obj.get("rules")
        if not isinstance(rules, dict):
            return None
        reshaped = {}
        for rule, rec in rules.items():
            if not isinstance(rec, dict):
                return None
            paths = rec.get("paths")
            reshaped[rule] = dict(rec, paths=list(paths.keys()) + list(paths.values())) if isinstance(paths, dict) else rec
        return dict(obj, rules=reshaped)
    return None


def _scan_objects(rel, fpath, text):
    """What the structural scanner is handed for one file."""
    if not fpath.endswith((".json", ".jsonl", ".ndjson")):
        return [text]
    objs = []
    for line in (text.splitlines() if fpath.endswith((".jsonl", ".ndjson")) else [text]):
        if line.strip():
            try:
                objs.append(json.loads(line))
            except ValueError:
                objs.append(line)
    if rel not in NAMES_ONLY_FILES:
        return objs
    out = []
    for o in objs:
        reshaped = _names_only(rel, o)
        out.append(o if reshaped is None else reshaped)
    out.append(text)      # the pattern rules read the file as written as well as as parsed
    return out


def _mask_signature(rel, text, author, reviewer):
    """`review.reviewer` is the signature §4.5 asks for, so the author's own name there is not
    a finding. Masked at equal length, so the lines the check does report still point at the
    file, and a second occurrence of the name anywhere in `fixture.json` still warns. A
    warning that fires on every run is a warning nobody reads.
    """
    if rel != "fixture.json" or not author or reviewer != author:
        return text
    return text.replace(json.dumps(author), '"%s"' % ("x" * len(author)), 1)


def _scan_files(path, meta, home, author, hostname):
    errors, warnings = [], []
    reviewer = (meta.get("review") or {}).get("reviewer")
    for fpath in _walk_files(path):
        rel = os.path.relpath(fpath, path)
        try:
            text = _read_text(fpath)
        except UnicodeDecodeError:
            # A file the scanners cannot read is a file the reviewer cannot read either.
            # `snapshot` and `collect_artifacts` stub undecodable content rather than store it,
            # so one reaching a fixture is a hole in the gate's coverage, not a file to skip
            # past.
            errors.append("%s: not UTF-8 text, so no redaction rule can be checked against it" % rel)
            continue
        except OSError as exc:
            errors.append("%s: unreadable (%s)" % (rel, exc.strerror))
            continue
        for o in _scan_objects(rel, fpath, text):
            for hit in redact.scan(o, home, hostname=hostname):
                errors.append("%s: %s" % (rel, hit))
        for w in redact.scan_report_only(_mask_signature(rel, text, author, reviewer), author, home):
            warnings.append("%s: %s" % (rel, w))
    return errors, warnings


def verify_fixture(path, home=None, author=None, hostname=None):
    home = home or os.path.expanduser("~")
    # The scanner can only scrub a pattern it holds, so rule 3's hostname half needs one named
    # here; the local host is right on the recording machine and a cross-machine review passes
    # the recording hostname explicitly (spec Revision Note, 2026-09-04).
    hostname = hostname or socket.gethostname()
    missing = _check_present(path)
    if missing:
        return missing, []
    fx = fixture.load(path)
    errors = _check_meta(path, fx["meta"])
    errors += _check_frames(fx["frames"])
    errors += _lifecycle(fx["frames"], set(fx["meta"].get("late_responses") or []))
    errors += _check_census(fx)
    errors += _check_artifacts(path, fx["frames"])
    errors += _check_mirror(path, fx)
    errors += _check_streams(path, fx)
    scan_errors, warnings = _scan_files(path, fx["meta"], home, author, hostname)
    return errors + scan_errors, warnings
