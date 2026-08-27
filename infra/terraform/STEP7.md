# Step 7 — 제한 속도 수동 복구와 중단·재개

## 목표

분석 경로가 멈췄을 때 Events 원본과 Athena 목적지를 비교해 어느 시간·어느 사용자의 이벤트가 빠졌는지 찾고, 정상 API를 방해하지 않는 속도로 다시 보냅니다.

```text
업무 API ──TransactWriteItems──→ Events 원본(GSI: recovery-by-time)
                                      │ 읽기 전용 Query
                                      ▼
운영자 역할 → inspect → RecoveryJobs 잠금·checkpoint → Firehose → S3 → Athena
                    └─ 진행 증거 → versioned recovery S3

API 관련 Alarm=ALARM ──→ 복구 PAUSED ──운영자 확인──→ resume
```

업무 Lambda는 RecoveryJobs 테이블에 접근하지 않습니다. 복구 실패가 API 성공 조건이나 원본 저장 경로에 영향을 주지 않습니다.

## 가벼운 가드레일

- 한 작업은 사용자 한 명과 최대 24시간 범위만 처리합니다. 오래된 장애도 24시간 단위 작업으로 나눕니다.
- GSI `Query`는 한 번에 1개만 평가하고 Firehose는 초당 1개만 보냅니다.
- `Scan`·`PutRecordBatch`·Events 쓰기·S3 삭제 권한이 없습니다.
- `__active_lock__` 조건부 항목으로 동시 실행을 하나만 허용합니다.
- API 요청량·Lambda concurrency/throttle·DynamoDB write throttle 중 하나라도 ALARM이면 전송 전에 멈춥니다.
- 재개와 중단은 각각 `I_UNDERSTAND` 확인이 필요합니다. 자동 재개·자동 확장은 없습니다.
- 원본 `body_json` hash와 player/event ID를 다시 확인한 뒤에만 보냅니다.
- 각 checkpoint와 완료·중단 결과를 버전 관리된 recovery S3에 기록합니다.
- 재전송은 at-least-once입니다. 목적지는 `event_id`로 중복을 제거해야 합니다.

## 운영 흐름

`recovery.py`는 배포된 복구 운영자 역할의 임시 자격증명으로 실행합니다.

1. `inspect`: Events와 Athena의 event ID를 비교해 범위·사용자·누락 ID를 출력합니다.
2. `create`: 확인한 누락 수와 범위를 `PAUSED` 작업으로 저장합니다.
3. `resume --confirm-resume I_UNDERSTAND`: 잠금을 얻고 알람을 확인한 뒤 제한 속도로 전송합니다.
4. 중단되면 마지막 checkpoint부터 다시 `resume`합니다. 직전 checkpoint 이후 중복 전송은 허용합니다.
5. 잘못 만든 작업은 `abort --confirm-abort I_UNDERSTAND`로 이력을 `ABORTED`로 남기고 잠금만 풉니다.

실행 환경과 실제 명령 순서는 [verify_step7.sh](scripts/verify_step7.sh)에 있습니다. 스크립트는 통제된 장애를 만들기 때문에 반복 실행하지 않습니다.

## 실제 장애 예시와 검증

2026-08-27 서울 리전에서 다음 순서로 검증했습니다.

1. Pipe를 `STOPPED`로 두고 API 이벤트 2건을 저장했습니다. API 저장은 모두 성공했습니다.
2. 복구 역할이 Events에는 2건, Athena에는 0건임을 찾아 사용자·시간·event ID를 특정했습니다.
3. API 보호 알람을 시험 ALARM으로 두자 처리 0건 상태에서 `PAUSED`가 됐습니다.
4. 두 번째 작업의 resume는 활성 잠금 때문에 거부됐습니다.
5. 첫 resume는 1건을 보낸 뒤 checkpoint를 남기고 멈췄습니다.
6. 운영자 확인 후 같은 작업을 재개해 총 2건을 완료하고 잠금을 해제했습니다.
7. Pipe가 계속 멈춘 상태에서 두 레코드에 `delivery_source=manual-recovery`가 있는지 S3 본문으로 확인했습니다.
8. Athena 대조에서 누락 0건을 확인한 다음 Pipe를 `RUNNING`으로 복귀시켰습니다.

관찰 결과:

| 지표 | 관찰값 | 의미 |
| --- | --- | --- |
| 업무 원본 RPO | 누락 0건 | 통제된 분석 장애 중 API가 수락한 2건이 Events에 모두 남음 |
| 분석 복구 RTO | 86초 | 운영자 resume 시작부터 Athena 누락 0건 확인까지 |
| 복구 전송량 | 초당 1건 | 코드에 고정, 자동 확장 없음 |

86초에는 Firehose의 최대 60초 버퍼 대기가 포함됩니다. 두 이벤트를 사용한 한 번의 실험값이며 실제 트래픽 규모, 오래된 데이터, 리전 장애의 RPO/RTO를 보장하지 않습니다.

## 구현 중 검증이 찾아낸 문제

- DynamoDB의 `Z`와 `+00:00` 시각 문자열을 직접 비교하면 같은 UTC 시각의 정렬이 달라졌습니다. datetime으로 정규화해 비교하고 회귀 테스트를 추가했습니다.
- Athena 실행에는 결과 버킷뿐 아니라 Catalog가 가리키는 raw-events 읽기가 필요했습니다. 정확한 두 prefix에만 권한을 추가했습니다.
- 일시정지 조건식 값 누락과 “항목 없음”의 빈 CLI 출력을 실제 실험에서 발견해 수정했습니다. 전송 전 실패 작업은 삭제하지 않고 처리 0건 `ABORTED` 증거로 남겼습니다.

## 설명할 수 있어야 하는 부분

- **왜 Kinesis Data Streams가 없는가:** 평상시 장애는 Streams 24시간 안에 복구하고, 그 시간을 넘긴 이력은 Events 원본에서 제한 속도로 재생합니다. 지속적인 다중 소비자 재생이 목표가 아니라서 별도 스트림 비용을 두지 않았습니다.
- **왜 현재 상태 테이블로 복구하지 않는가:** Players에는 최신 값만 있으므로 중간 사건을 재구성할 수 없습니다. 불변 Events가 원본입니다.
- **왜 자동 재개하지 않는가:** API가 불안정했던 원인이 남아 있을 수 있으므로 운영자가 알람과 범위를 다시 확인합니다.
- **왜 중복을 허용하는가:** Firehose 수락 뒤 checkpoint 전에 프로세스가 멈출 수 있습니다. 원본 ID를 유지하고 분석에서 `event_id`로 dedupe하는 편이 누락보다 안전합니다.

AWS 근거: [DynamoDB Query](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Query.html), [DynamoDB 조건식](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Expressions.ConditionExpressions.html), [Firehose PutRecord](https://docs.aws.amazon.com/firehose/latest/APIReference/API_PutRecord.html).
