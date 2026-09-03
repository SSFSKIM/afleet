<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# TUI-vs-headless UX gap inventory — Chrome, computer use, web tools, enterprise/policy, cloud sessions

Chapters covered: SPEC 46 (computer use and Chrome), 19 (web tools), 48 (enterprise and policy),
37 (cloud sessions and teleport).

Classes: **P** parity via protocol · **R** rebuild (data reachable) · **D** data gap ·
**X** unreachable · **T** terminal-specific.

## Cross-cutting fact that decides many rows below

The headless dialog dispatcher `K_` [`chunk-2rhzyjym.js:174430-174444`] forwards a
`request_user_dialog` control request to the host for **exactly three** dialog families:
`refusal_fallback_prompt` [`chunk-2rhzyjym.js:64169`], `fable_overage_consent_prompt`
[`chunk-2rhzyjym.js:68575`], and Slack-connect dialogs (only when the Slack integration object
is non-null). MCP elicitation goes out separately as the `elicitation` control request.
**Every other `dialog_kind` returns its declared `default` immediately**, no matter what the host
puts in `initialize.supportedDialogKinds`. The full kind list, recovered from the dialog-spec
factory call sites, is: `auto_mode_flagged_allow`, `auto_mode_setup_review`,
`chrome_install_setup`, `chrome_install_upsell`, `cloud_sync_consent`, `cloud_sync_offline`,
`computer_use_approval`, `fable_overage_consent_prompt`, `goal_proposal`, `ide_onboarding`,
`left_arrow_confirm`, `local_jsx`, `lsp_recommendation`, `managed_settings_security`,
`mcp_elicitation`, `mcp_elicitation_waiting`, `mcp_url_elicitation`, `peer_inbound_approval`,
`permission_*` (9 kinds, which travel as `can_use_tool` instead), `plugin_hint`,
`refusal_fallback_prompt`, `remote_callout`, `sandbox_network_access`, `ultraplan_launch`.
Defaults that matter here: `computer_use_approval` → `{granted:[],denied:[],flags:…}`
[`chunk-2rhzyjym.js:1197`]; `cloud_sync_consent` → `"not_now"` [`chunk-2rhzyjym.js:325413`];
`chrome_install_upsell`/`chrome_install_setup`/`ultraplan_launch`/`sandbox_network_access` →
`"cancelled"`; `managed_settings_security` → `"deferred_no_consent_surface"`; `local_jsx` → `null`.

Live ground truth (2.1.259, `/tmp/afleet-gap/init-dump.json`): the headless `initialize` response
lists 102 commands and **none** of `chrome`, `teleport`/`tp`, `remote-env`, `cloud-plugins`,
`autofix-pr`, `ultraplan`, `passes`, `web-setup`, `privacy-settings`, `upgrade`,
`rate-limit-options`, `pro-trial-expired`, `limit-reset`, `low-priority` are present. `ultrareview`,
`schedule`, `usage-credits`, `extra-usage`, `usage`, `doctor`, `debug`, `skill-doctor` **are**
present. That is exactly the local-jsx-vs-local split of SPEC 28 §22.

---

## 1. Claude in Chrome — enablement, pairing, dialogs (SPEC 46 §§46.14–46.20)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/chrome` settings dialog (Status / Extension / Browser rows, 5-item menu, footer) | `local-jsx`, `availability: ["claude-ai"]`, `isEnabled: () => !Oe()` — interactive only (46 §46.19, §46.19.1) | absent from `initialize.commands` (live init dump); a `local-jsx` command is refused with the SPEC 28 §8.1 panel message | X | GUI must rebuild the whole panel from disk + control requests: `Status` from `mcp_status` (server `claude-in-chrome` connected?), `Extension` from `~/.claude.json` `cachedChromeExtensionInstalled`, `Browser` from `chromeExtension.pairedDeviceName`. **Exceeds:** a GUI can show live per-tab state and open the three URLs natively. |
| `/chrome` browser picker (`Looking for connected browsers…`, `<name> · <os> · current`, `‹ Back`) | 46 §46.19.2 | none — same local-jsx refusal | X | Data is reachable: `mcp_call` on `mcp__claude-in-chrome__list_connected_browsers` / `select_browser` gives the identical list and selection. Reclassify to R if the GUI drives it through `mcp_call`. |
| `--chrome` / `--no-chrome` launch flags | 46 §46.29.2, §46.14.1 | flags are argv, so the GUI can pass them | R | Necessary, not optional: step 5 of `shouldEnableClaudeInChrome` disables Chrome for any **non-interactive** session, so afleet must pass `--chrome` (or `CLAUDE_CODE_ENABLE_CFC=1`) or browser tools never appear. `--chrome` also overrides the enterprise-MCP and `--safe-mode`/`--restricted` blocks. |
| One-time onboarding card (`Claude in Chrome`, chromeYellow) | 46 §46.15.1 | never rendered; `hasCompletedClaudeInChromeOnboarding` never set | X | GUI should render its own onboarding once and write the same config key so a later terminal session does not re-show it. |
| Auto-enable prompt (`Claude in Chrome extension detected`, `Yes, use my browser` / `No, keep browser tools off`) | 46 §46.15.2 | not raised: `shouldAutoEnableClaudeInChrome` requires an interactive dialog host | X | GUI must ask itself and write `claudeInChromeDefaultEnabled` into `~/.claude.json`. |
| In-turn install upsell (`Install extension` / `Not now` / `Don't ask again`) and the `chrome_install_setup` phase driver | 46 §46.15.3 — dialog kinds `chrome_install_upsell`, `chrome_install_setup` | both resolve to their default `"cancelled"` in headless (see cross-cutting note) | X | The model instead receives narration `Y`/`Fe` (46 §46.15.4), which is on the wire as assistant text. GUI must own extension installation entirely. |
| The 13 model-facing narrations about Chrome availability | 46 §46.15.4 | they are skill output → assistant text on the wire | P | Rendered as normal model text; nothing to rebuild. |
| Browser-tool permission dialog (`Claude in Chrome wants to <verb> on <host>`, `Allow` / `Allow all actions on <host> for this session` / `Deny`) | 46 §46.17.3, verb table §46.17.4 | `can_use_tool` control request with `tool_name: mcp__claude-in-chrome__*`, `input`, and `permission_suggestions` carrying `ClaudeInChromeDomain(<host>)` | P | The wire carries the suggestion rule, so the always-allow row is reproducible. **Missing:** `metadata.command.chrome` (`{host, url, domainAllowed, navigation}`) and the pre-computed `verbPhrase` are TUI-side additions built in `Ve()`/`PGe()` [`chunk-ht9kfnjn.js:548325`]; a GUI must re-derive the verb phrase and the host from `input` itself. |
| Cross-site-navigation forcing a prompt | 46 §46.12.4, §46.17.2 step 6 | manifests only as an extra `can_use_tool` | P | The *reason* (`decisionReason.type: "safetyCheck"`, `"cross-site navigation pending"`) is on the permission request; GUI can surface it. |
| Domain-rule denials (`Claude in Chrome is denied on <host>.`) and the five `browser_batch` shape denials | 46 §46.17.2 | tool result text on the wire | P | |
| Multi-browser guard (`Multiple Chrome browsers are connected…`) | 46 §46.7.1 | model-facing tool result; resolution goes through `AskUserQuestion`, which is a `can_use_tool` | P | The GUI renders the AskUserQuestion options list; this is the one pairing path that *does* reach a headless host. |
| The extension-side pairing prompt (`switch_browser` broadcast, "click Connect in the browser you want") | 46 §46.7, §46.7.2 | happens inside Chrome, not on the CLI wire at all | D | Nothing to render; the GUI can only tell the user to look at the browser. Workaround: drive `select_browser` via `mcp_call` so the broadcast is never needed. |
| Native-host install / manifest writing / first-install reconnect page opening | 46 §46.3 | happens as an unawaited side effect of `setupClaudeInChrome`; only debug-log lines | D | Silent in both TUI and headless; the GUI cannot report progress. Workaround: check `~/.claude/chrome/chrome-native-host` and the per-browser `NativeMessagingHosts/…json` on disk. |
| Browser tool-use header `Claude in Chrome[<tool>]` and the argument line (`navigate` → hostname, `computer/type` → `type "…"`, etc.) | 46 §46.28.1 | wire carries only `tool_use` with `name` + raw `input` | R | Pure client-side rendering; the table in §46.28.1 is the spec to reimplement. |
| `[View Tab]` OSC-8 hyperlink to `https://clau.de/chrome/tab/<tabId>` | 46 §46.28.1 | not on the wire | R | Trivially derivable from `input.tabId`. **Exceeds:** a GUI can open the tab natively instead of an OSC-8 link. |
| Collapsed result lines (`Navigation completed`, `Action completed`, `Page read`, …) outside `--verbose` | 46 §46.28.1 | wire carries the full tool_result | R | GUI must reimplement the 17-entry map; it can also just show the real result. |
| Screenshot images returned by `computer`/`zoom` | TUI prints `Action completed` and **never shows the image** (46 §46.28.1) | tool_result `content` carries `{type:"image", data, mimeType}` blocks | P → **exceeds** | This is a straight win: the GUI can display the screenshot inline where the TUI structurally cannot (ch. 41: the TUI cannot draw images). |
| `save_to_disk` screenshots + `Screenshot saved to: <path>` note | 46 §46.11.3 | text blocks on the wire; files under `<tmpdir>/claude-chrome-screenshots-*` | P | GUI can read and display the file. |
| `file_upload` path gate refusals (`Cannot upload "…": only files this session is allowed to read…`) | 46 §46.18 | model-facing tool result | P | |
| Auto-mode allowlist skipping the classifier for read-only browser tools | 46 §46.17.7 | invisible either way (no prompt is raised) | P | |
| `/web-setup` (Connect Claude on the web to GitHub, `gh auth token` import) | 46 §46.20 — `local-jsx`, `availability: ["claude-ai"]` | absent from the headless command list (live init dump) | X | Every network call (`POST /v1/code/github/import-token`) is plain HTTPS with the user's OAuth token; a GUI could re-implement, but that is outside the CLI's protocol. |
| `/web-setup` failure texts (gh missing / not authed / too old / inconclusive) | 46 §46.20.4 | none | X | |

