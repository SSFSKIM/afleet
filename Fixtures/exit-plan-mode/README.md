# exit-plan-mode

`--permission-mode plan`, a plan presented through `ExitPlanMode`, approved with a
`setMode` update. Serves acceptance item 7; informs no spike.

What it shows:

- The plan-mode turn costs four tool calls before the ask: a `Bash` look at the
  directory, a `Write` of the plan **into the config home**, a `ToolSearch` fetching
  `ExitPlanMode`'s schema, and then `ExitPlanMode` itself. `ExitPlanMode` is a deferred
  tool, so the fetch turn is unavoidable — the same shape `send-user-file` records for an
  SDK MCP tool.
- The plan file is written to `<config home>/plans/plan-<slug>.md`, not into the project,
  and the ask's `input` carries both `plan` (the markdown) and `planFilePath` (that
  path). A host rendering the plan card can use either, but the file it names is inside
  Claude Code's configuration home, which afleet may read and must never write.
- The ask's key set is `display_name`, `input`, `requires_user_interaction`, `subtype`,
  `tool_name`, `tool_use_id` — like `ask-user-question`'s and unlike `permission-allow`'s,
  it carries no `permission_suggestions`.
- The host answers `allow` with `updatedPermissions: [{type: "setMode", mode:
  "acceptEdits", destination: "session"}]`, and the engine confirms the change with a
  `system/status` frame carrying `permissionMode: "acceptEdits"` and a null `status`.
  That frame is the only acknowledgement of the mode change on the wire.

Why the recording ends `result/error_max_turns` with exit code 1: approving a plan hands
the work back to the model, which immediately starts implementing it — here writing a
real `README.md` into the scratch cwd, despite the prompt asking it not to. The turn
budget was raised from three to five and the run still ended at the cap, so the cap is
where this scenario ends by nature rather than by mis-budgeting. Everything item 7 needs
is recorded before the cap is reached.

Recorded on 2.1.259 under the scratch config home, model `haiku`, `--max-turns 5`.
`initial/` and `artifacts/` are empty.
