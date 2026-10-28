#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../common.sh"
load_config; drill_init
note 'Fast drill settings: DNS TTL 0 is not a cache-purge guarantee; existing client connections and recursive caches can outlive it.'
step fast-monitor az network traffic-manager profile update --resource-group "$(cfg '.globalResourceGroup')" \
  --name "$(cfg '.trafficManager.name')" --interval 10 --max-failures 1 --timeout 5 --ttl 0 -o none
