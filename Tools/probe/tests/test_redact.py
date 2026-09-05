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


    def test_an_ls_long_listing_loses_its_owner_and_group_columns(self):
        """A directory listing carries the account name where no other rule looks: not the home
        path, not the hostname, not an identity-named field."""
        listing = ("total 24\n"
        "drwxr-xr-x@  5 probeuser  wheel   160  9 4 20:54 .\n"
        "-rw-r--r--@  1 probeuser  staff    11  9 4 20:54 one.txt\n"
        "lrwxr-xr-x   1 probeuser  staff     3  9 4 20:54 link -> one.txt\n")
        out = self.r.redact_text(listing)
        self.assertNotIn("probeuser", out)
        self.assertNotIn("wheel", out)
        self.assertNotIn("staff", out)
        self.assertEqual(out.count("<user>"), 3)
        self.assertEqual(out.count("<group>"), 3)
        self.assertIn("one.txt", out)          # the rest of the line is evidence and stays
        self.assertIn("total 24", out)

    def test_the_owner_column_rule_is_positional_and_idempotent(self):
        """It cannot know the account name, and `redact` re-runs on committed fixtures."""
        once = self.r.redact_text("-rw-r--r--  1 someone  somegroup  4 x")
        self.assertEqual(once, "-rw-r--r--  1 <user>  <group>  4 x")
        self.assertEqual(self.r.redact_text(once), once)

    def test_the_owner_column_rule_does_not_reach_prose(self):
        """A mode string needs a link count after it, which prose does not supply. This is why
        the account name is not substituted wherever it appears: it is an ordinary word."""
        for s in ("the new wheel is round",
                  "-rw-r--r-- means owner-writable",
                  "5 probeuser wheel spokes",
                  "chmod to drwxr-xr-x when done"):
            self.assertEqual(self.r.redact_text(s), s)


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

    def test_secret_named_fields_are_replaced_whatever_their_value_type(self):
        """Was `..._string_fields_only`. The name recorded the blind spot rather than the rule:
        §4.5 replaces any secret-named field, and restricting that to strings let a container
        under the same key reach disk. `key` is the one assertion that moves -- a dict of
        strings under a bare `key` is now redacted whole, which costs the nested `projectKey`
        its exemption in that one position. Nothing in the corpus has that shape, and the
        alternative is leaving every secret-named container unredacted."""
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
        self.assertEqual(out["key"], "<redacted>")
        self.assertEqual(out["hookCallbackIds"], ["afleet.notification"])

    def test_a_secret_named_container_is_redacted_whole_and_scan_says_so(self):
        """The leak this closes. A secret-named key whose value was a dict, a list or a number
        was left alone unless the key was exactly `oauth`, `credentials` or `credential`, and
        `scan` shared the blind spot, so each of these reached disk *and* passed the gate."""
        for obj, expected in (({"authorization": {"value": "Bearer abc123"}}, {"authorization": "<redacted>"}),
                              ({"cookies": [{"value": "session-secret"}]}, {"cookies": "<redacted>"}),
                              ({"api_keys": {"primary": "opaque-secret"}}, {"api_keys": "<redacted>"}),
                              ({"secret": 1234567890}, {"secret": "<redacted>"}),
                              ({"nested": {"clientSecret": ["a", "b"]}}, {"nested": {"clientSecret": "<redacted>"}})):
            out = self.r.redact_json(obj)
            self.assertEqual(out, expected)
            self.assertEqual(redact.scan(out, home="/Users/probe", hostname="probe-mac"), [], obj)
            hits = redact.scan(obj, home="/Users/probe", hostname="probe-mac")
            self.assertTrue(any("secret-named field not redacted" in h for h in hits), (obj, hits))
            # And the finding still names only the rule and the position, never the container.
            for h in hits:
                self.assertNotIn("Bearer", h); self.assertNotIn("opaque", h); self.assertNotIn("1234567890", h)

    def test_the_protocol_structure_under_secret_named_keys_survives_the_container_rule(self):
        """The three things that sit under keys the predicate matches and must not be redacted:
        the setting names rule 5 leaves in key position, the token counters the engine reports
        in several name shapes, and a null under a secret-named key. A setting called
        `apiKeyHelper` names the field the container rule replaces the *value* of, so the name
        survives the rule that its own spelling would otherwise trip."""
        body = {"effective": {"env": "<redacted>", "apiKeyHelper": "<redacted>"},
                "sources": [{"source": "userSettings", "settings": {"a": "<redacted>", "token": "<redacted>"}}],
                "rate_limits": {"seven_day_oauth_apps": None}}
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r2", "response": body}}
        out = self.r.redact_frame(resp, "in", {"r2": "get_settings"})["response"]["response"]
        self.assertEqual(out["effective"], {"env": "<redacted>", "apiKeyHelper": "<redacted>"})
        self.assertEqual(out["sources"], [{"source": "userSettings",
                                           "settings": {"a": "<redacted>", "token": "<redacted>"}}])
        self.assertIsNone(out["rate_limits"]["seven_day_oauth_apps"])
        counters = {"usage": {"output_tokens_details": {"thinking_tokens": 101}, "input_tokens": 5},
                    "estimated_tokens_delta": 35, "estimated_tokens": None,
                    "modelUsage": {"claude-haiku-4-5": {"cacheReadInputTokens": 7, "maxOutputTokens": 64}},
                    "messageBreakdown": {"toolResultTokens": 12},
                    "_meta": {"progressToken": 3}}
        self.assertEqual(self.r.redact_json(counters), counters)
        self.assertEqual(redact.scan(counters, home="/Users/probe", hostname="probe-mac"), [])
        # The counter exemption is the value's doing, not the name's: the same names carrying
        # a string are credentials again.
        self.assertEqual(self.r.redact_json({"cacheReadInputTokens": "sk-ant-x"}), {"cacheReadInputTokens": "<redacted>"})
        self.assertEqual(self.r.redact_json({"oauth_tokens": 12}), {"oauth_tokens": "<redacted>"})

    def test_idempotent(self):
        obj = {"account": {"email": "a@b.c"}, "token": "t", "text": "/Users/probe/x a@b.c"}
        once = self.r.redact_json(obj)
        self.assertEqual(self.r.redact_json(once), once)

    def test_the_manifest_names_a_replaced_subtree_rather_than_counting_it_anonymously(self):
        """Rule 2 replaces a secret-named container whole, which can take structure a consumer
        needed with it -- a nested `projectKey` is the case that would hurt. That the corpus has
        no such shape is a fact about eighteen recordings against one engine version, not a
        property of the protocol, so the loss has to be visible to the reviewer walking REVIEW
        item 4 rather than showing up as an anonymous increment to `count`."""
        self.r.redact_json({"authorization": {"value": "Bearer x"}, "api_key": "k",
                            "nested": {"cookies": ["a", "b"]}})
        secrets = self.r.manifest()["rules"]["secrets"]
        self.assertEqual(secrets["count"], 3)
        self.assertEqual(sorted(secrets["paths"]), ["api_key", "authorization", "nested.cookies"])
        # Only the two containers, and the scalar is not among them.
        self.assertEqual(secrets["subtrees"], {"authorization": 1, "nested.cookies": 1})
        # A rule that replaced no container says so by the key's absence, which is what keeps
        # `redaction.json` the file it already is for every fixture in the corpus.
        self.assertNotIn("subtrees", self.r.manifest()["rules"]["identity"])
        scalars_only = redact.Redactor(home="/Users/probe", hostname="probe-mac")
        scalars_only.redact_json({"api_key": "k"})
        self.assertNotIn("subtrees", scalars_only.manifest()["rules"]["secrets"])

    def test_a_subtree_record_merges_with_the_one_already_on_disk(self):
        """`redact` adds to the manifest rather than replacing it, and this half has to travel
        the same way or a re-run drops the record of what the recording ate."""
        prior = {"rules": {"secrets": {"count": 1, "paths": {"authorization": 1},
                                       "subtrees": {"authorization": 1}}}}
        self.r.redact_json({"nested": {"cookies": ["a"]}})
        merged = self.r.manifest(prior)["rules"]["secrets"]
        self.assertEqual(merged["subtrees"], {"authorization": 1, "nested.cookies": 1})
        self.assertEqual(merged["count"], 2)

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

    def test_a_settings_body_keeps_the_engines_shape_and_loses_its_values(self):
        """Rule 5 replaces values and changes nothing else -- not a key name, not a shape.

        The engine answers `get_settings` with `{effective: {<setting name>: <value>}, sources:
        [{source, settings: {<setting name>: <value>}}], applied, errors?}` (2.1.258
        `cli.pretty.js`, the handler and `aRn()`). A fixture is evidence of what the engine
        sends, so a rule that invents a key name of its own writes evidence of something that
        never happened and teaches a consumer to read a field no engine will ever send. Setting
        *names* are not secrets and stay; every value goes, whatever its type.
        """
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r2", "response": {
            "effective": {"model": "opus", "env": {"SECRET": "x"}},
            "sources": [{"source": "userSettings", "settings": {"a": 1, "apiKeyHelper": "/bin/x"}}],
            "applied": {"model": "opus", "effort": "high"}}}}
        out = self.r.redact_frame(resp, "in", {"r2": "get_settings"})
        body = out["response"]["response"]
        self.assertEqual(list(body), ["effective", "sources", "applied"])
        self.assertEqual(body["effective"], {"model": "<redacted>", "env": "<redacted>"})
        self.assertEqual(body["sources"], [{"source": "userSettings",
                                            "settings": {"a": "<redacted>", "apiKeyHelper": "<redacted>"}}])
        self.assertEqual(body["applied"], {"model": "opus", "effort": "high"})
        self.assertEqual(redact.scan(body, home="/Users/probe", hostname="probe-mac"), [])

    def test_the_shape_rule_5_used_to_write_is_upgraded_in_place(self):
        """`make redact` over a fixture recorded under the older rule, which replaced the two
        fields with `effective_keys` and `sources_keys` of its own invention. The names it kept
        were the setting names, so the upgrade is lossless: they go back where the engine puts
        them, with the values already gone. Idempotent, like every other rule: a second pass
        finds `effective` and `sources` and leaves them alone."""
        legacy = {"applied": {"model": "opus"}, "effective_keys": ["env", "model"],
                  "sources_keys": [{"source": "userSettings", "keys": ["a", "apiKeyHelper"]}]}
        resp = {"type": "control_response",
                "response": {"subtype": "success", "request_id": "r2", "response": legacy}}
        body = self.r.redact_frame(resp, "in", {"r2": "get_settings"})["response"]["response"]
        self.assertEqual(list(body), ["applied", "effective", "sources"])
        self.assertEqual(body["effective"], {"env": "<redacted>", "model": "<redacted>"})
        self.assertEqual(body["sources"], [{"source": "userSettings",
                                            "settings": {"a": "<redacted>", "apiKeyHelper": "<redacted>"}}])
        again = {"type": "control_response",
                 "response": {"subtype": "success", "request_id": "r2", "response": body}}
        self.assertEqual(self.r.redact_frame(again, "in", {"r2": "get_settings"})["response"]["response"], body)

    def test_oauth_responses_keep_shape_and_drop_query(self):
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r3", "response": {
            "manualUrl": "https://claude.ai/oauth/authorize?code_challenge=abc&state=xyz", "automaticUrl": "https://claude.ai/o?x=1"}}}
        out = self.r.redact_frame(resp, "in", {"r3": "claude_authenticate"})
        self.assertEqual(out["response"]["response"], {"manualUrl": "https://claude.ai/oauth/authorize?<redacted>",
                                                       "automaticUrl": "https://claude.ai/o?<redacted>"})

    def test_oauth_requests_drop_their_url_queries(self):
        """The grant travels outbound too: `mcp_oauth_callback_url` and `mcp_authenticate`
        carry it in a request-side URL, where rule 6 used to run only over responses."""
        f = {"type": "control_request", "request_id": "r4", "request": {
            "subtype": "mcp_oauth_callback_url", "server_name": "afleet",
            "callbackUrl": "http://localhost:1455/callback?code=grant-1&state=nonce-1"}}
        out = self.r.redact_frame(f, "out", {})
        self.assertEqual(out["request"]["callbackUrl"], "http://localhost:1455/callback?<redacted>")
        self.assertEqual(out["request"]["server_name"], "afleet")
        g = {"type": "control_request", "request_id": "r5", "request": {
            "subtype": "mcp_authenticate", "server_name": "afleet",
            "nested": {"redirectUri": "https://claude.ai/oauth/cb?code=grant-2&state=nonce-2"}}}
        out2 = self.r.redact_frame(g, "out", {})
        self.assertEqual(out2["request"]["nested"]["redirectUri"], "https://claude.ai/oauth/cb?<redacted>")

    def test_oauth_callback_state_is_redacted_and_other_state_fields_are_not(self):
        """`claude_oauth_callback` carries its grant as bare strings: `authorizationCode`, which
        the `authorization` secret word already catches, and `state`, which no rule reached.
        The subtype is the gate -- `state` is an ordinary field name everywhere else."""
        f = {"type": "control_request", "request_id": "r6", "request": {
            "subtype": "claude_oauth_callback", "authorizationCode": "grant-3", "state": "nonce-3"}}
        out = self.r.redact_frame(f, "out", {})
        self.assertEqual(out["request"]["state"], "<redacted>")
        self.assertEqual(out["request"]["authorizationCode"], "<redacted>")
        g = {"type": "control_request", "request_id": "r7", "request": {
            "subtype": "can_use_tool", "tool_name": "Bash", "input": {
                "state": "expanded", "url": "https://docs.test/page?section=intro"}}}
        self.assertEqual(self.r.redact_frame(g, "out", {}), g)


