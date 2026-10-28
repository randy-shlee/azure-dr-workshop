# Azure DR workshop - 간소화 가이드 검토안

상태: 2026-10-28 사용자 승인, [Workshop_simple](Workshop_simple/README.md)에 반영.
기존 `workshop`은 고급/참고용으로 유지합니다. 아래는 승인된 구성의 기록입니다.

## 1. 변경 범위

- 참가자는 Azure 포털과 기존 앱의 버튼으로 결과를 확인합니다.
- 짧은 조회 명령과 기존 전환/원복 스크립트 한 줄은 허용합니다.
- 빌드, 릴리스 게시, 환경 복원, Secret 전달, 복구 작업은 강사용으로 분리합니다.
- 새 DR 실행 웹 버튼, 새 Automation runbook, 새 유료 서비스는 추가하지 않습니다.
- owner와 budget 제거는 공개 포털 템플릿에만 적용합니다.
  기존 CLI의 owner 태그, 예산, 선택 이메일 알림은 유지합니다.
- 포털은 owner 입력/태그, monthlyBudget/budgetStartDate 입력, 구독 예산 생성을
  제외합니다. 이메일 수신자가 없으므로 선택 이메일 알림도 포털에서는 제공하지 않습니다.
- expiry, CIDR, PostgreSQL 자격 증명, 기존 private 네트워크 정책과 AKS 최소 사양은 유지합니다.
- owner/예산이 없어도 비용 승인, 정리 담당자, 실제 삭제 확인은 필요합니다.

## 2. 참가자용 권장 흐름

| 단계 | 참가자가 할 일 | 완료 확인 | 기존 Lab 처리 |
|---|---|---|---|
| 00 시작하기 | 테스트 구독 로그인, 팀 prefix·공인 IP·종료일 확인, 비용/권한 안내 확인 | 대상 구독과 허용 IP가 맞음 | 00을 1페이지 체크리스트로 축소 |
| 01 배포하기 | Deploy to Azure 클릭, 필수 값 입력, 검토 후 승인된 환경에 Create | 포털 배포 Succeeded. 아직 앱 완료와는 구별 | 01의 긴 CLI 복원 블록을 강사용으로 이동 |
| 02 준비 상태 확인 | 배포 Outputs 확인, Automation Jobs 결과 확인, 앱 주소 열기 | Automation Completed, 양 리전 앱 준비. 샘플 완료는 별도 | 02/04의 자동화 상태 확인만 통합 |
| 03 앱 버튼으로 테스트 | 쓰기 테스트 → 읽기 테스트 → 샘플 데이터 확인 | 서비스별 결과, UUID/UTC, KRS secondary 실제 읽기 확인 | 05 중심. 코드·manifest·수동 Search 초기화는 제외 |
| 04 전환과 원복 | 강사/지정 오퍼레이터의 짧은 명령 실행을 관찰하고 앱 새로고침·쓰기/읽기 | KRS 전환과 KRC 복귀, backend 역할·두 endpoint 상태 확인 | 06을 전환/확인/원복 3부분으로 축소 |
| 05 정리하기 | 결과 스크린샷 저장, 승인된 담당자가 정확한 RG 삭제, 남은 리소스 확인 | 3개 RG·AKS 관리 RG·bootstrap custom role 정리 | 07의 pause/resume는 고급 참고로 이동 |

각 Lab은 **목표 → 클릭/짧은 명령 → 정상 화면/값 → 안 되면 멈출 위치 → 완료 체크**
순서로 통일합니다. 정상 화면에는 주석 달린 스크린샷을 사용하되 실제 환경을
확인하기 전에는 성공 화면을 임의로 만들지 않습니다.

## 3. 배포 화면 안내

참가자가 반드시 확인하거나 입력할 항목:

1. Subscription 및 Deployment location: 승인된 구독 / Korea Central.
2. prefix: 팀별 고유한 3~12자 소문자/숫자.
3. expiry: 종료 예정일. 자동 삭제 기능이 아님.
4. allowedClientCidrs: 실제 브라우저 인터넷 출구 공인 IPv4 CIDR 배열.
5. administratorLogin / administratorPassword: 테스트 PostgreSQL 계정.

나머지 인프라/샘플/릴리스 값은 기본값 유지로 안내합니다. 현재 ARM 포털 폼에는
다른 파라미터가 계속 표시되므로 이 다섯 묶음만 보이는 사용자 정의 폼이라고
설명하지 않습니다. owner/monthlyBudget/budgetStartDate는 표시하지 않고 예산도 만들지 않습니다.

full/lite 차이는 시작 문서의 작은 표로만 안내합니다. 기본 full은 기존 승인 범위를
유지하며, 강사가 lite를 선택했다면 EH/Redis/Search 및 해당 DR 검증은 제외로 표시합니다.

## 4. 짧은 명령을 넣는 기준

### 조회는 선택적으로

포털의 AKS Run command를 사용할 수 있는 권한/지역 지원을 강사가 사전 확인합니다.
private AKS의 일반 Kubernetes 리소스 화면에 직접 접속할 수 있다고 가정하지 않습니다.
앱 준비·샘플 단계가 불명확할 때만 KRC AKS Run command에서 다음을 조회합니다.

```bash
kubectl -n drtest get configmap workshop-bootstrap-status -o yaml
```

