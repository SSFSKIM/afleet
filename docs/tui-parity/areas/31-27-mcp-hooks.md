<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# 31-27-mcp-hooks — TUI-vs-headless UX gap inventory

Chapters covered: SPEC 31 (MCP client) and SPEC 27 (Hooks), plus SPEC 45 §45.20
(`hook_callback`) and §45.21 (`mcp_message`). Classification letters per the common brief
(P / R / D / X / T).

Live ground truth used throughout is from this machine, 2.1.259, headless
(`-p --input-format stream-json --output-format stream-json --include-hook-events …`):
`/tmp/afleet-gap/init-dump.json` (an `mcp_status` control response with three real
servers, one of them `needs-auth`) and `/tmp/afleet-gap/turns.ndjson.log` +
`.summary.json` (a `/mcp` turn and a `/hooks` turn).

Undocumented control requests (`mcp_authenticate`, `mcp_oauth_callback_url`,
`mcp_clear_auth`) were recovered by reading the handler bodies in `cli.pretty.js` at the
registry lines SPEC 45 §45.17 cites; their request/response fields are written out in
§3.3 below so a GUI can drive them.

---

## 1. MCP configuration, scopes, and the `.mcp.json` approval flow

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Five config scopes (`enterprise`, `project`, `user`, `local`) merged with precedence `local > project(approved) > user > plugin`, `claudeai` beneath everything | 31 §3.1, §3.9 | Not exposed as a merge view; `mcp_status` reports a final `scope` string per server (`local`/`user`/`project`/`dynamic`/`enterprise`/`claudeai`/`agent`) — live confirms `"scope":"dynamic"` for plugin servers and `"scope":"user"` | R | A GUI wanting the TUI's `/mcp` scope sections gets the grouping key free from `mcp_status.scope`, but must read `~/.claude.json`, `.mcp.json`, `.claude/settings*.json` and `managed-mcp.json` itself to show which file a row came from and to offer an "edit config" affordance. |
| Scope labels + file paths shown per server (`Local config (private to you in this project)` → `~/.claude.json [project: <cwd>]`, etc.) | 31 §7.5 table, §18.2 | Not on the wire | R | Static table; reimplement verbatim from 31 §7.5 and derive the path from `scope` + cwd + project root. |
| Section headings in `/mcp` (`Project MCPs`, `Local MCPs`, `User MCPs`, `Enterprise MCPs`, `Active agent MCPs`, `Built-in MCPs`, `claude.ai`, `Agent MCPs`) with path suffixes | 31 §18.2 | Derivable from `scope` | R | `dynamic` covers both `--mcp-config` and plugin servers; the TUI splits them by `pluginSource`, which `mcp_status` does **not** carry. Distinguishing "Built-in" from "plugin" from "`--mcp-config`" needs the host's own knowledge of what it passed plus the `plugin:<plugin>:<server>` name prefix. |
| `.mcp.json` **new-server approval dialog** — `New MCP server found in this project: <name>` with `Use this MCP server` / `Use this and all future MCP servers in this project` / `Continue without using this MCP server`; and the multi-server variant `<N> new MCP servers found in this project` + `Enable selected` | 31 §6.1 | **Never shown headless.** There is no dialog kind for it (the `request_user_dialog` kinds are the 34 in `io({kind:…})`, none of which is an MCP approval), and `iY(name)` promotes `pending → approved` whenever `Oe()` (non-interactive) is true and `projectSettings` is an enabled setting source [`cli.pretty.js:94676-94685`, `Oe()` at `cli.pretty.js:243981`] | X | Project `.mcp.json` servers are **silently auto-approved** in headless. Two consequences a GUI must own: (a) it never sees the security prompt the TUI shows, so if the product wants that consent moment it must build it itself from a read of `.mcp.json`; (b) if the host passes `--setting-sources` without `projectSettings`, the auto-approval does not fire and project servers are silently dropped instead. |
| Approval state persisted to `enabledMcpjsonServers` / `disabledMcpjsonServers` / `enableAllProjectMcpServers` in `.claude/settings.local.json` and the `~/.claude.json` project entry | 31 §6.1, §21 | `update_settings` writes `localSettings` only | R | A GUI can write approvals with `update_settings` (localSettings scope), which is exactly where the TUI dialog writes. Reset is `claude mcp reset-project-choices` — a subprocess, no control request. |
| Per-project enable/disable of any server (`/mcp enable|disable`), persisted to `disabledMcpServers`/`enabledMcpServers` in the `~/.claude.json` **project** entry | 31 §6.2 | `mcp_toggle {serverName, enabled}` control request — same persistence path (`tEe(name, enabled, storageV5)`), plus cache/discovery-entry teardown on disable [`cli.pretty.js:177827-177853`] | P | Errors are `Server not found: <n>`, `MCP server <n> is blocked by enterprise managed policy`, `MCP server <n> is not approved for this project — approve it in /mcp before enabling`. Success is an empty response on disable, and a reconnect result on enable. |
| Cross-session disable reconciliation lines (`<n> MCP server(s) were disabled in another session but aren't configured yet…`) | 31 §18.1 | Reachable only through the non-interactive `/mcp` text command's output | R | Text-only; a GUI showing structured state must replicate the reconciliation logic or just surface the `/mcp` text. |
| Enterprise `managed-mcp.json` exclusive control; `allowedMcpServers`/`deniedMcpServers`; `allowManagedMcpServersOnly` | 31 §3.4, §6.3 | Policy verdicts surface only as errors on `mcp_reconnect`/`mcp_authenticate`/`mcp_toggle` (`MCP server <n> is blocked by enterprise managed policy`) and as a `failed` client with error `Blocked by enterprise managed policy` | R | `get_settings` returns `effective` + `sources`, so a GUI can read `allowedMcpServers`/`deniedMcpServers` and pre-grey rows rather than waiting for a per-action error. |
| `--strict-mcp-config`, `--mcp-config`, `--plugin-dir-no-mcp` | 31 §3.5, §3.6 | CLI flags the host chooses at spawn; `--mcp-config` skips are reported in `system/init.mcp_server_errors` | P | See §2 row on `mcp_server_errors`. |
| Suppressed-duplicate rows (`<name> · ○ hidden — same URL as your server '<other>'` + one of four remediation hints) | 31 §18.2 | Not on the wire; suppressed servers do not appear in `mcp_status` at all | D | A GUI cannot tell "this connector was hidden as a duplicate" from "this connector does not exist". Workaround: compute endpoint signatures (31 §3.10) from the configs the GUI itself supplied plus disk configs, and reproduce the dedupe. |
| Scope-conflict warning (`Server "<n>" is defined in multiple scopes with different endpoints… OAuth tokens are stored per endpoint`) | 31 §3.10 | Not on the wire (doctor-style diagnostic) | D | Recomputable from disk configs. Low value. |

Rows: 10.

---

