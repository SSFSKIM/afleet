# C7: Workbench panels (2026-09-05)

> **Parent:** `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md §17 C7`.
> **Parent-pin:** that path at commit `ee94449` ("FleetKit: manifest skeleton with the C3
> and C4 target groups; X1 records the split"). **Level name:** composite child, wave 2 of
> the v1 roadmap (its package leaves) and wave 4 (its panel leaves). **Track:** decomposing
> run at dispatch, this document. **Consumes:** `AfleetCore` as merged from C2
> (`WorkspaceLink`, `DiffRef`, `ResolvedEnvironment`, `SessionID`, `ChannelOrigin`), the
> FleetKit manifest skeleton on `main`, and the parent's §9 in full. Leaves dispatch per
> their track hint, each carrying its section below as its spec; each leaf's artifact (plan
> or brief, ledger, PR) opens by citing this document (path + leaf id + the pin above). This
> document treats the parent's §17 C7 section, §9, §17.3's grades and contracts X1, X2, X5,
> X6, X7 and X11 as landed; it records the cut, the grades one level down, the contracts
> that cross the leaves, and the residue rulings a leaf inherits.

## Purpose

The Workbench is the VS Code-like panel beside the conversation: the place where the
user looks at what the agent is doing to the working tree, runs a shell in the same
directory with the same environment, reads the file the agent just edited at the line the
timeline pointed to, watches a dev server in a browser tab, and reads the repository's
history and pull requests without leaving the channel. Nothing here re-implements Claude
Code: the terminal runs the CLI's own `attach` and `--resume` clients in a PTY, the editor
is VS Code's own Monaco, git and gh are the user's binaries from the login shell's PATH.
The parent cut this branch as a composite because four panels have four state owners (a
process and its PTY, an editor buffer and a file watcher, a set of web views, a repository
and a remote) and four verification strategies, and because half of the work needs only
C2's value types while the other half needs a panel host that lands two waves later. This
document divides that branch into seven leaves along exactly those two axes.

## Parent-Level Acceptance

C7 closes by a recomposition check in the built app against the installed CLI, not by the
sum of its leaves:

1. **The parent's panel items pass as written**: 15 (background job attach and re-adopt),
   17 (open in terminal and back), 23 (terminal cwd and PATH), 24 (Files at the line, edit,
   save, refresh on agent edit), 25 (native viewers), 26 (dev-server URL in quick-open and
   the Browser tab), 27 (graph lanes, commit files, diff, working-tree row), 28 (PR with
   check status, opens in the Browser tab) and 39 (shared browser survives a channel
   switch). Items 15 and 17 are seams with C4 and are verified here, not in either leaf
   alone.
2. **Routes from other children land here**: `/login`'s automatic URL (item 59's `/login`
   step) and the overage card's *Set up usage credits…* (item 62's false branch) open in the
   Browser tab, and *Review trust in terminal* (item 47) runs `claude` in a Terminal pane
   in the project directory; all three arrive as `WorkspaceLink` or pane requests emitted by
   C6, never as Workbench code that knows about login, overage or trust.
3. **Every `WorkspaceLink` case routes end to end** from a click in the timeline: `.file`
   to Files at the line, `.diff` to a Files diff view, `.url` to a Browser tab, `.commit` to
   the Source Control commit detail, `.pullRequest` to the Browser tab on the PR page, and
   `.command` to the composer through C6's registered target; Cmd-click on any of them
   opens a new window.
4. **One environment**: `echo $PATH` in a pane equals the login shell's PATH (item 23), and
   the `git` and `gh` the panels run are the ones that PATH resolves (X11).
5. **The panel behaves as a panel**: any tab pops out into its own window keeping its
   channel context; panes and open editors are per channel and survive switching away and
   back; browser tabs are shared window-wide and persist across launches (X6, X7).
6. **The package stands alone**: `swift test --package-path Workbench` passes from a clean
   checkout with no network, covering the PTY layer's spawn, resize and exit, `LinkRouter`
   over every case, lane assignment for a merge, an octopus merge and a detached tag, the
   Monaco bridge's message codec, and the git and gh parsers; an import test proves that no
   Workbench module imports `ClaudeWire` (X1).
7. **The spikes are settled** with a Revision Note either way: S1 promoted or SwiftTerm
   adopted behind `TerminalSurface`; S3 promoted or its fallback adopted.
8. Because C7 is code-bearing, recomposition ends with an independent review of the merged
   Workbench tree against the items above before the retrospective is written.

## Grounding Baseline

Measured 2026-09-05 in the worktree at the pin.

- **Repository.** No `Workbench/` directory and no `project.yml` exist; `AfleetCore`,
  `ClaudeWire` and the `FleetKit` skeleton are on `main`. `AfleetCore.WorkspaceLink` and
  `DiffRef` match §9.6 exactly (`file(URL, line: Int?)`, `diff(DiffRef)`, `url(URL)`,
  `commit(String)`, `pullRequest(Int)`, `command(String)`; `DiffRef.Base` with
  `workingTreeAgainstHEAD`, `commit`, `commitAgainstParent`). `ResolvedEnvironment` carries
  `variables`, `shell`, `capturedAt`, `mode` and a `path` accessor; `ChannelOrigin` carries
  `foreignLive(.ownTerminalTab)`, the origin the hatch produces.
- **Toolchain.** macOS 26.5.2, Xcode 26.6 (17F113), Swift 6.3.3; `git` 2.55.0; `gh` 2.96.0
  logged in to github.com with `repo`, `read:org`, `workflow` and `gist` scopes; `bun`
  1.3.14; `node` 24.18.0; XcodeGen absent.