## 2. Computer use on macOS (SPEC 46 §§46.21–46.28)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Computer use available at all | wired only when the session is **interactive**, not `--restricted`, subscription is max/pro, no HIPAA taint, and `tengu_malort_pedway.enabled` is true (46 §46.21, wiring at `chunk-chr1kh62.js:454425` gated on `!Oe()`) | never wired in a headless run | X | This is the single hardest blocker in chapter 46: there is no flag equivalent to `--chrome` for computer use. A GUI cannot turn it on through argv. **Workaround:** none inside the protocol; afleet would have to run its own `computer-use` MCP server (the CLI exposes the entry point `claude --computer-use-mcp`) and inject it via `--mcp-config`, then the tools arrive as ordinary MCP tools. |
| `request_access` approval card (app list, `clipboardRead`/`clipboardWrite`/`systemKeyCombos` checkboxes) | dialog kind `computer_use_approval` (46 §46.24.2) | resolves to the default `{granted: [], denied: [], flags: …}` — an **empty grant** | X | Even if computer use were wired, every `request_access` would return an empty allowlist, so the dispatch gate answers `No applications are granted for this session. Call request_access first.` (46 §46.26.3). |
| macOS TCC panel (`Computer Use needs macOS permissions`, `Accessibility:` / `Screen Recording:` rows, `Open System Settings → …`, `Try again`) | 46 §46.27.1 — same `computer_use_approval` dialog, routed by `tccState` | same default → never shown | X | **Can a headless process trigger the OS prompts?** Only indirectly. The prompts come from `tcc.requestAccessibility()` / `tcc.requestScreenRecording()` in `computer-use-swift.node`, and the *only* JS caller is the panel's option handler [`chunk-bq8epagv.js:418835`, `:418839`], which never runs headless. `ensureOsPermissions` calls the non-prompting `check*` variants only (46 §46.21.2). So a headless CLI never raises a macOS permission dialog. A GUI hosting the CLI must request Accessibility/Screen Recording for **its own** bundle and deep-link to `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` / `?Privacy_ScreenCapture` itself. |
| Unattended-session TCC message (`…the grant prompt can't be shown during a scheduled run…`) | 46 §46.27.2 | this is the branch a non-interactive session would take | P | If computer use is ever reachable headlessly, this text arrives as a tool result. |
| Screen-takeover consent card | 46 §46.26.4 | **never fires even in the TUI** — `buildSessionContext` does not supply `onTakeoverRequest` (46 §46.26.4) | T | Listed for completeness; not a gap. |
| Cross-session lock (`Computer use is in use by another Claude session (<id>…)`) | 46 §46.26.2 | tool result text; lock file `~/.claude/computer-use.lock` | P | GUI can also read the lock file to pre-empt. |
| Esc hotkey to abort (`Claude is using your computer · press Esc to stop` OS notification) | 46 §46.22.3 — a global CGEvent tap registered by the Swift addon; the callback aborts the turn | not installed in a headless run (the tap is armed with the lock, which is only taken by a wired session) | X | The GUI already has `interrupt`; the OS notification itself is emitted through `os_notification`, which SPEC 45 §9.2 **drops before the wire**. **Exceeds:** a native GUI can post its own notification and bind its own global hotkey. |
| Computer-use tool header `Computer Use[<tool>]` + argument line (`(x, y)`, `direction ×n at (x,y)`, `"<text>"`…) | 46 §46.28.2 | raw `tool_use` input on the wire | R | 11-row table to reimplement. |
| Computer-use result collapsing (`Captured`, `Clicked`, `Typed`, `Pressed`, `Scrolled`, `Dragged`, `Opened`, `Access updated`) | 46 §46.28.2 — note the polarity is **inverted** vs. browser tools: verbose returns `null` so the image renders | wire carries the JPEG image block | P → **exceeds** | Same win as Chrome screenshots: the GUI shows the image unconditionally. |
| Frontmost-gate / tier / hit-test refusals (browser at tier `read`, terminal at tier `click`, desktop shell, ungranted app, mid-delivery focus change) | 46 §46.25.3–§46.25.4 | model-facing tool results | P | |
| Multi-display notes (`This screenshot was taken on monitor "X"…`) and hidden-application notes | 46 §46.23.4, §46.23.5 | appended text blocks on the wire | P | |
| Policy-denied app message (`"<app>" is blocked by policy for computer use…`) and user deny-list message | 46 §46.25.2 | tool result text | P | Note the user deny list lives in the **Claude desktop app's** Settings, not in `settings.json`; a GUI cannot offer that toggle. |
| `/config` row `Claude in Chrome enabled by default` | 46 §46.29.3 | `get_settings` / `update_settings` reach `localSettings` only; this key lives in the **global config** `~/.claude.json`, not settings | D | Workaround: the GUI reads and writes `~/.claude.json` directly (the same thing `/chrome` does). |

