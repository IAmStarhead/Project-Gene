#!/usr/bin/env python3
"""Describe comparable isolated native skin/garment views, not game acceptance."""
import argparse
import json
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--pack', default='layers44-final.pck')
    p.add_argument('--contacts', type=Path, help='Optional stamped dress --contact-details JSON')
    a = p.parse_args()
    hashes = json.loads((a.work/'source-hashes.json').read_text())
    expected = {k: v for k, v in hashes.items() if k in [
        'model_sha256', 'appearance_sha256', 'motion_set_sha256', 'runtime_sha256', 'controller_sha256']}
    shots = []
    def shot(clip, time, view, layer='both', **kw):
        outfit, close, suffix = kw.pop('outfit', 'dress'), kw.pop('close', True), kw.pop('suffix', '')
        shots.append(dict(clip=clip, time=time, view=view, layer=layer, outfit=outfit, close=close,
                          file=f'{outfit}-{clip}-{time:.3f}-{view}-{layer}{suffix}', **kw))
    for time in [.16, .18, .19, .20]:
        for layer in ['skin', 'both']:
            shot('attack_right', time, 'back', layer)
    for view in ['front', 'side', 'opposite']:
        for layer in ['skin', 'both']:
            shot('attack_right', .19, view, layer)
    for view in ['front', 'side', 'opposite', 'back']:
        shot('guard', 0, view, magenta=True, suffix='-magenta')
    for clip, time in [('attack_left', .18), ('attack_body_hook', .27), ('run_relaxed', .388), ('jump_start', .12)]:
        for layer in ['skin', 'both']:
            shot(clip, time, 'side', layer)
    for clip, time in [('dodge_back', .24), ('dodge_left', .24), ('dodge_right', .24), ('sprint_relaxed', .31)]:
        for view in ['front', 'side']:
            shot(clip, time, view, focus=[0, .73, .03])
    for clip, time in [('idle_relaxed', 0), ('dodge_left', .24), ('dodge_right', .24), ('attack_body_hook', .27)]:
        for view in ['front', 'back']:
            shot(clip, time, view, outfit='suit', close=False)
    if a.contacts:
        contacts = json.loads(a.contacts.read_text())
        for key, value in expected.items():
            if contacts['summary'][key] != value:
                raise ValueError('Stale contact inventory: '+key)
        cross = next(f['hits']['gown'] for f in contacts['intersections'] if f['frame'] == 'cross-019')
        faces = sorted({item['garment_triangle'] for item in cross['details']})
        for view in ['front', 'side', 'opposite', 'back']:
            shot('attack_right', .19, view, contact_faces=faces, suffix='-contact', magenta=True)
    for clip, time in [('run_relaxed', .388), ('sprint_relaxed', .31)]:
        for view in ['side', 'back']:
            shot(clip, time, view, outfit='suit', focus=[0, .35, .03], magenta=True, suffix='-magenta')
    config = dict(pack=a.pack, out=str(a.work/'captures'), expected=expected, shots=shots)
    (a.work/'layers.json').write_text(json.dumps(config, indent=2)+'\n')
    print(a.work/'layers.json', len(shots), 'isolated layer views')


if __name__ == '__main__':
    main()
