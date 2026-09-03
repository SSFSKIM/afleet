# afleet — a native macOS Slack-style workspace that hosts the Claude Code engine

Status: design approved 2026-09-03, revised the same day with the author's thirteen
additions. Living spec; see the tail sections.

## 1. Purpose

Today one Claude Code session lives in one terminal window. Running several at once means
several terminals, no shared inbox, no way to see which one is waiting on you, and no place
next to the conversation to read the file it just edited, open the page it just served, or
look at the branch it just made. Anthropic's desktop app has a chat surface but a reduced
harness and no workbench; the terminal has the real harness and no workbench.

After this work, a user opens **afleet**, a native macOS app, and sees every Claude Code
session on the machine laid out like Slack: projects as sidebar sections, sessions as
channels with unread and needs-input badges, an Activity view of everything waiting across
the fleet, the conversation in the middle rendered as readable messages with tool activity
folded under them, and a right-hand panel that opens a thread, a real terminal, a file
viewer and editor, a browser, or the git graph for that session's project. Nothing about
Claude Code is re-implemented: the app launches the unmodified `claude` binary in its
headless mode and speaks its documented protocol, so every setting, hook, plugin, skill, MCP
server, memory file, permission rule and slash command the user has in the terminal is
present unchanged. Sessions started in a terminal, background jobs, and past sessions all
appear in the same sidebar and render through the same timeline.

How to see it working: launch afleet, click any project, click any past session, and its
full history appears in under a second without spawning anything. Type a message, and the
same session continues, with permission prompts arriving as cards you approve with a click.
Open the Terminal tab, and a shell opens in that project's directory. Ask Claude to read a
file, and the path in the activity card opens that file in the Files tab at the right line.
A session you started in iTerm shows up as a channel too, read-only, with its live status.

## 2. Vocabulary

Terms of art used in this document, defined once here.

- **Engine**: the `claude` binary's turn loop, tools, permissions, hooks and MCP client,
  identical in the terminal and in headless mode.
- **Headless protocol**: the newline-delimited JSON exchanged on the binary's stdin and
  stdout under `-p --input-format stream-json --output-format stream-json`. Specified in
  `~/claude-code-bundle/2.1.257/SPEC/45-headless-and-sdk-protocol.md`, cited below as
  *SPEC 45*; sibling chapters are cited the same way.
- **Control request**: a protocol frame carrying a typed request from either side, answered
  by exactly one control response with the same request id. *Inbound* requests come from
  the binary to the app; *outbound* requests go from the app to the binary.
- **Host**: the process that owns the binary's stdin and stdout and answers inbound control
  requests. afleet is a host in the same sense as Claude Desktop and the VS Code extension.
- **Protocol baseline**: the CLI version whose published SDK typings and recorded fixtures
  the app is built against. Initially 2.1.259 with `@anthropic-ai/claude-agent-sdk@0.3.259`.
- **Workspace**: the afleet app and its one main window.
- **Project**: a directory Claude Code has run in. A collapsible sidebar section, grouped
  further by worktree when a project has several.
- **Channel**: one Claude Code session, identified by its session UUID, with one of four
  *origins* (§7.1): owned, foreign live, background job, archived.
- **Transcript**: the session's on-disk record at
  `~/.claude/projects/<slug>/<session-id>.jsonl` (*SPEC 35*), plus subagent transcripts
  beside it.
- **Registry**: `~/.claude/sessions/<pid>.json`, one record per live Claude Code process,
  with kind, status, name, cwd and session id (*SPEC 38.18*).
- **Roster**: `~/.claude/daemon/roster.json`, the daemon's list of background workers
  (*SPEC 38.5.3*); `claude agents --json` lists interactive and background sessions together.
- **Timeline**: the ordered list of items a channel renders, produced identically from live
  frames and from the transcript (§7.2).
- **Thread**: a drill-down attached to a timeline item, opened in the right panel.
- **Decision**: a timeline item created from an inbound control request that needs a person:
  permission, question, plan approval, dialog, elicitation.
- **Cluster**: consecutive tool calls between two pieces of assistant prose, rendered
  collapsed under the prose and labeled by the engine's own `tool_use_summary` frame.
- **Panel**: the tabbed right-hand region: Thread, Files, Source Control, Terminal, Browser,
  GitHub.
- **Link**: a typed reference (file, diff, URL, commit, pull request, command) any item can
  emit and the panel knows how to open.
- **Probe**: a scripted run against the installed binary that records frames or checks its
  behavior, used to catch drift between CLI versions.

## 3. Scope

**v1 (this spec):** engine host with the verified flag set; four channel origins rendered
through one timeline; lifecycle transitions between origins; sidebar with projects,
worktrees, channels, badges, Activity and Archived; timeline with three-layer density and
native markdown; decision cards; threads with reply; composer with the command router,
file mentions, shell escape, image paste, mode, model and effort pickers, queueing and
edit-via-rewind; panel tabs Files, Source Control, Terminal, Browser, GitHub; jobs listing
and adoption; notifications; Cmd+K; probe suite, golden fixtures, differential test and
version gate; login-shell environment resolution; in-process MCP server with
`send_user_file`.

**v1.1 (designed here, built after v1 ships):** afleet registering as Claude Code's IDE
(*SPEC 33*) for diff-in-editor permissions, editor selection context and diagnostics;
dispatching new background jobs from the composer; further in-process MCP tools such as
open-in-panel.

**Out of scope:** agent teams as channel members, cloud and Remote Control sessions, DMs,
reactions as actions, full-text search, staging and committing from Source Control, branch
and worktree management UI, a native code editor, LSP, other harnesses, notarized
distribution.

## 4. What the investigation established

Verified against the extracted 2.1.257 bundle, the installed 2.1.259 binary, and primary
sources; evidence is in *Surprises & Discoveries*.

1. **The terminal UI cannot be reskinned; the engine can be hosted.** The TUI is a custom
   React reconciler emitting ANSI (*SPEC 41*). Headless mode is "one process with three
   replaceable ends. The middle — the turn engine, the tools, permissions, hooks, MCP — is
   exactly the interactive harness" (*SPEC 45.1*). With the CLI's default setting sources
   all five tiers load (*SPEC 45.28.3*).
2. **This is how Anthropic's own GUIs work.** Claude Desktop's `app.asar` embeds the Agent
   SDK client; the binary's entrypoint registry names `claude-desktop` and `claude-vscode`
   (*SPEC 45.30*). The Agent SDK is the transport first-party GUIs use to host the full
   product.
3. **Permissions, questions and plan approval ride one channel.** Only *ask* decisions
   escalate to the host as `can_use_tool` (*SPEC 45.19*); `AskUserQuestion` and
   `ExitPlanMode` arrive on it with `requires_user_interaction` and are answered through
   `updatedInput` (*SPEC 21*). Without `--permission-prompt-tool stdio` every ask is a
   denial (*SPEC 45.19.6*, verified by probe on 2.1.259); the newer `--permission-prompts
   host` flag alone does not change that.
4. **The protocol is complete enough for a first-party-grade GUI**: sixty-six control
   request subtypes (*SPEC 45.17*), `side_question` with history, `rewind_conversation`
   with prefill, `file_suggestions`, `get_context_usage`, `add_directory`,
   `apply_flag_settings`, `rename_session`, and an in-process MCP mechanism over
   `mcp_message` (*SPEC 45.21*).
5. **Presence and jobs are already published.** The registry records every live process
   with `kind`, `status` (`busy`, `shell`, `idle`, `waiting`), `waitingFor`, `name`, `cwd`
   and `sessionId`; `claude agents --json` lists interactive and background sessions;
   `claude stop`, `attach`, `logs`, `rm`, `respawn` and `--bg --resume <id>` manage jobs.
6. **Billing is unchanged.** Anthropic paused the June 15, 2026 split; `claude -p` and
   third-party hosts still draw from the subscription's normal limits.
7. **The stack is proven.** libghostty-spm ships the full libghostty as an MIT SwiftPM
   binary target; many Swift apps embed it. Monaco is VS Code's editor under MIT.

