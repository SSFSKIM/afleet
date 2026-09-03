<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# 30-29-32 · Plugins, marketplaces, skills, output styles — TUI-vs-headless gap inventory

Chapters covered: SPEC 30 (plugins and marketplaces), SPEC 29 (skills), SPEC 32 (output styles).
Cross-references to SPEC 45 (headless protocol) and SPEC 28 (slash commands) are marked as such.

**Two facts drive most classifications in this area, stated once here rather than repeated in
every row.**

1. **The GUI runs on the same machine as `~/.claude`.** Every plugin/skill/style registry the
   TUI reads is a file the GUI can read too: `~/.claude/plugins/known_marketplaces.json`,
   `installed_plugins.json`, `flagged-plugins.json`, `plugin-catalog-cache.json`,
   `marketplaces/<name>/.claude-plugin/marketplace.json` (30 §§8–9), `~/.claude/skills/**`
   (29 §22), `~/.claude/output-styles/**` (32 §32.4). Every mutation the TUI performs has a
   `claude plugin …` CLI twin (30 §25) the GUI can shell out to. So "R (rebuild)" in this area
   almost always means "read the registry files and/or shell out to `claude plugin`", never
   "reverse-engineer from the transcript".
2. **The live session does not notice disk changes by itself.** Whatever the GUI changes on
   disk only reaches the running `claude` process through the `reload_plugins` /
   `reload_skills` control requests (SPEC 45 §45.17; handlers at `cli.pretty.js:177681` and
   `:177706`). Both are available on stdio and both return a fresh inventory.

**Verified live against 2.1.259** (`/tmp/afleet-gap/init-dump.json`, zero-cost handshake): the
`initialize` control response carries `commands` (102 entries), `output_style`,
`available_output_styles`, `agents`, `models`, `account`. It does **not** carry `plugins`,
`skills`, `plugin_errors` or `supportedDialogKinds` — those live on `system/init`. Of the
commands in this area, `skill-doctor`, `reload-skills` and `config` are present headless;
`skills`, `plugin`, `plugins`, `marketplace`, `cloud-plugins`, `plugin-types`,
`reload-plugins` and `output-style` are all absent.

---

## 30 · Plugin model, settings and lifecycle (chapter 30 §§1–16)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Five-axis enablement model (registered / installed / materialised / enabled / permitted) | 30 §1 table; each "no" yields a distinct error | `system/init.plugin_errors[] = {plugin, type, message}` and `plugin_warnings[]` (SPEC 45 §45.13, `cli.pretty.js:448041`) carry the resulting diagnosis; the five axes themselves are on disk | P (errors) / R (axes) | The GUI can show a much better plugin health view than the TUI by joining `installed_plugins.json`, `known_marketplaces.json` and the merged `enabledPlugins` from `get_settings`. |
| `enabledPlugins` semantics: `true`/array = enabled, `null`/`false` = off; `inline` and `skills-dir` ids are **opt-out** (anything but `false` is on) | 30 §10.1 (`oP`, `m()` at `chunk-c1x3x6nm.js:435524`) | `get_settings` returns `{applied, effective, sources[]}`; `effective.enabledPlugins` and each scope's raw map are on the wire (verified live) | P (read) / R (write) | Writing is disk-only — `update_settings` accepts **only** `outputStyle` (32 §32.12.2). The GUI must write `settings.json` / `settings.local.json` itself and then call `reload_plugins`. Reproduce the opt-out rule or the GUI will mis-render `@inline`/`@skills-dir` toggles. |
| Settings precedence note surfaced in the schema description ("to disable a plugin that project settings enable, set it to false in `.claude/settings.local.json`") | 30 §10.1 | `get_settings.sources[]` gives the per-scope values, so the GUI can compute which scope wins | R | The TUI's `/plugin` detail pane turns this into the "enabled in `.claude/settings.json` (shared with your team) / disable it just for you?" confirmation (30 §27.6). A GUI should rebuild that confirmation; it is the single most confusing plugin interaction. |
| `pluginConfigs` (non-sensitive `userConfig` values) and `pluginSecrets` (sensitive, keychain) | 30 §10.2 | `get_settings.effective.pluginConfigs` is on the wire (verified live); secrets are not, by design | P / D | Sensitive option values are deliberately unreachable. The GUI must write them through `claude plugin install --config KEY=VALUE` (30 §19.3) or reimplement the keychain write. |
| `extraKnownMarketplaces` / `additionalMarketplaces` alias | 30 §10.3 | `get_settings.effective.extraKnownMarketplaces` (verified live) | P | |
| Managed policy keys: `strictKnownMarketplaces`, `blockedMarketplaces`, `disableCommandPluginSources`, `disableSideloadFlags`, `strictPluginOnlyCustomization`, `pluginTrustMessage`, `pluginSuggestionMarketplaces`, `allowedChannelPlugins` | 30 §10.4–10.5 | Readable via `get_settings.sources[]` (the `policySettings` entry) — but the *effects* surface only as refusal strings | R | The refusal strings themselves (30 §23.8) reach a GUI only when it shells out to the CLI; in-session they appear as `plugin_errors` entries of type `marketplace-blocked-by-policy`. |
| Marketplace **add** (policy gate, idempotence, registry admission, clone/fetch, reserved-name check, seed-managed refusal) with ~20 distinct progress/error strings | 30 §11.1–11.2 | `claude plugin marketplace add <source> [--sparse …] [--scope user\|project\|local]` (30 §25.2) | R | The GUI must render progress itself. The CLI writes to the scope given by `--scope`; the TUI's Add-Marketplace form always writes **user** settings regardless of current scope (30 §27.7) — a GUI can improve on that by exposing the scope. |
| Marketplace **refresh/update**, the 30 s `skipIfRecent` throttle, the official-marketplace GCS fast path, the `claude-code-plugins` deprecation notice, the per-marketplace glyph and the clause-by-clause bulk summary | 30 §11.3 | `claude plugin marketplace update [name]` | R | The bulk-summary assembly (`Updated N marketplaces (M plugins bumped) · … · R plugins skipped — update them individually from the Installed tab · B plugins blocked by managed policy — ask your admin`) is pure TUI string assembly; the CLI prints its own variant. |
| Marketplace **remove**, the seed-registered refusal, and the TUI confirmation `Remove marketplace <name>? This will also uninstall N plugins…` | 30 §11.4 | `claude plugin marketplace remove <name> [--scope …]` | R | The GUI must supply its own confirmation dialog; nothing on the wire prompts. |
| Plugin **install**: reference normalisation, marketplace resolution, not-found/already-installed messages, `headersHelper` consent, the nine failure `reason`s, the success line with dependency/disabled/stale suffixes | 30 §12 | `claude plugin install <plugin> [-s scope] [--config k=v]… [-y]` | R | The scope semantics (`user`/`project`/`local`, `project`/`local` records carry `projectPath = cwd`, precedence `local > project > user`) must be reproduced (30 §12.1). |
| Plugin **update**, its ten-step decision tree, version-constraint pinning, `command`-source and `headersHelper` deferrals, and the two success strings ending `Restart to apply changes.` | 30 §13 | `claude plugin update <plugin> [-s scope] [-y]` | R | "Restart to apply changes" is CLI wording for an out-of-session update; a GUI driving a live session should say "reload" and then issue `reload_plugins` instead — a genuine improvement over both surfaces. |
| Autoupdate held/deferred notices (`Autoupdate held "<p>" — version constraint from <pinners>`) | 30 §13, §30.1 | Surfaces as a `plugin_errors`/`plugin_warnings` entry of type `autoupdate-blocked-by-pinner` / `autoupdate-deferred-entry-helper` / `autoupdate-disabled-by-policy` on `system/init` | P | The last two are classified "advisory" and are excluded from the TUI's Errors-tab badge count (30 §27.2). A GUI should copy that split or the badge will cry wolf. |
| **Uninstall**, wrong-scope messages, the orphan note, `--keep-data`, data-dir deletion | 30 §14.1 | `claude plugin uninstall <plugin> [-s scope] [--keep-data] [--prune] [-y]` | R | The TUI's `<name> has <size> of persistent data — delete it along with the plugin?` confirmation (30 §27.6) has no CLI equivalent; the CLI deletes unless `--keep-data`. A GUI should show the size and ask. |
| **Prune** / `autoremove` with dry-run and confirmation | 30 §14.2 | `claude plugin prune [-s scope] [--dry-run] [-y]` | R | `-y` is required when stdin/stdout is not a TTY. |
| The 24 h `.in_use` / `.orphaned_at` cache sweep | 30 §14.3, §8.4 | Runs inside the CLI process; nothing user-visible | P | No GUI work. |
| **Enable / disable**: bare-name disambiguation, managed lock, skills-dir policy, synced-vs-local shadowing, ineffective-write detection, reverse-dependency guard, forward-dependency closure | 30 §15.1–15.2 | `claude plugin enable\|disable <plugin> [-s scope]`, or write `enabledPlugins` directly | R | The **ineffective-write detection** (`Plugin "<id>" would still be enabled after writing <scope> settings: <source> settings govern it`) is the highest-value message here and is easy to omit; it needs `get_settings.sources[]` to reproduce. |
| `disable --all` | 30 §15.3 | `claude plugin disable --all` | R | |
| Managed-lock messaging (`This plugin is managed by your organization. Contact your admin to disable it.`) | 30 §15.4 | Same text comes back from the CLI's enable/disable engine | R | A GUI should render the row as locked rather than letting the user click and fail. |
| Dependency version-constraint intersection, tags, cross-marketplace deps | 30 §16 | Surfaces as `dependency-unsatisfied` / `dependency-version-unsatisfied` in `plugin_errors`, and as CLI refusals | P (diagnosis) / R (resolution UI) | |