## 3. WebFetch (SPEC 19 §§19.3–19.19)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| WebFetch permission prompt — title `Claude wants to fetch content from <hostname>` and the persist row `Yes, and don't ask again for <host>` | 19 §19.3 (`description`), §19.16.3, §19.27.2; dialog kind `permission_webfetch` | `can_use_tool` with `tool_name: "WebFetch"`, `input: {url, prompt}` and `permission_suggestions: [{type:"addRules", rules:[{toolName:"WebFetch", ruleContent:"domain:<host>"}], behavior:"allow", destination:"localSettings"}]` | P | The GUI gets the exact fields it needs. The rendered host is `Mte(host)` (trailing dot stripped, IPv6 bracketed) — re-derive from `input.url`. |
| Deny message `WebFetch denied access to domain:<host>.` and ask message `Claude requested permissions to use WebFetch, but you haven't granted it yet.` | 19 §19.16.3 | carried as `permissionResult.message` on the same `can_use_tool` | P | |
| Artifact-path permission variants (`Claude wants to read another person's artifact at <url> — its content enters this conversation`, ownership-unconfirmed variant, other-org deny) — all with `suppressAlwaysAllowRule: true` | 19 §19.17.3 | on `can_use_tool`; the suppress flag means **no** suggestion array is sent | P | GUI must hide its always-allow affordance when suggestions are absent, or it will offer a rule the CLI will not honour. |
| Preapproved-host auto-allow (91 hosts, §19.15.1) | silent allow, no prompt | identical — no `can_use_tool` is emitted | P | Nothing to render; the GUI just never sees a prompt for `docs.python.org` etc. |
| In-progress line `Fetching…` | 19 §19.27.1 | `tool_use` frame arrival is the only signal; no `tool_progress` for WebFetch (SPEC 45 §9.1 restricts `tool_progress` to Bash/PowerShell) | R | GUI shows its own spinner keyed on the unresolved `tool_use_id`. Also available: `getActivityDescription` text `Fetching <url truncated to 50>` — but that is computed client-side, not sent. |
| Completion line `Received **12.3KB** (200 OK)` | 19 §19.27.1 — built from the structured `WebFetchOutput` `{bytes, code, codeText}` | the wire's `tool_result` content is `output.result` **only**: `mapToolResultToToolResultBlockParam` returns `{tool_use_id, type:"tool_result", content: result}` (19 §19.3, line 98073) | **D** | `bytes`, `code`, `codeText`, `durationMs`, `url` and `artifactRead` are dropped at the wire boundary. A GUI cannot render the size/status line at all. Partial workaround: the HTTP-error result body embeds `The server returned HTTP <code> <text>.` so failures are recoverable; success size/status is not. |
| Verbose mode appending the full `result` string | 19 §19.27.1 | the wire always carries the full `result` | P → **exceeds** | The GUI has the verbose payload unconditionally and can offer expand/collapse. |
| `renderToolUseMessage` — bare URL, or `url: "…", prompt: "…"` in verbose | 19 §19.3 | raw `input` on the wire | R | |
| Redirect report (`REDIRECT DETECTED:` block, three degraded `Redirect URL:` forms) | 19 §19.14.2 | full text in the tool result | P | GUI can linkify the relayed target; note the spec's own warning that it is server-supplied and unverified. |
| Domain-preflight refusals (`Claude Code is unable to fetch from <host>`, `Unable to verify if domain <host> is safe to fetch…`) | 19 §19.7.4 | thrown tool errors → `is_error` tool_result | P | |
| Binary spill note (`[Binary content (application/pdf, 1.2MB) also saved to <path>]`) | 19 §19.9.3 | appended to `result`, so on the wire | P | GUI can open the file at that path. |
| `/clear` dropping the WebFetch cache | 19 §19.11.5 | `/clear` is a `local` command available headless; `conversation_reset` is emitted | P | |
| URL-provenance interactive prompt (cloud sessions only) — `WebFetch was denied by this session's URL provenance check. Approve to allow fetching this URL.` | 19 §19.18.2 | issued through `canUseTool`, i.e. a real `can_use_tool` with a fresh uuid and a `WebFetch(domain:…)` suggestion, raced against a 300 s timer | P | Only reachable in a CCR session with `CLAUDE_CODE_WEBFETCH_USE_CCR_PROXY`; the GUI answers it like any permission prompt. Note the outcome `suppressed_mode` when the mode is `dontAsk`/`bypassPermissions`. |
| `web-fetch` subagent routing (WebFetch removed from the main tool list) and its three "not available in this context" explanations | 19 §19.19.5–§19.19.7 | the tool simply is not in `system/init.tools`; explanations arrive as model-facing text | P | Gate `tengu_clever_orbit` / `CLAUDE_CODE_WEB_FETCH_AGENT`. GUI should not assume `WebFetch` is always present. |
| `web-fetch` agent harness note (`[Harness note, not part of the agent's report: WebFetch saved …]`) | 19 §19.9.4 | appended after the subagent report → arrives as a `user` tool_result frame | P | |
| `--restricted` removing `WebFetch` | 19 §19.29; 48 §4.2 R2 — `WebFetch` plus every `enablesCodeExecution` tool becomes a `toolsNarrowing` deny rule unless named in `--tools` | the tool is absent from `system/init.tools` | P | GUI reads the tool list; no separate signal is emitted for *why* it is missing. |

## 4. WebSearch (SPEC 19 §§19.20–19.24)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Permission handling | `checkPermissions` returns `behavior: "passthrough"` with an `addRules WebSearch → localSettings` suggestion (19 §19.16.4) | a `can_use_tool` only if a rule requires it; otherwise no prompt | P | |
| Live progress `Searching: <query>` and `Found <n> results for "<query>"` | 19 §19.27.2 — driven by `renderToolUseProgressMessage` fed by `emitProgress` events `{type:"query_update"}` / `{type:"search_results_received"}` (19 §19.23.4) | **not on the wire**: `tool_progress` is emitted only for Bash/PowerShell, and only under `CLAUDE_CODE_REMOTE`/`CLAUDE_CODE_CONTAINER_ID` (headless baseline, SPEC 45 §9.1) | **D** | This is the single most visible WebSearch regression. The GUI can show only "searching…" until the tool result lands. Workaround: none inside the protocol; a protocol addition (forwarding `tool_progress` for WebSearch) would be needed. |
| Completion line `Did 3 searches in 4s` | 19 §19.27.2 — built from `searchCount` / `durationSeconds` in `WebSearchOutput` | the wire's tool_result is the flattened `Web search results for query: "…"` + `Links: <JSON>` + `REMINDER:` string (19 §19.24.2) | **D** | `searchCount` and `durationSeconds` are dropped. The GUI can count the `Links:` groups by parsing the JSON, and time the request itself; it cannot recover `searchCount` when the model interleaved free text. |
| Search-result citations (`Links: [{"title","url"},…]`) | rendered only as the collapsed count line; the raw JSON is what the *model* sees | the same JSON is in the tool_result | P → **exceeds** | The GUI can render real clickable citation cards with titles — strictly better than the TUI, which shows only `Did N searches`. Note `page_age`, `encrypted_content` and snippets are dropped server-side before the harness sees them (19 §19.24.1), so a GUI cannot show snippets either. |
| Session budget message (`Web search was not performed: this session has used its web search budget (200 of 200 WebSearch calls)…`) | delivered as an ordinary, non-error tool result (19 §19.23.1) | identical on the wire | P | Caveat: the SDK/thin-client stub task registry implements the counter as a no-op returning `0`, so the cap never fires there [`chunk-c97e0h62.js:440855`]. |
| Provider unavailability (`Web search is not available on this Foundry deployment.`) and the provider matrix | 19 §19.25.2 | tool absent from `system/init.tools`, or a thrown tool error | P | |
| `--verbose` rendering of `allowed_domains` / `blocked_domains` | 19 §19.20 | raw `input` on the wire | R | |

## 5. Web / connector isolation and web-tool enable conditions (SPEC 19 §§19.25–19.26, 48 §3.8)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Isolation-latch denial (`Connectors are unavailable in this session under your organization's web search / connector isolation policy…` and the web-side twin) | 19 §19.26; 48 §3.8 | model-facing tool-result denial; also `tengu_tool_use_isolation_latch_denied` telemetry (48 §17.1) | P | The GUI sees the denial text but has no signal for *which class the session is latched to* until a denial occurs. Workaround: watch the first web/connector tool_use and mirror the classification locally (the rules are in 19 §19.26). |
| `initialize.webSearchIsolationExemptMcpServers` | not settable from the TUI at all | an `initialize` field the host may set; unioned with the eight built-in exempt servers (`cowork`, `workspace`, `session-info`, `mcp-registry`, `plugins`, `scheduled-tasks`, `dispatch`, `ide`) | P → **exceeds** | An SDK host has a lever the terminal user does not. Reconciliation class on a cloud session is `lost` [`chunk-fv96b6je.js:510395`]. SPEC 48's own open question flags that this lets a host defeat an org's isolation policy. |
| `allow_web_fetch` org denial disabling `WebFetch` (and the `hipaa` taint) | 19 §19.25.1; 48 §3.5 | tool absent from `system/init.tools`; no explanatory frame | D | The GUI cannot tell "org policy removed WebFetch" apart from "`--restricted` removed WebFetch" apart from "the tool list just does not include it". Workaround: read `~/.claude/policy-limits.json` (mode 0600) directly. |
| `skipWebFetchPreflight` settings key | editable in `settings.json` only | `get_settings` / `update_settings` (localSettings only) | P | Restrictive-only: policy can force `false`, a lower tier cannot force `true` (48 §2.5 step 4). |

