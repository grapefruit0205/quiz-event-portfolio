#!/usr/bin/env bash
set -euo pipefail

profile="${AWS_PROFILE:-quiz-event-portfolio}"
region="${AWS_REGION:-ap-northeast-2}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$(cd -- "${script_dir}/.." && pwd)"
temp_dir="$(mktemp -d)"
pipe_stopped=false
alarm_forced=false
api_alarm=""
pipe_name=""

cleanup() {
  if [[ "${alarm_forced}" == true && -n "${api_alarm}" ]]; then
    AWS_PROFILE="${profile}" aws cloudwatch set-alarm-state \
      --region "${region}" --alarm-name "${api_alarm}" --state-value OK \
      --state-reason "Step 7 verification cleanup" >/dev/null 2>&1 || true
  fi
  if [[ "${pipe_stopped}" == true && -n "${pipe_name}" ]]; then
    AWS_PROFILE="${profile}" aws pipes start-pipe \
      --region "${region}" --name "${pipe_name}" >/dev/null 2>&1 || true
  fi
  rm -rf "${temp_dir}"
}
trap cleanup EXIT

for command in aws curl python3 terraform; do
  command -v "${command}" >/dev/null || {
    echo "missing command: ${command}" >&2
    exit 1
  }
done

cd "${terraform_dir}"
recovery="$(terraform output -json recovery)"
monitoring="$(terraform output -json monitoring)"
pipeline="$(terraform output -json analysis_pipeline)"
buckets="$(terraform output -json s3_buckets)"

json_value() {
  local expression="$1"
  python3 -c "import json,sys; print(${expression})"
}

jobs_table="$(json_value 'json.load(sys.stdin)["jobs_table_name"]' <<<"${recovery}")"
events_table="$(json_value 'json.load(sys.stdin)["events_table_name"]' <<<"${recovery}")"
operator_role="$(json_value 'json.load(sys.stdin)["operator_role_arn"]' <<<"${recovery}")"
recovery_bucket="$(json_value 'json.load(sys.stdin)["recovery_bucket"]' <<<"${recovery}")"
firehose_name="$(json_value 'json.load(sys.stdin)["firehose_name"]' <<<"${recovery}")"
athena_workgroup="$(json_value 'json.load(sys.stdin)["athena_workgroup"]' <<<"${recovery}")"
glue_database="$(json_value 'json.load(sys.stdin)["glue_database"]' <<<"${recovery}")"
glue_table="$(json_value 'json.load(sys.stdin)["glue_table"]' <<<"${recovery}")"
pause_alarms="$(json_value 'json.dumps(json.load(sys.stdin)["pause_alarm_names"], separators=(",", ":"))' <<<"${recovery}")"
api_alarm="$(json_value 'json.load(sys.stdin)["alarm_names"]["api_high_requests"]' <<<"${monitoring}")"
pipe_name="$(json_value 'json.load(sys.stdin)["pipe_name"]' <<<"${pipeline}")"
raw_bucket="$(json_value 'json.load(sys.stdin)["raw-events"]' <<<"${buckets}")"

credentials="$(AWS_PROFILE="${profile}" aws sts assume-role \
  --region "${region}" --role-arn "${operator_role}" \
  --role-session-name step7-recovery-check \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"
read -r recovery_access recovery_secret recovery_token <<<"${credentials}"

run_recovery() {
  env -u AWS_PROFILE \
    AWS_ACCESS_KEY_ID="${recovery_access}" \
    AWS_SECRET_ACCESS_KEY="${recovery_secret}" \
    AWS_SESSION_TOKEN="${recovery_token}" \
    AWS_REGION="${region}" \
    RECOVERY_JOBS_TABLE="${jobs_table}" \
    EVENTS_TABLE="${events_table}" \
    FIREHOSE_NAME="${firehose_name}" \
    RECOVERY_BUCKET="${recovery_bucket}" \
    ATHENA_WORKGROUP="${athena_workgroup}" \
    GLUE_DATABASE="${glue_database}" \
    GLUE_TABLE="${glue_table}" \
    PAUSE_ALARMS_JSON="${pause_alarms}" \
    "${script_dir}/recovery.py" "$@"
}