---

## 30 · Plugin components, namespacing and substitution (chapter 30 §§17–21)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Plugin **commands** registered as `<plugin>:<subdirs…>:<file>` | 30 §18.1 (`uVo`) | `initialize.commands[]` and `system/commands_changed` carry the fully namespaced name (verified live: 41 of 102 entries contain `:`) | P | |
| Plugin command description rendered `(<plugin display name>) <description>` | 30 §18.1; 29 §15.3 (`LY`) | Verified live in `initialize.commands[].description` — 42 entries carry the `(plugin-dev)`-style prefix, 11 carry a `(user)` scope suffix, 1 carries `(dynamic workflow)` | P | **The autocomplete source labelling is free.** The GUI need not compute provenance for the completion menu; it only needs to strip/reformat the parenthetical if it wants a separate column. |
| Plugin **skills** registered `<plugin>:<skill>` | 30 §18.1; 29 §7.1 | Same as commands — skills *are* prompt commands, so they appear in `initialize.commands[]` and in `system/init.skills[]` (names only) | P | |
| Plugin **agents** named `[plugin, …subdirs, name].join(":")`; `permissionMode`/`hooks`/`mcpServers` silently ignored for plugin agents | 30 §18.2 | `initialize.agents[]` (name/description/model) and `system/init.agents[]` (agentType names) | P | The three "ignored for plugin agents" warnings are log-only; not on the wire. |
| Plugin **output styles** named `<plugin>:<style>` | 30 §18.3; 32 §32.5 | `initialize.available_output_styles` includes them (32 §32.12.1) | P | Verified live: only the five built-ins on this machine, so plugin-style presence is inferred from the code path, not observed. |
| Plugin **MCP servers** named `plugin:<plugin>:<server>`, tools exposed as `mcp__plugin_<plugin>_<server>__<tool>` | 30 §18.4, §28.6 | `system/init.mcp_servers[]`, `mcp_status` control request | P | Belongs primarily to the MCP area; listed here for the naming convention only. |
| Plugin **LSP servers** named `plugin:<plugin>:<server>`; extension-conflict notice | 30 §18.5 | `plugin_errors`/`plugin_warnings` of type `lsp-config-invalid`, `lsp-server-start-failed`, `lsp-server-crashed`, `lsp-request-timeout`, `lsp-request-failed` | P | |
| Plugin **hooks** (`hooks/hooks.json`, manifest `hooks`, one module per plugin) | 30 §§20.1–20.5 | Hook execution is visible via `--include-hook-events` (`hook_started`/`hook_progress`/`hook_response`); load failures via `plugin_errors` type `hook-load-failed` | P | The static hooks-module scan results (`<module> hooks: …`, `<module> calls: $.…`) are printed only by `claude plugin validate` — R. |
| Plugin **themes** and **keybindings** | 30 §18 table lists `themes`; keybindings are **not** a plugin component in 2.1.257 | Themes have no wire representation; the `Plugin` keybinding context (`space`/`i`/`f`) belongs to the `/plugin` panel only (30 §27.3) | T | Themes are terminal-colour tables; a native GUI supersedes them entirely. The `Plugin` keybinding context is meaningless without the panel. |
| Plugin **workflows**, **monitors**, **channels**, **settings** (`agent`, `subagentStatusLine` only), **binaries** | 30 §18 table, §21 | Binaries provisioning is gated on `CLAUDE_CODE_PLUGIN_BINARY_ASSETS` / `tengu_plugin_binary_assets` (default off) and only for official marketplaces — invisible in practice | P (invisible) | The validator's `bin/<name> is not a shipped file…` cross-check is CLI-only (R). |
| The shadowing rule ("declaring a component key suppresses the default folder") and its notice `Default <component>/ folder is ignored because the manifest sets <fields>` | 30 §4.1, §30.2 | `plugin_warnings` notice type `folder-shadowed-by-manifest` | P | The remedy text is a separate TUI string; a GUI must supply its own or copy 30 §30.2. |
| `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PROJECT_DIR}` / `${CLAUDE_PLUGIN_DATA}` / `${user_config.KEY}` substitution | 30 §19.1–19.2 | Entirely internal; the only user-visible artefact is the error `Plugin option "<key>" isn't set. Open /plugin manage to configure it…` | P | That error string names `/plugin manage`, which a GUI cannot open. **Rewrite it** — otherwise the GUI tells the user to run a command that does not exist there. |
| `--config KEY=VALUE` validation errors and the `<N> userConfig options not yet set` reminder | 30 §19.3 | `claude plugin install … --config k=v` | R | |
| `--plugin-dir <path>` / `--plugin-dir-no-mcp <path>` / `--plugin-url <url>` session-only sideloading | SPEC 02 lines 765–767; 30 §2.2 (`@inline`) | Launch flags — the GUI can append them to its own spawn line | P | Not in the afleet baseline command line today. Adding `--plugin-dir` gives the GUI a first-class "try this plugin without installing it" affordance the TUI only exposes at launch. Blocked when managed `disableSideloadFlags` is set (fatal at startup, SPEC 02 line 365). |
| `@skills-dir` adoption (a `~/.claude/skills/<x>/` or `<project>/.claude/skills/<x>/` directory that carries plugin content becomes a plugin) and its untrusted-workspace suppression | 30 §17.5; 29 §7.3 | Suppression surfaces as `plugin_warnings` type `project-scope-suppressed-untrusted` with the text `<N> project-scope directories under ./.claude/skills/ … run /reload-plugins (or relaunch)` | P (data) / R (remedy) | The remedy names `/reload-plugins`, unavailable headless. The GUI should say "accept trust, then reload" and wire the button to `set_cwd {trust_accepted: true}` followed by `reload_plugins`. |

---

## 30 · Trust, consent and policy refusals (chapter 30 §§22–23)

**Headline finding.** In headless streaming-input mode the dialog host is `K_()`
(`cli.pretty.js:174428`). It forwards a `request_user_dialog` control request for exactly
four kinds — `mcp_elicitation`, `refusal_fallback_prompt`, `fable_overage_consent_prompt`, and
the Slack-connect kinds — and returns the dialog's `default` for **everything else**. The
binary defines 34 dialog kinds (`io({ kind: … })`), among them `plugin_hint`,
`managed_settings_security` and `permission_skill`. **No plugin trust or consent dialog is
reachable over the headless protocol**, regardless of what the host declares in
`initialize.supportedDialogKinds`.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Plugin trust disclaimer on every details pane ("Make sure you trust a plugin before installing…"), plus managed `pluginTrustMessage` appended | 30 §22.1 | none | R | Static text; the GUI should render it verbatim on its own install pane and append `policySettings.pluginTrustMessage` from `get_settings`. |
| `Will install:` capability summary (Commands / Agents / Skills / Hooks / MCP Servers / LSP Servers) | 30 §22 table, §27.5 | `claude plugin details <name>` prints the component inventory | R | `--json` is read by the handler but **not declared as a flag**, so the JSON branch is unreachable from the CLI (30 §25.2). The GUI must parse the text output or read the plugin directory itself. |
| Install-scope menu (user / project / local), first entry pre-selected | 30 §22 table, §27.5 | `-s/--scope` on the CLI | R | |
| `command`-source consent: the review pane, the four `Ws` refusals, the CLI disclosure and `Run this command now? [y/N]` | 30 §22.2 | `claude plugin install/update … -y`, but: `-y/--yes is ignored inside a Claude Code session`, and without a TTY the command is only displayed | R (with a hard caveat) | A GUI spawning `claude plugin install` must (a) not inherit Claude Code entrypoint env vars, and (b) either allocate a PTY or pass `-y`. If it does neither, command-sourced plugins silently fail to install. Bulk install in the TUI refuses command sources outright. |
| `headersHelper` consent pane and its four consent-mismatch refusals | 30 §22.5 | same CLI path, same `-y` caveat | R | The `hiddenCharactersWarning` (`The command contains non-ASCII, hidden or control characters (shown as \u{…} escapes)`) must be reproduced — dropping it removes a real security affordance. |
| `command`-source execution refusals (16 distinct messages: exit code, timeout, >64 KB stdout, signal, spawn failure, no output, multiple lines, not absolute, UNC/automount, untrusted link, realpath failure, network re-check, not a directory, no plugin content, >20 000 entries, >256 MB) | 30 §22.3 | printed by the CLI | R | Surface verbatim; they are the only diagnosis the user gets. |
| Link-farm construction/relink refusals | 30 §22.4 | printed by the CLI | R | |
| Archive download safety: sha256 pin verification, redirect policy, zip-bomb limits, post-extraction shape checks | 30 §22.8 | printed by the CLI; load-time failures appear as `plugin_errors` types `mcpb-download-failed` / `mcpb-extract-failed` | P / R | |
| Startup **workspace-trust dialog** (`Accessing workspace:` … `Yes, I trust this folder` / `No, continue without these permissions`, **No focused by default**), including the `headersHelper` line | 30 §22.6 | Not a `request_user_dialog` kind at all. The headless equivalent is the `set_cwd` control request's `trust_accepted?` / `trusted_directory?` parameters (SPEC 45 §45.17, `chunk-2rhzyjym.js:177298`) | R | The GUI must build its own trust dialog and pass the answer through `set_cwd`. Until trusted, project-scope `@skills-dir` plugins are suppressed and the debug log records `Trust not accepted for current directory - skipping plugin installations`. |
| `plugin_hint` dialog (`{pluginName, pluginDescription, marketplaceName, sourceCommand}` → `yes` / `no` / `disable` / `cancelled`) | 30 §28.5; dialog descriptor at `cli.pretty.js:422986`, trigger at `:432448` | Never forwarded — `K_()` returns the default `"cancelled"` | X | Only fires when managed `pluginSuggestionMarketplaces` allowlists a marketplace (default: nothing), plus the hard-coded frontend-design tip. Low value; a GUI that wants contextual suggestions should build them from `plugin-catalog-cache.json` and the session's own file/command history. |
| `local_jsx` dialog kind (`{nodeId, commandName, immediate, hidesPrompt}`) | descriptor at `cli.pretty.js:328261`; renderer at `:423657` requires `LocalJsxRegistryContext` | Declaring it buys nothing — the payload is an index into the CLI's own Ink node registry | X | Worth knowing so nobody tries to route `/plugin` through it. |
| Enabling a plugin that ships hooks / MCP servers / monitors is **not** separately confirmed | 30 §22 (closing note) | same | P | A GUI can exceed the TUI here by showing what a plugin will register before the toggle takes effect (the data is in the manifest on disk). |
| Where policy refusals surface (nine points: add, clone, bulk refresh, load, install, enable, update, disable, bulk-update summary) | 30 §23.8 | load-time refusals arrive as `plugin_errors` type `marketplace-blocked-by-policy`; the rest only from the CLI | P / R | |

