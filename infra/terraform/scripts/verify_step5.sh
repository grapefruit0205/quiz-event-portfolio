#!/usr/bin/env bash
set -euo pipefail

profile="${AWS_PROFILE:-quiz-event-portfolio}"
region="${AWS_REGION:-ap-northeast-2}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$(cd -- "${script_dir}/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

for command in aws python3 terraform; do
  command -v "${command}" >/dev/null || {
    echo "missing command: ${command}" >&2
    exit 1
  }
done

cd "${terraform_dir}"
pipeline="$(terraform output -json analysis_pipeline)"
buckets="$(terraform output -json s3_buckets)"
tables="$(terraform output -json dynamodb_tables)"
pipe_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pipe_name"])' <<<"${pipeline}")"
firehose_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["firehose_name"])' <<<"${pipeline}")"
dlq_url="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["dlq_url"])' <<<"${pipeline}")"
database="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["glue_database"])' <<<"${pipeline}")"
table="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["glue_table"])' <<<"${pipeline}")"
workgroup="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["athena_workgroup"])' <<<"${pipeline}")"
raw_bucket="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["raw-events"])' <<<"${buckets}")"
events_table="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["events"]["name"])' <<<"${tables}")"

pipe_state="$(AWS_PROFILE="${profile}" aws pipes describe-pipe \
  --region "${region}" --name "${pipe_name}" --query CurrentState --output text)"
[[ "${pipe_state}" == "RUNNING" ]] || {
  echo "FAIL pipe state: ${pipe_state}" >&2
  exit 1
}
echo "PASS pipe is RUNNING"

firehose_state="$(AWS_PROFILE="${profile}" aws firehose describe-delivery-stream \
  --region "${region}" --delivery-stream-name "${firehose_name}" \
  --query DeliveryStreamDescription.DeliveryStreamStatus --output text)"
[[ "${firehose_state}" == "ACTIVE" ]] || {
  echo "FAIL Firehose state: ${firehose_state}" >&2
  exit 1
}
echo "PASS Firehose is ACTIVE"

api_output="$(LIVE_EVENT_PREFIX=step5 LIVE_TEST_RUN_ID=step5-live-check \
  AWS_PROFILE="${profile}" AWS_REGION="${region}" "${script_dir}/verify_step4.sh")"
printf '%s\n' "${api_output}"
event_id="$(python3 -c 'import re,sys; match=re.search(r"^LIVE_EVENT_ID=([A-Za-z0-9_-]+)$", sys.stdin.read(), re.M); print(match.group(1) if match else "")' <<<"${api_output}")"
[[ -n "${event_id}" ]] || {
  echo "FAIL live event id was not returned" >&2
  exit 1
}

AWS_PROFILE="${profile}" aws dynamodb get-item \
  --region "${region}" --table-name "${events_table}" --consistent-read \
  --key "{\"player_id\":{\"S\":\"alice\"},\"event_id\":{\"S\":\"${event_id}\"}}" \
  --output json > "${temp_dir}/ddb.json"

python3 - "${temp_dir}/ddb.json" "${temp_dir}/expected.json" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    item = json.load(source).get("Item")
if not item:
    raise SystemExit("FAIL event is missing from DynamoDB")
plain = {key: next(iter(value.values())) for key, value in item.items()}
body = plain["body_json"]
if hashlib.sha256(body.encode("utf-8")).hexdigest() != plain["payload_hash"]:
    raise SystemExit("FAIL DynamoDB body_json hash mismatch")
logical = json.loads(body)
if logical.get("event_id") != plain["event_id"] or logical.get("player_id") != plain["player_id"]:
    raise SystemExit("FAIL DynamoDB duplicated identity fields mismatch")
with open(sys.argv[2], "w", encoding="utf-8") as target:
    json.dump({
        "player_id": plain["player_id"],
        "event_id": plain["event_id"],
        "payload_hash": plain["payload_hash"],
        "body_json": body,
    }, target)
PY
echo "PASS DynamoDB immutable event and payload hash agree"

