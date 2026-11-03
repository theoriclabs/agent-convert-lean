"""Checked projections for native Codex images and authenticated Claude peer context."""
import copy
import json
import uuid


def image_item(block):
    mime = block.get('mimeType', '')
    locator = block.get('data', '')
    if not (mime == 'image' or mime.startswith('image/')):
        raise ValueError(f'Codex cannot project recorded media type {mime!r}')
    if not locator.startswith(('data:image/', 'https://', 'http://')):
        raise ValueError('Recorded image has no portable bytes or URL; recover it before conversion')
    return {'type': 'input_image', 'image_url': locator}


def structured_item(block):
    raw = block.get('raw', {})
    if not (block.get('label') == 'tool_reference' and isinstance(raw, dict) and
            raw.get('type') == 'tool_reference' and isinstance(raw.get('tool_name'), str)):
        raise ValueError('No checked native projection for structured source tool output')
    return {'type': 'input_text', 'text': json.dumps(raw, ensure_ascii=False, separators=(',', ':'), sort_keys=True)}


def project(transcript):
    prepared = copy.deepcopy(transcript)
    ledger = []
    for entry_index, entry in enumerate(prepared['entries']):
        payload = entry['payload']
        if payload['type'] == 'otherMsg':
            raw = entry['origin'].get('extras', {}).get('claudeRawEnvelope', {})
            origin = raw.get('origin', {})
            if not (payload.get('role') == 'peer' and raw.get('promptSource') == 'system' and
                    raw.get('turnOrigin') == 'peer' and origin.get('kind') == 'peer'):
                raise ValueError(f"Codex has no checked projection for source role {payload.get('role')!r}")
            marker = 'agent-convert-role-' + uuid.uuid4().hex
            ledger.append({'kind': 'peer', 'marker': marker, 'entry': entry_index,
                           'originalPayload': copy.deepcopy(payload), 'originalOrigin': entry['origin']})
            # The importer already labels this text as "Peer message from …".
            # Codex stores peer context as a native user message; source role and
            # author evidence remain metadata rather than fresh user intent.
            payload['type'] = 'userMsg'
            payload.pop('role')
            payload['blocks'].insert(0, {'type': 'text', 'text': marker})
        for block_index, block in enumerate(payload.get('blocks', [])):
            contents = block['content'] if block['type'] == 'toolResult' else [block]
            for content_index, content in enumerate(contents):
                if content['type'] == 'media':
                    kind, item = 'image', image_item(content)
                elif (block['type'] == 'toolResult' and content['type'] == 'unmodeled' and
                      content.get('label') == 'tool_reference'):
                    kind, item = 'tool_reference', structured_item(content)
                else:
                    continue
                marker = 'agent-convert-content-' + uuid.uuid4().hex
                ledger.append({'kind': kind, 'marker': marker, 'entry': entry_index,
                               'block': block_index, 'contentIndex': content_index,
                               'originalBlock': copy.deepcopy(content), 'nativeItem': item})
                replacement = {'type': 'text', 'text': marker}
                if block['type'] == 'toolResult':
                    block['content'][content_index] = replacement
                else:
                    payload['blocks'][block_index] = replacement
    return prepared, ledger


def attach(rows, ledger):
    records = {record['marker']: record for record in ledger}
    seen = set()
    for row in rows:
        payload = row.get('payload', {})
        if payload.get('type') == 'message':
            field = 'content'
        elif payload.get('type') in ('function_call_output', 'custom_tool_call_output'):
            field = 'output'
        else:
            continue
        contents = payload.get(field, [])
        was_string = isinstance(contents, str)
        if was_string:
            contents = [{'type': 'input_text', 'text': contents}]
        projected = []
        for block in contents:
            record = records.get(block.get('text'))
            if record is None:
                projected.append(block)
                continue
            if record['marker'] in seen:
                raise ValueError('A native projection marker was emitted more than once')
            seen.add(record['marker'])
            if record['kind'] in ('image', 'tool_reference'):
                projected.append(record['nativeItem'])
                key = '_agent_convert_media' if record['kind'] == 'image' else '_agent_convert_structured_results'
                row.setdefault(key, []).append({'source': record['originalBlock']})
            else:
                row['_agent_convert_source_role'] = {
                    'protocol': 'agent-convert.source-role.v1', 'role': 'peer',
                    'payload': record['originalPayload'], 'origin': record['originalOrigin'],
                    'targetRole': 'user'}
        if was_string and len(projected) == 1 and projected[0].get('type') == 'input_text':
            payload[field] = projected[0]['text']
        else:
            payload[field] = projected
    if seen != set(records):
        raise ValueError('Some source images or peer context did not reach native Codex history')
