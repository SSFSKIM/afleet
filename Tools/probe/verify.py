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
import hashlib
import json
import os
import socket
import stat

import census
import fixture
import redact

REVIEW_KEYS = ("reviewer", "date", "checklist_version")
# The fourth field of a signed review block, checked separately from the three above so the
# "not signed" finding keeps its exact wording -- `probe.record` matches that string by
# equality to tell a fresh recording's missing signature from every other error.
DIGEST_KEY = "tree_sha256"

# The version of `Fixtures/REVIEW.md` a signature attests to. Bump it whenever that file gains
# or changes an item, because a block recording an older version says the reviewer walked a
# shorter list than the one now in the repository -- which is the one thing the field is for.
# `verify` requires the recorded version to equal this one exactly. A block claiming an older
# version says in as many words that its reviewer walked a shorter list than the repository
# now holds, and a gate that accepts that statement is not asking the question the field
# exists to ask; the repair is to re-walk and sign again, which costs nothing but reading.
CHECKLIST_VERSION = 3

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
    # A host request the harness recorded and never managed to write. `Session._send_locked`
    # records and writes as one step while holding the write lock -- which is what keeps
    # capture order and wire order the same -- so a child that exits between the two leaves a
    # frame in the capture that never reached the wire, and the harness catches that write
    # failure and marks that exact record `unwritten`.
    #
    # Only the annotation is honoured. This used to be inferred from position -- the last
    # record being an inbound `control_request` was taken as proof it missed the wire -- which
    # asserted nothing: a truncated or crashed recording ending with a request the host really
    # did send has the same shape and passed the lifecycle check unremarked.
    # Collected only from records travelling `in`, and honoured below only for a request whose
    # recorded origin is `host`. The harness sets the mark nowhere else -- it can only fail
    # writing a frame the host is sending -- so both halves are what the annotation already
    # means; stating them here is what stops a mark on an outbound record from excusing a
    # CLI-originated request the host simply never answered.
    unwritten = {(rec.get("frame") or {}).get("request_id")
                 for rec in frames if rec.get("unwritten") and rec.get("dir") == "in"}
    unwritten.discard(None)
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
        if origin == "host" and rid in unwritten:
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


def tree_digest(path):
    """SHA-256 over the whole fixture tree: sorted relative paths and the bytes at them.

    What binds a signature to what it signs. Without it the review block asserted three truthy
    strings about nothing: any frame, transcript record, artifact, census or manifest could be
    edited after review and the old block went on passing -- which is worse than no gate,
    because it reads as a reviewer having seen the bytes in front of you.

    Three properties it needs and one it must not have. The path goes into the hash beside the
    bytes, so moving or renaming a file is a change; the length goes in too, so no pair of
    files can be concatenated into another pair; and the walk is the whole tree, README and
    `.gitkeep` included, because REVIEW item 8 has the reviewer read the README against the
    recording and item 9 has them look for the placeholder. What it must not cover is the
    review block itself, which would otherwise have to contain its own digest: `fixture.json`
    is hashed as its metadata *minus* `review`, re-serialised canonically so the hash does not
    move with indentation.
    """
    h = hashlib.sha256()
    for rel in sorted(os.path.relpath(p, path) for p in _walk_files(path)):
        full = os.path.join(path, rel)
        if rel == "fixture.json":
            try:
                with open(full, encoding="utf-8") as fh:
                    meta = json.load(fh)
                body = json.dumps({k: v for k, v in meta.items() if k != "review"},
                                  sort_keys=True, separators=(",", ":")).encode("utf-8")
            except (ValueError, UnicodeDecodeError):
                # Unparseable metadata is somebody else's finding; hashing the raw bytes keeps
                # this function total rather than making a malformed fixture a traceback.
                with open(full, "rb") as fh:
                    body = fh.read()
        else:
            with open(full, "rb") as fh:
                body = fh.read()
        h.update(rel.encode("utf-8"))
        h.update(b"\0%d\0" % len(body))
        h.update(body)
    return h.hexdigest()


