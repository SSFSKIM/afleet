# Tech debt tracker

Real, small, deliberately unfixed. One entry per item: what it is, where it was observed,
what would close it. An item leaves this file when a commit closes it or a child spec
adopts it as scope. Children's own ledgers hold the full narrative; this file is the
durable index.

## From C2 (AfleetCore and ClaudeWire), merged 2026-09-05

1. **Swift 6.3.3 miscompiles `case let x:` as a switch default arm.** A switch over `Frame`
   whose default arm bound the whole value while other arms destructured it crashed the test
   process with `SIGSEGV` in `swift_release` (Xcode 26.6, swift-driver 1.148.6, arm64). The
   workaround binds the decoded value to a local and switches with a plain `default:`;
   `FixtureCorpusTests` is written this way. Closer: reduce to a minimal case and file it
   upstream. Until then prefer `default:` over `case let` in switches over enums with
   non-trivial payloads.
2. **`ProcessRunnerTests.testLargeOutputIsFullyRead` is timing-sensitive.** A 30-second budget
   for work that takes about 2 seconds still lost once on a loaded machine, and the failure
   reads as a product bug (`exitCode -1`) rather than a starved test. Closer: raise the budget
   substantially or make the assertion insensitive to machine load.
3. **`LineReader` parks a blocked thread per stream.** Two streams per session means the
   libdispatch pool is exhausted around thirty concurrent sessions. Nothing proves the reader
   threads terminate, and there is no maximum line length. Owner when it bites: C4's fleet
   scale. Closer: a non-blocking reader (`DispatchIO` or a single poll loop) and a line cap
   that ends the process rather than the memory.
4. **`ProcessRunner` accumulates output unbounded.** Its only callers are `env -0` and
   `--version`, whose outputs are small; bounded buffering belongs to `WireTransport`.
   Closer: cap it, or route new callers through the bounded channel, if a large-output caller
   appears.
5. **`ShellEnvelope`'s forged-prefix defence is syntactic, not semantic.** The zero-width
   space defeats a line-start regex, but a forged harness note still reads as one to a model;
   entity escaping reverses under any downstream HTML decode; the envelope's own omission
   notice is not neutralised. Filed on the C2 spec as a design limit. Closer: none until a
   model-visible path needs a semantic defence.
6. **`tools/list` omits an `outputSchema` the built-in tool declares**, and a duplicate
   `tools/call` id would overwrite its in-flight entry (engine ids are monotonic, so this is
   latent). Closer: add the schema; reject a duplicate id with a JSON-RPC error.
7. **Hot-path allocations in diagnostics and capture.** A `Regex` is built per frame and an
   `ISO8601DateFormatter` per event because neither is `Sendable` under language mode 6;
   `enforceBudget` runs per line with one syscall per active session. Closer: cache per actor
   and amortise the budget check.
8. **`@unchecked Sendable` beyond the plan's allowlist** (`LineReader`, `RecordingDiagnostics`,
   `DataBox`, the MCP test sink). Each was read and found sound; the C2 spec's constraint was
   amended rather than the code. Closer: none; audit each new one at review.
9. **`HookCallbackMatcher`'s `matcher` and `timeout` have no fixture witness.** The recorded
   harness only ever sent the id-only form, so the assertion pins plan prose, not evidence.
   Closer: record a fixture with a hook that declares a matcher.
10. **Fixture census `count` is a running total, not a per-file tally.** It accumulates across
    re-recordings through `merge_required`, so three censuses exceed their fixtures' line
    counts and G2's count clause is weaker than it reads. The field name promises a tally.
    Owner: C1 follow-up. Closer: rename the field or document the semantic, and restate the
    G2 clause as set equality over kinds.
## From C3 (`child/c3-timeline`)

Appended by C3. C4 also appends to this file; keep each child's entries under its own heading and do
not renumber anything above.

11. **`AgentRunTree.link` drops a self-parent answer without trace.** The guard rejects
    `parentID == id` before `parentAnswers` is written, so a source claiming a node is its own
    parent leaves no record at all — the one case where the conflict/answers structure goes
    quiet. Owner: C3 (whole-branch review). Closer: record the rejected answer instead of
    returning early.
12. **`AgentRunTree.resolveJoins` is O(n²) in agent runs, once per observation.** It walks every
    node and calls `node(withToolUse:)`, itself a linear scan; Task 8's wire reducer calls
    `observe` once per frame. Fine at corpus scale. Owner: C3 (whole-branch review). Closer: a
    `toolUseID → nodeID` index.
