#!/usr/bin/env python3
"""Explicitly split mixed-outfit replay snapshots for the outfit-guarded FCL check.

No samples are silently dropped: output includes both actors and every take
for its selected outfit, with an exact input hash and sample inventory.
"""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('trace', type=Path)
    a = p.parse_args()
    source = json.loads(a.trace.read_text())
    if source.get('outfit') != 'mixed' or source.get('seeks'):
        p.error('Expected a mixed rendered-review snapshot trace with no exact seeks')
    count = sum(len(frames) for frames in source['takes'].values())
    seen = [f.get('outfit') for frames in source['takes'].values() for f in frames]
    if any(o not in ['dress', 'suit'] for o in seen):
        p.error('A snapshot has an unknown/missing outfit')
    written = 0
    for outfit in ['dress', 'suit']:
        subset = {name: [f for f in frames if f['outfit'] == outfit]
                  for name, frames in source['takes'].items()}
        subset = {name: frames for name, frames in subset.items() if frames}
        selected = sum(map(len, subset.values()))
        result = source | {'outfit': outfit, 'takes': subset,
            'input_trace_sha256': hashlib.sha256(a.trace.read_bytes()).hexdigest(),
            'filter_note': 'Explicit outfit selection; all actor/take snapshots with this outfit retained.',
            'input_snapshots': count, 'selected_snapshots': selected}
        output = a.trace.with_name('trace-'+outfit+'.json')
        output.write_text(json.dumps(result, separators=(',', ':'))+'\n')
        written += selected
        print(output, selected, 'of', count, 'actor snapshots')
    assert written == count, 'Every input snapshot must appear in exactly one output'


if __name__ == '__main__':
    main()
