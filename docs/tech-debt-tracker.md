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
   2026-09-07: The instance in `FleetFacadeTests.testOpenListsTheChannelAndPublishesEveryTransition` was converted to delivery-fulfilled waits in `761b748`; the C5 branch's entry 56 closes at its merge.
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

## From C4 (`child/c4-sessions-fleet`)

Appended by C4, continuing after C3's block. Keep each child's entries under its own heading and
do not renumber anything above.

26. **`ChannelSupervisor.terminatedEpochs` entries are never consumed for an epoch whose exit
    the pump filters out.** One `UInt64` stays in the set per wedge, and per exit that lands
    after a respawn has already moved the epoch on. It is tidiness, not a leak, and it is
    deliberately not being fixed; it is logged so the whole-branch review does not rediscover
    it. Owner: C4. Closer: none planned.
27. **`CLIVerbs`' twenty-second default may be too short for `claude --bg` against a cold or
    contended daemon.** `Verbs/CLIVerbs.swift:64` defaults to twenty seconds and `Fleet` builds
    its verbs with that default (`Fleet.swift:78-79`), so `sendToBackground`, `performJob` and
    every `jobs()` reconcile run at twenty seconds in production. G5's live gate had to raise
    its own separate instance to 180 s and still saw one failure: the daemon log of the failing
    run shows about seventy seconds between the verb being invoked and
    `[bg] bg spawned <short> (shell)` appearing, while earlier scenarios' workers and spares
    were still settling in the same config home. Run from a shell against a warm daemon the same
    command returns in 0.8 s whether its output is piped or redirected, so this is contention,
    not pipe inheritance. Observed on `2.1.261`, 2026-09-05: the exec-job scenario passed at
    9.1 s and 50.7 s and failed against ceilings of 90 s and 180 s. Owner: C4. Closer: measure
    the verb under a deliberately cold daemon and set the default from that, rather than raising
    it blind; consider whether a `--bg` verb should have a different budget from `agents --json`.
    **Closed** 2026-09-06. The second merge-evidence run turned the guess into a failure with a
    signature: `verbFailed(verb: "stop", exitCode: -1)`, where `-1` is the runner reporting that
    the client had not exited when the settle fired — the timeout chain and nothing else. The
    daemon log of that run shows job `5cfb47fd` spawned at 08:00:14.325 and `settled (killed)` at
    08:00:36.206, twenty-two seconds later: the kill landed just after the runner had SIGTERMed the
    `stop` client. A mutation abandoned at twenty seconds that the daemon then honours anyway is
    the worst of both outcomes. Measured afterwards from a shell against 2.1.263 in the same
    scratch home: `claude --bg --exec 'sleep 300'` returns in **1.1 s**; `claude stop <short>`
    returns in **0.70 s**, with the daemon logging `settled (killed)` within a second and roster
    and registry both empty two seconds later; `agents --json` **0.2 s**; `rm` **0.7 s**. The
    engine's own stop is fast, so the budget is about reaching a daemon that may be cold — the
    2.1.263 daemon is transient, exiting five idle seconds after its last client and booting again
    in about 0.3 s — and about the seventy seconds this entry itself observed under load. The fix
    splits the budgets rather than raising one: `CLIVerbs.readBudget` is twenty seconds for
    `agents --json` and `auth status`, `CLIVerbs.mutationBudget` is ninety for the two `--bg`
    forms, `stop`, `respawn`, `rm` and `auth logout`, and `CLIVerbsTests`'
    `testReadsAndMutationsTakeTheirOwnBudgets` reads back the timeout each verb handed the runner.
    G5's own `CLIVerbs` dropped its 180-second override at the same time, so the gate now measures
    the production budgets.
    **Corrected** 2026-09-06, same day. The third merge-evidence run failed the same scenario the
    same way at ninety seconds, which falsifies the diagnosis above: the failure did not go away,
    it moved to the new ceiling. The daemon log settles it — job `78a58ac5` spawned at
    08:31:38.787 and `settled (killed)` at 08:31:39.873, so the spawn, the listing and the stop
    all completed in 1.1 s, every client had disconnected by 08:31:39.9, and the daemon logged
    nothing for the remaining eighty-nine seconds. The engine was never slow and this entry's
    seventy-second observation was never contention. `ProcessRunner` learned each child's exit
    from `waitUntilExit()` on `DispatchQueue.global()`, which does not overcommit; under a loaded
    suite driving pty children every worker was blocked, the block never ran, the exit was never
    observed, and the verb was failed by its own timer long after the child had exited
    successfully — `liveness=gone pipesOpen=0 waitReturned=false`. Fixed by taking the exit from
    `process.terminationHandler`, which needs no thread of ours and cannot be starved, with
    `testTheChildsExitIsSeenEvenWithEveryDispatchWorkerBlocked` holding the pool deliberately: 7.06 s
    and a false failure before, 0.005 s and exit 0 after. A separate latent defect found on the way
    — settlement waiting for end-of-file on the pipes, which a surviving grandchild holds open — is
    fixed too. With both in, the fourth merge-evidence run passed all eight scenarios and the
    exec-and-stop scenario ran end to end in 5.287 s against 94.781 s failing. The budget split
    stands and was worth making, but ninety was sized from an artefact; the mutation budget is now
    **thirty seconds**, roughly twenty times the real measurements.
