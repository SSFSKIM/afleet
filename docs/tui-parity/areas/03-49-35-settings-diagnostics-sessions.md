<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

> **Errata from live probes (see ../README.md §4 and ../evidence/):**
> - The closing note calls `register_repo_root` the real `/add-dir` equivalent. Probe 10 shows it refuses any directory that is not a subdirectory of cwd or of a launch-time `--add-dir` root (`… is not a subdirectory of cwd or of a launch-time --add-dir root`); it registers cloned repos inside the workspace. There is no runtime `/add-dir` for a local headless session.

# Area 03 / 49 / 35 — settings & configuration, updates & diagnostics, session persistence

Scope: SPEC [03. Settings and configuration], [49. Updates and diagnostics],
[35. Session persistence]. Classifications use the letters from BRIEF.md
(P parity / R rebuild / D data gap / X unreachable / T terminal-specific).

Live ground truth used below (2.1.259, `/tmp/afleet-gap/init-dump.json`): the `initialize`
control response carries 102 `commands` rows; **`resume`, `export`, `rewind`, `branch`,
`fork`, `status`, `bug`, `feedback`, `release-notes`, `add-dir`, `cd`, `permissions`,
`update`, `version`, `diff` are all ABSENT** from that list, while `clear`, `rename`,
`config`, `compact`, `context`, `usage`, `model`, `effort`, `fast`, `doctor`, `debug`,
`heapdump`, `mcp`, `agents`, `color`, `goal`, `recap`, `init` are present.
`get_settings` and `get_binary_version` both answered on the local stdio transport.

---

## 03.1 The settings model: five sources and precedence

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Five settings sources | `userSettings`, `projectSettings`, `localSettings`, `flagSettings`, `policySettings`, merged lowest-first in exactly that order (03 §3.1, `chunk-ejcy5qcd.js:490008`) | `get_settings` returns `{effective, sources:[{source,settings}], applied}` — live-verified; `sources` omits empty sources (03 §8.3, `chunk-ejcy5qcd.js:491826-491835`) | P | A GUI can render the same "which tier set this" story the `/config` panel renders. `sources` is the per-source *validated* object, so the GUI can compute provenance itself. |
| Merge semantics (arrays union, `modelPicker` replaces, `extraKnownMarketplaces` shallow-merges, everything else deep-merges) | 03 §8.2 (`chunk-ejcy5qcd.js:491735-491746`) | not exposed; the host must re-implement the customiser if it wants to predict the effect of an edit | R | Data is on the wire (`sources` + `effective`); only the algorithm must be rebuilt. Cheap: one lodash `mergeWith` customiser. |
| Per-key source restrictions (security-sensitive keys read only from policy/flag/user; repo sources excluded from `env`, marketplaces, auto-mode rules) | 03 §9.1–9.4 | not exposed | R | The GUI must hard-code the same tables (03 §9.4 lists every key with its restriction verbatim) or it will show an edit as effective when it is silently ignored. |
| Effective *applied* model/effort/advisor/ultracode | shown in `/status` + `/model` + footer (49 §49.21.1) | `get_settings.applied = {model, effort, advisor, ultracode}` (`chunk-2rhzyjym.js:178218`); live-verified `{"model":"claude-fable-5-1","effort":"xhigh","advisor":null,"ultracode":false}` | P | Better than the TUI: one request gives the resolved values without parsing the footer. |
| `--setting-sources user,project,local` | 03 §3.2; `flagSettings`+`policySettings` are always re-added; `--restricted` = empty list | same flag on the headless launch (`chunk-ejcy5qcd.js:490076-490104`) | P | If the host passes it, `update_settings` refuses with `update_settings: the localSettings source is disabled for this session (--setting-sources)` (`chunk-2rhzyjym.js:174370`). |
| `--settings <file-or-json>` | 03 §3.3; content is **pinned at startup**, later edits never re-read | same flag; identical pinning (`chunk-gchhcbj1.js:515218-515248`) | P | Useful to a GUI as the "session overlay" that survives the whole process. Errors: `Error: Invalid JSON provided to --settings`, `Error: Settings file not found: <path>`, `Error: Settings file exceeds the 2MiB limit: <path>`, `Error: Cannot use settings file (<reason>): <path>`. |
| `--managed-settings <json>` (SDK parent policy tier) | 03 §5.8, hidden flag, restrictive-only filtered | same flag | P | A host can only *tighten*. `Og` (`chunk-ejcy5qcd.js:491174-491258`) lists exactly what survives. |
| Settings validation errors | modal `Settings Error` / `Settings Warning` with `Fix with Claude` / `Exit and fix manually` / `Continue without these settings` (03 §7.6) | `get_settings.errors` = non-warning records `{file, path, message}` only (`chunk-2rhzyjym.js:178217`); non-interactive sessions otherwise only log `Invalid setting skipped without dialog (automated session): …` (`chunk-chr1kh62.js:450125-450128`) | R | Error text is available; `severity`, `suggestion`, `docLink`, `statusOnly` are **not** in the control response — the GUI loses the suggestion/doc-link column and the warning/error split. The "Fix with Claude" prompt is fully specified (03 §7.6) and a GUI can submit it verbatim as a user message. |
| Status-only notices (`statusOnly` records: policy-helper misconfig etc.) | shown in `/status` and `claude doctor` (03 §7.2) | filtered out of `get_settings.errors` (only `severity !== "warning"` survive) | D | Workaround: shell out to `claude doctor`, which prints them under the same headings (49 §49.18.3). |

## 03.2 Writing settings from a headless host

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `update_settings` control request | — | **Accepts `source: "localSettings"` only, and within it only the single key `outputStyle`**, string values only, deletion unsupported, and it is refused outright over a remote transport (`chunk-2rhzyjym.js:174361-174379`: `var T_ = new Set(["outputStyle"])`, `update_settings keys not allowed: <keys>`, `update_settings values must be strings (deletion is not supported): <keys>`) | D | **SPEC 45 §45.22.8 understates this** — it says only that the source must be `localSettings`. The real allowlist is one key. Anything else a GUI wants to persist must go through `/config` (below) or file edits. |
| `apply_flag_settings` control request (local stdio transport) | — | The request's whole `settings` object is merged into the **`flagSettings` inline layer** (`ixe({...RW(), ...patch})`, `chunk-2rhzyjym.js:178133-178139`), a `null` value deletes a key, alias repair runs first (`sq`), then `Hl.notifyChange("flagSettings")` | P | This is far wider than the Remote-Control bridge, which refuses everything except `effortLevel`/`ultracode` with `apply_flag_settings: <keys> cannot be changed over Remote Control (only effortLevel and ultracode can)` (`chunk-2x0p0v0q.js:183815`). On the local path **any settings key is accepted**; it is session-scoped (never written to disk) and sits above user/project/local but below policy. |
| Keys `apply_flag_settings` gives extra behaviour to | — | `model` (runs `PreModelSwitch` hooks, allowlist step-down, emits the model-change notice), `agent` (system-prompt swap, `Agent "<x>" not found`), `effortLevel` (also flips `ultracode` when the value maps to it), `ultracode` (forces `xhigh` session effort), `fastMode`, `viewMode` (`SXe()`), plus anything else merged verbatim — `advisorModel` and `briefTranscript` are used this way by first-party callers (`chunk-1kg58a1a.js:89850`, `:145053`) | P | Confirms the brief's list and adds `agent`. Model/agent/fastMode changes are deferred behind the turn queue when a turn is in flight, and the response carries ` (the request's other settings were applied: <keys>)`. |
| `/config` interactive panel (rows, sections, lock badges) | 03 §18.3: sections `Appearance, Model & output, Display, Input & controls, Connections, Advanced, Experimental, Internal`; rows hidden when a policy/flag source owns the key; `→ settings.json` markers; per-change confirmation lines | the panel is `local-jsx` ⇒ refused headless | X (panel) / R (function) | The **row model** is reachable: the non-interactive twin `/config key=value` is `type:"local", supportsNonInteractive:true, isEnabled: () => !isInteractive()` (`chunk-1kg58a1a.js:143651`, `Oe()` at `cli.pretty.js:243981`) and is present in the live headless command list. A GUI rebuilds the panel and drives it through `/config`. |
| `/config key=value` (the settable rows) | 03 §18.2 | 59 row ids: `agentPushNotifEnabled agentsView apiKey artifacts askUserQuestionTimeout autoCompact autoConnectIde autoContinueAtUsageLimit autoInstallIdeExtension autoScroll autoUpdatesChannel checkpoints chrome copyFullResponse copyOnSelect crossSessionInbound defaultToAgentsView defaultView dialogExpiry diffTool editor externalEditorContext fast feedbackDrafts gitignore inputNeededNotifEnabled language leftArrowOpensAgents model modelProposedGoals notifChannel orgMemoryRead orgMemoryWrites outputStyle permissionMode precomputeCompactionEnabled progressBar promptSuggestionEnabled prStatus recap reduceMotion remoteControl remoteHomeSettings showExternalIncludesDialog showStatusInTerminalTab switchModelsOnFlag teammateMode theme thinking timeFormat timestamps tips turnDuration useAutoModeDuringPlan verbose workflowKeywordTriggerEnabled workflows workflowSizeGuideline worktreeBaseRef` (`chunk-wftr5q3n.js:776960-777325`) | R | This is the practical persistence channel for a GUI: it writes `~/.claude/settings.json` (most rows), `.claude/settings.local.json` (`tips`, `reduceMotion`, `outputStyle`, `defaultView`) and `~/.claude.json` (`workflowSizeGuideline`, `showStatusInTerminalTab`, `gitignore`, `copyFullResponse`, `copyOnSelect`, `defaultToAgentsView`, `leftArrowOpensAgents`, `externalEditorContext`, `prStatus`, `diffTool`, `autoConnectIde`, `autoInstallIdeExtension`, `chrome`, the `remoteControl` reset, the API-key record) — 03 §18.3. Output comes back as a `local_command_output` / informational frame. |
| `/config` rows the shorthand refuses | `<id> can't be enabled with key=value — open /config to change it from the panel.` and the three redirects `agentsView → /config (Agents view row)`, `autoUpdatesChannel → /channel`, `showExternalIncludesDialog → /config (External CLAUDE.md row)` (03 §18.2, `chunk-wcgy4qq1.js:776041-776093`) | same refusals headless | D | `autoUpdatesChannel` is reachable via `/channel`; the agents-view row and the external-CLAUDE.md row have **no** non-interactive path. |
| Every settings key **not** on a `/config` row | user edits `settings.json` by hand, or a dialog writes it (permission prompts, trust, MCP approvals) | no control request writes it | D | Affected: `hooks`, `statusLine`, `env`, `permissions.allow/deny/ask`, `permissions.additionalDirectories`, `mcpServers`, `enabledPlugins`, `skillOverrides`, `claudeMdExcludes`, `spellcheck`, `footerLinksRegexes`, `cleanupPeriodDays`, `attribution`, `worktree.*`, `sandbox.*`, `autoUpdatesChannel`/`minimumVersion`, `fallbackModel`, `modelPicker`, … Workarounds: (a) `apply_flag_settings` for a **session-scoped** value (not persisted), (b) `--settings` inline JSON at launch (pinned for the process), (c) editing the file on disk — which the afleet design forbids. |
| `/permissions` (allow/deny/ask rule editor) | `local-jsx`, `immediate: true` (`chunk-1kg58a1a.js:143528`) | not in the headless command list; no control request | X | Partial workaround: a `can_use_tool` response may carry `updatedPermissions`, which the CLI applies to the session context **and persists** (SPEC 45 §2600, `chunk-2rhzyjym.js:178880`), so "always allow" is reachable through the permission channel with a host-chosen destination. Bulk rule editing and rule *deletion* are not. |
| Permission mode | `/permissions` panel, Shift+Tab cycle | `set_permission_mode` control request; `system/status` frames carry mode changes; `/config permissionMode=<mode>` persists a default | P | |
| Model / effort / fast-mode toggles | `/model`, `/effort`, `/fast` pickers | `set_model`, `apply_flag_settings {effortLevel|fastMode|ultracode}`, `list_models`; `/model`, `/effort`, `/fast` also exist as headless commands (live list) | P | |
| Output style | `/output-style` picker | `update_settings {source:"localSettings", settings:{outputStyle:"<name>"}}` — the **one** key `update_settings` accepts; also `/config outputStyle=` | P | `initialize` response carries `output_style` and `available_output_styles` (live-verified). |

