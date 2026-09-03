<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

> **Errata from live probes (see ../README.md §4 and ../evidence/):**
> - Top gap 1 names `CLAUDE_CODE_REMOTE` as a workaround for live tool output. Probe 11 (`evidence/2026-09-03-control-request-shapes.md`) shows `tool_progress` carries only `elapsed_time_seconds` under the container variable and never output; the task output file is the only live source.
> - Top gap 14 says fast mode is unavailable headless. Probe 09 shows `apply_flag_settings {settings:{fastMode:true}}` clears `sdk_opt_in_required` and `/fast` then toggles normally.

# 41. TUI rendering — TUI-vs-headless UX gap inventory

Scope: SPEC chapter 41 §41.7–41.28 (renderer internals §41.1–41.6 excluded; §41.5.6 is covered
only where the flicker/reset behaviour has a user-visible consequence). Classes are P / R / D /
X / T exactly as defined in the common brief.

Ground truth used beyond the SPEC:
* `/tmp/afleet-gap/init-dump.json` — live `initialize`, `get_context_usage`, `get_session_cost`,
  `get_settings`, `get_usage`, `mcp_status`, `background_tasks`, `get_binary_version` responses
  from 2.1.259.
* `/tmp/afleet-gap/turns.ndjson.log` + `.summary.json` — live per-command probe of ~45 slash
  commands through the headless wire, and one real turn with a background Bash and a subagent.

Two facts from that capture are load-bearing for many rows below and are stated once here:

1. **`user` frames carry `tool_use_result`** — the full structured result object, not just the
   model-visible text. Live example (Bash, background):
   `{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"bbtvfk69j"}`
   (SPEC 45:1471 confirms `tool_use_result: d.toolUseResult`). Almost every per-tool result form
   in §41.16.7 is therefore a **rebuild (R)**, not a data gap.
2. **Every `local-jsx` panel is refused headless** with `"/<name> isn't available in this
   environment."` (live results for `/help`, `/status`, `/theme`, `/tui`, `/copy`,
   `/terminal-setup`, `/statusline`, `/diff`, `/focus`, `/brief`, `/vim`, `/plan`, `/permissions`,
   `/tasks`, `/skills`, `/memory`, `/hooks`, `/resume`, `/export`, `/btw`, `/bug`, `/release-notes`,
   `/keybindings`, `/add-dir`, `/cd`, `/fork`, `/background`, `/loops`, `/sandbox`, `/ide`).
   `request_user_dialog` never carries a `local_jsx` panel; `can_use_tool` covers only
   permission / `AskUserQuestion` / `ExitPlanMode`.

---

## 41.7 Text: measurement, wrapping, truncation, hyperlinks

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `textWrap` modes (`wrap`, `wrap-trim`, `wrap-stream`, `truncate`/`truncate-start`/`truncate-middle`) | Six modes, hard word wrap by default; `wrap-stream` drops the final partial row so streaming text has no stale trailing line (§41.7.1) | Nothing on the wire; the host owns layout | T | A GUI wraps natively. The one behaviour worth copying is `wrap-stream`: during `stream_event` deltas, do not lay out the last partial line as a settled row, or the last line jitters on every delta. |
| Ellipsis and the four truncators (path-aware, end, start, hard clip) | Always U+2026, never `...`; `el()` keeps the trailing `/basename` when eliding a path (§41.17.10) | — | T | Worth copying the path-aware rule verbatim for file chips: middle-elide, keep the basename. |
| Untrusted-text sanitising | Two passes strip `Cc/Cf/Cs/Co/Cn`, U+2028/29, default-ignorables, U+2800, then bidi overrides, zero-width marks, U+FEFF and PUA, iterated up to ten times (§41.7.4) | Not done on the wire — the CLI sanitises at paint time, so the host receives the raw text | R | A GUI must run its own sanitiser or a bidi-override / zero-width attack in tool output or model text renders in the GUI. This is a security-relevant rebuild, not cosmetics. |
| Notification-text sanitising | Code points < 32 and C1 (127–159) become a space before any OSC notification (§41.7.4) | — | T | Only matters if the GUI re-emits terminal escapes; a native notification API needs its own clamp. |
| OSC 8 hyperlinks in rendered content | `ink-link` interns a URI; the diff engine emits OSC 8 open/close around runs sharing a URI, with a djb2 id in base 36 so wrapped links stitch back together; close is `ESC]8;;BEL` (ST under kitty) (§41.7.5) | Model text arrives as markdown; link tokens are the host's to render | T | A GUI **exceeds** the TUI here: real clickable links with hover targets, no `(url)` degradation, no capability sniff (§41.11.4 `vf()`), no terminal that silently drops the escape. |
| Hyperlink degradation | When OSC 8 is unsupported the emitter falls back to `text (url)`, or the bare URL when there is no distinct label (§41.17.5) | — | T | A GUI should not reproduce the degraded form. |

## 41.8 Scrolling and the virtual message list

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Scroll container semantics: sticky-to-bottom, `followGrowth`, re-enable sticky on return to bottom | Per-node `scrollTop`/`scrollHeight`/`stickyScroll`/`scrollAnchor`; sticky re-enables automatically when the user scrolls back to the bottom (§41.8.1) | Not on the wire | R | The behaviour a GUI must copy: follow new output only while already pinned to the bottom, and re-pin silently when the user returns. `autoScrollEnabled` (default true) is readable from `get_settings`, so honour the user's setting. |
| Animated wheel drain (adaptive vs proportional curves) | Wheel delta accumulates and drains over frames: adaptive consumes >30 rows instantly then 2–3 rows/frame; proportional consumes ¾ of the remainder, min 4 rows (§41.8.2) | — | T | Native GUI scrolling with momentum supersedes this. |
| Hardware scrolling via DECSTBM | Full-width, unchanged-rect containers emit a scroll-region + `SU`/`SD` instead of repainting (§41.8.3) | — | T | Pure terminal optimisation. |
| `/scroll-speed` | `local-jsx`, fullscreen-only, never in JetBrains terminals; the dialog writes `userSettings.env.CLAUDE_CODE_SCROLL_SPEED`; footer `Scroll to feel it · ←/→ adjust · r reset to auto · Enter save · Esc cancel` (§41.8.4) | Not in the headless command list; refused as `local-jsx` | T | Superseded by OS scrolling. If the GUI ever wants parity it should note the setting is written into `env` inside settings.json, not a top-level key. |
| `CLAUDE_CODE_SCROLL_SPEED` env | Lines per wheel notch, float, ignored if ≤0/NaN, capped at 20; base 3 for xterm.js/Windows, 2 for JetBrains, else 1 (§41.8.4) | Readable from `get_settings` → `effective.env` if the user set it | T | Only useful if the GUI embeds a terminal view. |
| JetBrains wheel-inversion workaround | Rewrites a `wheelup` within 250 ms of a `wheeldown`, drops arrow keys within 75 ms of a wheel event (§41.8.5) | — | T | Terminal-emulator bug, gone in a GUI. |
| Virtual message list (windowing, 300-item cap, overscan, scroll anchoring, column-change rescale) | Windowed list with prefix sums, fast-scroll clamp of 25 items, anchor re-pin after each commit (§41.8.6, §41.15.3) | The host receives every frame and owns its own list | R | A GUI needs its own virtualisation for long transcripts. Two rules are worth copying because they are UX, not perf: (a) scroll anchoring — remember the item nearest the viewport top and correct `scrollTop` by however much it moved after a commit, otherwise streaming content shoves the view; (b) freeze the range for two frames after a width change while heights re-settle. |
| Element-tree commit cursor (200-message window, 50 rows slack, 30 in transcript mode) | Messages behind the cursor are unmounted; their rows survive only in terminal scrollback (§41.15.3) | — | R | A GUI **exceeds** the TUI: it can keep the whole transcript live and searchable instead of letting old messages fall into scrollback where they can never be re-styled or re-flowed. |
| `CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL` | Renders the list flat (§41.8.6) | — | T | Debug switch. |
| Jump-to-bottom pill: `Jump to bottom` / `<N> new messages`, with `(click) ↓`, `: <chord> to scroll`, `(<chord>) ↓` and bare `↓` suffixes (§41.15.2) | Fullscreen renderer only | Unseen-message count is derivable from the frames the host has rendered vs its own scroll position | R | Cheap parity win; the count logic is entirely host-side. |

## 41.9 Colour capability detection

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Colour level 0–3 detection (16-step chain: `--color` flags, `FORCE_COLOR`, CI vendors, `COLORTERM`, `TERM` families, `TERM_PROGRAM`) | §41.9.1 | — | T | A GUI is always "level 3". |
| `NO_COLOR` / `FORCE_COLOR` / VS Code 2→3 bump / tmux truecolor clamp (`CLAUDE_CODE_TMUX_TRUECOLOR`) | §41.9.2 | — | T | — |
| Four colour dialects `ansi:<name>`, `#rgb`/`#rrggbb`, `ansi256(n)`, `rgb(r,g,b)`, and the `X6()` validator | §41.9.3 | — | R | Only matters if the GUI reads user custom themes (§41.10.4) — it must accept exactly these four forms and silently drop anything else. |
| Truecolor → 256 downgrade, Apple Terminal pinned to level 2, italic-as-standout stripping under `TERM=screen*` | §41.9.4 | — | T | — |
| `/color <name>` — per-session prompt/accent colour | `local-jsx`, `terminalOriented`, palette = the eight `*_FOR_SUBAGENTS_ONLY` keys; empty arg picks a random colour; reset aliases `default/reset/none/gray/grey`; teammate sessions refuse with `Cannot set color: This session is a teammate…`; messages `Session color set to: <name>` / `Session color reset to default` (§41.9.5) | **Works headless.** Live: `/color red` → `result:success` `"Session color set to: red"`. Also a first-class control request, `set_color`. `terminal_slash_commands` lists it, so a GUI is told it is terminal-oriented | P | The colour is a session tag pushed to the bridge, so a GUI can both set it (`set_color` or the text command) and use it to tint its own session chrome — useful for multi-session windows. Note the TUI only tints the prompt border and subagent labels; a GUI can tint the whole window. |

## 41.10 Themes

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `theme` setting: six built-ins + `auto` + `custom:<slug>` | `dark`, `light`, `light-daltonized`, `dark-daltonized`, `light-ansi`, `dark-ansi` (§41.10.1) | `get_settings` returns `effective.theme` (live: `"dark"`). `/config theme=auto\|dark\|light\|light-daltonized\|dark-daltonized\|light-ansi\|dark-ansi` works headless (live `/config` usage text) | R | A GUI should read the user's theme choice and at minimum follow light/dark from it, and should offer the two daltonized variants — they are the product's only colour-blind affordance and a GUI that ships only light/dark regresses accessibility. |
| The 72-key palette, six tables | Full table in §41.10.3, including `diffAdded*`/`diffRemoved*`, the eight subagent colours, `rate_limit_fill/empty`, `briefLabelYou/Claude`, the rainbow pairs | Not on the wire | R | The exact RGB values are in the spec; a GUI wanting visual continuity with the terminal should seed its palette from them, especially the diff and subagent colours which users learn by sight. |
| `theme: "auto"` background detection | OSC 11 query → luminance test (0.2126/0.7152/0.0722 > 0.5), then `COLORFGBG` last field, then `dark`; re-queried on DEC 2031 theme-change notification; tmux/screen DCS-wrapped with a 2000 ms race (§41.10.2) | — | T | A GUI uses the OS appearance API; strictly better (it also gets change notifications reliably, which the OSC 11 path does not on terminals that never answer). |
| Custom themes `~/.claude/themes/<slug>.json` | `{ name, base, overrides }`; invalid base → `dark`; unknown override keys and malformed colours silently dropped; 256 KiB cap; `.json` only; sorted by display name; directory watched with `awaitWriteFinish` 300 ms; plugins contribute `pluginThemes` (§41.10.4) | Not on the wire at all | R | Readable from disk. A GUI that ignores custom themes will silently lose a user's personalisation; a GUI that reads them gets it for free. Note the failure mode to copy: a bad theme degrades to its base rather than erroring. |
| `/theme` picker | `local-jsx`, `immediate` in fullscreen (§41.10.5) | Refused headless (live: `/theme isn't available in this environment.`) | X | Panel unreachable; the underlying setting is reachable (row 1). A GUI ships its own theme picker and writes `theme` through `update_settings` (localSettings only) or directly to `settings.json`. |
| Syntax-highlight theme selection | Chosen from the theme **name**: contains `ansi` → indexed, contains `dark` → Monokai Extended, else GitHub (§41.17.6) | — | R | Copy the mapping so code blocks match the chosen theme. |

## 41.11 Terminal capabilities and the escape-sequence library

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| CSI/OSC/DEC-private-mode libraries; kitty vs BEL OSC terminator; tmux/screen DCS passthrough with `ESC` doubling | §41.11.1–41.11.3 | — | T | Only relevant if the GUI shells out to a terminal or embeds one. |
| Capability table (sync output DEC 2026, DECSTBM, OSC 9;4 progress, kitty keyboard/`modifyOtherKeys`, xterm.js detection, OSC 8, strikethrough) | §41.11.4 | — | T | Two entries leak into user-visible behaviour elsewhere: OSC 9;4 gates the progress bar (§41.20.4) and the strikethrough allow-list gates `~~del~~` rendering (§41.17.2) — a GUI always has both. |
| Per-terminal quirk table (JetBrains, Ghostty ink bleed, mintty, VS Code OSC 52 UTF-8 bug 1.123–1.125, macOS cmd-click SGR bug, `screen` italic-as-standout) | §41.11.5 | — | T | The VS Code OSC 52 bug is the only one with a GUI analogue: clipboard writes should not go through OSC 52 at all. |
| Terminal mode lifecycle and the `writeSync` crash restore (`ESC(B`, `SI`, `ESC[>4m`, `ESC[<u`, `ESC[?1004l`, `ESC[?2031l`, `ESC[?2004l`, `ESC[?25h`, scroll-region reset, iTerm2 progress clear) | §41.11.6 | — | T | A GUI hosting the binary in a pty must still do this on abnormal exit if it ever shows that pty to the user. |

## 41.12 Inline versus alternate screen: `/tui`

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Fullscreen/inline decision table, 14 reason codes | Ordered: `bg_forced_on`, `sr_auto_off`, `env_off`, `env_on`, `crash_auto_off`, `tmux_cc_auto_off`, `win_ssh_auto_off`, `settings_on`, `upsell_trial_on`, `settings_off`, `fresh_install_on`, `downsell_on`, `gb_on`/`gb_off` (§41.12.1) | `get_settings` returns `effective.tui` (live: `"fullscreen"`) but the resolved mode is never on the wire | T | Meaningless in a GUI. Worth knowing only because the mode changes what other surfaces do (queued messages, sticky pill, dense footer, `/scroll-speed` availability, dialog layout `modal` vs `inline`). |
| Involuntary downgrade messaging (`fullscreen disabled: tmux -CC…`, `fullscreen disabled: Windows over SSH…`, and the per-machine kill switch message ` (fullscreen was turned off on this machine after it repeatedly failed to start; /tui fullscreen retries)`) | §41.12.1, §41.12.4 | — | T | — |
| `/tui [default\|fullscreen]` | `local-jsx`; **relaunches the process** with `CLAUDE_CODE_TUI_JUST_SWITCHED` and, on the trial path, `CLAUDE_CODE_TUI_TRIAL` (read once, then unset) (§41.12.4) | Refused headless (live: `/tui isn't available in this environment.`) | T | Superseded. |
| Fullscreen upsell (3 impressions max, `CLAUDE_CODE_FORCE_FULLSCREEN_UPSELL`) | §41.12.4 | — | T | — |
| Alternate-screen specifics: selection inversion and search highlight painted into the cell buffer; cursor forced invisible; park patch each frame | §41.12.3 | — | T | The consequence that matters: in fullscreen the TUI owns selection, so native terminal selection needs `option/shift+click` (see §41.15.4 hints). A GUI has native selection always — a real UX win. |

## 41.13 Mouse, focus and selection

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Mouse tracking mode `full`/`scroll`/`off`, chosen by `CLAUDE_CODE_DISABLE_MOUSE` / `CLAUDE_CODE_DISABLE_MOUSE_CLICKS`; re-asserted after every resize | §41.13.1 | — | T | — |
| Hit testing and wheel bubbling to the first `onWheel` ancestor | §41.13.2 | — | T | — |
| Selection with `noSelect` planes — gutters use `noSelect: "from-left-edge"` so copying a message never picks up the `⏺`/`⎿` chrome; soft-wrap plane reassembles wrapped rows into logical lines; `followScroll` keeps the anchor pinned while content scrolls under it | §41.13.3, §41.16.3 | — | R | This is the single most copyable selection rule: **chrome must be unselectable and wrapped lines must copy as one logical line.** A GUI gets the second for free from text layout but must deliberately exclude gutters, bullets, line numbers and diff markers from selection/copy. |
| `copyOnSelect` (global config, default true) | Referenced in the `/config` row list (§41.26.2) | `/config copyOnSelect=true\|false` works headless (live usage text) | R | A GUI should honour it; it is a real user preference and cheap to read. |
| Search highlighting: every match inverted; the current match gets yellow + inverse + bold + underline with existing fg/bg stripped; any highlight forces full-screen damage | §41.13.4 | — | R | Transcript search is host-side. Copy the two-tier styling (all matches vs current match) — users rely on it to navigate `n`/`N`. |
| Terminal focus (DEC 1004) and the tmux hints `tmux focus-events off · add 'set -g focus-events on'…` and `tmux detected · scroll with PgUp/PgDn · or add 'set -g mouse on'…` | §41.13.5 | — | T | Focus state itself matters to a GUI (it gates the "terminal is active" suppression in `PushNotification`, §41.20.6) but the GUI knows its own focus natively. |

