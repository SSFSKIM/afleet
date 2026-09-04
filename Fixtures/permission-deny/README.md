# permission-deny

The same `Write` prompt as `permission-allow`, asked through `can_use_tool` and answered
`deny` with a message. Serves acceptance item 41; informs no spike.

What it shows:

- One `can_use_tool` request, answered `{behavior: "deny", message: "denied by the probe
  scenario"}`. The host's answer and the `--replay-user-messages` echo of it are both in
  the capture, travelling in and then out.
- The engine turns the denial into an ordinary `tool_result` block carrying
  `is_error: true` and the host's message verbatim as its content, addressed to the same
  `tool_use_id` the ask named. A denial is not an error frame and not a failed turn.
- The turn still ends `result/success`; the result text is "The Write tool was denied by
  the probe scenario." So a consumer keying failure off the result subtype reads a denied
  tool call as a clean turn, which is the same trap `rate-limited-turn` records for a
  rejected turn.
- The transcript holds 28 records against `permission-allow`'s 29. The one record the
  denial costs is the `file-history-delta`; the `file-history-snapshot` is written either
  way, so a consumer cannot tell an allowed write from a denied one by the snapshot alone.

Recorded on 2.1.259 under the scratch config home, model `haiku`, `--max-turns 3`.
`initial/` and `artifacts/` are empty.
