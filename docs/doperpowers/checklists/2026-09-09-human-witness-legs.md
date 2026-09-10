# Human witness legs — everything only a person can see (2026-09-09)

The merged C6 and C7 leaves recorded headless evidence and outstanding human/live legs
in their Outcomes. This file collects those legs and C6's cross-owner acceptance
prerequisites. It is not proof that all parent acceptance is implemented or passed.
Nothing here is a claim: each leg is unwitnessed until a person witnesses it.
Implementation-blocked legs cannot be completed merely by changing accounts.

**How to run the app.** `make build` (Debug, the `afleet` scheme) and launch it. Legs
marked *live* — the ones that spawn or attach to a real engine — run only under the
scratch config home the Makefile's `live` target uses,
`CLAUDE_CONFIG_DIR=/tmp/afleet-fixtures/config-home`; that home must report completed
onboarding and have the installed `claude` on PATH, which `make live` checks before it
runs anything. A few legs are harness legs rather than app legs and name their own
`swift run` line.

**How to report a pass.** Counts only — how many legs of a section passed, and which
numbered clause failed if one did. No paths, no session ids, no transcript excerpts,
no repository or account names. Same rule the leak-risk review has held on every
merge: reports emit counts.

**Reading a leg.** Each line gives the §14 checklist item it belongs to, the action,
what passing looks like (quoted from the spec where the spec has its own wording),
and one clause on what the headless half already proved. Leaf section headers identify
their merge; the cross-owner section names its unresolved prerequisite.

---

## C7.3 — Source Control core (`aa5df80`)

No human legs. The leaf is a package with no user interface: G1 and G2 are headless
over fixture repositories the tests build, and G3's conditional live `gh` leg was
evaluated on the machine (five pull requests decoded, no missing key). Everything a
person can see from this work appears under C7.7.

## C7.2 — Editor core (`a47788a`)

Backs items 24, 25 and 27 — Monaco is the editor all three render in — but has no
§14 item of its own; S3's third clause is a human's word by construction.

- [ ] **S3, "no visible jank"** — run `swift run --package-path Workbench S3Harness
      --route scheme --hold`, which "prints the report and leaves the window up for
      exactly that", open the 5 MB file warm and scroll it by hand. Passing is that
      the scroll reads as smooth to the eye. Headless: cold load median 556 ms against
      a 1,000 ms budget, first render of the 5 MB file in 89–128 ms, scripted scroll
      p50 17 ms / p95 24–33 ms, all five Monaco workers proved live by attributed traffic.

## C6 — Cross-owner prerequisite: New channel (tracker 162)

**Blocked by implementation, not just live policy.** No new-channel path exists, and
`isolatedSettingsForNewChannels` has no spawn consumer. Shell/lifecycle owns the
implementation; C6 retains integration verification under its inherited acceptance.
These legs are additions to the historical leaf checklist, not newly passed checks.

- [ ] IMPLEMENTATION BLOCKED **Item 3, New channel** (live) — on a project, choose
      *New channel* and send a message. A new transcript must appear with the UUID afleet
      chose, and the channel must gain an AI title after the first turn. No integrated
      creation/title evidence is recorded. Answer mapping for questions/plans does not
      cover this item. The first-turn leg also needs an account permitting prompted turns.
- [ ] IMPLEMENTATION BLOCKED **Item 47, Trust** (live) — in a directory never opened in
      the engine, *New channel* must open history-only with the trust banner and no process;
      *Review trust in terminal* must run `claude`, and accepting its dialog then exiting
      must lead to an owned spawn. Headless: the banner and terminal action have evidence,
      including routing to C7.4's pane runner; the required new-channel entry is absent.

The same prerequisite blocks the isolated-settings setup used by items **4, 5, 41 and 52**
and the card-diff leg below. Verify the Developer setting reaches the new channel's
spawn (`--setting-sources ""`, plus `--strict-mcp-config` when §6.12 requires it).
Isolation injected at a test process-factory seam does not prove this product setting.
No account change, fixture signature or checklist walk closes absent implementation.

## C6.2 — Composer and channel header (`c2dae0f`)

Three legs, "none of it reachable from XCTest". The prompted half of G6 is in the
blocked section below.

