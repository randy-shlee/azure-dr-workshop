# Lab 04. 자동 배포된 같은 이미지를 KRC/KRS에서 확인

[이전](03-build.md) · [목차](../README.md) · [다음](05-baseline.md)

기본 포털 경로는 이미 두 앱을 자동 배포합니다. 고객은 아래 4-0 및 4-4~4-5로
검증하며, **4-1~4-3은 강사 승인 하의 선택적 수동 복구/코드 해설**입니다.
AKS 접속은 private API에 직접 붙지 않고 **command invoke**를 사용합니다.

## 4-0. 자동 배포 완료 게이트

[환경 복원](01-infrastructure.md#새-터미널에서-복원) 후:

```bash
bash scripts/bootstrap-status.sh --wait-app
aks_run primary 'kubectl -n drtest get configmap workshop-bootstrap-status -o json'
```

Automation Completed와 ApplicationReady/Complete를 확인합니다.
이미지 태그는 `drtest-app:release-<Release 아카이브 SHA256>`입니다.
Secret 값을 조회할 필요는 없습니다. 샘플 완료는 Lab 02에서 별도로 확인합니다.
실패하면 아래 수동 적용을 무작정 실행하지 말고 먼저 원인을 해결합니다.

## 4-1. 선택적 복구: non-secret 설정 생성과 로컬 Kustomize 렌더

[환경 복원](01-infrastructure.md#새-터미널에서-복원)을 수행하고, 실제 ACR의 기존
이미지 전체 경로를 APP_IMAGE로 export합니다. 이 절차는 이미지를 다시 빌드하지 않습니다.

```bash
: "${APP_IMAGE:?실제 ACR의 기존 이미지 전체 경로를 export하세요}"
printf 'subscription=%s prefix=%s image=%s\n' "$SUBSCRIPTION_ID" "$PREFIX" "$APP_IMAGE"
export PG_USER="$PG_ADMIN_LOGIN"
export PG_DB=postgres
bash scripts/gen-app-config.sh
kubectl kustomize k8s/overlays/krc >"$STATE_DIR/app-krc.yaml"
kubectl kustomize k8s/overlays/krs >"$STATE_DIR/app-krs.yaml"
jq '.data | {REGION,STORAGE_READ_MODE,PG_HOST,EH_NAMESPACE,REDIS_HOST,
              SEARCH_ENDPOINT,AZURE_CLIENT_ID}' k8s/overlays/krs/configmap.yaml
```

로컬 렌더는 Kubernetes API에 접속하지 않습니다. 생성한 두 manifest에서
같은 APP_IMAGE, replicas 1, 포트 8000, resources 요청 100m/128Mi·제한 500m/256Mi,
WI label/ServiceAccount, no secret literal을 확인합니다.

KRS는 secondary 읽기, Redis/Search는 KRS, PG writer/EH namespace는 두 리전에서
동일합니다. 별도 DB는 만들지 않으므로 기본 `postgres` DB를 사용합니다.
workload identity webhook이 Pod에 tenant/token-file 환경과 토큰 볼륨을 주입합니다.
ACR 이미지 pull은 앱 MI가 아니라 **kubelet MI의 AcrPull**입니다.

공용 Service의 allow IP 범위와 AzureTrafficManager tag는 NSG 레이어 필터입니다.
AKS가 금지하는 `loadBalancerSourceRanges` + tag 조합을 다시 추가하지 않습니다.

## 4-2. 테스트용 Secret 값을 메모리에 준비

PG 비밀번호는 인프라 배포 때 입력한 것과 같아야 합니다.
기존 환경을 인수했으면 조직의 승인된 비밀 전달 수단을 사용하세요.

```bash
read -rs -p 'Test PostgreSQL password: ' PG_PASSWORD; echo
export PG_PASSWORD
if enabled '.features.deployRedis'; then
  # ARM control plane에서 읽되 stdout/파일/셸 이력으로 키를 출력하지 않음
  export REDIS_KEY_KRC="$(az rest --method post \
    --url "https://management.azure.com$(cfg '.primary.redis.id')/databases/default/listKeys?api-version=2026-09-01" \
    --query primaryKey -o tsv)"
  export REDIS_KEY_KRS="$(az rest --method post \
    --url "https://management.azure.com$(cfg '.secondary.redis.id')/databases/default/listKeys?api-version=2026-09-01" \
    --query primaryKey -o tsv)"
  [[ -n "$REDIS_KEY_KRC" && "$REDIS_KEY_KRC" != null && -n "$REDIS_KEY_KRS" && "$REDIS_KEY_KRS" != null ]] ||
    { printf 'Redis key lookup failed; stop and ask the instructor.\n' >&2; exit 1; }
else
  export REDIS_KEY_KRC='' REDIS_KEY_KRS=''
fi
```

Redis listKeys 권한이 없으면 강사가 해결합니다. 공개 endpoint/다른 인증 방식으로
우회하지 않습니다. Secret 전체를 조회하거나 `echo "$REDIS_KEY_KRC"`를 실행하지 마세요.
아래 실습은 테스트 전용 Kubernetes Secret이며 운영용 비밀 관리 패턴이 아닙니다.
셸 xtrace(`set -x`, `bash -x`)와 Azure debug는 끕니다.

## 4-3. 임시 Secret + manifest를 두 클러스터에 적용

실행 전에 화면의 구독/prefix/이미지를 강사와 확인하세요.
아래 블록은 실제 적용을 수행합니다. 비밀 값은 명령 문자열이 아닌 제한된 임시 파일로
첨부합니다. 기존 [aks_run](../../scripts/common.sh)이 remote exitCode/오류를 검증합니다.

```bash
(
  set -Eeuo pipefail
  umask 077
  : "${PG_PASSWORD:?테스트 PG 비밀번호가 필요합니다}"
  stage="$(mktemp -d "$STATE_DIR/workshop-app.XXXXXX")"
  trap 'rm -f -- "$stage/app-secrets.json" "$stage/app.yaml"; rmdir -- "$stage"' EXIT
  for key in primary secondary; do
    region="$(cfg ".$key.region")"
    cp "$STATE_DIR/app-$region.yaml" "$stage/app.yaml"
    if [[ "$key" == primary ]]; then secret_key="$REDIS_KEY_KRC"; else secret_key="$REDIS_KEY_KRS"; fi
    PG_PASSWORD="$PG_PASSWORD" REDIS_KEY="$secret_key" jq -n \
      '{apiVersion:"v1",kind:"Secret",metadata:{name:"drtest-app-secrets",namespace:"drtest"},
        type:"Opaque",stringData:{PG_PASSWORD:env.PG_PASSWORD,REDIS_KEY:env.REDIS_KEY}}' \
      >"$stage/app-secrets.json"
    aks_run "$key" \
      'kubectl create namespace drtest --dry-run=client -o yaml | kubectl apply -f -; kubectl apply -f app-secrets.json; kubectl apply -f app.yaml' \
      --file "$stage/app-secrets.json" "$stage/app.yaml"
  done
)
unset PG_PASSWORD PG_ADMIN_PASSWORD REDIS_KEY_KRC REDIS_KEY_KRS
```

한쪽만 적용된 뒤 실패했다면 양쪽 성공으로 기록하지 않습니다.
원인을 해결하고 필요한 비밀을 다시 입력한 후 같은 이미지로 재시도합니다.
구독/클러스터의 command invoke 권한과 관리 평면 결과에 대한 접근도 비밀 보호 경계입니다.
이미 실행 중인 Pod의 **Secret/ConfigMap 환경 변수는 apply만으로 갱신되지 않습니다.**
이미지 태그를 바꾸지 않고 설정/비밀만 고쳤다면 강사 승인 후
`aks_run primary 'kubectl -n drtest rollout restart deployment/drtest-app'`와
`aks_run secondary 'kubectl -n drtest rollout restart deployment/drtest-app'`로
Pod를 재시작한 뒤 다음 단계의 rollout을 다시 확인합니다.

## 4-4. 기본 경로: Ready와 실제 이미지 확인

```bash
aks_run primary 'kubectl -n drtest rollout status deployment/drtest-app --timeout=45s'
aks_run secondary 'kubectl -n drtest rollout status deployment/drtest-app --timeout=45s'
for key in primary secondary; do
  aks_run "$key" 'kubectl -n drtest get deployment drtest-app -o jsonpath="{.spec.template.spec.containers[0].image}"; echo; kubectl -n drtest get pods -l app=drtest-app'
done
```

45초 timeout은 짧은 관측 창입니다. 이미지 pull 중이면 상태/이벤트를 확인한 뒤
재조회하며, timeout을 Ready로 기록하지 않습니다. 각 리전 ready Pod 1개와
Lab 03의 아카이브 SHA256으로 만든 동일한 이미지 태그가 필요합니다.

## 4-5. Service 고정 IP와 Traffic Manager 확인

본 워크숍은 App Gateway를 끈 공용 LB 모드입니다.

```bash
for key in primary secondary; do
  service="$(aks_run "$key" 'kubectl -n drtest get service drtest-app -o json')"
  actual="$(jq -r '.status.loadBalancer.ingress[0].ip // ""' <<<"$service")"
  expected="$(cfg ".$key.publicIp.address")"
  printf '%s expected=%s actual=%s\n' "$key" "$expected" "$actual"
  [[ "$actual" == "$expected" ]] || { printf 'Service IP pending/mismatch; stop.\n' >&2; exit 1; }
done
az network traffic-manager profile show --ids "$(cfg '.trafficManager.id')" \
  --query 'endpoints[].{name:name,status:endpointStatus,monitor:endpointMonitorStatus}' -o table
```

EXTERNAL-IP가 pending이면 잠시 기다렸다 같은 조회를 반복합니다.
두 endpoint 모두 Enabled/Online이 된 후 아래 게이트를 실행합니다.
Online은 의존 서비스 전체의 성공이 아니라 `/healthz`의 앱 생존 확인입니다.

```bash
tm_assert_online
```

## 완료 게이트

- [ ] 두 리전 Ready, 같은 release-SHA256 태그와 준비한 앱 화면
- [ ] Secret 값은 Git/로그/제출물에 없음, 임시 파일 제거
- [ ] Service IP가 각각 인프라 Static IP와 정확히 일치
- [ ] TM 두 endpoint가 Enabled/Online
- [ ] Kubelet AcrPull과 앱 Workload Identity 역할을 구별해 설명
