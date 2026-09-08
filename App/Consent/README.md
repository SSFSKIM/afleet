# App/Consent — C6.3, consent sheets and the trust banner

Owned by **C6.3** of the C6 composite spec,
`docs/doperpowers/specs/2026-09-07-c6-conversation-surface.md` (leaf table, "Four leaves, not
three"): the §6.12 consent sheets over X5's `consentNeeded`, and the `untrusted` trust banner with
its *Review trust in terminal* action. No other leaf edits anything in this directory.

Three answers on the sheet, and only one of them writes: *Accept* remembers the acceptance in
afleet's own store (across sessions, until the entry's configuration changes — which the sheet
says); *Decline* is the one Claude Code-owned file this app writes; *Not now* dismisses and records
nothing, leaving the channel unspawned with the banner that brings the sheet back. Closing the sheet
is *Not now* and never a decline.
