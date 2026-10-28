#!/usr/bin/env bash
set -Eeuo pipefail
export STATE_DIR=/work/.state CONFIG_FILE=/inputs/config.json
export AZURE_CONFIG_DIR=/work/azure DOCKER_CONFIG=/work/docker
export PATH="/work/bin:$PATH"
mkdir -p "$STATE_DIR" "$AZURE_CONFIG_DIR" "$DOCKER_CONFIG" /work/bin
source "$(dirname "$0")/common.sh"
need az jq curl sha256sum tar gzip
need_python
read_input() {
  IFS= read -r -d '' "$1" <"/inputs/$2" || [[ -n "${!1}" ]] || die "Empty input: $2"
  export "$1"
}
read_input PG_USER pgUser
read_input PG_PASSWORD pgPassword
read_input IMAGE_URI imageUri
read_input IMAGE_SHA256 imageSha256
[[ "$IMAGE_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || die 'Image SHA256 is invalid.'
[[ "$IMAGE_URI" =~ ^https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/releases/download/[^/?#]+/app-image\.tar\.gz$ ]] ||
  die 'Only approved, anonymous GitHub Release image asset URLs are supported.'
export SUBSCRIPTION_ID="$(jq -er '.primary.aks.id | split("/")[2]' "$CONFIG_FILE")"
export DRTEST_WORKLOAD_LOGIN=true
az login --service-principal -u "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID" \
  --federated-token "$(cat "$AZURE_FEDERATED_TOKEN_FILE")" --allow-no-subscriptions -o none
load_config
drill_init
trap - ERR
publish_status() {
  local phase="$1" detail="$2"
  jq -n --arg phase "$phase" --arg detail "$detail" --arg image "${APP_IMAGE:-}" \
    '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:"workshop-bootstrap-status",namespace:"drtest"},
      data:{phase:$phase,detail:$detail,image:$image,utc:(now|todateiso8601)}}' >"$STATE_DIR/bootstrap-status.json"
  aks_run primary 'kubectl apply -f bootstrap-status.json' --file "$STATE_DIR/bootstrap-status.json"
  jq -n --rawfile csv "$DRILL_LOG" \
    '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:"workshop-bootstrap-log",namespace:"drtest"},
      data:{"drill.csv":$csv}}' >"$STATE_DIR/bootstrap-drill-log.json"
  aks_run primary 'kubectl apply -f bootstrap-drill-log.json' --file "$STATE_DIR/bootstrap-drill-log.json"
}
bootstrap_exit() {
  local rc="$?"
  trap - EXIT
  if (( rc != 0 )); then
    note "Bootstrap failed in ${CURRENT_STEP:-bootstrap} (exit $rc); inspect the failed Job."
    csv_log ERROR "${CURRENT_STEP:-bootstrap}" "exit $rc" || note 'Could not persist error CSV.'
    publish_status Failed "Failed in ${CURRENT_STEP:-bootstrap}, exit $rc" || note 'Could not publish failure status; inspect Job conditions.'
  fi
  return "$rc"
}
trap bootstrap_exit EXIT
download_verified() {
  local uri="$1" sha="$2" path="$3"
  [[ "$uri" == https://* && "$sha" =~ ^[a-fA-F0-9]{64}$ ]] || die 'Invalid pinned download input.'
  curl --proto '=https' --proto-redir '=https' -fLsS --retry 3 --connect-timeout 10 --max-time 3600 "$uri" -o "$path"
  printf '%s  %s\n' "$sha" "$path" | sha256sum --check --status || die "SHA256 mismatch: ${path##*/}"
}
publish_status Importing 'Verifying release archive and transferring to private ACR without a Docker daemon.'
CURRENT_STEP=image-transfer
csv_log START "$CURRENT_STEP"
download_verified "$CRANE_URI" "$CRANE_SHA256" /work/crane.tar.gz
tar -xzf /work/crane.tar.gz -C /work/bin crane
download_verified "$KUBECTL_URI" "$KUBECTL_SHA256" /work/bin/kubectl
chmod 700 /work/bin/crane /work/bin/kubectl
download_verified "$IMAGE_URI" "$IMAGE_SHA256" /work/app-image.tar.gz
gzip -dc /work/app-image.tar.gz >/work/app-image.tar
registry="$(cfg '.primary.acr.name')"
login_server="$(cfg '.primary.acr.loginServer')"
export APP_IMAGE="$login_server/drtest-app:release-${IMAGE_SHA256,,}"
token=''
for attempt in {1..20}; do
  if token="$(az acr login --name "$registry" --expose-token --query accessToken -o tsv)"; then break; fi
  (( attempt < 20 )) || die 'ACR Workload Identity authorization did not propagate.'
  sleep 30
done
[[ -n "$token" && "$token" != null ]] || die 'ACR token missing.'
printf '%s' "$token" | crane auth login "$login_server" --username 00000000-0000-0000-0000-000000000000 --password-stdin
unset token
crane push /work/app-image.tar "$APP_IMAGE"
crane digest "$APP_IMAGE" >"$STATE_DIR/image-digest.txt"
rm -f /work/app-image.tar /work/app-image.tar.gz /work/crane.tar.gz "$DOCKER_CONFIG/config.json"
note "Private registry image verified: $APP_IMAGE"
csv_log END "$CURRENT_STEP"
export REDIS_KEY_KRC='' REDIS_KEY_KRS=''
if enabled '.features.deployRedis'; then
  export REDIS_KEY_KRC="$(az rest --method post --url "https://management.azure.com$(cfg '.primary.redis.id')/databases/default/listKeys?api-version=2026-09-01" --query primaryKey -o tsv)"
  export REDIS_KEY_KRS="$(az rest --method post --url "https://management.azure.com$(cfg '.secondary.redis.id')/databases/default/listKeys?api-version=2026-09-01" --query primaryKey -o tsv)"
  [[ -n "$REDIS_KEY_KRC" && "$REDIS_KEY_KRC" != null && -n "$REDIS_KEY_KRS" && "$REDIS_KEY_KRS" != null ]] || die 'Redis key lookup failed.'
fi
publish_status Applying 'Initializing Search, applying both applications, verifying Ready, fixed IPs and Traffic Manager.'
step initialize-search bash "$ROOT_DIR/scripts/search-index.sh"
export CONFIRM="DEPLOY APP $SUBSCRIPTION_ID $PREFIX"
step deploy-application bash "$ROOT_DIR/scripts/app-apply.sh"
unset PG_PASSWORD REDIS_KEY_KRC REDIS_KEY_KRS CONFIRM
publish_status ApplicationReady 'Both regional apps Ready and Traffic Manager Online. Sample upload/replication may still be pending.'
step upload-and-replicate bash "$ROOT_DIR/scripts/upload-sampledata.sh"
publish_status Complete 'Application ready; sample data skipped explicitly or primary upload and secondary replication/read verified.'
aks_run primary 'kubectl -n drtest delete secret workshop-bootstrap-input --ignore-not-found=true'
