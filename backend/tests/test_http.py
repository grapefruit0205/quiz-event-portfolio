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

    def raw_request(self, method="GET", path="/quiz", body=None, headers=None):
        conn = HTTPConnection("127.0.0.1", self.server.server_port, timeout=10)
        request_headers = (
            {"Authorization": "Bearer local-alice"}
            if headers is None else headers
        )
        try:
            conn.request(method, path, body=body, headers=request_headers)
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def request(self, method="GET", path="/quiz", body=None, headers=None):
        status, _headers, data = self.raw_request(method, path, body, headers)
        return status, json.loads(data)

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

    def test_local_web_ui_and_security_headers(self):
        status, headers, body = self.raw_request(path="/", headers={})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "text/html; charset=utf-8")
        self.assertIn("default-src 'self'", headers["Content-Security-Policy"])
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertIn(b"AWS SAP Architecture Lab", body)

        for asset, content_type in (
                ("/assets/app.css", "text/css; charset=utf-8"),
                ("/assets/app.js", "text/javascript; charset=utf-8")):
            with self.subTest(asset=asset):
                asset_status, asset_headers, asset_body = self.raw_request(path=asset, headers={})
                self.assertEqual(asset_status, 200)
                self.assertEqual(asset_headers["Content-Type"], content_type)
                self.assertGreater(len(asset_body), 100)

    def test_same_origin_browser_api_allowed(self):
        origin = f"http://127.0.0.1:{self.server.server_port}"
        status, quiz = self.request(headers={
            "Origin": origin,
            "Authorization": "Bearer local-alice",
        })
        self.assertEqual(status, 200)
        self.assertEqual(quiz["quiz_id"], "aws-sap-architecture-v1")

    def test_nonlocal_host_and_cross_origin_rejected(self):
        cases = (
            {"Host": "evil.example", "Authorization": "Bearer local-alice"},
            {"Origin": "https://evil.example", "Authorization": "Bearer local-alice"},
        )
        for headers in cases:
            with self.subTest(headers=headers):
                self.assertEqual(self.request(headers=headers)[0], 403)

    def test_body_limit(self):
        status, _ = self.request(
            "POST",
            "/players/alice/results",
            "x" * 17000,
            {"Authorization": "Bearer local-alice", "Content-Type": "application/json"},
        )
        self.assertEqual(status, 413)

    def test_local_mode_refused_in_lambda(self):
        with patch.dict("os.environ", {"AWS_LAMBDA_FUNCTION_NAME": "not-a-real-deployment"}):
            with self.assertRaises(RuntimeError):
                make_server(self.db, 0)


if __name__ == "__main__":
    unittest.main()
