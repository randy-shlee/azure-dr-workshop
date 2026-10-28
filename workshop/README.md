# Azure DR workshop

대상은 Azure 인프라·애플리케이션 엔지니어입니다. 제공된 인프라와 샘플 앱을
배포하고, 연결·쓰기·읽기·Storage 보조 읽기·planned 전환/원복을 직접 확인합니다.
**운영계 장애 주입, 성능, SLA, 가용성 보장 또는 실제 RTO/RPO 인증 과정은 아닙니다.**

이 폴더는 교육 자료이며 실행 코드를 복제하지 않습니다. 기존
[인프라](../infra/main.bicep), [앱](../app/main.py), [운영 스크립트](../scripts),
[전체 기술 설명](../README.md)을 사용합니다.

## 실습 시작 전 반드시 읽기

- **팀별 승인된 테스트 구독/리소스 범위만 사용**합니다. 고객 데이터·운영 암호는 금지합니다.
- 전체 기능 구성의 기존 견적 예시는 약 **USD 3,511/월**입니다.
  이는 100GiB 기본값의 과거 Retail 예시이며 오늘의 견적·실습 총액·상한이 아닙니다.
  본 과정은 데이터를 약 10GiB로 줄여도 상시 컴퓨트 비용 대부분은 남습니다.
  예산 1,000과 expiry 태그는 리소스나 과금을 자동 중지하지 않습니다.
- 리전당 AKS 시스템 노드 **D4s_v5 2대**가 현재 구현 기본값입니다.
  B 시리즈/1노드로 임의 변경하지 않습니다.
- 업무 PaaS 데이터 경로는 Private Endpoint, 앱 HTTP만 공용입니다.
  **승인된 예외는 부트스트랩 Automation 계정 하나**입니다. cloud job 실행을 위해
  public networking을 허용하되 local auth/webhook은 쓰지 않고 ARM/RBAC/MI를 사용합니다.
  업무 PaaS의 public Disabled와 ACR bypass None은 유지합니다.
- 기본 경로는 **강사 로컬 build/save → 승인 후 GitHub Release 게시 → 고객 Deploy to Azure →
  기존 AKS에서 SHA256 확인/private ACR push → 두 앱 자동 배포**입니다.
  고객 Docker/private 빌드 네트워크, ACR Tasks pool, 새 VM/VPN/NAT는 필요 없습니다.
  GitHub에는 승인된 공개 샘플만 게시하며 private Release는 현재 지원하지 않습니다.
