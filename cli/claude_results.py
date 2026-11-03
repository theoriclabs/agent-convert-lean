"""Recover same-session native results omitted by Claude's selected parent walk."""
import bisect
import copy
import hashlib
import json
import uuid


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=True)


def recover(core, source, transcript, directory, run):
    entries = transcript['entries']
    if (len(transcript['threads']) != 1 or transcript.get('activeLeaf') is None or
            int(transcript['activeLeaf']) != len(entries) - 1):
        return transcript, []
    calls = {}
    linked = set()
    for index, entry in enumerate(entries):
        for block_index, block in enumerate(entry['payload'].get('blocks', [])):
            if block['type'] == 'toolCall' and entry.get('disposition', 'native') == 'native' and block.get('id'):
                calls.setdefault(block['id'], []).append((index, block_index, block))
            elif block['type'] == 'toolResult' and block['call']['kind'] == 'resolved':
                linked.add((int(block['call']['entry']), int(block['call']['block'])))
    missing = [(call_id, located[0]) for call_id, located in calls.items()
               if len(located) == 1 and located[0][:2] not in linked]
    if not missing:
        return transcript, []
    session_id = transcript['env'].get('sessionId')
    records = []
    first_uuid = {}
    raw_calls = {}
    raw_results = {}
    for number, line in enumerate(source.open(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        records.append(row)
        if row.get('uuid'):
            first_uuid.setdefault(row['uuid'], number)
        if row.get('sessionId') != session_id or row.get('isSidechain', False):
            continue
        content = row.get('message', {}).get('content')
        if not isinstance(content, list):
            continue
        for block in content:
            if row.get('type') == 'assistant' and block.get('type') == 'tool_use':
                raw_calls.setdefault(block.get('id'), []).append((number, row, block))
            elif row.get('type') == 'user' and block.get('type') == 'tool_result':
                raw_results.setdefault(block.get('tool_use_id'), []).append((number, row, block))
    positions = [first_uuid.get(entry['origin'].get('rawId')) for entry in entries]
    if any(position is None for position in positions) or positions != sorted(positions):
        raise ValueError('Cannot recover missing results: selected source record order is ambiguous')
    selected = []
    for call_id, (entry_index, block_index, call) in missing:
        candidates = raw_results.get(call_id, [])
        if not candidates:
            continue  # The CLI must not invent a missing source result.
        source_calls = raw_calls.get(call_id, [])
        caller_uuid = entries[entry_index]['origin'].get('rawId')
        if not source_calls or {row.get('uuid') for _, row, _ in source_calls} != {caller_uuid}:
            raise ValueError(f'Cannot uniquely authenticate source call for recovered result: {call_id}')
        for _, _, raw_call in source_calls:
            if raw_call.get('name') != call['name'] or raw_call.get('input') != call['arguments']:
                raise ValueError(f'Source call identity has conflicting arguments: {call_id}')
        unique = {(canonical(block), canonical(row.get('toolUseResult'))) for _, row, block in candidates}
        if len(unique) != 1:
            raise ValueError(f'Conflicting recorded results for {call_id}; refusing to choose one')
        source_line, result_row, result_block = candidates[0]
        if source_line <= min(number for number, _, _ in source_calls):
            raise ValueError(f'Recorded result precedes its source call: {call_id}')
        after = max(entry_index, bisect.bisect_right(positions, source_line) - 1)
        selected.append({'callId': call_id, 'entry': entry_index, 'block': block_index,
                         'sourceLine': source_line, 'sourceUuid': result_row.get('uuid'),
                         'after': after, 'row': result_row, 'rawBlock': result_block,
                         'callRow': source_calls[0][1], 'rawCall': source_calls[0][2]})
    if not selected:
        return transcript, []
    # Parse only retained source result bytes with the existing Claude importer.
    # Fresh graph IDs isolate parsing; no tool is executed, and the original
    # source envelope is restored on the resulting IR entry below.
    batch = []
    previous = None
    for item in selected:
        for row, content in ((item['callRow'], item['rawCall']), (item['row'], item['rawBlock'])):
            projected = copy.deepcopy(row)
            projected['uuid'] = str(uuid.uuid4())
            projected['parentUuid'] = previous
            projected['isSidechain'] = False
            projected['message']['content'] = [content]
            previous = projected['uuid']
            batch.append(projected)
    batch_path = directory / 'recovery-source.jsonl'
    batch_path.write_text(''.join(canonical(row) + '\n' for row in batch))
    archive = directory / 'recovery.loom.json'
    run([core, 'convert', batch_path, 'loom', archive, '--no-subagents'])
    parsed = json.loads(archive.read_text())
    recovered = {}
    for entry in parsed['entries']:
        for block in entry['payload'].get('blocks', []):
            if block['type'] != 'toolResult':
                continue
            ref = block['call']
            call = parsed['entries'][int(ref['entry'])]['payload']['blocks'][int(ref['block'])]
            recovered[call['id']] = (entry, block)
    insertions = {}
    evidence = []
    for item in selected:
        if item['callId'] not in recovered:
            raise ValueError('Claude parser did not recover an authenticated result')
        parsed_entry, parsed_block = recovered[item['callId']]
        entry = copy.deepcopy(parsed_entry)
        entry['payload'] = {'type': 'envMsg', 'blocks': [copy.deepcopy(parsed_block)]}
        if item['sourceUuid'] is not None:
            entry['origin']['rawId'] = item['sourceUuid']
        else:
            entry['origin'].pop('rawId', None)
        entry['origin']['sourceRef'] = f"recovered-source-line:{item['sourceLine']}"
        entry['origin'].setdefault('extras', {})['claudeRawEnvelope'] = item['row']
        entry['payload']['blocks'][0]['call'] = {'kind': 'resolved', 'entry': str(item['entry']), 'block': str(item['block'])}
        insertions.setdefault(item['after'], []).append((item['sourceLine'], entry))
        evidence.append({'callId': item['callId'], 'sourceLine': item['sourceLine'],
                         'sourceUuid': item['sourceUuid'],
                         'sourceResultSha256': hashlib.sha256(canonical(item['rawBlock']).encode()).hexdigest()})
    output = copy.deepcopy(transcript)
    new_entries = []
    remap = {}
    for index, entry in enumerate(output['entries']):
        remap[index] = len(new_entries)
        new_entries.append(entry)
        new_entries.extend(entry for _, entry in sorted(insertions.get(index, []), key=lambda pair: pair[0]))
    for index, entry in enumerate(new_entries):
        entry['index'] = str(index)
        entry['parent'] = str(index - 1) if index else None
        # Wire v0 encodes absent parents by omission.
        if not index:
            entry.pop('parent', None)
        for block in entry['payload'].get('blocks', []):
            if block['type'] == 'toolResult' and block['call']['kind'] == 'resolved':
                block['call']['entry'] = str(remap[int(block['call']['entry'])])
        if entry['payload']['type'] == 'compaction':
            coverage = entry['payload']['coverage']
            if coverage['kind'] == 'knownPrefix':
                coverage['firstKept'] = str(remap[int(coverage['firstKept'])])
    output['entries'] = new_entries
    output['activeLeaf'] = str(len(new_entries) - 1)
    output['origin'].setdefault('extras', {})['_agent_convert_recovered_results'] = evidence
    return output, evidence


def attach(rows, evidence):
    by_call = {item['callId']: item for item in evidence}
    seen = set()
    for row in rows:
        payload = row.get('payload', {})
        if payload.get('type') not in ('function_call_output', 'custom_tool_call_output'):
            continue
        call_id = row.get('_agent_convert_call_id', {}).get('source') or payload.get('call_id')
        if call_id in by_call:
            row['_agent_convert_recovered_result'] = by_call[call_id]
            seen.add(call_id)
    if seen != set(by_call):
        raise ValueError('Recovered source results did not all become native Codex history')