## 6. Managed settings, the approval dialog and policy-blocked commands (SPEC 48 §§2, 5, 16)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Dangerous-managed-settings approval dialog (`Managed settings require approval`, `Yes, I trust these settings` / `No, exit Claude Code`, the ⋯-and-N-more elision line, the two ＋/− delta lines) | 48 §2.9.2 — dialog kind `managed_settings_security` | **the requirement is waived**: in `-p`/non-TTY mode the outcome is `deferred_non_interactive` and the payload **is applied with no prompt** (48 §2.9.3) | X (and a security note) | This is the one row where headless is not merely different but *less safe*. A GUI cannot re-add the gate through the protocol — the decision is made before any frame is written. If afleet wants parity it must read `remote-settings.json` + `remote-settings-consent.json` itself and refuse to launch. |
| Rejection exit (`Managed settings were not approved; exiting without applying them.`, exit 1) | 48 §2.9.3 | unreachable (see above) | X | |
| Remote-settings load failure (`Your organization requires remote managed settings to load, but they could not be loaded…`) | 48 §2.9.3 | printed to stderr before any protocol frame | R | GUI must surface stderr; the headless protocol carries nothing. |
| Version pins (`Claude Code <v> is older than the minimum version required by your organization (<v>).` / newer-than-maximum twin) | 48 §2.7 — hard startup refusal | same refusal, on stderr, before the wire opens | R | afleet must render stderr on a failed launch or the user sees an unexplained crash. `update`/`install`/`doctor` are exempt. |
| Policy-helper failure/refresh warnings (`policyHelper refresh failing: …`, `remote policyHelpers entry not run: …`, 512-char cap) | 48 §2.8.4 — a status-only warning maintained alongside the tier | status warnings are TUI status-line content, not a wire frame | D | Workaround: none on the wire. `claude doctor` reports the same conditions and **is** available headless (it is in the live command list). |
| `allowManagedPermissionRulesOnly` startup warning (`Ignoring --allowedTools <tools>: permission rules are restricted to managed settings…`) | 48 §2.4 | emitted as an `informational` warning banner (headless baseline, SPEC 45 §9.1) | P | |
| `strictPluginOnlyCustomization` / `disableSideloadFlags` / `disableCommandPluginSources` refusals | 48 §5.2 | startup warnings → `informational` frames; some are debug-log only | P (banner) / D (log-only) | The two `--mcp-config` warnings (48 §5.1) are startup warnings; the per-agent `Skipping frontmatter MCP servers:` lines are debug-log only. |
| Safe-mode banner (`Safe mode: all customizations are disabled (CLAUDE.md, skills, plugins, hooks, MCP, agents, and more) · managed hooks and settings policy from your organization still apply…` + `<exit hint> to re-enable`) | 48 §4.1 | banner is TUI chrome; the *consequences* (missing skills/commands/tools) are visible in `system/init` | R | GUI must render its own safe-mode indicator; it knows the mode because it passed `--safe-mode` (or set `CLAUDE_CODE_SAFE_MODE`). The exit hint text depends on which of the two was used — `Ef()` in 48 §4. |
| The 17 per-surface safe-mode strings (skills picker, keybindings, themes, output styles, plugins panel, memory panel, auto-memory, `--agents`, statusline…) | 48 §4.1 table | almost all belong to TUI panels that do not exist headless; a few are debug-log lines | X / T | The `/statusline` refusal text is model-facing (`Tell the user: /statusline is unavailable in safe mode…`) so it does reach the wire. |
| `--restricted` behaviour table R1–R16 | 48 §4.2 | R2 (tools removed) is visible in `system/init.tools`; R3 (`bypassPermissions not supported in restricted mode`), R5 (`--restricted confines the file tools to the working directory.`), R7, R8, R9, R13, R14 are message strings | P (most) | R9 refuses the flag outright in cloud/remote-env/ssh sessions; R16 means every child process inherits `--restricted` and `CLAUDE_CODE_RESTRICTED=1`, which matters if afleet spawns nested claudes. R6 makes safety-check asks non-classifier-approvable, so `can_use_tool` arrives **without** an always-allow suggestion — the GUI must not offer one. |
| `--bare` / `CLAUDE_CODE_SIMPLE` | 48 §4.3 — strips the session to built-in behaviour, no hooks; hook-availability reason `hooks are disabled in this mode (--bare)` | argv flag; also drops both web tools from the tool set (19 §19.25.3) | R | GUI passes the flag; the consequence is visible in `system/init`. |
| `CLAUDE_CODE_SUPERVISED` | 48 §4.3 — marks the session as running under an external supervisor | environment variable | R | afleet is exactly this case; setting it is a one-line change. |
| `policyGate` on a command + an org policy that is off | typing the command yields the `Mp(policy, featureLabel, verb)` message (SPEC 28 §8 step 8b, §2502) | in a **non-interactive** session, `findPolicyDeniedCommand` still runs, and its output is emitted as a `/name args` echo followed by `<local-command-stdout>…</local-command-stdout>` (SPEC 28 §8c) | P | So policy-blocked command messages **do** reach a headless host, wrapped in the local-command-output envelope. The generic `cache_miss` variant is `Couldn't verify your organization's policy for <feature>…`. |
| Unknown/unavailable-command messages (`/<name> isn't available in this environment.`, `Unknown command: /x. Did you mean /y?`) | SPEC 28 §8b | same, via `local_command_output` | P | Note the cloud-specific overrides for `teleport`/`session`/`remote-control` (§9 below). |

## 7. Org policy, privacy, telemetry and residency (SPEC 48 §§3, 9, 10, 16)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| ZDR / HIPAA compliance-taint notices | HIPAA may be **named** in a denial sentence; ZDR never is, but both appear in `/status` and the taint banner; a HIPAA badge appears in the status line (48 §3.6) | denial sentences are model- or command-facing text (P); the `/status` line and the status-line badge are TUI chrome | P (sentences) / **D** (badge + `/status` line) | `/status` is not in the headless command list. Workaround: read `~/.claude/policy-limits.json` — it carries `compliance_taints` and `monitoring_notice` verbatim. |
| `monitoring_notice` org banner (text ≤ 500 chars, https-only URL) | rendered as a banner (48 §3.10) | **not** emitted as an `informational` frame | **D** | A GUI that does not read `policy-limits.json` will silently drop an org's mandated monitoring notice. Direct-read workaround as above. |
| Org denial sentences (`<Feature> is disabled by your organization's policy. Contact your organization admin to enable it.` / compliance variant / `Couldn't verify your organization's policy for <feature>…` / `/x is available for your organization but wasn't when this session started. Restart Claude Code to use it.`) | 48 §3.7 | reach the wire wherever they gate a command (`local_command_output`) or a tool (tool_result) | P | The `Restart Claude Code to use it.` variant is worth special-casing in a GUI: it means relaunch, not retry. |
| `analytics_disabled` | not user-visible in the TUI | on **both** the `initialize` control response and `system/init` (SPEC 45 §2206, §1138). Live init dump confirms `analytics_disabled: false` | P | |
| `product_feedback_disabled` | not user-visible | on `system/init` only (SPEC 45 §1138/§1207); **absent** from the `initialize` response in the live dump for an unrestricted account | P | A GUI should hide its feedback affordance when this is true. It is driven by `allow_product_feedback`, which is fail-closed (denied when no policy document is cached and the session is policy-eligible). |
| `feedback_survey_config` on `initialize` | drives the in-session survey | present on the `initialize` response (SPEC 45 §2206) | P → **exceeds** | GUI can render a nicer survey. |
| `/privacy-settings` (Data privacy toggle, `Help improve our AI models`, the Consumer-Terms consent dialog) | 48 §16.1–§16.2 — `local-jsx`, Pro/Max only | absent from the headless command list | X | Headless mode prints the consent notice to stderr instead, and after the deadline exits with status 1 (48 §16.2). afleet must surface that stderr text or the user gets an unexplained exit. The choice itself is a server-side account field (`grove_enabled`), so a GUI could re-implement via `PATCH /api/oauth/account/settings`. |
| Data-residency / essential-traffic withheld-feature messages (Files API, cloud sessions, remote env, Remote Control, Projects, Design, Channels, cross-machine transfer, `/ultrareview`, `--enable-live-preview`, `/feedback`) | 48 §9.3 | each surfaces where its feature is invoked — mostly tool results or command output | P | |
| `DISABLE_TELEMETRY` / `DO_NOT_TRACK` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | 48 §9.2 — environment-only, no settings key | environment variables the GUI sets | R | |
| Secret redaction of `raw_command` / `action_description` on the SDK permission request | 48 §10.2 — redaction is applied **before** the request leaves the process | so the GUI receives already-redacted values | P | Consequence for a GUI: do not expect the literal command text in a permission prompt to be byte-identical to what will run. |
| Transcripts written **unredacted**; redaction only on export | 48 §10.2 | same on both sides | P | If afleet ships its own transcript export, it must apply the 58-rule scanner itself. |
| `claude gateway` subcommand (self-hosted Claude Code Gateway, CRI admission wall) | 48 §8 — a separate top-level command, not a session surface | a separate process invocation; nothing on the session protocol | T | Listed for completeness. Its boot warnings and config refusals are stdout/stderr of that process. |

