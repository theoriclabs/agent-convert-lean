#!/usr/bin/env python3
"""Session discovery, conversion, checked native publication, and handoff."""
import argparse
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

import codex_native
import claude_results
import pdf_results
import rich_content

VERSION = '0.1.0'
TARGETS = ('claude', 'codex', 'pi', 'cursor-agent', 'opencode', 'loom')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, **kwargs):
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip() or f'Command exited {result.returncode}')
    for line in result.stderr.splitlines():
        if line:
            print(line, file=sys.stderr)
    return result.stdout


def json_document(text):
    for line in reversed(text.splitlines()):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    raise ValueError('Converter returned no JSON result')


def find_core(explicit=None):
    local = Path(__file__).resolve()
    chosen = explicit or os.environ.get('AGENT_CONVERT_CORE')
    if chosen:
        if not Path(chosen).is_file() or not os.access(chosen, os.X_OK):
            raise ValueError(f'Loom core is not executable: {chosen}')
        return Path(chosen).resolve()
    candidates = [
                  local.parent.parent / 'bin' / 'loom', local.parent.parent / '.lake/build/bin/loom',
                  shutil.which('loom')]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return Path(candidate).resolve()
    raise ValueError('Loom core is not installed. Run python3 scripts/install-agent-convert.py --build, or pass --core /path/to/loom')


def settings(path):
    """Read only root scalar settings; no credentials or unrelated configuration."""
    if not path.exists():
        return {}
    try:
        import tomllib
        value = tomllib.loads(path.read_text())
        return {key: value[key] for key in ('model', 'model_provider', 'model_context_window') if key in value}
    except ImportError:
        # Python 3.9 ships on macOS. These three root scalar TOML values need no
        # third-party parser; table/profile settings are deliberately excluded.
        value = {}
        for line in path.read_text().splitlines():
            if line.lstrip().startswith('['):
                break
            match = re.match(r'^\s*(model|model_provider|model_context_window)\s*=\s*(.*)$', line)
            if not match:
                continue
            raw = match[2].strip()
            if raw.startswith("'"):
                parsed = raw.split("'", 2)[1]
            else:
                try:
                    parsed, _ = json.JSONDecoder().raw_decode(raw)
                except ValueError:
                    continue
            value[match[1]] = parsed
        return value


def search(core, query, store=None, cwd=None, limit=20):
    command = [core, 'search', query, '--json', '--limit', str(limit)]
    if store:
        command += ['--store', store]
    if cwd:
        command += ['--cwd', cwd]
    output = run(command)
    return [json.loads(line) for line in output.splitlines() if line.startswith('{')]


def resolve(core, reference):
    candidate = Path(reference).expanduser()
    if candidate.is_file():
        return candidate.resolve()
    if re.fullmatch(r'[0-9a-fA-F-]{36}', reference):
        roots = [(Path.home() / '.claude/projects', f'{reference}.jsonl'),
                 (Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'sessions', f'*{reference}.jsonl'),
                 (Path.home() / '.pi/agent/sessions', f'*{reference}.jsonl')]
        matches = sorted({path.resolve() for root, pattern in roots if root.exists()
                          for path in root.rglob(pattern) if path.is_file()})
    else:
        matches = sorted({Path(hit['file']).resolve() for hit in search(core, reference, limit=200)})
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise ValueError(f'No session matches {reference!r}; provide a transcript path or use agent-convert find')
    raise ValueError('Multiple sessions match; select a path:\n' + '\n'.join(str(path) for path in matches[:20]))


