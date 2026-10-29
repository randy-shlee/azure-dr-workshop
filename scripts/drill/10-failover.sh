#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../common.sh"
load_config; drill_init
confirm "FAILOVER $PREFIX"
step storage-to-krs storage_planned_failover secondary
if enabled '.features.deployEventHubs' && enabled '.features.enableEventHubsGeoRecovery'; then
  step eh-to-krs env CONFIRM_EH="FAILOVER EH GEO $PREFIX" bash "$ROOT_DIR/scripts/eh-georecovery.sh" failover krs
fi
step pg-to-krs pg_switchover secondary
# Backend roles must be ready before admitting traffic.
step enable-krs tm_endpoint secondary Enabled
step disable-krc tm_endpoint primary Disabled
step dns-krs tm_dns_wait secondary
step health-krs curl --fail --silent --show-error --max-time 30 "http://$(cfg '.trafficManager.fqdn')${HEALTH_PATH:-/healthz}"
step data-krs dr_verify_data secondary
note 'KRS active. Storage/PG moved to Korea South. Event Hubs moved only its alias/metadata; pre-failover events remain in KRC.'
