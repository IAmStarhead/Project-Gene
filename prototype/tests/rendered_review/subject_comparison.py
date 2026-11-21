#!/usr/bin/env python3
"""Identical controlled full-source c9d24b1 / R57 game timelines.

Build --source-commit c9d24b1 for BEFORE; CURRENT production for AFTER.
Both packs use the SAME review driver. This is not appearance-only mixing.
"""
import argparse
import json
from pathlib import Path
from subject_scenarios import setup, take


def timeline():
    return [setup(outfit='suit',view='front'),
        take('subject-front',.2,'same settled controller | subject clothing FRONT'),
        setup(outfit='suit',view='back'),
        take('subject-back',.2,'same settled controller | subject clothing BACK'),
        setup(outfit='dress',view='side'),
        take('relaxed-jump',1.2,'same input and physics | ordinary F jump / absorption',jump=True),
        setup(outfit='dress',view='front',stance=True),
        take('combat-jump',1.2,'same input and physics | combat F jump / absorption',jump=True),
        setup(center=False,deck_edge=True,outfit='dress',view='route'),
        take('ledge',1.5,'same EXISTING deck | step OFF, not a launch',press=['move_right','walk_slow']),
        setup(center=False,route=True,outfit='dress',view='route'),
        take('walk',.6,'same accepted walking keys',press=['move_left','walk_slow']),
        take('jog',1.6,'same accepted jog legs, pelvis, cadence | arms change',release=['walk_slow']),
        take('stop',.4,'same real deceleration / stop',release=['move_left'])]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before',type=Path,required=True)
    parser.add_argument('--after',type=Path,required=True)
    parser.add_argument('--before-pack',default='before57.pck')
    parser.add_argument('--after-pack',default='runtime57.pck')
    args = parser.parse_args()
    for work,pack,label in [(args.before,args.before_pack,'BEFORE c9d24b1'),
                            (args.after,args.after_pack,'AFTER R57')]:
        work.mkdir(parents=True,exist_ok=True)
        config = {'pack':pack,'hashes':str(work/'source-hashes.json'),
            'out':str(work/'captures-comparison'),'sample_ticks':6,'coverage':'subject-comparison',
            'title':label+' | ACTUAL GAME CONTROLLERS','timeline':timeline(),
            'viewport':{'width':800,'height':450}}
        path = work/'subject-comparison.json'
        path.write_text(json.dumps(config,indent=2)+'\n')
        print(path)


if __name__=='__main__': main()
