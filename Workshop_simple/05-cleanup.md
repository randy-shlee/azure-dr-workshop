# 05. 정리하기

[이전](04-dr.md) · [목차](README.md) · [강사용 상세 확인](instructor.md#5-정리와-종료)

## 목표

실제 리소스 삭제까지 확인하고 정리 책임을 종료합니다.
참가자는 증거를 보관하고 **삭제 권한이 승인된 담당자만** 삭제합니다.

## 할 일

1. 평시/전환/원복의 UTC·결과 스크린샷을 팀의 승인된 위치에 보관합니다.
   원복이 미완료면 성공으로 바꾸지 말고 실제 상태와 담당자를 남깁니다.
2. 삭제 전에 강사가 실제 구독과 다음 대상을 확인·기록합니다.

   | 대상 | 확인 방법 |
   |---|---|
   | rg-팀prefix-krc / rg-팀prefix-krs / rg-팀prefix-global | 배포 Outputs의 세 RG와 비교 |
   | 두 AKS의 node resource group | 각 AKS Overview/Properties에서 실제 이름 기록 |
   | 팀prefix-workshop-bootstrap custom role | Outputs의 bootstrap.operatorRoleId와 구독 IAM 비교 |

3. 포털 **Resource groups → 정확한 대상 → Delete resource group**에서 세 RG를 삭제합니다.
   표시된 리소스 목록과 구독을 확인하고, 요구되는 이름을 입력합니다.
   공유/다른 팀 RG를 포함하지 않습니다.
4. 삭제 완료를 기다린 뒤 목록을 새로고침합니다. AKS 관리 RG도 함께 제거됐는지 확인합니다.
   관리 RG가 남으면 직접 무작정 지우지 말고 강사가 AKS 삭제 상태를 조사합니다.
5. 강사가 구독 **Access control (IAM) → Roles**에서 정확한 bootstrap custom role을 찾고,
   관련 리소스/역할 할당이 정리된 뒤 삭제합니다. 필요하면 강사용 정리 스크립트를 사용합니다.
   비용 포털은 반영이 지연되므로 담당자가 다음 날 다시 확인합니다.

## 정상 상태

세 RG, 두 AKS 관리 RG, 해당 bootstrap custom role이 남지 않습니다.
Automation·암호화 설정·bootstrap MI는 global RG와 함께 정리됩니다.
**포털 프로필에는 예산과 owner 태그가 없으므로 예산 삭제/owner 일치를 요구하지 않습니다.**

앱 탭을 닫거나 Deployment 이력만 삭제한 것은 리소스 삭제가 아닙니다.
AKS/PG만 중지해도 EH/Redis/Search/Storage/ACR/PE/IP 등은 계속 과금될 수 있습니다.
이 기본 과정에서는 pause를 정리 완료로 인정하지 않습니다.

## 안 되면 멈추기

잠금·정책·권한·역할 할당 때문에 실패하면 오류를 기록하고 담당자에게 넘깁니다.
삭제 권한이 없어 목록을 못 보는 것을 삭제 완료로 판단하지 않습니다.
보관 승인을 받았다면 대상·기한·잔여 비용 담당자를 기록하고 **삭제 미완료/승인된 보관**으로 구분합니다.
공유 구독의 다른 custom role/예산은 건드리지 않습니다.

## 완료 체크

- [ ] 필요한 증거 보관, 비밀번호·키·Secret 본문 미포함
- [ ] 세 RG·AKS 관리 RG·bootstrap custom role 삭제 또는 명시적 보관 승인
- [ ] 잔여 실패/비용 담당자와 다음 날 확인 일정 기록
