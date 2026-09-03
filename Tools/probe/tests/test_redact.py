import copy
import socket
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

    def test_single_letter_tld_and_deliberate_over_match(self):
        # The TLD quantifier is `+`, so a one-character TLD is caught (fail-closed) and
        # version specifiers are over-matched. Both are intended; pin them so a fixture
        # reviewer meeting `<email>` where `pkg@1.x` was is not surprised.
        self.assertEqual(self.r.redact_text("a@b.c"), "<email>")
        self.assertEqual(self.r.redact_text("install pkg@1.x"), "install <email>")

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


class RedactKeyTests(unittest.TestCase):
    """C1: a string in key position is data too."""

    def setUp(self):
        self.r = redact.Redactor(home="/Users/probe", hostname="probe-mac")

    def test_home_path_and_email_in_key_position_are_redacted(self):
        out = self.r.redact_json({"projects": {"/Users/probe/code/app": {"a": 1}},
                                  "contacts": {"a.b@example.com": {"n": 1}}})
        self.assertEqual(out, {"projects": {"~/code/app": {"a": 1}},
                               "contacts": {"<email>": {"n": 1}}})

    def test_colliding_redacted_keys_are_disambiguated(self):
        out = self.r.redact_json({"a@x.com": 1, "b@y.com": 2})
        self.assertEqual(out, {"<email>": 1, "<email>#2": 2})
        self.assertEqual(self.r.redact_json(out), out)

    def test_manifest_paths_do_not_leak_the_home_directory(self):
        self.r.redact_json({"projects": {"/Users/probe/code/app": {"token": "t"}}})
        self.assertIn("projects.~/code/app.token", self.r.manifest()["rules"]["secrets"]["paths"])
        self.assertEqual(redact.scan(self.r.manifest(), home="/Users/probe"), [])

    def test_scan_flags_strings_in_key_position(self):
        hits = redact.scan({"projects": {"/Users/probe/code/app": {}}, "c": {"a.b@example.com": {}}},
                           home="/Users/probe")
        self.assertEqual(len(hits), 2)
        self.assertTrue(all("in key" in h for h in hits))


class SecretKeyPredicateTests(unittest.TestCase):
    """C2 and I3: the predicate `redact_json` and `scan` share."""

    def setUp(self):
        self.r = redact.Redactor(home="/Users/probe", hostname="probe-mac")

    def test_plural_token_field_is_redacted_but_int_counters_survive(self):
        out = self.r.redact_json({"access_tokens": "aBcD1234secretvalue", "ephemeral_5m_input_tokens": 12})
        self.assertEqual(out["access_tokens"], "<redacted>")
        self.assertEqual(out["ephemeral_5m_input_tokens"], 12)
        self.assertEqual(redact.scan({"access_tokens": "aBcD1234secretvalue"}, home="/Users/probe"),
                         ["access_tokens: secret-named field not redacted"])

    def test_password_and_bearer_named_fields(self):
        self.assertEqual(self.r.redact_json({"password": "p", "bearerToken": "b", "PASSWORD": "q"}),
                         {"password": "<redacted>", "bearerToken": "<redacted>", "PASSWORD": "<redacted>"})

    def test_session_key_is_secret_but_project_key_is_structural(self):
        # projectKey names a directory the GUI must read (parity 03-49-35 line 186), so it
        # keeps its exemption. sessionKey has no such record and occurs credential-shaped,
        # so it is redacted like any other key-named field.
        out = self.r.redact_json({"sessionKey": "s3cret", "session_key": "s3cret", "projectKey": "p"})
        self.assertEqual(out, {"sessionKey": "<redacted>", "session_key": "<redacted>", "projectKey": "p"})
        self.assertEqual(redact.scan({"sessionKey": "s3cret"}, home="/Users/probe"),
                         ["sessionKey: secret-named field not redacted"])
        self.assertEqual(redact.scan({"projectKey": "p"}, home="/Users/probe"), [])

    def test_camelcase_and_cased_identity_keys(self):
        out = self.r.redact_json({"subscriptionType": "max", "accountUuid": "u", "Account": {"x": 1},
                                  "user_id": 7, "emailAddress": "opaque-id-12345", "organizationId": 3})
        self.assertEqual(out, {"subscriptionType": "<subscriptionType>", "accountUuid": "<accountUuid>",
                               "Account": "<Account>", "user_id": "<user_id>", "emailAddress": "<email>",
                               "organizationId": "<organizationId>"})
        self.assertEqual(len(redact.scan({"subscriptionType": "max"}, home="/Users/probe")), 1)

    def test_name_shaped_identity_keys_are_exact_never_substring(self):
        out = self.r.redact_json({"organizationName": "Acme", "userName": "pp", "accountName": "a",
                                  "fullName": "Probe Person", "toolName": "Bash", "serverName": "afleet",
                                  "modelName": "opus", "displayName": "Claude Opus 5 (1M context)"})
        self.assertEqual(out, {"organizationName": "<organizationName>", "userName": "<userName>",
                               "accountName": "<accountName>", "fullName": "<fullName>",
                               # displayName is a list_models / plugin / slash-command row field,
                               # not identity; redacting it would empty the model picker.
                               "toolName": "Bash", "serverName": "afleet", "modelName": "opus",
                               "displayName": "Claude Opus 5 (1M context)"})

    def test_hook_event_keys_are_structural_and_survive(self):
        hooks = {"hooks": {"UserPromptSubmit": [{"matcher": "*"}], "PreToolUse": []}}
        self.assertEqual(self.r.redact_json(hooks), hooks)


