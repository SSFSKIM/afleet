# afleet

A native macOS app that hosts the unmodified Claude Code engine over its headless
stream-json protocol and presents every session on the machine like Slack, with a
VS Code-like panel beside the conversation. Nothing about Claude Code is
re-implemented.

Root spec and roadmap: `docs/doperpowers/specs/2026-09-03-afleet-workspace-design.md`.
Design in §1 through §16, the roadmap in §17; every child spec cites `§17 C<n>` and
records its parent-pin. Protocol evidence: `Fixtures/` (golden recordings, verified by `make verify-fixtures` and drift-checked by `make probe`), `Tools/probe` and `Tools/fake-claude` (C1's suite), `docs/tui-parity/` and `probes/`; the
extracted bundle spec at `~/claude-code-bundle/2.1.257/SPEC/` is the authority on engine
behaviour.

Rules every agent working here holds (spec §7.8, §11, §12; contract X9):

- Never write under Claude Code's config home (`~/.claude` or `CLAUDE_CONFIG_DIR`).
  Every mutation goes through the CLI or the control channel. The single exception is
  a declined `.mcp.json` server written into the project's `.claude/settings.local.json`
  exactly as spec §6.12 describes.
- Never stop, kill or adopt a session running in the user's terminal.
- Do not impersonate a first-party entrypoint or user agent.
- The Agent SDK typings are all-rights-reserved: fetch on demand, never commit.
  cmux is GPL: read for architecture only, copy nothing.
- Fixtures are recorded only through opt-in capture, redacted before disk and reviewed
  before commit. Never send `submit_feedback` casually; it uploads real feedback.
- Never `end_session` a channel with running background tasks without warning; stream
  close kills its shells.
- Protocol facts come from C1's probes and fixtures, not from guessing; unknown one-way
  frames are opaque, unknown inbound requests are answered with an error at once.
