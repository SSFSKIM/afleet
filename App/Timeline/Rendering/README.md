# App/Timeline/Rendering — C6.1, the timeline renderer

Owned by **C6.1** of the C6 composite spec,
`docs/doperpowers/specs/2026-09-07-c6-conversation-surface.md` (leaf table, "Four leaves, not
three"): the channel column's list, every row kind but `decision` and `sentFile`, streaming,
markdown, clusters, thinking, chips, members, turn summaries, hidden meta, the header's readbacks
and S7. No other leaf edits anything in this directory.

**Amended 2026-09-09 (Task 8).** The sentence above still describes the *ownership* split — the two
cards, their answer mappings and the retraction bookkeeping are C6.3's and live in `App/Decisions/` —
but this directory now holds the two rows that **mount** them, because those rows exist to consume
the render context and the context is this leaf's (contract Y7).

## Rows/ — the thirteen kinds (C6.1 Task 4, completed at Task 8)

One file per kind group, and two pure layers under the views so the parts worth asserting are
values rather than layout:

- `TimelineRowBuilders.swift` — contract Y1's registration. All thirteen kinds claimed in one call,
  on the registry `AppModel.init` is given; the claim on `RowRegistry.shared` is made once per
  process, and the registry's trap on a second claim of a *kind* is left saying the one thing it
  exists to say.
- `DecisionRow.swift`, `SentFileRow.swift` — contract Y7's two mounts. They draw another leaf's card
  and row and supply what a builder is not handed: the channel, the link capability, the app's one
  `DecisionReservations` and the fold's raise. With no context they fall back to the readable halves,
  which is what an archived channel gets.
- `ToolResultForms.swift` — the per-tool sentences of parity §41.16.7 and the error normalisation
  of §41.16.6, as a value. Eleven tools have their own form; everything else takes the generic one
  and tracker 136 carries the remainder with the parity table as its map.
- `AgentChip.swift` — §9's chip. The tool is named `Agent`, not `Task`. It renders from the call
  and consults the channel's `AgentRunTree` only for the run id `AgentNavigating.show(run:in:)`
  takes; **with no tree it renders and does not navigate**, which is the ordinary case for a
  channel opened from its files (tracker 187).
- `FileLink.swift` — a path in a tool row as a `WorkspaceLink.file`. Canonicalised with
  `realpath(3)` and **never by opening a descriptor**: `open(2)` on a user-content directory is
  TCC-gated and blocks on a consent dialog.
- `ClusterRow.swift`, `ThinkingDisclosure.swift`, `MessageRows.swift`, `ToolCallRow.swift`,
  `TaskRunRow.swift`, `NoticeRows.swift`, `CompactBoundaryRow.swift`, `TurnSummaryRow.swift`,
  `OpaqueRow.swift` — the rest of §8, with the `taskRun` row hosting C6.3's `TaskCardView` through
  `TaskCardSeam` (contract Y2's second host, filled at Task 8).

Everything a row needs that is not its item arrives through `TimelineRenderContext`, including the
`TimelineNeighbourhood` gathered once per publish: the tool calls a cluster names, the instant
before an item, and the agent-run tree.
