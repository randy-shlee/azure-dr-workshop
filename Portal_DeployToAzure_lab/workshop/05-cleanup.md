# 05. 리소스 정리와 종료

[이전](04-dr.md) · [목차](README.md)

## 1. 삭제 또는 보관 결정

UUID·UTC·역할·이미지 식별자와 오류를 승인된 저장소에 보관합니다.
암호·키·Secret YAML·인증서·토큰은 포함하지 않습니다.
보관한다면 환경 소유자·기한·추가 비용·종료 담당자를 명시합니다.
탭 닫기, 배포 이력 삭제, expiry 태그, AKS/PG 중지는 전체 과금 종료가 아닙니다.

## 2. 삭제 대상 확인

**실행 위치: config를 복원한 Bash 터미널, 저장소 루트.**

```bash
az account show --query '{subscription:name,id:id}' -o table
jq '{prefix,primaryResourceGroup,secondaryResourceGroup,globalResourceGroup,
     bootstrapRole:.bootstrap.operatorRoleId}' "$CONFIG_FILE"
bash scripts/eh-georecovery.sh status
```

이번 실습의 정확한 3 RG와 2 AKS managed RG, 데이터 폐기 승인 여부를 대조합니다.
다른 환경·공유 namespace·감사 보관 대상이 포함되면 중단합니다.
포털 경로는 Automation과 구독 custom bootstrap role도 만들므로 RG 밖 역할까지 확인해야 합니다.

## 3. EH pairing 확인

포털에서 현재 EH Primary namespace의 **Geo-recovery → alias**를 확인합니다.
양 namespace 모두 폐기 대상인데 아직 paired이면 **Break pairing**을 수행한 뒤 RG를 삭제합니다.
fail-forward로 이미 끊겼다면 다시 연결하거나 역전환하지 않습니다.
상대 namespace가 보관/공유 대상이면 삭제를 진행하지 않습니다.

## 4. 승인된 환경 삭제

```bash
unset CONFIRM CONFIRM_BUDGET CONFIRM_BOOTSTRAP_ROLE
bash scripts/destroy.sh
```

스크립트가 표시하는 구독과 정확한 RG 목록을 읽고 요청하는 확인 문자열을 입력합니다.
bootstrap custom role 확인 프롬프트도 대상 이름을 대조합니다.
이 포털 템플릿은 예산을 만들지 않으므로 다른 환경의 budget 삭제를 요구한다면 config부터 다시 확인합니다.
삭제에는 시간이 걸립니다. 중복 실행하거나 wildcard로 다른 prefix까지 삭제하지 않습니다.

포털에서 직접 RG만 삭제했다면 구독의 **액세스 제어(IAM) → 역할**에서 출력에 기록한
`<prefix>-workshop-bootstrap` 역할과 남은 할당을 확인하고, 이 환경 전용인 경우에만 정리합니다.
공유 역할을 이름 유사성만으로 삭제하지 않습니다.

## 5. 종료 확인

포털에서 정확한 3 RG와 2 managed RG가 없어졌는지, custom role 잔여물과 실패 리소스가 없는지 확인합니다.
`MetadataDRCannotDeleteWhenAliasPresentConflict`이면 승인된 양 EH의 pairing 상태를 다시 확인합니다.
권한·잠금·정책 오류나 목록을 조회할 수 없는 상태는 삭제 완료가 아닙니다.
실습에 사용한 별도 관리용 VM/Cloud Shell 저장소의 비용·보관 여부도 따로 결정합니다.

구독 배포 이력과 감사 기록은 이 삭제 스크립트가 제거하지 않습니다.
실제 삭제 또는 명시적인 유료 보관 결정, 남은 오류, 다음 날 비용 확인 책임까지 기록하면 종료입니다.