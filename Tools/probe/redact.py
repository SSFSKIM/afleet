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
# The owner and group columns of an `ls -l` line, matched by **position** rather than by
# name. A directory listing carries the recording machine's account name in a place no other
# rule looks: it is not the home directory, not the hostname and not an identity-named field,
# so rules 1 to 3 walk straight past it. Substituting the account name wherever it appears
# would be the wrong instrument -- this machine's is `new`, and a blanket substitution would
# corrupt every fixture containing the word, which is the same reason the hostname rule
# carries a length guard. Position makes it certain instead: a ten-character mode string and
# a link count are together a strong enough anchor that nothing in prose reaches this, and the
# rule holds on a machine whose account name is a person's name, which is the case it exists
# for. The unstructured occurrences are handed to the reviewer by `scan_report_only`, which is
# §4.5's existing division of labour. Idempotent: `<user>` and `<group>` match the same groups
# on a second pass and substitute to themselves.
LS_LONG_RE = re.compile(r"([-dlbcps][-rwxSsTtLl]{9}[@+.]?\s+\d+\s+)(\S+)(\s+)(\S+)")
LS_USER, LS_GROUP = "<user>", "<group>"
# A key that redaction already replaced. `redact` re-runs on a committed fixture, and
# without this a `<email>` key would re-trigger the `email` substring test below and
# overwrite its own value on the second pass.
PLACEHOLDER_KEY_RE = re.compile(r"^<[^<>]*>(#\d+)?$")

# Identity keys in `IDENTITY_KEYS` match *exactly* against the normalised key, never as a
# substring: `user` as a substring would swallow the `UserPromptSubmit` hook-event name, which
# appears as a dictionary key in the `hooks` object of the §6.2 initialize payload.
# `IDENTITY_SUBSTRINGS` holds the three words that are safe to match anywhere in a key,
# because no structural key in this protocol contains one innocuously. `email` was there from
# the start; `account` and `organization` joined it after the exact-match set walked straight
# past `ownerAccountUuid` and `ownerOrganizationUuid` on a `bridge-session` transcript record,
# which carried a live account uuid and a live organization uuid into a fixture that `verify`
# then passed. Spec §4.5 rule 1 says these fields are replaced *anywhere*, and an exact-match
# set cannot deliver "anywhere": every prefix a future record puts in front of the word is a
# new hole, and each one is silent. The prefixed forms already enumerated below are kept
# because removing them would change nothing and re-open the reading that put them there.
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
IDENTITY_SUBSTRINGS = ("email", "account", "organization")
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
# `Redactor.manifest` keys its own record by *rule name*, two of which contain a secret word,
# and the value is a count and a set of field paths. A manifest is a legitimate thing to hand
# `scan` -- §4.4 commits it and REVIEW item 4 has a reviewer read it -- so the exemption
# belongs here and not only in `verify`'s names-only reshaping of the file.
#
# Rule 5's output used to need an exemption of its own and no longer does, which is worth
# saying because the reason is the principle the rule now follows. It replaced a `get_settings`
# answer's `effective` and `sources` with `effective_keys` and `sources_keys` of its own
# invention: names containing "key", carrying lists of strings, which is exactly the shape the
# widened secrets rule eats. Rule 5 keeps the engine's shape now and replaces values only, so a
# setting *name* stays where it always was -- in key position, where the secrets rule replaces
# a value and never a key -- and nothing has to be exempted to protect it.
SECRET_STRUCTURE_PATHS = frozenset(("rules.secrets", "rules.oauth_flow"))
# The one-time upgrade rule 5 applies to a fixture recorded under that older shape, so
# `make redact` migrates it. Shared with `probe._redact_in_place`, which carries the same
# rename into `census.json`: a census names a body by its keys.
LEGACY_SETTINGS_KEYS = {"effective_keys": "effective", "sources_keys": "sources"}
OAUTH_SUBTYPES = ("claude_authenticate", "claude_oauth_callback", "claude_oauth_wait_for_completion",
                  "mcp_authenticate", "mcp_oauth_callback_url")
MCP_LIMIT = 4096


def _norm_key(k):
    """Fold the casing and separators the wire mixes freely: the protocol uses camelCase
    (`subscriptionType`, `accountUuid`) where the spec's prose uses snake_case."""
    return k.lower().replace("_", "").replace("-", "")


def _contains_string(value):
    """Whether any leaf *value* under `value` is a string. Keys are not leaves: what a
    credential container leaks is its values, and reading its keys as content would make every
    numeric map with string keys -- which is every JSON object -- look like a secret."""
    if isinstance(value, str):
        return True
    if isinstance(value, dict):
        return any(_contains_string(v) for v in value.values())
    if isinstance(value, list):
        return any(_contains_string(v) for v in value)
    return False


