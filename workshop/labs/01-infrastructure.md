# Lab 01. 원클릭 배포와 실제 config 연결

[이전](00-readiness.md) · [목차](../README.md) · [다음: 샘플 검증](02-data.md)

## 1-1. 고정된 도구 한 명령

최종 ZIP을 새 디렉터리에 풀고 **ZIP 루트의 PowerShell**에서 실행합니다.
사용 중인 환경의 전체 PG/Redis 템플릿을 덮어쓰는 명령이 아닙니다.
구독/새 prefix/실제 승인 공인 IP를 바꾸고 [전체 배포 안내](../local-package.md)를 함께 봅니다.

```powershell
$release = (Get-Location).Path
Expand-Archive -LiteralPath .\deployment-tools.zip -DestinationPath .\tools
$password = Read-Host 'Test PostgreSQL password' -AsSecureString
.\tools\scripts\deploy-local-package.ps1 `
  -ReleaseDirectory $release `
  -Prefix 'mydrws01' `
  -SubscriptionId 'YOUR-SUBSCRIPTION-ID' `
  -AllowedClientCidrs 'YOUR-APPROVED-PUBLIC-IP/32' `
  -AdministratorLogin 'dradmin' `
  -AdministratorPassword $password `
  -ConfirmCreate
Remove-Variable password
```

암호를 명령행/파일에 평문으로 적지 않습니다. 첫 CIDR은 실제 배포 오퍼레이터 출구 주소입니다.
기존 팀 환경을 받았다면 명령을 재실행하지 말고 아래 완료 상태와 실제 앱만 확인합니다.

## 1-2. 자동 실행과 완료 게이트

1. 이미지/ARM/도구 SHA256과 서버 10 GB 계약 검증.
2. 세 RG 존재를 검사해 충돌 거절, cloud bootstrap=false로 새 인프라 생성.
3. 승인 CIDR+mTLS 임시 Docker 엔진으로 **원본 이미지**를 사설 ACR에 push.
4. 임시 엔진/규칙/새 grant/인증서 정리.
5. Search 초기화, 양 앱의 설정/Secret/Deployment/Service와 Ready/고정 IP/TM 확인.
6. 앱 준비 **후** CLI 10 GB 업로드/복제/KRS 실제 읽기.
7. 공개 앱의 실제 서비스 smoke 후 `phase=Complete`.

```powershell
Get-Content .\tools\.state\deployments\mydrws01\deployment-status.json
```

`ProvisioningInfrastructure`, `ImportingImage`, `ApplyingAndVerifyingApps`는 중간 상태입니다.
`Complete`가 필요하며 `Failed`/timeout은 다음 단계로 진행하지 않습니다.
`-SkipSampleData`는 샘플 검증 제외를 명시한 것이며 복제 성공이 아닙니다.
현재 경로에서 Automation Job/부트스트랩 ConfigMap이 없는 것은 정상입니다.

## 새 터미널에서 복원

이후 Bash 명령은 **전달본 source 폴더**에서 실행합니다. `tools`와 `source`는 형제 폴더입니다.
원본 tools ZIP에는 DR 전체 코드가 없으므로 tools 폴더를 DR 저장소 루트로 쓰지 않습니다.
같은 버전 코드와 **이번 성공 작업의 config**를 연결합니다.

```bash
export SUBSCRIPTION_ID='YOUR-SUBSCRIPTION-ID'
export PREFIX='mydrws01'
export STATE_DIR="$PWD/.state/$PREFIX"
export CONFIG_FILE="$PWD/../tools/.state/deployments/$PREFIX/config.json"
[[ -s "$CONFIG_FILE" ]] || { printf 'STOP: successful deployment config required\n' >&2; exit 1; }
jq -e --arg p "$PREFIX" --arg s "/subscriptions/$SUBSCRIPTION_ID/" \
  '.prefix == $p and (.primary.aks.id | startswith($s))' "$CONFIG_FILE" \
  || { printf 'STOP: subscription/prefix mismatch\n' >&2; exit 1; }
az login
az account set --subscription "$SUBSCRIPTION_ID"
source scripts/common.sh
load_config
mkdir -p "$STATE_DIR"
cp workshop/templates/observations.csv "$STATE_DIR/observations.csv"
jq '{prefix,primaryResourceGroup,secondaryResourceGroup,globalResourceGroup,sampleData,trafficManager}' "$CONFIG_FILE"
```

다른 디렉터리 배치라면 CONFIG_FILE만 실제 파일로 변경합니다.
없는 config를 `load_config`의 deployment-name 추정으로 복구하지 않습니다.
새 터미널마다 위 네 환경 변수/구독과 common.sh를 복원합니다. 비밀 값은 저장하지 않습니다.

## 선택적 포털 — 현재 과정에서 실행하지 않음

<!-- DEPLOY_BUTTON_START -->
현재 v1.0.7은 로컬 전용입니다. 승인·게시·별도 실증한 동일 버전 assets 없이는 포털 버튼을 사용하지 않습니다.
<!-- DEPLOY_BUTTON_END -->

코드에는 포털/Automation 경로가 있지만 최신 로컬 실증을 그 경로의 성공으로 주장하지 않습니다.
공개 v1.0.3은 이전 이미지/템플릿이므로 사용 금지입니다. [제작자 범위](03-build.md)를 참고합니다.

## 완료 게이트

- [ ] 실제 로컬 상태 Complete, 활성 features/skip 확인
- [ ] 이번 구독/prefix의 config, source Bash 환경 연결
- [ ] 실패 시 반복 배포/DB 삭제/forceUnlink 없이 진단
