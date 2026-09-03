<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# TUI-vs-headless UX gap inventory — notifications, channels, remote control, teams/fleet, daemon

Area: `50-36-39-38-notifications-remote-teams-daemon`.
Chapters: SPEC 50 (notifications and channels), 36 (remote control and bridge), 39 (teams and
fleet), 38 (daemon and messaging). Classification letters per BRIEF.md: **P** parity via
protocol, **R** rebuild, **D** data gap, **X** unreachable, **T** terminal-specific.

Live ground truth captured on this machine (2.1.259) is cited as **[live]** and described in
"Unverified / live probes" at the end.

---

## 50.1 The outbound notification model (rails, kinds, dispatcher)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Five outbound rails (O1 terminal/OS, O2 `Notification` hook, O3 mobile push, O4 in-terminal bar, O5 Slack) | §50.1 rail table | O2 fires headless (hook executor is not REPL-bound); O3 fires when a bridge is attached; O1 is dropped (no `onOSNotification` handler in `-p`, §50.3.2); O4 has no widget; O5 never carries harness traffic (§50.19.1) | mixed | Only O2/O3 survive headless. afleet must own O1 and O4 itself. |
| `notificationType` vocabulary — 14 values in `kar` plus `elicitation_complete`, `elicitation_response` | §50.2, §50.2.1; matcher domain is 16 values [`chunk-qmc0yc6t.js:646257`] | Not on the wire as a frame. Reachable only by registering a `Notification` hook and reading `hook_response` frames with `--include-hook-events` | R | Rebuild: install a `Notification` hook (matcher = `notification_type`) whose command echoes the payload; the hook's `hook_started`/`hook_response` frames then carry `message`, `title`, `notification_type` to the GUI. This is the only supported way to see the whole kind vocabulary headless. |
| The dispatcher `Ov` — reads `preferredNotifChannel`, **awaits** the hook, then emits on the terminal | §50.3.1 | Steps 1–2 run headless; step 3 (terminal emission) resolves to nothing useful; the hook result is discarded either way | R | A GUI reimplements step 3 as a native macOS notification. It can exceed the TUI: no OSC-escape guessing, no `auto`→`no_method_available` dead end (§50.3.3). |
| `os_notification` internal message (computer-use enter/exit, `PushNotification` local half) | §50.3.2 | **Dropped before the wire** — it is in the 45.9.2 `Cu` drop list and `onOSNotification` is unset without a REPL [`chunk-1kg58a1a.js:153367`] | D | Workaround: the same three events are observable indirectly — computer-use via tool frames, `PushNotification` via its own `tool_use`/`tool_result` pair (below). No frame carries the notification text as such. |
| Channel resolution (`auto` → iterm2 / kitty / ghostty / terminal_bell / `no_method_available`), attacher-terminal override | §50.3.3, §50.3.1 step 5 | none | T | Superseded by the GUI's own notification centre. |
| `preferredNotifChannel` values and their short labels (`bell`, `iterm2+bell`, `none`) | §50.3.3, §50.6.1 | Readable via `get_settings`; writable via `update_settings` (localSettings only) | T | Terminal-only meaning; a GUI should hide the row rather than render it. |
| The `Notification` hook contract: matcher subject `notification_type`, 600 000 ms default timeout, result discarded, cannot suppress | §50.4.1 | Identical headless; hook lifecycle frames arrive with `--include-hook-events` (45.9.1) | P | afleet already passes `--include-hook-events`, so it gets `hook_started`/`hook_progress`/`hook_response` for free. |
| Second hook entry path: SDK/bridge permission relay arms a 6 000 ms timer and fires the hook only (no terminal emission) | §50.4.2 | This is *the* headless path — it exists precisely because there is no REPL | P | Disabled by `CLAUDE_CODE_DISABLE_PERMISSION_PROMPT_NOTIFY_HOOKS`. Gives afleet a free "user has been sitting on a permission prompt for 6 s" signal without polling. |
| The 6 s idle/permission debounce React hook `hUe` | §50.4.3 | React-only; no headless twin | R | afleet must debounce its own "prompt has been open N seconds" nudge. |
| `idle_prompt` after `messageIdleNotifThresholdMs` (default 60 000 ms, read only from `~/.claude.json`, no settings-schema entry, no UI) | §50.5.1 | The timer class is REPL-constructed; headless never arms it. `inputNeededNotifEnabled` does not gate it | R | Rebuild from `result` + `session_state_changed(idle)` frames. Read the threshold from `~/.claude.json` on disk if you want parity; there is no control request for it. |
| Background-agent band notifications (`agent_needs_input`, `agent_completed`), `idle-seed` suppression, 120-char `needs` truncation | §50.5, §39.32.7 | The band classifier is FleetView-side; headless emits `task_notification`/`task_started`/`task_updated`/`task_progress` frames instead | R | afleet reconstructs bands from task frames. It can exceed the TUI here — the raw frames are richer than the four bands. |
| `worker_permission_prompt` (teammate needs a tool / network) | §50.5, §39.19.4 | Only via the `Notification` hook, or by observing the teammate mailbox on disk | D | Teams are out of afleet v1 scope; recorded for completeness. |
| `auth_success`, `quota_auto_resume_*` (7 outcomes) | §50.2 table | `auth_status` frames exist with `--enable-auth-status`; quota outcomes surface as `rate_limit_event` / `result` errors, not as their notification texts | R | The exact wording is not on the wire; a GUI writes its own. |
| Per-session dedup of background-agent notifications before telemetry | §50.5 [`chunk-stanqxmj.js:694985`] | none | R | Trivial to reimplement. |

---

## 50.2 Notification settings and the `/config` surfaces

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/config` row `Notifications` (new panel, gate `tengu_maple_sundial`) — one `managedEnum` over `$U` | §50.6.1 | `/config` is `local-jsx`-adjacent and not in the headless command list **[live: 102 commands, no `config` row of this kind]**; the underlying key is readable/writable via `get_settings` / `update_settings` | R | GUI renders its own toggle. |
| `/config` rows `Push when actions required` / `Push when Claude decides` (old panel), gated by `pushTogglesVisible = iG() && !vt() && yu()` | §50.6.1 | Same — settings-level access only | R | The visibility conjunction (push gate ∧ not `essential-traffic` ∧ claude.ai OAuth) is not exposed on the wire; a GUI must approximate it from `account` in `initialize` and its own gate knowledge. |
| The dedicated `Notifications` dialog (`Channel` cycles `$U`; two boolean rows) | §50.6.2 | none | X | `local-jsx`-class UI; no headless equivalent. |
| `⚠ No mobile registered · get the app and turn on notif` warning driven by `push_reachability.has_active_channel` | §50.6.2, §50.7.4 | **Not on the wire.** `GET /api/claude_code/notification/preferences` is a first-party endpoint the CLI calls for itself; nothing publishes reachability to an SDK host | D | Workaround: afleet can call the same endpoint with the user's claude.ai token if it holds one, or simply omit the hint. Reachability is advisory — no code path consults it before emitting a push (§50.7.4). |
| Server-side preference mirror (`bogosort.enable_push`, `code_requires_action.enable_push`), seed-never-overwrite hydration, fire-and-forget PATCH | §50.7.1–§50.7.3 | none | D | A GUI that flips `agentPushNotifEnabled` locally via `update_settings` will leave the server mirror stale, because `itn()` only runs from the CLI's own `/config` handlers. Workaround: PATCH the endpoint directly, or accept divergence. |
| `messageIdleNotifThresholdMs` (no schema entry, no UI, `~/.claude.json` only) | §50.5.1, §50.22.1 | Disk read only | R | |
| `taskCompleteNotifEnabled` | §50.6 — dead in 2.1.257 | — | — | Do not implement. |

---

## 50.3 Presence and mobile push (`PushNotification`)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `PushNotification` tool exists and is model-callable | §50.9.1; `shouldDefer: true`, so normally reached through `ToolSearch` | **Present in the headless `system/init.tools` list [live]** alongside `CronCreate/CronDelete/CronList`, `Monitor`, `ScheduleWakeup`, `ListAgents`, `SendMessage`, `RemoteTrigger` | P | The GUI sees the call as an ordinary `tool_use`/`tool_result` pair. |
| Local half of the tool: a terminal notification is raised | §50.9.3 step 3 | Emitted as `os_notification`, **dropped** headless; the tool records `localSent = !isNonInteractiveSession`, i.e. `false` | D→R | afleet should render its own native notification off the `tool_use` block's `input.message`. The tool's own result will say `Mobile push not sent (Remote Control inactive).` unless a bridge is attached. |
| Gate chain `config_off` → `user_present` → local emission → `no_transport` → success | §50.9.3 | Runs identically; `user_present` uses `TPn()` = terminal focus, else "interaction within 60 000 ms" (§50.8.1) | D | **`TPn()` has no host input.** A headless process has no terminal focus and `Dh()` (last interaction) never advances from host activity, so `user_present` will effectively never suppress. Consequence: a GUI user sitting in front of afleet still gets pushes the TUI would have suppressed. Workaround: set `CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK` (makes it explicit) and let the GUI decide, or set `CLAUDE_CLIENT_PRESENCE_FILE` (§50.8.3) so the *server* can drop redundant pushes. There is no control request to report presence. |
| Result strings, model-facing and user-facing (7 rendered variants incl. `Not sent because you're active in this terminal.`) | §50.9.4 | The model-facing string arrives in the `tool_result`; the user-facing rendering is TUI-only | R | afleet renders its own line from `pushSent` / `localSent` / `disabledReason` in the structured output. Note the divergence the spec calls out: model is told "requested", user is told "sent". |
| The synthetic ready-nudge push (`Your Claude Code session is ready — continue from your phone anytime.`) minted as an `is_meta` assistant `tool_use` on bridge `connected` | §50.10, §36.16.5 | Written with `writeSdkMessages`, i.e. onto the *bridge* stream, not stdout. Off by default (`tengu_kairos_ready_nudge` default `null`) | D | Not something afleet needs; note it will appear on the phone if a user enables Remote Control. |
| Four `fJ()`-gated prompt fragments that steer the model toward pushing (Monitor suffix, Monitor tool prompt, autonomous-loop tick, cron stop suffix) | §50.11 | Identical — they are prompt text, not UI | P | Only present when `tengu_kairos_push_notifications` ∧ `agentPushNotifEnabled`. |
| Notification-bar push upsell (`get pinged when Claude finishes · /config`, 20 idle minutes, ≤ 3 impressions) | §50.12 | none | T | Superseded. |
| Remote presence pulse `POST /v1/code/sessions/<id>/client/presence` (5 s rate limit, skipped when blurred / non-first-party) | §50.8.2 | Only runs when the REPL bridge is up | D | If afleet enables Remote Control on a hosted session (see 36.4), it inherits this — but it cannot report GUI focus, because the reporter reads terminal focus. Workaround is the marker file `CLAUDE_CLIENT_PRESENCE_FILE`: create it while the afleet window is focused, delete it when not. |

