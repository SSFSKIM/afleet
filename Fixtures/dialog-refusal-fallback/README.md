# dialog-refusal-fallback (synthetic, hypothesis)

What it shows: the CLI asking the host to resolve a model refusal. Four turns each stream a
partial assistant message, open a `request_user_dialog` of kind `refusal_fallback_prompt`
whose payload names that partial in `retractedMessageUuids`, and answer it a different way.

- `retry_fallback`: the retry runs, and its `assistant` frame carries `supersedes` naming
  the partial it replaces. The turn then ends with a `system/model_refusal_fallback` notice
  (`direction: "retry"`), whose `retracted_message_uuids` repeats the same retraction -- the
  two are documented as idempotent with each other, so a host may act on whichever arrives.
- `edit_prompt`: nothing at all between the answer and the result. The CLI aborts the turn so
  the user can edit.
- `cancelled`: an `assistant` frame carrying the refusal prose the CLI composes for the user.
- The close path, `{"behavior": "cancelled"}` with no `result` at all: identical to
  `cancelled`, because the dialog schema declares `default: "cancelled"`. A host that treats
  a missing `result` as a distinct outcome would be wrong, which is why both appear here.

**The decline legs carry no retraction signal on the wire, and that is the point.** The CLI's
decline branch does yield internal `tombstone` events, but they never reach a stream-json
host: the emitter's own filter lists `tombstone` among the event types it drops, the schema
is annotated `@internal ... From internal QueryEvent 'tombstone'`, and this repository's
parity inventory rates it "Dropped (45.9.2)" with a D verdict, listing a wire tombstone among
the signals the CLI still ought to add. So on `edit_prompt`, on `cancelled` and on the close
path there is nothing to react to, and the only mechanism a host has is the one the dialog
payload describes: evict the uuids in `retractedMessageUuids` yourself, on resolution --
"your own response (any choice) or `control_cancel_request` retirement, never on receipt", and
idempotently. Only the retry leg gets a wire signal, through `supersedes` and the notice's
`retracted_message_uuids`. A host that waits for a frame before evicting will leave the
refused partial on screen forever on three of the four outcomes.

A fifth turn opens a dialog of a kind the host never declared in
`initialize.supportedDialogKinds`. The host must leave it alone -- an error-shaped answer to
a parked dialog is swallowed -- and the CLI retires it itself with `control_cancel_request`,
the one shape in which a lifecycle closes without a response (spec §4.2).

**Whether that fifth turn can happen at all is open.** The parent's S6 and §6.3 mandate
modelling it, so the frames are not wrong to be here, but the parity inventory finds that
only three dialog families cross the wire and that every other kind "resolves to its declared
default immediately, whatever the host declares in `supportedDialogKinds`" -- which would mean
an undeclared kind never reaches a host to be left unanswered. `undeclared_probe_kind` is also
a synthetic placeholder: no binary contains that string, and a recording would have to
substitute a real kind outside the forwarded set. S6 should settle both.

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

What S6 should settle, because the bundle does not:

1. **Both `content` strings are partly placeholders.** The CLI assembles the refusal prose
   from a prefix, a category-dependent safeguards sentence, an edit hint and a learn-more URL.
   Only the safeguards sentence is readable verbatim; the rest is marked `[placeholder: ...]`
   in the frames rather than invented, because a rendering test written against invented copy
   would test nothing. The `model_refusal_fallback` notice is in the same position. The
   `edit_prompt` hint in the real copy names a keystroke and `/model`, both of which a GUI has
   to rewrite.
2. **The `result` subtypes on the decline legs.** `error_during_execution` is this fixture's
   assumption; the decline branch's own code says nothing about it. The `result` frames here
   also carry only `subtype`, `result`, `is_error` and `num_turns` -- the schemas require
   durations, costs and usage too, and a fabricated zero would be worse than an absence.
3. **The gap before the CLI retires the undeclared-kind dialog.** It is 1.5 s here so a replay
   is quick; the real dialog park deadline is five minutes by default per the parent's
   investigation, and no gate should read the fixture's timing as the deadline.
4. **Whether an undeclared kind is forwarded at all**, and what real kind to use in place of
   `undeclared_probe_kind`. See above.

`system/model_refusal_no_fallback` is deliberately **absent**. Its own schema says it is "not
emitted when the retry ran or the user declined the retry dialog" -- it covers the case where
no dialog was shown at all, which is not the case this fixture records.

Rebuild with `make synthetic`, which overwrites this directory and drops the review block
back to unsigned; walk `Fixtures/REVIEW.md` and `make sign` again afterwards.