---

## 30 · `claude plugin` CLI, validate, scaffold, eval (chapter 30 §§24–26, §29)

The whole CLI tree is the GUI's primary lever. Verb list for shelling out (30 §25.1):

| Verb | Usage | Aliases |
|---|---|---|
| `init` | `plugin init <name>` | `new` |
| `validate` | `plugin validate <path>` | — |
| `tag` | `plugin tag [path]` | — |
| `list` | `plugin list` | — |
| `details` | `plugin details <name>` | — |
| `marketplace add` | `plugin marketplace add <source>` | — |
| `marketplace list` | `plugin marketplace list` | — |
| `marketplace remove` | `plugin marketplace remove <name>` | `rm` |
| `marketplace update` | `plugin marketplace update [name]` | — |
| `install` | `plugin install <plugin>` | `i` |
| `uninstall` | `plugin uninstall <plugin>` | `remove`, `rm` |
| `prune` | `plugin prune` | `autoremove` |
| `enable` | `plugin enable <plugin>` | — |
| `disable` | `plugin disable [plugin]` | — |
| `update` | `plugin update <plugin>` | — |
| `eval` | `plugin eval [target]` | — (early access) |
| `eval init` | `plugin eval init [name]` | — (early access) |

The root command has no action handler: a bare `claude plugin` prints help to **stderr** and
exits 1 (30 §25).

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `claude plugin list [--json] [--available]` | 30 §25.3 — text form has the four extra sections (session-only, synced, synced-sync-off, skills-directory) | same command | R | `--json` is the GUI's best inventory source: `{id, version, scope, enabled, installPath, installedAt, lastUpdated, projectPath, mcpServers, errors[], notes[]}`; `--available` adds the catalog with `installCount`. **`--available` requires `--json`.** |
| `claude plugin marketplace list [--json]` | 30 §25.3 | same | R | JSON gives `{name, source, repo?/url?/path?, ref?, installLocation}`. |
| `claude plugin details <name>` — component inventory + projected token cost (`Always-on: ~N tok`, per-component always-on/on-invoke table) | 30 §25.3 | same command, text only | R | The same numbers drive the TUI's `Context cost: · Every turn: ~1.2k tokens · When invoked: ~4.5k tokens` block, coloured `warning` at ≥2000 always-on tokens (30 §27.5). This is one of the best affordances in the TUI and a GUI should reproduce it. |
| `claude plugin validate <path> [--strict]` — unknown-field diagnosis against three tables, path checks, manifest-quality warnings, component scanning with per-file frontmatter validation, symlink/size accounting, marketplace cross-validation | 30 §24 | same command | R | Exit 0 success, 1 failure (`--strict` promotes warnings), 2 on an unexpected exception. A GUI can offer a "validate this plugin" button; the messages are all quoted in 30 §24. |
| `claude plugin init <name> [--description] [--author] [--author-email] [--with skills,agents,hooks,mcp,lsp,output-style,channel] [-f]` — scaffolds a skills-dir plugin at `~/.claude/skills/<name>/` | 30 §26 | same command | R | Its closing lines already point at `/reload-plugins`; the GUI should substitute its own reload button (which issues the `reload_plugins` control request). |
| `claude plugin tag [path] [--push] [--dry-run] [-f] [-m] [--remote]` | 30 §25.2 | same | R | |
| `claude plugin eval [target]` — 20 flags, scored cases, `with-without` ablation, MCP mocks, LLM graders, HTML report with optional claude.ai publish | 30 §29 | same command; gated on `tengu_walnut_spire` or `CLAUDE_CODE_WALNUT_SPIRE`, otherwise prints `` `plugin eval` is currently in early access `` in red and exits 1 | R | Long-running with stderr progress lines and an exit-code contract (0 pass / 1 fail / 2 partial / 130 SIGINT / 143 SIGTERM). A GUI should run it as a background job and render `--json` (schema version 1, 30 §29.7) rather than scraping stderr. Self-test: run it in an empty directory — "currently in early access" means the gate is closed; `No eval cases found …` means it is open. |
| `claude plugin eval init [name] [--bare] [-i] [--eval-dir]` | 30 §29.8 | same | R | The non-`--bare` path **re-execs the CLI** with `--append-system-prompt <interviewPrompt> --strict-mcp-config -- "Let's set up evals for this plugin."` and `stdio: "inherit"`. A GUI cannot inherit stdio usefully; it should either pass `--bare` or drive the interview as an ordinary session with the same appended prompt. |
| `--cowork` hidden flag on most verbs | 30 §25 | — | T | Selects the `cowork_plugins/` directory; irrelevant to a desktop GUI. |
| Glyphs `✔ ✘ ⚠ ❯` with ASCII fallbacks | 30 §25.4 | — | T | Replace with native iconography. |

---

## 30 · The `/plugin` dialog and other interactive surfaces (chapter 30 §27)

`/plugin` is `{type: "local-jsx", name: "plugin", aliases: ["plugins","marketplace"], immediate: true}`
with **no `local` twin** (30 §27). Verified live: `plugin`, `plugins` and `marketplace` are
absent from the headless command list. Invoking it non-interactively yields the SPEC 28 §8.1
refusal: `/<name> opens an interactive panel and isn't available in this environment. Run it
from the Claude Code terminal instead.`