---

## 50.4 The inbound notification-bar frame (`system`/`notification`)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| A remote client pushes a strip entry into the terminal notification bar | §50.13 | The frame is **emitted outward** on the SDK stream as `{type:"system", subtype:"notification", key, text, priority, color?, timeout_ms?}` [`chunk-chr1kh62.js:448600`]; it is in 45.9.1 and passes filter `Cu` | P | afleet renders it as a transient banner. Two in-build producers: `error-compacting-conversation` and `fast-mode-overage-rejected`, both `priority: "immediate"`, `color: "error"`. |
| Validation and normalisation (priority ∈ low/medium/high/immediate; `timeout_ms` clamped 0–60 000; text truncated to 1 000 chars and newline-collapsed; colour ≤ 64 chars) | §50.13 | Same shape on the wire; the GUI applies the same clamps when rendering | P | |
| Remote entries are namespaced `remote:` + 256 chars, `immediate` demoted to `high`, ≤ 3 concurrent with oldest evicted | §50.13 | Ingress-side only; a GUI reading the outbound frame sees the un-namespaced key | R | A GUI wanting parity applies its own concurrency cap. |
| Priority-driven placement/pinning in the bar widget | §41.15.5 (out of area) | none | R | The frame carries `priority`; the layout is the GUI's. |

---

## 50.5 Inbound rails: queued notifications, `Poll`, `session_notice`

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `queued_notification` frames → `<task-notification>` nudge → `ReadNotifications` | §50.14, §50.15 | Enabled **only** when `CLAUDE_CODE_REMOTE` is set **and** the session is non-interactive (`EFe`, §50.14.1). Advertised as capability `queued_notifications` in `system/init` | X for afleet | afleet's children are non-interactive but not `CLAUDE_CODE_REMOTE`; setting that env var would also disable Remote Control entirely (`xA()`, §36.2.1) and force `PushNotification` into remote mode. Treat the rail as unavailable. |
| The frame is server-authored-only: refused from the stdin lane, and SSE `event_type` must equal payload `type` | §50.14.3 [`chunk-2rhzyjym.js:171392`] | **A host cannot inject one.** | X | This closes the obvious "afleet delivers a Slack message as a queued notification" idea. Use the channel rail (50.6) or a plain `user` frame instead. |
| Origin vocabulary `github_webhook` / `trigger_fire` / `mcp_send_message`, open set | §50.14.8 | n/a | — | |
| `Poll` tool + `poll_event` control request (`<event kind=… at=…>`, nonce manifest, 20-event / 32 768-byte chunking) | §50.16 | **A host can inject events**: `poll_event` is one of the 66 control requests (45.17). Requires `CLAUDE_CODE_POLL_EVENTS=true`, `launchOptions.pollEventIngressWired()`, **and permission mode exactly `auto`** (§50.16.6) | R (conditional) | This is the only sanctioned host→model out-of-band event channel. The permission-mode requirement is load-bearing: `poll event rejected: poll events require permission mode "auto" …`. If afleet ever wants to hand a channel message to the model as an *event* rather than a user turn, this is the mechanism — at the cost of forcing `--permission-mode auto`. |
| `Poll` blocks until an event or new user input arrives; a second concurrent call returns `(no pending events)` | §50.16.2 | Same | P | |
| Reserved kind `session-notice` matched leetspeak- and Levenshtein-1-tolerantly | §50.16.5 | Same refusal | P | |
| `session_notice` frames (MCP session-notice sub-rail) | §50.17 | Requires `CLAUDE_CODE_REMOTE === true` ∧ non-interactive ∧ gate `tengu_polished_lagoon` (default off) ∧ Poll enabled ∧ permission mode `auto` | X | Not reachable for afleet. |
| `ReadNotifications` result carries the `[SYSTEM NOTIFICATION - NOT USER INPUT]` preamble | §50.15.3 | Would appear in the `tool_result` if the rail were on | P | |

---

## 50.6 Channel servers (Slack / Telegram / … plugins)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| A channel is an MCP server declaring `experimental["claude/channel"]`; it pushes `notifications/claude/channel` | §50.18.2, §50.18.3 | Same MCP machinery headless | P | Content has **no size cap and no rate limit** in 2.1.257 (§50.18.4) — afleet should impose its own. |
| Inbound channel message becomes a **user prompt**, `isMeta: true`, `priority: "next"`, `skipSlashCommands`, `skipAttachments`, `origin: {kind:"channel", server}` | §50.18.4 [`chunk-bq8epagv.js:429820`], SDK twin at [`chunk-2rhzyjym.js:179039`] | With `--replay-user-messages` the host sees a replayed `user` frame carrying `origin` [`chunk-2rhzyjym.js:176411`]; `origin` is a published field of the `user` frame union with `kind ∈ human \| channel \| peer \| task-notification \| coordinator \| unclassified \| observer \| auto-continuation \| observer-activity` (SPEC 45.15.1) | P | **This is the load-bearing parity fact for afleet's channel feature.** The GUI can attribute every inbound turn by `origin.kind` and, for channels, `origin.server`. |
| Rendered envelope the model sees: `A message arrived from <server> while you were working:` + `<channel source="…" meta…>` + the `IMPORTANT: This is NOT from your user` warning + `After completing your current task, decide whether/how to respond.` | §50.18.4 | Identical text; it is inside the replayed `user` frame's content | P | A GUI should *not* render this preamble verbatim to the human — it is model-facing. Strip to the `<channel>` body and show `source`/`meta` as chips. This is a clear place a GUI exceeds the TUI. |
| Meta keys must match `/^[a-zA-Z_][a-zA-Z0-9_]*$/`; non-matching dropped with a warn log | §50.18.4 | Same | P | Attributes survive in the envelope; parse them for the chip row. |
| Registration gate chain (9 ordered skip reasons: capability, era, provider, disabled, policy, session, marketplace, allowlist ×3) | §50.18.5 | Same predicate `bPe` runs headless | R | The skip *toast* is TUI-only; the reason string is available to a host only through `channel_enable`'s error response (below) or `mcp_status`. |
| `--channels <servers…>` and `--dangerously-load-development-channels <servers…>` (both hidden from `--help`; entries must be tagged `plugin:<name>@<marketplace>` or `server:<name>`) | §50.18.7 | Flags work headless — they are root flags | P | afleet's command line does not currently pass `--channels`; it must, or use `channel_enable`. |
| The `--dangerously-load-development-channels` startup confirmation dialog (`WARNING: Loading development channels`, buttons `I am using this for local development` / `Exit`→exit 1) | §50.18.7 | A dialog at startup with no TTY — the headless path cannot show it | X | Consequence: afleet cannot use the dev-channels flag. It must ship channels as marketplace plugins on the ledger/org allowlist, or use `channel_enable`. |
| `channel_enable` control request | §50.18.9; handler [`chunk-2rhzyjym.js:179026`] | **Works headless.** Takes the MCP server name; requires the server to be connected *and* plugin-sourced with a marketplace (`server <n> is not plugin-sourced; channel_enable requires a marketplace plugin`); optimistically appends to the session allow-list, re-runs `bPe`, rolls back on skip, returns the skip `reason` as the error | P | This is afleet's supported route to turning a channel on at runtime without `--channels`. It also re-registers after MCP reconnect. |
| Capability-laundering guard: `claude/channel` is stripped from capabilities reported to an SDK client unless every condition still holds | §50.18.9 [`chunk-2rhzyjym.js:175981`] | Applies to what afleet sees in `mcp_status` | P | So `mcp_status` is a trustworthy "is this really a live channel" probe. |
| The channel permission responder (`notifications/claude/channel/permission_request` broadcast to every eligible server; first responder wins; **the local dialog still renders**; no timeout) | §50.18.6 | The `can_use_tool` request still goes to the host; the channel racer resolves it out from under the GUI | D | afleet must handle a permission request being answered elsewhere: the CLI cancels it. There is a `control_cancel_request` for the bridge path (§36.11.1) but the channel-responder path resolves locally — the host sees the `can_use_tool` simply never needing an answer. Design for "my dialog was invalidated". Gated by `tengu_harbor_permissions` (default off). |
| `channelsEnabled` / `allowedChannelPlugins` managed settings; no hard-coded allowlist in the binary (`tengu_harbor_ledger` supplies it, default `[]`) | §50.18.1, §50.18.8 | Same | P | In an offline / flag-less build **no `plugin:` channel can register at all**. This is a real deployment risk for afleet. |
| `#` at the prompt completes Slack channel names (`slack_search_channels`, limit 20, 150 ms debounce, ≤ 10 rows, requires a connected MCP server whose name contains `slack`) | §42.16.3; the per-command opt-out `completesHashChannels` is read but never written | Not a wire feature | R | Rebuild with the `mcp_call` control request against `slack_search_channels`. A GUI can exceed the TUI: richer rows, avatars, recency. |
| `~/.claude/channels/<name>/outbox/` | §50.20 — **neither created nor read by this build** | — | — | Do not build against it. |

---

