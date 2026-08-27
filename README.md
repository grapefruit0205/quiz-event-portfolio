# Quiz Event Portfolio

게임 이벤트 저장·분석 아키텍처를 작은 퀴즈 백엔드부터 단계적으로 구현하는 AWS 포트폴리오입니다.

## 현재 완료 범위

- **Step 1:** 게임 범위, API·데이터 계약, 향후 AWS 배포 계획
- **Step 2:** Python·SQLite 기반 로컬 백엔드와 자동 테스트
- **Step 3:** 단일 리전 AWS 기반 리소스 Terraform과 모의 plan 가드레일

AWS 리소스와 유료 서비스는 아직 생성하지 않았습니다. Step 3은 자격증명 없는 Terraform 모의 plan까지 검증했으며 실제 AWS plan/apply는 포트폴리오용 개발 계정 인증 뒤에 진행합니다. 현재 백엔드는 `127.0.0.1`에서만 실행되며 SQLite는 로컬 거래와 재시작 보존을 확인하기 위한 어댑터입니다.

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

## 검증 결과

- 자동 테스트 27개 통과
- 정상 채점과 상태·이력 거래 저장
- 잘못된 입력과 저장 실패 롤백
- 같은 요청의 안전한 재시도와 ID 충돌 거부
- 다른 사용자 데이터 접근 거부
- 실제 로컬 HTTP 호출과 서버 재시작 후 데이터 유지
- README만 사용한 독립 실행 검증
- Terraform 포맷·구문 검증과 가드레일 테스트 통과
- 모의 plan `32 add / 0 change / 0 destroy`

실제 DynamoDB·IAM·S3 생성과 권한 동작은 아직 검증하지 않았습니다. API Gateway·Lambda·WAF는 Step 4, Streams·Pipes·Firehose·Athena는 Step 5 범위입니다.
