"""Redaction rules (spec §4.5), applied structurally and in memory, with a manifest.

Two properties hold this module together and both are load-bearing for the child:

*Fail closed.* Where a rule cannot tell whether something is sensitive, it redacts.
Over-redacting a synthetic fixture costs a reviewer a moment of confusion; under-redacting
writes a real secret to a committed file.

*One predicate, two consumers.* `scan` reuses this module's own predicates, so wherever
the redactor is blind `verify` is blind to the same thing and the leak is undetectable by
the tooling. Widen a predicate and both halves widen together; never fork them.

*Findings are safe to persist.* Every string `scan` and `scan_report_only` return names the
rule that fired and the position it fired at, never the material that triggered it, so a
caller may print findings and may equally write them to a log or a report. `scan` gets this
by construction: it only reports what the redactor's own rules would change, so running
those rules over the finding is guaranteed to neutralise it. `scan_report_only` cannot use
that argument -- report-only findings are by definition material the redactor does not
touch -- so it names its findings instead of echoing them. A later edit that quotes an input
into a finding silently breaks this; the two `..._never_quote_what_they_found` tests guard
it.
"""
import collections
import json
import os
import re
import socket

# The TLD quantifier is deliberately `+`, not `{2,}`: these rules are fail-closed, and a
# single-letter TLD that slips through reaches disk unredacted. Over-matching is harmless
# here (a version spec like `pkg@1.x` redacted to <email> in a synthetic fixture costs
# nothing) and is pinned by a test so a fixture reviewer is not surprised by it.
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+")
SK_ANT_RE = re.compile(r"sk-ant-[A-Za-z0-9_\-]+")
JWT_RE = re.compile(r"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}")
QUERY_RUN_RE = re.compile(r"([?&][A-Za-z0-9_\-]+=)([A-Fa-f0-9]{32,}|[A-Za-z0-9+/=_\-]{32,})")
QUERY_RE = re.compile(r"\?.*$")
# A key that redaction already replaced. `redact` re-runs on a committed fixture, and
# without this a `<email>` key would re-trigger the `email` substring test below and
# overwrite its own value on the second pass.
PLACEHOLDER_KEY_RE = re.compile(r"^<[^<>]*>(#\d+)?$")

# Identity keys match *exactly* against the normalised key, never as a substring: `user`
# as a substring would swallow the `UserPromptSubmit` hook-event name, which appears as a
# dictionary key in the `hooks` object of the §6.2 initialize payload. `email` is the one
# substring match, because no structural protocol key contains it innocuously.
# `name`-suffixed entries are listed one by one for the same reason: `displayName` is
# structural in this protocol -- it is a `list_models` / `initialize.models` row field
# (parity 06-08-02 lines 21 and 26, evidence 2026-09-03-control-request-shapes line 15), a
# plugin catalogue field (30-29-32 line 170) and a slash-command field the menu widths and
# the Fuse.js ranking read (28-slash-commands lines 500 and 503) -- so redacting it would
# empty the model picker out of every fixture that records one.
IDENTITY_KEYS = frozenset(("account", "accountuuid", "accountid", "accountname",
                           "organization", "organizationuuid", "organizationid", "organizationname",
                           "user", "userid", "useruuid", "username",
                           "subscription", "subscriptiontype", "fullname"))
SECRET_WORDS = ("token", "oauth", "key", "secret", "credential", "authorization", "cookie",
                "password", "bearer")
USAGE_COUNTERS = {"input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
                  "thinking_tokens", "max_tokens", "tokens", "total_tokens", "maxtokens", "rawmaxtokens"}
# Keys that contain a SECRET_WORDS substring but are structural. `projectKey` names the
# directory a GUI must read to replay history -- `~/.claude/projects/<projectKey>/
# <sessionId>.jsonl`, parity 03-49-35 line 186 -- so its value is load-bearing. Nothing
# earns a place here without that kind of citation: `sessionKey` was exempt until a
# search of docs/tui-parity and probes turned up no record of it, against bundle
# occurrences in credential-shaped positions, so it is redacted like any other key.
SECRET_EXEMPT = frozenset(("apikeysource", "hookcallbackids", "projectkey"))
OAUTH_SUBTYPES = ("claude_authenticate", "claude_oauth_callback", "claude_oauth_wait_for_completion",
                  "mcp_authenticate", "mcp_oauth_callback_url")