## 50.7 Slack, Claude Tag, `/install-slack-app`

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Slack is *not* a notification channel — nothing in the harness routes outward to Slack | §50.19.1 | Same | P | Outbound Slack is only ever a model-issued MCP tool call. |
| `/install-slack-app` — `local`, `availability: ["claude-ai"]`, `supportsNonInteractive: false`; opens `https://slack.com/marketplace/A08SF47R6P4-claude`, bumps `slackAppInstallCount` | §50.19.3, SPEC 28 §614 table row | **Absent from the headless command list [live]** — a `local` command with `supportsNonInteractive: false` is refused | X→R | Trivial to rebuild: the GUI opens the same URL. It should also bump `slackAppInstallCount` in `~/.claude.json` so the two Slack tips stop firing (§50.19.4). |
| Claude Tag (Slack thread = one remote cloud session; org-owned identity; config snapshotted at thread start) | §50.19.2, `modules/claude-tag-dht2qzjm.md` | Entirely server-side | — | Relevant only as context: Claude Tag is *not* a local channel and cannot be hosted by afleet. |
| Inbound `slack-ping` origin (`channelId`, `threadTs`, `messageTs`, `slackUserId`, `senderDisplay`, `permalink`) | §50.19.5 | The origin union on the `user` frame (SPEC 45.15.1) does **not** include `slack-ping` — the bridge classifier produces it, but the published `origin` enum is `human\|channel\|peer\|task-notification\|coordinator\|unclassified\|observer\|auto-continuation\|observer-activity` | D | A Slack-relayed turn arriving through the bridge would surface to a stdio host (if at all) as `peer` or unclassified. Only relevant if afleet hosts a Claude-Tag session, which it cannot. |
| `[Verified human message relayed from the bound Slack thread]:` marker, emitted only when the server attested provenance and this is a Slack-entrypoint session | §50.19.5 | Not reachable from stdio | X | |
| The two Slack tips (`Run /install-slack-app to use Claude in Slack`, and the Slack-MCP variant) | §50.19.4 | Tips are TUI chrome | T | |
| `Slacked` display override for `slack_send_message` / `slack_post_message`, with a `#channel` deep link | §50.19.6 | Tool-render metadata is TUI-only; the raw `tool_use` is on the wire | R | Easy GUI win: render the same deep link. |

---

## 50.8 Joke and helper commands; away summaries; prompt suggestions

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/radio` — `local`, `supportsNonInteractive: false`, opens `https://clau.de/radio` | §50.21, SPEC 28 row 632 | **Absent headless [live]** | X→R | One-line rebuild. |
| `/stickers` — same shape, opens `https://www.stickermule.com/claudecode` | §50.21, SPEC 28 row 655 | **Absent headless [live]** | X→R | One-line rebuild. |
| `/mobile` (aliases `ios`, `android`) — `local-jsx`, two-tab QR dialog for the App Store / Play Store URLs | SPEC 36 §3.3, SPEC 28 row 619 | **Absent headless [live]**; `local-jsx` never works headless (SPEC 28 §22) | X→R | Pure app-download helper — it has nothing to do with pairing. A GUI shows the two links or renders its own QR. |
| `/wellbeing` (aliases `breaks`, `break-reminder`, `downtime`) — `local-jsx`, `Configure optional break reminders and quiet-hours nudges` | SPEC 28 row 676 | **`isEnabled: () => false` — always off in 2.1.257**, so it is absent from the TUI too | — | Nothing to port. Do not build a settings row for it. |
| `away_summary` — a recap of what happened while the terminal was unfocused, appended as `{type:"system", subtype:"away_summary", content, timestamp, uuid, isMeta:false}` with `(disable recaps in /config)` appended for the first 3 [`chunk-1kg58a1a.js:154421`], [`chunk-…:432070`] | Trigger is the **terminal focus subscription** `this.#e.focus.subscribe` [`chunk-…:432077`]; requires ≥ 3 human turns and ≥ 2 since the last summary [`chunk-…:431934-431951`] | Listed as a possible `system` subtype in SPEC 45.9.1 (the "internal surfaces" row), but its only producer is the REPL focus watcher, and there is no focus signal from a stdio host | D | **afleet cannot get away-summaries.** No control request reports host window focus. Workaround: afleet generates its own recap by asking the model (`side_question` control request is the closest supported one-shot fork), or renders a diff of transcript frames since the window lost focus — a place a GUI can beat the TUI, because it actually knows about focus. |
| `prompt_suggestion` — `{type:"prompt_suggestion", suggestion, uuid, session_id}` emitted after each turn [`chunk-2rhzyjym.js:176558`] | TUI shows it as ghost text; accepting logs `tengu_prompt_suggestion` | **On the wire, gated by `--prompt-suggestions`** (SPEC 45.9.1; flag at 45 §302). The flag errors out unless `--print` and `--output-format=stream-json`: `Error: --prompt-suggestions requires --print and --output-format=stream-json …` | P | afleet's command line does **not** currently pass `--prompt-suggestions`; adding it is free parity. Generated by a forked main-loop model call (SPEC 06 §3605), so it costs tokens. |

---

## 36.1 Remote Control eligibility, gates and diagnostics

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Eligibility: first-party API ∧ claude.ai subscription ∧ `tengu_ccr_bridge` ∧ not already remote ∧ not `disableRemoteControl` (`Sb()`, `Twn()`) | §2.1, [`chunk-b406103p.js:375709`] | **`Twn()` contains no TTY or interactivity check** — the same predicate governs a headless session | P | Confirmed live: `initialize` reports `remote_control_available: true` in a headless session on this machine **[live]**. |
| `initialize` advertises `remote_control_auto_enable`, `remote_control_available`, `remote_control_auto_on_by_default`, `ide_rc_auto_enable_gate` | SPEC 45 §45.18.4 [`chunk-2rhzyjym.js:178999`] | Present in every `initialize` control response | P | **[live] on this machine: `remote_control_available: true`, `remote_control_auto_enable: true`, `remote_control_auto_on_by_default: false`, `ide_rc_auto_enable_gate: true`.** afleet can render an accurate "Remote Control" affordance without guessing. |
| The 11 disabled-reason sentences (`jqt()`) | §2.3 | Not on the wire as a field — only `remote_control_available: false` | D | Workaround: afleet shows a generic "unavailable" and links to `claude doctor`. Or run `claude doctor` out-of-band and parse the Remote Control section (§2.6, nine check labels). |
| `claude doctor` Remote Control checklist (9 labels, failing checks only) | §2.6 | Separate process | R | |
| Minimum-version refusal (`tengu_bridge_min_version`, REPL uses `tengu_bridge_repl_v2_config.min_version`) | §2.5 | Same refusal path | P | |
| Org policy `allow_remote_control`, managed `disableRemoteControl`, `remote_control_at_startup` policy default | §2.2, §3.4 | Same resolution; `disableRemoteControl` readable via `get_settings` | P | |

## 36.2 Entry points (`/remote-control`, `--rc`, the CLI verb)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/remote-control` (alias `rc`) — `local-jsx`, `immediate: true`, description flips to `Disconnect Remote Control` when live, `isHidden: !Sb()` | §3.3, SPEC 28 row 638 | **Absent from the headless command list [live]**; `local-jsx` never runs headless | X → replaced by the `remote_control` control request (36.4) | The GUI must not surface this as a slash command; it drives the control request. |
| The one-time `Remote Control` enable card (`Take this session with you…` / `Enable Remote Control` / `Never mind`, sets `remoteDialogSeen`) | §3.3, dialog kind `remote_callout` with results `enable\|dismiss\|cancelled` | Dialog kinds are only requested when the host declared them in `initialize.supportedDialogKinds`; **`remote_callout` is a locally-raised dialog, not a `request_user_dialog`**. A non-interactive surface refuses: `Remote Control asks for a one-time confirmation before it's first enabled, and this session can't show it. Run /remote-control from an interactive Claude Code session.` | X on the slash path; **bypassed** on the control-request path | The `remote_control` handler at [`chunk-2rhzyjym.js:178376`] does not consult `remoteDialogSeen` — it calls `initReplBridge` directly. afleet should therefore show its **own** consent card before sending the request; the CLI will not ask. |
| The connected card (`This session is available in the Claude mobile app and claude.ai/code.`, rows `Disconnect this session` / `Show QR code` / `Continue`) | §3.3 | none | R | The QR data is `session_url` from the control response (below). Rebuild in native UI. |
| Four Remote Control notification/upsells: `rc-idle-upsell` (20 min, ≤ 3), `rc-permission-nudge` (`probability: 0`, off by default), `rc-long-turn-nudge` (`thresholdSec: 90`, quiet hours 07:00–21:00), `remote-control-auto-on` startup card | §3.3 "Notifications and upsells" | none | T | Superseded; afleet decides its own promotion. The quiet-hours rule (`dayStartHour: 7, dayEndHour: 21`) is the only one in the build and is worth copying. |
| `--remote-control [name]` / `--rc [name]` / `--remote-control-session-name-prefix <prefix>` root flags | §3.2 | Root flags work with `-p` in principle; the startup resolver `Yn()` explicitly suppresses auto-start when `isRemoteThinClient` or `CLAUDE_CODE_REMOTE`, neither of which applies to afleet | P | Simplest path: launch children with `--rc <name>`. Then `replBridgeExplicit` is set, which produces the `bridge_status` transcript line (§7.9). |
| Root options before the verb are **refused, not dropped**, with a 28-name allowlist | §3.1.3 | Only affects `claude remote-control`, not afleet's launch line | — | |
| `remoteControlAtStartup` resolution (repo-scoped `false` wins; repo-scoped `true` is ignored; then policy/flag/user; then legacy `~/.claude.json`) | §3.4 | Same; readable via `get_settings`, writable via `update_settings` (localSettings only — note this cannot set a *user*-scope value) | R | afleet should surface it as a per-app preference and write user settings itself if it wants parity with `/config`. |
| `/config` row `Enable Remote Control for all sessions` with `lock.writableWhileLocked: ["false"]` | §3.4 | none | R | Copy the semantics: a user may always turn RC **off**, even under a policy that forces it on. |
| Mirror mode (`autoUploadSessions`, `outboundOnly`) | §3.5 | **Inert in this build** — the reader is neither exported nor called; reachable only via `CLAUDE_BRIDGE_REATTACH_OUTBOUND_ONLY` | — | Do not build against it. |
| `claude daemon remote-control <add\|remove\|list>` | §3.6 | Gated off (`isDaemonWorkerRegistryEnabled()` is a literal `false`, SPEC 38 §38.2) | — | Unavailable in 2.1.257. |

## 36.3 The headless bridge server (`claude remote-control`)

