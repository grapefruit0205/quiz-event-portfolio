from http.client import HTTPConnection
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from quiz_backend.demo import run
from quiz_backend.local_server import make_server


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db = Path(self.tmp.name) / "http.sqlite3"
        self.start_server()
        self.addCleanup(self.stop_server)

    def start_server(self):
        self.server = make_server(self.db, 0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def request(self, method="GET", path="/quiz", body=None, headers=None):
        conn = HTTPConnection("127.0.0.1", self.server.server_port, timeout=10)
        try:
            conn.request(method, path, body=body, headers=headers or {"Authorization": "Bearer local-alice"})
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def test_real_http_demo(self):
        report = run(f"http://127.0.0.1:{self.server.server_port}")
        self.assertEqual(report["status"], "pass")
        self.assertFalse(report["aws_tested"])

    def test_restart_preserves_data_and_demo_is_repeatable(self):
        run(f"http://127.0.0.1:{self.server.server_port}")
        _, before = self.request(path="/players/alice")
        self.stop_server()
        self.start_server()
        _, after = self.request(path="/players/alice")
        self.assertEqual(after, before)
        run(f"http://127.0.0.1:{self.server.server_port}")
        _, again = self.request(path="/players/alice")
        self.assertEqual(again["version"], before["version"] + 1)

    def test_nonlocal_host_and_browser_origin_rejected(self):
        for headers in ({"Host": "evil.example", "Authorization": "Bearer local-alice"},
                        {"Origin": "https://evil.example", "Authorization": "Bearer local-alice"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request(headers=headers)[0], 403)

    def test_body_limit(self):
        status, _ = self.request("POST", "/players/alice/results", "x" * 17000,
                                 {"Authorization": "Bearer local-alice", "Content-Type": "application/json"})
        self.assertEqual(status, 413)

    def test_local_mode_refused_in_lambda(self):
        with patch.dict("os.environ", {"AWS_LAMBDA_FUNCTION_NAME": "not-a-real-deployment"}):
            with self.assertRaises(RuntimeError):
                make_server(self.db, 0)


if __name__ == "__main__":
    unittest.main()