13. **`AgentRunTree.roots` is `parent == nil`, not "depth-1 nodes".** Documented in the source
    and identical on the corpus; they diverge only for a depth-2 node no source answered for,
    which surfaces as a root instead of vanishing. C6 reads `roots` and must be told at
    recomposition. Owner: C3 (whole-branch review). Closer: decide which reading C6 needs.
14. **Incremental reduction in `StreamIngestion.publish`.** `publish`
    (`FleetKit/Sources/FleetTimeline/Ingest/StreamIngestion.swift:884`) recomputes the whole
    projection through `recompute()` (`:858`) once per applied frame, so draining N buffered
    frames is O(N x records). Measured in Task 10: a `Task.yield()`-rate feeder made a 250 ms
    settle buffer thousands of frames and the drain ran past ten seconds. No engine emits
    mirror frames at that rate, and the settle's time cap bounds `open`, so the residual cost
    is relocated rather than removed. Owner: C6, if live rendering needs it (the C3 plan's
    Question 2 defers it deliberately). Closer: reduce incrementally, with the
    file-versus-wire projection-equality invariant as the guard.
15. **`TranscriptIndex` skips symlinked project directories.** `discoverMainFiles` filters on
    `URLResourceKey.isDirectoryKey`, which is false for a symlink URL, so a project directory
    that is a symlink contributes no session. On the author's own config home that is 14
    directories holding 1,306 of 4,337 main transcripts. Owner: C3 follow-up. Closer: decide
    whether a symlinked project *directory* is followed (X9 refuses symlinked transcript
    *files*, which is a separate rule) and resolve it in discovery if so.
16. **The index's cold build is two orders of magnitude over its budget.** Spec C3 G2 asks for
    a median under 500 ms; five builds over 3,031 files measured a 66,412 ms median. The reads
    are not the cost — the same 3,031 head-and-tail reads take about 1.3 s single-threaded —
    so it is `TranscriptIndex.makeEntry`'s substring scanning over the two 64 KiB chunks, some
    22 ms per file. The 109 MB transcript's windowed read and reduce also misses, at 1,158 ms
    against 1,000 ms. Owner: C3 follow-up, before C4 wires the index to a sidebar. Closer: one
    pass over each chunk instead of a `range(of:)` per field, and a profile of
    `WindowedTranscript.read` on the 4 MiB tail.

17. **Closed: entries 15 and 16.** Both were resolved by the G2 fix wave (`child/c3-timeline`).
    Entry 15 is closed by a ruling rather than a change: a symlinked project directory is skipped
    deliberately, because the engine skips it too (2.1.258 `cli.pretty.js:13753-13755` drops any
    directory entry whose `Dirent.isDirectory()` is false), so a session under one is a session the
    CLI itself cannot find. The build now counts the skipped directories and reports the count in
    `indexBuilt`. On the author's home all fourteen resolve to sibling directories inside the same
    `projects/`, so their 1,306 files are aliases of files already indexed and following them would
    have added no session. Entry 16 is closed by measurement: cold build 66,412 ms to 365 ms
    against a 500 ms budget, largest transcript 1,158 ms to 667 ms against 1,000 ms.
18. **`hasSubagents` narrows on a case-insensitive volume.** The build consults the slug
    directory's listing for a `<sessionId>` entry before `stat`-ing, to save a syscall per file. On a
    case-insensitive volume a directory whose name differs from the file's stem only by case would
    be found by `stat` and missed by the listing. Owner: C3/C4. Closer: compare case-insensitively
    when the volume is, or drop the hint if the syscall turns out not to matter.
19. **Small cleanups in the index and reader.** A duplicated comment around the canonical-slug
    resolution in `TranscriptIndex.swift`; a dead `buffer.removeLast` in `TranscriptReader.pread`
    (`unsafeUninitializedCapacity` already sets the count); non-conversation lines parsed twice,
    once by `RecordDecoder`'s type probe and once by the two-stage path; and `Task.detached` in
    `inParallel` escaping the caller's priority as well as its executor, which is the point of it
    but means a deliberately low-priority caller no longer gets what it asked for. Owner: C3/C4.
