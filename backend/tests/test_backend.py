import base64
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock
from unittest.mock import patch

import quiz_backend.handler as handler_module
from quiz_backend.handler import build_handler, lambda_handler
from quiz_backend.local_server import LOCAL_PRINCIPALS
from quiz_backend.quiz import MAX_BODY_BYTES, MAX_VERSION, QUIZ_ID, content_hash
from quiz_backend.storage import SQLiteStore

ANSWERS = [2, 0, 3, 1, 2, 0, 1, 3, 0, 2]
NOW = "2026-08-27T01:02:03.004Z"


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "quiz.sqlite3"
        self.store = SQLiteStore(self.path)
        self.handler = build_handler(self.store, LOCAL_PRINCIPALS, clock=lambda: NOW)

    def submission(self, event_id="event-001", version=0):
        return {"event_id": event_id, "quiz_id": QUIZ_ID, "expected_version": version,
                "answers": ANSWERS.copy(), "test_run_id": "unit-001"}

    def event(self, body=None, path="/players/alice/results", method="POST", principal="local:alice"):
        return {"httpMethod": method, "path": path, "headers": {"Content-Type": "application/json"},
                "body": json.dumps(body) if body is not None else None, "isBase64Encoded": False,
                "requestContext": {"identity": {"userArn": principal}}}

    def call(self, body=None, **kwargs):
        result = self.handler(self.event(body, **kwargs), None)
        return result["statusCode"], json.loads(result["body"])

    def rows(self, table):
        with self.store.connection() as conn:
            return [dict(row) for row in conn.execute(f"SELECT * FROM {table}")]

    def test_quiz_hides_answer_key(self):
        status, quiz = self.call(path="/quiz", method="GET")
        self.assertEqual(status, 200)
        self.assertEqual(len(quiz["questions"]), 10)
        for q in quiz["questions"]:
            self.assertEqual(set(q), {"question_id", "domain", "text", "choices"})
            self.assertTrue(q["domain"])
            self.assertEqual(len(q["choices"]), 4)
            self.assertTrue(all(isinstance(choice, str) and choice for choice in q["choices"]))

    def test_new_player_read_has_no_write_side_effect(self):
        status, player = self.call(path="/players/alice", method="GET")
        self.assertEqual((status, player["version"], player["latest_result"]), (200, 0, None))
        self.assertEqual(self.rows("players"), [])

    def test_server_grades_and_stores_original_event(self):
        body = self.submission()
        body["answers"][0] = 1
        status, saved = self.call(body)
        self.assertEqual((status, saved["score"], saved["correct_count"], saved["version"]), (201, 90, 9, 1))
        self.assertEqual(len(self.rows("players")), 1)
        event = self.rows("events")[0]
        logical = json.loads(event["body_json"])
        self.assertEqual((logical["schema_version"], logical["event_type"]), (2, "QuizCompleted"))
        self.assertEqual(logical["answers"], body["answers"])
        self.assertEqual(event["payload_hash"], content_hash(logical))
        self.assertEqual(event["recovery_pk"], "2026-08-27T01")
        self.assertEqual(json.loads(event["response_json"]), saved)

    def test_exact_retry_returns_original_body_without_write(self):
        body = self.submission()
        first = self.handler(self.event(body))
        second = self.handler(self.event(body))
        self.assertEqual((first["statusCode"], second["statusCode"]), (201, 200))
        self.assertEqual(json.loads(first["body"]), json.loads(second["body"]))
        self.assertEqual(second["headers"]["X-Idempotent-Replay"], "true")
        self.assertEqual(len(self.rows("events")), 1)
        self.assertEqual(self.rows("players")[0]["version"], 1)

    def test_old_retry_does_not_overwrite_newer_result(self):
        first_body = self.submission()
        _, first = self.call(first_body)
        next_body = self.submission("event-002", 1)
        next_body["answers"] = [(a + 1) % 4 for a in ANSWERS]
        self.assertEqual(self.call(next_body)[0], 201)
        status, replay = self.call(first_body)
        self.assertEqual((status, replay), (200, first))
        player = self.store.get_player("alice")
        self.assertEqual((player["score"], player["version"]), (0, 2))

    def test_id_reuse_with_different_content_conflicts(self):
        body = self.submission()
        self.call(body)
        for key, value in [("answers", [(a + 1) % 4 for a in ANSWERS]),
                           ("expected_version", 1), ("test_run_id", "other-run")]:
            with self.subTest(field=key):
                status, error = self.call({**body, key: value})
                self.assertEqual((status, error["error"]["code"]), (409, "IDEMPOTENCY_CONFLICT"))
        self.assertEqual(len(self.rows("events")), 1)

    def test_wrong_version_changes_neither_table(self):
        self.call(self.submission())
        before = (self.rows("players"), self.rows("events"))
        status, error = self.call(self.submission("event-002", 0))
        self.assertEqual((status, error["error"]["code"]), (409, "VERSION_CONFLICT"))
        self.assertEqual((self.rows("players"), self.rows("events")), before)

    def test_ownership_checked_before_any_storage_operation(self):
        spy = Mock()
        handler = build_handler(spy, LOCAL_PRINCIPALS)
        for method, path in [("GET", "/players/bob"), ("POST", "/players/bob/results")]:
            event = self.event(self.submission(), method=method, path=path)
            event["headers"].update({"X-Player-Id": "bob", "X-Owner": "bob"})
            self.assertEqual(handler(event)["statusCode"], 403)
        self.assertEqual(spy.mock_calls, [])

    def test_missing_or_unknown_identity_rejected(self):
        for principal, expected in [(None, 401), ("", 401), ("unknown", 403)]:
            with self.subTest(principal=principal):
                self.assertEqual(self.call(self.submission(), principal=principal)[0], expected)
        self.assertEqual(self.rows("events"), [])

    def test_assumed_role_identity_maps_to_configured_iam_role(self):
        role = "arn:aws:iam::123456789012:role/quiz-event-portfolio-lab-alice-caller"
        handler = build_handler(self.store, {role: "alice"}, clock=lambda: NOW)
        event = self.event(path="/quiz", method="GET",
                           principal="arn:aws:sts::123456789012:assumed-role/quiz-event-portfolio-lab-alice-caller/test-session")
        self.assertEqual(handler(event)["statusCode"], 200)

    def test_two_users_may_use_same_event_id(self):
        self.assertEqual(self.call(self.submission())[0], 201)
        self.assertEqual(self.call(self.submission(), principal="local:bob", path="/players/bob/results")[0], 201)
        self.assertEqual(len(self.rows("events")), 2)

    def test_invalid_submission_fields_and_types(self):
        cases = [None, [], "string", {}, {**self.submission(), "score": 100},
                 {**self.submission(), "player_id": "alice"},
                 {**self.submission(), "quiz_id": "unknown"},
                 {**self.submission(), "event_id": "../bad"},
                 {**self.submission(), "event_id": "x" * 65}]
        for version in (True, "0", 0.0, -1, MAX_VERSION, None):
            cases.append({**self.submission(), "expected_version": version})
        for answers in ([], ANSWERS[:-1], ANSWERS + [0], "0123012301", None):
            cases.append({**self.submission(), "answers": answers})
        for answer in (True, "0", 0.0, -1, 4, None):
            cases.append({**self.submission(), "answers": [answer] + ANSWERS[1:]})
        for body in cases:
            with self.subTest(body=body):
                status, _ = self.call(body)
                self.assertEqual(status, 400)
        self.assertEqual(self.rows("events"), [])
        self.assertEqual(self.rows("players"), [])

    def test_invalid_json_duplicate_keys_and_nonfinite_numbers(self):
        for raw in ('{', '{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}',
                    '[' * 1100, '"\\ud800"'):
            event = self.event()
            event["body"] = raw
            self.assertEqual(self.handler(event)["statusCode"], 400)

    def test_size_limit_and_content_type(self):
        event = self.event(self.submission())
        event["body"] = " " * (MAX_BODY_BYTES + 1)
        self.assertEqual(self.handler(event)["statusCode"], 413)
        event = self.event(self.submission())
        event["headers"] = {"Content-Type": "text/plain"}
        self.assertEqual(self.handler(event)["statusCode"], 415)

    def test_base64_proxy_input(self):
        event = self.event(self.submission())
        event["body"] = base64.b64encode(event["body"].encode()).decode()
        event["isBase64Encoded"] = True
        self.assertEqual(self.handler(event)["statusCode"], 201)
        event["body"] = "not valid base64!"
        self.assertEqual(self.handler(event)["statusCode"], 400)

    def test_routes_and_query_contract(self):
        self.assertEqual(self.call(path="/missing", method="GET")[0], 404)
        self.assertEqual(self.call(path="/quiz", method="POST")[0], 405)
        event = self.event(method="GET", path="/quiz")
        event["queryStringParameters"] = {"answers": "true"}
        self.assertEqual(self.handler(event)["statusCode"], 400)

    def test_atomic_rollback_if_event_insert_fails(self):
        self.call(self.submission())
        before = (self.rows("players"), self.rows("events"))
        with self.store.connection() as conn:
            conn.execute("""CREATE TRIGGER simulate_storage_error BEFORE INSERT ON events
                            WHEN NEW.event_id='fail-event'
                            BEGIN SELECT RAISE(ABORT,'controlled failure'); END""")
        status, error = self.call(self.submission("fail-event", 1))
        self.assertEqual((status, error["error"]["code"]), (503, "STORAGE_UNAVAILABLE"))
        self.assertEqual((self.rows("players"), self.rows("events")), before)

    def test_concurrent_same_event_is_applied_once(self):
        def submit(_):
            return self.call(self.submission())
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(submit, range(8)))
        self.assertEqual(sorted(status for status, _ in results), [200] * 7 + [201])
        self.assertTrue(all(body == results[0][1] for _, body in results))
        self.assertEqual(len(self.rows("events")), 1)

    def test_concurrent_different_events_respect_expected_version(self):
        def submit(i):
            return self.call(self.submission(f"event-{i}"))[0]
        with ThreadPoolExecutor(max_workers=2) as pool:
            statuses = list(pool.map(submit, range(2)))
        self.assertEqual(sorted(statuses), [201, 409])
        self.assertEqual(len(self.rows("events")), 1)

    def test_persistent_results_after_reopening_store(self):
        _, saved = self.call(self.submission())
        reopened = SQLiteStore(self.path)
        self.assertEqual(reopened.get_player("alice")["latest_result"], saved)

    def test_hash_changes_when_event_content_changes(self):
        self.call(self.submission())
        row = self.rows("events")[0]
        modified = json.loads(row["body_json"])
        modified["score"] = 999
        self.assertNotEqual(content_hash(modified), row["payload_hash"])

    def test_logs_do_not_include_submission_or_token(self):
        event = self.event(self.submission())
        event["headers"]["Authorization"] = "SECRET-TEST-TOKEN"
        with self.assertLogs("quiz_backend", level="INFO") as logs:
            self.handler(event)
        text = "\n".join(logs.output)
        for secret in ("SECRET-TEST-TOKEN", "answers", "event-001"):
            self.assertNotIn(secret, text)

    def test_aws_entrypoint_is_fail_closed(self):
        handler_module._AWS_HANDLER = None
        with patch.dict("os.environ", {}, clear=True):
            result = lambda_handler(self.event(self.submission()), None)
        self.assertEqual(result["statusCode"], 503)
        self.assertEqual(json.loads(result["body"])["error"]["code"], "DEPLOYMENT_NOT_CONFIGURED")

    def test_aws_entrypoint_builds_configured_handler_once(self):
        role = "arn:aws:iam::123456789012:role/alice"
        fake_store = Mock()
        handler_module._AWS_HANDLER = None
        env = {"PLAYERS_TABLE": "players", "EVENTS_TABLE": "events",
               "PRINCIPAL_MAP_JSON": json.dumps({role: "alice"})}
        event = self.event(path="/quiz", method="GET",
                           principal="arn:aws:sts::123456789012:assumed-role/alice/session")
        with patch.dict("os.environ", env, clear=True), \
                patch("quiz_backend.storage.DynamoDBStore", return_value=fake_store) as adapter:
            self.assertEqual(lambda_handler(event, None)["statusCode"], 200)
            self.assertEqual(lambda_handler(event, None)["statusCode"], 200)
        adapter.assert_called_once_with("players", "events")
        handler_module._AWS_HANDLER = None


if __name__ == "__main__":
    unittest.main()
