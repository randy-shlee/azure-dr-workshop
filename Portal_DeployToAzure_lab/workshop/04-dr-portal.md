# 04. Azure Portal에서 Failover와 Failback

[이전](03-application.md) · [목차](README.md) · [Bash 버전](04-dr.md) · [다음: 정리](05-cleanup.md)

**실행 위치: Azure Portal의 각 서비스 화면과 PC의 앱 브라우저.**
역할 변경에 Cloud Shell이나 Bash 스크립트를 사용하지 않는 절차입니다.
기존 Bash 버전과 같은 환경에서 동시에 실행하지 않습니다.

이 절차는 공식 문서와 기존 전환 순서를 대조한 포털판입니다. **포털에서의 실제 전환·원복은 아직 미실증**입니다.
메뉴 이름은 영어 포털 기준이며 표시 언어와 화면 개편에 따라 달라질 수 있습니다.
필요한 메뉴·Planned 옵션이 없거나 상태를 확인할 수 없으면 중단합니다. 다른 종류의 승격으로 대신하지 않습니다.

## 1. 대상과 승인 확인

1. 포털 상단 **Directories + subscriptions**에서 이번 구독을 선택합니다.
2. **Resource groups**에서 이번 배포의 `rg-<prefix>-global`, `rg-<prefix>-krc`, `rg-<prefix>-krs`만 엽니다.
3. 실제 배포의 **Outputs → config** 또는 [준비 단계](02-ready.md)에서 확인한 이름과 리소스 ID를 대조합니다.
   아래 표의 이름은 패턴이며 Storage처럼 접미사가 붙는 실제 이름을 임의로 만들지 않습니다.
4. 환경 소유자의 전환·원복 승인을 확인하고, 한 명만 조작합니다. 다른 사용자의 쓰기와 샘플 업로드/재개를 중단합니다.
5. 각 단계의 시작/완료 UTC, 실제 리소스, 전후 역할, 앱 UUID를 기록합니다. 암호·키·토큰은 기록하지 않습니다.

| 서비스 | 대상과 포털 메뉴 | 이 실습에서 할 일 |
|---|---|---|
| Storage | 동일 Storage account → **Data management → Redundancy** | **Planned failover**로 KRS 전환, 같은 계정에서 Planned로 KRC 원복 |
| PostgreSQL | 현재 primary 서버 → **Settings → Replication** | 대상 replica의 **Promote → Promote to primary server**, **Data sync: Planned** |
| Event Hubs Standard | KRC namespace → **Geo-recovery** | 기존 alias를 KRS로 **Failover**. 원복 때는 KRS 유지 확인만 수행 |
| Traffic Manager | global RG의 profile → **Settings → Endpoints** | backend 전환 완료 후 endpoint **Enabled/Disabled → Save** |
| Azure Managed Redis | 각 지역 instance → **Active geo-replication** | active-active 연결과 모니터링 상태 확인. primary 승격/원복 조작 없음 |
| Azure AI Search | 각 지역 service → **Search management → Indexes** | 필요한 인덱스·문서와 앱 접근 확인. 두 독립 서비스 간 failover 버튼 없음 |
| AKS | 각 지역 cluster → **Kubernetes resources → Workloads / Services and ingresses** | 앱 Ready와 Service 확인. 지역 간 cluster 승격 버튼 없음 |
| ACR·네트워크·모니터링 | 해당 리소스의 Overview와 상태 화면 | 기존 구성 유지. 이 절차에서 레지스트리·PE·DNS record를 수동 전환하지 않음 |

## 2. 첫 전환 전 완료 조건

아래 조건이 하나라도 미확인이면 Failover를 누르지 않습니다.

| 확인 위치 | 필요한 상태 |
|---|---|
| Automation account → Jobs | 이번 배포 출력의 job ID와 일치하고 **Completed**, 예외 없음 |
| KRC AKS → Workloads | `workshop-bootstrap` Job 성공, 상태 ConfigMap `workshop-bootstrap-status`의 `phase=Complete` |
| 양 지역 앱 | 모두 Ready/접속 가능, 서비스별 정상. TM 앱은 KRC 응답 |
| 앱 → 샘플 데이터 확인 | 양쪽 large 8 + small 2,000, payload **10,000,000,000 bytes**, 보조 읽기 성공, **복제 완료** |
| Storage → Redundancy | **RA-GRS**, Primary **Korea Central**, Secondary **Korea South**, 양 지역 Available, 동기화 완료 및 Planned 가능 |
| Storage Last Sync Time | 최종 manifest 종료 시각 이상. 앱 재개를 실행했다면 새 manifest 기준으로 다시 확인 |
| PostgreSQL → Replication | KRC primary/KRS replica 모두 Ready, replica lag 확인, virtual writer=KRC 및 reader=KRS |
| Event Hubs → Geo-recovery | 기존 alias, KRC primary/KRS secondary, pairing 동기화 완료. 양 namespace의 앱 RBAC·사설 접근 준비 |
| TM → Endpoints | `krc` Priority 1, `krs` Priority 2, 둘 다 Enabled/Online |

