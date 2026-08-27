# Step 3~5 배포·구현 검증 기록

2026-08-27 · observed · Terraform 1.15.8 / hashicorp/aws 6.62.0 / AWS CLI 2.36.32

## 판정

Step 3의 기반 인프라 Terraform 작성, 실제 AWS 적용과 설정 검증을 완료했다. 포트폴리오용 개발 계정의 서울 리전에 `32 added / 0 changed / 0 destroyed`로 적용했고, 다시 plan한 결과 변경 사항이 없었다. 공개 문서에는 계정 ID와 리소스 ID를 기록하지 않는다.

Step 4의 DynamoDB 어댑터·Lambda·IAM 인증 API·WAF를 `23 added / 3 changed / 0 destroyed`로 적용했다. 실제 IAM 서명 API 시나리오와 AWS 설정 조회를 통과했고 재계획은 무변경이었다.

Step 5의 Pipes·Firehose·S3·Glue·Athena를 리소스 12개 추가로 적용했다. 첫 내용 검증에서 여러 줄 JSON 문제를 발견해 기존 객체 삭제 없이 세 리소스를 제자리 수정했고, 두 번째 라이브 이벤트의 원본·S3·Athena 내용 대조와 무변경 재계획을 통과했다.

## 수행한 검사

| 검사 | 판정 | 실제 관찰 |
| --- | --- | --- |
| `terraform fmt -check -recursive` | pass | 포맷 차이 없음 |
| `terraform validate` | pass | 오류 0, 경고 0 |
| `terraform test -verbose` | pass | mock 가드레일 run 1개 통과, 실패 0 |
| Step 3 mock plan | pass | 32 add, 0 change, 0 destroy |
| AWS 신원·리전 | pass | 비루트 IAM 사용자, 포트폴리오용 계정, `ap-northeast-2`; 사용자 MFA는 미검증 |
| 실제 plan·apply | pass | 32 add/added, 0 change/changed, 0 destroy/destroyed |
| apply 후 plan | pass | `No changes. Your infrastructure matches the configuration.` |

## Step 5 전달·분석 검사

| 검사 | 판정 | 실제 관찰 |
| --- | --- | --- |
| Terraform 포맷·validate·mock test | pass | 오류·경고 0, 가드레일 run 1개 통과 |
| 최초 Step 5 적용 | pass | 총 12개 리소스 추가, 기존 리소스 삭제 0 |
| Pipe/Firehose 상태 | pass | Pipe RUNNING, Firehose ACTIVE·암호화 ENABLED |
| 첫 라이브 probe | fail 후 수정 | 전달 지표는 각각 1건 성공했지만 여러 줄 JSON이 NDJSON 계약을 위반함 |
| 수정 plan/apply | pass | `0 add / 3 change / 0 destroy`, 교체 없이 경로·템플릿·Catalog 위치만 변경 |
| DynamoDB 원본 | pass | `body_json` SHA256과 저장된 `payload_hash` 일치 |
| S3 내용 | pass | GZIP NDJSON의 ID·hash·본문이 DynamoDB와 일치 |
| Athena | pass | 같은 `event_id`와 `payload_hash` 반환, 질의 성공 |
| Pipe DLQ | pass | visible 0, in-flight 0 |
| 최종 plan | pass | `No changes. Your infrastructure matches the configuration.` |
| 네트워크 | pass | 비기본 VPC available, 두 AZ의 비공개 서브넷 2개, DynamoDB Gateway Endpoint available |
| 인터넷 경로 | pass | `0.0.0.0/0` 경로 0개, Internet Gateway 0개, NAT Gateway 0개 |
| Lambda 보안 그룹 | pass | ingress 0개, DynamoDB prefix list의 TCP 443 egress 1개 |
| DynamoDB | pass | Players·Events ACTIVE, PAY_PER_REQUEST, 삭제 보호, PITR 14일 |
| Events 전달 준비 | pass | `NEW_IMAGE` Stream과 `recovery-by-time` GSI ACTIVE |
| S3 | pass | 세 버킷 모두 서울 리전, Block Public Access, Versioning, SSE-S3, 비공개 정책 |
| IAM 런타임 역할 | pass | Lambda 서비스 신뢰와 프로젝트 인라인 정책 확인 |
| 기존 백엔드 | pass | Python 자동 테스트 27개 통과 |

## Step 4 apply 전 검사

| 검사 | 판정 | 실제 관찰 |
| --- | --- | --- |
| Python 전체 테스트 | pass | 38개, 실패·오류·skip 0 |
| DynamoDB 어댑터 | pass | 조건부 거래 요청, 멱등 재시도, 버전/ID 충돌, 불명확한 거래 결과 재조회, event hash·응답 불일치 탐지, 저장 장애의 안전한 오류 변환 |
| AWS 역할 신원 | pass | STS assumed-role ARN을 고정 IAM role ARN으로 매핑하는 테스트 |
| Lambda 배포 ZIP | pass | 런타임에 필요한 Python 파일 4개만 포함, ZIP 무결성 오류 0 |
| Terraform 포맷·validate | pass | 오류·경고 0 |
| Terraform mock guardrail | pass | API IAM 인증, throttling, private Lambda, 로그 보관, WAF rate rule, DynamoDB 최대 처리량, 호출 역할 검사 |
| 실제 AWS plan | pass | `23 add / 3 change / 0 destroy`; replace/delete action 0 |
| 실제 apply | pass | `23 added / 3 changed / 0 destroyed` |
| 실제 IAM API | pass | 익명403, Alice 자기 조회200·Bob 조회403, 새 거래201, 재시도200, 다른 본문409, Bob 자기 조회200 |
| AWS 설정 조회 | pass | Lambda Active/VPC/256MB/10초, IAM method 3개, stage 5 req/s·burst10, WAF 60초100, 테이블 최대100 RRU/WRU, 로그7일 |
| apply 후 plan | pass | `No changes. Your infrastructure matches the configuration.` |

3개 제자리 변경은 Players·Events의 온디맨드 최대 요청 단위 추가와 Lambda 실행 역할의 불필요한 `logs:CreateLogGroup` 제거다. WAF는 월 기준 web ACL US$5와 rule US$1이 시간 비례 청구되며 요청 요금이 별도다.

상세 명령 결과는 Git에서 제외된 `work/quiz-step3-verification/`과 `work/quiz-step4-verification/`에 보관한다. Terraform state와 저장 plan 역시 Git에 올리지 않으며 로컬 파일 권한을 `600`으로 제한했다.

## 아직 증명하지 않은 것

- WAF/API Gateway/Lambda/DynamoDB throttling과 실제 알람 수신
- DynamoDB PITR 복원 시간과 복원 데이터 내용
- S3 객체 버전 복구와 실제 청구 비용
- 24시간을 넘긴 분석 누락의 제한 속도 재전송과 중단·재개
- 리전 전체 장애 복구와 원격 Terraform state 복구
- 부트스트랩 배포 사용자의 MFA 등록과 `PowerUserAccess`를 전용 배포 역할로 축소하는 작업

API Gateway·Lambda·WAF의 Step 4와 Streams·Pipes·Firehose·S3·Athena의 Step 5 검증을 완료했다. 현재 리소스는 비용이 발생할 수 있으므로 실습 종료 시 [README.md](README.md)의 보호 해제·destroy 절차를 따른다.
