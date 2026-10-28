#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
# Support depends on current service/topology. Attempt the real stop and fail clearly
# if rejected; never detach a replica or perform standalone promotion to save money.
# https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server
order="$(pg_order stop)"
confirm "PAUSE $PREFIX"
for key in primary secondary; do
  az aks stop -g "$(region_rg "$key")" -n "$(cfg ".$key.aks.name")" -o none
done
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  state="$(az postgres flexible-server show -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" --query state -o tsv)"
  if [[ "${state,,}" != stopped ]]; then
    note "Stopping PostgreSQL $key (current primary first, then replica)."
    if ! az postgres flexible-server stop -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" -o none; then
      die "Azure rejected PostgreSQL stop for $key in the current topology. AKS is already stopped; PostgreSQL may remain billable. No replication roles were changed. Resume/reconcile before another drill."
    fi
  fi
done <<<"$order"
note 'Pause calls completed. Disks, networking, ACR, EH, Redis, Search, PG storage and blob storage remain billable. Stopped PostgreSQL auto-starts after seven days; verify real states before assuming compute savings.'
