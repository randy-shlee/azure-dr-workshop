# Azure Portal DR 워크숍

Deploy to Azure 버튼으로 Korea Central(KRC)·Korea South(KRS) 환경과 앱을 배포한 뒤,
실제 데이터를 확인하고 계획된 전환과 원복을 수행합니다. 역할별 구분 없이 하나의 순서로 진행합니다.

**시작 조건:** Azure 구독과 필요한 권한, 실습 전용의 새 prefix를 준비합니다.
[보안 안내](../../SECURITY.md)를 확인하고 각 단계의 완료 조건을 충족한 뒤 다음 단계로 진행합니다.

## 워크숍 아키텍처

![Korea Central과 Korea South의 DR 실습 아키텍처](../../workshop/assets/architecture.svg)

[큰 원본 이미지](../../workshop/assets/architecture.svg) · [Azure 아이콘 출처와 이용 조건](../../workshop/assets/azure-icons/NOTICE.md)

Korea Central(KRC)을 평시 서비스 지역, Korea South(KRS)를 준비된 대기 지역으로 사용합니다.
그림은 서비스 간 논리 관계를 보여주며 모든 네트워크 리소스나 배포 단계를 나타내지는 않습니다.
포털 배포에서는 별도의 Automation bootstrap이 양 지역 앱과 샘플 데이터를 자동으로 준비합니다.

| 구성 | 그림을 읽는 방법과 실습에서 확인할 것 |
|---|---|
| Traffic Manager와 양 지역 AKS | TM은 HTTP 프록시가 아니라 DNS로 앱 진입점을 안내합니다. **Priority 라우팅**으로 KRC 우선순위 1, KRS 2이며 99:1 분산이 아닙니다. 양 AKS에 앱이 실행됩니다. |
| VNet·Private Endpoint·Private DNS | 업무 PaaS와 ACR은 사설 경로로 접근합니다. 승인 IP로 제한된 앱 HTTP 진입점과 private AKS 관리 API는 별개입니다. |
| Blob Storage | **RA-GRS 계정 하나**입니다. 그림의 KRS Storage는 같은 계정의 읽기 전용 지역 복제본이며 별도 Storage account가 아닙니다. Planned failover로 쓰기 primary를 바꿉니다. |
| PostgreSQL | 평시 KRC primary/KRS read replica이며, Planned switchover로 역할을 교환합니다. 양 앱은 고정 writer alias를 사용합니다. |
| Event Hubs Standard | KRC/KRS namespace와 공통 DR alias를 사용합니다. **metadata-only Geo-DR**이므로 이벤트 본문은 복제하지 않으며, 전환 후 alias는 KRS에 남습니다. |
| Azure Managed Redis | 양 지역 active geo-replication입니다. 앱은 각 지역 instance를 사용하며 PG처럼 primary를 승격하지 않습니다. |
| Azure AI Search | 양 지역의 **독립 인덱스**입니다. 다른 지역으로 문서가 자동 복제된다고 가정하지 않습니다. |
| ACR·관측·ID | 양 AKS가 KRC의 같은 사설 ACR 이미지를 사용합니다. 모니터링과 관리 ID는 상태 관찰·서비스 접근을 지원하며, ACR geo-replication을 구성한 그림은 아닙니다. |

### 데이터와 DR 흐름

1. **평시 확인:** TM 주소로 KRC 앱에 접속합니다. 양 앱의 일반 Blob 읽기·쓰기는 primary hostname,
	PG는 writer alias, EH는 DR alias를 사용합니다. KRS 앱이 평시부터 자동으로 읽기 전용 backend를 사용하는 구조는 아닙니다.
2. **복제 확인:** 정확히 10 GB 샘플의 양 endpoint inventory, 실제 secondary 읽기,
	Last Sync Time을 확인합니다. Storage의 `-secondary` 읽기는 이 복제 확인용이며 일반 앱 읽기 경로가 아닙니다.
3. **KRS 전환:** Storage Planned → EH alias KRS → PG KRS switchover → TM KRS 순서로 진행한 뒤 실제 앱 쓰기·읽기를 확인합니다.
4. **KRC 원복:** Storage KRC → PG KRC → EH 현재 active 확인 → TM KRC 순서로 진행합니다.
	**EH alias는 KRS에 유지**하며, 최종 TM endpoint는 양쪽 Enabled/Online인지 확인합니다.

각 서비스의 역할을 별도로 확인해야 하며, 앱 응답 지역만으로 모든 데이터 서비스가 전환됐다고 판단하지 않습니다.
조작 순서와 완료 조건은 [포털 DR 가이드](04-dr-portal.md)를 따릅니다.
Premium EH의 payload 복제·재승격 원복은 [Premium 구성 비교](04-dr-portal.md#5-event-hubs-premium)와 구분합니다.

## 진행 순서

| 단계 | 수행할 작업 | 실행 위치 |
|---|---|---|
| [00. 실행 환경](00-environment.md) | 브라우저·Bash·접근 IP·구독 준비 | PC 브라우저와 Bash 터미널 |
| [01. 포털 배포](01-deploy.md) | 인프라·앱 자동 배포 시작 | Azure 포털 |
| [02. 준비 완료](02-ready.md) | 배포 출력 가져오기, bootstrap 상태, 앱 주소 확인 | 포털과 Bash 터미널 |
| [03. 앱 사용](03-application.md) | 쓰기·읽기, 10 GB 샘플과 복제 확인 | 앱 브라우저 |
| [04. 포털 DR](04-dr-portal.md) | 각 서비스 화면에서 KRS 전환, 데이터 확인, KRC 원복. [Bash 대안](04-dr.md) | Azure 포털과 앱 브라우저 |
| [05. 정리](05-cleanup.md) | 정확한 자원 삭제 또는 유료 보관 결정 | 포털과 Bash 터미널 |

각 문서의 완료 조건을 충족한 뒤 다음 단계로 이동합니다. 같은 환경의 DR와 삭제 명령은 한 번에
한 사람만 실행합니다. 앱의 동일 UUID를 비교하는 동안 다른 쓰기는 중단합니다.

## 알아둘 경계

- 앱과 샘플은 자동 배포됩니다. 로컬 Docker 빌드나 수동 앱 배포는 필요하지 않습니다.
- 포털의 배포 성공, 앱 준비 완료, 샘플 복제 완료는 서로 다른 상태입니다.
- AKS/PaaS 사설 접근을 공개로 바꾸지 않습니다. 관리 명령은 AKS Run command를 사용합니다.
- PG 암호·Redis 키를 사용하는 기존 앱 구성을 유지합니다. 비밀 값은 기록하거나 공유하지 않습니다.
- 실습용 앱은 승인 IP로 제한된 HTTP입니다. 운영용 보안·가용성 인증을 대신하지 않습니다.
- 리소스는 생성 시점부터 과금됩니다. 종료 날짜 태그는 자동 삭제나 비용 상한이 아닙니다.

[00. 실행 환경 준비로 이동](00-environment.md) · [Lab 홈](../README.md)