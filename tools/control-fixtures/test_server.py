import json
import socket
import subprocess
import sys
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


class ControlFixtureTest(unittest.TestCase):
    def start_server(self, scenario):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        process = subprocess.Popen([sys.executable, str(HERE / 'server.py'), '--scenario', scenario, '--port', str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
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
                return sock.makefile('rwb')
            except ConnectionRefusedError:
                time.sleep(0.1)
        self.fail('fixture server did not start')

    def exchange(self, stream, request):
        stream.write(json.dumps(request).encode() + b'\n')
        stream.flush()
        return json.loads(stream.readline())

    def test_scenarios_and_console_projection(self):
        for scenario, path in [('decision', '/k/decision/D-7'), ('scene', '/k/scene/SC-1'), ('todo', '/k/todo/TD-12'), ('lists', '/k/scene'), ('empty', '/k/scene/empty')]:
            with self.subTest(scenario=scenario):
                stream = self.start_server(scenario)
                welcome = self.exchange(stream, {'op': 'hello', 'env': 'test', 'client': 'tui', 'spec': '999.0.0', 'surface': 'console'})
                self.assertEqual(welcome['surface'], 'console')
                first = json.loads(stream.readline())
                self.assertEqual(first['path'], path)
                self.assertTrue(any(block['type'] == 'console_action' for block in first['blocks']))
                shell = self.exchange(stream, {'op': 'boot'})
                self.assertEqual(shell['initial_to'], path)
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
