<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# Area 20 — Tasks and background work: TUI vs headless gap inventory

Source chapters: `SPEC/20-tasks-and-background-work.md` (all sections), plus the background-execution
parts of `SPEC/16-bash-tool.md` (§16.12 auto-background, §16.13 output files and progress polling,
§16.16 background shells, §16.18 the background notice, §16.21 shell-facing task tools).
Cross-checked against `SPEC/45-headless-and-sdk-protocol.md` §45.9.1–45.9.3, §45.15.1, §45.22.10 and
against `cli.pretty.js` where chapter 20 is silent (notably `task_progress` and
`background_tasks_changed`, which chapter 20 does not document).

**Live evidence.** Two probes captured on 2.1.259 today, in
`/tmp/afleet-gap/EVIDENCE-background-subagent.md`, exercise exactly this area over the headless
protocol with afleet's flag set: probe A runs a background `Bash` plus an `Agent(Explore)` that itself
calls `Bash`, then sends `end_session` while the shell is still running; probe B lets a background
shell finish *after* the turn's `result`, with the host idle for 40 s. Cited below as **EVIDENCE A**
and **EVIDENCE B**. Where the evidence contradicts what the chapter implies, the evidence wins and the
row says so. A second live artefact, `/tmp/afleet-gap/init-dump.json` (2.1.259 `initialize` handshake
with no turn), supplies the command list and the `background_tasks` response.

**Orientation.** "Task" names two unrelated things (§20.1). The **persisted task list** is a durable
checklist on disk under `~/.claude/tasks/`; the **background-task registry** is the in-memory table of
everything running asynchronously (shells, subagents, monitors, MCP tasks, workflows, cloud sessions,
teammates). They share no ids and no storage. This document keeps them in that order.

Two facts govern almost every row below, so they are stated once here:

1. **There is no "list background tasks" control request.** The `background_tasks` control request is
   *not* a query — it is the Ctrl+B action. With `tool_use_id` it backgrounds that one foreground
   tool call and answers `{ backgrounded: boolean }`; without one it backgrounds every eligible task
   and answers `{}` (`cli.pretty.js:178247-178264`, SPEC 45 §45.22.10). Confirmed against live
   ground truth: `/tmp/afleet-gap/init-dump.json` shows `background_tasks` returning `{}`. A GUI must
   therefore **maintain its own mirror of the registry** by folding `task_started`, `task_updated`,
   `task_notification` and `background_tasks_changed`.
2. **Live stdout of a running task never reaches the wire, under any flag.** The published
   `tool_progress` schema has no output field at all — only
   `{tool_use_id, tool_name, parent_tool_use_id, elapsed_time_seconds, task_id?, uuid, session_id,
   heartbeat?, subagent_type?, subagent_retry?}` (SPEC 45 §45.14.8). The internal `bash_progress`
   event carries `output`, `fullOutput`, `totalLines`, `totalBytes` (SPEC 16 §16.13) and the wire
   converter drops all four (`cli.pretty.js:92968-92975`). The only route to live output is the
   **task output file on disk** (§20.9). A GUI that tails those files is strictly better off than one
   that waits for frames.

---

## 20.2 The persisted task list (storage)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Task list exists at all | Inline checklist panel above the prompt, backed by `~/.claude/tasks/<listId>/<id>.json` (§20.2.3) | Same files, same process; nothing about them is announced on the wire | R (disk) | A GUI reads `~/.claude/tasks/<listId>/*.json` directly and `fs.watch`es the directory. Record shape is `{id, subject, description, activeForm?, owner?, status, blocks[], blockedBy[], metadata?}` (§20.2.4). |
| Which directory to read | Resolved per call by `lA()` (§20.2.2): `CLAUDE_CODE_TASK_LIST_ID` → static team name → dynamic team name → leader team name → session id, then `[^a-zA-Z0-9_-] → "-"` | Same resolution; the session id is on the wire (`system/init.session_id`, `result.session_id`) | R | For an ordinary session the directory name **is the session UUID**, so a GUI already knows it. To be safe against team mode, afleet can set `CLAUDE_CODE_TASK_LIST_ID` in the child env and pin the path deterministically. |
| Sidecar files in the list dir | `.lock` (zero-byte anchor), `.highwatermark` (§20.2.3) | Same | R | A GUI must ignore dotfiles when listing, exactly as `WC` does (§20.2.7). |
| Task ordering | `listTasks` sorts by `Number(id)` ascending (§20.2.7) | Same on disk | R | Reproduce the numeric sort, not lexicographic. |
| Invalid task file | Logged and treated as absent (`null`), never fatal (§20.2.4) | Same | R | A GUI must fail soft on a half-written file; writes are `JSON.stringify(...,null,2)` and are not atomic-renamed. |
| Task-list change event | `Si().taskList.updated.emit()` → the panel re-renders (§20.2.7) | Not on the wire in any form | D | Workaround: `fs.watch` the list directory. There is no `task_list_changed` system frame. |
| Concurrency | `proper-lockfile` on `<listdir>/.lock` (create/reset/claim) or on `<id>.json` (update), 30 retries, 5–100 ms (§20.2.5) | Same | R | A GUI that only *reads* needs no lock; a GUI that *writes* tasks (see below) must take the same locks or it will race the CLI. |
| Writing tasks from the GUI | The TUI never writes tasks itself; only the model does, via the tools | No control request exists to create/update/delete a task | D | A GUI wanting a "user edits the checklist" affordance must write the JSON itself under the same lock discipline and id allocation (`max(highest file id, .highwatermark)+1`, §20.2.6). Unsupported but mechanical. This is a place a GUI can **exceed** the TUI. |
| Teammate mailbox side effect | Setting `owner` under teams writes a `task_assignment` message into `~/.claude/teams/<team>/inboxes/<agent>.json` (§20.2.8) | Same; not on the wire | R (disk) | Only relevant in team mode; owned by chapter 39. |
| `metadata._internal` tasks | Hidden from `TaskList` output (§20.3.4) | Present in the JSON on disk | R | A GUI reading disk must filter `metadata._internal` itself or it will show rows the TUI hides. |

Rows: 10

---

## 20.3 Task-list tools: TaskCreate / TaskGet / TaskUpdate / TaskList

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Tool-use rows for the four tools | **Absorbed silently** — no visible tool-use row at all; "pops out on error" (§20.2.1, `WNe` list covers `TodoWrite`, `TaskCreate`, `TaskGet`, `TaskUpdate`, `TaskList`) | Full `assistant` frame with a `tool_use` block and a `user` frame with the `tool_result`, like any other tool | R | The GUI must implement the same absorb-silently-but-show-on-error rule, or the transcript will be noisier than the terminal's. `is_error` on the `tool_result` is the trigger. |
| Tools are deferred | `shouldDefer: true` — reached through `ToolSearch`, so they are absent from the initial tool list (§20.3) | Same; `system/init.tools` will not list them until surfaced | P | Nothing to do; just do not treat their absence from `init.tools` as "task list disabled". |
| Tools are model-gated | `Y9() = ly() && UM()`. `UM()` turns the task/todo tools **off** on models at or above opus 4.8 / sonnet 5 / fable 5 / mythos 5 unless `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`, the `tengu_rosy_wren` gate, a background/fleet session, or `todoToolsOptIn` (§20.2.1) | Identical logic | P | Product consequence: on current models the task panel may simply never populate. If afleet wants a checklist panel to be reliably useful it should set `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` in the child environment. |
| `TaskCreate` result | Result block `Task #<id> created successfully: <subject>` (§20.3.1) | Same text in the `tool_result` | P | This is how a GUI correlates the streamed optimistic row with the real task id — the same regex the CLI uses, `/^Task #(\S+) created successfully/` (§20.6). |
| `TaskCreate` forces the panel open | `call` emits `{type:"set_expanded_view", expandedView:"tasks"}` (§20.3.1 step 4, §20.6) | `set_expanded_view` is **dropped before the wire** (SPEC 45 §45.9.2 filter `Cu`) | D | Trivial workaround: the GUI opens its own task panel whenever it sees a `TaskCreate`/`TaskUpdate` `tool_use`. No protocol change needed. |
| `TaskGet` result rendering | Multi-line block: `Task #id: subject` / `Status:` / `Description:` / `Blocked by:` / `Blocks:` (§20.3.2) | Same text in the `tool_result` | P | — |
| `TaskUpdate` result rendering | `Updated task #<id> <fields>`, plus the teammate "call TaskList now" tail (§20.3.3) | Same | P | — |
| `TaskUpdate` status transitions | `deleted` deletes the file; `completed` runs `TaskCompleted` hooks first (§20.3.3) | Same; hook activity visible only with `--include-hook-events` | P | — |
| `TaskList` result rendering | One line per task, `#id [status] subject (owner) [blocked by #a]`, or `No tasks found` (§20.3.4) | Same | P | A GUI should render from the disk files, not by parsing this — but the text is there if it prefers. |
| `coerceInput` repairs | Mis-shaped `TaskCreate` calls are silently repaired (`title`/`name`/`content`/`active_form`/`task` wrappers, backfills, key stripping) before the tool runs (§20.3.1) | Same repair, but the **wire `tool_use.input` is the raw, un-coerced input** | R | A GUI that renders the task from `tool_use.input` (e.g. for the optimistic preview) must run the same coercion, exactly as the CLI's own streaming preview does (§20.6). |
| `validationErrorSteer` | Two specific steer strings replace the generic schema error (§20.3.1) | Same, as the `tool_result` text with `is_error` | P | — |

Rows: 11

---

## 20.4 TaskCreated and TaskCompleted hooks

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `TaskCreated` / `TaskCompleted` hook firing | Fire around the task-list tools; stdin carries `task_id`, `task_subject`, `task_description`, `teammate_name`, `team_name` (§20.4) | Visible as `system/hook_started` / `hook_progress` / `hook_response` frames only with `--include-hook-events` (which afleet passes) | P | — |
| Blocking hook feedback | Rendered to the model as `TaskCreated hook feedback:\n<stderr>`; a blocking `TaskCreated` **deletes** the just-created task, a blocking `TaskCompleted` leaves it untouched (§20.4) | Same text reaches the model; the user-visible surface is the hook frames plus the erroring `tool_result` | P | The GUI should surface the erroring task tool call (this is exactly the "pops out on error" case above). |
| Exit-code-2 stderr shown to user | "Other exit codes — show stderr to user only" (§20.4) | Arrives as a `system/informational` banner (hook feedback path, SPEC 45 §45.9.1) | P | — |

