# Step 1·2 로컬 + Step 4 AWS 어댑터 검증 기록

2026-08-27 · observed · Python 3.12.3 / SQLite 3.45.1

## 원래 목표와 현재 결과

Step 1의 구현 명세/배포 계획과 Step 2의 로컬 백엔드를 만든다는 목표에 맞는 산출물이다. **Step 1 계획 작성과 Step 2 로컬 구현·검증을 완료했다.** 이후 Step 3 기반은 실제 배포됐으며 그 증거는 Terraform 검증 문서에 분리했다.

이후 Step 4의 DynamoDB 저장 어댑터와 Lambda 환경 연결을 추가했다. 2026-08-27 전체 자동 테스트 38개와 실제 AWS IAM API 시나리오가 통과했다. 코드 모형 시험과 실제 AWS 증거는 구분해 기록한다.

## 수행한 검사

| 검사 | 판정 | 실제 관찰 |
| --- | --- | --- |
| Python 테스트 | pass | `python3 -m unittest discover -s tests -v`: 27개, 실패0·오류0·skip0 |
| 서버 채점·닫힌 입력 | pass | 정상 채점, 입력 타입/길이/추가 필드, 중복 JSON 키·NaN 거부 |
| 소유권·신원 | pass | 타 사용자 GET/POST403, DB 접근 전 거부, 신원 누락401 |
| 멱등성·충돌 | pass | 같은 요청 원래 응답, 다른 내용409, 과거 재시도가 최신 상태를 덮어쓰지 않음 |
| 거래 롤백 | pass | 로컬 SQLite 이벤트 INSERT에 실패를 주입하자 상태 갱신도 취소됨 |
| 동시 제출 | pass | 같은 이벤트 8개 요청은 새 저장1개/재시도7개. 다른 이벤트2개가 같은 버전으로 경쟁하면 저장1개/충돌1개 |
| 실제 로컬 HTTP | pass | 별도 서버 프로세스에 데모 실행, 11개 확인 항목 통과 |
| 지속 저장 | pass | 서버 프로세스 종료/재시작 뒤 상태와 원래 응답 유지 |
| 문서 예시 | pass | API 문서 JSON3개 파싱. submit.json과 실제 요청 일치, 70점 응답을 문서 예시와 대조 |
| 문서 링크 | pass | backend 문서 상대 링크12개 대상 존재 |
| AWS와 로컬 경계 | pass | AWS 진입점은503으로 거부, Lambda 환경에서 로컬 서버 생성 거부, 루프백 Host/Origin 제한 |
| 독립 실행 | pass | 별도 검토자가 README 테스트·서버·데모·curl·재시작을 실행. 정상201/70점, 재시도200, 타 사용자403, 재시작 보존 확인 |
| Step 1 배포 계획 | pass | 사용자가 서울/7일/US$20/보관14일 계획값을 Step 1·2 범위로 승인. plan_status=complete-for-step-1 |
| Step 1 당시 배포 Gate | historical / pass | 당시에는 실제 배포를 막았고 이후 Step 3을 별도 승인·plan·apply로 진행함 |
| 실제 AWS 업무 동작 | pass | 익명403, Alice 자기 조회200·Bob 조회403, 새 거래201, 동일 재시도200, 다른 본문 충돌409, Bob 자기 조회200 |

## Step 4에서 추가한 코드 검사

- DynamoDB Players+Events 조건부 거래 요청 구성과 consistent read.
- 같은 이벤트의 안전한 재시도, 다른 본문 ID 충돌, 동시 버전 충돌.
- 거래 응답이 불명확할 때 Events를 다시 읽어 이미 반영됐는지 판정.
- 상태가 가리키는 이벤트가 없거나 저장소가 실패할 때 안전한 503.
- 저장된 event 본문 hash·중복 필드·원래 응답 불일치 탐지.
- API Gateway의 STS assumed-role ARN을 허용된 IAM caller role로 정규화.
- Lambda 환경 설정 누락 시 fail closed, 정상 설정은 warm 환경에서 재사용.

## 증거 위치

작업공간 기준:

- `work/quiz-step2-verification/unit-tests.json`, `unit-tests.log`: 주 작업자 테스트 결과.
- `work/quiz-step2-verification/demo.json`, `local-checks.json`: 별도 실제 HTTP 프로세스·재시작·문서 대조.
- `work/quiz-step2-verification/document-checks.json`: 링크와 계획 JSON 검사.
- `work/quiz-step2-rehearsal/`: 독립 검토자의 명령·HTTP 응답·데모·재시작·종료 기록.

독립 실행 중 주 작업자가 테스트 파일의 사용하지 않는 `import copy` 한 줄을 제거했다. 애플리케이션 동작은 바꾸지 않았으며 이후 주 작업자 테스트도27개 통과했다. 독립 검토를 전체 파일 무변경 상태의 시험이라고 표현하지 않는다.

## 한계와 다음 단계

SQLite의 거래/동시성은 로컬 어댑터의 관찰이며 DynamoDB의 원자성·지연·규모 검증이 아니다. 테스트 토큰은 공개 fixture이며 실제 인증/계정 보호가 아니다. 본문 hash는 서명이 아니다. 게임의 부정행위 방지·실제 사용자 UI·AWS 알림/복원·비용/RPO/RTO 측정도 하지 않았다.

Step 4에서 같은 API 계약을 실제 DynamoDB와 Alice/Bob 역할로 확인했다. AWS 오류 시 SQLite로 대체하지 않는다. Streams/Pipes/Firehose와 복구 실험은 아직 범위 밖이다.
