#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/.state}"
CONFIG_FILE="${CONFIG_FILE:-$STATE_DIR/config.json}"
export ROOT_DIR STATE_DIR CONFIG_FILE
export PREFIX="${PREFIX:-kkbdrtest}" LOCATION="${LOCATION:-koreacentral}"
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-${PREFIX}-drtest}"
export OWNER_EMAIL="${OWNER_EMAIL:-owner@example.com}" MONTHLY_BUDGET="${MONTHLY_BUDGET:-1000}"
export ALLOWED_CLIENT_CIDRS="${ALLOWED_CLIENT_CIDRS:-203.0.113.10/32}"
export AZURE_CORE_ONLY_SHOW_ERRORS=true

az() {
  local arg
  local args=()
  for arg in "$@"; do
    if command -v cygpath >/dev/null && [[ "$arg" == @* && -f "${arg#@}" ]]; then args+=("@$(cygpath -w "${arg#@}")")
    elif command -v cygpath >/dev/null && [[ -f "$arg" ]]; then args+=("$(cygpath -w "$arg")")
    else args+=("$arg"); fi
  done
  # A long-lived AKS bootstrap must reread the rotating projected token rather
  # than reuse az login's originally captured federated assertion for days.
  if [[ "${DRTEST_WORKLOAD_LOGIN:-false}" == true && "${args[0]:-}" != login ]]; then
    [[ -r "${AZURE_FEDERATED_TOKEN_FILE:-}" && -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_TENANT_ID:-}" ]] ||
      die 'Workload login requires a readable projected token, client ID and tenant ID.'
    MSYS_NO_PATHCONV=1 command az login --service-principal -u "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID" \
      --federated-token "$(cat "$AZURE_FEDERATED_TOKEN_FILE")" --allow-no-subscriptions -o none || return "$?"
  fi
  # Protect ARM IDs from Git Bash's /subscriptions -> C:/... rewriting.
  MSYS_NO_PATHCONV=1 command az "${args[@]}"
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
need() { local x; for x in "$@"; do command -v "$x" >/dev/null || die "Required command: $x"; done; }
need_python() {
  local candidate
  for candidate in "${PYTHON_BIN:-python3}" python; do
    if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3,9))' >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"; export PYTHON_BIN; return
    fi
  done
  die 'Python >=3.9 required (python3 or python); set PYTHON_BIN if necessary.'
}
azure_context() {
  need az jq
  SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
  [[ -n "$SUBSCRIPTION_ID" ]] || die 'Run az login and az account set first.'
  export SUBSCRIPTION_ID
  az account set --subscription "$SUBSCRIPTION_ID"
}
export_config() {
  mkdir -p "$STATE_DIR"
  local output
  output="$(az deployment sub show --name "$DEPLOYMENT_NAME" --query properties.outputs.config.value -o json)"
  jq -e 'type == "object" and (.primary.aks.name | type == "string")' <<<"$output" >/dev/null ||
    die 'Subscription deployment has no valid config output.'
  printf '%s\n' "$output" >"$CONFIG_FILE.new"
  mv "$CONFIG_FILE.new" "$CONFIG_FILE"
}
load_config() {
  azure_context
  [[ -s "$CONFIG_FILE" ]] || export_config
  jq -e 'type == "object" and .primaryResourceGroup and .secondaryResourceGroup and .trafficManager.id' "$CONFIG_FILE" >/dev/null ||
    die "Invalid deployment config: $CONFIG_FILE"
  PREFIX="$(cfg '.prefix')"
  PRIMARY_RESOURCE_GROUP="$(cfg '.primaryResourceGroup')"
  SECONDARY_RESOURCE_GROUP="$(cfg '.secondaryResourceGroup')"
  GLOBAL_RESOURCE_GROUP="$(cfg '.globalResourceGroup')"
  TRAFFIC_MANAGER_FQDN="$(cfg '.trafficManager.fqdn')"
  export PREFIX PRIMARY_RESOURCE_GROUP SECONDARY_RESOURCE_GROUP GLOBAL_RESOURCE_GROUP TRAFFIC_MANAGER_FQDN
}
cfg() { jq -er "$1 // empty" "$CONFIG_FILE"; }
enabled() { [[ "$(jq -r "$1 // false" "$CONFIG_FILE")" == true ]]; }
region_key() {
  case "$1" in krc|koreacentral|primary) printf primary;; krs|koreasouth|secondary) printf secondary;; *) die "Unknown region: $1";; esac
}
region_rg() { if [[ "$1" == primary ]]; then cfg '.primaryResourceGroup'; else cfg '.secondaryResourceGroup'; fi; }
remote_result() {
  local result="$1" code
  jq -e 'has("exitCode") and (.exitCode | type == "number")' <<<"$result" >/dev/null ||
    die "AKS command invoke returned no remote exitCode: $result"
  jq -r '.logs // ""' <<<"$result"
  code="$(jq -r '.exitCode' <<<"$result")"
  [[ "$code" == 0 ]] || die "AKS remote command failed (exitCode=$code)."
  # kubectl can print errors yet a badly composed remote shell can return zero.
  if jq -r '.logs // ""' <<<"$result" | grep -Eq '(^Error from server|^error:|^FATAL:|^DR_REMOTE_ERROR)'; then
    die 'AKS remote output contains a command error.'
  fi
}
aks_run() {
  local key="$1" command="$2" result; shift 2
  result="$(az aks command invoke --resource-group "$(region_rg "$key")" --name "$(cfg ".$key.aks.name")" \
    --command "set -eu; $command" "$@" -o json)"
  remote_result "$result"
}
wait_job() {
  local key="$1" job="$2" timeout="${3:-86400}" start=$SECONDS result
  while (( SECONDS - start < timeout )); do
    result="$(aks_run "$key" "kubectl -n drtest get job '$job' -o json")"
    if jq -e '.status.conditions[]? | select(.type == "Failed" and .status == "True")' <<<"$result" >/dev/null; then
      aks_run "$key" "kubectl -n drtest logs job/$job --all-containers=true" || true
      die "Job $job failed."
    fi
    if jq -e '.status.conditions[]? | select(.type == "Complete" and .status == "True")' <<<"$result" >/dev/null; then
      aks_run "$key" "kubectl -n drtest logs job/$job -c upload"
      return
    fi
    sleep "${JOB_POLL_SECONDS:-30}"
  done
  die "Timed out after ${timeout}s waiting for $job (Job left running for inspection)."
}
confirm() {
  local expected="$1" approval_variable="${2:-CONFIRM}" answer
  if [[ "${!approval_variable:-}" == "$expected" ]]; then return; fi
  [[ -t 0 ]] || die "Set $approval_variable='$expected' to approve this operation."
  read -r -p "Type '$expected' to continue: " answer
  [[ "$answer" == "$expected" ]] || die 'Cancelled.'
}
csv_log() {
  local status="$1" step="$2" detail="${3:-}" line
  detail="${detail//$'\n'/ }"; detail="${detail//\"/\"\"}"
  line="\"$(date -u +%FT%TZ)\",\"$status\",\"$step\",\"$detail\""
  printf '%s\n' "$line" >>"$DRILL_LOG"
}
drill_init() {
  mkdir -p "$STATE_DIR"
  DRILL_LOG="${DRILL_LOG:-$STATE_DIR/drill-log-$(date -u +%Y%m%d).csv}"
  export DRILL_LOG
  [[ -f "$DRILL_LOG" ]] || printf 'utc,status,step,detail\n' >"$DRILL_LOG"
  trap 'rc=$?; csv_log ERROR "${CURRENT_STEP:-script}" "line $LINENO exit $rc"; exit "$rc"' ERR
}
step() {
  CURRENT_STEP="$1"; shift
  csv_log START "$CURRENT_STEP" "$*"
  "$@"
  csv_log END "$CURRENT_STEP"
}
tm_dns_wait() {
  local key="$1" host expected answer start=$SECONDS
  host="$(cfg '.trafficManager.fqdn')"
  if enabled '.features.deployAppGateway'; then expected="$(cfg ".$key.appGateway.address")"; else expected="$(cfg ".$key.publicIp.address")"; fi
  need nslookup
  while (( SECONDS - start < ${DNS_TIMEOUT_SECONDS:-900} )); do
    if [[ -n "${DNS_RESOLVER:-}" ]]; then answer="$(nslookup "$host" "$DNS_RESOLVER" 2>&1 || true)"
    else answer="$(nslookup "$host" 2>&1 || true)"; fi
    # Match complete address tokens, never substrings (10.0.0.1 != 10.0.0.10).
    if printf '%s\n' "$answer" | tr '[:space:]' '\n' | grep -Fxq "$expected"; then
      printf '%s\n' "$answer"; return
    fi
    sleep "${DNS_POLL_SECONDS:-10}"
  done
  die "DNS $host did not resolve to $expected within timeout. Set DNS_RESOLVER to a reachable recursive resolver."
}
tm_endpoint() {
  local key="$1" state="$2" endpoint
  if [[ "$key" == primary ]]; then endpoint="$(cfg '.trafficManager.primaryEndpointName')"; else endpoint="$(cfg '.trafficManager.secondaryEndpointName')"; fi
  az network traffic-manager endpoint update --resource-group "$(cfg '.globalResourceGroup')" \
    --profile-name "$(cfg '.trafficManager.name')" --name "$endpoint" --type azureEndpoints \
    --endpoint-status "$state" -o none
}
tm_assert_online() {
  local doc
  doc="$(az network traffic-manager profile show --ids "$(cfg '.trafficManager.id')" -o json)"
  jq '{status:.monitorConfig.profileMonitorStatus,endpoints:[.endpoints[] | {name,status:.endpointStatus,monitor:.endpointMonitorStatus}]}' <<<"$doc"
  jq -e '(.endpoints | length) == 2 and all(.endpoints[];
    .endpointStatus == "Enabled" and .endpointMonitorStatus == "Online")' <<<"$doc" >/dev/null ||
    die 'Traffic Manager requires two Enabled/Online endpoints before a drill; Degraded/CheckingEndpoint/Disabled is not success.'
}
storage_account() {
  az storage account show --ids "$(cfg '.primary.storage.id')" --expand geoReplicationStats -o json
}
storage_assert_region() {
  local key="$1" doc="$2" other
  case "$key" in primary) other=secondary;; secondary) other=primary;; *) die "Unknown Storage target: $key";; esac
  jq -e --arg primary "$(cfg ".$key.location")" --arg secondary "$(cfg ".$other.location")" '
    .sku.name == "Standard_RAGRS" and .provisioningState == "Succeeded" and
    (.failoverInProgress != true) and .primaryLocation == $primary and .secondaryLocation == $secondary
  ' <<<"$doc" >/dev/null || die "Storage must be RA-GRS with active $key and its paired secondary; inspect storage account state."
}
storage_planned_failover() {
  local key="$1" other doc
  case "$key" in primary) other=secondary;; secondary) other=primary;; *) die "Unknown Storage target: $key";; esac
  doc="$(storage_account)"
  if [[ "$(jq -r '.primaryLocation' <<<"$doc")" == "$(cfg ".$key.location")" ]]; then
    storage_assert_region "$key" "$doc"
    note "Storage $key is already active; no account failover."
    return
  fi
  storage_assert_region "$other" "$doc"
  jq -e '.geoReplicationStats.status == "Live" and .geoReplicationStats.canPlannedFailover == true' <<<"$doc" >/dev/null ||
    die 'Storage is not ready for planned failover. Wait for healthy geo-replication; unplanned failover is prohibited.'
  note "Starting planned Storage account failover to $key; waiting for Azure completion. This can take hours."
  az storage account failover --ids "$(cfg '.primary.storage.id')" --failover-type Planned --yes -o none
  doc="$(storage_account)"
  storage_assert_region "$key" "$doc"
  printf '%s\n' "$doc" >"$STATE_DIR/storage-active-$key.json"
  note "Storage $key active; RA-GRS retained. Both apps keep using the primary blob hostname."
}
pg_assert_pair() {
  local key="$1" other primary replica
  case "$key" in primary) other=secondary;; secondary) other=primary;; *) die "Unknown PostgreSQL target: $key";; esac
  primary="$(az postgres flexible-server show -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" -o json)"
  replica="$(az postgres flexible-server show -g "$(region_rg "$other")" -n "$(cfg ".$other.pg.name")" -o json)"
  jq -e '.state == "Ready" and (.replicationRole | ascii_downcase) == "primary"' <<<"$primary" >/dev/null ||
    die "PostgreSQL $key is not a Ready primary."
  MSYS_NO_PATHCONV=1 jq -e --arg source "$(cfg ".$key.pg.id")" '
    .state == "Ready" and (.replicationRole | ascii_downcase | endswith("replica")) and
    (.sourceServerResourceId | ascii_downcase) == ($source | ascii_downcase)
  ' <<<"$replica" >/dev/null || die "PostgreSQL $other is not a Ready replica of $key; refusing a split or standalone topology."
}
pg_switchover() {
  local key="$1" role
  role="$(az postgres flexible-server show -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" --query replicationRole -o tsv)"
  case "${role,,}" in
    primary) note "PostgreSQL $key is already primary; no promotion.";;
    replica|asyncreplica|geoasyncreplica|georeplica)
      local other
      if [[ "$key" == primary ]]; then other=secondary; else other=primary; fi
      pg_assert_pair "$other"
      az postgres flexible-server replica promote -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" \
        --promote-mode switchover --promote-option planned -o none;;
    *) die "Unexpected PostgreSQL role '$role'; refusing destructive/standalone promotion.";;
  esac
  pg_assert_pair "$key"
}
dr_verify_data() {
  local key="$1" url info written readback id
  url="http://$(cfg '.trafficManager.fqdn')"
  info="$(curl --fail --silent --show-error --max-time 40 "$url/api/info")"
  jq -e --arg region "$(cfg ".$key.region")" '.region == $region and .storage_read_mode == "primary"' <<<"$info" >/dev/null ||
    die "Application is not serving $key with the stable Storage primary endpoint."
  written="$(curl --fail --silent --show-error --max-time 40 -X POST "$url/api/write")"
  printf '%s\n' "$written"
  jq -e '.services.storage_primary.ok == true and .services.postgres.ok == true and (.record.id | type == "string" and length > 0)' <<<"$written" >/dev/null ||
    die 'Post-switch Storage/PostgreSQL writes failed; routing is not proof of data-plane recovery.'
  if enabled '.features.deployEventHubs'; then
    jq -e '.services.event_hubs.ok == true' <<<"$written" >/dev/null ||
      die 'Event Hubs alias send failed after routing. Metadata recovery does not prove producer access.'
  fi
  id="$(jq -er '.record.id' <<<"$written")"
  readback="$(curl --fail --silent --show-error --max-time 40 "$url/api/read")"
  printf '%s\n' "$readback"
  jq -e --arg id "$id" '
    .services.postgres.ok == true and .services.postgres.data.id == $id and
    .services.storage.ok == true and .services.storage.data.record.id == $id and
    .services.storage.data.endpoint_read == "primary"
  ' <<<"$readback" >/dev/null || die 'Post-switch readback did not recover the written record through both writer endpoints.'
  if enabled '.features.deployEventHubs'; then
    jq -e '.services.event_hubs.ok == true' <<<"$readback" >/dev/null ||
      die 'Event Hubs alias metadata read failed after routing.'
  fi
}
pg_order() {
  local mode="$1" key role
  local primaries=() replicas=() standalone=()
  for key in primary secondary; do
    role="$(az postgres flexible-server show -g "$(region_rg "$key")" -n "$(cfg ".$key.pg.name")" --query replicationRole -o tsv)"
    case "${role,,}" in
      primary) primaries+=("$key");;
      *replica*) replicas+=("$key");;
      none) standalone+=("$key");;
      *) die "Unrecognized PostgreSQL replicationRole: $role";;
    esac
  done
  if [[ "$mode" == stop ]]; then printf '%s\n' "${primaries[@]}" "${standalone[@]}" "${replicas[@]}"
  else printf '%s\n' "${replicas[@]}" "${standalone[@]}" "${primaries[@]}"; fi
}
