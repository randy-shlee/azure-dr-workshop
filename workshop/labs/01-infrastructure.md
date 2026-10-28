# Lab 01. Deploy to Azure → 인프라와 앱 자동 배포

[이전](00-readiness.md) · [목차](../README.md) · [다음](02-data.md)

고객 PC에서 이미지를 빌드하거나 후속 배포 스크립트를 시작하지 않습니다.
강사가 미리 공개한 **ARM JSON + runbook + docker save 아카이브**를 사용합니다.
버튼은 포털 입력 화면을 열며, 실제 과금 리소스 생성은 **Review + create → Create** 승인 후 시작합니다.

## 1-1. 포털에서 시작

<!-- DEPLOY_BUTTON_START -->
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.1%2Fworkshop%2Freleases%2Fazuredeploy.json)

Release: `randy-shlee/azure-dr-workshop@v1.0.1`. 게시된 공개 assets를 확인한 후 사용합니다.
<!-- DEPLOY_BUTTON_END -->

[공식 버튼 규격](https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-to-azure-button)에
따라 원격 Bicep이 아닌 **subscription-scope ARM JSON**을 연결합니다.
리소스 모듈은 JSON 내부에 포함되므로 고객이 별도로 모듈을 업로드하지 않습니다.

## 1-2. 생성 전에 확인할 항목