state="$(AWS_PROFILE="${profile}" aws pipes describe-pipe \
  --region "${region}" --name "${pipe_name}" --query CurrentState --output text)"
[[ "${state}" == "RUNNING" ]] || {
  echo "FAIL Pipe must start RUNNING, got ${state}" >&2
  exit 1
}
AWS_PROFILE="${profile}" aws pipes stop-pipe --region "${region}" --name "${pipe_name}" >/dev/null
pipe_stopped=true
for _ in $(seq 1 30); do
  state="$(AWS_PROFILE="${profile}" aws pipes describe-pipe \
    --region "${region}" --name "${pipe_name}" --query CurrentState --output text)"
  [[ "${state}" == "STOPPED" ]] && break
  sleep 2
done
[[ "${state}" == "STOPPED" ]] || {
  echo "FAIL Pipe did not stop for the controlled outage" >&2
  exit 1
}
echo "PASS controlled analysis outage: Pipe is STOPPED while the API remains available"

first_api="$(LIVE_EVENT_PREFIX=step7a LIVE_TEST_RUN_ID=step7-outage \
  AWS_PROFILE="${profile}" AWS_REGION="${region}" "${script_dir}/verify_step4.sh")"
second_api="$(LIVE_EVENT_PREFIX=step7b LIVE_TEST_RUN_ID=step7-outage \
  AWS_PROFILE="${profile}" AWS_REGION="${region}" "${script_dir}/verify_step4.sh")"
first_event="$(python3 -c 'import re,sys; m=re.search(r"^LIVE_EVENT_ID=(.+)$",sys.stdin.read(),re.M); print(m.group(1) if m else "")' <<<"${first_api}")"
second_event="$(python3 -c 'import re,sys; m=re.search(r"^LIVE_EVENT_ID=(.+)$",sys.stdin.read(),re.M); print(m.group(1) if m else "")' <<<"${second_api}")"
[[ -n "${first_event}" && -n "${second_event}" && "${first_event}" != "${second_event}" ]] || {
  echo "FAIL controlled events were not created" >&2
  exit 1
}
echo "PASS two API events were accepted and preserved while the analysis Pipe was stopped"

for pair in "first:${first_event}" "second:${second_event}"; do
  label="${pair%%:*}"
  event_id="${pair#*:}"
  AWS_PROFILE="${profile}" aws dynamodb get-item \
    --region "${region}" --table-name "${events_table}" --consistent-read \
    --key "{\"player_id\":{\"S\":\"alice\"},\"event_id\":{\"S\":\"${event_id}\"}}" \
    --output json >"${temp_dir}/${label}.json"
done
read -r from_ts to_ts < <(python3 - "${temp_dir}/first.json" "${temp_dir}/second.json" <<'PY'
from datetime import datetime, timedelta, timezone
import json
import sys

values = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as source:
        value = json.load(source).get("Item", {}).get("recorded_at", {}).get("S")
    if not value:
        raise SystemExit("FAIL recorded_at missing from a controlled source event")
    values.append(datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc))
print((min(values) - timedelta(seconds=1)).isoformat(),
      (max(values) + timedelta(seconds=1)).isoformat())
PY
)

inspected=false
for attempt in $(seq 1 12); do
  if run_recovery inspect --from-ts "${from_ts}" --to-ts "${to_ts}" --player-id alice \
      >"${temp_dir}/inspect.json" 2>"${temp_dir}/inspect.err"; then
    if python3 - "${temp_dir}/inspect.json" "${first_event}" "${second_event}" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source)
expected = {sys.argv[2], sys.argv[3]}
raise SystemExit(0 if value.get("source_count") == 2 and set(value.get("missing_event_ids", [])) == expected else 1)
PY
    then
      inspected=true
      break
    fi
  fi
  echo "WAIT recovery index/Athena inspection attempt ${attempt}/12"
  sleep 3
done
[[ "${inspected}" == true ]] || {
  cat "${temp_dir}/inspect.json" >&2 || true
  cat "${temp_dir}/inspect.err" >&2 || true
  echo "FAIL the exact source/destination gap was not identified" >&2
  exit 1
}
echo "PASS identified the missing period, player, and two event IDs from source vs destination"

