#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
load_config
for key in primary secondary; do
  region="$(cfg ".$key.region")"
  out="${APP_CONFIG_OUTPUT_DIR:-$ROOT_DIR/k8s/overlays}/$region"
  mkdir -p "$out"
  jq --arg key "$key" --arg subscription "$SUBSCRIPTION_ID" --arg pguser "${PG_USER:-${PG_ADMIN_LOGIN:-}}" --arg pgdb "${PG_DB:-}" '
    . as $c | .[$key] as $r |
    {apiVersion:"v1",kind:"ConfigMap",metadata:{name:"drtest-app-config",namespace:"drtest"},
     data:{
       REGION:$r.region,AZURE_CLIENT_ID:$r.identity.clientId,
       STORAGE_ACCOUNT:($c.primary.storage.name // ($c.primary.storage.primaryEndpoint|sub("^https://";"")|split(".")[0])),
       STORAGE_RESOURCE_ID:($c.primary.storage.id // ""),AZURE_SUBSCRIPTION_ID:$subscription,
       STORAGE_READ_MODE:(if $key == "primary" then "primary" else "secondary" end),
       EH_NAMESPACE:(if $c.features.deployEventHubs then ($r.eventHubs.host // "") else "" end),
       EH_NAME:(if $c.features.deployEventHubs then "drtest-events" else "" end),
       PG_HOST:$c.postgres.writerEndpoint,
       PG_DB:(if $pgdb=="" then ($c.postgres.database // "postgres") else $pgdb end),
       PG_USER:(if $pguser=="" then "dradmin" else $pguser end),
       REDIS_PORT:"10000",KRC_VNET_PREFIX:"10.10.",KRS_VNET_PREFIX:"10.20.",
       TM_FQDN:$c.trafficManager.fqdn,
       KRC_PUBLIC_IP:(if $c.features.deployAppGateway then $c.primary.appGateway.address else ($c.primary.publicIp.address // "") end),
       KRS_PUBLIC_IP:(if $c.features.deployAppGateway then $c.secondary.appGateway.address else ($c.secondary.publicIp.address // "") end),
       PUBLIC_IP_NAME:$r.publicIp.name,PUBLIC_IP_RESOURCE_GROUP:(if $key == "primary" then $c.primaryResourceGroup else $c.secondaryResourceGroup end),
       POSTGRES_WRITER_HOST:$c.postgres.writerEndpoint,POSTGRES_READER_HOST:$c.postgres.readerEndpoint,
       POSTGRES_DATABASE:(if $pgdb=="" then ($c.postgres.database // "postgres") else $pgdb end),POSTGRES_SSLMODE:"verify-full",
       STORAGE_PRIMARY_ENDPOINT:$c.primary.storage.primaryEndpoint,
       STORAGE_SECONDARY_ENDPOINT:$c.primary.storage.secondaryEndpoint,
       STORAGE_READ_ENDPOINT:(if $key == "primary" then $c.primary.storage.primaryEndpoint else $c.primary.storage.secondaryEndpoint end),
       STORAGE_CONTAINER:"sampledata",STORAGE_READ_ONLY:(if $key == "secondary" then "true" else "false" end),
       EVENTHUBS_HOST:($r.eventHubs.host // ""),EVENTHUBS_ENABLED:($c.features.deployEventHubs|tostring),
       REDIS_HOST:(if $c.features.deployRedis then ($r.redis.host // "") else "" end),REDIS_TLS:"true",REDIS_ENABLED:($c.features.deployRedis|tostring),
       SEARCH_ENDPOINT:(if $c.features.deployAiSearch then ($r.search.endpoint // "") else "" end),
       SEARCH_INDEX:(if $c.features.deployAiSearch then "dr-samples" else "" end),SEARCH_ENABLED:($c.features.deployAiSearch|tostring),
       ACR_LOGIN_SERVER:($r.acr.loginServer // $c.primary.acr.loginServer // ""),
       TRAFFIC_MANAGER_FQDN:$c.trafficManager.fqdn
     }}' "$CONFIG_FILE" >"$out/configmap.yaml"
  jq --arg key "$key" '
    .[$key] as $r |
    {apiVersion:"v1",kind:"ServiceAccount",metadata:{name:"drtest-app",namespace:"drtest",
     annotations:{"azure.workload.identity/client-id":$r.identity.clientId}}}' "$CONFIG_FILE" >"$out/serviceaccount.yaml"
  # Public allowlists are NSG-only annotations: source ranges cannot coexist with
  # azure-allowed-service-tags. Internal AppGW traffic uses gateway source ranges.
  jq --arg key "$key" '
    . as $c | .[$key] as $r |
    {apiVersion:"v1",kind:"Service",metadata:{name:"drtest-app",namespace:"drtest",
     annotations:(
       if .features.deployAppGateway then {
             "service.beta.kubernetes.io/azure-load-balancer-internal":"true",
             "service.beta.kubernetes.io/azure-load-balancer-internal-subnet":"snet-aks",
             "service.beta.kubernetes.io/azure-load-balancer-ipv4":$r.appGateway.backendAddress}
       else {"service.beta.kubernetes.io/azure-pip-name":$r.publicIp.name,
             "service.beta.kubernetes.io/azure-load-balancer-resource-group":(if $key == "primary" then .primaryResourceGroup else .secondaryResourceGroup end),
             "service.beta.kubernetes.io/azure-allowed-service-tags":"AzureTrafficManager",
             "service.beta.kubernetes.io/azure-allowed-ip-ranges":(.allowedClientCidrs|join(","))}
       end)},
     spec:({type:"LoadBalancer",selector:{app:"drtest-app"},ports:[{name:"http",port:80,targetPort:8000}],
       externalTrafficPolicy:"Local"} + (if .features.deployAppGateway then {loadBalancerSourceRanges:[$r.appGateway.backendSourceCidr]} else {} end))}' "$CONFIG_FILE" >"$out/service.yaml"
  # Replace annotations as a whole so internal-LB overlays never inherit public
  # filtering/IP annotations. The shared base owns all pod configuration.
  jq -n --arg image "${APP_IMAGE:-drtest-app:unconfigured}" --slurpfile service "$out/service.yaml" \
    '{apiVersion:"kustomize.config.k8s.io/v1beta1",kind:"Kustomization",namespace:"drtest",
      resources:["../../base","configmap.yaml"],
      patches:[{path:"serviceaccount.yaml"},
        {target:{kind:"Service",name:"drtest-app"},
          patch:([{op:"replace",path:"/metadata/annotations",value:$service[0].metadata.annotations},
                  {op:"replace",path:"/spec",value:$service[0].spec}]|tojson)}],
      images:[{name:"drtest-app",newName:($image|split("@")[0]|sub(":[^/:]+$";"")),
        newTag:($image|split(":")|last)}]}' >"$out/kustomization.yaml"
done
note 'Generated regional Kustomize overlays for the shared app base; no secrets or application deployment performed. Set APP_IMAGE to the built registry image before applying.'
