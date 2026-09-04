# send-user-file

The in-process MCP round trip: the model calls `mcp__afleet__send_user_file` with two files,
a caption and `status: "normal"`, and the harness's `afleet` server answers. Recorded
against `claude` 2.1.260 under the scratch config home of §4.6. Serves acceptance item 29
and C2.G3, and it is S5's evidence.

## What the recording shows

The whole server lifecycle, all of it under `--strict-mcp-config`:

1. Out of the §6.2 handshake and before any turn, three `control_request/mcp_message`
   frames carry `initialize` (client protocol `2025-11-25`), `notifications/initialized`
   and `tools/list`. The host answers each with `mcp_response`; `tools/list` returns the
   `send_user_file` schema.
2. In the turn, `system/init.tools` contains `mcp__afleet__send_user_file` and
   `system/init.mcp_servers` reports `[{"name": "afleet", "status": "connected"}]`.
3. `tools/call` arrives with exactly

   ```json
   {"files": ["a.txt", "b.txt"], "caption": "two files", "status": "normal"}
   ```

   and a `_meta` the host did not ask for, carrying `claudecode/toolUseId` and a
   `progressToken`. The host answers `{"content": [{"type": "text", "text": "sent 2 file(s)
   to the user: a.txt, b.txt (caption: two files)"}]}`.
4. The model then replies `done`, and `result` is `success` with `is_error: false`.

**The tool is deferred, not directly callable.** Although `system/init.tools` lists it, the
model's first action is `ToolSearch {"query": "select:mcp__afleet__send_user_file"}`, and
the transcript carries a `deferred_tools_delta` attachment naming it among the deferred set
and a `deferred_tools_record` afterwards. A host that assumes a registered SDK MCP tool is
immediately invocable will mis-model the first turn: the tool call is preceded by a schema
fetch, and the `tool_result` for that fetch is a `tool_reference` block rather than text.

The fallback launch was **not** used — `fixture.json`'s notes would say so as their first
line. `--strict-mcp-config` stays on the launch line for every scenario.

## Reading it

`initial/` and `artifacts/` are empty and hold only their `.gitkeep`; the scenario resumes
nothing and no frame names an artifact. The transcript holds 33 records and every one of
them is reproduced by the fixture's `transcript_mirror` frames.

The `environment` attachment records the working directory as
`/private/tmp/afleet-fixtures/send-user-file` — the resolved form of the scratch cwd, which
is the path the CLI works in and the one its project slug is derived from. Nothing in the
fixture comes from a real project. The `session_context` attachment's `userEmail` and one
`system-reminder` render are redacted to `<email>`; the redaction touched only the address
and left both records otherwise whole.

Recorded against the **pinned** 2.1.259 binary at
`~/.local/share/claude/versions/2.1.259`, which is the protocol baseline the parent declares
and the version C2 pins `ProtocolBaseline.version` to. The installed `claude` is 2.1.260;
the corpus stays at 2.1.259 deliberately, so that C1's evidence agrees with the declared
baseline and so that `make probe` against the installed binary is a real drift measurement
rather than a binary compared with itself. `launch.argv[0]` records the pinned path.
