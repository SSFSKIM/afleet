# zero-cost

The census baseline: an `initialize` handshake and the ten control requests that spend no
model tokens. Recorded against the **pinned** `claude` 2.1.259 at
`~/.local/share/claude/versions/2.1.259`, under the scratch config home of §4.6. No prompt
is sent, so no turn begins, no `system/init` is emitted and nothing is written to a
transcript — `initial/`, `transcript/` and `artifacts/` are empty and `streams.json` is `{}`
by construction, not by omission.

Serves acceptance items 32 and 33 and spike S8, and it is the first line of the drift ritual:
`make probe` re-runs this scenario against a binary and compares its census exactly, because
the fixture is `deterministic: true`.

## What the recording shows

- All ten zero-cost subtypes answer `success`: `get_context_usage`, `get_session_cost`,
  `get_binary_version`, `mcp_status`, `background_tasks`, `get_settings`, `get_usage`,
  `list_models`, `get_plan`, `file_suggestions`. `get_settings` answers
  `{applied, effective: {}, sources: []}` here: `--setting-sources ""` leaves no settings
  file in scope, so the two maps the engine builds are empty rather than redacted away.
- One `auth_status` frame arrives unprompted after the handshake.
- Three CLI-originated `mcp_message` round trips complete before any turn: the in-process
  `afleet` SDK server is initialised straight out of the §6.2 handshake, under
  `--strict-mcp-config`.
- Each of those three shows **two** `control_response` frames for one request id: the host's
  answer travelling in, and the same body travelling back out a few milliseconds later. That
  is the `--replay-user-messages` echo, not a duplicate answer — the CLI re-emits every host
  `control_response` on stdout when the flag is set (2.1.258 `cli.pretty.js`, the stdin
  loop's `control_response` branch). `verify` reads a response travelling the same way as the
  request it names as an echo for that reason.

## Reading it

`census.json` records 68 long flags from `claude --help`. That is the count *declared* at the
two-space indentation column; two further long flags (`--all`, `--permission-prompt-tool`)
appear on 2.1.259 only inside other flags' description prose.

`launch.argv[0]` reads `~/.local/share/claude/versions/2.1.259` rather than a bare `claude`,
which is how the fixture records the version it was pinned to. The path is redacted to `~`
like every other path under the recording user's home.

`get_usage` answers with `behaviors.day.behaviors[].key`, an enum of behaviour names — here
`high_parallel`. That field survives redaction only because it is exempted by path: the
secrets rule fires on any key containing "key", and until it was exempted the enum was
replaced by `<redacted>`.

The `initialize` response embeds this machine's slash-command, agent and model inventory as
the CLI reports it. It comes from the scratch config home's own `plugins/` and
`settings.json`, not from a real project, and the redaction rules leave it alone because it
is neither identity, secret, path nor settings body. It is committed as recorded; a reviewer
should know it is there.

**2026-09-06, re-redaction.** The `get_settings` frame used to read `effective_keys: []` and
`sources_keys: []`. Those two names were the fixture redactor's own invention, never the
engine's: 2.1.258 `cli.pretty.js` builds the answer in `aRn()` as `{effective: {<setting
name>: <value>}, sources: [{source, settings: {<setting name>: <value>}}]}`, with `applied`
added by the handler. Rule 5 now replaces values and keeps the shape, and `make redact`
migrated the frame and the census body key list in place. The recording was not re-run.