강사는 게시된 JSON의 SHA256, 실제 고객 프로필의 비용 및 Provider what-if를
[릴리스 절차](03-build.md#게시-전-what-if)대로 검토합니다.
포털 Review + create의 validation은 what-if나 실제 리전 용량 검증과 같지 않습니다.

| 입력 | 고객/강사 확인 |
|---|---|
| Subscription | 승인된 테스트 구독. Owner 또는 동등한 배포·역할 정의/할당 권한 필요 |
| Deployment location | `Korea Central` |
| prefix | 팀별 3~12자 소문자/숫자 권장. 전환 중 기존 환경에 재배포하지 않음 |
| owner / expiry | 실제 예산 수신 이메일 / ISO 날짜. 자동 삭제 기능이 아님 |
| monthlyBudget | 승인된 월 예산. 과금 차단 상한이 아님 |
| allowedClientCidrs | 테스트 브라우저의 공인 IPv4 CIDR 배열. 예: `["203.0.113.10/32"]`는 설명용이며 실제 IP로 교체 |
| administratorLogin / administratorPassword | 테스트 PG 관리자. 암호는 secure 입력이며 outputs/릴리스에 포함되지 않음 |
| deployWorkshopBootstrap | 게시된 워크숍 JSON 기본 `true`. Automation 계정 하나의 공용 네트워크 예외에 동의할 때만 사용 |
| bootstrapRunbookUri / Sha256, appImageArchiveUri / Sha256 | 강사가 패키징한 기본값 그대로. 공개된 동일 버전 GitHub Release와 정확히 일치해야 함 |
| sampleDataSizeGB / smallFileCount | 워크숍 기본 `10` / `2000` (실제 약 9.953GiB). 원본 Bicep의 100GiB 기본값과 다름 |
| skipSampleData | 기본 `false`. `true`이면 대용량 복제 실습은 제외 |
| deployEventHubs / deployRedis / deployAiSearch | full 기본 `true`. lite는 세 개와 enableEventHubsGeoReplication을 `false`로 변경 |
| 나머지 선택 기능 | ACR geo, App Gateway, DNS Resolver, alerts 기본 `false` 유지 |

기존 Bicep/CLI 경로는 `deployWorkshopBootstrap=false` 기본값을 유지합니다.
`main.bicepparam`의 환경 변수는 포털에 자동 반영되지 않습니다.
**D4s_v5 2노드/리전 등 현재 지원 SKU와 비용은 기존 기준을 유지**합니다.
KRS의 기능/용량 지원을 확인할 수 없으면 강사가 중단하거나 해당 기능을 명시적으로 끕니다.

## 1-3. Create 한 번으로 실행되는 작업

1. TM 포함 인프라를 한 번의 구독 배포로 생성합니다.
2. global RG에 Basic Automation 계정, encrypted 설정 asset, 게시 runbook과 실행 job을 생성합니다.
3. runbook이 MI로 KRC `AKS runCommand`를 호출해 **기존 AKS의 부트스트랩 Job**을 시작합니다.
4. AKS Job이 Release 이미지 아카이브를 내려받고 SHA256을 확인한 뒤,
   daemonless `crane`으로 **사설 ACR PE**에 push합니다. 재빌드, Docker-in-Docker,
   ACR admin 계정, `az acr import`, public/bypass 변경은 없습니다.
5. 기존 설정 생성·Search 초기화·앱 적용 코드를 재사용합니다. PG/Redis는 테스트용
   Secret으로 전달하고 양쪽 Ready, 고정 IP 일치, TM 두 endpoint Online을 확인합니다.
6. 화면을 먼저 사용할 수 있도록 앱 준비 뒤 샘플 업로드·복제/보조 읽기 검증을
   AKS에서 이어갑니다. 기존 CLI `deploy.sh`의 순서는 변경하지 않았습니다.

고객 PC에 private ACR 연결이나 Docker는 필요하지 않습니다. 대신 AKS outbound에서
공개 GitHub assets, MCR, Kubernetes 바이너리 다운로드와 Entra/ARM 접근이 허용되어야 합니다.
새 VM/NAT/VPN/Tasks pool은 생성하지 않습니다.
장시간 복제 대기 중 CLI 인증이 만료되지 않도록 부트스트랩은 각 ARM 호출 전에
현재 projected Workload Identity 토큰을 다시 읽습니다. 최초 로그인 토큰을 재사용하지 않습니다.

## 1-4. 완료 상태를 구분

| 상태 | 의미 / 다음 동작 |
|---|---|
| 포털 Deployment Succeeded | 인프라와 자동화 **시작 요청** 성공. 앱 완료가 아님 |
| Automation job Completed | 양 리전 앱 Ready + Service IP 일치 + TM Online 확인. 샘플은 계속될 수 있음 |
| KRC `workshop-bootstrap-status`의 ApplicationReady | 앱 준비 완료, 샘플 대기 가능 |
| KRC `workshop-bootstrap` Job Complete + status Complete | 샘플을 명시적으로 skip했거나 업로드·Last Sync Time·KRS 실제 읽기까지 확인 |
| Failed / Suspended / timeout | 성공으로 기록하지 말고 [문제 해결](../troubleshooting.md#포털-자동-배포)을 사용 |

포털의 구독 배포 **Outputs → config**에서 TM FQDN과 `bootstrap.accountName/jobId`를
확인합니다. 해당 Automation 계정 **Jobs**에서 job GUID의 Output/Errors를 확인합니다.
Automation cloud job의 3시간 제한을 피하기 위해 장시간 샘플 복제 대기는 AKS가 담당합니다.
앱 준비 대기 자체는 100분으로 제한되며 timeout은 오류로 남깁니다.

## 1-5. 테스트/훈련용 CLI 설정 복원

배포에는 필요 없지만 다음 Lab의 조회와 훈련 스크립트에는 Azure CLI/Bash가 필요합니다.
아래 파일에는 암호/키를 넣지 않습니다. Windows에서는 `.state`의 NTFS ACL도 사용자 전용인지 확인합니다.

```bash
umask 077
mkdir -p .state
cp workshop/templates/workshop.env.example .state/workshop.env
```

`.state/workshop.env`의 구독/prefix/CIDR과 **DEPLOYMENT_NAME**을 포털에서 실제 생성된
구독 배포 이름으로 수정합니다. 포털 이름을 `${PREFIX}-drtest`라고 가정하면 안 됩니다.
그 후:

```bash
source .state/workshop.env
az account set --subscription "$SUBSCRIPTION_ID"
source scripts/common.sh
load_config
cp workshop/templates/observations.csv "$STATE_DIR/observations.csv"
jq '{prefix,features,sampleData,trafficManager,bootstrap}' "$CONFIG_FILE"
bash scripts/bootstrap-status.sh --wait-app
```

이 명령은 작업을 시작하지 않고 **이미 시작된 자동 배포 상태만 관측**합니다.
`bootstrap-status.sh`는 준비 완료 0, 대기 중 2, 실패 1을 반환합니다.
`--wait-app`은 준비 또는 명시적 timeout까지 기다립니다.

## 새 터미널에서 복원

```bash
source .state/workshop.env
az account set --subscription "$SUBSCRIPTION_ID"
source scripts/common.sh
load_config
```

실제 outputs의 features를 기준으로 실습합니다. 셸 변수만 바꿔 배포된 서비스를
껐다고 가정하지 않습니다. 로그/outputs는 고객 환경 정보이므로 무단 공유하지 않습니다.

## 완료 게이트

- [ ] 게시된 버전·해시, 비용/권한/what-if 및 Automation 예외 승인
- [ ] 포털 배포 Succeeded와 앱 준비 완료를 별도로 확인
- [ ] 실제 DEPLOYMENT_NAME의 outputs 확보
- [ ] 양쪽 앱 Ready/고정 IP/TM Online 확인, 샘플 상태는 별도 관측
