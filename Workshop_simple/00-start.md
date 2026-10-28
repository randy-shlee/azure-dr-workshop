# 00. 시작하기

[목차](README.md) · [다음: 배포하기](01-deploy.md)

## 목표

승인된 환경과 비용 범위를 확인합니다. 이미 준비된 환경을 사용할지 새로 배포할지도 정합니다.

## 할 일

1. [Azure 포털](https://portal.azure.com)에 로그인하고 강사가 지정한 구독을 확인합니다.
2. 팀별로 **prefix, 실제 브라우저의 공인 IPv4, 종료일, 정리 담당자**를 적습니다.
   prefix는 3~12자 소문자/숫자입니다. 다른 팀과 중복되지 않게 정하세요.
3. 강사에게 비용·리전 지원·권한과 Automation public-network 예외 승인을 확인받습니다.
4. 강사가 정한 full/lite 범위를 확인합니다. 임의로 SKU나 서비스를 바꾸지 않습니다.

| 프로필 | 포함 범위 | 제외 범위 |
|---|---|---|
| full: 기본 | AKS, PostgreSQL, Storage, Traffic Manager, Event Hubs, Redis, Search | 없음. 실제 지원/권한 사전 확인 필요 |
| lite: 강사 승인 시 | AKS, PostgreSQL, Storage, Traffic Manager | EH/Redis/Search 및 해당 서비스 DR 검증 |

full은 AKS 노드 총 4대와 PG 2대, 양 리전 선택 서비스 등을 사용합니다.
lite도 무료가 아닙니다. 비용은 강사가 실제 구독·프로필 기준으로 확인합니다.
참가자에게는 브라우저만 필요하며 짧은 CLI 명령용 터미널은 강사가 준비합니다.

## 정상 상태

- 내 팀의 구독·prefix·공인 IP·종료일·담당자가 정해져 있습니다.
- full/lite와 실제 배포 또는 관찰만 하는 범위가 정해져 있습니다.
- 새 배포 권한과 기존 환경 조회 권한을 구별합니다.

## 안 되면 멈추기

구독·권한·허용 IP·비용 승인이 불명확하면 **Create를 누르지 않습니다**.
다른 리전/비싼 SKU/public endpoint로 우회하지 말고 강사에게 확인합니다.

## 완료 체크

- [ ] 구독·prefix·공인 IP·종료일·정리 담당자 확인
- [ ] 비용·권한·네트워크 예외·full/lite 승인 확인
- [ ] 신규 배포인지 사전 준비 환경 관찰인지 확인
