# Step 1 — 작은 퀴즈 백엔드의 범위와 배포 계획

대상: SAA 합격 후 첫 구현. 작성일: 2026-08-27. **이번 작업은 로컬 Step 1·2이며 AWS 배포는 하지 않는다.**

> **역사적 범위:** 이 문서는 Step 1 당시의 `math-v1` 계획을 보존한다. 현재 로컬 문제은행과 UI는 Step 9의 `aws-sap-architecture-v1`이며, 기존 AWS Lambda 배포본은 Step 9에서 변경하지 않았다. 현재 실행은 [STEP9.md](STEP9.md)를 따른다.

## 게임과 성공 기준

10개의 고정 산수 문제를 혼자 풀고 답안을 제출한다. 서버가 정답 수 × 10으로 0~100점을 계산한다. Players에는 가장 최근 점수와 버전을, Events에는 각 제출의 원본과 원래 응답을 보관한다. 점수는 누적 점수가 아니다.

게임 종류는 기존 대화의 추천을 따른 로컬 기본 예제다. 실시간 게임·회원가입·랭킹·화면·시간 제한은 만들지 않는다. 문제은행은 버전 ID `math-v1`로 고정하며 정답을 바꾸려면 새 quiz_id를 만든다.

## 기술 선택

| 항목 | 이번 선택 | 이유 |
| --- | --- | --- |
| 코드 | Python 3.12+, 표준 라이브러리 | 별도 패키지 설치 없이 실행·시험 |
| 로컬 HTTP | `http.server`, 127.0.0.1 전용 | 요청/응답 확인용, 공개 배포 금지 |
| 로컬 저장 | SQLite 파일 | 서버 재시작 후 결과와 거래 롤백 확인 |
| 미래 AWS 저장 | DynamoDB Players/Events | 기존 아키텍처 유지; SQLite는 AWS 대체안이 아님 |
| 미래 IaC | Terraform 하나 | Step 3에서 작성. 이번에는 `.tf` 생성/실행하지 않음 |
| 미래 API | Regional REST API + WAF + Lambda | 기존 설계 유지 |
| 미래 분석 | Events Streams → Pipes → Firehose Direct PUT → S3 → Athena | 이번에는 코드·리소스 없음 |

