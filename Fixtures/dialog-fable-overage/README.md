# dialog-fable-overage (synthetic, hypothesis)

What it shows: the CLI asking the host for consent before spending past a Fable balance.
Five turns each open a `request_user_dialog` of kind `fable_overage_consent_prompt` and cover
every outcome the enum allows -- `consent` with `overagesEnabled` true and again false,
`switch_default`, `cancelled`, and the close path `{"behavior": "cancelled"}` with no
`result`. Every outcome other than consenting while overages are already enabled is followed
by a `system/model_consent_fallback` frame naming the original and fallback models and
whether the choice was persisted as the default.

Serves item 62 and spike S6.

**These shapes are hypotheses.** Nothing here was recorded. Every field is read out of the
2.1.257 bundle modules -- `chunk-1kg58a1a.js` for the dialog kind, its
`{overagesEnabled, modelName?, balanceCents?, currency?}` payload and its
`consent | switch_default | cancelled` result enum with `default: "cancelled"`, and
`chunk-sct99ax9.js` for the `system/model_consent_fallback` schema, whose ten fields this
fixture's frames carry exactly. The baseline binary is 2.1.259, so `fixture.json` carries
`synthetic: true` and `hypothesis: true`, the fixture is excluded from `diff`, and every gate
resting on it stays provisional until S6 extracts the same strings from the installed 2.1.259
binary and clears the flag (spec §4.7). A synthetic fixture is never baseline evidence by
itself.

Two readings this fixture encodes, which S6 should confirm on a recording. First, the second
turn: consenting while `overagesEnabled` is false still produces a `model_consent_fallback`,
because the schema says `choice: "consent"` appears there "only when the gate could not
honor it". Second, the fifth turn: the close path carries no `result` and the schema's
`default: "cancelled"` makes it behave as `cancelled`, so the two produce the same frames.
The message uuids here are readable synthetic ids rather than RFC 4122 uuids, and the
timestamps are chosen for a fast replay rather than measured.

Rebuild with `make synthetic`, which overwrites this directory and drops the review block
back to unsigned; walk `Fixtures/REVIEW.md` and `make sign` again afterwards.
