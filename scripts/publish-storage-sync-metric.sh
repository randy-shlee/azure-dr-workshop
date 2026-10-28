#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
enabled '.features.enableStorageLastSyncCustomMetricAlert' ||
  die 'Exact LastSyncAgeSeconds custom metrics are preview. Explicitly enable enableStorageLastSyncCustomMetricAlert in infrastructure before publishing.'
need_python
resource="$(cfg '.primary.storage.id')"
last="$(az storage account show --ids "$resource" --expand geoReplicationStats --query geoReplicationStats.lastSyncTime -o tsv)"
[[ -n "$last" && "$last" != None ]] || die 'lastSyncTime unavailable; no fabricated freshness metric will be published.'
body="$("$PYTHON_BIN" - "$last" <<'PY'
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
last = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
age = (now-last).total_seconds()
if age < 0:
    raise ValueError("Last Sync Time is in the future; check clocks instead of publishing zero lag.")
print(json.dumps({"time": now.isoformat().replace("+00:00", "Z"), "data": {"baseData": {
    "metric": "LastSyncAgeSeconds", "namespace": "drtest", "dimNames": [],
    "series": [{"dimValues": [], "min": age, "max": age, "sum": age, "count": 1}]}}}))
PY
)"
# Requires Monitoring Metrics Publisher scoped to the storage resource.
# https://learn.microsoft.com/azure/azure-monitor/metrics/metrics-store-custom-rest-api
az rest --method post --resource https://monitoring.azure.com/ \
  --url "https://$(cfg '.primary.location').monitoring.azure.com$resource/metrics" --body "$body" -o none
note "Published drtest/LastSyncAgeSeconds from lastSyncTime=$last. Run every 10 minutes externally; no scheduler is provisioned."