28. **No net covers the sliver between a handoff's pre-launch recheck and its own transition.**
    `Lifecycle/ChannelSupervisor.swift:566-581`: rule 1 is suppressed for the whole handoff, and the
    designed nets are the release timeout into Contended and `beforeSpawn`'s recheck, both of which
    run before the launch. A foreign holder appearing between the recheck and the `apply` — for
    `sendToBackground` that stretch is the verb plus its roster confirmation, seconds rather than
    milliseconds — is not surfaced, and `backgroundJob` has no route out on a foreign holder. This
    widens an existing blind spot rather than opening a new one, and the alternative (a pid-precise
    exclusion) would reopen a `transitionNotInTable` route from Contended. Found at the Task 10
    re-review. Owner: C4. Closer: decide whether `backgroundJob` should have a foreign-holder route.
29. **`handingOff` is a Bool, not a depth counter.** `Lifecycle/ChannelSupervisor.swift:112`,
    `:534-535`. Two overlapping handoffs on one supervisor would have the first `defer` clear the
    flag while the second is still inside. Overlapping handoffs are already ill-defined — the second
    passes the owned-ready-or-dormant guard because the origin does not change until the end — so
    this is a facet of a pre-existing hazard rather than a new one. Owner: C4. Closer: a counter, or
    a guard that refuses a second concurrent handoff outright. **Closed** 2026-09-06 by the fix
    wave's ruling 2: `handingOff` is gone, and a second entrant to any lifecycle operation is
    refused with `LifecycleError.busy`.
30. **The handoff row test proves the guard, not the delivery.**
    `Tests/FleetSessionsTests/LifecycleRowTests.swift:1230-1236` pushes a `HolderSet` straight into
    `holdersChanged` rather than through the observer, so it does not show that the observer would
    produce such a set. The live run showed that, and the test's comment says so. Owner: C4.
    Closer: none planned; noted so the coverage is not overread.

