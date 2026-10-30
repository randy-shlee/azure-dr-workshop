#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
need kubectl
[[ -n "${APP_IMAGE:-}" ]] || die 'APP_IMAGE must identify the already-pushed private ACR image.'
[[ -n "${PG_PASSWORD:-}" && -n "${PG_USER:-}" ]] || die 'PG_USER and PG_PASSWORD are required for test Secrets.'
if enabled '.features.deployRedis'; then
  [[ -n "${REDIS_KEY_KRC:-}" && -n "${REDIS_KEY_KRS:-}" ]] || die 'Both regional Redis keys are required.'
fi
confirm "DEPLOY APP $SUBSCRIPTION_ID $PREFIX"
export APP_CONFIG_OUTPUT_DIR="${APP_CONFIG_OUTPUT_DIR:-$ROOT_DIR/k8s/overlays}"
bash "$ROOT_DIR/scripts/gen-app-config.sh"
mkdir -p "$STATE_DIR"
stage="$(mktemp -d "$STATE_DIR/app-deploy.XXXXXX")"
trap 'rm -f -- "$stage/app.yaml" "$stage/app-secrets.json"; rmdir -- "$stage"' EXIT
regions=("$@")
(( ${#regions[@]} )) || regions=(primary secondary)
for key in "${regions[@]}"; do
  [[ "$key" == primary || "$key" == secondary ]] || die "Unexpected region key: $key"
done
for key in "${regions[@]}"; do
  region="$(cfg ".$key.region")"
  [[ "$region" == krc || "$region" == krs ]] || die "Unexpected region: $region"
  kubectl kustomize "$APP_CONFIG_OUTPUT_DIR/$region" >"$stage/app.yaml"
  if [[ "$key" == primary ]]; then secret_key="${REDIS_KEY_KRC:-}"; else secret_key="${REDIS_KEY_KRS:-}"; fi
  PG_PASSWORD="$PG_PASSWORD" REDIS_KEY="$secret_key" jq -n \
    '{apiVersion:"v1",kind:"Secret",metadata:{name:"drtest-app-secrets",namespace:"drtest"},
      type:"Opaque",stringData:{PG_PASSWORD:env.PG_PASSWORD,REDIS_KEY:env.REDIS_KEY}}' >"$stage/app-secrets.json"
  aks_run "$key" 'kubectl create namespace drtest --dry-run=client -o yaml | kubectl apply -f -; kubectl apply -f app-secrets.json; kubectl apply -f app.yaml' \
    --file "$stage/app.yaml" --file "$stage/app-secrets.json"
  start=$SECONDS
  while true; do
    deployment="$(aks_run "$key" 'kubectl -n drtest get deployment drtest-app -o json')"
    if jq -e 'any(.status.conditions[]?; (.type=="ReplicaFailure" and .status=="True") or (.type=="Progressing" and .status=="False"))' <<<"$deployment" >/dev/null; then
      jq '.status.conditions' <<<"$deployment" >&2
      die "$region application rollout failed."
    fi
    if jq -e '(.status.observedGeneration // 0) >= .metadata.generation and
      (.status.updatedReplicas // 0)==1 and (.status.availableReplicas // 0)==1 and (.status.replicas // 0)==1' <<<"$deployment" >/dev/null; then break; fi
    (( SECONDS - start < ${APP_ROLLOUT_TIMEOUT_SECONDS:-600} )) || die "$region application readiness timed out."
    sleep "${APP_POLL_SECONDS:-10}"
  done
  expected="$(cfg ".$key.publicIp.address")"
  if enabled '.features.deployAppGateway'; then expected="$(cfg ".$key.appGateway.backendAddress")"; fi
  start=$SECONDS
  while true; do
    service="$(aks_run "$key" 'kubectl -n drtest get service drtest-app -o json')"
    actual="$(jq -r '.status.loadBalancer.ingress[0].ip // ""' <<<"$service")"
    if [[ "$actual" == "$expected" ]]; then break; fi
    (( SECONDS - start < ${APP_LB_TIMEOUT_SECONDS:-600} )) ||
      die "$region Service IP '$actual' does not equal infrastructure IP '$expected'."
    sleep "${APP_POLL_SECONDS:-10}"
  done
  note "$region ready; Service IP=$actual."
done
start=$SECONDS
while true; do
  profile="$(az network traffic-manager profile show --ids "$(cfg '.trafficManager.id')" -o json)"
  if jq -e '(.endpoints|length)==2 and all(.endpoints[]; .endpointStatus=="Enabled" and .endpointMonitorStatus=="Online")' <<<"$profile" >/dev/null; then break; fi
  (( SECONDS - start < ${APP_TM_TIMEOUT_SECONDS:-900} )) || die 'Traffic Manager did not reach two Enabled/Online endpoints.'
  sleep "${APP_POLL_SECONDS:-10}"
done
note "Application ready: http://$(cfg '.trafficManager.fqdn')/ | image=$APP_IMAGE"
