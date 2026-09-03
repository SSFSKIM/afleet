# Live probe: background Bash + subagent over stream-json (claude 2.1.259, 2026-09-03)

Flags as in EVIDENCE-slash-commands.md (includes --forward-subagent-text, --include-hook-events,
initialize with perTaskStopAffordance:true and agentProgressSummaries:true).

## Probe A — one turn: Bash run_in_background + Agent(Explore) that itself calls Bash
Frame sequence (stream_event omitted):

    user (human) → command_lifecycle queued/started → hook UserPromptSubmit → system/init → system/status requesting
    user isReplay=true (the echo)
    assistant [thinking]            parent=null
    assistant [tool_use Bash]       parent=null   (run_in_background=true)
    hook PreToolUse:Bash
    assistant [tool_use Agent]      parent=null
    hook PreToolUse:Agent
    system/task_started {task_id, tool_use_id, description, subagent_type:"Explore", is_backgrounded:false, spawn_depth:1, task_type:"local_agent", prompt}
    user [text]                     parent=<Agent tool_use_id>      ← the subagent's own prompt echoed as a user frame
    system/background_tasks_changed {tasks:[{task_id, task_type:"local_bash", description}]}
    system/task_started {task_id, tool_use_id, description, is_backgrounded:true, task_type:"local_bash"}
    user [tool_result for Bash]     parent=null  tool_use_result={stdout, stderr, interrupted, isImage, noOutputExpected, backgroundTaskId}
                                    content: "Command running in background with ID: <id>. Output is being written to: /private/tmp/claude-501/<slug>/<session>/tasks/<id>.output"
    system/task_progress {task_id, tool_use_id, description:"Running ls …", subagent_type:"Explore", usage:{total_tokens, tool_uses, duration_ms}, last_tool_name:"Bash"}
    hook PreToolUse:Bash            (the SUBAGENT's hook)
    assistant [tool_use Bash]       parent=<Agent tool_use_id>  subagent_type="Explore"   ← SUBAGENT TOOL CALL IS ON THE WIRE
    user [tool_result]              parent=<Agent tool_use_id>                              ← SUBAGENT TOOL RESULT IS ON THE WIRE
    assistant [text]                parent=<Agent tool_use_id>  subagent_type="Explore"
    system/task_updated {task_id, patch:{status:"completed", end_time}}
    system/task_notification {task_id, tool_use_id, status:"completed", output_file:".../tasks/<taskId>.output", summary, usage:{total_tokens, tool_uses, duration_ms}}
    user [tool_result for Agent]    parent=null  tool_use_result={status, prompt, agentId, agentType, harnessNoteCount, harnessTailCount, harnessSectionHash, content, resolvedModel, totalDurationMs}
    assistant [text "Waiting on the background command…"]
    hook Stop ×2
    result/success  (keys: duration_api_ms, duration_ms, fast_mode_disabled_reason, fast_mode_state, is_error, modelUsage, num_turns, origin, permission_denials, queued_turn_count, result, session_id, stop_reason, subagent_stats, subtype, total_cost_usd, type, usage, uuid)
    command_lifecycle completed
    → host sent end_session while the background shell was still running:
    control_response (end_session)
    system/background_tasks_changed {tasks:[]}
    system/task_updated {task_id, patch:{status:"killed", end_time}}
    system/task_notification {task_id, tool_use_id, status:"stopped", output_file, summary}

Findings:
1. With --forward-subagent-text on 2.1.259 a subagent's tool_use AND tool_result blocks are forwarded
   (assistant/user frames with parent_tool_use_id = the Agent tool_use id and subagent_type set), not
   only text/thinking. Nested depth is reported by task_started.spawn_depth.
2. task_progress carries a one-line activity description, last_tool_name and cumulative usage — the
   data behind the TUI's per-agent status line.
3. No agent-progress-summary frame appeared despite agentProgressSummaries:true (short run; unverified
   whether longer runs emit one).
4. end_session kills running background shells (status "killed", notification "stopped").
5. Background shell output is NOT streamed on the wire (no tool_progress for Bash): the only live
   source is the output_file path, which is present in both the tool_result text and task_notification.

## Probe B — background Bash completes AFTER the turn's result (host idle, no end_session for 40 s)

    … turn 1 … assistant [text "started"] → result/success (num_turns=2) → command_lifecycle completed
    (≈6 s later, with NO host input)
    system/background_tasks_changed {tasks:[]}
    system/task_updated {task_id, patch:{status:"completed", end_time}}
    system/task_notification {task_id, tool_use_id, status:"completed", output_file, summary:"Background command \"…\" completed …"}
    hook UserPromptSubmit
    system/init                       ← a NEW TURN starts by itself
    system/status requesting
    assistant [thinking], assistant [text "Background task completed with exit code 0."]
    hook Stop ×2
    result/success (num_turns=1)

Findings:
6. A headless session that stays open delivers background completions and the engine starts an
   unprompted turn (the <task-notification> injection). The injected user message is NOT emitted as a
   `user` frame (replay covers only human-driven messages), so the host sees task_notification and
   then an assistant turn with no visible trigger — the GUI must synthesise the timeline item from
   task_notification.
7. system/init is re-emitted at the start of that auto-turn (consistent with "init per turn").