Rows: 3

---

## 20.5 TodoWrite (legacy)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `TodoWrite` exists | Enabled only when the persisted task list is **off** (`!ly() && UM()`), i.e. mutually exclusive with the `Task*` tools (§20.5) | Same | P | A GUI must render whichever of the two surfaces is live; it can tell from which tool names appear. |
| Todo storage | **App state only, never disk.** Keyed by agent id, falling back to session id, so each subagent has its own list (§20.5.4) | Not on the wire and **not on disk** — `~/.claude/todos/` exists but has no writer in 2.1.257 (§20.5.4, Open questions) | D | The only source is the `TodoWrite` `tool_use.input.todos` array on the wire, which is the full replacement list every call. A GUI reconstructs the panel from the last `TodoWrite` input per `parent_tool_use_id`/agent. |
| Fully-completed list clears | A list where every item is `completed` is stored as `[]`, so the panel empties — but the tool result still echoes the submitted list (§20.5.4) | The wire shows the submitted list, not the stored `[]` | R | A GUI reproducing the panel must apply the same "all completed → clear" rule itself, otherwise it will show a stale full checklist the TUI would have hidden. |
| Subagent todo lists | Per-agent lists exist but the TUI panel shows the main session's | Subagent `TodoWrite` calls appear with `--forward-subagent-text` (which afleet passes) as `tool_use` blocks tagged with `parent_tool_use_id` and `subagent_type` — EVIDENCE A confirms subagent tool calls, not just text, are forwarded on 2.1.259 | P | A GUI can show per-subagent checklists — an affordance the TUI does not have. |
| `TodoWrite` result text | Fixed string "Todos have been modified successfully…" (§20.5.4) | Same | P | Not worth rendering. |

Rows: 5

---

## 20.6 activeForm and the task panel

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Inline task panel | Rendered when `ly()` and the list is non-empty; status glyphs `figures.tick` (success) / `squareSmallFilled` (claude colour) / `squareSmall`; subject bold when `in_progress`, struck through when `completed`, dimmed when completed or blocked (§20.6) | No panel; no frame describes it | R (disk) | Rebuild from `~/.claude/tasks/<listId>/*.json`. All the styling inputs (`status`, `activeForm`, `owner`, `blockedBy`) are in the record. |
| `activeForm` fallback | Spinner/panel shows `activeForm` while `in_progress`, else the `subject` (§20.6) | Same fields on disk and in `tool_use.input` | R | Reproduce the fallback; it is the one rule an implementer usually misses. |
| Owner chip `(@owner)` | Shown only when the terminal is ≥ 60 columns and the owner is an *active agent* (§20.6) | Owner is on disk; "is this owner currently an active agent" is not on the wire | R / D | The active-agent test needs the live teammate roster. `background_tasks_changed` lists `in_process_teammate` rows with their `description` but **not** `identity.agentName`, so matching owner→live agent is unreliable. Class D for the liveness dot specifically. A GUI has no column constraint, so it can always show the chip. |
| Owner activity second line | For an `in_progress`, unblocked task, a second line shows the owner's live activity description, truncated, with an ellipsis (§20.6) | Not on the wire | D | Nearest substitute is `task_progress.description` (which carries the subagent's `lastActivity.activityDescription`) for `local_agent` rows — but teammates are `in_process_teammate` and emit no such event. |
| `› blocked by #a, #b` suffix | Shown when open blockers remain; blockers filtered to *open* ones (§20.6, §20.3.4) | Computable from disk | R | Compute the open-blocker set (drop ids whose task is `completed`) yourself; the raw `blockedBy` array on disk is not filtered. |
| Sorting and overflow | When over budget: recently completed, in progress, pending (unblocked before blocked), older completed; remainder summarised as ` … +N in progress, M pending, K completed` (§20.6) | n/a | R / T | Mostly terminal-space management. A GUI with a scrollable panel does not need the overflow summary at all — a clear place to exceed the TUI. |
| Expanded-panel header | `<total> tasks (<done> done, <inProgress> in progress, <open> open)` (§20.6) | n/a | R | Trivially computed. |
| Optimistic streaming preview | While an assistant message is still streaming, `TaskCreate`/`TaskUpdate` calls are projected into a provisional list so the panel updates before the tools run; `pendingCreates` keyed by tool-use id, resolved by matching `/^Task #(\S+) created successfully/` (§20.6) | Reproducible: `--include-partial-messages` gives `stream_event` `input_json_delta`s for the same tool inputs | R | Requires running `coerceInput` on the partial input (§20.3.1). Fully rebuildable; this is one of the nicer polish items. |
| `RESUME.md` projection | Near a usage limit the task list is projected into todo shape and written into `RESUME.md` as `- [>] <activeForm>  ← current step` (§20.6) | Same file written on disk | R | Belongs to chapter 49; listed here because the projection uses `activeForm`. |
| Background-job "fan" projection | Background sessions project todos/tasks into `state.json.fan` entries `{id:"todo:<id>", kind:"todo", label}` (§20.6) | Readable from `~/.claude/jobs/<short>/state.json` | R (disk) | Only for `--bg` jobs; see §20.15. |

Rows: 10

---

## 20.7 Periodic reminders

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `todo_reminder` / `task_reminder` | `<system-reminder>` attachments after 10 assistant turns without the relevant tool and 10 turns since the last reminder (§20.7.1, §20.7.2). Not rendered to the user in either surface (`isMeta`) | Internal `attachment` messages are dropped by filter `Cu` unless they are `queued_command` / `tool_host_result_lines` / `hook_system_message` (SPEC 45 §45.9.2), so these never reach the wire | P | No user-visible difference. Listed because a GUI must not be surprised when the model suddenly rewrites the checklist unprompted. |
| Suppressing reminders | `CLAUDE_CODE_TODO_REMINDER_MODE=off`, or the `tengu_soft_slate_nudge` gate set to `off` (§20.7) | Same env var, settable by the host when spawning | P | A user-facing "stop nagging me about the checklist" toggle is available to a GUI via the child env. |

Rows: 2

---

## 20.8 The background-task registry

This is the core of the area. The registry is `AppState.tasks`, a `Record<taskId, Task>` (§20.8).

