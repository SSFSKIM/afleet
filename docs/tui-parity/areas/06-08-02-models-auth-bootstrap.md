<!-- Provenance: TUI-vs-headless gap inventory produced 2026-09-03 from the Claude Code 2.1.257 SPEC library (~/claude-code-bundle/2.1.257/SPEC) and cross-checked against the installed 2.1.259 binary. Part of docs/tui-parity; the classification legend (P/R/D/X/T) and the authoritative cross-area findings are in ../README.md. -->

# 06 · 08 · 02 — Models & selection, Auth & credentials, Bootstrap & CLI

Area: `06-08-02-models-auth-bootstrap`. Classification letters per BRIEF: **P** parity via
protocol · **R** rebuild client-side · **D** data gap · **X** unreachable · **T** terminal-specific.

Live ground truth used throughout: `/tmp/afleet-gap/init-dump.json` (2.1.259, zero-turn
`initialize` handshake plus `get_usage`, `get_settings`, `get_context_usage`,
`get_session_cost`, `mcp_status`, `background_tasks`, `get_binary_version`). Where the live
capture and the 2.1.257 SPEC disagree, both are stated.

---

## 1. The `/model` picker and the model list (SPEC 06 §15)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/model` interactive picker | `local-jsx`, `requires: {ink:true}`, `immediate`, `thinClientDispatch: "control-request"` — 06 §15 [`chunk-1kg58a1a.js:144983`] | Not in the headless `slash_commands` list (live: 102 commands, `model` present as the **`local` non-interactive** twin only). The GUI drives it with `list_models` + `set_model` control requests (45 §45.22.4, `Tf` schema) | R | The `local-jsx` form is X headless (§8.1 refusal panel). Every GUI must rebuild the picker; the row data is on the wire. |
| Non-interactive `/model <name>` | `local`, `supportsNonInteractive: true`, `isEnabled: () => isNonInteractive()`, hidden interactively — 06 §15.1 | Present in live `slash_commands` (`{"name":"model","description":"Set the AI model for Claude Code","argumentHint":"<model>"}`) | P | Works as a prompt-less command; returns `Set model to <name> …` text on `local_command_output`. |
| Picker row list | `fTe`/`V9r` ladder builds Default + family rows + `[1m]` rows + custom/gateway/allowlist rows — 06 §15.3 | `initialize.models` / `list_models` → `dX()` rows: `{value, resolvedModel, displayName, description, supportsEffort?, supportedEffortLevels?, supportsAdaptiveThinking?, supportsFastMode?, supportsAutoMode?, promoListPrice?, disabled?}` | P | Live rows: `default`→`claude-opus-5[1m]`, `opus[1m]`, `fable`, `sonnet`, `haiku`. `value` is what you feed back to `set_model`; `"default"` resets. |
| Row descriptions ("Opus 5 · Best for everyday, complex tasks", the four family slogans `Gie`/`G8`/`rAe`/`sAe`) | 06 §15.3 table of 22 row builders | Carried verbatim in `models[].description` (live: `"Opus 5 with 1M context · Best for everyday, complex tasks"`) | P | The GUI renders them as-is; the `·`-joined form is already composed server-side. |
| The **Default** row and its attribution suffix (` · Org default`, ` · Set by your organization`, ` · Set by ANTHROPIC_DEFAULT_MODEL`) | 06 §9.3, `defaultModelAttributionSuffix` (`sEt`) | Baked into `models[0].description` when it applies; there is no separate `attribution` field | P | Fine for display, but the GUI cannot *distinguish* "org-locked" from "tier default" programmatically — it would have to substring-match the suffix. |
| Per-Mtok price label (`$5/$25 per Mtok`, ` · (↯) …` for fast-mode price) | 06 §7.5, `getModelPricingSuffix` (`gJe`) | Only inside `description` when the provider is first-party; `promoListPrice` is a separate optional row field | P | Suffix is empty on non-first-party providers, so a GUI must not assume it is present. |
| `[1m]` context variants as separate rows ("Opus (1M context)", "Sonnet 5 (1M context)") | 06 §3.4, §15.3 | Separate `models[]` entries whose `value` carries the literal `[1m]` suffix (live: `"opus[1m]"`) | P | `[1m]` is client-side only and is stripped by `toProviderWireModelId` before the wire (06 §4.3). The GUI must round-trip `value` verbatim, never the `resolvedModel`. |
| `"opus[1m]"` naming and the `(1M context)` display suffix | `getPublicModelDisplayName` (`gx`) appends `" (1M context)"` when the input ends in `[1m]` and the entry has `context.supports_1m_suffix` — 06 §3.6 | Already applied in `displayName` | P | — |
| **Unavailable models with reasons** (disabled rows pushed to the end of the picker) | 06 §15.3; `getModelUnavailabilityReason` (`VN`) returns `{reason:"disabled", description, notOffered?}` or `{reason:"absent", displayName}` — 06 §10.4 | `initialize.unavailable_models` exists in the schema (45 §45.22 table) **but its producer `Kun` returns `[]` unless `CLAUDE_CODE_ENTRYPOINT === "claude-vscode"`, the provider is `firstParty`, and the base URL is first-party** [`cli.pretty.js` `var K9r = new Set(["claude-vscode"])`]. Live capture: field absent. | **D** | Real gap class. A third-party GUI gets only the enabled rows and never learns *why* a model is missing or what the org disabled. Workaround: impersonate `claude-vscode` via `CLAUDE_CODE_ENTRYPOINT` (see §24), or accept the loss. SPEC 06 §15.3 records the same gate. |
| Per-model notices (served-catalog `notice` / `selection_notice` with `{title,text,cta,is_dismissible}`, `badge`, `tooltip`) | 06 §11.1 served row schema | Not projected onto `models[]` rows at all | D | Only reachable through `description`/`disabled`. No protocol carrier for badge/CTA/tooltip. |
| "Not available"/"Update Claude Code to use this model" copy | 06 §10.4 | Only surfaces as the `set_model` / `/model <name>` failure string | R | GUI must render the returned refusal text. |
| Restricted-org step-down notice `Model "<x>" is restricted by your organization's settings. Using <y> instead.` | 06 §15.1 [`chunk-4g3k185a.js:252872`] | Prepended to the `/model <name>` result text | P | Text only; no structured `substitutedFrom` field on the wire. |
| Model-availability-per-account (entitlement deny overlay, `modelAccessCache`) | 06 §10.4 — empty for every provider except `firstParty`/`gateway` | Applied *before* `models[]` is built (denied rows are filtered, not marked) | P (implicitly) / D (for the reason) | The GUI sees the correct list; it cannot show "you could have this on Max". |
| Curated `settings.modelPicker` rows and `replaceBuiltInOptions` | 06 §12 | Fold into `models[]` identically | P | Nothing extra to do. |
| `ANTHROPIC_CUSTOM_MODEL_OPTION` extra row | 06 §15.3 `eXr` | Same | P | — |
| Cloud/thin-client picker (`list_models` with a 15 000 ms timeout, three failure strings) | 06 §15.4 | This is literally the shape a GUI should copy | P | Reuse the same timeout and the same three fallbacks ("pass a model name, e.g. /model sonnet"). |
| `set_model` control request | — | `{subtype:"set_model", model?: string|null, system_prompt?: string}`; omitted/`null`/`"default"` resets. Runs `PreModelSwitch`/`PostModelSwitch`, so it is deferred behind an in-flight dialog and can fail with `set_model failed` — 45 §45.22.4 | P | A GUI must treat `set_model` as async-and-fallible, not fire-and-forget. |
| Cache-miss confirmation dialog (`Switch model?` / `Your next response will be slower and use more tokens` / `Yes, switch to <x>` / `No, go back`) | 06 §16.3 [`chunk-pnta4t8h.js:636242`] | Never emitted headless — it is an Ink dialog, not a `request_user_dialog` kind | X | A GUI that wants the same protection must rebuild it from `get_context_usage` + its own switch bookkeeping. Opportunity to exceed the TUI: show the estimated re-cache cost inline. |
| `PreModelSwitch` hook `ask` decision | 06 §16.2 | Headless **refuses** instead of asking: `Model switch blocked by a PreModelSwitch hook: confirmation required, and this session cannot ask` | X | Documented in the hook's own `permissionDecision` description. |
| Current-model line from bare `/model` (`Current model: <name>…`, `Base model: <name>`) | 06 §16.4 [`chunk-vtx7cbfv.js:770597`] | Non-interactive `/model` with no args prints it | P | — |

