#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
need kubectl
[[ -n "${ACR_AGENT_POOL:-}" ]] ||
  die 'Private ACR build needs ACR_AGENT_POOL: an existing VNet-connected ACR Tasks pool (preview, billed separately). Public access will NOT be enabled.'
[[ -n "${PG_PASSWORD:-}" ]] || die 'Export PG_PASSWORD for the test-only Kubernetes Secret; do not put it in ConfigMaps.'
[[ -n "${PG_USER:-}" ]] || die 'Export PG_USER matching the infrastructure administrator login (never exported by secure Bicep parameters).'
if enabled '.features.deployRedis'; then
  [[ -n "${REDIS_KEY_KRC:-}" && -n "${REDIS_KEY_KRS:-}" ]] ||
    die 'Export REDIS_KEY_KRC and REDIS_KEY_KRS from the respective Managed Redis databases.'
fi
registry="$(cfg '.primary.acr.name')"
pool="$(az acr agentpool show -r "$registry" -n "$ACR_AGENT_POOL" -o json)"
jq -e '.provisioningState == "Succeeded" and (.virtualNetworkSubnetResourceId | type == "string" and length > 0) and .count > 0' <<<"$pool" >/dev/null ||
  die 'ACR agent pool must be provisioned, running and connected to a subnet with private DNS/ACR PE reachability.'
confirm "DEPLOY APP $SUBSCRIPTION_ID $PREFIX"
tag="${APP_TAG:-drtest-$(date -u +%Y%m%d%H%M%S)}"
[[ "$tag" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || die 'APP_TAG is not a valid container image tag.'
[[ "$ACR_AGENT_POOL" =~ ^[a-zA-Z0-9_-]+$ ]] || die 'Invalid ACR_AGENT_POOL name.'
# Only app/ is uploaded. Never send the workspace, .state or secret files.
# Agent pools are preview and must be prepared/approved by the operator:
# https://learn.microsoft.com/azure/container-registry/tasks-agent-pools
(
  cd "$ROOT_DIR/app"
  az acr build --registry "$registry" --agent-pool "$ACR_AGENT_POOL" \
    --image "drtest-app:$tag" --file Dockerfile --platform linux/amd64 .
)
export APP_IMAGE="$(cfg '.primary.acr.loginServer')/drtest-app:$tag"
export CONFIRM="DEPLOY APP $SUBSCRIPTION_ID $PREFIX"
bash "$ROOT_DIR/scripts/app-apply.sh"
