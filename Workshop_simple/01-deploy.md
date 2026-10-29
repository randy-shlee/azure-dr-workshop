# 01. 원클릭 배포

[이전](00-start.md) · [목차](README.md) · [다음: 준비 확인](02-ready.md)

## 목표

검증된 로컬 패키지의 **한 명령으로 앱까지 자동 배포**되는 과정을 관찰합니다.
공개 웹의 Deploy to Azure 버튼을 누르는 방식이 아닙니다.
명령/암호 입력은 강사만 [배포 안내](../workshop/local-package.md#one-command-to-deploy)에 따라 수행합니다.

## 할 일

1. 강사가 최종 ZIP과 manifest를 확인하고 원본 `deployment-tools.zip`을 `tools`에 추출합니다.
   `source`는 문서/DR 스크립트용이며 실제 배포는 추출한 고정 버전 도구를 사용합니다.
2. 승인된 새 prefix/구독/CIDR과 SecureString PG 암호로 단일 명령을 실행합니다.
3. 다음 자동 단계를 확인합니다.

   **해시 → 인프라 → 사설 ACR 이미지 → 양 앱/Secret/Service → 자동 10 GB
   샘플/복제/보조 읽기 → TM·실제 서비스 smoke**

4. `tools\.state\deployments\<prefix>\deployment-status.json`에서 `phase=Complete`를 확인합니다.
   인프라 `Succeeded`만으로 앱 완료가 아닙니다.
5. 해당 폴더의 `config.json`과 TM/지역 앱 주소를 강사에게 받습니다.

사전 준비 환경이면 이 단계를 다시 실행하지 않고 배포 이력/해시/완료 상태를 봅니다.
`drws1028c`는 이 전체 흐름의 성공 실증 환경이며 [결과](../workshop/releases/v1.0.7-validation.md)를 참고합니다.

## 정상 상태

- 로컬 상태 `Complete`, 양 앱 준비, 샘플 생략 없이 다음 게이트로 진행.
- 현재 경로에는 cloud Automation 계정/`workshop-bootstrap-status`가 없어도 정상.
- 원본 이미지/템플릿/도구를 변조하거나 공개 URL에 의존하지 않음.

`-SkipSampleData`를 명시한 배포는 앱 준비만 증명하므로 샘플/DR 완료로 제출하지 않습니다.

## 안 되면 멈추기

`Failed`/timeout/오류는 성공이 아닙니다. 실제 실패 단계와 오류를 강사에게 전달합니다.
같은 prefix로 전체 배포를 반복하거나 이미 있는 PG/Redis를 삭제해 우회하지 않습니다.
공개 v1.0.3 버튼과 미게시 과거 Draft는 사용하지 않습니다.

## 완료 체크

- [ ] 같은 버전 assets/해시와 승인된 입력 확인
- [ ] 실제 상태 `Complete` 또는 준비된 환경의 완료 이력 확인
- [ ] 해당 작업의 config/주소와 샘플 생략 여부 확인
