# dialog-refusal-fallback (synthetic, shapes confirmed on 2.1.259)

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
substitute a real kind outside the forwarded set. A recording should settle both.

**The fixture exercises the broad-safeguards copy branch, and only that one.** The CLI picks
the safeguards sentence from the refusal category: `cyber` and `bio` get "Our intentionally
broad safeguards allow us to deliver more capabilities faster, but can sometimes flag
legitimate coding, cybersecurity, and biology tasks", and every other category gets "This
sometimes happens with safe, normal conversations". This fixture sends `bio`, so both of its
copy strings carry the first sentence. The second branch is real and is **not covered here**;
a host rendering refusal copy should expect either. The category also drives a `Details:
`[<category>]`` suffix, which is appended for any non-empty category and so is present on both
branches and on both frames.

`bio` rather than a category from the other branch because the per-category fallback map is
keyed by exactly `cyber` and `bio`: a category with no entry in it is the case that routes to
`model_refusal_no_fallback` rather than offering this dialog at all, so picking a category to
obtain the general sentence would have bought copy coverage at the cost of a dialog that might
never be shown.

Serves item 62 and spike S6.

**These shapes are synthetic, and confirmed against the baseline.** Nothing here was recorded. Every field is read out of the
2.1.257 bundle: `chunk-1kg58a1a.js` for the dialog kind, its
`{originalModel, fallbackModel, apiRefusalCategory?, guidanceText?, retractedMessageUuids?}`
payload, its `retry_fallback | edit_prompt | cancelled` result enum with `default:
"cancelled"`, the decline branch, and the copy builders; `chunk-sct99ax9.js` for the
`assistant.supersedes` and `system/model_refusal_fallback` schemas. S6 then found
each of those definitions exactly once in the installed 2.1.259 baseline binary, with every
payload key, every enum value and `default: "cancelled"` inside its own definition's window,
so `fixture.json` carries `hypothesis: false` (spec §4.7). `synthetic: true` stays, and with
it the exclusion from `diff`: a synthetic fixture is never baseline evidence by itself, and
the list below is what no schema states and therefore what the extraction could not reach.

What a recording should settle, because no schema states it:

1. **Both `content` strings are partly placeholders.** The CLI assembles the refusal prose
   from a prefix, a category-dependent safeguards sentence, an edit hint and a learn-more URL.
   Only the safeguards sentence is readable verbatim; the rest is marked `[placeholder: ...]`
   in the frames rather than invented, because a rendering test written against invented copy
   would test nothing. The `model_refusal_fallback` notice is in the same position. The
   `edit_prompt` hint in the real copy names a keystroke and `/model`, both of which a GUI has
   to rewrite.
2. **The decline legs' `result` frames, subtype and text alike.** Both
   `subtype: "error_during_execution"` and the `"result": "refusal"` string are this fixture's
   assumptions; the decline branch's own code says nothing about either, and a host must not
   read `"refusal"` as a value the engine emits. The frames here also carry only `subtype`,
   `result`, `is_error` and `num_turns` -- the schemas require durations, costs and usage too,
   and a fabricated zero would be worse than an absence.
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