def _check_links(path):
    """No entry anywhere in a fixture tree may be a symlink or any other irregular file.

    The absolute half of the config-home rule read from the verifier's side. A tracked link
    beneath `transcript/` or `artifacts/` makes every tool that walks the fixture -- `redact`
    in place, `fake-claude`'s materialiser, a reviewer's own `grep -R` -- read and in one case
    write whatever it points at, which may be a repository file or a logged-in Claude
    configuration. It is also content the reviewer signs for without having seen, since what
    the link resolves to is not in the fixture. Findings are the relative path and the reason,
    which is fixture-relative by construction and safe to print.
    """
    out = []
    for root, dirs, files in os.walk(path):
        for name in sorted(dirs) + sorted(files):
            p = os.path.join(root, name)
            mode = os.lstat(p).st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                out.append("%s is a symlink or other irregular file; a fixture holds only regular files"
                           % os.path.relpath(p, path))
    return out


def _check_meta(path, meta):
    errors = ["fixture.json is missing %s (spec §4.4)" % k for k in REQUIRED_META if k not in meta]
    errors += ["fixture.json %s must be true or false (spec §4.4)" % k
               for k in BOOLEAN_META if k in meta and not isinstance(meta[k], bool)]
    if meta.get("name") != os.path.basename(os.path.normpath(path)):
        errors.append("fixture.json name %r does not match directory" % meta.get("name"))
    review = meta.get("review") or {}
    if not all(review.get(k) for k in REVIEW_KEYS):
        errors.append("review block is not signed (needs reviewer, date, checklist_version)")
    else:
        # Only once the block claims to be signed, so a freshly recorded fixture still reports
        # exactly one review error and `record` can go on treating it as advice.
        if review.get("checklist_version") != CHECKLIST_VERSION:
            errors.append("review block records checklist version %r, and Fixtures/REVIEW.md is at %d; "
                          "the fixture needs re-walking and re-signing"
                          % (review.get("checklist_version"), CHECKLIST_VERSION))
        if review.get(DIGEST_KEY) != tree_digest(path):
            errors.append("review block does not cover the fixture's current bytes (%s mismatch); "
                          "re-walk Fixtures/REVIEW.md and sign again" % DIGEST_KEY)
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


SIDECAR_ENTRY_TYPE = "agent_metadata"
SIDECAR_STREAM_MARKER = "subagents/"


def _is_sidecar_entry(entry):
    return isinstance(entry, dict) and entry.get("type") == SIDECAR_ENTRY_TYPE


def _check_sidecar_entries(path, stream, entries):
    """Every `agent_metadata` the mirror carried is the stream's `.meta.json`, field for field.

    The mirror delivers the sidecar on the transcript's channel with a `type` added, so the
    entry is not a record of that stream -- but it is a claim about a file the fixture holds,
    and the claim is checkable. Holding it against the sidecar is what keeps the entries out of
    the record comparison from being an amnesty.
    """
    sidecar = os.path.join(path, "transcript", stream[:-len(".jsonl")] + ".meta.json") \
        if stream.endswith(".jsonl") else None
    if not sidecar or not os.path.isfile(sidecar):
        return ["mirror carried %s for %s but no .meta.json sidecar is in the fixture"
                % (SIDECAR_ENTRY_TYPE, stream)]
    with open(sidecar, encoding="utf-8") as fh:
        try:
            want = json.load(fh)
        except ValueError:
            return ["transcript/%s is not valid JSON" % (stream[:-len(".jsonl")] + ".meta.json")]
    out = []
    for e in entries:
        got = dict(e)
        got.pop("type", None)
        if got != want:
            out.append("a mirrored %s for %s does not equal its .meta.json sidecar (differs on %s)"
                       % (SIDECAR_ENTRY_TYPE, stream,
                          ", ".join(sorted(k for k in set(got) | set(want) if got.get(k) != want.get(k)))))
    return out


def _identities(records):
    """A stream's record identities, in order. `uuid` is what a transcript record is keyed by;
    a record without one falls back to its own content, so a stream of unkeyed records is still
    compared in full and the fallback cannot be used to wave anything through."""
    return [r.get("uuid") if isinstance(r, dict) and r.get("uuid") else json.dumps(r, sort_keys=True)
            for r in records]


def _drift_fields(got, want):
    """The field names that differ between two identity-equal record sequences.

    One level of nesting is named, because the difference this reports lives inside `message`
    and a note saying only `message` tells a reviewer nothing they can check.
    """
    out = set()
    for a, b in zip(got, want):
        if a == b or not (isinstance(a, dict) and isinstance(b, dict)):
            continue
        for k in set(a) | set(b):
            if a.get(k) == b.get(k):
                continue
            va, vb = a.get(k), b.get(k)
            if isinstance(va, dict) and isinstance(vb, dict):
                out.update("%s.%s" % (k, sub) for sub in set(va) | set(vb) if va.get(sub) != vb.get(sub))
            else:
                out.add(k)
    return out


