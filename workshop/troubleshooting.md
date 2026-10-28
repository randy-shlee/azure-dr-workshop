# 문제 해결: 성공으로 위장하지 않고 다음 단계 정하기

[목차](README.md) · [강사 운영](facilitator-guide.md)

먼저 같은 저장소 루트에서 팀 환경/구독을 복원했는지 확인하세요.
`env`, `printenv`, Secret 전체, Authorization 헤더, `bash -x` 로그를 공유하지 않습니다.

| 증상 | 확인할 것 | 안전한 조치 / 중단 기준 |
|---|---|---|
| owner@example.com 또는 placeholder | 설정 파일 owner/subscription/CIDR | 실값·승인 확인 전 생성 금지 |
| what-if 변경 0건이 이상함 | explicit template-file/구독/파라미터 | deploy.sh 사용, 성공 메시지만 신뢰하지 않음 |
| NestedDeploymentShortCircuited | 런타임 reference 중첩 검증 생략 | 고객 리허설로 실제 배포/PE 검증; 완료 보장 아님 |
| BCP081 / template 오류 | 경고인지 실제 오류인지, CLI/Bicep 버전 | 오류는 중단. 경고도 실제 속성/지역 검증 필요 |
| SKU/quota/지역 기능 미지원 | KRC/KRS, 실제 구독 제한 | 강사 확인. 비싼 SKU/다른 리전 자동 변경 금지 |
| deploy가 오래 대기 | 실제 ARM 배포와 Job/Last Sync Time 단계 | 업로드/복제인지 확인. 무조건 재배포하지 않음 |
| ACR agent pool 미지원 | KRC와 공식 preview 지역 목록 | 본 과정은 Release 아카이브를 AKS에서 전송; Tasks 불필요 |
| 이미지 전송 timeout/public DNS | KRC Job의 registry/data DNS·443 | 사설 연결 복구; public access/bypass 열지 않음 |
| push unauthorized | bootstrap MI의 AcrPush, WI, 전파 | 이 ACR 역할/전파 확인. admin 키 활성화 금지 |
| ImagePullBackOff | 이미지 태그·실패 이벤트·kubelet AcrPull·ACR PE | 앱 MI와 혼동하지 말고 실제 원인 해결 |
| 새 코드가 안 보임 | Release 버전/아카이브 SHA/이미지·Pod·응답 리전 | 강사가 새 Release 준비, 승인된 새 환경에서 검증. 기존 assets 덮어쓰기 금지 |
| pod CrashLoop | 실제 앱 로그, env/포트/리소스 | 비밀 없는 로그만 확인. health를 의존 서비스로 바꾸지 않음 |
| TM Degraded | 아직 앱 미배포인지, IP/Service/HTTP80/healthz/CIDR/tag | Lab 04 게이트 전 진행 금지 |
| 브라우저 접속 timeout | proxy/VPN/실제 공인 출구 CIDR | 승인 CIDR/NSG 확인. 0.0.0.0/0으로 우회 금지 |
| Search 오류, 인덱스 없음 | 앱 전 초기화 Job이 성공했는지 | search-index.sh와 WI RBAC 확인 |
| disabled와 오류 혼동 | 실제 outputs.features, 빈 연결 env | 의도적으로 끈 서비스만 disabled. partial 설정은 오류 |
| PG 인증/TLS 오류 | PG_USER/Secret/DB/hostname/신뢰 체인 | 실제 비밀번호 재입력, verify-full 유지 |
| Redis 인증/연결 오류 | 각 리전 키, TLS10000, OSSCluster client | 반대 리전 키를 복사하지 않음 |
| Storage primary 쓰기 실패 | read_only flag와 primary PE/RBAC | 계정 failover로 해결하지 않음 |
| secondary DNS가 PUBLIC | KRS 전용 zone의 -secondary A 레코드/PE | Pod에서 확인, zone 공유로 우회하지 않음 |
| Last Sync Time unknown | app account-scoped Reader, ARM 응답/초기 복제 | null을 완료/지연0으로 기록하지 않음 |
| sample 수치가 오래됨 | 목록 300초 캐시/복제/manifest | 5분 뒤 수동 재조회, 오류/불일치 완료 처리 금지 |
| 재업로드 layout/크기 오류 | 기존 _manifest와 동일 SIZE/FILE_COUNT인지 | 다른 프로필은 새 승인 환경. 기존 데이터를 임의 삭제하지 않음 |
| 전환 스크립트 중간 실패 | CSV ERROR, 실제 PG/EH role/TM 상태 | 역할 재확인 후 강사 통제. 반대 명령/인프라 재배포 무작정 금지 |
| KRS 상태에서 precheck 실패 | 두 endpoint Enabled/Online 평시 가정 | Lab 06의 전환 중 역할 조회 사용 |
| 두 배지 일시 불일치 | Pod DNS와 브라우저 DNS/기존 연결 | UTC 보존 후 새/시크릿 창. TTL0 캐시 purge 보장 없음 |
| pause 실패 | AKS/PG 각각 실제 state/복제 토폴로지 | partial 중지와 계속 과금 명시, 복제 끊지 않음 |
| destroy 거절 | cfg의 정확한 rg-prefix-krc/krs/global·owner·구독 | 다른 팀 이름/오래된 config가 아닌지 확인. 안전 검사 제거 금지 |
| 삭제 실패/남은 managed RG | resource lock/정책/AKS 삭제 상태 | 강사/소유자가 정리, 완료될 때까지 책임 인계 |

