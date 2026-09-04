"""The resume half of the catalogue's relocation row: --resume after set_cwd, one more turn (item 64).

`unmirrored_prefix: 1`. Resuming a session appends exactly one record at the head of the
range before the mirror carries anything, and that record is never mirrored. Which record it
is depends on the resume: a session's first resume appends an `ai-title` duplicating the
title it already had, a later resume appends an `atis-latch`. The count is what holds, which
is why it and not the record type is what gets declared. This is the one place found so far
where the CLI writes a transcript record it does not mirror, so it is declared here rather
than tolerated in general: `verify` requires the count to be exact in both directions, so a
second unmirrored record still fails the gate and a declaration nothing needs is reported.
"""
from session_mirror_relocation import mirror_matches_file

META = {"name": "session-mirror-resume",
        "purpose": "resume the relocated session and add one turn; mirror and file still agree",
        "serves": ["item 64", "C3.G3"], "spikes": ["S14"], "census": True, "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 2}, "unmirrored_prefix": 1,
        "prompts": ["Reply with exactly: m5"], "resume_of": "session-mirror-relocation", "setup": None}


def run(session, ctx):
    session.send_user(META["prompts"][0])
    session.wait_result(timeout=120)
    ctx["notes"] += mirror_matches_file(session, ctx["config_home"])
