<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# 11 + 14 — Query loop / message model, and the tool interface & registry

Area: `11-14-query-loop-tool-interface`.
Sources read in full: `SPEC/11-query-loop-and-messages.md`, `SPEC/14-tool-interface-and-registry.md`.
Cross-checks against `SPEC/45-headless-and-sdk-protocol.md`, `SPEC/41-tui-rendering.md`,
`cli.pretty.js`, and the live 2.1.259 captures in `/tmp/afleet-gap/`.

Classes: **P** parity via protocol · **R** rebuild client-side · **D** data gap · **X** unreachable ·
**T** terminal-specific.

---

## 11.A The internal message vocabulary and what reaches the wire

The harness has exactly five conversation record types plus two wire-only types (SPEC 11.2.1). The
headless converter `TLe` (SPEC 45.9.3, `chunk-1kg58a1a.js:92949`) and filter `Cu`
(`chunk-2rhzyjym.js:172481`) decide which become stdout frames.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `user` record | Rendered as the user's prompt bubble, or as a tool-result row when its content is a `tool_result` (11.2.3, `DH` 11.2.12) | `user` wire frame carrying `message`, `tool_use_result` (the tool's **full** Output object, not the model-facing string), `tool_result_meta`, `origin`, `isSynthetic` (45.12.2) | P | GUI gets *more* than the model does: `tool_use_result` is the structured object. `tool_result_meta.non_execution_kind` ∈ `user-rejected, permission-rule, automode-blocked, automode-unavailable, automode-parsing-error, interrupted, cancelled` gives an exact reason for an empty error result — use it for the "rejected"/"interrupted" row styling. |
| `assistant` record | One transcript entry per message id, blocks laid out inline (thinking → text → tool_use) | **One wire frame per content block**, all sharing `message.id`; `stop_reason: null` and non-final `usage` on each (45.12.1) | R | A GUI must group by `message.id` itself and must not treat each frame as a separate turn. |
| `attachment` record | 35 of ~112 types render something; the rest render nothing (`default: return null`, `cli.pretty.js:767216`) | Only 3 attachment types survive as frames (see 11.F) | D | The single largest structural loss in ch. 11. |
| `system` record (30+ subtypes) | Display-only rows/banners; only `local_command` ever reaches the model (11.2.6) | Most subtypes pass through as `system/<subtype>` frames (45.9.1 table) | P | `api_error`, `turn_duration`, `permission_retry`, `stop_hook_summary`, `post_turn_summary`, `task_summary`, `file_snapshot` are listed as "internal surfaces" in 45.9.1 — see 11.D and 11.J. |
| `progress` record | Live sub-rows under a running tool (agent_progress, bash_progress, hook_progress, tool_heartbeat, workflow_*, 11.2.7). Never a chain parent | `TLe` converts them; but stdout only carries `tool_progress` for Bash/PowerShell **when `CLAUDE_CODE_REMOTE` or `CLAUDE_CODE_CONTAINER_ID` is set**, plus heartbeats and subagent retries always | D | afleet is a local host, so live Bash stdout progress is not on the wire. Workaround: set `CLAUDE_CODE_CONTAINER_ID` in the child env, or accept a static "running…" row. Subagent text needs `--forward-subagent-text` (already passed). |
| `api_system` (`role:"system"`) | Never displayed; produced during normalisation for mid-conversation-system models (11.2.8, 11.5.3) | Not on the wire | X | No user-visible effect; listed for completeness. |
| `tool_use_summary` | A ≤30-char past-tense label for a finished tool batch, e.g. `Fixed NPE in UserService` (11.2.9). Gated on `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES` + main thread | Passed through as a `tool_use_summary` frame (45.9.2) | P | Set `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES=1` in the child env and the GUI gets free collapsed-row labels the TUI itself does not show by default. Cheap win. |
| Message chain (`parentUuid`, `logicalParentUuid`, `sourceToolAssistantUUID` re-parenting) | Drives transcript ordering, rewind, and compact-boundary roots (11.2.2) | Wire frames carry `uuid` but **no `parentUuid`** | R | GUI must order by arrival. Full chain is readable from the session JSONL on disk (ch. 35) if rewind/branching UI is wanted. |
| `promptId` / `promptSource` (`typed`/`queued`/`suggestion_accepted`/`system`/`sdk`) | Distinguishes typed vs queued vs suggestion-accepted prompts (11.2.3) | Not on wire frames | D | A GUI that shows "you sent this from the queue" must track its own submissions. |

---

## 11.B Control events — what the TUI does with each, and what the GUI loses

SPEC 11.3 is the full control-event table; `Gxn` (`chunk-1kg58a1a.js:97131`) separates them from
messages. SPEC 45.9.2's filter `Cu` drops the ones below. The TUI consumer for each is the callback
bundle wired at `cli.pretty.js:426190-426315`.

| Event | TUI behaviour (SPEC §) | Headless equivalent (cite) | Class | Notes |
|---|---|---|---|---|
| `tombstone` | `onTombstone` → `De({type:"remove-by-uuid", uuid})` **deletes an already-rendered message** from the list and clears it from `stream.transcriptRetractedUuids` (11.3; `cli.pretty.js:426290`). Used for orphan repair, model-chain advance, refusal retract | Dropped (45.9.2). Partial compensation: with `--include-partial-messages` the CLI synthesises `content_block_stop` + `message_delta` + `message_stop` to close the abandoned block (45.13.1), and the *replacement* assistant frame carries `supersedes: [uuid…]` (45.12.1) | D | A GUI must implement retraction: on an assistant frame with `supersedes`, remove those uuids. But tombstones fired for non-refusal reasons (model-chain advance `chunk-1kg58a1a.js:122125`, malformed-tool-use retry `:122304`, orphan tombstoning `:121955`) produce **no** `supersedes` and no wire signal at all — those messages stay on screen in a GUI and are gone in the TUI. |
| `stream_request_start` | `onSetStreamMode("requesting")` — spinner enters the "requesting" state, token counter switches its arrow from `↓` to `↑` (11.3, 11.6; 41.18.4 `chunk-c872axth.js:440389`) | Re-injected by the engine as `system/status status:"requesting"`, but **suppressed unless `--include-partial-messages`** (45.9.2) | P | afleet already passes the flag, so this one is free. |
| `sdk_status` | `onCompactEvent` → compaction spinner state | Engine converts to `system/status` (11.2.6 `chunk-chr1kh62.js:448605`) | P | |
| `compact_progress` | `onCompactEvent` → the live compaction progress readout inside the spinner (11.3; ch. 13) | Dropped (45.9.2). Wire has only `system/status status:"compacting"` and, at the end, `compact_boundary` | D | GUI shows "compacting…" with no progress. Minor. |
| `stream_mode` | Sets the spinner mode: `requesting` / `thinking` / `responding` / `tool-input` / `tool-use` (11.6 `pat` table) | Dropped | R | Fully derivable from `stream_event`: `content_block_start` of `thinking`/`redacted_thinking` → thinking; `text` → responding; `tool_use` and the twelve server-tool block types → tool-input; `message_stop` → tool-use (11.6). A GUI can reproduce this exactly. |
| `response_length` | `stream.onResponseLength` (`cli.pretty.js:425746`): `op:"reset"` zeroes, otherwise adds a delta, to the response-character counter that the spinner prints as `↓ 1.2k tokens` (chars ÷ 4, 41.18.4 `chunk-c872axth.js:440199`) | Dropped | R (mostly) / D (compaction) | Answer to the brief's "?": it is the spinner's live token counter feed. A GUI can count its own `text_delta`/`input_json_delta` bytes for the model turn. What it *cannot* see is the compaction summary's own stream, which is where `onResponseLength` is threaded from `G1n` (`chunk-1kg58a1a.js:124361`) — during a compaction the GUI's counter will sit still. |
| `set_expanded_view` | `onExpandedView` → `appState.expandedView` (value `"teammates"` is mapped to `"none"`), which toggles the expanded team/tool panel (`cli.pretty.js:426302`) | Dropped | X | TUI-only view state; a GUI owns its own disclosure state. |
| `set_in_progress_tool_use_ids` | `onInProgressToolUseIDs` → `appState.inProgressToolUseIDs`, passed straight into the message renderer as `inProgressToolUseIDs` and `inProgressToolCallCount` (`cli.pretty.js:769130`, ch. 12). **This is what makes a tool row show a live spinner instead of a finished row.** | Dropped (45.9.2) | R | Derive it: a `tool_use` block whose `tool_use_id` has no matching `tool_result` in a later `user` frame is in progress. Equivalent in practice; the only loss is the harness's own add/remove ops for tools that are queued vs actually executing. |
| `hint_clears` | `onHintClears` → `Fmt(messages, ids, contentById)` (`chunk-1kg58a1a.js:117291`) **rewrites messages already on screen**, deleting or replacing server-cleared inline hint content, and drops the affected files from `readFileState` | Dropped | D | A GUI keeps showing content the server has retracted. No workaround on the wire; low frequency. |
| `api_metrics` | `stream.recordApiMetricsEvent` — TTFT, output-token totals, per-message timing, and the running thinking-token estimate from `thinking_delta.estimated_tokens` (11.6). Feeds `thought for <n>s` and the spinner's thinking labels (41.18.4 `chunk-c872axth.js:440222`) | Dropped. Partial substitutes: `system/thinking_tokens` frames, and `ttft_ms` / `duration_api_ms` on the `result` frame | R/D | A GUI can time its own first `stream_event`. Thinking-token *estimates during* streaming are only available if it re-implements `mhn()`; the per-message signature-delta character count is not recoverable. |
| `os_notification` | `onOSNotification` → `Ov(...)` (`cli.pretty.js:426310`) — **the desktop/terminal notification trigger** (bell, iTerm/Terminal.app notification, notification hook) | Dropped (45.9.2) | D → but see notes | The GUI must raise its own native notification. Partial data is on the wire: `system/notification` frames (`{key, text, priority, color?, timeoutMs?}`, 11.3) and the `PushNotification` tool. What is lost is the harness's own *policy* about when a notification is warranted (idle threshold, focus state). afleet can do better than the TUI here — it knows real macOS focus state. |
| `open_message_selector` | Opens the rewind / message-selector overlay (`cli.pretty.js:426197` → `_o()`); triggered by `Esc Esc` and by `chunk-02m8eq00.js:1203` | Dropped | X / T | The overlay itself is unreachable, but the *capability* is: `rewind_conversation` and `rewind_files` control requests (45.17) let a GUI build its own rewind picker over the frames it has. |
| `refusal_continuation` `{phase:"begin"|"end"}` | `onRefusalContinuation` (`cli.pretty.js:426293`): on `begin` sets `continuationReplacesUuids` and `Fe.setSalvage(salvageText, join === "exact")` — this is the collapser that stitches the retried continuation onto the partial text already painted, so the user sees one message, not two; on `end` clears both | Dropped. 45.13.2's `eu` collapser handles only the *banner* (`system/model_refusal_fallback`), suppressing provisional duplicates and reporting `suppressed_count` / `emitted_via` | D | A GUI will render the pre-refusal partial text **and** the re-streamed continuation as two separate assistant messages. The salvage text and the `join: "exact"` hint are not on the wire. This is the highest-value protocol addition for text fidelity. |
| `query_model_change` `{toModel}` | Ignored by `REe`; documented as "used by hosts to re-render the model badge" (11.3) | Dropped, but the paired `system/model_fallback` message *is* emitted from the same site (11.7.7, `chunk-1kg58a1a.js:122126`), as are `model_refusal_fallback`, `model_consent_fallback`, `model_refusal_no_fallback` (45.9.1) | P | The GUI updates the model badge from the `system/model_*` frames instead. No real gap. |
| `command_lifecycle` | `onCommandLifecycle(uuid, state)` — marks a queued command as started/completed/cancelled in the queue chip (11.3, 11.11.4) | On the wire as `command_lifecycle` frames, advertised by the `msg_lifecycle_v1` capability (45.10.3; confirmed present in the live init capture) | P | |
| `tool_drain_tick`, `server_fallback`, `fallback_request`, `refusal_no_fallback`, `streaming_fallback_began`, `apply_flag_settings`, `post_turn_summary`, `active_goal`, `conversation_reset`, `notification` | Consumed inside the loop or by dedicated TUI state (11.3) | `post_turn_summary`, `active_goal`, `conversation_reset`, `notification` all have wire frames (45.9.1); `apply_flag_settings` is dropped; the rest are loop-internal | P / X | `apply_flag_settings` (`Rye(settings)`) lets the CLI push a settings change into the TUI mid-turn; headless hosts must poll `get_settings`. |

