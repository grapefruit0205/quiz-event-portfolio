"""Repeatable requests against the actual local HTTP server; no AWS calls."""

import argparse
import json
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
import uuid

DEMO_ANSWERS = [0, 1, 2, 3, 0, 1, 2, 3, 0, 1]  # Public fixture, not an API answer-key leak.


def request(base_url, method, path, body=None, user="alice"):
    headers = {"Content-Type": "application/json"}
    if user is not None:
        headers["Authorization"] = f"Bearer local-{user}"
    data = json.dumps(body).encode() if body is not None else None
    req = Request(base_url + path, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=10) as res:
            return res.status, json.load(res)
    except HTTPError as exc:
        return exc.code, json.load(exc)


def run(base_url: str) -> dict:
    parsed = urlsplit(base_url)
    if (parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost"}
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path not in {"", "/"}):
        raise ValueError("Demo accepts only a local http://127.0.0.1:PORT URL.")
    base_url = base_url.rstrip("/")
    checks = []

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        checks.append({"check": name, "status": "pass"})

    status, quiz = request(base_url, "GET", "/quiz")
    check("문제 10개 조회, 정답 필드 없음", status == 200 and len(quiz["questions"]) == 10
          and all(set(q) == {"question_id", "text", "choices"} for q in quiz["questions"]))
    status, before = request(base_url, "GET", "/players/alice")
    check("내 현재 버전 조회", status == 200)
    run_id = "demo-" + uuid.uuid4().hex[:12]
    body = {"event_id": run_id, "quiz_id": "math-v1", "expected_version": before["version"],
            "answers": DEMO_ANSWERS, "test_run_id": run_id}
    status, saved = request(base_url, "POST", "/players/alice/results", body)
    check("서버 채점·새 제출", status == 201 and saved["score"] == 100 and saved["version"] == before["version"] + 1)
    status, replay = request(base_url, "POST", "/players/alice/results", body)
    check("같은 제출 재시도", status == 200 and replay == saved)
    different = {**body, "answers": [1] + DEMO_ANSWERS[1:]}
    status, error = request(base_url, "POST", "/players/alice/results", different)
    check("같은 ID·다른 내용 거부", status == 409 and error["error"]["code"] == "IDEMPOTENCY_CONFLICT")
    status, _ = request(base_url, "POST", "/players/alice/results", {**body, "score": 999})
    check("클라이언트 점수 필드 거부", status == 400)
    status, bob_before = request(base_url, "GET", "/players/bob", user="bob")
    check("Bob 기준 상태 조회", status == 200)
    status, _ = request(base_url, "POST", "/players/bob/results", body)
    check("Alice의 Bob 변경 거부", status == 403)
    status, bob_after = request(base_url, "GET", "/players/bob", user="bob")
    check("Bob 상태 변경 없음", status == 200 and bob_before == bob_after)
    status, _ = request(base_url, "GET", "/players/alice", user=None)
    check("인증 누락 거부", status == 401)
    status, after = request(base_url, "GET", "/players/alice")
    check("최종 상태·결과 확인", status == 200 and after["latest_result"] == saved
          and after["version"] == before["version"] + 1)
    return {"status": "pass", "test_run_id": run_id, "scope": "local-http-sqlite",
            "aws_tested": False, "checks": checks}


def main():
    parser = argparse.ArgumentParser(description="로컬 퀴즈 API 검증 클라이언트")
    parser.add_argument("--base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--output")
    args = parser.parse_args()
    try:
        report = run(args.base_url)
    except (AssertionError, ValueError, URLError, KeyError) as exc:
        parser.exit(1, f"검증 실패: {exc}\n서버 실행 여부와 README를 확인하세요.\n")
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        path = Path(args.output)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(output, encoding="utf-8")
    print(output, end="")


if __name__ == "__main__":
    main()