### 20.8.1–20.8.3 Kinds, ids, base record

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Ten task kinds | `local_bash` (shell), `local_agent` (subagent), `remote_agent` (cloud session), `in_process_teammate` (teammate), `local_workflow` (workflow), `monitor_mcp` (monitor), `monitor_ws` (monitor), `mcp_task` (MCP task), `dream`, `auto_mode_scan` (§20.8.1) | `task_started.task_type` and `background_tasks_changed[].task_type` carry the raw kind string | P | The display names (`shell`, `subagent`, `cloud session`, …) are **not** on the wire — only the raw `type`. The GUI must ship the same mapping (§20.8.1 table). One exception: the `Stop` hook payload uses the *display* names (§20.16.1). |
| Task ids | 9 chars: one kind letter (`b a r t w m s k d e`) plus 8 base-36 chars; **`local_agent` rows are keyed by the agent id instead** (§20.8.2) | Ids appear verbatim in every task event | P | The kind letter is a free type hint if a GUI ever sees an id without an accompanying event. Do not assume 9 chars for agents. |
| Base record fields | `{id, type, status, description, toolUseId?, startTime, endTime?, outputFile, outputOffset, notified, skipTranscript?, terminal?, totalPausedMs?}` (§20.8.3) | On the wire: `id`, `type`, `status`, `description`, `toolUseId`, `endTime` (as `end_time`), `outputFile` (only in `task_notification`), `totalPausedMs` (as `total_paused_ms`), `skipTranscript` | R / D | **`startTime` is never emitted.** A GUI must stamp its own "started at" from the arrival time of `task_started` — accurate enough live, wrong after `--resume` (the registry is rebuilt on resume and re-emits `task_started`, per §20.8.6, so ages restart). `outputOffset`, `notified`, `terminal` are internal. |
| `local_bash` extras | `command`, `cwd`, `isBackgrounded`, `agentId`, `kind:"monitor"`, `isAdopted`, `result.code` (§20.8.3, SPEC 16 §16.16) | `background_tasks_changed` gives `owner_agent_id` and `shell_kind` only in the *internal metadata* variant (`bc`), **not** in the emitted `Ka` payload (`cli.pretty.js:449055-449058`). `task_started` gives `owned_by_subagent` (boolean) but never the command string or cwd | D | The **command text** of a background shell is not on the wire as a field. It is available as (a) the `description` in `task_started` (which for a shell is the command's description, not the command), and (b) the `Bash` `tool_use.input.command` correlated by `tool_use_id`. Correlation by `tool_use_id` is the reliable route and is fully available. `cwd` is not obtainable at all — class D. |
| `local_agent` extras | `agentType`, `parentAgentId`, `spawnDepth`, `isObserver`, `isBackgrounded`, `prompt`, `keepaliveReasons`, `progress{tokenCount,toolUseCount,recentActivities,summary}`, `result{...}`, `killedBy` (§20.8.3) | `task_started` carries `subagent_type`, `spawn_depth`, `is_backgrounded`, `prompt`. `task_progress` carries `usage{total_tokens,tool_uses,duration_ms}`, `last_tool_name`, `summary`, `description` | P (mostly) | **`parentAgentId` is not emitted.** For nested subagents a GUI must build the tree from `spawn_depth` plus `parent_tool_use_id` on the forwarded subagent frames. `keepaliveReasons` (why a completed agent is being held/parked) is not on the wire — class D; the visible consequence is a `completed` agent that lingers in the roster. |
| `monitor_ws` extras | `url`, `ambient`, `frameLive` (§20.8.3, §20.13.5) | `task_started.ambient`, `background_tasks_changed[].ambient` | R / D | The WebSocket **URL** is not on the wire; it is in the `Monitor` `tool_use.input.ws.url`, so correlate by `tool_use_id`. |
| Observer tasks | Excluded from `/tasks` and from notifications (`Sd`, §20.8.4) | **Emit none of `task_started`, `task_updated`, `task_notification`** (§20.8.7) | P | Nothing to render; the GUI simply never learns they exist, which matches the TUI. |
| Parked agents | A `completed` `local_agent` with keepalive reasons is *parked*, not evicted: it still answers `TaskStop` and can be resumed with `SendMessage` (§20.8.4) | `task_updated` shows `status: "completed"`; nothing distinguishes parked from finished-and-evictable | D | This is a real UX gap: the TUI's `/tasks` shows parked agents under a **Completed** section with `x` still bound to stop them (§20.14.1/§20.14.2). A GUI can approximate: an agent that reported `completed` but has not been superseded is probably parked; `stop_task` on it will succeed rather than error. |

Rows: 8

### 20.8.4 State machine

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Statuses | `pending → running → completed \| failed \| killed`; terminal predicate `Fs` (§20.8.4) | `task_updated.patch.status` carries the same five values | P | — |
| `killed` vs `stopped` naming | Registry says `killed` (§20.8.4) | `task_notification.status` maps `killed → "stopped"` (`r === "killed" ? "stopped" : r`, §20.8.7); `task_updated.patch.status` keeps `killed` | P | A GUI must accept both spellings and normalise, or it will show a task as both killed and stopped. |
| Eviction | Terminal rows disappear when `notified`, all keepalives dropped and `evictAfter` (last drop + 30 s) has passed; `local_workflow` and `mcp_task` have extra delays (§20.8.5, §20.8.6) | Eviction is visible only as the row vanishing from the next `background_tasks_changed` payload | R | The GUI's own retention policy can differ — keeping a finished-task history is an obvious way to exceed the TUI, which forgets rows after 30 s. |

Rows: 3

### 20.8.7 SDK stream events — the wire schemas

These are the load-bearing schemas. Quoted from §20.8.7 and, for `task_progress` and
`background_tasks_changed` (which chapter 20 does not document), from `cli.pretty.js`.

`task_started` [§20.8.7, `chunk-1kg58a1a.js:96788`]:

```ts
{ type: "system"; subtype: "task_started";
  task_id: string;
  owned_by_subagent?: boolean;   // local_bash only: true when it has an agentId
  tool_use_id?: string;
  description: string;
  subagent_type?: string;
  is_backgrounded?: boolean;
  spawn_depth?: number;
  task_type: TaskKind;
  workflow_name?: string;
  prompt?: string;
  skip_transcript?: boolean;
  ambient?: true }
```

`task_updated` [§20.8.7, `chunk-1kg58a1a.js:96747`]:

```ts
{ type: "system"; subtype: "task_updated"; task_id: string;
  patch: { status?: TaskStatus; description?: string; end_time?: number;
           total_paused_ms?: number; error?: string; is_backgrounded?: boolean } }
```

`task_notification` [§20.8.7, `chunk-sct99ax9.js:669214-669218`] — emitted exactly once per task id
(one-shot claim `HN`):

```ts
{ type: "system"; subtype: "task_notification";
  task_id: string; tool_use_id?: string;
  status: "completed" | "failed" | "stopped";   // "killed" is mapped to "stopped"
  output_file: string;                           // "" when unknown
  summary: string;                               // "" when unknown
  usage?: Usage;
  resource_links?: unknown[];
  skip_transcript?: boolean;
  ambient?: true }
```

`task_progress` [not in chapter 20; `cli.pretty.js:98860-98862`, function `Yze`]:

```ts
{ type: "system"; subtype: "task_progress";
  task_id: string; tool_use_id?: string;
  description: string;
  subagent_type?: string;
  usage: { total_tokens: number; tool_uses: number; duration_ms: number };
  last_tool_name?: string;
  summary?: string;
  workflow_progress?: unknown }
```

Three producers: (a) the subagent query loop, once per subagent assistant message that ends in a
`tool_use`, with `description` set to the tracker's `lastActivity.activityDescription`
(`cli.pretty.js:100991`) — **ungated**; (b) the agent progress-summariser, gated on the `initialize`
option `agentProgressSummaries` (`Ohe()`, `cli.pretty.js:127665-127673`); (c) the workflow runner
(`cli.pretty.js:379222`).

EVIDENCE A shows producer (a) firing for a synchronous `Agent(Explore)` call:
`{task_id, tool_use_id, description: "Running ls …", subagent_type: "Explore",
usage: {total_tokens, tool_uses, duration_ms}, last_tool_name: "Bash"}` — no `summary` field, which is
the signature of the tracker producer rather than the summariser. No summariser frame appeared in that
probe despite `agentProgressSummaries: true`, but the run was short. This frame carries the data
behind the TUI's per-agent status line, and it is fully available to a GUI. Note `duration_ms` is computed from the task's `startTime`, which is the
only place the start time leaks onto the wire — as an elapsed value, not an absolute.

`background_tasks_changed` [not in chapter 20; `cli.pretty.js:449055-449059`, builder `Ka`]:

```ts
{ type: "system"; subtype: "background_tasks_changed";
  tasks: Array<{ task_id: string; task_type: TaskKind; description: string; ambient?: true }> }
```

Emitted from the app-state subscriber whenever `state.tasks` changes **and** the filtered list differs
by length, by `task_id` at a position, or by `ambient` (`cli.pretty.js:448968-448970`). The filter is
`tm(task) && !Sd(task)` — pending or running, not explicitly foregrounded, not an observer. So it is a
**roster of live tasks only**; a task disappearing from it is the signal that it finished or was
evicted. It carries no status, no command, no start time, no owner.

EVIDENCE A shows the practical consequence: a *synchronous* subagent (`is_backgrounded: false`) never
appears in `background_tasks_changed` at all, because `tm()` excludes explicitly-foregrounded rows.
The probe's only roster entry was the background shell,
`{task_id, task_type: "local_bash", description}`. So this frame is a **backgrounded**-work roster,
not a live-work roster, and a GUI must not use it to decide whether a subagent is running.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Task started | Registry `register` populates the panel/roster (§20.8.6) | `task_started` with the schema above | P | Emitted on **re-registration after resume** too, so a GUI must treat a repeat `task_started` for a known id as an update, not a new task. |
| Task field changes | `update` recomputes a minimal patch (§20.8.6) | `task_updated` with only the six patchable fields | P | Only `status`, `description`, `end_time`, `total_paused_ms`, `error`, `is_backgrounded` ever change on the wire. Anything else (command, cwd, progress, owner) is either static or invisible. |
| Task finished | Terminal transition drives the notification and the roster removal (§20.8.6) | `task_notification` once, plus a `task_updated` with the terminal status, plus the task dropping out of `background_tasks_changed` | P | Three signals for one event; a GUI should key off `task_notification` and treat the others as corroboration. |
| Live roster | The `/tasks` dialog reads `AppState.tasks` directly (§20.14.1) | `background_tasks_changed` is the closest thing, and is much thinner | R | Rebuild the roster by folding `task_started` (rich) + `task_updated` (status) and using `background_tasks_changed` only as a liveness cross-check. Do **not** try to build the roster from `background_tasks_changed` alone. |
| Exit code of a background shell | Shown in the completion line and in the `/tasks` detail (§20.10.5) | Not a field anywhere. It is embedded in `task_notification.summary` as `… completed (exit code 0)` / `… failed with exit code 3` (§20.10.5) and appended to the output file as `\n[exited with code N]\n` (§20.9.2) | D (field) / R (parse) | Parse the summary, or tail the output file's terminator. There is no structured exit code on the wire. |
| Event-queue overflow | n/a | The per-key event ring is capped at 1000; on overflow the oldest **non-bookend** event is dropped, where `conversation_reset`, `task_started`, `task_notification` and null-status `status` events are protected (§20.8.7) | P | Reassuring: a GUI that misses only `task_updated`/`task_progress` frames under load can still reconstruct start and end. |

Rows: 6

---

## 20.9 Task output files

Path (§20.9, confirmed against a live tree):

```text
<realpath(os.tmpdir())>/claude-<uid>/<project-slug>/<session-uuid>/tasks/<taskId>.output
```

`<project-slug>` is the cwd with non-alphanumerics replaced by `-`, truncated with a base-36 hash
suffix past a length limit (SPEC 16 §16.13, `chunk-9v1cn5qp.js:351865-351870`). For a `local_agent`
the `.output` entry is a **symlink** into
`~/.claude/projects/<slug>/<sessionId>/subagents/agent-<agentId>.jsonl`.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Live background-shell output | The `/tasks` shell detail view tails the last **8192 bytes** of `pl(task.id)` via `poe(path, 8192)` (`cli.pretty.js:407757-407764`, §20.9.2) | `tool_progress` for Bash exists only under `CLAUDE_CODE_REMOTE` or `CLAUDE_CODE_CONTAINER_ID`, is throttled, and **carries no output** — only `elapsed_time_seconds` and `task_id` (SPEC 45 §45.14.8) | **R (file)** | **The headline row.** EVIDENCE A confirms no `tool_progress` for Bash arrived at all. GUI workaround: tail the output file directly. The path is handed to the GUI three ways, two of them verified live: the `Bash` `tool_result` text (`Command running in background with ID: <id>. Output is being written to: /private/tmp/claude-501/<slug>/<session>/tasks/<id>.output`), `task_notification.output_file` at completion, and derivation from tmpdir+slug+session id. The observed path is `/private/tmp/...` on macOS — the realpath of `/tmp`, matching `$d()`'s `realpathSync` (§20.9); a GUI deriving the path itself must realpath too. Tailing beats the TUI: no 8 KB window, no polling interval. |
| Getting the `task_id` for a *foreground* shell that has not been backgrounded | The TUI has the registry in-process; a pre-registered foreground shell exists from the 2 s mark (`T6t`, `isBackgrounded:false`, SPEC 16 §16.16) | `task_started` **is** emitted for the pre-registration (registry `register`), and `tool_progress.task_id` is available under `CLAUDE_CODE_REMOTE`/`CLAUDE_CODE_CONTAINER_ID` | P / R | With `task_started` carrying `tool_use_id`, a GUI can map running Bash tool calls to output files without any env var. Setting `CLAUDE_CODE_CONTAINER_ID` additionally gives throttled elapsed-time ticks, at the cost of an `x-claude-remote-container-id` API header (SPEC 07 §1192) — a milder side effect than `CLAUDE_CODE_REMOTE`, which also clamps `Monitor` and changes autocompact reporting. |
| Nested subagent activity | The TUI shows a collapsed subagent row; the full nested transcript is not browsable inline | Much of it is already on the wire. EVIDENCE A: with `--forward-subagent-text` on 2.1.259 a subagent's **`tool_use` and `tool_result` blocks are forwarded too**, not just text and thinking — as `assistant`/`user` frames with `parent_tool_use_id` = the `Agent` tool-use id and `subagent_type` set. Depth comes from `task_started.spawn_depth`. Beyond that, the `.output` symlink points at the subagent's JSONL transcript, which contains everything including *its* nested subagents | P (wire) / R (file) | Better than SPEC 45's summary ("text and thinking blocks") implies. A GUI can render a live nested-subagent tree straight from the wire and fall back to the JSONL for anything trimmed. The model is forbidden from reading that file (§20.11.2) because it would overflow context; the restriction does not apply to a GUI. |
| In-band output markers | `\n[exited with code N]\n`, `\n[killed]\n` appended before the notification; `\n[output truncated: exceeded 5GB disk cap]\n` at the 5 GB cap; `\n[output omitted: it could not be written to disk]\n` on write failure (§20.9.1, §20.9.2) | Same bytes in the file | R | A GUI tailing the file must recognise these as harness markers, not program output, and use the exit marker to close the stream. Adopted shells skip the terminator (§20.9.2) — do not wait forever for it. |
| Read caps | `getTaskOutput`/`getTaskOutputDelta` cap at 8 MiB by default; the tail reader prefixes `[<N>KB of earlier output omitted]` (§20.9.2) | Irrelevant to a GUI reading the file itself | T | A GUI has no such cap. |
| Output-file lifetime | The writer is flushed and dropped at task completion (`Td`, §20.9.2); the file itself remains under the session temp directory | Same | R | Files survive the task, so a GUI can offer "show me the output of that shell from ten minutes ago" — the TUI's `/tasks` cannot, because the row is evicted. |

Rows: 6

---

## 20.10 `<task-notification>` injection

**The systematic rule for this whole section.** A `<task-notification>` reaches the host *only* if its
producer additionally calls `hs()` (the `task_notification` SDK emitter). Producers that call only
`Ra()` / `enqueuePendingNotification` are **entirely invisible headless**, because the injected user
message itself is dropped (row 1, EVIDENCE B). Checking each producer:

| Producer | Calls `hs()`? | Visible headless? |
|---|---|---|
| Shell/monitor completion (`Ddt`, §20.10.5) | yes | yes — `task_notification` |
| Subagent completion (`$q`, §20.10.4) | yes (via the registry terminal transition, §20.8.6) | yes |
| Stop notifications (§20.10.7, §20.12.5 step 8) | yes | yes |
| **Interactive-prompt stall watchdog** (`tWn`, `cli.pretty.js:127885-127916`) | **no** — `Ra(...)` only | **no** |
| **Monitor events** (`JM`, §20.10.6, `chunk-1kg58a1a.js:96505-96511`) | **no** — `Ra(...)` only | **no** |
| Container-restart notice (§20.16.3) | no | no |
| Artifact / room lifecycle notices (chapter 44) | no | no |

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| How the notification reaches the model | Enqueued on the command queue with `mode: "task-notification"`, delivered at the next turn boundary as a user-role message whose text is a `<task-notification>` element wrapped in `<system-reminder>` (§20.10) | **Not emitted at all.** EVIDENCE B: with the host idle, the completion produced `background_tasks_changed`, `task_updated`, `task_notification`, then `hook UserPromptSubmit`, then a fresh `system/init` and a complete unprompted assistant turn — with **no `user` frame** for the injected notification, even though `--replay-user-messages` was on. Cause: the notification is delivered as a `queued_command` attachment, and the converter skips it when the attachment is meta and its origin is a task-notification (`cli.pretty.js:142595`) | **D** | **This is the defining gap of the area.** The host sees an assistant turn appear from nowhere. GUI workaround: synthesise the timeline item from `task_notification` (which carries `task_id`, `tool_use_id`, `status`, `output_file`, `summary`, `usage`) and treat the `hook UserPromptSubmit` + `system/init` pair that follows with no host input as the marker that an auto-turn has begun. My earlier reading of SPEC 45 §45.9.3 suggested this would arrive as a `user` frame with `origin: {kind:"task-notification"}`; the live probe disproves that. |
| Element shape | Six scalar children in fixed order, each omitted when falsy: `task-id`, `tool-use-id`, `task-type`, `output-file`, `status`, `summary`; then the body (`<note>`, `<result>`, `<usage>`, `<worktree>`, `<event>`) (§20.10.1, §20.10.2) | The element itself never reaches the host (row 1). Its scalar fields all reappear structurally in `task_notification`: `task_id`, `tool_use_id`, `status`, `output_file`, `summary`, `usage` | P | The one thing with no structural equivalent is `task-type`, and that is recoverable from the `task_started` for the same `task_id`. The body elements (`<note>`, `<result>`, `<worktree>`, `<event>`) are lost — see the rows below. |
| The three "NOT USER INPUT" preambles | `BAe` (standalone), `L3t` (arriving with a real user message), plus the scheduled-firing preamble, prepended idempotently inside the `<system-reminder>` (§20.10.3) | Never on the wire (the whole injected message is dropped — row 1) | P | Nothing to strip, because nothing arrives. Listed so a reimplementer does not go looking for it. |
| Subagent completion notification | Summary variants: `Agent "<desc>" finished` / `… stopped at its N-turn limit (partial result; SendMessage to task-id to continue)` / `… failed: <error>` / `… was stopped by Claude` / `… was stopped by user` / `… was stopped`; body carries `<note>`, `<result>`, `<usage>`, `<worktree>` (§20.10.4) | Only the structured `task_notification` (`status`, `summary`, `usage`, `output_file`) reaches the host; the XML text does not | R | `<result>` (the agent's report text), `<note>` and `<worktree>` are **not recoverable from the notification**. For a synchronous `Agent` call the report is in the `Agent` `tool_result` — EVIDENCE A shows its `tool_use_result` carrying `{status, prompt, agentId, agentType, harnessNoteCount, harnessTailCount, harnessSectionHash, content, resolvedModel, totalDurationMs}`. For a *backgrounded* agent whose result lands after the turn, read the `.output` symlink (§20.9). |
| Background-shell completion notification | Summary variants per §20.10.5, including the monitor variants | Same | P | — |
| Interactive-prompt stall watchdog | After 45 s of no output growth, matches the last line against y/n-style prompts and fires **once** with `Background command "<desc>" appears to be waiting for interactive input` plus the last ≤1024 bytes and remediation advice (§20.10.5) | **Nothing.** `tWn` calls `Ra(...)` only, never `hs(...)` (`cli.pretty.js:127885-127916`), and the injected message is dropped | **D** | The user is never told their build is sitting on a `(y/n)` prompt. Workaround: a GUI tailing the output file (§20.9) can run the same check itself — the file stops growing for 45 s and the last line matches `/\(y\/n\)/i`, `/Press (any key\|Enter)/i`, `/Continue\?/i` and the rest of `Szo` (SPEC 16 §16.16). Reimplementing it is ~20 lines and yields a better affordance than the TUI's, because the GUI can offer a stop button inline. |
| Memory-pressure reaping | A top-level background shell is killed under memory pressure after 30 min of user idleness, with the normal killed notification (§20.10.5) | Same notification path | P | Disable with `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP` if a GUI wants shells to outlive idle periods. |
| Monitor events | Each 200 ms batch of monitor stdout becomes its own notification: `<summary>Monitor event: "<desc>"</summary><event>…</event>`, plus a PushNotification hint when push is available (§20.10.6) | **Nothing.** `JM` calls `Ra(...)` only (§20.10.6, `chunk-1kg58a1a.js:96505-96511`) and the injected message is dropped | **D** | The event still reaches the model (it starts an unprompted turn), so the host sees the *consequences* of an event it never saw. Workaround: a command monitor is a `local_bash` task, so its stdout is in the task output file — tail it and apply the same 200 ms batching. A `monitor_ws` has an output file too. Lifecycle lines (`[Monitor stopped — too much output …]`, `[WebSocket closed: …]`) are equally invisible. |
| Stop notifications | `Task "<desc>" was stopped by <agent id or "main session">` (status `stopped`); and the user-stop variant `Task "<desc>" was stopped by the user` (status `killed`), enqueued **`passive: true`** so it does not by itself wake a turn (§20.10.7) | The matching `task_notification` **is** emitted (§20.12.5 step 8), carrying the same `summary`; the injected text is not. EVIDENCE A confirms the `end_session` path: `task_updated{status:"killed"}` then `task_notification{status:"stopped"}` | P | Note the two spellings for one event, as in §20.8.4. A GUI that stops a task should still render its own confirmation from the `stop_task` control response rather than waiting for the notification, since the passive variant may not be followed by a turn. |
| Coalescing | Runs of consecutive `Background command …` / `Remote task "…"` completions collapse to `N background commands completed` / `N remote tasks completed` (§20.10.8) | Irrelevant — it operates on queued messages, which never reach the host | P | The host gets one `task_notification` **per task** regardless, so it can show them individually. Better than the TUI, for free. |
| Notification size cap | `task-notification` values are capped at 100000 characters, with a debug log line (§20.10.9) | Applies to the queued text only, which the host never sees | P | Affects what the model reads, not the GUI. |
| `task_status` attachment (legacy) | A second, older surface rendered as plain meta text ("Background agent … is still running. Progress: …") (§20.10.10) | Post-compaction producer only; the per-turn producer `Nxn` never populates its array in 2.1.257 (§20.10.10, Open questions) | P | Effectively dead except right after a compaction. Do not build a GUI feature on it. |
| `GetTask` structured delivery | Fully implemented but gated behind `hA()`, a hard-coded `return !1` (§20.10.11, SPEC 16 §16.16) | Never occurs in 2.1.257 | P | Named here so a GUI is not surprised if a future build starts splicing synthetic `GetTask` `tool_use`/`tool_result` pairs into the transcript for finished shells. Prepare to ignore `tool_use.id` values beginning `gettask_`. |

Rows: 13

---

## 20.11 TaskOutput

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `TaskOutput` tool | Deprecated; aliases `AgentOutputTool`, `BashOutputTool`, `AgentOutput`, `BashOutput`; user-facing name "Task Output" (§20.11) | Ordinary `tool_use`/`tool_result` frames | P | Its `description()` literally begins `[Deprecated]`. A GUI should render it as a low-key row. |
| Blocking wait | With `block: true` (default), polls every 100 ms up to `timeout` (default 30000 ms, max 600000) and emits a progress event `{type:"progress", toolUseID:"task-output-waiting-<ts>", data:{type:"waiting_for_task", taskDescription, taskType}}` (§20.11.4) | That progress event is an internal `progress` with an unhandled `data.type`, so `TLe` yields nothing for it (SPEC 45 §45.9.3) | D | The user sees a stalled tool call with no explanation for up to 10 minutes. Workaround: the GUI knows the tool is `TaskOutput` and can synthesise "waiting for task <id>" from `tool_use.input.task_id` plus its own registry mirror. |
| Retrieval status | Result block starts `<retrieval_status>success\|not_ready\|timeout</retrieval_status>` and then `<task_id>`, `<task_type>`, `<status>`, `<exit_code>`, `<output>`, `<error>` joined by blank lines (§20.11.7) | Same text | P | This is the one place a structured `<exit_code>` reaches the transcript. |
| Output truncation | Keeps the **last** `TASK_MAX_OUTPUT_LENGTH` chars (default 32000, capped 160000) with one of two banners (§20.11.6) | Same | P | A GUI showing the full file instead is strictly better. |
| Marking `notified` | A terminal `TaskOutput` read stamps `notified`, which suppresses the `<task-notification>` for that task (§20.11.4) | Consequence visible as a **missing** `task_notification` | D | A GUI that keys "task finished" solely off `task_notification` will miss tasks the model drained with `TaskOutput` first. Also key off `task_updated.patch.status` reaching a terminal value. Important correctness note. |
| "Don't read the transcript" guidance | The prompt and the `Agent` tool's async-launch result both forbid reading a `local_agent`'s `.output` (it is the JSONL transcript) (§20.11.2) | Same text in tool results | P | Applies to the model, not to the GUI (see §20.9). |

Rows: 6

---

## 20.12 TaskStop

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Model-initiated stop | `TaskStop` tool, aliases `KillShell`, `KillBash`; user-facing name "Stop Task" (§20.12) | Ordinary tool frames | P | — |
| **User-initiated stop** | `x` in the `/tasks` dialog, routed through the full `TaskStop` pipeline (§20.14.2) | `stop_task` control request, `{task_id: string}`, answering `{}` or an error (SPEC 45 §45.22.10; handler at `cli.pretty.js:178235-178246` calls the user-source stop with `source: "user"`) | P | This is the one background-task *action* a headless host has, and it is complete. Errors come back as control errors with the messages of §20.12.3/§20.12.4. |
| Identifier resolution | Accepts a task id, an agent id `name@team`, a bare teammate name, or a registered background-agent name, with ambiguity reporting and fuzzy suggestions (§20.12.3) | Same resolution behind `stop_task` | P | A GUI should pass the exact `task_id` it learned from `task_started`; the fuzzy paths exist for the model. |
| Stop failure messages | `No task found with ID: <id>. Did you mean: …`; `Multiple teammates match "<name>": …`; `Task <id> is not running (status: <status>)` (§20.12.3, §20.12.4) | Returned as the `control_response` error message | P | Render verbatim; they are already user-grade. |
| Cascade | Stopping a **parked** agent also kills descendants whose ancestry reaches it, each emitting its own `stopped` event; spared ids are reported (§20.12.5 step 7) | Each cascaded kill emits its own `task_notification` | P | A GUI stopping one agent should expect several notifications. |
| Session-wide stop | `ctrl+x ctrl+k` in `/tasks` stops all agents (`fzn`); `nY` stops everything user-interruptible (§20.12.6, §20.14.2) | **No control request for "stop all".** `stop_task` is per-task | R | A GUI issues N parallel `stop_task` requests using its registry mirror. Equivalent behaviour, more round trips. |
| `perTaskStopAffordance` | n/a (the TUI always has `/tasks`) | An `initialize` boolean. Declaring it tells the CLI the host renders a per-task stop control, so **an interrupt on an open-input stream-json session spares running background agents/workflows** (Stop only aborts the turn). Absence fails closed: interrupt kills background tasks. A one-shot run (string prompt / `-p` with stdin closed) still kills hold-back tasks at held-result release regardless (SPEC 45 §45.22, `initialize` schema) | P | **afleet must set `perTaskStopAffordance: true` in `initialize`** and actually render the per-task stop control; otherwise every Esc kills the user's background agents. First-attached-client-wins; later `initialize`s do not change it. |
| Persisted stop marker | `stoppedByUser: true` and an incremented `userStopCount` merged into the agent's on-disk record so a resumed session knows (§20.12.7) | Same on disk; not on the wire | R (disk) | Only matters if the GUI wants "you stopped this last time" across resumes. |

Rows: 8

---

## 20.13 Monitor

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `Monitor` tool availability | Gated on `tengu_amber_sentinel` (**default false**) and a POSIX-ish shell (§20.13) | Same gate; presence visible in `system/init.tools` after `ToolSearch` | P | Most sessions will not have it. Do not build a first-class GUI surface on the assumption it exists. |
| Command monitors | Each stdout line is an event; registers a `local_bash` task with `kind: "monitor"` (§20.13.4) | `task_started` with `task_type: "local_bash"` — **`shell_kind: "monitor"` is not in the emitted payload** (it exists only in the internal-metadata variant, `cli.pretty.js:449055-449058`) | D | A GUI cannot tell a monitor from an ordinary background shell from `task_started` alone. Workaround: the `tool_use` that created it is `Monitor`, not `Bash` — correlate by `tool_use_id`. The `/tasks` dialog labels monitors by `description` rather than `command` for exactly this reason (§20.14.1). |
| WebSocket monitors | `monitor_ws` kind; frames become events; lifecycle lines `[WebSocket closed: <code> <reason>]`, `[WebSocket error: …]`, `[binary frame, N bytes]`, `[Dropped N-byte frame …]` (§20.13.5) | `task_started` with `task_type: "monitor_ws"` and the terminal `task_notification` arrive; the lifecycle lines themselves are housekeeping monitor events, which are queue-only and therefore invisible (§20.10 producer table) | P (lifecycle: D) | The `ambient` flag is on the wire in both `task_started` and `background_tasks_changed`. The close code and error text are not — read them from the monitor's task output file. |
| Batching and rate limiting | 200 ms debounce; lines capped at 500 chars, batches at 3000; token bucket of 10 refilling one per 2 s; 30 s of continuous suppression auto-stops the monitor with `[Monitor stopped — too much output …]` (§20.13.6) | Same, as notification text | P | Nothing to rebuild; but a GUI should render these bracketed housekeeping lines as system chrome, not as monitor output. |
| Timeout / persistent | Default 300000 ms, max 3600000; `persistent: true` runs to session end. Under `CLAUDE_CODE_REMOTE` persistence is forced off and the timeout clamped to 30 min (§20.13.1) | Same | P | Another reason not to set `CLAUDE_CODE_REMOTE` just to get Bash `tool_progress`. |
| WebSocket permission dialog | `ask` with `Monitor will open a WebSocket to <url> (subprotocols: …)`; denials for org policy, private/link-local/metadata addresses, sandbox policy (§20.13.3) | Arrives as a normal `can_use_tool` permission request | P | Render the message verbatim; it names the URL, which is otherwise not on the wire. |
| Result block | `Monitor started (task <id>, persistent — runs until TaskStop or session end). …` (§20.13.7) | Same `tool_result` | P | Carries the task id, so the GUI can bind the monitor row to a tool call immediately. |

Rows: 7

---

## 20.14 The `/tasks` dialog

`/tasks` (alias `bashes`) is declared `type: "local-jsx"` with no `isEnabled` (§20.14). Per SPEC 28
§22, **no `local-jsx` command runs headless**: `filterCommandsForHeadless` keeps only `prompt`
commands without `disableNonInteractive` and `local` commands with `supportsNonInteractive`, and an
attempted invocation is refused with `/<name> opens an interactive panel and isn't available in this
environment. Run it from the Claude Code terminal instead.` (SPEC 28 §8.1 row 4).

Confirmed against live ground truth on 2.1.259: the `initialize` `commands` list from
`/tmp/afleet-gap/init-dump.json` contains 102 entries and **none** of `tasks`, `bashes`,
`background`, `bg`, `subtask`. (Other `local-jsx` commands such as `model`, `context`, `mcp` *are*
present because they have `local` twins enabled non-interactively.)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Opening `/tasks` | Ink dialog titled `Background`, cancel message `Background dialog dismissed` (§20.14) | Refused; not even offered in the command list | **X** (the dialog) / **R** (its content) | Everything the dialog *shows* is rebuildable from the registry mirror; everything it *does* is reachable via `stop_task`. The dialog itself is unreachable. |
| Which rows are listed | `Ywe`: any pending/running task not explicitly `isBackgrounded:false`, **plus** completed background subagents that are non-observer, `evictAfter !== 0`, and whose only keepalive is the idle-window flag (§20.14.1) | Derivable from the mirror, except the keepalive condition | R / D | The "completed but retained" inclusion rule depends on `keepaliveReasons`, which is not on the wire — class D for exact parity. Practical approximation: keep completed background agents visible for a while after `task_notification`. |
| Row sorting | Running first, then `startTime` descending (§20.14.1) | `startTime` is not on the wire | R | Use the GUI's own arrival timestamps. Ordering will differ after a resume. |
| Row labels per kind | `local_bash` → `command` (or `description` when `kind==="monitor"`); `remote_agent` → `title`; `local_agent` → `description`; `in_process_teammate` → `@<agentName>`; `local_workflow` → `summary ?? description`; others → `description` (§20.14.1) | `description` is on the wire for every kind; `command`, `title`, `summary`, `agentName` are **not** | D (per field) / R | For `local_bash` the TUI shows the *command*, the wire gives the *description*. Recover the command from the `Bash` `tool_use.input.command` by `tool_use_id`. `in_process_teammate`'s `@name` and `remote_agent`'s `title` have no wire source at all. |
| Sections and order | Fixed order with headers: `Agents`, `Shells`, `Monitors`, `MCP tasks`, `Cloud agents`, `Local agents`, `Completed`, `Dynamic workflows`, then unheadered `dream` and `auto-mode scan`. `Agents`/`Shells` headers suppressed when no other kind is present. Header format `  <Label> (<count>)` (§20.14.1) | n/a | R | Straightforward to reproduce from `task_type`. Note `Local agents` = running `local_agent`, `Completed` = completed-but-retained `local_agent`. |
| Empty state | `No tasks currently running` (§20.14.1) | n/a | R | — |
| Subtitle counts | ` · `-separated, zero counts omitted: `<N> agents · <N> active shells · <N> active agents` (§20.14.1) | n/a | R | — |
| `↑`/`↓` select | Always available (§20.14.2) | n/a | T | GUI list navigation supersedes. |
| `enter` view | Opens a per-kind detail dialog when the kind is viewable (`Qwe`: everything except `monitor_ws`; `mcp_task` only when its detail module loaded). For shells the detail tails 8192 bytes of the output file (`cli.pretty.js:407757-407764`) | Detail content is rebuildable from the output file; the per-kind dialogs themselves are unreachable | R | A GUI detail pane tailing the whole file exceeds the TUI's 8 KB window. |
| `enter` on a teammate / completed foregroundable agent | Foregrounds it instead, with transient message `Viewing agent` / `Viewing teammate` / `Viewing leader` (§20.14.2) | **No control request foregrounds a task** | X | Foregrounding is an in-process TUI state change with no protocol surface. A GUI's equivalent is to focus its own subagent transcript pane — different mechanism, comparable UX. |
| `f` foreground | Available for a running teammate, a foregroundable `local_agent`, or the leader row (§20.14.2) | Same as above | X | — |
| `x` stop | Any running task, or a parked `local_agent`. A press immediately after an auto re-index is swallowed once so a list change cannot cause an accidental kill (§20.14.2) | `stop_task` control request | P | Worth copying the "swallow the first press after a list reshuffle" safety behaviour. |
| `ctrl+x ctrl+k` stop all agents | Available when more than one `local_agent` is running (§20.14.2) | N × `stop_task` | R | See §20.12. |
| `escape` close | Always (§20.14.2) | n/a | T | — |
| Auto-open on detail | Opens straight to the detail view when given an `initialDetailTaskId`, or when exactly one task qualifies and it is viewable and not a completed-retained agent; closes (or falls back to the list) when its task disappears (§20.14.3) | n/a | R | A nice touch worth copying: single running task → show its output directly. |

Rows: 15

---

## 20.15 `/background`, `--bg`, `/subtask` and the job system

A **job** is a whole detached Claude Code session under the local background service — not a registry
task (§20.15). All three commands are `local-jsx`, so none is reachable headless (see §20.14 above;
live init-dump confirms all three are absent from the `commands` list).

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/background` (alias `bg`) | Confirmation dialog `Background this session?` with a `Stay` cancel; hands the session off to a detached job and prints the four-line `backgrounded · <short> · <name>` banner listing `claude agents/attach/logs/stop` (§20.15.1) | Unreachable (`local-jsx`) | X | A GUI's equivalent is to spawn its own second `claude` process — it does not need the CLI's job system at all. If it wants parity with `claude agents`, it can read `~/.claude/jobs/` (below). |
| `/background` refusal messages | `Cannot background — session persistence is disabled…`; `Nothing to background yet — send a message first.`; `Forking is not available in coordinator sessions. Use /branch instead.`; `Couldn't fork — this conversation is still being saved. Try again in a moment.` (§20.15.1) | n/a | X | Listed for completeness. |
| `/subtask` | Sends a **fork** subagent with the session's full context; the result comes back in the same conversation (§20.15.2). `isEnabled: () => !Rs()` | Unreachable as a command | X / R | The underlying capability is not: a GUI can inject a user message asking for a fork subagent, and the resulting `local_agent` task is fully visible on the wire. So the *affordance* is X, the *capability* is R. Worth exposing as a GUI button. |
| `--bg` / `--background` CLI flag | Starts a detached job; `--exec <cmd>` runs a bare shell command as a job; extensive copy/resume notes on stderr (§20.15.3) | Not applicable to a hosted headless session (afleet spawns the binary itself) | T | Listed because a GUI could shell out to `claude --bg` to get the same detached-session behaviour. |
| Job on-disk layout | `~/.claude/jobs/<8-hex-short>/` with `state.json` (mode 0600), `timeline.jsonl`, `exit-cause`, `exit-detail`, `.prompt-draft`, `tmp/`; root also holds `pins.json` and `.draft-<8hex>` (§20.15.4) | Same files | R (disk) | A GUI can build a full "other background sessions" panel by reading this tree — matching `claude agents`. |
| `state.json` contents | The full schema of §20.15.5: `state`, `detail`, `tempo`, `inFlight{tasks,queued,kinds,wake}`, `fan[]`, `budget`, `tokens`, `needs`, `block{questions}`, `suggestedReply`, `output`, `children[]`, `template`, `respawnFlags`, `name`, `color`, `sessionId`, `cwd`, `worktreePath`, timestamps, bridge fields, `pid` | Readable on disk | R (disk) | `needs` and `block.questions` are exactly what a GUI needs for a "this background session is waiting on you" badge. `fan[]` is the per-job task/todo roster (§20.6). |
| Job states | `starting`, `resuming`, `adopted`, `crashed` (transient) → `working`, `blocked` → terminal `done`, `failed`, `stopped`; `tempo` is orthogonal (`active`/`idle`/`blocked`) (§20.15.6) | On disk | R | Reproduce the "terminal and not `active`" rule (`Li`) before showing a job as finished. |
| `timeline.jsonl` | One `{at, state, detail?, text}` per persisted state change; `text` is new assistant text truncated to 4000 chars (§20.15.7) | On disk, append-only | R (disk) | Tailable — this is how a GUI renders a live feed of a detached session without attaching to it. |
| `exit-cause` / `exit-detail` | Bare cause token, and `<cause>\n<≤200 chars>`. **Reading is destructive** — the reader unlinks the file (§20.15.8) | On disk | R (disk) | Caution: a GUI that reads these will consume them out from under the CLI's supervisor. Read-without-unlink, or leave them alone. Cause tokens include `session_in_use`, `cli_error`, `uncaught:<Name>`, `worktree_create`, `preflight_endpoint` (§20.15.8 table). |
| `CLAUDE_JOB_DIR` | Absolute path of this process's job directory; its presence makes `Qa()` true, which **force-enables the task tools** regardless of the model gate, and enables the timeline writer (§20.15.4, §20.2.1) | Env var the host controls | P | A GUI can set `CLAUDE_JOB_DIR` to force the task tools on and get a timeline — but it then owns the job-directory contract. `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` is the cheaper way to force the tools on. |
| Dispatch record | `{proto, short, sessionId, source, cwd, launch{mode:"prompt"\|"resume"\|"exec"}, env, isolation, respawnFlags, agent, seed, cols, rows}` (§20.15.9) | Internal to the daemon protocol (chapter 38) | X | Out of scope for a host that spawns its own processes. |

Rows: 11

---

## 20.16 Background work and turn termination

This is the section that decides whether a GUI's background work survives. Answering the brief's
question directly, now confirmed live: **in the shape afleet runs (stream-json input, stdin held
open), background work survives across turns and is not killed at `result` time — EVIDENCE B shows a
background shell completing about six seconds after the turn's `result`, with the session still
healthy. Ending the session kills it — EVIDENCE A shows `end_session` producing
`background_tasks_changed{tasks:[]}`, `task_updated{status:"killed"}` and
`task_notification{status:"stopped"}` for a shell that was still running.**

The mechanics, from §20.16.2 and `cli.pretty.js:174130-174200`:

```js
function Fm({ inputClosed: e, currentState: n, hasActiveTeammates: r, hasRunningBgTasks: o, hasPendingNotification: _ }) {
  if ((r || o || _) && a.CLAUDE_CODE_BG_TASKS_REPORT_RUNNING) return !1;
  return !e && n === "running";
}
```

* With stdin **open** (`inputClosed === false`), the run is simply not finished, so no wind-down runs
  and background tasks keep going between turns. Turn N's `result` frame does not disturb them.
* With stdin **closed** and `CLAUDE_CODE_BG_TASKS_REPORT_RUNNING` unset, the run ends immediately; the
  wind-down wait never engages.
* With stdin closed **and** `CLAUDE_CODE_BG_TASKS_REPORT_RUNNING` set, `jm` keeps the run alive while
  background tasks exist, with a 5000 ms grace (`Tl`) before the sweep and a hard ceiling of
  `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` (default 600000 ms).
* The sweep `Wm` then: **kills** every `local_bash`; **kills** mid-delivery observer agents; **kills**
  agent-like running tasks only once the ceiling is reached; and otherwise **abandons** the task,
  emitting a `stopped` `task_notification` for it without actually stopping it.
* At stream close, `Dl` kills every still-running `local_bash` — sparing only a *foreground* shell
  whose owning agent is still alive — logging `print teardown: killing shell <id> ("<desc>") still
  running at stream close`. Guarded by `Al({shuttingDown, remoteTransport})`, i.e. it runs on a normal
  stream close but not during process shutdown or on a remote transport
  (`cli.pretty.js:176769`, `178815`).

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Background work across turns | Survives; the panel and `/tasks` keep showing it (§20.14) | Survives while stdin is open (EVIDENCE B) | P | afleet's shape is correct by default. Do not close stdin between turns. |
| Ending the session | n/a | Both routes kill running background shells. Closing stdin ends the run and `Dl` kills every running `local_bash`; `end_session` does the same — EVIDENCE A: `end_session` while a shell was running yielded `background_tasks_changed{tasks:[]}` → `task_updated{status:"killed"}` → `task_notification{status:"stopped"}` | P | **A GUI must treat both "close stdin" and `end_session` as "kill the user's background shells".** `end_session` is not an escape hatch. If afleet wants a shell to outlive the session it must run it outside the CLI. At minimum, warn when the roster is non-empty at teardown; the notifications arrive after the request, so the GUI can also just report what was killed. |
| **A background completion starts an unprompted turn** | The completion notification is folded into the next turn; in the TUI there is usually a user watching and a visible task panel explaining where it came from | EVIDENCE B, with the host idle: `background_tasks_changed` → `task_updated` → `task_notification` → `hook UserPromptSubmit` → **a fresh `system/init`** → `system/status requesting` → `assistant [thinking]` → `assistant [text]` → `hook Stop` ×2 → `result/success (num_turns=1)`. No `user` frame, no host input | **D** (the trigger) / P (the turn itself) | The GUI receives a complete assistant turn it never asked for. It must (a) not treat the unexplained `system/init` as a protocol error or a lost message, (b) insert a synthetic timeline item built from the preceding `task_notification`, and (c) keep its "is the model busy" state machine driven by `session_state_changed` rather than by "did I send a prompt". This is the most surprising behaviour in the area for a host author. |
| Keeping a one-shot run alive for background work | n/a | `CLAUDE_CODE_BG_TASKS_REPORT_RUNNING=1` plus `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` | P | Only relevant if afleet ever runs a genuine one-shot `-p`. |
| Abandoned-vs-killed distinction | n/a | The sweep emits `task_notification` with `status: "stopped"` for tasks it merely stopped waiting on, identical to a real kill | D | A GUI cannot tell "we stopped watching this" from "we killed this" at the ceiling. The only differentiator is the debug log line, which is not on the wire. |
| Interrupt behaviour | Esc aborts the turn; `/tasks` remains the way to stop individual tasks | `interrupt` control request. **Without `perTaskStopAffordance` declared, an interrupt kills running background agents/workflows** (fail-closed, since the host would otherwise have no way to stop a runaway one). With it declared on an open-input session, the interrupt only aborts the turn (SPEC 45, `initialize` schema) | P | Restating §20.12 because it belongs to turn termination too: declare `perTaskStopAffordance: true` and render the per-task stop control. |
| `Stop` / `SubagentStop` hook payload | Carries `background_tasks: [{id, type, status, description, command?, agent_type?, server?, tool?, name?}]` using the **display** kind names (`shell`, `subagent`, …), strings truncated to 1000 chars, plus `session_crons` (§20.16.1) | Visible to the host only as hook frames with `--include-hook-events` | R | Interesting side channel: this is the **only** place the wire can carry a background shell's `command` and an `mcp_task`'s `server`/`tool`. A host that installs a trivial `Stop` hook and reads the hook's stdin payload gets a full roster snapshot per turn. A genuine, if roundabout, workaround for the §20.14 label gap. |
| Container restart | On resume after a container restart, a synthetic notification `The container running this session was restarted before backgro…` with `status: "stopped"` (§20.16.3) | Queue-only (§20.10 producer table), so invisible to the host | D | Low impact for a desktop GUI, which does not run in a restartable container. Listed for completeness. |

Rows: 8

---

## 20.17 Environment variables the host controls

Every one of these is set by afleet when spawning the child, so each is a free knob (§20.17).

| Variable | Effect | Class | Notes |
|---|---|---|---|
| `CLAUDE_CODE_ENABLE_TASKS` | `false` disables the persisted task list and re-enables `TodoWrite` | P | Lets a GUI choose which checklist surface it supports. |
| `CLAUDE_CODE_ENABLE_TODO_TOOLS` | `true` forces the task/todo tools on for models above the generation floor | P | **Recommended if afleet wants a working task panel** — otherwise the tools are off on current models (§20.2.1). |
| `CLAUDE_CODE_TASK_LIST_ID` | Overrides the task-list id and thus the `~/.claude/tasks/<id>` directory | P | Pins the directory a GUI watches. |
| `CLAUDE_CODE_TODO_REMINDER_MODE=off` | Suppresses both periodic reminders | P | User-facing "stop nagging" toggle. |
| `TASK_MAX_OUTPUT_LENGTH` | `TaskOutput` cap, default 32000, max 160000 | P | Only affects what the model sees. |
| `CLAUDE_SUBAGENT_BG_SHELL_MAX_MS` | Wall-clock cap on a subagent-owned background shell (default 1 h; top-level shells uncapped) | P | Raise it for long builds started by subagents. |
| `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP` | Stops the memory-pressure reaper killing idle top-level background shells | P | Set it if a GUI wants shells to outlive long idle periods. |
| `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` | Removes `run_in_background` from the `Bash` schema entirely and rewrites the `Monitor` prompt's advice; the `background_tasks` control request is refused with `Background tasks are disabled in this session.` (§20.13.2, SPEC 16 §16.3) | P | A clean way to offer a "no background work" mode. |
| `CLAUDE_AUTO_BACKGROUND_TASKS` | Arms the `Agent` auto-background timer (120000 ms) and the worker check-in interval | P | Changes how often subagents self-background. |
| `CLAUDE_CODE_BG_TASKS_REPORT_RUNNING` / `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` | Print-mode wind-down (see §20.16) | P | — |
| `CLAUDE_CODE_REMOTE` | Enables Bash `tool_progress`, but also clamps `Monitor` to non-persistent/30 min and enables `autocompact_state` | P | Not recommended just for progress ticks. |
| `CLAUDE_CODE_CONTAINER_ID` | Also enables Bash `tool_progress`; side effects are an `x-claude-remote-container-id` API header and a tempdir-owner-mismatch downgrade (SPEC 07 §1192, SPEC 01 §1022) | P | The cheaper of the two if elapsed-time ticks are wanted. Still gives no output text. |
| `CLAUDE_JOB_DIR` | Marks the process as a job worker; force-enables the task tools and the timeline writer | P | Heavy-handed; prefer `CLAUDE_CODE_ENABLE_TODO_TOOLS`. |

Rows: 13

---

## 16.12 / 16.13 / 16.16 / 16.18 — the Bash background story

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `run_in_background` parameter | Model-facing; removed from the schema when `Ll()` (background tasks disabled) (SPEC 16 §16.3) | Same; visible in `tool_use.input` | P | — |
| Five ways a shell becomes a background task | Explicit `run_in_background`; timeout auto-background; turn abort (non-`git` commands); **user `Ctrl+B`**; deliver-message (SPEC 16 §16.16) | The first three and the fifth happen identically. `Ctrl+B` maps to the `background_tasks` control request | P | Result flags `backgroundedByUser`, `backgroundedByTurnAbort`, `backgroundedToDeliverMessage`, `timedOutAfterMs` show up as differing background-notice text in the `tool_result` (SPEC 16 §16.18). |
| **`Ctrl+B` "run in background"** | Footer shows `(ctrl+b to run in background)`, hidden entirely when background tasks are disabled; the binding is `task:background` in the `Task` context, doubled to `ctrl+b ctrl+b` under tmux (SPEC 16 §16.16) | `background_tasks` control request: with `tool_use_id` backgrounds that call and returns `{backgrounded: bool}`; without it backgrounds every eligible task and returns `{}` (SPEC 45 §45.22.10, `cli.pretty.js:178247-178264`) | P | **Fully reachable.** afleet should render a "run in background" button on a long-running Bash tool row and wire it to `background_tasks` with that call's `tool_use_id`. |
| Knowing *when* to offer Ctrl+B | At the 2 s mark the tool emits an internal progress event `{kind:"background_hint", toolUseId}` so the footer can offer it (SPEC 16 §16.16, §16.12) | **Not converted by `TLe`** — the `progress` case handles only `repl_tool_call`, `bash_progress`, `powershell_progress`, `tool_heartbeat`, `agent_api_retry` (`cli.pretty.js:92964-92984`). `background_hint` is silently dropped | **D** | Workaround: the GUI runs its own 2 s timer per in-flight `Bash` tool call and offers the button then. It matches the CLI's own threshold (`OWn = 2000`). Cheap and exact. A weaker signal is `task_started` for the pre-registered `local_bash` row, which fires at the same 2 s mark and carries the `tool_use_id`. |
| Live output of a running foreground Bash | Progress polling reads the tail 4096 bytes every 1 s and yields last-5-lines / last-100-lines / estimated total lines / total bytes (SPEC 16 §16.13); rendered live under the tool row | `tool_progress` carries none of it (see the preamble); gated on `CLAUDE_CODE_REMOTE`/`CLAUDE_CODE_CONTAINER_ID` even for the elapsed-time field | **R (file)** | Tail `<tmp>/claude-<uid>/<slug>/<session>/tasks/<taskId>.output`. The `taskId` comes from `task_started` (pre-registration at 2 s) or from the background notice text. This is the single biggest rebuild in the area and the one that most determines whether the GUI feels equal to the terminal. |
| Background notice in the tool result | `Command running in background with ID: <id>. Output is being written to: <path>. You will be notified when it completes. To check interim output, use Read on that file path.` — with variants for user-backgrounded, deliver-message and timeout, plus the synchronous-subagent warning and the `backgroundCwdHint` (SPEC 16 §16.18) | Identical text in the `tool_result` | P | **This is where a GUI reliably learns the output-file path**, for every backgrounding path. Parse `ID: (\S+)\.` and `written to: (.+?)\.` — or better, match the `task_started` that carries the same `tool_use_id`. |
| Auto-background on timeout | The command is moved to the background rather than killed; `timedOutAfterMs` set; only for *simple* command lists whose first word is not `sleep`, and (for turn-abort) not matching `/git/i` (SPEC 16 §16.12) | Same; visible as differing notice text plus `task_started` | P | `CLAUDE_CODE_AUTO_BACKGROUND_TIMEOUT_MS` (floored at 2000 ms) shortens the foreground wait — another host knob. |
| Backgrounded `cd` | Model is told `Session cwd remains <cwd>; directory changes made by the backgrounded command do not apply…` (SPEC 16 §16.14) | Same text | P | — |
| Adoption across sessions | Background shells can survive the process; a later wake re-registers them with `isAdopted: true` and skips the exit terminator (SPEC 16 §16.16, §20.9.2) | Re-registration emits `task_started` again | P | A GUI tailing an adopted shell's output file must not wait for `[exited with code N]`; rely on `task_notification`. |
| Runaway-output kill | The disk writer latches off past 5 GB with an in-band marker; buffered output past 16 MiB of write failures is dropped and `lostOutput` latches (§20.9.1) | Same markers in the file | R | Render them as harness chrome. |
| `Monitor` / `TaskOutput` / `TaskStop` shell-facing behaviour | SPEC 16 §16.21 restates §20.11–20.13 from the shell's side | Same tool frames | P | No additional user-visible surface. |

Rows: 11

---

## Top gaps in this area

Ranked by how much they cost a GUI that wants terminal parity or better. Gaps 1, 3, 7 and 15 are
confirmed by the live probes in `/tmp/afleet-gap/EVIDENCE-background-subagent.md`.

1. **Live stdout of a background (or long foreground) shell.** TUI: the `/tasks` shell detail tails
   8192 bytes of the output file, and the inline tool row shows last-5-lines from 1 s progress polls
   (SPEC 16 §16.13, `cli.pretty.js:407757-407764`). Wire: nothing — `tool_progress` has no output
   field at all and is gated on `CLAUDE_CODE_REMOTE`/`CLAUDE_CODE_CONTAINER_ID` even for its elapsed
   time (SPEC 45 §45.14.8); EVIDENCE A saw no Bash `tool_progress` frame whatsoever. GUI workaround:
   tail `<realpath(os.tmpdir())>/claude-<uid>/<project-slug>/<session-uuid>/tasks/<taskId>.output`
   (observed live as `/private/tmp/claude-501/<slug>/<session>/tasks/<id>.output`), whose path also
   arrives verbatim in the Bash `tool_result` text and in `task_notification.output_file`.
   **Class R (file).** Done well, this beats the TUI.
2. **No "list background tasks" control request.** `background_tasks` is the Ctrl+B *action*, not a
   query (§45.22.10, verified live: it answers `{}`). The GUI must fold `task_started` +
   `task_updated` + `background_tasks_changed` into its own registry mirror and keep it correct across
   resume (which re-emits `task_started` for adopted rows). **Class R**, but it is the foundational
   piece: every other background affordance depends on it.
3. **The `<task-notification>` injection is invisible, and it starts an unprompted turn.** EVIDENCE B:
   with the host idle, a finishing background shell produced `background_tasks_changed`,
   `task_updated`, `task_notification`, then `hook UserPromptSubmit`, a fresh `system/init`, and a
   complete assistant turn — with **no `user` frame** for the injected message, despite
   `--replay-user-messages`. The queued notification is a meta `queued_command` attachment and the
   converter skips exactly that case (`cli.pretty.js:142595`). **Class D.** The GUI must synthesise
   the timeline item from `task_notification` and must not treat the unexplained `system/init` as a
   protocol error. (This corrects my own reading of SPEC 45 §45.9.3, which suggested a `user` frame
   with `origin: {kind:"task-notification"}` would appear.)
4. **`perTaskStopAffordance` must be declared in `initialize`, or every interrupt kills the user's
   background agents.** Absence fails closed by design. Declaring it also obliges the GUI to render a
   real per-task stop control wired to `stop_task`. **Class P** — free, but easy to miss and
   destructive if missed.
5. **`background_hint` never reaches the wire.** The TUI's `(ctrl+b to run in background)` footer is
   driven by an internal progress event that `TLe` drops (`cli.pretty.js:92964-92984`). **Class D**;
   workaround is a GUI-side 2 s timer per in-flight `Bash` call, matching `OWn = 2000`, or keying off
   the `task_started` emitted by the 2 s pre-registration.
6. **A background shell's `command` and `cwd` are not on the wire.** `task_started` gives
   `description`; `background_tasks_changed` gives `{task_id, task_type, description, ambient?}` and
   nothing else. The TUI's `/tasks` labels shells by their **command** (§20.14.1). **Class D** for
   `cwd`; **class R** for the command, by correlating `tool_use_id` back to the `Bash`
   `tool_use.input.command`. A `Stop` hook's `background_tasks` payload is a second, roundabout source
   that does carry `command` (§20.16.1).
7. **Ending the session kills every running background shell — including via `end_session`.** `Dl`
   at stream close, guarded by `Al({shuttingDown, remoteTransport})` (§20.16.2,
   `cli.pretty.js:174182-174197`, `176769`); EVIDENCE A confirms the `end_session` path produces
   `task_updated{status:"killed"}` and `task_notification{status:"stopped"}` for a live shell. With
   stdin held open, background work survives turn boundaries untouched (EVIDENCE B). **Class P** — but
   it must be designed for: there is no graceful-detach route, so warn the user when the roster is
   non-empty at teardown.
8. **`TaskOutput` suppresses the terminal `task_notification`.** A terminal read stamps `notified`
   (§20.11.4), so a GUI keying "task finished" solely off `task_notification` silently misses those
   tasks. **Class D**; workaround is to also treat a terminal `task_updated.patch.status` as
   completion.
9. **Parked agents are indistinguishable from finished ones.** `keepaliveReasons` is not on the wire,
   so the `/tasks` `Completed` section's membership rule (§20.14.1) cannot be reproduced exactly, and
   the GUI cannot know that a `completed` agent can still be resumed with `SendMessage` or stopped.
   **Class D**; approximation is to keep completed background agents in the roster and let `stop_task`
   fail if they are gone.
10. **The whole `/tasks` dialog is unreachable, and it is not in the command list at all.** Verified
    live: `initialize.commands` on 2.1.259 has 102 entries and contains none of `tasks`, `bashes`,
    `background`, `bg`, `subtask` — all `local-jsx`, all filtered by `filterCommandsForHeadless`
    (SPEC 28 §22). **Class X** for the dialog, **R** for its content and **P** for its one destructive
    action. Rebuilding it is ~15 rows of list/section/label logic (§20.14.1–20.14.3).
11. **No `startTime` on the wire.** Every row's age must be inferred from frame arrival, which is wrong
    after a resume re-registers adopted tasks (§20.8.6). The only leak is `task_progress.usage
    .duration_ms`, and only for subagents and workflows. **Class D**; low severity, visible as wrong
    "running for Xm" labels after `--resume`.
12. **The persisted task list is invisible to the protocol.** No frame, no control request, no change
    event (§20.2.7's `taskList.updated` is in-process only). **Class R (disk)**: read and `fs.watch`
    `~/.claude/tasks/<sessionId>/*.json`, pin it with `CLAUDE_CODE_TASK_LIST_ID`. Also note the model
    gate: on current models the task tools are **off** unless `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`
    (§20.2.1), so the panel may never populate at all.
13. **The task tools are absorbed silently in the TUI transcript but are ordinary tool calls on the
    wire** (§20.2.1). Without the same suppression the GUI transcript is noticeably noisier than the
    terminal's. **Class R**, cheap: hide `TaskCreate`/`TaskGet`/`TaskUpdate`/`TaskList`/`TodoWrite`
    rows unless `tool_result.is_error`.
14. **Foregrounding a task (`f` / `enter` in `/tasks`) has no protocol surface.** **Class X.** The GUI's
    natural equivalent — focusing its own subagent pane, which it can populate from the `.output`
    symlink into the subagent JSONL transcript — is arguably better, but it is a different mechanism,
    not parity.
15. **Queue-only notifications are wholly invisible: every `Monitor` event, and the stuck-on-a-prompt
    watchdog.** A `<task-notification>` reaches the host only if its producer also calls `hs()`.
    `JM` (monitor events, §20.10.6) and `tWn` (the 45 s interactive-prompt stall watchdog,
    `cli.pretty.js:127885-127916`) call `Ra(...)` only, so with the injected message dropped (gap 6)
    the host sees nothing — while the model reacts to events the user was never shown. **Class D.**
    Workarounds: a command monitor is a `local_bash` task, so tail its output file and apply the same
    200 ms batching (§20.13.6); reimplement the stall regexes (`Szo`, SPEC 16 §16.16) against the
    tailed file, which yields a *better* affordance than the TUI's because the GUI can offer an inline
    stop button. Severity is currently limited by `tengu_amber_sentinel` defaulting `Monitor` off.
16. **`Monitor` rows are indistinguishable from ordinary background shells.** `shell_kind: "monitor"`
    exists in the internal metadata builder but not in the emitted `background_tasks_changed` payload
    (`cli.pretty.js:449055-449058`), and `task_started` has no equivalent. **Class D**; workaround is
    `tool_use_id` correlation to the `Monitor` tool call. Low impact while `tengu_amber_sentinel`
    defaults to false.

    ---

## Unverified

Everything below is inferred from code or schema reading rather than from an observed frame. All
other rows trace to a SPEC section or a quoted `cli.pretty.js` line.

* **Corrected, not unverified: the `<task-notification>` user frame.** I originally inferred from
  SPEC 45 §45.9.3 that it would arrive as a `user` frame with `origin: {kind:"task-notification"}`.
  EVIDENCE B disproves that — no such frame is emitted. The rows and gap 6 have been rewritten to
  match the evidence. Recorded here because the inference was plausible enough that a reader may make
  it too.
* **Whether `task_progress` from the subagent query loop is truly ungated.** EVIDENCE A confirms the
  tracker producer fires (a frame with `last_tool_name` and no `summary`), but that probe ran with
  `agentProgressSummaries: true`, so it cannot separate the two producers. The call site at
  `cli.pretty.js:100991` has no visible gate, unlike the summariser at `:127672` which checks `Ohe()`;
  I did not trace whether its enclosing block is conditional on `forwardSubagentText`. Untested: what
  a longer subagent run emits, and whether a summariser frame (with `summary`) ever appears.
* **Non-terminal `task_notification` frames.** I assert that only terminal transitions emit
  `task_notification` (from `HN`'s one-shot claim, §20.8.7). Both probes only exercised terminal
  cases, so I have not observed the harness attempting a non-terminal one.
* **The per-kind `/tasks` detail dialogs.** Chapter 20 §20.14.2 says `enter` opens "a per-kind detail
  dialog" without specifying their contents. I confirmed only the shell case (`X8` reading 8192 bytes
  of the output file at `cli.pretty.js:407757-407764`). The agent, workflow, MCP-task and cloud-session
  detail views are unspecified in my sources, so my "class R, rebuildable" claim for them is an
  inference from the fact that their underlying data is on the wire.
* **Exact `CLAUDE_CODE_CONTAINER_ID` blast radius.** I verified it enables Bash `tool_progress`
  (SPEC 45 §45.14.8), adds the `x-claude-remote-container-id` header (SPEC 07 §1192) and affects a
  tempdir-owner check (SPEC 01 §1022). I did not audit every read of the variable, so recommending it
  as "the milder of the two" is a judgement, not an exhaustive finding.
* **Whether a `Stop` hook can practically be used as a background-task roster source** (§20.16.1). The
  payload demonstrably carries `background_tasks` with `command` and display kind names, and hook
  frames reach the host with `--include-hook-events` (EVIDENCE A shows `hook Stop` ×2 arriving). I did
  not check whether the hook's *stdin* payload is echoed in the `hook_started` frame the host
  receives, or only the hook's stdout — which decides whether this workaround is real. Worth a
  five-minute experiment before relying on it.
* **`~/.claude/todos/`** has no writer in 2.1.257 (§20.5.4 and the chapter's own Open questions), so my
  "TodoWrite state is only reconstructable from the wire" claim depends on that remaining true.
