#!/usr/bin/env python3
"""R57 subject clothing, actual jump/drop/jog/kick controller evidence.

No production root/pose injection, retiming, platform, camera or floor edit.
Only documented starting fixtures, inputs, observer views and UI visibility.
Use with CURRENT make_pack.py --driver game. Cadence is simulation cadence,
not wall-clock performance. Every take is encoded at 1x, without interpolation.
"""
import argparse
import json
from pathlib import Path


def setup(**command):
    return {'setup': {'scene':'game','center':True,'steps':35,'ui':False,**command}}


def take(name, seconds, label, **command):
    return {'take':name,'ticks':round(seconds*60),'label':label,'command':command}


def timelines():
    air, kicks, jog, contact, plant = [], [], [], [], []
    for outfit in ['dress','suit']:
        for combat in [False,True]:
            stance = 'combat' if combat else 'relaxed'
            label = outfit+' / '+stance
            for moving in [False,True]:
                route = 'moving' if moving else 'stationary'
                air += [setup(outfit=outfit,stance=combat,view='route' if moving else 'side')]
                if moving:
                    air += [{'setup':{'press':['move_left'],'steps':18}}]
                air += [take(label+'-'+route,1.25,label+' | '+route+' F jump -> actual contact / absorption',jump=True)]
            air += [setup(center=False,deck_edge=True,outfit=outfit,stance=combat,view='route'),
                take(label+'-ledge',1.5,label+' | walk OFF existing 0.72 m deck, no jump',press=['move_right','walk_slow'])]
            # Same real launch/contact in the UNMODIFIED approved camera.
            air += [setup(outfit=outfit,stance=combat,view='game',ui=True),
                take(label+'-ordinary-camera',1.25,label+' | approved ordinary camera, no framing changes',jump=True)]
            contact += [setup(outfit=outfit,stance=combat,view='feet-side'),
                take(label+'-idle-feet',.2,label+' | real idle / CLOSE SIDE, original shadows'),
                {'setup':{'jump':True,'steps':75}},
                take(label+'-land-feet',.2,label+' | settled AFTER actual F jump / CLOSE SIDE'),
                {'setup':{'view':'feet-back'}},
                take(label+'-back-feet',.2,label+' | same live settled feet / CLOSE BACK')]
        for ordinary in [False,True]:
            view = 'game' if ordinary else ('pair-reverse' if outfit=='suit' else 'pair')
            for slot,kind,seconds in [(3,'front_kick',1.1),(4,'low_kick',1.1),(5,'roundhouse',1.5)]:
                label = outfit+' / '+kind+' / '+('approved game camera' if ordinary else 'full pair observer')
                kicks += [setup(center=False,pair=True,outfit=outfit,view=view,ui=ordinary),
                    take(label,seconds,label+' | select '+str(slot+1)+' then LMB; actual active clone',
                         select=slot,attack='L',clone=True)]
        for sprinting in [False,True]:
            gait = 'sprint' if sprinting else 'jog'
            slot = 5 if sprinting else 3
            plant += [setup(center=False,route=True,outfit=outfit,view='route'),
                {'setup':{'press':['move_left']+(['run'] if sprinting else []),'steps':26}},
                take(outfit+'-'+gait+'-plant',1.65,outfit+' | moving '+gait+' -> BRAKE / PLANT -> kick (no target)',
                     release=['move_left','run'],select=slot,attack='L')]
        jog += [setup(center=False,route=True,outfit=outfit,view='route'),
            take(outfit+'-walk',1.1,outfit+' | Alt WALK 1.15 m/s / original accepted legs',press=['move_left','walk_slow']),
            take(outfit+'-jog',1.6,outfit+' | release Alt -> JOG 2.9 m/s / new arm carriage',release=['walk_slow']),
            take(outfit+'-stop',.4,outfit+' | release movement -> real deceleration / stop',release=['move_left']),
            take(outfit+'-reverse',.65,outfit+' | opposite direction / no lock',press=['move_right']),
            take(outfit+'-forward',.65,outfit+' | turn forward / opposite-arm rhythm',release=['move_right'],press=['move_forward']),
            take(outfit+'-stop-again',.4,outfit+' | second real stop',release=['move_forward'])]
    jog += [setup(outfit='suit',view='game',ui=True),
        take('suit-jog-ordinary-camera',1.6,'suit | approved camera / ordinary jog',press=['move_left']),
        take('suit-stop-ordinary-camera',.4,'suit | approved camera / stop',release=['move_left'])]
    return {'subject-air':(3,air),'subject-kicks':(2,kicks),'subject-jog':(3,jog),
            'subject-contact':(3,contact),'subject-plant':(3,plant)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work',type=Path,required=True)
    parser.add_argument('--pack',default='runtime57.pck')
    args = parser.parse_args()
    args.work.mkdir(parents=True,exist_ok=True)
    for part,(step,timeline) in timelines().items():
        config = {'pack':args.pack,'hashes':str(args.work/'source-hashes.json'),
            'out':str(args.work/('captures-'+part)),'sample_ticks':step,'coverage':part,
            'title':'R57 | GODOT 4.7.2 | ACTUAL CONTROLLERS','timeline':timeline,
            'viewport':{'width':800,'height':450}}
        path = args.work/(part+'.json')
        path.write_text(json.dumps(config,indent=2)+'\n')
        print(path)


if __name__=='__main__': main()
