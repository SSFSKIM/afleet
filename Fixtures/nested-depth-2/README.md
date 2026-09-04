# nested-depth-2

A depth-2 agent run: a `general-purpose` subagent that itself spawns an `Explore` subagent to
search three synthetic files in the scratch cwd for the word `delta`. Recorded against the
pinned baseline `~/.local/share/claude/versions/2.1.259` on 2026-09-04, session
`2b8d665a-ef0a-444e-8144-f9f66e38c817`, `--max-turns 6`, `haiku`, config-home isolation,
exit 0. Serves acceptance items 49 and 52; it is S16's evidence.

**What the run saw** (the notes in `fixture.json`): two `task_started` frames at
`spawn_depth` 1 and 2, two distinct task ids, everything settled before the session closed,
`result/success`, and **depth-2 text or thinking forwarded: True**.

197 frames, including two `task_started`, five `task_progress`, two `task_updated`, two
`task_notification`, four `background_tasks_changed`, twenty-eight `transcript_mirror`, nine
`system/thinking_tokens`, three `system/init` and three `result/success` — one init and one
result per forked agent on top of the session's own.

**The two sidecars, which are what S16 came for.** Both runs have a transcript and a
`.meta.json` under `transcript/_slug_/<session>/subagents/`:

- `agent-a4bd7d1f17a7e8011` — `general-purpose`, 12 records. Sidecar: `agentType`,
  `description`, `toolUseId`, `spawnDepth: 1`. **No `parentAgentId`**, because at depth 1
  there is no parent agent.
- `agent-a558f55cd34e3996f` — `Explore`, 19 records. Sidecar: the same four fields with
  `spawnDepth: 2` **and `parentAgentId: "a4bd7d1f17a7e8011"`**, which is the depth-1 run's
  task id.

So `parentAgentId` is written exactly where §8.8 needs it and only where a parent exists.
Neither sidecar carries `color`, `model`, `permissionMode` or `worktreePath` on 2.1.259.

**Artifacts.** One `<taskId>.output` per run under `artifacts/…/tasks/`, each holding that
run's JSONL transcript, as in `explore-depth-1`.

**A re-engagement the first recording caught and this one did not.** In an earlier recording of
this scenario the engine emitted a second `task_started` for the *same* `task_id` when an
auto-turn re-engaged the backgrounded depth-1 agent, and mirrored a second `agent_metadata`
entry mid-stream with it. The scenario's settle helper compared started and ended ids as sets,
read the earlier notification as having settled the later start, and closed the session two
seconds into the re-engagement — `end_session` under a live agent, which ended that recording
`result/error_during_execution`. `_tasks.py` now counts occurrences rather than comparing sets
and waits for ten quiet seconds, and this recording needed no such allowance. The behaviour is
the engine's, not the scenario's: a host must expect `task_started` more than once per task id.

**Declarations.** `mirror_identity_only: ["subagents/"]`, for the reason recorded in
`explore-depth-1`'s README — a subagent's sidecar file and its mirror are two snapshots of one
record and can disagree on `message.stop_reason` and `message.usage`. This recording agrees
field for field on both streams. The `agent_metadata` entries the mirror carries are checked
against the `.meta.json` sidecars they claim to be. The main stream's 38 records are reproduced
by its mirror exactly.