이 명령은 상태 ConfigMap만 읽습니다. Secret 조회, 환경 변수 전체 출력은 하지 않습니다.
ApplicationReady와 Complete는 다르며 Automation Completed만으로 샘플 완료를 주장하지 않습니다.
샘플 복제는 오래 걸릴 수 있으므로 강사는 가능하면 전날 배포·복제를 완료합니다.

### 실제 backend 전환은 기존 스크립트 재사용

다음 명령은 **강사가 저장소·Bash/Azure CLI/Python/jq·구독 로그인·실제 배포 outputs를
준비한 터미널**에서만 실행합니다. 참가자 PC의 새 터미널에서 즉시 실행 가능한
무설정 명령으로 안내하지 않습니다. 준비 절차는 강사용 문서에서 한 번만 설명합니다.

전환 전:

```bash
bash scripts/drill/00-precheck.sh
```

KRS planned 전환:

```bash
bash scripts/drill/10-failover.sh
```

KRC 원복 후 평시 상태 확인:

```bash
bash scripts/drill/20-failback.sh
bash scripts/drill/00-precheck.sh
```

실제 변경 전 스크립트의 prefix 확인 문구를 입력합니다.
빠른 프로브/TTL 0 설정은 필수가 아니므로 기본 과정에서는 사용하지 않습니다.
이미 빠른 프로브를 사용한 환경은 기존 복구 절차로 기본값을 복원합니다.
오류나 부분 성공 시 반대 명령을 자동 재실행하지 않고 실제 PG/EH/TM 상태를 강사가 확인합니다.

참가자는 전환 전/후 앱의 응답 리전, TM 안내 리전, 실제 쓰기/읽기 결과를 기록합니다.
DNS/브라우저 캐시 때문에 전환이 즉시 보이지 않을 수 있고 고정 RTO/RPO를 보장하지 않습니다.

## 5. 포털 클릭만으로 가능한 범위와 한계

| 항목 | 권장 방법 | 주의점 |
|---|---|---|
| 리소스 배포/outputs/Automation 상태 | Azure 포털 | 배포 성공, 앱 준비, 샘플 복제 완료는 별개 |
| 앱 서비스 연결·쓰기·읽기·샘플 | 기존 대시보드 버튼 | enabled 서비스의 partial/error와 disabled를 구분 |
| Private Blob 데이터 확인 | 앱이 AKS에서 읽은 실제 결과 | 참가자 PC의 Storage Browser 접근을 위해 public access를 열지 않음 |
| Traffic Manager 상태 | 포털 Endpoints | endpoint Disable은 앱/VM/DB 중단이 아님 |
| 트래픽 경로만 전환하는 선택 체험 | 포털에서 KRC endpoint Disable/Enable | DNS 진입점만 바꾸며 PG/EH DR 완료로 기록하지 않음 |
| PG/EH까지 포함한 planned 전환/원복 | 지정 오퍼레이터의 기존 짧은 스크립트 | 순서·권한·복제 상태 확인이 필요. 참가자는 화면 관측 중심 |
| 정리 | 승인된 담당자의 포털 삭제 또는 기존 정리 스크립트 | RG뿐 아니라 AKS 관리 RG와 구독 custom role도 확인 |

Storage 계정 failover, 강제 데이터 손실 승격, 운영 장애 주입은 제외합니다.
Storage는 RA-GRS secondary 읽기, Redis는 active geo, Search는 독립 지역 인덱스라는
서비스별 차이를 짧은 표 하나로 유지합니다.

## 6. 강사용으로 옮길 내용

- Docker/릴리스/해시/버튼 준비와 실제 고객 프로필 Provider what-if.
- 구독 권한·할당량·지역 기능·비용·Automation 네트워크 예외 승인.
- 새 터미널의 로그인/환경 설정/outputs 복원.
- Kustomize, Workload Identity, Secret 전달, Search 초기화, 수동 앱 복구.
- 복제 지연, 오류/부분 성공, CLI 상세 진단과 전환 실패 복구.
- 정리 대상과 custom role 확인. 포털 프로필은 owner 확인과 예산 삭제를 요구하지 않음.
- pause는 전체 과금 종료가 아니므로 참가자 기본 종료 경로는 삭제로 안내.

## 7. 승인 후 만들 파일

```text
Workshop_simple\
  README.md
  00-start.md
  01-deploy.md
  02-ready.md
  03-test.md
  04-dr.md
  05-cleanup.md
  instructor.md
```

기존 앱·Bicep·운영 스크립트는 복제하지 않고 상대 링크로 재사용합니다.
새 Lab을 작성한 뒤 링크, 명령, owner/예산 없는 정리 흐름을 검증합니다.
실제 Azure 배포·전환·삭제는 별도 승인된 리허설 없이는 수행하지 않습니다.

## 검토 요청

권장안은 **참가자 포털/앱 중심 + 지정 오퍼레이터의 기존 DR 스크립트**입니다.
명령을 전혀 실행하지 않는 관찰형 진행도 가능하지만, Traffic Manager 클릭만으로
전체 backend DR를 수행했다고 설명하지 않습니다.

2026-10-28 이 구성이 승인되어 `Workshop_simple` 폴더와 새 가이드를 작성했습니다.

참고:
[Traffic Manager endpoint 활성화/비활성화](https://learn.microsoft.com/azure/traffic-manager/traffic-manager-endpoint-types#enabling-and-disabling-endpoints).
