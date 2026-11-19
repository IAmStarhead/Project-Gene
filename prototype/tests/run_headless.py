#!/usr/bin/env python3
"""Import and exercise the actual project with an installed Godot 4.7.x.

python prototype/tests/run_headless.py --godot /path/to/godot
GODOT_BIN is also accepted. No pip dependencies. Logs are checked as well as
exit codes: Godot may return 0 even after a GDScript runtime error.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
ANSI = re.compile(r'\x1b\[[0-9;]*m')
ERROR = re.compile(r'^(?:SCRIPT ERROR:|ERROR:)', re.MULTILINE)


def run(engine, args, expect_suite=False, expected_pattern=None):
    command = [engine, '--headless', '--path', str(PROJECT), *args]
    print('Running:', ' '.join(command), flush=True)
    try:
        result = subprocess.run(command, text=True, encoding='utf-8', errors='replace',
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    except subprocess.TimeoutExpired as error:
        print(error.stdout or '', file=sys.stderr)
        raise SystemExit('Godot timed out')
    text = ANSI.sub('', result.stdout)
    print(text)
    if result.returncode or ERROR.search(text):
        raise SystemExit('Godot reported an error (see log above)')
    if expect_suite and not re.search(r'GEN native animation suite: \d+ checks, 0 failures', text):
        raise SystemExit('The integration suite did not finish')
    if expected_pattern and not re.search(expected_pattern, text):
        raise SystemExit('The presentation suite did not finish')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default=os.getenv('GODOT_BIN'))
    parser.add_argument('--skip-import', action='store_true', help='use an already imported project')
    args = parser.parse_args()
    engine = args.godot or shutil.which('godot') or shutil.which('godot4')
    if not engine:
        raise SystemExit('Godot not found. Pass --godot /path/to/godot or set GODOT_BIN.')
    if Path(engine).is_file():
        engine = str(Path(engine).resolve())
    if not args.skip_import:
        run(engine, ['--editor', '--import'])
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_animation.gd'], expect_suite=True)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_presentation.gd'],
        expected_pattern=r'Presentation suite: \d+ checks, 0 failures')


if __name__ == '__main__':
    main()