## 2. Connection lifecycle, status, and startup errors

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Six client states `connected / cached / pending / failed / needs-auth / disabled` | 31 §8.7 | `mcp_status` and `system/init.mcp_servers` both run the state through `e_e(type)`, which maps **`cached` → `pending`** [`cli.pretty.js:448022-448024`] | D (partial) | A host can never see the `cached` state: a discovery-cache-served server is indistinguishable from one still dialling. Minor, since the cache is off unless `MCP_DISCOVERY_CACHE=true`. Live `mcp_status` shows exactly `connected` and `needs-auth`. |
| `/mcp` detail-view status glyphs: `○ disabled`, `✔ connected`, `⚠ connected · tools fetch failed`, `⚠ connected · no tools`, `… connecting…`, `✗ failed` | 31 §18.3 | `mcp_status.status` only, plus `tools` array length | R | `connected · tools fetch failed` vs `connected · no tools` is **not** distinguishable: `toolsListError` is on the internal `connected` client state but is not projected into the `mcp_status` payload [`cli.pretty.js:175988`]. Both render as `status:"connected", tools:[]`. |
| Per-server `Issue:` row (`displayDetail` / first Zod issue) | 31 §18.3, §7.4 | `mcp_status.error` is populated **only** when `status === "failed"` [`cli.pretty.js:175988`] | D | A `needs-auth` server carries no error text on the wire — live confirms `plugin:supabase:supabase` has `status:"needs-auth"` and **no** `error` key. The rich auth-rejection strings of 31 §10.2 (`Server rejected the configured Authorization header (HTTP <status>)…`) never reach a GUI. Workaround: run the server's `mcp__<server>__authenticate` stub tool, or shell out to `claude mcp get <name>`. |
| `errorCode` vocabulary (`CONNECT_TIMEOUT`, `UNCONFIGURED`, `ENDPOINT_NOT_FOUND`, `AUTH_HEADER_REJECTED`, `POLICY_BLOCKED`, `APPROVAL_REQUIRED`, …) | 31 §8.9.2, §6.5 | Not in `mcp_status` | D | Reaches the model in the "servers failed to connect" system reminder (`<name> (<errorCode>): "<error>"`) but that reminder is not a wire frame either. `ToolSearch` results echo `failed_mcp_servers: [{name, errorCode?, error?}]` — the one place a host can observe the code, and only as tool output. |
| `Used by:` / `Auth:` rows; negotiated protocol version for modern-era stdio servers | 31 §18.3 | Not on the wire | D | `negotiatedProtocolVersion` / `protocolEra` exist on the internal client state and are dropped by the `mcp_status` projection. |
| Reconnect ladder (5 attempts, `min(1000·2^(n−1), 30000)` ms) with the client held at `pending {reconnectAttempt, maxReconnectAttempts}` while old tools stay visible | 31 §8.12 | `mcp_status` reports `pending` with **no attempt counters** | D | A GUI can show "connecting…" but not "attempt 3 of 5". Workaround: poll `mcp_status` and count transitions, or accept the loss. |
| Reconnect progress screens (`Connecting to <name>…`, ` Establishing connection to MCP server`, `This may take a few moments.`, `Reconnecting to <name>`, ` Restarting MCP server process`) | 31 §18.3 | `mcp_reconnect {serverName}` blocks until the dial settles, then answers | R | Verbatim strings; a GUI writes its own progress copy. |
| Manual reconnect | 31 §18.3 (`Reconnect` menu item) | `mcp_reconnect {serverName}` [`cli.pretty.js:177716-177732`]. Errors: `Server not found: <n>`; `MCP server <n> is blocked by enterprise managed policy`; `MCP server <n> is disabled — enable it (mcp_toggle) before reconnecting`; `MCP server <n> is not approved for this project — approve it in /mcp before reconnecting` | P | The `distrust` flag is chosen by the CLI (true when the server already had a live non-cached/non-pending client), so a GUI cannot force a credential-distrusting reconnect except via `mcp_clear_auth`. |
| Startup MCP errors: `system/init.mcp_server_errors` | 31 §3.5; SPEC 45 §45.9 | Present on every `system/init`, shape `{name, type, message}[]`, filtered to names **not** already in `mcp_servers` [`cli.pretty.js:448059`]. Source is `skippedDynamicServers` — i.e. entries skipped from `--mcp-config` [`cli.pretty.js:451885-451890`] | P | Note the narrow scope: it is *only* `--mcp-config` parse skips, not connect failures and not `.mcp.json` problems. The TUI additionally prints `Warning: <N> MCP server(s) skipped due to invalid config:` on stderr, but only when `process.stderr.isTTY` [`cli.pretty.js:454366`], so headless gets the data solely from `mcp_server_errors`. |
| TUI startup notice `<N> setup issue(s): MCP (run /mcp for details)` for any `failed` or `needs-auth` server | `cli.pretty.js:429968-429974`, `391523` | Derivable from `mcp_status` / `system/init.mcp_servers` | R | Trivial to rebuild and a place a GUI can do better (clickable per-server rows instead of a count). |
| Persistent warning indicator `<N> MCP server(s) need authentication · run /mcp` | `cli.pretty.js:392310` (`id: "mcp-needs-auth"`) | Derivable: count `status === "needs-auth"` from `mcp_status` | R | Live: `plugin:supabase:supabase` is `needs-auth` on this machine right now, so this indicator is active in the TUI and must be rebuilt in the GUI. |
| `claude mcp list` / `get` / `add` / `remove` / `reset-project-choices` | 31 §7 | Subprocess only; no control-request equivalent for add/remove | R | A GUI can shell out to `claude mcp …`, or write the config files directly and call `mcp_set_servers` for the in-session effect. `mcp_set_servers {servers}` answers `{added, removed, errors}` and validates with `mcp_set_servers: servers must be an object of config objects` [`cli.pretty.js:177673`]. |
| Non-blocking startup: `alwaysLoad` servers awaited, the rest connect in the background as `pending` | 31 §8.13 | Same behaviour headless; `system/init.mcp_servers` is a snapshot at turn start | P | A GUI must re-poll `mcp_status` (or watch `ToolSearch` output) to learn when a `pending` server settles — there is **no** push frame for MCP state change. See "Top gaps". |
| MCP debug log lines (`Successfully connected (transport: …) in <ms>ms`, `Connection established with capabilities: {…}`, stderr flushes, SIGINT/SIGTERM/SIGKILL trace) | 31 §8.2, §8.8, §8.9 | Only via `--debug`/`--debug-file`, never on stdout | D | Footer `※ Run claude --debug to see error logs` in `/mcp` acknowledges this is already out-of-band in the TUI too. A GUI can spawn with `--debug-file <path>` and tail it. |

Rows: 13.

---

## 3. The `/mcp` surface vs. the MCP control requests

### 3.1 The command itself

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Interactive `/mcp` picker | 31 §18, registered `local-jsx`, `immediate: true`, `thinClientDispatch: "twin"` | Not runnable; a `local-jsx` command is refused headless (SPEC 28 §8.1) | X | The `twin` dispatch is the instruction to a first-party GUI: render your own equivalent screen, do not post text. |
| Non-interactive `/mcp [reconnect\|enable\|disable [<server>\|all]]` | 31 §18.1, `local` + `supportsNonInteractive: true`, `thinClientDispatch: "post-text"` | **Works headless — live-confirmed.** Sending `/mcp` returned `3 MCP server(s): 2 connected, 1 not connected, 0 disabled. Use \`/mcp\` in the terminal for details.` | P | The summary elides zero-count categories. `needs-auth` counts as "not connected". Full message vocabulary in 31 §18.1 (~30 strings). Good as a fallback, but a GUI should drive the typed control requests instead. |
| The `ide` pseudo-server | 31 §18.1, §20.1 | Filtered out of every `/mcp` listing; still appears in `mcp_status` | R | A GUI should filter `name === "ide"` from its server list to match the TUI. |

### 3.2 Published control requests

| Request | Fields | Response | Class | Notes |
|---|---|---|---|---|
| `mcp_status` | — | `{mcpServers: [{name, status, serverInfo?, error?, config?, scope?, tools?, capabilities?}]}` [`cli.pretty.js:175975-175989`] | P | `config` is **redacted by transport**: `sse`/`http` → `{type,url,headers,oauth}`; `claudeai-proxy` → `{type,url,id}`; `stdio` → `{type,command,args}` — the stdio `env` block is deliberately omitted. `tools` is present only for connected/cached clients and is `{name: <upstream tool name>, annotations:{readOnly?,destructive?,openWorld?}}` — **no descriptions and no input schemas** (live confirms `[{"name":"advisor_ask","annotations":{}}]`). `capabilities` is only `{experimental:{…}}` after the `claude/channel` gate, never the full `ServerCapabilities`, so a GUI cannot learn whether a server offers prompts or resources. In a confined/eval session the whole payload collapses to `{name,status}` [`cli.pretty.js:174194-174198` region, `E_n`]. |
| `mcp_set_servers` | `servers` | `{added, removed, errors}` | P | Same shape the CLI writes into its dynamic config; SDK MCP servers are `{type:"sdk", name, timeout?}` (SPEC 45 §45.21.3). |
| `mcp_reconnect` | `serverName` | — (empty success) | P | See §2. |
| `mcp_toggle` | `serverName`, `enabled` | — | P | See §1. |
| `set_mcp_permission_mode_override` | `serverName`, `mode: "default" \| "auto" \| null` | `undefined`, or `{warning}` when the server name is unknown | P | **Tighten-only.** Any other mode is refused with `Permission mode override over the control channel is tighten-only ('default', 'auto', or null); rejected '<x>'`; an unparseable mode gives `Cannot set permission mode: must be one of <list>`; `auto` when auto mode is unavailable gives `Cannot pin MCP server '<n>' to auto[: <reason>]`. Warnings: `MCP server '<n>' is not known; no override was present to clear.` / `MCP server '<n>' is not yet known; override stored but will not apply until a server with that exact name connects.` [`cli.pretty.js:177854-177874`]. The override only bites when the session mode is `bypassPermissions`, `auto`, or `plan` with bypass available [`cli.pretty.js:674187-674193`]. **There is no TUI surface for this at all** — a GUI exceeds the TUI here. |
| `mcp_call` | `tool` (fully-qualified `mcp__server__tool`), `arguments?`, `expires_at?`, `timeout_ms?`, `input_files?`, `output_files?` | `{content, structuredContent?, _meta?, staging?}` | P | Host calls an MCP tool directly, outside the model loop. Notable constraints [`cli.pretty.js:177733-177826`]: `disallowTasks: true` — a SEP-2663 task result is never backgrounded; `requestDialog: undefined` — an elicitation cannot be shown, so a URL elicitation comes back as the error `URL elicitation required (open URL, then retry mcp_call): <url>`; abortable via `control_cancel_request` (`mcp_call cancelled by client: <s>`). Any of `expires_at`/`timeout_ms`/`input_files`/`output_files` puts the call on the *staged* path, which is killed by the `tengu_ptc_enabled` gate with `staged mcp_call is disabled`. Other errors: `mcp_call: tool must be a string`; `Not a fully-qualified MCP tool name: <t>`; `MCP server not connected: <s>`; `mcp_call does not support SDK MCP servers. SDK servers are caller-provided — invoke <s> directly.`; `MCP server <s> requires authentication — send mcp_authenticate and retry mcp_call: …`; `MCP session expired for <s> — send mcp_reconnect and retry mcp_call: …`. Error text is truncated to 2000 chars. |
| `mcp_message` | `server_name`, `message` (JSON-RPC) | `{mcp_response?}` | P | See §10. |

### 3.3 The three unpublished OAuth control requests (recovered from `cli.pretty.js`)

**`mcp_authenticate`** [`cli.pretty.js:177878-177951`]