missing_count="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["missing_count"])' <"${temp_dir}/inspect.json")"
job_id="step7-$(date -u +%Y%m%dT%H%M%SZ)-$$"
blocked_job_id="${job_id}-blocked"
run_recovery create --job-id "${job_id}" --from-ts "${from_ts}" --to-ts "${to_ts}" \
  --player-id alice --expected-missing "${missing_count}" >"${temp_dir}/created.json"

marker="step7-api-protection-$(date -u +%Y%m%dT%H%M%SZ)-$$"
AWS_PROFILE="${profile}" aws cloudwatch set-alarm-state \
  --region "${region}" --alarm-name "${api_alarm}" --state-value ALARM --state-reason "${marker}"
alarm_forced=true
set +e
run_recovery resume --job-id "${job_id}" --confirm-resume I_UNDERSTAND >"${temp_dir}/alarm-paused.json"
pause_rc=$?
set -e
[[ "${pause_rc}" -eq 2 ]] || {
  echo "FAIL recovery did not use the API alarm pause exit code" >&2
  exit 1
}
python3 - "${temp_dir}/alarm-paused.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source)
if value.get("status") != "PAUSED" or not value.get("pause_reason", "").startswith("api-alarm:"):
    raise SystemExit("FAIL recovery did not pause for the API alarm")
if value.get("processed_count") != 0:
    raise SystemExit("FAIL recovery sent data while the API protection alarm was active")
PY
echo "PASS recovery paused before sending when a normal-API alarm was ALARM"

run_recovery create --job-id "${blocked_job_id}" --from-ts "${from_ts}" --to-ts "${to_ts}" \
  --player-id alice --expected-missing "${missing_count}" >"${temp_dir}/blocked-created.json"
set +e
run_recovery resume --job-id "${blocked_job_id}" --confirm-resume I_UNDERSTAND >"${temp_dir}/blocked-resume.json"
blocked_rc=$?
set -e
[[ "${blocked_rc}" -eq 1 ]] || {
  echo "FAIL a second concurrent recovery job was not rejected" >&2
  exit 1
}
blocked_status="$(run_recovery status --job-id "${blocked_job_id}")"
python3 -c 'import json,sys; assert json.load(sys.stdin)["status"] == "PAUSED"' <<<"${blocked_status}"
echo "PASS the active-job lock rejected a second concurrent recovery job"

AWS_PROFILE="${profile}" aws cloudwatch set-alarm-state \
  --region "${region}" --alarm-name "${api_alarm}" --state-value OK \
  --state-reason "Step 7 API protection rehearsal reset after ${marker}"
alarm_forced=false

recovery_started_epoch="$(date +%s)"
run_recovery resume --job-id "${job_id}" --confirm-resume I_UNDERSTAND \
  --stop-after-records 1 >"${temp_dir}/checkpoint-paused.json"
python3 - "${temp_dir}/checkpoint-paused.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source)
if value.get("status") != "PAUSED" or value.get("pause_reason") != "operator-stop-after-records":
    raise SystemExit("FAIL controlled interruption did not leave a paused checkpoint")
if value.get("processed_count") != 1 or value.get("checkpoint_sequence", 0) < 1:
    raise SystemExit("FAIL first record checkpoint was not persisted")
PY
echo "PASS controlled interruption persisted a one-record checkpoint"

run_recovery resume --job-id "${job_id}" --confirm-resume I_UNDERSTAND >"${temp_dir}/completed.json"
python3 - "${temp_dir}/completed.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source)
if value.get("status") != "COMPLETED" or value.get("processed_count") != 2:
    raise SystemExit("FAIL resumed recovery did not complete exactly two source events")
if value.get("expected_missing_count") != 2:
    raise SystemExit("FAIL recovery job lost its inspected missing-count evidence")
PY
lock_item="$(AWS_ACCESS_KEY_ID="${recovery_access}" AWS_SECRET_ACCESS_KEY="${recovery_secret}" \
  AWS_SESSION_TOKEN="${recovery_token}" AWS_REGION="${region}" \
  aws dynamodb get-item --region "${region}" --table-name "${jobs_table}" \
  --key '{"job_id":{"S":"__active_lock__"}}' --output json)"
if [[ -n "${lock_item}" ]]; then
  python3 -c 'import json,sys; assert "Item" not in json.load(sys.stdin)' <<<"${lock_item}"
