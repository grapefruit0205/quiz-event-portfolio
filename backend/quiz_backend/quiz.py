"""Small, fixed quiz and the closed request/event contract."""

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import re

MAX_BODY_BYTES = 16 * 1024
MAX_VERSION = 2**53 - 1
QUIZ_ID = "aws-sap-architecture-v1"
SCHEMA_VERSION = 2
EVENT_TYPE = "QuizCompleted"
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")

# (domain, question, choices, correct index). A changed question bank needs a new quiz_id.
QUESTIONS = (
    (
        "조직 · 네트워크",
        "한 회사가 단일 리전의 AWS Organizations 아래 80개 계정을 운영합니다. 각 계정의 VPC는 온프레미스 데이터센터와 통신해야 하지만 개발·운영 네트워크 사이의 통신은 분리해야 합니다. VPC 피어링 전면 연결은 운영 부담이 너무 크고, 기존 Direct Connect 연결은 유지해야 합니다. 가장 적절한 설계는 무엇입니까?",
        (
            "모든 VPC 사이에 피어링을 만들고 각 VPC에서 Direct Connect 가상 인터페이스를 별도로 생성한다.",
            "각 VPC에 NAT Gateway를 배치하고 인터넷을 통해 온프레미스 VPN을 연결한다.",
            "네트워크 계정에 Transit Gateway를 두고 AWS RAM으로 공유한 뒤, 개발·운영용 TGW 라우팅 테이블을 분리하고 Direct Connect Gateway를 연결한다.",
            "운영 VPC 하나를 전송 VPC로 지정하고 보안 그룹 참조만으로 다른 VPC의 경로를 자동 전파한다.",
        ),
        2,
    ),
    (
        "보안 · 감사",
        "보안팀은 모든 멤버 계정과 리전의 관리 이벤트를 중앙 보관해야 합니다. 멤버 계정 관리자는 수집을 중지하거나 보존된 로그를 변경할 수 없어야 하며, 규정상 7년간 WORM 보관이 필요합니다. 운영 부담이 가장 적은 조합은 무엇입니까?",
        (
            "Organizations 조직 추적을 로그 아카이브 계정의 버전 관리 S3 버킷으로 보내고 Object Lock 규정 준수 모드를 적용하며, SCP로 추적 중지·삭제 작업을 제한한다.",
            "각 계정에서 CloudWatch Logs 에이전트를 실행하고 로그 그룹의 보존 기간만 7년으로 설정한다.",
            "AWS Config 집계기를 사용해 모든 API 호출을 수집하고 S3 Glacier Flexible Retrieval로 즉시 전환한다.",
            "멤버 계정마다 독립 CloudTrail을 만들고 각 계정 관리자에게 추적과 버킷의 전체 관리 권한을 부여한다.",
        ),
        0,
    ),
    (
        "복원력 · DR",
        "Aurora PostgreSQL 기반 주문 서비스가 한 리전에서 Multi-AZ로 운영됩니다. 리전 장애 시 RPO 수초 이내와 RTO 5분 이내가 필요하며, 정상 시 보조 리전의 읽기 용량도 활용하려 합니다. 애플리케이션 변경과 복구 작업을 최소화하는 설계는 무엇입니까?",
        (
            "매일 AWS Backup 스냅샷을 다른 리전으로 복사하고 장애 시 새 클러스터로 복원한다.",
            "DMS 전체 로드를 매시간 실행해 보조 리전의 독립 Aurora 클러스터를 갱신한다.",
            "동일 리전의 Aurora Replica를 늘리고 리전 장애 시 스냅샷을 수동 복사한다.",
            "Aurora Global Database에 프로비저닝된 보조 리전을 구성하고 읽기 트래픽을 분산하며, 런북으로 보조 클러스터 승격과 애플리케이션 엔드포인트 전환을 시험한다.",
        ),
        3,
    ),
    (
        "통합 · 메시징",
        "게임 이벤트 API에 짧은 시간 동안 평소의 100배 트래픽이 유입됩니다. 이벤트는 플레이어별 순서를 유지해야 하고, 같은 event_id의 재시도가 중복 반영되어서는 안 됩니다. 소비자는 일시적으로 중단될 수 있습니다. 가장 적절한 설계는 무엇입니까?",
        (
            "SNS Standard 주제로 직접 발행하고 모든 소비자가 도착 순서대로 처리한다고 가정한다.",
            "SQS FIFO 큐에서 player_id를 MessageGroupId, event_id를 중복 제거 ID로 사용하고, 멱등 소비자·가시성 시간 제한·DLQ를 구성한다.",
            "EventBridge 기본 버스에 발행하고 재시도 기간 없이 실패 이벤트를 폐기한다.",
            "API Gateway 요청 제한을 크게 높이고 모든 이벤트를 Lambda 메모리에 임시 보관한다.",
        ),
        1,
    ),
    (
        "데이터베이스 · 성능",
        "DynamoDB에서 전 세계 토너먼트 점수를 PK=TOURNAMENT#2026인 단일 항목의 카운터로 갱신합니다. 테이블 전체 용량은 충분하지만 결승전마다 해당 키에서 쓰기 제한이 발생합니다. 읽기 시 수 초의 지연된 집계는 허용됩니다. 가장 확장성 있는 개선안은 무엇입니까?",
        (
            "DAX를 추가해 UpdateItem 쓰기를 캐시한다.",
            "테이블의 전체 프로비저닝 WCU만 계속 높인다.",
            "점수 쓰기를 결정 가능한 여러 샤드 키로 분산하고 DynamoDB Streams 소비자가 조회용 집계 항목을 비동기로 갱신하게 한다.",
            "같은 파티션 키를 사용하는 GSI를 추가하고 모든 쓰기를 GSI로 보낸다.",
        ),
        2,
    ),
    (
        "분석 · 거버넌스",
        "여러 사업부 계정이 각자 S3에 Parquet 데이터를 저장합니다. 중앙 분석 계정은 Athena로 이를 조회해야 하며, 팀별로 허용된 행과 열만 보여야 합니다. 데이터를 복사하지 않고 중앙에서 권한과 스키마를 관리하려면 무엇을 사용해야 합니까?",
        (
            "Lake Formation에서 데이터 위치를 등록하고 LF-Tag 권한과 행·열 데이터 필터를 교차 계정으로 부여하며, 소비 계정은 Glue Data Catalog 리소스 링크를 통해 조회한다.",
            "모든 버킷을 퍼블릭 읽기로 바꾸고 Athena workgroup 이름으로 접근을 구분한다.",
            "각 분석가에게 S3 관리자 권한을 주고 로컬 CSV 파일로 내려받아 필터링한다.",
            "사업부마다 Redshift 클러스터를 만들고 매일 전체 데이터를 중앙 클러스터로 복사한다.",
        ),
        0,
    ),
    (
        "마이그레이션 · 현대화",
        "수천 대의 온프레미스 VMware 서버를 여러 차수로 AWS에 이전해야 합니다. 애플리케이션 의존 관계가 문서화되어 있지 않고, 경영진은 차수별 진행 상황을 중앙에서 확인하려 합니다. 재호스팅 대상의 중단 시간을 최소화하는 조합은 무엇입니까?",
        (
            "AWS DMS만 사용해 VM 디스크와 네트워크 구성을 모두 복제한다.",
            "Application Discovery Service Agentless Collector 또는 Discovery Agent로 현황과 의존 관계를 수집하고 Migration Hub에서 차수를 추적하며, AWS Application Migration Service로 재호스팅 서버를 지속 복제한다.",
            "Snowcone 한 대로 모든 VM을 옮기고 Systems Manager가 자동으로 의존 관계를 복원하게 한다.",
            "VM마다 AMI를 수동 생성한 뒤 의존 관계 확인 없이 한 번에 모두 시작한다.",
        ),
        1,
    ),
    (
        "배포 · 운영",
        "결제 Lambda의 새 버전을 출시해야 합니다. 전체 트래픽 전환 전에 실제 요청의 10%로 오류율을 관찰하고, 오류 임계값을 넘으면 자동으로 이전 버전으로 돌아가야 합니다. 가장 관리 부담이 적은 방법은 무엇입니까?",
        (
            "함수 코드를 $LATEST에 덮어쓴 뒤 문제가 생기면 콘솔에서 이전 ZIP을 다시 올린다.",
            "두 Lambda 함수를 직접 만들고 Route 53 가중치 레코드로 10%를 분산한다.",
            "Reserved Concurrency를 10%로 설정하면 호출의 10%만 새 코드로 전달되므로 CloudWatch 경보만 추가한다.",
            "Lambda 버전과 별칭을 사용하고 CodeDeploy canary 배포 및 CloudWatch 경보 기반 자동 롤백을 구성한다.",
        ),
        3,
    ),
    (
        "글로벌 네트워크",
        "UDP와 TCP를 모두 사용하는 실시간 게임 세션이 두 리전의 NLB에서 실행됩니다. 콘솔 클라이언트의 방화벽 허용 목록에는 변경되지 않는 IP가 필요하고, 사용자는 가장 가까운 정상 리전으로 빠르게 연결되어야 합니다. 어떤 서비스가 핵심입니까?",
        (
            "AWS Global Accelerator에서 고정 Anycast IP와 엔드포인트 상태 검사를 사용해 리전별 NLB로 라우팅한다.",
            "CloudFront 배포의 캐시 동작으로 모든 UDP 세션을 NLB에 전달한다.",
            "Transit Gateway 피어링 주소를 인터넷 클라이언트에 공개한다.",
            "Route 53 단순 라우팅만 사용하고 DNS TTL을 24시간으로 설정한다.",
        ),
        0,
    ),
    (
        "이벤트 · 장기 복구",
        "DynamoDB의 현재 상태 변경을 Streams → Pipes → Firehose → S3로 분석합니다. 분석 경로가 24시간 넘게 중단되더라도 모든 업무 변경 이력을 복구해야 하며, 복구가 정상 API를 압박해서는 안 됩니다. 가장 적절한 보완은 무엇입니까?",
        (
            "Streams 보관 기간이 무제한이라고 가정하고 장애가 끝날 때까지 아무 작업도 하지 않는다.",
            "Firehose가 성공을 반환하면 업무 원본을 즉시 삭제하고 S3 객체 수만 확인한다.",
            "현재 상태와 불변 event_id가 있는 이력 항목을 트랜잭션으로 함께 저장하고, 평상시에는 Streams 경로를 사용하되 장기 장애에는 체크포인트·속도 상한·멱등성을 갖춘 이력 재전송을 수행한다.",
            "모든 API 요청을 CloudWatch Logs에만 기록하고 로그가 있으면 원본 이벤트와 동일하다고 간주한다.",
        ),
        2,
    ),
)


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def canonical_json(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False)


