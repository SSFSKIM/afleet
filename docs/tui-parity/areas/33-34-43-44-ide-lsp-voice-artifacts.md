<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# Area 33 / 34 / 43 / 44 — IDE integration, LSP, Voice, Artifacts & Design

Chapters covered: SPEC 33 (IDE integration), 34 (LSP client), 43 (Voice), 44 (Artifacts and
Claude Design). Classification letters per the common brief: **P** parity via protocol,
**R** rebuild client-side, **D** data gap, **X** unreachable, **T** terminal-specific.

Live ground truth used: `/tmp/afleet-gap/init-dump.json` (2.1.259 headless `initialize`).
Its `commands` list (102 entries) contains **no** `ide`, `lsp`, `voice`, `artifacts`,
`design-login`, `status`, `plugin` or `tasks` entry, and **does** contain `design`,
`design-consent`, `design-revoke` and `design-sync`.

---

## 33. IDE integration

### 33.0 Does a headless session connect to an IDE at all? — No.

Three independent reasons, all citable:

1. The auto-connect driver `Vre({autoConnectIdeFlag, ideToInstallExtension, …})` is a React
   effect mounted only by the interactive REPL, and its body returns immediately in a
   non-interactive session and in a background session unless an extension install is
   pending (SPEC 33 §33.8.3, `chunk-bq8epagv.js:429152-429183`). FleetView's separate
   prompt-box auto-connect is likewise "skipped in non-interactive and background sessions"
   (§33.8.3, `chunk-stanqxmj.js:693188`).
2. `/ide` is `type: "local-jsx"` (§33.9), so it is refused headless and does not appear in
   `system/init.slash_commands` — confirmed against the live 2.1.259 initialize dump.
3. `CLAUDE_CODE_SSE_PORT`, `FORCE_CODE_TERMINAL` and the whole terminal-identity family are
   stripped from the environment of spawned background/daemon sessions (§33.16.3,
   `chunk-m84am00s.js:589633`).

Consequence for afleet: `--ide`, the lockfile sweep, the 30 s discovery loop and the
`ide_connected` handshake never run under `claude -p`. The only way an `ide`-named MCP client
can exist in a headless session is if the **host injects it** as an MCP server config
(`type: "sse-ide"` is in the `.mcp.json` transport enum, `chunk-ejcy5qcd.js:487993`; `ws-ide`
is not) — see the "IDE-side surface" subsection below for what that does and does not buy.