## 03.3 Hot reload, watchers and the `ConfigChange` hook

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| External edit to `settings.json` / `.claude/settings*.json` | chokidar watch on the containing directories; 1000 ms write-stability + 500 ms poll; 1700 ms deletion debounce; 5 s self-write echo suppression; then cache invalidation, lazy re-read (03 §14.2, §14.5) | the watcher is process-wide, so a headless process **does** pick up external edits with the same latency | P (behaviour) / D (notification) | Nothing on the wire announces it: the frame catalogue (SPEC 45 §45.9.1) has `commands_changed` for skills/plugins but **no settings-changed frame**. A GUI must either poll `get_settings` or run its own file watcher. |
| Managed/MDM/registry sources | polled, not watched — every 1,800,000 ms the fingerprint is recompared (`Detected MDM settings change via poll`) (03 §14.2) | identical | P | Up to 30 minutes of staleness is normal; a GUI should not present managed settings as live. |
| `--settings` file edited after launch | never re-read (pinned) (03 §3.3); the Fix-with-Claude prompt says so verbatim | identical | P | |
| `ConfigChange` hook | runs **before** every invalidation, matcher matched against `source` (`user_settings`/`project_settings`/`local_settings`/`policy_settings`/`skills`), exit 2 blocks the change; `policy_settings` results are forced non-blocking (03 §14.3) | hooks run normally headless; with `--include-hook-events` the host sees `hook_started`/`hook_progress`/`hook_response` frames | P | A GUI can use a `ConfigChange` hook as its settings-change notification channel — that is the only push signal available. Cost: it needs a hook installed in a settings file. |
| `~/.claude.json` external change | `fs.watchFile` at 1000 ms; the whole object is re-parsed and re-installed (03 §14.5, §16.4) | identical | P | |

## 03.4 Working directories, `/add-dir`, `/cd`, trust

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/add-dir <path>` | `local-jsx`, adds a working directory; also appends the session's project dir to `<projectDirOf(D)>/.session-aliases` (35 §35.16.9) | not in the headless command list; the equivalent control request is **`register_repo_root`**, not `add_directory`: request `{directory, reload_claude_md?, reload_skills?, reload_plugins?}` → `{directory}` (recovered from `chunk-2rhzyjym.js:176900-176960`) | R | Validation is strict and the error strings are user-facing: `register_repo_root: target path could not be resolved`, `… is a network path or an obfuscated spelling, which cannot be registered`, `register_repo_root: <dir> is already a registered working directory`, `… is outside the allowed registration scope`. It fires the `DirectoryAdded` hook and can reload CLAUDE.md/skills/plugins. `--add-dir` at launch is the other route. |
| `add_directory` control request | — | **Not** the `/add-dir` equivalent. It is a container/cloud staging call: `{mount_path}` → `{staged_path, directory}`, and it refuses unless `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` is set in the container environment: `add_directory requires CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD to be set in the container environment` (`chunk-2rhzyjym.js:176961-176988`) | — | Recovered because the schema is unpublished. A local GUI should never call it. |
| `/cd <path>` | `local-jsx`, moves the session, relocates the transcript, re-runs the trust check (03 §15.7; 35 §35.23) | control request **`set_cwd`**: `{path, trust_accepted?, trusted_directory?}` → `{status:"ok", cwd, changed, transcript_relocated}` \| `{status:"needs_trust", directory, trust_root?}` \| `{status:"rejected", reason, message}` with `reason ∈ busy \| unsafe_path \| not_found \| not_a_directory \| blocked_by_rule` (recovered from `chunk-7xxepkby.js:319794-319845`) | P | Full parity **and better**: the `needs_trust` handshake is an explicit two-step the GUI renders as its own dialog; re-sending with `trust_accepted:true, trusted_directory:<echoed directory>` **persists** `projects[<canonical git root>].hasTrustDialogAccepted = true` in `~/.claude.json` (`v$e`, `chunk-sct99ax9.js:677871-677878`). Invalid combination: `set_cwd: invalid request — trust_accepted requires trusted_directory (echo the directory from the needs_trust response)`. The turn must be idle. |
| Workspace-trust dialog at startup | `Accessing workspace:` panel with the "Quick safety check" copy, the pre-approved-rules / added-directories / headersHelper disclosure bullets, `Security guide` link, and options `No, exit` / `Yes, I trust this folder` (03 §15.3) | **never shown in `-p`**: the session trust flag is forced true (`chunk-chr1kh62.js:454470-454472`), so `Jo()` is true while `fp()` stays false | D + security note | Consequence a GUI must reproduce: with `-p`, repo-declared `permissions.allow` and `permissions.additionalDirectories` are **silently dropped**, hooks / `statusLine` / `subagentStatusLine` / `fileSuggestion` / `apiKeyHelper` / `awsAuthRefresh` / `awsCredentialExport` / `gcpAuthRefresh` / `otelHeadersHelper` / `proxyAuthHelper` are skipped, and `env` is applied in **safe mode** only (03 §15.5, §12.1). The GUI shows a trusted-looking session that is quietly running with fewer of the repo's settings than the TUI would. |
| Persisting trust for the session's **own** startup cwd | the dialog writes it | no control request; only `set_cwd` persists trust, and only for the directory it moves to | D | Workaround inside the protocol: launch in a neutral directory, then `set_cwd` into the project with the two-step trust handshake. Otherwise the GUI would have to write `~/.claude.json` itself, which the afleet design forbids. |
| Trust-drop warnings | `Dropped <N> project-scoped permissions.allow entr(y|ies) — workspace not yet trusted` and the long `Ignoring <N> <key> …` stderr line (03 §15.5) | the stderr line is suppressed in some interactive cases but printed non-interactively | R | Only visible on stderr — a GUI must capture and parse stderr to surface it, since it is not a stdout frame. |
| Managed-settings consent dialog | `Managed settings require approval` + `Yes, I trust these settings` / `No, exit Claude Code`; rejection writes `Managed settings were not approved; exiting without applying them.` and exits 1 (03 §15.8) | interactive-only; headless just exits or proceeds depending on state | X | A managed org can therefore make a GUI session die at startup with only a stderr line. The GUI should surface stderr verbatim on a non-zero exit. |
| Home-directory sessions | trust is never persisted at `$HOME`, so the dialog reappears every session (03 §15.4 step 5) | same rule inside `set_cwd` | P | |

## 03.5 `~/.claude.json` global state and env-driven settings

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Global config (`numStartups`, `theme`, `oauthAccount`, `installMethod`, `projects` map, hint counters, `tipsHistory`, `lastReleaseNotesSeen`, …) | written continuously by the harness; 03 §16.2–16.6 enumerate 126 read fields, 26 write-only fields and 11 per-project fields | not exposed by any control request | D | A GUI that wants the same state (onboarding flags, per-project MCP approvals, trust, tips) must read `~/.claude.json` itself. `get_settings` covers **settings only** — the global config is a separate store (03 §1). |
| Sixteen UI keys that fall back from settings → global config (`theme`, `editorMode`, `verbose`, `autoCompactEnabled`, `todoFeatureEnabled`, …) | 03 §16.5 | the fallback happens inside the CLI, so `effective` may be missing a key whose value is nevertheless in force | D | A GUI reading only `get_settings.effective` will show "unset" for a value the CLI is actually using from `~/.claude.json`. |
| `env` block injection | applied once at startup; safe-mode vs full-mode by trust; six filters; project-scope denylist; OTEL dominance (03 §12) | identical, but a headless session is always in the "session trust forced true / `fp()` false" state described above | P (mechanism) / D (visibility) | Nothing reports which env keys were dropped except one-time debug lines like `<KEY> in <settings file> is ignored — project-scoped settings can't set this key.` |
| `update_environment_variables` stdin frame | — | accepts exactly two names, `CLAUDE_CODE_SESSION_ACCESS_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN`; others refused with `[structuredIO] refused update_environment_variables for non-allowlisted keys: <keys>` (SPEC 45 §45.15.3, `chunk-zjj1wsm3.js:850787`) | D | There is no runtime env channel for anything else; a GUI must set env at spawn time. |
| Policy blocks the user tries to change | `/config` row is **hidden entirely** when the effective source is policy/flag (03 §18.3); `Couldn't save this setting: a trusted policy owns it (detail withheld on this connection).`; `settings defaultMode "bypassPermissions" ignored — only policy/user/flag settings may grant bypass mode …`; `"crossSessionInbound" … a repo may only tighten …` | the same strings come back from `/config key=value` headless | R | A GUI must compute row visibility itself from `get_settings.sources` (a key whose highest defining source is `policySettings`/`flagSettings` is locked). |
| Version floors/ceilings from managed settings | `requiredMinimumVersion` / `requiredMaximumVersion` refuse to **start** with a two-line message (49 §49.5.2) | same, on stderr, before any frame is emitted | R | A GUI must render stderr on a failed spawn or the session silently fails to start. |

