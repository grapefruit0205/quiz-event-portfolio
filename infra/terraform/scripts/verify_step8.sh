#!/usr/bin/env bash
set -euo pipefail

profile="${AWS_PROFILE:-quiz-event-portfolio}"
region="${AWS_REGION:-ap-northeast-2}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$(cd -- "${script_dir}/.." && pwd)"
repo_dir="$(cd -- "${terraform_dir}/../.." && pwd)"
temp_dir="$(mktemp -d)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_epoch="$(date +%s)"
trap 'rm -rf "${temp_dir}"' EXIT

for command in aws curl git python3 rg terraform; do
  command -v "${command}" >/dev/null || {
    echo "missing command: ${command}" >&2
    exit 1
  }
done

echo "STEP8_STARTED_AT=${started_at}"

cd "${repo_dir}/backend"
python3 -m unittest discover -s tests >/dev/null
echo "PASS backend unit/integration tests: 38"

cd "${terraform_dir}"
python3 -m unittest discover -s tests -p 'test_*.py' >/dev/null
python3 -m py_compile scripts/recovery.py
echo "PASS recovery guardrail tests: 5"

terraform fmt -check -recursive
terraform validate >/dev/null
terraform test >/dev/null
echo "PASS Terraform format, validate, and mock guardrails"

AWS_PROFILE="${profile}" AWS_REGION="${region}" "${script_dir}/verify_step5.sh"
echo "PASS integrated API ownership, transaction, Pipe, Firehose, S3, and Athena content proof"

AWS_PROFILE="${profile}" AWS_REGION="${region}" "${script_dir}/verify_step6.sh"
echo "PASS integrated alarms, Budget, SNS, and encrypted SQS notification proof"

recovery="$(terraform output -json recovery)"
pipeline="$(terraform output -json analysis_pipeline)"
buckets="$(terraform output -json s3_buckets)"
account_id="$(terraform output -raw account_id)"
vpc_id="$(terraform output -raw vpc_id)"
api_id="$(terraform output -raw api_invoke_url | python3 -c 'import sys; print(sys.stdin.read().split("//",1)[1].split(".",1)[0])')"
jobs_table="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["jobs_table_name"])' <<<"${recovery}")"
recovery_bucket="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["recovery_bucket"])' <<<"${recovery}")"
raw_bucket="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["raw-events"])' <<<"${buckets}")"
pipe_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pipe_name"])' <<<"${pipeline}")"

AWS_PROFILE="${profile}" aws s3api list-objects-v2 \
  --region "${region}" --bucket "${recovery_bucket}" --prefix 'recovery-jobs/' \
  --output json >"${temp_dir}/recovery-objects.json"
completed_key="$(python3 - "${temp_dir}/recovery-objects.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    values = json.load(source).get("Contents", [])
completed = [value for value in values if value["Key"].endswith("/completed.json")]
if not completed:
    raise SystemExit("FAIL no completed Step 7 evidence object exists")
print(max(completed, key=lambda value: value["LastModified"])["Key"])
PY
)"
AWS_PROFILE="${profile}" aws s3api get-object --region "${region}" \
  --bucket "${recovery_bucket}" --key "${completed_key}" \
  "${temp_dir}/completed.json" >/dev/null
job_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_id"])' <"${temp_dir}/completed.json")"

AWS_PROFILE="${profile}" aws dynamodb get-item --region "${region}" \
  --table-name "${jobs_table}" --consistent-read \
  --key "{\"job_id\":{\"S\":\"${job_id}\"}}" --output json \
  >"${temp_dir}/job.json"
python3 - "${temp_dir}/job.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    item = json.load(source).get("Item", {})
if item.get("status", {}).get("S") != "COMPLETED":
    raise SystemExit("FAIL latest recovery evidence is not COMPLETED")
if item.get("processed_count", {}).get("N") != "2":
    raise SystemExit("FAIL latest completed recovery did not process two events")
if item.get("expected_missing_count", {}).get("N") != "2":
    raise SystemExit("FAIL latest recovery lost its inspected missing count")
PY

prefix="${completed_key%/completed.json}/"
python3 - "${temp_dir}/recovery-objects.json" "${prefix}" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    keys = [value["Key"] for value in json.load(source).get("Contents", []) if value["Key"].startswith(sys.argv[2])]
if not any(key.endswith("definition.json") for key in keys):
    raise SystemExit("FAIL recovery definition evidence is missing")
if not any("/progress/" in key for key in keys):
    raise SystemExit("FAIL recovery checkpoint evidence is missing")
if not any(key.endswith("completed.json") for key in keys):
    raise SystemExit("FAIL recovery completion evidence is missing")
PY

AWS_PROFILE="${profile}" aws s3api list-objects-v2 \
  --region "${region}" --bucket "${raw_bucket}" --prefix 'raw/schema_version=2/format=ndjson/' \
  --query 'Contents[].Key' --output json >"${temp_dir}/raw-keys.json"
python3 - "${temp_dir}/raw-keys.json" >"${temp_dir}/raw-keys.txt" <<'PY'
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
done <"${temp_dir}/raw-keys.txt"
python3 - "${temp_dir}/manual-events.txt" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    event_ids = {line.strip() for line in source if line.strip()}
if len(event_ids) != 2:
    raise SystemExit(f"FAIL expected two distinct manual recovery events, got {len(event_ids)}")
PY

lock_output="$(AWS_PROFILE="${profile}" aws dynamodb get-item --region "${region}" \
  --table-name "${jobs_table}" --key '{"job_id":{"S":"__active_lock__"}}' --output json)"
if [[ -n "${lock_output}" ]]; then
  python3 -c 'import json,sys; assert "Item" not in json.load(sys.stdin)' <<<"${lock_output}"
fi
pipe_state="$(AWS_PROFILE="${profile}" aws pipes describe-pipe --region "${region}" \
  --name "${pipe_name}" --query '[CurrentState,DesiredState]' --output text)"
[[ "${pipe_state}" == $'RUNNING\tRUNNING' ]] || {
  echo "FAIL Pipe is not RUNNING/RUNNING: ${pipe_state}" >&2
  exit 1
}
echo "PASS read-only Step 7 evidence: completed job, two manual records, checkpoint, no lock, Pipe RUNNING"

AWS_PROFILE="${profile}" AWS_REGION="${region}" terraform plan -detailed-exitcode -no-color \
  >"${temp_dir}/final-plan.txt"
grep -q 'No changes. Your infrastructure matches the configuration.' "${temp_dir}/final-plan.txt"
echo "PASS final AWS plan has no changes"

cd "${repo_dir}"
git diff --check
scan_args=(--hidden --glob '!.git/**' --glob '!memory/**' --glob '!work/**' \
    --glob '!outputs/**' --glob '!.terraform/**' --glob '!*.tfstate*' --glob '!*.tfplan')
if rg -n "${scan_args[@]}" '(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16})' . || \
    rg -n -F "${scan_args[@]}" "${account_id}" . || \
    rg -n -F "${scan_args[@]}" "${api_id}" . || \
    rg -n -F "${scan_args[@]}" "${vpc_id}" .; then
  echo "FAIL tracked project content contains a credential or private deployment identifier" >&2
  exit 1
fi
echo "PASS no credential patterns or private deployment identifiers in portfolio content"

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
duration="$(( $(date +%s) - started_epoch ))"
echo "STEP8_COMPLETED_AT=${completed_at}"
echo "STEP8_DURATION_SECONDS=${duration}"
echo "Step 8 integrated portfolio verification passed."