## 8. Billing, credits, rate limits and upsells (SPEC 48 §§12–15)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Limit-reached sentences (`You've hit your session limit · resets <t>`, `You're out of usage credits`, `Your org is out of usage · add funds to continue`, the 8-line rejected tree) | 48 §12.6 | surfaced as `rate_limit_event` frames and `result` `error_*` subtypes (headless baseline, SPEC 45 §9.1) | P | The exact sentence set is in §12.6; a GUI should reuse it rather than invent copy. |
| Approaching-limit warnings (`You've used <n>% of your <limit> · resets <t>`) and their tier-dependent call-to-action suffixes | 48 §12.2, §12.6 | `rate_limit_event` | P | The client-side pace thresholds (90/72 for five hours; 75/60, 50/35, 25/15 for seven days) are computed inside the CLI, so the GUI does not need to. |
| `/usage-credits` and `/extra-usage` | 48 §16 — `local-jsx` **and** `local` records | present in the live headless command list (the `local` record) | P | The 15-state purchase dialog itself is `local-jsx` and unreachable; headless gets the `local` variant, which for a non-billing team member returns `Requesting usage credits notifies your organization admins. To review and send the request, run /usage-credits in an interactive Claude Code session.` (48 §12.8). |
| `/upgrade` | `local-jsx`, hidden at enterprise (48 §16) | absent from the headless list | X | Opens `https://claude.ai/upgrade/max?...utm_campaign=upgrade_command`; a GUI can open it natively. |
| `/rate-limit-options` menu (`What do you want to do?`, 8 entries incl. `Wait here, then continue automatically at <t>`) | 48 §13.11 — `local-jsx`, hidden | absent | X | **This is the entry point to auto-continue.** Without it a headless host cannot arm a wait explicitly, and only the auto-armed path (subject to the 24-hour horizon and the 2-re-arm cap) is available. |
| Auto-continue state machine (armed → fired / stale / cancelled) and its 19 cancel reasons | 48 §13 | the continuation is injected as a **meta** prompt at priority `later` with `origin: {kind:"auto-continuation"}` and slash commands disabled (48 §13.8) | P (the continuation) / **D** (the armed/stale state) | The GUI sees the resumed turn but has no frame telling it a wait is armed, when it will fire, or that it went `stale` and needs an Enter press. The four teardown sentences (`Automatic continue stopped · …`, `Automatic continue did not run · …`, the five handoff variants) are TUI-rendered. Workaround: none on the wire; the setting `autoContinueAtUsageLimit` is readable via `get_settings`. |
| Grace-window wrap-up meta messages (`[Usage limit reached — grace window active. Wrap up: …]`) | 48 §13.10 | injected into the conversation, so visible as a user/meta frame | P | |
| Six C4E upsell stub commands (`ultraplan`, `ultrareview`, `teleport`/`tp`, `remote-control`/`rc`, `schedule`/`routines`, `autofix-pr`) | 48 §15.2 — `type: "local"`, `isHidden: true`, `supportsNonInteractive: **false**`; each returns `/<name> is available with Claude for Enterprise — ask your admin about migrating from API-key access.` | `supportsNonInteractive: false` means a `local` command is refused headless (SPEC 28 §22) | X | Audience is first-party API-key users not signed in with a subscription. A GUI showing these commands in a palette would get a refusal, not the upsell text. |
| Three C4E startup tips and the org-admin migration notice (`Get more out of Claude Code on Claude Enterprise`) | 48 §15.2 | startup tips are TUI chrome | D / **T** | Not worth rebuilding; a GUI's own onboarding supersedes them. |
| Pro-trial start screen and `/pro-trial-expired` | 48 §15.3 | `local-jsx`, absent headless | X | The `Trial: <n> days left` badge is status-line chrome; `footer_indicator` on `initialize` is the general-purpose replacement (not verified to carry this). |

## 9. Cloud sessions: creation, attach and the checklists (SPEC 37 §§37.2, 37.4–37.8, 37.11)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `--cloud "<description>"` creating a cloud session | 37 §37.6, §37.11.1 | supported headless **only** through `runHeadlessCloudCreate`, which requires the `headlessCloud` gate: `--cloud` present, `--environment`/`--project` absent, not `--print`, not `--init-only`, non-interactive, no `--sdk-url`, `--input-format` and `--output-format` both `stream-json`, and the `tengu_violin_wood` gate on (37 §37.12.1) | R | afleet's exact invocation satisfies every argv condition **except** that it passes `-p` (`--print`). Adding `--cloud` alongside `-p` therefore falls through to the interactive create path, not the headless cloud client. This is a launch-flag detail worth verifying against 2.1.259 before building on it. |
| `--cloud <session_id>` attaching | 37 §37.11 | `runHeadlessCloudAttach`; also gated on `tengu_remote_backend`, else `Error: Attaching to an existing cloud session is not enabled for your account.` | R | |
| `--environment <id>` / `--pool` | 37 §37.5, §37.11.1 | **incompatible with the headless cloud client** (the gate requires it absent); refused with `--cloud <description>` plus piped stdin or a positional prompt | X (in the headless-cloud mode) | To target an environment the GUI must use the interactive/`-p` create path instead. |
| `--teleport [session]` | 37 §37.10 | in print mode it takes a dedicated branch requiring an explicit session id and a clean git tree (37 §37.10.7); the four-phase spinner is replaced by nothing | R | The seeded transcript arrives as replayed messages; `Session resumed` / `Session resumed without branch: <error>` and the `bridge`-origin warning are real messages (37 §37.10.5) so they reach the wire. |
| The create checklist (`Setting up remote session…`, steps `Checking this checkout` → `Packaging this repository` → `Uploading this repository` → `Creating cloud session`, `· <size>`, elapsed `(12s)` after 5 s, footer `Typing is paused until the prompt opens`) | 37 §37.8.1 | driven by an in-process `onProgress` union (`checking`/`bundling`/`bundled`/`bundle_failed`/`creating`/`request_sent`/`created`) that never leaves the process | **D** | A GUI gets no create progress at all — potentially a 30+ second silence while a repo is bundled and uploaded. Workaround: none on the wire; a protocol addition would be needed. |
| Cancel semantics (first Ctrl-C aborts, second forces; `Cancelled after the create request was sent, so a cloud session may still have been created`, exit 130) | 37 §37.8.1 | `interrupt` control request during create is not modelled | D | |
| The remote startup checklist (`Setting up a cloud container` → `Cloning repository` → `Running setup script` → `Started Claude Code`, then `Remote session ready in 42s`) | 37 §37.8.2 — fed by server `system` events carrying `extra.step_id`/`extra.step_status`, with a 60 s / 5 s staleness guard | the same events reach the headless client, which uses them as a bootstrap checklist internally (37 §37.12.7) | R | The underlying `env_manager_log` frames exist; the GUI must reimplement the label table (`HZ`) and the staleness guard. |
| Attach banner `Attached to cloud session · code here or at <url>` / `Cloud session active · code here or at <url>` | 37 §37.2.3, §37.11.4 — emitted either as a `cloud_session_status` transcript record or an info notice | reaches the wire as a system record / `informational` frame | P | |
| Partial-history seed notice `Showing recent messages · full history at <url>` | 37 §37.11.5 | on the wire as a notice | P | The prefetch truncates the seed at the earliest unanswered `can_use_tool`/`request_user_dialog` so a newly attached client never inherits an unanswerable prompt — good news for a GUI. |
| Archived-session refusals (`Cloud session <id> is archived and cannot accept new messages.` + view URL) | 37 §37.11.3, §37.12.5 | headless variant `Error: cloud session <id> is archived and cannot accept new messages. View it at <url>`, printed and exit 1 | R | |
| `cloud_session` snapshot (`{id, view_url, device, directory_sync, not_applied[], client_version}`) | not shown in the TUI at all | exposed by the headless cloud client (37 §37.12.6) | P → **exceeds** | Machine-readable device-binding and directory-sync state that the terminal never surfaces. |
| Option-reconciliation notices (`Not applied to this cloud session…`, `An existing cloud session keeps the configuration it was created with…`, `Host options not applied…`) | 37 §37.12.3 | emitted as `warning`/`notice` levels **and** attached to `cloud_session.not_applied` (≤ 40 entries) | P | The `initialize`-key classification table is in 37 §37.12.3: `systemPrompt`, `agents`, `skills`, `forwardSubagentText`, `perTaskStopAffordance`, `webSearchIsolationExemptMcpServers` etc. are all `lost` in a cloud session — a GUI must expect its `initialize` to be partly ignored. |
| Worker-lifecycle notices (`Still waiting for the cloud session to start…`, `Cloud session may be unresponsive. Attempting to reconnect…`, `Lost the connection to the cloud session — reconnecting…`, `Reconnected.`, `The cloud session failed to start.`) | 37 §37.12.7 | these **are** the headless client's own notices — emitted to the host | P | |
| Directory-sync consent (`cloud_sync_consent` dialog: `sync` / `device_tools` / `not_now`) | 37 §37.12.4 step 2, §37.18.2 | headless dialog default is `"not_now"` (cross-cutting note) | X | So a headless cloud session **never arms directory sync** unless the host implements the dialog — and the host cannot, because the dispatcher does not forward the kind. The three "why file sync is off" explanations (37 §37.12.5) are what the user gets instead. |
| Seed-teardown warnings at exit (`File sync setup was interrupted: …`) | 37 §37.12.8 | emitted as warning notices | P | |
| `--restricted` + cloud (`Error: --restricted cannot be enforced in a cloud, remote-environment or ssh session…`, `Cloud sessions cannot be created from a --restricted session: they would not enforce it.`) | 37 §37.4.3–§37.4.4 | same refusals, on stderr / as command output | R | |
| Cloud eligibility refusals (`Please run /login and sign in with your Claude.ai account (not Console).`, `Cloud agents require a git repository (checked: <cwd>)…`, `Cloud agents require a GitHub remote…`, `The Claude GitHub app must be installed on this repository first.`, `Cloud sessions are disabled by your organization's policy…`) | 37 §37.4.1–§37.4.2 | same strings, reached through whichever surface invoked them | P | |