- **libghostty-spm** (`Lakr233/libghostty-spm`, MIT). Latest release tag `1.5.20260903`,
  published 2026-09-03, tracking Ghostty commit `c4e16970a803`; tags after `1.5.2` follow
  `<major.minor>.<UTC_YYYYMMDD>` with weekly releases and `1.4.0`–`1.5.0` were withdrawn, so
  the pin is an exact tag. Products `GhosttyKit` (C API), `GhosttyTerminal` (Swift views),
  `GhosttyTheme`, `ShellCraftKit`; macOS 13 minimum. The bundled libghostty is a trimmed
  build (custom shaders, inspector, Sentry, the native app runtime and the standalone
  executable removed). `GhosttyTerminal` exposes `TerminalSurfaceView` (SwiftUI),
  `TerminalView` (AppKit), `TerminalController`, `TerminalSurfaceOptions`, and a
  host-managed backend: `public enum TerminalSessionBackend: Sendable { case exec; case
  inMemory(InMemoryTerminalSession) }` and `public final class InMemoryTerminalSession:
  @unchecked Sendable` with `init(write: @escaping @Sendable (Data) -> Void, resize:
  @escaping @Sendable (InMemoryTerminalViewport) -> Void, suppressesPixelOnlyResizes: Bool =
  false)`, `receive(_ data: Data)` ("enqueue data for the terminal from the host backend"),
  `receive(_ string: String)`, `sendInput(_ data: Data)`, `finish(exitCode: UInt32,
  runtimeMilliseconds: UInt64)`, `readViewportText() -> String?` and
  `waitForPendingOutput()`. Input reaches the host through the `write` closure; output
  reaches the terminal through `receive`; the viewport reaches the host through `resize`.
  Sources: the package README and `Sources/GhosttyTerminal/InMemory/` on `main`, read
  2026-09-05.
- **The upstream C API** (`ghostty_init`, `ghostty_config_new`, `ghostty_app_new`,
  `ghostty_surface_new`, `ghostty_app_tick`, `ghostty_surface_draw`, `wakeup_cb`,
  `action_cb`) is documented as "used primarily by the macOS app and not yet stabilized for
  general-purpose embedding"; upstream issue #12065 (opened 2026-04-02 by the maintainer,
  milestone 1.4.0, open) requests exposing the surface's child pid and tty, which confirms
  that a libghostty-spawned child is not observable by the embedder today. Sources:
  `ghostty-org-ghostty.mintlify.app/api/overview`, `github.com/ghostty-org/ghostty/issues/12065`,
  read 2026-09-05.
- **Termini** (`arach/Termini`, MIT, macOS 14+) is the parent's reference implementation:
  a `forkpty`-backed local PTY (`TerminiLocalPTYProcess`), bytes routed to the screen with
  `controller.processRemoteOutput(data)`, keystrokes out through `controller.onTransportWrite`,
  size changes through `controller.onSizeChange`; no detach or exit-observation design is
  documented. **SwiftTerm** (`migueldeicaza/SwiftTerm`) is active in 2026 (synchronized
  output CSI 2026, `MacLocalTerminalView.startProcess(currentDirectory:)`) and ships
  `LocalProcessTerminalView`, so the S1 fallback is real.
- **Mitchell Hashimoto's pure-Swift Metal renderer over `libghostty-vt`** was announced in
  July 2026 as "coming soon"; it is not released at the pin and is not a dependency here.
- **The attach client's detach behaviour** (engine bundle 2.1.258, `cli.pretty.js`):
  `claude attach <id>` is described in-product as "Open the background session in this
  terminal. ← returns to agent view, Ctrl+Z drops back to your shell. The session keeps
  running either way." Its status lines end with "Ctrl+Z to detach", and a finished job
  prints "— done · Ctrl+Z to return —". The detach protocol (`daemonDetachApc`,
  `SUPERVISOR_DETACH_CODE`, `TRANSIENT_ATTACH_CODE`, `parseDetachMsg`) lives inside the CLI
  and is never spoken by afleet. Whether Ctrl+Z ends the process or stops it with `SIGTSTP`
  is not determinable from the bundle text and is S1's to observe.
- **Monaco** (`monaco-editor` on npm): latest `0.56.0`; the full package unpacks to 97.9 MB
  in 1,909 files, which is why a tree-shaken bundle, not the package, ships. The ESM
  integration requires `MonacoEnvironment.getWorker` or `getWorkerUrl` for the editor and
  language workers; esbuild-class bundlers (bun included) are the documented route
  (`microsoft/monaco-editor/docs/integrate-esm.md`, read 2026-09-05).
- **WebKit and custom schemes.** `WKURLSchemeHandler` is per web view; WebKit bug 242871
  records that loads from workers could not be serviced by a custom scheme handler until
  special handling was added for extension service workers, bug 296698 records an iOS 26
  regression where a page with a script element loaded through a custom scheme handler
  terminated the web content process, and the Apple forums record mixed-content refusals
  when a custom scheme is treated as insecure. None of this settles whether dedicated
  workers load under a custom scheme on macOS 26; S3 settles it.
- **gh JSON fields** (`cli.github.com/manual`, read 2026-09-05). `gh pr list --json` and `gh
  pr view --json` accept `number`, `title`, `state`, `isDraft`, `author`, `headRefName`,
  `baseRefName`, `url`, `updatedAt`, `createdAt`, `reviewDecision`, `statusCheckRollup`,
  `mergeStateStatus`, `mergeable`, `labels`, `additions`, `deletions`, `changedFiles`,
  `body` among 46 fields; `gh pr list` filters with `--head <branch>` and `--state
  {open|closed|merged|all}`. `gh pr checks --json` accepts `bucket`, `completedAt`,
  `description`, `event`, `link`, `name`, `startedAt`, `state`, `workflow`, exits 8 while
  checks are pending, and `--required` filters to required checks. `gh issue list --json`
  accepts `number`, `title`, `state`, `stateReason`, `author`, `labels`, `assignees`,
  `milestone`, `updatedAt`, `url`, `isPinned`, `issueType`, `blockedBy`, `blocking`,
  `parent`, `subIssues` among 27 fields.
- **git log ordering** (`git-scm.com/docs/git-log`, read 2026-09-05). `--topo-order` shows
  "no parents before all of its children are shown, and avoid[s] showing commits on
  multiple lines of history intermixed"; `--all` adds every ref under `refs/` plus `HEAD`;
  `--parents` prints `commit parent…`; `%H %P %D %an %at %s` are the placeholders the graph
  needs. The documentation makes no stability promise for `--graph`'s drawn output, which
  is why the graph is computed from `--parents`, never parsed from glyphs.

## Design

The parent's §9 is the design and is carried whole; this section records only what the
cut adds: the seams, the shapes two leaves must agree on, and the grades one level down.
Every unmarked statement is advisory inheritance a leaf may overturn with evidence and a
dated Revision Note here.

### Two axes, seven leaves