---

## 49.1 Auto-update and version awareness

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Background auto-updater | one of three implementations chosen by install type; first check 10 s after **process start**, then every 30 min, globally throttled to one check per 5 min (49 §49.11) | the same loops run in a headless process — nothing in the headless path disables them | P (behaviour) / D (visibility) | The updater's status is rendered into TUI chrome only; no frame reports it. |
| "Update available / installed" banner | npm: `✓ Update installed · Restart to apply`, `✗ Auto-update failed: no write permission to npm prefix · Run claude doctor`, …; native: `Checking for updates`, `✓ Update installed · Restart to update`; package manager: `Update available! Run: <command>` (49 §49.11.3–49.11.5) | **no frame** carries any of it | D | Workaround for a GUI: (1) `get_binary_version` → `{version, buildTime}` (live-verified `{"version":"2.1.259","buildTime":"2026-09-02T18:43:49Z"}`), poll it and compare against `~/.claude/.last-update-result.json` (49 §49.15.1: `{timestamp, path, outcome, status, version_from, version_to, error_code}`), or (2) shell out to `claude doctor` and parse `Last update attempt: <summary>`. |
| How a long-lived headless process learns a new version exists | the TUI re-renders its banner; `/update` (disabled in 2.1.257) would restart in place | the running process **never changes version**; `system/init.claude_code_version` is stamped once per turn from `BUILD.VERSION` and every transcript record carries `version` (35 §35.4.1) | D | The only in-band signal a GUI gets is that the value never changes. Practical design: watch `~/.claude/.last-update-result.json` (mtime + `version_to`) or the versions directory, then offer "restart session on new build" — restarting the child is the GUI's job, since `/update` is compiled out. |
| `/update` (alias `/restart`) | restarts the session onto the new build, carrying the conversation; full refusal ladder (`bg_session`, `transcript_path_drift`, `active_tasks`, `uncarriable`, `bg_flush_failed`, `bg_spawn_failed`) (49 §49.14) | `isEnabled: () => !1, isHidden: !0` in 2.1.257 — dead in the TUI **and** headless; absent from the live command list | X | A GUI re-implements it as "stop child, respawn with `--resume <id>`". The refusal conditions (49 §49.14.1) are the correctness checklist to copy: don't restart while background tasks run, and flush the transcript first. |
| `claude update` / `claude upgrade` | full stdout transcript, 13 steps, exit codes tabulated (49 §49.12) | a separate process the GUI can spawn; unchanged | T/R | The GUI drives it as a subprocess and renders the transcript. Note `Updates are disabled by your administrator. Contact your IT team to get the latest version.` under `DISABLE_UPDATES`. |
| `claude install [target]` | in-session `/install` state machine (`Checking installation status...` → `Installing … <version>` → `Setup notes:` → `Claude Code successfully installed!`) (49 §49.13) | subprocess only; `/install` is `local-jsx` | T/R | |
| Release channel | `/config autoUpdatesChannel` row → **redirects to `/channel`**; the `Enable Auto-Updates` and `Switch to Stable Channel` dialogs with the downgrade warning (49 §49.4.1) | `/channel` is not in the live headless command list; `/config autoUpdatesChannel=` is refused by the redirect table | D | Workaround: `--settings '{"autoUpdatesChannel":"stable"}'` at launch (session-scoped) or a file edit. |
| Version display | `/status` `Version` row; `claude --version` prints `2.1.257 (Claude Code)`; `/version` is disabled in both variants (49 §49.2.1, §49.28.3) | `get_binary_version` (P) | P | |

## 49.2 `claude doctor` and `/doctor`

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/doctor` (alias `/checkup`) | a bundled **prompt** command: one large markdown template the model executes agentically; 10 checks; two confirmation gates via `AskUserQuestion`; `disableModelInvocation: true`, `terminalOriented: true`, `requires: {workspace:true}` (49 §49.19) | **present in the live headless command list** — a `prompt` command works headless unless `disableNonInteractive` | P | The GUI sends `/doctor` as a user message and renders the model's report. Its `AskUserQuestion` gates arrive as `can_use_tool` requests, so the GUI renders them as native dialogs — a strict improvement over the TUI's list widget. `terminal_slash_commands` on 2.1.259 = `["doctor","color"]`, i.e. the CLI *labels* `/doctor` terminal-oriented even though it runs fine headless. |
| `DISABLE_DOCTOR_COMMAND` | removes `/doctor` | same | P | |
| `claude doctor` (the CLI subcommand) | plain-text report: `Running: <type> (<version>)`, `Commit:`, `Platform:`, `Package manager:`, `Path:`, `Invoked:`, `Config install method:`, `Search:`, `Auto-updates:`, `Auto-update channel:`, `Last update attempt:`, then `Managed settings (remote)`, `Invalid settings`, status notices, `Environment variables`, `Multiple installations found`, `Remote Control`, `<n> warning(s) found` / `No installation issues found.` (49 §49.18.3) | a subprocess the GUI spawns; no session needed; exits 0; exempt from the managed version gate and from the trust prompt | R | This is the GUI's substitute for the `/status` System-diagnostics block and for the status-only settings notices `get_settings` drops. All 23 warnings and their `fix` strings are specified verbatim (49 §49.18.2), so a GUI can re-render them as structured rows instead of text. |
| `/skill-doctor` | own command, gated on `allow_skill_doctor_transcript_scan` | present in the live headless command list (`skill-doctor`) | P | |

## 49.3 `/debug` and the debug log

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/debug [issue]` | prompt command that **turns debug logging on as a side effect**, then hands the model the log path, a 20-line tail, the daemon block and the settings paths; pins `allowedTools: ["Read","Grep","Glob"]` (49 §49.20) | present in the live headless command list | P | Same side effect headless. The GUI gets the model's analysis as ordinary assistant frames. |
| `--debug` / `--debug=<filter>` / `--debug-to-stderr` | writes `<configHome>/debug/<sessionId>.txt`, one record per line `<ISO> [LEVEL] <message>`, rotates at 10 MiB to `<name>.1.txt`, maintains a `latest` symlink, drains synchronously at exit (49 §49.24) | identical flags on the headless launch; `--debug-to-stderr` sends the same stream to stderr and writes nothing to disk | P | For a GUI the stderr variant is the better channel: no file watching, and it interleaves with spawn failures. Note it is *unbuffered* whenever `--debug` is on. |
| `--debug-file <path>` / `CLAUDE_CODE_DEBUG_LOGS_DIR` | highest-priority log path; a directory value costs one failing append then self-heals to `<dir>/<sessionId>.txt` (49 §49.24.1) | same | P | Lets the GUI give each session its own log file next to its own state. |
| Debug-log retention | swept by `cleanupPeriodDays` (default 30), `latest` skipped (49 §49.24.7) | same | P | |
| `CLAUDE_CODE_DIAGNOSTICS_FILE` (structured NDJSON: `{timestamp, level, event, data}` with `uncaught_exception`, `unhandled_rejection`, `shutdown_signal`, `exited`, `<span>_started/_completed/_failed`) | 49 §49.26.5 | same env var | R | The single best crash-observability channel for a GUI host: point it at a per-session file and tail it. Nothing equivalent is on the wire. |
| Startup profiler (`CLAUDE_CODE_PROFILE_STARTUP` → `startup-perf/<sessionId>.{txt,json}`) | 49 §49.25 | same | P | Useful for a GUI that wants to show "why did this session take 4 s to start". |