class ScanTests(unittest.TestCase):
    def test_scan_finds_hard_failures(self):
        hits = redact.scan({"a": "mail a@b.c", "b": {"c": "sk-ant-zzz"}, "d": "/Users/probe/x"}, home="/Users/probe")
        self.assertEqual(len(hits), 3)
        self.assertTrue(any("email" in h for h in hits))
        self.assertEqual(redact.scan({"a": "clean ~ text"}, home="/Users/probe"), [])

    def test_report_only(self):
        hits = redact.scan_report_only("by Probe Person in /Users/someone/x", author="Probe Person", home="/Users/probe")
        self.assertEqual(len(hits), 2)

    def test_an_unredacted_owner_column_is_a_hard_failure_and_a_redacted_one_is_not(self):
        dirty = {"out": "-rw-r--r--@  1 probe  staff  11  9 4 20:54 one.txt"}
        self.assertTrue(any("ls -l owner column" in h for h in redact.scan(dirty, home="/Users/probe")))
        clean = redact.Redactor(home="/Users/probe").redact_text(dirty["out"])
        self.assertEqual(redact.scan({"out": clean}, home="/Users/probe"), [])

    def test_the_account_name_is_reported_where_position_cannot_settle_it(self):
        """Hard redaction where position makes it certain, a reviewer where judgement is needed.
        Word boundaries keep a name inside a longer word from reporting."""
        hits = redact.scan_report_only("ask probe about it\nprober is someone else\nfine\nprobe again\n",
                                       author=None, home="/Users/probe")
        self.assertEqual([h for h in hits if "account name" in h],
                         ["the account name appears on 2 line(s), first at line 1; judge whether any of them "
                          "identifies anyone"])
        self.assertEqual(redact.scan_report_only("prober only\n", author=None, home="/Users/probe"), [])


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

    def test_a_counter_that_happens_to_be_named_user_keeps_its_value(self):
        """`result.subagent_stats.killed.user` counts subagents the user killed; it sits
        beside `killed.parent` and `killed.system` and carries no identity. Name cannot tell
        it from a numeric account id and neither can type, so the exemption is by path. The
        same key elsewhere is still redacted, which is what keeps the exemption narrow."""
        out = self.r.redact_json({"subagent_stats": {"killed": {"parent": 0, "user": 2, "system": 1}},
                                  "killed": {"user": 5}, "user": 7})
        self.assertEqual(out["subagent_stats"]["killed"], {"parent": 0, "user": 2, "system": 1})
        self.assertEqual(out["killed"]["user"], "<user>")
        self.assertEqual(out["user"], "<user>")
        self.assertEqual(redact.scan({"subagent_stats": {"killed": {"user": 2}}}, home="/Users/probe"), [])
        self.assertEqual(redact.scan({"killed": {"user": 5}}, home="/Users/probe"),
                         ["killed.user: identity field not redacted"])

    def test_the_usage_behaviour_enum_named_key_is_not_a_secret(self):
        """`get_usage` answers with `behaviors.day.behaviors[].key`, an enum of behaviour
        names -- `cache_miss`, `long_context`, `subagent_heavy`, `high_parallel`, `cron`
        (2.1.258 `cli.pretty.js`). The secrets rule fires on any key containing "key" and
        replaced each with `<redacted>`. The value is a string, exactly like a credential, so
        only its position separates the two. Indices are stripped before matching, so the
        exemption holds wherever the element sits."""
        out = self.r.redact_json({"behaviors": {"day": {"behaviors": [{"key": "cache_miss", "cost": 1},
                                                                      {"key": "cron"}]}},
                                  "sessionKey": "s3cret", "elsewhere": {"key": "opaque"}})
        self.assertEqual(out["behaviors"]["day"]["behaviors"], [{"key": "cache_miss", "cost": 1}, {"key": "cron"}])
        self.assertEqual(out["sessionKey"], "<redacted>")
        self.assertEqual(out["elsewhere"]["key"], "<redacted>")
        self.assertEqual(redact.scan({"behaviors": {"day": {"behaviors": [{"key": "cron"}]}}}, home="/Users/probe"), [])
        self.assertEqual(redact.scan({"elsewhere": {"key": "opaque"}}, home="/Users/probe"),
                         ["elsewhere.key: secret-named field not redacted"])

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

    def test_prefixed_account_and_organization_keys_are_caught_anywhere(self):
        """Rule 1 says "anywhere", and a prefix is how an exact-match set stops meaning it.

        The record that motivated this is `bridge-session`, which the engine writes with
        `ownerAccountUuid` and `ownerOrganizationUuid` holding a live account uuid and a live
        organization uuid. An exact-match set walked past both and `verify` passed the fixture.
        The invented identifiers below stand in for them, as REVIEW.md requires of a test input.
        """
        out = self.r.redact_json({"type": "bridge-session", "sessionId": "s-1",
                                  "bridgeSessionId": "cse_0invented",
                                  "lastSequenceNum": 0,
                                  "ownerAccountUuid": "00000000-1111-2222-3333-444444444444",
                                  "ownerOrganizationUuid": "55555555-6666-7777-8888-999999999999"})
        self.assertEqual(out["ownerAccountUuid"], "<ownerAccountUuid>")
        self.assertEqual(out["ownerOrganizationUuid"], "<ownerOrganizationUuid>")
        # The structural neighbours on the same record are untouched: a rule that took the
        # session ids with them would cost the fixture its only link back to the transcript.
        self.assertEqual(out["sessionId"], "s-1")
        self.assertEqual(out["lastSequenceNum"], 0)

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
        self.assertEqual(body["effective"], {"env": "<redacted>"})
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

    def test_a_non_map_effective_is_replaced_whole(self):
        """Fail-closed on a body rule 5 does not recognise: there are no setting names to keep
        in a string, so the field keeps its name and loses everything else."""
        resp = {"type": "control_response", "response": {"subtype": "success", "request_id": "r2",
                "response": {"effective": "model=opus;env.SECRET=hunter2"}}}
        body = self.r.redact_frame(resp, "in", {"r2": "get_settings"})["response"]["response"]
        self.assertEqual(body["effective"], "<redacted>")

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

    def test_a_substitution_that_changes_nothing_is_not_counted(self):
        """The owner column rule matches its own placeholders, so counting matches rather than
        changes would inflate the manifest on every `redact` re-run of a committed fixture."""
        once = self.r.redact_text("-rw-r--r--  1 someone  somegroup  4 x", path="p")
        first = self.r.manifest()["rules"]["identity"]["count"]
        self.assertEqual(first, 1)
        self.r.redact_text(once, path="p")
        self.assertEqual(self.r.manifest()["rules"]["identity"]["count"], first)

    def test_a_manifest_adds_to_the_one_already_on_disk(self):
        """`redact` re-runs over bytes the recording already redacted, so a fresh manifest records
        what is left rather than what was done; it is summed onto the prior file, not replacing it."""
        self.r.redact_text("-rw-r--r--  1 someone  somegroup  4 x", path="stdout")
        prior = {"rules": {"identity": {"count": 9, "paths": {"attachment.userEmail": 1, "stdout": 2}},
                           "secrets": {"count": 0, "paths": {}}}}
        merged = self.r.manifest(prior)["rules"]
        self.assertEqual(merged["identity"]["count"], 10)
        self.assertEqual(merged["identity"]["paths"]["attachment.userEmail"], 1)
        self.assertEqual(merged["identity"]["paths"]["stdout"], 3)
        self.assertEqual(sorted(merged), sorted(self.r.manifest()["rules"]))

    def test_merging_a_manifest_with_nothing_new_leaves_it_alone(self):
        """Which is what makes the sum stable rather than merely additive."""
        prior = {"rules": {"identity": {"count": 9, "paths": {"a": 9}}}}
        self.assertEqual(redact.Redactor(home="/Users/probe").manifest(prior)["rules"]["identity"], prior["rules"]["identity"])

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