## 5. Architecture: four modules, one-way dependencies

```
   Afleet      SwiftUI shell: sidebar, channel column, thread pane, Activity, Cmd+K,
      │        notifications, settings, packaging
      ▼
   Workbench   panels: Files (Monaco + viewers), Source Control + GitHub, Terminal
      │        (TerminalSurface over libghostty-spm + own PTY layer), Browser, LinkRouter
      ▼
   FleetKit    Timeline model; wire reducer + transcript reader (differential invariant);
      │        Channel with four origins and lifecycle; fleet tracking (registry, roster,
      │        agents --json); Activity query; command router; app store
      ▼
   ClaudeWire  Codable frames from the SDK typings; ClaudeProcess actor; control
               correlation; in-process MCP server; frame log; version gate; environment
               resolution; fake-claude, fixtures, probe suite
```

Each module is a SwiftPM package with its own tests, buildable without the modules above
it. Inside each, targets stay small and single-purpose (for example `FleetKit` has
`Timeline`, `WireReducer`, `TranscriptReader`, `Fleet`, `CommandRouter`, `Store`), but the
public dependency graph is the four-layer one above, which is also the cut
doperpowers:decomposing is expected to make. Workbench does not import ClaudeWire; the
Terminal panel's raw-TUI hatch and job attach go through FleetKit's lifecycle API.

Data flow in one paragraph. At launch, ClaudeWire resolves the environment through the
login shell (§6.9) and checks the version gate; FleetKit indexes transcripts, reads the
registry and roster, and restores the store; the sidebar renders channels with their
origins. Opening a channel renders its timeline from the transcript immediately. If the
origin allows, FleetKit asks ClaudeWire to spawn an owned process and perform the
handshake; live frames flow through the wire reducer into the same timeline. Inbound
control requests become decisions; answering one sends the control response. Composer
input goes through the command router to a text frame, a control request, or a native
action. When a process exits, the channel's origin changes and the timeline re-syncs from
disk. Every link an item emits goes through LinkRouter to a panel tab.

## 6. ClaudeWire: the wire layer

Review carefully; this is the load-bearing contract.

### 6.1 Launch

One `ClaudeProcess` actor per owned channel spawns the CLI in the channel's directory:

```
claude -p --input-format stream-json --output-format stream-json --verbose \
  --include-partial-messages --replay-user-messages --forward-subagent-text \
  --include-hook-events \
  --permission-prompt-tool stdio --permission-prompts host \
  [--session-id <uuid> | --resume <session-id> [--fork-session]] \
  [--model <m>] [--permission-mode <mode>] [--agent <a>] [--effort <l>] \
  [-n <name>] [--add-dir <dir>...] [-w [<worktree-name>]] \
  [--allow-dangerously-skip-permissions]
```

- `--permission-prompt-tool stdio` is the correctness fix and is sufficient on its own:
  the literal `stdio` installs the control-protocol answerer (*SPEC 45.23.1*); without it
  every permission ask is denied (*45.19.6*). Verified by probe on 2.1.259 (§Surprises).
- `--permission-prompts host` is new since 2.1.257 and present on 2.1.259, documented as
  "Who answers permission prompts with --print: host (the SDK host or
  --permission-prompt-tool) or none". **On its own it does not route asks to a raw CLI
  host**; the probe showed a denial with it and no prompt tool. It is passed alongside
  `stdio` on the 2.1.259 baseline only to pin the "host" choice explicitly against a future
  default change; the probe suite asserts its presence in `claude --help`.
- `--allow-dangerously-skip-permissions` is passed only after the user accepted afleet's
  bypass disclaimer (§8.6); it makes `bypassPermissions` selectable at runtime without
  defaulting to it.
- New channels mint their own UUID and pass `--session-id`; existing channels pass
  `--resume`; forks add `--fork-session`. The launch flags only set initial state; all of
  them are changeable at runtime through the command router (§7.6).
- The binary is resolved from `~/.local/bin/claude` through the resolved environment,
  overridable in settings. `CLAUDE_CODE_ENTRYPOINT` is left unset; afleet does not
  impersonate a first-party entrypoint.

### 6.2 Handshake

The first stdin line is `initialize`:

```json
{"type":"control_request","request_id":"init-1","request":{
  "subtype":"initialize",
  "supportedDialogKinds":[],
  "perTaskStopAffordance":true,
  "agentProgressSummaries":true,
  "sdkMcpServers":["afleet"],
  "sdkMcpServerConfigs":{"afleet":{}}
}}
```

Its response carries `commands`, `agents`, `models`, `output_style`,
`available_output_styles`, `account`, `current_model`, `current_permission_mode`,
`session_state`, `pid` (*SPEC 45.18.4*). The first `system/init` frame adds `tools`,
`skills`, `plugins`, `agents`, `slash_commands` with its `terminal_slash_commands`
subset, `mcp_servers`, `capabilities`, `claude_code_version`, `apiKeySource` and
`messaging_socket_path` (*SPEC 45.10.4*). Both are kept on the channel's session object.
`supportedDialogKinds` starts empty because the binary fails closed on undeclared kinds
(*SPEC 45.22.13*).

### 6.3 Frames, typing and opacity

- Every frame type in the typings of `@anthropic-ai/claude-agent-sdk@0.3.259`
  (`sdk.d.ts`, plus `sdk-tools.d.ts` for per-tool input shapes used to format cards)
  becomes a Swift `Codable` model. The package license is all-rights-reserved, so the
  typings are **not vendored**: `Tools/fetch-typings.sh` runs `npm pack` for the pinned
  version into an ignored directory for model generation and the probe census, and only
  our own Swift models are committed. The pinned version is the protocol baseline.
- Control requests without published typings (`side_question`, `rewind_conversation`,
  `add_directory`, `end_session`, `generate_session_title`) are modeled from the bundle's
  handler source (*SPEC 45.17*) and pinned by probe fixtures (S8).
- Decoding is tolerant. A frame with an unknown `type` or `subtype`, or a known one that
  fails to decode, is preserved as an opaque item with its raw JSON: never dropped, never
  fatal, rendered as a collapsed "unrecognized event" row, counted for the drift check.
- Every inbound and outbound frame is appended to
  `~/Library/Logs/afleet/frames/<session-id>.ndjson`, rotated; these logs feed fixtures.

### 6.4 Inbound and outbound requests

| Direction | Subtype | Behavior |
|---|---|---|
| inbound | `can_use_tool` | Decision item and card; answer `allow` with optional `updatedInput` and `updatedPermissions`, or `deny` with message; set `decisionClassification`. |
| inbound | `request_user_dialog` | Answer only declared kinds; never answer undeclared ones. |
| inbound | `elicitation` | Elicitation card; `accept` with content, `decline`, or `cancel`. |
| inbound | `hook_callback` | No hooks registered in v1; if received, answer an empty continue. |
| inbound | `mcp_message` | Route to the in-process MCP server (§6.8). |
| outbound | `interrupt` | Esc while running; honor `still_queued`. |
| outbound | `set_permission_mode`, `set_model`, `set_max_thinking_tokens`, `apply_flag_settings`, `rename_session`, `add_directory` | Command router targets (§7.6). |
| outbound | `rewind_conversation`, `rewind_files` | Edit-and-resend; restore files, with `dry_run` first. |
| outbound | `get_context_usage`, `get_session_cost`, `get_usage`, `get_binary_version` | Header meter, usage popover, version gate. |
| outbound | `stop_task`, `background_tasks` | Task cards. |
| outbound | `side_question` | Side-question threads, with `history`. |
| outbound | `file_suggestions` | `@` completion. |
| outbound | `mcp_status`, `mcp_set_servers`, `mcp_reconnect`, `mcp_toggle`, `reload_skills`, `reload_plugins` | Header menus and `/mcp`. |
| outbound | `end_session` | Graceful shutdown. |

### 6.5 Version gate

