#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../common.sh"
load_config; drill_init
confirm "FAILBACK $PREFIX"
note 'Restore Storage/PG before KRC routing. Standard Event Hubs stays active in KRS via its alias; it cannot fail back to the former primary.'
step storage-to-krc storage_planned_failover primary
step pg-to-krc pg_switchover primary
if enabled '.features.deployEventHubs' && enabled '.features.enableEventHubsGeoRecovery'; then
  step eh-active-alias bash "$ROOT_DIR/scripts/eh-georecovery.sh" wait active
fi
step enable-krc tm_endpoint primary Enabled
step dns-krc tm_dns_wait primary
# Keep the secondary endpoint enabled as the priority-2 standby.
step enable-krs tm_endpoint secondary Enabled
step health-krc curl --fail --silent --show-error --max-time 30 "http://$(cfg '.trafficManager.fqdn')${HEALTH_PATH:-/healthz}"
step data-krc dr_verify_data primary