## 49.4 `/status`

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/status` itself | opens the shared **Settings** dialog on the `Status` tab (tabs: Status, Config, Usage, Stats) (49 §49.21) | `local-jsx`; absent from the live headless command list; a headless invocation prints `/status opens an interactive panel and isn't available in this environment. Run it from the Claude Code terminal instead.` (`chunk-95p3p7y1.js:338523`) | X (as a panel) / R (as data) | Every row is separately obtainable — mapping below. |
| `Version` | `BUILD.VERSION` | `get_binary_version` → `{version, buildTime}`; also `system/init.claude_code_version` | P | |
| `Session name` / `Session ID` | name or `/rename to add a name`; id | `initialize` + `system/init.session_id`; name via `rename_session` / the `custom-title` transcript record | P | |
| `Session kind` (`interactive`, `background job · unattended/attached`) | 49 §49.21.1 | the host knows it launched the process; `sessionKind` is also stamped on every transcript record (35 §35.4.1) | P | |
| `Channels`, `Peer address`, `Memory paused` | 49 §49.21.1 | `channel_enable` control request; no frame for the peer address | D (peer address) | Minor. |
| `cwd` | current directory | `system/init.cwd`; `set_cwd` response `cwd` | P | |
| Account rows (`Login method`, `Auth token`, `API key`, `Profile`, `Organization`, `Email`, or `Login: Expired — log in again`) | 49 §49.21.1 | `initialize.account` (live-verified present); `--enable-auth-status` adds `auth_status` frames; `claude auth status [--json]` is the text twin | P | |
| `Claude Code on the web`, `Compliance` (`HIPAA` / `ZDR` / `Organization policy`), provider rows (`API provider`, base URLs, regions, `Proxy`, `Additional CA cert(s)`, mTLS cert/key) | 49 §49.21.1 | none of these are on the wire | D | Workaround: `claude doctor` covers the install/provider half; the compliance verdict is not printed anywhere a host can read. |
| `Model` | resolved main-loop model or `Default (<resolved>)` | `get_settings.applied.model`, `list_models`, `set_model` | P | |
| `IDE` (six connected/installed/error states) | 49 §49.21.1 | no frame | D | An afleet GUI supersedes this row anyway (it *is* the IDE). Classify as T in practice. |
| `MCP servers` (`<n connected>, <n cached>, <n need auth>, <n pending>, <n disabled>, <n failed> · /mcp`) | 49 §49.21.1 | `mcp_status` control request (live-verified) + `/mcp` command | P | |
| `Setting sources` / `Skipped sources` / `Managed settings (remote)` | 49 §49.21.1 | `get_settings.sources` gives the first two; the remote-managed state is not exposed | R + D (remote-managed state) | `claude doctor` prints `Managed settings (remote): <state>`. |
| `System diagnostics` block (`checkInstall` path guidance, `No write permissions for auto-updates`, launcher/`CLAUDE_CODE_PROCESS_WRAPPER` diagnostics, `Large <file> will impact performance (<n> chars > <max>)`) | 49 §49.21.2 | none on the wire | D | `claude doctor` covers the first three; the oversized-memory-file warning is only in `/status`. A GUI can recompute it: it is `chars > getMaxMemoryCharacterCount` over the loaded CLAUDE.md set. |

## 49.5 `/bug`, `/feedback`, the draft queue

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/bug` (alias `/share`) and `/feedback` | `local-jsx`, `requires:{ink:true}`; dialog `Submit feedback / bug report` → describe → **scope** (`This session only` / `+ last 24 hours` / `+ last 7 days`) → **consent screen** listing exactly what is sent (`Your feedback / bug description`, `Environment info`, `Remote workspace`, `Git repo metadata`, `Session transcript`) with the footer `We may use these to debug related issues and improve Claude Code.` (49 §49.22.3) | absent from the live headless command list; refused as a `local-jsx` command | X (dialog) / R (function) | The function is reachable: **`submit_feedback`** control request `{description, surface?, draft_id?, type?, title?, area?, attach_transcript?}` → `{feedback_id, unavailable_reason?, is_zdr_org?, failure_reason?, status_code?, ccshare_url?}` (SPEC 45 §2248; handler `chunk-2rhzyjym.js:178306-178329`). |
| The transcript-attach consent | three explicit steps in the TUI, with the scope words spelled out | headless: the non-draft path **always** passes the in-memory `messages` to the uploader; only the draft path honours `attach_transcript` (`chunk-2rhzyjym.js:178317-178322`) | D (consent) | A GUI **must** render its own consent screen before calling `submit_feedback`, and must not rely on `attach_transcript:false` to withhold the transcript on the non-draft path. This is a privacy-relevant divergence. |
| Scope selection (`session` / `day` / `week`) | 49 §49.22.3 | `submit_feedback` has no `scope` field; the SDK path uses `surface ?? "sdk"` and the current session's messages | D | Recent-session sweep (`recentSessionTranscripts`) is unreachable headless. |
| Disabled reasons | `<cmd> has been disabled via the DISABLE_FEEDBACK_COMMAND environment variable`, `… DISABLE_BUG_COMMAND …`, `… CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC …`, `<cmd> isn't available for your organization due to its compliance policy (HIPAA).` (49 §49.22.6) | `submit_feedback` returns `{feedback_id:null, unavailable_reason:<same string>}` | P | Good: the GUI can show the exact reason. |
| Bundle mode (third-party provider or no credentials) | writes `<configDir>/feedback-bundles/cc-<ts>-<6hex>.zip` and shows `Feedback bundle saved` (49 §49.22.2, §49.22.7) | the control request goes through the same mode selector | P | The response has no bundle-path field, so the GUI would have to look in `feedback-bundles/` to tell the user where the file is → minor D. |
| Success screens (`Thank you for your report!` + `Feedback ID:` with the prefilled GitHub-issue URL, or gated-on variant `Feedback sent` / `Reference ID:`) | 49 §49.22.7 | `feedback_id` (and `ccshare_url`) in the response | R | The GitHub-issue URL builder (title from a Haiku call, 7250-char budget) is TUI-only; a GUI can rebuild it or just link to the issues page. |
| `SendFeedback` tool + draft queue | model queues drafts; a card renders above the prompt (`1 → review`, `2 → send`, `0 → dismiss`, `+<n> more queued`), a footer counter, `/feedback` opens the `Feedback drafts` panel (49 §49.22.8–49.22.12) | `system/feedback_draft_queued` frame `{draft_id, draft_type, title, details_preview}` is on the wire (SPEC 45 §45.9.1; `chunk-1kg58a1a.js:111560`); submission via `submit_feedback {draft_id, …}` | P (notification) / R (panel) | A GUI gets the notification for free and rebuilds the review panel. The drafts themselves live at `~/.claude/feedback/drafts/<uuid>.json` (mode 0600, ≤10 kept, 30-day TTL) with the schema in 49 §49.22.9 — readable from disk if the GUI wants a list. |
| `feedbackDrafts` setting (`notify`/`quiet`/`off`) | changes card/counter behaviour; also `/config feedbackDrafts=` | `/config feedbackDrafts=off` works headless | P | |
| Exit nudge (`You have <n> unsent feedback draft(s)` / `enter → review & send   esc → discard and exit`) | 49 §49.22.14 | no equivalent — the headless process just exits | D | A GUI can query the drafts directory at session end and offer the same choice. |
| Session-quality survey (`How is Claude doing this session? (optional)`, keys 1–4/0, sampled at p=0.005) | 49 §49.22.15 | not on the wire | D | Negligible. |
| Per-message thumbs up/down | **does not exist** in the TUI (49 §49.22.15) | `message_rated` control request exists in the 66-request list | — | A GUI can *exceed* the TUI here: rate individual messages via `message_rated`. |

