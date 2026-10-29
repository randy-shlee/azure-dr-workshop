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
| 4 | [포털 Failover와 Failback](workshop/04-dr-portal.md), [Bash 대안](workshop/04-dr.md) |
| 5 | [리소스 정리와 종료](workshop/05-cleanup.md) |

배포와 DR 역할 변경은 Azure 포털에서 수행할 수 있습니다. 설정 가져오기와 보조 운영 명령은
저장소 루트의 **Bash 터미널**에서 실행합니다. Bash DR 대안의 장시간 실행 환경은 첫 단계에 설명되어 있습니다.

## 배포 버튼

배포 전 [보안 안내](../SECURITY.md)를 확인하고, 이번 실습 전용의 새 prefix를 사용합니다.
기존 환경에 같은 prefix로 전체 템플릿을 재배포하지 않습니다. 배포 실패 시 오류와 현재 리소스 상태를
확인한 뒤 진행하며, 보호 설정을 해제하거나 오류를 우회하지 않습니다.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Frandy-shlee%2Fazure-dr-workshop%2Fv1.0.11-portal.4%2FPortal_DeployToAzure_lab%2Freleases%2Fv1.0.11-portal.4%2Fazuredeploy.json)