def _check_mirror(path, fx):
    """Mirrored entries reproduce the transcript: `initial/` records plus every mirrored
    entry, in order, are the `transcript/` records. Returns `(errors, notes)`.

    Gated on whether the fixture declares a transcript at all, which is what the check actually
    needs, rather than on `synthetic`, which was only ever a proxy for it. A fixture written
    from schemas may legitimately have nothing under `transcript/`; one that does populate it is
    held to its mirror frames whether it was recorded or written by hand.
    """
    meta, frames = fx["meta"], fx["frames"]
    final = fixture.stream_sizes(os.path.join(path, "transcript"))
    if not final:
        return [], []
    errors, notes = [], []
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
    # The declared escape of §4.4, in the shape `late_responses` and `withdrawn_requests`
    # already have: a count the *scenario* states, never one the recorder infers, so it stays a
    # claim about engine behaviour a reviewer signed for rather than an amnesty the tooling
    # grants itself. The engine writes a record it does not mirror at the head of a resumed
    # session's appended range -- `session-mirror-resume` records one `ai-title` -- and the
    # count is checked for exactness in both directions: too few consumed still fails, and a
    # declaration nothing needs is reported as stale rather than left to rot.
    #
    # There is no declaration in the other direction, because what the engine does there is not
    # a record of that stream at all. A subagent's mirror carries `agent_metadata` entries that
    # `subagents/agent-<id>.jsonl` never receives: each holds the neighbouring `.meta.json`
    # sidecar's content with a `type` added, and the engine emits one when the agent starts and
    # another each time an auto-turn re-engages it, so both their number and their position are
    # the model's to decide (`explore-depth-1`, `nested-depth-2`) and a declared count would rot
    # on the next recording. They are held out of the record comparison and *checked against the
    # sidecar they claim to be* instead, which makes this a second assertion rather than an
    # allowance: a fixture whose mirror announces metadata no `.meta.json` carries fails here.
    # The discriminator is the entry type and not a missing `uuid`, because plenty of ordinary
    # records -- `ai-title`, `atis-latch`, `file-history-snapshot`, `last-prompt`,
    # `queue-operation` -- carry no `uuid` and are written to the file like any other.
    #
    # `mirror_identity_only` is the second declaration and the only one that is not a count,
    # because what it licenses does not have a stable one. A subagent's sidecar file and its
    # mirror are two snapshots of the same record taken at different moments: the record that
    # closes an assistant message reaches the file with `stop_reason: null` and a partial
    # `usage` on some runs and finalised on others, and the file is never rewritten, so the two
    # disagree by field while agreeing by identity. *Whether* they disagree is a race and a
    # count of diverging records would rot on the next recording -- but *which fields* can
    # disagree is not a race, and is declared. So the declaration is a mapping from a stream
    # scope to the field paths that may differ inside it: identity, order and count stay
    # strict, every other field stays compared, and a genuinely corrupt agent mirror still
    # fails. §7.3 defines record identity as the logical stream plus record `uuid` or a stable
    # hash for uuid-less records, and its Decision Log rejects "whole-file equality as the
    # invariant" outright, so comparing by identity is the spec's own comparison and the
    # field-for-field equality this check used to apply was an addition on top of it.
    #
    # The scope is checked structurally as well as matched: a declaration is refused unless
    # every stream it matches is an agent sidecar. The match is a substring test, so a scope of
    # `.jsonl` or of the empty string would otherwise relax every stream in the fixture, which
    # is the one thing this declaration must never be able to do.
    declared = int(meta.get("unmirrored_prefix") or 0)
    identity_scopes = meta.get("mirror_identity_only") or {}
    if not isinstance(identity_scopes, dict):
        # A boundary check, not a defensive one: `fixture.json` is data read off disk, and the
        # earlier shape of this field was a bare list. A list would otherwise reach `dict()` and
        # fail the whole verification with a traceback naming neither the fixture nor the field.
        return errors + ["fixture.json mirror_identity_only must map a stream scope to the field "
                         "paths that may differ, not %s" % type(identity_scopes).__name__], notes
    used = set()
    skipped = 0
    for stream, entries in sorted(mirrored.items()):
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
        hit = [pat for pat in identity_scopes if pat in stream]
        used.update(hit)
        if hit and SIDECAR_STREAM_MARKER not in stream:
            errors.append("fixture.json declares mirror_identity_only %s, which matches %s -- not an agent "
                          "sidecar stream, the only kind the declaration is for"
                          % (", ".join(sorted(hit)), stream))
            hit = []
        allowed = set()
        for pat in hit:
            allowed.update(identity_scopes[pat] or ())
        keyed = [e for e in entries if not _is_sidecar_entry(e)]
        sidecars = [e for e in entries if _is_sidecar_entry(e)]
        if sidecars:
            errors += _check_sidecar_entries(path, stream, sidecars)
            notes.append("mirror carried %d %s entry/entries on %s, checked against its .meta.json "
                         "sidecar rather than against the stream"
                         % (len(sidecars), SIDECAR_ENTRY_TYPE, stream))
        if got == head + keyed:
            continue
        # Only ever at the head of the appended range, and only as many records as remain
        # undeclared: a gap anywhere later is a mirror that lost records mid-session, which is
        # the failure this check exists for.
        matched = False
        for n in range(1, declared - skipped + 1):
            if got == head + got[len(head):len(head) + n] + keyed:
                skipped += n
                matched = True
                break
        if not matched and hit and _identities(got) == _identities(head + keyed):
            matched = True                                  # identity holds; the fields decide the verdict
            drift = _drift_fields(got, head + keyed)
            undeclared = drift - allowed
            if undeclared:
                errors.append("mirror content drift on %s in field(s) mirror_identity_only does not declare: %s"
                              % (stream, ", ".join(sorted(undeclared))))
            elif drift:
                notes.append("mirror content drift on %s: %d of %d records differ from the file in %s; the "
                             "identity sequence is equal and every field is declared (mirror_identity_only)"
                             % (stream, sum(1 for a, b in zip(got, head + keyed) if a != b), len(got),
                                ", ".join(sorted(drift))))
        if not matched:
            errors.append("mirror entries for %s do not reproduce transcript/%s (%d mirrored, %d of them "
                          "sidecar metadata, + %d initial vs %d records, unmirrored_prefix %d)"
                          % (stream, stream, len(entries), len(sidecars), len(head), len(got), declared))
    if declared and skipped != declared:
        errors.append("fixture.json declares unmirrored_prefix %d but the mirror check needed %d" % (declared, skipped))
    for pat in sorted(set(identity_scopes) - used):
        errors.append("fixture.json declares mirror_identity_only %r but no mirrored stream matches it" % pat)
    return errors, notes


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

