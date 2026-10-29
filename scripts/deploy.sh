#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
azure_context
mode="${1:---deploy}"
[[ "$mode" == --deploy || "$mode" == --what-if ]] || die 'Usage: deploy.sh [--what-if|--deploy]'
[[ -f "$ROOT_DIR/infra/main.bicepparam" ]] || die 'Missing infra/main.bicepparam'
[[ -n "${PG_ADMIN_PASSWORD:-}" ]] || die 'Export PG_ADMIN_PASSWORD; never put it in a file or command argument.'
az deployment sub what-if --name "$DEPLOYMENT_NAME" --location "$LOCATION" \
  --template-file "$ROOT_DIR/infra/main.bicep" --parameters "$ROOT_DIR/infra/main.bicepparam" --validation-level Provider
[[ "$mode" == --deploy ]] || exit 0
[[ -n "${WORKSHOP_RELEASE_DIR:-}" || -n "${APP_DEPLOY_COMMAND:-}" || "${SKIP_APP_DEPLOY:-false}" == true ]] ||
  die 'Set WORKSHOP_RELEASE_DIR to the verified local package. Application deployment is automatic from that package.'
[[ "$OWNER_EMAIL" != owner@example.com && "$OWNER_EMAIL" == *@* ]] || die 'Export a real OWNER_EMAIL before deployment.'
confirm "DEPLOY $SUBSCRIPTION_ID"
# The single subscription deployment includes Traffic Manager; do not redeploy after a DR switchover.
az deployment sub create --name "$DEPLOYMENT_NAME" --location "$LOCATION" \
  --template-file "$ROOT_DIR/infra/main.bicep" --parameters "$ROOT_DIR/infra/main.bicepparam" -o none
export_config
# Refresh exported non-secret endpoints for the application deployment hook.
load_config
if [[ -n "${WORKSHOP_RELEASE_DIR:-}" ]]; then
  need pwsh
  PG_ADMIN_PASSWORD="$PG_ADMIN_PASSWORD" pwsh -NoLogo -NoProfile -File "$ROOT_DIR/scripts/deploy-local-package.ps1" \
    -ReleaseDirectory "$WORKSHOP_RELEASE_DIR" -Prefix "$PREFIX" -SubscriptionId "$SUBSCRIPTION_ID" \
    -AllowedClientCidrs "$(cfg '.allowedClientCidrs|join(",")')" \
    -AdministratorLogin "${PG_ADMIN_LOGIN:-dradmin}" -InfrastructureConfigPath "$CONFIG_FILE"
elif [[ -n "${APP_DEPLOY_COMMAND:-}" ]]; then
  bash "$ROOT_DIR/scripts/gen-app-config.sh"
  if enabled '.features.deployAiSearch'; then bash "$ROOT_DIR/scripts/search-index.sh"; fi
  note 'Running user-supplied Prompt 2 application deployment hook.'
  bash -Eeuo pipefail -c "$APP_DEPLOY_COMMAND"
  if ! enabled '.sampleData.skip'; then bash "$ROOT_DIR/scripts/upload-sampledata.sh"; fi
elif [[ "${SKIP_APP_DEPLOY:-false}" == true ]]; then
  note 'PENDING: Prompt 2 application was explicitly skipped. No application or healthy DR endpoint is claimed.'
  exit 0
else
  die 'Infrastructure complete; application PENDING. Set APP_DEPLOY_COMMAND to deploy Prompt 2, or explicitly SKIP_APP_DEPLOY=true.'
fi
bash "$ROOT_DIR/scripts/drill/00-precheck.sh"