class FrameFailClosedTests(unittest.TestCase):
    """I4 and I5: the request subtype is a hint, not a gate."""

    def setUp(self):
        self.r = redact.Redactor(home="/Users/probe", hostname="probe-mac")

    def test_uncorrelated_response_still_drops_settings_and_oauth_queries(self):
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "rX", "response": {
            "effective": {"env": {"P": "hunter2"}},
            "nested": {"manualUrl": "https://claude.ai/o?code_challenge=abc&state=xyz"}}}}
        body = self.r.redact_frame(resp, "in", {})["response"]["response"]
        self.assertNotIn("effective", body)
        self.assertEqual(body["effective_keys"], ["env"])
        self.assertEqual(body["nested"]["manualUrl"], "https://claude.ai/o?<redacted>")

    def test_correlated_non_oauth_response_keeps_its_urls(self):
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r7",
                "response": {"docsUrl": "https://docs.test/page?section=intro"}}}
        body = self.r.redact_frame(resp, "in", {"r7": "get_settings"})["response"]["response"]
        self.assertEqual(body["docsUrl"], "https://docs.test/page?section=intro")

    def test_correlated_non_mcp_body_keeps_an_oversized_mcp_response_key(self):
        big = {"jsonrpc": "2.0", "id": 1, "method": "m", "params": {"blob": "x" * 5000}}
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r9",
                "response": {"mcp_response": big}}}
        out = self.r.redact_frame(resp, "in", {"r9": "list_models"})["response"]["response"]
        self.assertEqual(out["mcp_response"], big)
        # Uncorrelated stays fail-closed: no subtype means it could be an MCP body.
        out2 = self.r.redact_frame(resp, "in", {})["response"]["response"]
        self.assertIn("truncated", out2["mcp_response"])

    def test_correlated_non_settings_body_keeps_an_effective_key(self):
        body = {"effective": {"model": "opus"}, "sources": ["a"]}
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r8",
                "response": body}}
        out = self.r.redact_frame(resp, "in", {"r8": "list_models"})["response"]["response"]
        self.assertEqual(out, {"effective": {"model": "opus"}, "sources": ["a"]})

    def test_non_dict_effective_is_still_dropped(self):
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r2",
                "response": {"effective": "model=opus;env.SECRET=hunter2"}}}
        body = self.r.redact_frame(resp, "in", {"r2": "get_settings"})["response"]["response"]
        self.assertNotIn("effective", body)
        self.assertEqual(body["effective_keys"], [])

    def test_redact_frame_does_not_mutate_the_caller_frame(self):
        frames = [({"type": "control_request", "request_id": "r1", "request": {"subtype": "mcp_message",
                    "message": {"jsonrpc": "2.0", "id": 7, "method": "t", "params": {"b": "x" * 5000}}}}, {}),
                  ({"type": "control_response", "response": {"request_id": "r2", "response": {
                    "effective": {"model": "opus"}, "url": "https://c.ai/o?a=b"}}}, {"r2": "get_settings"}),
                  ({"type": "assistant", "message": {"text": "from /Users/probe on probe-mac"}}, {})]
        for frame, subs in frames:
            before = copy.deepcopy(frame)
            self.r.redact_frame(frame, "in", subs)
            self.assertEqual(frame, before)


