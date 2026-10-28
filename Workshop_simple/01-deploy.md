# 01. 배포하기

[이전](00-start.md) · [목차](README.md) · [다음: 준비 확인](02-ready.md)

## 목표

기존 공개 릴리스로 인프라와 앱 자동 배포를 시작합니다. PC에서 빌드하지 않습니다.
**사전 준비 환경을 받았다면 버튼을 누르지 말고 기존 배포 이력을 확인합니다.**

## 할 일

1. 신규 배포가 승인됐다면 다음 버튼을 누릅니다.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.3%2Fworkshop%2Freleases%2Fazuredeploy.json)

사용 버전: [Azure DR workshop v1.0.3](https://github.com/randy-shlee/azure-dr-workshop/releases/tag/v1.0.3).

2. 다음 항목만 입력·확인하고, 나머지는 강사가 지정한 기본값을 유지합니다.

| 입력 항목 | 입력/확인 값 |
|---|---|
| Subscription / Deployment location | 승인된 테스트 구독 / Korea Central |
| Prefix | 팀별 고유한 3~12자 소문자/숫자 |
| Expiry | 종료 예정 ISO 날짜. 예: `2026-11-27`. 자동 삭제 아님 |
| Allowed Client Cidrs | 실제 브라우저 공인 IPv4 CIDR 배열. `["203.0.113.10/32"]`는 문서용이며 실제 IP로 교체 |
| Administrator Login / Password | 테스트 PG 계정. 암호는 최소 12자이며 강사가 서비스 암호 규칙도 확인 |

3. **Deploy Workshop Bootstrap=true**, **Sample Data Size GB=10**,
   **Small File Count=2000**, **Skip Sample Data=false**를 확인합니다.
   lite라면 강사가 Deploy Event Hubs/Redis/Ai Search와 Enable Event Hubs Geo Replication을 false로 지정합니다.
4. 강사가 실제 프로필의 비용/권한/Provider what-if를 검토했는지 확인한 뒤,
   **Review + create → Create**를 누릅니다. 이때 과금 리소스 생성이 시작됩니다.
5. **Subscriptions → 해당 구독 → Deployments**에서 실제 배포 이름과 상태를 기록합니다.
   이름을 `<prefix>-drtest`라고 추측하지 마세요. 완료 후 **Outputs → config**를 엽니다.

고급 파라미터가 더 보이는 것은 정상입니다. **Owner / Monthly Budget / Budget Start Date는 없습니다.**
기본 AKS는 리전당 D4s_v5 2노드입니다. Private ACR/PaaS 정책과 릴리스 URL/해시는 바꾸지 않습니다.

## 정상 상태

배포가 Succeeded이고 Outputs에 config가 있습니다. 이는 **앱/샘플 완료가 아니라
인프라와 자동화 시작 요청 성공**입니다. 다음 Lab에서 계속 확인합니다.

## 안 되면 멈추기

템플릿 다운로드/validation/권한/할당량 오류는 강사에게 전달합니다.
실패한 환경에 무조건 다시 Create하지 않고, 특히 DR 전환 중에는 재배포하지 않습니다.
포털 validation은 Provider what-if나 실제 리전 용량 검증을 대신하지 않습니다.

## 완료 체크

- [ ] 승인된 구독과 실제 입력값 확인
- [ ] 배포 Succeeded 또는 사전 준비된 배포 이력 확인
- [ ] 실제 배포 이름과 Outputs → config 확보
