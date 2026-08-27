# Step 6 — 선제 모니터링과 비용 알림

## 목표

장애가 발생했을 때 추측하지 않고 다음 세 구간을 먼저 구분합니다.

1. API Gateway 요청량이 설정한 5 req/s에 가까워졌는가?
2. Lambda 동시 실행이 경고선에 도달했거나 실제 throttle이 발생했는가?
3. DynamoDB Players·Events 쓰기가 throttle됐는가?

분석 경로의 Pipe 실행 실패, Firehose S3 전달 실패, Pipe DLQ 적재도 같은 SNS 경로로 알립니다. 월 비용은 US$20 Budget의 실제 80%와 예측 100%에서 알립니다. Budget은 알림일 뿐 지출을 자동 차단하지 않습니다.

```text
API Gateway · Lambda · DynamoDB · Pipes · Firehose · DLQ
                         │ CloudWatch Alarm
                         ▼
                       SNS ──→ SSE-SQS 증거 큐(1일)

AWS Budgets(actual 80%, forecast 100%) ────────────────┘
```

## 가벼운 가드레일

- 알람은 8개만 두고 대시보드, 별도 로그 수집기, Chatbot은 추가하지 않습니다.
- API 요청량은 설정 상한의 80%가 2분 지속될 때 경고해 순간 spike와 구분합니다.
- Lambda concurrency 경고선은 8, 실제 Lambda·DynamoDB throttle은 1건부터 알립니다.
- 데이터가 없는 시간은 장애로 판정하지 않도록 `notBreaching`을 사용합니다.
- 알림 증거 큐는 SSE-SQS, 1일 보관이며 SNS 토픽만 메시지를 넣을 수 있습니다.
- SNS 메시지는 지표명과 상태만 포함하므로 이번 실습에서는 고객 관리 KMS 키를 추가하지 않았습니다.
- SQS는 사람이 상시 확인하는 운영 UI가 아니라 실제 전달 증거입니다. 실무 인계 시 email 또는 AWS Chatbot 같은 수신 채널을 추가할 수 있습니다.

## 실제 검증

2026-08-27 서울 리전에 기존 리소스 변경·삭제 없이 Step 6 리소스 14개를 추가했습니다. 첫 적용에서 SNS 리소스 정책의 광범위한 action 표현이 거부되어, AWS가 허용하는 토픽 action 목록으로 축소한 뒤 남은 2개 리소스만 이어서 적용했습니다.

`verify_step6.sh`는 다음을 실제 AWS API로 확인합니다.

- 8개 알람이 활성화되어 같은 SNS action과 `notBreaching` 정책을 사용함.
- 월 US$20 COST Budget과 actual 80%·forecast 100% 알림이 존재함.
- API 요청량 알람을 고유한 시험 사유로 `ALARM` 상태에 두었을 때 SNS를 거쳐 SQS에 정확한 메시지가 도착함.
- 시험 후 알람을 `OK`로 되돌리고 증거 메시지는 삭제하지 않음.

```bash
cd infra/terraform
AWS_PROFILE=quiz-event-portfolio AWS_REGION=ap-northeast-2 ./scripts/verify_step6.sh
```

이 시험은 알람 action과 전달 경로를 검증하지만 실제 과부하나 서비스 장애가 발생했다는 증거는 아닙니다. 정상 API에 부하를 주지 않기 위해 `SetAlarmState`를 사용했습니다.

## 실습자가 설명할 부분

- **API 요청량 증가:** API Gateway `Count`가 먼저 오르면 호출 증가인지 확인하고 WAF 차단·4XX/5XX·지연 시간을 함께 봅니다.
- **Lambda 한도:** `ConcurrentExecutions` 경고와 `Throttles`를 분리해 용량 접근과 실제 거부를 구분합니다.
- **DynamoDB 병목:** Lambda가 정상이어도 `WriteThrottleEvents`가 있으면 테이블 측 처리량 문제로 좁힙니다.
- **분석 장애:** API 저장 성공과 Pipe/Firehose 전달 성공은 별개이며, DLQ와 Events 원본으로 복구합니다.
- **비용 알림:** Budget은 뒤늦게 반영될 수 있고 리소스를 중지하지 않으므로 서비스 알람을 대신하지 않습니다.

AWS 근거: [CloudWatch 알람 SNS 통지](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Notify_Users_Alarm_Changes.html), [AWS Budgets SNS](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-sns-policy.html), [API Gateway 지표](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-metrics-and-dimensions.html).