def audit_source_tools(transcript, rows, ledger):
    """Compare every native emitted call and result with the selected source IR."""
    calls, results = codex_native.history(rows)
    source_calls = {}
    source_results = {}
    for entry in transcript['entries']:
        payload = entry['payload']
        if payload['type'] == 'assistantMsg':
            for block in payload['blocks']:
                if block['type'] == 'toolCall' and block.get('id'):
                    source_calls.setdefault(block['id'], []).append(block)
        elif payload['type'] == 'envMsg':
            for block in payload['blocks']:
                if block['type'] == 'toolResult' and block['call']['kind'] == 'resolved':
                    ref = block['call']
                    call = transcript['entries'][int(ref['entry'])]['payload']['blocks'][int(ref['block'])]
                    if call.get('id'):
                        source_results.setdefault(call['id'], []).append(block)
    mappings = {row.get('payload', {}).get('call_id'): row.get('_agent_convert_call_id', {}).get('source')
                for row in rows if row.get('_agent_convert_call_id')}
    projected = {document['callId'] for document in ledger}
    for call in calls:
        source_id = mappings.get(call['call_id']) or call['call_id']
        originals = source_calls.get(source_id, [])
        if len(originals) != 1:
            raise ValueError(f'Native call does not uniquely identify a source call: {source_id}')
        original = originals[0]
        if call.get('name') != original['name'] or json.loads(call['arguments']) != original['arguments']:
            raise ValueError(f'Native call changed source name or arguments: {source_id}')
    for result in results:
        source_id = mappings.get(result['call_id']) or result['call_id']
        originals = source_results.get(source_id, [])
        if len(originals) != 1:
            raise ValueError(f'Native result does not uniquely identify a source result: {source_id}')
        original = originals[0]['content']
        output = result['output']
        actual = [{'type': 'input_text', 'text': output}] if isinstance(output, str) else output
        documents = {d['contentIndex']: d for d in ledger if d['callId'] == source_id}
        expected = []
        for index, block in enumerate(original):
            if index in documents:
                document = documents[index]
                expected.append({'type': 'input_text', 'text': document['replacementText']})
                for page in document['pageFiles']:
                    expected.append({'type': 'input_image', 'image_url': 'data:image/png;base64,' +
                                     __import__('base64').b64encode(Path(page).read_bytes()).decode()})
            elif block['type'] == 'text':
                expected.append({'type': 'input_text', 'text': block['text']})
            elif block['type'] == 'media':
                expected.append(rich_content.image_item(block))
            elif block['type'] == 'unmodeled' and block.get('label') == 'tool_reference':
                expected.append(rich_content.structured_item(block))
            else:
                raise ValueError(f'No exact native projection for source result block: {source_id}')
        if actual != expected:
            raise ValueError(f'Native result changed source content or block order: {source_id}')
    # Literal source prose is allowed; generated tool-carrier prose is not.
    literal = {block['text'] for entry in transcript['entries']
               if entry['payload']['type'] in ('userMsg', 'assistantMsg')
               for block in entry['payload']['blocks'] if block['type'] == 'text'}
    emitted_text = [block.get('text', '') for row in rows if row.get('payload', {}).get('type') == 'message'
                    for block in row['payload'].get('content', [])]
    for text in emitted_text:
        if text.startswith(('[Historical tool call', '[Historical tool result')) and text not in literal:
            raise ValueError('Generated tool-carrier prose appeared in model-facing dialogue')
    for role in ('userMsg', 'assistantMsg'):
        latest = next((entry for entry in reversed(transcript['entries'])
                       if entry['payload']['type'] == role and
                       any(block['type'] == 'text' for block in entry['payload']['blocks'])), None)
        if latest:
            for block in latest['payload']['blocks']:
                if block['type'] == 'text' and block['text'] not in emitted_text:
                    raise ValueError(f'Latest source {role} text was lost')
    return {'sourceArgumentsAndResults': True, 'latestDialogueRetained': True}