## 10. The thin client driving a cloud session — what it refuses (SPEC 37 §§37.12.2, 37.22.3)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Pre-run refusals of the headless cloud client | n/a (TUI takes a different path) | six codes: `org_pin`, `unavailable`, `no_stream_input` (`Error: headless --cloud reads the SDK host messages from stdin as stream-json; stdin is a terminal here.`), `rejected_tool_restriction`, `rejected_unsupported`, `rejected_argv` (37 §37.12.2) | P | The four argv-policy texts are verbatim in §37.12.2: bypass-permissions, in-process SDK MCP servers, tool restrictions, and unsupported options are all **refused rather than silently dropped**. |
| Non-fatal notices | n/a | logged always, written to stderr **only when stderr is a TTY** (37 §37.12.2 `We()`) | **D** | Under afleet, stderr is a pipe, so `<flag> applies to this machine's client only…` and `MCP server[s] from --mcp-config ignored…` are **invisible**. Workaround: allocate a pty for stderr, or accept the loss and infer from `cloud_session.not_applied`. |
| Control requests the CLI **rejects** while driving a cloud session | n/a | route table at 37 §37.22.3. `reject` covers everything not in the three allowed routes | P | Verbatim rejection texts: `bypassPermissions is not available in a cloud-hosted session`; `update_settings is not available in a cloud-hosted session yet`; `file rewinding is not available in a cloud-hosted session: the cloud agent keeps no file checkpoints`; `MCP server changes are not available in a cloud-hosted session yet; …`; `<set_cwd\|add_directory\|register_repo_root> names a path on this machine; the agent's files are in the cloud container`; `<remote_control\|channel_enable\|ultrareview_launch\|claude_authenticate\|claude_oauth_callback\|claude_oauth_wait_for_completion\|mcp_authenticate\|mcp_clear_auth\|mcp_oauth_callback_url\|set_color> is not available while this process drives a cloud-hosted session`; `SDK MCP servers are not available in a cloud-hosted session`; `poll_event is not available in a cloud-hosted session yet`; `stage_file is sent to a cloud agent by the service, not by a host`; `<register_device_hooks\|upload_device_hook_template\|remote_tools_announce> is sent to a cloud agent by the attached client, not by a host`; `<can_use_tool\|hook_callback\|elicitation\|request_user_dialog\|oauth_token_refresh\|host_auth_token_refresh\|remote_tool_call\|remote_plumbing_call\|remote_tools_probe\|remote_control_work_secret> is agent-originated and cannot be sent by a host`; `<subtype> is not supported in a cloud-hosted session`; `a request without a string subtype is not supported in a cloud-hosted session`. |
| Control requests **forwarded** to the cloud worker | n/a | `set_permission_mode`, `set_model`, `set_max_thinking_tokens`, `mcp_toggle`, `mcp_reconnect`, `reload_plugins`, `reload_skills`, `set_mcp_permission_mode_override`, `apply_flag_settings` (only `model`, `advisorModel`, `effortLevel`, `ultracode`, `fastMode`, `viewMode`, `alwaysThinkingEnabled`), `rewind_conversation`, `seed_read_state` — these hold later sends; plus a non-holding set incl. `get_context_usage`, `get_session_cost`, `mcp_status`, `list_models`, `get_usage`, `get_binary_version`, `file_suggestions`, `read_file`, `get_workspace_diff`, `get_plan`, `stop_task`, `background_tasks`, `get_settings`, `submit_feedback`, `message_rated`, `generate_session_title`, `side_question`, `mcp_call`, `rename_session` (37 §37.22.3) | P | `initialize`, `interrupt`, `end_session`, `cancel_async_message` stay local. |
| The cloud-hosted `initialize` reply | n/a | advertises **nothing**: `{commands: [], agents: [], output_style: "default", available_output_styles: [], models: [], account, pid}` (37 §37.22.3) | **D** | A GUI driving a cloud session gets an empty command palette, empty agent list and empty model list. Workaround: forward `list_models` (which *is* forwarded) and hard-code the command palette, or read the local session's `initialize` before switching to cloud. |
| Opening requests on a headless attach (`--permission-mode plan`/`dontAsk` are **required**) | n/a | `Error: the cloud session did not accept --permission-mode plan, so this attach was stopped rather than continue without it.` / warning `The cloud session did not accept <mode>; it keeps its own.` (37 §37.12.5) | P | |
| Permission-mode divergence notice (`The cloud session did not apply the <mode> permission mode requested when it was created; it is in <mode> mode.`) | n/a | emitted on the first `system/init` | P | |
| `session_notice` / `queued_notification` inbound frames | TUI receives them from the cloud service on the Remote-Control transport (SPEC 50 §50.15, §50.17) | both are accepted stdin frame types but are marked `@internal Backend→CLI` (SPEC 45 §15.4) and produced by the cloud service, not an SDK host. `queued_notification` outside remote mode is dropped with `ccr_queued_notifications / not_remote`; `session_notice` is gated on `tengu_polished_lagoon` and the `session_notices` capability | X (for a host to send) / P (to observe the effect) | A GUI should **not** synthesise them. Their user-visible effect (a `<task-notification>` nudge drained by `ReadNotifications`, and a reserved `session-notice` poll event) arrives as ordinary conversation content. |
| `stage_file` control request | n/a — service→worker | rejected outright when the host drives a cloud session; no `subtype: "stage_file"` literal exists in the bundle, and SPEC 45's open questions say the producer is an out-of-tree host | X | Do not attempt to send it. |
| `poll_event` control request | n/a | request `{subtype:"poll_event", kind, event, wake?, authority?, sender_id?, sender_text?}`; requires poll-event delivery enabled for the session and **permission mode `auto`**, else `poll event rejected: poll events require permission mode "auto" (got "<mode>") …` [`cli.pretty.js:177398-177412`]; rejected entirely in a cloud-hosted session | P (locally) / X (cloud) | Usable by a GUI only in a local session running with `--permission-mode auto`. |

