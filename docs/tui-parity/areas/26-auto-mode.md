<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

> **Errata from live probes (see ../README.md §4 and ../evidence/):**
> - Top gap 14 says `sandbox_network_access` is a reachable dialog kind that fails closed if undeclared. The headless dialog dispatcher (`cli.pretty.js` 174428) forwards only `refusal_fallback_prompt`, `fable_overage_consent_prompt`, the Slack-connect kinds and MCP elicitation; `sandbox_network_access` resolves to its default `cancelled` regardless of `supportedDialogKinds`. The network prompt that does reach a host is the `can_use_tool` path (A-15/16/17).

# 26 — Auto mode: TUI-vs-headless UX gap inventory

Source chapter: `SPEC/26-auto-mode.md` (5428 lines), read in full except the verbatim
classifier rule text in §26.10.4/§26.11.5. Cross-checked against `cli.pretty.js` and
against a live 2.1.259 binary on this machine (probes: `/tmp/afleet-gap/init-dump.json`,
`/tmp/afleet-gap/probe-automode.py`, `/tmp/afleet-gap/probe-amsetup.py`).

**Live baseline for this machine.** `initialize` reports `current_permission_mode: "auto"`,
and `get_settings.effective.permissions.defaultMode` is `"auto"` from **userSettings** — so
auto is chosen explicitly, not by fallback. `get_settings.effective.autoMode` already carries
a filled-in 23-entry `environment` array plus five custom `allow` rules, i.e. the owner has
already run `/auto-mode-setup`. Both of those facts matter for the gap list: the GUI must
render an auto-mode session as the *normal* case, and it must not clobber an existing
`autoMode` block.

Classification letters are the brief's: **P** parity via protocol, **R** rebuild,
**D** data gap, **X** unreachable, **T** terminal-specific.

---

## 26.1 What auto mode is, and how the user is told

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Auto-mode explainer text | `AUTO_MODE_DESCRIPTION` = base + optional cost sentence + warning; shown on first entry and in the mode picker (§26.1 "User-visible description", `chunk-k0m28mtv.js:575345-575351`) | Not on the wire in any form | R | Three constants; the GUI hard-codes them. The cost sentence (`Sessions are slightly more expensive.`) is dropped for `pro`/`max`/`team` — the GUI can decide this from `initialize.account.subscriptionType` (live dump reports `subscription_type: "max"` via `get_usage`). |
| Mode label / symbol / colour for `auto` | Mode descriptor table: `title "Auto"`, `shortTitle "Auto"`, `indicator "auto mode"`, `symbol "⏵⏵"` (U+23F5 ×2), `color "warning"` (`chunk-yte5spsr.js:839628`) | `system/init.permissionMode` and `system/status{status:null,permissionMode}` carry only the bare string `"auto"` (SPEC 45:1138, 45:1612-1624) | R | The GUI has the mode; it must supply its own label, glyph and colour. A GUI can exceed the TUI here — a persistent, always-visible auto badge rather than a footer line. |
| "Auto mode is now Claude Code's default permission mode." one-shot notice | Three constants + docs URL (`chunk-bq8epagv.js:389222`), gated by `Mrt()` on `isAutoModeFromFallback() && !hasSeenAutoDefaultNotice` (§26.1) | Never emitted: the gate also requires the TUI store, and the field that would tell a host (`permission_mode_from_default_fallback`) is emitted only when `p1()` — entrypoint `claude-vscode` (`cli.pretty.js:178998`; verified absent in both live probes) | D | A GUI cannot learn "you are in auto because it is the default." Workaround: read `permissions.defaultMode` from `get_settings.effective` and compare — absent/`"default"` + `current_permission_mode: "auto"` implies fallback. |
| One-time entry warning posted into the transcript | 800 ms after first render in auto mode, appends `getAutoModeDescription()` as a `notice` message; suppressed on fallback entry and by `skipAutoPermissionPrompt` (§26.1 "The entry warning", `chunk-bq8epagv.js:431036-431059`) | The effect lives inside the Ink REPL render (`Vit(G$e, Loi)` at `cli.pretty.js:433777`), so it never runs headless | X | The GUI must decide its own first-run disclosure. `skipAutoPermissionPrompt` is readable via `get_settings` (live: `true` on this machine) and is purely a disclosure suppressor — it does not change classifier behaviour (§26.1). |
| "Make auto mode your default permission mode?" nudge dialog | Ink dialog: title `Make auto mode your default permission mode?`, body = the PYt paragraph, options `Yes, set auto mode as my default permission mode` / `No, keep <mode>`; accepting writes `permissions.defaultMode: "auto"` to userSettings (`cli.pretty.js:416876-416906`, `chunk-37wfp6n8.js:198668-198690`) | `initialize.auto_default_nudge` exists but is gated on `p1()` (IDE entrypoint only), and the resolution channel is the `claude-vscode` MCP `log_event` bridge (SPEC 33 §33.18, lines 2080-2092) | X | Unreachable over the stdio protocol. A GUI wanting the same nudge builds its own dialog and writes `permissions.defaultMode` itself (userSettings is not writable over the wire — see §26.19 row). |

---

## 26.2 Availability: the gate, the killswitch, the reasons, org policy

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `isAutoModeGateEnabled()` composite gate | Not circuit-broken **and** not `disableAutoMode` **and** the main model supports auto (§26.2, `chunk-1kg58a1a.js:99381-99388`) | No direct query. `set_permission_mode {mode:"auto"}` succeeds or fails and the failure text names the reason | R | **Verified live:** `set_permission_mode` → `{"subtype":"success","response":{"mode":"auto"}}`. The GUI's cheapest availability probe is an actual mode switch. |
| The four unavailable strings | `auto mode disabled by settings` / `auto mode is unavailable for your plan` / `auto mode unavailable while fast mode is on · run /fast off` (`·` = U+00B7) / `auto mode unavailable for this model`; fallback `auto mode is unavailable right now` (§26.2 table, `chunk-1kg58a1a.js:99290-99311`) | Surfaced only through `guardPermissionModeChange`: a rejected `set_permission_mode` returns `Cannot set permission mode to auto: <reason text>` (§26.3, `chunk-qxbh07cn.js:648472`, dispatched via `Cm` at `cli.pretty.js:173907` → the control-response error at `cli.pretty.js:177259-177267`) | P | The exact human-readable reason reaches the wire, but **only as the error string of a rejected mode switch**. A GUI that wants to grey out an "Auto" toggle proactively must attempt the switch and undo it, or read `disableAutoMode` from `get_settings`. |
| `auto-mode-gate-notification` (gate closed mid-session) | `verifyAutoModeGateAccess` pushes a `{kind:"warning", priority:"high"}` entry into the app-state notification queue and rewrites the context back to `default` (§26.2, `chunk-1sbjxm06.js:163770-163772`) | The notification queue (`notifications.current/queue/pinned`) is a TUI-only ephemeral banner store (`cli.pretty.js:4612`, `660727-660783`); nothing forwards it | D | The GUI *will* see the effect — a `system/status` `permissionMode` frame flipping to `default` — but not the reason. Workaround: on an unexpected mode drop, re-attempt `set_permission_mode auto` and show the rejection text. |
| `auto-mode-unavailable` feedback banner | Fires when the mode lands on `default` from a non-auto mode while auto is unavailable; `{kind:"feedback", color:"warning", priority:"medium"}` with the §26.2 reason text (`chunk-bq8epagv.js:431060-431076`) | Same TUI-only queue | X | The effect (`RRt`) is registered in the Ink render loop; it never runs headless. |
| "Auto mode is unavailable for your plan" as an API error | An HTTP 400 naming the `afk-mode-2026-01-31` beta is mapped to this user-facing turn error (`cli.pretty.js:67934`, `67679-67681`, beta constant at `chunk-sct99ax9.js:668913`) | Turn-level errors reach the wire as the assistant/result error text (SPEC 45 §45.11) | P | The GUI renders it like any other turn error; no special handling needed beyond recognising the string. |
| Settings disablement (`disableAutoMode` / `permissions.disableAutoMode`) | Value `"disable"` from any merged source closes the gate; both are **restrictive** policy keys, so managed policy may set them and lower scopes may not relax (§26.2, `chunk-ejcy5qcd.js:486170`, `488306`, `488712`) | `get_settings.effective` exposes both keys, and `get_settings.sources` names the contributing scope | P | Live dump confirms `get_settings` returns `effective` (38 keys) plus per-source `sources`. A GUI can tell the user *which* settings file disabled auto mode. |
| `isAutoModeDisabledByPolicySettings()` — "your org did this" | Narrower check distinguishing managed policy from user settings (§26.2, `chunk-1kg58a1a.js:99377-99380`) | Derivable: check whether the `policySettings` entry in `get_settings.sources` carries `disableAutoMode` | R | Cheap to rebuild; the GUI can phrase it better than the TUI ("Your organization has turned off auto mode"). |
| Server killswitch `tengu_auto_mode_config.enabled` | Tri-state `enabled`/`disabled`/`opt-in`, anything unrecognised → `enabled`; `disabled` from an override or live payload latches the session breaker (§26.2, `chunk-1kg58a1a.js:99399-99410`, `chunk-nc9m36bp.js:609822-609827`) | Not exposed on any control request | D | Only observable as `set_permission_mode auto` failing with `auto mode is unavailable for your plan`. |
| Untrusted-source rejection of `defaultMode: "auto"` | `permissions.defaultMode: "auto"` honoured only from policy/flag/user settings; project and local are ignored with a warn log (§26.2, `chunk-nc9m36bp.js:610043-610051`) | Startup warnings go to the debug log rather than the wire when the output format is `stream-json` (`cli.pretty.js:454481-454484`) | D | A repo-level `.claude/settings.json` asking for auto mode is silently ignored. The GUI must not promise repo-scoped auto mode. |
| Auto as the *default* mode | `tengu_harbor_willow` (or `meadow_lantern`) makes auto the fallback for interactive sessions; non-interactive sessions get it only under an IDE host (`p1()`) or `tengu_moss_anchor` (§26.2 "Auto mode as the default mode", `chunk-nc9m36bp.js:609916-609924`) | A headless GUI is a non-interactive session, so it does **not** inherit the auto default | D→R | The GUI must pass `--permission-mode auto` (or set `permissions.defaultMode`) itself. Verified: launching with `--permission-mode auto` yields `current_permission_mode: "auto"`. |
| Enterprise `autoModeEnabled` (Claude Desktop / Cowork policy) | Admin toggle "Allow Auto mode", default off in 3P deployments; a Claude Code managed-settings `disableAutoMode: "disable"` overrides it and hides auto entirely (`cli.pretty.js:230097-230101`) | Same as the settings rows above | R | Worth a distinct GUI message: the option can be absent for policy reasons that are not a bug. |

