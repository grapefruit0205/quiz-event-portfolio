"""Loopback-only development transport. Test tokens are public fixtures, NOT auth."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
from pathlib import Path
from urllib.parse import urlsplit
import uuid

from .handler import build_handler, error_response
from .quiz import ApiError, MAX_BODY_BYTES
from .storage import SQLiteStore

LOCAL_PRINCIPALS = {"local:alice": "alice", "local:bob": "bob"}
LOCAL_TOKENS = {"Bearer local-alice": "local:alice", "Bearer local-bob": "local:bob"}
WEB_DIR = Path(__file__).with_name("web")
STATIC_ROUTES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/assets/app.css": ("app.css", "text/css; charset=utf-8"),
    "/assets/app.js": ("app.js", "text/javascript; charset=utf-8"),
}
CONTENT_SECURITY_POLICY = (
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'none'; "
    "connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
)


def make_server(db_path: str | Path, port: int = 8765):
    if os.environ.get("AWS_LAMBDA_FUNCTION_NAME") or os.environ.get("AWS_EXECUTION_ENV", "").startswith("AWS_Lambda"):
        raise RuntimeError("Local test server/storage must not run in AWS Lambda.")
    application = build_handler(SQLiteStore(db_path), LOCAL_PRINCIPALS)

    class HTTPHandler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def log_message(self, *_args):
            pass  # Application logs contain only generated IDs and outcome, not request headers.

        def send_bytes(self, status, data, headers):
            self.send_response(status)
            for name, value in headers.items():
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            self.close_connection = True

        def send_result(self, result):
            self.send_bytes(
                result["statusCode"],
                result["body"].encode("utf-8"),
                result["headers"],
            )

        def send_static(self, filename, content_type):
            try:
                data = (WEB_DIR / filename).read_bytes()
            except OSError as exc:
                raise ApiError(503, "UI_UNAVAILABLE", "로컬 UI 파일을 읽을 수 없습니다.") from exc
            self.send_bytes(200, data, {
                "Content-Type": content_type,
                "Cache-Control": "no-store",
                "Content-Security-Policy": CONTENT_SECURITY_POLICY,
                "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
                "X-Frame-Options": "DENY",
            })

        def dispatch(self):
            try:
                expected_hosts = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
                hosts = self.headers.get_all("Host", [])
                if len(hosts) != 1 or hosts[0].lower() not in expected_hosts:
                    raise ApiError(403, "LOCAL_ONLY", "루프백 Host만 허용합니다.")
                expected_origins = {
                    f"http://127.0.0.1:{self.server.server_port}",
                    f"http://localhost:{self.server.server_port}",
                }
                origins = self.headers.get_all("Origin", [])
                if len(origins) > 1 or (origins and origins[0].lower() not in expected_origins):
                    raise ApiError(403, "LOCAL_ONLY", "같은 로컬 주소에서 시작한 브라우저 요청만 허용합니다.")
                parsed = urlsplit(self.path)
                static = STATIC_ROUTES.get(parsed.path)
                if self.command in {"GET", "HEAD"} and not parsed.query and static is not None:
                    self.send_static(*static)
                    return
                if self.headers.get("Transfer-Encoding") is not None:
                    raise ApiError(400, "INVALID_REQUEST", "Transfer-Encoding은 지원하지 않습니다.")
                lengths = self.headers.get_all("Content-Length", [])
                if len(lengths) > 1:
                    raise ApiError(400, "INVALID_REQUEST", "Content-Length 중복은 허용하지 않습니다.")
                value = lengths[0] if lengths else "0"
                if not value.isascii() or not value.isdecimal():
                    raise ApiError(400, "INVALID_REQUEST", "유효한 Content-Length가 필요합니다.")
                length = int(value)
                if length > MAX_BODY_BYTES:
                    raise ApiError(413, "BODY_TOO_LARGE", "본문은 16 KiB 이하여야 합니다.")
                data = self.rfile.read(length)
                if len(data) != length:
                    raise ApiError(400, "INVALID_REQUEST", "본문을 끝까지 받지 못했습니다.")
                body = data.decode("utf-8")
                auth = self.headers.get_all("Authorization", [])
                principal = LOCAL_TOKENS.get(auth[0]) if len(auth) == 1 else None
                event = {
                    "httpMethod": self.command, "path": parsed.path,
                    "headers": dict(self.headers.items()), "body": body,
                    "isBase64Encoded": False,
                    "queryStringParameters": {"unsupported": parsed.query} if parsed.query else None,
                    "requestContext": {"identity": {"userArn": principal}},
                }
                self.send_result(application(event, None))
            except UnicodeError:
                self.send_result(error_response(ApiError(400, "INVALID_JSON", "UTF-8 본문이 필요합니다."), str(uuid.uuid4())))
            except ApiError as exc:
                self.send_result(error_response(exc, str(uuid.uuid4())))
            except (TimeoutError, ConnectionError):
                self.close_connection = True

        do_GET = dispatch
        do_HEAD = dispatch
        do_POST = dispatch
        do_PUT = dispatch
        do_DELETE = dispatch
        do_PATCH = dispatch
        do_OPTIONS = dispatch

    return ThreadingHTTPServer(("127.0.0.1", port), HTTPHandler)


def main():
    parser = argparse.ArgumentParser(description="로컬 전용 퀴즈 서버 — AWS 배포 아님")
    parser.add_argument("--db", default=".local/quiz.sqlite3")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("port must be 0..65535")
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    server = make_server(args.db, args.port)
    print(json.dumps({"event": "local_server_ready", "url": f"http://127.0.0.1:{server.server_port}",
                      "db": str(Path(args.db).resolve()), "aws": False}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
