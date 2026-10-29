#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
enabled '.features.deployEventHubs' || die 'Event Hubs is disabled.'
enabled '.features.enableEventHubsGeoRecovery' || die 'Standard Geo-recovery is disabled; deploy and verify a metadata pairing first.'
action="${1:-status}"
api=2024-01-01
alias_name="$(cfg '.eventHubs.aliasName')"
get_alias() {
  local key="$1" doc entry url
  url="https://management.azure.com$(cfg ".$key.eventHubs.id")/disasterRecoveryConfigs"
  doc="$(az rest --method get --url "$url?api-version=$api" -o json)"
  entry="$(jq -e --arg alias "$alias_name" '
    if (.value | type) != "array" then error("Invalid Geo-DR alias list")
    else [.value[] | select(.name == $alias)] |
      if length > 1 then error("Duplicate Geo-DR alias") else .[0] // {} end
    end' <<<"$doc")"
  if [[ "$(jq -r '.name // empty' <<<"$entry")" == "$alias_name" ]]; then
    # List omits pendingReplicationOperationsCount; detail GET provides it.
    az rest --method get --url "$url/$alias_name?api-version=$api" -o json
  else printf '%s\n' "$entry"; fi
}
pair_ready() {
  local primary="$1" secondary="$2"
  MSYS_NO_PATHCONV=1 jq -en --argjson primary "$primary" --argjson secondary "$secondary" \
    --arg primaryId "$(cfg '.primary.eventHubs.id')" --arg secondaryId "$(cfg '.secondary.eventHubs.id')" '
    $primary.properties as $p | $secondary.properties as $s |
    $p.role == "Primary" and $s.role == "Secondary" and
    $p.provisioningState == "Succeeded" and $s.provisioningState == "Succeeded" and
    $p.pendingReplicationOperationsCount == 0 and
    ($p.partnerNamespace // "" | ascii_downcase) == ($secondaryId | ascii_downcase) and
    ($s.partnerNamespace // "" | ascii_downcase) == ($primaryId | ascii_downcase)
  ' >/dev/null
}
active_secondary() {
  jq -e '.properties.role == "PrimaryNotReplicating" and .properties.provisioningState == "Succeeded"' <<<"$1" >/dev/null
}
wait_ready() {
  local key="$1" start=$SECONDS primary secondary
  while (( SECONDS - start < ${EH_TIMEOUT_SECONDS:-3600} )); do
    secondary="$(get_alias secondary)"
    if jq -e '.properties.provisioningState == "Failed"' <<<"$secondary" >/dev/null; then
      die 'Event Hubs metadata recovery configuration failed.'
    fi
    if [[ "$key" == secondary || "$key" == active ]] && active_secondary "$secondary"; then
      note 'KRS owns the active alias. Pairing is removed; re-protect with a NEW empty namespace.'
      return
    fi
    if [[ "$key" == primary ]] && active_secondary "$secondary"; then
      die 'Geo-DR already failed forward to KRS. Returning to the former primary is unsupported; use a new empty namespace.'
    fi
    primary="$(get_alias primary)"
    if jq -e '.properties.provisioningState == "Failed"' <<<"$primary" >/dev/null; then
      die 'Event Hubs metadata recovery configuration failed.'
    fi
    if [[ "$key" == primary || "$key" == active ]] && pair_ready "$primary" "$secondary"; then
      note 'Standard Geo-DR metadata pairing is synchronized; event data is NOT replicated.'
      return
    fi
    sleep "${EH_POLL_SECONDS:-20}"
  done
  die 'Event Hubs alias did not reach the required metadata/active role before timeout.'
}
case "$action" in
  status)
    primary="$(get_alias primary)"
    secondary="$(get_alias secondary)"
    jq -n --arg alias "$alias_name" --argjson primary "$primary" --argjson secondary "$secondary" \
      '{alias:$alias,dataReplicated:false,primary:$primary,secondary:$secondary,
        failback:"Not supported to the former primary; re-protect with a new empty namespace."}';;
  wait)
    if [[ "${2:-}" == active ]]; then wait_ready active
    else wait_ready "$(region_key "${2:-krc}")"; fi;;
  failover)
    target="$(region_key "${2:?Usage: eh-georecovery.sh failover krs}")"
    [[ "$target" == secondary ]] || die 'Standard Geo-DR is fail-forward only. Failback to the old KRC namespace is unsupported.'
    secondary="$(get_alias secondary)"
    if active_secondary "$secondary"; then
      note 'Event Hubs alias is already active in KRS; no second failover.'
      exit 0
    fi
    wait_ready primary
    confirm "FAILOVER EH GEO $PREFIX" CONFIRM_EH
    note 'Failing forward metadata only. Old events/checkpoints stay in KRC; consumer offsets must be reset explicitly.'
    az rest --method post --url "https://management.azure.com$(cfg '.secondary.eventHubs.id')/disasterRecoveryConfigs/$alias_name/failover?api-version=$api" -o none
    wait_ready secondary;;
  *) die 'Usage: eh-georecovery.sh [status|wait krc|wait krs|wait active|failover krs]';;
esac
