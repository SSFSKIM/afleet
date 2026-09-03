"""Frame census: a set-based fingerprint of a stream-json session (spec §4.4)."""
import re

# A flag declaration is indented exactly two spaces and opens with the alias run: one or
# more short or long flags separated by commas. Anything after the run -- a value
# placeholder, the description -- is not part of it.
DECLARATION_RE = re.compile(r"^ {2}(-{1,2}[A-Za-z][A-Za-z0-9-]*(?:,\s*-{1,2}[A-Za-z][A-Za-z0-9-]*)*)")
LONG_FLAG_RE = re.compile(r"--[A-Za-z][A-Za-z0-9-]*")


def flags_from_help(text):
    """Sorted, de-duplicated long flags *declared* in `claude --help` (spec §4.4).

    The two-space indentation anchor is load-bearing. Declarations sit at exactly two
    spaces; wrapped description text sits at the description column (40 on 2.1.259), so
    the anchor is the only thing keeping a flag merely *mentioned* in prose out of the
    census. On 2.1.259 `--permission-prompt-tool` appears nowhere but inside the
    description of `--permission-prompts` ("the SDK host or --permission-prompt-tool"),
    and an unanchored parse would fingerprint it as a flag the CLI does not declare.

    A declaration may list several comma-separated aliases and may lead with a short
    flag: `-p, --print`, `--bg, --background`, `--allowedTools, --allowed-tools
    <tools...>`. Every long alias in the run is recorded, camelCase included -- matching
    only a lowercase prefix would invent `--allowed` out of `--allowedTools`.
    """
    flags = set()
    for line in (text or "").splitlines():
        declaration = DECLARATION_RE.match(line)
        if declaration:
            flags.update(LONG_FLAG_RE.findall(declaration.group(1)))
    return sorted(flags)


def request_subtypes(frames):
    """request_id -> request subtype, from control_request frames in either direction."""
    out = {}
    for f in frames:
        if isinstance(f, dict) and f.get("type") == "control_request":
            rid = f.get("request_id")
            sub = (f.get("request") or {}).get("subtype")
            if rid and sub:
                out[rid] = sub
    return out


def pair_of(frame, request_subtypes_map):
    t = frame.get("type")
    if t == "control_request":
        return "control_request/%s" % ((frame.get("request") or {}).get("subtype") or "?")
    if t == "control_response":
        rid = (frame.get("response") or {}).get("request_id")
        return "control_response/%s" % request_subtypes_map.get(rid, "?")
    sub = frame.get("subtype")
    return "%s/%s" % (t, sub) if sub else str(t)


def _payload(frame):
    """The discriminated payload one level down (spec §4.4): `request`, `response`, `message`.

    For a `control_response` this is the envelope, not the body it wraps. The envelope is
    what discriminates a success from an error -- `subtype` and `request_id` are always
    there, `response` appears on success and `error` on failure -- so fingerprinting the
    body here instead would make the two indistinguishable. The body has its own field;
    see `_body`.
    """
    t = frame.get("type")
    if t == "control_request":
        return frame.get("request") or {}
    if t == "control_response":
        return frame.get("response") or {}
    if t in ("assistant", "user"):
        return frame.get("message") or {}
    return None


def _body(frame):
    """A `control_response`'s inner body, or None when the frame carries none.

    None means absent, not empty. An error response has no body at all, and since the
    required sets are intersections, folding an absent body in as `{}` would permanently
    empty the recorded body shape and disarm the drift check for that pair.
    """
    if frame.get("type") != "control_response":
        return None
    body = (frame.get("response") or {}).get("response")
    return body if isinstance(body, dict) else None


def _block_types(frame):
    if frame.get("type") not in ("assistant", "user"):
        return None
    content = (frame.get("message") or {}).get("content")
    if not isinstance(content, list):
        return []
    return sorted({b.get("type") for b in content if isinstance(b, dict) and b.get("type")})


def census(frames, *, help_text=None, version=None):
    rs = request_subtypes(frames)
    pairs = {}
    capabilities = None
    for f in frames:
        if not isinstance(f, dict) or "type" not in f or f.get("type") == "keep_alive":
            continue                      # keep_alive carries nothing and its timing varies run to run
        pair = pair_of(f, rs)
        entry = pairs.setdefault(pair, {"count": 0, "_keys": [], "_pkeys": [], "_bkeys": [], "_blocks": None})
        entry["count"] += 1
        entry["_keys"].append(set(f.keys()))
        payload = _payload(f)
        if payload is not None:
            entry["_pkeys"].append(set(payload.keys()))
        body = _body(f)
        if body is not None:
            entry["_bkeys"].append(set(body.keys()))
        blocks = _block_types(f)
        if blocks is not None:
            if entry["_blocks"] is None:
                entry["_blocks"] = set()
            entry["_blocks"].update(blocks)
        if f.get("type") == "system" and f.get("subtype") == "init" and "capabilities" in f:
            capabilities = sorted(f["capabilities"]) if isinstance(f["capabilities"], list) else f["capabilities"]
    out_pairs = {}
    for pair, e in pairs.items():
        keys_union = sorted(set().union(*e["_keys"])) if e["_keys"] else []
        keys_req = sorted(set.intersection(*e["_keys"])) if e["_keys"] else []
        rec = {"count": e["count"], "keys": keys_union, "required_keys": keys_req}
        if e["_pkeys"]:
            rec["payload_keys"] = sorted(set().union(*e["_pkeys"]))
            rec["required_payload_keys"] = sorted(set.intersection(*e["_pkeys"]))
        if e["_bkeys"]:      # omitted entirely when no frame of the pair carried a body
            rec["body_keys"] = sorted(set().union(*e["_bkeys"]))
            rec["required_body_keys"] = sorted(set.intersection(*e["_bkeys"]))
        if e["_blocks"] is not None:
            rec["block_types"] = sorted(e["_blocks"])
        out_pairs[pair] = rec
    return {
        "version": version,
        # None means the help was never captured; [] means it was and declared nothing.
        "flags": flags_from_help(help_text) if help_text is not None else None,
        "capabilities": capabilities,
        "pairs": out_pairs,
    }


