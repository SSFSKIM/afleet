# permission-allow

A single `Write` into the scratch cwd, asked through `can_use_tool` and answered
`allow`. Serves acceptance items 4 and 5 and C2.G2; informs no spike.

What it shows:

- Exactly one `can_use_tool` request for the whole turn. Its request object carries
  `description`, `display_name`, `input`, `permission_suggestions`, `subtype`,
  `tool_name` and `tool_use_id`.
- The only suggestion the engine offers for a `Write` in the session's own directory is
  of type `setMode`. There is no `decision_reason_type` field on the request, which the
  scenario's brief expected; see the parent's Revision Notes.
- The host answers `{behavior: "allow", updatedInput: <the request's input>}` and the
  turn completes with `result/success`. The `--replay-user-messages` echo of that answer
  is in the capture, travelling out, as it is in every recording here.
- The transcript holds 29 records for one prompt and one tool call, including a
  `file-history-delta` and a `file-history-snapshot` that the `Write` produced.

Recorded on 2.1.259 under the scratch config home, model `haiku`, `--max-turns 3`.
`initial/` is empty because the session is new; `artifacts/` is empty because nothing
was written outside the transcript.
