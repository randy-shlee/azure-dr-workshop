#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
[[ $# == 0 || ( $# == 1 && "$1" == --wait-app ) ]] || die 'Usage: bootstrap-status.sh [--wait-app]'
load_config
account="$(jq -r '.bootstrap.accountName // empty' "$CONFIG_FILE")"
job_id="$(jq -r '.bootstrap.jobId // empty' "$CONFIG_FILE")"
[[ -n "$account" && -n "$job_id" ]] || die 'No portal bootstrap outputs. Export the actual portal subscription deployment config first.'
start=$SECONDS
while true; do
  state="$(az rest --method get --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$GLOBAL_RESOURCE_GROUP/providers/Microsoft.Automation/automationAccounts/$account/jobs/$job_id?api-version=2024-10-23" --query properties.status -o tsv)"
  note "Automation job: $state"
  case "$state" in
    Failed|Stopped|Suspended|Disconnected) die 'Automation did not complete successfully. Inspect Automation Errors and the KRC bootstrap Job.';;
    Completed|Running|Queued|New|Activating|Resuming|Starting) ;;
    *) die "Unexpected Automation job status: $state";;
  esac
  result="$(aks_run primary 'kubectl -n drtest get configmap workshop-bootstrap-status --ignore-not-found=true -o json')"
  job="$(aks_run primary 'kubectl -n drtest get job workshop-bootstrap --ignore-not-found=true -o json')"
  if [[ -n "$job" ]] && jq -e 'any(.status.conditions[]?; .type=="Failed" and .status=="True")' <<<"$job" >/dev/null; then
    die 'Bootstrap Job failed (including possible sample replication failure after application readiness).'
  fi
  phase='Pending'
  if [[ -n "$result" ]]; then
    jq '.data' <<<"$result"
    phase="$(jq -r '.data.phase // "Pending"' <<<"$result")"
    [[ "$phase" != Failed ]] || die 'Bootstrap reported failure.'
  fi
  if [[ "$state" == Completed && ( "$phase" == ApplicationReady || "$phase" == Complete ) ]]; then
    note "Application verified. Sample state: $phase (only Complete means skipped explicitly or replicated/read verified)."
    exit 0
  fi
  [[ "${1:-}" == --wait-app ]] || { note 'Pending, not verified ready.'; exit 2; }
  (( SECONDS - start < ${BOOTSTRAP_STATUS_TIMEOUT_SECONDS:-9000} )) || die 'Bootstrap observation timed out; inspect actual job state.'
  sleep "${BOOTSTRAP_STATUS_POLL_SECONDS:-30}"
done
