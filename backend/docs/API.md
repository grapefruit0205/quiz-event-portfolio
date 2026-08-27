# Step 1 API 계약 — quiz schema 2

기본 주소: `http://127.0.0.1:8765`. 모든 요청은 로컬 테스트 사용자 선택을 위해 `Authorization: Bearer local-alice` 또는 `Bearer local-bob`를 사용한다. 이는 AWS 인증이 아니다.

## 세 API

| 요청 | 결과 |
| --- | --- |
| GET `/quiz` | quiz_id=math-v1, 문제 10개, 각 선택지 4개. 정답 인덱스는 반환하지 않음 |
| GET `/players/alice` | Alice의 score/version/latest_result. Bob 토큰으로는 403 |
| POST `/players/alice/results` | 아래 답안 제출. Content-Type: application/json 필요 |

경로 player_id는 영숫자로 시작하는 영숫자/_/- 1~64자다. 실제 허용 소유자는 서버 매핑의 alice/bob뿐이다. 본문 player_id·헤더 owner로 사용자를 바꿀 수 없다. 전체 이력 조회·페이지 API는 아직 만들지 않았다. 조회 API는 **현재 상태와 최근 결과**만 반환하며, 모든 이력은 로컬 events 테이블에 보존한다.

## 제출

```json
{
  "event_id": "round-001",
  "quiz_id": "math-v1",
  "expected_version": 0,
  "answers": [0, 1, 2, 3, 0, 1, 2, 0, 1, 0],
  "test_run_id": "manual-001"
}
```

- 위 답안은 7개 정답이므로 서버가 70점으로 계산한다.
- answers는 문제 순서에 따른 **0부터 시작하는 선택지 번호** 10개다. 숫자 문자열·float·bool·null은 거부한다.
- expected_version은 직전 내 상태 조회 결과다. 새로운 사용자는 0. 새 제출은 버전을 1 올린다.
- event_id/test_run_id는 영숫자로 시작하는 영숫자/_/- 1~64자다. 새 플레이에는 새 event_id를 사용한다.
- 재시도는 **원래 본문 전체를 그대로** 보낸다. expected_version도 임의로 최신값으로 바꾸지 않는다.
- expected_version 범위는 0 이상, 2^53−1 미만이다. 추가 필드·누락 필드·중복 JSON 키·NaN/Infinity·16 KiB 초과를 거부한다.
- 쿼리 파라미터는 지원하지 않는다. 문제은행 수정은 같은 math-v1을 덮어쓰지 않고 새 버전으로 한다.

## 성공 응답 예시

아래 시각은 예시다. 실제 응답은 서버가 처음 저장한 UTC 밀리초 시각을 사용한다.

```json
{
  "player_id": "alice",
  "event_id": "round-001",
  "quiz_id": "math-v1",
  "score": 70,
  "correct_count": 7,
  "question_count": 10,
  "version": 1,
  "recorded_at": "2026-08-27T01:02:03.004Z"
}
```

새 제출은 201이다. 같은 ID/같은 내용 재시도는 200이며 **원래 성공 응답 본문**을 반환한다. 응답 헤더 X-Idempotent-Replay가 true다. 그 이후 다른 플레이가 저장됐어도 과거 재시도는 현재 점수/버전을 되돌리지 않는다. X-Request-Id는 호출마다 새로 생성하므로 달라질 수 있다.

## 실패 응답

```json
{
  "error": {"code": "VERSION_CONFLICT", "message": "현재 버전을 조회하고 새로운 제출 여부를 확인하세요."},
  "request_id": "서버가 생성한 요청 ID"
}
```

| 상태 | 대표 코드 | 의미·대응 |
| --- | --- | --- |
| 400 | INVALID_FIELDS / INVALID_ANSWERS / INVALID_JSON / INVALID_VERSION | 입력 수정. 무한 재시도 금지 |
| 401 | UNAUTHENTICATED | 테스트 토큰 없음/유효하지 않음 |
| 403 | FORBIDDEN / LOCAL_ONLY | 소유권 거부 또는 로컬 서버 외부 사용 시도 |
| 404 | NOT_FOUND | 없는 경로 |
| 405 | METHOD_NOT_ALLOWED | 잘못된 HTTP 메서드 |
| 409 | IDEMPOTENCY_CONFLICT | 같은 ID의 요청 내용이 다름. 기존 요청을 확인 |
| 409 | VERSION_CONFLICT | 현재 버전과 다름. 최신 상태를 읽고 새 플레이인지 판단 |
| 413 | BODY_TOO_LARGE | 본문 16 KiB 초과 |
| 415 | UNSUPPORTED_MEDIA_TYPE | application/json 필요 |
| 503 | STORAGE_UNAVAILABLE | 저장 실패. 원래 본문/ID로 제한 재시도 |
| 503 | DEPLOYMENT_NOT_CONFIGURED | AWS 진입점은 아직 미연결. 로컬 서버로 실행 |
| 500 | INTERNAL_ERROR | 예상 밖 코드 오류. request_id와 로컬 로그 확인 |

## 저장 계약

Players: player_id, 가장 최근 score, version, latest_event_id.

Events: 키 `(player_id,event_id)`, request_hash, payload_hash, 이벤트 본문, 원래 응답, 시간 검색용 키. 로컬 저장은 한 SQLite 거래다. 향후 DynamoDB에서는 같은 책임을 조건부 거래로 구현하고 실제 AWS에서 다시 검증한다.

request_hash 입력: schema_version=2, event_type=QuizCompleted, player_id, event_id, quiz_id, expected_version, answers, test_run_id.

payload_hash 입력: schema_version=2, event_type=QuizCompleted, player_id, event_id, entity_version, quiz_id, answers, correct_count, question_count, score, occurred_at, recorded_at, test_run_id.

정규화: 키 정렬·공백 없는 UTF-8 JSON·NaN 금지 후 SHA256. answers 배열 순서는 의미가 있으므로 바꾸지 않는다. request_hash/원래 응답/검색 키는 payload_hash에 포함하지 않는다. 현재 occurred_at과 recorded_at은 서버가 제출을 처리한 같은 시각이며 실제 DB commit 시각이나 클라이언트 경기 시작/종료 시각이라고 주장하지 않는다.

검색 키는 recovery_pk=`YYYY-MM-DDTHH`, recovery_sk=`recorded_at#player_id#event_id`다. 이번에는 키 값만 저장하며 GSI·분석·재전송은 실행하지 않는다.

## 보안 범위

서버 채점·소유권 검사·중복 제출 방지를 시험한다. 공개된 고정 문제/정답, 테스트 토큰, 무제한 새 플레이를 이용한 부정행위까지 막는 게임은 아니다. 클라이언트 위변조 방지·회원가입·계정 탈취 대응·실제 AWS_IAM 인증은 이번 단계의 증거에 포함하지 않는다.
