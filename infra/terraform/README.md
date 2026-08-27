# Step 3 — AWS 기반 리소스 Terraform

Step 2의 로컬 API를 실제 AWS에 연결하기 전에 필요한 기반만 정의합니다. API Gateway·Lambda 코드 배포·WAF는 Step 4, Streams→Pipes→Firehose→S3와 Athena는 Step 5입니다.

## 현재 배포 상태

2026-08-27에 포트폴리오용 개발 계정의 서울 리전에 실제 적용했습니다. 결과는 `32 added / 0 changed / 0 destroyed`이며, apply 뒤 재계획에서 `No changes`를 확인했습니다. 공개 저장소에는 계정 ID와 리소스 ID를 기록하지 않습니다. 세부 검증은 [VERIFICATION.md](VERIFICATION.md)에 있습니다.

Terraform state는 현재 이 개인 실습 환경의 로컬 파일에만 있으며 Git에서 제외되고 파일 권한은 `600`입니다. 팀 협업·CI/CD·재해 복구가 필요한 단계에서는 잠금이 있는 원격 backend로 이전해야 하지만, Step 3 개인 실습에는 추가하지 않았습니다.

## 생성 범위

- VPC 1개와 서로 다른 AZ의 프라이빗 서브넷·라우팅 테이블 2개
- NAT Gateway와 Internet Gateway가 없는 네트워크
- DynamoDB Gateway Endpoint와 prefix list 443만 허용하는 Lambda 보안 그룹
- 온디맨드 Players·Events 테이블, PITR 14일, 삭제 보호, AWS 소유 키 암호화
- Events의 `recovery-by-time` GSI와 `NEW_IMAGE` Stream
- raw-events·athena-results·recovery S3 버킷, 공개 차단·버전 관리·SSE-S3·TLS 강제
- 향후 Step 4 Lambda가 사용할 최소 권한 실행 역할

배포 역할과 Alice/Bob 호출 역할은 실제 API ARN이 생기는 Step 4에서 만듭니다. Firehose·Athena 역할도 해당 서비스가 생기는 Step 5로 넘깁니다. 이 단계에는 NAT, EKS, Redis, 고객 관리 KMS 키, VPC Flow Logs, 별도 CloudTrail Trail을 추가하지 않습니다.

## 로컬 검증

```bash
cd infra/terraform
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

`terraform test`는 AWS provider를 mock으로 바꾸므로 자격증명이나 유료 리소스가 필요하지 않습니다. 모의 테스트는 설정 계약을 확인하지만 실제 AWS 권한·서비스 상태·생성 성공을 증명하지 않습니다.

## 실제 plan과 apply

실습 전용 AWS 자격증명으로만 실행합니다. 기존 운영·프로덕션 프로필을 대신 사용하지 않습니다.

```bash
cp terraform.tfvars.example terraform.tfvars
terraform plan -out step3.tfplan
terraform apply step3.tfplan
```

Terraform 출력의 account_id와 aws_region이 의도한 실습 계정·서울 리전인지 확인한 뒤에만 apply합니다. `terraform.tfvars`, state, plan 파일은 Git에 올리지 않습니다.

## 비용과 정리

- VPC·서브넷·라우팅 테이블·보안 그룹 자체에는 별도 시간당 요금을 추가하지 않습니다.
- DynamoDB Gateway Endpoint는 추가 요금이 없습니다. NAT Gateway를 만들지 않습니다.
- DynamoDB 온디맨드 요청·저장량과 PITR 테이블 크기, S3 저장량·요청·이전 객체 버전에 따라 비용이 발생합니다.
- PITR 복구 기간을 14일로 줄여도 PITR 단가는 낮아지지 않습니다.
- 이 구성은 Budgets를 만들지 않으며 US$20을 강제 지출 상한으로 보장하지 않습니다.

정리할 때는 먼저 보존할 데이터가 없는지 확인합니다. 그다음 `dynamodb_deletion_protection_enabled=false`와 필요할 때만 `allow_bucket_force_destroy=true`로 plan/apply한 후 `terraform destroy`를 실행합니다. 이 두 보호 값을 자동으로 낮추지 않습니다.

## 근거와 한계

- [AWS Gateway endpoint](https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html): DynamoDB를 NAT/Internet Gateway 없이 연결하며 추가 endpoint 요금이 없음.
- [DynamoDB PITR](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/PointInTimeRecovery.html): 1~35일의 연속 복구 지점과 새 테이블 복원.
- [DynamoDB deletion protection](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/WorkingWithTables.Basics.html#WorkingWithTables.Basics.DeletionProtection): 실수로 인한 DeleteTable 차단.
- [S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html): 네 가지 버킷 공개 차단 설정.
- [Terraform mock provider](https://developer.hashicorp.com/terraform/language/tests/mocking): 자격증명 없이 provider 동작을 모의하는 테스트.

단일 리전이며 리전 전체 손실을 보호하지 않습니다. 실제 RPO/RTO, 업무 `TransactWriteItems`, 다른 사용자 접근 거부, PITR 복원, S3 객체 복구는 후속 실험으로 증명해야 합니다.
