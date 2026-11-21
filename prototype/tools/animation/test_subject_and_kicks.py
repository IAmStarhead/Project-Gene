"""R57: explicit allowed edits, original legs, fitted shell and new full-body kicks.

Numerical regressions are NOT artistic / rendered acceptance. The frozen
manifest is from c9d24b1, before authoring: every old clip is exact except the
FOUR user-rejected air clips and ONLY the easy jog arm chain. Accepted gait
hips / leg keys have their older independent hashes in test_locomotion.py.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import unittest

import numpy as np
from build_motion_set import MODEL, OUTPUT
from rig_math import Rig
from test_motion_set import sample, flexion
from kick_motion import SPECS

FROZEN = json.loads(Path(__file__).with_name('repair57_protected.json').read_text())


def digest(value, canonical_zero=False):
    def zero(v):
        if isinstance(v,dict): return {k:zero(x) for k,x in v.items()}
        if isinstance(v,list): return [zero(x) for x in v]
        return 0.0 if isinstance(v,float) and v==0 else v
    return hashlib.sha256(json.dumps(zero(value) if canonical_zero else value,
                                     sort_keys=True,separators=(',',':')).encode()).hexdigest()


def assert_protected_motion(test, data):
    keep = [data['bones'].index(n) for n in FROZEN['protected_bones_except_arm_chain']]
    test.assertEqual(len(FROZEN['clips']),35)
    for name,contract in FROZEN['clips'].items():
        c = data['clips'][name]
        payload = c if contract['scope']=='full' else c|{'rotations':[[q[i] for i in keep] for q in c['rotations']]}
        test.assertEqual(digest(payload,True),contract['sha256'],name+' changed outside the user-authorized scope')


class SubjectAndKickTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rig = Rig(MODEL)
        cls.data = json.loads((OUTPUT/'motion_set.json').read_text())
        cls.appearance = json.loads((MODEL.parent/'appearance/lab_uniform.json').read_text())

    def globals(self,name,time):
        return self.rig.globals(*sample(self.data['clips'][name],time))

    def joint(self,g,name):
        return g[self.rig.index[name],:3,3]

    def test_c9d24b1_frozen_complement_of_requested_edits(self):
        assert_protected_motion(self,self.data)
        self.assertEqual(set(self.data['clips'])-set(FROZEN['clips']),
            {'jump_start','jump_up','jump_down','land','jump_start_relaxed','jump_up_relaxed',
             'jump_down_relaxed','land_relaxed',*[s['clip'] for s in SPECS.values()]})

    def test_easy_jog_has_its_own_lower_arm_envelope_not_the_sprint_carriage(self):
        # The requested 80 +/- 10 authoring is deliberately less folded than
        # the old 91 +/- 13 jog. Check the resulting 3D bones, not just params:
        # narrower upper bound replaces the old high-carriage expectation.
        c = self.data['clips']['run_relaxed']
        matrices = np.asarray([self.globals('run_relaxed',t)
                               for t in np.linspace(0,c['duration'],241,endpoint=False)])
        chest = matrices[:,self.rig.index['chest'],:3,:3]
        for side,sign in [('L',1),('R',-1)]:
            shoulder,elbow,wrist = [matrices[:,self.rig.index[n+'.'+side],:3,3]
                                    for n in ['upper_arm','forearm','hand']]
            upper,fore = elbow-shoulder,wrist-elbow
            bends = np.rad2deg(np.arccos(np.clip(np.einsum('ij,ij->i',upper,fore)
                /np.linalg.norm(upper,axis=1)/np.linalg.norm(fore,axis=1),-1,1)))
            self.assertGreater(bends.min(),68,(side,'easy-jog extension stays anatomical'))
            self.assertLess(bends.max(),92,(side,'must not restore folded sprint arms'))
            self.assertLess(wrist[:,1].max(),1.18,(side,'easy jog hands remain low'))
            self.assertGreater(np.ptp(wrist[:,1]),.24,(side,'not a held bag-carrying pose'))
            lateral = sign*np.einsum('ij,ij->i',fore,chest[:,:,0])
            self.assertLess(lateral.min(),-.025,(side,'front hand still travels inward'))
            self.assertLess(lateral.max(),.056,(side,'only modest low-return clearance'))

    def test_dress_skin_hands_floor_support_and_cloth_are_not_silently_reauthored(self):
        frozen = {k:self.appearance[k] for k in ['gown','cloth','coverage','hands','floor_probes','model_sha256','hips_inverse_bind']}
        self.assertEqual(digest(frozen),FROZEN['dress_appearance_sha256'])

    def test_light_two_piece_subject_outfit_and_preserved_skin(self):
        s = self.appearance['suit']
        self.assertEqual(Counter(b['opening'] for b in s['boundaries']),
                         {'neck':1, 'armhole':2, 'top_hem':1, 'waist':1, 'leg_hem':2})
        self.assertTrue({'top','shorts'}.issubset(s['face_groups']))
        self.assertGreaterEqual(s['fit']['ease_m'], .01)
        self.assertLessEqual(s['fit']['max_source_offset_m'], .016)
        colors = np.asarray(s['colors'])
        self.assertGreater(colors.min(), .60)
        self.assertLess(np.ptp(colors,axis=1).max(),.061)
        coverage = s['coverage']
        self.assertGreater(coverage['top_low'],coverage['shorts_high'])
        self.assertGreaterEqual(coverage['skin_overlap'],.018)

    def test_kick_contacts_timings_weight_transfer_and_return(self):
        r = self.rig
        guard = self.globals('guard',0)
        for kind,s in SPECS.items():
            c = self.data['clips'][s['clip']]
            self.assertTrue(c['ground_only'])
            self.assertFalse(c['loop'])
            self.assertEqual(c['impact'],c['windup'])
            self.assertIn(c['windup'],c['times'])
            self.assertIn(c['active_end'],c['times'])
            np.testing.assert_allclose(self.globals(s['clip'],0),guard,atol=2e-7)
            np.testing.assert_allclose(self.globals(s['clip'],c['duration']),guard,atol=2e-7)
            before = self.globals(s['clip'],s['lift']*.85)
            self.assertGreater((1 if s['support']=='L' else -1)*self.joint(before,'hips')[0],.06,
                               'mass must transfer BEFORE the striking foot lifts')
            at = self.globals(s['clip'],s['windup'])
            knee = self.joint(at,'shin.'+s['side'])
            ankle = self.joint(at,'foot.'+s['side'])
            self.assertGreater(ankle[2],.60,kind)
            self.assertLess(flexion(self.joint(at,'thigh.'+s['side']),knee,ankle),50,
                            kind+' must actually extend into contact, not just wave a chambered bent leg')
            self.assertGreater(ankle[1],.80 if kind!='low_kick' else .30)
            self.assertLess(ankle[1],.50 if kind=='low_kick' else 1.15)
            self.assertGreater(self.joint(at,'hand.'+('L' if s['side']=='R' else 'R'))[1],1.25,
                               'free hand keeps its cover while the other balances')
            for t in np.linspace(s['windup'],s['active_end'],121):
                g = self.globals(s['clip'],t)
                for b in ['foot.','toe.']:
                    tip = self.joint(g,b+s['side'])
                    self.assertLessEqual(np.linalg.norm(tip[[0,2]]),s['reach']+.035,
                                         kind+' actual displayed effector cannot leave its own hit envelope mid-contact')
            support_toes = []
            for t in np.linspace(s['lift'],s['replant'],97):
                g = self.globals(s['clip'],t)
                support_toes.append(self.joint(g,'toe.'+s['support']))
                for side in ['L','R']:
                    bend = flexion(*[self.joint(g,b+'.'+side) for b in ['thigh','shin','foot']])
                    self.assertLess(bend,135,kind+' knee plane / re-chamber')
            self.assertLess(np.ptp(np.asarray(support_toes)[:,[0,2]],axis=0).max(),.012,
                            kind+' planted forefoot must pivot, not translate across the floor')
            self.assertGreaterEqual(c['duration']-c['cancel_window'],c['replant'],
                                    'cannot dodge-cancel while the kicking leg is still up')
        strong = self.data['clips'][SPECS['roundhouse']['clip']]
        for s in [SPECS['front_kick'],SPECS['low_kick']]:
            self.assertGreater(strong['windup'],s['windup']+.1)
            self.assertGreater(strong['stamina'],s['stamina'])
            self.assertGreater(strong['damage'],s['damage'])

    def test_air_sets_share_endpoints_and_relaxed_landing_never_visits_guard(self):
        for suffix,home in [('', 'guard'),('_relaxed','idle_relaxed')]:
            names = [n+suffix for n in ['jump_start','jump_up','jump_down','land']]
            np.testing.assert_allclose(self.globals(home,0),self.globals(names[0],0),atol=2e-7)
            for a,b in zip(names,names[1:]):
                np.testing.assert_allclose(self.globals(a,self.data['clips'][a]['duration']),self.globals(b,0),atol=2e-7)
            np.testing.assert_allclose(self.globals(names[-1],self.data['clips'][names[-1]]['duration']),self.globals(home,0),atol=2e-7)
            crest = self.globals(names[1],self.data['clips'][names[1]]['duration'])
            for side in ['L','R']:
                shoulder,elbow,wrist = [self.joint(crest,b+'.'+side) for b in ['upper_arm','forearm','hand']]
                self.assertLess(wrist[1],1.05,'no held defensive forearms at the apex')
                self.assertGreater(wrist[0]*(1 if side=='L' else -1),.255,
                                   'low balancing hands clear the knee-raised hem instead of passing through it')
                self.assertLess(elbow[1],shoulder[1]-.22)
            for t in np.linspace(0,.3,121):
                g = self.globals(names[-1],t)
                if suffix:
                    self.assertLess(self.joint(g,'hand.L')[1],1.02,'relaxed landing never raises fists to the face')


if __name__ == '__main__': unittest.main(verbosity=2)
