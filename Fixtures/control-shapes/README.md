# control-shapes

One short turn, then eleven host-originated control requests in sequence. Serves
acceptance items 11 and 13 and C4.G4; the recording spike S8 rests on. This is the
fixture that pins the parent's §6.4 request and response shapes for the command router.

The observed answers, in the order the scenario sends them:

| Request | Answer |
|---|---|
| `apply_flag_settings {settings: {effortLevel}}` | `success` with **no `response` key at all** — not an empty object and not `null` |
| `get_settings` | `success` `{applied: {model, effort, advisor, ultracode}, effective_keys, sources_keys: [{source, keys}]}`; the readback of the flag just applied is `effective_keys: ["effortLevel"]` with `source: "flagSettings"` |
| `list_models` | `success` `{models: [{value, resolvedModel, displayName, description, supportsEffort, supportedEffortLevels, supportsAdaptiveThinking, supportsFastMode, supportsAutoMode}]}` |
| `get_workspace_diff` | `success` `{diff: null}` in a directory that is not a repository |
| `rewind_files {user_message_id, dry_run: true}` | `success` `{canRewind, filesChanged, insertions, deletions}` |
| `set_cwd {path}` into an untrusted sibling | `success` `{status: "needs_trust", directory}` |
| `set_cwd {path}` back to the session's own cwd | `success` `{status: "ok", cwd, changed: false, transcript_relocated: true}` |
| `rewind_conversation {target_message_uuid}` | `success` `{rewound, targetMessageUuid, prefillText, precedingAssistantUuid}`; `prefillText` is the prompt to put back in the composer |
| `claude_authenticate` | `success` `{manualUrl, automaticUrl}`, both `https://claude.com/cai/oauth/authorize?…` with the query redacted by rule 6 |
| `claude_oauth_callback {code: <invalid>}` | `error` `"Request failed with status code 400"` |
| `claude_oauth_wait_for_completion` | `error` `"No active claude_authenticate flow"` |
| `generate_session_title {description, persist: false}` | `success` `{title}` |

Three of these are worth reading twice.

**The error envelope is confirmed on the wire.** `{subtype: "error", request_id, error:
<a bare string>}` — no `response` key, and `error` is a string rather than an object.
That matches the bundle reading recorded on this document's parent and is now observed
rather than read.

**`withdrawn_requests` is empty.** The scenario was written expecting
`claude_oauth_wait_for_completion` to hang, because a host cancel is a no-op for every
subtype outside the CLI's three-entry abort map, and to withdraw it after ten seconds.
It did not hang: with no flow in progress it answers an error immediately. No
`control_cancel_request` was sent and nothing is declared. The escape stays in the
contract for the case that does hang; this recording is not it.

**`set_cwd` back to the current directory still relocates.** `changed: false` and
`transcript_relocated: true` in the same answer. A host cannot read
`transcript_relocated` as "the transcript moved"; it means the relocation step ran.

`claude_authenticate` was safe to send: it returns URLs and starts no flow that the
scratch config home's existing login is disturbed by — every later request in the
sequence answered normally, and `claude_oauth_wait_for_completion` reports no active
flow.

Recorded on 2.1.259 under the scratch config home, model `haiku`, `--max-turns 2`; exit
0. `initial/` and `artifacts/` are empty.