At launch afleet runs `claude --version` and, on the first owned channel,
`get_binary_version`. A binary older than the protocol baseline is refused with an upgrade
screen naming installed and required versions; nothing spawns. A newer binary is accepted:
unknown frames take the opaque path, and features gate on `capabilities` tokens, never on
version comparison. The Settings screen shows the baseline, the installed version, and the
count of unknown frame types seen since install.

### 6.6 Sending input

User text becomes a `user` frame with a client-minted `uuid`, `parent_tool_use_id: null`
and `origin: {"kind":"human"}`; the schema requires hosts wrapping keyboard input to stamp
the human origin or trust gates fail closed (*SPEC 45.15.1*). Image pastes become image
blocks. The `--replay-user-messages` echo is treated as delivery acknowledgment. A leading
`!` sends a `bash_command` frame (*SPEC 45.15.2*), whose output renders as a system item
and never enters the transcript.

### 6.7 Process supervision

Owned by `ClaudeProcess`: stdin writer with backpressure, stdout line reader, stderr
capture ring, keep-alive, exit observation with code and signal, and a `terminate()` that
sends `end_session`, closes stdin, waits up to 5 s, then SIGTERM. Lifecycle policy
(when to spawn, reap, respawn) lives in FleetKit (§7.3); ClaudeWire only executes it.

### 6.8 In-process MCP server

`initialize.sdkMcpServers` and `sdkMcpServerConfigs` register a server named `afleet`,
served in-process over `mcp_message` frames carrying JSON-RPC (*SPEC 45.21*): the binary
forwards requests, the host answers in a control response. Tools appear to the model as
`mcp__afleet__<tool>`. The first tool is `send_user_file(files: [path], caption?: string)`,
because the built-in `SendUserFile` is enabled only on remote and desktop surfaces
(*SPEC 23.4.2*) and is absent headless. Its effect is a *sent file* timeline item with a
preview and an *Open in Files* link. Later tools ride the same server with their own
decision-log entries.

### 6.9 Environment resolution

At launch, once, afleet runs the user's login shell non-interactively
(`$SHELL -l -i -c 'env -0'` with a five-second timeout, so `.zprofile` and `.zshrc` both
apply; a non-interactive `-l -c` fallback if the interactive shell hangs)
and captures the environment. Every spawn (claude, git, gh, shells) inherits it, so
PATH-dependent MCP servers, hooks and helpers behave exactly as in the terminal. Settings
offers *Refresh environment* and shows the resolved PATH.

### 6.10 fake-claude, fixtures, probe suite

- `Tools/fake-claude/`: a script that speaks the protocol from a fixture, answers
  `initialize`, replays frames with timing, and can inject arbitrary frames. UI tests spend
  no tokens.
- **Golden fixtures**: NDJSON recorded from real sessions through the frame log, passed
  through a redaction pass (emails, tokens, absolute home paths, account fields) before
  they enter `Fixtures/`. Each fixture is paired with a snapshot of its transcript for the
  differential test (§7.2).
- **Probe suite** (`Tools/probe/`, run on demand with `make probe`; the three scripts
  already in `probes/`, a stream-json baseline, an initialize-and-permission round trip,
  and a headless `SendUserFile` check, are its seed and move there): runs the installed
  CLI through a scripted session and a zero-cost `initialize`, records a *frame census*
  (type and subtype counts, top-level key sets per type, `capabilities`, the flag list from
  `claude --help`), and diffs it against the census of the fixtures. A CLI upgrade is
  caught here before it breaks the app. New frame types found by the census are the queue
  for typing work.

## 7. FleetKit: sessions, timeline and fleet

### 7.1 Four channel origins

| Origin | Definition | Source of truth | Presence | Composer |
|---|---|---|---|---|
| Owned | afleet holds the process (connecting, ready, or dormant after reap) | live frames, then transcript | from `session_state_changed` | enabled |
| Foreign live | a session running in the user's terminal | transcript, mirrored read-only | registry record: `status`, `waitingFor`, `name` | disabled, with explanation |
| Background job | a `claude --bg` or daemon-dispatched session | transcript, mirrored | roster and `claude agents --json`: `state`, `name` | disabled until adopted |
| Archived | a past transcript with no live process | transcript | none | enabled; sending spawns and the channel becomes owned |

All four render through the one Timeline view, which knows the origin only to pick the
presence glyph and the composer state. Detection: a channel is *foreign live* when a
registry record with `kind: "interactive"` names its session id and its pid is not ours;
*background job* when the roster or `agents --json` names it; *owned* when afleet holds it;
otherwise *archived*. The registry and roster are watched with FSEvents and polled every
five seconds as a fallback.

### 7.2 Timeline and the differential invariant

```swift
enum TimelineItem: Identifiable {
  case userMessage(UserMessage)                 // text and blocks; origin kind (human, peer, channel, coordinator…)
  case assistantMessage(AssistantMessage)       // thinking blocks (duration) and text blocks; model; streaming tail
  case toolCall(ToolCall)                       // input, result, diff, structured tool_use_result, status
  case cluster(ToolCluster)                     // consecutive tool calls; label from tool_use_summary
  case taskRun(TaskRun)                         // subagent, background shell, monitor; progress; per-task stop
  case decision(Decision)                       // permission, question, plan, dialog, elicitation; state
  case hookRun(HookRun)                         // from hook_started / hook_progress / hook_response
  case notification(Notification)               // system/notification, informational banners
  case peerMessage(PeerMessage)                 // user-role messages with a non-human origin
  case compactBoundary(CompactBoundary)
  case sentFile(SentFile)                       // from mcp__afleet__send_user_file
  case turnSummary(TurnSummary)                 // from result: duration, cost, usage, stop reason, denials
  case opaque(OpaqueFrame)
}
// every item: id, timestamp, optional threadParent
```

Two producers feed it: the **wire reducer**, which folds live frames including streaming
deltas, `tool_use_summary`, task frames and `command_lifecycle`; and the **transcript
reader**, which folds the JSONL records the CLI writes (*SPEC 35.4–35.5*) plus subagent
transcripts (*35.11*). The invariant that keeps the app honest: **both producers yield the
same items for the same session.** It is enforced by a differential test on every golden
fixture and its transcript snapshot, comparing normalized items (streaming collapsed,
timestamps within tolerance, ids by uuid). Categories that exist only on the wire
(rate-limit events, keep-alives, partial deltas) are listed explicitly as exclusions in the
test, and that list is reviewed whenever the baseline moves.

Reducer rules: one internal assistant message may arrive as several wire frames sharing
`message.id` (*SPEC 45.9.3*) and merges into one item; frames with a `parent_tool_use_id`
attach to the thread of that tool call; a `tool_result` completes its call by
`tool_use_id`; `session_state_changed` drives presence; `result` advances the unread
cursor when the channel is not in view; on process exit the transcript reader re-reads
and reconciles by uuid.

The transcript index uses the head-and-tail read the CLI's picker uses (*SPEC 35.14*),
watches `~/.claude/projects`, and caches `{sessionId, cwd, title, mtime, preview,
turnCount}` in the store.

### 7.3 Lifecycle

State machine for one channel. "Reap" ends the process while the channel stays owned.