## 2. The effort slider and `/effort` (SPEC 06 §17)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/effort` interactive five-stop slider (`low` warning · `medium` success · `high` permission · `xhigh` autoAccept-shimmer · `max` rainbow-animated, plus a `ultracode` violet-ripple stop) | 06 §17.7 [`chunk-cagbxy4k.js:441225`] | `local-jsx`, absent from headless `slash_commands` | X → R | The GUI rebuilds the slider. All inputs are on the wire: `models[].supportsEffort` and `models[].supportedEffortLevels` (live: all five for opus/fable/sonnet, absent for haiku). |
| Non-interactive `/effort` | 06 §17.6, `supportsNonInteractive: true` | Live: `{"name":"effort","description":"Set effort level for model usage","argumentHint":"<low|medium|high|xhigh|max|ultracode|auto>"}` | P | Note the live argumentHint already includes `ultracode` and `auto`. |
| Setting effort programmatically | `/effort <level>` | `apply_flag_settings` with `{settings:{effortLevel: "low"|"medium"|"high"|"xhigh"|null, ultracode: boolean}}` — 06 §17.6 [`chunk-98zn5y0t.js:344405`], 45 §45.22.7 | P | **`max` is not accepted**: the persist filter `ZV` allows only low/medium/high/xhigh, and the TUI itself says `<level> is session-scoped and won't reach the remote process. Use low, medium, high, or xhigh instead.` A GUI must render `max` as achievable only via `--effort max` at launch. |
| `ultracode` (xhigh + standing dynamic-workflow orchestration) | 06 §17.2 `dA`/`lb`; requires dynamic workflows enabled **and** `xhigh_effort` capability **and** org permission | `apply_flag_settings {ultracode:true}`; `settings.ultracode` is session-scoped and never persisted by interactive toggles | P | The three refusal strings (workflows off / org restricts xhigh / model lacks xhigh) come back as command output. `--effort ultracode` at launch also works. |
| `auto` / "no effort parameter" | `/effort auto` → `{kind:"default"}` | `apply_flag_settings {effortLevel:null}` | P | — |
| Per-stop cost multiplier (`~1.6x the estimated cost of high (the default)`) | 06 §17.7, from `effort_cost_index[level] / effort_cost_index[modelDefault]`, gated on `tengu_marbled_teal` | **Not on the wire.** `effort_cost_index` lives only in the baked catalog | D | Workaround: hard-code the six-model `effort_cost_index` table from SPEC 06 §2.3 into the GUI, keyed by `resolvedModel`. Accept staleness across CLI upgrades. |
| Org effort ceiling (`Higher effort levels are restricted by your organization.`, `Your organization's default effort for this model is <level>.`) | 06 §17.3 `S7e`, ceiling from `modelAccessCache[].maxEffortLevel` | Reflected only by `supportedEffortLevels` being short, and by the refusal text `Effort '<x>' exceeds your organization's limit for <model>; using '<y>'.` | P | Enough to render a correct slider; not enough to render the explanatory note. |
| `max` warning copy (`May use excessive tokens resulting in long response times or overthinking. Use sparingly for the hardest tasks.`) | 06 §17.1 `Kre`, §17.7 | Not on the wire | R | Hard-code the constant. |
| Launch-effort pins (Opus 4.7 / 4.8 / Fable 5 held at model default until the user changes effort *interactively*) | 06 §17.5 `wN`; flags `unpinOpus47LaunchEffort` etc. in `~/.claude.json` | `Not applied: the launch-effort pin holds effort at <level> this session. Run /effort <level> in an interactive terminal to release the pin.` | **X** (release) / P (message) | A GUI-only user can never release the pin through the protocol — the message explicitly demands an interactive terminal. Workaround: write the three `unpin*LaunchEffort` booleans into `~/.claude.json` from the host, or launch once with `--effort <level>`. |
| `CLAUDE_CODE_EFFORT_LEVEL` override notices (5 distinct strings) | 06 §17.6 | Returned as command output | P | — |
| Current effort in the footer | TUI status line | `system/init.effort` (`"low"|"medium"|"high"|"xhigh"|"max"|null`) — 45 §45.10.4 | P | Emitted at the start of every turn. Live capture had no turn, so the field was absent from the `initialize` response (it lives on `system/init`, not on `initialize`). |
| `--effort <level>` at launch | 06 §14 | Same flag on the headless command line | P | Already in afleet's launch template. Unparseable values warn on stderr, not fatal. |

## 3. Fast mode and `/fast` (SPEC 06 §18)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/fast [on|off]` interactive toggle | `local-jsx`, `get isHidden() { return !$r() }` — 06 §18.4 | Live headless list **contains** `{"name":"fast","description":"Toggle fast mode (Opus 5)","argumentHint":"[on|off]"}` (the `local` twin, `supportsNonInteractive: true`) | P | The command is reachable; whether it *works* depends on the gate below. |
| Fast-mode state on the wire | — | `initialize.fast_mode_state` and `system/init.fast_mode_state`: `"off" | "cooldown" | "on"`, plus `fast_mode_disabled_reason` — always assigned, 45 §45.10.1/§45.10.4 | P | Live: `fast_mode_state: "off"`, `fast_mode_disabled_reason: "sdk_opt_in_required"`. Also echoed on the `result` frame. |
| **`sdk_opt_in_required` on a headless host** | `dU` (06 §18.1): `if (non-interactive && the SDK opt-in gate applies && flagSettings.fastMode !== true) -> "sdk_opt_in_required"`; message `Fast mode is not available in the Agent SDK` | The live value on this machine | **D → resolvable** | This is the headless host's default state, and it is **opt-in-able**: the gate is bypassed when `flagSettings.fastMode === true`, i.e. when fast mode is set through the *flag settings* layer. Two ways for afleet to opt in: (a) pass `--settings '{"fastMode":true}'` at launch (`--settings` populates `flagSettings`); (b) send `control_request {subtype:"apply_flag_settings", settings:{fastMode:true}}` — this is exactly what `/fast` does over a remote transport [`chunk-6anae7z9.js:287350`]. Without one of those, `/fast on` inside the session will keep returning `Fast mode is not available in the Agent SDK`. |
| Fast-mode promotion of the session model | Turning fast mode on while a non-fast-capable model is selected promotes to `opus` / `opus[1m]` (`OFe()`), running `PreModelSwitch` first — 06 §18.2, §18.4 | `apply_flag_settings {fastMode:true, model?}` carries the promoted model | P | The GUI must expect the model to change under it and re-read `system/init.model`. |
| Which models are fast-capable | `ff()`: capability `fast_mode`, or id contains `opus-4-8`/`opus-5` — 06 §18.2 | `models[].supportsFastMode` (live: true on `default` and `opus[1m]` only) | P | Directly renderable as a per-row badge. |
| Fast-mode result strings (`↯ Fast mode ON · model set to Opus 5 · $10/$50 per Mtok`, `Fast mode OFF`, `Fast mode unavailable: <message>`) | 06 §18.4 | Returned as command output | P | The `↯` glyph and the fast-mode price table (`lve`: Opus 4.8/5 → 10/50, others → 30/150) are client-side; the composed string is not. |
| Cooldown after a 429/overloaded fast request (600 000 ms claim-exhausted, 10 000 ms short) | 06 §18.3 | `fast_mode_state: "cooldown"` on the next `system/init` / `result` | P | Renderable; the *remaining* cooldown time is not on the wire (D, minor). |
| Status-line suffixes ` · Fast mode ON` / ` · Draws from usage credits` | 06 §18.4 [`chunk-vtx7cbfv.js:770309`] | Derivable from `fast_mode_state` | R | Trivial rebuild. |
| Ten unavailability reasons (`not_first_party`, `disabled_by_env`, `model_not_allowed`, `sdk_opt_in_required`, `pending`, `unknown`, `free`, `preference`, `extra_usage_disabled`, `network_error`) | 06 §18.1 | `fast_mode_disabled_reason` carries the raw reason token | P | The GUI should map the token to the SPEC 06 §18.1 message table itself; the message text is not sent. |

## 4. Thinking controls (SPEC 06 §17.9)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `alwaysThinkingEnabled` toggle | Settings key; `false` disables thinking. `sAn()`/`JN()` — 06 §17.9, §12 | `update_settings` (localSettings only) or `--settings`; readable via `get_settings` | P | `MAX_THINKING_TOKENS > 0` also disables the "always thinking" default. |
| `set_max_thinking_tokens` control request | — | `{subtype:"set_max_thinking_tokens", max_thinking_tokens?: int|null, thinking_display?: "summarized"|"omitted"|null}`; validation error text at 45 §45.22.5 | P | Omit/null resets to the session default. This is the only mid-session thinking control. |
| Thinking display modes `summarized` / `omitted` | `showThinkingSummaries` setting; a non-interactive session with `--output-format text`, or `json` without `--verbose`, **forces `omitted`** — 06 §17.9 | afleet runs `--output-format stream-json --verbose`, so `summarized` survives | P | Important: do not drop `--verbose`, or thinking content disappears. |
| `--thinking <enabled|adaptive|disabled>` / `--thinking-display <summarized|omitted>` launch flags | Hidden root options — 02 §4.3 | Same flags on the headless command line | P | Hidden but real. |
| Thinking content on the wire | `✻ Thinking…` spinner (41 §—, glyph `oE`) | `assistant` frames with `thinking` content blocks; `system/thinking_tokens` `{estimated_tokens, estimated_tokens_delta}` during the redacted-thinking phase | P | `thinking_tokens` is only digested from `thinking_delta.estimated_tokens` when the API streams pings; use it for a live "thinking" meter. |
| **"Thought for N seconds"** | **Not a TUI string.** The only occurrence in the binary is a release-note line describing the **VS Code Focus view**: `thinking-only folds show "Thought for Ns" and re-collapse when their turn completes` | Nothing emits it headless | T / D | The terminal shows `✻ Thinking…` with no elapsed count. A GUI can exceed both by timing the thinking block from the `stream_event` deltas itself (start of first `thinking_delta` → `content_block_stop`). |
| Adaptive thinking availability | `supportsAdaptiveThinking` (`KFe`) — 06 §8.3 | `models[].supportsAdaptiveThinking` (live: true on opus/fable/sonnet, absent on haiku) | P | — |

## 5. The advisor (SPEC 06 §12, SPEC 14 §—)

