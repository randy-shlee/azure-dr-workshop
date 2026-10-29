# 워크숍 개요와 실제 배포 아키텍처

[간단 과정](../Workshop_simple/README.md) · [고급 과정](README.md) · [검증 보고서](releases/v1.0.7-validation.md)

## 무엇을 실습하나요?

Korea Central(KRC)을 평시 서비스 리전, Korea South(KRS)를 준비된 대기 리전으로 구성합니다.
강사는 검증된 **로컬 패키지 한 명령**으로 인프라부터 앱·샘플까지 배포하고,
참가자는 브라우저에서 실제 데이터 작업을 확인합니다. 이후 별도로 승인한 오퍼레이터가
Storage/PG/EH의 서로 다른 DR 방식을 전환 스크립트로 실습합니다.

**현재의 one-click은 공개 포털 버튼이 아니라 한 번의 로컬 배포 명령입니다.**
공개 GitHub assets 없이 동작합니다. 최신 포털 경로는 공개 게시·별도 실증 전이므로
이 과정에서 Deploy to Azure 버튼이나 Automation Job을 완료 기준으로 사용하지 않습니다.

## 실제 성공한 full 구성

![공식 Azure 아이콘을 사용한 KRC/KRS 실제 배포 기준 아키텍처](assets/architecture.svg)

[큰 원본 SVG 열기](assets/architecture.svg) · [아이콘 출처와 이용 조건](assets/azure-icons/NOTICE.md)

그림은 **2026-10-28 `drws1028c`의 배포 성공 baseline**입니다. 리전별 RG의 ARM
리소스 목록도 재조회했습니다. 선은 논리 관계이며 모든 PE/NIC/NSG rule을 하나씩
그린 물리 배선도가 아닙니다. 제품 아이콘의 색상·형태·비율은 변경하지 않았습니다.

| 범위 | 실제 배포된 핵심 리소스 | 읽는 방법 |
|---|---|---|
| global RG | Traffic Manager 1개 | Priority, KRC 1 / KRS 2. DNS 안내이며 HTTP 프록시가 아님 |
| KRC RG | VNet, private AKS, 공인 앱 IP, PG, EH Standard, Redis, Search, ACR, Storage, Log Analytics/AMPLS, MI, Private DNS, PE 8개 | AKS 노드 2대. 관리형 PaaS 자체가 VNet 안에 들어가는 것은 아니며 PE로 접근 |
| KRS RG | VNet, private AKS, 공인 앱 IP, PG replica, EH Standard, Redis, Search, MI, Private DNS, PE 9개 | AKS 노드 2대. KRC의 동일 ACR/Storage에도 사설 접근 |
| AKS 관리 RG 2개 | 노드 VMSS, 디스크, Load Balancer 등 | 워크숍의 세 RG와 별도로 AKS가 관리. 정리 시 잔여 여부 확인 |
| Storage | **Standard_RAGRS 계정 하나** | KRC primary + paired KRS read-only secondary. KRS에 별도 LRS 계정을 만든 구조가 아님 |
| Private Link | PE 총 17개, 그중 EH 4개 | 양 VNet에서 양 EH namespace 접근. Private DNS는 VNet별로 분리 |
| 관측 | KRC workspace/AMPLS와 양 VNet monitor PE | global RG에 workspace가 있는 것으로 그리지 않음 |

다이어그램의 KRS Storage는 **동일 계정의 지역 복제본**이지 두 번째 ARM 계정이 아닙니다.
AKS public IP/Load Balancer는 앱 HTTP 진입점이고 private AKS API/업무 PaaS와 구별합니다.
ACR은 KRC 한 곳이며 양 AKS가 같은 이미지를 pull합니다.

### 현재 배포하지 않은 기능

99:1 가중 라우팅, Application Gateway, DNS Private Resolver, ACR geo-replication,
선택 alerts, cloud Automation 배포는 현재 full 실증 경로에 없습니다.
private AKS의 서비스 관리용 DNS와 배포된 private DNS zone은 DNS Resolver 리소스와 다릅니다.

## 각 데이터 서비스의 DR 의미

