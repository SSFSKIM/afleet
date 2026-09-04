# explore-depth-1

One `Explore` subagent, launched by the model from a single prompt, searching three
synthetic files in the scratch cwd for the word `gamma`. Recorded against the pinned
baseline `~/.local/share/claude/versions/2.1.259` on 2026-09-04, session
`04f72661-7164-4bfa-9adc-196c573d83be`, `--max-turns 4`, `haiku`, config-home isolation.
Serves acceptance items 9, 38 and 49 and C3.G3.

**What the run saw** (the notes in `fixture.json`): one `task_started`, `spawn_depth 1`,
every task settled before the session closed, `result/success`. Five captured frames carry
a `parent_tool_use_id`, which is the depth-1 forwarding `--forward-subagent-text` licenses.
105 frames in all, including one `task_started`, one `task_progress`, one `task_updated`,
one `task_notification`, two `background_tasks_changed`, fifteen `transcript_mirror` frames
and six `system/thinking_tokens`. Two `system/init` frames and two `result` frames are
recorded, not one of each: the forked subagent brings up an init of its own.

`task_started` carries `task_id`, `tool_use_id`, `description`, `subagent_type`,
`is_backgrounded`, `spawn_depth`, `task_type: "local_agent"`, `prompt`, `session_id` and
`uuid` — an agent id and a depth, and no parent id, which is what makes §8.8's two-step join
necessary. `is_backgrounded` is `true` because `CLAUDE_CODE_FORK_SUBAGENT=1` is on every
launch line.

**Transcript.** The main stream holds 33 records. The run's own transcript is
`transcript/_slug_/<session>/subagents/agent-a192e8009027b618d.jsonl`, 11 records, beside its
`.meta.json` sidecar. On 2.1.259 that sidecar holds four fields —
`agentType`, `description`, `toolUseId`, `spawnDepth` — and **none of the five §8.8 expects
of it** (`parentAgentId`, `color`, `model`, `permissionMode`, `worktreePath`).

**Artifact.** `artifacts/…/tasks/a192e8009027b618d.output` is the file the
`task_notification` names, and its content is the subagent's JSONL transcript byte for byte:
§8.8's reading that the `<taskId>.output` file is the same file as the sidecar transcript is
confirmed here on the wire.

**Two declarations this fixture is the first to need**, both about the subagent stream and
neither about the main one:

- `unwritten_prefix: 1`. The mirror for a subagent stream opens with an entry of type
  `agent_metadata` that is never written into the `.jsonl` at all — it is the `.meta.json`
  sidecar's content with a `type` added. So the mirror carries one record the file does not,
  at the head of the range.
- `mirror_identity_only: ["subagents/"]`. The sidecar file and its mirror are two snapshots
  of the same record taken at different moments. The record that closes an assistant message
  reaches the file with `stop_reason: null` and a partial `usage` on some runs and finalised
  on others, and the file is never rewritten afterwards. This recording happens to agree
  field for field; an earlier recording of the same scenario against the same binary diverged
  on two of eleven records in `message.stop_reason` and `message.usage`. The declaration
  keeps count, order and record identity strict — which is what the parent's §7.3 invariant
  states — and reports any field difference as a note on every run.

The main transcript's 33 records are reproduced by its mirror exactly, as in every other
recording in this corpus.
