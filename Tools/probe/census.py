"""Frame census: a set-based fingerprint of a stream-json session (spec §4.4)."""
import re

FLAG_RE = re.compile(r"(?m)^\s+(?:-[A-Za-z],\s+)?(--[a-z][a-z0-9-]*)")


def flags_from_help(text):
    """Sorted, de-duplicated long flags from `claude --help` output."""
    return sorted(set(FLAG_RE.findall(text or "")))


def request_subtypes(frames):
    """request_id -> request subtype, from control_request frames in either direction."""
    out = {}
    for f in frames:
        if f.get("type") == "control_request":
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
    """The discriminated payload one level down (spec §4.4)."""
    t = frame.get("type")
    if t == "control_request":
        return frame.get("request") or {}
    if t == "control_response":
        r = (frame.get("response") or {}).get("response")
        return r if isinstance(r, dict) else {}
    if t in ("assistant", "user"):
        return frame.get("message") or {}
    return None


def _block_types(frame):
    if frame.get("type") not in ("assistant", "user"):
        return None
    content = (frame.get("message") or {}).get("content")
    if not isinstance(content, list):
        return []
    return sorted({b.get("type") for b in content if isinstance(b, dict) and b.get("type")})


def census(frames, help_text=None, version=None):
    rs = request_subtypes(frames)
    pairs = {}
    capabilities = None
    for f in frames:
        if not isinstance(f, dict) or "type" not in f or f.get("type") == "keep_alive":
            continue                      # keep_alive carries nothing and its timing varies run to run
        pair = pair_of(f, rs)
        entry = pairs.setdefault(pair, {"count": 0, "_keys": [], "_pkeys": [], "_blocks": set()})
        entry["count"] += 1
        entry["_keys"].append(set(f.keys()))
        payload = _payload(f)
        if payload is not None:
            entry["_pkeys"].append(set(payload.keys()))
        blocks = _block_types(f)
        if blocks is not None:
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
        if e["_blocks"] or pair.split("/")[0] in ("assistant", "user"):
            rec["block_types"] = sorted(e["_blocks"])
        out_pairs[pair] = rec
    return {
        "version": version,
        "flags": flags_from_help(help_text) if help_text else [],
        "capabilities": capabilities,
        "pairs": out_pairs,
    }


def merge_required(previous, current):
    """Accumulate across re-recordings: keys = union, required = intersection, counts summed."""
    if not previous:
        return current
    out = {"version": current.get("version") or previous.get("version"),
           "flags": current.get("flags") or previous.get("flags"),
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
    """Human-readable drift lines; empty means no drift. mode: 'exact' | 'required'."""
    lines = []
    rp, op = recorded["pairs"], observed["pairs"]
    for pair in sorted(set(op) - set(rp)):
        lines.append("added pair %s" % pair)
    for pair in sorted(set(rp) - set(op)):
        lines.append("removed pair %s" % pair)
    for pair in sorted(set(rp) & set(op)):
        r, o = rp[pair], op[pair]
        if mode == "exact":
            _set_diff(pair, "keys ", r["keys"], o["keys"], lines)
            _set_diff(pair, "payload keys ", r.get("payload_keys"), o.get("payload_keys"), lines)
            _set_diff(pair, "block types ", r.get("block_types"), o.get("block_types"), lines)
        else:
            missing = sorted(set(r["required_keys"]) - set(o["keys"]))
            if missing:
                lines.append("%s: removed required keys %s" % (pair, " ".join(missing)))
            pmissing = sorted(set(r.get("required_payload_keys", [])) - set(o.get("payload_keys", [])))
            if pmissing:
                lines.append("%s: removed required payload keys %s" % (pair, " ".join(pmissing)))
    _set_diff("capabilities", "", recorded.get("capabilities"), observed.get("capabilities"), lines)
    _set_diff("flags", "", recorded.get("flags"), observed.get("flags"), lines)
    return lines