| 서비스 | 평시 | KRS 전환 | 앱 KRC 원복 후 |
|---|---|---|---|
| Blob Storage | KRC primary / KRS read-only 복제본 | 계정 **Planned failover**, KRS가 write primary | Planned failback, KRC primary |
| PostgreSQL | KRC Primary / KRS GeoAsyncReplica | writer/reader aliases와 **planned switchover** | KRC로 planned switchover, 복제 자동 역전 |
| Event Hubs Standard | KRC Primary / KRS Secondary, 공통 alias | **metadata-only fail-forward**, 이벤트 데이터는 복제되지 않음 | **alias는 KRS 유지**, 이전 primary로 failback하지 않음 |
| Azure Managed Redis | 양 지역 active geo | 별도 PG식 primary 승격 없음 | 지역별 연결/실제 데이터 확인 |
| AI Search | 양 지역 독립 인덱스 | KRS 인덱스 사용 | KRC 인덱스 사용. 자동 지역 복제/전체 문서 동일성 보장 없음 |
| Traffic Manager | 양쪽 Enabled/Online, KRC 우선 | backend 준비 후 KRC endpoint Disable | backend 준비 후 KRC Enable, KRS도 Enabled 유지 |

양 앱의 일반 Blob 읽기/쓰기는 안정적인 **primary hostname**, PG는 **writer alias**,
EH는 **Geo-DR alias**를 사용합니다. KRS 앱이 평시부터 PG reader/Storage secondary로
자동 분기하는 99:1 read/write 분리 앱은 아닙니다.
`-secondary` Blob 읽기는 **첫 전환 전 복제 probe**이며 전환 후 앱 데이터 경로가 아닙니다.

EH의 이벤트·checkpoint·offset·RBAC는 metadata alias와 함께 복제되지 않습니다.
양 namespace의 RBAC는 별도 배포했습니다. 실제 전환 전에 consumer 시작 위치,
중복/누락, KRC 원래 이벤트의 보존·replay를 따로 계획해야 합니다.
첫 전환 후 새 EMPTY namespace로 re-protect하는 작업은 이 과정에서 자동 수행하지 않습니다.

## 배포부터 실습까지

1. **승인**: 구독, 신규 prefix, 허용 CIDR, 비용, 보관/삭제 담당자.
2. **원클릭 배포**: 해시 검증 → 인프라 → 사설 ACR 이미지 → 양 앱/Secret/Service →
   CLI 10 GB 샘플/복제/보조 읽기 → TM/실제 서비스 smoke → `phase=Complete`.
3. **평시 검증**: 양 앱 Ready, 같은 이미지, TM Online, UUID 쓰기/읽기,
   2,008개/정확히 10 GB, 실제 primary/secondary 읽기와 Last Sync Time fence.
4. **별도 승인 DR**: 실제 스크립트 순서인 **Storage → EH → PG → TM**로 KRS 전환.
5. **원복**: **Storage → PG → EH active 확인 → TM**. EH는 KRS에 남습니다.
6. **종료**: 관측 증거 보관, 프로브 설정 복구, 승인된 보관 또는 실제 삭제·잔여 비용 확인.

**배포/앱/10 GB/복제는 실증 완료했지만 실제 failover·failback은 아직 실행하지 않았습니다.**
전환 스크립트가 있다고 클라우드 전환 성공/RTO/RPO를 인증한 것은 아닙니다.
자세한 실행 게이트는 [고급 Lab 06](labs/06-drill.md)을 따릅니다.

## 운영 경계와 비용

- 테스트 전용 HTTP 앱이며 승인한 공인 CIDR만 접근합니다. 운영 데이터/암호를 사용하지 않습니다.
- 업무 PaaS/ACR은 private. 앱/샘플은 Workload Identity, 이미지 pull은 kubelet AcrPull을 사용합니다.
  테스트 PG/Redis는 Kubernetes Secret을 사용하며 운영용 비밀 관리 패턴을 주장하지 않습니다.
- 배포 중만 승인 CIDR+mTLS의 임시 Docker 2376을 사용하고 엔진/규칙/새 push grant/인증서를 제거합니다.
  무인증 Docker 서비스나 상시 공용 ACR은 아닙니다.
- full의 알려진 비용 소계는 **약 USD 1,615.41/월/환경**(2026-10-28 사전 조회)이며
  가변 사용량/임시 빌드 등은 별도입니다. 예산 상한이나 가격 보장이 아닙니다.
- 새 환경 한 번의 전체 실증은 약 49분이었지만 배포·복제·planned 전환은 더 오래 걸릴 수 있습니다.
  Storage 각 전환은 수 시간도 허용합니다. 전날 준비를 권장합니다.
- `expiry`는 태그일 뿐 자동 삭제가 아닙니다. 검증용 `drws1028c`는 승인대로 보관 중입니다.

## 다이어그램 재생성

공식 아이콘 원본과 SVG 레이아웃을 저장소에 포함했습니다. 외부 이미지/font를 요청하지 않는
self-contained SVG를 생성합니다. 이 명령은 Azure 리소스를 변경하지 않습니다.

```powershell
.\scripts\render-workshop-architecture.ps1
```

아이콘은 Microsoft Azure Architecture Center V24의 허용된 다이어그램/교육 용도로만 사용합니다.
