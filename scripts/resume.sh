#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
order="$(pg_order start)"
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  state="$(az postgres flexible-server show -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" --query state -o tsv)"
  if [[ "${state,,}" == stopped ]]; then
    note "Starting PostgreSQL $key (current replica first, then primary)."
    az postgres flexible-server start -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" -o none
  fi
done <<<"$order"
for key in primary secondary; do
  state="$(az aks show -g "$(region_rg "$key")" -n "$(cfg ".$key.aks.name")" --query powerState.code -o tsv)"
  if [[ "${state,,}" == stopped ]]; then az aks start -g "$(region_rg "$key")" -n "$(cfg ".$key.aks.name")" -o none; fi
done
note 'Services resumed. Run scripts/drill/00-precheck.sh before a drill.'
