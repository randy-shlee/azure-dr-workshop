# 강사 운영 가이드

[참가자 목차](README.md) · [문제 해결](troubleshooting.md)

## 권장 운영

2~4명/팀, 환경 하나당 명령 실행자 한 명을 권장합니다.
참가자 수만큼 전체 환경을 만들지 말고 비용·quota·시간을 승인받으세요.
당일 교육은 약 반나절~하루, 인프라/대량 복제는 전날 리허설이 현실적입니다.
실습 단계를 이미 준비한 경우에도 누가 무엇을 실행했는지 관측 표에 표시합니다.

## D-7: 고객과 합의

- [ ] 테스트 구독/정책/예산/메일 수신자/수업 종료 삭제 책임
- [ ] 팀 prefix, CIDR, 네트워크 주소 대역 충돌 여부
- [ ] full 또는 lite와 제외 검증 목록
- [ ] AKS 4노드 합계, PG 2개, EH 2위치 PU, Redis/Search 양 리전 비용 안내
- [ ] 지정 오퍼레이터와 역할/비밀 전달 방법 승인
- [ ] 실제 장애 주입/성능/운영 RTO/RPO 검증이 아님에 동의
- [ ] 화면/CSV/환경 정보 보관 및 파기 정책
- [ ] 샘플 이미지/ARM/runbook 공개 게시 승인, 익명 GitHub Release 접근 정책
- [ ] Automation 계정 하나의 public networking 예외 및 encrypted 테스트 자격 증명 보관 승인

## D-3: 기술 준비

1. 강사 계정으로 해당 구독/지역의 provider·할당량·SKU·정책을 확인합니다.
   다른 구독의 what-if 결과로 배포 가능성을 보장하지 않습니다.
2. [강사 패키징](labs/03-build.md)으로 로컬 Linux/amd64 build/save, 이미지/소스 검사,
   새 태그·해시·ARM JSON·runbook을 준비하고 승인 후 네 assets를 공개합니다.
3. 실제 Release URL로 Lab 01 버튼을 활성화하고 익명 다운로드를 확인합니다.
   ARM JSON에는 입력한 암호가 없고, generated runbook의 ZIP은 허용 목록 원본뿐이어야 합니다.
4. AKS의 GitHub/MCR/도구/Entra/ARM outbound와 ACR private registry/data DNS·443을 점검합니다.
   업무 PaaS public/bypass를 열거나 VM/VPN/NAT/Tasks pool을 추가하지 않습니다.
5. bootstrap MI의 한정 custom-role 범위와 ACR AcrPush, kubelet AcrPull,
   app/sample WI, Storage Reader를 구별합니다.
6. Automation 계정의 local auth false, webhook 없음, encrypted 설정 asset 접근 권한,
   Portal 실제 배포 이름, CLI/Bicep/Bash/jq/kubectl, 브라우저 출구를 확인합니다.

## D-1: 같은 커밋/폴더 버전으로 리허설

강사 Lab 03 패키징/게시를 먼저 하고, 참가자 Lab 00~02/04~05를 리허설합니다.

- 환경 템플릿에서 placeholder 제거, owner 메일 검증, 실제 가격 재조회
- full 약 10GiB로 build/what-if/배포·샘플/KRS 실제 읽기 확인
- Automation/AKS 이미지 전송, Search 초기화 및 양 AKS rollout
- ARM 성공/앱 준비/샘플 복제 완료를 각각 관측하고 자동화 실패 경로도 확인
- 양 리전 FQDN/Service IP/TM Online, full 서비스별 실제 쓰기/읽기
- 한 차례 planned 전환·원복 후 baseline 복원
- 복제 대기/배포 시간이 수업 시간을 넘으면 시간표를 조정

실습 인프라 미지원 기능을 새 상위 SKU/다른 리전으로 임의 대체하지 않습니다.
lite로 변경 시 배포 전에 학습 범위를 다시 승인합니다.
이전 장애 훈련 후 같은 Bicep으로 무심코 초기 상태를 덮어쓰지 않습니다.

## 수업 중 개입 게이트

| 게이트 | 강사가 확인할 증거 | 실패 시 |
|---|---|---|
| 유료 배포 | 대상 구독/비용 승인/what-if | 생성 중단 |
| 샘플 | manifest와 KRS 검증 Job | DR 진행 보류 |
| 이미지 | private push/digest/Linux amd64 | 공개 우회 금지 |
| 앱 | 두 Ready/태그/IP/Online | 배포·권한 진단 |
| 전환 | PG/EH 역할과 단일 오퍼레이터 | 부분 성공을 재확인 |
| 종료 | 프로브/원복/삭제/담당자 | 종료 미완료로 기록 |

가장 중요한 설명은 다음 네 가지입니다.

1. TM은 DNS 응답만 바꾸며 트래픽은 실제 공인 IP로 직접 향한다.
2. Online health와 의존 서비스 연결/복제/데이터 정합성은 다른 관측이다.
3. `pe_region`은 PE IP이고 primary 역할/실제 데이터 리전의 증거가 아니다.
4. UI 변화 시각 차이는 DNS 캐시만의 정밀 지연이나 보장 RTO가 아니다.

## 평가와 종료

관측 CSV에는 최소 평시/전환/KRS 쓰기/원복/삭제를 기록합니다.
실패를 정상으로 바꾸기 위해 catch/skip/키 인증/public 접근을 추가하지 않습니다.
증거에는 암호·키·토큰·Kubernetes Secret 본문을 넣지 않습니다.
팀의 자격 증명/상태 폴더를 다른 팀에 넘기지 마세요.

종료 시 강사는 모든 팀의 3개 RG(Automation/MI/암호 asset 포함), AKS managed RG,
구독 budget/부트스트랩 custom role과 보관 승인 목록을
대조합니다. pause한 환경은 정리 완료가 아니라 잔여 과금 승인 대상입니다.
expiry 태그는 자동 삭제가 아닙니다. 비용 포털 반영 지연을 고려해 다음 날 재확인합니다.
강사 로컬 이미지/릴리스 산출물과 GitHub 공개 assets의 보관/파기는 별도 소유자에게 인계합니다.

## 작성 시 검증과 고객 리허설의 구별

기존 앱/스크립트의 mock 테스트와 Bicep/what-if는 제공되지만 고객 구독에서의
생성·지원 SKU·private 데이터 경로·DR 성공 증거는 아닙니다.
workshop Markdown의 shell 구문/파일 링크/명령 계약을 검사하고, 정리 스크립트는
실제 RG 이름 규칙을 사용하는 모의 테스트로 검증합니다. 유료 작업은 자동 실행하지 않습니다.
