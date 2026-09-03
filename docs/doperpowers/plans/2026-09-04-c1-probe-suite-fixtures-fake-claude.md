# C1: Probe Suite, Golden Fixtures and fake-claude — Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use doperpowers:subagent-driven-execution to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the fourteen ad hoc probe scripts into `Tools/probe` (census, record, snapshot, redact, verify, diff), ship `Tools/fake-claude` (a reactive fixture replayer with duplex scripts and safe materialisation), record the thirteen golden fixtures plus two synthetic dialog fixtures under `Fixtures/`, and settle spikes S5, S6, S8 and S10 through S18 with dated Revision Notes on the parent document in this branch.

**Architecture:** Two independent Python 3.9 standard-library tools. `Tools/probe` is a library (`harness.py`, `census.py`, `redact.py`, `fixture.py`, `verify.py`) with one CLI (`probe.py`) and one file per scenario under `scenarios/`; every frame is redacted in memory before it is captured, and a fixture is assembled in a temporary directory and renamed into `Fixtures/` in one step. `Tools/fake-claude` reads only the fixture format: it replays `frames.ndjson` reactively, applies a duplex script, and, when given a config home it created and marked, lays down `initial/`, appends `transcript_mirror` entries from the recorded offsets and writes artifacts in step with replay.

**Tech Stack:** Python 3.9.6 (system) and 3.14 (Homebrew), standard library only (`subprocess`, `threading`, `json`, `re`, `unittest`, `tempfile`, `os`, `argparse`, `importlib`, `pty`); GNU Make 3.81; the installed `claude` 2.1.259 for recordings only.

**Spec:** `docs/doperpowers/specs/2026-09-04-c1-probe-suite-fixtures-fake-claude.md` (child C1), citing the parent `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C1` and contracts X8, X9. Conflicts found during execution resolve against the child spec, then the parent.

## Global Constraints

- Python **3.9.6** must run every tool and test (`/usr/bin/python3`); no third-party imports anywhere under `Tools/`; no `match` statements, no `X | Y` type unions at runtime, no `zoneinfo` reliance.
- Every tool is also green on **3.14** (`/opt/homebrew/bin/python3`).
- **Nothing under `Tools/` creates, edits or deletes a file under any Claude config home** (`~/.claude` or `$CLAUDE_CONFIG_DIR`); `snapshot` copies, never moves. `fake-claude materialize` writes only into a directory it created and marked with `.afleet-fake-home`.
- **No unredacted byte reaches disk**, ever, git-ignored or not. Redaction runs in memory on every frame and on every file `snapshot` copies. There is no `raw/` directory.
- Recordings use the scratch config home `CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home` (logged into once by the author), a fresh scratch cwd under `/tmp/afleet-fixtures/<name>/`, model `haiku`, `--max-turns` between 2 and 6, `--setting-sources ""`, `--strict-mcp-config` (with the S5 exception), and the parent's §6.1 launch line with `--session-mirror`.
- The launch line always contains `--permission-prompt-tool stdio`; the harness refuses to build one without it.
- The MCP tool is exactly `send_user_file {files: [string], caption?: string, status: "normal" | "proactive", display?: "render" | "attach"}`; a JSON-RPC notification is answered with `mcp_response {"jsonrpc":"2.0","result":{},"id":0}`.
- `submit_feedback` is never sent by any scenario. `end_session` is never sent while a scenario's background task is still running unless the scenario says so.
- Commit messages are plain (`feat:`, `test:`, `docs:` prefixes), with no attribution trailer.
- Fixture names, file names and field names are exactly those in spec §4.4 and §4.7.

---

## File Structure

```
Makefile                                   test-tools, probe, census, record, verify-fixtures
Tools/probe/__init__.py                    empty; makes Tools/probe importable from tests
Tools/probe/probe.py                       CLI: census | diff | record | snapshot | redact | verify
Tools/probe/harness.py                     Launch, Capture (redact-then-record, spill), Session, MCPServer, policies
Tools/probe/census.py                      census(), merge_required(), diff(), flags_from_help()
Tools/probe/redact.py                      Redactor (six rules, manifest), scan(), scan_report_only()
Tools/probe/fixture.py                     fixture layout: find_session_files, snapshot_tree, streams, artifacts, assemble, load
Tools/probe/verify.py                      structural + lifecycle + redaction + review-block checks
Tools/probe/scenarios/__init__.py          empty
Tools/probe/scenarios/zero_cost.py         the zero-cost census scenario (deterministic)
Tools/probe/scenarios/<name>.py            one per fixture / spike (Tasks 8–11)
Tools/probe/tests/_paths.py                sys.path shim so tests import the modules by path
Tools/probe/tests/stand_in.py              a scripted protocol stand-in used as the "binary" by harness tests
Tools/probe/tests/test_census.py
Tools/probe/tests/test_redact.py
Tools/probe/tests/test_harness.py
Tools/probe/tests/test_fixture_verify.py
Tools/probe/tests/test_probe_cli.py
Tools/fake-claude/fake-claude              executable: `#!/usr/bin/env python3`, imports fake_claude.py beside it
Tools/fake-claude/fake_claude.py           replayer, scripts, materialize, refusals
Tools/fake-claude/tests/_paths.py
Tools/fake-claude/tests/test_fake_claude.py
Fixtures/REVIEW.md                         the second-review checklist and the review-block format
Fixtures/<name>/...                        recorded and synthetic fixtures (Tasks 7–10)
Fixtures/.gitignore                        empty file kept so the directory exists before the first fixture
```

`redact.py`, `census.py` and `fixture.py` know nothing about processes; `harness.py` knows nothing about fixture layout beyond producing a frame list; `probe.py` is the only module that composes them. `fake_claude.py` imports nothing from `Tools/probe`.

The spec's §4.1 lists `probe.py`, `harness.py`, `census.py`, `redact.py`; this plan adds `fixture.py` and `verify.py` so that the fixture layout and the verifier are unit-testable without the CLI. That is recorded as a Revision Note on the spec in Task 1.

---

### Task 1: Scaffold, Makefile and the census module

**Files:**
- Create: `Makefile`
- Create: `Tools/probe/__init__.py`, `Tools/probe/scenarios/__init__.py`, `Fixtures/.gitignore`
- Create: `Tools/probe/tests/_paths.py`
- Create: `Tools/probe/census.py`
- Test: `Tools/probe/tests/test_census.py`
- Modify: `docs/doperpowers/specs/2026-09-04-c1-probe-suite-fixtures-fake-claude.md` (Revision Notes only)

**Interfaces:**
- Consumes: nothing.
- Produces: `census.pair_of(frame, request_subtypes) -> str`; `census.census(frames, *, help_text=None, version=None) -> dict`; `census.merge_required(previous, current) -> dict`; `census.diff(recorded, observed, mode) -> list[str]` (`mode` is `"exact"` or `"required"`); `census.flags_from_help(text) -> list[str]`; `census.request_subtypes(frames) -> dict[request_id, subtype]`.

- [ ] **Step 1: Create the scaffold files**

```bash
mkdir -p Tools/probe/scenarios Tools/probe/tests Tools/fake-claude/tests Fixtures
touch Tools/probe/__init__.py Tools/probe/scenarios/__init__.py Fixtures/.gitignore
```

`Tools/probe/tests/_paths.py`:

```python
"""Put Tools/probe on sys.path so tests import modules directly (no package needed)."""
import os
import sys

PROBE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROBE_DIR not in sys.path:
    sys.path.insert(0, PROBE_DIR)
```

`Makefile`:

```make
PYTHON ?= python3
CLAUDE ?= claude
FIXTURE ?=
SCENARIO ?=
SCRIPT ?=

.PHONY: test-tools probe census record verify-fixtures

test-tools:
	$(PYTHON) -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_*.py'
	$(PYTHON) -m unittest discover -s Tools/fake-claude/tests -t Tools/fake-claude/tests -p 'test_*.py'

probe:
	$(PYTHON) Tools/probe/probe.py diff --claude "$(CLAUDE)" $(if $(FIXTURE),--fixture "$(FIXTURE)") $(if $(SCRIPT),--script "$(SCRIPT)")

census:
	$(PYTHON) Tools/probe/probe.py census --claude "$(CLAUDE)"

record:
	@test -n "$(SCENARIO)" || (echo "usage: make record SCENARIO=<name>" && exit 2)
	$(PYTHON) Tools/probe/probe.py record "$(SCENARIO)" --claude "$(CLAUDE)"

