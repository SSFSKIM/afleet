<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# 28 — Slash commands: TUI-vs-headless gap inventory

Source chapter: `/Users/probe/claude-code-bundle/2.1.257/SPEC/28-slash-commands.md` (read in full,
§25 verbatim prompt bodies skimmed, §26 telemetry skipped per brief).
Live cross-check: `/tmp/afleet-gap/init-dump.json` (2.1.259 `initialize` control_response,
102 advertised commands).

---

## 0. How to read this area

### 0.1 The three command types and what "headless" means

Three types exist (§1, `chunk-1kg58a1a.js:145407-145418`): `local` (runs a function, prints into the
transcript as `<local-command-stdout>`), `local-jsx` (opens an Ink dialog in the terminal), `prompt`
(expands to content blocks and runs a model turn). The headless filter is mechanical
(§22, `chunk-1kg58a1a.js:145440-145446`):

```js
function filterCommandsForHeadless(e) { if (slashCommandsDisabled()) return []; return e.filter(runsHeadless); }
function runsHeadless(e) {
  return e.type === "prompt" && !e.disableNonInteractive
      || e.type === "local" && e.supportsNonInteractive;
}
```

Every "Headless status" cell below is derived from that rule plus the row's `isEnabled` predicate.
The six values used:

| Value | Meaning |
|---|---|
| `runs-as-text` | the command executes in `-p` and its output arrives as an ordinary transcript message |
| `refused (local-jsx)` | `type: "local-jsx"` — refused with the §8.1 row-4 panel message, no exceptions |
| `refused (local, N-I false)` | `type: "local"` with `supportsNonInteractive: false` — filtered out of the list; typing it yields "isn't available in this environment" |
| `terminal-only` | `terminalOriented: true` and/or `disableNonInteractive` — the effect only exists on the machine with the terminal |
| `disabled in build` | `isEnabled: () => false` in 2.1.257 — never registered anywhere |
| `gated` | registration depends on a GrowthBook flag, entitlement, policy or platform check that may be off |

### 0.2 The correction a GUI most needs: "advertised" vs "runnable"

The brief warned that `initialize.commands` is `advertisedSlashCommands` (`userInvocable !== false
&& !isSkillOff`) and therefore not the runnable list. **In `-p` mode that distinction collapses, and
the live capture proves it.** The headless runner narrows its command list with
`filterCommandsForHeadless` *before* anything is advertised
(`cli.pretty.js:176040`, `os = _pe(await If(...))`, where `_pe` is the filter at
`cli.pretty.js:145440`); `advertisedSlashCommands` then runs on that already-narrowed array
(§23.2, `chunk-2rhzyjym.js:172443`).

I verified this mechanically. Taking the 126 §5 catalogue rows, keeping every `prompt` without
`disableNonInteractive` and every `local` with `supportsNonInteractive: ✓`, yields 35 predicted
names. The live 2.1.259 advertisement contains exactly 33 of them and **zero** names outside that
prediction — no `local-jsx` command, no `local` with `N-I false`, and not `/statusline`. The two
missing names are explained by their own gates: `/pause-memory` (`isEnabled: () => false`) and
`/plugin-types` (`tengu_plugin_hooks_modules` off on this account).

So the practical GUI rule is: **on this transport, `initialize.commands` *is* the runnable list**,
minus commands that are `userInvocable: false`. Two caveats remain, and both matter:

* `isHidden` is **not** applied to the advertisement. `__remote-workflow` and `workflow-launch-exec`
  are both `isHidden: true` and both appear in the live 102. A GUI that renders the array verbatim
  in a command palette will show internal plumbing the TUI hides. The wire carries no `isHidden`
  flag, so the GUI must maintain its own suppression list — that is a real data gap.
* The advertisement is a snapshot. `commands_changed` is a stdout frame (SPEC 45.9.1); a GUI must
  re-read the list on it rather than caching from the first `initialize`.

A live behaviour probe (32 commands sent as `user` frames on 2.1.259, recorded in
`/tmp/afleet-gap/EVIDENCE-slash-commands.md`) confirms the rule from the other direction: every
command absent from the advertisement was refused, and every command present ran. Per-row results
are folded into the master table below as **Live 2.1.259** notes.

### 0.3 What the wire never carries about a command

`initialize.commands` entries are `{ name, description, argumentHint, aliases? }` only
(§23.2 `toWire`). Everything else the TUI menu uses is dropped: `isHidden`, `type`, `source`,
`loadedFrom`, `kind`, `menuDescription`, `argNames`, `whenToUse`, `pluginInfo`,
`getArgumentCompletions`, `immediate`, `subcommands`, `policyGate`, `thinClientDispatch`. Several
gaps below are consequences of exactly this.

---

## 1. Master command table

