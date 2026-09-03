# TUI parity: what a GUI on the headless protocol loses, must rebuild, or cannot reach

Status: inventory complete for Claude Code 2.1.257 (bundle SPEC) cross-checked against the
installed 2.1.259 binary on 2026-09-03. Living document; the per-area inventories under
`areas/` are the detail, this file is the map.

## 1. Purpose

afleet hosts the unmodified `claude` binary through its headless protocol:

```
claude -p --input-format stream-json --output-format stream-json --verbose \
  --include-partial-messages --replay-user-messages --forward-subagent-text \
  --include-hook-events --permission-prompt-tool stdio --permission-prompts host \
  [--session-id <uuid> | --resume <id>] [--model] [--permission-mode] [--agent] [--effort] [-n] [--add-dir]
```

The product goal is a UX equal to or better than the native terminal UI. That is only
achievable if every user-visible thing the TUI does is accounted for: either the wire
already carries it, or the GUI rebuilds it from data it can reach, or it is a real gap that
needs a workaround or a protocol addition. This document is that accounting. It is written
for whoever builds the FleetKit reducer, the command router, the timeline and the panels.

## 2. Method and evidence

Three sources, in order of authority:

1. **The SPEC library** at `~/claude-code-bundle/2.1.257/SPEC/` (50 chapters derived from
   the 2.1.257 binary, with `cli.pretty.js` line citations). Eighteen area inventories were
   produced from it, one per group of chapters, each classifying every user-visible
   affordance. They are in `areas/` and are cited below as *A-nn*.
2. **The installed 2.1.259 binary**, probed live with the exact afleet flag set. The probe
   scripts are `probes/04` to `probes/12`; the captured results are in `evidence/`:
   - `2026-09-03-slash-commands-headless.md`: 48 slash commands sent as text, with the
     verbatim response of each.
   - `2026-09-03-background-and-subagent-frames.md`: the complete frame sequence for a
     background Bash plus an Explore subagent, and for a background task completing after
     the turn ended.
   - `2026-09-03-control-request-shapes.md`: 40 control requests including the unpublished
     ones, with observed request fields and responses; `--resume` replay behaviour;
     file checkpointing headless.
   - `2026-09-03-initialize-and-zero-cost-control-responses-2.1.259.json` and
     `2026-09-03-system-init-frame-2.1.259.json`: the handshake and first-turn init frames.
3. **`cli.pretty.js` itself**, read at the cited lines where the spec and the live binary
   disagreed.

Everything stated as fact below traces to one of these. Inferences are marked.

### 2.1 Classification used throughout

| Class | Meaning |
|---|---|
| **P** | Parity via protocol. The wire carries what is needed; the GUI only renders. |
| **R** | Rebuild. The TUI implements it client-side; the GUI must reimplement it, and the data is on the wire, behind a control request, or on disk. |
| **D** | Data gap. The TUI shows or does something whose data or control is not on the wire and not on disk. Needs a workaround or a protocol addition. |
| **X** | Unreachable. Interactive-only code path (`local-jsx` command, dialog never emitted headless, TTY-only behaviour) with no headless equivalent. |
| **T** | Terminal-specific. Only meaningful in a terminal; superseded by the GUI. |

## 3. The headless baseline in one page

What the wire gives a host, so the gaps below are read against it. Full detail: SPEC 45.

**Frames the host receives.** `system/init` at the start of every turn (tools, MCP servers,
slash commands with the `terminal_slash_commands` subset, skills, plugins, agents,
capabilities, model, permission mode, effort, fast-mode state). `assistant` per completed
content block (frames sharing `message.id` are one message; `parent_tool_use_id` and
`subagent_type` set for subagent output). `user` for tool results (with the tool's full
structured `tool_use_result`) and for replayed input. `stream_event` deltas.
`result` per turn (cost, usage, stop reason, permission denials, subagent stats).
`system/*`: status, compact_boundary, api_retry, informational banners, local command
output, hook lifecycle, task_started/updated/progress/notification,
background_tasks_changed, thinking_tokens, session_state_changed, permission_denied,
commands_changed, notification, memory_recall, elicitation_complete, and the model-fallback
family. Plus `tool_use_summary`, `rate_limit_event`, `command_lifecycle`,
`conversation_reset`, `prompt_suggestion`, `auth_status`, `keep_alive`, and the control
envelopes.

**Requests the CLI makes of the host.** `can_use_tool` (permissions, AskUserQuestion,
ExitPlanMode), `hook_callback`, `mcp_message`, `elicitation`, `request_user_dialog` (only
kinds the host declared), token-refresh requests.

**Requests the host can make.** 66 subtypes; the ones that matter here are interrupt,
initialize, set_permission_mode, set_model, set_max_thinking_tokens, apply_flag_settings,
rename_session, generate_session_title, get_context_usage, get_session_cost, get_usage,
list_models, get_binary_version, get_settings, update_settings, mcp_status, mcp_set_servers,
mcp_reconnect, mcp_toggle, mcp_authenticate, mcp_oauth_callback_url, mcp_clear_auth,
set_mcp_permission_mode_override, file_suggestions, read_file, get_workspace_diff,
get_plan, rewind_conversation, rewind_files, cancel_async_message, stop_task,
background_tasks, side_question, set_cwd, register_repo_root, reload_plugins,
reload_skills, submit_feedback, message_rated, claude_authenticate, ultrareview_launch,
end_session.

**Input frames.** `user` (text, images, `origin`, `uuid`, `shouldQuery`, `priority`),
`bash_command` (one-shot shell, no transcript), control frames, `keep_alive`.

**Slash commands.** The headless runner narrows the command table before it advertises
anything: a `prompt` command runs unless it opted out; a `local` command runs only if it
declared `supportsNonInteractive`; no `local-jsx` command runs. On 2.1.259 the advertised
`initialize.commands` list is already the runnable list: 33 built-ins plus every skill,
plugin command and custom command (102 in total on this machine). Anything else typed as
text answers with a bare assistant frame `/<name> isn't available in this environment.`

## 4. Findings from the live binary that change the design

These were established today by probe and by reading the handler source. Several correct
assumptions in the workspace design spec.

1. **`--resume` does not replay history.** A resumed headless session emits nothing until
   the first new turn. The transcript JSONL is the only source of prior messages (A-35
   agrees). The design's transcript reader is load-bearing, not an optimisation.
2. **Subagent tool calls are on the wire.** With `--forward-subagent-text`, a subagent's
   `tool_use` and `tool_result` blocks arrive as `assistant`/`user` frames with
   `parent_tool_use_id` set to the Agent call and `subagent_type` set, in addition to its
   text and thinking. `task_started` carries `spawn_depth`; `task_progress` carries a
   one-line activity description, `last_tool_name` and cumulative usage;
   `task_notification` carries `output_file`, `summary` and usage. The subagent's hooks
   also emit hook frames. SPEC 45.9.2 (2.1.257) describes text and thinking only; 2.1.259
   forwards more. Live evidence: `evidence/2026-09-03-background-and-subagent-frames.md`.
3. **Background shells are announced but not streamed.** `background_tasks_changed` and
   `task_started` (`task_type: local_bash`, `is_backgrounded: true`) arrive, and the
   `tool_result` text and the later `task_notification` both name the output file under
   `/private/tmp/claude-501/<slug>/<session>/tasks/<id>.output`. No `tool_progress` frames
   for Bash arrive outside `CLAUDE_CODE_REMOTE`. A GUI tails the file.
4. **A headless session that stays open auto-turns on background completion.** After the
   turn's `result`, when the shell finished the CLI emitted `task_updated`,
   `task_notification`, then a new `system/init`, an assistant reply and a `result`,
   with no host input. The injected `<task-notification>` user message is not emitted as
   a `user` frame, so the GUI must synthesise the timeline item from `task_notification`.
5. **`end_session` kills running background shells** (`task_updated` status `killed`,
   `task_notification` status `stopped`). Reaping a channel is destructive for its
   background work.
6. **`add_directory` is not `/add-dir`.** The handler reads `mount_path`, requires
   `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` and stages a file for a cloud container
   (cli.pretty.js 176961). Every local field name returns
   `undefined is not an object (evaluating 't.includes')`. There is no runtime equivalent
   of `/add-dir` for a local headless session; only `--add-dir` at launch.
