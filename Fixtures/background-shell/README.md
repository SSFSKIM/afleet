# background-shell

A `Bash` call with `run_in_background=true`, its `task_notification`, the auto-turn that
follows it, and the task's output file bundled under `artifacts/`. Recorded against the pinned
baseline `~/.local/share/claude/versions/2.1.259` on 2026-09-04, session
`9563caff-2896-4050-8c6c-1ede14516b30`, `--max-turns 4`, `haiku`, config-home isolation,
exit 0. Serves acceptance items 61 and 15's data, and C3.G3.

**What the run saw** (the notes in `fixture.json`): the first turn ended `result/success`, a
`task_notification` arrived naming an `output_file`, the auto-turn that followed it ended
`result/success` too, and two `background_tasks_changed` frames were emitted. 87 frames in
all, including one `task_started`, one `task_updated`, one `task_notification`, ten
`transcript_mirror` frames and a 33-record main transcript reproduced by its mirror exactly.

**A background shell is not an agent, and its `task_started` says so.** The frame carries
`task_id`, `tool_use_id`, `description`, `is_backgrounded: true`, `task_type: "local_bash"`,
`uuid` and `session_id` — and **no `spawn_depth` and no `subagent_type`**, both of which a
subagent's `task_started` carries (`explore-depth-1`). A host modelling one shape for the pair
will read a missing depth where there was never a tree.

`background_tasks_changed` carries a `tasks` array of `{task_id, task_type, description}` —
the registry mirror §8.8's *Move to background* action reads — and fires twice, once when the
task starts and once when it ends.

**The artifact, checked by hand.** `task_notification.output_file` is recorded in
`frames.ndjson` as
`<artifacts>/-private-tmp-afleet-fixtures-background-shell/<session>/tasks/bcdsdgryt.output`,
and `artifacts/` holds that exact path. Its content is
`bg-done\n\n[exited with code 0]\n` — the command's stdout followed by an exit line the CLI
appends, so the file is not raw stdout and a consumer parsing it must expect the trailer. The
`tool_result` for the Bash call names the same tokenised path.

**Two `result/success` frames, not one.** The prompt's own reply is the first; the auto-turn
the engine runs after the notification is the second. A host completing a turn on every
`result` frame will count two turns for one prompt.

**`keep_open: true`.** The global constraint forbids `end_session` while a background task is
running, because the stream close kills its shells, and this is the scenario the flag was
written for. No `end_session` control request appears in the capture; the session still exits
0 on stdin close, so the graceful path does not depend on the request.

**One review note.** The `output_file` value inside `fixture.json`'s `notes` is the raw
absolute path rather than the `<artifacts>` token: the scenario reads the frame and writes the
note before `record` tokenises the capture. Nothing under `frames.ndjson` or `transcript/` is
affected, and the raw form is the path's evidence, but a consumer reading `notes` as tokenised
text would be wrong.
