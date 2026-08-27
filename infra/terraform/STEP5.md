# Step 5 — 이벤트 전달과 Athena 분석

## 목표

업무 API가 DynamoDB에 원자적으로 저장한 `QuizCompleted` 이력을 분석용 S3로 전달하고, 같은 이벤트를 Athena에서 조회합니다.

```text
Events table → DynamoDB Streams → EventBridge Pipes → Firehose Direct PUT
                                                        ├─→ raw-events S3
                                                        └─→ Firehose 오류 로그
                              └─ 실패한 소스 batch → SQS DLQ

raw-events S3 → Glue Catalog external table → Athena workgroup
```

Kinesis Data Streams는 넣지 않았습니다. 이 프로젝트는 정상 전달 장애를 24시간 안에 발견·복구한다는 운영 목표를 두고, 장기 원본은 Streams가 아니라 Events 테이블에 보존합니다. 24시간을 넘긴 누락은 Step 7의 제한 속도 수동 재전송으로 다룹니다. 이 선택은 모든 실제 장애가 24시간 안에 복구된다는 통계 주장이 아닙니다.

## 가드레일

- Pipe는 새 `INSERT` 중 schema 2 `QuizCompleted`만 받고 `LATEST`부터 시작합니다.
- batch 10, batching window 1초, record age 1시간, retry 3회, parallelization 1입니다.
- 실패한 소스 batch의 SQS DLQ는 관리형 암호화와 14일 보관을 사용합니다.
- Firehose는 1 MiB 또는 60초마다 GZIP NDJSON을 S3에 씁니다.
- S3 경로는 `schema_version=2/format=ndjson`으로 고정합니다.
- Athena workgroup은 설정 강제, 결과 SSE-S3, 질의당 10 MiB 스캔 상한을 사용합니다.
- Glue ETL job, crawler, bookmark, Lake Formation, Kinesis Data Streams는 이번 범위에 없습니다.

## 실제 적용과 검증

2026-08-27 서울 리전에 Step 5 리소스 12개를 추가했습니다. 첫 실제 이벤트에서 Pipe와 Firehose는 각각 1건을 성공 처리했지만, 여러 줄 입력 템플릿 때문에 S3 객체가 NDJSON 계약을 만족하지 않는 것을 자동 검증이 발견했습니다.

기존 객체를 삭제하지 않고 이전 경로에 보존한 채 다음 세 항목만 제자리 변경했습니다.

1. Pipe 입력 템플릿을 한 줄 JSON으로 고정.
2. Firehose 목적지에 `format=ndjson` 경로 추가.
3. Glue table location을 새 경로로 제한.

수정 계획은 `0 added / 3 changed / 0 destroyed`였습니다. 새 이벤트로 다음을 확인했습니다.

- 익명 호출과 다른 사용자 데이터 접근 거부.
- DynamoDB 이력의 `body_json` SHA256과 `payload_hash` 일치.
- S3 GZIP 객체의 `event_id`, `player_id`, `payload_hash`, `body_json`이 DynamoDB와 일치.
- Athena가 같은 `event_id`와 `payload_hash` 반환.
- Pipe DLQ visible/in-flight 메시지 0.

실행 명령:

```bash
cd infra/terraform
AWS_PROFILE=quiz-event-portfolio AWS_REGION=ap-northeast-2 ./scripts/verify_step5.sh
```

스크립트는 새 테스트 이벤트를 한 건 저장하므로 빈번하게 반복하지 않습니다. 임시 STS 자격증명과 내려받은 응답·객체는 종료 시 제거하며 공개 저장소에는 실제 계정 ID나 이벤트 본문을 기록하지 않습니다.

## 설명할 수 있어야 하는 부분

1. **업무 저장과 분석 전달의 차이:** API 성공 기준은 DynamoDB 거래이며 Firehose 성공이 아닙니다.
2. **왜 Events 테이블이 원본인가:** Streams와 DLQ는 전달 수단이고, 장시간 장애 후 재생할 전체 이력은 Events에 남습니다.
3. **왜 SQS DLQ가 필요한가:** retry가 끝난 소스 batch를 운영자가 확인하지만 모든 이벤트의 영구 보관소로 쓰지는 않습니다.
4. **왜 첫 검증이 실패했는가:** 서비스 상태가 `RUNNING`·`ACTIVE`여도 데이터 형식까지 맞는 것은 아니므로 내용 대조가 필요합니다.
5. **중복 가능성:** Pipes와 Firehose 전달은 중복될 수 있어 분석·복구 시 처음 저장한 `event_id`를 기준으로 처리해야 합니다.

## 한계

알람과 실제 알림 수신은 Step 6, 24시간을 넘긴 누락의 수동 재전송·중단/재개는 Step 7입니다. 현재 Glue table은 작은 포트폴리오 데이터에 맞춘 단일 external table이며, 대규모 데이터의 partition projection·Lake Formation 권한 모델·ETL 품질 계층은 구현하지 않았습니다.

AWS 근거: [DynamoDB Streams 소스](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-pipes-dynamodb.html), [Pipes 실행 역할 권한](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-pipes-permissions.html), [Firehose AppendDelimiterToRecord](https://docs.aws.amazon.com/firehose/latest/APIReference/API_Processor.html), [Athena workgroup](https://docs.aws.amazon.com/athena/latest/ug/workgroups.html).
