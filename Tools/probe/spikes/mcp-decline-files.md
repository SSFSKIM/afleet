# Finding: what the terminal writes when a project `.mcp.json` server is declined

Requested by C4 against the parent's §6.12. Scenario:
`Tools/probe/scenarios/spike_mcp_decline_files.py`, run with
`make spike SCENARIO=spike-mcp-decline-files CLAUDE=~/.local/share/claude/versions/2.1.259`.
Recorded 2026-09-05 on 2.1.259 under the scratch config home
`/tmp/afleet-fixtures/config-home`. Cost 0.0000 USD: no prompt is sent by the headless
session the spike opens, and none is typed into the terminal.

## What was done

A pristine project directory per run under
`/tmp/afleet-fixtures/spike-mcp-decline-files/project-<uuid>/`, holding a `README.md` and a
`.mcp.json` declaring one stdio server whose `command` is `/usr/bin/true`. The project is
not a version-controlled tree, so §6.12's store resolution puts the local-settings store at
the project directory itself. The interactive `claude` is driven on a pseudo-terminal with
the scratch config home in `CLAUDE_CONFIG_DIR` and every `CLAUDE*` marker of the driving
agent's own session dropped from the child environment.

The project directory and the whole config home are digested (relative path, size,
SHA-256) at four moments: before the terminal starts, after the workspace-trust dialog is
answered, after the MCP dialog is declined, and after the terminal exits. Attributing each
write to the dialog that made it is the reason for the two intermediate marks; a single
before/after diff mixes the trust write into the answer. The two JSON documents §6.12 names
are additionally compared as key-path shapes — key names and value *types*, never values —
which is what this finding quotes.

## Both dialogs arrive with the safe option preselected

The workspace-trust dialog opens on `❯ No, exit`, with `Yes, I trust this folder` below it;
a driver that sends a bare `Enter` first closes the terminal. The MCP dialog opens on
`❯ Continue without using this MCP server`, the third of

```
Use this MCP server
Use this and all future MCP servers in this project
Continue without using this MCP server
```

so **declining is a bare `Enter`** and the arrow keys a driver would otherwise send are what
could wrap the selection onto *Use this MCP server*. The scenario therefore reads the
highlight off the captured screen before it decides which keys to send, and sends nothing at
all when the decline option is not the highlighted one.

The dialog's body is `New MCP server found in this project: <name>` followed by
`MCP servers may execute code or access system resources. All tool calls require approval.
Learn more in the MCP documentation.`

## The answer C4 asked for

**Declining writes exactly one file, and it is the one §6.12 names.**

Between the trust answer and the decline, the project directory gained a single file:

```
<project>/.claude/settings.local.json
```

created by this write, with a single key:

```
disabledMcpjsonServers: list[str] len=1        # the declined server's name, verbatim
```

Nothing else in the project changed. `.mcp.json` is untouched.

**The config home's project entry does not carry the rejection.** The entry
`projects[<realpath of the project>]` in `<configHome>/.claude.json` is created by the
*trust* dialog, not the MCP one, and it is created already holding the consent arrays empty:

```
allowedTools: list[] len=0
disabledMcpjsonServers: list[] len=0
enabledMcpjsonServers: list[] len=0
mcpContextUris: list[] len=0
hasClaudeMdExternalIncludesApproved: bool
hasClaudeMdExternalIncludesWarningShown: bool
hasTrustDialogAccepted: bool
```

Across the decline, that entry gained only `lastGracefulShutdown: bool` and
`lastVersionBase: str`, and at exit the per-session counters (`lastSessionId`,
`lastStartTime`, `lastCost`, `lastDuration`, the `lastTotal*` token counts, the `lastFps*`
figures, `lastLinesAdded`, `lastLinesRemoved`, `lastAPIDuration`,
`lastAPIDurationWithoutRetries`, `lastToolDuration`, `lastTotalWebSearchRequests`). Its
`disabledMcpjsonServers` and `enabledMcpjsonServers` are still empty lists at the end of the
run, and `enableAllProjectMcpServers` never appears.

So a consumer computing consent state reads the **rejection** from the local-settings store
and only from there. The project entry's identically-named arrays exist, are read by the
CLI for other purposes, and were empty throughout a run in which a server was declined; a
host that treats them as the rejection record sees no rejection.

## The rest of the diff, so a reader is not surprised by it

Everything else that moved is the terminal being a terminal, not the decline:

- `<configHome>/.claude.json` outside `projects{}` gained cached experiment and GrowthBook
  feature blocks on startup (`cachedExperimentData.*`, `cachedGrowthBookFeatures.*`,
  `cachedExperimentFeatures` growing by one), a `fullscreenBootPending.<pid>` record and a
  `replBridgePlaceholders.<id>` record while the process ran — both removed at exit — and
  `tipsHistory` / `tipLifetimeShownCounts` counters at exit.
- `<configHome>/sessions/<pid>.json` and `<configHome>/sessions/<pid>.<hash>.key` appear
  while the terminal holds the session and are removed when it leaves.
- `<configHome>/history.jsonl` and `<configHome>/.last-update-result.json` change at exit.
- The terminal's own banner offers remote control (`/rc connecting…`) unasked; that is the
  interactive CLI's default and it happens whether or not any dialog is answered.

## What this does and does not settle for §6.12

Settled: the file and the key §6.12 says the terminal's dialog writes are the file and the
key it writes, for a project whose store resolves to the project directory. afleet's
*Decline* writing `disabledMcpjsonServers` into `<root>/.claude/settings.local.json` matches
the terminal byte-for-key.

Not settled here: the store resolution when the project sits inside a version-controlled
tree whose root is above the session cwd (§6.12's canonical-root rule) — this project was a
plain directory, so both candidate paths coincide; the multi-server dialog variant
(`<N> new MCP servers found in this project` with *Enable selected*); the *Use this and all
future MCP servers in this project* leg, which §6.12 expects to write
`enableAllProjectMcpServers`; and whether the write preserves unrecognised keys in an
existing `settings.local.json`, since this run created the file rather than merging into
one.
