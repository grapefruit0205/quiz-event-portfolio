# Step 3 검증 기록

2026-08-27 · observed · Terraform 1.15.8 / hashicorp/aws 6.62.0

## 판정

Step 3의 기반 인프라 Terraform 작성과 자격증명 없는 로컬 검증을 완료했다. 실제 AWS 계정의 리소스 생성은 실행하지 않았다. 따라서 이 기록은 설정 계약을 증명하며, AWS 서비스 생성 성공이나 런타임 동작을 증명하지 않는다.

## 수행한 검사

| 검사 | 판정 | 실제 관찰 |
| --- | --- | --- |
| `terraform fmt -check -recursive` | pass | 포맷 차이 없음 |
| `terraform validate` | pass | 오류 0, 경고 0 |
| `terraform test -verbose` | pass | 가드레일 run 1개 통과, 실패 0 |
| mock plan | pass | 32 add, 0 change, 0 destroy |
| 네트워크 가드레일 | pass | 프라이빗 서브넷·라우팅 테이블 각 2개, 공개 IP 자동 할당 금지, DynamoDB Gateway Endpoint, prefix list TCP 443 |
| 데이터 보호 가드레일 | pass | 두 DynamoDB 테이블 온디맨드·PITR·삭제 보호, Events NEW_IMAGE Stream |
| S3 가드레일 | pass | 버킷 3개, Versioning과 네 가지 Block Public Access 설정 |
| 실제 AWS plan | unavailable | 격리된 빈 자격증명 설정으로 실행해 `No valid credential sources found` 확인 |
| 실제 AWS apply·런타임 | not run | DynamoDB·S3·IAM·VPC 리소스를 생성하지 않음 |

## 범위 확인

이 단계에는 VPC, 두 프라이빗 서브넷, DynamoDB Gateway Endpoint, Players/Events, S3 세 버킷, 향후 Lambda 실행 역할만 포함한다. NAT Gateway, Internet Gateway, EKS, Redis, 고객 관리 KMS 키, API Gateway, WAF, Firehose, Athena는 생성하지 않는다.

모의 테스트는 다음을 확인하지 못한다.

- 선택한 개발 계정에서의 IAM 허용 여부와 Service Control Policy
- 실제 리소스 이름 충돌, 할당량, 서비스 상태
- Lambda의 `TransactWriteItems`와 다른 사용자 접근 거부
- DynamoDB PITR 복원 시간과 복원 데이터 내용
- S3 객체 버전 복구와 실제 비용

## 다음 Gate

실제 배포 전 포트폴리오용 개발 계정에 로컬 인증하고, `terraform plan` 출력의 계정 ID·서울 리전·32개 생성·삭제 0개를 다시 확인한다. 기존 운영 또는 프로덕션 프로필은 사용하지 않는다. apply 뒤에는 리소스 상태와 보호 설정을 AWS에서 다시 검증하며, 그 전에는 Step 3이 AWS에 배포됐다고 표현하지 않는다.