MCP_LIMIT = 4096


def _norm_key(k):
    """Fold the casing and separators the wire mixes freely: the protocol uses camelCase
    (`subscriptionType`, `accountUuid`) where the spec's prose uses snake_case."""
    return k.lower().replace("_", "").replace("-", "")


def _is_secret_key(k, value=None):
    """Rule 2's name test, which needs the value for one exemption.

    `*_tokens` names are exempted only when the value is an integer. The suffix earns its
    exemption because `ephemeral_5m_input_tokens` is a counter that is not in the explicit
    set, but the distinguishing property is the value, not the name: `access_tokens` is a
    secret with a plural name and must not ride the same exemption.
    """
    lk = k.lower()
    if _norm_key(k) in SECRET_EXEMPT or lk in USAGE_COUNTERS:
        return False
    if lk.endswith("_tokens") and isinstance(value, int):
        return False
    return any(w in lk for w in SECRET_WORDS)


def _is_identity_key(nk):
    if PLACEHOLDER_KEY_RE.match(nk):
        return False
    return nk in IDENTITY_KEYS or "email" in nk


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
        # The manifest is written to `redaction.json`, which §4.4 commits, and its paths are
        # built from key names -- which are themselves data. Scrub here so the guarantee holds
        # at one chokepoint for every rule rather than at each call site.
        self.counts[rule]["count"] += 1
        self.counts[rule]["paths"][self.redact_text(path, record=False) or "$"] += 1

    def manifest(self):
        return {"rules": {r: {"count": v["count"], "paths": dict(v["paths"])} for r, v in self.counts.items()}}

    # ---- text
    def redact_text(self, s, path="", record=True):
        """Rules 1, 2 and 3 over a string. `record=False` suppresses bookkeeping, which is
        what `_hit` needs to sanitise a manifest path without recursing into itself."""
        out = s
        out, k = EMAIL_RE.subn("<email>", out)
        if k and record: self._hit("identity", path)
        for rx in (SK_ANT_RE, JWT_RE):
            out, k = rx.subn("<redacted>", out)
            if k and record: self._hit("secrets", path)
        out, k = QUERY_RUN_RE.subn(lambda m: m.group(1) + "<redacted>", out)
        if k and record: self._hit("secrets", path)
        for h in (self.home, self.home_raw):
            if h and h != "/" and h in out:
                out = out.replace(h, "~")
                if record: self._hit("paths_host", path)
        for h in (self.hostname, self.short_host):
            if h and len(h) > 2 and h in out:
                out = out.replace(h, "<host>")
                if record: self._hit("paths_host", path)
        return out

    # ---- structural
    def redact_json(self, obj, request_subtype=None, path=""):
        if isinstance(obj, dict):
            out = {}
            for k, v in obj.items():
                # A key is data too: project maps are keyed by absolute path and contact maps
                # by address. Predicates read the original key (structural meaning); the output
                # and the manifest path use the redacted one.
                rk = self.redact_text(k, path)
                if rk in out:
                    # Redaction can map two distinct keys onto one placeholder (two addresses
                    # both become `<email>`). Disambiguate rather than let the second silently
                    # overwrite the first: a fixture that quietly loses a subtree is wrong
                    # evidence, and wrong evidence is worse than verbose evidence.
                    n = 2
                    while "%s#%d" % (rk, n) in out:
                        n += 1
                    rk = "%s#%d" % (rk, n)
                p = "%s.%s" % (path, rk) if path else rk
                nk = _norm_key(k)
                if _is_identity_key(nk):
                    placeholder = "<email>" if "email" in nk else "<%s>" % rk
                    if v is None or v == placeholder or v == "<email>":
                        out[rk] = v
                    else:
                        out[rk] = placeholder
                        self._hit("identity", p)
                    continue
                if nk == "apikeysource":
                    placeholder = "<%s>" % rk
                    if v in ("none", placeholder, None):
                        out[rk] = v
                    else:
                        out[rk] = placeholder
                        self._hit("identity", p)
                    continue
                if _is_secret_key(k, v) and (isinstance(v, str) or (isinstance(v, (dict, list)) and nk in ("oauth", "credentials", "credential"))):
                    if v != "<redacted>":
                        self._hit("secrets", p)
                    out[rk] = "<redacted>"
                    continue
                out[rk] = self.redact_json(v, request_subtype, p)
            return out
        if isinstance(obj, list):
            return [self.redact_json(v, request_subtype, "%s[%d]" % (path, i)) for i, v in enumerate(obj)]
        if isinstance(obj, str):
            return self.redact_text(obj, path)
        return obj

    # ---- frame-scoped rules
    def _truncate_mcp(self, msg, path):
        if isinstance(msg, dict) and len(json.dumps(msg)) > MCP_LIMIT:
            kept = {k: msg[k] for k in ("jsonrpc", "id", "method") if k in msg}
            kept["truncated"] = len(json.dumps(msg))
            self._hit("mcp_bodies", path)
            return kept
        return msg

    def _redact_urls(self, node, path):
        """Rule 6, applied to nested strings too: a callback URL is not always top-level."""
        if isinstance(node, dict):
            for k, v in list(node.items()):
                node[k] = self._redact_urls(v, "%s.%s" % (path, k))
            return node
        if isinstance(node, list):
            return [self._redact_urls(v, "%s[%d]" % (path, i)) for i, v in enumerate(node)]
        if isinstance(node, str) and node.startswith("http") and "?" in node:
            new = QUERY_RE.sub("?<redacted>", node)
            if new != node:
                # Only on a real substitution: `redact` re-runs on a committed fixture and
                # `redaction.json` is committed, so the manifest must be idempotent too.
                self._hit("oauth_flow", path)
            return new
        return node

    def redact_frame(self, frame, direction, request_subtypes):
        """`direction` is unused here by design: the caller owns the tombstone line that
        records it (`{"t":..,"dir":"out","dropped":..}`), and only the caller knows the
        timestamp that goes beside it.

        The frame-scoped rules (4, 5, 6) run before the recursive walk of rules 1-3 even
        though §4.5 numbers them the other way. They must: rule 5 needs the pre-redaction
        `effective` dict and rule 4 needs the pre-redaction body size. §4.5's "in this
        order" numbers the rules, it does not sequence execution.
        """
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
                # The subtype is a hint, not a gate, but it is still a hint. Correlation is
                # lost for a late response (§4.4's `late_responses`), and a rule that fires
                # only on a known subtype fails open exactly when the frame is least
                # understood -- so each of rules 4, 5 and 6 fires on its own subtype or on an
                # unknown one. A correlated response to some other subtype therefore keeps a
                # body that merely happens to carry `mcp_response`, `effective`, `sources` or
                # a URL, and an uncorrelated one is treated as possibly any of them.
                if sub in (None, "mcp_message") and "mcp_response" in body:
                    body["mcp_response"] = self._truncate_mcp(body["mcp_response"], "response.mcp_response")
                if sub in (None, "get_settings"):
                    if "effective" in body:
                        eff = body.pop("effective")
                        body["effective_keys"] = sorted(eff.keys()) if isinstance(eff, dict) else []
                        self._hit("settings_bodies", "response.effective")
                    if "sources" in body:
                        srcs = body.pop("sources")
                        body["sources_keys"] = [{"source": s.get("source"), "keys": sorted((s.get("settings") or {}).keys())}
                                                for s in srcs if isinstance(s, dict)] if isinstance(srcs, list) else []
                        self._hit("settings_bodies", "response.sources")
                if sub is None or sub in OAUTH_SUBTYPES:
                    self._redact_urls(body, "response")
            return self.redact_json(f)
        return self.redact_json(frame)


