# Lab 02. 10 GB·복제·실제 보조 읽기

[이전](01-infrastructure.md) · [목차](../README.md) · [다음: 패키지 해설](03-build.md)

## 2-1. 자동 샘플과 업로드 버튼

기본 단일 배포 명령은 앱 준비 후 **KRC sampledata-upload Job → 복제 fence →
KRS sampledata-verify Job**을 실행합니다. 정상 환경을 관찰하려고 Job을 재생성하지 않습니다.
별도 cloud Automation/부트스트랩 ConfigMap을 완료 기준으로 쓰지 않습니다.

코드: [Job](../../k8s/jobs/sampledata-upload.yaml), [실행기](../../scripts/upload-sampledata.sh),
[프로그램](../../scripts/sampledata-program.sh), [공유 layout](../../app/sample_layout.py),
[버튼 worker](../../app/sample_upload.py).
CLI/양 앱은 같은 Blob lease를 사용합니다. 샘플 MI는 양 AKS OIDC issuer의
`system:serviceaccount:drtest:sampledata-upload`를 신뢰합니다.

| 기본 데이터 파일 | 수 / 크기 |
|---|---|
| large | 1 GiB 7개 + 386,655,232 bytes 1개 |
| small | 1 MiB 2,000개 |
| 합계 | **2,008개 / 10,000,000,000 bytes** |

manifest/control JSON은 payload 수/크기에 더하지 않습니다.
버튼은 서버 생성·업로드/재개이며 PC 파일 선택 기능이 아닙니다.
CLI와 버튼 모두 고정 상한 decimal 10 GB를 넘길 수 없고, 올바른 기존 파일을 재사용합니다.
기존 다른 manifest/잘못된 크기의 데이터는 명시적으로 실패하고 자동 삭제하지 않습니다.

## 2-2. 실행 결과

[환경 복원](01-infrastructure.md#새-터미널에서-복원) 후:

```bash
jq '.sampleData' "$CONFIG_FILE"
aks_run primary 'kubectl -n drtest get job sampledata-upload'
aks_run secondary 'kubectl -n drtest get job sampledata-verify'
aks_run primary 'kubectl -n drtest logs job/sampledata-upload -c upload --tail=20'
aks_run secondary 'kubectl -n drtest logs job/sampledata-verify -c upload --tail=20'
```

`skip=false`, 양 Job Complete, `UPLOAD_MANIFEST`와 `SECONDARY_READ_VERIFIED`를 봅니다.
그다음 **양 지역 앱의 샘플 데이터 확인**에서 모두 확인합니다.

- primary/secondary의 실제 전체 수/크기 = 2,008개/10 GB.
- 양 manifest 종료 fence 일치, 실제 1 MiB range 읽기 성공.
- Last Sync Time ≥ 최종 manifest 종료, `replication_complete=true`.

CLI manifest는 `actualFileCount/actualBytes`, 버튼 manifest는 `count/bytes`를 표시합니다.
필드 이름을 혼동하지 말고 실제 inventory도 함께 대조합니다.
예: `curl --fail --silent --show-error "http://$(cfg '.primary.publicIp.fqdn')/api/sampledata" | jq .`
HTTP 200이나 `test-app.sh` 성공만으로 복제 완료를 판정하지 않습니다.

## 2-3. 버튼 재개와 캐시

자동 생성된 동일 layout에서도 버튼 재개를 체험할 수 있습니다.
확인 후 시작 → 진행/오류 조회 → completed → **새 manifest fence의 복제 재확인** 순서입니다.
목록은 endpoint별 **300초 캐시**, Last Sync Time과 업로드 완료는 별도 상태입니다.
다른 앱의 오래된 manifest/집계가 남으면 5분 뒤 다시 확인합니다.
복제 대기는 실행기 기본 최대 48시간이며 수업 내 완료를 보장하지 않습니다.

기존 `drws1028a`의 과거 초과 샘플은 보존하고 새 상한 검증에는 별도 컨테이너를 사용했습니다.
재실행/다른 컨테이너 선택은 강사가 실제 설정과 lease/Job 상태를 확인한 후에만 수행합니다.

## 2-4. 사설 DNS와 Search

이 단계의 `-secondary`는 **첫 전환 전 복제 probe**입니다. 전환 후 일반 읽기 경로가 아닙니다.
Pod의 실제 해석은 [Lab 05](05-baseline.md)에서 확인하며 PC nslookup으로 대체하지 않습니다.
Blob은 KRC 생성 계정 하나이고 두 VNet PE는 같은 계정의 접근 지점입니다.

양 `dr-samples` Search 인덱스는 앱 배포 전에 자동 초기화합니다.
독립 인덱스이므로 이후 문서가 자동 geo-replication된다고 설명하지 않습니다.
`search-index.sh`/`upload-sampledata.sh`는 정상 배포 뒤 필수 재실행 단계가 아니라 승인된 복구용입니다.

## 완료 게이트

- [ ] CLI Job와 실제 양 앱의 manifest/파일/용량·읽기/fence 확인
- [ ] 버튼 재개 후 새 fence와 캐시를 구별
- [ ] 복제 미완료/오류면 DR 보류, 기존 데이터 보존
