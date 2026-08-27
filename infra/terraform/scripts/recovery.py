#!/usr/bin/env python3
"""Bounded, operator-confirmed replay of immutable DynamoDB events to Firehose."""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from typing import Any


READ_PAGE_LIMIT = 1
SEND_INTERVAL_SECONDS = 1
MAX_WINDOW_HOURS = 24
LOCK_JOB_ID = "__active_lock__"
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


class RecoveryError(RuntimeError):
    pass


class AwsCli:
    def __init__(self, region: str):
        self.region = region

    def run(self, service: str, *args: str, payload: dict | None = None) -> dict:
        command = ["aws", service, *args, "--region", self.region, "--output", "json", "--no-cli-pager"]
        if payload is not None:
            command.extend(["--cli-input-json", json.dumps(payload, separators=(",", ":"))])
        result = subprocess.run(command, check=False, text=True, capture_output=True)
        if result.returncode != 0:
            detail = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else "AWS CLI failed"
            raise RecoveryError(detail)
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def put_json_object(self, bucket: str, key: str, value: dict) -> None:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as output:
            json.dump(value, output, separators=(",", ":"), sort_keys=True)
            output.write("\n")
            path = output.name
        try:
            self.run(
                "s3api", "put-object", "--bucket", bucket, "--key", key,
                "--body", path, "--content-type", "application/json",
            )
        finally:
            Path(path).unlink(missing_ok=True)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def parse_timestamp(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise RecoveryError(f"invalid ISO-8601 timestamp: {value}") from exc
    if parsed.tzinfo is None:
        raise RecoveryError("timestamps must include a UTC offset")
    return parsed.astimezone(timezone.utc)


def canonical_timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()


def validate_scope(from_ts: str, to_ts: str, player_id: str) -> tuple[str, str, list[str]]:
    if not ID_PATTERN.fullmatch(player_id):
        raise RecoveryError("player_id must match the portfolio identifier contract")
    start = parse_timestamp(from_ts)
    end = parse_timestamp(to_ts)
    if end < start:
        raise RecoveryError("to_ts must be greater than or equal to from_ts")
    duration_hours = (end - start).total_seconds() / 3600
    if duration_hours > MAX_WINDOW_HOURS:
        raise RecoveryError(f"recovery windows are capped at {MAX_WINDOW_HOURS} hours")
    cursor = start.replace(minute=0, second=0, microsecond=0)
    final_hour = end.replace(minute=0, second=0, microsecond=0)
    hours = []
    while cursor <= final_hour:
        hours.append(cursor.strftime("%Y-%m-%dT%H"))
        cursor = cursor.fromtimestamp(cursor.timestamp() + 3600, tz=timezone.utc)
    return canonical_timestamp(start), canonical_timestamp(end), hours


def encode(value: Any) -> dict:
    if value is None:
        return {"NULL": True}
    if isinstance(value, bool):
        return {"BOOL": value}
    if isinstance(value, int):
        return {"N": str(value)}
    if isinstance(value, str):
        return {"S": value}
    raise TypeError(f"unsupported DynamoDB value: {type(value).__name__}")


def decode(value: dict) -> Any:
    if "S" in value:
        return value["S"]
    if "N" in value:
        number = value["N"]
        return int(number) if "." not in number else float(number)
    if "BOOL" in value:
        return value["BOOL"]
    if "NULL" in value:
        return None
    if "M" in value:
        return {key: decode(item) for key, item in value["M"].items()}
    if "L" in value:
        return [decode(item) for item in value["L"]]
    raise RecoveryError("unsupported DynamoDB response type")


def decode_item(item: dict) -> dict:
    return {key: decode(value) for key, value in item.items()}


def item_map(value: dict) -> dict:
    return {key: encode(item) for key, item in value.items()}


class RecoveryController:
    def __init__(self, aws: AwsCli, config: dict[str, Any]):
        self.aws = aws
        self.config = config

    def get_job(self, job_id: str) -> dict:
        result = self.aws.run(
            "dynamodb", "get-item", "--table-name", self.config["jobs_table"],
            "--key", json.dumps({"job_id": {"S": job_id}}), "--consistent-read",
        )
        if "Item" not in result:
            raise RecoveryError(f"recovery job not found: {job_id}")
        return decode_item(result["Item"])

    def query_source_page(
        self, hour: str, player_id: str, from_ts: str, to_ts: str, cursor_json: str = ""
    ) -> dict:
        args = [
            "--table-name", self.config["events_table"],
            "--index-name", "recovery-by-time",
            "--key-condition-expression", "recovery_pk = :hour",
            "--filter-expression", "player_id = :player",
            "--expression-attribute-values", json.dumps({
                ":hour": {"S": hour},
                ":player": {"S": player_id},
            }),
            "--limit", str(READ_PAGE_LIMIT),
        ]
        if cursor_json:
            args.extend(["--exclusive-start-key", cursor_json])
        return self.aws.run("dynamodb", "query", *args)

    def source_events(self, from_ts: str, to_ts: str, player_id: str, hours: list[str]) -> list[dict]:
        events = []
        for hour in hours:
            cursor = ""
            while True:
                result = self.query_source_page(hour, player_id, from_ts, to_ts, cursor)
                events.extend(
                    event for event in (decode_item(item) for item in result.get("Items", []))
                    if self.event_in_scope(event, from_ts, to_ts, player_id)
                )
                last_key = result.get("LastEvaluatedKey")
                if not last_key:
                    break
                cursor = json.dumps(last_key, separators=(",", ":"), sort_keys=True)
        return events

    @staticmethod
    def event_in_scope(event: dict, from_ts: str, to_ts: str, player_id: str) -> bool:
        if event.get("player_id") != player_id:
            return False
        try:
            recorded = parse_timestamp(event["recorded_at"])
        except (KeyError, RecoveryError):
            raise RecoveryError("source event has an invalid recorded_at")
        return parse_timestamp(from_ts) <= recorded <= parse_timestamp(to_ts)

    def destination_event_ids(self, from_ts: str, to_ts: str, player_id: str) -> set[str]:
        escaped_player = player_id.replace("'", "''")
        query = (
            f'SELECT DISTINCT event_id, recorded_at FROM "{self.config["glue_table"]}" '
            f"WHERE player_id = '{escaped_player}'"
        )
        result = self.aws.run(
            "athena", "start-query-execution",
            "--work-group", self.config["athena_workgroup"],
            "--query-execution-context", f'Database={self.config["glue_database"]}',
            "--query-string", query,
        )
        query_id = result["QueryExecutionId"]
        for _ in range(60):
            status = self.aws.run("athena", "get-query-execution", "--query-execution-id", query_id)
            state = status["QueryExecution"]["Status"]["State"]
            if state == "SUCCEEDED":
                break
            if state in {"FAILED", "CANCELLED"}:
                reason = status["QueryExecution"]["Status"].get("StateChangeReason", state)
                raise RecoveryError(f"Athena inspection failed: {reason}")
            time.sleep(1)
        else:
            self.aws.run("athena", "stop-query-execution", "--query-execution-id", query_id)
            raise RecoveryError("Athena inspection timed out")
        rows = self.aws.run("athena", "get-query-results", "--query-execution-id", query_id)
        values = rows.get("ResultSet", {}).get("Rows", [])[1:]
        event_ids = set()
        start = parse_timestamp(from_ts)
        end = parse_timestamp(to_ts)
        for row in values:
            columns = row.get("Data", [])
            if len(columns) < 2:
                continue
            event_id = columns[0].get("VarCharValue", "")
            recorded_at = columns[1].get("VarCharValue", "")
            if event_id and recorded_at and start <= parse_timestamp(recorded_at) <= end:
                event_ids.add(event_id)
        return event_ids

    def inspect(self, from_ts: str, to_ts: str, player_id: str) -> dict:
        from_ts, to_ts, hours = validate_scope(from_ts, to_ts, player_id)
        source = self.source_events(from_ts, to_ts, player_id, hours)
        source_ids = {event["event_id"] for event in source}
        destination_ids = self.destination_event_ids(from_ts, to_ts, player_id)
        return {
            "player_id": player_id,
            "from_ts": from_ts,
            "to_ts": to_ts,
            "source_count": len(source_ids),
            "destination_count": len(source_ids & destination_ids),
            "missing_count": len(source_ids - destination_ids),
            "missing_event_ids": sorted(source_ids - destination_ids),
        }

    def create(self, job_id: str, from_ts: str, to_ts: str, player_id: str, expected_missing: int) -> dict:
        if not ID_PATTERN.fullmatch(job_id) or job_id == LOCK_JOB_ID:
            raise RecoveryError("job_id must be a safe identifier and cannot use the lock key")
        if expected_missing < 0:
            raise RecoveryError("expected_missing must be zero or greater")
        from_ts, to_ts, hours = validate_scope(from_ts, to_ts, player_id)
        now = utc_now()
        job = {
            "job_id": job_id,
            "status": "PAUSED",
            "pause_reason": "awaiting-operator-confirmation",
            "player_id": player_id,
            "from_ts": from_ts,
            "to_ts": to_ts,
            "hours_json": json.dumps(hours, separators=(",", ":")),
            "hour_index": 0,
            "cursor_json": "",
            "processed_count": 0,
            "scanned_count": 0,
            "checkpoint_sequence": 0,
            "expected_missing_count": expected_missing,
            "created_at": now,
            "updated_at": now,
        }
        self.aws.run(
            "dynamodb", "put-item", "--table-name", self.config["jobs_table"],
            "--item", json.dumps(item_map(job), separators=(",", ":")),
            "--condition-expression", "attribute_not_exists(job_id)",
        )
        self.aws.put_json_object(
            self.config["recovery_bucket"], f"recovery-jobs/{job_id}/definition.json",
            {key: job[key] for key in ("job_id", "player_id", "from_ts", "to_ts", "expected_missing_count", "created_at")},
        )
        return job

    def acquire(self, job: dict) -> None:
        now = utc_now()
        payload = {
            "TransactItems": [
                {"Put": {
                    "TableName": self.config["jobs_table"],
                    "Item": item_map({"job_id": LOCK_JOB_ID, "owner_job_id": job["job_id"], "updated_at": now}),
                    "ConditionExpression": "attribute_not_exists(job_id) OR owner_job_id = :owner",
                    "ExpressionAttributeValues": {":owner": {"S": job["job_id"]}},
                }},
                {"Update": {
                    "TableName": self.config["jobs_table"],
                    "Key": {"job_id": {"S": job["job_id"]}},
                    "UpdateExpression": "SET #status = :running, updated_at = :now, started_at = if_not_exists(started_at, :now) REMOVE pause_reason",
                    "ConditionExpression": "#status = :paused OR #status = :running",
                    "ExpressionAttributeNames": {"#status": "status"},
                    "ExpressionAttributeValues": {
                        ":paused": {"S": "PAUSED"},
                        ":running": {"S": "RUNNING"},
                        ":now": {"S": now},
                    },
                }},
            ]
        }
        self.aws.run("dynamodb", "transact-write-items", payload=payload)

    def active_alarms(self) -> list[str]:
        if not self.config["pause_alarms"]:
            return []
        result = self.aws.run(
            "cloudwatch", "describe-alarms", "--state-value", "ALARM",
            "--alarm-names", *self.config["pause_alarms"],
        )
        return sorted(alarm["AlarmName"] for alarm in result.get("MetricAlarms", []))

    def pause(self, job_id: str, reason: str) -> dict:
        now = utc_now()
        self.aws.run(
            "dynamodb", "update-item", "--table-name", self.config["jobs_table"],
            "--key", json.dumps({"job_id": {"S": job_id}}),
            "--update-expression", "SET #status = :paused, pause_reason = :reason, updated_at = :now",
            "--expression-attribute-names", json.dumps({"#status": "status"}),
            "--expression-attribute-values", json.dumps({
                ":paused": {"S": "PAUSED"},
                ":running": {"S": "RUNNING"},
                ":reason": {"S": reason},
                ":now": {"S": now},
            }),
            "--condition-expression", "#status = :running",
        )
        return self.get_job(job_id)

    @staticmethod
    def replay_record(event: dict, job_id: str) -> dict:
        required = {
            "schema_version", "event_type", "player_id", "event_id", "entity_version",
            "quiz_id", "score", "correct_count", "question_count", "recorded_at",
            "test_run_id", "request_hash", "payload_hash", "body_json", "response_json",
            "recovery_pk", "recovery_sk",
        }
        missing = sorted(required - event.keys())
        if missing:
            raise RecoveryError(f"source event is missing fields: {', '.join(missing)}")
        body = event["body_json"]
        if hashlib.sha256(body.encode("utf-8")).hexdigest() != event["payload_hash"]:
            raise RecoveryError(f"source hash mismatch: {event['event_id']}")
        logical = json.loads(body)
        if logical.get("event_id") != event["event_id"] or logical.get("player_id") != event["player_id"]:
            raise RecoveryError(f"source identity mismatch: {event['event_id']}")
        return {
            **{key: event[key] for key in required},
            "stream_sequence_number": "manual-recovery",
            "pipe_ingestion_time": utc_now(),
            "delivery_source": "manual-recovery",
            "recovery_job_id": job_id,
        }

    def send_event(self, event: dict, job_id: str) -> None:
        if event["player_id"] != self.get_job(job_id)["player_id"]:
            raise RecoveryError("refusing to replay another player's event")
        record = self.replay_record(event, job_id)
        data = base64.b64encode(json.dumps(record, separators=(",", ":"), sort_keys=True).encode()).decode()
        self.aws.run(
            "firehose", "put-record",
            payload={"DeliveryStreamName": self.config["firehose_name"], "Record": {"Data": data}},
        )

    def checkpoint(
        self, job: dict, hour_index: int, cursor_json: str, processed: int, scanned: int, sequence: int
    ) -> dict:
        now = utc_now()
        evidence = {
            "job_id": job["job_id"],
            "player_id": job["player_id"],
            "hour_index": hour_index,
            "processed_count": processed,
            "scanned_count": scanned,
            "checkpoint_sequence": sequence,
            "updated_at": now,
        }
        self.aws.put_json_object(
            self.config["recovery_bucket"],
            f"recovery-jobs/{job['job_id']}/progress/{sequence:06d}.json", evidence,
        )
        self.aws.run(
            "dynamodb", "update-item", "--table-name", self.config["jobs_table"],
            "--key", json.dumps({"job_id": {"S": job["job_id"]}}),
            "--update-expression", (
                "SET hour_index = :hour, cursor_json = :cursor, processed_count = :processed, "
                "scanned_count = :scanned, checkpoint_sequence = :sequence, updated_at = :now"
            ),
            "--expression-attribute-values", json.dumps({
                ":hour": {"N": str(hour_index)},
                ":cursor": {"S": cursor_json},
                ":processed": {"N": str(processed)},
                ":scanned": {"N": str(scanned)},
                ":sequence": {"N": str(sequence)},
                ":now": {"S": now},
                ":running": {"S": "RUNNING"},
            }),
            "--condition-expression", "#status = :running",
            "--expression-attribute-names", json.dumps({"#status": "status"}),
        )
        return self.get_job(job["job_id"])

    def complete(self, job: dict) -> dict:
        now = utc_now()
        payload = {
            "TransactItems": [
                {"Update": {
                    "TableName": self.config["jobs_table"],
                    "Key": {"job_id": {"S": job["job_id"]}},
                    "UpdateExpression": "SET #status = :complete, completed_at = :now, updated_at = :now REMOVE pause_reason",
                    "ConditionExpression": "#status = :running",
                    "ExpressionAttributeNames": {"#status": "status"},
                    "ExpressionAttributeValues": {":complete": {"S": "COMPLETED"}, ":running": {"S": "RUNNING"}, ":now": {"S": now}},
                }},
                {"Delete": {
                    "TableName": self.config["jobs_table"],
                    "Key": {"job_id": {"S": LOCK_JOB_ID}},
                    "ConditionExpression": "owner_job_id = :owner",
                    "ExpressionAttributeValues": {":owner": {"S": job["job_id"]}},
                }},
            ]
        }
        self.aws.run("dynamodb", "transact-write-items", payload=payload)
        completed = self.get_job(job["job_id"])
        self.aws.put_json_object(
            self.config["recovery_bucket"], f"recovery-jobs/{job['job_id']}/completed.json",
            {key: completed[key] for key in ("job_id", "player_id", "processed_count", "scanned_count", "created_at", "completed_at")},
        )
        return completed

    def abort(self, job_id: str, confirmation: str, reason: str) -> dict:
        if confirmation != "I_UNDERSTAND":
            raise RecoveryError("abort requires --confirm-abort I_UNDERSTAND")
        if not reason or len(reason) > 120:
            raise RecoveryError("abort reason must contain 1 to 120 characters")
        job = self.get_job(job_id)
        if job["status"] in {"COMPLETED", "ABORTED"}:
            raise RecoveryError(f"cannot abort a {job['status']} job")
        now = utc_now()
        payload = {
            "TransactItems": [
                {"Update": {
                    "TableName": self.config["jobs_table"],
                    "Key": {"job_id": {"S": job_id}},
                    "UpdateExpression": "SET #status = :aborted, abort_reason = :reason, aborted_at = :now, updated_at = :now REMOVE pause_reason",
                    "ConditionExpression": "#status = :paused OR #status = :running",
                    "ExpressionAttributeNames": {"#status": "status"},
                    "ExpressionAttributeValues": {
                        ":aborted": {"S": "ABORTED"},
                        ":paused": {"S": "PAUSED"},
                        ":running": {"S": "RUNNING"},
                        ":reason": {"S": reason},
                        ":now": {"S": now},
                    },
                }},
                {"Delete": {
                    "TableName": self.config["jobs_table"],
                    "Key": {"job_id": {"S": LOCK_JOB_ID}},
                    "ConditionExpression": "attribute_not_exists(job_id) OR owner_job_id = :owner",
                    "ExpressionAttributeValues": {":owner": {"S": job_id}},
                }},
            ]
        }
        self.aws.run("dynamodb", "transact-write-items", payload=payload)
        aborted = self.get_job(job_id)
        self.aws.put_json_object(
            self.config["recovery_bucket"], f"recovery-jobs/{job_id}/aborted.json",
            {key: aborted[key] for key in ("job_id", "player_id", "processed_count", "created_at", "aborted_at", "abort_reason")},
        )
        return aborted

    def resume(self, job_id: str, confirmation: str, stop_after_records: int | None = None) -> tuple[dict, int]:
        if confirmation != "I_UNDERSTAND":
            raise RecoveryError("resume requires --confirm-resume I_UNDERSTAND")
        if stop_after_records is not None and not 1 <= stop_after_records <= 10:
            raise RecoveryError("stop-after-records must be between 1 and 10")
        job = self.get_job(job_id)
        if job["status"] == "COMPLETED":
            return job, 0
        self.acquire(job)
        job = self.get_job(job_id)
        sent_this_run = 0
        hours = json.loads(job["hours_json"])
        while int(job["hour_index"]) < len(hours):
            alarms = self.active_alarms()
            if alarms:
                paused = self.pause(job_id, f"api-alarm:{','.join(alarms)}")
                return paused, 2
            hour_index = int(job["hour_index"])
            result = self.query_source_page(
                hours[hour_index], job["player_id"], job["from_ts"], job["to_ts"], job["cursor_json"]
            )
            items = [
                event for event in (decode_item(item) for item in result.get("Items", []))
                if self.event_in_scope(event, job["from_ts"], job["to_ts"], job["player_id"])
            ]
            scanned = int(job["scanned_count"]) + int(result.get("ScannedCount", 0))
            processed = int(job["processed_count"])
            for event in items:
                if event["player_id"] != job["player_id"]:
                    raise RecoveryError("query returned an event outside the requested player scope")
                self.send_event(event, job_id)
                processed += 1
                sent_this_run += 1
                time.sleep(SEND_INTERVAL_SECONDS)
            last_key = result.get("LastEvaluatedKey")
            next_hour = hour_index if last_key else hour_index + 1
            next_cursor = json.dumps(last_key, separators=(",", ":"), sort_keys=True) if last_key else ""
            job = self.checkpoint(
                job, next_hour, next_cursor, processed, scanned, int(job["checkpoint_sequence"]) + 1
            )
            if stop_after_records is not None and sent_this_run >= stop_after_records:
                return self.pause(job_id, "operator-stop-after-records"), 0
        return self.complete(job), 0


def load_config() -> dict[str, Any]:
    names = {
        "jobs_table": "RECOVERY_JOBS_TABLE",
        "events_table": "EVENTS_TABLE",
        "firehose_name": "FIREHOSE_NAME",
        "recovery_bucket": "RECOVERY_BUCKET",
        "athena_workgroup": "ATHENA_WORKGROUP",
        "glue_database": "GLUE_DATABASE",
        "glue_table": "GLUE_TABLE",
    }
    config = {key: os.environ.get(env_name, "") for key, env_name in names.items()}
    missing = [env_name for key, env_name in names.items() if not config[key]]
    if missing:
        raise RecoveryError(f"missing environment variables: {', '.join(missing)}")
    try:
        config["pause_alarms"] = json.loads(os.environ.get("PAUSE_ALARMS_JSON", "[]"))
    except json.JSONDecodeError as exc:
        raise RecoveryError("PAUSE_ALARMS_JSON must be a JSON array") from exc
    if not isinstance(config["pause_alarms"], list) or not all(isinstance(value, str) for value in config["pause_alarms"]):
        raise RecoveryError("PAUSE_ALARMS_JSON must be a JSON string array")
    return config


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    inspect_parser = subparsers.add_parser("inspect")
    create_parser = subparsers.add_parser("create")
    status_parser = subparsers.add_parser("status")
    resume_parser = subparsers.add_parser("resume")
    abort_parser = subparsers.add_parser("abort")
    for item in (inspect_parser, create_parser):
        item.add_argument("--from-ts", required=True)
        item.add_argument("--to-ts", required=True)
        item.add_argument("--player-id", required=True)
    create_parser.add_argument("--job-id", required=True)
    create_parser.add_argument("--expected-missing", required=True, type=int)
    status_parser.add_argument("--job-id", required=True)
    resume_parser.add_argument("--job-id", required=True)
    resume_parser.add_argument("--confirm-resume", required=True)
    resume_parser.add_argument("--stop-after-records", type=int)
    abort_parser.add_argument("--job-id", required=True)
    abort_parser.add_argument("--confirm-abort", required=True)
    abort_parser.add_argument("--reason", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    region = os.environ.get("AWS_REGION", "ap-northeast-2")
    controller = RecoveryController(AwsCli(region), load_config())
    if args.command == "inspect":
        output = controller.inspect(args.from_ts, args.to_ts, args.player_id)
        code = 0
    elif args.command == "create":
        output = controller.create(args.job_id, args.from_ts, args.to_ts, args.player_id, args.expected_missing)
        code = 0
    elif args.command == "status":
        output = controller.get_job(args.job_id)
        code = 0
    elif args.command == "resume":
        output, code = controller.resume(args.job_id, args.confirm_resume, args.stop_after_records)
    else:
        output = controller.abort(args.job_id, args.confirm_abort, args.reason)
        code = 0
    print(json.dumps(output, ensure_ascii=False, sort_keys=True))
    return code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RecoveryError as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), flush=True)
        raise SystemExit(1)
