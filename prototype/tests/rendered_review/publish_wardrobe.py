#!/usr/bin/env python3
"""Verify the paired wardrobe take, publish four unchanged/uncropped comparisons."""
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
    if data['errors'] or data['config']['coverage'] != 'wardrobe' or len(frames) != 122:
        raise ValueError('Expected the successful 122-frame paired wardrobe timeline')
    pairs = list(zip(frames[:61], frames[61:]))
    for dress, suit in pairs:
        if dress['take'].replace('dress-', '', 1) != suit['take'].replace('suit-', '', 1):
            raise ValueError('Unmatched takes')
        if dress['player']['outfit'] != 'dress' or suit['player']['outfit'] != 'suit':
            raise ValueError('Unmatched costumes')
        for field in ['view', 'viewport', 'camera_yaw', 'yaw', 'stamps']:
            if dress[field] != suit[field]:
                raise ValueError('Unmatched observer/settings/source '+field)
        for who in ['player', 'clone']:
            for field in ['rotations', 'hips', 'position', 'phase', 'hand_open', 'state']:
                if dress[who][field] != suit[who][field]:
                    raise ValueError('Unmatched actor '+who+'/'+field)
        for frame in [dress, suit]:
            if sha(frame['file']) != frame['sha256']:
                raise ValueError('Changed source PNG '+frame['file'])
    font = ImageFont.truetype(args.font, 16)
    small = ImageFont.truetype(args.font, 13)
    width, height, band, title = 480, 270, 27, 47
    samples = [0, 13, 18, 42]
    sheet = Image.new('RGB', (width*2, title+(height+band)*len(samples)), '#152331')
    draw = ImageDraw.Draw(sheet)
    draw.text((10, 5), 'DRESS | retained', font=font, fill='#e7efff')
    draw.text((width+10, 5), 'SUIT | optional O', font=font, fill='#b4eeed')
    draw.text((10, 27), 'GODOT game controllers | same poses, route, observer/light | not a performance measurement', font=small, fill='white')
    sources = []
    for row, index in enumerate(samples):
        for col, frame in enumerate(pairs[index]):
            with Image.open(frame['file']) as image:
                if image.size != (800, 450):
                    raise ValueError('Unexpected viewport')
                sheet.paste(image.convert('RGB').resize((width, height), Image.Resampling.LANCZOS),
                            (col*width, title+row*(height+band)))
            draw.text((col*width+8, title+row*(height+band)+height+6),
                      frame['take']+' | source frame '+str(index+col*61), font=small, fill='white')
            sources.append({'take':frame['take'], 'sha256':frame['sha256'], 'frame':index+col*61})
    args.out.mkdir(parents=True, exist_ok=True)
    path = args.out/'wardrobe-comparison.jpg'
    sheet.save(path, quality=94)
    (args.out/'wardrobe-comparison.json').write_text(json.dumps({
        'file':path.name, 'sha256':sha(path), 'manifest_sha256':sha(args.manifest),
        'source_hashes':data['source_hashes'], 'exact_pose_pairs_checked':len(pairs),
        'max_rotations_hips_positions_difference':0, 'sources':sources,
        'conditions':'Current game controllers; identical route and observer view, production medium PBR lighting. Both actors pose/position/phase/hand state EXACTLY equal in all 61 pairs. Uniform 800x450 -> 480x270; no crop/retouch. NOT historical before/after or GPU FPS.'}, indent=2)+'\n')
    print(path, ': 61 exact pose pairs checked')


if __name__ == '__main__':
    main()
