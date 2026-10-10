#!/usr/bin/env python3
"""Check control provenance, literal collisions, and native-history preservation."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("repair_notifications", root / "scripts/repair-claude-task-notifications.py")
repair_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair_module)
text = "<task-notification>\n<task-id>b1</task-id>\n<tool-use-id>tu1</tool-use-id>\n<output-file>/tmp/b1.output</output-file>\n<status>completed</status>\n<summary>Background command completed</summary>\n</task-notification>"
sid = str(uuid.uuid4())
parent = None
source_records = []
for index, (content, generated) in enumerate(((text, False), (text, True), ("Latest request", False)), 1):
    record = {"type": "user", "uuid": str(uuid.uuid4()), "parentUuid": parent,
              "sessionId": sid, "cwd": "/tmp", "isSidechain": False,
              "timestamp": f"2026-09-29T12:00:0{index}.000Z",
              "message": {"role": "user", "content": [{"type": "text", "text": content}]}}
    if generated:
        record.update({"origin": {"kind": "task-notification"}, "promptSource": "system", "turnOrigin": "task_notification"})
    parent = record["uuid"]
    source_records.append(record)

with tempfile.TemporaryDirectory(prefix="loom-task-controls-") as directory:
    scratch = Path(directory)
    source = scratch / "source.jsonl"
    source.write_text("\n".join(json.dumps(r) for r in source_records) + "\n")
    target = scratch / "converted.jsonl"
    run = subprocess.run([str(root / ".lake/build/bin/loom"), "convert", str(source), "codex", str(target)], capture_output=True, text=True)
    assert run.returncode == 0, run.stderr
    converted = [json.loads(line) for line in target.read_text().splitlines()]
    user_messages = [r["payload"] for r in converted if r.get("type") == "response_item" and r.get("payload", {}).get("role") == "user"]
    assert [r["content"][0]["text"] for r in user_messages] == [text, "Latest request"]
    archived = converted[0]["payload"]["_agent_convert_source_archive"]["source_control_records"]
    assert len(archived) == 1 and archived[0]["record"] == source_records[1]

    # Repair an older rollout that rendered both records as prompts. Match source
    # timestamp and metadata, so the unmarked literal survives unchanged.
    old = scratch / "old.jsonl"
    rows = [{"type": "session_meta", "timestamp": source_records[0]["timestamp"], "payload": {"id": str(uuid.uuid4()), "cwd": "/tmp"}}]
    for record in source_records:
        content = record["message"]["content"][0]["text"]
        rows.extend([
            {"type": "response_item", "timestamp": record["timestamp"], "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": content}]}},
            {"type": "event_msg", "timestamp": record["timestamp"], "payload": {"type": "user_message", "message": content}},
        ])
    tools = [
        {"type": "response_item", "timestamp": "2026-09-29T12:00:04.000Z", "payload": {"type": "function_call", "call_id": "tu2", "name": "Read", "arguments": "{\"file_path\":\"example\"}"}},
        {"type": "response_item", "timestamp": "2026-09-29T12:00:05.000Z", "payload": {"type": "function_call_output", "call_id": "tu2", "output": "Retained recorded output"}},
    ]
    rows.extend(tools)
    old.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    clean, report = scratch / "clean.jsonl", scratch / "report.json"
    result = repair_module.repair(old, source, clean, report)
    assert result["notificationsArchived"] == 1 and result["dialogueRecordsRemoved"] == 2
    repaired = [json.loads(line) for line in clean.read_text().splitlines()]
    assert repaired[-2:] == tools
    assert repaired[1:3] == rows[1:3]
    assert repaired[0]["payload"]["_agent_convert_source_archive"]["source_control_records"][0]["record"] == source_records[1]
    try:
        repair_module.repair(old, source, clean, report)
    except FileExistsError:
        pass
    else:
        raise AssertionError("Repair overwrote an existing destination")
print("Passed: generated controls archived; literal XML retained; native tools unchanged; overwrite refused.")