def session_title(source):
    custom = None
    title = None
    try:
        for line in source.open():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get('type') == 'custom-title':
                custom = row.get('customTitle') or row.get('title')
            elif row.get('type') == 'ai-title':
                title = row.get('aiTitle') or row.get('title')
    except (OSError, UnicodeError):
        pass
    return custom or title or source.stem


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', action='version', version='agent-convert ' + VERSION)
    parser.add_argument('--core', help='Path to a Loom conversion core')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('version', help='CLI and core identity')
    sub.add_parser('doctor', help='Check installed converter and native tools')
    find = sub.add_parser('find', help='Find sessions by words in their messages')
    find.add_argument('query')
    find.add_argument('--store')
    find.add_argument('--cwd')
    find.add_argument('--limit', type=int, default=20)
    find.add_argument('--json', action='store_true')
    convert = sub.add_parser('convert', help='Convert a session; installs Codex or Claude when output is omitted')
    convert.add_argument('source', help='Session ID, transcript path, or unambiguous search query')
    convert.add_argument('target', choices=TARGETS)
    convert.add_argument('output', nargs='?', type=Path)
    convert.add_argument('--install', action='store_true', help='Install a Codex conversion even with an output path')
    convert.add_argument('--model')
    convert.add_argument('--provider')
    convert.add_argument('--cwd')
    convert.add_argument('--session-id')
    convert.add_argument('--name', help='Name for the installed Codex session')
    convert.add_argument('--codex', default='codex', help='Codex executable for native validation')
    convert.add_argument('--codex-home', type=Path,
                         default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))))
    convert.add_argument('--validation', choices=('native', 'artifact'), default='native',
                         help='Native Codex loading and local request serialization, or artifact checks only')
    convert.add_argument('--with-subagents', action='store_true')
    convert.add_argument('--allow-empty-dialogue', action='store_true')
    convert.add_argument('--json', action='store_true', help='Emit one machine-readable receipt')
    convert.add_argument('--keep-work', action='store_true', help='Retain intermediate conversion files on success')
    return parser.parse_args(argv)