## 49.6 `/heapdump`, crashes, error reporting

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/heapdump` | hidden, `supportsNonInteractive: true`, gated purely on the org policy `allow_heap_dump`; writes `<Desktop>/<sessionId>.heapsnapshot` + `<sessionId>-diagnostics.json` (mode 0600) and prints an RSS/heap summary plus `Open the .heapsnapshot in Chrome DevTools → Memory → Load to inspect retainers.` (49 §49.23) | **present in the live headless command list** | P | Output arrives as command output frames; on a redacted connection only basenames are printed. |
| Uncaught exception / unhandled rejection | HTTP/2 teardown recovery budget (50/min), 10-in-5 s loop breaker, `CLAUDE_CODE_SUPERVISED` → exit 70, 10 s startup-mount watchdog printing `Claude Code could not start: <message>` (49 §49.26.1–49.26.4) | identical; the host sees a dead child plus stderr | R | A GUI should set `CLAUDE_CODE_SUPERVISED` (exit 70 is an unambiguous "it crashed" signal) and `CLAUDE_CODE_DIAGNOSTICS_FILE` for the reason. |
| Crash report upload (Datadog, gated by `DISABLE_ERROR_REPORTING`, provider, version ≥ 2.1.193, `tengu_orford_ness`, `allow_error_reporting`) | 49 §49.26.6 | identical | P | A privacy-minded GUI sets `DISABLE_ERROR_REPORTING`. |
| Unclean-exit detection | the marker is the **survival** of `~/.claude/sessions/<pid>.json`; reported once per process as a debug line + `tengu_unclean_exit`; **nothing is shown to the user** (49 §49.26.7; 35 §35.27.1) | identical | R | A GUI can do better: it owns the child pid, so it knows exactly when a session died uncleanly, and can offer resume immediately. |
| Resume hint on shutdown (`Resume this session with:` / `claude --resume <session>`) | printed on every TTY shutdown (49 §49.26.8) | not printed (stdout is not a TTY) | R | The GUI has the session id already. |
| Failed-resume messages (`Claude Code exited: startup failed after restoring the previous session (<reason>).`, `… could not continue the previous session (<reason>). Run claude --resume to pick a session, or start a new one.`) | 49 §49.26.8; 35 §35.16.3 | printed to stderr, then exit | R | Must be captured from stderr. |
| Fullscreen boot canary banners | 49 §49.26.8 | irrelevant | T | |
| Background-session auto-restart prompt injection | 49 §49.26.8 | applies to `--bg` sessions only | P | |
| API retry banner | TUI shows a retry indicator | `system/api_retry` frame `{attempt, max_retries, retry_delay_ms, error_status (null for connection errors), error, uuid, session_id}` (`chunk-sct99ax9.js:673390`); `control_request_progress` carries the same counters for `side_question` | P | There is no "Claude Code is having trouble" string in the bundle — the retry frame plus `result` error subtypes are the whole story. Rate-limit UX is chapter 08. |
| Rate-limit resume checkpoint | writes `<git root>/.claude/RESUME.md` and a private `refs/claude/checkpoint-<8>` ref; two dim lines `checkpointed — see <resumePath>` / `or /rewind to undo this turn's file edits`; **no failure is ever shown** (49 §49.27) | the checkpoint refuses with `skipReason: non_interactive` in a headless session (`chunk-cfwy8s58.js:444555`) | D | A headless GUI session gets **no** rate-limit checkpoint at all. If afleet wants the safety net it must snapshot the worktree itself. Gated anyway on `tengu_vellum_anchor` (default off). |

## 49.7 `/release-notes` and the remaining diagnostic commands

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/release-notes` | `local-jsx`, `requires:{ink:true}`; picker titled `Release notes`, subtitle `Select a version to view its notes.`, a `Show all` row + one row per version (`Version <v>` / `<n> item(s)`); reads **only** the fetched cache `<configDir>/cache/changelog.md`; empty cache prints `See the full changelog at: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md` (49 §49.28.4) | absent from the live headless command list; unreachable | X | Trivial for a GUI to exceed: fetch `https://raw.githubusercontent.com/anthropics/claude-code/refs/heads/main/CHANGELOG.md` itself, or read the same cache file, and parse with the documented rule (split on `/^## /gm`, truncate heading at `" - "`, take `- ` bullets). |
| Startup "what's new" notice | `Updated to latest. Got <n> features, <n> bugfixes and <n> other changes.` + `code.claude.com/docs/en/changelog for details`; keyed on `lastReleaseNotesSeen`; reads the **embedded** snapshot, which stops at 2.1.252 in a 2.1.257 build so upgrades from 2.1.252–2.1.256 show nothing (49 §49.28.4) | not emitted headless | R | A GUI that renders its own "what's new" should use the fetched changelog, not the embedded snapshot, and keep its own seen-marker. |
| `/upgrade` (plan upsell) | opens `https://claude.ai/upgrade/max?utm_source=claude_code&utm_medium=cli&utm_campaign=upgrade_command` and starts a fresh login (49 §49.28.1) | absent headless | X | The URL is a constant; a GUI can open it directly. |
| `/wellbeing` (break reminders, quiet hours) | `isEnabled: () => !1` — compiled in, switched off; the module returns `Wellbeing settings are not available in this build` (49 §49.28.2) | same | X | Nothing to reproduce; the `breakReminder`/`quietHours` settings keys exist but nothing reads them. |
| `/version` | both definitions `isEnabled: () => !1` (49 §49.28.3) | absent | X | Superseded by `get_binary_version`. |
| `/terminal-setup`, `/tui`, `/color` | terminal-only affordances | `color` is in the live headless command list and in `terminal_slash_commands` | T | A GUI supersedes all three; `terminal_slash_commands` (2.1.259: `["doctor","color"]`) is the CLI's own hint about which commands are terminal-shaped. |

---

## 35.1 The transcript on disk: record types a GUI must parse

The wire never replays history (35.8 below), so a GUI that shows a resumed conversation
**must read `~/.claude/projects/<projectKey>/<sessionId>.jsonl`**. Project key =
`cwd.replace(/[^a-zA-Z0-9]/g,"-")`, truncated at 200 chars + `-` + base-36 hash (35 §35.2.1).
One JSON object per line, mode 0600, append-only, torn tails sealed with a leading `\n`
(35 §35.3.1).

| Record type | Rendering consequence for a GUI | Class | Notes |
|---|---|---|---|
| `user`, `assistant` | the conversation itself; envelope adds `parentUuid`, `logicalParentUuid`, `isSidechain`, `agentId`, `promptId`, `sessionKind`, `userType`, `entrypoint`, `cwd`, `sessionId`, `version`, `gitBranch`, `slug`, `forkedFrom` (35 §35.4.1) | R | Must walk `parentUuid` backwards from the leaf, heal a missing parent with the nearest earlier same-`isSidechain` record within 5000 ms, then re-attach parallel tool results (assistants sharing `message.id` + their `tool_result` users) and non-conversation descendants (35 §35.13). Skipping this drops messages. |
| `attachment` | attachment payloads rendered inline | R | Drop types in the "never restore" set; backfill `displayPath` (35 §35.18). |
| `system` (incl. `subtype: "compact_boundary"`) | boundary carries `parentUuid: null` + `logicalParentUuid`; a boundary with neither `preservedSegment` nor `preservedMessages` is a **hard truncation point** — everything before it can be hidden (35 §35.5.13) | R | Also the reset point for context-collapse state. |
| `progress` | **not stored as a message**; its uuid is remapped to its parent | R | A GUI that renders it will double-render. |
| `summary` (`{summary, leafUuid}`) | the picker's summary column | R | No writer in 2.1.257 (35 open question) — treat as legacy/cloud-produced. |
| `custom-title`, `ai-title` | session title; last occurrence wins | R | `custom-title.json` sidecar mirrors the custom title so the title is readable without parsing the transcript. |
| `tag` | `#tag` badge and a search field | R | No local writer; SDK `tagSession` only. |
| `relocated` (`relocatedCwd`) | overrides the recorded `cwd` everywhere | R | Skipping it makes a moved session look like it belongs to the wrong project. |
| `last-prompt` (`lastPrompt`, `leafUuid`, `explicit`, `rewound`) | the leaf checkpoint; `leafUuid:null` + `explicit` = **cleared to empty**; `rewound:true` = a rewind anchor | R | This is how the loader picks the leaf; a GUI that ignores it will render a stale branch. |
| `ended-by-model`, `continued-in` | session lifecycle; `continued-in` marks a session superseded by a background fork | R | Drives the picker's `superseded` flag. |
| `history-suppression` | permanently taints the conversation for cloud egress; inherited by forks | R | Cosmetic for a local GUI, load-bearing if it ever uploads. |
| `agent-name`, `agent-color`, `agent-setting`, `mode`, `permission-mode`, `isolation-latch`, `atis-latch`, `worktree-state` | session-scoped UI/agent state the TUI restores on resume | R | `agent-name`/`agent-color` are what the picker shows as the row title. |
| `pr-link`, `frame-link` | `repo#PR` badge; artifact count badge `⧉ N` | R | |
| `file-history-snapshot`, `file-history-delta` | the rewind selector's checkpoint list (folded, capped at the last 100) | R | Needed to render "which messages can I rewind to". |
| `attribution-snapshot`, `content-replacement`, `fork-context-ref`, `observer-ref` | mostly internal; `fork-context-ref` explains a subagent's inherited context | R | |
| `cost-state` | `/cost` figures restored on resume | R | Alternative: `get_session_cost` control request (live-verified) — **P** for the live session. |
| `queue-operation` | queued-command bookkeeping | R | `command_lifecycle` frames cover the live case. |
| `artifact-comment-monitor`, `artifact-autoreact-ledger` | artifact state; **merged**, not last-wins | R | The autoreact ledger is the only record recognised by byte prefix. |
| `marble-origami-commit/-snapshot/-reset` | context-collapse state; a `reset` discards prior commits | R | |
| Subagent transcripts | `<sessionId>/subagents/agent-<agentId>.jsonl` (+ `agent-<agentId>.meta.json` with `agentType`, `description`, `model`, `permissionMode`, `parentAgentId`, …) (35 §35.11) | R | Live subagent text is on the wire only with `--forward-subagent-text` (text + thinking, `parent_tool_use_id` set); **tool calls, tool results and the subagent's own structure are not** — for those a GUI must read the sidecar files. Metadata sidecar is the only place `agentType`/`description` live. |
| Tool-result spill | `<sessionId>/tool-results/<id>.txt` (and `pdf-<n>/page-*.jpg`) (35 §35.10) | R | Keyed on the session's **original** cwd, so it does not follow a relocation. |
| `transcript_mirror` frames (`--session-mirror`) | — | `{type:"transcript_mirror", filePath, entries}` — every JSONL entry the writer appends, mirrored live (`chunk-2rhzyjym.js:175273`) | **P** | The single biggest win available to an afleet-style host: turn `--session-mirror` on and the GUI receives every sidecar record (titles, `last-prompt`, `file-history-*`, `pr-link`, `cost-state`, subagent lines with their `filePath`) without watching the filesystem. It mirrors **new writes only** — history still needs a file read. Failures surface as `system/mirror_error`. |

