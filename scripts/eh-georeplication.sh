#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
enabled '.features.deployEventHubs' || die 'Event Hubs is disabled.'
action="${1:-status}"
if [[ "$action" == promote ]]; then
  enabled '.features.enableEventHubsGeoReplication' || die 'Geo-replication is disabled. Run configure and verify the link before promotion.'
fi
# GA OpenAPI: Microsoft.EventHub/Eventhub/stable/2026-01-01/openapi.json.
api=2026-01-01
id="$(cfg '.primary.eventHubs.id')"
url="https://management.azure.com$id"
get_namespace() { az rest --method get --url "$url?api-version=$api" -o json; }
wait_replication() {
  local target="${1:-}" start=$SECONDS doc state active
  while (( SECONDS - start < ${EH_TIMEOUT_SECONDS:-3600} )); do
    doc="$(get_namespace)"
    state="$(jq -r '.properties.provisioningState' <<<"$doc")"
    [[ "${state,,}" != failed ]] || die 'Event Hubs provisioning failed.'
    active="$(jq -r '.properties.geoDataReplication.locations[]? | select(.roleType == "Primary") | .locationName' <<<"$doc")"
    if [[ "$state" == Succeeded ]] && jq -e '.properties.geoDataReplication.locations | length == 2' <<<"$doc" >/dev/null &&
      jq -e 'all(.properties.geoDataReplication.locations[]; (.replicaState | ascii_downcase) == "active")' <<<"$doc" >/dev/null &&
      [[ -z "$target" || "$active" == "$target" ]]; then
      printf '%s\n' "$doc"; return
    fi
    sleep "${EH_POLL_SECONDS:-20}"
  done
  die 'Event Hubs geo-replication did not become ready before timeout.'
}
case "$action" in
  status) get_namespace | jq '{id,provisioningState:.properties.provisioningState,geoDataReplication:.properties.geoDataReplication}';;
  configure)
    confirm "CONFIGURE EH GEO $PREFIX"
    note 'Enabling the Korea South geo location bills a second Premium PU.'
    doc="$(get_namespace)"
    current="$(jq -r '.properties.geoDataReplication.locations[]? | select(.roleType == "Primary") | .locationName' <<<"$doc")"
    current="${current:-koreacentral}"
    if [[ "$current" == koreacentral ]]; then other=koreasouth; else other=koreacentral; fi
    lag="$(cfg '.primary.eventHubs.maxReplicationLagSeconds')"
    [[ "$lag" =~ ^[0-9]+$ ]] && (( lag >= 300 && lag <= 86400 )) ||
      die 'Asynchronous Event Hubs max replication lag must be 300..86400 seconds; zero requests synchronous replication.'
    body="$(jq -nc --arg primary "$current" --arg secondary "$other" --argjson lag "$lag" \
      '{properties:{geoDataReplication:{maxReplicationLagDurationInSeconds:$lag,locations:[{locationName:$primary,roleType:"Primary"},{locationName:$secondary,roleType:"Secondary"}]}}}')"
    az rest --method patch --url "$url?api-version=$api" --body "$body" -o none
    wait_replication "$current"
    jq '.features.enableEventHubsGeoReplication = true' "$CONFIG_FILE" >"$CONFIG_FILE.new"
    mv "$CONFIG_FILE.new" "$CONFIG_FILE"
    note 'Runtime config now enables geo drills. Set ENABLE_EH_GEO_REPLICATION=true before any future infrastructure deployment.';;
  promote)
    target="$(region_key "${2:?Usage: eh-georeplication.sh promote krc|krs}")"
    location="$(cfg ".$target.location")"
    doc="$(wait_replication)"
    current="$(jq -r '.properties.geoDataReplication.locations[] | select(.roleType == "Primary") | .locationName' <<<"$doc")"
    if [[ "$current" != "$location" ]]; then
      body="$(jq -nc --arg location "$location" '{properties:{primaryLocation:$location,force:false}}')"
      az rest --method post --url "$url/failover?api-version=$api" --body "$body" -o none
      wait_replication "$location"
    else note "Event Hubs already primary in $location."; fi;;
  *) die 'Usage: eh-georeplication.sh [status|configure|promote krc|promote krs]';;
esac