## 41.14 Accessibility and the screen-reader renderer

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `CLAUDE_CODE_ACCESSIBILITY` | Cursor stays visible, native cursor used, line-number gutter always drawn; also replaces the `/config` list with a numbered form (`Enter a number to change [1-N]…`, §41.26.3) | Not on the wire | T | A GUI uses platform accessibility. But note the two behavioural knock-ons the TUI ties to this flag that a GUI should reproduce as its own accessibility mode: always show code line numbers, and offer a keyboard-numbered alternative to any pointer-driven list. |
| `INK_SCREEN_READER` / `CLAUDE_AX_SCREEN_READER` line-oriented renderer | `onRender` diverts to a line-diff renderer: flatten to text + preserve-whitespace ranges, hard wrap, park the cursor where the reader should announce, diff by common prefix with append/erase fast paths (§41.14) | — | X → superseded | Unreachable headless and irrelevant to a GUI, but the *requirement* it encodes is not: a GUI must expose the transcript through the platform accessibility tree with correct roles and live-region semantics. The TUI's `aria-label`s (`tool:`, `tool error:`, `claude:`, `(selected)`, `(more below)`, `done:`, `failed:`) are the vocabulary to mirror (§41.16.2, §41.22.8, §41.22.12). |
| `CLAUDE_AX_STARTUP_QUIET_MS`, `CLAUDE_AX_PREPARK_MS` | Startup quiet period suppresses all output; pre-park delay parks the cursor at column 1 before a large redraw so the reader is not interrupted mid-utterance | — | T | The generalisable rule for a GUI: do not fire a live-region update mid-announcement during bulk streaming; batch. |
| Screen-reader mode forces `nativeCursor`, disables fullscreen (`sr_auto_off`) and DECSTBM, and skips the Apple Terminal bell change in `/terminal-setup` (§41.25.4) | §41.14, §41.12.1 | — | T | — |
| Screen-reader table rendering: each row flattened to `header: value` clauses ending in a period (§41.17.4c) | | — | R | Worth copying as the GUI's accessible table serialisation. |

## 41.15 Screen composition

### 41.15.1–41.15.3 Root, layout frame, message list

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Three-region frame (scrollable / sidebar / bottom column) with three renderer branches (fullscreen, DECSTBM, classic inline) | §41.15.2 | — | T | Layout is the GUI's own. |
| Sticky-prompt pill and jump-to-bottom pill (fullscreen only) | §41.15.2 | — | R | See §41.8 row. |
| `Viewing @agent` header (`viewSelectionMode`) | §41.15.1 | Subagent text arrives only with `--forward-subagent-text`, tagged `parent_tool_use_id` | R | afleet passes the flag, so per-subagent views are buildable; the *selection* UI is host-side. |
| Queued messages block (fullscreen only) | §41.15.1 | `command_lifecycle` (queued→started→completed/cancelled/discarded/refused) is on the wire; `--replay-user-messages` echoes queued user input | P | A GUI can show a proper queue with reorder/cancel — **exceeds** the TUI, which only lists them. |
| Unseen-message divider snapshot | §41.15.2 (scroll store) | Host-side | R | — |
| Duplicate-uuid dedupe (`#N` suffix) and the three VirtualMessageList invariant errors | §41.15.3 | — | R | A GUI keying rows by `uuid` must handle the same upstream duplicate-uuid case; the CLI reports it rather than repairing it silently. |

### 41.15.4 The footer cluster — every indicator

The footer is a left column (statusLine row + hint row) beside a right-aligned column
(notifications + indicator chips) [`chunk-bq8epagv.js:410812`]. **The working directory, git
branch and model name are not native footer segments** — they reach the terminal only through the
user's `statusLine` command (§41.19.3). Row-replacing states pre-empt the hint row entirely.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| statusLine row | The user's own command output, dim, one truncating `Text` per line (§41.19.6) | See §41.19 — the payload must be rebuilt by the host | R | Highest-value footer row; see the §41.19 gap analysis. |
| Hint row: dense vs classic layout (gate `tengu_copper_thistle`) | Two mutually exclusive one-row layouts, segments joined by dim ` · ` (§41.15.4) | — | R | A GUI can show all affordances at once instead of racing for width. |
| `Press <key> again to detach (session keeps running)` / `… to exit` | Row-replacing, when an exit message is pending | — | T | Detach/exit is a GUI window action. |
| `Pasting…` | Row-replacing while a paste is in flight | — | R | Host-side (§41.24). |
| `paste again to expand` | Row-replacing when a collapsed paste can be expanded | — | R | Host-side. |
| `-- <vimMode> --` | Row-replacing when vim mode ≠ NORMAL and `hideVimModeIndicator` is off | `editorMode` readable via `get_settings` (live: `"normal"`); the live mode is host-side | R | If the GUI implements vim keys it owns the indicator, and must honour `statusLine.hideVimModeIndicator` so a user script that renders `vim.mode` itself is not doubled. |
| `! for shell mode` | Row-replacing in bash-composer mode, coloured `bashBorder` | Bash composer maps to the `bash_command` stdin frame (one-shot `/bin/sh -c`, no transcript, no persistent shell) | R | A GUI must reproduce the mode; note the headless `bash_command` has no persistent shell, unlike the TUI's `!` mode expectations. |
| Single blank space | Row-replacing in fullscreen when nothing to show, preserving row height | — | T | Layout artefact. |
| `? for shortcuts` | Dense: selected hint. Classic: only when no other hint and no pills fit | — | R | A GUI shows a help affordance permanently. |
| `esc to interrupt` / `esc to return to team lead` | While a turn runs; composed from the `chat:cancel` binding, not a literal (§41.18.4) | `system/status`, `session_state_changed` (`running`), `result` bound the turn; `interrupt` control request performs it | P | Data on the wire; the control exists. |
| `ctrl+t to show tasks` / `… to hide tasks` | When todos exist | TodoWrite results arrive as `tool_use_result`; `TodoWrite` has **no** result renderer in the TUI (§41.16.5) | R | A GUI **exceeds** here: the TUI can only show todos in the diff sidebar progress bar and the tasks panel; a GUI can render the todo list as a first-class always-visible panel. |
| `enter to view tasks` / `down to manage` | Task footer chip selected/unselected | `background_tasks` control request; `task_started`/`task_updated`/`task_progress`/`task_notification`/`background_tasks_changed` frames | P | Full parity data. |
| `enter to view memories` | Memories chip selected | `memory_recall` frames | R | — |
| `hold <space> to speak` | Voice on, session idle, seen < 3 times | Voice is a TUI input path; `voice`/`voiceEnabled` in settings | D | No wire affordance for voice capture; a GUI would build its own dictation and inject a `user` frame. |
| `/tasks to see subagents` | Subagent tasks exist | `task_*` frames, `--forward-subagent-text` | P | — |
| `/diff to hide diff` | Diff tab active in a git repo | `get_workspace_diff` control request | R | — |
| `ctrl+c to copy` / `option+click to native select` / `shift+click to native select` | Fullscreen with a live selection | — | T | A GUI has native selection and copy; this hint disappears entirely — a straight UX improvement. |
| `← for agents` / `← <n> agents` / `← <n> done` | Agents chip | `task_*` frames; `initialize.agents` | R | — |
| `↳ <n> background` | ≥2 background tasks, dense layout | `background_tasks_changed`, `background_tasks` | P | — |
| `<n> feedback drafts` | Drafts exist | `feedback_draft_queued` frames; `submit_feedback` control request | P | — |
| Permission-mode pill | `⏸ plan mode on`, `⏵⏵ accept edits on`, `⏵⏵ bypass permissions on`, `⏵⏵ don't ask on`, `⏵⏵ auto mode on`; `default` suppressed; colours `planMode`/`autoAccept`/`error`/`error`/`warning` | `initialize.current_permission_mode` (live: present), `system/status` permissionMode change frames, `set_permission_mode` control request | P | Full parity including the symbol/colour table. |
| IDE selection chips `⧉ N lines selected` / `⧉ N lines from diff` / `⧉ N lines from <path>` / `⧉ In <path>` | §41.15.4 | IDE integration is a separate lane (ch. 33); not on the headless wire | D | A GUI that is itself the editor supersedes this; a GUI beside an external editor has no wire path to the IDE selection. |
| `◎ cloud` chip | Cloud session indicator | Remote-control/cloud state is partly in `initialize` (`remote_control_available`, `remote_control_auto_enable`) | R | — |
| `Debug` chip | Debug mode | — | T | — |
| `focus` chip | Terminal focus state | — | T | GUI knows natively. |
| `memory paused` chip | Memory paused | `memory_recall` / settings | R | — |
| Context indicator | **Not a footer segment** — it is a notification: `<N>% until auto-compact` / `<100−N>% context used`, and the low-context warning `Context low (<N>% remaining) · Run /compact to compact & continue` | `get_context_usage` returns `percentage`, `totalTokens`, `maxTokens`, `autoCompactThreshold`, `isAutoCompactEnabled`, `categories`, `messageBreakdown` (verified live). `autocompact_state` frames are emitted **only** under `CLAUDE_CODE_REMOTE` | R | A GUI must poll `get_context_usage` after each `result` frame (and ideally after each assistant message) to keep a live context meter, because nothing pushes it. A GUI **exceeds** the TUI: `get_context_usage` also returns the per-category breakdown (system prompt, memory files, MCP tools, agents, slash commands, skills) that the TUI only shows inside `/context`. |
| The `?` help panel replacing the whole footer | Lists `! for shell mode`, `/ for commands`, `@ for file paths`, `/btw for side question`, `double tap esc to clear input`, `shift + tab to auto-accept edits`, `ctrl + o for verbose output`, `ctrl + t to toggle tasks`, `ctrl + _ to undo`, `ctrl + z to suspend`, `ctrl + v to paste images`, `alt + p to switch model`, `alt + o to toggle fast mode`, `ctrl + s to stash prompt`, `ctrl + g to edit in $EDITOR`, `/keybindings to customize` | `/help` is refused headless (live) | X → R | The panel is unreachable, but every entry maps to a host-side affordance a GUI must provide its own UI for. Note `/btw` (side question) has a real control request, `side_question`, and its progress arrives as `control_request_progress` — the only progress kind on the wire. |

### 41.15.5 The notification bar — every message it can carry

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Two bars: pinned (above input, prefixed `⚠`, `warning` colour, never expires) and transient (below input, 8000 ms default, one shared timer) | §41.15.5 | `system/notification` frames carry `{key, text, priority, color?, timeout_ms?}` (SPEC 50:1639) — the wire shape has no `jsx`, `segments`, `pinned`, `invalidates`, `fold` or `kind` | R | A GUI can render the wire-borne subset directly, but must invent its own pinned/transient split: the wire does not say which bar an entry belongs to. |
| Priority ordering `immediate`/`high`/`medium`/`low`, ties to earliest-inserted; `immediate` preempts synchronously and pushes the incumbent back to the queue head | §41.15.5 | `priority` is on the wire | P → R | Copy the tie-break and the preemption/requeue rule or notifications will reorder confusingly. |
| First-writer-wins dedupe by `key` (a duplicate is discarded, not replaced, unless `fold`) | §41.15.5 | `key` is on the wire | R | Non-obvious and worth copying: repeated identical notices must not restart the timer. |
| Diff-panel hold: only `exemptFromDiffPanelHold` entries display while the diff panel is up | §41.15.5 | Not on the wire | R | Host policy. |
| `timeoutMs: 2147483647` idiom = never auto-dismiss but still evictable | §41.15.5 | `timeout_ms` on the wire | R | Handle the sentinel or a GUI will schedule a 24-day timer. |
| Remote-origin clamps: key prefixed `remote:` and truncated to 256 chars, text clamped to 1000 chars and one line, timeout clamped 0…60000 ms, `immediate` demoted to `high`, at most 3 queued | §41.15.5 | Applies to notifications injected from a remote host | R | A GUI injecting its own notices should apply the same clamps. |
| Representative local-only entries: `Deeper reasoning requested for this turn` (ultrathink), `Scroll wheel is sending arrow keys · use PgUp/PgDn to scroll`, the rate-limit family (§41.16.11), `Automatic continue cancelled · /rate-limit-options to re-arm`, `<paste> is no longer available and was removed from the prompt` (§41.24.1), `/<cmd> is currently unavailable.` (§41.22.3), `No image found in clipboard…` (§41.24.4), `Status line is configured but disableAllHooks is true` (§41.19.6) | Scattered across §41.15.5, §41.16.11, §41.22.3, §41.24 | Most are raised locally by TUI code paths and never cross the wire | D | These are the concrete losses. A GUI must synthesise its own equivalents from the underlying wire events (`rate_limit_event`, `informational` banners, `permission_denied`, `api_retry`, hook events). Several — the ultrathink confirmation, the paste-eviction notice, the clipboard-miss notice — are purely host-side anyway and become the GUI's own. |
| `informational` banners (info/notice/suggestion/warning), including local slash-command output and hook feedback | Rendered as system rows / notices | On the wire as `system/informational` | P | Direct render. |

### 41.15.6 Mode unions

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `screen` (`prompt`/`transcript`), `streamingPreviewHold`, `replTab` (`convo`/`diff`), `expandedView` (`none`/`tasks`), `viewSelectionMode`, `footerSelection` (`null`/`tasks`/`workflows`/`frame`/`memories`), dialog `layout`, dialog hide reason, renderer | §41.15.6 | None on the wire | R | Pure host-side view state. Listed because each is a distinct view a GUI must decide whether to offer; `footerSelection` in particular encodes that the footer chips are *focusable* — a keyboard-navigable footer is an affordance a GUI can easily miss. |

### 41.15.7 Welcome chrome

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| The 58×30 art box | Only on four pre-REPL screens (onboarding, Pro-trial start, `setup-token`, powerup discovery); **never inside the REPL**; degrades to `Welcome to Claude Code` under 30 rows | Pre-REPL flows are not headless | X | Onboarding is a GUI-owned flow. |
| REPL header: `Claude Code v<version>` / model + billing type (+ trial badge) / `@<agent> · <cwd>` | Three dim lines beside a 9×3 animated sprite; no `cwd:` label; path is project-relative → `~`-relative → absolute; empty under `CLAUDE_CODE_HIDE_CWD`; middle-elided to `max(columns−15, 20)` minus the agent name (§41.15.7) | `initialize` returns `models`, `account`, current model, agents; `get_binary_version` returns `{version, buildTime}`; cwd is the host's own | P | Everything needed is available on demand; the GUI renders it as a title bar. |
| Sprite animation (fullscreen only) and the one-shot extras (release-notes summary, entrance animation), suppressed when resumed / background / teammate | §41.15.7 | — | T | — |
| `hideWelcomeChrome` (hides the header, keeps the announcement slot) | §41.15.7 | — | T | — |

### 41.15.8 The autocomplete menu

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Windowed suggestion list, height `max(1, min(max(6, rows/2), rows−3))`, window centred on the selection, padded to constant height so the prompt does not jump | §41.15.8 | — | R | A GUI popup is unconstrained; the "don't let the prompt jump" rule still applies. |
| Path-like rows (`file-`, `mcp-resource-`, `mcp-template`, `agent-`) get a 20-column description cap and a different width split | §41.15.8 | — | R | — |
| Selected row `suggestion`-coloured, unselected dim; hover selects, click accepts | §41.15.8 | — | R | — |
| The suggestion *data*: commands, agents, files, MCP resources | Local index, or the user's `fileSuggestion` command | `initialize.commands` (live: 102 entries with name/description/argumentHint/aliases), `initialize.agents`, and the `file_suggestions` control request (`query` → `suggestions?`) — which is what honours the user's `fileSuggestion` setting | P | Strong parity: a GUI gets the command list and file suggestions from the CLI itself, including plugin/skill commands, so it never drifts from the binary. **Caution:** the headless `commands` list is the user-invocable set only — it excludes every `local-jsx` panel (no `theme`, `tui`, `copy`, `diff`, `help`, `statusline`, `terminal-setup`, `plan`, `permissions`, `tasks`, `skills`, `memory`, `hooks`, `resume`, `export`, `vim`, `focus`, `brief`). A GUI must add its own entries for the affordances it reimplements, or users will find the menu impoverished relative to the terminal. |

### 41.15.9 Other panels

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Diff sidebar in the `sidebar` slot | §41.16.9 | See §41.16.9 rows | R | — |
| FleetView (replaces the whole screen for multi-session harnesses): display name from `name`, else the first words of the intent capped at 25 columns, else `current session`/`new session`; status words `Done`/`Failed`/`Stopped`/busy/blocked(`warning`)/dim `Idle` | §41.15.9 (semantics in ch. 39) | Per-session state via `session_state_changed` (`idle`/`running`/`requires_action`) and `result` | R | afleet is itself a multi-session host; the naming fallback chain and the six status words are worth copying verbatim for its session list. `requires_action` is the signal that a `can_use_tool` or `request_user_dialog` is parked — the correct trigger for a "needs you" badge. |

