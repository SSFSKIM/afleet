# Fixture review checklist (G4)

A fixture enters the repository only after one person other than the recording
run has walked this list and signed the `review` block in `fixture.json`.
`Tools/probe/probe.py verify` refuses an unsigned fixture.

**Checklist version 2.** `sign` stamps this number into the review block, so a
fixture signed at a lower version was reviewed against a shorter list than this
one. Adding or changing an item here means bumping `verify.CHECKLIST_VERSION`
and re-walking the fixtures whose signatures should still stand.

1. `fixture.json`: `name` matches the directory; `launch.env` lists only the six
   variables of the parent's §6.1 table (no PATH, HOME or anything else);
   `purpose`, `serves`, `prompts` are truthful. `synthetic` is set only for the
   two dialog fixtures; `hypothesis` is set only while a synthetic fixture's
   shapes are still unconfirmed on the baseline, and S6 has cleared it on both,
   so a fixture arriving with it set again should say in `notes` what is not
   confirmed.
2. `grep -R` the whole fixture for the **recording author's** name, e-mail and
   hostname, and for `/Users/`: only `~`, `<email>`, `<host>` and the scratch cwd
   may appear. The author is not you — item 1 of this list requires a reviewer
   other than the recording run — so take the identifiers from the recording
   machine rather than your own: `fixture.json`'s `recorded_at` and `launch` say
   which run it was, and `verify --hostname <recording host>` applies rule 3's
   hostname half off-machine, which it cannot infer.
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
   items and spikes it serves — **and describes this recording, not a previous
   one.** A re-recording carries the existing README across rather than losing
   it, which is why every claim in it has to be read against the fixture in
   front of you: the version, the session, the counts and the frame names all
   move when a fixture is re-recorded, and only this reading catches a
   paragraph that no longer applies.
9. Empty `initial/`, `transcript/` and `artifacts/` hold a `.gitkeep` and nothing
   else, and `git ls-files` on the fixture lists it. Git tracks no empty
   directory, and `verify` requires `initial/` and `transcript/` to exist, so a
   fixture missing the placeholder passes on the recording machine and fails on
   every clone.
10. **Synthetic fixtures only** (`synthetic: true`): hold every asserted frame
   against the bundle module the generator cites, field by field, and read
   `fixture.json`'s `hypothesis` as the claim it is. A synthetic fixture asserts
   a shape nobody observed on the wire, so this list's other items — which ask
   whether a recording was faithfully captured — cannot catch a frame that is
   simply wrong. Nothing but this reading can.

Sign with `Tools/probe/probe.py sign Fixtures/<name> --reviewer "<your name>"`,
which writes `{"reviewer", "date", "checklist_version", "tree_sha256"}` and stamps
the version from `verify.CHECKLIST_VERSION` — no number is written by hand here, so
this line cannot fall behind the list above it. Then run `make verify-fixtures` and
commit the fixture in its own commit.

`tree_sha256` is a digest of the whole fixture — every relative path and the bytes
at it, with the review block itself excluded — and `verify` recomputes it. So a
signature covers the bytes you walked and nothing else: any later edit to any file
in the fixture, `make redact` and a hand-fixed frame alike, re-opens this list
rather than passing on the strength of a walk that happened before the edit. The
repair is to walk the list again and sign again, which costs nothing but reading.
`verify` also refuses a `checklist_version` that is not the current one, for the
same reason. Neither of these adds anything to the ten items above, which is why
the version does not move for them.
