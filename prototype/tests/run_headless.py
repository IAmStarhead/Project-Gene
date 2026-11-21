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
import time

PROJECT = Path(__file__).resolve().parents[1]
ANSI = re.compile(r'\x1b\[[0-9;]*m')
ERROR = re.compile(r'^(?:SCRIPT ERROR:|ERROR:)', re.MULTILINE)


def run(engine, args, expect_suite=None, timeout=300):
    command = [engine, '--headless', '--path', str(PROJECT), *args]
    print('Running:', ' '.join(command), flush=True)
    started = time.monotonic()
    try:
        result = subprocess.run(command, text=True, encoding='utf-8', errors='replace',
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        partial = error.stdout or b''
        print(partial.decode('utf-8', 'replace') if isinstance(partial, bytes) else partial, file=sys.stderr)
        raise SystemExit(f'Godot timed out after {timeout}s; suite NOT accepted')
    print(f'Elapsed: {time.monotonic()-started:.3f}s', flush=True)
    text = ANSI.sub('', result.stdout)
    print(text)
    if result.returncode or ERROR.search(text):
        raise SystemExit('Godot reported an error (see log above)')
    if expect_suite and not re.search(re.escape(expect_suite) + r': \d+ checks, 0 failures', text):
        raise SystemExit(expect_suite + ' did not finish')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default=os.getenv('GODOT_BIN'))
    parser.add_argument('--skip-import', action='store_true', help='use an already imported project')
    parser.add_argument('--suite-timeout', type=int, default=300,
                        help='seconds per process (default 300 for the expanded cloth/controller suites); no checks are skipped')
    args = parser.parse_args()
    if args.suite_timeout < 1:
        parser.error('--suite-timeout must be positive')
    engine = args.godot or shutil.which('godot') or shutil.which('godot4')
    if not engine:
        raise SystemExit('Godot not found. Pass --godot /path/to/godot or set GODOT_BIN.')
    if Path(engine).is_file():
        engine = str(Path(engine).resolve())
    if not args.skip_import:
        run(engine, ['--editor', '--import'], timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_animation.gd'],
        expect_suite='GEN native animation suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_idle_cache.gd'],
        expect_suite='GEN idle-cache suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_presentation.gd'],
        expect_suite='Presentation suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_camera_smoothing.gd'],
        expect_suite='Camera smoothing suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_camera_jump_air.gd'],
        expect_suite='Camera jump air suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_training_sword.gd'],
        expect_suite='Training sword suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_limb_demo.gd'],
        expect_suite='Limb demo suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_cut_manikin.gd'],
        expect_suite='Cut manikin suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_manikin_parts.gd'],
        expect_suite='Manikin partition suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_integration.gd'],
        expect_suite='GEN combined integration suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_directional.gd'],
        expect_suite='GEN directional suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_outfits.gd'],
        expect_suite='GEN wardrobe suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_combat_zones.gd'],
        expect_suite='GEN combat-zone suite', timeout=args.suite_timeout)
    run(engine, ['--fixed-fps', '60', '--script', 'res://tests/test_controller_transitions.gd'],
        expect_suite='GEN controller-transition suite', timeout=args.suite_timeout)


if __name__ == '__main__':
    main()