fi
echo "PASS operator-confirmed resume completed and released the active-job lock"

found=false
for attempt in $(seq 1 18); do
  AWS_PROFILE="${profile}" aws s3api list-objects-v2 \
    --region "${region}" --bucket "${raw_bucket}" --prefix 'raw/schema_version=2/format=ndjson/' \
    --query 'Contents[].Key' --output json >"${temp_dir}/keys.json"
  python3 - "${temp_dir}/keys.json" >"${temp_dir}/keys.txt" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    print("\n".join(json.load(source) or []))
PY
  : >"${temp_dir}/manual-events.txt"
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    AWS_PROFILE="${profile}" aws s3api get-object --region "${region}" \
      --bucket "${raw_bucket}" --key "${key}" "${temp_dir}/object.gz" >/dev/null
    python3 - "${temp_dir}/object.gz" "${job_id}" >>"${temp_dir}/manual-events.txt" <<'PY'
import gzip
import json
import sys
try:
    with gzip.open(sys.argv[1], "rt", encoding="utf-8") as source:
        for line in source:
            value = json.loads(line)
            if value.get("delivery_source") == "manual-recovery" and value.get("recovery_job_id") == sys.argv[2]:
                print(value.get("event_id", ""))
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    pass
PY
  done <"${temp_dir}/keys.txt"
  if python3 - "${temp_dir}/manual-events.txt" "${first_event}" "${second_event}" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    observed = {line.strip() for line in source if line.strip()}
raise SystemExit(0 if {sys.argv[2], sys.argv[3]} <= observed else 1)
PY
  then
    found=true
    break
  fi
  echo "WAIT manual recovery S3 delivery attempt ${attempt}/18"
  sleep 10
done
[[ "${found}" == true ]] || {
  echo "FAIL manual recovery records did not reach S3 within 180 seconds" >&2
  exit 1
}
echo "PASS both manual-recovery records reached S3 while the Pipe remained stopped"

restored=false
for attempt in $(seq 1 6); do
  if run_recovery inspect --from-ts "${from_ts}" --to-ts "${to_ts}" --player-id alice \
      >"${temp_dir}/restored.json"; then
    if python3 -c 'import json,sys; v=json.load(sys.stdin); assert v["source_count"] == 2 and v["missing_count"] == 0' \
        <"${temp_dir}/restored.json"; then
      restored=true
      break
    fi
  fi
  sleep 3
done
[[ "${restored}" == true ]] || {
  echo "FAIL Athena did not observe the restored event IDs" >&2
  exit 1
}
recovery_rto_seconds="$(( $(date +%s) - recovery_started_epoch ))"
echo "PASS source-to-Athena comparison reports no remaining controlled gap"

evidence_keys="$(AWS_PROFILE="${profile}" aws s3api list-objects-v2 \
  --region "${region}" --bucket "${recovery_bucket}" --prefix "recovery-jobs/${job_id}/" \
  --query 'Contents[].Key' --output json)"
python3 -c 'import json,sys; keys=json.load(sys.stdin) or []; assert any(k.endswith("definition.json") for k in keys); assert any("/progress/" in k for k in keys); assert any(k.endswith("completed.json") for k in keys)' <<<"${evidence_keys}"
echo "PASS versioned S3 evidence contains definition, checkpoints, and completion"

AWS_PROFILE="${profile}" aws pipes start-pipe --region "${region}" --name "${pipe_name}" >/dev/null
for _ in $(seq 1 30); do
  state="$(AWS_PROFILE="${profile}" aws pipes describe-pipe \
    --region "${region}" --name "${pipe_name}" --query CurrentState --output text)"
  [[ "${state}" == "RUNNING" ]] && break
  sleep 2
done
[[ "${state}" == "RUNNING" ]] || {
  echo "FAIL Pipe did not return to RUNNING" >&2
  exit 1
}
pipe_stopped=false
echo "PASS normal Streams-to-Pipe analysis delivery returned to RUNNING"
echo "OBSERVED_SOURCE_RPO_EVENTS=0"
echo "OBSERVED_ANALYSIS_RECOVERY_RTO_SECONDS=${recovery_rto_seconds}"
echo "Step 7 gap detection, bounded replay, pause, checkpoint, resume, and restore verification passed."