## 41.16 Message and tool-result rendering

### 41.16.1–41.16.4 Chrome, bullets, gutters, input border

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| The glyph vocabulary: `❯` user prefix, `⏺`(macOS)/`●` tool+assistant bullet, `⎿` result gutter, `∴` thinking bullet, `✻` thinking/scheduled/summary, `∙` progress separator, `※` recap, `⧉` IDE/artifact, `↳` nesting, `↻` MCP resource update, `⑂` fork, `◇`/`◆` ultraplan, `♪` audio, `▌` streaming caret, `!` bash prefix, `⏸`/`⏵⏵` permission modes, `├└│┬┴` agent tree, `∴∷∵∷` thinking cycle, `⚠` pinned notice, `⌕` search, `▎` blockquote, `█` swatch, `─` rule, `╭╮╰╯` corners. **No ASCII fallback table** (unlike vendored `figures`) | §41.16.1 | Message roles and block types are on the wire; the glyph vocabulary is not | R | A GUI replaces glyphs with real iconography. The mapping matters for recognisability: users read `⏺` green/red as tool success/failure at a glance. Absent from this build: any `#` memory prefix, `%` mode prefix, or `☒`/`☐` todo chrome. |
| Bullet state machine: running = dim, blinking between bullet and space every 600 ms; done = `success`, not dim; errored = `error`; queued = dim, no blink. Assistant prose bullet is `color: "text"` and only on the first content block. System bullets: `warning` → warning colour, `notice` → `inactive`, `info` → **no bullet**, dim | §41.16.2 | Tool state is derivable: `assistant` frame with a `tool_use` block → running; the matching `user` frame with `tool_result` (and `is_error`) → done/errored; `command_lifecycle` and `set_in_progress_tool_use_ids` (**dropped** before the wire) would have made it explicit | R | The one real subtlety: `set_in_progress_tool_use_ids` is in the dropped list (SPEC 45.9.2), so a GUI must infer "in progress" purely from unmatched `tool_use` ids. That inference is exact for the main thread; for subagents it needs `parent_tool_use_id` bookkeeping. |
| Gutters: 5-column canonical result gutter `"  ⎿  "` (with a non-breaking space), 7 columns for hook sub-lines, `marginLeft: 5` bodies, `paddingLeft: 2` standard indent, `paddingLeft: 3` agent-tree rows, `columns − 12` diff/Write preview width; every gutter `noSelect: "from-left-edge"` | §41.16.3 | — | R | Indentation depth is the only cue for nesting (tool → result → hook sub-line); a GUI needs an equivalent hierarchy. |
| Input box "border" is **only a bottom rule**, colour `bashBorder` in bash mode, the viewed subagent's colour when viewing a subagent, else `promptBorder`; plan mode does **not** tint it | §41.16.4 | Permission mode on the wire; subagent identity via `parent_tool_use_id` | R | Note the deliberate absence: plan mode is signalled by the footer pill, not the composer. A GUI is free to do better, but should not tint the composer for plan mode if it wants terminal-consistent muscle memory. |

### 41.16.5–41.16.6 Dispatch and shared primitives

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Three-stage renderer dispatch (tool object → `builtinRenderFamily` → static table keyed by `uiTableKey ?? name`), nine dispatch slots (`renderToolResultMessage`, `renderToolUseErrorMessage`, `renderToolUseRejectedMessage`, `renderToolUseProgressMessage`, `renderToolUseQueuedMessage`, `renderToolUseTag`, `renderGroupedToolUse`, `userFacingNameBackgroundColor`, `isResultTruncated`) | §41.16.5 | The host must key its own renderers off `tool_use.name` | R | Copy the `uiTableKey` idea: `mcp__<server>__<tool>` → one generic MCP renderer, `mcp__<chrome-domain>__*` → the Chrome family, `mcp__computer-use__*` → the computer-use family, `eval_registered__*` → the REPL renderer. Without it a GUI shows raw MCP tool names. |
| `… +12 lines (ctrl+o to expand)` — the overflow count + expand affordance, and the universal error renderer | §41.16.6 | Full result text is on the wire in `tool_use_result` | R | The chord in the affordance must become a GUI gesture (click/disclosure). |
| Error normalisation: non-string result → `Tool execution failed`; a string containing `InputValidationError: ` → `Invalid tool parameters` (outside verbose); otherwise prefixed `Error: ` unless already `Error: ` or `Cancelled: `; errors truncate at 10 lines | §41.16.6 | `is_error` and the raw text are on the wire | R | Copy the normalisation, especially `InputValidationError` → `Invalid tool parameters`, and keep the raw text behind a verbose toggle. |

### 41.16.7 Per-tool result forms

Every row below has its structured input in the `assistant` frame's `tool_use` block and its
structured result in the `user` frame's `tool_use_result`, so the class is **R** unless noted:
the data is on the wire and the host reimplements the presentation.