---

## 26.3 Entering and leaving auto mode

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Shift+Tab mode ring | `default → acceptEdits → plan → (bypassPermissions \| auto \| default) → (auto \| default)`; `auto → default`; `dontAsk → default` (§26.3, `chunk-nzczdq15.js:631189-631215`) | `set_permission_mode` accepts any of the six modes directly (SPEC 45 §45.22.3); the CLI validates with `Sf`+`h1` then `guardPermissionModeChange` | P (better) | The ring is a keyboard affordance, not a protocol constraint. A GUI should offer a **direct mode picker** rather than replicating the cycle — strictly better UX. Note `auto` is reachable in the ring only *after* plan or bypass, which is a real TUI wart. |
| Rejection of an invalid mode | `Cannot set permission mode: must be one of acceptEdits, auto, bypassPermissions, default, dontAsk, plan` (`chunk-yte5spsr.js:839584`) | Same string returned as the control-response error (SPEC 45 §45.22.3) | P | — |
| `--permission-mode auto` at launch | Startup computes the stripped-rule list for display and enters auto (§26.4, `chunk-1kg58a1a.js:99226-99227`) | Supported on the headless command line (brief's baseline); verified live | P | — |
| Mode-change echo | Footer redraws | `system/status {status:null, permissionMode}` on every *actual* change (SPEC 45:1612-1624) | P | **Verified live:** three `set_permission_mode` calls (auto→default→auto with a leading no-op) produced exactly two `system/status` frames — a same-mode set is a silent no-op. The GUI must not expect a frame per request; use the control-response `{mode}` echo as the acknowledgement. |
| `useAutoModeDuringPlan` (plan mode keeps auto semantics) | Default `true`; **any** settings source setting `false` turns it off; non-restrictive policy key (§26.3, `chunk-ftzzbzs6.js:510143-510148`, `chunk-ejcy5qcd.js:488306`) | Readable via `get_settings`; settable for the session via `apply_flag_settings` | P/R | **Verified live:** `apply_flag_settings {"useAutoModeDuringPlan": false}` lands in `sources[flagSettings]`. |
| Plan-from-auto: read-only calls skip the classifier | Inside plan mode the classifier runs only for non-read-only calls (§26.3, `chunk-1kg58a1a.js:99251-99272`) | Invisible to the host — it changes only whether a classifier request is made | P | No GUI work; note it when explaining latency differences between plan and auto. |
| Chrome / MCP classifier floor | Certain MCP servers are routed to `auto` even under `bypassPermissions`; the Chrome family behind `chromeClassifierFloorEnabled` (§26.3 "MCP servers and Chrome", `chunk-sct99ax9.js:674186-674193`) | Not announced; the host just sees classifier-shaped denials or allows for those tools | D | Minor. If the GUI shows "bypass permissions" as "nothing is checked", that is wrong for Chrome MCP tools. |
| Browser permission dialog copy about auto mode | `This session is in Auto mode, so an AI classifier approves routine browser actions — you are only prompted when it is unsure.` (`cli.pretty.js:507838`) | The `permission_browser` dialog kind exists as a `request_user_dialog` kind, but this sentence is composed TUI-side | R | The GUI writes its own equivalent line; the mode is known from `initialize`/`system/status`. |
| Poll-event channel requires auto mode | `poll event rejected: poll events require permission mode "auto" (got "<mode>") — the event channel's protections route event-driven commands through the auto-mode classifier.` (§26.22.4, `chunk-2rhzyjym.js:177409`) | Returned as the `poll_event` control-response error | P | — |

---

## 26.4 The dangerous-rule strip

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Entering auto suspends "dangerous" allow rules | Bare/`*` Bash rules, the `al` interpreter/network prefix list, bare/`*` PowerShell rules and the PowerShell verb list, every `Agent(...)` rule, and `Monitor` are stripped and remembered for restoration on exit (§26.4, `chunk-1kg58a1a.js:99074-99102`) | Nothing on the wire | D | The GUI's own permissions view will disagree with reality: `get_settings.effective.permissions.allow` still lists the suspended rules while auto mode ignores them. **The GUI must re-implement the predicate** (§26.4 lists it completely, incl. the `al`/PowerShell arrays at `chunk-3741da2d.js:197012`) to grey out suspended rules while in auto mode. |
| Per-rule log line | `Ignoring dangerous permission <Tool(pattern)> from <source> (bypasses classifier)` (§26.4) | Debug log only (`t(...)`), never a wire frame, and it is not in the startup `warnings` array (`cli.pretty.js:99220-99288` — the `warnings` pushes are all about `--allowedTools`, typos and rule shape) | D | Reachable only by running the binary with `--debug` and scraping stderr. |
| `dangerousPermissions` returned at startup | `initializeToolPermissionContext` returns the list (§26.4, `chunk-1kg58a1a.js:99226-99227`, `99288`) | The top-level startup caller destructures only `warnings` and `overlyBroadBashPermissions` and discards `dangerousPermissions` (`cli.pretty.js:454480`) | D | Even the TUI drops it on this path; nothing to render. |
| Live filtering of rules added during auto mode | `aj()` drops dangerous allow rules on every permission check, so a rule added mid-session is filtered too (§26.4, `chunk-3741da2d.js:197144-197163`) | Invisible | D | A GUI "always allow" affordance that adds `Bash(*)` will appear to work and then silently do nothing. Warn at the point of creation. |
| Stripped rules count as present | `allowRuleExistsAt` treats a stripped rule as present so the UI does not offer to re-add it (§26.4, `chunk-1kg58a1a.js:75335-75338`) | — | R | The GUI should copy this behaviour to avoid an "add rule" button that is a no-op. |
| `autoMode.classifyAllShell` | When set, **every** Bash/PowerShell allow rule is dangerous, so all shell goes through the classifier; restrictive policy key (§26.19.1, `chunk-3741da2d.js:197128-197139`) | Readable via `get_settings.effective.autoMode.classifyAllShell`; settable per-session via `apply_flag_settings` | P | A useful GUI toggle ("route all shell through the classifier"), with the honest cost note. |

---

## 26.5 The `auto_mode` / `auto_mode_exit` system reminders

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `auto_mode` attachment (three shapes) | Rendered as a `user` message with `isMeta: true`; Shape A bypass, Shape B `steerOnly` Bash-first, Shape C full `## Auto Mode Active` block (§26.5, `chunk-1kg58a1a.js:154092-154115`) | Meta user messages are part of the conversation; with `--replay-user-messages` the host sees the replayed input stream, and the reminder is a synthesized meta message on the CLI side | P | Verified indirectly: this very session's context shows the Shape-B reminder text. The GUI should **hide or collapse** `isMeta` user messages rather than showing them as the user's words. |
| The `autoModeConsentFlow` "hold and batch your asks" block | Appended to Shape C only when `!isSubagentLoop && priorAssistantContext()` (§26.5) | Same channel | P | Explains a user-visible behaviour change: the model batches consent asks at the end of a turn instead of stopping. Worth surfacing in GUI help text. |
| `auto_mode_exit` reminder (`## Exited Auto Mode`, two shapes + the `bashFirst` suffix) | Emitted on leaving auto mode, once per stint (§26.5 "The exit reminder", `chunk-1kg58a1a.js:146422-146433`) | Same | P | — |

---

## 26.6–26.8 The decision pipeline, fast paths, and hooks

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Classifier request in flight | Tool-use id added to `classifierApprovals.checking`; the tool-use renderer subscribes to it (`zg(Re.id)` at `cli.pretty.js:764782`) **but discards the value** — there is no distinct "checking with the classifier" spinner in 2.1.257 | Nothing on the wire | D | The user sees only the ordinary in-progress tool spinner, and so will the GUI. A GUI **can exceed the TUI** here — but it has no signal to key off: no frame marks "classifier started". The only proxy is elapsed time between the assistant tool_use frame and the tool result. |
| Per-agent serialization of classifier calls | Requests serialized per agent id, with `queueDepth`/`queueWaitMs` reported on the decision event (§26.6 "Serialization", `chunk-1kg58a1a.js:75157-75207`) | Not on the wire | D | Explains why parallel tool calls in auto mode are slower than in `acceptEdits`. The GUI cannot show queue depth; it can show elapsed time. |
| Fast path 1 — `acceptEdits` simulation | Re-runs `checkPermissions` in a synthetic `acceptEdits` context with dangerous rules filtered; on allow, skips the model call entirely (§26.7) | Invisible; the tool simply runs | P | Nothing to render; relevant only to latency expectations. |
| Fast path 2 — safe-tool allowlist (23 tools + read-only Chrome actions) | Read/Grep/Glob/LSP/ToolSearch/MCP-resource/Task*/TodoWrite/plan tools etc. bypass the classifier (§26.7 "Fast path 2") | Invisible | P | Useful GUI copy: "reads, searches and task bookkeeping never call the classifier" — this is exactly the sentence the CLI itself tells the model on failure (§26.16.4). |
| Tools that are always classified | `Agent`, `CronCreate`, `memory_write`, `SendFile`, `RemoteTrigger`, `ScheduleWakeup`, `SendMessage` never take the fast path (§26.7 "Tools that are always classified") | Invisible | P | — |
| Eight bail-outs back to the normal ask path | `safety_check`, `ask_rule`, `org_ask_ceiling`, `plan_mode_floor`, `requires_user_interaction`, `workflow_usage_consent`, `outside_read_first_prompt`, `mode_changed_while_queued` (§26.6 "Bail-outs" table) | The bail-out is what turns into a `can_use_tool` control request; the reason itself is telemetry-only | R | The host can partly reconstruct: `can_use_tool.decision_reason_type` + `classifier_approvable` (SPEC 45:2491-2498) tell it whether a safety check refused classifier adjudication. `classifier_approvable` is `!ob(D, r => !r.classifierApprovable)` — i.e. **false means "no classifier can clear this; only the human can"**, which is exactly the phrasing a GUI dialog should use. |
| `AskUserQuestion` always bails out | `I6()` is hard-coded `true`, so the AskUserQuestion classifier exception never applies and it takes the `requires_user_interaction` path (§26.6) | Arrives as a `can_use_tool` with `requires_user_interaction: true` (SPEC 45:2498) | P | The GUI must render AskUserQuestion as a real question even in auto mode. |
| Hook `deny` beats auto mode | Hook deny is final; a deny rule overrides a hook allow/ask (§26.8) | `hook_started`/`hook_response` frames plus the hook's own denial; **no `permission_denied` frame** — the schema explicitly excludes hook denies and deny-rule overrides of hook decisions (SPEC 45:1646) | D | A GUI that keys "why was this blocked?" off `permission_denied` alone will miss hook denials. Use `--include-hook-events` and correlate. |
| Hook `ask` → `hookAskFloor` | A classifier *allow* is downgraded back to the ask, so the human is still prompted (§26.8) | The host sees a `can_use_tool` it would not have seen otherwise | P | Nothing extra to render; explains an "auto mode still asked me" case. |
| Hook `allow` still classified | Under `tengu_virtual_knuth`, an effective-auto hook allow still runs the classifier with `hookAllowVouched` (§26.8) | Invisible | D | Only affects latency and telemetry. |
| `PostToolUse` `classifierContext` | A hook may attach up to 2000 chars of context to a tool result, rendered as a `host_context`/`host_context_live` line for the classifier (§26.8, §26.13.3) | Fully host-controllable: the GUI writes a `PostToolUse` hook returning `hookSpecificOutput.classifierContext` | P (better) | **A real GUI advantage.** `host_context_live` (this live session, gate `tengu_disable_live_host_context` off) may relay real user words and *can satisfy a SOFT BLOCK consent bar the way a user turn would* (§26.13.3 verbatim bullet). A GUI with an out-of-band approval affordance can feed the approval straight to the classifier. |

---

## 26.9–26.15 The classifier request, its failures, and what leaks out

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Which model is classifying | Resolution order `modelByMainModel` → `model` → external Sonnet-5 default → flagship reroute target, org-policy vetted (§26.9 "Model selection") | Only leaked inside the *unavailable* denial text, which interpolates the model id (§26.16.4) | D | The GUI cannot show "classifier: claude-sonnet-5" until something fails. Workaround: parse the model name out of the unavailable message; otherwise omit. |
| Classifier stall logging | `[Stall] classifier_request_started/progress/finished` lines with reqId, tool, model, stage, duration, errorKind; first warning at 15 s then every 30 s, ≤10 times (§26.9 "Stall logging") | `--debug` stderr only | D | The single best diagnostic for "why is my auto-mode session hanging" is stderr-only. A GUI that already captures stderr for `--debug` sessions can surface it; otherwise it is blind. |
| Stage-1 / stage-2 timeouts | Stage 1: 60 s scaling to 120 s by prompt size, restarted per fetch attempt; stage 2: flat 120 s per call (§26.9 "Timeouts and budgets") | Not on the wire | D | A tool call can sit for two minutes with no frame at all. **The GUI should show its own elapsed-time affordance on any tool call in auto mode**, because the protocol gives it nothing. |
| Retry layers (SDK retries ×4, reparse loop ×4, outer unavailable retries) | §26.15.1; outer-retry warn line `Auto mode classifier: primary <model> unavailable (<errorKind>); outer retry n/N after Xms` | Debug log only. Note: `api_retry` / `control_request_progress{status:"api_retry"}` frames cover the *main loop*, not the classifier | D | Same blindness as above; the classifier's retries are entirely silent. |
| Error dump file | On a classifier throw, writes `auto-mode-classifier-error.txt` (mode 0600) next to the session transcript, containing the error, context comparison, action, system prompt and transcript; skipped when persistence is off (§26.15.5) | Path is on the result object as `errorDumpPath` but that object never reaches the wire | R (disk) | The GUI can find it deterministically at `~/.claude/projects/<slug>/auto-mode-classifier-error.txt` and offer "attach diagnostics". Contains the full rendered classifier prompt — treat as sensitive. |
| `AUTOMODE_DECISION_LOG=1` | Appends one JSON record per decision to `.automode_decisions.jsonl` **in the process cwd**: `{ts, tool, allowlisted, decision, durationMs, classifierModel, input/output/cache tokens, stage, category, stage1Severity, stage2Severity}` (§26.16.9, `chunk-1kg58a1a.js:74932-74946`) | Same file; the GUI sets the env var when spawning and tails the file | **R (the single most valuable workaround in this chapter)** | This is the only complete, machine-readable per-decision record available to a host: it carries the verdict, the model, the matched rule category, the severity scores, the duration and the token counts — none of which are on the wire. Caveat: it is written to `process.cwd()`, so the GUI must control cwd or accept the file landing in the workspace. |
| Same-turn sibling context | The classifier sees the same-turn tool calls issued before this one (§26.19.4) | Invisible | P | — |
| CLAUDE.md preamble to the classifier | A user-level CLAUDE.md is prepended with an explicit "generic encouragement is not authorization" framing (§26.12.8) | Invisible | P | Good GUI help text: a CLAUDE.md that says "be autonomous" will *not* loosen auto mode. |

---

## 26.16 Decision outcomes: what the user and the host actually see

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| **Allowed silently** — post-hoc marker | After the tool result, a dim single-line `Allowed by auto mode classifier`, suppressed for the `Agent` tool; the classifier's *reason* is stored per tool-use id (`Udn` at `cli.pretty.js:69813`, `428257`) but the renderer prints only the fixed string (`cli.pretty.js:768958`) | Not on the wire at all: an `allow` decision never produces a frame (SPEC 45 §45.19 — `can_use_tool` is the `ask` branch only; A4 glossary line 157) | **D** | The GUI cannot distinguish "the classifier approved this" from "a rule allowed it" from "a fast path allowed it". Workaround: `AUTOMODE_DECISION_LOG` gives per-tool `decision: "allowed"` + `allowlisted` + `stage`, joinable by timestamp and tool name (there is no `tool_use_id` in that record). |
| **Escalated to a prompt** | The dialog's consent line reads `Auto mode classifier requires confirmation for this <toolType>.\n<reason>`, themed `error` (`cli.pretty.js:821131-821134`) | `can_use_tool` carries `decision_reason_type: "classifier"` and `decision_reason` = the classifier's reason string (SPEC 45:2491-2498, extractor `oze` at `cli.pretty.js:70416-70435`) | **P** | Fully rebuildable. Two cautions from the schema: the reason **may carry ANSI escapes — sanitize before rendering**, and for `decision_reason_type: "subcommandResults"` the reason is the *nested* check's text. The `classifier: "auto-mode"` sub-discriminator is **not** on the wire, so a GUI cannot tell auto-mode from another classifier — in practice `"auto-mode"` is the only one. |
| **Denied with a reason** | The model receives the §26.16.3 message: `Permission for this action was denied by the Claude Code auto mode classifier. Reason: <reason>. If you have other tasks…` + the `OEt`/`ues` tail + optionally the settings hint | `system/permission_denied` with `decision_reason_type: "classifier"`, `decision_reason: <reason>`, `message: <the full model-facing text>` (SPEC 45 §45.14.3, emitter `chunk-zjj1wsm3.js:851330`); also booked into `result.permission_denials` (`{tool_name, tool_use_id, tool_input}`) | **P** | Solid parity for real blocks. The `noVerdict` flag is *not* on the wire, so a GUI must distinguish a judgement-deny from a fail-closed deny **by message prefix**: real block starts with `Permission for this action was denied by the Claude Code auto mode classifier. Reason: `, and the CLI's own extractor `shn()` slices the reason out at `. If you have other tasks` (`chunk-1kg58a1a.js:151586-151597`) — copy that parser. |
| **Denied because the classifier was unavailable** | Model text: `<model> is temporarily unavailable<qualifier>, so auto mode cannot determine the safety of <ToolName> right now…` with qualifier ` (rate-limited)` / ` (overloaded)` / ` (server error)` / ` (timed out)` / ` (connection failed)` (§26.16.4). Internal `decision_reason` is the constant `Classifier unavailable` | Same `permission_denied` frame; `decision_reason` = `Classifier unavailable`, `message` = the long text | **P** | The literal `Classifier unavailable` reason string is the GUI's reliable discriminator for "transient, retry" versus a real policy block. Present it as a retry affordance, not a denial. |
| **Denied with no verdict** (parse failure / policy refusal) | `Auto mode could not evaluate this action and is blocking it for safety — run with --debug for details`, optionally with the "a safety check separate from auto mode blocked this request because of earlier conversation content" clause, wrapped by `F5e` into the refused or transient form (§26.16.5) | Same frame; `decision_reason` is that sentence, `message` the wrapped form | **P** | The refused form tells the user to switch out of auto mode or start a fresh session — a GUI should turn that into a button. |
| **Transcript too long** | Falls back to the normal permission path with reason `Auto mode classifier transcript exceeded context window — falling back to manual approval (try /compact to reduce conversation size)`; the `Agent` tool is allowed outright; headless **throws** `Agent aborted: auto mode classifier transcript exceeded context window in headless mode` (§26.16.2, §26.16.6) | With `--permission-prompt-tool stdio` the session is not `shouldAvoidPermissionPrompts`, so the GUI gets a `can_use_tool` with `decision_reason_type: "other"` and that reason string | **P** | Important: a bare `-p` host **aborts the turn**; a host with a permission surface gets a prompt. afleet's flags put it in the good branch. |
| **Refused by the safety safeguard** | Headless throw `Agent aborted: auto mode classifier request refused by the safety safeguard in headless mode` (§26.16.2) | Same conditional as above | P | — |
| "denied by auto mode" transcript banner | Immediate-priority warning: `<tool name, lowercased> denied by auto mode · <reason truncated to 80 chars> · /permissions`, tool segment red, reason dimmed; suppressed for `noVerdict` denials (§26.16.8, `cli.pretty.js:428268`) | TUI notification queue only | R | All three parts are derivable from the `permission_denied` frame; the `· /permissions` call-to-action must become the GUI's own settings deep-link. |
| "explain why" affordance | **There is none.** The reason string is the whole explanation; the classifier's `<thinking>` body is captured on the result object (`thinking`, §26.16.1) but is never rendered anywhere, and the `<category>` (matched BLOCK rule name) is likewise telemetry-only | Neither is on the wire | **D** | A GUI wanting "why was this blocked?" beyond one sentence has only two sources: `AUTOMODE_DECISION_LOG` (`category`, `stage`, severities) and the request journal (see §26.24 row). |
| Subsequent-approval tracking | A denial is remembered by `{toolName, inputKey}` so a later approval of the same call emits `tengu_auto_mode_subsequent_approval` with `msSinceDeny` (§26.16.8, `cli.pretty.js:428310-428313`) | Telemetry only | X | No user-visible surface; listed for completeness. |
| `permission_retry` system frame | `Allowed <a, b>` summary line after a retry (SPEC 11:406, SPEC 45:1022 lists `permission_retry` among `system` subtypes routed to "internal surfaces") | Listed as an internal-surface subtype in SPEC 45's table, not among the §45.9.1 wire frames | D/X | I found no auto-mode producer of `permission_retry`; it belongs to the permission-system retry path (ch. 24), not to auto mode. Flagged under **Unverified**. |

---

## 26.17–26.18 The circuit breakers

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Denial counters | Trip at **3 consecutive** or **20 total** real blocks; only a real block counts (`unavailable`/`transcriptTooLong`/`refusedBySafeguard`/parse failure do not); an allow — classifier or rule-engine — resets the streak (§26.17.1-26.17.2) | Nothing on the wire | **D** | The GUI cannot show "2 of 3 consecutive blocks — one more and I will start asking you." Workaround: count `permission_denied` frames whose message carries the §26.16.3 prefix and whose `decision_reason` is not `Classifier unavailable` and does not start with `Auto mode could not evaluate` — that reproduces the `fn` predicate exactly. |
| Trip sentences | `<N> consecutive actions were blocked. Please review the transcript before continuing.` / `<N> actions were blocked this session. Please review the transcript before continuing.`, combined with `\n\nLatest blocked action: <reason>` (§26.17.3) | The combined text becomes the `decisionReason.reason` of the resulting ask, so it arrives as `can_use_tool.decision_reason` | **P** | Nice: the escalation message itself is on the wire once the breaker trips. |
| Headless abort on trip | `Agent aborted: too many classifier denials in headless mode` — thrown only when `shouldAvoidPermissionPrompts` (§26.17.3, §26.17.5) | With `--permission-prompt-tool stdio` the host has a prompt surface, so the trip becomes a `can_use_tool` instead of an abort | P | afleet is in the safe branch. A bare `-p` GUI would lose the turn. |
| Timed auto-deny dialog | Under `tengu_ticklish_whisper`, the fallback dialog auto-denies after `120000` ms and emits `tengu_auto_mode_denial_dialog_auto_denied` (§26.17.4) | `denialLimitFallback` is a JS `Symbol`-keyed marker on the permission result (`chunk-1kg58a1a.js:75096-75106`) — it is not serialisable and never crosses the wire | **D/X** | A host cannot learn that this particular `can_use_tool` carries an auto-deny deadline. If the gate is on, an unanswered dialog will resolve itself after two minutes and the GUI will see the tool denied with no explanation. The GUI's own dialogs should carry a visible timer as a defensive measure. |
| Session gate breaker | Latched once by `verifyAutoModeGateAccess`; never cleared for the session; makes the reason `circuit-breaker` → `auto mode is unavailable for your plan` (§26.18.1) | Only via the `set_permission_mode` rejection text | R | See §26.2. |
| Safety-check `circuitBreaker` traits | Six tags; `isolatePeerMachines`, `restrictedMode` and `outsideReadsBlocked` are never classifier-routed, so they always fall back to the dialog (§26.18.3) | `can_use_tool.classifier_approvable` is the wire-visible projection; note `oze` deliberately **suppresses** the reason text for `circuitBreaker === "outsideReadsBlocked"` (`cli.pretty.js:70425`) | P/D | For an outside-read block the host gets `decision_reason_type: "safetyCheck"` with **no** `decision_reason`. The GUI must supply its own copy for that case, and can use `blocked_path` from the same `can_use_tool` payload. |

---

## 26.19 `autoMode` settings

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Reading the effective `autoMode` block | `/permissions` Auto-mode tab, or `claude auto-mode config` (§26.21) | `get_settings` returns `effective.autoMode` and per-source `sources[]` | **P (verified live)** | The live dump shows the full merged `{allow, environment}` block. Note `effective` shows the **merged concatenation**, not `$defaults` expansion — for the expanded view the GUI must shell out to `claude auto-mode config` (§26.21). |
| Trusted sources for `autoMode` | Only `userSettings`, `flagSettings`, `policySettings`, concatenated in that order; project and local settings ignored with a one-shot warn (§26.19.2, `chunk-ftzzbzs6.js:510166-510197`) | — | P/D | The warn line is debug-log-only in stream-json mode. A GUI offering per-project classifier rules must explain that they will be ignored. |
| Writing `autoMode` rules for the session | Editing the file, or the `/permissions` tab | **`apply_flag_settings` accepts an `autoMode` block and merges it into `flagSettings` — a trusted source** (`cli.pretty.js:178054-178145`; no key allowlist on the stdio transport, unlike the cloud transport's 7-key set at `chunk-fv96b6je.js:510277`) | **R (verified live)** | **Verified:** `apply_flag_settings {"autoMode":{"soft_deny":["$defaults","AFLEET PROBE RULE: …"]}}` succeeded and `get_settings.effective.autoMode.soft_deny` came back with the probe rule appended to the user's rules, with `sources` gaining a `flagSettings` entry. This is the GUI's supported path to session-scoped classifier rules. |
| Writing `autoMode` rules **persistently** | The `/permissions` tab or `/auto-mode-setup` writes user settings | `update_settings` accepts **only** `source: "localSettings"` (SPEC 45 §45.22.8) — and localSettings is an *untrusted* source for `autoMode` | **D** | **Dead end on the wire.** A GUI must either (a) use `apply_flag_settings` per session, (b) edit `~/.claude/settings.json` on disk itself, or (c) drive `/auto-mode-setup … --apply-file` (§26.20), which writes user settings. |
| `$defaults` splicing | The literal `"$defaults"` inherits the shipped rules at that position; an array consisting solely of `$defaults` is emptied (§26.11.2, §26.20.4) | Same semantics wherever the array is written | P | The GUI's rule editor must preserve `$defaults` or it silently *replaces* the 69 shipped SOFT BLOCK rules. This is the highest-consequence footgun in the whole settings surface. |
| Field descriptions | Five verbatim `.describe(...)` strings (§26.19.1 table) | Not on the wire (`get_settings` returns values, not schema) | R | Copy them into the GUI's rule editor as help text. |
| Served config `tengu_auto_mode_config` (23 keys) | §26.19.3 table — controls the model, stages, severity thresholds, retries, `envOnboarding`, meta-line visibility, etc. | Not exposed anywhere | D | Non-actionable for a GUI; listed because it explains behaviour differences between machines. |
| `CLAUDE_CODE_AUTO_MODE_*` env overrides (15) and `CLAUDE_CODE_TICKLISH_WHISPER*` | All read from the internal `Yn` registry, which is `{}` in this build — **every one of them is inert** (§26.23.2, Open questions) | — | **T/X** | A GUI must not offer these as settings. The only working host-side env controls are `AUTOMODE_DECISION_LOG`, `CLAUDE_CHROME_CLASSIFIER_FLOOR`, `CLAUDE_CODE_EVAL_CONFINED` and `CLAUDE_CODE_HIDE_SETTINGS_HINT`. |
| No `CLAUDE_CODE_DISABLE_AUTO_MODE` | Does not exist in this build (§26 Open questions) | — | T | Disablement is settings-only. |
| Deprecated `--enable-auto-mode` flag | Declared, hidden, `(deprecated) Opt in to auto mode`, and never read (`chunk-fbf9hkgp.js:504302`) | — | T | Do not pass it. |

---

## 26.20 `/auto-mode-setup` — the wizard and its headless twin

### The interactive wizard (all rows X)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/auto-mode-setup` interactive registration | `type: "local-jsx"`, `isEnabled: ASt() && !isNonInteractive()`, `requires: {workspace, ink}` (§26.20.1, `cli.pretty.js:143519`) | No `local-jsx` command works headless; each is refused with `/<name> opens an interactive panel and isn't available in this environment.` (SPEC 28 §8.1 row 4) | **X** | In a headless session the interactive registration is *disabled* rather than refused, so the `local` twin resolves instead — the GUI never sees the refusal. |
| Wizard screens and copy | `Teach auto mode about your environment?`; the data-scope paragraph; `How you use Claude here`; posture options Work/Open source/Hobby/Mixed; depth checkboxes `Also scan shell history` / `Also scan your other repos`; screen-reader variants; the existing-entries append/replace/cancel step; scanning and saving spinners (§26.20.2) | — | **X** | A GUI reimplements the whole question flow, then drives the headless twin with the answers. All strings are in §26.20.2 and can be copied. |
| `Review proposed auto-mode setup` dialog | `request_user_dialog` kind `auto_mode_setup_review`, payload `{environment, allow, soft_deny, hard_deny, remove_from_permissions_allow, notes, mode:"append"\|"replace"}`, result `"accept"\|"decline"\|"cancelled"` (`cli.pretty.js:421289`) | The kind is declarable in `initialize.supportedDialogKinds`, **but the only requester is the local-jsx wizard** (`chunk-4pcd1evr.js:256487`) | **X** | Declaring the kind buys nothing headless. The GUI renders its own review from the `--propose` JSON. |
| `auto_mode_flagged_allow` dialog | `request_user_dialog` kind, payload `{flagged: string[], runId}`, result `{toRemove: string[]}` — asks which over-broad `permissions.allow` rules to delete (`cli.pretty.js:421289`, requested at `chunk-4pcd1evr.js:256501`) | Same: local-jsx-only requester | **X** | The headless twin instead takes `remove_from_permissions_allow` from the proposal file and applies it wholesale. The GUI must build its own multi-select before writing the file. |
| Background scan task | Registers an `auto_mode_scan` background task labelled `scanning for auto-mode setup`, detail `environment scan for /auto-mode-setup`, with a status line (§26.20.2) | The headless `--propose` call is synchronous and returns the proposal in one shot — no background task, no `task_started`/`task_progress` frames | X→P | Simpler headless. The GUI shows its own progress while the single command runs. |
| Environment-onboarding nudge | After ≥5 startups and ≥5 recorded auto-mode denials with no environment entries: dialog `Teach auto mode about your environment?` / `Auto mode works better when it knows your environment. Takes about a minute.` with `Yes` / `Not now` / `Don't show again`; 7-day snooze; state in `~/.claude.json` under `autoModeEnvSetup` (§26.20.8) | The gate `B5e` requires `toolPermissionContext.mode === "auto"` inside the REPL; TUI-only | **X** | The `autoModeEnvSetup` counter is **also never incremented headless** (it is bumped in the TUI's `useCanUseTool` at `cli.pretty.js:428268`), so a GUI must keep its own denial count if it wants the same prompt. |

### The headless twin — full argument protocol (what a GUI must drive)

Registration (`cli.pretty.js:143518`): `type: "local"`, `name: "auto-mode-setup"`,
`supportsNonInteractive: true`, `isEnabled: () => CSt() && isNonInteractive()`,
`isHidden: !isNonInteractive()`. **Note the asymmetry:** the interactive twin requires
`tengu_auto_mode_config.envOnboarding === true`; the headless twin requires only
`!CLAUDE_CODE_REMOTE` and that a classifier model resolves. A GUI therefore gets the setup
flow in deployments where the terminal does not.

**Verified live on 2.1.259:** the command is advertised in `initialize.commands` with its
non-interactive `argumentHint`, and `/auto-mode-setup --help` returned its JSON payload as
a synthetic `assistant` text frame (`model: "<synthetic>"`) and in `result.result`, with
`num_turns: 0` and `total_cost_usd: 0`.

| Aspect | Contract | Cite | Class |
|---|---|---|---|
| Invocation | Send the command as ordinary user text on stdin: `{"type":"user","message":{"role":"user","content":"/auto-mode-setup …"}}` | verified live | P |
| Result transport | One synthetic `assistant` text block containing pretty-printed JSON (2-space indent), echoed in `result.result`. No `local_command_output` frame was observed | verified live | P |
| Grammar (two forms) | `/auto-mode-setup [--request-id <uuid>] --wizard posture=<personal\|open-source\|enterprise\|mixed> scope=<all\|project> depth=<both\|shell\|repos\|here> --propose` — and — `/auto-mode-setup [--request-id <uuid>] [--apply-target <user\|project>] --expect-sha256 <64-hex> --apply-file <absolute-path>` | §26.20.6, `chunk-m3km2xh9.js:588550` | P |
| `--wizard` matching | Exact regex `/^--wizard posture=(\S+) scope=(\S+) depth=(\S+)\s+--propose$/` — no reordering, no extra whitespace variants; an unknown enum value yields `Couldn't parse arguments.` + usage (verified live with `posture=bogus`) | §26.20.6 | P |
| `--request-id` | Must be the **first** flag; canonical 8-4-4-4-12 UUID, either case; echoed verbatim as `requestId` on the result object so a host with several commands in flight can match replies | §26.20.6 | P |
| Flag ordering | `--request-id` → `--apply-target` → `--expect-sha256` → `--apply-file <path>`; everything after `--apply-file` is the path (quotes stripped). Fourteen distinct ordering/duplication violations each have their own message + usage, log code `bad_flag_grammar` | §26.20.6 table | P |
| `--apply` is refused | `One-shot --apply isn't available (it would write model output with no review). Use --propose, show the result to the user, then --apply-file <path>.` | §26.20.6 | P |
| Apply-file preconditions, in order | `missing_hash_arg` → `bad_hash_arg` (`/^[0-9a-fA-F]{64}$/`) → `bad_path` (must resolve strictly inside `os.tmpdir()` or the Claude config dir, realpaths included) → `read_denied` (a `permissions.deny` read rule covers it) → `read_failed` (read with `noFollow`, `requireNlink1`, `sniffEncoding`) → `too_large` (1 000 000-byte cap) → `hash_mismatch` → `parse_failed` → `scope_mismatch` | §26.20.6, `chunk-m3km2xh9.js:588560-588617` | P |
| `--apply-target` semantics | Does **not** change where the config is written — entries always land in the **user settings file**. It only refuses a proposal whose recorded `scope` disagrees (`user ↔ scope=all`, `project ↔ scope=project`) | §26.20.6-26.20.7 | P |
| `--propose` success shape | `{ok: true, proposal: {environment[], allow[], soft_deny[], hard_deny[], remove_from_permissions_allow[], notes[], mode: "append", scope: <answers.scope>}}` (the wizard's `gathered` field is dropped by the twin) | `cli.pretty.js:287778`, `588578` | P |
| `--propose` failure codes | `recon_failed`, `aborted`, `no_model`, `refused`, `truncated`/`unexpected_stop`, `api_failed`, `parse_failed`, `unknown_removal`, `invalid_proposal` — each with a verbatim user-facing `reason` | §26.20.3 table | P |
| Proposal validation before apply | Fences stripped, Zod-validated, entries trimmed and de-duplicated; **dangerous allow entries are dropped** when `allow.length ≤ 200` (unless `$defaults` or >10 000 chars), with a note `Dropped <n> proposed allow <entry\|entries> — too broad for auto mode to honor safely.`; `Itn` structural checks enforce that `environment` is non-empty, contains no `$defaults`, and that each non-empty `allow`/`soft_deny`/`hard_deny` array **starts with `$defaults`** | §26.20.4, `chunk-6bkf4eqn.js:287780-287811` | P |
| `--apply-file` success shape | `{ok: true, filePath, autoModeKeysWritten[], environmentEntriesPreserved, permissionsAllowRemoved[], permissionsAllowNotFound[], permissionsAllowSkipped, warnings[], target?, droppedUnsafeAllowCount?}` | `chunk-dt8558b2.js:480873`, `chunk-m3km2xh9.js:588612` | P |
| `mode: "replace"` | The `--propose` output is hard-coded to `mode: "append"`; but `--apply-file` reads `mode` from the file the host wrote, and the sha256 binds *the host's* bytes | `cli.pretty.js:287778` vs `588613` | P | A GUI can offer "start fresh" by writing `"mode":"replace"` into the reviewed file — the same choice the interactive wizard offers. |
| Environment-size warning | On write, `autoMode.environment now has <n> entries (~<n> KB). It's spliced into the classifier prompt on every auto-mode decision — consider pruning stale entries.` | §26.20.7 | D | Log-level only; the GUI should compute and show the size itself. |

---

## 26.21 `claude auto-mode` CLI and the `/permissions` auto tab

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `claude auto-mode defaults [--label <prefix>]` | Prints the four shipped arrays as JSON, optionally filtered by rule-label prefix (§26.21.1) | Separate process; not a slash command and not a control request | **R (shell out)** | The **only** way for a GUI to obtain the shipped rule library, which is a compressed embedded asset (`permissions_external-0f27b1d1.txt.zst`), not a file on disk. Essential for a rule editor that shows what `$defaults` expands to. |
| `claude auto-mode config` | Prints the effective config with `$defaults` expanded against the shipped defaults (§26.21.1) | — | R (shell out) | Complements `get_settings`, which returns the unexpanded merge. |
| `claude auto-mode reset [-y]` | Removes the `autoMode` key from user settings, with a confirmation, an unparseable-entries guard, and a note that managed/flag rules still apply (§26.21.1, verbatim strings) | — | R (shell out) | The GUI can drive it with `-y` and surface the exact output lines. |
| `claude auto-mode critique [--model]` | Sends the fully rendered classifier system prompt (empty slots) plus the user's custom rules to a model and prints the critique; `Analyzing your auto mode rules…`, `Failed to analyze rules: <error>`, and the no-rules message (§26.21.1) | — | R (shell out) | Costs a model call. A genuinely useful GUI feature ("check my rules") that needs no new protocol. |
| `/permissions` Auto-mode tab | `local-jsx` (SPEC 28:625), rendered only when `isAutoModeAvailable !== false`, id `automode`, title `Auto mode` (`cli.pretty.js:685570`) | No `local-jsx` command works headless | **X** | Everything below is inside it. |
| Recent-denials list | In-memory React ref capped at **20** entries, session-scoped, never persisted (`cli.pretty.js:4625-4630`, cap `an = 20`); empty state `No recent denials. Commands denied by the auto mode classifier will appear here.`; header `Commands recently denied by the auto mode classifier.`; per-entry `r` toggles a "(retry)" mark | The GUI builds the same list from `permission_denied` frames — which carry more (`tool_use_id`, `tool_input` via `result.permission_denials`) | **R (better)** | A GUI can persist denials across sessions and link each to its transcript position, which the TUI cannot. |
| Custom-rule editor | `Extra rules for the auto mode classifier. Rules are plain sentences; new rules are saved to your user settings.`; per-section header `<section> for the auto mode classifier · From <source>`; legacy-key hint; read-only-source hint `It is delivered by <source> and cannot be modified here.`; `Delete auto mode rule?`; overflow `… +<n> more rules — run \`claude auto-mode defaults\` to print the full set.` (§26.21.2) | — | X→R | Rebuild against `get_settings` (read) + on-disk write or `apply_flag_settings` (session). |
| Environment document editor | Opens `autoMode.environment` as a document in a scratch file prefixed `auto-mode-env-edit-` in the session directory; errors with `The environment could not be opened for editing: this session has no session directory to hold the working file. Edit autoMode.environment in your settings file directly.`; success `Saved your auto mode environment document` / `Replaced the built-in auto mode environment with your own document`; restructure hints `Re-run /auto-mode-setup to restructure…` (§26.21.2) | — | X→R | A GUI does this natively with a text area. The refuse message from the rules editor — `The environment is edited as a document — use Edit environment on the Auto mode tab.` (`cli.pretty.js:683695`) — is a TUI-navigation artefact with no GUI analogue. |
| Settings-file-error state | `the settings file has a validation error or cannot be read, so its auto mode rules are not in effect; fix it (Claude Code names the problem at startup), then try again.` (§26.21.2) | Detectable: `get_settings.sources` will simply lack the broken scope | R | Worth surfacing prominently — a broken settings file silently disables every custom classifier rule. |
| `/doctor` auto-mode item | The doctor skill checks whether auto mode is the user's default permission mode and proposes making it so (`cli.pretty.js:386915`) | `doctor` is a *prompt*-type skill (live init lists it with alias `checkup`), so it works headless | P | — |

---

## 26.22 Sandbox network classifier and subagent hand-back

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `SandboxNetworkAccess` classification | The sandbox network policy reuses the whole auto-mode classifier with a synthetic tool call `{"SandboxNetworkAccess":{"host":…,"port":…}}` and its own severity site; **fails closed on unavailability** (§26.22.1) | `request_user_dialog` kind `sandbox_network_access`, payload `{host, port?, forwardedFromWorker?, workerName?}`, result `{allow, persistToSettings, persistRow?}` or `"cancelled"` (`cli.pretty.js:396429`) | **P** | Declarable in `initialize.supportedDialogKinds`. Absence fails closed to the no-dialog behaviour, so a GUI that wants sandboxed network prompts **must** declare this kind. |
| Subagent hand-back review | A subagent's final message is itself classified, with the `Subagent has finished and is handing back control…` framing and the untrusted-output warning (§26.22.2) | The verdict surfaces as an ordinary classifier decision on the parent's `Agent` tool result | P | — |
| "classifier was unavailable while reviewing this subagent" note | `Note: <model> (the safety classifier) was unavailable<qualifier> when reviewing this subagent's work. Please carefully verify the subagent's actions and output before acting on them.` (§26.22.2) | Appended to the tool result the model reads, so it appears in the `user` tool-result frame | P | The GUI should visually flag it — it is a quality caveat attached to a result that otherwise looks normal. |
| Coordinator / worker guidance prompts | Worker: report the exact action, the denial reason, and "needs user approval for X". Coordinator: quote the user's exact words into the worker's prompt, because the worker's classifier sees only its own transcript (§26.22.3) | Prompt text; reaches subagents normally | P | Explains a real multi-agent failure mode a GUI should document: **an approval given in the parent session is invisible to a subagent's classifier.** |
| Slack / GitHub auto-reply blocked by auto mode | `… Auto mode did not approve an unattended auto-reply, so the reply was not posted — read and reply with <tool> when ready (further comments will not repeat this notice).` (`cli.pretty.js:596205`) | Reaches the model as tool-result text | P | — |

---

## 26.23–26.24 Cost, telemetry, and the request journal

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| **Cost of the classifier** | Computed per decision as `classifierCostUSD` (plus per-stage `classifierStage1CostUSD` / `classifierStage2CostUSD`) and sent to telemetry (§26.24.1, `cli.pretty.js:75551`) | **Excluded from every accounting field on the wire.** `modelUsage`'s own schema says "Internal helper calls outside the query pipeline (e.g. the permission classifier, token-count probes) are excluded", and `total_cost_usd` covers "the same query-pipeline calls as modelUsage" (SPEC 45 §45.11.5) | **D** | The auto-mode explainer promises "Sessions are slightly more expensive" and then gives the host no way to show by how much. Workaround: `AUTOMODE_DECISION_LOG=1` records per-decision `inputTokens`/`outputTokens`/`cacheReadInputTokens`/`cacheCreationInputTokens` and `classifierModel`; a GUI can price them itself. `/cost` (`get_session_cost`) likewise excludes it — verified: the live `get_session_cost` text has no classifier line. |
| Session-level classifier stats in the TUI | **There are none.** `Rnt(session, record)` writes only to the `AUTOMODE_DECISION_LOG` file (`cli.pretty.js:74932-74946`); no `/status`, `/cost` or footer surface aggregates classifier decisions | — | **D (symmetric)** | Good news for parity: the TUI does not show classifier stats either, so a GUI that reads the decision log **exceeds** the TUI rather than catching up. |
| Request journal (last classifier request/response pairs) | Kept in session state for a debug UI; merged across a refusal so both attempts show (§26.24.3, `chunk-4a0qf0mq.js:244284-244288`) | Not on the wire, and I found no user-facing renderer of it in 2.1.257 | D | Listed for completeness; not currently a TUI affordance. |
| Telemetry events (17 auto-mode events) | §26.24.1 | Statsig/OTel only | X | Not a user-visible surface. |

---

## Top gaps in this area

Ranked by how much they cost a GUI that wants parity-or-better with the terminal.

1. **An `allow` decision produces no wire frame at all.** The TUI prints a dim
   `Allowed by auto mode classifier` under each classifier-approved tool result
   (`cli.pretty.js:768958`); the protocol carries nothing — `can_use_tool` is the `ask`
   branch only (SPEC 45 §45.19). A GUI cannot tell "the classifier vetted this" from "a
   rule allowed it". *Workaround:* run with `AUTOMODE_DECISION_LOG=1` and tail
   `.automode_decisions.jsonl` in the process cwd; it carries `decision`, `allowlisted`,
   `stage`, `category` and per-decision token counts. This is the single highest-leverage
   workaround in the chapter.
2. **No signal that a classifier call is in flight, and no timeout budget on the wire.** A
   tool call can sit silent for up to 120 s (§26.9 "Timeouts and budgets") with no frame.
   Even the TUI has no dedicated indicator (`zg(Re.id)`'s value is discarded at
   `cli.pretty.js:764782`), so the GUI must invent its own elapsed-time affordance — an
   easy place to beat the terminal.
3. **Classifier cost is invisible.** Excluded from `modelUsage`, `total_cost_usd` and
   `get_session_cost` by explicit schema note (SPEC 45 §45.11.5), while the mode's own
   description warns sessions are "slightly more expensive". Only the decision log has the
   tokens. This is the most user-facing honesty gap in auto mode.
4. **`autoMode` rules cannot be written persistently over the protocol.** `update_settings`
   accepts only `localSettings` (SPEC 45 §45.22.8), and `localSettings` is an *untrusted*
   source for `autoMode` (§26.19.2) — so the write would land and be ignored. **Verified
   working alternative:** `apply_flag_settings` merges an `autoMode` block into
   `flagSettings`, a trusted source, for the session. Persistence needs a direct
   `~/.claude/settings.json` edit or `/auto-mode-setup … --apply-file`.
5. **The dangerous-rule strip is silent and invisible.** Entering auto mode suspends every
   bare/`*` Bash rule, the whole interpreter/network prefix family, all PowerShell
   dispatch verbs, every `Agent(...)` rule and `Monitor` (§26.4) — but `get_settings` still
   reports them as allowed, the per-rule log is `--debug`-only, and the computed
   `dangerousPermissions` list is discarded even by the TUI (`cli.pretty.js:454480`). A GUI
   permissions view will lie unless it re-implements the predicate from §26.4.
6. **The denial circuit breaker is invisible until it fires.** 3 consecutive or 20 total
   real blocks flips auto mode into asking (§26.17), and nothing on the wire counts down.
   The counting predicate is reproducible from `permission_denied` frames (exclude
   `Classifier unavailable` and `Auto mode could not evaluate…` reasons), and a GUI showing
   "2 of 3" would be strictly better than the terminal.
7. **`denialLimitFallback`'s timed auto-deny is a JS `Symbol` and cannot cross the wire**
   (`chunk-1kg58a1a.js:75096-75106`). Under `tengu_ticklish_whisper` a `can_use_tool` the
   host is holding will be auto-denied after 120 s with no warning in the payload. GUI
   dialogs should carry their own visible deadline defensively.
8. **How much of the setup wizard is reachable headless: the model call and the write, but
   not a single dialog.** The `local` twin (`--wizard … --propose`, then
   `--expect-sha256 … --apply-file`) is fully drivable — verified live on 2.1.259, returning
   JSON as a synthetic `assistant` frame at zero cost. Both wizard dialog kinds
   (`auto_mode_setup_review`, `auto_mode_flagged_allow`) exist as `request_user_dialog`
   kinds but are requested **only** by the local-jsx path (`chunk-4pcd1evr.js:256487,256501`),
   so declaring them buys nothing. The GUI must build the question flow, the proposal
   review, and the over-broad-rule multi-select itself. Two compensations: the headless
   twin does **not** require `envOnboarding` (the interactive one does), so the GUI gets
   setup where the terminal does not; and `mode: "replace"` is reachable by writing it into
   the reviewed file even though `--propose` always emits `"append"`.
9. **`permission_mode_from_default_fallback` and `auto_default_nudge` are IDE-only.** Both
   are gated on `p1()` — entrypoint `claude-vscode` (`cli.pretty.js:178998`) — and were
   absent in both live probes. A GUI cannot learn "auto is your default" or offer the
   "Make auto mode your default permission mode?" nudge through the protocol. Derive the
   first from `get_settings.effective.permissions.defaultMode`; build the second yourself.
10. **`noVerdict` is not on the wire, so fail-closed denials look like policy denials.** The
    `permission_denied` frame carries `decision_reason_type: "classifier"` for a real block,
    a `Classifier unavailable` fail-closed deny, and a parse-failure deny alike. Discriminate
    by message prefix — the CLI's own extractor `shn()` (`chunk-1kg58a1a.js:151586-151597`)
    slices the reason at `. If you have other tasks`; reuse that exact parse. Getting this
    wrong means telling the user "Claude blocked this" when the truth is "the classifier
    timed out; retry."
11. **All four auto-mode banner surfaces are TUI-only.** The entry warning, the
    "auto is now the default" notice, `auto-mode-gate-notification`, `auto-mode-unavailable`
    and the `<tool> denied by auto mode · <reason> · /permissions` line all live in the Ink
    notification queue (`cli.pretty.js:4612`, `660727-660783`) or in effects registered
    inside the REPL render (`Vit(G$e, …)` at `cli.pretty.js:433777`). Every one must be
    rebuilt; the denial banner is fully derivable from `permission_denied`, the rest are not.
12. **The unavailability reason is only reachable by attempting a mode switch.** The four
    strings (`auto mode disabled by settings`, `auto mode is unavailable for your plan`,
    `auto mode unavailable while fast mode is on · run /fast off`,
    `auto mode unavailable for this model`) reach the wire solely as the error text of a
    rejected `set_permission_mode` (§26.3, `cli.pretty.js:173907`). A GUI that wants to grey
    out an Auto toggle proactively must probe, or infer from `get_settings`.
13. **The shipped rule library is not readable over the protocol.** It is a compressed
    embedded asset, so a GUI rule editor that wants to show what `$defaults` expands to must
    shell out to `claude auto-mode defaults` (or `config`). Related footgun: dropping
    `"$defaults"` from an `autoMode` array silently *replaces* the 69 shipped SOFT BLOCK
    rules (§26.11.2, §26.20.4) — the highest-consequence mistake in the settings surface.
14. **`sandbox_network_access` fails closed if the host does not declare it.** It is a real,
    reachable `request_user_dialog` kind (`cli.pretty.js:396429`) that reuses the auto-mode
    classifier and denies on unavailability (§26.22.1). Not declaring it in
    `initialize.supportedDialogKinds` silently degrades sandboxed network access.
15. **"Explain why this was blocked" has no data behind it.** The classifier's `<thinking>`
    body and the matched BLOCK-rule `<category>` are captured on the result object (§26.16.1)
    but rendered nowhere and never serialised. Beyond the one-sentence reason, the only
    sources are the decision log's `category`/`stage`/severity fields and the `--debug`
    error dump.

---

## Unverified

- **`permission_retry`.** SPEC 11:406 and SPEC 45:1022 name it, but I found no auto-mode
  producer; I believe it belongs to the permission-system retry path (ch. 24) and not to
  auto mode. Flagged rather than classified with confidence.
- **The `r` key in the `/permissions` recent-denials list.** I read the handler
  (`cli.pretty.js:683290-683345`): it toggles membership of two `Set`s and the row renders
  a `" (retry)"` suffix. I did not trace what consumes that set, so "marks the denied
  command for retry" is an inference from the label, not a read of the retry path.
- **`apply_flag_settings` key surface on stdio.** I verified live that `autoMode` and
  `useAutoModeDuringPlan` are accepted and land in `flagSettings`. I read the handler and
  saw no key allowlist on this transport (only the cloud transport has one,
  `chunk-fv96b6je.js:510277`), but I did not exhaustively test other auto-mode keys such as
  `permissions.disableAutoMode` or `skipAutoPermissionPrompt` through that channel.
- **Whether `tengu_ticklish_whisper` (the timed auto-deny) is on for this account.** The
  gap row assumes it may be; I did not observe a `denialLimitFallback` in practice, and the
  env override that would force it (`CLAUDE_CODE_TICKLISH_WHISPER`) is inert in this build.
- **The `local_command_output` frame.** SPEC 45:1005 lists the subtype, but the live
  `/auto-mode-setup --help` run produced its JSON as a synthetic `assistant` frame and in
  `result.result`, with no `local_command_output` frame observed. I did not determine
  whether some other local command emits it, or whether the subtype is unused in 2.1.259.
- **`tengu_auto_mode_config` values on this machine.** Several behaviours documented above
  (severity mode, `outcomeVisibility`, `repoVisibility`, `gitStatusType`, `envOnboarding`,
  `twoStageClassifier`) depend on a served config I cannot read. `envOnboarding` must be
  true or false-with-the-headless-twin-still-enabled — the twin's presence in the live
  command list only proves `CSt()`, not `ASt()`.
- **Whether the classifier's cost appears anywhere in `/usage` or `get_usage`.** I confirmed
  its exclusion from `modelUsage`, `total_cost_usd` and the `get_session_cost` text, but did
  not audit the `get_usage` rate-limit payload for a separate classifier line.
