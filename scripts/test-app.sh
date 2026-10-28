#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
need curl nslookup
url="http://$(cfg '.trafficManager.fqdn')"
dns="$(nslookup "$(cfg '.trafficManager.fqdn')")"
printf '%s\n' "$dns"
for key in primary secondary; do
  expected="$(cfg ".$key.publicIp.address")"
  if enabled '.features.deployAppGateway'; then expected="$(cfg ".$key.appGateway.address")"; fi
  if printf '%s\n' "$dns" | tr '[:space:]' '\n' | grep -Fxq "$expected"; then note "DNS advisory: $(cfg ".$key.region") ($expected)"; fi
done
request() {
  local method="$1" path="$2" payload
  payload="$(curl --fail-with-body --silent --show-error --connect-timeout 3 --max-time 40 \
    -H 'Cache-Control: no-store' -X "$method" "$url$path")"
  jq . <<<"$payload"
  # A dependency failure intentionally uses HTTP 200 with explicit per-service
  # status. It must still fail a smoke test, not appear as success.
  if jq -e '(.status == "error" or .status == "partial") or (.error != null and .error != "") or
    (.primary.status=="error" or .secondary.status=="error") or
    ([.services[]? | select(.status=="error")] | length > 0)' <<<"$payload" >/dev/null; then
    failures=$((failures+1))
  fi
}
failures=0
request GET /api/info
request GET /api/tm
# POST is not retried by this client: Event Hubs can deliver at least once.
request POST /api/write
request GET /api/read
request GET /api/sampledata
for key in primary secondary; do
  note "Pod-side connection checks: $(cfg ".$key.region")"
  result="$(aks_run "$key" "kubectl -n drtest exec deployment/drtest-app -- python -c 'import urllib.request; print(urllib.request.urlopen(\"http://127.0.0.1:8000/api/check\", timeout=30).read().decode())'")"
  printf 'SERVICE\tSTATUS\tPE_REGION\tIPS\tMS\n'
  jq -r '(.services // .) | to_entries[] | [.key,.value.status,.value.pe_region,((.value.ips // [])|join(",")),(.value.latency_ms|tostring)]|@tsv' <<<"$result"
  if jq -e '[((.services // .)[]) | select(.status=="error")] | length > 0' <<<"$result" >/dev/null; then failures=$((failures+1)); fi
done
(( failures == 0 )) || die "$failures API checks reported dependency failures; inspect JSON above."
note 'Smoke requests completed. Check sampledata.replication_complete and the dashboard before declaring the drill successful.'