def _is_token_counter(lk, value):
    """The one secret word that also names a counter, and the test that separates the two.

    `token` is unlike the other eight: the protocol counts tokens everywhere, so it names
    credentials *and* arithmetic. Both halves of the test are needed. The name half requires
    that `token` is the **only** secret word present, so `oauth_token` and `api_key_token` are
    never counters. The value half requires that nothing under the value is a string, which is
    what actually distinguishes them: a credential is ultimately a string, a counter is
    numbers. That covers the shapes the corpus carries -- `cacheReadInputTokens`,
    `estimated_tokens_delta`, `maxOutputTokens`, `progressToken`, and
    `usage.output_tokens_details`, a *dict* of counters -- without any of them needing to be
    listed, which matters because the name of the next one is not knowable from here.

    This supersedes the narrower `*_tokens`-and-int rule, which the corpus outgrew in every
    direction: the suffix missed `cacheReadInputTokens`, and the int test missed a dict of
    counters. Nothing it exempted stops being exempt.
    """
    if any(w in lk for w in SECRET_WORDS if w != "token"):
        return False
    return not _contains_string(value)


def _is_secret_key(k, value):
    """Rule 2's name test. §4.5 replaces *any* secret-named field, and the value decides only
    which of three exemptions applies -- never whether the rule fires at all.

    Reading §4.5 as "any secret-named **string**" is what left `{"authorization": {"value":
    "Bearer .."}}`, `{"cookies": [{"value": ..}]}` and `{"api_keys": {"primary": ..}}` on disk
    and, because `scan` shares this predicate, invisible to the gate as well. The whole subtree
    goes now, whatever its type.

    `None` is the one value that is never redacted, for the reason the identity rule has always
    left it alone: there is nothing there to leak, and substituting a placeholder changes the
    field's type for no gain. `rate_limits.seven_day_oauth_apps` is the corpus instance.
    """
    lk = k.lower()
    if _norm_key(k) in SECRET_EXEMPT or lk in USAGE_COUNTERS:
        return False
    if value is None:
        return False
    if not any(w in lk for w in SECRET_WORDS):
        return False
    return not _is_token_counter(lk, value)


# Fields whose *name* is in IDENTITY_KEYS but whose position makes them counters. The rules
# key on names, and a name alone cannot tell `user: 7` -- a numeric account id, which is
# identity -- from `killed.user`, the number of subagents the user killed, which is not.
# Type cannot tell them apart either, since both are ints. Position can, so the exemption is
# written as the path it applies to and nothing wider.
#
# `result.subagent_stats.killed.user` sits beside `killed.parent` and `killed.system`, both
# plain counts, and appears in every `result` frame. Redacted it became the string `<user>`,
# which destroys the count and changes the field's type -- not a cosmetic loss, because C2.G2
# asks that every frame in every fixture decode and re-encode without loss, and a `Codable`
# model typing it `Int` cannot read a string back. Found in the `rate-limited-turn` recording.
#
# The bar for adding a path here: the field must be incapable of carrying identity *in that
# position*, demonstrably, from a recording or the bundle -- never because it looked harmless.
IDENTITY_COUNTER_PATHS = frozenset(("subagent_stats.killed.user",))


# The same problem one rule over. `get_usage` answers with `behaviors.day.behaviors[].key`
# and its weekly twin, and the field named `key` there is an enum of behaviour names --
# `cache_miss`, `long_context`, `subagent_heavy`, `high_parallel`, `cron` (2.1.258
# `cli.pretty.js`, `behaviors: R(c({ key: ee([...])`). The secrets rule fires on any key
# containing "key", so it replaced each with `<redacted>` and cost the fixture the one thing
# that says what a usage behaviour is called. Type cannot save this one either: the value is
# a string, exactly like a credential. Position can, so again the exemption is the path.
SECRET_ENUM_PATHS = frozenset(("behaviors.key",))

_PATH_INDEX_RE = re.compile(r"\[\d+\]")


def _path_exempt(path, exempt):
    """Whether a field's *position* takes it out of a name-keyed rule.

    List indices are stripped before matching, so an exemption is written against the shape
    of the path rather than against where an element happened to sit -- `behaviors[0].key`
    and `behaviors[3].key` are the same field. Matching is on a full trailing segment run, so
    a suffix cannot straddle a partial segment name.
    """
    bare = _PATH_INDEX_RE.sub("", path)
    return any(bare == c or bare.endswith("." + c) for c in exempt)


