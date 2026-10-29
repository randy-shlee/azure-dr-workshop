# 강사용 준비와 운영

[참가자 과정](README.md) · [전체 아키텍처](../workshop/architecture.md) · [고급 과정](../workshop/README.md)

## 1. 수업 전 게이트

현재 기준은 **v1.0.7 full / 로컬 단일 명령**입니다.
`drws1028c`의 전체 자동 배포/앱/10 GB/복제/읽기 실증은 완료했고 실제 DR는 미실행입니다.
[검증 보고서](../workshop/releases/v1.0.7-validation.md)와 이번 팀의 새 검증 결과를 구별합니다.

- 테스트 구독/리전 용량·권한, 새 prefix, 실제 출구 CIDR, 비용/삭제 담당자 승인.
- PowerShell 7.2+, Azure CLI, Git Bash(Bash 4+), Python 3.9+, jq, curl, nslookup, kubectl.
- 참가자 PC에는 브라우저만. private AKS/PaaS를 PC에 공개하지 않음.
- 원본 assets SHA와 10 GB 계약 확인. 배포 중 임시 mTLS Docker 2376/새 push grant의 정리 승인.
- PG 암호는 SecureString으로 전달. 파일/채팅/명령행 평문/패키지에 넣지 않음.
- EH 이벤트 보존/consumer restart·replay와 수 시간 가능한 Storage 전환을 별도 승인.

배포는 [한 명령 안내](../workshop/local-package.md#one-command-to-deploy)를 그대로 사용합니다.
최종 전달 ZIP의 원본 도구는 `tools`, 운영 코드와 문서는 `source`에 둡니다.
공개 저장소를 새로 clone해 아직 게시하지 않은 수정본을 받았다고 가정하지 않습니다.

## 2. 오퍼레이터 터미널 한 번 준비

배포 완료 후 **전달 ZIP의 source 폴더를 VS Code에서 열고 Git Bash 터미널**을 사용합니다.
아래에서 실제 구독/prefix로 바꿉니다. `tools`와 `source`는 전달 ZIP 루트의 형제 폴더입니다.
이미 다른 위치에 추출했다면 `CONFIG_FILE`을 실제 성공 작업의 config로 지정합니다.

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
jq '{prefix,primaryResourceGroup,secondaryResourceGroup,globalResourceGroup,features,sampleData,trafficManager}' "$CONFIG_FILE"
```

`jq` 실패 시 진행하지 않습니다. 선택한 config가 없으면 `load_config`가 다른 배포 outputs를
찾아오도록 맡기지 않습니다. 구독/prefix를 눈으로도 확인합니다.
새 터미널은 같은 네 환경 변수와 `source scripts/common.sh; load_config`를 복원합니다.
암호/Redis 키는 이 파일이나 환경 복원 메모에 넣지 않습니다.

## 3. 준비와 평시

1. `tools\.state\deployments\<prefix>\deployment-status.json`: `Complete`.
2. `sampleData.skip=false`, 양 앱 Ready/같은 이미지/Service IP: [Lab 04](../workshop/labs/04-application.md).
3. TM 양 Enabled/Online, 지역 앱 각각 KRC/KRS, TM KRC/KRC.
4. 자동 Job 로그의 `UPLOAD_MANIFEST`, `SECONDARY_READ_VERIFIED`:
   [Lab 02](../workshop/labs/02-data.md). 없는 bootstrap ConfigMap은 현재 게이트가 아님.
5. [앱 테스트](03-test.md): 모든 활성 서비스, exact 10 GB와 실제 읽기/fence.
   버튼 재개로 manifest가 갱신됐다면 복제를 다시 확인.
6. 첫 drill만 `bash scripts/drill/00-precheck.sh`.

일반 UI의 EH read는 metadata, Search read는 count입니다. 정확한 이벤트 본문 소비나
특정 Search 문서 대조를 새로 수행하지 않았다면 기존 보고서의 강한 검증을 재수행했다고 쓰지 않습니다.
`test-app.sh`도 `replication_complete=true`를 대신 보장하지 않으므로 별도로 확인합니다.

## 4. 전환·원복과 실패 대응

[참가자 DR](04-dr.md)와 [정확한 관리/데이터 검증](../workshop/labs/06-drill.md)을 함께 사용합니다.

| 단계 | 실제 스크립트 계약 |
|---|---|
| 전환 | `10-failover.sh`: Storage → EH → PG → TM → DNS/health/data |
| 원복 | `20-failback.sh`: Storage → PG → EH wait active → TM → DNS/health/data |
| 원복 후 EH | KRS 유지. 이전 KRC로 failback/자동 re-pair하지 않음 |
| 데이터 gate | `dr_verify_data`: Blob/PG 동일 ID, EH send/metadata. Redis/Search 실제 결과는 추가 확인 |
| 프로브 복구 | `99-restore.sh`: 기본 30초/3회/10초, TTL 60. backend 역할 변경 아님 |

fast 설정은 기본 실습에서 제외합니다. 별도 승인한 `05-fast-settings.sh`는 추가 비용과
TTL 0의 한계를 설명하고 반드시 99번으로 복구합니다.
부분 실패 시 CSV/관리 역할/실제 데이터/라우팅부터 확인하고 반대 명령이나 전체 Bicep을 덮어 실행하지 않습니다.
첫 EH fail-forward 후에는 `wait krc`/첫 baseline을 반복하지 않습니다.

## 5. 정리와 종료

[참가자 정리](05-cleanup.md)와 [상세 삭제](../workshop/labs/07-cleanup.md)를 사용합니다.
paired EH는 전체 폐기 전에 정확한 두 대상을 확인하고 Break pairing을 먼저 수행합니다.
소유자 승인 없이 `drws1028a`/`drws1028c` 등 공유 검증 환경을 지우지 않습니다.
현재 로컬 경로의 Automation/예산/custom bootstrap role은 없으므로 삭제를 요구하지 않습니다.

종료 인계는 **실제 삭제 또는 기한/소유자/비용이 정해진 보관**, 남은 오류와 다음 날 비용 확인까지입니다.
공개 게시/실제 DR 미실행을 완료로 바꾸지 않습니다.