## Pod/이미지 진단

팀 환경을 복원하고 [common.sh](../scripts/common.sh)를 source한 세션에서 사용합니다.

```bash
aks_run primary 'kubectl -n drtest get pods,service; kubectl -n drtest get events --sort-by=.lastTimestamp'
aks_run secondary 'kubectl -n drtest get pods,service; kubectl -n drtest get events --sort-by=.lastTimestamp'
aks_run primary 'kubectl -n drtest logs deployment/drtest-app --tail=80'
```

애플리케이션 오류는 sanitized 정보를 반환하도록 되어 있어도 제출 전 로그를 검토합니다.
Secret 본문/환경 전체를 출력하는 진단 명령은 사용하지 않습니다.

## 포털 자동 배포

| 증상 | 확인/조치 |
|---|---|
| 버튼이 아직 비활성 | 강사의 실제 저장소/Release 주소가 필요. Lab 03 패키징·승인·게시 후 활성화 |
| 포털 JSON 다운로드 실패 | 익명 Release asset 접근, 파일명, URL encoding. Bicep URI는 지원하지 않음 |
| runbook 게시/hash 오류 | 원본 버전/바이트/SHA256 확인. assets를 수정했다면 새 태그로 패키징. 해시 검증 제거 금지 |
| Automation 생성 policy deny | 계정 하나의 public networking 예외 승인 필요. 업무 PaaS의 정책은 완화하지 않음 |
| ARM 성공인데 앱 없음 | Automation Jobs의 실제 job GUID와 Error/Output 확인. ARM 성공은 trigger 완료뿐 |
| MI/403 | WI subject/issuer 및 custom role·AcrPush 전파, 실제 두 AKS 범위 확인 |
| GitHub 404/401 | 공개 승인된 익명 asset인지 확인. private Release/PAT를 Secret/URI에 추가하지 않음 |
| SHA256 mismatch | 이미지/tool/runbook의 원본 버전 검토. 다른 hash로 임의 통과시키지 않음 |
| 부트스트랩 OOM/디스크 | Job conditions/Pod events, 이미지 4GiB uncompressed/2GiB compressed 제한 확인. 작은 app-only 이미지로 새 Release 준비 |
| Automation timeout/Failed, AKS Job 실행 중 | 실제 상태를 관찰. 살아 있는 Job를 삭제·재시작하지 않음. Automation 재시작은 같은 SHA Job에 재접속 |
| 앱은 준비됐으나 샘플 Failed | Automation Completed를 전체 성공으로 기록하지 않음. 샘플 Job/Last Sync Time/부트스트랩 오류 확인 |

```bash
bash scripts/bootstrap-status.sh
aks_run primary 'kubectl -n drtest get job workshop-bootstrap -o json'
aks_run primary 'kubectl -n drtest logs job/workshop-bootstrap -c bootstrap --tail=80'
```

수정 후 **동일 SHA의 살아 있는 Job**는 Automation 계정에서 같은 runbook을 Start하여
재관측할 수 있습니다. job GUID가 바뀌면 outputs의 기존 jobId 대신 포털에서 실제 새 job을 확인합니다.
`bootstrap-status.sh`가 자동으로 새 job GUID를 추측하지는 않습니다.

실패 종료한 Job를 다시 실행해야 할 때만, 강사가 자격 증명/해시/원인을 확인하고 아래
**정확한 이름**을 삭제하도록 별도 승인합니다. 활성 Job에는 실행하지 않습니다.

```bash
# 실패 종료와 강사 승인 확인 후에만 수행
aks_run primary 'kubectl -n drtest delete job workshop-bootstrap --wait=true; kubectl -n drtest delete configmap workshop-bootstrap-status --ignore-not-found=true; kubectl -n drtest delete secret workshop-bootstrap-input --ignore-not-found=true'
```

그 뒤 포털에서 동일 버전 runbook을 Start합니다. encrypted 설정 asset을 사용하므로
PG/Redis 키를 실행 매개변수에 붙이지 않습니다. 샘플 업로더는 올바른 기존 파일을 건너뛰며,
동시 uploader/자동화 작업은 금지합니다. 다른 이미지 SHA는 새 환경/별도 승인으로 취급합니다.
실패 상태의 Secret/Pod는 진단을 위해 남겨두므로 강사가 명시적으로 정리해야 합니다.

## 배포 중단으로 config output 자체가 없는 경우

`destroy.sh`는 정상 outputs를 전제로 합니다. 없는 config를 임의로 만들어
실패를 숨기지 않습니다. 강사가 Azure Portal/ARM 배포 기록에서 **실제로 생성된**
팀의 정확한 3개 RG, AKS managed RG, 구독 예산/부트스트랩 custom role을 확인하고 별도 삭제 승인을
받아 정리합니다. 구독 전체/이름 wildcard로 지우는 명령은 사용하지 않습니다.

## 강사에게 전달할 최소 정보

팀 prefix, 대상 구독 식별자(승인 채널만), 실행 단계, UTC, 비밀을 제거한 오류,
실제 Pod/PG/EH/TM 상태, 이미 성공한 변경, 아직 남은 과금 자원을 전달합니다.
비밀 값은 별도의 승인된 비밀 관리 경로로만 처리합니다.
