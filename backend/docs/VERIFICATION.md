# Step 1·2 로컬 + Step 4 AWS 어댑터 + Step 9 UI 검증 기록

2026-08-27 · observed · Python 3.12.3 / SQLite 3.45.1

## 원래 목표와 현재 결과

Step 1의 구현 명세/배포 계획과 Step 2의 로컬 백엔드를 만든다는 목표에 맞는 산출물이다. **Step 1 계획 작성과 Step 2 로컬 구현·검증을 완료했다.** 이후 Step 3 기반은 실제 배포됐으며 그 증거는 Terraform 검증 문서에 분리했다.

이후 Step 4의 DynamoDB 저장 어댑터와 Lambda 환경 연결을 추가하고, Step 9에서 로컬 SAP 퀴즈 UI를 연결했다. 2026-08-27 현재 자동 테스트 40개와 실제 AWS IAM API 시나리오가 통과했다. 코드 모형 시험과 실제 AWS 증거는 구분해 기록한다.

## 수행한 검사

| 검사 | 판정 | 실제 관찰 |
| --- | --- | --- |
| Python 테스트 | pass | Step 2 당시 27개, Step 9 현재 40개. 실패0·오류0 |
| 서버 채점·닫힌 입력 | pass | 정상 채점, 입력 타입/길이/추가 필드, 중복 JSON 키·NaN 거부 |
| 소유권·신원 | pass | 타 사용자 GET/POST403, DB 접근 전 거부, 신원 누락401 |
| 멱등성·충돌 | pass | 같은 요청 원래 응답, 다른 내용409, 과거 재시도가 최신 상태를 덮어쓰지 않음 |
| 거래 롤백 | pass | 로컬 SQLite 이벤트 INSERT에 실패를 주입하자 상태 갱신도 취소됨 |
| 동시 제출 | pass | 같은 이벤트 8개 요청은 새 저장1개/재시도7개. 다른 이벤트2개가 같은 버전으로 경쟁하면 저장1개/충돌1개 |
| 실제 로컬 HTTP | pass | 별도 서버 프로세스에 데모 실행, 11개 확인 항목 통과 |
| 지속 저장 | pass | 서버 프로세스 종료/재시작 뒤 상태와 원래 응답 유지 |
| 문서 예시 | pass | API 문서 JSON3개 파싱. submit.json과 실제 요청 일치, 70점 응답을 문서 예시와 대조 |
| 문서 링크 | pass | backend 문서 상대 링크12개 대상 존재 |
| AWS와 로컬 경계 | pass | AWS 진입점은503으로 거부, Lambda 환경에서 로컬 서버 생성 거부, 루프백 Host와 동일 로컬 Origin만 허용 |
| 독립 실행 | pass | 별도 검토자가 README 테스트·서버·데모·curl·재시작을 실행. 정상201/70점, 재시도200, 타 사용자403, 재시작 보존 확인 |
| Step 1 배포 계획 | pass | 사용자가 서울/7일/US$20/보관14일 계획값을 Step 1·2 범위로 승인. plan_status=complete-for-step-1 |
| Step 1 당시 배포 Gate | historical / pass | 당시에는 실제 배포를 막았고 이후 Step 3을 별도 승인·plan·apply로 진행함 |
| 실제 AWS 업무 동작 | pass | 익명403, Alice 자기 조회200·Bob 조회403, 새 거래201, 동일 재시도200, 다른 본문 충돌409, Bob 자기 조회200 |
| Step 9 실제 브라우저 | pass | 문제10개·radio40개, 제출 전후 버튼 상태, 100점 저장, 새로고침 유지, 콘솔 오류0 |

## Step 4에서 추가한 코드 검사

- DynamoDB Players+Events 조건부 거래 요청 구성과 consistent read.
- 같은 이벤트의 안전한 재시도, 다른 본문 ID 충돌, 동시 버전 충돌.
- 거래 응답이 불명확할 때 Events를 다시 읽어 이미 반영됐는지 판정.
- 상태가 가리키는 이벤트가 없거나 저장소가 실패할 때 안전한 503.
- 저장된 event 본문 hash·중복 필드·원래 응답 불일치 탐지.
- API Gateway의 STS assumed-role ARN을 허용된 IAM caller role로 정규화.
- Lambda 환경 설정 누락 시 fail closed, 정상 설정은 warm 환경에서 재사용.

## Step 9에서 추가한 검사

- 고정 정적 경로의 HTML/CSS/JavaScript 응답과 CSP·frame 차단·no-sniff·no-store 헤더.
- 외부 Host/Origin 403과 같은 로컬 Origin API 200.
- 실제 브라우저의 10문제 렌더링, 10개 선택 후 제출 활성화, 서버 채점 결과 표시.
- stale 화면에서 409 충돌 시 최신 version만 다시 읽고 자동 재제출하지 않으며, 사용자 재클릭 후 정상 저장.
- 제출 후 SQLite 최신 점수와 version 갱신, 새로고침 뒤 결과 유지.
- Step 9에서 AWS API·Terraform apply·신규 AWS 리소스는 사용하지 않음.

## 증거 위치

작업공간 기준:

- `work/quiz-step2-verification/unit-tests.json`, `unit-tests.log`: 주 작업자 테스트 결과.
- `work/quiz-step2-verification/demo.json`, `local-checks.json`: 별도 실제 HTTP 프로세스·재시작·문서 대조.
- `work/quiz-step2-verification/document-checks.json`: 링크와 계획 JSON 검사.
- `work/quiz-step2-rehearsal/`: 독립 검토자의 명령·HTTP 응답·데모·재시작·종료 기록.

독립 실행 중 주 작업자가 테스트 파일의 사용하지 않는 `import copy` 한 줄을 제거했다. 애플리케이션 동작은 바꾸지 않았으며 이후 주 작업자 테스트도27개 통과했다. 독립 검토를 전체 파일 무변경 상태의 시험이라고 표현하지 않는다.

## 한계와 다음 단계

SQLite의 거래/동시성은 로컬 어댑터의 관찰이며 DynamoDB의 원자성·지연·규모 검증이 아니다. 테스트 토큰은 공개 fixture이며 실제 인증/계정 보호가 아니다. 본문 hash는 서명이 아니다. Step 9 UI는 실제 로컬 화면이지만 부정행위 방지·회원가입·Cognito·공개 호스팅은 포함하지 않는다.

Step 4에서 같은 저장·권한 계약을 실제 DynamoDB와 Alice/Bob 역할로 확인했고, Step 5~8에서 분석·알림·복구와 통합 증거를 별도 검증했다. Step 9 소스의 SAP 문제은행과 UI는 기존 AWS Lambda에 apply하지 않았으므로 로컬 플레이 결과를 AWS 실행 증거로 표현하지 않는다.