AKS의 포털 Kubernetes 화면은 사설 API에 대한 네트워크·RBAC 권한이 있어야 합니다.
열리지 않으면 API server를 공개하지 않습니다. [준비 단계](02-ready.md)의 읽기 전용 AKS Run command로
Job과 ConfigMap을 확인하거나 접근 가능한 관리 환경을 준비한 후 진행합니다.
포털의 리소스 이름만 같거나 ARM 배포만 성공한 것은 이 완료 조건을 대신하지 않습니다.

TM **Configuration**에서 routing method, DNS TTL, monitor protocol/port/path, interval, timeout, tolerated failures를
기록하고, endpoint별 health check 설정도 보관합니다. 이 절차는 fast 설정을 적용하지 않습니다.
**Always serve traffic**으로 probe를 우회하거나 endpoint/프로필을 삭제하지 않습니다.

## 3. KRS로 Failover

**순서: Storage Planned → Event Hubs alias KRS → PostgreSQL KRS switchover → TM KRS → 실제 데이터 확인.**
각 단계가 완료된 것을 확인한 뒤 다음 단계로 이동합니다. 중간 상태에서는 앱 쓰기 테스트를 하지 않습니다.

### 1. Storage: 같은 계정에서 Planned failover

1. 이번 Storage account의 **Data management → Redundancy**를 엽니다.
2. Primary KRC/Secondary KRS, RA-GRS와 복제 상태를 다시 확인합니다.
3. **Prepare for Customer-Managed failover**를 선택합니다.
4. **Planned failover**를 선택합니다. **Unplanned Failover는 선택하지 않습니다.**
5. Last Sync Time과 대상 지역을 확인합니다. 승인된 변경임을 확인한 뒤 `yes`를 입력하고 **Failover**를 누릅니다.
6. 완료 알림과 **Activity log**를 관찰하고 Redundancy 화면을 새로고침합니다.
   수 시간이 걸릴 수 있으므로 버튼을 반복해서 누르거나 반대 방향 전환을 시작하지 않습니다.
7. 완료 조건: Primary **Korea South**, Secondary **Korea Central**, **RA-GRS**, 양 지역 정상,
   동기화/전환 진행 중이 아니고 계정 provisioning 완료. portal에 충분한 상태가 없으면 읽기 전용 관리 조회로 보완합니다.

Storage account와 일반 primary Blob hostname은 그대로 사용합니다. 계정을 새로 만들거나 앱의 일반 읽기를
`-secondary` hostname으로 바꾸지 않습니다. Planned 전환은 geo-redundancy를 유지하므로 LRS로 바꾸거나 복제를 재설정하지 않습니다.

### 2. Event Hubs: metadata alias를 KRS로 전환

1. **KRC Event Hubs namespace**의 **Geo-recovery**에서 기존 alias와 KRS partner를 확인합니다.
2. pairing이 준비됐는지 확인하고 **Failover**를 선택합니다. 대상 KRS와 pairing 해제 경고를 읽고 승인 후 확정합니다.
3. 완료 후 **KRS namespace → Geo-recovery**에서 기존 alias가 KRS에서 활성인지 확인합니다.
   목록 표시만으로 판단하지 말고 완료 알림/Activity log와 실제 앱의 alias send 결과도 대조합니다.

이 구성은 **Standard metadata-only Geo-DR**이며 **Geo-replication** 메뉴의 payload 복제 기능과 다릅니다.
전환하면 기존 pairing은 해제되고 alias는 KRS로 이동합니다. 기존 이벤트는 KRC에 남으며 자동 복제·replay·offset 이식되지 않습니다.
**Break pairing**으로 전환을 대신하지 않고 namespace/alias를 삭제하지 않습니다.
RBAC와 private endpoint가 자동 복제된다고 가정하지 않습니다. 메뉴가 없거나 권한/동기화 오류면 중단합니다.

### 3. PostgreSQL: KRS replica를 Planned switchover