def content_hash(value) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def valid_identifier(value) -> bool:
    return isinstance(value, str) and IDENTIFIER.fullmatch(value) is not None


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(value):
    raise ValueError("non-finite JSON number")


def parse_json(body: str):
    if not isinstance(body, str):
        raise ApiError(400, "INVALID_JSON", "JSON 문자열 본문이 필요합니다.")
    try:
        size = len(body.encode("utf-8"))
    except UnicodeError as exc:
        raise ApiError(400, "INVALID_JSON", "올바른 UTF-8 JSON이 필요합니다.") from exc
    if size > MAX_BODY_BYTES:
        raise ApiError(413, "BODY_TOO_LARGE", "본문은 16 KiB 이하여야 합니다.")
    try:
        return json.loads(body, object_pairs_hook=_unique_object,
                          parse_constant=_reject_constant)
    except (ValueError, RecursionError) as exc:
        raise ApiError(400, "INVALID_JSON", "중복 키 없는 유효한 JSON이 필요합니다.") from exc


@dataclass(frozen=True)
class Submission:
    event_id: str
    quiz_id: str
    expected_version: int
    answers: tuple[int, ...]
    test_run_id: str

    def request_fields(self, player_id: str) -> dict:
        return {
            "schema_version": SCHEMA_VERSION, "event_type": EVENT_TYPE,
            "player_id": player_id, "event_id": self.event_id,
            "quiz_id": self.quiz_id, "expected_version": self.expected_version,
            "answers": list(self.answers), "test_run_id": self.test_run_id,
        }


