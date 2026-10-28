#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../common.sh"
load_config; drill_init
confirm "FAILOVER $PREFIX"
if enabled '.features.deployEventHubs' && enabled '.features.enableEventHubsGeoReplication'; then step eh-to-krs bash "$ROOT_DIR/scripts/eh-georeplication.sh" promote krs; fi
step pg-to-krs pg_switchover secondary
# Backend roles must be ready before admitting traffic; no storage account failover.
step enable-krs tm_endpoint secondary Enabled
step disable-krc tm_endpoint primary Disabled
step dns-krs tm_dns_wait secondary
step health-krs curl --fail --silent --show-error --max-time 30 "http://$(cfg '.trafficManager.fqdn')${HEALTH_PATH:-/healthz}"
note 'KRS active. Storage remains read-only secondary; primary blob writes are not moved.'
