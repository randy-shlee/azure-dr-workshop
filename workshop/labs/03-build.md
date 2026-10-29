# Lab 03. 이미지·패키지 해설과 강사 제작

[이전](02-data.md) · [목차](../README.md) · [다음: 앱 검증](04-application.md)

## 3-1. 참가자는 다시 빌드하지 않음

현재 v1.0.7은 [새 환경 전체 실증](../releases/v1.0.7-validation.md)을 완료했습니다.
고객은 원본 이미지/ARM/도구를 사용합니다. 이 Lab은 **코드 해설**이며
제작자는 변경 소스의 새 버전을 Lab 01 **전에** 만듭니다.
기존 release 디렉터리를 덮어쓰거나 문서 개정만으로 앱 버전을 올리지 않습니다.

| 원본 asset | 확인 |
|---|---|
| app-image.tar.gz | 실제 canonical Dockerfile의 Linux/amd64 build/save/gzip 결과 |
| azuredeploy.json | 모듈이 내장된 subscription ARM template |
| deployment-tools.zip | 공개 URL 없이 배포하는 고정된 실행 도구 |
| release-manifest.json | 이미지/ARM/도구/runbook SHA256, 버전, 10 GB 계약 |
| DEPLOYMENT.md | 기본 단일 명령과 보안/완료 게이트 |
| workshop-bootstrap.ps1 | 선택적 공개 포털용. 현재 로컬 실행에서는 사용하지 않음 |

SHA256 태그는 **이미지 아카이브 해시**입니다. 레지스트리의 OCI manifest digest/imageID와
다른 식별자이며 둘을 같은 값으로 비교하지 않습니다.
로컬 배포는 `release-<archive SHA256>` 태그로 private ACR에 push합니다.

## 3-2. 새 소스 패키지 제작 — 강사만

앱 코드 변경 시 사용하지 않은 새 버전으로 canonical build/save와 테스트를 수행합니다.
아래 `v1.0.8`은 **미사용 새 태그의 예시**이며 실증된 릴리스라는 뜻이 아닙니다.

```powershell
.\scripts\package-workshop-release.ps1 `
  -Repository 'YOUR-ORG/YOUR-REPO' -ReleaseTag 'v1.0.8'
```

로컬 Linux Docker가 기본입니다. 명시적 `-AzureBuildConfigPath`를 사용하는 자체 Azure
엔진만 verified PIP + mTLS로 허용하며 임의 원격 endpoint는 거절합니다.
패키저 자체는 Azure 인프라를 배포하거나 GitHub에 게시하지 않습니다.
도구 상세: [패키저](../../scripts/package-workshop-release.ps1),
[엔진](../../scripts/azure-docker-engine.ps1), [앱 Dockerfile](../../app/Dockerfile).

앱 전체 payload 버퍼/임시 10 GB 파일 대신 제한된 스트림을 사용합니다.
새 배포본의 코드 변경은 앱/스크립트/패키지 검사를 하고, 별도 새 환경에서 다시 실증합니다.
정상 환경을 PG/Redis 재배포/삭제/forceUnlink로 초기화하지 않습니다.

## 게시 전 what-if

새 템플릿/릴리스를 만드는 강사는 실제 구독과 **같은 프로필**의 Provider validation/
what-if를 검토합니다. 로컬은 `deployWorkshopBootstrap=false`를 전달합니다.
보호된 파라미터 파일을 사용하고 SecureString 암호를 stdout/평문 명령행/일반 디렉터리에 남기지 않습니다.

`NestedDeploymentShortCircuited`는 상세 검증 생략이지 성공이 아닙니다.
what-if/compile은 실제 지역 용량, 이미지 실행, 사설 연결, 데이터 복제를 대체하지 않습니다.
현재 v1.0.7 성공은 이 일반 설명이 아니라 별도 실증 보고서를 근거로 합니다.

## 3-3. 공개 포털은 별도 작업

`-UpdateWorkshopButton`과 공개 게시/commit/push는 조직 승인 후에만 수행합니다.
현재는 실행하지 않습니다. raw template URL, 같은 버전 공개 assets/해시,
익명 다운로드/CORS, cloud Automation 권한/네트워크와 실제 새 환경을 별도로 검증해야 합니다.
기존 v1.0.3 버튼은 사용하지 않습니다. 로컬 실증을 공개 포털 실증으로 바꾸어 쓰지 않습니다.

선택 경로의 코드는 [포털 Bicep](../../infra/workshop.bicep),
[runbook](../../scripts/workshop-bootstrap.ps1),
[상태 조회](../../scripts/bootstrap-status.sh)에 있습니다.
이 경로의 ARM Succeeded는 자동화 시작이며 앱/샘플 완료를 뜻하지 않습니다.

## 완료 게이트

- [ ] 원본 assets와 배포 태그/OCI digest의 관계 이해
- [ ] 이미 배포한 환경에서 불필요한 빌드/이미지/Secret 재적용 없음
- [ ] 새 코드를 만들었다면 새 버전·검사·새 환경 실증, 공개 게시 별도 승인