### 33.1 Feature table

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `--ide` flag | Forces the auto-connect gate `yfe(true)`; connects if exactly one valid IDE is found (§33.16.1, §33.8.1) | Flag is accepted by the CLI but the effect that consumes it never mounts (§33.8.3) | X | afleet must not rely on `--ide`; nothing happens. |
| Lockfile discovery `~/.claude/ide/*.lock` | Scans config dir + `~/.claude/ide` (+ WSL mounts), newest-mtime first, parses JSON `{workspaceFolders,pid,ideName,transport,runningInWindows,authToken}`, port from filename (§33.3–33.4) | Not run headless (§33.8.3) | R | Fully reimplementable from disk: the format is specified byte-for-byte in §33.3.2 and the CLI only ever reads/deletes lockfiles. afleet can write one for *interactive* CLIs launched from its terminal, but it does nothing for its own headless child. |
| Stale-lockfile sweep (`pid` liveness, 500 ms TCP probe) | Runs once before each discovery loop (§33.5) | none | X/T | Housekeeping only; no user-visible effect a GUI needs. |
| Workspace-validity + ancestor-PID check | A lockfile is valid only if cwd is inside `workspaceFolders`; inside an IDE terminal the IDE pid must be `ppid` or one of 10 ancestors (§33.4, §33.4.1) | none | T | Terminal-parentage logic; meaningless for a GUI that *is* the IDE. |
| `/ide` picker dialog ("Select IDE" / "Connect to an IDE for integrated development features." / `None`) | `local-jsx` dialog listing valid IDEs, workspace-folder descriptions, "Only one Claude Code instance can be connected to VS Code at a time.", 35 s connect timeout (§33.9.2–33.9.3) | Command absent from `slash_commands` (verified in init dump); `local-jsx` is refused headless (SPEC 28 §22) | X | A GUI that is itself the editor has no use for the picker; the equivalent affordance is afleet's own connection state. |
| `/ide open` (open project in an IDE) | Discovery → picker → runs `<code|cursor|windsurf> <path>`; prints `Opened project in <IDE>` (§33.9.1 A) | none | X | A GUI can shell out to the same CLI itself (exceeds: it knows its own project path). |
| Auto-connect opt-in dialogs ("Do you wish to enable auto-connect to IDE?" / "…disable…") | Shown once when `!XH()`, writes `autoConnectIde` + `hasIdeAutoConnectDialogBeenShown` (§33.8.4) | none | X | Config keys live in `~/.claude.json`; a GUI can read/write them but they have no headless effect. |
| Extension auto-install (`<cli> --force --install-extension anthropic.claude-code`), `Installed extension to <IDE>` / `Installed plugin to <IDE>` messages | Runs at startup for VS Code-family terminals; sets `diffTool: "auto"` on first success (§33.10.1–33.10.2) | none | X/T | Not applicable: afleet is the editor. |
| IDE onboarding dialog ("✻ Welcome to Claude Code for <IDE>", `Cmd+Esc`, `Cmd+Option+K`, "+11 -22" badge) | Once per terminal identity, keyed by `hasIdeOnboardingBeenShown[<terminal>]` (§33.10.3) | none | X | afleet writes its own onboarding. |
| Diff-in-editor for `Edit`/`Write` permission (`openDiff` racing the terminal dialog) | With a connected `ide` client and `diffTool: "auto"`, the harness opens a diff tab named `✻ [Claude Code] <basename> (<6 hex>) ⧉` **in parallel** with the terminal permission dialog; whichever answers first wins; `FILE_SAVED`→saved content, `TAB_CLOSED`→proposed content, `DIFF_REJECTED`→deny "User denied via IDE"; accept is always a one-time allow with rewritten `old_string`/`new_string` (§33.14) | Not reachable: the racer is started from the permission **dialog's** `onRacersReady` callback (`chunk-ht9kfnjn.js:548944`, reached only through `xGe`, the dialog-ask path at `chunk-bq8epagv.js:428295` / `chunk-hyfr0y0c` teammate path). The SDK ask path is `createCanUseTool` (`chunk-zjj1wsm3.js:851366`, SPEC 24 §24.16.1), which never calls `xGe`. | X → R | **Key answer to the brief's question:** the CLI does *not* open a diff itself when a host answers `can_use_tool`; there is no before/after interleaving to worry about. The functional equivalent is entirely in the GUI's hands and is strictly better: `can_use_tool` accepts `{behavior:"allow", updatedInput}`, which is the same power `FILE_SAVED` gives the extension (return the user-edited content), plus `{behavior:"deny", message}` for the reject case. afleet renders its own diff editor and returns `updatedInput`. |
| Terminal dialog title change "Opened changes in <IDE> ⧉" + "Save file to continue…" | §33.14.2 | n/a | T | Superseded by the GUI's own diff UI. |
| `closeAllDiffTabs` at every turn start | §33.13.1 | n/a | T | |
| `mcp__ide__getDiagnostics` (model-visible) | Model may call it when an `ide` client is connected (§33.11.2) | Only if the host injects an `sse-ide` MCP server; then it is an ordinary MCP tool over the wire | R | Optional. afleet can expose its own diagnostics as an SDK MCP server (`initialize.sdkMcpServers` + `mcp_message`) instead — no lockfile, no transport, and it works headless. That is the recommended route. |
| `mcp__ide__executeCode` (model-visible; dropped in restricted mode) | §33.11.2, §33.17 | same as above | R | |
| Selection context → `selected_lines_in_ide` attachment ("The user selected the lines <a> to <b> from <file>: …", content truncated at 2000 chars) | Driven by the IDE's `selection_changed` notification; 0-based→1-based conversion; main thread only; suppressed for denied paths (§33.12.1–33.12.2) | The subscription `Cpe(clients, onSelection)` is a REPL React hook (`chunk-bq8epagv.js:397480`), and for remote sessions the notification wiring is fed an empty client list (§33.11.3) | R | afleet already owns the editor's selection. It should inject the same context as text (or its own tagged block) in the `user` stdin frame. The verbatim TUI wording is in §33.12.2 and is worth copying so model behaviour matches. Exceeds: a GUI can attach *multiple* selections, or a live selection that updates per turn. |
| Opened-file context → `opened_file_in_ide` attachment ("The user opened the file <f> in the IDE…"), also loads nested `CLAUDE.md` for that path | §33.12.3 | Not emitted headless (same hook) | R | Same: prepend it to the prompt. Note the side effect the TUI gets for free — nested memory loading for the opened file's directory chain; a GUI reproducing this must decide whether to care. |
| Footer selection indicator `⧉ N lines selected` / `⧉ In <file>` / `· disconnected` / `· reconnecting…` | §33.15.1 | none | R | Pure client-side chrome; afleet renders its own. |
| Editor "send to Claude Code" → `@relative/path#L12-30 ` inserted into the composer | Driven by the IDE's `at_mentioned` notification; insertion text built by `Z6e` (§33.12.4) | Not emitted headless (hook) | R | afleet types the same `@path#L12-30` text into its composer; the CLI's `@`-mention resolution then works normally on the wire (ch. 42/15). This is the cheapest high-value copy. |
| IDE diagnostics after edits (`diagnostics` attachment, `<new-diagnostics>` block, per-file baseline before each Edit/Write, 500 ms/2000 ms deadlines, 4000-char cap) | §33.13 | The attachment is a **meta** message and, in the TUI, "never appears as user-visible text" (§33.13.5). Headless: filter `Cu` passes only three attachment kinds to the wire (`queued_command`, `tool_host_result_lines`, `hook_system_message`) — a `diagnostics` attachment is dropped (SPEC 45 §45.9.2) | D (invisible in TUI too) | Neither surface shows it to a human; both feed it to the model. If afleet wants a diagnostics banner it must compute diagnostics itself; there is no frame carrying them. |
| `/status` IDE row (`Connected to <IDE> extension version <v>`, `✗ Not connected to <IDE name>`, install-error text) | §33.15.3 | `/status` is absent from headless `slash_commands` (verified) | X/R | afleet renders its own connection state. `mcp_status` control request reports MCP servers, so an injected `ide` server would appear there. |
| Notifications `<IDE> disconnected`, `IDE extension install failed (see /status for info)` | §33.15.2; both suppressed in non-interactive sessions | none | X | |
| Tips ("Connect Claude to your IDE · /ide", "Open the Command Palette … to enable IDE integration") | §33.15.4 | Tips are TUI-only | T | |
| `/config` rows: `Diff tool` (terminal/auto), `Auto-connect to IDE (external terminal)`, `Auto-install IDE extension` | §33.16.2 | `/config` exists headless as a `local` command (present in init dump) but these rows are IDE-conditional TUI rows; the underlying keys live in `~/.claude.json` | R | Readable/writable from disk; no headless effect. |
| Manual reconnect refusal ("The IDE connection is managed automatically and can't be reconnected manually") | §33.7.5 | `mcp_reconnect` control request would hit the same refusal for the `ide` server | P | Only matters if afleet injects an `ide` server. |
| `/clear` tears down the IDE connection | §33.7.5 | n/a headless | T | |
| Managed policy: `permissions.deniedMcpServers` naming `ide` blocks integration; `allowedMcpServers` is ignored for this transport | §33.17 | Same rule applies to an injected `sse-ide` server | P | Enterprise users can block afleet-as-IDE by denying the server name. |
| `claude-vscode` SDK host channel (`log_event` inbound, `experiment_gates` outbound) | §33.19.1 | This is the *other* surface: the CLI as an SDK child of an editor. Reachable headless — it is an MCP server named `claude-vscode` with transport `sdk` | P/R | afleet could register an SDK MCP server named `claude-vscode` and receive `experiment_gates` plus route `tengu_feedback_survey_event` / `auto_default_nudge_*` callbacks. Gated on `CLAUDE_CODE_ENTRYPOINT=claude-vscode`, which also flips `hasInteractiveUI` to true (SPEC 45 §45.30.5) — that has side effects (artifact auto-open, publish context) afleet should weigh before setting it. |
| `sH()` file-changed notifier | Dead code: reads the `claude-vscode` client and returns; called after every `Edit`, `Write`, in-place `sed`, and file-history rewind (§33.19.2) | none | D | The intent — "tell the editor host that the CLI changed a file on disk behind its back" — is real and unserved. afleet must detect file changes itself (watch the filesystem, or drive off tool results for Edit/Write/Bash), because no frame announces "this path changed". |

### 33.2 The exact IDE-side surface a GUI must implement (for the record)

If afleet still wants to register as an IDE in v1.1 — which only helps *interactive* `claude`
processes it spawns, not its own headless child — the complete contract is:

**Discovery.** Write `~/.claude/ide/<port>.lock` (directory mode `0700`) containing
`{"workspaceFolders":[<abs paths>],"pid":<editor pid>,"ideName":"afleet","transport":"ws",
"runningInWindows":false,"authToken":"<secret>"}`. The port comes from the filename, not the
JSON. `transport` must be exactly `"ws"` for WebSocket; anything else means SSE (§33.3.2).

