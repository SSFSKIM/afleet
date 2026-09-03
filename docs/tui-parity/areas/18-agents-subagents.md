<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# 18 — Agent tool and subagents: TUI-vs-headless inventory

Chapter: `SPEC/18-agent-tool-and-subagents.md`. Wire side cross-checked against
`SPEC/45-headless-and-sdk-protocol.md`, `SPEC/35-session-persistence.md` §35.11,
`SPEC/41-tui-rendering.md`, and against two live captures on the installed 2.1.259
(`/tmp/afleet-gap/turns.ndjson.log`, `/tmp/afleet-gap/EVIDENCE-background-subagent.md`).

**Headline correction to SPEC 45.9.2.** The chapter-45 sentence "subagent assistant messages
are dropped unless `--forward-subagent-text`" (SPEC 45 §45.9.2, checklist line 4559) describes
only the `assistant`-typed branch of filter `Cu` [`cli.pretty.js:172483-172486`]. Subagent
messages do not travel that branch. The `Agent` tool re-publishes every subagent message as an
internal **`progress` message of `data.type === "agent_progress"`**
[`cli.pretty.js:101876-101883`], `Cu` forwards `progress` unconditionally
[`cli.pretty.js:172487-172490`], and the converter `ufn` turns each one back into a wire
`assistant` / `user` frame with `parent_tool_use_id` set plus `subagent_type` and
`task_description` [`cli.pretty.js:92931-92947`]. The gate is inside the tool, not the filter:

```js
for (let el of cm([_a])) {
  let Ys = el.message.content[0];
  if (!Tl && Ys.type !== "tool_use" && Ys.type !== "tool_result")
    continue;                                   // Tl = options.forwardSubagentText
  B({ type: "progress", toolUseID: `agent_${F.message.id}`,
      data: { message: el, type: "agent_progress", agentId, agentType, … } });
}
```
[`cli.pretty.js:101878-101883`]

So: **`tool_use` and `tool_result` blocks of a depth-1 subagent reach stdout even without the
flag; `--forward-subagent-text` additionally forwards `text` and `thinking` blocks and is what
unlocks nested (depth ≥ 2) forwarding.** Confirmed live on 2.1.259 in
`EVIDENCE-background-subagent.md` Probe A. Treat 45.9.2 as describing one of two paths.

---

## 18.1–18.2 The `Agent` tool object: identity, naming, colour

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Tool name / alias | Header row says `Agent`, alias `Task` accepted (§18.2) | `assistant` frame `tool_use.name` is `Agent` or `Task` | P | Accept both names when matching. |
| Header label | `userFacingName` `g6t`: `Fetch` for the web-fetch built-in, the `subagent_type` when it is not `general-purpose`, else `Agent` (§18.2, [`cli.pretty.js:101507-101514`]) | `tool_use.input.subagent_type` + `system/task_started.subagent_type` | R | Pure client-side mapping. The web-fetch case needs the normaliser `n$`: any type normalising to `webfetch` when no other active agent claims that name (§18.7.7). |
| Header colour | `pKe`/`zre` map the definition's `color` frontmatter to the eight `*_FOR_SUBAGENTS_ONLY` palette entries; `undefined` for `general-purpose` and web-fetch (§18.2, §18.6) | Nothing. `initialize.agents` is exactly `{name, description, model}` [`cli.pretty.js:178998`]; `task_started` carries `subagent_type` only | **D** | Workaround: parse `color:` from `~/.claude/agents/*.md` and `<project>/.claude/agents/*.md` frontmatter yourself, or read the run's sidecar `<sessionId>/subagents/agent-<agentId>.meta.json`, which records `color` (§35.11.1) — but only after the spawn. |
| Activity description | `getActivityDescription` = `input.description` with whitespace collapsed, else `Running task` (§18.2) | `tool_use.input.description`, and `task_started.description` already collapsed | P | |
| Parallel `Agent` calls in one message | `isConcurrencySafe()` — several agents run at once and render as one grouped block (§18.2) | Several `tool_use` blocks share a `message.id` across consecutive `assistant` frames (§45.12.1) | P | Group by `message.id` to reproduce the `Running N agents…` header. |
| Auto-mode spawn permission | `checkPermissions` returns passthrough `Agent tool requires permission to spawn subagents.` unless the call is a pure web-fetch dispatch (§18.2) | `can_use_tool` control request for the `Agent` tool | P | |
| Result size cap | 100 000 chars; overflow spills to `<sessionId>/tool-results/` (§18.24.3) | Same file on disk; the wire `tool_result` is the truncated form | R | Read the spill file for the untruncated report. |

---

## 18.3–18.4 Tool prompt and input schema

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Which parameters the model may pass | Default interactive schema is five properties: `description`, `prompt`, `subagent_type`, `model`, `isolation` (§18.4) | Same schema, except `run_in_background` **survives** headless because the fork feature is off (`tV()` → `disabled` when `Oe()`, §18.20.1) | P | Read the emitted `tool_use.input`; do not assume the interactive five. |
| `run_in_background` default | In an interactive session with fork on, every subagent is backgrounded (`Ot` in §18.18 step 9) | Headless: `nt` still defaults to background unless the model passes `run_in_background: false` — it did in both live probes, producing `is_backgrounded: false` | P | Read `task_started.is_backgrounded`; never infer it from the flags. |
| `name` / `team_name` / `mode` | Stripped from the emitted JSON schema unless `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` (§18.4) | Same strip | P | |
| `cwd` | Never exposed to the model in any mode (§18.4) | Same | P | |
| Fork offered to the model | On by default in interactive sessions (§18.20.1) | **Off** headless unless `CLAUDE_CODE_FORK_SUBAGENT=1` is in the child env | R | Launch-time env var; a GUI wanting TUI parity on fork must set it. See §18.20 below for the consequences. |

---

