#!/usr/bin/env python3
"""Identical-pose/camera/light appearance comparisons, NOT controller playback.

Build two layers packs first (make_pack.py); only the BEFORE pack uses
--baseline-appearance. Configs verify five asset/runtime stamps on each frame.
No cropped gameplay camera or diagnostic full skin enters production.
"""
import argparse
import json
from pathlib import Path


def shots():
    result = []
    for t in [.16, .18, .19, .20]:
        for layer in ['skin', 'both']:
            result.append(dict(clip='attack_right', time=t, view='back', layer=layer, close=True))
    for view in ['front', 'side', 'opposite']:
        result.append(dict(clip='attack_right', time=.19, view=view, layer='both', close=True))
    for clip, t in [('attack_left', .18), ('guard', 0)]:
        for layer in ['skin', 'both']:
            result.append(dict(clip=clip, time=t, view='back', layer=layer, close=True))
    for clip in ['dodge_back', 'dodge_left', 'dodge_right', 'sprint_relaxed']:
        for view in ['side', 'back']:
            result.append(dict(clip=clip, time=.31 if clip == 'sprint_relaxed' else .24,
                view=view, layer='both', close=False, simulate=True, warm=clip == 'sprint_relaxed'))
    for s in result:
        s['outfit'] = 'dress'
        s['file'] = f"{s['clip']}-{s['time']:.3f}-{s['layer']}-{s['view']}"
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for which in ['before', 'after']:
        p.add_argument('--'+which, type=Path, required=True, help='make_pack --work directory')
        p.add_argument('--'+which+'-pack', required=True)
    a = p.parse_args()
    for which in ['before', 'after']:
        work, pack = getattr(a, which), getattr(a, which+'_pack')
        hashes = json.loads((work/'source-hashes.json').read_text())
        expected = {k: hashes[k] for k in ['model_sha256', 'appearance_sha256', 'motion_set_sha256',
                                          'runtime_sha256', 'controller_sha256']}
        config = dict(pack=pack, out=str(work/'comparison'), expected=expected, shots=shots())
        (work/'comparison.json').write_text(json.dumps(config, indent=2)+'\n')
        print(work/'comparison.json')


if __name__ == '__main__':
    main()
