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

# The version of `Fixtures/REVIEW.md` a signature attests to. Bump it whenever that file gains
# or changes an item, because a block recording an older version says the reviewer walked a
# shorter list than the one now in the repository -- which is the one thing the field is for.
# `verify` checks the key is present and truthy, not that it is current: an old fixture is not
# invalid, it is one whose signature a re-review can be judged against.
CHECKLIST_VERSION = 2

# §4.4's `fixture.json` enumeration, plus `deterministic`, which the same section's census
# paragraph names in prose. Required by presence and not by value: a missing `deterministic`
# reads as false and silently picks the permissive census comparison over the strict one,
# which is precisely the downgrade `census.diff` refuses to allow at its own boundary. A
# recorded fixture gets these from `record`; a hand-written synthetic one is where the
# omission is real.
REQUIRED_META = ("name", "purpose", "recorded_at", "cli_version", "launch", "prompts", "serves",
                 "census", "deterministic", "synthetic", "hypothesis", "late_responses",
                 "withdrawn_requests", "review")

# The four §4.4 fields whose *value* is a flag. Presence is the wrong instrument for these:
# `"deterministic": null` is present, reads as false, and silently picks the permissive census
# comparison over the strict one -- the same downgrade a missing field makes, one step further
# along. `record` writes `bool(...)`, so only a hand-written fixture reaches here, which is the
# population this check exists for.
BOOLEAN_META = ("census", "deterministic", "synthetic", "hypothesis")

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

def _lifecycle(frames, late_ok, withdrawn_ok=()):
    errors = []
    state = {}      # rid -> (origin, status); origin in {"cli","host"}, status in {"open","closed","cancelled","withdrawn","dropped"}
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
            if rid in state:
                # The second request takes the id's state entry, so the first one's outcome
                # stops being checked. That is the remaining way an unanswered request leaves
                # the gate unremarked.
                errors.append("request id %s is opened twice; the earlier lifecycle cannot be checked" % rid)
            state[rid] = (origin, "open"); subtype[rid] = (f.get("request") or {}).get("subtype")
            opened_at[rid] = i
        elif t == "control_response":
            rid = (f.get("response") or {}).get("request_id")
            origin, status = state.get(rid, (None, None))
            if origin is None:
                errors.append("response to unknown request %s" % rid)
            elif d == ("out" if origin == "cli" else "in"):
                # The `--replay-user-messages` echo, not an answer. That flag makes the CLI
                # re-emit every `control_response` the host sends straight back on stdout
                # (2.1.258 `cli.pretty.js`: the stdin loop's `control_response` branch is
                # `if (C.replayUserMessages) bt.enqueue(d)`), so a CLI-originated request
                # shows the host's answer travelling in and the same body travelling back
                # out milliseconds later. The parent's §6.1 launch line always carries the
                # flag, so every recording made here contains these; read as answers they
                # were counted a second time and reported as duplicates.
                #
                # A response travelling the same way as the request it names can only be an
                # echo: the answer is by definition the other direction, which is the branch
                # below. Skipping loses no strictness -- two genuine answers still collide on
                # `closed`, in either direction -- and it is why the "wrong direction" error
                # this replaces is gone rather than merely bypassed.
                continue
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
                # "open" and "withdrawn" both land here. A response to a withdrawn request is
                # an ordinary settlement, not the exception `late_responses` exists to license:
                # the CLI honours a host cancel for only three subtypes and answers anyway even
                # for those, so a host request always ends in a response and the cancel merely
                # says the host stopped waiting.
                state[rid] = (origin, "closed")
        elif t == "control_cancel_request":
            rid = f.get("request_id")
            origin, status = state.get(rid, (None, None))
            if origin is None:
                errors.append("cancel for unknown request %s" % rid)
            elif origin == "host" and d == "in" and rid in withdrawn_ok:
                # A declared withdrawal: the host cancelled its own request and `fixture.json`
                # says so. All three halves are required -- host-originated, a host-to-CLI
                # cancel frame carrying the id, and the id listed -- so the entry cannot excuse
                # a request the fixture does not actually show being withdrawn. The list is
                # written from a scenario's explicit cancel path and never inferred from the
                # frames, which is what keeps it a declaration rather than a blanket amnesty.
                if status == "open":
                    state[rid] = (origin, "withdrawn")
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
                # a fixture defect to work around. The one declared escape is
                # `withdrawn_requests` above, which a scenario opts into per request id.
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
    errors += ["fixture.json %s must be true or false (spec §4.4)" % k
               for k in BOOLEAN_META if k in meta and not isinstance(meta[k], bool)]
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


