# 02. 자동 배포 완료와 앱 접속

[이전](01-deploy.md) · [목차](README.md) · [다음: 앱 데이터](03-application.md)

## 1. 이번 배포의 설정 가져오기

**실행 위치: 환경 준비에서 선택한 Bash 터미널, 저장소 루트.** 실제 구독/prefix/포털 배포 이름으로 바꿉니다.
이 과정은 포털 배포의 출력만 읽으며 리소스를 다시 배포하지 않습니다.

```bash
export SUBSCRIPTION_ID='YOUR-SUBSCRIPTION-ID'
export PREFIX='mydrws01'
export DEPLOYMENT_NAME='EXACT-PORTAL-DEPLOYMENT-NAME'
export STATE_DIR="$PWD/.state/$PREFIX"
export CONFIG_FILE="$STATE_DIR/config.json"
az account set --subscription "$SUBSCRIPTION_ID"
source scripts/common.sh
export_config
jq -e --arg p "$PREFIX" --arg s "/subscriptions/$SUBSCRIPTION_ID/" \
  '.prefix == $p and (.primary.aks.id | startswith($s))' "$CONFIG_FILE" \
  || { printf 'STOP: subscription/prefix mismatch\n' >&2; exit 1; }
load_config
jq '{prefix,primaryResourceGroup,secondaryResourceGroup,globalResourceGroup,trafficManager}' "$CONFIG_FILE"
```

`true`와 정확한 RG가 표시되는지 확인합니다. 오류면 다음으로 진행하지 않습니다.
다른 환경의 config를 복사하지 않습니다. `export_config`는 지정한 포털 배포 이름에서 명시적으로 가져옵니다.
`config.json`은 작업 환경에서 보호하고 암호·Redis 키·토큰을 추가하지 않습니다.

새 터미널에서는 저장소 루트로 이동한 뒤 이 블록의 환경 변수와 구독 선택을 복원합니다.
config가 있으면 `source scripts/common.sh`와 `load_config`를 실행하고 같은 구독/prefix를 대조합니다.
Cloud Shell에서 VM으로 이동했다면 해당 VM에서 같은 태그를 받아 이 절차로 다시 가져옵니다.

## 2. 앱 자동 배포 관찰

```bash
bash scripts/bootstrap-status.sh --wait-app
```

Automation과 KRC bootstrap 상태를 관찰합니다. 앱 준비가 되면 종료하지만,
**`ApplicationReady`는 샘플 복제 완료가 아닙니다.** 관찰 제한시간 초과도 Azure 작업 중단을 뜻하지 않습니다.

포털에서는 global RG의 `aa-<prefix>-bootstrap` → **작업**에서 상태를 확인합니다.
작업 ID는 ARM 출력 `config.bootstrap.jobId`와 대조합니다. 오류 시 같은 runbook을 중복 시작하지 않습니다.

아래는 Bash에서 실행하되, 실제 kubectl은 사설 AKS의 Run command 환경에서 동작합니다.

```bash
aks_run primary 'kubectl -n drtest get configmap workshop-bootstrap-status -o jsonpath="{.data.phase}"'
aks_run primary 'kubectl -n drtest get pods,services'
aks_run secondary 'kubectl -n drtest get pods,services'
```

양 앱 Pod가 Ready이고 Service에 외부 IP가 있는지 확인합니다. 샘플까지 완료되면 phase가 `Complete`가 됩니다.
전체 Secret YAML·암호화 Automation 변수·키·토큰을 출력하지 않습니다.

## 3. 앱 주소 열기

```bash
jq -r '"TM: http://" + .trafficManager.fqdn,
       "KRC: http://" + .primary.publicIp.address,
       "KRS: http://" + .secondary.publicIp.address' "$CONFIG_FILE"
tm_assert_online
```

PC 브라우저에서 세 주소를 각각 엽니다. TM은 평시 KRC, 각 지역 주소는 해당 지역 앱이어야 합니다.
TM 양 endpoint는 Enabled/Online이어야 합니다. 앱 화면의 응답 지역과 backend 지역도 기록합니다.

접속이 안 되면 브라우저의 출구 IP가 입력한 CIDR에 포함되는지 먼저 확인합니다.
앱 화면은 열리지만 Bash의 curl만 실패하면 터미널 출구 IP도 확인합니다.
Cloud Shell에서 kubectl 직접 접속 실패는 AKS 공개 전환으로 해결하지 않고 위 Run command 경로를 사용합니다.

## 완료 조건

Automation 정상 완료, 양 앱 Ready/접속, TM 양 Online, bootstrap `Complete`를 확인했습니다.
다음 단계에서 앱의 실제 데이터와 샘플 복제를 확인합니다.

[다음: 앱 데이터](03-application.md)