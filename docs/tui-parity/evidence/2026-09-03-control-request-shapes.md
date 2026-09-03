# Live probe: control requests on 2.1.259 (2026-09-03) — resume replay, unpublished schemas, checkpoints

Probe 07 resumed the probe-B session with `--resume <id>` and sent a zero-cost `initialize`, then one
control request per line. Probe 08 started a fresh session in a scratch directory with
`CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=1` in the environment, ran one Write turn, and exercised
rewind/title/file-suggestion/settings requests.

## Resume does not replay history
`--resume <session-id>` + `initialize`, six seconds idle: **0 assistant/user frames** arrived. A GUI
must render prior history from the transcript JSONL; the wire only carries new turns.

## Request/response shapes observed (success unless noted)
| Subtype | Request sent | Response / error |
|---|---|---|
| `list_models` | `{}` | `models[]` rows: `value, resolvedModel, displayName, description, supportsEffort, supportedEffortLevels[], supportsAdaptiveThinking, supportsFastMode, supportsAutoMode` |
| `get_plan` | `{}` | `{exists:false}` |
| `get_workspace_diff` | `{}` | `{diff:{stats:{filesCount,linesAdded,linesRemoved}, perFileStats[], hunks[], skippedLarge[], restricted[], source:{kind:"working-tree"}}}` |
| `file_suggestions` | `{query:"pro"}` (first call) | `{suggestions:[]}` — empty on the first call while the index warms |
| `file_suggestions` | `{query:"src/pro"}` | `src/probe-b.py` plus paths under `~/.claude/skills/...` (the index includes global skill dirs) |
| `file_suggestions` | `{query:""}` | top-level entries of cwd |
| `read_file` | `{path, max_bytes:200}` | `{contents, absPath, truncated:true}` |
| `add_directory` | `{directory}` / `{path}` / `{directories:[…]}` | **error** `undefined is not an object (evaluating 't.includes')` — the handler reads `mount_path` and is a cloud-container request: it calls `stageFile({mount_path})` and requires `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` (cli.pretty.js 176961–176990). **There is no local headless equivalent of `/add-dir`**; only `--add-dir` at launch. |
| `apply_flag_settings` | `{settings:{effortLevel:"low"}}`, `{model:"sonnet"}`, `{fastMode:true}`, `{agent:"Explore"}`, `{outputStyle:"Concise"}`, `{viewMode:"fullscreen"}`, `{bogusKey:1}` | `null` success for **every** key including the bogus one — no validation feedback; the model change emitted a replayed user frame `<local-command-stdout>Set model to `claude-sonnet-5`</local-command-stdout>`; `get_settings.applied` later showed `{model, effort, advisor, ultracode}` |
| `set_color` | `{color:"blue"}` | **error** `Unsupported control request subtype: set_color` (in the schema registry, not in the dispatcher) |
| `set_max_thinking_tokens` | `{max_thinking_tokens:null, thinking_display:"summarized"}` | `null` |
| `rewind_conversation` | `{user_message_id}` | **error** `rewind_conversation: target_message_uuid must be a string` |
| `rewind_conversation` | `{target_message_uuid:<first user uuid>}` | `{rewound:true, targetMessageUuid, prefillText:"<the original prompt>", precedingAssistantUuid:null}`; also accepts `interrupt_if_running`; refuses with `error:"commands queued" | "prompt pending" | "turn running"` |
| `rewind_files` | `{user_message_id, dry_run:true}` (default env) | `{canRewind:false, error:"File rewinding is not enabled."}` |
| `rewind_files` | same, with `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=1` | `{canRewind:true, filesChanged:[…], insertions:0, deletions:1}`; `dry_run:false` → `{canRewind:true, skippedLinks:0}` and the file written by the turn was removed |
| `get_settings` | `{}` | `{effective, sources[], applied:{model,effort,advisor,ultracode}}` |
| `update_settings` | `{source:"userSettings", …}` | **error** `update_settings: unsupported source userSettings` |
| `update_settings` | `{source:"localSettings", settings:{permissions:{…}}}` | **error** `update_settings keys not allowed: permissions` — an allow-list of string-valued keys applies (see below) |
| `mcp_status` | `{}` | `mcpServers[]`: `name, status (connected|needs-auth|…), config, scope, serverInfo?, tools[{name, annotations}]` |
| `background_tasks` | `{}` | `{}` |
| `stop_task` | `{task_id:"nope"}` | `{}` (no error for an unknown id) |
| `generate_session_title` | `{}` | **error** `undefined is not an object (evaluating 'r.trim')` |
| `generate_session_title` | `{description:"…", persist:false}` | `{title:"probe-rewind.txt creation"}` (one model call; `persist:true` also saves it as the AI title) |
| `get_session_cost` | `{}` | `{text:"Total cost: … Usage: …"}` (preformatted text only) |
| `get_usage` | `{}` | `{session:{total_cost_usd,total_api_duration_ms,total_duration_ms,total_lines_added,total_lines_removed,model_usage}, subscription_type, rate_limits_available, rate_limits:{five_hour, seven_day, seven_day_oauth_apps, seven_day_opus, seven_day_sonnet, seven_day_cowork, …}, behaviors}` |
| `get_context_usage` | `{detail:true}` | `categories[{name,tokens,color,isDeferred?}], gridRows, totalTokens, maxTokens, rawMaxTokens, percentage, model, memoryFiles, mcpTools, agents, skills, slashCommands, autoCompactThreshold, autocompactSource, isAutoCompactEnabled, messageBreakdown, apiUsage` |
| `remote_control` | `{}` | `null` success (no fields required; effect not verified) |
| `channel_enable` | `{}` | **error** `server  is not connected` (needs a server name) |
| `mcp_authenticate` | `{serverName}` | `{authUrl, requiresUserAction:true, callbackExpected:true, redirectScheme:"localhost", state, …}` — the CLI opens a localhost callback listener; a GUI can drive MCP OAuth by opening `authUrl` |
| `mcp_oauth_callback_url` | `{serverName}` | **error** `Invalid callback URL: missing authorization code. Please paste the full redirect URL including the code parameter.` (needs `callbackUrl`) |
| `mcp_clear_auth` | `{serverName:"nope"}` | **error** `Server not found: nope` |
| `claude_authenticate` | `{}` | `{manualUrl, automaticUrl, …}` — the account login flow is drivable headless (open `automaticUrl`, the CLI listens on a localhost port; `manualUrl` + `claude_oauth_callback` for paste-the-code) |
| `poll_event` | `{}` | **error** `poll-event delivery is not enabled for this session` |
| `ultrareview_launch` | `{}` | `{status:"error", message:"No changes to review: …", reason:"empty_diff"}` — runs locally; also emitted replayed synthetic user frames `<command-name>/ultrareview</command-name>` and `<local-command-stderr>…` |
| `stage_file` | `{}` | **error** `CLAUDE_CODE_REMOTE_SESSION_ID unset` (cloud only) |
| `register_repo_root` | `{directory:<cwd>}` | **error** `… is the current working directory, which is already registered; pass the cloned repo's own directory instead` |
| `set_cwd` | `{path:<cwd>}` | `{status:"ok", cwd, changed:false, transcript_relocated:true}` |
| `message_rated` | `{messageUuid, sentiment, surface, cleared}` | `{}` |
| `submit_feedback` | `{description:"probe"}` | `{feedback_id}` — **this sent real feedback to Anthropic**; do not probe it casually |
| `nonexistent_subtype` | `{}` | **error** `Unsupported control request subtype: nonexistent_subtype` |

