# Lab 03. 강사 사전 준비: 로컬 이미지 → GitHub Release

[이전](02-data.md) · [목차](../README.md) · [다음](04-application.md)

**이 단계는 강사/콘텐츠 작성자가 Lab 01 전에 한 번 수행**합니다.
고객은 빌드 없이 공개된 동일 버전 아카이브를 사용합니다. 코드를 바꾸면 새 버전으로
다시 패키징·승인·게시해야 합니다. 배포 중 고객 PC에서 빌드하는 방식이 아닙니다.

## 3-1. 로컬 준비

- 승인된 로컬 Docker Linux 엔진, PowerShell 7.2+, Azure CLI/Bicep.
- 공개 배포가 승인된 GitHub 저장소와 새 Release 태그. 민감한 코드/자격 증명/고객 데이터 금지.
- [앱](../../app/main.py), [HTML](../../app/static/index.html),
  [Dockerfile](../../app/Dockerfile)을 검토하고 선택적으로 팀 이름을 변경합니다.
- 포트 8000, `/healthz`, 환경 변수 계약은 유지합니다.
- 원본 저장소 전체가 아닌 **app 폴더만** Docker build context로 사용합니다.
  원격 Docker context에는 소스를 전송하지 않도록 패키저가 거절합니다.

공개 저장소/릴리스 사용은 별도의 조직 승인이 필요합니다. **아직 공개 승인을 받지
않았다면 게시하지 마세요.** 현재 구현은 익명 다운로드만 지원하며 private Release,
PAT, 만료되는 서명 URL은 지원하지 않습니다. 배포할 포털 JSON과 runbook도
인증 없이 읽을 수 있어야 합니다.

## 3-2. 이미지와 포털 파일 패키징

다음은 **PowerShell** 예시입니다. 설명용 `YOUR-ORG/YOUR-REPO`를 실제 승인 저장소로 바꿉니다.

```powershell
pwsh -File .\scripts\package-workshop-release.ps1 `
  -Repository 'YOUR-ORG/YOUR-REPO' -ReleaseTag 'v1.0.3' -UpdateWorkshopButton
