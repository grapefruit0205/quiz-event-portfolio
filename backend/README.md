# Step 1·2 — 로컬 퀴즈 백엔드

**대상: SAA 합격 후 첫 구현. AWS 계정·키·Docker·추가 Python 패키지가 필요하지 않습니다.**

10문제 퀴즈의 답안을 서버가 채점하고, 현재 점수와 플레이 이력을 저장합니다. 로컬 실행은 Python 표준 라이브러리와 SQLite를 사용합니다. Step 4에서는 같은 handler를 Lambda와 DynamoDB에 배포하고 AWS IAM 역할 호출을 검증했습니다. Step 5에서는 저장된 이벤트를 Pipes와 Firehose로 S3에 전달하고 Athena 내용 대조까지 검증했습니다.

## 1. 먼저 테스트

프로젝트 루트에서 터미널을 열고 실행합니다. 이미 backend 폴더라면 cd는 생략합니다. Python 3.12 이상이 필요합니다.

```bash
cd backend
python3 --version
python3 -m unittest discover -s tests -v
```

테스트는 임시 SQLite 파일과 127.0.0.1 서버만 사용합니다. AWS API/외부 서비스는 호출하지 않습니다. `OK`가 나오면 다음으로 이동합니다.

## 2. 서버 시작 — 터미널 A

backend 폴더에서:

```bash
python3 -m quiz_backend.local_server
```

`local_server_ready`와 `http://127.0.0.1:8765`가 표시됩니다. 서버는 계속 실행되며 Ctrl+C로 종료합니다. DB는 `.local/quiz.sqlite3`에 저장됩니다. 같은 파일로 재시작하면 기존 결과가 남습니다.

포트가 사용 중이라면 `--port 8766`으로 실행하고 아래 클라이언트에도 같은 포트를 지정하세요. 새 데이터로 연습하려면 `--db .local/another-run.sqlite3`를 사용하세요. 기존 DB를 지울 필요가 없습니다.

## 3. 실제 요청 확인 — 터미널 B

두 번째 터미널도 backend 폴더에서 실행합니다.

```bash
python3 -m quiz_backend.demo
```

성공하면 `status: pass`, `scope: local-http-sqlite`, `aws_tested: false`와 확인 항목이 나옵니다. 데모는 새 event_id를 만들어 정상 제출·중복·잘못된 입력·타 사용자 거부를 확인합니다. 여러 번 실행해도 기존 버전을 조회한 뒤 동작합니다.

포트 변경/기록 저장 예시:

```bash
python3 -m quiz_backend.demo --base-url http://127.0.0.1:8766 --output .local/demo-report.json
```

서버가 없는 경우 Connection refused가 나옵니다. 터미널 A에서 서버가 실행 중인지, 포트가 같은지 확인하세요.

## 4. 직접 한 번 호출해보기

아래 토큰은 공개된 **로컬 사용자 선택 값**입니다. AWS 키나 실제 로그인 토큰이 아닙니다.

```bash
curl -sS http://127.0.0.1:8765/quiz -H 'Authorization: Bearer local-alice'
curl -sS http://127.0.0.1:8765/players/alice -H 'Authorization: Bearer local-alice'
```

[examples/submit.json](examples/submit.json)은 Alice의 버전이 0인 **새 DB에서** 쓰는 예시입니다. 이미 데모를 실행했다면 새 event_id를 정하고 expected_version을 내 조회 결과로 바꾸세요. 같은 요청을 재시도할 때는 본문을 바꾸지 않습니다.

```bash
curl -sS -i http://127.0.0.1:8765/players/alice/results \
  -H 'Authorization: Bearer local-alice' \
  -H 'Content-Type: application/json' \
  --data-binary @examples/submit.json
```

예시 답안은 70점입니다. 첫 제출은 201, 동일 요청 재시도는 200입니다. 응답의 version은 새 플레이마다 1씩 증가합니다. 다른 사람의 데이터를 읽어보면 403입니다.

```bash
curl -sS -i http://127.0.0.1:8765/players/bob -H 'Authorization: Bearer local-alice'
```

## 5. 코드 읽는 순서

| 파일 | 이해할 내용 |
| --- | --- |
| [quiz.py](quiz_backend/quiz.py) | 문제·입력 검사·채점·이벤트/hash 계약 |
| [handler.py](quiz_backend/handler.py) | 인증된 신원 매핑·소유권 검사·API 응답 |
| [storage.py](quiz_backend/storage.py) | SQLite 거래와 DynamoDB 조건부 거래, 중복 요청, 버전 충돌 |
| [local_server.py](quiz_backend/local_server.py) | 로컬 HTTP 요청을 Lambda proxy 모양으로 변환 |
| [demo.py](quiz_backend/demo.py) | 실제 HTTP 호출로 성공과 거부 결과 확인 |

`handler.lambda_handler`는 Terraform이 `PLAYERS_TABLE`, `EVENTS_TABLE`, `PRINCIPAL_MAP_JSON`을 모두 주입한 경우에만 DynamoDB 어댑터를 만듭니다. 설정이 빠지거나 잘못되면 **503 DEPLOYMENT_NOT_CONFIGURED**로 닫힙니다. 로컬 서버는 같은 요청 처리 함수 `build_handler`에 SQLite/테스트 신원을 명시적으로 연결합니다.

## 6. 범위와 검증

- [Step 1 명세·배포 계획](docs/STEP1.md): 완료된 계획과 Step 3 전 별도 승인 Gate.
- [API 계약](docs/API.md): 본문·상태 코드·데이터 계약.
- [검증 기록](docs/VERIFICATION.md): 실제 실행한 검사와 미실행 범위.
- [배포 계획 JSON](config/deployment-plan.json): deployment_enabled=false. **배포 스크립트가 아닙니다.**

과거 v5 설계의 ScoreChanged/schema 1 대신 이 로컬 예제는 QuizCompleted/schema 2를 사용합니다. 배포된 데이터는 없으며 마이그레이션은 하지 않았습니다. 미래 Catalog/검증기도 이 계약에 맞춰야 합니다.

이 로컬 HTTP 서버는 127.0.0.1 전용입니다. 인터넷 공개·터널링·실사용자 데이터 입력을 하지 마세요. 공개 웹 UI는 없습니다. 실제 AWS 검증은 [Terraform Step 4 문서](../infra/terraform/STEP4.md)와 [Step 5 문서](../infra/terraform/STEP5.md)에 있습니다. 복구 RPO/RTO는 아직 실측하지 않았습니다.
