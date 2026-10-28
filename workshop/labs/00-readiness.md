# Lab 00. 사전 준비와 안전 게이트

[목차](../README.md) · 다음: [인프라 배포](01-infrastructure.md)

## 0-1. 팀과 범위 정하기

팀별 prefix(예: drws01a7), 테스트 구독, 만료일, 허용 공인 CIDR,
예산 승인자, 훈련 오퍼레이터를 정합니다. 공유 구독이라면 강사가 quota/비용을
팀 수만큼 합산합니다. prefix는 **3~12자 소문자 영숫자**로 선택하고,
TM 공용 DNS 등 전역 이름 충돌을 피하도록 조직/팀 식별자와 임의 숫자를 조합하세요.

강사가 필요한 권한을 최소 범위·기간으로 준비합니다.

- subscription deployment, 각 서비스 생성, provider 등록/할당량 확인
- 앱/샘플 MI 및 kubelet 역할 할당
- AKS command invoke/결과 조회
- Storage ARM 조회, PostgreSQL planned switchover, TM endpoint 변경
- full 프로필은 Redis database listKeys, EH geo promotion 권한
- bootstrap custom role 생성/할당/삭제와 Automation job 상태 조회
- bootstrap MI만 해당 ACR의 **AcrPush**; admin 사용자/키를 활성화하지 않음

이 목록은 권한 자동 부여 명령이 아닙니다. 구독 Owner를 모든 참가자에게
일괄 부여하는 대신 조직의 승인된 역할 조합을 강사가 확인하세요.

## 0-2. 실행 위치를 구별하기

| 위치 | 수행할 작업 | 필요한 연결 |
|---|---|---|
| 강사 로컬 PC | 교육 전 Docker build/save, ARM JSON 패키징 | Docker Hub/PyPI, 공개 도구 SHA256 조회; ACR 연결 불필요 |
| 고객 포털/제어 단말 | 포털 Create, 이후 운영/훈련/브라우저 | ARM/Entra, 허용 공인 CIDR → 앱 HTTP |
| Automation cloud job | KRC runCommand와 앱 준비 상태 확인 | ARM/MI; 업무 PaaS data plane에 직접 접속하지 않음 |
| AKS Pod/Job | GitHub 아카이브 → private ACR, 앱, 샘플 업로드 | GitHub/MCR/도구 다운로드/ARM/Entra outbound와 지역별 DNS/PE |

private AKS의 kubeconfig를 PC에 내려 직접 kubectl 접속하지 않습니다.
새 VM/VPN/게이트웨이를 이 실습에서 만들지 않습니다.
고객 PC에 Docker나 ACR 사설 연결이 없어도 포털 자동 배포가 진행됩니다.

## 0-3. 도구 점검

저장소 루트 Bash에서 실행합니다.

```bash
bash --version
az version
az bicep version
python --version
jq --version
curl --version
command -v nslookup
kubectl version --client
az login
```

위는 배포 후 CLI 실습 도구이며 포털 배포 자체의 필수 도구는 아닙니다.
강사 패키징 PC에만 Docker Linux containers/amd64와 PowerShell 7.2+가 필요합니다.
Python은 운영 스크립트에 3.9+가 필요하고 앱의 target은 **3.12**입니다.
앱 로컬 테스트를 수행한다면 의존성은 가상환경에 설치합니다.
Windows에서는 팀의 `.state` 폴더에 대한 NTFS ACL도 해당 사용자/승인된 관리자만
접근하도록 확인합니다. Git Bash의 umask만으로 Windows ACL이 제한된다고 가정하지 않습니다.

## 0-4. 네트워크와 지역 게이트

강사가 다음을 사전에 확인합니다.

- koreacentral/koreasouth의 D4s_v5 할당량과 AKS 시스템 풀 제한
- PostgreSQL GP cross-region replica/virtual endpoint/PE, EH Premium geo,
  Managed Redis B3 active geo, Search Basic 지원과 구독 제한
- KRC/KRS VNet 대역 10.10.0.0/16, 10.20.0.0/16과 기존 네트워크 대역 충돌 없음
- 고객 PC의 실제 인터넷 출구 CIDR. 회사 proxy/VPN/브라우저 출구가 다를 수 있음
- 업무 PaaS public 차단 유지, Automation 계정 하나의 public networking 예외 승인
- AKS outbound의 GitHub assets/MCR/도구/Entra/ARM 접근과 ACR PE DNS/443

SKU 미지원이면 승인 없이 상위 SKU/다른 리전으로 바꾸지 않습니다.
EH/Redis/Search만 끄는 절감 프로필은 가능하지만 해당 서비스 실습은 제외합니다.
AKS/PG/부트스트랩 경로가 준비되지 않으면 배포 실습 자체를 보류합니다.

## 0-5. 비용/시간 승인

full은 EH/Redis/Search를 모두 켜고 약 10GiB 샘플을 사용합니다.
선택 기능 App Gateway/Resolver/Alerts/ACR geo는 끕니다.
lite는 EH/Redis/Search를 모두 끄며 PG/TM/Storage 중심으로만 수행합니다.
**lite도 무료가 아니며 full의 DR 결과를 대신하지 않습니다.**

공개 포털 프로필은 owner 입력과 구독 예산 생성을 생략합니다.
비용 승인자·정리 담당자는 운영상 별도로 정하며, 비용 검토를 생략하지 않습니다.
기존 CLI 프로필의 예산은 구독 청구 통화이고 Retail 견적은 USD입니다.
서로 다른 통화 금액을 직접 비교하지 마세요. 생성·복제·삭제 대기 중에도 과금됩니다.

## 완료 게이트

- [ ] 강사/팀별 대상 구독·prefix·권한·CIDR 확인
- [ ] 비용과 일정 승인, 운영 데이터/자격 증명 미사용 확인
- [ ] 강사 사전 Release/해시/공개 승인 및 Automation 예외 승인
- [ ] 지역 기능/할당량/정책 사전 확인
- [ ] full/lite 선택과 제외 실습 기록
