<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# 42 — Input and keybindings: TUI-vs-headless gap inventory

Area: `42-input-keybindings`. Source chapter: `SPEC/42-input-and-keybindings.md` (read in full).
Headless baseline: `SPEC/45-headless-and-sdk-protocol.md` §45.9, §45.15, §45.17; live 2.1.259
handshake in `/tmp/afleet-gap/init-dump.json`.

Classification letters are the brief's: **P** parity via protocol, **R** rebuild client-side,
**D** data gap, **X** unreachable, **T** terminal-specific.

One structural fact governs almost every row below: **the entire keybinding layer is an Ink
React layer.** `KeybindingSetup` mounts inside the renderer [`chunk-0w8tcdfc.js:4789`], the
handler registry is a React context [`chunk-8pf2x3zw.js:330193`], and the decoder is driven by
`stdin` in raw mode [`chunk-teb05yv9.js:719898`]. A headless process has none of it: no
`keybindings.json` is loaded, no action is ever dispatched, no editor buffer exists. So the
default answer for this whole chapter is **R** — the GUI owns input entirely and reaches the
CLI only through `user` / `bash_command` frames and control requests. The interesting rows are
the ones where that is *not* enough (D/X) and the ones where the wire already carries the
answer (P).

---

## 42.2–42.4 Input plumbing, contexts and the chord grammar

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Raw-mode stdin decoder, UTF-8 reassembly, ~70 named keys | §42.2 steps 1–5, `Jp()` [`chunk-teb05yv9.js:718913`] | none — stdin carries JSON frames | T | AppKit delivers `NSEvent` with real modifier bits. The GUI skips the entire decoder. |
| Bracketed paste (DEC 2004), `isPasted` synthetic key, unterminated-paste flush | §42.2 step 3 [`chunk-teb05yv9.js:718822`] | none | T | Native `NSPasteboard` paste is strictly better: typed content, no envelope, no focus-report contamination (`rawEmpty` / `rawEndedWithFocusTail`, §42.15.1). |
| Terminal focus in/out (`\x1b[I` / `\x1b[O`), mouse and wheel events | §42.2 step 6 | none | T | |
| `ctrl+z` suspend → `SIGTSTP`, `SIGCONT` restore; suppressed when `CLAUDE_CODE_SESSION_KIND=bg` | §42.2 step 9, §42.21.6 [`chunk-teb05yv9.js:721392`] | none | T | A GUI has no process-suspend affordance and needs none. Do **not** send SIGTSTP to the child. |
| Keystroke normalisation: `alt`≡`meta`, `enter`→`"\n"`, shift inferred from an upper-case char, macOS Option-glyph un-mangling (`†`→`t`) | §42.2 step 10, §42.3.1 [`chunk-h5f2rmvb.js:533661`] | none | T | These are terminal artefacts. A GUI gets true `alt` vs `cmd` and real shift state — see "exceeds the TUI" in §42.7 below. |
| Chord grammar: space-separated keystrokes, greedy prefix match, 1000 ms pending timeout, `escape` cancels a pending chord | §42.3.4, §42.10.2 [`chunk-0w8tcdfc.js:4768`] | none | R | If the GUI honours user chords it must reproduce the 1000 ms window and the escape-cancels rule, or users' `ctrl+x …` chords misfire. |
| Chord display formatting (`opt`/`cmd` on macOS, `Esc`, `↑↓←→`, `PageUp`); `O$()` treats iTerm2 / Apple Terminal as "macOS" | §42.3.3 [`chunk-h5f2rmvb.js:533523`, `:533546`] | none | R | A GUI should render `⌥ ⌘ ⇧ ⌃` glyphs instead; strictly better. |
| 23 contexts (`Global`, `Chat`, `Autocomplete`, `Confirmation`, `Help`, `ProactivityMenu`, `Transcript`, `HistorySearch`, `Task`, `ThemePicker`, `Settings`, `Tabs`, `Attachments`, `Footer`, `MessageSelector`, `DiffDialog`, `DiffPanel`, `ModelPicker`, `EffortSlider`, `Select`, `Plugin`, `Scroll`, `Agents`), `Global` always appended | §42.4, §42.10.3 [`chunk-1kg58a1a.js:112105`] | none | R | Only matters if the GUI honours `keybindings.json`; it must map each context onto its own focus regions. `ProactivityMenu` has no defaults and its dispatcher is a stub (§42.23.3) — safe to ignore. |
| `swallowAll` scopes, `ActionEvent.consume()`, pre-dispatch handlers, `singleKey:false` | §42.10.4–5, §42.11 | none | T | Internal; listed only because `singleKey:false` is what makes `enter` reach the editor (§42.20.1) and what the tmux `ctrl+b` accommodation flips (§42.23.2). |

---

## 42.5–42.6 The action catalogue and the default binding table

145 action ids in 27 namespaces [`chunk-1kg58a1a.js:112109`], plus the open-ended
`command:<name>` family. **No action id ever crosses the wire**; every row is what the GUI must
provide and how it reaches the CLI. Grouped by the context each action's default binding lives
in (§42.6). Where a whole family is mechanically identical the actions are listed together;
every one of the 145 ids appears somewhere below.

