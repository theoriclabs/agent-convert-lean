#!/usr/bin/env python3
"""Exercise Antigravity discovery and handoff with isolated local stores."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'cli'))
import agent_convert
import antigravity


DESKTOP = '00000000-0000-4000-8000-000000000001'
CHILD = '00000000-0000-4000-8000-000000000002'
CLI = '00000000-0000-4000-8000-000000000003'
CLI_CHILD = '00000000-0000-4000-8000-000000000004'


class AntigravityTest(unittest.TestCase):
    def setUp(self):
        scratch = TemporaryDirectory(prefix='agent-convert-antigravity-test-')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.workspace = self.root / "alice's work"
        self.workspace.mkdir()
        self.desktop = self.root / 'antigravity'
        self.cli = self.root / 'antigravity-cli'
        for surface, ident in ((self.desktop, DESKTOP), (self.cli, CLI)):
            conversations = surface / 'conversations'
            conversations.mkdir(parents=True)
            (conversations / f'{ident}.db').touch()
        self.db = self.desktop / 'conversation_summaries.db'
        self.workspaces = [self.workspace.as_uri()]

        # Keep committed rows in the WAL throughout the test. The desktop DB
        # also catalogs CLI conversations on the reviewed Antigravity build.
        self.connection = sqlite3.connect(self.db)
        self.addCleanup(self.connection.close)
        self.connection.execute('PRAGMA journal_mode=WAL')
        self.connection.execute('PRAGMA wal_autocheckpoint=0')
        self.connection.execute('''
          CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT,
            workspace_uris TEXT, parent_conversation_id TEXT, agent_name TEXT, source TEXT
          )''')
        self.connection.executemany('INSERT INTO conversation_summaries VALUES (?, ?, ?, ?, ?, ?, ?)', [
            (DESKTOP, 'Desktop project', 'First prompt', json.dumps(self.workspaces), '', '', ''),
            (CHILD, '', '', '[]', DESKTOP, 'research', ''),
            (CLI, 'CLI project', '', json.dumps(self.workspaces), '', '', 'CORTEX_TRAJECTORY_SOURCE_CLI'),
        ])
        self.connection.commit()

        self.descriptor(self.desktop, DESKTOP, CHILD, 'Dependency researcher')
        self.descriptor(self.cli, CLI, CLI_CHILD, 'Tests reviewer')
        self.log = self.desktop / 'brain' / DESKTOP / '.system_generated/logs/transcript_full.jsonl'
        self.log.parent.mkdir(parents=True, exist_ok=True)
        self.log.write_bytes(
            b'{"type":"USER_INPUT","content":"First prompt","step_index":0}\n'
            b'{"type":"GENERIC","content":"Recorded tool bytes","step_index":1}\n'
            b'{"type":"PLANNER_RESPONSE","content":"Unique reply text","step_index":2}\n')
        self.log.with_name('transcript.jsonl').write_text('{"type":"USER_INPUT","content":"Short log"}\n')

    def descriptor(self, base, parent, child, label):
        path = base / 'brain' / parent / '.system_generated/subagents' / f'{child}.json'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'conversationId': child, 'workspaceUris': self.workspaces,
                                    'subagentDescriptor': {'typeName': 'research', 'role': label}}))

    def invoke(self, *args, expect=0):
        output = io.StringIO()
        errors = io.StringIO()
        with patch.object(antigravity, 'data_root', return_value=self.root), \
                redirect_stdout(output), redirect_stderr(errors):
            status = agent_convert.main(list(args))
        self.assertEqual(status, expect, errors.getvalue())
        return output.getvalue(), errors.getvalue()

    def test_catalog_search_and_desktop_handoff(self):
        result, _ = self.invoke('antigravity', 'list', '--json', '--cwd', str(self.workspace))
        threads = {row['id']: row for row in json.loads(result)}
        self.assertEqual(set(threads), {DESKTOP, CHILD, CLI, CLI_CHILD})
        self.assertEqual(threads[CLI]['surface'], 'cli')
        self.assertEqual(threads[CHILD]['agentLabel'], 'Dependency researcher')
        self.assertEqual(threads[CHILD]['parentId'], DESKTOP)
        self.assertEqual(threads[DESKTOP]['transcript'], str(self.log))

        result, _ = self.invoke('find', 'unique reply', '--store', 'antigravity-desktop', '--json')
        self.assertEqual([row['id'] for row in json.loads(result)], [DESKTOP])
        result, _ = self.invoke('find', 'dependency researcher', '--store', 'antigravity', '--json')
        self.assertEqual([row['id'] for row in json.loads(result)], [CHILD])

        result, _ = self.invoke('antigravity', 'resume', CHILD, '--surface', 'desktop', '--json')
        plan = json.loads(result)
        self.assertEqual((plan['rootId'], plan['id']), (DESKTOP, CHILD))
        self.assertEqual(plan['searchText'], 'Desktop project')
        self.assertEqual([item['id'] for item in plan['subagents']], [CHILD])
        with patch.object(antigravity.sys, 'platform', 'darwin'), \
                patch.object(antigravity.subprocess, 'run') as launch:
            self.invoke('antigravity', 'resume', CHILD, '--surface', 'desktop', '--launch')
            launch.assert_called_once_with(['open', '-a', 'Antigravity'], check=True)

    def test_snapshot_fallback_includes_committed_wal(self):
        wal = self.db.with_name(self.db.name + '-wal')
        before = self.db.read_bytes(), wal.read_bytes()
        query = antigravity.query_summaries

        def block_live_index(path, *, private_copy=False):
            if path == self.db:
                raise sqlite3.OperationalError('unable to open database file')
            self.assertTrue(private_copy)
            return query(path, private_copy=private_copy)

        with patch.object(antigravity, 'query_summaries', side_effect=block_live_index):
            rows = antigravity.read_summaries(self.db)
        self.assertEqual({row[0] for row in rows}, {DESKTOP, CHILD, CLI})
        self.assertEqual(before, (self.db.read_bytes(), wal.read_bytes()))

        busy, remaining, _ = self.connection.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()
        self.assertEqual((busy, remaining), (0, 0))
        self.connection.close()
        wal.unlink(missing_ok=True)
        self.db.with_name(self.db.name + '-shm').unlink(missing_ok=True)
        self.assertFalse(wal.exists())
        with patch.object(antigravity, 'query_summaries', side_effect=block_live_index):
            rows = antigravity.read_summaries(self.db)
        self.assertEqual({row[0] for row in rows}, {DESKTOP, CHILD, CLI})
        self.assertFalse(wal.exists())

    def test_raw_export_and_partial_record(self):
        command = [sys.executable, str(ROOT / 'cli/agent_convert.py'), 'antigravity',
                   '--data-dir', str(self.root), 'transcript', DESKTOP, '--surface', 'desktop']
        result = subprocess.run(command, check=True, capture_output=True)
        self.assertEqual(result.stdout, self.log.read_bytes())
        result, _ = self.invoke('antigravity', 'show', DESKTOP, '--tail', '5', '--json')
        self.assertEqual([row['role'] for row in json.loads(result)['dialogue']], ['user', 'assistant'])

        with self.log.open('ab') as stream:
            stream.write(b'{"type":')
        result = subprocess.run(command, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b'')
        self.assertIn(b'partial last record', result.stderr)

    def test_cli_routes_subagent_through_parent_and_preserves_prompt(self):
        result, _ = self.invoke('antigravity', 'resume', CLI_CHILD, '--surface', 'cli', '--json')
        plan = json.loads(result)
        self.assertEqual(plan['argv'], ['agy', '--conversation', CLI])
        self.assertEqual([item['id'] for item in plan['subagents']], [CLI_CHILD])

        with patch.object(antigravity.subprocess, 'call', return_value=0) as launch:
            self.invoke('antigravity', 'resume', CLI_CHILD, '--surface', 'cli', '--launch')
            launch.assert_called_once_with(['agy', '--conversation', CLI], cwd=str(self.workspace))
            prompt = '--flag-like text\nUnicode reply: café'
            self.invoke('antigravity', 'send', CLI, '--surface', 'cli', '--prompt=' + prompt)
            self.assertEqual(launch.call_args.args[0], ['agy', '--conversation', CLI, '--print=' + prompt])
            _, error = self.invoke('antigravity', 'send', CLI_CHILD, '--surface', 'cli', '--prompt', 'hi', expect=1)
            self.assertIn('/agents', error)
            self.assertEqual(launch.call_count, 2)

    def test_ambiguous_uuid_and_parent_cycle_are_rejected(self):
        (self.cli / 'conversations' / f'{DESKTOP}.db').touch()
        _, error = self.invoke('antigravity', 'show', DESKTOP, expect=1)
        self.assertIn('both surfaces', error)
        self.descriptor(self.desktop, CHILD, DESKTOP, 'Stale descriptor')
        _, error = self.invoke('antigravity', 'resume', CHILD, '--surface', 'desktop', expect=1)
        self.assertIn('parent cycle', error)


if __name__ == '__main__':
    unittest.main()
