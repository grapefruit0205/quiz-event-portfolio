# Quiz Event Portfolio

게임 이벤트 저장·분석 아키텍처를 작은 퀴즈 백엔드부터 단계적으로 구현하는 AWS 포트폴리오입니다.

## 현재 완료 범위

- **Step 1:** 게임 범위, API·데이터 계약, 향후 AWS 배포 계획
- **Step 2:** Python·SQLite 기반 로컬 백엔드와 자동 테스트
- **Step 3:** 단일 리전 AWS 기반 리소스 Terraform, 실제 배포와 상태 검증
- **Step 4:** DynamoDB 거래 어댑터, IAM 인증 API Gateway·Lambda·WAF 구현과 실제 plan 검증

Step 3 기반과 Step 4 API는 포트폴리오용 개발 계정의 서울 리전에 배포되어 있습니다. 실제 IAM 서명 요청으로 익명 거부, Alice/Bob 소유권 분리, DynamoDB 거래 저장과 재시도를 확인했습니다. 로컬 SQLite 모드도 독립 실행할 수 있습니다.

## 빠른 실행

Python 3.12 이상에서 별도 패키지 설치 없이 실행할 수 있습니다.

```bash
cd backend
python3 -m unittest discover -s tests -v
python3 -m quiz_backend.local_server
```

다른 터미널에서 실제 HTTP 시나리오를 실행합니다.

```bash
cd backend
python3 -m quiz_backend.demo
```

## 문서

- [Step 1 명세·배포 계획](backend/docs/STEP1.md)
- [API 계약](backend/docs/API.md)
- [백엔드 실행 안내](backend/README.md)
- [Step 1·2 검증 범위와 결과](backend/docs/VERIFICATION.md)
- [Step 3 Terraform 범위·실행 안내](infra/terraform/README.md)
- [Step 3 검증 기록](infra/terraform/VERIFICATION.md)
- [Step 4 API·보안·비용 가드레일](infra/terraform/STEP4.md)

## 검증 결과

- 자동 테스트 38개 통과
- 정상 채점과 상태·이력 거래 저장
- 잘못된 입력과 저장 실패 롤백
- 같은 요청의 안전한 재시도와 ID 충돌 거부
- 다른 사용자 데이터 접근 거부
- 실제 로컬 HTTP 호출과 서버 재시작 후 데이터 유지
- README만 사용한 독립 실행 검증
- Terraform 포맷·구문 검증과 가드레일 테스트 통과
- Step 3 모의 plan `32 add / 0 change / 0 destroy`
- 실제 apply `32 added / 0 changed / 0 destroyed`
- 실제 상태 조회와 apply 후 무변경 plan 통과
- Step 4 mock 가드레일 통과, 실제 plan `23 add / 3 change / 0 destroy`, 삭제·교체 0
- Step 4 실제 apply `23 added / 3 changed / 0 destroyed`, 라이브 API 시나리오와 무변경 plan 통과

VPC·DynamoDB·S3·IAM 기반과 Step 4 API Gateway·Lambda·WAF는 실제 AWS 상태와 호출로 확인했습니다. Streams·Pipes·Firehose·Athena는 Step 5 범위입니다. IAM 사용자 MFA 등록과 광범위한 부트스트랩 권한 축소는 보안 부채로 남겨 두었습니다.