def merge_required(previous, current):
    """Accumulate across re-recordings: keys = union, required = intersection, counts summed."""
    if not previous:
        return current
    # flags uses `is not None`, not `or`: a run whose `claude --help` came back empty must
    # record the empty list so later diffs alarm, not silently inherit the previous list.
    out = {"version": current.get("version") or previous.get("version"),
           "flags": current.get("flags") if current.get("flags") is not None else previous.get("flags"),
           "capabilities": current.get("capabilities") if current.get("capabilities") is not None else previous.get("capabilities"),
           "pairs": {}}
    names = set(previous["pairs"]) | set(current["pairs"])
    for n in names:
        a, b = previous["pairs"].get(n), current["pairs"].get(n)
        if a is None or b is None:
            out["pairs"][n] = dict(a or b)
            continue
        rec = {"count": a["count"] + b["count"],
               "keys": sorted(set(a["keys"]) | set(b["keys"])),
               "required_keys": sorted(set(a["required_keys"]) & set(b["required_keys"]))}
        if "payload_keys" in a or "payload_keys" in b:
            rec["payload_keys"] = sorted(set(a.get("payload_keys", [])) | set(b.get("payload_keys", [])))
            rec["required_payload_keys"] = sorted(set(a.get("required_payload_keys", [])) & set(b.get("required_payload_keys", [])))
        # A side with no body carries no evidence about the body's shape, so it is skipped
        # rather than intersected away -- the same reason `_body` distinguishes absent from
        # empty. Intersecting against a missing side would let one error-only re-recording
        # empty the required body shape for good.
        with_body = [s for s in (a, b) if "body_keys" in s]
        if with_body:
            rec["body_keys"] = sorted(set().union(*[set(s["body_keys"]) for s in with_body]))
            rec["required_body_keys"] = sorted(set.intersection(*[set(s["required_body_keys"]) for s in with_body]))
        if "block_types" in a or "block_types" in b:
            rec["block_types"] = sorted(set(a.get("block_types", [])) | set(b.get("block_types", [])))
        out["pairs"][n] = rec
    return out


def _set_diff(prefix, what, before, after, lines):
    before, after = set(before or []), set(after or [])
    removed, added = sorted(before - after), sorted(after - before)
    if removed:
        lines.append("%s: removed %s%s" % (prefix, what, " ".join(removed)))
    if added:
        lines.append("%s: added %s%s" % (prefix, what, " ".join(added)))


def diff(recorded, observed, mode):
    """Human-readable drift lines; empty means no drift. mode: 'exact' | 'required'.

    An unknown mode raises rather than defaulting: the two modes are a strict and a
    permissive gate, and later callers derive this argument from fixture metadata, where
    a wrong value would silently downgrade the strict gate to the permissive one.
    """
    if mode not in ("exact", "required"):
        raise ValueError("unknown census diff mode %r; expected 'exact' or 'required'" % (mode,))
    lines = []
    rp, op = recorded["pairs"], observed["pairs"]
    for pair in sorted(set(op) - set(rp)):
        lines.append("added pair %s" % pair)
    for pair in sorted(set(rp) - set(op)):
        lines.append("removed pair %s" % pair)
    for pair in sorted(set(rp) & set(op)):
        r, o = rp[pair], op[pair]
        if mode == "exact":
            # Exact mode compares the required sets too. A key that goes from always
            # present to sometimes present leaves the union untouched, so reading only
            # the union would let that drift through the strict gate unremarked.
            _set_diff(pair, "keys ", r["keys"], o["keys"], lines)
            _set_diff(pair, "required keys ", r["required_keys"], o["required_keys"], lines)
            _set_diff(pair, "payload keys ", r.get("payload_keys"), o.get("payload_keys"), lines)
            _set_diff(pair, "required payload keys ", r.get("required_payload_keys"), o.get("required_payload_keys"), lines)
            _set_diff(pair, "body keys ", r.get("body_keys"), o.get("body_keys"), lines)
            _set_diff(pair, "required body keys ", r.get("required_body_keys"), o.get("required_body_keys"), lines)
            _set_diff(pair, "block types ", r.get("block_types"), o.get("block_types"), lines)
        else:
            missing = sorted(set(r["required_keys"]) - set(o["keys"]))
            if missing:
                lines.append("%s: removed required keys %s" % (pair, " ".join(missing)))
            pmissing = sorted(set(r.get("required_payload_keys", [])) - set(o.get("payload_keys", [])))
            if pmissing:
                lines.append("%s: removed required payload keys %s" % (pair, " ".join(pmissing)))
            bmissing = sorted(set(r.get("required_body_keys", [])) - set(o.get("body_keys", [])))
            if bmissing:
                lines.append("%s: removed required body keys %s" % (pair, " ".join(bmissing)))
    _set_diff("capabilities", "", recorded.get("capabilities"), observed.get("capabilities"), lines)
    _set_diff("flags", "", recorded.get("flags"), observed.get("flags"), lines)
    return lines