The first axis is the panel, because each panel has its own state owner and failure mode.
The second axis is the host: the parent named the PTY layer, the Monaco bundle and bridge,
lane assignment and `LinkRouter` as work that needs only Core types and can run now against
a stub, while every tab needs the panel host (C5.G4) and, for the terminal, the lifecycle
API (C4). A leaf that straddled the axis would merge twice across three waves and hold a
worktree for weeks with a pending gate the map has to keep explaining; a leaf per cell is
one merge each and lets `main` carry the cores while the hosts are built. The Browser has
no core (its state is web views and a store namespace), so the grid has seven cells, not
eight.

```
                      core (dispatchable now)          panel (after C5.G4)
Terminal and jobs     C7.1 TerminalCore + S1           C7.4 TerminalPanel (also after C4)
Files and links       C7.2 EditorCore, LinkRouting, S3 C7.5 FilesPanel
Browser               —                                C7.6 BrowserPanel (also after C4's store)
Source Control, GitHub C7.3 SourceControlCore          C7.7 SourceControlPanel
```

**[binding — two-axis cut]** The seven leaves and their target ownership below. A leaf
that finds a seam wrong files a `[parent-impact]` note here, never a local re-cut.

### The Workbench package and its manifest (contract W1)

**[binding — seven leaves build one package in parallel worktrees]** `Workbench/` at the
repository root, `swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, language mode 6 on
every target, one library product `Workbench` whose umbrella target re-exports the modules
below. Dependencies: `../AfleetCore`, `../FleetKit` (X1; never `ClaudeWire`), and
`Lakr233/libghostty-spm` pinned `exact: "1.5.20260903"` until a leaf bumps it with a
Revision Note. Targets, each owned by exactly one leaf; a leaf adds targets only inside its
own marked region of the manifest, and C7.1 owns the file itself:

| Target | Owner | Depends on | Notes |
|---|---|---|---|
| `TerminalCore` | C7.1 | AfleetCore, `GhosttyTerminal`, `GhosttyKit` | `TerminalSurface`, the PTY layer, the GhosttyKit adapter; SwiftTerm is added here only if S1 falls back |
| `EditorCore` | C7.2 | AfleetCore | `MonacoEditorView` (an `NSView` over `WKWebView`), the bridge, the committed bundle as a resource |
| `LinkRouting` | C7.2 | AfleetCore | `LinkRouter` and its target registry |
| `SourceControlCore` | C7.3 | AfleetCore | `git log` and `git status` parsers, lane assignment, diff model, `gh` JSON models and runner |
| `PanelHostAPI` | C5 (see the flow-back below) | AfleetCore, FleetKit | X7's tab-registration and channel-context protocol; declared here so both Workbench and the app can import it |
| `TerminalPanel` | C7.4 | TerminalCore, LinkRouting, PanelHostAPI, FleetKit | panes, job attach, the hatch, `claude logs` |
| `FilesPanel` | C7.5 | EditorCore, LinkRouting, PanelHostAPI, FleetKit | tree, viewers, watcher, banners |
| `BrowserPanel` | C7.6 | LinkRouting, PanelHostAPI, FleetKit | shared tabs, quick-open, persistence |
| `SourceControlPanel` | C7.7 | SourceControlCore, EditorCore, LinkRouting, PanelHostAPI, FleetKit | graph, detail, diffs, GitHub tab |
| `Workbench` | umbrella | all of the above | `@_exported import` of each |
| `S1Harness`, `S3Harness` | C7.1, C7.2 | their core | `executableTarget`s under `Workbench/Spikes/`, not in the product; each opens an `NSWindow` from `swift run` without an app bundle |

Test targets mirror the core targets (`TerminalCoreTests`, `EditorCoreTests`,
`LinkRoutingTests`, `SourceControlCoreTests`) and every panel target gets one when a panel
leaf lands. The orchestrator lands this skeleton on `main` before dispatching C7.1 through
C7.3, exactly as it did for FleetKit, with one placeholder source per target so the empty
package builds; that landing is the first row of the Tracking Map.

### `TerminalSurface` and the PTY layer (contract W2)

**[binding — C7.4 consumes it, and the S1 fallback must satisfy it unchanged]** The
protocol, kept to what a pane needs and nothing the renderer happens to offer:

```swift
public protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    func feed(_ output: Data)                                   // PTY -> screen
    var onInput: (@Sendable (Data) -> Void)? { get set }        // keyboard, paste, IME -> PTY
    var onResize: (@Sendable (TerminalSize) -> Void)? { get set } // rows, columns, pixel size
    func processDidExit(code: Int32)                            // final render; the pane decides what to show
    func setAppearance(_ appearance: TerminalAppearance)        // theme, font, follows the system by default
}
public struct TerminalSize: Hashable, Sendable { public var rows: Int, columns: Int, pixelWidth: Int, pixelHeight: Int }
```

The GhosttyKit adapter implements it over `InMemoryTerminalSession`: `feed` calls
`receive`, the session's `write` closure drives `onInput`, its `resize` closure drives
`onResize`, and `processDidExit` calls `finish(exitCode:runtimeMilliseconds:)`. Advisory:
the adapter shape, the appearance mapping onto `GhosttyTheme`, and which
`TerminalSurfaceOptions` are exposed.

The PTY layer (`PTYProcess`, an actor) owns the process end. **[binding — X11 and the
lifecycle seam]** It spawns with the channel's cwd and `ResolvedEnvironment.variables` as
the complete environment (no inheritance from afleet's own), and it reports exit as an
observed event with the code or signal, because the hatch's re-adoption (§7.4, "the
Terminal tab's process exits and its registry record is gone") is keyed on that event.
Advisory, the recommended mechanism: `openpty(3)`, then `posix_spawn` with
`POSIX_SPAWN_SETSID` and file actions that open the slave path as descriptors 0, 1 and 2
in the child, which makes the slave the session leader's controlling terminal at that open
(the slave is opened after `setsid`, without `O_NOCTTY`); `ioctl(master, TIOCSWINSZ)` on
`onResize`; a `DispatchSource` read loop on the master feeding `feed` on the main actor; and
`waitpid` with `WUNTRACED` so a child that stops rather than exits is seen. `forkpty(3)` is
the fallback if the controlling terminal is not acquired that way; it is not the first
choice because a `fork` in a process with live actors and threads is only safe between
`fork` and `exec` for async-signal-safe calls, and the failure is silent. libghostty's own
`.exec` backend is rejected for the pane even if the trimmed build supports it: the
embedder cannot observe the child's exit or pid (issue #12065) and cannot compose the
environment X11 requires.

**Delegated unknown, S1 (C7.1).** In the harness: a login shell renders through the
adapter with live resize and IME (a CJK composition commits correctly); `claude attach
<short>` against a running `claude --bg` job renders the job's screen; Ctrl+Z returns —
recording whether the attach client exits (with what code) or stops with `SIGTSTP`; if it
stops, the PTY layer treats a stopped attach child as detached (`SIGCONT` then `SIGHUP`,
the job keeps running under the daemon) and the finding is recorded here. Promote when all
three hold; otherwise SwiftTerm's `TerminalView` behind `TerminalSurface`, with the PTY
layer unchanged, as a Revision Note.

### Monaco: bundle, bridge, view (contract W4)

**[binding — C7.5 and C7.7 both consume it]** Monaco ships as a committed, generated bundle
under `Workbench/Sources/EditorCore/Resources/monaco/`, built by `Tools/build-monaco.sh`
with bun from `monaco-editor@0.56.0` (a lockfile pins it), tree-shaken to the editor, the
diff editor, syntax highlighting for every Monaco language and language services only for
the web languages (`typescript`, `javascript`, `json`, `css`, `html`), with a `VERSION`
stamp and Monaco's MIT licence text beside it. `swift test` never runs bun and never
touches the network; upgrading Monaco is a deliberate commit that reruns the script. The
bundle is loaded by `MonacoEditorView` (an `NSView` wrapping a `WKWebView`) through a
`WKURLSchemeHandler` on the `afleet-editor` scheme, and the bridge is a
`WKScriptMessageHandler` named `afleet` plus `evaluateJavaScript` for host-to-editor calls,
carrying JSON messages with this vocabulary and no other: host to editor `open {path,
language, text, line?}`, `setText`, `gotoLine {line, column?}`, `setTheme {name}`,
`showDiff {path, original, modified, language}`, `save` (request the buffer); editor to
host `ready`, `dirty {path, isDirty}`, `saveRequested {path, text}`, `cursor {line,
column}`, `error {message}`. The codec for these messages is a Swift `Codable` type in
`EditorCore` with a round-trip test. Advisory: the exact scheme name, whether workers are
served through the scheme or created from Blob URLs, the theme mapping.

**Delegated unknown, S3 (C7.2).** In the harness: cold load of the editor under one second
from `swift run`; a 5 MB file opens warm with no visible jank; a 2,000-line diff renders;
and, first of all, whether Monaco's editor and language workers start under the custom
scheme on macOS 26 — if not, workers are created from Blob URLs built by the bootstrap
script, and if that also fails the bundle is loaded with `loadFileURL(_:allowingReadAccessTo:)`
instead of the scheme, each recorded here. Promote when the three measurements hold;
otherwise the fallback the parent names (the WebKit route with the measurements recorded)
as a Revision Note. The measured bundle size is recorded in the Tracking Map.

### `LinkRouter` (contract W5)

**[binding — every panel and C6 register against it]** `LinkRouter` in `LinkRouting` is a
registry, not a switch: a target registers for a `WorkspaceLink` case (or a predicate over
it) with a handler that receives the link and a `LinkDestination` (`.currentPanel`,
`.newWindow`); `open(_ link: WorkspaceLink, from: LinkDestination)` picks the most specific
registered target, and with none registered falls back to `NSWorkspace.shared.open` for
`.url` and to a diagnostic for the rest. Cmd-click maps to `.newWindow`. Files registers
`.file` and `.diff`, Browser registers `.url` and `.pullRequest`, Source Control registers
`.commit`, and C6 registers `.command` for the composer. The router is pure and tested
without the app: one test per case proving the registered target is called with the link
intact, one proving the fallback, one proving specificity.

### Source Control and GitHub data (contract W7)

**[binding — C7.7 renders only these types]** `SourceControlCore` defines `GitCommit
{hash, parents: [String], refs: [GitRef], authorName, authorTimestamp, subject}` parsed from
`git log --topo-order --all --parents --format='%H%x1f%P%x1f%D%x1f%an%x1f%at%x1f%s%x1e'`,
`WorkingTreeStatus` from `git status --porcelain=v2 --branch`, `LaneAssignment {rows:
[GraphRow]}` where a row carries the commit, its lane, and the edges to the next row, and
the `gh` models `PullRequest`, `CheckRun`, `Issue` decoded from the verified field subsets
in the Grounding Baseline. Every `git` and `gh` invocation goes through one `ToolRunner`
that resolves the binary through `ResolvedEnvironment.path` and passes
`ResolvedEnvironment.variables` (X11), runs in the repository root, and returns stdout,
stderr and the exit code with a timeout; a missing binary or a non-zero exit is a
panel-local error state (§10), never an exception that reaches the channel. Lane assignment
is the classic single pass over topological order (a commit takes its first child's lane
when it is that child's first parent, otherwise the first free lane; merges close lanes
when their extra parents are reached; the working tree occupies row zero above `HEAD`),
tested on a merge, an octopus merge and a detached tag. Advisory: the exact algorithm,
refresh cadence, and pagination.

### Store namespaces (contract W6)

**[binding — X6 says who owns what]** Workbench persists under two keys of FleetKit's store:
`workbench.browser` (the shared tab set: URLs, titles, order, selected index) and
`workbench.panel.<configHomeHash>.<sessionId>` (per-channel panel state: open files with
cursor positions, pane count and cwd overrides, the selected tab). Both are `Codable`
types owned by Workbench with a schema version; FleetKit never reads them.

### What the panels need from the host (contract W8, X7)

The channel context X7 promises (session id, cwd, environment, store handle, `LinkRouter`
target capability) covers everything except two things the Browser and the Terminal need,
recorded here as a flow-back to the parent rather than invented locally:

- a **recent-URL feed** for quick-open: the host supplies an observable list of URLs seen
  in the current channel's tool output (C3's items carry them; C6 renders them; the Browser
  only lists them). Without it the Browser would parse timeline items, which X1 forbids.
- a **pane request and exit report** at the lifecycle seam: X5's `openInTerminal(channel)`
  and `attach(job)` perform their ownership work (§7.2 rule 5, the quiescent handoff) and
  hand the Terminal panel a `PaneRequest {executable, arguments, cwd, environment,
  purpose: .hatch(SessionID) | .attach(jobShort) | .logs(jobShort) | .shell | .command}`;
  the panel runs it and reports `PaneExit {request, code, observedAt}` back through X5,
  which owns the re-adoption. The Terminal panel never spawns `claude` for a session on
  its own initiative. `stop`, `respawn` and `rm` are CLI verbs with no PTY and belong to X5's
  actions; the sidebar's *Stop* and *Respawn* call X5, not Workbench.

**[binding — ownership protocol is C4's]** The second bullet's division: the hatch takes
exclusive ownership through X5 and gives it back through the exit report; C7.4 owns the
pane, C4 owns the transition.

### Grades inherited from the parent, one level down

- §9.6 `WorkspaceLink`: binding (parent).
- §9.3's adapter shape and §9.5's verb list: advisory; that attach and the hatch are CLI
  verbs in a PTY with exclusive ownership: binding (parent).
- §9.1's bundling and bridge: advisory in the parent; W4 fixes the parts two leaves share.
- §9.4: advisory except window-wide shared tabs, binding (parent).
- §9.2's scope (graph, history, working-tree diff; no staging, committing or branch
  operations): binding by the parent's decision; its algorithm: advisory.
- The Files tree, viewers and watcher internals: advisory. Recommended: per-open-file
  `DispatchSource.makeFileSystemObjectSource` with a poll fallback for the conflict banner;
  `git check-ignore --stdin` in one batch for the gitignore toggle; `NSAttributedString`
  markdown, `NSImage`, PDFKit, AVKit, Quick Look for the viewers, in that order of
  preference.
- Web Inspector: `isInspectable = true` in Debug builds and behind the Developer setting
  in Release; advisory.

## Children

### C7.1: Terminal core — `TerminalSurface`, the PTY layer, the GhosttyKit adapter, S1 — plan

- **Purpose:** Everything a terminal pane needs below the panel: the `TerminalSurface`
  protocol, the PTY layer that spawns a process in a directory with a given environment
  and reports its exit, the GhosttyKit adapter over `InMemoryTerminalSession`, and the S1
  harness that settles whether GhosttyKit is the renderer. It also owns the Workbench
  manifest after the skeleton lands.
- **Acceptance:** G1 (required): `swift test --package-path Workbench` covers the PTY layer
  with a real child: spawn `/bin/sh -c 'pwd; echo $FOO'` in a temporary directory with a
  crafted environment and read both back; resize and observe `TIOCGWINSZ` from the child
  (`stty size`); exit code and signal observed and reported once each; a stopped child is
  observed as stopped; nothing inherits from the test process's environment (assert by
  names, never by dumping environments, §6.3). G2 (required, S1): the harness renders a
  login shell through the adapter with live resize and IME, renders `claude attach <short>`
  against a running `claude --bg` job started under the scratch config home, and Ctrl+Z
  returns to the pane with the job still listed by `claude agents --json`; the exit-or-stop
  finding is recorded in this document's Revision Notes. Promote-or-fallback: a failure
  adopts SwiftTerm behind `TerminalSurface` with the PTY layer unchanged, recorded as a
  Revision Note, and G2 is re-run against it. G3 (required): the adapter does nothing on
  the main thread that blocks on the child (feed is asynchronous; a flooding child cannot
  freeze the harness), proven with a `yes` child for ten seconds.
- **Edges:** blocked-by: C2 (landed), the W1 skeleton on `main`; blocks: C7.4; conditional
  on nothing.
- **Contracts:** W1 (owner of the manifest), W2 (owner), X11.
- **Design inheritance:** §9.3 (adapter advisory; CLI-verbs-in-a-PTY binding), W2, the
  Grounding Baseline's libghostty-spm and attach facts, the S1 fallback (advisory).
- **Required:** required for parent acceptance (items 15, 17, 23 rest on it).
- **Status:** not-dispatched, dispatchable now (after the skeleton lands). Branch
  `child/c7-terminal-core`.

### C7.2: Editor core — the Monaco bundle, bridge and view, `LinkRouter`, S3 — plan

- **Purpose:** The editor as a reusable view and the router every panel registers with:
  `Tools/build-monaco.sh` and the committed bundle, `MonacoEditorView` over `WKWebView`
  with the W4 bridge, the S3 harness, and `LinkRouting` with `LinkRouter`.
- **Acceptance:** G1 (required): `swift test --package-path Workbench` covers the bridge
  codec round trip for every message in W4, `LinkRouter` for every `WorkspaceLink` case,
  its fallback and its specificity rule, and a resource test that the bundle is present,
  stamped with the pinned Monaco version and accompanied by the licence. G2 (required, S3):
  the harness loads the editor cold under one second from `swift run`, opens a 5 MB file
  warm with no visible jank, renders a 2,000-line diff, and reports whether workers started
  under the scheme, from Blob URLs, or under `loadFileURL`; the findings and the bundle
  size are recorded in this document. Promote-or-fallback per the Design. G3 (required):
  `git ls-files` shows the bundle, `VERSION` and licence and nothing else generated (no
  `node_modules`, no lockfile-adjacent caches); a clean checkout builds and tests with the
  network disabled.
- **Edges:** blocked-by: C2 (landed), the W1 skeleton; blocks: C7.5, C7.6, C7.7.
- **Contracts:** W1, W4 (owner), W5 (owner).
- **Design inheritance:** §9.1 (advisory), §9.6 (binding), W4, W5, the Grounding
  Baseline's Monaco and WebKit facts.
- **Required:** required.
- **Status:** not-dispatched, dispatchable now. Branch `child/c7-editor-core`.

### C7.3: Source Control core — git and gh parsers, lane assignment, the tool runner — brief

- **Purpose:** The pure and process-level half of Source Control and GitHub: the
  `ToolRunner` that resolves `git` and `gh` through the resolved environment, the parsers
  for `git log`, `git status` and `git diff`, lane assignment, and the `gh` models over the
  verified field subsets.
- **Acceptance:** G1 (required): lane assignment tests on fixture repositories the tests
  build in a temporary directory with the `git` binary: a merge (at least two lanes), an
  octopus merge (three parents), a detached tag, and a repository with the working tree
  dirty (row zero present); `git status --porcelain=v2` parsing for modified, added,
  deleted, renamed and untracked; `gh` models decode recorded sample JSON committed as test
  data (synthetic values, real field names). G2 (required): the runner passes the resolved
  environment and cwd, times out, and surfaces a missing binary as a typed error; a test
  proves the environment it passes is the one it was given, by names. G3 (conditional,
  evaluable when `gh` is logged in on the machine running it, else skipped with a named
  reason): `gh pr list --json` on a public repository with open pull requests decodes with
  no missing key.
- **Edges:** blocked-by: C2 (landed), the W1 skeleton; blocks: C7.7.
- **Contracts:** W1, W7 (owner), X11.
- **Design inheritance:** §9.2 (scope binding, algorithm advisory), W7, the Grounding
  Baseline's git and gh facts.
- **Required:** required.
- **Status:** not-dispatched, dispatchable now. Branch `child/c7-scm-core`. Ledger
  `docs/doperpowers/ledgers/<date>-c7.3-scm-core.md`.

### C7.4: Terminal panel and jobs — panes, attach, the hatch, logs — plan

- **Purpose:** The Terminal tab: one or more panes per channel opened in the channel's cwd
  with the resolved environment, Cmd+Shift+T for a new pane, job attach through
  `claude attach <short>`, the raw-TUI hatch through `claude --resume <id>` with
  re-adoption on exit via X5, `claude logs <short>` in a pane, and the pane half of item
  47's *Review trust in terminal*.
- **Acceptance:** G1 (required): item 23 in the built app. G2 (required): item 15's attach
  half and item 17 end to end with C4: the pane exit is reported through X5 and the channel
  becomes owned again with the composer enabled. G3 (required): a `PaneRequest` from C6
  runs in a pane in the requested cwd (item 47's terminal step); a pane whose process exits
  shows the exit and offers *Restart pane*; closing a hatch pane while its process lives
  asks first (§7.8's never-kill rule applies to foreign sessions; the hatch process is
  afleet's own tab and may be terminated after confirmation). G4 (required): panes are per
  channel and survive a channel switch; the tab pops out.
- **Edges:** blocked-by: C7.1, C4 (X5 with W8's pane request and exit report), C5.G4;
  blocks: C6's item 47 action, recomposition.
- **Contracts:** W2, W8, X5, X7.
- **Design inheritance:** §9.3, §9.5, §7.4's hatch rows (binding), §7.2 rule 5 (binding).
- **Required:** required.
- **Status:** not-dispatched, blocked-by C7.1, C4, C5.G4. Branch `child/c7-terminal-panel`.

### C7.5: Files panel — tree, viewers, watcher, link targets — plan

- **Purpose:** The Files tab: the tree rooted at the channel's cwd with gitignore toggle
  and filter, open, reveal and copy path; code in `MonacoEditorView` with save, goto-line
  and theme; native viewers for markdown, images, PDF, audio and video; the file watcher
  with the dirty-buffer conflict banner; and the `.file` and `.diff` targets on
  `LinkRouter`.
- **Acceptance:** G1 (required): item 24 in the built app, including the refresh after the
  agent edits the open file and the conflict banner when the buffer is dirty. G2
  (required): item 25. G3 (required): a `.diff` link with each `DiffRef.Base` opens the
  right pair in the diff editor. G4 (required): open files and cursor positions persist
  per channel under W6 and restore on relaunch.
- **Edges:** blocked-by: C7.2, C5.G4; blocks: C7.7 (diff views), recomposition.
- **Contracts:** W4, W5, W6, X7.
- **Design inheritance:** §9.1 (advisory), the Design's tree and viewer recommendations.
- **Required:** required.
- **Status:** not-dispatched, blocked-by C7.2, C5.G4. Branch `child/c7-files-panel`.

### C7.6: Browser panel — shared tabs, quick-open, persistence, routes — brief

- **Purpose:** The Browser tab: `WKWebView` tabs shared across the window with URL bar,
  back, forward, reload and inspector; quick-open over the host's recent-URL feed; the
  `.url` and `.pullRequest` targets on `LinkRouter`; Cmd-click to the system browser; tabs
  persisted under W6.
- **Acceptance:** G1 (required): items 26 and 39 in the built app. G2 (required): a `.url`
  link from a timeline item opens in the tab; Cmd-click opens the system browser; a
  `.pullRequest` link opens the PR page. G3 (required): tabs persist across relaunch. G4
  (required): the inspector is reachable in Debug and behind the Developer setting in
  Release.
- **Edges:** blocked-by: C7.2 (LinkRouter), C4 (X6 store), C5.G4 and W8's recent-URL feed;
  blocks: C7.7 (PR opening), C6's `/login` and overage routes, recomposition.
- **Contracts:** W5, W6, W8, X6, X7.
- **Design inheritance:** §9.4 (window-wide tabs binding, the rest advisory).
- **Required:** required.
- **Status:** not-dispatched, blocked-by C7.2, C4, C5.G4. Branch `child/c7-browser-panel`.
  Ledger `docs/doperpowers/ledgers/<date>-c7.6-browser-panel.md`.

### C7.7: Source Control and GitHub panel — graph, detail, diffs, GitHub tab — plan

- **Purpose:** The Source Control tab: the graph on a SwiftUI `Canvas` from
  `SourceControlCore`'s lane assignment with branch and tag labels and the working tree as
  row zero; commit detail with changed files and Monaco diffs; working-tree diffs against
  `HEAD`; the `.commit` target on `LinkRouter`; and the GitHub tab with pull requests for
  the branch, checks and issues from `gh`, a PR opening in the Browser tab.
- **Acceptance:** G1 (required): item 27 in the built app, including the working-tree row
  updating within one second of an edit. G2 (required): item 28. G3 (required): a
  `.commit` link selects that commit; `gh` absent or logged out shows the panel-local empty
  state with the `gh auth login` hint and runs no auth flow. G4 (required): no staging,
  commit or branch action exists in the UI (§9.2 scope, binding).
- **Edges:** blocked-by: C7.3, C7.5 (diff views), C7.6 (PR opening), C5.G4; blocks:
  recomposition.
- **Contracts:** W4, W5, W7, X7, X11.
- **Design inheritance:** §9.2 (scope binding, algorithm advisory), W7.
- **Required:** required.
- **Status:** not-dispatched, blocked-by C7.3, C7.5, C7.6, C5.G4. Branch `child/c7-scm-panel`.

## Cross-Child Contracts

- **W1 Workbench manifest and target split.** As the Design states, with the ownership
  table. Owner: C7.1 for the file, each leaf for its region; the orchestrator lands the
  skeleton. Binds every C7 leaf and C5 (the `PanelHostAPI` target).
- **W2 `TerminalSurface` and the PTY layer's observable contract.** The protocol as written;
  exit reported once as an observed event; environment and cwd taken from the request and
  nothing else. Owner: C7.1. Binds C7.4 and the S1 fallback.
- **W4 Monaco bundle, bridge vocabulary and view.** Owner: C7.2. Binds C7.5, C7.7.
- **W5 `LinkRouter` registration.** Owner: C7.2. Binds C7.4 through C7.7 and C6.
- **W6 Store keys.** Owner: C7 as a whole (declared here). Binds C7.5, C7.6; rides X6.
- **W7 Source Control and GitHub data types and the tool runner.** Owner: C7.3. Binds C7.7.
- **W8 Host capabilities: recent-URL feed, pane request and exit report.** Owner: this
  document as a flow-back to the parent's X5 and X7 (C4 and C5 own the content). Binds
  C7.4, C7.6, C4, C5, C6. Written to outlive this unit: on closing, W8's two shapes are
  promoted into X5 and X7 on the parent.

## Ordering & Dependency Map

```
main: W1 skeleton ──► C7.1 TerminalCore (S1) ──────────────┐
                 ├──► C7.2 EditorCore + LinkRouting (S3) ──┼─┐
                 └──► C7.3 SourceControlCore ──────────────┼─┼─┐
      (wave 2, three worktrees, disjoint manifest regions) │ │ │
                                                           ▼ │ │