109 rows covering all 126 catalogue objects from §5 (17 names ship as interactive/headless twins and
are one row each: `auto-mode-setup, autocompact, color, config, context, effort, extra-usage, fast,
goal, import, mcp, model, rename, skill-doctor, ultrareview, usage, usage-credits`; 109 + 17 = 126).
Five further rows describe the dynamic sources (§3.1 #1–#6, §13, §18, §19, §20) as classes.

"Live" marks whether the name is in the 2.1.259 advertisement (Y/·).

| Command | Type(s) | Headless status | Route for a GUI | What the TUI version shows that the GUI must rebuild | Class | Notes |
|---|---|---|---|---|---|---|
| `/add-dir` | local-jsx | refused (local-jsx) · | `add_directory` control request | Path-entry dialog with validation and a "directory added" confirmation | R | Control request replaces it cleanly; GUI supplies its own native folder picker, which beats the TUI's typed path. `--add-dir` at launch does the same thing. **Live 2.1.259:** REFUSED with `/add-dir isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/advisor` | local-jsx | refused (local-jsx) · gated (`tengu_sage_compass2` + first-party + `!CLAUDE_CODE_DISABLE_ADVISOR_TOOL`) | none named; `thinClientDispatch: control-request` but SPEC 45.29 does not name the request | Model-picker dialog for the consult-a-stronger-model feature, plus current on/off state | D | The only `control-request` command whose target request the spec does not name. Nearest workaround: write the advisor setting through `update_settings` (localSettings only) and restart; unverified whether that takes effect mid-session. |
| `/agents` | local | runs-as-text Y | none needed | Nothing — the body is a static "(removed)" pointer to `.claude/agents/` | P | `initialize.agents` already carries the agent list (present in the live dump); the GUI should render an agent manager rather than echo this string. **Live 2.1.259:** RAN, printing the static removal notice (`The /agents wizard has been removed. Ask Claude to create or update subagents for you …`). |
| `/artifacts` | local-jsx | refused (local-jsx) · gated (artifacts enabled, no stub dir) | none | Browser over published/shared artifacts | X | Ch. 44 owns the data path; no control request exposes it. |
| `/auto-mode-setup` | local-jsx + local | runs-as-text (local twin) Y | none; drive the local twin's argument grammar | Interactive wizard; the headless twin takes `[--request-id <uuid>] (--wizard posture=… scope=… depth=… --propose \| --expect-sha256 <64-hex> --apply-file <path>)` | R | Unusually good headless story: the local twin exposes a full propose/apply protocol with a SHA-256 guard, so a GUI can render its own wizard and apply atomically. Also the only `local`/`local-jsx` command `skillOverrides` can switch off (§20.1). |
| `/autocompact` | local-jsx + local | runs-as-text (local twin) Y | `update_settings` (localSettings) for persistence; `apply_flag_settings` for the session | Slider/selector for the auto-compact window with the current threshold rendered | R | `autocompact_state` frames only arrive under `CLAUDE_CODE_REMOTE` (SPEC 45.9.1), so a plain GUI host does not get live threshold telemetry — read it back by running the command. |
| `/autofix-pr` | local-jsx | refused (local-jsx) · gated (claude.ai + `allow_remote_sessions`) | none | PR-monitoring launcher | X | Cloud feature, ch. 37. |
| `/background` (`bg`) | local-jsx | refused (local-jsx) · gated (FleetView on) | none | "Send this session to the background" handoff with a prompt field | X/T | FleetView-only concept. A GUI already owns window lifecycle; it should implement backgrounding natively rather than route this. **Live 2.1.259:** REFUSED with `/background isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/branch` | local-jsx | refused (local-jsx) · | none | Name-entry dialog; forks the conversation at the current point | R (disk) | No control request. The GUI can rebuild it: copy the session JSONL up to the chosen message and launch with `--session-id` (ch. 35). Non-trivial but fully reachable. **Live 2.1.259:** REFUSED with `/branch isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/brief` | local-jsx | refused (local-jsx) · gated (`briefConfig.enable_slash_command`) | none | Toggles brief-only transcript rendering | T | Pure TUI render mode; a GUI implements its own density control. **Live 2.1.259:** REFUSED with `/brief isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/btw` | local-jsx | refused (local-jsx) · | `side_question` control request | Inline side-question panel that does not disturb the main turn | P | `control_request_progress` frames are emitted for `side_question` only (SPEC 45.9.1), so the GUI gets streaming progress for free. Best-supported command in the chapter. **Live 2.1.259:** REFUSED with `/btw isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/bug` (`share`) | local-jsx | refused (local-jsx) · | `submit_feedback` control request | Multi-step dialog: description field, consent to attach transcript, submitted-ID confirmation | R | `feedback_draft_queued` is a stdout frame. The GUI must rebuild the consent copy itself — the wire carries no template. **Live 2.1.259:** REFUSED with `/bug isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/cd` | local-jsx | refused (local-jsx) · | `set_cwd` control request | Path dialog + confirmation of the new working directory | R | Same as `/add-dir`; GUI can exceed the TUI with a native picker. **Live 2.1.259:** REFUSED with `/cd isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/chrome` | local-jsx | refused (local-jsx) · gated (`!isNonInteractive()`, availability `claude-ai`) | none | Claude-in-Chrome settings panel | X | Ch. 46. |
| `/clear` (`reset`, `new`) | local | runs-as-text Y | send as text; `conversation_reset` frame confirms | Confirmation and the "previous session stays on disk (resumable with /resume)" reassurance | P | `thinClientDispatch: post-text`. A GUI will usually want its own new-session action instead, but the command works. |
| `/cloud-plugins` | local-jsx | refused (local-jsx) · gated (cloud plugins available, `!CLAUDE_CODE_DISABLE_PLUGIN_FORWARDING`) | `update_settings` (localSettings) | Yes/no choice for forwarding local plugins to cloud sessions | R | Setting-shaped; `requires: { workspace: false, ink: true }`. |
| `/color` | local-jsx + local | runs-as-text (local twin) Y · `terminalOriented` | `set_color` control request | Prompt-bar colour swatch list | T | One of the two names in `terminal_slash_commands` on 2.1.259. The prompt bar is a terminal artefact; `set_color` exists so a remote UI can still tint its own chrome. **Live 2.1.259:** RAN despite `terminalOriented`: `Session color set to: red`. So the terminal-oriented marker does not imply headless refusal. |
| `/compact` | local | runs-as-text Y | send as text | Spinner, then the summary; the pre/post token counts | P | Engine-deferred (§23.3, `deferSlashToEngine` is true only for `compact`): the dispatcher emits the user message and lets the query loop own it. Wire gives `system/status: compacting` and a `compact_boundary` frame. |
| `/config` (`settings`) | local-jsx + local | runs-as-text (local twin, `key=value` only) Y | `get_settings` + `update_settings` (**localSettings only**) | Full settings browser: grouped keys, current values, source of each value, live toggles | R with a real edge | The TUI dialog edits any scope; `update_settings` writes only `.claude/settings.local.json`. A GUI cannot change user, project, policy or flag settings over the wire — it must edit those files directly on disk, and then nothing tells the running session to re-read them. Also the destination of `/vim`, `/output-style` and `/theme`, so this row carries their weight too. `getArgumentCompletions` on the local-jsx variant is client-side and lost. **Live 2.1.259:** RAN. With no arguments the local twin prints the full settable-key list (`agentPushNotifEnabled`, `autoCompact`, `autoConnectIde`, `autoScroll`, `checkpoints`, `chrome`, …) — that listing is a usable substitute for the lost `getArgumentCompletions` on `/config`. |
| `/context` | local-jsx + local | runs-as-text (local twin) Y | `get_context_usage` control request | The coloured grid: one cell per token bucket, per-category breakdown, percentage-full ring | P for the data, R for the visualisation | The numbers are on the wire (verified in the live dump); the grid rendering is entirely client-side. A GUI can exceed the TUI here easily. **Live 2.1.259:** RAN. Printed a markdown "## Context Usage" report (model, 21.9k/200k = 11%, per-category table) **and** the assistant frame carried a structured `context_usage` object `{model,total_tokens,raw_max_tokens,percentage,categories,mcp_tools,memory_files,agents,skills}` — so the data is on the wire in machine-readable form, not just prose. |
| `/copy` | local-jsx | refused (local-jsx) · | none | Copies the Nth-latest assistant response to the clipboard, with a confirmation | R | The GUI already holds every assistant message from the wire and owns the system clipboard; reimplement natively. Note `/terminal-setup`'s iTerm2 branch exists solely to make `/copy` work — irrelevant to a GUI. **Live 2.1.259:** REFUSED with `/copy isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/design` | local | runs-as-text Y · `policyGate` (`allow_design_sync`) | none needed | `consent \| revoke` text result | P | `subcommands` map `{sync, login, consent, revoke}` lives on the bundled `design` skill, not here (§12) — subcommand routing is server-side, so it works headless. |
| `/design-consent` | local | runs-as-text Y (hidden) | none needed | — | P | Hidden but advertised (see §0.2 caveat). |
| `/design-login` | local-jsx | refused (local-jsx) · | none | claude.ai OAuth authorisation flow for design-system access | X | Browser-based auth with no control request. |
| `/design-revoke` | local | runs-as-text Y (hidden) | none needed | — | P | |
| `/desktop` (`app`) | local-jsx | refused (local-jsx) · gated (not remote, `allow_desktop_handoff`, availability `claude-ai`) | none | Hand-off to Claude Desktop | X/T | A macOS GUI hosting the binary *is* the desktop app case; superseded. |
| `/diff` | local-jsx | refused (local-jsx) · | `get_workspace_diff` control request | Under `tengu_willow_crate` it is a toggleable diff *panel*; otherwise a one-shot uncommitted-changes view plus per-turn diffs | P for data, R for the panel | `vcs_state_changed` and `code_change_published` frames exist on the wire. Per-turn diff attribution (which turn produced which hunk) is the part the GUI must track itself. **Live 2.1.259:** REFUSED with `/diff isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/effort` | local-jsx + local | runs-as-text (local twin) Y | `apply_flag_settings` control request | Level picker with the current level highlighted and the computed `[<levels>\|ultracode\|auto]` hint | P | `initialize` carries `effort`; the live argumentHint was `<low\|medium\|high\|xhigh\|max\|ultracode\|auto>`, i.e. the getter is evaluated before the wire. Also settable at launch with `--effort`. **Live 2.1.259:** RAN: `/effort low` → `Set effort level to low (this session only): Quick, straightforward implementation with minimal overhead`. |
| `/exit` (`quit`) | local-jsx | refused (local-jsx) · `terminalOriented`, `fleetHostCall` | `end_session` control request | Description flips to "Detach from this background session (it keeps running)" when backgrounded | T | An unregistered `local` twin exists solely as the bridge fallback (§5.1). GUI owns window close. |
| `/export` | local-jsx | refused (local-jsx) · | none | File-vs-clipboard chooser, filename entry, written-to confirmation | R (disk) | No control request. The GUI has the full transcript from the wire and the JSONL on disk; export is trivially reimplemented and can be better (PDF, HTML, share links). **Live 2.1.259:** REFUSED with `/export isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/extra-usage` | local-jsx + local | runs-as-text (local twin) Y · gated (credits available) | — | Nothing: both variants print `Renamed to /usage-credits` | P | Both variants are `isHidden: ✓` yet the name is advertised live — a clean demonstration of the §0.2 hidden-leak. A GUI must not surface it. |
| `/fast` | local-jsx + local | runs-as-text (local twin) Y | `apply_flag_settings` control request | Toggle whose label is a getter: `Toggle fast mode (<state>)` | P | `initialize` carries `fast_mode_state` and `fast_mode_disabled_reason` (both in the live dump); the live description read `Toggle fast mode (Opus 5)`, so the getter is resolved wire-side. **Live 2.1.259:** RAN but reported unavailable: `Fast mode unavailable: Fast mode is not available in the Agent SDK`, matching `initialize.fast_mode_disabled_reason = sdk_opt_in_required`. **Fast mode is off by construction on this transport** — `apply_flag_settings` will not turn it on, so a GUI should hide the control rather than offer a dead toggle. |
| `/feedback` | local-jsx | refused (local-jsx) · | `submit_feedback` control request | Feedback composer with category selection | R | In headless a plugin may legally claim the `feedback` alias — it is one of the two `HEADLESS_YIELDABLE_NAMES` (with `help`), §4.1/§6.3. A GUI that hard-codes `/feedback` can be shadowed. |
| `/focus` | local-jsx | refused (local-jsx) · | none | Focus view: prompt, summary and response only | T | Render mode; GUI implements its own. **Live 2.1.259:** REFUSED with `/focus isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/fork` | local-jsx | refused (local-jsx) · gated (`!coordinatorMode()`) | none | Two different commands under one name: FleetView on → "copy this conversation into a new background session"; off → "spawn a background agent that inherits the full conversation" | X/R | Nothing on the wire distinguishes the two variants. The copy variant is rebuildable from session files (as `/branch`); the spawn variant needs the FleetView host. **Live 2.1.259:** REFUSED with `/fork isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/goal` | local-jsx + local | runs-as-text (local twin) Y | send as text (`post-text`) | Condition entry + the persistent "goal active" indicator | P | `active_goal` is a stdout frame — the GUI gets the live goal state for free and can render a much better persistent affordance than the TUI footer. **Live 2.1.259:** RAN: bare `/goal` → `No goal set. Usage: \`/goal <condition>\``. |
| `/heapdump` | local | runs-as-text Y (hidden) · `policyGate` (`allow_heap_dump`) | none needed | Path of the written heap snapshot | P | Advertised live, so the policy is on for this account. Diagnostic only. |
| `/help` | local-jsx | refused (local-jsx) · | none | The whole help panel: grouped command list, key bindings, docs links, version line | R | The GUI must build its own palette from `initialize.commands` — which lacks grouping, `type`, `source` and `isHidden`, so the TUI's grouping cannot be reproduced faithfully. `help` is a `HEADLESS_YIELDABLE_NAMES` alias a plugin may claim. **Live 2.1.259:** REFUSED with `/help isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/hooks` | local-jsx | refused (local-jsx) · `requires: { workspace: false, ink: true }` | `get_settings` for the config; `hook_started` / `hook_progress` / `hook_response` frames for runtime | Per-event hook configuration browser and editor | R/D | Reading is possible via `get_settings`; writing is limited to localSettings by `update_settings`, so the TUI's ability to edit user/project hook config is not reachable over the wire. **Live 2.1.259:** REFUSED with `/hooks isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/ide` | local-jsx | refused (local-jsx) · | none | IDE integration status and connect/disconnect actions | X/T | Ch. 33; terminal-adjacent. **Live 2.1.259:** REFUSED with `/ide isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/import` | local-jsx + local | runs-as-text (local twin) Y · gated (`tengu_import`) | none needed | Interactive source selection (`[codex\|gemini] [--dry-run]`) and a per-item diff of what will be imported | R | The local twin takes no argument hint in the catalogue but is advertised with an empty hint live; the dry-run preview the dialog shows is not reproduced by the text variant. |
| `/init` | **prompt** | runs-as-text Y | none needed | Nothing — it is a model turn | P | Two bodies exist (§25.1): legacy, and a new 8-phase interactive version under `CLAUDE_CODE_NEW_INIT` / `tengu_slate_harbor_experiment`. The live description was the legacy one, so this account is on the legacy path. `progressMessage: "analyzing your codebase"` is client-side spinner text the GUI must supply itself. |
| `/insights` | **prompt** | runs-as-text Y | none needed | — | P | `disableModelInvocation`, `requires: { workspace: true }`. Produces an on-disk HTML report (chapter's own open question). |
| `/install-github-app` | local-jsx | refused (local-jsx) · gated (`!DISABLE_INSTALL_GITHUB_APP_COMMAND`, availability claude-ai/console) | none | GitHub App installation flow: repo picker, browser handoff, secret setup | X | Ch. 47. |
| `/install-slack-app` | local | refused (local, N-I false) · gated (availability `claude-ai`) | none | Slack app install flow | X | Explicitly `supportsNonInteractive: false` — a `local` command that opted out. |
| `/keybindings` | local | refused (local, N-I false) · gated (`tengu_keybinding_customization_release`) | none | Opens `~/.claude/keybindings.json` in an editor | T | Terminal keybindings are meaningless to a GUI, which owns its own. **Live 2.1.259:** REFUSED with `/keybindings isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/limit-reset` | local | refused (local, N-I false) · gated (claude.ai + campaign) (hidden) | none | Rate-limit reset offer with the weekly-limit warning | X | `rate_limit_event` frames tell a GUI a limit was hit, but the reset action is not exposed. |
| `/list-agents` (`peers`) | local | runs-as-text Y · gated (`tengu_harbor_kite`) | none needed | Table of subagents, teammates and messageable sessions | P | Text output only; a GUI should parse it or read the messaging socket (ch. 38). |
| `/login` | local-jsx | refused (local-jsx) · gated (`!DISABLE_LOGIN_COMMAND`), `fleetHostCall` | `claude_authenticate` + `claude_oauth_callback` + `claude_oauth_wait_for_completion` | OAuth browser handoff, account picker when already signed in (description getter flips to "Switch Anthropic accounts") | R | The control-request trio covers this; `auth_status` frames arrive with `--enable-auth-status`. The GUI must rebuild the account-picker UI. |
| `/logout` | local-jsx | refused (local-jsx) · gated (registered only when not first-party-only or a gateway token is present), `fleetHostCall` | `claude_authenticate` family | Sign-out confirmation | R | Registration is itself conditional (§4 `runtimeGatedGroups.logout`), so its absence is not an error. |
| `/loops` | local-jsx | disabled in build (`isEnabled: () => false`) | — | — | X | Never registered in 2.1.257. Ignore. **Live 2.1.259:** REFUSED with `/loops isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/low-priority` | local | refused (local, N-I false) · gated (claude.ai + rate-limit state) (hidden) | none | "Continue at lower priority" toggle after hitting a session limit | D | `rate_limit_event` announces the condition; the remedy is unreachable. |
| `/mcp` | local-jsx + local | runs-as-text (local twin) Y | `mcp_status`, `mcp_reconnect`, `mcp_toggle`, `mcp_authenticate`, `mcp_clear_auth`, `mcp_oauth_callback_url`, `mcp_set_servers`, `set_mcp_permission_mode_override` | Server list with per-server status dots, tool/prompt/resource counts, reconnect and enable/disable actions, OAuth flows | P | The richest control-request coverage in the chapter — eight requests for one command. `mcp_status` verified in the live dump. `thinClientDispatch: twin` on the dialog, `post-text` on the local variant. **Live 2.1.259:** RAN but **heavily degraded**: the headless twin printed only `3 MCP server(s): 2 connected, 1 not connected, 0 disabled. Use \`/mcp\` in the terminal for details.` A GUI must use the `mcp_*` control requests; the command text is not a substitute. |
| `/memory` | local-jsx | refused (local-jsx) · | none | CLAUDE.md file picker across scopes, inline editor, memory settings | D for the editor, R for the content | No control request. The GUI reads `CLAUDE.md` / `CLAUDE.local.md` from disk and can edit them, but nothing tells the live session to re-read memory. `memory_recall` frames show what was recalled, not what is configured. **Live 2.1.259:** REFUSED with `/memory isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/mobile` (`ios`, `android`) | local-jsx | refused (local-jsx) · | none | QR code rendered in the terminal | T | A GUI renders a real QR image; strictly better, but it needs the URL, which the wire does not carry. |
| `/model` | local-jsx + local | runs-as-text (local twin) Y | `list_models` + `set_model` control requests | Picker with per-model descriptions, current-model highlight and the getter description `Set the AI model for Claude Code (currently <model>)` | P | `initialize.models` present in the live dump; `model_*` fallback frames report involuntary switches. Fully covered. **Live 2.1.259:** RAN. `/model` printed `Current model: \`Sonnet 5\` (effort: high)` plus `Usage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID.`; `/model sonnet` printed `Set model to \`Sonnet 5\` for this session only` and the next `system/init` reported the new model. |
| `/output-style` | local-jsx | refused (local-jsx) · gated (`tengu_maple_sundial`) (hidden) | `update_settings` (localSettings) | Nothing — the body is the `"Output style moved to /config"` stub | P | `initialize` carries `output_style` and `available_output_styles` (both in the live dump). Route users to the settings surface instead. |
| `/passes` | local-jsx | refused (local-jsx) · gated (eligibility + cache) | none | Referral/free-week share flow | X | Ch. 08. |
| `/pause-memory` (`memory-pause`, `toggle-memory`) | local | disabled in build (`isEnabled: () => false`) | — | — | X | `supportsNonInteractive: ✓` and `thinClientDispatch: post-text` but never registered — this is one of the two names my mechanical prediction over-generated, confirming the gate. |
| `/permissions` (`allowed-tools`) | local-jsx | refused (local-jsx) · | **partial**: `set_permission_mode` changes the mode; `get_settings` reads `permissions.allow/deny/ask`; `update_settings` writes them **into localSettings only** | The full rule browser: merged effective rules with the source of each, add/remove/edit rules, per-tool grouping, and the session-only rules accumulated from "always allow" answers during the run | D | This is the largest single gap in the chapter. What is possible: reading persisted rules, writing localSettings rules, switching mode (also via `--permission-mode` and `system/status` mode-change frames), and observing `can_use_tool` / `permission_denied`. What is **not** possible: enumerating the *merged effective* rule set with provenance, editing user/project/policy rules, or seeing session-only grants made mid-run. A GUI must re-merge the settings files itself and will still miss session-only state. **Live 2.1.259:** REFUSED with `/permissions isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/plan` | local-jsx | refused (local-jsx) · | `get_plan` control request; `set_permission_mode: "plan"` to enter plan mode | `[open\|share\|<description>]`: opens the plan, shares it, or seeds plan mode with a description | R | Plan *approval* arrives as an `ExitPlanMode` `can_use_tool` request, so the interactive half is on the wire. Sharing (`/plan share`) has no control request. **Live 2.1.259:** REFUSED with `/plan isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/plugin` (`plugins`, `marketplace`) | local-jsx | refused (local-jsx) · | `reload_plugins` for activation; `plugin_install` frames report installs | Marketplace browser, per-plugin enable/disable, install/uninstall, error list | D | Only reload is exposed. Browsing and installing require driving the CLI or editing plugin config on disk (ch. 30). `getArgumentCompletions` is client-side and lost. |
| `/plugin-types` | local | runs-as-text · gated (`tengu_plugin_hooks_modules`, off here) · | none needed | Writes `claude-code-mcp.d.ts` typing the connected MCP tools | P | Predicted-but-absent in the live list; the flag is off on this account, not a spec error. |
| `/powerup` | local-jsx | refused (local-jsx) · | none | Interactive feature-discovery lessons | T | Pure onboarding UI; a GUI should build its own. |
| `/privacy-settings` | local-jsx | refused (local-jsx) · gated (claude.ai org with privacy settings) | none | Privacy settings viewer/editor | X | Ch. 48. |
| `/pro-trial-expired` | local-jsx | refused (local-jsx) · (hidden) | none | Post-trial options panel | X | Triggered by account state, not typed. |
| `/radio` | local | refused (local, N-I false) · | none | Plays lo-fi radio in the terminal | T | Explicit `supportsNonInteractive: false`. |
| `/rate-limit-options` | local-jsx | refused (local-jsx) · gated (claude.ai) (hidden) | none | Options panel shown when a rate limit is hit | D | `rate_limit_event` frames announce the limit; the option set behind this panel is not on the wire. A GUI must hard-code its own remediation copy. |
| `/recap` | local | runs-as-text Y | send as text (`post-text`) | One-line session recap | P | |
| `/release-notes` | local-jsx | refused (local-jsx) · | none | Scrollable changelog for the running version | R | `get_binary_version` (verified live) gives the version; the notes themselves ship in the package and can be read from disk. **Live 2.1.259:** REFUSED with `/release-notes isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/reload-plugins` | local | **refused (local, N-I false)** · `terminalOriented` | `reload_plugins` control request | "Activate pending plugin changes", `[--force]` | R | Notable inversion: the *command* is refused headless, but the *control request* exists. A GUI must call `reload_plugins` rather than send `/reload-plugins`. The only `type: "local"` command with `thinClientDispatch: control-request`, hence the only one that can resolve to `unavailable` on a thin client (SPEC 45.29). |
| `/reload-skills` | local | runs-as-text Y | `reload_skills` control request, or send as text | Confirmation of what was picked up | P | Both paths work; expect a `commands_changed` frame after. |
| `/remote-control` (`rc`) | local-jsx | refused (local-jsx) · gated (remote-control gate) | `remote_control` control request | Connect/disconnect toggle whose description flips when connected; pairing name entry | R | `initialize` carries `remote_control_available`, `remote_control_auto_enable`, `remote_control_auto_on_by_default` (all in the live dump) so the GUI can render availability accurately. |
| `/remote-env` | local-jsx | refused (local-jsx) · gated (claude.ai + `allow_remote_sessions`) | none | Default cloud-agent environment picker | X | Ch. 37. |
| `/rename` (`name`) | local-jsx + local | runs-as-text (local twin) Y | `rename_session` control request; `generate_session_title` for an auto title | Name entry prefilled with the current title | P | Fully covered, and a GUI can offer inline rename in a session list. **Live 2.1.259:** RAN: `/rename probe-title` → `Session renamed to: probe-title`. |
| `/resume` (`continue`) | local-jsx | refused (local-jsx) · | none | Session browser: titles, timestamps, message counts, preview, and `getArgumentCompletions`-driven title search offering up to 10 matches with `suggestionType: "custom-title"` (§21.5) | R (disk) | No control request at all. The GUI must enumerate `~/.claude/projects/**/*.jsonl` itself and relaunch the binary with `--resume`. The title-search completion is client-side and entirely lost. High-value rebuild. **Live 2.1.259:** REFUSED with `/resume isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/rewind` (`checkpoint`, `undo`) | local | **refused (local, N-I false)** · | `rewind_conversation` + `rewind_files` control requests | Checkpoint list with per-checkpoint file/message deltas and a code-vs-conversation-vs-both choice | R | Same inversion as `/reload-plugins`: command refused, control requests available. The GUI must build the checkpoint browser; `files_persisted` frames and `seed_read_state` help. **Live 2.1.259:** REFUSED with `/rewind isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/sandbox` | local-jsx | refused (local-jsx) · gated (hidden on unsupported platforms) | none; `get_settings`/`update_settings` for the exclusion list | Dynamic description rendering current sandbox state plus `(⏎ to configure)`; `exclude "command pattern"` (Windows adds `install`) | R/D | Sandbox state is not on the wire (ch. 17). The GUI must infer it from settings and platform. **Live 2.1.259:** REFUSED with `/sandbox isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/scroll-speed` | local-jsx | refused (local-jsx) · gated (fullscreen renderer, terminal not excluded) | none | Mouse-wheel speed slider | T | Meaningless outside a terminal. |
| `/security-review` | **prompt** | runs-as-text Y | none needed | — | P | `progressMessage: "analyzing code changes for security risks"` is client-side spinner text. |
| `/session` (`remote`) | local-jsx | refused (local-jsx) · gated (`isRemoteMode()`, `fanout` capability) | none | Cloud session URL + QR code | X | Only registered in remote mode. |
| `/setup-bedrock` | local-jsx | refused (local-jsx) · gated (hidden unless `CLAUDE_CODE_USE_BEDROCK`) | none | Bedrock auth/region/model-pin reconfiguration wizard | X | Env + settings driven; a GUI can edit the same files but gets no validation. |
| `/setup-vertex` | local-jsx | refused (local-jsx) · gated (hidden unless `CLAUDE_CODE_USE_VERTEX`) | none | Vertex auth/project/region/model-pin wizard | X | As above. |
| `/skill-doctor` | local-jsx + local | runs-as-text (local twin) Y · gated (`tengu_lantern_prism`, on here) | none needed | Report of loaded-but-unused skills and their context cost | P | `thinClientDispatch: twin` on the dialog, `post-text` on the local twin. Advertised live, so the flag is on for this account. |
| `/skills` | local-jsx | refused (local-jsx) · | `reload_skills`; `get_settings`/`update_settings` for `skillOverrides` | Skill list with source labels, per-skill on/off/user-invocable-only toggles | R/D | The list is derivable from `initialize.commands` (prompt-type entries), but the wire drops `source` and `loadedFrom`, so the TUI's provenance labels ("user", "project", "project, gitignored", "managed", "cli flag", "(plugin)", "(claude.ai sync)") cannot be reproduced from the wire — only the pre-formatted description suffix survives, and only when `formatDescriptionWithSource` added one (§21.4). **Live 2.1.259:** REFUSED with `/skills isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/status` | local-jsx | refused (local-jsx) · | assemble from `initialize` + `get_binary_version` + `mcp_status` + `get_settings` + `get_context_usage` + `get_session_cost` | One panel: version, model, account, API connectivity, tool statuses, IDE/MCP state | R | Every component is individually reachable (all six verified in the live dump); only the composition is client-side. A GUI status pane can comfortably exceed the TUI's. **Live 2.1.259:** REFUSED with `/status isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/statusline` | **prompt** | **terminal-only** (`disableNonInteractive` + `terminalOriented`) · | none | Sets up the terminal status line by editing `~/.claude/settings.json` | T | The **only** `prompt` command with `disableNonInteractive`, and correspondingly the only prompt command absent from the live 102 — a clean confirmation of the §22 rule. `allowedTools: ["Agent", "Read(~/**)", "Edit(~/.claude/settings.json)"]`. **Live 2.1.259:** REFUSED with `/statusline isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/stickers` | local | refused (local, N-I false) · | none | Sticker order form | X | |
| `/stop` | local-jsx | refused (local-jsx) · gated (background session + FleetView) | `stop_task` for background tasks | "Stop this background session; transcript and worktree are kept" | X/T | An unregistered `local` twin exists as the bridge fallback (§5.1). `stop_task` addresses background *tasks*, not this session concept. |
| `/subtask` | local-jsx | refused (local-jsx) · gated (FleetView on, `!coordinatorMode()`) | none | "Send a subagent off with your full context" launcher | X | Registered only when FleetView is on (§4); when off, `/fork` becomes the spawn variant instead. |
| `/tasks` (`bashes`) | local-jsx | refused (local-jsx) · | `background_tasks` + `stop_task` control requests | Live table of background work with per-task status, output tail and kill actions | P/R | `background_tasks` verified in the live dump; `task_started`, `task_updated`, `task_progress`, `task_notification` and `background_tasks_changed` are all stdout frames. A GUI can build a far better task panel than the TUI table. **Live 2.1.259:** REFUSED with `/tasks isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/team-onboarding` | **prompt** | runs-as-text Y · `policyGate` (`allow_team_onboarding`) | none needed | — | P | `effort: "low"`, `allowedTools: ["Edit(ONBOARDING.md)", "Bash(ls *)", "ShareOnboardingGuide"]`. Advertised live, so the policy is on. |
| `/teleport` (`tp`) | local-jsx | refused (local-jsx) · gated (claude.ai + `allow_remote_sessions`) | none | Send-to-cloud / resume-from-cloud picker | X | Also one of the three names with a bespoke cloud-session refusal message (§8, quoted below). |
| `/terminal-setup` | local-jsx | refused (local-jsx) · | none | A four-way description getter keyed on `$TERM_PROGRAM`, then writes terminal keybindings | T | Explicitly terminal-specific; the getter's iTerm2 branch exists to enable `/copy`. Superseded by the GUI. **Live 2.1.259:** REFUSED with `/terminal-setup isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/theme` | local-jsx | refused (local-jsx) · | `update_settings` (localSettings) for the persisted theme; `set_color` for the prompt bar only | Theme picker with live preview | T/R | A GUI owns its own theming; only sync the setting if it wants the two to agree. **Live 2.1.259:** REFUSED with `/theme isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/tui` | local-jsx | refused (local-jsx) · | none | `[default\|fullscreen]` renderer switch | T | Meaningless in a GUI. **Live 2.1.259:** REFUSED with `/tui isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/ultraplan` | local-jsx | refused (local-jsx) · gated (`tengu_ultraplan_config.enabled` + entitlement + `!isRemoteMode()`) | none | Description getter shows a cost/time estimate and docs URL before launching | X | No control request; contrast `/ultrareview`, which has one. |
| `/ultrareview` | local-jsx + local | runs-as-text (local twin) Y · gated (ultra entitlement) | `ultrareview_launch` control request | Description getter with `<time>`, `<cost> USD` and a docs URL, then a confirm step | R | Advertised live, so the entitlement is present. The GUI must render its own cost-confirmation, since the estimate only reaches the wire embedded in the description string. |
| `/update` (`restart`) | local | disabled in build (`isEnabled: () => false`) · `fleetHostCall` | none | "Switch to the latest version (conversation continues)" | X | Never registered in 2.1.257 despite being in `BRIDGE_SAFE_COMMANDS`. |
| `/upgrade` | local-jsx | refused (local-jsx) · gated (not enterprise, `!DISABLE_UPGRADE_COMMAND`, not already Max, availability claude-ai) | none | Plan-upgrade offer | X | Ch. 08. |
| `/usage` (`cost`, `stats`) | local-jsx + local | runs-as-text (local twin) Y | `get_session_cost` + `get_usage` control requests | Cost breakdown, plan-usage bars, activity stats over time | P for data, R for charts | Both requests verified in the live dump. Note the twins carry *different* descriptions and the local twin has a `menuDescription` (`Show session cost and plan usage`) that only the bridge advertisement uses — the SDK wire got the long form, as the live capture shows. **Live 2.1.259:** RAN under all three names (`/usage`, `/cost`, `/stats`). Output: `You are currently using your subscription to power your Claude Code usage` then `Current session: 55% used · resets Sep 3 at 10:40pm (Asia/Seoul)` and a weekly line. Prose only — the percentages are not structured on this path, so prefer `get_session_cost` + `get_usage`. |
| `/usage-credits` | local-jsx + local | runs-as-text (local twin) Y · gated (credits available) | none named | Credit configuration / request-from-admin flow | R | Advertised live. |
| `/vim` | local-jsx | refused (local-jsx) · gated (`tengu_maple_sundial`) (hidden) | `update_settings` | Nothing — `"Editor mode moved to /config"` stub, sharing a dialog module with `/output-style` | T | Editor mode is an input-editor concern (ch. 42); a GUI owns its own editor. **Live 2.1.259:** REFUSED with `/vim isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/voice` | local | refused (local, N-I false) · gated (availability claude-ai, hidden unless voice available) | none | `[hold\|tap\|off]` voice-mode toggle | X/T | Ch. 43; requires local audio capture the GUI would have to own natively. |
| `/web-setup` | local-jsx | refused (local-jsx) · gated (`allow_remote_sessions` + `allow_quick_web_setup`) | none | GitHub-account web setup flow | X | Ch. 37. |
| `/wellbeing` (`breaks`, `break-reminder`, `downtime`) | local-jsx | disabled in build (`isEnabled: () => false`) | — | — | X | Never registered. |
| `/workflow-launch-exec` | local | runs-as-text Y (hidden) · `disableModelInvocation` | none needed | Nothing user-facing — executes a server-launched workflow handoff | P | Advertised live despite `isHidden` — suppress in a GUI palette (§0.2). |
| `/workflows` | local-jsx | refused (local-jsx) · gated (workflows enabled) | none | Browser over running and completed workflows | X | Ch. 40. Dynamic *workflow commands* are a separate class row below. |
| `/__remote-workflow` | local | runs-as-text Y (hidden) · `disableModelInvocation` | none needed | Nothing user-facing | P | Same hidden-leak as above; the leading underscore also means it escapes the naive `[a-z0-9-]+` enumeration (§5). |

### 1.1 Dynamic command sources, as classes

| Source class | Type(s) | Headless status | Route for a GUI | What the TUI version shows that the GUI must rebuild | Class | Notes |
|---|---|---|---|---|---|---|
| **Custom commands on disk** — `<managedSettingsDir>/.claude/commands`, `~/.claude/commands`, every project root's `.claude/commands` (§13.1), plus `.claude/skills` trees | prompt (`loadedFrom: "commands_DEPRECATED"` or `"skills"`; `source` `policySettings` / `userSettings` / `projectSettings`) | runs-as-text unless the file sets `disable-non-interactive` | none needed; they arrive in `initialize.commands` | Provenance label appended to the description (`(user)`, `(project)`, `(project, gitignored)`, `(managed)`, `(cli flag)`), the `(arguments: a, b)` suffix built from `argNames`, and the `argument-hint` frontmatter as inline ghost text | R | 12 of these were visible in the live capture (`worktree`, `grilling`, `teach`, `deep-research`, `impeccable`, …). The description suffix *is* on the wire (it is baked in by `formatDescriptionWithSource` before `toWire`), so a GUI gets provenance for free here — but `source` itself is not, so it cannot group or filter by scope. Name derivation is directory-namespaced with `:` (§13.4): `.claude/commands/git/sync.md` → `/git:sync`. File cap 1 048 576 bytes; frontmatter cap 30 lines / 65 536 bytes. |
| **Plugin commands and plugin skills** (§18, §3.1 #3–#4) | prompt, `source: "plugin"` | runs-as-text | `reload_plugins` to pick up changes; `plugin_install` frames | Description prefixed `(<plugin display name>) `, and the plugin's own aliases after `stripShadowedPluginAliases` removed colliding ones | R | 33 of these in the live capture (`doperpowers:*`, `plugin-dev:*`, `supabase:*`, …). Names are always `<plugin>:<path>`; a bare declared `name` also registers as an alias, which the live data confirms (`doperpowers:agora` carries alias `agora`). In a **headless** session, names that cannot run headlessly are excluded from the reserved set, so a plugin may legally claim the `help` and `feedback` aliases (§6.3, `HEADLESS_YIELDABLE_NAMES`) — a GUI must not assume those two names mean the built-ins. |
| **MCP prompts** (§19) | prompt, `source: "mcp"`, `isMcp: true` | runs-as-text | `mcp_status` to know which servers are up; `mcp_call` / `mcp_message` for the underlying protocol | Display name `<server>:<prompt> (MCP)` (or the bare prompt name when claude.ai-hosted), the ` (MCP)` re-assembly in the parser, positional argument mapping onto declared MCP arguments, and RFC 6570 `urlTemplate` URI completion in the menu | R/D | None were connected in the live capture. Three GUI hazards: (a) the parser special-cases a literal ` (MCP)` suffix (§7) so a GUI sending `/server:prompt (MCP) args` must preserve it exactly; (b) an MCP entry whose *display* name collides is kept but forced `isHidden: true` (§3.1) — and `isHidden` is not on the wire, so the GUI will show a duplicate the TUI hides; (c) URI-template completion (`getArgumentCompletions` territory) is entirely client-side. Missing-argument errors come back as `Missing required argument(s): <names>. Usage: /mcp__<server>__<prompt> <arg1> <arg2> …`. |
| **Bundled skills** (§20) | prompt, `source: "bundled"`, `loadedFrom: "bundled"` | runs-as-text | none needed | Nothing beyond the menu row | P | 41 names ship in 2.1.257; 16 appeared live (`batch`, `claude-api`, `code-review`, `dataviz`, `debug`, `design-sync`, `doctor`, `fewer-permission-prompts`, `loop`, `run`, `run-skill-generator`, `schedule`, `simplify`, `update-config`, `verify`, `workflow-authoring`). Two carry behaviour a GUI must respect: `code-review` has `subcommands: { ultra: "ultrareview" }`, and `loop` sets `argsMayContainSlashCommands` so `/loop 5m /foo` is *not* stack-peeled (§11). **`doctor` (alias `checkup`) carries `terminalOriented: true`** (`cli.pretty.js:386964`) — it is the second entry in 2.1.259's `terminal_slash_commands` alongside `color`, which is why that array is `["doctor","color"]` even though neither is a built-in `local-jsx` command. `CLAUDE_CODE_DISABLE_BUNDLED_SKILLS` drops all but `survivesBundledKillSwitch` skills and demotes the five built-in `prompt` commands to user-invocable-only. **Live 2.1.259:** `/doctor` was **not** refused despite being in `terminal_slash_commands` — it was echoed as a `prompt` command and the model answered it with streamed text. `terminalOriented` therefore affects only the `terminal_slash_commands` advertisement and the `/` menu, never headless runnability (`/color` likewise ran). |
| **Dynamic workflow commands** (§3.1 #2, ch. 40) | prompt, `kind: "workflow"` | runs-as-text | none named | Menu row tagged `dynamic workflow` and description suffixed ` (dynamic workflow)` (§21.4) | D | None appeared live. The `tag` field is a menu-render concept that `toWire` drops entirely — a GUI cannot tell a workflow command from any other prompt command over the wire, because the ` (dynamic workflow)` suffix is inside the description string and is the only signal. |

---

## 2. Live 2.1.259 cross-check

### 2.1 Advertised on 2.1.259 but not in the 2.1.257 §5 catalogue — 69 names, all dynamic-source

Every one is a `prompt` command from a dynamic source, i.e. §5 is not missing any built-in:

* **12 user skills / custom commands** (`~/.claude/skills`, `~/.claude/commands`): `claude-md-setup`,
  `deep-research`, `grill-me`, `grill-with-docs`, `grilling`, `impeccable`,
  `improve-codebase-architecture`, `playwright-cli`, `teach`, `worktree`, `writing-great-skills`,
  `youtube-library-organize`.
* **33 plugin skills**: `chatgpt-advisor:*` (2), `claude-md-management:*` (2), `code-review:code-review`,
  `designer:designer`, `doperpowers:*` (22), `eli5:eli5`, `plugin-dev:*` (8 incl. `create-plugin`),
  `skill-creator:skill-creator`, `supabase:*` (2).
* **16 bundled skills**: `batch`, `claude-api`, `code-review` (alias `review`), `dataviz`, `debug`,
  `design-sync`, `doctor` (alias `checkup`), `fewer-permission-prompts`, `loop` (alias `proactive`),
  `run`, `run-skill-generator`, `schedule` (alias `routines`), `simplify`, `update-config`, `verify`,
  `workflow-authoring`.

Two of those names also exist in 2.1.257 as *other things* and a GUI must not conflate them:
`schedule` and `ultraplan`/`ultrareview`/`teleport`/`remote-control`/`autofix-pr` are the six **C4E
upsell stubs** (§4.2) when the session is API-key-based and `tengu_c4e_slash_upsell` is on; here
`schedule` resolved to the bundled skill instead, which is the expected precedence (§6.1: built-ins
are appended last, so anything else wins a name tie).

### 2.2 Catalogue commands not advertised on 2.1.259 — 76 names, every one explained

| Reason | Count | Names |
|---|---|---|
| `local-jsx` (never runs headless, §22) | 60 | `add-dir`, `advisor`, `artifacts`, `autofix-pr`, `background`, `branch`, `brief`, `btw`, `bug`, `cd`, `chrome`, `cloud-plugins`, `copy`, `design-login`, `desktop`, `diff`, `exit`, `export`, `feedback`, `focus`, `fork`, `help`, `hooks`, `ide`, `install-github-app`, `login`, `logout`, `loops`, `memory`, `mobile`, `output-style`, `passes`, `permissions`, `plan`, `plugin`, `powerup`, `privacy-settings`, `pro-trial-expired`, `rate-limit-options`, `release-notes`, `remote-control`, `remote-env`, `resume`, `sandbox`, `scroll-speed`, `session`, `setup-bedrock`, `setup-vertex`, `skills`, `status`, `stop`, `subtask`, `tasks`, `teleport`, `terminal-setup`, `theme`, `tui`, `ultraplan`, `upgrade`, `vim`, `web-setup`, `wellbeing`, `workflows` |
| `local` with `supportsNonInteractive: false` | 10 | `install-slack-app`, `keybindings`, `limit-reset`, `low-priority`, `radio`, `reload-plugins`, `rewind`, `stickers`, `update`, `voice` |
| `prompt` with `disableNonInteractive` | 1 | `statusline` |
| `isEnabled: () => false` (disabled in build) | 4 | `loops`, `pause-memory`, `update`, `wellbeing` (the last three also covered above) |
| Flag/entitlement gate off on this account | 1 | `plugin-types` (`tengu_plugin_hooks_modules`) |

The interactive twin of each of the 17 twin names is likewise absent; the `local` twin carries the
name in the advertisement. No catalogue command was advertised that the §22 rule predicts should be
refused, and none that it predicts should run was missing except the two gated ones — the rule
reproduces the live list exactly.

Corollary for a GUI: **do not derive command availability from the 2.1.257 catalogue.** Derive it
from `initialize.commands` on the live binary, and re-derive on every `commands_changed` frame,
because gates (`tengu_lantern_prism` for `/skill-doctor`, `tengu_import` for `/import`,
`allow_heap_dump` for `/heapdump`, entitlement for `/ultrareview`) vary per account and per build.

---

## 3. Pre-execution gates (§8.1) and error texts (§8.2) the GUI will see echoed

### 3.1 The refusal a GUI actually gets is NOT the §8.1 panel message

This is the single most important correction in this area, and the live probe settles it.

SPEC 28 §8.1 row 4 says a `local-jsx` command in a non-interactive session is refused with:

```text
/<name> opens an interactive panel and isn't available in this environment. Run it from the Claude Code terminal instead.
```

**That message is unreachable for built-ins on this transport.** `filterCommandsForHeadless`
removes every `local-jsx` command from the list *before* dispatch (§22), so `findCommand` never
finds one and the §8.1 gate never runs. Execution instead falls into §8 step 8b — "in a
non-interactive session where `builtInCommandNames` contains the name" — which returns:

```text
/<name> isn't available in this environment.
```

Thirty-two commands were probed live on 2.1.259 and every refusal used exactly that text, with the
name substituted: `/help`, `/status`, `/tasks`, `/permissions`, `/vim`, `/rewind`, `/resume`,
`/memory`, `/hooks`, `/skills`, `/plan`, `/diff`, `/btw`, `/export`, `/theme`, `/terminal-setup`,
`/keybindings`, `/release-notes`, `/copy`, `/bug`, `/add-dir`, `/cd`, `/branch`, `/fork`,
`/background`, `/loops`, `/tui`, `/focus`, `/brief`, `/sandbox`, `/ide`, `/statusline`.

Note that this one string covers **three** different underlying causes, which the GUI cannot tell
apart from the text alone:

* `local-jsx` (most of the list);
* `local` with `supportsNonInteractive: false` (`/rewind`, `/keybindings`);
* `prompt` with `disableNonInteractive` (`/statusline`).

**Delivery shape is also not what §22 describes.** §22 says every headless refusal emits two *user*
messages — the echoed invocation plus `<local-command-stdout>…</local-command-stdout>`. Live, a
refusal produced **only an `assistant` frame** carrying the bare sentence, followed by `result`,
with **no user echo at all**. A command that actually ran did produce the user echo (`<command-name>`
/ `<command-message>` / `<command-args>`) followed by its output. So the presence or absence of the
user echo is a reliable runtime signal a GUI can use: *echo present ⇒ the command ran; assistant
frame only ⇒ it was refused.*

Every step also emitted `system/init` and three `command_lifecycle` frames
(`queued` → `started` → `completed`), so a GUI has a lifecycle signal independent of the text.

Practical consequence: a GUI should never send a command absent from `initialize.commands`. If it
does, it must intercept `/<name> isn't available in this environment.` and substitute its own native
affordance — rendering the sentence verbatim tells the user nothing actionable, and the §8.1 variant
("Run it from the Claude Code terminal instead") would be actively wrong advice in a GUI anyway.

### 3.2 The four §8.1 gates, for completeness

Four gates run before any dispatch, in this order (`chunk-95p3p7y1.js:338526-338546`). They apply to
commands that *are* in the list — so for a headless host, rows 1–3 are reachable (an enabled-then-
disabled command, a `skillOverrides`-off skill, a `userInvocable: false` skill) and row 4 is not.
In non-interactive mode each is emitted as the echoed invocation `/<name> <redacted args>` followed
by `<local-command-stdout><text></local-command-stdout>`.

| # | Condition | Non-interactive text (verbatim) |
|---|---|---|
| 1 | `!isCommandEnabled(cmd)` | `/<name> isn't available in this session.` |
| 2 | `isSkillOff(cmd)` | `Skill "<name>" is disabled via skillOverrides. Remove the override from your settings to run it.` |
| 3 | `cmd.userInvocable === false` | `This skill can only be invoked by Claude, not directly by users. Ask Claude to use the "<name>" skill for you.` |
| 4 | `cmd.type === "local-jsx" && isNonInteractive()` | `/<name> opens an interactive panel and isn't available in this environment. Run it from the Claude Code terminal instead.` — **not observed live; see §3.1** |

Note how easily rows 1 and the step-8b message are confused: `isn't available in this **session**`
(row 1, command present but disabled) versus `isn't available in this **environment**` (step 8b,
command absent from the list). A GUI matching on these strings must match the whole sentence.

The interactive variants differ for rows 1–2 (row 1 is a warning banner; row 2 adds a second
`Args from disabled skill: <args>` line), and row 3 is identical in both modes.

### 3.3 Other refusals a GUI can receive

* Unknown command, with an edit-distance ≤ 2 suggestion over visible enabled commands:
  `Unknown command: /<name>. Did you mean /<suggestion>?` or `Unknown command: /<name>` (name
  truncated to 512 chars, suggestion to 200). In interactive mode a second warning
  `Args from unknown skill: <redacted args>` follows; in non-interactive it does not.
* Malformed input: ``Commands are in the form `/command [args]` `` — but in a non-interactive
  session a line that fails to parse as a command **falls through to being treated as an ordinary
  prompt** instead (§8 step 1). A GUI that lets a user type a bare `/` gets a model turn, not an
  error.
* Conversation ended by the model: `Claude ended this conversation. Start a new session (or /clear)
  to continue.` Only `clear`, `resume`, `help`, `exit`, `feedback` (non-`prompt` types) are allowed
  after that point.
* The three cloud-session refusals for `/teleport`, `/session` and `/remote-control`, emitted only
  when `CLAUDE_CODE_REMOTE_SESSION_ID` is set (§8) — e.g. `/teleport pulls a cloud session into a
  terminal on your own machine, so it can't run from inside this session. …`

### 3.4 §8.2 — thrown errors

Every throw is funnelled through `commandThrowTextForTranscript` and lands as
`<local-command-stderr>…</local-command-stderr>`:

* abort → `Interrupted` (or the error's own message);
* a `CommandError` → its message, tag-escaped;
* anything else → `String(error)`, tag-escaped;
* on a redacted connection → `<name truncated to 200 chars> failed (detail withheld on this
  connection)`.

`escapeTags` rewrites `<tag` openers and `Bt` HTML-escapes `&`, `<`, `>` for stderr payloads, so a
GUI rendering these as HTML must un-escape rather than double-escape.

---

## 4. `local-jsx` `onDone` semantics a GUI must reproduce (§9.2)

Any `local-jsx` command a GUI reimplements natively must end by producing the same transcript
effect the TUI's `onDone(message, opts)` produces, or the model's view of the conversation diverges
from what the user saw.

| `opts` | Transcript effect the GUI must reproduce |
|---|---|
| `display: "skip"` | No messages at all. `nextInput` / `submitNextInput` are still honoured. |
| `display: "system"` | The `<command-name>/…` echo plus `<local-command-stdout>message</local-command-stdout>` plus any `metaMessages`. Suppressed entirely when the renderer is fullscreen and the message ends with the literal `" dismissed"`. |
| (neither) | A user message `NV(displayName, args)` (§10.2 shape) plus `<local-command-stdout>message</local-command-stdout>`, or `(no content)` when the message is empty. |
| `shouldQuery: true` | A model turn runs after the messages are appended. Without it, nothing is sent to the model. |
| `nextInput: string` | The input box is **prefilled** with that text, cursor at the end. Purely client-side. |
| `submitNextInput: true` | That prefilled text is **submitted immediately** as the next user turn. |

The `nextInput` / `submitNextInput` pair is the subtle one: several dialogs finish by handing the
user a pre-composed follow-up prompt. A GUI reimplementation that skips it silently drops a step the
user expects. `metaMessages` are transcript-visible but `isMeta`, so they must not be shown as
ordinary assistant/user content.

Two failure paths also matter: if neither `cmd.load` nor the static `DIALOG_MAP` entry resolves, the
result is the §8.1 row-4 refusal; if the panel is dismissed without `onDone` ever being called, the
result is **no messages at all** — the invocation leaves no trace. A GUI should match that (a
cancelled dialog writes nothing).

`DIALOG_MAP` has 74 entries; six `local-jsx` commands carry their own `load` instead (`branch`,
`brief`, `color`, `focus`, `subtask`, `ultraplan`), and `/vim` and `/output-style` share one module.

---

## 5. Transcript wrapper text (§10) — render local command echoes the way the TUI does

A GUI must recognise six tag names in message text or it will show users raw XML:

| Tag | Produced by |
|---|---|
| `<command-name>` | every local / local-jsx / prompt echo |
| `<command-message>` | same |
| `<command-args>` | same (omitted by the `prompt` form when there are no args) |
| `<local-command-stdout>` | `local` text results, `local-jsx` `onDone` messages, and every headless gate/refusal |
| `<local-command-stderr>` | `local` results with `level: "error"`, and every throw |
| `<local-command-caveat>` | prepended to any command that did not request a model turn |

The three echo shapes differ and the differences are load-bearing for a parser:

`local` / `local-jsx` (`NV`) — **note the literal 12-space indentation on lines 2 and 3, which is
part of the emitted string**:

```text
<command-name>/NAME</command-name>
            <command-message>NAME</command-message>
            <command-args>ARGS</command-args>
```

`prompt` (`Fe`) — different field order, no indentation, `<command-args>` omitted when empty:

```text
<command-message>NAME</command-message>
<command-name>/NAME</command-name>
<command-args>ARGS</command-args>
```

Skill-loading metadata (`formatSkillLoadingMetadata`), used when the command is *not* user-invocable
and came from `skills` / `syncedSkills` / `plugin` / `mcp` / `memoryStore` — **no leading `/`**:

```text
<command-message>NAME</command-message>
<command-name>NAME</command-name>
<skill-format>true</skill-format>
```

The caveat, verbatim, on a message with `isMeta: true`:

```text
<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>
```

An empty `local-jsx` result renders `<local-command-stdout>(no content)</local-command-stdout>`.
Arguments are replaced with `***` when `isSensitive` is set (no 2.1.257 command sets it) and passed
through `redactSecrets` in the headless echo specifically.

A GUI has a real opportunity here: the TUI shows these as dimmed pseudo-XML in the scrollback. A GUI
should parse them into a proper "command run" chip with collapsible output, which is strictly better
— but it must not *hide* the caveat's effect, since the model genuinely is told to ignore that
content.

---

## 6. Stacked commands (§11)

A `prompt` command may be followed immediately by up to **five** further slash commands, each peeled
off and expanded in turn. A GUI's input box must not "helpfully" reject `/a /b /c` as malformed.

| Behaviour | Detail |
|---|---|
| Cap | `MAX_STACKED = 5`; exceeding it emits `Stacked command limit (5) reached — remaining input passed as arguments` |
| Eligibility | only `prompt` commands with no `context: "fork"`, no `getContext`, no `argsMayContainSlashCommands`, `userInvocable !== false`, enabled, and not skill-off |
| Opt-out | the head command having `argsMayContainSlashCommands` skips peeling entirely — the bundled `loop` skill uses this so `/loop 5m /foo` keeps `/foo` as an argument |
| Merging | allowed/disallowed tool lists concatenate; each stacked command's `model` and `effort` override the head's |
| Tagging | the head's first message is `stackedOriginalInput`; each stacked expansion's first message is `stackedExpansion: true` — neither tag survives to the wire |
| Failures | `Stacked skill /<name> blocked by UserPromptExpansion hook` (skipped) or `Stacked skill /<name> failed to load: <error>` |

Class: **P** — stacking happens server-side, so a GUI gets it for free by passing the raw text
through. The only GUI obligation is not to over-validate input.

## 7. Subcommands (§12)

`routeSubcommand` matches the first argument token case-insensitively against the command's
`subcommands` map and re-dispatches to the named target, which must itself resolve and be enabled.
`subcommandsBareOnly` restricts routing to the case where the token is the entire argument string.

Only three maps ship in 2.1.257, all on bundled skills: `code-review` (alias `review`) →
`{ ultra: "ultrareview" }`; the `design` canvas skill and the `design` hub skill both →
`{ sync: "design-sync", login: "design-login", consent: "design-consent", revoke: "design-revoke" }`,
bare-only on the canvas variant.

Class: **P/D** — routing is server-side and works headless, but the `subcommands` map is **not** on
the wire. A GUI cannot offer `/code-review ultra` as a completion or know that `/design login` will
land on a `local-jsx` command and be refused. It can only discover this by trying.

---

## 8. Autocomplete (§21) — the largest concentration of client-side behaviour

Everything in this section is implemented in the TUI process. None of it is on the wire; a GUI
building a command palette must reimplement all of it from `initialize.commands`, and will do so
with strictly less information (§0.3).

| Feature | TUI behaviour | What a GUI can reproduce | Class |
|---|---|---|---|
| Trigger | `/` at position 0, or mid-line after whitespace or CJK punctuation `[\s。、？！]`, unless the line already starts with `add-dir`, `cd`, `resume`, `plugin`, `plugins` or `marketplace` | Fully — it is pure input logic | R |
| Empty-query ranking | Top **5** `prompt` commands by usage score first, then five alphabetical buckets: `local`/`local-jsx`; `prompt` from user/local settings; from project settings; from policy settings; everything else | **Partly.** The GUI cannot bucket, because `type` and `source` are not on the wire. Recency it can track itself. | D |
| Usage score | `usageCount * max(0.5^(daysSince/7), 0.1)`, written at most once per 60 s per command, persisted in `localConfig().skillUsage` | Fully, and better — the GUI can read the same `skillUsage` map from disk to stay consistent with the TUI, or keep its own | R (disk) |
| Query ranking | Fuse.js v7 `threshold: 0.3, distance: 100` over six weighted keys: `commandName` ×3, `displayName` ×2, `partKey` ×2 (name split on `[:_-]`), `aliasKey` ×2, `displayPartKey` ×1, `descriptionKey` ×0.5; then a six-level comparator (exact name → exact alias → name prefix shortest-first → alias prefix → Fuse score quantised to `floor(score*10)` → usage boost) | Fully — every input (name, aliases, description) is on the wire. Matching the coarse quantisation matters: it is what lets recency break ties. | R |
| Hidden commands | Excluded from the index, but reachable by typing an exact name, in which case the hidden match is prepended | **Not reproducible.** `isHidden` is not on the wire, so a GUI either shows hidden commands always (leaking `__remote-workflow`, `extra-usage`, `design-consent`, `workflow-launch-exec`, …) or maintains a hard-coded suppression list | D |
| Row rendering | `displayText` = `/<display>` plus ` (<matchedAlias>)` when an alias matched; description = provenance-formatted text plus `(arguments: a, b)` from `argNames`; workflow rows carry a `dynamic workflow` tag; `identityKey` distinguishes same-named commands from different sources | **Partly.** The provenance suffix is baked into the wire description, so that survives. `argNames`, the workflow tag, and `identityKey` do not — two commands with the same display name from different sources are indistinguishable on the wire | D |
| Menu width / empty state | Column width `max(len(displayName)) + 6`; empty state `No commands match "<input>"` for a >1-char simple token | Fully (cosmetic) | R |
| **Argument hints** | Shown inline once the input has a space and the cursor sits right after it | Fully — `argumentHint` is on the wire (`""` when absent), and the live capture shows getters already resolved, e.g. `/effort` → `<low\|medium\|high\|xhigh\|max\|ultracode\|auto>`, `/impeccable` → its long bracketed grammar | P |
| Positional-name hints | For `prompt` commands with `argNames`, once the input ends with a space the hint becomes the remaining names as `[name] [name]` | **Not reproducible** — `argNames` is not on the wire. Only the `(arguments: …)` description suffix hints at it, and `toWire` does not add that suffix | D |
| **`getArgumentCompletions`** | Called `(completedArgs, partialArg, ctx)`, at most **12** results, each replacing the whole line as `<command> <completed…> <value>[ ]` (trailing space dropped when `isFinal` or the value equals the partial). Built-ins that define it: `/config`, `/plugin`, and the bundled `design` skill | **Entirely lost.** It is a function on the command object; functions do not cross the wire and no control request invokes one. A GUI gets no settings-key completion for `/config`, no plugin-name completion for `/plugin`, no project completion for `design`. Partial workaround: `get_settings` enumerates settings keys so `/config` completion can be rebuilt independently; there is no equivalent for `/plugin` | D |
| `/resume` title search | Special-cased: searches session titles, up to 10 matches, `suggestionType: "custom-title"` | Rebuildable from `~/.claude/projects/**/*.jsonl` on disk | R (disk) **Live 2.1.259:** REFUSED with `/resume isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| `/add-dir`, `/cd` completion | Switch to directory completion | Rebuildable; a native GUI picker is better | R **Live 2.1.259:** REFUSED with `/add-dir isn't available in this environment.` — delivered as an **assistant** frame with no user echo (see §3). |
| Inline ghost text | Shortest name or display name starting with the typed partial, case-insensitive, rendered as ghost text; `shouldPreselectFirst` preselects row 1 for empty queries and non-command suggestions, otherwise only when a `[:_-]`-delimited suffix of the name/display name/alias starts with the query with delimiters removed | Fully — needs only names and aliases | R |

---

## 9. Disabling mechanisms (§24)

| Mechanism | Reaches the GUI as | Class |
|---|---|---|
| `--disable-slash-commands` (help text: `Disable all skills`) | `initialize.commands` is `[]`, and every model-facing skill list is empty. A GUI must handle an empty array without treating it as a handshake failure | P |
| `skillOverrides: { "<name>": "off" \| "user-invocable-only" }` | `off` removes the name from the advertisement (`isAdvertisedSlashCommand` checks `!isSkillOff`); `user-invocable-only` keeps it advertised but hides it from the model. Readable and writable via `get_settings` / `update_settings`, the latter localSettings-only | R |
| `CLAUDE_CODE_DISABLE_BUNDLED_SKILLS` / `"disableBundledSkills": true` | Bundled skills without `survivesBundledKillSwitch` vanish from the advertisement; the five built-in `prompt` commands stay advertised but become user-invocable-only | P |
| `disableSkillShellExecution` (managed or user settings) or `CLAUDE_CODE_IS_COWORK` | Shell blocks in command bodies are replaced with the literal `[shell command execution disabled by policy]`; nothing announces this on the wire | D |
| `policyGate` + an org policy that is off | The command is absent from the advertisement, and typing it produces a policy-specific message via `findPolicyDeniedCommand` — or a `stale_list` message when the policy is on but the command is missing | R |
| `isEnabled` returning false | Filtered out of `getCommands` entirely | P |
| `availability` not met (`claude-ai` / `console`) | Filtered by `meetsAvailabilityRequirement`; account type is in `initialize.account` | P |
| Per-command env kill switches: `DISABLE_LOGIN_COMMAND`, `DISABLE_LOGOUT_COMMAND`, `DISABLE_INSTALL_GITHUB_APP_COMMAND`, `DISABLE_UPGRADE_COMMAND`, `DISABLE_EXTRA_USAGE_COMMAND`, `DISABLE_COMPACT`, `CLAUDE_CODE_DISABLE_ADVISOR_TOOL`, `CLAUDE_CODE_DISABLE_PLUGIN_FORWARDING`, `CLAUDE_CODE_DISABLE_AGENT_VIEW`, `CLAUDE_CODE_DISABLE_POLICY_SKILLS`, `CLAUDE_CODE_DISABLE_DOCTOR_COMMAND` | Absence from the advertisement. `CLAUDE_CODE_DISABLE_AGENT_VIEW` is the one that changes *semantics* rather than availability: with FleetView off, `/fork` becomes the spawn-a-background-agent variant and `/subtask` disappears (§4) | P |

The through-line: almost every disabling mechanism is observable as *absence from
`initialize.commands`*, which is exactly why a GUI should treat that array as authoritative and
never hard-code a command list.

---

## Top gaps in this area

Ranked by how much they cost a GUI aiming at TUI parity.

1. **`/permissions` has no adequate control-request replacement.** `set_permission_mode` covers the
   mode; `get_settings` / `update_settings` cover persisted rules but write only to
   `.claude/settings.local.json`. Nothing exposes the *merged effective* rule set with per-rule
   provenance, nothing lets a GUI edit user/project/policy rules, and nothing surfaces the
   session-only grants accumulated from "always allow" answers during the run. A GUI must re-merge
   the settings files itself and will still show a rule list that does not match reality mid-session.
   (Row `/permissions`; §24, §8.1.)
2. **`getArgumentCompletions` is a function on the command object and cannot cross the wire.**
   `/config`, `/plugin` and the bundled `design` skill all lose argument completion entirely. Only
   `/config` has a partial workaround (`get_settings` enumerates keys). (§21.5.)
3. **`isHidden` is not on the wire, but hidden commands *are* advertised.** The live 102 include
   `__remote-workflow`, `workflow-launch-exec`, `extra-usage`, `design-consent` and `design-revoke`,
   all `isHidden: true`. A GUI palette that renders the array verbatim shows internal plumbing the
   TUI hides, and cannot reproduce the TUI's "hidden commands are reachable by exact name only"
   behaviour. Requires a hard-coded suppression list. (§0.2, §21.3.)
4. **`/resume` has no control request at all.** The session browser — titles, timestamps, previews,
   and the client-side title search offering 10 `custom-title` matches — must be rebuilt entirely
   from `~/.claude/projects/**/*.jsonl`, and resuming means relaunching the binary with `--resume`.
   Highest-effort rebuild in the chapter, and unavoidable: no GUI ships without a session list.
   (Row `/resume`; §21.5.)
5. **Two commands are refused headless while their control requests exist** — `/reload-plugins`
   (`supportsNonInteractive: false`, but `reload_plugins` exists) and `/rewind`
   (`supportsNonInteractive: false`, but `rewind_conversation` and `rewind_files` exist). A GUI that
   maps user intent to command text instead of to control requests will get a refusal for
   functionality it actually has. `/rewind`'s checkpoint browser is a substantial rebuild.
6. **`update_settings` writes localSettings only.** This bounds `/config`, `/hooks`, `/memory`,
   `/theme`, `/output-style`, `/vim`, `/sandbox`, `/cloud-plugins` and `skillOverrides` simultaneously.
   Any GUI settings surface that lets a user edit user- or project-scope configuration must write
   files directly, and nothing then tells the running session to re-read them. (§24, row `/config`.)
7. **`/memory` is unreachable and memory edits do not propagate.** No control request touches
   CLAUDE.md configuration. A GUI can read and write the files, but the live session's loaded memory
   will be stale until it restarts. (Row `/memory`.)
8. **The wire drops `type`, `source`, `loadedFrom` and `kind`, so the `/` menu's grouping and
   provenance cannot be reproduced.** Empty-query bucketing (locals, then user, project, policy,
   rest), the `dynamic workflow` tag, and `identityKey`'s ability to distinguish two same-named
   commands from different sources are all lost. The one thing that survives is the provenance
   suffix already baked into the description string. (§0.3, §21.2, §21.4.)
9. **`argNames` is not on the wire**, so the TUI's remaining-positional-argument hints
   (`[name] [name]` as you type) cannot be reproduced for any file-backed command. Only the static
   `argumentHint` string survives. (§21.5.)
10. **One refusal string covers three different causes, and it is not the string the spec
    predicts.** Live, every refused command returned `/<name> isn't available in this environment.`
    as a bare **assistant** frame with no user echo — never the §8.1 row-4 "opens an interactive
    panel" text, which `filterCommandsForHeadless` makes unreachable for built-ins. The one sentence
    is emitted for `local-jsx` commands, for `local` commands with `supportsNonInteractive: false`,
    and for `/statusline`, so a GUI cannot tell from the text why it failed or whether a control
    request would have worked. It must intercept the string and map the name to a native affordance.
    (§3.1.)
11. **`subcommands` maps are invisible.** `/code-review ultra` and the four `design` subcommands
    route server-side and work, but a GUI cannot offer them as completions or warn that
    `/design login` lands on a refused `local-jsx` command. (§12.)
12. **MCP display-name collisions are hidden by `isHidden`, which the GUI cannot see.** A colliding
    MCP prompt is kept but forced hidden (§3.1); a GUI will render the duplicate. Compounded by the
    ` (MCP)` display-name suffix that the parser round-trips literally (§7).
13. **Three GUI-visible strings are client-side spinner text with no wire representation** —
    `progressMessage` (`"analyzing your codebase"` for `/init`, `"analyzing code changes for security
    risks"` for `/security-review`, `"scanning usage data"` for `/team-onboarding`, defaulting to
    `"running"` / `"loading"` for file-backed commands). A GUI showing a generic spinner loses the
    TUI's per-command context. (§2, §18.)
14. **`disableSkillShellExecution` silently blanks `!`-blocks** with the literal
    `[shell command execution disabled by policy]` and emits nothing on the wire to explain why a
    command's output looks wrong. (§16.3, §24.)
15. **Plugins may claim the `help` and `feedback` aliases in headless sessions.** `HEADLESS_YIELDABLE_NAMES`
    lets a plugin take those two names precisely because the built-ins cannot run there, so a GUI
    that hard-codes `/help` may dispatch to a plugin. (§4.1, §6.3.)
16. **`/mcp`'s headless twin is a stub, not a substitute.** Live it printed only
    `3 MCP server(s): 2 connected, 1 not connected, 0 disabled. Use /mcp in the terminal for
    details.` The TUI's per-server status, tool/prompt/resource counts and reconnect actions exist
    only behind the eight `mcp_*` control requests — a GUI that routes the command text gets almost
    nothing. Same pattern, smaller stakes, for `/usage`, which returns prose percentages while
    `get_session_cost` / `get_usage` return structure. (Rows `/mcp`, `/usage`.)
17. **Fast mode is unavailable by construction on this transport.** `/fast` ran but returned
    `Fast mode unavailable: Fast mode is not available in the Agent SDK`, matching
    `initialize.fast_mode_disabled_reason = sdk_opt_in_required`. A GUI should read that field and
    hide the toggle rather than offer a control that cannot succeed. (Row `/fast`.)

---

## Unverified

* **`/advisor`'s control request.** The command declares `thinClientDispatch: "control-request"` but
  neither SPEC 28 §2.1 nor SPEC 45.29 names the request it issues. I did not trace the dialog module
  to find it. The `update_settings` workaround I suggest is inference, not observation.
* **Whether `update_settings` changes take effect in the running session** or only on the next
  launch. The brief states the request is localSettings-only; I did not test propagation.
* **Whether `initialize.commands` is regenerated on `commands_changed`.** I inferred that a GUI must
  re-read on that frame from the frame's existence in SPEC 45.9.1; no `commands_changed` frame
  appeared in either the handshake capture or the 32-command behaviour probe.
* **Whether the §8.1 row-4 message is reachable at all headless.** I argue it is not, because
  `filterCommandsForHeadless` removes `local-jsx` commands before dispatch, and 32 live probes all
  returned the step-8b text instead. A plugin- or MCP-supplied `local-jsx` command, or a reload race
  where the list still holds one, could in principle still reach it; I did not construct that case.
* **Whether §22's "two user messages" description is wrong or scoped to a path I did not exercise.**
  Live refusals produced an assistant frame with no user echo. Commands that ran did produce the
  user echo. I did not trace which code path emits the assistant frame.
* **`/plan share`, `/mobile`'s QR URL, `/session`'s URL** — I assert these are not on the wire based
  on the absence of a matching control request in the brief's 66-request list, not on reading ch. 36/37.
* **C4E upsell stub visibility.** I state the six stubs (`ultraplan`, `ultrareview`, `teleport`,
  `remote-control`, `schedule`, `autofix-pr`) are hidden and gated on `tengu_c4e_slash_upsell`; this
  account is not API-key-based so none were observed, and I could not confirm how they interact with
  the same-named registered commands beyond the §6.1 precedence rule.
* **The `local-jsx` count of 60 in §2.2** is derived from my parse of the §5 table, not from a
  separate enumeration of the binary. The chapter itself says 80 `local-jsx` *objects*; 60 is the
  count of distinct *names* whose only registered variants are `local-jsx` (the 17 twin names and the
  three unregistered twins account for the difference).
* **`terminal_slash_commands = ["doctor","color"]`.** I confirmed `doctor` carries
  `terminalOriented: true` at `cli.pretty.js:386964` and that `Mxe` builds the array from
  `userInvocable !== false && terminalOriented === true` at `cli.pretty.js:448059`. I did not verify
  that the same two names appear on a machine with different bundled-skill gating.
* **§25 verbatim prompt bodies** were skimmed per the brief, so any user-visible affordance that
  exists only inside those prompt texts (e.g. the new `/init`'s Phase 1 question set, which uses
  `AskUserQuestion` and therefore *does* reach a GUI as a `can_use_tool` request) is not inventoried
  here beyond that note.
