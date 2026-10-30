#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
enabled '.features.deployAiSearch' || { note 'AI Search disabled; nothing to initialize.'; exit 0; }
mkdir -p "$STATE_DIR"
regions=("$@")
(( ${#regions[@]} )) || regions=(primary secondary)
for key in "${regions[@]}"; do
  [[ "$key" == primary || "$key" == secondary ]] || die "Unexpected region key: $key"
done
for key in "${regions[@]}"; do
  region="$(cfg ".$key.region")"
  # Data-plane calls must originate inside each private AKS VNet.
  jq -n --arg client "$(cfg ".$key.identity.clientId")" '
    {apiVersion:"v1",kind:"ServiceAccount",metadata:{name:"drtest-app",namespace:"drtest",
      annotations:{"azure.workload.identity/client-id":$client}}}' >"$STATE_DIR/search-serviceaccount.json"
  jq -n --arg endpoint "$(cfg ".$key.search.endpoint")" --arg region "$region" '
    {apiVersion:"batch/v1",kind:"Job",metadata:{name:"search-index-init",namespace:"drtest"},
     spec:{backoffLimit:2,activeDeadlineSeconds:1800,template:{
       metadata:{labels:{"azure.workload.identity/use":"true"}},
       spec:{serviceAccountName:"drtest-app",restartPolicy:"Never",containers:[{
         name:"upload",image:"mcr.microsoft.com/azure-cli:2.85.0",command:["/bin/bash","-Eeuo","pipefail","-c","
export AZURE_CONFIG_DIR=/work/azure
mkdir -p /work/azure
az login --service-principal --username \"$AZURE_CLIENT_ID\" --tenant \"$AZURE_TENANT_ID\" --federated-token \"$(cat \"$AZURE_FEDERATED_TOKEN_FILE\")\" --allow-no-subscriptions -o none
token=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
index=$(printf \"%s\" \"{\\\"name\\\":\\\"dr-samples\\\",\\\"fields\\\":[{\\\"name\\\":\\\"id\\\",\\\"type\\\":\\\"Edm.String\\\",\\\"key\\\":true},{\\\"name\\\":\\\"region\\\",\\\"type\\\":\\\"Edm.String\\\",\\\"filterable\\\":true},{\\\"name\\\":\\\"title\\\",\\\"type\\\":\\\"Edm.String\\\",\\\"searchable\\\":true},{\\\"name\\\":\\\"content\\\",\\\"type\\\":\\\"Edm.String\\\",\\\"searchable\\\":true}]}\")
curl --fail-with-body --silent --show-error --retry 8 --retry-all-errors --retry-delay 15 --connect-timeout 10 --max-time 60 -X PUT -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\" \"$SEARCH_ENDPOINT/indexes/dr-samples?api-version=2025-09-01\" --data \"$index\"
echo
docs=$(printf \"{\\\"value\\\":[{\\\"@search.action\\\":\\\"mergeOrUpload\\\",\\\"id\\\":\\\"seed-%s\\\",\\\"region\\\":\\\"%s\\\",\\\"title\\\":\\\"DR smoke test\\\",\\\"content\\\":\\\"Independently seeded regional index; this is not index replication.\\\"}]}\" \"$REGION\" \"$REGION\")
curl --fail-with-body --silent --show-error --retry 8 --retry-all-errors --retry-delay 15 --connect-timeout 10 --max-time 60 -X POST -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\" \"$SEARCH_ENDPOINT/indexes/dr-samples/docs/index?api-version=2025-09-01\" --data \"$docs\" > /work/result.json
python3 -c \"import json; d=json.load(open(\\\"/work/result.json\\\")); assert d[\\\"value\\\"] and all(i.get(\\\"status\\\") is True for i in d[\\\"value\\\"]), d\"
echo SEARCH_INDEX_VERIFIED
"],env:[{name:"SEARCH_ENDPOINT",value:$endpoint},{name:"REGION",value:$region}],
         resources:{requests:{cpu:"100m",memory:"128Mi"},limits:{cpu:"1",memory:"512Mi"}},
         volumeMounts:[{name:"work",mountPath:"/work"}]}],volumes:[{name:"work",emptyDir:{sizeLimit:"256Mi"}}]}}}}' >"$STATE_DIR/search-index-job.json"
  aks_run "$key" "kubectl create namespace drtest --dry-run=client -o yaml | kubectl apply -f -; \
kubectl apply -f search-serviceaccount.json; \
kubectl -n drtest delete job search-index-init --ignore-not-found=true --wait=true; \
kubectl apply -f search-index-job.json" --file "$STATE_DIR/search-serviceaccount.json" --file "$STATE_DIR/search-index-job.json"
  wait_job "$key" search-index-init 2100 | tee "$STATE_DIR/search-$region.log"
  grep -q '^SEARCH_INDEX_VERIFIED' "$STATE_DIR/search-$region.log" || die "Search $region initialization did not verify per-document status."
done
note 'Selected independent Search indexes seeded. This is not managed cross-region index replication. App MI needs Search Service Contributor AND Search Index Data Contributor.'