## 11. Remote tasks and the cloud permission relay (SPEC 37 §37.13)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Remote-task registry row (`remote_agent`, status, `reviewProgress`, `terminal.summary`) | rendered as a task row in the task list | reachable via the `background_tasks` control request and `task_started` / `task_updated` / `task_progress` / `task_notification` frames | P | |
| Permission relay for a supervised cloud session | the local session answers the cloud session's prompts on the user's behalf when it can prove equivalence (37 §37.13.3) | **disabled headless**: the first gate is `if (r.toolUseContext.options.isNonInteractiveSession === true) return "non_interactive_session"` | X | Consequence: in a headless host, a cloud sub-session's permission prompts are never relayed to the GUI; they must be answered in the browser. |
| Blocked-on-input failure (`the cloud session is waiting on input (a question, or a permission prompt this session couldn't answer for it). Answer it at <url>, or relaunch with an agent whose permission mode doesn't prompt.`) | 37 §37.13.4 | delivered as a task notification → on the wire | P | Because the relay is off headless, this path fires after 3 consecutive `requires_action` polls. |
| Completion / failure notifications (`Cloud review completed` + findings, `Cloud review failed: <reason>`) with the seven-entry failure vocabulary | 37 §37.13.5–§37.13.6 | `task_notification` frames | P | Includes the prompt-injection guard sentence about relayed error output. |