def _is_identity_counter(path):
    return _path_exempt(path, IDENTITY_COUNTER_PATHS)


def _is_secret_enum(path):
    return _path_exempt(path, SECRET_ENUM_PATHS)


def _is_secret_structure(path):
    return _path_exempt(path, SECRET_STRUCTURE_PATHS)


def _secret_field(k, value, path):
    """The whole of rule 2 in one place, so `redact_json` and `scan` cannot drift apart."""
    return _is_secret_key(k, value) and not _is_secret_enum(path) and not _is_secret_structure(path)


def _is_identity_key(nk):
    if PLACEHOLDER_KEY_RE.match(nk):
        return False
    return nk in IDENTITY_KEYS or any(w in nk for w in IDENTITY_SUBSTRINGS)


class Redactor:
    def __init__(self, home=None, hostname=None, author=None):
        self.home = os.path.realpath(home or os.path.expanduser("~"))
        self.home_raw = home or os.path.expanduser("~")
        self.hostname = hostname or socket.gethostname()
        self.short_host = self.hostname.split(".")[0]
        self.author = author
        self.counts = collections.OrderedDict((r, {"count": 0, "paths": collections.Counter(),
                                                   "subtrees": collections.Counter()})
                                              for r in ("identity", "secrets", "paths_host", "mcp_bodies", "settings_bodies", "oauth_flow"))

    # ---- bookkeeping
    def _hit(self, rule, path, subtree=False):
        # The manifest is written to `redaction.json`, which §4.4 commits, and its paths are
        # built from key names -- which are themselves data. Scrub here so the guarantee holds
        # at one chokepoint for every rule rather than at each call site.
        #
        # `subtree` says the substitution replaced a dict or a list rather than a scalar, so
        # everything below that path went with it. It is recorded separately because the loss
        # is different in kind: a scalar replacement trades one value for a placeholder, while
        # a container replacement can take structure a consumer needed -- a `projectKey` nested
        # under a secret-named container is the case that would hurt. Rule 2 is fail-closed and
        # replaces the container deliberately; what it must not do is make that loss look like
        # an anonymous increment to the count. REVIEW item 4 sends a reviewer here, so this is
        # where a subtree replacement has to be visible by name.
        self.counts[rule]["count"] += 1
        scrubbed = self.redact_text(path, record=False) or "$"
        self.counts[rule]["paths"][scrubbed] += 1
        if subtree:
            self.counts[rule]["subtrees"][scrubbed] += 1

    def manifest(self, prior=None):
        """What this redactor substituted, optionally added to what a `prior` manifest records.

        `redact` re-runs the rules over a fixture whose bytes are already redacted, so a fresh
        manifest records only what that pass found -- which, for everything the first pass
        already caught, is nothing. Replacing the file would therefore turn the manifest from a
        record of what was redacted into a record of what the last re-run happened to find, and
        REVIEW item 4 asks a reviewer to read it as the former. Summing is stable rather than
        merely additive: a rule with nothing left to substitute contributes zero, so re-running
        twice changes nothing, and a rule added after the recording (the `ls -l` owner column)
        shows up as the new substitutions it made on top of the old ones.
        """
        out = {r: {"count": v["count"], "paths": dict(v["paths"])} for r, v in self.counts.items()}
        subtrees = {r: dict(v["subtrees"]) for r, v in self.counts.items()}
        for rule, before in ((prior or {}).get("rules") or {}).items():
            entry = out.setdefault(rule, {"count": 0, "paths": {}})
            entry["count"] += before.get("count", 0)
            for path, n in (before.get("paths") or {}).items():
                entry["paths"][path] = entry["paths"].get(path, 0) + n
            for path, n in (before.get("subtrees") or {}).items():
                acc = subtrees.setdefault(rule, {})
                acc[path] = acc.get(path, 0) + n
        # Written only where there is something to report. A rule that replaced no container
        # says so by the key's absence, which keeps `redaction.json` the same file it was for
        # every fixture in the corpus and puts the key in front of a reviewer exactly when a
        # subtree was in fact replaced.
        for rule, paths in subtrees.items():
            if paths:
                out[rule]["subtrees"] = paths
        return {"rules": out}

    # ---- text
    def redact_text(self, s, path="", record=True):
        """Rules 1, 2 and 3 over a string. `record=False` suppresses bookkeeping, which is
        what `_hit` needs to sanitise a manifest path without recursing into itself.

        A rule is counted when it **changes** the string, never merely when it matches. Most
        rules cannot match their own output, so the two are the same for them -- but the owner
        column rule can: `<user>` and `<group>` sit where a name and a group sat, so it matches
        its own placeholders and substitutes them to themselves. Counting the match would inflate
        the manifest on every `redact` re-run of a committed fixture, which is the rot the
        manifest merge exists to avoid, so the test is on the result rather than on the match.
        """
        def apply(text, rule, fn):
            after = fn(text)
            if after != text and record:
                self._hit(rule, path)
            return after

        out = s
        out = apply(out, "identity", lambda t: EMAIL_RE.sub("<email>", t))
        for rx in (SK_ANT_RE, JWT_RE):
            out = apply(out, "secrets", lambda t, rx=rx: rx.sub("<redacted>", t))
        out = apply(out, "secrets", lambda t: QUERY_RUN_RE.sub(lambda m: m.group(1) + "<redacted>", t))
        out = apply(out, "identity",
                    lambda t: LS_LONG_RE.sub(lambda m: m.group(1) + LS_USER + m.group(3) + LS_GROUP, t))
        for h in (self.home, self.home_raw):
            if h and h != "/":
                out = apply(out, "paths_host", lambda t, h=h: t.replace(h, "~"))
        for h in (self.hostname, self.short_host):
            if h and len(h) > 2:
                out = apply(out, "paths_host", lambda t, h=h: t.replace(h, "<host>"))
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
                if _is_identity_key(nk) and not _is_identity_counter(p):
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
                if _secret_field(k, v, p):
                    if v != "<redacted>":
                        self._hit("secrets", p, subtree=isinstance(v, (dict, list)))
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

    def _blank_settings(self, node, path):
        """A settings map with every key kept and every value replaced, whatever its type.

        Rule 5's whole content. §4.5 asks for a `get_settings` answer's values to go, and the
        engine sends them as `{<setting name>: <value>}` (2.1.258 `cli.pretty.js`, `aRn()`), so
        the answer is a map of the same names onto placeholders. A setting name is not a secret
        and a fixture is evidence of what the engine sent: a rule that renames a field writes
        evidence of a frame that never travelled, and a consumer that learns the invented name
        from the fixture fails against a real engine. Redaction replaces values and nothing else.

        A value that is not a map at all cannot keep a shape it does not have; it is replaced
        outright, which is rule 5 staying fail-closed on a body it does not recognise.
        """
        if isinstance(node, dict):
            out = {k: "<redacted>" for k in node}
            if out != node:
                self._hit("settings_bodies", path,
                          subtree=any(isinstance(v, (dict, list)) for v in node.values()))
            return out
        if node == "<redacted>":
            return node
        self._hit("settings_bodies", path, subtree=isinstance(node, list))
        return "<redacted>"

    def _blank_sources(self, node, path):
        """`sources` is `[{source, settings: {<setting name>: <value>}}]`. The source name says
        which file a setting came from and is kept for the same reason the setting names are."""
        if not isinstance(node, list):
            return self._blank_settings(node, path)
        out = []
        for i, s in enumerate(node):
            p = "%s[%d]" % (path, i)
            if isinstance(s, dict):
                entry = dict(s)
                if "settings" in entry:
                    entry["settings"] = self._blank_settings(entry["settings"], p + ".settings")
                out.append(entry)
            else:
                out.append(self._blank_settings(s, p))
        return out

    def _upgrade_legacy_settings(self, body):
        """Rewrite a body carrying the shape rule 5 itself used to write into the engine's.

        A committed fixture holds `effective_keys` and `sources_keys`, which no engine ever
        sent. What that older rule kept was the setting names, so the upgrade is lossless: the
        names go back where the engine puts them, values already gone. In place, so the body's
        key order survives and the migration diff reads as the rename it is, and only where the
        engine's own key is absent, so a second `make redact` finds nothing to do.
        """
        if not any(old in body and new not in body for old, new in LEGACY_SETTINGS_KEYS.items()):
            return
        rebuilt = {}
        for k, v in body.items():
            new = LEGACY_SETTINGS_KEYS.get(k)
            if new and new not in body:
                rebuilt[new] = self._from_legacy_settings(new, v)
                # Recorded against the engine's key, not the invented one: it is the same field,
                # and the manifest a reviewer reads should name the position the engine names.
                self._hit("settings_bodies", "response.%s" % new)
            else:
                rebuilt[k] = v
        body.clear()
        body.update(rebuilt)

    @staticmethod
    def _from_legacy_settings(new, v):
        if not isinstance(v, list):
            return "<redacted>"
        if new == "effective":
            return {k: "<redacted>" for k in v if isinstance(k, str)}
        return [{"source": s.get("source"),
                 "settings": {k: "<redacted>" for k in (s.get("keys") or []) if isinstance(k, str)}}
                for s in v if isinstance(s, dict)]

    def _redact_oauth_state(self, node, path):
        """Rule 6's other half. `claude_oauth_callback` hands back its grant as two bare
        strings: `authorizationCode`, which the `authorization` secret word already catches,
        and `state`, which no name rule reaches. Adding `state` to SECRET_WORDS would reach it
        and a great deal else -- `session_state`, a dialog's state -- so the OAuth subtype is
        the gate instead, exactly as it is for the URL half. Nested for the same reason the URL
        rule is nested, and idempotent so a `redact` re-run over a committed fixture does not
        inflate the manifest.
        """
        if isinstance(node, dict):
            for k, v in list(node.items()):
                p = "%s.%s" % (path, k)
                if k.lower() == "state" and v is not None and v != "<redacted>":
                    node[k] = "<redacted>"
                    self._hit("oauth_flow", p, subtree=isinstance(v, (dict, list)))
                else:
                    node[k] = self._redact_oauth_state(v, p)
            return node
        if isinstance(node, list):
            return [self._redact_oauth_state(v, "%s[%d]" % (path, i)) for i, v in enumerate(node)]
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
            if sub in OAUTH_SUBTYPES:
                # The grant travels outbound as well: `mcp_oauth_callback_url.callbackUrl` and
                # `mcp_authenticate.redirectUri` carry `?code=..&state=..`, and rule 6 used to
                # run only over responses. A request states its own subtype, so unlike a
                # response there is no correlation to lose and no fail-open case to cover: the
                # gate is the subtype and nothing else. Scanning every string for a URL instead
                # would rewrite a `can_use_tool` argument that merely happens to be one.
                req = json.loads(json.dumps(f["request"]))
                self._redact_urls(req, "request")
                self._redact_oauth_state(req, "request")
                f["request"] = req
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
                    self._upgrade_legacy_settings(body)
                    if "effective" in body:
                        body["effective"] = self._blank_settings(body["effective"], "response.effective")
                    if "sources" in body:
                        body["sources"] = self._blank_sources(body["sources"], "response.sources")
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
    if any(m.group(2) != LS_USER or m.group(4) != LS_GROUP for m in LS_LONG_RE.finditer(s)):
        hits.append("%s: ls -l owner column%s" % (path, where))
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
                if _is_identity_key(nk) and not _is_identity_counter(p):
                    if v not in (None, "<email>", "<%s>" % k):
                        hits.append("%s: identity field not redacted" % p)
                elif nk == "apikeysource":
                    if v not in (None, "none", "<%s>" % k):
                        hits.append("%s: identity field not redacted" % p)
                elif _secret_field(k, v, p):
                    # Whatever the type: a dict or a list under a secret-named key is the
                    # container case the redactor now replaces, so anything that is not the
                    # placeholder is a finding here too. The value is never walked into and
                    # never quoted -- the finding names the position and the rule only.
                    if v != "<redacted>":
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
    """The findings only a human can judge in context: reported, never failed.

    These name what matched and where, and never echo it. The material is exactly what the
    redactor leaves alone -- that is why a human has to judge it -- so it cannot be made safe
    by redacting the finding, and §4.5 sends the reviewer to the file anyway. One finding per
    line keeps a name that recurs on every transcript line from burying the rest.

    The account name -- the last segment of the home directory -- joins the author's name and a
    foreign `/Users/` path here rather than among the substitutions, and for the same reason
    they are here. Where its position makes it certain it is redacted outright (`LS_LONG_RE`);
    everywhere else it is an ordinary word that may or may not be an identifier, which is a
    judgement, and substituting it blindly would corrupt any fixture whose prose contains it.
    Matched on word boundaries so a name inside a longer word does not report.

    It reports **once per file** with a line count, where the author's name reports once per
    line, and the difference is the point. An author's name is rare enough that each occurrence
    is worth a look. An account name may be an ordinary English word -- on the machine this was
    written on it is `new`, which occurs 120 times across the corpus, every one of them prose --
    so a per-line finding would bury the two checks that already live here under a hundred lines
    nobody reads. A count and a first line send the reviewer to the same place without costing
    them the rest of the report.
    """
    hits = []
    account = os.path.basename(os.path.normpath(home)) if home else ""
    if account:
        lines = sorted({_line_of(text, m.start())
                        for m in re.finditer(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(account), text)})
        if lines:
            hits.append("the account name appears on %d line(s), first at line %d; judge whether any of them "
                        "identifies anyone" % (len(lines), lines[0]))
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
