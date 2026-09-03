# Live probe: slash commands sent as text over stream-json (claude 2.1.259, 2026-09-03)

Flags: -p --input-format stream-json --output-format stream-json --include-partial-messages --replay-user-messages --forward-subagent-text --include-hook-events --permission-prompt-tool stdio --permission-prompts host --permission-mode default --model haiku --verbose
Each command was sent as a `user` frame (origin human). `echo` = a `user` frame with <command-name>/<command-message>/<command-args> was emitted (the transcript echo of a runnable local command). Refused commands produce ONLY an `assistant` frame whose text is `/<name> isn't available in this environment.` plus a `result` — no user echo. Every step also emitted system/init and 3 command_lifecycle frames (queued/started/completed).

| Command | Outcome | Echo | Result text (first 160 chars) |
|---|---|---|---|
| `/help` | REFUSED | no | /help isn't available in this environment. |
| `/context` | RAN | yes | ## Context Usage⏎⏎**Model:** claude-haiku-4-5-20251001  ⏎**Tokens:** 21.9k / 200k (11%)⏎⏎### Estimated usage by category⏎⏎| Category | Tokens | Percentage |⏎|-- |
| `/cost` | RAN | yes | You are currently using your subscription to power your Claude Code usage⏎⏎Current session: 57% used · resets Sep 3 at 10:39pm (Asia/Seoul)⏎Current week (all mo |
| `/usage` | RAN | yes | You are currently using your subscription to power your Claude Code usage⏎⏎Current session: 55% used · resets Sep 3 at 10:40pm (Asia/Seoul)⏎Current week (all mo |
| `/status` | REFUSED | no | /status isn't available in this environment. |
| `/model sonnet` | RAN | yes | Set model to `Sonnet 5` for this session only |
| `/model` | RAN | yes | Current model: `Sonnet 5` (effort: high)⏎Usage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default,  |
| `/tasks` | REFUSED | no | /tasks isn't available in this environment. |
| `/permissions` | REFUSED | no | /permissions isn't available in this environment. |
| `/config` | RAN | yes | Usage: /config key=value [key=value ...]⏎  agentPushNotifEnabled=true|false⏎  autoCompact=true|false⏎  autoConnectIde=true|false⏎  autoScroll=true|false⏎  check |
| `/vim` | REFUSED | no | /vim isn't available in this environment. |
| `/rewind` | REFUSED | no | /rewind isn't available in this environment. |
| `/doctor` | RAN | yes | These were local commands you ran (context check, usage check, model switch to Sonnet, and viewing available config options) — no action needed from me here. Le |
| `/resume` | REFUSED | no | /resume isn't available in this environment. |
| `/memory` | REFUSED | no | /memory isn't available in this environment. |
| `/hooks` | REFUSED | no | /hooks isn't available in this environment. |
| `/mcp` | RAN | yes | 3 MCP server(s): 2 connected, 1 not connected, 0 disabled. Use `/mcp` in the terminal for details. |
| `/agents` | RAN | yes | The /agents wizard has been removed.⏎⏎Ask Claude to create or update subagents for you (e.g. "create a code-reviewer subagent that ..."),⏎or edit the files dire |
| `/skills` | REFUSED | no | /skills isn't available in this environment. |
| `/plan` | REFUSED | no | /plan isn't available in this environment. |
| `/diff` | REFUSED | no | /diff isn't available in this environment. |
| `/btw what is 2+2` | REFUSED | no | /btw isn't available in this environment. |
| `/export` | REFUSED | no | /export isn't available in this environment. |
| `/rename probe-title` | RAN | yes | Session renamed to: probe-title |
| `/effort low` | RAN | yes | Set effort level to low (this session only): Quick, straightforward implementation with minimal overhead |
| `/fast` | RAN | yes | Fast mode unavailable: Fast mode is not available in the Agent SDK |
| `/theme` | REFUSED | no | /theme isn't available in this environment. |
| `/terminal-setup` | REFUSED | no | /terminal-setup isn't available in this environment. |
| `/keybindings` | REFUSED | no | /keybindings isn't available in this environment. |
| `/release-notes` | REFUSED | no | /release-notes isn't available in this environment. |
| `/copy` | REFUSED | no | /copy isn't available in this environment. |
| `/stats` | RAN | yes | You are currently using your subscription to power your Claude Code usage⏎⏎Current session: 56% used · resets Sep 3 at 10:40pm (Asia/Seoul)⏎Current week (all mo |
| `/bug` | REFUSED | no | /bug isn't available in this environment. |
| `/color red` | RAN | yes | Session color set to: red |
| `/add-dir /tmp` | REFUSED | no | /add-dir isn't available in this environment. |
| `/cd /tmp` | REFUSED | no | /cd isn't available in this environment. |
| `/branch` | REFUSED | no | /branch isn't available in this environment. |
| `/fork` | REFUSED | no | /fork isn't available in this environment. |
| `/background` | REFUSED | no | /background isn't available in this environment. |
| `/goal` | RAN | yes | No goal set. Usage: `/goal <condition>` |
| `/loops` | REFUSED | no | /loops isn't available in this environment. |
| `/tui` | REFUSED | no | /tui isn't available in this environment. |
| `/focus` | REFUSED | no | /focus isn't available in this environment. |
| `/brief` | REFUSED | no | /brief isn't available in this environment. |
| `/sandbox` | REFUSED | no | /sandbox isn't available in this environment. |
| `/ide` | REFUSED | no | /ide isn't available in this environment. |
| `/statusline` | REFUSED | no | /statusline isn't available in this environment. |

Notes:
- `/doctor` (in terminal_slash_commands) was NOT refused: it was echoed as a prompt-type command and the MODEL answered it (stream events + rate_limit_event) — on 2.1.259 /doctor is a bundled skill, terminalOriented, and headless it simply runs as a prompt.
- `/fast` ran and printed: `Fast mode unavailable: Fast mode is not available in the Agent SDK` (initialize.fast_mode_disabled_reason = sdk_opt_in_required).
- `/mcp` headless twin prints only a count line and says `Use /mcp in the terminal for details`.
- `/context` headless twin prints a markdown report AND the assistant frame carries `context_usage` {model,total_tokens,raw_max_tokens,percentage,categories,mcp_tools,memory_files,agents,skills}.
- `/config` with no args prints the full list of key=value settable keys (see below).
- `/model sonnet` changed the model for the session (later system/init showed model claude-sonnet-5).
- `/color red` ran (`Session color set to: red`) although /color is terminalOriented.
- `/help`, `/status`, `/tasks`, `/permissions`, `/vim`, `/rewind`, `/resume`, `/memory`, `/hooks`, `/skills`, `/plan`, `/diff`, `/btw`, `/export`, `/theme`, `/terminal-setup`, `/keybindings`, `/release-notes`, `/copy`, `/bug`, `/add-dir`, `/cd`, `/branch`, `/fork`, `/background`, `/loops`, `/tui`, `/focus`, `/brief`, `/sandbox`, `/ide`, `/statusline` → refused.

## /config key list printed headless (2.1.259)
```
Usage: /config key=value [key=value ...]
  agentPushNotifEnabled=true|false
  autoCompact=true|false
  autoConnectIde=true|false
  autoScroll=true|false
  checkpoints=true|false
  chrome=true|false
  
```

## /model output
```
Current model: `Sonnet 5` (effort: high)
Usage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID.
```

## /usage output (headless twin)
```
You are currently using your subscription to power your Claude Code usage

Current session: 55% used · resets Sep 3 at 10:40pm (Asia/Seoul)
Current week (all models): 73% used · resets Sep 7 at 12am (
```