Python의 HTTP 서버는 프로덕션 서버가 아니다. SQLite 검증은 DynamoDB·IAM·Streams의 검증이 아니다. [Python HTTP 문서](https://docs.python.org/3.12/library/http.server.html), [SQLite 문서](https://docs.python.org/3.12/library/sqlite3.html)

## 이후 생성할 리소스 목록 — 계획이며 미생성

Step 1에서 무엇을 만들 예정인지 확인하기 위한 목록이다. **아래 리소스 생성은 이번 Step 1·2 작업에 포함되지 않는다.** 정확한 이름/ARN·계정ID와 비용은 Step 3 전에 확인한다.

| 단계 | 예정 리소스 | 목적·제한 |
| --- | --- | --- |
| Step 3 | VPC 1개, 서로 다른 AZ의 프라이빗 서브넷 2개와 라우팅 테이블, Lambda용 SG, DynamoDB Gateway Endpoint | 기존 VPC 연결 구조. DB 호출만 하는 API에 NAT를 추가하지 않는 계획 |
| Step 3 | DynamoDB Players·Events, Events 시간 검색 GSI, PITR·삭제 보호 | 현재 상태와 이력 보존. SQLite를 AWS로 올리지 않음 |
| Step 3~5 | S3 raw·Athena 결과·복구 기록 저장 위치, 공개 차단·암호화·Versioning | 역할별 접근 범위를 나눔. 자동 삭제/Glacier 전환은 첫 실습에서 하지 않음 |
| Step 3~4 | 배포 역할, 업무 Lambda 역할, 테스트 사용자 Alice/Bob의 서로 다른 IAM 역할 | 역할별 최소 권한. 실제 계정 자격증명은 코드/문서에 넣지 않음 |
| Step 4 | Regional REST API 1개, 실습 Stage, 업무 Lambda 1개, WAF Web ACL | API 세 경로. 로컬 테스트 토큰 대신 실제 IAM 요청 검증 |
| Step 5 | EventBridge Pipe 1개, Direct PUT Firehose 1개, 소스 SQS DLQ 1개, 각각의 실행 권한 | Events Streams → Pipes → Firehose → S3. Kinesis Data Streams 제외 |
| Step 5 | Glue Catalog database/table, Athena workgroup | schema 2의 원본 이력 조회. Glue ETL job·Lake Formation 추가 없음 |
| Step 6 | CloudWatch 로그/알람, SNS 수신 경로, 비용 알림 | 실제 수신 시험, 제한된 실습 부하. Budgets를 지출 차단기로 간주하지 않음 |
| Step 7 | DynamoDB RecoveryJobs, 운영자 복구 역할, S3 진행 기록 | CLI 하나가 수동 재처리·중단 후 재개. API는 이 테이블에 의존하지 않음 |

별도 중앙 백업 서비스, Redis, EKS, 상시 WAS, 멀티 리전 스택은 이 목록에 없다. CloudTrail의 별도 Trail/감사 버킷은 기존 설계에서도 미확정 제안이므로 필수 배포로 승격하지 않는다.

## 데이터 흐름

1. 로컬 테스트 신원 Alice로 문제와 현재 버전을 조회한다.
2. 고유한 event_id, 현재 expected_version, 답안 10개를 제출한다.
3. 서버가 사용자 소유권·입력·문제 버전을 확인하고 채점한다.
4. 같은 event_id/같은 요청이면 저장된 원래 응답을 반환한다. 같은 ID/다른 요청은 409다.
5. 새로운 요청이면 상태 버전을 확인하고 Players 갱신과 Events 추가를 한 로컬 거래로 처리한다.
6. 저장된 결과를 반환한다. 분석 전달 완료를 기다리는 로직은 없다.

## API와 데이터 계약

정확한 입출력은 [API.md](API.md)를 따른다. 세 경로만 구현한다.

- `GET /quiz`: 정답을 제외한 문제 조회.
- `GET /players/{player_id}`: 현재 점수·버전·최근 결과 조회. 이력이 없으면 score=0, version=0, latest_result=null.
- `POST /players/{player_id}/results`: 답안 제출·서버 채점·거래 저장.

Events 키는 `(player_id,event_id)`다. 요청 내용 비교용 request_hash와 이벤트 내용 비교용 payload_hash는 분리한다. SHA256은 서명이 아니며 원본 저장소를 수정할 수 있는 공격자를 막지 않는다. 클라이언트 제공 score·player_id·timestamp는 받지 않는다.

### 기존 v5와의 차이

이 구현의 이벤트는 **QuizCompleted / schema_version=2**다. 기존 v5의 ScoreChanged/schema 1 점수 직접 제출 예제와 혼용하지 않는다. schema 2는 quiz_id·제출 답안·정답 수를 포함한다. 실제 배포 데이터는 없으며 마이그레이션을 실행하지 않았다. 향후 Step 5에서 Catalog·검증기가 이 계약을 읽도록 맞춘다. 기존 v5 ZIP·도면·검증 기록은 변경하지 않는다.

### 인증 경계

로컬 서버만 공개된 테스트 토큰 `local-alice`, `local-bob`를 허용한다. 이는 로그인/비밀 키가 아니며 두 테스트 사용자를 선택하는 장치다. 토큰은 AWS 인증이 아니다. 서버는 클라이언트의 X-Player-Id·owner 헤더를 신뢰하지 않는다.

Lambda 요청 처리 코드는 API Gateway REST proxy 형식과 서버 측 principal→player 매핑을 사용한다. 실제 IAM identity 필드와 호출 제한은 Step 4에서 확인한다. AWS용 진입점은 저장소/신원 매핑 연결 전까지 503으로 거부하며 SQLite나 로컬 토큰으로 대체하지 않는다. [AWS proxy 형식](https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-lambda-proxy-integrations.html)

## 배포 계획과 승인 Gate

[deployment-plan.json](../config/deployment-plan.json)이 계획값의 원본이다. 사용자는 Step 1·2 범위에서 서울 리전·실습 7일·US$20 상한·이력 보관 14일 계획값을 승인했다. 이 금액은 예상 청구액도, AWS의 자동 지출 차단도 아니다.

**Step 1의 산출물인 구현 명세와 배포 계획 작성은 완료다.** `plan_status=complete-for-step-1`과 각 `approved=true`는 Step 1·2 계획값이 정해졌다는 뜻이다. AWS 사용 승인과는 다르므로 `deployment_enabled=false`, `deployment_approval=not-granted`를 유지한다.

계정 선정·예상 비용 재검토·정리 범위·실제 배포 권한은 Step 3 착수 전 Gate다. 이번 승인은 Step 2까지 질문 없이 진행하라는 사용자 지시에 따른 계획 승인이다. AWS 호출이나 유료 리소스 생성을 승인한 것으로 확대하지 않는다.

## Light guardrail

- 실제 AWS 호출·자격증명 읽기·패키지 설치·유료 자원 생성 없음.
- 외부 노출 없이 127.0.0.1에서만 실행. 실사용자·실제 개인정보 없음.
- API 세 개, 고정 문제 10개, 합성 사용자 두 명, 업무 상태/이력 저장만 구현.
- 복구 worker·GSI 조회·IaC·로그 알림·프런트엔드는 다음 Step으로 넘김.
- 현재 테스트는 로컬 동작 증거이며 대규모 처리·무손실·실제 IAM 보안 보장이 아님.

## 실습자가 설명할 다섯 질문

1. 왜 클라이언트 점수를 받지 않고 서버에서 채점하는가?
2. 상태와 이력을 함께 저장하지 않으면 어떤 문제가 생기는가?
3. 같은 요청 재시도와 새로운 플레이는 어떻게 구별하는가?
4. 왜 다른 사용자 검사를 DB 읽기 전에 하는가?
5. 로컬 성공과 실제 AWS 배포 성공은 무엇이 다른가?