Request: `{ subtype: "mcp_authenticate", serverName: string, redirectUri?: string }`.

Success responses, three shapes:

| Case | Response |
|---|---|
| claude.ai connector (`claudeai-proxy`) | `{ authUrl, requiresUserAction: true, callbackExpected: false }` |
| OAuth server, authorization URL produced | `{ authUrl, requiresUserAction: true, callbackExpected: true, redirectScheme: "localhost" \| "custom", state, callbackPort? }` — `callbackPort` is present **only** when `redirectScheme === "localhost"` |
| flow completed without needing the user (cached credential) | `{ requiresUserAction: false, callbackExpected: false }` |

Errors: `Server not found: <n>`; `MCP server <n> is blocked by enterprise managed policy`;
`MCP server <n> is disabled — enable it (mcp_toggle) before authenticating`;
`MCP server <n> is not approved for this project — approve it in /mcp before authenticating`;
`Unable to build claude.ai connector auth URL (missing org or server id)`;
`Server type "<t>" does not support OAuth authentication`; plus a message for
Anthropic-hosted endpoints.

Semantics a GUI must know: the flow always runs with `skipBrowserOpen: true`, so **the CLI
never opens a browser on this path** — the host owns opening `authUrl`. `redirectUri` is
honoured only when the server's config has no `oauth.clientId`; if the authorization
server rejects it the CLI silently retries on localhost and answers with
`redirectScheme: "localhost"` (debug line
`[mcp_authenticate] AS rejected custom redirectUri for <n>; falling back to localhost: <err>`).
When `redirectScheme` is `localhost`, the CLI is already listening on
`127.0.0.1:<callbackPort>/callback` and will complete the flow itself; the host does not
need to send `mcp_oauth_callback_url` unless the browser cannot reach that loopback port.
After the token exchange the CLI reconnects the server on its own, guarding against
identity change, removal, disable and policy block (31 §10.7 message list).

**`mcp_oauth_callback_url`** [`cli.pretty.js:177953-177976`]

Request: `{ subtype: "mcp_oauth_callback_url", serverName: string, callbackUrl: string }`.
Success: empty. Errors: `No active OAuth flow for server: <n>`;
`Invalid callback URL: missing authorization code. Please paste the full redirect URL including the code parameter.`
(the URL must parse and carry a `code` or `error` query parameter); or the OAuth failure
text. This is the "paste the redirect URL" escape hatch for remote/containerised sessions.

**`mcp_clear_auth`** [`cli.pretty.js:178030-178053`]

Request: `{ subtype: "mcp_clear_auth", serverName: string }`. Success: `{}`. Errors:
`Server not found: <n>`; `Cannot clear auth for server type "<t>"` (only `sse` and `http`
are clearable). Behaviour: revokes tokens for the configured config **and**, when the live
client's config differs, for that one too; then either drops the discovery-cache entry and
marks the client `failed` with error `Authentication cleared`, or dials again with
`distrust: true`.

### 3.4 `/mcp` affordances with no control request

| Feature | TUI behaviour (SPEC §) | Headless | Class | Notes |
|---|---|---|---|---|
| `View tools` screen (per-server tool list, gated on ≥1 tool) | 31 §18.3 | `mcp_status.tools` gives names + three boolean annotations, no descriptions/schemas | R (degraded) | To show descriptions a GUI must call `ToolSearch` with `select:mcp__<server>__<tool>` and read the returned schemas, or run `mcp_message` `tools/list` for an SDK server. For a normal (non-SDK) server there is **no** control request that returns tool descriptions. |
| `Clear authentication` for a claude.ai connector (opens `claude.ai` in a browser: `Find the MCP server in the browser and click "Disconnect".`) | 31 §18.3 | `mcp_clear_auth` refuses `claudeai-proxy` (`Cannot clear auth for server type "claudeai-proxy"`) | X | Connector disconnect is a claude.ai web action. A GUI can only open the URL. |
| `Authenticate` for a claude.ai connector | 31 §18.3 | `mcp_authenticate` returns `{authUrl, requiresUserAction:true, callbackExpected:false}` | P | The host opens the URL; there is no callback to submit. |
| Agent-scope read-only detail view (`agent-only`, `○ not connected (agent-only)`, `⚠ may need authentication`, `This server connects only when running the agent.`) | 31 §18.3 | Agent-scope servers appear in `mcp_status` with `scope: "agent"` and no client state | R | Reproduce the read-only treatment from the scope value. |
| Footer hints (`※ Run claude --debug to see error logs`, `https://code.claude.com/docs/en/mcp for help`), overflow indicators, key hints | 31 §18.2 | n/a | T | Terminal chrome; superseded by GUI scrolling. |

Rows in §3: 3 + 6 + 3 + 5 = 17.

---

## 4. MCP OAuth: TUI vs headless

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Authentication progress screen: `Authenticating with <name>…`, ` A browser window will open for authentication` / ` Authenticating via your identity provider` (XAA), `If your browser doesn't open automatically, copy this URL manually`, `Return here after authenticating in your browser. Press Esc.` | 31 §18.3 | The host builds this from the `mcp_authenticate` response | R | The XAA variant is selectable from the server config (`oauth.xaa`), which `mcp_status.config.oauth` carries. |
| Browser opened automatically by the CLI | 31 §10.4 step 3 (`performMCPOAuthFlow` normally opens it) | **No.** The control-request path passes `skipBrowserOpen: true` | R | The host must open `authUrl` itself. This is arguably better in a native GUI (it can use the system default browser and keep focus). |
| Loopback callback listener on `127.0.0.1:<port>/callback`, 300 s timeout, success page `Authentication successful` / `You can close this tab and return to Claude Code.` | 31 §10.4 steps 6–8 | Identical — the listener runs inside the CLI process regardless of interactivity, and `callbackPort` is returned to the host | P | The GUI does not need its own listener. `EADDRINUSE` still yields `OAuth callback port <p> is already in use — another process may be holding it. Run \`lsof -ti:<p> -sTCP:LISTEN\` to find it.` |
| `If the redirect page shows a connection error, paste the URL from your browser here` — a text input in the TUI | 31 §18.3 | `mcp_oauth_callback_url {serverName, callbackUrl}` | P | The GUI builds the paste box; the wire accepts it. Only needed when the browser cannot reach the CLI's loopback port (containers, SSH). |
| `--no-browser` flag on `claude mcp login` | 31 §7.7 | Subprocess only | T/R | Superseded by the control-request flow. |
| `needs-auth` status and the 15 min / 4 h / 90 s needs-auth cache | 31 §10.3 | `mcp_status.status === "needs-auth"` (live-confirmed on `plugin:supabase:supabase`); the cache TTL is invisible | P (status) / D (cache) | A GUI's "Retry" button will appear to do nothing while the needs-auth cache is warm, because `connectToServer` short-circuits. `mcp_reconnect` clears the discovery-cache entry but the needs-auth cache is cleared only inside `reconnectMcpServerImpl`'s retry path. Practical guidance: drive re-auth through `mcp_authenticate`, not `mcp_reconnect`. |
| The two synthetic auth-stub tools `mcp__<server>__authenticate` and `mcp__<server>__complete_authentication` that the model can call | 31 §10.7 | **Suppressed entirely in non-interactive sessions** [`cli.pretty.js:527169-527171`] | X | Important: on this machine those two tools are visible (this session is interactive), but a headless-hosted session will not have them. Instead the model is told, via the §17.2 system reminder, `This session is non-interactive, so Claude cannot run the OAuth flow here… Do not ask the user for authorization codes, tokens, or callback URLs.` A GUI wanting the model to be able to trigger auth must either register its own in-process SDK MCP tool or intercept and drive `mcp_authenticate` from the UI. |
| XAA (`claude mcp xaa setup/login/show/clear`) | 31 §10.9, §7.10 | Subprocess only; `CLAUDE_CODE_ENABLE_XAA=1` gated | T | Hidden feature; a GUI can ignore it or shell out. |
| Token storage keyed `<name>|sha256({type,url,headers})[0:16]` in the keychain | 31 §10.5 | Never exposed | — | Correctly opaque; nothing for a GUI to do. |

Rows: 9.

---

