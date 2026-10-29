# Lab 07. 결과·보관·실제 삭제

[이전](06-drill.md) · [목차](../README.md)

## 7-1. 결과와 보관 승인

실행/미실행/부분 실패, 실제 역할과 UUID/UTC, 이미지 식별자, 관측 CSV/스크린샷을 보관합니다.
Secret/암호/Redis 키/인증서/kubeconfig/토큰/Authorization 헤더는 제출하지 않습니다.
실제 DR 미실행을 배포 성공으로 대신하지 않습니다.

보관할 환경은 **소유자·기한·추가 비용·종료 담당자**를 적습니다.
`drws1028c`는 승인대로 보관 중이므로 정리 예시를 그대로 실행해 지우지 않습니다.
expiry는 자동 삭제가 아닙니다. 일시 중지는 과금 종료가 아닙니다.

## 7-2. 삭제 전 역할·대상 기록

승인된 **폐기 대상**에서만 실행합니다. [실제 config](01-infrastructure.md#새-터미널에서-복원)를 확인합니다.

```bash
RG_KRC="$(cfg '.primaryResourceGroup')"
RG_KRS="$(cfg '.secondaryResourceGroup')"
RG_GLOBAL="$(cfg '.globalResourceGroup')"
MANAGED_KRC="$(az aks show -g "$RG_KRC" -n "$(cfg '.primary.aks.name')" --query nodeResourceGroup -o tsv)"
MANAGED_KRS="$(az aks show -g "$RG_KRS" -n "$(cfg '.secondary.aks.name')" --query nodeResourceGroup -o tsv)"
printf 'subscription=%s\nRGs=%s %s %s\nmanaged=%s %s\n' \
  "$SUBSCRIPTION_ID" "$RG_KRC" "$RG_KRS" "$RG_GLOBAL" "$MANAGED_KRC" "$MANAGED_KRS"
bash scripts/eh-georecovery.sh status
```

세 RG는 정확히 `rg-<prefix>-krc/krs/global`이고 managed RG는 실제 AKS outputs여야 합니다.
다른 팀/공유 자원은 삭제하지 않습니다. 폐기 전 필요한 EH 이벤트의 보존/replay를 승인받습니다.
lite는 EH status를 제외하며 전체 full 성공이라고 적지 않습니다.

### EH pairing 선행 작업

아직 Primary/Secondary로 paired이면 양 namespace가 모두 **이번 폐기 대상**인지 확인하고,
현재 Primary의 **Geo-recovery → alias → Break pairing**을 수행합니다.
공유/보관할 상대가 연결되어 있으면 중단합니다.
이미 fail-forward 후 연결이 끊겼다면 역전환하지 않습니다.

pairing을 남겨 두면 `MetadataDRCannotDeleteWhenAliasPresentConflict`로 EH/RG 삭제가 실패할 수 있습니다.
`destroy.sh`는 pairing을 자동 해제하지 않으므로 **이 작업부터** 마칩니다.
해제는 환경 폐기 절차이지 DR failover/failback 성공 증거가 아닙니다.

## 7-3. 승인 후 삭제 — 파괴적

```bash
unset CONFIRM CONFIRM_BUDGET CONFIRM_BOOTSTRAP_ROLE
REQUIRE_OWNER_TAG=false bash scripts/destroy.sh
```

정확한 `DELETE <subscription> <primaryRG> <secondaryRG> <globalRG>`를 승인합니다.
현재 로컬 경로의 config는 budgetName이 비어 있고 bootstrap role도 없으므로
구독 예산/Automation/custom role 삭제를 요구하지 않습니다.
다른 실제 배포 경로에 해당 항목이 있으면 스크립트가 별도 확인을 요청합니다.
owner 태그 기반 기존 CLI 환경은 소유자 검사를 임의로 끄지 말고 그 프로필의 승인을 따릅니다.

스크립트는 삭제를 기다린 후 config를 제거합니다. 그 뒤 `load_config`로 복구하려 하지 않습니다.
위에서 저장한 값으로 실제 부재를 확인합니다.

```bash
for group in "$RG_KRC" "$RG_KRS" "$RG_GLOBAL" "$MANAGED_KRC" "$MANAGED_KRS"; do
  printf '%s: ' "$group"
  az group exists --name "$group"
done
```

모두 `false`가 기대값입니다. 권한/통신 오류를 부재로 판단하지 않습니다.
정확한 실패 RG/남은 EH/managed RG를 진단한 후 승인 대상만 재시도합니다.
구독 전체/이름 wildcard 삭제나 남은 managed RG의 무작정 직접 삭제는 금지합니다.
정상 config가 없는 실패 배포는 [문제 해결](../troubleshooting.md#실패-배포에-config가-없는-경우)을 따릅니다.

## 7-4. 잠시 중지하는 경우만

별도 승인 시 `pause.sh`/`resume.sh`가 있지만 기본 종료는 삭제 또는 명시적 보관입니다.
AKS/PG만 멈춰도 EH/Redis/Search/Storage/ACR/PE/IP/디스크는 계속 과금됩니다.
PG는 7일 후 자동 시작할 수 있고 stop이 거절되면 부분 중지일 수 있습니다.
활성 업로드/부트스트랩 중에 중지하지 않으며 재개 후 실제 상태를 재확인합니다.

## 완료 게이트

- [ ] 필요한 비밀 없는 증거와 실패/미실행 범위 보관
- [ ] 실제 RG/managed RG 부재 또는 소유자·기한·비용이 명시된 보관
- [ ] 잔여 잠금/정책/서비스 삭제 오류와 다음 날 실제 비용 확인 책임 인계
