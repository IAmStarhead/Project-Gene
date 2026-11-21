#!/usr/bin/env python3
"""Build an ISOLATED command-driven native Godot review pack, never a game mod.

python prototype/tests/rendered_review/make_pack.py --godot /path/to/godot \
  --work .local/review/repair-44/runtime-project \
  --output .local/godot-visual/public/runtime44.pck

The WebAssembly engine/HTTP host are external; see README.md. No dependencies
beyond Python + Godot. Source hashes are validated again by the capture client.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT/'prototype'
HERE = Path(__file__).resolve().parent
FILES = {
    'model_sha256': 'assets/heroine/female_A_rigged_safe.glb',
    'appearance_sha256': 'assets/heroine/appearance/lab_uniform.json',
    'motion_set_sha256': 'assets/heroine/animations/motion_set.json',
    'runtime_sha256': 'scripts/character_appearance.gd',
    'controller_sha256': 'scripts/character_anim.gd',
    'player_sha256': 'scripts/player.gd', 'clone_sha256': 'scripts/clone_enemy.gd',
    'hit_check_sha256': 'scripts/hit_check.gd', 'lock_on_sha256': 'scripts/lock_on.gd',
    'hud_sha256': 'scripts/hud.gd', 'world_sha256': 'scripts/build_scene.gd',
    'lighting_sha256': 'shaders/toon_light.gd', 'showcase_sha256': 'scripts/showcase.gd',
    'main_sha256': 'scripts/main.gd', 'tuning_sha256': 'scripts/tuning.gd',
    'project_sha256': 'project.godot',
    'move_catalog_sha256': 'scripts/move_catalog.gd',
    'quick_slots_sha256': 'scripts/quick_slots.gd',
    'camera_sha256': 'scripts/camera_rig.gd',
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--godot', required=True)
    p.add_argument('--driver', choices=['game', 'layers', 'production'], default='game')
    p.add_argument('--baseline-appearance', help='Layers only: git commit for model, appearance JSON and cloth runtime. Other sources stay current for identical pose/camera diagnostics.')
    p.add_argument('--source-commit', help='Archive ALL production sources from this exact git commit into the owned review copy; same CURRENT review driver. Never checkout or edit a production branch. Cannot combine with appearance-only mixing.')
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    if a.source_commit and a.baseline_appearance:
        p.error('--source-commit cannot be combined with --baseline-appearance')
    source_commit = None
    if a.source_commit:
        source_commit = subprocess.run(['git','rev-parse','--verify','--end-of-options',
            a.source_commit+'^{commit}'],cwd=ROOT,text=True,capture_output=True,check=True).stdout.strip()
    baseline = None
    if a.baseline_appearance:
        if a.driver != 'layers':
            p.error('--baseline-appearance is only for the isolated layers diagnostic')
        revision = subprocess.run(['git', 'rev-parse', '--verify', '--end-of-options',
                                   a.baseline_appearance+'^{commit}'], cwd=ROOT,
                                  text=True, capture_output=True, check=True)
        baseline = revision.stdout.strip()
    work, output = a.work.resolve(), a.output.resolve()
    if (work == ROOT or work == SOURCE or work in SOURCE.parents or SOURCE in work.parents
            or work == ROOT/'.git' or ROOT/'.git' in work.parents):
        p.error('--work must be a separate review directory, not in prototype, .git or a repository ancestor')
    project = work/'prototype'
    if (output.suffix != '.pck' or SOURCE in output.parents or project in output.parents
            or ROOT/'.git' in output.parents):
        p.error('--output must be a .pck outside production, .git and the project being packed')
    marker = work/'.rendered-review'
    identity = str(ROOT)+'\n'
    if project.is_symlink():
        p.error('Refusing a symlinked project destination')
    if project.exists() and (not marker.exists() or marker.read_text() != identity):
        p.error('Refusing to overwrite an unmarked existing project; choose a fresh --work directory')
    work.mkdir(parents=True, exist_ok=True)
    marker.write_text(identity)
    # Recreate only this explicitly owned REVIEW copy, so removed scripts and
    # old imports cannot leak into a repeated pack. Never delete production
    # or an unmarked project. Exclude output / authoring dependencies.
    if project.exists():
        shutil.rmtree(project)
    if source_commit:
        content = subprocess.run(['git','archive','--format=tar',source_commit,'prototype'],
            cwd=ROOT,capture_output=True,check=True).stdout
        # Write only regular tracked files under the fixed prototype prefix.
        # Do not use unrestricted extractall or follow archive symlinks.
        with tarfile.open(fileobj=io.BytesIO(content),mode='r:') as archive:
            for member in archive.getmembers():
                parts = PurePosixPath(member.name).parts
                if not parts or parts[0] != 'prototype' or '..' in parts:
                    raise ValueError('Unexpected historical archive path: '+member.name)
                if any(k in parts for k in ['.godot','node_modules','animation_preview','__pycache__','output']):
                    continue
                if member.isdir(): continue
                if not member.isfile():
                    raise ValueError('Historical review does not follow links: '+member.name)
                destination = project.joinpath(*parts[1:])
                destination.parent.mkdir(parents=True,exist_ok=True)
                destination.write_bytes(archive.extractfile(member).read())
    else:
        shutil.copytree(SOURCE, project, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('.godot', 'node_modules', 'animation_preview', '__pycache__', 'output'))
    # Hash the chosen production sources BEFORE installing any review hooks.
    expected = {key: sha(project/path) for key,path in FILES.items() if (project/path).is_file()}
    production = (project/'project.godot').read_text()
    assert production.count('run/main_scene="res://scenes/main.tscn"') == 1
    (project/'production-project.godot').write_text(production)
    if a.driver == 'production':
        (project/'project.godot').write_text(production)
    else:
        (project/'project.godot').write_text(production.replace(
            'run/main_scene="res://scenes/main.tscn"', 'run/main_scene="res://driver.tscn"'))
        driver = 'driver' if a.driver == 'game' else 'layers'
        for suffix in ['.gd', '.tscn']:
            shutil.copy2(HERE/(driver+suffix), project/('driver'+suffix))
        scene = project/'driver.tscn'
        scene.write_text(scene.read_text().replace('res://tests/rendered_review/'+driver+'.gd', 'res://driver.gd'))
        if a.driver == 'game':
            # Explicit test-only dependency even when the historical source
            # predates it. No production controller, asset or scene is patched.
            (project/'tests').mkdir(exist_ok=True)
            shutil.copy2(HERE.parent/'native_soles.gd',project/'tests/native_soles.gd')
            # Optional no-raster preflight uses precisely the same command
            # fixtures, but is never called by the Web/production entry point.
            for helper in ['native_trace.gd','native_trace.tscn']:
                text = (HERE/helper).read_text().replace('res://tests/rendered_review/driver.gd','res://driver.gd').replace(
                    'res://tests/rendered_review/native_trace.gd','res://native_trace.gd')
                (project/helper).write_text(text)
    shutil.copy2(HERE/'pack.gd', project/'pack.gd')
    for key, value in expected.items():
        file = FILES[key]
        if key != 'project_sha256' or a.driver == 'production':
            assert sha(project/file) == value, 'Changed production copy '+file
    if baseline:
        # A deliberately MIXED diagnostic, never advertised as a historical
        # game/controller replay: only appearance changes, not pose/camera.
        for key in ['model_sha256', 'appearance_sha256', 'runtime_sha256']:
            path = FILES[key]
            content = subprocess.run(['git', 'show', baseline+':prototype/'+path],
                                     cwd=ROOT, capture_output=True, check=True).stdout
            (project/path).write_bytes(content)
            expected[key] = sha(project/path)
    (work/'source-hashes.json').write_text(json.dumps(expected, indent=2)+'\n')
    engine = str(Path(a.godot).resolve()) if Path(a.godot).is_file() else a.godot
    def run(args, log, env=None):
        result = subprocess.run([engine, '--headless', '--path', str(project), *args],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=180, env=env)
        (work/log).write_text(result.stdout)
        print(result.stdout[-1500:])
        clean = re.sub(r'\x1b\[[0-9;]*m', '', result.stdout)
        if result.returncode or re.search(r'^(?:SCRIPT ERROR:|ERROR:)', clean, re.MULTILINE) or 'Parse Error:' in clean:
            raise SystemExit('Review build failed: '+str(work/log))
    run(['--editor', '--import'], 'import.log')
    import os
    output.parent.mkdir(parents=True, exist_ok=True)
    run(['--script', 'res://pack.gd'], 'pack.log', os.environ | {'PACK_OUTPUT': str(output)})
    (work/'pack.json').write_text(json.dumps({'pck_sha256':sha(output), 'strict_import_and_pack_pass': True,
        'isolated_project_sha256':sha(project/'project.godot'),
        'driver':a.driver, 'driver_sha256':sha(project/'driver.gd') if a.driver != 'production' else None,
        'native_trace_sha256':sha(project/'native_trace.gd') if a.driver == 'game' else None,
        'baseline_appearance_commit': baseline, 'production_source_commit':source_commit,
        'diagnostic_note': ('Appearance-only baseline with CURRENT poses/cameras; not historical gameplay' if baseline
                            else 'ALL production sources archived from the stated commit; CURRENT isolated review driver and test-only dense-sole helper' if source_commit else None),
        'source_hashes':expected}, indent=2)+'\n')
    print('Review pack:', output, '\nSource hashes:', work/'source-hashes.json')


if __name__ == '__main__':
    main()
