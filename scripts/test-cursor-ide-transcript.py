#!/usr/bin/env python3
"""Synthetic read-only Cursor store recovery; never reads the user's database."""

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LOOM = Path(os.environ.get("LOOM_BIN", ROOT / ".lake/build/bin/loom")).resolve()
SESSION = "72000000-0000-4000-8000-000000000001"
STAMP = "2026-10-15T12:00:00.000Z"


def varint(n):
    data = bytearray()
    while n > 127:
        data.append((n & 127) | 128)
        n >>= 7
    return bytes(data + bytes([n]))


def field(number, value):
    value = value.encode() if isinstance(value, str) else value
    return varint(number * 8 + 2) + varint(len(value)) + value


def row(role, *blocks):
    return {"role": role, "message": {"content": list(blocks)}}


def text(value):
    return {"type": "text", "text": value}


def call(name, args):
    return {"type": "tool_use", "name": name, "input": args}


def write_export(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))


def wire_results(transcript):
    return [b for e in transcript["entries"] for b in e["payload"].get("blocks", [])
            if b["type"] == "toolResult"]


def wire_calls(transcript):
    return [b for e in transcript["entries"] for b in e["payload"].get("blocks", [])
            if b["type"] == "toolCall"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


with tempfile.TemporaryDirectory(prefix="loom-cursor-ide-export-") as directory:
    scratch = Path(directory)
    source = scratch / ".cursor/projects/synthetic/agent-transcripts" / SESSION / f"{SESSION}.jsonl"
    db = scratch / "state.vscdb"
    env = {**os.environ, "LOOM_CURSOR_IDE_DB": str(db)}
    marker = scratch / "must-not-be-executed"
    command = f"touch {marker}"
    export_rows = [
        row("user", text("<timestamp>recorded time</timestamp>\n<user_query>\nRead the fixture.\n</user_query>")),
        # Repeated identical calls and duplicate stored IDs must retain occurrence order.
        row("assistant", call("Read", {"path": "example.txt"}), call("Read", {"path": "example.txt"})),
        row("assistant", text("Searching next.")),
        row("assistant", call("Grep", {"pattern": "needle", "head_limit": 5})),
        row("assistant", call("Shell", {"command": command, "description": "Recorded action only"})),
        row("assistant", text("Finished.")),
        {"type": "turn_ended", "status": "error", "error": "recorded turn failure",
         "future": {"kept": True}},
    ]
    write_export(source, export_rows)
    bubbles = [{"bubbleId": "user", "type": 1, "text": "Read the fixture.", "createdAt": STAMP}]

    def tool(bid, name, enum, args, result=None, status="completed", **extra):
        tf = {"tool": enum, "name": name, "toolCallId": "duplicate-recorded-id",
              "rawArgs": json.dumps(args), "status": status, **extra}
        if result is not None:
            tf["result"] = result
        return {"bubbleId": bid, "type": 2, "createdAt": STAMP, "toolFormerData": tf}

    bubbles += [tool("read-1", "read_file_v2", 40, {"path": "example.txt"}, "first recorded result"),
                tool("read-2", "read_file_v2", 40, {"path": "example.txt"}, ""),
                {"bubbleId": "between", "type": 2, "text": "Searching next.", "createdAt": STAMP}]
    # Same-bubble binary result, independently encoded; the inline field is absent.
    binary = field(5, field(2, field(2, field(1, "recorded grep failure"))))
    bubbles.append(tool("grep", "ripgrep_raw_search", 41,
                        {"pattern": "needle", "headLimit": 5, "caseInsensitive": False,
                         "multiline": False, "offset": 0, "toolCallId": "duplicate-recorded-id"},
                        status="error", toolCallBinary=base64.b64encode(binary).decode()))
    bubbles.append(tool("shell", "run_terminal_command_v2", 15, {}, "recorded shell output",
                        params=json.dumps({"command": command, "commandDescription": "Recorded action only"})))
    bubbles.append({"bubbleId": "end", "type": 2, "text": "Finished.", "createdAt": STAMP})
    composer = {"composerId": SESSION, "fullConversationHeadersOnly":
                [{"bubbleId": b["bubbleId"], "type": b["type"]} for b in bubbles]}
    connection = sqlite3.connect(db)
    connection.executescript("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);"
                             "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);")

    def save(key, value):
        connection.execute("INSERT OR REPLACE INTO cursorDiskKV VALUES (?, ?)",
                           (key, json.dumps(value)))
        connection.commit()

    save(f"composerData:{SESSION}", composer)
    for bubble in bubbles:
        save(f"bubbleId:{SESSION}:{bubble['bubbleId']}", bubble)
    original_db, original_source = digest(db), digest(source)
    sequence = 0

    def convert(target="loom", source_path=source, flags=(), expect=0):
        global sequence
        sequence += 1
        output = scratch / f"result-{sequence}.{target}"
        run = subprocess.run([str(LOOM), "convert", str(source_path), target, str(output),
                              "--target-cwd", str(scratch), "--json", *flags],
                             env=env, capture_output=True, text=True)
        assert run.returncode == expect, (run.returncode, run.stderr)
        if expect:
            assert not output.exists(), "Refused recovery wrote an output"
            return run.stderr
        return json.loads(output.read_text()) if target == "loom" else [
            json.loads(line) for line in output.read_text().splitlines()]

    recovered = convert()
    results = wire_results(recovered)
    assert len(wire_calls(recovered)) == len(results) == 4
    assert results[0]["content"] == [text("first recorded result")]
    assert results[1]["content"] == [text("")]
    assert json.loads(results[2]["content"][0]["text"]) == {"error": {"error": "recorded grep failure"}}
    assert results[2]["error"] == {"kind": "native", "isError": "true"}
    assert results[3]["content"] == [text("recorded shell output")]
    assert [c["arguments"] for c in wire_calls(recovered)] == [
        b["input"] for r in export_rows for b in r.get("message", {}).get("content", []) if b["type"] == "tool_use"]
    assert any(n["kind"] == "cursorIdeTranscriptResultsRecovered" for n in recovered["importNotes"])
    assert recovered["origin"]["extras"]["raw_control_messages"][0]["raw"] == export_rows[-1]
    assert not any(e["payload"]["type"] == "event" for e in recovered["entries"])
    # Every recovered result is in the selected linear history, including the tail.
    for i, entry in enumerate(recovered["entries"]):
        assert entry.get("parent") == (None if i == 0 else str(i - 1))
    assert len(wire_results(convert(flags=("--no-subagents",)))) == 4
    assert [c["id"] for c in wire_calls(recovered)] == ["duplicate-recorded-id"] * 4
    assert digest(db) == original_db and digest(source) == original_source

    # The existing Codex native exporter requires unique call IDs. Verify its
    # native path with unique *recorded* IDs; duplicates above remain exact in IR.
    for bubble in bubbles:
        if "toolFormerData" in bubble:
            bubble["toolFormerData"]["toolCallId"] = "recorded-" + bubble["bubbleId"]
            save(f"bubbleId:{SESSION}:{bubble['bubbleId']}", bubble)
    native_db = digest(db)

    codex = convert("codex")
    items = [r["payload"] for r in codex if r.get("type") == "response_item"]
    calls = [r for r in items if r["type"] == "function_call"]
    outputs = [r for r in items if r["type"] == "function_call_output"]
    assert len(calls) == len(outputs) == 4, [r["type"] for r in items]
    assert [c["call_id"] for c in calls] == [r["call_id"] for r in outputs]
    assert len(set(c["call_id"] for c in calls)) == 4
    assert [r["output"] for r in outputs[:2]] == ["first recorded result", ""]
    archived = codex[0]["payload"]["_agent_convert_source_archive"]["source_control_records"]
    assert archived[0]["raw"] == export_rows[-1]
    claude = convert("claude")
    blocks = [b for r in claude for b in r.get("message", {}).get("content", []) if isinstance(b, dict)]
    assert sum(b["type"] == "tool_use" for b in blocks) == 4
    assert sum(b["type"] == "tool_result" for b in blocks) == 4
    provenance = [r.get("_agent_convert", {}).get("transcriptProvenance", {}) for r in claude]
    assert any(p.get("kind") == "record" and p.get("payload", {}).get("raw") == export_rows[-1]
               for p in provenance), provenance
    assert not marker.exists(), "Import reran a historical command"
    assert digest(db) == native_db and digest(source) == original_source

    inspected = subprocess.run([str(LOOM), "inspect", "cursor-agent", str(source), "--json"],
                               env=env, capture_output=True, text=True)
    assert inspected.returncode == 0, inspected.stderr
    assert len(wire_results(json.loads(inspected.stdout)["transcript"])) == 4

    # Default derivation and installation must use the same recovered source.
    install_root = scratch / "claude-projects"
    installed = subprocess.run([str(LOOM), "convert", str(source), "claude",
                                "--target-cwd", str(scratch)],
                               env={**env, "CLAUDE_PROJECTS": str(install_root)},
                               capture_output=True, text=True)
    assert installed.returncode == 0, installed.stderr
    installed_files = list(install_root.rglob(f"{SESSION}.jsonl"))
    assert len(installed_files) == 1
    installed_rows = [json.loads(line) for line in installed_files[0].read_text().splitlines()]
    assert sum(b.get("type") == "tool_result" for r in installed_rows
               for b in r.get("message", {}).get("content", []) if isinstance(b, dict)) == 4

    # Native sidecar acquisition also recovers results before graph rebasing.
    child_id = "72000000-0000-4000-8000-000000000002"
    child_file = source.parent / "subagents" / f"{child_id}.jsonl"
    write_export(child_file, [row("assistant", call("Read", {"path": "child.txt"}))])
    child_bubble = tool("child-read", "read_file_v2", 40, {"path": "child.txt"}, "child output")
    save(f"composerData:{child_id}", {"composerId": child_id,
         "fullConversationHeadersOnly": [{"bubbleId": "child-read", "type": 2}]})
    save(f"bubbleId:{child_id}:child-read", child_bubble)
    stitched = convert(flags=("--with-subagents",))
    assert len(stitched["threads"]) == 2 and len(wire_results(stitched)) == 5
    child_result_entry = next(e for e in stitched["entries"] if e["payload"].get("blocks") == [wire_results(stitched)[-1]])
    child_result = child_result_entry["payload"]["blocks"][0]
    owner = stitched["entries"][int(child_result["call"]["entry"])]
    assert child_result_entry["thread"] == owner["thread"] == "1"
    assert len(wire_results(convert(flags=("--no-subagents",)))) == 4
    child_file.unlink()

    # Matching a bare filename is insufficient to read a private conversation.
    copied = scratch / f"{SESSION}.jsonl"
    write_export(copied, export_rows)
    assert not wire_results(convert(source_path=copied))

    for change in ["message", "arguments", "tool-order", "id", "count", "text-order"]:
        changed = copy.deepcopy(export_rows)
        if change == "message":
            changed[0]["message"]["content"][0]["text"] = "A different request"
        elif change == "arguments":
            changed[1]["message"]["content"][0]["input"]["path"] = "other.txt"
        elif change == "tool-order":
            changed[1], changed[3] = changed[3], changed[1]
        elif change == "id":
            changed[1]["message"]["content"][0]["id"] = "another-operation"
        elif change == "count":
            changed[1]["message"]["content"].pop()
        else:
            changed[2], changed[3] = changed[3], changed[2]
        write_export(source, changed)
        assert "Cursor result recovery" in convert(expect=2)
    write_export(source, export_rows)

    unknown = {"type": "future_event", "payload": {"keep": "unrecognized event"}}
    write_export(source, export_rows + [unknown])
    assert any(e["payload"].get("event", {}).get("raw") == unknown for e in convert()["entries"])
    assert "dropEvents" in convert("codex", expect=3)
    write_export(source, export_rows)

    # Wrapper-looking user-authored text in the store must remain literal.
    literal = "<user_query>\nRead the fixture.\n</user_query>"
    save(f"bubbleId:{SESSION}:user", {**bubbles[0], "text": literal})
    assert "messages differ" in convert(expect=2)
    literal_rows = copy.deepcopy(export_rows)
    literal_rows[0]["message"]["content"][0]["text"] = "<user_query>\n" + literal + "\n</user_query>"
    write_export(source, literal_rows)
    assert len(wire_results(convert())) == 4
    save(f"bubbleId:{SESSION}:user", bubbles[0])
    write_export(source, export_rows)

    save(f"composerData:{SESSION}", {**composer, "composerId": "different-session"})
    assert "identity" in convert(expect=2)
    save(f"composerData:{SESSION}", composer)
    connection.execute("DELETE FROM cursorDiskKV WHERE key=?", (f"bubbleId:{SESSION}:read-1",))
    connection.commit()
    assert "Cursor result recovery" in convert(expect=2)
    save(f"bubbleId:{SESSION}:read-1", bubbles[1])

    # A retained provisional loading result is not a completed execution.
    pending = copy.deepcopy(bubbles[1])
    pending["toolFormerData"]["status"] = "loading"
    save(f"bubbleId:{SESSION}:read-1", pending)
    assert len(wire_results(convert())) == 3
    save(f"bubbleId:{SESSION}:read-1", bubbles[1])

    connection.execute("DELETE FROM cursorDiskKV WHERE key=?", (f"composerData:{SESSION}",))
    connection.commit()
    missing = convert()
    assert not wire_results(missing), "Borrowed an unrelated session's results"
    assert any(n["kind"] == "cursorIdeTranscriptRecoveryUnavailable" for n in missing["importNotes"])
    connection.close()

print("Cursor IDE transcript recovery: exact outputs, binary/error/empty results, repeated IDs, "
      "active linkage, native Codex/Claude history, stale-source refusals, and read-only acquisition passed.")
