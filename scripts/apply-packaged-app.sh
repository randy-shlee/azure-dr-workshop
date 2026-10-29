#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
: "${APP_IMAGE:?A verified private ACR image is required}"
: "${PG_USER:?PostgreSQL login is required}"
: "${PG_PASSWORD:?PostgreSQL password is required}"
export REDIS_KEY_KRC='' REDIS_KEY_KRS=''
if enabled '.features.deployRedis'; then
  for key in primary secondary; do
    value="$(az rest --method post \
      --url "https://management.azure.com$(cfg ".$key.redis.id")/databases/default/listKeys?api-version=2026-09-01" \
      --query primaryKey -o tsv)"
    [[ -n "$value" && "$value" != null ]] || die "$key Redis key lookup failed."
    if [[ "$key" == primary ]]; then REDIS_KEY_KRC="$value"; else REDIS_KEY_KRS="$value"; fi
  done
  unset value
fi
bash "$ROOT_DIR/scripts/search-index.sh"
export CONFIRM="DEPLOY APP $SUBSCRIPTION_ID $PREFIX"
bash "$ROOT_DIR/scripts/app-apply.sh"
unset PG_PASSWORD REDIS_KEY_KRC REDIS_KEY_KRS CONFIRM
skip_sample_check=false
if enabled '.sampleData.skip'; then
  skip_sample_check=true
else
  bash "$ROOT_DIR/scripts/upload-sampledata.sh"
fi
SKIP_SAMPLE_CHECK="$skip_sample_check" bash "$ROOT_DIR/scripts/test-app.sh"