| From | Event | Action | To |
|---|---|---|---|
| Archived, listed in a project section (active within 30 days) | opened | spawn `--resume <id>` (eager) | Owned, connecting |
| Archived, listed under *Archived* (older) | opened | render history only; no process | Archived |
| Archived (older) | user sends | spawn `--resume <id>`, then send | Owned, connecting |
| Owned, connecting | handshake done | — | Owned, ready |
| Owned, ready | 30 min with no turn, no pending decision, no input | `terminate()` | Owned, dormant |
| Owned, dormant | user sends | spawn `--resume <id>` under the same session id; the send waits and then goes; no visible change except a brief connecting glyph | Owned, ready |
| Owned, any | process exits non-zero | respawn with backoff 1 s, 2 s, 4 s (three attempts), then a system item with exit code, stderr tail and *Reopen* | Owned, ready or Archived |
| Owned | more than 6 owned processes live | reap the least recently used dormant-eligible one | that one: Owned, dormant |
| Background job | *Adopt* | `claude stop <short>`, then spawn `--resume <id>` | Owned, connecting |
| Owned | *Send to background* | `terminate()`, then `claude --bg --resume <id>` | Background job |
| Owned | *Open in terminal* | `terminate()`; run `claude --resume <id>` in a Terminal tab; keep mirroring the transcript | Foreign live (own tab) |
| Foreign live (own tab) | the Terminal tab's process exits | spawn `--resume <id>` | Owned, connecting |
| Foreign live (user's terminal) | registry record disappears | — | Archived |
| Foreign live (user's terminal) | user presses send | refused with "running in your terminal"; adoption is never offered for interactive sessions | unchanged |

Compaction is the `/compact` text command and renders as a divider from
`compact_boundary`. File rewind uses `rewind_files` with `dry_run: true` first and shows the
counts before applying. Forking a channel spawns `--resume <id> --fork-session` as a new
channel.

### 7.4 Threads

| Kind | Anchor | Content | Reply |
|---|---|---|---|
| Subagent | a task run with a subagent type | frames whose `parent_tool_use_id` matches (forwarded text and thinking), agent progress summaries, the subagent transcript when over | posts to the main session with a quoted reference `Re: agent <name>:`; appears in both places |
| Tool detail | any tool call | full input, full output, structured `tool_use_result`, timing; copy and open-in-panel | posts to the main session with `Re: <tool> <short id>:` |
| Task | background shell or monitor | its task frames and output | stop only |
| Decision | a decision card | the decision and its outcome | replying instead of clicking sends text to the main session while the decision stays pending |
| Side question | *Ask on the side* on any message | question and answer pairs, tool-free | `side_question` with the accumulated `history` |
| Sent file | a sent-file item | preview and caption | posts to the main session |

One thread is open at a time in the Thread tab, Slack-style.

### 7.5 Decisions and the Activity view

Every inbound request that needs a person becomes a Decision item and a card (§8.4).
The **Activity view**, pinned at the top of the sidebar as a virtual channel, is a query
over all channels for: pending decisions, notifications, failed results (`result` error
subtypes and `is_error` tool results), permission denials from `result.permission_denials`
and `system/permission_denied`, `rate_limit_event` frames, and auth state from
`auth_status` frames. Each row links to its channel and item; decisions can be answered
from the Activity view. macOS notifications fire for decisions and completed turns in
channels not in view.

### 7.6 The composer command router

Three classes, resolved in this order:

1. **Local commands** the terminal implements as screen UI. afleet implements them
   natively and translates to control requests or lifecycle actions:

   | Command | Mechanism |
   |---|---|
   | `/model <name>` and the picker | `set_model` |
   | `/permissions <mode>`, the picker, Shift+Tab cycle | `set_permission_mode` |
   | `/effort <level>` | `apply_flag_settings` with the effort key (`effortLevel`; confirmed by probe) |
   | `/rename <title>` | `rename_session` |
   | `/add-dir <path>` | `add_directory` (unpublished schema; field shape confirmed by probe) |
   | `/agent <name>` | `apply_flag_settings` with `agent`; the command reports the CLI's caveat that with the system-prompt snapshot on, the change applies at the next compaction or a new session |
   | `/clear` | sent as text; `conversation_reset` frame resets the timeline |
   | `/rewind` | `rewind_conversation` and `rewind_files` |
   | `/fork` | new channel with `--fork-session` |
   | `/background` | send-to-background transition (§7.3) |
   | `/stop` | `interrupt`, or `stop_task` when a task is selected |
   | `/mcp` | MCP popover from `mcp_status` |
   | `/agents` | agents list from the handshake |
   | `/resume` | focuses the sidebar switcher |
   | `/compact`, `/context`, `/cost`, `/usage` | sent as text; results render from frames |

2. **Terminal-only commands**, listed separately in `system/init.terminal_slash_commands`,
   are hidden from autocomplete and refused locally with a one-line explanation.
3. **Pass-through commands**: everything else in the `commands` list (custom commands,
   skills, plugin commands, headless-capable built-ins) is sent as text and executes in
   the engine.

Autocomplete comes from the handshake's `commands` list with the local table layered on
top. A local command that afleet has not implemented yet falls through as text, so the
engine's refusal shows in the channel and in the drift log instead of failing silently.

### 7.7 Store

`~/Library/Application Support/afleet/state.json`, atomic writes, schema version:
channel grouping and pins, section order and collapse, unread cursors per session,
per-channel panel state, browser tabs, bypass disclaimer acceptance, fixture-recorded
baseline. SQLite is revisited when search arrives. **The app never writes to `~/.claude`;
every mutation goes through the CLI or the control channel.** This includes bypass
acceptance, which the CLI stores in user settings but afleet keeps in its own store.

## 8. Afleet: the shell

### 8.1 Window

```
┌ Sidebar ──────┬ # fix-auth-tests · main · opus · Auto ────────┬ Thread │ Files │ SCM │ Term │ Web │ GH ┐
│ ⚡ Activity 3  │  you                                    16:42 │                                        │
│ ▾ afleet      │  Investigate the failing auth tests            │  Agent: Explore  (running 12s)         │
│   # spec-v1 ● │                                                │  ▸ Read 14 files · Grep ×3             │
│   # ui-spike  │  Claude · opus                          16:42 │                                        │
│ ▾ doperpowers │  ▸ Thought for 8 seconds                       │  [raw output / diff / files]           │
│   ⌥ agora-nat │  The failures come from session refresh…       │                                        │
│   # agora   ! │  ▸ Searched the auth module · 8 files · 4.2s   │                                        │
│ ▸ Lingual     │  ▸ Ran the test suite · 42 passed · 2 failed   │                                        │
│ Background    │  ┌ Permission · Bash ─────────────────────┐    │                                        │
│   ◉ review-pr │  │ npm test -- --watch=false               │    │                                        │
│ ▸ Archived    │  │ [Allow once] [Always allow] [Deny…]     │    │                                        │
├───────────────┴────────────────────────────────────────────────┴────────────────────────────────────────┤
│ / commands  @ files  ! shell     Message #fix-auth-tests…      Auto ▾ │ opus ▾ │ high ▾ │ ⏎ send        │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Three regions in an `NSSplitView`-backed layout: sidebar, channel column with header,
timeline and composer, and the panel. The panel is tabbed; any tab pops out into its own
window keeping its channel context. Appearance follows the system with the macOS 26
material set; the sidebar uses native vibrancy; type is the system font.

### 8.2 Sidebar

- **Activity** at the top with a count of pending decisions (§7.5).
- **Sections are projects**, grouped further by worktree or cwd when a project has several,
  from the `projects` map in `~/.claude.json` joined with slugs under `~/.claude/projects`.
  Projects active in the last 30 days show by default; the rest under *All projects*;
  pinning persists.
- **Channels** show title (custom, else AI title, else first prompt), relative time, a
  one-line preview, and an origin glyph: none for owned, a terminal glyph for foreign live,
  a job glyph for background, dimmed for archived.
- **Badges**: dot for unread items since the cursor, red count for pending decisions,
  running glyph for a turn in progress, presence text from the registry for foreign live.
- **Background** lists jobs with *Adopt*, *Attach* and *Stop*; **Archived** at the bottom.
- **Cmd+K** switcher over projects, channels and jobs with fuzzy matching.
- **New channel** from a section header: project, cwd or new worktree, model, permission
  mode, agent persona and name, then spawn.

### 8.3 Timeline rendering

- **Native list**, `NSTableView`-backed, virtualized by item identity, bottom-anchored.
- **Streaming**: deltas coalesce at a cap of thirty updates per second into the current
  message's tail; only the stable prefix is parsed as markdown (block boundaries detected
  from the delta stream), the tail renders as plain text, so long responses stay smooth.
- **Markdown** through Apple's swift-markdown into attributed text with native code
  highlighting; tables native; diagrams in a lazily created WKWebView per block.
- **Clusters**: tool calls between prose collapse into one row labeled by the engine's own
  `tool_use_summary` (`summary`, `preceding_tool_use_ids`), falling back to counts and
  elapsed time when no summary arrives; expandable inline to one row per call.
- **Thinking** renders as a collapsible "Thought for N seconds", with the live estimate
  from `system/thinking_tokens` while streaming.
- **Turn summary** rows show duration, cost and stop reason; compaction is a divider.
- **Header**: branch, model, mode, effort, a context meter from `get_context_usage`, and
  menus for MCP, reload skills and plugins, rename, fork, send to background, open in
  terminal.

### 8.4 Decision cards

| Card | Trigger | Rendering | Answer |
|---|---|---|---|
| Permission | `can_use_tool` without `requires_user_interaction` | display name, consent line, input formatted per tool (shell in monospace, `Edit` and `Write` as Monaco diffs, paths as links); `decision_reason` stripped of ANSI | *Allow once* → `allow`, `user_temporary`; *Always allow* only when `permission_suggestions` exist and `suppress_always_allow_rule` is unset → `allow` with `updatedPermissions`, `user_permanent`; *Deny…* → `deny`, `user_reject` |
| Question | `can_use_tool` for `AskUserQuestion` | options, side-by-side previews, multi-select, *Other* | `allow` with `updatedInput.answers` and `annotations` |
| Plan approval | `can_use_tool` for `ExitPlanMode` | plan markdown; *Approve*, *Approve and auto-accept edits*, *Reject with feedback* | `allow` with `updatedPermissions: [setMode]`, or `deny` with feedback |
| Task | task frames | name, active form, elapsed, per-task *Stop* | `stop_task` |
| Elicitation | `elicitation` | schema-driven form | `accept`, `decline`, `cancel` |
| Dialog | `request_user_dialog` for a declared kind | by kind | `behavior`, `result` |

`default_to_no` focuses decline and removes approve shortcuts; `requires_user_interaction`
means the tool's own card is the surface with no one-tap approve or deny. Cards answered
or cancelled by the binary become inert with the outcome shown.

### 8.5 Composer

Markdown field, Shift+Enter newline, Enter send. `/` autocompletes through the command
router; `@` completes files via `file_suggestions`; `!` sends `bash_command`; image paste
and file drop attach. Pickers for permission mode, model and effort on the right. Sending
while a turn runs queues; `command_lifecycle` drives a "queued" chip with cancel via
`cancel_async_message`. Editing a past user message calls `rewind_conversation` and
prefills the returned text.

### 8.6 Bypass mode

`bypassPermissions` appears in the mode picker only if the account allows it
(`disableBypassPermissionsMode` unset, read via `get_settings`). Selecting it the first
time shows the same disclaimer the CLI shows; acceptance is stored in afleet's store, after
which owned channels launch with `--allow-dangerously-skip-permissions` so the mode is
selectable at runtime via `set_permission_mode`. Declining leaves the mode unavailable.

### 8.7 Notifications and keyboard

`UNUserNotification` for decisions and completed turns in channels not in view, each
toggleable. Shortcuts: Cmd+K switcher, Esc interrupt, Cmd+Enter send, Cmd+1…6 panel tabs,
Cmd+Shift+T new terminal tab, Shift+Tab cycle permission mode, Cmd+Shift+A Activity.

## 9. Workbench: the panels

### 9.1 Files

Tree rooted at the channel's cwd, gitignore toggle, filter; open, reveal, copy path. Code
opens in Monaco inside a `WKWebView`, bundled at build time from npm with bun into
`Resources/monaco/`, served through a custom URL scheme handler, bridged with
`WKScriptMessageHandler` for open, save, goto-line, theme and diff. Syntax highlighting
for all Monaco languages; language services only for the web languages it ships. Markdown,
images, PDF, audio and video open in native viewers (attributed text, `NSImage`, PDFKit,
AVKit, Quick Look fallback). A file watcher refreshes open files when the agent edits
them, with a conflict banner if the buffer is dirty. Paths in items open here at the line.

### 9.2 Source Control and GitHub

Graph on a SwiftUI `Canvas` from `git log --topo-order --all` with a lane-assignment pass,
branch and tag labels, working tree as the top row; commit detail with changed files and
Monaco diffs; working-tree changes with diffs against HEAD. Uses the `git` binary from the
resolved environment so hooks, credential helpers and worktrees behave. No staging,
committing or branch operations. GitHub: pull requests for the branch, checks and issues
via `gh ... --json`; a PR opens in the Browser tab.

### 9.3 Terminal

`TerminalSurface` protocol implemented over GhosttyKit from libghostty-spm with a small PTY
layer of our own, since the package ships an in-memory backend; Termini is the reference
implementation. One feed in v1: a local PTY. Job attach runs `claude attach <id>` and the raw-TUI hatch
runs `claude --resume <id>`, both as ordinary PTY processes, so the CLI's own attach client
handles the detach protocol; a host-managed byte-stream feed is reserved for later. One or
more panes per channel, opened in the channel's cwd with the
resolved environment. The adapter is the only import of the package, so swapping to
Mitchell's Swift renderer or SwiftTerm is contained.

### 9.4 Browser

`WKWebView` tabs per channel with URL bar, back, forward, reload, inspector; quick-open of
dev-server URLs seen in tool output; links in messages open here, Cmd-click in the system
browser.

### 9.5 Jobs

The Background section reads the roster and `claude agents --json`, and drives jobs
through the CLI verbs `stop`, `attach`, `logs`, `rm`, `respawn`. *Attach* runs
`claude attach <id>` in a Terminal pane. The daemon control socket (*SPEC 38.11*) is not
spoken directly in v1. Dispatching new jobs is v1.1.

### 9.6 Link routing

```swift
enum WorkspaceLink { case file(URL, line: Int?), diff(DiffRef), url(URL), commit(String), pullRequest(Int), command(String) }
```

Items emit links; `LinkRouter` opens them in the right tab of the channel's panel or the
popped-out window; Cmd-click forces a new window.

## 10. Error handling

- Missing or old CLI: onboarding or upgrade screen; nothing spawns.
- Unknown or malformed frames: opaque item plus log line, never fatal.
- Process crash: respawn with backoff, then a system item with exit code, stderr tail and
  *Reopen*; the channel never shows as broken.
- Control request errors from the binary: inline on the card or a toast with its text.
- Decisions cancelled by the binary: card inert, "answered elsewhere".
- Undeclared dialog kinds: never answered; the binary's timeout applies.
- Auth and rate-limit frames: banners in the channel and rows in Activity.
- Transcript parse failures: the record is skipped with a warning row; the channel opens in
  follow mode.
- Git and PTY failures: panel-local error states that never take the channel down.
- Stdin write failure or closed pipe: crash path.

## 11. Packaging

Deployment target **macOS 26**, built with Xcode 26 and Swift 6 with strict concurrency,
because the author's machine is moving to macOS 26 and the app should adopt its material
set natively. The project is generated by XcodeGen from `project.yml` so builds run from
the command line, with ad-hoc signing for local use. `ClaudeWire` and `FleetKit` contain
no UI and stay buildable and testable with the macOS 15 toolchain via `swift test`, so the
protocol, transcript and differential work can proceed on the current machine before the
move. Dependencies: libghostty-spm, swift-markdown, Monaco (vendored build output), the
vendored SDK typings.

## 12. Security and policy

- The daemon control key is not read in v1; job operations go through CLI verbs.
- No entrypoint or user-agent impersonation.
- Subscription use is legitimate under the current paused policy; if Anthropic enacts the
  Agent SDK credit, the usage popover already shows the meter and a per-project API key is
  a one-setting addition logged as backlog.
- cmux is GPL and is read for architecture only; no code is copied. Monaco and
  libghostty-spm are MIT. The Agent SDK typings are all-rights-reserved and are fetched
  on demand, never committed.
- Fixtures are redacted before commit; the frame log stays local.

## 13. Acceptance

Behavior a person can observe. Commands assume the app is built with
`xcodebuild -scheme afleet -configuration Debug build` and launched.

1. **History without a process.** Click an archived session. Its timeline renders in under
   one second; the process spawns afterwards, shown by a connecting glyph that clears at
   handshake.
2. **Continue.** Send `Reply with exactly: pong`. `pong` renders as a Claude message with a
   turn summary; the transcript at `~/.claude/projects/<slug>/<id>.jsonl` gains records.
3. **New channel.** *New channel* on a project, send a message. A new transcript appears
   with the UUID afleet chose; the channel gains an AI title after the first turn.
4. **Permission.** In `default` mode send `Run: ls -la`. A permission card shows the command;
   *Allow once* runs it; repeating and choosing *Deny* lists the call in the turn summary's
   denials.
5. **Always allow.** When offered, *Always allow* makes the same command run without a card
   on the next turn.
6. **Question.** Send `Use AskUserQuestion to ask me whether I prefer tabs or spaces`; a
   question card renders; selecting an option continues the turn with that answer.
7. **Plan.** Set the picker to `plan`, send `Plan a hello-world script`; a plan card
   renders; *Approve* switches the picker back and Claude proceeds.
8. **Interrupt.** Send `Count slowly to 100, one number per line`, press Esc; the turn
   stops within two seconds; the summary says interrupted.
9. **Subagent thread.** Send `Use the Explore agent to list the top-level directories`;
   the cluster shows a task run with a thread glyph; the thread shows forwarded text and,
   after completion, the subagent transcript.
10. **Side question.** *Ask on the side*, ask a question, then a follow-up; both answers
    appear in the thread; the main transcript gains no records.
11. **Command router.** `/model sonnet` changes the header model badge without a Claude
    turn; `/effort low` likewise; `/rename hello` renames the channel and the transcript's
    title record; `/vim` is hidden from autocomplete and refused with an explanation; a
    custom command from `~/.claude/commands` executes as text; `/add-dir /tmp` makes a
    subsequent `Read /tmp/x` succeed without a permission card.
12. **Shell escape and mentions.** `!pwd` prints the channel directory as a system item
    without a turn; typing `@src` lists matching files.
13. **Edit and resend.** *Edit* on a past user message prefills the composer and rewinds
    the conversation to that point when sent.
14. **Foreign live.** Start `claude` in Terminal.app in a project. Within five seconds the
    sidebar shows that session with a terminal glyph and status `idle`; typing in the
    terminal changes it to `busy`; the channel opens read-only and mirrors new messages as
    they land; the composer explains why it is disabled; quitting the terminal session
    turns the channel archived.
15. **Background job.** Run `claude --bg "Run this: sleep 90 && echo done"` in a terminal. The
    Background section lists it; *Attach* shows its screen in a Terminal tab; the detach
    key returns; *Adopt* stops it and reopens it owned, and its next message continues the
    same session id.
16. **Send to background.** *Send to background* on an owned channel; `claude agents --json`
    lists the session as background; the channel shows the job glyph and mirrors.
17. **Open in terminal.** *Open in terminal*; the owned process exits; the Terminal tab
    shows the interactive prompt for the same session; the composer is disabled; closing
    the tab makes the channel owned again and the composer works.
18. **Reap and respawn.** Leave an owned channel idle past the timeout;
    `pgrep -fl "claude -p" | wc -l` drops by one; sending a message continues the same
    session id with only a brief connecting glyph.
19. **Cap.** Open seven channels: at most 6 owned processes are live.
20. **Crash.** `kill -9` an owned process; the channel respawns and shows a system item;
    kill it three more times quickly and a *Reopen* item appears instead.
21. **Activity.** With two channels waiting on permissions and one rate-limit event,
    Activity shows three rows; answering a decision from Activity resolves it in its
    channel.
22. **Badges and notifications.** A channel not in view reaching a permission prompt shows
    a red badge; with the app in the background a macOS notification appears; viewing the
    channel clears the badge.
23. **Terminal.** `pwd` in the Terminal tab prints the channel cwd; `echo $PATH` matches
    the login shell's PATH.
24. **Files.** Click a path in a Read row; Monaco opens it at that line; edit and save;
    `git diff` shows the change; ask Claude to edit the same file; the editor refreshes.
25. **Viewers.** A `.md`, `.png`, `.pdf` and `.mp4` each open in their native viewer.
26. **Browser.** `python3 -m http.server 8123` in the terminal; the URL appears in
    quick-open; the listing renders in the Browser tab.
27. **Source Control.** A repository with a merge commit shows at least two lanes; a commit
    lists its files; a file shows a diff; editing a file updates the working-tree row.
28. **GitHub.** A repository with an open PR lists it with check status; opening it loads
    the PR in the Browser tab.
29. **Sent file.** Send `Use mcp__afleet__send_user_file to send me README.md`; a sent-file
    item with a preview appears; *Open in Files* opens it.
30. **Bypass gate.** Selecting `bypassPermissions` the first time shows the disclaimer;
    declining leaves the mode unavailable; accepting enables it and a subsequent
    `set_permission_mode` succeeds; `~/.claude/settings.json` is unchanged by afleet.
31. **Differential invariant.** `swift test --package-path FleetKit` passes, including the
    differential test over every fixture in `Fixtures/`.
32. **Probe and drift.** `make probe` against the installed CLI prints a census diff of
    zero against the fixtures; against a `fake-claude` emitting an invented frame type it
    prints one added type, and the app renders that frame as an unrecognized event.
33. **Version gate.** Pointing the binary setting at a `fake-claude` reporting `2.1.200`
    shows the upgrade screen naming both versions and opens no channel.
34. **Environment.** With an MCP server that is only on PATH through `~/.zshrc`, the
    channel's `system/init.mcp_servers` lists it as connected.
35. **Never writes `~/.claude`.** Run `fswatch ~/.claude` during a session that uses every
    feature above: every write is attributable to a `claude` process, none to afleet.
36. **Tests.** `xcodebuild test -scheme afleet` passes: ClaudeWire round-trip on every
    fixture frame type, FleetKit reducer and differential tests, command router, transcript
    reader, lane assignment, LinkRouter, and the `fake-claude` UI smoke.

## 14. Spike milestones

Each has a way to run, what to observe, and a promote-or-discard criterion.
doperpowers:writing-plans turns them into tasks.

- **S1 Terminal backend.** Scratch app rendering a login shell through our PTY layer into
  GhosttyKit's in-memory backend, then `claude attach <id>` against a running job, with live
  resize and IME. Promote when both render correctly and the detach key returns cleanly;
  otherwise SwiftTerm behind `TerminalSurface`.
- **S2 Resume behavior.** Run `--resume` headless and record whether prior messages replay.
  Promote the transcript reader as sole history source if no replay. Also confirm
  `--bg --resume <id>` and `claude stop` round-trip a session id unchanged.
- **S3 Monaco in WKWebView.** Cold load, warm open of a 5 MB file, diff on a 2,000-line
  change. Promote under one second cold and no visible jank.
- **S4 Transcript index.** Cold index of all local transcripts under 500 ms with the
  head-and-tail read; incremental update under 50 ms.
- **S5 In-process MCP.** Register `afleet`, have Claude call `mcp__afleet__send_user_file`.
  Promote when the tool is listed in `system/init.tools` and the round trip completes.
- **S6 Dialog kinds.** Enumerate `request_user_dialog` kinds from the dispatch sites and
  record which can occur locally. v1 declares none.
- **S7 Native markdown.** Ten real assistant messages with tables, nested lists and fenced
  code through swift-markdown at thirty updates per second on a long message. Promote when
  fidelity matches the terminal renderer and frame time stays under 16 ms; otherwise the
  WKWebView conversation.
- **S8 Command router shapes.** Probe `add_directory`, `apply_flag_settings` with
  `effortLevel` and `agent`, and `rewind_conversation` on 2.1.259; record request and
  response shapes into fixtures.
- **S9 Differential harness.** Record one real session as a golden fixture with its
  transcript snapshot; make the wire reducer and transcript reader agree; write down the
  wire-only exclusion list.

## 15. Natural seams for decomposition

1. ClaudeWire: frames from typings, `ClaudeProcess`, control correlation, MCP server,
   frame log, version gate, environment resolution, fake-claude, fixtures, probe suite
   (S2, S5, S8).
2. FleetKit: Timeline, wire reducer, transcript reader with the differential test, four
   origins and lifecycle, fleet tracking, Activity query, command router, store (S4, S9).
3. Afleet shell: sidebar, timeline view, cards, threads, composer, Activity view, Cmd+K,
   notifications, bypass gate, settings, packaging for macOS 26 (S7).
4. Workbench terminal and jobs: `TerminalSurface`, PTY layer, panes, attach, raw-TUI hatch
   (S1).
5. Workbench files: Monaco bridge, viewers, watcher, LinkRouter (S3).
6. Workbench browser, Source Control and GitHub.
7. v1.1: IDE registration, job dispatch, open-in-panel MCP tool.

Seams 1 and 2 have no UI and unblock everything and can run on the macOS 15 machine now;
3 depends on both; 4, 5 and 6 depend on 3 only through LinkRouter and the panel tab host.

## Decision Log

- Decision: Host the unmodified `claude` binary over the headless protocol; the app owns
  only presentation.
  Rationale: The TUI is a React reconciler with no skin hook (*SPEC 41*); headless runs the
  identical engine (*SPEC 45.1*); Claude Desktop and the VS Code extension are hosts of the
  same kind. Rejected: reskinning the TUI (impossible); PTY-wrapping and ANSI parsing
  (cannot recover structure, breaks per release); re-implementing the agent on the SDK.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: A channel is one session; sidebar sections are projects, sub-grouped by
  worktree.
  Rationale: The session is Claude Code's persistent unit; the main pane stays the
  conversation. Rejected: channel = project with sessions as posts; channel = agent team.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Four channel origins (owned, foreign live, background job, archived) rendered
  through one Timeline view.
  Rationale: Sessions started in a terminal and daemon jobs are part of the fleet; one view
  keeps the model honest. Rejected: the earlier two-state live-or-archived model, which
  could not represent a terminal session or a job.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Lifecycle transitions use the CLI's own verbs: adopt via `claude stop` then
  `--resume`; background via `--bg --resume`; open-in-terminal via `claude --resume` in a
  pane with re-adoption on exit; 30-minute reap with invisible respawn; crash respawn with
  backoff.
  Rationale: Every transition is a documented CLI behavior; the session id never changes.
  Rejected: killing foreign interactive sessions to adopt them (never offered); 15-minute
  reap (too aggressive for a daily driver).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: The wire reducer and the transcript reader must produce identical timeline
  items for the same session, enforced by a differential test on golden fixtures.
  Rationale: It is the one invariant that makes archived, mirrored and live channels
  interchangeable. Rejected: protocol-only history (needs a process per read); best-effort
  parity without a test.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: An Activity view as a cross-channel query over decisions, notifications,
  failures, denials, rate limits and auth state.
  Rationale: Badges tell you where; Activity tells you what, across the fleet. Rejected:
  badges and Cmd+K only.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: A composer command router with three classes: local (native, translated to
  control requests), terminal-only (hidden via `terminal_slash_commands`), pass-through
  (sent as text); unimplemented local commands fall through as text.
  Rationale: Matches the CLI's own thin-client dispatch (*SPEC 45.29*) and keeps every
  launch flag runtime-changeable; fall-through makes gaps visible in the channel and the
  drift log. Rejected: sending everything as text (local-jsx commands are refused headless);
  hard-coding a static list.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Codable models derived from the `@anthropic-ai/claude-agent-sdk@0.3.259`
  typings, fetched on demand and never committed; unpublished control subtypes modeled
  from the bundle source and probe fixtures; unknown frames preserved as opaque items.
  Rationale: The typings are the published, versioned source for what they cover; their
  license forbids vendoring; the schema says to ignore unknown members. Rejected:
  vendoring the typings; hand-modeling everything from the extracted spec (unversioned);
  strict decoding (breaks on every release).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Golden redacted NDJSON fixtures, an on-demand frame census diffed against the
  installed CLI, and a version gate that refuses CLIs older than the fixture baseline.
  Rationale: The wire grows per release; drift must be caught before it breaks the app.
  Rejected: relying on the SDK typings alone; strict decoding.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Resolve PATH and environment through the login shell once at launch.
  Rationale: PATH-dependent MCP servers, hooks and helpers must behave as in the terminal.
  Rejected: inheriting the GUI launch environment; per-spawn shell wrapping.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: An in-process MCP server named `afleet`, declared via `sdkMcpServers` and
  `sdkMcpServerConfigs`, JSON-RPC over `mcp_message`, first tool `send_user_file`.
  Rationale: `SendUserFile` is gated to remote and desktop surfaces; the SDK MCP mechanism
  is the supported way for a host to add tools. Rejected: no app tools in v1.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: The app never writes to `~/.claude`; every mutation goes through the CLI or the
  control channel, including bypass acceptance kept in afleet's own store.
  Rationale: `~/.claude` is the engine's; concurrent writers corrupt state. Rejected:
  writing user settings directly.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Four modules, ClaudeWire → FleetKit → Workbench → Afleet, one-way dependencies,
  small targets inside each.
  Rationale: Each lower layer is testable without the ones above; the layering is
  decomposing's cut. Rejected: the earlier flat list of thirteen packages (correct
  boundaries, no layering).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Streaming tail capped at thirty updates per second, only the stable prefix
  parsed as markdown, clusters labeled by `tool_use_summary`, collapsible "Thought for N
  seconds", bypass behind the CLI's disclaimer.
  Rationale: Smooth long responses; the engine already names clusters; parity with the
  CLI's safety gate. Rejected: re-parsing the whole message per delta.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Deployment target macOS 26 with Xcode 26; ClaudeWire and FleetKit stay
  buildable on macOS 15 for now.
  Rationale: The author's machine moves to macOS 26; the app should adopt its materials;
  the non-UI layers need not wait. Rejected: macOS 15 target with later migration.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Protocol baseline 2.1.259 with SDK typings 0.3.259; `--permission-prompt-tool
  stdio` always; `--permission-prompts host` additionally on that baseline.
  Rationale: The probe matrix under clean settings shows `stdio` alone routes asks to the
  host and `host` alone does not; passing both pins the choice explicitly. Rejected:
  baseline 2.1.257; relying on `--permission-prompts host` alone (the other session's
  design claimed it was probe-verified, but its probes never reached the ask path).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Monaco in a WKWebView for code and diffs; native viewers otherwise.
  Rationale: VS Code's actual editor, MIT. Rejected: full VS Code web workbench; native
  Swift editor (pre-production upstream).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Native timeline list with swift-markdown, not a web view.
  Rationale: Selection, vibrancy, accessibility, no scroll coupling. Rejected: one WKWebView
  for the conversation (S7 keeps it as fallback).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Eager spawn on open for channels in a project section (active within 30 days);
  history-only open for the older *Archived* section with spawn on first send; cap of 6
  owned processes.
  Rationale: Instant first send where you work; browsing hundreds of old transcripts must
  not boot hooks and MCP servers per click; bounded memory. Rejected: lazy spawn everywhere
  (two to four second first-message latency); eager everywhere (process churn while
  browsing history).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: v1 audience is the author as a daily driver; open source once it is good.
  Rejected: product for others from day one; internal team tool.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Bill through the logged-in subscription; no API-key switching in v1.
  Rationale: The credit split was paused. Rejected: per-project API key (backlog); API only.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: New sessions in the project directory; isolation via `-w` on request.
  Rejected: always a worktree; no worktrees.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: IDE registration is v1.1. Rejected: v1; never.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Source Control scope is graph, history and working-tree diff. Rejected: staging
  and commit UI; branch and worktree management.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Slack's structure with macOS-native materials. Rejected: faithful Slack chrome;
  Rocket.Chat look.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: v1 Slack must-haves are badges and threads; reactions-as-actions and search are
  out. "Fleet" in v1 means parallel local sessions plus jobs; teams and cloud are out.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Thread and panel share one tabbed right region, poppable; one thread open at a
  time. Rejected: four fixed columns; separate window.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Three-layer density. Rejected: TUI mirror; prose only.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: GhosttyKit via libghostty-spm with our own PTY layer behind `TerminalSurface`.
  Rationale: Full renderer, MIT, weekly releases, no zig; the package ships an in-memory
  backend. Rejected: building Ghostty from source; SwiftTerm as primary (S1 fallback).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Job attach and the raw-TUI hatch run CLI verbs (`claude attach`, `claude
  --resume`) inside a PTY pane; no direct daemon socket client in v1.
  Rationale: The CLI's own attach client already implements the detach protocol and stall
  handling. Rejected: speaking `control.sock` and the detach APC sequences ourselves
  (duplicates the CLI; one more protocol to drift).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Side questions use `side_question` with history, tool-free.
  Rationale: Verified control request with progress and history. Rejected for v1: hidden
  forked sessions as side chats (richer, more moving parts; revisit).
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Human input frames stamp `origin: {kind: "human"}`; entrypoint left default;
  raw-TUI hatch takes exclusive ownership; thread replies post to the main session with a
  quoted reference; app state in JSON until search arrives.
  Date/Author: 2026-09-03 / kimmi with Claude

- Decision: Track is controlled, followed by doperpowers:decomposing. Rejected: autonomous
  execplan; direct spike-first.
  Date/Author: 2026-09-03 / kimmi with Claude

## Surprises & Discoveries

- Observation: Anthropic paused the June 15, 2026 Agent SDK credit split.
  Evidence: support.claude.com article 15036540: "We're pausing the changes to Claude Agent
  SDK usage described below. For now, nothing has changed" and "Claude Agent SDK,
  `claude -p`, and third-party app usage still draw from your subscription's usage limits."

- Observation: `--permission-prompts <target>` exists on 2.1.259 but not in 2.1.257, and
  on its own does not route asks to a raw CLI host.
  Evidence: `claude --help` on 2.1.259: "Who answers permission prompts with --print:
  "host" (the SDK host or --permission-prompt-tool) or "none""; zero matches in the 2.1.257
  flag table and `cli.pretty.js`. Probe 02 with `--setting-sources ""` and a Write in cwd:
  host-only → no `can_use_tool`, `system/permission_denied:1`, no file; stdio-only →
  `PERMISSION REQUEST: Write … suggestions: ['setMode']`, answered, file written; neither
  → denial, no file. `set_permission_mode` succeeded in all three.

- Observation: Under the author's real settings, Write in the working directory needs no
  ask, so probes must disable setting sources to reach the permission path.
  Evidence: probe 02 with default settings wrote `probe.txt` under both flag variants with
  no `can_use_tool`; `terminal_slash_commands` on 2.1.259 is `['doctor', 'color']`;
  `account` carries `apiProvider, email, organization, subscriptionType`.

- Observation: Without a permission tool, every ask is a denial; `stdio` selects the
  control protocol.
  Evidence: *SPEC 45.19.6*; *45.23.1*: `if (e === "stdio") return n.createCanUseTool(o);`.

- Observation: The registry publishes live-session presence usable for foreign-live
  channels.
  Evidence: `~/.claude/sessions/2061.json` on this machine: `kind: interactive, status:
  busy, name: afleet-24, entrypoint: cli, version: 2.1.259, messagingSocketPath:
  /tmp/cc-socks/2061.sock`; schema in *SPEC 38.18.1* with `status`, `waitingFor`, `tempo`.

- Observation: `claude agents --json` lists interactive and background sessions together.
  Evidence: 16 entries on this machine, background ones with `id`, `state: blocked`,
  `name`, `cwd`; interactive ones with `status`, `pid`.

- Observation: `--bg --resume <id>` keeps the session id; `claude stop` keeps the
  conversation.
  Evidence: `claude --help`: "With --resume <session-id>, continues that session in the
  background under the same ID"; `stop|kill <id>`: "Its conversation is kept: `claude
  attach <id>` opens it again, `claude --resume` works once it is stopped".

- Observation: `SendUserFile` is disabled in a local headless session.
  Evidence: *SPEC 23* tool table: "remote/desktop surface"; `isEnabled` reads
  `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE || CLAUDE_CODE_REMOTE || F_()`.

- Observation: The installed 2.1.259 answers `initialize` with no turn and no cost, running
  SessionStart hooks first, and emitted hook frames without `--include-hook-events`.
  Evidence: handshake output: `hook_started`/`hook_response` for `SessionStart:startup`,
  then `control_response success` with 102 commands, 11 agents, models
  `default, opus[1m], fable, sonnet, haiku`, account `Claude Max`, mode `auto`.

- Observation: `tool_use_summary` carries `summary` and `preceding_tool_use_ids`;
  `side_question` carries `history` and runs tool-free with a 600 s timeout;
  `rewind_conversation` returns `prefillText`.
  Evidence: `cli.pretty.js` line 673390 schema; lines 178330–178346, 177455, 442918.

- Observation: The bypass disclaimer writes `skipDangerousModePermissionPrompt: true` to
  user settings; `--allow-dangerously-skip-permissions` makes the mode selectable without
  defaulting to it.
  Evidence: *SPEC 24.17.3*; `claude --help` line 18.

- Observation: The 0.3.259 typings cover the control protocol but not every subtype, and
  carry an all-rights-reserved license.
  Evidence: `sdk.d.ts` (8,721 lines) declares `subtype: 'initialize' | 'can_use_tool' |
  'request_user_dialog' | 'hook_callback' | 'mcp_message' | 'set_model' |
  'set_permission_mode' | 'apply_flag_settings' | 'file_suggestions' |
  'get_context_usage' | 'rename_session' | 'interrupt' | 'elicitation'` and a 39-member
  `SDKMessage` union; no `side_question`, `rewind_conversation` or `add_directory`;
  `LICENSE.md`: "© Anthropic PBC. All rights reserved."

- Observation: Claude Desktop embeds the Agent SDK client.
  Evidence: strings in `/Applications/Claude.app/Contents/Resources/app.asar`:
  `supportedDialogKinds:this.initConfig?.supportedDialogKinds` and `sdk_interrupt`.

- Observation: Probe 01 on 2.1.259 with the full flag set completed a Bash turn with no
  `can_use_tool` at all: `echo` is on the read-only allowlist and was auto-allowed, so it
  does not exercise the permission path; 65 skills and 14 plugins loaded headless.
  Evidence: census `assistant:4, user:2, system/hook_started:2, system/hook_response:2,
  system/status:2, system/thinking_tokens:2, rate_limit_event:1, result/success:1`;
  init `terminal-only 2 | skills 65 | plugins 14 | agents 11`; cost $0.0299.

- Observation: Local data is plentiful: 96 projects, 136 slugs, 695 transcripts, one
  daemon worker, 16 live sessions.

## Outcomes & Retrospective

Pending — written at finish.

## Revision Notes

- 2026-09-03: Initial spec from the brainstorming session.
- 2026-09-03: Revised with the author's thirteen additions: verified flag set with
  `--permission-prompts host` kept on the 2.1.259 baseline; four channel origins replacing
  the two-state model; lifecycle transitions through CLI verbs; the differential invariant;
  the Activity view; the composer command router; probe suite and drift ritual;
  login-shell environment resolution; MCP server declaration via `sdkMcpServerConfigs`; the
  never-write-`~/.claude` rule; four-module layering replacing the flat package list;
  rendering details; macOS 26 packaging. Acceptance, spikes, seams and the Decision Log
  updated to match.
- 2026-09-03: Probe matrix on 2.1.259 established that `--permission-prompt-tool stdio`
  alone routes asks and `--permission-prompts host` alone does not; flag semantics
  corrected in §4 and §6.1. Refinements from self-review: old archived channels open
  history-only and spawn on first send; job attach and the raw-TUI hatch run CLI verbs in
  a PTY pane instead of a hand-written daemon socket client; environment capture uses an
  interactive login shell; the existing `probes/` scripts seed the probe suite.
- 2026-09-03: SDK typings are fetched on demand rather than vendored (all-rights-reserved
  license); unpublished control subtypes are modeled from source and fixtures.