def _evidence_from_this_run(recorded, recount):
    """An accumulated census restricted to what the latest run holds evidence about.

    §4.4 accumulates a model-driven scenario's census across re-recordings, while
    `frames.ndjson` holds only the newest run, so `census.json` legitimately describes pairs
    and body shapes those frames do not contain. §4.4's removed-pair alarm is about a binary
    that stopped producing a pair, which is `diff`'s comparison against a fresh live run --
    a different question from this one, which only asks whether a census describes its own
    file. Reading the accumulation as drift would fail every re-recording, and only ever the
    second one, after the live sessions have been paid for.

    Dropping what this run says nothing about leaves the direction the recount exists for
    untouched: `diff` reads the observed side for added pairs and for the key sets a required
    set is checked against, so a census that under-describes its own frames still fails.
    """
    pairs = {}
    for name, rec in recorded["pairs"].items():
        observed = recount["pairs"].get(name)
        if observed is None:
            continue                      # a pair only an earlier recording produced
        if "body_keys" not in observed:
            # `merge_required`'s own rule read from the other side: a run that carried no body
            # for a pair holds no evidence about that body's shape, so it neither confirms nor
            # contradicts what an earlier run recorded. Without this an accumulated body
            # survives a run of nothing but error responses and is reported as removed.
            rec = {k: v for k, v in rec.items() if k not in ("body_keys", "required_body_keys")}
        pairs[name] = rec
    return dict(recorded, pairs=pairs)


def _check_census(fx):
    """`census.json` against `frames.ndjson`, for every fixture including a synthetic one.

    Both sides live inside the fixture, so this needs no binary and says the same thing about
    a hand-written fixture as about a recorded one -- and a hand-written census is exactly the
    one that nothing else in the pipeline has ever read.
    """
    meta, recorded = fx["meta"], fx["census"]
    if not isinstance(recorded, dict) or not isinstance(recorded.get("pairs"), dict):
        # The recount reads every fixture's census now, and a hand-written one is where a
        # mis-shaped file actually turns up. Without this the comparison raises and the gate
        # reports nothing at all, which is the one outcome worse than a finding.
        return ["census.json is not a census object with a pairs map"]
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
    # Exact mode is left alone. `record` merges only when `deterministic` is false, so a
    # deterministic fixture's census never accumulates and a pair or a body it holds that its
    # own frames do not is real drift.
    mode = "exact" if meta.get("deterministic") else "required"
    expected = recorded if mode == "exact" else _evidence_from_this_run(recorded, recount)
    try:
        drift = census.diff(expected, recount, mode)
    except (KeyError, TypeError, AttributeError):
        # A pair record of the wrong shape, which the top-level guard above cannot see.
        return errors + ["census.json has a pair record the comparison cannot read"]
    if drift:
        errors.append("census.json does not match a recount: %s" % "; ".join(drift))
    return errors


def _tokens_in_strings(obj, into):
    """Every `<artifacts>/…` path the decoded strings of `obj` name.

    A decoded string names an artifact only when the whole string is the token, so the test is
    `startswith` and the remainder is taken whole. Both halves earn their place against a false
    missing-artifact failure, and a gate that cries wolf is a gate reviewers learn to override:
    reading from the prefix inwards would swallow the rest of a sentence in a `result` frame
    that merely mentions a path, and stopping at the first space would break a path containing
    one.
    """
    prefix = fixture.ARTIFACT_TOKEN + "/"
    for s in fixture._strings(obj):
        if s.startswith(prefix) and len(s) > len(prefix):
            into.add(s[len(prefix):])