1. 현재 primary인 **KRC PostgreSQL flexible server → Settings → Replication**을 엽니다.
2. KRC/KRS 모두 Ready인지, virtual writer가 KRC이고 reader가 승격할 KRS를 가리키는지 확인합니다.
3. **KRS replica 옆 Promote**를 선택합니다.
4. **Action: Promote to primary server**, **Data sync: Planned**를 선택하고 **Promote**를 확정합니다.
5. 완료 알림 후 새로고침하여 **KRS primary / KRC replica**, 양 서버 Ready,
   KRC replica의 source가 KRS, virtual writer=KRS 및 reader=KRC인지 확인합니다.

**Promote to independent server and remove from replication / Promote to standalone**과 **Forced**는 사용하지 않습니다.
두 서버의 tier/compute/storage 대칭과 필요한 서버 매개변수가 맞지 않거나 virtual endpoint 경고가 있으면 중단합니다.
**High availability → Planned failover**는 동일 서버의 HA standby 전환이므로 이 지역 간 read-replica 실습과 다릅니다.
앱의 writer hostname과 PG 암호는 바꾸지 않습니다.

### 4. Traffic Manager: backend 완료 후 KRS로 라우팅

1. profile → **Settings → Endpoints**에서 `krs`를 선택합니다.
2. **Status: Enabled → Save**, Online 확인 후 `krc`를 **Disabled → Save**로 변경합니다.
3. profile 설정은 Priority routing을 유지하고 endpoint priority는 KRC 1/KRS 2 그대로 둡니다.
4. DNS TTL과 클라이언트 캐시·기존 연결의 영향을 기다린 뒤 **TM URL**에서 응답 리전 **KRS**를 확인합니다.
   새 창에서도 대조하되 새 창이 OS DNS 캐시를 반드시 비운다고 가정하지 않습니다.

endpoint Disabled는 backend 앱을 중지하는 기능이 아닙니다. KRC 직접 IP가 계속 응답할 수 있습니다.
직접 IP의 지역과 TM 안내 지역이 다른 것만으로 DNS 전환 실패라고 판정하지 않습니다.

### 5. KRS에서 실제 데이터 확인

1. TM 앱에서 Storage 읽기 모드가 **primary**, 응답 리전이 **KRS**인지 확인합니다.
2. **쓰기 테스트 → 읽기 테스트**를 한 번씩 실행하고 Blob/PG의 동일 UUID와 UTC를 기록합니다.
3. Redis·Search의 실제 결과, EH alias send 및 sequence metadata 읽기를 각각 확인합니다.
   EH sequence 조회 성공은 이전 이벤트 본문 복구를 증명하지 않습니다.
4. Storage Redundancy, PG Replication, EH Geo-recovery, TM Endpoints의 전후 상태를 함께 기록합니다.

Redis는 KRS 앱에 이미 설정된 KRS instance를 사용합니다. **Force unlink**, Flush, 인스턴스 삭제로 전환을 흉내 내지 않습니다.
양 instance의 **Active geo-replication** 연결과 **Monitoring → Metrics → Geo Replication Healthy**를 확인합니다.
앱 성공과 복제 건강도는 별도로 기록합니다. eventual consistency이며 복제 시간 SLA를 보장하지 않습니다.
Search는 지역별 독립 인덱스이며 KRC에서 쓴 문서가 KRS에 자동 복제됐다고 가정하지 않습니다.
AKS 노드나 앱을 중지·재배포하지 않습니다. 앱의 오류/partial/disabled를 전체 성공으로 기록하지 않습니다.

## 4. KRC로 Failback

**순서: Storage Planned KRC → PostgreSQL KRC switchover → EH KRS 유지 확인 → TM KRC → 실제 데이터 확인.**
전환 후의 새 역할을 기준으로 수행하며 첫 전환 전 baseline과 혼동하지 않습니다.
다른 사용자의 쓰기와 샘플 업로드를 다시 중단하고 승인 및 각 단계 UTC를 기록합니다.

### 1. Storage: 동일 계정에서 다시 Planned

1. **Redundancy**에서 현재 Primary KRS/Secondary KRC, RA-GRS, 양 지역 정상 및 Planned 가능 상태를 확인합니다.
2. KRS에서 쓴 데이터의 복제 상태와 Last Sync Time을 확인합니다. 최초 KRC 업로드 manifest만으로 새 쓰기의 복제를 판단하지 않습니다.
3. **Prepare for Customer-Managed failover → Planned failover**에서 KRC를 새 primary로 확인하고 확정합니다.
4. 완료까지 기다리고 Primary **Korea Central**, Secondary **Korea South**, **RA-GRS**,
   양 지역 정상 및 전환 완료를 확인합니다. Unplanned나 redundancy 변경으로 원복을 대신하지 않습니다.

### 2. PostgreSQL: 현재 primary에서 KRC replica 승격

