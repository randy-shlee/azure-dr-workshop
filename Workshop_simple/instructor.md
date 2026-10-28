# 강사용 준비·명령·복구

[참가자 목차](README.md) · [기존 상세 문제 해결](../workshop/troubleshooting.md)

## 1. 수업 전 게이트

팀 환경 하나당 오퍼레이터 한 명을 지정합니다. 가능하면 전날 배포·복제를 완료하세요.

- 테스트 구독·prefix·공인 CIDR·삭제 담당자·full/lite·실제 비용을 승인받습니다.
  예산 리소스가 없으므로 비용 책임을 별도로 확인합니다.
- 지역 기능/할당량/정책을 실제 구독에서 확인합니다. D4s_v5 2노드/리전은 유지합니다.
- 공개 [v1.0.3 릴리스](https://github.com/randy-shlee/azure-dr-workshop/releases/tag/v1.0.3)의
  네 assets와 manifest.templateUri의 익명 다운로드·SHA256/CORS를 확인합니다.
- 고객용 bootstrap=true JSON과 실제 파라미터로 Provider what-if를 검토합니다.
  [명령과 패키징 절차](../workshop/labs/03-build.md#게시-전-what-if)를 재사용합니다.
  원본 CLI용 bootstrap=false 결과나 포털 validation으로 대체하지 않습니다.
- Automation 계정 하나의 public networking 예외, custom-role 생성/할당,
  AKS command invoke, PG switchover, TM 변경, full의 EH geo/Redis listKeys 권한을 확인합니다.
- AKS outbound의 GitHub/MCR/도구 다운로드/Entra/ARM과 ACR PE/DNS를 확인합니다.
  새 VM/VPN/NAT/Tasks pool이나 업무 PaaS public 접근을 추가하지 않습니다.
- 참가자 PC의 HTTP 앱 접근과 브라우저 출구 IP를 확인합니다.
  Run command의 포털 노출/권한을 확인하고, 없으면 아래 CLI 조회를 강사가 담당합니다.

참가자는 Docker/Bash 도구가 필요 없습니다. 오퍼레이터 PC에는 **Bash 4+, Azure CLI,
Python 3.9+, jq, curl, nslookup**이 필요합니다. Windows는 Git Bash를 사용합니다.
로컬 kubectl 없이도 기존 스크립트는 AKS command invoke로 조회합니다.
새 릴리스 제작자에게만 로컬 Docker Linux 엔진·PowerShell 7.2+·Bicep이 필요합니다.

## 2. 오퍼레이터 터미널 한 번 준비

아래는 저장소 루트의 **Bash / Windows Git Bash**입니다. PowerShell에 붙여 넣지 마세요.
소스가 없을 때만 공개 저장소를 clone하고 루트로 이동합니다.

```bash
git clone https://github.com/randy-shlee/azure-dr-workshop.git
cd azure-dr-workshop
```

기존 소스가 있으면 승인된 같은 버전을 사용합니다. 준비된 환경을 재배포하지 않습니다.

```bash
umask 077
mkdir -p .state
cp workshop/templates/workshop.env.example .state/workshop.env
```

`.state/workshop.env`를 편집해 실제 SUBSCRIPTION_ID/PREFIX/EXPIRY/CIDR과
**DEPLOYMENT_NAME**을 넣습니다. 배포 이름은 포털 구독 Deployments의 실제 이름입니다.
암호·키는 넣지 않습니다. Windows에서는 `.state`의 NTFS ACL도 사용자 전용인지 확인합니다.

```bash
az login
source .state/workshop.env
az account set --subscription "$SUBSCRIPTION_ID"
source scripts/common.sh
load_config
jq '{prefix,primaryResourceGroup,secondaryResourceGroup,globalResourceGroup,budget,budgetName,features,sampleData,bootstrap}' "$CONFIG_FILE"
```

포털 프로필은 budget=0, budgetName=""입니다. feature/샘플 값은 실제 outputs 기준입니다.
여러 환경을 다룰 때는 환경 파일도 분리하고 구독/prefix/config를 매번 확인하세요.
잘못된 기존 config가 있으면 다른 팀 파일을 덮어쓰지 말고 올바른 팀 STATE_DIR를 사용합니다.

새 터미널은 로그인 상태를 확인한 뒤 다음으로 복원합니다.

```bash
source .state/workshop.env
az account set --subscription "$SUBSCRIPTION_ID"
source scripts/common.sh
load_config
```

## 3. 준비와 샘플 완료 확인

```bash
bash scripts/bootstrap-status.sh --wait-app
```

이 명령은 자동화를 시작하지 않고 관측만 합니다. 대기 없는 호출은 준비 0/대기 2/실패 1,
--wait-app은 준비 또는 timeout까지 기다립니다. 앱 준비가 샘플 완료를 뜻하지 않습니다.

```bash
aks_run primary 'kubectl -n drtest get configmap workshop-bootstrap-status -o yaml'
aks_run primary 'kubectl -n drtest get job workshop-bootstrap -o json'
```

phase Complete와 Job Complete, sampleData.skip=false를 함께 확인합니다.
앱 샘플 버튼에서 manifest/파일 수·용량/Last Sync Time/secondary 실제 읽기를 확인합니다.
필요한 상세 증거만 다음으로 조회합니다.

```bash
aks_run primary 'kubectl -n drtest logs job/sampledata-upload -c upload --tail=20'
aks_run secondary 'kubectl -n drtest logs job/sampledata-verify -c upload --tail=20'
```

정상 로그의 UPLOAD_MANIFEST/SECONDARY_READ_VERIFIED와 앱 결과를 대조합니다.
샘플 복제 대기는 기본 최대 48시간이며 수업 내 완료를 보장하지 않습니다.
복제 미완료면 DR는 보류하고 준비된 별도 환경 관찰로 범위를 명시합니다.

주소와 TM 상태를 확인합니다.

```bash
printf 'TM: http://%s/\nKRC: http://%s/\nKRS: http://%s/\n' \
  "$(cfg '.trafficManager.fqdn')" "$(cfg '.primary.publicIp.fqdn')" "$(cfg '.secondary.publicIp.fqdn')"
tm_assert_online
```

양 앱 Ready·같은 이미지·Service IP 일치는 자동화 결과와
[고급 Lab 04의 조회](../workshop/labs/04-application.md#4-4-기본-경로-ready와-실제-이미지-확인)를 사용합니다.
서비스 정상 표시는 /healthz만으로 판정하지 않고 참가자 앱의 실제 데이터 작업과 함께 확인합니다.

## 4. 전환·원복과 실패 대응

[참가자 Lab 04](04-dr.md)의 명령을 지정 오퍼레이터만 실행합니다.
전환 전 PG가 KRC writer인지, EH geo 사용 시 KRC가 실제 primary인지 확인합니다.

```bash
for key in primary secondary; do
  az postgres flexible-server show -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" \
    --query '{state:state,role:replicationRole,source:sourceServerResourceId}' -o json
done
if enabled '.features.deployEventHubs' && enabled '.features.enableEventHubsGeoReplication'; then
  bash scripts/eh-georeplication.sh status
fi
```

KRS 전환 후와 KRC 원복 후에도 같은 역할 조회를 수행합니다.
기본 프로브 30초/3회/timeout 10초·TTL 60을 유지합니다.
기존에 fast 설정을 사용했다면 복구 시 다음을 실행하고 실제 값을 확인합니다.

```bash
bash scripts/drill/99-restore.sh
```

```bash
az network traffic-manager profile show --ids "$(cfg '.trafficManager.id')" \
  --query '{ttl:dnsConfig.ttl,monitor:monitorConfig,endpoints:endpoints[].{name:name,status:endpointStatus,monitor:endpointMonitorStatus}}' -o json
```

실패하면 $STATE_DIR의 drill CSV ERROR 단계와 실제 PG/EH/TM 역할을 대조합니다.
KRS 트래픽 중 평시 precheck는 양쪽 Enabled 요구 때문에 실패할 수 있습니다.
오류 상태를 성공으로 바꾸거나 반대 스크립트를 자동 실행하지 않습니다.
상세 진단은 [기존 DR Lab](../workshop/labs/06-drill.md#실패부분-성공-시),
수동 앱 복구는 [고급 Lab 04](../workshop/labs/04-application.md)를 사용합니다.
Secret 조회/로그 출력, public 우회, standalone PG promotion, Storage account failover는 금지합니다.

## 5. 정리와 종료

포털 수동 삭제 전에 실제 세 RG·두 node RG·bootstrap.operatorRoleId를 기록합니다.
기존 [정리 스크립트](../scripts/destroy.sh)를 사용할 때는 **포털 삭제와 동시에 실행하지 않습니다**.
아직 세 RG/custom role이 존재하고 outputs가 유효한 상태에서 둘 중 한 경로를 선택하세요.

```bash
unset CONFIRM CONFIRM_BUDGET CONFIRM_BOOTSTRAP_ROLE
REQUIRE_OWNER_TAG=false bash scripts/destroy.sh
```

구독·정확한 RG 이름과 DELETE 확인 문구, bootstrap role 이름/ID를 확인합니다.
budgetName이 빈 포털 프로필은 예산 확인/삭제를 생략합니다.
owner가 있는 기존 CLI 환경은 이 과정과 구별하고 기존 owner 검증을 유지합니다.

포털로 정리했다면 **구독 IAM → Roles**에서 정확한 팀 bootstrap custom role을 찾아
연관된 역할 할당 정리 후 삭제합니다. 구독의 다른 역할/예산을 지우지 않습니다.
목록/권한 오류는 삭제 완료 증거가 아닙니다. 실제 RG 부재와 역할 삭제를 확인합니다.
스크립트는 성공 시 config 파일을 제거하므로 삭제 후 load_config로 복구하려 하지 않습니다.

- [ ] 원복/프로브 상태 또는 미완료 상태와 증거 기록
- [ ] 세 RG·AKS 관리 RG·bootstrap custom role 삭제/명시적 보관 승인
- [ ] 실제 비용 반영 지연을 고려한 다음 날 점검 담당자 지정
- [ ] Azure와 별개인 GitHub 공개 assets/로컬 이미지의 보관 책임 인계

## 6. 자료 유지보수와 검증 범위

앱/Bicep/스크립트는 복제하지 않습니다. 새 릴리스는
[기존 패키징 절차](../workshop/labs/03-build.md)를 사용하고, 루트 README·고급 Lab 01·
[간단 Lab 01](01-deploy.md)의 버튼/릴리스 버전을 함께 갱신합니다.
패키저의 -UpdateWorkshopButton은 현재 고급 Lab 01만 갱신하므로 나머지도 검토하세요.

이 문서는 기존 명령 계약과 링크/셸 구문으로 검증하며, 고객 구독에서의 실제 배포·
private 연결·전환·삭제 리허설을 대신하지 않습니다. 성공 화면을 임의로 만들지 않았으며,
고객 리허설에서 비밀/계정 정보가 없는 실제 스크린샷만 추가합니다.
