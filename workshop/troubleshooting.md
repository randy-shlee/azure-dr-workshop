# 문제 해결 — 현재 로컬 v1.0.7 기준

[목차](README.md) · [환경 복원](labs/01-infrastructure.md#새-터미널에서-복원) ·
[실증 보고서](releases/v1.0.7-validation.md)

먼저 구독/prefix/실제 config와 작업 단계부터 확인합니다.
`env`/`printenv`, Secret 전체, 암호·키·토큰·인증서, `bash -x`/Azure debug 로그를 공유하지 않습니다.

## 배포와 앱

| 증상 | 확인 / 조치 |
|---|---|
| 인프라만 보임 | 로컬 deployment-status의 phase/오류 확인. ARM Succeeded만으로 앱 완료 아님 |
| 없는 Automation/부트스트랩 ConfigMap | 현재 로컬 경로는 생성하지 않음. 해당 상태를 만들지 말고 tools 작업의 JSON/실제 앱 확인 |
| 오래 대기 | 실제 ARM 단계인지 이미지/Job/복제인지 확인. 약 49분은 한 번의 관측이며 고정 제한 아님 |
| 원본 SHA/blocked 오류 | 같은 버전 assets인지 확인. hash/blocked 검사를 제거하지 말고 검증한 v1.0.7 사용 |
| 새 prefix 충돌 | 기존 세 RG를 덮어쓰지 않음. 새 이름/실패 잔여 정리를 소유자가 결정 |
| 기존 PG/Redis 전체 재배포 실패 | 비멱등 update 경로. replica/DB/peer 삭제·forceUnlink 금지. 새 환경 또는 명시적 앱 업데이트 |
| 스크립트/DR 코드가 없음 | 원본 tools는 배포용. 전달본 source에서 운영 코드 사용 |
| 잘못된 config/없는 config | 실제 tools 작업의 config를 지정하고 구독/prefix 검증. 다른 deployment outputs로 추정하지 않음 |
| 이미지 push 실패 | 자체 Azure mTLS/CIDR/ACR PE·DNS·한정 push 권한/전파. ACR admin/public/bypass 우회 금지 |
| ImagePullBackOff | 정확한 태그/이벤트, **kubelet** AcrPull, registry/data PE·DNS |
| Pod CrashLoop | 실제 앱 로그/포트/리소스. health를 의존 서비스 probe로 바꾸지 않음 |
| 앱 timeout/TM Degraded | HTTP 주소, 브라우저 실제 출구 CIDR, Service IP/NSG/healthz/TM probe |
| PG TLS/인증 | 실제 테스트 암호/DB/hostname/CA. TLS 검증 비활성화 금지 |
| Redis 오류 | 지역별 키/TLS10000/OSSCluster FQDN remap. 다른 리전 키 복사 금지 |
| Search 인덱스 없음 | 자동 초기화 단계/WI 역할. 정상 환경에 반복 seed하지 않음 |
| 임시 엔진 정리 실패 | 보호된 recovery 상태를 보존하고 해당 config/StateDirectory로 helper Stop. 자격 증명/2376 방치 금지 |

조회는 환경을 복원한 Bash에서:

```bash
aks_run primary 'kubectl -n drtest get pods,service; kubectl -n drtest get events --sort-by=.lastTimestamp'
aks_run secondary 'kubectl -n drtest get pods,service; kubectl -n drtest get events --sort-by=.lastTimestamp'
aks_run primary 'kubectl -n drtest logs deployment/drtest-app --tail=80'
```

민감 정보는 공유 전에 검토합니다. 원인 해결 없이 새 코드/키/manifest를 겹쳐 적용하지 않습니다.

## 업로드와 복제

| 증상 | 확인 / 조치 |
|---|---|
| 업로드 409 | 같은 Blob lease를 CLI/양 앱이 공유. 진행 상태 관찰, 강제로 lease 끊지 않음 |
| 400/403 | 크기/대상 입력 금지, 같은 Origin과 명시적 10GB 확인 필요. cross-origin 우회 금지 |
| 업로드 disabled | 실제 `sampleData.uploadEnabled`/앱 설정. 토글만 바꿔 검증 완료라고 쓰지 않음 |
| manifest/크기 불일치 | 기존 데이터 보존, 명시적 승인 아래 다른 설정 컨테이너/환경 사용. 자동 삭제 금지 |
| completed인데 복제 미완료 | 최종 manifest fence와 Last Sync Time 비교. 재개로 종료 시각이 바뀌면 재확인 |
| 2,008개인데 크기 필드가 없음 | CLI는 actualFileCount/actualBytes, 버튼은 count/bytes. 실제 inventory도 대조 |
| 숫자가 오래됨/지역별 다름 | endpoint별 목록 캐시 300초. 5분 뒤 양 앱에서 재조회 |
| Last Sync Time null | ARM Reader 권한/초기 복제/응답 확인. null을 완료·지연0으로 처리 금지 |
| KRS WI/403 | 공유 샘플 MI의 **KRS OIDC issuer**/subject federation와 역할 확인 |
| SDK etag TypeError | v1.0.6 계열 사용 금지. 수정 v1.0.7의 IfMissing-only commit 사용 |
| 과거 10 GiB 예산 데이터 | 새 decimal 10 GB 증거로 바꾸지 말고 별도 보존 |

Job/로그와 실제 읽기/fence의 기준은 [Lab 02](labs/02-data.md)를 따릅니다.

## DR

| 증상 | 확인 / 조치 |
|---|---|
| 전환 중간 실패 | CSV ERROR, 실제 Storage/PG/EH/TM 역할부터 확인. 반대 명령/전체 재배포 금지 |
| Storage 오래 대기 | Planned 실제 작업/primaryLocation/복제 확인. 수 시간 허용, unplanned/중복 전환 금지 |
| PG Premium_LRS | 로컬 디스크 정상. 지역 DR는 서버 replica/aliases |
| EH failover 후 페어링 사라짐 | 정상 fail-forward 결과. 이전 primary failback/자동 re-pair 금지 |
| KRC 앱 원복 후 EH KRS | 의도된 상태. 양 VNet→양 namespace PE/RBAC/alias 실제 접근 확인 |
| 원복 뒤 wait krc/precheck 실패 | 첫 baseline을 다시 강요하지 않음. Lab 06의 사후 역할/데이터 조회 사용 |
| EH payload/offset 누락 | metadata만 전환. consumer 시작 위치/중복·누락/replay 계획. 기존 이벤트 보존 |
| EH 403 | 양 namespace의 앱 RBAC/PE/DNS. RBAC는 복제되지 않음 |
| 두 배지 일시 불일치 | UTC 보존 후 필요 시 새/시크릿 창. TTL0도 cache purge 보장 없음 |
| 화면만 KRS | backend primary 증명 아님. 관리 역할+같은 ID 쓰기/읽기 확인 |

정확한 순서는 [Lab 06](labs/06-drill.md)이며 Storage → EH → PG → TM입니다.
실제 DR는 아직 실증하지 않았고 문서 정리는 그 실증을 대신하지 않습니다.

## 실패 배포에 config가 없는 경우

`destroy.sh`는 정상 config를 전제로 합니다. 없는 outputs를 임의로 만들어 실패를 숨기지 않습니다.
포털/ARM에서 실제 생성된 **정확한** RG/managed RG/서비스를 소유자가 확인하고 별도 승인합니다.
paired EH라면 양 대상 확인 후 Break pairing을 수행하고 남은 alias도 삭제합니다.
pairing 해제 성공만으로 namespace를 삭제할 수 있는 것은 아니므로 양쪽 alias 부재를 확인합니다.
`MetadataDRCannotDeleteWhenAliasPresentConflict`를 방치한 채 삭제 완료라고 쓰지 않습니다.
잠금/정책/서비스 실패/권한 오류를 부재로 간주하지 않습니다.
구독 전체나 wildcard 삭제 명령은 사용하지 않습니다.

## 선택적 포털과 과거 기록

공개 v1.0.3/과거 Draft를 현재 코드의 복구 수단으로 실행하지 않습니다.
포털/Automation은 공개 승인·같은 버전 assets·별도 새 환경 실증이 필요한 다른 경로입니다.
초기 AKS/Network/Search/Premium 제한과 core-repair 기록은 과거 이력이며
현재 v1.0.7 앱/샘플을 미검증이라고 설명할 근거가 아닙니다.

강사에게는 prefix/승인된 구독 식별자, UTC/실제 단계, 민감 정보를 제거한 오류,
성공한 변경·현재 역할·남은 과금 자원만 전달합니다.
