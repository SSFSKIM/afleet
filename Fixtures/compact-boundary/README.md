# compact-boundary

A resume of `plain-two-turn` in which `/compact` is sent as a user message and the engine runs
the compaction. Recorded 2026-09-05 on 2.1.259 under the scratch config home, in the scratch
cwd `/tmp/afleet-fixtures/plain-two-turn`, session `8cc24a21-6251-4783-b526-3957214d26a6`,
immediately after `rewind-turn` left that session with a rewound leaf.

Serves `C3.G1` and `C3.G3`, and is the corrective recording C3 asked C1 for against parent
§7.3's compaction clause. It is the first compaction anywhere in the corpus.

## `/compact` is honoured headless

Sent as an ordinary `user` frame on the stream-json input, `/compact` runs. There is no
control request for a compaction, so this is the only way a host on this protocol can ask for
one, and the recording settles that it works. The turn's `result` is
`subtype: "success"`, `is_error: false`, **`num_turns: 0`**, `result: ""`, and
`total_cost_usd` about 0.0059 with an all-zero `usage` block — so a host that counts turns or
sums tokens from `result` sees nothing, while the cost field alone shows the summary was
generated. A compaction is a paid turn that does not look like one.

## §7.3 is wrong about `compact_boundary` reaching the wire

§7.3 lists `compact_boundary` among the `system` records that reach the file and never the
wire, and therefore among the record kinds C3's differential invariant compares file-to-file
only. **This recording shows it on the wire.** The engine emits a
`system` frame with `subtype: "compact_boundary"` carrying

```
type, subtype, session_id, uuid, logical_parent_uuid, compact_metadata
```

and `compact_metadata` in snake_case:

```
trigger, pre_tokens, post_tokens, cumulative_dropped_tokens, duration_ms,
preserved_segment {head_uuid, anchor_uuid, tail_uuid},
preserved_messages {anchor_uuid, uuids, all_uuids}
```

The same record also arrives in a `transcript_mirror`. So `compact_boundary` should come off
§7.3's file-only exclusion list; leaving it there means the differential test never compares a
record the wire does deliver. This is a `[parent-impact]` finding and the parent's tending
session owns the edit.

## The record on disk, and its `compactMetadata`

The file gains a `system` record with `subtype: "compact_boundary"` whose keys are

```
type, subtype, uuid, parentUuid, logicalParentUuid, sessionId, timestamp, cwd, gitBranch,
slug, entrypoint, userType, version, isMeta, isSidechain, level, content, compactMetadata
```

with `content: "Conversation compacted"`, `level: "info"`, `isMeta: false`, `parentUuid: null`
and `logicalParentUuid` naming the assistant record the compaction was anchored at.
`compactMetadata` is the camelCase twin of the wire's `compact_metadata`:

```
trigger, preTokens, postTokens, cumulativeDroppedTokens, durationMs,
preservedSegment {headUuid, anchorUuid, tailUuid},
preservedMessages {anchorUuid, uuids, allUuids}
```

`trigger` is `"manual"` here, which is the value a `/compact` produces; an automatic
compaction's value is not observed by this recording. On this run `preTokens` was 22072 and
`postTokens` 922, with 21150 cumulative dropped tokens and a 6133 ms duration.

**`parentUuid: null` on the boundary record is the detail a reducer must not miss.** The
boundary starts a new chain rather than extending the old one; `logicalParentUuid` is the only
link back. A reducer following `parentUuid` alone sees two disjoint trees in one file.

## The compaction summary

The summary is a `user` record — not a `system` record and not an `assistant` one — carrying
`isCompactSummary: true` and `isVisibleInTranscriptOnly: true`, with an ordinary
`message {role, content}`. **Seventeen** records are appended in total: two `queue-operation`,
an `ai-title`, a `mode`, a `permission-mode`, an `atis-latch`, a `bridge-session`, the
`compact_boundary`, four `user` records (the summary, one `isMeta`, and two ordinary), four
`attachment` records, and — as the file's last line — a `last-prompt`.

That trailing `last-prompt` is written during shutdown, after the `end_session` exchange, and
it is why `fixture.json`'s notes count sixteen where this README counts seventeen: the
scenario reads the file at `wait_result` and the engine was not finished with it. Read the
notes as what the run saw at that moment and the committed `transcript/` as the resting state.
`rewind-turn` shows the same shutdown write, so it is not particular to a compaction.

## What the mirror carried

**Eight** `transcript_mirror` frames follow the `/compact`, carrying seventeen records between
them, including the `system/compact_boundary` and all four `user` records. The eighth arrives
after the `end_session` request and response and carries the trailing `last-prompt`; the first
seven, carrying sixteen, are the ones that land before the `result`.

**The `system/init` is displaced, not duplicated.** The whole recording carries exactly one
`system/init`, which is the ordinary count — `rewind-turn` carries one for its one prompt, and
`plain-two-turn` one for each of its two. What is unusual is *where* it sits: not at the start
of the turn, where every other fixture puts it, but late, after all the pre-compaction mirrors
and immediately before the boundary frame. A host that keys anything on "init means the turn is
starting" — a spinner, a turn boundary, a context reset — gets it here at the moment the
context is replaced instead, most of the way through the prompt it belongs to.

## The file is not rewritten

The transcript grew from 66 records to 83. Nothing before the boundary was dropped, so §7.3's
sentence about local garbage collection rewriting the file to drop what precedes a boundary
without a preserved segment is not exercised here — this compaction *has* a preserved segment
(`preservedSegment` names a head, an anchor and a tail). A hard-truncation compaction remains
unrecorded.

## Two things a reviewer will ask about

**`bridge-session` records.** The transcript carries `bridge-session` records with
`bridgeSessionId`, `ownerAccountUuid` and `ownerOrganizationUuid`. The two uuids are redacted
to `<ownerAccountUuid>` and `<ownerOrganizationUuid>`; catching them required widening
redaction rule 1 to match `account` and `organization` as substrings, because the exact-match
key set walked past the `owner`-prefixed forms and `verify` passed the fixture with live
account and organization uuids in it. The `bridgeSessionId` (`cse_…`) is deliberately kept: it
is an opaque server-side handle, it is not named by rule 1 or rule 2, and the corpus keeps
session identifiers by design — but it is a judgement, and it is written here so a reviewer
makes it rather than inherits it.

These records were already in the live transcript before this wave's first recording — the
file held them from record 33 onward, past where `resume-no-replay` ends at 32 — so they are
not an artefact of this wave. Their most likely origin is the interactive holder
`spike-contention` ran against this session, which connects remote control; this wave did not
verify that.

**`rate_limit_event`.** As in `rewind-turn`, an informational
`rate_limit_info.status: "allowed"` frame, not a rejection.
