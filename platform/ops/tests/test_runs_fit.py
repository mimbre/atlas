"""runs-fit.py: before an update, every open run of an environment that the running model has
a place for must keep its flow and state in the new model; deploy.sh deploys nothing while
one does not."""
import http.server
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / 'platform/ops/runs-fit.py'
spec = importlib.util.spec_from_file_location('runs_fit', SCRIPT)
runs_fit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runs_fit)

CURRENT = {'issue': ['doing', 'merging', 'review'], 'pr_test': ['testing'], 'decide': ['open']}
FLOWS = {'issue': ['doing', 'review'], 'pr_test': ['testing']}


def run(key, flow, state, status='running'):
    return {'id': key, 'properties': {'flow': flow, 'state': state, 'status': status}}


class Misfits(unittest.TestCase):
    def test_runs_in_the_new_model_fit(self):
        runs = [{'key': 'a', 'flow': 'issue', 'state': 'review', 'status': 'running'}]
        self.assertEqual(runs_fit.misfits(runs, CURRENT, FLOWS), [])

    def test_a_flow_or_state_the_update_removes_does_not(self):
        runs = [
            {'key': 'a', 'flow': 'decide', 'state': 'open', 'status': 'blocked'},
            {'key': 'b', 'flow': 'issue', 'state': 'merging', 'status': 'running'},
            {'key': 'c', 'flow': 'pr_test', 'state': 'testing', 'status': 'running'},
        ]
        lines = runs_fit.misfits(runs, CURRENT, FLOWS)
        self.assertEqual(len(lines), 2)
        self.assertIn('a: flow decide', lines[0])
        self.assertIn('b: state merging is no state of flow issue', lines[1])

    def test_a_run_the_running_model_has_no_place_for_is_not_the_updates(self):
        runs = [
            {'key': 'a', 'flow': 'design_and_accept', 'state': 'designing', 'status': 'active'},
            {'key': 'b', 'flow': 'issue', 'state': 'gone_before', 'status': 'blocked'},
        ]
        self.assertEqual(runs_fit.misfits(runs, CURRENT, FLOWS), [])


class OpenRuns(unittest.TestCase):
    def test_pages_until_has_more_is_false_and_skips_completed_and_ended_runs(self):
        pages = {
            1: {'data': [run('a', 'issue', 'doing'), run('b', 'issue', 'gone', 'completed'),
                         run('d', 'issue', 'gone', 'ended')],
                'meta': {'has_more': True}},
            2: {'data': [run('c', 'decide', 'open', 'blocked')], 'meta': {'has_more': False}},
        }
        asked = []

        def fetch(page):
            asked.append(page)
            return pages[page]

        self.assertEqual(runs_fit.open_runs(fetch), [
            {'key': 'a', 'flow': 'issue', 'state': 'doing', 'status': 'running'},
            {'key': 'c', 'flow': 'decide', 'state': 'open', 'status': 'blocked'},
        ])
        self.assertEqual(asked, [1, 2])

    def test_open_reads_rela_on_loopback(self):
        seen = []

        class Rela(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append(self.path)
                page = int(self.path.rsplit('page=', 1)[1])
                body = {'data': [run(f'r{page}', 'issue', 'doing')], 'meta': {'has_more': page < 2}}
                data = json.dumps(body).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(('127.0.0.1', 0), Rela)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            out = subprocess.run([sys.executable, str(SCRIPT), 'open', str(server.server_address[1])],
                                 capture_output=True, text=True, check=True).stdout
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual([r['key'] for r in json.loads(out)], ['r1', 'r2'])
        self.assertEqual(seen, ['/api/v1/flow_runs?per_page=100&page=1',
                                '/api/v1/flow_runs?per_page=100&page=2'])


class Check(unittest.TestCase):
    def check(self, runs):
        with tempfile.TemporaryDirectory() as tmp:
            files = [Path(tmp, name) for name in ('runs.json', 'current.json', 'new.json')]
            for path, value in zip(files, (runs, CURRENT, FLOWS)):
                path.write_text(json.dumps(value))
            return subprocess.run([sys.executable, str(SCRIPT), 'check', *map(str, files)],
                                  capture_output=True, text=True)

    def test_exits_0_when_all_fit(self):
        result = self.check([{'key': 'a', 'flow': 'issue', 'state': 'doing', 'status': 'running'}])
        self.assertEqual((result.returncode, result.stdout), (0, ''))

    def test_exits_1_listing_what_does_not_fit(self):
        result = self.check([{'key': 'a', 'flow': 'issue', 'state': 'merging', 'status': 'running'}])
        self.assertEqual(result.returncode, 1)
        self.assertIn('a: state merging', result.stdout)

    def test_usage(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