---

## 11.C Turn lifecycle indicators

The spinner is ch. 41's, but everything it reads comes from ch. 11's control events, so it belongs
here from the wire angle.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Spinner mode (`requesting` → `thinking` → `responding` → `tool-input` → `tool-use`) | Driven by `stream_mode` / `stream_request_start` / the `pat` reducer (11.6) | Derive from `stream_event` block types + `system/status status:"requesting"` | R | Exact mapping table is 11.6; reproducible 1:1. |
| Spinner verb line | `overrideMessage ?? activeTask.activeForm ?? activeTask.subject ?? (defaultVerb || locally sampled verb)`, always suffixed `…` (41.18.4 `chunk-c872axth.js:440444`) | The sampled-verb list is client-side only; `tool_progress` heartbeats and `getActivityDescription` (14.4.8) are the per-tool substitutes | R | GUI writes its own verb; `getActivityDescription` output is *not* on the wire (see 14.A). |
| Elapsed timer (`0s`, `1.4s`, `12s`, `2m 3s`, `1h 2m 3s`, minus paused time) | `chunk-6aqvjbk0.js:287577`, `chunk-c872axth.js:440159` | GUI times from its own submit | P (trivially rebuildable) | |
| Token counter `↓ 1.2k tokens` / `↑` while requesting | Response characters ÷ 4, animated, `Intl.NumberFormat` compact lowercase (41.18.4) | Count `text_delta` + `input_json_delta` bytes from `stream_event` | R | Same caveat as `response_length` above (compaction blind spot). |
| Thinking label escalation: `thinking` → `still thinking` → `thinking more` → `thinking some more` → `almost done thinking` | Time-thresholded, `chunk-c872axth.js:440144` | Elapsed-time-based; nothing needed from the wire | R | |
| `running tool for <d>` / `ran tool for <d>` / `thought for <n>s` | `chunk-c872axth.js:440220-440228` | Timed from `stream_event` block boundaries and tool_use/tool_result pairing | R | `thought for N s` needs only the thinking block's start/stop times, both visible in `stream_event`. |
| `esc to interrupt` | **Composed, not literal**: the footer renders `<chord> to <action>` from the `chat:cancel` binding + the word `interrupt` (41.18.4 `chunk-bq8epagv.js:410123`; the literal string appears only in the low-priority retry banner `chunk-c872axth.js:440315`) | `interrupt` control request; the `interrupt_receipt_v1` and `interrupt_cancel_queued_v1` capabilities are advertised in `system/init` (confirmed in the live capture) | T | A GUI shows a stop button. The interrupt *receipt* (`still_queued`, `cancelled`) is richer than what the TUI footer conveys — a GUI can exceed the TUI here. |
| Stall banners: `Waiting for API response` (10 s / 45 s / 300 s thresholds) | 41.18.5 `chunk-c872axth.js:440282`, `:440167` | Not on the wire as such | R | A GUI can time silence between frames itself; the `keep_alive` frame (every 30 s while a control request is outstanding) helps distinguish "hung" from "working". |
| `session_state_changed` (`idle` / `running` / `requires_action`) | No direct TUI equivalent — the TUI knows its own state | On the wire (45.9.1, 45.14.2); `idle` is documented as the authoritative turn-over signal | P | A GUI can drive its whole busy/idle chrome from this. Better than reverse-engineering `result`. |

---

## 11.D Errors, retries and recovery

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `api_retry` banner | `system/api_retry`, twinned off `api_error` by the engine (11.2.6 `chunk-chr1kh62.js:448621`). Spinner shows `API error · next try in <d> · attempt N/M` (41.18.5 `chunk-c872axth.js:440341`) | `system/api_retry` frame is **passed through by `Cu`** (45.9.2) | P | Also mirrored as `system/control_request_progress status:"api_retry"` with `attempt`, `max_retries`, `retry_delay_ms`, `error_status` for `side_question` (45.14, `chunk-sct99ax9.js:673390`). |
| `api_error` system record | Internal display record `mle(error, retryInMs, retryAttempt, maxRetries, source)` (11.2.6 `:154436`) | Listed under 45.9.1's "internal surfaces" row; the user-facing carrier is the **assistant** frame with `is_api_error_message: true`, `api_error`, `api_error_status`, `error_details` (45.12.1, `Iit` at `chunk-1kg58a1a.js:92781`) | P | GUI renders the error from the assistant frame, not from a banner. `message.model === "<synthetic>"` (`Jc`) identifies fabricated error messages (11.2.12 `LV`). |
| `max_output_tokens` recovery | `API Error: Claude's response exceeded the <N> output token maximum…` (11.7.4), then up to 3 silent retries with a `turnCompanion` nudge | The error assistant frame reaches the wire with `api_error: "max_output_tokens"`; the nudge is an `isMeta` user message and is **not** replayed | P/R | The GUI sees the error text and then more output; it should collapse the three attempts the way the TUI does. The retry count is not signalled. |
| Truncated-response recovery (11.7.5) | Same shape, gated `tengu_truncated_response_recovery` (default on); text differs for subagent vs main | `truncatedAfterOutput` is not projected onto the assistant wire frame's field set (`Iit` copies `aborted`, `is_api_error_message`, `api_error`, `resumed_from_incomplete_thinking`, `is_virtual`, `batch_tool_uses`, `wire_tool_inputs` only) | D | Silent to the GUI; low impact. |
| Malformed tool use (`stop_reason:"tool_use"`, zero blocks) | First occurrence: tombstone the attempt, retry silently. Second: `The model's tool call could not be parsed (retry also failed).` and terminal `malformed_tool_use_exhausted` (11.7.7) | Terminal reaches `result.terminal_reason`; the first-occurrence tombstone does not | D | Combined with the tombstone gap: a GUI shows a phantom assistant message the TUI erased. |
| Prompt-too-long / image error | `Prompt is too long · automatic compaction failed: <detail>` (11.7.3 `Lit`), or one of three single-exchange explanations; terminal `prompt_too_long` / `image_error` | Error text arrives on the assistant frame; terminal on `result.terminal_reason` | P | |
| Rapid-refill breaker | `Autocompact is thrashing: … Try reading in smaller chunks, or use /clear to start fresh.` (11.7.3 `chunk-1kg58a1a.js:63689`) | Assistant error frame + `terminal_reason: "rapid_refill_breaker"` | P | Worth a dedicated GUI affordance offering `/clear`. |
| Blocking context limit | `Prompt is too long`, terminal `blocking_limit` (11.4.3 step 14) | `result.terminal_reason` | P | |
| Stop-hook block-cap override warning (`A hook blocked the turn from ending N consecutive times — overriding…`) | 11.13.2 | `system/informational` warning | P | |
| `Stop hook failed: <msg>` | `Mt(..., "warning")` (11.13.2) | `system/informational` | P | |
| Budget exhausted (`--max-budget-usd`) | stderr `Budget limit reached ($X of $Y); stopping background agents.` (11.14.5 `chunk-2rhzyjym.js:174213`) | `result` with `subtype: "error_max_budget_usd"` and `terminal_reason: "budget_exhausted"` (45, `chunk-2rhzyjym.js:1288`) | P | |
| `--max-turns` reached | `Error: Reached maximum number of turns (N)` (11.14.5) | `result` `subtype: "error_max_turns"` | P | |