**Therefore every row below is X for the panel itself and R for the capability.** The GUI
rebuilds the whole plugin manager natively; the data comes from disk + `claude plugin` + the
control protocol.

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| The `/plugin` panel as such (tabbed `Plugins` window) | 30 §27.2 | refused with the §8.1 message | X | The GUI's replacement is a native window; this is the single largest rebuild in the area. |
| `/plugin` argument grammar (`list`, `install`, `manage`, `stats`, `uninstall`, `enable`, `disable`, `configure`, `validate`, `tag`, `marketplace …`, `help`) and its two-level autocomplete records | 30 §27.1 | none | R | The completion descriptions (`List installed plugins`, `Enable an installed plugin`, …) are worth reusing as GUI menu labels. Note `eval` parses to `menu` — **the eval view is unreachable from the slash command**. |
| Tabs: `Discover`, `Installed`, `Marketplaces`, `Errors (N)`, `Stats` | 30 §27.2 | none | R | `Stats` is gated on `tengu_lantern_prism` / `CLAUDE_CODE_LANTERN_PRISM`; verified open for this user (`skill-doctor` is in the live command list). The error badge counts non-advisory errors plus failed marketplace installs. |
| **Discover** tab rows: `<radio> <displayName> · <marketplace> · <suggestion badge> [Community Managed] · <N> installs` plus a 60-column description; five suggestion badges; seven empty states; three load-warning forms | 30 §27.4 | `claude plugin list --json --available` gives id/name/description/marketplace/version/source/installCount; the catalog is also in `plugin-catalog-cache.json` | R | Install count renders **only** for `claude-plugins-official`; `[Community Managed]` comes from the entry's `tags`. The seven empty states encode real policy conditions (git missing, no external marketplaces allowed, strict allowlist, no marketplace added, load failure, all installed, all installed for this project) — reproduce them or the user sees an unexplained blank list. |
| **Plugin details** pane: name, `from <marketplace>`, version, last updated, description, `By: <author>`, trust warning, context-cost block, headersHelper block, `Will install:` summary, command-source note | 30 §27.5 | `claude plugin details` + the marketplace entry on disk | R | |
| Install menu and its six options (three scopes, homepage, GitHub, back) | 30 §27.5 | `claude plugin install -s <scope>` | R | |
| Install result lines and the five activation tails (` Plugin is now active.` / ` The plugin couldn't be loaded…` / ` Run /reload-plugins to apply.` / two disabled-by-default variants) | 30 §27.5 | the CLI prints its own success line | R | **Rewrite the `/reload-plugins` tail** — the GUI's equivalent is a button that issues `reload_plugins`. |
| Bulk install, its three summary forms and eight tails | 30 §27.5 | loop the CLI | R | Bulk install refuses command-sourced plugins outright. |
| Post-install `Configure <plugin>` / `Plugin options` / `Save configuration` flow and its 17 outcome strings | 30 §27.5 | `--config KEY=VALUE` at install time (30 §19.3) | R | Sensitive options cannot be set through `--config` from a GUI without the keychain path; see 30 §10.2. |
| **Installed** tab: eight scope groups (`Flagged`, `Project`, `Local`, `User`, `Enterprise`, `Managed`, `Built-in`, `Skills`) in fixed order, plus `Needs attention` / `Favorites` / `Not used recently` cross-cutting sections | 30 §27.6 | `claude plugin list --json` + `installed_plugins.json` | R | Favorites persist in `~/.claude.json` under `favoritePlugins`; the GUI can read/write that key directly. |
| `Not used recently` heuristic: requires a warm load cache, no `strictKnownMarketplaces`, a real marketplace, `user-install` classification, **no** themes/output-styles/monitors/workflows contributed, a usage record, no unflushed use, and both `daysSinceLastUse ≥ 14` and `sessionsSinceLastUse ≥ 10` | 30 §27.6 | `pluginUsage` in `~/.claude.json` (`{usageCount, lastUsedAt, lastUsedNumStartups}` per plugin id) | R | Fully reproducible from disk. The "contributes only passive components" exclusion is the subtle part — omit it and the GUI will nag users about theme plugins forever. |
| Safe-mode banner (`Safe mode: plugins are disabled this session — changes here save but won't load until safe mode is off.`) | 30 §27.6 | The GUI knows its own launch flags / env | R | |
| Plugin detail menu (11 items, three of them toggles) and its 10 action-outcome strings, plus two confirmations (project-scope disable, persistent-data delete) | 30 §27.6 | CLI verbs | R | |
| Per-source failure hints for `@inline` / `@skills-dir` / `@synced` copies that did not load | 30 §27.6 | The failure itself is in `plugin_errors`; the hint text is TUI-side | P / R | |
| **Marketplaces** tab: pending-changes batching (`Pending changes: Enter apply`, `Update N marketplaces`, `Remove N marketplaces`), the `✻`-wrapped official name, the four-item detail menu, auto-update toggle and its three refusals, and the Add-Marketplace form with four source examples | 30 §27.7 | CLI verbs | R | Auto-update default: on for names in the official set except `knowledge-work-plugins` and `first-party-plugins` (30 §2.3). The batching UX is worth copying — one confirmation for N marketplace operations. |
| **Errors** tab: 29 error variants with a longer explanatory rendering plus per-row guidance, and five resolve actions (`navigate`, `remove-extra-marketplace`, `remove-installed-marketplace`, `managed-only`, `none`) | 30 §27.8, §30.1, §30.3 | `system/init.plugin_errors[] = {plugin, type, message}` carries the **type tag and short message**; the long guidance strings are TUI-only | P (data) / R (guidance) | This is the best-value rebuild in the chapter: the `type` tag is a stable key, and 30 §30.3 lists all 29 guidance strings verbatim. Remember the advisory/non-advisory split for the badge (30 §27.2). |
| **Stats** tab (identical content to `/skill-doctor`, with `in the Installed tab` substituted for `in /plugin`) | 30 §27.9; 29 §18.2 | `/skill-doctor` **is** available headless as its `local` twin (`supportsNonInteractive: true`) — verified live | P | Text report only; see the skills section below. |
| `/plugin help` (a 30-line usage block) | 30 §27.10 | none | X/T | Superseded by GUI affordances. |
| `/plugin validate` and `/plugin tag` usage blocks | 30 §27.10 | the CLI verbs | R | |
| `/reload-plugins` | 30 §27.11; `{type:"local", supportsNonInteractive:false, terminalOriented:true, thinClientDispatch:"control-request"}` (verified in binary) | The **`reload_plugins` control request** (SPEC 45 §45.17), which returns `{commands, agents, plugins, mcpServers, error_count}` | P for the reload, **D for the pre-flight warning** | The control-request handler (`cli.pretty.js:177681`) calls `cH()` directly. It **skips** the `fee()` prompt-cache impact probe that the slash command runs, so the GUI never receives `This reload changes MCP tools (<server>) and adds the LSP tool — your next message will re-read the whole conversation instead of using the cache.` It also has no `--force`, so newly installed dependencies are always activated. **Workaround:** the GUI can compare `mcp_status` before and after the reload and warn the user itself, but it cannot warn *before* committing. |
| The pending-changes banner `Plugins changed. Run /reload-plugins to activate.` | 30 §27.11; `cli.pretty.js:397612` | Emitted through the TUI's Ink `addNotification` hook, **not** the engine's `notification` channel (which is what becomes `system/notification`, `cli.pretty.js:448602`) | D | The GUI must synthesise its own banner. It has the information — it performed the install itself, or it can watch `installed_plugins.json` with FSEvents. |
| The autoupdate banner (`Plugins updated: a and b · reloaded for this session` / `· reloaded with errors — see /plugin` / `· Run /reload-plugins to apply`) | 30 §27.11; `cli.pretty.js:431494` | Same — a segments-shaped TUI notification, not on the wire (the wire `notification` frame carries a flat `text` only) | D | Same workaround: watch `installed_plugins.json`, or call `reload_plugins` opportunistically. |
| `/plugin-types` (writes `claude-code-mcp.d.ts` from live MCP tool schemas) | 30 §27.12 | `{type:"local", supportsNonInteractive: true}` — **but gated on `tengu_plugin_hooks_modules`, default off**; verified absent from the live command list | P when the gate opens | Also reachable as a plain prompt (`/plugin-types [dir]`) once enabled. Plugin-author tooling; low priority for a chat GUI. |
| `/cloud-plugins` (consent dialog: `Use your enabled plugins in cloud sessions you run from this machine?` with `Yes` / `No, keep them on this machine only` / `Not now`, **`Not now` focused**) | 30 §27.13 | `local-jsx`, no twin, `requires: {ink: true}` — verified absent headless | X for the dialog; R for the mechanism | The answer is **not a settings key**: it lives at `<configHome>/state/cloud-plugins-consent.json` as `{version:1, choice, decidedAt, hostname}`, and a hostname mismatch reads back as unset. A GUI can write that file and rebuild the dialog. The forwarding itself travels as `apply_flag_settings {settings: {cloudPluginsForwarded: <patch>}}` followed by `reload_plugins` — both are control requests the GUI can send. |
| The 17 per-plugin cloud-forwarding drop reasons and 7 worker-side refusals | 30 §27.13 | not on the wire | D | Only meaningful if the GUI implements cloud forwarding; note them as a follow-on. |
| Account-synced (`@synced`) plugins: sync round, on-disk layout, refusal messages | 30 §27.14 | `system/init.plugins[]` includes them with `source` set; the three root-level sync-disabled messages are log-only | P (presence) / D (sync diagnostics) | A synced plugin can be disabled but not installed/updated/uninstalled locally. |
| `system/plugin_install` progress frames (`status: started \| installed \| failed \| completed`, `name?`, `error?`) | SPEC 45 §45.14.7 | Emitted **only** when `CLAUDE_CODE_SYNC_PLUGIN_INSTALL` is set **and** `--output-format stream-json` (`cli.pretty.js:176012`) | P (opt-in) | These cover the **startup sync of account plugins**, not user-driven installs. If afleet wants a progress indicator for account-plugin sync it must add `CLAUDE_CODE_SYNC_PLUGIN_INSTALL=1` to the child env. |
| `system/commands_changed` after a skill/plugin reload | SPEC 45 §45.9.1; emitter at `cli.pretty.js:176199` | `{type:"system", subtype:"commands_changed", commands: [{name, description, argumentHint, aliases?}]}` — `stream-json` only | P | Same shape as `initialize.commands`, including the `(plugin)` / `(user)` labelling. The GUI should treat this as the authoritative refresh for its slash-command menu. |

---

## 30 · Model-facing plugin tools and suggestions (chapter 30 §28)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `ListPlugins`, `SearchPlugins`, `SuggestPluginInstall` (and the three skill twins) | 30 §28.1–28.4 | **Absent in an ordinary terminal `claude` session.** `Xce()` requires no HIPAA taint plus either `CLAUDE_CODE_REMOTE` + first-party, or entrypoint ∈ {claude-desktop, claude-desktop-3p, local-agent} + first-party + `tengu_saddle_lantern` (default false) | X for a stdio GUI today | If afleet ever sets `CLAUDE_CODE_ENTRYPOINT=claude-desktop`, these become available and `SuggestPluginInstall` renders **out of band** — the tool result explicitly says "The card itself is rendered by the host client". That is a native install card the GUI would have to build. Worth flagging as a future capability, not a current gap. |
| Relevance-based contextual install tips (`Working with <topic>? Install the <plugin> plugin: /plugin install <plugin>@<marketplace>`) and the session-start notification `plugin suggestion: <pluginId> · /plugin` | 30 §28.5 | not on the wire | D / X | Only fires when managed `pluginSuggestionMarketplaces` allowlists a marketplace (default: nothing surfaces), plus the hard-coded frontend-design tip. There is **no dismissal mechanism**; throttling lives in `~/.claude.json` (`tipsHistory`, `tipLifetimeShownCounts`, `pluginSuggestionDiscoverShownCounts`). Very low priority. |
| What the model is told about plugins | 30 §28.6 | Nothing enumerates plugins to the model; plugin identity leaks only through namespaced skill names, `mcp__plugin_<p>_<s>__<tool>` tool names, and plugin-submitted prompts | P | Plugin-submitted prompts arrive as ordinary **user-role** messages beginning `The <plugin> plugin sent a message:` — a GUI should style these distinctly from real user input, which the TUI does not do. A genuine improvement opportunity. |

---