### Global

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `app:interrupt` — `ctrl+c` | §42.6.1, §42.21.4. Layer 1 aborts the turn / kills background agents; layer 2 first press clears the input and arms the exit hint, second press within 800 ms exits | `interrupt` control request (`reason?`, `cancel_queued?` → `still_queued`, `cancelled?`) [`chunk-2rhzyjym.js:177170`] | R | The GUI needs a Stop button, not a two-press ladder. `interrupt` aborts the turn and disarms non-durable auto-react wiring but **does not stop tasks** (`mz(..., {durable:false})` skips the `rm()` stop, [`chunk-eeds86e2.js`→`cli.pretty.js:467209`]). |
| `app:exit` — `ctrl+d` | §42.6.1, §42.21.5. On an empty buffer, first press shows `Press Ctrl-D again to exit`, second exits; on a non-empty buffer it is forward-delete | close stdin ("finish the current turn and exit", §45.15) or the `end_session` control request [`chunk-2rhzyjym.js:177192`] | R | Two distinct exits: closing stdin drains the turn; `end_session` aborts and marks queued commands `discarded` via `command_lifecycle`. |
| `app:toggleTodos` — `ctrl+t` | §42.23.1. Flips the footer panel to the tasks view [`chunk-bq8epagv.js:395308`] | todo state arrives on the wire (`task_*` frames, `background_tasks_changed`); panel visibility is GUI state | R | Pure view toggle. No `/config` row exists for it even though `todoFeatureEnabled` is in the schema (§42.24.1). |
| `app:toggleTranscript` — `ctrl+o` | §42.23.1. Turns off brief-only mode, else flips the full transcript screen | GUI renders its own transcript from `assistant` / `user` / `system` frames | R | |
| `app:toggleBrief` — `ctrl+shift+b` | §42.23.1, §42.24.3. Flips `isBriefOnly`, the same state `/focus` toggles | `apply_flag_settings` with the brief-transcript flag [`chunk-2rhzyjym.js:178054`]; `/focus` itself is `local-jsx` + `requires: {ink:true}` and absent from the live headless command list | R | The *state* is settable; the *view* is the GUI's to draw. |
| `app:toggleReplTab` — unbound | §42.23.1 [`chunk-bq8epagv.js:433019`] | none | T | Tabbed-REPL affordance, no default chord. |
| `app:toggleDiffNoiseFilter`, `app:toggleDiffPreSession`, `app:cycleDiffBase` (`ctrl+x b`, DiffPanel), `app:diffFileListUp`/`Down` (`ctrl+up`/`ctrl+down`/`meta+up`/`meta+down`) | §42.6.1–2, §42.23.1 | `get_workspace_diff` control request returns the diff text [`chunk-2rhzyjym.js:177592`]; `vcs_state_changed` / `code_change_published` frames signal changes | R | The diff *content* is on the wire; the panel, its file list, the tests filter, the pre-session toggle and the base selector are all GUI-side. A native diff view can far exceed the TUI panel here. |
| `app:toggleTerminal` — unbound | §42.23.1. Handler is an empty function [`chunk-bq8epagv.js:395298`] | none | X | Dead in 2.1.257 (chapter's own open question). Ignore. |
| `app:redraw` — unbound | §42.23.1. `forceRedraw()` | none | T | Meaningless in a retained-mode GUI. |
| `app:openArtifact` — `ctrl+]` | §42.23.1. Opens the most recently registered artifact frame URL, auto-collapsing its footer indicator after 15 000 ms [`chunk-bq8epagv.js:408318`] | no artifact-URL frame is in the §45.9.1 stdout catalogue | D | Cross-ref chapter 44. From this chapter's angle: the key gesture is trivial, the artifact registry is not on the wire. Workaround: the GUI hosts the artifact webview itself and tracks URLs from the artifact tool's own output. |
| `history:search` — `ctrl+r` | §42.6.1, §42.19.4 | read `~/.claude/history.jsonl` from disk | R | See §42.19. |
| `strip:jump1`…`jump9`, `strip:next`, `strip:previous`, `strip:toggle`, `strip:new` (13) | §42.5, §42.23.3. No default binding; hidden from the `keybindings-help` skill | none | X | Unbindable-in-practice, undocumented, no observable handler. List and ignore. |

### Chat

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `chat:submit` — `enter` | §42.6.3, §42.20.1. Registered with `singleKey:false` while `enter` still resolves to `chat:submit`, so the key falls through to the editor's `return` handler, which chooses newline vs submit [`chunk-bq8epagv.js:413974`] | `user` stdin frame with `uuid`, `origin:{kind:'human'}`, `shouldQuery` (§45.15.1) | P | The GUI must stamp `origin:{kind:'human'}` — an absent origin fails closed at strict `isHuman()` gates. `shouldQuery:false` appends without starting a turn and merges into the next querying message. |
| `chat:queueSubmit` — `ctrl+x enter` | §42.20.5. Sets `wait:true` on the queue item so the submission parks for the next drain, and bypasses the "suggestions showing, do not submit" guard | `user` frame with `priority` (`now`/`next`/`later`, default `next`) [`chunk-1kg58a1a.js:48042`] | R | Mid-turn `submit` and `queueSubmit` are identical (both queue). Idle, only `queueSubmit` parks. `priority` is the nearest wire control; there is no `wait` field. |
| `chat:newline` — `ctrl+j` | §42.21.11. Snapshots undo, splices `\n`, advances the caret | a `\n` in the frame's text | R | Free in a native multi-line text view. |
| `chat:cancel` — `escape` | §42.21.2. Precedence: running turn → queue pull-back → passive background work → (never) background agents, because Escape passes `suppressBackgroundAgentKill:true` | `interrupt`; `cancel_async_message {message_uuid}` → `{cancelled}` [`chunk-2rhzyjym.js:177389`] | R | Rebuild the *ladder*, not the key. Both arms exist on the wire; the ordering policy is the GUI's. |
| `chat:killAgents` — `ctrl+x ctrl+k`, double-press within **3000 ms** (the one gesture that is not 800 ms) | §42.21.8. Stops every background agent, clears the whole command queue (writing dropped commands to history, undo disarmed), stops live-document watches, disarms artifact auto-replies, enqueues a disclosure notification | closest: `interrupt {cancel_queued:true}` (clears the queue, returns the `cancelled` uuid list) **plus** one `stop_task {task_id}` per live task [`chunk-2rhzyjym.js:178235`] | **D** | No single control request. Task ids come from `task_started`/`task_updated`/`background_tasks_changed` frames. Not reachable at all: the live-document watch teardown, the artifact auto-reply disarm and the disclosure notification. Also note `interrupt` alone does *not* stop tasks. |
| `chat:cycleMode` — `shift+tab` | §42.22 | `set_permission_mode {mode, ultraplan?}` → `{mode?}` [`chunk-2rhzyjym.js:177259`] | R | See §42.22 below for the ring and its availability gap. |
| `chat:modelPicker` — `meta+p` | §42.6.3 | `set_model {model?, system_prompt?}`; `list_models`; `initialize.models` (5 in the live dump) | P | Model list and current model are on the wire. |
| `chat:fastMode` — `meta+o` | §42.6.3 | `/fast` is in the live headless command list; `initialize.fast_mode_state` / `fast_mode_disabled_reason` report state (live dump: `"off"` / `"sdk_opt_in_required"`) | P | Note the live 2.1.259 handshake reports fast mode disabled with reason `sdk_opt_in_required` for an SDK-driven session — a GUI must render that, not a dead toggle. |
| `chat:thinkingToggle` — `meta+t` | §42.6.3 | `set_max_thinking_tokens {max_thinking_tokens?, thinking_display?}` [`chunk-2rhzyjym.js:177289`]; `thinking_tokens` frame reports usage | P | `thinking_display` is `"summarized"` \| `"omitted"`. |
| `chat:workflowKeywordToggle` — `meta+w` | §42.5, §42.6.3. Toggles the session's ultracode keyword state [`chunk-bq8epagv.js:412901`] | `apply_flag_settings {settings:{ultracode:…}}` [`chunk-2rhzyjym.js:178054`]; the Remote-Control bridge allowlists exactly `effortLevel` and `ultracode` for this path [`chunk-2x0p0v0q.js:183522`, `:183811`] | R | Cross-ref chapter 40 for semantics. |
| `chat:undo` — `ctrl+_`, `ctrl+-`, `ctrl+shift+-`, `ctrl+shift+_` | §42.12.7, §42.21.11. 50-entry ring, 1000 ms coalescing, **no redo**, restores text + cursor + `pastedContents` together | none needed | R (trivial) | A native `NSTextView` gives undo *and* redo for free, so the GUI strictly exceeds the TUI here. The only thing to add is coupling `pastedContents` to the undo entry so an undone paste drops its placeholder backing. |
| `chat:externalEditor` — `ctrl+g`, `ctrl+x ctrl+e` | §42.21.9. `$VISUAL` → `$EDITOR` → first of `code`/`vi`/`nano`; `code -w` / `subl --wait`; temp file `<tmpdir>/claude-prompt-<16 hex>.md`; optional last-50-lines reference block gated on `externalEditorContext`; on failure the draft is untouched and one of three messages is shown | none | R | A GUI can offer "open draft in $EDITOR" by spawning the editor itself; nothing here touches the CLI. Or drop it — a real text view supersedes it. |
| `chat:stash` — `ctrl+s` | §42.21.10. **Single slot**, in-memory only, not a stack, not on disk; auto-restores when a slash command or empty submit leaves the draft blank, with the notification `Draft restored` | none | R (trivial) | A GUI can keep per-tab drafts persistently — strictly better than one slot. |
| `chat:imagePaste` — `ctrl+v` (`alt+v` on Windows/WSL; WSL keeps `ctrl+v` too) | §42.15.8, §42.21.12. Reads the clipboard directly; per-platform detection (`osascript` `«class PNGf»`, `xclip`/`wl-paste`, PowerShell `Clipboard`); converts/resizes to the model's image limits; failure message differs when SSH'd | `user` frame `image` content blocks (§45.15.1); `image_paste_ids` field exists on the frame | P | Native `NSPasteboard` image paste is far better. The GUI must still do the resize/encode itself — the CLI does it only on the `ctrl+v` path. |
| `chat:clearInput` — `ctrl+l`; `chat:clearScreen` — `cmd+k` | §42.21.7. **Both are wired to the same force-redraw handler and neither clears the input** [`chunk-bq8epagv.js:414012`] | none | T | A known 2.1.257 wiring bug (chapter open question). Do not replicate; give the GUI a real clear-input. The buffer is actually cleared by double-Escape or the first `ctrl+c`. |
| `chat:cycleProactivity`, `chat:attentionUp`, `chat:attentionDown` | §42.5. No default binding, hidden from the docs skill | none | X | |
| `voice:pushToTalk` — bare `space` in `Chat` | §42.5, §42.6.3 | chapter 43 | R | Listed here only because it occupies bare `space` in the Chat context and because the validator warns when a user binds it to a bare letter (§42.8.2). |
| `history:previous` / `history:next` — `up` / `down` | §42.6.3, §42.19.3. **Declared but no component registers a handler**; recall lives in the editor's own `up`/`down` code, so rebinding removes the default without moving the behaviour | read `~/.claude/history.jsonl` | R | A faithful GUI should not replicate this quirk. |
| `command:<name>` bindings | §42.7.3. Runs `/<name>` as if typed, with a no-op editor handle so the draft is untouched; restricted to the `Chat` context by the validator; telemetry collapses to `command:custom` | send the slash command as the text of a `user` frame, subject to §45.29.1 (`prompt` works unless `disableNonInteractive`; `local` only with `supportsNonInteractive:true`; `local-jsx` always refused) | R | **A user's `command:` bindings can point at commands the headless CLI refuses.** The GUI should check the name against `initialize.commands` (102 entries live) and grey out or locally implement the rest. |

### Autocomplete, Confirmation, Task, MessageSelector

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `autocomplete:accept` (`tab`), `dismiss` (`escape`), `previous` (`up`), `next` (`down`); also hand-wired `ctrl+n`/`ctrl+p` | §42.6.4, §42.17.7 | none | R | Menu is entirely client-side; see §42.17. |
| `confirm:yes` (`y`, `enter`), `no` (`n`, `escape`), `previous` (`up`), `next` (`down`), `nextField` (`tab`), `previousField` (unbound), `toggle` (`space`), `cycleMode` (`shift+tab`) | §42.6.6, §42.22.6. In the tool-permission dialog `cycleMode` selects "accept for the rest of this session" or toggles the focused feedback field; in plan approval it is "approve with this feedback" | the dialog itself arrives as the `can_use_tool` control request (A→C) with `permission_suggestions`, `blocked_path`, `decision_reason`, `default_to_no`, `matched_ask_rule`, `title`, `display_name` (§45.17); the GUI answers with the §45.19 union | P | Everything the TUI dialog shows is in the request payload. Keyboard navigation of the GUI's own sheet is native. |
| `permission:toggleDebug` — unbound | §42.5 | none | X | |
| `task:background` — `ctrl+b` **and** `ctrl+x ctrl+b` | §42.23.2. Backgrounds **every** eligible foreground task, not just one (`ZM`, [`chunk-1kg58a1a.js:128023`]) | `background_tasks` control request: with `tool_use_id` backgrounds that one (`Ode`), **without one it calls the identical `ZM`** [`chunk-2rhzyjym.js:178247`] | P | Exact parity, including the "background all" semantics. Refused when background tasks are disabled. |
| tmux `ctrl+b` prefix accommodation | §42.23.2. Under tmux the advertised chord doubles each `ctrl+b`; `CLAUDE_CODE_KB_COHESION_FIXES` drops `ctrl+b` out of the single-key pass unless the user rebound the action; four hint forms | none | T | A GUI has no prefix-key conflict. Drop the whole accommodation. |
| `messageSelector:up`/`down`/`top`/`bottom`/`select` | §42.6.16, §42.21.3 | `rewind_conversation` control request (unpublished schema; request `target_message_uuid`, `interrupt_if_running?`, `last_seen_user_message_uuid?`; response `{rewound, prefillText, precedingAssistantUuid, error?}`) [`chunk-2rhzyjym.js:177455`] | R | See §42.21.3 for the option menu and what is missing. |

### Contexts that a GUI supersedes wholesale

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `select:next`/`previous`/`pageUp`/`pageDown`/`first`/`last`/`accept`/`cancel` (8) | §42.6.19 | none | T | Native list views. |
| `scroll:pageUp`/`pageDown`/`lineUp`/`lineDown`/`top`/`bottom`/`halfPageUp`/`halfPageDown`/`fullPageUp`/`fullPageDown` (10), incl. synthetic `wheelup`/`wheeldown` key names | §42.6.12, §42.6.8 | none | T | Native scroll views. |
| `selection:copy`/`clear`/`extendLeft`/`extendRight`/`extendUp`/`extendDown`/`extendLineStart`/`extendLineEnd` (8); `copyOnSelect` setting | §42.6.12, §42.24.1 | none | T | Native text selection. `copyOnSelect` is fullscreen-renderer-only in the TUI; a GUI should follow macOS convention instead. |
| `transcript:toggleShowAll` (`ctrl+e`), `transcript:exit` (`ctrl+c`/`escape`/`q`) | §42.6.8 | frames are on the wire; the view is GUI-side | R | |
| `historySearch:next` (`ctrl+r`), `accept` (`escape`/`tab`), `cancel` (`ctrl+c`), `execute` (`enter`), `cycleScope` (`ctrl+s`) | §42.6.9, §42.19.4 | `~/.claude/history.jsonl` on disk | R | Semantics in §42.19.4. Note `execute` (Enter) **submits the match immediately** rather than accepting it into the draft, and `cancel` restores the pre-search snapshot rather than just closing. |
| `tabs:next`/`previous` | §42.6.7 | none | T | |
| `attachments:next`/`previous`/`remove`/`exit` | §42.6.14 | image blocks on the `user` frame | R | Native attachment chips. |
| `footer:up`/`down`/`next`/`previous`/`openSelected`/`clearSelection`/`close`/`dismiss` (8) | §42.6.15 | `initialize.footer_indicator` is on the wire | R | Chapter 41 owns the footer's content; the keyboard focus ring is a GUI concern. |
| `diff:dismiss`/`previousSource`/`nextSource`/`back`/`viewDetails`/`previousFile`/`nextFile` (7) | §42.6.17 | `get_workspace_diff` | R | |
| `modelPicker:decreaseEffort`/`increaseEffort`/`thisSessionOnly`; `effortSlider:thisSessionOnly` | §42.6.18 | `set_model`, `apply_flag_settings {effortLevel}`, `/effort` | R | "This session only" is the `mainLoopModelForSession` distinction — the GUI must expose it or it will silently persist model changes. |
| `theme:toggleSyntaxHighlighting`, `theme:editCustom` | §42.6.11 | `set_color` control request sets the session accent only | R | Theming is GUI-native; chapter 41. |
| `settings:search`/`retry`/`periodDay`/`periodWeek`/`sortByTokens` (5) | §42.6.5 | `get_settings` / `update_settings` (localSettings only), `get_usage` | R | |
| `plugin:toggle`/`install`/`favorite` | §42.6.20 | `reload_plugins`, `plugin_install` frame | R | Chapter 30. |
| `agents:switchView`, `agents:togglePin` | §42.6.20 | `initialize.agents` (11 live) | R | |
| `help:dismiss` (`escape`) | §42.6.13 | none | T | |
| `proactivityMenu:previousLevel`/`nextLevel`/`previousMode`/`nextMode`/`dismiss` (5) | §42.5, §42.22.4. Dispatcher is a stub returning `false` | none | X | Dead in this build. |

---

## 42.7–42.9 `~/.claude/keybindings.json`, validation, and the help skill

The single most consequential decision for the GUI in this chapter: **users have real
`keybindings.json` files and the headless CLI never reads them.**

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| The file itself: `~/.claude/keybindings.json` (or `$CLAUDE_CONFIG_DIR/keybindings.json`), **no project scope**, absent by default | §42.7.1 [`chunk-1kg58a1a.js:112316`] | not on the wire; readable straight from disk | R | The GUI reads the same path. Schema is public (`https://www.schemastore.org/claude-code-keybindings.json`). |
| Hot reload: chokidar watch with `awaitWriteFinish` 500 ms, poll 200 ms, `usePolling` 2000 ms, `atomic:true`; `add`/`change` reload, `unlink` reverts to defaults; edits take effect with no restart | §42.7.1 [`chunk-1kg58a1a.js:112494`] | fs watch in the GUI | R | Cheap to match and users expect it. |
| Merge order: user blocks **appended after** defaults, flattened, **last match wins**; `null` unbinds *and consumes* the key (does not fall through); adding a chord does not remove the default | §42.7.4 [`chunk-1kg58a1a.js:112469`, `chunk-h5f2rmvb.js:533563`] | — | R | Get this exactly right or a user's "move ctrl+g to ctrl+e" file behaves differently in the GUI than in the terminal. |
| Chord normalisation for duplicate/reserved detection: lower-case, alias maps (`control`→`ctrl`, `option`/`opt`/`meta`→`alt`, `command`/`cmd`/`super`/`win`→`cmd`), **modifiers sorted alphabetically**; asymmetric with the matcher's own folding (`meta`→`meta`, `cmd`→`super`) | §42.3.2 [`chunk-1kg58a1a.js:112120`] | — | R | |
| Gating: `tengu_keybinding_customization_release` (default true) and the safe/simple-mode capability `ao("keybindings")`; when off, defaults only and no watcher | §42.7.1 | none | R | The GUI cannot read Statsig gates; assume enabled. |
| Validation: 5 structural errors, 10 per-block conditions, the Levenshtein-≤-2 "Did you mean" suggester, the raw-JSON duplicate-key regex pass, the normalised duplicate pass, and the reserved-key tables — all advisory, written to the debug log only | §42.8 | none | R | **Where a GUI exceeds the TUI:** surface these in a real settings UI instead of a debug log. |
| Reserved-key tables: `ctrl+c`, `ctrl+d`, `ctrl+m`, `ctrl+[`, `ctrl+i`, `ctrl+h`, `capslock` (non-rebindable); `ctrl+z`, `ctrl+\` (terminal); `cmd+c/v/x/q/w/tab/space` (macOS) | §42.8.5 [`chunk-1kg58a1a.js:112113`] | none | T→R | **Most of this list is a terminal artefact.** `ctrl+m`≡Enter, `ctrl+[`≡Esc, `ctrl+i`≡Tab, `ctrl+h`≡Backspace are byte-level collisions a native app does not have; `capslock` *is* deliverable to an `NSEvent` handler. A GUI can honour bindings the terminal refused — a genuine superset. But `cmd+c/v/x/q/w` remain real macOS system keys and must stay reserved. |
| `command:` value regex `/^command:[a-zA-Z0-9:\-_]+$/`, warning when outside the `Chat` context | §42.7.2, §42.8.2 | — | R | |
| The `keybindings-help` model skill (`userInvocable:false`, `allowedTools:["Read"]`, enabled with `BF()`) — 8 fixed sections plus 3 tables generated from the live binding set | §42.9 [`chunk-bkee3xt2.js:387062`] | the skill ships inside the binary and is model-invocable in any mode, headless included | P | Its generated "Available Actions" table has known artefacts (`confirm:no` shows context `Settings`; `select:next` lists six keys) because `is()` collects keys across contexts but reports the first context seen. If the GUI writes bindings, it inherits whatever the model produces from this skill. |
| Telemetry `tengu_keybinding_fired`, `tengu_keybinding_fallback_used`, `tengu_custom_keybindings_loaded` | §42.25 | none | T | No user-visible effect; noted for completeness only. |

---

## 42.12 The prompt editor buffer

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Immutable `(measuredText, offset, column)` cursor rebuilt every keystroke | §42.12 [`chunk-ha6de7vj.js:536911`] | none | R (trivial) | `NSTextView` / `NSTextStorage`. |
| `keybindingFlavor`: `classic` (default) vs `readline` — differs in `ctrl+w`, `alt+b`, `alt+f`, `alt+d`, and the word class for `ctrl`/`opt`+Arrow and `opt`/`ctrl`+Backspace | §42.12.2 [`chunk-ha6de7vj.js:536903`]; the setting's own text is the normative statement [`chunk-ejcy5qcd.js:488712`] | setting readable via `get_settings.effective` **only when set** (the live dump shows it absent, i.e. defaulted) | R | macOS text views already ship readline-ish emacs bindings (`ctrl+a/e/k/y`, `opt`+arrows). Honour the setting only if the GUI wants terminal-identical word motion. |
| Control-key map: `ctrl+a/b/c/d/e/f/h/k/n/p/u/w/y` and `alt+b/f/d/y` | §42.12.3 | none | R (trivial) | macOS gives most of these free; `ctrl+k`/`ctrl+y` too. |
| **Kill ring**: `ctrl+k`/`ctrl+u`/`ctrl+w`/`alt+d` + modified deletions push with `append`/`prepend`; any other key interrupts the sequence; `ctrl+y` yanks, `alt+y` yank-pops; after a `ctrl+u` killing ≥ 3 chars a 5000 ms hint `Ctrl+Y to paste deleted text` | §42.12.5 [`chunk-ha6de7vj.js:537860`] | none | R (trivial) | AppKit's own kill ring covers `ctrl+k`/`ctrl+y`; `alt+y` yank-pop and the append/prepend sequencing are not free but are also near-invisible to most users. Low priority. |
| **Undo**: 50 entries, 1000 ms coalescing (deferred, not dropped), identical text skipped, **index only decrements — no redo**; explicit immediate snapshots before paste, newline, external-editor replacement, queue pop and paste expansion; vim bypasses the debounce per NORMAL/VISUAL edit | §42.12.7, §42.21.11 [`chunk-bq8epagv.js:412495`, `:411406`] | none | R (trivial) | Native undo/redo is a superset. Only carry over the rule that an undo restores `pastedContents` alongside the text. |
| Named-key switch, incl. `tab` returning `undefined` (the editor never consumes Tab) and the swallowed set (`insert`, `clear`, `enter`, `center`, `mouse`, `f1`–`f12`) | §42.12.4 | none | R | |
| The `!`-at-start rule: typing `!` at offset 0 inserts it and steps the caret left | §42.12.4 [`chunk-ha6de7vj.js:538067`] | none | R | Only matters if the GUI replicates bash mode inline (see §42.16.1). |
| Paste placeholders are atomic to the cursor (`placeholderContaining`, `snapOutOfPlaceholder`) — arrows and Backspace jump `[Pasted text #1 +40 lines]` whole | §42.12.1 [`chunk-ha6de7vj.js:537034`] | none | R | If the GUI shows placeholder chips, make them atomic attachments — better than text. |
| **Left-arrow guard**: `←` on an empty input detaches from an attached agent or goes back to the agents list, behind a `fire`/`arm`/`absorb`/`attach-arm`/`attach-absorb`/`reject` state machine; 3000 ms arm window, hints `Press ← again to go back to agents` / `Ambiguous ←, press again to detach`; `reject` when the key was not a `soloKeypress` (arrow burst); gate `tengu_left_arrow_editing_guard`, setting `leftArrowOpensAgents` (default true, has a `/config` row) | §42.12.6 [`chunk-ha6de7vj.js:536795`] | none | T | The whole mechanism exists because a terminal cannot tell a human keypress from a pasted arrow burst. A GUI has a back button. Drop it. |

---

## 42.13 Editor modes, vim, and `/vim`

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `editorMode: "normal" \| "vim"`, default `normal`, written to `~/.claude/settings.json`, legacy fallback `~/.claude.json`, legacy value `"emacs"` coerced to `"normal"` | §42.13.1, §42.24.1 | `get_settings.effective.editorMode` (live dump: `"normal"`); `/config` is in the live headless command list as `type:"local"`, `supportsNonInteractive:true`, `argumentHint:"key=value"` | P (read) / R (write) | `update_settings` writes localSettings only, so a GUI changing the *user* default writes `~/.claude/settings.json` itself. |
| Full vim layer: NORMAL / INSERT / VISUAL / VISUAL LINE, the §42.13.3 motion table, `d`/`c`/`y` operators with doubling and count multiplication (`3d2w` = 6 words), 15 text-object pairs (`iw aw i" a( ib aB i< …`), counts clamped at 10 000, **one unnamed register** on the session scratch, indent step of exactly two spaces, dot-repeat over 18 recorded change kinds, **no REPLACE mode**, `r` as a one-shot | §42.13.2–4 | none | R | This is the single largest client-side rebuild in the chapter. Explicitly *not* implemented in the TUI either: `%`, `{}`, `()`, `H/M/L`, `n/N/*/#`, `/`/`?` search, `\|`, `+`/`-`/`_`, `ge/gE`, `[[`/`]]`, marks, `g_`, `g0`, `g$`, `it/at`, `is/as`, `ip/ap`. A GUI that ships vim should match this scope, not exceed it silently. |
| `vimInsertModeRemaps` (e.g. `{"jj":"<Esc>"}`): exactly two printable non-space NFC chars, `<Esc>` the only target, 1000 ms window, cursor must not have moved between the two | §42.13.5 [`chunk-y7d4rb5m.js:823036`] | setting readable from disk | R | |
| Mode indicator `-- INSERT --` / `-- VISUAL --` / `-- VISUAL LINE --` (dim; NORMAL renders nothing), suppressed during history search and by `statusLine.hideVimModeIndicator`; the same value is fed to the status line as `vim.mode` | §42.13.6 | none | R | |
| **No per-mode cursor shape**: the harness never emits DECSCUSR; the cursor is a reverse-video block in every mode | §42.13.6 | — | T | A GUI *should* exceed this (bar in insert, block in normal) — a rare case where matching the TUI would be worse. |
| Vim ↔ keybinding interaction: `chat:cancel` is deactivated while vim is on and the mode is not NORMAL, so `escape` in INSERT/VISUAL is a vim key and only NORMAL-mode `escape` interrupts; `?` opens the shortcut overlay only in INSERT; `/` in NORMAL opens the prompt-history picker (hint `Esc i / for slash commands`); `k`/`j` at the buffer edges fall through to history; backspace-removes-attachment is INSERT-only | §42.13.7 | none | R | If the GUI ships vim mode it must reproduce this precedence or Escape becomes ambiguous. |
| `/vim` | §42.13.8, §42.24.4. A hidden `local-jsx` redirect behind `tengu_maple_sundial` (**default off**), so it does not exist in a stock build; when on it prints `/vim moved → Editor mode in /config` and opens the settings dialog | absent from the live headless command list | X | The three working routes are the `/config` Editor-mode row, `/config editor=vim`, and editing `settings.json`. |

---

## 42.14 Multi-line entry

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Backslash + Enter: with `multiline` on and `disableBackslashReturn` off, a trailing `\` is deleted and replaced by a newline; sets `hasUsedBackslashReturn` in the legacy config | §42.14 [`chunk-ha6de7vj.js:537909`] | none | T | Exists because plain terminals cannot deliver Shift+Enter. A GUI should not replicate it — it would eat a legitimate trailing backslash. |
| Shift+Enter / Option+Enter: the key event carrying `meta` or `shift` (terminals send ESC then CR) | §42.14 | none | P→R | Native and unambiguous in a GUI. |
| Apple Terminal shift probe: `TERM_PROGRAM === "Apple_Terminal"` plus a native `isModifierPressed("shift")` addon call, pre-warmed on mount | §42.14.1 [`chunk-ha6de7vj.js:537803`] | none | T | |
| `ctrl+j` (`chat:newline`) | §42.14 | none | R | |
| `enter` (as opposed to `return`) always inserts a literal `\n` — the bracketed-paste-newline path | §42.14 | none | T | |
| `/terminal-setup`: writes `shift+enter` → `sendSequence "\x1B\r"` for VS Code/Cursor/Windsurf, a TOML block for Alacritty, `["terminal::SendText","\x1B\r"]` for Zed, `useOptionAsMetaKey` for Apple Terminal; iTerm2/WezTerm/Ghostty/Kitty/Warp/Windows Terminal are never touched; records `shiftEnterKeyBindingInstalled` / `optionAsMetaKeyInstalled`; fallback note advertises backslash+return | §42.14.2, §42.24.5 [`chunk-ha6de7vj.js:536538`] | `local-jsx` with `requires:{ink:true}`; absent from the live headless command list | **T + X** | Superseded outright by the GUI. |
| Onboarding hints `Press Option+Enter to send a multi-line message` / `Press Shift+Enter…` and `Run /terminal-setup to enable …`, suppressed once the flag is set and `numStartups > 3` | §42.14.2 [`chunk-chr1kh62.js:452591`] | none | T | Do not port. |

---

## 42.15 Paste

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Two detection paths: bracketed paste, or any unmodified key whose printable text exceeds **800** chars (`Fre`) treated as a paste | §42.15.1 [`chunk-ha6de7vj.js:538259`] | none | T | |
| `isPasting` flag → footer shows `Pasting…`; the Enter that ends a paste is buffered and replayed a tick later so a trailing clipboard newline does not submit | §42.15.2 [`chunk-ha6de7vj.js:538254`] | none | T | Native paste is atomic; the whole race disappears. |
| Paste splitting on newlines and on the boundary before an absolute path; fragments that look like image paths are read as images; a macOS `screencaptureui` `/TemporaryItems/` path that fails to read falls back to the clipboard image; on macOS/WSL an *empty* paste with an image handler means "the clipboard holds an image" (50 ms debounce) | §42.15.2 | native pasteboard type negotiation | R | The GUI reads `NSPasteboard` types directly — strictly better and no heuristics. |
| **Text placeholders**: paste is normalised (CRLF/CR → LF, tabs → 4 spaces) then replaced when it exceeds 800 chars **or** more than `max(0, min(rows-10, 2))` newlines (i.e. 2 on any terminal ≥ 12 rows). Forms: `[Pasted text #N]`, `[Pasted text #N +M lines]`, `[Image #N]`, `[Audio #N]`, `[...Truncated text #N +M lines...]` | §42.15.3 [`chunk-1kg58a1a.js:47350`, `:47158`] | the GUI sends the **expanded** text in the `user` frame | R | Placeholders exist because a terminal cannot render a collapsible chip. A GUI should render attachment chips and send the real content — an unambiguous improvement. **But** history interop (§42.19) requires writing the placeholder form back. |
| Re-paste expands: pasting the same text over its own placeholder restores the literal text instead of minting a second id; a dim 8000 ms footer hint `paste again to expand` appears while that is possible, gated at 100 000 chars | §42.15.4 [`chunk-bq8epagv.js:412738`, `:410029`] | none | R | With chips, replace this with an explicit expand/preview affordance. |
| **Oversized draft truncation**: a whole draft over **10 000** chars keeps 500 chars at each end and excises the middle into `[...Truncated text #N +M lines...]`, once per non-empty draft | §42.15.5 [`chunk-bq8epagv.js:411900`] | none | R | A GUI has no line budget and should not truncate the draft at all. |
| Missing-backing repair at submit: `<label> #<id> is no longer available and was removed from the prompt` (plural form too), under the notification key `pasted-text-unavailable` | §42.15.5 [`chunk-1kg58a1a.js:47420`] | none | R | |
| Expansion at submit time (`x9`, reverse index order) yielding `{stripped, expanded, removed}`; ids are positive integers < 2^32 | §42.15.6 | the GUI does the expansion before writing the frame | R | |
| Paste storage: `{id, type:"text"\|"image", content?, contentHash?, mediaType?, filename?}`; content > 1024 chars is content-addressed into the `paste-cache` directory, capped at 10 MB | §42.15.7 [`chunk-1kg58a1a.js:47346`, `:47404`] | on disk | R | Only needed for history interop. |
| `onAudioPaste` is threaded through the input component but the chat passes `undefined` — **no audio paste path is reachable in 2.1.257** despite `[Audio #N]` existing | §42.15.2 | — | X | Do not build it. |

---

## 42.16 The four input modes `!` `#` `@` `/`

The prompt has exactly **two** modes — `bash` and `prompt` [`chunk-33q5tpxk.js:186175`]. `@` and
`/` are autocomplete triggers, and `#` is a Slack-channel completer, not memory.

### 42.16.1 `!` — bash mode, and how the headless `bash_command` frame differs

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| Entering: `!` at offset 0 never reaches the buffer — either exactly one char was inserted (the `!` is swallowed, value stays empty) or the previous value was empty (the `!` is stripped, remainder kept, tab-expanded); pasting into an empty input does the same; opt out with `interpretLeadingModeCharacter:false` | §42.16.1 [`chunk-bq8epagv.js:412515`] | none | R | |
| Leaving: Backspace, Delete, Escape or `ctrl+u` with the caret at offset 0 | §42.16.1 [`chunk-bq8epagv.js:412016`] | none | R | |
| Indicator: prompt glyph becomes `!` + NBSP in the `bashBorder` colour; the input box border switches to `bashBorder` | §42.16.1 | none | R | |
| History round-trip: `vce` puts the `!` back for storage, so recalling a bash line restores bash mode | §42.16.1 [`chunk-33q5tpxk.js:186167`] | on disk | R | |
| **Execution — TUI `!`** | §42.16.1. Runs through the **Bash tool** (or PowerShell when `defaultShell` is `powershell`) with the **sandbox disabled**; the line is written to the transcript as `<bash-input>…</bash-input>`; the result is appended as a **synthetic user message** `<bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>` [`chunk-q24s0kp0.js:640215`, `:640223`]; whether the model then answers is `respondToBashCommands` (default **true**, forced false if the command was interrupted or backgrounded); telemetry `tengu_input_bash {powershell, respond}` | — | — | The Bash tool means **persistent shell state**: shell snapshot sourcing, `cd`, exported vars and the working directory survive across `!` lines. |
| **Execution — headless `bash_command` frame** | — | `{type:"bash_command", command, cwd?, uuid?, session_id?}`. `runHeadlessBashCommand` spawns **`/bin/sh -c <cmd>`** (or `pwsh -NoProfile -Command`) directly [`cli.pretty.js:572615`]. The CLI enqueues two `user` frames tagged `isReplay:true` on stdout: `<bash-input>…</bash-input>`, then `<bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr><bash-exit-code>N</bash-exit-code>` [`chunk-2rhzyjym.js:178684-178690`]. A `uuid` yields `command_lifecycle` `completed`; a non-string `command` yields `<bash-stderr>Command failed: missing command</bash-stderr>` | **D** | **Five concrete differences.** (1) **No transcript**: the schema states the output is not appended to the conversation, so the model never sees it — `respondToBashCommands` has no analogue and there is no way to make the model react. (2) **No persistent shell**: one-shot `/bin/sh -c` per call, no shell snapshot, no surviving `cd`/exports — the TUI's Bash tool keeps all of it. (3) It reports **`<bash-exit-code>`**, which the TUI path does not. (4) Same trust model — no sandbox, no per-command prompt — so a GUI must gate it in its own UI. (5) `pwsh` is chosen by `Fit()`, not by the frame. **Workaround for parity**: for "run it and let Claude see it", do not use `bash_command`; run the shell in the GUI (or via a Bash tool call) and send a normal `user` frame containing the same `<bash-input>`/`<bash-stdout>`/`<bash-stderr>` wrapping — that reproduces the TUI's transcript entry and lets `shouldQuery` decide whether the model replies. Use `bash_command` only for a dedicated terminal pane. |
| `defaultShell` setting — "Default shell for input-box ! commands. Defaults to 'bash' on all platforms (no Windows auto-flip)"; no `/config` row | §42.16.1, §42.24.1 | not in `get_settings.effective` unless set | R | |
| Bash mode changes autocomplete: path completion replaces `@`-mentions, shell completion becomes reachable, ghost text switches to shell history | §42.16.1, §42.17.1 | none | R | |

### 42.16.2 `@` — mentions

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Trigger `Mzt`: `@` at offset 0 or immediately after whitespace or one of `。、？！` — **a mid-word `@` never triggers**, so an email address is inert | §42.16.2 [`chunk-bq8epagv.js:404238`] | none | R | Reproduce the CJK punctuation set; it is not obvious. |
| Token class: Unicode letters/numbers/marks plus `_ - . / \ ( ) [ ] ~ :`; a quoted form `@"…"` admits spaces; everything else (space, comma, `#`, `*`, `?`, `$`, a second `@`) terminates | §42.16.2 | none | R | |
| Path-vs-index routing: `vhe(query)` sends `~/`, `/`, `./`, `../`, `~`, `.`, `..` to the filesystem completer, everything else to the fuzzy index | §42.16.2 [`chunk-bq8epagv.js:404747`] | see §42.18 | R | |
| Expansion at **submit** time, not accept time; agents rows labelled `<type> (agent)` | §42.16.2 | the same extractor runs in the shared attachment path — a `@path` in a headless `user` frame is expanded by the same code [`chunk-1kg58a1a.js:147188`], and re-run in `inputMentionsOnly` mode for nested memory (SPEC 10.12.1) | P | So the GUI can simply send the literal `@path` text. Note the asymmetry the chapter calls out: `#` is not in the completion token class so a `#L10` line-range suffix is never *completed*, but the submit-time extractor **does** parse it (`obr`, `#L<start>[-<end>]`). |
| Input hints under an empty prompt: `! for shell mode`, `@ for file paths`, `/ for commands`, `/btw for side question` | §42.16.2 | none | R | Cheap onboarding; worth porting as placeholder chips. |

### 42.16.3 `#` — Slack channels, not memory

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| **There is no `#` memory shortcut in 2.1.257.** The mode enum has two members; `user-memory-input` survives only as a transcript tag for old sessions. Memory editing is `/memory` | §42.16.3 [`chunk-vp8nzhw3.js:766279`] | `/memory` is **not** in the live headless command list | X (for `/memory`) | Do not build a `#` memory affordance. |
| `#` completes **Slack channel names**: regex `(^\|\s)#([a-z0-9][a-z0-9_-]*)$`, prompt mode only, requires a **connected** MCP server whose name contains `slack`, and the active slash command must not declare `completesHashChannels`. 150 ms debounce; calls the `slack_search_channels` MCP tool with `limit:20, channel_types:"public_channel,private_channel"`, 5000 ms timeout, capped at 10 rows; recognised channels are highlighted in the live input | §42.16.3 [`chunk-bq8epagv.js:404553`, `:404042`, `:404050`] | **closest control request: `mcp_call {tool:"slack_search_channels", arguments:{…}, timeout_ms?}`** [`chunk-2rhzyjym.js:177733`]; server presence from `mcp_status` (`{mcpServers:[{name,status,…}]}` — live dump confirms the shape) | R | Everything needed is on the wire: `mcp_status` gives the connected-server list to apply the `name.includes("slack")` test, and `mcp_call` invokes the same tool with the same arguments. The GUI reimplements the regex, the 150 ms debounce, the 10-row cap and the input highlighting. No shipped command sets `completesHashChannels` (chapter open question), so the opt-out is dead. |

### 42.16.4 `/` — slash commands

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `/` at offset 0 opens the command menu; `wE()` accepts a name of `[a-zA-Z0-9.:\-_]` or a `server:name://…` MCP prompt URL | §42.16.4 [`chunk-bq8epagv.js:403838`] | `initialize.commands` — live 2.1.259 returns **102** entries with `name`, `description`, `argumentHint`, `aliases` | P | The menu's *data* is on the wire. Rendering and filtering are the GUI's. |
| Mid-line `/` never opens the menu — ghost text only | §42.17.2 | — | R | See §42.17.2 below. |
| Which commands actually run headless | SPEC 28 §22 / 45.29.1 | live dump: `/keybindings`, `/vim`, `/focus`, `/terminal-setup`, `/btw`, `/memory`, `/rewind` are **absent**; `/config`, `/clear`, `/model`, `/fast`, `/effort`, `/compact`, `/context`, `/usage`, `/doctor`, `/color` are present | R | The GUI must render the CLI's list, not the TUI's, and locally implement the missing ones (see §42.24). `system/init.terminal_slash_commands` on 2.1.259 is `["doctor","color"]`. |

---

## 42.17 The autocomplete engine

All of §42.17 is client-side. The only wire dependencies are the data sources.

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| **Provider dispatch order is the precedence** — 17 ordered branches in `ji()`: suppression while history-searching → mid-line `/` ghost → bash path → bash-history ghost → agent `@` → Slack `#` → emoji inline replace → emoji menu → `/add-dir`+`/cd` arg → `/resume <query>` → custom-command `getArgumentCompletions` → argument-hint only → MCP prompt URL template → slash menu → `@` explicit path → `@` unified → shell completion | §42.17.1 [`chunk-bq8epagv.js:404480`] | data per row below | R | Order matters: a GUI that runs providers concurrently and merges will show different results. Reproduce the first-match-wins order. |
| `suggestionType` discriminator: `none`, `command`, `file`, `directory`, `agent`, `slack-channel`, `emoji`, `custom-title`, `shell` | §42.17 | — | R | |
| Engine suppressed entirely while reverse-searching or scrolling history | §42.17 [`chunk-bq8epagv.js:412580`] | — | R | |
| **Mid-line `/` trigger `I6`**: only after whitespace or `。、？！`; never at offset 0 (that is the menu); suppressed when the whole input is `/add-dir`, `/cd`, `/resume`, `/plugin`, `/plugins` or `/marketplace`; cursor at/before the token end; partial non-empty, class `[a-zA-Z0-9._:-]`; suffix is the first menu hit whose `name` **or** user-facing name prefix-matches case-insensitively. **When it matches, the menu is explicitly cleared** | §42.17.2 [`chunk-bq8epagv.js:403802`, `:404489`] | `initialize.commands` | R | This is why `src/foo`, `and/or` and URLs are inert. Subtle and worth copying exactly. |
| **Ghost text**: prompt mode → mid-line slash completion; bash mode → shell-history completion (needs ≥ 2 chars, corpus harvested from previously submitted `!` lines, capped at 50 entries, cached 60 000 ms). Rendered inside the buffer only when the cursor is at the absolute end of the last wrapped row: **first grapheme drawn as the inverted cursor cell, remainder dimmed**; hidden as soon as the caret moves (`insertPosition` must equal the offset) | §42.17.3 [`chunk-bq8epagv.js:404027`, `chunk-ha6de7vj.js:536990`] | none | R | The inverted-first-grapheme trick is a terminal necessity; a GUI can draw proper grey inline text. |
| **Tab, and only Tab, accepts ghost text — Right-arrow does not.** Bash: replaces the whole line, no trailing space. Prompt: replaces the token with `/`+full command **plus one trailing space** | §42.17.3 [`chunk-bq8epagv.js:404741`] | — | R | Users may expect Right-arrow (shell convention); accepting it would be a deliberate improvement. |
| Dimmed **argument hint** after a slash command when the value starts with `/` and has no space yet or ends with one: the command's `argumentHint`, else remaining named args as `[name1] [name2]` | §42.17.3 [`chunk-1kg58a1a.js:55728`] | `initialize.commands[].argumentHint` | P | |
| **Unified `@` provider**: file index and agent list in parallel, plus MCP resources and resource templates; the non-file half ranked by Fuse.js (`threshold:0.6`, weights name 3 / agentType 3 / displayText 2 / uriTemplate 2 / server 1 / description 1), **+0.15 penalty on `mcp_resource` rows**, then one ascending merge on `score` (lower is better) with files entering at the index's normalised rank (default 0.5). Caps: 15 rows, descriptions clamped to 60 columns | §42.17.4 [`chunk-bq8epagv.js:404160`, `:404170`] | agents: `initialize.agents` (11 live). MCP resources/templates: `mcp_message` control request (`resources/list`, `resources/templates/list`). Files: `file_suggestions` — **but the response drops `score`** (§42.18) | **D (partial)** | The merge is *defined by the file score*, and the control response omits it (see §42.18.1). Workaround: assign files a synthetic score from their returned rank (`i/n`), which reproduces the TUI's own normalisation exactly — the TUI's score *is* `rank/count`. That makes this recoverable, but only because the normalisation is rank-based; a GUI must know to do it. |
| Suggestion id shapes `file-<path>`, `mcp-resource-<server>__<uri>`, `mcp-template::…`, `agent-<type>`, `slack-channel-<name>`, `emoji:<name>`, `dm-…`, `resume-title-<sessionId>`, `command-arg-<value>` | §42.17.4 | — | R | Only needed to reproduce the compact-vs-full row split (`Yr()`). |
| Menu rendering: overlay height exactly 5 lines, inline `max(1, min(max(6, floor(rows/2)), rows-3))`; window places up to `floor(height/2)` above the selection; **no "N more" string, no header/footer row**; compact rows `icon name – description` with icons `+` (file), `◇` (MCP), `*` (agent); file descriptions capped at 20 cols, MCP display text at 30; full two-column rows for commands/emoji/Slack/resume/args with a name column `min(maxColumnWidth, floor(cols*0.4))`, optional `[tag]`, a 7-column kind lane behind `CLAUDE_CODE_ENABLE_MENU_KIND_LANES` / `tengu_mint_lanes`, optional `[sourceTag]`, then description; selected row uses the `suggestion` colour and is undimmed, all others dimmed; fuzzy-match spans bold+undimmed; **mouse hover overrides keyboard selection** | §42.17.5 | none | T | All layout. A GUI should use its own popover. The one behaviour worth keeping: hover overriding keyboard selection. |
| Empty state: only `No commands match "<input>"` for the slash menu; an empty file result silently collapses the list | §42.17.5 [`chunk-bq8epagv.js:404669`] | — | R | |
| **Accept semantics**, three entry points: **Tab** always `shouldExecute:false` (fills, never runs; with nothing selected accepts row 0); **Enter** `shouldExecute:true` but **with nothing selected it does not accept** — it dismisses and submits the line as typed; **Click** behaves like Tab | §42.17.6 [`chunk-bq8epagv.js:404741`, `:404884`, `:404998`] | — | R | The Enter-with-nothing-selected rule is the one users notice. |
| Per-provider accept: slash → whole input + trailing space, menu closed, Enter also submits unless the command is a prompt with declared `argNames`; MCP prompt URL template → whole input, no space, menu **re-opens**; bash path → last space to cursor, files get a space, directories do not and **re-open**; `/add-dir`/`/cd` → `/` for dirs, space otherwise, dirs re-open; `@` explicit path → same; agent/Slack/emoji → trailing space, closed; `/resume` title → whole input, no space, Enter submits; shell → `$name ` for variables, `name ` for commands | §42.17.6 | — | R | |
| `@` file provider does **longest-common-prefix completion first**: if the common prefix of every visible `displayText` is longer than what was typed, insert it bare and re-run; only when it adds nothing is the selected row accepted. With exactly one match the prefix *is* the match, so **the first Tab inserts it bare and a second Tab adds the closer**. Skipped when any row carries `replacement` metadata | §42.17.6 [`chunk-bq8epagv.js:404824`] | — | R | Classic shell behaviour; users will notice its absence. |
| Insert formatting `Whe`: paths with a space are wrapped in double quotes — **no backslash escaping and no escaping of an embedded quote**; trailing space only when `isComplete`; `applyFileSuggestion` splices `[startPos, startPos+len)` and puts the caret after | §42.17.6 [`chunk-bq8epagv.js:404284`, `chunk-gavhbb3k.js:514527`] | — | R | The missing quote-escaping is a real (minor) bug; a GUI should escape properly. |
| Selection preserved across re-queries by id, defaulting to row 0 — **except** `file`, `slack-channel`, `custom-title` and MCP templates, which start with nothing selected; the slash menu preselects row 0 only when the top hit genuinely prefix-matches | §42.17.6 | — | R | Combines with the Enter rule above: with a file menu open, Enter submits rather than accepting. |
| **Tab's four duties**: (1) menu or ghost present → `autocomplete:accept`; (2) empty input with a pending prompt suggestion → accept the starter prompt; (3) empty/whitespace input → 3000 ms hint naming the `chat:thinkingToggle` chord; (4) otherwise nothing. The text buffer never consumes Tab | §42.17.7 [`chunk-bq8epagv.js:405021`] | duty (2)'s data is the `prompt_suggestion` frame (`--prompt-suggestions`) | R (P for the data) | Duty (3) is a discovery hint; a GUI has menus for that. Tab-for-focus-traversal is the native expectation and conflicts with duty (1) — resolve deliberately. |
| The `Autocomplete` context activates exactly when there are suggestions **or** ghost text; submission is blocked while a menu is up **unless every row is a directory row**; Enter with a bash-path menu open passes through when the line ends in `\` or the Apple Terminal shift probe fires | §42.17.7 [`chunk-bq8epagv.js:405003`, `:413723`, `:405046`] | — | R | |
| Debounces (all trailing-edge): files/`@` 50 ms, Slack 150 ms, MCP prompt URL template 150 ms; everything else undebounced. Minimum queries: 2 after `:` for emoji, 2 for the bash-history ghost, 1 for the mid-line `/` ghost, 1 after `#` for Slack. **No loading spinner.** Race guards store the query in a ref plus a monotonic counter; shell completion aborts its predecessor | §42.17.8 | the 50 ms file debounce now guards a **control round-trip**, not an in-process call | R | Latency is the GUI's new problem: consider raising the debounce or showing an inline spinner (a place to exceed the TUI, which shows none). |
| `emojiCompletionEnabled` (default true, no `/config` row): `:name` menu after ≥ 2 chars, `:name:` inline replacement | §42.17.1, §42.24.1 | none | R (trivial) | |

---

## 42.18 File suggestions and the file index

### 42.18.1 Does the `file_suggestions` control request give the same results? — **Yes, with three caveats**

The headless handler calls the **identical** function the TUI calls:

```js
let { generateFileSuggestions: I, globalFileIndexCache: F } = await import(".../chunk-01hk4n0c.js"),
    fe = await I(F, d.request.query, !0, C.storageV5);
Xe(d, { suggestions: fe.map((z) => ({ path: z.displayText })) });
```
[`chunk-2rhzyjym.js:177645-177646`]

So the scoring (§42.18.2), the process-level cache (§42.18.3), the `git ls-files
--recurse-submodules` / ripgrep walk plus Claude-config `.md` files and the background
untracked pass (§42.18.4), the `.ignore`/`.rgignore` in-process matcher (§42.18.5), the
refresh policy (§42.18.6) and the `fileSuggestion` custom-helper override are all *the same
code on the same index*. The caveats:

1. **`showOnEmpty` is hardcoded `true`.** An empty query returns the cwd `readdir` (capped at
   15) rather than `[]`. The TUI's `@` provider chooses per caller.
2. **The `score` field is dropped.** The published response schema is
   `{suggestions: [{path, score?}]}` [`chunk-sct99ax9.js:673390`] but the handler emits `path`
   only. Array order still encodes the ranking, and since the TUI's exposed score *is*
   `rank / resultCount` [`chunk-ejcy5qcd.js:487722`], a GUI can reconstruct it exactly. Without
   doing so, the §42.17.4 merge against MCP/agent rows is wrong.
3. **No `indexBuildComplete` signal.** The TUI re-runs the last query when a partial index
   finishes building [`chunk-bq8epagv.js:404454`]; over the wire an early query silently returns
   partial-index results and nothing tells the GUI to retry.

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `generateFileSuggestions(cache, query, showOnEmpty, storageV5)`: remote short-circuit → `[]` on empty → custom-helper override → empty/dot query readdir → kick background refresh → strip `./`, expand `~` → search ≤ 15 → telemetry | §42.18.1 [`chunk-gavhbb3k.js:514486`] | `file_suggestions {query}` → `{suggestions:[{path}]}` [`chunk-2rhzyjym.js:177643`] | **P** (with the three caveats above) | Result rows carry no description, which is why file rows have no description column. |
| Fuzzy scoring: `16*queryLen + 4*adjacent − Σ(3 + gapSize) + Σ positionBonus + max(0, 32 − (pathLen>>2))`; separator bonus 8 for `/ \ - _ . <space>`, camelCase bonus 6, position-0 bonus 8; **smart case** (any uppercase in the query → case-sensitive); query truncated to 64; 26-bit a–z prefilter; **no exact-prefix special case**, **no directory-depth term, no recency term, no separate basename weighting**; exposed score is `rank/count` ∈ [0,1), lower better; paths containing the substring `test` demoted ×1.05 **after** the sort (so it only affects cross-source merging) | §42.18.2 [`chunk-ejcy5qcd.js:487593`, `:487703`, `:487722`] | identical — same code path | P | If the GUI ever wants its own index (e.g. for latency), these constants are the spec. |
| Empty-query result: cached first-path-segments, deduped, sorted by length then lexicographically, capped at 100 | §42.18.2 | reachable, because `showOnEmpty` is forced true | P | |
| Cache: process-level in-memory singleton, **no on-disk persistence**, rebuilt each process start; `resetFileIndexCache` nulls everything and bumps `cacheGeneration` (staling in-flight work), called from the session-cache clear on `/clear` | §42.18.3 [`chunk-gavhbb3k.js:514257`, `:514260`] | same process, same cache — the GUI shares it | P | Because `/clear` is available headless, the index reset still happens. |
| Walk: `git -c core.quotepath=false ls-files --recurse-submodules` from the repo root, 5000 ms timeout, re-based to cwd-relative; ripgrep fallback `--files --follow --hidden` excluding `.git/ .svn/ .hg/ .bzr/ .jj/ .sl/` (plus `--no-ignore-vcs` when `respectGitignore` is false); every `.md` under user/project/additional-dir/policy `.claude/{commands,agents,output-styles,skills,workflows,routines}` as **absolute** paths; a background `git ls-files --others [--exclude-standard]` pass merged in later. Directories synthesised from ancestor chains. **No max depth, no max file count**; symlinks followed; 10 000 ms overall abort | §42.18.4 | identical | P | The absolute config-`.md` paths are why `@` can complete a user-level command file. |
| Ignore rules: in-process vendored `ignore` matcher, **fail-open** (an invalid path is kept); **only `.ignore` and `.rgignore`**, in the repo root and the cwd, memoised on `<repoRoot>:<cwd>`; `.gitignore` honoured only indirectly (via `git ls-files`, `--exclude-standard`, and ripgrep's own handling); **no `git check-ignore` subprocess, no `.claudeignore`, `node_modules` is not hardcoded** | §42.18.5 [`chunk-gavhbb3k.js:514326`, `:514317`] | identical | P | A GUI building its own picker must not "improve" this — divergence would confuse users comparing with the terminal. |
| Refresh policy: 5000 ms minimum between refreshes when `.git/index` mtime is unchanged; **in a non-git directory, a previous scan over 1000 ms means the index is never refreshed again for the process lifetime**; a `.git/index` mtime change bypasses the window; in-flight refresh returns immediately; **no timer — entirely demand-driven**, kicked by each non-trivial query and once on editor mount | §42.18.6 [`chunk-gavhbb3k.js:514451`] | the control request kicks the same refresh | P | The non-git never-refresh rule is a real trap: in a non-repo directory a GUI's file picker can go permanently stale. Workaround: nothing on the wire resets it except `/clear`. |
| `pathListSignature`: sampled FNV-1a over ~500 evenly spaced entries plus the last, `<count>:<hex>`; unchanged signature skips the rebuild | §42.18.6 | — | P | |
| Scope-moving controls | §42.18.4 (repo root / cwd) | `set_cwd {path, trust_accepted?, trusted_directory?}` → `{status, cwd, changed, transcript_relocated}`; `add_directory`; `register_repo_root {directory, reload_claude_md?, reload_plugins?, reload_skills?}` | P | These are how a GUI moves the index's root at runtime. |
| `respectGitignore` (default true, `/config` row `Respect .gitignore in file picker`); settings text: "Note: .ignore files are always respected" | §42.18.7 | `get_settings` / `update_settings` | P | |
| `fileSuggestion: {type:"command", command}` replaces the built-in index entirely: the command receives a session/hook payload plus `query`, stdout split on newlines, trimmed, empties dropped, capped at 15, 5000 ms timeout; subject to managed policy, skipped when hooks are disabled or the workspace is untrusted; disabled by `CLAUDE_CODE_SIMPLE`/`--bare` (the built-in index still runs) | §42.18.7 | applies to the control request too, since it lives inside `generateFileSuggestions` | P | A GUI that builds its own index would silently ignore a user's `fileSuggestion` helper — an argument for using the control request. |
| `CLAUDE_CODE_GLOB_TIMEOUT_SECONDS` overrides the ripgrep timeout (default 20 000 ms; 60 000 ms on WSL) | §42.18.7 | env var on the child | P | |
| **No setting or env var bounds the index size and none disables the `@` picker**; the only off-switch is remote mode, which redirects to the control channel | §42.18.7 | — | — | Worth knowing before shipping a GUI onto a monorepo. |

---

## 42.19 Prompt history

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `~/.claude/history.jsonl` — one **global** newline-delimited file; project and session are *fields*, not directories. Record: `{display, pastedContents, timestamp, project, sessionId?}`; `display` keeps placeholders intact and keeps a bash line's leading `!`. Appended with mode `0o600` under a file lock | §42.19.1 [`chunk-1kg58a1a.js:47465`, `:47675`] | not on the wire — **readable and writable straight from disk** | R | The GUI must both read (to show history) and write (so the terminal and the GUI share one history). Writing is the part that is easy to skip and shouldn't be. |
| Read cap `K8e = 100` per project (the *file* is uncapped); `readForProject` yields current-session entries first, then the rest of the project's | §42.19.2 | disk | R | |
| Write-time dedupe: dropped only when it exactly repeats the immediately previous entry in the same project **and** session and neither has pasted content. Read-time dedupe on a canonical form that rewrites every `#N` to `#_` and appends a `hash:`/`inline:`/`literal:`/`dead` discriminator | §42.19.2 [`chunk-1kg58a1a.js:47498`, `:47367`] | disk | R | |
| Pastes: text ≤ 1024 chars inlined, longer content-addressed to the paste cache; **only text entries still referenced by a placeholder in `display` are stored — images and audio are never written to history**, and on recall resolve to `unavailable` | §42.19.2 [`chunk-1kg58a1a.js:47414`, `:47646`] | disk | R | A GUI with attachment chips must decide what a recalled entry with a dead image placeholder shows. |
| Suppression: `CLAUDE_CODE_SKIP_PROMPT_HISTORY`, sensitive slash commands (`isSensitive`), secret-looking pastes scanned in 65 536-byte windows; a prompt made only of dead pastes, or whose leading sigil would change once dead pastes are stripped, is skipped | §42.19.2 [`chunk-1kg58a1a.js:47780`, `:47159`] | env var passes to the child; the secret scan is the GUI's to reimplement if it writes history | R | Skipping the secret scan would write credentials to a shared file — do not. |
| Write timing: entry built at submit, **written when the prompt is actually dispatched**, so a queued prompt only enters history when the queue drains; debounced flush with 5 retries at 500 ms; exit hook drains the queue and in-flight paste writes; a `fromKeybinding` submission produces **no** entry; `removeLast()` retracts | §42.19.2 [`chunk-1kg58a1a.js:47860`] | the GUI can mirror this off `command_lifecycle` `started` | R | Nice trick: gate the history write on `command_lifecycle: started` for the frame's uuid and the semantics match exactly. |
| Scopes `["session","project","everywhere"]`; **Up/Down recall is always project-scoped** | §42.19.2 [`chunk-1kg58a1a.js:47497`] | disk | R | |
| **Up/Down (`history:previous`/`next`)**: Up recalls only when the caret is on **visual row 0** (wrapped row, not logical line), Down mirrors on the last visual row; `up`/`down` with `shift`/`ctrl`/`meta` are ignored outright. Chat-level order: >1 suggestion showing → swallow; caret past the first logical newline → swallow; with `CLAUDE_CODE_KB_COHESION_FIXES`, walk the queue-edit selection and only reach history at index 0; else if the queue holds editable commands, **pull all of them into the draft**; else history-previous. Down past the newest entry moves focus into the footer strip | §42.19.3 [`chunk-ha6de7vj.js:537931`, `chunk-bq8epagv.js:412595`] | disk + the GUI's own queue model | R | |
| **There is no prefix search.** The only filter is the submit mode, captured on the first Up: a draft starting with `!` restricts navigation to bash entries | §42.19.3 [`chunk-bq8epagv.js:411308`] | — | R | A GUI adding prefix search would exceed the TUI; users coming from the terminal will not expect it. |
| Draft restoration: the original draft saved once on the first Up out of index 0 and only when non-blank; per-entry edit map; recalling upward puts the caret at the **end**, restoring the draft at offset **0**; entries loaded in pages of 10; recalled pastes re-minted with fresh ids | §42.19.3 [`chunk-bq8epagv.js:411259`, `chunk-1kg58a1a.js:48002`] | — | R | |
| After the **second** Up in a session, a 5000 ms hint names the `history:search` chord with the description `search history` | §42.19.3 | — | R | |
| **`ctrl+r` inline reverse-i-search**: case-insensitive **substring** via `lastIndexOf`, newest-first over the **entire file** (no scope), skipping content-identical repeats, no fuzzy tier; caret parked at the match offset. Bindings: `ctrl+r` next older, `escape`/`tab` accept and exit, `ctrl+c` restores the pre-search snapshot, `enter` submits immediately, Backspace on an empty query cancels. Label `search prompts:` / `no matching prompt:`; in vim with an empty query a dim `esc i / for slash commands` | §42.19.4 [`chunk-bq8epagv.js:403487`] | disk | R | |
| **Fullscreen history picker**: `ctrl+s` cycles scope `session → project → everywhere`, **default `everywhere`**; substring first, then an in-order subsequence tier once the scan completes; budget 16 MiB of prompt text charged at 256 bytes/entry, 100 entries rendered immediately, batch size quadrupling, 6 preview rows, 8-column timestamp; title `Search prompts · <scope>` with ` · newest N only` when truncated; filter placeholder `Filter history…`; empty states `Loading…` / `Couldn't read prompt history` / `Searching older prompts…` / `No history yet` / `No matching prompts` | §42.19.4 [`chunk-bq8epagv.js:405983`, `:405969`] | disk | R | A native table view with live filtering exceeds this easily. |
| **History search is refused in cloud sessions**: `History search isn't available in cloud sessions yet` | §42.19.4 [`chunk-bq8epagv.js:414080`] | — | T | Only relevant if the GUI drives a cloud-hosted session; the file is local either way, so the GUI can offer it where the TUI cannot. |

---

## 42.20 Submitting, queueing and steering

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `enter` reaching the editor: `chat:submit` is registered with `singleKey:false` **only while `enter` still resolves to it**; rebind the action and `singleKey` flips true and the dispatcher fires it directly | §42.20.1 [`chunk-bq8epagv.js:413974`] | — | R | The general "a key the editor must see unless the user moved the action" mechanism. Only matters if the GUI honours `keybindings.json`. |
| **Submitting during a turn queues, it does not steer.** Only `prompt` and `bash` modes are queueable (`prompt_queued` / `mode_not_queueable` otherwise). The input is then cleared: value, cursor, `pastedContents`, history navigation **and the undo buffer** | §42.20.2 [`chunk-bq8epagv.js:425146`] | send the `user` frame; the CLI queues it and emits `command_lifecycle` `queued` for its `uuid` | P | `session_state_changed` (`idle`\|`running`\|`requires_action`) tells the GUI which it will be. Frames without a `uuid` emit no lifecycle events — **always stamp a uuid**. |
| Priorities `now:0, next:1, later:2`; user prompts default `next`, task notifications `later`. **No maximum queue size for user prompts** (caps are 50 queued peer messages, 1000 poll events) | §42.20.2 [`chunk-1kg58a1a.js:48042`, `:48323`] | `priority` on the `user` frame | P | |
| Queue rendering: queued prompts render as read-only user rows just above the input, marked `isQueued` (dimmed; accessibility label swaps `you:` → `selected:`) | §42.20.3 [`chunk-bq8epagv.js:411095`] | `command_lifecycle` `queued`→`started`→`completed`\|`cancelled`\|`discarded`\|`refused`, joined on `command_uuid`; with `--replay-user-messages` the frame text is echoed back | P | The GUI has everything it needs to render a live queue. Note the ordering caveat in the schema: a command that starts a fresh turn emits `completed` **after** that turn's `result`, while one folded into an in-flight turn emits it **before**. |
| Queue editing: `popAllEditable` joins every editable queued command with the current draft using newlines, re-mints colliding paste ids, recomputes the cursor, removes them, and collapses the mode to `bash` only if **all** popped entries were bash; `popEditableAt(index)` for one. Reachable from Up with a non-empty queue, from Escape with a non-empty queue, and from the cancel path. With `CLAUDE_CODE_KB_COHESION_FIXES`, Up/Down walk a `queueEditIndex` and Enter pulls the selected entry back, emitting `Clear the input to edit this queued shell command` | §42.20.3 [`chunk-1kg58a1a.js:48518`, `:48540`] | **`cancel_async_message {message_uuid}` → `{cancelled}`** [`chunk-2rhzyjym.js:177389`], then re-send a new `user` frame with the edited text | **R** | This is the right decomposition: "pull back to edit" = cancel + re-send. The CLI dequeues all entries matching the uuid, or marks a cancel pending if the fold is in flight, and emits `command_lifecycle` `cancelled`. **The lifecycle frame cannot distinguish a user-requested cancel from a swept one** — the schema explicitly tells resenders to correlate against their own `cancel_async_message` responses and any `interrupt` receipt's `cancelled` list before resending. |
| Placeholder hints while the queue is non-empty and the input empty: `Press up to edit queued messages, Enter to send them immediately` (behind `tengu_jiggly_mochi`) / `Press up to edit queued messages` (at most 3 times per install) | §42.20.3 | — | R | |
| **Draining**: fires when the turn guard goes inactive and no dialog is open. If the head is a slash command or a bash line, exactly **one** entry drains; otherwise **all consecutive same-mode plain prompts** drain as one batch, stopping at a slash command, a `screeningPending` entry, or a `drainOnly` boundary. The batch becomes a **single turn**, and their history entries are written first | §42.20.4 [`chunk-bq8epagv.js:428448`] | observable as several `command_lifecycle` `started` frames followed by one `result` | P | The GUI must not assume one queued message = one turn. |
| A hook may drop a queued prompt during screening: `Prompt dropped by a hook` | §42.20.4 [`chunk-bq8epagv.js:425176`] | `hook_started`/`hook_response` frames; the drop shows as a `command_lifecycle` terminal state | P | |
| `chat:queueSubmit` (`ctrl+x enter`) sets `wait:true` so an idle submission parks for the next drain and bypasses the suggestions guard; mid-turn it is identical to `chat:submit` | §42.20.5 [`chunk-bq8epagv.js:413992`, `:413744`] | nearest: `priority:"later"` on the `user` frame | R | No `wait` field exists on the wire; `priority` is the closest lever. |
| **`/btw`** — a `local-jsx` command with `immediate:true`, which is the input-layer switch: an immediate local-JSX command submitted mid-turn takes a branch **before** the queue; the panel mounts `{immediate:true, hidesPrompt:false, retireAtTurnBoundary:true}` so the prompt stays usable underneath; the token is highlighted live by `/^\/btw\b/gi`; footer hint `/btw for side question` | §42.20.6 [`chunk-1kg58a1a.js:143528`, `chunk-bq8epagv.js:428061`] | **not in the live headless command list**, but its descriptor carries `thinClientDispatch: "control-request"` → the **`side_question` control request** [`chunk-2rhzyjym.js:178330`], and `control_request_progress` is emitted **only** for `side_question` (§45.9.1) | **R** | So `/btw` is fully reachable, just not as typed text: the GUI intercepts `/btw <question>` locally and issues `side_question`, streaming the answer from `control_request_progress`. This is the one place in the chapter where a GUI must translate a slash command into a control request. |

---

## 42.21 The interrupt ladder

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| The double-press helper: first press runs an immediate side effect and arms; a second within **800 ms** disarms and fires; the default window is 800 ms and **only `chat:killAgents` differs (3000 ms)** | §42.21.1, §42.21.8 [`chunk-668g8fpq.js:285963`] | none | T | Double-press ladders exist because a terminal has one key and no buttons. A GUI should use distinct controls and a confirmation sheet. |
| **Escape, layer 1** (`chat:cancel`): gate requires not-in-transcript, no background-tasks dialog, no input overlay, no visible mode picker, and something running or queued; excludes a non-prompt mode with empty input, vim editing, and viewing an agent. Precedence inside: running turn wins → queue pull-back → passive background work → background agents (never, since Escape passes `suppressBackgroundAgentKill:true`) | §42.21.2 [`chunk-bq8epagv.js:403215`, `:403192`] | `interrupt`; `cancel_async_message` | R | |
| **Escape, layer 2** (`onKeyDownBefore`): clear a queue-edit selection or dismiss the help overlay → let vim have it if the mode is not NORMAL → pull queued messages back → arm the double-Escape rewind when the transcript is non-empty, the input is **empty** and nothing is loading. The same pass resets `!` mode to `prompt` at offset 0 | §42.21.2 | — | R | |
| **Escape, layer 3** (editor): first Escape on a **non-empty** input shows `Esc again to clear` for 1000 ms; a second within the 800 ms window clears the input — writing the cleared text to prompt history first when `historyOnClear` is set, no mask is in force and the text is not blank. **The hint outlives the accept window by 200 ms.** Footer help reads `double tap esc to clear input`. Skipped entirely when `disableEscapeDoublePress` | §42.21.2 [`chunk-ha6de7vj.js:537825`] | none | R | The 1000-vs-800 ms mismatch is a real (small) bug; do not port it. |
| **Double-Escape → message selector (rewind)**: a `CI` with a no-op first callback, so the 800 ms window is invisible; refused in cloud sessions (`Rewind is not yet available in cloud sessions`); activates the `MessageSelector` context only when no restore is in flight, no error, no message confirmed and **more than one** candidate exists. Title `Rewind`, guide `enter`=`continue` / `escape`=`cancel`, empty state `Nothing to rewind to yet.` | §42.21.3 [`chunk-bq8epagv.js:412793`, `:401817`] | `rewind_conversation` (request `target_message_uuid`, `interrupt_if_running?`, `last_seen_user_message_uuid?`; response `{rewound, prefillText, precedingAssistantUuid, error?}`) [`chunk-2rhzyjym.js:177455`] | R | The response's `prefillText` is exactly what the TUI puts back in the draft, and `precedingAssistantUuid` anchors the transcript truncation — a GUI gets both for free. Refusal strings to render: `"commands queued"`, `"prompt pending"`, `"turn running"`, `"target not found"`, `"stale target"`, `"unseen later turn"`, `"poll tool_result target"`, `"delivered poll events in range"`. |
| The restore-option menu: `Restore code and conversation` / `Restore conversation` / `Restore code` (the first and third only when code changes exist), plus `Summarize from here`, `Summarize up to here`, `Never mind`, an optional `add context (optional)` input, and the consequence blurbs (`The conversation will be forked.`, `Messages after this point will be summarized.`, `Preceding messages will be summarized. …`, `The conversation will be unchanged.`) | §42.21.3 [`chunk-bq8epagv.js:401716`, `:401841`] | conversation → `rewind_conversation`; code → **`rewind_files {user_message_id, dry_run?}` → `{canRewind, error?, filesChanged?, insertions?, deletions?, skippedLinks?}`**; summarize → a `user` frame with `summarize_metadata {messages_summarized, user_context?, direction:"from"\|"up_to"}` (§45.15.1) | R | All six options are reachable, but as **three different mechanisms** the GUI must compose itself. `rewind_files` with `dry_run:true` gives the exact preview counts the TUI shows. `skippedLinks` must be surfaced. |
| **Ctrl-C, layer 1** (`app:interrupt`): handles "viewing an agent", otherwise returns `false` when the cancel function declines so the key falls through; its gate is **broader than Escape's** — it includes background agents | §42.21.4 [`chunk-bq8epagv.js:403232`] | `interrupt` | R | |
| **Ctrl-C, layer 2** (editor): first press clears the input (unless `disableCtrlCClear`) **and** arms the exit message; a second within 800 ms exits. Renders `Press Ctrl-C again to exit`, or `Press Ctrl-C again to detach (session keeps running)` in a background or catch-up session | §42.21.4 [`chunk-ha6de7vj.js:537820`, `chunk-bq8epagv.js:410013`] | — | R | The detach-vs-exit distinction is worth keeping in a GUI that supports background sessions. |
| **Ctrl-D**: no component registers `app:exit` in the chat (only dialogs do), so the key reaches the editor. Non-empty buffer → forward-delete, no exit message, ever. Empty → `Press Ctrl-D again to exit`, second press exits. **Never clears the input** | §42.21.5 [`chunk-ha6de7vj.js:537855`, `:537846`] | close stdin, or `end_session` | R | |
| **Ctrl-Z** | §42.21.6 | none | T | See §42.2 above. |
| `chat:clearInput` / `chat:clearScreen` | §42.21.7 | none | T | Both force a redraw; neither clears the input. Known wiring bug. |
| `chat:killAgents` | §42.21.8 | see the Chat table above | **D** | Confirmed messages to reuse: `Press <chord> again to stop background agents` (3000 ms) and `No background agents running` (2000 ms). |
| `chat:externalEditor`, `chat:stash`, `chat:newline`, `chat:undo`, `chat:imagePaste` | §42.21.9–12 | see the Chat table above | R | |

---

## 42.22 `Shift+Tab`: the mode cycle

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| The chord `LNn`: `shift+tab` unless the platform is Windows *and* the runtime is too old to deliver a distinguishable Shift+Tab, in which case `meta+m`. In 2.1.257 it is **`shift+tab` unconditionally** (the version check is folded to true). The literal `"shift+tab"` also binds `tabs:previous`, but `Tabs` is only active in tabbed views so they never collide | §42.6, §42.22.1 | none | T | A GUI has no Shift+Tab ambiguity and should probably use a segmented control, keeping the chord as an accelerator. |
| Gating: registered in `Chat` with `!wm && !Pf` — **inert while any overlay or `local-jsx` dialog is mounted, or while `ctrl+r` search is open** | §42.22.2 [`chunk-bq8epagv.js:414016`] | — | R | |
| **The ring: `default → acceptEdits → plan → [bypassPermissions] → [auto] → default`.** `default`, `acceptEdits`, `plan` are always in it (plan has no availability gate). `auto` always exits to `default`. **`dontAsk` is never entered by the cycle, only escaped** — it is reachable only via the `/config` `permissionMode` row or settings. With neither optional mode available it collapses to a 3-cycle | §42.22.3 [`chunk-nzczdq15.js:631198`] | `set_permission_mode {mode, ultraplan?}` → `{mode?}`; current mode from `initialize.current_permission_mode` (live dump: `"auto"`) and from `system/status` permissionMode-change frames | R | The GUI sets an absolute mode; the ring order is its own to implement. |
| Availability: `bypassPermissions` only when launched with `--dangerously-skip-permissions` **and** the settings killswitch is unset; `auto` only when the circuit breaker, the `disableAutoMode` killswitch and model capability all pass | §42.22.3 [`chunk-nzczdq15.js:631195`, `:631189`] | **not on the wire** — `initialize` returns `current_permission_mode` but no availability list | **D** | Workarounds, in order of quality: (a) the GUI knows its own launch flags, so it knows whether `--dangerously-skip-permissions` was passed; (b) `get_settings.effective` carries `autoMode` (present in the live dump's key list) and the bypass killswitch; (c) optimistically call `set_permission_mode` and read the error — `Cm()` validates against availability and returns an error string [`chunk-2rhzyjym.js:177262`]. |
| Teammate branch: while an in-process teammate is being viewed, Shift+Tab cycles **that teammate's** mode, not the session's | §42.22.3 [`chunk-bq8epagv.js:413905`] | no per-teammate mode control request | D | Cross-ref chapter 39. |
| Cloud-session refusal: `No other permission modes are available in this cloud session` | §42.22.3 | — | R | |
| **The cycle does not reverse with a modifier.** A directional ring exists but is only reached with `kind:"mode"`, produced solely by the stubbed `proactivityMenu:*` actions | §42.22.4 [`chunk-bq8epagv.js:405114`] | — | T | A GUI with a segmented control gets bidirectional selection free — an improvement, not a divergence risk. |
| Indicator strings and colours: `⏸ manual mode on` (`inactive`), `⏸ plan mode on` (`planMode`), `⏵⏵ accept edits on` (`autoAccept`), `⏵⏵ bypass permissions on` (`error`), `⏵⏵ don't ask on` (`error`), `⏵⏵ auto mode on` (`warning`); `default` normally suppressed in the footer; the dimmed chord suffix makes the full string `⏵⏵ accept edits on (shift+tab to cycle)`, with a second site labelling the action `auto-accept edits` | §42.22.5 [`chunk-yte5spsr.js:839628`] | mode is on the wire; glyphs/colours are the GUI's | P | The glyphs are U+23F8 and U+23F5 U+23F5. |
| Screen-reader announcement `[<mode> on]` on commit | §42.22.3 | — | R | Port to `NSAccessibility` announcements. |
| `confirm:cycleMode` — the **same chord means something else** in `Confirmation`: it selects "accept for the rest of this session" (label `Yes, keep allowing reads outside the working directories` when a path rule is involved) or toggles the focused feedback field; in plan approval it is "approve with this feedback"; in the `/powerup` carousel it advances a slide | §42.22.6 [`chunk-bq8epagv.js:422711`, `:422376`] | the option is in the `can_use_tool` payload | P | A GUI must not globally bind Shift+Tab to mode-cycling or it will break the permission sheet. |
| Documented mentions of the chord in the auto-mode description, `/powerup`, and the tips engine | §42.22.7 | prose arrives with the content | P | These strings will name `shift+tab` even in a GUI — a reason to keep it as an accelerator. |

---

## 42.23 The remaining Chat and Global actions

Covered inline in the §42.5–42.6 tables above (`app:*` toggles, `task:background` and the tmux
prefix accommodation, the unbound `strip:*` and `proactivityMenu:*` families). Two summary
points:

* `task:background` is the **cleanest parity row in the chapter**: `background_tasks` with no
  `tool_use_id` invokes the identical `ZM` "background everything eligible" function
  [`chunk-2rhzyjym.js:178253`, `chunk-1kg58a1a.js:128023`].
* The whole tmux accommodation (`CLAUDE_CODE_KB_COHESION_FIXES`, doubled `ctrl+b` hints,
  `singleKey` flipping) exists only because tmux steals `ctrl+b`. Drop it, and drop the
  `keybindings-help` skill's Behavioral Rule 3 warning about `ctrl+b`/`ctrl+a` if the GUI ever
  regenerates that text — the two are not coupled in the CLI either.

---

## 42.24 Settings, commands, env vars and gates that touch input

| Feature | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `editorMode` (`normal`\|`vim`, default `normal`, `/config` row `Editor mode`) | §42.24.1 | `get_settings.effective.editorMode` — present in the live dump as `"normal"`; `/config` is available headless (`type:"local"`, `supportsNonInteractive:true`) | P (read) / R (write user scope) | `update_settings` writes **localSettings only**, so a user-scope change means writing `~/.claude/settings.json` from the GUI. |
| `keybindingFlavor` (`classic`\|`readline`, default `classic`, **no `/config` row**) | §42.24.1 | `get_settings` only when set; else read `~/.claude/settings.json` | R | |
| `vimInsertModeRemaps`, `statusLine.hideVimModeIndicator`, `defaultShell`, `fileSuggestion`, `emojiCompletionEnabled`, `respondToBashCommands` — **none has a `/config` row** | §42.24.1 | `get_settings` / disk | R | A GUI settings panel that surfaces these exceeds the TUI, which requires hand-editing JSON. |
| `respectGitignore` (`/config` row), `leftArrowOpensAgents` (`/config` row), `copyOnSelect` (`/config` row, fullscreen only), `askUserQuestionTimeout` (`never`\|`60s`\|`5m`\|`10m`, `/config` row) | §42.24.1 | `get_settings` / `update_settings` | P | `askUserQuestionTimeout` matters headless: it governs auto-continue on an `AskUserQuestion` `can_use_tool`. |
| The `/config` panel's literal `Input & controls` group: `editor`, `askUserQuestionTimeout`, `modelProposedGoals`, `copyOnSelect`, `promptSuggestionEnabled`, `agentsView`, `checkpoints`, `workflows`, `workflowKeywordTriggerEnabled`, `artifacts`. `autoScroll` is under `Display`, `verbose` under `Model & output`. **No row for paste behaviour and none for the todo panel** | §42.24.1 [`chunk-9w2c2eyx.js:353218`] | the taxonomy is not on the wire | R | Useful as a grouping template for the GUI's own settings window. |
| `/keybindings` — writes `~/.claude/keybindings.json` **only if absent**, from a template that is the full default table minus the non-rebindable keys, then opens it in the external editor. Outcomes: `Keybinding customization is disabled in this environment.`, `Created <path> with template. Opened in your editor.`, `Opened <path> in your editor.` (+ a safe-mode suffix) | §42.24.2 [`chunk-1kg58a1a.js:143976`, `chunk-55zhfsqw.js:268142`] | `type:"local"`, **`supportsNonInteractive:false`** → refused headless; confirmed absent from the live command list | **X** | A GUI must implement its own keybinding editor. This is the natural place to exceed the TUI: a real editor with validation surfaced live (§42.8) instead of a JSON file opened in `vi`. |
| `/focus` | §42.24.3 | `local-jsx` + `requires:{ink:true}`; absent from the live command list. State is settable via `apply_flag_settings` | X (command) / R (state) | Its TUI refusal text is instructive: `Focus view needs the fullscreen renderer…` — the whole feature is renderer-gated. It also refuses to toggle off when the state came from the `viewMode` setting. |
| `/vim` | §42.24.4 | absent (gate `tengu_maple_sundial` default off) | X | |
| `/terminal-setup` | §42.24.5 | absent | X + T | Superseded. |
| `CLAUDE_CODE_KB_COHESION_FIXES` | §42.24.6 [`chunk-92mnx5nj.js:336503`] | env var on the child | R | Changes two user-visible behaviours: drops `ctrl+b` out of the single-key pass for `task:background`, and switches Up/Down to walk a queued-message selection index. Both are TUI-only. |
| `CLAUDE_CODE_SKIP_PROMPT_HISTORY` | §42.24.6 | env var on the child; **the GUI must honour it in its own history writer too** | R | |
| `CLAUDE_CODE_SESSION_KIND=bg`, `CLAUDE_CODE_BS_AS_CTRL_BACKSPACE`, `CLAUDE_CODE_ALTGR_AS_TEXT`, `CLAUDE_CODE_ACCESSIBILITY`, `CLAUDE_CODE_NATIVE_CURSOR`, `CLAUDE_CODE_ENABLE_MENU_KIND_LANES` | §42.24.6 | — | T | All terminal-decoder or terminal-cursor concerns. |
| `CLAUDE_CODE_GLOB_TIMEOUT_SECONDS` | §42.24.6 | env var on the child | P | Affects the shared file index, so it affects `file_suggestions` too. |
| Gates `tengu_keybinding_customization_release` (true), `tengu_left_arrow_editing_guard` (true), `tengu_maple_sundial` (false), `tengu_mint_lanes` (false), `tengu_jiggly_mochi`, `tengu_copper_thistle` (false) | §42.24.7 | not readable over the wire | D (minor) | The GUI cannot read Statsig gates and must assume the documented defaults. Only `tengu_maple_sundial` changes a user-visible surface (`/vim`), and it is off. |

## 42.25 Telemetry

No user-visible effect; the brief excludes it. Two absences are worth recording because they
affect what a GUI can measure: **there is no event for "suggestion shown" or "suggestion
accepted", and no event on a vim mode transition** (§42.25).

---

## Top gaps in this area

Ranked by how much they cost the product.

1. **`~/.claude/keybindings.json` is invisible to the headless CLI (R, large).** Users have real
   files with custom chords, `null` unbindings and `command:` bindings. The GUI must parse the
   file, reproduce the merge order (defaults + user appended, **last wins**, `null` unbinds
   *and consumes*), the alias/sort normalisation, the 23 contexts, the 1000 ms chord window, and
   the `command:`-is-Chat-only rule — and hot-reload it. Ignoring the file is a visible
   regression for every power user; honouring it is also the single largest chance to exceed the
   TUI, because a native app can deliver `ctrl+i`, `ctrl+m`, `ctrl+[`, `ctrl+h` and `capslock`
   that the terminal reserved (§42.8.5). (§42.7, §42.8)
2. **`chat:killAgents` has no wire equivalent (D).** Nearest is `interrupt {cancel_queued:true}`
   plus one `stop_task` per live task id. Not reachable at all: the live-document watch teardown,
   the artifact auto-reply disarm, and the disclosure notification. Note also that plain
   `interrupt` does **not** stop tasks (`durable:false` skips the stop). (§42.21.8)
3. **The `!` bash path is genuinely different headless (D).** `bash_command` is a one-shot
   `/bin/sh -c` with **no persistent shell state** and **no transcript entry**, so the model never
   sees the output and `respondToBashCommands` has no analogue; it does add
   `<bash-exit-code>`. For TUI parity, run the shell host-side and send a normal `user` frame
   wrapped in `<bash-input>`/`<bash-stdout>`/`<bash-stderr>`; use `bash_command` only for a
   dedicated terminal pane. (§42.16.1)
4. **The Shift+Tab ring's availability is not on the wire (D).** `initialize` gives
   `current_permission_mode` but never says whether `bypassPermissions` or `auto` are in the
   ring, and `dontAsk` is reachable only outside the cycle. Workaround: the GUI's own launch
   flags plus `get_settings` killswitches, or probe with `set_permission_mode` and read the
   error. (§42.22.3)
5. **`file_suggestions` returns the same results but drops the `score` (D, small but sharp).**
   Same function, same index, same ignore rules, same 15 cap; the handler emits `{path}` only
   even though the schema allows `{path, score?}`. The §42.17.4 `@` merge against MCP and agent
   rows is *defined by* that score. Reconstruct it as `rank/count` — which is exactly what the
   TUI exposes. Also: `showOnEmpty` is forced true, and there is no `indexBuildComplete`
   signal, so a partial-index result is never upgraded. (§42.18.1)
6. **`/btw` must be translated, not typed (R).** It is absent from the headless command list but
   its descriptor carries `thinClientDispatch:"control-request"` → the `side_question` control
   request, whose answer streams as the only `control_request_progress` frames. A GUI that just
   forwards `/btw …` as text gets a refusal. (§42.20.6)
7. **Queue editing decomposes into cancel + re-send (R).** `popAllEditable` /`popEditableAt` map
   to `cancel_async_message {message_uuid}` followed by a fresh `user` frame. The catch:
   `command_lifecycle: cancelled` cannot distinguish a user-requested cancel from a swept one,
   so the GUI must correlate against its own cancel responses and any `interrupt` receipt's
   `cancelled` list before resending. (§42.20.3)
8. **`/keybindings` is refused headless (X).** `supportsNonInteractive:false`, confirmed absent
   from the live 2.1.259 command list. The GUI must ship its own keybinding editor — and should,
   surfacing the §42.8 validation live instead of writing it to a debug log. (§42.24.2)
9. **The rewind dialog is three mechanisms, not one (R).** "Restore conversation" =
   `rewind_conversation` (returns `prefillText` and `precedingAssistantUuid` — both directly
   useful), "Restore code" = `rewind_files` (use `dry_run:true` for the preview counts and
   surface `skippedLinks`), "Summarize from/up to here" = a `user` frame carrying
   `summarize_metadata {direction:"from"|"up_to"}`. All reachable; none composed for you. Plus
   eight distinct refusal strings to render. (§42.21.3)
10. **`#` Slack targeting is rebuildable but non-obvious (R).** `mcp_status` supplies the
    connected-server list for the `name.includes("slack")` test, and `mcp_call
    {tool:"slack_search_channels", arguments:{limit:20, channel_types:"public_channel,private_channel"}}`
    is the exact call. Reimplement the regex `(^|\s)#([a-z0-9][a-z0-9_-]*)$`, the 150 ms
    debounce, the 10-row cap and the live input highlighting. (§42.16.3)
11. **Paste placeholders are a terminal workaround the GUI should replace, but history forces a
    round-trip (R).** `[Pasted text #N +M lines]`, the 800-char / 2-newline thresholds, the
    10 000-char draft truncation and the "paste again to expand" hint all exist because a
    terminal cannot draw a chip. Use attachment chips and send expanded text — but write the
    placeholder form back to `history.jsonl` (with the ≤ 1024-char inline / content-hash split)
    or the terminal and the GUI stop sharing history. (§42.15, §42.19.1)
12. **`app:openArtifact` has no artifact-URL frame (D).** The registry is not in the §45.9.1
    stdout catalogue; the GUI must track artifact URLs from tool output itself. Cross-ref
    chapter 44. (§42.23.1)
13. **A whole vim layer is a from-scratch rebuild (R, large).** If the GUI honours
    `editorMode:"vim"` it must match §42.13's exact scope — including what is deliberately *not*
    implemented (`%`, `{}`, `H/M/L`, buffer search, marks, `it/at`, `ip/ap`, REPLACE mode) and
    the `escape`-is-a-vim-key-unless-NORMAL precedence. Shipping "vim mode" that diverges is
    worse than shipping none. (§42.13)
14. **Autocomplete accept semantics are quietly load-bearing (R).** Tab never executes and falls
    back to row 0; **Enter with nothing selected dismisses and submits the line as typed**; file,
    Slack, resume-title and MCP-template menus deliberately start with nothing selected; `@` does
    longest-common-prefix completion first, so a single match needs two Tabs. Get these wrong and
    the GUI feels subtly broken to anyone coming from the terminal. (§42.17.6)
15. **Two TUI behaviours are bugs a GUI should not port (T).** `chat:clearInput` and
    `chat:clearScreen` are both wired to force-redraw and neither clears the input; the
    `Esc again to clear` hint lives 1000 ms while the accept window is 800 ms. Both are noted as
    open questions in the chapter itself. (§42.21.7, §42.21.2)

---

## Unverified

* **`@`-mention expansion for headless `user` frames.** The extractor
  [`chunk-1kg58a1a.js:147188`] lives in the shared attachment module and SPEC 10.12.1 says it is
  re-run at prompt submission, so a `@path` typed into a headless frame should expand exactly as
  in the TUI. I did not trace the headless call site end-to-end; chapters 10/11 own it. Verify
  before relying on "just send the literal `@path`".
* **`/config editor=vim` headless.** `/config` exists headless as a separate descriptor
  (`type:"local"`, `supportsNonInteractive:true`, `argumentHint:"key=value"`,
  [`chunk-1kg58a1a.js` near the `local-jsx` twin]) and is in the live 2.1.259 command list. I did
  not confirm that its key registry accepts the `editor` id (the `editor` id is definitely the
  `/config` panel's row id, [`chunk-9w2c2eyx.js:353218`]). The disk route (`~/.claude/settings.json`)
  is certain.
* **Whether `bash_command`'s two replayed `user` frames are gated on `--replay-user-messages`.**
  They are enqueued unconditionally at [`chunk-2rhzyjym.js:178684`, `:178690`]; I read the enqueue
  but not the downstream filter, so I did not confirm they survive without the flag. afleet passes
  the flag anyway.
* **Exactly which flag keys `apply_flag_settings` accepts on the direct stdio path.** The
  Remote-Control *bridge* allowlists only `effortLevel` and `ultracode`
  [`chunk-2x0p0v0q.js:183811`]; the direct handler [`chunk-2rhzyjym.js:178054`] is visibly broader
  (`model`, `agent`, …) but I did not enumerate it. The brief-transcript key used for
  `app:toggleBrief` / `/focus` is inferred from the `/focus` implementation's own
  `onQueryEvent({type:"apply_flag_settings", settings:{bri…}})` call, whose key name I saw
  truncated.
* **`app:openArtifact`.** I confirmed no artifact-URL frame appears in the §45.9.1 catalogue but
  did not read chapter 44; the artifacts agent may know of a frame or control request I missed.
* **Statsig gate defaults** (`tengu_jiggly_mochi` in particular) are taken from the chapter's own
  table; I did not re-derive them from the bundle.
