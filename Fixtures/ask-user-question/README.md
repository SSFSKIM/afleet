# ask-user-question

An `AskUserQuestion` with two options and previews, answered through
`updatedInput.answers`. Serves acceptance items 6 and 57; the live half of spike S15.

What it shows:

- The question arrives as an ordinary `can_use_tool` request with `tool_name:
  "AskUserQuestion"`. Unlike the `Write` ask in `permission-allow`, it carries
  `requires_user_interaction: true` and carries **no** `permission_suggestions` and no
  `description` — the two asks do not have the same key set, so a host modelling one
  request shape for `can_use_tool` will find fields missing.
- The `input` is `{questions: [{question, header, options: [{label, description,
  preview}], multiSelect}]}`. Both options carry a `preview`, which is what S15 exists to
  confirm: `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=markdown` is on the launch line (it is
  now in `harness.DEFAULT_ENV_TABLE`, per the parent's §6.1 table), and the previews are
  markdown block-character mockups rather than prose.
- The host answers `allow` with the whole input echoed back plus an added
  `answers: {"<the question text>": "<the chosen label>"}` map. The engine accepts that
  as the user's choice and renders it back to the model as a `tool_result` reading
  `Your questions have been answered: "Which colour do you prefer?"="Red".`
- The assistant's next message is the single word `Red`, so the answer round trip is
  observably closed.

Recorded on 2.1.259 under the scratch config home, model `haiku`, `--max-turns 3`; 28
transcript records. `initial/` and `artifacts/` are empty.
