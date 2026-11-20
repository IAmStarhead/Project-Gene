#!/usr/bin/env python3
"""Publish three-view diagnostics of explicit contact_scenarios.py snapshots.

These are native re-renders of a FROZEN controller snapshot, not additional
controller coverage or signed-depth/visibility classification. Original PNGs
are SHA-checked and uniformly scaled, never cropped or retouched.
"""
import argparse
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('out', type=Path)
    parser.add_argument('--font', default='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')
    args = parser.parse_args()
    from PIL import Image, ImageDraw, ImageFont
    data = json.loads(args.manifest.read_text())
    frames = data['frames']
    if data['errors'] or len(frames) != 24:
        raise ValueError('Expected 24 successful native views of the eight explicit cases')
    rows = []
    for offset in range(0, len(frames), 3):
        group = frames[offset:offset+3]
        command = group[0]['command']
        if [f['command']['view'] for f in group] != ['side', 'opposite', 'back']:
            raise ValueError('Expected both sides and back, in the declared order')
        for frame in group:
            if (frame['command']['label'] != command['label'] or
                    frame['command']['diagnostic_pose'] != command['diagnostic_pose'] or
                    frame['command']['contact_faces'] != command['contact_faces']):
                raise ValueError('Different snapshot/contact faces in a three-view row')
            if sha(frame['file']) != frame['sha256']:
                raise ValueError('Changed source PNG '+frame['file'])
        rows.append(group)
    args.out.mkdir(parents=True, exist_ok=True)
    font = ImageFont.truetype(args.font, 14)
    published = []
    for start in range(0, len(rows), 2):
        sheet = Image.new('RGB', (1500, 760), '#152331')
        draw = ImageDraw.Draw(sheet)
        sources = []
        for r, group in enumerate(rows[start:start+2]):
            for col, frame in enumerate(group):
                with Image.open(frame['file']) as image:
                    if image.size != (1000, 700):
                        raise ValueError('Unexpected source dimensions')
                    sheet.paste(image.convert('RGB').resize((500, 350), Image.Resampling.LANCZOS), (col*500, r*380))
                cmd = frame['command']
                draw.text((col*500+5, r*380+350), cmd['label'], font=font, fill='white')
                draw.text((col*500+5, r*380+365), cmd['view']+' | RED contact faces (+0.5 mm); MAGENTA skin', font=font, fill='#b4d6e8')
                sources.append({'frame':Path(frame['file']).name, 'sha256':frame['sha256'],
                    'case':cmd['label'], 'view':cmd['view'], 'garment_contact_triangles':len(cmd['contact_faces']),
                    'source_hashes':{k:v for k,v in frame.items() if k.endswith('_sha256')}})
        path = args.out/f'contacts-{start//2+1}.jpg'
        sheet.save(path, quality=94)
        published.append({'file':path.name, 'sha256':sha(path), 'sources':sources})
        print(path)
    (args.out/'contacts.json').write_text(json.dumps({
        'manifest_sha256':sha(args.manifest), 'native_views':len(frames), 'controller_snapshots':len(rows),
        'conditions':'Frozen actual-controller snapshots, neutral diagnostic re-render. NOT new controller coverage. Red intersecting garment faces are expanded 0.5 mm, not signed depth; magenta is production visible skin. Both sides/back. Uniform 1000x700 -> 500x350, no crop/retouch.',
        'sheets':published}, indent=2)+'\n')


if __name__ == '__main__':
    main()
