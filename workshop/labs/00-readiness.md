# Lab 00. 범위·권한·도구·비용

[목차](../README.md) · [다음: 원클릭 배포](01-infrastructure.md)

## 0-1. 구조와 범위

[공통 개요/실제 아키텍처](../architecture.md)를 먼저 읽습니다.
현재 검증된 full은 KRC/KRS private AKS 각 2노드, PG primary/geo-replica,
EH Standard 각 1 TU와 metadata alias, Redis/Search 양 리전, 단일 RA-GRS/ACR입니다.
TM Priority이며 99:1이 아닙니다. Storage/PG/EH의 DR 방식은 서로 다릅니다.

팀별 테스트 구독, **소문자로 시작하는 3~12자 prefix**, 승인 CIDR,
단일 오퍼레이터, 종료일과 비용/보관/삭제 담당자를 정합니다.
운영 데이터/암호·실제 리전 장애 주입은 금지합니다.
lite는 별도 승인하며 제외한 EH/Redis/Search를 full 검증으로 제출하지 않습니다.

## 0-2. 위치와 도구

| 위치 | 작업 |
|---|---|
| 오퍼레이터 PowerShell 7.2+ | 원본 도구 추출, SecureString 입력, 단일 배포 명령 |
| 전달본 source의 Bash 4+/Git Bash | 조회·평시·DR·정리 스크립트 |
| private AKS Pod/Job | 사설 PaaS 실제 데이터 접근, 샘플 생성/검증 |
| 참가자 브라우저 | 승인 CIDR의 HTTP 앱, 결과 관찰 |

오퍼레이터는 Azure CLI, Python 3.9+, jq, curl, nslookup, kubectl을 준비합니다.
제작자는 Azure CLI/Bicep과 Linux Docker 또는 명시적으로 검증한 자체 Azure mTLS 엔진이 추가로 필요합니다.
고객 PC Docker Desktop/사설 ACR 연결/새 VM·VPN·NAT·ACR Tasks pool은 필요하지 않습니다.
private AKS API를 PC에 공개하지 않고 command invoke를 사용합니다.

## 0-3. 권한과 네트워크

강사가 승인된 최소 범위·기간의 권한을 준비합니다. 다음은 자동 권한 부여 명령이 아닙니다.

- subscription deployment/서비스 생성/할당량·정책 확인과 MI/kubelet 역할 할당
- AKS command invoke, 결과 조회, 실제 서비스/로그 확인
- 임시 엔진/NSG rule과 한정 AcrPush 추가/제거. kubelet AcrPull과 앱 데이터 역할 구별
- Storage 조회/Planned failover, PG planned switchover, EH alias failover, TM 변경
- full Redis listKeys와 테스트 Secret 전달. Secret 전체를 조회/공유하지 않음

KRC/KRS SKU·실제 용량·지역 기능과 10.10.0.0/16, 10.20.0.0/16 대역 충돌을 확인합니다.
업무 PaaS/ACR public 차단을 유지하고 승인한 클라이언트 HTTP 및 **임시 CIDR+mTLS 2376**만 예외로 둡니다.
AKS의 MCR/공식 도구/Entra/ARM outbound와 사설 ACR registry/data DNS·443이 필요합니다.
현재 로컬 경로는 cloud Automation public-network 예외나 공개 GitHub assets를 전제로 하지 않습니다.

## 0-4. 비용·시간·증거

알려진 full 비용 소계는 약 **USD 1,615.41/월/환경**(2026-10-28 조회)이며 별도 사용량/빌드가 추가됩니다.
로컬 경로는 구독 예산을 만들지 않으며 expiry는 자동 삭제가 아닙니다.
새 배포 한 번의 49분 관측을 보장값으로 쓰지 않습니다. 전날 준비를 권장합니다.
Storage planned 각 전환은 수 시간도 허용합니다.
EH 이전 이벤트 보존/replay·consumer restart 계획을 별도 승인합니다.

## 완료 게이트

- [ ] 대상·권한·CIDR·비용·보관/삭제·도구 승인
- [ ] full 범위/제외 검증과 데이터 보존 계획 확인
- [ ] 배포/평시 성공과 실제 DR 미실행을 구별