20. **`ClaudeWire`'s `JSONValue.init(from:)` throws up to five `DecodingError`s per value.** It
    tries `Bool`, `Int64`, `Double`, `String`, array and object in turn, so a string costs three
    thrown errors and an object five, each building a coding path and a description. This is the
    single largest remaining cost in the transcript read path and it slows every consumer of the
    package. Owner: C2 — deliberately not touched by C3, which has no mandate over that target.
    Closer: reorder the attempts (string and object first) or decode `[String: JSONValue]` directly
    where the caller knows the shape; the ordering of `Int64` before `Double` must be kept.
21. **G2's "cold" build means no persisted index and a fresh actor, not a cold page cache.** The
    365 ms median is warm steady state; a genuinely cold cache adds the SSD read of some 380 MB of
    heads and tails. Pre-existing test design, recorded so the budget's name does not mislead.
    Owner: C4, when the sidebar's first paint is measured for real.

22. **A same-uuid cross-source conflict is counted as a duplicate without comparing content.**
    `StreamIngestion.swift:478-483`: once a uuid is applied, a mirror entry carrying it is counted
    and dropped, and the inverse path binds a file locator to a mirror-retained record, neither
    comparing canonical content. Under protocol skew, a partial write or corruption the projection
    could hold one source's payload while `rawRecord` reads the other's bytes, with only a duplicate
    count to show for it. Dismissed as design intent for now: the child spec's arbitration table
    says a delivery whose key is already applied is a counted duplicate, and hashing every record on
    every uuid collision is a cost the spec deliberately does not pay. Owner: C3/C6, as hardening.
    Closer: compare canonical content on a cross-source uuid collision only, and emit a typed
    conflict notice with an explicit source-precedence or rebuild policy when they disagree.
23. **Window-root suppression can attach a rewound branch to abandoned history.**
    `RecordReducer.swift:389-403`: for an open window, `ConversationTree` exempts the first missing
    parent in *physical file order* rather than the selected chain's boundary. A bounded tail of a
    rewound transcript can begin inside an abandoned branch and only later reach the new branch's
    turn start; the abandoned record then consumes the exemption, and the real chain boundary
    becomes eligible for five-second orphan healing and can be attached to the abandoned branch. The
    reopened timeline would show discarded turns ahead of the active branch even though closure
    declared the window valid. Not fixed because there is no oracle: no fixture contains a rewind,
    which the child spec already lists as a delegated unknown owed to C1, and a fix against an
    unwitnessed path is a guess. Owner: C3/C1. Closer: have window closure carry the selected
    chain's boundary uuid explicitly in `WindowMarker` and exempt only that record, plus a rewound
    fixture above 8 MiB whose tail begins on an abandoned branch, compared against the whole-file
    leaf chain.
24. **Test temp trees are never checked against the config home.**
    `Tests/FleetTimelineTests/Support/TempTree.swift:15-16`: every test config home is created under
    `FileManager.default.temporaryDirectory` without confirming that the resolved location lies
    outside `~/.claude` and `CLAUDE_CONFIG_DIR`, so a shell whose `TMPDIR` points inside a config
    home would make the suite write there against X9. Raised by the merge-time leak-risk review; not
    fixed now because the environment is contrived (macOS sets `TMPDIR` under `/var/folders`, the
    live-test config home is a scratch tree under `/tmp`) and X9 is verified empirically by the
    recursive fingerprint taken before and after the suite. Owner: C3, and every child's test
    support. Closer: canonicalise `temporaryDirectory` in `TempTree.init` and throw `XCTSkip` with a
    fixed message when it resolves inside either config home; C4's staging helpers take the same
    guard.
25. **The wire's compact boundary loses its logical parent in C2's frame type.**
    `ClaudeWire/Sources/WireFrames/SystemFrames.swift:130-133`: `CompactBoundaryFields` declares
    `type, subtype, compact_metadata, uuid, session_id` and not `logical_parent_uuid`, which the
    engine emits whenever the record carries one (2.1.258 `cli.pretty.js:147047`) and which the
    `compact-boundary` fixture's out-direction frame carries; the key survives only in the lossless
    extras, and `FleetTimeline/Reduce/WireReducer.swift:339` passes `logicalParentUUID: nil` for the
    boundary row. No rendered field depends on it today and check two's compared shape excludes it,
    so the live timeline shows the same rows either way. Found at the C3 merge. Owner: C2, with C3
    as the consumer. Closer: declare `logicalParentUuid = "logical_parent_uuid"` as an optional
    field on `CompactBoundaryFields`, pass it through in `WireReducer`, and pin the fixture's frame
    decoding it.
