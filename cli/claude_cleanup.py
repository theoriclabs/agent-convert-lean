"""Keep exporter-generated reasoning labels out of native conversation text."""
import copy
import json
import re
import hashlib


def clean(rows):
    rows = copy.deepcopy(rows)
    archived = []
    removed = {}
    for row in rows:
        marker = row.get('_agent_convert', {})
        if marker.get('protocol') != 'agent-convert.claude-carriers.v1':
            continue
        content = row.get('message', {}).get('content')
        if row.get('type') != 'assistant' or not isinstance(content, list):
            continue
        omit = set()
        handled = set()
        for item in marker.get('reasoning', []):
            index = item.get('block')
            if not isinstance(index, int) or not 0 <= index < len(content):
                continue
            source = item.get('source', {})
            kind = source.get('kind', source.get('type'))
            if kind == 'thinking':
                text = source.get('thinking', '')
                expected = '[Prior reasoning]\n' + text if text else '[prior reasoning not retained as readable text]'
            elif kind == 'unmodeled':
                raw = source.get('raw', {})
                if not raw.get('encrypted_content'):
                    continue
                summary = raw.get('summary', [])
                if not all(x.get('type') == 'summary_text' for x in summary):
                    continue
                text = '\n'.join(x.get('text', '') for x in summary)
                expected = '[Prior reasoning]\n' + text if text else '[prior reasoning not retained as readable text: ' + source.get('label', '') + ']'
            else:
                continue
            if content[index] != {'type': 'text', 'text': expected}:
                continue
            handled.add(index)
            if not any(record.get('uuid') == row.get('uuid') for record in archived):
                archived.append(copy.deepcopy(row))
            if text:
                content[index]['text'] = text
            else:
                omit.add(index)
        marker['reasoning'] = [item for item in marker.get('reasoning', []) if item.get('block') not in handled]
        if not omit:
            continue
        kept = [index for index in range(len(content)) if index not in omit]
        mapping = {old: new for new, old in enumerate(kept)}
        row['message']['content'] = [content[index] for index in kept]
        for key, values in list(marker.items()):
            if isinstance(values, list) and all(isinstance(value, dict) for value in values):
                adjusted = []
                for value in values:
                    if 'block' not in value:
                        adjusted.append(value)
                    elif value['block'] in mapping:
                        value['block'] = mapping[value['block']]
                        adjusted.append(value)
                marker[key] = adjusted
        if not kept:
            removed[row['uuid']] = row.get('parentUuid')
    for row in rows:
        marker = row.get('_agent_convert', {})
        if marker.get('protocol') != 'agent-convert.claude-carriers.v1':
            continue
        for block in row.get('message', {}).get('content', []):
            if block.get('type') != 'tool_result' or not isinstance(block.get('content'), list):
                continue
            original = copy.deepcopy(row)
            changed = False
            for item in block['content']:
                if item.get('type') != 'text':
                    continue
                text = item.get('text', '')
                try:
                    value = json.loads(text)
                except ValueError:
                    continue
                if not isinstance(value, dict):
                    continue
                if isinstance(value.get('output'), str) and 'exit_code' in value and 'chunk_id' in value:
                    item['text'] = value['output']
                    changed = True
                elif set(value) == {'name', 'description'} and all(isinstance(v, str) for v in value.values()):
                    item['text'] = value['name'] + '\n\n' + value['description']
                    changed = True
                elif isinstance(value.get('content'), list) and all(
                        piece.get('type') == 'text' and isinstance(piece.get('text'), str)
                        for piece in value['content']):
                    rendered = []
                    for piece in value['content']:
                        try:
                            rendered.append(json.dumps(json.loads(piece['text']), indent=2, ensure_ascii=False))
                        except ValueError:
                            rendered.append(piece['text'])
                    item['text'] = '\n'.join(rendered)
                    changed = True
            if changed and block['content'] and re.fullmatch(
                    r'Script completed\nWall time [^\n]+\nOutput:\n', block['content'][0].get('text', '')):
                block['content'].pop(0)
            if changed and not any(record.get('uuid') == row.get('uuid') for record in archived):
                archived.append(original)
    def ancestor(value):
        seen = set()
        while value in removed:
            if value in seen:
                raise ValueError('Cycle in removed reasoning record links')
            seen.add(value)
            value = removed[value]
        return value
    output = []
    for row in rows:
        if row.get('uuid') in removed:
            continue
        for key in ('parentUuid', 'leafUuid'):
            if key in row:
                row[key] = ancestor(row[key])
        output.append(row)
    return output, archived


def clean_file(path):
    from pathlib import Path
    path = Path(path)
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    cleaned, archived = clean(rows)
    if archived:
        archive = Path(str(path) + '.reasoning-provenance.json')
        previous = json.loads(archive.read_text()).get('records', []) if archive.exists() else []
        with archive.open('w') as stream:
            json.dump({'protocol': 'agent-convert.reasoning-provenance.v1', 'records': previous + archived}, stream)
        path.write_text(''.join(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n' for row in cleaned))
        receipt = Path(str(path) + '.conversion.json')
        if receipt.exists():
            data = json.loads(receipt.read_text())
            data['outputSha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            data['recordsPreservedInCleanupMetadata'] = len(previous) + len(archived)
            receipt.write_text(json.dumps(data, indent=2))
    return len(archived)