7. **`update_settings` can write exactly one key: `outputStyle`.** The allow-list
   `T_ = new Set(["outputStyle"])` (cli.pretty.js 174361), source must be `localSettings`,
   values must be strings. Permission rules, additional directories, hooks and every
   `/config` row are unwritable through the control protocol. The headless `/config
   key=value` text command is the only remaining route for the ~40 keys it lists
   (`theme`, `editor`, `autoCompact`, `checkpoints`, `notifChannel`, `permissionMode`,
   `model`, `outputStyle`, `verbose`, `workflows`, ...); it writes the user settings file
   through the CLI.
8. **File checkpointing is off headless unless `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=1`
   is in the environment** (`pT()`, cli.pretty.js 58976). With it set, `rewind_files`
   `dry_run` reports the files and a real rewind restores them. Without it every
   `rewind_files` answers `File rewinding is not enabled.`
9. **`rewind_conversation` takes `target_message_uuid`** (not `user_message_id`) and
   returns `{rewound, targetMessageUuid, prefillText, precedingAssistantUuid}`; it refuses
   with `commands queued`, `prompt pending` or `turn running`, and accepts
   `interrupt_if_running`.
10. **`generate_session_title` takes `{description, persist}`** and returns `{title}`.
11. **`set_color` is in the schema registry but not in the dispatcher** on 2.1.259
    (`Unsupported control request subtype`); the `/color` text command works instead.
12. **`apply_flag_settings` accepts any key silently**, including nonsense, and answers
    `null`. Only `get_settings.applied` (`model`, `effort`, `advisor`, `ultracode`)
    reflects what took effect. `outputStyle`, `agent` and `viewMode` via this request are
    unverified.
13. **Fast mode is opt-in, not unavailable.** `initialize` reports
    `fast_mode_disabled_reason = sdk_opt_in_required` and `/fast` prints `Fast mode is not
    available in the Agent SDK` until the host sends `apply_flag_settings {settings:
    {fastMode: true}}`; after that the reason clears and `/fast` toggles normally (probe 09).
    The same opt-in is available at launch as `--settings '{"fastMode":true}'`.
14. **The account login flow and MCP OAuth are drivable headless.** `claude_authenticate`
    returns `{manualUrl, automaticUrl}` and `mcp_authenticate` returns `{authUrl,
    callbackExpected, redirectScheme: localhost, state}`; the CLI opens the localhost
    callback listener itself. `/login`, `/logout` and the `/mcp` auth rows are therefore
    reproducible without a terminal.
15. **`file_suggestions` returns an empty list on its first call** while the index warms,
    and its results include paths under `~/.claude/skills`. A GUI should prime it at
    channel open and expect global entries.
16. **`submit_feedback` sends real feedback** (a `feedback_id` came back for the probe).
17. **`/doctor` runs as a prompt.** It is listed in `terminal_slash_commands` but on
    2.1.259 it is a bundled skill; sent as text it went to the model, which answered from
    context. Hiding it is the right call, but it is not a refusal.
18. **`/mcp` headless prints one line** (`3 MCP server(s): 2 connected, 1 not connected, 0
    disabled. Use /mcp in the terminal for details.`); the real functionality is behind
    the eight `mcp_*` control requests.


19. **Only three dialog families cross the wire.** The headless dialog dispatcher
    (cli.pretty.js 174428) forwards `request_user_dialog` for `refusal_fallback_prompt`,
    `fable_overage_consent_prompt` and the Slack-connect kinds; MCP elicitation goes out as
    the separate `elicitation` request. Every other kind (the 9 `permission_*` kinds travel
    as `can_use_tool` instead; `auto_mode_flagged_allow`, `auto_mode_setup_review`,
    `chrome_install_*`, `cloud_sync_*`, `computer_use_approval`, `goal_proposal`,
    `ide_onboarding`, `lsp_recommendation`, `managed_settings_security`,
    `peer_inbound_approval`, `plugin_hint`, `remote_callout`, `sandbox_network_access`,
    `ultraplan_launch`, `local_jsx`) resolves to its declared default immediately, whatever
    the host declares in `supportedDialogKinds`.
20. **`--session-mirror` works on 2.1.259** although it is absent from `claude --help`. It
    emits `transcript_mirror {filePath, entries}` with the JSONL records the CLI just wrote.
    A GUI that renders from transcript records can use one reducer for archived and live
    channels and stop watching the transcript file (probe 10).
21. **`--enable-auth-status` works** and emits one `auth_status` frame after `initialize`.
22. **Headless sessions write a registry record but never publish `status`,
    `waitingFor` or `tempo`** (A-50/38, live-verified), so other tools see an afleet channel
    as a session with unknown activity.
23. **Live Bash output is not on the wire under any flag.** With `CLAUDE_CODE_CONTAINER_ID`
    set, a five-line foreground loop produced one `tool_progress` frame carrying only
    `elapsed_time_seconds` (the published schema has no output field), and the container
    variable auto-backgrounded the command. The task output file is the only live source
    (probe 11).
24. **`CLAUDE_CODE_ENTRYPOINT=local-agent` does not unlock `SendUserFile`** in practice
    (tools went from 42 to 44: `Glob` and `Grep` appeared, `SendUserFile` did not; probe 09).
    The in-process MCP replacement in the design stands.

## 5. The gap map, area by area

Each entry names the inventory file, gives the verdict for the area, and lists the gaps that
matter, with their class. Counts are feature rows in the inventory.

### A-41 Terminal rendering: footer, dialogs, tool result forms, markdown, notifications
`areas/41-tui-rendering.md`, 386 rows. Verdict: almost everything the terminal *draws* is
client-side code, and the raw material on the wire is richer than what the terminal shows.
The losses are the pushes the terminal gets for free from being in-process.

- Live tool output while a tool runs: not on the wire (D; see finding 23). The terminal
  shows `Running… <elapsed>` plus the last five lines; a GUI shows nothing until the tool
  finishes unless it tails the task output file.
- OS notifications: the internal `os_notification` message with its 14 types and texts is
  dropped (D). Workaround that restores parity: register a `Notification` hook through
  `initialize.hooks` and read it back via `hook_callback`.
- The `statusLine` payload cannot be reproduced exactly: `cost`, `prompt_cache`,
  `exceeds_200k_tokens`, `pr`, `scratchpad_dir`, `prompt_id` have no wire source;
  `get_session_cost` returns a rendered text blob (D). A user's status script that reads
  `.cost.total_cost_usd` prints nothing in the GUI.
- The context meter is poll-only: `get_context_usage` on demand, nothing pushes it outside
  `CLAUDE_CODE_REMOTE` (R). Poll after every `result`.
- 74 lazy dialog registry entries are all `local-jsx` panels: unreachable as commands, and
  the refusal text tells the user to go back to the terminal (X per panel; most have a
  control-request or on-disk equivalent).
- The notification bar: only `{key, text, priority, color?, timeout_ms?}` crosses as
  `system/notification`; the rate-limit family, ultrathink confirmation, paste eviction and
  clipboard messages are local (D; synthesise from `rate_limit_event`, `api_retry`,
  `informational`, `permission_denied`).
- Spinner stall and retry copy (`Waiting for API response`, `next try in N · attempt N/M`,
  stall thresholds at 10, 45 and 300 s) is TUI-side; `api_retry` and `rate_limit_event` are
  the raw signals (R, high perceived-quality impact).
- Custom themes under `~/.claude/themes`, `spinnerVerbs`, tip overrides and tip cadence
  state live only on disk (R, cheap).
- Untrusted-text sanitising (control and format characters, bidi overrides, zero-width
  marks) is paint-time and not inherited; markdown `html` tokens are raw passthrough in the
  TUI (R, security-relevant: implement the passes, do not copy the passthrough).
- Mermaid fences and inline images are never drawn by the terminal; the binary ships
  mermaid 11.16.1 for artifacts. The two biggest visual wins for a GUI.
- Tab status (OSC 21337, per-session colour and state word) is implemented and
  hard-disabled in the terminal; the palette is in the spec (GUI exceeds).

### A-42 Input: keybindings, editor, paste, mentions, queueing, interrupt ladder
`areas/42-input-keybindings.md`, 218 rows. Verdict: the prompt editor is a native text
field's job and mostly free; the losses are the user's own keybinding file, the `!` shell
path, and two interrupt actions with no wire equivalent.

