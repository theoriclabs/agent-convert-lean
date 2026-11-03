"""Native Codex loading, offline request validation, and session naming."""
import collections
import copy
import hashlib
import http.server
import json
import os
import selectors
import shutil
import subprocess
import threading
import time
from pathlib import Path


class Rpc:
    def __init__(self, executable, home, directory):
        env = os.environ.copy()
        env['CODEX_HOME'] = str(home)
        self.log = (directory / 'app-server.stderr.log').open('wb')
        self.child = subprocess.Popen([executable, 'app-server', '--stdio'], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=self.log, env=env, cwd=directory)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.child.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.sequence = 0

    def send(self, message):
        self.child.stdin.write((json.dumps(message) + '\n').encode())
        self.child.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        number = self.sequence
        self.send({'id': number, 'method': method, 'params': params})
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                if not line.strip():
                    continue
                value = json.loads(line)
                if value.get('id') == number:
                    if 'error' in value:
                        raise ValueError(f"Codex {method}: {value['error'].get('message', value['error'])}")
                    return value['result']
            for key, _ in self.selector.select(1):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    raise ValueError('Codex app-server exited before responding')
                self.buffer += data
        raise ValueError(f'Codex {method} timed out; see {self.log.name}')

    def __enter__(self):
        self.request('initialize', {'clientInfo': {'name': 'agent-convert', 'version': '0.1.0'},
                                    'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized', 'params': {}})
        return self

    def __exit__(self, *args):
        self.child.terminate()
        try:
            self.child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait()
        self.selector.close()
        self.log.close()


def history(rows):
    calls, results = [], []
    for row in rows:
        payload = row.get('payload', {})
        if payload.get('type') in ('function_call', 'custom_tool_call'):
            calls.append(payload)
        elif payload.get('type') in ('function_call_output', 'custom_tool_call_output'):
            results.append(payload)
    call_ids = [p['call_id'] for p in calls]
    result_ids = [p['call_id'] for p in results]
    if len(set(call_ids)) != len(call_ids) or len(set(result_ids)) != len(result_ids):
        raise ValueError('Duplicate native tool-call or result IDs in converted history')
    if set(call_ids) != set(result_ids):
        raise ValueError('Unpaired native call/result history in converted output')
    return calls, results