## 30 · Errors and notices (chapter 30 §30)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| 29-variant error taxonomy with a per-variant "worth telling the user even when disabled?" flag and four overrides | 30 §30.1 | `system/init.plugin_errors[] = {plugin, type, message}` | P | The `type` tag is the stable key; the boolean map in 30 §30.1 tells the GUI which errors to show for a *disabled* plugin. |
| 11-variant notice taxonomy plus 18 remedy strings | 30 §30.2 | `system/init.plugin_warnings[]` (same shape) | P (data) / R (remedies) | Several remedies name `/reload-plugins` or `/plugin`; rewrite for the GUI. |
| The Errors-tab long rendering (30 guidance strings) | 30 §30.3 | not on the wire | R | Copy verbatim, substituting GUI navigation for `/plugin …` references. |

---

## 29 · Skills: what a user sees, discovery and naming (chapter 29 §§1–11)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| A skill is a `type: "prompt"` command; every skill has a `/name` spelling unless `user-invocable: false` | 29 §1 | `initialize.commands[]` and `system/init.slash_commands[]` list exactly the user-invocable ones | P | |
| Autocomplete row: name + `LY()` description carrying the source label | 29 §15.3; `LY` at `chunk-1kg58a1a.js:145447` | On the wire in `initialize.commands[].description` and `commands_changed`. Verified live: `(plugin-dev) …` prefix for plugin skills, `(user)` suffix for user skills, `(dynamic workflow)` for workflows | P | The full label set is: `(<plugin display name>) <desc>`, `<desc> (plugin)`, `<desc> (claude.ai sync)`, `<desc> (dynamic workflow)`, and the scope labels `(user)`, `(project)`, `(project, gitignored)`, `(cli flag)`, `(managed)`. A GUI wanting a separate provenance column must parse these back out — or read the skill directories. |
| `argument-hint` shown after the slash-command name | 29 §3.1 | `initialize.commands[].argumentHint` (verified live, e.g. `plugin-dev:create-plugin` → `Optional plugin description`) | P | |
| Aliases | 29 §5.5 | `initialize.commands[].aliases` (verified live) | P | Plugin aliases that would shadow another command are stripped by `A7o` before this point. |
| `when_to_use` — "becomes part of the tool description" | 29 §3.1, §12.4 | **Not on the wire.** It reaches the model inside the `skill_listing` `<system-reminder>` attachment, which is a request-side attachment, never a stdout frame | D | Affects the `/skills` row token estimate (`Wc([name, description, whenToUse])`) and any GUI skill browser. **Workaround:** parse `SKILL.md` frontmatter from disk; the discovery roots are enumerated in 29 §5.1. |
| `user-invocable: false` — skill hidden from the user, model-only | 29 §3.1 | Filtered out of `slash_commands` and `initialize.commands` | P | Typing such a name yields `This skill can only be invoked by Claude, not directly by users. Ask Claude to use the "<name>" skill for you.` (SPEC 28 §8.1). |
| `disable-model-invocation: true` — typable but invisible to the model | 29 §3.1, §13.3 | Still in `commands`; the distinction is not marked on the wire | D | Minor: a GUI cannot badge "user-only" skills without reading frontmatter. |
| `model` / `effort` overrides declared by a skill | 29 §3.1, §14.2 | Applied as tool-result **context layers** (`{kind:"model"}` / `{kind:"effort"}`); the effect shows up in subsequent `assistant` frames' model field | P (effect) / D (notice) | The TUI does not print a distinct "this skill switched the model" banner either — the `Skill` tool output's `model` field is the only signal, and it is inside the tool result. Both surfaces are equally quiet; a GUI can exceed the TUI by surfacing it. |
| `paths:` conditional activation — the skill is invisible until the model touches a matching file | 29 §6.2 | The skill simply appears in a later `commands_changed` frame | P | Activation logs `[skills] Activated conditional skill '<name>' (matched path: <path>)` at debug level only; the *reason* a skill appeared is not on the wire (D, minor). |
| Directory-scoped skills: lazily discovered, named `<prefix>:<name>` only on collision, description suffixed `(scoped to <prefix>/ — use this instead of the unscoped "<name>" skill …)` | 29 §6.1–6.3 | Both the qualified name and the suffixed description arrive in `commands_changed` | P | The suffix text is the only signal that a row is directory-scoped; a GUI wanting a proper badge must parse it or read `skillRoot` from disk. |
| The scoped-variant reminder (`Directory-scoped variants of the "<name>" skill exist in this repo: …`) | 29 §6.4 | A `<system-reminder>` injected into the request, not a stdout frame | X | Model-facing only; no user-visible TUI element either. Listed for completeness. |
| The new-directory reminder (`New skills discovered in <dir>, now available via the Skill tool:`) | 29 §6.5 | Same — request-side attachment | X | The *effect* (new commands) does reach the GUI via `commands_changed`. |
| Skill sources: managed/policy, user, project ancestors, additional working dirs, legacy `commands/`, plugin, bundled, built-in, MCP, memory-store, claude.ai-synced | 29 §5.1 table | `system/init.skills[]` is names only; provenance is in the `LY` description label and on disk | P (names) / R (provenance) | |
| Bundled skills (42 registrations, 41 names) and their kill switch `disableBundledSkills` / `CLAUDE_CODE_DISABLE_BUNDLED_SKILLS` (only `doctor` survives) | 29 §11 | Bundled skills appear in `commands` like any other; the setting is readable via `get_settings` | P | Ten of the 42 are gated behind a literal `return false` in this build and never appear. Note `doctor` is `terminalOriented: true` — verified live, it is one of the two entries in `terminal_slash_commands`. |
| claude.ai-synced skills: `(claude.ai sync)` label, the reserved `synced` directory name, `syncClaudeAiSkills` semantics | 29 §10 | Label is on the wire; sync state is not | P / D | Synced skills lose every name collision to local, plugin and earlier synced skills. |
| MCP skills (`<server>:<skill>`), memory-store skills (`memories::<name>`, always model-only) | 29 §§8–9 | MCP skills appear in `commands` when the `tengu_mcp_skills` gate is on; memory-store skills are always `userInvocable: false` so they never appear | P / X | |
| `skills-disabled/` directory | 29 Open questions | no code path reads it | — | Operator convention, not a feature. Do not implement. |

---

## 29 · The skill listing and its budget (chapter 29 §12)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| The `skill_listing` `<system-reminder>` attachment (`The following skills are available for use with the Skill tool:` + one line per new skill) | 29 §12.3–12.4 | Request-side attachment; never a stdout frame | X | The user never sees it in the TUI either. Its *cost* is what the user sees, via `/context` and `/skill-doctor`. |
| The budget: `floor(contextWindowTokens × bytesPerToken × skillListingBudgetFraction)`, default `200000 × 4 × 0.01 = 8000` chars; per-description cap `skillListingMaxDescChars` = 1536; env override `SLASH_COMMAND_TOOL_CHAR_BUDGET` | 29 §12.5 | `get_settings.effective.skillListingBudgetFraction` is on the wire — **verified live at `0.02` for this user** (set in `userSettings`) | P (value) / R (arithmetic) | At 0.02 the budget is 16 000 chars. A GUI wanting to show "you are over budget" must redo the arithmetic itself. |
| The over-budget warning `Skill listing over budget: <n> skills, <total> chars > <budget> budget — descriptions will be truncated. Run /skills to disable some, or raise skillListingBudgetFraction in settings.` | 29 §12.5 | Logged at `warn` level only — **not** an `informational` frame | D | **This is the answer to "what does the TUI show when skills are elided": nothing in the transcript.** The user finds out only via `/context` or `/skill-doctor`. A GUI can genuinely exceed both surfaces by computing the budget from `get_settings` + the command list and showing a persistent indicator. |
| Elision policy: `name-only`-overridden and **bundled** skills keep their full line; everything else competes on `usageCount × max(0.5^(daysSinceUse/7), 0.1)` and degrades to `- <name>` | 29 §12.5 | `skillUsage` lives in `~/.claude.json` as `{"<name>": {usageCount, lastUsedAt}}` | R | Fully reproducible from disk. Widths are measured with `Bun.stringWidth(t, {ambiguousIsNarrow: true})` — display columns, not bytes. |
| The `/context` accounting variant (`cappedSkills`, `budgetMode`, `budgetTruncatedSkills`, `totalChars`, `budget`, `bytesPerToken`) | 29 §12.6 | `get_context_usage` control request — belongs to the context-management area; check there whether the skill breakdown is included | P (probably) | Flagged in Unverified. |
| Post-compaction `invoked_skills` restatement | 29 §12.7 | Request-side attachment | X | Not user-visible in either surface. |

---

