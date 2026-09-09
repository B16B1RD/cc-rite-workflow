#!/usr/bin/env bash
# Offline preparation only: no GitHub, host process, git init, or credentials.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "Usage: bash tests/runtime-e2e/prepare.sh /absolute/new-directory" >&2
  exit 1
fi
SOURCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$SOURCE_ROOT" "$1" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, destination = map(Path, sys.argv[1:])
try:
    if not destination.is_absolute():
        raise ValueError('destination must be an absolute new directory')
    if destination.exists() or destination.is_symlink():
        raise ValueError('destination already exists; choose a new directory')
    commit = subprocess.check_output(
        ['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = bool(subprocess.check_output(
        ['git', '-C', str(source), 'status', '--porcelain'], text=True).strip())
    # Exclusive creation also rejects a destination created after the check.
    os.mkdir(destination)
    (destination / 'app.py').write_text(
        'def greet(name):\n    return f"Hello, {name}!"\n')
    (destination / 'test_app.py').write_text('''import unittest
from app import greet


class GreetingTest(unittest.TestCase):
    def test_greeting(self):
        self.assertEqual(greet("Rite"), "Hello, Rite!")


if __name__ == "__main__":
    unittest.main()
''')
    (destination / 'rite-config.yml').write_text('''schema_version: 2
language: ja
github:
  projects:
    enabled: false
branch:
  base: main
  pattern: "{type}/issue-{number}-{slug}"
commands:
  test: "python3 -m unittest -v"
  lint: "python3 -m py_compile app.py test_app.py"
multi_session:
  enabled: true
  worktree_base: .rite/worktrees
wiki:
  enabled: false
issue:
  auto_decompose_threshold: none
''')
    (destination / '.gitignore').write_text('''.rite/
.codex-dev/
.grok/
.claude/
.agents/
plugins/
scripts/
__pycache__/
.runtime-e2e-source.json
''')
    (destination / 'plugins').mkdir()
    shutil.copytree(source / 'plugins/rite', destination / 'plugins/rite', symlinks=True)
    (destination / 'scripts').mkdir()
    shutil.copy2(source / 'scripts/rite-dev', destination / 'scripts/rite-dev')
    (destination / '.grok/plugins').mkdir(parents=True)
    (destination / '.grok/config.toml').write_text('[plugins]\nenabled = ["rite"]\n')
    (destination / '.grok/plugins/rite').symlink_to('../../plugins/rite')
    (destination / '.runtime-e2e-source.json').write_text(
        json.dumps({'rite_commit': commit, 'dirty': dirty}, indent=2) + '\n')
    print(f'Prepared: {destination}')
    print(f'Source: {commit}; dirty={str(dirty).lower()}')
    if dirty:
        print('Unverified: prepare again from a clean revision before host E2E.')
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    print(f'ERROR: prepare: {error}', file=sys.stderr)
    sys.exit(1)
PY