| Feature | TUI behaviour | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/advisor [model|off]` | `local-jsx`, `requires: {ink:true}`, `thinClientDispatch: "control-request"`, `isEnabled: () => bH()`, hidden when the gate is off. Description: `Let Claude consult a stronger model at key moments` [`cli.pretty.js`] | **Absent from the live headless `slash_commands` list** (all 102 names checked) | **X** | No `local` twin exists. A GUI cannot turn the advisor on or off mid-session. |
| Setting the advisor model | `/advisor <model>` writes `settings.advisorModel` | `--advisor <model>` at launch (hidden root option, 02 §4.3: `Enable the server-side advisor tool with the specified model (alias or full ID).`), or `settings.advisorModel` via `--settings` / `update_settings` | R | This is the workaround for the X above: afleet should expose the advisor as a **launch-time** or settings-level control, not a mid-session toggle. |
| Advisor eligibility | `advisor_rank` in the baked catalog gates it; `[AdvisorTool] Skipping advisor - <m> cannot advise <base> (advisor must be at least as capable as the base model)` | Not on the wire; only the debug log | D | Rebuild from the `advisor_rank` column of SPEC 06 §2.3 (haiku 1, sonnet-4-6 2, sonnet-5/opus-4-6 3, opus-4-7/4-8/5 4, fable/mythos 5). |
| Advisor tool on the request | `{type:"advisor_20260301", name:"advisor", model}` pushed into the tool list; beta `advisor-tool-2026-03-01` | Server-side tool — its output arrives as `advisor_message` iterations inside the server-tool loop, surfacing on `assistant` frames | P | The GUI renders them like any other content block. There is no dedicated frame subtype. |
| Advisor incompatibility error | `API Error: … · The configured advisor model is not compatible with this request model — change or unset the advisorModel setting (or the --advisor flag)` (the non-interactive variant is already selected by `Oe()`) | Same text on `result` `error_*` | P | The message is already phrased for a headless caller. |

## 6. Model fallback, refusal and the consent dialog (SPEC 06 §20)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Availability-chain fallback (529 ×3, 404/403/5xx, last resort) | 06 §20.1–§20.2; `system/model_fallback` | `system` frame `subtype: "model_fallback"` — passed through the wire filter unchanged (45 §45.9.2) | P | Render as an inline banner. |
| Refusal fallback | 06 §20.3; `system/model_refusal_fallback` with `scope: "session"|"local"` | Frame fields: `trigger`, `direction`, `scope?`, `original_model`, `fallback_model`, `request_id`, `api_refusal_category`, `api_refusal_explanation`, `saw_cyber_refusal?`, `retracted_message_uuids?`, `refused_user_message_uuid`, `content` [45 §45.13.2] | P | The `provisional` flag is stripped before the wire; a provisional banner may be *superseded* — the GUI must honour `retracted_message_uuids` and re-render, exactly as the TUI's collapser does. |
| `model_refusal_no_fallback` | 06 §20.3 | Passed through | P | — |
| Fable credit-consent fallback | 06 §20.4; `system/model_consent_fallback` — `Switched to <NewModel> <scope> · <FableName> requires usage credits · /model to change` | Passed through | P | The `/model to change` instruction is wrong copy for a GUI; rewrite it. |
| **The refusal-fallback consent dialog** | An interactive choice ("retry on fallback model or edit prompt") | `request_user_dialog` with `dialog_kind: "refusal_fallback_prompt"` [`SPEC 36 §—`: `var r = { refusal_fallback_prompt: "choose: retry on fallback model or edit prompt" }`]. **Reachable headless, but only if the host declares it** in `initialize.supportedDialogKinds` | **P, conditional** | The schema is explicit: absence of the kind is treated as "cannot display" and the flow **fails closed to the classic refusal error**. afleet must send `supportedDialogKinds: ["refusal_fallback_prompt"]` *and* implement `onUserDialog`, or it silently loses the choice. A host must never answer `{behavior:"cancelled"}` for a kind it did not declare. |
| Dialog timeout | — | The CLI cancels an unanswered dialog after its deadline (`tengu_request_user_dialog_timeout`), injecting `{behavior:"cancelled"}` locally; a late answer is discarded | P | Budget a response deadline in the GUI. |
| Pending dialogs on reconnect | — | `initialize` response carries pending `request_user_dialog` requests (sibling of `pending_permission_requests`) so a joining client re-arms them; the same `request_id` may also arrive as a live frame — render once | P | 45 §45.— (`jU`). |
| `--fallback-model <m1,m2,m3>` | `Enable automatic fallback… Re-tries the primary at the start of each user turn. (only works with --print)` — 06 §14, 02 §4.3 | Print-only by design; cap 3, `default` expands, disallowed entries dropped, window-shrinking targets filtered | P | afleet already runs `--print`, so this flag is fully available. Expose it as a session setting. |
| `settings.fallbackModel` array | 06 §12 | Settable via `--settings` | P | SPEC 06 open question: whether it is re-read mid-session is undetermined. |
| `CLAUDE_CODE_NO_MODEL_FALLBACK` | Collapses every chain to `[primary]` | Env var at launch | P | — |

## 7. Model naming, `[1m]`, and availability per account (SPEC 06 §3, §9, §10)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Alias vocabulary accepted by `--model` / `set_model` | `sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan`, plus `default` and `inherit` — 06 §3.1 | Same strings accepted by `set_model` | P | The non-interactive `/model` usage line enumerates them: `Usage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID.` |
| `opusplan` (Opus in plan mode, Sonnet otherwise) | 06 §3.5; `renderDefaultModelSetting` → `"Opus in plan mode, else Sonnet"` | Accepted by `set_model`; the effective model changes with `permissionMode` | P | The GUI must not assume `system/init.model` equals the picked value — plan mode substitutes. |
| `[1m]` refusals at switch time (`Opus with 1M context is not available for your account.` / `Sonnet with 1M context is not available for your account.` with a docs link) | 06 §3.4 | Returned as the `set_model` / `/model` failure message | P | — |
| Resolved model id vs. picked value | `renderModelName` ladder — 06 §3.6 | `models[].value` (pick) vs `models[].resolvedModel` (concrete id) vs `system/init.model` (what the turn actually used) | P | Three distinct things; a GUI that conflates them will mis-highlight the picker. |
| Deprecation / retirement banners (`⚠ <Model> will be retired on <date>…`, `⚠ <x> is automatically remapped to <Opus>…`) | 06 §21 | Emitted as `informational` notice frames | P | Class of frame confirmed by the headless baseline (45 §45.9.1 `informational`). |
| Model restore on resume + `Session model <m> could not be restored (<reason>) — using <target> instead.` | 06 §22 | Emitted as an `informational` frame on a `--resume` launch; `PostModelSwitch` fires with `source:"resume"` | P | — |
| Org default / `enforceAvailableModels` warnings (five verbatim strings) | 06 §10.2 | `informational` warnings | P | — |
| Third-party default-probe notices (`Opus: Opus 5 not available — using Opus 4.6. Enable … in the Bedrock console to upgrade.`) | 06 §4.5 | `informational` at startup | P | Only relevant if afleet ever runs Bedrock/Vertex. |

## 8. Model-related fields in `initialize` and `system/init` (SPEC 45 §45.10)

| Feature | TUI behaviour | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `footer_indicator` | A short server-pushed badge in the TUI footer | `initialize.footer_indicator` / `system/init.footer_indicator`. **Recovered shape** (SPEC 06/45 leave it as `object`): built by `Mxt()` = `oYt(clientData().footer_indicator)`, which parses `{ text?: string }`, and on a non-empty text returns `{ text: <sanitised> }`, else `undefined`. Sanitiser `ry`: strip ANSI, strip `[\x00-\x1f\x7f-\x9f]`, trim, truncate to **32** chars (`ny`) with a **6**-char floor (`ty`) [`cli.pretty.js`, `var ty = 6, ny = 32`] | P | So it is exactly a short text badge, ≤32 chars, sourced from server client-data — not model-specific. Live capture: absent (no client-data indicator configured). On a Remote Control bridge it is blanked (`footerIndicator: void 0` in `hrt()`). |
| `apiKeySource` | `/status` "API key:" row | `system/init.apiKeySource`: `"ANTHROPIC_API_KEY" | "apiKeyHelper" | "/login managed key" | "none"` (plus five legacy members current CLIs never emit) — 45 §45.10.4 | P | Live `initialize.account.apiKeySource` was absent (OAuth session), and `account.apiProvider` was `"firstParty"`. |
| `account` block | `/status` rows | `initialize.account` = `{email, organization, subscriptionType, tokenSource, apiKeySource, apiProvider}`. Live: `{"email":"…","organization":"…'s Organization","subscriptionType":"Claude Max","apiProvider":"firstParty"}` | P | This is the account row a GUI renders. Note `subscriptionType` is the **display name** (`Claude Max`), not the raw tier. |
| `current_model`, `current_permission_mode`, `session_state` | — | On the `initialize` response (live: `current_permission_mode`, `session_state` present; `current_model` present on cloud/bridge transports via `getInitializeState`) | P | — |
| `effort` on `system/init` | Footer | Present per 45 §45.10.1/§45.10.4 | P | Only on `system/init` (start of a turn), not on the zero-turn `initialize` response. |

---

## 9. `/login`, `/logout` and the OAuth flow (SPEC 08 §4, §13.3, §14)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `/login` | `local-jsx`, `isEnabled: !DISABLE_LOGIN_COMMAND`; description computed at render: `Switch Anthropic accounts` when a key is present, else `Sign in with your Anthropic account`. Declares a `fleetHostCall` — 08 §13.3 | **Absent from the live headless `slash_commands` list** | **X → P via control requests** | See the next three rows: the protocol has a full, unpublished sign-in surface. |
| `/logout` | `local-jsx`, `Sign out from your Anthropic account`; body prints `Signing out…` / `Couldn't sign out — <message>` — 08 §13.3, §8.7 | Absent headless; **no** `claude_logout` control request exists | **X** | Workaround: the GUI shells out to `claude auth logout` (08 §14.3, prints `Successfully logged out from your Anthropic account.`, exit 0/1). That is a separate process, so the running session keeps its in-process token until restarted. |
| **`claude_authenticate`** (unpublished control request) | — | **Recovered from `chunk-2rhzyjym.js:177977`.** Request: `{subtype:"claude_authenticate", loginWithClaudeAi?: boolean}` (defaults to `true` — `false` selects the Anthropic Console flow). Behaviour: (1) `validateForceLoginMethod(loginWithClaudeAi)` — a managed-settings pin refuses with the policy message and `force_login_method_refused`; (2) cleans up any prior flow; (3) emits `tengu_oauth_flow_start`; (4) honours `forceLoginOrgUUID` when the chosen method agrees with `forceLoginMethod`; (5) starts `startOAuthFlow(..., {loginWithClaudeAi, orgUUID, skipBrowserOpen: true})`. **Response: `{manualUrl, automaticUrl}`** — the two authorize URLs from `buildAuthUrl` (manual → `https://platform.claude.com/oauth/code/callback`; automatic → `http://localhost:<ephemeral>/callback`). Errors: `Bn(d,"claude_authenticate", err)`. | **P (unpublished)** | `skipBrowserOpen: true` means **the CLI does not open a browser** — the GUI owns that. This is the only way a GUI can offer sign-in without the terminal. The loopback listener is still started by the CLI on 127.0.0.1 at an OS-assigned port, so the automatic redirect works if the GUI opens `automaticUrl` on the same machine. |
| **`claude_oauth_callback`** | — | Request: `{subtype:"claude_oauth_callback", authorizationCode: string, state: string}`. Refused with `No active claude_authenticate flow` when no flow is armed. Calls `handleManualAuthCodeInput({authorizationCode, state})`, then awaits the flow (same body as `claude_oauth_wait_for_completion`). | **P (unpublished)** | This is the **paste-code fallback**: the user copies `<code>#<state>` from `https://platform.claude.com/oauth/code/callback`; the GUI splits on `#` (both halves non-empty — the TUI's own validation is `Invalid code. Please make sure the full code was copied`) and sends the two fields. |
| **`claude_oauth_wait_for_completion`** | — | Request: `{subtype:"claude_oauth_wait_for_completion"}` (no fields). Same refusal when no flow is armed. Awaits the in-flight flow and replies **`{account: {email, organization, subscriptionType, tokenSource, apiKeySource, apiProvider}}`** — i.e. the same `getAccountInformation()` shape as `initialize.account`. On failure: `claude_oauth_callback failed` / the sanitised error. | **P (unpublished)** | Use this when the user completed the browser leg and the loopback listener caught the code. The reply is the GUI's cue to re-render the account row. |
| Post-login side effects the GUI gets for free | — | Inside the handler: `Xae()` persists tokens, identity change is broadcast, `validateForceLoginOrg` runs (a failure logs the user back out and throws `Login blocked: this machine's managed settings policy could not be satisfied or verified. Run claude auth login from a terminal for details.`), and the commands/models are rebuilt and re-pushed | P | An org-pin failure is a **hard stop the GUI must surface verbatim**, because the recovery genuinely requires a terminal. |
| Account-switch semantics | 08 §4.8 `lZt`: compares incoming identity, classifies `same_account` vs `account_switch`, runs `performLogout({clearOnboarding:false, preserveInProcessTokens:true, preserveNonAnthropicAuth:true})` | Happens inside `claude_authenticate` | P | The GUI should treat an account switch as invalidating every cached model/usage/settings view. |
| The login-method menu (`Claude account with subscription` / `Anthropic Console account` / `3rd-party platform`) and the Console submenu (`Sign in with your Console account (recommended)` / `Create an API key (legacy)` / `Go back`) | 08 §4.7 | Not on the wire — `claude_authenticate` takes only the `loginWithClaudeAi` boolean | R | The GUI rebuilds a two-option chooser (subscription vs Console). The Console **keyless/profile** variant (`wif`) and the 3rd-party platform wizards are not reachable through the control request at all → X; shell out to `claude auth login --console` / `/login` in a terminal. |
| `--sso` / `--email <addr>` login hints | `claude auth login --sso`, `--email` map to `login_method=sso` and `login_hint` on the authorize URL — 08 §4.4, §14.1 | Not exposed on `claude_authenticate` | D | Workaround: shell out to `claude auth login --sso --email <x>`. |
| Gateway (`forceLoginMethod: "gateway"`) device-code login | 08 §19.4, an Ink screen with a TLS-trust prompt and a `user_code` | `claude_authenticate` refuses: `forceLoginMethod is 'gateway' in managed settings; run /login from an interactive terminal to authenticate.` | **X** | Enterprise gateway customers cannot sign in from a GUI at all. Flag this to the user with the exact message. |
| `claude setup-token` (long-lived, 1-year, inference-only) | 08 §15 | A separate CLI invocation with its own Ink screen; the token is printed once and never stored | T / X | A GUI can shell out but must capture stdout. Note the consequence: an inference-only token has **no refresh token** and cannot self-heal, and Remote Control refuses it. |
| Trusted-device enrolment on `/login` | 08 §8.8; `Your organization requires Trusted Devices for Remote Control, but this device is not enrolled. Please run \`/login\` in Claude Code to enroll this device.` | Enrolment runs inside the login flow, so `claude_authenticate` enrols too (same `Xae` path) | P | Only matters for Remote Control. |

## 10. Token refresh, expiry banners and auth errors (SPEC 08 §5–§7, §23)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Silent refresh (5-minute skew, cross-process lock, CAS persistence) | 08 §5.8, §6 | Entirely internal; the GUI sees nothing unless it fails | P (invisible) | Nothing to build. |
| `Login expired · Please run /login` | 08 §23.1/§23.2 branch 7 (`OAuthRefreshDeadError`) | Interactive text; the **non-interactive** variant is `Failed to authenticate: OAuth session expired and could not be refreshed` and arrives on a `result` `error_*` frame | P | The GUI must map the non-interactive phrasing (it will never see "run /login") and offer its own sign-in button wired to `claude_authenticate`. |
| `Could not refresh your login because another Claude Code process is refreshing it…` | 08 §23.1, branch 8 | Non-interactive variant: `Failed to refresh OAuth token: another Claude Code process is refreshing it or exited mid-refresh. This is usually transient; retry in a minute…` | P | Retryable — the GUI should offer retry rather than sign-out. |
| `OAuth token revoked · Please run /login` | branch 11 | Non-interactive: `Your account does not have access to Claude. Please login again or contact your administrator.` | P | — |
| `Your account is on hold and can't use Claude Code. View details or appeal: <url>` | 08 §23.3, gated on `tengu_lively_beaver`; URL sanitised to `claude.ai`/`anthropic.com` or `https://claude.ai/restricted` | Same text on `result` | P | Render the URL as a link. |
| Org disabled API-key auth / disabled organization (4 + 2 variants) | branches 3, 12, 13 | Same text | P | — |
| `Your apiKeyHelper script is failing · … · Run /status to see the script's error output` | branch 4 | `/status` is **not** in the headless command list | D (for the detail) | The helper's stderr *is* reachable: the `auth_status` frame (next row) carries it. Rewrite the message. |
| **`auth_status` frame** | The TUI's "authentication indicator" that streams `apiKeyHelper` / `awsAuthRefresh` / `gcpAuthRefresh` output live | **Real on this build.** `--enable-auth-status` is a hidden root option (`Enable auth status messages in SDK mode`, default `false`) — 02 §4.3, 45 §—. Frame schema recovered: `{type:"auth_status", isAuthenticating: boolean, output: string[], error?: string, uuid, session_id}` [`cli.pretty.js`, `nse`] | **P, opt-in** | afleet must add `--enable-auth-status` to its launch line to get it. Emitted right after the `initialize` response in the handshake (45 §45.18.5, `opt enableAuthStatus`). Only meaningful when `apiKeyHelper` / an AWS/GCP refresh command is configured. |
| SDK-driven token refresh (`oauth_token_refresh`, `host_auth_token_refresh`) | — | CLI → host control requests, installed **only** when `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH` is set **and** `CLAUDE_CODE_ENTRYPOINT ∈ {claude-desktop, local-agent, claude-vscode}` — 08 §9.4, 45 §45.22.14 | **X for a third-party host** | Entrypoint-gated. afleet cannot own the credential unless it impersonates one of those three. Not a loss in practice: the CLI refreshes its own stored login fine. |
| `AWS credentials expired or invalid · run \`<awsAuthRefresh>\` and retry…` / Google Cloud variants | 08 §23.2 branch 14 | Same text | P | Only for 3P providers. |

## 11. Rate limits, usage and the credit surfaces (SPEC 08 §13)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `rate_limit_event` frame | The TUI's rate-limit banner | Frame `{type:"rate_limit_event", rate_limit_info, uuid, session_id}`, "emitted when rate limit info changes". **`rate_limit_info` shape recovered** [`cli.pretty.js` `wie`]: `{status: "allowed"|"allowed_warning"|"rejected", resetsAt?: int, rateLimitType?: "five_hour"|"seven_day"|"seven_day_opus"|"seven_day_sonnet"|"seven_day_overage_included"|"overage", utilization?: number, unifiedWindows?: {five_hour?, seven_day?, seven_day_overage_included?} each {utilization, resetsAt}}` | P | Everything a banner needs is on the wire. |
| Rate-limit *type* display names | `five_hour`→`session limit`, `seven_day`→`weekly limit`, `seven_day_opus`→`Opus limit`, `seven_day_sonnet`→`Sonnet limit`, `seven_day_overage_included`→`Fable limit`, `overage`→`usage credit limit` — 08 §13.2 | Only the raw token is sent | R | Hard-code the six-entry map. |
| Rate-limit response headers (~25 `anthropic-ratelimit-unified-*`) | Parsed into the per-request limit state — 08 §13.2 | Digested into `rate_limit_event`; the raw headers never reach the host | P (for the digest) / D (for grace/slow-lane fields) | `grace-status`, `slow-*` and `overage-period-*` headers are parsed by the CLI but are **not** in `wie` — a GUI cannot render the grace-window or slow-lane meters from the wire. |
| Grace-window system reminder `[Usage limit reached — grace window active. Wrap up: finish or checkpoint; don't start subagents or long work.]` | 08 §13.2 | Injected into the model's context, not shown to the user | — | Not a UI affordance; noted so a GUI does not double-report it. |
| **Auto-continue when the limit resets** | `Wait here, then continue automatically at <time>` / `Wait here, then continue automatically when the limit resets` (confirmation phrase `when your usage limit resets`); the countdown row renders `auto-continue in <N>s · any key to stay`; preference `autoContinueAtUsageLimit` (default **true**), entitlement precondition `isClaudeAISubscriber() && billingType !== "usage_based"` — 08 §13.2 [`chunk-y8kk9qcx.js:825410`, `:825459`, `:825506`]; rendering owned by 41 §16.11 | **No auto-resume headless.** The quota auto-resume state machine is an interactive-session affordance; a headless turn that hits the wall ends with a `result` `error_*` and a `rate_limit_event` carrying `resetsAt`. | **D** | Real gap. The GUI must implement the wait-and-resubmit itself: on `status:"rejected"`, park the turn, count down to `resetsAt`, and re-send the user message. It has everything it needs (`resetsAt` is an epoch-second int). Opportunity to exceed the TUI: a GUI countdown survives the app being backgrounded, and can notify. |
| `/rate-limit-options` | `local-jsx`, `isHidden: true`, `isEnabled: () => isClaudeAISubscriber()`, `Show options when rate limit is reached` | Absent from the live headless list | **X** | Rebuild: the options it offers are exactly the other rows in this table (credits, upgrade, low-priority, wait). |
| `/low-priority` (the slow lane) | Command name is `low-priority` (`uX`), gated on GrowthBook `tengu_toasty_breeze.enabled`. Copy block `K8`: label `Continue now at lower priority`, notice `/low-priority to continue now at lower priority · uses your weekly limit`, status `Lower priority until {reset}`, allowance `{percent} allowance left`, wait banner `Working at lower priority · waiting for capacity`, exhausted `You've used this week's lower-priority allowance`; cooloff 10 min default (max 1440) | Absent from the live headless list (gate off on this account) | **X** | Even when the gate is on it is a `local-jsx` surface. Slow-lane budget headers are not in `wie` (see above), so a GUI cannot render the `{percent} allowance left` note. |
| `/limit-reset` | **Does not exist as a command in 2.1.257.** The reset time is surfaced by `/usage` and by the rate-limit banner | — | — | Brief's name; the real affordances are `/usage` and `rate_limit_event.resetsAt`. |
| `/usage-credits` (hidden alias `/extra-usage`) | `local-jsx` + `local`; `isEnabled: isExtraUsageAllowed()` (billing type in the 7-entry overage set, and not `DISABLE_EXTRA_USAGE_COMMAND`) — 08 §12.3 | **Present** in the live headless list: `{"name":"usage-credits","description":"Configure usage credits or request them from your admin when you hit a limit"}` and `{"name":"extra-usage","description":"Renamed to /usage-credits"}` | P | The `local` twin runs headless. Confirm behaviour before promising it to users — the interactive purchase flow itself is Ink. |
| `/upgrade` | `local-jsx`, `Upgrade to Max for higher rate limits and more Opus`, `availability: ["claude-ai"]`, `requires: {ink:true}` | Absent headless | **X** | Rebuild as a link-out to the billing page. |
| `/passes` | `local-jsx`; description varies: `Share a free week of Claude Code with friends and earn usage credits` or `Share a free week of Claude Code with friends` | Absent headless | **X** | Link-out. |
| `/pro-trial-expired` | `local-jsx`, `isHidden: true`, `Options shown when the Pro plan Claude Code trial has ended` | Absent headless | **X** | Trial-expiry is also surfaced by `oauthAccount.claudeCodeTrialEndsAt` (readable from `~/.claude.json`) → R. |
| `/privacy-settings` | `local-jsx`, `isEnabled: () => isConsumerSubscriber()`, `View and update your privacy settings` | Absent headless | **X** | The underlying `grove_enabled` account field is server-side (08 §11.3). In `--print` mode the CLI writes the consumer-terms notice to **stderr** and, past the deadline, **exits 1** — a GUI must watch stderr and surface that. |
| `/usage` (aliases `cost`, `stats`) | `local-jsx` + `local`; `Show session cost, plan usage, and what's contributing to your limits` | **Present** headless (live) | P | — |
| `get_usage` control request | — | Live response: `{session: {total_cost_usd, total_api_duration_ms, total_duration_ms, total_lines_added, total_lines_removed, model_usage}, subscription_type: "max", rate_limits_available: true, rate_limits: {...}, behaviors: {...}}` | P | The richest usage surface a GUI has. |
| `get_usage.rate_limits` | — | Live: `five_hour` `{utilization:55, resets_at, limit_dollars, used_dollars, remaining_dollars, locked_reason}`, `seven_day` `{utilization:73, …}`, plus null-valued `seven_day_oauth_apps/opus/sonnet/cowork/omelette`, `tangelo`, `iguana_necktie`, `omelette_promotional`, `nimbus_quill`, `cinder_cove`, `amber_ladder`, `juniper_tide`; `extra_usage` `{is_enabled, monthly_limit, used_credits, utilization, currency, decimal_places, disabled_reason:"out_of_credits", user_disabled, spend_limit_reached, credits_ever_enabled, daily, weekly}`; `limits[]` `{kind, group, percent, severity, resets_at, scope:{model:{id,display_name}}|null, is_active}`; `spend` `{used:{amount_minor,currency,exponent}, limit, percent, severity, enabled, disabled_reason, cap, balance, auto_reload, disclaimer, can_purchase_credits, can_toggle}`; `member_dashboard_available`; `model_scoped[]` `{display_name, utilization, resets_at}` | P | Note this live shape is **richer than SPEC 08 §13.1** (which documents the older `/api/oauth/usage` `utilization` schema). `limits[].severity` and `is_active` are exactly what a GUI needs to pick which meter to foreground. |
| **`get_usage.behaviors`** — what it contains | — | Live: two buckets, `day` and `week`, each `{request_count, session_count, behaviors: [{key, pct, count}], agents: [{name, pct}], skills: [{name, pct}], plugins: [{name, pct}], mcp_servers: []}`. Observed `behaviors[].key` values on this machine: `subagent_heavy` (pct 97), `long_context` (pct 75) | P | It is a **usage-pattern profile**, not a rate limit: how this account's traffic is shaped (percentile ranks against the population, plus which agents/skills/plugins/MCP servers dominate). Useful for a GUI "your usage" panel; nothing else consumes it. |
| `get_session_cost` / `get_context_usage` | `/cost`, `/context` | Control requests; `/context` is also in the live headless command list | P | — |

## 12. API key sources, `apiKeyHelper` and provider setup (SPEC 08 §2, §10, §14, §21)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `apiKeySource` in the status panel | `/status` rows — 08 §14.5 | `system/init.apiKeySource` and `initialize.account.apiKeySource` | P | Four live values; five legacy members exist only for type compatibility. |
| Auth-token source (`claude.ai`, `ANTHROPIC_AUTH_TOKEN`, `apiKeyHelper`, `CLAUDE_CODE_OAUTH_TOKEN`, fd variants, `profile`, `none`) | `/status` "Auth token:" row — 08 §2.1 | `initialize.account.tokenSource` | P | Live: absent (OAuth session with no token-source annotation). |
| Custom-API-key approval dialog (`Detected a custom API key in your environment` / `ANTHROPIC_API_KEY: sk-ant-...<20>` / `Yes` / `No (recommended)`) | 08 §10.4 | **Bypassed headless**: `getAnthropicApiKeyWithSource` step 3 returns an unapproved `ANTHROPIC_API_KEY` outright when non-interactive and the client type is not `claude-vscode` — 08 §2.2 | X (the dialog) | Security note for afleet: a headless host silently trusts `ANTHROPIC_API_KEY`. If afleet injects one it must own that decision; if the user's shell exports one it will be used without consent. |
| `apiKeyHelper` failures | `apiKeyHelper failed: <message>` in red on stderr, pushed into the authentication-status indicator — 08 §10.2 | stderr + the `auth_status` frame (with `--enable-auth-status`) | P, opt-in | See §10. |
| Workspace-trust gate on project/local `apiKeyHelper` / `awsAuthRefresh` / `awsCredentialExport` / `gcpAuthRefresh` | Executed only after trust is confirmed — 08 §10.1 | **The trust dialog is skipped in `-p`** (02 §4.3) — see §18 below | **security-relevant** | Trust is still *resolvable* from disk (`hasTrustDialogAccepted`); a headless launch in an untrusted directory therefore does not run these helpers, which is correct, but it also never asks. |
| `/setup-bedrock` | `local-jsx`, `Reconfigure Amazon Bedrock authentication, region, or model pins` | Absent from the live headless list | **X** | Bedrock configuration is env-var and settings driven (08 §21, 06 §13); a GUI rebuilds the wizard as a settings form and writes `--settings` / `update_settings`. |
| `/setup-vertex` | `local-jsx`, `Reconfigure Google Vertex AI authentication, project, region, or model pins` | Absent headless | **X** | Same. |
| 3rd-party platform wizards inside `/login` (`platform_setup` → `bedrock_done` / `vertex_done` / `aws_refresh_running`) | 08 §4.7 state machine; on Enter it marks onboarding complete and **relaunches the process** | Unreachable | **X** | A GUI must never promise Bedrock/Vertex onboarding; direct users to the docs or to a terminal. |
| Foundry / Claude-Platform / Mantle credentials | 08 §21.5 | Pure env-var configuration | P | Nothing interactive. |
| `claude auth status --json` | `{loggedIn, authMethod, apiProvider, analyticsDisabled, projectsDirectory, forcedLoginMethod?, apiKeySource?, email?, orgId?, orgName?, subscriptionType?}`; exit 0/1 — 08 §14.4 | A shell-out the GUI can use *outside* a session | R | Useful for a pre-launch "are we signed in?" check. `--text` renders the `/status` rows. |

---

## 13. The welcome screen, onboarding and first-run surfaces (SPEC 02 §8.9)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Welcome banner (`Welcome to Claude Code` + `v2.1.257`, with a wide-terminal ASCII variant and per-theme colouring) | 02 §8.9 [`cli.pretty.js` `ZB()`] | Nothing | T | A GUI has its own launch surface. |
| Onboarding screen (shown when `!hasCompletedOnboarding` or `CLAUDE_CODE_POWERUP_ONBOARDING`) | 02 §8.9 step D | Never runs headless: `on()` short-circuits for background/bridge sessions, and the whole `runOnboarding` block is **interactive-only** (02 §8.6 step 42) | **X** | A first-ever `claude` launched only by afleet therefore never completes onboarding, and `hasCompletedOnboarding` stays false in `~/.claude.json`. The GUI should either (a) write the flag itself, or (b) run `claude` once in a terminal on first install. Otherwise every future *interactive* launch re-prompts. |
| Theme choice (`Theme` / `Choose the text style that looks best with your terminal`) | Onboarding step | Not applicable | T | GUI owns theming. |
| Login step inside onboarding | Onboarding step | Replaced by `claude_authenticate` (§9) | R | — |
| Terminal setup (`/terminal-setup`, iTerm2/Terminal.app defaults import, the interrupted-setup restore messages) | 02 §8.8 step 8 | `/terminal-setup` absent from the headless list; the restore messages only print interactively | **T** | Superseded by the GUI. Note the two restore strings exist in case a user's iTerm2 was left half-configured by a prior terminal session. |
| Workspace **trust dialog** (`Accessing workspace:` + cwd + `Quick safety check: Is this a project you created or one you trust? …` + `Claude Code'll be able to read, edit, and execute files here.` + `Yes, I trust this folder` / `No, continue without these permissions` / `No, exit` + a `Security guide` link) | 02 §8.9; also shown when `Sae()` reports **new untrusted configuration sources** | **Skipped in `-p`.** Verbatim from the `--print` help: `Note: The workspace trust dialog is skipped when Claude is run in non-interactive mode (via -p, or when stdout is not a TTY, e.g. piped or redirected output). Only use this in directories you trust. Settings files that fail validation are silently ignored in this mode (no error dialog is shown).` | **X — security gap, flag it** | This is the most important security row in this area. Every afleet session runs with `-p`, so opening any folder silently grants read/edit/execute and silently activates that folder's `.claude/settings.json`, hooks, agents and `.mcp.json`. **afleet must own a trust decision of its own**: prompt on first open of a directory, persist it, and refuse to launch (or launch with `--restricted` / `--setting-sources user`) until the user consents. The CLI's own `hasTrustDialogAccepted` state is on disk (03), so a GUI can read and honour it, but the CLI will not ask. |
| New-untrusted-sources re-prompt | Same dialog, triggered by `Sae()` | Also skipped | **X** | Same mitigation: afleet should diff the project's settings/hooks/MCP sources between launches and re-ask. |
| Invalid-settings dialog (interactive) with a "fix" option that prepends a generated settings-fix prompt | 02 §8.6 step 44 | In `-p`, settings files that fail validation are **silently ignored** | **D** | The GUI gets no signal. Workaround: shell out `claude doctor` (which reads settings without a trust prompt) or validate the JSON itself before launch. |
| Data-sharing (`grove_enabled`) consent dialog | 02 §8.9 step L; escape → exit 0 | In `--print`: written to **stderr**, and past the deadline **exit 1** with `[ACTION REQUIRED] An update to our Consumer Terms and Privacy Policy has taken effect on October 8, 2025. You must run \`claude\` to review the updated terms.` — 08 §11.3 | **D / X** | A GUI that ignores stderr will see an unexplained exit 1. Watch for the `[ACTION REQUIRED]` marker and tell the user to run `claude` in a terminal. Also note the dialog is *always* skipped on the first run for an account (no `groveConfigCache` entry). |
| Pro-trial start screen, powerup-discovery step, custom-API-key approval, Bedrock upgrade dialog, bypass-permissions consent dialog, dev-channels dialog, Chrome onboarding | 02 §8.9 steps N/P/R/S/U/W/X | All interactive-only | **X** | The bypass-permissions consent one matters: `--dangerously-skip-permissions` in a fresh install normally requires an accepted dialog. Headless, the `skipDangerousModePermissionPrompt` flag governs. |
| First-run tips / release notes | `setup_release_notes_ms` in `setup()` (02 §8.8 step 19); content owned by 49 | Not emitted headless | T / R | If afleet wants a "what's new", read the release-notes payload from disk or ship its own. |
| "New version available" banner | `New version available: <v> (current: 2.1.257)`; also `Auto-updating…`, `Update installed · Restart to apply`, `Auto-update failed: no write permission to npm prefix · Run …` — the footer restart notice after a background auto-update | Not on the wire | **D** | Rebuild: `get_binary_version` control request gives the running version (live capture includes it); the GUI polls the release channel itself, or shells out `claude update`. Opportunity to exceed the TUI: a GUI can offer a one-click restart-into-new-version. |

## 14. `claude` subcommands a GUI can shell out to (SPEC 02 §5)

Registration order from `Ws()` (02 §5.1). One line of purpose each; "gated" notes the guard.

| Subcommand | Purpose (verbatim description unless noted) | GUI use |
|---|---|---|
| `claude auth login` | `Sign in to your Anthropic account` (`--email`, `--sso`, `--console`, `--claudeai`) | Fallback when `claude_authenticate` cannot serve (SSO, Console keyless, gateway) |
| `claude auth status` | `Show authentication status` (`--json` default, `--text`); exit 0 signed in, 1 not | Pre-launch signed-in check |
| `claude auth logout` | `Log out from your Anthropic account` | The only logout a GUI has |
| `claude setup-token` | `Set up a long-lived authentication token (requires Claude subscription)` | Rarely; prints the token once |
| `claude doctor` | `Check the health of your Claude Code installation. Reads settings files in the current directory without a trust prompt.` No flags, always exits 0 | Settings/health panel; exempt from the org version pin |
| `claude update` / `upgrade` | `Check for updates and install if available` | The update button |
| `claude install [target]` | `Install Claude Code native build. Use [target] to specify version (stable, latest, or specific version)`; `--force` | Version pinning |
| `claude mcp serve|add|remove|list|get|login|logout|add-json|add-from-claude-desktop|reset-project-choices|xaa …` | `Configure and manage MCP servers` | MCP management UI (chapter 31's area) |
| `claude plugin` (alias `plugins`) `init|validate|tag|list|eval|details|marketplace …|install|uninstall|prune|enable|disable|update` | plugin lifecycle | Plugin manager (chapter 30's area) |
| `claude agents` | `Manage background agents`; `--json` prints active sessions as JSON **without needing a TTY**, `--all` includes completed | The single best scriptable surface for a fleet view |
| `claude project purge [path]` | `Delete all Claude Code state for a project (transcripts, tasks, file history, config entry)`; `--dry-run`, `-y`, `-i`, `--all` | "Forget this project" |
| `claude ultrareview [target]` | `Run a cloud-hosted multi-agent code review of the current branch (or a PR number / base branch) and print the findings`; `--json`, `--timeout`, `--post` | Review panel |
| `claude auto-mode defaults|config|reset|critique` | `Inspect or reset auto mode classifier configuration` | Auto-mode settings |
| `claude import [codex|gemini]` | `Import config from another AI coding agent into Claude Code` — **gated** on `tengu_import` (default false); otherwise prints a refusal | Migration wizard, if the gate lands |
| `claude remote-control` / `rc` (hidden) | `Control local sessions from claude.ai/code or the Claude mobile app`; hand-rolled parser, refuses non-allowlisted root options | Chapter 36's area |
| `claude sandbox install|status` (hidden) | Windows sandbox install / posture as one JSON line | Windows only |
| `claude gateway --config <path>` (registered only in the non-print positional branch) | `Run the enterprise auth/telemetry gateway` | Not a GUI concern |
| `claude import-conversations <path>` (hidden) | gated on `CLAUDE_IMPORT_CONVERSATIONS` | — |
| `claude daemon run|status|logs|install|uninstall|start|stop|restart|hub|…` | Not a Commander command; entry-stub dispatched (02 §5.18, §2.10) | Chapter 38's area |
| `claude logs|attach|stop|kill|respawn|rm <id>`, `claude --bg` | Background-session verbs, advertised in `--help` via a `visibleCommands` override but dispatched from the entry stub (02 §2.11) | Background-session management |
| **There is no `claude config`** (02 §5.19) | — | Use `/config`, `update_settings`, or edit settings files |

Two flags exist that are **not** Commander options: `--exec <cmd>` (only under `--bg`) and `--routine`.

## 15. Exit paths, exit codes and signals (SPEC 02 §12–§13)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| Exit-code table | 02 §12.1: `0` success · `1` generic failure · `2` usage/config error · `70` `EX_SOFTWARE` (uncaught under `CLAUDE_CODE_SUPERVISED`; also the daemon's restart request) · `75` `EX_TEMPFAIL` (429) · `78` `EX_CONFIG` (permanent bridge error) · `129` SIGHUP/orphan · `130` SIGINT · `143` SIGTERM · `128+n` signal pass-through | Same for the headless process | P | afleet must distinguish these. `129` and `143` are recorded as a **deliberate external stop, not a crash** (02 §12.1) — mirror that in the GUI. |
| Headless signal handling | 02 §13.2: SIGINT aborts the in-flight turn with a `user-cancel` reason and `gracefulShutdown(0)`; SIGTERM commits the session, kills live shells, `gracefulShutdown(143)` | The host's stop button should send SIGINT for "stop this turn" and SIGTERM for "close the session" | P | SIGINT is the right stop; `interrupt` control request is the *softer* one that keeps the process. |
| `exit-cause` / `exit-detail` breadcrumbs | Written under `$CLAUDE_JOB_DIR` when set; consume-and-delete, refuse >65 536 bytes; observed causes `cli_error`, `exit_with_error`, `exit_with_message`, `setcwd`, `worktree_create`, `worktree_chdir:<code>`, `relaunch_spawn_error`, `session_in_use`, `uncaught:<Name>`, `unhandled:<Name>` — 02 §12.3 | **A GUI can opt in** by setting `CLAUDE_JOB_DIR` per session and reading the file after exit | **R → strictly better than the TUI** | This is the cleanest crash-attribution channel available and the TUI does not surface it at all. Recommended. |
| Resume hint on exit (`Resume this session with:` / `claude [--worktree <name> ]--resume <session-id>`) | Printed only when stdout is a TTY — 02 §12.4 | Not printed | T | The GUI owns resume. |
| Startup-mount watchdog (`Claude Code could not start: <msg>` after 10 000 ms) | 02 §12.6 | Suppressed for non-UI paths; a headless launch that never mounts a UI is not watched | D (minor) | The GUI should impose its own launch timeout. |
| Uncaught-exception circuit breaker (10 in 5 000 ms) | 02 §12.7 | Same; prints the loop report to fd 2 then exits 1 | P | Watch stderr. |
| `CLAUDE_CODE_SUPERVISED` | Uncaught exception / unhandled rejection exits **70** instead of being absorbed — 02 §10 | An env var afleet can set | R → recommended | Turns a silently-absorbed crash into a distinguishable exit code. Cheap reliability win. |
| Inspector guard | Importing the main chunk **exits 1 with no message** if a Node/Bun inspector is attached or requested via `NODE_OPTIONS` — 02 §2.16 | Same | P | If afleet ever sets `NODE_OPTIONS`, do not include `--inspect`. |
| Graceful-shutdown budget | Failsafe `max(5000, sessionEndHookTimeout + 5000)`; cleanup raced against 2 000 ms; stdout drain `min(30000, max(2000, ceil(bytes*1000/262144))) + 1500` ms — 02 §12.4 | Same | P | The GUI must wait at least this long before SIGKILL. |

## 16. `--continue`, `--resume`, `-n` and session identity (SPEC 02 §4.3, §8.6)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| `-c, --continue` | `Continue the most recent conversation in the current directory` | Same flag; no picker involved | P | "Most recent **in the current directory**" — the GUI must launch with the right cwd or it will continue the wrong conversation. |
| `-r, --resume [value]` | `Resume a conversation by session ID, or open interactive picker with optional search term` | With a value: resumes that id. **Without a value** the picker is interactive-only | P (with id) / X (picker) | afleet already passes `--resume <id>`. Rebuild the picker from the transcript store (chapter 35). |
| `--fork-session` | `When resuming, create a new session ID instead of reusing the original` | Same | P | Required if afleet wants `--session-id` together with `--resume` (see the refusal below). |
| `--session-id <uuid>` conflicts | `Error: --session-id can only be used with --continue or --resume if --fork-session is also specified.`; `Error: Invalid session ID. Must be a valid UUID.`; `Error: Session ID <id> is already in use.` (breadcrumb `session_in_use`) — 02 §8.6 step 19 | Same, fatal at startup | P | The `session_in_use` breadcrumb is how a GUI detects a double-launch. |
| `-n, --name <name>` | `Set a display name for this session (shown in the prompt box, /resume picker, and terminal title)` | Same flag; also settable mid-session with `rename_session` | P | All three display sites are TUI-only, so for a GUI `-n` is purely a persisted label it renders itself. |
| `--from-pr [value]` | `Resume a session linked to a PR by PR number/URL, or open interactive picker` | With a value: works; picker is interactive | P / X | — |
| `--resume-session-at <message id>` / `--resume-drops-turn <message id>` | Print-mode-only truncating resume (hidden) | Available exactly because afleet runs `--print` | P | The refusal semantics of `--resume-drops-turn` (refuse if the discarded range contains anything not attributable to that turn) are a good safety net for a GUI "rewind" feature. |
| `--rewind-files <user-message-id>` | `Restore files to state at the specified user message and exit (requires --resume)` | A separate one-shot invocation | P | Also available live as the `rewind_files` control request. |
| `--no-session-persistence` | `Disable session persistence` (print-only) | Available | P | For ephemeral GUI scratch sessions. |
| Model restore on resume | 06 §22; declines with `not a model this version of Claude Code recognizes` / `not allowed by this account's model settings` / `retired` | `informational` frame + `PostModelSwitch` with `source:"resume"` | P | The GUI must re-read `system/init.model` after a resume rather than assuming its own last-picked value. |

## 17. TTY detection and what non-TTY changes (SPEC 02 §8.3; SPEC 45 §45.31.2 owns)

| Feature | TUI behaviour (SPEC §) | Headless equivalent | Class | Notes |
|---|---|---|---|---|
| The non-interactivity predicate | `Cs(argv)` = `-p` **or** `--print` **or** `--init-only` **or** a `--sdk-url*` token **or** `!process.stdout.isTTY` — 02 §8.3 | afleet trips it three ways at once | P | Consequence: `Oe()` (non-interactive) is true everywhere downstream, selecting the terse variant of every auth error and the headless branch of every dialog. |
| Early input capture | Started only on a TTY outside print mode; Ctrl-C exits **130** — 02 §8.2, §2.15 | Never starts | T | — |
| Piped stdin | Buffered UTF-8, **10 MiB cap** (`Error: piped stdin input exceeds 10MB…`), 3-second silence warning, joined to the argv prompt with `\n` — 02 §8.6.2 | afleet uses `--input-format stream-json`, which takes the async-generator path instead | P | Note the *other* path's failure mode (`Error: cannot read --input-format=stream-json messages from stdin (<code>): stdin is unreadable.`) is fatal. |
| Everything else non-TTY changes | — | **SPEC 45 §45.31.2 owns this.** Noted here only so the inventory is complete. | — | Do not duplicate; cross-reference. |

## 18. `CLAUDE_CODE_ENTRYPOINT` and the first-party-only feature set (SPEC 45 §45.30)

The accepted value set is 25 strings (`qVt`, 45 §45.30). Below is every behaviour this area's
chapters gate on a *first-party* entrypoint — the gap class the brief asked to enumerate.
A third-party GUI that does **not** impersonate gets none of them.

| Gated behaviour | Gate | Chapter | Class | Consequence for afleet |
|---|---|---|---|---|
| **`initialize.unavailable_models`** — the disabled/why-unavailable model rows | `CLAUDE_CODE_ENTRYPOINT === "claude-vscode"` **and** first-party provider **and** first-party base URL (`Kun`, `var K9r = new Set(["claude-vscode"])`) | 06 §15.3 | **D** | The single biggest model-surface loss. Without it the picker can only show what is available, never what is greyed out and why. |
| SDK-driven credential refresh (`oauth_token_refresh`, `host_auth_token_refresh` control requests) | `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH` **and** entrypoint ∈ `{claude-desktop, local-agent, claude-vscode}` (`KJe`) | 08 §9.4, 45 §45.22.14 | X | Host cannot own the credential. Low impact — the CLI refreshes its own. |
| `apiKeyHelper` suppressed as an auth-token source; settings helpers ignored | `mr()` = `CLAUDE_CODE_REMOTE` **or** `Dc()` (entrypoint ∈ `{claude-desktop, claude-desktop-3p, local-agent}`) | 08 §1.4, §2.1 | — | A *difference*, not a loss: first-party desktop entrypoints get **less** here. |
| Host-managed provider credentials (`CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST`) | Env var, but the error copy assumes the desktop app (`…managed by the desktop app… restart the desktop app.`) | 08 §20 | — | afleet can set it, but the user-facing copy will name "the desktop app". |
| **The interactivity carve-out**: a `--print` process still reports an *interactive* UI | `n === "claude-vscode" || Dc()` in the surface classifier (45 §45.30.5) | 45 §45.30.5 | **X, and consequential** | This is the switch that makes dialogs, `ask` decisions and interactive-only refusals behave as if a human were present. A third-party host stays on the `print` branch, so every "this session cannot ask" refusal applies. Impersonating `claude-vscode` would flip a *lot* of behaviour at once and is not recommended without testing. |
| Non-interactive `ANTHROPIC_API_KEY` bypass **not** applied | `Snt()` = non-interactive **and** client type ≠ `claude-vscode` | 08 §2.2 | — | VS Code still gets the approval prompt; a third-party host does not. |
| Auto-updater excluded | entrypoints `claude-desktop`, `claude-desktop-3p`, `local-agent`, `claude-vscode`, `sdk-*` | 49 §— | — | afleet's `cli` entrypoint keeps the auto-updater on; set `DISABLE_AUTOUPDATER` if the GUI wants to own updates. |
| `experiment_gates` push to the extension (`tengu_vscode_*`, `tengu_vellum_siding`) | a connected MCP client literally named `claude-vscode` | 05 §—, 33 §33.19 | — | Not a user-visible loss. |
| Question preview format forced to `markdown` | forced for every client type **except** `sdk-*`, `claude-desktop`, `local-agent`, `remote` | 02 §8.3 step 4 | — | afleet on `cli` gets markdown, which is what a GUI wants anyway. |
| Session-persistence entrypoint set (`{claude-desktop, claude-desktop-3p, local-agent}`) | 35 §— | 35 | — | Cross-reference only. |
| Telemetry `client_type` bucket | entrypoint → `claude_code_cli` for afleet | 05 §— | — | No behaviour change. |

**Recommendation.** Impersonating `claude-vscode` would recover `unavailable_models`, but it
simultaneously flips the interactivity carve-out (dialogs, `ask` decisions, the API-key
approval prompt) and the auto-updater exclusion. Treat it as an all-or-nothing decision, not a
per-feature switch. The honest path is to accept the `unavailable_models` gap and file it as a
protocol request.

---

## Top gaps in this area

Ranked by how much they cost the product.

1. **The workspace trust dialog is skipped in `-p`** (02 §4.3, §8.9). Every afleet session
   silently grants read/edit/execute on the opened folder and silently activates that folder's
   settings, hooks, agents and `.mcp.json`; settings that fail validation are silently ignored.
   afleet must own its own trust decision, persist it, and re-ask when a project's configuration
   sources change. This is the only *security* gap in the area and it is unmitigated by default.
2. **No auto-continue when a usage limit resets** (08 §13.2). The TUI parks the turn and
   resumes automatically (`Wait here, then continue automatically when the limit resets`,
   `auto-continue in Ns · any key to stay`, preference `autoContinueAtUsageLimit` default true).
   A headless session just fails the turn. The GUI must rebuild the wait-and-resubmit machine
   from `rate_limit_event.resetsAt`; it can then beat the TUI by surviving app backgrounding.
3. **`unavailable_models` is entrypoint-gated to `claude-vscode`** (06 §15.3, `Kun`). A
   third-party GUI never learns which models are disabled or why. Needs a protocol change or an
   impersonation decision with wide side effects.
4. **`/login` and `/logout` are absent headless, but a full sign-in surface exists unpublished.**
   `claude_authenticate` → `{manualUrl, automaticUrl}`, `claude_oauth_callback
   {authorizationCode, state}`, `claude_oauth_wait_for_completion` → `{account}`. This is the
   single highest-leverage thing to build: without it afleet cannot sign a user in at all;
   with it, sign-in is a first-class GUI flow with `skipBrowserOpen` handing the GUI the URL.
   Logout still has no control request — shell out to `claude auth logout`.
5. **Fast mode is off by default with `sdk_opt_in_required`, and it is opt-in-able.** The live
   value on this machine. `--settings '{"fastMode":true}'` at launch, or
   `apply_flag_settings {fastMode:true}`, clears the gate (`flagSettings.fastMode === true`
   short-circuits `dU`). Without one of those a user-visible TUI feature is simply missing.
6. **`--enable-auth-status` is not in afleet's launch line.** The `auth_status` frame
   (`{isAuthenticating, output[], error?}`) is real on this build and is the only channel
   carrying `apiKeyHelper` / AWS / GCP credential-refresh output. Add the flag.
7. **`refusal_fallback_prompt` requires `supportedDialogKinds` on `initialize`.** Absence fails
   closed to the classic refusal error, silently. One line in the handshake buys back a
   user-facing choice.
8. **The consumer-terms (`grove`) notice exits 1 through stderr in `--print`.** Past the
   deadline the process writes `[ACTION REQUIRED] …` to stderr and exits 1 with no protocol
   frame. A GUI that ignores stderr shows an unexplained crash.
9. **Onboarding never completes headless**, so `hasCompletedOnboarding` stays false and any
   later interactive launch re-prompts. afleet should write the flag or run `claude` once.
10. **Effort cost multipliers and the `max` warning are not on the wire** (06 §17.7). The slider
    loses its "~1.6× the cost of high" annotation unless the GUI hard-codes `effort_cost_index`.
11. **`/advisor` has no `local` twin** — the advisor can only be configured at launch
    (`--advisor <model>`) or through `settings.advisorModel`. Design the GUI around that.
12. **The launch-effort pin cannot be released through the protocol** (06 §17.5): the refusal
    literally says "Run /effort <level> in an interactive terminal". Workaround: write the three
    `unpin*LaunchEffort` booleans, or pass `--effort` at launch.
13. **`max` effort cannot be set mid-session** — `apply_flag_settings` accepts only
    low/medium/high/xhigh. `max` is launch-only.
14. **No "new version available" signal on the wire.** Rebuild from `get_binary_version` plus
    the GUI's own release check; the TUI's `Update installed · Restart to apply` footer notice
    has no protocol equivalent.
15. **`CLAUDE_JOB_DIR` exit breadcrumbs are unused and free.** Setting it per session gives the
    GUI a crash-attribution channel (`exit-cause` / `exit-detail`) the TUI never surfaces —
    a place where a GUI can straightforwardly exceed the terminal.

## Unverified

- **`fast_mode_state` transitions on this build were not observed live** — the capture was a
  zero-turn handshake, so `"cooldown"` and `"on"` are taken from the schema (45 §45.10.4) and
  SPEC 06 §18.3, not from a running session. The claim that `apply_flag_settings {fastMode:true}`
  clears `sdk_opt_in_required` is read from `dU`'s source (06 §18.1: `n = flagSettings.fastMode
  === true`; `if (non-interactive && gate && !n) -> "sdk_opt_in_required"`) and from the
  `/fast` remote-application path [`chunk-6anae7z9.js:287350`]; **it was not executed.**
- **`--settings` populating `flagSettings`** is inferred from SPEC 06 §12's `ultracode`
  description ("typically provided via `--settings` or the `apply_flag_settings` control
  request") and from the `flagSettings` settings-source name (02, 03). I did not trace the
  `--settings` loader to confirm it writes the `flagSettings` tier specifically.
- **`claude_authenticate`'s exact response field names** are read from the handler at
  `chunk-2rhzyjym.js:177977` (`Xe(d, { manualUrl: nt, automaticUrl: ft })`) and
  `chunk-2rhzyjym.js:178016` (`Xe(d, { account: {...} })`). There is no published Zod schema
  for these three subtypes, so field *optionality* is unverified. The request field names
  (`loginWithClaudeAi`, `authorizationCode`, `state`) are read directly from the destructuring.
- **Whether `initialize.account.tokenSource` is ever populated on an OAuth session** — it was
  absent from the live capture. `getAccountInformation` (08 §12.4) says `tokenSource` is set
  "when the token comes from `CLAUDE_CODE_OAUTH_TOKEN` / its fd, or any non-profile source",
  which reads as *not* set for a plain stored claude.ai login. Inferred, not confirmed.
- **`/usage-credits` behaviour headless.** It appears in the live `slash_commands` list, so a
  `local` twin exists and is enabled, but I did not invoke it. Whether the non-interactive form
  can actually toggle credits or only reports status is unverified.
- **`get_usage.behaviors[].pct` semantics.** I read it as a population percentile
  (`subagent_heavy` pct 97 with count 5, `long_context` pct 75 with count 11 363 — pct clearly
  does not track count), but no schema or literal in the bundle names it. The `key` vocabulary
  beyond these two values is unknown.
- **`get_usage.rate_limits` live shape is richer than SPEC 08 §13.1.** The spec documents the
  older `/api/oauth/usage` `utilization` schema (`five_hour`, `seven_day`, `extra_usage`,
  `limits[]`); the live 2.1.259 response adds `severity`, `is_active`, `spend`, `model_scoped`,
  `member_dashboard_available` and eight further named windows. SPEC 08's own open questions
  flag that the endpoint contract needs a live capture — this capture is that, but it is one
  account on one plan and the field set may vary by tier.
- **`footer_indicator` was absent from the live capture**, so the recovered `{text}` shape is
  from the builder (`Mxt`/`oYt`/`ry`) rather than from an observed value. The exact meaning of
  the `ty = 6` floor (minimum length vs. ellipsis reserve) was not traced into `it()`.
- **`/low-priority` gate state.** It is absent from the live command list; I attribute that to
  `tengu_toasty_breeze.enabled` being false on this account rather than to a headless
  restriction, but I did not read the GrowthBook payload to confirm.
- **`"Thought for N seconds"`** — the only occurrence in the bundle is a release-note string
  describing the VS Code Focus view. I searched for a TUI producer and found none; the TUI
  glyph is `✻ Thinking…`. I did not read chapter 41 in full, which the brief assigns to another
  agent, so a TUI thinking-duration render may exist there under different wording.
- **The `-p` trust-skip's exact scope.** The claim that project `.claude/settings.json`, hooks
  and `.mcp.json` are activated without a prompt follows from the `--print` help text plus SPEC
  08 §10.1's trust gate; I did not trace `Jo()`/`vue()` (03's territory) to confirm which
  specific sources remain gated by the on-disk `hasTrustDialogAccepted` value in a `-p` launch.