---

## 11.E Refusal fallback, `supersedes` and retraction

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Refusal-fallback notice | `system/model_refusal_fallback` built by `OS` (11.7.6): `<Model>'s safeguards flagged this message. This sometimes happens with safe, normal conversations. Switched to <Model>. <suffix>` | Wire frame carries `trigger`, `direction`, `scope`, `original_model`, `fallback_model`, `request_id`, `api_refusal_category`, `api_refusal_explanation`, `saw_cyber_refusal`, `retracted_message_uuids`, `refused_user_message_uuid`, `content` (45.13.2) | P | The `provisional` flag is stripped and duplicate provisional banners are collapsed CLI-side (45.13.2 `eu`) — the GUI gets the already-deduplicated banner. |
| Non-switching variants | `… This response was generated by <Model> instead. Your session model is unchanged. …` / `… This response was completed by <Model>. …` (11.7.6 `chunk-1kg58a1a.js:65181`, `:65186`) | Same frame, `direction`/`scope` distinguish them | P | |
| Client-side retract (`Uc()`) | Splices retracted assistant messages out of the list and yields one `tombstone` per uuid (11.7.6 `:121692`) | `retracted_message_uuids` on the banner frame + `supersedes` on the replacement assistant frame + synthetic stream close events (45.13.1) | R | **A GUI must implement retraction.** On `model_refusal_fallback`, delete the uuids in `retracted_message_uuids`; on any assistant frame with `supersedes`, delete those uuids. |
| Refusal-continuation collapser | `phase:"begin"` arms `continuationReplacesUuids` + salvage text so the re-streamed continuation merges into the visible partial message; telemetry `tengu_convolute_arcades_retry_outcome` = `merged` / `no_text` / `error` (11.7.6) | Not on the wire (see 11.B) | D | Consequence: duplicated partial text in the GUI. |
| Server-side cascade decline | `Server refusal-fallback target "<m>" is not in the availableModels allowlist; declining the swap` — a `warn` log, not user-visible (11.7.6) | — | X | Log only; no GUI action needed. |
| `refused_user_message_uuid` | Lets the TUI point the banner at the offending user turn (11.7.6) | On the wire | P | A GUI can highlight the flagged prompt — the TUI barely does. Opportunity to exceed. |

---

## 11.F Attachments

`Ype` renders attachments into model-facing `user` messages at request-assembly time (11.8.3); the
`attachment` transcript record is separately rendered in the TUI by the component at
`cli.pretty.js:766476-767216`, whose `default` arm returns `null`.

**TUI-visible attachment types (35 of ~112).** Enumerated from the switch at `cli.pretty.js:766477-767197`:
`teammate_mailbox` (pre-switch, only when agent teams are on), `directory`, `file`,
`already_read_file`, `compact_file_reference`, `pdf_reference`, `audio_transcript`,
`selected_lines_in_ide`, `selected_lines_in_diff`, `nested_memory`, `relevant_memories`,
`dynamic_skill`, `skill_listing`, `agent_listing_delta`, `queued_command`, `plan_file_reference`,
`invoked_skills`, `diagnostics`, `mcp_resource`, `command_permissions`, `async_hook_response`,
`async_hook_response_batch`, `hook_blocking_error`, `hook_non_blocking_error`, `hook_cancelled`,
`hook_error_during_execution`, `hook_success`, `hook_stopped_continuation`, `hook_deferred_tool`,
`goal_status`, `hook_system_message`, `tool_hosts_notice`, `tool_host_result_lines`,
`hook_permission_decision`, `task_status`, `teammate_shutdown_batch`.

**Wire-visible attachment types (3).** Filter `Cu`'s `case "attachment"` (45.9.2,
`chunk-2rhzyjym.js:172521-172531`).

| Attachment | TUI behaviour | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `queued_command` | Rendered as an inbound message bubble; a projects-relay origin gets a `fromName` speaker label (`cli.pretty.js:769078`) | Becomes a **replayed `user` frame** — but only when `--replay-user-messages` is set (45.9.2) | P | afleet passes the flag. The `origin` field is preserved on the replayed frame (45.12.3 `cu`). |
| `hook_system_message` | Dim informational row | Becomes a `system/informational` banner | P | |
| `tool_host_result_lines` | Renders the tool-host result lines | Becomes a `system/tool_host_result` frame | P | |
| `agent_listing_delta` | `Available agent types for the Agent tool: …` / `New agent types are now available…` / `The following agent types are no longer available` (11.9.15) | **Dropped.** `system/init.agents` gives the current list per turn | R | Diffing consecutive `system/init.agents` reproduces the delta. |
| `deferred_tools_delta` | Not in the TUI switch → invisible in the TUI too (it is a model-facing reminder) | Dropped; `system/init.tools` gives the current pool | R | See 14.F — the GUI can diff init lists. |
| `plan_mode` / `plan_mode_exit` / `plan_mode_reentry` | `plan_mode_exit` renders `## Exited Plan Mode` in the model context; TUI plan-mode state is separate chrome | Dropped. Permission-mode change arrives as `system/status status:null, permissionMode:"plan"` (45.14.1) | P | Mode chrome comes from the status frame, not the attachment. |
| `auto_mode` / `auto_mode_exit` | Same | Same (`permissionMode:"auto"`) | P | |
| `diagnostics` / `lsp_diagnostics` | Rendered as a diagnostics block under the turn | Dropped | D | A GUI wanting an inline diagnostics panel must run its own LSP or scrape the model-facing text out of the transcript JSONL. |
| `task_status` | `Task "<desc>" (<id>) was stopped by the user.` / `Background agent … is still running. Progress: …` (11.9.15) | Dropped as an attachment, but `system/task_started` / `task_updated` / `task_progress` / `task_notification` / `background_tasks_changed` frames carry the same state (45.9.1) | P | |
| `goal_status` | Goal chip | Dropped; `active_goal` frame carries it (45.9.1) | P | |
| `hook_*` family (blocking_error, non_blocking_error, cancelled, error_during_execution, success, stopped_continuation, deferred_tool, permission_decision) | Eight distinct hook outcome rows (11.9.15 texts) | Dropped as attachments; `--include-hook-events` gives `system/hook_started` / `hook_progress` / `hook_response` instead (45.9.1) | R | The hook *events* are on the wire (afleet passes `--include-hook-events`), so a GUI can build equivalent rows, but the harness's own phrasing (`<name> hook blocking error from command: "<cmd>": <err>`) must be reproduced client-side. |
| `mcp_resource` | Renders the resource header/preview | Dropped | D | Resource content is model-facing only. |
| `relevant_memories`, `nested_memory`, `invoked_skills`, `skill_listing`, `dynamic_skill` | Memory/skill context rows | Dropped; `system/memory_recall` covers auto-recall (45.9.1); `system/init.skills` covers the skill list | R/D | Nested-memory and invoked-skill listings have no wire twin. |
| `file`, `directory`, `already_read_file`, `compact_file_reference`, `pdf_reference`, `audio_transcript`, `inlined_image_paths`, `edited_text_file`, `edited_image_file`, `read_truncation_notice` | File/@-mention context chips and "changed on disk" notices | Dropped | D | The GUI loses "`<file>` changed on disk since you last read it" and the truncated-read notices, which the TUI shows. |
| `selected_lines_in_ide`, `selected_lines_in_diff`, `opened_file_in_ide` | IDE selection chips (`⧉` glyph, 41 §2847) | Dropped | X | IDE-integration only; irrelevant for afleet unless it becomes the IDE. |
| `command_permissions` | `Allowed <a, b>` style row | Dropped; `system/permission_retry` covers the retry case (11.2.6) | D | |
| `teammate_mailbox`, `team_context`, `teammate_shutdown_batch`, `agent_pending_messages` | Team panels | Dropped | D | Only relevant with agent teams enabled. |
| `token_usage`, `budget_usd`, `output_token_usage`, `total_tokens_reminder` | Not in the TUI switch — model-facing only | Dropped; `result.usage` / `total_cost_usd` and the `get_context_usage` / `get_session_cost` control requests carry the real numbers | P | `output_token_usage` is dead code in 2.1.257 (11.8, Open questions). |
| `max_turns_reached` | Renders to nothing by design; "exists so the host can detect the condition" (11.14.5) | Dropped; `result.subtype: "error_max_turns"` is the host signal | P | |
| Everything else (~70 types) | `default: return null` — invisible in the TUI too | Dropped | X | No gap: neither surface shows them. |

**Attachment producer failure isolation** (11.8.1 `pd`): a throwing producer logs
`Attachment error in <label>` and returns `[]`. This never surfaces to either UI. No gap.

---

