"""Small author-tool regressions; no Godot, numpy, browser or network required.

python -m unittest discover -s prototype/tests/rendered_review -p 'test_*.py' -v
All fixtures live in an owned ignored temporary directory, never production.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


class ReviewToolTests(unittest.TestCase):
    def setUp(self):
        local = ROOT/'.local/review'
        local.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='review-tools-', dir=local)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.work = self.base/'work'
        self.work.mkdir()

    def build(self, *extra, work=None):
        return subprocess.run([sys.executable, str(HERE/'make_pack.py'),
            '--godot', str(self.base/'engine-must-not-run'), '--work', str(work or self.work),
            '--output', str(self.base/'review.pck'), *extra],
            capture_output=True, text=True, timeout=10)

    def test_unmarked_project_is_never_removed(self):
        project = self.work/'prototype'
        project.mkdir()
        sentinel = project/'keep.txt'
        sentinel.write_text('user file')
        result = self.build()
        self.assertEqual(result.returncode, 2)
        self.assertIn('unmarked existing project', result.stderr)
        self.assertEqual(sentinel.read_text(), 'user file')

    def test_wrong_owner_is_never_removed(self):
        (self.work/'prototype').mkdir()
        (self.work/'.rendered-review').write_text('another checkout\n')
        result = self.build()
        self.assertEqual(result.returncode, 2)
        self.assertIn('unmarked existing project', result.stderr)
        self.assertEqual((self.work/'.rendered-review').read_text(), 'another checkout\n')

    def test_symlink_destination_is_not_followed_even_with_marker(self):
        target = self.base/'external-project'
        target.mkdir()
        (target/'keep.txt').write_text('external file')
        try:
            (self.work/'prototype').symlink_to(target, target_is_directory=True)
        except OSError as error:
            self.skipTest('OS does not permit creating a directory symlink: '+str(error))
        (self.work/'.rendered-review').write_text(str(ROOT)+'\n')
        result = self.build()
        self.assertEqual(result.returncode, 2)
        self.assertIn('symlinked project destination', result.stderr)
        self.assertEqual((target/'keep.txt').read_text(), 'external file')

    def test_production_and_git_are_rejected(self):
        for work in [ROOT, ROOT/'prototype', ROOT/'.git']:
            with self.subTest(work=work):
                result = self.build(work=work)
                self.assertEqual(result.returncode, 2)
                self.assertIn('--work must be a separate review directory', result.stderr)

    def test_appearance_only_mixing_is_not_presented_as_historical_gameplay(self):
        result = self.build('--driver', 'game', '--baseline-appearance', 'HEAD')
        self.assertEqual(result.returncode, 2)
        self.assertIn('only for the isolated layers diagnostic', result.stderr)

    def test_full_historical_source_cannot_be_silently_mixed_with_appearance_only(self):
        result = self.build('--source-commit','HEAD','--baseline-appearance','HEAD')
        self.assertEqual(result.returncode,2)
        self.assertIn('cannot be combined',result.stderr)

    def test_failed_render_coverage_cannot_be_published_as_a_successful_video(self):
        from assemble import assemble
        manifest = self.base/'failed.json'
        for report in [{'errors':[],'frames':[{}],'coverage_assertions_passed':False},
                       {'errors':[],'frames':[{}]}]:
            manifest.write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError,'coverage assertions'):
                assemble(manifest,self.base/'must-not-exist.mp4')
        self.assertFalse((self.base/'must-not-exist.mp4').exists())

    def test_subject_timelines_have_uniform_true_simulation_cadence(self):
        from subject_scenarios import timelines
        expected = {'subject-air':420,'subject-kicks':444,'subject-jog':232,
                    'subject-contact':48,'subject-plant':132}
        for name,(step,timeline) in timelines().items():
            takes = [x for x in timeline if 'take' in x]
            self.assertTrue(all(x['ticks'] % step == 0 for x in takes))
            self.assertEqual(sum(x['ticks']//step for x in takes),expected[name])
        kick_timeline = timelines()['subject-kicks'][1]
        self.assertEqual({x['command']['select'] for x in kick_timeline if 'take' in x},{3,4,5})
        self.assertTrue(all(x['command']['attack']=='L' for x in kick_timeline if 'take' in x),
                        'real selector then same LMB handler, not a private start-attack hook')

    def test_before_after_rejects_different_physics_observer_and_protected_source(self):
        from copy import deepcopy
        from publish_subject_comparison import validate
        png = self.base/'frame.png'
        png.write_bytes(b'unchanged native PNG placeholder; validation does not decode pixels')
        frame = {'take':'relaxed-jump','ticks':6,'steps':6,'viewport':[800,450],
            'view':'side','yaw':0,'camera_yaw':0,'velocity':[0,1,0],
            'grounded':False,'action':'','action_time':0,'camera_transform':[0]*12,
            'player':{'position':[0,1,0]},'file':str(png),
            'sha256':hashlib.sha256(png.read_bytes()).hexdigest()}
        original = {'errors':[],'coverage_assertions_passed':True,
            'config':{'coverage':'subject-comparison','sample_ticks':6,'timeline':[{'take':'relaxed-jump'}]},
            'frames':[frame],'source_hashes':{k:'unchanged' for k in
                ['world_sha256','lighting_sha256','camera_sha256','model_sha256','clone_sha256','project_sha256']}}
        self.assertEqual(len(validate(original,deepcopy(original))),1)
        for field in ['position','camera_transform','velocity','world_sha256']:
            changed = deepcopy(original)
            if field == 'position': changed['frames'][0]['player'][field][0] = .001
            elif field == 'world_sha256': changed['source_hashes'][field] = 'different'
            else: changed['frames'][0][field][0] = .001
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate(original,changed)

    def trace(self, unknown=False):
        data = {'fps': 10, 'outfit': 'mixed', 'seeks': {}, 'takes': {
            'take/player': [{'outfit': 'dress', 'id': 1}, {'outfit': 'suit', 'id': 2}],
            'take/clone': [{'outfit': 'unknown' if unknown else 'dress', 'id': 3}]}}
        path = self.base/'contact-trace.json'
        path.write_text(json.dumps(data))
        return path, subprocess.run([sys.executable, str(HERE/'split_trace.py'), str(path)],
                                   capture_output=True, text=True, timeout=10)

    def test_splitter_keeps_every_actor_snapshot_exactly_once(self):
        path, result = self.trace()
        self.assertEqual(result.returncode, 0, result.stderr)
        inventories = []
        for outfit in ['dress', 'suit']:
            data = json.loads((self.base/('trace-'+outfit+'.json')).read_text())
            self.assertEqual(data['input_trace_sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(data['input_snapshots'], 3)
            values = [frame for frames in data['takes'].values() for frame in frames]
            self.assertEqual(len(values), data['selected_snapshots'])
            self.assertTrue(all(frame['outfit'] == outfit for frame in values))
            inventories += [frame['id'] for frame in values]
        self.assertEqual(sorted(inventories), [1, 2, 3])

    def test_splitter_rejects_unknown_outfit_instead_of_dropping_it(self):
        _, result = self.trace(unknown=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown/missing outfit', result.stderr)
        self.assertFalse((self.base/'trace-dress.json').exists())
        self.assertFalse((self.base/'trace-suit.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
