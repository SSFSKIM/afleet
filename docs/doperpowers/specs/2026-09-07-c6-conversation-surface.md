# C6: Conversation surface and Agents panel — composite (2026-09-07)

> **Parent:** `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C6`.
> **Parent-pin:** that path at commit `b775842` ("Spec: the human's two decisions at the C5
> merge"). **Level name:** composite child, wave 4 of the v1 roadmap; its leaves are children
> one level down. **Track:** composite — this document is the decomposing run at dispatch the
> parent's §17 C6 row asked for; each leaf runs the controlled track (child spec → plan →
> execute) in its own worktree. **Status:** cut **approved by the human 2026-09-08**; wave 1
> (C6.1, C6.2, C6.3) dispatching; C6.4 blocked-by C6.1 and C6.3.
>
> This document treats the parent's §17 C6 section and its design inheritance (§6.6, §7.3,
> §7.5, §7.6, §7.7, §8.3 through §8.8, contracts X4, X5, X7, X9, X10) as landed and records
> only what the joint view of the four leaves settles: the cut, the contracts between the
> leaves, the authority grades, and the parent-level acceptance the recomposition verifies.
> It reads the C3 child spec `2026-09-05-c3-fleetkit-timeline.md`, the C4 child spec
> `2026-09-05-c4-fleetkit-sessions-fleet.md`, the C5 child spec `2026-09-06-c5-app-shell.md`,
> the C7 composite `2026-09-05-c7-workbench-panels.md` and `docs/tech-debt-tracker.md` at the
> same commit.

## Purpose

The channel column and the Agents tab, as the parent states them: the native, virtualized
timeline with streaming markdown, clusters, thinking, agent chips, members, turn summaries and
hidden meta; every decision card of §8.4 including the two dialog cards, with reply-to-card
semantics; the Thread tab's thread kinds; the composer with the router, `@` mentions, host-side
`!` with the hardened envelope, image paste, queueing, edit via rewind, prompt-suggestion ghost
text and the mode, model and effort pickers; the bypass gate; the consent sheets; the trust
banner with its terminal action; the sent-file item; and the Agents tab of §8.8. It replaces
C5's placeholder timeline. Everything here renders what C3 reduces and acts only through C4's
lifecycle API; nothing in this unit spawns `claude`, reads a transcript file, or writes under
a config home.

## Parent-Level Acceptance

Closing this composite is a recomposition check against the parent's §17 C6 acceptance, run
on `main` after the last leaf merges — not the sum of the leaves' gates:

- Checklist items **2, 3, 6, 7, 8, 10, 12, 13, 29, 30, 37, 40, 41, 42, 43, 44, 45, 47, 57,
  60, 61, 62** pass against the installed CLI or `fake-claude` fixtures exactly as each item
  states; items **9, 38, 49, 50, 51, 52** pass in the Agents tab; items **4 and 5** pass in
  the timeline with the same cards Activity already answers.
- Item 24's link emission: a path in a Read row emits a `WorkspaceLink.file` with its line,
  routed through X7's `LinkRouterCapability`.
- **S7** passes on the ten-message corpus at thirty updates per second under 16 ms per frame,
  or the WKWebView fallback is adopted with a Revision Note on the parent.
- With the `nested-depth-2` fixture the depth-2 tree renders from the two-step join before the
  `.meta.json` is written and is corrected by it afterwards.
- The differential invariant of §7.3 is untouched: this unit adds no reducer; every item the
  timeline shows is a `TimelineItem` or an overlay entry C3 produced.
- X9 holds across the unit: the app-side write seam C5 landed (`AppFileWrites`) still observes
  every write, and the config-home witness of C5's live gate reads zero unattributed changes
  across every live item above.

## Grounding Baseline

What is on `main` at the pin, verified by reading rather than by report:

- **C3's model** (`FleetKit/Sources/FleetTimeline`): `TimelineItem` with the thirteen kinds
  of §7.3 (`userMessage`, `assistantMessage`, `toolCall`, `cluster`, `taskRun`, `decision`,
  `hookRun`, `notification`, `peerMessage`, `compactBoundary`, `sentFile`, `turnSummary`,
  `opaque`), `ItemID`, `Provenance`, `DurableProjection`, `Overlay` (`turns`, `hooks`,
  `notifications`, `clusters`, `decisions: [RequestID: DecisionItem]`, `queue`, `stale`,
  `banners`), `DecisionItem` (`requestID`, `kind`, `state`, `payload`, `toolUseID`,
  `agentID`, `threadParent`), `ChannelTimeline`, `TimelineChange`, `AgentRunTree` and
  `AgentRunNode`, `TaskOutputTailer`, `URLSources` and `ProjectionCategories`. The reducers
  are C3's; this unit consumes `ChannelTimeline` values as C5's `ChannelTimelineModel`
  already does.
- **C4's lifecycle API** (`FleetKit/Sources/FleetSessions/Types/LifecycleAPI.swift`):
  `perform(_:on:)` with `LifecycleAction` — `open`, `send(UserInput)`, `answer(RequestID,
  InboundAnswer)`, `fork(at:)`, `quiescentRestart`, `sendToBackground`, `stopEverything`,
  `backgroundAll`, `logout`, `reopen` — `route(_:on:)` returning `Routed`
  (`controlRequest`, `strategy`, `lifecycle`, `restart`, `text`, `native`,
  `refusedLocally`), `run(_:arguments:on:ui:)`, `events(of:)`, `updates`, `preconditions`,
  `acceptProjectServers`, `declineProjectServers`, `openInTerminal`, `jobs`, `performJob`.
  X10's router table is data in `Router/RouterTable.swift`. `LifecycleError.busy` and
  `notEligible(Blocker)` are the refusals a surface must render.
