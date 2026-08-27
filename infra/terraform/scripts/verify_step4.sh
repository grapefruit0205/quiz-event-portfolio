#!/usr/bin/env bash
set -euo pipefail

profile="${AWS_PROFILE:-quiz-event-portfolio}"
region="${AWS_REGION:-ap-northeast-2}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$(cd -- "${script_dir}/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

for command in aws curl python3 terraform; do
  command -v "${command}" >/dev/null || {
    echo "missing command: ${command}" >&2
    exit 1
  }
done

cd "${terraform_dir}"
api_url="$(terraform output -raw api_invoke_url)"
roles_json="$(terraform output -json caller_role_arns)"
alice_role="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["alice"])' <<<"${roles_json}")"
bob_role="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["bob"])' <<<"${roles_json}")"

assume() {
  local role_arn="$1" session_name="$2" prefix="$3"
  local credentials
  credentials="$(AWS_PROFILE="${profile}" aws sts assume-role \
    --region "${region}" \
    --role-arn "${role_arn}" \
    --role-session-name "${session_name}" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)"
  read -r "${prefix}_ACCESS" "${prefix}_SECRET" "${prefix}_TOKEN" <<<"${credentials}"
  export "${prefix}_ACCESS" "${prefix}_SECRET" "${prefix}_TOKEN"
}

signed_call() {
  local prefix="$1" method="$2" path="$3" body_file="${4:-}" output_file="$5" headers_file="$6"
  local access_name="${prefix}_ACCESS" secret_name="${prefix}_SECRET" token_name="${prefix}_TOKEN"
  local curl_args=(
    --silent --show-error
    --request "${method}"
    --aws-sigv4 "aws:amz:${region}:execute-api"
    --user "${!access_name}:${!secret_name}"
    --header "x-amz-security-token: ${!token_name}"
    --dump-header "${headers_file}"
    --output "${output_file}"
    --write-out '%{http_code}'
  )
  if [[ -n "${body_file}" ]]; then
    curl_args+=(--header 'Content-Type: application/json' --data-binary "@${body_file}")
  fi
  curl "${curl_args[@]}" "${api_url}${path}"
}

expect_status() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL ${label}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
  echo "PASS ${label}: HTTP ${actual}"
}

assume "${alice_role}" "step4-alice-check" "ALICE"
assume "${bob_role}" "step4-bob-check" "BOB"

status="$(curl --silent --output "${temp_dir}/anonymous.json" --write-out '%{http_code}' "${api_url}/quiz")"
expect_status "anonymous request rejected" 403 "${status}"

status="$(signed_call ALICE GET /quiz '' "${temp_dir}/quiz.json" "${temp_dir}/quiz.headers")"
expect_status "Alice reads quiz" 200 "${status}"

status="$(signed_call ALICE GET /players/alice '' "${temp_dir}/alice.json" "${temp_dir}/alice.headers")"
expect_status "Alice reads own state" 200 "${status}"
version="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' < "${temp_dir}/alice.json")"

status="$(signed_call ALICE GET /players/bob '' "${temp_dir}/cross.json" "${temp_dir}/cross.headers")"
expect_status "Alice cannot read Bob" 403 "${status}"

event_id="step4-$(date +%s)-$$"
python3 - "${event_id}" "${version}" > "${temp_dir}/submission.json" <<'PY'
import json
import sys

print(json.dumps({
    "event_id": sys.argv[1],
    "quiz_id": "math-v1",
    "expected_version": int(sys.argv[2]),
    "answers": [0, 1, 2, 3, 0, 1, 2, 3, 0, 1],
    "test_run_id": "step4-live-check",
}, separators=(",", ":")))
PY

status="$(signed_call ALICE POST /players/alice/results "${temp_dir}/submission.json" "${temp_dir}/created.json" "${temp_dir}/created.headers")"
expect_status "new result stored" 201 "${status}"

status="$(signed_call ALICE POST /players/alice/results "${temp_dir}/submission.json" "${temp_dir}/replay.json" "${temp_dir}/replay.headers")"
expect_status "same result safely replayed" 200 "${status}"
grep -qi '^x-idempotent-replay: true' "${temp_dir}/replay.headers" || {
  echo "FAIL replay header missing" >&2
  exit 1
}
cmp -s "${temp_dir}/created.json" "${temp_dir}/replay.json" || {
  echo "FAIL replay body differs from original" >&2
  exit 1
}
echo "PASS replay returns the original body"

python3 - "${temp_dir}/submission.json" > "${temp_dir}/conflict.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source)
value["answers"][0] = 1
print(json.dumps(value, separators=(",", ":")))
PY
status="$(signed_call ALICE POST /players/alice/results "${temp_dir}/conflict.json" "${temp_dir}/conflict-response.json" "${temp_dir}/conflict.headers")"
expect_status "event id reuse with changed content rejected" 409 "${status}"

status="$(signed_call BOB GET /players/bob '' "${temp_dir}/bob.json" "${temp_dir}/bob.headers")"
expect_status "Bob reads own state" 200 "${status}"

echo "Step 4 live API verification passed. Temporary credentials and responses were removed."