This whole program is a *sibling* of afleet, not a dependency: it spawns its own
`claude --print` children. Listed because its child command line is the closest official
statement of "how a first-party host drives the CLI".

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| The child command line: `--print --sdk-url <url> --session-id <id> --input-format stream-json --output-format stream-json --replay-user-messages --resume=<sdkUrl> [--verbose] [--debug-file] [--permission-mode] …` | §6.4 | — | — | Note what Anthropic's own host **does not** pass: no `--include-partial-messages`, no `--forward-subagent-text`, no `--include-hook-events`, no `--permission-prompt-tool`. afleet's line is strictly richer. |
| Token refresh pushed into a running child over stdin as `{"type":"update_environment_variables","variables":{"CLAUDE_CODE_SESSION_ACCESS_TOKEN":"…"}}` | §6.6 | Confirms the two-var stdin frame is real and used | P | |
| Child env overlay and the `ule` carry-over deny list (28 names scrubbed case-insensitively before spawn) | §6.5 | — | R | afleet should scrub the same list when spawning children, or inherit stale bridge identity. |
| The terminal renderer: banner, `Ready · <repo> · <branch>`, capacity line, per-session OSC-8 links, QR, `space to show QR code`, `w to toggle spawn mode`, `[HH:MM:SS]` log lines | §4.11 | — | T | Pure terminal chrome; afleet's window replaces it. |
| Activity extraction from child stdout (`Read→Reading`, `Bash→Running`, …; last 10 activities, last 10 stderr lines) | §6.6 | — | R | Useful crib for afleet's own activity summary line. |
| `[remote-io] warning: ` stderr marker for attestation drops | §13.6 | afleet sees these on the child's stderr | R | Parse and surface; otherwise the user gets silent frame drops. |
| Spawn modes (`same-dir`/`worktree`/`session`), first-run picker, `w` toggle, `remoteControlSpawnMode` project config | §4.4 | — | T | |
| Give-up messages, backoff ladders, system-sleep detection (240 s gap resets budgets) | §4.8 | — | R | Copy the sleep-detection heuristic if afleet supervises long-lived children. |

## 36.4 The `remote_control` control request (unpublished schema, recovered)

Recovered from the handler at `cli.pretty.js:178376–178562` and the response builder at
`cli.pretty.js:175189`. SPEC 45 §2265 lists it as *(no published schema)*.

```ts
// host → CLI
{ type: "control_request", request_id, request: {
    subtype: "remote_control",
    enabled: boolean,                    // true = attach, false = detach
    name?: string,                       // initialName → the session title in claude.ai/code
    reattach_session_id?: string,        // string only; anything else ignored
    keep_session_on_exit?: boolean,      // === true → neverArchive
    work_secret?: string                 // non-empty string only; enables the work-secret attach path
} }

// CLI → host, on enabled:true success
{ session_url: "https://claude.ai/code/<compatSessionId>",
  connect_url: "https://claude.ai/code?environment=<environmentId>",
  environment_id: string,                // always "" for the REPL bridge (§7.7)
  bridge_epoch: number,                  // monotonic, incremented per successful attach
  bridge_session_id: string }

// CLI → host, on enabled:false success
{}                                        // empty payload
```

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Enabling Remote Control from a host | `/remote-control` | The request above; works in `-p` | P | Refusals: `Remote Control cannot be enabled from inside a remote session` (when `isRemoteTransport()`); `Remote Control initialization failed` or the `onStateChange` detail string. Re-enabling while already attached returns the current `Uo(...)` payload; enabling while a *different* session is bound tears the old one down first. |
| Connection state | `/rc connecting… / active / reconnecting / failed` status-line label (§7.9) | **A `{type:"system", subtype:"bridge_state", state, detail, bridge_epoch, uuid, session_id}` frame is enqueued onto the SDK stdout stream on every state change** [`cli.pretty.js:178527`]. `state ∈ init\|ready\|connected\|reconnecting\|failed\|policy_disabled`; `detail` is the human sentence | P | **Undocumented in the SPEC library** — not in 45.9.1's frame table and not in the 45.9.2 drop list, and it is enqueued directly on the output queue. afleet gets full connection-state parity for free, including the failure sentences of §7.3. |
| `session_url` / QR code | The connected card's QR (§3.3) | `session_url` in the control response; also `Ta()` = `https://claude.ai/code/<compatSessionId>` (§1.2) | P | Render a native QR; the TUI's `small: true` option is inert on the `utf8` path anyway (§3.3). |
| Bridge teardown reason | — | `{type:"system", subtype:"worker_shutting_down", reason}` is on the wire (45.9.1; schema at 45 §1720). Reasons observed: `remote_control_disabled`, `host_exit`, `owner_changed`, `account_changed` | P | The schema note is important: absence is **not** a dead-host signal, and a resumed session may replay historical instances — treat it as live-tail only. |
| `remote_control_work_secret` | — | A separate control request the CLI sends the host (`onWorkSecretRefresh` → `n.requestRemoteControlWorkSecret`) [`cli.pretty.js:178529`]; listed in SPEC 45 §2893 | D | afleet only needs it if it supplies `work_secret`; otherwise ignore. |
| The 27 `tengu_bridge_repl_skipped` reasons and their user-facing detail sentences (`Claude.ai login expired — run /login, then /remote-control`, …) | §7.3 | Delivered as `bridge_state{state:"failed", detail}` | P | Rewrite `/login` and `/remote-control` references into GUI actions — a place afleet beats the TUI. |

## 36.5 What the bridge advertises to a thin client (the first-party GUI contract)

This is the best available statement of "what a first-party GUI is expected to render".

| Feature | Bridge/worker behaviour (cite SPEC §) | afleet's stdio equivalent | Class | Notes |
|---|---|---|---|---|
| The 20 client→worker control subtypes: `initialize`, `set_model`, `set_max_thinking_tokens`, `set_permission_mode`, `rename_session`, `set_color`, `file_suggestions`, `read_file`, `get_workspace_diff`, `get_context_usage`, `get_usage`, `mcp_status`, `mcp_authenticate`, `mcp_oauth_callback_url`, `mcp_reconnect`, `interrupt`, `apply_flag_settings`, `mcp_set_servers`, `stop_task`, `background_tasks` | §10.1 | **All 20 are in the 66-request stdio set (BRIEF 45.17).** So the entire first-party GUI command surface is reachable over stdio | P | This is the strongest single finding for afleet: everything Anthropic's own mobile/web client can do to a session, a stdio host can do. |
| `initialize` response the bridge returns: `{commands, agents: [], output_style: "normal", available_output_styles: ["normal"], models: [], account: {}, pid, …getInitializeState()}` plus `pending_permission_requests` / `pending_user_dialog_requests` | §10.1 | The stdio `initialize` response is **strictly richer**: real `agents`, real `models`, `unavailable_models`, `account`, `fast_mode_state`, `footer_indicator`, `feedback_survey_config`, `session_state`, the four `remote_control_*` fields **[live: 102 commands, 11 agents, full models list]** | P | afleet is better-fed than the phone. |
| The redacted `system/init` variant on a bridge connection: `cwd: ""`, `betas`, `memoryPaths`, `messagingSocketPath`, `powerShellPath`, `footerIndicator` all blanked; plugin/MCP error arrays emptied | §45.10.5 [`chunk-chr1kh62.js:448053`] | afleet gets the **unredacted** variant — including `messaging_socket_path` **[live: `/tmp/cc-socks/34882.sock`]**, `cwd`, `memory_paths` | P | Another place afleet exceeds the phone. |
| Only `user` frames may be injected as conversation; everything else must be a control frame | §9.4 | Identical on stdio, plus `bash_command` (which the bridge also accepts, §9.3) | P | |
| Worker→client requests: only `can_use_tool` and `request_user_dialog` (plus the three served-tool subtypes) | §10.2 | stdio adds `hook_callback`, `mcp_message`, `elicitation`, `oauth_token_refresh`, `host_auth_token_refresh` (BRIEF 45.17) | P | |
| `supportedDialogKinds` bounds: non-empty strings ≤ 64 chars, at most 32 kept | §10.2 | Same field on the stdio `initialize` | P | **[live] afleet's probe sent `supportedDialogKinds: []`, so no `request_user_dialog` will ever arrive.** Declaring kinds is how afleet opts into non-permission dialogs. |
| The `dialog:` pseudo-tool convention for phones (`tool_name: "dialog:<kind>"`, `display_tool_name: "Claude needs your input"`) | §10.3 | Used only in the `pending_action` metadata lane; `RequiresActionDetails.tool_name` explicitly refuses `dialog:` names | R | afleet should render `request_user_dialog` natively rather than as a pseudo-tool. |
| `can_use_tool` summary fields for a phone (`AskUserQuestion`→`Question`, `ExitPlanMode`→`Plan`/`Plan ready for review`, else the description or the Bash command truncated to 120) | §10.3, §50.8.4 | Gated by `tengu_bridge_requires_action_details` (default `false`) and only published as bridge metadata | R | Good crib for afleet's own permission-card titles. |
| Only `effortLevel` and `ultracode` may be changed remotely (`apply_flag_settings`) | §12.2 | Same restriction on stdio; error strings are verbatim | P | `ultracode: true` forces effort `xhigh`. |
| `external_metadata` the worker publishes: `permission_mode` (suppressed while `bypassPermissions`), `is_ultraplan_mode`, `effort_level`, `cross_session_inbound`, `post_turn_summary`, `pending_action(s)`, `current_branches`, `worktree_state`, `task_summary` | §12.1 | **Not on stdio.** The equivalents are `system/status` (permissionMode change), `session_state_changed`, `system/post_turn_summary`, `vcs_state_changed` | P (mostly) | `current_branches`/`worktree_state` have no stdio twin; `vcs_state_changed` is the nearest. Class D for per-worktree git state. |
| `system/init` re-sent on every model / permission-mode / fast-mode / effort / command-list / MCP-command-list change | §12.4 | Identical on stdio — `system/init` opens **every** turn (BRIEF 45.9.1) **[live: 48 `system/init` frames across 48 turns]** | P | afleet should diff consecutive `system/init` frames rather than assume they are constant. |
| Control-request timeouts: 75 s client→worker, 600 s for `side_question`, reset by `system/control_request_progress` | §10.4 | Same frames on stdio (`control_request_progress` is `side_question`-only per BRIEF) | P | |
| The permission relay's "first answer wins, loser dismissed by `control_cancel_request`" | §11.1, §11.3 | On stdio afleet is the *only* answerer unless Remote Control is also on | P | If afleet enables Remote Control, it must handle its own `can_use_tool` being cancelled. |
| Undelivered-answer resend ladder (1 s, 5 s, 15 s, 45 s; ≤ 4 failures) and the six give-up sentences | §11.5 | Bridge-side only | R | Copy the sentences if afleet ever proxies answers. |
| Device attestation filtering and its four user notices (`Remote Control ignored a message that arrived without a valid device signature (attestation: ABSENT). Re-pair the sending device in Trusted Devices.`) | §13, §13.4 | Reaches afleet as `[remote-io] warning: ` lines on child stderr (§13.6) | R | Surface them; the user otherwise sees phone input silently vanish. |
| `mcp_set_servers` on a bridge only honours injected Project servers (`(servers not adopted): <n> server(s) not adopted: a Remote Control bridge only honors the injected Project servers`) | §10.1 | On stdio, `mcp_set_servers` is unrestricted | P | afleet exceeds the phone. |
| Served tools / passthrough tools (a cloud session running `Bash`/`Read`/`Write`/`Edit` on the local machine) | §17 | **Disabled in this build** — four stubs return `false`/`external_build` | — | Not implementable. |

