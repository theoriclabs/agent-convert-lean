# Remove generated Claude notification clutter

Recent Claude versions may omit `isMeta` on background-task notifications. Authenticate them with recorded `origin.kind = task-notification`, `promptSource = system`, and `turnOrigin = task_notification`. XML-looking text alone is insufficient: preserve user-authored examples, mixed prose, and unmatched or ambiguous records.

The converter archives recognized generated controls in provenance. For an already converted Codex session, use the checkout's repair helper against the original Claude source:

```sh
python3 scripts/repair-claude-task-notifications.py <codex-rollout> \
  --claude-source <original-claude-jsonl> \
  --output <new-clean-rollout.jsonl> --report <new-report.json>
```

The helper removes only matching generated user-message records and their display twins, retaining exact source controls in session metadata. It writes a new session ID and leaves tools, ordinary messages, reasoning, and original files intact. Do not silently discard the notifications' completion details or treat them as fresh user requests.

When repairing a session that has already been resumed, include the latest persisted Codex work. If its model turn is still active, avoid replacing that rollout or taking a snapshot that would strand an in-flight call. Prefer a new cleaned session after the turn finishes. Preserve the existing session as a fallback, install the new file without replacement, and validate its native history and displayed dialogue before handing it off.

Report the matched conversation, output/install path, material limitations, and exact resume command. Distinguish removed display clutter from retained execution history. Keep the handoff concise.