## 18.5 The tool result the parent receives

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `completed` report + `agentId:`/`<usage>` footer | Rendered as the report body plus `Done (N tool uses · X tokens · Ys)` [`cli.pretty.js:769612`] | `user` frame, `message.content[0].tool_result`, and the **full Output object** on `tool_use_result` | P | Live-verified fields: `status, prompt, agentId, agentType, content, resolvedModel, totalDurationMs, totalTokens, totalToolUseCount, usage, toolStats{readCount,searchCount,bashCount,editFileCount,linesAdded,linesRemoved,otherToolCount}, harnessNoteCount, harnessTailCount, harnessSectionHash`. Everything the `Done (…)` line needs is here. |
| `Explore` / `Plan` bare results | Same two agents get no `agentId`/usage footer in the model-facing text (§18.5) | Footer absent from `tool_result` text, but `tool_use_result` still carries the numbers | P | Render the stats from `tool_use_result`, not by parsing the text. |
| `async_launched` | `Backgrounded agent (↓ to manage, ctrl+o to expand)`; for web-fetch, `Fetching in background` [`cli.pretty.js:769603`] | `tool_use_result.status === "async_launched"` with `agentId`, `outputFile`, `canReadOutputFile` | P | The `↓ to manage` affordance is the TUI task manager — see §18.23. |
| `remote_launched` | `Cloud agent launched · <taskId> · <sessionUrl>` [`cli.pretty.js:769600`] | `tool_use_result.status === "remote_launched"` with `taskId`, `sessionUrl`, `outputFile` | P | A GUI can make `sessionUrl` clickable; the TUI cannot. |
| `teammate_spawned` | Teams-only row `@name` (§18.5, [`cli.pretty.js:769748`]) | Same `tool_use_result.status` | P | Teams are ch. 39; only reachable with the experimental env flag. |
| Mid-run model swap chain `sonnetA → opusB` | Read from `agent_progress.modelsUsed` while running, or `toolUseResult.modelsUsed` at the end (`a1`/`i1`, [`cli.pretty.js:769646-769660`]) | `modelsUsed` is **not** copied onto the wire `assistant` frame by `ufn`; it appears only on the final `tool_use_result`, and only when more than one model was used | R (partial) / **D** while running | Live-verified: a single-model run returns `resolvedModel` and no `modelsUsed`. The GUI can show the swap after the fact but not mid-flight. |
| Hand-back provenance frame (§18.5.1) | Report indented two spaces under a `[Subagent hand-back]` header when `CLAUDE_CODE_HANDBACK_PROVENANCE` / gate `tengu_melodic_wolf` | Same text in the `tool_result`; `harnessNoteCount`/`harnessTailCount`/`harnessSectionHash` on `tool_use_result` (live-verified, present even with the gate off, as zeros) | P | These three counts let a GUI style harness notes differently from model text — a place to **exceed** the TUI, which only indents. |

---

## 18.6–18.11 Agent definitions: discovery, frontmatter, precedence

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Agent list for a picker | Definitions merged from six sources, precedence policy > flag > project (deeper wins) > user > plugin > built-in, sorted by `agentType` (§18.11) | `initialize` control_response `agents` and `system/init.agents` | P (names) / **D** (everything else) | `initialize.agents[]` = `{name, description, model?}` only [`cli.pretty.js:178998`]; live-verified across 11 entries. `system/init.agents` is a bare **array of names**. No `color`, no `tools`, no `source`, no `whenToUseLean`, no file path. |
| Custom agent frontmatter with UI effect: `color` | Tints the tool-call header (§18.6) | Not on the wire | **D** | Parse the `.md` files (§18.8.1 search order) or the `.meta.json` sidecar. |
| Custom agent frontmatter: `model`, `description` | Shown in the agents listing to the model | On the wire in `initialize.agents` | P | |
| Custom agent frontmatter: `tools`, `disallowedTools`, `permissionMode`, `maxTurns`, `background`, `isolation`, `memory`, `skills`, `effort` | Affect behaviour; the TUI never displays them either | Not on the wire | R | Both surfaces are equally blind; a GUI that parses the frontmatter can **exceed** the TUI by showing "this agent runs with X tools in a worktree". |
| Frontmatter parse errors | Warning strings from `Ryr` (§18.8.2), e.g. `Agent file <path> has invalid permissionMode '<v>'…` | Debug-log only; not an `informational` frame | **D** | Minor. A GUI that lints the files itself gives better feedback than the TUI. |
| Duplicate/shadowed agent names | `[agents] Duplicate agent name '<type>' (<source>): …` (§18.11) | Debug-log only | **D** | Minor; reconstructable by scanning the same directories. |
| `--agent <name>` main-thread agent | Replaces (or appends to, when `appendSystemPrompt: true`) the session system prompt (§18.10) | Same flag; afleet already passes it | P | `Warning: agent "<name>" not found. Available agents: …` goes to the log, not the wire — validate the name against `initialize.agents` before launching. |
| `--agents <json>` | Injects `flagSettings` definitions (§18.10) | Same flag, and `initialize.agents` (stdin) | P | Note §18.10: in safe mode the flag is ignored. |
| `agents` capability disabled by policy | Only built-ins load (§18.11) | `initialize.agents` shrinks accordingly | P | |

---

## 18.12 The "Available agent types" system reminder

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `Available agent types for the Agent tool:` / `New agent types are now available…` delta reminder | An `isMeta` user message; the TUI does not render it to the user (§18.12) | Reaches the wire as a `user` frame with `isSynthetic: true` (from `isMeta`, §45.12.2) | P | Not user-visible in either surface. A GUI should build its picker from `initialize.agents`, not from this reminder — but hiding `isSynthetic` user frames is required to avoid leaking it into the timeline. |
| The tool-summary suffix `(Tools: …)` | Computed by `$Ao` from `tools`/`disallowedTools` (§18.12) | Only inside that meta message; not in `initialize.agents` | R | Parse it out of the reminder if you want per-agent tool lists without reading the `.md` files. |

---

## 18.13–18.14 Resolution and spawn refusals

