"""Discover local Antigravity conversations and hand them off to native clients."""

from contextlib import closing
from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
from urllib.parse import unquote, urlsplit
import uuid


STORES = {'desktop': 'antigravity', 'cli': 'antigravity-cli'}
SEARCH_STORES = {f'antigravity-{surface}': surface for surface in STORES}
GENERATED = Path('.system_generated')
DIALOGUE_TYPES = {'USER_INPUT': 'user', 'PLANNER_RESPONSE': 'assistant'}


def data_root():
    return Path.home() / '.gemini'


def thread_id(value):
    try:
        canonical = str(uuid.UUID(value))
    except (ValueError, AttributeError, TypeError):
        return None
    return canonical if canonical == value.lower() else None


def local_workspaces(value):
    uris = value
    if isinstance(value, str):
        try:
            uris = json.loads(value or '[]')
        except ValueError:
            return []
    if not isinstance(uris, list):
        return []
    paths = []
    for uri in uris:
        if not isinstance(uri, str):
            continue
        try:
            parsed = urlsplit(uri)
        except ValueError:
            continue
        if parsed.scheme == 'file' and parsed.netloc in ('', 'localhost') and parsed.path.startswith('/'):
            path = unquote(parsed.path, errors='replace')
            if '\x00' not in path and path not in paths:
                paths.append(path)
    return paths


@dataclass
class Thread:
    id: str
    surface: str
    title: str = ''
    preview: str = ''
    updated: str = ''
    modified: float = 0
    status: str = ''
    workspaces: list = field(default_factory=list)
    transcript: Path = None
    conversation: Path = None
    parent_id: str = None
    agent_label: str = ''
    agent_type: str = ''

    def agent_info(self):
        return {'id': self.id, 'parentId': self.parent_id,
                'agentLabel': self.agent_label or None, 'agentType': self.agent_type or None}

    def info(self):
        return {**self.agent_info(), 'surface': self.surface, 'title': self.title,
                'preview': self.preview, 'updated': self.updated or None,
                'status': self.status or None, 'workspaces': self.workspaces,
                'transcript': str(self.transcript) if self.transcript else None,
                'conversationFile': str(self.conversation) if self.conversation else None}


def warn(message):
    print(f'agent-convert: {message}', file=sys.stderr)


def query_summaries(path, *, private_copy=False):
    mode = 'rw' if private_copy else 'ro'
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=' + mode, uri=True, timeout=1)) as db:
        columns = {r[1] for r in db.execute('PRAGMA table_info(conversation_summaries)')}
        if 'conversation_id' not in columns:
            raise ValueError('missing conversation_summaries table')
        optional = ('title', 'preview', 'last_modified_time', 'workspace_uris', 'status', 'source', 'app_data_dir',
                    'parent_conversation_id', 'agent_name')
        fields = ', '.join(key if key in columns else "''" for key in optional)
        return db.execute('SELECT conversation_id, ' + fields + ' FROM conversation_summaries').fetchall()


def file_version(path):
    try:
        st = path.stat()
        return st.st_ino, st.st_size, st.st_mtime_ns
    except FileNotFoundError:
        return None


def read_summaries(path):
    if not path.is_file():
        return []
    try:
        try:
            return query_summaries(path)
        except sqlite3.OperationalError:
            # SQLite may need to create a WAL index even for a read-only open.
            # Copy the database and any WAL as one stable snapshot in that case.
            wal = path.with_name(path.name + '-wal')
            files = (path, wal)
            with TemporaryDirectory(prefix='agent-convert-agy-') as directory:
                before = [file_version(p) for p in files]
                for original, version in zip(files, before):
                    if version is not None:
                        shutil.copyfile(original, Path(directory) / original.name)
                if before != [file_version(p) for p in files]:
                    raise ValueError('catalog changed while being copied; retry')
                # A WAL-mode database may have just checkpointed and removed
                # both sidecars. SQLite can recreate them in the private copy.
                return query_summaries(Path(directory) / path.name, private_copy=True)
    except (OSError, sqlite3.Error, ValueError) as exc:
        warn(f'Cannot read Antigravity catalog {path}: {exc}')
        return []


def read_last_workspaces(path):
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(value, dict):
            raise ValueError('expected a workspace-to-conversation map')
        return value
    except (OSError, ValueError) as exc:
        warn(f'Cannot read Antigravity workspace cache {path}: {exc}')
        return {}