- `~/.claude/keybindings.json` is invisible to the headless CLI (R, large). Honouring it
  means reproducing merge order (defaults plus user, last wins, `null` unbinds and consumes),
  23 contexts, the 1000 ms chord window and hot reload. A native app can also bind
  `ctrl+i`, `ctrl+m`, `ctrl+[`, `ctrl+h` and `capslock`, which the terminal had to reserve.
- `chat:killAgents` (kill every agent with confirmation) has no wire equivalent (D).
  Nearest: `interrupt {cancel_queued: true}` plus one `stop_task` per live task. Plain
  `interrupt` does not stop tasks.
- The `!` shell path differs: `bash_command` is a one-shot `/bin/sh -c` with no persistent
  shell and no transcript entry, so the model never sees the output (D). For parity, run the
  shell host-side and send a normal `user` frame wrapped in `<bash-input>`,
  `<bash-stdout>`, `<bash-stderr>`.
- Whether `bypassPermissions` and `auto` are in the Shift+Tab ring is not on the wire (D);
  derive from launch flags and `get_settings`, or probe `set_permission_mode` and read the
  error.
- `file_suggestions` drops the `score` the TUI's unified `@` merge is defined by, forces
  `showOnEmpty`, and has no index-complete signal (D, small). Reconstruct score as
  `rank/count`.
- `/btw` is refused as text and must be translated to `side_question` (R); its answer
  streams as `control_request_progress` frames, which a GUI can show as progress.
- Queue editing decomposes into `cancel_async_message` plus a fresh `user` frame, and
  `command_lifecycle: cancelled` does not say who cancelled (R).
- `/keybindings` is refused (X); ship a native editor that surfaces the validation live.
- The rewind dialog is three mechanisms: `rewind_conversation`, `rewind_files` with
  `dry_run`, and a `user` frame with `summarize_metadata {direction}` (R). Eight refusal
  strings to render.
- `#` Slack-channel targeting is rebuildable via `mcp_status` plus `mcp_call
  slack_search_channels` (R).
- Paste placeholders exist because a terminal cannot draw a chip; a GUI should use chips,
  but must write the placeholder form back to `history.jsonl` or stop sharing history (R).
- `--print` sessions neither read nor write `~/.claude/history.jsonl` (D; read it
  yourself).
- Autocomplete accept semantics are load-bearing: Tab never executes, Enter with nothing
  selected submits the raw line, `@` needs two Tabs for a single match (R).

### A-28 Slash commands: the complete catalogue
`areas/28-slash-commands.md`, 109 master rows covering all 126 catalogue objects plus the
dynamic sources. Verdict: on this transport `initialize.commands` already *is* the runnable
list (33 built-ins on 2.1.259 plus skills, plugin and custom commands); everything the
terminal implements as a panel is absent and must be a native affordance.

- Refused as text on 2.1.259 (live): `/help`, `/status`, `/tasks`, `/permissions`, `/vim`,
  `/rewind`, `/resume`, `/memory`, `/hooks`, `/skills`, `/plan`, `/diff`, `/btw`, `/export`,
  `/theme`, `/terminal-setup`, `/keybindings`, `/release-notes`, `/copy`, `/bug`,
  `/add-dir`, `/cd`, `/branch`, `/fork`, `/background`, `/loops`, `/tui`, `/focus`,
  `/brief`, `/sandbox`, `/ide`, `/statusline`. One refusal string covers three causes.
- Ran as text (live): `/context`, `/cost`, `/usage`, `/stats`, `/model [name]`, `/config
  [key=value]`, `/mcp` (one line), `/agents` (removed notice), `/rename`, `/effort`,
  `/fast`, `/color`, `/goal`, `/doctor` (as a prompt), plus every skill.
- With a control-request route: `/model` (`list_models`, `set_model`), `/effort` and
  `/fast` (`apply_flag_settings`), `/rename` (`rename_session`), `/btw` (`side_question`),
  `/context` (`get_context_usage`), `/diff` (`get_workspace_diff`), `/usage`
  (`get_session_cost`, `get_usage`), `/plan` view (`get_plan`), `/rewind`
  (`rewind_conversation`, `rewind_files`), `/cd` (`set_cwd`), `/mcp` (eight `mcp_*`
  requests), `/reload-plugins` (`reload_plugins`), `/reload-skills` (`reload_skills`),
  `/bug` and `/feedback` (`submit_feedback`), `/login` (`claude_authenticate` family),
  `/ultrareview` (`ultrareview_launch`), `/tasks` stop (`stop_task`, `background_tasks`),
  `/clear` and `/compact` (text; `conversation_reset` and `compact_boundary` frames).
- No route at all: `/permissions` (read via `get_settings`, no editor), `/add-dir` (finding
  6), `/memory`, `/resume` (disk), `/export`, `/copy`, `/help`, `/status` (mostly
  reconstructible), `/hooks` (read-only from disk), `/skills`, `/plugin`, `/logout` (shell
  out to `claude auth logout`), `/theme`, `/tui`, `/focus`, `/brief`, `/vim`, `/keybindings`,
  `/statusline`, `/terminal-setup`, `/release-notes`, `/branch`, `/fork`, `/background`,
  `/subtask`, `/ide`, `/chrome`, `/sandbox`, `/voice`, `/desktop`, `/mobile`, `/teleport`,
  `/remote-control` (the `remote_control` request exists), `/artifacts`, `/workflows`.
- Data the wire drops from command rows: `type`, `source`, `loadedFrom`, `kind`,
  `isHidden` (hidden internals such as `__remote-workflow` are advertised), `argNames`,
  `subcommands`, `progressMessage`, and `getArgumentCompletions` (a function; `/config`,
  `/plugin` and the `design` skill lose completion) (D).
- Plugins may claim the `help` and `feedback` aliases in headless sessions.

### A-20 Tasks and background work
`areas/20-tasks-background.md`, 163 rows. Verdict: the wire announces background work
(start, update, completion, and the output file path) but streams none of it, has no query
for the current task set, and starts turns on its own when work completes.

- Live stdout of a background or long-running shell is not on the wire (finding 23). Tail
  `<realpath(tmpdir)>/claude-<uid>/<project-slug>/<session>/tasks/<taskId>.output`, whose
  path arrives in the Bash tool result text and in `task_notification.output_file` (R,
  file).
- There is no way to *list* background tasks: `background_tasks` is the ctrl+b action, not
  a query (live: answers `{}`). Build the registry mirror from `task_started`,
  `task_updated` and `background_tasks_changed` (R, foundational).
- The task-notification injection is invisible and starts an unprompted turn (finding 4)
  (D; synthesise the item from `task_notification`).
- `perTaskStopAffordance: true` must be declared in `initialize`, or every `interrupt`
  kills the user's background agents; absence fails closed (P, free, easy to miss).
