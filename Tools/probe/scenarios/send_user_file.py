"""S5: the in-process MCP round trip through mcp__afleet__send_user_file (item 29, C2.G3)."""
import os

import harness

META = {"name": "send-user-file", "purpose": "in-process MCP round trip: two files, a caption, status normal",
        "serves": ["item 29", "C2.G3"], "spikes": ["S5"], "census": True, "optional_pairs": ["system/thinking_tokens"], "deterministic": False, "isolation": "config-home",
        "launch": {"max_turns": 4, "strict_mcp_config": True}, "fallback_launch": {"strict_mcp_config": False},
        "fallback_reason": "the SDK MCP server did not register under --strict-mcp-config",
        "prompts": ["Use the mcp__afleet__send_user_file tool to send the files a.txt and b.txt to me, "
                    "with the caption 'two files' and status 'normal'. Then reply with the single word: done"],
        "resume_of": None, "spill_after": 5000}


def setup(cwd):
    with open(os.path.join(cwd, "a.txt"), "w") as fh:
        fh.write("alpha\n")
    with open(os.path.join(cwd, "b.txt"), "w") as fh:
        fh.write("beta\n")


META["setup"] = setup


def run(session, ctx):
    # The registration check has to come after a turn has begun: `system/init` is emitted at
    # the start of every turn, not at the handshake (docs/tui-parity/README.md), so the tool
    # list does not exist until the prompt has been sent and answered.
    session.send_user(META["prompts"][0])
    res = session.wait_result(timeout=180)
    tools = (session.system_init or {}).get("tools") or []
    registered = "mcp__afleet__send_user_file" in tools
    ctx["notes"].append("sdk server registered under strict-mcp-config: %s" % registered)
    if not registered and ctx["launch"].strict_mcp_config:
        raise harness.RetryWithFallback("mcp__afleet__send_user_file absent from system/init.tools")
    ctx["notes"].append("tools/call arguments seen by the harness: %r" % session.mcp.calls)
    ctx["notes"].append("result: %s" % (res or {}).get("subtype"))
