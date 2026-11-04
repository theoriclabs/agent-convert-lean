#!/usr/bin/env python3
"""Real-core CLI checks; all source data, output, and stores are synthetic."""
import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import uuid
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'cli'))
import agent_convert


def pdf_bytes():
    stream = b'BT /F1 18 Tf 50 700 Td (RECORDED-PDF-MARKER) Tj ET'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
               b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream']
    result = b'%PDF-1.4\n'; offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(result)); result += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
    start = len(result)
    result += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    result += b''.join(f'{offset:010d} 00000 n \n'.encode() for offset in offsets[1:])
    return result + f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()


def png_bytes():
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))
    header = struct.pack('>IIBBBBB', 64, 64, 8, 6, 0, 0, 0)
    pixels = b''.join(b'\x00' + bytes([30, 80, 190, 255]) * 64 for _ in range(64))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


def fixture(directory):
    source = directory / 'claude source.jsonl'
    sentinel = directory / 'MUST-NOT-BE-EXECUTED'
    session = str(uuid.uuid4()); previous = None; rows = []
    def row(role, content):
        nonlocal previous
        ident = str(uuid.uuid4())
        record = {'type': role, 'uuid': ident, 'parentUuid': previous, 'sessionId': session,
                  'cwd': str(directory), 'version': '2.1.274', 'timestamp': f'2026-11-03T00:00:00.{len(rows):03d}Z',
                  'isSidechain': False, 'message': {'role': role, 'content': content}}
        if role == 'assistant':
            record['message'].update({'id': 'msg_' + ident, 'model': 'claude-test', 'type': 'message'})
        previous = ident; rows.append(record)
    row('user', [{'type': 'text', 'text': 'Review the recorded PDF and failed command.'}])
    row('assistant', [{'type': 'tool_use', 'id': 'failed-call', 'name': 'Bash',
                       'input': {'command': 'touch ' + str(sentinel)}}])
    row('user', [{'type': 'tool_result', 'tool_use_id': 'failed-call', 'content': 'RECORDED-FAILURE', 'is_error': True}])
    long_id = 'pdf-' + 'x' * 90
    row('assistant', [{'type': 'tool_use', 'id': long_id, 'name': 'Read', 'input': {'file_path': 'original.pdf'}}])
    rows[-1]['parentUuid'] = rows[1]['uuid']  # Skip the earlier result in the selected parent walk.
    document = {'type': 'document', 'source': {'type': 'base64', 'media_type': 'application/pdf',
                                              'data': base64.b64encode(pdf_bytes()).decode()}}
    row('user', [{'type': 'tool_result', 'tool_use_id': long_id, 'is_error': False,
                  'content': [{'type': 'text', 'text': 'RECORDED-BEFORE'}, document,
                              {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png',
                               'data': base64.b64encode(png_bytes()).decode()}},
                              {'type': 'text', 'text': 'RECORDED-AFTER'},
                              {'type': 'tool_reference', 'tool_name': 'fixture_historical_tool'}]}])
    row('user', [{'type': 'text', 'text': 'Peer envelope'}])
    rows[-1].update({'promptSource': 'system', 'turnOrigin': 'peer',
                     'origin': {'kind': 'peer', 'from': 'synthetic-peer', 'name': 'Fixture peer',
                                'body': 'RECORDED-PEER-CONTEXT'}})
    row('assistant', [{'type': 'text', 'text': 'LAST-ASSISTANT: reviewed the PDF and recorded failure.'}])
    row('user', [{'type': 'text', 'text': 'LATEST-REQUEST: keep both facts for the next task.'}])
    source.write_text(''.join(json.dumps(r) + '\n' for r in rows))
    return source, sentinel, long_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', default=os.environ.get('LOOM_BIN', str(ROOT / '.lake/build/bin/loom')))
    parser.add_argument('--native', action='store_true', help='Also exercise installed Codex against a localhost fake provider')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='agent-convert-test-') as temp:
        directory = Path(temp)
        source, sentinel, long_id = fixture(directory)
        original = source.read_bytes()
        home = directory / 'codex-home'; home.mkdir()
        (home / 'config.toml').write_text('model = "gpt-6.1-sol"\nmodel_provider = "openai"\n')
        output = directory / 'converted.jsonl'
        command = [sys.executable, str(ROOT / 'cli/agent_convert.py'), '--core', str(Path(args.core).resolve()),
                   'convert', str(source), 'codex', str(output), '--codex-home', str(home), '--json',
                   '--validation', 'native' if args.native else 'artifact']
        result = subprocess.run(command, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        receipt = json.loads(result.stdout)
        assert receipt['conversion']['targetModel'] == 'gpt-6.1-sol'
        assert receipt['conversion']['toolCallsEmittedNative'] == 2
        assert receipt['conversion']['toolResultsEmitted'] == 2
        assert receipt['pdfDocuments'] == receipt['pdfPages'] == 1
        assert receipt['sourceImages'] == receipt['peerMessages'] == 1
        assert receipt['recoveredResults'] == 1
        rows = [json.loads(line) for line in output.read_text().splitlines()]
        # Running sessions are captured only at complete-record boundaries.
        snapshot_source = directory / 'growing-codex.jsonl'
        snapshot_output = directory / 'snapshot.jsonl'
        snapshot_source.write_bytes(output.read_bytes() + b'{"partial":')
        captured = agent_convert.snapshot_file('codex', snapshot_source, snapshot_output)
        assert snapshot_output.read_bytes() == output.read_bytes()
        assert captured['omittedRecords'] == 0 and captured['runningToolCalls'] == []
        # A call still running ends the snapshot; no result is invented for it.
        started = {'type': 'event_msg', 'payload': {'type': 'task_started'}}
        pending = {'type': 'response_item', 'payload': {'type': 'function_call', 'call_id': 'pending', 'name': 'exec_command'}}
        later = {'type': 'event_msg', 'payload': {'type': 'token_count'}}
        snapshot_source.write_text(output.read_text() + ''.join(json.dumps(r) + '\n' for r in (started, pending, later)))
        snapshot_output.unlink()
        captured = agent_convert.snapshot_file('codex', snapshot_source, snapshot_output)
        assert snapshot_output.read_text() == output.read_text() + json.dumps(started) + '\n'
        assert captured['omittedRecords'] == 2 and captured['runningToolCalls'] == ['exec_command']
        # Parallel Claude calls: a call whose result follows a running call is left out with it.
        prompt = {'type': 'user', 'message': {'role': 'user', 'content': 'IN-PROGRESS-REQUEST'}}
        def claude_call(ident):
            return {'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                {'type': 'tool_use', 'id': ident, 'name': 'Bash', 'input': {}}]}}
        finished = {'type': 'user', 'message': {'role': 'user', 'content': [
            {'type': 'tool_result', 'tool_use_id': 'first', 'content': 'done'}]}}
        claude_running = directory / 'running-claude.jsonl'
        claude_running.write_text(source.read_text() + ''.join(
            json.dumps(r) + '\n' for r in (prompt, claude_call('first'), claude_call('second'), finished)))
        claude_snapshot = directory / 'claude-snapshot' / 'running-claude.jsonl'
        captured = agent_convert.snapshot_file('claude', claude_running, claude_snapshot)
        assert claude_snapshot.read_text() == source.read_text() + json.dumps(prompt) + '\n'
        assert captured['omittedRecords'] == 3 and captured['runningToolCalls'] == ['Bash']
        # End to end: --snapshot converts a running Claude session that would otherwise be refused.
        running_rows = [json.loads(line) for line in source.read_text().splitlines()]
        last = running_rows[-1]
        def threaded(record):
            nonlocal last
            record = {**{k: last[k] for k in ('sessionId', 'cwd', 'version', 'isSidechain')}, **record,
                      'uuid': str(uuid.uuid4()), 'parentUuid': last['uuid'], 'timestamp': last['timestamp']}
            if record['type'] == 'assistant':
                record['message'].update({'id': 'msg_' + record['uuid'], 'model': 'claude-test', 'type': 'message'})
            last = record
            return record
        running_rows[-1]['message']['content'] = [{'type': 'text', 'text': 'LATEST-REQUEST: keep both facts for the next task.'}]
        running_rows += [threaded({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
            {'type': 'text', 'text': 'Checking.'}]}}), threaded(claude_call('still-running'))]
        claude_running.write_text(''.join(json.dumps(r) + '\n' for r in running_rows))
        snapshot_converted = directory / 'snapshot-converted.jsonl'
        snapshot_command = command.copy()
        snapshot_command[snapshot_command.index(str(source))] = str(claude_running)
        snapshot_command[snapshot_command.index(str(output))] = str(snapshot_converted)
        snapped = subprocess.run(snapshot_command + ['--snapshot'], capture_output=True, text=True)
        assert snapped.returncode == 0, snapped.stderr
        snapped_receipt = json.loads(snapped.stdout)
        assert snapped_receipt['snapshot']['omittedRecords'] == 1
        assert snapped_receipt['snapshot']['runningToolCalls'] == ['Bash']
        assert snapped_receipt['snapshot']['sourceChangedDuringConversion'] is False
        snapped_rows = [json.loads(line) for line in snapshot_converted.read_text().splitlines()]
        snapped_calls, snapped_results = agent_convert.codex_native.history(snapped_rows)
        assert len(snapped_calls) == len(snapped_results) == 2
        assert 'still-running' not in snapshot_converted.read_text()
        assert 'Checking.' in snapshot_converted.read_text()
        assert agent_convert.unreplayable_reasoning(rows) == 0
        assert agent_convert.unreplayable_reasoning([
            {'type': 'response_item', 'payload': {'type': 'reasoning', 'summary': []}},
            {'type': 'response_item', 'payload': {'type': 'reasoning', 'summary': [], 'encrypted_content': 'gAAA'}}]) == 1
        calls, results = agent_convert.codex_native.history(rows)
        assert len(calls) == len(results) == 2
        pdf_result = next(row for row in rows if row.get('_agent_convert_pdf_results'))
        assert len(pdf_result['payload']['call_id']) <= 64
        assert pdf_result['_agent_convert_call_id']['source'] == long_id
        content = pdf_result['payload']['output']
        assert [b['type'] for b in content] == ['input_text', 'input_text', 'input_image', 'input_image', 'input_text', 'input_text']
        assert content[0]['text'] == 'RECORDED-BEFORE'
        assert content[-2]['text'] == 'RECORDED-AFTER'
        assert json.loads(content[-1]['text']) == {'type': 'tool_reference', 'tool_name': 'fixture_historical_tool'}
        assert receipt['structuredToolReferences'] == 1
        peer = next(r for r in rows if r.get('_agent_convert_source_role'))
        assert peer['_agent_convert_source_role']['role'] == 'peer'
        assert peer['payload']['role'] == 'user'
        assert 'RECORDED-PEER-CONTEXT' in peer['payload']['content'][0]['text']
        assert 'RECORDED-PDF-MARKER' in content[1]['text']
        raw = pdf_result['_agent_convert_pdf_results']['documents'][0]['originalBlock']['raw']['source']['data']
        assert base64.b64decode(raw) == pdf_bytes()
        assert not sentinel.exists(), 'Historical command was rerun'
        assert source.read_bytes() == original
        assert Path(str(output) + '.conversion.json').exists()
        assert receipt['verification']['liveModelRecall'] is False
        if args.native:
            assert receipt['verification']['nativeLoad'] is True
            assert receipt['verification']['nativeRequestSerialization'] is True
            assert receipt['verification']['externalModelRequests'] == 0
        # Recovery must reject conflicting same-ID observations rather than guess.
        conflicting = directory / 'conflicting-source.jsonl'
        original_rows = [json.loads(line) for line in source.read_text().splitlines()]
        alternative = json.loads(json.dumps(original_rows[2]))
        alternative['uuid'] = str(uuid.uuid4())
        alternative['message']['content'][0]['content'] = 'CONFLICTING-RESULT'
        original_rows.insert(3, alternative)
        conflicting.write_text(''.join(json.dumps(row) + '\n' for row in original_rows))
        conflicting_command = command.copy()
        conflicting_command[conflicting_command.index(str(source))] = str(conflicting)
        conflicting_output = directory / 'conflicting-output.jsonl'
        conflicting_command[conflicting_command.index(str(output))] = str(conflicting_output)
        refused = subprocess.run(conflicting_command, capture_output=True, text=True)
        assert refused.returncode != 0 and 'Conflicting recorded results' in refused.stderr
        assert not conflicting_output.exists()
        # Publication never overwrites a prior export or silently repairs an ID.
        again = subprocess.run(command, capture_output=True, text=True)
        assert again.returncode != 0 and 'already exists' in again.stderr
        invalid_command = command.copy()
        invalid_path = directory / 'invalid-target.jsonl'
        invalid_command[invalid_command.index(str(output))] = str(invalid_path)
        invalid = subprocess.run(invalid_command + ['--session-id', 'invalid'], capture_output=True, text=True)
        assert invalid.returncode != 0 and not invalid_path.exists()
        assert 'already exists' not in invalid.stderr
        # Exercise real installation in an isolated Codex store.
        installed_command = command.copy(); installed_command.remove(str(output))
        installed_command += ['--name', 'Synthetic migrated session']
        installed = subprocess.run(installed_command, capture_output=True, text=True)
        assert installed.returncode == 0, installed.stderr
        installed_receipt = json.loads(installed.stdout)
        path = Path(installed_receipt['outputs'][0])
        assert str(path.resolve()).startswith(str(home.resolve()) + os.sep)
        assert path.exists() and 'resume' in installed_receipt['resumeCommand']
        if args.native or __import__('shutil').which('codex'):
            assert installed_receipt['registeredName'] == 'Synthetic migrated session'
        assert not sentinel.exists()
        # Explicit Claude IDs cannot replace another native conversation.
        claude_projects = directory / 'claude-projects'
        claude_projects.mkdir()
        occupied_id = str(uuid.uuid4())
        occupied = claude_projects / (occupied_id + '.jsonl')
        occupied.write_text('EXISTING-CONVERSATION')
        claude = subprocess.run([sys.executable, str(ROOT / 'cli/agent_convert.py'),
                                 '--core', str(Path(args.core).resolve()), 'convert', str(source),
                                 'claude', '--session-id', occupied_id],
                                env={**os.environ, 'CLAUDE_PROJECTS': str(claude_projects)},
                                capture_output=True, text=True)
        assert claude.returncode != 0 and 'already exists' in claude.stderr
        assert occupied.read_text() == 'EXISTING-CONVERSATION'
        # Invalid output IDs and missing native validators fail before publication.
        missing = command.copy(); missing[missing.index(str(output))] = str(directory / 'must-not-exist.jsonl')
        missing += ['--codex', 'agent-convert-no-such-codex', '--validation', 'native']
        failed = subprocess.run(missing, capture_output=True, text=True)
        assert failed.returncode != 0 and not (directory / 'must-not-exist.jsonl').exists()
        print(json.dumps({'check': 'agent-convert-cli', 'passed': True, 'nativeValidation': args.native,
                          'sourceUnchanged': True, 'pdfBytesRetained': True, 'historicalToolsRerun': 0,
                          'longCallIdMapping': True, 'omittedResultsRecovered': True, 'ambiguousRecoveryRefused': True, 'sourceImagesRetained': True, 'peerContextRetained': True, 'installation': True, 'overwriteRefused': True}))


if __name__ == '__main__':
    main()