## 5. MCP tools: naming, deferral, ToolSearch, invocation

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Tool naming `mcp__<un(server)>__<un(tool)>`; plugin servers become `mcp__plugin_<plugin>_<server>__…`; claude.ai connectors `mcp__claude_ai_<name>__…` | 31 §11.1 | Same names appear in `system/init.tools` and in every `assistant` tool_use | P | The sanitiser replaces `[^A-Za-z0-9_-]` with `_`, so the display name and the wire name differ. A GUI must map back with `mcp_status` (which carries the **original** `name`) rather than by un-sanitising, which is lossy. |
| `userFacingName()` = `<serverName> - <annotations.title \|\| toolName> (MCP)` used in permission dialogs and tool rows | 31 §11.4 | `can_use_tool` carries `display_name?` and `title?` (SPEC 45 §45.22 table) | P | The CLI computes it; the host renders it. |
| Every MCP tool is **deferred** behind `ToolSearch` (only the name is in context) unless `alwaysLoad` or `anthropic/alwaysLoad` | 31 §11.6 | Identical headless — deferral is a model-context property, not a UI one | P | Consequence for a GUI's "context usage" screen: `get_context_usage` returns `mcpTools?`, and per the shipped `/skill-doctor` text a GUI must **never** report a token cost for deferred MCP tools nor suggest disabling a server to save context. |
| `ToolSearch` "still connecting"/"failed"/"policy-blocked" appendices, plus the 5 s targeted wait | 31 §11.6 | Same; visible to the host only as the tool's `user` result frame | P | The `pending_mcp_servers` / `failed_mcp_servers` fields in the `ToolSearch` output are the richest per-server error data on the wire (they carry `errorCode`). |
| `WaitForMcpServers` tool (enabled only while a client is `pending`) | 31 §11.7 | Same; the host sees it appear/disappear from `system/init.tools` between turns | P | A GUI can also call it via… nothing — there is no host-side invoke for a built-in tool. Poll `mcp_status` instead. |
| `RefreshMcpTools` tool | 31 §11.8 | Same | P | Same note. |
| Read-only / destructive / open-world annotations driving `isConcurrencySafe` and permission text | 31 §11.4 | `mcp_status.tools[].annotations` gives `readOnly` / `destructive` / `openWorld` | P | Enough to render tool badges. |
| Tool-call watchdogs: 30 s heartbeat log, hard timeout, idle timeout, 90 s transport-loss | 31 §12.2 | Idle/hard-timeout **errors** arrive as normal tool_result errors. The 30 s heartbeat is a debug-log line only | D (heartbeat) | `tool_progress` heartbeats are on the wire only for Bash/PowerShell (and only under `CLAUDE_CODE_REMOTE`/`CLAUDE_CODE_CONTAINER_ID`); MCP progress notifications go to the internal tool-progress channel and are **not** emitted. See §9. |
| Large-result handling: persist to `mcp-<server>-<tool>-<ts>` or truncate with the `[OUTPUT TRUNCATED - exceeded 25000 token limit]` notice | 31 §12.5 | Identical; the summary/notice is inside the tool_result text | P | `files_persisted` frames tell the host which files were written. |
| Retroactive approval card for JSON-RPC `-32003` (`The <toolName> connector requires approval for this call.`) | 31 §12.3 | Surfaces as a `can_use_tool` control request | P | Host renders it as a permission prompt like any other. |
| URL elicitation retry on JSON-RPC `-32042` (up to 3 rounds) | 31 §12.3 | Uses the `mcp_url_elicitation` dialog kind — reachable headless **only if** the host declares it in `initialize.supportedDialogKinds` | P (conditional) | Live probe declared `supportedDialogKinds: []`, so this degrades. A GUI that wants URL elicitation must declare `mcp_url_elicitation`. |
| "Why is this tool missing" hints appended to a tool-not-found error | 31 §17.3 | Same text; model-facing only | P | Not user-visible in the TUI either. |
| Server `instructions` injected as `mcp_instructions_delta` | 31 §17.1 | Model-facing attachment, not a wire frame | D | A GUI cannot show "this server contributed N chars of instructions". Low value; `get_context_usage` gives the aggregate. |

Rows: 13.

---

## 6. MCP resources and `@` mentions

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `ListMcpResources` / `ReadMcpResource` / `ReadMcpResourceDir` tools | 31 §13.1–13.3 | Identical | P | Model-driven; nothing UI-specific. |
| Unified `@` autocomplete mixing files, **MCP resources**, **MCP resource templates** and agents, fuzzy-ranked with a +0.15 score adjustment for MCP resources | `cli.pretty.js:404160-404180` | **`file_suggestions {query}` returns only `{suggestions: [{path}]}` from the file index** [`cli.pretty.js:177643-177649`] | D | This is the sharpest data gap in the MCP half of this area. The wire has no way to enumerate MCP resources for an `@` picker. Workarounds, in order of preference: (a) the GUI runs its own `ListMcpResources` — but that requires a model turn; (b) `mcp_call {tool: "mcp__<server>__…"}` cannot help because resources are not tools; (c) `mcp_message` works **only** for SDK-hosted servers. For ordinary servers there is no host-side resource listing at all. |
| `@<server>:<uri>` resolution when the message is submitted | 31 §13.5 | **Works headless.** The extractor regex runs in the message-processing path; the resolver reads the prefetched resource list and does `resources/read` | P | So a GUI can offer a free-text `@server:uri` field and it will resolve — only the *completion list* is missing. Failures are silent (the mention is dropped, `tengu_at_mention_mcp_resource_error` fired). |
| `mcp_resource` attachment rendered in the transcript as `Read MCP resource <name> from <server>` | `cli.pretty.js:766890-766901` | Attachment is dropped by the headless filter (`Cu` passes only `queued_command`, `tool_host_result_lines` and `hook_system_message` attachments) | D | A GUI cannot show "this turn read resource X from server Y". Workaround: parse the `@server:uri` tokens out of the user message the GUI itself sent. |
| Resource-template argument completion via `completion/complete` | 31 §13.4 | Not reachable from the host | D | Same root cause as the `@` picker gap. |
| Resource prefetch at startup | 31 §13.5 | Same; invisible | — | No user-visible surface. |

Rows: 6.

---

## 7. MCP prompts as slash commands

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| A server's `prompts/list` entries become commands `/mcp__<server>__<prompt>` with `userFacingName` `<server>:<prompt> (MCP)` and `source: "mcp"` | 31 §14 | They appear in `system/init.slash_commands` and in the `initialize` response's `commands` array (with `name`, `description`, `argumentHint`, `aliases`) | P | Live `init-dump.json` confirms the `commands` array carries exactly those fields. A GUI's command palette gets MCP prompts for free. |
| Invocation `/mcp__<server>__<prompt> <arg1> <arg2>` with positional args zipped into the declared `arguments` | 31 §14 | Same — these are `prompt`-kind commands, which work headless (SPEC 28 §22) | P | Missing-argument error is `Missing required argument: <names>. Usage: /mcp__<server>__<prompt> <arg1> <arg2>`. |
| `argNames` shown as an argument hint in the TUI's command menu | 31 §14 | `argumentHint` in the `initialize` commands list | P | |
| Command list invalidated on `notifications/prompts/list_changed` | 31 §14 | The `commands_changed` frame is on the wire (SPEC 45 §45.9) | P | A GUI should re-read the command list on `commands_changed` rather than caching from `initialize`. |
| Prompt-command failure text `Error running command '<prompt>': <error>` | 31 §14 | Arrives as a `result` / `informational` frame | P | |

Rows: 5.

---

## 8. Elicitation

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Form-mode elicitation dialog: message + one field per `requestedSchema` property (string/enum/boolean/number/array-of-enum), `Accept` / `Decline`, required-field enforcement (`This field is required`), `Select at least <n> item(s)` / `Select at most <n> item(s)`, `not set` placeholders, `Type something…`, ` (task <shortId>)` header suffix | 31 §15.3 | The CLI sends the host an `elicitation` control request `{mcp_server_name, message, mode?, url?, elicitation_id?, requested_schema?, title?, display_name?, description?}`; the host answers `{action, content?}` | P (data) / R (widget) | Everything needed to render the form is on the wire — including `requested_schema`. The entire form widget (field types, cardinality checks, required markers, the exact validation copy) must be rebuilt. This is one of the larger single build items in this area, and one where a native GUI clearly beats a terminal form. |
| URL-mode elicitation: message + URL, actions ` Accept `, ` Reopen URL `, ` Decline`, ` Cancel`; then the waiting phase `Waiting for the server to confirm completion…` / `Continue without waiting` (dialog kind `mcp_elicitation_waiting`, results `dismiss\|retry\|cancel\|cancelled`, action label `Skip confirmation`) | 31 §15.3 | Same `elicitation` control request with `mode: "url"` and `url`; the waiting phase is a `request_user_dialog` of kind `mcp_elicitation_waiting`, gated on `initialize.supportedDialogKinds` | P (conditional) | If the host does not declare `mcp_elicitation` / `mcp_elicitation_waiting` / `mcp_url_elicitation`, the flow degrades to its no-dialog behaviour. Live probe declared `supportedDialogKinds: []`. A GUI must declare all three. |
| URL-safety strings (`This URL extends past this screen — its beginning is not visible here.`, `This URL cannot be shown exactly as it would open, so opening it is disabled. Decline to continue.`, `This URL's browser-ready form is too long to hand to a browser safely…`) | 31 §15.3 | Not on the wire — these are computed by the terminal renderer from the URL and the screen width | R / T | The first is purely terminal-width-driven and irrelevant in a GUI. The second and third are genuine safety checks (non-renderable URL, over-long browser form) that a GUI **should** reimplement rather than drop. |
| `notifications/elicitation/complete` → harness notification `MCP server "<name>" confirmed elicitation <id> complete` | 31 §15.1 | The `elicitation_complete` frame is on the wire (SPEC 45 §45.9) | P | A GUI can close its waiting dialog on this frame — better than the TUI's poll-and-dismiss. |
| Any error during elicitation answers `{action:"cancel"}` | 31 §15.2 | Same; a host that never answers leaves the tool call hanging until the tool timeout (the idle watchdog is **paused** while an elicitation is open, 31 §12.2) | P | A GUI must always answer the `elicitation` request, including on window close. |
| `Elicitation` / `ElicitationResult` hooks short-circuiting the dialog | 31 §15.4, 27 §13.10 | Hooks run identically headless; an SDK host can register for both events via `initialize.hooks` | P | An SDK host can therefore auto-answer elicitations in code instead of showing UI. |

