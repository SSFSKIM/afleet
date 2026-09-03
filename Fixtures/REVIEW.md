# Fixture review checklist (G4)

A fixture enters the repository only after one person other than the recording
run has walked this list and signed the `review` block in `fixture.json`.
`Tools/probe/probe.py verify` refuses an unsigned fixture.

1. `fixture.json`: `name` matches the directory; `launch.env` lists only the six
   variables of the parent's §6.1 table (no PATH, HOME or anything else);
   `purpose`, `serves`, `prompts` are truthful; `synthetic`/`hypothesis` are set
   only for the two dialog fixtures.
2. `grep -R` the whole fixture for your name, your e-mail, your hostname and
   `/Users/`: only `~`, `<email>`, `<host>` and the scratch cwd may appear.
3. Open every `tool_result` block in `frames.ndjson` and every `attachment`
   record under `transcript/`: the content must come from the scratch repository
   under `/tmp/afleet-fixtures/<name>/`, never from a real project.
4. `redaction.json` lists every rule (identity, secrets, paths_host, mcp_bodies,
   settings_bodies, oauth_flow), even with a zero count.
5. `initial/`, `streams.json` and `transcript/` are consistent: `verify` checks
   that the final file extends the initial one from the recorded offset.
6. `artifacts/` holds every file a frame or record names by the `<artifacts>`
   token, and nothing else.
7. Every file under the fixture decodes as UTF-8. `verify` fails on one that does
   not, because a file the redaction rules cannot read is a file neither they nor
   you can inspect — so a stray `.DS_Store` dropped in by the Finder fails the
   gate, and deleting it is the fix.
8. `README.md` (optional) says what the recording shows and which acceptance
   items and spikes it serves.

Sign with `Tools/probe/probe.py sign Fixtures/<name> --reviewer "<your name>"`,
which writes `{"reviewer", "date", "checklist_version": 1}`, then run
`make verify-fixtures` and commit the fixture in its own commit.