- `background_hint` (the terminal's "offer run-in-background" moment) never reaches the
  wire; run a two-second timer per in-flight Bash call (D).
- A background shell's command and cwd are not in `task_started` (only a description);
  correlate the command through `tool_use_id`, cwd is lost (R plus D).
- Ending the session kills every running background shell, including via `end_session`
  (finding 5); there is no graceful-detach route (P, needs a warning at teardown).
- `TaskOutput` suppresses the terminal `task_notification` by stamping `notified`, so
  completion detection must also watch `task_updated` (D).
- Parked agents are indistinguishable from finished ones (`keepaliveReasons` is off the
  wire); no `startTime`, so ages are wrong after a resume (D).
- `/tasks` is unreachable and absent from the command list; its content is rebuildable (X
  for the dialog, R for the content). Foregrounding a task has no surface (X).
- The persisted task list (`TaskCreate` family) is invisible to the protocol; read
  `~/.claude/tasks/<sessionId>/*.json`. The task tools are off on current models unless
  `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` (R, disk).
- Queue-only notifications are wholly invisible: every `Monitor` event and the
  stuck-on-an-interactive-prompt watchdog. Both are reimplementable from the output file,
  and doing so is a better affordance than the terminal's (D).
- Monitor rows are indistinguishable from ordinary background shells (`shell_kind` is not
  emitted) (D, low impact).

### A-18 Agents and subagents
`areas/18-agents-subagents.md`, 144 rows. Verdict: subagent visibility is not the large gap
it was expected to be; depth-1 activity is fully on the wire, and the real losses are
naming, colour, and the absence of a backgrounding control.

- Depth-2 and deeper activity is visible only with `--forward-subagent-text`, and even then
  the parent link is implicit: no `parentAgentId` on any frame. Rebuild the tree with a
  two-step join on `tool_use_id` (R; undocumented).
- Agent colour is nowhere on the wire; `initialize.agents` is `{name, description, model}`.
  Parse the agent markdown frontmatter or the `.meta.json` sidecar after spawn (R).
- No way to background a running foreground agent; the terminal has ctrl+b (D, no
  workaround).
- `task_progress` is tool-paced: an agent thinking for forty seconds emits nothing. Tick
  elapsed locally; `agentProgressSummaries` opts into a model-written activity line about
  every 30 s (R; the frame was not observed in the short probes).
- The completion notification injected into the conversation is not framed as a user
  message (finding 4).
- `can_use_tool` and `permission_denied` identify the asking subagent by `agent_id` only;
  map it to `task_started.task_id` (same value) for type and description (R).
- The `<taskId>.output` file is a symlink to
  `~/.claude/projects/<slug>/<sessionId>/subagents/agent-<taskId>.jsonl`, the full-fidelity
  fallback during and after the run (R).
- `subagentStatusLine` never reaches the wire; read the setting and run it yourself (R).
- Fork subagents resolve to `disabled` in non-interactive sessions; enabling them strips
  `run_in_background` (T, deliberate).
- Silent degradations with no frame: MCP servers blocked for an agent, remote isolation
  falling back to worktree or local (D).

### A-24/21 Permissions, plan mode, questions
`areas/24-21-permissions-plan-questions.md`, 201 rows. Verdict: the permission round trip is
complete for approve, deny, edit-input and add-rule, and incomplete for everything the
dialog says *around* the decision.

- `/permissions` is unreachable and must be rebuilt from `get_settings`; there is no control
  request that removes a rule or a directory. Rules can be added persistently only through
  `updatedPermissions` on an open `can_use_tool`, whose `destination` may name
  `userSettings`, `projectSettings` or `localSettings` (X plus D).
- No `permission_*` dialog kind crosses the wire; the GUI reconstructs the Bash, file diff,
  WebFetch, MCP, Agent, skill, plan and question variants from `tool_name` plus `input`,
  and loses `classifierState`, `operationType`, `verbPhrase`, `intervalMs` and the rendered
  tool-use line (R plus D).
- `decision_reason` is empty for the four commonest escalation types (`rule`, `mode`,
  `subcommandResults`, `permissionPromptTool`) and the outside-reads safety check; rebuild
  the consent line from `decision_reason_type` plus `matched_ask_rule` (D).
- Reject-with-feedback changes semantics: the TUI's rejection is a soft `ask` that is not
  booked; the wire only offers `deny`, which is booked into `result.permission_denials`.
  The host composes the model-facing string itself (four variants) and decides `interrupt`
  (R).
- Accept-with-feedback ("yes, but do X"), images on a rejection, and the `userModified`
  signal have no wire fields; plan editing is the exception, `input.plan` round-trips (D).
- "Approve and clear context" is four operations headless: deny, `/clear`,
  `set_permission_mode`, seeded message (D with workaround).
- Auto-mode availability is not on the wire (D). Probing `set_permission_mode` switches
  the mode on success.
- Rule validation and warning text (16 checks, dangerous-rule stripping) goes to the debug
  log headless; a rule editor must reimplement the validators (D plus R).
- The denial-limit fallback and its countdown are invisible; headless the limits abort the
  agent (`too many classifier denials in headless mode`). Count `permission_denied` frames
  against 3 consecutive and 20 total (D).
- `localDisplayOnly` asks arrive with `requires_user_interaction` but their disclosure never
  crosses (X).
- `AskUserQuestion` previews are off for SDK-shaped clients unless
  `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT` is set (D, cheap).
- `updatedInput` fully covers editing a tool's input before approval (P).
- The host must handle its dialog being cancelled by the `PermissionRequest` hook race
  (`control_cancel_request`) (P, correctness).

### A-26 Auto mode
`areas/26-auto-mode.md`, 120 rows. Verdict: the classifier's decisions are mostly silent on
the wire; the setup wizard's model call and write are reachable, its dialogs are not.

- An `allow` decision produces no frame; the terminal prints `Allowed by auto mode
  classifier` under each approved result (D). `AUTOMODE_DECISION_LOG=1` writes a
  per-decision JSONL record with verdict, stage, matched rule and tokens.
- No signal that a classifier call is in flight and no timeout budget on the wire; a tool
  call can sit silent for up to 120 s. The terminal has no indicator either (GUI can
  exceed).
- Classifier cost is excluded from `modelUsage`, `total_cost_usd` and `/cost` (D).
- `autoMode` rules cannot be written persistently through the protocol; `apply_flag_settings`
  accepts an `autoMode` block into `flagSettings` for the session (live-verified) (R).
- The dangerous-rule strip is silent: auto mode suspends bare and `*` Bash rules and all
  `Agent(...)` rules, but `get_settings` still reports them (D).
- The timed auto-deny marker on an escalated prompt cannot cross the wire; a held
  `can_use_tool` may be auto-denied after 120 s with nothing in the payload (D).
- `/auto-mode-setup --help` runs headless and returns JSON at zero cost; the two wizard
  dialog kinds are requested only by the interactive path (X for dialogs, R for the
  protocol).
- The shipped rule library is a compressed asset; a rule editor shells out to `claude
  auto-mode defaults`. Dropping `"$defaults"` from an array silently replaces the 69 shipped
  block rules.
- "Explain why this was blocked" has no data behind it anywhere (D).

### A-31/27 MCP and hooks
`areas/31-27-mcp-hooks.md`, 158 rows. Verdict: MCP management is fully drivable through
control requests (including OAuth, which the terminal cannot do without a browser either),
but every live state change is poll-only; hooks are visible only with
`--include-hook-events`, and hook display text is lost.

- No push frame for MCP server state changes; `mcp_status` is poll-only (D, cheap poll).
- `mcp_status` carries no tool descriptions or schemas, no `errorCode`, no error text for
  `needs-auth`, and reports `cached` as `pending` (D). `claude mcp get <name>` fills the
  rest.
- `file_suggestions` returns files only; MCP resources, templates and agents are absent
  from the `@` picker data, though `@server:uri` resolves when typed (D).
- The hook spinner's `statusMessage` and MCP tool progress notifications (`progress`,
  `total`, `message`) are dropped (D; one inference, flagged in the file).
- Auto-backgrounding of slow MCP calls is off headless unless `CLAUDE_AUTO_BACKGROUND_TASKS`
  is set (D with a one-line fix).
- The `.mcp.json` approval dialog never happens headless: project servers are silently
  approved (X, security moment lost; build a consent step from the file).
- `mcp__<server>__authenticate` stub tools are suppressed non-interactively; all re-auth is
  GUI-driven through `mcp_authenticate` (the CLI opens the loopback listener itself) and
  `mcp_oauth_callback_url` only when the browser cannot reach it (R). Live-relevant:
  `plugin:supabase:supabase` is `needs-auth` on this machine.
- Stop-hook and PreCompact/PostCompact display blocks and the `hook_permission_decision`
  attachment are not on the wire; `--include-hook-events` is effectively mandatory (D).
- Editing hook files takes effect only after a snapshot reload no control request forces;
  prefer SDK callback hooks via `initialize.hooks` (D).
- Where the GUI exceeds: `set_mcp_permission_mode_override` has no TUI surface; in-process
  SDK MCP servers; SDK callback hooks survive the managed `disableAllHooks` switch;
  `elicitation_complete` closes a waiting dialog on push; `/hooks` is read-only in the TUI.

### A-30/29/32 Plugins, skills, output styles
`areas/30-29-32-plugins-skills-styles.md`, 168 rows. Verdict: the `/plugin` and `/skills`
panels have no headless surface at all; their capability is rebuildable from registry files
plus the `claude plugin` CLI plus `reload_plugins` and `reload_skills`.

- `/plugin` (five tabs, install, enable, marketplace lifecycle) and `/skills` (four
  override states, lock precedence, the delete-when-equal-to-baseline write rule) are `X`
  for the panel, `R` for the capability.
- `when_to_use` is on no frame; only in `SKILL.md` frontmatter (D).
- The over-budget skill-listing warning is a log line, not a frame; this user's
  `skillListingBudgetFraction` is 0.02 (D; a clear place to exceed).