Rows: 6.

---

## 9. Long-running MCP calls, progress, and backgrounding

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| MCP `onprogress` notifications (`{progress, total, message}`) forwarded into the tool-progress channel and shown on the tool row | 31 §12.2, §16.4 | **Dropped.** The `progress` arm of the internal→wire converter handles only nested tool progress, `repl_tool_call`, `bash_progress`/`powershell_progress` (and those only under `CLAUDE_CODE_REMOTE`/`CLAUDE_CODE_CONTAINER_ID`), `tool_heartbeat` and `agent_api_retry` [`cli.pretty.js:92963-92978`]. `mcp_progress` falls through and breaks | D | A GUI shows a spinning MCP tool with no percentage, no total, and no server-supplied message. This is a protocol addition, not a workaround. Partial mitigation: `tool_heartbeat` frames still arrive for any long tool, so the GUI can show elapsed time. |
| Auto-backgrounding of a call slower than `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS` (default 120 s when the `tengu_mcp_auto_background` gate is on) | 31 §12.6 | Headless: `getMcpAutoBackgroundMs` returns `0` when the session is non-interactive **unless** `CLAUDE_AUTO_BACKGROUND_TASKS` is set [`chunk-kf9c39pn.js:579653-579664`] | D (behavioural difference) | So by default a headless-hosted session **never** auto-backgrounds a slow MCP call — it blocks the turn until the tool timeout. A GUI that wants TUI parity must set `CLAUDE_AUTO_BACKGROUND_TASKS` in the child environment. Worth doing: the backgrounding message (`MCP tool "<tool>" is still running after <n>s. It was moved to the background as task <id>…`) plus the `task_started`/`task_notification` frames give a far better UX than a frozen turn. |
| Server-driven SEP-2663 tasks: backgrounded (registered in the task registry, `tasks/get` polling, `notifications/tasks/status`) or polled inline | 31 §12.6 | The registry entries surface as `background_tasks` (`type: "mcp_task"`, with `server`/`tool`) and via `task_started` / `task_updated` / `task_progress` / `task_notification` frames | P | Live `background_tasks` control response is captured in `init-dump.json`. The MCP task notification text (`MCP task <shortId> (<server>/<tool>) <status>.` plus persisted-output hints) arrives verbatim. |
| `mcp_call` from the host with `expires_at` / `timeout_ms` / `input_files` / `output_files` | SPEC 45 §45.22 | See §3.2. `disallowTasks: true`, so a host-driven call is never backgrounded and never becomes a SEP-2663 task | P | The `staging` field in the response carries the staged-file result. Guarded by the `tengu_ptc_enabled` kill switch (`staged mcp_call is disabled`). |
| `Stop`/`Interrupt` of a running MCP call → `The tool call was interrupted before a result was received. It may or may not have completed on the server — verify before assuming it succeeded, and retry if needed.` | 31 §12.2 | Same text in the tool_result | P | |

Rows: 5.

---

## 10. SDK MCP servers, `mcp_message`, and channels

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| In-process host-provided MCP servers | Not available in the TUI at all | `initialize.sdkMcpServers: string[]` + `sdkMcpServerConfigs: {name: {timeout?, alwaysLoad?}}`; the CLI registers `{type:"sdk", name, timeout?}` and proxies every JSON-RPC frame over `mcp_message` (SPEC 45 §45.21) | P (GUI exceeds TUI) | A native GUI can expose its own tools to the model with zero subprocess overhead. Default `mcp_message` timeout is 70 000 ms; JSON-RPC **notifications** get no timeout signal at all. |
| SDK server tools appear as `mcp__<name>__<tool>` | 31 §11.1 | Same, unless `CLAUDE_AGENT_SDK_MCP_NO_PREFIX` is set, in which case the tool keeps its bare upstream name [`chunk-mbv25gm4.js:592801`] | P | The no-prefix mode is worth knowing: it makes host tools indistinguishable from built-ins in `system/init.tools`. |
| Host→CLI `mcp_message` (server-initiated notifications and requests) | n/a | Supported, but **silently dropped** when `server_name` names an unknown or unconnected server — the CLI answers with a bare success either way (SPEC 45 §45.21.2) | P (with a trap) | A GUI must not treat the empty success as delivery confirmation. |
| `mcp_set_servers` to add/remove SDK servers mid-session | n/a | `{added, removed, errors}` | P | |
| SDK servers bypass the enterprise allowlist (`filterMcpServersByPolicy` exempts `type: "sdk"`) and are never blocked at connect time | 31 §6.3, §6.5 | Same | P | Deliberate; the host is trusted. But note `mcp_call` explicitly refuses SDK servers (`SDK servers are caller-provided — invoke <s> directly.`). |
| Channel-capable servers (`claude/channel` experimental capability, `channelsEnabled` managed setting) | 31 §9 (forces a live dial), §23 | `channel_enable {serverName}` control request; `mcp_status.capabilities.experimental["claude/channel"]` is present only when the channel gate passes [`cli.pretty.js:175981-175987`] | P | Chapter 50 owns channels. MCP-side surface is just: the capability flag in `mcp_status`, the `channel_enable` request, and the fact that a channel-capable server always forces a live dial (never served from the discovery cache). |

Rows: 6.

---

## 11. Roots, sampling, logging

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `roots/list` answered from cwd + additional working directories; `notifications/roots/list_changed` broadcast on change | 31 §16.1 | Identical; `add_directory` / `register_repo_root` / `set_cwd` all change the root set | P | A GUI calling `add_directory` implicitly re-broadcasts roots to every MCP server. |
| `sampling/createMessage` | **Not supported** — the client never advertises the capability; the SDK refuses with `Client does not support sampling capability (required for sampling/createMessage)` | Same | — | No gap; record so a GUI does not promise it. |
| `notifications/message` (server log records) | **No handler registered**; records are dropped by the SDK default handler. On a modern-era connection registering any custom notification handler is explicitly refused | Same | — | So "MCP notifications/logging messages the TUI shows" is a null set: **the TUI shows none**. `logging/setLevel` is never called. This is worth stating plainly because it looks like a gap and is not one. |
| The only MCP-originated notifications the user ever sees | `MCP server "<name>" confirmed elicitation <id> complete` (`notificationType: "elicitation_complete"`) and `Elicitation response for server "<name>": <action>` (`notificationType: "elicitation_response"`), 31 §15.1/§15.4 | Both arrive as `elicitation_complete` / `notification` frames | P | |

Rows: 4.

---

## 12. Hook events and what the TUI shows for each

The 33 events, the input payloads, and the blocking semantics are identical headless — the
engine is the same generator. What differs is *rendering*. Column 3 gives the headless
surface for the event's user-visible effect.

