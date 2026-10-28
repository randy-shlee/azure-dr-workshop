# Lab 02. 샘플 데이터와 private 복제 읽기

[이전](01-infrastructure.md) · [목차](../README.md) · [다음](03-build.md)

## 2-1. 어디서 데이터를 올리는지 확인

Lab 01의 deploy는 KRC AKS 안에서 Workload Identity Job으로 업로드합니다.
PC/deploymentScripts가 Storage에 데이터를 보내지 않습니다. 읽을 소스:

- [Job](../../k8s/jobs/sampledata-upload.yaml)
- [업로드 실행기](../../scripts/upload-sampledata.sh)
- [업로드/검증 프로그램](../../scripts/sampledata-program.sh)

AZCOPY bench 옵션/인증 버전 차이 대신 현재 구현은 스트림/작은 파일 배치를 사용하며
기존 올바른 크기의 blob을 건너뜁니다. 파일 수/용량 검증 후에만
`sampledata/_manifest.json`을 기록합니다.

새 터미널은 [환경 복원](01-infrastructure.md#새-터미널에서-복원)을 먼저 수행합니다.

```bash
jq '.sampleData' "$CONFIG_FILE"
aks_run primary 'kubectl -n drtest get job,pods'
az storage account show --ids "$(cfg '.primary.storage.id')" \
  --expand geoReplicationStats \
  --query '{secondary:secondaryLocation,replication:geoReplicationStats}' -o json
```

`.sampleData.skip`은 false여야 합니다. true로 사전 배포된 환경이면 강사와
훈련 전 파라미터를 재검토하세요. 파일의 skip 값만 편집해 배포를 완료한 것으로
꾸미지 않습니다.

## 2-2. Job / manifest / 복제 결과 확인

```bash
aks_run primary 'kubectl -n drtest logs job/sampledata-upload -c upload --tail=20'
aks_run secondary 'kubectl -n drtest get job sampledata-verify'
aks_run primary 'kubectl -n drtest get configmap workshop-bootstrap-status -o json'
```

정상 업로드 로그에는 `UPLOAD_MANIFEST`, 정상 secondary 검증 로그에는
`SECONDARY_READ_VERIFIED`가 있습니다. Job가 아직 생성되지 않았다면 현재
부트스트랩 단계가 어디인지 먼저 확인하세요. 앱 준비 뒤 샘플을 시작합니다.
없는 Job를 정상으로 기록하지 않습니다. manifest는 업로드 로그 또는
브라우저 `/api/sampledata`에서 확인합니다. 포털 경로의 로컬 PC에
`upload-manifest.json`이 자동 복사되지는 않습니다.

포털 자동화의 시작/종료/오류 CSV는 KRC ConfigMap에도 보관합니다.
실제 복제 완료 시각을 이후 DR 관측 CSV와 비교할 수 있습니다.

```bash
aks_run primary 'kubectl -n drtest get configmap workshop-bootstrap-log -o json' \
  | jq -r '.data["drill.csv"]' >"$STATE_DIR/bootstrap-drill.csv"
```

업로드 스크립트는 기본 10분 간격으로 Last Sync Time을 확인하고,
manifest 업로드 이후의 fence 시각에 도달하면 KRS Job에서 파일 목록/실제 range 읽기를 검증합니다.
기본 복제 대기 상한은 48시간으로, 수업 내 완료를 보장하지 않습니다.
시각은 업로드 시작/끝, Last Sync Time, 관측한 복제 완료 시각을 각각 기록합니다.

업로드 또는 검증 실패 후 원인을 해결하고, 기존 bootstrap Job이 더 이상 실행 중이
아닌지 강사가 확인했을 때만 다음으로 재개합니다. 동시 재실행하지 않습니다.
성공한 Job를 관찰하려고 매번 재실행할 필요는 없습니다.

```bash
# 실패 복구용: 올바른 기존 파일은 건너뛰고 manifest/replication을 다시 검증
bash scripts/upload-sampledata.sh
```

현재 layout과 다른 manifest, 잘못된 크기의 기존 파일은 오류입니다.
10GiB → 100GiB 확장은 기존 container에 덮어쓰는 실습이 아닙니다.
대량 실험은 별도 승인한 새 환경/prefix에서 100/20,000 설정으로 시작하세요.

## 2-3. KRS secondary DNS 레코드 확인

```bash
ACCOUNT="$(cfg '.primary.storage.name')"
KRS_RG="$(cfg '.secondaryResourceGroup')"
az network private-dns record-set a show -g "$KRS_RG" \
  -z privatelink.blob.core.windows.net -n "${ACCOUNT}-secondary" \
  --query aRecords -o json
```

KRS VNet 전용 zone의 `<account>-secondary`가 10.20.* PE를 가리켜야 합니다.
PC에서 nslookup한 결과로 Pod의 사설 DNS를 판정하지 않습니다.
Pod 내부 실제 조회는 앱 배포 후 Lab 05에서 수행합니다.
KRC 별도 zone은 secondary 조회를 위해 KRS PE 주소를 명시적으로 갖고 있으며,
global peering을 경유합니다. zone 자체를 두 VNet에 공유하지 않습니다.

**Storage 계정 failover는 하지 않습니다.** 이 과정은 RA-GRS secondary 읽기이며
계정 쓰기 리전은 계속 KRC입니다. 계정 failover/failback 시간 및 위험을
TM/PG/EH 전환과 혼동하지 마세요.

## 2-4. Search 초기화

포털의 full 자동 배포는 앱 배포 전에 Search를 초기화합니다.
아래는 인덱스 복구가 필요하고 bootstrap이 더 이상 실행 중이지 않을 때만 실행합니다.

```bash
if enabled '.features.deployAiSearch'; then
  bash scripts/search-index.sh
else
  printf 'Search disabled: index lab excluded.\n'
fi
```

인덱스는 양 리전에 독립적으로 `dr-samples`를 만듭니다.
두 Search의 문서가 자동 geo-replication된다고 설명하지 않습니다.

## 완료 게이트

- [ ] 실제 파일 수/용량과 manifest 확인
- [ ] Last Sync Time/fence 및 KRS 검증 Job의 실제 읽기 성공 확인
- [ ] Storage secondary 위치와 KRS private DNS 레코드 확인
- [ ] Search 초기화 또는 승인된 disabled 상태 구별
- [ ] 미완료 복제는 보류로 기록하고 전환 실습을 시작하지 않음
