# exit-plan-mode

`--permission-mode plan`, a plan presented through `ExitPlanMode`, approved with a
`setMode` update. Serves acceptance item 7; informs no spike. **Outside the census**
(`census: false`) — see the last section.

What it shows:

- The plan-mode turn spends tool calls before the ask: a `Write` of the plan **into the
  config home**, then a `ToolSearch {"query": "select:ExitPlanMode"}` fetching the tool's
  schema, then `ExitPlanMode` itself. `ExitPlanMode` is a deferred tool, so the fetch turn
  is unavoidable — the same shape `send-user-file` records for an SDK MCP tool.
- The plan file is written to `<config home>/plans/plan-<slug>.md`, not into the project,
  and the ask's `input` carries both `plan` (the markdown) and `planFilePath` (that path).
  A host rendering the plan card can use either, but the file it names is inside Claude
  Code's configuration home, which afleet may read and must never write.
- The ask's key set is `display_name`, `input`, `requires_user_interaction`, `subtype`,
  `tool_name`, `tool_use_id`. Like `ask-user-question`'s and unlike `permission-allow`'s,
  it carries no `permission_suggestions`.
- The host answers `allow` with `updatedPermissions: [{type: "setMode", mode:
  "acceptEdits", destination: "session"}]`, and the engine confirms the change with a
  `system/status` frame carrying `permissionMode: "acceptEdits"` and a null `status`.
  That frame is the only acknowledgement of the mode change on the wire.
- After the approval the model goes on to do the work: it lists the directory and writes a
  real `README.md` into the scratch cwd, despite the prompt asking it not to.

Why it is outside the census, and why the reason is general. Approving a plan hands the
work back to the model, so the number of turns the session needs after the approval is the
model's choice, and whether it fits inside `--max-turns` varies run to run. That choice
shows up in the census as the `result` pair: a run that finishes is `result/success`, a run
that does not is `result/error_max_turns`. Both were measured — recorded at five turns the
session capped, and `make probe` re-running the same scenario at five finished — and §4.4
alarms on an added or removed pair in required mode as well as exact, deliberately, so
`deterministic: false` is no escape. This is the rule `rate-limited-turn` and
`resume-no-replay` already sit under, a scenario leaves the census when re-running it
cannot be expected to reproduce what was recorded; the novelty is that the cause here is a
turn count the model picks rather than a precondition the recording consumes. Any capped
scenario whose length the model chooses will meet it.

Recorded on 2.1.259 under the scratch config home, model `haiku`, `--max-turns 5`; the run
ends `result/error_max_turns` with exit code 1, which is where this scenario ends by
nature. Everything item 7 needs is recorded before the cap. `initial/` and `artifacts/`
are empty.

## 2026-09-04: re-redacted in place

The plan-mode session ran `ls -l` in the scratch cwd, and the resulting listing carried the
recording machine's OS account name in its owner column, in `frames.ndjson` and in the session
transcript. No §4.5 rule looked there: an owner column is neither the home directory nor the
hostname nor an identity-named field. `LS_LONG_RE` now redacts the owner and group columns **by
position**, so the rule needs no knowledge of the account name, and `make redact` was re-run
over this fixture. The listing reads `<user>  <group>` and nothing else about the recording
changed. `redaction.json` now records both the recording's own substitutions and the six the
owner-column rule made — fifteen identity substitutions in all — because `redact` adds to the
manifest already on disk rather than replacing it, and no longer counts a substitution that
changes nothing. Re-running `make redact` on this fixture is a byte-for-byte no-op.