The entries from here on come from the whole-branch review of 2026-09-06
(`.doperpowers/sde/2026-09-05-c4-fleetkit-sessions-fleet/final-review-triage.md`, buckets as the
architect's rulings settled them). Line numbers are as at `4f2102d`, before the fix wave.

31. **A store-write failure after `claude --bg` leaves the job invisible to logout twice over.**
    `scalpel-1#8`. The verb has already created the job when `rememberOwnJob` fails, so the short
    is neither in the store nor in the census, and `/logout` neither stops it nor is blocked by it.
    Reachable only when the store write itself fails. Owner: C4. Closer: compensate on the failure
    — stop the job just created, or adopt it into the record on the next reconcile.
32. **`resolveContended` filters every `isOwnChild` holder rather than this supervisor's process.**
    `scalpel-1#13`. Another afleet channel's child is excluded from the contention it should cause.
    The residual harm is a wrong displayed origin, not a wrong lifecycle decision. Owner: C4.
    Closer: compare the holder's pid with this supervisor's own child pid.
33. **The `.git` ownership check is the last path-after-resolution in the §6.12 writer.**
    `scalpel-3#3`. `Preconditions/LocalSettingsStore.swift` asks `lstat(resolved + "/.git")` by name
    after the root descriptor is open. The root descriptor's own ownership is already `fstat`-
    verified, so a decoy can only suppress or fabricate a refusal for a directory the user owns.
    Owner: C4. Closer: `case relative(Int32, String)` on `OwnershipSubject`, backed by
    `fstatat(fd, name, …, AT_SYMLINK_NOFOLLOW)`.
34. **The settings target descriptor is checked for type and mode but not `st_uid`.**
    `scalpel-3#4`, at `LocalSettingsStore.swift:177`. Same-uid only, and the directory holding it
    has been ownership-checked. Owner: C4. Closer: one guard after the `fstat`.
35. **The post-rename `fsync` result is discarded, contradicting the file's own step-6 comment.**
    `scalpel-3#5`. `Store/FileStateStore.swift:196` answers the same question the opposite way.
    Owner: C4. Closer: settle it once, in whichever direction, and make both files say the same.
36. **The writer's root-equality check compares an `F_GETPATH` string with a `realpath` string.**
    `scalpel-3#1`'s second half, at `LocalSettingsStore.swift:140`. A project root spelled through
    the data volume's firmlink therefore refuses `symlink` for ever. Fail-closed, so a wrong answer
    costs a refusal and never a write. The *containment* half of the same finding was fixed in the
    2026-09-06 wave by canonicalising both sides through `F_GETPATH`; this comparison is against
    the resolution string the writer deliberately took *before* the open, which is what makes the
    ancestor-swap refusal work, so it cannot take the same treatment without thought. Owner: C4.
    Closer: canonicalise the resolution the same way, or compare device and inode for this one
    check only.
37. **Fork re-key destination collisions in `Fleet.publish` and `FleetCapCounter.rekey`.**
    `scalpel-4#6` and `scalpel-4#7`. A fork whose real session id is already registered overwrites
    the entry rather than refusing. Owner: C4, revisit with C5's registration model. Closer: a
    diagnostic on the collision could land now; the resolution belongs with C5.
38. **`RuntimeStateUpdater` has no `update_settings` case, and `applied.output_style` is a dead
    branch.** `sweep#11` and `scalpel-5#12`. The engine does not emit `output_style` under
    `applied`, so an output-style change made by an answer is never recorded and the *next* restart
    re-reports the same stale mismatch. The same hole exists for `resolveSetting("effort", …)`,
    which lands in `flagSettings` and never in `state.effort`; that half lives in
    `Lifecycle/ChannelSupervisor.swift` and was left alone by the 2026-09-06 wave, which fixed only
    the `get_settings` reader beside it. Owner: C4. Closer: add the `update_settings` case and read
    the output style from the source that carries it.
39. **`apply_flag_settings` deletes a null-valued key; the updater stores it as JSON null.**
    `scalpel-5#13`. The engine merges and then deletes null-valued keys (2.1.258
    `cli.pretty.js:152496`), so a restart would re-send a key the engine has dropped and fail its
    readback for ever. Unreachable as shipped: `CommandRouter.flagValue` produces only strings and
    bools, and the only other producer would need a picker that does not exist. Owner: C4. Closer:
    drop a null value from `state.flagSettings` rather than storing it.
40. **The state store re-resolves its base by name on every write.** `scalpel-3#2`. Not a privilege
    boundary — the base lives under `~/Library/Application Support/afleet`, whose ancestors only the
    user can swap, and a same-uid process can rewrite the document directly — and scoped out by the
    child's ruling 7, whose only ask is that the constructor validate the base against the config
    homes. Owner: C4. Closer: hold a verified directory descriptor for the base, if the store ever
    holds something a same-uid process should not be able to redirect.

41. **A channel's task mirror never forgets a finished row inside one child's life.**
    Task 11's finding 2, now live: `FleetTimeline`'s `RegistryMirror` names its evictable rows
    through `evictable(asOf:grace:)` but exposes no remover, so `ChannelTaskMirror` cannot act on
    the answer. Nothing decides wrongly — the reading eligibility gets is C3's own `liveWork`, and
    the whole mirror is reset when the child exits — so the cost is a completed row per background
    task for the life of one process. Owner: C3 for the remover, C4 for the call. Closer: a
    `mutating func forget(_ ids: [String])` on `RegistryMirror`, called with `evictable(asOf:)`
    after each fold.
42. **The per-channel mirror does not fold the Bash tool's own result sentence.**
    `RegistryMirror.observe(bashToolResult:toolUseID:at:epoch:)` binds a background shell's id and
    output file from the tool result, which is the first frame that names either — before
    `task_started` arrives. `ChannelTaskMirror` folds the five task subtypes and `tool_progress`
    only, so for the moment between the tool result and the first task frame the channel looks
    idle to the reap. The window is one frame wide and both later frames arm the row, so nothing
    survives it; a surface that wants the output file from the same mirror will need it. Owner:
    C4, with C6's task pane. Closer: fold the assistant/user tool-result frames here as C3's own
    ingest does, rather than re-deriving the sentence.

43. **`Fleet.perform(.reap)` reads eligibility on the far side of the marker.** `sweep#1`. The
    facade checks the verdict (`Fleet.swift:324`) and then awaits `supervisor.reap()` (`:329`),
    which takes `inFlight` a hop later; a send admitted in between sets `turnRunning`, and the reap
    never asks again. The gate lives at the facade deliberately — the rig uses `reap()` as
    unconditional teardown — so the harm is bounded: the channel goes cleanly dormant, the
    transcript survives and a resume continues. Owner: C4. Closer: a `reapIfEligible()` on the
    supervisor that takes the marker, re-reads the verdict and terminates in one turn, leaving
    `reap()` the teardown it is.
44. **A restart request merged during a restart's own suspension is dropped.** `sweep#2`. A second
    request folds into `pendingChange` (`ChannelSupervisor.swift:1337-1340`) while `restartNow`
    runs, and the clear after the terminate discards it — after the composer has told the user the
    change applies when the current work finishes. The window is as wide as a terminate. It loses a
    settings request, not conversation state, and the user can ask again. Owner: C4. Closer: fold
    `pendingChange` into the request being applied at the moment of the clear instead of dropping
    it.
45. **A launch that throws before `run()` leaves the channel connecting with no process.**
    `scalpel-1#3`. `ClaudeProcess.spawn` evaluates `try launch.arguments()` outside the catch that
    publishes `.exited` (`ClaudeProcess.swift:82`), and the supervisor's handshake catch restores
    the resting state only for a `terminatedEpochs` member — so this one throw produces no exit and
    no restore: sends queue for ever, no *Reopen* is offered, and only relaunching afleet moves the
    channel. It violates ruling 1, but the trigger is narrow: `arguments()` throws only on a
    caller-chosen value beginning with `-`, and every field that carries one is engine- or
    picker-sourced except a typed `/model` argument. Owner: C4. Closer: restore the resting state
    on a throw that arrived with no exit behind it.
46. **`/logout`'s *Wait* and *Stop* both decide from the census-time blocker set.**
    `scalpel-4#2`. `LogoutPlan.execute` re-reads task ids only for channels already in
    `nonEligible` (`LogoutPlan.swift:153`, `:160`). *Stop* therefore terminates a channel that
    became blocked after the census without stopping its work — the §7.4 harm — and *Wait* is a
    dead end, because `Fleet.runLogout` keeps the same census after every waiting outcome, so a
    channel that has since become eligible is waited on for ever. The *Wait* half errs safe: the
    plan never signs out and the user can choose *Stop* or abandon. The *Stop* half needs the user
    to drive another channel into a background task while the sheet is open. Owner: C4. Closer:
    rebuild the blocker set from the live mirror at the moment each choice acts.

47. **`Fixtures/control-shapes/README.md` counts eleven requests where the table has twelve.** The
    opening line says "eleven host-originated control requests in sequence"; the table has twelve rows
    because `set_cwd` is sent twice — twelve requests across eleven subtypes. Raised by the reviewer who
    re-signed the fixture after the rule-5 migration (2026-09-06). Any edit re-signs the fixture, so
    batch it with the next fixture touch. Owner: C1.
48. **`redaction.json`'s per-rule `count` is a running total across redaction passes.** The rule-5
    migration stacked two rename hits on the original pass's two, so both migrated manifests read four
    where two values were replaced — visible in `zero-cost`, whose settings maps are empty. A reader who
    takes the number for "placeholders currently in the file" is misled; extends entry 10. Closer: a
    sentence in `Fixtures/REVIEW.md` and in the manifest's own key name if it is ever revised. Owner: C1.
49. **The drift ritual's resume scenarios depend on the recording-time scratch home.** `make probe`
    runs `session-mirror-resume` with the session id recorded in the `resume_of` fixture
    (`Tools/probe/probe.py:326-336`), so it can only succeed while the transcript that recording
    wrote still exists under the scratch config home. After the scratch home is recreated (a reboot
    clears `/tmp`) the scenario fails with the engine's "No conversation found with session ID"
    before any comparison runs (observed 2026-09-06 on 2.1.263). Not drift. Closer: run the
    `resume_of` scenario first inside the same `diff` invocation and thread its live session id
    through, so the ritual never resumes a recorded id; seeding the fixture's transcript into the
    scratch home is not an option, because `Tools/` never writes under a config home. Owner: C1.
50. **Two engine drifts on 2.1.263 against the 2.1.259 corpus, both benign for typed readers.**
    `make probe` over the corpus on 2026-09-06 (installed CLI 2.1.263; zero-cost census exact)
    reports for every turn-bearing fixture: (a) `removed pair rate_limit_event` — the recorded
    sessions each carried one allowed-status `rate_limit_event` after a turn, the live sessions
    carry none; the emitter and its single wrapper are unchanged between the bundles (2.1.258
    `cli.pretty.js:366607/620572`, 2.1.263 `:746910/424400`), so the condition moved upstream or
    the API no longer sends per-turn status for this account; and (b) `assistant: removed required
    payload keys diagnostics` — streamed assistant frames no longer carry `message.diagnostics`.
    ClaudeWire declares neither field (`RateLimitEventFields` is optional by construction;
    `AssistantFrame` has no `diagnostics`), `WireReducer` and `ActivityQuery` treat the event as
    occasional, and the fixtures still replay it, so nothing breaks. Consumers must not assume a
    rate-limit event per turn. The corpus stays pinned at 2.1.259; re-pinning is a deliberate C1
    re-recording, not a drift fix. Owner: C1 (re-pin decision), C6 (the §8 banner must not wait
    for a per-turn event).
51. **`RouteStrategy.applyFlagSetting`'s readback is declared and never executed.** The table row
    documents the strategy as "`apply_flag_settings {settings: {key: value}}` then `get_settings`"
    and gives it `ReadbackSource.getSettingsEffective`, but `CommandRouter.resolve` routes every
    flag command to a `.controlRequest` and `StrategyExecutor.run` answers `.applyFlagSetting` with
    `.notARequest`, so nothing anywhere sends the readback or reads `effective` after an applied
    flag. `RouterTests.testEffortSendsApplyFlagSettingsAndReadsBackEffective` performs the
    `get_settings` itself, which is why the gap is invisible. Deliberately left alone by the
    2026-09-06 facade corrective (`ace7a7b`), whose scope was reaching the router from `Fleet` and
    not changing what it does. Closer: C6 decides where the readback belongs — a second request
    inside a strategy the executor runs, or the surface re-reading settings after a flag change —
    and `ReadbackSource` either drives it or goes. Owner: C6.

## From C5 (`child/c5-app-shell`)

Appended by C5. Entries 49 and 50 are the 2026-09-06 drift ritual's and 51 is the router
corrective's; C5 numbers from 52 and renumbers nothing above.

52. **Demonstrating a guard failing performs the write the guard exists to refuse.** Parent
    §17.7 requires that a test written to prove a fix be shown failing against the pre-fix
    code; for a test whose subject is a refusal — `TempTree`'s config-home guard, the store's
    `configHomes:` check, the app-write seam of G1e — "pre-fix code" means the guard removed,
    and the removed-guard run then does the forbidden thing. Observed in C5's Task 1: the
    demonstration created a directory inside `/tmp/afleet-fixtures/config-home` twice. Both
    were removed at once and verified gone; no file inside was created, modified or deleted,
    and the home's thirteen top-level entries and every file under them were untouched (only
    the root directory's own mtime moved). The committed test was then changed to point at an
    invented config home under the temporary directory, so repeating the demonstration is
    safe. Closer: none needed for that test; the entry exists because the tension is general
    and every later C5 task with a refusal test meets it. The plan's Global Constraints now
    carry the rule, so this is a record rather than an open item.


53. **Two file handles on `diagnostics.log` and two on `fleet.log`, each tracking its own
    offset.** `Fleet.init` builds a `FileDiagnostics` and a `FileFleetDiagnostics` from the
    `diagnosticsDirectory` it is handed, and C5's `DiagnosticsComposer` — which the plan's
    Task 3 deliverable names explicitly — builds a second pair on the same directory. Each
    sink opens its file with `FileHandle(forWritingTo:)` and seeks to the end **once**, then
    keeps its own running offset, so it is not `O_APPEND`: if both pairs ever write, the
    second writer overwrites the first writer's bytes from wherever it last left off rather
    than appending after them. Today nothing writes through the composer's `wire` or `fleet`
    sinks — C5 originates no `DiagnosticEvent` and no `FleetDiagnosticEvent` — so the two
    extra handles are opened and never used and no line has been lost. The moment C6 or C7
    reports its own wire or fleet event through the composer, `diagnostics.log` starts
    corrupting. Only `timeline.log` is unambiguously the app's, because FleetKit ships no file
    sink for `TimelineNotice` at all. Closer: either `Fleet.init` takes the two sinks instead
    of a directory (one owner per file, which is also what would let the app install a
    capturing sink), or the composer stops constructing that pair and exposes `Fleet`'s. The
    first is a small FleetKit change and is the better shape. Owner: C6 (first writer), with
    the FleetKit signature change belonging to whoever touches `Fleet.init` next.
    Second consequence, found in Task 3's review: Settings' *Delete diagnostics* renews the
    composer's own three sinks after unlinking their files, but it cannot reach `Fleet`'s
    duplicate pair, so those two go on writing into unlinked inodes until the app is
    relaunched. **Neither closer listed above closes this half**, which the first draft of this
    sentence claimed: one owner per file still holds a handle to an unlinked inode, and so does
    a composer that exposes `Fleet`'s sinks. What closes both halves together is the C5 spec's
    revised recommendation — each sink opening the log `O_APPEND` **per write** and closing,
    holding no handle across writes, so a sink whose file was unlinked recreates it on the next
    write. That still leaves two sinks racing each other's rotation rename, which only a single
    rotation owner settles.
54. **`TranscriptIndex` and `Fleet` disagree about the config home's spelling.** The index
    records a symlink-resolved root in its snapshot; `Fleet` keys supervisors by the
    launch-resolved root. C5's `ChannelRegistrar.listed` threads the home through as an argument
    so registration joins them correctly today, but the disagreement is still there for the next
    consumer that joins those two by key — C6 and C7 both will. Found at C5 Task 4. Closer:
    settle one spelling at the seam, or have both sides canonicalise identically, rather than
    each caller remembering to bridge it.
55. **`FleetBrowserModel.rebuild()` re-derives every section on every `ChannelState`.** Harmless
    at C4's cap of six live processes, which is the only thing that pushes states today. It is
    the first thing a view bound straight to `sections` would feel, so C5 Task 5 and C6 should
    know. Found at C5 Task 4. Closer: patch the affected section rather than rebuilding, if a
    profile ever shows it.
    **Amended after Task 4's review, which found this entry recorded half its subject.** The
    re-derivation was not pure: grouping called `realpath` plus an upward `fileExists` walk per
    path component and then read a candidate's `.git`, memoised only *within* one call, so the
    whole set of probes was repeated from scratch on every rebuild — on the main actor, on every
    `ChannelState`, every delta, every failed action and every dismissed banner. That half is
    **closed**: `PathMemo` outlives the call, so each distinct directory is probed once per launch,
    and `ProjectGroupingTests.testThePathMemoIsNotReprobedOnASecondGrouping` holds it there
    against a counter of real probes rather than of cache entries. What remains open is the
    original entry as written — the O(rows) rebuild itself, which is arithmetic and allocation
    with no syscalls in it.
    **Measured at Task 5, and the "harmless" reading does not survive the number.** Task 5 is the
    first consumer to bind a view straight to `sections`, so it measured before assuming: 3,000
    rows across 40 sections, warm `PathMemo`, fifty consecutive `apply(_ state:)` calls, mean
    **47.9 ms** and worst **50.4 ms** per rebuild, all of it on the main actor. Split by phase over
    the same corpus: about 41 ms building rows (3,000 `URL(fileURLWithPath:)` among them, one per
    row per rebuild) and about 18 ms grouping. The cap of six live processes bounds how many
    *channels* push states, not how often each pushes one, and a channel mid-turn pushes many; at
    48 ms each that is three dropped frames per state. Note this is the model's own cost and is
    paid whether or not a view is bound. What binding adds is SwiftUI's own diff, and that is
    **not** free either: `List` renders rows lazily but `OutlineListCoordinator.diffRows` walks the
    whole row tree on every update, so the model's cost and the view's cost compound. Closer,
    unchanged in shape and now with a profile behind it: `apply(_ state:)` changes one row's live
    half, so patch that row in place and re-derive only when its archived-ness or its section
    membership changed.
    **Observed live at Task 5, and it is worse than the synthetic number suggested.** Running the
    built app against a real config home — 306 projects, 3,006 transcripts, four foreign live
    channels — pins one core at 100 percent indefinitely, not as a launch burst. A six-second
    sample of the main thread: 39 percent inside the `updates` loop, `apply(_ state:)`,
    `rebuild()`, `ProjectGrouping.sections` and its per-section sort; 60 percent inside
    `OutlineListCoordinator.diffRows` re-diffing the section array that rebuild just replaced. The
    driver is the rate, not the size: C4 re-runs `claude agents` every few hundred milliseconds to
    observe foreign holders and each observation publishes a `ChannelState`, while the transcript
    index contributed one update in twenty seconds over the same window. So the two halves compound
    at the holder-poll rate and the model's O(rows) rebuild is the load-bearing one.
    **Closed at Task 5**, `712ff54`. Idle CPU against the same config home is 0.1 percent, measured
    over five reads eight seconds apart on an uninstrumented build, against a sustained 100 percent
    before. Three changes, each demonstrated: a `ChannelState` patches the row it names through a
    row index instead of re-deriving, falling back to the full derivation only when the state
    crosses `isArchived`, which is the one thing about a row's position a state can change; a state
    for a session `listed` does not hold publishes nothing, because `rebuild()` derives from
    `listed` alone and could not have produced a row for it; and the `updates` loop ingests and
    defers, flushing on the first main-actor hop that brings no new arrival, bounded by 256
    deferrals rather than by any duration. Measured coalescing on the real corpus: 87 publishes and
    7 full rebuilds for 13,250 states.
    One correction to the diagnosis above, from instrumenting the stream rather than inferring it:
    the driver is **not** a steady holder poll. It is C4's registration seeding — 13,250 states over
    2,671 distinct sessions, about five per registered channel, 99.5 percent of them `.archived`,
    every one a first arrival — and it is a bounded burst that drains and stops. It looked endless
    only because the old path consumed it more slowly than it arrived. `AppTests/SidebarUpdateCostTests.swift`
    holds all of it, correctness clauses first. Owner: whoever
    next opens `FleetBrowserModel` — C6 is the likely one, since a live conversation is exactly
    the workload that emits states in a stream.
56. **`FleetFacadeTests.testOpenListsTheChannelAndPublishesEveryTransition` is load-sensitive
    and fails the whole-suite gate under load.** `FleetKit/Tests/FleetSessionsTests/FleetFacadeTests.swift:473`
    waits with `harness.waitFor("the merged stream to carry the transitions") { collected.count >= 2 }`
    — a polling helper on a wall-clock budget — over a merged `AsyncStream` whose delivery is
    scheduled. Found while C5 was hunting a different flake: on an idle machine the full suite is
    green, and under deliberate load (a concurrent full test run, a concurrent Release build,
    twenty spinners, load average 32 rising to 75) this one test failed on both loaded runs.
    Measured alongside it: an invocation that normally takes thirty seconds took over ten minutes
    under that load, so a five-second budget is comfortably inside reach.
    Why it matters beyond C4: `xcodebuild test -scheme afleet` runs FleetKit's suite, so this is
    a flaky assertion inside C5's G1b gate and inside every later child's. The parent already
    carries the shape as entry 2, from a C2 test whose starved-machine failure read as a product
    bug. Owner: C4's file. Closer: fulfil the wait from the delivery — the collector signals when
    it appends — rather than polling a deadline. C5 converted its own tests this way in `0f3ec6b`
    and the pattern transfers directly.

57. **The sidebar reads `SidebarGrouping` and never writes it, so pinning and collapse do not
    persist.** Spec §4 says grouping, pinning and collapse persist through `FleetKitKeys.grouping`
    and unread cursors through `FleetKitKeys.unreadCursors`. Task 5 wired the read half only:
    `FleetCoordinator.loadGrouping` loads the persisted `SidebarGrouping` and `ProjectGrouping`
    orders sections by it, and `SidebarView` draws the pin glyph on a pinned section — but the
    sidebar offers no pin, unpin or collapse action, so nothing ever writes a new value back.
    A user can therefore see a pin that a previous version of afleet set and cannot set one.
    Task 5's brief lists neither action among its deliverables, which is why this is a gap rather
    than a bug. Closer: a context menu on the section header calling through to a
    `FleetBrowserModel.setPinned(_:on:)` / `setCollapsed(_:on:)` pair that writes `SidebarGrouping`
    back through `StateStore` under `.fleetKit`. Owner: C6, or a C5 follow-up if the human gate
    wants it before C6.
58. **`LifecycleAPI.attach` hands back a `PaneRequest` that nothing in C5 renders.** The sidebar's
    *Attach* on a background job calls `FleetBrowserModel.attach(_:)`, which returns X5's
    `PaneRequest`; `ShellModel.pendingPane` holds the most recent one and no surface runs it,
    because running a pane is the Terminal panel's job and that is C7's. Nothing is lost — the
    request is a value and X5 does the ownership work either way — but the button currently
    reports success and shows nothing, which is a wrong affordance in the same sense §5 uses of a
    half-drawn card. Closer: either Task 8's pane seam consumes `pendingPane` and hands it to the
    registered runner, or the button is disabled with a sentence until C7.3 lands. Owner: C5
    Task 8 for the first option, which is the cheaper of the two and is already building the seam.

59. **`TrustReader.isTrusted` reads `<configHome>/.claude.json`, which on an ordinary installation
    is a file that has never existed.** Same defect as the one C5 Task 5 fixed on the app side and
    the same evidence: the engine resolves the global config document as
    `join(CLAUDE_CONFIG_DIR ?? homedir(), ".claude.json")` (2.1.263 `cli.pretty.js:298330`) while
    the config home is `CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")`, so the two coincide only
    when the variable is set. `FleetKit/Sources/FleetSessions/Preconditions/TrustReader.swift:68`
    appends to the root unconditionally, so with the variable unset every project reads as
    untrusted and `SpawnPrecondition.untrusted` refuses every spawn. Not observed as a failure yet
    because C5 spawns nothing; C6 is the first child that will. **Outside C5's fence** — the file
    is C4's, inside the FleetKit package — which is why this is an entry and not a commit.
    Closer: `isTrusted` takes the resolved document location, or a `ConfigHome` rather than a URL,
    the same shape the app now uses. Owner: C4, before C6 spawns.
