#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
enabled '.sampleData.skip' && { note 'Sample data explicitly skipped.'; exit 0; }
storage_assert_region primary "$(storage_account)"
need_python
mkdir -p "$STATE_DIR"
run_upload_job() {
  local key="$1" mode="$2" endpoint="$3" job="sampledata-$2" rendered="$STATE_DIR/sampledata-$2.json"
  # kubectl performs YAML->JSON conversion on the private-cluster command runner.
  aks_run "$key" "kubectl create namespace drtest --dry-run=client -o yaml | kubectl apply -f -; \
kubectl -n drtest create configmap sampledata-program --from-file=sampledata-program.sh --from-file=sample_layout.py --dry-run=client -o yaml | kubectl apply -f -; \
kubectl create --dry-run=client -f sampledata-upload.yaml -o json" \
    --file "$ROOT_DIR/scripts/sampledata-program.sh" --file "$ROOT_DIR/app/sample_layout.py" --file "$ROOT_DIR/k8s/jobs/sampledata-upload.yaml" >"$STATE_DIR/job-template-result.txt"
  # command-invoke output can include apply status lines before the final JSON.
  "$PYTHON_BIN" - "$STATE_DIR/job-template-result.txt" "$STATE_DIR/job-template.json" <<'PY'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
start = text.find('{\n')
if start < 0:
    raise SystemExit("Remote job template did not contain JSON")
obj = json.loads(text[start:])
pathlib.Path(sys.argv[2]).write_text(json.dumps(obj))
PY
  jq --arg job "$job" --arg endpoint "$endpoint" --arg mode "$mode" --slurpfile config "$CONFIG_FILE" '
    $config[0].sampleData as $c |
    .metadata.name=$job |
    .spec.template.spec.containers[0].image=($c.image // "mcr.microsoft.com/azure-cli:2.85.0") |
    .spec.template.spec.initContainers[0].env |= map(
      if .name=="UPLOAD_MODE" then .value=$mode else . end) |
    .spec.template.spec.containers[0].env |= map(
      if .name=="STORAGE_ENDPOINT" then .value=$endpoint
      elif .name=="SAMPLE_DATA_CONTAINER" then .value=($c.containerName // "sampledata")
      elif .name=="UPLOAD_MODE" then .value=$mode
      elif .name=="SIZE_GB" then .value=($c.sizeGB|tostring)
      elif .name=="LARGE_FILE_SIZE_GB" then .value=($c.largeFileSizeGB|tostring)
      elif .name=="SMALL_FILE_COUNT" then .value=($c.smallFileCount|tostring)
      elif .name=="SMALL_FILE_SIZE_MB" then .value=($c.smallFileSizeMB|tostring)
      else . end)' "$STATE_DIR/job-template.json" >"$rendered"
  jq -nc --arg client "$(cfg '.sampleData.clientId')" \
    '{apiVersion:"v1",kind:"ServiceAccount",metadata:{name:"sampledata-upload",namespace:"drtest",annotations:{"azure.workload.identity/client-id":$client}}}' \
    >"$STATE_DIR/uploader-serviceaccount.json"
  aks_run "$key" "kubectl apply -f uploader-serviceaccount.json; \
kubectl -n drtest delete job '$job' --ignore-not-found=true --wait=true; \
kubectl apply -f 'sampledata-$mode.json'" --file "$STATE_DIR/uploader-serviceaccount.json" --file "$rendered"
  wait_job "$key" "$job" "${UPLOAD_TIMEOUT_SECONDS:-86400}"
}
run_upload_job primary upload "$(cfg '.primary.storage.primaryEndpoint')" | tee "$STATE_DIR/upload.log"
manifest="$(sed -n 's/^UPLOAD_MANIFEST //p' "$STATE_DIR/upload.log" | tail -n 1)"
jq -e '.endUtc and .actualBytes > 0' <<<"$manifest" >/dev/null || die 'Upload completed without a verified manifest.'
printf '%s\n' "$manifest" >"$STATE_DIR/upload-manifest.json"
end="$(jq -r '.replicationFenceUtc // .endUtc' <<<"$manifest")"
note "Waiting for storage lastSyncTime >= $end before the planned account failover drill. Upload preparation does not move account roles."
start=$SECONDS
while (( SECONDS - start < ${REPLICATION_TIMEOUT_SECONDS:-172800} )); do
  stats="$(az storage account show --ids "$(cfg '.primary.storage.id')" --expand geoReplicationStats --query geoReplicationStats -o json)"
  last="$(jq -r '.lastSyncTime // empty' <<<"$stats")"
  if [[ -n "$last" ]] && "$PYTHON_BIN" - "$last" "$end" <<'PY'
import datetime, sys
def date(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
sys.exit(0 if date(sys.argv[1]) >= date(sys.argv[2]) else 1)
PY
  then
    run_upload_job secondary verify "$(cfg '.primary.storage.secondaryEndpoint')" | tee "$STATE_DIR/secondary-verify.log"
    grep -q '^SECONDARY_READ_VERIFIED ' "$STATE_DIR/secondary-verify.log" || die 'Secondary read verification marker absent.'
    note "Replication completed at $(date -u +%FT%TZ); lastSyncTime=$last; KRS secondary reads verified."
    exit 0
  fi
  note "Replication pending: lastSyncTime=${last:-unknown}"
  sleep "${REPLICATION_POLL_SECONDS:-60}"
done
die 'Replication timeout; sample objects and Job logs retained. Retry safely; existing correct-sized objects are skipped.'
