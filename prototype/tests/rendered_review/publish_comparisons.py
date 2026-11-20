#!/usr/bin/env python3
"""Publish small paired diagnostic sheets and their pose/camera provenance.

Images are scaled uniformly, never cropped/retouched. This is a static
appearance comparison, not historical gameplay or collision acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--before', type=Path, required=True, help='layers capture manifest.json')
    p.add_argument('--after', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--font', default='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')
    a = p.parse_args()
    from PIL import Image, ImageDraw, ImageFont
    before, after = [json.loads(path.read_text()) for path in [a.before, a.after]]
    for d in [before, after]:
        if d['errors']:
            raise ValueError('Cannot publish a failed capture')
    key = lambda f: tuple(f['command'].get(k) for k in ['clip', 'time', 'view', 'layer'])
    bmap, amap = [{key(f): f for f in d['frames']} for d in [before, after]]
    if set(bmap) != set(amap):
        raise ValueError('Different comparison poses')
    pairs = []
    for k, b in bmap.items():
        other = amap[k]
        # Deliberately strict: no pose tolerance that could reward changing
        # accepted legs or moving the problem out of the camera.
        for field in ['camera', 'rotations', 'hips', 'full_skin', 'body_visible', 'gown_visible']:
            if b[field] != other[field]:
                raise ValueError('Unmatched '+field+' for '+str(k))
        for field in ['clip', 'time', 'view', 'layer', 'close', 'focus', 'simulate', 'warm']:
            if b['command'].get(field) != other['command'].get(field):
                raise ValueError('Unmatched command '+field)
        sources = []
        for frame in [b, other]:
            digest = sha(frame['file'])
            if digest != frame['sha256']:
                raise ValueError('Changed source PNG: '+frame['file'])
            sources.append({'sha256': digest, 'file': Path(frame['file']).name,
                'source_hashes': {k: v for k, v in frame.items() if k.endswith('_sha256')}})
        pairs.append({'pose': dict(zip(['clip', 'time', 'view', 'layer'], k)),
                      'camera': b['camera'], 'pose_equal_exactly': True, 'sources': sources})
    a.out.mkdir(parents=True, exist_ok=True)
    font, small = ImageFont.truetype(a.font, 19), ImageFont.truetype(a.font, 16)
    groups = {
        'shoulder-comparison': [('attack_right', .19, 'back', 'skin'),
            ('attack_right', .19, 'back', 'both'), ('attack_right', .19, 'side', 'both'),
            ('attack_left', .18, 'back', 'both')],
        'hem-comparison': [(c, .31 if c == 'sprint_relaxed' else .24, 'side', 'both')
                           for c in ['dodge_back', 'dodge_left', 'dodge_right', 'sprint_relaxed']],
        'hem-back-comparison': [(c, .31 if c == 'sprint_relaxed' else .24, 'back', 'both')
                                for c in ['dodge_back', 'dodge_left', 'dodge_right', 'sprint_relaxed']],
    }
    sheets = []
    for name, keys in groups.items():
        width, picture_height, band, title = 600, 420, 30, 54
        canvas = Image.new('RGB', (width*2, title+(picture_height+band)*len(keys)), '#152331')
        draw = ImageDraw.Draw(canvas)
        draw.text((12, 7), 'BEFORE | d67fef7 appearance', font=font, fill='#ffc5b8')
        draw.text((width+12, 7), 'CURRENT | same pose, light and camera', font=font, fill='#b4eeed')
        draw.text((12, 31), 'GODOT 4.7.2 | neutral diagnostic | full skin only where labelled', font=small, fill='white')
        for row, k in enumerate(keys):
            y = title+row*(picture_height+band)
            for col, source in enumerate([bmap[k], amap[k]]):
                image = Image.open(source['file']).convert('RGB')
                if image.size != (1000, 700):
                    raise ValueError('Unexpected diagnostic canvas')
                image = image.resize((width, picture_height), Image.Resampling.LANCZOS)
                canvas.paste(image, (col*width, y))
                label = f'{k[0]} | {k[1]:.3f}s | {k[2]} | '+('FULL SKIN (diagnostic)' if k[3]=='skin' else 'production coverage')
                draw.text((col*width+8, y+picture_height+5), label, font=small, fill='white')
        dest = a.out/(name+'.jpg')
        canvas.save(dest, quality=94)
        sheets.append({'file':dest.name, 'sha256':sha(dest), 'pairs':keys})
        print(dest)
    (a.out/'comparisons.json').write_text(json.dumps({
        'before_manifest_sha256':sha(a.before), 'after_manifest_sha256':sha(a.after),
        'conditions':'Appearance-only d67fef7 baseline + current poses and layers driver, not historical gameplay. Native frame_post_draw. 1000x700 uniformly scaled to 600x420 per tile, no cropping/retouching.',
        'comparison_pairs':len(pairs), 'max_pose_or_camera_difference':0, 'pairs':pairs, 'sheets':sheets,
    }, indent=2)+'\n')


if __name__ == '__main__':
    main()
