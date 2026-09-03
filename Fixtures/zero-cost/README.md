# zero-cost

The census baseline: an `initialize` handshake and the ten control requests that spend no
model tokens, recorded against the installed `claude` 2.1.259 under the scratch config home
of §4.6. No prompt is ever sent, so no turn begins, no `system/init` is emitted and nothing
is written to a transcript — `initial/`, `transcript/` and `artifacts/` are empty and
`streams.json` is `{}` by construction, not by omission.

Serves acceptance items 32 and 33 and spike S8, and it is the first line of the drift
ritual: `make probe` re-runs this scenario against a binary and compares its census
exactly, because the fixture is `deterministic: true`.

## What the recording shows

- All ten zero-cost subtypes answer `success`: `get_context_usage`, `get_session_cost`,
  `get_binary_version`, `mcp_status`, `background_tasks`, `get_settings`, `get_usage`,
  `list_models`, `get_plan`, `file_suggestions`.
- One `auth_status` frame arrives unprompted after the handshake.
- Three CLI-originated `mcp_message` round trips complete before any turn: the in-process
  `afleet` SDK server is initialised straight out of the §6.2 handshake, under
  `--strict-mcp-config`.
- Each of those three shows **two** `control_response` frames for one request id: the
  host's answer travelling in, and the same body travelling back out a few milliseconds
  later. That is the `--replay-user-messages` echo, not a duplicate answer — the CLI
  re-emits every host `control_response` on stdout when the flag is set (2.1.258
  `cli.pretty.js`, the stdin loop's `control_response` branch). `verify` reads a response
  travelling the same way as the request it names as an echo for that reason.

## Reading it

`census.json` records 68 long flags from `claude --help`. That is the count *declared* at
the two-space indentation column; two further long flags (`--all`,
`--permission-prompt-tool`) appear on 2.1.259 only inside other flags' description prose,
which is what the child spec's earlier "70 distinct flags" observation counted.

The `initialize` response embeds this machine's slash-command, agent and model inventory as
the CLI reports it. It comes from the scratch config home's own `plugins/` and
`settings.json`, not from a real project, and the redaction rules leave it alone because it
is neither identity, secret, path nor settings body. It is committed as recorded; a
reviewer should know it is there.
