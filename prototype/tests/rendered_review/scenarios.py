#!/usr/bin/env python3
"""Write the exact rendered-review timelines into an ignored review folder."""
import argparse
import json
from pathlib import Path


def setup(**command):
    return {'setup': {'scene': 'game', 'steps': 35, 'ui': False, **command}}


def take(name, seconds, label, **command):
    return {'take': name, 'ticks': round(seconds*60), 'label': label, 'command': command}


def timelines():
    wardrobe = []
    for outfit in ['dress', 'suit']:
        wardrobe += [setup(route=True, outfit=outfit, view='route'),
            take(outfit+'-idle', .3, outfit+' | idle / original relaxed hands'),
            take(outfit+'-walk', .6, outfit+' | Alt 1.15 m/s', press=['move_left', 'walk_slow']),
            take(outfit+'-jog', .6, outfit+' | jog 2.9 m/s', release=['walk_slow']),
            take(outfit+'-sprint', .6, outfit+' | Shift 5.6 m/s', press=['run']),
            take(outfit+'-stop', .2, outfit+' | stop', release=['move_left', 'run']),
            take(outfit+'-jump', 1., outfit+' | actual F jump / landing', jump=True)]
        for direction, values in [('forward',[0,1]),('back',[0,-1]),('left',[1,0]),('right',[-1,0])]:
            wardrobe += [take(outfit+'-dodge-'+direction,.7,outfit+' | dodge '+direction,dodge=values)]
    strafe = [setup(center=True, outfit='dress', view='three', lock=True),
        take('dress-locked-walk',.6,'dress | locked Alt lateral 1.15 m/s',press=['move_left','walk_slow']),
        take('dress-locked-jog',.6,'dress | locked jog / common foot phase',release=['walk_slow']),
        take('dress-stance-entry',.6,'dress | R while moving, no phase reset',stance=True),
        take('dress-diagonal',.6,'dress | meaningful forward/lateral blend',press=['move_forward']),
        take('dress-retreat',.8,'dress | own backward cycle, faces clone',release=['move_left','move_forward'],press=['move_back']),
        take('dress-side-shift',.8,'dress | locked side Shift 5.6 m/s',release=['move_back'],press=['move_right','run']),
        take('free-combat',.8,'dress | unlock: free combat turns to travel, 5.6 m/s',lock=True),
        setup(center=True, outfit='suit', view='three', lock=True),
        take('suit-lateral',.6,'suit | target-facing left / ordinary stance',press=['move_left']),
        take('suit-diagonal',.6,'suit | R + diagonal blend',press=['move_back'],stance=True),
        take('suit-retreat',.8,'suit | target-facing retreat',release=['move_left']),
        take('suit-side-shift',.6,'suit | target-facing right / Shift',release=['move_back'],press=['move_right','run']),
        setup(wall_fixture=True,outfit='suit',view='wall'),
        take('wall-stop',1.4,'suit | held D + Shift, ACTUAL wall stops gait',press=['move_right','run'])]
    combat=[]
    for outfit in ['dress','suit']:
        reverse=outfit=='suit'
        combat += [setup(pair=True,outfit=outfit,view='pair-reverse' if reverse else 'pair'),
            take(outfit+'-Q',.8,outfit+' | Q left body hook / confirmed torso both actors',clone=True,attack='Q'),
            take(outfit+'-jab',.8,outfit+' | original LMB jab / concurrent flinch',attack='L'),
            take(outfit+'-cross',.8,outfit+' | original RMB cross / AI retreat',attack='R'),
            setup(step_pair=True,outfit=outfit,view='duel-reverse' if reverse else 'duel'),
            take(outfit+'-clone-head',1.,outfit+' | clone on EXISTING stair -> player head',clone=True),
            setup(pair=True,outfit=outfit,view='pair-reverse' if reverse else 'pair'),
            take(outfit+'-jump-preparation',.3,outfit+' | actual F jump, not a floating fixture',jump=True,clone=True),
            take(outfit+'-player-head',1.,outfit+' | falling cross -> confirmed clone head',attack='R')]
    # Complement the short transition/dodge reel with whole gait cycles.
    # Fresh identical route for EACH gait: a long sprint may not silently hit
    # the far wall before both feet completed their cycles. No speed changes.
    gaits = []
    for outfit in ['dress','suit']:
        for gait,seconds,press in [('idle',3.2,[]),('walk',2.4,['move_left','walk_slow']),
                                  ('jog',2.0,['move_left']),('sprint',1.4,['move_left','run'])]:
            gaits += [setup(route=True,outfit=outfit,view='route'),
                take(outfit+'-gaits-'+gait,seconds,outfit+' | full '+gait+' cycles / same pose and light',press=press)]
    smoke=[setup(center=True,outfit='suit',view='game'),
        take('production-camera',.4,'actual game camera / production UI',ui=True),
        take('F3',.2,'actual F3 zone and costume diagnostics',tap=['toggle_debug_details'])]
    return {'wardrobe':wardrobe,'strafe':strafe,'combat':combat,'gaits':gaits,'smoke':smoke}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work',type=Path,required=True)
    p.add_argument('--pack',default='runtime44.pck')
    a=p.parse_args()
    a.work.mkdir(parents=True,exist_ok=True)
    for part,timeline in timelines().items():
        c={'pack':a.pack,'hashes':str(a.work/'source-hashes.json'),'out':str(a.work/('captures-'+part)),
           'sample_ticks':6,'coverage':part,'timeline':timeline,'viewport':{'width':800,'height':450}}
        (a.work/(part+'.json')).write_text(json.dumps(c,indent=2)+'\n')
        print(a.work/(part+'.json'))


if __name__=='__main__':
    main()