verify-fixtures:
	$(PYTHON) Tools/probe/probe.py verify Fixtures/*/
```

Note: Make recipes need a real tab character at the start of each recipe line.

- [ ] **Step 2: Write the failing census tests**

`Tools/probe/tests/test_census.py`:

```python
import unittest
import _paths  # noqa: F401
import census


def frame(t, **kw):
    d = {"type": t}
    d.update(kw)
    return d


class PairOfTests(unittest.TestCase):
    def test_system_frame_uses_subtype(self):
        self.assertEqual(census.pair_of(frame("system", subtype="init"), {}), "system/init")

    def test_control_request_uses_request_subtype(self):
        f = frame("control_request", request_id="r1", request={"subtype": "can_use_tool"})
        self.assertEqual(census.pair_of(f, {}), "control_request/can_use_tool")

    def test_control_response_is_keyed_by_the_request_it_answers(self):
        f = frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {}})
        self.assertEqual(census.pair_of(f, {"r1": "get_usage"}), "control_response/get_usage")
        self.assertEqual(census.pair_of(f, {}), "control_response/?")

    def test_plain_frame_has_no_subtype(self):
        self.assertEqual(census.pair_of(frame("assistant", message={}), {}), "assistant")


class CensusTests(unittest.TestCase):
    def frames(self):
        return [
            frame("system", subtype="init", capabilities=["a", "b"], tools=[], uuid="u"),
            frame("control_request", request_id="r1", request={"subtype": "can_use_tool", "tool_name": "Write", "input": {}}),
            frame("control_response", response={"subtype": "success", "request_id": "r1", "response": {"behavior": "allow"}}),
            frame("assistant", message={"role": "assistant", "content": [{"type": "text", "text": "hi"}, {"type": "tool_use", "id": "t"}]}),
            frame("assistant", message={"role": "assistant", "content": [{"type": "text", "text": "again"}], "model": "x"}),
        ]

    def test_pairs_keys_payload_keys_and_block_types(self):
        c = census.census(self.frames(), help_text="  --foo  x\n  -p, --print  y\n", version="2.1.259")
        self.assertEqual(c["version"], "2.1.259")
        self.assertEqual(c["flags"], ["--foo", "--print"])
        self.assertEqual(c["capabilities"], ["a", "b"])
        p = c["pairs"]
        self.assertEqual(sorted(p), ["assistant", "control_request/can_use_tool", "control_response/can_use_tool", "system/init"])
        self.assertEqual(p["control_request/can_use_tool"]["payload_keys"], ["input", "subtype", "tool_name"])
        self.assertEqual(p["control_response/can_use_tool"]["payload_keys"], ["behavior"])
        self.assertEqual(p["assistant"]["block_types"], ["text", "tool_use"])
        self.assertEqual(p["assistant"]["count"], 2)
        # required keys = keys present in every frame of the pair; keys = union
        self.assertEqual(p["assistant"]["keys"], ["message", "type"])
        self.assertEqual(p["assistant"]["payload_keys"], ["content", "model", "role"])
        self.assertEqual(p["assistant"]["required_payload_keys"], ["content", "role"])

    def test_merge_required_intersects_required_and_unions_keys(self):
        a = census.census(self.frames())
        b = census.census(self.frames()[:1] + [frame("system", subtype="init", capabilities=["a"], extra=1)])
        m = census.merge_required(a, b)
        self.assertEqual(m["pairs"]["system/init"]["keys"], ["capabilities", "extra", "subtype", "tools", "type", "uuid"])
        self.assertEqual(m["pairs"]["system/init"]["required_keys"], ["capabilities", "subtype", "type"])
        self.assertIn("assistant", m["pairs"])  # pairs only in one side are kept as recorded


class DiffTests(unittest.TestCase):
    def base(self):
        return census.census([
            frame("system", subtype="init", capabilities=["a"], tools=[]),
            frame("assistant", message={"role": "assistant", "content": []}),
        ], help_text="  --foo  x\n", version="2.1.259")

    def test_exact_mode_reports_added_pair_removed_key_and_flag_changes(self):
        rec = self.base()
        obs = census.census([
            frame("system", subtype="init", capabilities=["a", "z"]),
            frame("assistant", message={"role": "assistant", "content": []}),
            frame("afleet_invented", x=1),
        ], help_text="  --foo  x\n  --bar  y\n", version="2.1.260")
        lines = census.diff(rec, obs, "exact")
        self.assertIn("added pair afleet_invented", lines)
        self.assertIn("system/init: removed keys tools", lines)
        self.assertIn("capabilities: added z", lines)
        self.assertIn("flags: added --bar", lines)
        self.assertNotIn("version", " ".join(lines))  # version is informational

    def test_required_mode_ignores_optional_keys_and_counts(self):
        rec = census.merge_required(
            census.census([frame("assistant", message={"role": "assistant", "content": [], "model": "m"})]),
            census.census([frame("assistant", message={"role": "assistant", "content": []})]),
        )
        obs = census.census([
            frame("assistant", message={"role": "assistant", "content": []}),
            frame("assistant", message={"role": "assistant", "content": []}),
        ])
        self.assertEqual(census.diff(rec, obs, "required"), [])
        obs2 = census.census([frame("assistant", message={"content": []})])
        self.assertEqual(census.diff(rec, obs2, "required"), ["assistant: removed required payload keys role"])

    def test_identical_census_has_no_diff(self):
        self.assertEqual(census.diff(self.base(), self.base(), "exact"), [])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_census.py' -v`
Expected: `ImportError`/`ModuleNotFoundError: No module named 'census'`.

- [ ] **Step 4: Implement `Tools/probe/census.py`**

```python
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_census.py' -v`
Expected: all tests `ok`. Then run `make test-tools` and expect the probe discovery to pass and the fake-claude discovery to report `Ran 0 tests` (no tests yet; that is fine, exit 0).

- [ ] **Step 6: Record the module split in the spec**

Append to the spec's `## Revision Notes`:

```
- 2026-09-04: Planning split the tooling into `fixture.py` (layout, snapshot, streams,
  artifacts, assembly) and `verify.py` (structural, lifecycle, redaction and review
  checks) beside the four modules §4.1 names, so both are unit-testable without a live
  binary; `probe.py` remains the only composition point. Discovery runs one
  `unittest discover` per tool because `Tools/fake-claude` is not an importable
  package name.
```

- [ ] **Step 7: Commit**

```bash
git add Makefile Tools/probe/__init__.py Tools/probe/scenarios/__init__.py Fixtures/.gitignore Tools/probe/tests/_paths.py Tools/probe/census.py Tools/probe/tests/test_census.py docs/doperpowers/specs/2026-09-04-c1-probe-suite-fixtures-fake-claude.md
git commit -m "feat(probe): scaffold, Makefile and census fingerprint with exact and required-shape diff"
```

### Task 2: Redaction rules, manifest and scanners

**Files:**
- Create: `Tools/probe/redact.py`
- Test: `Tools/probe/tests/test_redact.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `redact.Redactor(home=None, hostname=None, author=None)` with `redact_frame(frame_dict, direction, request_subtypes) -> dict | None` (None means "drop this frame; write a tombstone"), `redact_json(obj, request_subtype=None) -> obj`, `redact_text(text) -> str`, `manifest() -> dict`; module functions `scan(obj_or_text, home) -> list[str]` (hard failures) and `scan_report_only(text, author, home) -> list[str]`; constant `USAGE_COUNTERS`.

- [ ] **Step 1: Write the failing redaction tests**

`Tools/probe/tests/test_redact.py`:

```python
import json
import unittest
import _paths  # noqa: F401
import redact


class RedactTextTests(unittest.TestCase):
    def setUp(self):
        self.r = redact.Redactor(home="/Users/probe", hostname="probe-mac", author="Probe Person")

    def test_email_home_and_hostname(self):
        s = "mail me at a.b@example.com from /Users/probe/src on probe-mac"
        self.assertEqual(self.r.redact_text(s), "mail me at <email> from ~/src on <host>")

    def test_secret_patterns_in_text(self):
        s = "key sk-ant-api03-abcDEF123 and jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        out = self.r.redact_text(s)
        self.assertNotIn("sk-ant-api03", out)
        self.assertNotIn("eyJhbGci", out)
        self.assertIn("<redacted>", out)

    def test_long_hex_in_url_query_only(self):
        url = "https://x.test/cb?code=0123456789abcdef0123456789abcdef&state=s"
        self.assertEqual(self.r.redact_text(url), "https://x.test/cb?code=<redacted>&state=s")
        self.assertEqual(self.r.redact_text("0123456789abcdef0123456789abcdef"), "0123456789abcdef0123456789abcdef")


class RedactJsonTests(unittest.TestCase):
    def setUp(self):
        self.r = redact.Redactor(home="/Users/probe", hostname="probe-mac")

    def test_identity_fields_get_typed_placeholders(self):
        obj = {"account": {"uuid": "u", "email": "a@b.c"}, "apiKeySource": "user", "subscription_type": "max",
               "organization": {"id": 1}, "user": {"id": 2}, "contact_email": "x@y.z", "other": "keep"}
        out = self.r.redact_json(obj)
        self.assertEqual(out, {"account": "<account>", "apiKeySource": "<apiKeySource>", "subscription_type": "<subscription_type>",
                               "organization": "<organization>", "user": "<user>", "contact_email": "<email>", "other": "keep"})
        self.assertEqual(self.r.redact_json({"apiKeySource": "none"}), {"apiKeySource": "none"})

    def test_secret_named_string_fields_only(self):
        obj = {"accessToken": "abc", "oauth": {"x": 1}, "api_key": "k", "clientSecret": "s", "credentials": "c",
               "Authorization": "Bearer t", "cookie": "c=1",
               "input_tokens": 12, "output_tokens": 3, "max_tokens": 4, "thinking_tokens": 0, "cache_read_input_tokens": 9,
               "key": {"projectKey": "p", "sessionId": "s"}, "hookCallbackIds": ["afleet.notification"]}
        out = self.r.redact_json(obj)
        self.assertEqual(out["accessToken"], "<redacted>")
        self.assertEqual(out["oauth"], "<redacted>")
        self.assertEqual(out["api_key"], "<redacted>")
        self.assertEqual(out["clientSecret"], "<redacted>")
        self.assertEqual(out["credentials"], "<redacted>")
        self.assertEqual(out["Authorization"], "<redacted>")
        self.assertEqual(out["cookie"], "<redacted>")
        for k in ("input_tokens", "output_tokens", "max_tokens", "thinking_tokens", "cache_read_input_tokens"):
            self.assertEqual(out[k], obj[k])
        self.assertEqual(out["key"], {"projectKey": "p", "sessionId": "s"})
        self.assertEqual(out["hookCallbackIds"], ["afleet.notification"])

    def test_idempotent(self):
        obj = {"account": {"email": "a@b.c"}, "token": "t", "text": "/Users/probe/x a@b.c"}
        once = self.r.redact_json(obj)
        self.assertEqual(self.r.redact_json(once), once)

    def test_manifest_counts_rules_and_paths(self):
        self.r.redact_json({"account": {"email": "a@b.c"}, "token": "t", "nested": {"cookie": "c"}})
        m = self.r.manifest()
        self.assertEqual(m["rules"]["identity"]["count"], 1)
        self.assertEqual(m["rules"]["secrets"]["count"], 2)
        self.assertIn("nested.cookie", m["rules"]["secrets"]["paths"])


class RedactFrameTests(unittest.TestCase):
    def setUp(self):
        self.r = redact.Redactor(home="/Users/probe", hostname="probe-mac")

    def test_update_environment_variables_is_dropped(self):
        f = {"type": "control_request", "request_id": "r9", "request": {"subtype": "update_environment_variables", "variables": {"A": "1"}}}
        self.assertIsNone(self.r.redact_frame(f, "out", {}))

    def test_mcp_bodies_over_4kb_are_truncated(self):
        big = "x" * 5000
        f = {"type": "control_request", "request_id": "r1", "request": {"subtype": "mcp_message", "server_name": "afleet",
             "message": {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"blob": big}}}}
        out = self.r.redact_frame(f, "out", {})
        msg = out["request"]["message"]
        self.assertEqual(msg["jsonrpc"], "2.0"); self.assertEqual(msg["id"], 7); self.assertEqual(msg["method"], "tools/call")
        self.assertNotIn("params", msg); self.assertGreater(msg["truncated"], 4096)
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r1",
                "response": {"mcp_response": {"jsonrpc": "2.0", "id": 7, "result": {"blob": big}}}}}
        out2 = self.r.redact_frame(resp, "in", {"r1": "mcp_message"})
        self.assertIn("truncated", out2["response"]["response"]["mcp_response"])

    def test_get_settings_values_are_dropped(self):
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r2", "response": {
            "effective": {"model": "opus", "env": {"SECRET": "x"}}, "sources": [{"source": "userSettings", "settings": {"a": 1}}],
            "applied": {"model": "opus", "effort": "high"}}}}
        out = self.r.redact_frame(resp, "in", {"r2": "get_settings"})
        body = out["response"]["response"]
        self.assertEqual(body["applied"], {"model": "opus", "effort": "high"})
        self.assertEqual(body["effective_keys"], ["env", "model"])
        self.assertEqual(body["sources_keys"], [{"source": "userSettings", "keys": ["a"]}])
        self.assertNotIn("effective", body); self.assertNotIn("sources", body)

    def test_oauth_responses_keep_shape_and_drop_query(self):
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r3", "response": {
            "manualUrl": "https://claude.ai/oauth/authorize?code_challenge=abc&state=xyz", "automaticUrl": "https://claude.ai/o?x=1"}}}
        out = self.r.redact_frame(resp, "in", {"r3": "claude_authenticate"})
        self.assertEqual(out["response"]["response"], {"manualUrl": "https://claude.ai/oauth/authorize?<redacted>",
                                                       "automaticUrl": "https://claude.ai/o?<redacted>"})


class ScanTests(unittest.TestCase):
    def test_scan_finds_hard_failures(self):
        hits = redact.scan({"a": "mail a@b.c", "b": {"c": "sk-ant-zzz"}, "d": "/Users/probe/x"}, home="/Users/probe")
        self.assertEqual(len(hits), 3)
        self.assertTrue(any("email" in h for h in hits))
        self.assertEqual(redact.scan({"a": "clean ~ text"}, home="/Users/probe"), [])

    def test_report_only(self):
        hits = redact.scan_report_only("by Probe Person in /Users/someone/x", author="Probe Person", home="/Users/probe")
        self.assertEqual(len(hits), 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_redact.py' -v`
Expected: `ModuleNotFoundError: No module named 'redact'`.

- [ ] **Step 3: Implement `Tools/probe/redact.py`**

```python
"""Redaction rules (spec §4.5), applied structurally and in memory, with a manifest."""
import collections
import json
import os
import re
import socket

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
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
        n = 0
        out, k = EMAIL_RE.subn("<email>", out); n += k
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_redact.py' -v`
Expected: all `ok`. If `test_identity_fields_get_typed_placeholders` fails on `contact_email`, the `endswith("email")` branch is misordered relative to `k in IDENTITY_KEYS`; keep the order shown.

- [ ] **Step 5: Commit**

```bash
git add Tools/probe/redact.py Tools/probe/tests/test_redact.py
git commit -m "feat(probe): structural redaction rules with manifest, hard scanners and report-only scanners"
```

### Task 3: The harness — launch line, redact-then-capture, correlation, policies, MCP mini-server

**Files:**
- Create: `Tools/probe/harness.py`
- Create: `Tools/probe/tests/stand_in.py` (a scripted protocol stand-in; the tests launch it as the "binary")
- Test: `Tools/probe/tests/test_harness.py`

**Interfaces:**
- Consumes: from Task 2: `redact.Redactor`, `.redact_frame(frame, direction, request_subtypes)`; from Task 1: `census.request_subtypes` is not used here (the harness keeps its own map).
- Produces: `harness.Launch` dataclass with `argv()` and `environment(base=None)`; `harness.DEFAULT_ENV_TABLE`, `harness.INITIALIZE`, `harness.SCRATCH_CONFIG_HOME`; `harness.Session(launch, redactor, initialize=None, declared_dialog_kinds=None, spill_after=5000)` with `start(timeout=30) -> dict` (the initialize response body), `send_user(text, uuid=None) -> str`, `request(subtype, timeout=30, **payload) -> dict` (the `response` object: `{"subtype": "success"|"error", "request_id", "response"|"error"}`), `answer(request_id, response=None, error=None)`, `on(subtype, policy)` where policy is `"allow"`, `"deny"`, `"leave"` or a callable `frame -> dict | None`, `wait_for(pred, timeout) -> dict`, `wait_result(timeout=120) -> dict`, `frames() -> list[dict]` (captured `{"t","dir","frame"}` or tombstones, in order), `system_init` property, `close(end_session=True) -> int`; `harness.MCPServer(tools, cwd)` with `handle(message) -> dict | None`; `harness.SEND_USER_FILE_TOOL`.

- [ ] **Step 1: Write the protocol stand-in used by the tests**

`Tools/probe/tests/stand_in.py` — a fake `claude` that speaks just enough stream-json for the harness tests. It reads stdin lines, answers `initialize`, and on the first `user` frame runs the features named in `STAND_IN_FEATURES` (comma-separated) in order, then emits a `result`. It never touches any config home.

```python
#!/usr/bin/env python3
"""Scripted stream-json stand-in for harness tests. Features via STAND_IN_FEATURES."""
import json
import os
import sys
import threading
import time
import uuid

FEATURES = [f for f in os.environ.get("STAND_IN_FEATURES", "").split(",") if f]
inbox = []
lock = threading.Condition()


def emit(frame):
    sys.stdout.write(json.dumps(frame) + "\n")
    sys.stdout.flush()


def reader():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except ValueError:
            continue
        with lock:
            inbox.append(m)
            lock.notify_all()
    with lock:
        inbox.append({"type": "__eof__"})
        lock.notify_all()


def wait(pred, timeout=10):
    deadline = time.time() + timeout
    with lock:
        while True:
            for m in inbox:
                if pred(m):
                    return m
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            lock.wait(remaining)


def response_to(rid, timeout=10):
    return wait(lambda m: m.get("type") == "control_response" and (m.get("response") or {}).get("request_id") == rid, timeout)


def control_request(subtype, **payload):
    rid = str(uuid.uuid4())
    req = {"subtype": subtype}
    req.update(payload)
    emit({"type": "control_request", "request_id": rid, "request": req})
    return rid


def main():
    if "--version" in sys.argv:
        print("2.1.259 (Claude Code)"); return 0
    if "--help" in sys.argv:
        print("Options:\n  -p, --print  x\n  --input-format <f>  y\n  --permission-prompt-tool <t>  z\n"); return 0
    threading.Thread(target=reader, daemon=True).start()
    init = wait(lambda m: m.get("type") == "control_request" and (m.get("request") or {}).get("subtype") == "initialize", 10)
    if init is None:
        return 4
    emit({"type": "control_response", "response": {"subtype": "success", "request_id": init["request_id"],
          "response": {"commands": [], "agents": [], "models": [], "output_style": "default", "account": {"email": "real@example.com"},
                       "current_model": "haiku", "current_permission_mode": "default", "session_state": "idle", "pid": os.getpid()}}})
    user = wait(lambda m: m.get("type") == "user", 20)
    if user is None:
        return 0
    sid = str(uuid.uuid4())
    emit({"type": "system", "subtype": "init", "session_id": sid, "cwd": os.getcwd(), "tools": ["Bash", "mcp__afleet__send_user_file"],
          "capabilities": ["interrupt_receipt_v1"], "claude_code_version": "2.1.259", "apiKeySource": "none", "uuid": str(uuid.uuid4())})
    for feature in FEATURES:
        if feature == "permission":
            rid = control_request("can_use_tool", tool_name="Write", input={"file_path": "x.txt", "content": "hi"}, tool_use_id="tu1")
            r = response_to(rid)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "permission", "behavior": ((r or {}).get("response") or {}).get("response", {}).get("behavior")})
        elif feature == "unknown":
            rid = control_request("bogus_probe_request", payload=1)
            r = response_to(rid)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "unknown", "error": (r or {}).get("response", {}).get("error")})
        elif feature == "dialog":
            rid = control_request("request_user_dialog", dialog_kind="not_declared_kind", payload={})
            r = response_to(rid, timeout=1.5)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "dialog", "answered": r is not None})
            emit({"type": "control_cancel_request", "request_id": rid})
        elif feature == "mcp":
            for msg in ({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "stand-in", "version": "0"}}},
                        {"jsonrpc": "2.0", "method": "notifications/initialized"},
                        {"jsonrpc": "2.0", "id": 2, "method": "ping"},
                        {"jsonrpc": "2.0", "id": 3, "method": "tools/list"},
                        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "send_user_file", "arguments": {"files": ["a.txt", "b.txt"], "caption": "two", "status": "normal"}}},
                        {"jsonrpc": "2.0", "id": 5, "method": "nope/method"}):
                rid = control_request("mcp_message", server_name="afleet", message=msg)
                r = response_to(rid)
                emit({"type": "system", "subtype": "stand_in_saw", "what": "mcp", "id": msg.get("id"), "mcp_response": ((r or {}).get("response") or {}).get("response", {}).get("mcp_response")})
        elif feature == "envvars":
            rid = control_request("update_environment_variables", variables={"SECRET_KEY": "s3cret"})
            response_to(rid)
        elif feature == "hook":
            rid = control_request("hook_callback", callback_id="afleet.notification", input={"message": "hello", "notification_type": "idle"})
            r = response_to(rid)
            emit({"type": "system", "subtype": "stand_in_saw", "what": "hook", "response": ((r or {}).get("response") or {}).get("response")})
        elif feature == "ignore_end_session":
            pass
        elif feature == "leak":
            emit({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "token sk-ant-api03-LEAKLEAK and mail leak@example.com"}]}, "uuid": str(uuid.uuid4())})
    emit({"type": "result", "subtype": "success", "result": "done", "num_turns": 1, "session_id": sid, "uuid": str(uuid.uuid4())})
    # end-of-session behaviour
    end = wait(lambda m: m.get("type") == "__eof__" or (m.get("type") == "control_request" and (m.get("request") or {}).get("subtype") == "end_session"), 30)
    if end and end.get("type") == "control_request":
        if "ignore_end_session" in FEATURES:
            wait(lambda m: m.get("type") == "__eof__", 30)
            time.sleep(30)  # keep living until a signal arrives
        else:
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": end["request_id"], "response": {}}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Run `chmod +x Tools/probe/tests/stand_in.py`.

- [ ] **Step 2: Write the failing harness tests**

`Tools/probe/tests/test_harness.py`:

```python
import json
import os
import sys
import tempfile
import time
import unittest
import _paths  # noqa: F401
import harness
import redact

STAND_IN = os.path.join(os.path.dirname(__file__), "stand_in.py")


def make_launch(tmp, **kw):
    args = dict(binary=sys.executable, binary_args=[STAND_IN], cwd=tmp, session_id="11111111-1111-4111-8111-111111111111",
                config_home=None, max_turns=2)
    args.update(kw)
    return harness.Launch(**args)


class LaunchTests(unittest.TestCase):
    def test_argv_matches_the_parent_launch_line_in_order(self):
        l = harness.Launch(binary="claude", cwd="/tmp/x", session_id="s", model="haiku", permission_mode="default", max_turns=3)
        self.assertEqual(l.argv(), [
            "claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
            "--permission-prompt-tool", "stdio", "--permission-prompts", "host",
            "--session-id", "s", "--model", "haiku", "--permission-mode", "default",
            "--enable-auth-status", "--session-mirror", "--setting-sources", "", "--strict-mcp-config", "--max-turns", "3"])

    def test_resume_fork_and_optional_flags(self):
        l = harness.Launch(binary="claude", cwd="/tmp/x", resume="r", fork=True, agent="Explore", effort="low", name="n",
                           add_dirs=["/a"], worktree="wt", allow_bypass=True, prompt_suggestions=True,
                           setting_sources=None, strict_mcp_config=False, extra_flags=["--foo"])
        a = l.argv()
        for seq in (["--resume", "r", "--fork-session"], ["--agent", "Explore"], ["--effort", "low"], ["-n", "n"], ["--add-dir", "/a"],
                    ["-w", "wt"], ["--allow-dangerously-skip-permissions"], ["--prompt-suggestions", "true"], ["--foo"]):
            i = a.index(seq[0]); self.assertEqual(a[i:i + len(seq)], seq)
        self.assertNotIn("--setting-sources", a); self.assertNotIn("--strict-mcp-config", a)

    def test_refuses_a_line_without_the_stdio_prompt_tool(self):
        with self.assertRaises(ValueError):
            harness.Launch(binary="claude", cwd="/tmp/x", session_id="s", extra_flags=["--permission-prompt-tool", "none"]).argv()

    def test_environment_applies_the_table_and_strips_forbidden_variables(self):
        base = {"PATH": "/bin", "CLAUDE_CODE_REMOTE": "1", "CLAUDE_CODE_CONTAINER_ID": "c", "CLAUDE_CODE_ENTRYPOINT": "cli", "HOME": "/Users/probe"}
        env = harness.Launch(binary="claude", cwd="/tmp/x", session_id="s", config_home="/tmp/ch").environment(base)
        for k, v in harness.DEFAULT_ENV_TABLE.items():
            self.assertEqual(env[k], v)
        self.assertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/ch")
        for k in ("CLAUDE_CODE_REMOTE", "CLAUDE_CODE_CONTAINER_ID", "CLAUDE_CODE_ENTRYPOINT"):
            self.assertNotIn(k, env)
        self.assertEqual(env["PATH"], "/bin")


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="afleet-harness-")
        self.redactor = redact.Redactor(home="/Users/probe", hostname="probe-mac")

    def run_session(self, features, **kw):
        os.environ["STAND_IN_FEATURES"] = ",".join(features)
        s = harness.Session(make_launch(self.tmp, **kw), self.redactor)
        init = s.start(timeout=10)
        self.assertEqual(init["current_model"], "haiku")
        return s

    def test_handshake_user_turn_and_capture_order(self):
        s = self.run_session([])
        s.send_user("hello")
        res = s.wait_result(timeout=10)
        self.assertEqual(res["subtype"], "success")
        self.assertEqual(s.system_init["claude_code_version"], "2.1.259")
        code = s.close()
        self.assertEqual(code, 0)
        kinds = [(c["dir"], c["frame"]["type"]) for c in s.frames() if "frame" in c]
        self.assertEqual(kinds[0], ("in", "control_request"))          # initialize
        self.assertEqual(kinds[1], ("out", "control_response"))
        self.assertIn(("in", "user"), kinds); self.assertIn(("out", "result"), kinds)
        ts = [c["t"] for c in s.frames()]
        self.assertEqual(ts, sorted(ts)); self.assertEqual(ts[0], 0)

    def test_capture_is_redacted_before_it_is_stored(self):
        s = self.run_session(["leak"])
        s.send_user("hi"); s.wait_result(10); s.close()
        blob = json.dumps(s.frames())
        self.assertNotIn("sk-ant-api03", blob); self.assertNotIn("leak@example.com", blob); self.assertNotIn("real@example.com", blob)
        self.assertIn("<email>", blob)

    def test_allow_deny_and_script_policies(self):
        s = self.run_session(["permission"])
        s.send_user("go"); s.wait_result(10); s.close()
        saw = [c["frame"] for c in s.frames() if c.get("frame", {}).get("subtype") == "stand_in_saw"]
        self.assertEqual(saw[0]["behavior"], "allow")
        s = self.run_session(["permission"]); s.on("can_use_tool", "deny")
        s.send_user("go"); s.wait_result(10); s.close()
        saw = [c["frame"] for c in s.frames() if c.get("frame", {}).get("subtype") == "stand_in_saw"]
        self.assertEqual(saw[0]["behavior"], "deny")
        s = self.run_session(["permission"])
        s.on("can_use_tool", lambda f: {"behavior": "allow", "updatedInput": {"file_path": "y.txt", "content": "changed"}})
        s.send_user("go"); s.wait_result(10); s.close()
        answers = [c["frame"] for c in s.frames() if c["dir"] == "out" and c.get("frame", {}).get("type") == "control_response"]
        self.assertTrue(any(((a["response"].get("response") or {}).get("updatedInput") or {}).get("content") == "changed" for a in answers))

    def test_unknown_request_gets_the_immediate_error_and_undeclared_dialog_is_left(self):
        s = self.run_session(["unknown", "dialog"])
        s.send_user("go"); s.wait_result(10); s.close()
        saw = {c["frame"]["what"]: c["frame"] for c in s.frames() if c.get("frame", {}).get("subtype") == "stand_in_saw"}
        self.assertEqual(saw["unknown"]["error"], "subtype bogus_probe_request not supported by afleet %s" % harness.VERSION)
        self.assertFalse(saw["dialog"]["answered"])
        cancels = [c for c in s.frames() if c.get("frame", {}).get("type") == "control_cancel_request"]
        self.assertEqual(len(cancels), 1)

    def test_mcp_server_answers_the_five_methods_and_notifications(self):
        open(os.path.join(self.tmp, "a.txt"), "w").write("A"); open(os.path.join(self.tmp, "b.txt"), "w").write("B")
        s = self.run_session(["mcp"])
        s.send_user("go"); s.wait_result(10); s.close()
        seen = {c["frame"]["id"]: c["frame"]["mcp_response"] for c in s.frames() if c.get("frame", {}).get("what") == "mcp"}
        self.assertEqual(seen[1]["result"]["serverInfo"]["name"], "afleet")
        self.assertEqual(seen[None], {"jsonrpc": "2.0", "result": {}, "id": 0})
        self.assertEqual(seen[2]["result"], {})
        tools = seen[3]["result"]["tools"]; self.assertEqual(tools[0]["name"], "send_user_file")
        self.assertEqual(tools[0]["inputSchema"]["required"], ["files", "status"])
        self.assertIn("a.txt", seen[4]["result"]["content"][0]["text"]); self.assertIn("b.txt", seen[4]["result"]["content"][0]["text"])
        self.assertEqual(seen[5]["error"]["code"], -32601)

    def test_hook_callback_default_answer(self):
        s = self.run_session(["hook"])
        s.send_user("go"); s.wait_result(10); s.close()
        saw = [c["frame"] for c in s.frames() if c.get("frame", {}).get("what") == "hook"][0]
        self.assertEqual(saw["response"], {"continue": True})

    def test_update_environment_variables_becomes_a_tombstone_and_its_answer_is_not_captured(self):
        s = self.run_session(["envvars"])
        s.send_user("go"); s.wait_result(10); s.close()
        blob = json.dumps(s.frames())
        self.assertNotIn("s3cret", blob)
        tomb = [c for c in s.frames() if c.get("dropped") == "update_environment_variables"]
        self.assertEqual(len(tomb), 1); self.assertIn("request_id", tomb[0])
        rid = tomb[0]["request_id"]
        self.assertFalse(any(c.get("frame", {}).get("response", {}).get("request_id") == rid for c in s.frames()))

    def test_request_round_trip_and_close_sequence_with_a_stubborn_child(self):
        s = self.run_session(["ignore_end_session"])
        s.send_user("go"); s.wait_result(10)
        t0 = time.time(); code = s.close(); dt = time.time() - t0
        self.assertIn(code, (-15, 143))           # SIGTERM after the 5 s end_session wait
        self.assertGreaterEqual(dt, 5.0); self.assertLess(dt, 11.0)

    def test_spill_keeps_order_and_content(self):
        s = self.run_session(["leak", "leak"], )
        s.spill_after = 3
        s.send_user("hi"); s.wait_result(10); s.close()
        fr = s.frames()
        self.assertGreater(len(fr), 3)
        self.assertEqual([c["t"] for c in fr], sorted(c["t"] for c in fr))
        self.assertTrue(all("frame" in c or "dropped" in c for c in fr))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_harness.py' -v`
Expected: `ModuleNotFoundError: No module named 'harness'`.

- [ ] **Step 4: Implement `Tools/probe/harness.py`**

```python
"""Launch line, redact-then-capture, control correlation, answer policies, MCP mini-server (spec §4.3)."""
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field

VERSION = "0.1"
SCRATCH_CONFIG_HOME = "/tmp/afleet-fixtures/config-home"
DEFAULT_ENV_TABLE = {
    "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING": "1",
    "CLAUDE_AUTO_BACKGROUND_TASKS": "1",
    "CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK": "1",
    "CLAUDE_CODE_FORK_SUBAGENT": "1",
}
FORBIDDEN_ENV = ("CLAUDE_CODE_REMOTE", "CLAUDE_CODE_CONTAINER_ID", "CLAUDE_CODE_ENTRYPOINT")
INITIALIZE = {
    "subtype": "initialize",
    "supportedDialogKinds": ["refusal_fallback_prompt", "fable_overage_consent_prompt"],
    "perTaskStopAffordance": True,
    "agentProgressSummaries": True,
    "sdkMcpServers": ["afleet"],
    "sdkMcpServerConfigs": {"afleet": {}},
    "hooks": {"Notification": [{"hookCallbackIds": ["afleet.notification"]}],
              "ConfigChange": [{"hookCallbackIds": ["afleet.config-change"]}]},
}
SEND_USER_FILE_TOOL = {
    "name": "send_user_file",
    "description": "Send one or more files to the user.",
    "inputSchema": {"type": "object",
                    "properties": {"files": {"type": "array", "items": {"type": "string"}},
                                   "caption": {"type": "string"},
                                   "status": {"type": "string", "enum": ["normal", "proactive"]},
                                   "display": {"type": "string", "enum": ["render", "attach"]}},
                    "required": ["files", "status"]},
}


@dataclass
class Launch:
    binary: str = "claude"
    binary_args: list = field(default_factory=list)   # placed right after binary (tests use it for the stand-in script)
    cwd: str = "."
    session_id: str = None
    resume: str = None
    fork: bool = False
    model: str = "haiku"
    permission_mode: str = "default"
    agent: str = None
    effort: str = None
    name: str = None
    add_dirs: list = field(default_factory=list)
    worktree: str = None              # None | "" (bare -w) | "<name>"
    allow_bypass: bool = False
    prompt_suggestions: bool = False
    setting_sources: str = ""         # None = omit the flag; "" = --setting-sources ""
    strict_mcp_config: bool = True
    max_turns: int = None
    extra_flags: list = field(default_factory=list)
    env_table: dict = field(default_factory=lambda: dict(DEFAULT_ENV_TABLE))
    config_home: str = SCRATCH_CONFIG_HOME   # None = inherit the real one

    def argv(self):
        a = [self.binary] + list(self.binary_args) + [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--forward-subagent-text", "--include-hook-events",
            "--permission-prompt-tool", "stdio", "--permission-prompts", "host"]
        if self.resume:
            a += ["--resume", self.resume] + (["--fork-session"] if self.fork else [])
        elif self.session_id:
            a += ["--session-id", self.session_id]
        for flag, val in (("--model", self.model), ("--permission-mode", self.permission_mode), ("--agent", self.agent),
                          ("--effort", self.effort), ("-n", self.name)):
            if val:
                a += [flag, val]
        for d in self.add_dirs:
            a += ["--add-dir", d]
        if self.worktree is not None:
            a += ["-w"] + ([self.worktree] if self.worktree else [])
        if self.allow_bypass:
            a += ["--allow-dangerously-skip-permissions"]
        a += ["--enable-auth-status", "--session-mirror"]
        if self.prompt_suggestions:
            a += ["--prompt-suggestions", "true"]
        if self.setting_sources is not None:
            a += ["--setting-sources", self.setting_sources]
        if self.strict_mcp_config:
            a += ["--strict-mcp-config"]
        if self.max_turns is not None:
            a += ["--max-turns", str(self.max_turns)]
        a += list(self.extra_flags)
        if "--permission-prompt-tool" in self.extra_flags:
            i = self.extra_flags.index("--permission-prompt-tool")
            if self.extra_flags[i + 1:i + 2] != ["stdio"]:
                raise ValueError("the launch line must keep --permission-prompt-tool stdio")
        return a

    def environment(self, base=None):
        env = dict(os.environ if base is None else base)
        for k in FORBIDDEN_ENV:
            env.pop(k, None)
        env.update(self.env_table)
        if self.config_home:
            env["CLAUDE_CONFIG_DIR"] = self.config_home
        return env


class MCPServer:
    """Minimal JSON-RPC 2.0 server for the in-process `afleet` MCP server."""
    def __init__(self, cwd, tools=None):
        self.cwd = cwd
        self.tools = tools or [SEND_USER_FILE_TOOL]
        self.calls = []

    def handle(self, msg):
        method, mid = msg.get("method"), msg.get("id")
        if "id" not in msg:                      # notification
            return {"jsonrpc": "2.0", "result": {}, "id": 0}
        if method == "initialize":
            return {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                                                            "serverInfo": {"name": "afleet", "version": VERSION}}}
        if method == "ping":
            return {"jsonrpc": "2.0", "id": mid, "result": {}}
        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": mid, "result": {"tools": self.tools}}
        if method == "tools/call":
            params = msg.get("params") or {}
            if params.get("name") != "send_user_file":
                return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown tool %s" % params.get("name")}}
            args = params.get("arguments") or {}
            files = args.get("files") or []
            missing = [f for f in files if not os.path.isfile(os.path.join(self.cwd, f))]
            self.calls.append(args)
            if missing:
                return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "missing: %s" % ", ".join(missing)}], "isError": True}}
            text = "sent %d file(s) to the user: %s" % (len(files), ", ".join(files))
            if args.get("caption"):
                text += " (caption: %s)" % args["caption"]
            return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}]}}
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found: %s" % method}}


class Session:
    def __init__(self, launch, redactor, initialize=None, declared_dialog_kinds=None, spill_after=5000):
        self.launch = launch
        self.redactor = redactor
        self.initialize = dict(INITIALIZE if initialize is None else initialize)
        self.declared = set(declared_dialog_kinds if declared_dialog_kinds is not None else self.initialize.get("supportedDialogKinds", []))
        self.spill_after = spill_after
        self.policies = {"can_use_tool": "allow"}
        self.mcp = MCPServer(launch.cwd)
        self._capture = []           # in-memory redacted records
        self._spool = None           # (path, fh) once spilled
        self._spooled = 0
        self._lock = threading.Condition()
        self._t0 = None
        self._pending = {}           # outbound request_id -> subtype
        self._responses = {}         # outbound request_id -> response object
        self._dropped_ids = set()
        self._raw_frames = []        # redacted decoded frames for wait_for (same objects as capture)
        self._inbound_subtypes = {}  # CLI-originated request_id -> subtype (for the redactor's rule lookup)
        self._eof = False
        self._wait_cursor = 0
        self.system_init = None
        self.proc = None
        self._stderr = []

    # ---- capture
    def _now_ms(self):
        if self._t0 is None:
            self._t0 = time.monotonic()
        return int((time.monotonic() - self._t0) * 1000)

    def _record(self, direction, frame):
        rs = dict(self._pending)
        rs.update(self._inbound_subtypes)
        red = self.redactor.redact_frame(frame, direction, rs)
        t = self._now_ms()
        if red is None:
            rid = frame.get("request_id")
            self._dropped_ids.add(rid)
            rec = {"t": t, "dir": direction, "dropped": (frame.get("request") or {}).get("subtype"), "request_id": rid}
        elif frame.get("type") == "control_response" and (frame.get("response") or {}).get("request_id") in self._dropped_ids:
            return None
        else:
            rec = {"t": t, "dir": direction, "frame": red}
        with self._lock:
            self._capture.append(rec)
            if len(self._capture) > self.spill_after:
                self._spill_locked()
            self._lock.notify_all()
        return red

    def _spill_locked(self):
        if self._spool is None:
            d = tempfile.mkdtemp(prefix="afleet-spool-")
            os.chmod(d, 0o700)
            path = os.path.join(d, "capture.ndjson")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            self._spool = (path, os.fdopen(fd, "w"))
        for rec in self._capture:
            self._spool[1].write(json.dumps(rec) + "\n")
        self._spool[1].flush()
        self._spooled += len(self._capture)
        self._capture = []

    def frames(self):
        with self._lock:
            out = []
            if self._spool is not None:
                self._spool[1].flush()
                with open(self._spool[0]) as fh:
                    out = [json.loads(l) for l in fh if l.strip()]
            return out + list(self._capture)

    # ---- process
    def start(self, timeout=30):
        self.proc = subprocess.Popen(self.launch.argv(), cwd=self.launch.cwd, env=self.launch.environment(),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._stderr_reader, daemon=True).start()
        rid = "init-1"
        self._send({"type": "control_request", "request_id": rid, "request": self.initialize}, subtype="initialize", rid=rid)
        resp = self._wait_response(rid, timeout)
        if resp is None:
            raise RuntimeError("initialize timed out; stderr: %s" % "".join(self._stderr)[-2000:])
        if resp.get("subtype") != "success":
            raise RuntimeError("initialize failed: %s" % resp.get("error"))
        return resp.get("response") or {}

    def _send(self, frame, subtype=None, rid=None):
        if rid and subtype:
            self._pending[rid] = subtype
        self._record("in", frame)
        line = json.dumps(frame) + "\n"
        self.proc.stdin.write(line)
        self.proc.stdin.flush()

    def _stderr_reader(self):
        for line in self.proc.stderr:
            self._stderr.append(line)

    def _reader(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                frame = json.loads(line)
            except ValueError:
                frame = {"type": "__unparseable__", "raw": line}
            if frame.get("type") == "control_request":
                self._inbound_subtypes[frame.get("request_id")] = (frame.get("request") or {}).get("subtype")
            red = self._record("out", frame)
            if red is not None:
                with self._lock:
                    self._raw_frames.append(red)
                    if red.get("type") == "system" and red.get("subtype") == "init":
                        self.system_init = red
                    if red.get("type") == "control_response":
                        self._responses[(red.get("response") or {}).get("request_id")] = red["response"]
                    self._lock.notify_all()
            if frame.get("type") == "control_request":
                threading.Thread(target=self._dispatch, args=(frame,), daemon=True).start()
        with self._lock:
            self._eof = True
            self._lock.notify_all()

    # ---- inbound policy
    def on(self, subtype, policy):
        self.policies[subtype] = policy

    def _dispatch(self, frame):
        req = frame.get("request") or {}
        sub = req.get("subtype")
        rid = frame.get("request_id")
        policy = self.policies.get(sub)
        try:
            if sub == "mcp_message":
                self.answer(rid, {"mcp_response": self.mcp.handle(req.get("message") or {})}); return
            if sub == "request_user_dialog" and req.get("dialog_kind") not in self.declared and policy is None:
                return                                    # left for the CLI's deadline (parent §6.3)
            if sub == "hook_callback" and policy is None:
                self.answer(rid, {"continue": True}); return
            if policy is None and sub not in ("can_use_tool", "elicitation", "request_user_dialog", "hook_callback"):
                self.answer(rid, error="subtype %s not supported by afleet %s" % (sub, VERSION)); return   # the parent §6.3 string, verbatim
            if policy == "leave":
                return
            if policy == "allow" or (policy is None and sub == "can_use_tool"):
                self.answer(rid, {"behavior": "allow", "updatedInput": req.get("input", {})}); return
            if policy == "deny":
                self.answer(rid, {"behavior": "deny", "message": "denied by the probe scenario"}); return
            if callable(policy):
                resp = policy(frame)
                if resp is not None:
                    self.answer(rid, resp)
                return
            self.answer(rid, error="subtype %s not supported by afleet %s" % (sub, VERSION))
        except Exception as e:  # never leave a request unanswered because the policy crashed
            self.answer(rid, error="probe policy failed: %s" % e)

    def answer(self, request_id, response=None, error=None):
        body = {"subtype": "error", "request_id": request_id, "error": error} if error is not None else \
               {"subtype": "success", "request_id": request_id, "response": response if response is not None else {}}
        self._send({"type": "control_response", "response": body})

    # ---- outbound
    def send_user(self, text, uuid_=None):
        u = uuid_ or str(uuid.uuid4())
        self._send({"type": "user", "uuid": u, "parent_tool_use_id": None, "origin": {"kind": "human"},
                    "message": {"role": "user", "content": text}})
        return u

    def request_async(self, subtype, **payload):
        rid = str(uuid.uuid4())
        req = {"subtype": subtype}
        req.update(payload)
        self._send({"type": "control_request", "request_id": rid, "request": req}, subtype=subtype, rid=rid)
        return rid

    def wait_response(self, rid, timeout=30):
        return self._wait_response(rid, timeout)

    def cancel(self, rid):
        """Cancel one of our own outbound requests (recorded as an `in` control_cancel_request)."""
        self._send({"type": "control_cancel_request", "request_id": rid})

    def request(self, subtype, timeout=30, **payload):
        rid = self.request_async(subtype, **payload)
        resp = self._wait_response(rid, timeout)
        if resp is None:
            raise TimeoutError("no response to %s within %ss" % (subtype, timeout))
        return resp

    def _wait_response(self, rid, timeout):
        deadline = time.time() + timeout
        with self._lock:
            while rid not in self._responses:
                remaining = deadline - time.time()
                if remaining <= 0 or (self._eof and self.proc.poll() is not None):
                    return None
                self._lock.wait(min(remaining, 0.5))
            return self._responses[rid]

    def wait_for(self, pred, timeout=60):
        """The next frame matching pred that arrived after the previous match (a cursor, so two
        wait_result() calls return two different results)."""
        deadline = time.time() + timeout
        with self._lock:
            while True:
                for i in range(self._wait_cursor, len(self._raw_frames)):
                    if pred(self._raw_frames[i]):
                        self._wait_cursor = i + 1
                        return self._raw_frames[i]
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                self._lock.wait(min(remaining, 0.5))

    def wait_result(self, timeout=120):
        return self.wait_for(lambda f: f.get("type") == "result", timeout)

    # ---- shutdown (parent §6.7)
    def close(self, end_session=True):
        if self.proc is None:
            return None
        if self.proc.poll() is None and end_session:
            try:
                self._send({"type": "control_request", "request_id": "end-1", "request": {"subtype": "end_session"}}, "end_session", "end-1")
            except (BrokenPipeError, OSError):
                pass
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        for sig in (None, signal.SIGTERM, signal.SIGKILL):
            if sig is not None and self.proc.poll() is None:
                self.proc.send_signal(sig)
            try:
                self.proc.wait(timeout=5)
                break
            except subprocess.TimeoutExpired:
                continue
        return self.proc.returncode

    def stderr_tail(self, n=2000):
        return "".join(self._stderr)[-n:]
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_harness.py' -v`
Expected: all `ok`; the stubborn-child test takes about six seconds. If `test_handshake_user_turn_and_capture_order` sees the first capture as `("in","control_request")` but `t != 0`, the clock started before the first record: `_now_ms` must set `_t0` on the first call only (as written).

- [ ] **Step 6: Run both Python versions**

Run: `/opt/homebrew/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_*.py'`
Expected: `OK`.

- [ ] **Step 7: Commit**

```bash
git add Tools/probe/harness.py Tools/probe/tests/stand_in.py Tools/probe/tests/test_harness.py
git commit -m "feat(probe): session harness with redact-then-capture, answer policies, MCP mini-server and the shutdown sequence"
```

### Task 4: Fixture layout and the verifier

**Files:**
- Create: `Tools/probe/fixture.py`
- Create: `Tools/probe/verify.py`
- Test: `Tools/probe/tests/test_fixture_verify.py`

**Interfaces:**
- Consumes: from Task 1: `census.census`, `census.diff`, `census.request_subtypes`; from Task 2: `redact.Redactor`, `redact.scan`, `redact.scan_report_only`.
- Produces: `fixture.SLUG_TOKEN`, `fixture.ARTIFACT_TOKEN`, `fixture.slug_of(cwd) -> str`, `fixture.find_session(config_home, session_id) -> (slug, projects_dir)`, `fixture.snapshot(config_home, session_id, dest_dir, redactor) -> dict[relpath, size]`, `fixture.stream_sizes(initial_dir) -> dict[relpath, int]`, `fixture.collect_artifacts(frames, records_dirs, dest_dir, uid=None) -> dict[abs_path, token_path]`, `fixture.tokenise(obj, mapping) -> obj`, `fixture.write_fixture(fixtures_root, name, meta, frames, census_obj, manifest, initial_dir, transcript_dir, artifacts_dir) -> str`, `fixture.load(path) -> dict` with keys `meta, frames, census, streams, path`; `verify.verify_fixture(path, home=None, author=None) -> (errors, warnings)`.

- [ ] **Step 1: Write the failing tests**

`Tools/probe/tests/test_fixture_verify.py`:

```python
import json
import os
import shutil
import tempfile
import unittest
import _paths  # noqa: F401
import census
import fixture
import redact
import verify

SID = "22222222-2222-4222-8222-222222222222"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


def fake_config_home(root, cwd="/private/tmp/afleet-fixtures/demo"):
    slug = fixture.slug_of(cwd)
    base = os.path.join(root, "projects", slug)
    write(os.path.join(base, SID + ".jsonl"), json.dumps({"type": "user", "uuid": "u1", "cwd": cwd, "message": {"role": "user", "content": "hi a@b.c"}}) + "\n")
    write(os.path.join(base, SID, "subagents", "agent-x.jsonl"), json.dumps({"type": "assistant", "uuid": "a1"}) + "\n")
    write(os.path.join(base, SID, "subagents", "agent-x.meta.json"), json.dumps({"agentType": "Explore"}))
    return slug


def build_fixture(root, name="demo", **overrides):
    """A tiny valid fixture: one host request answered, one CLI request answered, one cancelled."""
    frames = [
        {"t": 0, "dir": "in", "frame": {"type": "control_request", "request_id": "init-1", "request": {"subtype": "initialize"}}},
        {"t": 5, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "init-1", "response": {"commands": []}}}},
        {"t": 10, "dir": "in", "frame": {"type": "user", "uuid": "u1", "message": {"role": "user", "content": "hi"}}},
        {"t": 20, "dir": "out", "frame": {"type": "system", "subtype": "init", "capabilities": ["x"], "session_id": SID}},
        {"t": 30, "dir": "out", "frame": {"type": "control_request", "request_id": "c1", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {}}}},
        {"t": 40, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}}},
        {"t": 50, "dir": "out", "frame": {"type": "control_request", "request_id": "d1", "request": {"subtype": "request_user_dialog", "dialog_kind": "zzz"}}},
        {"t": 60, "dir": "out", "frame": {"type": "control_cancel_request", "request_id": "d1"}},
        {"t": 70, "dir": "out", "frame": {"type": "transcript_mirror", "filePath": "~/.claude/projects/_slug_/%s.jsonl" % SID, "entries": [{"type": "assistant", "uuid": "a2"}]}},
        {"t": 80, "dir": "out", "frame": {"type": "system", "subtype": "task_notification", "output_file": "<artifacts>/_slug_/%s/tasks/t1.output" % SID}},
        {"t": 90, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "done"}},
    ]
    c = census.census([f["frame"] for f in frames], help_text="  --foo  x\n", version="2.1.259")
    meta = {"name": name, "purpose": "test", "recorded_at": "2026-09-04T00:00:00Z", "cli_version": "2.1.259",
            "launch": {"argv": ["claude", "-p"], "env": {"CLAUDE_CODE_FORK_SUBAGENT": "1"}}, "prompts": ["hi"], "serves": ["item 1"],
            "census": True, "deterministic": True, "synthetic": False, "hypothesis": False, "late_responses": [],
            "review": {"reviewer": "kimmi", "date": "2026-09-04", "checklist_version": 1}}
    meta.update(overrides)
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, "initial"), exist_ok=True)
    os.makedirs(os.path.join(d, "transcript", "_slug_"), exist_ok=True)
    os.makedirs(os.path.join(d, "artifacts", "_slug_", SID, "tasks"), exist_ok=True)
    write(os.path.join(d, "fixture.json"), json.dumps(meta, indent=1))
    with open(os.path.join(d, "frames.ndjson"), "w") as fh:
        for f in frames:
            fh.write(json.dumps(f) + "\n")
    write(os.path.join(d, "census.json"), json.dumps(c))
    write(os.path.join(d, "redaction.json"), json.dumps({"rules": {}}))
    write(os.path.join(d, "streams.json"), json.dumps({"_slug_/%s.jsonl" % SID: 0}))
    write(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), json.dumps({"type": "assistant", "uuid": "a2"}) + "\n")
    write(os.path.join(d, "artifacts", "_slug_", SID, "tasks", "t1.output"), "bg-done\n")
    return d


class SlugAndSnapshotTests(unittest.TestCase):
    def test_slug_of_replaces_every_non_alphanumeric(self):
        self.assertEqual(fixture.slug_of("/Users/new/Developer/GitHub/afleet"), "-Users-new-Developer-GitHub-afleet")
        self.assertEqual(fixture.slug_of("/private/tmp/afleet-fixtures/x.y"), "-private-tmp-afleet-fixtures-x-y")

    def test_find_and_snapshot_redacts_and_rewrites_the_slug(self):
        home = tempfile.mkdtemp(); dest = tempfile.mkdtemp()
        slug = fake_config_home(home)
        self.assertEqual(fixture.find_session(home, SID)[0], slug)
        sizes = fixture.snapshot(home, SID, dest, redact.Redactor(home="/Users/probe", hostname="probe-mac"))
        self.assertEqual(sorted(sizes), ["_slug_/%s.jsonl" % SID, "_slug_/%s/subagents/agent-x.jsonl" % SID, "_slug_/%s/subagents/agent-x.meta.json" % SID])
        text = open(os.path.join(dest, "_slug_", SID + ".jsonl")).read()
        self.assertIn("<email>", text); self.assertNotIn("a@b.c", text)
        # the source tree is untouched
        self.assertIn("a@b.c", open(os.path.join(home, "projects", slug, SID + ".jsonl")).read())
        self.assertEqual(fixture.stream_sizes(dest)["_slug_/%s.jsonl" % SID], sizes["_slug_/%s.jsonl" % SID])

    def test_collect_artifacts_and_tokenise(self):
        art_src = tempfile.mkdtemp(); dest = tempfile.mkdtemp()
        out = os.path.join(art_src, "claude-501", "-slug", SID, "tasks", "t9.output")
        write(out, "hello\n")
        binary = os.path.join(art_src, "claude-501", "-slug", SID, "tasks", "t10.output")
        os.makedirs(os.path.dirname(binary), exist_ok=True); open(binary, "wb").write(b"\xff\xfe\x00 not utf-8")
        write(out, "hello leak@example.com\n")
        frames = [{"type": "system", "subtype": "task_notification", "output_file": out}, {"type": "system", "subtype": "task_notification", "output_file": binary}]
        r = redact.Redactor(home="/Users/probe", hostname="probe-mac")
        mapping = fixture.collect_artifacts(frames, [], dest, r, task_root=os.path.join(art_src, "claude-501"))
        self.assertEqual(mapping[out], "<artifacts>/-slug/%s/tasks/t9.output" % SID)
        self.assertEqual(open(os.path.join(dest, "-slug", SID, "tasks", "t9.output")).read(), "hello <email>\n")
        self.assertEqual(json.load(open(os.path.join(dest, "-slug", SID, "tasks", "t10.output")))["omitted"], "binary artifact")
        self.assertEqual(fixture.tokenise(frames, mapping)[0]["output_file"], "<artifacts>/-slug/%s/tasks/t9.output" % SID)


class WriteAndLoadTests(unittest.TestCase):
    def test_write_is_atomic_and_load_round_trips(self):
        root = tempfile.mkdtemp(); src = build_fixture(tempfile.mkdtemp())
        loaded = fixture.load(src)
        path = fixture.write_fixture(root, "copy", loaded["meta"], loaded["frames"], loaded["census"], {"rules": {}},
                                     os.path.join(src, "initial"), os.path.join(src, "transcript"), os.path.join(src, "artifacts"))
        self.assertEqual(path, os.path.join(root, "copy"))
        self.assertEqual(sorted(os.listdir(root)), ["copy"])  # no temp dir left behind
        again = fixture.load(path)
        self.assertEqual(again["frames"], loaded["frames"]); self.assertEqual(again["meta"]["name"], "copy")


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="afleet-fx-")

    def errors(self, path):
        e, w = verify.verify_fixture(path, home="/Users/probe", author="Probe Person")
        return e

    def test_valid_fixture_passes(self):
        self.assertEqual(self.errors(build_fixture(self.root)), [])

    def test_unsigned_review_fails(self):
        d = build_fixture(self.root, review={"reviewer": "", "date": "", "checklist_version": 1})
        self.assertTrue(any("review" in e for e in self.errors(d)))

    def test_planted_email_fails_in_any_file(self):
        d = build_fixture(self.root)
        with open(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), "a") as fh:
            fh.write(json.dumps({"type": "user", "message": {"content": "write to someone@example.org"}}) + "\n")
        self.assertTrue(any("email" in e for e in self.errors(d)))

    def test_orphaned_request_fails(self):
        d = build_fixture(self.root)
        with open(os.path.join(d, "frames.ndjson"), "a") as fh:
            fh.write(json.dumps({"t": 95, "dir": "out", "frame": {"type": "control_request", "request_id": "c9", "request": {"subtype": "can_use_tool"}}}) + "\n")
        self.assertTrue(any("c9" in e and "unanswered" in e for e in self.errors(d)))

    def test_cancelled_then_late_needs_the_late_responses_entry(self):
        d = build_fixture(self.root)
        with open(os.path.join(d, "frames.ndjson"), "a") as fh:
            fh.write(json.dumps({"t": 95, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "d1", "response": {}}}}) + "\n")
        self.assertTrue(any("d1" in e and "late" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2", late_responses=["d1"])
        with open(os.path.join(d2, "frames.ndjson"), "a") as fh:
            fh.write(json.dumps({"t": 95, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "d1", "response": {}}}}) + "\n")
        self.assertEqual(self.errors(d2), [])

    def test_tombstone_is_skipped_by_the_lifecycle_check(self):
        d = build_fixture(self.root)
        with open(os.path.join(d, "frames.ndjson"), "a") as fh:
            fh.write(json.dumps({"t": 95, "dir": "out", "dropped": "update_environment_variables", "request_id": "e1"}) + "\n")
        self.assertEqual(self.errors(d), [])

    def test_missing_artifact_and_bad_stream_offset_fail(self):
        d = build_fixture(self.root)
        os.remove(os.path.join(d, "artifacts", "_slug_", SID, "tasks", "t1.output"))
        self.assertTrue(any("artifacts" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2")
        write(os.path.join(d2, "streams.json"), json.dumps({"_slug_/%s.jsonl" % SID: 999}))
        self.assertTrue(any("streams.json" in e for e in self.errors(d2)))

    def test_census_mismatch_fails_and_required_mode_tolerates_optional_keys(self):
        d = build_fixture(self.root)
        c = json.load(open(os.path.join(d, "census.json"))); c["pairs"]["system/init"]["keys"].append("ghost")
        write(os.path.join(d, "census.json"), json.dumps(c))
        self.assertTrue(any("census" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2", deterministic=False)
        c2 = json.load(open(os.path.join(d2, "census.json"))); c2["pairs"]["system/init"]["keys"].append("optional_key")
        write(os.path.join(d2, "census.json"), json.dumps(c2))
        self.assertEqual(self.errors(d2), [])

    def test_hypothesis_requires_synthetic_and_synthetic_skips_census_recount(self):
        d = build_fixture(self.root, hypothesis=True, synthetic=False)
        self.assertTrue(any("hypothesis" in e for e in self.errors(d)))
        d2 = build_fixture(self.root, name="demo2", hypothesis=True, synthetic=True, census=False)
        self.assertEqual(self.errors(d2), [])

    def test_mirror_entries_must_reproduce_the_transcript(self):
        d = build_fixture(self.root)
        with open(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), "a") as fh:
            fh.write(json.dumps({"type": "assistant", "uuid": "not-mirrored"}) + "\n")
        self.assertTrue(any("mirror entries" in e for e in self.errors(d)))

    def test_report_only_warning_for_author_name(self):
        d = build_fixture(self.root)
        with open(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"), "a") as fh:
            fh.write(json.dumps({"type": "user", "message": {"content": "by Probe Person"}}) + "\n")
        e, w = verify.verify_fixture(d, home="/Users/probe", author="Probe Person")
        self.assertEqual(e, []); self.assertTrue(any("author" in x for x in w))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_fixture_verify.py' -v`
Expected: `ModuleNotFoundError: No module named 'fixture'`.

- [ ] **Step 3: Implement `Tools/probe/fixture.py`**

```python
"""Fixture layout (contract X8, spec §4.4): snapshot, streams, artifacts, atomic assembly, load."""
import glob
import json
import os
import re
import shutil
import tempfile

SLUG_TOKEN = "_slug_"
ARTIFACT_TOKEN = "<artifacts>"
REQUIRED_FILES = ("fixture.json", "frames.ndjson", "census.json", "redaction.json", "streams.json")


def slug_of(cwd):
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def find_session(config_home, session_id):
    hits = glob.glob(os.path.join(config_home, "projects", "*", session_id + ".jsonl"))
    if not hits:
        raise FileNotFoundError("no transcript for %s under %s/projects" % (session_id, config_home))
    slug = os.path.basename(os.path.dirname(hits[0]))
    return slug, os.path.join(config_home, "projects")


def _session_files(projects_dir, slug, session_id):
    base = os.path.join(projects_dir, slug)
    rel = []
    for p in glob.glob(os.path.join(base, session_id + "*")):
        if os.path.isfile(p):
            rel.append(os.path.relpath(p, projects_dir))
        elif os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in files:
                    rel.append(os.path.relpath(os.path.join(root, f), projects_dir))
    return sorted(rel)


def _redact_file(src, dest, redactor):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(src, "rb") as fh:
        raw = fh.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        with open(dest, "wb") as out:
            out.write(raw)
        return
    if src.endswith(".jsonl"):
        lines = []
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                lines.append(json.dumps(redactor.redact_json(json.loads(line))))
            except ValueError:
                lines.append(redactor.redact_text(line))
        text = "\n".join(lines) + ("\n" if lines else "")
    else:
        try:
            text = json.dumps(redactor.redact_json(json.loads(text)))
        except ValueError:
            text = redactor.redact_text(text)
    with open(dest, "w") as out:
        out.write(text)


def snapshot(config_home, session_id, dest_dir, redactor):
    """Copy (never move) the session's transcript files, redacted, with the slug rewritten."""
    slug, projects_dir = find_session(config_home, session_id)
    sizes = {}
    for rel in _session_files(projects_dir, slug, session_id):
        token_rel = rel.replace(slug, SLUG_TOKEN, 1)
        dest = os.path.join(dest_dir, token_rel)
        _redact_file(os.path.join(projects_dir, rel), dest, redactor)
        sizes[token_rel] = os.path.getsize(dest)
    return sizes


def stream_sizes(initial_dir):
    out = {}
    for root, _, files in os.walk(initial_dir):
        for f in files:
            p = os.path.join(root, f)
            out[os.path.relpath(p, initial_dir)] = os.path.getsize(p)
    return out


def _strings(obj):
    if isinstance(obj, dict):
        for v in obj.values():
            for s in _strings(v):
                yield s
    elif isinstance(obj, list):
        for v in obj:
            for s in _strings(v):
                yield s
    elif isinstance(obj, str):
        yield obj


def default_task_root():
    return "/private/tmp/claude-%d" % os.getuid()


def collect_artifacts(frames, record_dirs, dest_dir, redactor, task_root=None):
    """Copy files under the CLI's task root that frames or records name, redacted in memory before the
    first write; a file that is not UTF-8 is replaced by a JSON stub naming its size (no binary bytes are
    stored). Returns abs -> token path."""
    task_root = task_root or default_task_root()
    candidates = set()
    for f in frames:
        for s in _strings(f):
            if s.startswith(task_root) or s.startswith(task_root.replace("/private/tmp", "/tmp")):
                candidates.add(s)
    for d in record_dirs:
        for root, _, files in os.walk(d):
            for name in files:
                with open(os.path.join(root, name), errors="replace") as fh:
                    for line in fh:
                        for m in re.finditer(re.escape(task_root) + r"[^\s\"']+", line):
                            candidates.add(m.group(0))
    mapping = {}
    for path in sorted(candidates):
        real = path.replace("/tmp/claude-", "/private/tmp/claude-", 1) if path.startswith("/tmp/") else path
        if not os.path.isfile(real):
            continue
        rel = os.path.relpath(real, task_root)
        dest = os.path.join(dest_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(real, "rb") as fh:
            raw = fh.read()
        try:
            text = redactor.redact_text(raw.decode("utf-8"), path="artifacts/" + rel)
        except UnicodeDecodeError:
            text = json.dumps({"omitted": "binary artifact", "bytes": len(raw)})
        with open(dest, "w") as out:
            out.write(text)
        mapping[path] = ARTIFACT_TOKEN + "/" + rel
    return mapping


def tokenise(obj, mapping):
    if not mapping:
        return obj
    if isinstance(obj, dict):
        return {k: tokenise(v, mapping) for k, v in obj.items()}
    if isinstance(obj, list):
        return [tokenise(v, mapping) for v in obj]
    if isinstance(obj, str):
        for k in sorted(mapping, key=len, reverse=True):
            if k in obj:
                obj = obj.replace(k, mapping[k])
        return obj
    return obj


def write_fixture(fixtures_root, name, meta, frames, census_obj, manifest, initial_dir, transcript_dir, artifacts_dir):
    os.makedirs(fixtures_root, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".tmp-%s-" % name, dir=fixtures_root)
    try:
        with open(os.path.join(tmp, "fixture.json"), "w") as fh:
            json.dump(meta, fh, indent=1, sort_keys=True)
        with open(os.path.join(tmp, "frames.ndjson"), "w") as fh:
            for rec in frames:
                fh.write(json.dumps(rec) + "\n")
        with open(os.path.join(tmp, "census.json"), "w") as fh:
            json.dump(census_obj, fh, indent=1, sort_keys=True)
        with open(os.path.join(tmp, "redaction.json"), "w") as fh:
            json.dump(manifest, fh, indent=1, sort_keys=True)
        for sub, src in (("initial", initial_dir), ("transcript", transcript_dir), ("artifacts", artifacts_dir)):
            dst = os.path.join(tmp, sub)
            if src and os.path.isdir(src):
                shutil.copytree(src, dst)
            else:
                os.makedirs(dst)
        with open(os.path.join(tmp, "streams.json"), "w") as fh:
            json.dump(stream_sizes(os.path.join(tmp, "initial")), fh, indent=1, sort_keys=True)
        dest = os.path.join(fixtures_root, name)
        old = None
        if os.path.exists(dest):
            old = tempfile.mkdtemp(prefix=".old-%s-" % name, dir=fixtures_root)
            os.rmdir(old)
            os.rename(dest, old)
        os.rename(tmp, dest)
        if old:
            shutil.rmtree(old)
        return dest
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


def load(path):
    with open(os.path.join(path, "fixture.json")) as fh:
        meta = json.load(fh)
    frames = []
    with open(os.path.join(path, "frames.ndjson")) as fh:
        for line in fh:
            if line.strip():
                frames.append(json.loads(line))
    with open(os.path.join(path, "census.json")) as fh:
        c = json.load(fh)
    with open(os.path.join(path, "streams.json")) as fh:
        streams = json.load(fh)
    return {"path": path, "meta": meta, "frames": frames, "census": c, "streams": streams}
```

- [ ] **Step 4: Implement `Tools/probe/verify.py`**

```python
"""Fixture verification (spec §4.2 `verify`): structure, lifecycle, redaction, review block."""
import json
import os

import census
import fixture
import redact

REVIEW_KEYS = ("reviewer", "date", "checklist_version")


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


def verify_fixture(path, home=None, author=None):
    errors, warnings = [], []
    home = home or os.path.expanduser("~")
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
        recount["flags"] = fx["census"].get("flags"); recount["version"] = fx["census"].get("version")
        drift = census.diff(fx["census"], recount, "exact" if meta.get("deterministic") else "required")
        if drift:
            errors.append("census.json does not match a recount: %s" % "; ".join(drift))
    # artifacts tokens
    art_dir = os.path.join(path, "artifacts")
    needed = set()
    for rec in frames:
        for s in fixture._strings(rec):
            if fixture.ARTIFACT_TOKEN in s:
                needed.add(s.split(fixture.ARTIFACT_TOKEN + "/", 1)[1].split('"')[0])
    for fpath in _walk_files(os.path.join(path, "transcript")):
        with open(fpath, errors="replace") as fh:
            for line in fh:
                if fixture.ARTIFACT_TOKEN in line:
                    for part in line.split(fixture.ARTIFACT_TOKEN + "/")[1:]:
                        needed.add(part.split('"')[0].split("'")[0].split()[0])
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
            head = [json.loads(l) for l in open(init_path) if l.strip()] if os.path.isfile(init_path) else []
            want = head + entries
            got = [json.loads(l) for l in open(final_path) if l.strip()]
            if got != want:
                errors.append("mirror entries for %s do not reproduce transcript/%s (%d mirrored + %d initial vs %d records)" % (stream, stream, len(entries), len(head), len(got)))
    # streams offsets
    initial_sizes = fixture.stream_sizes(os.path.join(path, "initial"))
    for stream, off in fx["streams"].items():
        if off > initial_sizes.get(stream, 0):
            errors.append("streams.json offset for %s exceeds the file under initial/" % stream)
    for stream, size in initial_sizes.items():
        tpath = os.path.join(path, "transcript", stream)
        if os.path.isfile(tpath):
            with open(os.path.join(path, "initial", stream), "rb") as a, open(tpath, "rb") as b:
                if not b.read().startswith(a.read()):
                    errors.append("transcript/%s does not extend initial/%s" % (stream, stream))
    # redaction scan on every file
    for fpath in _walk_files(path):
        rel = os.path.relpath(fpath, path)
        try:
            text = open(fpath, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        objs = []
        if fpath.endswith((".json", ".jsonl", ".ndjson")):
            for line in (text.splitlines() if fpath.endswith((".jsonl", ".ndjson")) else [text]):
                if line.strip():
                    try:
                        objs.append(json.loads(line))
                    except ValueError:
                        objs.append(line)
        else:
            objs.append(text)
        for o in objs:
            for hit in redact.scan(o, home):
                errors.append("%s: %s" % (rel, hit))
        for w in redact.scan_report_only(text, author, home):
            warnings.append("%s: %s" % (rel, w))
    return errors, warnings
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_fixture_verify.py' -v`
Expected: all `ok`. Then `make test-tools` → all green on 3.9; `PYTHON=/opt/homebrew/bin/python3 make test-tools` → green on 3.14.

- [ ] **Step 6: Commit**

```bash
git add Tools/probe/fixture.py Tools/probe/verify.py Tools/probe/tests/test_fixture_verify.py
git commit -m "feat(probe): fixture layout with initial/streams/artifacts and a verifier with lifecycle, census and redaction checks"
```

### Task 5: The `probe.py` CLI, scenario loader, zero-cost scenario and the no-unredacted-byte property

**Files:**
- Create: `Tools/probe/probe.py`
- Create: `Tools/probe/scenarios/zero_cost.py`
- Test: `Tools/probe/tests/test_probe_cli.py`

**Interfaces:**
- Consumes: Task 1 `census`, Task 2 `redact`, Task 3 `harness.Launch/Session/SCRATCH_CONFIG_HOME`, Task 4 `fixture`, `verify`.
- Produces: the CLI `probe.py {census|diff|record|snapshot|redact|verify}`; the scenario contract: a module under the scenario directory exposing `META` (dict) and `run(session, ctx)`; `probe.load_scenario(name, scenario_dir=None)`; `probe.record(name, claude, scenario_dir=None, fixtures_root="Fixtures", config_home=None, reviewer=None) -> (fixture_path, verify_errors)`; `probe.claude_version(binary_argv)`, `probe.claude_help(binary_argv)`; environment `AFLEET_CLAUDE_BINARY`, `AFLEET_SCENARIO_DIR`, `AFLEET_FIXTURES_ROOT`.

**Scenario contract (used by Tasks 8–11):**

```python
META = {
    "name": "plain-two-turn",            # fixture directory name
    "purpose": "two short prompts, no tools",
    "serves": ["item 1", "item 2", "item 31", "item 56", "C3.G1"],
    "census": True,                      # participates in `diff`
    "deterministic": False,              # exact vs required-shape comparison
    "isolation": "config-home",          # or "setting"
    "launch": {"max_turns": 2},          # Launch(...) overrides; "binary_args" allowed
    "prompts": ["Reply with exactly: one", "Reply with exactly: two"],
    "resume_of": None,                   # fixture name whose session this scenario resumes
    "setup": None,                       # optional callable(scratch_cwd) creating synthetic files
    "spikes": [],                        # spike ids this scenario informs
}

def run(session, ctx):
    """Drive the session. ctx: {"cwd", "config_home", "name", "meta", "notes": []}. Return nothing."""
```

- [ ] **Step 1: Write the failing CLI tests**

`Tools/probe/tests/test_probe_cli.py`:

```python
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import _paths  # noqa: F401
import probe

STAND_IN = os.path.join(os.path.dirname(__file__), "stand_in.py")
SCENARIO_SRC = '''
import os
META = {"name": "%(name)s", "purpose": "cli test", "serves": ["test"], "census": True, "deterministic": True,
        "isolation": "config-home", "launch": {"binary_args": [%(stand_in)r], "max_turns": 2},
        "prompts": ["hello"], "resume_of": None, "setup": None, "spikes": []}

def run(session, ctx):
    session.send_user("hello")
    session.wait_result(20)
    ctx["notes"].append("ran")
'''


class RecordAndDiffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="afleet-cli-")
        self.scenarios = os.path.join(self.tmp, "scenarios"); os.makedirs(self.scenarios)
        self.fixtures = os.path.join(self.tmp, "Fixtures")
        self.config_home = os.path.join(self.tmp, "config-home"); os.makedirs(self.config_home)
        with open(os.path.join(self.scenarios, "cli_demo.py"), "w") as fh:
            fh.write(SCENARIO_SRC % {"name": "cli-demo", "stand_in": STAND_IN})
        os.environ["STAND_IN_FEATURES"] = "leak,permission,envvars"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_record_no_unredacted_byte_reaches_disk_and_review_is_unsigned(self):
        path, errors = probe.record("cli_demo", claude=sys.executable, scenario_dir=self.scenarios,
                                    fixtures_root=self.fixtures, config_home=self.config_home, scratch_root=self.tmp)
        self.assertEqual(path, os.path.join(self.fixtures, "cli-demo"))
        self.assertEqual([e for e in errors if "review" not in e], [])
        self.assertTrue(any("review" in e for e in errors))
        for root, _, files in os.walk(self.tmp):           # fixture, scratch cwd, scratch config home, everything
            for f in files:
                blob = open(os.path.join(root, f), "rb").read()
                self.assertNotIn(b"sk-ant-api03", blob, os.path.join(root, f))
                self.assertNotIn(b"leak@example.com", blob, os.path.join(root, f))
                self.assertNotIn(b"s3cret", blob, os.path.join(root, f))
        self.assertFalse(os.path.isdir(os.path.join(path, "raw")))
        self.assertFalse(any(n.startswith(".tmp-") for n in os.listdir(self.fixtures)))
        meta = json.load(open(os.path.join(path, "fixture.json")))
        self.assertEqual(meta["cli_version"], "2.1.259")
        self.assertEqual(sorted(meta["launch"]["env"]), sorted(probe.harness.DEFAULT_ENV_TABLE))
        self.assertIn("--permission-prompt-tool", meta["launch"]["argv"])
        self.assertEqual(meta["review"], {"reviewer": "", "date": "", "checklist_version": 1})

    def test_sign_then_verify_and_diff_against_the_same_binary_is_clean(self):
        path, _ = probe.record("cli_demo", claude=sys.executable, scenario_dir=self.scenarios,
                               fixtures_root=self.fixtures, config_home=self.config_home, scratch_root=self.tmp)
        probe.sign(path, reviewer="tester")
        self.assertEqual(probe.verify_paths([path])[0], 0)
        code, report = probe.diff(claude=sys.executable, scenario_dir=self.scenarios, fixtures_root=self.fixtures,
                                  config_home=self.config_home, scratch_root=self.tmp)
        self.assertEqual(code, 0, report)
        os.environ["STAND_IN_FEATURES"] = "leak,permission,envvars,hook"      # a new (type, subtype) pair appears
        code, report = probe.diff(claude=sys.executable, scenario_dir=self.scenarios, fixtures_root=self.fixtures,
                                  config_home=self.config_home, scratch_root=self.tmp)
        self.assertEqual(code, 1); self.assertIn("added pair", report)

    def test_main_usage_and_exit_codes(self):
        out = subprocess.run([sys.executable, os.path.join(probe.HERE, "probe.py")], capture_output=True, text=True)
        self.assertEqual(out.returncode, 2)


class ResumeResolutionTests(unittest.TestCase):
    def test_resolve_resume_reads_the_prior_fixture_for_record_diff_and_spike(self):
        root = tempfile.mkdtemp(); os.makedirs(os.path.join(root, "prior"))
        json.dump({"session_id": "prior-sid"}, open(os.path.join(root, "prior", "fixture.json"), "w"))
        self.assertEqual(probe.resolve_resume({"resume_of": "prior"}, root), "prior-sid")
        self.assertIsNone(probe.resolve_resume({"resume_of": None}, root))


class ZeroCostScenarioTests(unittest.TestCase):
    def test_zero_cost_scenario_loads_and_declares_the_requests(self):
        m = probe.load_scenario("zero_cost")
        self.assertEqual(m.META["name"], "zero-cost"); self.assertTrue(m.META["deterministic"])
        self.assertEqual(m.REQUESTS[0], ("get_context_usage", {}))
        self.assertIn(("list_models", {}), m.REQUESTS)
        self.assertNotIn("submit_feedback", [r[0] for r in m.REQUESTS])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_probe_cli.py' -v`
Expected: `ModuleNotFoundError: No module named 'probe'`.

- [ ] **Step 3: Write `Tools/probe/scenarios/zero_cost.py`**

```python
"""The zero-cost census: initialize plus the requests that spend no model tokens (probe 04)."""
REQUESTS = [
    ("get_context_usage", {}), ("get_session_cost", {}), ("get_binary_version", {}), ("mcp_status", {}),
    ("background_tasks", {}), ("get_settings", {}), ("get_usage", {}), ("list_models", {}), ("get_plan", {}),
    ("file_suggestions", {"query": ""}),
]
META = {"name": "zero-cost", "purpose": "initialize and the zero-cost control requests; the drift ritual's first line",
        "serves": ["item 32", "item 33", "S8"], "census": True, "deterministic": True, "isolation": "config-home",
        "launch": {"max_turns": 1}, "prompts": [], "resume_of": None, "setup": None, "spikes": ["S8"]}


def run(session, ctx):
    for subtype, payload in REQUESTS:
        resp = session.request(subtype, timeout=30, **payload)
        ctx["notes"].append("%s -> %s" % (subtype, resp.get("subtype")))
```

- [ ] **Step 4: Implement `Tools/probe/probe.py`**

```python
#!/usr/bin/env python3
"""probe: census | diff | record | snapshot | redact | verify (spec §4.2)."""
import argparse
import datetime
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census      # noqa: E402
import fixture     # noqa: E402
import harness     # noqa: E402
import redact      # noqa: E402
import verify      # noqa: E402

SCENARIO_DIR = os.environ.get("AFLEET_SCENARIO_DIR") or os.path.join(HERE, "scenarios")
FIXTURES_ROOT = os.environ.get("AFLEET_FIXTURES_ROOT") or os.path.abspath(os.path.join(HERE, "..", "..", "Fixtures"))
SCRATCH_ROOT = "/tmp/afleet-fixtures"


def log(msg):
    sys.stderr.write(msg + "\n")


def binary_argv(claude):
    return [os.environ.get("AFLEET_CLAUDE_BINARY") or claude or "claude"]


def tool_argv(claude, meta):
    """The binary plus a scenario's binary_args (tests point at a Python stand-in this way)."""
    return binary_argv(claude) + list((meta.get("launch") or {}).get("binary_args") or [])


def claude_version(argv):
    out = subprocess.run(argv + ["--version"], capture_output=True, text=True, timeout=30).stdout.strip()
    return out.split()[0] if out else ""


def claude_help(argv):
    return subprocess.run(argv + ["--help"], capture_output=True, text=True, timeout=30).stdout


def load_scenario(name, scenario_dir=None):
    path = os.path.join(scenario_dir or SCENARIO_DIR, name.replace("-", "_") + ".py")
    if not os.path.isfile(path):
        raise FileNotFoundError("no scenario %s (%s)" % (name, path))
    spec = importlib.util.spec_from_file_location("scenario_" + name.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def scenario_for_fixture(fixture_path, scenario_dir=None):
    meta = json.load(open(os.path.join(fixture_path, "fixture.json")))
    return load_scenario(meta.get("scenario") or meta["name"], scenario_dir), meta


def fresh_scratch(name, scratch_root=SCRATCH_ROOT):
    d = os.path.join(scratch_root, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    return d


def make_launch(meta, claude, cwd, config_home, resume=None):
    kw = dict(binary=binary_argv(claude)[0], cwd=cwd, config_home=config_home)
    kw.update(meta.get("launch") or {})
    if resume:
        kw["resume"] = resume
    else:
        kw.setdefault("session_id", str(uuid.uuid4()))
    return harness.Launch(**kw)


def resolve_config_home(meta, config_home):
    if config_home is not None:
        return config_home
    return harness.SCRATCH_CONFIG_HOME if meta.get("isolation", "config-home") == "config-home" else None


def run_scenario(mod, claude, config_home, scratch_root, redactor, resume=None, initial_dir=None):
    meta = mod.META
    cwd = os.path.join(scratch_root, meta["resume_of"]) if meta.get("resume_of") else fresh_scratch(meta["name"], scratch_root)
    if callable(meta.get("setup")):
        meta["setup"](cwd)
    launch = make_launch(meta, claude, cwd, resolve_config_home(meta, config_home), resume=resume)
    session = harness.Session(launch, redactor)
    ctx = {"cwd": cwd, "config_home": launch.config_home, "name": meta["name"], "meta": meta, "notes": [], "launch": launch}
    session.start(timeout=60)
    try:
        mod.run(session, ctx)
    finally:
        code = session.close(end_session=not meta.get("keep_open"))
    ctx["exit_code"] = code
    ctx["stderr_tail"] = session.stderr_tail()
    return session, ctx


def resolve_resume(meta, fixtures_root):
    """The session id a scenario resumes, from the fixture named by META['resume_of'] (None when it resumes nothing)."""
    if not meta.get("resume_of"):
        return None
    prior = json.load(open(os.path.join(fixtures_root or FIXTURES_ROOT, meta["resume_of"], "fixture.json")))
    return prior["session_id"]


def session_id_of(session, launch):
    if session.system_init and session.system_init.get("session_id"):
        return session.system_init["session_id"]
    return launch.resume or launch.session_id


def record(name, claude, scenario_dir=None, fixtures_root=None, config_home=None, scratch_root=SCRATCH_ROOT, reviewer=None):
    fixtures_root = fixtures_root or FIXTURES_ROOT
    mod = load_scenario(name, scenario_dir)
    meta = dict(mod.META)
    redactor = redact.Redactor()
    argv = tool_argv(claude, meta)
    version, help_text = claude_version(argv), claude_help(argv)
    work = tempfile.mkdtemp(prefix="afleet-record-")
    os.chmod(work, 0o700)
    initial_dir, transcript_dir, artifacts_dir = (os.path.join(work, d) for d in ("initial", "transcript", "artifacts"))
    for d in (initial_dir, transcript_dir, artifacts_dir):
        os.makedirs(d)
    ch = resolve_config_home(meta, config_home)
    resume = resolve_resume(meta, fixtures_root)
    if resume:
        fixture.snapshot(ch or os.path.expanduser("~/.claude"), resume, initial_dir, redactor)
    session, ctx = run_scenario(mod, claude, config_home, scratch_root, redactor, resume=resume)
    sid = session_id_of(session, ctx["launch"])
    frames = session.frames()
    try:
        fixture.snapshot(ctx["config_home"] or os.path.expanduser("~/.claude"), sid, transcript_dir, redactor)
    except FileNotFoundError as e:       # a stand-in writes no transcript; the real CLI always does
        ctx["notes"].append("no transcript to snapshot: %s" % e)
    mapping = fixture.collect_artifacts([r.get("frame") for r in frames if "frame" in r], [transcript_dir], artifacts_dir, redactor)
    if mapping:
        frames = fixture.tokenise(frames, mapping)
        for root, _, files in os.walk(transcript_dir):
            for f in files:
                p = os.path.join(root, f)
                text = open(p).read()
                for k, v in mapping.items():
                    text = text.replace(k, v)
                open(p, "w").write(text)
    c = census.census([r["frame"] for r in frames if "frame" in r], help_text=help_text, version=version)
    existing = os.path.join(fixtures_root, meta["name"], "census.json")
    if not meta.get("deterministic") and os.path.isfile(existing):
        c = census.merge_required(json.load(open(existing)), c)
    out_meta = {
        "name": meta["name"], "scenario": name, "purpose": meta.get("purpose"), "serves": meta.get("serves", []),
        "spikes": meta.get("spikes", []), "recorded_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cli_version": version, "session_id": sid, "cwd": ctx["cwd"],
        "launch": {"argv": ctx["launch"].argv(), "env": {k: v for k, v in ctx["launch"].env_table.items()}},
        "prompts": meta.get("prompts", []), "census": bool(meta.get("census", True)), "deterministic": bool(meta.get("deterministic")),
        "isolation": meta.get("isolation", "config-home"), "synthetic": False, "hypothesis": False,
        "late_responses": list(meta.get("late_responses", [])), "notes": ctx["notes"], "exit_code": ctx["exit_code"],
        "review": {"reviewer": reviewer or "", "date": datetime.date.today().isoformat() if reviewer else "", "checklist_version": 1},
    }
    out_meta = redactor.redact_json(out_meta)          # fixture.json is a redaction target too (spec §4.5)
    path = fixture.write_fixture(fixtures_root, meta["name"], out_meta, frames, c, redactor.manifest(), initial_dir, transcript_dir, artifacts_dir)
    shutil.rmtree(work, ignore_errors=True)
    errors, warnings = verify.verify_fixture(path)
    for w in warnings:
        log("warning: " + w)
    return path, errors


def sign(path, reviewer):
    p = os.path.join(path, "fixture.json")
    meta = json.load(open(p))
    meta["review"] = {"reviewer": reviewer, "date": datetime.date.today().isoformat(), "checklist_version": 1}
    with open(p, "w") as fh:
        json.dump(meta, fh, indent=1, sort_keys=True)


def verify_paths(paths):
    failed, lines = 0, []
    for p in paths:
        errors, warnings = verify.verify_fixture(p.rstrip("/"))
        for e in errors:
            lines.append("%s: ERROR %s" % (p, e))
        for w in warnings:
            lines.append("%s: warning %s" % (p, w))
        if errors:
            failed += 1
    return failed, "\n".join(lines)


def diff(claude, scenario_dir=None, fixtures_root=None, config_home=None, scratch_root=SCRATCH_ROOT, only=None, script=None):
    fixtures_root = fixtures_root or FIXTURES_ROOT
    drifted, report = 0, []
    names = [only] if only else sorted(n for n in os.listdir(fixtures_root) if os.path.isfile(os.path.join(fixtures_root, n, "fixture.json")))
    for n in names:
        fpath = os.path.join(fixtures_root, n)
        mod, meta = scenario_for_fixture(fpath, scenario_dir)
        if not meta.get("census") or meta.get("synthetic"):
            continue
        env_backup = dict(os.environ)
        os.environ["FAKE_CLAUDE_FIXTURE"] = fpath
        if script:
            os.environ["FAKE_CLAUDE_SCRIPT"] = script
        os.environ.setdefault("FAKE_CLAUDE_SPEED", "0")
        try:
            argv = tool_argv(claude, mod.META)
            version, help_text = claude_version(argv), claude_help(argv)     # inside the env block so fake-claude answers from this fixture
            session, ctx = run_scenario(mod, claude, config_home, scratch_root, redact.Redactor(), resume=resolve_resume(meta, fixtures_root))
        finally:
            os.environ.clear(); os.environ.update(env_backup)
        observed = census.census([r["frame"] for r in session.frames() if "frame" in r], help_text=help_text, version=version)
        recorded = json.load(open(os.path.join(fpath, "census.json")))
        lines = census.diff(recorded, observed, "exact" if meta.get("deterministic") else "required")
        if lines:
            drifted += 1
            report.append("%s: DRIFT" % n); report += ["  " + l for l in lines]
        else:
            report.append("%s: ok" % n)
    return min(drifted, 125), "\n".join(report)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="probe")
    sub = ap.add_subparsers(dest="cmd")
    for name in ("census", "diff", "record", "snapshot", "redact", "verify"):
        sp = sub.add_parser(name)
        sp.add_argument("--claude", default=None)
        sp.add_argument("--config-home", default=None)
        if name == "census":
            sp.add_argument("--scenario", nargs="*", default=[])
        if name == "diff":
            sp.add_argument("--fixture", default=None); sp.add_argument("--script", default=None)
        if name == "record":
            sp.add_argument("scenario"); sp.add_argument("--reviewer", default=None)
        if name in ("snapshot", "redact"):
            sp.add_argument("fixture")
        if name == "verify":
            sp.add_argument("fixtures", nargs="+")
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_usage(); return 2
    if args.cmd == "census":
        out = {}
        for name in ["zero_cost"] + list(args.scenario):
            mod = load_scenario(name)
            argv_b = tool_argv(args.claude, mod.META)
            version, help_text = claude_version(argv_b), claude_help(argv_b)
            session, ctx = run_scenario(mod, args.claude, args.config_home, SCRATCH_ROOT, redact.Redactor(), resume=resolve_resume(mod.META, FIXTURES_ROOT))
            out[mod.META["name"]] = census.census([r["frame"] for r in session.frames() if "frame" in r], help_text=help_text, version=version)
        print(json.dumps(out, indent=1, sort_keys=True)); return 0
    if args.cmd == "diff":
        code, report = diff(args.claude, config_home=args.config_home, only=args.fixture, script=args.script)
        print(report); return code
    if args.cmd == "record":
        path, errors = record(args.scenario, args.claude, config_home=args.config_home, reviewer=args.reviewer)
        print("recorded %s" % path)
        real = [e for e in errors if "review" not in e]
        for e in errors:
            print(("ERROR " if e in real else "needs review: ") + e)
        return 1 if real else 0
    if args.cmd == "snapshot":
        meta = json.load(open(os.path.join(args.fixture, "fixture.json")))
        ch = args.config_home or (harness.SCRATCH_CONFIG_HOME if meta.get("isolation") == "config-home" else os.path.expanduser("~/.claude"))
        dest = os.path.join(args.fixture, "transcript")
        shutil.rmtree(dest, ignore_errors=True)
        fixture.snapshot(ch, meta["session_id"], dest, redact.Redactor()); return 0
    if args.cmd == "redact":
        r = redact.Redactor()
        fx = fixture.load(args.fixture)
        rs = census.request_subtypes([x["frame"] for x in fx["frames"] if "frame" in x])
        frames = []
        for rec in fx["frames"]:
            if "frame" in rec:
                red = r.redact_frame(rec["frame"], rec["dir"], rs)
                frames.append(dict(rec, frame=red) if red is not None else {"t": rec["t"], "dir": rec["dir"], "dropped": rec["frame"].get("request", {}).get("subtype"), "request_id": rec["frame"].get("request_id")})
            else:
                frames.append(rec)
        with open(os.path.join(args.fixture, "frames.ndjson"), "w") as fh:
            for rec in frames:
                fh.write(json.dumps(rec) + "\n")
        for sub in ("initial", "transcript", "artifacts"):
            d = os.path.join(args.fixture, sub)
            for root, _, files in os.walk(d):
                for f in files:
                    p = os.path.join(root, f); fixture._redact_file(p, p, r)
        with open(os.path.join(args.fixture, "redaction.json"), "w") as fh:
            json.dump(r.manifest(), fh, indent=1, sort_keys=True)
        return 0
    if args.cmd == "verify":
        failed, report = verify_paths(args.fixtures)
        if report:
            print(report)
        print("%d fixture(s) failed" % failed if failed else "all fixtures pass")
        return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_probe_cli.py' -v`
Expected: all `ok`. The record test asserts that no file under the whole temp tree carries the planted strings; if the scratch config home contains the stand-in's transcript, that is expected to be empty because the stand-in never writes one. Then `make test-tools` on both interpreters.

- [ ] **Step 6: Commit**

```bash
git add Tools/probe/probe.py Tools/probe/scenarios/zero_cost.py Tools/probe/tests/test_probe_cli.py
git commit -m "feat(probe): CLI with census, diff, record, snapshot, redact and verify; zero-cost scenario; no-unredacted-byte test"
```

### Task 6: fake-claude — reactive replay, duplex scripts, safe materialisation

**Files:**
- Create: `Tools/fake-claude/fake_claude.py`
- Create: `Tools/fake-claude/fake-claude` (executable wrapper)
- Create: `Tools/fake-claude/tests/_paths.py`
- Test: `Tools/fake-claude/tests/test_fake_claude.py`

**Interfaces:**
- Consumes: only the fixture format of Task 4 (files on disk); nothing imported from `Tools/probe`.
- Produces: the executable `Tools/fake-claude/fake-claude` honouring `FAKE_CLAUDE_FIXTURE`, `FAKE_CLAUDE_SPEED`, `FAKE_CLAUDE_SCRIPT`, `FAKE_CLAUDE_INIT`, `FAKE_CLAUDE_CONFIG_HOME`, `FAKE_CLAUDE_VERSION`; `--version`; `--help`; `materialize <fixture> <configHome> [--cwd <path>]`; module functions `fake_claude.slug_of(cwd)`, `fake_claude.materialize(fixture_dir, config_home, cwd) -> int`, `fake_claude.Replayer(fixture_dir, env, stdin, stdout, stderr).run() -> int`; exit codes 0 (done), 2 (usage or refusal), 3 (unexpected host traffic or expect timeout).

- [ ] **Step 1: Write the failing tests**

`Tools/fake-claude/tests/_paths.py`:

```python
import os, sys
TOOL_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if TOOL_DIR not in sys.path:
    sys.path.insert(0, TOOL_DIR)
```

`Tools/fake-claude/tests/test_fake_claude.py`:

```python
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import _paths  # noqa: F401
import fake_claude

EXE = os.path.join(_paths.TOOL_DIR, "fake-claude")
SID = "33333333-3333-4333-8333-333333333333"
REC_CWD = "/private/tmp/afleet-fixtures/tiny"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


def tiny_fixture(root):
    """Two turns: initialize, user -> system/init + assistant + mirror + result; host get_usage; user -> result; end_session."""
    d = os.path.join(root, "tiny")
    rec_slug = fake_claude.slug_of(REC_CWD)
    fp = "~/.claude/projects/%s/%s.jsonl" % (rec_slug, SID)
    frames = [
        {"t": 0, "dir": "in", "frame": {"type": "control_request", "request_id": "init-1", "request": {"subtype": "initialize"}}},
        {"t": 2, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "init-1", "response": {"commands": [], "current_model": "haiku"}}}},
        {"t": 10, "dir": "in", "frame": {"type": "user", "uuid": "u1", "message": {"role": "user", "content": "one"}}},
        {"t": 20, "dir": "out", "frame": {"type": "system", "subtype": "init", "session_id": SID, "capabilities": [], "cwd": REC_CWD}},
        {"t": 30, "dir": "out", "frame": {"type": "assistant", "uuid": "a1", "message": {"role": "assistant", "content": [{"type": "text", "text": "one"}]}}},
        {"t": 35, "dir": "out", "frame": {"type": "transcript_mirror", "filePath": fp, "entries": [{"type": "user", "uuid": "u1", "cwd": REC_CWD}, {"type": "assistant", "uuid": "a1"}]}},
        {"t": 40, "dir": "out", "frame": {"type": "control_request", "request_id": "c1", "request": {"subtype": "can_use_tool", "tool_name": "Write", "input": {}}}},
        {"t": 50, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}}},
        {"t": 55, "dir": "out", "frame": {"type": "system", "subtype": "task_notification", "output_file": "<artifacts>/%s/%s/tasks/t1.output" % (rec_slug, SID)}},
        {"t": 60, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "one"}},
        {"t": 70, "dir": "in", "frame": {"type": "control_request", "request_id": "h1", "request": {"subtype": "get_usage"}}},
        {"t": 75, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "h1", "response": {"session": {"total_cost_usd": 0}}}}},
        {"t": 80, "dir": "in", "frame": {"type": "user", "uuid": "u2", "message": {"role": "user", "content": "two"}}},
        {"t": 90, "dir": "out", "frame": {"type": "transcript_mirror", "filePath": fp, "entries": [{"type": "user", "uuid": "u2"}]}},
        {"t": 95, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": "two"}},
        {"t": 100, "dir": "in", "frame": {"type": "control_request", "request_id": "end-1", "request": {"subtype": "end_session"}}},
        {"t": 101, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "end-1", "response": {}}}},
    ]
    meta = {"name": "tiny", "cli_version": "2.1.259", "session_id": SID, "cwd": REC_CWD, "deterministic": False, "synthetic": False,
            "hypothesis": False, "late_responses": [], "launch": {"argv": [], "env": {}},
            "review": {"reviewer": "t", "date": "2026-09-04", "checklist_version": 1}}
    write(os.path.join(d, "fixture.json"), json.dumps(meta))
    with open(os.path.join(d, "frames.ndjson"), "w") as fh:
        for f in frames:
            fh.write(json.dumps(f) + "\n")
    write(os.path.join(d, "census.json"), json.dumps({"version": "2.1.259", "flags": ["--print", "--session-mirror"], "capabilities": [], "pairs": {}}))
    write(os.path.join(d, "redaction.json"), json.dumps({"rules": {}}))
    write(os.path.join(d, "initial", "_slug_", SID + ".jsonl"), json.dumps({"type": "summary", "cwd": REC_CWD}) + "\n")
    init_size = os.path.getsize(os.path.join(d, "initial", "_slug_", SID + ".jsonl"))
    write(os.path.join(d, "streams.json"), json.dumps({"_slug_/%s.jsonl" % SID: init_size}))
    write(os.path.join(d, "transcript", "_slug_", SID + ".jsonl"),
          json.dumps({"type": "summary", "cwd": REC_CWD}) + "\n" + json.dumps({"type": "user", "uuid": "u1", "cwd": REC_CWD}) + "\n" +
          json.dumps({"type": "assistant", "uuid": "a1"}) + "\n" + json.dumps({"type": "user", "uuid": "u2"}) + "\n")
    write(os.path.join(d, "artifacts", rec_slug, SID, "tasks", "t1.output"), "bg-done\n")   # artifacts keep the recorded slug, as collect_artifacts stores them
    return d


class Host:
    """Launches fake-claude like the app would and talks stream-json to it."""
    def __init__(self, fixture, cwd, env=None, argv_extra=()):
        env_all = dict(os.environ); env_all.update({"FAKE_CLAUDE_FIXTURE": fixture, "FAKE_CLAUDE_SPEED": "0"}); env_all.update(env or {})
        self.p = subprocess.Popen([EXE, "-p", "--output-format", "stream-json", "--session-id", SID] + list(argv_extra), cwd=cwd, env=env_all,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.frames, self.cond = [], threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            if line.strip():
                with self.cond:
                    self.frames.append(json.loads(line)); self.cond.notify_all()

    def send(self, frame):
        self.p.stdin.write(json.dumps(frame) + "\n"); self.p.stdin.flush()

    def wait(self, pred, timeout=5):
        deadline = time.time() + timeout
        with self.cond:
            while True:
                for f in self.frames:
                    if pred(f):
                        return f
                rem = deadline - time.time()
                if rem <= 0:
                    return None
                self.cond.wait(rem)

    def finish(self, timeout=5):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            return self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill(); return None


class VersionHelpTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(); self.fx = tiny_fixture(self.root)

    def test_version_and_help_come_from_the_fixture(self):
        env = dict(os.environ, FAKE_CLAUDE_FIXTURE=self.fx)
        self.assertEqual(subprocess.run([EXE, "--version"], capture_output=True, text=True, env=env).stdout.strip(), "2.1.259 (Claude Code)")
        env["FAKE_CLAUDE_VERSION"] = "9.9.9"
        self.assertEqual(subprocess.run([EXE, "--version"], capture_output=True, text=True, env=env).stdout.strip(), "9.9.9 (Claude Code)")
        out = subprocess.run([EXE, "--help"], capture_output=True, text=True, env=env).stdout
        self.assertIn("--session-mirror", out); self.assertIn("--print", out)


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(); self.fx = tiny_fixture(self.root); self.cwd = tempfile.mkdtemp()

    def test_reactive_order_blocking_and_request_id_substitution(self):
        h = Host(self.fx, self.cwd)
        h.send({"type": "control_request", "request_id": "my-init", "request": {"subtype": "initialize"}})
        r = h.wait(lambda f: f.get("type") == "control_response"); self.assertEqual(r["response"]["request_id"], "my-init")
        time.sleep(0.3); self.assertFalse(any(f.get("type") == "assistant" for f in h.frames))     # blocks on the user line
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "anything"}})
        req = h.wait(lambda f: f.get("type") == "control_request"); self.assertEqual(req["request_id"], "c1")
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "result"))
        h.send({"type": "control_request", "request_id": "zz", "request": {"subtype": "get_usage"}})
        r2 = h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "zz")
        self.assertEqual(r2["response"]["response"]["session"]["total_cost_usd"], 0)
        h.send({"type": "user", "uuid": "y", "message": {"role": "user", "content": "two"}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "result" and f.get("result") == "two"))
        h.send({"type": "control_request", "request_id": "e", "request": {"subtype": "end_session"}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "e"))
        self.assertEqual(h.finish(), 0)

    def test_leading_and_trailing_expects_fail_when_the_host_stays_silent(self):
        lead = os.path.join(self.root, "lead.json"); write(lead, json.dumps([{"expect": {"type": "control_request", "request.subtype": "get_usage"}, "timeout_ms": 500}]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": lead})
        self.assertEqual(h.finish(timeout=5), 3)                                    # nothing sent: leading expect times out
        trail = os.path.join(self.root, "trail.json"); write(trail, json.dumps([{"after": 999, "emit": {"type": "system", "subtype": "late"}}, {"expect": {"type": "user"}, "timeout_ms": 500}]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": trail})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        h.send({"type": "control_request", "request_id": "zz", "request": {"subtype": "get_usage"}}); h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "zz")
        h.send({"type": "user", "uuid": "y", "message": {"role": "user", "content": "two"}}); h.wait(lambda f: f.get("result") == "two")
        h.send({"type": "control_request", "request_id": "e", "request": {"subtype": "end_session"}})
        self.assertEqual(h.finish(timeout=5), 3)                                    # trailing emit fires at the end, then the expect times out

    def test_patch_step_removes_keys_from_matching_out_frames(self):
        script = os.path.join(self.root, "patch.json"); write(script, json.dumps([{"patch": {"type": "system", "subtype": "init"}, "remove": ["capabilities"]}]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": script})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        init = h.wait(lambda f: f.get("subtype") == "init"); self.assertNotIn("capabilities", init); h.finish()

    def test_unexpected_host_traffic_fails_with_exit_3_unless_a_rule_allows_it(self):
        h = Host(self.fx, self.cwd)
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "control_request", "request_id": "surprise", "request": {"subtype": "interrupt"}})
        self.assertEqual(h.finish(), 3)
        self.assertIn("unexpected", h.p.stderr.read())
        script = os.path.join(self.root, "rule.json"); write(script, json.dumps([{"rule": "generic-success", "subtypes": ["interrupt"]}]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": script})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "control_request", "request_id": "surprise", "request": {"subtype": "interrupt"}})
        r = h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "surprise")
        self.assertEqual(r["response"]["subtype"], "success"); h.finish()

    def test_script_emit_expect_answer(self):
        script = os.path.join(self.root, "s.json")
        write(script, json.dumps([
            {"after": 2, "emit": {"type": "afleet_invented", "x": 1}},
            {"after": 3, "emit": {"type": "control_request", "request_id": "inj-1", "request": {"subtype": "bogus_kind"}}},
            {"expect": {"type": "control_response", "request_id": "$last", "response.subtype": "error"}, "timeout_ms": 2000},
            {"answer": {"type": "system", "subtype": "stand_in_ack"}},
        ]))
        h = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": script})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "afleet_invented"))
        inj = h.wait(lambda f: f.get("type") == "control_request" and f["request_id"] == "inj-1"); self.assertIsNotNone(inj)
        h.send({"type": "control_response", "response": {"subtype": "error", "request_id": "inj-1", "error": "subtype bogus_kind not supported"}})
        self.assertIsNotNone(h.wait(lambda f: f.get("subtype") == "stand_in_ack"))
        # the recorded can_use_tool still follows and must be answered
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        self.assertIsNotNone(h.wait(lambda f: f.get("type") == "result")); h.finish()
        h2 = Host(self.fx, self.cwd, env={"FAKE_CLAUDE_SCRIPT": script})
        h2.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h2.wait(lambda f: f.get("type") == "control_response")
        h2.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        h2.wait(lambda f: f.get("type") == "control_request" and f["request_id"] == "inj-1")
        self.assertEqual(h2.finish(timeout=6), 3)                                   # expect timed out, host never answered


class MaterializeTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(); self.fx = tiny_fixture(self.root)
        self.fake_real_home = os.path.join(self.root, "real-claude"); os.makedirs(self.fake_real_home)
        self.env = dict(os.environ, CLAUDE_CONFIG_DIR=self.fake_real_home)

    def run_materialize(self, dest, cwd="/private/tmp/afleet-fixtures/tiny"):
        return subprocess.run([EXE, "materialize", self.fx, dest, "--cwd", cwd], capture_output=True, text=True, env=self.env)

    def test_refuses_the_real_home_a_symlink_into_it_and_unmarked_directories(self):
        self.assertEqual(self.run_materialize(self.fake_real_home).returncode, 2)
        link = os.path.join(self.root, "link"); os.symlink(self.fake_real_home, link)
        self.assertEqual(self.run_materialize(link).returncode, 2)
        unmarked = os.path.join(self.root, "unmarked"); os.makedirs(unmarked)
        self.assertEqual(self.run_materialize(unmarked).returncode, 2)
        self.assertEqual(os.listdir(unmarked), [])

    def test_creates_marks_lays_down_initial_state_and_refuses_an_existing_transcript(self):
        dest = os.path.realpath(os.path.join(self.root, "fake-home"))
        r = self.run_materialize(dest); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(dest, ".afleet-fake-home")))
        slug = fake_claude.slug_of("/private/tmp/afleet-fixtures/tiny")
        t = os.path.join(dest, "projects", slug, SID + ".jsonl")
        self.assertEqual(open(t).read().count("\n"), 1)
        self.assertEqual(self.run_materialize(dest).returncode, 2)               # transcript already there

    def test_nested_symlink_under_a_marked_home_is_refused_by_materialize_and_replay(self):
        dest = os.path.realpath(os.path.join(self.root, "fake-home")); elsewhere = os.path.join(self.root, "elsewhere"); os.makedirs(elsewhere)
        os.makedirs(dest); open(os.path.join(dest, fake_claude.MARKER), "w").close()
        os.symlink(elsewhere, os.path.join(dest, "projects"))
        self.assertEqual(self.run_materialize(dest).returncode, 2); self.assertEqual(os.listdir(elsewhere), [])
        os.unlink(os.path.join(dest, "projects")); r = self.run_materialize(dest, cwd="/private/tmp/afleet-fixtures/other-cwd"); self.assertEqual(r.returncode, 0)
        os.symlink(elsewhere, os.path.join(dest, "tasks"))                       # replay must refuse the artifact write
        h = Host(self.fx, tempfile.mkdtemp(), env={"FAKE_CLAUDE_CONFIG_HOME": dest, "FAKE_CLAUDE_CWD": "/private/tmp/afleet-fixtures/other-cwd"})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        self.assertEqual(h.finish(timeout=10), 2); self.assertEqual(os.listdir(elsewhere), [])

    def test_replay_with_config_home_reproduces_the_final_filesystem(self):
        dest = os.path.realpath(os.path.join(self.root, "fake-home")); cwd = "/private/tmp/afleet-fixtures/other-cwd"
        self.assertEqual(self.run_materialize(dest, cwd=cwd).returncode, 0)
        h = Host(self.fx, tempfile.mkdtemp(), env={"FAKE_CLAUDE_CONFIG_HOME": dest, "FAKE_CLAUDE_CWD": cwd})
        h.send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); h.wait(lambda f: f.get("type") == "control_response")
        h.send({"type": "user", "uuid": "x", "message": {"role": "user", "content": "one"}})
        mirror = h.wait(lambda f: f.get("type") == "transcript_mirror")
        slug = fake_claude.slug_of(cwd)
        self.assertEqual(mirror["filePath"], os.path.join(dest, "projects", slug, SID + ".jsonl"))
        notif = h.wait(lambda f: f.get("subtype") == "task_notification")
        self.assertTrue(notif["output_file"].startswith(os.path.join(dest, "tasks")))
        self.assertTrue(os.path.isfile(notif["output_file"]))
        h.send({"type": "control_response", "response": {"subtype": "success", "request_id": "c1", "response": {"behavior": "allow"}}})
        h.wait(lambda f: f.get("type") == "result")
        h.send({"type": "control_request", "request_id": "zz", "request": {"subtype": "get_usage"}}); h.wait(lambda f: f.get("type") == "control_response" and f["response"]["request_id"] == "zz")
        h.send({"type": "user", "uuid": "y", "message": {"role": "user", "content": "two"}}); h.wait(lambda f: f.get("result") == "two")
        h.finish()
        ok, report = fake_claude.compare_final_state(self.fx, dest, cwd)
        self.assertTrue(ok, report)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `/usr/bin/python3 -m unittest discover -s Tools/fake-claude/tests -t Tools/fake-claude/tests -p 'test_*.py' -v`
Expected: `ModuleNotFoundError: No module named 'fake_claude'`.

- [ ] **Step 3: Implement `Tools/fake-claude/fake_claude.py`**

```python
#!/usr/bin/env python3
"""fake-claude: replay a fixture reactively; duplex scripts; safe materialisation (spec §4.8)."""
import json
import os
import re
import sys
import threading
import time

MARKER = ".afleet-fake-home"
SLUG_TOKEN = "_slug_"
ARTIFACT_TOKEN = "<artifacts>"
EXIT_REFUSED = 2
EXIT_UNEXPECTED = 3


def slug_of(cwd):
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def load_fixture(d):
    meta = json.load(open(os.path.join(d, "fixture.json")))
    frames = [json.loads(l) for l in open(os.path.join(d, "frames.ndjson")) if l.strip()]
    cen = json.load(open(os.path.join(d, "census.json")))
    streams = json.load(open(os.path.join(d, "streams.json")))
    return meta, frames, cen, streams


def dumps(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


# ---------------------------------------------------------------- materialise
def _real(p):
    return os.path.realpath(os.path.expanduser(p))


def _within(child, parent):
    child, parent = _real(child), _real(parent)
    return child == parent or child.startswith(parent.rstrip("/") + "/")


def refusal_reason(dest, session_id, env=None):
    env = os.environ if env is None else env
    forbidden = [os.path.expanduser("~/.claude")]
    if env.get("CLAUDE_CONFIG_DIR"):
        forbidden.append(env["CLAUDE_CONFIG_DIR"])
    for f in forbidden:
        if _within(dest, f):
            return "destination %s resolves into the config home %s" % (dest, f)
    real = _real(dest)
    if os.path.lexists(dest) or os.path.exists(real):
        if not os.path.isdir(real):
            return "destination %s exists and is not a directory" % dest
        if not os.path.isfile(os.path.join(real, MARKER)):
            return "destination %s exists without the %s marker" % (dest, MARKER)
        for root, _, files in os.walk(os.path.join(real, "projects")):
            if session_id + ".jsonl" in files:
                return "destination already holds a transcript for %s" % session_id
    return None


def safe_path(root, rel):
    """A destination under root whose every component below root is a real directory, never a symlink;
    refused (returns None) when a component is a symlink or the resolved path leaves root."""
    root = _real(root)
    cur = root
    parts = [p for p in rel.split(os.sep) if p not in ("", ".")]
    if any(p == ".." for p in parts):
        return None
    for part in parts[:-1]:
        cur = os.path.join(cur, part)
        if os.path.islink(cur):
            return None
        if os.path.exists(cur) and not os.path.isdir(cur):
            return None
    final = os.path.join(cur, parts[-1]) if parts else cur
    if os.path.islink(final) or not _within(final, root):
        return None
    return final


def _open_new(path, mode):
    """open() that never follows a symlink at the leaf."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | (os.O_APPEND if "a" in mode else 0) | (os.O_TRUNC if "w" in mode else 0)
    return os.fdopen(os.open(path, flags, 0o600), mode)


def _rewrite_text(text, meta, cwd, real_home):
    slug = slug_of(cwd)
    text = text.replace(SLUG_TOKEN, slug)
    if meta.get("cwd"):
        text = text.replace(meta["cwd"], cwd)
    return text.replace(ARTIFACT_TOKEN, os.path.join(real_home, "tasks"))


def materialize(fixture_dir, config_home, cwd, env=None, stderr=sys.stderr):
    meta, _, _, _ = load_fixture(fixture_dir)
    reason = refusal_reason(config_home, meta["session_id"], env)
    if reason:
        stderr.write("fake-claude: refusing to materialize: %s\n" % reason)
        return EXIT_REFUSED
    real = _real(config_home)
    os.makedirs(real, exist_ok=True)
    open(os.path.join(real, MARKER), "a").close()
    initial = os.path.join(fixture_dir, "initial")
    for root, _, files in os.walk(initial):
        for f in files:
            src = os.path.join(root, f)
            rel = os.path.relpath(src, initial).replace(SLUG_TOKEN, slug_of(cwd))
            dst = safe_path(real, os.path.join("projects", rel))
            if dst is None:
                stderr.write("fake-claude: refusing to write through a symlink or outside the fake home: projects/%s\n" % rel)
                return EXIT_REFUSED
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(src, "rb") as a:
                data = a.read()
            try:
                data = _rewrite_text(data.decode("utf-8"), meta, cwd, real).encode("utf-8")
            except UnicodeDecodeError:
                pass
            with _open_new(dst, "wb") as b:
                b.write(data)
    return 0


def compare_final_state(fixture_dir, config_home, cwd):
    """Records per line for transcript files; bytes for artifacts. Returns (ok, report)."""
    meta, _, _, _ = load_fixture(fixture_dir)
    real, report, ok = _real(config_home), [], True
    tdir = os.path.join(fixture_dir, "transcript")
    for root, _, files in os.walk(tdir):
        for f in files:
            src = os.path.join(root, f)
            rel = os.path.relpath(src, tdir).replace(SLUG_TOKEN, slug_of(cwd))
            dst = os.path.join(real, "projects", rel)
            want = [json.loads(_rewrite_text(l, meta, cwd, real)) for l in open(src) if l.strip()]
            got = [json.loads(l) for l in open(dst) if l.strip()] if os.path.isfile(dst) else None
            if got != want:
                ok = False; report.append("transcript %s differs (%s vs %s records)" % (rel, None if got is None else len(got), len(want)))
    adir = os.path.join(fixture_dir, "artifacts")
    for root, _, files in os.walk(adir):
        for f in files:
            src = os.path.join(root, f)
            dst = os.path.join(real, "tasks", os.path.relpath(src, adir))
            if not os.path.isfile(dst) or open(src, "rb").read() != open(dst, "rb").read():
                ok = False; report.append("artifact %s differs" % os.path.relpath(src, adir))
    return ok, "\n".join(report)


# ---------------------------------------------------------------- replay
def _get(frame, dotted):
    cur = frame
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


class Replayer:
    def __init__(self, fixture_dir, env, stdin, stdout, stderr):
        self.env, self.stdin, self.stdout, self.stderr = env, stdin, stdout, stderr
        self.meta, self.frames, self.census, self.streams = load_fixture(fixture_dir)
        self.fixture_dir = fixture_dir
        self.speed = float(env.get("FAKE_CLAUDE_SPEED", "1") or "1")
        self.script = json.load(open(env["FAKE_CLAUDE_SCRIPT"])) if env.get("FAKE_CLAUDE_SCRIPT") else []
        self.rules = {s for step in self.script if step.get("rule") == "generic-success" for s in step.get("subtypes", [])}
        self.patches = [s for s in self.script if "patch" in s]
        self.steps = [s for s in self.script if "rule" not in s and "patch" not in s]
        self.init_override = json.load(open(env["FAKE_CLAUDE_INIT"])) if env.get("FAKE_CLAUDE_INIT") else None
        self.home = _real(env["FAKE_CLAUDE_CONFIG_HOME"]) if env.get("FAKE_CLAUDE_CONFIG_HOME") else None
        self.cwd = env.get("FAKE_CLAUDE_CWD") or os.getcwd()
        self.inbox, self.cond, self.eof = [], threading.Condition(), False
        self.last_request_id = None
        self.out_index = 0
        self.offsets = {}   # real stream path -> next byte offset

    # ---- io
    def emit(self, frame):
        try:
            if self.home:
                frame = self._rewrite_frame(frame)
            if self.home and frame.get("type") == "transcript_mirror":
                self._append_mirror(frame)
        except RuntimeError as e:                       # a symlink appeared under the fake home: stop before writing
            self.stderr.write("fake-claude: %s\n" % e); self.stderr.flush()
            raise SystemExit(EXIT_REFUSED)
        self.stdout.write(dumps(frame) + "\n"); self.stdout.flush()
        if frame.get("type") == "control_request":
            self.last_request_id = frame.get("request_id")
        self.out_index += 1

    def _reader(self):
        for line in self.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                f = json.loads(line)
            except ValueError:
                continue
            with self.cond:
                self.inbox.append(f); self.cond.notify_all()
        with self.cond:
            self.eof = True; self.cond.notify_all()

    def take(self, pred, timeout):
        """Remove and return the first inbox frame matching pred, or None on timeout/eof."""
        deadline = None if timeout is None else time.time() + timeout
        with self.cond:
            while True:
                for i, f in enumerate(self.inbox):
                    if pred(f):
                        return self.inbox.pop(i)
                if self.eof:
                    return None
                rem = None if deadline is None else deadline - time.time()
                if rem is not None and rem <= 0:
                    return None
                self.cond.wait(rem if rem is not None else 0.5)

    def fail(self, msg):
        self.stderr.write("fake-claude: %s\n" % msg); self.stderr.flush()
        return EXIT_UNEXPECTED

    # ---- filesystem
    def _rewrite_frame(self, frame):
        text = _rewrite_text(dumps(frame), self.meta, self.cwd, self.home)
        text = text.replace("~/.claude/projects/", os.path.join(self.home, "projects") + "/")
        rec_slug = slug_of(self.meta.get("cwd", "")) if self.meta.get("cwd") else None
        if rec_slug:
            text = text.replace("/projects/%s/" % rec_slug, "/projects/%s/" % slug_of(self.cwd))
        frame = json.loads(text)
        for s in self._artifact_paths(frame):
            self._write_artifact(s)
        return frame

    def _artifact_paths(self, obj):
        prefix = os.path.join(self.home, "tasks") + "/"
        if isinstance(obj, dict):
            for v in obj.values():
                for s in self._artifact_paths(v):
                    yield s
        elif isinstance(obj, list):
            for v in obj:
                for s in self._artifact_paths(v):
                    yield s
        elif isinstance(obj, str) and obj.startswith(prefix):
            yield obj

    def _write_artifact(self, path):
        rel = os.path.relpath(path, os.path.join(self.home, "tasks"))
        src = os.path.join(self.fixture_dir, "artifacts", rel)     # artifacts/ keeps the recorded task-root layout
        dst = safe_path(self.home, os.path.join("tasks", rel))
        if dst is None:
            raise RuntimeError("refusing to write artifact through a symlink: tasks/%s" % rel)
        if os.path.isfile(src) and not os.path.exists(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(src, "rb") as a, _open_new(dst, "wb") as b:
                b.write(a.read())

    def _append_mirror(self, frame):
        rel = os.path.relpath(frame["filePath"], os.path.join(self.home, "projects"))
        path = safe_path(self.home, os.path.join("projects", rel))
        if path is None:
            raise RuntimeError("refusing to append through a symlink: projects/%s" % rel)
        stream = rel.replace(slug_of(self.cwd), SLUG_TOKEN, 1)
        if path not in self.offsets:
            self.offsets[path] = self.streams.get(stream, 0)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if not os.path.exists(path):
                _open_new(path, "ab").close()
            with open(path, "r+b") as fh:
                fh.truncate(self.offsets[path])
        with _open_new(path, "ab") as fh:
            for entry in frame.get("entries", []):
                fh.write((dumps(entry) + "\n").encode("utf-8"))
            self.offsets[path] = fh.tell()

    # ---- script
    def _due(self, step, next_t):
        if "after" in step:
            return self.out_index > step["after"]
        if "at" in step:
            return next_t is None or step["at"] <= next_t
        return True

    def _run_script(self, next_t):
        """Run the script as a sequential state machine: an emit step waits for its position (time or
        index); expect and answer steps run as soon as they are reached, wherever they sit."""
        while self.steps:
            s = self.steps[0]
            if "emit" in s:
                if not self._due(s, next_t):
                    return None
                self.steps.pop(0); self.emit(s["emit"]); continue
            self.steps.pop(0)
            if "expect" in s:
                got = self.take(lambda f: self._matches(f, s["expect"]), (s.get("timeout_ms", 5000)) / 1000.0)
                if got is None:
                    return self.fail("expect timed out: %s" % dumps(s["expect"]))
                self._last_matched = got
            elif "answer" in s:
                ans = json.loads(dumps(s["answer"]))
                if ans.get("type") == "control_response" and getattr(self, "_last_matched", {}).get("type") == "control_request":
                    ans.setdefault("response", {})["request_id"] = self._last_matched["request_id"]
                self.emit(ans)
        return None

    def _matches(self, frame, matcher):
        for k, v in matcher.items():
            if k == "request_id":
                want = self.last_request_id if v == "$last" else v
                got = frame.get("request_id") or (frame.get("response") or {}).get("request_id")
                if got != want:
                    return False
            elif _get(frame, k) != v:
                return False
        return True

    # ---- recorded host inputs
    def _wait_recorded_input(self, rec):
        want = rec["frame"]
        t = want.get("type")
        if t == "control_response":
            rid = want["response"]["request_id"]
            pred = lambda f: f.get("type") == "control_response" and (f.get("response") or {}).get("request_id") == rid
        elif t == "user":
            pred = lambda f: f.get("type") == "user"
        elif t == "control_request":
            sub = want["request"]["subtype"]
            pred = lambda f: f.get("type") == "control_request" and (f.get("request") or {}).get("subtype") == sub
        else:
            pred = lambda f: f.get("type") == t
        while True:
            got = self.take(lambda f: True, None)
            if got is None:
                return None, None
            if pred(got):
                return got, want
            code = self._handle_unexpected(got)
            if code:
                return code, None

    def _handle_unexpected(self, frame):
        sub = (frame.get("request") or {}).get("subtype")
        if frame.get("type") == "control_request" and sub in self.rules:
            self.emit({"type": "control_response", "response": {"subtype": "success", "request_id": frame["request_id"], "response": {}}})
            return None
        if frame.get("type") == "control_request" and sub == "end_session":
            self.emit({"type": "control_response", "response": {"subtype": "success", "request_id": frame["request_id"], "response": {}}})
            return 0
        return self.fail("unexpected host frame: %s" % dumps(frame)[:300])

    def run(self):
        threading.Thread(target=self._reader, daemon=True).start()
        i, prev_t, pending_id_map = 0, 0, {}
        while i < len(self.frames):
            rec = self.frames[i]
            if "dropped" in rec:
                i += 1; continue
            if rec["dir"] == "in":
                got, want = self._wait_recorded_input(rec)
                if isinstance(got, int):
                    return got
                if got is None:
                    return 0                                             # stdin closed mid-replay: exit like the CLI
                if want.get("type") == "control_request":                 # host request: remember its real id
                    pending_id_map[want["request_id"]] = got["request_id"]
                if want.get("type") == "control_request" and want["request"]["subtype"] == "initialize":
                    self._host_init_id = got["request_id"]
                prev_t = rec["t"]; i += 1; continue
            code = self._run_script(rec["t"])
            if code:
                return code
            delay = (rec["t"] - prev_t) / 1000.0
            if self.speed > 0 and delay > 0:
                time.sleep(delay / self.speed)
            frame = json.loads(dumps(rec["frame"]))
            for patch in self.patches:                                   # {"patch": {matcher}, "remove": [keys]} strips keys from matching out frames
                if self._matches(frame, patch["patch"]):
                    for k in patch.get("remove", []):
                        frame.pop(k, None)
            if frame.get("type") == "control_response":
                rid = frame["response"].get("request_id")
                if rid in pending_id_map:
                    frame["response"]["request_id"] = pending_id_map[rid]
                if self.init_override and rid == "init-1":
                    frame["response"]["response"] = self.init_override
            self.emit(frame)
            prev_t = rec["t"]; i += 1
        code = self._run_script(None)
        if code:
            return code
        while True:                                                       # after the last line: wait for close or end_session
            got = self.take(lambda f: True, None)
            if got is None:
                return 0
            code = self._handle_unexpected(got)
            if code is not None:
                return code


def print_help(cen, out):
    out.write("Usage: claude [options] [command] [prompt]\n\nOptions:\n")
    for flag in cen.get("flags", []):
        out.write("  %s\n" % flag)


def main(argv=None, env=None, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr):
    argv = sys.argv[1:] if argv is None else argv
    env = os.environ if env is None else env
    if argv[:1] == ["materialize"]:
        if len(argv) < 3:
            stderr.write("usage: fake-claude materialize <fixture> <configHome> [--cwd <path>]\n"); return EXIT_REFUSED
        cwd = argv[argv.index("--cwd") + 1] if "--cwd" in argv else os.getcwd()
        return materialize(argv[1], argv[2], cwd, env, stderr)
    fixture_dir = env.get("FAKE_CLAUDE_FIXTURE")
    if "--version" in argv:
        v = env.get("FAKE_CLAUDE_VERSION") or (load_fixture(fixture_dir)[0].get("cli_version") if fixture_dir else "0.0.0")
        stdout.write("%s (Claude Code)\n" % v); return 0
    if "--help" in argv:
        print_help(load_fixture(fixture_dir)[2] if fixture_dir else {"flags": []}, stdout); return 0
    if not fixture_dir:
        stderr.write("fake-claude: FAKE_CLAUDE_FIXTURE is not set\n"); return EXIT_REFUSED
    if env.get("FAKE_CLAUDE_CONFIG_HOME"):
        home = env["FAKE_CLAUDE_CONFIG_HOME"]
        if not os.path.isfile(os.path.join(_real(home), MARKER)):
            stderr.write("fake-claude: FAKE_CLAUDE_CONFIG_HOME %s is not a home fake-claude created (missing %s)\n" % (home, MARKER)); return EXIT_REFUSED
    return Replayer(fixture_dir, env, stdin, stdout, stderr).run()


if __name__ == "__main__":
    sys.exit(main())
```

`Tools/fake-claude/fake-claude`:

```python
#!/usr/bin/env python3
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fake_claude
sys.exit(fake_claude.main())
```

Run `chmod +x Tools/fake-claude/fake-claude`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/usr/bin/python3 -m unittest discover -s Tools/fake-claude/tests -t Tools/fake-claude/tests -p 'test_*.py' -v`
Expected: all `ok`. The expect-timeout test takes about two seconds. If `test_replay_with_config_home_reproduces_the_final_filesystem` reports the transcript differing by one record, check that `_append_mirror` truncates to the `streams.json` offset only on first touch (as written) and that `materialize` laid down `initial/` once.

- [ ] **Step 5: Run on 3.14 and commit**

Run: `PYTHON=/opt/homebrew/bin/python3 make test-tools` → `OK` twice.

```bash
git add Tools/fake-claude/fake_claude.py Tools/fake-claude/fake-claude Tools/fake-claude/tests/_paths.py Tools/fake-claude/tests/test_fake_claude.py
git commit -m "feat(fake-claude): reactive fixture replayer with duplex scripts, unexpected-traffic failure and marked-home materialisation"
```

### Task 7: Review checklist, the `sign` subcommand, and the two synthetic dialog fixtures (S6 hypotheses)

**Files:**
- Create: `Fixtures/REVIEW.md`
- Create: `Tools/probe/synthetic/__init__.py`, `Tools/probe/synthetic/dialogs.py`
- Modify: `Tools/probe/probe.py` (add the `sign` subcommand and a `synthetic` subcommand)
- Modify: `Makefile` (add `synthetic` and `sign` targets)
- Test: `Tools/probe/tests/test_synthetic.py`

**Interfaces:**
- Consumes: Task 4 `fixture.write_fixture`, `verify.verify_fixture`; Task 5 `probe.sign`, `probe.main`.
- Produces: `probe.py sign <fixture> --reviewer <name>`; `probe.py synthetic` (rebuilds both dialog fixtures deterministically); `synthetic.dialogs.build(fixtures_root) -> list[str]`; `Fixtures/dialog-refusal-fallback/` and `Fixtures/dialog-fable-overage/` with `synthetic: true, hypothesis: true, census: false`.

- [ ] **Step 1: Write `Fixtures/REVIEW.md`**

```markdown
# Fixture review checklist (G4)

A fixture enters the repository only after one person other than the recording
run has walked this list and signed the `review` block in `fixture.json`.
`Tools/probe/probe.py verify` refuses an unsigned fixture.

1. `fixture.json`: `name` matches the directory; `launch.env` lists only the six
   variables of the parent's §6.1 table (no PATH, HOME or anything else);
   `purpose`, `serves`, `prompts` are truthful; `synthetic`/`hypothesis` are set
   only for the two dialog fixtures.
2. `grep -R` the whole fixture for your name, your e-mail, your hostname and
   `/Users/`: only `~`, `<email>`, `<host>` and the scratch cwd may appear.
3. Open every `tool_result` block in `frames.ndjson` and every `attachment`
   record under `transcript/`: the content must come from the scratch repository
   under `/tmp/afleet-fixtures/<name>/`, never from a real project.
4. `redaction.json` lists every rule (identity, secrets, paths_host, mcp_bodies,
   settings_bodies, oauth_flow), even with a zero count.
5. `initial/`, `streams.json` and `transcript/` are consistent: `verify` checks
   that the final file extends the initial one from the recorded offset.
6. `artifacts/` holds every file a frame or record names by the `<artifacts>`
   token, and nothing else.
7. `README.md` (optional) says what the recording shows and which acceptance
   items and spikes it serves.

Sign with `Tools/probe/probe.py sign Fixtures/<name> --reviewer "<your name>"`,
which writes `{"reviewer", "date", "checklist_version": 1}`, then run
`make verify-fixtures` and commit the fixture in its own commit.
```

- [ ] **Step 2: Write the failing synthetic-fixture test**

`Tools/probe/tests/test_synthetic.py`:

```python
import json
import os
import tempfile
import unittest
import _paths  # noqa: F401
import verify
from synthetic import dialogs


class SyntheticDialogFixturesTests(unittest.TestCase):
    def test_build_both_fixtures_and_they_verify_once_signed(self):
        root = tempfile.mkdtemp()
        paths = dialogs.build(root)
        self.assertEqual(sorted(os.path.basename(p) for p in paths), ["dialog-fable-overage", "dialog-refusal-fallback"])
        for p in paths:
            meta = json.load(open(os.path.join(p, "fixture.json")))
            self.assertTrue(meta["synthetic"]); self.assertTrue(meta["hypothesis"]); self.assertFalse(meta["census"])
            self.assertEqual(meta["review"]["reviewer"], "")
            errors, _ = verify.verify_fixture(p)
            self.assertEqual([e for e in errors if "review" not in e], [])
        frames = [json.loads(l) for l in open(os.path.join(paths[1], "frames.ndjson"))]
        results = [f["frame"]["response"]["response"].get("result") for f in frames
                   if f["dir"] == "in" and f["frame"]["type"] == "control_response" and "result" in (f["frame"]["response"].get("response") or {})]
        self.assertEqual(sorted(set(results)), ["cancelled", "edit_prompt", "retry_fallback"])
        kinds = {f["frame"]["request"].get("dialog_kind") for f in frames if f["dir"] == "out" and f["frame"]["type"] == "control_request"}
        self.assertIn("refusal_fallback_prompt", kinds); self.assertIn("undeclared_probe_kind", kinds)
        self.assertTrue(any(f["frame"]["type"] == "control_cancel_request" for f in frames))
        frames2 = [json.loads(l) for l in open(os.path.join(paths[0], "frames.ndjson"))]
        self.assertTrue(any(f["frame"].get("subtype") == "model_consent_fallback" for f in frames2))
        ovs = [f["frame"]["request"]["payload"]["overagesEnabled"] for f in frames2 if f["dir"] == "out" and f["frame"]["type"] == "control_request" and f["frame"]["request"].get("dialog_kind") == "fable_overage_consent_prompt"]
        self.assertEqual(sorted(set(ovs)), [False, True])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run it to verify it fails**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_synthetic.py' -v`
Expected: `ModuleNotFoundError: No module named 'synthetic'`.

- [ ] **Step 4: Implement `Tools/probe/synthetic/dialogs.py`**

```python
"""Hand-written dialog fixtures for S6. Shapes come from the 2.1.257 bundle modules
(chunk-1kg58a1a.js: refusal_fallback_prompt result enum retry_fallback|edit_prompt|cancelled,
payload {originalModel, fallbackModel, apiRefusalCategory?, guidanceText?, retractedMessageUuids?};
fable_overage_consent_prompt result consent|switch_default|cancelled, payload {overagesEnabled,
modelName?, balanceCents?, currency?}; chunk-sct99ax9.js: system/model_consent_fallback).
They stay `hypothesis: true` until the same strings are extracted from the installed 2.1.259 binary."""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import census   # noqa: E402
import fixture  # noqa: E402

SID_R = "44444444-4444-4444-8444-444444444444"
SID_F = "55555555-5555-4555-8555-555555555555"
CWD = "/private/tmp/afleet-fixtures/synthetic"


def _init_pair(t):
    return [{"t": t, "dir": "in", "frame": {"type": "control_request", "request_id": "init-1", "request": {"subtype": "initialize",
             "supportedDialogKinds": ["refusal_fallback_prompt", "fable_overage_consent_prompt"]}}},
            {"t": t + 5, "dir": "out", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": "init-1",
             "response": {"commands": [], "models": [], "current_model": "opus", "current_permission_mode": "default"}}}}]


def _dialog(t, rid, kind, payload, answer, sid):
    frames = [{"t": t, "dir": "out", "frame": {"type": "control_request", "request_id": rid,
               "request": {"subtype": "request_user_dialog", "dialog_kind": kind, "payload": payload}}}]
    if answer is None:
        frames.append({"t": t + 1500, "dir": "out", "frame": {"type": "control_cancel_request", "request_id": rid}})
    else:
        frames.append({"t": t + 200, "dir": "in", "frame": {"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": answer}}})
    return frames


def _user(t, uid, text):
    return {"t": t, "dir": "in", "frame": {"type": "user", "uuid": uid, "parent_tool_use_id": None, "origin": {"kind": "human"},
                                          "message": {"role": "user", "content": text}}}


def _assistant(t, uid, text, **extra):
    f = {"type": "assistant", "uuid": uid, "session_id": "", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}
    f.update(extra)
    return {"t": t, "dir": "out", "frame": f}


def _result(t, text):
    return {"t": t, "dir": "out", "frame": {"type": "result", "subtype": "success", "result": text, "num_turns": 1}}


def refusal_frames():
    p = {"originalModel": "claude-fable-5-1", "fallbackModel": "claude-opus-5", "apiRefusalCategory": "safety",
         "guidanceText": "The model declined; retry on the fallback model or edit your prompt.", "retractedMessageUuids": ["a-partial-1"]}
    fr = _init_pair(0)
    t = 100
    for n, (answer, note) in enumerate([({"behavior": "completed", "result": "retry_fallback"}, "retry on the fallback model"),
                                        ({"behavior": "completed", "result": "edit_prompt"}, "edit prompt: the turn aborts"),
                                        ({"behavior": "completed", "result": "cancelled"}, "keep the refusal"),
                                        ({"behavior": "cancelled"}, "close the card")]):
        fr.append(_user(t, "u%d" % n, "prompt %d" % n)); t += 50
        fr.append(_assistant(t, "a-partial-%d" % n, "partial text before the refusal")); t += 50
        fr += _dialog(t, "dlg-%d" % n, "refusal_fallback_prompt", dict(p, retractedMessageUuids=["a-partial-%d" % n]), answer, SID_R); t += 300
        if answer.get("result") == "retry_fallback":
            fr.append(_assistant(t, "a-retry-%d" % n, "answer from the fallback model", supersedes=["a-partial-%d" % n])); t += 50
            fr.append(_result(t, "answer from the fallback model")); t += 50
        else:
            fr.append({"t": t, "dir": "out", "frame": {"type": "system", "subtype": "model_refusal_no_fallback", "content": "The model refused (%s)." % note,
                       "uuid": "s-%d" % n, "session_id": SID_R, "supersedes": ["a-partial-%d" % n]}}); t += 50
            fr.append({"t": t, "dir": "out", "frame": {"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "refusal", "num_turns": 1}}); t += 50
    fr.append(_user(t, "u-undeclared", "prompt that triggers an undeclared kind")); t += 50
    fr += _dialog(t, "dlg-undeclared", "undeclared_probe_kind", {}, None, SID_R); t += 1600
    fr.append(_result(t, "continued after the CLI cancelled its own dialog"))
    return fr


def fable_frames():
    fr = _init_pair(0)
    t = 100
    cases = [(True, {"behavior": "completed", "result": "consent"}), (False, {"behavior": "completed", "result": "consent"}),
             (True, {"behavior": "completed", "result": "switch_default"}), (True, {"behavior": "completed", "result": "cancelled"}),
             (False, {"behavior": "cancelled"})]
    for n, (enabled, answer) in enumerate(cases):
        fr.append(_user(t, "u%d" % n, "prompt %d" % n)); t += 50
        payload = {"overagesEnabled": enabled, "modelName": "Fable 5", "balanceCents": 0 if enabled else None, "currency": "USD" if enabled else None}
        fr += _dialog(t, "fab-%d" % n, "fable_overage_consent_prompt", payload, answer, SID_F); t += 300
        choice = answer.get("result", "cancelled")
        if not (choice == "consent" and enabled):
            fr.append({"t": t, "dir": "out", "frame": {"type": "system", "subtype": "model_consent_fallback", "choice": choice,
                       "original_model": "claude-fable-5-1", "original_model_name": "Fable 5", "fallback_model": "claude-opus-5",
                       "persisted_as_default": choice == "switch_default", "content": "Switched to Opus for this session.",
                       "uuid": "mcf-%d" % n, "session_id": SID_F}}); t += 50
        fr.append(_assistant(t, "a-%d" % n, "answer")); t += 50
        fr.append(_result(t, "answer")); t += 50
    return fr


def _write(root, name, sid, frames, purpose, serves):
    work = tempfile.mkdtemp(prefix="afleet-synth-")
    initial = os.path.join(work, "initial"); transcript = os.path.join(work, "transcript", fixture.SLUG_TOKEN); os.makedirs(initial); os.makedirs(transcript)
    with open(os.path.join(transcript, sid + ".jsonl"), "w") as fh:
        for rec in frames:
            f = rec["frame"]
            if f.get("type") in ("user", "assistant"):
                fh.write(json.dumps({"type": f["type"], "uuid": f.get("uuid"), "cwd": CWD, "message": f["message"]}) + "\n")
    meta = {"name": name, "scenario": None, "purpose": purpose, "serves": serves, "spikes": ["S6"], "recorded_at": "2026-09-04T00:00:00Z",
            "cli_version": "2.1.257-bundle", "session_id": sid, "cwd": CWD, "launch": {"argv": [], "env": {}}, "prompts": [],
            "census": False, "deterministic": False, "isolation": "none", "synthetic": True, "hypothesis": True, "late_responses": [],
            "notes": ["hand-written from the 2.1.257 bundle modules; shapes unconfirmed on 2.1.259"], "exit_code": 0,
            "review": {"reviewer": "", "date": "", "checklist_version": 1}}
    c = census.census([r["frame"] for r in frames], version="2.1.257-bundle")
    return fixture.write_fixture(root, name, meta, frames, c, {"rules": {}}, initial, os.path.join(work, "transcript"), None)


def build(fixtures_root):
    return [_write(fixtures_root, "dialog-fable-overage", SID_F, fable_frames(), "every fable_overage_consent_prompt outcome, overagesEnabled both ways, model_consent_fallback", ["item 62"]),
            _write(fixtures_root, "dialog-refusal-fallback", SID_R, refusal_frames(), "every refusal_fallback_prompt result, the close path, supersedes after a refusal, an undeclared kind cancelled by the CLI", ["item 62"])]
```

`Tools/probe/synthetic/__init__.py` is empty.

- [ ] **Step 5: Add `sign` and `synthetic` to `probe.py` and the Makefile**

In `probe.py` `main()`, extend the sub-parser loop's tuple to `("census", "diff", "record", "snapshot", "redact", "verify", "sign", "synthetic")`, add for `sign`: `sp.add_argument("fixture"); sp.add_argument("--reviewer", required=True)`, and before the final `return` add:

```python
    if args.cmd == "sign":
        sign(args.fixture.rstrip("/"), args.reviewer); print("signed %s" % args.fixture); return 0
    if args.cmd == "synthetic":
        from synthetic import dialogs
        for p in dialogs.build(FIXTURES_ROOT):
            print("built %s" % p)
        return 0
```

Makefile additions:

```make
synthetic:
	$(PYTHON) Tools/probe/probe.py synthetic

sign:
	@test -n "$(FIXTURE)" -a -n "$(REVIEWER)" || (echo "usage: make sign FIXTURE=Fixtures/<name> REVIEWER=<name>" && exit 2)
	$(PYTHON) Tools/probe/probe.py sign "$(FIXTURE)" --reviewer "$(REVIEWER)"
```

- [ ] **Step 6: Run the tests, build, review and sign the two fixtures**

Run: `/usr/bin/python3 -m unittest discover -s Tools/probe/tests -t Tools/probe/tests -p 'test_synthetic.py' -v` → `ok`.
Run: `make synthetic` → prints two `built Fixtures/...` lines.
Walk `Fixtures/REVIEW.md` for each (they contain only synthetic strings), write a one-paragraph `README.md` in each stating that the shapes are hypotheses from the 2.1.257 bundle pending the S6 extraction on 2.1.259, then:
```bash
make sign FIXTURE=Fixtures/dialog-refusal-fallback REVIEWER="<your name>"
make sign FIXTURE=Fixtures/dialog-fable-overage REVIEWER="<your name>"
make verify-fixtures
```
Expected: `all fixtures pass`.

- [ ] **Step 7: Commit**

```bash
git add Fixtures/REVIEW.md Fixtures/dialog-refusal-fallback Fixtures/dialog-fable-overage Tools/probe/synthetic Tools/probe/probe.py Tools/probe/tests/test_synthetic.py Makefile
git commit -m "feat(fixtures): review checklist, sign and synthetic subcommands, and the two S6 dialog fixtures as hypotheses"
```

### Task 8: Recording wave A — login check, zero-cost, send-user-file (S5), plain-two-turn, resume-no-replay (S2)

**Files:**
- Create: `Tools/probe/scenarios/send_user_file.py`, `Tools/probe/scenarios/plain_two_turn.py`, `Tools/probe/scenarios/resume_no_replay.py`
- Modify: `Tools/probe/probe.py` (fallback-launch retry in `record`)
- Create: `Fixtures/zero-cost/`, `Fixtures/send-user-file/`, `Fixtures/plain-two-turn/`, `Fixtures/resume-no-replay/` (recorded)
- Modify: `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md` (Revision Notes: `C1/S5:`, `C1/S2:`)

**Interfaces:**
- Consumes: Task 5 scenario contract and `probe.record`; Task 3 `harness.RetryWithFallback` (added here).
- Produces: four recorded, reviewed, signed fixtures; the S5 finding.

- [ ] **Step 1: Pre-flight — the scratch config home must be logged in**

Run:
```bash
test -f /tmp/afleet-fixtures/config-home/.claude.json && /usr/bin/python3 -c "import json;d=json.load(open('/tmp/afleet-fixtures/config-home/.claude.json'));print('logged in' if d.get('oauthAccount') else 'NOT logged in')"
```
Expected: `logged in`. If the file is missing or prints `NOT logged in`, stop and ask the author to run `CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home claude` once and complete the login (parent §17.6 convention). Do not fall back to the real config home without the author's word.

- [ ] **Step 2: Add the fallback-launch retry to `record`**

In `harness.py` add:

```python
class RetryWithFallback(Exception):
    """A scenario asks to be re-run with META['fallback_launch'] applied; the message is the reason."""
```

In `probe.py` `run_scenario`, wrap the call:

```python
    try:
        mod.run(session, ctx)
    except harness.RetryWithFallback as why:
        ctx["notes"].append("retry with fallback launch: %s" % why)
        ctx["retry"] = str(why)
    finally:
        code = session.close(end_session=not meta.get("keep_open"))
```

and in `record`, after `session, ctx = run_scenario(...)`:

```python
    if ctx.get("retry") and meta.get("fallback_launch"):
        meta = dict(meta); meta["launch"] = dict(meta.get("launch") or {}, **meta["fallback_launch"])
        mod.META = meta
        session, ctx = run_scenario(mod, claude, config_home, scratch_root, redactor, resume=resume)
        ctx["notes"].insert(0, "recorded with fallback launch after: %s" % meta.get("fallback_reason", "retry requested"))
```

- [ ] **Step 3: Write the three scenario files**

`Tools/probe/scenarios/send_user_file.py`:

```python
"""S5: the in-process MCP round trip through mcp__afleet__send_user_file (item 29, C2.G3)."""
import os
import harness

META = {"name": "send-user-file", "purpose": "in-process MCP round trip: two files, a caption, status normal",
        "serves": ["item 29", "C2.G3"], "spikes": ["S5"], "census": True, "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 4, "strict_mcp_config": True}, "fallback_launch": {"strict_mcp_config": False},
        "fallback_reason": "the SDK MCP server did not register under --strict-mcp-config",
        "prompts": ["Use the mcp__afleet__send_user_file tool to send the files a.txt and b.txt to me, with the caption 'two files' and status 'normal'. Then reply with the single word: done"],
        "resume_of": None, "spill_after": 5000}


def setup(cwd):
    open(os.path.join(cwd, "a.txt"), "w").write("alpha\n")
    open(os.path.join(cwd, "b.txt"), "w").write("beta\n")
META["setup"] = setup


def run(session, ctx):
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=180)
    tools = (session.system_init or {}).get("tools") or []
    registered = "mcp__afleet__send_user_file" in tools
    ctx["notes"].append("sdk server registered under strict-mcp-config: %s" % registered)
    if not registered and ctx["launch"].strict_mcp_config:
        raise harness.RetryWithFallback("mcp__afleet__send_user_file absent from system/init.tools")
    ctx["notes"].append("tools/call arguments seen by the harness: %r" % session.mcp.calls)
    ctx["notes"].append("result: %s" % (res or {}).get("subtype"))
```

`Tools/probe/scenarios/plain_two_turn.py`:

```python
"""Two short prompts, no tools (items 1, 2, 31, 56; C3.G1)."""
META = {"name": "plain-two-turn", "purpose": "two short prompts, no tools", "serves": ["item 1", "item 2", "item 31", "item 56", "C3.G1"],
        "spikes": ["S14"], "census": True, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 2},
        "prompts": ["Reply with exactly the word: one", "Reply with exactly the word: two"], "resume_of": None, "setup": None}


def run(session, ctx):
    for p in META["prompts"]:
        session.send_user(p)
        res = session.wait_result(timeout=120)
        ctx["notes"].append("result: %s" % (res or {}).get("subtype"))
    mirrors = [f for f in session.frames() if f.get("frame", {}).get("type") == "transcript_mirror"]
    ctx["notes"].append("transcript_mirror frames: %d" % len(mirrors))
```

`Tools/probe/scenarios/resume_no_replay.py`:

```python
"""S2's record: --resume replays no history (item 1)."""
import time

META = {"name": "resume-no-replay", "purpose": "--resume of plain-two-turn, initialize, six idle seconds, no history frames",
        "serves": ["item 1"], "spikes": ["S2"], "census": True, "deterministic": True, "isolation": "config-home",
        "launch": {"max_turns": 1}, "prompts": [], "resume_of": "plain-two-turn", "setup": None}


def run(session, ctx):
    time.sleep(6)
    history = [f for f in session.frames() if f.get("dir") == "out" and f.get("frame", {}).get("type") in ("assistant", "user")]
    ctx["notes"].append("assistant/user frames after resume with no input: %d" % len(history))
```

Note: `resume_no_replay` must run in the **same scratch cwd** as `plain-two-turn` so the CLI finds the session; add to `probe.fresh_scratch` a parameter so that `record` uses `meta["resume_of"]`'s directory when set: in `run_scenario`, `cwd = fresh_scratch(meta["name"], scratch_root)` becomes `cwd = os.path.join(scratch_root, meta["resume_of"]) if meta.get("resume_of") else fresh_scratch(meta["name"], scratch_root)`.

- [ ] **Step 4: Record `zero-cost` first (deterministic; proves the login and the launch line)**

Run: `make record SCENARIO=zero_cost`
Expected: `recorded Fixtures/zero-cost` and one `needs review:` line. Then inspect `Fixtures/zero-cost/census.json`: pairs must include `control_request/initialize` and `control_response/initialize`, one `control_response/<subtype>` per entry in `REQUESTS`, `auth_status`, and no `assistant` pair. If `record` fails with a handshake timeout, print `Fixtures`… nothing was written; read the stderr tail it prints and fix the login or the binary path before continuing.
Walk `Fixtures/REVIEW.md`, then:
```bash
make sign FIXTURE=Fixtures/zero-cost REVIEWER="<name>" && make verify-fixtures
git add Fixtures/zero-cost && git commit -m "fixtures: zero-cost census baseline on 2.1.259"
```

- [ ] **Step 5: Record `send-user-file` and settle S5**

Run: `make record SCENARIO=send_user_file`
Read `Fixtures/send-user-file/fixture.json` `notes`: whether the SDK server registered under `--strict-mcp-config` and whether the fallback launch was used; confirm `frames.ndjson` holds `control_request/mcp_message` frames with `tools/call` carrying `{"files": ["a.txt", "b.txt"], "caption": "two files", "status": "normal"}` and a `mcp_response` with the text result. Review, sign, verify, commit as in Step 4.
Append to the parent document's Revision Notes (in this branch):
```
- 2026-09-04 C1/S5: The in-process MCP server registers through `initialize.sdkMcpServers`
  and `mcp__afleet__send_user_file` appears in `system/init.tools`; the model calls it with
  `files`, `caption` and `status` and the round trip is `mcp_message` → `mcp_response`
  (fixture `send-user-file`). Under `--strict-mcp-config` the server <did | did not>
  register; <if not:> scenarios that need it drop that flag. Settles §6.8's mechanism.
```
Fill the angle-bracketed parts from the notes.

- [ ] **Step 6: Record `plain-two-turn`, then `resume-no-replay`, and settle S2**

Run: `make record SCENARIO=plain_two_turn`; confirm `notes` shows `transcript_mirror frames: N` with N ≥ 2 and `transcript/_slug_/<sid>.jsonl` exists with the two user and two assistant records; review, sign, verify, commit.
Run: `make record SCENARIO=resume_no_replay`; confirm `notes` shows `assistant/user frames after resume with no input: 0` and that `initial/` holds the prior transcript with `streams.json` offsets equal to its sizes; review, sign, verify, commit.
Append to the parent's Revision Notes:
```
- 2026-09-04 C1/S2: `--resume` plus `initialize` and six idle seconds emitted no assistant
  or user frames (fixture `resume-no-replay`); history comes only from the transcript.
  Confirms §7.3's record-reducer-primary design; S2 stays resolved.
```

- [ ] **Step 7: Run the drift ritual against the four fixtures**

Run: `make probe`
Expected: `zero-cost: ok`, `send-user-file: ok`, `plain-two-turn: ok`, `resume-no-replay: ok`, exit 0. If a model-driven fixture drifts on an optional key, re-record it once (`make record` merges required shapes) and re-run.

- [ ] **Step 8: Commit the scenarios and the parent notes**

```bash
git add Tools/probe/scenarios/send_user_file.py Tools/probe/scenarios/plain_two_turn.py Tools/probe/scenarios/resume_no_replay.py Tools/probe/probe.py Tools/probe/harness.py docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md
git commit -m "feat(probe): wave A scenarios with fallback launch; S5 and S2 findings on the parent"
```

### Task 9: Recording wave B — permissions, question (S15), plan, control shapes (S8), session mirror and relocation (S13, S14)

**Files:**
- Create: `Tools/probe/scenarios/permission_allow.py`, `permission_deny.py`, `ask_user_question.py`, `exit_plan_mode.py`, `control_shapes.py`, `session_mirror_relocation.py`, `session_mirror_resume.py`
- Create: the seven recorded fixtures of the same names (hyphenated)
- Modify: the parent's Revision Notes (`C1/S8:`, `C1/S13:`, `C1/S14:`, `C1/S15:`) and the child spec's Revision Notes (the relocation row becomes two fixtures)

**Interfaces:**
- Consumes: the scenario contract (Task 5); `harness.Session.on`, `.request`, `.frames`, `.system_init`.
- Produces: seven fixtures; four findings.

- [ ] **Step 1: S15 first — find the accepted preview-format values in the bundle**

Run:
```bash
cd ~/claude-code-bundle/2.1.257 && python3 - <<'EOF'
import re, glob
for f in sorted(glob.glob('modules/chunk-*.js')):
    s = open(f, encoding='utf-8', errors='replace').read()
    for m in re.finditer('CLAUDE_CODE_QUESTION_PREVIEW_FORMAT', s):
        print('#####', f); print(s[max(0, m.start()-400):m.start()+400].replace('\n', ' ')); print()
EOF
```
Read the surrounding code for the comparison the variable feeds (an `===` against literals, or a `Set([...])`). Write the literal values down; export the one that enables previews for the recording below:
```bash
export AFLEET_QUESTION_PREVIEW_FORMAT=<the value that enables previews>
```
If the variable is compared only for truthiness, use `1`. Record what you found; it goes into the `C1/S15:` note in Step 6.

- [ ] **Step 2: Write the permission, question and plan scenarios**

`Tools/probe/scenarios/permission_allow.py`:

```python
"""Write in the scratch cwd answered allow (items 4, 5; C2.G2)."""
META = {"name": "permission-allow", "purpose": "a Write asked through can_use_tool and answered allow", "serves": ["item 4", "item 5", "C2.G2"],
        "spikes": [], "census": True, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 3},
        "prompts": ["Use the Write tool to create a file named probe.txt in the current directory containing the text: afleet. Then reply with the single word: done"],
        "resume_of": None, "setup": None}


def run(session, ctx):
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=120)
    asks = [f for f in session.frames() if f.get("frame", {}).get("request", {}).get("subtype") == "can_use_tool"]
    ctx["notes"].append("can_use_tool requests: %d; result: %s" % (len(asks), (res or {}).get("subtype")))
    if asks:
        r = asks[0]["frame"]["request"]
        ctx["notes"].append("ask fields: %s; suggestions: %s" % (sorted(r.keys()), [x.get("type") for x in r.get("permission_suggestions") or []]))
```

`Tools/probe/scenarios/permission_deny.py`:

```python
"""The same Write answered deny with a message (item 41)."""
META = {"name": "permission-deny", "purpose": "a Write asked through can_use_tool and denied with a message", "serves": ["item 41"],
        "spikes": [], "census": True, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 3},
        "prompts": ["Use the Write tool to create a file named probe.txt in the current directory containing the text: afleet. Then reply with the single word: done"],
        "resume_of": None, "setup": None}


def run(session, ctx):
    session.on("can_use_tool", "deny")
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=120)
    ctx["notes"].append("result: %s; text: %r" % ((res or {}).get("subtype"), str((res or {}).get("result"))[:120]))
```

`Tools/probe/scenarios/ask_user_question.py`:

```python
"""AskUserQuestion answered through updatedInput.answers (items 6, 57 with S15)."""
import os
import harness

META = {"name": "ask-user-question", "purpose": "a question with two options and previews, answered through updatedInput.answers",
        "serves": ["item 6", "item 57"], "spikes": ["S15"], "census": True, "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 3, "env_table": dict(harness.DEFAULT_ENV_TABLE,
                   **({"CLAUDE_CODE_QUESTION_PREVIEW_FORMAT": os.environ["AFLEET_QUESTION_PREVIEW_FORMAT"]} if os.environ.get("AFLEET_QUESTION_PREVIEW_FORMAT") else {}))},
        "prompts": ["Before answering, use the AskUserQuestion tool to ask me which colour I prefer, offering exactly two options, red and blue, each with a short preview. After I answer, reply with only the colour I chose."],
        "resume_of": None, "setup": None}


def answer_first_option(frame):
    req = frame["request"]
    inp = dict(req.get("input") or {})
    questions = inp.get("questions") or []
    answers = {}
    for q in questions:
        opts = q.get("options") or []
        answers[q.get("question", "")] = (opts[0].get("label") if opts else "red")
    inp["answers"] = answers
    return {"behavior": "allow", "updatedInput": inp}


def run(session, ctx):
    session.on("can_use_tool", lambda f: answer_first_option(f) if f["request"].get("tool_name") == "AskUserQuestion"
               else {"behavior": "allow", "updatedInput": f["request"].get("input", {})})
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=150)
    asks = [f["frame"]["request"] for f in session.frames() if f.get("frame", {}).get("request", {}).get("tool_name") == "AskUserQuestion"]
    previews = [o.get("preview") for a in asks for q in (a.get("input") or {}).get("questions", []) for o in q.get("options", [])]
    ctx["notes"].append("AskUserQuestion asks: %d; previews present: %s; requires_user_interaction: %s; result: %s" % (
        len(asks), any(previews), [a.get("requires_user_interaction") for a in asks], (res or {}).get("subtype")))
    ctx["notes"].append("CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=%r" % os.environ.get("AFLEET_QUESTION_PREVIEW_FORMAT"))
```

`Tools/probe/scenarios/exit_plan_mode.py`:

```python
"""Plan mode, a plan, approved with setMode (item 7)."""
META = {"name": "exit-plan-mode", "purpose": "--permission-mode plan, a plan presented through ExitPlanMode, approved with a setMode update",
        "serves": ["item 7"], "spikes": [], "census": True, "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 3, "permission_mode": "plan"},
        "prompts": ["Plan, in three short bullet points, how you would add a README.md to this directory. Then call ExitPlanMode to present the plan. Do not create any file."],
        "resume_of": None, "setup": None}


def approve(frame):
    req = frame["request"]
    if req.get("tool_name") == "ExitPlanMode":
        return {"behavior": "allow", "updatedInput": req.get("input", {}),
                "updatedPermissions": [{"type": "setMode", "mode": "acceptEdits", "destination": "session"}]}
    return {"behavior": "allow", "updatedInput": req.get("input", {})}


def run(session, ctx):
    session.on("can_use_tool", approve)
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=150)
    plans = [f["frame"]["request"] for f in session.frames() if f.get("frame", {}).get("request", {}).get("tool_name") == "ExitPlanMode"]
    ctx["notes"].append("ExitPlanMode asks: %d; plan keys: %s; result: %s" % (len(plans), sorted((plans[0].get("input") or {}).keys()) if plans else [], (res or {}).get("subtype")))
    modes = [f["frame"] for f in session.frames() if f.get("frame", {}).get("subtype") == "status"]
    ctx["notes"].append("status frames after approval: %s" % [m.get("permissionMode") for m in modes])
```

- [ ] **Step 3: Write the control-shapes and session-mirror scenarios**

`Tools/probe/scenarios/control_shapes.py`:

```python
"""S8: control request and response shapes the router relies on (items 11, 13; C4.G4)."""
import os

META = {"name": "control-shapes", "purpose": "apply_flag_settings with readback, rewind_conversation, set_cwd needing trust, the claude_authenticate family",
        "serves": ["item 11", "item 13", "C4.G4"], "spikes": ["S8"], "census": True, "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 2}, "prompts": ["Reply with exactly the word: shapes"], "resume_of": None, "setup": None}


def run(session, ctx):
    first_uuid = session.send_user(META["prompts"][0])
    session.wait_result(timeout=120)
    def note(sub, resp):
        body = resp.get("response") if resp.get("subtype") == "success" else resp.get("error")
        ctx["notes"].append("%s -> %s %s" % (sub, resp.get("subtype"), sorted(body.keys()) if isinstance(body, dict) else str(body)[:120]))
    note("apply_flag_settings", session.request("apply_flag_settings", settings={"effortLevel": "low"}))
    note("get_settings", session.request("get_settings"))
    note("list_models", session.request("list_models"))
    note("get_workspace_diff", session.request("get_workspace_diff"))
    note("rewind_files dry_run", session.request("rewind_files", user_message_id=first_uuid, dry_run=True))
    sibling = os.path.join(os.path.dirname(ctx["cwd"]), "control-shapes-sibling")
    os.makedirs(sibling, exist_ok=True)
    note("set_cwd sibling", session.request("set_cwd", path=sibling))
    note("set_cwd back", session.request("set_cwd", path=ctx["cwd"]))
    note("rewind_conversation", session.request("rewind_conversation", target_message_uuid=first_uuid))
    note("claude_authenticate", session.request("claude_authenticate"))
    note("claude_oauth_callback (invalid code)", session.request("claude_oauth_callback", code="probe-invalid-code"))
    rid = session.request_async("claude_oauth_wait_for_completion")          # no login completes; capture the shape or the silence
    resp = session.wait_response(rid, timeout=10)
    if resp is None:
        session.cancel(rid)
        ctx["notes"].append("claude_oauth_wait_for_completion -> no response in 10 s; cancelled by the host (control_cancel_request recorded)")
    else:
        note("claude_oauth_wait_for_completion", resp)
    note("generate_session_title", session.request("generate_session_title", description="control shapes probe", persist=False))
```

`Tools/probe/scenarios/session_mirror_relocation.py`:

```python
"""S14 and S13: transcript_mirror entries equal the file's appends; set_cwd relocation honouring needs_trust (items 56, 64; C3.G3, C3.G4)."""
import glob
import json
import os

META = {"name": "session-mirror-relocation", "purpose": "two turns, set_cwd to a sibling (trust accepted when asked), two more turns",
        "serves": ["item 56", "item 64", "C3.G3", "C3.G4"], "spikes": ["S13", "S14"], "census": True, "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 4},
        "prompts": ["Reply with exactly: m1", "Reply with exactly: m2", "Reply with exactly: m3", "Reply with exactly: m4"], "resume_of": None, "setup": None}


def mirror_matches_file(session, config_home):
    """Concatenate transcript_mirror entries per filePath and compare with the file's records, record for record."""
    per_file = {}
    for rec in session.frames():
        f = rec.get("frame") or {}
        if f.get("type") == "transcript_mirror":
            per_file.setdefault(f["filePath"], []).extend(f.get("entries", []))
    report = []
    for path, entries in per_file.items():
        real = os.path.expanduser(path.replace("~/.claude", config_home, 1)) if path.startswith("~/.claude") else path
        if not os.path.isfile(real):
            report.append("%s: file missing" % path); continue
        records = [json.loads(l) for l in open(real) if l.strip()]
        tail = records[-len(entries):] if entries else []
        report.append("%s: %d mirrored, file has %d records, tail equal: %s" % (os.path.basename(path), len(entries), len(records), tail == entries))
    return report


def run(session, ctx):
    for p in META["prompts"][:2]:
        session.send_user(p); session.wait_result(timeout=120)
    sibling = os.path.join(os.path.dirname(ctx["cwd"]), "session-mirror-relocation-sibling")
    os.makedirs(sibling, exist_ok=True)
    r = session.request("set_cwd", path=sibling)
    body = r.get("response") or {}
    ctx["notes"].append("set_cwd sibling -> %s %s" % (r.get("subtype"), json.dumps(body)[:200]))
    if body.get("status") == "needs_trust" or body.get("needs_trust"):
        r2 = session.request("set_cwd", path=sibling, trust_accepted=True)
        ctx["notes"].append("set_cwd trust_accepted -> %s %s" % (r2.get("subtype"), json.dumps(r2.get("response") or r2.get("error"))[:200]))
    for p in META["prompts"][2:]:
        session.send_user(p); session.wait_result(timeout=120)
    errors = [f for f in session.frames() if f.get("frame", {}).get("subtype") == "mirror_error"]
    ctx["notes"].append("mirror_error frames: %d" % len(errors))
    ctx["notes"] += mirror_matches_file(session, ctx["config_home"])
    cfg = os.path.join(ctx["config_home"], ".claude.json")
    if os.path.isfile(cfg):
        projects = (json.load(open(cfg)).get("projects") or {})
        ctx["notes"].append("scratch .claude.json trust for sibling: %s" % (projects.get(sibling) or {}).get("hasTrustDialogAccepted"))
```

`Tools/probe/scenarios/session_mirror_resume.py`:

```python
"""The resume half of the relocation row: --resume after set_cwd, one more turn (item 64)."""
META = {"name": "session-mirror-resume", "purpose": "resume the relocated session and add one turn; mirror and file still agree",
        "serves": ["item 64", "C3.G3"], "spikes": ["S14"], "census": True, "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 2}, "prompts": ["Reply with exactly: m5"], "resume_of": "session-mirror-relocation", "setup": None}


def run(session, ctx):
    from session_mirror_relocation import mirror_matches_file
    session.send_user(META["prompts"][0]); session.wait_result(timeout=120)
    ctx["notes"] += mirror_matches_file(session, ctx["config_home"])
```

Note: `session_mirror_resume` imports its sibling; `probe.load_scenario` must put the scenarios directory on `sys.path` — add `sys.path.insert(0, scenario_dir or SCENARIO_DIR)` at the top of `load_scenario`.

- [ ] **Step 4: Record the seven fixtures, one at a time**

For each name in `permission_allow`, `permission_deny`, `ask_user_question`, `exit_plan_mode`, `control_shapes`, `session_mirror_relocation`, `session_mirror_resume`:

```bash
make record SCENARIO=<name>            # read the printed notes and any ERROR lines
```
then walk `Fixtures/REVIEW.md`, write the fixture's `README.md` (what it shows, the notes that matter), and:
```bash
make sign FIXTURE=Fixtures/<hyphenated-name> REVIEWER="<name>" && make verify-fixtures
git add Fixtures/<hyphenated-name> && git commit -m "fixtures: <hyphenated-name>"
```
Expected per fixture: `permission-allow` notes `can_use_tool requests: 1` and the ask fields include `permission_suggestions`, `tool_use_id`, `decision_reason_type`; `permission-deny` result is a success whose text explains the denial; `ask-user-question` notes one ask with `previews present: True` when S15's value was exported (if `False`, retry once with the other candidate value from Step 1 and record which); `exit-plan-mode` notes one `ExitPlanMode` ask with `plan` in its input keys; `control-shapes` notes each request's outcome with `apply_flag_settings -> success`, `get_settings` keys including `applied`, `claude_authenticate` keys `manualUrl`, `automaticUrl`; `session-mirror-relocation` notes `tail equal: True` for the main transcript and a `set_cwd` outcome (`needs_trust` handled or `status: ok` directly); `session-mirror-resume` notes `tail equal: True`.
If `control-shapes`' `rewind_conversation` refuses with `turn running`, the previous turn's `result` had not been awaited; the scenario waits for it, so re-run.

- [ ] **Step 5: Drift check**

Run: `make probe` → every fixture `ok`, exit 0. A model-driven fixture that drifts on optional keys is re-recorded once (merge) and checked again.

- [ ] **Step 6: Findings on the parent and the child**

Append to the parent's Revision Notes (fill from the notes; keep each note to the facts observed):
```
- 2026-09-04 C1/S8: Request and response shapes pinned by `control-shapes`:
  `apply_flag_settings {settings:{effortLevel}}` answers null and `get_settings.applied`
  carries the readback; `rewind_conversation {target_message_uuid}` answers
  `{rewound, targetMessageUuid, prefillText, precedingAssistantUuid}`; `set_cwd` answers
  `{status, cwd, changed, transcript_relocated}` <and needs_trust as observed>;
  `claude_authenticate` answers `{manualUrl, automaticUrl, …}`; `claude_oauth_callback` with an
  invalid code answers <the error text>; `claude_oauth_wait_for_completion` <answered … | stayed
  silent and was cancelled>. Settles §6.4's unpublished shapes for C2's models.
- 2026-09-04 C1/S13: Under the scratch config home `set_cwd` to an untrusted sibling
  <returned needs_trust and `trust_accepted: true` completed it | completed without a
  trust step>; the scratch `.claude.json` <did | did not> record `hasTrustDialogAccepted`
  for the sibling. Settles §7.7's `/cd` trust handling.
- 2026-09-04 C1/S14: `--session-mirror` is accepted on 2.1.259; `transcript_mirror`
  entries, concatenated per `filePath`, equal the transcript's appended records record for
  record, across a `set_cwd` relocation and a resume (fixtures `session-mirror-relocation`,
  `session-mirror-resume`); no `mirror_error` was emitted. The build flag that promotes the
  mirror to primary (§7.3) may be turned on; the file watcher stays the fallback.
- 2026-09-04 C1/S15: `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT` accepts <the values found>; with
  `<value>` the `AskUserQuestion` input carries `options[].preview` (fixture
  `ask-user-question`). §6.1's table takes `<value>`.
```
Then make the value reproducible: add `"CLAUDE_CODE_QUESTION_PREVIEW_FORMAT": "<value>"` to `harness.DEFAULT_ENV_TABLE`, delete the `env_table` override and the `AFLEET_QUESTION_PREVIEW_FORMAT` indirection from `ask_user_question.py`, re-record `ask-user-question` once so its `fixture.json` `launch.env` carries the variable, and confirm in a fresh shell (`env -i PATH="$PATH" HOME="$HOME" make probe FIXTURE=ask-user-question`) that no export is needed.
Append to the child spec's Revision Notes:
```
- 2026-09-04: The catalogue's `session-mirror-relocation` row is recorded as two fixtures,
  `session-mirror-relocation` and `session-mirror-resume`, because a fixture is one
  process and the row's resume is a second one; G1 counts fourteen recorded fixtures.
```

- [ ] **Step 7: Commit**

```bash
git add Tools/probe/scenarios/*.py Tools/probe/probe.py docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md docs/doperpowers/specs/2026-09-04-c1-probe-suite-fixtures-fake-claude.md
git commit -m "feat(probe): wave B scenarios; S8, S13, S14 and S15 findings on the parent"
```

### Task 10: Recording wave C — agents (S16), background shell with artifacts, the Notification hook (S18)

**Files:**
- Create: `Tools/probe/scenarios/explore_depth_1.py`, `nested_depth_2.py`, `background_shell.py`, `notification_hook.py`
- Create: the four recorded fixtures
- Modify: the parent's Revision Notes (`C1/S16:`, `C1/S18:`)

**Interfaces:**
- Consumes: the scenario contract; `fixture.collect_artifacts` (runs inside `record`).
- Produces: four fixtures; two findings.

- [ ] **Step 1: Write the four scenarios**

`Tools/probe/scenarios/_tasks.py` (shared by the agent and background scenarios; `CLAUDE_CODE_FORK_SUBAGENT=1` backgrounds every subagent, so the initiating turn's `result` can arrive while agents still run):

```python
"""Wait until every task the CLI started has ended, so end_session never kills a live agent."""
import time


def started_ids(session):
    return [f["frame"].get("task_id") for f in session.frames() if f.get("frame", {}).get("subtype") == "task_started"]


def ended_ids(session):
    return [f["frame"].get("task_id") for f in session.frames() if f.get("frame", {}).get("subtype") == "task_notification"]


def wait_for_tasks(session, timeout=300):
    """True when every task_started has a task_notification; also drains the auto-turns that follow."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        pending = set(started_ids(session)) - set(ended_ids(session))
        if not pending:
            time.sleep(3)                      # let a trailing auto-turn's result arrive
            return True
        time.sleep(1)
    return False
```

`Tools/probe/scenarios/explore_depth_1.py`:

```python
"""One Explore agent (items 9, 38, 49; C3.G3)."""
import os
from _tasks import wait_for_tasks

META = {"name": "explore-depth-1", "purpose": "one Explore subagent searching synthetic files", "serves": ["item 9", "item 38", "item 49", "C3.G3"],
        "spikes": [], "census": True, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 4},
        "prompts": ["Use the Agent tool with subagent_type Explore to find which files in this directory contain the word gamma. Reply with only the file names it reports."],
        "resume_of": None}


def setup(cwd):
    for name, text in (("one.txt", "alpha beta\n"), ("two.txt", "gamma delta\n"), ("three.md", "no match here\n")):
        open(os.path.join(cwd, name), "w").write(text)
META["setup"] = setup


def run(session, ctx):
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=300)
    settled = wait_for_tasks(session, timeout=300)
    started = [f["frame"] for f in session.frames() if f.get("frame", {}).get("subtype") == "task_started"]
    ctx["notes"].append("task_started: %d, depths: %s, all settled: %s, result: %s" % (len(started), [t.get("spawn_depth") for t in started], settled, (res or {}).get("subtype")))
    ctx["notes"].append("frames with parent_tool_use_id: %d" % sum(1 for f in session.frames() if f.get("frame", {}).get("parent_tool_use_id")))
```

`Tools/probe/scenarios/nested_depth_2.py`:

```python
"""S16: a general-purpose agent that itself spawns Explore (items 49, 52)."""
import os
from _tasks import wait_for_tasks

META = {"name": "nested-depth-2", "purpose": "a depth-2 run: general-purpose spawns Explore", "serves": ["item 49", "item 52"],
        "spikes": ["S16"], "census": True, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 6},
        "prompts": ["Use the Agent tool with subagent_type general-purpose. Instruct that agent to use the Agent tool itself with subagent_type Explore to find which files in this directory contain the word delta, and to report the file names back to you. Then reply with only those file names."],
        "resume_of": None}


def setup(cwd):
    for name, text in (("one.txt", "alpha beta\n"), ("two.txt", "gamma delta\n"), ("three.md", "delta again\n")):
        open(os.path.join(cwd, name), "w").write(text)
META["setup"] = setup


def run(session, ctx):
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=480)
    settled = wait_for_tasks(session, timeout=480)
    started = [f["frame"] for f in session.frames() if f.get("frame", {}).get("subtype") == "task_started"]
    ctx["notes"].append("task_started: %d, depths: %s, all settled: %s, result: %s" % (len(started), sorted(t.get("spawn_depth") for t in started), settled, (res or {}).get("subtype")))
    ctx["notes"].append("depth-2 text or thinking forwarded: %s" % any(
        f.get("frame", {}).get("type") == "assistant" and f["frame"].get("parent_tool_use_id") and
        any(b.get("type") in ("text", "thinking") for b in f["frame"]["message"].get("content", [])) for f in session.frames()))
```

`Tools/probe/scenarios/background_shell.py`:

```python
"""A run_in_background Bash, its task_notification and the auto-turn; the output file bundled as an artifact (items 61, 15; C3.G3)."""
META = {"name": "background-shell", "purpose": "background Bash, task_notification, auto-turn, task output file", "serves": ["item 61", "item 15", "C3.G3"],
        "spikes": [], "census": True, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 4},
        "prompts": ["Use the Bash tool with run_in_background=true to run exactly: sleep 6 && echo bg-done . Then immediately reply with the single word: started"],
        "resume_of": None, "setup": None}


def run(session, ctx):
    session.send_user(META["prompts"][0])
    first = session.wait_result(timeout=120)
    notif = session.wait_for(lambda f: f.get("type") == "system" and f.get("subtype") == "task_notification", timeout=90)
    second = session.wait_result(timeout=120) if notif else None          # wait_for is a cursor: this is the auto-turn's result
    ctx["notes"].append("first result: %s; task_notification: %s; output_file: %s; auto-turn result: %s" % (
        (first or {}).get("subtype"), bool(notif), (notif or {}).get("output_file"), (second or {}).get("subtype")))
    ctx["notes"].append("background_tasks_changed frames: %d" % sum(1 for f in session.frames() if f.get("frame", {}).get("subtype") == "background_tasks_changed"))
```

`Tools/probe/scenarios/notification_hook.py`:

```python
"""S18: the Notification hook registered through initialize.hooks fires while a permission ask waits (item 53)."""
import time

META = {"name": "notification-hook", "purpose": "a permission ask left waiting past the idle threshold; the hook_callback for afleet.notification and its input shape",
        "serves": ["item 53"], "spikes": ["S18"], "census": True, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 3},
        "prompts": ["Use the Write tool to create a file named waiting.txt containing the text: wait. Then reply with the single word: done"],
        "resume_of": None, "setup": None}
WAIT_SECONDS = 75


def run(session, ctx):
    seen = {}
    def hook(frame):
        seen["input"] = frame["request"].get("input"); seen["callback_id"] = frame["request"].get("callback_id"); seen["at"] = time.time()
        return {"continue": True}
    session.on("hook_callback", hook)
    def slow_allow(frame):
        t0 = time.time()
        while time.time() - t0 < WAIT_SECONDS and "input" not in seen:
            time.sleep(0.5)
        return {"behavior": "allow", "updatedInput": frame["request"].get("input", {})}
    session.on("can_use_tool", slow_allow)
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=240)
    ctx["notes"].append("hook_callback seen: %s; callback_id: %s; input keys: %s; result: %s" % (
        "input" in seen, seen.get("callback_id"), sorted((seen.get("input") or {}).keys()), (res or {}).get("subtype")))
    if "input" in seen:
        ctx["notes"].append("notification input: %s" % str(seen["input"])[:300])
```

- [ ] **Step 2: Record the four fixtures, one at a time**

Same loop as Task 9 Step 4 for `explore_depth_1`, `nested_depth_2`, `background_shell`, `notification_hook`. A scenario whose notes say `all settled: False` is re-recorded with a larger timeout rather than accepted, because `end_session` after an unsettled agent produces a truncated sidecar. Expected: `explore-depth-1` notes one `task_started` at depth 1 and `transcript/_slug_/<sid>/subagents/agent-<id>.jsonl` plus its `.meta.json` are present; `nested-depth-2` notes depths `[1, 2]` and two subagent files with their `.meta.json`; `background-shell` notes `task_notification: True` with an `output_file` whose recorded value in `frames.ndjson` reads `<artifacts>/…/tasks/<id>.output` and `artifacts/` holds it (`verify` checks this); `notification-hook` notes whether the hook fired inside 75 s and the input keys when it did. If `nested-depth-2` produces only depth 1, add to the prompt "You must delegate the search to an Explore subagent rather than searching yourself" and re-record once; note the outcome either way.

- [ ] **Step 3: Drift check and findings**

Run: `make probe` → all `ok`, exit 0.
Append to the parent's Revision Notes:
```
- 2026-09-04 C1/S16: A depth-2 run was captured (fixture `nested-depth-2`): `task_started`
  frames carry `spawn_depth` <1 and 2>, depth-2 <text/thinking was | was not> forwarded
  under `--forward-subagent-text`, and both subagents' `.meta.json` sidecars carry
  `parentAgentId`. Settles §8.8's two-step join input and item 49's fixture.
- 2026-09-04 C1/S18: With `Notification` registered through `initialize.hooks`, a
  permission ask left waiting <fired a `hook_callback` for `afleet.notification` after
  about N s with input keys <…> | did not fire within 75 s> (fixture `notification-hook`).
  <Settles §6.2's route and item 53 | Item 53 stays provisional; the idle threshold needs
  a setting, logged for C5>.
```

- [ ] **Step 4: Commit**

```bash
git add Tools/probe/scenarios/explore_depth_1.py Tools/probe/scenarios/nested_depth_2.py Tools/probe/scenarios/background_shell.py Tools/probe/scenarios/notification_hook.py docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md
git commit -m "feat(probe): wave C scenarios; S16 and S18 findings on the parent"
```

### Task 11: Spikes without fixtures — S6 baseline extraction, S10, S11, S12, S17 — and the `spike` subcommand

**Files:**
- Modify: `Tools/probe/probe.py` (a `spike` subcommand: run a scenario, print its notes, write no fixture)
- Create: `Tools/probe/scenarios/spike_worktree.py` (S10), `spike_resume_at.py` (S11), `spike_contention.py` (S12), `spike_agent_switch.py` (S17)
- Create: `Tools/probe/spikes/extract_dialog_enums.py` (S6)
- Modify: `Fixtures/dialog-refusal-fallback/fixture.json`, `Fixtures/dialog-fable-overage/fixture.json` (clear `hypothesis` when S6 closes)
- Modify: the parent's Revision Notes (`C1/S6:`, `C1/S10:`, `C1/S11:`, `C1/S12:`, `C1/S17:`)

**Interfaces:**
- Consumes: Task 5 `run_scenario`, `load_scenario`; the scenario contract with `META["fixture"] = False`.
- Produces: `probe.py spike <name>` printing `notes` as lines; findings.

- [ ] **Step 1: Add the `spike` subcommand**

In `probe.py` `main()`: add `"spike"` to the sub-parser tuple with `sp.add_argument("scenario")`, and:

```python
    if args.cmd == "spike":
        mod = load_scenario(args.scenario)
        session, ctx = run_scenario(mod, args.claude, args.config_home, SCRATCH_ROOT, redact.Redactor(), resume=resolve_resume(mod.META, FIXTURES_ROOT))
        for n in ctx["notes"]:
            print(n)
        print("exit code %s" % ctx["exit_code"])
        return 0
```

Add a Makefile target:
```make
spike:
	@test -n "$(SCENARIO)" || (echo "usage: make spike SCENARIO=<name>" && exit 2)
	$(PYTHON) Tools/probe/probe.py spike "$(SCENARIO)" --claude "$(CLAUDE)"
```

- [ ] **Step 2: S6 — extract the dialog enums from the installed 2.1.259 binary**

`Tools/probe/spikes/extract_dialog_enums.py`:

```python
#!/usr/bin/env python3
"""S6: confirm the dialog payload and result enums on the installed baseline binary.
Scans the binary's bytes for the literal strings; falls back to the extracted bundle when told to."""
import os
import re
import sys

VERSIONS = os.path.expanduser("~/.local/share/claude/versions")
NEEDLES = {
    "refusal_fallback_prompt": [rb'kind:"refusal_fallback_prompt"', rb'"retry_fallback","edit_prompt","cancelled"', rb"retractedMessageUuids", rb"guidanceText", rb"apiRefusalCategory"],
    "fable_overage_consent_prompt": [rb'kind:"fable_overage_consent_prompt"', rb'"consent","switch_default","cancelled"', rb"overagesEnabled", rb"balanceCents", rb"model_consent_fallback"],
}


def scan(path):
    """For each kind, find the dialog's own definition (`kind:"<kind>"`) and require every needle to sit
    inside the 800 bytes that follow it, so the enum and fields are structurally tied to that handler."""
    data = open(path, "rb").read()
    out = {}
    for kind, needles in NEEDLES.items():
        anchor = needles[0]
        windows = [data[i:i + 800] for i in [m.start() for m in re.finditer(re.escape(anchor), data)]]
        out[kind] = {"definitions": len(windows),
                     "needles_in_definition_window": {n.decode(): any(n in w for w in windows) for n in needles[1:]},
                     "context": windows[0][:800].decode("utf-8", "replace") if windows else ""}
    return out


def main():
    version = sys.argv[1] if len(sys.argv) > 1 else "2.1.259"
    candidates = [os.path.join(VERSIONS, version)] + sorted(f for f in [os.path.join(VERSIONS, version, x) for x in (os.listdir(os.path.join(VERSIONS, version)) if os.path.isdir(os.path.join(VERSIONS, version)) else [])] if os.path.isfile(f))
    hits = None
    for c in candidates:
        if os.path.isfile(c) and os.path.getsize(c) > 1_000_000:
            hits = scan(c); print("scanned", c); break
    if hits is None:
        print("no binary found under", VERSIONS); return 2
    ok = True
    for kind, info in hits.items():
        print("%s: %d definition(s)" % (kind, info["definitions"]))
        for needle, present in info["needles_in_definition_window"].items():
            print("   %-48s %s" % (needle, "in window" if present else "NOT in window"))
            ok = ok and present
        ok = ok and info["definitions"] > 0
        print("   context: %s" % info["context"][:800])
    print("ALL SHAPES STRUCTURALLY CONFIRMED" if ok else "NOT CONFIRMED (missing definition or a needle outside its window; if the binary is compressed, extract with the ~/claude-code-bundle tools and rerun on the largest module)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
```

Run: `/usr/bin/python3 Tools/probe/spikes/extract_dialog_enums.py 2.1.259`
Expected: one or more definitions per kind, every needle `in window`, and `ALL SHAPES STRUCTURALLY CONFIRMED`; paste the two printed contexts into the finding. If it prints `NOT CONFIRMED`, the binary embeds compressed JS: run the extraction the author used for 2.1.257 (`~/claude-code-bundle/2.1.257/tools/`, or the `update-bundle` skill) into `~/claude-code-bundle/2.1.259/` and rerun the scan against `~/claude-code-bundle/2.1.259/modules/*.js` by passing that directory's largest chunk path as the version argument. Either way, paste the counts into the finding.
Only when both kinds are structurally confirmed on 2.1.259: set `"hypothesis": false` in both dialog fixtures' `fixture.json`, keep `synthetic: true`, re-sign both (`make sign …`), `make verify-fixtures`, and commit `fixtures: S6 confirmed on 2.1.259, dialog fixtures leave hypothesis`. If not, leave them as they are.

- [ ] **Step 3: Write the four spike scenarios**

`Tools/probe/scenarios/spike_worktree.py` (S10):

```python
"""S10: -p with -w <name> creates and uses a worktree headless? (parent §7.7's *New isolated session*)."""
import os
import subprocess

META = {"name": "spike-worktree", "purpose": "S10: -w probe-wt under print mode", "serves": [], "spikes": ["S10"], "census": False, "fixture": False,
        "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 2, "worktree": "probe-wt"},
        "prompts": ["Run `pwd` with the Bash tool and reply with only the directory it prints."], "resume_of": None}


def setup(cwd):
    subprocess.run(["git", "init", "-q"], cwd=cwd, check=True)
    open(os.path.join(cwd, "README.md"), "w").write("probe\n")
    subprocess.run(["git", "add", "."], cwd=cwd, check=True)
    subprocess.run(["git", "-c", "user.email=probe@example.invalid", "-c", "user.name=probe", "commit", "-q", "-m", "init"], cwd=cwd, check=True)
META["setup"] = setup


def run(session, ctx):
    ctx["notes"].append("system/init cwd before turn: %s" % (session.system_init or {}).get("cwd"))
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=120)
    ctx["notes"].append("system/init cwd: %s; result: %r" % ((session.system_init or {}).get("cwd"), str((res or {}).get("result"))[:200]))
    wt = subprocess.run(["git", "worktree", "list"], cwd=ctx["cwd"], capture_output=True, text=True).stdout
    ctx["notes"].append("git worktree list:\n%s" % wt)
    ctx["notes"].append("stderr tail: %s" % session.stderr_tail(500))
```

`Tools/probe/scenarios/spike_resume_at.py` (S11):

```python
"""S11: is --resume-session-at <uuid> inclusive of that message? (parent §7.7's *Fork from here*)."""
import glob
import json
import os

META = {"name": "spike-resume-at", "purpose": "S11: --resume-session-at inclusivity", "serves": [], "spikes": ["S11"], "census": False, "fixture": False,
        "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 2}, "prompts": ["Reply with exactly: after"],
        "resume_of": "plain-two-turn"}


def pick_target(ctx):
    files = glob.glob(os.path.join(ctx["config_home"], "projects", "*", ctx["launch"].resume + ".jsonl"))
    records = [json.loads(l) for l in open(files[0]) if l.strip()]
    assistants = [r for r in records if r.get("type") == "assistant"]
    return assistants[0]["uuid"], len(records)


def run(session, ctx):
    # this scenario is run twice by hand: first to learn the uuid, then with the flag (see the plan step)
    target, before = pick_target(ctx)
    ctx["notes"].append("first assistant uuid: %s; records before: %d" % (target, before))
    session.send_user(META["prompts"][0]); session.wait_result(timeout=120)
    files = glob.glob(os.path.join(ctx["config_home"], "projects", "*", (session.system_init or {}).get("session_id", ctx["launch"].resume) + ".jsonl"))
    records = [json.loads(l) for l in open(files[-1]) if l.strip()]
    kept = [r.get("uuid") for r in records if r.get("type") in ("user", "assistant")]
    ctx["notes"].append("session file: %s; user/assistant uuids now: %s" % (os.path.basename(files[-1]), kept))
```

Run it twice: first `make spike SCENARIO=spike_resume_at` to read the first assistant uuid; then with the flag on the launch by exporting it through `extra_flags`: edit `META["launch"]["extra_flags"] = ["--resume-session-at", "<that uuid>", "--fork-session"]` for the second run and note whether the kept uuids include the target (inclusive) or stop before it (exclusive), then remove the edit.

`Tools/probe/scenarios/spike_contention.py` (S12):

```python
"""S12: a second holder against a live session's registry record (parent §7.2's Contended wording)."""
import glob
import json
import os
import pty
import subprocess
import time

META = {"name": "spike-contention", "purpose": "S12: headless --resume while an interactive claude --resume holds the session", "serves": [],
        "spikes": ["S12"], "census": False, "fixture": False, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 1},
        "prompts": [], "resume_of": "plain-two-turn"}


def registry(config_home):
    out = []
    for f in glob.glob(os.path.join(config_home, "sessions", "*.json")):
        try:
            d = json.load(open(f)); out.append({k: d.get(k) for k in ("pid", "kind", "status", "sessionId", "entrypoint")})
        except ValueError:
            pass
    return out


def run(session, ctx):
    sid = ctx["launch"].resume
    ctx["notes"].append("registry before: %s" % registry(ctx["config_home"]))
    master, slave = pty.openpty()
    env = dict(os.environ, CLAUDE_CONFIG_DIR=ctx["config_home"], TERM="xterm-256color")
    tui = subprocess.Popen(["claude", "--resume", sid], cwd=ctx["cwd"], stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
    time.sleep(8)
    ctx["notes"].append("registry with the interactive holder: %s" % registry(ctx["config_home"]))
    ctx["notes"].append("headless session (this one) handshake ok: %s; its stderr: %r" % (session.proc.poll() is None, session.stderr_tail(300)))
    try:
        os.write(master, b"/exit\r")
    except OSError:
        pass
    try:
        tui.wait(timeout=10)
    except subprocess.TimeoutExpired:
        tui.terminate()
    ctx["notes"].append("registry after: %s" % registry(ctx["config_home"]))
```

Note the order this produces: the harness spawned the headless `--resume` first (that is `session`), then the TUI joins; run `make spike SCENARIO=spike_contention` and read the registry lines: record whether both processes register with the same `sessionId`, what `status` each shows, whether either exits or prints a warning. Then, to observe the other order, start the TUI by hand in a second terminal first (`CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home claude --resume <plain-two-turn sid>` in `/tmp/afleet-fixtures/plain-two-turn`) and run `make spike SCENARIO=spike_contention` again; note the headless handshake outcome and stderr.

`Tools/probe/scenarios/spike_agent_switch.py` (S17):

```python
"""S17: does apply_flag_settings {agent} take effect on the next turn, and does --agent persist across --resume? (parent §7.7 restart rule)."""
import os

AGENT = """---
name: probe-agent
description: A probe agent that marks its replies.
---
You are the probe agent. Begin every reply with the exact word PROBEAGENT and then answer briefly.
"""
META = {"name": "spike-agent-switch", "purpose": "S17: runtime agent switch and agent persistence", "serves": [], "spikes": ["S17"], "census": False,
        "fixture": False, "deterministic": False, "isolation": "config-home", "launch": {"max_turns": 2, "setting_sources": "project"},
        "prompts": ["Reply with exactly: plain", "Reply with one short sentence about the weather."], "resume_of": None}


def setup(cwd):
    os.makedirs(os.path.join(cwd, ".claude", "agents"), exist_ok=True)
    open(os.path.join(cwd, ".claude", "agents", "probe-agent.md"), "w").write(AGENT)
META["setup"] = setup


def text_of(res):
    return str((res or {}).get("result"))[:120]


def run(session, ctx):
    session.send_user(META["prompts"][0]); r1 = session.wait_result(timeout=120)
    ctx["notes"].append("turn 1 (no agent): %r" % text_of(r1))
    r = session.request("apply_flag_settings", settings={"agent": "probe-agent"})
    ctx["notes"].append("apply_flag_settings agent -> %s" % r.get("subtype"))
    session.send_user(META["prompts"][1]); r2 = session.wait_result(timeout=120)
    ctx["notes"].append("turn 2 (after apply_flag_settings): %r; starts with PROBEAGENT: %s" % (text_of(r2), text_of(r2).startswith("PROBEAGENT")))
    ctx["notes"].append("agents in initialize/system init: %s" % [a.get("name") for a in (session.system_init or {}).get("agents", []) if isinstance(a, dict)])
```

For the persistence half, run two more spikes by hand with the harness from a Python shell (documented in the step): launch `--agent probe-agent` in the same scratch cwd, one turn, close; then `--resume <sid>` without `--agent`, one turn; note whether the resumed reply starts with `PROBEAGENT`. The exact commands:

```bash
cd /tmp/afleet-fixtures/spike-agent-switch && CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home /usr/bin/python3 - <<'EOF'
import sys, uuid; sys.path.insert(0, "/Users/new/Developer/GitHub/afleet-c1/Tools/probe")
import harness, redact
sid = str(uuid.uuid4())
s = harness.Session(harness.Launch(cwd=".", session_id=sid, agent="probe-agent", setting_sources="project", max_turns=2), redact.Redactor()); s.start()
s.send_user("Reply with one short sentence about the sea."); print("with --agent:", str(s.wait_result(120).get("result"))[:100]); s.close()
s = harness.Session(harness.Launch(cwd=".", resume=sid, setting_sources="project", max_turns=2), redact.Redactor()); s.start()
s.send_user("Reply with one short sentence about the sky."); print("after --resume without --agent:", str(s.wait_result(120).get("result"))[:100]); s.close()
EOF
```

- [ ] **Step 4: Run the spikes and write the findings**

Run each: `make spike SCENARIO=spike_worktree`, `make spike SCENARIO=spike_resume_at` (twice, per Step 3), `make spike SCENARIO=spike_contention` (both orders), `make spike SCENARIO=spike_agent_switch` plus the persistence commands. Append to the parent's Revision Notes, facts only:
```
- 2026-09-04 C1/S6: <Every needle for both dialog kinds is present in the installed 2.1.259
  binary (counts …); the two synthetic fixtures leave hypothesis and item 62 is no longer
  provisional | The 2.1.259 binary could not be scanned (…); S6 stays open, the two
  fixtures keep hypothesis: true, and item 62 stays provisional>.
- 2026-09-04 C1/S10: `-p -w probe-wt` <created a worktree at … and system/init.cwd pointed
  into it | was accepted but the session ran in the main tree | was refused with …>.
  §7.7's *New isolated session* <stands | is a restart-only action | is dropped>.
- 2026-09-04 C1/S11: `--resume-session-at <uuid> --fork-session` keeps messages <up to and
  including | before> the target; *Fork from here* <includes | excludes> the clicked message.
- 2026-09-04 C1/S12: With an interactive `claude --resume` holding the session, a headless
  `--resume` <completed its handshake and both registered under the same sessionId with
  statuses … | failed with …>; in the other order <…>. §7.2's Contended state <is
  reachable as designed | needs the wording …>.
- 2026-09-04 C1/S17: `apply_flag_settings {agent}` <changed | did not change> the next
  turn's behaviour; a session launched with `--agent` <kept | lost> the agent after
  `--resume` without the flag. §7.7's `/agent` row <can use apply_flag_settings | stays a
  quiescent restart> and the restart <must | need not> re-pass `--agent`.
```

- [ ] **Step 5: Commit**

```bash
git add Tools/probe/probe.py Makefile Tools/probe/spikes Tools/probe/scenarios/spike_*.py Fixtures/dialog-refusal-fallback Fixtures/dialog-fable-overage docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md
git commit -m "feat(probe): spike subcommand, S6 extraction and the S10, S11, S12, S17 spikes; findings on the parent"
```

### Task 12: Final verification against the spec's acceptance

**Files:**
- Modify: `docs/doperpowers/specs/2026-09-04-c1-probe-suite-fixtures-fake-claude.md` (Outcomes & Retrospective, Surprises, Revision Notes)

- [ ] **Step 1: Tool tests on both interpreters**

Run: `make test-tools` and `PYTHON=/opt/homebrew/bin/python3 make test-tools`
Expected: both print `OK` twice (probe tests, fake-claude tests).

- [ ] **Step 2: G1 — the fixture catalogue**

Run:
```bash
/usr/bin/python3 - <<'EOF'
import json, os
want = ["plain-two-turn","permission-allow","permission-deny","ask-user-question","exit-plan-mode","explore-depth-1","nested-depth-2",
        "background-shell","session-mirror-relocation","session-mirror-resume","send-user-file","control-shapes","resume-no-replay",
        "zero-cost","dialog-refusal-fallback","dialog-fable-overage"]
for n in want:
    p = os.path.join("Fixtures", n); m = json.load(open(os.path.join(p, "fixture.json")))
    frames = [json.loads(l) for l in open(os.path.join(p, "frames.ndjson")) if l.strip()]
    mirrors = sum(1 for f in frames if f.get("frame", {}).get("type") == "transcript_mirror")
    print("%-28s signed=%s synthetic=%s hypothesis=%s mirrors=%d initial=%s streams=%s" % (
        n, bool(m["review"]["reviewer"]), m["synthetic"], m["hypothesis"], mirrors, os.path.isdir(os.path.join(p, "initial")), os.path.isfile(os.path.join(p, "streams.json"))))
EOF
make verify-fixtures
```
Expected: sixteen lines, every `signed=True`, every recorded fixture (`synthetic=False`) with `mirrors>=1` except `zero-cost` and `resume-no-replay` (no turn), `initial=True streams=True` everywhere; `all fixtures pass`. Also check by hand: `ls Fixtures/nested-depth-2/transcript/_slug_/*/subagents/` shows two `agent-*.jsonl` and two `.meta.json`; `ls Fixtures/background-shell/artifacts/` is non-empty; `grep -c tools/call Fixtures/send-user-file/frames.ndjson` ≥ 1.

- [ ] **Step 3: G2 — the drift ritual against the CLI and against fake-claude**

Run: `make probe` → every `census: true` fixture prints `ok`, exit 0.
Run:
```bash
printf '[{"after": 3, "emit": {"type": "afleet_invented", "x": 1}}]' > /tmp/afleet-invented.json
make probe CLAUDE=Tools/fake-claude/fake-claude FIXTURE=plain-two-turn SCRIPT=/tmp/afleet-invented.json; echo "exit=$?"
printf '[{"patch": {"type": "system", "subtype": "init"}, "remove": ["capabilities"]}]' > /tmp/afleet-removed.json
make probe CLAUDE=Tools/fake-claude/fake-claude FIXTURE=plain-two-turn SCRIPT=/tmp/afleet-removed.json; echo "exit=$?"
```
Expected: the first prints `plain-two-turn: DRIFT` with exactly one `added pair afleet_invented` line and `exit=1`; the second prints a `removed required keys capabilities` line for `system/init` and `exit=1`. (`make probe` passes `FAKE_CLAUDE_FIXTURE` through `probe.py diff`, which sets it per fixture; the scenario drives fake-claude with the same prompts it recorded.)

- [ ] **Step 4: G3 — findings**

Run: `grep -n 'C1/S' docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md`
Expected: one dated note for each of S2, S5, S6, S8, S10, S11, S12, S13, S14, S15, S16, S17, S18, each naming the parent clause it settles. Any `[parent-impact]` written during the waves is listed in the child spec's Surprises section.

- [ ] **Step 5: G4 — redaction gates**

Run:
```bash
test ! -d Fixtures/*/raw && echo "no raw dirs"
cd Tools/probe/tests && /usr/bin/python3 -m unittest -v \
  test_probe_cli.RecordAndDiffTests.test_record_no_unredacted_byte_reaches_disk_and_review_is_unsigned \
  test_fixture_verify.VerifyTests.test_unsigned_review_fails \
  test_fixture_verify.VerifyTests.test_planted_email_fails_in_any_file \
  test_fixture_verify.VerifyTests.test_orphaned_request_fails \
  test_fixture_verify.SlugAndSnapshotTests.test_collect_artifacts_and_tokenise; cd ../../..
```
Expected: `Ran 5 tests` and `OK` (fully qualified names, so an empty selection cannot pass silently): unsigned review, planted email and unresolved lifecycle fail `verify`; the record test and the artifact test prove no unredacted byte reaches disk.

- [ ] **Step 6: Write the child's Outcomes and hand back to the parent**

Replace `Pending — written at finish.` under `## Outcomes & Retrospective` in the child spec with: the gate results (G1 through G4 and the tool tests, each with the command and its observed output line), the list of spikes settled versus left open, the number of live recordings and the approximate cost line from `get_session_cost` of the last `zero-cost` run, what surprised (copied from the Surprises section), and what the next owner should know (the scratch-home login, the S15 value, the fallback launch if S5 needed it). Add a Revision Note `- 2026-09-04: v3, execution complete; gates verified as listed in Outcomes.` Commit:

```bash
git add docs/doperpowers/specs/2026-09-04-c1-probe-suite-fixtures-fake-claude.md
git commit -m "docs(c1): outcomes and retrospective; gates verified"
```

Then report to the parent session: the branch tip, the gate results, and which parent Revision Notes were added. The merge to `main` is the parent's step (parent §17.6 dispatch mechanics).

---

## Questions left for the human

Each was answered with the recommendation below and the plan follows it; overrule by editing the spec or the plan before dispatch.

1. **Two modules more than the spec names.** `fixture.py` and `verify.py` were added beside `probe.py`, `harness.py`, `census.py`, `redact.py` (Task 1 records this in the spec). Recommendation: keep; the spec's list was illustrative, not a contract.
2. **Record-for-record, not byte-for-byte, for transcript replay equality.** The CLI emits `transcript_mirror.entries` as parsed objects (bundle `chunk-sct99ax9.js`: `entries: R(de())`), so fake-claude re-serialises them; the final-state test compares parsed records per line for transcript files and bytes for artifacts (Task 6). Recommendation: accept; the self-review below records it on the spec.
3. **The relocation row becomes two fixtures.** `session-mirror-relocation` and `session-mirror-resume` (Task 9), because one fixture is one process. Recommendation: accept.
4. **A `patch` script step** (`{"patch": {matcher}, "remove": [keys]}`) was added to fake-claude so G2's "removes a required key from `system/init`" case is producible (Task 6). Recommendation: accept as an additive X8 field.
5. **The `notification-hook` recording may not fire inside its 75-second budget**; if it does not, item 53 stays provisional and the idle threshold becomes a C5 setting question (Task 10). Recommendation: accept the outcome as the finding rather than extending the budget past two minutes.
