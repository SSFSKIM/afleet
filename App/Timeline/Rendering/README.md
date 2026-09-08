# App/Timeline/Rendering — C6.1, the timeline renderer

Owned by **C6.1** of the C6 composite spec,
`docs/doperpowers/specs/2026-09-07-c6-conversation-surface.md` (leaf table, "Four leaves, not
three"): the channel column's list, every row kind but `decision` and `sentFile`, streaming,
markdown, clusters, thinking, chips, members, turn summaries, hidden meta, the header's readbacks
and S7. No other leaf edits anything in this directory.

## Rows/ — the eleven kinds (C6.1 Task 4)

One file per kind group, and two pure layers under the views so the parts worth asserting are
values rather than layout:

- `TimelineRowBuilders.swift` — contract Y1's registration. Eleven kinds claimed, `decision` and
  `sentFile` never; `AppModel.init` claims them on the registry it is given.
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
  `OpaqueRow.swift` — the rest of §8, with the `taskRun` row hosting C6.3's `TaskCardView` behind
  a seam named for it.

Everything a row needs that is not its item arrives through `TimelineRenderContext`, including the
`TimelineNeighbourhood` gathered once per publish: the tool calls a cluster names, the instant
before an item, and the agent-run tree.
