# Step 8 — 최종 통합 검증

## 목적

Step 4~7에서 각각 검증한 기능을 마지막에 한 번 연결해 확인합니다. Step 8은 AWS 리소스를 추가하지 않고 테스트 이벤트 1건과 시험 알람 메시지만 만듭니다. Step 7의 Pipe 장애 실험은 반복하지 않고 이미 보존된 완료 작업을 읽기 전용으로 재검증합니다.

## 2026-08-27 실행 결과

`verify_step8.sh`를 서울 리전의 포트폴리오 계정에 실행해 139초에 통과했습니다.

| 구간 | 결과 |
| --- | --- |
| 백엔드 자동 테스트 | 38개 통과 |
| 복구 가드레일 테스트 | 5개 통과 |
| Terraform | fmt·validate·mock guardrail 통과 |
| API 권한 | 익명 403, 자기 조회 200, 다른 사용자 403 |
| 거래·멱등성 | 신규 201, 동일 재시도 200, 변경된 ID 재사용 409 |
| 데이터 내용 | DynamoDB hash, S3 GZIP NDJSON, Athena event/hash 일치 |
| 분석 실패 경로 | Pipe DLQ visible/in-flight 0 |
| 모니터링 | 알람 8개와 월 US$20 Budget 확인 |
| 실제 알림 | CloudWatch→SNS→SSE-SQS 메시지 수신 후 알람 OK 복귀 |
| 복구 증거 | 완료 작업, 수동 레코드 2건, checkpoint, 잠금 없음, Pipe RUNNING |
| 실제 AWS plan | `No changes` |
| 공개 안전성 | 자격증명 패턴·실제 계정/API/VPC 식별자 없음 |

실행 명령:

```bash
cd infra/terraform
AWS_PROFILE=quiz-event-portfolio AWS_REGION=ap-northeast-2 ./scripts/verify_step8.sh
```

이 스크립트는 실제 API 이벤트와 알림 증거를 남기므로 매 커밋마다 자동 실행하는 CI가 아닙니다. 빠른 반복은 로컬 테스트와 Terraform mock을 사용하고, 통합 검증은 단계 완료 시 운영자가 실행합니다.

## 최종 판정

다음 주장을 실제 증거로 설명할 수 있습니다.

- 다른 사용자의 상태 접근을 거부하면서 상태와 불변 이벤트를 한 거래로 저장합니다.
- 분석 전달이 멈춰도 API 원본은 남고, 누락 범위를 특정해 제한 속도로 중단·재개할 수 있습니다.
- 서비스 한도 접근과 실제 throttle, 분석 전달 실패, 비용 임계치를 구분해 알립니다.
- 서비스가 `RUNNING`인지만 확인하지 않고 원본·목적지의 ID·hash·본문을 대조합니다.

다음은 증명하지 않았습니다.

- 리전 전체 장애의 복구와 다중 리전 RPO/RTO.
- 실제 대규모 부하와 24시간 이상 지난 대량 이력의 장시간 처리량.
- 이메일·메신저 당직 체계, 조직 단위 계정 분리, 원격 Terraform state.
- IAM 사용자 MFA와 배포 부트스트랩 권한 축소.

이 경계는 [PORTFOLIO.md](../../PORTFOLIO.md)와 단계별 문서에도 같은 표현으로 유지합니다.