- **C5's shell** (`App/`): `ChannelTimelineModel` (items and rows over C3's timeline; `open`,
  `close`, `subscribe`, `transcriptMoved`), `ChannelTimelineRegistry`, `PanelHostModel` and
  `Workbench/Sources/PanelHostAPI` (X7: `PanelTabID` closed at seven, `ChannelContext` with
  `key`, `session`, `cwd`, `environment`, `store`, `links`, `recentURLs`, `reportPaneExit`;
  `LinkRouterCapability`; `PaneRunning`), `PlaceholderTab` registered under `.thread` (C6
  takes the id by `unregister(.thread)` then registers its own; `.agents` is free),
  `HostLinkRouter`, `ActivityModel` with the inline permission answer path and the
  `ChannelEventPump` per channel, `NotificationRouter`, `SidebarView`, `QuickSwitcherModel`,
  the setup and settings screens, `AppFileWrites` and `LaunchSequence.overlappingWriteRoot`
  (X9's app-side half), `ConfigHomeWitness` and `ScratchLiveGate` (the live-gate harness).
- **C2's envelope**: `ClaudeWire/Sources/WireFrames/ShellEnvelope.swift` implements §6.6's
  hardening of the `!` path; the composer calls it and writes no sanitiser of its own.
- **Fixtures** this unit's gates replay: `ask-user-question`, `dialog-refusal-fallback`,
  `dialog-fable-overage`, `rewind-turn`, `nested-depth-2`, `notification-hook`,
  `compact-boundary`, `control-shapes`, `session-mirror-relocation`, `session-mirror-resume`,
  `background-shell`, and C1's `fake-claude` for every card and dialog item.
- **Engine authority**: the extracted bundle `~/claude-code-bundle/2.1.263/cli.pretty.js`,
  cited by line; `docs/tui-parity/areas/` (`18-agents-subagents.md`,
  `24-21-permissions-plan-questions.md`, `28-slash-commands.md`, `41-tui-rendering.md`,
  `42-input-keybindings.md`, `20-tasks-background.md`) as the parity map. The `SPEC/`
  chapters are anchored to 2.1.258 and are a map, not the authority.
- **Live tests**: only under the scratch config home `CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home`
  with `AFLEET_LIVE_CLI=1`; a test that spawns an engine outside
  `LaunchConfiguration.childEnvironment` scrubs `CLAUDE*` itself (`CLAUDE_CODE_CHILD_SESSION`
  in this harness's environment switches the engine's registration off, parent §6.10). This
  unit is the first whose gates **spend model turns**; the budget is in the live-cost
  statement below.
- **Two facts from C5's merge that bind here**: `open(2)` on a user-content directory is
  TCC-gated and blocks on the consent dialog, so nothing in this unit opens a descriptor on a
  path the user chose (`realpath`/`stat` for canonicalisation); and every fixture and live gate
  so far ran under a `CLAUDE_CONFIG_DIR` scratch home (tracker 70), so a default-shaped home
  is a shape this unit's live items have never seen.

## Live-cost statement

The parent's acceptance items for this unit are live conversations. Each leaf declares its own
budget in its child spec; the composite's ceiling is **ten US dollars across the four leaves**
on the scratch account, with every live item that a `fake-claude` fixture can replay replayed
instead (every card, dialog, cancellation, malformed answer and unknown request; the shell
envelope with a scripted command; the depth-2 tree). Turns are spent only on the items that
name a model behaviour (2, 3, 6, 7, 8, 9, 10, 12, 13, 29, 37, 41, 49, 50, 51, 52, 61) and each
is run at most twice per leaf. `submit_feedback` is never sent.

## Design

### Four leaves, not three

The parent's advisory sketch cut three leaves: rendering with the composer, decision cards
with threads, and the Agents panel. The gate splits the first. The timeline renderer and the
composer have different state owners (the renderer reads `ChannelTimeline` values and owns no
lifecycle state; the composer writes through X5 and owns pending sends, the queue chip, the
pickers' readbacks and the restart-required settings), different invariants (frame time under
streaming versus every send reaching the lifecycle exactly once), different failure modes (a
jank or a mis-rendered block versus a lost send or a wrong answer mapping) and different
verification (fixtures and S7's frame-time harness versus live turns and the router table).
"Renders and sends" is acceptance phrased with an *and*. Splitting them also lets both start
in the first wave: the composer needs only C5's model and X5, not the renderer.

**[binding — joint view]** The cut is:

| Leaf | Owns | Directory | Branch |
|---|---|---|---|
| **C6.1 Timeline renderer** | the channel column's list, every item row kind except decisions and sent files, streaming, markdown, clusters, thinking, chips, members, turn summaries, hidden meta, the header's readbacks, S7 | `App/Timeline/Rendering/`, `App/Timeline/ChannelTimelineModel.swift` (from C5) | `child/c6-timeline-renderer` |
| **C6.2 Composer and channel header** | the composer, the router UI, `@` and `!`, paste and drop, the queue chip, edit via rewind and *Fork from here*, ghost text, the mode, model and effort pickers, the bypass gate, the header's menus and actions, restart-required settings | `App/Composer/`, `App/Header/` | `child/c6-composer` |
| **C6.3 Decision cards and threads** | the six card kinds and the two dialog cards, their answer mappings, reply-to-card, the Thread tab and its five thread kinds, the consent sheets, the trust banner and its terminal action, the sent-file item, Activity's adoption of the card component | `App/Decisions/`, `App/Threads/`, `App/Consent/` | `child/c6-decisions` |
| **C6.4 Agents panel** | the Agents tab: the run tree, the per-run transcript over C6.1's view, node actions, *Stop everything* and *Background all*, subagent cards on nodes, chip navigation, item 51's delivery states | `App/Agents/` | `child/c6-agents` |

All four live in the app target: the parent's §8.8 puts the Agents tab in the Afleet layer
because it renders timelines, and the same reason holds for the rest. Four worktrees build one
Xcode target; XcodeGen globs `App/**`, so adding files under a leaf's directory touches
`project.yml` never, and the two files two leaves must both touch — `App/Composition/AppModel.swift`
for tab registration and `App/Timeline/Rows/RowRegistry.swift` for the row slot — are handled
by the skeleton below and by sequential merges.

### The skeleton the orchestrator lands before dispatch (contract Y1)

**[binding — four leaves build one target in parallel]** Before any leaf's branch opens,
`main` gains, with one placeholder per leaf so the app still builds:

- `App/Timeline/Rows/RowRegistry.swift`: a registry keyed by `TimelineItem` kind that maps an
  item to its row view builder, with a default row (C5's placeholder row) for every kind. C6.1
  fills every kind but `decision` and `sentFile`; C6.3 fills those two. A kind nobody has
  filled renders the default row, never nothing, so the list is complete on every branch.
- The four directories with a `README.md` naming the owner, so `git` shows ownership and a
  leaf that edits outside its directory is visible in review.
- `App/Agents/AgentNavigation.swift`: the app-level seam of contract Y4 with a no-op default,
  so C6.1's chip compiles before C6.4 exists.

Amended 2026-09-09 at C6.3's merge (its D1/D1b, superseded in part by the one-fold ruling of
2026-09-08): the skeleton's second landing (`9d6d320`) gave `TimelineRow` its `item: TimelineItem`
with the builder arity unchanged, and the app's one wire subscription is C3's `StreamIngestion`
fold (corrective `01eb7a7`), consumed by C6.1 — no leaf lands a reducer subscription of its own.

### Contract Y2 — one card component, two hosts

**[binding — the parent's §7.6 says decisions are answered from the timeline and from
Activity]** C6.3 owns `DecisionCardView` and its answer mapping (`§8.4` row → `InboundAnswer`
→ `LifecycleAction.answer`). The timeline (C6.1's row slot) and Activity (C5's
`ActivityModel`, whose inline permission path predates this unit) both host that one component
and its mapping; at C6.3's merge Activity's inline card is replaced by the component and the
answer path is one function. Activity renders it in the compact presentation for a plain
permission ask and keeps C5's ruled behaviour for every other kind — a row and *Go to channel*
(amended 2026-09-09 at C6.3's merge, its D4). A card's *state* (pending, answered, cancelled by the binary, session ended,
answered elsewhere) is C3's `DecisionItem.state`; the view renders it and never keeps its own.
Answers go through X5 and nothing else: a card never holds a `ClaudeWire` type.

### Contract Y3 — the tab handoff

**[binding — X7's id set is closed]** C6.3 takes `.thread` by `unregister(.thread)` then
`register(ThreadTab(lifecycle:))`, and C6.4 takes `.agents` the same way. Corrected 2026-09-09
from C6.3's `[parent-impact]`: the handover happens once a `Workspace` exists — in
`performLaunch`, after `bindWorkspace` — not in `AppModel.init`, because `unregister` is `async`
(X7 made it so to await the link-target withdrawal) and a tab that answers a card or runs a stop
must be constructed with the lifecycle, which X7 keeps out of `ChannelContext` and which does not
exist in `init`. C5's placeholder registration in `init` stays and serves the id until then, so
the handover is real and `PlaceholderTab` stays live code. The two leaves still touch different
statements in one file and merge in sequence; "one line each" is withdrawn.

### Contract Y4 — chip to run

**[binding]** An `Agent` chip in the timeline (C6.1) navigates to the Agents tab at that run
through `AgentNavigation.show(run: AgentRunID, in: ChannelKey)`, an app-level seam C6.4
implements (select the tab through the panel host, select the node). It is not a
`WorkspaceLink`: that enum belongs to AfleetCore and C7.2's router in flight enumerates every
case, so a new case would be a mid-flight contract change for a navigation that never leaves
the app. The skeleton's default is a no-op; C6.4 replaces it.

### Contract Y5 — everything the surface does goes through X5

**[binding — parent X5 and X9]** Every send is `perform(.send(UserInput))`; every slash
command is `route(_:on:)` then `run`/`perform` as `Routed` says; every answer is
`perform(.answer)`; fork, restart, background, stop-everything, background-all and logout are
their actions; the trust banner's terminal action is `openInTerminal` handing a `PaneRequest`
to the host; consent is `accept`/`declineProjectServers`. No leaf constructs a `ClaudeWire`
type, opens a transcript file, or writes under a config home; a leaf that needs a query X5
lacks files a `[parent-impact]` against X5 rather than reaching around it (C5's tracker
entries 74 and 77 are two such queries already filed: the owned-actions readback and the
roster-change signal).

### Contract Y6 — edit and the drift replacement cross the row/composer seam

**[binding]** Named 2026-09-08 at C6.2's merge, from C6.2's tracker 153: Y4 named chip-to-run in
one direction and the cut never named the mirror case, so with every gate green on both sides the
app would ship an *Edit* wired to nothing and a drift replacement nobody sees. Three sites, all in
`App/Timeline/` (C6.1), over a model that is C6.2's: an *Edit* row action on a past user message
calls `ComposerModel.edit(_:)`, and the composer owns everything it triggers (the rewind carrying
`last_seen_user_message_uuid`, the body reading, the *Fork from here* fallback); when a rewind was
refused and a fork opened, the composer sets `ComposerModel.editNote` and the row renders it beside
the edited message; an assistant row whose frame uuid is in `ComposerModel.interceptedReplacements`
draws the replacement in place of the frame (§7.7) — a substitution, not an annotation: the frame's
own text appears nowhere in the row, which is the clause a test must fail on, since an annotation
passes the positive half alone — the composer owns the interception and the counts, the row owns the
substitution. C6.1 verifies all three through the composer model or C6.2's
recording double, no engine, and its call removes the `edit(_:)` allowlist line from
`check-app-wiring.py`.

### Contract Y7 — the render context: links and the fold's signal reach a row

**[binding]** Named 2026-09-09 at C6.3's merge, from its tracker 157: five mounts on the row side waited
on one value nobody had landed. C6.1's `TimelineRenderContext` — the per-row capability environment
value Y1's skeleton paragraph promised — carries the link capability (`ChannelContext.links`, so a
card's paths render as links without a second registry) and the channel fold's `signal(_:)` (so an
answering object constructed from a row raises `HostSignal.decisionAnswered` and a card leaves
`pending` on screen). Consumers on the row side, C6.1's to mount: the decision row's actions
(`DecisionAnswering` with `raise` assigned from the context and the app's one reservation set,
`AppModel.decisions`, so no two surfaces answer one request), the sent-file row's *Open in Files*,
`RetractionRegistry.retains(_:)` before drawing, and `TaskCardView` on the `taskRun` row. Activity
and the Thread tab assign `raise` through the app-scoped `ChannelTimelineRegistry.model(for:)` and do
not wait on the context (closed on C6.3's branch before merge). Owner: C6.1 (the value); C6.3 (the
consumers' components). Binds both and C6.4 (node cards).

### Rendering (advisory, C6.1)

`NSTableView`-backed list virtualized by `ItemID`, bottom-anchored, as §8.3. Streaming
coalesces at thirty updates per second into the current message's tail; only the stable prefix
is parsed as markdown (block boundaries from the delta stream), the tail as plain text.
Markdown through Apple's `swift-markdown` into attributed text; the highlighter is the leaf's
call at grill time (a pure-Swift grammar set is preferred over a JavaScript engine because a
`WKWebView` per code block is exactly what S7 exists to avoid); tables native; diagrams in a
lazily created `WKWebView` per block. Clusters labelled from `tool_use_summary`, falling back
to counts and elapsed. Thinking as a collapsible with the `system/thinking_tokens` estimate.
Members per §8.3. Hidden meta (`isSynthetic`) not rendered; the raw view keeps it. Turn
summary rows; compaction as a divider (§7.3's stated reopen behaviour). The header's
**readbacks** (branch, model, mode, effort, context meter) are C6.1's because they are
rendered state; the header's **menus** are C6.2's because they are actions. S7 is C6.1's spike
with the WKWebView fallback behind one `TimelineRendering` protocol so the fallback swaps
the view, not the model.

### The composer (binding where §6.6, §7.7 and §8.5 bind; advisory for layout)

Markdown field, Shift+Enter newline, Enter send, Cmd+Enter send. `/` autocompletes from the
handshake's `commands` with X10's local table layered on top, resolved through `route`; a
`refusedLocally` explanation renders inline and never tells the user to go to the terminal.
`@` completes through `file_suggestions`. `!` runs host-side in the channel's cwd with the
resolved environment and posts the `ShellEnvelope` frame — the sanitiser is C2's, called, not
copied. Image paste and drop attach blocks. Sending while a turn runs queues; the queue chip
reads `Overlay.queue` and cancels through `cancel_async_message`. **Edit** on a past user
message: `rewind_conversation` first, always carrying `last_seen_user_message_uuid` (the newest
user message the composer has rendered), prefill from the honoured body's `prefillText`; a
refusal read from the body, not the envelope — `"unseen later turn"` when the host has not
caught up, `"stale target"` only if the field was somehow omitted — falls back to *Fork from
here* with the composer prefilled from the transcript and says so; files are rewound only after
an honoured conversation rewind and only when asked (§8.5 as corrected 2026-09-08, item 13). Ghost text from
`prompt_suggestion` when the setting is on; turning it on is a quiescent restart. The mode
picker shows `bypassPermissions` only when `get_settings` allows it and follows §8.6's gate
exactly (disclaimer once, acceptance stored in afleet's store, quiescent restart with the
flag, then `set_permission_mode`). Restart-required settings restart quiescently through X5
with the readback rule of §7.4. Every picker's value is a readback (`get_settings.applied`,
`effective`), never the last thing the user clicked.

### Decision cards and threads (binding for mappings; advisory for layout)

The six cards and two dialog cards of §8.4, rendered from `DecisionItem.kind` and `payload`,
answered with exactly the mappings in §8.4's *Answer* column and the dialog table's *Result*
column; `default_to_no` and `requires_user_interaction` as stated; a card answered or cancelled
by the binary goes inert with its outcome; the refusal card's `retractedMessageUuids` are
evicted on resolution, never on receipt; the overage card renders a following
`system/model_consent_fallback` as its outcome. `Edit` and `Write` inputs render as diffs:
through C7.2's `MonacoEditorView` when it is on `main`, else an attributed-text diff behind
one `DiffRendering` protocol, so C6.3 neither waits for C7.2 nor forks a second editor
(conditional-on edge). Reply-to-card is §7.5's *Decision* thread. The Thread tab hosts one
thread at a time, Slack-style, with the five kinds of §7.5; *Ask on the side* is
`side_question` with accumulated history. Consent sheets render X5's `consentNeeded` server
list and answer through `accept`/`declineProjectServers`; the trust banner renders
`untrusted` with *Review trust in terminal* as an `openInTerminal` pane request (the pane
runner is C7.4's; until it lands the request surfaces the host's *no runner* refusal as a
banner naming the terminal, which is the parent's item 47 degraded, not silently skipped).
The sent-file item renders `sentFile` with a preview and *Open in Files* as a
`WorkspaceLink.file`. Subagent permission cards (item 52) are the same component with the
agent label C3 already joins.

### The Agents panel (data model binding; rendering advisory)

The tree over C3's `AgentRunTree`: one node per run keyed by task id, type, model badge,
status, locally ticked elapsed from `task_started`, activity line from `task_progress` or the
model-written summary; nesting from `agent_metadata`'s `parentAgentId` with the two-step join
as fallback (S16's fixture proves both); a repeated `task_started` for one task id is the same
node; parking renders as completed children under a node with no `task_notification`. The
per-run transcript reuses C6.1's view with agent-type authorship and the model badge from the
run's own frames. Node actions: *Stop* (`stop_task`), *Move to background*
(`background_tasks {tool_use_id}` with the `{backgrounded: false}` rule of §8.4), *Send
message* with item 51's four delivery states tracked from the main timeline's `SendMessage`
tool call and the agent stream, *Open transcript file* (`WorkspaceLink.file`), *Copy agent
id*; *Stop everything* and *Background all* as X5 actions behind their confirms. Subagent
permission cards mirror on nodes through Y2.

### Grades inherited from the parent, one level down

Binding, from the parent as marked: §6.6 (sending input); §7.3's item model and reducer rules
as consumed; §7.5's thread table; §7.6's Activity semantics; §7.7's router classes and flag
matrix as data; §8.4's answer mappings and frame shapes; §8.5's rewind rule; §8.6; §8.7's
shortcuts; §8.8's data model; X4, X5, X7, X9, X10. Advisory: §8.3's rendering tactics, §8.4's
layout, §8.8's rendering, the sub-cut sketch this document replaces, and every "advisory"
paragraph above. Contracts Y1 through Y5 are binding because only the joint view of four
leaves in one target could settle them.

## Children

### C6.1: Timeline renderer — plan

- **Purpose:** The channel column's list and every row kind except decisions and sent
  files; streaming; markdown; clusters; thinking; agent chips; members; hidden meta; turn
  summaries; compaction divider; the header's readbacks; the S7 spike and its fallback. It
  extends C5's `ChannelTimelineModel` rather than replacing it and fills Y1's registry.
- **Acceptance:** G1 (required): the ten-message S7 corpus (recorded assistant messages from
  `Fixtures/`, with tables, nested lists, fenced code, thinking) renders through the native
  path; a harness drives thirty updates per second for sixty seconds and the frame time stays
  under 16 ms at the 99th percentile, measured with `CADisplayLink`/`os_signpost`, or the
  WKWebView fallback is adopted behind `TimelineRendering` with a Revision Note on the parent.
  G2 (required): replaying `compact-boundary`, `nested-depth-2`, `background-shell` and
  `session-mirror-resume` through `fake-claude`, the list shows every durable item C3 reduces,
  in order, with clusters labelled from `tool_use_summary` and counts when no summary
  arrives, thinking collapsed with its duration, `isSynthetic` hidden, the compaction divider,
  and an `Agent` chip whose click calls `AgentNavigation.show` (a counting double); a
  differential check that the rows' item ids equal the timeline's ids for every fixture. G3
  (required): item 24 — a path in a Read row emits `WorkspaceLink.file(url, line:)` through
  the channel context's `links`. G4 (required): the header renders model, mode, effort and the
  context meter from `get_settings` and `get_context_usage` readbacks replayed from
  `control-shapes`, never from a picker's last click. G5 (required, live, zero turns): opening
  a foreign session under the scratch home (C5's `ScratchLiveGate`) renders its history within
  five seconds with zero unattributed config-home changes. G6 (required; added 2026-09-08 at
  C6.2's merge, contract Y6): an *Edit* row action on a past user message reaches
  `ComposerModel.edit(_:)`; a refused rewind's `editNote` renders beside that row; an assistant
  row whose uuid is in `interceptedReplacements` draws the replacement in place of the frame —
  through the composer model or C6.2's recording double, no engine. G7 (required; added
  2026-09-09 at C6.3's merge, contract Y7): `TimelineRenderContext` carries `links` and the fold's
  `signal(_:)`; a decision card in the list leaves `pending` after an answer through a lifecycle
  double; a path in a permission card emits a `WorkspaceLink` through `links`; `TaskCardView` is
  mounted on `taskRun` and `RetractionRegistry.retains(_:)` is consulted before drawing, with the
  two allowlist lines removed.
- **Edges:** blocked-by: the Y1 skeleton on `main`; blocks: C6.3 (row slot), C6.4 (view
  reuse); conditional on nothing.
- **Contracts:** Y1 (fills), Y2 (hosts the card in the `decision` slot and `TaskCardView` on
  the `taskRun` row; consults `RetractionRegistry` — amended 2026-09-09 at C6.3's merge), Y4
  (calls), Y6 (calls and renders; named 2026-09-08 at C6.2's merge), X4, X7 (reads
  `ChannelContext`).
- **Design inheritance:** §8.3 (advisory), §7.3 (binding as consumed), S7 (the spike is the
  leaf's), X4.
- **Track hint:** controlled. Tracker entries **127–141**.
- **Status:** not-dispatched, dispatchable on approval of this cut. Worktree
  `../afleet-c6/timeline-renderer`.

### C6.2: Composer and channel header — plan

- **Purpose:** The composer and the header's menus and actions: the field, the router UI over
  X10, `@` mentions, host-side `!` through `ShellEnvelope`, paste and drop, the queue chip,
  edit via rewind with *Fork from here*, ghost text, the mode, model and effort pickers with
  their readbacks, the bypass gate, the header menus (MCP, reload skills and plugins, rename,
  fork, send to background, open in terminal), and restart-required settings.
- **Acceptance:** G1 (required): a router-UI test for every row of X10's table — each local
  command dispatches to the `Routed` case the table names, a terminal-only command is refused
  locally with its one-line explanation, a pass-through command is sent as text, and the
  engine's `/<name> isn't available in this environment.` refusal is intercepted and
  replaced, counted in the drift log — driven through a lifecycle double, no engine. G2
  (required): `!` posts the `ShellEnvelope` frame for a scripted command and item 60's
  fixture script renders every tag literally (fixture, not live). G3 (required): the queue
  chip follows `Overlay.queue` from a replayed `command_lifecycle` sequence and cancels
  through `cancel_async_message`. G4
  (required): item 13 — every `rewind_conversation` the composer sends carries
  `last_seen_user_message_uuid`; an honoured body (`rewound: true`, `targetMessageUuid`,
  `prefillText`, no `error`) prefills; a refusal read from the body (`"unseen later turn"`
  injected through the double; `"stale target"` from `rewind-turn`, which was recorded without
  the field) falls back to *Fork from here* (`perform(.fork(at:))`) with the composer prefilled
  and a visible note; no `rewind_files` call precedes the honoured answer. G5 (required): §8.6's bypass gate on a lifecycle double —
  declining restarts nothing; accepting stores the acceptance, performs one quiescent restart
  with the flag, then sends `set_permission_mode`; `settings.json` is never touched (the
  X9 seam records no write). G6 (required, live, at most four turns): items 2, 8 and 12 under
  the scratch home with the config-home witness reading zero unattributed changes. G7
  (required): every picker's displayed value is a readback replayed from `control-shapes`.
  **Outcome 2026-09-08:** G1, G2, G3, G4, G5 and G7 met; G6's zero-turn half ran live and
  passed, its prompted half (items 2, 8, 12) is **blocked** by the scratch account's organisation
  policy with zero of four turns spent — carried as a manual witness with the quit `NSAlert`, the
  delegate adaptor in the real scene and `.quit` against a busy live engine. Three
  `[parent-impact]`s, all resolved on `main` as correctives (`6abd4a0` X10 refusal copy,
  `d802792` `sendPrompt`, `b86a73a` `quit`/`liveTaskIDs(of:)`). Four gates found thinner than
  their wording by the leaf's own audit and re-cut, each proved by mutation; the substitution
  half of G1 and the visible-note half of G4 are C6.1's through Y6. Merge review: one panel round
  (32 confirmed, 5 P1) closed by four file-partitioned waves — channel switch identity, the shell
  escape's ownership check, bounded capture, process group and cancellation, the quit re-census,
  the fork's own channel, the prompt's own uuid during a spawn, cancelled prompts retired from
  attribution, restart completion judged by epoch, routed setting changes through the header's
  gate, IME composition before Return — then a second round (22 confirmed, 4 P1) closed by three
  more waves: presence recomputed at publication (a C4 defect the sidebar shared), no composer on
  a read-only row, the fork's prefill delivered under its resolved identity, the restart gate as
  one state machine with a single release point, the shell escape's escalation owed to the group
  — then a third (14) and a fourth (11): the header's *Open in terminal* now warns from
  `liveTaskIDs(of:)` before ending shells (X9), an image with no words is a message, quitting
  cancels running `!` commands, and the restart-required-settings gate — three rounds of local
  patches had each produced the next round's races — was rebuilt as one generation-fenced
  operation behind a single predicate every entry point consults. A fifth round closed the
  review under the convergence rule (findings dispositioned as debt or dismissed unless a rule
  violation). X4/X5 amended as the parent records.
- **Edges:** blocked-by: the Y1 skeleton; blocks: nothing inside C6; C6.4's *Send message*
  reuses its send path.
- **Contracts:** Y5, Y6 (owner), X5, X10, X7 (`ChannelContext.environment` for `!`).
- **Design inheritance:** §6.6, §7.7, §8.5, §8.6 (binding); §8.3's header list (advisory
  split: readbacks to C6.1, menus here).
- **Track hint:** controlled. Tracker entries **142–156**.
- **Status:** **merged** 2026-09-08 at `c2dae0f` from `child/c6-composer` `4902242`
  (72 commits). Worktree `../afleet-c6/composer` retired.

### C6.3: Decision cards and threads — plan

- **Purpose:** The card component of Y2 with every mapping of §8.4 and the dialog table; the
  Thread tab with §7.5's five kinds; reply-to-card; consent sheets; the trust banner and its
  terminal action; the sent-file item; Activity's adoption of the component.
- **Acceptance:** G1 (required): every card kind and both dialog cards replayed through
  `fake-claude` — `ask-user-question` (item 57's previews), `dialog-refusal-fallback` and
  `dialog-fable-overage` (item 62 in full, including the billing-page route as a
  `WorkspaceLink.url` through `links`, eviction on resolution not receipt, the
  `model_consent_fallback` outcome), a permission card with `permission_suggestions` (items 4
  and 5's *Always allow* scope choice), a plan card, an elicitation form, a task card with
  *Move to background* and the `{backgrounded: false}` rule (item 61's two fixture arms),
  `control_cancel_request` (item 42), the malformed-answer arm (item 43), an unknown inbound
  request (item 45), and `kill -9` while pending (item 44, on the stand-in) — each answer
  asserted as the exact `InboundAnswer` handed to the lifecycle double. G2 (required): the
  Thread tab takes `.thread` from the placeholder and hosts each of the five kinds; a
  reply to a permission card sends `deny` with the text as `message` (item 37); *Ask on the
  side* sends `side_question` with accumulated history and the main transcript gains no
  records (item 10, fixture). G3 (required): Activity renders the same component and its
  answer path is the one function (a static test that `ActivityModel` constructs no card of
  its own). G4 (required): consent sheets and the trust banner render `consentNeeded` and
  `untrusted` from a lifecycle double, answer through the X5 actions, and the banner's action
  requests `openInTerminal`; with no pane runner the host's refusal renders as a banner naming
  the terminal. G5 (required, live, at most six turns): items 4, 5, 6, 7 and 41 under the
  scratch home in an isolated channel, witness at zero unattributed changes.
  **Outcome 2026-09-09:** G1–G4 met; G5's prompted half blocked by organisation policy with six turns unspent (manual witness), its zero-turn half live. Four `[parent-impact]`s: `HostSignal` unreachable
  (resolved on `main` at `2e85ac0`/`01eb7a7`), the C7.6 conditional edge, §8.4's five corrections
  and two facts, and Y3's handover point — all applied above and in the parent at this merge. Its
  tracker 157 (five row-side mounts behind C6.1's render context) became contract Y7; Activity's
  and the Thread tab's `raise` were closed on the branch before merge. Findings for the parent
  filed by the leaf: 161 (two FleetTimeline flakes, C3), 162 (no new-channel path; a Settings
  toggle with no consumer), 163 (`ScratchLiveGate` precondition, C5), 164 (`RowRegistry.shared`
  traps on a second `AppModel` — Y1's skeleton, flagged to C6.1). Merge review: three panel rounds
  (21, 16, 18 confirmed) and six waves — Activity cards keyed by request, Return owned only by an
  active card, every `permission_suggestions` entry described before *Always allow* with its
  directories named, consent evaluations fenced and the sheet bound to its request and to the
  project the fleet evaluated, a no-write *Not now*, one app-scoped reservation set for every
  answering object, thread content keyed by its subject, the reducer retaining an early
  settlement, bounded previews and diffs, the elicitation and question forms' explicit emptiness,
  null, exclusive *Other*, composition and numeric guards — closed under the hard stop with 306–319
  filed.
- **Edges:** blocked-by: the Y1 skeleton; C6.1's merge for the in-timeline row (the card
  builds and tests standalone before it); conditional-on C7.2 for Monaco diffs (attributed
  diff until then); item 47's terminal action conditional-on C7.4; blocks: C6.4 (node cards).
- **Contracts:** Y1 (fills `decision` and `sentFile`), Y2 (owner), Y3 (`.thread`), Y5, X5,
  X7.
- **Design inheritance:** §7.5, §7.6, §8.4, §6.12's consent flow (binding); card layout
  (advisory).
- **Track hint:** controlled. Tracker entries **157–171**.
- **Status:** **merged** 2026-09-09 at `0fe2797` from `child/c6-decisions` `79f4a9a`
  (79 commits). Worktree `../afleet-c6/decisions` retired.

### C6.4: Agents panel — plan

- **Purpose:** The Agents tab of §8.8 over C3's run tree, reusing C6.1's view and C6.3's
  cards; node actions; *Stop everything* and *Background all*; chip navigation; item 51's
  delivery states.
- **Acceptance:** G1 (required): with `nested-depth-2` replayed, the depth-2 tree renders
  from the two-step join before the `.meta.json` is written and is corrected by it afterwards;
  a repeated `task_started` for one task id is one node; parking renders as stated. G2
  (required): the per-run transcript renders with agent-type authorship and the model badge
  from the run's frames (item 38, fixture). G3 (required): node actions dispatch the exact
  X5 actions and control requests (`stop_task`, `background_tasks {tool_use_id}` with the
  `{backgrounded: false}` refresh, *Open transcript file* as `WorkspaceLink.file`), and
  *Stop everything* and *Background all* go through X5 behind their confirms, all on a
  lifecycle double. G4 (required): item 51's four *Not delivered* arms and the
  *Pending → Relayed → Delivered* path on `fake-claude` fixtures the leaf records from the
  scripted stand-in (no live turns for the negative arms). G5 (required): a chip click in
  C6.1's list lands on the run through Y4. G6 (required, live, at most six turns): items 9,
  49, 50, 51's positive path and 52 under the scratch home, witness at zero.
- **Edges:** blocked-by: C6.1 and C6.3 merged; blocks: recomposition.
- **Contracts:** Y2 (hosts), Y3 (`.agents`), Y4 (owner), Y5, X4, X5, X7.
- **Design inheritance:** §8.8 (data model binding, rendering advisory), §7.3's registry
  mirror and task rules, `docs/tui-parity/areas/18-agents-subagents.md`.
- **Track hint:** controlled. Tracker entries **172–186**.
- **Status:** not-dispatched, blocked-by C6.1 and C6.3. Worktree `../afleet-c6/agents`.

## Cross-Child Contracts

- **Y1 Row registry and directory ownership.** As the Design states; the skeleton is the
  orchestrator's landing on `main` before dispatch. Owner: this document; C6.1 and C6.3 fill
  it. Binds all four leaves.
- **Y2 One card component, two hosts.** Owner: C6.3. Binds C6.1 (row slot), C6.4 (node
  cards), and C5's Activity (adoption at C6.3's merge). Amended 2026-09-09 at C6.3's merge:
  C6.1's `taskRun` row hosts C6.3's `TaskCardView` on the `decision` slot's terms, and C6.1's
  list consults C6.3's `RetractionRegistry` before drawing — §8.4's eviction of
  `retractedMessageUuids` is a render-time filter, not a reducer (C6.3's D11, D15).
- **Y3 Tab handoff.** Owner: this document (X7 rides it). Binds C6.3 (`.thread`) and C6.4
  (`.agents`).
- **Y4 Chip-to-run navigation.** Owner: C6.4; C6.1 calls it. Binds both.
- **Y5 Everything through X5.** Owner: this document (X5 and X9 ride it). Binds all four.
- **Y6 Edit and the drift replacement across the row/composer seam.** Owner: C6.2 (the model
  side, landed); C6.1 calls and renders. Binds both. Named 2026-09-08 at C6.2's merge.
- **Y7 The render context: links and the fold's signal reach a row.** Owner: C6.1 (the value),
  C6.3 (the components). Binds both and C6.4. Named 2026-09-09 at C6.3's merge.

## Ordering & Dependency Map

```
main: Y1 skeleton ──► C6.1 TimelineRenderer (S7) ──┐
                 ├──► C6.2 Composer + header ───────┼──► (both merge to main)
                 └──► C6.3 DecisionCards + threads ─┘        │
      (wave 1, three worktrees; C6.3's in-timeline row       ▼
       lands when C6.1 is on main)                    C6.4 AgentsPanel ──► recomposition
C7.2 (Monaco) ─ conditional ─► C6.3's diff rendering
C7.4 (terminal panel) ─ conditional ─► item 47's terminal action
C7.6 (Browser tab)    ─ conditional ─► item 62's billing route (added 2026-09-09; unrouted `.url` opens externally until the tab registers)
```

Wave 1, on approval: C6.1, C6.2 and C6.3 in parallel; C6.3 merges after C6.1 so its row
lands into the registry C6.1 filled. Wave 2: C6.4 when C6.1 and C6.3 are on `main`. Then
recomposition. The critical path is C6.1 → C6.3 → C6.4. C7.2, C7.4 and C7.6 are conditional
edges with fallbacks, never blockers.

## Risks & Mitigations

- **S7 fails on the native path.** The fallback is a `WKWebView` timeline behind
  `TimelineRendering`; the model, rows registry and item ids are unchanged, so the swap is one
  view. Decide at C6.1's spike task, first in its plan.
- **Live turns cost money and drift.** Every replayable item is a fixture; live items are
  capped per leaf and run under the witness; a live item that fails is re-run once, then
  recorded as a finding, never looped.
- **Four leaves in one target.** Y1's directories and the two one-line touch points in
  `AppModel.swift`; a leaf editing outside its directory is a review finding; merges are
  sequential and the floor runs at each.
- **Monaco, the terminal runner and the Browser tab are in flight (C7.2, C7.4, C7.6).** All
  three are conditional edges with stated fallbacks; a leaf never waits on them (C7.6 added
  2026-09-09 at C6.3's merge for item 62's billing route).
- **The X5 queries C5 filed (tracker 74, 77).** C6.2's header actions want the owned-actions
  readback (74) and the Background list wants the roster signal (77); both are C4 correctives
  the orchestrator lands on `main` before or during wave 1 so no leaf reaches around X5.
- **A default-shaped config home has never been exercised (tracker 70).** C6's live gates
  run under the scratch home like every gate before them; the first default-shaped live gate
  is the re-pin's, not this unit's, and the risk is named here so nobody reads C6's green as
  covering it.

## Deferred / Out of Scope

The Monaco diff inside cards beyond the attributed fallback (C7.2 lands it); the terminal
pane for item 47 (C7.4); auto-mode's explain view (parent §17.8); voice; the raw-frame view
beyond what C5 ships; the quit-time shutdown hook (§7.4 *Quit*, C5's tracker 71 — owner C6,
landed by whichever C6 leaf first ships a busy indicator the dialog can name; if none does by
recomposition, it is a corrective child of this composite).

## Tracking Map

| Leaf | Artifact | Status |
|---|---|---|
| Y1 skeleton | landed by the orchestrator on `main` at `5e24f1a` (row registry keyed by `TimelineCategory`, seven leaf directories, Y4's `AgentNavigating` seam) | landed 2026-09-08 |
| C6.1 Timeline renderer | spec and plan `2026-09-08-c6.1-timeline-renderer.md` on `child/c6-timeline-renderer` (worktree `../afleet-c6/timeline-renderer`) | dispatched 2026-09-08 from `5e24f1a` |
| C6.2 Composer and header | `2026-09-08-c6.2-composer.md`; Outcomes in the child spec | **merged** 2026-09-08 at `c2dae0f` from `child/c6-composer` `4902242` (72 commits); G1–G5, G7 met, G6 half live and half blocked by organisation policy (manual witness); floor 1336 at the tip; tracker 142–156 (146, 151 closed by `main` correctives; 153 named as Y6; 147, 156 open) and 196–231 from the five-round merge review (208 and 218 closed; 209, 210 and 226 are recomposition items for C3/C4; five panel rounds, twelve waves) |
| C6.3 Decision cards and threads | `2026-09-08-c6.3-decisions.md`; Outcomes in the child spec | **merged** 2026-09-09 at `0fe2797` from `child/c6-decisions` `79f4a9a` (79 commits); G1–G4 met; G5's prompted half blocked by organisation policy with six turns unspent (manual witness), its zero-turn half live; floor 1463 at the tip; tracker 157–171; the in-timeline row lands when C6.1 merges (Y1's registry) |
| C6.4 Agents panel | spec and plan `…-c6.4-agents.md` on `child/c6-agents` | blocked-by C6.1, C6.3 |

## Decision Log

- **Four leaves.** The renderer and the composer split on the gate's own criteria (state
  owners, invariants, failure modes, verification); the parent's sketch is overturned as
  advisory content and recorded here, not as a parent revision. Rejected: three leaves as
  sketched (one context owning both the frame-time spike and the router UI), and five (cards
  and threads apart — a thread is a card's reply surface and they share the answer path).
- **All four in the app target.** §8.8's reason (renders timelines) holds for every leaf;
  Workbench stays panels-only under X1. Rejected: a `Conversation` package (a package edge
  between the row registry and the app's model for no consumer but the app).
- **One card component for the timeline and Activity.** §7.6 says both answer decisions;
  two implementations would drift on the one mapping that must not. Activity adopts the
  component at C6.3's merge rather than C6.3 forking Activity's card.
- **Chip navigation is an app seam, not a `WorkspaceLink`.** A new enum case would reach
  AfleetCore and C7.2's router mid-flight for a navigation that never leaves the app.
- **Conditional edges to C7.2 and C7.4 with fallbacks.** A leaf never waits on another
  composite's leaf; the fallback is a protocol the later arrival fills.
- **The header splits: readbacks to C6.1, menus to C6.2.** Readbacks are rendered state;
  menus are actions; the split follows the same line as the leaf cut.
- **Live budget of ten dollars.** Every replayable item is a fixture; the items that need a
  model are the ones whose acceptance names a model behaviour.

## Surprises & Discoveries

- (none yet; written at dispatch and as leaves land)

## Questions for the human gate

Answered 2026-09-08: the cut approved as written; the ten-dollar live budget approved; the
highlighter is **pure Swift, decided now** — C6.1 picks a Swift highlighting library at grill
time and records it, and no code block renders in a `WKWebView`.

1. **The cut** — four leaves as above. Recommendation: approve as written.
2. **Live budget** — ten US dollars across the unit on the scratch account, replayable items
   as fixtures. Recommendation: approve; a leaf that needs more stops and asks.
3. **Markdown highlighter** — the leaf chooses at grill time between a pure-Swift grammar set
   and a JavaScript engine in a web view; recommendation: pure Swift, because S7's point is to
   keep code blocks off `WKWebView`. Decide now on the principle or leave it to C6.1.

## Outcomes & Retrospective

Pending — written when the unit closes. Closing is a RECOMPOSITION check against
Parent-Level Acceptance as written, then the retrospective.

## Revision Notes

- 2026-09-07: v1, written at the decomposing run against parent commit `b775842`, after the
  C5 merge (`78303c7`). Flow-back to the parent at approval: the §17.9 C6 row points here; the
  sub-cut sketch in §17 C6 is superseded by this cut (advisory content, recorded as a dated
  Revision Note on the parent by the orchestrator).
- 2026-09-08: cut approved by the human; the Y1 skeleton landed on `main` at `5e24f1a` — one
  deviation from the Design: XcodeGen treats a `README.md` under `App/**` as a bundle resource, so
  `project.yml` excludes `**/README.md` rather than the directories going without an owner file.
  C6.1, C6.2 and C6.3 dispatched from `5e24f1a` in their worktrees.
- 2026-09-08: item 13 corrected from the probe (parent Revision Note of the same date) — the
  composer always supplies `last_seen_user_message_uuid`; the fork fallback is the rare path;
  C6.2's G4 re-worded.
- 2026-09-08 reconciliation of C6.2 (merge `c2dae0f` from `child/c6-composer` `4902242`,
  72 commits). Contract Y6 named from tracker 153, with a G6 on C6.1 for it; C6.1 flagged.
  Three `[parent-impact]`s resolved as `main` correctives before merge (X10 copy, `sendPrompt`,
  `quit`). Two advisory overturns applied to the parent: §8.5's Enter and §8.7's Cmd+Enter both
  send; §8.3's header list is split as this cut split it. §8.6 corrected: the engine compares
  `disableBypassPermissionsMode` to the string `"disable"`. 
- 2026-09-09 reconciliation of C6.3 (merge `0fe2797` from `child/c6-decisions` `79f4a9a`,
  79 commits). Y2 re-worded (one component and its mapping; Activity's compact
  presentation); Y2 gains the `taskRun` row and the retraction filter (C6.1 flagged); Y3 corrected
  to the `performLaunch` handover (binds C6.4 identically); the C7.6 conditional edge added; the
  Y1 paragraph records skeleton 2 and the fold. Parent §8.4 corrected in five places with two facts
  added, as C6.3's `[parent-impact]` states them. 
