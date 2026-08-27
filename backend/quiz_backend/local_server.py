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

        def send_result(self, result):
            data = result["body"].encode("utf-8")
            self.send_response(result["statusCode"])
            for name, value in result["headers"].items():
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True

        def dispatch(self):
            try:
                expected_hosts = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
                hosts = self.headers.get_all("Host", [])
                if len(hosts) != 1 or hosts[0].lower() not in expected_hosts:
                    raise ApiError(403, "LOCAL_ONLY", "루프백 Host만 허용합니다.")
                if self.headers.get("Origin") is not None:
                    raise ApiError(403, "LOCAL_ONLY", "브라우저 Origin 요청은 이번 CLI 실습에서 허용하지 않습니다.")
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
                parsed = urlsplit(self.path)
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
