# 00. 실행 환경 준비

[목차](README.md) · [다음: 포털 배포](01-deploy.md)

## 1. 실행 위치 선택

| 위치 | 수행할 작업 |
|---|---|
| PC의 웹 브라우저 | Azure 포털 배포, Automation 확인, 앱 화면 사용 |
| Azure Cloud Shell **Bash** | 저장소 다운로드, Azure 관리 조회, 배포 출력 가져오기, 짧은 상태 확인 |
| 지속 실행 가능한 Linux Bash | 전체 Failover/Failback. 예: 관리용 Linux VM의 VS Code Remote SSH 터미널 |
| AKS Run command | 사설 클러스터 안에서 kubectl 실행. Bash의 기존 스크립트가 Azure CLI로 요청 |

**`10-failover.sh`는 Azure 포털 화면에 붙여 넣는 명령이 아닙니다.** 저장소를 받은 Bash 터미널에서
`bash scripts/drill/10-failover.sh`로 실행합니다. Cloud Shell에서도 도구·권한·앱 접근이 충족되면
실행할 수 있지만, Storage 전환이 수 시간 걸릴 수 있어 전체 DR에는 지속 실행 환경을 사용합니다.
Cloud Shell은 비활성·세션 제한 및 연결 종료가 있으며, 브라우저를 닫은 뒤 작업 지속을 보장하지 않습니다.
스크립트가 끊겨도 Azure 작업은 계속될 수 있으므로 즉시 재실행하지 않습니다.

Windows PowerShell/CMD에 아래 Bash 명령을 그대로 실행하지 않습니다. 로컬 환경을 사용한다면
WSL2 등 Bash 4+와 아래 도구를 갖춘 환경을 사용합니다. 이 과정은 Cloud Shell과 Linux 기준입니다.

## 2. 접근 IP와 권한 준비

앱 접근 허용 목록에는 **앱 브라우저의 공인 출구 IPv4**와 **DR 터미널의 공인 출구 IPv4**가 모두 필요합니다.
회사 프록시·VPN·NAT를 사용하면 PC/VM 주소가 아니라 실제 출구 주소를 네트워크 담당자에게 확인합니다.
관리용 VM은 워크숍 삭제 대상 RG 밖에 두고 승인된 고정 출구 IP를 사용합니다.

Cloud Shell 출구 IP는 PC 주소와 다르며 재접속 시 바뀔 수 있습니다. 관리 조회가 성공해도 앱 HTTP 호출은
차단될 수 있습니다. 고정 IP를 승인할 수 없다면 Cloud Shell에서 DR를 실행하지 말고 승인된 관리용
Bash 환경을 사용합니다. `0.0.0.0/0` 허용이나 사설 서비스 공개로 해결하지 않습니다.

구독 범위 배포와 role assignment/custom role 생성 권한이 필요합니다. 일반 Contributor만으로는
권한 부여가 부족할 수 있습니다. DR에는 Storage/PG/EH/TM 변경과 AKS Run command 권한도 필요합니다.
조직 관리자에게 실제 권한·양 리전 할당량·SKU·정책·비용 승인을 확인합니다.

## 3. Bash와 도구 확인

Azure 포털 상단의 **Cloud Shell (`>_`)**을 열고 **Bash**를 선택합니다. 처음 실행하면 조직 정책에 맞는
세션/저장소 방식을 선택합니다. 저장소가 없는 임시 세션은 작업 파일도 유지되지 않습니다.
Linux 관리용 VM을 쓰면 해당 VM의 Bash 터미널에서 동일하게 시작합니다.

```bash
bash --version
for tool in az git jq curl nslookup python3; do
  command -v "$tool" || printf 'MISSING: %s\n' "$tool"
done
python3 --version
```

Bash 4+, Python 3.9+가 필요합니다. `MISSING`이 있으면 중단하고 승인된 방법으로 도구를 설치합니다.
로컬 kubectl·Docker·azd·Bicep은 이 포털 실습에 필요하지 않습니다. kubectl은 AKS Run command 안에서 실행합니다.

Cloud Shell은 로그인된 사용자 컨텍스트를 사용합니다. VM/WSL은 먼저 `az login`으로 로그인합니다.
실습을 승인받은 계정과 구독을 사용하는지 확인합니다.

```bash
export SUBSCRIPTION_ID='YOUR-SUBSCRIPTION-ID'
az account set --subscription "$SUBSCRIPTION_ID"
az account show --query '{subscription:name,id:id,tenant:tenantId}' -o table
```

구독이 다르거나 권한 오류가 나면 이후 명령을 실행하지 않습니다.

## 4. 같은 버전의 운영 스크립트 받기

배포 버튼과 동일한 공개 태그를 받습니다. 현재 지정된 태그가 아직 공개되지 않았다면 여기서 중단합니다.
다른 branch나 이전 릴리스로 대신 진행하지 않습니다.

```bash
export LAB_TAG='v1.0.11-portal.2'
git clone --branch "$LAB_TAG" --single-branch \
  https://github.com/randy-shlee/azure-dr-workshop.git azure-dr-portal
cd azure-dr-portal
git describe --tags --exact-match
test -f scripts/common.sh && test -f scripts/drill/10-failover.sh
```

이후 명령은 **저장소 루트 `azure-dr-portal`**에서 실행합니다.
문서가 있는 하위 폴더에서 실행하면 `scripts/...` 경로를 찾지 못합니다.
동일 이름 폴더가 이미 있으면 clone 오류를 무시하거나 기존 파일을 덮어쓰지 말고 별도 작업 경로를 사용합니다.

## 완료 조건

브라우저·지속 실행 Bash 환경, 승인된 두 출구 IP, 도구, 구독 권한, 동일 태그의 저장소가 준비되었습니다.
새 터미널을 열면 구독 선택과 저장소 루트 이동을 다시 하고, 배포 후에는 다음 단계의 config 설정도 복원합니다.

[다음: 포털 배포](01-deploy.md)