**Transport.** Either `ws://127.0.0.1:<port>` with subprotocol `mcp` and the request header
`X-Claude-Code-Ide-Authorization: <authToken>`, or `http://127.0.0.1:<port>/sse` **with no
auth at all** (`authToken` exists only on `ws-ide`; §33.7.2). Negotiate the **legacy** MCP
protocol era — on a modern-era connection the CLI skips registering handlers for
`selection_changed`, `at_mentioned` and `log_event` (§33.7.3).

**Handshake.** Right after `initialize` the CLI sends the one-way notification
`{"method":"ide_connected","params":{"pid":<cli pid>}}` (§33.7.4).

**Tools the CLI calls** (§33.11.1): `openDiff({old_file_path,new_file_path,new_file_contents,
tab_name})` — long-lived, must not return until the user saves/closes/rejects, answering
`[{type:"text",text:"FILE_SAVED"},{type:"text",text:"<content>"}]` or `["TAB_CLOSED"]` or
`["DIFF_REJECTED"]`; `close_tab({tab_name})`; `closeAllDiffTabs({})`;
`getDiagnostics({uri:"file://<abs>"} | {})` returning one text block whose JSON is
`DiagnosticFile[]` (`uri` may be `file://`, `_claude_fs_right:` or `_claude_fs_left:`).
Optionally advertise `executeCode` — every other tool is hidden from the model by the
`mcp__ide__` filter (§33.11.2).

**Notifications the IDE sends** (§33.11.3): `selection_changed
{selection:{start:{line,character},end:{line,character}}, text, filePath}` (0-based; the CLI
converts and decrements `lineCount` when `end.character === 0`), `at_mentioned
{filePath,lineStart,lineEnd}` (0-based), `log_event {eventName,eventData}` (re-emitted as
`tengu_ide_<eventName>` telemetry).

**What this does not buy in a headless session:** every consumer of `selection_changed`,
`at_mentioned` and the diff race lives in the interactive REPL/dialog layer (§33.8.3,
§33.11.3, §33.14.2). An injected `ide` MCP server in headless gets you the two model-visible
tools and nothing else. The IDE-diagnostics collector (`handleQueryStart` →
`beforeFileEdited` → `getNewDiagnostics`) hangs off the query runner and would plausibly
still run, but its output is an attachment the wire drops (see the table) — so it would be
invisible to afleet either way.

---