def validate_submission(value) -> Submission:
    fields = {"event_id", "quiz_id", "expected_version", "answers", "test_run_id"}
    if not isinstance(value, dict) or set(value) != fields:
        raise ApiError(400, "INVALID_FIELDS", "event_id, quiz_id, expected_version, answers, test_run_id만 필요합니다.")
    for name in ("event_id", "test_run_id"):
        if not valid_identifier(value[name]):
            raise ApiError(400, "INVALID_IDENTIFIER", f"{name}: 영숫자로 시작하는 영숫자/_/- 1~64자여야 합니다.")
    if value["quiz_id"] != QUIZ_ID:
        raise ApiError(400, "UNKNOWN_QUIZ", "지원하지 않는 문제 버전입니다.")
    version = value["expected_version"]
    if type(version) is not int or not 0 <= version < MAX_VERSION:
        raise ApiError(400, "INVALID_VERSION", "expected_version은 허용 범위의 정수여야 합니다.")
    answers = value["answers"]
    if (not isinstance(answers, list) or len(answers) != len(QUESTIONS)
            or any(type(a) is not int or not 0 <= a <= 3 for a in answers)):
        raise ApiError(400, "INVALID_ANSWERS", "answers는 문제 순서대로 0~3 정수 10개여야 합니다.")
    return Submission(value["event_id"], value["quiz_id"], version,
                      tuple(answers), value["test_run_id"])


def public_quiz() -> dict:
    return {"quiz_id": QUIZ_ID, "question_count": len(QUESTIONS), "points_per_question": 10,
            "questions": [{"question_id": f"q{i}", "domain": domain,
                           "text": text, "choices": list(choices)}
                          for i, (domain, text, choices, _) in enumerate(QUESTIONS, 1)]}


def grade(submission: Submission) -> tuple[int, int]:
    correct = sum(answer == question[3]
                  for answer, question in zip(submission.answers, QUESTIONS, strict=True))
    return correct, correct * 10


def make_event(player_id: str, submission: Submission, version: int,
               recorded_at: str, correct: int, score: int) -> dict:
    return {
        "schema_version": SCHEMA_VERSION, "event_type": EVENT_TYPE,
        "player_id": player_id, "event_id": submission.event_id,
        "entity_version": version, "quiz_id": submission.quiz_id,
        "answers": list(submission.answers), "correct_count": correct,
        "question_count": len(QUESTIONS), "score": score,
        "occurred_at": recorded_at, "recorded_at": recorded_at,
        "test_run_id": submission.test_run_id,
    }