| Tool | TUI rendered form (SPEC §41.16.7) | Class | Notes |
|---|---|---|---|
| `Grep` / `Glob` (shared renderer) | Three modes — `content` → lines, `count` → matches + files, `files_with_matches` (default) → files. Sentence `Found <bold N> file(s)`, singularised by slicing the trailing `s`; secondary count adds ` across N files`. **No "No files found" string** — zero renders as `Found 0 files`. Collapsed = one row + expand; verbose indents the body by 5. Errors `File not found`, `Error searching files` | R | A GUI can exceed: clickable file paths, grouped by directory, inline previews. |
| `Read` | Six forms: `Read <bold N> line(s)`, `Read image (<size>)`, `Read PDF (<size>)`, `Read <bold N> page(s) (<size>)`, `Read <bold N> cells` / `No cells found in notebook`, `Already in context (<path>)` / `Unchanged since last read`. Errors `File not found`, `Error reading file`. Header appends ` · pages N` or ` · lines A-B` | R | — |
| `Edit` | `Added <bold N> lines` / `Removed <bold N> lines`, capitalisation trick (`Added 5 lines, removed 3 lines`). Rejection: `User rejected update to <bold path>` in `subtle` | R | The structured patch is in `tool_use_result`; see §41.16.8. |
| `Write` | `Wrote <bold N> <unit> to <bold path>`, optional ` — previous content replaced (no diff shown)`, 10-line syntax-highlighted preview, overflow affordance | R | — |
| `Bash` | Command header truncated to 2 lines / 160 chars; `Running…` in flight, `Waiting…` queued; result ends in `Running in the background (↓ to manage)`, `Done`, or `(No output)`; `[Image data detected and sent to Claude]` for image output; live progress `Running… ` + elapsed + last 5 lines, footed `+N lines` / `~N lines`; badge `(timeout 2m)` / `(12s · timeout 2m)` / `(12s)` | R (live progress: **D** in general) | Verified live: the Bash `tool_use_result` carries `stdout`, `stderr`, `interrupted`, `isImage`, `noOutputExpected`, `backgroundTaskId`. **But `tool_progress` frames — the live streaming stdout — are emitted only when `CLAUDE_CODE_REMOTE` or `CLAUDE_CODE_CONTAINER_ID` is set** (heartbeats and subagent retries always). Without setting one of those env vars a GUI cannot show the TUI's live "last 5 lines while running"; it gets the output only at completion. Workaround: launch the CLI with `CLAUDE_CODE_REMOTE` set, or accept a completion-only view. |
| `Agent` | `Done (7 tool uses · 41.2k tokens · 3m 12s)`; cloud launch line with task id + session URL; `Backgrounded agent (↓ to manage, ctrl+o to expand)`; progress `Initializing…`, collapsed one-liner `In progress… · <bold N> tool uses · <tok>`, else last three sub-messages + overflow; grouped agents render a header + one tree row per agent with `⎿` status `Initializing…` / `Running in the background` / `Done` | R | With `--forward-subagent-text` the sub-messages are on the wire (text + thinking, `parent_tool_use_id` set) plus `task_*` frames. A GUI **exceeds**: full expandable subagent transcripts instead of the last three lines. |
| `WebFetch` | `Received <bold size> (<status>)`; progress `Fetching…` | R | — |
| `WebSearch` | `Did <n> search(es) in <duration>`; progress `Searching: <query>`, `Found <n> results for "<query>"` | R | — |
| `ExitPlanMode` | `Exited plan mode` / `Plan submitted for team lead approval` / `User approved Claude's plan`, plus `Plan saved to: <path> · /plan to edit`; rejection `User rejected Claude's plan:` in a round box coloured `planMode` | P | `ExitPlanMode` arrives as a `can_use_tool` request, so the host renders the approval UI itself and controls the copy; `get_plan` control request fetches the plan. |
| `EnterPlanMode` | `Entered plan mode` + explanatory line | R | — |
| `AskUserQuestion` (rejected) | `User declined to answer questions`, then one line per question | P | `AskUserQuestion` arrives via `can_use_tool` — the GUI owns the whole question UI and can far exceed the terminal (radio groups, multi-select, free text). |
| `LSP` | `Found <bold N> definitions across <bold M> files`; `Hover info available`; error `LSP operation failed` | R | — |
| `Skill` | `Successfully loaded skill · N tools allowed · <model>` | R | — |
| `TaskOutput` | `Read output (ctrl+o to expand)`, `Task is still running…`, `Task not ready`, `No task output available` | R | — |
| `TaskStop` | `<command>… · stopped` | R | `stop_task` control request is the host-side stop; declare `perTaskStopAffordance: true` in `initialize` or an interrupt kills background tasks (afleet's probe already declares it). |
| `EnterWorktree` / `ExitWorktree` | `Switched to worktree on branch <bold b>` + dim path; `Kept worktree` / `Removed worktree (branch <bold b>)` then `Returned to <cwd>` | R | — |
| `Monitor` | `Monitor started · task <id> · persistent` or `· timeout Ns` | R | — |
| `CronCreate` / `CronDelete` / `CronList` | `Scheduled <bold id> (<schedule>)`; `Cancelled <bold id>`; `No scheduled jobs` else one row per job with `(recurring)` / `(one-shot)` / `[session-only]` | R | — |
| `RemoteTrigger` | `HTTP <status> (<N> lines)` | R | — |
| `ListMcpResourcesTool` / `ReadMcpResourceDirTool` / `ReadMcpResourceTool` | `(No resources found)` else pretty JSON; `(Empty directory)`; `(No content)` | R | — |
| generic MCP | `[Image]` per image block; `(No content)`; an oversize warning | R | A GUI can show MCP images inline — see §41.17.9. |
| MCP progress | `Running…`, `Processing… <n>`, or a 20-column bar + percentage | D | MCP progress notifications reach the host only if it is the MCP transport (`mcp_message` both directions); otherwise the CLI-hosted server's progress is not on the wire. A GUI hosting SDK MCP servers gets it; for CLI-configured servers, no. |
| `PushNotification` | Four branches incl. `Terminal and mobile notification sent.` | R | See §41.20.6 for the refusal strings. |
| `NotebookEdit` | `Updated cell <bold n>:` + highlighted code at `marginLeft: 2` | R | — |
| `memory_write` | Header + 10 lines capped at 200 chars each, then `… +N more lines` | R | — |
| plugin/skill list tools | `<count> <noun\|nouns>` | R | — |
| `claude-in-chrome` family | 18 verbs → one dim line each (`Navigation completed`, `Tab created`, `Tabs read`, `Input completed`, `Action completed`, `Window resized`, `Search completed`, `GIF action completed`, `Console messages retrieved`, `Network requests retrieved`, `Shortcuts retrieved`, `Shortcut executed`, `Script executed`, `Page read`, `Image uploaded`, `Page text retrieved`, `Plan updated`); the tag adds a `[View Tab]` hyperlink | R | The `[View Tab]` link is a real affordance — a GUI should keep it as a button. |
| `computer-use` family | 14-verb map; **suppressed entirely in verbose mode** | R | Note the inversion: verbose *hides* these. |
| `TodoWrite` | **Absent from the renderer table**; `userFacingName` is empty and `renderToolUseMessage` returns `null`. Todos surface only in the diff-sidebar progress bar and the tasks panel | R | Clear opportunity: a GUI showing a live todo list from `TodoWrite` inputs strictly **exceeds** the TUI. |
| `Waiting for permission…` | Replaces the result body while a permission prompt is open | P | Directly derivable: the host itself is holding the `can_use_tool` request. |

### 41.16.8 Diffs

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| **Unified only — no side-by-side renderer exists** | Two unified renderers (ANSI-highlighted and Ink), row shape `<space><padded line no><space><marker><code><right pad>`, gutter width = digits of the max line number + 3, gutter `noSelect` | The structured patch (`structuredPatch`: `{oldStart, oldLines, newStart, newLines, lines}`) is in `tool_use_result` for Edit/Write; `get_workspace_diff` for the workspace | R | A GUI **exceeds** the TUI outright by offering side-by-side. |
| Line-numbering discrepancy between the two renderers | ANSI path uses true unified semantics (context takes the new numbering); the Ink path rewinds the counter after a removed run so paired `-`/`+` share a number | — | R | Pick the ANSI/unified semantics; the Ink behaviour is the odd one. |
| Six theme keys, unchanged lines dimmed with no background, removed lines rendered **without** syntax highlighting | §41.16.8 | — | R | Copy the palette (§41.10.3) for continuity; a GUI can highlight removed lines too, which is better. |
| Word-level diffing, bailing out above 40 % line divergence and always when dimmed | §41.16.8 | — | R | The 40 % bail-out is a good heuristic to copy — beyond it word diff is noise. |
| Four truncations: 2000 chars/line (` … [+N chars]`), 400 hunk lines/file in the sidebar (`… diff truncated (exceeded 400 line limit)`), a dim `...` between hunks, and the 3-line collapsed tool result | §41.16.8 | — | R | A GUI should raise these limits, not copy them. |
| Context = 3 lines; no hunk-collapse mechanic | §41.16.8 | — | R | Expandable context is a GUI win. |

### 41.16.9 The diff sidebar

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Mount gate: feature flag + fullscreen + main focus + ≥110 columns + a git repo; auto-open needs 144 columns the first time, 110 thereafter; width `min(floor(cols × 0.45), 90, cols − 70)` | §41.16.9 | — | T | Width gates vanish in a GUI. |
| Header `<bold N> files changed +A −R` with a `✕` close control, plus a todo progress bar when todos exist | §41.16.9 | `get_workspace_diff` control request returns the diff; `vcs_state_changed` frames signal changes | R | The todo progress bar is derived from `TodoWrite` inputs — host-side. |
| Empty states `No uncommitted changes`, `No changes this session`, `No commits yet`, `Diff unavailable`, and the no-repo message `The diff panel shows git changes — the current directory isn't in a git repository` | §41.16.9 | — | R | Copy the four distinct empty states; they are informative. |
| Base cycling session → uncommitted → branch (`app:cycleDiffBase`), toggle via `/diff` or `app:toggleReplTab` | §41.16.9 | `/diff` refused headless (live); `get_workspace_diff` presumably parameterised by base | R | **Unverified:** whether `get_workspace_diff` accepts a base selector. |
| `diffTool` setting (global config, not `settings.json`, default `auto`) gating Edit/Write previews into the IDE's native diff tab | §41.16.9 | Not in the headless `/config` key list; readable only from the global config file | R | A GUI that is the editor supersedes this; note the setting lives in `~/.claude.json`, not `settings.json`, so `update_settings` cannot write it. |

### 41.16.10 Interruption and rejection

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| **No strikethrough in message chrome** — rejection is `subtle` + dim (the only strikethrough in the bundle is a completed task-board subject) | §41.16.10 | — | R | Deliberate; a GUI should also avoid strikethrough for rejections (it reads as "deleted", not "declined"). |
| `Interrupted` / `Interrupted · What should Claude do instead?` | §41.16.10 | `interrupt` control request is host-initiated; the resulting `result` frame is `error_*`; the transcript sentinels (`[Request interrupted by user]`) belong to ch. 11 and do arrive as message content | P | — |
| Per-tool rejection renderers (`User rejected update to <path>`, `User rejected Claude's plan:`, `User declined to answer questions`) | §41.16.7 | The host itself issued the denial via `can_use_tool`; `permission_denied` advisory frames also exist | P | The GUI knows exactly what it denied and can render better provenance than the TUI. |

### 41.16.11 Rate-limit auto-continue rendering

Six surfaces, and **there is no `Claude usage limit reached` literal** — the family is
`Usage limit reached · …`.

| Feature | TUI behaviour (SPEC §41.16.11) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Pinned notice (pinned, `high` priority, rendered `⚠ <text>`) | `Your usage limit has reset · press enter to continue`; `Usage limit reached · continuing shortly · esc to cancel`; `Usage limit reached · continuing automatically at <time> · esc to cancel`; `… when it resets · esc to cancel` | `rate_limit_event` frames carry `rate_limit_info` whenever it changes; `get_usage` returns `{session, subscription_type, rate_limits_available, rate_limits, behaviors}` (verified live) | R | All the state is obtainable; every string and the pinned/transient placement is a rebuild. `behaviors` in `get_usage` is the likely home of the auto-continue policy — **unverified**. |
| Transcript notices | `Usage limit reached · continuing automatically <when> · esc or type to cancel`; `Usage limit reached again after you continued · … · the automatic-continue setting no longer ends this wait (esc or /rate-limit-options still can)`; event rows `Usage limit available again · continuing now`, `Usage limit has reset · press enter to continue`, `Automatic continue was turned off · …`, `Automatic continue stopped …`, `Usage limit reset · continuing automatically` | Same as above | R | The second string encodes a real policy subtlety (a second limit hit ignores the setting) that a GUI must not lose. |
| Inline block under the rate-limit message | `Continuing shortly · esc to cancel`; `Continuing automatically at <time> · esc to cancel`; `Continuing automatically when your limit resets · esc to cancel`; `Press ⏎ to continue after reset`. Headline coloured `error` (or `warning` for spend limits) | Chosen by prefix-matching the assistant message; the same message text is on the wire | R | The prefix match is the trigger a GUI must replicate, or the block never appears. |
| Spinner retry row headlines | Limit vocabulary: `five_hour` → `session limit`, `seven_day` → `weekly limit`, `seven_day_opus` → `Opus limit`, `seven_day_sonnet` → `Sonnet limit`, `seven_day_overage_included` → `Fable limit`, `overage` → `usage credit limit` | `api_retry` frames + `rate_limit_event` | R | Copy the vocabulary table — the labels are user-facing plan language. |
| Approaching-limit strings | `You've used <N>% of your <limit> · resets <time>`; `Approaching <limit> · resets <time>` | `get_usage` / `rate_limit_event` | R | — |
| Formatting | Countdown collapses to one unit above five minutes; reset clock is 12-hour, minutes suppressed on the hour, meridiem lower-cased (`3pm`, `3:45pm`), dated form beyond 24 hours | §41.16.11 | R | Honour `timeFormat` (`auto`/`12-hour`/`24-hour`/`24-hour-utc`, headless-settable) — the TUI's clock respects it. |
| Cancellation gestures + toast | `chat:cancel` (esc), `app:interrupt` (ctrl+c), `chat:killAgents` each cancel and raise an 8 s toast `Automatic continue cancelled · /rate-limit-options to re-arm` | `interrupt` control request | R | The re-arm path is `/rate-limit-options`, a `local-jsx` panel — **unreachable headless (X)**. A GUI must expose the underlying setting (`autoContinueAtUsageLimit`, default true) itself, and note it is **not** in the headless `/config` key list, so it must be written to `settings.json` on disk or through `update_settings` (localSettings). |
| Ticking | **Only the spinner row ticks**; pinned and inline rows re-render on a 30-second poll | §41.16.11 | R | A GUI can tick everything smoothly. |

### 41.16.12 Static commitment

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Four cooperating "static" layers (terminal scrollback, the React `isStatic` memo predicate, the element-tree commit cursors, cell-level blitting); there is **no Ink `<Static>`** | §41.16.12 | — | T | Pure renderer mechanics — but with one user-visible consequence: once a message scrolls into terminal scrollback it can never be restyled, re-wrapped or re-searched. A GUI keeps everything live, which is a genuine capability the terminal cannot match (re-flow on resize, retroactive search, retroactive theme change). |
| `isStatic` rules (a collapsed read/search block is never static; a tool use becomes static only when not streaming, not in progress, no outstanding `PostToolUse` hook, and every sibling tool-use id is resolved) | §41.16.12 | `hook_started`/`hook_response` frames with `--include-hook-events` tell the host when `PostToolUse` is outstanding | R | Useful as a memoisation rule for a GUI too. |
| Repaint triggers: `/clear` (new conversation id → full remount), rewind/compact (conversation-id bump), `ctrl+l`/`cmd+k`, `app:redraw`, resize, a write to stderr, an external `clear` | §41.16.12, §41.5.6 | `conversation_reset` frames (`/clear`, plan-mode exit) and `compact_boundary` frames are on the wire | P | A GUI should treat `conversation_reset` and `compact_boundary` as the transcript-boundary markers the TUI treats them as, including inserting a visible divider at `compact_boundary`. |
| Non-TTY degradation (whole frame as plain text once per changed frame) | §41.16.12 | — | T | — |

---

## 41.17 Markdown, code highlighting, mermaid and images

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Markdown engine configuration | Vendored `marked`, GFM **on**, `breaks` **off** (a single newline inside a paragraph is not a line break) | Assistant text arrives as raw markdown in `assistant` text blocks and `stream_event` deltas | R | A GUI must match `breaks: false` or every model paragraph gains spurious line breaks. |
| Three tokenizer overrides | `del`: only `~~x~~`, single-tilde is not strikethrough. `def`: **link reference definitions disabled entirely**, so `[text][id]` renders literally. `table`: escapes `\|` inside backticks, bails to a paragraph if any row has more cells than the header | — | R | All three are deliberate and must be copied or the GUI renders text the model did not intend. |
| Prompt-mode markdown instance | Additionally disables `table`, `blockquote`, `hr`, `lheading`, `link`, `autolink`, `url`, `escape`, `br`, and underscore emphasis (asterisk emphasis kept) | — | R | This is what makes typed user input render sanely in the composer; a GUI composer with live preview needs the same restricted grammar. |
| Token → terminal table (headings bold/underline with **no `#` prefix and no colour**; `codespan` in the `permission` colour with **no backticks and no background**; fenced `code` with **no fence, no border, no indent**; `blockquote` prefixed `▎` and italic; `hr` = literal `---`, not a full-width rule; `html` = **raw passthrough, unescaped and unsanitised**) | §41.17.2 | — | R | Two rows matter for a GUI: (a) raw `html` passthrough is a rendering-injection hazard the GUI must **not** copy — sanitise or escape; (b) the TUI's plain heading/codespan/fence styling is the terminal's limit, and a GUI can and should do better (real code blocks with copy buttons, real rules, real heading hierarchy). |
| Strikethrough capability gate | Allow-list of nine terminals + `CLAUDE_CODE_FORCE_STRIKETHROUGH`; Apple Terminal and `TERM=linux` excluded; otherwise the literal `~~…~~` is shown | §41.17.2 | T | A GUI always supports it — a small, real improvement. |
| Lists | **Unordered bullets are always ASCII `-` at every depth.** Ordered markers cycle by depth: decimal → lowercase letters → lowercase Roman → decimal. Continuation indent = parent + marker width + 1, capped at 32 columns. A post-pass glues `N.` to the preceding word with U+00A0 so a wrap cannot strand a number where it would read as a marker. Ink list components only under a 300-node / 64-depth budget (§41.17.3) | — | R | The `-`-at-every-depth choice is a terminal limitation; a GUI should use proper nested bullet glyphs. The U+00A0 glue trick is worth knowing but unnecessary with real layout. |
| Tables | Two renderers by nesting, not configuration: box-drawing Ink tables at top level (min column width 3, max 4 wrapped lines per row, max 200 rows, 5-step width algorithm) and ASCII pipes for nested tables and the string API; fallback to a **vertical key/value layout** with a `─` rule of `min(width−1, 40)` when rows need >4 wrapped lines or the box exceeds `width − 4`; truncation footer `… <N> more rows not shown`; header cells force-centred, body cells honour markdown alignment (§41.17.4) | — | R | A GUI **exceeds**: real tables with column resizing and no 200-row cap. The vertical fallback is still worth keeping for narrow windows. |
| Links | OSC 8 with `chalk.blue`/`blueBright` by theme; `mailto:` strips the scheme; markdown titles appended as ` ("title")`; Claude artifact/frame URLs prefixed `⧉`; bare `owner/repo#123` auto-linked with a forge allow-list (`gitlab.com`, `bitbucket.org`, `codeberg.org`, `gitea.com`, `git.sr.ht`, `dev.azure.com`); a post-pass appends ` (url)` where a label alone is ambiguous (§41.17.5) | — | R | The `owner/repo#123` autolink and the artifact `⧉` prefix are real affordances to copy. The ` (url)` disambiguation post-pass becomes unnecessary if the GUI shows link targets on hover. |
| Syntax highlighting A (highlight.js → 16-colour chalk, 34-entry scope map, dotted-scope right-to-left fallback) | Used for fenced code in assistant markdown; 180 grammars lazily registered plus a non-upstream **Cedar** grammar (alias `cedarpolicy`); plugins may register more, ≤16 aliases each, never shadowing a built-in | — | R | A GUI uses its own highlighter but should keep the alias table (`sh`/`zsh` → bash, `ts`/`tsx` → typescript, `html`/`svg`/`plist` → xml, `toml` → ini) and the Cedar grammar, or plugin-authored and policy code loses colour. |
| Unknown-language behaviour | Markdown fences: skip highlighting and print the language name **dimmed on its own line**, then raw text. The code-block component instead falls back to `markdown` and logs | §41.17.6 | R | Note this is exactly how a ` ```mermaid ` fence renders. |
| Syntax highlighting B (true-colour code/diff renderer) | File previews, notebook cells, diffs; palette by theme name; filename-driven language detection (basename map `Dockerfile`/`Makefile`/`Rakefile`/`Gemfile`/`CMakeLists`, then extension, then shebang / `<?php` / `<?xml`); lines clamped at 2000 chars with ` … [+N chars]`; tabs expand to 8-column stops | §41.17.6 | R | Copy the filename→language detection; it is what makes extension-less files highlight. |
| Highlighting gates | `syntaxHighlightingDisabled` setting nulls highlighter A everywhere; `CLAUDE_CODE_SYNTAX_HIGHLIGHT` falsy disables highlighter B only; the theme picker reports which reason applies | §41.17.6 | R | Honour `syntaxHighlightingDisabled` from `get_settings`; it is an accessibility choice for some users. |
| Line-number gutter | Leading space, right-aligned number, trailing space; blank gutter on wrapped continuation rows; dim via `ESC[2m` for context lines; diff lines prepend the raw `+`/`-`/space column; gutter suppressed entirely when the block starts at line 1 **and** accessibility mode is off | §41.17.7 | R | Copy the "suppress for line-1 blocks unless accessibility mode" rule — it is why short snippets look clean but remain navigable for screen-reader users. |
| **Mermaid is never drawn in the terminal** | A ` ```mermaid ` fence takes the unsupported-language path: a dimmed `mermaid` label line then the raw diagram source. The only mermaid transform in the bundle is markdown → HTML for the **artifact publisher**, rendered by mermaid.js 11.16.1 **in a browser**, served over HTTP from the artifact host (§41.17.8) | The fence arrives as ordinary markdown text | R → **GUI exceeds** | This is one of the clearest places a GUI beats the terminal: bundle a mermaid renderer and draw the diagram inline. The binary already proves the intent (it renders mermaid for published artifacts) and pins a version, 11.16.1, worth matching for fidelity. Same for the `hljsBundle` and `chart-runtime` payloads it inlines into artifacts. |
| **Inline images are never drawn** | No `1337;File=` (iTerm2), no kitty graphics, no Sixel producer anywhere in the bundle; the only OSC 1337 use sets a profile property. There is no `imageDisplay` / `inlineImages` setting. Images render as `[Image #N]` / `[Image]`, wrapped in an OSC 8 `file://` link when the path resolves and hyperlinks are supported, with any stored description dimmed after it. Attached files render as `▸ [image] <path> (<size>)` / `▸ [file] …` (§41.17.9) | Image content blocks are on the wire in both directions (stdin `user` frames accept image blocks; MCP results carry image blocks) | P → **GUI exceeds** | The single biggest visual gap in the chapter. A GUI can display pasted screenshots, MCP-returned images, Read-tool images and Bash image output inline, where the terminal shows only `[Image #N]`. Keep the placeholder grammar for round-tripping composer text (next row). |
| Placeholder grammar | `/\[(?:Pasted text #\d+( \+\d+ lines)?\|Image #\d+\|Audio #\d+\|\.\.\.Truncated text #\d+ \+\d+ lines\.\.\.)\]/g` | — | R | A GUI must recognise the same shapes when re-expanding composer text, and must treat them as atomic tokens for cursor motion, word-delete and selection (§41.24.1). |
| Streaming markdown | Frozen prefix + live re-lexed tail, 4096-char chunks; when a split falls inside an open fence the fence's opening line is re-prepended so the fragment still lexes as code; split prefers the last newline, then the last space within 1536 chars, never splits a surrogate pair (§41.17.11) | `stream_event` deltas arrive with `--include-partial-messages` | R | The open-fence re-prepend is the non-obvious rule: without it, streaming code blocks flicker between "code" and "prose" mid-stream. Copy it. |
| Width/wrapping utilities | `Bun.stringWidth` with `ambiguousIsNarrow: true`; grapheme segmentation via `Intl.Segmenter`; SGR re-open fixup after each inserted newline (§41.17.10) | — | T | `ambiguousIsNarrow: true` is a real choice affecting CJK/emoji layout; a GUI's text engine decides this itself. |

## 41.18 The spinner and spinner tips

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Spinner glyph animation | Six glyphs `· ✢ ✳ ✶ ✻ ✽` (ghostty variant substitutes `✻` for `✽`), mirrored into twelve, cosine-eased so it ping-pongs and dwells at the ends; 2000 ms period; render tick 100 ms, 50 ms while `mode === "requesting"` | Nothing on the wire; the host knows a turn is running from `system/status`, `session_state_changed` and the absence of a `result` | R | A GUI uses its own indeterminate indicator. The one thing to copy is the *mode* distinction: `requesting` (uploading the request) vs streaming — the TUI signals it by ticking faster and flipping the token arrow from `↓` to `↑`. |
| Spinner row composition | Glyph → message (gerund + `…`, with a 3-character travelling shimmer) → suffix group in parentheses joined by ` · ` in fixed order: stop-hook `spinnerSuffix`, elapsed timer, token counter, thinking/tool status → optional compaction gauge on a second row when ≥8 columns remain (§41.18.4) | Elapsed is host-measurable; `thinking_tokens` frames carry thinking-token accounting; `system/status` gives `compacting`; `compact_progress` is **dropped** before the wire | R (compaction gauge: **D**) | The compaction progress gauge has no wire source (`compact_progress` is filtered out, and `autocompact_state` is `CLAUDE_CODE_REMOTE`-only). A GUI can only show an indeterminate "Compacting…" from `system/status`, unless it runs the CLI with `CLAUDE_CODE_REMOTE` set. |
| Message priority chain | `overrideMessage ?? activeTask.activeForm ?? activeTask.subject ?? (store.defaultVerb \|\| locallySampledVerb)`, always suffixed `…` | Task subjects/active forms arrive via `task_started`/`task_updated`; plugin overrides and stop-hook suffixes are local | R | Showing the current task's `activeForm` instead of a random verb is the most informative part and is on the wire. |
| Elapsed timer | `0s`, `N.Ns` under a second, `Ns` under a minute, then `Nm Ns`, `Nh Nm Ns`, `Nd Nh Nm`; accumulated paused time subtracted (§41.18.4) | Host-measurable | R | Also gates `showTurnDuration` (default true), headless-settable via `/config turnDuration=`. |
| Token counter | **Response characters ÷ 4**, animated toward the true value rather than jumping; `Intl.NumberFormat` compact, lowercased (`842`, `1.2k`, `15.0k`); prefixed `↓`, or `↑` in `requesting` mode (§41.18.4) | With `--include-partial-messages` the host can count streamed characters exactly, and `stream_event` `message_delta` carries real usage | R → **GUI exceeds** | The TUI's counter is an estimate; a GUI reading `message_delta.usage` can show the true output-token count. |
| Thinking label escalation | `thinking` → `still thinking` (10 s) → `thinking more` (20 s) → `thinking some more` (30 s) → `almost done thinking` (45 s); tool branch `running tool for <d>` / `ran tool for <d>` / `thought for <n>s` (§41.18.4) | Thinking blocks and `thinking_tokens` are on the wire; the durations are host-measurable | R | Cheap to copy and genuinely reassuring during long thinking. |
| Retry and stall variants | `stalled` → `Waiting for API response` + a network-check suffix; `low_priority_waiting` → the formatted error + ` · next try in <d> · attempt <N> · esc to interrupt`; default → `API error` / a rate-limit headline / the formatted error, plus retry countdown and `attempt N/M`. Stall thresholds 10 s / 45 s / 300 s (§41.18.5) | `api_retry` frames are on the wire; `rate_limit_event` supplies the rate-limit headline | P → R | The frames exist; the escalation copy is a rebuild. A GUI showing nothing during a 45-second stall will feel broken — this is a real parity requirement, not decoration. |
| The 186-verb gerund list | One array literal (`Accomplishing` … `Zigzagging`, incl. `Flambéing`, `Sautéing`, `Clauding`); sampled **once per turn**, stored as `defaultVerb`, re-rolled at each turn boundary; **no seasonal variant and no switch to disable it** (§41.18.6) | Not on the wire | R | Pure personality. A GUI that drops it loses a signature piece of the product's character; the list is reproduced verbatim in the spec so copying is trivial. |
| `spinnerVerbs` setting `{ mode: "append" \| "replace", verbs }` | Replaces or extends the list (replace with an empty array falls back to the default) | Readable from settings on disk / `get_settings` | R | Honour it, or a user's customisation silently disappears in the GUI. |
| Tip line (third line of the spinner block), rendered `<label>: <content>`, label `Tip` unless an org override supplies one | 70-entry registry + a dynamic `marketplace-plugin:<name>` family; each entry has `cooldownSessions` (measured in **CLI startups**, not wall clock), optional `priority`, `maxLifetimeShows`, `advertisedCommand`, `providerAgnostic`, `isRelevant` | Not on the wire | R (with a real data dependency) | Full registry, cooldowns and lifetime caps are in the spec. State lives in `~/.claude.json` as `tipsHistory`, `tipLifetimeShownCounts` and `numStartups` — **readable and writable from disk**, so a GUI can participate in the same cadence rather than re-showing tips the user has already seen in the terminal. That shared-state detail is easy to miss and is what makes GUI/terminal tips feel coherent. |
| Tip eligibility and ranking | Filters: previously-throwing `isRelevant`, non-first-party inference keeps only `providerAgnostic` tips, unavailable `advertisedCommand`, `isRelevant`, cooldown, lifetime cap, then org tips appended (`excludeDefault` returns org tips only). Ranking is **deterministic**: sessions-since-last-shown descending (never shown = ∞), tiebreak `priority` descending (§41.18.9) | — | R | Note `advertisedCommand` filtering: in a GUI many advertised commands (`/theme`, `/copy`, `/terminal-setup`, `/tui`) do not exist, so those tips must be dropped or rewritten — otherwise the GUI advertises commands it refuses. |
| Cadence and pre-emption | One tip per turn, chosen at the turn boundary. Two time-based replacements pre-empt the slot: after 30 minutes in a single turn, `Use /clear to start fresh when switching topics and free up context`; after 30 seconds, if the user has never used `/btw`, `Use /btw to ask a quick side question without interrupting Claude's current work`. Sub-line priority: narration → `Next: <task subject>` → `<label>: <tip>` (§41.18.10) | `task_*` frames give `Next: <subject>` | R | The `Next: <task subject>` sub-line is the most useful of the three and is fully on the wire. |
| `spinnerTipsEnabled` setting | Short-circuits the whole tip system | `/config tips=true\|false` works headless | R | — |
| `spinnerTipsOverride` (organisation tips) | ≤500 chars/tip, ≤200 tips, ≤256 KiB file, label ≤40 chars (default `Tip`), id `/^[A-Za-z0-9._-]{1,64}$/`, trusted sources `policySettings`/`flagSettings`/`userSettings`, `cooldownSessions` clamped 0…1000, `priority` clamped −10…10; project scope may contribute plain strings only; text sanitised of control/format chars (§41.18.11) | Readable from the settings cascade | R | Enterprise-relevant: a managed deployment's tips must still appear in the GUI or admins lose a comms channel. |
| Feature-of-the-week campaign | Dated dynamic config supplying its own texts, `titleLabel` (default `Feature of the week:`), `tipBlurb` and `command`; `null` outside its window; gate `tengu_lilac_loom` (§41.18.11) | Not on the wire | D | A GUI cannot fetch the campaign payload through the headless protocol; it would need the same dynamic-config channel. Low stakes. |
| Reduced motion | `prefersReducedMotion` setting, or gate `tengu_cedar_marsh` in VS Code-family/xterm.js hosts. Effects: every interval becomes `null` (no re-render loop), the glyph becomes a static `●` cross-faded on the same 2000 ms cosine, frame index pinned to 0, shimmer parked at −100, the brief spinner uses a static `"…  "`. The streaming-text animation is also suppressed under reduced motion **and under Windows Terminal regardless** (§41.18.3) | `/config reduceMotion=true\|false` works headless; readable from settings | R | An accessibility requirement, not a preference. A GUI must read `prefersReducedMotion` **and** the OS-level reduce-motion setting, and suppress spinner animation, shimmer, the sprite, the animated title prefix and streaming text animation. |
| Brief spinner (`CLAUDE_CODE_BRIEF` / gate `tengu_kairos_brief`) | Dot tick 120 ms advancing every 300 ms | §41.18.2, §41.23.5 | T | See §41.23.5. |

## 41.19 The `statusLine` command protocol

This is the single highest-fidelity parity item in the chapter: users have existing scripts, and a
GUI that wants to run them unchanged must reproduce the payload exactly.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Settings shape `{ type: "command", command, padding?, refreshInterval?, hideVimModeIndicator? }` | `type: "command"` is the only literal; **no `timeout` field and no `type: "static"`**; policy tier can substitute its own value in safe mode / managed-hooks-only | `get_settings` returns it (live: `{"type":"command","command":"bash /Users/new/.claude/statusline-command.sh"}`) | P | The setting is fully readable; the GUI decides whether to execute it. |
| Executing the command | The CLI runs it as a hook (`StatusLine` event, hook name `statusLine`) via bash (PowerShell on Windows without Git Bash); env = credential-scrubbed `process.env` plus `CLAUDECODE=1`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION=1`, `CLAUDE_PID`, `CLAUDE_PROJECT_DIR`, `COLUMNS`, `LINES`; cwd = payload `cwd` with fallbacks; stdin = the JSON + newline then `end()`; effective hard timeout **600 s** (no `timeout` in the schema), bounded in practice by the AbortController | **Nothing runs it headless.** The component mounts only when `screen === "prompt"`, no exit message is showing and a setting resolves — none of which exists headless | R | The GUI must spawn the command itself with the same shell, env and cwd rules. Note `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID`: scripts use them, and the GUI must supply the CLI child's pid and the session id from `initialize`/`system.init`. |
| The payload — documented schema | The `statusline-setup` agent's system prompt is the definitive user-facing contract: `session_id`, `session_name?`, `prompt_id?`, `transcript_path`, `cwd`, `model{id,display_name}`, `workspace{current_dir,project_dir,added_dirs,git_worktree?,repo{host,owner,name}?}`, `version`, `output_style{name}`, `context_window{total_input_tokens,total_output_tokens,context_window_size,current_usage\|null,used_percentage,remaining_percentage}`, `effort{level}?`, `thinking{enabled}`, `rate_limits{five_hour?,seven_day?,spend_limit?}`, `vim{mode}?`, `agent{name,type}?`, `pr{number,url,review_state?,kind?}?`, `worktree{name,path,branch?,original_cwd,original_branch?}?` | See per-field analysis below | R/D | — |
| The payload — real producer | Adds seven **undocumented** groups: `agent_type` (top level — the real home of what the docs call `agent.type`, which is **never emitted**), `scratchpad_dir`, `cost{total_cost_usd,total_duration_ms,total_api_duration_ms,total_lines_added,total_lines_removed}`, `exceeds_200k_tokens`, `prompt_cache{12 fields}`, `fast_mode`, `remote{session_id}`. No `hook_event_name` | — | R/D | A GUI aiming for script parity must emit the undocumented fields too: real scripts read `cost.total_cost_usd` and `fast_mode`. |
| Payload field sourcing for a GUI | — | `session_id`, `model`, `version` (`get_binary_version` → `{version, buildTime}`), `output_style` (`initialize.output_style`), `agent` (`initialize.agents`, `--agent`), `effort` (`initialize`/`applied.effort`, live `"xhigh"`), `thinking` (`set_max_thinking_tokens` state / `thinking_tokens`), `context_window` (**`get_context_usage`** → `totalTokens`, `maxTokens`, `percentage`), `rate_limits` (**`get_usage`** → `rate_limits`, live present, plus `rate_limit_event` pushes), `cwd`/`workspace` (host-owned; `set_cwd`, `add_directory`), `transcript_path` (host knows the session dir), `vim` (host-owned), `worktree` (host-owned), `session_name` (`rename_session`, `generate_session_title`) | R | Most of the payload is reconstructible from control requests the host already has. |
| Payload fields with **no** wire source | `cost` (`get_session_cost` returns only a rendered `text` blob — verified live: response is `{"text": ...}`), `prompt_cache` (all 12 fields), `exceeds_200k_tokens`, `pr` (the GitHub/GitLab PR badge), `scratchpad_dir`, `prompt_id` | — | **D** | Workarounds: compute `cost` by parsing `get_session_cost.text` (fragile) or by summing `stream_event` usage against model pricing; compute `pr` with the GitHub/GitLab CLI or API from the current branch; derive `exceeds_200k_tokens` from `get_context_usage.totalTokens > 200000`; omit `prompt_cache` and `scratchpad_dir` and accept that scripts reading them get `null`. `prompt_id` has no substitute. |
| Refresh cadence | First subscribe = immediate run + arm timer. Refresh on any of eight inputs (`tokenUsage`, `permissionMode`, `vimMode`, `mainLoopModel`, `fastMode`, `effortValue`, `thinkingEnabled`, `prStatus`) **or a new assistant message**, debounced 300 ms. Command-text change = immediate un-debounced run. Periodic timer only when `refreshInterval` is set (minimum 1 s), itself debounced. One-shot reset-deadline timer at the soonest rate-limit / prompt-cache expiry + 1000 ms. Every run aborts the in-flight one — a slow command is cancelled, not queued. Last text cached per session so a remount shows the previous value immediately. **Nothing in the render path runs the command** (§41.19.5) | — | R | Copy the abort-not-queue rule; without it a slow status script backs up and the footer lags minutes behind. |
| Rendering | Mounted above the hint row. `padding` is horizontal only. Each output line is its own `Text` with `dimColor` and `wrap: "truncate"` — nothing wraps, each line truncates independently. Output goes through a real **ANSI parser**, not a stripper: colours, backgrounds, dim, bold, italic, underline, strikethrough, inverse **and OSC 8 hyperlinks all survive**; the outer `dimColor` is forced onto every span. Because each line is an independent `Text`, a fix-up re-prefixes each line with the accumulated SGR of all preceding lines. **No spinner, no placeholder**: before the first result the row is empty (a single space in fullscreen reserves it); a slow command keeps showing the previous text; failure or empty output collapses the row silently (§41.19.6) | — | R | A GUI must implement a real ANSI-to-styled-text parser for status output, including OSC 8, and must reproduce the cross-line SGR carry-over or multi-line coloured status lines lose their colour after line 1. |
| Output handling | Whole stdout trimmed, split on newlines, each line trimmed, **empty lines dropped entirely**, rejoined. No line cap and no character truncation in the executor. ANSI not stripped. Empty output → clears the row. **stderr is never displayed** — debug log only. Failures classified once per host (`spawn_failed`, `timeout`, `nonzero_exit`, `exec_error`) (§41.19.4) | — | R | A GUI can **exceed**: surface status-line failures to the user instead of silently blanking the row, which is a genuine debugging pain point today. |
| Gating | Returns immediately on `disableAllHooks` (policy), when the `statusLine` feature is disabled for the mode, or when workspace trust is not accepted; two warn-level diagnostics at mount (`Status line is configured but disableAllHooks is true`, `Status line command skipped: workspace trust not accepted`) | §41.19.4, §41.19.6 | R | The trust gate matters: a GUI must not execute a repo-adjacent status command in an untrusted workspace. |
| Side effect on the footer | Configuring a status line sets `suppressHint`, which turns **off** the classic-layout `? for shortcuts` and `esc to interrupt` hints | §41.19.6 | R | Non-obvious coupling; a GUI need not copy it (it has room for both). |
| `/statusline` | `prompt`-type command dispatching the built-in `statusline-setup` agent with `allowedTools: [Task, Read(~/**), Edit(~/.claude/settings.json)]`; `disableNonInteractive: true`; refuses in safe mode with a message explaining that safe mode only renders the managed status line | Live: `/statusline isn't available in this environment.` | X → R | The command is refused headless because of `disableNonInteractive`, but the *agent* (`statusline-setup`, sonnet, tools `Read`/`Edit`) is a normal built-in agent, so a GUI can dispatch the same setup flow itself by sending the equivalent user message. That is the cheapest way to get parity on status-line configuration. |
| `fileSuggestion` command (`executeFileSuggestionCommand`) | `{ type: "command", command }`, no padding/interval/timeout; gates `disableAllHooks`, feature gate, workspace trust, each returning `[]`; `AbortSignal.timeout(5000)`; input = hook base + `query`; one path per line, blanks dropped, no JSON; failures return `[]` silently. When configured it **replaces the built-in file index entirely** and at most 15 suggestions show, in the command's own order (§41.19.8) | The `file_suggestions` control request (`query` → `suggestions?`) goes to the CLI, which applies this setting | P | A GUI should route `@` completion through `file_suggestions` rather than doing its own filesystem scan — that way the user's `fileSuggestion` command, gitignore respect and index all keep working. |
| `subagentStatusLine` | Separate setting decorating each running task row; **not** through the hook runner — shells out directly with a 5000 ms timeout; input = hook base + `columns` + `tasks[]`; output is **JSONL**, one `{id, content}` per line, malformed lines logged and skipped; cadence 300 ms then every 5000 ms, re-entrancy-guarded (§41.19.10) | Task list available from `background_tasks` / `task_*` frames | R | Obscure but cheap: a GUI with a task list can run the same command and decorate rows identically. |
| Telemetry (`tengu_status_line_mount`, `tengu_status_line_result`, `tengu_feature_ok/bad`) | §41.19.9 | — | T | No user-visible effect. |

## 41.20 Terminal notifications

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `preferredNotifChannel` domain `auto`, `iterm2`, `terminal_bell`, `iterm2_with_bell`, `kitty`, `ghostty`, `notifications_disabled` (default `auto`; legacy key that may live in `~/.claude.json`) | §41.20.1 | `get_settings` returns it (live: `"terminal_bell"`); `/config notifChannel=…` works headless | R | A GUI should read it as intent: `notifications_disabled` must silence native notifications too, and anything else means "notify me". |
| Notification-type domain (14 values) | `permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`, `agent_needs_input`, `agent_completed`, `elicitation_url_dialog`, `worker_permission_prompt`, `push_notification`, `computer_use_enter`, `computer_use_exit`, `quota_auto_resume_fired`, `quota_auto_resume_stale`, `quota_auto_resume_disabled` | The internal `os_notification` message that carries these is **dropped before the wire** (SPEC 45.9.2) | **D** | This is the notification gap. The host never learns "notify now, type X". Workarounds, in order of quality: (1) the **`Notification` hook** still fires in-process, and with `--include-hook-events` the host sees `hook_started`/`hook_response` for it, carrying `message`, `title`, `notification_type` — this is the recommended bridge; (2) infer from wire state: `session_state_changed: requires_action` → permission/dialog needed, `result` + idle → turn complete, `can_use_tool` arrival → permission prompt. |
| `auto` channel resolution | `Apple_Terminal` → `terminal_bell` only when the profile's audible bell is **off** (i.e. the bell is a visual flash), else no method; `iTerm.app` → `iterm2`; `kitty` → `kitty`; `ghostty` → `ghostty`; anything else → **no method available** (§41.20.2) | — | T | The consequence: in most terminals (including plain xterm, tmux, VS Code) the user gets **no OS notification at all**. A GUI with native notifications is unambiguously better here. |
| Apple Terminal bell probe | AppleScript reads the front window's profile name, then the plist `Bell` key (§41.20.2) | — | T | — |
| Escape sequences | iTerm2 `ESC]9;<title: message>BEL`; kitty three OSC 99 writes (`i=<id>:d=0:p=title`, `i=<id>:p=body`, `i=<id>:d=1:a=focus` — clicking focuses the window); Ghostty `ESC]777;notify;<title>;<body>BEL`; bell `\x07`. All except the bell go through the tmux/screen DCS wrapper. App name `Claude Code`; kitty id is a random int < 10000 (§41.20.3) | — | T | The kitty `a=focus` action is the affordance to match: clicking a GUI notification must focus and reveal that session. |
| OSC 9;4 progress bar | Gated by capability (`WT_SESSION` disables; ConEmu enables; ghostty ≥1.2.0; iTerm2 ≥3.6.6) and by the setting `terminalProgressBarEnabled` (default true, `/config` label `Terminal progress bar`). States: clear `ESC]9;4;0;BEL`, error `;2;<pct>`, indeterminate `;3;`, running `;1;<pct>`; percentage clamped 0…100 and rounded (§41.20.4) | `/config progressBar=true\|false` headless | R | The macOS analogue is a Dock badge / progress indicator. Honour `terminalProgressBarEnabled` as "show me progress in the OS chrome". |
| The `Notification` hook | Fires on **every** OS notification with `{hook_event_name: "Notification", message, title, notification_type}` | With `--include-hook-events` the host sees `hook_started`/`hook_progress`/`hook_response` frames | P | As noted above, this is the practical bridge for the dropped `os_notification` lane — but only if the user actually has a `Notification` hook configured. A GUI can install its own hook (via `initialize.hooks`) that emits a marker the GUI recognises, turning the whole notification lane into **P**. That is the recommended workaround for the row above. |
| Message texts | `Claude is waiting for your input` (`idle_prompt`); `Claude needs your permission to use <tool>` (`permission_prompt`); `Claude Code login successful` (`auth_success`); `<name> needs permission for …` and `<name> needs network access to <host>` (`worker_permission_prompt`); `<label> needs your input` (`agent_needs_input`); `<label> finished` / `<label> failed` (`agent_completed`); `Claude is using your computer · press Esc to stop` / `Claude is done using your computer` (§41.20.6) | — | R | Reuse verbatim; users recognise them. |
| `PushNotification` refusals | `Push not sent — mobile push is disabled in /config.`; `Not sent — this terminal is active, so your output here already reaches the user; a separate notification would be redundant.`; `Mobile push not sent (Remote Control inactive).` / `Terminal notification sent. Mobile push not sent (Remote Control inactive).`; presence check skippable with `CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK` (§41.20.6) | Tool result on the wire | R | The presence check is the interesting one: "this terminal is active" must become "this GUI window is focused", or the GUI will suppress notifications it should send (or vice versa). Since the CLI cannot see GUI focus, a GUI should set `CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK` and do its own focus-based suppression. |
| `/config` channel labels | `Auto`; `iTerm2 (OSC 9)`; `Terminal Bell (\a)`; `Kitty (OSC 99)`; `Ghostty (OSC 777)`; `iTerm2 w/ Bell`; `Disabled`. Short forms elsewhere: `bell`, `iterm2+bell`, `none` (§41.20.7) | Headless `/config notifChannel=` accepts the same seven values | R | A GUI should relabel these (they are terminal-protocol names) but must keep writing the same values. |
| `inputNeededNotifEnabled` / `agentPushNotifEnabled` (both default false) | Push when actions required / when Claude decides | `/config inputNeededNotifEnabled=`, `/config agentPushNotifEnabled=` headless; both in `get_settings` (live: present) | P | — |

## 41.21 The terminal title and tab status

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Title write | `M7(title)` writes `ESC]0;<title>BEL` (SET_TITLE_AND_ICON) with ANSI stripped; `null` suppresses the write. **There is no OSC 1 or OSC 2 emitter** | — | T → R | A GUI sets its window/tab title instead — the same information architecture applies. |
| Title resolution precedence | `sessionTitle` (explicit `/rename`) → `aiSessionTitle` (model-generated) → `agentTitle` (`--agent` type) → `haikuTitle` (utility-model short title) → `Claude Code` | `rename_session` and `generate_session_title` control requests; `--agent` is a launch flag the host chose | P | Full parity: the host can set and fetch the title. Live probe confirms `/rename probe-title` → `Session renamed to: probe-title`. |
| Animated prefix | `◐`/`◑` alternating every 960 ms while the turn runs; static `✳` when idle or suppressed; title is `<prefix> <title>`. Pinned static under a multiplexer (gate `tengu_static_title_under_mux`, default on) | Turn state from `system/status` / `session_state_changed` | R | Copy the idea — a running/idle marker in the window title is what lets users find the busy session among many windows. Suppress the animation under reduced motion. |
| Gating and teardown | `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` disables the store, skips `process.title`, and skips the exit reset; `terminalTitleFromRename` controls whether `/rename` feeds the title; on exit the title is cleared with `ESC]0;BEL` written synchronously (§41.21.4) | Settings readable | R | Honour `terminalTitleFromRename` if the GUI titles windows from `/rename`. |
| Other title writers | `/resume` sets `claude · resume`; an attached background job writes its state into the title (§41.21.4) | — | T | — |
| Tab status (OSC 21337) | Fully implemented — state palette (`idle` green `Idle`, `busy` orange `Working`, …), encoder, clear string — but **the capability predicate is hard-coded `false`, so nothing is ever emitted**. The `showStatusInTerminalTab` `/config` row exists, gated by `tengu_terminal_sidebar` (§41.21.5) | — | X → **GUI exceeds** | A dead feature in the terminal that a GUI can simply ship: per-session status colour + word in the tab. The palette is in the spec. |

## 41.22 Dialogs as a widget system

**Headline:** none of the 74 lazily-imported panels below can ever be triggered headless.
`request_user_dialog` forwards only agent-initiated dialog kinds the host declared in
`initialize.supportedDialogKinds` (the CLI fails closed on absence — afleet's live probe declared
`supportedDialogKinds: []`, so every dialog-gated flow degrades to its no-dialog behaviour, e.g.
`refusal_fallback_prompt` becomes the classic refusal error). `can_use_tool` carries only
permission requests, `AskUserQuestion` and `ExitPlanMode`. Everything else is **X**, with a
control-request or on-disk equivalent noted where one exists.

### 41.22.1 The lazy dialog registry — all 74 entries

| Command | Headless path | Class | Notes |
|---|---|---|---|
| `add-dir` | `add_directory` control request | R | Panel X, capability R. |
| `advisor` | none | X | — |
| `artifacts` | `code_change_published` frames; artifact tools | R | — |
| `auto-mode-setup` | `/config useAutoModeDuringPlan=`, `permissionMode=auto` | R | — |
| `autocompact` | `/config autoCompact=`; `get_context_usage.autoCompactThreshold`/`isAutoCompactEnabled` | R | — |
| `autofix-pr` | none | X | — |
| `btw` | `side_question` control request (progress via `control_request_progress` — the only progress kind on the wire) | R | Live `/btw` refused; the control request is the real path. |
| `bug` | `submit_feedback` control request; `feedback_draft_queued` frames | R | — |
| `cd` | `set_cwd` control request | R | — |
| `chrome` | `/config chrome=` | R | — |
| `cloud-plugins` | `reload_plugins`; `plugin_install` frames | R | — |
| `config` | headless `/config key=value` (38 keys) + `get_settings` / `update_settings` | R | See §41.26. |
| `context` | `/context` works headless (markdown text); `get_context_usage` for structured data | P | Live-verified. |
| `copy` | none needed — the GUI holds the transcript | R | The sidecar-file half is X. |
| `design-login` | none | X | — |
| `desktop` | none | X | — |
| `diff` | `get_workspace_diff` control request | R | Live `/diff` refused. |
| `effort` | `/effort <level>` works headless | P | Live: `Set effort level to low (this session only)…`. |
| `exit` | `end_session` control request | R | — |
| `export` | host owns the transcript | R | Live `/export` refused. |
| `extra-usage` | none (billing web flow) | X | — |
| `fast` | `/fast` returns `Fast mode unavailable: Fast mode is not available in the Agent SDK`; `initialize.fast_mode_state` + `fast_mode_disabled_reason` | D | Fast mode is genuinely unavailable on the SDK/headless path — a capability gap, not just a UI gap. |
| `feedback` | `submit_feedback` | R | — |
| `fork` | none | X | Session forking has no control request. |
| `goal` | `/goal` works headless; `active_goal` frames | P | Live: `No goal set. Usage: /goal <condition>`. |
| `help` | none | X | GUI ships its own; see the `?` panel row in §41.15.4. |
| `hooks` | settings files on disk; `initialize.hooks`; hook event frames | R | — |
| `ide` | ch. 33 lane, not on the headless wire | D | — |
| `import` | present in the headless command list | R | — |
| `install-github-app` | none | X | — |
| `login` | `claude_authenticate`, `claude_oauth_callback`, `claude_oauth_wait_for_completion`; `auth_status` frames with `--enable-auth-status` | R | Full OAuth flow is host-drivable. |
| `logout` | none | X | — |
| `loops` | none | X | Live refused. |
| `mcp` | `/mcp` returns a text summary; `mcp_status`, `mcp_toggle`, `mcp_reconnect`, `mcp_authenticate`, `mcp_clear_auth`, `mcp_oauth_callback_url`, `mcp_set_servers`, `set_mcp_permission_mode_override` | R | Live `/mcp` → `3 MCP server(s): 2 connected, 1 not connected, 0 disabled. Use /mcp in the terminal for details.` — an explicit "go to the terminal" dead end the GUI must replace. |
| `memory` | memory files on disk; `memory_recall` frames | R | — |
| `mobile` | none | X | — |
| `model` | `/model` works headless; `set_model`, `list_models`, `initialize.models` | P | Live-verified both forms. |
| `output-style` | `initialize.output_style` + `available_output_styles`; `/config outputStyle=` | P | — |
| `passes` | none | X | — |
| `permissions` | settings files; `set_permission_mode`; `can_use_tool` responses may carry rule updates | R | Live `/permissions` refused. A GUI must build the whole rule editor. |
| `plan` | `get_plan` control request | R | Live `/plan` refused. |
| `plugin` | `reload_plugins`; `plugin_install`, `commands_changed` frames | R | — |
| `powerup` | none | X | — |
| `privacy-settings` | none | X | — |
| `pro-trial-expired` | none | X | Account-lifecycle panel. |
| `rate-limit-options` | none; the underlying `autoContinueAtUsageLimit` setting is on disk (not in the headless `/config` key list) | X → R | See §41.16.11. |
| `release-notes` | none | X | Live refused. |
| `remote-control` | `remote_control` control request; `initialize.remote_control_*` | R | — |
| `remote-env` | `update_environment_variables` stdin frame (only two token vars) | D | Almost no coverage. |
| `resume` | `--resume` / `--session-id` at launch; session files on disk | R | Live `/resume` refused; a GUI owns session listing anyway. |
| `sandbox` | none | X | — |
| `scroll-speed` | — | T | — |
| `session` | `initialize`, `rename_session`, `end_session` | R | — |
| `setup-bedrock` / `setup-vertex` | env/config files | R | — |
| `skill-doctor` | present in the headless command list | R | — |
| `skills` | `reload_skills`; `initialize.commands` includes skills | R | Live `/skills` refused. |
| `status` | `initialize` + `get_binary_version` + `mcp_status` + `get_settings` + `get_usage` | R | Live `/status` refused; every field is separately fetchable. |
| `tasks` | `background_tasks` control request; `task_*` and `background_tasks_changed` frames; `stop_task` | P | Live `/tasks` refused, but the data lane is complete. |
| `teleport` | none | X | — |
| `terminal-setup` | — | T | §41.25. |
| `theme` | `/config theme=`; custom themes on disk | R | §41.10. |
| `tui` | — | T | — |
| `ultrareview` | `ultrareview_launch` control request | R | — |
| `upgrade` | none | X | — |
| `usage` | `/usage` works headless (and `/cost`, `/stats` alias to it); `get_usage` | P | Live-verified; returns plan usage text with reset times. |
| `usage-credits` | present in the headless command list | R | — |
| `vim` | `editorMode` in settings; `/config editor=normal\|vim` headless | R | Live `/vim` refused; key handling is host-side (ch. 42). |
| `web-setup` | none | X | — |
| `wellbeing` | none | X | — |
| `background` | `background_tasks`, `task_*` frames | R | Live refused. |
| `daemon` | none | X | — |
| `stop` | `stop_task` control request (declare `perTaskStopAffordance`) | R | — |
| `workflows` | none on the wire beyond normal tool use | X | `/config workflows=`, `workflowSizeGuideline=` reachable. |

### 41.22.2–41.22.12 Widget behaviour

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Mount/unmount lifecycle | Elements stored in a `Map` by minted id; the promise resolves `"closed"` (programmatic abort) vs `"dismissed"` (user escaped) | — | R | The closed/dismissed distinction is worth keeping: a GUI should treat "we closed it" and "the user dismissed it" differently for retry/telemetry. |
| `immediate` / `hidesPrompt` / `retireAtTurnBoundary` per call site | A slash command typed **mid-turn** keeps the prompt live; the same command at rest hides it. Turn-boundary retirement closes opted-in dialogs before dispatch, on an empty batch, and in the `finally` arm (§41.22.2) | — | R | The mid-turn rule is a real UX principle: never steal the composer while the user might want to keep typing. |
| Failure strings | Interactive: `/<cmd> is currently unavailable.` (immediate-priority feedback notification; telemetry `cmd_local_jsx_no_dialog_resolution`, `cmd_local_jsx_no_panel_host`). Non-interactive: `/<cmd> opens an interactive panel and isn't available in this environment. Run it from the Claude Code terminal instead.` | The live capture shows the shortened form `"/<cmd> isn't available in this environment."` in 2.1.259 | P | A GUI should intercept these before they reach the user and route to its own panel — the message telling users to "run it from the Claude Code terminal" is exactly the failure a GUI exists to prevent. |
| Prompt blocking | **The prompt is unmounted, not disabled.** Keyboard isolation comes from three independent mechanisms: the composer subtree is removed, the dialog frame claims `activeElement`, and scope-chain resolution walks up from the focused node (§41.22.4) | — | R | A GUI should use real modality/focus trapping rather than disabling inputs. |
| Dialog store placement rules | `place: "under"` (queue behind what the user is looking at), `holdsTop` (only `mcp_elicitation`), `succeeds`, `hideWhile` (default `["panel"]`), `shownAt` with a **150 ms input grace period**, `revealSeq` (§41.22.5) | — | R | The 150 ms input grace is the anti-misclick rule: a dialog that appears must not accept the keystroke already in flight. Copy it. |
| Suppression reasons in priority order | `progress` → `panel` → `draft` → `typing` → none. A dialog hidden by `draft` shows a dim placeholder: `Claude has a question for you — it shows once you send or clear what you're typing.` / `Claude has a suggestion for you — it shows once you send or clear what you're typing.` (§41.22.5) | The host receives `can_use_tool` / `request_user_dialog` immediately regardless | R | Important behaviour to copy: never interrupt a user mid-draft with a modal; park it with a visible placeholder. Both strings are reusable verbatim. |
| Three mounts, not an overlay (`inline`, `bottom`, `modal`) | Layout is declarative per dialog kind; default `inline`; only five of 42 kinds override it (`local_jsx` → modal in fullscreen / bottom if immediate / inline; `ultraplan_choice` and `permission_exit_plan_mode_v2` → modal; the MCP elicitation kinds → bottom) (§41.22.6) | — | R | The principle: permission prompts appear **in the transcript flow**, not as OS modals. A GUI that turns every permission into a modal dialog will feel much worse than the terminal. |
| Dialog chrome | **A Claude Code dialog has no box** — a single horizontal rule (`─`, or `▔` for the fullscreen modal) plus two columns of horizontal padding, shrinking to 1 and dropping the rule in a constrained viewport. Props: `title` (bold, in `color`), `titleEnd` (right-aligned, dim, `truncate-start`), `subtitle` (dim), `color` (default `permission`), `onCancel` bound to `confirm:no` with hint `cancel`, `inputGuide`, `hideInputGuide`, `hideBorder`, `onInterrupt` (§41.22.7) | — | R | The visual language is intentionally lightweight; a GUI is free to use cards, but should keep permission prompts inline and low-chrome. |
| Select list | Cursor glyph priority: disabled → space; focused → `❯` in `suggestion`; last row with more below → `↓` with `aria-label: "(more below)"`; first row with more above → `↑` `(more above)`; hovered → dim `❯`. Selected marker `✔` in `success`, `aria-label: "(selected)"`. Row colour `inactive`/`success`/`suggestion`. Numbering is absolute, 1-based, padded; **only digits 1–9 are actionable** (`0` maps to −1 and is rejected). Navigation **wraps around** in both directions and resets the visible window. Page size default 5, clamped to terminal height with 8 rows reserved (§41.22.8) | — | R | Two rules worth copying into a GUI list: numeric quick-select 1–9, and wrap-around navigation. The aria labels are the accessibility vocabulary. |
| Multi-select and text input | Checkbox composed from brackets (`[✔]` in `success` / `[ ]`), not the `figures` glyphs; `tab`/`shift+tab` move focus (tab from the last row jumps to submit), `space`/`enter` toggle, digits 1–9 toggle by index, `escape` cancels. Text-input cursor is a space painted `inverse`, suppressed in screen-reader mode. **There is no shared Confirm widget** — a yes/no is the frame + a two-option select (`Yes`/`No`) + the `Confirmation` scope (§41.22.9) | Relevant when rendering `AskUserQuestion` via `can_use_tool` | R | A GUI rendering `AskUserQuestion` should support the same gestures (numeric select, tab-to-submit) so keyboard users keep their habits. |
| Keyboard-hint vocabulary | ~460 hints generated from `{chord, action}` pairs: `<chord> to <action>` or `(<chord> to <action>)`; three formatting presets (`default`, `compact`, `symbol`) differing in key case, modifier case, `caretCtrl` (`ctrl+X` → `^X`), separators; a key-name table with title/lower/glyph forms (`Enter`/`enter`/`⏎`, `Esc`/`esc`/`⎋`, `Tab`/`tab`/`⇥`, `Space`/`space`/`␣`, `Backspace`/`⌫`, `Delete`/`⌦`, arrows, `PageUp`/`pgup`/`⇞`, `Home`/`↖`, `End`/`↘`) and platform-aware modifiers (`⌃⇧⌥⌘`). `Ke` resolves the user's actual binding and renders nothing for a deliberately unbound action; `fe` joins with a dim ` · `; `Z` auto-generates up to **4** hints from the focused element's ancestor handlers, appending `+N more`, rendered dim and italic. Default footer: `enter to confirm · Esc to cancel`; a pending Ctrl-C/Ctrl-D double-press replaces the row with `Press <key> again to exit` (§41.22.10) | User keybindings live in `~/.claude/keybindings.json` (ch. 42) | R | The generalisable principle: **hints must reflect the user's actual bindings, not hard-coded chords**, and an unbound action shows no hint. A GUI reading the same keybindings file keeps hints honest. The 4-hint cap plus `+N more` is a good density rule. |
| Keyboard scopes | 23 named scopes with documented meanings (`Global`, `Chat`, `Autocomplete`, `Confirmation`, `Help`, `ProactivityMenu`, `Transcript`, `HistorySearch`, `Task`, `ThemePicker`, `Settings`, `Tabs`, `Attachments`, `Footer`, `MessageSelector`, `DiffDialog`, `DiffPanel`, `ModelPicker`, `EffortSlider`, `Select`, `Plugin`, `Scroll`, `Agents`) (§41.22.11) | — | R | Ch. 42 owns the bindings; from the rendering angle the list is the inventory of focusable regions a GUI must have — notably `Footer` (chips are focusable) and `Scroll`. |
| Glyph tables | Vendored `figures` with a Unicode/ASCII fallback chosen by a capability sniff (non-Windows: Unicode unless `TERM=linux`; Windows: an allow-list); status table mapping five states to glyph + colour + `aria-label` (`done:`, `failed:`, …). The Claude Code glyph constants have **no** fallback table (only the macOS `⏺` vs `●` branch) (§41.22.12) | — | T | A GUI uses icons; keep the `aria-label` vocabulary. |

## 41.23 Transcript view, brief mode and verbosity

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| The fold | Long tool results fold at **three wrapped lines**; effective width `max(columns − 10, 10)`; character scan capped at `3 × width × 4`; a fourth line is shown when hiding it would hide exactly one line; affordance `(<chord> to expand)`. Per-renderer overrides: errors 10 lines, `Write` preview 10, `memory_write` 10 × 200 chars, `Bash` header 2 lines/160 chars, rejected-write preview 10, agent progress 3 sub-messages, system rows 5 lines/200 chars (§41.23.1) | Full text is on the wire in `tool_use_result` | R | Copy the fold defaults for visual density, but a GUI can expand in place with no re-layout cost. The "show the 4th line rather than hide exactly one" rule is a nice detail. |
| `ctrl+o` transcript screen | `app:toggleTranscript` in the `Global` scope, flips `screen` between `prompt` and `transcript`; **forces verbose rendering** (settings `verbose` OR `screen === "transcript"`); replaces the whole layout subtree; commit cursor tightens to a 30-message cap (§41.23.2) | No wire involvement | R | A GUI's transcript is always on screen; the affordance to preserve is the **verbose toggle**, not the screen switch. |
| Transcript hint bar | `dialog waiting · Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll · v to open in editor · ? for shortcuts`, degrading to a bare `? for shortcuts`; right-aligned `verbose ` badge (§41.23.2) | — | R | `dialog waiting` is a genuinely useful state indicator — a GUI should surface "a dialog is parked behind this view" the same way. |
| Transcript help panel | Two-column legend: `↑↓ j/k scroll`, `ctrl+u/d half page`, `space b page`, `g/G top/bottom`, `{/} prev/next prompt`, `/ search`, `n/N next/prev match`, `[ print to scrollback`, `v open in <editor>`, `ctrl+o toggle transcript`, `q exit`, `? close help` (§41.23.2) | — | R | `{`/`}` prev/next **prompt** navigation is the standout affordance — jumping between user turns. A GUI should offer it. `[ print to scrollback` is terminal-only (T). |
| `ctrl+e` — show all | `transcript:toggleShowAll` in the `Transcript` scope; renders a titled rule `<chord> to show <bold N> previous messages` / `… to hide …` above the list, and a footer segment cycling `n/N to navigate` → hint bar → `v to <editor>` → `<chord> to collapse/show all`. (`ctrl+r` is **not** an expand key — it is `history:search`) (§41.23.3) | The host holds every message it has received; older history needs `--resume` or reading the session file | R | Caveat: a GUI attached mid-session (resume) must load prior messages from the session transcript file itself — the wire replays only what happens after attach (plus `--replay-user-messages`). |
| `verbose` setting and `viewMode` | `verbose: boolean` ("Show full tool output instead of truncated summaries"), companion `viewMode: default\|verbose\|focus`; resolution order CLI flag → `viewMode` → settings cascade; the load-bearing consumer is the shared text renderer | `/config verbose=true\|false` works headless; `verbose` is also a CLI flag afleet already passes (`--verbose` is required for stream-json output, a different meaning) | R | Note the collision: `--verbose` on the command line is a *protocol* requirement for stream-json, while the `verbose` **setting** is a rendering choice. A GUI must keep them separate and expose the rendering one as its own toggle. |
| Brief mode | `CLAUDE_CODE_BRIEF` or gate `tengu_kairos_brief` selects a compact spinner and compact message layout; app state carries `isBriefOnly` and `briefTranscript`; `/brief` toggles brief-only; `/focus` is the third view mode ("just your prompt, summary, and response"); `streamingPreviewHold` combines them (`hidden` in transcript or brief-only, `focus` in fullscreen focus mode, else `none`); theme keys `briefLabelYou` / `briefLabelClaude` (§41.23.5) | `/brief` and `/focus` both refused headless (live) | X → R | The three view densities (default / verbose / focus) are a genuine product idea a GUI should offer: `focus` = prompt + summary + response only. `viewMode` and `defaultView` are settable from settings, so the GUI can honour a user's existing preference. |
| `defaultView` (`transcript`/`chat`/`default`) | Which screen a session opens on | Settings; not in the headless `/config` key list | R | Read from `get_settings` if set. |

## 41.24 Paste cache, image paste and `/copy`

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Placeholder shapes | `[Pasted text #N]` / `[Pasted text #N +M lines]`; `[Image #N]`; `[Audio #N]`; `[...Truncated text #N +M lines...]` for visible input over 10000 chars (keeping 500 head + 500 tail). Note the asymmetry: the leading `...` sits outside the `#N`, the trailing inside the bracket (§41.24.1) | The expanded content is what goes on the wire in the `user` frame | R | A GUI composer must produce the same placeholders if it wants text round-tripping and the atomic-token editing behaviour; it may instead show real chips, which is better UX but diverges from `history.jsonl` compatibility. |
| Placeholders as atomic editor tokens | Cursor motion, word-delete and selection treat a placeholder as one unit (§41.24.1) | — | R | Required or users delete half a placeholder and corrupt it. |
| Eviction notice | `<label> #N is no longer available and was removed from the prompt` / `… are no longer available and were removed …` (§41.24.1) | — | R | — |
| Text paste cache | `~/.claude/paste-cache/<sha256[0:16]>.txt`, mode `0600`; **the spill happens at history-write time, not at paste time**, and only for entries longer than 1024 characters; shorter pastes are inlined into `history.jsonl`; write failure retains content in memory up to a cumulative 10 MB; eviction is age-only via `cleanupPeriodDays`, sweeping `.txt` and `.txt.tmp.*` (§41.24.2) | Not on the wire | R | Only matters if the GUI shares prompt history with the terminal. If it does, it must implement the same spill or the terminal will show broken placeholders for GUI-originated history entries (and vice versa). |
| Image cache | `~/.claude/image-cache/<sessionId>/<pasteId>.<subtype>`, mode `0600`, `datasync`ed; in-memory path map capped at 200, FIFO; eviction is **session-scoped**, deleting every session directory except the current one in full (§41.24.3) | — | R | The whole-directory eviction is aggressive: a GUI keeping several sessions alive must not let the CLI's sweep delete another live session's images. Worth verifying in practice. |
| Getting an image in — clipboard | Per-platform commands (`osascript -e 'get POSIX path of (the clipboard as «class furl»)'` on darwin; `xclip`/`wl-paste` on linux). The bundled artefact is darwin-only, so the win32 arm is unreachable (§41.24.4) | Stdin `user` frames accept image content blocks directly | P → **GUI exceeds** | A native GUI reads the clipboard through the OS API — no shelling out, no `osascript`, works for images that never touch a file. This is a clear improvement. |
| Getting an image in — drag and drop | A pasted string split on ` /` and ` C:\` boundaries and newlines; paths matching `/\.(png\|jpe?g\|gif\|webp)$/i` are read as images; macOS `screencaptureui` temp screenshots route back through the clipboard reader (§41.24.4) | — | P → **GUI exceeds** | Native drag-and-drop with previews beats path-string parsing outright. |
| Getting an image in — long keypress | Any single key event whose payload exceeds 800 characters is treated as a paste (§41.24.4) | — | T | Terminal-only heuristic. |
| Media-type detection and size budgets | **Magic bytes, not extension**: PNG `89 50 4E 47`, JPEG `FF D8 FF`, GIF `GIF87a`/`GIF89a`, WEBP `RIFF…WEBP`, else null. Budgets: `imageMaxRawBytes` 307200 (tight profile) / 512000, `wholePdfMaxRawBytes` 0 / 2500000, `pdfMaxPagesPerRead` 3 / 6; a JPEG re-compressor bisects quality 1–89 in ≤5 steps. Failures: `[Image could not be processed: <msg>]`, `Unable to compress image (<size>) to fit within <limit>. Please use a smaller image.` (§41.24.4) | The GUI must do this before putting an image block on stdin | R | Copy the magic-byte sniff and the budgets, or the API rejects oversized images with a worse error. The compression ladder is a real requirement for screenshots on Retina displays. |
| Paste feedback | Footer rows `Pasting…` and `paste again to expand` (§41.24.5) | — | R | — |
| `/copy` | `local-jsx`; offers the full response plus one entry per fenced code block; full entry labelled `Full response` with description `<n> chars, <m> lines`; copies, **writes a sidecar file** (directory mode `0700`, extension from the block's language, default `.txt`), and returns `Copied to clipboard (<n> characters, <m> lines)` + `Also written to <path>`; on copy failure prefixes `⚠ <reason>; the file below is unaffected`. `copyFullResponse` global-config flag skips the picker (`/config` label `Skip the /copy picker`) | Live: `/copy isn't available in this environment.` | X → R | The GUI copies from its own transcript. Two behaviours worth keeping: per-code-block copy targets (not just the whole response), and the sidecar file as a fallback when clipboard access fails. `copyFullResponse` and `copyOnSelect` are both headless-settable via `/config` and should be honoured. |
| Clipboard transport | OSC 52 or a platform tool, with the tmux wrapper and the VS Code 1.123–1.125 UTF-8 bug workaround (§41.11.5, §41.24.6) | — | T | Native clipboard API supersedes all of it. |

## 41.25 `/terminal-setup`

Entirely terminal-specific — **T** throughout. Listed because a GUI hosting the binary may still
want to know what it does to the user's machine, and because the Apple Terminal branch has an
accessibility interaction.

| Feature | TUI behaviour (SPEC §) | Class | Notes |
|---|---|---|---|
| Eligibility | Apple Terminal (macOS), `vscode`, `cursor`, `windsurf`, `alacritty`, `zed`. Terminals with native Shift+Enter (Ghostty, Kitty, iTerm2, WezTerm, Warp, Windows Terminal) get a message and no configuration. Remote-editor sessions (`.vscode-server`, `.cursor-server`, `.windsurf-server`, `.devin-server`) are refused | T | Live: refused headless. |
| VS Code family | Writes `keybindings.json` (`shift+enter` → `workbench.action.terminal.sendSequence` with `{"text":"\u001b\r"}`, `when: terminalFocus`), sets `terminal.integrated.mouseWheelScrollSensitivity` to 3 and `terminal.integrated.gpuAcceleration` to `off`; backs up to `<path>.<4 hex bytes>.bak` first; outcome strings incl. `<editor> already has a Shift+Enter terminal binding with different args; leaving it as-is.` | T | The GPU-acceleration change exists to fix garbled glyphs — a GUI has no such problem. |
| Apple Terminal | PlistBuddy sets `useOptionAsMetaKey true` and `Bell false` on both `Default Window Settings` and `Startup Window Settings`; exports a backup first; restore is `defaults import` + `killall cfprefsd`; **skipped when macOS major ≥ 27, and when screen-reader mode is on (which needs the audible bell)**; success text ends `You must restart Terminal.app for changes to take effect.` | T | The screen-reader skip is the one behavioural principle to carry over: never disable a user's audible feedback channel when assistive tech is in use. |
| Alacritty / Zed | Appends a TOML `[[keyboard.bindings]]` block / edits `keymap.json` JSONC-aware with `terminal::SendText "\u001b\r"` | T | — |
| iTerm2 clipboard access | Probes `defaults read com.googlecode.iterm2 AllowClipboardAccess`, writes it back, and embeds the undo instruction (`iTerm2 → Settings → General → Selection → check "Applications in terminal may access clipboard"`) | T | — |
| Under a multiplexer | Short-circuits with the full unsupported-terminal help text (`Terminal setup cannot be run from tmux/screen…`, including `You can already use backslash (\) + return to add newlines.`) | T | — |
| Onboarding step and the rotating tip | `Use Claude Code's terminal setup?` with `Yes, use recommended settings` / `No, maybe later with /terminal-setup`; tip registry entry 11 | T | A GUI must drop this tip (its `advertisedCommand` does not exist there) — see §41.18.9. |

## 41.26 The `/config` panel

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Structure | Four tabs `Status`, `Config`, `Usage`, `Stats`, framed `Settings`; the Config tab groups rows into eight sections (`Appearance`, `Model & output`, `Display`, `Input & controls`, `Connections`, `Advanced`, `Experimental`, `Internal`); the `Advanced` header becomes `ADVANCED — MOVING TO SETTINGS.JSON` when migration applies | The headless `/config` is a **different command**: `Usage: /config key=value [key=value ...]` listing 38 keys (live-verified) | R | A GUI builds its own settings window. The section grouping is worth copying — it is the product's own information architecture for these options. |
| Row types and writers | Only three row types: `boolean`, `enum`, `managedEnum`. **No number or free-text row.** A boolean renders the literal string `true`/`false` — no glyph, no on/off wording. Four writers: `settings.json` (user), `settings.local.json` (local), one-key user write, and the **global config store** (`~/.claude.json`) | `update_settings` writes **localSettings only**; anything targeting user settings or the global config must be written to disk by the host | R → partly **D** | This is the important asymmetry: rows whose writer is the global config (`showStatusInTerminalTab`, `gitignore`, `copyFullResponse`, `copyOnSelect`, `defaultToAgentsView`, `leftArrowOpensAgents`, `externalEditorContext`, `prStatus`, `diffTool`, `autoConnectIde`, `autoInstallIdeExtension`, `chrome`, `apiKey`, `workflowSizeGuideline`) cannot be written through `update_settings` at all. A GUI must edit `~/.claude.json` directly or use the headless `/config key=value` command where the key is supported. |
| Rendering | Label column `min(44, max(14, availableWidth − 16))`; selection glyph `❯`; selected rows `suggestion`; `labelBoldSuffix` in bold; policy-locked rows show an indented dim reason line; migrating rows marked `→ settings.json`; search box `Search settings…`, empty state `No settings match "<q>"`, scroll indicators `↑ N more above` / `↓ N more below` (§41.26.3) | — | R | Two things to copy: the **policy-locked reason line** (enterprise users need to know why a setting is greyed out) and search-as-you-type over settings. |
| Footer states | navigation (`←/→/tab to switch`, `down to return`, `Esc to close`), filtering (`Type to filter`, `enter/down to select`, `up to tabs`, `Esc to clear`), editing (`enter/space to change`, `/ to search`, `Esc to close`) (§41.26.3) | — | R | — |
| Inline warning | Under the thinking row: `Changing thinking mode mid-conversation will increase latency and may reduce quality.` (§41.26.3) | — | R | Reuse verbatim. |
| Accessibility variant | Replaces the list with a numbered form: `Enter a number to change [1-N], or <key>:`, rejecting bad input with `Invalid selection "<x>". Enter a number between 1 and N.` (§41.26.3) | — | R | — |
| Activation | Enter/space/left/right/tab activate the focused row; any printable key seeds the search box; boolean toggles in place; a plain enum **cycles**; `managedEnum` / `pickToCommit` open a sub-dialog (`Theme`, `Model`, `RemoteHomeSettings`, `ExternalIncludes`, `OutputStyle`, `Language`, `AgentsView`, `Notifications`, `EnumPicker`, `EnableAutoUpdates`, `ChannelDowngrade`) (§41.26.4) | — | R | Enum-cycling on enter is a terminal affordance; a GUI uses a popup. |
| Close summary | Emits a system message summarising changes: `Set theme to <name>`, `Set editor mode to <mode>`, an enabled/disabled line for auto-compact, or `Config dialog dismissed` (§41.26.4) | — | R | Putting settings changes into the transcript is a nice touch worth keeping — it gives the model and the user a record. |
| The 60-row registry | Full list in §41.26.2 (`autoCompact`, `autoContinueAtUsageLimit`, `remoteHomeSettings`, `switchModelsOnFlag`, `tips`, `feedbackDrafts`, `reduceMotion`, `thinking`, `fast`, `promptSuggestionEnabled`, `recap`, `checkpoints`, `orgMemoryRead`, `orgMemoryWrites`, `workflows`, `workflowKeywordTriggerEnabled`, `workflowSizeGuideline`, `artifacts`, `verbose`, `progressBar`, `showStatusInTerminalTab`, `turnDuration`, `precomputeCompactionEnabled`, `timestamps`, `timeFormat`, `permissionMode`, `worktreeBaseRef`, `useAutoModeDuringPlan`, `gitignore`, `copyFullResponse`, `copyOnSelect`, `autoScroll`, `agentsView`, `defaultToAgentsView`, `leftArrowOpensAgents`, `autoUpdatesChannel`, `theme`, `notifChannel`, `inputNeededNotifEnabled`, `agentPushNotifEnabled`, `outputStyle`, `defaultView`, `language`, `editor`, `askUserQuestionTimeout`, `modelProposedGoals`, `externalEditorContext`, `prStatus`, `model`, `diffTool`, `autoConnectIde`, `autoInstallIdeExtension`, `chrome`, `teammateMode`, `remoteControl`, `dialogExpiry`, `crossSessionInbound`, `showExternalIncludesDialog`, `apiKey`) | The live headless `/config` accepts **38** of them: `agentPushNotifEnabled`, `autoCompact`, `autoConnectIde`, `autoScroll`, `checkpoints`, `chrome`, `copyFullResponse`, `copyOnSelect`, `defaultToAgentsView`, `editor`, `externalEditorContext`, `gitignore`, `inputNeededNotifEnabled`, `language`, `leftArrowOpensAgents`, `model`, `notifChannel`, `outputStyle`, `permissionMode`, `prStatus`, `progressBar`, `promptSuggestionEnabled`, `recap`, `reduceMotion`, `remoteControl`, `switchModelsOnFlag`, `theme`, `thinking`, `timeFormat`, `tips`, `turnDuration`, `useAutoModeDuringPlan`, `verbose`, `workflowKeywordTriggerEnabled`, `workflowSizeGuideline`, `workflows`, `worktreeBaseRef` | R | **Not reachable through headless `/config`:** `autoContinueAtUsageLimit`, `remoteHomeSettings`, `feedbackDrafts`, `fast`, `orgMemoryRead`, `orgMemoryWrites`, `artifacts`, `showStatusInTerminalTab`, `precomputeCompactionEnabled`, `timestamps`, `agentsView`, `autoUpdatesChannel`, `defaultView`, `askUserQuestionTimeout`, `modelProposedGoals`, `diffTool`, `autoInstallIdeExtension`, `teammateMode`, `dialogExpiry`, `crossSessionInbound`, `showExternalIncludesDialog`, `apiKey`. Those must be written to `settings.json` / `settings.local.json` / `~/.claude.json` on disk (or, for local-scope keys only, through `update_settings`). |

## 41.27 Diagnostics, telemetry and failure handling

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Console patching | Every `console` method is redirected to the debug log (`warn`/`error` for `warn`/`error`/`trace`) so stray output never corrupts the frame | Headless writes JSON to stdout; the same discipline applies for a different reason | T | A GUI hosting the binary must keep the CLI's stderr out of the stdout JSON stream and surface it in a diagnostics pane. |
| stderr contamination → repaint | A write to `process.stderr` marks the previous frame contaminated and schedules a repaint | The live capture keeps a `stderr_tail`; stderr carries real diagnostics | R | Recommendation: a GUI should capture and expose the CLI's stderr — it is where status-line failures, theme parse errors (`[theme] <slug>.json: invalid JSON`), hook failures and renderer warnings go, none of which reach the wire. |
| Frame telemetry and debug switches (`CLAUDE_CODE_FRAME_TIMING_LOG`, `..._SAMPLE_EVERY`, `CLAUDE_CODE_BENCH_LIVE_COUNTS`, `CLAUDE_CODE_DEBUG_REPAINTS`, `tengu_flicker`) | §41.27.2, §41.27.4 | — | T | No user-visible affordance. |
| Layout/pool fault messages | §41.27.3 | — | T | — |

## 41.28 Reference: settings, environment variables and gates a user flips from the TUI

| Setting | Where the TUI flips it | Headless reachability | Class | Notes |
|---|---|---|---|---|
| `theme` | `/theme`, `/config` | `/config theme=` (7 values); `get_settings.effective.theme` | R | Custom `custom:<slug>` values only from disk. |
| `syntaxHighlightingDisabled` | not in `/config` | settings file only | R | Honour it. |
| `statusLine` | `/statusline` (agent-driven) | `get_settings`; written by the `statusline-setup` agent, which a GUI can dispatch | R | §41.19. |
| `subagentStatusLine`, `fileSuggestion` | not in `/config` | settings file; `file_suggestions` control request applies the latter | R/P | — |
| `verbose` | `/config`, `ctrl+o`/`ctrl+e` | `/config verbose=` | R | Distinct from the `--verbose` CLI flag. |
| `viewMode` (`default`/`verbose`/`focus`) | `/focus`, `/brief` | settings file only | R | — |
| `defaultView` (`transcript`/`chat`/`default`) | `/config` | settings file only | R | — |
| `preferredNotifChannel` | `/config` | `/config notifChannel=` | R | §41.20. |
| `inputNeededNotifEnabled`, `agentPushNotifEnabled` | `/config` | `/config` both | P | — |
| `terminalProgressBarEnabled` | `/config` (`Terminal progress bar`) | `/config progressBar=` | R | Map to Dock progress. |
| `spinnerTipsEnabled` | `/config` (`Show tips`) | `/config tips=` | R | — |
| `spinnerVerbs`, `spinnerTipsOverride` | settings only | settings file | R | Org tips matter for managed deployments. |
| `prefersReducedMotion` | `/config` (`Reduce motion`) | `/config reduceMotion=` | R | Accessibility requirement; also honour the OS setting. |
| `autoScrollEnabled` | `/config` (`Auto-scroll`) | `/config autoScroll=`; live `get_settings` shows `true` | R | — |
| `tui` (`default`/`fullscreen`) | `/tui` | `get_settings.effective.tui` (live `"fullscreen"`) | T | — |
| `editorMode` (`normal`/`vim`) | `/vim`, `/config` | `/config editor=`; live `get_settings` shows `"normal"` | R | Ch. 42 owns the bindings. |
| `showTurnDuration` | `/config` | `/config turnDuration=` | R | — |
| `showMessageTimestamps` | `/config` | **not** in the headless key list | R | Disk write. A GUI showing timestamps always exceeds the default. |
| `timeFormat` | `/config` | `/config timeFormat=` | R | Governs every clock the GUI renders (rate-limit resets, timestamps). |
| `diffTool` (`terminal`/`auto`) | `/config` | global config file only | R | Not writable via `update_settings`. |
| `language` | `/config` | `/config language=<value>` | R | UI language hint — a GUI should respect it for its own chrome. |
| `CLAUDE_CODE_HIDE_CWD` | env | readable from `get_settings.effective.env` if set in settings | R | A user who hides their cwd in the terminal expects the GUI to hide it too. |
| `CLAUDE_CODE_BRIEF` | env / gate | env | R | — |
| `CLAUDE_CODE_SYNTAX_HIGHLIGHT`, `CLAUDE_CODE_FORCE_STRIKETHROUGH`, `FORCE_HYPERLINK`, `NO_COLOR`, `FORCE_COLOR`, `COLORTERM`, `COLORFGBG`, `CLAUDE_CODE_TMUX_TRUECOLOR` | env | — | T | Terminal capability plumbing; `NO_COLOR` arguably should mute a GUI's colour accents too. |
| `CLAUDE_CODE_DISABLE_MOUSE`, `..._MOUSE_CLICKS`, `CLAUDE_CODE_SCROLL_SPEED`, `CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL`, `CLAUDE_CODE_NO_FLICKER`, `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN`, `CLAUDE_CODE_TUI_TRIAL`, `..._JUST_SWITCHED`, `..._FORCE_FULLSCREEN_UPSELL`, `CLAUDE_CODE_DECSTBM`, `CLAUDE_CODE_NATIVE_CURSOR`, `CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT`, `CLAUDE_CODE_FORCE_SYNC_OUTPUT` | env | — | T | Renderer-only. |
| `CLAUDE_CODE_ACCESSIBILITY`, `INK_SCREEN_READER`, `CLAUDE_AX_STARTUP_QUIET_MS`, `CLAUDE_AX_PREPARK_MS` | env | — | T | See §41.14 for the principles to carry over. |
| `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` | env | — | R | Treat as "don't advertise session state in window chrome". |
| `CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK` | env | — | R | A GUI should **set** this and do its own focus-based suppression (§41.20.6). |
| `CLAUDE_CODE_REMOTE` | env | — | R | Not a TUI setting, but decisive here: setting it turns on `tool_progress` for Bash/PowerShell **and** `autocompact_state` frames, closing two of the three data gaps in this chapter (live Bash output during a run, and compaction progress). A GUI should evaluate setting it deliberately — with the caveat that it changes other CLI behaviour outside this chapter. |
| Gates (`tengu_pewter_brook`, `tengu_amber_creek`, `tengu_marlin_porch`, `tengu_native_cursor`, `tengu_xterm_atlas_reset`, `tengu_basalt_meadow`, `tengu_cedar_marsh`, `tengu_static_title_under_mux`, `tengu_kairos_brief`, `tengu_ochre_wren`, `tengu_terminal_sidebar`, `tengu_copper_thistle`, `tengu_lilac_loom`) | server-side | not user-flippable, not on the wire | T/D | Only `tengu_cedar_marsh` (forced reduced motion) and `tengu_lilac_loom` (feature-of-the-week tips) have user-visible content a GUI would want; neither is readable headless. |

---

## Top gaps in this area

Ranked by how much they cost a GUI aiming for parity-or-better.

1. **Live Bash/tool output during a run is not on the wire by default.** `tool_progress` frames
   are emitted only under `CLAUDE_CODE_REMOTE` or `CLAUDE_CODE_CONTAINER_ID` (heartbeats and
   subagent retries always). The TUI shows `Running… <elapsed>` plus the last 5 lines
   (§41.16.7); a default headless GUI shows nothing until the tool finishes. **Class D with a
   workaround: set `CLAUDE_CODE_REMOTE`.** Same switch also turns on `autocompact_state`.
2. **OS/terminal notifications never reach the host.** The internal `os_notification` message —
   which carries the 14 notification types and their texts — is dropped by filter `Cu`
   (SPEC 45.9.2). Without it a GUI cannot know when to raise a native notification with the
   right wording. **Class D; recommended workaround: install a `Notification` hook via
   `initialize.hooks` and read it back through `--include-hook-events`,** which upgrades the whole
   lane to P. Otherwise infer from `session_state_changed: requires_action` and `result`.
3. **The statusLine payload cannot be reproduced exactly.** `cost` (`get_session_cost` returns
   only a rendered `text` blob, verified live), `prompt_cache` (12 fields), `exceeds_200k_tokens`,
   `pr`, `scratchpad_dir` and `prompt_id` have no wire source. A user's existing status script
   that reads `.cost.total_cost_usd` or `.pr.number` will print nothing in the GUI. **Class D**;
   partial workarounds: parse `get_session_cost.text`, query the PR from the git remote, derive
   `exceeds_200k_tokens` from `get_context_usage`. Everything else in the payload is
   reconstructible from `get_context_usage`, `get_usage`, `get_binary_version`, `initialize` and
   host-owned state.
4. **The context indicator must be polled.** `get_context_usage` returns
   `percentage`/`totalTokens`/`maxTokens`/`autoCompactThreshold` on demand, but nothing pushes it
   outside `CLAUDE_CODE_REMOTE`. A GUI must poll after each `result` (ideally after each assistant
   message) or its context meter goes stale. **Class R**, but easy to get wrong.
5. **Every `local-jsx` panel is unreachable and the failure text points users back to the
   terminal.** 74 registry entries; live-verified refusals for `/theme`, `/tui`, `/copy`,
   `/diff`, `/plan`, `/permissions`, `/tasks`, `/skills`, `/memory`, `/hooks`, `/status`,
   `/help`, `/export`, `/vim`, `/focus`, `/brief`, `/statusline`, `/terminal-setup` and more, plus
   `/mcp`'s `Use /mcp in the terminal for details.` **Class X per panel**, but most have a
   control-request or on-disk equivalent (§41.22.1 table) — the GUI must rebuild the UI for each
   one it wants, and must intercept the refusal text so users never see "run it from the Claude
   Code terminal".
6. **The autocomplete command list is the headless subset.** `initialize.commands` returned 102
   entries live and contains **no** `local-jsx` panel. A GUI that renders the list verbatim gives
   users a menu missing `/theme`, `/copy`, `/diff`, `/help`, `/plan`, `/permissions`, `/tasks`,
   `/statusline`, `/export` and the rest. It must merge in its own entries for the affordances it
   reimplements. **Class R.**
7. **Only a small subset of notification-bar entries crosses the wire.** `system/notification`
   carries `{key, text, priority, color?, timeout_ms?}`; the pinned/transient split, `jsx`,
   `segments`, `invalidates`, `fold` and most call sites (rate-limit family, ultrathink
   confirmation, paste eviction, clipboard miss, scroll-as-arrows) are local. **Class D**; the GUI
   must synthesise equivalents from `rate_limit_event`, `api_retry`, `informational`,
   `permission_denied` and its own state.
8. **Mermaid and inline images are never drawn by the TUI.** Mermaid fences render as a dimmed
   `mermaid` label plus raw source; images render as `[Image #N]`. The binary already renders
   mermaid 11.16.1 in published HTML artifacts. **Class R → GUI exceeds** — the two highest-value
   visual wins available, and both are pure host-side work with the data already on the wire.
9. **Untrusted-text sanitising is a paint-time behaviour the host does not inherit.** The CLI
   strips control/format characters, bidi overrides, zero-width marks and PUA before painting
   (§41.7.4); a GUI receiving raw model and tool text must implement the same passes or a
   crafted tool result can spoof its UI. **Class R, security-relevant.**
10. **Markdown `html` tokens are raw passthrough.** The TUI emits `token.text` unescaped and
    unsanitised (§41.17.2). A GUI rendering markdown to HTML must **not** copy this; it must
    escape or sanitise. **Class R, security-relevant.**
11. **Half the `/config` rows cannot be written through the protocol.** `update_settings` writes
    localSettings only, and the headless `/config key=value` accepts 38 of ~60 rows. Everything
    backed by the global config (`diffTool`, `copyOnSelect`, `gitignore`, `prStatus`,
    `showStatusInTerminalTab`, `apiKey`, …) plus `autoContinueAtUsageLimit`, `timestamps`,
    `defaultView`, `askUserQuestionTimeout`, `dialogExpiry` and others require direct file edits.
    **Class R with a real caveat** — the GUI ends up writing three different files.
12. **Custom themes, `spinnerVerbs`, `spinnerTipsOverride` and tip history live only on disk.**
    A GUI that ignores `~/.claude/themes/*.json`, the verb customisation, org tip overrides and
    the `tipsHistory`/`numStartups` cadence state silently discards personalisation the user set
    up in the terminal, and re-shows tips they have already dismissed. **Class R, cheap to fix.**
13. **Spinner stall/retry feedback has no default UI in a GUI.** `api_retry` and
    `rate_limit_event` are on the wire, but the escalation copy (`Waiting for API response`,
    `next try in <d> · attempt N/M`, the stall thresholds at 10/45/300 s) is TUI-side. Without it
    a GUI looks hung during a 45-second stall. **Class R, high perceived-quality impact.**
14. **`fast` mode is genuinely unavailable headless** — live: `Fast mode unavailable: Fast mode is
    not available in the Agent SDK`, with `initialize.fast_mode_state` and
    `fast_mode_disabled_reason` explaining it. **Class D (capability, not rendering)**; the GUI
    should hide or explain the affordance rather than offering a control that always fails.
15. **Tab status (OSC 21337) is implemented but hard-disabled in the terminal.** Per-session
    status colour and word (`Idle`/`Working`/…) with a full palette exists in the bundle and is
    never emitted. **Class X → GUI exceeds**: a GUI can ship exactly this in its session tabs
    using the spec's palette.

## Unverified

* Whether `get_workspace_diff` accepts a base selector (session / uncommitted / branch) matching
  the sidebar's `app:cycleDiffBase`. The control-request table lists the name only.
* The complete enumeration of `request_user_dialog` `dialog_kind` values. §41.22.6 says 42 dialog
  kinds exist in the store and names five; only `refusal_fallback_prompt` is documented as
  forwardable (SPEC 36 §10.3). I did not read the full `zS` schema table, so I cannot say which
  of the 42 a host may declare in `supportedDialogKinds`. What is verified: afleet's live probe
  declared `supportedDialogKinds: []`, and no local-jsx panel is ever forwarded.
* Whether `get_usage.behaviors` (present in the live response) is where the auto-continue policy
  state lives. I inferred it from the field name; I did not read its contents or a spec section
  describing it.
* Whether `initialize.footer_indicator` carries a renderable footer chip. The field is optional in
  the schema (SPEC 45:1219) and was **absent** from the live 2.1.259 `initialize` response, so I
  could not inspect its shape.
* The exact interaction between a GUI holding several sessions open and the image cache's
  whole-directory session sweep (§41.24.3). I read the eviction code path in the spec but did not
  test concurrent sessions.
* Verbatim tip texts for registry entries 1–70: I read the registry table (ids, priorities,
  cooldowns, caps) and the selection algorithm in full, but skimmed the 220-line verbatim text
  block at §41.18.8 rather than reading every string. Nothing in my classification depends on the
  individual strings.
* Whether the 2.1.259 binary's shortened refusal string (`"/<cmd> isn't available in this
  environment."`, live) has fully replaced the 2.1.257 long form documented at §41.22.3
  (`"…opens an interactive panel and isn't available in this environment. Run it from the Claude
  Code terminal instead."`) or whether both are still emitted on different paths.