## 11.G Meta, virtual and transcript-only messages

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `isMeta` user messages | Harness-authored context (ambient reminders, nudges, `turnCompanion` recovery prompts). Not shown as the user speaking; `DV`/`P3` (11.2.12) exclude them from "genuine user turn" tests | Wire `user` frame carries `isSynthetic: true` when `isMeta || isVisibleInTranscriptOnly || isCompactSummary` (45.12.2 `lwe`) | P | **A GUI should not render `isSynthetic` user frames as user messages.** They are harness plumbing. The three causes are conflated into one boolean — if the GUI wants to show compact summaries but hide nudges, it cannot distinguish them from this flag alone. |
| `isVirtual` | Synthesised for display; stripped from the wire request (`Wj`, `go` drops them, 11.5.1) | `is_virtual: true` on both assistant (`Iit`) and user frames (45.12.1/45.12.2) | P | Render them; they are display-intended. |
| `isVisibleInTranscriptOnly` | Rendered in `/export` and the transcript view, never sent to the model (11.2.3) | Folded into `isSynthetic`; no distinct flag | D (minor) | |
| `isCompactSummary` | The post-compaction summary message; `kEe` treats it like a compact boundary (11.2.12) | Folded into `isSynthetic`; `system/compact_boundary` frame marks the boundary itself | P | Use `compact_boundary` for the divider and hide the `isSynthetic` summary body, or show it collapsed — a GUI can beat the TUI here. |
| `turnCompanion` nudges (`Output token limit hit. Resume directly…`, `[Your previous response had no visible output…]`, `The previous response failed to produce a valid tool call…`) | Injected as `isMeta` user messages; the TUI does not render them as user turns (11.7.4, 11.7.7, 11.7.8) | Not replayed (they are `isMeta`, and `su`'s replay filter requires `!isMeta && DV(n)`, 45.12.3) | P | Correctly invisible on both sides. |
| Ambient user-context block (11.5.4) | Prepended to every request, never persisted, never displayed | Never on the wire | X | No gap. |
| `<system-reminder>` wrapping vs mid-conversation system turns (11.5.3) | Invisible to the user on both surfaces | Invisible | X | Listed because it changes *model* behaviour, not UI. Note for afleet: nothing to do. |

---

## 11.H Queued and steered messages, `/btw`, brief mode

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Message queue (three priorities `now`/`next`/`later`) | Typing while a turn runs enqueues; the queue chip shows depth; `popAllEditable` / `popEditableAt` let the user pull a queued message back into the editor (11.11.1) | Stdin `user` frames with `priority` are accepted (45.15). `command_lifecycle` reports `queued → started → completed/cancelled/discarded/refused` | P/R | A GUI must render its own queue UI and its own "pull back to edit" affordance — there is no control request to *remove* a queued message, only `interrupt { cancel_queued: true }`. |
| Mid-turn fold (steering) | A message typed mid-turn is folded into the running turn after the next tool batch, prefixed `The user sent a new message while you were working:` + `This is how Claude Code surfaces messages the user sends mid-turn…` (11.11.5) | Same mechanism server-side; the folded message reaches the GUI as a replayed `user` frame with `origin` | P | The GUI should render the replayed frame inline in the running turn, not as a new turn — otherwise the visual model diverges from the conversational one. |
| Slash commands are never folded | `Run(f)`: a queued value starting with `/` is excluded from mid-turn folds (11.11.4) | Same | P | A GUI that queues `/`-commands must expect them to wait for the next turn. |
| All-or-nothing fold delivery | Partial conversion logs `[query] turn-start passive fold emitted N of M — leaving them queued` at `warn`; mid-turn partial logs at `error` and drops the undelivered (11.11.4) | Invisible on the wire | D (minor) | Only observable as a message that silently stays queued. |
| Origin preambles (`peer`, `channel`, `coordinator`, `plugin`, `slack-ping`, `observer`, `task-notification`, `scheduled-trigger`, `projects-relay`) | `dpe` prefixes a provenance banner; the TUI renders a `fromName` speaker label for projects-relay queued commands (11.11.5; `cli.pretty.js:769078`) | `origin` object is preserved on replayed `user` frames (45.12.3) | P | A GUI can render richer provenance chips than the TUI's text banner. |
| Peer-message admission control (rate limit, dedupe, `queue-full` drop receipts) | Rejections are silent to the user; drop receipts go back to the peer over UDS (11.11.7) | Invisible | X | |
| `/btw` side question | `local-jsx` command, `immediate: true`. Runs a **separate one-shot query** (`querySource: "side_question"`, `maxTurns: 1`, `skipTranscript: true`, all tools denied via `canUseTool` → `"Side questions cannot use tools"`). Answer renders in its own panel; `btwHistory` threads follow-ups. Usage errors: `Usage: /btw <your question>`, `Side questions aren't available when viewing a session read-only`. A Ctrl-chord submits it. The panel's "step aside" re-queues it as a `task-notification` (11.11.6) | **The `local-jsx` command itself is refused headless** (SPEC 28 §22 / 45.29.1). The capability is exposed as the `side_question` **control request** — the only one besides `mcp_call` that is genuinely abortable, with `system/control_request_progress` frames carrying `status: "started"` / `"api_retry"` and retry counters (45.22.11, 45.14) | R | afleet must build its own side-question panel on `side_question` + `control_request_progress` + `control_cancel_request`. It gets *more* than the TUI (progress + cancel). Losses: the model's synthetic fallbacks (`(The model tried to call <tool> instead of answering directly…)`, `(API error: …)`) are produced inside the local-jsx handler, so the GUI must produce its own; and `btwHistory` threading is client state the GUI must keep. Errors: `Session is shutting down` / `Side question cancelled`. |
| Brief mode / `SendUserMessage` (alias `Brief`) | `/brief` is `local-jsx` (`Toggle brief-only mode`, 41.23.5). When on, plain assistant text is hidden and only `SendUserMessage` output is shown; a `system/turn_duration` record carries `briefHiddenCount` (11.14.4). The enable/disable reminders are 11.9.10 | `/brief` (local-jsx) is **refused headless**. `SendUserMessage.isEnabled()` is `LAe() \|\| ofe()` (14.8) — brief mode or "pewter-owl" tool mode; the live 2.1.259 `system/init.tools` capture does **not** list it | X (the toggle) / D (the state) | The GUI cannot turn brief mode on through the protocol, and cannot read whether it is on. If it were on, `SendUserMessage` tool calls would be the user-visible channel and plain text would need hiding — the GUI would have to infer that from the tool's presence in `system/init.tools`. `briefStandalone` (14.4.5, on `SendUserMessage`, `SendUserFile`, the artifact addons) is not on the wire either. Recommend: treat brief mode as out of scope; if `SendUserMessage` appears in `init.tools`, render its calls prominently. |
| `--brief`-adjacent enforcement | At turn end `kUn` may inject a brief-enforce sentinel: `In brief mode, plain assistant text is hidden from the user — only SendUserMessage reaches them. Call it now…` (11.13.2; text at SPEC 23 §538) | `isMeta`, not replayed | X | |
| `/focus` view | Third view mode, `requires: { ink: true }` (41.23.5) | — | T | Terminal-only; the GUI owns its layout. |

---

## 11.I Abort and interrupt

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Interruption message | `[Request interrupted by user]` or `[Request interrupted by user for tool use]`, emitted at four checkpoints unless the abort reason is internal (`interrupt`, `turn-abort`, `refusal-fallback-edit`) (11.12.2, `YI` at `:151833`) | Emitted as a normal `user` frame with `interruptedMessageId` **not** projected onto the wire | P (text) / D (linkage) | The GUI sees the sentinel text but not which message was cut. `aborted: true` on the assistant frame (`Iit`) is the usable marker for a truncated message. |
| Abort reason taxonomy (`user-cancel`, `remote-cancel`, `shutdown`, `interrupt`, `turn-abort`, `background`, `refusal-fallback-edit`, `recovery-timeout`, `server-fallback-tombstone`, `subagent-park`) | Determines whether a user-visible message is emitted at all, and whether the abort propagates to children (11.12.1) | Not on the wire | D (minor) | The GUI just sees the presence or absence of the sentinel. |
| Orphan repair | Dangling `tool_use` blocks get synthetic error `tool_result`s (`Yjo`, 11.12.4); `[Orphaned tool result removed due to conversation resume]` on resume (`EYn`) | The synthetic `tool_result`s reach the wire as normal `user` frames | P | |
| Interrupt receipt | The TUI's footer just clears | `interrupt` control response carries `still_queued` and `cancelled` under the `interrupt_receipt_v1` / `interrupt_cancel_queued_v1` capabilities (45.10.3; both present in the live init capture) | P → exceed | A GUI can tell the user "3 queued messages also cancelled" — the TUI does not. |
| Computer-use unhide on abort (`Uj`, 5 s budget) | 11.12.2 | — | X | |

---

## 11.J Stop / StopFailure / PostToolBatch surfaces

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `stop_hook_summary` system record | Emitted when at least one Stop hook produced progress; carries hook count, per-hook info, errors, `preventedContinuation`, total duration, additional contexts (11.13.2 `wUn`) | Listed under 45.9.1's "internal surfaces"; **not** an enumerated stdout frame | D | With `--include-hook-events` the GUI gets `hook_started`/`hook_progress`/`hook_response` and can build its own summary row. |
| Stop-hook error notification | `Stop hook error occurred · <binding> to see` (11.13.2) | The binding hint is terminal-specific | T | GUI shows its own affordance. |
| Stop-hook block loop | Up to `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` (default 8) blocked turn-ends, then a warning and a forced `completed` (11.13.2) | The warning is a `system/informational`; the blocked iterations look like extra turns | P | |
| `StopFailure` | Fire-and-forget on the three API-error exits; output and exit codes ignored (11.13.4) | Same; `--include-hook-events` shows it fired | P | |
| `PostToolBatch` blocking | Yields `hook_stopped_continuation` attachment (`Execution stopped by PostToolBatch hook` or the hook's reason) and returns `hook_stopped` (11.13.5) | Attachment dropped; `terminal_reason: "hook_stopped"` on `result`; hook events with `--include-hook-events` | R | GUI reconstructs the banner from the hook response frame. |
| `PostToolBatch hooks cancelled (control stream closed)` | Debug log (11.13.5) | — | X | |

---

## 11.K Thinking blocks

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Streaming thinking panel | `onStreamingThinking` accumulates the live thinking text; finalised when the assistant message carrying a `thinking` block arrives (11.6 `REe`) | `stream_event` `content_block_delta` / `thinking_delta` carries the text; the completed block arrives on its own assistant frame | P | |
| `redacted_thinking` blocks | Carried through unchanged; `Ope` treats them as always signed (11.15) | Present in `message.content` on the assistant frame | P | A GUI must render *something* for a `redacted_thinking` block (it has no readable text) — a "thinking (redacted)" placeholder. |
| `thought for N s` | Composed from `api_metrics` timing (41.18.4 `chunk-c872axth.js:440222`) | Time the `content_block_start`→`content_block_stop` span of the thinking block in `stream_event` | R | |
| Thinking-token estimate | `onApiMetrics({type:"thinking_progress", estimatedTokensDelta})` from `delta.estimated_tokens` or `mhn(delta.thinking)`; `signature_delta` → `{type:"thinking_signature", chars}` (11.6) | `system/thinking_tokens` frames (45.9.1) | P/R | Per-delta granularity is lost; the frame-level total is on the wire. |
| Unsigned trailing thinking | `zJ` / `upe` / `vor` drop it during normalisation (11.15) | Invisible | X | |
| Thinking-block resumption | `resumed_from_incomplete_thinking: true` on the assistant frame (45.12.1 `Iit`) — gate `tengu_thinking_block_resumption`, default **off** | On the wire | P | Rarely fires in 2.1.257. |
| `ultrathink` keyword highlighting | `_Je(text)` = `/\bultrathink\b/i`; `zFe` returns match spans so the **input editor highlights the word as you type** (11.15) | Not on the wire; it is pure client-side text matching | R | Trivial to reimplement in the GUI's composer; also `ultracode` (`workflow_keyword_request`, 11.9.15). Nice polish win. |
| `set_max_thinking_tokens` | `/effort`-style TUI control | Control request (45.17) | P | |

---

## 11.L Token, cost, duration and the `result` frame

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `turn_duration` system record | Display record gated by setting `showTurnDuration`; carries `durationMs`, `budgetTokens/Limit/Nudges`, `messageCount`, `pendingBackgroundAgentCount`, `pendingWorkflowCount`, and `briefHiddenCount` (11.14.4) | 45.9.1 "internal surfaces" row — not an enumerated stdout frame | D | The pending-background-agent and pending-workflow counts have no wire twin; `background_tasks` control request substitutes for the former. |
| `result.duration_ms` / `duration_api_ms` / `ttft_ms` / `ttft_stream_ms` / `time_to_request_ms` | Not shown per-turn in the TUI | All on the `result` frame (45, `chunk-sct99ax9.js:673390`) | P → exceed | The GUI can show per-turn latency breakdowns the TUI never surfaces. |
| `result.total_cost_usd` / `usage` / `modelUsage` | `/cost` command | On `result`; also `get_session_cost` and `get_usage` control requests | P | `modelUsage` per model carries `costBasis` (`list`/`managed`/`unknown`), `canonicalModel`, `provider`, `contextWindow`, `maxOutputTokens`, `thinkingTokens` — richer than `/cost`'s TUI output. |
| `result.permission_denials` | Not surfaced as a list in the TUI | On `result`; documented as **the authoritative record** (the `system/permission_denied` frames are best-effort advisories) (45.14) | P → exceed | A GUI should show an end-of-turn "N tool calls were denied" affordance. |
| `result.terminal_reason` | Not surfaced | 19 values: the 15 of `bre` plus `budget_exhausted`, `structured_output_retry_exhausted`, `tool_deferred_unavailable`, `turn_setup_failed` (11.4.4, 45) | P | Map to GUI end-of-turn states. `aborted_streaming`/`aborted_tools` = user aborted; `completed`/`max_turns`/`background_requested`/`tool_deferred`/`hook_stopped`/`stop_hook_prevented` = not errors (`bEt`); the rest are errors. |
| `result.stop_reason` | — | On `result`; `tool_deferred` is written in place of the model's stop reason for a deferred-tool exit (45.9.2) | P | `pause_turn` and `compaction` exist in the advisor enum only and have no main-loop handling (11.7.10, Open questions) — a GUI should treat an unknown `stop_reason` as end-of-turn. |
| `result.num_turns` / `queued_turn_count` / `subagent_stats` / `structured_output` / `deferred_tool_use` / `fast_mode_state` | — | On `result` | P | |
| `<total_tokens>` reminder | Model-facing only; in `padded-countdown` mode the number is a **synthetic budget**, not the real context window (11.10.2) | Real numbers via `get_context_usage` | P | Do not scrape `<total_tokens>` for a context gauge — it is fictional by design. |
| Usage-limit grace companions (`[Usage limit reached — grace window active. Wrap up: …]`) | `turnCompanion` `isMeta` messages plus, on the near-limit path, a `system` warning (11.14.3) | The `system` warning reaches the wire as `system/informational`; the companions do not (isMeta) | P | Also `rate_limit_event` frames (45.9.1). |

---

## 14.A The tool interface's rendering hooks — one row per hook

Critical structural fact for a GUI: **only `renderToolUseMessage` (73 sites) actually lives on the
tool object.** The other five renderers live in the UI side-table `LT`, keyed by `uiTableKey ?? name`
and resolved by `Ap(tool, member)` (14.4.1 `chunk-vp8nzhw3.js:764729`). The only factory site that
sets all five on the tool is the permanently-disabled `TestingPermission`, which returns `null` from
each (14.4.8). None of these functions, and none of their output, crosses the wire.

| Hook | What the TUI derives from it (SPEC §) | Headless equivalent | Class | Notes / what a GUI must reimplement |
|---|---|---|---|---|
| `renderToolUseMessage(input, {verbose, columns})` | The tool-call header line, e.g. the command for Bash, the path for Read. Returning `null` suppresses the line entirely — `ToolSearch`, `EnterPlanMode`, `TaskGet/Update/List`, `ListAgents` do this (14.4.8) | Nothing. The GUI gets `tool_use.name` + raw `input` JSON | **R** | Must be reimplemented **per tool**. Start with the ~15 the user sees most (Bash, Read, Edit, Write, Glob, Grep, WebFetch, WebSearch, Task/Agent, TodoWrite, Skill, NotebookEdit, MCP generic). For unknown tools, fall back to a JSON summary. Also reimplement the `null` suppressions or the GUI shows noise rows the TUI hides. |
| `renderToolUseProgressMessage(progressMsgs, …)` | Live sub-rows while a tool runs. In `LT` for: `Agent`, `Bash`, `AskUserQuestion`, `TaskOutput`, `PowerShell`, `WebFetch`, `WebSearch`, `REPL`, `SearchMcpRegistry`-family and the artifact family (`cli.pretty.js:764687-764714`). `hook_progress` entries are filtered out before it runs (`cli.pretty.js:764949`) | `progress` records only reach stdout as `tool_progress` for Bash/PowerShell **under `CLAUDE_CODE_REMOTE`/`CLAUDE_CODE_CONTAINER_ID`**; heartbeats and subagent retries always (45.9.1) | **D** for Bash/PowerShell locally; **P** for subagent progress with `--forward-subagent-text` | The single most visible tool-rendering gap: locally, a long `Bash` command shows no streaming output in the GUI while the TUI streams it. Workaround: set `CLAUDE_CODE_CONTAINER_ID` in the child process environment to unlock `tool_progress`. Verify empirically before relying on it. |
| `renderToolResultMessage(data, progressMsgs, {verbose, theme, tools, style})` | The result body: diff for Edit, file preview for Read, output block for Bash, agent transcript for Agent. Present in `LT` for ~25 tools | The wire `user` frame's `tool_use_result` carries the tool's **full structured Output object** (45.12.2), not the string sent to the model | **R** (data is on the wire) | This is the good news: a GUI has *better* raw material than the model does. It must write a renderer per tool over `tool_use_result`. Note `Bash`'s result renderer reads `progressMessages.at(-1).data.timeoutMs` (`cli.pretty.js:779643`) — that timeout is only in a progress record, so it is lost locally. |
| `renderToolUseRejectedMessage(…)` | The "rejected" row after a permission denial. In `LT` for `AskUserQuestion`, `Edit`, `Write`, `NotebookEdit`, `WebSearch`, `REPL`, the artifact family | `tool_result_meta.non_execution_kind` on the `user` frame distinguishes `user-rejected` / `permission-rule` / `automode-blocked` / `interrupted` / `cancelled` (45.12.2); `system/permission_denied` frames carry `tool_name`, `tool_use_id`, `decision_reason_type`, `decision_reason`, `message` | **P → R** | The *classification* is on the wire and is finer-grained than the TUI's. Only the visual form must be rebuilt. A GUI can exceed the TUI by showing `decision_reason`. |
| `renderToolUseErrorMessage(result, {verbose, progressMessagesForMessage, tools})` | The error row. In `LT` for most tools | The error text is in the `tool_result` block (`is_error: true`), often wrapped `<tool_use_error>…</tool_use_error>` (14.16 step 9) | **R** | Reimplement; strip the `<tool_use_error>` wrapper for display. |
| `renderToolUseQueuedMessage()` | A dim `Waiting…` line for a tool call queued behind a non-concurrency-safe one. **Only two tools have it**: `Bash` (`chunk-0tx8z8kt.js`, body at `cli.pretty.js:779640` — literally `<Text dimColor>Waiting…</Text>`) and `PowerShell` (`chunk-vd0z14a4.js`). Call site `UP()` at `cli.pretty.js:764959` | Nothing on the wire distinguishes "queued" from "running" | **R** | Derive: a `tool_use` whose id is not in the derived in-progress set and has no result yet. Trivial to reproduce (it is one dim word). |
| `userFacingName(input?)` | The tool-name chip. Input-dependent for several: `EnterWorktree` → `Entering worktree` / `Creating worktree`; `ExitWorktree` → `Cleaning up worktree` / `Exiting worktree`; `Projects` → `Project: <name>`; MCP tools → `<server> - <title\|toolName> (MCP)`; `ToolSearch` and other invisible tools → `""` (14.4.1) | The `can_use_tool` control request carries `display_name`, but that is `u3(name)` — a **generic prettifier** (`mcp__srv__do_thing` → `Do Thing`, `cli.pretty.js:92666`), *not* `userFacingName` | **D** | The wire's `display_name` differs from the TUI label for every tool with an input-dependent or MCP name. A GUI must build its own name table, including the `""` cases that suppress the chip entirely. |
| `userFacingNameBackgroundColor` | Only `Agent` sets it (`pKe`) — colours the agent chip by agent type (14.4.8, `cli.pretty.js:764812`) | Not on the wire | R | Cosmetic; derive from `subagent_type` on forwarded subagent frames. |
| `getActivityDescription(input)` | The spinner's verb for the running tool. 13 sites. Resolved through `qw()` (coerce + zod parse) first, so a malformed input yields no description (14.4.8 `LBt`) | Not on the wire | **R** | Needs a per-tool verb table. Modest effort, high polish payoff. |
| `getToolUseSummary(input)` | One-line summary for collapsed views. 15 sites | Not on the wire. Separate mechanism: the `tool_use_summary` **frame** (11.2.9) is a model-generated batch label, gated by `CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES` | R + P | Two different things with confusable names. The frame is free if the env var is set; the per-call summary is not. |
| `extractSearchText(input)` | Text the transcript search indexes. 10 sites (`Glob`, `Grep`, `Write`, `WebSearch`, the three memory tools, `Read`, `Poll`, `SendMessage`); the memory tools return `""` **to stay out of the index** (14.4.8) | Not on the wire | R | If afleet builds transcript search, reproduce the memory tools' opt-out or memory contents become searchable — arguably a privacy regression. |
| `isTransparentWrapper` | Only `REPL`. Tells the renderer the frame is a container for nested tool calls and must not be drawn as a leaf (14.4.8) | Not on the wire | D | Without it, a GUI draws REPL as a normal leaf tool and loses the nesting. Hard-code the one case. |
| `isResultTruncated(data, {columns})` | Shows a "truncated / show more" affordance. 5 sites: the three MCP-resource tools, `PowerShell`, the MCP prototype | Not on the wire | R | The GUI can decide truncation itself from `tool_use_result` size. |
| `isSearchOrReadCommand(input)` → `{isSearch, isRead, isList?}` | Drives **transcript collapsing** of consecutive search/read calls. 4 sites: `Glob`, `Grep`, `Read`, `PowerShell` (14.4.5) | Not on the wire | R | Needed to reproduce the TUI's tidy collapsed read/search groups. |
| `uiTableKey` | Routes renderer lookup: MCP prototype → `"mcp"` (one renderer for all `mcp__*`), REPL-registered tools → `"repl-registered"` (14.4.1) | Not on the wire, but derivable from the `mcp__` prefix and the `eval_registered__` prefix | R | Same grouping strategy works for a GUI. |
| `builtinRenderFamily` (`"claude-in-chrome"`, `"computer-use"`) | Special renderers for the two bundled MCP servers (14.4.1) | Not on the wire | D | Only matters if those servers are in use. |
| `renderGroupedToolUse` (`LT[Agent]` only) | Groups a subagent's tool calls under one row (`cli.pretty.js:764687`) | `parent_tool_use_id` on forwarded frames gives the grouping | P/R | The grouping key is on the wire; the layout is not. |

---

## 14.B The registry, the `tools` list, and what a GUI can know about a tool

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| The tool pool | `aD()` = deny-filtered built-ins (sorted by name) ++ deny-filtered MCP tools (sorted by name), deduped by name, **built-in wins a collision** (14.6.3) | `system/init.tools` — **names only**, `string[]` (45.10.2, `chunk-chr1kh62.js:448058`) | **D for metadata, P for membership** | Verified against the live 2.1.259 capture: 42 entries, plain names, `Agent` mapped to `Task` by `mrt`, MCP tools present as full `mcp__server__tool` names. There is **no description, no `inputSchema`, no `searchHint`, no `isReadOnly`, no `shouldDefer` flag** anywhere on the wire. |
| Tool descriptions / schemas for built-ins | The TUI does not show them either (they are model-facing) | Not obtainable | X | Neither surface shows them; not a gap. Listed because a GUI that wants a tool inspector cannot build one. |
| MCP tool descriptions / schemas | Not shown in the TUI's transcript; `/mcp` shows the server list | `mcp_status` control response returns, per server, `{name, status, serverInfo?, config, scope, tools?: [{name, annotations}]}`. **Verified live**: `annotations` carries `readOnly` at most; **no descriptions and no input schemas** | **D** | Corrects a common assumption: `mcp_status.tools` does *not* carry schemas. What it does give is per-tool `annotations.readOnly`, which is the one place a GUI can source a read-only badge — for MCP tools only. The bare tool name is returned; the GUI must apply the sanitiser (`[^a-zA-Z0-9_-] → _`, plus the `"claude.ai "` prefix special case, 14.14.1) and the `mcp__<server>__<tool>` join to match the name in `init.tools`. Confirmed by the live capture: server `plugin:chatgpt-advisor:advisor` + tool `advisor_ask` → `mcp__plugin_chatgpt-advisor_advisor__advisor_ask`. |
| Tool aliases | Nine tools accept legacy names at dispatch (`Agent`←`Task`, `TaskStop`←`KillShell`/`KillBash`, `SendUserMessage`←`Brief`, `TaskOutput`←4 names, the three MCP-resource tools, `Workflow`←`RunWorkflow`, `ListAgents`←`ListPeers`) (14.4.1). Aliases are never emitted to the API | `initialize.toolAliases` is a **host-supplied** map (wire name → canonical name) threaded into `wr()` as the third argument (14.5.1); the CLI does not publish its own alias table | **R** | Two independent alias tables exist: the per-tool `aliases` arrays, and a static 12-entry canonicalisation map used when parsing permission rules (`chunk-hwzew3kw.js:550002`). They agree entry-for-entry **except** `Workflow`'s `RunWorkflow`, which has no rule-map entry — a rule written `RunWorkflow(...)` binds to nothing. A GUI that offers rule editing must reproduce the rule map, not the tool map. Also: `system/init.tools` reports `Task`, not `Agent` — a GUI matching names must handle that. |
| Alias fallback at dispatch | A tool absent from the session pool is still reachable by one of its built-in aliases (14.5.2) | Invisible | X | |
| `EndConversation` rule exemption | Permission rules can never match it (`WXe`, 14.5.3) | Invisible | X | A GUI's rule editor should hide it from tool pickers. |
| Family tools (`familyParentToolName`) | `Artifact` rules cover `ArtifactComments`/`ArtifactData`/`ArtifactCheck` (14.5.4) | Not on the wire | R | Rule-editor fidelity only. |

---

## 14.C Tools unavailable or differently gated in a headless child

From 14.8's `isEnabled` table, restricted to predicates that depend on TTY / entrypoint / remote
environment. Ground truth from the live 2.1.259 `system/init.tools` capture (42 tools) is noted where
it confirms or contradicts.

| Tool | Gate (SPEC 14.8) | Effect on afleet's child | Class | Notes |
|---|---|---|---|---|
| `ProposeGoal` | `!Oe() && !Mn() && !bt() && zct() && SRe() !== "disabled"` — `Oe()` is "non-interactive" | **Disabled** under `-p` | X | Confirmed absent from the live capture. The one-keypress goal-approval affordance is unreachable; the `active_goal` frame and `/goal` still exist for reading goal state. |
| `SendUserMessage` (`Brief`) | `LAe() \|\| ofe()` — brief mode or pewter-owl tool mode | Absent unless brief mode is on, which the GUI cannot turn on | X | See 11.H. |
| `REPL` | `uy()`: `CLAUDE_CODE_REPL` env override, else the `tengu_slate_harbor` gate **for `cli`/`remote` entrypoints only** | Entrypoint-dependent | R | Absent from the live capture. If afleet sets `CLAUDE_CODE_ENTRYPOINT` to something other than `cli`, REPL never enables even for users the gate covers. Set `CLAUDE_CODE_REPL` explicitly if REPL parity matters. **Unverified**: which entrypoint value afleet's spawn produces. |
| `RemoteTrigger` | `Gn() && wt() && !CLAUDE_CODE_REMOTE && Ft("allow_remote_sessions") && Ft(_M)` | Enabled locally (present in the live capture) | P | |
| `propose_skills` | Requires `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE` unset **and** `CLAUDE_CODE_ENVIRONMENT_KIND` unset | Enabled locally unless afleet sets either | P | Do not set those env vars unless you mean to disable it. |
| `EnterWorktree` deferral | Never-deferred when `CLAUDE_CODE_SESSION_KIND === "bg"` (14.11.2 `mZn`) | Behaviour differs if afleet sets `bg` | P | Cosmetic (deferral only). |
| `Bash` | Structural `cs()` — non-Windows, or Windows with bash present | Enabled on macOS | P | |
| `PowerShell` | `Zk()` — off macOS only when `CLAUDE_CODE_USE_POWERSHELL_TOOL === true` | Disabled | P | |
| `Glob`, `Grep` | Removed by `Hue()` when `Ky() && cs()` (the "use find/grep through Bash" preference), then conditionally re-added by `DC()` | **Absent from the live capture** | P | A GUI showing a tool palette must read `init.tools`, not a hard-coded list. |
| `TodoWrite` | `!ly() && UM()` — off when the Task tools are on | Absent from the live capture (Task tools present) | P | |
| `AskUserQuestion` | `bwe()` | Present in the live capture; headless it surfaces through `can_use_tool` | P | |
| `WebFetch` | `Ft(jAe)` entitlement, plus possible delegation to the `web-fetch` subagent (`Nq`) | Present | P | If delegated, the "no such tool" steer explains it (14.16.1). |
| `WaitForMcpServers` | Re-added by `DC()` when a server is still pending and `ToolSearch` is absent | Situational | P | |
| `TestingPermission` | `isEnabled()` → `false`, permanently | Never present | X | |
| `--restricted` flag | Removes Bash/PowerShell/REPL/the code-running tools and WebFetch unless `--tools` names them; ignores user/project/local settings; confines file tools to working dirs; refuses `bypassPermissions` (14.9.1) | A launch-flag choice for afleet | P | Worth surfacing as a "sandboxed session" toggle in the GUI. |
| `bash_output_audience_note` attachment | Requires an **interactive** session (`!Oe()`) (11.9.15) | Never injected headless | X | Model-behaviour difference only: the model is not told the user cannot see long Bash output. Since a GUI *can* show full Bash output, this is arguably correct — but only if the GUI actually renders it (see 14.A `renderToolUseProgressMessage`). |
| "This session is non-interactive" MCP-auth reminder | The `deferred_tools_delta` needs-auth text explicitly tells the model it cannot run OAuth here (11.9.15, 14.11.9) | Always the headless text | D | The GUI **can** run the OAuth flow (`mcp_authenticate`, `mcp_oauth_callback_url` control requests, 45.17), so the model is being told something false. Opportunity: afleet should surface an "authorize this server" button and the model's advice will be wrong. No protocol fix available; accept it. |

---

## 14.D Tool narrowing (`--allowedTools`, `--disallowedTools`, `--tools`, deny rules)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Bare `--disallowedTools Bash` | Removes `Bash` from the registry entirely; it never reaches `tools[]` (14.9.3) | Same; the tool is absent from `system/init.tools` | P | |
| Scoped `--disallowedTools "Bash(git *)"` | The tool **stays** on the wire; the rule is enforced at call time (`qXe` returns false for any rule with a `ruleContent`, 14.9.3) | Same | P | A GUI's "disable this tool" UI must know the difference, or a scoped rule will look ineffective. |
| `--tools` | Expands to a `toolsNarrowing` deny list of every built-in *not* named; `"default"` / `preset:default` restore all; `PowerShell`, `Glob`, `Grep` are force-added to the deny list when the preset was not used (14.9.2) | Same | P | |
| `--allowedTools` with a wildcard | Rejected per entry: `Ignoring --allowedTools rule "<rule>": <error>. <suggestion>.` (14.9.2); the general message is `Wildcard tool name "<name>" is not supported in allow rules` + `An allow pattern must name the scope it widens — globs are permitted only in the tool position after a literal mcp__<server>__ prefix. Deny and ask rules accept wildcards anywhere` (14.9.4) | stderr / startup warning | R | A GUI's rule editor should validate before launch and show these messages itself. |
| Managed-settings suppression | `Ignoring --allowedTools <rules>: permission rules are restricted to managed settings (allowManagedPermissionRulesOnly).` (14.9.2) | Startup message | R | |
| Alias expansion disabled for `cliArg` / `toolsNarrowing` | `return e.source !== "cliArg" && e.source !== "toolsNarrowing"` (14.9.4) | Same | P | A GUI writing `Task(...)` as a CLI arg will **not** match `Agent`. Canonicalise before passing. |
| Changing the allowed/disallowed set mid-session | Not possible in the TUI either (settings edit + restart) | **There is no control request for it** (14.9.6) | D | `update_settings` (localSettings only) and `apply_flag_settings` exist but the chapter is explicit: no protocol path for the allowed/disallowed sets. A GUI's "disable this tool" toggle requires a session restart. Real product constraint. |
| MCP server-level rules | `mcp__github` and `mcp__github__*` cover a whole server; `mcp__github__get_*` globs within it; **server names may not be globbed** (14.9.4) | Same | P | |
| Agent/skill tool narrowing | A **different** mechanism (`Hde()`): exact names + family/V1 expansion + MCP server-prefix denies, **no glob matching at all** (14.9.5) | Same | P | A GUI editing agent frontmatter must not offer globs. |

---

## 14.E Deferred tools and `ToolSearch`

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Deferral is on by default | `ENABLE_TOOL_SEARCH` unset → mode `"tst"`, deferral always on (14.11.1). Every MCP tool is deferred (`cfe()` returns `false` in this build, 14.11.2) | Same; `ToolSearch` is present in the live `init.tools` capture | P | Consequence for the GUI: **most MCP tools are not callable until the model runs `ToolSearch`.** A tool-palette UI built from `init.tools` will list tools the model cannot immediately invoke. |
| `ToolSearch` transcript row | `userFacingName: () => ""` and `renderToolUseMessage() → null` — **the TUI shows nothing at all** for a ToolSearch call (14.11.3) | The `tool_use`/`tool_result` pair is on the wire like any other | P → decision | A GUI that renders every tool call will show rows the TUI deliberately hides. Recommend matching the TUI (hide), or showing a collapsed "loaded N tools" chip. |
| `ToolSearch` result blocks | Returns `tool_reference` blocks, not text (14.11.7) | On the wire inside `tool_result.content` | P | A GUI must handle the `tool_reference` block type or it will render an empty result. Useful signal: these are exactly the tools that just became callable. |
| `ToolSearch` no-match text | `No matching deferred tools found` plus up to three appended notes about connecting / failed / policy-blocked MCP servers (14.11.7, full texts in the chapter) | On the wire as the tool result text | P | |
| Deferred-tool announcements | `deferred_tools_delta` attachment: "now available via ToolSearch", "just became available and are ready to use", re-added / removed / retracted / needs-auth / failed / policy-blocked / still-connecting sections, plus the ambient-context footer (14.11.9) | **Attachment dropped** (11.F). `system/init.tools` per turn is the only wire view | R | Diff consecutive `init.tools` lists to reproduce added/removed. The **retraction causes** (`policy_blocked`, `org_blocked`, `denied`, `disabled`, `not_configured`, `Source removed`, 14.11.9) are not derivable — but `mcp_status` gives per-server `status`, which covers most of them. |
| Periodic usage reminder | `Some available tools' schemas are not loaded in this conversation yet: … use ToolSearch…` every 15 turns (14.11.10) | Model-facing only; not rendered in either UI | X | |
| Schema-not-sent repair hint | On a zod failure for a tool whose schema was never sent: `This tool's schema was not sent to the API — … Load the tool first: call ToolSearch with query "select:<TOOL>", then retry` (14.11.11) | Appears in the `tool_result` error text | P | Render it; it explains an otherwise baffling failure. |
| `DeferredToolPlaceholder` | `Reserved placeholder that keeps deferred tool loading active; never call this tool.` Spliced one position before the end of `tools[]` (14.12.3) | Never in `init.tools` (it is a bare API schema, not a tool object) | X | If the model ever calls it, show the error; no special handling. |
| Discovery bookkeeping across compaction | `extractDiscoveredToolNames` scans the transcript for `tool_reference` blocks, surfaced `deferred_tools_delta` names, and `compact_boundary.compactMetadata.preCompactDiscoveredTools` (14.11.12) | The `tool_reference` blocks are on the wire; the compact-boundary metadata is not projected | R/D | A GUI tracking "which tools are loaded" loses the pre-compaction carry-over. Cosmetic. |
| MCP refresh-and-wait | On no match, one refresh + up to 5 s of 50 ms polling for targeted pending servers (14.11.6) | Invisible; the tool call simply takes longer | P | |
| `tst-auto` threshold mode | `ENABLE_TOOL_SEARCH=auto:N` — deferral only when deferred-tool tokens exceed N% of the context window (14.11.8) | A launch-env choice | P | afleet could set `auto:10` to give small-MCP users inline schemas and immediate callability. Worth considering. |

---

## 14.F Concurrency, result size, and permission-relevant members

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `isConcurrencySafe(input)` | The scheduler's batching predicate; default **false**, so unknown tools serialise (14.2, 14.4.5). `Bash`, `PowerShell`, `TaskOutput` define it as `this.isReadOnly?.(e)` | Not on the wire | R | Only matters for the "Waiting…" queued row (14.A). Derivable in practice from arrival order. |
| `isReadOnly(input)` | Feeds plan-mode admission, mutation bookkeeping, and **the UI collapse logic** (14.4.5) | Not on the wire for built-ins; for MCP tools, `mcp_status.tools[].annotations.readOnly` (verified live) | **D** for built-ins, **P** for MCP | The permission dialog's read-only badge cannot be built for built-in tools from the wire. Hard-code the table from SPEC 14.7's RO column (it is complete: 65 of 82 sites). |
| `isDestructive(input)` | Feeds the permission-dialog wording. Five sites: `ExitWorktree`, `Projects`, the artifact addon family, `ShareOnboardingGuide`, `DesignSync` (14.4.5); MCP tools get it from `annotations.destructiveHint` | `can_use_tool` does **not** carry it (the payload is `tool_name`, `display_name`, `input`, `description?`, `permission_suggestions?`, `blocked_path?`, `decision_reason?`, `decision_reason_type?`, `matched_ask_rule?`, `classifier_approvable?`, `tool_use_id`, `agent_id?`, `suppress_always_allow_rule?`, `default_to_no?`, `requires_user_interaction?`, 45.19) | **D** | Same fix: hard-code the five names. MCP `destructiveHint` is not in `mcp_status`'s `annotations` either (live capture shows only `readOnly`). |
| `getPath(input)` | The filesystem path a call touches, used for working-directory rules and the "outside read" first prompt (14.4.6). 11 sites | `can_use_tool.blocked_path` covers the blocked case only | **D** | For a GUI dialog that wants to show "will write to ~/foo/bar.ts", reimplement `getPath` for the 11 tools (`Edit`, `Glob`, `Grep`, `Write`, `NotebookEdit`, `LSP`, `Read`, the artifact family, `CronDelete`, `self_hosted_runner_tail_log`, `CronCreate`) — or read the path out of the raw `input` using each tool's `ruleContentField` (`Bash`→`command`, `Read`/`Edit`/`Write`→`file_path`, `NotebookEdit`→`notebook_path`, `WebFetch`→`url`, `LSP`→`filePath`), which is a smaller table. |
| `suppressesAlwaysAllowRule` | Hides the "always allow" option in the prompt | **On the wire** as `suppress_always_allow_rule` (45.19) | P | Honour it: hiding "always allow" is a safety affordance. |
| `requiresUserInteraction()` | Forces `ask` that neither auto mode nor an allow rule can bypass. `ExitPlanMode`, `ShowOnboardingRolePicker`, `AskUserQuestion`, plus MCP tools with the `_meta` flag (14.4.5) | **On the wire** as `requires_user_interaction` | P | A GUI must not auto-answer these. |
| `default_to_no`, `classifier_approvable`, `matched_ask_rule`, `decision_reason` (may carry ANSI escapes — sanitise, 45.19) | Dialog defaults and the consent line | On the wire | P → exceed | The TUI's dialog does less with `matched_ask_rule` than a GUI could. |
| `permissionCheckFailureDecision` fail-closed message | `The <tool> permission check failed and its fail-closed posture could not be determined. The call is denied.` (14.4.6) | Arrives as the tool_result error / `permission_denied` message | P | |
| `maxResultSizeChars` and persistence | Effective cap = `min(maxResultSizeChars, persistenceThresholdCeiling ?? 50000)`, or a `tengu_velvet_ibis` per-tool override, or `400000` when unset; `Infinity` (Read, the three memory tools) disables persistence entirely. Over-cap results are written to disk and replaced with a `<persisted-output>`-wrapped 2000-byte preview (14.4.7) | The GUI sees the **truncated** `tool_result` content and the `<persisted-output>` wrapper, including the on-disk path | **P → exceed** | Big opportunity: the wrapper names the file on disk, so a GUI can offer "open full output" — the TUI shows only the preview. Verify the path is inside the session's `tool-results/` dir before opening. |
| `tengu_tool_result_persisted` / `tengu_tool_empty_result` | Telemetry only (14.17) | — | X | |
| `<tool_use_error>` wrapper | Wraps `validateInput` failures and no-such-tool errors (14.4.3, 14.16) | On the wire inside `tool_result` | R | Strip for display. |
| "No such tool" steers | 11 context-specific explanations (`REPL`-absorbed, subagent-restricted, `SendUserMessage` disabled, coordinator delegation, WebFetch→Artifact, WebFetch→subagent, disconnected provider, disabled, `Glob`/`Grep` hidden, MCP connecting, 11 MCP bad-state messages) (14.16.1) | All arrive as the tool_result error text | P | Render them verbatim; they are genuinely explanatory. |
| Unparsed-JSON guard message | `InputValidationError: <TOOL> was called with input that could not be parsed as JSON. / You sent (first N of M bytes): <prefix> / Common causes: …` (14.16 step 5) | On the wire | P | |
| MCP description injection canary (`tengu_mcp_description_contains_toolcall_xml`) | Telemetry only; not user-visible (14.17) | — | D (opportunity) | Nothing surfaces a prompt-injection-shaped MCP description to the user on either surface. A GUI could warn. |
| MCP schema drop / degrade | A dropped MCP tool is announced to the model as `mcp_dropped_tools_delta`; with the gate off (the shipped default) an invalid schema is **kept verbatim** and the API may 400 (14.12.6) | Attachment dropped; `mcp_status` shows the server as connected with the tool present | D | A GUI cannot tell the user "this MCP tool has a schema the API will reject". Low frequency. |

---

## Top gaps in this area

Ranked by user-visible impact on afleet.

1. **Per-tool rendering must be rebuilt wholesale (14.A).** Six renderer hooks, plus
   `userFacingName`, `getActivityDescription`, `getToolUseSummary`, `isSearchOrReadCommand` and
   `isTransparentWrapper`, are pure client-side code and none of their output crosses the wire. The
   raw material is better than the model's (`tool_use_result` is the full structured Output object),
   but every tool row a user sees is afleet's to write. Class **R**, unavoidable, and the single
   largest work item in these two chapters.
2. **Local Bash/PowerShell progress is not on the wire (14.A / 11.A).** `tool_progress` frames are
   emitted only when `CLAUDE_CODE_REMOTE` or `CLAUDE_CODE_CONTAINER_ID` is set (45.9.1). A long
   `Bash` command streams live in the TUI and shows a static row in the GUI. Class **D** with a
   named workaround: set `CLAUDE_CODE_CONTAINER_ID` in the child environment. Test this before
   depending on it.
3. **Message retraction is only half-signalled (11.B `tombstone`).** The TUI deletes messages from
   the transcript on refusal fallback, model-chain advance, malformed-tool-use retry and orphan
   repair. The wire carries `supersedes` / `retracted_message_uuids` for the refusal path only. The
   other three paths leave the GUI showing phantom messages. Class **D**; a protocol addition
   (`tombstone` passthrough) would fix it cleanly.
4. **The refusal-continuation collapser has no wire twin (11.B / 11.E).** `refusal_continuation`
   carries the salvage text and an `exact`-join hint that let the TUI merge a re-streamed
   continuation into the partial text already painted. Without it a GUI shows duplicated text after
   a refusal fallback. Class **D**, and the highest-value single protocol addition for text fidelity.
5. **~31 TUI-visible attachment types vanish (11.F).** Only `queued_command`, `hook_system_message`
   and `tool_host_result_lines` become wire frames. Lost outright: file-changed-on-disk notices,
   truncated-read notices, diagnostics blocks, MCP resource previews, nested-memory and
   invoked-skill listings, command-permission rows, the eight hook outcome rows (partly recoverable
   via `--include-hook-events`). Class **D/R** case by case.
6. **No tool metadata on the wire at all (14.B).** `system/init.tools` is `string[]`; `mcp_status`
   returns `{name, annotations}` per MCP tool with `readOnly` at most — **verified live, no
   descriptions and no schemas**. Read-only and destructive badges for built-ins, `getPath` for
   dialog previews, and any tool-inspector UI must come from a hard-coded table transcribed from
   SPEC 14.7 / 14.4.5 / 14.4.6. Class **D**, mitigated by the spec being complete.
7. **`display_name` on `can_use_tool` is not `userFacingName` (14.A).** It is `u3()`, a generic
   prettifier, so `mcp__openaiDeveloperDocs__search_openai_docs` becomes `Search Openai Docs` rather
   than `openaiDeveloperDocs - Search OpenAI Docs (MCP)`, and `EnterWorktree` never says
   "Creating worktree". A GUI that trusts `display_name` will look subtly wrong in the dialog. Class
   **D**; fix with a client-side name table.
8. **`/btw` and `/brief` are `local-jsx` and therefore unreachable (11.H).** `/btw`'s *capability*
   survives as the `side_question` control request — with progress frames and cancellation, so a GUI
   can exceed the TUI — but the panel, the fallback texts and the `btwHistory` threading are
   afleet's to build. `/brief` has no control-protocol path at all, so brief mode cannot be entered
   or even observed. Class **R** / **X**.
9. **`os_notification` is dropped (11.B).** The TUI's desktop-notification trigger does not cross
   the wire. afleet must implement its own idle/attention policy — which it can do better, since it
   knows real macOS focus state. Class **D** with an upside.
10. **The tool allow/deny sets cannot be changed mid-session (14.D).** SPEC 14.9.6 is explicit that
    no control request exists. A GUI "disable this tool" toggle requires a relaunch. Class **D**;
    plan the UX around session restart.
11. **Deferred tools mean `init.tools` overstates immediate availability (14.E).** Deferral is on by
    default and every MCP tool is deferred, so a palette built from `init.tools` lists tools the
    model must `ToolSearch` for first. Consider launching with `ENABLE_TOOL_SEARCH=auto:10` so small
    MCP setups ship schemas inline. Class **P** with a configuration decision attached.
12. **`hint_clears` is dropped (11.B).** Content the server retracts stays on screen in the GUI.
    Low frequency, no workaround. Class **D**.
13. **`response_length` blind spot during compaction (11.B).** The token counter freezes while a
    compaction summary streams, because that stream is invisible to the host. Class **D**, cosmetic.
14. **`isSynthetic` conflates three provenances (11.G).** `isMeta`, `isVisibleInTranscriptOnly` and
    `isCompactSummary` collapse into one boolean, so a GUI cannot show compact summaries while
    hiding harness nudges without heuristics. Class **D**, minor.
15. **`ProposeGoal` is disabled non-interactively (14.C).** The one-keypress goal-approval affordance
    is unreachable headless; goal *state* is still readable via `active_goal`. Class **X**.

---

## Unverified

* **Which `CLAUDE_CODE_ENTRYPOINT` value afleet's spawned child reports.** This decides `REPL`
  availability (`uy()` gates on `cli`/`remote` entrypoints, 14.8) and affects `Mit()`'s telemetry
  name collapsing (14.5.5). Not determinable from the spec or the captures; measure it.
* **Whether setting `CLAUDE_CODE_CONTAINER_ID` in the child environment actually unlocks
  `tool_progress` for local Bash without other side effects.** Inferred from SPEC 45.9.1's gating
  clause; not tested. Other behaviour keyed on container/remote environment variables (e.g.
  `propose_skills`' `CLAUDE_CODE_ENVIRONMENT_KIND` check, `autocompact_state` frames) may change
  too.
* **`LAe()` / `ofe()` (the `SendUserMessage` gate) and `bwe()`, `Vo()`, `yP()` and the other
  `isEnabled` predicates** are recorded by SPEC 14.8 as call sites only; their definitions were not
  resolved (the chapter's own Open questions say the same). The claim "brief mode cannot be entered
  headless" rests on `/brief` being `local-jsx` plus the live capture showing `SendUserMessage`
  absent — not on reading `LAe()`.
* **Whether any `system/turn_duration` or `system/stop_hook_summary` frame reaches stdout.** SPEC
  45.9.1 files them under a catch-all "internal surfaces" row rather than giving them their own
  emission condition; I read that as "not emitted", but the row's phrasing is ambiguous and I did
  not trace `Cu` line by line for these two subtypes.
* **The exact set of `LT` side-table entries.** I read `cli.pretty.js:764687-764717` and identified
  the tools with `renderToolUseQueuedMessage` (only `Bash` and `PowerShell`) and the shape of the
  `Agent` entry, but the table uses lazy getters and interpolated name constants; a complete
  tool→renderer matrix would need each `chunk-*` module resolved individually.
* **`decidingInputFields`** on the four remote-capable tools has no reader anywhere in the bundle
  (SPEC 14 Open questions); I have repeated the spec's inference rather than verified semantics.
* The live captures are from **2.1.259** while the SPEC describes **2.1.257**. Every live-verified
  claim above (init `tools` shape, `mcp_status` payload, capability list) is stated as a 2.1.259
  observation.