class ManifestAndScanContractTests(unittest.TestCase):
    def setUp(self):
        self.r = redact.Redactor(home="/Users/probe", hostname="probe-mac")

    def test_manifest_is_idempotent_across_runs(self):
        frame = {"type": "control_response", "response": {"request_id": "r3",
                 "response": {"manualUrl": "https://c.ai/o?a=b"}}}
        subs = {"r3": "claude_authenticate"}
        once = self.r.redact_frame(frame, "in", subs)
        first = self.r.manifest()
        self.r.redact_frame(once, "in", subs)
        self.assertEqual(self.r.manifest(), first)

    def test_scan_is_clean_on_redactor_output(self):
        payload = {"account": {"uuid": "u"}, "subscriptionType": "max", "apiKeySource": "user",
                   "emailAddress": "opaque-id-1", "accessToken": "sk-ant-api03-XYZ", "oauth": {"r": "t"},
                   "access_tokens": "aBcD1234secretvalue", "input_tokens": 5,
                   "projects": {"/Users/probe/code/app": {"note": "dev.ops@corp.example on probe-mac"}},
                   "url": "https://x.test/cb?code=0123456789abcdef0123456789abcdef"}
        out = self.r.redact_json(payload)
        self.assertEqual(redact.scan(out, home="/Users/probe", hostname="probe-mac"), [])

    def test_scan_defaults_to_the_local_hostname_and_takes_an_override(self):
        self.assertEqual(redact.scan({"a": "built on probe-mac"}, home="/Users/probe", hostname="probe-mac"),
                         ["a: hostname"])
        self.assertEqual(redact.scan({"a": "built on " + socket.gethostname()}, home="/Users/probe"),
                         ["a: hostname"])
        # An explicit hostname replaces the default rather than adding to it.
        self.assertEqual(redact.scan({"a": "built on probe-mac"}, home="/Users/probe", hostname="other-mac"), [])

    def test_scan_catches_the_defaulted_hostname_in_key_position(self):
        # Key position is the path that composes finding text, so a hostname the scanner was
        # never given would ride into a finding that is safe to persist by assumption only.
        host = socket.gethostname()
        hits = redact.scan({host: {"accessToken": "x"}}, home="/Users/probe")
        self.assertIn("<host>: hostname in key", hits)
        self.assertIn("<host>.accessToken: secret-named field not redacted", hits)
        self.assertNotIn(host, " | ".join(hits))

    def test_scan_flags_an_unredacted_api_key_source(self):
        self.assertEqual(redact.scan({"apiKeySource": "user"}, home="/Users/probe"),
                         ["apiKeySource: identity field not redacted"])
        self.assertEqual(redact.scan({"apiKeySource": "none"}, home="/Users/probe"), [])
        self.assertEqual(redact.scan({"apiKeySource": "<apiKeySource>"}, home="/Users/probe"), [])

    def test_report_only_tolerates_a_missing_home(self):
        self.assertEqual(redact.scan_report_only("in /Users/someone/x", author=None, home=None),
                         ["line 1: path under /Users: /Users/<user>"])

    def test_scan_findings_never_quote_what_they_found(self):
        # The invariant Tasks 4 and 5 rely on: a finding names the rule and the position and
        # never the material, so it is safe to persist as well as to print.
        planted = {"projects": {"/Users/probe/code/app": {"note": "a.b@example.com",
                                                          "accessToken": "sk-ant-api03-SECRETVALUE"}},
                   "host": "built on probe-mac"}
        hits = redact.scan(planted, home="/Users/probe", hostname="probe-mac")
        blob = " | ".join(hits)
        for literal in ("/Users/probe", "a.b@example.com", "sk-ant-api03-SECRETVALUE", "probe-mac"):
            self.assertNotIn(literal, blob)
        self.assertIn("projects.~/code/app: home directory in key", hits)
        self.assertIn("projects.~/code/app.note: email", hits)
        self.assertIn("projects.~/code/app.accessToken: secret-named field not redacted", hits)
        self.assertIn("host: hostname", hits)

    def test_report_only_findings_never_quote_what_they_found(self):
        text = "committed by Probe Person\nand touched /Users/someone/secret-dir\n"
        hits = redact.scan_report_only(text, author="Probe Person", home="/Users/probe")
        blob = " | ".join(hits)
        self.assertNotIn("Probe Person", blob)
        self.assertNotIn("someone", blob)
        self.assertEqual(hits, ["line 1: configured author name appears",
                                "line 2: path under /Users: /Users/<user>"])


if __name__ == "__main__":
    unittest.main()
