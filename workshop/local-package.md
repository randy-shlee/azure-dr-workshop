# 로컬 최종 패키지: 인프라부터 앱 준비까지

GitHub 공개 게시 없이 배포하는 **현재 기본 경로**입니다. 문서 개정본도 실행 assets는
새 환경 실증을 완료한 **v1.0.7 원본 바이트/해시**를 유지합니다.
패키지에 포함한 이미지와 도구를 사용하므로 미게시 URL이나 과거 공개 이미지에 의존하지 않습니다.
[전체 개요·Azure 구성도](architecture.md), [간단 과정](../Workshop_simple/README.md),
[고급 과정](README.md), [실증/제외 범위](releases/v1.0.7-validation.md)를 함께 봅니다.

## 준비 사항

- 승인된 Azure 테스트 구독, 배포/역할 할당 권한, Korea Central/South 할당량과 실제 용량,
  사용하지 않은 3~12자 소문자/숫자 prefix(첫 글자 소문자, `^[a-z][a-z0-9]{2,11}$`).
- PowerShell 7.2+, Azure CLI, Windows Git Bash, Python 3.9+, jq, kubectl.
- 승인한 오퍼레이터/브라우저 공인 IPv4 CIDR(/24~ /32). 광역 공개는 거절합니다.
  첫 CIDR은 실제 배포 오퍼레이터의 출구 주소로 지정합니다. 임시 Docker 엔진은 이 CIDR만 허용합니다.
- manifest/해시를 포함한 완전한 로컬 릴리스 디렉터리.
- SecureString으로 전달하는 테스트 PostgreSQL 암호. 아카이브, 소스, 터미널 기록,
  명령행 인수의 평문에 포함하지 않습니다.

full은 AKS 4노드, PostgreSQL 2서버와 양 리전 데이터 서비스를 사용합니다.
환경 유지 중 계속 과금하며 `expiry`는 태그일 뿐 자동 삭제가 아닙니다.
2026-10-28 사전 조회의 알려진 항목 소계는 추가 환경 약 **USD 1,615.41/월**이며
가변 사용량/임시 빌드 등은 별도입니다. 기존 DR 환경에 전체 템플릿을 덮어써 실증하지 않습니다.

<a id="one-command-to-deploy"></a>

## 한 명령으로 배포

최종 전달 ZIP을 새 폴더에 풉니다. 아래는 **ZIP 루트**(assets + `source`가 있는 폴더)에서
실행하는 PowerShell입니다. 내부 `deployment-tools.zip`은 별도 `tools`에 추출합니다.
이미 실행 중인 tools/state를 덮어쓰지 않습니다. 암호를 입력한 뒤 한 배포 명령이 끝까지 수행합니다.

```powershell
az login
Expand-Archive -LiteralPath .\deployment-tools.zip -DestinationPath .\tools
$password = Read-Host 'Test PostgreSQL password' -AsSecureString
.\tools\scripts\deploy-local-package.ps1 `
  -ReleaseDirectory (Get-Location).Path `
  -Prefix 'mydrws01' `
  -SubscriptionId 'YOUR-SUBSCRIPTION-ID' `
  -AllowedClientCidrs 'YOUR-PUBLIC-IP/32' `
  -AdministratorLogin 'dradmin' `
  -AdministratorPassword $password `
  -ConfirmCreate
