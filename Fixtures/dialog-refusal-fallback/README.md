# dialog-refusal-fallback (synthetic, hypothesis)

What it shows: the CLI asking the host to resolve a model refusal. Four turns each stream a
partial assistant message, open a `request_user_dialog` of kind `refusal_fallback_prompt`
whose payload names that partial in `retractedMessageUuids`, and answer it a different way.

- `retry_fallback`: the retry runs, and its `assistant` frame carries `supersedes` naming
  the partial it replaces. The turn then ends with a `system/model_refusal_fallback` notice
  (`direction: "retry"`), whose `retracted_message_uuids` repeats the same retraction -- the
  two are documented as idempotent with each other, so a host may act on whichever arrives.
- `edit_prompt`: one `tombstone` frame per already-streamed message, then nothing. The CLI
  aborts the turn so the user can edit, and emits no notice.
- `cancelled`: the same tombstones, then an `assistant` frame carrying the refusal prose the
  CLI composes for the user.
- The close path, `{"behavior": "cancelled"}` with no `result` at all: identical to
  `cancelled`, because the dialog schema declares `default: "cancelled"`. A host that treats
  a missing `result` as a distinct outcome would be wrong, which is why both appear here.

A fifth turn opens a dialog of a kind the host never declared in
`initialize.supportedDialogKinds`. The host must leave it alone -- an error-shaped answer to
a parked dialog is swallowed -- and the CLI retires it itself with `control_cancel_request`,
the one shape in which a lifecycle closes without a response (spec §4.2).

Serves item 62 and spike S6.

**These shapes are hypotheses.** Nothing here was recorded. Every field is read out of the
2.1.257 bundle: `chunk-1kg58a1a.js` for the dialog kind, its
`{originalModel, fallbackModel, apiRefusalCategory?, guidanceText?, retractedMessageUuids?}`
payload, its `retry_fallback | edit_prompt | cancelled` result enum with `default:
"cancelled"`, and the decline branch that yields the tombstones; `chunk-sct99ax9.js` for the
`assistant.supersedes`, `tombstone` and `system/model_refusal_fallback` schemas. The baseline
binary is 2.1.259, so `fixture.json` carries `synthetic: true` and `hypothesis: true`, the
fixture is excluded from `diff`, and every gate resting on it stays provisional until S6
extracts the same strings from the installed 2.1.259 binary and clears the flag (spec §4.7).
A synthetic fixture is never baseline evidence by itself.

Three things S6 should settle, because the bundle does not:

1. The `tombstone` frame's `message` field. Its schema types it as opaque and says the wire
   shape is pending, so the fixture carries only the tombstoned message's own uuid.
2. The `result` subtypes on the decline legs. `error_during_execution` is this fixture's
   assumption, not a bundle reading; the decline branch's own code says nothing about it.
3. The gap before the CLI retires the undeclared-kind dialog. It is 1.5 s here so a replay is
   quick; the real dialog park deadline is five minutes by default per the parent's
   investigation, and no gate should read the fixture's timing as the deadline.

`system/model_refusal_no_fallback` is deliberately **absent**. Its own schema says it is "not
emitted when the retry ran or the user declined the retry dialog" -- it covers the case where
no dialog was shown at all, which is not the case this fixture records.

Rebuild with `make synthetic`, which overwrites this directory and drops the review block
back to unsigned; walk `Fixtures/REVIEW.md` and `make sign` again afterwards.