## 29 · The `Skill` tool, invocation and rendering (chapter 29 §§13–15)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `Skill` tool call rendering: the skill name, prefixed `/` for `commands_DEPRECATED` skills, suffixed ` · by <author>` under the `tengu_tussock_oriole` team-attribution gate | 29 §13.5 (`cIn`) | The `assistant` frame carries the raw `tool_use` block `{skill, args}`; `renderToolUseMessage` output is not on the wire | R | Trivial rebuild: render `name` with an optional `/` prefix. The ` · by <author>` attribution needs the git-history scan (29 §19.5) — reproducible from disk, low value. |
| The `Skill` tool result strings (`Skill "<name>" launched (forked execution, running in the background).`, `Skill "<name>" completed (forked execution).`, `Loaded skill instructions (read-only): <name>…`, `Launching skill: <name>`) | 29 §13.5 | Present verbatim in the `user` tool-result frame | P | |
| The skill invocation **echo** in the transcript: `<command-message>…</command-message>` / `<command-name>/<name></command-name>` / `<command-args>…</command-args>`, or `<skill-format>true</skill-format>` for model-only skills | 29 §14.1 | Both injected user messages ride the wire (`--replay-user-messages` replays them); the first carries `sourceToolUseID` = the `Skill` tool-use id, and both are `turnCompanion: true` | P (data) / R (rendering) | The TUI collapses these into the tool-call row using `sourceToolUseID`. A GUI must do the same grouping or the user sees a raw XML blob as a "user message" — this is the single most visible skills rendering task. The body message is `isMeta: true`. |
| The `{type: "command_permissions", allowedTools, model}` synthetic record | 29 §14.1 | On the wire as part of the injected messages | P | |
| Re-invocation elision (`Skill /<name> is already loaded above; instructions unchanged. Arguments: <args>` and its three siblings) | 29 §14.3 | The substituted text is what rides the wire | P | |
| Forked invocation: **background by default** (`background ?? true`, false only in coordinator/non-interactive sessions) | 29 §14.4 (`a6t`) | `Oe()` is the non-interactive predicate — **in headless (`-p`) a forked skill runs inline, not backgrounded**. The tool returns `{status:"forked", agentId, result}` | P | Important behavioural difference between the GUI's session and a terminal session. If afleet wants background forks it must look at whether its launch counts as interactive; today it does not. |
| Inline-fork `skill_progress` progress events | 29 §14.4 | `control_request_progress` is restricted to `side_question` (SPEC 45 baseline), so skill fork progress does **not** reach the host as progress frames; subagent text arrives via `--forward-subagent-text` with `parent_tool_use_id` set | P (partial) | The GUI gets the subagent's text and thinking but not the structured `skill_progress` envelope. Sufficient for a progress UI. |
| Coordinator (read-only) invocation and its two synthesised texts | 29 §14.5 | Only in coordinator sessions | P | Out of scope for afleet unless it runs coordinator mode. |
| `checkPermissions`: auto-allow for a skill that grants nothing beyond text (`vRo` inert set); otherwise **ask** with `Execute skill: <name>` and two suggested rules `{toolName:"Skill", ruleContent:"<name>"}` / `"<name>:*"` | 29 §13.4 | Arrives as a `can_use_tool` control request with `permission_suggestions` (SPEC 45 §45.17, `chunk-2rhzyjym.js:177201` region) | P | Declaring `allowed-tools`, `disallowed-tools` or `hooks` is what forces the prompt — those three are **not** in the inert set. The GUI already handles `can_use_tool`; nothing new. |
| The 11 `validateInput` error codes (1, 2, 4, 5, 7, 8, 9, 10, 11, 12, 13) and their messages | 29 §13.3 | Returned as tool errors in the `user` frame | P | Includes the `Did you mean <suggestion>?` edit-distance hint and the directory-scoped-variants hint. |
| Stacked prompt commands (`/a /b /c rest`, max 5, `Stacked command limit (5) reached — remaining input passed as arguments`) | 29 §15.1 | Works headless — stacking happens in command expansion, before the type gate | P | A GUI's command bar should not block a user from typing `/a /b`. |
| Disabled-skill message (`Skill "<name>" is disabled via skillOverrides. Remove the override from your settings to run it.` — the non-interactive variant, which drops the `/skills` mention) | 29 §15.2 | Arrives as `local_command_output` / an `informational` frame | P | Note the GUI gets the *non-interactive* wording, which does not point at `/skills`. If the GUI rebuilds a skills manager it should rewrite this string to point there. |

---

