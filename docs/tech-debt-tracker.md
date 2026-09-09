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
**Historical correction, 2026-09-07 (F1 claim sweep):** entry 55 and its dated amendments
below preserve the investigation before the sidebar fix. The six-process cap does **not**
bound how many channels publish states; registered processless supervisors publish too.
The rebuild defect is closed by row patching and coalescing, as the later closer records.

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
    **Observed live at Task 5, and it is worse than the synthetic number suggested.**
    *(The attribution in this paragraph is superseded twice over — read the two paragraphs after it.
    Kept because the profile split it reports is still the measurement that motivated the fix.)*
    Running the built app against a real config home — 306 projects, 3,006 transcripts, four foreign live
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
    every one a first arrival. `AppTests/SidebarUpdateCostTests.swift` holds all of it, correctness
    clauses first.
    **And that correction was itself incomplete**, per Task 5's review, which traced the mechanism
    to `Fleet.fanOut` (`Fleet.swift:135-137` walks every supervisor for every published `HolderSet`,
    and `ChannelSupervisor.swift:1718-1720` assigns before testing for change). So the cost is one
    published state **per registered channel per holder-set change**, recurring for the life of the
    process, and registration seeding is its first and largest instance rather than the whole of it.
    The consumer-side fix is unaffected and its value goes up: the coalescing absorbs a recurring
    cost, not a draining one. The producer half is tracker 60, against C4. Two consequences of the
    correction are worth keeping visible: "it is a bounded burst that drains and stops" was true of
    seeding and is false in general, and `identical=0` was true of seeding — where every state is a
    first arrival — so coalescing repeats is not the dead end it looked outside the burst.
    Nothing is left open on this entry; the ownership line it used to carry ("whoever next opens
    `FleetBrowserModel`") is retired with it.
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

59. **Closed 2026-09-07 (`1c19d52`).** `TrustReader.isTrusted` read `<configHome>/.claude.json`, a file
    that does not exist on an ordinary installation, so every project resolved untrusted and no
    channel could spawn owned. The engine resolves the document as
    `join(CLAUDE_CONFIG_DIR ?? homedir(), ".claude.json")` (2.1.263 `cli.pretty.js:298330`) while the
    config home is `CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")`; the two coincide only with the
    variable set, which every scratch-home test does. `ConfigHome.globalConfig` (AfleetCore) now
    carries the rule, `isTrusted(root:globalConfig:)` reads through it, and a default-shaped test
    (document beside the home) was shown failing first. The wider consequence — `childEnvironment`
    injecting the variable for a default home moved the keychain credential item and the document
    for every child — is `6b3fc23` and parent §6.1/§6.9/X11. Found by C5 Task 5.
60. **Seeding publishes each intermediate state per channel, and a contended channel republishes on
    every fan-out.** What remains of the amplification C5 measured at Task 5 (13,250 states across
    2,671 sessions on one launch over a real config home, `identical=0`, 99.8% `.archived`). The
    recurring half is closed 2026-09-07 by `f9da990`: `ChannelSupervisor.holdersChanged` now publishes
    on a fanned-out holder set only when its own narrowed holder view changed or a transition was
    taken (two-channel test in `HolderFanOutTests.swift`, failing first at 2 publishes where 1 was
    expected). Still open, two shapes: seeding emits every step toward a channel's settled state
    rather than the settled state once, or should say why the intermediates are load-bearing; and
    `resolveContended`'s `publish()` on the two-or-more-foreign-holders path is the same
    unconditional shape, bounded by how few channels are ever contended. C5's sidebar coalesces
    (13,250 states cost 87 publishes and 7 rebuilds); C6 subscribes to the same stream without that
    machinery. Owner: C4, the seeding half before C6's conversation surface subscribes.
61. **`afleet.config-change` is answered but not acted on: the `get_settings` refresh §6.4 asks for
    is owed.** The parent's protocol table says the callback "refreshes `get_settings` and answers
    likewise". C5 Task 6 ships the answer — an empty continue, so the engine is never left blocked
    on a registered hook callback that nothing routes — and deliberately not the refresh.
    Why deferred rather than done: `get_settings` is a per-channel control request whose reader is
    the channel's settings and permissions view, which is C6's. This child renders no engine
    settings at all (`SettingsReadout` is the app's own config-home and diagnostics readout, not the
    engine's), so a refresh here would fetch a value nothing draws and would have to invent a place
    to keep it. The hang was the defect and the answer closes it; the behaviour is what remains.
    Closer: when C6 owns a live per-channel settings view, make the `afleet.config-change` route
    re-read `get_settings` for that channel and publish it, and keep the empty continue after it.
    Owner: C6. Found by Task 6's review as finding C1; the answer landed in the same task.
62. **§6's third notification source has no stored preference.** The spec names three toggleable
    sources — a decision in a channel not in view, a completed turn in a channel not in view, and
    every notification the engine raises through the `Notification` hook — and the persisted
    `NotificationPreferences` carries `permissionRequests`, `turnCompleted` and `channelFailed`.
    None of the three is the hook, so C5 gates decisions, completed turns and failed turns and
    leaves the engine's own hook notification always on, which is the least surprising default: the
    engine raised it deliberately. Not a defect, a gap between the document and the stored shape.
    Closer: add a fourth field with a default, a Settings row beside the other three, and decide
    whether `channelFailed` keeps its current meaning (a `result` frame with `is_error`) or is
    renamed to say so. Owner: C6 or whoever next opens the Settings screen.
63. **`ActivityModel.start()` reads every registered channel's state once per launch.** It seeds
    itself from `LifecycleAPI.states()`, which on `Fleet` awaits each supervisor in turn — one
    actor hop per registered channel, and the sidebar registers every listed transcript, so on a
    real config home that is thousands of hops. It happens once, off the first paint, and the model
    then keeps only the states that could produce a row, so nothing after the seed is fleet-wide.
    Filed because it is a fleet-wide read where a per-channel feed would do, and because it grows
    with the corpus. Not measured at three thousand channels. Closer: either a `states(of:)` taking
    the keys the caller cares about, or seeding Activity from the same `updates` feed the sidebar
    already consumes and dropping the initial pull. Owner: C4 for the first, C5's successor for the
    second.
64. **Nothing handles a notification being clicked.** C5 posts three kinds of notification and
    carries the channel's session id on each (`AfleetNotification.session`), but no
    `UNUserNotificationCenterDelegate` is set, so a click opens the app and lands wherever the
    window already was. The channel the notification is about is one hop away and the user has to
    find it themselves, which is most of the value of having been told.
    **It is unreachable until authorisation can be granted, and that ordering is the useful part
    of this entry.** Spike S-C5-1 did not promote: on an ad-hoc-signed, non-notarised build the
    system prompt is presented but nothing unattended can answer it, and the status is `denied`
    afterwards, so no system notification is drawn and there is nothing to click. Until somebody
    with a screen grants authorisation, or the app is signed and notarised, a click handler could
    be written but not exercised — which is why C5 left it rather than shipping a path no test and
    no human could reach. The in-app fallback banner has the same gap and is reachable today: a
    banner in the Activity list is not clickable either, and that half could be done now.
    Closer, in the order they become reachable: give `BannerStack`'s rows a tap that calls
    `ShellModel.select(_:)` with the notification's session; then, once a system notification can
    be delivered, set a delegate whose `didReceive` response routes the same way, keyed by the
    session already carried on the notification. Owner: whoever holds the shell after C5 — C6 in
    practice, since it owns the surface a routed click lands on. Deferred by C5 Task 6 and filed at
    the reviewer's instruction, because a deferral nobody recorded is indistinguishable from an
    omission.
65. **A `ChannelTimelineModel` created by `attach` and never sent `open` stays blank forever.**
    Reachable only if a caller attaches a model and then never opens the channel it belongs to,
    which no C5 path does — the column opens on appearance. Recorded because C6 replaces that
    view and may attach earlier or on a different trigger. Found at C5 Task 7. Closer: either
    make `attach` imply the first `open`, or assert in the model that a `nil` projection with
    `hasOpened` false is unreachable so a future caller trips it.
66. **Closed 2026-09-08 by C6.1 (`child/c6-timeline-renderer`).** `hasOpened` now moves to after
    the index lookup succeeds, and a retry that finds the entry clears the failure the attempt
    before it recorded; `testAMissingIndexEntryIsRetried` holds both halves and was demonstrated
    failing against the pre-fix shape. The entry's original text follows.

    **`hasOpened` is set before the index lookup, so a missing entry pins `failure` for the
    model's life.** A channel whose index entry is absent at open time — a transcript deleted
    between listing and opening — records the failure and never retries, because the guard that
    prevents re-opening has already fired. No C5 path produces it: the sidebar lists from the
    same snapshot the model reads. Found at C5 Task 7. Closer: set `hasOpened` after the lookup
    succeeds, so a transient absence is retried on the next appearance.

67. **The panel column resolves its `ChannelContext` inside `body`, which mutates the host.**
    `PanelHostModel.context(for:cwd:)` records the channel's working directory and caches the
    context it built, and `view(for:context:)` touches the eviction order and can create a session
    — all from inside a SwiftUI view evaluation. It is sound today and deliberately so: every field
    those paths write is `@ObservationIgnored`, so none of them invalidates a view and none can
    produce "modifying state during view update". The debt is that the safety rests on that
    property of five stored properties rather than on the shape of the call, and the first of them
    to become observed — a host that wanted the tab bar to redraw when a context is rebuilt, say —
    reintroduces the hazard silently. Found at C5 Task 8. Closer: resolve the context in an
    `onChange` or a `task(id:)` and hold it in view state, the same move C5 Task 7's fix made for
    the channel header; or keep the caches behind a type whose API cannot be called from `body`.
    Owner: whoever next adds observed state to the host — C6 or C7 in practice.
68. **`PanelHost.run(_:)` picks a pane runner by tab rather than by the request's purpose.**
    `registerPaneRunner(_:for:)` is keyed by `PanelTabID`, and `run` prefers the runner registered
    for `.terminal`, falling back to the first registered in canonical order and throwing
    `noPaneRunner(.terminal)` when there is none. Only C7's Terminal leaf registers a runner, so the
    fallback arm is unexercised and the choice is unambiguous today. `PaneRequest` already carries a
    `PanePurpose`, which is what a second runner would want to be routed by — a logs pane in a
    different leaf, say. Found at C5 Task 8. Closer: when a second runner appears, route on
    `request.purpose` and let a runner declare the purposes it accepts; the protocol member's `for
    tab:` parameter stays, because a runner still belongs to a tab. Owner: C7, at its second runner.
69. **Closed 2026-09-07 (`c4997a9`).** C4's live-test trusted-directory selector canonicalised both
    sides of its config-home exclusion with `URL.resolvingSymlinksInPath()`, which rewrites
    `/private/tmp/…` to `/tmp/…` only when the result exists, so a trust entry naming a not-yet-created
    directory beneath the scratch config home survived the exclusion — the live suite would then have
    created a directory inside a config home. The selector is now `LiveGate.trustedDirectories(…)`,
    canonicalised by `realpath` over the longest existing prefix with the missing components put back
    (a local copy of C5's `CanonicalPath`; FleetKit's tests cannot import the App target), with a
    CLI-free test shown failing first (two candidates where one was expected). Found by C5 Task 9
    through its port's own test; unexploited in C4 because no fixture entry named such a path.
70. **Every fixture and live gate ran under a `CLAUDE_CONFIG_DIR` scratch home, which is not the
    shape of an ordinary installation.** With the variable set the engine reads
    `$CLAUDE_CONFIG_DIR/.claude.json`, names its keychain credential item with a path-hash suffix
    (2.1.263 `cli.pretty.js:338499`) and ignores an installed launchd daemon (`:363645`, `:363679`);
    with it unset — every default installation — it reads `~/.claude.json`, the unsuffixed keychain
    item, and an installed daemon if there is one. Two `main` defects hid behind this for four
    children (the always-injected home and `TrustReader`'s document path, corrected 2026-09-07), and
    the daemon observations in C4's spec were all taken with the installed-daemon path closed
    (correctives `6b3fc23`, `1c19d52`).
    Closer: the next fixture re-pin (entry 50) also records under a default-shaped scratch `HOME`
    (a temporary `HOME` with `.claude/` inside and `.claude.json` beside it, `CLAUDE_CONFIG_DIR`
    unset), and at least one live gate per spawning child runs in that shape. The cost is that such
    a child authenticates through the unsuffixed keychain item, the author's own; the gate must
    stay zero-turn. Owner: C1's maintainer at the re-pin; C6 for the first spawning gate.

71. **The app never calls `AppFleet.shutdown()`.** `Workspace.swift` declares it on the protocol
    and every call site is a test's teardown; no path in `App/` invokes it, so quitting afleet
    leaves its streams unfinished, its timers uncancelled and its diagnostics unflushed.
    **Corrected 2026-09-07 by the architect's ruling: `shutdown()` terminates nothing** — its own
    doc comment says so. What ends an owned child on quit is the **pipe**: an owned channel is the
    engine on afleet's stdio, and the engine treats stream close as wind-down, killing every
    still-running local shell and abandoning its other background tasks (parent §7 near line 981,
    and the Decision Log entry near 2805). So an owned conversation cannot outlive afleet, "keep
    it running" is not something a quit dialog could offer, and the only way to keep one is to
    release it first with *Open in terminal*. Found at C5 Task 8's review follow-up, by sweeping `App/` for members whose only
    callers are in `AppTests/` (the same sweep that found `ChannelTimelineRegistry.release(_:)`
    uncalled, which was fixed rather than filed because it had an owner and a seam already). This
    one is filed rather than fixed because it is a decision, not an omission: X5's invariant is that
    afleet never stops a session running in the user's terminal, so what an app-termination hook may
    end is exactly the set `Fleet` owns, and whether quitting the window should end an owned
    conversation at all — rather than releasing it the way *Open in terminal* does — is the
    architect's call. **That call is made**, and goes into parent §7.4 as a binding *Quit* clause
    at C5's merge: on `applicationShouldTerminate`, if any owned channel has a turn running or
    running local shells, afleet asks **once**, naming those channels, before ending them — the
    same warning rule X9 already imposes per channel for `end_session`; on confirmation, or when
    nothing is busy, it runs `terminate()` on each owned channel that has a process, then
    `Fleet.shutdown()`, then exits. Foreign and background-job channels are never touched.
    Closer: implement that clause. Owner: C6, which owns the surface where a running conversation
    is visible when the user quits.
    **DONE at C6.2 Task 9**: `App/Header/QuitGuard.swift` and one `applicationShouldTerminate` hook
    in `App/AfleetApp.swift`, asserted in `AppTests/Header/QuitGuardTests.swift`. `AppFleet.shutdown()`
    now has a production caller. Two things the implementation found, both for the architect rather
    than for a later worker to rediscover. **First, §7.4 asks for a capability X5 does not publish.**
    `terminate()` on a channel is `perform(.reap)`, and `Fleet` gates that reap on dormant
    eligibility — deliberately, because the reap the *user* asks for must not end a channel with a
    turn in flight — so the channels the quit dialog just asked about are exactly the ones the reap
    refuses. `ChannelSupervisor.reap()` is the unconditional terminate and is not reachable through
    the facade. The clause is implemented by escalating a refused reap through `.stopEverything` and
    reaping again, which ends what the user was told quitting ends, using only X5 verbs; the clean
    fix is an unconditional terminate on `LifecycleAPI` for this one caller, which is C4's to add.
    **Second, "a turn running or running local shells" is read from two places**, because no single
    published value carries both: `ChannelState.presence == .busy` is the turn (the sidebar's and the
    composer's own notion), and the running background tasks come from
    `ChannelHeaderActionsModel.liveTaskIDs`, over the timeline the *Send to background* confirm
    already reads. A channel the user never opened has no timeline, so at quit it is judged by its
    presence alone — the guard constructs no composer and no ingestion at the moment the app is being
    asked to stop. `ChannelState` carrying a live-task count would close that gap and is C4's too.
    **Ruled 2026-09-08, and the escalation withdrawn.** The architect read §7.4's *Quit* as the
    literal bare `terminate()` and accepted the missing verb as a parent gap: the clause was added at
    C5's merge a day after C4 merged, so X5 never received it. The escalation's argument was wrong on
    the point that mattered — the engine's `end_session` already records `task_updated
    {status: "killed"}` and `task_notification {status: "stopped"}` for its shells and writes the
    trailing `last-prompt` during shutdown, so the bare form is a *recorded* teardown rather than a
    pipe yank, while the escalation's failure path (a reap still refused after `.stopEverything`)
    exits with no SIGTERM/SIGKILL and no wedge record, regressing §6.7. The replacement lands on
    `main` as `LifecycleAction.quit` (per channel, unconditional, `maySpawn: false`, no eligibility
    gate, no `inFlight` guard, with `LifecycleTable.TerminatingAction.quit` so a ghost a quit leaves
    is recorded as one) plus `LifecycleAPI.liveTaskIDs(of:)`, which also closes the presence-only
    narrowing above: busy becomes `presence == .busy || !liveTaskIDs(of:).isEmpty`, the fleet's fact
    rather than a surface's local count. **Still open at C6.2 Task 10:** neither member exists in this
    leaf's tree, so `QuitGuard` still ships the withdrawn escalation and `QuitGuardTests` still
    asserts it. Closer: the adoption task swaps both and re-points the two assertions. Owner: C6.2's
    adoption task.
72. **A member declared in `App/` whose only callers are in `AppTests/` is not detectable by any
    check this repo runs.** Two real defects in one review cycle had that exact shape:
    `PanelHost.selectIndex(_:in:)`, correct and tested with no production caller while the menu
    called something that indexed a different list, and `ChannelTimelineRegistry.release(_:)`,
    correct and tested and never called, so every channel ever opened kept its ingestion. Both were
    found by hand. The sweep is mechanical — declarations in `App/`, call sites counted in `App/`
    versus `AppTests/` — and would have found both, plus entry 69, in one run.
    **DONE at C5 Task 10 (`138c58a`), and the closer below is what was built** —
    `Tools/c5/check-app-wiring.py`, run from `make test-tools`, with its own gate in
    `Tools/c5/tests/`. Two corrections to the closer as it was written. The allowlist needed
    **eighteen** entries rather than six: the four probes named below plus `whenSettled`, and
    twelve current findings, each carrying the tracker number that owns it (71, 73, 74) rather
    than an exemption. And the check keys on a bare name, so it cannot see a member whose name is
    also used elsewhere under `App/` — `PanelHostModel.run(_:)` has no production caller and the
    check will never say so, because `LaunchSequence.run()` shares the name. Per-clause wiring is
    still read by hand at a merge; this closes the mechanical half only.
    Closer: add it to
    `Tools/c5/` beside `check-x7-drift.py` with an explicit allowlist for the members that are
    legitimately unexercised (`registerPaneRunner`, whose caller is C7's Terminal leaf, and the
    test-only probes `pump`, `settle`, `whenChanged`, `cursorsPersisted`), and run it from `make
    test`. Owner: C5 Task 10 if the merge wants it, otherwise the first child that adds a `Tools`
    check of its own. **The general form is worth more than the check**: a gate clause is only as
    true as the path the app takes to it, and nothing in the suite says which path that is.
73. **Six counts and three accessors are declared in `App/` for a diagnostics line, a report or a
    screen that never reads them.** Found at C5 Task 10 by the sweep tracker 72 asked for, now
    `Tools/c5/check-app-wiring.py`. `PanelHostModel.liveSessionCount` and `liveChannelCount`,
    `HostLinkRouter.targetCount`, `ChannelTimelineRegistry.openChannels` and
    `FleetCoordinator.skippedWithoutCWDCount` each say in their own doc comment that they exist
    "for a diagnostics line" or "for a report"; no such line is written, so the numbers the app
    would state about itself are computable and never stated. `FleetBrowserModel.restore(from:)`
    is superseded by `paint(_:listing:origin:)`, which is what `FleetCoordinator` actually calls,
    and `AppRoute.setupState` / `upgradeVersions` are unread because `RootView` switches on the
    enum directly — all three remain the suite's assertion surface, which is why they are here
    and not deleted. Nothing is wrong with the app: every one of these is a read-only accessor and
    no behaviour depends on it. Closer, two halves: write the diagnostics line the five counts were
    declared for, through `DiagnosticsComposer.app`, at the points the composer already records
    (launch complete, channel released); and delete `restore(from:)` in favour of the call the
    coordinator makes, moving the two tests that use it onto `paint`. Owner: C6, which is the first
    child with a reason to read those numbers back. Until then each is allowlisted in the check
    with this entry's number as its reason.
74. **Closed 2026-09-08 by C6.2 Task 8.** The channel header's action menu is the first consumer of
    both properties: every owned action is gated on `offersOwnedActions`, and a read-only row draws
    `readOnlyReason` **in place of** the menu rather than a disabled list.
    `HeaderActionTests.testAReadOnlyRowOffersNoOwnedActionAtAll` asserts it, and the mutation that
    opens the gate unconditionally fails twenty assertions across the read-only and no-row tests.
    The row is threaded into the mount from the column rather than read back out of the
    environment, so the gate is exercised through the production path and not only on the model.
    Original entry follows.

    **`ChannelRow.offersOwnedActions` and `readOnlyReason` have no consumer, because C5's sidebar
    offers no channel action at all.** `ListingPolicy` decides the mode, `ChannelRegistrar` carries
    it onto the row, `SidebarModelTests` asserts a teammate transcript is listed read-only — and
    `ChannelRowView` draws a glyph, a title, a subtitle and a badge, with no context menu and no
    button. So G1c's read-only clause is true of the model and unobservable in the app, which is
    correct for this child rather than wrong: with no affordance to gate there is nothing that
    could spawn against someone else's session, and X5 refuses it a second time regardless. Filed
    because the first child to add a channel action inherits a row that already knows the answer
    and a codebase where nothing has ever asked it — the shape that produced tracker 72's two
    defects. Closer: the context menu C6 adds reads `offersOwnedActions` for what it offers and
    `readOnlyReason` for the sentence it shows instead, and a test asserts a read-only row offers
    no owned action. Owner: C6, which owns the surface where a channel action first appears.
75. **Closed 2026-09-07 (`f36c496`, `9dda131`, `440f525`).** The class is swept out of all three
    targets and each now carries an `AssertionLeakGuardTests` that scans its own sources for the two
    mechanical shapes, with an empty allowlist. The counts the sweep actually found, against the
    candidate counts below: `FleetSessionsTests` 47 sites (11 path, 26 aggregate, 10 invented-value
    but same-shape), `FleetTimelineTests` 15, `ClaudeWireTests` 5 — all messages, because every
    equality candidate there turned out to be over an invented constant. The aggregate shape
    dominated: `ChannelKey` carries the rig's config home, so every equality over a key, a census, a
    logout outcome or a pane request's environment printed a temporary path without naming one.
    Filed follow-up: nothing stops the *next* aggregate leak, because the guard is line-based and
    cannot see through a struct; a `CustomStringConvertible` on `ChannelKey` that prints the session
    id and a digest of the config home would close the shape rather than the instances, and is a
    product-side decision C4 owns. Original statement:

    **The assertion-leak class is unfixed in three package test targets, and it is the one class
    the app's own suite was swept for.** C5 Task 10 swept every test target in the tree for
    assertions whose failure message would print a path derived from `FileManager.temporaryDirectory`
    — which carries the account hash of the machine that ran the suite. `AppTests` had ten and they
    are fixed. Outside C5's fence the sweep counted **fifteen** in `FleetSessionsTests`, **twelve**
    in `FleetTimelineTests` and **seven** in `ClaudeWireTests`, of which the confirmed ones are
    `PreconditionTests` (nine sites plus two failure messages that interpolate a resolved temporary
    path outright), `FleetFacadeTests` (one), `TranscriptIndexTests` (the entry-path comparisons)
    and `LiveCLITests` (one). Every one is an `XCTAssertEqual` or `XCTAssertNotEqual` over two
    temporary-directory-rooted paths, so a failure prints both. Not fixed here because these files
    belong to C2, C3 and C4 and a merge-time diff across three other children's suites is the wrong
    place to land it. Closer: spell each as a boolean with a message that names counts, the way
    `AppTests` now does; the sweep is mechanical and reproducible from the class statement above.
    Owner: C4 for `FleetSessionsTests`, C3 for `FleetTimelineTests`, C2 for `ClaudeWireTests`.
76. **`LaunchFixtures.wait(upTo:for:)` and `waitAsync(upTo:for:)` are declared and called by
    nothing.** Two polling waiters in `AppTests/Support/LaunchDoubles.swift`, each returning a
    `Bool` nobody reads because there is no caller. Found by C5 Task 10's sweep for awaits whose
    result is discarded; they are the inverse case, a result nobody can discard because nobody asks
    for one. Harmless, and worth removing rather than leaving as a pattern the next executor copies:
    every wait in this suite is fulfilled by the event it waits for and none of them polls, which is
    the rule these two would quietly break. Closer: delete both. Owner: the next task that opens
    `LaunchDoubles.swift`.

77. **Closed 2026-09-08 (`248ac93`, `6c3ead2`).** Background roster changes outside afleet had no
    complete app-consumable signal (C5 review F6): `SidebarView` loaded the roster once and only
    afleet's own Adopt and Stop refreshed it, while `LifecycleAPI.updates` carries channel states,
    which cannot represent an exec job (no session, so no channel) or a job's own state text. X5
    now has `jobUpdates`. `FleetObserver` publishes its read whenever `HolderSnapshot.jobs` differs
    by value from the last published one — `f9da990`'s rule over the roster, and separately from
    the holders — and `Fleet` forwards each as the full current `[JobEntry]`, derived by
    `HolderSnapshot.roster`, which `jobs()` reads too. The publication rides the watch and the
    five-second poll the observer already ran, so no `agents --json` is added; the Background list
    subscribes before it takes its initial snapshot and patches by row, and Adopt and Stop no
    longer refresh. `RosterSignalTests` and `BackgroundRosterTests` pin both halves.
    Remaining: the sidebar still takes one `jobs()` snapshot at launch, so the roster's first paint
    costs the CLI boot `reconcileNow` has always cost — the stream cannot replace it, because a
    launch has to start from somewhere and the first publication is not owed until something moves.

**R3 correction, 2026-09-07:** entry 78's two-guard statement excludes the filesystem-root
case: C5 now handles it by path components; the C4 guard still misses it (entry 80). The
symlink-containment debt in entry 78 is unchanged.

78. **The X9 app-side claim rests on root containment, which a symlink planted inside a write
    root would escape.** `AppFileWrites` observes every path app code chooses, and
    `testEveryFilesystemWriteInTheAppIsBehindTheSeam` keeps that observation complete. It does
    not observe the bytes `FileStateStore` and the package diagnostics sinks write beneath a
    root the app handed them; for those the app declares the root, and the claim that nothing
    lands under a config home follows from `LaunchSequence.overlappingWriteRoot` and
    `FileStateStore`'s `configHomes:` both refusing a root that canonicalises to or under the
    resolved config home. Containment therefore assumes a package writes only beneath the root
    it was given. A symlink inside a write root pointing into a config home defeats both guards,
    because both canonicalise the root and neither walks its descendants. Not reachable through
    anything C5 ships — every write root is a directory afleet creates — and left unfixed rather
    than papered over with a second guard in the seam, which would be a third answer to a
    question two places already answer. Closer: whichever child first accepts a user-chosen
    store or diagnostics root resolves each write path, not only the root, or opens its files
    with `O_NOFOLLOW`. Owner: C6 if it ships the Settings control for either root; otherwise the
    child that does.

79. **Closed 2026-09-07 by ruling: the reviewer signature is admitted.** Eighteen fixture
    `review.reviewer` values and one probe test input carry the author's handle. None is an engine
    byte, a path or an account identifier; the field is the human attestation §11's review gate
    exists to record, and it is the identity git's author field already carries on every commit.
    §11 now says so in one sentence (parent, C5 merge). The C5 leak-risk sweep that found them was
    otherwise clean: four of six identity patterns matched nothing anywhere, and every identifier
    C5's own test inputs use is invented.
80. **`FileStateStore` permits descendants when a config home is the filesystem root (C5 review R3).**
    `FleetKit/Sources/FleetSessions/Store/FileStateStore.swift:31` compares canonical strings
    using equality or `hasPrefix(homePath + "/")`. For a config home of `/`, the prefix is
    `//`, so an ordinary descendant passes the never-write guard. C5 corrected its own
    `LaunchSequence.overlappingWriteRoot` before any store or diagnostics construction, but
    the package constructor remains unsafe for other callers. This is outside C5's fence,
    like entry 75, and was not edited in the app-shell fix wave. Closer: retain canonicalization
    and compare path-component prefixes instead of string prefixes; demonstrate the refusal
    with a non-writing seam so a removed guard cannot create anything beneath a config home.
    Owner: C4 (`FileStateStore`, X6/X9).

81. **SwiftUI body/action inspection is tied to framework storage (C5 review T2).**
    `AppTests/Support/ViewTree.swift` exercises the shipped Settings body and its actual
    button closure without a separate presentation model. The local hosted accessibility
    instrument exposed no SwiftUI children, so it could not prove control reachability.
    Reflection is test-only and prints no values. Its action adapter checks isolation,
    signature and size before bridging SwiftUI's Swift-5 closure metadata to Swift 6;
    the missing-control and press assertions fail closed if the framework shape changes.
    This is not a pixel/layout or accessibility witness. Replace it with a reliable hosted
    accessibility instrument or native UI-test target when the app has one. Owner: C5 tests.

## From C6.2 (`child/c6-composer`)

142. **`cancel_async_message` has no typed spec in ClaudeWire, though the engine declares one.**
     The queue chip's cancel goes out as `AnyControlRequest(subtype: "cancel_async_message",
     payload: ["message_uuid": …])` through `RawControlRequest`, which carries the same bytes as a
     typed spec would. The engine declares the pair in its own request table (2.1.263
     `cli.pretty.js:94602`; handler `:452054-452063`, schema `:94598`), so the shape is known and
     stable: `{message_uuid: String}` in, `{cancelled: Bool}` out, where `false` means the message
     was never in the queue. Filed rather than fixed because `ClaudeWire` is C2's file and this
     leaf's fence stops at `App/`. Closer: add `CancelAsyncMessage` to
     `ClaudeWire/Sources/WireFrames/OutboundRequests.swift` at the next typings pass and let the
     composer construct it. Owner: C2.

143. **`RewindOutcome` models neither `precedingAssistantUuid` nor `targetMessageUuid`.** The
     engine's `rewind_conversation` body carries both (`control-shapes`, `rewind-turn`), and
     `precedingAssistantUuid` is the fork point *Fork from here* needs. C6.2's *Edit* path is
     unaffected because it reads the raw `JSONValue` off `LifecycleAPI.send(_:on:)` rather than
     going through `StrategyExecutor`, but `/rewind`'s strategy does go through it, so a *Fork from
     here* ever offered from `/rewind` would have no fork point to offer. Closer: add the two
     fields to `RewindOutcome` and populate them where the executor already reads the body. Owner:
     C4 (`FleetKit/Sources/FleetSessions/Router/CommandRouter.swift`).

144. **Closed 2026-09-08 on `main` at `6abd4a0`.** The engine has two refusal sentences, not one:
     the bare form (2.1.263 `cli.pretty.js:540254`) and an interactive-panel form (`:540305`) that
     ends by telling the user to run the command from the Claude Code terminal.
     `RouterTable.bareRefusalPattern` is anchored at both ends and matched only the first, so the
     second reached the channel unintercepted and uncounted — carrying, in the engine's own words,
     the one sentence §7.7 forbids afleet from showing, while the drift log read zero for the whole
     class. Filed by C6.2 as a `[parent-impact]` against X10 and fixed by the C4 corrective
     (`8dd10fe`, `2cfc67a`): a second pattern, a `RefusalShape` on `Intercepted`, per-shape counts
     through `driftCount(of:)`, `refusal_shape` on the drift-log entry, and copy that no longer
     sends anyone to the terminal on either path.

145. **Closed 2026-09-08 by probe `spike_rewind_last_seen` (`77a0d62`), spec corrected at
     `81a3dca`.** §8.5 read `rewind_conversation`'s `"stale target"` as a fact about which process
     sent the message, so item 13 was written around a fallback. It is not: the engine runs a
     later-turn scan whose reach is set by the optional `last_seen_user_message_uuid`
     (`:452145-452153`). Measured on 2.1.263, zero turns, three forks of a scratch session — with
     the field naming the newest user message an older target is **honoured**; with the field
     omitted the same target is `"stale target"`; with the field naming the target itself it is
     `"unseen later turn"`. So the composer always sends the field, the rewind is the ordinary path
     and the fork is the exception. The wrong-but-obvious value — the target's own uuid — refuses
     every older edit and hides behind the fallback, which is why C6.2's G4 asserts the payload
     names the newest message and not the target.

146. **`LifecycleRowTests.testPaneExitReAdoptsWhenTheRecordIsGone` fails when the machine's pid
     counter wraps.** **Closed 2026-09-08 by the `main` corrective `85006b4`** (a two-helper decoy;
     no ordering assumption on pids). The test arranges a decoy job holder at `ScriptedHolderFiles.livePID` — the
     test runner's own pid, which never dies — and asserts it sorts ahead of the helper process the
     test then spawns (`XCTAssertLessThan(livePID, tab)`, "the decoy holder sorts first"). That
     holds only while pids increase monotonically. macOS wraps them near 100000, so a run whose
     runner starts at a high pid and whose helper is spawned after the wrap gets a *lower* helper
     pid and the arrangement inverts. Observed here at C6.2's Task 1 boundary: runner 97819, helper
     715, one failure; the same test passed alone minutes later with the runner at a low pid, and
     passed in the leaf's baseline run half an hour earlier. So it is neither a regression from the
     roster-signal commits nor anything C6.2 touched — it is latent in the arrangement and fires on
     roughly one run in a thousand-pid window.
     Closer: do not derive the decoy pid from the runner. Spawn a second helper for the decoy and
     order the two by their observed pids, or keep the runner's pid and *skip* with a named reason
     when `livePID >= tab`, so an impossible arrangement reports as a skip rather than as a product
     failure. The `XCTAssertLessThan` is already an arrangement guard rather than a subject
     assertion, which is why it reads as a defect in the code under test when it fires.
     Owner: C4 (`FleetKit/Tests/FleetSessionsTests/LifecycleRowTests.swift`). Found by C6.2.

147. **A test that crashes the bundle is retried by `xcodebuild` and reports "Executed 0", not a
     failure.** Found at C6.2's Task 3 boundary. `ComposerMountTests` walks the channel column's
     view body with `Mirror` to assert the two mount points; when the composer's registry gained a
     route to `PanelHostModel`, that walk left the view layer and ran into the app's object graph —
     view struct → model → `ChannelContext` → link router, store, pane-exit closure — which is
     cyclic. It recursed until the stack ended. The bundle died, `xcodebuild` restarted it, and the
     final summary read `Test Suite 'ComposerMountTests' passed … Executed 0 tests, with 0 failures`.
     A suite that executes nothing is indistinguishable, in the summary a reviewer reads, from a
     suite that has nothing to run — and the run's overall exit code was still 0. The seven tests
     were only noticed missing because a per-suite count was compared against the previous run.
     Fixed locally for this walk (`ComposerViewTree` no longer descends into a reference type that
     is not itself a view; C5's `ViewTree` has the same unbounded shape but has never reached such
     a graph). The general hazard is not fixed: nothing in this repo's `make test` notices that a
     bundle restarted or that a suite's executed count fell to zero.
     Closer: have the test target's runner fail when a suite reports zero executed tests while
     declaring test methods, or diff per-suite counts against a committed baseline in `make test`.
     Owner: C5's test tooling (`Tools/c5/`), which already owns the wiring check.

148. **`check-app-wiring.py` cannot see a member whose only caller is inside a package.**
     `ComposerModel.confirm(preview:)` witnesses `FleetKit.StrategyUI`; `StrategyExecutor.run` calls
     it through the `ui:` argument the composer hands itself in as, so no source under `App/` calls
     it and none should. The checker reported it as declared in `App/` and called only from
     `AppTests/`, which is the same category its `FRAMEWORK` set already covers for SwiftUI — for a
     protocol the check does not know about. C6.2 added one allowlist line with its reason
     (`2b2a236`, isolated so it can be reverted alone) rather than changing the rule or dropping the
     conformance. Note the asymmetry that made this visible at all: the sibling requirement
     `open(url:)` escapes the check entirely, because the check keys on a bare name and `open` is
     used elsewhere under `App/` — the known blind spot in entry 72. So the mechanism reports one of
     two identical cases and is silent about the other.
     Closer: teach the check about protocol witnesses — a member whose name and signature match a
     requirement of a protocol the type conforms to is called by whoever calls the protocol. Owner:
     C5's test tooling.

149. **`ProcessRunner` cannot set a child's working directory.**
     `ClaudeWire/Sources/WireEnvironment/ProcessRunner.swift`'s `run` takes an executable,
     arguments, an environment and a timeout, and no directory. C6.2's `!` escape is defined by the
     directory it runs in (§6.6: "in the channel's directory with the resolved environment"), so it
     could not reuse the runner and spawns locally in `HostShellRunner`, copying `ProcessJob`'s
     settlement rather than its code — exit-driven completion rather than EOF on the pipes, so a `!`
     that backgrounds a daemon does not hang; non-blocking drains; a budget then SIGTERM/SIGKILL.
     The rejected alternative was prefixing `cd <dir> &&` to the user's command, which puts a line
     in front of what they typed and changes what the transcript shows them running.
     Closer: a `directory:` parameter on `ProcessRunner`, after which `HostShellRunner` collapses
     into `FoundationProcessRunner`. Owner: C2. Found by C6.2 Task 4.

150. **`ShellEnvelope.neutralize` is idempotent, so double sanitisation is byte-invisible.** An
     escaped `<` has no `<` left, an escaped turn marker no longer matches, a defused prefix no
     longer starts its line. A host that neutralised a command or a stream before handing it to
     `wrap` therefore produces byte-identical output, and C6.2's G2 equality assertion — written
     believing it proved the composer sanitised nothing itself — passes. Demonstrated at Task 4 by
     three mutations, one carrying a marker through the command; all passed. The same assertion does
     catch a rule of the host's own: an appended element, a dropped byte, a merged or trimmed
     stream, each demonstrated failing. This is not a defect in the envelope — idempotence is a
     property worth having — but it means "called, never copied" (§6.6) is enforced by structure and
     review, not by any test, and C6.2's gate has been corrected in place to say so.
     Closer: if the property is ever worth testing, give `neutralize` a way to report whether it
     changed anything, and assert the host's call is the first. Owner: C2 if it is worth it; filed
     mainly so no later reader re-derives the false confidence. Found by C6.2 Task 4.

151. **`ChannelTimelineModelTests.testOpenSettlesOnAFinishedEventStream` has a wall-clock budget that
     fails under load. Recurred; worth fixing now rather than watching.** **Closed 2026-09-08 by the
     `main` corrective `8e0f0d7`** (delivery-fulfilled wait; the one-round claim moved to
     `FleetTimelineTests.IngestionTests`). Observed twice during
     C6.2: 621 ms at Task 5 and **1022 ms at Task 6's boundary**, both against a 500 ms budget, both
     while other builds were competing for the machine; alone on a quiet machine it settles in
     **51 ms**, so the budget is 10x the real cost and the failures are entirely load. Original note:
     observed once during C6.2's Task 5: 621 ms against a 500 ms budget while
     mutation builds were competing for the machine; it passed on the clean run and on the retry.
     Same family as entry 146 and as C2's entry 2 — a test whose failure reads as a product defect
     when what it measured was a busy host, and this repo now runs several `xcodebuild` invocations
     at once during a fix wave, so the condition is ordinary rather than exotic.
     Closer: raise the budget substantially, or make the assertion insensitive to load by settling on
     an observed event rather than on elapsed time. Owner: C6.1
     (`AppTests/ChannelTimelineModelTests.swift`). Found by C6.2 Task 5.

152. **`HostSignal.rewound` moves only the live half, and that is the design — recorded so nobody
     re-derives the alarm.** `StreamIngestion.signal` folds through `wire?.apply` and reports
     `liveChanges` only (`StreamIngestion.swift:192-201`); the durable projection is a separate
     cache and is untouched. C6.2's Task 6 read that as "an honoured rewind leaves the discarded
     turn on screen" and wrote an assertion that failed. It is not a defect. The durable half is
     built by walking back from the transcript's own leaf (`last-prompt.leafUuid`, else the last
     conversation record) through `parentUuid` — `Reader/WindowedTranscript.swift:111-128` — and the
     honoured rewind appends exactly one `last-prompt` naming the pre-rewind assistant, which
     arrives mirrored (`Fixtures/rewind-turn/README.md`). So the abandoned records fall out of the
     durable half as soon as that record lands, and `HostSignal.rewound` covers the live half in the
     interval. Two halves, two mechanisms, no gap.
     The observable a host-side test can actually assert is therefore the live one: an open
     streaming preview is cleared by an honoured rewind and left alone by a refused one. C6.2's G4
     asserts both arms. Filed for C6.3, which raises `decisionAnswered` through the same seam and
     would otherwise spend the same hour. No closer; this entry is the answer.

153. **C6.1 must call `ComposerModel.edit(_:)`, and no contract says so.** **Named as contract Y6 at
     C6.2's merge, 2026-09-08; the call and the two render sites are C6.1's (its G6); this entry
     closes when C6.1's merge shows them.** The composite gives C6.2
     the *Edit* request, the body reading and the *Fork from here* fallback, and gives C6.1 every
     row kind — so the affordance that starts an edit is a row action on a past user message, in
     `App/Timeline/`, while everything it triggers is in `App/Composer/`. Neither leaf's section
     names the call, and the cut's cross-child contracts (Y1–Y5) do not cover it: Y4 is the mirror
     case in the other direction (C6.1 calls C6.4's `AgentNavigation.show`) and was named
     explicitly, which is what makes the omission here visible rather than invisible.
     Left as it stands, C6.1 ships a row with no *Edit*, or an *Edit* wired to nothing, and item 13
     is dead at recomposition with every gate green on both sides. `check-wiring` reported
     `ComposerModel.edit(_:)` as declared in `App/` and called only from `AppTests/` — correctly —
     and C6.2 allowlisted it in the category the file already uses for Y4's seam ("filled by C6.n")
     rather than inventing an affordance inside another leaf's directory.
     Closer: name it in the composite as a cross-child contract in Y4's shape, and give C6.1 the one
     call. Owner: the C6 composite (the architect). Raised by C6.2 Task 6.

     **Two more faces of the same omission, found by Task 10's gate audit.** The call is the incoming
     half; the missing render sites are the outgoing half, and neither is reachable from this leaf's
     fence either.
     (a) **`ComposerModel.editNote` is written in eight places and read by no view.** It is the note
     G4 requires on every refused-rewind arm — "the conversation was not rewound and a fork was
     opened instead", the no-fork-point reason, the two distinguishable refusal wordings. Every arm
     is asserted on the model and none of them is visible anywhere, so G4's "shows a visible note"
     clause is discharged at model level only. It has no natural home in `App/Composer/`: the note is
     about a past message the user chose to edit, so it belongs beside that row.
     (b) **`ComposerModel.interceptedReplacements` is written and read by nobody.** §7.7 and G1 ask
     that the drift replacement be shown *in place of* the offending assistant frame. The map is keyed
     by frame uuid precisely so a renderer can substitute; `RefusalSurface` instead draws
     `lastInterception.replacement` as an **additional** label beside the field, which annotates the
     refusal rather than replacing it. The substitution site is a timeline row — `App/Timeline/`,
     C6.1's — so this leaf can file it and not fix it. The interception, the replacement text and the
     per-shape counts are all asserted and correct; only the substitution is missing.
     Closer for both: the same composite contract that gives C6.1 the `edit(_:)` call gives it the two
     render sites — the note beside the edited row, and `interceptedReplacements[uuid]` consulted when
     an assistant row draws. Owner: the C6 composite, with C6.1.

154. **`HostSignal.promptSent` reaches the fold and produces no `TimelineChange`, so no surface can
     show a queued message before the engine echoes it.** `WireReducer.apply(_ signal:)` appends the
     uuid to `outstandingPrompts`; that array is not in `Snapshot`, so `difference(to:)` reports
     nothing, `StreamIngestion.signal` returns an empty `Effect` and `ChannelTimelineModel.signal`
     does not republish. Measured at C6.2's Task 6b against the real reducer, with the negative
     asserted (`testPromptSentPutsNoRowInTheChip`, floored by the `command_lifecycle` arm so it
     cannot pass vacuously).
     This is not a defect in the X5 corrective (`d802792`), which delivered exactly what it
     promised: the uuid is now available and `TurnAttribution.prompted(uuid:)` works, where before
     this every turn afleet reduced was `.unprompted`. It is a gap between what the host-signal
     corrective's design implies — a pre-echo preview — and what the fold currently models. C6.2's
     queue chip therefore renders from `Overlay.queue` alone, which is what §8.5 describes and what
     G3 asserts, so nothing is blocked.
     Closer: if a pre-echo queued row is wanted, C3 models an outstanding prompt the snapshot diffs
     and the chip reads it like any other reduced state. Owner: C3 / the C6 composite, as a design
     decision rather than a fix. Raised by C6.2 Task 6b.

155. **The permission-mode picker cannot re-read its own value.** Model and effort are confirmed by
     a fresh `get_settings` after every click (`applied.model`, `applied.effort`), which is what
     makes §7.4's "the displayed value is a readback, never the last click" true of them.
     `set_permission_mode` answers an empty body, and no control request anywhere in the corpus
     reports the mode a running process is in — the only readback is the handshake's
     `current_permission_mode`, which arrives at connect and at a quiescent restart. So between a
     click and the next handshake the picker either shows a value nothing confirmed or shows the
     stale one. C6.2 chose the second: the click is remembered and never displayed, and the next
     handshake either confirms it or raises the disagreement, so the rule holds at the cost of the
     picker lagging its own click until the process restarts.
     Closer: a `get_permission_mode` request, or `set_permission_mode` answering the resulting mode,
     either of which is an engine change and not afleet's; failing that, nothing to fix — this entry
     exists so the lag is read as the readback rule holding rather than as a bug. Owner: nobody
     today; C1's probe suite if a readback ever appears. Raised by C6.2 Task 7.

156. **§8.6's fourth arm has nothing to stand on: the bypass acceptance is written and read by
     nobody.** C6.2 writes `FleetKitKeys.bypassAccepted` into the `fleetKit` namespace as §7.8
     requires, and `grep` finds no other reader in the tree — only the key's declaration and this
     leaf's code. So §8.6's "later owned spawns include the flag from the start, so the mode
     switches without a restart" is not implemented anywhere: nothing consults the acceptance when
     a launch configuration is built, and neither `ChannelState` nor `get_settings` reports whether
     the running process carries `--allow-dangerously-skip-permissions`. A surface therefore cannot
     tell arm 4 (already launched with the flag) from arm 3 (needs the restart) except by trying.
     C6.2 implemented arm 4 as the spec's own fallback says — with the acceptance stored, send
     `set_permission_mode` and restart nothing, and render whichever of the validator's three
     refusal strings comes back (2.1.263 `cli.pretty.js:750921-750931`) — so the behaviour is
     correct and self-correcting, but it asks the engine a question the host should already know
     the answer to, and on a process without the flag the user sees a refusal rather than a
     restart.
     Closer, and it is a C4 decision rather than a fix: either the launch path consults
     `bypassAccepted` when composing a spawn, or X5 publishes the launch flags the current process
     carries so a surface can branch without asking. Owner: C4, with the C6 composite ruling which.
     Raised by C6.2 Task 8.

196. **A process acquired after the quit clause's last census is ended by the exit, not by afleet.**
     The clause now re-reads the owned set after each termination pass and terminates whatever
     gained a process, bounded to three passes (`App/Header/QuitGuard.swift`). What that cannot
     close is a spawn landing after the final census: it receives no `.quit`, and `Fleet.shutdown()`
     terminates nothing, so the engine is wound down only when the exit closes its pipe. A spawn
     barrier over the census would close it and was ruled out — a lifecycle-wide lock taken at the
     moment the app is trying to stop, for a window measured in one pass. Closer: X5 gains a
     "refuse new processes" state the clause can raise, or `Fleet.shutdown()` terminates what it
     still owns. Owner: C4, if the pipe-close teardown ever proves insufficient (see 195). Filed
     2026-09-08 by C6.2's review wave.

197. **A composer keeps its event subscription after its channel leaves the screen.** The mount
     resolves and subscribes the composer of whichever channel is being drawn, which is what makes a
     switch between two same-mode channels work at all; nothing stops the previous channel's
     subscription, because its view never disappears. Each visited channel therefore holds one live
     `events(of:)` fan-out until its composer is released. It is cheap and it keeps the queue chip
     and the handshake current, but it grows with the session and is not a decision anyone took.
     Closer: the mount stops the composer of the channel it is switching away from, or the registry
     bounds how many composers stay subscribed. Owner: C6.2's next pass. Filed 2026-09-08 by C6.2's
     review wave.

198. **The late `/rewind` confirmation is declined in a property observer rather than at the
     raise.** `ComposerModel.rewindAnswer` carries a `didSet` that resumes a continuation handed to a
     released composer, because the raise itself — `StrategyUI.confirm(preview:)` in
     `App/Composer/CommandRouting.swift` — was outside this wave's fence. The behaviour is right and
     the check is in the one place every raise passes through, but the natural home is a guard at the
     top of `confirm`. Closer: move it there and drop the observer. Owner: whichever wave next edits
     `CommandRouting.swift`. Filed 2026-09-08 by C6.2's review wave.

199. **An honoured rewind whose prefill is dropped offers no way back to it.** `ComposerModel.edit`
     writes the engine's `prefillText` only when the field still holds what it held when the edit
     was asked for; typing that arrived while the request was in flight is kept instead, and the
     composer says so. That is the right side to err on — the user can see their own words and never
     gave them to anything — but the edited message's text is then simply gone from the surface,
     and the only way back to it is to edit the same message again. Small, and outside this wave's
     scope: a second surface (an *Insert the edited message* affordance, or a held prefill the field
     offers) is a design decision the composer's own spec should make rather than a fix. Raised by
     the C6.2 fix wave for scalpel-2#6. Owner: C6.2.

202. **Composer mounting asks nothing about the channel's origin.** `App/Composer/ComposerMount.swift`
     mounts a composer for any key it is handed: it reads no `LifecycleAPI.state(of:)` and no listing
     mode, so a channel the user's own terminal holds gets a live field whose every send is refused
     one call later. The `!` half of this was closed in the C6.2 fix wave — the escape asks
     `state(of:)` before it spawns anything, so no host-side effect precedes the refusal — and the
     plain-send half is harmless in the same way every other refusal is: the words stay in the field
     and the reason is shown. What is left is the affordance, not a correctness defect: the composer
     offers a field where the answer is always no. Closer: the mount consults the origin and renders
     the refusal (or the *Fork* the banner already offers) instead of the field. Owner: the C6.2 leaf
     that owns `ComposerMount.swift`. Filed 2026-09-08 by the C6.2 fix wave.

205. **A queued quiescent restart is announced and then forgotten.** `perform(.quiescentRestart)`
     answers as soon as the change is *recorded*, and a channel that is not eligible keeps it as
     `pendingChange` for its dormant timer. C6.2's fix wave stops the surface confirming anything
     there — the field re-opens and the banner says the change applies when the current work
     finishes — but nothing resumes §7.4's readback when the timer later runs it, so the user is
     told the setting is pending and never told it took. The signal exists on the wire (the new
     process handshakes with a fresh epoch, on `events(of:)`, which *is* a fan-out); what does not
     exist is a reason for the surface to be watching for it, since `LifecycleAPI.updates` is one
     stream with one consumer and cannot be joined by a second. Closer: the composer's own event
     loop notices a handshake whose epoch differs from the one the queued restart was asked
     against and re-runs the readback, or X5 publishes per-channel state a surface may subscribe
     to. Owner: the C6 composite, with C4 if the second shape is chosen. Raised by C6.2's fix wave.
     Round 5 (scalpel-1#1) restates the same gap from the gate's side: `noteQueuedRestart` marks the
     operation done, so when the deferred restart later runs and its readiness is published, nothing
     reconciles the composer's gate and the field can stay closed — the epoch watch this entry asks for
     is the closer for both.

206. **A strategy's answer is a one-line note where three of them are screens.** `StrategyOutcome`
     carries `permissions` (the whole `get_settings` body), `mcp` (the server list) and `memory`
     (the memory files) and the composer now says how many of each came back, plus the engine's own
     sentence for a refused rewind. That is presentation, not the surface each is: bare
     `/permissions` is §7.7's read-only rules view, `/mcp` is the header's popover (which the header
     already draws for its own menu item and the composer cannot reach), and `/memory` is a list of
     paths a note may not name (§11). Closer: the panel or popover each names, once C6.4 and the
     header's popover are reachable from a routed line. Owner: the C6 composite. Raised by C6.2's
     fix wave.

207. **Three `.native` destinations have no target to open.** `modelPicker` and `effortPicker` now
     open the header's own pickers. `tasks`, `agents` and `switcher` are handed to the workspace's
     link router as `WorkspaceLink.command(_:)`, which is the app's only "open the surface named
     this" API — and no `LinkTarget` claims a command link today, so the router answers with a
     diagnostic. What is missing, named: the Agents tab is C6.4's and does not exist; a Tasks
     surface is named by the table and by nothing else in the tree; and C5's switcher is opened by
     `ShellModel.presentSwitcher()`, which a composer cannot reach — it holds a `ChannelContext` and
     the shell is not on it. Closer: each surface registers a `LinkTarget` for its own command name
     as it lands, and the shell registers one for the switcher. Owner: C6.4 (agents), C5 (the
     switcher). Raised by C6.2's fix wave.

208. **The mode half of §7.4's readback races the handshake that carries it.** The only readback
     permission mode has is the handshake's, which reaches the pickers through the composer's own
     `events(of:)` loop, while `confirmReadback` runs on the caller's task the moment
     `perform(.quiescentRestart)` returns. Nothing synchronises the two: on a slow delivery the
     comparison reads the *old* process's mode and banners a setting that did in fact survive. It
     was latent before (the snapshot carried the same stale value, so the two agreed by accident)
     and is visible now that the snapshot carries the mode the channel is running. Closer: the
     readback waits for a handshake whose epoch is the new process's before comparing the mode —
     the same watch item 205 needs. Owner: C6.2. Raised by C6.2's fix wave. **Closed** by C6.2's
     second fix wave: the mode is read from X5's `engineReports(of:)` — the handshake the fleet
     retains for the channel — after the epoch has been established to have advanced, and an
     unresolved mode holds the gate instead of releasing it (item 214 is what remains of the watch).

209. **`HostSignal.promptSent` is raised after `sendPrompt` returns, and an engine result can arrive
     first.** `ComposerModel.post` registers the uuid with the fold only once the facade has answered,
     while `ChannelSupervisor.deliver` awaits the process write and the wire fans out independently; a
     result that lands in between is reduced `.unprompted` and the late uuid then attributes the *next*
     result. Bounded to one misattributed turn and needs a result faster than a facade round trip (an
     immediate refusal is the realistic case). The remedy is not a composer patch: the supervisor owns
     both the write and the fold's inputs, so it should raise the signal itself before the write — an
     X4/X5 design change for C3 and C4 at C6's recomposition. Owner: the C6 composite (architect).
     Filed 2026-09-08 at C6.2's merge review (panel round 2, scalpel-1#1).

210. **`HostSignal.promptCancelled` is raised after the cancel's answer, and a result can consume the
     uuid first.** Same shape as 209 from the other side: the chip retires the uuid only when
     `cancel_async_message` answers `cancelled: true`; a result ingested in between takes the cancelled
     uuid off the outstanding list, and the later removal cannot repair the attribution. Same remedy
     and owner as 209. Filed 2026-09-08 (panel round 2, scalpel-1#2). *Stop everything*
     (`Interrupt(cancelQueued: true)` through `perform(.stopEverything)`) cancels every queued prompt and
     retires none of their uuids either — the same remedy covers it (panel round 4, scalpel-3#1).

211. **`Fleet.forkResolutions` is written for every fork and read by one caller.** The map recording
     a fork's provisional-to-resolved key is the only place the two ids are ever linked, so it is
     written whenever `publish` re-keys a channel — but `resolvedForkKey(of:)` is the only reader,
     and `perform(.fork)` and a routed `/fork` never ask. Each unread fork therefore leaves one key
     pair behind for the life of the process. Bounded by the number of forks a session opens and
     measured in tens of bytes, so it is filed rather than fixed. Closer: record only for a
     provisional key `Fleet.fork(at:on:)` handed out, and drop it when the channel is released.
     Owner: C4. Raised by C6.2's second review round.

212. **`EditAndRewindTests` prints a `ChannelKey` on two failures.** The pre-existing fork arms
     compare `rig.selected` to an array of keys, so a failure prints a config home under the
     process's temporary directory and a session id (§11). It is a failure message and not a report,
     but the rule is about the byte reaching a file at all. The arm added in the second review round
     compares a count and a boolean instead; the two older ones were left alone to keep the wave's
     diff to its findings. Closer: the same count-and-boolean shape. Owner: C6.2.

213. **The read-only gate is in the mount, not in the model.** A row C5 lists read-only is given no
     composer, which makes every write path unreachable from the UI — but `ComposerModel.send()` and
     the `!` escape carry no refusal of their own, so a caller that reached a retained composer for
     such a channel would not be refused the way `surface.isDisabled` refuses one. There is no such
     caller today: the registry builds a composer only for a drawn channel, and a read-only channel
     is never drawn with one. Filed because the same reasoning was wrong once already — the header's
     gate was in the view and this finding is what that cost. Closer: the read-only reason joins
     `ChannelSurfaceState`, so the model refuses on the same seam the restart already closes.
     Owner: C6.2.

214. **An owed readback is settled only by a handshake that arrives afterwards.** C6.2's second fix
     wave retains the snapshot when a confirmation cannot be completed — the channel did not answer
     `get_settings`, or the fleet had no permission mode to report for the replacement — and the
     field stays closed until the next handshake re-runs the comparison. That handshake is the
     replacement reporting, so it normally arrives; but a replacement that handshook *before* the
     hold was taken, or one whose handshake is lost, leaves the confirmation owed with nothing to
     settle it, and the field stays shut until the user changes a setting. It is the same missing
     watch as item 205 — a surface with no per-channel state to subscribe to — and the closer is the
     same: the composer's own event loop, or per-channel state on X5, re-running an owed
     confirmation on any epoch change rather than only on a handshake it happens to see. Owner: the
     C6 composite, with C4 if the second shape is chosen. Raised by C6.2's second fix wave.

215. **Answering the fleet's banner re-sends a value the engine already applied.** The fleet resolves
     its unresolved settings strictly in order, so a correction made out of that order cannot advance
     it; the surface now re-answers each setting the fleet still names with the value the readback
     reports, which for a setting the user has already corrected is one extra `set_model`,
     `apply_flag_settings` or `set_permission_mode` carrying a value the process is already running.
     It is idempotent and bounded by the three settings the pickers own, and it is what makes the
     banner's promise ("pick a value to continue") true for a user who picks in their own order. What
     would remove it: `resolveSetting` accepting a correction for any unresolved setting rather than
     only the head of the list, so one request answers both halves whatever order they arrive in.
     Owner: C4 (`ChannelSupervisor.resolveSetting`), with C6.2 dropping the re-answer when it lands.
     Raised by C6.2's second fix wave.

218. **`ToolRunner` carries both of the escalation defects the `!` escape just had.** **Closed
     2026-09-09 by the `main` corrective `925a6e5`** (escalation keyed on its own flag; the group
     signalled whether or not the leader was reaped; two descendant tests). C7.3's
     `Workbench/Sources/SourceControlCore/ToolRunner.swift` is the arrangement C6.2's `ShellChild`
     was copied from, and it still keys its `SIGKILL` on `settled` and its `signalTree` on `reaped`.
     Both windows are the same: a budget expiring inside a termination's grace reaps the child and
     settles, and the escalation then skips the kill; and a settlement-time drain that ends the call
     can no longer signal a group whose leader has been reaped. A tool a panel runs writes the
     command, so `git` starting descendants is likelier there than in a chat field, not less.
     Closer: record the group separately from the pid, key the escalation on whether it has run, and
     drop `settled` from `beginTermination` — the three edits `ShellEscape.swift` took, with the two
     arms that arrange the orderings. Owner: C7.3. Found by C6.2's second fix wave (scalpel-3#1, #2)
     while reading the house pattern.

219. **A `!` whose group is still being escalated does not survive the app quitting.** The escalation
     is now owed to the group past the caller's answer, which means up to two graces (one second)
     during which the `SIGKILL` is a block on a dispatch queue and nothing else. If afleet exits in
     that window — a quit, a crash, a test host tearing down — the block dies with the process and a
     descendant that ignored the `SIGTERM` stays on the machine. The same is true of
     `abandonUnreapedChild`'s off-queue reap. Bounded and rare, and unfixable inside the child alone:
     the closer is that §7.4's quit path drains what the composers still owe their groups before it
     terminates, in the same pass that ends the channels. Owner: C6.2 (the quit clause). Raised by
     C6.2's second fix wave.

225. **The delayed `SIGKILL` names a process-group id whose identity is no longer retained.**
     `ShellChild` defers the leader's reap during a termination precisely so the pid keeps naming the
     group, but two paths reap inside the escalation grace anyway: the budget's timer reaps and
     settles, and a settlement reached any other way reaps too. The retained `SIGKILL` block then
     calls `kill(-group, …)` on a stored number with nothing holding that number reserved. For the
     signal to reach a stranger the whole group must exit inside the grace *and* the pid space must
     wrap onto that id in the same window — at most one second, with the group's own exit as the
     first of two coincidences. Left standing deliberately: C7.3's `ToolRunner` and every runner of
     this shape accept the same window, and closing it means keeping identity alive across the
     escalation (holding the leader unreaped until the last signal, or a pidfd-style handle the
     platform does not offer for groups) — a redesign of the reap, not a patch. The one mitigation
     worth having is taken on the branch: `kill(-group, 0)` immediately before the `SIGKILL`, which
     skips the signal for a group that is already gone and narrows the window to the probe-to-kill
     gap. Closer: whoever revisits the reap ordering — most likely alongside 218, which is the same
     code in C7.3 — decides whether identity can be held to the last signal. Owner: C6.2 with C7.3.
     Filed by C6.2's third review round (scalpel-2#1), with the architect's disposition recorded.

226. **A fork whose handshake crashes strands the edit's prefill under a key nobody migrates.**
     `ChannelSupervisor.handleExit` settles the fork-identity waiters and clears the identity timer even
     when the same exit schedules an automatic respawn, so `settledForkKey()` answers the *provisional*
     key for the whole of the backoff. *Fork from here* takes that answer, and the registry files the
     edited message's prefill and the selection under it; the replacement that comes back from the
     respawn re-keys the channel, and nothing migrates a pending draft or a selection across a re-key.
     The user's edited message is then waiting under a key no composer will ever be built for. Needs a
     crash inside a fork's handshake window, so it is rare rather than impossible. Closer: either keep
     the waiters pending across a scheduled respawn — bounded by the fork-identity deadline, so a fork
     that never resolves still fails rather than hanging — or have the registry migrate pending drafts
     and selection when a channel is re-keyed. Owner: C4 with C6.2. Filed 2026-09-09 (panel round 4,
     scalpel-4#1).
     Round 5 adds two faces (scalpel-5#1, #2): a respawn refused by a precondition or the cap arms no
     new deadline, so waiters admitted under `forkIdentityResolving` never resume; and the deadline's
     expiry settles waiters with the unchanged provisional key, which `EditAndRewind` reports as success
     and hands to the registry — the draft is then stranded under a key no row resolves. Closer: the
     settle answers nil on refusal and on deadline, and the composer reports the fork as not opened.

228. **The fleet still merges two restart-required changes; no surface exercises that any more.**
     The gate's redesign (Decision Log, 2026-09-09, the fourth fix wave) refuses a second
     restart-required change while one is running, so the "second `quiescentRestart` merges into the
     pending change and answers success at once" path is unreachable from a single
     `SettingPickersModel`. `ChannelSupervisor` still merges — two afleet windows over one channel
     each hold their own pickers and their own field, and each is independently correct about its
     own surface — but nothing asserts what the second window's surface shows while the first
     window's restart runs, and the arm that used to cover the merge now covers the refusal instead.
     Small: the surfaces do not share state and the fleet's own merge is C4's, tested there. Closer:
     one arm building two `SettingPickersModel`s over one `ChannelKey` and one double, asserting each
     field independently. Owner: C6.2. Filed by the fourth fix wave.

229. **Readiness is read as `.owned(.connecting)` and not as "anything but `.owned(.ready)`".**
     The gate closes the field and refuses setting changes for a channel the fleet reports as
     connecting, which is the state a restart that threw after spawning leaves and the state review
     round 4's P1 named. `.owned(.dormant)` and `.owned(.contended)` are left alone deliberately —
     both are other leaves' semantics, a dormant channel is woken by typing into it, and closing the
     field over either would be this gate forming an opinion it has no evidence for. Whether a
     setting change asked for on a dormant channel does the right thing end to end is unexamined:
     the request would reach `ChannelSupervisor` with no process on the other end. Closer: read what
     C4 does with a control request on a dormant channel and either widen the input or record why
     the narrow reading is right. Owner: C6.2 with C4. Filed by the fourth fix wave.

230. **The restart gate's admission is not atomic across its own awaits.** `allows(_:)` reads the
     operation's phase, then awaits `lifecycle.state(of:)` and the fleet's held setting, and answers
     from the earlier reading; a `beginRestart` landing inside those awaits is not seen (round 5,
     scalpel-1#2). Both restart entry points also await the channel's state after admission and then
     `beginRestart` unconditionally, so two concurrent callers can supersede each other's generation
     and the supervisor's merge-and-queue path is reached after all (scalpel-1#3; 228 is the untested
     fleet side of that path). Bounded to concurrent restart-required changes on one channel from two
     surfaces. Closer: the admission takes the operation slot first and validates after, or the whole
     predicate runs on one actor-isolated read. Owner: C6.2. Filed 2026-09-09 at the fifth review round.

231. **An accepted bypass cannot resolve a `permissionMode` restart mismatch.** `BypassGate` asks the
     gate for `.bypassMode`, and while the channel is connecting over an unresolved setting the gate
     admits only `.settingChange`, so the `resolveSetting` recovery that `issueMode` offers for the other
     modes is unreachable for bypass (round 5, scalpel-2#1). The user can still recover by picking a
     non-bypass mode. Closer: admit `.bypassMode` as a setting change when the unresolved setting is
     `permissionMode` and the launch prerequisite is met. Owner: C6.2. Filed 2026-09-09.
## From C7.2 (`child/c7-editor-core`)

97. **Closed 2026-09-08 (`b9ef4f8`).** **`PanelHostModel.unregister` releases the tab's state
    before awaiting the link-target withdrawal (C7.2 fix-wave finding, outside its fence).** `App/Panels/PanelHostModel.swift`
    drops `tabs[id]`, the pane runners and every session, and only then awaits
    `links.unregister(tab:)`. While it is suspended on that await the main actor is free, so a
    delivery already committed inside `LinkRouter` can reach a target whose tab and sessions the
    host has torn down. `LinkRouter` now refuses to deliver to a token withdrawn during its own
    suspension, so the registry is consistent; this is the same guarantee one layer up, and it is
    exactly what X7's 2026-09-06 amendment made `unregister` `async` to obtain. Closer: await the
    router's withdrawal *first*, then release host state — a reordering within
    `PanelHostModel.unregister`. Not done here because C7.2's app fence is `HostLinkRouter.swift`
    alone and C6's leaves are opening in the same target. Owner: C5/C6 (X7).

98. **Closed 2026-09-08 (`b9ef4f8`).** **`LinkRouter.open` may run `prepare` more than once
    for one call.** When the resolved target
    is withdrawn during `prepare`, the router re-resolves and runs `prepare` again for the
    successor — deliberately, because a pop-out prepared for a tab that then left is not one
    prepared for its replacement. The host's pop-out is idempotent enough today that this is
    harmless, but it is a behavioural fact any `prepare` implementation must tolerate rather than
    an accident. Closer: none needed unless a `prepare` with non-idempotent side effects appears;
    then the retry needs a way to undo the first preparation.

99. **The split Monaco build emits a byte-identical duplicate stylesheet.** `tsMode-<hash>.css`
    and `editor.css` are the same 164.76 KB content, and `freemarker2-<hash>.css` is a third
    language-mode sheet; all three are loaded through the generated `styles.css`. Roughly 165 KB
    of the 13 MB bundle is redundant. Closer: a bun build option or a post-pass in
    `Tools/build-monaco.sh` that de-duplicates emitted assets by content hash. Owner: C7.2's
    build script, whoever next bumps Monaco.

100. **`HostLinkRouter.targetCount` is `async` and its only caller is a test.** Tracker entry 73's
     class, unchanged by C7.2 except that the delegation made it `async`. It stays because a
     registry with no observable size is hard to diagnose. Closer: a diagnostics line that reads
     it in the running app, or deletion.

101. **Resource Timing reports nothing for the `afleet-editor` scheme.** A `WKURLSchemeHandler`
     serves every document, chunk and worker request, and `performance.getEntriesByType("resource")`
     returns zero entries for them. So S3 proves dynamic-import chunk loading by its *effect*
     (grammar scopes present in the tokens) rather than by the network timeline, and any future
     per-asset timing needs instrumenting inside the scheme handler in Swift. Owner: C7.5 if it
     ever needs per-asset load timings.

102. **`requestAnimationFrame` stops in an occluded window, and a locked screen occludes
     everything.** Every frame-based measurement then hangs rather than fails. The S3 harness
     measures frame liveness first and overrides the window's reported occlusion when it finds
     none, recording `occlusionOverridden`; the committed numbers were taken with the override
     off. Closer: none — this is AppKit behaviour. Worth knowing before anyone writes another
     frame-timing harness.

103. **`xcodebuild` intermittently aborts at the package-bundle transition.** Two of four full
     `make test` runs during C7.2 died with `DVTAssertions: Message sent to invalidated object:
     IDESwiftPackageTestBundleProductBuildable` and `Abort trap: 6`, *after* every app test had
     passed, at the hand-over from the last FleetKit bundle to the first Workbench one. Xcode
     26.6, 13 test bundles in one scheme. Not caused by any diff; the same bundles pass under
     `-only-testing` and under `swift test`. It will read as a failure in CI and is not one.
     Closer: split the scheme, or retry the transition.

104. **`readBuffer` does not clear the editor's dirty flag.** Only the host knows whether its
     write succeeded, so `bridge.js` leaves the flag set until the next `open` or `setText`.
     C7.5 will meet this the first time it wires *Save*. Closer: a host-to-editor acknowledgement,
     which is a W4 vocabulary addition and therefore a contract change, not a local fix.

105. **W4's `error` has no discriminator, so a host cannot tell a refusal from a failure.** The
     bridge refuses `save` while a diff is on screen (C7.2 fix-wave finding B1) with
     `error {message}`, because that is the whole editor-to-host vocabulary for "no". A host
     that wants to re-issue the save against the editor, rather than surface a failure to the
     user, has only prose to branch on, and prose is not a contract. Closer: a `kind` or `code`
     field on `error`, or a distinct refusal message — either is a W4 vocabulary addition and
     therefore a contract change, of the same class as entry 104's acknowledgement. Owner: C7.5
     the first time it wires *Save* beside C7.7's diff.

106. **The bun executable that generates the Monaco bundle is recorded, not enforced.**
     `Tools/build-monaco.sh` refuses to run without `bun` on PATH and writes `bun --version` into
     the bundle's `VERSION`, but nothing checks *which* version that is. `Tools/monaco/bun.lock`
     pins Monaco's dependency graph; it does not pin the bundler that reads it, and the script
     emits minified, code-split, content-hashed output — so the committed inputs do not by
     themselves determine the committed bytes, and a rebuild under a different bun can produce a
     different tree from an unchanged repository. That is only a latent nuisance today (nothing
     rebuilds the bundle in CI, and `VERSION` carries no date so an unchanged rebuild is a no-op),
     but it is exactly the property the committed bundle is supposed to have. Closer: pin the
     version in the script and refuse to build under another, or — the weaker half, already
     present — keep recording it in `VERSION` beside Monaco's and treat a mismatch as a rebuild
     hazard. Owner: C7.2's build script, whoever next bumps Monaco.

107. **A tab popped out by `prepare` that withdraws with no successor leaves a presented window
     whose tab no longer exists.** The router's one-preparation rule and the host's per-tab
     generation stop a second window and a stale re-add (C7.2 waves A, D and G), but nothing undoes
     a pop-out already presented when the target then withdraws and the open falls back. Closer: an
     undo path on `prepare` (the router hands the host the preparation to retract on fallback), or
     the pop-out scene dismissing itself when its tab is gone. Owner: C7.5, which owns the first
     panel that pops out under load. Filed 2026-09-08 at C7.2's merge from wave A's report.

## From C7.3

Filed at the close of C7.3 (Source Control core; ledger
`docs/doperpowers/ledgers/2026-09-07-c7.3-scm-core.md`). Numbers 112 through 126 are this
leaf's reservation; 125 onward are unused.

112. **`SourceControlCore.ToolRunner` duplicates C2's process mechanics.** Termination-handler
     exit observation, non-blocking pipe drains, timeout with grace and `SIGKILL` are written
     twice: once in `ClaudeWire/Sources/WireEnvironment/ProcessRunner.swift` and once in
     `Workbench/Sources/SourceControlCore/ToolRunner.swift`. The duplication is forced, not
     careless: contract X1 forbids Workbench from importing `ClaudeWire`, and X2 keeps
     `AfleetCore` to value types, so neither existing home was available. Two copies is
     tolerable; a third is the signal to extract a process package below both. Owner: whichever
     child needs the third copy, or C2 if it revisits the package split.

113. **Workbench has no §11 diagnostics domain.** §11's table names four log files
     (`diagnostics.log`, `fleet.log`, `timeline.log`, `app.log`) and none belongs to the panel
     layer, so C7.3 logs nothing and returns typed errors for the panel to render (§10). When a
     panel wants a durable record of a failing `git` or `gh` invocation, the domain has to be
     opened in §11's table with a writer that owns the file — one writer per file, per the
     2026-09-07 amendment. Owner: C7.7, or C5 if it opens it first.

114. **The commit graph is read in a fixed window with no paging above it.** `GitLog.commits`
     defaults to 2,000 commits (`-n`/`--skip`); lane assignment marks an edge to a parent
     outside the window `truncated`, but nothing fetches the next page. Correct for a viewport,
     incomplete for a scroll. Owner: C7.7 when the panel's scroll needs it.

115. **Closed 2026-09-08 (`3c0ec27`).** The architect amended contract W7 to `--decorate=full`,
     so `%D` arrives as full ref paths and `GitLog.refs(from:)` strips `refs/heads/`,
     `refs/remotes/` and `refs/tags/` instead of guessing at the first slash; the pin stays
     explicit because `log.decorate=short` is now the adverse setting. **`%D`'s shortened
     decorations cannot distinguish a remote-tracking branch from a local branch whose name
     contains a slash.** Measured on `git` 2.55.0: `feature/x` is reported as
     `.remoteBranch(remote: "feature")` named `x`, and a local branch literally named
     `origin/feature` is indistinguishable from the remote-tracking one. The arrow form
     (`HEAD -> feature/x`) is exempt because it names a local branch by construction. No parser
     of `%D` can resolve this; the remedy is `--decorate=full`, which prints `refs/heads/…` and
     `refs/remotes/…` unambiguously and would simplify the parser rather than complicate it —
     but it amends contract W7's command line, which this leaf does not own. Raised to the
     architect as a parent revision at merge. Owner: whoever revises W7, most likely C7.7 when
     the panel draws ref badges and the distinction becomes visible.

116. **`ToolRunner` has no `timeoutState`.** C2's `ProcessRunner` sampled a
     `describeAtTimeout()` before signalling the child, which is what separated a hung child
     from one that exited without the runner observing it. That sampling was not carried across;
     the residual tell is the pair `exitCode == -1 && timedOut`, which is enough for a panel to
     render "the tool did not answer" and not enough to say which of the two happened. Filed
     rather than fixed because the state is only worth its cost once something consumes it, and
     nothing does yet (entry 113). Owner: whoever opens the Workbench diagnostics domain.

117. **`ToolJob.drainRemaining` is not falsifiable by any black-box test on macOS.** The final
     non-blocking pass over each pipe on the exit path always finds the pipe empty, because the
     readable event reaches the runner's queue ahead of the exit in every construction tried, so
     deleting it changes no observable behaviour. It is kept as defence for the ordering a loaded
     queue or another platform could produce, and the review that found this was explicit that
     an earlier apparent demonstration was an artifact of the assertion, not of the drain.
     Closing this means a seam that lets a test hold the queue busy across the child's last
     write. Owner: whoever next revises the process layer, or the extraction entry 112
     anticipates.

118. **`gh pr checks`' documented exit code 8 has no live confirmation.** C7.3 accepts 0 and 8
     from that verb because `gh`'s own help and its `cmdutil.PendingError` say 8 means "checks
     are still pending", and the behaviour is asserted with a stub runner. Twenty-six open pull
     requests across four large public repositories had all settled at the time of the gate, so
     no live run produced it. One live confirmation against a repository with a check in flight
     would close this. Owner: C7.7 at its GitHub-tab gate.

119. **`GraphRow.Edge.truncated` is easy to misread as "the line ends here".** It means only
     that the edge's target commit is outside the window `GitLog` read: the parent is never
     read, so its lane reservation is never released, and the lane repeats the same truncated
     straight-down edge on every row below to the bottom of the window. That is the wanted
     rendering — a line leaving a viewport does continue — but a consumer that read the flag as
     a terminator would stop the line at the first row that named it and draw a graph that
     disagrees with the lane state. Documented on the flag and pinned by a multi-row test;
     what would close it is either a name that cannot be misread or a rendering contract the
     panel and this type share. Owner: C7.7, the first consumer.

120. **One mutation of the first-parent rule survives C7.3's suite and may be equivalent.**
     Writing rule 3 as "the first parent takes the leftmost *free* lane" rather than the
     commit's own lane passes every test, because a commit's own lane is released immediately
     before that rule runs and is the leftmost free one in every fixture. Distinguishing the two
     needs a row read at a *reserved* lane while a lane to its left is free; a lane is freed only
     by a parentless commit or by a released duplicate, and three probed shapes — two roots with
     interleaved dates, and an unrelated-history merge in each direction — all had
     `git log --topo-order --all` follow one chain to its end before starting another, which
     frees lanes right to left. So the mutant may be equivalent under git's ordering rather than
     merely uncovered. Filed rather than chased: closing it means either a shape that orders the
     other way, or an argument that none exists. Owner: whoever next revises lane assignment.

121. **`GraphRow.edges` may contain several edges arriving in the same `toLane`.** A consumer
     that indexes a row's edges by destination lane silently drops one of each pair and
     disconnects a line at that row. It happens two ways: a merge reaching into a lane another
     child already reserved, where the lane carries both the merge's edge and the pass-through
     of the line already running down it; and two lanes converging on one parent, where both
     bend into the lane the parent was read at. This was three of the five findings at C7.3's
     whole-branch review, and the model was changed once to allow it (ledger D43). Documented on
     `GraphRow.Edge` and pinned by a connectivity assertion over every lane fixture; what would
     close it is a rendering contract the panel and this type share. Owner: C7.7, the first
     consumer.

122. **`log.excludeDecoration` silently removes decorations from `%D` and no command-line option
     overrides it.** Measured on `git` 2.55.0: a user who sets `log.excludeDecoration=refs/tags/*`
     — a reasonable thing to hold for one's own `git log` — gets a commit graph with no tags on it,
     and the same for any pattern they chose. Every other configuration this module is sensitive to
     is pinned on the command line (D45); this one is not pinnable. `--decorate-refs=<pattern>`
     does override the setting but replaces the whole decoration set, and was measured to drop
     `HEAD` while restoring tags, which is a worse answer than the one it fixes; `-c
     log.excludeDecoration=` adds an empty pattern that matches everything and removes all
     decorations. The blast radius is bounded — decorations missing from the graph, never a wrong
     edge or a wrong commit — and `AdverseConfigurationTests` documents it as unpinned rather than
     ruled out. What would close it: read decorations from `git for-each-ref` and join them to the
     window by object name, instead of from `%D`. Owner: whoever next revises `GitLog`, and a
     natural companion to the `--decorate=full` swap entry 115 records as taken.

123. **Nothing enforces that a setting `AdverseConfigurationTests.ruledOut` names can be exhibited
     by the fixture that measures it.** The suite carries two dictionaries: `hostile`, the settings
     the command-line pins defend against, and `ruledOut`, the settings measured to reach no byte
     any parser here reads. `ruledOut` is a tripwire, and a tripwire is only worth its name if the
     repository under it can make the setting speak. Two of C7.3's eighteen could not be:
     `log.showSignature` acts only over a *signed* commit and every fixture was unsigned, and
     `diff.renameLimit` acts only on the *inexact* half of rename detection and the only rename in
     the fixture was exact. Both measured inert, both went into the tripwire, both were live
     silent-wrong-answer defects, and both were found by an external reviewer rather than by the
     tripwire. R5 fixed the fixture — the repository the tripwire runs against is now signed and
     carries a `.mailmap`, a note, an upstream, a subdirectory, an inexact rename and a modified
     file — and wrote floor assertions saying each of those shapes is present. It did not fix the
     *mechanism*: the enrichment and the floor are hand-written, and the next entry added to
     `ruledOut` can be inert for the wrong reason again with nothing to say so. Bounded, because a
     wrong verdict costs a missing pin, which is the class the suite already treats. What would
     close it: a per-entry note of the property the fixture must have for that setting to speak,
     checked by the test, so that adding an entry without the property fails. Owner: whoever next
     extends `AdverseConfigurationTests`.

124. **The rename-limit pin hard-codes git's default in two modules.** `GitDiff` passes `-l1000`
     and `WorkingTreeStatus` passes `-c diff.renameLimit=1000 -c status.renameLimit=1000`, where
     `1000` is git's documented default for `diff.renameLimit` — pinned rather than lifted to `0`
     (unlimited) on purpose, because a user who lowered the limit lowered it for speed on a large
     repository and the panel's answer should be git's default answer, not a slower one no
     configuration would ever have produced. If a future git changes that default, the panel
     freezes the old one silently, in the direction of doing more work rather than less, so nothing
     fails and no test notices. Trivial and stable in practice; filed because the number is a copy
     of another program's documentation with nothing linking it back. Owner: whoever next revises
     the configuration pins.

125. **Closed 2026-09-08 (`d0e32b6` on `main`): one drain pass in C2's `ProcessRunner` is bounded
     (`PipeDrain.bytesPerPass`, one mebibyte, 64 KiB chunks); a spent budget re-arms the read source
     and the queue turns; ClaudeWire 251/6/0. Original:** C2's `ProcessRunner` carries the same unbounded pipe drain C7.3's `ToolRunner` had.**
     `ClaudeWire/Sources/WireEnvironment/ProcessRunner.swift` reads while data keeps arriving and
     returns only on `EAGAIN`, on the same serial queue that runs its timeout, its `SIGKILL`
     escalation and its settlement — the shape C7.3's R6 review found and bounded in its own copy
     (`PipeDrain.bytesPerPass`, one mebibyte per readable event). C7.3 could not fix it: contract
     X1 forbids Workbench from importing `ClaudeWire`, the two runners are deliberately separate
     copies (entry 112), and the file belongs to C2. The exposure there is larger, not smaller: that
     runner drives the engine's own long-lived processes rather than short `git` reads. What would
     close it: the same bound applied in C2's copy, or the extraction entry 112 anticipates, which
     would leave one copy to bound. Owner: C2, or whichever child needs the third copy.

126. **The bound on one drain pass has no end-to-end tripwire.** `PipeDrain.bytesPerPass` exists so
     that a producer cannot own the runner's queue; deleting it leaves every black-box test in the
     suite green. Measured over five producer shapes — one `dd` at 64 KiB, 1 MiB and 4 MiB blocks,
     and four and eight of them at once — this machine's drain consumes about 3 GB/s and no
     user-space producer keeps a 64 KiB pipe fed at that rate, so the loop reaches `EAGAIN` between
     events and the timeout fires within 13 ms of its deadline either way. The bound is therefore
     pinned at the seam (`PipeDrain.pass` against a descriptor that never says `EAGAIN`) and the
     flooding-child test is a floor rather than a discriminator. The same testability limit as
     entry 117, one layer up, and it is what let the defect live: a review found it by reading.
     What would close it: a seam that lets a test hold the queue busy across a producer's writes,
     or a fake descriptor whose readability the test controls. Owner: whoever next revises the
     process layer, or the extraction entry 112 anticipates.

## From C6.1 (`child/c6-timeline-renderer`)

Entries **127 through 141** are C6.1's, as the C6 composite's leaf table allots them. Nothing above
is renumbered.

**Extended 2026-09-09: entries 321 through 335 are also C6.1's.** The composite's leaf table allotted
127–141 and this leaf spent all fifteen by Task 7; 142–320 are other blocks' reservations
(292–319 C6.3's review, 298–299 C7.1's, 300–305 C6.3's). Everything C6.1 files from Task 8 onward is
numbered from 321. Nothing above is renumbered.

127. **The live thinking-token estimate has no home in C3's model.** `system/thinking_tokens`
     carries `estimated_tokens`, `estimated_tokens_delta` and a `uuid` naming the *user* message the
     turn answers (2.1.263 `cli.pretty.js:811445`; emitted at `:523066` and `:289222`). ClaudeWire
     models the frame as `SystemFrame.thinkingTokens`, but `Overlay` has no field for the estimate
     and `WireReducer.route(_ system:)` sends the frame to its `default:` arm, where it becomes an
     opaque item — an "unrecognized event" row for every one of the nine `nested-depth-2` carries.
     §8.3 wants the estimate live under a thinking disclosure while a message streams. It is a
     scalar with a lifetime shorter than an item's and §7.3's differential invariant is about items,
     so it is not obviously an item; `Overlay` already holds non-item state (`queue`, `banners`,
     `sessionState`) and is the natural home. Found at C6.1's grill. Closer: an
     `Overlay.thinkingEstimate` set from the frame and cleared when the message settles, so the
     renderer reads it where it reads everything else. Owner: C3, at its next corrective; until then
     the disclosure has no number.

128. **No fixture carries a `tool_use_summary` frame, so cluster labelling has no recorded
     witness.** §8.3 labels a cluster from the engine's own `tool_use_summary`
     (`summary`, `preceding_tool_use_ids`), falling back to counts and elapsed time. Across all
     twenty committed fixtures the frame appears zero times, and
     `FleetKit/Tests/FleetTimelineTests/Invariant/ProjectionEqualityTests.swift` asserts that as an
     invariant with a comment telling whoever adds one to *read* it rather than construct one.
     `WireReducerTests` constructs one by hand for the same reason. So the labelled arm of every
     cluster test — C6.1's G2 included — injects a frame it invented, and the fallback arm is the
     only one any recording exercises. Found at C6.1's grill. Closer: C1 records a scenario whose
     turn produces consecutive tool calls the engine summarises, at the next fixture re-pin; the
     tests then read it. Owner: C1 for the recording, C6.1 for adopting it.

129. **Closed 2026-09-08**, in the same change that took C3's one-fold corrective (`01eb7a7`).
     `StreamIngestion.signal(_:)` exists now, so the seam property it describes is deleted rather
     than wired: `ChannelTimelineModel.signal(_:)` calls the ingestion directly, and there is no
     longer a property that could be left unassigned. `ChannelTimelineSeamTests`'
     `testAnAnsweredDecisionLeavesPending` asserts the behaviour the seam existed to enable — a
     `DecisionItem` leaving `.pending` — instead of counting calls on a double, and it was shown
     failing against a `signal(_:)` that returns without calling the ingestion. The entry stands
     below as filed, because what it describes was true of the tree for the hours between the seam
     commit and the corrective.

     **`ChannelTimelineModel.ingestionSignal` is never set in production, so `signal(_:)` is a
     no-op in the running app.** The forwarder landed with C6.1's seam commit and is exercised by
     `ChannelTimelineSeamTests`, but the only writers of the property are those tests: nothing at
     the composition root assigns it, because the C3 corrective that gives `StreamIngestion` a
     `signal(_:)` of its own was not on `main` when the seam was written. `check-app-wiring` does
     not flag it — the check keys on a bare name and `signal(_:)` *reads* the property in
     production — so the tool's substance is unmet while its letter is satisfied, which is
     precisely the shape tracker 72 exists to catch. The consequence is worse than a missing seam:
     C6.2 and C6.3 call `signal(_:)` by a name the architect gave them, and until the property is
     assigned their calls succeed and do nothing, so a decision stays `.pending` with no error
     anywhere. Found at C6.1's review of its own seam commit. Closer: assign it at the composition
     root in the same change that lands the C3 corrective, and add a wiring assertion that the
     app — not a test — set it. Owner: the architect, at the corrective's reconciliation.

130. **Closed 2026-09-08**, by the first of the two closers it named. C3's
     `StreamIngestion.signal(_:)` performs the path rebind itself — `if case .relocated(let mainPath)
     = signal { await relocated(mainPath: mainPath) }`, at its own definition — so
     `transcriptMoved(to:)` now raises the signal and nothing else, and one move travels one route.
     `testARelocationReachesTheFold` holds it, with the idempotence clause the coordinator's
     path-on-every-update behaviour needs. The entry stands below as filed.

     **`.relocated` will reach the ingestion twice once the seam is wired.**
     `ChannelTimelineModel.transcriptMoved(to:)` calls `ingestion.relocated(mainPath:)` and then
     raises `signal(.relocated(mainPath:))`. Today the second reaches a nil seam and costs nothing.
     When `ingestionSignal` is pointed at `StreamIngestion.signal(_:)` the same move arrives by two
     routes, and whether that is idempotent is a property of the corrective, not of this side —
     C6.1's test can only pin the idempotence of its own double. Both calls are deliberate: the
     first is the path rebind the ingestion already needed, the second is the fold hearing about a
     move no frame states. Found at C6.1's review. Closer: at the corrective's landing, either make
     `StreamIngestion.signal(.relocated:)` subsume the rebind so the app raises only the signal, or
     assert the double delivery is idempotent against the real ingestion. Owner: the architect,
     with C3.

131. **Closed 2026-09-08 (`37d8f0a` on `main`): the rig's `startObserver()` returned before the
     observer's poll and reconciliation timers were parked, so a `TestClock.advance` could pass a
     timer not yet armed, and the in-place roster rewrite fires no vnode event, so the poll was
     the only re-read route. Test support only; bundle 8/8 after, 2/5 failed before. Original:**
     `LifecycleRowTests.testABackgroundJobWhoseRosterWorkerGoesArchivesTheChannel` is flaky, and
     it reddens every child's floor.** It fails with "timed out waiting for the archived outcome;
     state was backgroundJob" after the rig's 30-second guard. Measured at C6.1's Task 0 floor:
     one failure in a full `make test`, then **two passes and one failure in three isolated runs**
     of that test alone (`swift test --package-path FleetKit --filter …`). The failing run costs
     30 seconds; the passing runs take 0.03. Nothing in C6.1 can reach it — the diff touches
     `App/Timeline/` and `AppTests/`, and `FleetSessionsTests` does not import the app target — and
     it arrived with `main`'s roster-signal work, which is also what the test exercises: it waits
     for a channel to archive when its roster worker disappears, and the signal it waits on is the
     `jobUpdates` stream X5 gained at the tracker 77 corrective. A 30-second guard that trips on a
     third of runs is a race, not a slow machine. Found at C6.1 Task 0's floor. Closer: make the
     archival wait delivery-fulfilled rather than deadline-bounded, the way tracker 2's instance was
     converted; or find the roster-signal race it is reporting, which is the more likely reading
     given the shape. Owner: C4. **Any child whose floor shows exactly this one red should re-run
     before treating it as their own.**

132. **The table measures every row's height on a render, and each measurement builds a hosting
     view.** `NSTableView` with `usesAutomaticRowHeights` off asks its delegate for the height of
     *every* row when it reloads, because it needs the document's total height to size the scroller
     — not just the twenty rows on screen. `TimelineTableController.height(of:width:)` answers by
     constructing an `NSHostingView` over the row's SwiftUI body and reading its fitting size, which
     is the only honest answer while contract Y1's builder returns `AnyView`. The heights are cached
     per `ItemID` and a publish invalidates only the ids it names, so the cost is paid once per row
     rather than once per publish — but it is paid for the whole channel at the first render, and a
     channel with thousands of items therefore builds thousands of hosting views before it draws
     one. G5 opens a foreign session's real history, which is where this would first be felt. Found
     at C6.1 Task 2. Closers, in order of preference: estimate a height from the item's own shape
     and correct it when the row is first hosted, which is what a cheap row-height estimator buys;
     or measure with a single reused hosting view rather than a fresh one per row. Owner: C6.1, at
     Task 5's measurement pass, if the number turns out to matter. Round 1 (scalpel-4 #1) sharpens
     the same entry: the delegate builds and measures an `NSHostingView` on the main actor for every
     uncached row, offscreen ones included, so a cold load pays for the whole document before it
     draws a line, and the warm-up path skips item-backed rows entirely — closer unchanged, measure
     only what the viewport needs and estimate the rest.

133. **A timeline mounted without `AppModel` in the environment draws rows with no capabilities and
     says nothing.** `TimelineListView` reads `@Environment(AppModel.self)` and builds
     `TimelineRenderContext` only when it finds one; with no model the environment value is nil and
     every row draws without a link router, without contract Y4's navigation seam and without the
     channel's collapse state. That is the right behaviour for a preview or a reflection-only test,
     and the wrong one for the app, where the single host — `AfleetApp`'s `.environment(model)` —
     is three files away from the view that depends on it and `RootView` between them is closed. The
     failure mode is a row whose links quietly do nothing, which is exactly the shape tracker 129
     records for the host-signal seam. Found at C6.1 Task 2. Closer: an assertion that the mounted
     column resolves a non-nil context through a real launch, once Task 4's rows give the context a
     use worth asserting on. Owner: C6.1, at Task 4.

134. **The untrusted-text sanitiser splits emoji sequences and drops variation selectors.**
     Parity §41.7's strip set includes the default-ignorable code points, and U+200D (the zero-width
     joiner) and U+FE00–FE0F (the variation selectors) are both in it. So a family emoji renders as
     its three component glyphs and a heart with an emoji presentation selector renders in its text
     presentation. This is exactly what the engine's own sanitiser does — the terminal shows the same
     thing — so it is parity and not a regression, and the security half of the pass is what the
     entry protects. But a GUI is where a reader notices. Found at C6.1 Task 3. Closer: exempt U+200D
     between two extended-pictographic scalars and the variation selectors, which costs one lookahead
     per scalar and leaves the bidi and zero-width-space classes untouched; the divergence from the
     terminal is then in afleet's favour and is stated where the exemption is written. Owner: C6.1,
     when a reader reports it or when the row kinds land emoji-heavy content.

135. **The streaming preview keeps its highlighting across a `syntaxHighlightingDisabled` flip.**
     `TimelineTableController.preferenceChanged()` drops both caches and re-settles every row that
     carries its own source, and deliberately leaves the streaming preview alone: rebuilding it would
     reset the character count the delta path indexes the preview's text by, and replay text already
     on screen. So a message in flight when the preference flips finishes drawing highlighted, and
     the durable item that replaces it within the turn draws unhighlighted. Found at C6.1 Task 3.
     Closer: rebuild the preview row from its source *and* carry the consumed-character count across
     the rebuild, which is one field and is only worth doing once a settings change can arrive
     mid-turn (Task 5's readout). Owner: C6.1, at Task 5.

136. **Per-tool result forms stop at eleven; parity §41.16.7 tabulates about thirty.** `Read`,
     `Edit`, `Write`, `Bash`, `Grep`, `Glob`, `Agent`, `WebFetch`, `WebSearch`, `TodoWrite` and the
     `mcp__<server>__<tool>` family have the engine's own sentences; every other tool takes the
     generic `Done` / `(No output)` form, so `LSP`, `Skill`, `TaskOutput`, `TaskStop`, the worktree
     pair, `Monitor`, the cron trio, `NotebookEdit`, `memory_write`, the `claude-in-chrome` and
     `computer-use` families and the MCP resource readers all render as an unnamed result. Nothing
     is lost — the raw text is behind the disclosure — but a reader gets a count where the terminal
     gives a sentence. Found at C6.1 Task 4, and scoped out there deliberately. Closer: the parity
     table is the map; each form is a case in `ToolResultForms.completed(_:)` and a line in
     `ToolResultFormTests`. Owner: C6.1 or whoever next touches the forms.

137. **A tool row's diff is a count, not a diff.** `Edit` renders parity's `Added N lines, removed
     M lines` from `structuredPatch`, and `Write` renders its line count, but neither draws the
     patch: §41.16.8's unified renderer, the word-level diffing and the four truncations are
     unimplemented, and the structured patch reaches the disclosure only as raw text. Found at
     C6.1 Task 4. Closer: a unified-diff view over `structuredPatch` with the ANSI path's line
     numbering (the Ink path's rewind is the odd one, and §41.16.8 says so), mounted in the same
     slot the raw disclosure occupies. Owner: C6.1's successor on the rows, or C7.2 if the diff
     belongs in the panel instead.

138. **The thinking disclosure's duration is the span from the item before it, not the model's own
     thinking time.** A `thinking` block carries no start instant and the assistant item carries
     one timestamp, so "Thought for N seconds" is measured from the preceding item's instant — which
     over-reports whenever the gap holds anything but thinking (a slow tool result, a reader's
     pause before a prompt). The number is right for the ordinary streamed turn and wrong for a
     resumed or interleaved one. Found at C6.1 Task 4. Closer: the streaming path knows when the
     first thinking delta arrived; carrying that instant on `StreamingPreview` would make the span
     exact, which is the same corrective tracker 127 asks for and could land with it. Owner: C3 for
     the field, C6.1 for reading it.

139. **Closed 2026-09-09 by C6.1 Task 8, and the premise below was wrong.** A mid-session mode change
     is *not* invisible until a restart: `system/status` carries `permissionMode`, `StatusFields`
     already modelled it, and the engine populates it — across the corpus's 40 status frames exactly
     one carries a value, `acceptEdits`, in `exit-plan-mode`, the recording where a mode actually
     changes. So the header now follows status frames as the live readback and falls back to the
     handshake only for the value it opens with (`ReadbackPoller.liveMode(_:)`,
     `ChannelHeaderReadout.apply(liveMode:)`, and the precedence flag that stops the retained
     handshake folding the launch mode back over a live one on the next turn end). Asserted by
     `HeaderReadoutTests.testTheModeFollowsAStatusFrameAndNotTheRetainedHandshake`, which replays
     that recorded frame and was shown failing against the handshake-only readback first. What the
     entry got right, and what still holds, is everything it says about `get_settings`: the mode is
     not in that answer, and `effective` is the settings files rather than the process. The rest —
     the closer, the two owners, the note about the spec — is superseded; the spec's §10 was
     corrected on the same day. **What this entry does not close** is C6.2's *picker*, which reads
     the handshake through `Readback.verify` and covers the same limit with a disagreement note; the
     picker is that leaf's and is untouched here.
     The refuted text follows.

     **The header's permission-mode readback is the launch handshake's, so a mode changed inside a
     process is invisible until that process is replaced.** The child spec's §10 names `get_settings`
     as the source of model, mode and effort. The engine reports two of the three there: its answer
     is `{applied: {model, effort, advisor, ultracode}, effective, sources}` (2.1.257
     `cli.pretty.js:178217`, and both recordings that carry the subtype — `control-shapes` and
     `zero-cost`), where `effective` is the merged *settings files* and a mode read out of it would
     be what a file asks for rather than what the process runs. The readback the engine does offer is
     `InitializeResponse.current_permission_mode`, which is what `Readback.verify` compares a restart
     against and what C6.2's picker displays, so the strip reads it from `engineReports(of:)`. That
     value is *retained per process*: a `set_permission_mode` mid-session produces no new handshake,
     so the strip keeps showing the launch mode until a quiescent restart mints one. C6.2's picker
     has the same limit and covers it with a disagreement note; the strip has no note. Found at C6.1
     Task 5, where G4's clause is asserted across two replayed handshakes. Closer: the fleet's
     runtime record (`SessionRuntimeState.permissionMode`) already tracks every applied mode and is
     the honest source for a display; exposing it on `LifecycleAPI` — or having the strip read the
     `set_permission_mode` echo off its own event subscription — closes it. Owner: C6.2 for the
     display's story about a click, X5 for the accessor. The spec's §10 wants the same correction.

140. **`HeaderReadoutView` has no production mount until C6.2's header bar calls it.** C6.1 owns the
     readout and its view and C6.2 owns `App/Header/`, so the one line that mounts the strip is the
     other leaf's, exactly as the child spec's *Parent revision* has it. Until that line lands, every
     member the strip reaches — `ChannelTimelineModel.startReadbacks()` among them — is production
     code the app never runs, and `check-app-wiring` cannot say so, because the calls are all inside
     `App/`. This is the same shape as entry 129 and it is filed for the same reason: the letter of
     the check is satisfied while its substance is not. Found at C6.1 Task 5. Closer: C6.2 mounts
     `HeaderReadoutView(model:)` in its header bar, and the leaf that does it asserts the mount the
     way `ComposerMountTests` asserts the composer's. Owner: C6.2.

141. **The *Edit* target is recorded by the row, so a note the row did not cause has no message to
     sit beside.** Contract Y6 has `ComposerModel.editNote` render beside the edited message, and
     the composer records no target — its own surface is one line above the field, where "which
     message" is not a question. So `TimelineEditState` records what the row itself did, and only a
     note produced by a press on a row is drawn in the timeline. Two notes are not: the ones
     `CommandRouting` writes for `/rewind`, `/cd` and the routed settings, and any note that arrives
     after the channel subtree was rebuilt and the state reset. Both still draw above the field
     through `EditNoteSurface`, so nothing is lost to the user; what is lost is the placement.
     Found at C6.1 Task 7. Closer: the composer records the target it was given — one stored
     `promptUUID` beside `editNote` — and the row reads it instead of remembering, which also makes
     the placement survive a re-mount. Owner: C6.2, whose file the target would live in.

321. **The task card mounted on the `taskRun` row has no registry mirror, so it never offers *Move
     to background*.** §8.4 offers that action only for a running task C3's `RegistryMirror` knows,
     with a `tool_use_id` to name in the `background_tasks` request — and no mirror is reachable from
     the timeline's read model. `ChannelTimeline` carries the durable half, the overlay, the preview
     and the agent tree; the fold's mirror lives inside `StreamIngestion` and is not published, and
     the one mirror the app does hold is `ChannelEventPump.mirror`, which is Activity's and reaching
     it from a row would be the second capability path the C6 cut exists to prevent. So
     `TimelineRenderContext.makeTaskCard(_:)` builds the model over an empty `RegistryMirror()`: the
     card offers *Stop*, which reads the item's own status, and the backgrounding action is absent
     rather than wrong. The Thread tab's task card is unaffected — its host builds the model with the
     pump's mirror. Found at C6.1 Task 8, mounting contract Y2's second host. Closer: `ChannelTimeline`
     carries the mirror the fold already holds, and the context reads it where it reads the overlay.
     Owner: C3 for the field, C6.1 for the read.
     **Closed 2026-09-09 by the `corrective/c3-agent-tree-mirror` corrective on `main`, commit
     `6c964e1`.** `ChannelTimeline.registry` carries the fold's mirror as a value snapshot per publish,
     the way it carries the overlay; `TimelineNeighbourhoodCache` puts it on the neighbourhood with the
     other reads a row makes of its timeline, and `makeTaskCard` builds the model over it. Activity's
     `ChannelEventPump.mirror` is untouched, so the second capability path the C6 cut forbids was not
     opened. Left standing: entry 406.

322. **The timeline's task card takes its item by value and is rebuilt only when the task's status
     changes, so a card's text lags its `task_progress`.** `TaskCardModel` stores the `TaskRunItem`
     it was built with and replaces it only through `refresh`, which the card calls when the engine
     contradicts it. The row therefore keys the model by `taskID` and `status`
     (`TaskCardSeam.identity(of:)`): keying by the whole item would rebuild on every progress frame
     and drop a refusal banner and an in-flight request the reader is watching, and keying by the
     task alone would leave a finished run reading *Running* and offering *Stop*. What is lost in
     between is a description or summary that changes without the status changing. Found at C6.1
     Task 8. Closer: the card model takes the item as an observed input rather than a snapshot, so
     the host replaces the value and not the object. Owner: C6.3, whose model it is.
    Round 3 scalpel-1#3 restates it after wave E: the seam's identity now carries the capability but
    still not `description`/`summary`, so same-status `task_progress` updates never reach the retained
    `TaskCardModel.item`; `makeTaskCard` installs no item-update path. The closer is an update path on
    the model, not a wider identity (a rebuild drops a refusal banner and an in-flight request).

323. **Two Workbench suites carry run-to-run state and fail after a crashed test host, and one of
     them says why in its own arithmetic.** Both reddened once at C6.1 Task 8, in the run
     immediately after three test-host crashes, and both passed on the next clean run; neither is
     reachable from that task's diff, which touches no file under `Workbench/`.
     `SourceControlCoreTests.ToolRunnerTests.testAChildThatBlocksIsTimedOutAndKilled` proves the
     child was killed with `pgrep -f "sleep 31.415926"` over a **fixed** marker, so any `sleep` with
     that argument left behind by an earlier aborted run — which a crashed host leaves — matches and
     fails the assertion; the marker wants to be unique per run.
     `TerminalCoreTests.FloodTests.testMainActorStallDoesNotDuplicateOutstandingDelivery` counted
     2,097,156 bytes against 2,097,152 expected: exactly 4 more, which is `go\r\n` echoed by the
     PTY, so what it caught was terminal echo racing the child's read and not a duplicated delivery
     — and the message it prints ("one in-flight output delivery was submitted more than once")
     names a cause that was not the cause, which is the part worth fixing whatever else changes.
     Found at C6.1 Task 8. Closer: a per-run marker in the first, and `ECHO` disabled — or the echo
     accounted for — in the second. Owner: C7.3 for the runner, C7.1 for the PTY test.

## From C6.3 (`child/c6-decisions`)

Entries **157 through 171** are C6.3's, as the C6 composite's leaf table allots them, and all fifteen
are used; its merge review added 292–297, 300–319 (298–299 are C7.1's). Nothing above is renumbered —
the gap between 141 and 157 is C6.1's and C6.2's reservations and is expected. (Header re-stated
2026-09-09 after a union merge of two waves' edits left it self-contradictory.)

157. **Five deferred mounts wait on one carrier: C6.1's `TimelineRenderContext`.** Read rather than
     assumed at this child's tip: no `EnvironmentValues`, `EnvironmentKey` or `@Entry` declaration
     exists anywhere under `App/`, and `TimelineRenderContext` appears in the tree only as four
     doc-comments naming its absence. C6.1's skeleton 2 (`9d6d320`) landed `TimelineRow.item` and
     `ChannelTimelineModel.signal(_:)`; the per-row capability value lands in a later C6.1 task.
     Everything this child could not mount is downstream of that one value, and filing them
     separately would restate one closer five times:
     - a permission card's paths render as **text, not links**, because the link capability travels
       in that value and reaching `ChannelContext.links` another way would be the duplicate registry
       C5's `HostLinkRouter` exists to prevent;
     - the sent-file row's *Open in Files* (§14 item 29) is unbuilt for the same reason;
     - the decision row's actions are absent, so the row renders and does not answer;
     - `RetractionRegistry.retains(_:)` has **no production caller** and still carries its
       `check-app-wiring.py` allowlist entry naming Task 8, and `TaskCardView` is not mounted on
       C6.1's `taskRun` row — both allowlist entries were to be removed at that mount;
     - **`DecisionAnswering.raise` was assigned nowhere**, so D2's loop was complete but not closed:
       a successful `perform(.answer)` raised `HostSignal.decisionAnswered` where a test handed it
       the fold, and raised nothing in the running app, because none of the three hosts that
       construct an answering object (Activity, the Thread tab, the timeline row) owns a
       `ChannelTimelineModel` — only the channel column does. So a card's state did not leave
       `.pending` on screen. The spec never said who makes that assignment; that omission was the
       architect's, not a worker's. **Activity's clause is closed** (2026-09-09, architect's ruling,
       second review round): no render context is needed for it, because the app-scoped
       `ChannelTimelineRegistry` reaches every channel's fold, and `ActivityModel` now takes a
       `timeline` provider over that one registry which the composition root assigns. The Thread
       tab's and the timeline row's assignments remain on this entry.
     - **nothing assigns `DecisionAnswering.raise`**, so D2's loop is complete but not closed: a
       successful `perform(.answer)` raises `HostSignal.decisionAnswered` where a test hands it the
       fold, and raises nothing in the running app, because none of the three hosts that construct
       an answering object (Activity, the Thread tab, the timeline row) owns a
       `ChannelTimelineModel` — only the channel column does. So a card's state does not yet leave
       `.pending` on screen. The spec never said who makes that assignment; that omission is the
       architect's, not a worker's. **Closed for the Thread tab, 2026-09-09**, by the architect's
       ruling: the tab is handed `ChannelFold`, two closures over the app-scoped
       `ChannelTimelineRegistry`, at its `performLaunch` construction, and assigns `raise` on the
       answering object it builds — a panel tab has no row and needs no per-row carrier. **Closed for
       Activity the same day** by wave A (`ad4e854`): `ActivityModel` takes a `timeline` provider over
       the same registry. The timeline row's assignment is the one clause still open, and it is
       contract Y7's (C6.1's `TimelineRenderContext`).
     The mechanism in every case ships and is tested against a double; what is missing is the
     construction site. Found at Tasks 2, 6 and 8a, re-verified by reading at this child's tip.
     Closer: C6.1's merge lands `TimelineRenderContext` and constructs the answering object with the
     channel's model; this child's rows then read the capability where every other row reads it. If
     C6.1's merge does not make the `raise` assignment, this stays open on that clause alone.
     Owner: C6.1, at its merge.

158. **`annotations.preview` is produced by the question card's shape but never populated.** The
     card writes only `notes`. Two readings of one field name, unresolved and not resolvable from
     what is recorded: `Fixtures/ask-user-question` records an answer with **no `annotations` key at
     all** even though its chosen option carries a preview, so deriving one from the option would
     contradict the recording; and the engine's own TUI populates it only from a preview whose
     `kind` is `"full"` (2.1.263 `cli.pretty.js:518286`), a shape the tool-input schema's
     plain-string `preview` does not describe. The card therefore emits `annotations` only when it
     produced one and omits it otherwise, which is what G1b asserts — correct against both readings
     and informative under neither. Same class as the overage card's declared-but-unfed
     `balanceCents` and `currency`. Found at Task 4. Closer: a recording that actually carries
     `annotations`, or a bundle reading that reconciles the two preview shapes. Owner: C1 for the
     recording, C6.3's successor for adopting it.

159. **`ThreadModel.open(_:)` has no production caller, and `check-app-wiring.py` cannot see it.**
     Nothing inside the Thread tab opens a thread; every affordance that would is in another leaf —
     a timeline tool row (C6.1), a decision row (this child's deferred Task 8 mount, entry 157) and
     *Ask on the side* on a message (C6.2). The checker keys on the bare name `open`, which is used
     elsewhere under `App/`, so the member is invisible to it: the tool's letter is satisfied and
     its substance is not, which is the shape tracker 72 exists to catch. Recorded here rather than
     left to a name collision. Found at Task 6. Closer: C6.1's and C6.2's affordances land, and the
     decision row's actions arrive with entry 157's carrier. Owner: C6.1 and C6.2, at their merges.

160. **A pre-existing unused-binding warning outside this child's fence.** A clean
     `build-for-testing` surfaces `App/Timeline/ChannelTimelineModel.swift:352: warning: immutable
     value 'ingestion' was never used` — `transcriptMoved(to:)` binds the ingestion in its `guard`
     and then raises `signal(.relocated:)` alone, which is correct behaviour (tracker 130's closer)
     with a leftover binding. Committed code this child did not touch, and invisible to an
     incremental `make build`/`make test`, which is why it survived: this child's own runs report
     zero warnings. Verified still present at this tip by reading the source. Found at Task 6.
     Closer: drop the binding to a plain `guard ingestion != nil` or use it. Owner: whoever owns
     `App/Timeline/` — C6.1.

161. **Two load-dependent flakes in `FleetTimelineTests` redden the shared floor.** **Closed 2026-09-09
     by the `main` corrective `1402cd4`** (both waits delivery-fulfilled with a 120 s hang guard; the
     tailer test's own pre-write race fixed with it; 0 of 10 → 10 of 10 under a load average near 150).
     `IngestionTests.testTheWholeWireStreamThroughTheTapYieldsMirrorEffectsAndTheLiveHalf` failed
     once in a full-suite run (7 effects against 15, 30 entries against 53) and passes in
     isolation — 27 executed / 0 failures on a focused re-run. `TaskOutputTailerTests
     .testASecondChunksCallSurvivesTheFirstStreamsTermination` has the same shape. Both are outside
     this child's fence. This matters past tidiness: **two intermittents make a red full-suite run
     ambiguous**, so every downstream child and every merge reconciliation has to distinguish noise
     from regression by hand, which is exactly the reading a floor exists to make mechanical. Found
     at Tasks 7 and 9. Closer: make each assertion wait on delivery rather than on elapsed work, the
     way tracker 2's and tracker 131's instances were converted. Owner: C3.

162. **afleet has no new-channel path, and a Settings toggle with no consumer.** `Fleet.register`
     composes every launch as `.resume(key.session, fork: false)`; nothing under `App/` constructs
     `.new(SessionID())`. `AfleetStore.isolatedSettingsForNewChannels`
     (`App/Composition/AfleetStore.swift:49`) is written by a control in `SettingsView` and read by
     nobody. Two consequences, both concrete: root acceptance item 3 (*New channel*) has no
     implementation at all, and item 4's *Isolated settings for this channel* developer setting does
     not reach a spawn — which is why this child's live gate has to impose isolation at the
     process-factory seam rather than through the setting the parent names. Not this child's to fix;
     channel creation belongs to the shell or to the composer/header leaf. Found at Task 9. Closer:
     a `.new` composition at `Fleet.register`'s caller, with the developer setting read there.
     Owner: the architect, to assign.

163. **`claude auth status` is not a sufficient live-gate precondition, and `ScratchLiveGate` treats
     it as one.** The scratch home reports `loggedIn: true` with an `oauth_token` on `firstParty`,
     and a prompted turn still returns an API error before any tool call: the account's
     organisation has subscription access to Claude Code disabled at the policy level. The engine
     writes it as an `assistant` record carrying `isApiErrorMessage`, `apiErrorStatus`, `error` and
     `requestId`, with `stop_reason: stop_sequence`, at **zero cost**. So a signed-in home can be an
     unusable home and the gate's entry check cannot see the difference; the failure instead
     surfaces four minutes later as the surface's own assertion about a missing card, and the
     diagnosis took a transcript read because nothing in the run reported it. Found at Task 9, and
     it has already cost a second leaf (C6.2's G6). Closer: `ScratchLiveGate` additionally skips —
     loudly, naming the condition — when the first `result` of a probe run carries an error subtype
     or the first assistant record carries `isApiErrorMessage`. Owner: C5, which owns the file.

164. **`RowRegistry.shared` is process-wide and traps on a duplicate, while the suite builds many
     `AppModel`s.** An unguarded pair of `register(kind:)` calls in `AppModel.init` crashes the
     second construction, so this child's claim sits behind a MainActor-isolated
     `hasClaimedRowKinds` flag: the trap stays live for the case Y1 wrote it for (two leaves owning
     one kind) and is defeated for the case it never anticipated (one process, many models).
     **C6.1 registers eleven kinds the same way and meets this the moment its leaf merges**, so the
     guard belongs in Y1's skeleton rather than being rediscovered per leaf. Found at Task 8a.
     Closer: the skeleton either states the one-claim-per-process rule and offers the guard, or
     `RowRegistry` becomes idempotent for an identical re-registration. Owner: the architect, with
     C6.1 at its merge.

165. **The elicitation form implements a stated JSON-Schema subset, and anything outside it renders
     raw** (spec D8): object properties of string (with `enum`), number, integer, boolean and
     string-array; every other shape, a nested object included, renders as a raw JSON field and
     still answers. The boundary is deliberate, not an oversight, and is filed so that the first
     real MCP server whose schema exceeds it produces a widening rather than a bug report. No
     fixture carries an elicitation at all, so the whole card is built on invented requests. Found
     at Task 4. Closer: widen the subset when a real server's schema needs it. Owner: C6.3's
     successor.

166. **`ViewTree` reflection needs an explicit descent to reach a hosted card.** `ViewTree` reflects
     stored properties, so a host's body holds the card *value* and not its buttons, and a blind
     recursion into `body` reaches `Text`, whose `Body` is `Never`. Task 2 added a `CardTree` helper
     that descends deliberately for the card's own type. Test-instrument debt, and it extends entry
     81's finding that SwiftUI body inspection is tied to framework storage rather than to the view
     tree a user sees. Found at Task 2. Closer: fold the deliberate descent into `ViewTree` itself
     so each host does not add its own. Owner: C5, which owns the instrument.

167. **The sent-file row has no production supplier for its channel's working directory.** The row
     resolves its preview path the way `SendUserFileTool` did — tilde first, absolute as given,
     anything else against the channel's cwd — and `SentFileRowView.cwd` is the seam that carries it.
     Nothing in the running app sets it, because a row learns its channel's context from C6.1's
     `TimelineRenderContext` and that value is not on `main` (entry 157). Capturing the app's panel
     host in `RowRegistry.shared`'s builder instead was rejected: the registry is process-wide and the
     suite builds many `AppModel`s (entry 164), so the first one's host would answer for every later
     one. The consequence is bounded and stated in the row: with no cwd, a **relative** path is not
     read at all and the row says the file could not be previewed, rather than reading whatever sits
     at that path relative to the app's own directory. Absolute and `~` paths, which is what the
     recorded corpus carries, preview as normal. Found in the second review round. Closer: the same
     carrier as 157 hands the row its channel's cwd. Owner: C6.1, at its merge.

168. **No production host marks a decision card active, so no card binds Return.** `isActive` gates
     the approve shortcut (Decision Log, 2026-09-09) and every host passes the default, which is
     `false`: Activity deliberately, because a compact card in a fleet-wide list must not own the
     keyboard default action, and the timeline and Thread hosts because neither yet knows which of
     the cards it draws the user is acting on. Answering by mouse is unaffected; a one-key approve is
     absent until a host tracks focus or selection. Filed rather than answered here because the
     knowledge is the host's, not the card's. Found in the second review round. Closer: the timeline
     list marks the focused row's card active (C6.1), and the Thread tab marks the open thread's
     (C6.3's Thread half). Owner: C6.1 and the Thread host.

     **Half closed 2026-09-09 (second fix wave, architect's ruling).** The Thread tab is the first
     production host to set it: a tab draws exactly one card and the user opened it, so it owns
     Return with no list for the shortcut to reach the wrong member of. `ThreadView` passes
     `isActive: true`, asserted through the existing shortcut clause. Activity's compact list and
     the timeline's rows still pass the default, and the entry stays open for the timeline row —
     which is where a focused-row notion has to come from.

169. **Four of the five thread anchors are still snapshots.** `ThreadAnchor.decision` now resolves
     through the `DecisionItem` the channel's fold holds, so a card settled by any surface reads as
     settled in the open thread. The other four carry values taken at the moment the thread was
     opened: a tool call opened while running shows *running* for as long as the thread stays open,
     a task's status is the registry mirror's at that instant, and a sent file's delivery never
     turns from pending to delivered. The mechanism to fix each is the one the decision anchor now
     uses — the fold is reachable from the tab — but each kind is keyed differently (`ItemID` for a
     tool call and a sent file, the task id for a task) and none of the four misleads a user into
     an action the engine then rejects, which is what made the decision case worth closing now.
     Found while closing the decision anchor, 2026-09-09. Closer: the anchor holds the key rather
     than the value for every kind, and reads the fold for all five. Owner: C6.3's successor.

170. **Closed 2026-09-09** (second fix wave, architect's ruling): §6.12 gains a third answer, *Not
     now*. It dismisses the sheet, writes nothing anywhere and leaves the channel in
     `consentNeeded` — unspawned, still asking — and the column draws a banner that brings the
     sheet back, so an outstanding decision does not lose its affordance with its modal. Closing
     the sheet by its own gesture *is* *Not now*: the binding is real now, and declining stays the
     only path that writes `settings.local.json` (§6.12's one exception), reachable only by
     pressing *Decline*. `testNotNowRecordsNothingAndLeavesTheChannelWaiting` holds it on the X9
     seam — no acceptance, no decline, no lifecycle action — with the precondition re-asserted
     afterwards. The entry stands below as filed.

     **The consent sheet cannot be dismissed by the user.** `ChannelDecorations` presents §6.12's
     sheet from the verdict — `.constant(model.consentRequest)` — so the sheet's own dismissal
     gesture writes into a binding that drops it and the sheet returns. That is deliberate as far
     as it goes: consent is taken before the child exists, the sheet closes because the fleet
     stopped asking rather than because the view decided it had, and a sheet a user could wave away
     would leave the channel in a state with no affordance to get back to. But it reads as a stuck
     window rather than as a modal decision, and the design says nothing about a third answer.
     Found while binding the sheet to its evaluation, 2026-09-09. Closer: §6.12 says what dismissal
     means — *not now*, leaving the channel unspawned with a banner, is the likely answer — and the
     sheet gets a real binding. Owner: the architect, then C6.3's successor.

171. **A question answered with only a note carries an empty `answers` entry.** The question card
     now builds a response for a question the user annotated and did not otherwise answer, because
     that is the only way its annotation reaches the reply at all; `DecisionCard.echo(_:answering:)`
     then writes `answers[<the question>] = ""` beside the annotation, so the engine reads an empty
     answer where the user gave none. Nothing is lost and nothing is invented — the alternative
     spelling, an `answers` map that skips a response with no selections, lives in the mapping and
     not in the card. Found by the review wave on C6.3. Closer: `echo` omits an entry whose
     selections are empty. Owner: whoever next owns `DecisionAnswerMapping`.

296. **A form-mode elicitation whose schema is not an object draws no form and no Accept.**
     `ElicitationForm.init?` now builds a form for an object with no properties (its answer is
     `{}`), but a `requested_schema` of some other type — a bare `{"type": "string"}`, or a schema
     given as a `$ref` — still produces no form, so the card offers only *Decline* and *Cancel*.
     That is the same shape §6.4 forbids, one level up from the properties this wave fixed; it is
     left standing because no server has been seen to send one and the raw-JSON fallback for a
     whole schema is a design question, not a repair. Found by the review wave on C6.3. Closer:
     a whole-schema raw field for a form-mode request the subset cannot open. Owner: C6.3's
     successor, with entry 165.

297. **An integer control truncates a fractional entry rather than refusing it.** Typing `2.7`
     into a property of `type: "integer"` sends `2`, silently, and this wave's numeric guard did
     not change that — it only stopped the out-of-range and non-finite cases from trapping. Small,
     and the field would have to say why it refused. Found by the review wave on C6.3. Closer:
     refuse a value with a fractional part in an integer control, the way an out-of-range one is
     refused. Owner: C6.3's successor.

300. **The timeline's own card host does not share the app's reservation set yet.** The second fix
     wave gave `DecisionAnswering` an app-scoped `DecisionReservations` — one in-flight set and one
     settle announcement for every surface — and wired the two hosts that exist on this branch,
     Activity and the Thread tab, from `AppModel.decisions`. The third host is C6.1's timeline card,
     which builds its answering object inside `TimelineRenderContext` and is not on `main`. Until it
     is handed the same set, a card answered from the timeline while Activity's answer is in flight
     reopens exactly the window this wave closed: two answers on the wire and the second refused as
     `decisionGone`, and Activity's pump keeps a payload the timeline settled. Found while closing
     scalpel-1#2 and #4. Closer: C6.1's render context carries the app's `DecisionReservations` and
     passes it to the answering object it builds. Owner: C6.1, at its merge.

301. **A host registered on `DecisionReservations` cannot withdraw.** `observe(_:_:)` is keyed by the
     host's `ObjectIdentifier`, which is what stops one model re-registering twice, but there is no
     removal: `startActivity` builds a **new** `ActivityModel` on every launch that reaches a
     workspace, so the previous model's entry stays in the map for the app's life. Nothing leaks the
     model — the closure holds it weakly and a dead entry does nothing — and the bound is the number
     of relaunches in one process, which is small. Filed rather than fixed because the withdrawal
     wants an owner (a token, or `stop()`), and choosing one is a design question about who holds the
     registration. Found in the same change. Closer: `observe` returns a registration the host
     releases, or `ActivityModel.stop()` withdraws. Owner: C6.3's successor.

302. **The trust re-read fires when the pane is handed over, not when the user finishes with it.**
     `reviewTrustInTerminal` re-reads the verdict once `PanelHost.run(_:)` returns, and that is the
     handover rather than the grant: the user trusts the project in Claude Code's own dialog some
     seconds later. The second half of sweep#5 is what actually catches it — the mount re-evaluates
     when afleet comes back to the front — so the case left standing is a Terminal pane that never
     takes the front away from afleet, where the banner can stay up until the selection moves. Small,
     and no wrong write follows from it: the channel is history-only, which is the safe direction.
     Found in the second fix wave. Closer: the pane's `PaneExit` is already reported to C4; route it
     to a re-read as well. Owner: C6.3's successor, with C7.4.

303. **A card's diff is prepared once per view instance, not once per decision.** `DiffView` reads
     the other side of a change through `.task(id:)`, so a card drawn in both presentations — the
     compact card in Activity and the full card in the timeline — makes the read twice, and a view
     SwiftUI rebuilds for an unrelated reason makes it again. The line-level difference is cached by
     its two sides and does not repeat, so what is left is one bounded read per instance rather than
     one per render pass, which is the cost the fix was about. Found by the second review wave on
     C6.3 (scalpel-5#1). Closer: a preparation cache keyed by the request id, invalidated when the
     card leaves `.pending`. Owner: C6.3's successor, with C7.2's `MonacoEditorView` seam.

304. **A raw elicitation field cannot answer a schema with a string that begins like JSON.** The
     discriminator between "a string" and "a syntax error" is the opening character: text beginning
     `{`, `[` or `"` must parse, everything else is carried as a string. A server whose schema
     genuinely wants the *string* `{not json` therefore cannot be answered through the raw field.
     Nothing recorded asks for one, and the alternative — a control that says which of the two it is
     — is a design question rather than a repair. Found by the second review wave on C6.3
     (scalpel-4#3). Closer: a per-field switch between "as JSON" and "as text". Owner: C6.3's
     successor, with entries 165 and 296.

305. **A file over 16 MiB shows the tool's input instead of a diff.** `FileTextReader` reports a
     file past `defaultLimitBytes` as unreadable, because a diff of a truncated file draws the
     missing half as a deletion nobody proposed, and the card then falls back to the verbatim input
     with the line that says why. That is true but unhelpful for a legitimately large file — a
     generated bundle, a lockfile — where a diff of the changed region would be exactly what the
     user needs. Found by the second review wave on C6.3 (scalpel-5#2). Closer: an `Edit` reads a
     window around its `old_string` rather than the whole file, which needs a seek the bounded read
     already has the descriptor for. Owner: C6.3's successor, with tracker 292.

306. **The diff's line difference is computed on the main actor on a cache miss.**
     `DiffRendering.view` (`App/Decisions/DiffRendering.swift`) looks the two sides up in `DiffLineCache` and, when the digest is not
     there, computes the line-level difference inside the render pass. The read and the repeat
     computation were moved off the main actor, but the *first* one for any pair was not, and the
     algorithm is quadratic in the number of lines over a ceiling of sixteen mebibytes — a large
     `Write` or a `replace_all` therefore hitches the window once per card. It is one hitch and not
     a hang, which is why this is a note. Closer: the difference is computed in the preparing task
     beside the read, so the cache is warm before the card draws; or the renderer bounds itself by
     line count and draws a summary past it. Owner: C6.3. Filed 2026-09-09 at C6.3's third review
     round (hard stop).

307. **A completed answer clears whatever draft is in the thread, not its own.** `ThreadModel.send`
     (`App/Threads/ThreadModel.swift`) hands `perform` an `onSuccess` that clears the draft unconditionally. The answer is a round
     trip, and the thread can be re-opened on another anchor while it is in flight, so a reply the
     user has begun typing to a *newer* card is erased by an older card's success. The window is
     narrow and nothing wrong is sent — what is lost is typing. Closer: the clear names the draft
     belonging to the answer that completed, and does nothing when the thread has moved on. Owner:
     C6.3. Filed 2026-09-09 at C6.3's third review round (hard stop).

308. **A refused thread reply is discarded rather than kept.** `ThreadModel.post` (`App/Threads/ThreadModel.swift`) clears the draft
     before it calls `perform(.send)`, so a send the composer or the wire refuses takes the user's
     text with it. The decision path already holds the opposite rule — the draft is cleared by the
     answer succeeding, because the model holds the only copy of what was typed — and the reply path
     did not get it. Closer: clear on success, as the answers do. Owner: C6.3. Filed 2026-09-09 at
     C6.3's third review round (hard stop).

309. **A settled answer announces a `ChannelState` captured before the round trip.**
     `DecisionAnswering.deliver` (`App/Decisions/DecisionAnswering.swift`) reads the state, awaits the raise, and then announces the value it
     captured; the settlement observer applies it. A state that arrived while the answer was in
     flight is therefore overwritten by an older one, and the card list on screen is the one from
     before the answer. Closer: announce the state before awaiting, or let the observer apply by
     request id alone and take the state from the stream that owns it. Owner: C6.3. Filed 2026-09-09
     at C6.3's third review round (hard stop).

310. **A failed answer releases the reservation without settling the card.** `answerFailed` and
     `decisionGone` (`App/Decisions/DecisionAnswering.swift`) drop the in-flight reservation and announce nothing, so a Thread card whose
     request the engine has already closed goes back to pending and enabled — an affordance over a
     request that can never be answered, and a second press that earns the same error. The two
     failures are not the same shape as a refusal the user can retry: a consumed request is
     terminal. Closer: treat a consumed-request failure as a settlement for the card. Owner: C6.3.
     Filed 2026-09-09 at C6.3's third review round (hard stop).

311. **A settlement signalled while the timeline is opening its ingestion is dropped.**
     `ChannelTimelineModel` (`App/Timeline/ChannelTimelineModel.swift`) holds no wire until its ingestion is open, and a signal that arrives in
     that window meets a nil and is discarded — the card stays pending on screen although the answer
     succeeded, until something else invalidates it. The window is short and opens once per channel,
     which is why this is a note rather than a fix. Closer: the signal is buffered until the
     ingestion opens, or the model retains it and replays it on open. Owner: C3/C5 with C6.3. Filed
     2026-09-09 at C6.3's third review round (hard stop).

312. **A request answered before Activity ingests it stays retained.** `ChannelEventPump.forget`
     (`App/Activity/ChannelEventPump.swift`) marks a request the pump has already ingested; a Thread answer that lands first finds nothing
     to mark, and the later ingest retains the payload with no settlement against it. Bounded — one
     request's payload, released when the channel's pump goes — but it is the one bookkeeping rule
     the reservation set exists to keep. Closer: a settlement marker that survives the later ingest,
     so the order of the two events stops mattering. Owner: C6.3. Filed 2026-09-09 at C6.3's third
     review round (hard stop).

313. **A plan approval's `setMode` does not reach the supervisor's runtime permission mode.**
     `RuntimeStateUpdater` (`FleetKit/Sources/FleetSessions/Lifecycle/RuntimeState.swift`) ignores `system/status`, so the mode the engine adopts when a plan
     approval sends `setMode` is never recorded in `ChannelState.permissionMode`. The session
     behaves as the user asked; a relaunch reads the stale mode and undoes it, silently. Closer: C4
     reads the accepted mode from the answer it sent, or from the `system/status` frame that follows
     it. Owner: C4. Filed 2026-09-09 at C6.3's third review round (hard stop).

314. **The trust action throws on a channel with no process.** *Review trust in terminal* (`App/Consent/PrecommitModel.swift`) goes
     through the lifecycle's terminal handoff, which mints a `PaneRequest` from a running channel
     and throws `notOwned` when there is none — so on a history-only channel opened from its files,
     which is exactly the case §6.11's banner is drawn for, the action refuses before it reaches the
     pane. Closer: with no process to hand over, the action opens a pane on the project's directory
     directly; no handoff is involved, because there is nothing to hand off. Owner: C6.3 with C7.4.
     Filed 2026-09-09 at C6.3's third review round (hard stop).

315. **The thread's generic reply to a question card answers only the first question.** A thread
     reply (`App/Threads/ThreadModel.swift`, against `App/Decisions/QuestionCardView.swift`) builds one response from the text in the composer and files it against the first
     question, so the selections and notes the user entered on the card's own controls for the other
     questions are dropped. The card's own Answer button is correct; the thread's reply is the
     second path to the same request and does not read what the first one holds. Closer: the thread
     reply reads the question card's draft rather than composing its own. Owner: C6.3. Filed
     2026-09-09 at C6.3's third review round (hard stop).

316. **A list field eats its delimiter while it is being typed.** The elicitation form's list control
     (`App/Decisions/ElicitationForm.swift`) rebuilds its text from the parsed selections on every set, so the delimiter the user has just
     typed — the character that is about to start the next item — is parsed away before the next one
     arrives, and a list cannot be typed straight through. Closer: the control retains the text
     being edited and parses it for the value, rather than deriving the text from the value. Owner:
     C6.3. Filed 2026-09-09 at C6.3's third review round (hard stop).

317. **A root schema with `allOf` and no direct properties becomes a form that accepts `{}`.** The
     elicitation form (`App/Decisions/ElicitationForm.swift`) reads the root object's `properties`; a schema that composes its properties
     through `allOf` has none there, so the form is empty and its Accept sends an empty object as
     though the user had answered. Composition is outside the stated subset (tracker 165), and the
     rule for everything outside it is the raw editor — the root did not get it. Closer: composition
     at the root falls back to the raw editor, as an unsupported field already does. Owner: C6.3.
     Filed 2026-09-09 at C6.3's third review round (hard stop).

318. **Question and elicitation drafts are lost on a channel switch.** Both live in view `@State`
     (`App/Decisions/QuestionCardView.swift`, `App/Decisions/ElicitationCardView.swift`),
     which SwiftUI discards when the subtree goes away, so a half-filled form or a typed note is
     gone the moment the user looks at another channel and comes back. The card is still pending and
     still answerable; what is lost is typing. The same class as 307 and 308, and the same cure.
     Closer: the drafts move to the retained model, which is where the reply draft already lives.
     Owner: C6.3. Filed 2026-09-09 at C6.3's third review round (hard stop).

319. **An older read can overwrite a newer preview.** `SentFileRowView` and `DiffView`
     (`App/Decisions/SentFileRowView.swift`, `App/Decisions/DiffRendering.swift`) assign the
     result of an awaited read without checking that the source it was started for is still the one
     on screen, so two reads in flight settle in completion order rather than in request order and
     the slower, older one wins. Both are keyed by `.task(id:)`, which cancels the previous task —
     which is why this is a note and not a fix — but cancellation is cooperative and the read does
     not check it. Closer: a generation captured before the await and compared after it, the fence
     `PrecommitModel.evaluate` already takes. Owner: C6.3. Filed 2026-09-09 at C6.3's third review
     round (hard stop).
## From `main` correctives, 2026-09-08 onward (numbered from 187; 82–186 are the C6 and C7 leaves' reservations)

187. **Two of `AgentRunTree`'s three parent sources have no production caller.**
     `AgentRunTree.apply(agentMetadata:for:)` and `apply(metaFile:)` are called only from tests;
     in production the tree is built from the wire alone and only the two-step join ever answers
     the parent question. The ingestion's file-side `agentMetadata` handling is item-shaped
     (`StreamState.metadata` → `StreamProjection.metadata` → `RecordReducer`'s `taskRun` items and
     thread attachment) and never reaches a tree. Consequences: a foreign or archived channel
     opened from its files has no agent-run tree at all, so C6.4's Agents tab is empty for it; a
     live channel's tree loses the parent evidence the `agent_metadata` mirror entry and the
     `.meta.json` sidecar would give. Found by the `2dc57ba` corrective (which routed the tree to
     the app, X4 amended) and left standing on purpose. Closer: the ingestion feeds its file-side
     metadata into the reducer's tree (or a file-only tree the ingestion owns when there is no
     wire) through the two existing, tested entry points; then C6.4 reads one tree for every
     channel kind. Owner: C3, before C6.4's Agents tab is judged on foreign channels.
     **Closed 2026-09-09 by the `corrective/c3-agent-tree-mirror` corrective on `main`, commit
     `d670f3f`.** `StreamIngestion` feeds both sources: a mirror-delivered `agent_metadata` entry goes
     to `AgentRunTree.apply(agentMetadata:for:)` from `applyMirror`, and every `.meta.json` the file
     path enumerates goes to `apply(metaFile:)` from `loadMetadata` — which the open read and the
     watcher both call, so a live channel and a file-only one reach the same tree. `absorb` creates
     the node when no `task_started` has, which is what a channel with no wire needed; first-source-
     wins is unchanged and a later disagreeing source still lands in `conflicts`. Left standing: a
     node the metadata created reads `.running` (entry 407).

188. **`make test` rewrites `Workbench/Package.resolved` with the app's own dependency pins.**
     Since C6.1's seam range added HighlightKit to `project.yml` (`exactVersion: 0.2.0`), the
     app scheme's xcodebuild resolution writes HighlightKit's pin and a new `originHash` into
     `Workbench/Package.resolved` — the local package's committed lockfile, which C7.2's offline
     proof relies on — leaving the tree dirty after every floor run; C6.1 and two `main`
     correctives each reverted it by hand. Nothing is lost (the app's pin is derivable from
     `project.yml`), but a child that commits the churn by accident changes Workbench's lockfile
     for a dependency Workbench does not declare. Closer: find why the project's resolution
     targets the local package's file (xcodegen's package layout, or the package being both a
     local dependency and a workspace member) and point it at the project's own
     `xcshareddata/swiftpm/Package.resolved`; until then the floor's Makefile target restores the
     file after the run. Owner: C5 (`project.yml`), noted 2026-09-08.
     Root cause found 2026-09-09 at C7.1's merge: two tools rewrite the one file toward different
     graphs — the App floor's xcodebuild adds the app's pins (HighlightKit, swift-cmark) to
     `Workbench/Package.resolved` as part of the workspace resolution, and `swift package`/`swift test`
     under `Workbench/` prunes them again as unused by the manifest. Whichever copy is committed, the
     other tool dirties the tree. Closer: pin every Workbench dependency exactly in the manifest (most
     already are) and stop committing `Workbench/Package.resolved`, so neither tool's rewrite is a diff;
     `main` keeps the App floor's copy until then. Owner: the architect.

189. **`SourceControlCore` decodes pathnames lossily.** Both git parsers convert path bytes with
     `String(decoding:as: UTF8.self)`, which replaces invalid sequences, so a non-UTF-8 path reaches a
     panel as a path that does not exist and two distinct byte names can collapse to one key during
     the diff join. APFS enforces UTF-8 for new names, so the exposure is history and foreign
     checkouts, not the live working tree. Found by C7.3's merge panel. Closer: keep the raw bytes on
     the model beside the display string, or fail the record with a typed error. Owner: C7.7, when
     it first meets such a repository.

190. **An unborn `HEAD` and a broken `HEAD` are the same to `GitDiff`.** `resolvingAnUnbornHead`
     treats every non-zero `rev-parse --verify HEAD^{commit}` as unborn (a timed-out probe is now
     `.timedOut`, corrective on the branch), so a corrupt or dangling `HEAD` is compared against the
     empty tree and drawn as a repository whose whole tree is new. Found by C7.3's merge panel.
     Closer: distinguish exit 128 with a missing ref from a resolvable symbolic `HEAD` naming a
     missing object, and surface the latter as a repository error. Owner: C7.7.

191. **Working-tree containment is not atomic across ancestors.** `workingTreeFile` refuses `..`,
     absolute paths and `realpath` ancestors outside the root, and opens the final component with
     `O_NOFOLLOW` + `fstat`; an ancestor swapped for a symlink between the `realpath` and the open is
     still followed. The threat is a racing local writer on the user's own machine. Found by C7.3's
     merge panel, ruled out of scope twice. Closer: descriptor-relative traversal (`openat` with
     `O_NOFOLLOW` per component) from a descriptor on the root. Owner: C7.7 if the panel ever reads
     files it did not list itself.

192. **A type change from a gitlink carries no source-side kind.** `FileChange.kind` is
     destination-biased; for mode 160000 → file or symlink the caller cannot tell that the source
     side is a gitlink and that `GitDiff.blob` is invalid for it. Found by C7.3's merge panel.
     Closer: carry both modes (the raw record has them) or a `sourceKind`. Owner: C7.7 when it
     renders type changes.

193. **A truncated `HEAD` lane does not continue below a limit-truncated window.** When `HEAD` lies
     below the window (skip zero, limit reached) the working-tree row emits one truncated edge and
     reserves nothing, so the first unrelated tip takes lane 0 and no reservation carries the edge
     through the rows — against `GraphRow.Edge`'s rule that an unread target's lane continues to the
     bottom. Found by C7.3's merge panel. Closer: reserve a lane for the out-of-window `HEAD` and
     release it at the window's end, or draw the truncated edge to the row's edge. Owner: C7.7 with
     pagination (tracker 114).

194. **`IngestionTests.testTheWholeWireStreamThroughTheTapYieldsMirrorEffectsAndTheLiveHalf` gives
     up on its effects under load.** **Closed 2026-09-09 by `1402cd4`** (delivery-fulfilled waits with a
     120 s hang guard; 0 of 10 → 10 of 10 under a load average near 150; the tailer test's own
     pre-write race fixed with it). In a `make test` run with a 15-minute load average of 89 (two
     floors and a `swift test` loop in parallel), `IngestionTests` took 209 s instead of ~25 s and
     this test collected 5 of 15 mirror effects (23 of 53 duplicates) before its wait ended at
     23 s; alone it passes 5 of 5. Same class as 131, 146 and 151: a bounded wait read as a
     product failure. Closer: the collection wait becomes delivery-fulfilled (await the count, with
     a guard of a minute or more that only turns a hang into a failure) rather than a fixed window;
     and the floor's operator rule is one xcodebuild floor at a time. Owner: C3. Filed 2026-09-08
     at C7.2's merge.

195. **What the transcript records for a turn in flight at `end_session` is unprobed.** The
     §7.4 Quit ruling (corrective `b86a73a`) rests on `end_session` being a recorded teardown:
     the engine writes `task_updated {status:"killed"}` and `task_notification
     {status:"stopped"}` for its shells and the trailing `last-prompt` during shutdown (parent
     Surprises, C1's compact-boundary second reading). Whether a *turn* still streaming at that
     moment leaves an interruption record, a truncated assistant record, or nothing is not in any
     fixture. If it leaves a truncated record that `--resume` then shows, the fix belongs in
     `terminate()` itself for every terminating action (an `interrupt` before `end_session`),
     not in one caller. Closer: a zero-turn-cost probe is impossible (a turn must be running), so
     this is one prompted turn under the scratch home at C1's next re-pin, reading the transcript
     after exit. Owner: C1 (probe), C2 (`terminate()`) if it bites. Filed 2026-09-08 at the Quit
     ruling.

## From C7.1 (Terminal core), merged 2026-09-09

82. **`openpty(3)` sets `FD_CLOEXEC` on the master one call too late.** `Darwin+PTY.swift`
    opens the pty and then sets the flag, so a concurrent spawner elsewhere in the process
    that does not use `POSIX_SPAWN_CLOEXEC_DEFAULT` can inherit the master in that window.
    The window is small and nothing in afleet spawns that way today. Closer:
    `posix_openpt(O_RDWR | O_CLOEXEC)` with `grantpt`/`unlockpt`/`ptsname` instead of
    `openpty`, which never has the flag off. Found by the Task 2 independent review.
    Owner: C7.1 if a second spawner appears, else whichever child adds one.
83. **The child descriptor surveys scan fds 3 through 20 only.** The two isolation tests in
    `PTYSpawnTests.swift` enumerate a fixed range rather than the child's whole `/dev/fd`.
    A leak above 20 would pass. Closer: enumerate the directory and subtract the three
    standard descriptors. Found by the Task 2 independent review.
84. **`PTYTestChild.output(from:until:)` carries one fixed three-second marker deadline.**
    The four spawn tests sit on it while the two write tests raise their own to twenty.
    On a loaded machine the three-second cases are the first to flake, and the failure reads
    as a product defect rather than a starved test — the same shape as tracker entry 2.
    Closer: make the deadline a parameter with a generous default. Found by the Task 2
    independent review.

85. **One dispatch thread is blocked in `waitpid` for the lifetime of every live
    `PTYProcess`, plus a `DispatchSemaphore` wait on that thread per status.** libdispatch's
    per-QoS worker pool is 64. A fleet of panes — this project's premise — each holding a
    read queue, a write queue and a permanently blocked wait queue can exhaust it and stall
    unrelated dispatch work elsewhere in the app. **Decided rather than left silent, at the
    reviewer's request:** not fixed in C7.1. The realistic v1 ceiling is small (C4 caps live
    processes at six and C5's panel-session LRU holds sixteen channels), the blocking waiter
    is what makes the one-report invariant and the ordered stop/terminate delivery
    straightforward, and both were measured and tested at length; swapping the mechanism now
    would put the child's most expensive semantics back in play for a limit no v1
    configuration reaches. Closer: `DispatchSource.makeProcessSource` or a single SIGCHLD
    reaper, keeping the same serialisation — note that `makeProcessSource(.exit)` alone does
    **not** report stops, which `WUNTRACED` does and the detach path needs, so the
    replacement is not a drop-in. Owner: C7.4 if a pane count that matters appears, else the
    child that first runs many panes at once. Found by the Task 3 independent review.

86. **A full-rate flood costs the pane up to a quarter-second of input latency, and the cost
    is the renderer's, not the host's.** Measured in the S1 harness over four ten-second `yes`
    runs: run-loop heartbeat median 17.3–23.6 ms with maxima of 117–262 ms, 16–24% of 50 ms
    ticks lost, and a real `NSEvent` keystroke round-tripping in 24.9–587.1 ms. The same ten
    seconds headless through the identical PTY layer reads median 2.025 ms, max 10.115 ms,
    199/200 ticks and roughly 15x the throughput, and only 251–347 ms of the ten seconds is
    spent inside `feed` — so host delivery is not the cost and no amount of coalescing on our
    side addresses it. The window stays responsive, not smooth: a drag during a full-rate
    flood hitches. Not fixed here because the remedy is the renderer's (frame pacing, or
    dropping intermediate frames when the grid is being overwritten faster than it is drawn),
    and because a pane flooding at full rate is not the ordinary case. Closer: revisit if a
    user reports hitching, or when a `libghostty-vt` Swift renderer makes frame pacing ours.
    Owner: C7.4 if it ships pane throttling, else whoever owns the renderer swap.
87. **The S1 harness's grid claims rest on `GhosttyTerminalSurface.renderedViewportText()`,
    added so a separate module could read the grid.** It waits for pending output and returns
    `readViewportText()`, and one test pins its headless contract (`nil` with no surface
    attached, which is what keeps the harness's "it rendered" claim falsifiable). It exists
    for the spike, and C7.4 has no need of it; if the panel never adopts it, it should be
    withdrawn rather than left as public surface area nobody calls. Owner: C7.4 at its close.

88. **Harness teardown is inconsistent, and one path cannot execute.** `S1Harness`'s
    `HarnessWindow.swift:379` is `defer { Task { await child.teardown() } }` while
    `main.swift:55-57` calls `exit(status)` on the same main-actor turn, so the escalation ladder
    never runs; the `shell` leg calls `teardown()` on no path, and the attach leg's write-failure
    return skips its own. Harmless in practice — `exit()` closes the master and the kernel's
    revoke hangs up the group — but the harness is what C7.4 will read. Closer: one teardown path
    per leg, awaited before `exit`. Owner: C7.1 if the harness outlives the spike, else C7.4.
89. **`AdapterWiringTests` carries one assertion that cannot fail as named, and several that pin
    the dependency rather than this child.** The `feed`-returns-promptly assertion targets a
    blocking `feed`, which would hang the test rather than fail it, so every non-blocking
    implementation passes trivially; the `readViewportText() == nil` assertions pin libghostty's
    inertness with no surface attached, not our code. Both are cheap and honest, neither is
    evidence. Closer: express the blocking case as a timeout that reports, and label the
    dependency-pinning assertions as such. Owner: C7.1 tests.
90. **`openpty` returning a descriptor in 0, 1 or 2 would make the child close its own
    standard streams.** `Darwin+PTY.swift:106-125` opens the slave as 0, dups to 1 and 2, then
    closes the inherited master and slave by number; if the host had stdin closed and `master`
    came back as fd 0, the close would take the child's own stdout or stdin with it — a pane that
    renders nothing, with no error anywhere. Unreachable from the app and under XCTest today,
    which is why it is logged rather than fixed. Closer: refuse or `dup` any pty descriptor below
    3 before building the file actions. Owner: C7.1 if a host ever spawns with closed standard
    streams. Found by the whole-branch review.
91. **`write()` after the child exits returns two different errors depending on timing.** Before
    the read source observes EOF it surfaces `PTYError.systemCall(.write, EIO)`; afterwards,
    `PTYError.closed`. C7.4 would have to match on both to mean one thing. Closer: map `EIO` on a
    master whose child has ended to `.closed`. Owner: C7.4 when it handles pane write failures.
92. **The X1 import test proves half of what its comment claims.** Its header says "the manifest
    is one half of that boundary", but neither test parses `Package.swift`: adding a dependency to
    a target with no source-level import passes. Closer: parse the manifest's target
    dependencies, or narrow the comment to what the walk actually checks. Owner: C7.1 with the
    manifest.
93. **A host waiting on `awaitFeedCapacity()` cannot be cancelled out of the wait.** The
    continuation is resumed only when the adapter's backlog falls below the low-water mark, so a
    renderer that wedges permanently leaves the waiting host suspended with no way out; today the
    only such host is the S1 harness, whose process ends anyway. Closer: register the waiter under
    `withTaskCancellationHandler` and resume it on cancellation, the way the PTY layer's write
    gate already does. Owner: C7.4 when a pane's read loop has a lifetime of its own.
94. **Back-pressure is on the concrete adapter, not on `TerminalSurface`.** `feed` is the
    protocol's only delivery seam and returns `Void`, so `outstandingFeedByteCount` and
    `awaitFeedCapacity()` live on `GhosttyTerminalSurface`; a host that holds panes only through
    W2 has no way to stop reading a flooding child. C7.4 holds the concrete type, which is why
    this is a hand-off rather than a defect, and it is the same reasoning `themeResolution`
    already records. Closer: a one-line W2 amendment, on evidence, if a second surface or a
    protocol-only host appears. Owner: C7.4 with the parent.
95. **`renderedViewportText()` waits on the adapter's backlog by polling.** It calls the
    session's own drain barrier in a bounded loop (1,000 attempts) because the dependency offers
    no completion signal, so a diagnostic read behind a large backlog spins on the main thread
    rather than suspending. Diagnostic-only — no pane path calls it — and the bound keeps it from
    hanging. Closer: a completion callback on the adapter's drain that the read can await, or
    upstream support. Owner: C7.1 if G2's self-test leg ever reads behind a flood.

96. **The owner-release cleanup helper is called `terminateAndReap` and no longer reaps.**
    `PTYTestChild.terminateAndReap(_ identity:)` signals the child's group and then watches it
    die; the status belongs to the production waiter, which is the whole point of the review fix
    that removed its `waitpid`. The sibling overload taking a `PTYProcess` has always had the
    same shape and the same name. A reader who trusts the name will think a status is claimed
    here. Closer: rename both to say what they do — `terminate(_:)` — in one mechanical pass over
    the nine call sites. Owner: C7.1 tests, or whoever next touches the helper.
298. **The adapter learns that the renderer has a surface by polling a viewport read.** The
    backlog is held until the session is attached, because the dependency drops unattached output
    past 1 MiB, but `libghostty-spm` publishes no attachment event and keeps `currentSurface`
    internal, so `GhosttyTerminalSurface` probes `readViewportText() != nil` every 10 ms while it
    has something undelivered and no surface. Cheap (an unattached read returns immediately) and
    latched after the first attach, so it costs one poll cycle of first-paint latency and nothing
    afterwards. Closer: an attachment callback upstream, or `currentSurface` made public, either
    of which turns the poll into a wait. Owner: C7.1 if the dependency is bumped, else C7.4.
292. **A `replace_all` edit draws the whole file as a diff.** The card shows the change the tool
     would make, and for `replace_all` the occurrences can be anywhere, so `DiffSource.prepare`
     hands the renderer the file and the file with every occurrence replaced (Decision Log,
     2026-09-09). `AttributedDiffRenderer` draws every line it is given, including unchanged ones, so
     a `replace_all` over a large file draws a large view — the same shape the `Write` arm has had
     since Task 3 and the reason this is a note rather than a regression. Nothing is wrong on screen;
     it is a cost, and it is the renderer's to answer, not the source's. Closer: the renderer emits
     hunks — runs of change with a few lines of context and an elision between them — which also
     improves every long `Write`. Owner: whoever replaces the drawing, C7.2's Monaco conformer being
     the likely one. Filed 2026-09-09 at C6.3's second review round.

320. **`LateMountMetadataTests.testALateComposerSeedsTheReportsTheStreamWillNotRepeat` fails under a
     full floor and passes alone.** Seen once at C6.3's final stitch floor ("the composer read back no
     system/init", 0.136 s) and 3 of 3 green alone at 5/5 each; the suite's files were untouched by the
     branch. Same class as 131/146/151/194: a seeding path whose order a busy host can change. Closer:
     the seeding test waits for delivery of the retained report rather than reading once. Owner: C6.2.
     Filed 2026-09-09 at C6.3's merge.

## From C7.5 (Files panel, `child/c7-files-panel`)

232. **Every leaf builds its own git and temporary-tree fixtures.** `FilesPanelTests/Support`
     rebuilds a scratch-tree guard, a repository builder and a recording runner that
     `SourceControlCoreTests/Support` already has, because test sources cannot be imported across
     targets and neither belongs in a shipping module. Two copies of a guard is two places for it
     to be wrong. Closer: a `WorkbenchTestSupport` library target the test targets depend on, or
     the guard promoted into a module that ships. Owner: whichever of C7.4, C7.6 or C7.7 writes
     the third copy.

233. **Both sides of a diff are decoded as UTF-8 with replacement.** `DiffPairResolver` hands
     Monaco strings, so a byte sequence that is not UTF-8 becomes U+FFFD and a save from that
     buffer would not round-trip. Deliberate — refusing to show a diff of a file with one bad byte
     is worse for the user — and the diff editor is read-only, so nothing writes it back today.
     This is the contents half of entry 189, which is about path bytes. Closer: carry the raw
     bytes beside the string and refuse the *editor* (not the diff) for a file that does not
     round-trip. Owner: C7.7 when it renders diffs of arbitrary history.

234. **`ToolRunning` cannot write to a `git` child's stdin.** `ToolJob` opens every child's
     descriptor 0 on `/dev/null` and `run` has no stdin parameter, so any verb whose batch form is
     `--stdin` is unavailable: C7.5's gitignore batch had to be respelled
     `check-ignore --verbose --non-matching` and read by position (child spec Design §3). The
     failure shape is the dangerous one — `--stdin` reads EOF and reports *nothing*, exit 0. Closer:
     an optional `stdin: Data` on `ToolRunning.run` written and closed before the read loop.
     Owner: C7.3's module, whichever leaf needs the second such verb.

235. **What a `FileSnapshot` still costs, now that it is bounded.** *Closed in part at C7.5's fix
     wave.* `FileSnapshot.read` now `stat(2)`s first and reads the contents only when the size or
     the modification time moved, so a quiet poll tick over an open file is one `stat` and no
     digest; and the read is bounded by `FileKind.maximumReadableBytes`, so a file above the panel's
     cap has no snapshot rather than a 64 MiB one. What remains: (a) the shortcut cannot see a write
     that keeps both the size and the modification time — a swap of the same number of bytes with
     the time put back is a change no watcher on this file system observes for free, and the panel
     will show the old buffer until something else moves; (b) a *real* change to a file just under
     the cap is still a whole read and a SHA-256 on the main-actor opening path, so opening a 60 MiB
     text file still blocks a frame. Closers: for (a), nothing short of a content check, so it is a
     documented limit rather than a bug; for (b), read and digest off the main actor, or digest a
     bounded prefix plus the size. Owner: C7.5's own follow-up, or the first leaf that opens a large
     file and notices.

236. **The Files tree does not follow the working tree.** §9.1's watcher sentence is about open
     files, so a file the agent creates or deletes appears only on expansion, on *Refresh*, or
     after a save. A user watching an agent scaffold a directory sees nothing move. Ruled out of
     scope at this leaf's gate (Parent revision 3) rather than forgotten. Closer: one FSEvents
     stream over the channel's cwd, coalesced, with the `node_modules` class of directory
     excluded. Owner: a v1.1 Files follow-up.

237. **A tab's link targets accumulate for the life of the tab.** `LinkRouterCapability` withdraws
     by `PanelTabID`, so a panel cannot retract one channel's registration without retracting every
     channel's. C7.5 registers a `.file` and a `.diff` target per channel and makes them hold the
     session **weakly**, so a session the host evicted leaves an inert pair that stops claiming and
     lets the router take W5's fallback — correct, but the registrations themselves stay on the
     router until the tab is unregistered. A user who visits three thousand channels leaves six
     thousand dead targets, each consulted on every `open`. Closer: a per-registration withdrawal
     token on `LinkRouterCapability`, which is an X7 change no gate needed here. Owner: C7.6 and
     C7.7 register per channel too; the first one that measures the resolution cost.

238. **Nothing in X7 tells a panel session it is being released.** `PanelTabSession` has no
     teardown member and `PanelHostModel` releases a session by dropping the reference — under LRU
     pressure, on `unregister`, and when a channel leaves the index. C7.5 answers it with a `deinit`
     that spawns a flush of whatever its store still holds pending, which covers the persisted
     document but cannot call a main-actor method: an edit recorded in the session and not yet
     handed to the store is still lost, and watchers are stopped only because they were made inert
     when released rather than because anything asked them to stop. Every later panel with a
     process, a socket or a buffer behind it has the same gap and a worse consequence. Closer:
     `func willRelease() async` on `PanelTabSession`, awaited by the host before it drops the slot.
     Owner: C5's fence, raised by C7.5; C7.4's panes are the case that will force it.

239. **An atomic save carries the file's mode and nothing else.** Writing a temporary and
     `rename`ing it installs a fresh inode, so the destination's owner, group and any ACL entries
     are replaced by the saving process's. The mode is carried because losing it has a visible
     consequence (an executable script stops being executable); ownership and ACLs are not, and on
     a shared checkout a save can quietly drop a collaborator's access or an explicit deny. Found by
     C7.5's merge panel, ruled out of scope: a faithful replace needs `copyfile(3)` with
     `COPYFILE_ACL | COPYFILE_XATTR` onto the temporary, or an exchange primitive. Closer: that
     call, once someone edits a file whose ACL matters. Owner: C7.5's follow-up.

240. **`LinkRouterCapability.open` does not say which channel the link came from.** Every channel's
     Files session registers a `.file` and a `.diff` target with the same tab and specificity, and
     `LinkRouter.mostSpecific` compares specificity and tab order — never channel identity. So the
     registry alone cannot deliver a link to the session it came from. C5 recorded the same gap in
     `HostLinkRouter` ("`LinkRouterCapability.open(_:from:)` carrying the channel would remove the
     case altogether, and that is an X7 amendment"); C7.5 mitigates it by registering **once per
     tab** and routing to the channel the panel is presenting, which is right for a click the user
     just made and wrong for a link delivered to a channel that is not on screen. Closer: the X7
     amendment of C7.5's Parent revision 4 — the capability carries the originating `ChannelKey`
     and `LinkTarget` may match on it. Owner: C5's fence; C7.6 and C7.7 register per channel too.

241. **Re-baselining the editor after a save can overwrite a keystroke.** W4's vocabulary is closed
     and `readBuffer` deliberately leaves the dirty flag alone, so the only way to tell Monaco "this
     is the saved state now" is `setText` — which replaces the buffer. A character typed between the
     `saveRequested` that captured the text and the `setText` that acknowledges it is lost. The
     alternative is worse and is why the trade was made: without the acknowledgement the editor stays
     dirty in its own eyes, `reportDirty` fires only on a transition, and every subsequent edit is
     invisible to the host — including to the watcher's refresh, which would replace them all. Found
     by C7.5's second merge round. Closer: a `setBaseline` message on the bridge that resets
     `savedVersionId` without touching the model, which is a W4 amendment. Owner: C7.2's contract,
     whichever leaf next opens it.

242. **A panel session cannot capture its buffer when its view unmounts.** `dismantleNSView` detaches
     the surface, and the only way to obtain the text is a `save` round trip through a web view that
     is already going away. So text typed and never stashed by a switch, a toggle or a diff is lost
     on a bare remount. Everything a *user action* triggers stashes first; this is the path with no
     action in it. Found by C7.5's second merge round. Closer: a `dirty` event carrying the text, or
     a periodic stash while a buffer is dirty. Owner: C7.5's follow-up.

243. **Cmd+S resolves the main window's channel, not the focused one.** *Closed at C7.5's fix
     wave D: the pop-out scene publishes its identity as a focused scene value, and the Save item
     resolves both its target and its enablement against the key window through it.*
     `AppModel.filesSaveTarget` read `PanelHostModel.selectedChannel` and `selected`, which
     describe the main window; `PoppedOutPanelScene` keeps its own channel and does not update
     them. With a Files pop-out
     focused, the menu item's enabled state and its action both speak about the main window's
     channel. The pop-out's own *Save* button is unaffected. Found by C7.5's second merge round.
     Closer: the host tracking which scene is key, which is C5's fence. Owner: C5.

244. **The save's containment check and its temporary creation are two moments.** The config-home
     refusal resolves the destination and then `atomicallyWrite` creates a temporary by pathname; an
     ancestor directory swapped for a symlink in between redirects the temporary into the protected
     directory, and the pre-rename revalidation checks contents rather than containment. The threat
     is a racing local writer on the user's own machine — the class C7.3 ruled out of scope twice as
     entry 191. Found by C7.5's second merge round. Closer: descriptor-relative creation (`openat`
     from a descriptor on the validated parent). Owner: whichever leaf makes 191 worth closing.

245. **The suppressed clean report is keyed on a path, not on a surface.** When the session replaces
     a buffer it records the path whose `dirty:false` it caused, so the bridge's own clean report
     does not drop an unsaved marker the user still owns. The record is retired only by a real
     `dirty:true`. That is exact for `bridge.js` as written — `reportDirty` fires on transitions, so
     a clean report can only follow a dirty one — but it is an assumption about another module's
     behaviour rather than something this session enforces, and with several surfaces attached there
     is no per-surface accounting. Found by C7.5's fix wave for the second merge round. Closer:
     either the bridge tagging a host-caused transition, which is a W4 shape change, or per-surface
     expectations here. Owner: C7.5's follow-up, or C7.2's contract if the bridge answers it.

246. **`FilesPanelTests` builds fixtures that duplicate no other target, and is now the leaf's
     largest suite.** 149 of the package's 383 tests live in one target with a private git fixture
     builder, a scratch-tree guard and a recording runner (entry 232's duplication), plus real PDFs,
     PNGs and MP4 containers generated per test. Nothing is wrong with it; it is slow enough
     (~15 s of the package's ~33 s) that the next leaf to add to it should know where the time goes
     before adding more. Closer: share the fixtures per entry 232 and build the media corpus once
     per suite rather than once per test. Owner: C7.7, which will add to this target.

336. **A presentation can wait out the stash bound before it draws.** A file switch over a dirty
     buffer is a `save` round trip, and a second switch arriving while the first is outstanding now
     waits for the same answer rather than racing it — correct, and up to `stashTimeout` (two
     seconds) of a panel that has not redrawn, with nothing on screen saying why. Found by C7.5's
     fix wave A for the third merge round. Closer: a pending marker on the tab the presentation is
     heading for, which is a view change; or a shorter bound, which trades a slow editor's captures
     for responsiveness. Owner: C7.7, which draws the tab strip.

337. **Two windows can hold two different unsaved buffers, and only one of them can win.** The
     session holds one text per open file, so ownership follows the surface that last reported the
     file dirty. If the user genuinely types in both windows, the second `dirty` report takes
     ownership and the first window's edits are overwritten by the `setText` that follows the next
     save. Fixing the *cursor* half of this (entry: fix wave A) removed the case where a window
     that typed nothing could take the buffer; the divergent case remains and cannot be closed
     without a per-surface buffer or a bridge command that reads a buffer without saving it. Found
     by C7.5's fix wave A. Closer: a `readBuffer` in W4 that answers per surface, which is an
     amendment to C7.2's contract. Owner: C7.2's contract, whichever leaf next opens it.

338. **A retired buffer request is kept until an editor answers it, and the queue is capped by a
     number.** `saveRequested` carries no request id, so replies are correlated positionally: an
     expired request stays in the queue so its late answer can be recognised as belonging to a
     request that is over. An editor that never answers therefore accumulates entries, and the cap
     that stops that is 32 — a number chosen because an editor silent across that many requests is
     not going to answer any of them, not because anything measured it. Found by C7.5's fix wave A.
     Closer: a request id on the wire, which is the W4 amendment entry 241 also wants. Owner:
     C7.2's contract.

339. **The one-read fix for the buffer and its baseline has no failing test of its own.** The
     window it closes is an atomic replacement landing between two reads of one path, which cannot
     be driven deterministically without a test-only injection seam in the read path — judged worse
     than the bug it would prove. What is tested is the new API's contract: the snapshot and the
     bytes it was taken from are the same bytes. Found by C7.5's fix wave A. Closer: a seam in
     `FileSnapshot` that a test can suspend, if a second such race ever needs proving. Owner:
     whichever leaf next needs to test a file-system race.
341. **A watched symbolic link polls for the life of the watch, and its source can sit on a stale
     inode.** `FileWatch` now keeps the stat poll armed beside the vnode source whenever the path is
     a link, because `open(2)` follows it and the source therefore watches the target's inode —
     which a retarget or a removal of the link never touches. Two costs follow. The poll is the only
     thing carrying such a path, so a change is observed at the poll interval rather than
     immediately; and after a retarget the source stays armed on the *previous* target's inode,
     holding an `O_EVTONLY` descriptor on a file nothing is interested in until the watch ends.
     Neither is wrong — the poll delivers, and the descriptor is released with the watch. Closer:
     re-arm from the tick when a symlinked path's observation moves, which needs the source's
     current inode to compare against. Owner: C7.5's follow-up. Found by C7.5's fix wave B.

342. **`FileTree`'s listing cache is keyed by the exact `URL` value a caller passed.** A URL from
     `contentsOfDirectory` carries a trailing slash for a directory and may resolve `/tmp` to
     `/private/tmp`, so a hand-built `root.appending(path: "src")` is a *different* key from the
     `src` node's own `url`. Every caller today walks by node — the column, and `refreshAll` over
     the cache's own keys — so nothing is currently wrong; a future caller that constructs a URL
     for `refresh(_:)` or `children(of:)` would silently enumerate a second time or refresh
     nothing. Closer: normalise on the way into `loaded`. Owner: whichever leaf next adds a caller
     that names a directory rather than walking to it. Found by C7.5's fix wave B.

361. **The whole-path symlink question answers "no" for the system's own `/var` and `/tmp`
     aliases.** `FileWatch` decides whether to keep the poll armed by asking whether resolving the
     path changes it, and `resolvingSymlinksInPath` normalises those two prefixes away — so a file
     whose *only* symlinked ancestor is one of them is left to the vnode source alone. Nobody
     retargets `/var`, and the alternative (an `lstat(2)` per component) puts a stat loop under
     every watch on a file in the temporary directory, which is where every test tree and a fair
     number of scratch files live. Closer: ask per component and exempt the aliases by name, if a
     case ever appears that needs it. Owner: C7.5's follow-up. Found by C7.5's fix wave D.

362. **The channel a `.newWindow` delivery lands in is carried by one slot, so two such links in
     flight at once can cross.** `PanelHostModel.lastPopOut` records the pop-out the router just
     prepared and the Files tab resolves its channel from it, which is what stops a delivery from
     following a window that has moved on. Two `.newWindow` opens overlapping — two Cmd-clicks
     before the first delivery lands — leave the second's pop-out in that slot for both, and the
     first file opens in the second's channel. The real closer is entry 240's X7 amendment: the
     capability carrying the originating `ChannelKey` makes the delivery name its own channel and
     the slot disappear. Owner: X7's amendment, whichever leaf opens it. Found by C7.5's fix wave D.

343. **Two presentations dispatched concurrently cannot be ordered by intent.** The presentation
     generation says which call claimed the surface last, and a call that has been dispatched but
     has not run yet has claimed nothing — so a suspension taken *before* a presentation (opening a
     file arms its watcher first) is checked against the last generation that actually reached the
     surface rather than against a ticket. That answers the question that matters, but it is a
     weaker order than intent: two calls that suspend before drawing can still resolve in either
     order, and a watcher refresh landing in the same window is indistinguishable from a user
     action. Closer: a single serialised presentation queue on the session, so intent order is
     entry order — worth doing when a second panel needs the same shape. Owner: C7.5's follow-up.
     Found by C7.5's fix wave C.

344. **A stash's late answer is exempt from generation retirement by argument, not by
     construction.** Every other request kind is retired when its presentation is superseded; a
     stash is not, because its answer is a capture that a *newer* presentation may itself be
     waiting on, and retiring it would leave that waiter to time out. What makes the exemption safe
     is that a capture records only what the editor holds for a named buffer, checked against the
     path and the buffer's revision. That is a proof about the operation rather than a restriction
     on it, so a future capture that did more than record text would silently lose the guarantee.
     Closer: a request id on the wire (entries 241, 338) would let a stash be retired without
     stranding its observers. Owner: C7.2's contract.

345. **`BufferState` fences the fields that were being mutated out of turn, and only those.** The
     text, the baselines, the dirty flag, the owner and the cursor cannot be assigned from the
     session; `hasConflict`, `keepsMine`, `isMissing`, `kind` and the markdown toggle still can,
     because no defect has involved them. The boundary is therefore a judgment about where the
     defects were, not a principle, and a new field of genuine buffer state added to `OpenFile`
     rather than to `BufferState` would sit outside the fence without anything saying so. Closer:
     move the remaining per-file flags behind operations too, once one of them earns it. Owner:
     C7.5's follow-up, or C7.7 if it adds per-file state.

366. **A file that grows past the cap keeps its old contents and is reported deleted.**
     `FileWatch.evaluate` has one nil outcome: `FileSnapshot.readWithContents` answering nothing
     becomes `.deleted`. But that read refuses a file *above the cap* exactly as it refuses one
     that is gone, so a clean file the agent appends past `FileKind.maximumReadableBytes` reaches
     the session as a deletion — the panel marks it missing and leaves the editor holding the
     contents from before the growth, which are now neither the file nor a baseline anything can
     be compared against. Closer: a distinct `.oversized` outcome that refreshes the file into the
     unsupported preview, which is what opening it fresh would do. File: `FileWatch.swift`.
     Owner: C7.5. Filed 2026-09-09 at C7.5's third review round (hard stop).

367. **The MPEG signature mask rejects AAC's own ADTS header.** `FileKind.signature(of:)` tests
     `bytes[1] & 0xE6 == 0xE2` for MPEG audio, and an ADTS frame begins `0xFF 0xF1` or `0xFF 0xF9`
     — both of which mask to `0xE0`, not `0xE2`. So a `.aac` file passes the extension claim, is
     put to the container veto, fails it and is drawn as opaque bytes rather than by the media
     viewer. Nothing else in `mediaExtensions` is affected: the other AAC spellings carry an
     `ftyp` box. Closer: a separate ADTS test beside the MPEG one, sync word plus layer bits, since
     the two families do not share a mask. File: `FileKind.swift`. Owner: C7.5.
     Filed 2026-09-09 at C7.5's third review round (hard stop).

368. **A package cannot be a Quick Look file, because `FileKind.of` asks `stat(2)` first.** The
     size guard is `regularFileSize(url)`, which answers `nil` for a directory, so the function
     returns `.binary` before the extension is ever consulted — and `.rtfd`, the one entry in
     `quickLookExtensions` that is a *bundle*, is unreachable from a tree row or a link even though
     Quick Look draws it. The order is otherwise right: the cap has to come before the whole-file
     read. Closer: package detection ahead of the regular-file guard, keyed on the extension and
     the directory bit together, so only the bundle kinds take the branch. File: `FileKind.swift`.
     Owner: C7.5. Filed 2026-09-09 at C7.5's third review round (hard stop).

369. **The vnode source watches the file's inode, so a renamed ancestor is unobserved.** `open(2)`
     resolves the whole path, and the source is armed on what it opened: renaming a regular parent
     directory and putting a different directory at the old pathname leaves the watch reporting the
     file the user is no longer looking at, and every change at the path on screen is invisible.
     Entry 341 covers the symbolic-link half, which polls; this is the plain-directory half, which
     does not, because the path resolves to itself and nothing arms the poll. Closer: watch the
     path's ancestors, or keep a poll that compares the path's current inode with the watched one
     and re-arms when they disagree. File: `FileWatch.swift`. Owner: C7.5.
     Filed 2026-09-09 at C7.5's third review round (hard stop).

370. **Two `.newWindow` preparations in flight can deliver one window's file into the other's
     session.** `PanelHostModel.lastPopOut` is a single slot, so overlapping A and B pop-out
     preparations leave B's window in it for both deliveries and A's file opens in B's channel —
     where the next save writes it. This is entry 362 seen from the delivery side rather than the
     channel side: same slot, same crossing, and the same closer, which is entry 240's X7
     amendment carrying the originating `ChannelKey` on the delivery so the slot disappears.
     File: `PanelHostModel` (C5) with `FilesTab.swift` as the consumer. Owner: C5/C7.2.
     Filed 2026-09-09 at C7.5's third review round (hard stop).

371. **A `.newWindow` delivery whose pop-out closed first opens the file in a hidden session.**
     The delivery resolves its channel from the prepared pop-out, and when that window has gone by
     the time the link lands the resolution falls back to the main window's selection — so the file
     opens in a session no window is drawing, and the user sees nothing happen. A fallback is right
     for a link that never named a window; it is wrong for one that named a window which is gone.
     Closer: refuse the delivery outright when the prepared window is no longer there, which is the
     same shape as fix wave D's "with a host, a lookup that answers nothing opens nothing".
     File: `FilesTab.swift`. Owner: C7.5. Filed 2026-09-09 at C7.5's third review round (hard stop).

372. **Cmd+S from a window that is not a Files scene saves the main window's buffer.**
     `FilesSaveButton` reads the focused-scene value and treats its *absence* as "this is the main
     window", because the main scene publishes nothing — so the shortcut fires from Settings, or
     from any scene that sets no value, and writes whichever file the main window's Files tab has
     selected. Entry 243 closed the pop-out half of this; the absent case is the other half.
     Closer: the main scene publishes its own identity, and absence disables *Save* rather than
     defaulting to a window. File: the app's Files commands. Owner: C7.5.
     Filed 2026-09-09 at C7.5's third review round (hard stop).

373. **`isDirty` hashes the whole buffer on every evaluation, on the main actor.** Dirtiness is
     derived from the disk baseline (fix wave C), so a *clean* text buffer takes a SHA-256 over
     `Data(text.utf8)` each time it is asked — and it is asked by the readout, by `save`, by the
     watcher's policy and by every presentation, for a buffer of up to the 64 MiB cap, on the actor
     that draws. Correct and unmeasured: nothing in the suite is large enough to show it. Closer:
     cache the digest per revision on `BufferState`, since every mutation of the text already goes
     through operations that could invalidate it. File: `FilesPanelSession.swift`. Owner: C7.5.
     Filed 2026-09-09 at C7.5's third review round (hard stop).

374. **A session that only ever showed a diff never disposes its two diff models.** `bufferPath`
     is set by `open` alone, and `leaveDiffPane` refuses to send `gotoLine` without one — so a
     channel whose Files tab was reached by a `.diff` link and dismissed with *Close diff* sends
     nothing at all, and Monaco keeps both sides of the pair allocated until some later editor
     activity replaces them. Harmless for a small pair and not for two large ones. Closer:
     `leaveDiffPane` disposes regardless, which needs a command that is safe before the first
     `open` — the guard exists because `gotoLine` is an `error` then. File:
     `FilesPanelSession.swift`, with C7.2's vocabulary. Owner: C7.5.
     Filed 2026-09-09 at C7.5's third review round (hard stop).

## From C7.6 (`child/c7-browser-panel`)

Reserved range 247–261.

247. **M1's `waitForWriteAttempts` and `waitForSleep` seams carry no deadline.** They are
     continuation-shaped: a condition that never holds is a wait that never returns. That cost this
     leaf a 900-second suite kill at M4, when a mutation stopped the model committing edits at all
     and the coalescing test waited for a window that was never going to open. M4 added
     deadline-bearing twins (`expectWriteAttempts`, `expectSleep`, fulfilled through
     `XCTestExpectation` with the suite's 20-second deadline) and used them everywhere, but M1's own
     tests still use the continuation form, so the trap is closed for new tests and open for old
     ones. Closer: convert M1's remaining call sites to the twins and delete the continuation
     seams, so the deadline-free shape cannot be reached at all. Owner: C7.6 at closeout, or the
     next leaf that touches `BrowserTabStoreTests`. Filed 2026-09-09 at the R2 fix wave.

248. **No native affordance for opening a page-originated non-web scheme.** D38 refuses every
     non-web scheme that arrives from inside a rendered page — by link, form, subframe, redirect or
     script — because WebKit's navigation type authenticates no user gesture. R2 recommended
     requiring an explicit native action instead; refusing outright is the safe end of that
     recommendation, and it is what shipped. What is missing is the other end: a user who genuinely
     clicked a `mailto:` on a page has no way to act on it, and the refusal is diagnostic-only, so
     they are not even told. This is usability, not correctness — the URL bar remains a working
     path, and nothing about the affordance is required for the security property to hold. Closer:
     a panel-local row or context-menu item ("Open in the default application") that carries the
     refused URL and is actuated by a real `NSEvent`, which is the same unforgeable authority the
     URL bar has. Owner: C7.6 at M6 if the app wiring makes it cheap, otherwise C7.7. Filed
     2026-09-09 at the R2 fix wave.

249. **`AfleetSettings` and `NotificationPreferences` still decode through the synthesised
     `Decodable`.** Q15 found the trap on `DeveloperSettings` — a new non-optional field makes every
     document an earlier build wrote fail to decode, and `AfleetSettingsStore.read` answers a decode
     failure with the defaults, so the whole settings document silently reverts. M6 closed it there
     with a hand-written `init(from:)` using `decodeIfPresent` for every field. The other two types
     in the same document have the identical shape and the identical exposure: the next field added
     to either resets the user's settings on first launch of the new build, silently. Not fixed
     here, by the architect's ruling at this leaf's gate ("if the shape recurs elsewhere in
     `AfleetSettings`, it is filed, not fixed"). Closer: the same hand-written initialiser on both,
     or one shared decoding helper, plus a test per type that decodes a document written before its
     newest field. A stronger closer, if the next owner wants one: make
     `AfleetSettingsStore.read` distinguish "absent" from "unreadable" so a decode failure is
     reported rather than answered with defaults. Owner: C5's fence — the next child that adds a
     settings field. Filed 2026-09-09 at C7.6's M6.

250. **A popup opened without a target frame loses the original request's method and body, and
     WebKit's supplied configuration.** `BrowserWebTab`'s `createWebViewWith` answers a
     `window.open` or a `target="_blank"` by asking the model for a new panel tab and loading
     `URLRequest(url:)` built from the action's URL alone (Q11), so a `POST` becomes a `GET` with no
     body, and the `WKWebViewConfiguration` WebKit hands the delegate — which carries the opener
     relationship — is dropped in favour of the panel's own. Real, and out of scope on purpose: this
     panel exists for a dev server, a documentation page and a pull request, and a `window.open`
     carrying a POST body is not among them. Nothing here is a security hole; the loss is fidelity
     on a shape the panel does not aim at. Closer: return a web view built from the supplied
     configuration and let WebKit perform the navigation itself, which means the model can hand back
     a `BrowserWebTab` built around a configuration it did not make — a change to
     `BrowserWebViewFactory`'s one-way ownership. Owner: C7.6 at closeout if a page needs it,
     otherwise the next leaf that touches `BrowserWebTab`. Filed 2026-09-09 at the R3/R4 fix wave.

251. **A second main window would have two Browser panels claiming the same `WKWebView`, and one of
     them would lose its page with nothing to say about it.** `AfleetApp` retains one `AppModel`
     outside its `WindowGroup` and does not disable additional main windows, and `PanelColumnView`
     passes `.panel` as the surface for every instance it draws. `PanelSurface.panel` carries no
     window identity — wave C gave that to `poppedOutWindow(tab:channel:)` because a pop-out is a
     window and needs one — so two main windows are one surface to `BrowserModel`: both would render
     the same web views, an `NSView` has one superview, and the window that lost them would keep
     drawing an ordinary Browser panel rather than the "Showing in the main window" placeholder that
     exists for exactly this. Real, and **currently unreachable**: with one main window there is one
     `.panel` and the identity is not needed. The treatment is known and is the one wave C already
     applied to pop-outs — give the main surface its window's identity too, so `liveSurfaces` and
     the "elsewhere" state work per window. It is not filed as this leaf's because **whether afleet
     permits a second main window at all is C5's design question**, not the Browser panel's: the
     answer decides between extending the identity and disabling the command, and a leaf must not
     pick. Owner: C5. Filed 2026-09-09 at the R5 fix wave (wave D).

252. **A quit that is abandoned after the panel drain leaves the Browser silently not persisting.**
     Wave E's `BrowserModel.closeForQuit()` sets a one-way barrier and then drains, which is what
     makes the drain the last word (D62). The barrier is never cleared, so if anything were to stop
     the termination *after* `QuitGuard` reached the drain, the Browser panel would keep working —
     tabs open, pages load — and quietly write nothing, with no row saying so. Unreachable today:
     `QuitGuard.quit()` takes every decision that can decline before it drains, and returns `true`
     unconditionally afterwards, so nothing in this tree abandons a quit past that point. It becomes
     reachable the moment a second termination guard, an `applicationShouldTerminate` that can
     answer `.terminateCancel` later, or a "quit was interrupted" path is added. Closers, in
     ascending cost: clear the barrier if the quit is abandoned (one call, and the caller has to
     know); or make the closed state visible as a panel-local row, which is the honest version and
     is §10's shape. Owner: whoever adds a path that can abandon a quit after the drain — C5's
     lifecycle, most likely. Filed 2026-09-09 at the R5 fix wave (wave E).

253. **`BrowserPanelView` registers two main-panel lifetimes under one `.panel` key.** SwiftUI keys
     the Browser subtree by (tab, channel), so a channel switch constructs the replacement before
     it destroys the outgoing one, and both register as `.panel` — the same key, with nothing to
     tell the two apart. In that order the outgoing view's `onDisappear` removes the *replacement's*
     registration, so a live pop-out is handed ownership of the pages and the replacement has no
     later appearance in which to consume `panelLeftHoldingPages` and take them back. The user's
     "Bring them back here" is undone for the rest of the session, which is exactly the defect D63
     closed for the ordering it was written against. File:
     `Workbench/Sources/BrowserPanel/BrowserPanelView.swift`. Closer: a per-lifetime registration
     token, so a disappearance can only remove the registration it made. Owner: C7.6.
     Filed 2026-09-09 at C7.6's merge round (hard stop).

254. **`navigationGeneration` does not advance for history or in-page navigation.** It counts what
     the user did to the *tab set* — a tab opened, selected, closed, or a URL submitted — so a page
     the user reached by Back, Forward, or by clicking a link inside the page leaves it where it
     was. A pull-request lookup made before any of those and resolving after them therefore reads
     its generation unchanged, concludes nothing overtook it, and replaces the page the user is
     now on rather than opening its own tab: D61's rule, applied to a clock that did not tick.
     File: `Workbench/Sources/BrowserPanel/BrowserModel.swift`. Closer: bump the generation on
     every committed navigation — `settled` already runs for each one — which makes "the current
     tab still means what the click meant" the whole of what the counter says. Owner: C7.6.
     Filed 2026-09-09 at C7.6's merge round (hard stop).

255. **The pull-request handler checks supersession only on the resolved branch.** `.resolved`
     carries the generation the request was made at into `deliver`, which is D61 working; `.failed`
     carries nothing. So a lookup the user has long since navigated past can still publish its
     error row through `reportLinkError` and, at `.currentPanel`, reselect the Browser tab over a
     newer navigation — a row about a link the user has moved on from, on top of a page they
     just chose. File: `Workbench/Sources/BrowserPanel/BrowserLinkTargets.swift`. Closer: read
     `made` on the failure branch too, and drop the row and the selection when it has moved.
     Owner: C7.6. Filed 2026-09-09 at C7.6's merge round (hard stop).

324. **The child spec's §8 says the corpus folds four `isMeta` records; it folds three.** G2's
     hidden-record clause scans every committed fixture through `RecordReducer` and counts the
     records the durable projection actually hides: `compact-boundary` one,
     `session-mirror-relocation` one, `session-mirror-resume` one — three, not the four §8 states
     (which reads "`session-mirror-resume` 2"). The wire half is as stated: one `isSynthetic`, in
     `compact-boundary` alone, and no other fixture carries one. Nothing is wrong in the app — the
     obligation is that a hidden record is never a row, and it is not — but a number in the spec that
     no fold produces is a floor a future gate could be written against and fail on correct
     behaviour. Found at C6.1 Task 6, by the gate's first run; the gate now pins three and says
     where the number came from. Closer: §8's sentence corrected to three at the next spec revision.
     Owner: the leaf owner, with the Outcomes.

325. **`StreamIngestion.agents` is never nil after `open`, so "a channel opened from its files has
     no tree" is false as written.** §9 and tracker 187 both say the agent-run tree is *nil* for a
     file-opened channel — every archived channel and every foreign session — and the C6.1 rows are
     designed around it. `StreamIngestion.open` builds the `WireReducer` unconditionally, before the
     tap starts, and `agents` reads `wire?.agents`, so what such a channel has is a **non-nil tree
     holding no runs**. The behaviour every consumer depends on is unchanged — no node, no run id,
     no navigation — and G5 measured exactly that live (0 runs). What is wrong is the predicate: a
     caller writing `agents == nil` to mean "this channel has no tree" is testing something that is
     never true, and would go on to build a navigable chip. Found at C6.1 Task 6, by G5's first live
     run, which failed on the nil assertion. Closer: the two documents say "resolves no run" rather
     than "nil", or `agents` answers nil while the fold has seen no wire event. Owner: C3 for the
     property, the leaf owner for the sentence.

326. **A row's button cannot be pressed by the test harness once it is inside a `RowFrame`.**
     `ViewTree.press` recovers a `Button`'s action by reflection, and `RowFrame` stores its content
     as a `@ViewBuilder @MainActor () -> Body` closure, which reflection cannot enter; the row also
     reads its capabilities from `@Environment`, which a body evaluated outside a render pass does
     not carry. So every row this leaf ships whose affordance is inside a `RowFrame` — the agent
     chip, the cluster disclosure, the thinking disclosure — is asserted through the content its
     action reads and the capability it calls, and not through a synthesised press. The decision row
     avoids this by splitting `DecisionRowContent`, which takes the context as a parameter; the
     chip and the two disclosures have no such split. Found at C6.1 Task 6, writing G2's chip
     clause. Closer: the same split for the three rows, so a test constructs the body over a context
     it supplies; or a harness that hosts the row in a real window and clicks it. Owner: C6.1.

327. **G5's chip arm has no subject in the scratch config home.** The gate asserts that a channel
     opened from its files renders an `Agent` chip and does not navigate, and the assertion is
     structurally sound — it iterates the history's `Agent` calls and counts the navigable ones —
     but the session the scratch home offers holds two rows and no `Agent` call at all, so the loop
     runs zero times and the clause is carried by the tree assertion beside it (0 runs resolved).
     The treeless arm is therefore witnessed at the tree, not at a chip. Found at C6.1 Task 6, from
     the gate's own printed counts (agent chips 0). Closer: the scratch home holds a recorded
     session whose history contains an `Agent` call, which is a fixture-corpus job rather than a
     code one. Owner: C1 for the recording, C6.1 for adopting it.

330. **A settled block picks up its highlight on the next render of it, and nothing schedules one.**
     C6.1's markdown cache now notices that a cold highlight has landed and rebuilds the block over
     the styled code, so the *next* render of a fenced block is highlighted. What no longer holds a
     stale block is the cache; what still can is the screen. A row already visible when the fill
     lands is redrawn only when the controller reloads it — which a streaming channel does within a
     frame and a quiet one may not do at all, so a fenced block in the last message of an idle
     channel can stay unhighlighted until the reader scrolls it out and back. Found at C6.1's fix
     wave, verifying the cache fix against what a reader sees. Closer: the highlighter tells the
     table which keys filled and the table reloads the rows holding them, which is a change in
     `TimelineTableController` and belongs with whoever owns the reload path. Owner: C6.1.

331. **The controller's own `settle` callers keep the streaming boundary rule for text that has
     stopped arriving.** `MarkdownBody` — the path every durable message row draws through — now
     finalises, so a completed message ending in `**Done**` is parsed in full. The two callers in
     `TimelineTableController` that re-settle a source-backed row, the preference flip's rebuild and
     `setRows`, still call `settle`, so a row carrying its own source can keep an unparsed tail. No
     channel row is affected — an item row carries no source of its own — but the S7 corpus path
     does, and a corpus document ending mid-block renders its own delimiters. Found at C6.1's fix
     wave, deciding which callers `finalise` replaces. Closer: those two call sites finalise, which
     is correct for both — neither is drawing text that is still arriving, and the streaming preview
     beside them is the one caller that must keep the boundary rule. Owner: C6.1, in the file that
     owns the controller.
332. **A decision card on a channel afleet does not own still offers its answers.** Round 1's
     scalpel-3 #2 closed the task card's *Stop* by gating `TimelineRenderContext.makeTaskCard` on
     C5's listing policy; `makeAnswering` is not gated the same way, so a `pending` decision item on
     a read-only or foreign channel would draw answerable buttons whose `LifecycleAction.answer`
     X5 refuses as `notOwned`. It is filed rather than fixed because no surface can currently reach
     it: a pending decision enters the overlay through this app's *own* control channel, and a
     channel afleet does not own has none — an item read out of a foreign transcript settles as
     answered or, under D12, `.inert`. Found at C6.1's round-1 fix wave. Closer: the same
     `isOwned` gate on `makeAnswering`, taken together with whatever C6.3 concludes about a decision
     item's state on a channel with no live overlay. Owner: C6.1 with C6.3.
328. **A hosted row's asynchronous growth is implemented but witnessed only at its synchronous
     entry.** `TimelineRowHostView` forwards SwiftUI's `invalidateIntrinsicContentSize` to a
     deferred re-measure, which is what a card mounting its content a run loop after the row was
     built relies on; the test drives the same re-measure through `update(root:context:)`, which is
     synchronous and deterministic. So the *path* is asserted and the *trigger* is not: a SwiftUI
     release that stops raising that invalidation would leave asynchronously grown rows clipped
     with every gate green. Found at C6.1's review fix wave, writing the height-invalidation test.
     Closer: a row whose content grows on its own after a mount, asserted after a bounded wait on
     the height the table allocates — which needs a hosted window and a row that changes size for a
     reason the test controls. Owner: C6.1.

329. **A row's height is measured two ways, and the two can disagree by a point.** An unmounted row
     is measured by the controller — a throwaway hosting view over a width-pinned root, or the
     TextKit path for the two rows that are not items (tracker 132) — while a mounted row reports
     its own `fittingSize` through its host. They agree to within a point in everything measured
     here, and the reporting side wins because it is the height actually drawn, but the first mount
     of a row can therefore note one height change that changes nothing a reader sees. Found at
     C6.1's review fix wave. Closer: one measurement path, which means measuring through the row's
     own host and having no second one — reachable only once every row is mounted before it is
     measured, which a virtualised table does not do. Owner: C6.1.

**Merge review, confirming round (2026-09-09): entries 333–335 and 375–379 file what the round found
and the architect left standing.** The round's other twelve findings were fixed by waves D–G before
the merge; one (asynchronous highlighting never redrawing the row) is already 330.

333. **The anchor's transfer from the preview to its durable item needs the preview gone and a new
    key appended in one publish, and two ordinary sequences deny it.** The reducer clears the
    preview per assistant block, so the next `content_block_start` can reopen one before the item is
    published; and `ItemBuilder.addAssistant` merges a matching `message.id` into an existing item,
    so no key is new. Either way the bottom-pinned viewport keeps its old row and the reader sees a
    jump. The fix reconciles anchors by message identity instead of by key novelty
    (`TimelineTableController`, the anchor transfer). Round 2 scalpel-1#2.
    Round 3 scalpel-1#2 adds the case where *another* preview is present: successive nil-ID previews
    share `preview:streaming`, so the held anchor resolves to the new preview below the completed
    block and an unpinned reader is moved past it. Same fix.

334. **A changed task's cached height is dropped, and the fresh measurement can be the card's
    placeholder, not the card.** `applyItems` removes the height; `height(of:)` measures a fresh host
    whose `TaskCardSeam.card` is nil until its task runs, while the retained on-screen card keeps its
    identity and `remeasure` suppresses an unchanged full height already `reported`. The smaller
    fallback can stay cached and clip the card. The fix re-reports a mounted host's height after any
    invalidation of its key. Round 2 scalpel-1#3.

335. **Every hosting view the table has ever created is retained until its key leaves the history.**
    `pruneHosts` removes keys absent from the items, never rows that left the viewport; each
    neighbourhood change then updates and synchronously remeasures every retained host. Memory and
    per-publish work grow with the rows a reader has visited, which on a long session undoes the
    virtualisation the table exists for. A viewport-exit eviction with a small keep-alive margin is
    the fix; the S7 measurement should be repeated against it. Round 2 scalpel-2#1 (and the sweep).

375. **Task controls are offered on the mode, not on a live owned process.** `ChannelRow
    .offersOwnedActions` is `mode == .ownedCandidate`, and the context always carries the workspace
    lifecycle, so an archived or foreign-live owned-candidate transcript can build a running task
    card that offers *Stop*; the supervisor then rejects the action as `notOwned`, so nothing is
    stopped — the control is a dead button, not a wrong one. Gate on the channel's readiness being
    `.owned` as well. Round 2 scalpel-3#3.

376. **The syntax-highlighting preference is a process-wide flag.** Each controller's `apply` writes
    `CodeHighlighter.shared.enabled`; `MarkdownBody` renders through the singleton without reading
    its own context's preference, and `MarkdownText` caches by source alone. Two channels whose
    `get_settings` readbacks disagree can render, and cache, each other's styling while their
    controllers interleave. Carry the preference on the render context into the pipeline and key
    the cache by it. Round 2 scalpel-4#1.

377. **The streaming split's fence test is a parity count of lines beginning with three backticks.**
    Tilde fences, indented fences and fences of unequal length are not recognised, so a preview can
    settle inside an open block and the text after it is parsed as markdown (`**literal**` becomes
    emphasis) and frozen that way. `finalise` at completion does not revisit it. Match the opening
    delimiter (character and length, per CommonMark) when deciding whether a fence is open. Round 2
    scalpel-4#2.

378. **A permission-mode status reported before the timeline's first subscription is lost.**
    `ChannelSupervisor.events` is a future-only stream; `Fleet.engineReports` retains the handshake
    and `system/init` but not the latest status, and `SettingsReadback` takes the mode from the
    handshake alone. The header shows the launch mode until the next change, which on a quiet channel
    is never. The retained latest status belongs beside the handshake in X5's `EngineReports` (C4's
    surface); the timeline then reads it at subscription. Round 2 scalpel-5#3; owner C4/X5, reader
    here.

379. **A settings readback and the handshake it is paired with are fetched without an epoch.**
    `ReadbackPoller.settings` awaits `send` and then `engineReports` as two operations; a restart
    between them pairs the old process's settings with the replacement's handshake, and
    `refreshReadbacks` publishes the pair unchecked. Have `engineReports` carry the epoch and drop a
    pair whose halves disagree. Round 2 scalpel-5#4.
    Round 3 scalpel-5#3 and 5#5 widen this: the opening `refreshReadbacks` of a re-subscription does
    not reconcile the retained epoch (wave G reconciles only on later events), so a replacement whose
    handshake preceded the re-subscription and then stays idle keeps the old mode; and
    `refreshReadbacks` checks eligibility before its awaits and publishes without revalidating the
    process afterwards. Both close with the epoch on `EngineReports`.

**Residue of waves D–G (2026-09-09), filed by the architect at the stitch: 380–383.**

380. **A link's label is flattened through `plain()`.** Wave D made Strong and Emphasis recurse into
    their children, so `**[guide](…)**` keeps its destination; the label of a link is still built by
    `plain(link)`, so `[**bold** guide](…)` keeps the destination and loses the emphasis inside the
    label. Route `Markdown.Link` through `inline` and lay the link attributes over the child runs.
    Round 2 scalpel-4#5's remaining half.
    Round 3 sweep#3: the `Heading` branch is `plain(heading)` with a font attribute too, so a link
    inside a heading is unclickable. Same fix, same place.

381. **`pruneHosts` and `refreshHostedRoots` still walk the whole row list per publish.** Wave F took
    the concatenation out of every per-row reader (10,005 cached height queries on a 2,001-row table
    with a preview: 7,141 ms before, 11 ms after), but a publish still builds `Set(rows.map(\.key))`
    and, when the context changed, a dictionary of the same size. Removing that wants a maintained
    key→index map on the controller, which needs one assignment point for `itemRows`. Per-publish,
    not per-query, so it is bounded by the publish rate.
    Round 3 scalpel-2#2: before its unchanged-return, `applyItems` builds every `RenderedRow`, maps
    both key arrays and compares the historical items, so a preview-only publish still does
    history-sized main-thread work. The same maintained index closes it.

382. **`ChannelTimelineModel.rows` and `items` re-merge and re-sort both halves of the timeline on
    every body evaluation.** The neighbourhood no longer pays this (wave F's cache), but the row
    list the table diffs against still does, so a preview-only publish sorts the whole history
    before the diff sees it. The same key the neighbourhood cache uses (the published timeline with
    its preview cleared) would serve.

383. **`testAContextChangeReachesMountedRows` passes vacuously.** `InventedItems.context` builds a
    fresh `TimelineEditState`, `RetractionRegistry` and `DecisionReservations` per call, so the
    identity half of `differs` reports a change whatever the cwd does; the test would pass with
    `cwd` removed from the comparison. Wave E's capability test pins all three (the pattern to copy).

**Final review round (2026-09-09, round 3, the hard stop): 394–397.** Eighteen P2, none P1; two §12
gaps fixed by wave H (a file link's display string and the agent chip's title/headline were drawn
unsanitised), ten already filed above (322, 330, 333–335, 376–381, extended where the round widened
them), four new below. Numbers 384–393 are C7.4's; C6.1 continues from 394.

394. **`TaskCardView` can keep the model it was first given after the replacement arrives.** On a status
    change the row assigns the new identity to the view while still supplying the old `card`; the
    `.task` then replaces `card` without the identity changing again, so the child's
    `@State(initialValue:)` retains the first model. With `makeTaskCard`'s empty registry it can go on
    showing *Running* and *Stop* after completion (the action fails as `notOwned`/not-running, a dead
    button). Key the view's identity by the card's own identity (`ObjectIdentifier`) rather than by
    the item. Round 3 scalpel-3#1.

395. **The streaming split treats the last blank line as a container boundary.** `consumeClosedBlocks`
    settles at a blank line, so an ordered list whose items arrive across appends is parsed as two
    lists each starting at 1, and a continuation paragraph loses its list context; the durable
    `MarkdownBody` reparses the whole source and is right, the settled preview rows are not. Keep a
    list open across a single blank line when the next non-blank line continues it. Round 3
    scalpel-4#3 (377 is the same split's fence rule).

396. **A channel subscribed while connecting gets no readbacks until its first turn ends.** The
    opening `refreshReadbacks` runs at once; a request sent before the process is running is refused
    (or, if X5's connecting queue holds it, answered late — to be verified against `ProcessHandle
    .send(_:uuid:)`), `observed(epoch:)` is false for the first epoch so the handshake triggers no
    retry, and the live task blocks `adopt(.ready)` from opening another subscription. Retry the
    opening readback on the handshake. Round 3 scalpel-5#1.

397. **The reopen trigger is lost while the old subscription drains.** Archival finishes the stream,
    but buffered events or an awaited refresh keep `readbackTask` non-nil while the channel reopens;
    `beginReadbacks` rejects the trigger, and when the drain ends the task only clears itself without
    rechecking a live channel, so readbacks stop for good on that channel. The existing test masks it
    by calling `startReadbacks` repeatedly. Re-check liveness when the task ends. First corrective
    after the merge (C6 recomposition). Round 3 scalpel-5#4.

## From C7.4 (Terminal panel and jobs, `child/c7-terminal-panel`)

Reserved ranges 262–276, 346–355 and 384–393. Filed 2026-09-09 at C7.4's close-out and after its
four whole-branch review rounds.

262. **A cancelled `awaitFeedCapacity()` waiter can leave one identifier behind.** The
    cancellation handler and the normal return race at the end of a wait: `forgetWaiter` can clear
    the record just before the racing `onCancel` inserts it, leaving one `UUID` in
    `cancelledWaiters` for the life of the surface. Harmless — identifiers are minted per call, so a
    stale entry can never refuse a future waiter — and bounded by the number of waits cancelled at
    exactly that instant. Closer: have the cancellation path record only while the wait is
    registered, or clear the set when the queue drains. Owner: C7.4, or C7.1 if the adapter's
    waiter is reworked.
263. **`FloodTests.testMainActorStallDoesNotDuplicateOutstandingDelivery` fails under full-suite
    load.** Seen once during C7.4's T1 with 2097156 bytes against 2097152 — four bytes, the shape of
    the pty echoing the test's own `"go\n"` release write. It touches no surface code, passed alone
    three times and passed in both later full runs. Closer: subtract the release write's echo, or
    send it down a path the child does not echo. Owner: C7.1's file.
264. **`.failed`'s synthetic 127 is indistinguishable from a child that really exited 127.** The
    panel reports `PaneSpawn.unexecutableExitCode` when a spawn never executed, because C4 is
    waiting on the request's id and a hatch whose pane never started would otherwise leave its
    channel released for ever (child spec Design §2). A child that exits 127 on its own is reported
    identically. Accepted: X5's re-adoption keys on the event, not the number. Closer: a reason
    field on `PaneExit`, which is X5's shape and a parent revision. Owner: C7.4 with the architect.
265. **`PersistedPane.cwd` records where a shell pane was spawned, never where it is.** W6 asks for
    cwd overrides and a pane opened at an explicit directory restores there, but a shell the user
    `cd`s in restores where it started. Closer: OSC 7, or reading the child's cwd from the kernel;
    neither exists below the pane today. Owner: C7.4.
266. **A restored or restarted shell pane keeps nothing but its directory.** No scrollback, no shell
    history reuse, and the pane bar labels panes by purpose alone, so two shell panes in one channel
    are indistinguishable and cannot be reordered. Deliberate for v1 — the composite defers "split
    panes and pane layouts beyond a stack" — and recorded so the next leaf does not read the
    minimal bar as finished. Closer: a per-pane title from the child's own reporting, and a
    scrollback the restore can replay. Owner: C7.4.
267. **`PaneReadout` carries a hand-written signal-name table.** A signalled child is named
    (`SIGKILL`) rather than numbered (137), which is the point, but the mapping is a switch in the
    panel rather than `strsignal(3)`. A signal the table does not know falls back to its number.
    Closer: `strsignal`, with the table kept only for the names it renders differently. Owner: C7.4.
268. **The view claim is unwitnessed against a real second window.** `PaneSurfaceHost` re-registers
    a claimant on every remount, and correctness rests on identity-checked withdrawal rather than on
    ordering, which is right — but every assertion about it is model-level. A real pop-out has never
    been driven. Closer: the human leg in G4.3, or a UI test that opens the second window. Owner:
    C7.4's human gate.
269. **The Background job row now carries four link buttons.** *Adopt*, *Attach*, *Logs* and *Stop*
    sit in one sidebar row with no layout work; §9.5 asks for the verbs and not for a menu, but the
    row is getting wide. Closer: a menu, or icons with help text. Owner: C5's sidebar with C7.4.
270. **A job pane refused for want of a channel reads as a generic failure.** The sidebar's banner
    for a row that can name no channel does not distinguish that case from any other lifecycle
    refusal; only the trust banner's `noChannelContext` sentence says what actually happened.
    Closer: one sentence per refusal in the sidebar, the way `PrecommitModel` already does. Owner:
    C7.4.
271. **Exit reports leave through an unstructured `Task`, so nothing can await one.**
    `TerminalPanelSession.report` hands each `PaneExit` to a detached task; no caller and no test can
    await delivery, so "exactly one exit" is only assertable by polling until the count agrees with
    itself. Without that quiescence loop C7.4's double-report mutation would have passed, which is
    the shape of a test that cannot fail. Production consequence is small — C4 is an actor and the
    per-pane identity guard preserves ordering — but the seam is untestable by construction. Closer:
    an awaitable report, or a session-level barrier the tests can use. Owner: C7.4.
272. **The close path's reported exit code depends on a race with the read loop.** `close()` tears
    the child down, cancels the loop, then reads `pane.state`: whether the loop observed the
    termination first decides between the child's real status and the synthetic `128 + SIGHUP`. Both
    are true statements about an instant, and X5 keys on the event rather than the number, so this is
    recorded rather than fixed. Closer: read the termination the pty layer observed rather than the
    pane's rendered state. Owner: C7.4.
273. **`PanelRig.shellPath` and `LaunchFixtures.environment` each hardcode the same shell.** One of
    the two should read the other; today a change to either leaves the pair disagreeing and only a
    shell-pane test would notice. Closer: the rig reads the fixture. Owner: C7.4's test support.
274. **`ChannelHeaderActionsModel.explanation(of:)` says a channel "was not handed off".** By the
    time `handOff()` reaches the host, X5 has already released the channel — the pane simply never
    opened. The inaccuracy predates C7.4 and now appears in two refusal arms rather than one.
    Closer: say what did not happen, which is that no pane opened. Owner: C6.2's file.
275. **`AfleetStoreKeys.window` is declared in `App/` and read nowhere in `App/`.** Found while
    C7.4's live leg was tripping `check-app-wiring.py`: the check keys on bare names, so a
    test-local identifier named `window` had been masking it. Either it is unwired window-state
    persistence or it is dead. Closer: wire it or delete it. Owner: C5.
276. **`check-app-wiring.py` keys on bare member names.** An unrelated test-local identifier can
    surface or mask a finding about a declaration it has nothing to do with; entry 275 is a concrete
    instance. The script's own docstring already concedes the limitation. Closer: key on the
    declaring type as the X7 drift checker learned to. Owner: C5's tool.
346. **A pane the user never looks at cannot report its child's exit while its renderer is full.**
    The pane consumes output and termination through one event loop and waits on
    `awaitFeedCapacity()` between deliveries. An unattached surface holds its backlog until a
    surface attaches (C7.1 tracker 298), so once 1 MiB is outstanding the loop stops and cannot
    reach `.ended`, even though `PTYProcess` has already observed the child's status. For a hatch
    whose pane is never rendered — the request names a channel the window is not showing — the exit
    report, and with it X5's re-adoption, waits for the tab to be opened or the pane to be closed.
    Not fixed here because every cheap fix is wrong: a deadline on the wait defeats C7.1's
    "nothing is dropped" backpressure, and the honest fix needs a seam the adapter does not expose.
    Closer: publish attachment on `GhosttyTerminalSurface`, or give the pane a termination observer
    independent of the output stream. Owner: C7.4 with C7.1.
347. **A channel removed from the index leaves its Terminal session holding live children.**
    `TerminalSessionRegistry` retains a session while it has panes, which is what keeps a pane alive
    across the host's LRU eviction; but `FleetCoordinator.release` and the host's `releaseChannel`
    tell the registry nothing, so a channel that leaves the index keeps its panes and their children
    for the life of the process. C7.4 closed the workspace-reset half inside its own fence; this
    half needs a host seam the leaf was not authorised to add. Closer: a channel-release callback
    from `PanelHostModel.releaseChannel` into the registry. Owner: C7.4 with C5.
348. **A workspace rebind during a pane handoff discharges through the wrong lifecycle.** The
    header awaits its *original* `lifecycle.openInTerminal()`, but its pane-runner closure holds the
    host, and `bindWorkspace` replaces that host's lifecycle and contexts. A delivery that lands
    after the rebind reports — or discharges — through the replacement, and the original
    supervisor's `pendingHatch` is never cleared. Not fixed, because the rebind that causes it
    discards that supervisor's whole fleet in the same act: nothing observable outlives it today.
    The reasoning is what makes this safe, so it is recorded rather than trusted to memory — a
    future rebind that reused a fleet would make it a live defect. Closer: carry the lifecycle the
    request was minted by, or refuse a delivery whose world has moved. Owner: C7.4 with C5.
349. **A pane request delivered across a workspace release cannot be recognised as stale.**
    `TerminalPaneRunner.run` hops to the main actor holding a `ChannelContext`; a release can
    intervene before the session is made. The registry's staleness check compares the identity of
    the context's `store`, but `ScopedStore` is not class-bound and the production
    `WorkbenchScopedStore` is a struct, so the check answers "same world" rather than answering
    falsely — it stands *behind* `bindWorkspace`'s release, not in front of it. Closer: a
    first-class world token on `ChannelContext`, which is a `PanelHostAPI` change and a parent
    revision. Owner: C7.4 with C5.
350. **The composer's Escape and Shift+Tab reach the window while a terminal pane has focus.**
    `ComposerShortcutBar` stays mounted beside the panel and binds both keys unconditionally, and
    the renderer's `performKeyEquivalent` returns false for ordinary non-Command keys it has not
    bound — so Escape in a pane can interrupt a turn instead of reaching the child, and Shift+Tab
    can cycle permission mode instead of completing. It makes a full-screen TUI in a pane
    (`claude --resume`, an editor) misbehave in a way that reads as the pane being broken. Not fixed
    in C7.4: the shortcut bar is C6.2's, and suppressing it needs a focus signal that crosses the
    two children. Closer: the composer's shortcuts stand down while the panel holds first
    responder. Owner: C6.2 with C7.4; escalated to the architect at C7.4's merge.
351. **`continueStopped()` signals a process-group number it read across an actor hop.** The pane
    re-checks its own state and its pty before signalling (round three's fix), but not the pty
    layer's ownership gate, which closes before the reap; the pane learns of `.ended` later, through
    the output stream. A stopped child that exits inside that window could see the signal land on a
    reused group number. Narrow — it needs a stop, an exit and a pid reuse inside one hop — and
    §7.8's rule is what makes it worth recording anyway. Closer: a resume that the pty layer
    performs under its own ownership gate, rather than a number handed out to a caller. Owner:
    C7.4 with C7.1.
352. **A persistence write can outlive the session that scheduled it.** `schedulePersist` captures
    the store, the document and the preceding task without retaining the session, and an *empty*
    session loses the registry's strong retention, so host eviction can discard it while a write is
    still pending. A replacement session waits on the released flag, which ordinary eviction never
    sets, so a restore can read in front of the old session's last write. Bounded — the document is
    small, the window is one actor hop, and both sessions write the same channel's own key — but it
    is a two-writer path W6's per-tab key was meant to end. Closer: a per-key write barrier the
    registry owns rather than one chained inside a session. Owner: C7.4.
353. **A job pane for an unvisited channel depends on the caller seeding the host's context.** The
    ruled seam has the caller name the channel and the host resolve it, and the host can only
    resolve a channel it has rendered or been told a cwd for. C7.4's sidebar path supplies the cwd
    it knows, so *Attach* and *Logs* work for a job whose channel the window has never shown; a
    caller that cannot name a cwd still refuses. Recorded because the dependency is not obvious
    from the seam's shape and the next caller will meet it. Closer: `run(_:for:)` taking the cwd, or
    the host resolving a channel through the fleet's own row. Owner: C7.4 with C5.
354. **Quit does not know a Terminal pane is running.** `QuitGuard.forApp` is built from the fleet
    and the composers; `FleetQuitTermination.quitChannels` filters to owned channels, and a shell
    pane has no fleet entry at all. So §7.4's Quit asks about turns and background tasks and says
    nothing about a pane with a live child, app termination closes the pty descriptors without
    awaiting any pane teardown, and the alert's own advice — that *Open in terminal* is how you keep
    a conversation — is wrong for the pane it hands you to. No state is corrupted (a relaunch
    re-evaluates every channel from the registry) and the children are afleet's own, so §7.8 is not
    breached; what is missing is the warning. Closer: the quit guard asks the session registry
    whether any pane holds a live child, and the sentence names it. Owner: C6.2's `QuitGuard` with
    C7.4; escalated to the architect at C7.4's merge.
355. **Retired at the architect's ruling of 2026-09-09**, which gave C7.4 the range 384–393. It
    had carried four unrelated residues under one number because the range had run out; each now
    has its own, and its first clause was decided rather than filed. See 384 (closed), 385, 386
    and 387.

384. **Closed 2026-09-09 by the architect's ruling, in C7.4's merge-prep pass.** *Attach* and
    *Logs* from a Background row used to start a pane in a channel the window was not showing: the
    host selects the Terminal tab, but the panel column derives its channel from `shell.focus`, so
    nothing brought that channel into view, and item 15's "*Attach* shows its screen" was not what
    happened. Ruled: a row action acts on that row's channel, so it brings it into view — the
    sidebar selects the channel, then the host selects the tab, then the request runs. A witness
    asserts the selection precedes the run, and fails when the selection is dropped.
385. **After `/cd`, a channel's new shell panes still open in the old directory.**
    `ComposerRegistry.adoptDirectory` rebuilds the host's `ChannelContext`, but the host hands back
    the session it already retains and `TerminalPanelSession` holds the context it was made with;
    neither Cmd+Shift+T nor the pane bar's `+` passes a directory override. The channel moves and
    its next shell does not. Closer: a context refresh a retained session can observe — a seam
    between the host's cache and a live session rather than a change inside either. Owner: C7.4
    with C5.
    **A second entry point into the same wrongness was closed in wave F5**: the sidebar used to
    seed a channel's context with a *job's* directory when the channel had no row, which recorded
    that directory as the **channel's** own cwd — so every later Cmd+Shift+T shell opened there and
    it was persisted into the W6 document. A job's channel is now resolved through its row only;
    with no row the pane goes to the channel in view, and no cwd is recorded for anyone. What
    remains here is the `/cd` case, which needs the context-refresh seam.
386. **A shell opened while the initial document read is in flight is lost to a release in that
    window.** `schedulePersist` deliberately writes nothing until the read reaches `.done`, and
    `tearDown` deliberately writes nothing at all, so a pane created between those two facts is
    recorded by neither and the replacement session reads the older document. Both halves are right
    on their own; the gap is where they meet. Same family as 346 and 352 — ordering under teardown,
    where each fix has revealed the next. Closer: a teardown that flushes what the read was
    blocking rather than one that writes nothing. Owner: C7.4.
387. **Closed 2026-09-09 in wave F5**, by the merge review round finding the sequence its closer
    had only guessed at: main-window host A holds the surface, pop-out B steals it, a re-render C
    steals it from B, and when the pop-out closes B — dismantled, in no window — is handed the view
    while the live A draws nothing. `relinquish` now forgets **before** the ownership guard rather
    than after it, and `survivingHost` skips any container with no window. The test that covered
    this passed only by creation order; the reversed order and the dismantled-middle-host case are
    covered now.
    Recorded with it, benign today: `PaneSurfaceContainer.mounted` is **process-global with no
    per-test reset**, so containers from earlier tests share one list. Harmless — every entry is
    weak and windowless ones are now skipped — and worth knowing before someone reads a cross-test
    interaction as a defect in the claim.
388. **`TerminalSessionRegistry.isSameWorld` is inert in production.** It decides whether a
    retained session belongs to the workspace being asked about by comparing the identity of the
    context's `store`, but `identity(of:)` needs a class and the production `WorkbenchScopedStore`
    is a **struct**, so the check answers "same world" for every context it is given. It is harmless
    only because it stands *behind* `bindWorkspace`, which releases the whole registry before any
    replacement context exists. Written as a guard, it currently guards nothing, and a reader will
    trust it. Closer: a first-class world token on `ChannelContext` — a `PanelHostAPI` change and so
    a parent revision — or a class-bound store. Same seam as entry 349. Owner: C7.4 with C5.

406. **The neighbourhood's registry mirror is outside the timeline table's reload comparison.**
     `TimelineTableController` decides a forced reload by comparing `toolCalls`,
     `precedingTimestamps` and `agents`; `TimelineNeighbourhood.registry` joined the value in the
     `corrective/c3-agent-tree-mirror` corrective and was not added, because that corrective's App
     change was held to the one read it was for. A registry move with no accompanying item change
     therefore does not re-key the `taskRun` row, and the card keeps the mirror snapshot it was built
     with. Narrow in practice: a row appears with its `task_started`, which moves the item too, and
     the foreground-to-background transition is one the card refreshes itself on — so the reachable
     gap is a `background_tasks_changed` that unlists a row while nothing else about it moves. Closer:
     add `registry` to the comparison, or key the card on the mirror's row rather than on the item.
     Owner: C6.1. Filed 2026-09-09.
     **Closed 2026-09-09 by the same corrective's fix wave, and it was wider than filed.** The reload
     comparison was the second half; the first was `TaskCardSeam.identity(of:in:)`, which read the
     task, the status and the channel's capability and never the mirror — so a row mounted before its
     run's `task_started` reached the fold kept the card it built then, and *Move to background* was
     absent for the whole of that run's foreground life whatever any comparison said. Both now fold in
     the mirror's **eligibility** for the task (`TaskCardEligibility`, `TaskCardModel.isEligible`) and
     not the mirror itself, which also takes the neighbourhood cache off the mirror: `lastFrameAt` is
     stamped by every task frame, so keying on the whole value charged a chatty agent one O(items)
     rebuild per heartbeat — the growth §8.3 forbids, arriving through a field a card reads four values
     out of.

407. **A tree node built from a `.meta.json` sidecar reads `.running` on a channel that ended long
     ago.** Nothing on disk records an agent run's terminal status: the sidecar carries `agentType`,
     `description`, `toolUseId`, `spawnDepth` and `parentAgentId` and no more, and the run's own
     transcript ends without saying it ended. So the node a file-only open creates takes the type's
     default, and C6.4's Agents tab will show every run of an archived or foreign session as running.
     It is deliberately the *same* reading the record reducer already takes for a file-side `taskRun`
     row with no spawning call (`RecordReducer.taskRun(for:spawnedBy:toolUseID:)`), because the two
     halves of one channel disagreeing about one run is worse than both being conservative — but both
     are wrong for a session that is over. Closer: derive the status from the spawning tool call when
     the main transcript holds one (which is what the item side already does when it can), and treat a
     channel the index reports dormant as ending its runs. Filed by the
     `corrective/c3-agent-tree-mirror` corrective on `main`, 2026-09-09. Owner: C3, before C6.4 is
     judged on foreign channels.
     **Mostly closed the same day, in the same corrective's fix wave.** `StreamIngestion` reconciles
     the tree against the merged projection's `taskRun` rows after every recompute, so a node no
     `task_started` named takes the row's status and the row's start instant: an archived session's
     runs now read *Completed* in both halves. What remains is narrower and is what this entry now
     stands for: a run whose spawning call is nowhere in the merged line — a truncated window, an
     agent stream whose `tool_use` block was compacted away — still reads running in both halves,
     because nothing on disk says otherwise; and no node gets an `endedAt`, since neither the sidecar
     nor the transcript records when a run ended, so a consumer that ticks elapsed to `endedAt ?? now`
     has nothing to stop at. Closer: an end instant the file half can defend (the last record of the
     run's own transcript is a *last activity*, not an end), and C4's dormancy as the second witness.

## From C7.7 (Source Control and GitHub panel, `child/c7-scm-panel`)

277. **A linked worktree's or a submodule's history changes outside the watched root.** Design §5
     rests on "history changes only through `.git`, and `.git` is watched", which holds for an
     ordinary repository and not for a linked worktree or a submodule: there `.git` is a *pointer
     file* and the real HEAD, refs and reflogs live elsewhere, so an empty commit in a linked
     worktree can generate no event beneath the watched root and the graph goes stale until the
     user refreshes. `RepositoryWatch` follows the limitation deliberately rather than reaching for
     a git command this leaf is not allowed to write (W7). Closer: a C7.3 reader that reports the
     real git directory (`rev-parse --git-common-dir`), watched alongside the working tree — which
     is a core capability decision, not a panel fix. Found by C7.7's whole-branch review.
     Owner: C7.3, with C7.7 as first consumer.

278. **`NoDefer` is carried as an API contract, not as a mechanism.** The plan named dropping
     `kFSEventStreamCreateFlagNoDefer` as a mutation that must turn G1.5 red; measured on this
     machine it does not — deliveries arrive in 11–14 ms with the flag and without it at a
     0.5–1 s latency, and the deferral only shows at a 3 s latency, where it costs 1.79 s. The
     one-second bound is bought by the latency sitting well under it. Recorded so a later reader
     does not re-derive it and does not treat the mutation as an outstanding obligation.
     Owner: C7.7.

279. **The `gh` not-authenticated classification is written twice.** `GitHubModel` classifies a
     `gh` failure into a message plus an optional `gh auth login` hint, duplicating C7.6's
     `PullRequestURLResolver`, because panel targets cannot import each other. Two copies of one
     rule diverge the first time either is edited. Design §8 anticipates the duplication and files
     it rather than working around it. Closer: the classification belongs in `SourceControlCore`
     beside the `ToolError` it reads. Owner: whichever leaf next needs a third copy.

280. **The third copy of the git fixture builder, and now a fourth thing inside it.** Entry 232
     named the duplication of a scratch guard, a repository builder and a recording runner across
     test targets; C7.7 wrote the third copy, and added a *correct* argv verb extractor to it —
     one that skips options taking a separate value (`-c key=value`, `-C`, `--git-dir`, …). The
     first version of that extractor read `git -c diff.renameLimit=1000 status` as a
     `diff.renameLimit=1000`, which would have made a G4 allowlist either fail spuriously or, as a
     denylist, silently accept `git -c anything=x commit`. C7.3's own copy should be checked for
     the same wrong reading. Closer: entry 232's `WorkbenchTestSupport` target. Owner: the next
     leaf to add a copy.

     **Two divergences inside this leaf, found at its own fix wave and left standing.**
     `RepositoryReaderTests` keeps a *second* copy of the git verb allowlist which does not carry
     `hash-object` — harmless only because no test there reaches `GitDiff`'s unborn-`HEAD` path
     today, so the two lists have quietly drifted and the next test to reach it fails in a way that
     looks like a violation rather than a stale list. And `SourceControlModelTests` still asserts
     argv per test, where `GitHubModelTests` moved the same claim into `tearDown()` so it cannot be
     forgotten — the weaker form is exactly what let a whole flow escape the gate until the
     whole-branch review found it.

281. **`GitRepository`'s `name:` defaults to `"repo"`, so two fixtures in one scratch tree collide.**
     The second `git init` builds its history on top of the first's, silently — it cost one real
     red during C7.7's readout tests, presenting as a fixture reporting three lanes where two were
     expected. Closer: default the name to a unique value, or have the initialiser refuse a
     directory that already exists. Owner: whoever owns the shared fixture under entry 232.

282. **A prefix `.commit` delivery costs up to five `git log` reads.** Design §7's ruling forbids
     calling a prefix unique before the walk reaches its bound, and W7 leaves this leaf no
     object-existence reader, so an abbreviated hash outside the window walks. If C7.3 shipped a
     `rev-parse --verify` / `--disambiguate` wrapper the whole walk collapses to one lookup.
     Owner: C7.3, with C7.7 as first consumer.

283. **`deliveryRetries` is one.** A `.commit` delivery superseded twice — a repository being
     written continuously — answers `.searchInterrupted` rather than the commit. Bounded by
     design, since a click must not spend a repository's worth of `git log`, but it is a real if
     rare second-best answer. Owner: C7.7.

284. **A cancellation is recognised by comparing against a mapping, not by a tag.** `RepositoryError`
     classifies a `ToolError` into a detail string and keeps no structural marker, so the model
     identifies a cancelled read by comparing against the reader's own mapping of
     `ToolError.cancelled`. It works and is pinned by a test; the honest shape is a case or a flag
     on `RepositoryError`. Owner: C7.7.

285. **`AppModel.filesSession(for:)` and `sourceControlSession(for:)` are the same six lines twice**,
     differing only in a tab id and a cast; a third panel host makes it three. The generic that
     removes the duplication needs `PanelTabSession` subtype resolution the host does not expose.
     It belongs next to tracker 240, whose X7 amendment would touch both methods anyway.
     Owner: C5's fence.

286. **G4's source-level surface gate is scoped to two file names.** The scan that closes "a
     `Button` written into a view body with no `Control` behind it" reads
     `SourceControlPanelView.swift` and `GitHubPanelView.swift` by name through `#filePath`. A
     third view file added to the panel directory is silently unscanned. The durable form is a scan
     of every `*View.swift` in the directory, which needs a rule for what counts as a `Control`
     door per file. Owner: C7.7, or whoever adds the third view.

287. **The G4 surface gate is textual and models no indirection.** It cannot see a session captured
     into a local (`let s = session; s.commit()`), an interactive element introduced by a helper
     view type living in another file, or a mutating action added *inside* `Control.perform` — that
     last one remains the enum inventory's job. It closes the mutation it was written for and is
     not a proof about rendered SwiftUI; a body walk would need an inspection facility this
     repository does not have. Owner: C7.7.

288. **The live `gh` leg names a public repository through `GH_REPO`.** It runs in a scratch tree
     and reads only, but it remains network- and account-dependent; if CI ever runs with a token,
     that token's rate limit is spent here. Owner: C7.7.

289. **`gh pr checks`' documented exit code 8 still has no live confirmation** — this leaf's live
     leg ran and reached no repository with a check in flight, so entry 118 stays open and is
     restated here as C7.7's own unfinished business rather than left on C7.3's row. The behaviour
     is asserted against an authored document and a stub. Owner: C7.7 or whoever next runs the
     live leg while CI is in flight somewhere.

290. **Four workers in one worktree cannot each show a test failing first.** A task that lands its
     tests before its implementation makes `swift test` unbuildable for every sibling, so two of
     C7.7's four Wave A tasks took their failing-first evidence in a throwaway copy of the package.
     The evidence is sound; the shape is not, and it also cost several later runs to sibling
     compile breaks. Closer: a worktree per parallel task, or a rule that tests and implementation
     land in one commit. Owner: whoever dispatches the next parallel wave.

291. **A user's brand-new file appears in the working-tree row but not in its file list.** The row
     is driven by `git status` (which sees untracked files) and the list by `git diff HEAD` (which
     does not), so an unstaged new file makes the panel say the tree is dirty and then shows a list
     that does not contain it. Both halves are correct about their own question — §6 keeps them
     apart deliberately — but the asymmetry is real and a human tester will meet it at G1's leg.
     Closer: list untracked paths from the status alongside the diff, marked as untracked.
     Owner: C7.7.
