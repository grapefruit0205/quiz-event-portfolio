#!/usr/bin/env bash
set -euo pipefail

profile="${AWS_PROFILE:-quiz-event-portfolio}"
region="${AWS_REGION:-ap-northeast-2}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$(cd -- "${script_dir}/.." && pwd)"
temp_dir="$(mktemp -d)"
alarm_was_forced=false
api_alarm=""

cleanup() {
  if [[ "${alarm_was_forced}" == true && -n "${api_alarm}" ]]; then
    AWS_PROFILE="${profile}" aws cloudwatch set-alarm-state \
      --region "${region}" --alarm-name "${api_alarm}" --state-value OK \
      --state-reason "Step 6 verification cleanup" >/dev/null 2>&1 || true
  fi
  rm -rf "${temp_dir}"
}
trap cleanup EXIT

for command in aws python3 terraform; do
  command -v "${command}" >/dev/null || {
    echo "missing command: ${command}" >&2
    exit 1
  }
done

cd "${terraform_dir}"
monitoring="$(terraform output -json monitoring)"
account_id="$(terraform output -raw account_id)"
topic_arn="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["alert_topic_arn"])' <<<"${monitoring}")"
queue_url="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["evidence_queue_url"])' <<<"${monitoring}")"
budget_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["budget_name"])' <<<"${monitoring}")"
api_alarm="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["alarm_names"]["api_high_requests"])' <<<"${monitoring}")"
mapfile -t alarm_names < <(python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["alarm_names"].values()))' <<<"${monitoring}")

AWS_PROFILE="${profile}" aws cloudwatch describe-alarms \
  --region "${region}" --alarm-names "${alarm_names[@]}" --output json \
  >"${temp_dir}/alarms.json"
python3 - "${temp_dir}/alarms.json" "${topic_arn}" "${alarm_names[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    alarms = json.load(source).get("MetricAlarms", [])
topic = sys.argv[2]
expected = set(sys.argv[3:])
actual = {alarm["AlarmName"] for alarm in alarms}
if actual != expected:
    raise SystemExit(f"FAIL alarm set mismatch: expected {len(expected)}, got {len(actual)}")
for alarm in alarms:
    if alarm.get("ActionsEnabled") is not True:
        raise SystemExit(f"FAIL actions disabled: {alarm['AlarmName']}")
    if alarm.get("AlarmActions") != [topic]:
        raise SystemExit(f"FAIL alarm action mismatch: {alarm['AlarmName']}")
    if alarm.get("TreatMissingData") != "notBreaching":
        raise SystemExit(f"FAIL missing-data policy mismatch: {alarm['AlarmName']}")
PY
echo "PASS eight alarms use the same SNS action and notBreaching missing-data policy"

AWS_PROFILE="${profile}" aws budgets describe-budget \
  --region us-east-1 --account-id "${account_id}" --budget-name "${budget_name}" \
  --output json >"${temp_dir}/budget.json"
AWS_PROFILE="${profile}" aws budgets describe-notifications-for-budget \
  --region us-east-1 --account-id "${account_id}" --budget-name "${budget_name}" \
  --output json >"${temp_dir}/budget-notifications.json"
python3 - "${temp_dir}/budget.json" "${temp_dir}/budget-notifications.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    budget = json.load(source)["Budget"]
with open(sys.argv[2], encoding="utf-8") as source:
    notifications = json.load(source).get("Notifications", [])
if budget.get("BudgetType") != "COST" or budget.get("TimeUnit") != "MONTHLY":
    raise SystemExit("FAIL budget type or time unit mismatch")
if budget.get("BudgetLimit", {}).get("Amount") != "20.0":
    raise SystemExit("FAIL monthly budget is not USD 20")
observed = {
    (value.get("NotificationType"), float(value.get("Threshold", -1)))
    for value in notifications
}
expected = {("ACTUAL", 80.0), ("FORECASTED", 100.0)}
if observed != expected:
    raise SystemExit(f"FAIL budget notifications mismatch: {observed}")
PY
echo "PASS monthly USD 20 budget has actual 80% and forecast 100% notifications"

marker="step6-live-$(date -u +%Y%m%dT%H%M%SZ)-$$"
AWS_PROFILE="${profile}" aws cloudwatch set-alarm-state \
  --region "${region}" --alarm-name "${api_alarm}" --state-value ALARM \
  --state-reason "${marker}"
alarm_was_forced=true

received=false
for attempt in $(seq 1 12); do
  AWS_PROFILE="${profile}" aws sqs receive-message \
    --region "${region}" --queue-url "${queue_url}" --max-number-of-messages 10 \
    --wait-time-seconds 5 --visibility-timeout 0 --attribute-names All \
    --message-attribute-names All --output json >"${temp_dir}/messages.json"
  if python3 - "${temp_dir}/messages.json" "${api_alarm}" "${marker}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    messages = json.load(source).get("Messages", [])
for message in messages:
    try:
        body = json.loads(message["Body"])
    except (KeyError, json.JSONDecodeError):
        continue
    if (
        body.get("AlarmName") == sys.argv[2]
        and body.get("NewStateValue") == "ALARM"
        and body.get("NewStateReason") == sys.argv[3]
    ):
        raise SystemExit(0)
raise SystemExit(1)
PY
  then
    received=true
    break
  fi
  echo "WAIT alarm notification attempt ${attempt}/12"
done
[[ "${received}" == true ]] || {
  echo "FAIL the forced alarm notification did not reach SQS" >&2
  exit 1
}
echo "PASS forced CloudWatch ALARM reached the encrypted SQS evidence queue through SNS"

AWS_PROFILE="${profile}" aws cloudwatch set-alarm-state \
  --region "${region}" --alarm-name "${api_alarm}" --state-value OK \
  --state-reason "Step 6 verification reset after ${marker}"
alarm_was_forced=false
state="$(AWS_PROFILE="${profile}" aws cloudwatch describe-alarms \
  --region "${region}" --alarm-names "${api_alarm}" \
  --query 'MetricAlarms[0].StateValue' --output text)"
[[ "${state}" == "OK" ]] || {
  echo "FAIL alarm did not return to OK: ${state}" >&2
  exit 1
}
echo "PASS test alarm returned to OK; evidence messages were not deleted"
echo "Step 6 monitoring, budget, and live notification verification passed."