## 29 · Overrides, hot reload, `/skills`, `/skill-doctor`, `/reload-skills` (chapter 29 §§16–18)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `skillOverrides: {"<name>": "on"\|"name-only"\|"user-invocable-only"\|"off"}`, deep-merged per key across scopes | 29 §16.1 | `get_settings.effective.skillOverrides` and per-scope `sources[]` — **verified present live** | P (read) / R (write) | Writing is disk-only. **Plugin skills can never be overridden per-skill** (`source === "plugin"` always returns `"on"`); disabling one means disabling the plugin. Reproduce that or the GUI offers a toggle that silently does nothing. |
| Lock precedence: `policySettings` > `flagSettings` > the skill's own `disable-model-invocation` (author) > `plugin` | 29 §16.2 | derivable from `get_settings.sources[]` + `SKILL.md` frontmatter on disk | R | A locked row must not be cyclable; in the plugin manager an author-locked row toggles only between `off` and `user-invocable-only`. |
| `/skills` dialog: rows for skills whose `loadedFrom` ∈ {`skills`, `syncedSkills`, `commands_DEPRECATED`, `plugin`, `mcp`} — **bundled, built-in and memory-store skills are not listed** | 29 §18.1 | `{type: "local-jsx", immediate: true}`, **no `local` twin** — verified absent from the live command list; refused with the SPEC 28 §8.1 panel message | X for the dialog; R for the capability | Full rebuild. All strings are in 29 §18.1. |
| `/skills` row format: `<glyph> <label padded to 9>  <name> · <source> · <tokens> tok`, glyphs `✔ on` / `● name-only` / `◯ user-only` / `✘ off`, locked rows prefixed `🔒 ` with ` · locked by <policy\|flag\|author\|plugin>` | 29 §18.1 | none | R | The token estimate is `round(len(name + " " + description + " " + whenToUse) / bytesPerToken)` — needs `when_to_use`, which is **not on the wire** (D; read frontmatter from disk). |
| `/skills` source labels: `claude.ai sync`, `mcp`, `plugin`, `memory store`, `built-in`, else the scope label (`user`, `project`, `project, gitignored`, `cli flag`, `managed`) | 29 §18.1 | Derivable from the `LY` description label already on the wire, or read from disk | P/R | |
| `/skills` verbatim UI strings (`Skills`, `Search skills…`, `No skills found`, `Create skills in .claude/skills/ or ~/.claude/skills/`, `Custom skills are disabled in safe mode — …`, `Plugin skills are managed via /plugin`, `Updated <n> skill override(s)`, `No changes`, `Failed to save skill overrides: <message>`) | 29 §18.1 | none | R | Reuse verbatim except `Plugin skills are managed via /plugin`, which must point at the GUI's plugin manager. |
| `/skills` write semantics: writes to `localSettings` (`.claude/settings.local.json`), skips locked rows, writes `undefined` (deleting the key) when the chosen state equals the inherited project/user baseline, then clears command memoisation | 29 §18.1 | The GUI writes the file, then must call `reload_skills` | R | The delete-when-equal-to-baseline rule matters: without it the GUI accretes redundant keys in every project. |
| `/skill-doctor` | 29 §18.2 | **Two definitions**: `local-jsx` (opens the plugin manager's Stats tab) and `local` with `supportsNonInteractive: true`, `thinClientDispatch: "post-text"`, `isEnabled: () => isNonInteractive()`. **Verified present in the live headless command list.** | P | The GUI gets the **text report** for free by sending `/skill-doctor` as a user message. Gated on `tengu_lantern_prism` or `CLAUDE_CODE_LANTERN_PRISM`; when closed the command does not exist at all. |
| The `/skill-doctor` report: table `skill / source / context / 7d tokens / uses / last used`, three dim explanation lines, the five warning sentences, and the `Plugins not used recently` footer | 29 §18.2 | Arrives as text (via `local_command_output` / an `informational` frame) | P (text) / R (table) | The structured `SkillReport` data model (rows with `owner`, `pluginKey`, `usageCount`, `daysSinceUse`, `listingTokens`, `weekTokens`) is **not** on the wire — only the rendered text. A GUI wanting a sortable table must either parse the fixed-width columns (minimum widths: skill 5, source 6, context 7, week 9, uses 4) or recompute from `~/.claude.json` + transcripts. |
| `/skill-doctor` policy denial (`allow_skill_doctor_transcript_scan`) replaces the 7-day token column with `7d tokens: <note>` | 29 §16.3, §18.2 | in the text | P | HIPAA reason string: `Not shown for HIPAA-regulated organizations: measured by scanning the session transcripts saved on this machine.` |
| `/skill-doctor` entry-point errors (`Skill usage reports are not available on this connection.`, `Couldn't compute skill usage.`, `Couldn't compute skill usage. Run with --debug for details. (<error>)`) | 29 §18.2 | in the text | P | |
| `/reload-skills` | 29 §18.3 | `{type:"local", supportsNonInteractive: true, thinClientDispatch: "post-text"}` — **verified present headless**; also the `reload_skills` control request returning `{skills: [{name, description, argumentHint, aliases}]}` (`cli.pretty.js:177706`) | P | The control request is the better path: it returns the fresh list directly. Note the returned `description` is `LY`-labelled, same as `commands`. |
| `/reload-skills` output (`Reloaded skills: <n> skill(s) available (<a> added, <r> removed)` / `(no changes)`, plus ` (custom skills are disabled in safe mode)`) | 29 §18.3 | text via the slash command; the control request returns the list instead | P | The GUI can diff the returned list itself and produce a better message. |
| The chokidar skill watcher (polls at 2 s active / 30 s after 60 s idle, 300 ms debounce, skips the re-announce when content hashes are unchanged) | 29 §17 | Runs inside the CLI; its effect reaches the host as `commands_changed` | P | **The GUI gets automatic pickup of edited skill files for free** — no need to watch the filesystem itself for `~/.claude/skills`, `~/.claude/commands`, `<project>/.claude/{skills,commands,agents}` at depth 2. |
| Safe mode (`--safe-mode` / `CLAUDE_CODE_SAFE_MODE`) disables **all** custom skills; bare mode (`--bare` / `CLAUDE_CODE_SIMPLE`) restricts discovery to `--add-dir` directories | 29 §5.1, §20.2 | The GUI controls its own launch flags | R | If afleet ever offers a "safe session" toggle it must surface the consequence. |
| `strictPluginOnlyCustomization` policy (blocks `~/.claude/skills`, project skills, legacy command dirs, memory-store skills) | 29 §16.3 | readable from `get_settings.sources[].policySettings` | R | |

---

## 29 · Skill authoring surfaces and settings (chapter 29 §§19–20)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| The `# Saving skills` system-prompt section (four variants by which authoring tool is present) | 29 §19.1 | `lne()` returns `null` unless the entrypoint is `remote_cowork` or `CLAUDE_CODE_SKILL_PROPOSALS` is set | X in a normal session | Not present for afleet today. |
| `propose_skills` tool (renders a review card; render-only) | 29 §19.2 | `isEnabled` requires `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE` set and `CLAUDE_CODE_ENVIRONMENT_KIND` unset, plus the cowork/proposals gate | X today | If it were enabled, the "review card" is a **host-rendered** surface — the tool result is only `{proposalCount}`. A native GUI could implement a genuinely good skill-proposal card, but it needs the env plumbing first. |
| `save_skill` | 29 §19.1, Open questions | The name constant exists; **no tool by that name is built in this bundle** — it is supplied by the hosting surface | D | Potentially a place afleet could inject an SDK MCP tool of its own, but the harness does not define the schema. |
| `SearchSkills` / `ListSkills` / `SuggestSkills` (claude.ai catalogue) | 29 §19.3 | Same `Xce()` gate as the plugin tools — absent in a stdio session | X today | |
| Team-authored skill attribution (`New from your team: /<name> (<author>), …`) | 29 §19.5 | Gated on `tengu_tussock_oriole`; the tip is a TUI startup notification | D | Reproducible from git history (last 7 days of `.claude/skills` and `.claude/commands` additions). Low priority. |
| The `/doctor` skill's malformed-frontmatter guidance (a file whose YAML fails to parse **still loads**, with every field dropped) | 29 §19.4 | `/doctor` is a bundled skill with `terminalOriented: true` — **verified live, it is one of the two `terminal_slash_commands`** | T | A GUI should either run `claude plugin validate` on the skills directories itself or expose its own checkup. This failure mode is silent at normal verbosity and is the most common real-world skill bug. |
| Settings keys: `skillOverrides`, `disableBundledSkills`, `syncClaudeAiSkills`, `skillListingBudgetFraction`, `skillListingMaxDescChars`, `disableSkillShellExecution`, `strictPluginOnlyCustomization`, `enabledPlugins["<name>@skills-dir"]` | 29 §20.1 | all readable via `get_settings` | P (read) / R (write) | Only `outputStyle` is writable over the wire. |

---

## 32 · Output styles (chapter 32)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| The five built-in styles in fixed picker order: `default`, `Proactive`, `Concise`, `Explanatory`, `Learning` | 32 §32.3 | `initialize.available_output_styles` — **verified live as exactly these five**; `initialize.output_style` = the current raw setting (`"default"` live) | P | |
| Custom styles on disk: `<managedDir>/.claude/output-styles` (policy), `<configHome>/output-styles` (user), `<ancestor>/.claude/output-styles` (project, deeper wins) | 32 §32.4.1 | Their **names** appear in `available_output_styles`; their descriptions and bodies do not | P (names) / R (descriptions) | `additionalDirectories` and `localSettings` contribute no styles. Files are found by a recursive walk with a **case-sensitive** `.md` test (plugin styles use a case-*insensitive* test — so `Style.MD` loads from a plugin but not from `~/.claude/output-styles`). |
| Plugin styles named `<plugin>:<style>` | 32 §32.5.1 | included in `available_output_styles` in `plugin:style` form | P | |
| `force-for-plugin: true` — a plugin style **overrides the user's setting entirely** and is invisible to `initialize.output_style`, the `statusLine` payload and the per-turn reminder (all three read the raw setting) | 32 §32.5.3, §32.11.4, §32.12.1 | The GUI cannot tell that a forced style is active | **D** | Real gap: the GUI's style picker would show "default" while a plugin's style is actually in force. **Workaround:** scan enabled plugins' `output-styles/*.md` on disk for `force-for-plugin: true` and badge the picker accordingly. Multiple forced styles log `Multiple plugins have forced output styles: <names>. Using: <name>` — winner order is unspecified (32 Open questions). |
| Resolution precedence: `policySettings` > `projectSettings` (deeper wins) > `userSettings` > plugin > built-in; an unknown name resolves silently to no style | 32 §32.6 | not on the wire | R | The silent-fallback behaviour matters: a GUI that lets a user pick a style that later disappears will show it selected while nothing is applied. |
| `/output-style` command | 32 §32.11.1 | A hidden `local-jsx` "moved to /config" stub, enabled only when `tengu_maple_sundial` is on (default false). **Verified absent from the live headless command list.** | X / T | Its whole behaviour is to print `/output-style moved → Output style in /config` and open the settings dialog. Superseded. |
| The `/config` picker row: `id: "outputStyle"`, `label: "Output style"`, group `Model & output` (fifth of eleven), `type: "managedEnum"`, `options` = the five built-in keys only, `optionsHint: "For custom styles, open /config."` | 32 §32.11.2 | `/config` **is** available headless as its `local` twin (`Set a setting by key`, `argumentHint: "key=value"`) — verified live | P (partial) / R | The non-interactive `/config outputStyle=<v>` shorthand accepts **only the five built-in keys**, so a custom or plugin style cannot be selected that way. **Use `update_settings` instead** (next row). |
| The `Preferred output style` sub-view: subtitle `This changes how Claude Code communicates with you`, `Loading output styles…` placeholder, 10 visible options, each `{label: record.name ?? "Default", description: record.description ?? "Claude completes coding tasks efficiently and provides concise responses"}`, key hints `enter select` / `Esc cancel` | 32 §32.11.2 | none | R | The GUI has the names from `available_output_styles` but **not the descriptions** — those come from each style's frontmatter (built-in descriptions are in 32 §32.3; custom ones need a disk read). |
| Changing the style mid-session | 32 §32.11.2 (writes `localSettings`) | **`update_settings` control request**, and only it: `{subtype:"update_settings", source:"localSettings", settings:{outputStyle:"<name>"}}`. Confirmed at 32 §32.12.2 and SPEC 45 §45.22.8; the handler at `cli.pretty.js:178224` calls the normal settings writer, so the `output_style` prompt-section cache invalidation (32 §32.13) fires. `apply_flag_settings` handles only `model`, `agent`, `fastMode`, `effortLevel`, `ultracode` (`cli.pretty.js:178054`) — **not** `outputStyle`. | P | Constraints to reproduce: `source` must be exactly `"localSettings"`; values must be **strings** (so clearing means sending the literal `"default"`, not `null`); it is refused over a remote transport and in cloud-hosted sessions; it is refused when `--setting-sources` disables `localSettings`. All error strings are returned verbatim (32 §32.12.2). |
| The `/config` change summary line `Set output style to <name>` | 32 §32.11.2 | none | R | Trivial. |
| Safe-mode picker warning: `Your saved output style "<name>" is a custom style disabled in safe mode — <restart without --safe-mode\|unset CLAUDE_CODE_SAFE_MODE> to use it; selecting a style here replaces it`, and the row label suffix ` (disabled in safe mode)` | 32 §32.11.2, §32.14 | Under safe mode `available_output_styles` simply shrinks to the five built-ins — the *reason* is not on the wire | D (minor) | The GUI controls its own launch flags, so it knows whether safe mode is on and can render the warning itself. |
| Effect of a style on **rendering** | 32 §32.3.4, §32.7 | A style only rewrites the system prompt (or, in static-prompt mode, injects an `output_style_instructions` attachment). Nothing in the TUI renders `Explanatory`'s `★ Insight ─────` blocks or `Learning`'s `● **Learn by Doing**` specially — they arrive as ordinary assistant **markdown** | P | **A real opportunity to exceed the TUI.** The Insight block is a stable, machine-detectable shape: a line matching `` `★ Insight ─{41}` `` opening and `` `─{49}` `` closing, both inside backticks (the star is `★` U+2605, or `✶` U+2736 when `TERM=linux`). A native GUI can render these as callout cards. Same for the `Learn by Doing` request format. Note the `Learning` prompt ships a **doubled `## Insights` heading** — a shipped-literal quirk, not a bug to fix. |
| Style-change banners | 32 §32.11.2 | The only banner is `/config`'s post-dialog change summary. There is no informational frame, no notice, and no styles-related startup banner anywhere in the chapter | P (nothing to port) | The per-turn `<system-reminder>` (`<name> output style is active. <turnReminder>`) is request-side only. |
| `keep-coding-instructions` (absent ⇒ the `# Doing tasks` section is **dropped**) | 32 §32.7.2 | not on the wire | R | The single most behaviour-changing frontmatter decision in the format, and it is silent. A GUI's style editor/browser should warn when a custom style omits it. All four built-ins set it to `true`. |
| Creating a custom style | 32 §32.11.1 | There is **no** in-harness style-creation flow — no `/output-style:new`, no scaffolder except `claude plugin init --with output-style` | R | The GUI can offer a proper editor writing `~/.claude/output-styles/<name>.md`; frontmatter keys are `name`, `description`, `keep-coding-instructions`, `force-for-plugin`, hyphenated exactly (`normalizeKeys` is inert in 2.1.257). |
| Picking up a **newly written** style file | 32 §32.13 | Changing the *selection* only evicts the `output_style` prompt-section entry; picking up a new **file** requires one of the cache clears — the plugin-reload path calls `YHe(); fUt();` | R | So after writing a new style file the GUI should issue `reload_plugins` (which clears the output-style caches) before the style will resolve. `reload_skills` does not clear them. |
| `statusLine` stdin JSON carries `output_style: {name: <raw setting>}` | 32 §32.11.4 | statusLine is a TUI concept | T | |
| Cloud forwarding of styles (`Applied settings from your machine: CLAUDE.md, 3 output styles, output style (from your next message)`; the five `outputStyleCheck` outcomes; the `unresolved` warning `the output style your settings select is not available in this session, so it does not apply`) | 32 §32.15 | Only relevant to `claude --cloud` | R/X | Out of scope unless afleet drives cloud sessions. |
| The official `explanatory-output-style` / `learning-output-style` **plugins**, which use a `SessionStart` hook instead of the style mechanism | 32 §32.17 | Their `additionalContext` arrives through the hook pipeline (`--include-hook-events` shows `hook_response`) | P | Their marketplace descriptions call the built-in `Explanatory` style **deprecated** and `Learning` **unshipped**, though both remain selectable. Worth surfacing in a GUI style picker as a note. |

---

## Top gaps in this area

Ranked by how much a user would miss them.

1. **The `/plugin` manager has no headless surface at all.** `local-jsx`, no `local` twin,
   verified absent from the live command list; invoking it yields the SPEC 28 §8.1 panel
   refusal. Five tabs, ~120 distinct strings, the whole install/enable/uninstall/marketplace
   lifecycle. The GUI must rebuild it from `installed_plugins.json` +
   `known_marketplaces.json` + `plugin-catalog-cache.json` + `claude plugin … [--json]`, and
   push changes into the live session with `reload_plugins`. (30 §27) — **X for the panel, R
   for everything it does.**

2. **`/skills` likewise has no headless surface.** Same shape: `local-jsx`, no twin, verified
   absent. The GUI must rebuild the row list (glyphs, four override states, lock precedence,
   source labels, token estimates) and the `localSettings` write semantics including the
   delete-when-equal-to-baseline rule. (29 §18.1) — **X / R.**

3. **`when_to_use` is not on the wire anywhere.** It shapes the model's skill selection, feeds
   the `/skills` token estimate, and is the field a skill author most needs to see. The only
   source is `SKILL.md` frontmatter on disk. (29 §3.1, §12.4, §18.1) — **D.**

4. **The over-budget skill-listing warning is a log line, not a frame.** When skills are elided
   the TUI shows nothing in the transcript; the user discovers it only through `/context` or
   `/skill-doctor`. With `skillListingBudgetFraction` at 0.02 for this user the budget is
   16 000 display columns. The GUI can compute this from `get_settings` + the command list and
   show a standing indicator — better than the TUI. (29 §12.5) — **D, with a strong
   exceed-the-TUI opportunity.**

5. **`reload_plugins` skips the prompt-cache impact pre-flight.** The slash command runs
   `fee()` first and aborts with `This reload changes MCP tools (<server>) and adds the LSP
   tool — your next message will re-read the whole conversation instead of using the cache.`
   The control-request handler (`cli.pretty.js:177681`) calls `cH()` directly with no probe and
   no `--force`. A GUI can silently cost the user a full cache miss. Workaround: diff
   `mcp_status` around the reload and warn afterwards. (30 §27.11) — **D.**

6. **No plugin trust or consent dialog is reachable headless.** The headless dialog host
   (`K_()`, `cli.pretty.js:174428`) forwards only `mcp_elicitation`,
   `refusal_fallback_prompt`, `fable_overage_consent_prompt` and the Slack-connect kinds;
   everything else returns its `default`. The `command`-source review, the `headersHelper`
   review, the install-scope menu, the workspace-trust dialog and `plugin_hint` are all
   unreachable regardless of `supportedDialogKinds`. The GUI must build these itself and route
   the answers through `claude plugin … -y` (command/headers consent) and
   `set_cwd {trust_accepted}` (workspace trust). (30 §22) — **X.**

7. **`command`-source and `headersHelper` installs can fail silently from a GUI.** The CLI
   refuses `-y` when it detects it is inside a Claude Code session, and without a TTY it only
   *displays* the command. A GUI shelling out must scrub Claude Code entrypoint env vars and
   either allocate a PTY or pass `-y`. (30 §22.2, §22.5) — **R with a hard operational
   caveat.**

8. **A `force-for-plugin` plugin style is invisible on the wire.** `initialize.output_style`
   and the `statusLine` payload both report the *raw setting*, so the GUI's picker shows
   "default" while a plugin style is actually in force. Only a disk scan of enabled plugins'
   `output-styles/*.md` reveals it. (32 §32.5.3, §32.12.1) — **D.**

9. **The "Plugins changed / Run /reload-plugins to activate" and autoupdate banners are
   TUI-only.** Both go through Ink's `addNotification`, not the engine's `notification`
   channel that becomes `system/notification`. The GUI must synthesise its own pending-reload
   state — which it can, since it performs the installs, or by watching
   `installed_plugins.json`. (30 §27.11) — **D.**

10. **The skill invocation echo needs deliberate grouping.** The two injected user messages
    (`<command-message>` / `<command-name>` / `<command-args>`, then the `isMeta` body) ride
    the wire and will be replayed. Without using `sourceToolUseID` and `turnCompanion` to fold
    them into the `Skill` tool row, the user sees raw XML presented as their own message.
    (29 §14.1) — **P data, R rendering, high visual cost if missed.**

11. **The `/plugin` Errors tab's guidance text is TUI-only.** `plugin_errors` gives a stable
    `type` tag and a short message; the 30 explanatory guidance strings and five resolve
    actions are not on the wire. They are all quoted in 30 §30.3, so this is cheap to
    reproduce — and skipping it leaves the user with a bare error tag. (30 §27.8, §30.3) —
    **R.**

12. **Plugin skills cannot be disabled individually, and the GUI must not pretend otherwise.**
    `getSkillOverride` returns `"on"` unconditionally for `source === "plugin"`. A skills
    manager that offers a per-skill toggle on plugin rows will appear broken. (29 §16.1) —
    **P behaviour, R UI correctness.**

13. **Only `outputStyle` is writable over the wire.** `update_settings` allows exactly one key,
    into `localSettings`, string values only. Every other settings change in this area
    (`enabledPlugins`, `skillOverrides`, `pluginConfigs`, `extraKnownMarketplaces`) is a disk
    write followed by `reload_plugins` / `reload_skills`. (32 §32.12.2, SPEC 45 §45.22.8) —
    **R, but it constrains the whole architecture.**

14. **`system/plugin_install` progress frames require an opt-in env var.** They only appear
    when `CLAUDE_CODE_SYNC_PLUGIN_INSTALL` is set *and* the output format is `stream-json`, and
    they cover the startup sync of account plugins, not user-driven installs. If afleet wants
    that progress it must add the variable to the child environment. (SPEC 45 §45.14.7,
    `cli.pretty.js:176012`) — **P but opt-in.**

15. **`Explanatory` / `Learning` insight blocks are plain markdown.** Neither surface renders
    them specially. The `★ Insight ─────` fence and the `● **Learn by Doing**` block are
    stable, detectable shapes a native GUI can turn into callout cards — a clear place to beat
    the terminal. (32 §32.3.4) — **P, exceed-the-TUI.**

---

## Unverified

Things inferred rather than read, or read but not confirmed against a live run.

- **`get_context_usage` skill breakdown.** 29 §12.6 describes a `/context` accounting variant
  producing `cappedSkills` / `budgetMode` / `budgetTruncatedSkills` / `budget`. I did not
  confirm whether the `get_context_usage` control response carries that breakdown or only a
  total; that belongs to the context-management area. The live dump contains a
  `get_context_usage` response I did not open.
- **Custom and plugin output styles in `available_output_styles`.** No custom style exists on
  this machine (`~/.claude/output-styles/` is absent per 32's own Open questions), so the live
  response showed only the five built-ins. That plugin styles appear as `plugin:style` is read
  from 32 §32.12.1, not observed.
- **`plugin_hint` reachability.** I confirmed that `K_()` filters dialog kinds and that
  `plugin_hint` is not among the forwarded set, so it cannot reach a headless host. I did not
  separately confirm that its *trigger* (`cli.pretty.js:432448`) runs at all outside the Ink
  REPL; the surrounding code reads as a React hook, which would make it doubly unreachable.
- **Whether `permission_skill` is ever dispatched as a `request_user_dialog`.** The kind is
  defined (`cli.pretty.js:548590`) but the Skill permission ask reaches a headless host through
  `can_use_tool` with `permission_suggestions`. I assume `permission_skill` is the TUI's local
  rendering of the same decision, not a separate wire path.
- **The exact `informational` subtype carrying `/skill-doctor` output.** SPEC 45 lists both
  `local_command_output` and `informational` for local slash-command output; I did not run
  `/skill-doctor` headless to see which one it uses, or whether the report arrives as one frame
  or several.
- **`terminal_slash_commands` composition.** The brief states 2.1.259 reports
  `["doctor","color"]`. I confirmed `doctor` is `terminalOriented: true` and that
  `/reload-plugins` is too, and reasoned that `/reload-plugins` is excluded because
  `system/init.commands` is already filtered by the print-mode predicate
  (`supportsNonInteractive`). I did not observe a `system/init` frame directly — the zero-cost
  handshake in the dump produced none.
- **Bulk-refresh and autoupdate behaviour in a headless session.** 30 §11.3 and §27.11 describe
  marketplace autoupdate at startup. Whether autoupdate runs at all under `-p` (and therefore
  whether the missing autoupdate banner matters) I did not determine.
- **`claude plugin details --json`.** 30 §25.2 says the handler reads `options.json` but no
  `--json` flag is declared, making the branch unreachable. I did not run the command to
  confirm.
