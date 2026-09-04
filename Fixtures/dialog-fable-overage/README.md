# dialog-fable-overage (synthetic, shapes confirmed on 2.1.259)

What it shows: the CLI asking the host for consent before spending past a Fable balance.
Five turns each open a `request_user_dialog` of kind `fable_overage_consent_prompt` and cover
every outcome the enum allows, with `overagesEnabled` both ways -- `consent`,
`switch_default` against a false payload and again against a true one, `cancelled`, and the
close path `{"behavior": "cancelled"}` with no `result`. Every outcome other than consenting
while overages are already enabled is followed by a `system/model_consent_fallback` frame
naming the original and fallback models and whether the choice was persisted as the default.

`consent` appears only against `overagesEnabled: true`, deliberately. The parent's §8.4 offers
that action "only when `overagesEnabled` is true, because a bare wire reply never enables
billing", and acceptance item 62 has the false branch stay pending until *Switch to the
default model* or *Not now*. A leg answering `consent` to a false payload would depict a reply
afleet is specified never to send, and a conforming host replaying this fixture would diverge
from it. The engine does have a behaviour there -- `model_consent_fallback`'s schema says
`choice: "consent"` reaches it "only when the gate could not honor it" -- but that is engine
behaviour afleet cannot trigger, so it belongs in an S6 finding rather than in a fixture
afleet replays against.

Serves item 62 and spike S6.

**These shapes are synthetic, and confirmed against the baseline.** Nothing here was recorded. Every field is read out of the
2.1.257 bundle modules -- `chunk-1kg58a1a.js` for the dialog kind, its
`{overagesEnabled, modelName?, balanceCents?, currency?}` payload and its
`consent | switch_default | cancelled` result enum with `default: "cancelled"`, and
`chunk-sct99ax9.js` for the `system/model_consent_fallback` schema, whose ten fields this
fixture's frames carry exactly. S6 then found both definitions in the installed 2.1.259
baseline binary, the dialog with its four payload keys, its `consent | switch_default |
cancelled` result enum and `default: "cancelled"`, and the frame with the same enum on
`choice` beside `original_model`, `original_model_name`, `fallback_model` and
`persisted_as_default`, so `fixture.json` carries `hypothesis: false` (spec §4.7).
`synthetic: true` stays, and with it the exclusion from `diff`: a synthetic fixture is never
baseline evidence by itself.

Each `model_consent_fallback.content` is built from the template the CLI builds it with --
`Switched to <fallback> <"— now your default model" | "for this session"> · <original>
requires usage credits · /model to change` -- so the clause tracks `persisted_as_default`
rather than contradicting it, and the `/model to change` instruction a GUI has to rewrite is
visible. The two model display names substituted into the template are this fixture's own
synthetic models.

One reading a recording should confirm: the fifth turn's close path carries no `result`,
and the schema's `default: "cancelled"` makes it behave as `cancelled`, so it and the fourth
turn produce the same frames. The message uuids here are readable synthetic ids rather than
RFC 4122 uuids, and the timestamps are chosen for a fast replay rather than measured.

Rebuild with `make synthetic`, which overwrites this directory and drops the review block
back to unsigned; walk `Fixtures/REVIEW.md` and `make sign` again afterwards.