def _string_hits(s, path, probe, where=""):
    """Rules 1, 2 and 3 as assertions rather than substitutions."""
    hits = []
    if EMAIL_RE.search(s):
        hits.append("%s: email%s" % (path, where))
    if SK_ANT_RE.search(s) or JWT_RE.search(s) or QUERY_RUN_RE.search(s):
        hits.append("%s: secret pattern%s" % (path, where))
    if probe.home in s or probe.home_raw in s:
        hits.append("%s: home directory%s" % (path, where))
    for h in (probe.hostname, probe.short_host):
        if len(h) > 2 and h in s:
            hits.append("%s: hostname%s" % (path, where))
            break
    return hits


def scan(obj_or_text, home, *, hostname=None):
    """Hard failures: anything a redaction rule would still change.

    `hostname` defaults to the local one, like `Redactor` itself, and an explicit value
    overrides it for a review run on some other machine. It cannot be left unset: findings
    are made safe by running the redactor's rules over them, so a pattern the scanner was
    never given cannot be scrubbed back out of a finding -- an unredacted hostname in key
    position would compose a finding that is safe to persist by assumption and not in fact.
    Defaulting makes the guarantee true on the recording machine, which is where recording
    and verification happen; elsewhere rule 3's hostname half holds only if the caller
    passes the recording hostname.
    """
    hits = []
    probe = Redactor(home=home, hostname=hostname)

    def walk(o, path):
        if isinstance(o, dict):
            for k, v in o.items():
                # Scrub each path segment rather than the finished path: the email pattern
                # would otherwise swallow the parent segments along with the key and cost the
                # reader the position. Detection still reads the raw key.
                p = "%s.%s" % (path, probe.redact_text(k, record=False)) if path else probe.redact_text(k, record=False)
                hits.extend(_string_hits(k, p, probe, " in key"))
                nk = _norm_key(k)
                if _is_identity_key(nk):
                    if v not in (None, "<email>", "<%s>" % k):
                        hits.append("%s: identity field not redacted" % p)
                elif nk == "apikeysource":
                    if v not in (None, "none", "<%s>" % k):
                        hits.append("%s: identity field not redacted" % p)
                elif _is_secret_key(k, v) and isinstance(v, str) and v != "<redacted>":
                    hits.append("%s: secret-named field not redacted" % p)
                else:
                    walk(v, p)
        elif isinstance(o, list):
            for i, v in enumerate(o):
                walk(v, "%s[%d]" % (path, i))
        elif isinstance(o, str):
            hits.extend(_string_hits(o, path, probe))

    walk(obj_or_text, "")
    # Segment scrubbing above already covers every finding this function builds. Scrubbing
    # the finished list too costs one pass and makes the guarantee hold at the return
    # statement for any finding a later edit adds, however it is composed.
    return [probe.redact_text(h, record=False) for h in hits]


def _line_of(text, index):
    return text.count("\n", 0, index) + 1


def scan_report_only(text, author, home):
    """The two findings only a human can judge in context: reported, never failed.

    These name what matched and where, and never echo it. The material is exactly what the
    redactor leaves alone -- that is why a human has to judge it -- so it cannot be made safe
    by redacting the finding, and §4.5 sends the reviewer to the file anyway. One finding per
    line keeps a name that recurs on every transcript line from burying the rest.
    """
    hits = []
    if author:
        seen = set()
        start = text.find(author)
        while start != -1:
            line = _line_of(text, start)
            if line not in seen:
                seen.add(line)
                hits.append("line %d: configured author name appears" % line)
            start = text.find(author, start + 1)
    seen = set()
    for m in re.finditer(r"/Users/[A-Za-z0-9._-]+", text):
        if home and m.group(0).startswith(home):
            continue
        line = _line_of(text, m.start())
        if line not in seen:
            seen.add(line)
            hits.append("line %d: path under /Users: /Users/<user>" % line)
    return hits
