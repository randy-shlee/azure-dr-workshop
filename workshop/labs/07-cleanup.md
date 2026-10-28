# Lab 07. 결과 정리와 과금 종료 확인

[이전](06-drill.md) · [목차](../README.md)

**완료 기준은 삭제 명령 실행이 아니라 실제 리소스 정리 확인**입니다.
사용 중인 환경이라면 강사/소유자 승인 없이 중지·삭제하지 않습니다.

## 7-1. 비밀 없는 증거와 회고

팀 STATE_DIR의 observations.csv, drill CSV, 비용 견적, 앱 이미지 태그/digest,
필요한 스크린샷만 승인된 고객 저장소에 보관합니다.
Secret YAML, 비밀번호/키, Docker 인증 파일, 토큰, 디버그 로그는 제외합니다.
CSV는 고객 환경 정보를 포함하므로 교육 외부에 공개하지 않습니다.

질문:

1. TM 안내와 응답 리전의 변화 시각은 왜 다른가?
2. health 정상인데 실제 쓰기가 실패할 수 있는 이유는?
3. PG/EH, Redis, Search, Storage의 DR 방식은 어떻게 다른가?
4. TTL 0과 Last Sync Time이 각각 보장하지 않는 것은?
5. 중지와 삭제 중 무엇이 실제 비용을 제거하는가?

## 7-2. 장기 보관 승인이 없다면 삭제 권장

앞 Lab의 **원복 및 프로브 복구**를 확인합니다.

```bash
# 이미 원복한 환경의 기본 프로브/역할을 확인하는 단계
bash scripts/drill/00-precheck.sh
```

상태가 비정상이라도 자원 삭제는 소유자 판단으로 할 수 있지만, 이를 DR 원복 성공으로
기록하면 안 됩니다. 먼저 실제 상태와 미완료 항목을 남깁니다.

### 다음 수업을 위해 잠시 유지하는 경우만 pause

부트스트랩/샘플 Job 실행 중 중지하면 timeout/부분 업로드가 남을 수 있습니다.
강사는 실제 작업 상태와 보관/재시도 계획을 먼저 확인합니다.

```bash
bash scripts/pause.sh
```

`PAUSE <prefix>` 승인 후 AKS stop, 현재 PG primary → replica stop을 시도합니다.
PG 토폴로지에서 stop을 거절하면 스크립트가 실패하고 AKS만 이미 멈췄을 수 있습니다.
이를 전체 중지 성공으로 기록하지 말고 각 서버 상태를 확인하세요.
PG는 7일 후 자동 시작할 수 있습니다.

**EH/Redis/Search/ACR/Storage/PE/IP/TM/디스크는 계속 과금**됩니다.
보관 기한과 비용 책임자가 없는 상태로 pause를 종료 조치라고 제출하지 않습니다.
재개는 아래 명령 후 평시 precheck입니다.

```bash
# 승인된 다음 실습 재개 시에만
bash scripts/resume.sh
bash scripts/drill/00-precheck.sh
```

### 워크숍 종료: 삭제 전 정확한 대상 기록

```bash
RG_KRC="$(cfg '.primaryResourceGroup')"
RG_KRS="$(cfg '.secondaryResourceGroup')"
RG_GLOBAL="$(cfg '.globalResourceGroup')"
BUDGET_NAME="$(cfg '.budgetName')"
MANAGED_KRC="$(az aks show -g "$RG_KRC" -n "$(cfg '.primary.aks.name')" --query nodeResourceGroup -o tsv)"
MANAGED_KRS="$(az aks show -g "$RG_KRS" -n "$(cfg '.secondary.aks.name')" --query nodeResourceGroup -o tsv)"
printf 'subscription=%s\nRGs=%s %s %s\nmanaged=%s %s\nbudget=%s\n' \
  "$SUBSCRIPTION_ID" "$RG_KRC" "$RG_KRS" "$RG_GLOBAL" "$MANAGED_KRC" "$MANAGED_KRS" "$BUDGET_NAME"
```

대상이 팀의 `rg-<prefix>-krc/krs/global` 및 해당 AKS managed RG인지 확인합니다.
공유 빌드 네트워크나 다른 팀 RG는 삭제 대상이 아닙니다.

## 7-3. 승인 후 3개 RG + 구독 예산/부트스트랩 역할 삭제 — 파괴적

```bash
unset CONFIRM CONFIRM_BUDGET CONFIRM_BOOTSTRAP_ROLE
REQUIRE_OWNER_TAG=true bash scripts/destroy.sh
```

스크립트가 요구하는 확인을 각각 입력합니다.

- `DELETE <subscription> <primaryRG> <secondaryRG> <globalRG>`
- `DELETE BUDGET <budgetName>`
- 포털 부트스트랩 사용 시 `DELETE BOOTSTRAP ROLE <prefix>-workshop-bootstrap`

실제 3개 RG 이름/owner와 custom role의 구독/정확한 이름을 검사합니다.
삭제 완료 대기 후 구독 범위 예산과 부트스트랩 custom role도 삭제합니다.
Automation/암호화 설정 asset/부트스트랩 MI는 global RG와 함께 삭제됩니다.
삭제된 RG 안의 AKS가 관리하는 노드 RG도 정리되어야 합니다.
성공 후 CONFIG_FILE이 제거되므로, 이후 `load_config`를 다시 호출해 삭제된 환경을
재생성/복구하려 하지 않습니다. 위에서 저장한 변수로 확인합니다.

```bash
for group in "$RG_KRC" "$RG_KRS" "$RG_GLOBAL" "$MANAGED_KRC" "$MANAGED_KRS"; do
  printf '%s: ' "$group"
  az group exists --name "$group"
done
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Consumption/budgets?api-version=2026-06-01" \
  --query "value[?name=='$BUDGET_NAME'].name" -o json
unset PG_ADMIN_PASSWORD PG_PASSWORD REDIS_KEY_KRC REDIS_KEY_KRS
```

기대는 각 RG false와 해당 예산 목록 `[]`입니다. 포털 경로는
`az role definition list --name "$PREFIX-workshop-bootstrap" -o json`도 `[]`인지 확인합니다.
권한/통신 오류를 리소스가 없다는 증거로 해석하지 마세요.
잠금/정책/서비스 삭제 실패가 있으면 소유자가 확인할 때까지 정리 미완료입니다.
배포 이력과 승인된 감사 로그는 자동 삭제하지 않습니다.
비용 포털 반영은 지연될 수 있으므로 당일과 다음 날 강사가 재확인합니다.

본 기본 경로는 ACR Tasks pool을 만들지 않습니다. GitHub Release와 강사 로컬
이미지/아카이브는 Azure 삭제와 별개이므로 보관·공개 파기 책임을 인계합니다.

## 완료 게이트

- [ ] 결과/UTC/이미지 태그를 비밀 없이 보관, 실패/제외 범위 명시
- [ ] 프로브와 backend 원복 상태 기록
- [ ] 실제 RG/AKS managed RG/예산/부트스트랩 역할 삭제 확인 또는 보관 비용 승인
- [ ] 남은 잠금·실패·과금에 대한 담당자/기한 확인
- [ ] 강사 최종 서명/확인으로 워크숍 종료