Every refusal below is thrown as `AgentTypeError` / `AgentPreconditionError` /
`RemoteAgentPreconditionError` / `WorktreeIsolationError` and rendered to the model without a
stack trace (§18.2).

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `Agent type '<t>' not found. Available agents: …` | Error `tool_result`, red row | Identical `user` frame with `is_error` on the `tool_result` block | P | |
| Ambiguity message `Agent type '<t>' is ambiguous — matches …` (§18.13.1 step 6) | idem | idem | P | |
| Denied by an `Agent(<t>)` permission rule (§18.13.1 step 2) | idem, naming the rule source | idem | P | The rule source string is in the message text only; there is no structured field. |
| `…every tool it may use is denied by the current permission settings` (§18.13) | idem | idem | P | |
| Depth cap — `Subagent nesting limit reached (depth d of max)…` (§18.14 #1, default 3 via `tengu_hazel_trellis`) | idem | idem | P | Also silently removes the `Agent` tool from a subagent at `agentDepth >= db()` (§18.15) — the GUI cannot see that removal, only its effect. |
| Concurrency cap — `Concurrent subagent limit reached. You can run N subagents at once.` (§18.14 #7, default 20) | idem | idem | P | |
| Budget exhausted (§18.14 #6) | idem | idem | P | Also surfaces as `result` subtype `error_max_budget_usd` (SPEC 45 §45.13). |
| `requiredMcpServers` unmet, after a 30 s wait (§18.14 #8) | idem, and the message tells the user to run `/mcp` | idem | P | The `/mcp` advice is dead text headless; render your own MCP panel. |
| MCP servers blocked for this agent — `<type> agent MCP server(s) blocked by <reason>: <names>` (§18.15) | Surfaced **to the UI, not the model** [`cli.pretty.js:98383`, `cli.pretty.js:101781`] | Not on the wire as a distinct frame | **D** | A silent degradation headless: the agent runs with fewer tools and nobody is told. |
| Zero-tool refusal (§18.15) | Error `tool_result` naming `invalidTools` / `unavailableTools` | idem | P | |
| `agent.spawn` plugin hook deny — `Subagent spawn denied by a plugin: <reason>` (§18.14 #9) | idem | idem | P | |

---

## 18.15–18.17 Tool set, permission mode, model routing

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Subagent tool set (17 tools in `XNe` always removed; background agents limited to the 26 in `K7e`) (§18.15) | Invisible; only observable when a call fails | `system/init.tools` describes the **main thread**, not any subagent | **D** | A GUI cannot show "this background agent has no `Skill`/`REPL`". Derivable only by reimplementing `dAo`/`VE` against the definition. |
| Permission mode a subagent runs under (§18.16 ladder `tW`) | Not shown; the border tint changes when *viewing* a subagent transcript (§41.16.4) | Recorded in the `.meta.json` sidecar (`permissionMode`, `spawnMode`) after spawn | R | Read the sidecar; nothing on the wire. |
| Permission prompt raised *inside* a subagent | Prompt renders in the Agent row context, tinted with the subagent's `*_FOR_SUBAGENTS_ONLY` colour (§41.16.4) | `can_use_tool` control request carries **`agent_id`** and `tool_use_id` [`cli.pretty.js:172498`, SPEC 45 §45.19] but no agent type, name or colour | R | Join `agent_id` against `system/task_started.task_id` (they are the same id — see §18.23) to recover `subagent_type` and `description`. Without that join the GUI can only say "a subagent is asking". |
| Auto-denied tool inside a subagent | Denial row | `system/permission_denied` carries `agent_id` (SPEC 45 §45.14, [`cli.pretty.js:172646`]) | P | Same join. |
| Fork permission mode `bubble` | Prompts bubble to the parent session (§18.16 #3) | Same `can_use_tool` with the fork's `agent_id` | P | |
| Background agent with no dialog channel auto-denies (`shouldAvoidPermissionPrompts`, §18.16 #3) | N/A interactively | With `--permission-prompt-tool stdio --permission-prompts host` there **is** a channel, so background subagents prompt normally | P | A GUI **exceeds** bare `-p`, which silently denies. |
| Model actually used by the subagent | Chain rendered on the row when it changed (§18.5 above) | `task_started` has no model; `tool_use_result.resolvedModel` arrives only at the end | R / **D** while running | `system/task_started` would be the natural carrier and does not have it. Sidecar `.meta.json` has `model` and is written at spawn — poll it if you need the model live. |
| `Explore` capped at `opus` on first-party auth (§18.17.1) | Invisible | Invisible | — | No user-visible surface either side. |

---

## 18.18–18.19 The running subagent: what the TUI draws vs what the wire carries

This is the section the product question turns on. The TUI's whole rendering is computed
client-side from the internal `agent_progress` messages — the same objects that `ufn` converts
into wire frames.

### What the TUI draws

| Element | Source | Line |
|---|---|---|
| Group header `Running N agents…` / `N agents finished` / `N background agents launched (↓ manage)` | one `Agent` tool_use per row | [`cli.pretty.js:769744-769748`] |
| Per-agent row `AgentType (description) · N tool uses · 41.2k tokens` | `toolUseCount` counted from progress messages whose assistant content has a `tool_use`; `tokens` = cache_creation + cache_read + input + output of the **last** subagent assistant message | [`cli.pretty.js:769723-769730`], [`cli.pretty.js:762233-762285`] |
| Second line `⌿ <last tool activity>` / `Initializing…` / `Running in the background` / `Done` | `lastToolInfo` from the last tool_use block | [`cli.pretty.js:762237-762242`] |
| Nested tool calls, condensed, last `dU` of them | each `agent_progress` assistant/user message re-rendered with `style: "condensed"` | [`cli.pretty.js:769699-769703`] |
| Roll-up rows `Searched N files · Read N files` | `SBt` folds runs of search/read calls | [`cli.pretty.js:769696-769698`] |
| Fold footer `+N tool uses (ctrl+o to expand)` | `Uh({count, unit:"tool use", expandable:true})` | [`cli.pretty.js:769704`] |
| Height-budget collapse `In progress… · N tool uses · X tokens · (ctrl+o to expand)` | when `rows < (inProgressToolCallCount * r1 + n1)` | [`cli.pretty.js:769680`] |
| Completion `Done (7 tool uses · 41.2k tokens · 3m 12s)` | the `completed` Output object | [`cli.pretty.js:769612`] |
| Model chain `modelA → modelB` | `agent_progress.modelsUsed` | [`cli.pretty.js:769646-769660`] |
| `(ctrl+b to background)` hint after 2 000 ms | `emitToolProgress({kind:"background_hint"})` → TUI-only renderer | [`cli.pretty.js:101886`], [`cli.pretty.js:428610-428614`] |

### What the wire carries (live-verified, 2.1.259, `--forward-subagent-text`)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Subagent's own `tool_use` blocks | Nested condensed rows | `assistant` frame, `parent_tool_use_id` = the `Agent` tool_use id, `subagent_type`, `task_description` [`cli.pretty.js:92937-92941`] | P | Emitted **with or without** `--forward-subagent-text` [`cli.pretty.js:101878-101883`]. This contradicts the 45.9.2 summary; see the headline note. |
| Subagent's own `tool_result` blocks | idem | `user` frame, same `parent_tool_use_id`, plus `tool_use_result` (the tool's full Output object) [`cli.pretty.js:92943-92945`] | P | Also unconditional. |
| Subagent's `text` blocks (its running narration and final report) | Only in the expanded transcript | `assistant` frame with `parent_tool_use_id` — **only** with `--forward-subagent-text` | P | afleet passes the flag. |
| Subagent's `thinking` blocks | Only in the expanded transcript | Same gate; `w1e` redacts before emission [`cli.pretty.js:92938`, `cli.pretty.js:192392`] | P | |
| Subagent's initial prompt | Shown at the top of the expanded fold | `user` frame with `parent_tool_use_id` carrying the prompt text (live-verified) — and `task_started.prompt` | P | Two independent copies. |
| Spawn announcement | Row appears | `system/task_started {task_id, tool_use_id, description, subagent_type, is_backgrounded, spawn_depth, task_type:"local_agent", prompt}` [`cli.pretty.js:96786`] | P | `task_id` **is** the `agentId` (§18.23.1); live value `a69fb6984c5234e4f` matches the `^a[0-9a-f]{16}$` id shape (§18.1). `owned_by_subagent` is only ever set for `local_bash` tasks [`cli.pretty.js:96768-96772`], not nested agents. |
| Live activity line, tool count, token count, elapsed | `⌿ Running ls …` + `· N tool uses · X tokens` | `system/task_progress {task_id, tool_use_id, description, subagent_type, usage:{total_tokens, tool_uses, duration_ms}, last_tool_name}` [`cli.pretty.js:98861`, `cli.pretty.js:100991`] | P | Fired on **every subagent assistant message containing a `tool_use`** — so it is tool-paced, not time-paced. Between tool calls there is no heartbeat: the GUI must tick elapsed locally from `task_started`. |
| Model-written progress summary ("Reading runAgent.ts") | Feeds the task row (§18.19.1) | Same `task_progress` frame with `summary` set and `description` replaced by it [`cli.pretty.js:127672`] | P (opt-in) | Requires `agentProgressSummaries: true` in `initialize` → `TOn(true)` [`cli.pretty.js:177252`] → `enableSummarization: Ohe()` [`cli.pretty.js:101884`]. It forks a 1-turn summariser every **30 s** and skips when the transcript has < 3 messages or is unchanged (§18.19.1) — which is why the live probes (3 s and 12 s) produced none. Not a bug. |
| Status transitions | Row colour/spinner | `system/task_updated {task_id, patch:{status, end_time}}` [`cli.pretty.js:96746`] | P | |
| Completion | `Done (…)` | `system/task_notification {task_id, tool_use_id, status, output_file, summary, usage}` [`cli.pretty.js:669217`] **and** the `user`/`tool_result` frame with the full Output object | P | `summary` on the notification is the subagent's final report text. |
| API retry inside a subagent | Retry indicator under the row (`agent_api_retry`) | `tool_progress` frame with `tool_name: "Agent"`, `subagent_type`, and `subagent_retry {agent_id, attempt, max_retries, retry_delay_ms, error_status, error_category}`; a resolved retry sends the same frame **without** `subagent_retry` [`cli.pretty.js:92976`] | P | Not gated on `CLAUDE_CODE_REMOTE` — SPEC 45 §45.14.8 confirms heartbeats and subagent-retry frames bypass that gate. |
| Bash progress inside a subagent | Live bash output under the nested row | Forwarded to the parent as `bash_progress` [`cli.pretty.js:101862`] but `TLe` drops it unless `CLAUDE_CODE_REMOTE`/`CLAUDE_CODE_CONTAINER_ID` [`cli.pretty.js:92968-92972`] | **D** | Same gap as top-level Bash; the workaround is the task output file. |
| `(ctrl+b to background)` on a synchronous agent after 2 s | TUI hint + `Task` keybinding context (`ctrl+b`, `ctrl+x ctrl+b`) | No wire frame, no control request | **D** | There is no "background this running task" control in the 66-request catalogue. A synchronous agent the model launched with `run_in_background: false` cannot be backgrounded by the user. |
| `ctrl+o` transcript fold / `+N tool uses (ctrl+o to expand)` | Client-side fold of the same progress stream | All the folded content is on the wire | R | The GUI must implement its own expand/collapse; it has strictly more data than the TUI fold shows. |
| Roll-up `Searched N · Read N` rows | `SBt`, client-side | Rebuildable from the forwarded `tool_use` blocks | R | |
| Stall watchdog | `Agent stalled: no progress for Ns (stream watchdog did not recover)` (§18.19.1) | Arrives as the agent's failure report in `task_notification.summary` / the error `tool_result` | P | |
| `max_turns` stop | Report prefixed `NOTE: this agent stopped at its N-turn limit…` (§18.24 #4) | Same text in the report; `task_notification.summary` is `Agent "<d>" stopped at its N-turn limit (partial result; SendMessage to task-id to continue)` (§18.23.2) | P | |

### Nested subagents (depth ≥ 2)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Max depth | 3 by default (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` / `tengu_hazel_trellis`); the `Agent` tool disappears from the tool set at the cap (§18.14, §18.15) | Same | P | Depth 0 = main thread. |
| Depth-2 spawn announcement | Nested rows inside the depth-1 fold | `system/task_started` with `spawn_depth: 2`. `hu()` enqueues onto the **host-level** outbound queue [`cli.pretty.js:669202`], drained by `runHeadlessStreaming` regardless of nesting — so nested task frames do reach stdout | P (mechanism verified in code; a live depth-2 run was not captured) | The frame does **not** carry `parentAgentId`. Join instead on `tool_use_id`: the nested `Agent` tool_use block appears in a depth-1 `assistant` frame whose `parent_tool_use_id` names the depth-1 agent. |
| Depth-2 subagent's own tool calls, results, text | Nested condensed rows | Re-emitted by the depth-1 tool only when `forwardSubagentText` is true, preserving the **inner** `parentToolUseID` [`cli.pretty.js:101873-101877`] | P with the flag, **D** without | This is the one place where `--forward-subagent-text` changes structural visibility rather than just text. Without it, a depth-2 agent is a black box: you see it start and stop and nothing in between. |
| Depth-2 completion | Rolls up into the depth-1 report | `task_notification` for the nested task id, plus a nested `tool_use_result` inside a depth-1 `user` frame | P | `toolStats` of nested agents are folded into the parent's `toolStats` (§18.24). |
| Rebuilding the tree | Implicit in the render tree | Two-step join: frame `parent_tool_use_id` → the `tool_use` block with that id → the frame that carried it → its `parent_tool_use_id` | R | Fully reconstructable with the flag on. Document this join in the GUI; it is not stated anywhere in SPEC 45. |

---

## 18.20 Fork subagents (`subagent_type: "fork"`)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Fork availability | On by default interactively; `qRn` adds per-call checks (§18.20.1) | `kyr()` returns `disabled` when `Oe()` (non-interactive) — **forks do not exist headless** unless `CLAUDE_CODE_FORK_SUBAGENT=1` | R | Set the env var on the child process for parity. Note the knock-on: with fork on, `run_in_background` is stripped from the schema and *every* subagent is backgrounded (§18.18 step 9) — a large behavioural change, not just an extra agent type. |
| Fork always background | `async_launched` result and a `<task-notification>` later (§18.20.4) | Same frames as any background agent | P | |
| Fork inherits the parent transcript | Shown as a normal agent row | The fork's inherited prefix is **not** re-emitted; only post-fork messages are forwarded | P | Correct behaviour — the parent already streamed the prefix. |
| `fork-context-ref` transcript record (§18.20.3) | Invisible | On disk in `agent-<id>.jsonl`; `Ssr` re-attaches the parent prefix on resume (§18.25.3) | R | A GUI reading a fork's transcript file must follow the ref itself or it will see a truncated history. |
| Fork refusals — `Fork cannot use isolation: "remote"…`, `Fork is not available inside a forked worker.` (§18.20.1) | Error `tool_result` | Same | P | |
| `/fork`, `/subtask` user commands | `local-jsx`, gated by the `fleetFork` feature group (§18.30.2); prints `⏵ forked <name> (<last 4 of agentId>)` | **No** `local-jsx` command works headless (SPEC 28 §22, 45.29.1) | **X** | Equivalent: send a normal turn instructing the model to call `Agent({subagent_type:"fork", …})`, which needs `CLAUDE_CODE_FORK_SUBAGENT=1`. |

---

## 18.21 `isolation: "worktree"`

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Worktree created | Log line `Created agent worktree at: <path> on branch: <branch>` / `Resuming existing agent worktree at: <path>` (§18.21) | Debug log only; no wire frame at creation time | **D** | The GUI learns the path only at completion (`tool_use_result.worktreePath/worktreeBranch`) or from the `.meta.json` sidecar (`worktreePath`, `worktreeBranch`, `spawnedWithWorktree`), which is written at spawn (§35.11.1). Poll the sidecar for a live indicator. |
| Auto-cleanup when HEAD is unchanged | `Agent worktree kept at: <path>` / silent removal; `worktreeCleanlyRemoved: true` written to the sidecar (§18.21) | `tool_use_result` simply has no `worktreePath` when it was removed | P | Absence is the signal. There is no cleanup prompt or confirmation dialog in either surface — cleanup is automatic and unattended. |
| Hook-based worktrees kept | `Hook-based agent worktree kept at: <path>` | Log only | **D** | Minor. |
| Containment refusals (`context_lost`, `worktree_gone`, `shared_checkout`, `command_redirect`) (§18.21) | Error `tool_result` inside the subagent | Same, forwarded as a subagent `user`/`tool_result` frame | P | Visible headless precisely because subagent tool_results are always forwarded. |
| Edit guard `This agent is isolated in the worktree <path>. Edit the worktree copy…` | idem | idem | P | |
| Non-git worktree isolation | Requires `WorktreeCreate`/`WorktreeRemove` hooks; else `WorktreeIsolationError` (§18.14 #10) | Same; hook events are visible with `--include-hook-events` | P | |

---

## 18.22 `isolation: "remote"`

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Availability | `Rce()` requires first-party provider, claude.ai OAuth, a prior remote session, a remote environment, and gate `tengu_neapolitan` (default **off**) (§18.22) | Identical gates | P | Effectively unavailable in most sessions; do not build UI on it. |
| Eligibility failure messages (`Please run /login…`, `Cloud agents require a GitHub remote…`) (§18.22) | Error `tool_result` | Same | P | The `/login` advice is dead text headless. |
| Launch result | `Cloud agent launched · taskId · sessionUrl` | `tool_use_result.status === "remote_launched"` | P | |
| Fallbacks (`isolation:'remote' is unavailable … falling back to isolation:'worktree'`) (§18.18 step 8) | Log only | Log only | **D** | The agent silently runs somewhere other than requested. |
| Completion | `task-notification` with `taskType: "remote_agent"`, summary `Remote task "<d>" completed successfully\|failed\|is blocked\|was stopped` | Same `system/task_notification` | P | |
| Remote metadata | `<sessionId>/remote-agents/remote-agent-<taskId>.meta.json` (§35.11.2) | Same on disk | R | |

---

## 18.23 Background agents, notifications, parking, killing

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Task registry row (`LocalAgentTask`, §18.23.1) | `/tasks` panel, `↓ to manage`, per-row spinner | `system/task_started` + `task_updated` + `background_tasks_changed`; snapshot via the `background_tasks` control request | P | The registry record has far more than the frames expose (`ownerAgentId`, `parentAgentId`, `keepaliveReasons`, `isObserver`, `forkedSkillName`, `userStopCount`, `killedBy`, `quietlyParked`). Only `status`, `description`, `subagent_type`, `spawn_depth`, `is_backgrounded` reach the wire. |
| Completion notification injected into the conversation (`<task-notification>` envelope, §18.23.2) | Renders as an incoming message and starts a turn | The **injected user message is not emitted as a `user` frame** (`--replay-user-messages` covers human-driven messages only) — the host sees `system/task_notification`, then an unprompted `system/init` and assistant turn (Probe B, findings 6–7) | R | The GUI must synthesise the timeline item from `task_notification` (it has `status`, `summary`, `output_file`, `usage`), otherwise an assistant turn appears with no visible trigger. |
| Resume notice `Agent "<d>" was resumed by the user` (§18.23.2) | Injected message | Same absence; no `task_notification` for a resume | **D** | Only observable as another unexplained turn. Mitigate by having the GUI record its own `SendMessage`-driven resumes. |
| Parking (agent completed but holds `agent:` keepalives, §18.23.3) | Row stays live | `task_updated` never reaches a terminal status; no `task_notification` until the children settle | R | Detect by "completed children but no notification". |
| Eviction after 30 s (`WE`) | Row disappears | `background_tasks_changed` | P | |
| Kill all background agents — `ctrl+x ctrl+k` twice, with the toast `Press ctrl+x ctrl+k again to stop background agents` [`cli.pretty.js:403266`] | Confirm-then-kill | `stop_task` control request per task (declared via `perTaskStopAffordance: true` in `initialize`); or `interrupt`, which kills background tasks **unless** `perTaskStopAffordance` was declared (SPEC 45 initialize schema) | R | Two-key confirm and "kill everything" are the GUI's to build; fan out `stop_task` over the ids from `background_tasks`. Declaring `perTaskStopAffordance` also changes `interrupt` semantics — with it, interrupt spares running agents. |
| Killed-agent notification (partial report, max-turns note stripped, §18.23.3) | Row turns red, report shown | `task_notification` with `status: "killed"`/`"stopped"` and whatever partial `summary` exists | P | Live-verified for a `local_bash` task; same code path. |
| Output file | `output_file` on the notification | Same, live-verified | P | **For a local agent this file is a symlink to the subagent transcript** — see §18.25 below. |
| Auto-background after 120 s (`CLAUDE_AUTO_BACKGROUND_TASKS`) | Row flips to backgrounded | `task_updated` patch | P | |

---

## 18.24 Result assembly, sanitisation, auto-mode handoff

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Report = text blocks of the last non-empty assistant message (§18.24 #2) | Rendered as the tool result | Same text in `tool_result` and `task_notification.summary` | P | |
| Control-tag neutralisation (`<system-reminder>` → `&lt;system-reminder>`, the `hkt` envelope list, forged markers) (§18.24.1) | Escaped text | Escaped identically on the wire | P | The GUI inherits the protection; do **not** un-escape when rendering. |
| `[harness: subagent output matched instruction-shaped pattern(s): …]` prefix note (§18.24.1) | Prepended text block | Same | P | A GUI can badge this rather than inlining it — an area to exceed the TUI. |
| Auto-mode handoff `SECURITY WARNING: This subagent performed actions that may violate security policy…` (§18.24.2) | Prepended harness note | Same text; the decision itself is telemetry-only | P | |
| Web-fetch saved-files harness note (§18.7.7, §18.24 #6) | Trailing note naming the scratch dir | Same | P | The scratch-dir constraint matters for a GUI that offers to open the file. |
| Result spill over 100 000 chars | Truncated in the transcript | Truncated on the wire; full text in `<sessionId>/tool-results/` | R | |

---

## 18.25 Transcripts on disk and resume — the GUI's escape hatch

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Subagent transcript file | `ctrl+o` fold reads the in-memory progress stream | `~/.claude/projects/<slug>/<sessionId>/subagents/agent-<agentId>.jsonl` (§18.25.1, §35.11) — **live-verified**: `agent-a69fb6984c5234e4f.jsonl`, 28 KB, every `user`/`assistant`/`attachment` record with `isSidechain: true` and `agentId` | R | This is the definitive workaround for anything the wire drops: nested tool history, attachments, `deferred_tools_delta`, system reminders the subagent saw. `agentId` == `task_id` from `task_started`. |
| Path discovery | N/A | `task_notification.output_file` is `<tasks dir>/<taskId>.output`, and **for a local agent that file is a symlink to the subagent JSONL** (live-verified: `/private/tmp/claude-501/<slug>/<session>/tasks/a69fb….output -> ~/.claude/projects/<slug>/<session>/subagents/agent-a69fb….jsonl`) | R | Two ways in: resolve `output_file` (available only at completion, and it is a `local_bash`-style *file* for shell tasks), or construct `<projects root>/<slug>/<sessionId>/subagents/agent-<task_id>.jsonl` from `system/init.cwd` + `session_id` (available at spawn time, so it works **during** the run). Do not assume the tasks dir and the projects dir share a root — they do not. |
| Metadata sidecar | N/A | `agent-<agentId>.meta.json` (§18.25.2, §35.11.1). Live-verified minimal shape: `{agentType, description, toolUseId, spawnDepth}`; grows with `model`, `permissionMode`, `color`, `name`, `parentAgentId`, `worktreePath`, `worktreeBranch`, `isFork`, `stoppedByUser`, `worktreeCleanlyRemoved` as the run requires | R | The only on-disk source for `color`, `parentAgentId` and `permissionMode` — three things the wire never carries. |
| Lazy hydration for remote-created sessions (§35.11.3) | N/A | The file may not exist locally until fetched | R | Handle `ENOENT` gracefully; a remote-origin session's subagent files are fetched on demand. |
| Resume from transcript | `SendMessage` to a settled agent, or the transcript view's resume action | `SendMessage` tool call by the model; no host-initiated control request exists | **D** for a user-initiated resume | A GUI cannot resume an agent on the user's behalf; it can only inject a turn asking the model to `SendMessage`. |
| Resume refusals (user-stopped agent, missing transcript, forked-skill scoping, worktree gone) (§18.25.4) | Error text | Same text in the `SendMessage` tool result | P | |

---

## 18.26 `SendMessage` / `ListAgents`

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `ListAgents` rows (`agentType`, `status`, `started <duration> ago`) (§18.26.3) | Model-facing tool result the user sees rendered | Same tool result on the wire; independently, the `background_tasks` control request gives the host a structured list | P | The host list is better structured than the model's text table. |
| Naming a spawned agent (`name` param) | `@name` label on the row | Only when agent teams are enabled — `name` is stripped from the schema otherwise (§18.4) | X (default) | Without teams, agents are addressable only by `agentId`, which is the `task_id` the GUI already has. |
| `SendMessage` routes (`main`, live, stopped-by-user, stopped, evicted) (§18.26.2) | Result strings such as `Message queued for delivery to <name> at its next tool round.` | Same tool results | P | |
| Inline hand-back (`Resumed agent <name>. Result: …`) (§18.26.2) | Rendered block | Same text | P | |

---

## 18.27 Hook points

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `SubagentStart` (15 s, `agent_id`, `agent_type`) (§18.27.1) | Hook feedback shows as an informational banner | With `--include-hook-events`: `hook_started`/`hook_progress`/`hook_response` frames — live-verified for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `Stop`; Probe A shows the **subagent's own** `PreToolUse:Bash` on the wire | P | A GUI gets per-hook visibility the TUI compresses into one line. |
| `SubagentStop` (120 s, `agent_transcript_path`, `last_assistant_message`) (§18.27.2) | idem | idem | P | `agent_transcript_path` in the hook payload is another route to the JSONL path. |
| Blocking `SubagentStart` error | `SubagentStart:<agentType>` error message prepended to the subagent | Visible as a forwarded subagent frame | P | |
| `agent.spawn` / `agent.offer` plugin sites (§18.27.3) | Silent unless they deny | Deny surfaces as a tool error; `agent.offer` hiding an agent surfaces as a shrunken `initialize.agents` | P | |

---

## 18.28 Observer agents

Gated by `CLAUDE_CODE_EXPERIMENTAL_OBSERVER_AGENTS` (§18.28); off by default.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Observer pairing and fan-out (cap depth 2) | Extra task row flagged `isObserver` | `task_started` does not expose `isObserver`; the `.meta.json` sidecar does (`isObserver`, `observerTaskId`, `observerStopped`, `armingPermissionMode`) | **D** on the wire / R via disk | An observer appears on the wire as an ordinary extra `local_agent` task with no marker. |
| `ObserverReport` delivery (`Report queued for <target>.`) | Injected message | Injected without a `user` frame, like other notifications | R | Same synthesis problem as §18.23. |
| Pairing refusals (`[agentObserver] …`) | Log only | Log only | **D** | Minor. |

---

## 18.29 Agent memory

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `memory: user\|project\|local` directory appended to the agent's prompt (§18.29) | Invisible | Invisible | — | No user-visible surface either side. A GUI could show "this agent has persistent memory at `<dir>`" by reading the frontmatter — exceeds the TUI. |
| Auto-added `Write`/`Edit`/`Read` when memory is on and `tools` is explicit (§18.29) | Invisible | Invisible | — | |
| Disabled by `--safe-mode`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY`, `CLAUDE_CODE_SIMPLE`, `autoMemoryEnabled: false` | — | Same | P | |

---

## 18.30 `/agents`, `/fork`, `/subtask`

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/agents` | `local` command, `supportsNonInteractive: true`; prints the removal notice pointing at `.claude/agents/` and the docs URL (§18.30.1) | Works headless; output arrives as `local_command_output` / an `informational` banner | P | The wizard is gone in 2.1.257+; a GUI's own agent editor is a clear improvement over the TUI here. |
| `/fork` | `local-jsx` (§18.30.2) | Refused with the §8.1 panel message | **X** | See §18.20. |
| `/subtask` | `local-jsx` (§18.30.2) | Refused | **X** | |
| `⏵ forked <name> (<last 4 of agentId>)` success line | TUI-only | — | X | |

---

## 18.32 Environment variables and gates with a user-visible effect

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `CLAUDE_CODE_DISABLE_AGENT_VIEW` / `disableAgentView` | Removes the built-in `claude` agent — "FleetView's default when no agent name is typed" (§18.7, §18.32) | Same removal, observable as a missing entry in `initialize.agents` | P | FleetView itself is ch. 39 and is a terminal surface; from this chapter's angle the only effect is the presence of one agent type. `claude`'s system prompt is `appendSystemPrompt: true` and encodes the `result:` / `needs input:` / `failed:` completion protocol a fleet host parses out of message text (§18.7.6) — a GUI running background jobs may want the same convention. |
| `CLAUDE_CODE_FORK_SUBAGENT` | — | The single most consequential launch knob for parity (see §18.20) | R | |
| `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, `CLAUDE_CODE_SUBAGENT_MODEL`(`_FORCE`) | Caps and defaults (§18.32) | Same env; also visible through `get_settings` (`effective.env`) | P | Live `get_settings` returned the user's `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` — so a GUI can display the active caps. |
| `CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS`, `CLAUDE_CODE_WEB_FETCH_AGENT`, `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS` | Change the built-in roster | Observable in `initialize.agents` | P | Note `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS` only bites in a non-interactive session — i.e. exactly afleet's case. |
| `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` | Forces synchronous subagents | Same; `task_started.is_backgrounded` always false | P | |
| `subagentStatusLine` setting | A separate command shelled out with a 5 000 ms timeout, fed `{…hook base, columns, tasks[]}`, emitting JSONL `{id, content}` lines that decorate each running task row; initial tick at 300 ms then every 5 000 ms (§41.19.10) | The CLI still executes it (it is a settings-level helper, not a TUI-only path), but its output is consumed by the TUI renderer and never framed on the wire | **D** | A GUI that wants user-scriptable per-agent status decoration must run the command itself: read `subagentStatusLine` via the `get_settings` control request, then invoke it with the task list it already has from `background_tasks` / `task_started`. Note it is a `ro`-class helper command (blocked when workspace trust is not accepted, §48). |

---

## Top gaps in this area

Ranked by how much they cost a GUI aiming at TUI parity.

1. **Depth-2+ subagent activity is invisible without `--forward-subagent-text`; with it, it is fully visible but the parent link is implicit.** Nested `agent_progress` is re-emitted only under the flag [`cli.pretty.js:101873-101877`], and the resulting frames carry the *inner* `parent_tool_use_id` with no `parentAgentId` anywhere. Class P with the flag / D without. **Action:** keep the flag, and implement the two-step join (frame `parent_tool_use_id` → the `tool_use` block with that id → the frame that carried it) to rebuild the tree. Nothing in SPEC 45 documents this join.
2. **SPEC 45.9.2 understates what the wire carries — build against the code, not the summary.** Subagent `tool_use` and `tool_result` blocks reach stdout unconditionally; `text` and `thinking` need the flag [`cli.pretty.js:101878-101883`, `cli.pretty.js:92931-92947`]; live-confirmed on 2.1.259. A GUI that trusted 45.9.2 would have built a disk-polling fallback it does not need for depth 1.
3. **Agent colour is nowhere on the wire.** `initialize.agents` is `{name, description, model}` only [`cli.pretty.js:178998`]. The TUI tints the tool-call header, the row description and the subagent transcript border with the `color:` frontmatter value. Class D. **Workaround:** parse the agent `.md` frontmatter at startup, or read `subagents/agent-<id>.meta.json` after the spawn (it records `color`).
4. **No way for the user to background a running foreground agent.** The TUI offers `ctrl+b` (Task context) after a 2 000 ms `background_hint`; there is no wire frame and no control request. Class D. **Workaround:** none — the only lever is prompt engineering so the model passes `run_in_background: true`, or setting `CLAUDE_CODE_FORK_SUBAGENT=1`, which makes everything background.
5. **`task_progress` is tool-paced, not time-paced.** It fires only when the subagent emits an assistant message containing a `tool_use` [`cli.pretty.js:100991`]. A subagent thinking for 40 s emits nothing. Class R. **Workaround:** tick elapsed locally from `task_started`; opt into `agentProgressSummaries: true` for a model-written activity line every 30 s (skipped when the transcript has < 3 messages or is unchanged, §18.19.1 — which is why short runs produce none).
6. **The completion notification injected into the conversation is not framed as a `user` message.** The host sees `system/task_notification`, then an unprompted `system/init` and assistant turn (Probe B, findings 6–7). Class R. **Workaround:** synthesise the timeline item from `task_notification` (`status`, `summary`, `output_file`, `usage`) or the turn appears out of nowhere.
7. **`can_use_tool` and `permission_denied` identify the asking subagent only by `agent_id`.** No type, name or colour. Class R. **Workaround:** maintain a map from `system/task_started.task_id` (which equals the `agentId`) to `subagent_type` + `description`, and label the prompt from it. Without the map the GUI can only say "a subagent is asking" — worse than the TUI, which tints and names the row.
8. **The best full-fidelity fallback: the subagent JSONL on disk.** `~/.claude/projects/<slug>/<sessionId>/subagents/agent-<taskId>.jsonl` (live-verified) holds every record the subagent saw, including attachments and system reminders that never reach the wire. `<taskId>.output` in the tasks dir is a **symlink** to it (live-verified) — but the tasks dir root differs from the projects root, so construct the path from `system/init.cwd` + `session_id` + `task_started.task_id` if you need it *during* the run. Sidecar `.meta.json` is the only source for `color`, `parentAgentId` and `permissionMode`.
9. **A subagent's Bash output never streams.** `bash_progress` is forwarded to the parent but dropped by `TLe` unless `CLAUDE_CODE_REMOTE`/`CLAUDE_CODE_CONTAINER_ID` [`cli.pretty.js:92968-92972`]. Class D. **Workaround:** the task output file, or tailing the subagent JSONL.
10. **`subagentStatusLine` never reaches the wire.** The user-scriptable per-agent decoration (§41.19.10) is consumed by the TUI renderer. Class D. **Workaround:** read the setting via `get_settings` and shell out to it yourself with the task list you already have; its contract is stable (stdin `{…hook base, columns, tasks[]}`, stdout JSONL `{id, content}`, 5 000 ms timeout).
11. **Forks do not exist headless by default.** `kyr()` returns `disabled` when `Oe()` (§18.20.1). Class R via `CLAUDE_CODE_FORK_SUBAGENT=1`, but the knock-on is large: with fork on, `run_in_background` is stripped from the schema and every subagent is backgrounded (§18.18 step 9). Decide deliberately; do not flip it for the extra agent type alone.
12. **Worktree path is invisible while the agent runs.** `tool_use_result.worktreePath` arrives only at completion; creation is a log line (§18.21). Class D on the wire, R via the `.meta.json` sidecar (`worktreePath`, `spawnedWithWorktree`), which is written at spawn. There are no cleanup prompts in either surface — removal when HEAD is unchanged is automatic and unannounced.
13. **The subagent's tool set is unknowable.** `system/init.tools` describes the main thread only; the 17 always-removed tools (`XNe`) and the 26-tool background allow-list (`K7e`) are applied invisibly (§18.15). Class D. Accept it, or reimplement `dAo`/`VE` against the parsed definition.
14. **Silent degradations have no frame:** MCP servers blocked for an agent (`<type> agent MCP server(s) blocked by <reason>: <names>`, routed "to the UI, not the model", §18.15), and `isolation: "remote"` falling back to `worktree` or local (§18.18 step 8). Class D both. A GUI cannot tell the user the agent is running with less than it asked for.
15. **Killing agents is per-task, not global.** The TUI's `ctrl+x ctrl+k`-twice kills all background agents with a confirm toast [`cli.pretty.js:403266`]. Headless has `stop_task` per id. Class R — fan out over `background_tasks`. Note that declaring `perTaskStopAffordance: true` (which afleet should) also makes `interrupt` spare running background agents, so the GUI must provide the kill path itself.

---

## Unverified

- **Depth-2 `system/task_started` / `task_progress` / `task_notification` frames.** I verified the mechanism in code — `hu()` enqueues onto a host-level queue [`cli.pretty.js:669202`] drained by `runHeadlessStreaming`, independent of nesting — and that `spawn_depth` is populated from the task record [`cli.pretty.js:96786`]. I did **not** capture a live depth-2 run. The claim that nested agents produce their own task frames with `spawn_depth: 2` is a code inference.
- **`agentProgressSummaries` frame shape.** I traced `initialize.agentProgressSummaries` → `TOn(true)` [`cli.pretty.js:177252`] → `Ohe()` → `enableSummarization` [`cli.pretty.js:101884`] → `MAn` → `Yze` with `summary` set [`cli.pretty.js:127672`], which emits `system/task_progress` with both `description` and `summary` carrying the model-written line. No live capture produced one (both probes were far shorter than the 30 s cadence), so the field combination is inferred from code.
- **`--forward-subagent-text` off.** All live captures used the flag. The claim that `tool_use`/`tool_result` blocks are forwarded *without* it rests on the `if (!Tl && …) continue;` branch at [`cli.pretty.js:101878-101883`] plus `Cu`'s unconditional `progress` pass-through, not on an observed run.
- **`tool_progress` frames for subagent API retries.** Traced through `TLe`'s `agent_api_retry` branch [`cli.pretty.js:92976`] and corroborated by SPEC 45 §45.14.8 ("heartbeats and subagent-retry frames are not [gated]"). Not observed live.
- **`CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION`** appears in the settings env allowlist [`cli.pretty.js:486426`] and in the live `get_settings` response, but chapter 18 does not document it and I did not trace its consumer. Treat the per-session spawn cap as undocumented.
- **`subagentStatusLine` execution in a headless session.** §41.19.10 and §03 describe it as a settings-level helper with its own runner; I did not confirm whether the CLI still executes it when no TUI renderer is attached. The gap classification (its output never reaches the wire) holds either way.
- **Teams / teammate rows (`origin` kinds `peer`, `coordinator`).** Reachable only under `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`; chapter 18 covers only the branch condition that routes to `spawnTeammate`. The wire's `origin` field on `user` frames is chapter 39/45 territory and I did not trace how peer messages are framed.