## 36.6 Can a headless-hosted session be Remote-Controlled from the phone?

**Yes, subject to eligibility — and this is the mechanism that makes afleet-hosted channels
reachable from claude.ai mobile.** Evidence:

1. `Twn()` — the predicate `initReplBridge` gates on — is `Sj() && !xA() && u() && gate("tengu_ccr_bridge")`
   [`chunk-b406103p.js:375709`]. There is no TTY, `isInteractive`, or surface check.
2. The `remote_control` control request handler is in the **SDK/headless** control dispatcher
   (`chunk-2rhzyjym.js`, the same file that handles `initialize`, `channel_enable`, `poll_event`),
   not in the REPL. It calls `initReplBridge` directly and does not consult `remoteDialogSeen`.
3. Its only structural refusal is `Remote Control cannot be enabled from inside a remote session`
   (`n.isRemoteTransport()`), which is false for a stdio-hosted child.
4. `initialize` on this machine, in a headless session, reports `remote_control_available: true`
   and `remote_control_auto_enable: true` **[live]**.

Practical consequences for afleet:

* A channel-owning headless session can publish itself to `claude.ai/code` and the Claude mobile
  app. The phone then sees the transcript, can send `user` frames, can answer `can_use_tool`, and
  can drive the 20 control subtypes of §10.1.
* Because the local TUI equivalent is "nothing is locked out — the bridge is an additional client,
  not an exclusive one" (§18.6), afleet keeps full control while the phone is attached. The only
  exclusivity is one *worker* per session (`worker_epoch`).
* afleet must render its own consent card first (36.2), must handle `can_use_tool` being answered
  from the phone (a `control_cancel_request` on the bridge, or simply a request that never needs
  an answer locally), and should surface `bridge_state` transitions.
* `--rc <name>` at launch is the simpler alternative to the control request, and it sets
  `replBridgeExplicit`, producing the `/remote-control is active · Continue here, on your phone,
  or at <sessionUrl>` transcript line (§7.9).

---

## 39.1 FleetView / the agents view

FleetView has **no relationship to agent teams** (§39.32, §39.32.12) — it is a TUI over the
background-job client. For afleet it is the closest existing "multi-session GUI" and therefore the
best design reference; almost none of it is reachable through the headless protocol.

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| FleetView opens via seven routes (`claude agents`, bare `claude` with `defaultToAgentsView`, the commander handler, bare `--resume`, left-arrow out of the REPL, `--cloud` detach, clean APC detach) | §39.32.2 | Not a session feature at all — it is a separate process/screen | T | afleet *is* the replacement. |
| Gate: on by default; off via `CLAUDE_CODE_DISABLE_AGENT_VIEW` or the `disableAgentView` setting; rejection prints `'<verb>' <reason>.` and exits 1 | §39.32.1 | `disableAgentView` readable via `get_settings` | R | Note the same setting disables `--bg`, `/background` and the on-demand daemon (SPEC 38 §38.30). |
| Four bands: `Ready for review` / `Needs input` / `Working` / `Completed`, with the onboarding descriptions | §39.32.9 | Reconstructable from `session_state_changed`, `task_*` frames and the registry `status` field — **but only for sessions that publish `status`, which headless sessions do not** (see 38.2) | R/D | afleet knows its own children's state from their frames; it cannot band *other* sessions reliably. |
| Status word logic (`Done`/`Failed`/`Stopped`/`Working`/`Needs input`/`Idle`, dim on idle) | §39.32.9 | — | R | Direct crib. |
| Four columns: age, label, artifact (`N PRs` / `#N` / `PR`), detail | §39.32.9 | — | R | |
| Group modes `state` → `directory` → `group`, persisted as `fleetViewGroupMode`; reserved headers `(ungrouped)`, `(earlier)` | §39.32.9 | — | R | |
| Terminal title `<n> awaiting input · claude agents` | §39.32.9 | — | T | Native equivalent: dock badge. |
| Empty states (`Nothing running in the background.`, `Hand off a task and it keeps working…`, `You are not logged in…`) | §39.32.9 | — | R | |
| Origin banner `Your conversation moved to the background — enter opens it · esc returns to it · ctrl+c twice quits` | §39.32.9 | — | T | |
| ~28 keybindings; only three are rebindable (`agents:switchView`, `agents:togglePin`, `chat:externalEditor`) | §39.32.10 | — | T | A GUI has no chord budget problem; this is a place to exceed. |
| The peek pane's deferred space key (500 ms, so push-to-talk can claim it) | §39.32.6 | — | T | |
| Tab-accept of a prompt suggestion inside the peek pane, logged `source: "fleetview_peek"` | §39.32.6 | `prompt_suggestion` frames with `--prompt-suggestions` | P | |
| IDE auto-connect from FleetView (opens its own `ide` MCP connection so `@`-mentions resolve editor state) | §39.32.5 | `mcp_set_servers` / `mcp_reconnect` control requests let afleet do the same | R | |
| Refresh cadence 120 s / 2 s / 500 ms / 30 s / 30 s | §39.32.9 | — | R | |
| The `remote` tab | §39.32.4 — **dead**: `zu()` returns `false`, `showRemoteTabs` is a literal `false`, `listRemoteSessions` returns `[]` | — | — | Do not build it. |
| The launch composer | §39.32.1 — **dead code**, both predicates return literal `false` | — | — | |
| The built-in `claude` background-job agent's three markers (`result:` → done, `needs input:` → blocked, `failed:` → done/failure) read from **message text only** | §39.32.11 | The prompt is real and applies to any background job; the classifier is TUI-side | R | If afleet dispatches background jobs it must reimplement the classifier — or better, use the `task_*` frames it already receives, which are strictly more reliable than parsing prose. |
| Fleet nudges → OS notifications with `agent_needs_input` / `agent_completed`, `idle-seed` suppression | §39.32.7, §50.5 | — | R | |
| `defaultToAgentsView`, `leftArrowOpensAgents`, `hasOpenedAgentsView`, `autoConnectIde` global-config keys; `/config` row `Agents view` | §39.32.8 | Global-config keys are on disk in `~/.claude.json`; not in the settings schema | R | |
| `claude agents` refuses a non-TTY stdout: `requires an interactive terminal (stdout is not a TTY) — use 'claude agents --json' for a machine-readable listing` | §39.32.2 | **`claude agents --json` is the documented machine-readable listing** | R | See 38.5 — this is afleet's out-of-band way to enumerate background jobs. |

## 39.2 Agent teams (out of afleet v1 scope, documented for completeness)

Teams require `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` or `--agent-teams` **and** the gate
`tengu_amber_flint` (§39.2.1). afleet's v1 excludes teams-as-channel-members; the rows below say
what a later version would face.

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Two roles only, flat roster: `team-lead@<team>` and `<name>@<team>`; teammates cannot spawn teammates | §39.3.1, §39.3.2 | Same refusal text | P | |
| A teammate is spawned by passing `name` to the `Agent` tool; the three teams-only schema fields (`name`, `team_name`, `mode`) are stripped from the wire schema when the gate is off | §39.2.1, §39.8.1 | `system/init.tools` would show `Task`/`Agent` either way; the *schema* difference is visible only in the tool definition | R | afleet can detect team-capability by inspecting the Agent tool's input schema. |
| `-n <name>` / `--agent-name` — teammate identity flags `--agent-id`, `--agent-name`, `--team-name` must be supplied **together**, else `Error: --agent-id, --agent-name, and --team-name must all be provided together` | §39.2.5 | These are root flags, so they work headless | P | Note `-n` in afleet's launch line is the *session* name flag (SPEC 38 `CLAUDE_CODE_SESSION_NAME` / registry `name`), not `--agent-name`. **[live: a headless probe with no `-n` got `name: "tmp-32", nameSource: "derived"`.]** |
| `--agent-color`, `--agent-type`, `--plan-mode-required`, `--parent-session-id`, `--teammate-mode` | §39.2.5 | Root flags; work headless | P | |
| `teammateMode` setting (`auto`/`tmux`/`iterm2`/`in-process`), `/config` row `Teammate mode` | §39.2.6 | `get_settings`/`update_settings` | R | For a GUI the only sane value is `in-process` — tmux/iterm2 backends spawn terminal panes. |
| Eight-colour teammate palette, round-robin from a persisted index; lead gets `red`, first teammate `blue` | §39.3.3 | Colour is in the `<teammate-message>` envelope's `color=` attribute | P | |
| On-disk layout `~/.claude/teams/<slug>/config.json` + `inboxes/<agent>.json` (+ `.lock` files) | §39.4 | Readable from disk; the permission layer explicitly allows reading the whole `teams/` tree | R | A GUI can render the roster by reading the team file directly. |
| `<teammate-message teammate_id=… color=… summary=…>` envelope, batched and wrapped in the shared peer preamble when the recipient is the lead | §39.15.6 | **On the wire**: the headless lead drains its mailbox on a 500 ms loop and enqueues the batch as a `prompt`, which `--replay-user-messages` echoes as a `user` frame [`chunk-2rhzyjym.js:176734`] | P | So a GUI *can* render team traffic — it parses `<teammate-message>` out of the replayed user frame. |
| Eleven protocol frames intercepted rather than delivered (`permission_request`, `permission_response`, `sandbox_permission_*`, `shutdown_*`, `team_permission_update`, `mode_set_request`, `plan_approval_*`) | §39.16.1 | Intercepted before the model, so **not on the wire** | D | Permission requests from teammates surface only as an OS notification (`worker_permission_prompt`) and a local dialog. A GUI would have to read the mailbox files itself. |
| Four lifecycle frames that *are* delivered (`task_assignment`, `task_completed`, `teammate_terminated`, `idle_notification`) | §39.16.1 | Reach the model as prose, hence the wire | P | |
| `SendMessage` routing table: `main`, `agent-live`, `agent-stopped`, `agent-evicted`, `local-session` (uds), `cloud-session` (bridge), `mailbox` | §39.16.4 | Tool call, so fully on the wire | P | |
| 16 `SendMessage` validation refusals (`broadcast (to: "*") is no longer supported…`, `to must be a bare teammate name…`, …) | §39.16.5 | In `tool_result` | P | |
| Teammate name resolution, ambiguity messages, Levenshtein-≤2 suggestion | §39.16.6 | In `tool_result` | P | |
| `TaskStop` accepts a teammate by agent id or bare name | §39.16.7 | `stop_task` control request also exists | P | |
| Lead-side inbox poller (1 s timer, eight-bucket partition, drops `team_permission_update`/`mode_set_request`) | §39.17 | Runs headless too (the headless lead has its own 500 ms drain, §39.21.5) | P | |
| Teammate permission relay: request minted as `perm-<epochMs>-<7 base36>`, forwarded over the mailbox, lead renders a dialog with `requestSource: {type:"subagent", agentName}` | §39.19 | The lead's dialog is a **local** permission dialog, not a `can_use_tool` to the host | D | A GUI hosting a lead would not be asked. Workaround: none within the protocol. |
| Plan-approval relay; teammate panel shows `awaiting approval` | §39.20, §39.24.1 | Frames intercepted | D | |
| Task panel rows for in-process teammates (`teammate` label, `idle`/`awaiting approval` elapsed states, idle collapse past 3 rows with a summary row) | §39.24.1 | `task_started`/`task_updated`/`task_progress`/`background_tasks_changed` frames carry the underlying registry state | R | A GUI rebuilds the panel from task frames. |
| Session badge `@name` in the teammate's colour, or `View teammates: \`tmux -L claude-swarm-<pid> a\`` | §39.24.2 | — | T | The tmux hint is meaningless in a GUI. |
| Lifecycle notifications `1 teammate started` / `N teammates shut down`, folded, `timeoutMs: 5000` | §39.24.3 | — | R | |
| Mode-change warning `/model changes the team lead's model, not this teammate's` | §39.24.4 | — | R | |
| Per-frame teammate panels (`Shutdown request from …`, `Plan Approval Request from …`, `Plan Approved by …`, `Teammate terminated (from …)`, `<n> … shut down gracefully`) | §39.24.6 | The text is inside replayed `user` frames | R | Parse and render as cards. |
| Headless team teardown: a `<system-reminder>` forces the lead to shut its team down before answering, with a 10 s park timeout (`CLAUDE_CODE_TEAM_TEARDOWN_PARK_TIMEOUT_MS`, 1 000–60 000 ms) | §39.21.5 | This *is* the headless path | P | If afleet ever enables teams, closing stdin will block on this. |