| Event | TUI shows (SPEC 27 §) | Headless surface | Class | Notes |
|---|---|---|---|---|
| *(all events)* spinner line: one `progress` message per matched hook carrying `hookEvent`, `hookName` (`<event>[:<matchQuery>]`), `command` (the hook's `statusMessage` if set, else the display form of the command/prompt/url/server-tool), `promptText?`, `statusMessage?` | §13.1 | **Not on the wire.** `hook_progress` internal progress messages fall through the converter's `progress` arm and are dropped [`cli.pretty.js:92963-92978`]. With `--include-hook-events` the host instead gets `system/hook_started {hook_id, hook_name, hook_event}` | D | The hook's `statusMessage` — the one field a hook author writes specifically to be displayed — **never reaches a headless host**. A GUI can only show `<event>:<matchQuery>`. This is a protocol addition; the workaround is to read `statusMessage` out of the settings files the GUI itself resolved, keyed by event+matcher, which is fragile when several hooks share a matcher. |
| *(all events, with `--include-hook-events`)* | §12.5 | `system/hook_started`, `system/hook_progress {stdout, stderr, output}` (polled at 1000 ms, emitted only when the accumulated output changed), `system/hook_response {output, stdout, stderr, exit_code?, outcome}` where `outcome ∈ success \| error \| cancelled` | P | Gating is `xSe(event)`: `["SessionStart", "Setup"]` are **always** emitted; every other event only under `--include-hook-events` [`cli.pretty.js:46819-46835`]. Live confirms `hook_started`/`hook_progress`/`hook_response` for `SessionStart:startup`. These three frames are excluded from "last message" selection by the `fy` filter. |
| `PreToolUse` — permission verdict `allow` / `deny` / `ask` / `defer` | §13.6 | `ask` becomes a `can_use_tool` control request with the message `Hook PreToolUse:<tool> asked for confirmation for this tool`; `deny` becomes a denied tool result with `PreToolUse:<tool> hook error: <err>` or `Hook PreToolUse:<tool> denied this tool`; `allow` skips the prompt | P | The `decision_reason` on `can_use_tool` carries `{type: "hook", …}` including `hookSource` (`settings` / `plugin:<name>` / `skill`), so a GUI can label the prompt "requested by a hook". |
| `PreToolUse` `defer` | §13.7 | **Only honoured headless** (`!isNonInteractiveSession` ignores it in interactive mode), and only for a solo (non-batched), non-served call. Produces a `hook_deferred_tool` attachment and a `result` frame rewritten to `stop_reason: "tool_deferred"` with an empty `result` | P (GUI exceeds TUI) | The TUI logs `Hook <name> returned permissionDecision=defer in interactive mode; ignoring (defer is print-mode only)`. A GUI driving headless gets a feature the terminal does not have — but must handle the `tool_deferred` stop reason and offer a resume affordance (`-p --resume`). The TUI's row for it is `<hookName> deferred <toolName> · resume with -p --resume to continue`. |
| `PostToolUse` `additionalContext` | §13.8, §13.3 | `hook_additional_context` attachments are **model-facing only**; the TUI does not render them either (no case in the transcript attachment renderer) | P | Symmetric loss — no gap. |
| `PostToolUse` `updatedToolOutput` / `updatedMCPToolOutput` | §13.8 | Applied before the `user` tool_result frame is emitted, so the host sees the rewritten output | P | A GUI cannot show "this output was rewritten by a hook". Same in the TUI. |
| `PostToolUse` blocking error | §13.8 | `hook_blocking_error` attachment → dropped from the wire; the model sees it, the host does not | D | The TUI renders `<hookName> hook returned blocking error` in red with the reason beneath [`cli.pretty.js:767022-767040`]. A GUI gets nothing unless `--include-hook-events` is on, in which case `hook_response {outcome:"error", stderr}` covers it. **Recommendation: always pass `--include-hook-events`.** |
| `PostToolUseFailure`, `PostToolBatch` | §2.1 | Same as `PostToolUse` | P/D | |
| `Notification` | §2.1 | The harness `notification` frame is on the wire; the hook itself is `runs_locally` and non-blocking | P | |
| `UserPromptSubmit` **block** | §13.5 | `system/informational {content: "UserPromptSubmit operation blocked by hook:\n<err>\n\nOriginal prompt: <prompt>", level: "warning", prevent_continuation: true}` plus a `result` frame whose text is the same string [`cli.pretty.js:69872-69877`, `69974`] | P | `suppressOriginalPrompt: true` omits the `Original prompt:` tail. This is the cleanest hook surface on the wire — fully renderable. |
| `UserPromptSubmit` non-blocking hook errors | §13.5 | `system/informational {content: "UserPromptSubmit hook error: <e1>; <e2>", level: "warning"}` [`cli.pretty.js:338694`] | P | |
| `UserPromptSubmit` `additionalContext` / `sessionTitle` | §4.2 | Context is model-facing; the title change is observable via `generate_session_title`-adjacent state but has no dedicated frame | P/D | Minor. |
| `UserPromptSubmit` callback timeout on an SDK host | §10.7 | `hook_cancelled` attachment → **the one hook_cancelled the TUI renders**: `<hookName> hook timed out after <N>s — output discarded. Raise the hook's "timeout" to allow more time.` (only for `UserPromptSubmit` with `timedOut`) [`cli.pretty.js:767013-767029`]. Not on the wire | D | Rebuild from `hook_response {outcome: "cancelled"}`. |
| `UserPromptExpansion` | §2.1 | Same block semantics as `UserPromptSubmit` | P | |
| `SessionStart` **context injection** | §16.1 | The context is a `hook_additional_context` attachment named `SessionStart` — model-facing, not on the wire. But `hook_started`/`hook_response` for `SessionStart` are **always** emitted regardless of `--include-hook-events`, and the response `output` carries the raw JSON the hook printed | P (via hook_response) | Live capture shows exactly this: `hook_response` with `output` containing `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}`. A GUI can parse `additionalContext` out of the `hook_response.output` and show "N hooks contributed context" — which the TUI does **not** do. |
| `SessionStart` `initialUserMessage` | §16.2 | Submitted as a normal user turn; visible with `--replay-user-messages` | P | |
| `SessionStart` `sessionTitle`, `watchPaths`, `reloadSkills` | §16.1 | `reloadSkills` produces a `commands_changed` frame; the others are invisible | P/D | |
| `SessionStart` resume dedupe (drops attachments already in the transcript) | §16.3 | Same logic; SDK resume path calls it | P | A GUI that renders `hook_response` frames on resume will see the hook fire again even though its context was deduped — cosmetic double-report. |
| `SessionEnd` | §2.1, §10.9 | Timeout is `max(1500, min(largest configured timeout, 60000))` ms, overridable by `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS`. Failures print to the harness's own `process.stderr` as `SessionEnd hook [<label>] failed: <output>` | P | Because it goes to stderr, a GUI capturing the child's stderr sees it; a GUI that discards stderr does not. |
| `Stop` / `SubagentStop` continuation | §17.4 | `hook_blocking_error` → a meta user message `Stop hook feedback:\n<error>` and the turn continues; the host sees a new `assistant` turn with no new user input | D | The TUI shows a dedicated `stop_hook_summary` row: `Ran <N> stop hook(s)` in red (errors), gold (feedback or prevented continuation) or hidden entirely when there was nothing to report, with sub-lines `Stop hook error: <e>` / `Stop hook feedback: <f>` [`cli.pretty.js:763057-763065`]. **None of this reaches a headless host** except through `hook_response` frames. Without them a GUI shows an unexplained extra turn. |
| `Stop` hook error terminal notification (`Stop hook error occurred · <chord> to see`) | §17.4 | Not on the wire | T/D | Terminal-chord phrasing is terminal-specific; the underlying "a stop hook errored" signal is a real gap, covered by `hook_response {outcome:"error"}`. |
| `Stop` consecutive-block cap | §17.2 | `system/informational {level: "warning"}` with `A hook blocked the turn from ending <N> consecutive times — overriding and ending turn. For Stop/SubagentStop hooks, check stop_hook_active in the input and return success while it's true. Set CLAUDE_CODE_STOP_HOOK_BLOCK_CAP to raise this limit.` | P | Default cap 8. |
| `preventContinuation` on any event | §13.5 | `system/informational {content: "Operation stopped by hook[: <stopReason>]", level: "warning", prevent_continuation: true}` | P | The `prevent_continuation` boolean on the informational frame is exactly the signal a GUI needs to stop its own spinner. |
| `hook_stopped_continuation` | §13.3 | TUI: `<hookName> hook stopped continuation: <message>` in warning colour. Attachment dropped from the wire | D | Same content is in the informational frame above; low incremental loss. |
| `StopFailure` | §2.1 | Fire-and-forget; no user surface either way | — | |
| `SubagentStart` / `SubagentStop` | §2.1 | Hook frames only | P | |
| `PreCompact` / `PostCompact` | §13.12 | The TUI renders a display block: `PreCompact [<label>] completed successfully[: <output>]` / `… failed[: <output>]`, and a `blockedBy` list. Headless gets `compact_boundary` and, with `--include-hook-events`, `hook_response` frames | D | The per-hook PreCompact/PostCompact display block is not on the wire. Rebuild from `hook_response`. |
| `TaskCreated` / `TaskCompleted` / `TeammateIdle` blocking | §13.5 | Blocking messages `TaskCreated hook feedback:\n<e>` etc. become meta user messages; `preventContinuation` texts `TaskCompleted hook prevented continuation` / `TeammateIdle hook prevented continuation` | P | The `task_*` frames carry the resulting state change. |
| `PreModelSwitch` / `PostModelSwitch` | §2.1, §4.2 | `PreModelSwitch` `permissionDecision: "ask"` → **a headless session refuses instead of asking** (stated verbatim in the SDK schema). `deny` cancels the switch; `set_model` answers with an error | P | A GUI must expect `set_model` to fail when a `PreModelSwitch` hook says `ask`. The `model_*` fallback frames cover the automatic cases. |
| `PermissionRequest` | §13.9 | The verdict is applied before `can_use_tool` is sent, so an allowing/denying hook makes the prompt vanish. The TUI records `Allowed by <event> hook` / `Denied by <event> hook` in the transcript (`hook_permission_decision` attachment) | D | The attachment is dropped from the wire, so a GUI cannot show "this call was auto-approved by a hook". Workaround: with `--include-hook-events`, correlate a `PermissionRequest` `hook_response` against the absent `can_use_tool`. |
| `PermissionDenied` (+ `retry`) | §2.1 | Auto-mode classifier path; `permission_denied` frame is on the wire | P | |
| `ConfigChange` | §13.13 | Settings watcher; a hook cannot veto a `policy_settings` change. No wire frame for the event itself | D | A GUI editing settings via `update_settings` should re-read `get_settings` rather than expect a push. |
| `WorktreeCreate` / `WorktreeRemove` | §13.11 | Thrown errors surface as command failures | P | |
| `InstructionsLoaded`, `CwdChanged`, `FileChanged`, `DirectoryAdded` | §13.13 | Observability only; `DirectoryAdded` returns `systemMessages` which become informational banners | P | |
| `MessageDisplay` `displayContent` (replace the streamed delta) | §4.2 | The rewrite is applied to the assistant text **before** it is emitted, so a host sees the substituted text | P | A GUI streaming `stream_event` deltas gets the rewritten text transparently. |
| `Setup` (`--init` / `--maintenance`) | §2.1 | `hook_started`/`hook_response` **always** emitted (in the `J2r` always-on set) | P | |
| `Elicitation` / `ElicitationResult` | §13.10 | See §8 | P | |
| `hook_system_message` (a hook's `systemMessage` field) | §13.3 — TUI renders `<hookName> says: <content>` | **On the wire**: converted to `system/informational {content: "<hookName> says: <line>" per line, level: "notice"}` [`cli.pretty.js:92637-92644`, `172521-172531`] | P | One of exactly three attachment types that survive the headless filter. Renders identically. |
| `terminalSequence` (OSC 0/1/2/9/99/777 and BEL) | §4.5 | Written straight to the terminal by the CLI process | T | In a GUI-hosted child this writes escape bytes to a pipe the GUI is reading as JSON lines — harmless but noise. A GUI could parse OSC 9 desktop notifications out of the raw stream and turn them into native notifications; that would exceed the TUI. |
| `async_hook_response` / `async_hook_response_batch` | §14.3 | TUI renders `Async hook <event> completed` / `<N> async <event> hooks completed`. Attachment dropped from the wire; the reply's `systemMessage` and `additionalContext` still reach the model | D | `--include-hook-events` gives a terminal `hook_response` per async hook, which is the practical substitute. |
| `hook_error_during_execution` | §13.3 | TUI: `<hookName> hook warning`. Dropped from the wire | D | Covered by `hook_response {outcome:"error"}`. |
| `hook_success` (exit 0 with plain stdout) | §12.3 | TUI renders **nothing**. Reaches the model only for `SessionStart`, `UserPromptSubmit`, `UserPromptExpansion` | P | Symmetric; no gap. |

Rows: 40.

---

## 13. Hook configuration, `/hooks`, and settings a user changes from the TUI

| Feature | TUI behaviour (SPEC 27 §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/hooks` command | §21.1 — `local-jsx`, `immediate: true`, `requires: {workspace: false, ink: true}` | **Refused headless — live-confirmed**: sending `/hooks` returned `/hooks isn't available in this environment.` | X | Everything below must be rebuilt by a GUI from disk + `get_settings`. |
| `/hooks` is **read-only for hooks** — it browses, never edits (`ℹ This menu is read-only. To add or modify hooks, edit settings.json directly or ask Claude.`, `To add hooks, edit settings.json directly or ask Claude`, `To modify or remove this hook, edit settings.json directly or ask Claude to help.`) | §21.1 | n/a | R | This lowers the bar substantially: a GUI only needs a *viewer*, and can then exceed the TUI by adding an editor (`update_settings` writes `localSettings`; user/project settings need direct file writes). |
| Four-level navigation: `Hooks` (`<N> hook(s) configured`) → `<Event> - Matchers` → `<Event> - Matcher: <matcher\|(all)>` → `Hook details` | §21.2 | n/a | R | Row labels: matcher rows are `[<sources>] <matcher \|\| "(all)">` with `<N> hook(s)`; hook rows are `[<type>] <statusMessage \|\| display>` with the source description and ` (<pluginName>)` for plugin hooks. Detail rows in order: `Event:`, `Matcher:`, `Type:`, `Source:`, `Plugin:`, `Status message:`, then a captioned box (`Command` / `Prompt` / `URL` / `MCP tool` / `Script file` / `Script`). |
| Source ordering `localSettings, projectSettings, userSettings`, then plugin and built-in, ties by `localeCompare` | §21.2 | Derivable from `get_settings.sources` | R | |
| The seven source labels (`User settings (~/.claude/settings.json)`, `Project settings (.claude/settings.json)`, `Local settings (.claude/settings.local.json)`, `policySettings`, `Plugin hooks (~/.claude/plugins/*/hooks/hooks.json)`, `Session hooks (in-memory, temporary)`, `Built-in hooks (registered internally by Claude Code)`) | §6.1 | `get_settings` returns `effective` + `sources` | R | Note `flagSettings` (`--settings`) is deliberately **not** listed by `/hooks`, so a GUI that passes `--settings` should decide whether to be more honest than the TUI here. |
| Safe-mode banner (`ℹ Safe mode` + the "Hooks from settings files are suspended…" paragraph) | §21.4 | `get_settings` + knowing whether the GUI passed `--safe-mode`/`CLAUDE_CODE_SAFE_MODE` | R | |
| Policy-restriction banner (`ℹ Hooks Restricted by Policy` + "Only hooks from managed settings can run…") | §21.4 | `get_settings.effective.allowManagedHooksOnly` / `strictPluginOnlyCustomization` | R | |
| "All hooks disabled" full-screen pre-empt (`Hook configuration · disabled`, `All hooks are currently disabled[ by a managed settings file]. You have <N> configured hook(s) that <is\|are> not running.`, the three bullet consequences, `To re-enable hooks, remove "disableAllHooks" from settings.json or ask Claude.`) | §21.4 | `get_settings.effective.disableAllHooks` | R | The last line is suppressed when the switch came from managed policy — reproduce that. |
| The cloud-consent screen (`Let cloud sessions started from this machine run its hooks?`, the contract paragraph, four options, persistence explainers, the 250 ms mis-click guard, the `Hooks from this machine: on/off/not decided` status line, per-row placement text) | §21.5, §19.7 | Not reachable headless; the consent record is `~/.claude/state/device-hooks-consent.json` (`{version, choice, decidedAt, hostname}`, mode 0600, discarded when `hostname` changes) | X | This is the **only** thing `/hooks` writes. Relevant to a GUI only if it drives `claude --cloud`; otherwise skip. |
| Opening `/hooks` forces a settings reload (`q_n()`/`jxr()` refresh the frozen snapshot) — the documented workaround for "the settings watcher isn't watching `.claude/`" | §6.4, §21.6, §23.5 | **No control request refreshes the hooks snapshot.** `update_settings` and `apply_flag_settings` change settings; whether they refresh `WY()` is not established here | D | Real operational gap: a GUI that writes a new hook to `.claude/settings.json` may find it does not fire until the session restarts, exactly as the embedded skill warns. Safe workaround: restart the child session after writing hooks, or register the hook as an SDK callback via a fresh `initialize` instead of writing a file. |
| Hook config sources loaded identically headless? | §6.2–§6.5 | Yes — the merge (`user → project → local → flag → policy`, array concatenation, frozen snapshot) is interactivity-independent. The one interactivity-sensitive gate is workspace trust: `shouldSkipHookDueToTrust()` returns before matching when the workspace is untrusted, and headless `-p` **skips the trust dialog** entirely | P (with a trap) | So a GUI running `-p` in an untrusted directory silently runs no hooks at all, with only the debug line `Skipping <event>[:<query>] hook execution - workspace trust not accepted`. A GUI should check `projects[<cwd>].hasTrustDialogAccepted` in `~/.claude.json` and present its own trust step. |
| `disableAllHooks` also disables the status line and file suggestions | §20 | Same | P | |
| The seven disable switches (`policySettings.disableAllHooks`, `allowManagedHooksOnly`, safe mode, `strictPluginOnlyCustomization: ["hooks"]`, non-managed `disableAllHooks`, bare mode, untrusted workspace) | §20 | All readable from `get_settings` + the GUI's own flags | R | Note: **SDK callback hooks are exempt from the managed policy kill switch** (`Policy disableAllHooks: skipping configured hooks for <event> (SDK callback hooks still run)`), which is a genuine capability a GUI has that the TUI does not. |
| `/goal` — registers a session `Stop` prompt hook | §17.4 | `/goal` is a slash command; whether it works headless depends on its kind (not established here). The `active_goal` frame is on the wire, and the TUI's `goal_status` attachment (`Goal achieved` / `Goal not yet met… continuing` / `Goal could not be achieved` with duration/turns/tokens) is dropped | R | Refused when hooks are restricted: `/goal can't run while hooks are restricted (disableAllHooks or allowManagedHooksOnly is set in settings or by policy).` |

Rows: 15.

---

## 14. SDK hooks via `initialize.hooks` (the `hook_callback` round trip)

| Feature | Behaviour (SPEC 45 §45.20, 27 §10.7) | Class | Notes |
|---|---|---|---|
| Registration | `initialize.hooks: {<Event>: [{matcher?, hookCallbackIds: string[], timeout?}]}`. The CLI installs one `callback` entry per id with `origin: "sdkHost"` and **replaces** every previously registered SDK-host hook for that event | P | A repeated `initialize` re-registers; `hooks_applied: true` comes back on the response. Ids are opaque strings (the in-process SDK mints `hook_0`, `hook_1`, …). |
| Which events a host can register for | **All 33.** The `input` field of `hook_callback` is the union of all 33 per-event input schemas | P | Nothing is SDK-ineligible. |
| The request | `{subtype: "hook_callback", callback_id, input, tool_use_id?, issued_at?, deadline_ms?}` | P | `issued_at`/`deadline_ms` are added only on the device-hook path; a GUI can ignore them. |
| The response | `{async: true, asyncTimeout?}` or the full hook reply (`continue`, `suppressOutput`, `stopReason`, `decision`, `systemMessage`, `terminalSequence`, `reason`, `hookSpecificOutput`) | P | A non-abort failure is swallowed (`console.error("Error in hook callback <id>:", e)` — one of the few direct stderr writes) and the hook is treated as having no opinion. |
| Timeouts | `timeout` on the registration is in **seconds**. A per-hook timeout on `UserPromptSubmit`/`UserPromptExpansion` is swallowed into a blocking result `<event>[:<matchQuery>] hook callback timed out after <ms>ms` with `suppressOriginalPrompt: true`; on other events it becomes `outcome: "cancelled"` | P | The two fixed `PreToolUse` stop reasons are worth surfacing verbatim in a GUI: `PreToolUse hook did not respond before its timeout (host client may be unreachable). The tool call was not executed; other configured hooks may not have completed.` and the `…failed with an unexpected error…` variant. |
| Generations and retirement | Every callback captures a generation counter. A repeated `initialize` bumps it, cancels every pending `hook_callback` with `control_cancel_request`, and resolves each with a fail-safe: `PreToolUse` and `PreModelSwitch` → **deny**; the prompt hooks → **block with `suppressOriginalPrompt: true`** | P | A GUI must not re-`initialize` mid-turn casually — it will deny in-flight tool calls. |
| Confined-session strip | In a confined session a hook `allow` is discarded (`… permissionDecision=allow ignored: a confined session takes grants only from its command line`) | P | |
| Shutdown fence | After process commit, six gating events (`PreToolUse`, `PermissionRequest`, `UserPromptSubmit`, `UserPromptExpansion`, `TaskCompleted`, `TeammateIdle`) **stall forever** rather than proceed unguarded; every other event's hooks are skipped; `SessionEnd` is exempt | P (with a trap) | A GUI whose hook callback never answers during shutdown will hang the child. Always answer, including on teardown. |
| Function hooks (`type: "function"`) and the plugin hooks worker | 27 §10.8, §18 — worker thread, `$` host API, static-scan allowlist, `PreToolUse` two-tier chain, `tengu_plugin_hooks_modules` gate (default **off**) | — | Entirely internal; nothing a GUI drives or renders. The only user-visible surfaces are the `hook_failed` log frames and the wedge message `<plugin> ignored its signal <N> times in a row: a runaway plugin in the hooks worker`, none of which is on the wire. Record as invisible. |

Rows: 9.

---

## Top gaps in this area

Ranked by how much they cost a GUI that wants TUI parity or better.

1. **No push frame for MCP server state changes.** `mcp_status` is poll-only, and `system/init` is emitted only at the start of a turn. A server that finishes connecting, drops, or flips to `needs-auth` mid-turn is invisible until the host polls. The TUI re-renders `/mcp` live. Class D — the workaround is a poll loop on `mcp_status`, which is cheap but racy. (§2)
2. **`mcp_status` carries no per-tool descriptions or schemas, no `errorCode`, no error for `needs-auth`, and collapses `cached` to `pending`.** The `/mcp` detail view's `Issue:` row, the `⚠ connected · tools fetch failed` vs `⚠ connected · no tools` distinction, and the `View tools` screen's descriptions are all unreachable. Class D. Partial workaround: `ToolSearch` output carries `failed_mcp_servers[].errorCode`; `claude mcp get <name>` as a subprocess gives the rest. (§2, §3.2, §3.4)
3. **`file_suggestions` returns files only — no MCP resources, no resource templates, no agents.** The TUI's `@` picker is a unified fuzzy search over all four. A GUI cannot build an equivalent picker from the wire; `@server:uri` still *resolves* when typed blind, so the capability exists but is undiscoverable. Class D, no good workaround for non-SDK servers. (§6)
4. **The hook spinner's `statusMessage` never reaches the host.** `hook_progress` internal progress messages are dropped by the converter; `--include-hook-events` gives only `hook_name` (`<event>:<matchQuery>`). The one field hook authors write for display is invisible. Class D. (§12)
5. **MCP tool progress notifications are dropped.** `onprogress` (`progress`, `total`, `message`) goes to an internal channel that the headless converter does not handle. A long MCP call shows as an opaque spinner with no server-supplied status. Class D. (§9)
6. **Auto-backgrounding of slow MCP calls is off by default headless.** `getMcpAutoBackgroundMs` returns `0` in a non-interactive session unless `CLAUDE_AUTO_BACKGROUND_TASKS` is set, so a 10-minute MCP call blocks the turn instead of becoming a background task. Class D, but with a one-line fix: set that env var when spawning. Highest effort-to-value ratio on this list. (§9)
7. **The `.mcp.json` approval dialog is unreachable and silently auto-approves.** There is no dialog kind for it; `iY()` promotes `pending → approved` in any non-interactive session with `projectSettings` enabled. The security moment the TUI presents simply does not happen. Class X. A GUI that cares must build its own consent step from a read of `.mcp.json`. (§1)
8. **The auth-stub tools are suppressed non-interactively.** `mcp__<server>__authenticate` / `complete_authentication` do not exist headless, so the model cannot start an OAuth flow; it is instructed not to ask the user for codes. All re-auth must be driven from the GUI via `mcp_authenticate` / `mcp_oauth_callback_url`. This is live-relevant right now: `plugin:supabase:supabase` is `needs-auth` on this machine. Class X. (§4)
9. **Stop-hook and PreCompact/PostCompact display blocks are not on the wire.** The TUI's `Ran <N> stop hook(s)` row with its error and feedback sub-lines, and the `PreCompact [<label>] completed successfully: <output>` block, are dropped. Without `--include-hook-events` a GUI shows an unexplained extra turn after a Stop hook blocks. Class D — mitigated almost entirely by always passing `--include-hook-events`. (§12)
10. **Editing hooks does not take effect without a reload, and no control request forces one.** The frozen `WY()` snapshot is refreshed by the settings watcher or by opening `/hooks`; a GUI has neither. Class D. Practical answer: restart the child after writing hooks, or prefer SDK callback hooks over file-based ones. (§13)
11. **`hook_blocking_error`, `hook_permission_decision`, `hook_cancelled`, `hook_error_during_execution`, `async_hook_response`, `mcp_resource` attachments are all dropped from the wire.** Only `hook_system_message` survives (as `system/informational`, level `notice`). Class D, largely covered by `--include-hook-events`, except `hook_permission_decision` ("Allowed/Denied by `<event>` hook") which has no substitute. (§12, §6)
12. **`--include-hook-events` is effectively mandatory.** Without it only `SessionStart` and `Setup` emit lifecycle frames; every other hook is invisible. It is already in the afleet command line — this row exists to say: do not remove it. (§12)
13. **Untrusted workspace silently disables all hooks headless.** `-p` skips the trust dialog, so hooks are dropped with only a debug line. A GUI should check `projects[<cwd>].hasTrustDialogAccepted` and present its own trust step. Class D with a clean workaround. (§13)
14. **Where the GUI can exceed the TUI:** `set_mcp_permission_mode_override` has **no TUI surface at all**; SDK MCP servers (`initialize.sdkMcpServers` + `mcp_message`) let a native app expose its own tools in-process with no subprocess; SDK callback hooks survive the managed `disableAllHooks` kill switch; `PreToolUse` `defer` is honoured only in print mode; `elicitation_complete` lets a GUI close its waiting dialog on a push rather than a poll; and `/hooks` being read-only means a GUI shipping a hook *editor* is strictly ahead.

---

## Unverified

Things inferred rather than read directly, or read only partially.

1. **Whether `update_settings` or `apply_flag_settings` refreshes the frozen hooks snapshot (`WY()`).** SPEC 27 §6.4 lists four refreshers (`q_n()`, `jxr()`, `TD(t)`, `cNe(t)`) but I did not trace whether either control request calls one. The gap row in §13 assumes it does not; a GUI should test this empirically before designing around it.
2. **Whether `/goal` is runnable headless.** It is refused when hooks are restricted, and I did not check its command kind in `system/init.slash_commands`. The `active_goal` frame's presence on the wire suggests it is, but I did not confirm.
3. **Exactly which internal `progress` message shapes `cfn(e)` admits** in the converter's `progress` arm [`cli.pretty.js:92964`]. I read the else-chain and confirmed `hook_progress` and `mcp_progress` are not among the explicitly handled types, and that unhandled types `break` without yielding. I did not read `cfn`'s body, so if it happens to admit `hook_progress` the §12 and §9 gap rows would be wrong. Given that `cfn` is followed by `ufn(e, r)` (a nested-progress expander) this is unlikely, but it is the one inference load-bearing for two top-ten gaps.
4. **`iA(e)`** — the predicate gating the reduced `mcp_status` payload (`{name,status}` only) and the reduced `system/init`. I read its effect but not its definition; SPEC 45 context suggests it means "confined / eval session", not "headless". If it were true for ordinary headless sessions, live `mcp_status` would not have carried `config`/`scope`/`tools` — and it did, so headless is not confined. Recorded because the exact trigger matters for a GUI running plugin evals.
5. **Whether the `mcp_reconnect` success payload carries anything.** The handler ends in `Kl(d, di(F, Ce))`; SPEC 45's table shows no response fields. I did not read `Kl`.
6. **The `anthropic-hosted` branch message in `mcp_authenticate`** (`$e(d, Zn(z.message))`) — the message comes from the auth-strategy classifier and I did not resolve its text.
7. **Chapter 50 (channels) content.** Per the brief I noted only the MCP-side surfaces (`channelsEnabled`, the `claude/channel` experimental capability in `mcp_status`, `channel_enable`, and the discovery-cache live-dial forcing). The channel protocol itself is another agent's area.
8. **`claude mcp login` / `logout` handler strings** — SPEC 31 §7.7 quotes the subcommand definitions but flags the handler bodies (`chunk-egx269gm.js`) as unread. I confirmed one string (`Authenticated with "<n>", but it's currently disabled. Enable it in /mcp for its tools to load.`) incidentally but did not enumerate them; they are subprocess-only and low value for a GUI.
