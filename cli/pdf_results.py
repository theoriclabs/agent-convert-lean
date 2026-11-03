"""Project recorded PDF tool results into Codex text/image output, without rerunning tools."""
import base64
import copy
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def project(transcript, directory):
    """Return a fresh IR plus a ledger; original source blocks remain in the ledger."""
    prepared = copy.deepcopy(transcript)
    ledger = []
    for entry_index, entry in enumerate(prepared['entries']):
        payload = entry['payload']
        if payload['type'] != 'envMsg':
            continue
        for block_index, block in enumerate(payload['blocks']):
            if block['type'] != 'toolResult':
                continue
            for content_index, content in enumerate(block['content']):
                if content.get('type') != 'unmodeled' or content.get('label') != 'document':
                    continue
                raw = content.get('raw', {})
                source = raw.get('source', {})
                if source.get('type') != 'base64' or source.get('media_type') != 'application/pdf':
                    continue
                for program in ('pdftotext', 'pdftoppm'):
                    if not shutil.which(program):
                        raise ValueError(f'{program} is required for recorded PDF results; install Poppler (brew install poppler)')
                ref = block['call']
                if ref.get('kind') != 'resolved':
                    raise ValueError('Cannot attribute a PDF result to an unresolved source call')
                call = prepared['entries'][int(ref['entry'])]['payload']['blocks'][int(ref['block'])]
                call_id = call.get('id')
                if not call_id:
                    raise ValueError('PDF result has no recorded source call ID')
                data = base64.b64decode(source['data'], validate=True)
                if not data.startswith(b'%PDF-'):
                    raise ValueError('Recorded PDF bytes have no PDF header')
                directory.mkdir(parents=True, exist_ok=True)
                prefix = f'{len(ledger) + 1:03d}-{sha256(data)[:12]}'
                pdf = directory / (prefix + '.pdf')
                pdf.write_bytes(data)
                text_file = directory / (prefix + '.txt')
                extraction = subprocess.run(['pdftotext', '-layout', str(pdf), str(text_file)],
                                            capture_output=True, text=True, timeout=60)
                if extraction.returncode:
                    raise ValueError(f'Cannot extract recorded PDF: {extraction.stderr.strip()}')
                rendering = subprocess.run(['pdftoppm', '-r', '120', '-png', str(pdf), str(directory / prefix)],
                                          capture_output=True, text=True, timeout=120)
                if rendering.returncode:
                    raise ValueError(f'Cannot render recorded PDF: {rendering.stderr.strip()}')
                pages = sorted(directory.glob(prefix + '-*.png'),
                               key=lambda p: int(p.stem.rsplit('-', 1)[1]))
                if not pages:
                    raise ValueError('Recorded PDF produced no page images')
                text = text_file.read_text()
                label = Path(str(call.get('arguments', {}).get('file_path', 'recorded.pdf'))).name
                replacement = {'type': 'text', 'text': f'[Text extracted from recorded PDF: {label}]\n{text}'}
                block['content'][content_index] = replacement
                ledger.append({'callId': call_id, 'entry': entry_index, 'block': block_index,
                               'contentIndex': content_index, 'originalBlock': content, 'replacementText': replacement['text'],
                               'pdf': str(pdf), 'sha256': sha256(data), 'text': text,
                               'pageFiles': [str(page) for page in pages], 'renderDpi': 120})
    return prepared, ledger


def attach(rows, ledger):
    by_call = {}
    for document in ledger:
        by_call.setdefault(document['callId'], []).append(document)
    attached = set()
    for row in rows:
        payload = row.get('payload', {})
        if payload.get('type') not in ('function_call_output', 'custom_tool_call_output'):
            continue
        output = payload['output']
        # Codex's native output content union uses input_text, including tools.
        if isinstance(output, list):
            for item in output:
                if item.get('type') == 'output_text':
                    item['type'] = 'input_text'
        documents = by_call.get(payload.get('call_id'), [])
        if not documents:
            # Loom may remap wire IDs. Recover the authenticated source ID.
            mapping = row.get('_agent_convert_call_id', {})
            documents = by_call.get(mapping.get('source'), [])
        if not documents:
            continue
        if isinstance(output, str):
            output = [{'type': 'input_text', 'text': output}]
            payload['output'] = output
        records = []
        inserted = 0
        for document in documents:
            position = document['contentIndex'] + inserted
            if output[position].get('text') != document['replacementText']:
                raise ValueError('PDF projection lost its source content position')
            images = []
            for file in document['pageFiles']:
                data = Path(file).read_bytes()
                images.append({'type': 'input_image', 'image_url': 'data:image/png;base64,' +
                               base64.b64encode(data).decode()})
            output[position + 1:position + 1] = images
            inserted += len(images)
            records.append({'originalBlock': document['originalBlock'], 'sha256': document['sha256'],
                            'renderDpi': document['renderDpi'],
                            'pageSha256': [sha256(Path(p).read_bytes()) for p in document['pageFiles']]})
            attached.add((document['entry'], document['block'], document['contentIndex']))
        row['_agent_convert_pdf_results'] = {'protocol': 'agent-convert.pdf-results.v1', 'documents': records}
    if len(attached) != len(ledger):
        raise ValueError('Some recorded PDF results did not become native tool outputs; refusing publication')


def save_originals(ledger, directory):
    if not ledger:
        return
    directory.mkdir(parents=True, exist_ok=False)
    for document in ledger:
        source = Path(document['pdf'])
        with (directory / source.name).open('xb') as output:
            output.write(source.read_bytes())
