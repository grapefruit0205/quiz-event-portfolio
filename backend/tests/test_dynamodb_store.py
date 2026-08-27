import json
import unittest

from quiz_backend.quiz import ApiError, grade, validate_submission
from quiz_backend.storage import DynamoDBStore, _plain_item


ANSWERS = [0, 1, 2, 3, 0, 1, 2, 3, 0, 1]
NOW = "2026-08-27T01:02:03.004Z"


class AwsError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class FakeDynamoDB:
    def __init__(self):
        self.tables = {"players": {}, "events": {}}
        self.transact_calls = []
        self.fail_get = False
        self.commit_then_timeout = False

    @staticmethod
    def _key(table, item):
        plain = _plain_item(item)
        if table == "players":
            return plain["player_id"]
        return plain["player_id"], plain["event_id"]

    def get_item(self, TableName, Key, ConsistentRead):
        if self.fail_get:
            raise AwsError("ProvisionedThroughputExceededException")
        assert ConsistentRead is True
        item = self.tables[TableName].get(self._key(TableName, Key))
        return {"Item": item} if item is not None else {}

    def transact_write_items(self, TransactItems):
        self.transact_calls.append(TransactItems)
        player_put = TransactItems[0]["Put"]
        event_put = TransactItems[1]["Put"]
        player_key = self._key("players", player_put["Item"])
        event_key = self._key("events", event_put["Item"])
        current = self.tables["players"].get(player_key)
        if player_put["ConditionExpression"] == "attribute_not_exists(player_id)":
            player_ok = current is None
        else:
            expected = int(player_put["ExpressionAttributeValues"][":expected"]["N"])
            player_ok = current is not None and int(current["version"]["N"]) == expected
        if not player_ok or event_key in self.tables["events"]:
            raise AwsError("TransactionCanceledException")
        self.tables["players"][player_key] = player_put["Item"]
        self.tables["events"][event_key] = event_put["Item"]
        if self.commit_then_timeout:
            self.commit_then_timeout = False
            raise AwsError("TransactionCanceledException")
        return {}


class DynamoDBStoreTests(unittest.TestCase):
    def setUp(self):
        self.client = FakeDynamoDB()
        self.store = DynamoDBStore("players", "events", client=self.client)

    def submission(self, event_id="event-001", version=0, answers=None):
        return validate_submission({
            "event_id": event_id,
            "quiz_id": "math-v1",
            "expected_version": version,
            "answers": ANSWERS.copy() if answers is None else answers,
            "test_run_id": "ddb-unit",
        })

    def submit(self, submission):
        correct, score = grade(submission)
        return self.store.submit("alice", submission, correct, score, NOW)

    def test_new_player_read_has_no_side_effect(self):
        self.assertEqual(self.store.get_player("alice"), {
            "player_id": "alice", "score": 0, "version": 0, "latest_result": None,
        })
        self.assertEqual(self.client.tables, {"players": {}, "events": {}})

    def test_transaction_stores_state_and_immutable_event(self):
        saved, replayed = self.submit(self.submission())
        self.assertFalse(replayed)
        self.assertEqual((saved["score"], saved["version"]), (100, 1))
        player = _plain_item(self.client.tables["players"]["alice"])
        event = _plain_item(self.client.tables["events"][("alice", "event-001")])
        self.assertEqual((player["latest_event_id"], player["version"]), ("event-001", 1))
        self.assertEqual((event["event_type"], event["recovery_pk"]),
                         ("QuizCompleted", "2026-08-27T01"))
        self.assertEqual(json.loads(event["response_json"]), saved)
        self.assertEqual(self.store.get_player("alice")["latest_result"], saved)

    def test_exact_retry_replays_without_second_transaction(self):
        first, _ = self.submit(self.submission())
        second, replayed = self.submit(self.submission())
        self.assertTrue(replayed)
        self.assertEqual(second, first)
        self.assertEqual(len(self.client.transact_calls), 1)

    def test_event_id_reuse_with_other_content_conflicts(self):
        self.submit(self.submission())
        with self.assertRaises(ApiError) as raised:
            self.submit(self.submission(answers=[1] * 10))
        self.assertEqual((raised.exception.status, raised.exception.code),
                         (409, "IDEMPOTENCY_CONFLICT"))

    def test_stale_version_conflicts_without_writes(self):
        self.submit(self.submission())
        before = {name: dict(items) for name, items in self.client.tables.items()}
        with self.assertRaises(ApiError) as raised:
            self.submit(self.submission("event-002", 0))
        self.assertEqual(raised.exception.code, "VERSION_CONFLICT")
        self.assertEqual(self.client.tables, before)

    def test_ambiguous_transaction_result_is_resolved_as_replay(self):
        self.client.commit_then_timeout = True
        saved, replayed = self.submit(self.submission())
        self.assertTrue(replayed)
        self.assertEqual(saved["version"], 1)
        self.assertEqual(len(self.client.tables["events"]), 1)

    def test_storage_error_maps_to_safe_503(self):
        self.client.fail_get = True
        with self.assertRaises(ApiError) as raised:
            self.store.get_player("alice")
        self.assertEqual((raised.exception.status, raised.exception.code),
                         (503, "STORAGE_UNAVAILABLE"))

    def test_player_without_event_pointer_is_reported_inconsistent(self):
        self.client.tables["players"]["alice"] = {
            "player_id": {"S": "alice"}, "score": {"N": "10"}, "version": {"N": "1"},
        }
        with self.assertRaises(ApiError) as raised:
            self.store.get_player("alice")
        self.assertEqual(raised.exception.code, "STORAGE_INCONSISTENT")

    def test_tampered_event_payload_is_reported_inconsistent(self):
        self.submit(self.submission())
        event = self.client.tables["events"][("alice", "event-001")]
        event["score"] = {"N": "999"}
        with self.assertRaises(ApiError) as raised:
            self.store.get_player("alice")
        self.assertEqual(raised.exception.code, "STORAGE_INCONSISTENT")


if __name__ == "__main__":
    unittest.main()