found=false
for attempt in $(seq 1 18); do
  AWS_PROFILE="${profile}" aws s3api list-objects-v2 \
    --region "${region}" --bucket "${raw_bucket}" --prefix 'raw/schema_version=2/format=ndjson/' \
    --query 'Contents[].Key' --output json > "${temp_dir}/keys.json"
  python3 - "${temp_dir}/keys.json" > "${temp_dir}/keys.txt" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    for key in json.load(source) or []:
        print(key)
PY
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    object_file="${temp_dir}/object.gz"
    AWS_PROFILE="${profile}" aws s3api get-object \
      --region "${region}" --bucket "${raw_bucket}" --key "${key}" \
      "${object_file}" >/dev/null
    if python3 - "${object_file}" "${event_id}" "${temp_dir}/s3-event.json" <<'PY'
import gzip
import json
import sys
try:
    with gzip.open(sys.argv[1], "rt", encoding="utf-8") as source:
        for line in source:
            value = json.loads(line)
            if value.get("event_id") == sys.argv[2]:
                with open(sys.argv[3], "w", encoding="utf-8") as target:
                    json.dump(value, target)
                raise SystemExit(0)
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    pass
raise SystemExit(1)
PY
    then
      found=true
      break
    fi
  done < "${temp_dir}/keys.txt"
  [[ "${found}" == true ]] && break
  echo "WAIT S3 delivery attempt ${attempt}/18"
  sleep 10
done
[[ "${found}" == true ]] || {
  echo "FAIL event did not reach S3 within 180 seconds" >&2
  exit 1
}

python3 - "${temp_dir}/expected.json" "${temp_dir}/s3-event.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as expected_file:
    expected = json.load(expected_file)
with open(sys.argv[2], encoding="utf-8") as actual_file:
    actual = json.load(actual_file)
for key in ("player_id", "event_id", "payload_hash", "body_json"):
    if actual.get(key) != expected[key]:
        raise SystemExit(f"FAIL S3 field mismatch: {key}")
PY
echo "PASS S3 GZIP NDJSON matches the DynamoDB source event"

query="SELECT player_id, event_id, payload_hash FROM ${table} WHERE event_id = '${event_id}' LIMIT 1"
query_id="$(AWS_PROFILE="${profile}" aws athena start-query-execution \
  --region "${region}" --work-group "${workgroup}" \
  --query-execution-context "Database=${database}" --query-string "${query}" \
  --query QueryExecutionId --output text)"
for attempt in $(seq 1 30); do
  query_state="$(AWS_PROFILE="${profile}" aws athena get-query-execution \
    --region "${region}" --query-execution-id "${query_id}" \
    --query QueryExecution.Status.State --output text)"
  case "${query_state}" in
    SUCCEEDED) break ;;
    FAILED|CANCELLED)
      AWS_PROFILE="${profile}" aws athena get-query-execution \
        --region "${region}" --query-execution-id "${query_id}" \
        --query QueryExecution.Status.StateChangeReason --output text >&2
      exit 1
      ;;
  esac
  sleep 2
done
[[ "${query_state}" == "SUCCEEDED" ]] || {
  echo "FAIL Athena query timed out" >&2
  exit 1
}
AWS_PROFILE="${profile}" aws athena get-query-results \
  --region "${region}" --query-execution-id "${query_id}" --output json \
  > "${temp_dir}/athena.json"
python3 - "${temp_dir}/athena.json" "${temp_dir}/expected.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as result_file:
    rows = json.load(result_file)["ResultSet"]["Rows"]
with open(sys.argv[2], encoding="utf-8") as expected_file:
    expected = json.load(expected_file)
values = [[column.get("VarCharValue", "") for column in row["Data"]] for row in rows[1:]]
wanted = [expected["player_id"], expected["event_id"], expected["payload_hash"]]
if wanted not in values:
    raise SystemExit("FAIL Athena did not return the expected event")
PY
echo "PASS Athena returned the same event_id and payload_hash"

dlq_counts="$(AWS_PROFILE="${profile}" aws sqs get-queue-attributes \
  --region "${region}" --queue-url "${dlq_url}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' \
  --output text)"
[[ "${dlq_counts}" == $'0\t0' ]] || {
  echo "FAIL Pipe DLQ is not empty: ${dlq_counts}" >&2
  exit 1
}
echo "PASS Pipe DLQ is empty"
echo "Step 5 live delivery and analytics verification passed for ${event_id}."
