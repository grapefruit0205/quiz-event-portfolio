# Step 4 — IAM 인증 퀴즈 API

Step 2의 같은 요청 처리 코드를 Lambda에 올리고 DynamoDB 어댑터로 바꿉니다. 실제 요청 흐름은 다음과 같습니다.

```text
Alice/Bob 테스트 역할 → Regional API Gateway → WAF → Lambda(2개 private subnet)
                                                    └→ DynamoDB Gateway endpoint
                                                       ├→ Players 현재 상태
                                                       └→ Events 변경 이력
```

API Gateway는 `/quiz`, `/players/{player_id}`, `/players/{player_id}/results` 세 method만 만들며 모두 `AWS_IAM` 인증을 요구합니다. API Gateway가 인증한 ARN을 Lambda가 Alice/Bob에 매핑하고, 경로의 player_id와 다르면 저장소를 읽기 전에 403으로 거부합니다. 공개 웹 로그인 시스템을 흉내 내기 위한 Cognito는 이번 단계에 추가하지 않습니다.

## 구현한 가드레일

| 구간 | 설정 | 발생 시 해석 |
| --- | --- | --- |
| WAF | IP별 60초 100요청 초과 차단 | 한 출발지의 반복 요청이 먼저 차단됨 |
| API Gateway | stage 전체 5 req/s, burst 10 | 429가 생기면 API 제한부터 확인 |
| Lambda | 256 MB, timeout 10초, 계정 동시 실행 한도 사용 | Lambda Throttles가 생기면 계정 동시 실행 한도 확인 |
| DynamoDB | PAY_PER_REQUEST, 테이블·GSI 최대 100 RRU/WRU | ThrottledRequests가 생기면 DB 최대 처리량 확인 |
| 로그 | Lambda JSON 로그 7일, API data trace·WAF sample 끔 | 요청 본문·Authorization을 기록하지 않음 |

API Gateway와 WAF의 rate limit은 정확한 비용 상한이나 무손실 처리 보장이 아닙니다. 특히 API Gateway throttling은 목표값이며 초과 요청이 모두 같은 경계에서 차단된다고 가정하지 않습니다. 알람은 Step 6 범위입니다.

이 계정에서 확인한 Lambda 계정 동시 실행 한도는 10입니다. 별도 reserved concurrency를 설정하면 계정의 unreserved pool 최소 조건과 충돌할 수 있어 이번 단계에서는 사용하지 않습니다. 대신 API 요청률을 작게 제한하고 실제 Throttles를 후속 알람에서 관찰합니다.

## 상태와 이력의 원자적 저장

Lambda는 한 제출을 DynamoDB `TransactWriteItems` 한 번으로 처리합니다.

1. Players의 `version`이 클라이언트가 읽은 값과 같은지 조건 검사합니다.
2. 새 점수와 `latest_event_id`를 Players에 저장합니다.
3. 같은 `(player_id, event_id)`가 없을 때만 Events에 원본 이벤트와 원래 응답을 추가합니다.

두 쓰기 중 하나만 성공하지 않습니다. 같은 event_id와 같은 본문을 재시도하면 저장된 원래 응답을 반환하고, 본문이 다르면 409로 거부합니다. 거래 결과를 클라이언트가 확실히 받지 못한 경우에도 Events를 consistent read로 다시 확인합니다. 조회 시에는 저장된 event 본문 hash와 중복 필드·원래 응답이 일치하는지도 검사합니다.

## 최소 권한

- API method: `AWS_IAM`; 익명 요청 거부.
- Alice/Bob 호출 역할: 해당 lab stage의 `execute-api:Invoke`만 허용.
- Lambda 실행 역할: 프로젝트 로그 쓰기, VPC ENI 관리, 두 DynamoDB 테이블 접근만 허용.
- VPC endpoint policy: 같은 두 DynamoDB 테이블만 허용.
- Lambda 보안 그룹: ingress 없음, 서울 리전 DynamoDB prefix list의 TCP 443 egress만 허용.

Alice/Bob 역할의 신뢰 주체는 기본적으로 Terraform을 실행한 IAM 사용자입니다. STS assumed role로 Terraform을 실행한다면 `operator_principal_arn`에 세션 ARN이 아니라 원본 IAM role ARN을 넣습니다.

## apply 전 검증

```bash
cd infra/terraform
terraform fmt -check -recursive
terraform validate
terraform test
AWS_PROFILE=quiz-event-portfolio terraform plan -out=step4.tfplan
```

검토한 plan `23 add / 3 change / 0 destroy`를 그대로 적용했고 결과도 `23 added / 3 changed / 0 destroyed`였습니다. apply 후 무변경 plan을 확인했습니다. plan 파일과 state는 Git에서 제외합니다.

## apply 후 실제 시나리오

저장 plan 적용 뒤 다음 스크립트로 라이브 시나리오를 실행했습니다.

```bash
AWS_PROFILE=quiz-event-portfolio ./scripts/verify_step4.sh
```

이 스크립트는 자격 증명을 출력하거나 저장소에 남기지 않고 다음 항목을 모두 통과했습니다.

1. 익명 요청 403.
2. Alice의 퀴즈·자기 상태 조회 200.
3. Alice가 Bob 상태를 읽으면 403.
4. 새 제출 201, 같은 본문 재시도 200과 원래 응답 일치.
5. 같은 event_id를 다른 본문으로 쓰면 409.
6. Bob의 자기 상태 조회 200.

스크립트 성공만으로 WAF rate rule, API 429, Lambda/DynamoDB throttling이 실제 발생했다고 주장하지 않습니다. 그 실험과 알람 수신은 Step 6에서 분리합니다. AWS 설정 조회로 method 3개의 IAM 인증, stage 제한, Lambda VPC·런타임, WAF 연결, DynamoDB 최대 처리량과 로그 7일도 확인했습니다.

## 비용과 제한

WAF는 트래픽이 없어도 web ACL 월 US$5와 사용자 정의 rule 월 US$1이 발생하며 시간 단위로 비례 청구됩니다. 여기에 WAF 요청, API Gateway REST 호출, Lambda 실행·로그, DynamoDB 요청·저장·PITR 비용이 추가됩니다. AWS 무료 사용량이나 크레딧 적용 여부는 계정마다 다릅니다.

Shield Advanced, NAT Gateway, API 캐시, X-Ray, API 상세 metrics/data trace, WAF managed rule group은 비용과 학습 범위를 줄이기 위해 제외했습니다. 단일 리전이며 리전 전체 장애를 복구하지 않습니다. IAM 사용자 MFA 등록과 PowerUserAccess 축소도 후속 보안 부채입니다.

참고: [API Gateway IAM 인증](https://docs.aws.amazon.com/apigateway/latest/developerguide/permissions.html), [API Gateway throttling](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-request-throttling.html), [WAF 연결](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-control-access-aws-waf.html), [AWS WAF 요금](https://aws.amazon.com/waf/pricing/), [DynamoDB transactions](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/transactions.html)