## update_settings allow-list
`A_` (cli.pretty.js 174360–174380): source must be `localSettings`; every value must be a string
(deletion unsupported); keys outside the set `T_ = new Set(["outputStyle"])` (cli.pretty.js 174361) are refused. **The only setting a host can write through the control protocol is `outputStyle`.** Everything else the TUI's /config panel writes must go through the headless `/config key=value` text command (its twin lists ~40 keys; see the slash-command evidence) or cannot be written at all (permission rules, additional directories, hooks, MCP servers at user/project scope).

## Permission prompts under the author's settings
The Write in probe 08 produced **no** `can_use_tool` because the user's settings allow `Write`
globally; probes that need the ask path must pass `--setting-sources ""` (see the design spec).

## Additional flags and requests (probe 10)
| Item | Observation |
|---|---|
| `--session-mirror` | Accepted by 2.1.259 although absent from `claude --help`. After a zero-cost `/goal` turn the session emitted `{type:"transcript_mirror", filePath:"~/.claude/projects/<slug>/<session>.jsonl", entries:[...]}` carrying the JSONL records the CLI just wrote (`queue-operation` enqueue/dequeue, the user record, the local-command output record …). The CLI can therefore push transcript records live; a GUI that renders from JSONL records can use one reducer for archived and live channels. |
| `--enable-auth-status` | Accepted; see the frame census below for whether an `auth_status` frame is emitted on this account. |
| `register_repo_root {directory}` | Refused unless the directory is a subdirectory of cwd or of a launch-time `--add-dir` root: `register_repo_root: /tmp/afleet-gap/ws2 is not a subdirectory of cwd or of a launch-time --add-dir root`. It is for registering cloned repos inside the workspace, **not** a runtime `/add-dir`. Together with `add_directory` being a container request, there is no runtime way to add a working directory to a local headless session. |
| `--enable-auth-status` | Accepted; one `auth_status` frame was emitted after `initialize` (probe 10). |
| `tool_progress` with `CLAUDE_CODE_CONTAINER_ID` set (probe 11) | A foreground Bash loop printing five lines over five seconds produced exactly one frame: `{"type":"tool_progress","tool_use_id":"bash-progress-0","tool_name":"Bash","parent_tool_use_id":"<the Bash tool_use id>","elapsed_time_seconds":3,"task_id":"…"}` — elapsed time only, **no output**. The container variable also auto-backgrounded the command (`task_started` + `task_notification` appeared for a foreground call). Live Bash output is not on the wire under any flag; the task output file is the only live source. |
