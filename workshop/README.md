# Azure DR 워크숍 — 고급 과정

[간단 과정](../Workshop_simple/README.md)과 **같은 배포본·같은 DR 스크립트**를 사용합니다.
이 과정은 운영자가 이미지/MI/Private Link/복제/관리 역할과 실제 데이터 증거까지 확인합니다.

## 공통 아키텍처와 현재 기준

![공식 Azure 아이콘을 사용한 실제 full 배포 구성](assets/architecture.svg)

[개요·리소스 배치·서비스별 DR 의미](architecture.md)를 먼저 읽습니다.
`drws1028c`의 v1.0.7 단일 명령 전체 배포, 10 GB 샘플/복제/실제 읽기,
양 앱과 5개 서비스의 실제 데이터·TM Online은 [실증 완료](releases/v1.0.7-validation.md)했습니다.
**실제 failover/failback·99:1은 실행하지 않았습니다.**

현재 one-click은 [로컬 패키지 한 명령](local-package.md)입니다.
공개 v1.0.3 버튼은 사용하지 않으며 cloud Automation 경로는 기본 과정에서 제외합니다.
원본 이미지/ARM/도구를 바꾸지 않는 문서 개정과 새 앱 릴리스 제작도 구별합니다.

## 읽고 실행하는 순서

| 순서 | 문서 | 완료 증거 |
|---|---|---|
| 강사 사전 | [03. 이미지·패키지 읽기/제작](labs/03-build.md) | 기존 v1.0.7 사용 또는 새 소스의 새 버전 제작·별도 실증 |
| 00 | [준비·권한·비용](labs/00-readiness.md) | 구독/CIDR/범위/담당자 승인 |
| 01 | [원클릭 배포와 환경 연결](labs/01-infrastructure.md) | 고정 도구 한 명령 `Complete`, 실제 config |
| 02 | [10 GB·복제·Job 검증](labs/02-data.md) | 정확한 파일/용량, manifest, KRS 실제 읽기/fence |
| 03 | [패키지·코드 해설](labs/03-build.md) | 재빌드 없이 아카이브/배포 이미지의 관계 이해 |
| 04 | [앱·MI·사설 연결](labs/04-application.md) | 양 Pod Ready·이미지·IP·TM, 비밀을 출력하지 않는 확인 |
| 05 | [평시 API·데이터 baseline](labs/05-baseline.md) | 실제 쓰기/읽기, 첫 drill 사전 역할 |
| 06 | [승인된 전환·원복](labs/06-drill.md) | 단계별 역할/UUID/UTC, EH KRS 유지 |
| 07 | [정리·보관·과금](labs/07-cleanup.md) | 실제 삭제 또는 명시적 보관 승인 |

Lab 03은 강사에게는 **배포 전 선택 단계**, 참가자에게는 이미 배포한 코드의 해설입니다.
정상 배포 뒤 수동 이미지/Secret/샘플 준비를 다시 실행하지 않습니다.
전체 환경의 소유자·단일 오퍼레이터를 정하고, 전날 배포/복제 준비를 권장합니다.

## 공통 실행 규칙

- 배포는 **PowerShell 7.2+**, 운영/DR는 **source 폴더의 Bash 4+ / Windows Git Bash**입니다.
  터미널 종류를 섞지 않습니다.
- 최종 ZIP 루트의 원본 도구는 `tools`, 전체 문서/운영 코드는 `source`에 둡니다.
  Bash의 `CONFIG_FILE`은 **실제 성공한 tools 작업의 config**를 가리켜야 합니다.
  [복원 절차](labs/01-infrastructure.md#새-터미널에서-복원)를 따릅니다.
- 없는 config를 다른 deployment 이름으로 자동 추정하지 않습니다. 구독/prefix를 검증합니다.
- `CONFIRM`을 전역 export하지 않습니다. 배포/전환/원복/삭제 승인을 각각 확인합니다.
- private AKS는 command invoke, 업무 PaaS는 Pod의 Private Link 경로로 확인합니다.
  Secret/env 전체, 암호·키·인증서·Authorization 헤더를 제출하지 않습니다.

## DR에서 다른 점

실제 전환은 **Storage → EH → PG → TM**, 원복은
**Storage → PG → EH active 확인 → TM**입니다.
EH는 metadata-only/fail-forward여서 앱 KRC 원복 후에도 KRS에 남습니다.
Storage/PG primary와 PE 위치/브라우저 응답 리전은 서로 다른 관측입니다.
Redis active geo와 Search 독립 인덱스를 PG식 승격으로 설명하지 않습니다.
전환 후 첫 drill baseline/`-secondary` 복제 probe를 재사용하지 않습니다.

## 비용과 판정

full은 AKS D4s_v5 2노드/리전, PG 2서버, EH Standard/Redis/Search 양 리전,
단일 RA-GRS/ACR과 PE 17개입니다. 알려진 소계 약 **USD 1,615.41/월/환경**에
별도 사용량/빌드 비용이 추가되며, expiry와 예산은 자동 삭제/과금 상한이 아닙니다.
Storage 각 planned 작업은 수 시간도 허용하며 49분 배포 실증을 소요 시간 보장으로 해석하지 않습니다.

| 판정 | 기준 |
|---|---|
| 배포/평시 통과 | 전체 자동 단계 + 실제 양 앱/샘플/fence/데이터 확인 |
| DR 수행 통과 | 승인한 전환/원복을 실제로 실행하고 모든 역할/데이터/UTC 확인 |
| 관찰/부분 수행 | 사전 환경만 관찰, lite/skip 또는 실제 전환 미실행을 명시 |
| 보류 | 연결·복제·역할·권한 오류나 정리 책임 미확정 |

[강사 일정/개입 게이트](facilitator-guide.md) · [문제 해결](troubleshooting.md) ·
[관측 CSV](templates/observations.csv)