- [ ] **The quit alert** (no numbered §14 item; §8's quit clause) — with a busy channel,
      press Cmd+Q. Passing is "the quit `NSAlert` itself — its copy, its button order,
      and that Cmd+Q with a busy channel raises exactly one". Headless: the re-census,
      the one-reservation rule and the cancellation of running `!` commands are all tested
      against a lifecycle double.
- [ ] **The delegate in the real scene** (no numbered §14 item) — launch the built app and
      confirm quit behaviour engages at all. Passing is `NSApplicationDelegateAdaptor`
      installing the delegate, "which SwiftUI resolves at app launch and not in a test
      bundle". Headless: every consequence of the delegate is tested; its installation is not.
- [ ] **`.quit` against a live engine** (items 16, 17 adjacent; live) — with a genuinely busy
      owned channel under the scratch home, quit. Passing is the `.quit` verb ending it.
      Headless: the verb, the warning from `liveTaskIDs(of:)` and the busy re-census are
      proved on doubles.

## C7.1 — Terminal core (`855b815`)

S1's verdict is **promote GhosttyKit, provisionally**; it "is final when a person has run
`swift run --package-path Workbench S1Harness shell` and reported those three". All four
run in the same window, in order. Backs items 15, 17 and 23.

- [ ] **The prompt** (item 23) — start the harness shell. Passing is "does the prompt look
      right — colour, font, cursor". Headless: a login shell's first paint filled one
      non-blank row of a 33x112 grid from 473 bytes, "which is a prompt and nothing more".
- [ ] **A full-screen TUI** (item 23) — run `vim` in that window. Passing is the redraw and
      the alternate-screen exit both correct. Headless: two invented markers fed through the
      real pty came back out of the rendered grid; nothing about alternate-screen was asserted.
- [ ] **Live resize** (item 23) — drag the window by its title bar while the TUI is up.
      Passing is a live resize, and whether it stutters is the finding. Headless: a
      programmatic resize round-tripped 33x112 → 41x138 in 59.5 ms and the child's own
      `stty size` rendered the same pair back.
- [ ] **CJK input** (item 23) — switch to a CJK input method and commit a composition.
      Passing is "the text reaches the shell". Headless: nothing; IME is outside the pty layer.
- [ ] **Flood feel** (optional, tracker 86) — `S1Harness flood`, dragging during the ten
      seconds. Passing is a judgement, not a bar: the window is "responsive, not smooth",
      and a drag under full-rate flood "will hitch by up to a quarter of a second". Headless:
      run-loop heartbeat median 17.3–23.6 ms, maximum 117–262 ms over four runs.

## C6.3 — Decision cards and threads (`0fe2797`)

Three looks legs; "every gate above asserts the value a click sends", and "that a
diff is readable … [is] looks, and no headless runner takes them". The prompted half of
G5 is in the blocked section below. Note that tracker 157 — the reason "in the running
app a card's state does not yet leave `.pending`" — was closed as contract Y7 at C6.1's
merge, which lands after this one. That removes the pending-state blocker, not tracker
162's isolation-setting blocker on the diff leg.

- [ ] IMPLEMENTATION BLOCKED **A diff on a card is readable** (items 4, 5; tracker 162) — in a disposable directory with
      *Isolated settings for this channel* on, drive a `Write` card to a pending state and
      read its diff. Passing is that the diff is readable at the card's size. Headless:
      bounded previews and diffs are asserted by value, never by legibility.
- [ ] **A dialog's deadline is legible** (item 62) — replay `dialog-fable-overage` through
      `fake-claude` and look at a pending dialog card. Passing is "that a five-minute
      deadline is legible on a pending dialog". Headless: §8.4's five-minute deadline is
      recorded as a fact and the card's actions are asserted as exact `InboundAnswer`s.
- [ ] **`requires_user_interaction` reads as deliberate** (items 57, 62) — replay a card
      carrying the flag. Passing is that it "reads as deliberate rather than broken".
      Headless: the flag's effect on the answer path is tested; its effect on a reader is not.

## C7.5 — Files panel (`517899d`)

Seven legs. G1–G4 are met headless "over a recording editor seam"; each gate named its
own human half, and the composite adds the tree chrome.

- [ ] **The Read-row click** (item 24) — click a path in a Read row. Passing is "Monaco
      rendering the file at the line on screen", and typing into it works. Headless: the
      routed `.file` link produces `open {path, language, text, line}` with the link's line intact.
- [ ] **The agent's edit refreshes the pane** (item 24; live) — with that file open, ask
      `claude` to edit it. Passing is the editor refreshing, cursor restored. Headless: a
      clean rewrite on disk produces `open` then `gotoLine` in that order.
- [ ] **The conflict banner** (item 24) — dirty the buffer, then have the file rewritten
      underneath it. Passing is the conflict banner appearing, with *Reload* and *Keep mine*
      both doing what they say. Headless: both arms proved; *Reload* refreshes, *Keep mine*
      marks the next save an overwrite.
- [ ] **Each viewer renders** (item 25) — open a `.md`, a `.png`, a `.pdf` and an `.mp4`.
      Passing is "an image visible, a PDF paged, an MP4 playing". Headless: `FileKind.of(url:)`
      names the viewer for a generated corpus and bytes veto a false extension.
- [ ] **The side-by-side diff** (items 24, 27) — open a `.diff` link. Passing is "the pair
      rendered side by side in Monaco's diff editor". Headless: every `DiffRef.Base` over
      real repositories plus added, deleted, renamed, root, binary and gitlink cases, asserted
      at the `showDiff` command's contents.
- [ ] **Relaunch restore** (item 24) — open several files, quit, relaunch. Passing is
      "relaunching the built app and finding the files still open", at their cursor positions.
      Headless: the per-channel document round-trips against a real store; two channels never
      read each other's key.
- [ ] **The tree chrome** (item 24) — exercise the tree: gitignore toggle, filter, reveal,
      copy path. Passing is that each control does what it says on a real project. Headless:
      the gitignore batch is `check-ignore --verbose --non-matching` read by position, tested
      as a decision, not as chrome.

## C7.6 — Browser panel (`6f8a8ec`)

Nine legs: two gate legs, the Release inspector, the click half that C6.1 unblocked
after this merge, and the five visual legs waves C, D and E added.

- [ ] **The dev server** (item 26; live) — run `python3 -m http.server 8123` in a Terminal
      pane. Passing is the URL appearing in quick-open and "the listing renders in the
      Browser tab". Headless: not proved at all — "item 26 needs a real dev server and a person".
- [ ] **The shared tab survives a switch** (item 39) — open a page, switch channels, switch
      back. Passing is "the tab and its page are unchanged". Headless: structural — one
      `BrowserModel` owned by the one tab, so "a second web view for a second channel is
      unrepresentable, not merely untested".
- [ ] **The Release inspector** (G4; no numbered item) — a Release build with the Developer
      toggle off, then on. Passing is the inspector unreachable then reachable. Headless:
      `isInspectable` follows the injected policy, asserted both ways; Debug leg met.
- [ ] **A `.url` clicked in the timeline** (item 26; C6.1 dependency) — click a URL rendered
      in a timeline row. Passing is the page loading in the Browser tab; Cmd-click opens the
      system browser instead. Headless: the whole delivery path is proved through a real
      `LinkRouter`; at C7.6's pin no timeline item emitted a `.url`, which C6.1's merge changed.
- [ ] **Quick-open's arrow keys** (item 26) — open quick-open and press Up/Down. Passing is
      the highlight moving. Headless: proved at the model; "what a human witnesses is that
      SwiftUI calls the lifecycle the way the model assumes".
- [ ] **Pages follow a pop-out** (item 39) — with a Browser pop-out on screen, switch the
      main panel column away. Passing is the pages moving into the pop-out. Headless: at the
      session.
- [ ] **Pages return** (item 39) — switch the column back with the pop-out still open.
      Passing is the pages returning to the main panel. Headless: at the session.
- [ ] **Cmd-Shift-L in a pop-out** (item 26) — press it in a popped-out Browser window.
      Passing is quick-open opening there "and not in the main window as well". Headless: at
      the session.
- [ ] **Quick-open closes on switch-away** (item 26) — open quick-open, then switch the
      surface showing it away. Passing is quick-open closing. Headless: at the session.

## C6.1 — Timeline renderer (`947c7cc`)

Three legs. Historical S7 measurements were p50 3.51 ms / p99 7.66 ms over 1,781
samples, compared with the minimal spike's 1.47 ms. The invented-prose workload measures
markdown hosting, the table and scroll correction, not production item builders;
tracker 427 remains a deferred performance-coverage gap.

- [ ] **A markdown-heavy turn, side by side** (item 2; §12's fidelity witness, not item 3's creation/title check) — open the
      same markdown-heavy turn in afleet and in the terminal, beside each other. Passing is
      that afleet's rendering is faithful. Headless: "this is what the invented S7 corpus
      bought its frame time with, and it is the one thing no gate in this leaf can supply".
- [ ] **A chip, a disclosure and a card, by hand** (item 9) — click each. Passing is each
      navigating or expanding as its assertion says it would. Headless: the chip resolves its
      run's task id on a counting double, but "no chip or disclosure is clicked (reflection
      cannot enter a `@ViewBuilder`)".