- `reload_plugins` skips the prompt-cache pre-flight the slash command runs; no `--force`
  equivalent (D).
- No plugin trust or consent dialog is reachable (X, see finding 19).
- `command`-source installs can fail silently from a GUI: the CLI ignores `-y` inside a
  Claude Code session and without a TTY only displays the command (R, operational caveat).
- A `force-for-plugin` style is invisible: `initialize.output_style` reports the raw setting
  (D).
- The "Plugins changed, run /reload-plugins" and autoupdate banners are Ink-only (D).
- Skill invocation echoes need grouping via `sourceToolUseID` or raw `<command-name>` XML
  appears as user text (P data, R rendering).
- Provenance labelling in autocomplete is free: descriptions carry `(plugin-dev)` prefixes
  and `(user)` suffixes (P). Edited skill files are picked up automatically and announced
  by `commands_changed` (P).
- Only `outputStyle` is writable through `update_settings` (finding 7).

### A-03/49/35 Settings, diagnostics, sessions
`areas/03-49-35-settings-diagnostics-sessions.md`, 178 rows. Verdict: reading is nearly
complete, writing is nearly absent, and the session picker is entirely the GUI's.

- `update_settings` writes exactly one key (finding 7); every other persisted setting goes
  through `/config key=value` as text (works headless) or a file edit (D).
- Resume replays nothing (finding 1); chain reconstruction, parallel tool-result recovery
  and the `last-prompt` leaf rule are the GUI's to reimplement from the 22 transcript
  record types (D; the file lists each type with its rendering consequence).
- `--session-mirror` (finding 20) removes almost all transcript watching (P, unused).
- No settings-change frame; external edits are picked up in about 1.5 s but silently.
  Poll `get_settings` or install a `ConfigChange` hook (D).
- Workspace trust is silently degraded in `-p`: the persisted flag stays false, so repo
  `permissions.allow`, additional directories, hooks, `statusLine`, `fileSuggestion` and
  every credential helper are dropped and `env` runs in safe mode. The only in-protocol
  persist is the `set_cwd` `needs_trust` handshake, and it covers the target of a directory
  change, not the startup cwd (D plus security).
- A long-lived process cannot learn a new build exists in-band; watch
  `~/.claude/.last-update-result.json` and offer restart (D).
- `submit_feedback` uploads the transcript on the non-draft path regardless of
  `attach_transcript`; render the TUI's consent disclosure first (D plus privacy).
- `/status` is about 80% reconstructible; compliance verdict, provider and proxy rows and
  the diagnostics block need `claude doctor` as a subprocess (R plus D).
- `get_settings.errors` drops status notices and validation metadata (D).
- `~/.claude.json` (trust, onboarding, `projects` map, tips history, sixteen UI keys) is
  outside the protocol (D).
- The rate-limit resume checkpoint (`.claude/RESUME.md`) never fires headless (D).
- `/export`, `/branch`, `/release-notes`, `/upgrade` are unreachable and trivially exceeded
  (X to opportunity).

### A-13/10/23 Context, memory, session and utility tools
`areas/13-10-23-context-memory-session-tools.md`, 146 rows. Verdict: context accounting is
better than the TUI's (one control request returns the whole analyser), compaction and
memory are the quiet losses, and the tool list has a definite headless-disabled set.

- `SendUserFile` is off under the `sdk-cli` entrypoint (D; the in-process MCP replacement
  stands, finding 24).
- Microcompact (`hint_clears`) is not on the wire: the CLI rewrites old tool-result bodies
  in the model's context while the GUI shows the originals (D, cleanest protocol-addition
  candidate).
- `/memory` is unreachable and absent from `slash_commands`; rebuild from
  `get_context_usage.memoryFiles` plus disk (X plus R).
- `memory_saved` is dropped: no "Saved memory" indicator. Watch the memory directory and
  match memory-dir `Write`/`Edit` calls (D).
- `autocompact_state` needs `CLAUDE_CODE_REMOTE`, which is a trap (it disables auto-memory
  and re-gates reactive compaction); recompute the countdown from
  `get_context_usage.autoCompactThreshold` (R).
- `compact_progress` is dropped; `system/status {compacting}` plus `compact_result` and hook
  events recover most of the five-phase spinner (D).
- The Esc-Esc message selector and partial "summarize from here / up to here" compaction
  are unreachable as UI; the `user` frame with `summarize_metadata` is the mechanism (R).
- `ProposeGoal` is the one tool gated on a TTY; `/goal` works (X).
- `ReportFindings` renders as a raw tool call; the findings UI is client-side (R, a place a
  GUI wins).
- `PushNotification`'s `os_notification` is dropped; fire the native notification from the
  `tool_use` input and set `CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK=1` (R).
- No exit-time worktree keep/remove prompt headless; worktrees accumulate (D).
- The external-CLAUDE.md-imports consent dialog never fires; out-of-cwd imports are silently
  dropped (X).
- Several result strings name TUI affordances (`ctrl+o`, `Press esc twice`, `/memory`,
  `/mcp`); a rewrite table is warranted (R).
- Tools absent headless with the reason: `ProposeGoal` (TTY), `SendUserFile` (surface),
  `SendFeedback`, `EndConversation`, `REPL`, `Artifact*` (entrypoint `sdk-cli`),
  `SearchPlugins`/`ListSkills` family and connector tools (remote or desktop entrypoint),
  `propose_skills`, `Projects` (`CLAUDE_PROJECT_UUID`), `RefreshMcpTools` (env; worth
  enabling), `TodoWrite` (superseded by Task tools). `--brief` does work headless.

### A-11/14 Query loop and tool interface
`areas/11-14-query-loop-tool-interface.md`, 191 rows. Verdict: per-tool rendering is a
wholesale rebuild with better raw material than the terminal has; retraction and attachments
are the protocol's weak spots.

- Six renderer hooks plus `userFacingName`, `getActivityDescription`,
  `getToolUseSummary`, `isSearchOrReadCommand`, `isTransparentWrapper` are client-side code
  and none of their output crosses; the wire `user` frame carries the tool's full structured
  Output object (R, with `structuredPatch`, `oldString`/`newString`, `originalFile`, file
  content, image and PDF bytes, notebook cells and Grep modes all present; A-15/16/17
  confirms the stripping hooks apply only to the Artifact family).
- Retraction is half-signalled: `supersedes` only for the refusal path; tombstones from
  model-chain advance, malformed-tool-use retry and orphan repair leave phantom messages
  (D).
- The refusal-continuation collapser has no wire twin, so duplicated text appears after a
  refusal fallback (D, highest-value single addition).
- About 31 of 35 TUI-visible attachment types vanish; only `queued_command`,
  `hook_system_message` and `tool_host_result_lines` become frames (D).
- No tool metadata on the wire: `system/init.tools` is names only; `mcp_status` gives
  `{name, annotations}` per MCP tool, no descriptions or schemas (D).
- `can_use_tool.display_name` is a generic prettifier, not `userFacingName` (R).
- Tool allow and deny sets cannot change mid-session; no control request (D).
- Deferral is on by default and every MCP tool is deferred, so `init.tools` overstates
  immediate availability; consider `ENABLE_TOOL_SEARCH=auto:10` (R).
- `response_length` is dropped, so the token counter freezes during compaction (D).
- `isSynthetic` conflates `isMeta`, `isVisibleInTranscriptOnly` and `isCompactSummary` (D).

### A-15/16/17 File tools, Bash, sandbox
`areas/15-16-17-file-bash-sandbox.md`, 157 rows. Verdict: file-tool data is strictly richer
on the wire than in the terminal; the Bash live view and the sandbox posture are the losses.

- Live Bash output streaming: not on the wire (D; finding 23). Protocol-addition candidate
  one.
- No control request backgrounds a running foreground command; the terminal's ctrl+b has no
  equivalent among the 66 requests (D, candidate two).
- File checkpointing is off by default headless (finding 8; one environment variable).
- The effective sandbox policy is invisible: the `/sandbox` panel and the
  `sandbox_instructions` attachment are unreachable; `claude sandbox status` gives posture
  but not the path and domain lists (D).
- The eleven trusted-tier sandbox settings are unwritable through the protocol (D).
- The externally-changed-file reminder is dropped: the model is told, the host is not (D).
- "Did this command run sandboxed" is not on the wire; reproducing the `SandboxedBash`
  badge means reimplementing the predicate and `excludedCommands` matching (D).
