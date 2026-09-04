# explore-depth-1

One `Explore` subagent, launched by the model from a single prompt, searching three synthetic
files in the scratch cwd for the word `gamma`. Recorded against the pinned baseline
`~/.local/share/claude/versions/2.1.259` on 2026-09-04, session
`c68633f3-68eb-4f49-bd22-e645fc21d67c`, `--max-turns 4`, `haiku`, config-home isolation,
exit 0. Serves acceptance items 9, 38 and 49 and C3.G3.

**What the run saw** (the notes in `fixture.json`): one `task_started` at `spawn_depth 1`,
every task settled before the session closed, `result/success`. Twenty captured frames carry
a `parent_tool_use_id` — the depth-1 forwarding `--forward-subagent-text` licenses.

137 frames: one `task_started`, seven `task_progress`, one `task_updated`, one
`task_notification`, two `background_tasks_changed`, twenty-five `transcript_mirror`, six
`system/thinking_tokens`, and **two** `system/init` and **two** `result/success` frames rather
than one of each — the forked subagent brings up an init and a result of its own, so a host
counting turns off `result` frames must not read the second as a second prompt.

`task_started` carries `task_id`, `tool_use_id`, `description`, `subagent_type`,
`is_backgrounded`, `spawn_depth`, `task_type: "local_agent"`, `prompt`, `session_id` and
`uuid`: an agent id and a depth, and no parent id, which is what makes §8.8's two-step join
necessary when the sidecar is not yet on disk. `is_backgrounded` is `true` because
`CLAUDE_CODE_FORK_SUBAGENT=1` is on every launch line.

**Transcript.** The main stream holds 33 records. The agent's own transcript is
`transcript/_slug_/<session>/subagents/agent-a8d2040715ad915fb.jsonl`, 29 records, beside its
`.meta.json` sidecar. On 2.1.259 that sidecar holds four fields — `agentType`, `description`,
`toolUseId`, `spawnDepth` — and **none of the five §8.8 expects of it** (`parentAgentId`,
`color`, `model`, `permissionMode`, `worktreePath`). `parentAgentId` does appear at depth 2;
see `nested-depth-2`.

**Artifact.** `artifacts/…/tasks/a8d2040715ad915fb.output` is the file the `task_notification`
names, and its content is the subagent's JSONL transcript. §8.8's reading that the
`<taskId>.output` file is the same file as the run's sidecar transcript is confirmed here.

**Two things about the subagent mirror** that no earlier fixture reached, both visible in this
recording and neither true of the main stream:

- The mirror carries an entry of type `agent_metadata` that the `.jsonl` never receives. It is
  the `.meta.json` sidecar's content with a `type` added, emitted when the agent starts and
  again whenever an auto-turn re-engages it. `verify` holds each one against the sidecar it
  claims to be rather than against the stream's records.
- `mirror_identity_only: ["subagents/"]`. The sidecar file and its mirror are two snapshots of
  the same record taken at different moments: the record that closes an assistant message
  reaches the file with `stop_reason: null` and a partial `usage` on some runs and finalised on
  others, and the file is never rewritten. This recording agrees field for field; an earlier
  recording of this scenario against the same binary diverged on two of eleven records in
  `message.stop_reason` and `message.usage`. The declaration keeps count, order and record
  identity strict — which is what the parent's §7.3 invariant states — and reports any field
  difference as a note on every run.

The main transcript's 33 records are reproduced by its mirror exactly, as in every other
recording in this corpus.

**One review note.** The Explore agent ran `ls -l` in the scratch cwd, so a `tool_result` in
this fixture carries the recording machine's OS account short name in the listing's owner
column. §4.5's rules substitute the home directory and the hostname but say nothing about a
bare account name, which no earlier scenario put on the wire.