## 12. Cloud commands: `/ultrareview`, `/ultraplan`, `/autofix-pr`, `/schedule`, `/teleport`, `/remote-env`, `/cloud-plugins`, `/passes` (SPEC 37 §§37.5.5, 37.9, 37.14–37.16, 37.21.4, 37.25)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/ultrareview` — the interactive dialog (`Run ultrareview in the cloud?`, `<duration> · Est. cost <cost> USD`, `Run and only show findings here` / `Cancel` / `Run and post the findings to the PR as me`) | 37 §37.14.10 (`local-jsx` record) | absent | X | Note the option order: **Cancel sits between** the two run options. |
| `/ultrareview` non-interactive | a second command record `type: "local"`, `supportsNonInteractive: true`, `isEnabled: () => Oe() && bC()` (37 §37.14.1) | **present** in the live headless command list | P | This is the one cloud command a GUI gets for free. Its output is the launch message block (37 §37.14.9). |
| `ultrareview_launch` control request | n/a | request `{subtype:"ultrareview_launch", args?: string (default ""), confirm?: boolean (default false)}`; handler at [`cli.pretty.js:178352-178363`] | P | **Response, recovered from the handler's callee [`cli.pretty.js:827770-827812`]:** one of `{status:"error", message, reason?}` · `{status:"blocked", message, actionUrl?}` · `{status:"needs-confirm", body, billingNote}` · `{status:"launched", sessionId, sessionUrl, taskId, title, message, billingNote, postReviewTo?:{repo,prNumber}, postIgnored?:true}`. The handler also synthesises transcript entries via `ey()` [`cli.pretty.js:174481`] and **enqueues them as `user` frames with `isReplay: true`**, so the host sees `<command-name>/ultrareview <args></command-name>` plus either `<local-command-stdout>` or `<local-command-stderr>Ultrareview did not launch: <message>[\nMore: <actionUrl>]</local-command-stderr>`. On `needs-confirm` no transcript entries are produced — the host must re-send with `confirm: true`. The SDK path passes no `postReview`/`applyFixes`/`invocation`, so `--post` and `--fix` are unreachable through it. |
| `ultrareview_launch` inside a cloud session | n/a | rejected: `ultrareview_launch is not available while this process drives a cloud-hosted session` (37 §37.14.13) | X | |
| The ultrareview task row (`ultrareview · <stage>`, `<F> found · <V> verified · <R> refuted`, 80 ms animation) | 37 §37.14.11 | progress is parsed from `hook_progress`/`hook_response` stdout by the local poller and stored on the task row; `task_progress` frames carry it | R | The GUI must reimplement the `a8()` stage-label logic; the numbers are on the wire. |
| Stopping ultrareview (`Stop ultrareview?` dialog, `Ultrareview stopped.` + session URL) | 37 §37.14.11 | `stop_task` control request exists; the confirmation dialog does not | R | GUI renders its own confirm and calls `stop_task`. |
| `claude ultrareview [target]` CLI subcommand (`--json`, `--timeout`, `--post`, `--no-post`; findings formatter with 🔴/🟡/🟣; three SIGINT regimes; progress on stderr, findings on stdout) | 37 §37.14.12 | a separate process invocation, not a session surface | T | A GUI can shell out to it and parse `--json`. Note stdout/stderr discipline is already machine-friendly. |
| `/code-review ultra` redirect and its five local-fallback preambles | 37 §37.14.3 | `/code-review` is in the live headless command list; the subcommand fold happens the same way | P | The preambles are model-facing text on the wire. |
| Ultrareview preconditions (18 refusal reasons — `not_git_repo`, `pr_diff_too_large`, `github_not_connected`, `no_merge_base`, …) | 37 §37.14.6 | returned as command output / `status:"error"` on the control request | P | |
| `/ultraplan` cloud plumbing — the `ultraplan_launch` dialog (`run` / `cancel` / `cancelled`) | 37 §37.16.1 | dialog default `"cancelled"` in headless | X | `/ultraplan` is also absent from the headless command list. The approval poller's notifications (`The cloud ultraplan session produced a plan and is waiting for approval. Tell the user to open <url>…`) would reach the wire if a launch ever happened. |
| `/autofix-pr` | 37 §37.15 — `local-jsx`, interactive only (`!Oe()`) | absent | X | Behavioural note for anyone rebuilding it: `/autofix-pr stop` and `/autofix-pr off` are parsed and then **ignored** — the token becomes the new session's prompt (37 §37.15.2). Its progress steps, PR-detection refusals and success block are all in §37.15.3–§37.15.7. |
| `/schedule` (routines) | 37 §37.15a — a bundled skill rendering one long model prompt, plus the deferred `RemoteTrigger` tool | **present** in the live headless command list | P | The whole surface is model-driven, so it works headless unchanged. |
| `/teleport` menu (`Continue this session in the cloud` / `Resume a session from cloud`, `Moving your session…`, `Session now in the cloud: <url>` + one of three reconnect lines) | 37 §37.9 | absent from the headless command list | X | Also structurally unavailable: option 1 requires an active Remote Control bridge (`This session isn't connected to Remote Control. Run /remote-control first…`), and `/remote-control` is likewise `local-jsx`. |
| `/teleport` preconditions (restricted / no bridge / no auth / no git / dirty / unpushed / env lookup / no environment) | 37 §37.9.2 | none | X | |
| `--teleport` session picker (`Select a session to resume`, `Updated`/`Origin`/`Session Title` columns, Ctrl+R retry, four error-class hints) | 37 §37.10.6 | print-mode `--teleport` **requires** an explicit id (`No session ID provided for teleport`) | R | The list is one authenticated `GET /v1/code/sessions`; a GUI can render a far better picker. **Exceeds.** |
| `--teleport` repository-mismatch dialogs (`TeleportHostUnverifiedDialog`, `TeleportRepoMismatchDialog` seeded from `githubRepoPaths`) | 37 §37.10.2 | not raised; print mode fails with `You must run claude --teleport <id> from a checkout of <repo>.` | R | GUI can offer the same "pick a checkout" affordance from `~/.claude.json` `githubRepoPaths`. |
| Commands replaced *inside* a cloud session (`/teleport`, `/session`, `/remote-control`) | 37 §37.4.5 — three explanatory texts | in a **non-interactive** session these are exactly the strings `findPolicyDeniedCommand`'s sibling branch emits (SPEC 28 §8b), wrapped in `<local-command-stdout>` | P | So a GUI forwarding `/teleport` inside a cloud session does get the sentence `/teleport pulls a cloud session into a terminal on your own machine, so it can't run from inside this session. To continue this session locally, run claude --teleport <id> from a checkout of this repository. …`. |
| `/remote-env` picker (`Select remote environment`, `Currently using: <name>`, `— Self-hosted environments —`, `<name> (<id>) · N runners`) | 37 §37.5.5 | absent | X | The setting it writes is `remote.defaultEnvironmentId` in **user settings** (and it clears the local-settings value). `update_settings` only reaches `localSettings`, so a GUI must edit `~/.claude/settings.json` directly — and note the trust rule: a `ccpool_` value is honoured only from policy/flag/user settings (37 §37.5.2). |
| `/cloud-plugins` consent | 37 §37.21.4 — `local-jsx` | absent | X | The model-facing nudge `Your plugins are not used in cloud sessions from this machine yet: run /cloud-plugins in claude on this machine to decide.` still reaches the wire. Consent lives at `<config-home>/state/cloud-plugins-consent.json` (mode 0600) — a GUI can write it. |
| `/passes` guest passes | 37 §37.25 — `local-jsx`, `requires: {ink: true}`, hidden on a cold cache | absent | X | Purely a referral surface; a GUI can call the two `referral/*` endpoints itself. |
| `--bg` background sessions and the `attach`/`logs`/`stop`/`respawn`/`rm` verbs | 37 §37.17 | separate process invocations; `claude agents --json` is the machine-readable listing and does not require a TTY | T / R | Refusals worth honouring: `--bg and --print conflict…`, `--bg and --cloud are different backends…`, `--bg and --environment are different backends…`. |

---

## Top gaps in this area

Ranked by how much they cost the product.

1. **WebSearch live progress is not on the wire (D).** The TUI shows `Searching: <query>` and
   `Found <n> results for "<query>"` from `emitProgress`; the headless baseline forwards
   `tool_progress` only for Bash/PowerShell. A GUI can show nothing between the tool call and the
   result, which for a multi-query search is many seconds of dead air. Needs a protocol addition.
   (19 §19.23.4, §19.27.2)

2. **Cloud-session create progress is invisible (D).** The create checklist's seven `onProgress`
   kinds never leave the process, so `--cloud` looks frozen while a repository is bundled and
   uploaded. (37 §37.6.3, §37.8.1)

3. **Every dialog kind except three silently resolves to its default headless (X).** This is one
   mechanism, not one feature: it removes the Chrome install upsell, the computer-use app-grant and
   TCC panels, directory-sync consent, the managed-settings approval, `ultraplan_launch`,
   `sandbox_network_access`, `peer_inbound_approval` and `auto_mode_setup_review` in a single
   stroke, and declaring the kinds in `initialize.supportedDialogKinds` does not help.
   (`chunk-2rhzyjym.js:174430-174444`)

4. **Computer use cannot be turned on headlessly at all (X).** It is wired only for interactive
   sessions and there is no `--computer-use` flag analogous to `--chrome`. Even if it were wired,
   `request_access` resolves to an empty grant. The only path is for afleet to host
   `claude --computer-use-mcp` itself and inject it via `--mcp-config`. (46 §46.21)

5. **`WebFetch` and `WebSearch` structured outputs are truncated at the wire (D).** Only
   `output.result` survives `mapToolResultToToolResultBlockParam`, so `bytes`, `code`, `codeText`,
   `durationMs`, `searchCount` and `durationSeconds` are lost. The TUI's `Received 12.3KB (200 OK)`
   and `Did 3 searches in 4s` lines cannot be reproduced. (19 §19.3, §19.24.2)

6. **The managed-settings approval gate is waived in headless mode (X, security-relevant).**
   `deferred_non_interactive` applies a dangerous remote payload with no prompt. A GUI that wants
   parity must read `remote-settings.json` and `remote-settings-consent.json` and gate the launch
   itself. (48 §2.9.3)

7. **A GUI driving a cloud session gets an empty `initialize` reply (D).** No commands, no agents,
   no models. The command palette and model picker must be sourced elsewhere
   (`list_models` is forwarded; commands are not). (37 §37.22.3)

8. **Non-fatal headless-cloud notices go to stderr only when stderr is a TTY (D).** Under a pipe,
   "your `--mcp-config` servers were ignored" is silent. (37 §37.12.2)

9. **The org `monitoring_notice` banner never reaches the wire (D).** An organisation's mandated
   monitoring text is simply dropped. Workaround: read `~/.claude/policy-limits.json`. (48 §3.10)

10. **Auto-continue state is invisible and `/rate-limit-options` is unreachable (D + X).** The GUI
    cannot tell the user a wait is armed, when it fires, or that it went `stale` and needs an
    Enter; and it cannot let the user arm one explicitly. (48 §13, §13.11)

11. **The cloud permission relay is disabled in non-interactive sessions (X).** A supervised cloud
    sub-session's prompts can never be answered from the GUI — only in the browser — and after
    three `requires_action` polls the task is failed. (37 §37.13.3)

12. **Directory sync never arms in a headless cloud session (X).** `cloud_sync_consent` defaults to
    `not_now`, so the cloud agent starts without the user's local changes. (37 §37.12.4, §37.18.2)

13. **Screenshots are a clear win for the GUI (exceeds).** The TUI structurally cannot draw images
    and prints `Action completed` / `Captured`; the image blocks are on the wire in both the Chrome
    and computer-use families. Same for WebSearch citations, which the TUI reduces to a count.
    (46 §46.28, 19 §19.24.1)

14. **`--chrome` must be passed explicitly (R).** Without it (or `CLAUDE_CODE_ENABLE_CFC=1`) a
    non-interactive session disables Claude in Chrome at step 5 of the eligibility predicate, so no
    browser tools appear at all. (46 §46.14.1)

15. **Six C4E upsell commands and every `local-jsx` cloud/enterprise command are simply absent from
    `initialize.commands` (X).** Confirmed against the live 2.1.259 handshake. A GUI palette built
    from that list is already correct; a palette built from documentation is not.

## Unverified

* **The `headlessCloud` gate vs. afleet's actual argv.** `TFn` requires `!print`, and afleet passes
  `-p`. I read the gate (37 §37.12.1) but did not run a `-p --cloud` invocation to confirm which
  branch 2.1.259 takes. Everything in §10 assumes the headless-cloud client is entered; if `-p`
  routes to the interactive create path instead, those rows change class.
* **Whether `chrome_install_upsell`/`computer_use_approval` would be forwarded on a non-`print`
  stream-json session.** I read one dispatcher (`K_` in `chunk-2rhzyjym.js`, the print/headless
  handler). There may be a second dispatcher on another entry path that forwards more kinds; I did
  not enumerate every construction site of the dialog-handler callback.
* **`footer_indicator` contents.** SPEC 45 lists it on the `initialize` response and the live dump
  did not include it for this account, so I could not confirm whether it carries the HIPAA badge,
  the trial badge, or something else.
* **`tengu_malort_pedway.enabled` in production.** Every computer-use row is conditional on a
  server-side gate whose shipped value the bundle does not contain (46 Open questions).
* **`tool_progress` for WebSearch.** I inferred its absence from the headless baseline's statement
  that `tool_progress` is Bash/PowerShell-only; I did not trace `emitProgress` to the frame writer
  to confirm WebSearch's progress events are dropped rather than re-labelled.
* **The `stage_file` request shape.** SPEC 45's own open questions state no `subtype: "stage_file"`
  literal exists in the bundle; I read the handler at `cli.pretty.js:177612` but the field set is
  only inferable from its consumer.
* **`/session` as a command record.** I covered it only through the cloud-session refusal map
  (37 §37.4.5); its own definition lives outside my four chapters.
* **Chapter 46 §46.10 (tool schemas), §46.10.2 (native host process) and chapter 37 §§37.7,
  37.18–37.24 (git bundle internals, directory-sync wire, device binding, self-hosted runners, the
  agent proxy) were read selectively rather than line-by-line**, on the brief's instruction to skip
  transport internals. If a user-visible affordance hides in those sections I may have missed it.