def validate(rows, directory, executable, model=None, model_cache=None, context_window=None):
    """Ask the actual Codex runtime to load and serialize a temporary copy.

    The only provider is a loopback test server. No real model is called and
    the fixed reply cannot request tools. Existing source tools are never run.
    """
    if not shutil.which(executable):
        raise ValueError('Codex is required for native validation; install Codex or use --validation artifact for a file-only export')
    header = next(row['payload'] for row in rows if row['type'] == 'session_meta')
    model = model or next((row['payload'].get('model') for row in reversed(rows)
                           if row['type'] == 'turn_context' and row['payload'].get('model')), None)
    if not model:
        raise ValueError('Converted history has no target model for native validation')
    session_id = header['id']
    home = directory / 'codex-validation-home'
    relative = Path('sessions/2000/01/01') / f'rollout-2000-01-01T00-00-00-{session_id}.jsonl'
    path = home / relative
    path.parent.mkdir(parents=True)
    if model_cache and model_cache.exists():
        shutil.copy2(model_cache, home / 'models_cache.json')
    path.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows))
    with Rpc(executable, home, directory) as rpc:
        loaded = rpc.request('thread/read', {'threadId': session_id, 'includeTurns': True})
    if (loaded['thread']['id'] != session_id or
            Path(loaded['thread']['cwd']).resolve() != Path(header['cwd']).resolve()):
        raise ValueError('Codex loaded a different session identity or working directory')
    # Use a new home so provider state from thread/read cannot conflict with the
    # test-only provider. The deliverable retains its real model/provider.
    test_home = directory / 'codex-request-home'
    test_path = test_home / relative
    test_path.parent.mkdir(parents=True)
    if model_cache and model_cache.exists():
        shutil.copy2(model_cache, test_home / 'models_cache.json')
    test_rows = copy.deepcopy(rows)
    for row in test_rows:
        if row['type'] == 'session_meta':
            row['payload']['model_provider'] = 'loom_local'
    test_path.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in test_rows))
    captured = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if self.path.rstrip('/') != '/v1/responses':
                self.send_error(400, 'Validation requires context compaction or an unsupported request')
                return
            captured.append(body)
            item = {'id': 'msg_agent_convert_check', 'type': 'message', 'role': 'assistant',
                    'status': 'completed', 'content': [{'type': 'output_text', 'text': 'LOAD-OK', 'annotations': []}]}
            response = {'id': 'resp_agent_convert_check', 'object': 'response', 'created_at': 0,
                        'status': 'completed', 'model': header.get('model', 'conversion-check'), 'output': [item],
                        'usage': {'input_tokens': 100, 'output_tokens': 3, 'total_tokens': 103}}
            events = [('response.created', {'type': 'response.created', 'response': {
                **response, 'status': 'in_progress', 'output': []}}),
                ('response.output_item.added', {'type': 'response.output_item.added', 'output_index': 0,
                 'item': {**item, 'status': 'in_progress', 'content': []}}),
                ('response.output_text.delta', {'type': 'response.output_text.delta', 'item_id': item['id'],
                 'output_index': 0, 'content_index': 0, 'delta': 'LOAD-OK'}),
                ('response.output_item.done', {'type': 'response.output_item.done', 'output_index': 0, 'item': item}),
                ('response.completed', {'type': 'response.completed', 'response': response})]
            payload = ''.join(f'event: {event}\ndata: {json.dumps(data)}\n\n' for event, data in events).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    try:
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    except OSError as error:
        raise ValueError(f'Local Codex validation needs permission to bind localhost: {error}') from error
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    env = os.environ.copy()
    env['CODEX_HOME'] = str(test_home)
    for key in ('OPENAI_API_KEY', 'OPENAI_BASE_URL', 'CODEX_API_KEY', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
                'http_proxy', 'https_proxy', 'all_proxy'):
        env.pop(key, None)
    env['NO_PROXY'] = '127.0.0.1,localhost'
    provider = ('model_providers.loom_local={name="Agent Convert local validation",'
                f'base_url="http://127.0.0.1:{server.server_port}/v1",wire_api="responses",'
                'requires_openai_auth=false,supports_websockets=false,request_max_retries=0,stream_max_retries=0}')
    command = [executable, 'exec', '--sandbox', 'read-only', '-c', 'approval_policy="never"', '-c',
               'model_provider="loom_local"', '-c', provider, '-c', 'model=' + json.dumps(model),
               'resume', '--skip-git-repo-check', '--json', session_id,
               'Conversion validation only: reply LOAD-OK without calling tools.']
    if context_window:
        command[2:2] = ['-c', 'model_context_window=' + str(int(context_window))]
    try:
        result = subprocess.run(command, cwd=directory, env=env, capture_output=True, text=True, timeout=60)
        (directory / 'codex-request.stderr.log').write_text(result.stderr)
        if result.returncode:
            raise ValueError(f'Codex request validation failed: {result.stderr[-1800:].strip()}')
        if len(captured) != 1:
            raise ValueError(f'Expected one local validation request; received {len(captured)}')
        (directory / 'native-request.json').write_text(json.dumps(captured[0], ensure_ascii=False))
        actual = captured[0]['input']
        actual_calls = [p for p in actual if p.get('type') in ('function_call', 'custom_tool_call')]
        actual_results = [p for p in actual if p.get('type') in ('function_call_output', 'custom_tool_call_output')]
        calls, results = history(rows)
        for expected, received, label in ((calls, actual_calls, 'calls'), (results, actual_results, 'results')):
            if len(expected) != len(received):
                raise ValueError(f'Codex omitted native {label}: expected {len(expected)}, received {len(received)}')
            for before, after in zip(expected, received):
                for key in ('type', 'call_id', 'name', 'arguments', 'input', 'output'):
                    if key in before and before[key] != after.get(key):
                        raise ValueError(f'Codex changed native {label} field {key}')
        # Framework instructions may be inserted, but native conversation
        # messages (including labeled peer context and user images) must remain.
        def message_signature(item):
            content = []
            for part in item.get('content', []):
                if 'text' in part:
                    if part['text']:
                        content.append(('text', part['text']))
                elif part.get('type') == 'input_image':
                    content.append(('image', part.get('image_url') or part.get('file_id')))
            return item.get('role'), content
        expected_messages = [message_signature(row['payload']) for row in rows
                             if row.get('payload', {}).get('type') == 'message' and
                             row['payload'].get('content')]
        actual_messages = [message_signature(item) for item in actual if item.get('role')]
        cursor = 0
        for signature in expected_messages:
            if not signature[1]:
                continue
            while cursor < len(actual_messages) and actual_messages[cursor] != signature:
                cursor += 1
            if cursor == len(actual_messages):
                raise ValueError('Codex omitted or changed a native conversation message')
            cursor += 1
        for line in result.stdout.splitlines():
            event = json.loads(line)
            item = event.get('item', {})
            if item.get('type') in ('command_execution', 'mcp_tool_call', 'web_search', 'dynamic_tool_call'):
                raise ValueError('Validation unexpectedly requested a tool')
        images = sum(1 for p in actual_results if isinstance(p.get('output'), list)
                     for item in p['output'] if item.get('type') == 'input_image')
        return {'nativeLoad': True, 'nativeRequestSerialization': True, 'nativeCalls': len(calls),
                'nativeResults': len(results), 'nativeImages': images, 'nativeMessages': len(expected_messages), 'liveModelRecall': False,
                'historicalToolsRerun': 0, 'externalModelRequests': 0}
    finally:
        server.shutdown()
        server.server_close()


def name_session(executable, home, session_id, name, directory):
    with Rpc(executable, home, directory) as rpc:
        rpc.request('thread/name/set', {'threadId': session_id, 'name': name})
        loaded = rpc.request('thread/read', {'threadId': session_id, 'includeTurns': False})
        if loaded['thread']['id'] != session_id:
            raise ValueError('Codex did not register the installed session')