- ARM 배포 성공, Automation의 앱 준비 확인, AKS의 샘플 복제 완료는 별개입니다.
  부트스트랩 Job의 일시적 CPU/메모리/디스크·다운로드, Automation 실행 분,
  공개 Release 보관/전송과 Azure 네트워크 비용을 추가로 고려합니다.
  요금 무료 구간을 비용 0의 보장으로 해석하지 마세요.
  기존 estimate-cost.sh 표에는 Automation 실행 분/GitHub/추가 다운로드 비용이
  포함되지 않습니다. [Automation 요금](https://azure.microsoft.com/pricing/details/automation/)과
  실제 사용 시간을 별도 검토합니다. Job은 기존 노드를 사용하며 VM을 추가하지 않습니다.
- 인프라 생성·샘플 복제는 수업 시간보다 오래 걸릴 수 있습니다.
  **권장: 강사가 전날 00~02를 리허설/준비하고 고객은 당일 전 단계를 순서대로 학습**합니다.
  당일 처음부터 생성한다면 고정 종료 시각을 보장하지 않습니다.
- 초기 자료 작성 과정에서는 실제 Azure 배포/이미지 빌드/전환을 실행하지 않았습니다.
  2026-10-28의 `v1.0.0` 릴리스 준비에서는 로컬 Linux/amd64 이미지를 빌드하고
  컨테이너의 `/healthz`와 대시보드 HTTP 200을 확인했습니다.
  실제 Azure 배포·private 서비스 연결·DR 전환은 여전히 미검증입니다.
  로컬 검사와 what-if 성공을 고객 구독에서의 성공 보장으로 해석하지 마세요.

## 학습 목표

1. Bicep 파라미터, 예산·SKU·비용, what-if 승인 절차를 설명한다.
2. 한 번의 구독 배포로 네트워크·PaaS·Private AKS·Traffic Manager를 준비한다.
3. 샘플 업로드/복제와 Search 인덱스 초기화를 구별한다.
4. 강사의 사전 이미지 패키징과 고객의 재빌드 없는 private ACR 전송/자동 배포를 구별한다.
5. 의존 서비스 연결과 실제 데이터 작업을 브라우저·CLI로 검증한다.
6. DNS 안내 리전과 응답 서버 리전을 구별하며 planned 전환·원복을 관측한다.
7. 오류/미지원 기능을 성공으로 기록하지 않고 비용 정리를 완료한다.

## 진행 순서

시간은 토론/실습 가이드이며 Azure 대기 시간은 별도입니다.

| 순서 | 실습 | 권장 시간 | 완료 게이트 |
|---|---|---:|---|
| 사전 | [강사 로컬 패키징·GitHub Release 게시](labs/03-build.md) | 교육 전 | 이미지/JSON/runbook/해시/공개 승인 |
| 00 | [준비·팀 구성·접속·비용 승인](labs/00-readiness.md) | 30분 | 권한, CIDR, 네트워크 예외, 예산 승인 |
| 01 | [Deploy to Azure·자동 앱 배포](labs/01-infrastructure.md) | 45분 + 생성 대기 | ARM/앱 준비를 별도로 확인, outputs 확보 |
| 02 | [샘플 데이터·복제·인덱스](labs/02-data.md) | 25분 + 복제 대기 | manifest, KRS secondary 실제 읽기 |
| 03 | [사전 이미지와 자동 전송 코드 읽기](labs/03-build.md) | 20분 | 아카이브 해시와 배포 이미지 비교 |
| 04 | [Workload Identity·Secret·자동 배포 검증](labs/04-application.md) | 30분 | 양쪽 앱 Ready, 고정 IP 일치, TM Online |
| 05 | [브라우저·API 기능 테스트](labs/05-baseline.md) | 35분 | 평시 결과와 UUID/시각 증거 |
| 06 | [DR 전환·원복·관측](labs/06-drill.md) | 50분 + 서비스 대기 | KRS 전환, KRC 복귀, 프로브 원복 |
| 07 | [회고·중지/삭제·과금 확인](labs/07-cleanup.md) | 25분 + 삭제 대기 | 정리 증거와 책임자 확인 |

다음 문서로 넘어가기 전에 각 문서의 **완료 게이트**를 충족하세요.
한 팀의 훈련 명령은 지정된 오퍼레이터 한 명만 실행합니다.
리소스 이름과 로그는 팀별 prefix로 분리하고, 두 팀이 같은 환경을 전환하지 않습니다.

## 실습 공통 규칙

- 명령은 **저장소 루트의 Bash 4+ / Windows Git Bash** 기준입니다.
  PowerShell에 Bash 코드를 그대로 붙여 넣지 마세요. Windows 경로 이동 예:
  Git Bash에서 `cd /e/VS_Code/AzDR/AzTemplate`.
- 창을 바꿀 때는 [01의 환경 복원](labs/01-infrastructure.md#새-터미널에서-복원)을 수행합니다.
  비밀 값은 파일에 저장하지 않으며 필요할 때 다시 입력합니다.
- 기본 입력 확인 문구는 실제 스크립트가 출력합니다. 이 과정에서는 `CONFIRM`을
  전역 export하지 않습니다. 삭제·전환·배포 승인을 서로 재사용하지 않습니다.
- 실패하면 다음 단계로 진행하지 말고 [문제 해결](troubleshooting.md)을 사용합니다.
  `disabled`, `pending`, 오류, 검증 완료를 구별해 기록하세요.
- 화면 이벤트와 drill CSV는 UTC입니다. 새 탭에 기존 이벤트 로그가 이어지지 않습니다.

## 제출물과 평가

[관측 CSV 템플릿](templates/observations.csv)을 팀 전용 상태 폴더에 복사합니다.
비밀 값/Authorization 헤더/Secret YAML은 제출하지 않습니다.

필수 증거: 비용/배포 승인, what-if, 샘플 복제, 코드 버전 태그, 양 리전 IP·Pod,
평시 UUID 쓰기/읽기, KRS 전환과 KRC 복귀 UTC, 프로브 원복, 리소스 정리 결과.

| 판정 | 기준 |
|---|---|
| 통과 | 활성화한 서비스에 실제 데이터 작업 성공, 전환/원복 및 정리 완료 |
| 부분 수행 | 승인된 절감 프로필의 disabled 서비스 또는 강사 제공 환경 관찰만 수행 |
| 보류 | SKU/지역·권한·private 연결·복제 오류 또는 정리 미완료 |

옵션 서비스를 껐는데 전체 서비스 DR를 검증했다고 적지 않습니다.
수업 종료 시 [강사 운영 가이드](facilitator-guide.md)의 종료 체크리스트를 함께 확인하세요.

## 자료 검증 범위

- 2026-10-28 공개 릴리스 `v1.0.2`에서 네 assets의 익명 다운로드와
  이미지/runbook/ARM JSON의 SHA256을 확인했습니다. 태그 고정 raw JSON도
  Release JSON과 바이트가 같고 CORS `*` 응답을 제공합니다.
- 로그인한 Azure 포털에서 `v1.0.2` 버튼으로 subscription-scope 입력 화면,
  샘플 `10GB`, bootstrap `true`, 같은 버전의 assets URL을 확인했습니다.
  Review + create / Create는 실행하지 않았습니다.
- 게시 준비 시 API 29개, 운영 회귀 40개, 부트스트랩 10개 검사가 통과했습니다.
  별도 기존 `infra/tests/validate-template.ps1`은 현재 `union` 출력 구조와
  맞지 않는 public-IP 단언에서 실패했으므로 통과로 집계하지 않습니다.
  최신 API의 BCP081 경고와 실제 배포/연결/DR 미검증 범위도 남아 있습니다.
- 운영 회귀 40개와 포털/릴리스/부트스트랩 검사 10개(compiled ARM 검사 포함)가 통과했습니다.
  Lab 04 복구 블록을 그대로 추출해
  두 리전 manifest/Secret 전달 및 임시 파일 정리를 모의 실행했습니다.
- 실제 인프라 RG 이름을 사용하는 destroy 안전 검사와 타 환경 이름 거절을 검증했습니다.
  기존 정리 도구가 `rg-<prefix>-...` 이름을 거부하던 오류를 수정했습니다.
- Markdown 로컬 링크, shell 구문과 환경 템플릿을 검사합니다.
- Bicep build 성공. Provider what-if는 bootstrap=true 60 changes/17개,
  false 58 changes/13개의 NestedDeploymentShortCircuited 진단과 함께 성공했습니다.
  런타임 모듈 일부가 상세 검증 생략되었으므로 실제 Release 다운로드/배포 성공 증거는 아닙니다.
- Azure 리소스 생성/삭제, Azure ACR push, 실제 DR 훈련은 실행하지 않았습니다.
  로컬 이미지 빌드·기동 검증은 위 `v1.0.0` 준비 기록과 구별합니다.
  고객 환경의 강사 사전 리허설이 여전히 필요합니다.

검사 명령:

```bash
bash scripts/tests/run.sh
```

PowerShell이 없으면 해당 suite가 NOT RUN으로 표시됩니다. 강사 PC에서는
`pwsh -File scripts/tests/test-workshop-bootstrap.ps1`도 반드시 실행합니다.
`-TemplatePath`에 실제 `az bicep build` 산출물을 주면 compiled ARM 계약까지 검사합니다.