def _names_moved(obj):
    """Every key of a subtree moved into value position, recursively, values kept.

    The reshaping goes all the way down rather than one level, because the names these two
    files carry sit at more than one depth: a census pair record holds its protocol key sets
    under `keys`, `payload_keys` and `body_keys`, and a manifest holds a rule's field paths
    under the rule's own name -- `rules.secrets`. Both are names in key position, both match
    the secrets predicate, and neither is content. One level of reshaping moved the pair name
    and left the key sets underneath it, which the widened rule 2 then read as unredacted
    secret containers.

    Values survive intact and are still scanned; only the structural predicates, which ask
    "must this field's value be a placeholder?", are taken off a question that has no answer
    for a name.
    """
    if isinstance(obj, dict):
        return list(obj.keys()) + [_names_moved(v) for v in obj.values()]
    if isinstance(obj, list):
        return [_names_moved(v) for v in obj]
    return obj


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
        return dict(obj, pairs=_names_moved(pairs))
    if rel == "redaction.json":
        rules = obj.get("rules")
        if not isinstance(rules, dict):
            return None
        return dict(obj, rules=_names_moved(rules))
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
    links = _check_links(path)
    if links:
        # Returned alone rather than added to the rest: every check below this line opens the
        # files of the tree, and following a link out of the fixture is the thing the finding
        # says must not happen.
        return links, []
    fx = fixture.load(path)
    errors = _check_meta(path, fx["meta"])
    errors += _check_frames(fx["frames"])
    errors += _lifecycle(fx["frames"], set(fx["meta"].get("late_responses") or []),
                         set(fx["meta"].get("withdrawn_requests") or []))
    errors += _check_census(fx)
    errors += _check_artifacts(path, fx["frames"])
    mirror_errors, mirror_notes = _check_mirror(path, fx)
    errors += mirror_errors
    errors += _check_streams(path, fx)
    scan_errors, warnings = _scan_files(path, fx["meta"], home, author, hostname)
    return errors + scan_errors, mirror_notes + warnings
