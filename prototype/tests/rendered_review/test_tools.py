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

    def test_historical_gameplay_is_not_offered(self):
        result = self.build('--driver', 'game', '--baseline-appearance', 'HEAD')
        self.assertEqual(result.returncode, 2)
        self.assertIn('only for the isolated layers diagnostic', result.stderr)

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