## 35.2 Session listing and the `/resume` picker

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/resume` picker | `local-jsx`; header `Resume session` + ` (<focused> of <total>)`; rows are label/description (no column headers); grouped by session id with `▼`/`▶`/`▸` tree prefixes (35 §35.19) | absent from the live headless command list; `--resume` with no value opens the picker only in a TTY | X (picker) / R (list) | The whole list is rebuildable from disk. |
| Row title | `agentName → customTitle → aiTitle → summary → firstPrompt → "Autonomous session" → sessionId.slice(0,8)`, XML-ish blocks stripped (35 §35.19.7, `getLogDisplayTitle`) | read from the JSONL head/tail | R | |
| Row description | `<relative time> · [bg ·] [branch ·] <file size> [· #tag] [· @agent] [· repo#PR]`, joined by ` · `; because list rows always carry `fileSize` the TUI shows **bytes, not a message count** (35 §35.19.7) | same fields from disk | R | A GUI can trivially exceed this by showing the real message count (it costs a full parse) and the first prompt. |
| The head-and-tail read | `readSessionLite`: first 64 KiB as `head`, last 64 KiB as `tail`, opened `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`; fields extracted by substring search, not JSON parsing (35 §35.14.2) | the same technique is what makes a 5000-session list fast | R | Field-by-field source table is in 35 §35.14.2 — copy it exactly, especially `firstPrompt = last lastPrompt in tail → head scan → first content/text truncated to 200`. |
| Picker drop rules | drop on: slug collision with a different real directory, `isSidechain`, `teamName`, `sessionKind ∈ {daemon, daemon-worker}`, foreign SDK `entrypoint`, `/loop` sessions; mark `superseded` when `continued-in` names a live successor; `bookkeepingOnly` flag (35 §35.14.3) | same rules apply to any list a GUI builds | R | Skipping them shows the user dozens of internal sessions. |
| Sort | `modified` desc, then `created` desc (35 §35.14.4) | same | R | |
| Discovery fan-out | current project dir + sibling worktree project dirs + `.session-aliases` dirs + `<slug>--claude-worktrees-*` + cross-project dirs whose recorded cwd matches, concurrency 32 (35 §35.19.1) | same | R | `.session-aliases` is a list of *other project directories*, written only by `/add-dir` (35 §35.16.9) — a GUI that ignores it loses sessions after an `/add-dir`. |
| Search | plain case-insensitive substring over **display title, git branch, tag, PR identifier only**; PR URLs rewritten to `PR #<n> <repo>`; **message-content search is dead code** (35 §35.19.4) | — | R | Easy win: a GUI can offer real full-text search over the JSONL, which the TUI cannot. |
| Filters | `Ctrl+A` all projects, `Ctrl+B` all branches, `Ctrl+W` all worktrees (35 §35.19.3) | — | R | |
| Preview pane | `Space` opens it; `Loading session…`, `Enter to resume`, `Esc to cancel`, metadata `<relative time> · <N> messages[ · <branch>]` (35 §35.19.8) | — | R | |
| Inline rename in the picker | `Ctrl+R` → `Rename session:`; calls `saveCustomTitle` **directly**, so only `String.trim()` is applied — no `ds()` sanitisation, no uniqueness check, no registry update (35 §35.19.9) | — | R | A GUI should use the `rename_session` control request instead, which does sanitise. |
| Resume a session running in the background | `Session <id> is running as a background session (<jobId>). Run \`claude attach <id>\` … Add --fork-session to branch off a copy instead.` (35 §35.16.4) | same refusal on `--resume` | P | The liveness source is `~/.claude/sessions/<pid>.json` (chapter 38 owns it). |
| Cross-directory resume | `This conversation is from a different directory.` + `cd <dir> && claude --resume <id>` copied to the clipboard (35 §35.19.8) | a GUI just spawns with the right cwd | R | |
| "continue" | `--continue` picks the newest non-superseded, non-live conversation; `No conversation found to continue`; `Your most recent conversation is running in the background (session <id>). …` (35 §35.16.3) | same flag | P | |
| "fork" from the picker | `--fork-session` bypasses every liveness check (35 §35.16.3) | same flag | P | |

## 35.3 Titles and `/rename`

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Two titles | `customTitle` (user/host) beats `aiTitle` (model-generated) everywhere (35 §35.15) | both are transcript records; `custom-title.json` sidecar mirrors the custom one | R | |
| AI title generation | once per fresh conversation at the start of the first turn, only if no custom/ai title, no agent type, terminal titles not disabled, and the first human message is not an XML wrapper or slash command; small-fast model, last 1000 chars, `{title}` JSON schema, skipped under 10 chars of input (35 §35.15.1–35.15.2) | the `--print`/stdin loop runs the same test (`chunk-2rhzyjym.js:178744-178764`), latched off when the loaded transcript already has non-system messages, in essential-traffic mode, or with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` | P | |
| `generate_session_title` control request | — | request `{description, persist}` → `{title}`; with `persist:true` it writes the `ai-title` record and adopts it (`chunk-2rhzyjym.js:178267-178295`) | P | Recovered schema (unpublished). Lets a GUI title a session on demand — e.g. from a first draft the user typed but has not sent. |
| `rename_session` control request | `/rename [name]`, aliases `/name`; with no argument it generates a kebab-case name (35 §35.15.5); collision-yield notice `Another live session on this machine goes by "<taken>", so this session is now "<assigned>". Use /rename to pick a different name.`; `Cannot rename: This session is a teammate. …` | `rename_session {title}`; `title must be non-empty`; sanitised by `ds()` (trim → collapse Cc/Cf/U+2028/U+2029 → strip C0/C1 → 200 code points → trim) (35 §35.15.3) | P | `/rename` is **also** in the live headless command list (`type:"local", supportsNonInteractive:true`), so both routes work. |
| Terminal-title side effect | `terminalTitleFromRename` (default true) makes `/rename` update the OSC-0 terminal title | irrelevant to a GUI | T | |
| `#tag` | no `/tag` command exists; SDK `tagSession` only (35 §35.15.8) | same | D | Minor; a GUI that wants labels must write them another way. |

## 35.4 `/clear`, `/compact`, conversation reset

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/clear` (aliases `/reset`, `/new`) | `Start a new session with empty context; previous session stays on disk (resumable with /resume)`; `type:"local", supportsNonInteractive:true, thinClientDispatch:"post-text"` (`chunk-1kg58a1a.js:143528`) | **present in the live headless command list**; emits a `conversation_reset` frame carrying `newConversationId` (`chunk-1kg58a1a.js:153349`; SPEC 45 §45.9.1 lists `conversation_reset` for `/clear` and plan-mode exit) | P | The GUI clears its view on the frame and keeps the old transcript for `/resume`. Also clears footer link badges and the rate-limit checkpoint store. |
| Effect on disk | a `last-prompt` record with `leafUuid:null, explicit:true` marks "cleared to empty" (35 §35.5.2) | same | R | A GUI reading the JSONL must honour `clearedToEmpty` or it will render a conversation the user cleared. |
| `/compact` | summarises and writes a `compact_boundary` | present in the live headless command list; `compact_boundary` frame + `system/status: compacting` are on the wire | P | Chapter 13 owns the mechanics. |
| Prompt history | `/clear` does **not** touch `~/.claude/history.jsonl` (35 §35.26.3) | same | P | |

## 35.5 `/branch`, `/fork`, `--fork-session`

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/branch [name]` | copies the live conversation into a brand-new `<newSessionId>.jsonl` in the same project dir, rewriting each record with `forkedFrom: {sessionId, messageUuid}`; titles are made unique as `<base> (Branch)`, `(Branch 2)`, …; success message `Branched conversation "<name>". You are now in the new branch (session <newId>). Use /resume <oldId> ("<oldTitle>") to return to the original …` (35 §35.22.1) | `local-jsx`; absent from the live headless command list | X | Rebuildable only by re-implementing the copier against the JSONL (the algorithm is fully specified, including the `history-suppression` inherit and the `neutralizedByFork` marking). Simpler GUI equivalent: spawn a new child with `--resume <id> --fork-session`, which gets the same *conversation* without copying the file. |
| `/fork [prompt]` | two variants; the fleet one copies the conversation into a new **background** session and keeps the current one working; `Couldn't fork: <message>. This session is unaffected; try again.`, `Forking is not available in coordinator sessions. Use /branch instead.`, `Couldn't fork — this conversation is still being saved. Try again in a moment.` (35 §35.22.2) | `local-jsx`; absent headless | X | Both variants ultimately spawn a child with `--resume <transcriptPath|sessionId> --fork-session [--session-id <uuid>]` and write a `continued-in` record into the parent transcript — exactly what a GUI would do itself. |
| `--fork-session` | new session id, no file adoption, metadata adopted **minus** worktree binding, relocated cwd, both artifact ledgers and the whole bridge binding; refusal-fallback records neutralised; `SessionStart` hook `source` becomes `"fork"` (35 §35.16.6) | same flag on the headless launch | P | Also: a transcript whose session id is neither a UUID nor a recognised custom id is *silently* forked even without the flag. |
| `--session-id` interaction | `Error: --session-id can only be used with --continue or --resume if --fork-session is also specified.`; `Error: Invalid session ID. Must be a valid UUID.`; `Error: Session ID <uuid> is already in use.` (35 §35.16.5) | same | P | Collision detection is a single `statSync` in the **current project directory only** — a GUI reusing ids across directories will not be caught. |

## 35.6 `/export`

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/export [filename]` | `local-jsx`, `requires:{ink:true}`; dialog `Export conversation` → `Copy to clipboard` / `Save to file` (`… in the current directory` or `… in the directory claude was launched from` for remote workspaces) → `Enter filename:` (35 §35.21) | absent from the live headless command list | X | |
| Format | **plain text only** — the detailed-transcript renderer's static frames concatenated and ANSI-stripped (`Bun.stripANSI`); no JSON, no Markdown option; width `max(80, columns-6)` when driven programmatically (35 §35.21) | — | R | A GUI can trivially exceed the TUI: it owns the message objects (or the JSONL) and can emit Markdown, HTML or JSON. |
| Default filename | `<YYYY-MM-DD-HHMMSS>-<slug>.txt` from the first user message (lower-cased, non-`[a-z0-9\s-]` stripped, whitespace → `-`, 49 chars + `…`), else `conversation-<stamp>.txt`; extensionless paths get `.txt` (35 §35.21) | — | R | Worth copying for familiarity. |
| Result strings | `Conversation copied to clipboard`, `Conversation exported to: <path>`, `Failed to export conversation: <message>`, `Export cancelled` | — | R | |

## 35.7 `/rewind` and checkpoints

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/rewind` (aliases `/checkpoint`, `/undo`) | `type:"local", supportsNonInteractive:false`; the whole module just emits `open_message_selector`; the same dialog opens on double-Esc. Options: `Restore code and conversation`, `Restore conversation`, `Restore code`, `Summarize from here`, `Summarize up to here`, `Never mind`; diff-stat previews `The code will be unchanged.` / `The code has not changed (nothing will be restored).`; warning `Rewinding does not affect files edited manually or via bash.` (15 §15.12.8) | absent from the live headless command list; `open_message_selector` is in the **dropped-before-the-wire** filter (BRIEF 45.9.2) | X (dialog) / R (function) | The GUI rebuilds the message selector from its own message list plus `file-history-snapshot`/`-delta` records, then calls the two control requests below. |
| File snapshots | taken before every `Edit`/`Write`/`NotebookEdit` and the intercepted sed-edit path; ordinary `Bash` writes are **not** checkpointed; anchored to a user message (15 §15.12.4) | same; `fileCheckpointingEnabled` (default true) gates it, settable via `/config checkpoints=` | P | The GUI must repeat the "bash edits are not covered" warning or users will lose work. |
| `rewind_files` control request | — | `{user_message_id, dry_run?}` → `{canRewind, error?, filesChanged?, insertions?, deletions?, skippedLinks?}` (SPEC 45 §2222, `chunk-2rhzyjym.js:177376`) | P | `dry_run` gives exactly the diff-stat preview the TUI shows. Errors: `File rewinding is not enabled.`, `No file checkpoint found for this message.`, `rewindFiles: no turn received yet`, and in cloud sessions `Rewind is not yet available in cloud sessions`. Skipped-link reporting text is in 15 §15.12.7. |
| `rewind_conversation` control request | — | request `{target_message_uuid, interrupt_if_running?, last_seen_user_message_uuid?}` → `{rewound: true, targetMessageUuid, prefillText, precedingAssistantUuid}` or `{rewound:false, prefillText:null, precedingAssistantUuid:null, error}` with `error ∈ "commands queued" \| "prompt pending" \| "turn running" \| "target not found" \| "stale target" \| "unseen later turn" \| "poll tool_result target" \| "delivered poll events in range" \| "failed to persist rewind anchor" \| "state changed"` (recovered from `chunk-2rhzyjym.js:177455-177585`; SPEC 45 lists it as *no published schema*) | P | `prefillText` is the rewound user message's original text — the GUI puts it back in the composer, exactly like the TUI. `precedingAssistantUuid` lets the GUI anchor its view. `interrupt_if_running:true` makes the CLI abort an in-flight turn (10 s budget) before rewinding. |
| `--rewind-files <uuid>` | hidden CLI flag: restore files at that user message and exit; `Files rewound to state at message <id>` (15 §15.12.8) | requires `--resume`; `Error: --rewind-files requires --resume`, `… is a standalone operation and cannot be used with a prompt`, `… requires a user message UUID, but <value> is not a user message in this session` | P | A one-shot subprocess is a clean way for a GUI to offer "restore files" without touching the live session. |
| Rewind traces on disk | `removeTranscriptMessage` splices the record out in place (≤50 MiB fast path); the surviving `last-prompt` carries `rewound: true` and becomes `rewindAnchorUuid` on load (35 §35.9, §35.12.3) | same | R | A GUI reading the JSONL must honour `rewindAnchorUuid`. |

## 35.8 Resume semantics headless (does the wire replay history?)

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| **History on resume** | the TUI re-renders the loaded conversation from memory | **No history frames are emitted.** The loaded chain becomes the in-memory list `St = M` and is never written to stdout (`chunk-2rhzyjym.js:175402` and the surrounding `runHeadlessStreaming` body); the only echo mechanism is `--replay-user-messages`, which re-emits messages **the host itself submitted** with `isReplay:true` (SPEC 45 §45.12.3) | **D** | This is the load-bearing conclusion of this area: **a GUI resuming a session must read the JSONL itself** (or have mirrored it earlier). `--session-mirror` does not help retroactively — it mirrors new appends only. |
| Session id on resume | — | `system/init` at the start of the first turn carries `session_id`; `initialize` carries `session_state` | P | |
| SessionStart hook | runs with `source: "resume"` or `"fork"`; hook-produced context is appended (deduplicated) | same; visible with `--include-hook-events` | P | |
| Interrupted-turn handling | on load the tail is classified `none` / `interrupted_turn` / `interrupted_prompt`; `interrupted_turn` appends a meta user message `Continue from where you left off.` (override: `CLAUDE_CODE_RESUME_PROMPT`), and a trailing user message gets a synthetic assistant `"No response requested."` (35 §35.18) | same, and `CLAUDE_CODE_RESUME_INTERRUPTED_TURN` enables auto-replay | P | A GUI that also renders the JSONL will see these synthetic records — it should suppress `isMeta` records the way the TUI does. |
| Permission mode on resume | restored **except** `plan` and `bypassPermissions`, except when the CLI set one; `auto` only if the gate is on (35 §35.17.4) | same; deferred tool uses warn `Deferred tool resume: permissionMode mismatch (deferred under '<a>', resuming under '<b>'). --resume does not restore permissionMode — pass --permission-mode <a> to match.` | P | The GUI should pass `--permission-mode` explicitly rather than rely on restoration. |
| Model on resume | restored from the last assistant record unless pinned by CLI/env/settings; decline warning `Session model <model> could not be restored (<reason>) — using <fallback> instead.` (35 §35.17.5) | same | P | |
| Worktree re-entry | five outcome messages, only a *poisoned* rejection clears the binding (35 §35.17.3) | same, printed to stderr | R | Must be captured from stderr. |
| Agent restoration | `This session was running agent '<type>', which is no longer available … Continuing with the default tools and system prompt …` (35 §35.17.2) | same | R | |
| Unchained transcript | one-paragraph warning to the debug log **and to stderr** when running non-interactively (35 §35.13) | same | R | Good signal for a GUI that writes its own transcripts. |
| `--resume` resolution | UUID → absolute `.jsonl` path → exact title → picker (35 §35.16.4) | in print mode there is **no picker**: `Error: --resume "<value>" matches <N> sessions. Pass one of these session IDs to disambiguate:` / `Error: --resume requires a valid session ID or session title when used with --print.` | P | The GUI should always resolve to a UUID itself. |
| `--resume-session-at` / `--resume-drops-turn` | hidden print-mode-only truncating resume | headless-only flags | P | Lets a GUI implement "reopen this session as of message X" without rewriting the file. |
| `--no-session-persistence` | disables transcript writes entirely; **print mode only** (`Error: --no-session-persistence can only be used with --print mode.`) (35 §35.28.1) | same | P | For an afleet "incognito" session. Consequence: nothing to read back, no resume, and the GUI becomes the only record. |
| Other persistence kill switches | `CLAUDE_CODE_SKIP_PROMPT_HISTORY` (disables transcript **and** prompt history), the inherited `CLAUDE_CODE_CHILD_SESSION` marker (override `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`); banners `Transcript saving is off — CLAUDE_CODE_SKIP_PROMPT_HISTORY is set · --resume will not find this session; if unintended, unset it and restart` (35 §35.3.2, §35.26.6) | same | R | A GUI spawning children must not leak `CLAUDE_CODE_CHILD_SESSION`, or its child sessions silently stop persisting. |
| `--session-mirror` | — | `transcript_mirror` frames; failures as `system/mirror_error` | P | See 35.1. |

## 35.9 Relocation, registry, prompt history

| Feature | TUI behaviour (cite SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Transcript relocation on cwd change | the `.jsonl` **and** the `<sessionId>/` sidecar directory are *moved* into the new project dir; a `relocated` record is appended; concurrent appends are parked in a relocation bracket (35 §35.23) | triggered by `set_cwd`; the response's `transcript_relocated` boolean reports it | P | A GUI caching the transcript path must re-resolve it after every `set_cwd`. |
| `~/.claude/sessions/<pid>.json` live registry | liveness, names, `status`/`waitingFor`/`tempo`, tmux coordinates; reaped by liveness, never by age; `/resume` never reads it (35 §35.27.1) | chapter 38 owns it | — | Noted only: it is how "is this session still running" is decided, and it is what makes a stale entry mean "unclean exit". A GUI supervising its own children does not need it. |
| `~/.claude/history.jsonl` prompt history | up-arrow recall (project-scoped, cap 100), Ctrl+R inline reverse search (no scope filter), fullscreen "Search prompts" picker with `session`/`project`/`everywhere` scopes, `History n/m` badge (35 §35.26.4) | not on the wire and not written by a headless session in the normal case: `add()` records typed prompts, slash commands, `!bash`, `@file`, queued prompts and discarded drafts — but **non-interactive `-p`/SDK runs are explicitly listed as "not recorded"** (35 §35.26.3) | D | So an afleet GUI gets no prompt history for free **and contributes none**. It must keep its own; if it wants continuity with the terminal it can read `~/.claude/history.jsonl` (record shape, paste offload at >1024 chars into `paste-cache/<16 hex>.txt`, and the newest-first readers are fully specified in 35 §35.26). |
| Paste cache | `[Pasted text #<n> +<m> lines]` placeholders; content-addressed files; lost content renders `<label> #<id> is no longer available and was removed from the prompt` (35 §35.26.5–35.26.6) | same file layout | R | A GUI doing large pastes should reuse the same placeholder convention so the model sees familiar text. |
| Retention sweep | one-shot per process, armed at the first user prompt (interactive) or right after MCP connect (`--print`); 30-day default on **mtime**; hourly `touchSessionTranscript` heartbeat keeps a long session's own transcript alive (35 §35.24.1) | identical in headless | P | Consequence for a GUI: a long-lived session whose process is *not* the one that owns the transcript will not be heartbeated. Also `cleanupPeriodDays: 0` disables the whole sweep, and the sweep refuses entirely when settings have validation errors (`Skipping cleanup: settings have validation errors but <key> was explicitly set.`). |
| Quarantine / torn tails | `<sessionId>.orphaned-<epochms>-<hex8>.jsonl` for unattributable transcripts; torn tails sealed with a leading newline (35 §35.2.6, §35.3.1) | same | R | A GUI listing project directories must ignore `.orphaned-*` files. |

---

## Top gaps in this area

1. **`update_settings` writes exactly one key.** Source must be `localSettings` *and* the
   only accepted key is `outputStyle`; values must be strings and deletion is unsupported
   (`chunk-2rhzyjym.js:174361-174379`). SPEC 45 §45.22.8 does not say this. Every other
   persisted setting must go through `/config key=value` (59 rows, works headless) or a
   file edit. **D.**
2. **Resuming replays nothing.** The wire never re-emits a loaded conversation
   (`chunk-2rhzyjym.js:175402`); `--replay-user-messages` only echoes what the host sent.
   A GUI must parse `~/.claude/projects/<key>/<sessionId>.jsonl`, including chain
   reconstruction, parallel-tool-result recovery and the `last-prompt` leaf rule, or it
   shows the wrong history. **D.**
3. **`--session-mirror` is the highest-leverage flag in this area and is not in the afleet
   launch line.** `{type:"transcript_mirror", filePath, entries}` delivers every JSONL
   record — titles, leaf checkpoints, file-history snapshots, PR links, cost state, subagent
   lines — live, removing almost all filesystem watching. Add it. **P (unused).**
4. **No settings-change notification.** External edits *are* picked up (chokidar, ~1.5 s;
   MDM polled every 30 min), but no frame announces it. A GUI must poll `get_settings` or
   install a `ConfigChange` hook as its own push channel. **D.**
5. **Workspace trust is silently degraded in `-p`.** The dialog never runs, the session
   trust flag is forced true but the *persisted* flag stays false, so repo `permissions.allow`,
   `permissions.additionalDirectories`, hooks, `statusLine`, `fileSuggestion` and every
   credential helper are dropped and `env` is applied in safe mode (03 §15.4 step 8, §15.5).
   The only in-protocol way to persist trust is the `set_cwd` `needs_trust` handshake, which
   covers the *target* of a directory change, not the startup cwd. **D + security.**
6. **A long-lived headless process can never learn a new build exists in-band.** `/update`
   is compiled out, no frame carries the updater's banner, and `get_binary_version` is
   constant for the process's life. The GUI must watch
   `~/.claude/.last-update-result.json` (or shell out to `claude doctor`) and offer its own
   "restart on new version". **D.**
7. **`/bug` consent is not enforced headless.** On the non-draft path `submit_feedback`
   always uploads the current session's messages regardless of `attach_transcript`
   (`chunk-2rhzyjym.js:178317-178322`). The GUI must render its own consent screen with the
   TUI's five-bullet disclosure before calling it. **D + privacy.**
8. **`/status` is unreachable but almost fully reconstructible.** Version, account, model,
   MCP counts, setting sources and cwd all have control requests; the residue —
   compliance verdict (HIPAA/ZDR/org policy), provider/proxy/mTLS rows, the
   `System diagnostics` block and the oversized-CLAUDE.md warning — has no wire source.
   `claude doctor` as a subprocess covers most of the diagnostics half. **R + D.**
9. **`/permissions` has no headless editor.** Rules can only be *added* as a side effect of
   answering `can_use_tool` with `updatedPermissions` (which the CLI persists); there is no
   list, edit or delete path. **X + partial workaround.**
10. **`/rewind` is unreachable as a dialog but complete as a pair of control requests.**
    `rewind_files {user_message_id, dry_run}` gives the exact diff-stat preview and
    `rewind_conversation {target_message_uuid, interrupt_if_running, last_seen_user_message_uuid}`
    returns `{rewound, targetMessageUuid, prefillText, precedingAssistantUuid, error}` with
    ten distinct error strings. Both schemas were unpublished; they are recovered above.
    Building the message selector is the GUI's only real work. **R.**
11. **Status-only settings notices and validation metadata are dropped.**
    `get_settings.errors` keeps only non-warning records and only `{file, path, message}` —
    no `severity`, `suggestion`, `docLink`. The TUI's Settings Error/Warning modal, its
    suggestion column and the "Fix with Claude" flow all need `claude doctor` or a re-read
    of the files to reconstruct. **D.**
12. **`~/.claude.json` is invisible to the protocol.** Onboarding flags, the `projects` map
    (trust, MCP approvals, per-project state), tips history, `lastReleaseNotesSeen`,
    `installMethod` and the sixteen UI keys that fall back from settings to the global
    config are all outside `get_settings`. A GUI that shows "unset" for one of those keys
    will be wrong. **D.**
13. **`--print` sessions contribute nothing to prompt history** and read none of it, so an
    afleet GUI starts with an empty recall list unless it reads `~/.claude/history.jsonl`
    itself (record shape and the paste-cache offload rule are fully specified). **D.**
14. **The rate-limit resume checkpoint never fires headless** (`skipReason:
    non_interactive`), so `.claude/RESUME.md` and the `refs/claude/checkpoint-*` snapshot —
    the TUI's safety net when a five-hour window closes mid-task — simply do not exist for
    a GUI session. **D.**
15. **`/export`, `/branch`, `/release-notes`, `/upgrade` are `local-jsx` and unreachable**,
    but each is trivially exceeded by a GUI: real Markdown/JSON export instead of ANSI-stripped
    text, `--resume … --fork-session` instead of a file copy, the fetched changelog instead
    of a stale embedded snapshot, and a plain link for the upsell. **X → opportunity.**

## Unverified

* I did not exercise `apply_flag_settings` with an arbitrary key at runtime; the claim that
  the local stdio path accepts any settings key rests on reading the merge
  (`ixe({...RW(), ...patch})` at `chunk-2rhzyjym.js:178133-178139`) and on the absence of an
  allowlist in that branch — in contrast to the bridge, which has an explicit one.
* The claim that a headless process picks up external settings edits is inferred from the
  watcher being process-wide and unconditioned on interactivity (03 §14.2); I did not
  observe a live headless process reacting to an edit.
* `terminal_slash_commands = ["doctor","color"]` comes from the brief's 2.1.259 capture, not
  from a frame in `init-dump.json` (that probe ran no turn, so no `system/init` frame exists
  in it).
* The `/config` row → store mapping (user settings vs `.claude/settings.local.json` vs
  `~/.claude.json`) is taken from SPEC 03 §18.3; I extracted the 59 row ids directly from
  `chunk-wftr5q3n.js:776960-777325` but did not re-derive each row's persistence closure.
* Whether a `can_use_tool` `updatedPermissions` answer can target a *user*-scope destination
  (and therefore fully substitute for `/permissions`) is chapter 24/45 territory; I only
  verified that such updates are applied to the session context **and persisted**
  (SPEC 45 line 2600).
* The statement that `submit_feedback` ignores `attach_transcript` on the non-draft path is
  read from the handler passing `messages: St` unconditionally to `Zhe(...)`
  (`chunk-2rhzyjym.js:178320`); I did not trace `Zhe` to confirm it has no second consent
  gate of its own.
* Chapter 41 (the `/config` panel's rows and rendering) and chapter 38 (`~/.claude/sessions/`)
  belong to other agents; I covered them only where 03/35 defines the data.
