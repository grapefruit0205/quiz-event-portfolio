# Quiz Event Portfolio

게임 이벤트 저장·분석 아키텍처를 작은 퀴즈 백엔드부터 단계적으로 구현하는 AWS 포트폴리오입니다.

## 현재 완료 범위

- **Step 1:** 게임 범위, API·데이터 계약, 향후 AWS 배포 계획
- **Step 2:** Python·SQLite 기반 로컬 백엔드와 자동 테스트
- **Step 3:** 단일 리전 AWS 기반 리소스 Terraform, 실제 배포와 상태 검증
- **Step 4:** DynamoDB 거래 어댑터, IAM 인증 API Gateway·Lambda·WAF 구현과 실제 plan 검증
- **Step 5:** Streams→Pipes→Firehose→S3 전달과 Athena 내용 대조
- **Step 6:** API·Lambda·DynamoDB·분석 경로 알람, Budget, 실제 SNS 알림 수신
- **Step 7:** 누락 범위 식별, 초당 1건 수동 복구, 알람 일시정지와 checkpoint 재개
- **Step 8:** API·분석·알림·복구 증거의 최종 통합 검증
- **Step 9:** 로컬 AWS SAP 아키텍처 10문제 UI, 서버 채점과 최근 점수 표시

Step 3~7은 포트폴리오용 개발 계정의 서울 리전에 배포되어 있고 Step 8 통합 검증까지 완료했습니다. 실제 IAM 서명 요청, 데이터 원본→S3→Athena 내용 일치, 알림 수신, 통제된 분석 장애의 중단·재개 복구를 확인했습니다. Step 9에서는 AWS 리소스를 추가하지 않고 로컬 SQLite 백엔드에 실제 플레이 가능한 SAP 아키텍처 퀴즈 UI를 연결했습니다.

## 빠른 실행

Python 3.12 이상에서 별도 패키지 설치 없이 실행할 수 있습니다.

```bash
cd backend
python3 -m unittest discover -s tests -v
python3 -m quiz_backend.local_server
```

브라우저에서 `http://127.0.0.1:8765`를 열면 10문제 퀴즈를 풀고 점수를 확인할 수 있습니다.

다른 터미널에서 실제 HTTP 시나리오를 실행합니다.

```bash
cd backend
python3 -m quiz_backend.demo
```

## 문서

- [포트폴리오 아키텍처·장애 시나리오·증거](PORTFOLIO.md)
- [Step 1 명세·배포 계획](backend/docs/STEP1.md)
- [API 계약](backend/docs/API.md)
- [백엔드 실행 안내](backend/README.md)
- [Step 1·2 검증 범위와 결과](backend/docs/VERIFICATION.md)
- [Step 3 Terraform 범위·실행 안내](infra/terraform/README.md)
- [Step 3 검증 기록](infra/terraform/VERIFICATION.md)
- [Step 4 API·보안·비용 가드레일](infra/terraform/STEP4.md)
- [Step 5 이벤트 전달·Athena 분석](infra/terraform/STEP5.md)
- [Step 6 선제 모니터링·비용 알림](infra/terraform/STEP6.md)
- [Step 7 제한 속도 수동 복구](infra/terraform/STEP7.md)
- [Step 8 최종 통합 검증](infra/terraform/STEP8.md)
- [Step 9 로컬 SAP 퀴즈 UI](backend/docs/STEP9.md)

## 검증 결과

- 자동 테스트 40개 통과
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
- Step 5 실제 전달에서 형식 결함을 찾아 수정하고 DynamoDB·S3·Athena 내용 대조 통과
- Step 6 리소스 14개 추가, 8개 알람·Budget·SNS→SQS 라이브 알림 수신 통과
- Step 7 통제 장애에서 원본 누락 0건, checkpoint 재개, Athena 복구 RTO 86초 관찰
- Step 8 전체 통합 검증 139초, 실제 AWS 최종 plan 무변경
- Step 9 실제 브라우저에서 10문제 제출·100점 저장·새로고침 유지·콘솔 오류 0건

VPC부터 제한 속도 복구까지 실제 AWS 상태와 호출로 확인했습니다. 실제 과부하와 리전 장애는 의도적으로 유발하지 않았습니다. IAM 사용자 MFA 등록과 광범위한 부트스트랩 권한 축소는 보안 부채로 남겨 두었습니다. Step 9는 로컬 전용이며 Cognito·공개 웹 호스팅·AWS apply는 포함하지 않습니다.
