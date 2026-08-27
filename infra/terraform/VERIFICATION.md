# Step 3 검증 기록

2026-08-27 · observed · Terraform 1.15.8 / hashicorp/aws 6.62.0 / AWS CLI 2.36.32

## 판정

Step 3의 기반 인프라 Terraform 작성, 실제 AWS 적용과 설정 검증을 완료했다. 포트폴리오용 개발 계정의 서울 리전에 `32 added / 0 changed / 0 destroyed`로 적용했고, 다시 plan한 결과 변경 사항이 없었다. 공개 문서에는 계정 ID와 리소스 ID를 기록하지 않는다.

## 수행한 검사

| 검사 | 판정 | 실제 관찰 |
| --- | --- | --- |
| `terraform fmt -check -recursive` | pass | 포맷 차이 없음 |
| `terraform validate` | pass | 오류 0, 경고 0 |
| `terraform test -verbose` | pass | mock 가드레일 run 1개 통과, 실패 0 |
| mock plan | pass | 32 add, 0 change, 0 destroy |
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

상세 명령 결과는 Git에서 제외된 `work/quiz-step3-verification/aws-apply/`에 보관한다. Terraform state와 저장 plan 역시 Git에 올리지 않으며 로컬 파일 권한을 `600`으로 제한했다.

## 아직 증명하지 않은 것

- API Gateway·Lambda에서 실제 IAM 역할로 업무 요청 처리
- Players 갱신과 Events 추가를 묶은 DynamoDB `TransactWriteItems`
- 다른 사용자 데이터 변경 거부
- DynamoDB PITR 복원 시간과 복원 데이터 내용
- S3 객체 버전 복구와 실제 청구 비용
- 리전 전체 장애 복구와 원격 Terraform state 복구
- 부트스트랩 배포 사용자의 MFA 등록과 `PowerUserAccess`를 전용 배포 역할로 축소하는 작업

API Gateway·Lambda·WAF는 Step 4, Streams·Pipes·Firehose·S3 전달과 Athena는 Step 5에서 검증한다. 현재 리소스는 비용이 발생할 수 있으므로 실습 종료 시 [README.md](README.md)의 보호 해제·destroy 절차를 따른다.