def convert(core, args):
    source = resolve(core, args.source)
    initial_hash = digest(source)
    if args.output and args.output.expanduser().exists():
        raise ValueError(f'Output already exists: {args.output}')
    if args.install and args.target != 'codex':
        raise ValueError('--install currently applies to Codex; omit output to install Claude')
    if args.output is None and args.target not in ('codex', 'claude'):
        raise ValueError(f'{args.target} requires an output path; native installation is supported for Codex and Claude')
    directory = Path(tempfile.mkdtemp(prefix='agent-convert-'))
    successful = False
    try:
        session_id = args.session_id or str(uuid.uuid4())
        options = ['--target-session-id', session_id]
        if args.with_subagents:
            options += ['--with-subagents']
        if args.allow_empty_dialogue:
            options += ['--allow-empty-dialogue']
        for flag, value in (('--target-model', args.model), ('--target-provider', args.provider), ('--target-cwd', args.cwd)):
            if value:
                options += [flag, value]
        if args.target == 'claude' and args.output is None:
            projects = Path(os.environ.get('CLAUDE_PROJECTS', str(Path.home() / '.claude/projects')))
            # The core can replace an explicitly reused ID. This installed CLI
            # publishes fresh sessions and must refuse that before delegating.
            if str(uuid.UUID(session_id)) != session_id.lower():
                raise ValueError('Claude target session ID must be a canonical UUID')
            existing = next(projects.rglob(session_id + '.jsonl'), None) if projects.exists() else None
            if existing is not None:
                raise ValueError(f'Claude session ID already exists: {existing}')
            # The core owns Claude's transactional sidecars, index, and UUID checks.
            output = run([core, 'convert', source, 'claude'] + options + (['--json'] if args.json else []))
            if digest(source) != initial_hash:
                raise ValueError('Source changed during conversion; inspect the reported installed session')
            if args.json:
                summary = json_document(output)
                cwd = summary.get('targetCwd') or summary.get('cwd')
                print(json.dumps({'cliVersion': VERSION, 'source': str(source), 'target': 'claude',
                                  'sessionId': session_id, 'conversion': summary,
                                  'resumeCommand': 'cd ' + shlex.quote(cwd) + ' && ' + shlex.join(['claude', '--resume', session_id])}))
            else:
                print(output, end='')
            successful = True
            return
        detected = json_document(run([core, 'detect', source, '--json']))
        source_format = detected.get('format') or detected.get('detectedFormat')
        configured = settings(args.codex_home / 'config.toml') if args.target == 'codex' else {}
        if args.target == 'codex':
            if not args.model and configured.get('model'):
                options += ['--target-model', configured['model']]
            if not args.provider:
                options += ['--target-provider', configured.get('model_provider', 'openai')]
        transcript = None
        ledger = []
        rich_ledger = []
        recovered_results = []
        conversion_source = source
        if args.target == 'codex' and source_format == 'claude':
            # Only Claude is projected through the archive. Codex continuation
            # sources always go directly through the core's active-context import.
            archive = directory / 'source.loom.json'
            run([core, 'convert', source, 'loom', archive,
                 '--with-subagents' if args.with_subagents else '--no-subagents'])
            transcript = json.loads(archive.read_text())
            transcript, recovered_results = claude_results.recover(core, source, transcript, directory, run)
            prepared, ledger = pdf_results.project(transcript, directory / 'attachments')
            prepared, rich_ledger = rich_content.project(prepared)
            conversion_source = archive
            if ledger or rich_ledger or recovered_results:
                conversion_source = directory / 'prepared.loom.json'
                conversion_source.write_text(json.dumps(prepared, ensure_ascii=False))
        candidate = directory / 'converted.jsonl'
        summary = json_document(run([core, 'convert', conversion_source, args.target, candidate, '--json'] + options))
        receipt = {'cliVersion': VERSION, 'source': str(source), 'sourceSha256': initial_hash,
                   'sourceFormat': source_format, 'target': args.target, 'sessionId': session_id,
                   'core': json_document(run([core, 'version', '--json'])), 'conversion': summary,
                   'recoveredResults': len(recovered_results),
                   'sourceImages': sum(r['kind'] == 'image' for r in rich_ledger),
                   'peerMessages': sum(r['kind'] == 'peer' for r in rich_ledger),
                   'structuredToolReferences': sum(r['kind'] == 'tool_reference' for r in rich_ledger),
                   'pdfDocuments': len(ledger), 'pdfPages': sum(len(d['pageFiles']) for d in ledger),
                   'verification': {'liveModelRecall': False}}
        if args.target == 'codex':
            rows = [json.loads(line) for line in candidate.read_text().splitlines() if line.strip()]
            pdf_results.attach(rows, ledger)
            rich_content.attach(rows, rich_ledger)
            claude_results.attach(rows, recovered_results)
            calls, results = codex_native.history(rows)
            if len(calls) != summary['toolCallsEmittedNative'] or len(results) != summary['toolResultsEmitted']:
                raise ValueError('Native history counts disagree with converter summary')
            if transcript is not None:
                receipt['verification'].update(audit_source_tools(transcript, rows, ledger))
            if args.validation == 'native':
                receipt['verification'].update(codex_native.validate(rows, directory, args.codex, summary.get('targetModel'),
                    args.codex_home / 'models_cache.json', configured.get('model_context_window')))
            else:
                receipt['verification']['nativeLoad'] = False
                receipt['verification']['nativeRequestSerialization'] = False
            candidate.write_text(''.join(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n' for row in rows))
        if digest(source) != initial_hash:
            raise ValueError('Source changed during conversion; retry after the source turn finishes')
        destinations = []
        if args.output:
            destinations.append(args.output.expanduser().resolve())
        install = args.target == 'codex' and (args.install or args.output is None)
        if install:
            now = datetime.datetime.now(datetime.timezone.utc)
            destination = args.codex_home / 'sessions' / now.strftime('%Y/%m/%d') / (
                f"rollout-{now.strftime('%Y-%m-%dT%H-%M-%S')}-{session_id}.jsonl")
            # Different timestamps must not permit a second session with this ID.
            existing = list((args.codex_home / 'sessions').rglob(f'*{session_id}.jsonl'))
            if existing:
                raise ValueError(f'Codex session ID already exists: {existing[0]}')
            destinations.append(destination.resolve())
        for destination in destinations:
            if destination.exists() or destination.is_symlink():
                raise ValueError(f'Destination already exists: {destination}')
            if destination == source:
                raise ValueError('Destination is the source session')
            if Path(str(destination) + '.conversion.json').exists():
                raise ValueError(f'Conversion receipt already exists beside {destination}')
        if install:
            asset_directory = args.codex_home / 'imports' / session_id
        else:
            asset_directory = Path(str(destinations[0]) + '.attachments')
        if asset_directory.exists():
            raise ValueError(f'Attachment/receipt directory already exists: {asset_directory}')
        asset_directory.mkdir(parents=True)
        for document in ledger:
            pdf = Path(document['pdf'])
            with (asset_directory / pdf.name).open('xb') as output:
                output.write(pdf.read_bytes())
        receipt.update({'outputs': [str(p) for p in destinations], 'attachments': str(asset_directory),
                        'outputSha256': digest(candidate), 'sourceUnchanged': True})
        if ledger:
            receipt['adaptations'] = ['Recorded PDF results contain extracted text and page images; original PDF bytes are retained in metadata and attachments.']
        if receipt['recoveredResults']:
            receipt.setdefault('adaptations', []).append('Retained same-session results omitted by the selected Claude parent walk were restored by exact call identity and source order; no tools were rerun.')
        if receipt['structuredToolReferences']:
            receipt.setdefault('adaptations', []).append('Recorded ToolSearch references are preserved as JSON text in native tool results, with original structured blocks in metadata.')
        if receipt['peerMessages']:
            receipt.setdefault('adaptations', []).append('Peer-authored messages remain labeled peer context in native user-role entries; original role and author evidence are retained in metadata.')
        for destination in destinations:
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open('xb') as output:
                output.write(candidate.read_bytes())
            if digest(destination) != receipt['outputSha256']:
                raise ValueError(f'Published artifact checksum mismatch: {destination}')
        if install:
            header = next(row['payload'] for row in rows if row['type'] == 'session_meta')
            cwd = header['cwd']
            name = args.name or session_title(source) + ' (converted)'
            try:
                codex_native.name_session(args.codex, args.codex_home, session_id, name, directory)
                receipt['registeredName'] = name
            except (ValueError, OSError) as error:
                receipt['namingWarning'] = str(error)
                print(f'Installed session; naming failed: {error}', file=sys.stderr)
            command = [args.codex, '-C', cwd, 'resume', session_id]
            # The output carries the requested model; pin it in the handoff too.
            model = args.model or configured.get('model')
            if model:
                command += ['--model', model]
            default_home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))).resolve()
            if args.codex_home.resolve() != default_home:
                command = ['env', 'CODEX_HOME=' + str(args.codex_home.resolve())] + command
            receipt['resumeCommand'] = shlex.join(command)
        elif args.target == 'opencode':
            receipt['nextCommand'] = shlex.join(['opencode', 'import', str(destinations[0])])
        elif args.target == 'pi':
            receipt['nextCommand'] = shlex.join(['pi', '--session', str(destinations[0])])
        for destination in destinations:
            with Path(str(destination) + '.conversion.json').open('x') as output:
                json.dump(receipt, output, indent=2, ensure_ascii=False)
        with (asset_directory / 'conversion-receipt.json').open('x') as output:
            json.dump(receipt, output, indent=2, ensure_ascii=False)
        if args.json:
            print(json.dumps(receipt, ensure_ascii=False))
        else:
            print(f'Converted {source} → {args.target}')
            for destination in destinations:
                print(f'Output: {destination}')
            if args.target == 'codex':
                print(f'Native tool history: {len(calls)} calls, {len(results)} results; PDF attachments: {len(ledger)}')
                print('Validation: ' + ('native loading and local request serialization' if args.validation == 'native' else 'artifact checks only'))
            print(receipt.get('resumeCommand') or receipt.get('nextCommand') or '')
        successful = True
    finally:
        if successful and not args.keep_work:
            shutil.rmtree(directory)
        else:
            print(f'Conversion work retained: {directory}', file=sys.stderr)


def main(argv=None):
    args = parse_args(argv)
    try:
        core = find_core(args.core)
        if args.command == 'version':
            print(json.dumps({'cliVersion': VERSION, 'corePath': str(core), 'core': json_document(run([core, 'version', '--json']))}))
        elif args.command == 'doctor':
            print(json.dumps({'cliVersion': VERSION, 'corePath': str(core),
                              'core': json_document(run([core, 'version', '--json'])),
                              'codex': shutil.which('codex'), 'pdftotext': shutil.which('pdftotext'),
                              'pdftoppm': shutil.which('pdftoppm')}, indent=2))
        elif args.command == 'find':
            hits = search(core, args.query, args.store, args.cwd, args.limit)
            if args.json:
                print(json.dumps(hits, ensure_ascii=False))
            else:
                for hit in hits:
                    print(f"{hit['file']}\n  {hit.get('snippet', '')[:180]}")
        elif args.command == 'convert':
            convert(core, args)
        return 0
    except (ValueError, OSError, KeyError, subprocess.TimeoutExpired) as error:
        print(f'agent-convert: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
