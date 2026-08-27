import hashlib
import importlib.util
import json
from pathlib import Path
import unittest


SCRIPT = Path(__file__).parents[1] / "scripts" / "recovery.py"
SPEC = importlib.util.spec_from_file_location("recovery", SCRIPT)
recovery = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(recovery)


class RecoveryGuardrailTests(unittest.TestCase):
    def event(self):
        logical = {
            "schema_version": 2,
            "event_type": "QuizCompleted",
            "player_id": "alice",
            "event_id": "event-1",
        }
        body = json.dumps(logical, separators=(",", ":"), sort_keys=True)
        return {
            **logical,
            "entity_version": 1,
            "quiz_id": "math-v1",
            "score": 70,
            "correct_count": 7,
            "question_count": 10,
            "recorded_at": "2026-08-27T01:59:59.123456+00:00",
            "test_run_id": "step7-test",
            "request_hash": "r" * 64,
            "payload_hash": hashlib.sha256(body.encode()).hexdigest(),
            "body_json": body,
            "response_json": "{}",
            "recovery_pk": "2026-08-27T01",
            "recovery_sk": "2026-08-27T01:59:59.123456+00:00#alice#event-1",
        }

    def test_scope_is_one_player_and_at_most_24_hours(self):
        start, end, hours = recovery.validate_scope(
            "2026-08-27T01:59:59.123456Z", "2026-08-27T02:00:01Z", "alice"
        )
        self.assertEqual(hours, ["2026-08-27T01", "2026-08-27T02"])
        self.assertIn(".123456", start)
        self.assertTrue(end.endswith("+00:00"))
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_scope("2026-08-27T00:00:00Z", "2026-08-28T00:00:01Z", "alice")
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_scope("2026-08-27T00:00:00Z", "2026-08-27T00:01:00Z", "../alice")

    def test_replay_preserves_source_and_marks_manual_delivery(self):
        source = self.event()
        value = recovery.RecoveryController.replay_record(source, "job-1")
        self.assertEqual(value["body_json"], source["body_json"])
        self.assertEqual(value["event_id"], "event-1")
        self.assertEqual(value["delivery_source"], "manual-recovery")
        self.assertEqual(value["recovery_job_id"], "job-1")

    def test_replay_rejects_tampered_hash_and_identity(self):
        source = self.event()
        source["payload_hash"] = "0" * 64
        with self.assertRaises(recovery.RecoveryError):
            recovery.RecoveryController.replay_record(source, "job-1")
        source = self.event()
        source["event_id"] = "other-event"
        with self.assertRaises(recovery.RecoveryError):
            recovery.RecoveryController.replay_record(source, "job-1")

    def test_fixed_rate_and_page_limits_are_small(self):
        self.assertEqual(recovery.READ_PAGE_LIMIT, 1)
        self.assertEqual(recovery.SEND_INTERVAL_SECONDS, 1)
        self.assertEqual(recovery.MAX_WINDOW_HOURS, 24)

    def test_utc_z_and_offset_timestamps_share_the_same_scope(self):
        event = self.event()
        event["recorded_at"] = "2026-08-27T01:59:59.123456Z"
        self.assertTrue(recovery.RecoveryController.event_in_scope(
            event,
            "2026-08-27T01:59:58.123456+00:00",
            "2026-08-27T02:00:00.123456+00:00",
            "alice",
        ))
        self.assertFalse(recovery.RecoveryController.event_in_scope(
            event,
            "2026-08-27T02:00:00+00:00",
            "2026-08-27T02:00:01+00:00",
            "alice",
        ))


if __name__ == "__main__":
    unittest.main()
