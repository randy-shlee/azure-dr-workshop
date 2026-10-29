# Azure Portal 기반 DR 워크숍

GitHub의 **Deploy to Azure** 버튼에서 Azure 포털로 이동하여 리소스와 앱을 자동 배포하고,
앱 데이터 확인, Korea South 전환, Korea Central 원복, 리소스 정리를 순서대로 진행합니다.
역할별 문서를 나누지 않고 하나의 실습 순서를 사용합니다.

## 시작하기

**[고객용 Step-by-Step 워크숍 시작](workshop/README.md)**

| 순서 | 실습 |
|---|---|
| 0 | [실행 환경과 Azure 로그인](workshop/00-environment.md) |
| 1 | [포털에서 리소스와 앱 배포](workshop/01-deploy.md) |
| 2 | [자동 배포 완료와 앱 접속](workshop/02-ready.md) |
| 3 | [앱 데이터와 샘플 복제 확인](workshop/03-application.md) |
| 4 | [Failover와 Failback](workshop/04-dr.md) |
| 5 | [리소스 정리와 종료](workshop/05-cleanup.md) |

배포는 브라우저에서, 운영 명령은 저장소 루트의 **Bash 터미널**에서 실행합니다.
Azure Cloud Shell의 사용 범위와 장시간 DR 실행 환경은 첫 단계에 설명되어 있습니다.

## 배포 버튼

**현재 버튼은 실환경 검증용 후보입니다.** 연결된 태그의 템플릿과 이미지·runbook이 공개되기 전에는
사용할 수 없습니다. 공개 prerelease는 최종 검증 완료를 뜻하지 않으며, 실제 배포와 DR 결과는 별도로 확인합니다.
이 상태에서 배포 오류를 우회하거나 기존 환경에 같은 prefix로 재배포하지 않습니다.

현재 준비본은 최소 런타임으로 재빌드한 v1.0.11 이미지·번들을 사용합니다.
새 태그는 v1.0.11-portal.2이며 [검증 후보 상태](releases/v1.0.11-portal.2/README.md)와
[보안 안내](../SECURITY.md)를 먼저 확인합니다. 2026-10-29 앱 이미지의 OS·Python 패키지 감사에서
알려진 취약점이 없었습니다. 구 이미지 기반 v1.0.8-portal.1 및 OS 취약점으로 차단된
v1.0.10-portal.1은 계속 사용하지 않습니다.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.2%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.2%2Fazuredeploy.json)

기존 원클릭 배포 경로는 변경하지 않습니다. 이 경로도 기존 인프라·앱·운영 스크립트를 재사용하며,
고객용 실습에는 릴리스 제작이나 준비용 테스트 절차를 포함하지 않습니다.