- Persisted output is a win: `persistedOutputPath` and `persistedOutputSize` are structured
  fields pointing at a readable file (P).
- Image, PDF page and notebook cell bytes are on the wire; the terminal prints `Read image
  (240KB)` (P, GUI exceeds).
- `<sandbox_violations>` is stripped by the TUI but present on the wire (P, GUI exceeds).
- The network-access prompt arrives as `can_use_tool` with the persist rule in
  `permission_suggestions` (P).
- Startup sandbox warnings arrive on stderr, not as frames, except the `failIfUnavailable`
  hard stop (R).

### A-06/08/02 Models, auth, bootstrap
`areas/06-08-02-models-auth-bootstrap.md`, 193 rows. Verdict: model and effort control is
complete; sign-in is drivable; the security-relevant loss is the skipped trust dialog, and
the UX loss is no auto-continue at a usage-limit reset.

- Workspace trust dialog skipped in `-p` (D, security; afleet must own its trust
  decision).
- No auto-continue when a usage limit resets; the terminal parks and resumes, headless
  fails the turn. Rebuild from `rate_limit_event.resetsAt` (D).
- `unavailable_models` is populated only for the `claude-vscode` entrypoint; a third-party
  GUI never learns which models are disabled or why (D).
- `/login` and `/logout` are absent but sign-in is drivable: `claude_authenticate` returns
  `{manualUrl, automaticUrl}` with the browser left to the host, `claude_oauth_callback
  {authorizationCode, state}`, `claude_oauth_wait_for_completion` returns `{account}`;
  logout shells out to `claude auth logout` (R).
- Fast mode is opt-in (finding 13).
- `--enable-auth-status` is real and the only channel carrying credential-helper output
  (P, add it).
- `refusal_fallback_prompt` must be declared in `supportedDialogKinds` or the fallback
  degrades silently to the classic refusal error (R).
- The consumer-terms notice exits 1 through stderr with no frame; onboarding never
  completes headless (D).
- Effort cost multipliers and the `max` warning are not on the wire; `max` cannot be set
  mid-session through `apply_flag_settings`; the launch-time effort pin cannot be released
  (D).
- No "new version available" signal (D).
- `get_usage.rate_limits` is richer than SPEC 08 documents (`severity`, `is_active`,
  `spend`, `model_scoped`), and `behaviors` is a usage-pattern profile, not a rate-limit
  structure (P).

### A-33/34/43/44 IDE, LSP, voice, artifacts
`areas/33-34-43-44-ide-lsp-voice-artifacts.md`, 103 rows. Verdict: none of these four
surfaces reaches a headless session; the two that matter (diff-in-editor, selection context)
are the host's job by construction.

- Diff-in-editor is not a protocol feature: the IDE diff race starts from the interactive
  permission dialog, never from `can_use_tool`. The equivalent is `allow` with
  `updatedInput`. Registering as an IDE in v1.1 would not deliver it for afleet's own
  headless child (R, design correction).
- Selection and open-file context (`selected_lines_in_ide`, `opened_file_in_ide`) are
  REPL-mounted subscriptions; the GUI injects them itself, and `@relative/path#L12-30` in
  the composer drives the CLI's whole mention pipeline (R).
- Diagnostics after edits (IDE and LSP) reach the model but never the host; the TUI shows
  them to no one either (absolute gap, D).
- No frame announces a file changed on disk; the notifier is dead code (D).
- `/artifacts` is unreachable and its REST endpoints need a claude.ai bearer the host does
  not hold; drive the model's `Artifact` tool instead (X).
- `/design-login` cannot run headless (X).
- Voice is unreachable and entirely replaceable by native dictation (X to exceed).
- `lsp_recommendation` is a dialog kind the GUI can win outright; LSP has no status surface
  at all (exceed).
- `code_change_published` and `vcs_state_changed` are git frames (A-22/47/40), not artifact
  frames.

### A-50/36/39/38 Notifications, Remote Control, teams, daemon
`areas/50-36-39-38-notifications-remote-teams-daemon.md`, 220 rows. Verdict: a headless
session can be Remote-Controlled from the phone, channel and peer attribution is on the
wire, and the losses are presence publication and the local half of notifications.

- Headless sessions write a registry record but never publish `status`, `waitingFor` or
  `tempo` (finding 22). Workaround: afleet writes those fields into the child's registry
  file; the schema is public and readers are defensive.
- A headless-hosted session can be Remote-Controlled from claude.ai mobile: the
  `remote_control` handler is in the dispatcher and this machine reports
  `remote_control_available: true` headless (P, highest-leverage capability in the area).
  The request emits an undocumented `system/bridge_state` frame with `state`, `detail`,
  `bridge_epoch`.
- `origin` on `user` frames carries channel, peer and coordinator attribution (P).
- `PushNotification`'s `user_present` guard is blind to the GUI; use
  `CLAUDE_CLIENT_PRESENCE_FILE` or `CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK` (D).
- `os_notification` is dropped; the `Notification` hook is the only complete channel (D).
- A held cross-session message parks with no way to ask the host; set
  `crossSessionInbound` explicitly (D).
- `away_summary` is unreachable; its trigger is terminal focus, and no request reports host
  focus (D; a GUI genuinely knows about focus).
- `--dangerously-load-development-channels` needs a TTY dialog; `channel_enable` at runtime
  is the supported alternative (X).
- `queued_notification` and `session_notice` are server-authored only; the host-to-model
  event channel is `poll_event`, which needs `CLAUDE_CODE_POLL_EVENTS=true` and permission
  mode `auto` (X).
- `ListAgents` returns a formatted string; read `~/.claude/sessions/*.json` for the roster
  (D).
- `--prompt-suggestions` is free parity not being taken (P).
- Teammate protocol frames are intercepted before the model; lifecycle frames and
  `<teammate-message>` prose do arrive, so a read-only team view is achievable (D).

### A-46/19/48/37 Chrome, computer use, web tools, enterprise, cloud
`areas/46-19-48-37-chrome-web-enterprise-cloud.md`, 150 rows. Verdict: the browser and
computer-use surfaces are interactive-only; web tools are fine except progress; two
enterprise gates are waived headless and one is security-relevant.

- WebSearch live progress (`Searching: <query>`, `Found N results`) is not on the wire (D).
- Cloud-session create progress (seven checklist kinds) never leaves the process (D).
- Computer use cannot be enabled headless at all; the only workaround is hosting `claude
  --computer-use-mcp` yourself through `--mcp-config` (X).
- WebFetch and WebSearch structured outputs are truncated at the wire: `bytes`, `code`,
  `searchCount`, `durationSeconds` are lost (D).
- The managed-settings approval gate is waived headless: a dangerous remote payload is
  applied with no prompt (`deferred_non_interactive`) (X, security-relevant; read
  `remote-settings.json` and `remote-settings-consent.json` yourself and refuse to launch).
- A GUI driving a cloud session gets an empty `initialize` reply (D).
- Headless-cloud non-fatal notices go to stderr only when stderr is a TTY (D).
- The org `monitoring_notice` banner never reaches the wire (D).
- The cloud permission relay is disabled in non-interactive sessions (X).
- Screenshots and search citations are already on the wire as image blocks and `Links`
  JSON (GUI exceeds).
- `--chrome` must be passed explicitly (R).

### A-22/47/40 Goals, git and GitHub, workflows
`areas/22-47-40-goals-git-workflows.md`, 153 rows. Verdict: git state is the GUI's to read
from disk, the workflow phases view has no live representation, and the worktree exit dialog
simply does not exist headless.

- The workflow phases view has no live wire representation: per-agent progress reaches
  stdout as one throttled `tool_progress` line per 10 s. Poll `background_tasks`, whose
  task record carries the full `workflowProgress` array (R). Per-agent skip, retry and
  pause inside a running workflow have no control request (D, no workaround).
- The worktree exit dialog is not a dialog kind; a headless session exiting inside a
  worktree silently leaves the worktree and branch on disk. The GUI runs the three probes
  and drives `ExitWorktree` itself (X to R).
- `active_goal` frames are `CLAUDE_CODE_REMOTE`-only; track goal state client-side (D).
- The no-op streak fold and `scheduled_task_fire` records are absent from the wire; rebuild
  the fold from each `ScheduleWakeup` call's `noop` argument (D).
- The dynamic-loop keepalive lives in a React hook; headless loops stop silently when the
  model forgets to re-arm. The GUI needs its own 1200 s fallback timer (D).