Remove-Variable password
```

명령은 다음을 자동 수행합니다.

1. 이미지/템플릿/배포 도구의 SHA256을 검증합니다.
2. 새 환경의 리소스 그룹이 이미 있으면 거절합니다.
3. 이 로컬 경로의 cloud Automation을 끄고 인프라를 생성합니다.
4. KRC에 승인 CIDR+mTLS로 제한한 임시 Docker 엔진을 시작합니다.
   공용 무인증 Docker 서비스가 아닙니다.
5. 패키지 이미지를 로드해 VNet 내부에서 사설 ACR로 push하고,
   임시 엔진/네트워크 규칙/이번에 추가한 push 권한을 제거합니다.
6. Search 초기화, Secret 생성, 양 앱 배포를 수행합니다.
7. 양 Pod Ready, 고정 Service IP, 양 Traffic Manager endpoint Online을 확인합니다.
8. 명시적 `-SkipSampleData`가 아니면 샘플 업로드/복제/보조 읽기를 확인합니다.
9. 공개 API의 쓰기/읽기와 양 Pod의 백엔드 연결 smoke를 실행합니다.
   샘플 생략 시에도 서비스 smoke는 수행하고 샘플 검증만 명시적으로 제외합니다.

앱은 샘플 복제 대기 **이전**에 배포됩니다. 요청한 모든 단계가 끝나야 명령이 성공합니다.
ZIP 루트 기준 `tools\.state\deployments\<prefix>\deployment-status.json`의 `phase=Complete`와
`tools\.state\deployments\<prefix>\config.json`을 확인합니다.
인프라 Succeeded만으로 앱 준비가 완료된 것은 아닙니다.

완료 후 운영/DR는 전달본 `source`를 VS Code에서 열고 그 위치의 Git Bash에서 수행합니다.
원본 tools ZIP은 배포용 소규모 도구여서 전체 DR 코드를 포함하지 않습니다.
대상 config는 `../tools/.state/deployments/<prefix>/config.json`이며
[구독/prefix 검증을 포함한 복원 절차](labs/01-infrastructure.md#새-터미널에서-복원)를 따릅니다.
`source/.state/<prefix>`는 운영 로그 위치이지 자동 생성 config의 위치가 아닙니다.
공개 저장소 clone으로 미게시 소스가 같다고 가정하지 않습니다.

앱만 업데이트할 때는 정확한 기존 비밀 없는 config를 `-InfrastructureConfigPath`에 전달합니다.
인프라 생성을 건너뛰며 PG/Redis 전체 스택 재배포를 지원하는 기능이 아닙니다.
임시 엔진 정리가 실패하면 상태는 실패이며 보호된 복구 상태 경로를 보존합니다.
이 경우 해당 config/StateDirectory로 엔진의 `-Action Stop`을 재실행해 정리합니다.

## 업로드 버튼과 10 GB 상한

업로드 버튼은 **서버에서 샘플 데이터를 생성**합니다. PC 파일을 선택해 보내는 기능은 아닙니다.
승인된 워크숍 IP 경계와 명시적 확인이 필요하며 다른 Origin에서의 시작은 거절합니다.

- 최대 논리 샘플 payload: **10,000,000,000 bytes(decimal 10 GB)**.
- 요청이나 환경 변수로 서버 상한을 올릴 수 없습니다.
- 기본: 1 GiB 7개 + 나머지 386,655,232 bytes 1개 + 1 MiB 2,000개,
  총 **2,008객체/정확히 10 GB**입니다.
- 제한된 스트리밍으로 전체 크기의 메모리 버퍼/로컬 임시 파일을 만들지 않습니다.
- 공유 Blob lease로 양 앱의 동시 업로드를 제한합니다.
- 자동 CLI 샘플 Job도 같은 lease를 사용하므로 자동 업로드와 버튼 업로드가 겹치지 않습니다.
- 샘플 inventory 밖에 진행/오류를 영속화하고 화면에서 상태를 polling합니다.
- 올바른 기존 파일은 재개할 수 있습니다. 크기/manifest 불일치는 명시적으로 실패하고
  성공시키기 위해 기존 데이터를 삭제하지 않습니다.

이전 `drws1028a`의 10 GiB 예산 검증 데이터는 새 decimal 상한보다 큽니다.
원본을 보존하고 새 10 GB 검증에는 별도 설정 컨테이너를 사용합니다.
이전 데이터를 새 상한 검증 성공으로 바꿔 기록하지 않습니다.

inventory/읽기와 Last Sync Time은 별도 게이트입니다.
복제 대기 중이면 failover 준비 완료를 주장하지 않습니다.

## 패키지 제작

강사는 전달본 `source` 또는 승인된 최신 소스 루트에서 canonical Dockerfile을
`linux/amd64`로 실제 build하고 `docker save`로 내보낸 후
허용 목록 소스/컴파일한 템플릿과 함께 묶습니다.

```powershell
.\scripts\package-workshop-release.ps1 `
  -Repository 'YOUR-ORG/YOUR-REPO' -ReleaseTag 'v1.0.8'
```

`v1.0.8`은 사용하지 않은 새 태그의 예시이지 검증 릴리스가 아닙니다.
기존 v1.0.7 assets/디렉터리를 재생성하지 않습니다.
기본은 로컬 Linux Docker입니다. 명시적으로 승인한 Azure 엔진은 `-AzureBuildConfigPath`로 지원합니다.
endpoint가 해당 환경의 실제 PIP와 일치하고 검증된 mTLS를 활성화해야 하며 임의 원격 endpoint는 거절합니다.

승인 없이 패키지를 게시하거나 공개 버튼을 새 미게시 URL로 바꾸지 않습니다.
선택적 포털은 같은 버전 공개 assets/해시가 모두 있어야 합니다.
로컬 패키지를 만들었다고 그 공개 URL이 유효해지는 것은 아닙니다.

## 배포 성공으로 검증되지 않는 항목

실제 Storage/PG/EH 전환·원복, 99:1 라우팅, 장애 내구성, SLA/RTO/RPO 보장은
별도 승인 실습입니다. Event Hubs Standard Geo-DR는 metadata-only/fail-forward이며
이벤트 payload를 복제하지 않습니다.

실제 승인 절차와 post-failback 상태는 [DR Lab](labs/06-drill.md)를 따릅니다.
전환은 **Storage → EH → PG → TM**, 원복은 **Storage → PG → EH active 확인 → TM**입니다.
Storage/PG/앱을 KRC로 원복해도 EH alias는 KRS에 남습니다.
