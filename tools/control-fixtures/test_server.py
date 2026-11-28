import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


class ControlFixtureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.artifact = Path(cls.temp.name) / 'product.json'
        root = HERE.parents[1]
        subprocess.run(
            ['mix', 'run', '--no-start', str(HERE / 'product_generate.exs'), str(cls.artifact)],
            cwd=root / 'products/software_factory',
            env=dict(os.environ, MIX_ENV='test'),
            check=True, timeout=120,
        )

    def start_server(self, scenario):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        env = dict(os.environ, MIX_ENV='prod', ATLAS_ENV='prod', ATLAS_ENV_FILE='/nonexistent/production.json')
        process = subprocess.Popen([sys.executable, str(HERE / 'server.py'), '--scenario', scenario, '--port', str(port), '--artifact', str(self.artifact)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
        self.addCleanup(process.stderr.close)
        self.addCleanup(lambda: process.wait(timeout=10))
        self.addCleanup(process.terminate)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if process.poll() is not None:
                self.fail(process.stderr.read().decode())
            try:
                sock = socket.create_connection(('127.0.0.1', port), timeout=1)
                sock.settimeout(5)
                self.addCleanup(sock.close)
                stream = sock.makefile('rwb')
                self.addCleanup(stream.close)
                return stream
            except ConnectionRefusedError:
                time.sleep(0.1)
        self.fail('fixture server did not start')

    def exchange(self, stream, request):
        stream.write(json.dumps(request).encode() + b'\n')
        stream.flush()
        return json.loads(stream.readline())

    def test_scenarios_and_console_projection(self):
        for scenario, path in [('decision', '/k/decision/D-7'), ('scene', '/k/scene/SC-1'), ('todo', '/k/to_do/TD-12'), ('lists', '/_open'), ('empty', '/k/issue')]:
            with self.subTest(scenario=scenario):
                stream = self.start_server(scenario)
                welcome = self.exchange(stream, {'op': 'hello', 'env': 'test', 'client': 'tui', 'spec': '999.0.0', 'surface': 'console'})
                self.assertEqual(welcome['surface'], 'console')
                first = json.loads(stream.readline())
                self.assertEqual(first['path'], path)
                if scenario == 'decision':
                    source = HERE.parents[1] / 'products/software_factory/e2e/fixtures/decision-options.json'
                    offer = json.loads(source.read_text())
                    self.assertTrue(any(block['type'] == 'header' and block['props'].get('title') == offer['question'] for block in first['blocks']))
                    self.assertEqual(
                        {block['props']['text'] for block in first['blocks'] if block['type'] == 'option'},
                        {option['text'] for option in offer['options']},
                    )
                elif scenario in {'scene', 'todo'}:
                    title = {'scene': 'Make examples easy to inspect', 'todo': 'Prepare the local examples'}[scenario]
                    self.assertTrue(any(block.get('props', {}).get('title') == title for block in first['blocks']))
                self.assertTrue(any(block['type'] == 'console_action' for block in first['blocks']))
                shell = self.exchange(stream, {'op': 'boot'})
                self.assertEqual(shell['initial_to'], path)
                self.assertEqual(shell['active_tab'], scenario)
                self.assertEqual(len({tab['id'] for tab in shell['tabs']}), len(shell['tabs']))
                self.assertEqual(len({tab['to'] for tab in shell['tabs']}), len(shell['tabs']))
                for tab in shell['tabs']:
                    self.assertRegex(tab['to'], r'^(/_open|/k/[^/]+)$')
                    tab_page = self.exchange(stream, {'op': 'open', 'to': tab['to']})
                    self.assertEqual(tab_page['path'], tab['to'])
                    self.assertEqual(tab_page['reason'], 'open')
                page = self.exchange(stream, {'op': 'open', 'to': path})
                self.assertEqual(page['reason'], 'open')
                refreshed = self.exchange(stream, {'op': 'refresh'})
                self.assertEqual(refreshed['reason'], 'reconcile')
                self.assertEqual(refreshed['path'], path)
                self.assertEqual(self.exchange(stream, {'op': 'boot', 'to': '/missing'})['op'], 'boot')
                self.assertIn('error', self.exchange(stream, {'op': 'boot', 'to': '/missing'}))
                self.assertEqual(self.exchange(stream, {'op': 'submit', 'endpoint': 'answer', 'params': {}, 'values': {}})['op'], 'bye')

    def test_native_projection_and_unknown_page(self):
        stream = self.start_server('scene')
        self.exchange(stream, {'op': 'hello', 'env': 'test', 'client': 'mac', 'spec': '999.0.0'})
        page = json.loads(stream.readline())
        self.assertFalse(any(block['type'] == 'console_action' for block in page['blocks']))
        self.assertEqual(self.exchange(stream, {'op': 'open', 'to': '/missing'})['op'], 'bye')


if __name__ == '__main__':
    unittest.main()