- The branch name has no wire source; read `HEAD` from disk and use `vcs_state_changed`
  only as cache invalidation (R).
- The PR-status poller is disabled headless; no PR badge data arrives. Use `gh pr view
  --json` (R).
- The rate-limit checkpoint never runs headless, so there is no `RESUME.md` safety net (D).
- `file_snapshot` frames are dropped, so checkpointed messages cannot be enumerated even
  though `rewind_files` works (D).
- `/loops`, the only surface showing cron jobs and goals together, is dead in the binary;
  rebuilding it is a clear chance to beat the terminal (exceed). Session-only cron jobs
  are invisible from outside the process (D).
- `/diff`, `/workflows`, `/install-github-app` are `local-jsx`; the first two have clean
  data substitutes (`get_workspace_diff`, `background_tasks`), the third needs full
  reimplementation (X).
- The `ultracode` keyword veto (`alt+w`) has no stdin representation (D).
- Commit attribution: suppressing it via CLAUDE.md is model persuasion, not configuration;
  the settings path needs both `attribution.commit` and `attribution.pr` (R).
- Meta user messages reach the wire as `user` frames with `isSynthetic: true`, which is
  what makes goal kickoffs, Stop-hook feedback, loop-tick reminders and ultracode reminders
  observable (P; listed as the single most valuable thing to confirm with one live turn).

## 6. The gaps that shape the architecture

Ranked across areas by how much they change what FleetKit and the shell must be. Class
letters as in section 2.1; "fix" names the cheapest complete remedy known today.

1. **Nothing on the wire during a running tool or a thinking subagent** (D). Bash output,
   WebSearch progress, MCP progress, hook status text and classifier calls are all silent;
   `task_progress` is tool-paced. Fix: tail task output files; tick elapsed locally; opt into
   `agentProgressSummaries`; show `api_retry` and `rate_limit_event` as stall copy.
2. **The persisted-settings surface is read-mostly** (D). One writable key over the
   protocol; `/config key=value` as text for about forty keys; nothing for permission rules,
   additional directories, hooks, MCP scopes, sandbox tiers, `~/.claude.json`. Fix: decide
   per key between the text command, `updatedPermissions` on an open ask, and a documented
   file write through the CLI (`claude mcp add`, `claude plugin`), and say so in the UI.
3. **No runtime `/add-dir`** (X). Only `--add-dir` at launch; `add_directory` and
   `register_repo_root` are for containers and cloned repos. Fix: restart the child with a
   new `--add-dir` list, which the lifecycle already supports.
4. **History comes from disk, and the CLI will mirror it live** (P). `--resume` replays
   nothing; `--session-mirror` pushes every JSONL record as it is written. Fix: make the
   transcript-record reducer the primary reducer and treat wire frames as the streaming
   preview layer; the differential test then compares two views of one record stream.
5. **Permission dialogs are reconstructed, and the words around the decision are missing**
   (D). Empty `decision_reason` for common escalation types; no soft-reject; no
   accept-with-feedback; opaque `agent_id`. Fix: rebuild the consent line from
   `decision_reason_type` and `matched_ask_rule`; map `agent_id` through `task_started`;
   compose the four model-facing rejection strings.
6. **Retraction and refusal collapse are half-signalled** (D). Phantom messages after
   tombstones; duplicated text after a refusal fallback. Fix: handle `supersedes`; declare
   `refusal_fallback_prompt`; watch for a stale `message_start` and close the open block.
7. **Background work dies with the process, and cannot be listed** (D). `end_session`
   kills background shells; `background_tasks` is an action, not a query; no request
   backgrounds a running foreground command or agent; an `interrupt` without
   `perTaskStopAffordance` kills every background agent. Fix: mirror the registry from
   `task_started`, `task_updated` and `background_tasks_changed`; never reap a channel while
   that mirror is non-empty; declare `perTaskStopAffordance`; drop the ctrl+b affordance
   from the design.
8. **Presence is not published for headless sessions** (D). Fix: afleet writes `status`,
   `waitingFor` and `tempo` into the child's `~/.claude/sessions/<pid>.json` itself.
9. **Notifications need a hook, not a frame** (D). Fix: register a `Notification` hook via
   `initialize.hooks`; set `CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK=1`.
10. **Trust and consent moments are skipped** (X, security). Workspace trust,
    `.mcp.json` approval, managed-settings approval, plugin consent, external CLAUDE.md
    imports. Fix: afleet presents its own trust step before spawning in a directory it has
    not seen, reads `.mcp.json` and `remote-settings*.json`, and refuses to launch on a
    pending managed-settings payload.
11. **Per-tool rendering is a wholesale rebuild with richer data** (R). Fix: renderers keyed
    on `tool_name` over `tool_use_result`; open persisted output files; draw images and
    diffs the terminal cannot.
12. **The command palette is the runnable list plus native entries** (R). Fix: the command
    router's local table is the union of the `initialize.commands` list and afleet's native
    affordances, with the refusal text intercepted so users never read "run it from the
    terminal".
13. **Context and cost are poll-only but complete** (R). Fix: `get_context_usage` after
    every `result`; `get_usage` on a timer; parse `get_session_cost.text` for the status
    line.
14. **Keybindings, themes, spinner verbs and tips history live only on disk** (R). Fix:
    parse `~/.claude/keybindings.json` and `~/.claude/themes`; read tip cadence state so
    dismissed tips stay dismissed.
15. **Fast mode, checkpoints, auth status, prompt suggestions, session mirror and MCP
    auto-backgrounding are opt-ins the launch line does not take** (P). Fix: section 8.

## 7. Where the GUI exceeds the terminal

Collected from the inventories; each is pure host-side work on data already on the wire or
already on disk.

- Render mermaid, inline images, screenshots, PDF pages and notebook cells; the terminal
  prints placeholders for all of them.
- Show `<sandbox_violations>`, WebSearch `Links` JSON and structured `tool_use_result`
  fields the terminal strips or collapses.
- A context panel from `get_context_usage` (categories, per-tool message breakdown,
  autocompact threshold) with no turn spent, better than the terminal's `/context`.
- A findings panel for `ReportFindings`, a notebook view for `NotebookEdit`, a real diff
  viewer for `Edit`/`Write` with `structuredPatch`.
- Per-session tab status colour and word from the disabled OSC 21337 palette.
- Side questions with streamed progress and cancellation (`side_question`).
- An `@` picker that can add MCP resources and agents from `mcp_status` and `initialize`
  where the terminal's unified provider is the only reference.
- A hook editor (`/hooks` is read-only), a rule editor with live validation, a keybinding
  editor with live validation, a plugin manager with progress.
- Native notifications with focus awareness (`away_summary` has no host-focus source in the
  protocol; a GUI has one).
- A classifier-in-flight indicator (the terminal has none), a per-decision auto-mode log
  from `AUTOMODE_DECISION_LOG=1`.
- Native dictation instead of `/voice`; real export formats instead of `/export`; a fetched
  changelog instead of `/release-notes`; fork via `--fork-session` instead of a file copy.
- `set_mcp_permission_mode_override`, in-process MCP tools, SDK callback hooks that survive
  `disableAllHooks`, `RefreshMcpTools`: capabilities with no terminal surface at all.

## 8. Launch line and handshake recommended by this inventory

Changes to the workspace design's section 6.1 and 6.2, each traced to a finding above.

Add to the launch line:

```
--session-mirror                      # transcript_mirror frames (finding 20)
--enable-auth-status                  # auth_status frame (finding 21)
--prompt-suggestions                  # prompt_suggestion after each turn (A-50)
```

Add to the child environment:

```
CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=1      # rewind_files works (finding 8)
CLAUDE_AUTO_BACKGROUND_TASKS=1                   # slow MCP calls background instead of blocking (A-31)
CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK=1 # PushNotification fires (A-50)
CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=<format>     # AskUserQuestion previews for SDK clients (A-24/21)
AUTOMODE_DECISION_LOG=1                          # per-decision classifier log (A-26); optional
```

Do not set `CLAUDE_CODE_REMOTE` (it disables auto-memory and changes compaction) or
`CLAUDE_CODE_CONTAINER_ID` (it auto-backgrounds every command) to get the frames they unlock;
neither carries tool output anyway.

In `initialize`:

- `supportedDialogKinds: ["refusal_fallback_prompt", "fable_overage_consent_prompt"]`, with
  cards for both; nothing else is ever forwarded (finding 19).
- `hooks`: a `Notification` hook so OS notifications reach the host (A-41, A-50), and a
  `ConfigChange` hook as the settings-change push channel (A-03).
- `agentProgressSummaries: true` (already), `perTaskStopAffordance: true` (already).

After the handshake:

- `apply_flag_settings {settings: {fastMode: true}}` if the user wants the toggle (finding
  13); `get_settings.applied` is the only readback.
- Prime `file_suggestions` once so the index is warm (finding 15).

Never send `submit_feedback` without the consent screen (finding 16), and never `end_session`
a channel whose last `background_tasks_changed` was non-empty without warning (finding 5).

## 9. Corrections to the workspace design spec

Findings that contradict `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md`.

| Design spec statement | What the binary does | Consequence |
|---|---|---|
| §7.6: `/add-dir <path>` maps to `add_directory` ("unpublished schema; field shape confirmed by probe") | `add_directory` is a cloud-container staging call (`mount_path`); `register_repo_root` requires a subdirectory of cwd or of a launch-time `--add-dir` root | No runtime `/add-dir`; restart the child with a new `--add-dir` list |
| §7.6: `/agent <name>` via `apply_flag_settings {agent}` | Accepted with `null` and no readback; unverified whether it takes effect | Treat as unverified until probed with a turn |
| §7.6: `/permissions <mode>` and the picker | The mode part is fine (`set_permission_mode`); the rules editor has no route; `update_settings` writes only `outputStyle` | A rules view is read-only from `get_settings`; adds happen only through `updatedPermissions` on an open ask |
| §7.2: wire reducer and transcript reader as two producers with a differential test | `--session-mirror` makes the CLI push transcript records live; `--resume` replays nothing | One transcript-record reducer, with wire frames as the streaming preview; the differential test compares the two views of one record stream |
| §7.4: subagent threads from "forwarded text and thinking", transcript after completion | Tool calls and results of depth-1 subagents are on the wire; depth 2+ only with the flag; `task_progress` carries activity and usage | Threads can show the live tool tree; the JSONL symlink is the fallback |
| §7.3: 30-minute reap via `terminate()` | `end_session` kills running background shells | Reap only when `background_tasks_changed` is empty |
| §8.4: "Always allow" writes `updatedPermissions` | `destination` may be `userSettings` or `projectSettings`, not only local | Offer the scope choice the TUI offers |
| §8.7: Esc interrupt | `interrupt` does not stop tasks; kill-all needs `stop_task` per task | Two affordances: interrupt turn, stop everything |
| §6.8: `SendUserFile` absent headless, MCP replacement | Confirmed, including under `CLAUDE_CODE_ENTRYPOINT=local-agent` | Design stands |
| §6.1: `--permission-prompts host` alongside `stdio` | Confirmed on 2.1.259; `--permission-prompt-tool stdio` is what routes asks | Design stands |
| §3 v1.1: register as an IDE for diff-in-editor permissions | The IDE diff race starts from the interactive dialog, never from `can_use_tool` | IDE registration buys selection context and diagnostics, not diff-in-editor; `updatedInput` already covers edit-before-approve |
| §7.6: `/fast` hidden as unavailable | Opt-in through `apply_flag_settings {fastMode: true}` | Offer the toggle after the opt-in |

## 10. Protocol additions worth asking Anthropic for

Ordered by how many gaps each would close. None has a host-side workaround.

1. `tool_progress` with an `output` delta for Bash, and progress frames for WebSearch, MCP
   `onprogress` and hook `statusMessage`.
2. A control request to background a running foreground tool or agent (the terminal's
   ctrl+b).
3. A `tombstone` or `supersedes` signal for every retraction path, and the refusal
   continuation collapser on the wire.
4. `hint_clears` (microcompact) so hosts can mirror what the model's context now holds.
5. `os_notification` as a frame, or documented parity through the `Notification` hook.
6. `decision_reason` populated for `rule`, `mode`, `subcommandResults`,
   `permissionPromptTool`, plus soft-reject and accept-with-feedback fields on the
   `can_use_tool` answer.
7. A settings-change frame, and `update_settings` accepting the keys `/config` accepts.
8. A local `add_directory` (or `set_cwd`-style) request for additional working directories.
9. `mcp_status` push on state change, with tool descriptions and schemas.
10. `initialize.agents` with colour and `agents`' metadata; `commands` with `isHidden`,
    `type`, `source`, `argNames`, `subcommands`.
11. Presence (`status`, `waitingFor`) published by headless sessions into the registry.
12. `unavailable_models` for all hosts, and effort cost multipliers.

## 11. Consolidated unverified items

Each area file has an "Unverified" section; these are the ones that would change a design
decision if wrong.

- `apply_flag_settings` with `agent`, `outputStyle` and `viewMode`: accepted silently; no
  turn was run to see whether they took effect.
- `agentProgressSummaries` frame shape: never observed; both subagent probes were shorter
  than the 30 s cadence.
- Depth-2 nested subagent frames: inferred from code; no live capture.
- Whether a headless process reacts to an external settings edit (the watcher is
  process-wide and unconditioned, per the spec; not observed).
- Whether `update_settings` or `apply_flag_settings` refreshes the frozen hooks snapshot.
- Whether MCP `onprogress` and hook `hook_progress` internal messages are dropped by the
  converter's `progress` arm (one inference carrying two A-31/27 gaps).
- The four attachment types A-15/16/17 classified as dropped, if rendered attachments are
  converted before the filter runs.
- Whether `-p --cloud` on 2.1.259 takes the thin-client branch (`TFn` requires `!print`).
- `@path` mention expansion in a headless `user` frame end-to-end (the extractor is shared;
  the headless call site was not traced).
- Whether `unavailable_models` gating and `permission_mode_from_default_fallback` can be
  obtained without impersonating `claude-vscode` (they cannot by design; listed so the
  decision not to impersonate is a conscious one).
- The `file_suggestions` first-call empty result: index warm-up is the likely cause; not
  confirmed by reading the cache code.

## 12. Index

| File | Chapters | Rows |
|---|---|---|
| `areas/41-tui-rendering.md` | SPEC 41 | 386 |
| `areas/42-input-keybindings.md` | SPEC 42 | 218 |
| `areas/28-slash-commands.md` | SPEC 28 | 109 + 5 |
| `areas/20-tasks-background.md` | SPEC 20, 16 (background) | 163 |
| `areas/18-agents-subagents.md` | SPEC 18 | 144 |
| `areas/24-21-permissions-plan-questions.md` | SPEC 24, 21 | 201 |
| `areas/26-auto-mode.md` | SPEC 26 | 120 |
| `areas/31-27-mcp-hooks.md` | SPEC 31, 27 | 158 |
| `areas/30-29-32-plugins-skills-styles.md` | SPEC 30, 29, 32 | 168 |
| `areas/03-49-35-settings-diagnostics-sessions.md` | SPEC 03, 49, 35 | 178 |
| `areas/13-10-23-context-memory-session-tools.md` | SPEC 13, 10, 23 | 146 |
| `areas/11-14-query-loop-tool-interface.md` | SPEC 11, 14 | 191 |
| `areas/15-16-17-file-bash-sandbox.md` | SPEC 15, 16, 17 | 157 |
| `areas/06-08-02-models-auth-bootstrap.md` | SPEC 06, 08, 02 | 193 |
| `areas/33-34-43-44-ide-lsp-voice-artifacts.md` | SPEC 33, 34, 43, 44 | 103 |
| `areas/50-36-39-38-notifications-remote-teams-daemon.md` | SPEC 50, 36, 39, 38 | 220 |
| `areas/46-19-48-37-chrome-web-enterprise-cloud.md` | SPEC 46, 19, 48, 37 | 150 |
| `areas/22-47-40-goals-git-workflows.md` | SPEC 22, 47, 40 | 153 |
| `evidence/` | live probe captures, 2.1.259 | |
| `../../probes/04` to `12` | the probe scripts (04 zero-cost census, 05 slash commands, 06 background turn boundary, 07 resume and control shapes, 08 checkpoints and rewind, 09 fast mode and entrypoint, 10 session mirror and auth status, 11 tool_progress, 12 registry record) | |

Errata: where a live probe contradicted an inventory, the inventory carries an "Errata"
note at its top and this file is authoritative.
