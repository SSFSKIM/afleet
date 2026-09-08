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
     counter wraps.** The test arranges a decoy job holder at `ScriptedHolderFiles.livePID` — the
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
     fails under load. Recurred; worth fixing now rather than watching.** Observed twice during
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

153. **C6.1 must call `ComposerModel.edit(_:)`, and no contract says so.** The composite gives C6.2
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
     up on its effects under load.** In a `make test` run with a 15-minute load average of 89 (two
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