- [ ] **A long transcript opened cold** (item 1) — open a long archived session. Passing is
      the timeline rendering "in under one second" without a scroll hitch. Headless: G5 proved
      the five-second budget on two rows at 107 ms — "G5 proves the budget, not scale"; tracker
      132 (every row's height measured through a throwaway hosting view on reload) is the risk.

## C7.4 — Terminal panel and jobs (`054e42c`)

Eight legs, from the leaf's "What a human still has to witness" plus the composite's list.
The attach measurement is settled — exit 0 at 522 and 530 ms with the `--hold` control
passing — so these are about the screen, not the timing.

- [ ] **Item 23 on a screen** (item 23) — `pwd` then `echo $PATH` in a Terminal pane. Passing
      is the channel cwd and the login shell's PATH, both visible. Headless: a real child
      through the pane's own path, environment asserted by name in both directions.
- [ ] **The attach client's screen** (item 15; live) — start `claude --bg` under the scratch
      home, *Attach*. Passing is the client's screen rendering in the pane, and the detach key
      returning "the pane showing the exited attach and the job still running". Headless: the
      whole X5 path plus a live run at zero model turns.
- [ ] **Attach brings its channel into view** (item 15) — *Attach* from the Background section
      while another channel is focused. Passing is the job's own channel visibly coming into
      view. Headless: a host that resolved the channel from focus instead of the caller fails
      the placement test and nothing else.
- [ ] **The composer across the hatch** (item 17) — *Open in terminal*, then close the tab.
      Passing is the composer disabled while the hatch lives and enabled after, "the channel
      becomes owned again". Headless: the exit is reported through X5 exactly once with the
      request echoed.
- [ ] **The close confirmation** (item 17) — close a hatch pane while its process lives.
      Passing is a confirmation "whose hatch wording names the channel's return", and confirming
      reports exactly one exit. Headless: the confirmation and the single exit are both asserted.
- [ ] **Cmd+Shift+T and keystrokes** (item 23) — take Cmd+Shift+T from the menu bar and type
      into the new pane. Passing is the keys landing. Headless: "the tests prove the container
      asks for first responder and the window grants it to the surface; they cannot prove the
      renderer then routes the keys".
- [ ] **The pop-out** (parent acceptance 5) — pop the Terminal tab out. Passing is "two windows
      over one Terminal tab both drawing, the loser saying so, and the main window repainting
      when the pop-out closes". Headless: the claimant stack is proved at model level, including
      out-of-order withdrawal.
- [ ] **The composer keeps the keyboard** (parent acceptance 5) — close a pop-out while the
      composer has focus. Passing is the composer keeping the keyboard. Headless: hand-off never
      takes the keyboard and a windowless host is never handed the surface — both fix-wave F5
      properties, asserted at the model.

## C7.7 — Source Control and GitHub panel (`3ab455f`)

Six legs. Every gate is met headlessly, including the one-second working-tree clause at
5 of 5 runs inside the bound; what is left is what the panel looks like on a real repository,
and FSEvents on the user's own directories is TCC-gated in a way no test could reach.

- [ ] **The graph** (item 27) — open Source Control on a repository with a merge commit.
      Passing is "the graph drawn on screen with its lanes, dots, ref badges and dates", at
      least two lanes. Headless: lanes named with their commits over merge, octopus and
      detached-tag repositories, asserted as the Canvas's draw operations.
- [ ] **The commit detail** (item 27) — select a commit. Passing is the detail beside the graph
      listing its files. Headless: the commit-file corpus — modification, add, delete, rename,
      binary, gitlink and a root commit listing its whole tree — asserted at the selected-commit
      readout.
- [ ] **The diff click** (item 27) — click a file in a commit. Passing is the diff opening in
      Monaco. Headless: the click emits its `.diff` through a real `LinkRouter` to a recording
      target; C7.7 imports no editor.
- [ ] **The working-tree row appears** (item 27; live) — ask `claude` to edit a file and watch.
      Passing is the row appearing "while the user watches", within one second. Headless:
      5 of 5 standalone runs inside the bound, ~0.23 s to appear and ~0.50 s to clear, on a
      temporary repository — a watcher on the user's own repository is this leg.
- [ ] **The PR row** (item 28) — open the GitHub tab on a repository with an open PR. Passing
      is "the PR row on screen with its check status". Headless: the branch-scoped list by value
      and the five-valued rollup with its mixed cases; the live `gh` leg reached no check in
      flight, so tracker 289 stays open and *pending* has never been seen live.
- [ ] **The PR opens in the Browser tab** (item 28) — click the PR row. Passing is the PR page
      loading in the Browser tab. Headless: exactly `.pullRequest(number)` is emitted through a
      real router and no URL is built in this panel.

## C6.4 — Agents panel (`19b4127`)

Three looks legs and one hand-off. G1–G5 are met headless and G6's zero-turn half rendered a
run's transcript from a session's files alone with the config-home witness at zero; the leaf
says plainly what the green does not cover: a `confirmationDialog`'s buttons and an
`AgentRelayNote`'s placement cannot be reached by a `Mirror` walk (tracker 398), and the live
half exercised a single-run tree (184). The prompted half of G6 is in the blocked section below.

- [ ] **The fixture signature** — copy `/tmp/afleet-c64/send-message-delivery/` into `Fixtures/`,
      walk `Fixtures/REVIEW.md` (item 2's two account-name hits are the English word inside the
      engine's stopped-by-user sentence; item 1's "two dialog fixtures" and `hypothesis: false`
      were accepted 2026-09-10, tracker 426), then `make sign FIXTURE=Fixtures/send-message-delivery
      REVIEWER=<name>`. Passing is `make verify-fixtures` clean and `AgentRelayFixtureTests` no
      longer skipping. Headless: the six arms are asserted on hand-built machines; the fixture
      replay is the half that waits.
- [ ] **The two confirms read as what they end** (items 50, 51's neighbours) — with a channel
      that has two live runs, open the Agents tab and press *Stop everything*, then *Background
      all*; each confirm names what it will end and *Cancel* performs nothing. Headless: declining
      is asserted against a double that could have recorded an action; the buttons themselves are
      asserted through the members they call, never as drawn (398).
- [ ] **A relay note sits under its message** (item 51) — replay `send-message-delivery` through
      `fake-claude` once it is signed, or send a message from a node against a live channel, and
      look at the main timeline: the delivery state and *Retry* sit with the sent message, not
      only in the Agents tab. Headless: the note's body and the row's reading are asserted by
      value; where the row puts it is not (398).
- [ ] **An archived run reads as its agent** (item 38) — open a channel from disk that ran an
      `Explore` agent, select the run in the Agents tab and read its transcript: every message is
      authored `Explore` with a model badge, and none says "Claude". Headless: G2 asserts the
      author and badge on the row that draws them, replayed through the real ingestion; that a
      reader sees them at the row's size is looks.

---

## Blocked: the prompted-turn legs (not yours to run on this account)

These are the live legs whose acceptance names a *model behaviour* — they need a prompted
turn, and prompted turns are refused by the scratch account's organisation policy. The
composite records them as blocked and carried as a manual witness; the turns budgeted for
them are **unspent** and travel forward. Do not attempt prompted turns on this account:
the policy blocker requires an account change or an API key, not a re-run. That does not
remove product blockers: items 4, 5, 41 and 52 also depend on tracker 162's isolation consumer,
and item 3's prompted half is listed with its missing new-channel implementation above.
The recorded leaf turn budgets below are unchanged; the added coverage is not new spend
or evidence that those budgets exercise every parent clause.

**C6.2 G6 — four turns unspent, zero of four spent.**

- [ ] BLOCKED **Item 2, Continue** — send `Reply with exactly: pong`; `pong` renders as a Claude
      message with a turn summary and the transcript gains records.
- [ ] BLOCKED **Item 8, Interrupt** — send `Count slowly to 100, one number per line`, press Esc;
      "the turn stops within two seconds; the summary says interrupted".
- [ ] BLOCKED **Item 12, Shell escape and mentions** — `!pwd`, then ask `What did my last shell
      command print?`; the answer proves "a real model saw the `<bash-stdout>` envelope and could
      quote it back". The `!` posting half and item 60's envelope tags are fixture-proved and are
      *not* blocked.

**C6.3 G5 — six turns unspent, plus the D13 allowance.**

- [ ] POLICY + IMPLEMENTATION BLOCKED **Item 4, Permission** (tracker 162) — in a disposable directory with *Isolated settings* on, in
      `default` mode, `Create a file named ask.txt containing hello`; a `Write` card shows path
      and content, *Allow once* writes it and the log records `user_temporary`.
- [ ] POLICY + IMPLEMENTATION BLOCKED **Item 5, Always allow** (tracker 162) — repeat with a second file; the card offers *Always allow*,
      the log records `updatedPermissions` as `user_permanent`, and a third file writes with no card.
- [ ] BLOCKED **Item 6, Question** — `Use AskUserQuestion to ask me whether I prefer tabs or
      spaces`; a question card renders and selecting an option continues the turn.
- [ ] BLOCKED **Item 7, Plan** — picker to `plan`, `Plan a hello-world script`; a plan card renders
      and *Approve* switches the picker back.
- [ ] POLICY + IMPLEMENTATION BLOCKED **Item 41, Deny** (tracker 162) — in the isolated
      channel from item 4, click *Deny…* on a `Write` card with `not now`; the file is not written,
      the card shows denied, the summary lists the denial, "Claude's next message reflects the reason".

**C6 integration — item 43's real-engine end-to-end leg remains unavailable.**

- [ ] POLICY BLOCKED **Item 43, Malformed host answer** — arm the implemented Developer
      action *Send malformed answer to next permission*, then approve a permission card.
      Passing is the binary's denial text rendered in the timeline (the prefix specified
      in §14 item 43), followed by the channel continuing. Headless: C6.3's fixture proves
      rendering and corrective `91e0902` implements the arming action; neither is a witnessed
      real-engine round trip. The action is not missing implementation or a second deferred
      review finding. No live pass is recorded.

**C6.4 G6 — six turns unspent, zero of six spent.**

- [ ] BLOCKED **Item 9, Agent chip and tree** — send `Use the Explore agent to list the top-level
      directories`; the cluster shows an Explore chip with a running status, clicking it opens
      the Agents tab with the run selected, its tool calls arriving live and, after completion,
      the full transcript from its JSONL file. The chip-to-run wiring (G5) and a transcript from
      disk (G6's zero-turn half) are proved; only the live arrival waits on a turn.
- [ ] BLOCKED **Item 49, Nested agents** — with the fork setting off, send `Use a general-purpose
      agent that itself uses the Explore agent to list this directory`; the tree shows the child
      nested under its parent, selecting the child shows its own transcript, and the child's
      `.meta.json` names the parent. Nesting and parking are proved on `nested-depth-2` (G1);
      a live multi-run tree has not been seen (tracker 184).
- [ ] BLOCKED **Item 50, Stop a node** — while an agent runs, *Stop* on its node sends
      `stop_task`; the node shows stopped and the task item shows the partial summary. The exact
      request is asserted on the lifecycle double (G3).
- [ ] BLOCKED **Item 51, the positive path** — *Send message* on a completed Explore node with
      `also list hidden files`: *Pending*, then *Relayed* when the `SendMessage` call naming the
      run returns reporting success, then *Delivered* when the run's transcript gains the text.
      All five arms replay from the staged fixture once it is signed (G4).
- [ ] POLICY + IMPLEMENTATION BLOCKED **Item 52, Subagent permission** (tracker 162) — in the isolated channel, ask an agent to write
      a file; the permission card is labelled `Explore` with the run's description, the node
      shows a waiting badge, Activity lists it, and allowing it continues both.

The leaves record headless fixture/component evidence for cards, dialogs, cancellation,
malformed-answer rendering and unknown requests. That is not end-to-end evidence for every
leg here: `send-message-delivery` still awaits human review/signature and non-skipping replay;
New channel, trust entry and the isolation consumer remain implementation-blocked. C6
acceptance remains open under the composite Outcomes' closure conditions. Tracker 397/428
fixes merged with verification at `b2f1607`; these code checks do not check any human-witness box; tracker 435 is closed at `749246b` (relay conclusions
taken at publish and at release), which likewise checks no human-witness box. No boxes are checked by this correction.