def _tokens_in_raw_line(line, into):
    """The fallback for a record that is not JSON, which has no string boundaries to read. A
    token would have ended at its closing quote had the line parsed, so that is where it ends
    here."""
    for part in line.split(fixture.ARTIFACT_TOKEN + "/")[1:]:
        token = part.split('"')[0].split("'")[0].strip()
        if token:
            into.add(token)


def _check_artifacts(path, frames):
    needed = set()
    for rec in frames:
        _tokens_in_strings(rec, needed)
    # `initial/` as well as `transcript/`: a resume fixture's `initial/` holds a prior
    # session's records, and those name artifacts a replay has to resolve too.
    for sub in ("initial", "transcript"):
        for fpath in _walk_files(os.path.join(path, sub)):
            with open(fpath, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if fixture.ARTIFACT_TOKEN not in line:
                        continue
                    try:
                        _tokens_in_strings(json.loads(line), needed)
                    except ValueError:
                        _tokens_in_raw_line(line, needed)
    art_dir = os.path.join(path, "artifacts")
    return ["artifacts/%s named by a frame or record is missing" % rel
            for rel in sorted(needed) if not os.path.isfile(os.path.join(art_dir, rel))]


def _check_mirror(path, fx):
    """Mirrored entries reproduce the transcript: `initial/` records plus every mirrored
    entry, in order, are the `transcript/` records.

    Gated on whether the fixture declares a transcript at all, which is what the check actually
    needs, rather than on `synthetic`, which was only ever a proxy for it. A fixture written
    from schemas may legitimately have nothing under `transcript/`; one that does populate it is
    held to its mirror frames whether it was recorded or written by hand.
    """
    meta, frames = fx["meta"], fx["frames"]
    final = fixture.stream_sizes(os.path.join(path, "transcript"))
    if not final:
        return []
    errors = []
    rec_slug = fixture.slug_of(meta["cwd"]) if meta.get("cwd") else None
    # A session file can be named by more than one path over one recording. `set_cwd` with
    # trust answers `transcript_relocated: true` and *moves* the transcript into the new
    # project slug, so the mirror names the old path before the relocation and the new one
    # after it, while `snapshot` finds one file at whichever path it ended at. Keyed by path
    # alone the entries split into two streams, one of which the fixture cannot hold. The file
    # is what has an identity here, not the path, and within one session's transcript
    # directory the file name carries it: the main stream is `<session>.jsonl` and each
    # sidecar has a name of its own, so no two distinct streams collide. Ambiguity falls back
    # to the path, which reports the missing stream exactly as before.
    by_name = {}
    for stream in final:
        by_name.setdefault(os.path.basename(stream), []).append(stream)
    mirrored = {}
    for rec in frames:
        f = rec.get("frame") or {}
        if f.get("type") == "transcript_mirror" and "/projects/" in f.get("filePath", ""):
            stream = f["filePath"].split("/projects/", 1)[1]
            if rec_slug:
                stream = stream.replace(rec_slug, fixture.SLUG_TOKEN, 1)
            if stream not in final:
                same_name = by_name.get(os.path.basename(stream)) or []
                if len(same_name) == 1:
                    stream = same_name[0]
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
    errors += _lifecycle(fx["frames"], set(fx["meta"].get("late_responses") or []),
                         set(fx["meta"].get("withdrawn_requests") or []))
    errors += _check_census(fx)
    errors += _check_artifacts(path, fx["frames"])
    errors += _check_mirror(path, fx)
    errors += _check_streams(path, fx)
    scan_errors, warnings = _scan_files(path, fx["meta"], home, author, hostname)
    return errors + scan_errors, warnings
