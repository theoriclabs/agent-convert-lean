#!/usr/bin/env python3
"""Install the session CLI, an immutable Loom core, and its discoverable Codex skill."""
import argparse
import hashlib
import io
import json
import os
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


def command(argv, cwd=None):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout[-3000:])
    return result.stdout


def install(args):
    repo = Path(__file__).resolve().parent.parent
    scratch = Path(tempfile.mkdtemp(prefix='agent-convert-install-'))
    source_revision = None
    try:
        if args.build:
            source_revision = command(['git', 'rev-parse', 'HEAD'], repo).strip()
            blob = subprocess.check_output(['git', 'archive', source_revision], cwd=repo)
            source = scratch / 'source'
            source.mkdir()
            with tarfile.open(fileobj=io.BytesIO(blob)) as archive:
                # The archive is from this trusted checkout, never a downloaded tar.
                archive.extractall(source)
            print(f'Building Loom core from committed source {source_revision[:12]}', file=sys.stderr)
            result = subprocess.run(['lake', '-KcoreRevision=' + source_revision, 'build', 'loom'],
                                    cwd=source, stdout=(scratch / 'build.log').open('w'), stderr=subprocess.STDOUT)
            if result.returncode:
                raise ValueError(f'Core build failed; see {scratch / "build.log"}')
            core = source / '.lake/build/bin/loom'
        else:
            core = args.core.expanduser().resolve()
        identity = json.loads(command([str(core), 'version', '--json']))
        if identity.get('protocolVersion') != 'loom.cli.v1':
            raise ValueError('The supplied binary does not implement loom.cli.v1')
        destination = args.prefix.expanduser().resolve() / 'share/agent-convert'
        launcher = args.prefix.expanduser().resolve() / 'bin/agent-convert'
        stage = destination.with_name('agent-convert.install-stage')
        if stage.exists():
            raise ValueError(f'Installation stage already exists: {stage}')
        stage.mkdir(parents=True)
        shutil.copytree(repo / 'cli', stage / 'cli', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        (stage / 'bin').mkdir()
        shutil.copy2(core, stage / 'bin/loom')
        shutil.copy2(repo / 'LICENSE', stage / 'LICENSE')
        receipt = {'core': identity, 'sourceRevision': source_revision,
                   'coreSha256': hashlib.sha256(core.read_bytes()).hexdigest(),
                   'cliVersion': '0.1.0', 'python': sys.executable}
        (stage / 'installation.json').write_text(json.dumps(receipt, indent=2))
        backup = destination.with_name('agent-convert.install-backup')
        if backup.exists():
            raise ValueError(f'Installation backup already exists: {backup}')
        if destination.exists():
            destination.rename(backup)
        try:
            stage.rename(destination)
            launcher.parent.mkdir(parents=True, exist_ok=True)
            launcher_stage = launcher.with_name('agent-convert.install-stage')
            with launcher_stage.open('x') as output:
                output.write('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' ' +
                             shlex.quote(str(destination / 'cli/agent_convert.py')) + ' "$@"\n')
            launcher_stage.chmod(0o755)
            os.replace(launcher_stage, launcher)
        except Exception:
            if destination.exists():
                shutil.rmtree(destination)
            if backup.exists():
                backup.rename(destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        skill_destination = args.skills_dir.expanduser().resolve() / 'agent-session-converter'
        skill_source = repo / 'skills/agent-session-converter'
        # Update maintained resources without removing unrelated personal references.
        shutil.copytree(skill_source, skill_destination, dirs_exist_ok=True)
        print(json.dumps({'cli': str(launcher), 'core': str(destination / 'bin/loom'),
                          'skill': str(skill_destination / 'SKILL.md'), 'identity': receipt}, indent=2))
        shutil.rmtree(scratch)
    except Exception:
        print(f'Installer work retained: {scratch}', file=sys.stderr)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--core', type=Path, help='Use an already built/released Loom binary')
    source.add_argument('--build', action='store_true', help='Build the current committed revision in an isolated directory')
    parser.add_argument('--prefix', type=Path, default=Path.home() / '.local')
    parser.add_argument('--skills-dir', type=Path,
                        default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'skills')
    args = parser.parse_args()
    try:
        install(args)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'install-agent-convert: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
