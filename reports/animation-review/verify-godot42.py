#!/usr/bin/env python3
"""Check delivered report-42 evidence integrity, NOT rerun its geometry tests.

    python reports/animation-review/verify-godot42.py

Standard library only. Intentionally fails if the tested runtime/assets or
media changed; re-record the evidence after a deliberate production change.
For actual regressions, run prototype/tests/run_headless.py and the generators.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / 'reports/animation-review/godot42-evidence.json'


def require(condition, message):
    if not condition:
        raise SystemExit('Evidence integrity FAILED: ' + message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    data = json.loads(EVIDENCE.read_text(encoding='utf-8'))
    require(set(data['changed_source_files']) == set(data['changed_source_files_sha256']),
            'Changed-source inventory differs from its hash manifest')
    sources = dict(data['changed_source_files_sha256'])
    for key, relative in data['source_paths'].items():
        expected = data['source_sha256'][key]
        require(relative not in sources or sources[relative] == expected,
                'Conflicting source hashes: ' + relative)
        sources[relative] = expected
    for relative, expected in sources.items():
        path = ROOT / relative
        require(path.is_file(), 'Missing tested source: ' + relative)
        require(digest(path) == expected, 'Changed tested source: ' + relative)
    for relative, expected in data['artifacts'].items():
        path = ROOT / relative
        require(path.is_file(), 'Missing artifact: ' + relative)
        require(path.stat().st_size == expected['bytes'], 'Changed artifact size: ' + relative)
        require(digest(path) == expected['sha256'], 'Changed artifact: ' + relative)

    # Also check the source commit when available (e.g. not a shallow archive).
    source = data['tested_source_commit']
    if shutil.which('git') and subprocess.run(
            ['git', 'cat-file', '-e', source + '^{commit}'], cwd=ROOT,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        for relative, expected in sources.items():
            blob = subprocess.check_output(['git', 'show', source + ':' + relative], cwd=ROOT)
            require(hashlib.sha256(blob).hexdigest() == expected,
                    'Source commit mismatch: ' + relative)

    require(data['native_checks']['animation'] == 606, 'Native baseline count')
    require(data['native_checks']['combined_integration'] == 55, 'New integration count')
    require(data['native_checks']['failures'] == 0, 'Native failures')
    require(data['native_checks']['fresh_import_strict_pass'] is False,
            'Do not silently turn the disclosed fontconfig failure into a pass')
    require(data['python_tests']['count'] == 43 and data['python_tests']['passed'], 'Python summary')
    require(data['invariants']['newly_hidden_faces'] == 0, 'Expanded body mask')
    require(data['invariants']['outer_cuff_max_coordinate_difference_m'] == 0,
            'The outer cuff was changed')
    for name, count in [('controller', 3366), ('library', 848),
                        ('exact_seeks', 14), ('webgl_controllers', 518)]:
        result = data['fcl'][name]
        require(result['frames'] == count, name + ' sample count')
        require(result['intersecting_frames'] == {'gown': count, 'skirt': 0},
                name + ' contacts (remaining gown contacts must stay disclosed)')
    require(data['fcl_principal_overlapping_samples'] == 4746, 'Overlapping sample total')
    video = data['video']
    require(video['duration_seconds'] == 21.3 and video['container_frames'] == 1278,
            'Video timeline')
    require(video['container_fps'] == 60 and video['native_framebuffers_in_video'] == 258
            and video['distinct_native_pixel_arrays'] == 258, 'Distinct/coded frame disclosure')
    require(data['video_decode']['frames_decoded'] == 1278, 'Decode summary')
    require(data['environment']['windows_opengl33_940mx_tested'] is False,
            'Do not relabel SwiftShader as target hardware')
    print('Evidence integrity OK: %d tested sources, %d artifacts; source %s.' %
          (len(sources), len(data['artifacts']), source))
    print('This verifies stored hashes/consistency, not a new Godot/FCL run or visual acceptance.')


if __name__ == '__main__':
    main()
