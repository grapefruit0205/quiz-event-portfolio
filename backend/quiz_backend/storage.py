"""SQLite is a local adapter, not a DynamoDB emulator or AWS deployment backend."""

from contextlib import contextmanager
import json
import sqlite3
from pathlib import Path

from .quiz import ApiError, Submission, canonical_json, content_hash, make_event


class SQLiteStore:
    def __init__(self, path: str | Path):
        if str(path) == ":memory:":
            raise ValueError("Use a local file; each request gets its own connection.")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connection() as conn:
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS players (
                    player_id TEXT PRIMARY KEY,
                    score INTEGER NOT NULL,
                    version INTEGER NOT NULL,
                    latest_event_id TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS events (
                    player_id TEXT NOT NULL,
                    event_id TEXT NOT NULL,
                    request_hash TEXT NOT NULL,
                    payload_hash TEXT NOT NULL,
                    body_json TEXT NOT NULL,
                    response_json TEXT NOT NULL,
                    recovery_pk TEXT NOT NULL,
                    recovery_sk TEXT NOT NULL,
                    PRIMARY KEY (player_id, event_id)
                );
            """)

    @contextmanager
    def connection(self):
        conn = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
        finally:
            conn.close()

    def get_player(self, player_id: str) -> dict:
        try:
            with self.connection() as conn:
                # A single SELECT keeps the state/result view within one snapshot.
                row = conn.execute("""
                    SELECT p.score, p.version, e.response_json
                    FROM players p LEFT JOIN events e
                      ON p.player_id=e.player_id AND p.latest_event_id=e.event_id
                    WHERE p.player_id=?
                """, (player_id,)).fetchone()
                if row is None:
                    return {"player_id": player_id, "score": 0, "version": 0, "latest_result": None}
                if row["response_json"] is None:
                    raise ApiError(503, "STORAGE_INCONSISTENT", "상태와 이력이 일치하지 않습니다.")
                return {"player_id": player_id, "score": row["score"], "version": row["version"],
                        "latest_result": json.loads(row["response_json"])}
        except sqlite3.Error as exc:
            raise ApiError(503, "STORAGE_UNAVAILABLE", "저장소를 사용할 수 없습니다.") from exc

    def submit(self, player_id: str, submission: Submission, correct: int,
               score: int, recorded_at: str) -> tuple[dict, bool]:
        request_hash = content_hash(submission.request_fields(player_id))
        try:
            with self.connection() as conn:
                try:
                    conn.execute("BEGIN IMMEDIATE")
                    old = conn.execute(
                        "SELECT request_hash,response_json FROM events WHERE player_id=? AND event_id=?",
                        (player_id, submission.event_id)).fetchone()
                    if old is not None:
                        if old["request_hash"] != request_hash:
                            raise ApiError(409, "IDEMPOTENCY_CONFLICT", "같은 event_id를 다른 내용으로 재사용할 수 없습니다.")
                        conn.rollback()
                        return json.loads(old["response_json"]), True

                    current = conn.execute("SELECT version FROM players WHERE player_id=?",
                                           (player_id,)).fetchone()
                    version = current["version"] if current is not None else 0
                    if version != submission.expected_version:
                        raise ApiError(409, "VERSION_CONFLICT", "현재 버전을 조회하고 새로운 제출 여부를 확인하세요.")
                    next_version = version + 1
                    event = make_event(player_id, submission, next_version, recorded_at, correct, score)
                    response = {"player_id": player_id, "event_id": submission.event_id,
                                "quiz_id": submission.quiz_id, "score": score, "correct_count": correct,
                                "question_count": event["question_count"], "version": next_version,
                                "recorded_at": recorded_at}
                    conn.execute("""
                        INSERT INTO players(player_id,score,version,latest_event_id) VALUES(?,?,?,?)
                        ON CONFLICT(player_id) DO UPDATE SET score=excluded.score,
                            version=excluded.version,latest_event_id=excluded.latest_event_id
                    """, (player_id, score, next_version, submission.event_id))
                    conn.execute("INSERT INTO events VALUES(?,?,?,?,?,?,?,?)", (
                        player_id, submission.event_id, request_hash, content_hash(event),
                        canonical_json(event), canonical_json(response), recorded_at[:13],
                        f"{recorded_at}#{player_id}#{submission.event_id}"))
                    conn.commit()
                    return response, False
                except Exception:
                    conn.rollback()
                    raise
        except sqlite3.Error as exc:
            raise ApiError(503, "STORAGE_UNAVAILABLE", "저장에 실패했습니다. 같은 요청으로 재시도하세요.") from exc