## 34. LSP

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| LSP servers come only from plugins (`<pluginRoot>/.lsp.json`, manifest `lspServers`) | §34.3; no settings key, no CLI flag (§34.3.4) | Identical — plugin loading is not TUI-specific | P | Nothing for afleet to do beyond letting users install LSP plugins; the official catalogue is twelve marketplace plugins (§34.22). |
| `LSP` tool (9 operations: goToDefinition, findReferences, hover, documentSymbol, workspaceSymbol, goToImplementation, prepareCallHierarchy, incomingCalls, outgoingCalls) | §34.17; deferred (`shouldDefer`), reachable through `ToolSearch`; `isEnabled` is the latching `hasEverConnected()` | Same tool, same schema; appears in the model's tool list on the same conditions | P | The GUI sees ordinary `assistant` tool_use / `user` tool_result frames. |
| Tool-use header line (`operation: "goToDefinition", symbol: "foo", in: "src/x.ts"`) | Built by `renderToolUseMessage`, which reads the file itself to name the symbol under the cursor (§34.17.8) | Not on the wire — `renderToolUseMessage` is a TUI-side member | R | Trivial to rebuild from the tool input (`operation`, `filePath`, `line`, `character`); the symbol-extraction nicety needs a 64 KiB read of the file (regex `/[\w$'!]+|[+\-*/%&|^~<>=]+/g`, 30-char cap). |
| LSP result text (`Found 3 references across 2 files: …`, `Defined in <path>:<line>:<col>`, hover blocks, symbol trees) | §34.18; every failure path returns a **successful** result whose string describes the problem — the tool never emits `is_error` | Identical string arrives in the `tool_result` content | P | afleet should not treat "No LSP server available for file type: .rs" as an error frame; it is a success. |
| Diagnostics after `Edit`/`Write` (`didChange`+`didSave` fire-and-forget, `publishDiagnostics` collected, dedup, ≤10/file ≤30 total, delivered on the **next** turn's attachment pass) | §34.13.6, §34.15, §34.16.1 | The `diagnostics` attachment is dropped by the headless filter `Cu` (SPEC 45 §45.9.2) — only `queued_command`, `tool_host_result_lines` and `hook_system_message` attachments become wire frames | D | Same as the IDE path: the model sees `<new-diagnostics>…`, the host sees nothing. Note the TUI does not display it either (attachments render into model-facing system-reminders, SPEC 11 §11.8.3) — so this is not a *parity* gap with the terminal, it is an absolute gap. A GUI wanting a "3 new errors after that edit" banner must run its own LSP client. |
| `<new-diagnostics>` block format (basename-only headers, 1-based positions, `✘/⚠/ℹ/★` glyphs, `[code]`, `(source)`, 4000-char cap) | §34.16.3–34.16.4 | not on the wire | D | Documented here only so a GUI that *does* run its own LSP can present the same information the model already has, and not double-report. |
| Attachment gate: requires `Bash` or `PowerShell` in the session tool list | §34.16.1 | same gate | P | Worth knowing: an afleet agent profile without Bash silently gets no diagnostics into the model context. |
| `/lsp` status command | **Does not exist** — §34.19.1 states the exhaustive command scan finds no `lsp` entry | absent (confirmed: no `lsp` in the live init dump) | T/X | Nothing to port; a GUI showing LSP server state exceeds the TUI. |
| LSP setup issues (`setupIssues.lspFailedCount`, "N setup issue(s): LSP") | Polled every 5 s by the `lsp-initialization` app service; each failing server becomes a `generic-error` under source `lsp-manager`; the count only reaches a debug-log line (§34.19.1, and the chapter's own open question notes no render path was located) | none | D (minor) | The errors themselves surface through `/plugin` (local-jsx, unreachable headless). A GUI that wants "your rust-analyzer plugin failed to start" must parse `--debug` output — the subsystem logs exclusively through the debug logger (§34.20.4, prefixes `[LSP MANAGER]`, `[LSP SERVER <name>]`, `LSP Diagnostics: …`). |
| LSP extension-conflict warnings ("LSP server "x" is not used for .ts files — <owner> already registered…") | Produced before any spawn and rendered in the plugin error list (§34.6.4) | Plugin errors reach the wire only through `/plugin`-style surfaces; not emitted as a frame | D (minor) | Same workaround: debug log, or read the plugin manifests from disk. |
| LSP plugin recommendation dialog ("LSP plugin recommendation / Plugin: … / Would you like to install this LSP plugin?", options Yes/No/Never/Disable-all) | Offered at most once per session when the model touches a file type with no server and a marketplace plugin's binary resolves on PATH (§34.19.3) | It is a `request_user_dialog` of kind `lsp_recommendation` — reachable only if the host declares that kind in `initialize.supportedDialogKinds` | R→P | This is one of the few dialogs a GUI can genuinely *win*: declare `lsp_recommendation` in `supportedDialogKinds` and render a native card with the four options (`yes`/`no`/`never`/`disable`, default `cancelled`, `hideWhile: ["panel","draft"]`). Config keys `lspRecommendationDisabled`, `lspRecommendationIgnoredCount` (≥5 suppresses), `lspRecommendationNeverPlugins` live in `~/.claude.json`. |
| `/plugin` detail "LSP Servers" row; `claude plugin` CLI "LSP servers (2) gopls, pyright (out-of-process tooling; no model context cost)" | §34.19.5 | `/plugin` is local-jsx → unreachable; the `claude plugin` CLI is a separate process a GUI can shell to | X/R | afleet can render plugin inventory from `~/.claude/plugins/**` or the `claude plugin` CLI. |
| `/reload-plugins` cache warning ("This reload adds the LSP tool — your next message will re-read the whole conversation instead of using the cache. Run /reload-plugins --force to apply.") | §34.19.6 | `reload_plugins` is a control request the host can send; the warning text is TUI-composed | R | If afleet exposes a "reload plugins" button it should reproduce the warning: the classification (`adds`/`removes`/`may-add`/`may-remove`) is derivable from whether the LSP tool has ever connected and whether any enabled plugin declares servers. |
| Safe/bare mode disable (`--safe-mode`, `--bare`, `CLAUDE_CODE_SAFE_MODE`, `CLAUDE_CODE_SIMPLE`) | §34.2.2 | identical | P | |
| Remote gate (`CLAUDE_CODE_REMOTE*` + `tengu_moonlit_panda`) defers manager init | §34.2.3 | identical | P | |
| Server process is memory-capped (`CLAUDE_CODE_TOOL_MEMORY_LIMIT`, cgroup class `lsp`); OOM shows in the crash message | §34.9.1 | identical, but only in the debug log | P/D | |

---

## 43. Voice

Voice is the cleanest case in this area: it is **entirely unreachable headless** and entirely
replaceable by the GUI.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/voice [hold\|tap\|off]` | `type: "local"`, `availability: ["claude-ai"]`, **`supportsNonInteractive: false`**, `isHidden: !OMe()` (§43 §4.1) | Refused headless; absent from `slash_commands` (confirmed in the live init dump) | X | A `local` command runs headless only with `supportsNonInteractive: true` (SPEC 28 §22). |
| `/voice` success line ("Voice mode enabled (hold). Hold space to record. Dictation language: en (/config to change).") and the language-hint counter (max 2 per language) | §43 §4.4 | none | X | |
| `/voice` availability errors ("Voice mode requires a Claude.ai account…", org-policy sentences, "No audio recording tool found… brew install sox", "Microphone access is denied…") | §43 §4.2–4.5, §6, §14.1 | none | X | Only the *gating facts* matter to afleet: voice needs a claude.ai OAuth login on a first-party provider (`gl()`), org policy `allow_voice_mode`, and macOS microphone permission. |
| Push-to-talk key (`voice:pushToTalk`, default `space` in the `Chat` context), hold warm-up (2 repeats echo, "keep holding…", recording at 5 repeats), 200 ms release inference, `Escape` cancel, 300 ms double-tap-to-submit | §43 §7 | none — this whole machine exists because a terminal has no key-up event | X/T | A GUI has real key-down/key-up and needs none of it. Pure win. |
| Tap mode (tap to start, tap to stop+submit; 15 s silence, 120 s cap) | §43 §7.5, §8.12 | none | X | |
| Waveform / level meter (`" ▁▂▃▄▅▆▇█"`, gain 1.8, smoothing 0.7, 0.15 grey threshold, 50 ms frames, **drawn in the cursor cell**) | §43 §13.4 | none | X | Exceeds: a GUI can render a real waveform beside the composer. |
| Status indicators: `⏺ REC · tap to send`, dim `listening…`, pulsing `Voice: processing…`, dim `keep holding…` | §43 §13.1–13.3 | none | X | |
| Interim transcript painted into the composer, dimmed via `interimRange` (priority-1 dim highlight), replaced as it firms up; final spliced at the anchor; a user edit aborts insertion (`input_diverged`) | §43 §12.1–12.4 | none | X | The anchor/strip/expected-value dance is a terminal-buffer problem. A GUI composer with a real selection model does this natively. |
| Auto-submit (`voice.mode === "tap"` or `voice.autoSubmit`, and ≥3 words by `max(whitespace split, Intl.Segmenter word-like)`) | §43 §12.5 | none | X | Worth copying the 3-word floor verbatim: it is what stops a stray "yes" from firing a turn. |
| Footer hint `hold <key> to speak` (max 3 sessions), startup tip "Use /voice to enable push-to-talk dictation" (10-session cooldown) | §43 §13.5–13.6 | none | X/T | |
| Voice error surfacing: one immediate error-coloured notification, key `voice-error`, 10 s lifetime; plus the truncated `voiceError` line in the REPL chrome | §43 §12.6 | none | X | |
| Audio capture: native `audio-capture.node` (CoreAudio via cpal) first, SoX `rec -q --buffer 1024 -t raw -r 16000 -e signed -b 16 -c 1 -` fallback; **no silence effect** on the dictation path | §43 §5 | none | X | The loader is lazily imported when voice becomes enabled (§5, §8.3). afleet does its own AVFoundation capture. |
| Microphone permission: probed by starting and immediately stopping a throwaway native recording; macOS prompt text comes from the generated `ClaudeCode.app` bundle's `NSMicrophoneUsageDescription` ("Claude Code uses the microphone for voice dictation."), TCC keyed to `com.anthropic.claude-code` | §43 §6 | none | X | afleet has its own bundle id and its own usage description — and its own TCC grant, independent of Claude Code's. |
| Transcription transport: one WebSocket to `wss://api.anthropic.com/api/ws/speech_to_text/voice_stream?encoding=linear16&sample_rate=16000&channels=1&endpointing_ms=300&utterance_end_ms=1000&language=<code>&use_conversation_engine=true`, `Authorization: Bearer <claude.ai OAuth>`, `x-app: cli`, `anthropic-client-platform`, optional `x-config-keyterms`; frames `KeepAlive` / `CloseStream` up, `TranscriptInterim` / `TranscriptText` / `TranscriptEndpoint` / `TranscriptError` / `error` down | §43 §9 | Not exposed through the headless protocol in any form | X (D if afleet wants the *service*) | This is the one piece a GUI cannot trivially replicate: the endpoint is OAuth-only, first-party-only, and there is no control request that proxies it. afleet must either use the platform's own dictation (macOS `SFSpeechRecognizer` / `NSSpeechRecognizer`), a third-party ASR, or reimplement this WebSocket against the user's claude.ai OAuth token (which afleet does not hold — the CLI does). Practical recommendation: **native dictation into the composer**, which exceeds the TUI (no push-to-talk warm-up, real key-up, editable interim text, no 2000-char anchor logic). |
| Dictation language = the shared `language` setting (20 codes with endonym aliases; `/config` field "Enter your preferred response and voice language:") | §43 §10, §13.7 | `/config` is reachable headless as a `local` command, and `get_settings`/`update_settings` control requests read/write settings | P (the setting) / X (the voice use) | |
| Key terms (14 fixed terms + project dir basename + branch tokens, ≤50 terms, ≤1024 header chars — leaks local identifiers, no setting to suppress) | §43 §11 | none | X | Privacy note worth surfacing if afleet ever builds its own dictation against the same endpoint. |
| `audio_transcript` attachment ("The user @-mentioned the audio file X. Claude Code transcribed it…", `<audio-transcript filename= duration=>`) and its transcript row | §43 §16 | **This build ships only the consumer half** — nothing constructs the attachment, and `@voice.m4a` today resolves to a `Read` binary-file rejection and is silently dropped (§16.5) | D → opportunity | Documented contract for an attachment *supplied from outside*. afleet could transcribe an attached audio file itself and inject the transcript as text; it cannot make the CLI produce the attachment. |

---

## 44. Artifacts and Claude Design

### 44.0 Correction on two frames named in the brief

`code_change_published` and `vcs_state_changed` are **not** artifact frames. They are emitted
by the Bash git/gh classifier (SPEC 47 §47.7.3): `vcs_state_changed
{kind: commit|push|merge|rebase, branch?, cwd}` per detected change, and
`code_change_published {provider, url, repo, identifier, action}` only when a PR URL passes a
strict host/shape allowlist. Neither is shown to the model and neither appears in the REPL —
they exist *for* SDK hosts. One `code_change_published` with `action: "started"` is emitted at
SDK `initialize` when the entrypoint is Claude Desktop and the session start type is `fresh`
(§47.7.3). Artifact publishes produce no dedicated frame at all; the publish result arrives as
an ordinary tool result.

### 44.1 Artifacts

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `Artifact` tool (publish/list/read + gated actions) | §44.8; shipped action enum with no gates is exactly `publish, list, read, watch, unwatch, status, upload_asset, list_assets, read_asset, delete_asset` (§44.5.2) | Identical — the gate snapshot is environment/statsig-driven, not TUI-driven | P | The enum, the field set *and* the prompt are rebuilt from one gate snapshot frozen at first schema build (§44.5.3); afleet must not assume a fixed action list. |
| `ArtifactComments` / `ArtifactData` / `ArtifactCheck` add-on tools (toolset mode, latch `CLAUDE_CODE_ARTIFACT_TOOLSET` / `tengu_cobalt_plinth_damson`, default off) | §44.7 | Identical; all three are `shouldDefer` and report `userFacingName() === "Artifact"` | P | If afleet groups tool cards by `userFacingName`, all four collapse into one "Artifact" lane, which is what the CLI intends. |
| Publish approval card ("Claude wants to publish <subject>, uploading it to claude.ai (Anthropic's servers) to host as the page "<title>" …") | §44.12.5; composed in `checkPermissions` | Arrives as the `can_use_tool` request's `description` / ask message; the same text | P | afleet renders it as a permission card. Ownership/audience clauses, "(its other published files stay)" and the room-disclosure clause all come through as text. |
| "Redeploy of an artifact already published this session" (no prompt) | §44.12.5 | identical | P | |
| Reasons that bar the auto-mode classifier (`classifier_approvable: false`): ownership-unconfirmed reads, `verify`, `room_send`, `delete`, symlinked publish bases, plan-mode publishes | §44.27.3 | `can_use_tool` carries `classifier_approvable` (SPEC 24 §24.16.1) | P | afleet should surface "this one needs you" rather than auto-approving. |
| Plan-mode refusals when no human can answer (publish / write_db / resolve / delete / reads / page-data) | §44.27.1; predicate `jH(ctx)` is **permission-mode** based (`mode !== "bypassPermissions"`, not `plan`+bypass), not interactivity-based (`chunk-j5tremg8.js` via `chunk-4bkx7jf6`) | Same in headless: a host answering `can_use_tool` counts as a consent surface, so these refusals fire only in plan mode with bypass, or when `shouldAvoidPermissionPrompts` is set — and that flag is *not* set when the host provides `requestDialog` (`chunk-1kg58a1a.js:98337`) | P | Actionable: afleet declaring dialog support keeps artifact publishing available from plan mode instead of hitting "no one can answer the prompt in this session". |
| Publish result (url, version, audience, warnings, `liveSubscription`, `verifyGuide`, type refs) | §44.11 | `user` frame `tool_use_result` carries the tool's full Output object (SPEC 45 §45.12.2) | P | Caveat: the artifact family declares `stripToolUseResultAtCreation` + `stripForStorage` (§44.8.1, SPEC 14 §14.4.7), so `read.result` and every comment body are blanked in the stored/emitted result object. The model-facing text block still carries the content. afleet should read the text block, not the structured field, for page HTML and comment bodies. |
| Conflict / stale-guard rejection, live content handed back under `[Artifact <ver> — live version; raw HTML follows]`, `force:true` advisory | §44.13.3 | same strings in the tool result | P | |
| Deleted-artifact notice `<artifact-deleted url=…/>` injected as a meta user message when the user deletes from `/artifacts` | §44.13.3 | Meta attachment → dropped by the headless filter | D (small) | Only matters if afleet implements its own artifact browser with delete; it must then inject an equivalent note as a `user` message so the model stops using the URL. |
| `/artifacts` browser (gallery, search, rename, pin, delete, attach; keys `o` open, `c` copy, `d` delete, `p` pin, `r` refresh, Enter attach) | §44.33 | `local-jsx` → unreachable; absent from headless `slash_commands` (confirmed) | X → R | Fully rebuildable: the data is four documented endpoints (`GET /api/frame/frames?limit=200`, `POST /api/frame/retitle/<slug>`, `POST|DELETE /api/frame/favorite/<slug>`, `DELETE /api/frame/<slug>`) — but they need the user's claude.ai OAuth bearer plus the five `X-Frame-*` headers (§44.36.5), which afleet does not hold. Practical alternative: drive the model's own `Artifact` tool (`action: "list"`, `delete`) and render the results — the tool result is on the wire. A GUI gallery with thumbnails exceeds the TUI list. |
| Published-artifact link card in the REPL chrome (`frameUrls` app state, `←/→ to navigate`, `Enter to open`, `x to dismiss`, `/artifacts to see all`), `ctrl+]` reopens the session's most recent artifact | §44.33.3 (`chunk-bq8epagv.js:408290`), §44.38.2 | Not a frame; app state only | R | Rebuild from publish tool results: collect every `url` the Artifact tool returns this session. |
| Auto-open of a freshly published page in the browser (with `?via=auto_preview`) | Deferred surface, then `ai()` opens the URL — gated on `hasInteractiveUI` and skipped in bg/teammate/remote/desktop/vscode contexts (`chunk-j5tremg8.js:554286-554330`) | `hasInteractiveUI` is false for a bare `-p` session and the publish context is `print` (SPEC 45 §45.30.5), so **nothing auto-opens** | R | afleet decides its own policy (open in its own web view is the obvious win). `CLAUDE_CODE_ARTIFACT_AUTO_OPEN` falsy suppresses it entirely. |
| Read of an artifact (own → raw HTML inline or spilled to disk; someone else's → isolated summary steered by `prompt`) | §44.15 | identical | P | |
| Read permission surface (allow reasons "Reading the user's own artifact", ask subjects "another person's artifact" / "an artifact whose ownership couldn't be confirmed", "approving covers re-reads … for the rest of the conversation") | §44.15.2 | via `can_use_tool` | P | |
| Comment threads: read / reply / resolve, activation model, "sent to you" labels, duplicate-reply protection | §44.16 | identical tool results | P | Comment bodies are blanked in the stored result object (`stripForStorage`) but present in the text block. |
| Comments permission surface (silent allow for reads; ask when prompted by the new-comments notification; plan-mode resolve refusal) | §44.16.6 | via `can_use_tool` | P | |
| Unattended auto-replies / auto-edits (gated `CLAUDE_CODE_ARTIFACT_COMMENTS_AUTOREACT` / `tengu_sorrel_trellis`, default off), pause on Ctrl+C, `resume_replies` consent cards | §44.16.7, §44.17.5 | The three `resume_replies` ask bodies arrive as permission asks; the "user interrupted with Ctrl+C / Stop" pause maps to `interrupt` control requests | P/R | If afleet has a Stop button it is the Ctrl+C equivalent and will pause auto-replies the same way; the "resume" path then asks. |
| Watches, three rails (`none` / `live` behind `tengu_slate_lantern` / `durable` under `CLAUDE_CODE_REMOTE`), frozen per session; user can see and stop live watches in `/tasks` | §44.17 | Rails behave identically; `/tasks` is unreachable (local-jsx, absent from init dump), but `background_tasks` control request + `background_tasks_changed` frames expose the same task list | R | afleet's task panel should include artifact watches; the wire carries them. |
| Durable wake subscriptions via the `watch_url` MCP tool + `POST /api/frame/subscribe/<slug>` | §44.18 | Requires a first-party MCP server offering `watch_url`; unchanged headless | P | Only relevant for cloud/remote sessions. |
| Artifact database (`read_db` / `write_db`, gated `tengu_umber_lattice`, default off), consent cards ("Claude wants to edit this artifact's data.") | §44.19 | via `can_use_tool` | P | |
| Asset store (`upload_asset` / `list_assets` / `read_asset` / `delete_asset`, **on by default**), "every delete asks separately" | §44.20 | identical | P | Local writes from `read_asset`/`read_file` follow the scratchpad rule: default destination needs no approval, any other directory asks. |
| `verify` (viewer runtime diagnostics, owner-only, gated `tengu_osier_pylon_trace`, forced off under `CLAUDE_CODE_REMOTE`) | §44.23 | identical | P | |
| `preview` (local headless-Chrome render harness, CSP lock-down, DNS `MAP * ^NOTFOUND`, screenshots) | §44.24 | **Not compiled into 2.1.257** — `MLt()` is unconditionally false; throw-site "artifact preview is not compiled into this build" | X (both surfaces) | Do not build a UI for it. Same for live rooms, live edit (`sync`/`version`), page handlers and `read_page_data` (§44.5.1). |
| Artifact types (`list_types` / `describe_type` / create-from-type, `auto_open`) | §44.25 | identical, gated off by default | P | |
| `delete` (gated `tengu_cobalt_plinth_alder`, off by default; every delete asks; plan mode refuses) | §44.26.1 | identical | P | The "self-delete advice" string literally teaches the user about `/artifacts` + `d` — afleet should substitute its own gallery affordance in its UI copy, but cannot change the model-facing string. |
| `open` action (show an artifact in the user's viewer) | §44.26.2, gated off | identical | P | |
| `/config` row "Artifacts" (writes `enableArtifact` to user settings, clears `disableArtifact`) | §44.35.2 | `get_settings` / `update_settings` (localSettings only) control requests, plus direct settings-file writes | R | afleet renders its own toggle; note `update_settings` is limited to local settings, so a user-scope write needs a file edit. |
| Chart.js and highlight.js vendored bundles | Inlined into the published page at publish time, behind sentinel comments, each guarded by a safety scan (§44.12.3, §44.31.2). Chart block only when the page carries `data-chart-runtime`; hljs runs a budgeted pass over `pre>code` (50 000/250 000/4 096 budgets) | Same — this is server-bound page composition, not rendering in the client | P | Neither bundle is ever fetched over the network and neither renders in the terminal. Nothing for a GUI to do. |
| Mermaid vendored bundle | **Not** inlined into published pages (published artifacts render mermaid natively); served only by the local preview harness at `/_runtime/mermaid-11.16.1.min.js` (§44.12.3, §44.31.2) — and that harness is compiled out | n/a | X | This closes the loop with ch. 41's "mermaid is not rendered": the CLI ships `modules/mermaid.min.js` purely for a preview feature that does not exist in this build. A GUI rendering mermaid in the transcript is a clean *exceeds*, with no CLI behaviour to match. |
| Workshop lane (`*.workshop.md` / `*.workshop.html`, decision island, `read_page_data`, three banner states, 27-rule direct-HTML verifier) | §44.30 | Gated by `tengu_gable_onyx_sluice` (off) and `read_page_data` is compiled out (`hr` is constant false) | X (this build) | Documented for completeness; nothing to render today. |
| Embedded artifact skills (`artifact-design`, `artifact-diagramming`, `artifact-capabilities`, `workshop`, `doc`, …) | §44.32 | Skills are wire-visible through `system/init` and the Skill tool | P | Several are constant-false in this build (`plan-artifact`, `prototype`, `whiteboard*`, `artifact-pr-review`, the four page templates). |
| Artifact enablement (`enableArtifact` five-layer resolution, first-party provider only, `tengu_cobalt_plinth`, org policy `allow_cobalt_plinth`, claude.ai login) | §44.3 | identical | P | The login-error sentences ("Artifacts need a claude.ai login. Run /login and select "Claude account with subscription"…") arrive as tool results; afleet should link its own login flow (`claude_authenticate` control request) from that string. |

### 44.2 Claude Design

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/design consent \| revoke` (hub `local` command, `policyGate: allow_design_sync`, `supportsNonInteractive: true`) | §44.34.2; success lines "Design agent access granted…" / "…revoked…" | **Works headless** — present in the live init dump with description "Grant or revoke Claude agent access to your Design projects", argumentHint `consent | revoke` | P | Output arrives as `local_command_output` / informational frames. afleet can expose it as a menu item. |
| `/design-consent`, `/design-revoke` (hidden one-line adapters) | §44.34.2 | Present in the init dump (hidden in the TUI, still invocable) | P | |
| `/design-login` (`local-jsx`, browser OAuth with manual code paste, states starting → waiting → processing → success/error) | §44.34.7 | `local-jsx` → refused; **absent** from the init dump | X | The precondition message says it plainly: "DesignSync needs design-system authorization, and /design-login cannot run in this non-interactive session. Ask the user to run /design-login once from an interactive Claude Code session on this machine — headless and SDK runs here then reuse that authorization." afleet must either (a) tell the user to run `claude` interactively once, or (b) drive the same OAuth itself (client id `59637612-477b-4836-a601-b0589eda7704`, scopes `user:design:read`/`user:design:write`, PKCE S256, loopback `http://localhost:<port>/callback`) and write the `designOauth` slot into the same secure store — the credential lives beside `claudeAiOauth` in `~/.claude/.credentials.json`/keychain (§44.38.1). Option (b) is a real integration win but touches credential storage. |
| `/design-sync` (bundled skill; runs the Storybook/package converter and uploads) | §44.34.2 | Present in the init dump with its full description | P | The 24-module `design-sync` worker set ships embedded (§44.31.3); it runs as ordinary Bash/tool work whose output the GUI sees. |
| Design consent card ("Connect to Claude Design? Claude can read and edit your Design projects from this tool. Change anytime at claude.ai/design/settings or with /design revoke.") | §44.34.3 — the entire consent text a user ever sees | Delivered through the permission path (for the MCP-connector route it is built with `localDisplayOnly: true`, `classifier_approvable: false`) | P | Consent is **server-side only** — no settings key, no file. A GUI cannot cache or pre-answer it. |
| `DesignSync` tool + the durable per-project write grant ask ("Approving writes the listed files now, and lets Claude write to ANY file in the project "<name>" (<sharing>) … until you revoke it in settings at claude.ai/design. Deletes and CLAUDE.md/.claude paths still ask every time.") | §44.34.5–44.34.6 | via `can_use_tool`; carries `serverApprovalWatch: {kind:"design_project_grant", projectId}` which drives an out-of-band approval poller | P/R | The sharing labels (`private: invited members only`, `visible to your whole organization`, `PUBLIC`) are load-bearing in the card; afleet should render them prominently. |
| 15-minute plan-token clause ("Approving also lets writes and deletes to exactly these paths run without another prompt for up to 15 minutes…") | §44.34.3 | same text in the ask | P | |
| Tokenless-write denial through a user-configured design MCP connector ("writing without a plan_token is available only through the native Claude Design tool…") and sharing-widening cache withdrawal | §44.34.4 | identical (MCP client path) | P | |
| `ClaudeDesign` canvas tool + the `/design` canvas skill ("Draft a design on a canvas Artifact…", 2.4 MB `payload.template.html.asset`) | §44.34.5; hub gated on `tengu_omelette_fouet` (off), canvas skill gated on `tengu_ethereal_nova` (**on**) + capabilities | Skill availability is wire-visible; tool calls are ordinary frames | P | With the hub gate off, only the consent/revoke dispatcher exists — which is exactly what the live init dump shows. |
| Design errors ("Claude Design rejected this session's claude.ai credential (HTTP 403)… Run /design login…", "DesignSync is only available with claude.ai authentication…", "DesignSync is unavailable while nonessential network traffic is restricted…") | §44.34.5–44.34.6 | same strings in tool results | P | These are the strings afleet should pattern-match to offer a login button. |

---

## Top gaps in this area

Ranked by impact on afleet's "equal or better than the terminal" goal.

1. **Diff-in-editor is not a protocol feature — and does not need to be.** The IDE diff race
   is started from the interactive permission *dialog* (§33.14.2, `chunk-ht9kfnjn.js:548944`
   reached only via `xGe`), never from the `can_use_tool` path. The CLI will not open a diff
   before or after asking the host. afleet must render its own diff in the permission card and
   return `{behavior:"allow", updatedInput}` — which is exactly as expressive as the
   extension's `FILE_SAVED` reply, and better, because it also carries `updatedPermissions`.
   **Registering as an IDE in v1.1 would not deliver this**; it only helps interactive `claude`
   processes afleet might spawn.
2. **Selection and open-file context must be injected by the GUI.** `selected_lines_in_ide`
   and `opened_file_in_ide` come from REPL-mounted subscriptions to the IDE's
   `selection_changed` notification (§33.12.1–33.12.3); nothing on the wire carries them.
   Rebuild: prepend the verbatim §33.12.2/§33.12.3 wording (with the 2000-char truncation) to
   the `user` stdin frame. Cheap, high value, and afleet can exceed the TUI (multiple
   selections, per-turn refresh).
3. **`@`-mention insertion from the editor is trivially reproducible.** `at_mentioned` →
   `@relative/path#L12-30 ` (§33.12.4). Typing that string into the composer gets the CLI's
   whole mention pipeline for free. Do this before anything else IDE-related.
4. **Diagnostics after edits reach the model but never the host.** Both the IDE path
   (§33.13.5) and the LSP path (§34.16) produce a `diagnostics` attachment, and the headless
   filter `Cu` passes only three attachment kinds (SPEC 45 §45.9.2). The TUI does not display
   them either, so this is not a parity gap — but a GUI that wants an "N new errors" banner
   must run its own language server. No protocol addition would help short of a new frame.
5. **No frame announces that a file changed on disk.** The `sH()` no-op (§33.19.2) is the
   vestige of exactly that notification, called after every `Edit`, `Write`, in-place `sed`
   and file-history rewind. afleet must watch the filesystem or infer changes from tool
   results, or its editor views will go stale behind the agent's back.
6. **`/artifacts` is unreachable and its endpoints need a credential afleet does not hold.**
   `local-jsx` (§44.33), confirmed absent from the live init dump. The realistic rebuild is to
   drive the model's `Artifact` tool (`action: "list"` / `delete`) and render the results,
   not to call `/api/frame/frames` directly (that needs the claude.ai bearer plus five
   `X-Frame-*` headers, §44.36.5).
7. **`/design-login` cannot run headless, and Design work stops without it.** `local-jsx`,
   absent from the init dump; the CLI's own precondition text tells the user to run it once
   from an interactive session (§44.34.6). afleet must either shell out to an interactive
   `claude` for that one command, or implement the OAuth flow itself against the documented
   client id and write the `designOauth` credential slot (§44.34.7, §44.38.1).
8. **Voice is entirely unreachable and entirely replaceable.** `/voice` is `local` with
   `supportsNonInteractive: false` (§43 §4.1), absent from the init dump; every indicator,
   the push-to-talk warm-up machine and the interim-painting anchor logic are terminal
   workarounds (§43 §7, §12, §13). A GUI doing native dictation into its composer exceeds all
   of it — with the single caveat that Anthropic's transcription WebSocket (§43 §9) is
   OAuth-only and not proxied by any control request, so afleet supplies its own ASR.
9. **Publish approvals arrive intact; declare dialog support to keep plan-mode publishing
   alive.** The artifact consent-surface predicate is permission-mode based, not
   interactivity based (§44.27.1); `shouldAvoidPermissionPrompts` is *not* set when the host
   provides `requestDialog` (`chunk-1kg58a1a.js:98337`). Declaring dialog kinds in
   `initialize` therefore keeps publish/write_db/read_page_data available from plan mode
   instead of hitting "no one can answer the prompt in this session".
10. **`lsp_recommendation` is a dialog kind a GUI can win outright.** The TUI shows a four-option
    panel when the model touches a file type with no server (§34.19.3). Declare the kind in
    `supportedDialogKinds` and render a native install card; the config keys
    (`lspRecommendationDisabled`, `lspRecommendationIgnoredCount`, `lspRecommendationNeverPlugins`)
    are ordinary `~/.claude.json` fields.
11. **LSP has no status surface at all — an easy exceed.** There is no `/lsp` command
    (§34.19.1), the failure count only reaches a debug-log line, and server errors surface
    only through `/plugin`. A small "language servers: gopls running, pyright failed" panel in
    afleet is strictly more than the terminal offers; the data needs `--debug` parsing or
    reading plugin manifests from disk.
12. **Artifact tool results are partly blanked in the structured field.** The family sets
    `stripToolUseResultAtCreation` + `stripForStorage` (§44.8.1, SPEC 14 §14.4.7), so
    `read.result` and comment bodies are empty in `tool_use_result`; the content lives in the
    tool result's text block. A GUI reading only the structured field will show empty artifact
    reads.
13. **Five artifact subsystems are compiled out — do not build UI for them.** Live rooms, live
    edit (`sync`/`version`), page handlers, the Chrome preview harness and `read_page_data`
    all ship prompt text and schema branches but have `null` providers (§44.5.1). Same for the
    workshop lane, which depends on `read_page_data`.
14. **Mermaid ships but is never rendered by the CLI.** It is inlined into no published page
    and served only by the compiled-out preview harness (§44.12.3, §44.31.2). Rendering
    mermaid (and Chart.js specs) inside afleet's transcript is a free exceed with no CLI
    behaviour to match.
15. **`code_change_published` / `vcs_state_changed` are git frames, not artifact frames**
    (SPEC 47 §47.7.3). Wiring them to an artifact panel would be wrong; they belong to a
    commit/push/PR activity view, and `code_change_published` fires only for allowlisted PR
    URL shapes.

---

## Unverified

- **Whether the IDE diagnostics collector runs in a headless session at all.** Its
  `handleQueryStart` hook sits in the query runner (`chunk-bq8epagv.js:426429`, inside
  `_runImpl`); I did not establish whether `runHeadlessStreaming` drives that same class. It
  is moot for afleet — the resulting attachment is dropped by the wire filter either way —
  but the claim "diagnostics baselines never run headless" is *not* established.
- **Whether a host can actually inject an `sse-ide` MCP server headless.** `sse-ide` is in the
  `.mcp.json` transport enum (§33.7.1) and survives config expansion untouched
  (`cli.pretty.js:95249`), and `ide` is not in the reserved-name table used for user configs
  (SPEC 31 §4.3 — it is only in the built-in set `PAn` that hides it from listings). I did not
  test `mcp_set_servers` with such a config, nor confirm that its validator accepts the
  `sse-ide` shape.
- **Exactly which permission asks route through `xGe` versus `createCanUseTool` in a
  `--permission-prompt-tool stdio --permission-prompts host` session.** I traced the two
  callers of `xGe` (the REPL path at `chunk-bq8epagv.js:428295`, and a teammate path guarded
  by `if (T.requestDialog !== void 0)` at `chunk-m84am00s`-adjacent `cli.pretty.js:589693`)
  and the separate SDK path `createCanUseTool` (`chunk-zjj1wsm3.js:851366`). The conclusion
  that the IDE diff racer cannot fire for a host-answered permission follows from code
  structure, not from a live run.
- **Whether `ide`-server diagnostics or selection would work if a host injected the server**
  is inferred from where the subscriptions are registered (React hooks in
  `chunk-bq8epagv.js`), not tested.
- **The exact set of dialog kinds a host may declare.** I assumed `lsp_recommendation` and
  `ide_onboarding` are declarable in `initialize.supportedDialogKinds`; the brief states the
  mechanism, and the kinds are named in §34.19.3 and §33.10.3, but I did not verify the
  allowed-kind list in SPEC 45.
- **Voice transcription reimplementation feasibility.** I recorded the endpoint, query string
  and frame grammar from §43 §9; whether the token afleet could obtain (its own OAuth, or the
  CLI's stored `claudeAiOauth`) is accepted by that endpoint is untested and possibly
  against terms.
- **`BINARY_FILE_MAX_BYTES`, `MANIFEST_TOTAL_BUDGET`, `v7`, `SF`** artifact publish limits —
  the chapter itself flags these as unconfirmed (§44 Open questions); I did not re-derive
  them.