def read_subagents(base):
    for path in (base / 'brain').glob(f'*/{GENERATED}/subagents/*.json'):
        parent = thread_id(path.parents[2].name)
        ident = thread_id(path.stem)
        if not parent or not ident or parent == ident:
            continue
        try:
            record = json.loads(path.read_text(encoding='utf-8'))
        except FileNotFoundError:
            continue
        except (OSError, ValueError) as exc:
            warn(f'Cannot read Antigravity subagent {path}: {exc}')
            continue
        if not isinstance(record, dict) or thread_id(record.get('conversationId')) != ident:
            continue
        descriptor = record.get('subagentDescriptor')
        label = descriptor.get('role') if isinstance(descriptor, dict) else None
        kind = descriptor.get('typeName') if isinstance(descriptor, dict) else None
        yield parent, ident, label if isinstance(label, str) else '', kind if isinstance(kind, str) else '', record


def catalog(root):
    threads = {}
    for surface, store in STORES.items():
        base = root / store
        for path in (base / 'conversations').glob('*'):
            ident = thread_id(path.stem)
            if not ident or path.suffix not in ('.db', '.pb') or not path.is_file():
                continue
            thread = threads.setdefault((surface, ident), Thread(ident, surface))
            if thread.conversation is None or path.suffix == '.db':
                thread.conversation = path
                thread.modified = path.stat().st_mtime
        for logs in (base / 'brain').glob(f'*/{GENERATED}/logs'):
            ident = thread_id(logs.parent.parent.name)
            if not ident:
                continue
            # The full log retains fields that the documented short log can truncate.
            for name in ('transcript_full.jsonl', 'transcript.jsonl'):
                path = logs / name
                if path.is_file() and path.stat().st_size:
                    thread = threads.setdefault((surface, ident), Thread(ident, surface))
                    thread.transcript = path
                    thread.modified = max(thread.modified, path.stat().st_mtime)
                    break

    for catalog_surface, store in STORES.items():
        base = root / store
        for ident, title, preview, updated, workspaces, status, source, data_dir, parent, agent in read_summaries(
                base / 'conversation_summaries.db'):
            ident = thread_id(ident)
            if ident is None:
                continue
            surface = catalog_surface
            app_store = Path(data_dir).name if data_dir else ''
            if source == 'CORTEX_TRAJECTORY_SOURCE_CLI' or app_store == STORES['cli']:
                surface = 'cli'
            elif app_store == STORES['desktop']:
                surface = 'desktop'
            elif app_store == 'antigravity-ide':
                continue
            thread = threads.setdefault((surface, ident), Thread(ident, surface))
            thread.title = title or thread.title
            thread.preview = preview or thread.preview
            thread.updated = updated or thread.updated
            thread.status = status or thread.status
            thread.workspaces = local_workspaces(workspaces) or thread.workspaces
            thread.parent_id = thread_id(parent) or thread.parent_id
            thread.agent_type = agent or thread.agent_type

    for surface, store in STORES.items():
        for parent, ident, label, kind, record in read_subagents(root / store):
            thread = threads.setdefault((surface, ident), Thread(ident, surface))
            thread.parent_id = parent
            thread.agent_label = label or thread.agent_label
            thread.agent_type = kind or thread.agent_type
            thread.workspaces = thread.workspaces or local_workspaces(record.get('workspaceUris'))

    fallback = {}
    for workspace, value in sorted(read_last_workspaces(root / STORES['cli'] / 'cache/last_conversations.json').items()):
        ident = thread_id(value)
        if ident and Path(workspace).is_absolute():
            fallback.setdefault(ident, []).append(workspace)
    for ident, paths in fallback.items():
        thread = threads.get(('cli', ident))
        if thread and not thread.workspaces:
            thread.workspaces = paths
    return sorted(threads.values(), key=lambda t: (timestamp(t), t.surface, t.id), reverse=True)


def timestamp(thread):
    if thread.updated:
        try:
            dt = datetime.fromisoformat(thread.updated.replace('Z', '+00:00'))
            return (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).timestamp()
        except ValueError:
            pass
    return thread.modified


def resolve(threads, reference, surface):
    ident = thread_id(reference)
    if ident is None:
        raise ValueError('Enter the full conversation UUID returned by antigravity list or find')
    matches = [t for t in threads if t.id == ident and surface in (None, t.surface)]
    if not matches:
        raise ValueError(f'No local Antigravity conversation matches {reference}')
    if len(matches) != 1:
        raise ValueError(f'Conversation {reference} exists on both surfaces. Pass --surface cli or --surface desktop')
    return matches[0]


def captured_log(thread):
    path = thread.transcript
    if path is None:
        raise ValueError(f'{thread.surface} conversation {thread.id} has no local JSONL transcript')
    # Atomic replacements keep the old inode readable. Bound the read to the
    # opened file's size so concurrent appenders cannot extend the export.
    with path.open('rb') as stream:
        data = stream.read(os.fstat(stream.fileno()).st_size)
    if not data:
        raise ValueError(f'Antigravity transcript is empty: {path}')
    if not data.endswith(b'\n'):
        try:
            json.loads(data.rsplit(b'\n', 1)[-1])
        except ValueError:
            raise ValueError(f'Antigravity transcript has a partial last record: {path}. Retry after the write finishes') from None
    return data