```

[패키저](../../scripts/package-workshop-release.ps1)는 다음을 수행합니다.

1. 로컬에서 `docker build --platform linux/amd64` 실행 및 아키텍처 확인.
2. `docker save` → 스트리밍 gzip → SHA256 생성.
3. 허용 목록의 운영 스크립트/K8s 원본만 작은 ZIP으로 묶어 runbook에 포함.
   `.state`, 암호, 전체 저장소, 이미지 파일은 이 ZIP에 포함하지 않음.
4. 포털 전용 [Bicep](../../infra/workshop.bicep)을 ARM JSON으로 빌드하고
   워크숍 10GiB/부트스트랩 true/Release URL/해시 기본값을 설정.
   공유 인프라는 재사용하되 owner 입력/태그, 예산 생성, 이메일 알림은 제외합니다.
   기존 CLI용 [Bicep](../../infra/main.bicep)의 기본 동작은 유지합니다.
5. `.state/releases/v1.0.3`에 파일 생성. 기존 디렉터리/동일 버전 덮어쓰기는 거절.
6. `-UpdateWorkshopButton`이면 같은 JSON을 `workshop/releases/azuredeploy.json`에도
   생성하고 Lab 01의 버튼을 **릴리스 태그로 고정한 raw.githubusercontent.com URL**로 교체.
   GitHub Release 다운로드 주소는 포털 브라우저의 CORS 요청을 지원하지 않습니다.
   JSON은 UTF-8/LF로 생성하여 Git 줄바꿈 정규화 후에도 SHA256을 유지합니다.
   생성된 JSON과 문서 변경을 commit/push한 뒤 그 commit에 새 릴리스 태그를 생성합니다.
   **태그 게시 전에는 버튼 URL이 아직 열리지 않습니다.**

게시할 네 assets:

| 파일 | 용도 |
|---|---|
| `app-image.tar.gz` | 미리 빌드한 `docker save` 이미지. Git repo blob으로 commit하지 않음 |
| `workshop-bootstrap.ps1` | 해시로 고정한 게시 runbook. 기존 스크립트/K8s 소스 ZIP 포함 |
| `azuredeploy.json` | 포털 subscription-scope ARM template, 모듈 내장 |
| `release-manifest.json` | 버전, URL, 이미지/runbook/template SHA256 |

`deploy-button.md`는 문서용이며 `kubectl.sha256`은 패키징 보조 파일입니다.
새 리소스 생성, `az acr build/import`, GitHub 업로드는 패키저가 실행하지 않습니다.
Linux/amd64 도구 `crane`과 `kubectl`도 고정 버전/해시로 검증한 후 AKS 안에서만 사용합니다.

## 게시 전 what-if

고객용 JSON의 실제 파라미터를 검토해야 합니다. 원본 Bicep의 bootstrap=false
what-if만으로 포털 프로필을 검증했다고 적지 않습니다.
아래는 **Bash**이며 기존 팀 환경을 복원한 뒤 수행합니다.

```bash
read -rs -p 'Test PostgreSQL password for what-if: ' PG_PASSWORD; echo
export PG_PASSWORD
export PORTAL_TEMPLATE="$ROOT_DIR/.state/releases/v1.0.3/azuredeploy.json"
(
  umask 077
  stage="$(mktemp -d "$STATE_DIR/portal-what-if.XXXXXX")"
  trap 'rm -f -- "$stage/parameters.json"; rmdir -- "$stage"' EXIT
  jq -n '{parameters:{
    prefix:{value:env.PREFIX},expiry:{value:env.EXPIRY},
    allowedClientCidrs:{value:(env.ALLOWED_CLIENT_CIDRS|split(","))},
    administratorLogin:{value:env.PG_ADMIN_LOGIN},administratorPassword:{value:env.PG_PASSWORD}}}' \
    >"$stage/parameters.json"
  az deployment sub what-if --location koreacentral --template-file "$PORTAL_TEMPLATE" \
    --parameters "@$stage/parameters.json" --validation-level Provider
)
unset PG_PASSWORD
```

비밀 파일은 제한된 로컬 상태 폴더에서만 만들고 삭제합니다. Windows NTFS ACL도 보호하세요.
해시/URL, 역할 정의/할당, 3개 RG, Basic Automation의 네트워크 예외와 예상 비용을 검토합니다.
NestedDeploymentShortCircuited는 상세 검증 생략이며 실제 성공 보장이 아닙니다.
실제 강사 테스트 구독에서 리허설 후 배포 성공 여부를 별도로 기록합니다.

## 3-3. 승인 후 GitHub에 게시 — 수동 승인 작업

조직 승인 후 아래 **PowerShell** 명령으로 공개 저장소의 Release assets를 올립니다.
초기 자료 작성 시 업로드는 실행하지 않았으며, 현재 게시 버전은 Lab 01에서 확인합니다.

```powershell
$repo = 'YOUR-ORG/YOUR-REPO'
$tag = 'v1.0.3'
$dir = Join-Path (Get-Location) ".state\releases\$tag"
git add workshop/releases/azuredeploy.json workshop/labs/01-infrastructure.md
git commit -m "Prepare workshop portal template $tag"
git push origin HEAD
gh release create $tag --repo $repo --target (git rev-parse HEAD) --title 'Azure DR workshop' `
  "$dir\app-image.tar.gz" "$dir\workshop-bootstrap.ps1" `
  "$dir\azuredeploy.json" "$dir\release-manifest.json"
```

GitHub Release asset당 용량 제한(현재 2GiB)을 넘으면 중단합니다. 아카이브를 임의로
분할하거나 repo에 commit하지 않습니다. 원본 앱만 패키징한 이미지 크기를 확인하세요.
현재 도구는 분할/외부 레지스트리 원본을 지원하지 않습니다.

익명 브라우저에서 네 URL과 manifest의 raw `templateUri`가 열리는지,
두 JSON의 SHA256이 같은지와 raw 응답의 CORS 헤더를 확인한 후,
Lab 01 버튼이 포털의 올바른 subscription template을 여는지 검증합니다.
버전/tag/assets를 덮어쓰지 마세요. 이미지와 runbook 해시가 달라지면 배포를 실패시킵니다.
runbook은 인프라를 관리할 수 있는 코드이므로 검토한 강사의 릴리스만 신뢰합니다.

## 3-4. 고객 관찰

고객은 소스·Dockerfile과 release-manifest를 비교하고,
Lab 04에서 실제 배포된 이미지가 `drtest-app:release-<archive SHA256>`인지 확인합니다.
고객의 Docker/ACR private 연결은 필요 없습니다.
코드 수정 실습을 원하면 **강사가 새 Release를 만들고 별도 테스트 환경에서 배포**합니다.
DR 훈련 중 기존 인프라를 재배포하지 않습니다.

## 완료 게이트

- [ ] 로컬 Linux/amd64 build/save 성공, 실제 이미지 실행/테스트
- [ ] 공개 승인, 비밀/고객 데이터 미포함, 새 버전/해시 고정
- [ ] 게시한 JSON으로 Provider what-if 및 실제 리허설
- [ ] 익명 assets 다운로드와 Lab 01 포털 버튼 확인
- [ ] 실제 고객 배포는 새 ACR에 재빌드 없이 전송
