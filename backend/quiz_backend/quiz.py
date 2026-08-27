"""Small, fixed quiz and the closed request/event contract."""

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import re

MAX_BODY_BYTES = 16 * 1024
MAX_VERSION = 2**53 - 1
QUIZ_ID = "math-v1"
SCHEMA_VERSION = 2
EVENT_TYPE = "QuizCompleted"
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")

# (question, choices, correct index). A changed question bank needs a new quiz_id.
QUESTIONS = (
    ("2 + 3 = ?", (5, 4, 6, 7), 0),
    ("10 - 4 = ?", (4, 6, 8, 10), 1),
    ("3 × 4 = ?", (6, 9, 12, 15), 2),
    ("20 ÷ 5 = ?", (1, 2, 3, 4), 3),
    ("7 + 8 = ?", (15, 14, 16, 17), 0),
    ("9 - 3 = ?", (3, 6, 9, 12), 1),
    ("2 × 8 = ?", (8, 12, 16, 20), 2),
    ("18 ÷ 3 = ?", (3, 4, 5, 6), 3),
    ("12 + 8 = ?", (20, 18, 22, 24), 0),
    ("25 - 10 = ?", (10, 15, 20, 25), 1),
)


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def canonical_json(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False)


def content_hash(value) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def valid_identifier(value) -> bool:
    return isinstance(value, str) and IDENTIFIER.fullmatch(value) is not None


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(value):
    raise ValueError("non-finite JSON number")


def parse_json(body: str):
    if not isinstance(body, str):
        raise ApiError(400, "INVALID_JSON", "JSON 문자열 본문이 필요합니다.")
    try:
        size = len(body.encode("utf-8"))
    except UnicodeError as exc:
        raise ApiError(400, "INVALID_JSON", "올바른 UTF-8 JSON이 필요합니다.") from exc
    if size > MAX_BODY_BYTES:
        raise ApiError(413, "BODY_TOO_LARGE", "본문은 16 KiB 이하여야 합니다.")
    try:
        return json.loads(body, object_pairs_hook=_unique_object,
                          parse_constant=_reject_constant)
    except (ValueError, RecursionError) as exc:
        raise ApiError(400, "INVALID_JSON", "중복 키 없는 유효한 JSON이 필요합니다.") from exc


@dataclass(frozen=True)
class Submission:
    event_id: str
    quiz_id: str
    expected_version: int
    answers: tuple[int, ...]
    test_run_id: str

    def request_fields(self, player_id: str) -> dict:
        return {
            "schema_version": SCHEMA_VERSION, "event_type": EVENT_TYPE,
            "player_id": player_id, "event_id": self.event_id,
            "quiz_id": self.quiz_id, "expected_version": self.expected_version,
            "answers": list(self.answers), "test_run_id": self.test_run_id,
        }


def validate_submission(value) -> Submission:
    fields = {"event_id", "quiz_id", "expected_version", "answers", "test_run_id"}
    if not isinstance(value, dict) or set(value) != fields:
        raise ApiError(400, "INVALID_FIELDS", "event_id, quiz_id, expected_version, answers, test_run_id만 필요합니다.")
    for name in ("event_id", "test_run_id"):
        if not valid_identifier(value[name]):
            raise ApiError(400, "INVALID_IDENTIFIER", f"{name}: 영숫자로 시작하는 영숫자/_/- 1~64자여야 합니다.")
    if value["quiz_id"] != QUIZ_ID:
        raise ApiError(400, "UNKNOWN_QUIZ", "지원하지 않는 문제 버전입니다.")
    version = value["expected_version"]
    if type(version) is not int or not 0 <= version < MAX_VERSION:
        raise ApiError(400, "INVALID_VERSION", "expected_version은 허용 범위의 정수여야 합니다.")
    answers = value["answers"]
    if (not isinstance(answers, list) or len(answers) != len(QUESTIONS)
            or any(type(a) is not int or not 0 <= a <= 3 for a in answers)):
        raise ApiError(400, "INVALID_ANSWERS", "answers는 문제 순서대로 0~3 정수 10개여야 합니다.")
    return Submission(value["event_id"], value["quiz_id"], version,
                      tuple(answers), value["test_run_id"])


def public_quiz() -> dict:
    return {"quiz_id": QUIZ_ID, "question_count": len(QUESTIONS), "points_per_question": 10,
            "questions": [{"question_id": f"q{i}", "text": text, "choices": list(choices)}
                          for i, (text, choices, _) in enumerate(QUESTIONS, 1)]}


def grade(submission: Submission) -> tuple[int, int]:
    correct = sum(answer == question[2]
                  for answer, question in zip(submission.answers, QUESTIONS, strict=True))
    return correct, correct * 10


def make_event(player_id: str, submission: Submission, version: int,
               recorded_at: str, correct: int, score: int) -> dict:
    return {
        "schema_version": SCHEMA_VERSION, "event_type": EVENT_TYPE,
        "player_id": player_id, "event_id": submission.event_id,
        "entity_version": version, "quiz_id": submission.quiz_id,
        "answers": list(submission.answers), "correct_count": correct,
        "question_count": len(QUESTIONS), "score": score,
        "occurred_at": recorded_at, "recorded_at": recorded_at,
        "test_run_id": submission.test_run_id,
    }