def dialogue(thread):
    for number, line in enumerate(captured_log(thread).split(b'\n'), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError('expected object')
        except ValueError:
            raise ValueError(f'Invalid JSON object in {thread.transcript} at line {number}') from None
        kind = row.get('type')
        role = DIALOGUE_TYPES.get(kind) if isinstance(kind, str) else None
        content = row.get('content')
        if role and isinstance(content, str) and content:
            yield {'role': role, 'index': row.get('step_index', number - 1),
                   'timestamp': row.get('created_at'), 'text': content}


def matching_text(thread, words):
    metadata = (('title', thread.title), ('agent', thread.agent_label), ('agent', thread.agent_type),
                ('preview', thread.preview), ('id', thread.id))
    for role, value in metadata:
        if all(word in value.casefold() for word in words):
            return role, None, value
    if thread.transcript:
        try:
            for row in dialogue(thread):
                if all(word in row['text'].casefold() for word in words):
                    return row['role'], row['index'], row['text']
        except (OSError, ValueError) as exc:
            warn(str(exc))
    return None


def find(root, query, store, cwd, limit):
    words = query.casefold().split()
    if not words:
        raise ValueError('Search query is empty')
    hits = []
    for thread in catalog(root):
        if len(hits) >= limit:
            break
        if store and SEARCH_STORES.get(store) != thread.surface:
            continue
        if cwd and not any(cwd in workspace for workspace in thread.workspaces):
            continue
        match = matching_text(thread, words)
        if match:
            role, index, value = match
            info = thread.info()
            hits.append({**info, 'store': f'antigravity-{thread.surface}', 'role': role, 'index': index,
                         'file': info['transcript'] or info['conversationFile'],
                         'snippet': ' '.join(value.split())[:400]})
    return hits


def lineage(thread, threads):
    by_id = {t.id: t for t in threads if t.surface == thread.surface}
    chain = [thread]
    seen = {thread.id}
    while chain[-1].parent_id:
        parent = chain[-1].parent_id
        if parent in seen:
            raise ValueError(f'Antigravity catalog has a parent cycle at {parent}')
        if parent not in by_id:
            raise ValueError(f'Parent conversation {parent} for {thread.id} is missing from the local catalog')
        chain.append(by_id[parent])
        seen.add(parent)
    return chain[-1], [item.agent_info() for item in reversed(chain[:-1])]


def handoff(thread, threads, cwd=None, prompt=None):
    root, subagents = lineage(thread, threads)
    target = {'surface': thread.surface, 'id': thread.id, 'rootId': root.id, 'subagents': subagents}
    if thread.surface == 'desktop':
        if cwd is not None:
            raise ValueError('--cwd is available for CLI conversations')
        if prompt is not None:
            raise ValueError('Open the desktop conversation through its picker and send the prompt there')
        # Use the title (or a prompt excerpt) because desktop full-text search
        # searches dialogue and titles; search by UUID is not a documented filter.
        title = root.title.strip()
        query = title or ' '.join(root.preview.split())[:120]
        if not query and root.transcript:
            query = next((' '.join(row['text'].split())[:120] for row in dialogue(root)
                          if row['role'] == 'user' and row['text'].strip()), '')
        return {**target, 'title': root.title, 'searchText': query, 'preview': root.preview,
                'updated': root.updated or None, 'workspacePaths': root.workspaces,
                'pickerShortcut': 'Cmd+K' if sys.platform == 'darwin' else 'Ctrl+K'}
    command = ['agy', '--conversation', root.id]
    if prompt is not None:
        if subagents:
            raise ValueError('Open the parent CLI conversation and address the subagent from its /agents panel')
        # Use one argv value so a prompt that starts with a flag stays a prompt.
        command.append('--print=' + prompt)
    workspace = str(Path(cwd).expanduser().resolve()) if cwd is not None else next(iter(root.workspaces), None)
    if workspace and not Path(workspace).is_dir():
        raise ValueError(f'Workspace is unavailable: {workspace}. Pass --cwd with an accessible directory')
    shell = shlex.join(command)
    if workspace:
        shell = f'cd {shlex.quote(workspace)} && {shell}'
    return {**target, 'argv': command, 'cwd': workspace, 'command': shell}


def add_commands(parent):
    parent.add_argument('--data-dir', type=Path, default=data_root(),
                        help='Directory containing the Antigravity stores (default: ~/.gemini)')
    actions = parent.add_subparsers(dest='action', required=True)
    listing = actions.add_parser('list', help='List recent CLI and desktop conversations')
    listing.add_argument('--limit', type=int, default=20)
    listing.add_argument('--cwd', help='Filter by a recorded workspace path substring')
    show = actions.add_parser('show', help='Inspect a conversation and optionally its last dialogue entries')
    show.add_argument('--tail', type=int, default=0, metavar='N')
    transcript = actions.add_parser('transcript', help='Write the recorded JSONL log to stdout')
    resume = actions.add_parser('resume', help='Print native CLI resume or desktop picker instructions')
    resume.add_argument('--cwd', help='Override the workspace for a CLI conversation')
    resume.add_argument('--launch', action='store_true', help='Start agy or open the macOS desktop app')
    send = actions.add_parser('send', help='Send one prompt to a CLI conversation and wait for the response')
    prompts = send.add_mutually_exclusive_group(required=True)
    prompts.add_argument('--prompt')
    prompts.add_argument('--prompt-file', type=Path)
    send.add_argument('--cwd', help='Override the workspace for a CLI conversation')
    for action in (listing, show, transcript, resume, send):
        action.add_argument('--surface', choices=STORES)
    for action in (listing, show, resume):
        action.add_argument('--json', action='store_true')
    for action in (show, transcript, resume, send):
        action.add_argument('id', help='Full conversation UUID')


def run_cli(threads, root, plan):
    if root != data_root().resolve():
        raise ValueError('Launching agy requires the default Antigravity data directory')
    thread = resolve(threads, plan['rootId'], 'cli')
    if thread.conversation is None or not thread.conversation.is_file():
        raise ValueError(f'CLI conversation {thread.id} has no local conversation file to resume')
    return subprocess.call(plan['argv'], cwd=plan['cwd'])


def run(args):
    root = args.data_dir.expanduser().resolve()
    if args.action == 'list':
        if args.limit < 1:
            raise ValueError('--limit must be positive')
        threads = [t for t in catalog(root) if args.surface in (None, t.surface) and
                   (not args.cwd or any(args.cwd in path for path in t.workspaces))][:args.limit]
        if args.json:
            print(json.dumps([t.info() for t in threads], ensure_ascii=False))
        else:
            for thread in threads:
                description = ' '.join((thread.title or thread.agent_label or thread.preview).split())[:160]
                print(f'{thread.id}  {thread.surface:<7}  {description}')
        return 0

    threads = catalog(root)
    thread = resolve(threads, args.id, args.surface)
    if args.action == 'show':
        if args.tail < 0:
            raise ValueError('--tail must be nonnegative')
        info = thread.info()
        if args.tail:
            info['dialogue'] = list(dialogue(thread))[-args.tail:]
        print(json.dumps(info, ensure_ascii=False, indent=None if args.json else 2))
    elif args.action == 'transcript':
        sys.stdout.buffer.write(captured_log(thread))
    elif args.action == 'send':
        prompt = args.prompt if args.prompt_file is None else args.prompt_file.read_text(encoding='utf-8')
        if not prompt.strip():
            raise ValueError('Prompt is empty')
        plan = handoff(thread, threads, args.cwd, prompt=prompt)
        return run_cli(threads, root, plan)
    else:
        plan = handoff(thread, threads, args.cwd)
        cli_subagent = ('Open /agents and select subagent ' + thread.id
                        + (f' ({thread.agent_label})' if thread.agent_label else ''))
        if args.launch:
            if thread.surface == 'cli':
                if args.json:
                    raise ValueError('--json cannot be combined with an interactive CLI launch')
                if plan['subagents']:
                    print(cli_subagent, file=sys.stderr)
                return run_cli(threads, root, plan)
            if sys.platform != 'darwin':
                raise ValueError('Desktop launch is available on macOS. Open the app and use the conversation picker')
            subprocess.run(['open', '-a', 'Antigravity'], check=True)
        if args.json:
            print(json.dumps(plan, ensure_ascii=False))
        elif thread.surface == 'cli':
            print(plan['command'])
            if plan['subagents']:
                print(cli_subagent)
        else:
            print(f"In Antigravity, open the conversation picker with {plan['pickerShortcut']}.")
            if plan['searchText']:
                print('Search for ' + json.dumps(plan['searchText'], ensure_ascii=False))
            print(f"Select conversation {plan['rootId']} after checking the title and workspace.")
            for item in plan['subagents']:
                label = f" ({item['agentLabel']})" if item['agentLabel'] else ''
                print(f"Open Overview → Subagents and select {item['id']}{label}.")
    return 0
