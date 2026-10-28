#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../common.sh"
load_config; drill_init
confirm "FAILBACK $PREFIX"
note 'Safe failback reverses backend roles FIRST. Enabling higher-priority KRC before PostgreSQL/EH are ready would route clients prematurely.'
step pg-to-krc pg_switchover primary
if enabled '.features.deployEventHubs' && enabled '.features.enableEventHubsGeoReplication'; then step eh-to-krc bash "$ROOT_DIR/scripts/eh-georeplication.sh" promote krc; fi
step enable-krc tm_endpoint primary Enabled
step dns-krc tm_dns_wait primary
# Keep the secondary endpoint enabled as the priority-2 standby.
step enable-krs tm_endpoint secondary Enabled
step health-krc curl --fail --silent --show-error --max-time 30 "http://$(cfg '.trafficManager.fqdn')${HEALTH_PATH:-/healthz}"