1. 현재 primary인 **KRS 서버 → Settings → Replication**에서 KRC replica를 확인합니다.
2. 양 서버 Ready, virtual reader=KRC를 확인한 뒤 KRC 옆 **Promote**를 선택합니다.
3. **Promote to primary server + Planned**로 확정합니다.
4. **KRC primary / KRS replica**, 양 서버 Ready, KRS source=KRC,
   virtual writer=KRC 및 reader=KRS를 확인합니다. standalone/Forced는 사용하지 않습니다.

### 3. Event Hubs: KRS 유지, failback 버튼 조작 없음

**KRS namespace → Geo-recovery**에서 기존 alias가 여전히 KRS에서 활성인지 확인합니다.
이 Geo-DR는 **fail-forward만 지원하며 이전 KRC로 자동 failback하지 않습니다.**
기존 KRC를 삭제하거나 다시 pairing하여 첫 상태로 맞추지 않습니다.
다음 보호 구성은 새 EMPTY namespace와 별도 변경 승인 작업이며 이번 원복 범위 밖입니다.

### 4. Traffic Manager와 probe 설정 확인

1. backend KRC 복귀가 끝난 뒤 **Endpoints → krc → Enabled → Save**, Online을 확인합니다.
2. **krs도 Enabled**로 유지/변경합니다. KRC Priority 1/KRS Priority 2이며 최종 양 endpoint Online이어야 합니다.
3. TM URL에서 응답 KRC와 일반 primary Storage 읽기를 확인합니다. DNS/연결 캐시가 남으면 완료로 기록하지 않습니다.
4. **Configuration**과 각 endpoint의 health checks를 처음 기록한 값과 비교합니다.
   이 포털판은 fast/probe 설정을 변경하지 않으므로 원래 값이면 별도 복구 명령이 필요하지 않습니다.
   다르면 승인된 원래 값으로 복구하고 Save 후 양 Online을 다시 확인합니다. 원래 값이 없으면 추측하지 않습니다.
5. TM 앱에서 새 UUID로 **쓰기 → 읽기**, Blob/PG 일치와 Redis/Search/EH 접근을 다시 확인합니다.

## 5. 완료 기록과 부분 실패

| 단계 | 시작/완료 UTC | 실제 리소스 | 완료 증거 |
|---|---|---|---|
| KRS 전환 | 기록 | Storage / EH / PG / TM | KRS Storage·PG·TM, EH alias KRS, 새 Blob/PG UUID와 서비스 결과 |
| KRC 원복 | 기록 | 같은 리소스 | KRC Storage·PG·TM, **EH KRS 유지**, TM 양 Enabled/Online, 새 UUID |

확인 버튼 클릭이나 포털의 알림 한 건만으로 완료로 기록하지 않습니다. 실제 역할·앱 데이터·최종 상태를 함께 확인합니다.
이번 전환·원복에서 측정하지 않은 RTO/RPO를 보장하지 않습니다.

오류나 연결 종료 시 포털 **Notifications / Activity log**의 작업 시각·대상·결과·correlation ID와
Storage/PG 역할, EH alias, TM endpoint 현재 상태부터 기록합니다. 실행 중 작업이 있으면 기다립니다.
반대 방향 작업, 전체 템플릿 재배포 또는 Bash DR 스크립트를 바로 실행하지 않습니다.
서로 다른 backend 역할이 섞인 상태에서는 쓰기를 멈추고 마지막으로 성공한 단계에서 재개 여부를 결정합니다.
지원되지 않는 옵션, 읽기 실패, partial 결과를 우회하지 말고 미완료로 남깁니다.

## 공식 근거

2026-10-29 기준 공식 문서와 대조했습니다. UI 개편 시 화면의 대상·의미를 먼저 확인합니다.

- [Storage 계정 failover: Portal, Planned 선택과 Redundancy](https://learn.microsoft.com/azure/storage/common/storage-initiate-account-failover)
- [Storage Planned failover/failback 동작](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-planned)
- [PostgreSQL replica switchover: Portal](https://learn.microsoft.com/azure/postgresql/read-replica/how-to-switch-over-replica-to-primary)
- [PostgreSQL promotion 제약](https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas-promote)
- [Event Hubs Geo-DR: Portal failover와 fail-forward](https://learn.microsoft.com/azure/event-hubs/configure-geo-disaster-recovery)
- [Traffic Manager endpoint Enabled/Disabled](https://learn.microsoft.com/azure/traffic-manager/traffic-manager-manage-endpoints)
- [Azure Managed Redis active geo-replication](https://learn.microsoft.com/azure/redis/how-to-active-geo-replication)

[다음: 리소스 정리](05-cleanup.md) · [Bash 버전](04-dr.md)