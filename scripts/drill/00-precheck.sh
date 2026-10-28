#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../common.sh"
load_config; drill_init
need curl nslookup
check_region() {
  local key="$1" resource role definitions metric aggregation state
  state="$(az aks show -g "$(region_rg "$key")" -n "$(cfg ".$key.aks.name")" --query '{state:provisioningState,power:powerState.code}' -o json)"
  printf '%s\n' "$state"
  jq -e '.state == "Succeeded" and .power == "Running"' <<<"$state" >/dev/null || die "AKS $key is not running."
  role="$(az postgres flexible-server show -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" --query '{role:replicationRole,state:state,source:sourceServerResourceId}' -o json)"
  printf '%s\n' "$role"
  jq -e '.state == "Ready"' <<<"$role" >/dev/null || die "PostgreSQL $key is not ready."
  for resource in pg eventHubs redis search; do
    if [[ "$resource" == eventHubs ]] && ! enabled '.features.deployEventHubs'; then continue; fi
    if [[ "$resource" == redis ]] && ! enabled '.features.deployRedis'; then continue; fi
    if [[ "$resource" == search ]] && ! enabled '.features.deployAiSearch'; then continue; fi
    # Discover available metrics; do not assume primary/replica-specific metric names exist.
    definitions="$(az monitor metrics list-definitions --resource "$(cfg ".$key.$resource.id")" \
      --query '[].{name:name.value,unit:unit,aggregations:supportedAggregationTypes}' -o json)"
    printf '%s\n' "$definitions"
    while IFS=$'\t' read -r metric aggregation; do
      [[ -n "$metric" ]] || continue
      note "$key $resource role-aware metric: $metric ($aggregation); inspect missing samples rather than interpreting them as zero."
      az monitor metrics list --resource "$(cfg ".$key.$resource.id")" --metric "$metric" \
        --interval PT1M --offset 1h --aggregation "$aggregation" -o json
    done < <(jq -r '.[] | select(.name | test("^(ReplicationLagDuration|geoReplicationHealthy|physical_replication_delay_in_seconds)$";"i")) |
      [.name,(if (.aggregations | index("Maximum")) != null then "Maximum" else .aggregations[0] end)] | @tsv' <<<"$definitions")
  done
  aks_run "$key" 'kubectl -n drtest get deployment,pods,service; kubectl -n drtest rollout status deployment/drtest-app --timeout=90s'
  local host
  if enabled '.features.deployAppGateway'; then host="$(cfg ".$key.appGateway.fqdn")"; else host="$(cfg ".$key.publicIp.fqdn")"; fi
  curl --fail --silent --show-error --connect-timeout 10 --max-time 30 "http://$host${HEALTH_PATH:-/healthz}"
}
step primary-check check_region primary
step secondary-check check_region secondary
step storage-replication az storage account show --ids "$(cfg '.primary.storage.id')" --expand geoReplicationStats \
  --query '{status:geoReplicationStats.status,lastSyncTime:geoReplicationStats.lastSyncTime}' -o json
if enabled '.features.deployEventHubs' && enabled '.features.enableEventHubsGeoReplication'; then step event-hubs-status bash "$ROOT_DIR/scripts/eh-georeplication.sh" status; fi
step traffic-manager tm_assert_online
# Use the caller's resolver; Azure's internal recursive resolver is not reachable outside Azure.
step dns nslookup "$(cfg '.trafficManager.fqdn')"
step global-health curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
  "http://$(cfg '.trafficManager.fqdn')${HEALTH_PATH:-/healthz}"
