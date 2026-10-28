# Azure DR workshop

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.1%2Fworkshop%2Freleases%2Fazuredeploy.json)

[v1.0.1 릴리스](https://github.com/randy-shlee/azure-dr-workshop/releases/tag/v1.0.1)의
ARM 템플릿·runbook·Linux/amd64 이미지 아카이브를 사용합니다.
먼저 워크숍의 비용·권한·공개 네트워크 예외를 검토하세요. 버튼을 누르는 것만으로는
배포되지 않으며 **Review + create → Create** 승인 시 과금 리소스가 생성됩니다.

고객 실습은 [단계별 워크숍](workshop/README.md)을 사용하세요.
강사 로컬 이미지 build/save·GitHub Release 준비, Deploy to Azure와 양 AKS 자동 배포,
브라우저 테스트, DR 전환·원복, 비용 정리와 강사 가이드를 별도 폴더에 제공합니다.

포털 자동 배포는 선택 기능 `deployWorkshopBootstrap`입니다(원본 Bicep 기본 false,
워크숍 패키징 JSON 기본 true). [릴리스 패키저](scripts/package-workshop-release.ps1)가
ARM JSON/해시/runbook을 준비하고, 기존 AKS에서 Release 아카이브를 검증해
private ACR로 전송한 뒤 [공유 앱 적용기](scripts/app-apply.sh)를 실행합니다.
승인된 예외는 **부트스트랩 Automation 계정의 public networking만**이며
local auth/webhook은 사용하지 않습니다. 업무 PaaS/ACR의 private 정책은 유지합니다.
ARM 성공은 자동화 시작 성공이지 앱/샘플 완료가 아닙니다.
[상태 확인](scripts/bootstrap-status.sh)과 [포털 실습](workshop/labs/01-infrastructure.md)을 참고하세요.
공개 릴리스와 배포 버튼은 [포털 실습](workshop/labs/01-infrastructure.md)에서 확인합니다.
버튼은 포털 입력 화면만 열며 실제 Azure 리소스 생성은 별도 승인이 필요합니다.

Korea Central / Korea South 간 **훈련용** Bicep와 Bash 운영 도구입니다.
전환·원복, DNS 진입점, RA-GRS 보조 읽기를 확인합니다. 성능, SLA, 가용성,
운영계 보안 적합성 검증은 하지 않습니다. HTTP만 사용하며 TLS 인증서는 범위 밖입니다.
고객 데이터나 운영 자격 증명을 업로드하지 마세요.

## 먼저 알아둘 제약

- **AKS 사양 변경은 사용자 승인 사항입니다.** 현재 시스템 풀 문서는 B 시리즈를
  지원하지 않고 최소 4 vCPU, 2노드를 요구합니다. 따라서 요청의
  B2s_v2 → B2ms → D2s_v5 1노드 대신 **D4s_v5 2노드/리전**을 사용합니다.
  HA/가용성 영역/사용자 풀/오토스케일러/추가 애드온은 만들지 않습니다.
  [시스템 풀 제한](https://learn.microsoft.com/azure/aks/use-system-pools)
- D4s_v5는 임시 디스크가 없으며, 현재 구독의 Korea South SKU 조회에서도
  `EphemeralOSDiskSupported=False`입니다. 기본은 64GiB Managed OS 디스크입니다.
  `USE_EPHEMERAL_OS_DISK=true`는 검증한 호환 VM 크기로 변경한 경우에만 사용합니다.
  지원되지 않는 크기를 자동으로 비싼 크기로 바꾸지 않습니다.
- **공용 Service 접근 제한 변경도 사용자 승인 사항입니다.** AKS는
  `loadBalancerSourceRanges`와 `azure-allowed-service-tags`를 함께 지정하면
  오류를 반환합니다. 따라서 공용 Service는 `azure-allowed-ip-ranges`에
  동일한 클라이언트 CIDR을 넣고 `AzureTrafficManager` service tag와 함께
  사용합니다. 필터링은 NSG에서 수행되며 kube-proxy의 호스트 필터는 적용하지 않습니다.
  [공식 구성 제한](https://learn.microsoft.com/azure/aks/configure-load-balancer-standard)
- 리소스 그룹은 직접 관리하는 3개입니다. AKS는 별도로 노드 리소스 그룹
  `rg-<prefix>-krc-aks-managed`, `rg-<prefix>-krs-aks-managed`를 자동 생성합니다.
  클러스터 삭제 시 함께 정리됩니다. 예산 필터는 이 두 그룹도 포함합니다.
- 예산은 **구독 범위** 리소스이므로 global RG 안에 넣을 수 없습니다.
  3개 RG + 2개 AKS 관리 RG 비용만 필터링하여 월 예산 80%/100%에 owner 이메일로
  알립니다. **예산은 사용량 차단 장치가 아닙니다.** 통화는 구독 청구 통화입니다.
  사용자가 입력한 `$1000`은 `monthlyBudget=1000`으로 반영했습니다.
- 모든 태그 지원 리소스에 `purpose=dr-test`, `owner`, `expiry`를 설정합니다.
  예산, RBAC, DNS 레코드, 하위 구성처럼 태그를 지원하지 않는 형식에는 태그를
  넣지 않습니다. `expiry`는 자동 삭제를 실행하지 않습니다.
- 최신 GA API를 고정했습니다. 일부 2026 API는 Bicep 최신 릴리스에도 로컬
  타입 정보가 없어 BCP081 경고가 발생할 수 있습니다. 이 경고는 런타임 검증을
  대체하지 않습니다. Diagnostic Settings만 GA API가 없어 공식 문서의
  `2021-05-01-preview`를 사용합니다.
- KRS 리소스 유형 노출과 실제 SKU/geo 기능의 구독별 배포 가능성은 다릅니다.
  Event Hubs geo, Redis B3, DNS Resolver 등의 TODO와 Learn 링크를 확인하고,
  미지원 기능은 해당 bool을 끄세요. 용량 부족이나 권한 오류를 성공으로 처리하지 않습니다.

## 구성 및 비용

| 구성 | 기본값 / 이유 |
|---|---|
| VNet | KRC 10.10.0.0/16, KRS 10.20.0.0/16, 양방향 global peering |
| AKS | Private API, Free tier, Azure CNI Overlay, OIDC/Workload Identity |
| ACR | KRC Premium 1개. **Private Endpoint 필수 사유**, geo 기본 꺼짐 |
| Storage | KRC Standard_RAGRS Hot 1개, 키 인증 금지, 3개 blob PE |
| Event Hubs | Premium 1 PU/위치. **geo-replication 필수 사유** |
| PostgreSQL | GP D2ds_v5 primary/replica 각 1개, 32GiB, PG16 |
| Managed Redis | Balanced_B3 각 1개. **geo 지원 최소 등급** |
| AI Search | Basic, replica 1/partition 1 각 1개. **PE 최소 등급** |
| 진입점 | 리전별 Standard Static IP + Priority Traffic Manager |
| 모니터링 | KRC LA 1개, 30일, 1GB/일 한도, private AMPLS + PE 2개 |

`DEPLOY_EVENT_HUBS`, `DEPLOY_REDIS`, `DEPLOY_AI_SEARCH` 기본 `true`.
`ENABLE_ACR_GEO_REPLICATION`, `DEPLOY_APP_GATEWAY`, `DEPLOY_DNS_RESOLVER`,
`DEPLOY_ALERTS` 기본 `false`. 훈련하지 않는 서비스는 배포 전 끄는 것이 가장 저렴합니다.
**EH의 secondary도 같은 1 PU로 과금됩니다.** Redis 두 인스턴스, Search 두 서비스,
PG 두 서버도 각각 과금됩니다.
Managed Redis active geo는 **HA가 필수**이므로 Redis에 한해서
`highAvailability=Enabled`입니다. 이는 가용성 실험을 위한 선택 옵션이 아니라
[서비스 필수 조건](https://learn.microsoft.com/azure/redis/how-to-active-geo-replication)입니다.
가용성 영역은 요청하지 않으며 persistence는 끕니다. Redis 전체를 끄려면
`DEPLOY_REDIS=false`를 사용하세요.
전체 기본 구성을 한 달 유지하면 1,000 예산을 초과할 수 있습니다. 예산을
배포 가능 금액이나 견적 상한으로 해석하지 말고 Retail Prices 표를 먼저 확인하세요.
2026-10-27 Retail Prices API 조회의 전체 기본 구성 예시는 **약 USD 3,511.29/월**
(730시간, 28개 항목 매칭, UNKNOWN 0개)입니다. 4개 P6 64GiB OS 디스크와
15개 PE를 포함하고 ACR geo는 끈 값입니다. 가변 트래픽·처리량·알림·세금과
계약 할인은 별도이며 최신 가격은 스크립트로 다시 조회하세요.

Front Door, Firewall, Bastion, NAT Gateway, VPN/ExpressRoute Gateway, Jump VM은 없습니다.
AKS 접근은 `az aks command invoke`만 사용합니다. 기본 경로의 공용 IP는 AKS
공유 Standard LB의 outbound SNAT와 앱 frontend에 재사용합니다. 인터넷 egress는
이미지 다운로드와 Entra 토큰 교환에 필요하며 PaaS public data plane을 열지는 않습니다.

App Gateway를 켜면 WAF_v2 최소 고정 용량 1, 리전별 추가 공인 IP가 생성되고
TM은 그 IP를 사용합니다. 백엔드는 AKS internal LB `10.10.0.100` /
`10.20.0.100`입니다. 이 주소를 다른 Service에 할당하지 마세요. App Gateway
subnet NSG는 허용 클라이언트와 AzureTrafficManager만 HTTP에 허용합니다.
DNS Resolver는 네이티브 VNet DNS에는 불필요하며 켰을 때 inbound endpoint만 만듭니다.

## 준비 및 파라미터

Azure CLI, Bicep, Bash 4+, Python 3.9+, jq, curl, nslookup이 필요합니다. Windows는 Git Bash
또는 WSL의 Linux Azure CLI를 사용하세요. Azure CLI가 올바른 구독을 사용하는지
`az account show`로 확인하세요. 구독 배포, 리소스 생성, 역할 할당 및 예산 생성
권한이 필요합니다. 공급자 등록과 리전별 vCPU/서비스 할당량도 확인하세요.

```bash
az login
az account set --subscription '<subscription-id>'
export PREFIX=kkbdrtest
export OWNER_EMAIL='your-team@example.org'  # 실제 수신 주소 필수
export EXPIRY='2026-11-27'
export MONTHLY_BUDGET=1000
export ALLOWED_CLIENT_CIDRS='203.0.113.10/32' # 문서용 예시: 실제 브라우저의 공인 IPv4로 교체
export PG_ADMIN_LOGIN=dradmin
read -rs -p 'PG administrator password: ' PG_ADMIN_PASSWORD; echo
export PG_ADMIN_PASSWORD
```

암호를 파라미터 파일/셸 이력/Git에 저장하지 마세요. Bicep의 관리자 ID·암호는
secure 파라미터입니다. owner는 사용자가 아직 제공하지 않아 파라미터 파일의
`owner@example.com`은 what-if용 예제일 뿐이며 실제 배포 전에 바꿔야 합니다.

```bash
# 가장 싼 기능 확인 예: 비용 큰 선택 서비스 해제, 데이터 10GiB
export DEPLOY_EVENT_HUBS=false DEPLOY_REDIS=false DEPLOY_AI_SEARCH=false
export SAMPLE_DATA_SIZE_GB=10 SMALL_FILE_COUNT=2000
# 20,000MiB 작은 파일만으로도 10GiB를 초과하므로 두 값을 함께 조정

az bicep build --file infra/main.bicep
az deployment sub what-if --location koreacentral \
  --name "${PREFIX}-drtest" --template-file infra/main.bicep \
  --parameters infra/main.bicepparam --validation-level Provider
bash scripts/estimate-cost.sh --no-event-hubs --no-redis --no-search --storage-gb 10
bash scripts/deploy.sh
```

`estimate-cost.sh --help`의 서비스 스위치를 실제 배포 플래그와 맞춰 사용하세요.
`deploy.sh`는 what-if → 하나의 subscription 배포(TM 포함) → AKS 샘플 데이터
Job → 앱 배포 훅/엔드포인트 확인 순서입니다. 아래의 경량 FastAPI DR 확인 앱을
함께 제공합니다. 앱을 배포하지 않았으면 TM Degraded는 정상적인 초기 상태이며
훈련 성공으로 간주하면 안 됩니다. `APP_DEPLOY_COMMAND`에 실제 앱 배포 명령을
지정하거나 별도 앱 배포 후 상태 확인 단계를 실행하세요.
인프라만 먼저 준비하려면 `SKIP_APP_DEPLOY=true bash scripts/deploy.sh`로
**pending 상태를 명시적으로 허용**하세요. 앱 배포까지 포함하려면
`APP_DEPLOY_COMMAND='bash scripts/app-deploy.sh' bash scripts/deploy.sh`를 사용합니다.
앱 빌드에는 아래의 private ACR agent pool 및 Secret 준비가 먼저 필요합니다.
`deploy.sh --what-if`는 배포 없이 검토만 합니다.
기본 outputs 캐시는 `.state/config.json`이며 `STATE_DIR` / `CONFIG_FILE`로
변경할 수 있습니다. 이 파일과 훈련 CSV에는 환경 정보가 있으므로 Git에서 제외합니다.
실제 배포는 대상 구독을 확인하는 `DEPLOY <subscription>` 확인 문구를 요구합니다.
비대화형 실행은 같은 문자열을 `CONFIRM` 환경변수로 명시해야 합니다.
이 환경의 Azure CLI 2.89에서는 파라미터 파일만 지정한 what-if가 변경 0건을
반환했습니다. 따라서 스크립트와 위 예제는 **template-file을 명시**하여 실제
리소스가 확장되는 검증을 사용합니다.

배포 outputs의 `config`가 운영 스크립트와 앱 설정 생성의 공통 계약입니다.
선택 서비스를 끈 경우 해당 구성은 빈 객체이며 코드에서 키/가짜 접속 문자열을
만들지 않습니다. 앱은 Storage/EH/ACR/Search에 리전별 MI client ID와 Entra SDK
credential을 사용합니다. PG 관리자 인증과 Redis 인증은 이 네 서비스의 RBAC
계약에 포함되지 않으며 비밀번호/키를 outputs나 생성 설정에 넣지 않습니다.
Kubelet MI에는 AcrPull, 앱 MI에는 Blob Data Contributor / EH Data Owner /
Search Index Data Contributor를 지정합니다. Search 인덱스 정의 생성은 데이터
작업이 아니므로 스키마 생성에 필요한 Search Service Contributor도 사용합니다.
샘플 전용 MI는 `id-<prefix>-sampledata`이며 Blob Data Contributor만 사용합니다.
앱 MI에는 Last Sync Time의 ARM 조회를 위해 **Storage 계정 범위 Reader**를
추가합니다. 구독 전체 Reader를 부여하지 않습니다.

## 사설 DNS 및 RA-GRS 검증

각 리전에 동일한 이름의 **별도** DNS zone을 만들고 해당 VNet 하나에만 링크합니다.
Storage/Service Bus/PostgreSQL/Redis/Search/ACR의 6개 zone과 private Monitor에
필요한 추가 4개 zone이 있습니다. 모든 PE에 DNS zone group을 연결합니다.
한 리전의 zone을 반대 VNet에 링크하거나 zone을 공유하지 마세요.
PG의 두 실제 서버 이름만은 양쪽 별도 zone에 모두 기록합니다. 로컬 서버는
zone group이, 반대 서버는 명시적 A 레코드가 해당 PE를 가리킵니다. Global
peering으로 반대 PE에 접근하므로 writer/reader CNAME이 바뀌어도 사설 해석이
유지됩니다. Private Endpoint를 수동 재생성해 IP를 바꾼 경우 이 레코드도
갱신해야 하며, 훈련 중에는 수동 재생성하지 마세요.

Storage에는 KRC `blob`, KRS `blob`, KRS `blob_secondary`가 있습니다.
KRS zone에 `<account>`와 **`<account>-secondary`** A 레코드가 서로 다른
PE 사설 주소를 가리키는지 확인합니다.
KRC의 별도 zone에도 `<account>-secondary`를 KRS 보조 PE 주소로 기록합니다.
KRC 앱의 secondary 검사/읽기 재시도는 global peering을 경유하며 공용 endpoint로
우회하지 않습니다. 이 레코드도 PE 재생성 시 갱신해야 합니다.

```bash
ACCOUNT='<storage-account-output>'
az network private-dns record-set a show \
  -g "rg-${PREFIX}-krs" -z privatelink.blob.core.windows.net \
  -n "${ACCOUNT}-secondary" --query aRecords
# 사설 DNS 해석/보조 읽기는 KRS AKS 안에서 실행(로컬 PC에서는 확인 불가)
az aks command invoke -g "rg-${PREFIX}-krs" -n "aks-${PREFIX}-krs" \
  --command "kubectl -n drtest get jobs,pods"
```

보조 읽기 URL은 `https://<account>-secondary.blob.core.windows.net/...`입니다.
보조 엔드포인트는 쓰기용이 아닙니다. KRS에서 훈련 중 쓰기는 주 계정 이름을
사용해 KRS의 primary blob PE를 경유합니다. **Storage 계정 failover 명령은 없습니다.**
[공식 문서](https://learn.microsoft.com/azure/storage/common/storage-disaster-recovery-guidance)에
따르면 account failover는 통상 약 1시간 걸리고 failback에도 별도 시간이 듭니다.
실제 소요 시간은 보장되지 않습니다. 이 환경에서는 Last Sync Time과 secondary
읽기로 대체합니다. KRS가 실제 geo-paired secondary 위치인지 계정의
`secondaryLocation` 출력도 확인하세요.

## 샘플 데이터

배포 직후 KRC AKS의 Workload Identity Kubernetes Job이 PE로 업로드합니다.
배포 PC/deploymentScripts에서는 데이터를 업로드하지 않습니다.

기본 `sampleDataSizeGB=100`, `largeFileSizeGB=1`, `smallFileCount=20000`,
`smallFileSizeMB=1`, `skipSampleData=false`입니다. 단위는 GiB/MiB로 계산하며
80 × 1GiB + 20,000 × 1MiB = 약 **99.53GiB**입니다. 불가능한 조합은 실패시킵니다.
대형/소형 데이터는 `sampledata/large/`, `sampledata/small/`,
완료 정보는 `sampledata/_manifest.json`에 있습니다. 재실행 시 기존 blob을 덮어쓰지
않습니다. manifest가 완료되기 전 실패한 Job을 성공으로 취급하지 마세요.
기존 manifest/계획이 다르거나 blob 크기·개수가 계획과 다르면 완료 manifest를
만들지 않고 실패합니다. Job은 Azure CLI 2.85.0 이미지와 checksum으로 고정한
AzCopy 10.34.1을 사용합니다. 초기화 시 GitHub 배포 파일을 받을 outbound 접근이
필요합니다. Azure CLI/Entra 호출도 outbound를 사용합니다.
AzCopy bench의 생성 이름에 의존하면 재실행 시 같은 데이터를 건너뛰기 어려워,
대체 경로인 결정적 파일명·분할 생성·`azcopy copy --overwrite=false`를 사용합니다.
대형 파일은 스트리밍하고 작은 파일은 제한된 배치로 처리하여 전체 100GiB를
노드 디스크에 먼저 만들지 않습니다.

```bash
bash scripts/upload-sampledata.sh
```

기본 업로드 제한은 24시간, 복제 대기는 48시간입니다.
`UPLOAD_TIMEOUT_SECONDS`, `REPLICATION_TIMEOUT_SECONDS`,
`REPLICATION_POLL_SECONDS`(기본 600), `JOB_POLL_SECONDS`(기본 30)로 조정할 수
있습니다. 제한 초과는 성공이 아니라 오류입니다.
업로드 시간은 노드 대역폭, 디스크, Storage 제한에 따라 달라집니다. 100GB를
빠르게 올리는 성능 실험이 아닙니다. 업로드 종료 후 10분 간격으로 Last Sync Time이
manifest 종료 시각 이상인지 기다리고 CSV에 기록합니다. 계정 전체 복제 경계이므로
관찰 지연은 있을 수 있습니다. 실제 보조 읽기도 확인해야 합니다.

저장 용량, RA-GRS 지역 복제 전송, 쓰기/목록/읽기 요청, PE 처리량, peering,
인터넷 전송은 별도 과금 대상입니다. 완료 후 private AKS의 WI 도구 Pod/Job에서
sampledata 컨테이너의 blob을 삭제하거나 전체 리소스를 제거하세요. 예:
`azcopy remove "https://<account>.blob.core.windows.net/sampledata/*" --recursive=true`
(WORKLOAD 로그인 환경 안에서 실행; 로컬 PC에서는 public access 차단으로 실패).

## DR 훈련

앱 두 리전의 `/healthz`와 데이터 접근이 정상이고 TM 양쪽이 Online인 뒤 시작합니다.
TM은 프록시가 아니라 DNS 응답만 바꿉니다. PE/사설 IP는 TM Azure endpoint가
아닙니다. DNS TTL과 OS/브라우저/애플리케이션 캐시는 별도이며 TTL 0도 즉시 전환을
보장하지 않습니다. 공용 Service는 allowedClientCidrs를 allowed-ip-ranges에 넣고
AzureTrafficManager service tag를 함께 사용합니다. 생성된 Service annotation을 제거하지 마세요.

```bash
bash scripts/gen-app-config.sh
bash scripts/search-index.sh              # Search 사용 시, AKS 내부 REST
bash scripts/drill/00-precheck.sh
bash scripts/drill/05-fast-settings.sh
bash scripts/drill/10-failover.sh
# 앱 기능/엔드포인트/메시지/PG writer/reader/Storage secondary 읽기 확인
bash scripts/drill/20-failback.sh
bash scripts/drill/99-restore.sh
```

Event Hubs의 Bicep geo 구성을 끈 뒤 수동 구성 경로를 사용할 경우:

```bash
# namespace가 이미 배포된 상태에서 실행. 두 번째 Premium PU 과금 확인 필요.
CONFIRM="CONFIGURE EH GEO ${PREFIX}" bash scripts/eh-georeplication.sh configure
bash scripts/eh-georeplication.sh status
```

수동 configure는 복제 상태가 정상임을 확인한 후 로컬 runtime config의 geo
훈련 플래그를 켭니다. 실제로 Korea South geo가 지원되지 않는 경우 이 스크립트도
우회 수단이 아니며 Azure 오류로 종료합니다. 최대 복제 지연은
`MAX_REPLICATION_LAG_SECONDS`(기본 300)를 배포 outputs에서 읽습니다.
비동기 허용 범위는 300~86,400초입니다. 0은 동기 복제이므로 이 환경에서는
허용하지 않습니다.
다음 인프라 배포 시에는 `ENABLE_EH_GEO_REPLICATION=true`를 맞추세요.
전환 후에는 인프라 재배포 대신 역할 전환 스크립트를 사용하세요.

기본 TM 프로브는 30초/실패 3회/timeout 10초/TTL 60초이며 훈련 모드는
10초/실패 1회/timeout 5초/TTL 0입니다. **빠른 프로브는 추가 과금**됩니다.
완료/실패 여부와 관계없이 99번으로 복구하세요.
PG는 standalone promotion이 아니라 **planned switchover**를 사용해야 역방향
복제가 유지됩니다. writer/reader virtual endpoint를 앱에서 사용하세요.
원복은 backend 역할을 KRC로 돌린 후 KRC TM endpoint를 활성화하여 오래된
backend로 트래픽이 먼저 돌아가는 것을 방지합니다. 부분 성공/실패 후에는
00-precheck로 실제 역할을 확인한 다음 진행하고 인프라를 덮어 재배포하지 마세요.
모든 단계의 시작·종료/실패는 UTC `drill-log-<날짜>.csv`로 남깁니다.
전환/원복 확인 문구는 `FAILOVER <prefix>` / `FAILBACK <prefix>`입니다.
DNS 대기는 `DNS_TIMEOUT_SECONDS=900`, `DNS_POLL_SECONDS=10`,
EH는 `EH_TIMEOUT_SECONDS=3600`, `EH_POLL_SECONDS=20`이 기본이며 필요 시
환경변수로 변경하세요. `DNS_RESOLVER`로 확인할 리졸버를 지정할 수 있습니다.
앱의 health 경로는 기본 `/healthz`입니다. `HEALTH_PATH`를 바꾸면 인프라 TM
프로브 경로도 함께 맞춰야 합니다.

## 중지·재개·삭제

```bash
bash scripts/pause.sh
bash scripts/resume.sh
bash scripts/destroy.sh
```

AKS는 stop/start를 사용합니다. PG는 현재 primary/replica 역할을 조회하고
지원되는 범위에서 중지 primary → replica, 시작 replica → primary 순서로
처리합니다. 서비스가 현재 복제 토폴로지의 stop/start를 거절하면 명시적으로
실패시키고, 비용 절감을 위해 복제를 끊거나 standalone 승격하지 않습니다.
PG는 중지 후 7일이 지나면 자동 시작할 수 있습니다.
**Event Hubs/Redis/Search/ACR/Storage/PE/TM/IP/디스크는 계속 과금**됩니다.
App Gateway도 AKS 중지와 별개로 과금됩니다. 장기간 방치하지 마세요.

destroy는 대상 구독과 3개 RG를 제시하고 확인을 받은 뒤 삭제합니다. 구독 범위의
이 환경 전용 예산도 별도로 제거해야 하며 도구가 해당 이름을 확인합니다.
다른 구독 리소스/예산은 건드리지 않습니다.
중지는 `PAUSE <prefix>`, 삭제는
`DELETE <subscription> <primaryRG> <secondaryRG> <globalRG>`,
예산 삭제는 별도로 `DELETE BUDGET <budgetName>` 확인을 요구합니다.
비대화형 실행은 `CONFIRM`과 `CONFIRM_BUDGET`에 정확한 문구를 각각 지정합니다.

## 관찰 및 알림

Event Hubs ApplicationMetricsLogs, PG/TM AllMetrics를 단일 private LA로 보냅니다.
일일 1GB 한도는 실시간 비용 상한이 아니며 한도 도달 시 관찰 공백이 생길 수 있습니다.
AKS Container Insights는 비용 때문에 켜지 않습니다.

`DEPLOY_ALERTS=true`일 때 EH ReplicationLagDuration, 양 PG replica lag,
양 Redis geoReplicationHealthy, Storage native 복제 지연, TM endpoint 상태
알림을 만듭니다. Redis는 알림을 켰을 때만 AllMetrics 진단을 추가하고 로그
쿼리에서 **60개의 완료된 1분 버킷이 모두 존재하고 각각 Maximum=0**인지 확인합니다.
단순한 1시간 metric 창은 첫 번째 0 샘플만으로 발화할 수 있어 사용하지 않습니다.
샘플 부재는 건강/비정상의 증거로 판정하지 않으며, 수집 지연 시 알림도 지연됩니다.

Last Sync Time은 ARM 속성이지 Azure Monitor의 동명 native metric이 아닙니다.
정확한 Last Sync Time 지연 알림은 추가로
`ENABLE_STORAGE_LAST_SYNC_CUSTOM_METRIC_ALERT=true`를 명시한 경우에만 생성합니다.
이 기능이 사용하는 [직접 custom metrics](https://learn.microsoft.com/azure/azure-monitor/metrics/metrics-custom-overview)는
**preview**이므로 GA 기본 경로와 분리했습니다. `publish-storage-sync-metric.sh`가
`drtest/LastSyncAgeSeconds` custom metric을 게시해야 동작합니다. 호출자에게
Storage 범위의 Monitoring Metrics Publisher 권한이 필요합니다.
훈련 동안 외부 스케줄러/터미널에서 10분마다 실행하세요. 항상 켜진 유료 컴퓨트는
배포하지 않으므로 **게시기를 실행하지 않으면 이 알림은 동작하지 않습니다.**
네이티브 `ReplicationLagSeconds`와 Last Sync Time의 의미도 구별하세요.

## 검증 범위

Bicep build와 subscription what-if는 인프라 생성/데이터 경로/지역 용량 보장이
아닙니다. 제공된 앱의 실제 클라우드 실행, 100GB 업로드, 실제 planned switchover,
DR 기능 검증은 배포 후 실행해야 합니다. 생성 시 실행한 검증 결과와 남은
차단 사항은 아래에 기록합니다.

### 2026-10-27 검증 결과

- `az bicep build`: 전체 템플릿 성공. 최신 GA에 대한 BCP081 타입 카탈로그
  경고가 있으나 빌드 오류는 없습니다.
- 컴파일된 템플릿 검증: 앱용 Reader/secondary DNS를 포함한 163개 리소스 선언에 대해 private 접근, 최소 SKU,
  PG16/32GiB/HA off, Redis geo 필수 HA/persistence off, 예산, outputs,
  DNS zone group, 60분 지속 알림 조건 등을 확인합니다.
- 운영·샘플 데이터·앱 배포 회귀 테스트는 `bash scripts/tests/run.sh`로 실행합니다.
  public/internal Kustomize 렌더와
  유료 빌드/AKS 적용의 mock 흐름, 부분 API 실패 종료를 포함합니다.
- Provider 수준 subscription what-if:
  - 기본 구성: `Succeeded`, Create 58건, NestedDeploymentShortCircuited 경고 13건.
  - EH/Redis/Search를 끈 구성: `Succeeded`, Create 93건, 같은 종류 경고 1건.
  - App Gateway/DNS Resolver/알림/ACR geo/custom sync 알림을 모두 켠 구성:
    `Succeeded`, Create 64건, 같은 종류 경고 18건.
- 변경 수가 최소 구성에서 더 큰 것은 실제 비용이나 리소스 수가 더 많다는 뜻이
  아닙니다. 런타임 `reference()` 값이 남은 중첩 모듈은 what-if가 상세 확장을
  생략합니다. 따라서 **what-if 성공을 모든 리소스의 배포 가능성 검증 완료로
  해석하면 안 됩니다.** 실제 SKU 용량·지역 기능·PE 통신은 배포 시 확인해야 합니다.
- 실제 배포, 100GiB 업로드, 앱 배포, failover/failback은 실행하지 않았습니다.
  실수로 환경이 생성되거나 사용료가 발생하는 배포 명령은 실행하지 않았습니다.
- owner 이메일은 미입력으로 예제 주소로만 what-if를 수행했습니다. 실제 배포에는
  유효한 owner 이메일과 PG 암호가 필요합니다.
- 앱용 Reader/secondary DNS 변경 후에도 기본 Provider what-if:
  `Succeeded`, 변경 58건, NestedDeploymentShortCircuited 경고 13건을 확인했습니다.
- 실제 브라우저에서 loopback fixture로 6개 카드, 정상/실패/disabled, 리전
  불일치 경고/복구, 쓰기/읽기/샘플 표, 최근 이벤트 20개 제한, 10초 자동
  갱신 토글, sample 비자동 호출, fetch no-store, 390px 모바일 레이아웃을 확인했습니다.
  이는 Azure 연결 성공 증거가 아닙니다.
- 백엔드 단위 테스트: 29개 통과. 읽기 응답 표 계약, optional 서비스 disabled,
  secondary 재시도/실제 PE 표시, 토큰 재시도 중첩 방지, `_manifest.json` 집계와
  실패/불일치 시 복제 완료 오판 방지를 포함합니다.
- Pylance 문법/진단 오류 없음, 의존성 `pip check` 통과.
  실제 FastAPI를 로컬에서 기동하여 health/info/no-store와 클라우드 설정을 비운
  상태의 카드/읽기 표도 확인했습니다. 테스트 인터프리터는 **Python 3.13.13**이며
  Python 3.12 문법 파싱도 통과했습니다. Docker/Python 3.12 실행 환경이 없어
  **컨테이너 빌드 및 3.12 런타임 실행은 미검증**입니다.

로컬 템플릿 검증(PowerShell 7):

```powershell
az bicep build --file infra\main.bicep --outfile "$env:TEMP\kkbdrtest-main.json"
.\infra\tests\validate-template.ps1 -TemplatePath "$env:TEMP\kkbdrtest-main.json"
Remove-Item -LiteralPath "$env:TEMP\kkbdrtest-main.json"
```

## 브라우저 DR 확인 앱

런타임 코드는 [app/main.py](app/main.py)와
[app/static/index.html](app/static/index.html) 두 파일입니다. Python 3.12 +
FastAPI 단일 컨테이너이며 HTML은 외부 CDN/빌드 도구 없이 동작합니다.
Deployment는 replica 1, 요청 100m/128Mi, 제한 500m/256Mi이고 별도 앱 노드
풀을 만들지 않습니다. 앞서 승인된 AKS 시스템 풀 최소 사양은 그대로 유지합니다.

앱은 **인터넷용 인증 서비스가 없는 테스트 도구**입니다. 허용한 테스트 PC/사내
공인 CIDR에서만 사용하세요. HTTP만 사용하며 TLS 인증서·사용자 로그인·운영용
비밀 관리·성능/가용성 보장은 범위 밖입니다. Secret/암호를 브라우저에 입력하거나
URL에 넣지 마세요. 요청 Host/클라이언트 IP는 관측값이며 인증 근거가 아닙니다.

### 구성과 인증

`bash scripts/gen-app-config.sh`가 인프라 outputs로
[k8s/overlays/krc](k8s/overlays/krc)와 [k8s/overlays/krs](k8s/overlays/krs)를
생성합니다(생성물은 Git 제외). 공통 Deployment/Service/ServiceAccount는
[k8s/base](k8s/base)에 있습니다. Secret은 이 명령이 만들지 않습니다.

| 환경 변수 | 설정/의미 |
|---|---|
| `REGION`, `POD_NAME` | krc/krs, Pod downward API |
| `STORAGE_ACCOUNT`, `STORAGE_READ_MODE` | 같은 RA-GRS 계정, KRC=primary/KRS=secondary |
| `EH_NAMESPACE`, `EH_NAME` | 양 리전 동일 namespace FQDN / drtest-events |
| `PG_HOST`, `PG_DB`, `PG_USER` | 양 리전 동일 writer virtual endpoint, 기본 postgres DB, 배포 시 PG_USER 지정 |
| `PG_PASSWORD` | 테스트 전용 Kubernetes Secret; 테이블 dr_test는 앱이 자동 생성 |
| `REDIS_HOST`, `REDIS_PORT`, `REDIS_KEY` | 리전별 Managed Redis, TLS 10000, Secret 키 |
| `SEARCH_ENDPOINT`, `SEARCH_INDEX` | 리전별 Search, dr-samples |
| `KRC_VNET_PREFIX`, `KRS_VNET_PREFIX` | 10.10. / 10.20.; PE IP 관측 분류 |
| `TM_FQDN`, `KRC_PUBLIC_IP`, `KRS_PUBLIC_IP` | TM DNS 및 리전 판정; App Gateway 모드에서는 gateway 공인 IP |
| `AZURE_CLIENT_ID` | 리전별 앱 Workload Identity |
| `AZURE_SUBSCRIPTION_ID`, `STORAGE_RESOURCE_ID` | ARM geoReplicationStats Last Sync Time 조회 |

`PG_USER`/`PG_DB`를 export하면 생성 설정을 덮어쓸 수 있습니다. 별도 DB는 자동
생성하지 않으므로 먼저 실제 DB를 준비하세요. 인프라 관리자 로그인은 secure
파라미터라 outputs로 노출하지 않습니다. 앱 배포에는 `PG_USER`를 직접 지정해야
합니다. 설정 생성만 실행할 때 기본 예제 로그인은 dradmin입니다.
Storage/Event Hubs/Search는 DefaultAzureCredential의 Workload Identity를 사용하고
ACR 이미지 pull은 kubelet identity가 담당합니다. Redis는 OSSCluster
리디렉션을 지원하는 cluster client를 사용합니다.
EH/Redis/Search를 끄면 해당 연결 환경 변수가 비어 있고 앱은 `disabled`로 표시합니다.
부분 설정 누락이나 실제 연결 실패를 disabled/정상으로 위장하지 않습니다.

공용 Service는 인프라 Static IP 이름·RG를 지정합니다. AKS 공식 문서에서
`loadBalancerSourceRanges`와 `azure-allowed-service-tags`의 동시 사용은 오류임을
확인하여, 승인한 `azure-allowed-ip-ranges` + `AzureTrafficManager` 조합을
유지합니다. 이는 NSG 레이어 필터이며 host-level kube-proxy 필터는 아닙니다.
[공식 어노테이션 설명](https://learn.microsoft.com/azure/aks/configure-load-balancer-standard#restrict-inbound-traffic-to-specific-ip-ranges)을
참고하세요. 이 문서에서 CIDR/tag 병합은 preview로도 표시되므로 AKS 지원 상태를
배포 시 확인하세요. App Gateway를 켜면 Service는 내부 LB, source range는
gateway subnet만 허용하며 공용 tag/IP 어노테이션을 상속하지 않습니다.

### Private ACR 이미지 빌드 및 앱 배포

ACR은 publicNetworkAccess Disabled / bypass None입니다. 일반 공유 ACR Tasks
빌드에 맞추려고 public 접근이나 trusted-service bypass를 자동으로 열지 않습니다.
따라서 **운영자가 미리 준비한 VNet 연결 ACR Tasks 전용 agent pool**과 그
서브넷의 ACR PE/DNS 접근이 필요합니다. 이 기능과 `az acr build --agent-pool`은
**preview**이며 별도 상시 컴퓨트 비용·리전 지원 확인이 필요합니다. 기본 Bicep은
pool을 생성하지 않습니다. 기존 private 연결 빌드 환경을 쓰고 미사용 pool도 별도로
중지/삭제하세요. 인프라 예산/정적 SKU 비용표에는 외부 pool 비용이 포함되지 않습니다.
[agent pool 구성/지역/방화벽 요건](https://learn.microsoft.com/azure/container-registry/tasks-agent-pools),
[private ACR 접근 제한](https://learn.microsoft.com/azure/container-registry/container-registry-private-endpoints)을
먼저 확인하세요. 빌드 노드는 Docker Hub/PyPI에 나갈 수 있어야 하고, 배포 PC도
로컬 build context 업로드에 필요한 private 연결/DNS를 갖추어야 합니다.
이 요구사항을 위해 Jump VM/VPN/NAT/Public ACR을 자동 추가하지 않습니다.

```bash
# az login / account set 및 인프라 배포, 샘플 Job, Search 인덱스 준비 후
export ACR_AGENT_POOL='<이미 준비한 private agent pool>'
export PG_USER='<인프라에 지정한 PG 관리자 로그인>'
read -rs -p 'PG password: ' PG_PASSWORD; echo; export PG_PASSWORD
# Redis를 켰을 때만 각 리전 database 키를 읽어 입력(두 키가 같다고 가정하지 않음)
read -rs -p 'KRC Redis key: ' REDIS_KEY_KRC; echo; export REDIS_KEY_KRC
read -rs -p 'KRS Redis key: ' REDIS_KEY_KRS; echo; export REDIS_KEY_KRS
bash scripts/app-deploy.sh
unset PG_PASSWORD REDIS_KEY_KRC REDIS_KEY_KRS
```

스크립트는 `DEPLOY APP <subscription> <prefix>` 확인 후 app 디렉터리만
ACR로 전송하여 유료 빌드 → 새 태그로 overlay 생성 → 로컬 Kustomize 렌더 →
AKS command invoke 적용 → 양쪽 readiness/Service IP 검증 → TM 두 엔드포인트
Enabled/Online까지 기다립니다. `APP_TAG`로 태그를 지정할 수 있으나 기존 태그를
재사용하지 마세요(기본은 UTC 시각 새 태그). 평시/원복 상태에서 배포하세요.
훈련 중 Disabled인 TM endpoint가 있으면 성공으로 처리하지 않습니다.
`APP_ROLLOUT_TIMEOUT_SECONDS=600`, `APP_LB_TIMEOUT_SECONDS=600`,
`APP_TM_TIMEOUT_SECONDS=900`, `APP_POLL_SECONDS=10`으로 대기를 조정할 수 있습니다.
개인 암호/키는 umask 077 임시 파일로 command invoke에 첨부하고 종료 시
삭제하며 shell 명령/출력/overlay에 넣지 않습니다. Kubernetes Secret과
command invoke의 관리 평면 접근 권한도 테스트용 비밀 접근 경계입니다.
스크립트를 `bash -x` 또는 `az --debug`로 실행하지 마세요.

접속:

- TM: `http://<prefix>-dr.trafficmanager.net/`
- KRC 직접: `http://<prefix>-app-krc.koreacentral.cloudapp.azure.com/`
- KRS 직접: `http://<prefix>-app-krs.koreasouth.cloudapp.azure.com/`
- App Gateway 모드에서는 outputs의 리전 gateway 주소를 사용하세요.

### API 관측 의미

- `/healthz`는 의존 서비스를 호출하지 않습니다. TM Online은 **앱 생존**을
  뜻하며 PG/EH/Storage 정상 여부는 `/api/check`로 확인해야 합니다.
- `/api/info`, `/api/tm`, `/api/check`는 10초 자동 새로고침(토글 가능);
  `/api/sampledata`는 버튼을 누른 경우에만 조회합니다. 브라우저 fetch와 API
  응답 모두 no-store입니다. 최근 20건 리전 이벤트는 해당 탭 메모리에만 남습니다.
- 외부 작업 timeout은 시도당 3초, 재시도 1회이며 목록 조회는 시도당 10초 제한입니다.
  샘플 목록만 300초 캐시합니다. SDK/네트워크/인증 시간이 포함되어 전체 HTTP
  응답이 3초라는 뜻은 아닙니다. 목록 조회가 두 번 모두 제한 내에 끝나지 않으면 명시적 오류이며
  부분 목록을 완전한 집계처럼 표시하지 않습니다.
- `/api/write`는 하나의 UUID/UTC 시각을 각 서비스에 기록하며 분산 트랜잭션이
  아닙니다. 일부 성공/실패는 서비스별로 표시하고 Blob primary 쓰기 실패 시
  `read_only:true`를 반환합니다. Event Hubs 전송 재시도는 중복 이벤트를 만들 수
  있으므로 UUID로 식별하세요. UI 버튼 클릭은 실제 테스트 데이터를 생성합니다.
- `/api/read`는 PG/Redis/Blob 최신 자료, Search 문서 수, EH 파티션별 마지막
  sequence number를 반환합니다. 이것은 EH 이벤트 소비/완전성 검증은 아닙니다.
  Search 두 인덱스는 독립적이며 자동 geo-replication을 가정하지 않습니다.
- Blob 쓰기는 KRS 앱에서도 **항상 primary 계정**으로 전송합니다. secondary
  읽기 모드에서는 보조 주소만 읽고, primary 읽기는 실패 시 secondary hostname
  재시도를 사용합니다. 실제 읽은 endpoint/fallback 결과를 확인하세요.
- 샘플은 primary/secondary의 manifest, large/small 파일 수와 바이트, 임의 파일
  최대 1MiB range 읽기 시간, ARM Last Sync Time을 표시합니다. 파일 크기가
  1MiB보다 작으면 실제 읽은 바이트를 참고하세요. `replication_complete`가
  미확인/null이면 완료로 해석하지 마세요. 목록 캐시와 복제 지연 때문에 값이
  일시적으로 다를 수 있습니다.
- `pe_region`은 **Pod가 해석한 PE IP 대역**입니다. EH/PG의 현재 primary 리전이나
  Storage 실제 데이터 배치 리전의 증거가 아닙니다. 그 역할/복제 상태는 drill
  precheck와 함께 확인하세요. TM API는 Pod의 DNS 리졸버 관측이며 브라우저와
  동일한 캐시를 공유하지 않습니다.

### 브라우저를 열어 둔 DR 훈련

1. 평시: 응답 서버/TM 안내 배지 KRC, 쓰기/읽기 정상. 샘플 버튼에서 양쪽
   파일 수·용량과 Last Sync Time 기반 복제 완료를 확인합니다.
2. `bash scripts/drill/05-fast-settings.sh` →
   `bash scripts/drill/10-failover.sh`. 이벤트 로그의 TM 안내 KRC→KRS,
   응답 리전 KRC→KRS 시각을 각각 기록합니다.
3. KRS에서 Storage secondary 카드 `pe_region=KRS`, secondary 샘플 읽기,
   PG/EH planned 전환 후 쓰기 성공을 확인합니다. Blob primary 쓰기는 계속
   KRC 계정으로 향합니다(계정 failover 없음).
4. `bash scripts/drill/20-failback.sh` → 두 배지 KRC 복귀 →
   `bash scripts/drill/99-restore.sh`.
5. UI UTC 이벤트와 `drill-log-<날짜>.csv`를 비교합니다. 두 관측 시각 차이는
   DNS 캐시뿐 아니라 10초 polling·Pod resolver·기존 연결 영향도 포함합니다.
6. CLI 확인은 `bash scripts/test-app.sh`입니다. TM nslookup/IP 판정, info,
   write/read/sampledata 및 두 Pod 내부 check의 PE 표를 출력하며 의존 서비스
   오류가 있으면 nonzero 종료합니다. 중간 HTTP/관리 명령 실패도 즉시 종료합니다.
7. 완료 후 반드시 pause 또는 destroy를 실행하고 외부 agent pool 과금도 정리하세요.

로컬 테스트는 클라우드 통신을 mock하며 실제 자격 증명/유료 배포가 필요 없습니다.
백엔드 테스트와 운영 스크립트 테스트는 별도 실행합니다:

```bash
python -m venv .venv
# Linux/Git Bash: source .venv/bin/activate
# Windows PowerShell: .\.venv\Scripts\Activate.ps1
python -m pip install -r app/requirements.txt
python -m unittest discover -s tests -p 'test_app.py'
bash scripts/tests/run.sh
```

UI만 Azure 없이 확인하려면 `python tests/serve_dashboard_fixture.py`로
loopback `http://127.0.0.1:8766/`을 엽니다. fixture는 명시적으로 가짜 데이터와
실패/disabled를 반환하는 **테스트 서버**이며 실제 앱 대신 배포하지 마세요.
테스트 후 Ctrl+C로 중지합니다.

실제 배포/이미지 빌드/DR 전환은 이 로컬 검증과 구분해야 합니다. 컨테이너
target은 Python 3.12이며 로컬 검증 interpreter 버전도 결과와 함께 기록하세요.
