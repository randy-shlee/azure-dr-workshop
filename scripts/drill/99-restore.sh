#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../common.sh"
load_config; drill_init
step restore-monitor az network traffic-manager profile update --resource-group "$(cfg '.globalResourceGroup')" \
  --name "$(cfg '.trafficManager.name')" --interval 30 --max-failures 3 --timeout 10 --ttl 60 -o none
note 'Baseline monitor restored (30s / 3 failures / 10s timeout / TTL60). Routing roles were not changed; use 20-failback.sh if needed.'
