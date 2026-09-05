# C3: `FleetKit` timeline — reducers, transcript index, agent tree, registry mirror (2026-09-05)

> **Parent:** `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C3`.
> **Parent-pin:** that path at commit `ee94449` ("FleetKit: manifest skeleton with the C3 and
> C4 target groups; X1 records the split"). **Level name:** child, wave 2 of the v1 roadmap.
> **Track:** controlled. **Branch:** `child/c3-timeline`, worktree `../afleet-c3`; merges to
> `main` when G1 through G4 pass. C1 has merged, so G1's blocker (C1.G1) is discharged, and
> C2's `WireEventPolicy` corrective is on `main` at merge `ca68f2e`, so every gate is
> evaluable against that pin; where a gate names a recording the corpus does not hold, this
> document says so and the gate is stated against the corpus that exists (parent §17.6's
> pending-gate rule applies to the missing recording, never to a substitute). This document
> treats the parent's §17 C3 section and its binding inheritance (§7.3 in full, §8.8's tree
> data model, X4's field list, X4 and X7 as amended on 2026-09-05 by C7's decomposing run,
> §5's package edges) as landed; it records only the residue
> those sections leave to this child.

## Purpose

Everything afleet shows about a session is either a transcript record or a wire frame, and
the parent's one non-negotiable is that a channel looks the same whether its history came
from disk, from `transcript_mirror` frames, or from a live process (Decision Log, "The wire
reducer and the transcript reader must produce identical timeline items"). C3 is the pure
data half of `FleetKit` that makes that true: the `TimelineItem` model and its identity; the
transcript record model and the reader that turns a JSONL file into records without ever
guessing; the record reducer that folds records into the durable projection, with the
source arbitration that lets the file and the mirror feed one idempotent ingestion; the wire
reducer that folds the remaining frames into the streaming preview and the ephemeral
overlay; the transcript index that lists thousands of sessions from a head-and-tail read
in the time a click takes; the agent-run tree with its two-step join and sidecar
enrichment; the background-task registry mirror and the output-file tail; and the
differential invariant, written as a test that runs against every fixture C1 recorded; and
the queries the panels ask of a channel's timeline, beginning with the recent URLs the
Browser panel's quick-open lists. No process is spawned here. Input is files and frame streams; output is value types. When C3
is done, C4 can decide dormancy from the registry mirror, C6 can render a channel from
`DurableProjection` plus `Overlay` and an `AgentRunTree` without reading a byte of JSONL,
and the corpus stands guard over all three.

## Acceptance

The parent's gates, restated as observable behaviour. Each gate names the test target that
proves it. All of them run under `swift test --package-path FleetKit`; C3's tests live in
`FleetTimelineTests`.

- **G1 (required) — the invariant holds on every fixture, both checks, no fixture
  excluded.** `DifferentialInvariantTests` runs over every directory under `Fixtures/` (the
  count is asserted equal to the committed eighteen, not floored) and asserts, per fixture:
  *check one* — for every stream a `transcript_mirror` frame names, the entries delivered
  in frame order equal, by record identity, the records of the paired file under
  `transcript/` in the byte range appended during the recording (from that stream's
  `streams.json` offset to end of file), after skipping exactly the number of file records
  `fixture.json` declares as `unmirrored_prefix`; field-for-field equality holds except at
  the paths `mirror_identity_only` declares for a matching stream scope; `agent_metadata`
  entries are compared against the stream's `.meta.json`, field for field; and the set of
  fixtures that carry at least one mirrored stream equals a pinned set of fifteen names, so
  a fixture that silently loses its mirror fails rather than passing vacuously. *Check
  two* — the durable projection the wire reducer produces from the fixture's frames,
  delivered as the transport delivers them (control requests through C2's `WireEventPolicy`
  at `ca68f2e`, never as bare frames) and seeded from `initial/` on a resume, equals, item for item, the durable projection the record reducer produces from the
  fixture's transcript files, for the categories the wire carries
  (`ProjectionCategories.comparedWireToFile`), with identity by record uuid, subagent items
  by agent id and source file, streaming collapsed, and timestamps compared within one
  second only where both sides carry one. The record kinds compared file-to-file only are
  the named constant `ProjectionCategories.fileOnlyRecordKinds`; the overlay is asserted
  separately, from wire frames alone, for decisions, cluster labels and per-turn cost. Both
  lists are constants the renderer reads too (X4). Every record kind the corpus contains is
  either modelled or in the session-state vocabulary; a kind outside both is a named finding
  that fails the test, because an unknown kind is exactly the drift this gate exists to
  catch. The two synthetic fixtures are run through both checks and their results are
  pinned as an exact set of named findings, not asserted as passes: a synthetic fixture is
  authoritative about the shapes it was built to exercise and about nothing else (parent
  §11, §17.7). This is parent item 31.
- **G2 (required) — the index is fast enough to be the sidebar.** Two layers, because the
  parent's numbers are about the author's machine and the default suite must not read it.
  *Default suite*: `TranscriptIndexTests` assembles the corpus's transcript snapshots into a
  config-home-shaped tree under the system temporary directory and asserts the index's
  correctness — one entry per logical session (fifteen across the corpus's seventeen main
  files), the title precedence of §35.19.7, the relocated
  cwd overriding the recorded one, subagent files counted but not listed, `.meta.json`
  ignored, a `memory/` directory ignored — and that `update(changed:)` after touching one
  file re-reads that file alone (asserted by a counting file reader, not by timing).
  *Opt-in*, behind `AFLEET_LOCAL_INDEX=1`: `LocalHomeIndexTests` reads the config home the
  environment resolves (never writes, opens with `O_NOFOLLOW`), builds the index with an
  in-memory storage so no persisted snapshot exists, and asserts the median of five cold
  builds under 500 ms, an incremental update after one `touch` under 50 ms, and the
  channel history of the largest local transcript produced in under one second through the
  reader's bounded window. Its output is counts, sizes and timings, never a path, a title
  or a record (parent §6.3). The 2,989 files of parent §17.2 are 2,967 today (grounding
  below); the test prints its count rather than asserting the parent's. This is S4 and
  item 1's data half.
- **G3 (required) — the three fixtures the data half is named for replay correctly.**
  `session-mirror-relocation` and `session-mirror-resume` fold through `StreamIngestion`
  with no duplicate and no missing record (asserted as the record-key sequence of the final
  file, repeated `atis-latch`, `ai-title` and `relocated` lines included), with the stream's path rebound at `transcript_relocated` and the byte offset
  carried across the resume (item 64's reducer half). `nested-depth-2` yields a two-level
  `AgentRunTree` whose depth-2 node's parent is the depth-1 task id, with the parent read
  from the `agent_metadata` mirror entry before the sidecar exists and again from the
  `.meta.json` on disk, and whose two-step join returns the same answer when both are
  withheld (item 49's data half). `background-shell` yields a `RegistryEntry` of kind
  `local_bash` that is listed by the engine while it runs and unlisted after, a synthesised
  `TaskRunItem` completion from `task_notification`, and a `TaskOutputTailer` over the
  artifact that yields the command's output and then the parsed exit code from the trailer
  (item 61's data half). Each of these assertions was demonstrated failing against a
  deliberately broken reducer before it was accepted (parent §17.7, the discriminating-test
  rule), and the demonstrations are recorded in the plan's ledger.
- **G4 (required) — mirror frames alone drive the reducer; `mirror_error` switches to
  file-only.** With no `TranscriptWatcher` attached and no file read after the open,
  `StreamIngestion` fed only the fixture's `transcript_mirror` frames produces the same
  durable projection as the file read (item 56's data half; the recorded fixtures whose
  mirror is complete are the evidence, and `session-mirror-resume` is the counter-case
  where the file read is load-bearing and the test says so). Fed a `system/mirror_error`
  frame, the ingestion reports `.fileOnly` for the rest of that process epoch, ignores later
  mirror entries for that stream, and emits exactly one `TimelineNotice`; there is no
  recorded `mirror_error` in the corpus, so this path is exercised with C2's committed,
  bundle-modelled sample (`ClaudeWire/Tests/Support/Samples/system_mirror_error.json`) and
  is stated as shape-verified, not engine-verified.

Parent items C3 touches but does not close: 1, 31, 49, 56, 61, 64 (their UI halves belong
to C6 and C4's lifecycle to C4).

## Grounding

Measured 2026-09-05 in the worktree, against C1's corpus at `ee94449`, the local config home
(read only, counts only) and the extracted 2.1.258 bundle (`~/claude-code-bundle/2.1.258/cli.pretty.js`).

**The corpus.** Eighteen fixtures, sixteen recorded, two synthetic. Seventeen carry a
transcript snapshot of fifteen logical sessions (`plain-two-turn` and `resume-no-replay` are
two snapshots of one session, as are `session-mirror-relocation` and
`session-mirror-resume`); `zero-cost` carries none. Fifteen carry at least one mirrored stream
(the two synthetic dialogs and `zero-cost` carry none); `explore-depth-1` mirrors two
streams and `nested-depth-2` three; `session-mirror-relocation` mirrors one stream under two
paths. Across the twenty JSONL files (seventeen main, three subagent) there are 611 records
of eleven kinds — `user` 71, `assistant` 119, `attachment` 200, `queue-operation` 64,
`file-history-snapshot` 26, `file-history-delta` 4, `atis-latch` 46, `last-prompt` 46,
`ai-title` 29, `mode` 2, `relocated` 4 — and 496 mirrored entries of those eleven plus
`agent_metadata` (3), which the mirror carries and no JSONL receives. Among the uuid-less
records, thirty canonical-hash groups across fourteen files repeat: forty-eight later lines
are byte-identical to an earlier line of the same file (`atis-latch`, `ai-title`,
`relocated`), written by the engine and kept by it. **No `system` record
of any subtype appears in the corpus**, so the five system kinds the parent's §7.3 names
(`turn_duration`, `stop_hook_summary`, `local_command`, `informational`, `compact_boundary`)
are promised by the bundle and by the author's local transcripts, not witnessed here.
`user` records carrying `isMeta` (2) are file-only: no `user` frame on the wire carries
`isSynthetic` anywhere in the corpus. Attachment records come in thirteen `attachment.type`
values (`total_tokens_reminder`, `prompt_snapshot`, `skill_listing`,
`deferred_tools_delta`, `environment`, `session_context`, `date`, `agent_listing_delta`,
`model`, `deferred_tools_record`, `plan_mode`, `plan_mode_exit`, `max_turns_reached`); every
one has a `parentUuid` naming a conversation record. Conversation records form a single
rooted chain in every main file (one root, no orphan, no branch point); the depth-2 agent
file has one branch point (two records sharing a parent: parallel tool results). No fixture
contains a rewind, a compaction, a `progress` record, a `tool_progress` frame, a
`tool-results/` spill or a `mirror_error`.

**Wire and file agree by uuid.** In every recorded fixture the set of top-level `assistant`
frame uuids equals the set of the main file's `assistant` record uuids, and the wire's
`message.id` groups equal the file's; the host's own `user` frames (direction `in`) carry a
uuid that is the file record's uuid, and `--replay-user-messages` echoes each with
`isReplay`; a `user` frame with a `tool_result` block is a `user` record on disk with
`toolUseResult`. Forwarded subagent frames (`parent_tool_use_id` set) belong to the agent
stream's file, which is why the out-direction `user` set is not a subset of the main file
in `explore-depth-1` and `nested-depth-2`. `assistant` and out-direction `user` frames carry
`timestamp`; `system`, `result` and in-direction frames do not. A forked subagent's
`system/init` and `result` frames carry the **session's own `session_id`** and no
`parent_tool_use_id`, so nothing on the frame distinguishes an agent's result from the
session's; `session-mirror-relocation` also emits a `result` with `num_turns: 0` for the
relocation itself. Streaming arrives as `stream_event` with `message_start`,
`content_block_start`, `content_block_delta` (`text_delta`, `thinking_delta`,
`signature_delta`, `input_json_delta`), `content_block_stop`, `message_delta`,
`message_stop`.

**Sidecars and task files.** A subagent's `.meta.json` holds `agentType`, `description`,
`toolUseId`, `spawnDepth` and, at depth 2, `parentAgentId`; the mirror's `agent_metadata`
entry is that object plus `type`. The `<taskId>.output` artifact of an agent run holds the
same records as the agent's transcript, line for line and JSON-equal, but not the same
bytes (31,079 against 31,590; 34,705 against 35,640), so the two are one record sequence
under two serialisations, never to be compared as bytes. A background shell's output file
is the command's stdout followed by `\n[exited with code N]\n`. Task output files live at
`<realpath(tmpdir)>/claude-<uid>/<slug>/<sessionId>/tasks/<taskId>.output` (parity area 20
§20.9; bundle `H(yR(), Q(), "tasks")` at line 828391), capped at 16 MiB with an omission
notice, and for an agent the entry is a symlink into the transcript sidecar. The local
config home holds no `tasks/` directory at all: the files are outside it and ephemeral.

**The local config home** (read only): 639 project slugs; 2,967 top-level session files;
3,479 subagent transcripts beside 3,480 `.meta.json`; 442 sidecar directories, 76 of them
with `subagents/`; a `memory/MEMORY.md` under sixty slugs and PDF page renders under a few.
Session file sizes: median 99 KB, p90 364 KB, p99 5.5 MB, maximum 109 MB, 1.39 GB in all.
A full parse of the set is out of the question for a 500 ms budget; a head-and-tail read of
2,967 files is about 47 MB of reads and three system calls per file.

**The engine's own reader.** The picker reads `od = 65536` bytes from the head and the same
from the tail (`ihe`, line 13803) and returns `{mtime, size, head, tail}`; it extracts fields
by substring search, never by parsing the whole line (`Gf`, `G1`, `Ose`, `VQ`, lines 13341
to 13408); the first prompt skips `user` lines that contain `tool_result`, `isMeta` or
`isCompactSummary` (`Ett`, line 13464); title precedence is `agentName → customTitle →
aiTitle → summary → firstPrompt → "Autonomous session" → sessionId.slice(0,8)` (parity
§35.19.7). The loader keeps as conversation only records whose type is in
`Vr = {user, assistant, attachment, system, progress}` and which carry a string `uuid`
(`Qr`/`os`, line 250499); every other kind is session state, folded by the policy tables at
lines 428922 (`dts`: `transcript`, `boundary-cleared`, `accumulate`, `last-wins`) and 429460
(`vbr`: `dedup-transcript`, `always`, `route-by-agent`), which together enumerate the engine's
full record vocabulary of thirty-eight kinds: the five conversation kinds and thirty-three
state kinds. `dts` folds `progress` as `boundary-cleared`, not `transcript`; `vbr` marks every
state kind `always` and only the five conversation kinds `dedup-transcript`, so the engine
never content-deduplicates a state record — the fact the record key below is built on. The picker's drop rules hide sessions whose
`entrypoint` is `sdk-cli`, `sdk-ts` or `sdk-py` (`ckt`, line 13317) — which is every session
afleet itself spawns.

## Design

### Package and target layout

One target, `FleetTimeline`, inside the `FleetKit` package on `main`, added only inside the
manifest's C3 region (parent X1); one test target, `FleetTimelineTests`. The target depends
on `AfleetCore` and the `ClaudeWire` product and imports `ClaudeWire`; it reuses
`Lossless`, `DeclaredKeys`, `JSONValue`, `ContentBlock`, `Message`, `UserMessage`,
`MessageOrigin`, `Frame`, `SystemFrame`, `TranscriptMirrorFrame`, `WireEvent`,
`InboundRequest`, `ProcessEpoch` and `SessionID` rather than redefining any of them. Folders
inside the target mark the concerns without a compile-time wall between them: `Model/`
(items, identity, categories), `Records/` (record model and decoding), `Reader/` (files,
line scanning, head-and-tail, bounded windows), `Reduce/` (record reducer, wire reducer,
projection and overlay), `Ingest/` (source arbitration), `Index/` (the index, title
precedence, watcher, storage protocol), `Agents/` (the run tree), `Registry/` (the mirror and
the output tailer), `Diagnostics/` (typed notices). A second target is cut only when a
compile-time boundary earns it; none does today, and the umbrella `FleetKit` re-exports the
target so a consumer writes `import FleetKit`. Every public type is `Sendable`; the reducers
are value types with pure functions; the three long-lived things are actors
(`StreamIngestion` per channel, `TranscriptIndex` per config home, `TaskOutputTailer` per
file). Nothing is `@MainActor`. `@unchecked Sendable` follows C2's stated property (a
single-owner box whose every access is serialised by one named mechanism), and each use
names the mechanism.

### Vocabulary

- **Record**: one JSONL line of a transcript, or one entry of a `transcript_mirror` frame.
  Both are the same object; the mirror is a second delivery of the file's append.
- **Logical stream**: config home root, session id and stream name (`main` or
  `agent-<taskId>`). The path of the file is an alias of the stream and changes under
  relocation; the slug is derived from a cwd and is not identity.
- **Record key**: logical stream plus record identity — the record's `uuid`, or, for a kind
  that carries none, the SHA-256 of its canonical JSON together with an occurrence ordinal:
  the number of records with that hash already applied in the stream when this one is
  applied. Two byte-identical `atis-latch` lines are two records with two keys, as the
  engine's own dedup table treats them. One key is applied once, whatever delivered it and
  however many times.
- **Conversation record**: a record whose kind is `user`, `assistant`, `attachment`,
  `system` or `progress` and which carries a `uuid` — the engine's own definition.
  Everything else is a **session-state record**.
- **Durable projection**: the items reconstructible from conversation records alone.
  **Overlay**: the items and state only the wire carries. **Streaming preview**: the partial
  assistant message assembled from `stream_event` deltas until its frames arrive.
- **Leaf path**: the chain of conversation records from the root to the leaf the transcript
  names, which is what the engine renders on resume. A **branch** is a chain the leaf path
  does not include.

### The record model (`Records/`)

Records are decoded with the two-stage pattern C2 uses for frames: a line parses once into
`JSONValue`; `type` (and `subtype` for `system`) selects the model; the typed model decodes
from the same bytes wrapped in `Lossless`, so every undeclared key and every explicit null
survives a round trip and nothing in a record is ever dropped.

```swift
public enum TranscriptRecord: Sendable, Hashable {
  case user(UserRecord)                       // Lossless<UserRecordFields>
  case assistant(AssistantRecord)             // Lossless<AssistantRecordFields>
  case attachment(AttachmentRecord)           // Lossless<AttachmentRecordFields>
  case system(SystemRecord)                   // subtype-modelled where the reducer reads it, else lossless generic
  case progress(ProgressRecord)               // never stored as a message by the engine; kept, never rendered
  case agentMetadata(AgentMetadataRecord, canonicalHash: String)   // mirror-only: the .meta.json body plus `type`
  case sessionState(SessionStateRecord, canonicalHash: String)     // the engine's thirty-three state kinds: its thirty-eight-kind vocabulary minus the five above
  // the uuid-less kinds carry the SHA-256 of the line's canonical JSON (`JSONValue.canonicalData`: sorted keys, normalised
  // numbers), computed by the decoder from the stage-one value; a key is never derived from a re-encoding, whose key order is per-process
  case unknown(kind: String, JSONValue)       // a kind outside the vocabulary: kept, counted, a finding
  case undecodable(raw: Data, byteOffset: Int, reason: String) // a torn or corrupt line: kept as opaque, never fatal

  public var kind: String { get }             // the wire `type`, e.g. "user", "last-prompt"
  public var uuid: String? { get }
  public var contentHash: String? { get }    // the uuid-less kinds' canonical-JSON SHA-256 (the `canonicalHash` above); nil for a uuid record
  public func key(in stream: LogicalStream, ordinal: Int) -> RecordKey   // ordinal ignored for a uuid record; a sequence's come from `RecordKey.keys(for:in:)`
}
```

`UserRecordFields` declares `type, uuid, parentUuid, logicalParentUuid, isSidechain,
isMeta, isCompactSummary, agentId, sessionId, cwd, timestamp, version, gitBranch, slug,
entrypoint, userType, promptId, promptSource, permissionMode, toolUseResult,
sourceToolAssistantUUID, toolDenialKind, origin, queueSkipAttachments, message`;
`AssistantRecordFields` declares `type, uuid, parentUuid, logicalParentUuid, isSidechain,
agentId, sessionId, cwd, timestamp, version, gitBranch, slug, entrypoint, userType,
requestId, isApiErrorMessage, apiErrorStatus, error, effort, quotaLimits, apiBlockIndex,
attributionAgent, attributionMcpServer, attributionMcpTool, message`;
`AttachmentRecordFields` declares `type, uuid, parentUuid, isSidechain, agentId, sessionId,
cwd, timestamp, version, gitBranch, slug, entrypoint, userType, rendered, attachment` with
`attachment.type` read through `JSONValue`; `SystemRecordFields` declares `type, subtype,
uuid, parentUuid, logicalParentUuid, isSidechain, agentId, sessionId, cwd, timestamp,
content, level, durationMs, toolUseID, preventContinuation, compactMetadata, isMeta`.
`SessionStateRecord` is `Lossless<SessionStateFields>` with `type, sessionId` declared and
typed accessors for the fields the reducer and the index read: `lastPrompt`, `leafUuid`,
`explicit`, `rewound` (kind `last-prompt`); `aiTitle`, `customTitle`, `summary`; `relocatedCwd`;
`mode`; `atis`; `continuedInSessionId` (kind `continued-in`, whose writer emits `{type,
timestamp, sessionId: <source>, continuedInSessionId: <destination>}` — 2.1.258 lines 246346
and 246351 — so its `sessionId` is this file's own id, never the destination); `agentName`;
`tag`; `messageId` and `snapshot` (the two
`file-history-*` kinds); `operation` (`queue-operation`); the `cost-state` body as
`JSONValue`. `SessionStateVocabulary.kinds` is the engine's list from the two bundle tables,
pinned as a constant with the line numbers in its doc comment, and a kind absent from it
decodes as `.unknown`. `progress` is modelled only so it is recognised: the engine never
stores it as a message and remaps its uuid to its parent (parity §35.1), and the reducer
drops it from every projection while keeping it in the raw view.

Decoding never throws and never skips a line silently: a line that fails both stages
becomes `.undecodable` carrying its byte offset, the reducer emits a warning row for it
(parent §10), and `TimelineNotice.recordSkipped(kind:reason:)` records the fact without the
bytes.

### Logical streams and path aliasing

```swift
public struct LogicalStream: Hashable, Sendable, Codable {
  public let configHome: URL              // ConfigHome.root, standardised
  public let sessionID: SessionID
  public let name: StreamName
  public enum StreamName: Hashable, Sendable, Codable { case main, agent(taskID: String) }
  public init(configHome: URL, sessionID: SessionID, name: StreamName)
}
public enum TranscriptPath: Sendable, Hashable {
  case mainTranscript(slug: String), agentTranscript(slug: String, taskID: String), agentMetadata(slug: String, taskID: String)
  /// A path under `<configHome>/projects/` names a stream, or it does not name a transcript at all.
  public static func resolve(_ path: URL, under configHome: URL) -> (LogicalStream, TranscriptPath)?
  public static func path(of stream: LogicalStream, slug: String) -> URL
}
public struct RecordKey: Hashable, Sendable, Codable {
  public let stream: LogicalStream
  public let identity: Identity
  /// `hash(_:ordinal:)`: the canonical-JSON hash and the count of records with that hash already applied in the stream.
  /// A record cannot know its ordinal; whoever applies records in stream order assigns it (`keys(for:in:)` for a sequence
  /// read whole, `StreamIngestion` incrementally as deliveries arrive).
  public enum Identity: Hashable, Sendable, Codable { case uuid(String), hash(String, ordinal: Int) }
  /// Keys for records applied in this order: a uuid-less record's ordinal is the number of earlier records in the sequence
  /// with the same hash. What the reducer's callers and the tests use for a whole-file read.
  public static func keys(for records: [TranscriptRecord], in stream: LogicalStream) -> [RecordKey]
}
```

`resolve` is the only place a path becomes a stream. A `transcript_mirror.filePath` is
resolved through it; a watcher event is resolved through it; the fixture loader resolves the
`_slug_` placeholder through it because the placeholder is a slug like any other. The
session id is read from the file name (`<sessionId>.jsonl`) or the directory
(`<sessionId>/subagents/agent-<taskId>.jsonl`), never from the slug. A relocation therefore
changes nothing about identity: `StreamIngestion.relocated(mainPath:)` rebinds the alias and
carries the byte offset, and the two `filePath` values `session-mirror-relocation` records
resolve to one stream.

**Occurrence identity.** The engine writes byte-identical state records repeatedly — thirty
duplicate groups and forty-eight later occurrences across fourteen corpus files — and never
deduplicates them (`vbr`, line 429460, maps every state kind to `always`), so a uuid-less
record's key is its canonical hash *and* its ordinal, assigned by the applier in application
order: `RecordKey.keys(for:in:)` numbers a whole-file read, and `StreamIngestion` numbers
incrementally as deliveries arrive. Keys never renumber once published; the one exception is
the rewrite rebuild below, which replaces a stream's keys wholesale. Two deliveries of one
append are matched by hash and per-source occurrence past the stream's *cursor*: the k-th
unclaimed mirror delivery of a content is the k-th unclaimed file line of that content past
the cursor, whichever arrives first assigns the ordinal, and the other is a counted duplicate
(the file's binds the locator). The cursor is where `open` aligned the channel's tap against
the file it read (the arbitration section below), so a mirror entry re-delivering a uuid-less
line the open already read — a frame whose emission crossed the read, or a re-open while a
turn runs — is claimed against that line and never applied again; nothing about the channel
flow is presumed. Records `loadEarlier` prepends take fresh ordinals and move no published key.

### The transcript reader (`Reader/`)

`TranscriptReader` is a value type over one file URL with five entry points. `readAll()`
returns every record and the file's byte length; `readAppended(from offset:)` returns the
records after an offset and the new length, sealing a torn tail the way the engine does (a
final line without a terminator is held back and re-read on the next call, and a leading
`\n` the engine writes to seal a torn tail is skipped); `readWindow(policy:)` returns a
bounded window from the end, aligned back to a record boundary and then extended
backwards until the leaf path is closed, with a `WindowMarker` (`earlierAvailable: true`, `continueBefore` the offset the
next `readEarlier(before:)` continues from); `read(at:length:)` returns one record's bytes,
and every read returns `ranges: [ByteRange]` (`offset`, `length`) parallel to its records; the
reader is stream-less, and `RecordLocator` is a stream plus one of these ranges. A window is
*closed* when the leaf the file names lies inside it and the earliest record of the leaf's
chain inside it is a turn start — a `user` record that is neither a tool result nor
`isMeta` — or the file's first record; not when the chain reaches its root, which for a
never-rewound file is the whole file and would void the bound. A chain record whose parent
lies before an open window is a window root, not an orphan. `WindowedTranscript.read(_:policy:)`
owns that loop and is what `StreamIngestion.open` calls; the reader itself deals in bytes and
lines. Files are opened `O_RDONLY | O_NOFOLLOW`; a
symlink or a non-regular file is refused with a typed error. Lines are scanned for `\n` in
the raw bytes and decoded individually, so one corrupt line costs one `.undecodable` record.
The window rule for a channel open (`WindowPolicy(wholeFileUpTo:initialTail:earlierStep:)`,
defaults 8 MiB, 4 MiB, 4 MiB): a file up to 8 MiB (above the local p99) is read whole; beyond
that the initial window is the last 4 MiB, and the projection carries an `earlierAvailable`
marker the renderer turns into *Load earlier*. The contract behind that affordance is
`StreamIngestion.loadEarlier()`: it continues from the marker through
`WindowedTranscript.readEarlier`, the same closure rule one step further back, prepends the
records with fresh keys and locators, moves the marker, and returns the prepended keys in
`Effect.applied`; C6 calls it and reads nothing itself, and at offset 0 it returns an empty
effect. The differential test always reads whole files.

`HeadTailReader` is the picker's read, exactly: the first and last 64 KiB, `{mtime, size,
head, tail}`, fields by substring search with the engine's helper semantics (`G1` first
occurrence in the head, `Gf` last occurrence in the tail, `Ose` last line of a type carrying
a key, `VQ` first line carrying a key, `Ett`'s three skips for the first prompt). It is what
the index uses and nothing else does.

### The record reducer (`Reduce/RecordReducer`)

A pure function from records to a `DurableProjection`, run over one logical stream at a
time and then merged across a session's streams:

```swift
public struct RecordReducer: Sendable {
  public struct Options: Sendable { public var hideMeta = true; public var window: WindowMarker? = nil; public var locators: [RecordKey: RecordLocator] = [:]; public init() }
  public static func reduce(_ records: [TranscriptRecord], stream: LogicalStream, options: Options = .init()) -> StreamProjection
  public static func merge(_ streams: [StreamProjection], main: LogicalStream) -> DurableProjection   // agent items ordered by timestamp among main items
}
public struct ByteRange: Sendable, Hashable, Codable { public var offset: Int; public var length: Int }              // the reader's (Reader/), stream-less
public struct RecordLocator: Sendable, Hashable, Codable { public var stream: LogicalStream; public var range: ByteRange }  // a range plus the stream that owns it
public struct HiddenRecord: Sendable, Hashable, Codable {   // the payload stays on disk; `StreamIngestion.rawRecord(for:)` reads it on demand
  public var key: RecordKey; public var kind: String; public var timestamp: Date?; public var reason: Reason
  public var locator: RecordLocator?                        // nil: delivered by the mirror before the file held it; the ingestion serves it meanwhile
  public enum Reason: String, Sendable, Codable { case attachment, isMeta, isSynthetic, progress, sessionState, unknownKind }
}
public struct DurableProjection: Sendable, Hashable {
  public var items: [TimelineItem]
  public var hidden: [HiddenRecord]         // isMeta users, attachments, progress, session state: key, kind, reason, locator — never the payload
  public var branches: [Branch]             // chains the leaf path excludes; not rendered in v1
  public var session: SessionState          // title candidates, leaf, relocatedCwd, mode, clearedToEmpty, costState, continuedIn
  public var warnings: [ReadWarning]        // undecodable lines, healed orphans
  public var window: WindowMarker?          // earlierAvailable and the continuation offset
}
```

Rules, in the order they apply:

1. **Tree, then leaf.** Conversation records are placed by `parentUuid`. The leaf is the
   `leafUuid` of the last `last-prompt` record in the stream; `leafUuid: null` with
   `explicit: true` means *cleared to empty* and the projection is empty with
   `session.clearedToEmpty` set; without a `last-prompt` the leaf is the last conversation
   record. A `parentUuid` that names no record is healed to the nearest earlier record with
   the same `isSidechain` within five seconds of its timestamp (parity §35.13); an
   unhealable orphan starts its own chain and is reported in `warnings`. The rendered list
   is the leaf path; the other chains are `branches`. On the corpus every main file is one
   chain, so the leaf path is the file order — the rule matters after a rewind, which no
   fixture exercises (delegated unknown below).
2. **Assistant merging.** Records sharing `message.id` fold into one `AssistantMessageItem`
   whose id is the first record's uuid and whose provenance lists every folded key; parallel
   `Agent` tool uses in one message stay one group with the message id as the group key.
   `supersedes` on a record retracts the listed uuids from the projection.
3. **Tool calls.** A `tool_use` block opens a `ToolCallItem` keyed by its tool-use id; the
   `user` record whose `tool_result` block names that id completes it, with
   `toolUseResult` as the structured result and `toolDenialKind` as the denial; a
   `sourceToolAssistantUUID` on the result is honoured as the join when the block id is
   absent. The tool input is typed through `ToolInput.parse` for the tools whose cards need
   fields. `mcp__afleet__send_user_file` calls become `SentFileItem`s (durable, because both
   halves are records).
4. **Users and peers.** A `user` record with `isMeta` is hidden; a wire `user` frame with
   `isSynthetic` is hidden by the wire reducer, and the two are one rule with two spellings.
   A `user` record whose `origin.kind` is not `human` is a `PeerMessageItem`, authored from
   the origin.
5. **Attachments** are hidden from the projection and kept in the raw view; they are
   file-only by construction and are on `fileOnlyRecordKinds`.
6. **System records.** `compact_boundary` becomes a `CompactBoundaryItem`; one without a
   preserved segment or preserved messages is a hard truncation point and the reducer keeps
   only the boundary, the compaction summary and what follows (parent §7.3, stated
   behaviour). `informational`, `local_command`, `turn_duration` and `stop_hook_summary`
   become `NotificationItem`s marked file-only. No fixture carries any of these; the rules
   are written from the bundle and parity §35.1 and are exercised only by mutation of a
   recorded record's `type`, which is stated in the test.
7. **Subagent streams.** An agent stream reduces on its own; `merge` attaches its items to
   the `TaskRunItem` of the tool use that spawned it, orders agent items by timestamp among
   the main items, and stamps provenance with the agent id and source file. The mirror and
   the file of an agent stream may disagree in `message.stop_reason` and `message.usage`
   only; the projection's assistant item does not carry either as identity-bearing content.
8. **Session state** folds by the engine's policy: last-wins kinds keep the last, the
   `file-history-*` kinds accumulate, `relocated` overrides cwd everywhere.

### The wire reducer (`Reduce/WireReducer`)

```swift
public struct WireReducer: Sendable {
  public init(stream: LogicalStream, slug: String)     // the slug constructs agent transcript paths at spawn
  public mutating func apply(_ event: WireEvent) -> [TimelineChange]
  public mutating func apply(_ signal: HostSignal) -> [TimelineChange]
  public var durable: DurableProjection { get }      // the categories the wire carries, built from assistant/user frames
  public var overlay: Overlay { get }
  public var preview: StreamingPreview? { get }
  public var registry: RegistryMirror { get }
  public var agents: AgentRunTree { get }
}
public enum HostSignal: Sendable {                     // what only the host knows
  case promptSent(uuid: String, at: Date)
  case decisionAnswered(RequestID, outcome: DecisionOutcome)
  case rewound(toUUID: String)
  case processReplaced(ProcessEpoch)                    // a respawn: overlay resets, projection stays
  case relocated(mainPath: URL)                         // set_cwd answered: the agent tree's slug follows
}
public struct Overlay: Sendable, Hashable {              // the wire-only half: reset by `processReplaced`, marked stale by `exited`
  public var turns: [TurnSummaryItem]
  public var hooks: [String: HookRunItem]                // by hook id
  public var notifications: [NotificationItem]
  public var clusters: [ItemID: ToolClusterItem]         // by the first preceding call's item id
  public var decisions: [RequestID: DecisionItem]
  public var queue: QueueState
  public var stale: Bool
  public var banners: [Banner]
  public var sessionState: SessionStateChanged?         // ClaudeWire's payload of `SystemFrame.sessionStateChanged` (SystemFrames.swift:303); the last frame wins; nil in `.empty`
  public static let empty: Overlay
  public var items: [TimelineItem] { get }               // decisions, clusters, turns, notifications and hooks as items, for `ChannelTimeline`'s merge
}
public struct QueueState: Sendable, Hashable, Codable { public var queued: [String]; public var started: [String]; public var lastState: String? }
public struct Banner: Sendable, Hashable, Codable {
  public enum Kind: String, Sendable, Codable { case rateLimit, auth, apiRetry, modelFallback, compatibility, mirrorFileOnly }
  public var kind: Kind; public var text: String; public var epoch: ProcessEpoch; public var at: Date
}
```

The wire reducer consumes `WireEvent` exactly as `ClaudeProcess` publishes it. From
`.frame`: `assistant` and `user` frames build the durable half with the same merge, join
and hiding rules as the record reducer, keyed by the frame's uuid so check two can compare
them; `stream_event` deltas assemble the `StreamingPreview` for the current `message.id`
and are discarded when the corresponding `assistant` frames arrive (streaming collapsed);
`tool_use_summary` labels the cluster of its `preceding_tool_use_ids`; `result` becomes a
`TurnSummaryItem` whose attribution is `.prompted` when a `promptSent` is outstanding,
`.relocation` when `num_turns == 0`, and `.unprompted` otherwise — a forked agent's result
and the auto-turn after a `task_notification` both land there, because the frame itself
cannot tell them apart (grounding); `system/init` mid-session marks a turn boundary and
never a new prompt; `command_lifecycle` drives the queue state; `session_state_changed` is
kept as `overlay.sessionState` (the last frame wins, no item); `rate_limit_event`, `auth_status`, `system/notification`, `system/api_retry`, hook frames,
`permission_denied`, the model-fallback frames and `system/status` become overlay items or
banners; task frames feed the `RegistryMirror` and the `AgentRunTree` and synthesise the
completion `TaskRunItem` from `task_notification`; `tool_progress` moves the registry
entry's `lastFrameAt` and the agent node's last tool and makes no item (no fixture carries
it: unwitnessed, tested on a constructed frame); `transcript_mirror` frames are not
reduced here at all — `StreamIngestion` reads them from its own subscription of the channel's fan-out (*Open and the tap*, below), not from this reducer's; `.opaque` frames become `OpaqueItem`s.
From `.request`: a decision item in state `pending`, keyed by request id, labelled from the
payload, mirrored to the agent node when the request carries an agent id; `.policyAnswered`
and `.requestCancelled` settle it; `HostSignal.decisionAnswered` settles it with the
outcome. `.exited` closes the epoch: the overlay is kept for display and marked stale, the
preview is dropped, and a `processReplaced` on respawn resets it. `HostSignal.rewound`
truncates the wire reducer's durable half to the named uuid, which is the wire side's only
way to follow a rewind, since wire frames carry no `parentUuid`. `HostSignal.relocated(mainPath:)`
re-slugs the agent tree, whose transcript paths are computed from its current slug.

### Source arbitration (`Ingest/StreamIngestion`)

```swift
public actor StreamIngestion {
  public enum Mode: Sendable { case filePrimary, mirrorPrimary }       // the parent's build flag
  public enum State: Sendable, Hashable { case both, fileOnly(since: ProcessEpoch), mirrorOnly }   // mirrorOnly: opened on a main path that does not exist yet; the mirror is the only source until the first `fileChanged` finds the file
  public init(session: SessionID, configHome: URL, mode: Mode, diagnostics: any TimelineDiagnosticsSink, mirrorGapWindow: Duration, tapSettle: Duration)
  public struct Effect: Sendable { public var applied: [RecordKey]; public var duplicates: Int; public var routedElsewhere: Int; public var changes: [TimelineChange]; public var stateChange: State? }
  public func open(file mainPath: URL, events: some AsyncSequence<WireEvent, Never> & Sendable, policy: WindowPolicy) async throws -> DurableProjection
                                                                        // consumes the channel's tap into a buffer, reads the file, aligns the buffer against its tail, applies the rest, then keeps consuming until the tap ends or `close()`
  public nonisolated let effects: AsyncStream<Effect>                   // every effect in order — the tap's and the calls' below — what C6 folds
  public func fileChanged(_ path: URL, at: Date) async -> Effect
  public func relocated(mainPath: URL) async
  public func loadEarlier() async throws -> Effect                      // *Load earlier* (C6's contract): the next window back, prepended; `applied` lists the prepended keys
  public func rawRecord(for key: RecordKey) async throws -> JSONValue  // the raw view's read: the bytes at the key's locator, decoded and verified against the key
  public func close()                                                   // stops consuming the tap; every query still answers
  public enum RawRecordError: Error, Sendable, Equatable { case unknownKey, staleLocator }
  public var offsets: [LogicalStream: Int] { get }
  public var paths: [LogicalStream: URL] { get }                        // the current aliases
  public var projection: DurableProjection { get }
  public var state: State { get }
}
```

One ingestion per channel holds every stream of the session, a set of applied record keys
per stream, a byte offset per file, each file's `(st_dev, st_ino)` and length as captured at
open (or at the first `fileChanged` that found a file `open` did not), each stream's tail
anchor (*The rewrite arm*, below), and per stream the cursor its tap alignment fixed (below).
The arbitration table:

| Delivery | Applied when | Not applied when |
|---|---|---|
| file record, on open | always; sets the stream's offset to the file length and captures the file's `(st_dev, st_ino)` and length; the tap is already being consumed into a buffer | the main path does not exist yet: `open` does not throw; the stream starts at offset 0 and cursor 0 with no identity, and the state is `mirrorOnly` |
| file record, on the first `fileChanged` that finds a main file `open` did not | the identity is captured and the file is read from 0 by the watcher-change row (mirror-unclaimed records claimed, locators bound); the state moves to `both`, carried as the effect's `stateChange` | — |
| mirror entry buffered while `open` read | the alignment below does not claim it (then it is a mirror entry past the cursor, next row) | the alignment claims it against a line the open read (a duplicate, counted) |
| mirror entry, from the tap | its key is not yet applied and the resolved stream is this session's — for a uuid-less entry, the file holds no unclaimed line of that hash past the cursor | key already applied (a duplicate, counted); the file's earliest unclaimed line of that hash past the cursor is claimed instead (a duplicate, counted); path resolves to another session (a routing fault, a notice); state is `fileOnly` for this epoch |
| file record, on watcher change | its key is not yet applied — for a uuid-less record, no mirror delivery of that hash past the cursor is still unconfirmed | key already applied by the mirror (the locator is bound to that key) |
| `agent_metadata` entry | always, as the stream's metadata (not a timeline record) | — |
| mirror entry naming a stream with no open file | opens the stream lazily (an agent starting) | — |
| file rewritten: a shorter length, a changed `(st_dev, st_ino)`, or a tail anchor that no longer reads back | the stream is rebuilt whole through `WindowedTranscript`: records, applied set, locators and ordinals replaced; one `TimelineNotice.fileRewritten` | — (nothing is read from the stale offset) |
| `loadEarlier` | the next window back, prepended with fresh keys and locators; the marker moves | `earlierAvailable == false` (an empty effect) |

**Open and the tap.** `open` takes the channel's tap — one subscription of the channel's
per-subscriber fan-out, C4's `LifecycleAPI.events(of:)` (C4 spec v2.3 on
`child/c4-sessions-fleet`: each call yields an independent `AsyncStream<WireEvent>` carrying
every event in order), never ClaudeWire's single-consumer `WireEventStream` — and owns the
ordering between it and the file:
it starts consuming the tap into a buffer, then reads the file (whole or the initial window,
recording its length L), then waits until the tap has been quiet for `tapSettle` (20 ms by
default; the engine emits a write's frame within the millisecond, so a frame in flight at
the read lands inside it), then aligns the buffered entries against the file's tail before
it applies any of them. The mirror frame carries `filePath` and `entries` and nothing
positional, so the alignment is by content: because the tap precedes the read and the
engine writes in order, the buffer's prefix is a suffix of the record sequence the read
ended at. Walking the buffered entries in order, a uuid entry the file holds claims its
record and fixes the cursor there; uuid-less entries between two fixed points claim the
file's unclaimed uuid-less records between the same points by hash, in order; when the
buffer holds no anchor, the longest k such that its first k identities equal the file's
last k are claimed. The cursor — the end of the last claimed record, the start of the read
when nothing was claimed — is the file-side counting origin from then on: a claimed entry
is a counted duplicate, an unclaimed one is applied as a mirror entry past the cursor under
the occurrence rule, and an entry arriving later that re-delivers a line before L claims
the earliest unclaimed line of its hash past the cursor by that same rule rather than
applying again. A claim never creates a record and a wrong claim costs the latency until
the watcher shows the line, while a missed claim is a phantom no fold removes
(`queue-operation` and the `file-history-*` kinds do not fold idempotently), so the walk
claims whenever it can; one `TimelineNotice.tapAligned` per stream records the claimed and
unclaimed counts. No precondition on the channel flow is stated: a resumed mirror that
carries only later appends and C6 re-opening a channel's timeline while a turn runs are one
case, and a re-open mid-epoch needs no special handling. A main path that does not exist
yet — a fresh session before its first turn — is the one distinguished case: `open` does
not throw, the stream is created at offset 0 and cursor 0 with no file identity, the state
is `mirrorOnly` (the mirror is the only source until the file appears), and the first
`fileChanged` that finds the file captures its identity, reads it from 0 by the ordinary
rule (mirror-unclaimed records claimed, locators bound) and moves the state to `both`. An
error inside `open` after the tap task started — an unreadable file, a directory at the
path — cancels that task and finishes `effects` before it rethrows. C6 takes one
subscription for `open` and a separate one for the channel's `WireReducer`, and never feeds
frames itself; an event on the ingestion's subscription that is not a `transcript_mirror`,
a `mirror_error` or an `exited` is not this actor's and is left alone, the reducer having
its own copy — nothing is dropped. The one record a resume writes and never mirrors
is closed by the file read, which is why the watcher stays attached under `mirrorPrimary`
and why G4's `session-mirror-resume` case is stated as the counter-example. A
`mirror_error` for a stream (the tap's `system` frame), or a record the watcher delivers
that no mirror frame delivers within `mirrorGapWindow` (two seconds by default, the same
order as the engine's own write-stability windows, advisory), switches the ingestion to
`fileOnly(since:)` for the process epoch and emits one
`TimelineNotice.mirrorErrorSwitchedToFileOnly` or `.mirrorGap`. The gap is the actor's own
deadline, not a later file event's: under `mirrorPrimary` each record the watcher applied is
remembered per stream with the time it was seen until the mirror delivers it (a uuid
duplicate or a claim of a file-unclaimed record removes it); adding the first pending record
arms one sleeping task for the window, whose sweep switches the state, emits an effect
carrying the `stateChange` and the `mirrorGap` notice on `effects` with no file event
required, and re-arms while anything is still pending; `close()` cancels it; under
`filePrimary` nothing is kept. On the tap's `exited`
event every stream's file is re-read from its offset (a stream whose file does not exist yet
is skipped) and reconciled by key; a record the
file has and the projection lacks is applied, a record the projection has and the file
lacks is kept and counted in a notice, never dropped; the tap's first event under a greater
epoch lifts a `fileOnly(since:)` back to `both`. `relocated(mainPath:)` rebinds the main stream's path
and the sidecar directory, keeps every offset, and reopens nothing; a rename keeps the
inode, so the identity captured at open still matches. `rawRecord(for:)` is
how the raw view sees a hidden record: the projection carries only the `HiddenRecord`'s
locator, the actor reads those bytes on demand through its own reader (`read(at:length:)`),
decodes them and verifies that the record's `uuid`, or its canonical hash, is the key's — a
mismatch is a locator left over from a rewrite the actor has not yet seen and throws
`RawRecordError.staleLocator` rather than returning another record's bytes — and a record
the mirror delivered before the file held it is served from the record the actor retained
until `fileChanged` sees it on disk. Memory stays bounded and no consumer touches JSONL.

**The rewrite arm.** Parent §7.3: a compact boundary without a preserved segment is a hard
truncation point and local garbage collection rewrites the file to drop what precedes it
(SPEC 35.8, 35.5.13). The engine also rewrites in place without shrinking: `performRemoveByUuid`
(bundle 2.1.258 `cli.pretty.js` 430606–430644; 2.1.257 line 156853) opens the transcript
`r+`, truncates at the removed line and writes the suffix back, so the inode survives, and
with the watcher's 0.1 s latency one coalesced event can arrive after later appends pushed
the length past the old offset. Every `fileChanged` therefore checks before it reads: it
`fstat`s — a length shorter than the stream's offset, or a `(st_dev, st_ino)` other than the
one captured — and it `pread`s the stream's tail anchor, the byte range of the raw line of
the last file-located record, whose SHA-256 the actor kept; a shorter length, another
identity, a short read of the anchor or a digest other than the anchor's each means the
bytes behind the offset are not the bytes that were applied, and the stream
is rebuilt whole through `WindowedTranscript` — records, applied set, locators and
occurrence ordinals replaced, the new identity and length captured, one payload-free
`TimelineNotice.fileRewritten` emitted, `State` unchanged. The anchor is refreshed after every read and every rebuild
and skipped while the stream has no located record. This is the only event that renumbers a
published key; `rawRecord`'s verification remains the backstop only for a key queried between
the rewrite and the next `fileChanged`.

**Stream order.** `records[stream]` is held in file order by locator offset, with records
the mirror delivered and the file has not yet shown after the last located one, in delivery
order; prepending by `loadEarlier` is therefore ordinary insertion, and the reducer's
last-wins folds see the file's order once the file has caught up.

### The timeline model and its constants (`Model/`, contract X4)

```swift
public enum TimelineItem: Identifiable, Hashable, Sendable {
  case userMessage(UserMessageItem), assistantMessage(AssistantMessageItem), toolCall(ToolCallItem)
  case cluster(ToolClusterItem), taskRun(TaskRunItem), decision(DecisionItem), hookRun(HookRunItem)
  case notification(NotificationItem), peerMessage(PeerMessageItem), compactBoundary(CompactBoundaryItem)
  case sentFile(SentFileItem), turnSummary(TurnSummaryItem), opaque(OpaqueItem)
  public var id: ItemID { get }; public var timestamp: Date? { get }; public var threadParent: ItemID? { get }
  public var provenance: Provenance { get }; public var category: TimelineCategory { get }
}
public struct ItemID: Hashable, Sendable, Codable { public let stream: LogicalStream; public let key: String }
  // key: first record uuid of a message; tool-use id; task id; request id; hook id; record uuid otherwise
public struct Provenance: Hashable, Sendable {
  public var stream: LogicalStream; public var agentID: String?; public var sourceFile: URL?
  public var epoch: ProcessEpoch?; public var records: Set<RecordKey>; public var origin: Origin
  public enum Origin: Sendable, Hashable { case file, mirror, wire, synthesised }
}
public enum TimelineCategory: String, CaseIterable, Sendable, Codable { case userMessage, assistantMessage, toolCall, cluster, taskRun, decision, hookRun, notification, peerMessage, compactBoundary, sentFile, turnSummary, opaque }

public enum ProjectionCategories {
  /// Reconstructible from conversation records (parent §7.3, "the durable projection").
  public static let durable: Set<TimelineCategory> = [.userMessage, .assistantMessage, .toolCall, .peerMessage, .sentFile, .compactBoundary, .taskRun]
  /// Only the wire carries these; rendered live, not expected on reopen.
  public static let overlay: Set<TimelineCategory> = [.cluster, .decision, .hookRun, .notification, .turnSummary]
  /// Check two compares these item for item; `.taskRun` only for subagent runs, by agent id and source file.
  public static let comparedWireToFile: Set<TimelineCategory> = [.userMessage, .assistantMessage, .toolCall, .peerMessage, .sentFile, .taskRun]
  /// Record kinds that never reach the wire as conversational frames and are compared file-to-file only.
  /// `compact_boundary` left this list on 2026-09-05 (parent amendment; Revision Notes below).
  public static let fileOnlyRecordKinds: Set<RecordKindMatcher> = [
    .kind("attachment"), .system("turn_duration"), .system("stop_hook_summary"), .system("local_command"),
    .system("informational"), .userWhere(.isMeta),
    .userOrigin("task-notification"), .userWhere(.sidechainRoot)]
  /// Fields compared inside an item under check two; everything else is display or timing.
  public static let comparedItemFields: ItemFieldSet = [.role, .model, .contentBlocks(.text, .thinking, .toolUse(id: true, name: true, input: true), .toolResult(content: true, isError: true), .image, .document), .origin, .toolDenialKind]
}
```

The three category sets and the field set are the constants the parent's X4 promises: the
differential test reads them and C6's renderer reads them, so an edit to one is visible to
both. `URLSources.contributing` below is the fifth, named the same way for the same reason. `fileOnlyRecordKinds` is the parent's list plus one grounded entry, `user` records
with `isMeta`, which the corpus shows on disk and never on the wire (filed below as a
parent revision). Item payload structs (`UserMessageItem` and the rest) carry the fields
the parent's §7.3 comment lists per case, all public with public initialisers, and every
one is `Codable` so C4's store can persist a projection snapshot if it chooses to.
`ToolCallItem` stores `rawInput: JSONValue` and exposes `input: ToolInput` as a computed
property through `ToolInput.parse(name:input:)`, because `ToolInput` is `Hashable, Sendable`
and not `Codable` on `main`.

### Timeline queries (`Model/ChannelTimeline`) — inherited from X4 and X7 as amended

Design inheritance, not this child's decision: the parent's X4 and X7 were amended on
2026-09-05 by C7's decomposing run. The Browser panel's quick-open lists the URLs seen in
the current channel's tool output; X1 forbids Workbench from parsing timeline items, so the
host needs a FleetKit query for them. The rule as inherited: URL extraction from tool output
is a FleetTimeline concern, exposed as a query over the channel's timeline, computed from
the same reduced items the renderer reads so it can never disagree with what the timeline
shows. Which item kinds contribute is this child's to decide and is named as a constant like
the other lists in X4.

```swift
/// The read model the renderer holds: the durable projection, the overlay and the preview, merged in order.
public struct ChannelTimeline: Sendable, Hashable {
  public var durable: DurableProjection; public var overlay: Overlay; public var preview: StreamingPreview?
  public var items: [TimelineItem] { get }                       // merged, ordered; what the renderer reads
  public func recentURLs(limit: Int) -> [SeenURL]                // most recent first, de-duplicated
}
public struct SeenURL: Hashable, Sendable, Codable {
  public let url: URL
  public let firstSeen: ItemID; public let firstSeenAt: Date?
  public let lastSeen: ItemID; public let lastSeenAt: Date?
}
public enum URLSources {
  /// The item kinds whose text is scanned for URLs. Tool results carry dev-server and
  /// documentation URLs; assistant text carries the ones the model names; local command
  /// output carries what a slash command printed. User messages are excluded because the
  /// person typed them; thinking blocks, attachments, hidden records and captions are excluded.
  public static let contributing: Set<URLSourceKind> = [.toolResultText, .assistantText, .localCommandOutput]
}
public enum URLSourceKind: String, Sendable, Codable, CaseIterable { case toolResultText, assistantText, localCommandOutput }
```

`recentURLs(limit:)` scans the text of every item whose kind is in `URLSources.contributing`,
in `items` order, for `http` and `https` URLs (a conservative scanner: the scheme, then
characters up to whitespace or a closing quote, bracket or angle bracket, with trailing
sentence punctuation trimmed), de-duplicates by the exact URL string, orders by the last
item that mentioned each, most recent first, and returns at most `limit`. It reads
`ChannelTimeline.items`, never a frame or a record, which is what keeps it in agreement
with the rendered timeline; C7's Browser leaf calls it and applies its own dev-server
heuristic on top (parent §9.4, advisory). One recorded fact for the test: no recorded
fixture carries a URL in tool output; the synthetic `dialog-refusal-fallback` carries **one distinct
URL, sighted twice**, in assistant text (corrected 2026-09-05 during execution: an independent parse
of its `frames.ndjson` finds seven out-direction assistant text blocks and two sightings of the same
URL, so the earlier "two" was counting sightings, not distinct URLs), so `ChannelTimelineQueryTests`
asserts extraction on that fixture's shape
and on items constructed in the test for the other two kinds, and says so.

### The transcript index (`Index/`)

```swift
public actor TranscriptIndex {
  public init(configHome: ConfigHome, storage: any IndexStorage, reader: any HeadTailReading = HeadTailReader(), concurrency: Int = 16)
  public func build() async throws -> IndexSnapshot                  // cold: scan projects/*/*.jsonl, one head-and-tail read each
  public func update(changed: [URL]) async -> IndexDelta             // re-read only files whose stat changed; add/remove entries
  public func entry(_ id: SessionID) -> IndexEntry?
  public var snapshot: IndexSnapshot { get }
}
public struct IndexEntry: Hashable, Sendable, Codable {
  public let sessionID: SessionID; public var path: URL; public var slug: String
  public var cwd: String?            // `relocated.relocatedCwd` if present, else the head's `cwd`
  public var title: String; public var titleSource: TitleSource   // agentName, customTitle, aiTitle, summary, firstPrompt, fallback
  public var firstPrompt: String?; public var lastPrompt: String?; public var preview: String
  public var gitBranch: String?; public var tag: String?; public var agentName: String?
  public var mtime: Date; public var size: Int64; public var createdAt: Date?
  public var entrypoint: String?; public var sessionKind: String?; public var isSidechain: Bool
  public var teamName: String?; public var continuedIn: SessionID?; public var clearedToEmpty: Bool
  public var hasSubagents: Bool; public var turnCount: Int?     // nil until a full read has happened
}
public struct IndexSnapshot: Sendable, Codable, Hashable { public var configHome: URL; public var builtAt: Date; public var entries: [SessionID: IndexEntry]; public var schemaVersion: Int }
public protocol IndexStorage: Sendable { func load() async throws -> IndexSnapshot?; func save(_ snapshot: IndexSnapshot) async throws }
public struct InMemoryIndexStorage: IndexStorage { public init() }
public protocol TranscriptWatching: Sendable { var changes: AsyncStream<[URL]> { get }; func start() throws; func stop() }
public final class TranscriptWatcher: TranscriptWatching   // FSEvents over <configHome>/projects, 100 ms latency, coalesced per path
```

The cold build lists `projects/*/` and reads every top-level `*.jsonl` with the head-and-tail
reader in a task group of bounded width; `<sessionId>/` directories are noted for
`hasSubagents` and not descended; `memory/`, `tool-results/` and anything that is not a
session file are ignored. Discovery is a full listing every time rather than the picker's
fan-out by cwd, because afleet lists every project and because a relocated session's file
lives under a slug that its cwd no longer produces. The stamps kept per entry are `mtime`
and `size`; `update(changed:)` stats the named files and re-reads only those whose stamp
moved, adds files that appeared and removes files that vanished; it never re-reads the rest.
Entries are keyed by session id, and two files can carry one id — a later snapshot of the
session, or the same session at a new slug after a relocation with the old file not yet
gone — so the index remembers, per id, every main file it has seen carry that id (`build()`
fills the set, every `update` adds to it), and `update(changed:)` resolves its URLs first and
decides per id over that set together with the named files: it stats them all, drops the
vanished, and any surviving file keeps the entry (`updated`, with the path of the survivor
whose `mtime` is later, whichever order `changed` named them, and even when the batch named
only the file that vanished); only an id with no file left is `removed`; a session is
never `removed` and `added` in one update.
`turnCount` is nil until the channel is opened and a full read has counted it, because the
picker itself shows bytes, not a message count, and a count would cost the full parse the
budget forbids. The snapshot persists through `IndexStorage`, a two-function protocol C4
implements over its namespaced store (X6) and tests satisfy in memory; the index never
writes a file itself. The watcher is a separate unit the app starts, and a Developer toggle
that leaves it stopped is what item 56 turns off; the index and the ingestion take changes
through `update(changed:)` and `fileChanged(_:)` alone, so every test drives them without
FSEvents. The engine's picker drop rules are **not** applied here: the entry carries
`entrypoint`, `sessionKind`, `isSidechain`, `teamName` and `continuedIn` (the tail's last
`continued-in` line's `continuedInSessionId`), and the sidebar
policy (C4, X5) decides what to list — afleet's own sessions are `entrypoint: sdk-cli`, which
the terminal's picker hides and afleet must show.

### The agent-run tree (`Agents/`)

```swift
public struct AgentRunNode: Hashable, Sendable, Identifiable, Codable {
  public let id: String                                   // task id == agent id
  public var agentType: String?; public var description: String; public var model: String?
  public var status: TaskStatus; public var depth: Int; public var parent: String?; public var parentSource: ParentSource
  public var activityLine: String?; public var lastToolName: String?; public var elapsedOrigin: Date
  public var toolUseID: String?; public var children: [String]          // no stored path: `AgentRunTree.transcriptURL(of:)`
  public var startedCount: Int                            // task_started seen for this id; a repeat is the same node
  public enum ParentSource: String, Sendable, Codable { case agentMetadata, metaFile, twoStepJoin, none }
}
public struct AgentRunTree: Hashable, Sendable {
  public var nodes: [String: AgentRunNode]; public var roots: [String]; public private(set) var slug: String
  public mutating func apply(taskStarted:), apply(taskProgress:), apply(taskUpdated:), apply(taskNotification:)
  public mutating func apply(agentMetadata: AgentMetadataRecord, stream: LogicalStream)
  public mutating func apply(metaFile: URL) throws
  public mutating func observe(parentToolUseID: String?, carryingToolUseIDs: [String])   // the two-step join's input
  public mutating func observe(assistantModel: String, agentID: String)
  public mutating func apply(toolProgress: ToolProgressFrame, at: Date)   // lastToolName, activityLine of the node whose toolUseID is the frame's parentToolUseID
  public func node(_ id: String) -> AgentRunNode?                          // by task id; nil when unknown
  public func node(withToolUse toolUseID: String) -> AgentRunNode?        // the node whose spawning Task tool-use id matches; nil when unknown
  public func transcriptURL(of id: String) -> URL?                         // under the tree's current slug, computed on every call; nil for an unknown id
  public mutating func relocate(slug: String)
}
```

A node is created at the first `task_started` whose `task_type` is `local_agent` (a shell's
`task_started` carries no `spawn_depth` and no `subagent_type` and creates no node), keyed by
`task_id`; a repeat for the same id increments `startedCount` and re-arms status. The parent
link is set from the first source that answers and recorded as such: the `agent_metadata`
mirror entry at the head of the agent stream, then the `.meta.json` when read, then the
two-step join (a frame's `parent_tool_use_id` names the `tool_use` block that spawned it;
the frame that carried that block has its own `parent_tool_use_id`, which is the
grandparent), and `none` at depth 1 where no parent exists. The transcript path is
constructed at spawn from the channel's cwd slug, session id and task id and rebound on
relocation. Elapsed is ticked by the consumer from `elapsedOrigin`; the activity line is
`task_progress.description` and `last_tool_name`, replaced by `summary` when present; the
model badge comes from the run's own `assistant` frames or records, because neither the
frame nor the sidecar carries it on 2.1.259. Status normalises `killed` to `stopped`.
Parking — a finished node with running children — is a derived property the renderer asks
for, not a stored status.

### The registry mirror and output tailing (`Registry/`)

```swift
public struct RegistryEntry: Hashable, Sendable, Identifiable, Codable {
  public let id: String; public var kind: TaskKind; public var placement: Placement
  public var description: String; public var toolUseID: String?; public var outputFile: URL?
  public var status: TaskStatus; public var startedAt: Date; public var endedAt: Date?; public var lastFrameAt: Date
  public var notified: Bool; public var listedByEngine: Bool; public var epoch: ProcessEpoch
  public enum Placement: String, Sendable, Codable { case foreground, background }
}
public enum TaskKind: Hashable, Sendable, Codable { case localBash, localAgent, remoteAgent, inProcessTeammate, localWorkflow, monitorMCP, monitorWS, mcpTask, dream, autoModeScan, other(String) }
public enum TaskStatus: String, Sendable, Codable { case running, completed, failed, stopped }
public struct RegistryMirror: Hashable, Sendable {
  public var entries: [String: RegistryEntry]
  public mutating func apply(_ frame: SystemFrame, at: Date, epoch: ProcessEpoch)          // task_* and background_tasks_changed
  public mutating func apply(toolProgress: ToolProgressFrame, at: Date)                    // lastFrameAt only
  public mutating func observe(bashToolResult text: String, toolUseID: String)              // "Output is being written to: <path>"
  public func liveWork(asOf now: Date) -> [RegistryEntry]                                    // running, or started and not yet notified
  public func evictable(asOf now: Date) -> [String]                                          // notified terminal entries older than the grace
}
public actor TaskOutputTailer {
  public init(path: URL, pollInterval: Duration = .milliseconds(250))
  public func chunks() -> AsyncStream<OutputChunk>            // appended text; absence and deletion tolerated
  public func stop()
}
public struct OutputChunk: Sendable, Hashable { public var text: String; public var exitCode: Int32?; public var truncatedByEngine: Bool }
```

The mirror folds `task_started` (rich), `task_updated` (status from the patch), and
`task_notification` (terminal, `notified`, `outputFile` when non-empty), and uses
`background_tasks_changed` only as the liveness cross-check `listedByEngine`, because the
payload is thinner than the registry and excludes foregrounded rows (parity §20.8). Every
frame for a task, including `tool_progress` heartbeats, moves `lastFrameAt`, which is the
fact C4's dormant-eligibility rule reads; the heartbeat threshold itself is C4's (parent
§7.4). The Bash `tool_result` text names the output file before any task frame does, so
`observe(bashToolResult:)` binds it early. `liveWork(asOf:)` is the query C4.G2 depends on:
an entry is live while `running`, or while started and not yet `notified`; C4 adds its
uncertainty rule on top. The tailer reads bytes appended to a path, tolerates the file not
existing yet and disappearing (task files are outside the config home and ephemeral),
parses the trailing `[exited with code N]` into `exitCode` when it is at end of file, and
reports the engine's omission notice as `truncatedByEngine`. For a `localAgent` entry the
output file is a symlink to the agent transcript, so a consumer opens the agent stream
through `StreamIngestion` instead of tailing bytes; the tailer refuses a symlink for the
same reason the reader does.

### Diagnostics (`Diagnostics/`)

```swift
public protocol TimelineDiagnosticsSink: Sendable { func record(_ notice: TimelineNotice) }
public enum TimelineNotice: Sendable, Hashable {
  case mirrorErrorSwitchedToFileOnly(session: SessionID, stream: LogicalStream.StreamName, epoch: ProcessEpoch)
  case mirrorGap(session: SessionID, stream: LogicalStream.StreamName, missing: Int, epoch: ProcessEpoch)
  case mirrorRoutedElsewhere(session: SessionID, epoch: ProcessEpoch)
  case recordSkipped(session: SessionID, stream: LogicalStream.StreamName, kind: String?, reason: SkipReason, byteOffset: Int)
  case unknownRecordKind(session: SessionID, kind: String)
  case orphanHealed(session: SessionID, stream: LogicalStream.StreamName)
  case relocationFollowed(session: SessionID)
  case tapAligned(session: SessionID, stream: LogicalStream.StreamName, claimed: Int, unclaimed: Int)
  case fileRewritten(session: SessionID, stream: LogicalStream.StreamName, previousLength: Int, newLength: Int)
  case indexBuilt(files: Int, durationMs: Int)
  case indexUpdated(changed: Int, durationMs: Int)
  public enum SkipReason: String, Sendable { case invalidJSON, tornTail, notAnObject }
}
```

Every case carries identifiers, counts and fixed vocabulary; no path, no title, no record
byte. `LogicalStream` itself is not logged because it carries the config home path. C2's
`DiagnosticEvent` is a closed enum in a package below this one, so FleetKit owns its own
notice type; the app composes both sinks into the one metadata log under
`~/Library/Logs/afleet/` (parent §11's owned-files table), which is C5's to wire. `NullTimelineDiagnostics` is the default.

### The differential invariant as a test (`FleetTimelineTests/Invariant/`)

`FixtureCorpus` is the test-side loader: the fixtures root found from `#filePath`; per
fixture, `fixture.json` (name, `synthetic`, `session_id`, `unmirrored_prefix`,
`mirror_identity_only`), `streams.json`, every file under `transcript/` resolved to a
stream through `TranscriptPath.resolve` with the fixture's config-home root
`/tmp/afleet-fixtures/config-home` and the `_slug_` placeholder, and `frames.ndjson` decoded
line by line with `FrameDecoder` into `(t, direction, Frame)`.

*Check one* replays the mirror: entries of every `transcript_mirror` frame, in frame
order, grouped by resolved stream, become record keys and are compared with the appended
range of the paired file as an ordered sequence, exactly; then field for field with the
declared identity-only paths masked for matching scopes; then every `agent_metadata` entry
against the stream's `.meta.json`. The pinned set of fifteen mirrored fixtures is asserted
as a set, not a count.

*Check two* replays each fixture as the transport would have delivered it: out-direction
frames go through C2's `WireEventPolicy` — `ClaudeProcess`'s frame-to-event policy,
extracted as a pure function by the C2 corrective on `main` at merge `ca68f2e`, so the
transport and this test call the same code (the replay threads its own
`WireEventPolicy.Context`, drives `effects(for:in:receivedAt:)` and keeps only the
`.publish(event)` effects, so the engine's echo of every host-written `control_response` is
`dropUncorrelated` and no event, a correlated error-body response settles as any other, and
every cancel frame yields `cancelMCPTask`; the five `WireEventPolicyFixtureTests` on `main`
are the parity witness between the actor and the function) — so a control request arrives as `.request`, `.policyAnswered` or
`.unansweredDialog` and never as a `.frame`; in-direction frames are what the host did and
become `HostSignal`s (`promptSent` for a `user` frame, `decisionAnswered` for a
`control_response`). A fixture with an `initial/` snapshot seeds the `WireReducer` with the
record reducer's projection of that snapshot, which is what `StreamIngestion.open` gives it
on a resume. It then runs `RecordReducer` over every transcript file, merges, filters both projections to
`comparedWireToFile`, and compares item for item by `ItemID`, category and
`comparedItemFields`, printing the first difference with item ids and field names only.
The overlay assertions read the same frames and check that every `can_use_tool`,
`request_user_dialog` and `elicitation` request produced a decision item, every
`tool_use_summary` labelled a cluster, and every `result` produced a turn summary with
cost and duration.

*Discrimination.* Before the gate is accepted, each of these is demonstrated red against
a deliberate break and the run is quoted in the ledger: a mirror entry dropped from one
fixture in memory fails check one by identity; a `message.usage` mutated in a main-stream
mirror entry fails check one by field, while the same mutation in an agent stream passes
because the scope declares it; a `tool_result` uuid changed in memory fails check two by
identity; a `text` block edited in memory fails check two by field; a record's `type`
rewritten to an invented kind fails the vocabulary assertion; removing one fixture from the
listing fails the count. The tests also assert what they found — items compared per
fixture, streams compared per fixture — against an independent count from the fixture's
own records and against an outcome pinned by fixture name for all eighteen (zero for
`zero-cost`, the snapshot's items for `resume-no-replay`), so a filter that matched nothing
cannot pass and no fixture is excluded.

### Tests outside the invariant

`ReaderTests` (torn tail held back and re-read; sealed tail skipped; window alignment on the
largest fixture; the window closes at a turn start on `nested-depth-2`, extends until a
named leaf is inside on a synthetic transcript above 8 MiB, `readEarlier` paginates a
rewound synthetic transcript to offset 0 and reassembles `readAll`, and every byte range
reads back its record; symlink refused; one corrupt line yields one `.undecodable`),
`RecordModelTests` (every record in the corpus round-trips key for key through `Lossless`;
the vocabulary constant equals, as an exact dictionary, the test's own transcription of
`dts` — thirty-three state kinds, `progress` folded `boundary-cleared` — and is disjoint from
`vbr`'s five `dedup-transcript` kinds; repeated uuid-less lines keep their multiplicity under
`RecordKey.keys(for:in:)` on every corpus file; `continuedInSessionId` is read from an
invented `continued-in` line and its `sessionId` is not), `RecordReducerTests`
(leaf selection on a file with a `last-prompt`; `clearedToEmpty`; orphan healing by deleting
a parent record from a recorded stream; `supersedes`; merge by `message.id`; tool join by
block id and by `sourceToolAssistantUUID`; `isMeta` hidden), `WireReducerTests` (streaming
preview assembled and collapsed; result attribution for the relocation's `num_turns: 0` and
for `nested-depth-2`'s three results; decision lifecycle through request, the host's answer —
`permission-deny`'s recorded `deny` is the host's, `.answered` — and a policy answer from a
constructed unknown-subtype `control_request`, the only route to `.policyAnswered`;
`processReplaced`; a constructed `session_state_changed` into the overlay), `IngestionTests` (the arbitration table row by row, using
`session-mirror-relocation` for the rebind, `session-mirror-resume` for the offset, the
unmirrored record and the multiplicity of repeated uuid-less lines, `nested-depth-2` for lazy
agent streams, the `mirror_error` sample for the switch, a copy rewritten without its first
lines and a copy rewritten in place as `performRemoveByUuid` does for the rewrite arm and
`rawRecord`'s stale-locator check, a missing main file for `mirrorOnly`, the actor's own gap
deadline, the relocation's whole event list through the tap, the rewound synthetic
transcript for `loadEarlier` paginated to the root with identical uuid-less lines straddling
every page, and three synthetic straddles for the tap
alignment — anchored, unanchored, and a re-open mid-epoch while frames keep arriving), `IndexTests` (as G2 states, over fifteen
logical sessions: a later snapshot updates its entry, a relocation to a new slug updates the
path and never removes and re-adds, and the later `mtime` wins when two files carry one id
in either `changed` order, and deleting the winner alone falls back to the alias the build
saw) and `LocalHomeIndexTests`, `AgentRunTreeTests`
(depth-2 parent from each of the three sources and the same answer from all; the repeated
`task_started`; a shell creates no node), `RegistryMirrorTests` (`background-shell` row by
row; `killed` normalised; `liveWork` before and after notification; the tailer on the
artifact with its trailer), `ChannelTimelineQueryTests` (`recentURLs` on the synthetic
dialog's assistant text, on constructed tool-result and local-command items, de-duplication
and most-recent-first order, and a user message that is not scanned). The plan's test names are the ledger's index.

## Contracts

**Owned by C3.** X4 Timeline model: `TimelineItem` with its thirteen cases and payload
structs, `ItemID`, `Provenance`, `TimelineCategory`, `ProjectionCategories` with its four
constants, `RecordKey`, `LogicalStream`, `TranscriptRecord`, `DurableProjection`,
`Overlay`, `AgentRunNode` and `AgentRunTree`, `RegistryEntry` and `RegistryMirror`,
`TranscriptIndex` with `IndexEntry`, `IndexSnapshot` and `IndexStorage`, `StreamIngestion`,
`TranscriptReader`, `TaskOutputTailer`, `TimelineNotice`, `ChannelTimeline` with
`recentURLs(limit:)`, `SeenURL` and `URLSources.contributing` — all public with public
initialisers. `StreamIngestion.open` takes the channel's tap — one subscription of C4's
per-subscriber fan-out, `LifecycleAPI.events(of:)`, never ClaudeWire's single-consumer
`WireEventStream`: C6 takes one subscription for `open` and a separate one for the
`WireReducer`, folds `effects`, and never feeds frames itself.
Binds C4 (`liveWork(asOf:)`, `IndexStorage`, `IndexEntry`'s listing flags),
C6 and every leaf of its cut (the item model, the category constants, the overlay, the tree
and the transcript path of a run), and C7's Browser leaf (`recentURLs(limit:)`, under X7 as
amended).

**Bound by C3.** X1: `FleetTimeline` depends on `AfleetCore` and `ClaudeWire` alone and is
added inside the manifest's C3 region only; a test greps its imports. X3 (consumed):
`WireReducer.apply(_: WireEvent)` takes the event enum as C2 publishes it and nothing
reaches into `ClaudeProcess`; `Handshake.pending` is never read (parent X3, a wire fact).
X8: the fixture loader reads `frames.ndjson`, `fixture.json`, `streams.json`, `transcript/`
and the `mirror_identity_only` and `unmirrored_prefix` declarations in the forms C1 committed
and asks nothing of `fake-claude`; no fixture is edited to pass a test, and a suspected
fixture defect is the second hypothesis and escalates to the orchestrator. X6 (consumed through a seam, ruled 2026-09-05):
`IndexStorage` is a protocol declared in `FleetTimeline` exactly as written above; nothing
moves to `AfleetCore`; C4 implements it inside `FleetSessions`, which already depends on
`FleetTimeline`, over its namespaced store, and C3's tests satisfy it in memory with
`InMemoryIndexStorage`. C4's plan cites this line. X9: nothing here
writes under any config home; every file is opened read-only with `O_NOFOLLOW`; the
opt-in local test reads and prints counts. §6.3 as amended: notices and assertions carry
names, counts and shapes, never a path, an environment or a record.

## Delegated unknowns

S4 is answered by G2's opt-in measurement and its protocol above; S9's harness is check one
and check two. Paths the corpus does not witness, each stated as such in its test and each
a candidate for a C1 corrective recording rather than for a synthetic frame (a rewind and a
compaction are dispatched to C1 as a follow-up; C3 does not wait, and a later fixture
converts the test, never the code): a rewind (leaf
path, branches, `HostSignal.rewound`); a compaction (`compact_boundary` on disk and on the
wire, the hard truncation, and the file rewrite that follows it, modelled by rewriting a
copy without its first lines); the five system record kinds; `tool_progress` heartbeats; a
`user` frame with `isSynthetic`; a `mirror_error`; a `tool-results/` spill; a `cost-state`
record; a `progress` record. The exact orphan-healing constant is read from the bundle at
plan time (parity §35.13 states five seconds; the constant was not located in this
grounding pass and the rule is written from parity). Whether the two-second mirror-gap
window is right is empirical and advisory; it is a constant with a name.

## Parent revisions

Filed on the parent by the orchestrator on 2026-09-05 (cited here as filed, for the lineage
check at recomposition), with evidence here: (1) §7.3's
file-only exclusion list gains `user` records with `isMeta`, observed on disk and absent on
the wire across the corpus; (2) §7.3's head-and-tail read is 64 KiB each way, from the
bundle; (3) a forked subagent's `system/init` and `result` frames carry the session's own
id and no parent id, so result attribution is a host-state question, not a frame field; (4)
the `<taskId>.output` of an agent run is JSON-equal to the agent transcript and not
byte-equal, and task output files live under the temporary directory, not the config home;
(5) the engine's picker hides `entrypoint: sdk-cli`, which is afleet's own sessions, so the
listing policy must not copy it; (6) §17.2's transcript count is 2,967 today. None of these
contradicts binding content; (1) extends a binding list and was filed as such.

Filed 2026-09-05 during execution, from check two's evidence, and extending the same binding list
as (1): (7) §7.3's file-only exclusion list gains a `user` record whose `origin.kind` is
`task-notification` — the parent's own §7.3 prose already states that the `<task-notification>`
message the engine injects "is never emitted as a `user` frame", so the list was simply behind the
text; and (8) it gains the root `user` record of an agent stream — the prompt the parent injected,
which reaches the wire only as the spawning `Task` call's input. Both are witnessed on disk across
the corpus and appear on the wire only inside `transcript_mirror` frames, which the wire reducer
does not reduce. Measured over the corpus: the origin matcher selects exactly four records; the
sidechain-root matcher selects exactly the three agent-stream opening prompts and no main-stream
record, every main root carrying `isSidechain: false`. Conversely (9), §7.3's compaction paragraph
loses `compact_boundary` from that list, per the coordinator's amendment of the same date.

**Evidence for (7) and (8), recorded here for the parent Revision Note written at merge.** Measured
over the eighteen-fixture corpus on 2026-09-05 with a walk of every JSONL under `transcript/`.

*Task-notification origin* — four `user` records, whose `origin` is exactly `{"kind":
"task-notification"}`, in three fixtures: `background-shell` (uuid `376b0e02…`), `explore-depth-1`
(`22351035…`) and `nested-depth-2` (`b0aa7b8e…` and `e6692000…`). All four carry `userType:
"external"` and a `<task-notification>` content block. No other non-human `origin.kind` appears
anywhere in the corpus. Each uuid was grepped across its fixture's `frames.ndjson`: every occurrence
is an out-direction `transcript_mirror` frame, and none is a `user` frame in either direction.

*Sidechain roots* — three `user` records with `isSidechain: true` and no `parentUuid`, one at the
head of each of the corpus's three agent streams: `explore-depth-1`'s (`8f31e2f3…`) and
`nested-depth-2`'s two (`82d93d14…`, `37cd16ad…`). The rule that makes the matcher safe is that
**every sidechain root lies on an agent stream**: across all seventeen main files, every root `user`
record carries `isSidechain: false`, so the matcher cannot reach a main-stream prompt. These three
were grepped the same way, with the same result — mirror frames only, never a `user` frame. They
reach the wire only as the spawning `Task` call's input, which is a different item on a different
stream.

Both classes are therefore file-only in the precise sense the constant means: the wire reducer does
not reduce `transcript_mirror` frames — those belong to `StreamIngestion` — so no wire path can
produce them. Check two's compared-item counts moved only where these records were being counted:
`background-shell` 6 to 5, `explore-depth-1` 22 to 20, `nested-depth-2` 23 to 19.

## Questions for the human gate

The first four were ruled on 2026-09-05; the rulings are in the Revision Note for v2 and
the questions stand as the record of what was asked. The fifth was added at v2.2 and is open; v2.3 added none.

1. **Leaf path or file order.** The record reducer renders the leaf path the engine's own
   loader renders and keeps abandoned branches in `DurableProjection.branches` unrendered.
   On every recorded fixture the two are identical; they differ only after a rewind, which
   no fixture holds. Recommendation: leaf path, with branches kept for a later affordance.
2. **Corrective recordings.** A `rewind` and a `compact` fixture would turn two promised
   paths into witnessed ones before C6 renders them. Recommendation: ask C1 for both now;
   the other unwitnessed paths as they arise.
3. **Reading the author's config home in an opt-in test.** G2's numbers are only measurable
   there; the test is read-only and prints counts and timings. Recommendation: accept,
   behind `AFLEET_LOCAL_INDEX=1`, never in the default suite.
4. **Listing policy ownership.** The index carries the engine's drop-rule inputs and applies
   none; C4's sidebar policy decides. Recommendation: confirm C4 owns it, so afleet's own
   `sdk-cli` sessions are never hidden by an inherited rule.
5. **What "closed" means for the bounded window.** The reader section now defines it: the
   named leaf is inside the window and the window's earliest chain record is a turn start or
   the file's first record — not that the chain reaches its root, which for a never-rewound
   file is the whole file and would make the 4 MiB bound a fiction on the 109 MB local
   maximum. Records whose parent lies before an open window are window roots, not orphans.
   Recommendation: accept; overrule before the plan's Task 2 if the renderer should read to
   the root instead.

## Decision Log

- Decision: One `FleetTimeline` target with folders per concern, not a target per concern.
  Rationale: nothing here needs a compile-time wall, and every extra target is a manifest
  edit inside a region two children share. Rejected: `Timeline`, `WireReducer`,
  `TranscriptReader` as separate targets (parent §5's list is an example, and graded advisory).
- Decision: Records are `Lossless` wrappers decoded from the line's own bytes, with an
  `.unknown` case for kinds outside the engine's vocabulary and an `.undecodable` case for
  torn lines. Rationale: the invariant is only provable when nothing is dropped; the
  vocabulary is the engine's own table, so drift is a named finding. Rejected: a
  `[String: JSONValue]` bag per record (no typed reducer); dropping unknown kinds.
- Decision: The record reducer renders the leaf path, heals orphans as parity §35.13
  describes, and keeps branches unrendered. Rationale: it is what the engine renders on
  resume; on the corpus it equals the file order. Rejected: flat file order (renders an
  abandoned branch after a rewind); rendering branches inline (a product call, deferred).
- Decision: The wire reducer follows a rewind through `HostSignal.rewound`, not by
  inference. Rationale: wire frames carry no `parentUuid`; the host that sent
  `rewind_conversation` knows the target. Rejected: inferring from `conversation_reset`
  alone (that frame is `/clear`, not rewind).
- Decision: Result attribution is `.prompted`, `.relocation` or `.unprompted`, decided by
  `HostSignal.promptSent` and `num_turns`. Rationale: forked agents' results and auto-turns
  carry the session's own id and no parent; only host state knows whether a prompt is
  outstanding. Rejected: counting turns off `result` frames.
- Decision: `StreamIngestion` keys everything by `RecordKey` and treats paths as aliases.
  Rationale: relocation moves the file and the mirror names two paths for one stream.
  Rejected: keying by path; two reducers reconciled after the fact.
- Decision: The index reads 64 KiB head and tail with substring extraction, lists every
  slug, applies no drop rules, and leaves `turnCount` nil until a full read. Rationale:
  the picker's technique is what makes 3,000 files fit in 500 ms; afleet's own sessions
  would be dropped by the picker's rules; a count costs the parse. Rejected: full parse;
  the picker's cwd fan-out; a synthetic large file for the perf gate.
- Decision: The index persists through an injected `IndexStorage`, the watcher is a
  separate unit, and both are exercised in tests without FSEvents or a file. Rationale: the
  store is C4's (X6) and lands after C3; item 56's toggle needs the watcher detachable.
  Rejected: the index writing its own cache file; the index starting FSEvents implicitly.
- Decision: FleetKit owns `TimelineNotice`; the app composes it with C2's sink.
  Rationale: `DiagnosticEvent` is a closed enum below this package; a free-form string case
  would be the bypass shape §6.3 forbids. Rejected: asking C2 for a generic case.
- Decision: The registry mirror exposes `liveWork(asOf:)` and `lastFrameAt`; the heartbeat
  threshold stays with C4. Rationale: parent §7.4 states the rule on C4's table; C3 supplies
  the facts. Rejected: a threshold constant here.
- Decision: The tailer refuses symlinks and consumers open an agent's stream through the
  ingestion. Rationale: the agent `.output` is the transcript under another name and another
  serialisation. Rejected: tailing the symlink as text.
- Decision: `URLSources.contributing` is tool-result text, assistant text and local command
  output. Rationale: those are where dev-server, documentation and command-printed URLs
  appear; the person already knows what they typed. Rejected: user messages; thinking
  blocks; attachments and hidden records; sent-file captions. (The query itself is inherited
  from X4 and X7 as amended 2026-09-05, not decided here.)
- Decision: G2's real-machine measurement is opt-in and read-only; the default suite
  measures nothing it cannot ground. Rationale: parent §6.3 and X9. Rejected: asserting the
  parent's numbers over the fixture snapshots (meaningless at that size).

- Decision: A bounded window is closed at a turn start, not at the chain's root, and the
  loop that closes it (`WindowedTranscript.read`) sits above the byte-level reader.
  Rationale: the leaf path of a never-rewound transcript is the whole file; closure to the
  root would read the 109 MB local maximum whole on every channel open. A turn boundary is
  where the engine's own rendering can start without a dangling tool result. Rejected:
  closure to the root; treating pre-window parents as orphans (they would be healed to the
  wrong root and warned about on every open).
- Decision: Hidden records are `HiddenRecord`s — key, kind, reason and a byte locator —
  and the raw view reads a payload on demand through `StreamIngestion.rawRecord(for:)`.
  Rationale: the projection must not hold every hidden payload (a long session's attachments
  and meta users are most of its bytes), and C6 must never touch JSONL; the locator plus
  one read through C3's own reader gives both. A mirror-delivered record not yet on disk is
  served from the retained record until the file catches up. Rejected: bare `RecordKey`s
  (the raw view had nothing to show); payloads in the projection (unbounded memory).
- Decision: Check two replays a fixture through C2's `WireEventPolicy` and seeds resume
  fixtures from `initial/`, and C3 duplicates none of the transport's frame-to-event policy.
  Rationale: a copy in C3's tests would drift from the transport silently. The corrective
  landed on `main` at merge `ca68f2e` (branch commit `f187499`):
  `ClaudeWire/Sources/WireTransport/WireEventPolicy.swift` — `init(policy:handshakeRequestID:)`,
  `Context {pendingOutbound, pendingInbound, seenInbound, epoch}`, `Effect` with a
  payload-free `.kind`, `effects(for:in:receivedAt:)`, `effects(deciding:)` — with
  `WireEvent.kind` and `ClaudeProcess.wireEvents`. The actor performs the effects the function
  returns, so the two agree by construction; the five `WireEventPolicyFixtureTests` are the
  parity witness, and since no fake-claude Swift harness exists there is no separate parity
  test. The plan's Task 8 preflights the pin with `git merge-base --is-ancestor ca68f2e HEAD`.
  Rejected: feeding control requests as `.frame`s (the transport never does); excluding the
  resume fixtures (the seed is exactly what `StreamIngestion.open` provides).
- Decision: A uuid-less record's key is its canonical hash plus an occurrence ordinal,
  assigned by the applier in application order; two deliveries of one append are matched by
  hash and per-source occurrence past the alignment cursor (v2.4; v2.3 counted from the open
  offset). Rationale: the engine writes
  byte-identical state records repeatedly (forty-eight later occurrences in the corpus) and
  its own dedup table never collapses them; a content-only key drops them under mirror-only
  ingestion and makes G3's exact key sequence unreachable. Application order, not file
  order, is what keeps a published key stable when `loadEarlier` prepends. Rejected:
  content-only keys (loses records); file-order ordinals (renumber on every prepend); a
  counter inside `TranscriptRecord` (a record cannot know its own ordinal).
- Decision: `StreamIngestion.open` takes the channel's `WireEvent` tap and owns the ordering
  between it and the file — buffer the tap, read the file, align the buffer against the
  file's tail, and count occurrences from the alignment's cursor from then on. The tap is
  one subscription of C4's per-subscriber fan-out (`LifecycleAPI.events(of:)`), never
  ClaudeWire's single-consumer `WireEventStream`; the reducer reads its own subscription, so
  the ingestion leaving events that are not its own alone loses nothing (v2.5). Rationale:
  the mirror frame carries nothing positional; `queue-operation` and the `file-history-*`
  kinds do not fold idempotently, so one doubled record is a phantom queued item or a
  duplicated rewind entry; a consumer-side ordering rule cannot close the write-then-emit
  straddle at the tap; and C6 re-opening a channel's timeline while a turn runs is an
  ordinary action. A claim never creates a record, so the walk errs toward claiming: a wrong
  claim is latency until the watcher shows the line, a missed claim is a phantom. Rejected:
  the v2.3 precondition that `open` precede the epoch's first mirror entry (unenforceable at
  the tap); C6 feeding frames after its own read (moves the race, does not close it); a
  positional field in the frame (not ours to add).
- Decision: `fileChanged` detects a rewrite — a shorter length, a changed `(st_dev,
  st_ino)`, or a tail anchor (the byte range and SHA-256 of the last file-located record's
  raw line, `pread` before every append read) that no longer reads back (v2.5; v2.4 accepted
  the same-inode, non-shrinking case) — and rebuilds the stream whole, emitting
  `fileRewritten`; `rawRecord` verifies the decoded record against its key and throws
  `staleLocator` on a mismatch. Rationale: parent §7.3's garbage collection shortens the
  file behind the offset; the engine's `performRemoveByUuid` rewrites in place through one
  `r+` descriptor, so the inode survives and later appends can carry the length past the old
  offset before the coalesced watcher event lands; an appended read from a stale offset
  misses records or lands mid-line, and a stale locator would hand the raw view another
  record's bytes. Rejected: keeping old records and locators across a
  rewrite (they name bytes that no longer exist); a live-compaction policy that preserves
  pre-boundary records (the engine's own loader drops them; the raw view is not a history
  feature).
- Decision: `StreamIngestion.loadEarlier()` is the C6 contract behind *Load earlier*, and
  `WindowedTranscript.readEarlier` is the closure rule it continues through. Rationale: C6
  never reads JSONL, so without an ingestion entry point a transcript above 8 MiB would be
  a permanent suffix, against the parent's binding leaf path. Rejected: letting the renderer
  call the reader (breaks X4's no-JSONL rule); reading such files whole (the 109 MB local
  maximum).
- Decision: A main path that does not exist at `open` is `State.mirrorOnly`, not an error,
  and the mirror-gap deadline is the actor's own timer. Rationale: a fresh session has no
  file before its first turn, and `open` must not fail on the ordinary case; a gap checked
  only inside a later `fileChanged` waits for an event the coalescing watcher may never
  send, so the switch to `fileOnly` and its notice would arrive late or not at all.
  Rejected: creating the file (X9 forbids every write under the config home); polling the
  path (the first `fileChanged` is the signal); checking gaps only on file events (v2.4).
- Decision: The index remembers every main file it has seen carry a session id
  (`candidates`) and decides an update over that set together with the batch's URLs.
  Rationale: after a build that saw two files for one id, a batch naming only the vanished
  winner would otherwise remove an entry whose older alias still exists. Rejected: stat-ing
  the named files and the entry's current path alone (v2.4; misses the alias); a rescan of
  the slug on every update (the budget).

## Surprises & Discoveries

- Observation: The corpus holds no `system` transcript record of any subtype, no
  `tool_progress` frame, no `isSynthetic` user frame and no `mirror_error`. Impact: five
  reducer rules and the heartbeat fold are written from the bundle and parity, tested by
  mutation, and named as unwitnessed.
- Observation: `user` records with `isMeta` exist on disk (two) with no wire counterpart.
  Impact: a grounded addition to the file-only list; filed as a parent revision.
- Observation: A forked subagent's `system/init` and `result` carry the session's own id.
  Impact: result attribution moved to host state.
- Observation: The agent `.output` and the agent transcript are the same records under two
  serialisations. Impact: identity comparison only; the tailer never reads it.
- Observation: The engine's picker would hide every afleet-spawned session. Impact: the
  index exposes the inputs and applies no rule.
- Observation: No recorded fixture carries a URL in tool output; the only URLs in the corpus
  are two in a synthetic dialog's assistant text. Impact: the URL query is tested on that
  shape and on constructed items, and stated as such.
- Observation: The local set is 2,967 session files, 1.39 GB, with a 109 MB maximum.
  Impact: the reader's bounded window and the index's head-and-tail read are both
  load-bearing, not optimisations.
- Observation: Thirty duplicate canonical-hash groups among uuid-less records across
  fourteen corpus files, forty-eight later occurrences (`atis-latch`, `ai-title`,
  `relocated`); the engine's `vbr` table deduplicates conversation kinds only. Impact: record
  keys carry an occurrence ordinal (v2.3).
- Observation: The seventeen main transcript files are fifteen logical sessions; the two
  resume fixtures are later snapshots of two other fixtures' sessions. Impact: the index test
  pins fifteen entries and gains the snapshot and relocation update cases.
- Observation: The `dts` and `vbr` tables hold thirty-eight kinds (five conversation,
  thirty-three state), not the forty-one v2.2 stated, and `dts` folds `progress` as
  `boundary-cleared`. Impact: the count corrected; the vocabulary test asserts the exact
  dictionary.
- Observation: The `continued-in` record's destination field is `continuedInSessionId`; its
  `sessionId` is the source. Impact: the accessor, `SessionState` and the index read that
  field; a mutation test with invented ids guards it, since no fixture carries the kind.

## Outcomes & Retrospective

Pending — written at finish.

## Revision Notes

- 2026-09-05: v2.6, parent amendment applied mid-execution (coordinator, during Task 1/2).
  §7.3's file-only exclusion list has lost `compact_boundary`: the `compact-boundary` recording
  taken on `main` today shows the engine emitting the boundary on the wire as a `system` frame of
  that subtype and mirroring the record, so it is compared like any other record rather than
  file-to-file only. `ProjectionCategories.fileOnlyRecordKinds` drops `.system("compact_boundary")`
  and keeps the rest of the list. Nothing else moves: this branch's corpus carries no
  `compact_boundary` record in any fixture, so no census pin, count or name set changes, and
  `.compactBoundary` stays in `durable` and out of `comparedWireToFile` exactly as before. The new
  fixture itself is not merged here — `FixtureCorpus.committedCount` is 18 on this branch and is
  the first pin to move when this branch merges `main`.

- 2026-09-05: v2.5, third Codex pass (ten findings; nine folded, one half-dismissed by the
  coordinator). The tap is stated as one subscription of C4's per-subscriber fan-out
  (`LifecycleAPI.events(of:)`), never ClaudeWire's single-consumer `WireEventStream`; C6
  takes a separate subscription for the `WireReducer`, so the ingestion leaving non-mirror
  events alone loses nothing (the wire reducer section, *Open and the tap*, Contracts and the
  Decision Log say so). `State.mirrorOnly` gets its meaning: `open` on a missing main path
  does not throw, and the first `fileChanged` that finds the file moves the state to `both`
  (two table rows, the `State` comment); an error inside `open` cancels the tap task and
  finishes `effects` before rethrowing. The mirror gap is the actor's own deadline (armed
  when a pending file record is added, swept without a file event, cancelled by `close()`),
  removed on both mirror-side claim paths, nothing kept under `filePrimary`. The rewrite arm
  gains a tail anchor — the byte range and SHA-256 of the last file-located record's raw
  line, `pread` before every append read — closing the same-inode, non-shrinking rewrite
  v2.4 accepted, grounded in the bundle's `performRemoveByUuid` (2.1.258 `cli.pretty.js`
  430606–430644; 2.1.257 line 156853). `Overlay` is declared in full beside `WireReducer`,
  with `QueueState` and `Banner` (all three were named and never listed), and
  `sessionState: SessionStateChanged?` is where `session_state_changed` lands;
  `AgentRunTree.node(_:)` and `node(withToolUse:)` are declared. The index keeps
  `candidates` per session id and decides updates over them. Tests outside the invariant
  name the new cases: the decision lifecycle's policy answer comes from a constructed
  unknown-subtype request and `permission-deny`'s recorded `deny` is the host's answer;
  `loadEarlier` is checked with identical uuid-less lines across every page and compared by
  content, not key numbering; a missing main file; the actor's gap deadline; the
  relocation's whole event list through the tap; the in-place rewrite; deleting the index
  winner alone. Two decisions added. The plan's count fixes (18 streams compared, Task 5's
  fifteen) touch no spec text.
- 2026-09-05: v2.4, coordinator ruling on the precondition v2.3 stated (open before the
  epoch's first mirror entry): withdrawn, not restated. `StreamIngestion.open(file:events:policy:)`
  takes the channel's tap and owns the ordering — it buffers the tap before reading the file,
  waits for the tap to settle, aligns the buffered entries against the file's tail (a uuid
  anchor fixes the cursor exactly; uuid-less entries between fixed points match by hash in
  order; without an anchor, the longest k such that the first k buffered identities equal the
  file's last k), applies what the alignment does not claim as mirror-only, and counts
  occurrences from the cursor rather than the open offset from then on; an entry arriving
  after the alignment that re-delivers a line before the read's end claims the earliest
  unclaimed line of its hash past the cursor. A re-open mid-epoch needs no special case.
  Surface: `apply(mirror:)`, `mirrorError` and `processExited` leave the public block — the
  tap drives them — and `effects`, `close()`, `tapSettle:` and `mirrorGapWindow:` (which the
  plan's initialiser already had) join it; `open`'s label is `file:` as the ruling wrote it,
  `relocated(mainPath:)` keeps its label because `HostSignal.relocated(mainPath:)` shares it;
  `TimelineNotice.tapAligned` records the claimed and unclaimed counts. Contracts: C6 obtains
  the channel's tap from `FleetSessions` and hands it to `open`; it never feeds frames itself.
  Decision Log entry added; the occurrence decision's rationale now counts from the cursor.
- 2026-09-05: v2.3, declaration audit before the third review (no design change). The
  `TranscriptRecord` block gains `contentHash` and `key(in:ordinal:)`, which the v2.3 prose and
  the plan already had while the block still read `key(in:)`; the reader's window is named
  `WindowMarker` where it is returned; the identity paragraph says `relocated(mainPath:)` as
  the `StreamIngestion` block does; the occurrence-matching paragraph states its precondition
  (open before the epoch's first mirror entry, at an offset no later than that entry).
- 2026-09-05: v2.3, after the Codex adversarial review of plan v2 (eight findings, all
  verified real and accepted, each shaped by a coordinator ruling) and a merge of `main` at
  `ca68f2e` (C2's `WireEventPolicy` corrective; the corpus unchanged). Record keys: a
  uuid-less record's identity is its canonical hash plus an occurrence ordinal assigned in
  application order (`Identity.hash(_:ordinal:)`, `RecordKey.keys(for:in:)`), grounded in the
  engine's `vbr` table, which never deduplicates state records; the arbitration table
  matches deliveries by per-source occurrence index. Ingestion: a file-rewrite arm on
  `fileChanged` (parent §7.3's garbage collection) keyed on a shorter length or a changed
  `(st_dev, st_ino)`, rebuilding the stream whole with a new `TimelineNotice.fileRewritten`;
  `rawRecord` verifies the record against its key and throws `RawRecordError.staleLocator`;
  `loadEarlier()` is the C6 contract behind *Load earlier*, through
  `WindowedTranscript.readEarlier`; `records[stream]` is held in file order. Reader:
  `ByteRange` and `ReadResult.ranges` are the reader's, `RecordLocator` wraps a range with
  its stream, and `WindowPolicy` has a memberwise initialiser. Check two names the
  `WireEventPolicy` pin, the three behaviours the replay models and the five fixture tests
  as the parity witness; the "every gate is evaluable" sentence names the pin.
  `continued-in` reads `continuedInSessionId`. The record vocabulary is thirty-eight kinds
  (thirty-three state; `dts` folds `progress` as `boundary-cleared`), not forty-one. The
  index holds one entry per logical session, fifteen across seventeen files, and
  `update(changed:)` decides per id. Four decisions and four surprises added; no new
  question.
- 2026-09-05: v2.2, after the Codex adversarial review of plan v1 (eight findings, all
  accepted, two shaped by the coordinator) and a merge of `main` at `7a51d56` (C2's
  `SessionStart.forkFrom(SessionID, at: ForkPoint)`, X5's `PaneRequest.id`, C1's rewind-turn
  and compact-boundary scenarios written with recordings pending the usage reset; the corpus
  is still eighteen). Surface changes: `DurableProjection.hidden` is `[HiddenRecord]` — key,
  kind, reason and a `RecordLocator` — and `StreamIngestion.rawRecord(for:)` reads a hidden
  payload on demand, so the projection holds no payloads and C6 never touches JSONL;
  `StreamIngestion.paths`; `HostSignal.relocated(mainPath:)`; `AgentRunNode` loses its stored
  `transcript` for `AgentRunTree.transcriptURL(of:)` and `relocate(slug:)`;
  `AgentRunTree.apply(toolProgress:at:)` and `tool_progress` routed to the registry and the
  tree; `TranscriptRecord.agentMetadata` and `.sessionState` carry the canonical hash the
  decoder computed (v2.1 keyed uuid-less records by a `JSONEncoder` re-encoding, whose key
  order is per-process); `ToolCallItem.input` is computed because `ToolInput` is not
  `Codable`; `TranscriptReader.read(at:length:)` and per-record locators;
  `RecordReducer.Options.locators`. The bounded window's "closed" is defined — turn-start
  rule, window roots are not orphans — and filed as gate question 5. Check two is restated:
  replayed through C2's `WireEventPolicy` (a corrective the coordinator dispatches; C3
  duplicates nothing), seeded from `initial/`, all eighteen fixtures compared with a per-name
  pinned outcome; G1 says "no fixture excluded".
- 2026-09-05: v2.1, at planning. Signatures aligned with the plan's: `readWindow(policy:)`,
  `StreamIngestion.Effect` nested with a `routedElsewhere` count and an `offsets` view,
  `WireReducer.init(stream:slug:)`, `AgentRunTree.observe(parentToolUseID:carryingToolUseIDs:)`.
  Plan: `docs/doperpowers/plans/2026-09-05-c3-fleetkit-timeline.md`.
- 2026-09-05: v2, after the orchestrator's review. Rulings on the four questions: (1) the
  leaf path is rendered and branches are kept unrendered; (2) a rewind and a compaction
  recording are a C1 follow-up dispatched separately, C3 tests both paths by mutation, names
  them unwitnessed and does not wait; (3) the opt-in read of the author's config home behind
  `AFLEET_LOCAL_INDEX=1` is accepted, read-only, counts and timings only, never in the default
  suite; (4) listing policy is C4's under X5, the index carries the inputs and applies no drop
  rule. One ruling settling C4's store question: nothing moves to `AfleetCore`;
  `IndexStorage` stays a protocol declared here, C4 implements it in `FleetSessions` over its
  namespaced store, and C3's tests satisfy it in memory (Contracts, X6). The six parent
  revisions are filed on `main` and cited as filed. The recent-URL query stays as inherited.
- 2026-09-05: v1, written at dispatch against parent commit `ee94449`. Folds in, as design
  inheritance, the X4/X7 amendment C7's decomposing run filed the same day: the channel's
  recent-URL query (`ChannelTimeline.recentURLs(limit:)`) with `URLSources.contributing`.
