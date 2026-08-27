# Step 3 배포 + Step 4 구현 검증 기록

2026-08-27 · observed · Terraform 1.15.8 / hashicorp/aws 6.62.0 / AWS CLI 2.36.32

## 판정

Step 3의 기반 인프라 Terraform 작성, 실제 AWS 적용과 설정 검증을 완료했다. 포트폴리오용 개발 계정의 서울 리전에 `32 added / 0 changed / 0 destroyed`로 적용했고, 다시 plan한 결과 변경 사항이 없었다. 공개 문서에는 계정 ID와 리소스 ID를 기록하지 않는다.

Step 4의 DynamoDB 어댑터·Lambda·IAM 인증 API·WAF를 `23 added / 3 changed / 0 destroyed`로 적용했다. 실제 IAM 서명 API 시나리오와 AWS 설정 조회를 통과했고 재계획은 무변경이었다.

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
- 리전 전체 장애 복구와 원격 Terraform state 복구
- 부트스트랩 배포 사용자의 MFA 등록과 `PowerUserAccess`를 전용 배포 역할로 축소하는 작업

API Gateway·Lambda·WAF의 Step 4 검증은 완료했다. Streams·Pipes·Firehose·S3 전달과 Athena는 Step 5에서 검증한다. 현재 리소스는 비용이 발생할 수 있으므로 실습 종료 시 [README.md](README.md)의 보호 해제·destroy 절차를 따른다.
