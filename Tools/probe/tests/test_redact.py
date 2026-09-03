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
