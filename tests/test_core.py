import json
import os
import pathlib
import subprocess
import tempfile
import unittest

BINARY = pathlib.Path(__file__).resolve().parents[1] / 'build/DiskScope.app/Contents/MacOS/DiskScope'

class ScanTests(unittest.TestCase):
    def scan(self, path):
        return json.loads(subprocess.check_output([str(BINARY), '--scan-json', str(path)]))

    def test_allocated_size_hardlinks_symlinks_hidden_and_sparse(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'node_modules/pkg').mkdir(parents=True)
            (root / 'node_modules/pkg/index.js').write_bytes(b'x' * 20000)
            (root / '.hidden').write_bytes(b'h' * 10000)
            os.link(root / '.hidden', root / 'hardlink')
            os.symlink(root, root / 'cycle')
            with (root / 'sparse.dmg').open('wb') as f:
                f.truncate(1_000_000_000)
            result = self.scan(root)
            nodes = result['nodes']
            by_path = {n['path']: n for n in nodes}
            self.assertFalse(result['limited'])
            self.assertEqual(result['skipped'], 0)
            self.assertEqual(len(nodes), 8)
            self.assertTrue(by_path[str(root / 'cycle')]['symlink'])
            self.assertFalse(by_path[str(root / 'cycle')]['directory'])
            sparse = by_path[str(root / 'sparse.dmg')]
            self.assertEqual(sparse['logical'], 1_000_000_000)
            self.assertLess(sparse['size'], 100000)
            self.assertIn('Node.js', by_path[str(root / 'node_modules/pkg/index.js')]['tags'])
            self.assertEqual(by_path[str(root / 'node_modules/pkg/index.js')]['category'], 'Dev')
            du = int(subprocess.check_output(['/usr/bin/du', '-sk', str(root)]).split()[0]) * 1024
            self.assertLessEqual(abs(nodes[0]['size'] - du), 1024)
            hard_sizes = [by_path[str(root / n)]['size'] for n in ['.hidden', 'hardlink']]
            self.assertEqual(sum(hard_sizes), os.lstat(root / '.hidden').st_blocks * 512)

    def test_empty_and_unicode(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / '中文文件夹').mkdir()
            (root / '中文文件夹/测试.pdf').write_bytes(b'test')
            result = self.scan(root)
            self.assertEqual(result['nodes'][0]['count'], 3)
            self.assertEqual(result['nodes'][-1]['category'], 'Doc')

    def test_model_weights_are_other_and_keep_ai_filter(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            for name in ['model.safetensors', 'model.gguf', 'loader.py']:
                (root / name).write_bytes(b'x' * 4096)
            nodes = {n['name']: n for n in self.scan(root)['nodes']}
            for name in ['model.safetensors', 'model.gguf']:
                self.assertEqual(nodes[name]['category'], 'Other')
                self.assertIn('AI Models', nodes[name]['tags'])
            self.assertEqual(nodes['loader.py']['category'], 'Dev')

    def test_browse_search_filters_and_pagination(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'node_modules').mkdir()
            (root / 'node_modules/index.js').write_bytes(b'x' * 16000)
            (root / 'video.mp4').write_bytes(b'v' * 20000)
            (root / '中文.pdf').write_bytes(b'd' * 2000)
            def service(action, args):
                return json.loads(subprocess.check_output([str(BINARY), '--service-json', action, folder, json.dumps(args)]))
            browser = service('browse', {'node': 0})
            self.assertEqual(len(browser['children']), 3)
            self.assertEqual(browser['totalChildren'], 3)
            self.assertEqual(len(service('browse', {'node': 0, 'offset': 2})['children']), 1)
            filtered = service('search', {'filters': ['Node.js']})
            self.assertEqual(filtered['total'], 2)
            self.assertTrue(all('Node.js' in n['tags'] for n in filtered['rows']))
            self.assertEqual(service('search', {'query': '中文'})['total'], 1)
            self.assertEqual(service('search', {'type': 'Video'})['rows'][0]['name'], 'video.mp4')
            large = service('search', {'large': True})
            self.assertTrue(all(not n['directory'] for n in large['rows']))
            self.assertEqual(large['rows'][0]['name'], 'video.mp4')

    def test_tree_budget_preserves_top_level_siblings(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'many-files').mkdir()
            for i in range(60):
                sub = root / 'many-files' / str(i)
                sub.mkdir()
                for j in range(16):
                    (sub / f'{j}.js').write_bytes(b'x' * 4096)
            (root / 'second-folder').mkdir()
            (root / 'second-folder/movie.mp4').write_bytes(b'v' * 100000)
            (root / 'third.pdf').write_bytes(b'd' * 4000)
            output = json.loads(subprocess.check_output([str(BINARY), '--service-json', 'browse', folder, '{"node":0}']))
            self.assertEqual({e['name'] for e in output['tree']['children']}, {'many-files', 'second-folder', 'third.pdf'})
            def count(n): return 1 + sum(count(c) for c in n.get('children', []))
            self.assertLessEqual(count(output['tree']), 1400)

if __name__ == '__main__': unittest.main(verbosity=2)
