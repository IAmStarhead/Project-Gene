#!/usr/bin/env python3
"""Encode captured framebuffers at their recorded simulation rate, no interpolation.

Pillow is a review-only dependency. Use --ffmpeg or an ffmpeg on PATH; the
optional imageio-ffmpeg package is a fallback for constrained authoring hosts.
Original PNG hashes and per-frame state are preserved in a small JSON sidecar.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def assemble(manifest, output, ffmpeg=None, font_path=None):
    data = json.loads(manifest.read_text())
    frames = data['frames']
    if data['errors'] or not frames or data.get('coverage_assertions_passed') is not True:
        raise ValueError('Capture must contain frames, have no engine/page errors and pass its coverage assertions')
    from PIL import Image, ImageDraw, ImageFont
    step = data['config']['sample_ticks']
    if any(f['steps'] != step for f in frames):
        raise ValueError('Nonuniform sample duration needs explicit variable-rate encoding')
    fps = 60 / step
    if abs(len(frames) / fps - data['simulation_seconds']) > 1e-7:
        raise ValueError('Sample timings differ from the recorded simulation duration')
    sources = [Path(f['file']) for f in frames]
    for f, path in zip(frames, sources):
        if sha(path) != f['sha256']:
            raise ValueError('Capture PNG differs from its manifest: '+str(path))
    if len({f['sha256'] for f in frames}) != data['unique_pngs']:
        raise ValueError('Incorrect distinct-frame count')
    if not ffmpeg:
        ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg:
            try:
                from imageio_ffmpeg import get_ffmpeg_exe
                ffmpeg = get_ffmpeg_exe()
            except ImportError as error:
                raise SystemExit('Install ffmpeg or pass --ffmpeg') from error
    font_path = font_path or next((str(p) for p in [
        Path('/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf'),
        Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')]
        if p.exists()), None)
    font = lambda n: ImageFont.truetype(font_path, n) if font_path else ImageFont.load_default(size=n)
    regular, small = font(16), font(13)
    with Image.open(sources[0]) as image:
        width, height = image.size
    # Captured game pixels are pasted UNCHANGED, not cropped or obscured.
    header, footer = 54, 48
    total_height = height + header + footer
    if width % 2 or total_height % 2:
        raise ValueError('YUV420 encoding requires an even size')
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [str(ffmpeg), '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'rawvideo', '-pixel_format', 'rgb24', '-video_size', f'{width}x{total_height}',
        '-framerate', str(fps), '-i', 'pipe:0', '-an', '-c:v', 'libx264', '-preset', 'medium',
        '-crf', '19', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(output)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    try:
        for i, (frame, path) in enumerate(zip(frames, sources)):
            with Image.open(path) as image:
                if image.size != (width, height):
                    raise ValueError('Viewport changed within the capture')
                canvas = Image.new('RGB', (width, total_height), '#15212f')
                canvas.paste(image.convert('RGB'), (0, header))
            draw = ImageDraw.Draw(canvas)
            title = data['config'].get('title','GODOT 4.7.2 | GAME CONTROLLERS')+' | '+data['config']['coverage'].upper()
            draw.text((12, 6), title, font=regular, fill='#d9f2ff')
            draw.text((12, 30), frame['label'], font=small, fill='white')
            draw.text((12, height+header+5),
                f'1x simulation | {fps:g} captured frames/s | physics 60 Hz | frame {i+1}/{len(frames)}',
                font=small, fill='white')
            draw.text((12, height+header+26),
                'Offline WebGL2 / SwiftShader; review observer + starting fixtures. NOT GPU FPS.',
                font=small, fill='#bdd1e1')
            process.stdin.write(canvas.tobytes())
    finally:
        process.stdin.close()
        status = process.wait()
    if status:
        raise RuntimeError('ffmpeg failed with status '+str(status))
    # Do not publish large pose/cloth arrays or repeat the same hashes 300 times.
    omitted = {'rotations', 'hips', 'cloth'}
    frame_states = []
    for i, frame in enumerate(frames):
        keys = ['take', 'label', 'ticks', 'steps', 'sha256', 'action', 'action_time',
                'grounded', 'health', 'clone_health', 'stamina', 'lock_target', 'last_contact',
                'received_contact', 'clone_received_contact', 'attack_kind', 'dodge_local',
                'clone_grounded', 'hud_visible', 'yaw', 'camera_yaw', 'velocity', 'framing',
                'selected_slot', 'kick_planting', 'stance', 'training_blade', 'training_limb', 'air_launched',
                'land_time', 'soles', 'floor_y', 'view', 'camera_transform']
        row = {k: frame[k] for k in keys if k in frame}
        row.update({'frame': i, 'video_time': round(i/fps, 6)})
        for who in ['player', 'clone']:
            row[who] = {k: v for k, v in frame[who].items() if k not in omitted}
        frame_states.append(row)
    evidence = {'video': output.name, 'video_sha256': sha(output),
        'capture_manifest_sha256': sha(manifest), 'source_hashes': data['source_hashes'],
        'conditions': data['conditions'], 'physics_hz': 60, 'capture_hz': fps,
        'playback_simulation_rate': 1, 'frames': len(frames), 'distinct_source_pngs': data['unique_pngs'],
        'seconds': data['simulation_seconds'], 'viewport': [width, height],
        'video_pixels': [width, total_height], 'interpolated_frames': 0,
        'errors': data['errors'], 'timeline': data['config']['timeline'], 'frame_states': frame_states}
    sidecar = output.with_suffix('.json')
    sidecar.write_text(json.dumps(evidence, indent=2)+'\n')
    print(f'{output}: {len(frames)} frames, {data["unique_pngs"]} distinct PNGs, '
          f'{data["simulation_seconds"]:g}s, {fps:g} captured frames/s, 1x simulation')
    return evidence


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('manifest', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--ffmpeg')
    p.add_argument('--font', help='Optional path to a TrueType font')
    a = p.parse_args()
    assemble(a.manifest, a.output, a.ffmpeg, a.font)


if __name__ == '__main__':
    main()
