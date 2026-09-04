"""The resume half of the catalogue's relocation row: --resume after set_cwd, one more turn (item 64)."""
from session_mirror_relocation import mirror_matches_file

META = {"name": "session-mirror-resume",
        "purpose": "resume the relocated session and add one turn; mirror and file still agree",
        "serves": ["item 64", "C3.G3"], "spikes": ["S14"], "census": True, "deterministic": False,
        "isolation": "config-home", "launch": {"max_turns": 2},
        "prompts": ["Reply with exactly: m5"], "resume_of": "session-mirror-relocation", "setup": None}


def run(session, ctx):
    session.send_user(META["prompts"][0])
    session.wait_result(timeout=120)
    ctx["notes"] += mirror_matches_file(session, ctx["config_home"])