## 39.3 `/list-agents`, `ListAgents`, `/agents`, `/subtask`, `/fork`, `/background`

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/list-agents` (alias `peers`) — `local`, **`supportsNonInteractive: true`** | §39.25, SPEC 28 row 611 | **Present in the headless command list [live]** | P | afleet can invoke it as a prompt-line command and render `local_command_output`. |
| `ListAgents` tool (alias constant `ListPeers`), `isEnabled()` === `Vo()` (cross-session messaging gate, default on) | §39.25, SPEC 38 §38.26.1 | **Present in the headless `system/init.tools` list [live]** | P | Output is `{ listing: string }` — a pre-rendered block, not structured rows. |
| `ListAgents` model-facing row format: sections `Subagents` / `Teammates` / `Peer sessions`, rows `"  " + [primary, …extras].join("  ·  ")`, 100-row cap, self line | SPEC 38 §38.26.3 | Same string in the `tool_result` | R→D | **The listing is a formatted string, not structured data.** A GUI wanting a real roster must either parse the block or read `~/.claude/sessions/*.json` itself. Reading the registry is strictly better and is what afleet should do. |
| `/list-agents` user-facing format `  [<status>]  ·  <name>  ·  <agentType>  ·  started <duration> ago` | SPEC 38 §38.26.4 | Arrives as `local_command_output` | P | |
| Nine degraded-listing notes (`(the session list on this machine could not be read just now …)`, `(the Remote Control session list for your account did not complete just now …)`, …) | SPEC 38 §38.26.3–4 | In the same string | P | |
| Name-shadow notes (`not messageable by name while a subagent in this session is registered under that name`, `message it by this exact name as printed — no [ref]`) | SPEC 38 §38.26.3 | Same | P | |
| Former-name note `says it was <name> until <duration> ago`, shown within 10 min | SPEC 38 §38.26.3 | Same | P | |
| `/agents` — `local`, description begins `(removed)` | §39.25, SPEC 28 row 556 | **Present in the headless command list [live]** with the same `(removed)` description | P | Tombstone; render nothing. |
| `/subtask` — `local-jsx`, `Send a subagent off with your full context; its result comes back here`, enabled only when FleetView is on and not coordinator mode | SPEC 28 row 657 | **Absent headless [live]**; `local-jsx` never works headless | X | Rebuild: afleet sends a `user` frame that asks for a `Task` call, or drives `Task` through its own affordance. |
| `/fork` — `local-jsx`; description flips: FleetView on → `Copy this conversation into a new background session and keep working here`; off → `Spawn a background agent that inherits the full conversation` | SPEC 28 row 596 | **Absent headless [live]** | X | The **copy variant** is the interesting one for afleet: "copy this conversation into a new background session". Rebuild by starting a second child with `--resume <sessionId>` (which continues) or by replaying the transcript. There is no control request that forks a session. |
| `/background` (alias `bg`) — `local-jsx`, `Send this session to the background and free the terminal`, registered only when FleetView is on | SPEC 28 row 563 | **Absent headless [live]** | X→T | Meaningless for a GUI-hosted session: afleet's window *is* the foreground, and the child already survives. |
| Coordinator-mode refusals (`Forking is not available in coordinator sessions. Use /branch instead.`, `Subtasks are not available in coordinator sessions. Use /branch instead.`) | §39.30 | Only reachable if `CLAUDE_CODE_COORDINATOR_MODE` is set | R | |

## 39.4 Coordinator mode

Coordinator mode is **suppressed in a locally interactive session** and is explicitly a
headless / hosted-surface mode (`Rs()` returns false when `qu()` and not remote, §39.2.2) — so it
is one of the few features where headless is the *primary* surface.

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Enabling: env `CLAUDE_CODE_COORDINATOR_MODE` only; **no flag, no slash command** | §39.2.2, §39.26.3 | Set the env var when spawning the child | P | afleet controls this at spawn time. |
| System prompt replaced by `getCoordinatorSystemPrompt`; `--system-prompt` still wins, `--append-system-prompt` still applies | §39.26.1 | Same | P | |
| Built-in agent roster collapses to exactly one agent, `worker` | §39.26.1 | Visible in `initialize.agents` and `system/init.agents` | P | afleet can detect coordinator mode by observing a one-entry agent list. |
| Tool set filtered to `{Agent, TaskStop, SendMessage, StructuredOutput, Skill, ReadNotifications, ListAgents, Workflow}` plus PR-subscription tools, comms-roled MCP tools, `CLAUDE_CODE_COORDINATOR_EXTRA_TOOLS` | §39.26.2 | Visible in `system/init.tools` | P | |
| Fork subagents disabled unconditionally (`CLAUDE_CODE_FORK_SUBAGENT=1` cannot re-enable) | §39.30 | Same | P | |
| `Skill` becomes read-only for the coordinator | §39.30 | Prompt text | P | |
| Resume-time mode matching messages (`Entered coordinator mode to match resumed session.` / `Exited …`) | §39.26.3 | Surfaced as **stderr in print mode** [`chunk-2rhzyjym.js:179150`], not as a frame | D | afleet must read child stderr to catch it. Workaround: infer from the one-entry agent roster in `system/init`. |
| Mode persisted after every turn (`saveMode("coordinator"\|"normal")`) | §39.26.3 | Same | P | |
| The `coordinator` origin kind on inbound user frames (`The coordinator sent a message`) | §39.30 [`chunk-v866bw1e.js:754039`] | `origin.kind === "coordinator"` is a published member of the `user` frame origin union (SPEC 45.15.1) | P | Renderable. |

## 39.5 `/team-onboarding` (human teams, not agent teams)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/team-onboarding` — **`type: "prompt"`**, `allowedTools: ["Edit(ONBOARDING.md)", "Bash(ls *)", "ShareOnboardingGuide"]`, org policy `allow_team_onboarding`, `disableModelInvocation: true`, `requires: {workspace: true}`, `progressMessage: "scanning usage data"`, `effort: "low"` | §39.31.1, SPEC 28 row 659 | **Present in the headless command list [live]** — a `prompt` command works headless unless `disableNonInteractive` | P | Full parity; afleet just sends `/team-onboarding` as a user turn. |
| The guide template and authoring prompt, replaceable by `tengu_flint_harbor_prompt` (window clamped 1–365 days, default 30) | §39.31.2–3 | Prompt text | P | |
| `ShareOnboardingGuide` tool | §39.31.5 | Not in this session's tool list **[live]** — gated by the same policy | P | |

---

## 38.1 The daemon, routines and scheduled tasks

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/daemon` — `local-jsx`, `Manage background services and routines`, `immediate: true` | §38.15 | **Not registered at all in 2.1.257**: `isDaemonWorkerRegistryEnabled()` is a literal `false`, so `/daemon` is absent from the TUI *and* headless. Confirmed absent from the live command list **[live]** | — | Nothing to port. The implementation ships but is unreachable. |
| The daemon hub screen (sections `Scheduled` / `Remote Control`; columns `Name/Schedule/Next run/Last run/PID` and `Name/Directory/Status/PID`; the four header forms; 1 000 ms refresh) | §38.15 | `claude daemon hub` refuses without a TTY: `Interactive hub requires a TTY. See \`claude daemon --help\`.` | X→R | The best available blueprint if afleet ever surfaces routines. Data source is `~/.claude/daemon.json` + `daemon.status.json`, both readable from disk. |
| `~/.claude/daemon.json` `remoteControl[]` and `tasks[]` entry schemas (`.strict()`; `permissionMode` default `dontAsk`, `runTimeoutMinutes` default 30 max 10 080, `maxQueued` default 1, `maxConcurrent` default 1, unique ids) | SPEC 36 §3.6, SPEC 22 §22.5 | Readable and writable from disk; the daemon supervisor watches the file | R | The `scheduled` worker kind is gated off in this build (§38.2), so writing tasks there does nothing today. |
| `/loops` — `local-jsx`, `List, create, and delete loops`, **`isEnabled: () => false`** | SPEC 22 §22.20, SPEC 28 row 614 | Absent from the TUI and headless **[live]** | — | Its dialog (`Loops`, `Recurring crons and stop-hooks active for this session`, rows `<human> · <prompt≤50> · <id>`, `d` delete / `n` new, create screen with `every`/`until` radio) is the only surface that shows crons and goals together — a good GUI blueprint, nothing more. |
| `CronCreate` / `CronList` / `CronDelete` tools | SPEC 22 §22.9–§22.10 | **All three appear in the headless `system/init.tools` list [live]** | P | The GUI sees create/list/delete as ordinary tool calls; it can also drive them by prompting. |
| Durable cron store `<projectRoot>/.claude/scheduled_tasks.json` (`{tasks:[{id, cron, prompt, createdAt, recurring?, permanent?, createdBySessionId, createdByPid, createdByProcStart}]}`) | SPEC 22 §22.5 | On disk; defensive loader drops malformed entries | R | afleet can render and edit the schedule directly. Session-only tasks live in memory and are invisible on disk. |
| `ScheduleWakeup` (dynamic loops) | SPEC 22 §22.11 | **In the headless tools list [live]** | P | |
| `Monitor` tool (long-running watch that emits task notifications; its prompt carries the `PushNotification` suffix when push is on) | §50.11, SPEC 22/23 | **In the headless tools list [live]** | P | Its events reach the host as `task_notification` / `task_progress` frames. |
| `scheduled_task_fire` record: `{type:"system", subtype:"scheduled_task_fire", content, isMeta:false, timestamp, uuid, taskId, cron, prompt (≤200 chars), taskKind?, cronKind?, noOpStreak?, streakStartedAt?, foldedUuids?}` | SPEC 22 §22.17 | Listed in SPEC 45.9.1 as an "internal surfaces" `system` subtype, so it can reach the wire | P | Visible line for a loop fire is `Claude resuming /loop wakeup (Mon D h:mmam)`; a sentinel prompt is relabelled `/loop` or `/loop (loop.md)`. Rendered dim in the TUI — a GUI should render it as a timeline marker. |
| The no-op streak fold (collapses quiet dynamic-loop ticks; seven veto reasons) | SPEC 22 §22.18 | The fold is written into the record (`noOpStreak`, `foldedUuids`), so a host can honour or ignore it | P | A GUI can do better: show the folded ticks behind a disclosure triangle instead of hiding them. |
| `RemoteTrigger` tool | — | **In the headless tools list [live]** | P | |
| Registry worker kinds `heartbeat` / `scheduled` / `remoteControl`; only `heartbeat` is admitted (`r === "heartbeat" \|\| PK()`) | §38.2, §38.9.1 | — | — | |
| Daemon origins `service` / `foreground` / `transient`; only `transient` idle-exits and can be displaced | §38.3 | — | R | Matters if afleet spawns background jobs: the daemon it starts on demand is `transient` and will idle-exit. |
| `daemonColdStart` setting (`transient` / `ask`) and the cold-start install prompt | §38.14.2, §38.30 | `get_settings`; the prompt is a TTY dialog | X | afleet should set `daemonColdStart: "transient"` so the child never tries to prompt. |
| `disableAgentView` disables background agents, `--bg`, `/background` and the on-demand daemon | §38.30 | `get_settings` | P | |

## 38.2 The session registry (`~/.claude/sessions/<pid>.json`)

**This is the decisive finding for whether afleet's owned channels appear to other tools as live
sessions. They do — but silently.**

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Every eligible process writes `~/.claude/sessions/<pid>.json` (mode 0600 in a 0700 dir, unlinked on exit); registration is skipped for subagents and certain embedded modes | §38.18.1 | **A headless `-p --input-format stream-json` process writes its own record. [live]** Observed: `{pid, sessionId, cwd, startedAt, procStart, version:"2.1.259", peerProtocol:1, peerFeatures:["notify_idle","reply_across_default_dirs","artifact_yield"], kind:"interactive", entrypoint:"sdk-cli", pidDomain:"darwin", messagingSocketPath:"/tmp/cc-socks/<pid>.sock", name:"tmp-32", nameSource:"derived", nameSince}` | P | So an afleet-hosted channel **is** discoverable and addressable by `ListAgents`, `SendMessage`, `/list-agents` and any other tool that reads the registry. Note `kind` is `"interactive"`, not `"bg"`. |
| `status` ∈ `busy` / `shell` / `idle` / `waiting`, plus `waitingFor` (e.g. `"dialog open"`), `state`, `detail`, `tempo` ∈ `active`/`idle`/`blocked`, `needs`, `updatedAt`, `statusUpdatedAt` | §38.18.1 schema | **A headless session never writes any of them. [live]** Nine live TUI sessions on this machine all carry `status` (`idle`/`busy`/`waiting` with `waitingFor: "dialog open"`); the two headless probes carried none — including across a full completed turn | **D** | **Load-bearing gap.** afleet's channels appear in every peer listing as sessions of *unknown* activity, so a human or an agent using `/list-agents` cannot tell whether a channel is busy. There is no control request to publish status. Workarounds, in order of preference: (a) afleet writes the fields into the child's registry file itself — the schema is public, the file is per-pid and readable/writable by the same uid, and the reader is defensive about unknown/mistyped fields; (b) accept the gap and rely on the fact that `SendMessage` still works. `tempo` was `null` on **every** record observed, TUI included, so it may be write-dead in 2.1.259. |
| `name` / `nameSource` (`user`/`peer`/`derived`/`collision`/`auto`/`hook`) / `nameSince` / `formerNames` (≤ 3, each ≤ 200 chars) | §38.18.1 | `nameSource: "derived"` when no name is given **[live: `tmp-32` from cwd `/private/tmp`]**; `CLAUDE_CODE_SESSION_NAME` seeds it with source `user` (§38.29) | P | afleet passes `-n`; that is what makes a channel addressable by a meaningful name. Also settable at runtime with the `rename_session` control request. |
| `peerFeatures` filtered to `/^[a-z0-9_]{1,32}$/`, ≤ 16; three advertised: `notify_idle`, `reply_across_default_dirs` (non-Windows with `Bun.ant.getPeerPid`), `artifact_yield` | §38.18.1 | Same in headless **[live]** | P | |
| Key files `<pid>.<sha256(canonicalSocketPath)>.key` holding a 32-hex `peerToken`; a separate `childToken` exported as `CLAUDE_CODE_MESSAGING_TOKEN` distinguishes descendants from peers | §38.18.2 | Written by headless sessions too **[live: a `.key` file exists beside every `.json`]** | P | Auth is mandatory only on Windows (§38.18.3). |
| Defensive reader: non-`/^\d+\.json$/` names skipped, non-round-tripping names deleted, 262 144-byte cap, wrong-typed fields dropped, torn reads retried once after 25 ms | §38.18.1 | Same | P | This is what makes workaround (a) above safe: extra or wrong fields are dropped, not fatal. |

## 38.3 The messaging socket and cross-session traffic

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `messaging_socket_path` in `system/init` | §45.10.4 | **Present in the headless `system/init` [live: `/tmp/cc-socks/34882.sock`]**; blanked to `undefined` in the redacted bridge variant (§45.10.5) | P | What a GUI can do with it: (1) label the session's own address; (2) hand it to other tooling; (3) **send a `user` frame to another session directly over its socket** — but afleet should not do this, because it already owns stdin for its own children and the UDS path re-implements auth, pacing and the peer-loop guard. Its real value is read-only: it tells afleet the child is reachable and gives the exact address other agents will use. |
| Startup binding is skipped for a remote thin client and when the `tengu_harbor_kite` gate is off (default on), with a late-bind hook on the next gate refresh | §38.16 | Headless binds **[live]** | P | |
| `<cross-session-message from=… from-session=… hop-chain=… from-name=… from-mode=…>` envelope, fixed attribute order, round-trip-verified parsing, closing-tag escaping | §38.23.1 | Arrives inside a `user` frame with `origin.kind === "peer"`; `--replay-user-messages` echoes it | P | A GUI parses the attributes and renders a peer card. It should **not** show the model-facing preamble/trailer verbatim. |
| The five preamble headers and four trailers (`Another Claude session sent a message while you were working:` … the permission-laundering paragraph) | §38.23.2 | Same text on the wire | P | |
| The `crossSessionInbound` gate: `accept` / `hold` / `refuse`, repo scopes may only tighten, invalid values force `hold`; unset → mode parity (`bypass↔bypass` / `prompting↔prompting`) | §38.22.1–2, §38.30 | `get_settings` / `update_settings`; the setting's verbatim description is in the schema | R | afleet must decide a default for its channels. `refuse` is the safest for a channel that only relays external traffic. |
| The held-message dialog (`Held message from another session`, `Deliver this message to Claude` / `Deny — drop it and tell the sender it was declined`, eight cause explanations, sanitised preview with `…[<n> lines, <n> chars total — expand to review before approving]`) | §38.22.5 | **This is a locally-raised dialog, not a `request_user_dialog`.** A headless session with a held message parks it with no way to ask the host | D | Workaround: set `crossSessionInbound: "accept"` or `"refuse"` explicitly so `hold` never happens. Otherwise messages silently accumulate (buffer capacity 100). This is a real footgun for afleet. |
| Eight remediation sentences shown outside the dialog | §38.22.5 | — | R | |
| Peer-loop guard (bucket 30 @ 0.5/s, 30 s dedup, 10 self-hops, 28-hop chain, 50 queued) and the five drop reasons; user-visible line `Dropped a peer message from @<name> (<from>): <explanation>.` | §38.21 | The drop line is a local UI notice | D | Not on the wire; afleet cannot show why a peer message vanished. |
| Sender pacing with the `Too many messages to this session just now…` refusal | §38.20.4 | In the `SendMessage` `tool_result` | P | |
| `isolatePeerMachines` setting (`Require explicit approval before SendMessage can reach a peer session on another machine via Remote Control`) | §38.30 | `get_settings` | R | |
| `notify_when_idle` subscription and the four `[Cross-session idle notice]` texts (idle / exited / not-holding / expired-after-12 h) | §38.25 | Delivered into the subscriber's conversation, hence on the wire | P | The receiving session also shows its *user* a notice about the subscription itself (`A process claiming the address <addr> asked to be told when this session is next idle…`) — that one is local UI only, class D. |
| `[Cross-session idle notice]` one-line UI renderings | §38.25.3 | — | R | |

## 38.4 Background job verbs and `claude agents --json`

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Six positional verbs routed before Commander: `claude logs\|attach\|stop\|kill\|respawn\|rm <short>` (plus `--bg`/`--background`) | §38.28.1 | Separate processes, all gated on `isAgentsFleetEnabled()` | R | afleet shells out to these, or reimplements against the daemon control socket. |
| `claude agents --json` — the documented machine-readable listing, offered by name when stdout is not a TTY | §39.32.2 [`chunk-c7eymqh7.js:439479`] | Separate process | R | **The recommended out-of-band way for afleet to enumerate background jobs.** The interactive `claude agents` refuses a non-TTY stdout. |
| `claude attach <short>` collision hint `Session <short> is already running — \`claude attach <short>\` to join it` | §38.28.1 | — | R | |
| The daemon control socket (18 ops, newline-delimited JSON, peer-uid verified) | §38.11 | Reachable by any same-uid process | R | The lowest-level and most complete route; also the most coupled to internals. Prefer `claude agents --json`. |
| `claude ssh` | §38.28.2 — **dead**, no `.command("ssh")` exists | — | — | |
| The complete Commander subcommand set (43 verbs) | §38.28.2 | — | — | Useful inventory for anything afleet wants to shell out to. |

---

## Top gaps in this area

Ranked by impact on afleet.

1. **A headless session never publishes `status`/`waitingFor`/`tempo` into `~/.claude/sessions/<pid>.json`, though it does write the record itself (38.2, class D, [live]).** Every afleet-owned channel is discoverable and addressable by `ListAgents`/`SendMessage`, but appears with unknown activity to every other tool and agent on the machine. Recommended workaround: afleet writes the status fields into the child's registry file directly — the schema is public and the reader is defensive.
2. **A headless-hosted session *can* be Remote-Controlled from claude.ai mobile (36.6, class P).** `Twn()` has no interactivity check, the `remote_control` control request lives in the headless dispatcher, and this machine reports `remote_control_available: true` in a headless `initialize` [live]. This is the single highest-leverage capability in this area: it makes afleet channels reachable from the phone. It costs afleet its own consent card (the CLI's one-time dialog is bypassed) and a handler for permission requests answered elsewhere.
3. **The `remote_control` control request's schema is unpublished but fully recovered (36.4, class P), and it emits an undocumented `system/bridge_state` frame** carrying `state`, `detail` and `bridge_epoch` on every transition. That gives afleet complete connection-state parity with the TUI status line for free — but only if it knows to listen for a frame that is in no SPEC frame table.
4. **`origin` on the `user` frame is the whole channel-attribution story, and it is on the wire (50.6, class P).** `origin.kind ∈ human|channel|peer|task-notification|coordinator|…` with `origin.server` for channels. afleet gets first-class attribution for channel and peer traffic without parsing prose — provided it keeps `--replay-user-messages` and stamps `{kind:"human"}` on its own input (absent origin fails closed at strict `isHuman()` gates).
5. **`PushNotification`'s `user_present` guard is blind to the GUI (50.3, class D).** `TPn()` reads terminal focus, which a headless process never has, so the tool will push even when the human is looking at afleet. Fix by maintaining `CLAUDE_CLIENT_PRESENCE_FILE` while the window is focused, and/or setting `CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK` and deciding in the GUI.
6. **The `os_notification` message — the local half of every OS notification, including `PushNotification` and computer-use enter/exit — is dropped before the wire (50.1, class D).** afleet must synthesise native notifications from `tool_use` blocks and hook events. The `Notification` hook is the only complete channel: register one and read `hook_response` frames.
7. **A held cross-session message parks with no way to ask the host (38.3, class D).** The held-message dialog is locally raised, not a `request_user_dialog`. A headless channel left on the default `crossSessionInbound` (mode parity) can silently accumulate up to 100 held messages. afleet should set the value explicitly.
8. **`away_summary` is unreachable (50.8, class D).** Its only trigger is the terminal focus subscription; no control request reports host focus. A GUI genuinely knows about focus, so this is an opportunity as much as a gap — afleet can generate a better recap than the TUI.
9. **`--dangerously-load-development-channels` is unusable headless (50.6, class X)** because its startup confirmation dialog needs a TTY. Channels must therefore be marketplace plugins on the org allowlist or the `tengu_harbor_ledger` dynamic config — and in an offline or flag-less build the ledger is `[]`, so **no `plugin:` channel can register at all**. This is a deployment risk worth designing around now. `channel_enable` at runtime is the supported alternative and works headless.
10. **`queued_notification` and `session_notice` are server-authored-only and refused from the stdin lane (50.5, class X).** The obvious "afleet injects an external event as a notification" design is closed. The sanctioned host→model event channel is `poll_event`, which requires `CLAUDE_CODE_POLL_EVENTS=true` **and permission mode exactly `auto`**.
11. **`ListAgents` returns a formatted string, not structured rows (39.3, class D).** afleet should read `~/.claude/sessions/*.json` directly for its roster and use `ListAgents` only for the model.
12. **Every `local-jsx` command in this area is unreachable headless and confirmed absent from the live command list (class X):** `/remote-control`, `/mobile`, `/subtask`, `/fork`, `/background`, `/loops`, `/daemon`. `/radio`, `/stickers` and `/install-slack-app` are `local` with `supportsNonInteractive: false` and equally absent. All are cheap rebuilds except `/fork`'s copy variant, which has no protocol equivalent. `/wellbeing` and `/loops` are `isEnabled: () => false` in 2.1.257 — they are absent from the TUI too, so there is nothing to port.
13. **`--prompt-suggestions` is free parity afleet is not currently taking (50.8, class P).** It emits `{type:"prompt_suggestion", suggestion, uuid, session_id}` after each turn. It requires `--print` and `--output-format=stream-json`, both of which afleet already passes, and it costs a forked model call per turn.
14. **The push-preference server mirror diverges silently (50.2, class D).** Flipping `agentPushNotifEnabled` through `update_settings` does not PATCH `/api/claude_code/notification/preferences`, because only the CLI's own `/config` handlers call the writer. afleet must PATCH it itself or accept that the phone's push preference and the local setting drift apart.
15. **Teammate protocol frames (permission requests, plan approvals, shutdown handshakes) are intercepted before the model and never reach the wire (39.2, class D).** Out of afleet v1 scope, but any later version that wants teams-as-channel-members will have to read `~/.claude/teams/<slug>/inboxes/*.json` from disk to render them. Lifecycle frames and `<teammate-message>` prose *do* reach the wire, so a read-only team view is achievable.

---

## Unverified

Things inferred rather than read, and live probes whose scope should be understood.

**Live probes run for this document (2.1.259, macOS, this machine):**

* `/tmp/afleet-gap/reg-probe.py` — spawned `claude -p --input-format stream-json --output-format stream-json --verbose …` in `/tmp`, sent one `initialize`, then inspected `~/.claude/sessions/`. Result: the parent pid has a record; its two children do not. Record contents quoted verbatim in 38.2.
* `/tmp/afleet-gap/reg-probe2.py` — same, plus one complete turn (`--permission-mode plan`, Haiku, prompt "Reply with the single word: ok"), polling the registry file every 250 ms throughout. Result: `status`, `tempo`, `waitingFor`, `state`, `detail` were absent at every sample and in the final file. Compared against 14 live registry records on this machine, of which every `entrypoint: "cli"` record carried `status` and none carried `tempo`.
  * **Caveat:** one turn in one permission mode. I did not test a turn that raises a permission prompt (which is where `waitingFor: "dialog open"` appears on TUI sessions), nor a long-running turn. It is possible — though the code path I read does not suggest it — that `status` is written only from a code path that a plan-mode Haiku turn never reaches. Treat "headless never writes status" as strongly evidenced, not proven.
* `initialize` and `system/init` field values quoted as **[live]** come from `/tmp/afleet-gap/init-dump.json` and `/tmp/afleet-gap/turns.ndjson.log`, captured before this task.

**Inferences, not reads:**

* **That `bridge_state` frames actually reach stdout.** I read the enqueue site (`cli.pretty.js:178527`) and confirmed `bridge_state` is in neither the 45.9.2 `Cu` drop list nor any other filter I found, and that the `bt` queue at that site is the same queue used for `auth_status`, `active_goal` and `prompt_suggestion` (all of which do reach stdout). I did not observe a `bridge_state` frame, because that would require enabling Remote Control on a live session.
* **That the `remote_control` request succeeds end-to-end on this machine.** I recovered the schema from the handler and confirmed the eligibility predicate has no interactivity check and that `remote_control_available: true` is reported live. I did not actually send the request, because doing so publishes a session to claude.ai. The refusal branches I quote are read from the handler, not observed.
* **`connect_url` for a REPL bridge.** `Uo()` builds it as `hst(f.environmentId, …)` and §7.7 states `environmentId` is always `""` for the REPL bridge, so `connect_url` should be `https://claude.ai/code?environment=`. I did not observe the actual string.
* **That `channel_enable` works from a stdio host in practice.** The handler is unambiguously in the SDK dispatcher and I read its full body, but I did not exercise it — that would need a channel-capable marketplace plugin on the ledger.
* **The exact `origin` value on a replayed channel turn.** I read the enqueue site (`origin: {kind:"channel", server}`) and the replay site (`...ee && {origin: ee}` where `ee = M6(H.origin)` passes non-task-notification origins through unchanged), and SPEC 45.15.1 confirms `channel` is a published member of the origin union. I did not capture such a frame.
* **Whether `tempo` is written anywhere in 2.1.259.** It is in the registry schema (§38.18.1) and was `null` on all 14 live records including TUI sessions. I did not locate a writer. It may be write-dead.
* **`/wellbeing`'s dialog content.** SPEC 28 records it as `local-jsx` with `isEnabled: () => false`; I did not read its implementation, since it is unreachable in both surfaces.
* **The `#`-channel autocomplete rebuild path.** I confirmed the TUI calls `slack_search_channels` via MCP with `limit: 20, channel_types: "public_channel,private_channel"` and that `mcp_call` is a host-available control request, but I did not verify that `mcp_call` can reach that particular tool without a permission prompt.
