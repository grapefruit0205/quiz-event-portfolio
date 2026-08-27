"""Storage adapters for the local exercise and the deployed AWS runtime."""

from contextlib import contextmanager
import json
import sqlite3
from pathlib import Path

from .quiz import ApiError, Submission, canonical_json, content_hash, make_event


def _ddb_encode(value):
    """Encode the small, closed event schema for the low-level DynamoDB client."""
    if value is None:
        return {"NULL": True}
    if type(value) is bool:
        return {"BOOL": value}
    if type(value) is int:
        return {"N": str(value)}
    if isinstance(value, str):
        return {"S": value}
    if isinstance(value, (list, tuple)):
        return {"L": [_ddb_encode(item) for item in value]}
    if isinstance(value, dict):
        return {"M": {str(key): _ddb_encode(item) for key, item in value.items()}}
    raise TypeError(f"Unsupported DynamoDB value type: {type(value).__name__}")


def _ddb_decode(value):
    if "NULL" in value:
        return None
    if "BOOL" in value:
        return value["BOOL"]
    if "N" in value:
        number = value["N"]
        return int(number) if "." not in number else float(number)
    if "S" in value:
        return value["S"]
    if "L" in value:
        return [_ddb_decode(item) for item in value["L"]]
    if "M" in value:
        return {key: _ddb_decode(item) for key, item in value["M"].items()}
    raise ValueError("Unsupported DynamoDB attribute value")


def _ddb_item(value: dict) -> dict:
    return {key: _ddb_encode(item) for key, item in value.items()}


def _plain_item(value: dict | None) -> dict | None:
    if value is None:
        return None
    return {key: _ddb_decode(item) for key, item in value.items()}


def _aws_error_code(exc: Exception) -> str:
    response = getattr(exc, "response", None)
    if isinstance(response, dict):
        error = response.get("Error")
        if isinstance(error, dict) and isinstance(error.get("Code"), str):
            return error["Code"]
    return type(exc).__name__


