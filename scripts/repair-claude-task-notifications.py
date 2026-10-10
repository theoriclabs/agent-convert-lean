#!/usr/bin/env python3
"""Remove authenticated Claude task controls from a converted Codex dialogue.

Write a new rollout, retaining exact source controls in native session metadata.
Never match XML alone, overwrite a rollout, start a model, or execute old tools.
"""

import argparse
import collections
import datetime
import hashlib
import json
from pathlib import Path
import uuid


def load(path):
    data = path.read_bytes()
    return data, [json.loads(line) for line in data.splitlines() if line.strip()]


def text_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list) and len(content) == 1:
        block = content[0]
        if block.get("type") in ("text", "input_text"):
            return block.get("text")
    return None


def generated_task(record):
    return record.get("isMeta") is True or (
        record.get("origin", {}).get("kind") == "task-notification"
        and record.get("promptSource") == "system"
        and record.get("turnOrigin") == "task_notification"
    )


def repair(rollout, source, output, report_path):
    if output.resolve() in (rollout.resolve(), source.resolve()):
        raise ValueError("Write to a new destination; do not replace either source.")
    if output.exists() or report_path.exists():
        raise FileExistsError("Output or report already exists.")
    original_bytes, rows = load(rollout)
    source_bytes, source_rows = load(source)
    controls = collections.defaultdict(list)
    for record in source_rows:
        if record.get("type") != "user" or not generated_task(record):
            continue
        text = text_content(record.get("message", {}).get("content"))
        if isinstance(text, str) and text.startswith("<task-notification>\n") and text.endswith("\n</task-notification>"):
            controls[(record.get("timestamp"), text)].append(record)

    kept, removed, archived = [], [], []
    keys_seen = set()
    for row in rows:
        payload = row.get("payload", {})
        text = None
        if row.get("type") == "response_item" and payload.get("type") == "message" and payload.get("role") == "user":
            text = text_content(payload.get("content"))
        elif row.get("type") == "event_msg" and payload.get("type") == "user_message":
            text = payload.get("message")
        key = (row.get("timestamp"), text)
        matches = controls.get(key, []) if isinstance(text, str) else []
        if not matches:
            kept.append(row)
            continue
        if len(matches) != 1:
            raise ValueError("Ambiguous source notification; refusing removal.")
        source_record = matches[0]
        removed.append(row)
        if key not in keys_seen:
            keys_seen.add(key)
            archived.append({
                "kind": "task-notification",
                "raw": text,
                "record": source_record,
                "uuid": source_record.get("uuid"),
                "timestamp": source_record.get("timestamp"),
            })

    if not archived:
        raise ValueError("No source-authenticated task notifications found.")
    metadata = [row for row in kept if row.get("type") == "session_meta"]
    if len(metadata) != 1:
        raise ValueError("Expected exactly one session metadata record.")
    header = metadata[0]
    payload = header["payload"]
    old_id = payload["id"]
    new_id = str(uuid.uuid4())
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    archive = payload.get("_agent_convert_source_archive")
    if archive is None:
        source_record = archived[0]["record"]
        archive = {
            "protocol": "agent-convert.codex-carriers.v1",
            "kind": "historical_source_provenance",
            "source_session_payload": {}, "source_identity": {},
            "source_env": {"cwd": source_record.get("cwd"), "harnessVersion": None,
                           "instructions": None, "model": None, "provider": None,
                           "sessionId": source_record.get("sessionId")},
            "source_control_records": [], "generated_target_control_records": [],
        }
        payload["_agent_convert_source_archive"] = archive
    archive["source_control_records"].extend(archived)
    payload["id"] = new_id
    if "session_id" in payload:
        payload["session_id"] = new_id
    payload["timestamp"] = now
    header["timestamp"] = now

    # Only authenticated notification rows and the session identity may change.
    old_tools = [r for r in rows if r.get("payload", {}).get("type") in (
        "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output")]
    new_tools = [r for r in kept if r.get("payload", {}).get("type") in (
        "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output")]
    assert old_tools == new_tools
    assert len(rows) == len(kept) + len(removed)
    report = {
        "input": str(rollout.resolve()), "inputSha256": hashlib.sha256(original_bytes).hexdigest(),
        "source": str(source.resolve()), "sourceSha256": hashlib.sha256(source_bytes).hexdigest(),
        "output": str(output.resolve()), "previousSessionId": old_id, "sessionId": new_id,
        "timestamp": now, "notificationsArchived": len(archived), "dialogueRecordsRemoved": len(removed),
        "nativeToolRecordsPreserved": len(new_tools), "allOtherHistoryPreserved": True,
        "originalsUnchanged": True, "removedRecords": removed,
    }
    with output.open("x") as stream:
        for row in kept:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    with report_path.open("x") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    assert rollout.read_bytes() == original_bytes and source.read_bytes() == source_bytes
    return {key: report[key] for key in (
        "output", "sessionId", "notificationsArchived", "dialogueRecordsRemoved", "nativeToolRecordsPreserved")}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rollout", type=Path)
    parser.add_argument("--claude-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(repair(args.rollout, args.claude_source, args.output, args.report)))
