# Step 9 — 로컬 AWS SAP 퀴즈 UI

## 목표

기존 Python·SQLite 백엔드에 별도 프레임워크나 배포 서비스를 추가하지 않고, 브라우저에서 실제로 풀 수 있는 10문제 UI를 연결한다. 문제는 AWS Certified Solutions Architect – Professional(SAP-C02)의 네 개 콘텐츠 도메인을 참고해 이 프로젝트용으로 새로 작성했다. AWS 공식 기출·모의 문제를 복제한 것이 아니며 실제 시험 출제를 보장하지 않는다.

문제 범위는 조직 네트워크, 중앙 감사, 재해 복구, 순서 보장 메시징, DynamoDB 핫 키, 데이터 레이크 권한, 마이그레이션, Lambda canary 배포, 글로벌 게임 네트워크, 24시간 초과 이벤트 복구다.

## 실행 흐름

```text
브라우저
  ├─ GET /                         HTML/CSS/JavaScript
  ├─ GET /quiz                     정답을 제외한 10문제
  ├─ GET /players/alice            최근 점수와 version
  └─ POST /players/alice/results   서버 채점 → SQLite 거래 저장
```

UI는 Alice 로컬 실습 사용자로 고정한다. 답안 10개를 모두 선택하기 전에는 제출할 수 없고, 성공하면 점수·정답 수·기록 버전·저장 시각을 표시한다. 새로고침하면 SQLite에서 최근 점수를 다시 조회한다. 다른 제출이 먼저 반영되어 409 VERSION_CONFLICT가 발생하면 자동 재제출하지 않고 최신 기록만 다시 읽어 사용자가 답안을 확인하게 한다.

## Light guardrail

- 서버는 계속 `127.0.0.1`에만 바인딩한다.
- 정적 파일은 세 개의 고정 경로만 제공하며 임의 파일 경로를 받지 않는다.
- API는 같은 로컬 Origin만 허용하고 외부 Origin과 변조된 Host를 거부한다.
- HTML은 인라인 스크립트 없이 CSP, frame 차단, no-sniff, no-store 헤더를 사용한다.
- 로컬 Bearer 값은 공개 실습 사용자 선택값일 뿐 실제 인증으로 주장하지 않는다.
- Cognito, S3 정적 호스팅, CloudFront, 새 AWS 리소스는 추가하지 않는다.
- 기존 AWS Lambda에는 Step 9 코드를 apply하지 않는다. 현재 공개 웹 로그인이나 AWS UI 연결을 주장하지 않는다.

공유 백엔드 소스의 문제은행은 `aws-sap-architecture-v1`로 바뀌었지만, 이번 단계는 로컬 전용이므로 기존 Step 8 AWS Lambda 배포본은 변경하지 않았다. 향후 별도 승인을 받아 백엔드도 갱신하기 전에는 Terraform plan에 Lambda 코드 변경이 표시될 수 있다.

## 검증

2026-08-27에 다음을 확인했다.

- Python 자동 테스트 40개 통과
- GET `/`, CSS, JavaScript의 상태·Content-Type·보안 헤더 확인
- 외부 Host/Origin 403, 같은 로컬 Origin API 200 확인
- 실제 인앱 브라우저에서 radio 40개와 문제 카드 10개 렌더링
- 정답 10개 선택 전 제출 비활성, 선택 후 활성 확인
- 실제 제출 결과 100점·10/10·기록 #1 저장
- 열린 화면보다 다른 제출이 먼저 저장된 상황에서 409 안내·최신 점수 재조회·자동 재제출 없음 확인
- 운영자 확인에 해당하는 두 번째 클릭으로 100점·기록 #3 저장
- 새로고침 후 100점 유지와 브라우저 경고·오류 0건 확인
- AWS 호출·Terraform apply·신규 과금 리소스 없음

## 문제 설계 근거

시험 범위는 [SAP-C02 공식 시험 가이드](https://docs.aws.amazon.com/aws-certification/latest/solutions-architect-professional-02/solutions-architect-professional-02.html)의 조직 복잡성, 신규 설계, 지속 개선, 마이그레이션·현대화 도메인을 사용했다. 정답 설계는 다음 AWS 공식 문서의 서비스 동작과 대조했다.

- [Transit Gateway 공유와 Direct Connect 연결](https://docs.aws.amazon.com/vpc/latest/tgw/working-with-transit-gateways.html)
- [S3 Object Lock 규정 준수 모드](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)
- [Aurora Global Database 장애 복구](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database-disaster-recovery.html)
- [SQS FIFO 메시지 그룹과 중복 제거](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues-understanding-logic.html)
- [DynamoDB 쓰기 샤딩](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-partition-key-sharding.html)
- [Lake Formation 교차 계정 리소스 링크](https://docs.aws.amazon.com/lake-formation/latest/dg/resource-links-about.html)
- [Application Discovery Service와 Migration Hub](https://docs.aws.amazon.com/application-discovery/latest/userguide/what-is-appdiscovery.html)
- [Lambda CodeDeploy canary](https://docs.aws.amazon.com/codedeploy/latest/userguide/applications-create-lambda.html)
- [Global Accelerator 고정 IP와 상태 기반 라우팅](https://docs.aws.amazon.com/global-accelerator/latest/dg/introduction-how-it-works.html)
- [DynamoDB Streams 24시간 보관](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.CoreComponents.html)과 [Transactional outbox](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html)

## 포트폴리오 설명

“인프라 증거만으로는 사용자가 무엇을 만드는지 체감하기 어려워, 같은 서버 채점·멱등성·버전 제어 계약을 사용하는 로컬 UI를 붙였습니다. 브라우저는 답안과 기대 버전만 보내고 점수는 서버가 계산합니다. 공개 인증은 이 단계의 목표가 아니므로 Cognito와 웹 호스팅은 넣지 않았고, 실제 AWS 모니터링·분석·복구 증거와 로컬 플레이 경험을 분리했습니다.”