C4 (X5 + W8) ─────────────────────────────────────────► C7.4 TerminalPanel
C5.G4 (panel host, PanelHostAPI) ───────────┬─────────► C7.4 │ │
                                            ├──────────► C7.5 FilesPanel ◄──┘ │
                                            ├──────────► C7.6 BrowserPanel ◄─ C7.2, C4 (store)
                                            └──────────► C7.7 SourceControlPanel ◄── C7.3, C7.5, C7.6
      (wave 4; C7.5 and C7.6 in parallel, then C7.7)
```

Wave 2, now: C7.1, C7.2 and C7.3 in parallel, each merging to `main` when its gates pass;
their spikes settle first inside each leaf. Wave 4, when C5.G4 lands: C7.5 and C7.6 in
parallel (C7.6 also needs C4's store), C7.4 when C4 has W8's pane request, then C7.7.
Recomposition after C7.7. The critical path inside C7 is C7.2 → C7.5 → C7.7; the critical
path into C7 is the parent's C4 → C5.

## Risks & Mitigations

- **Workers under a custom scheme.** WebKit's history with custom-scheme loads makes
  worker start-up the first thing S3 measures; two fallbacks are named in order (Blob-URL
  workers, then `loadFileURL`), so the leaf never stalls on it.
- **Weekly Ghostty tags.** An exact pin (`1.5.20260903`) and a bump only by a leaf with a
  Revision Note; the adapter is the only importer, so a breaking tag is one file.
- **Ctrl+Z semantics in a pane with no shell parent.** `waitpid(WUNTRACED)` in the PTY
  layer and the stopped-means-detached rule, settled by S1 before any pane is built.
- **Controlling-terminal acquisition without `fork`.** The `posix_spawn` file-action route
  is verified by G1's `stty size` and job-control checks; `forkpty` is the named fallback.
- **The hatch's re-adoption race** (pane exits before the registry record disappears):
  C4's ten-second quiescent handoff (§7.2 rule 5) owns the wait; C7.4 only reports the exit.
- **Bundle bloat in git.** The tree-shaken bundle's size is measured by S3 and reported to
  the human gate before it is committed; the question below carries the decision.
- **Tests that pass but cannot fail** (parent §17.7, binding): every fix's test is shown
  failing first; the PTY layer's environment assertions compare names, never dumps; a lane
  test asserts the lanes it expects, not that some lanes exist.
- **`gh` or `git` missing on PATH.** Panel-local states; the tool runner never falls back
  to `/usr/bin` silently, because a different binary would mean different hooks and
  credential helpers (X11).

## Deferred / Out of Scope

**Deferred (may return):** a host-managed byte-stream terminal feed (the parent reserves it;
`TerminalSurface.feed` already takes bytes, so it is an adapter away); split panes and
pane layouts beyond a stack; Monaco language services for languages other than the web
five; a `libghostty-vt` Swift-renderer adapter when it ships; GitHub actions beyond reading
(merge, comment, approve); search across the Files tree; Quick Look for arbitrary types as a
first-class viewer; a `git blame` gutter.

**Explicitly out of scope (parent §3, §9.2):** staging, committing, branch and worktree
operations; a native code editor; LSP; dispatching new jobs (v1.1); speaking the daemon
control socket or the detach APC sequences (the CLI's own clients do this, binding by the
parent's decision); any write under `<configHome>` (X9); IDE registration.

## Tracking Map

| Leaf | Artifact | Status |
|---|---|---|
| W1 skeleton | landed by the orchestrator on `main` before dispatch | pending |
| C7.1 Terminal core | plan `plans/<date>-c7.1-terminal-core.md` on `child/c7-terminal-core` | not-dispatched, dispatchable after W1 |
| C7.2 Editor core | plan `plans/<date>-c7.2-editor-core.md` on `child/c7-editor-core` | not-dispatched, dispatchable after W1 |
| C7.3 Source Control core | ledger `ledgers/<date>-c7.3-scm-core.md` on `child/c7-scm-core` | not-dispatched, dispatchable after W1 |
| C7.4 Terminal panel | plan on `child/c7-terminal-panel` | blocked-by C7.1, C4, C5.G4 |
| C7.5 Files panel | plan on `child/c7-files-panel` | blocked-by C7.2, C5.G4 |
| C7.6 Browser panel | ledger on `child/c7-browser-panel` | blocked-by C7.2, C4, C5.G4 |
| C7.7 Source Control panel | plan on `child/c7-scm-panel` | blocked-by C7.3, C7.5, C7.6, C5.G4 |

Spike outcomes (S1, S3), the exit-or-stop finding, the worker-loading finding and the
measured bundle size are recorded in the Revision Notes and summarised on the leaf's row
when it lands.

## Decision Log

- Decision: Seven leaves on two axes — three package cores now, four panels after the
  host — rather than four panel leaves.
  Rationale: The parent already separates package-level work from UI work by blocker; a
  panel leaf would merge twice across three waves and hold a worktree with a pending gate
  the map keeps explaining. The Browser has no core. Rejected: four panel leaves merging
  in halves; one combined "package leaf" for all cores (three unrelated state owners and
  verification strategies, the split signals of the gate).
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: S1 and S3 run as the first gate of C7.1 and C7.2, promote-or-fallback, not as
  spike leaves.
  Rationale: The spike's artefact is the leaf's first deliverable (the PTY layer and
  adapter; the bundle and view); a spike leaf would have to discard or merge it, and the
  skill's spike track is "findings, never a merge". Rejected: standalone spike leaves; the
  spikes deferred until the panels.
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: Spike harnesses are SwiftPM `executableTarget`s under `Workbench/Spikes/`,
  opening an `NSWindow` from `swift run` without an app bundle.
  Rationale: XcodeGen is absent and the app target is C5's; a windowed executable needs
  no bundle for a terminal view or a web view, and `swift run` keeps the spike inside the
  package's own test cycle. Rejected: waiting for C5's app; a throwaway Xcode project.
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: Our own PTY layer with `posix_spawn` + `openpty`, `forkpty` as the fallback;
  libghostty's `.exec` backend rejected for panes.
  Rationale: The pane must observe its child's exit (the hatch's re-adoption keys on it)
  and compose the environment X11 requires; libghostty's own child is not observable by
  the embedder (issue #12065) and its environment is its own. `fork` in a process with live
  actors is only safe for async-signal-safe calls before `exec`. Rejected: `forkpty` first
  (Termini's route; silent failure class); `.exec`.
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: Monaco as a committed, generated, tree-shaken bundle rebuilt by
  `Tools/build-monaco.sh`, loaded through a custom scheme handler with Blob-URL workers as
  the first fallback.
  Rationale: SwiftPM build plugins have no network and `swift test` from a clean checkout
  must pass; the parent's §11 already lists Monaco as "build output committed"; §9.1's
  "bundled at build time" describes the script, not the SwiftPM build. Rejected: bun in the
  SwiftPM build; loading from a CDN (offline, privacy); shipping the npm package whole
  (97.9 MB, 1,909 files).
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: `LinkRouter` is a registry of targets, not a switch in the host.
  Rationale: Five registrants across four leaves and C6; a switch would couple the host
  to every panel and make each new case a host edit. Rejected: a switch statement in the
  app; per-panel `open` methods the host calls by name.
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: The graph is computed from `git log --topo-order --all --parents`, never parsed
  from `--graph` glyphs; git runs as the user's binary, not libgit2.
  Rationale: git's documentation promises topological order and parent lists and promises
  nothing about the drawn graph's stability; the parent wants hooks, credential helpers
  and worktrees to behave, which only the binary gives. Rejected: parsing `--graph`;
  libgit2.
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: GitHub data only through `gh … --json` with fixed field subsets; no token
  handling in afleet.
  Rationale: `gh` already holds the user's token and scopes; the field names are
  documented and verified. Rejected: GitHub REST through `URLSession` with our own token
  store.
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: The jobs verbs split — `attach` and `logs` are panes; `stop`, `respawn` and `rm`
  are X5 actions with no PTY.
  Rationale: Only the first two produce a screen; the rest are one-shot processes the
  lifecycle API already runs for *Adopt*. Rejected: every verb in a pane; every verb in
  Workbench.
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: The hatch takes ownership only through X5 and returns it through a pane exit
  report; the Terminal panel never spawns `claude --resume` on its own.
  Rationale: §7.2's ownership protocol is C4's and rule 5's quiescent handoff has to run
  before the pane starts; a pane that spawned on its own would race it. Rejected: the panel
  spawning after asking X5 for permission (splits one transition across two owners).
  Date/Author: 2026-09-05 / decomposing run (C7).

- Decision: `PanelHostAPI` is a target in the Workbench package that C5 fills.
  Rationale: X7's protocol has to be importable by Workbench (which registers tabs) and by
  the app (which hosts them), and Workbench cannot import the app; declaring the target now
  fixes its location without pre-empting C5's content. Rejected: the protocol in FleetKit
  (FleetKit never models upper-layer state, X6's rule); in AfleetCore (value types only).
  Date/Author: 2026-09-05 / decomposing run (C7).

## Surprises & Discoveries

- **libghostty-spm has an `exec` backend.** `TerminalSessionBackend` is `exec |
  inMemory(InMemoryTerminalSession)`, so the package can spawn a child itself. The parent's
  reason for our own PTY layer ("the package ships an in-memory backend") is therefore
  incomplete; the load-bearing reason is exit observation and environment composition,
  recorded in the Design. Evidence: `Sources/GhosttyTerminal/InMemory/TerminalSessionBackend.swift`
  on `main`, 2026-09-05.
- **Ctrl+Z is the attach client's detach key**, and the client also treats ← as "back to
  the agents view". A pane running `claude attach` therefore has two exits: one to the
  CLI's own FleetView inside the pane, one out of the process. Evidence: bundle 2.1.258
  strings quoted in the Grounding Baseline.
- **The `--graph` output is undocumented for parsing.** The design already computed lanes;
  the documentation check turned an assumption into a decision.
- **`gh pr checks` exits 8 while checks are pending.** A non-zero exit is not a failure
  there; the tool runner must know the verb's exit contract.
- **Monaco's full package is 97.9 MB.** The bundle decision is about a tree-shaken build;
  its real size is a spike output, not a guess.

## Questions for the human gate

1. **Committing the Monaco bundle.** The recommendation is to commit the generated,
   tree-shaken bundle (likely 10–20 MB across a few dozen files; S3 measures it) so a clean
   checkout tests offline. The alternative is a release-asset download step on first build.
   Decide after S3 reports the size, or now on the principle.
2. **Ghostty pin cadence.** Weekly tags. Recommendation: pin exactly, bump at each C7
   leaf's dispatch with a Revision Note; never track the latest implicitly.

## Outcomes & Retrospective

Pending — written when the unit closes. Closing is a RECOMPOSITION check: verify
Parent-Level Acceptance as written — all leaves landed is not the same event — then
retrospect.

## Revision Notes

- 2026-09-05: v1, written at the decomposing run against parent commit `ee94449`. Flow-back
  raised for the orchestrator, none of it edited on the parent here: X5 gains W8's pane
  request and exit report; X7 gains the recent-URL feed and the `PanelHostAPI` target's
  location in the Workbench package; X1's Workbench manifest ownership is C7.1 with the
  regions of W1; §11's "build output committed" and §9.1's "bundled at build time" are
  reconciled as the Design says; §9.5's verb list is split between panes and X5 actions;
  the parent's Tracking Map row for C7 points here.
