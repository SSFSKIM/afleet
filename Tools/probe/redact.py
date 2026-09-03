"""Redaction rules (spec §4.5), applied structurally and in memory, with a manifest."""
import collections
import json
import os
import re
import socket

# The TLD quantifier is deliberately `+`, not `{2,}`: these rules are fail-closed, and a
# single-letter TLD that slips through reaches disk unredacted. Over-matching is harmless
# here (a version spec redacted to <email> in a synthetic fixture costs nothing).
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+")
SK_ANT_RE = re.compile(r"sk-ant-[A-Za-z0-9_\-]+")
JWT_RE = re.compile(r"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}")
QUERY_RUN_RE = re.compile(r"([?&][A-Za-z0-9_\-]+=)([A-Fa-f0-9]{32,}|[A-Za-z0-9+/=_\-]{32,})")
QUERY_RE = re.compile(r"\?.*$")
IDENTITY_KEYS = ("account", "organization", "user", "subscription_type")
SECRET_WORDS = ("token", "oauth", "key", "secret", "credential", "authorization", "cookie")
USAGE_COUNTERS = {"input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
                  "thinking_tokens", "max_tokens", "tokens", "total_tokens", "maxtokens", "rawmaxtokens"}
SECRET_EXEMPT = {"apikeysource", "hookcallbackids", "projectkey", "sessionkey"}
OAUTH_SUBTYPES = ("claude_authenticate", "claude_oauth_callback", "claude_oauth_wait_for_completion",
                  "mcp_authenticate", "mcp_oauth_callback_url")
MCP_LIMIT = 4096


def _is_secret_key(k):
    lk = k.lower()
    if lk in SECRET_EXEMPT or lk in USAGE_COUNTERS or lk.endswith("_tokens"):
        return False
    return any(w in lk for w in SECRET_WORDS)