class DynamoDBStore:
    """Atomic current-state + immutable-event writes using DynamoDB transactions."""

    def __init__(self, players_table: str, events_table: str, client=None):
        if not players_table or not events_table:
            raise ValueError("Both DynamoDB table names are required.")
        if client is None:
            import boto3
            client = boto3.client("dynamodb")
        self.players_table = players_table
        self.events_table = events_table
        self.client = client

    def _get(self, table: str, key: dict) -> dict | None:
        result = self.client.get_item(
            TableName=table,
            Key=_ddb_item(key),
            ConsistentRead=True,
        )
        return _plain_item(result.get("Item"))

    def _event(self, player_id: str, event_id: str) -> dict | None:
        return self._get(self.events_table, {"player_id": player_id, "event_id": event_id})

    @staticmethod
    def _saved_response(event: dict) -> dict:
        try:
            saved = json.loads(event["response_json"])
            logical = json.loads(event["body_json"])
            if (not isinstance(saved, dict) or not isinstance(logical, dict)
                    or content_hash(logical) != event["payload_hash"]
                    or any(event.get(key) != value for key, value in logical.items())):
                raise ValueError("event integrity mismatch")
            expected = {
                "player_id": event["player_id"],
                "event_id": event["event_id"],
                "quiz_id": event["quiz_id"],
                "score": event["score"],
                "correct_count": event["correct_count"],
                "question_count": event["question_count"],
                "version": event["entity_version"],
                "recorded_at": event["recorded_at"],
            }
            if saved != expected:
                raise ValueError("response integrity mismatch")
        except (KeyError, TypeError, ValueError) as exc:
            raise ApiError(503, "STORAGE_INCONSISTENT", "저장된 이력 형식이 올바르지 않습니다.") from exc
        return saved

    def get_player(self, player_id: str) -> dict:
        try:
            player = self._get(self.players_table, {"player_id": player_id})
            if player is None:
                return {"player_id": player_id, "score": 0, "version": 0, "latest_result": None}
            latest_event_id = player.get("latest_event_id")
            if not isinstance(latest_event_id, str) or not latest_event_id:
                raise ApiError(503, "STORAGE_INCONSISTENT", "상태와 이력이 일치하지 않습니다.")
            event = self._event(player_id, latest_event_id)
            if event is None:
                raise ApiError(503, "STORAGE_INCONSISTENT", "상태와 이력이 일치하지 않습니다.")
            return {
                "player_id": player_id,
                "score": player["score"],
                "version": player["version"],
                "latest_result": self._saved_response(event),
            }
        except ApiError:
            raise
        except Exception as exc:
            raise ApiError(503, "STORAGE_UNAVAILABLE", "저장소를 사용할 수 없습니다.") from exc

    def submit(self, player_id: str, submission: Submission, correct: int,
               score: int, recorded_at: str) -> tuple[dict, bool]:
        request_hash = content_hash(submission.request_fields(player_id))
        try:
            old = self._event(player_id, submission.event_id)
            if old is not None:
                if old.get("request_hash") != request_hash:
                    raise ApiError(409, "IDEMPOTENCY_CONFLICT", "같은 event_id를 다른 내용으로 재사용할 수 없습니다.")
                return self._saved_response(old), True

            current = self._get(self.players_table, {"player_id": player_id})
            version = current.get("version", 0) if current is not None else 0
            if version != submission.expected_version:
                raise ApiError(409, "VERSION_CONFLICT", "현재 버전을 조회하고 새로운 제출 여부를 확인하세요.")

            next_version = version + 1
            event = make_event(player_id, submission, next_version, recorded_at, correct, score)
            saved = {
                "player_id": player_id,
                "event_id": submission.event_id,
                "quiz_id": submission.quiz_id,
                "score": score,
                "correct_count": correct,
                "question_count": event["question_count"],
                "version": next_version,
                "recorded_at": recorded_at,
            }
            player_item = {
                "player_id": player_id,
                "score": score,
                "version": next_version,
                "latest_event_id": submission.event_id,
            }
            event_item = {
                **event,
                "request_hash": request_hash,
                "payload_hash": content_hash(event),
                "body_json": canonical_json(event),
                "response_json": canonical_json(saved),
                "recovery_pk": recorded_at[:13],
                "recovery_sk": f"{recorded_at}#{player_id}#{submission.event_id}",
            }
            player_write = {
                "TableName": self.players_table,
                "Item": _ddb_item(player_item),
            }
            if current is None:
                player_write["ConditionExpression"] = "attribute_not_exists(player_id)"
            else:
                player_write.update({
                    "ConditionExpression": "#version = :expected",
                    "ExpressionAttributeNames": {"#version": "version"},
                    "ExpressionAttributeValues": {":expected": _ddb_encode(version)},
                })
            self.client.transact_write_items(TransactItems=[
                {"Put": player_write},
                {"Put": {
                    "TableName": self.events_table,
                    "Item": _ddb_item(event_item),
                    "ConditionExpression": "attribute_not_exists(player_id) AND attribute_not_exists(event_id)",
                }},
            ])
            return saved, False
        except ApiError:
            raise
        except Exception as exc:
            if _aws_error_code(exc) in {"TransactionCanceledException", "ConditionalCheckFailedException"}:
                try:
                    old = self._event(player_id, submission.event_id)
                    if old is not None:
                        if old.get("request_hash") == request_hash:
                            return self._saved_response(old), True
                        raise ApiError(409, "IDEMPOTENCY_CONFLICT", "같은 event_id를 다른 내용으로 재사용할 수 없습니다.")
                    current = self._get(self.players_table, {"player_id": player_id})
                    if (current.get("version", 0) if current is not None else 0) != submission.expected_version:
                        raise ApiError(409, "VERSION_CONFLICT", "현재 버전을 조회하고 새로운 제출 여부를 확인하세요.")
                except ApiError:
                    raise
                except Exception:
                    pass
            raise ApiError(503, "STORAGE_UNAVAILABLE", "저장에 실패했습니다. 같은 요청으로 재시도하세요.") from exc


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