class Redactor:
    def __init__(self, home=None, hostname=None, author=None):
        self.home = os.path.realpath(home or os.path.expanduser("~"))
        self.home_raw = home or os.path.expanduser("~")
        self.hostname = hostname or socket.gethostname()
        self.short_host = self.hostname.split(".")[0]
        self.author = author
        self.counts = collections.OrderedDict((r, {"count": 0, "paths": collections.Counter()})
                                              for r in ("identity", "secrets", "paths_host", "mcp_bodies", "settings_bodies", "oauth_flow"))

    # ---- bookkeeping
    def _hit(self, rule, path):
        self.counts[rule]["count"] += 1
        self.counts[rule]["paths"][path or "$"] += 1

    def manifest(self):
        return {"rules": {r: {"count": v["count"], "paths": dict(v["paths"])} for r, v in self.counts.items()}}

    # ---- text
    def redact_text(self, s, path=""):
        out = s
        out, k = EMAIL_RE.subn("<email>", out)
        if k: self._hit("identity", path)
        for rx in (SK_ANT_RE, JWT_RE):
            out, k = rx.subn("<redacted>", out)
            if k: self._hit("secrets", path)
        out, k = QUERY_RUN_RE.subn(lambda m: m.group(1) + "<redacted>", out)
        if k: self._hit("secrets", path)
        for h in (self.home, self.home_raw):
            if h and h != "/" and h in out:
                out = out.replace(h, "~"); self._hit("paths_host", path)
        for h in (self.hostname, self.short_host):
            if h and len(h) > 2 and h in out:
                out = out.replace(h, "<host>"); self._hit("paths_host", path)
        return out

    # ---- structural
    def redact_json(self, obj, request_subtype=None, path=""):
        if isinstance(obj, dict):
            out = {}
            for k, v in obj.items():
                p = "%s.%s" % (path, k) if path else k
                lk = k.lower()
                if k in IDENTITY_KEYS or lk.endswith("email") or lk == "email":
                    if v is not None and v != "<%s>" % k and v != "<email>":
                        out[k] = "<email>" if "email" in lk else "<%s>" % k
                        self._hit("identity", p)
                    else:
                        out[k] = v
                    continue
                if k == "apiKeySource":
                    if v not in ("none", "<apiKeySource>", None):
                        out[k] = "<apiKeySource>"; self._hit("identity", p)
                    else:
                        out[k] = v
                    continue
                if _is_secret_key(k) and (isinstance(v, str) or (isinstance(v, (dict, list)) and lk in ("oauth", "credentials", "credential"))):
                    if v != "<redacted>":
                        self._hit("secrets", p)
                    out[k] = "<redacted>"
                    continue
                out[k] = self.redact_json(v, request_subtype, p)
            return out
        if isinstance(obj, list):
            return [self.redact_json(v, request_subtype, "%s[%d]" % (path, i)) for i, v in enumerate(obj)]
        if isinstance(obj, str):
            return self.redact_text(obj, path)
        return obj

    # ---- frame-level rules (4, 5, 6 need the request subtype; 2's drop rule needs the frame)
    def _truncate_mcp(self, msg, path):
        if isinstance(msg, dict) and len(json.dumps(msg)) > MCP_LIMIT:
            kept = {k: msg[k] for k in ("jsonrpc", "id", "method") if k in msg}
            kept["truncated"] = len(json.dumps(msg))
            self._hit("mcp_bodies", path)
            return kept
        return msg

    def redact_frame(self, frame, direction, request_subtypes):
        t = frame.get("type")
        if t == "control_request":
            sub = (frame.get("request") or {}).get("subtype")
            if sub == "update_environment_variables":
                self._hit("secrets", "request")
                return None
            f = dict(frame)
            if sub == "mcp_message":
                req = dict(f["request"]); req["message"] = self._truncate_mcp(req.get("message"), "request.message"); f["request"] = req
            return self.redact_json(f)
        if t == "control_response":
            rid = (frame.get("response") or {}).get("request_id")
            sub = request_subtypes.get(rid)
            f = json.loads(json.dumps(frame))
            body = (f.get("response") or {}).get("response")
            if isinstance(body, dict):
                if sub == "mcp_message" and "mcp_response" in body:
                    body["mcp_response"] = self._truncate_mcp(body["mcp_response"], "response.mcp_response")
                if sub == "get_settings":
                    if "effective" in body:
                        body["effective_keys"] = sorted(body.pop("effective").keys()) if isinstance(body.get("effective"), dict) else []
                        self._hit("settings_bodies", "response.effective")
                    if "sources" in body:
                        srcs = body.pop("sources")
                        body["sources_keys"] = [{"source": s.get("source"), "keys": sorted((s.get("settings") or {}).keys())}
                                                for s in srcs if isinstance(s, dict)]
                        self._hit("settings_bodies", "response.sources")
                if sub in OAUTH_SUBTYPES:
                    for k, v in list(body.items()):
                        if isinstance(v, str) and "?" in v and v.startswith("http"):
                            body[k] = QUERY_RE.sub("?<redacted>", v); self._hit("oauth_flow", "response.%s" % k)
            return self.redact_json(f)
        return self.redact_json(frame)


def scan(obj_or_text, home):
    """Hard failures: anything a redaction rule would still change."""
    hits = []
    probe = Redactor(home=home, hostname="\x00nohost\x00")
    def walk(o, path):
        if isinstance(o, dict):
            for k, v in o.items():
                p = "%s.%s" % (path, k) if path else k
                if (k in IDENTITY_KEYS or k.lower().endswith("email")) and v not in (None, "<email>", "<%s>" % k):
                    hits.append("%s: identity field not redacted" % p)
                elif _is_secret_key(k) and isinstance(v, str) and v != "<redacted>":
                    hits.append("%s: secret-named field not redacted" % p)
                else:
                    walk(v, p)
        elif isinstance(o, list):
            for i, v in enumerate(o):
                walk(v, "%s[%d]" % (path, i))
        elif isinstance(o, str):
            if EMAIL_RE.search(o): hits.append("%s: email" % path)
            if SK_ANT_RE.search(o) or JWT_RE.search(o) or QUERY_RUN_RE.search(o): hits.append("%s: secret pattern" % path)
            if probe.home in o or probe.home_raw in o: hits.append("%s: home directory" % path)
    walk(obj_or_text, "")
    return hits


def scan_report_only(text, author, home):
    hits = []
    if author and author in text:
        hits.append("author name appears: %s" % author)
    for m in re.finditer(r"/Users/[A-Za-z0-9._-]+", text):
        if not m.group(0).startswith(home):
            hits.append("path under /Users: %s" % m.group(0))
    return hits
