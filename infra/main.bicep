targetScope = 'subscription'

@minLength(3)
@maxLength(12)
param prefix string = 'kkbdrtest'
@description('Owner tag and budget notification email. Replace example before deployment.')
param owner string
@description('ISO date for lifecycle tagging; not an automatic deletion schedule.')
param expiry string
@minValue(1)
param monthlyBudget int = 1000
param deployBudget bool = true
param budgetStartDate string = '${utcNow('yyyy-MM')}-01T00:00:00Z'
param allowedClientCidrs array = ['203.0.113.10/32']

param deployEventHubs bool = true
param deployRedis bool = true
param deployAiSearch bool = true
param enableAcrGeoReplication bool = false
param deployAppGateway bool = false
param deployDnsResolver bool = false
param deployAlerts bool = false
// TODO: Direct custom metrics remain preview. Explicit opt-in is required for
// exact Last Sync Time age alerting (not the native replication-lag metric).
// https://learn.microsoft.com/azure/azure-monitor/metrics/metrics-custom-overview
param enableStorageLastSyncCustomMetricAlert bool = false
// TODO: Check Korea South capacity/feature availability in your subscription:
// https://learn.microsoft.com/azure/event-hubs/geo-replication
param enableEventHubsGeoReplication bool = true
@minValue(300)
@maxValue(86400)
param maxReplicationLagSeconds int = 300
param fastFailover bool = false
param aksVmSize string = 'Standard_D4s_v5'
@minValue(2)
param aksNodeCount int = 2
param useEphemeralOsDisk bool = false
param kubernetesVersion string = ''
@allowed(['Standard_D2ds_v5', 'Standard_D2ds_v4'])
param postgresVmSize string = 'Standard_D2ds_v5'
@secure()
param administratorLogin string
@secure()
@minLength(12)
param administratorPassword string
@minValue(1)
param sampleDataSizeGB int = 100
@minValue(1)
param largeFileSizeGB int = 1
@minValue(0)
param smallFileCount int = 20000
@minValue(1)
param smallFileSizeMB int = 1
param skipSampleData bool = false
param sampleDataImage string = 'mcr.microsoft.com/azure-cli:2.85.0'

@description('Opt-in portal bootstrap. Only its Automation account permits public networking; no webhook or local authentication is enabled.')
param deployWorkshopBootstrap bool = false
param bootstrapRunbookUri string = ''
param bootstrapRunbookSha256 string = ''
param appImageArchiveUri string = ''
param appImageArchiveSha256 string = ''
param bootstrapRunId string = utcNow()

var primaryLocation = 'koreacentral'
var secondaryLocation = 'koreasouth'
var tags = union({ purpose: 'dr-test', expiry: expiry }, empty(owner) ? {} : { owner: owner })
resource krc 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-${prefix}-krc'
  location: primaryLocation
  tags: tags
}
resource krs 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-${prefix}-krs'
  location: secondaryLocation
  tags: tags
}
resource global 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-${prefix}-global'
  location: primaryLocation
  tags: tags
}

// Budgets are subscription-scoped, not children of the global resource group,
// and the API does not support tags. Filters cover exactly the three owned RGs
// plus the two AKS-managed node RGs (automatically removed with their clusters).
resource budget 'Microsoft.Consumption/budgets@2026-06-01' = if (deployBudget) {
  name: '${prefix}-drtest-budget'
  properties: {
    amount: monthlyBudget
    category: 'Cost'
    timeGrain: 'Monthly'
    timePeriod: { startDate: budgetStartDate }
    filter: {
      dimensions: {
        name: 'ResourceGroupName'
        operator: 'In'
        values: [krc.name, krs.name, global.name, 'rg-${prefix}-krc-aks-managed', 'rg-${prefix}-krs-aks-managed']
      }
    }
    notifications: {
      Actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [owner]
      }
      Actual100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: [owner]
      }
    }
  }
}

module netKrc 'modules/network.bicep' = {
  name: 'network-krc'
  scope: krc
  params: {
    prefix: prefix
    region: 'krc'
    location: primaryLocation
    addressPrefix: '10.10.0.0/16'
    subnetPrefix: '10.10'
    tags: tags
    deployAppGateway: deployAppGateway
    deployDnsResolver: deployDnsResolver
    allowedClientCidrs: allowedClientCidrs
  }
}
module netKrs 'modules/network.bicep' = {
  name: 'network-krs'
  scope: krs
  params: {
    prefix: prefix
    region: 'krs'
    location: secondaryLocation
    addressPrefix: '10.20.0.0/16'
    subnetPrefix: '10.20'
    tags: tags
    deployAppGateway: deployAppGateway
    deployDnsResolver: deployDnsResolver
    allowedClientCidrs: allowedClientCidrs
  }
}
module peerKrc 'modules/peering.bicep' = {
  name: 'peering-krc'
  scope: krc
  params: { localVnetName: netKrc.outputs.vnetName, remoteVnetId: netKrs.outputs.vnetId }
}
module peerKrs 'modules/peering.bicep' = {
  name: 'peering-krs'
  scope: krs
  params: { localVnetName: netKrs.outputs.vnetName, remoteVnetId: netKrc.outputs.vnetId }
}
module idKrc 'modules/identities.bicep' = {
  name: 'identities-krc'
  scope: krc
  params: { prefix: prefix, region: 'krc', location: primaryLocation, tags: tags, deploySampleIdentity: true }
}
module idKrs 'modules/identities.bicep' = {
  name: 'identities-krs'
  scope: krs
  params: { prefix: prefix, region: 'krs', location: secondaryLocation, tags: tags }
}
module aksKrc 'modules/aks.bicep' = {
  name: 'aks-krc'
  scope: krc
  params: {
    prefix: prefix
    region: 'krc'
    location: primaryLocation
    tags: tags
    subnetId: netKrc.outputs.aksSubnetId
    publicIpId: netKrc.outputs.publicIp.id
    clusterIdentity: idKrc.outputs.cluster
    kubeletIdentity: idKrc.outputs.kubelet
    appIdentityName: idKrc.outputs.app.name
    sampleIdentityName: idKrc.outputs.sample.name
    vmSize: aksVmSize
    nodeCount: aksNodeCount
    useEphemeralOsDisk: useEphemeralOsDisk
    kubernetesVersion: kubernetesVersion
    podCidr: '10.244.0.0/16'
  }
}
module aksKrs 'modules/aks.bicep' = {
  name: 'aks-krs'
  scope: krs
  params: {
    prefix: prefix
    region: 'krs'
    location: secondaryLocation
    tags: tags
    subnetId: netKrs.outputs.aksSubnetId
    publicIpId: netKrs.outputs.publicIp.id
    clusterIdentity: idKrs.outputs.cluster
    kubeletIdentity: idKrs.outputs.kubelet
    appIdentityName: idKrs.outputs.app.name
    vmSize: aksVmSize
    nodeCount: aksNodeCount
    useEphemeralOsDisk: useEphemeralOsDisk
    kubernetesVersion: kubernetesVersion
    podCidr: '10.245.0.0/16'
  }
}
module logs 'modules/workspace.bicep' = {
  name: 'monitor-workspace'
  scope: krc
  params: { prefix: prefix, location: primaryLocation, tags: tags }
}
module monitorKrc 'modules/monitor-pe.bicep' = {
  name: 'monitor-pe-krc'
  scope: krc
  params: {
    prefix: prefix
    region: 'krc'
    location: primaryLocation
    tags: tags
    subnetId: netKrc.outputs.peSubnetId
    scopeId: logs.outputs.scopeId
    dnsZoneIds: netKrc.outputs.dnsZoneIds
  }
}
module monitorKrs 'modules/monitor-pe.bicep' = {
  name: 'monitor-pe-krs'
  scope: krs
  params: {
    prefix: prefix
    region: 'krs'
    location: secondaryLocation
    tags: tags
    subnetId: netKrs.outputs.peSubnetId
    scopeId: logs.outputs.scopeId
    dnsZoneIds: netKrs.outputs.dnsZoneIds
  }
}
var appPrincipals = [idKrc.outputs.app.principalId, idKrs.outputs.app.principalId]
module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: krc
  params: {
    prefix: prefix
    tags: tags
    primarySubnetId: netKrc.outputs.peSubnetId
    secondarySubnetId: netKrs.outputs.peSubnetId
    primaryDnsZoneId: netKrc.outputs.dnsZoneIds['privatelink.blob.${environment().suffixes.storage}']
    secondaryDnsZoneId: netKrs.outputs.dnsZoneIds['privatelink.blob.${environment().suffixes.storage}']
    principalIds: appPrincipals
    samplePrincipalId: idKrc.outputs.sample.principalId
  }
}
module acr 'modules/acr.bicep' = {
  name: 'acr'
  scope: krc
  params: {
    prefix: prefix
    tags: tags
    primarySubnetId: netKrc.outputs.peSubnetId
    secondarySubnetId: netKrs.outputs.peSubnetId
    primaryDnsZoneId: netKrc.outputs.dnsZoneIds['privatelink.azurecr.io']
    secondaryDnsZoneId: netKrs.outputs.dnsZoneIds['privatelink.azurecr.io']
    enableGeoReplication: enableAcrGeoReplication
    kubeletPrincipalIds: [idKrc.outputs.kubelet.principalId, idKrs.outputs.kubelet.principalId]
  }
}
module eventhubs 'modules/eventhubs.bicep' = if (deployEventHubs) {
  name: 'eventhubs'
  scope: krc
  params: {
    prefix: prefix
    tags: tags
    primarySubnetId: netKrc.outputs.peSubnetId
    secondarySubnetId: netKrs.outputs.peSubnetId
    primaryDnsZoneId: netKrc.outputs.dnsZoneIds['privatelink.servicebus.windows.net']
    secondaryDnsZoneId: netKrs.outputs.dnsZoneIds['privatelink.servicebus.windows.net']
    principalIds: appPrincipals
    enableGeoReplication: enableEventHubsGeoReplication
    maxReplicationLagSeconds: maxReplicationLagSeconds
    workspaceId: logs.outputs.id
  }
}
module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  scope: krc
  params: {
    prefix: prefix
    tags: tags
    primarySubnetId: netKrc.outputs.peSubnetId
    secondarySubnetId: netKrs.outputs.peSubnetId
    primaryDnsZoneId: netKrc.outputs.dnsZoneIds['privatelink.postgres.database.azure.com']
    secondaryDnsZoneId: netKrs.outputs.dnsZoneIds['privatelink.postgres.database.azure.com']
    administratorLogin: administratorLogin
    administratorPassword: administratorPassword
    vmSize: postgresVmSize
    workspaceId: logs.outputs.id
  }
}
module redis 'modules/redis.bicep' = if (deployRedis) {
  name: 'redis'
  scope: krc
  params: {
    prefix: prefix
    tags: tags
    primarySubnetId: netKrc.outputs.peSubnetId
    secondarySubnetId: netKrs.outputs.peSubnetId
    primaryDnsZoneId: netKrc.outputs.dnsZoneIds['privatelink.redis.azure.net']
    secondaryDnsZoneId: netKrs.outputs.dnsZoneIds['privatelink.redis.azure.net']
  }
}
module search 'modules/search.bicep' = if (deployAiSearch) {
  name: 'search'
  scope: krc
  params: {
    prefix: prefix
    tags: tags
    primarySubnetId: netKrc.outputs.peSubnetId
    secondarySubnetId: netKrs.outputs.peSubnetId
    primaryDnsZoneId: netKrc.outputs.dnsZoneIds['privatelink.search.windows.net']
    secondaryDnsZoneId: netKrs.outputs.dnsZoneIds['privatelink.search.windows.net']
    principalIds: appPrincipals
  }
}
module gatewayKrc 'modules/appgateway.bicep' = if (deployAppGateway) {
  name: 'appgw-krc'
  scope: krc
  params: {
    prefix: prefix
    region: 'krc'
    location: primaryLocation
    tags: tags
    subnetId: netKrc.outputs.appGatewaySubnetId
    aksSubnetPrefix: '10.10.17.0/24'
    allowedClientCidrs: allowedClientCidrs
    backendAddress: '10.10.0.100'
  }
}
module gatewayKrs 'modules/appgateway.bicep' = if (deployAppGateway) {
  name: 'appgw-krs'
  scope: krs
  params: {
    prefix: prefix
    region: 'krs'
    location: secondaryLocation
    tags: tags
    subnetId: netKrs.outputs.appGatewaySubnetId
    aksSubnetPrefix: '10.20.17.0/24'
    allowedClientCidrs: allowedClientCidrs
    backendAddress: '10.20.0.100'
  }
}
module tm 'modules/global.bicep' = {
  name: 'traffic-manager'
  scope: global
  params: {
    prefix: prefix
    tags: tags
    primaryPublicIpId: deployAppGateway ? gatewayKrc!.outputs.config.publicIpId : netKrc.outputs.publicIp.id
    secondaryPublicIpId: deployAppGateway ? gatewayKrs!.outputs.config.publicIpId : netKrs.outputs.publicIp.id
    fastFailover: fastFailover
    workspaceId: logs.outputs.id
  }
}

module alerts 'modules/alerts.bicep' = if (deployAlerts) {
  name: 'optional-alerts'
  scope: global
  params: {
    prefix: prefix
    tags: tags
    owner: owner
    postgresIds: [postgres.outputs.config.primary.id, postgres.outputs.config.secondary.id]
    eventHubsId: deployEventHubs && enableEventHubsGeoReplication ? eventhubs!.outputs.config.id : ''
    redisIds: deployRedis ? [redis!.outputs.config.primary.id, redis!.outputs.config.secondary.id] : []
    storageId: storage.outputs.config.id
    trafficManagerId: tm.outputs.config.id
    workspaceId: logs.outputs.id
    replicationLagSeconds: maxReplicationLagSeconds
    enableStorageLastSyncCustomMetricAlert: enableStorageLastSyncCustomMetricAlert
  }
}
module redisMetricsKrc 'modules/redis-diagnostics.bicep' = if (deployRedis && deployAlerts) {
  name: 'redis-metrics-krc'
  scope: krc
  params: { redisName: redis!.outputs.config.primary.name, workspaceId: logs.outputs.id }
}
module redisMetricsKrs 'modules/redis-diagnostics.bicep' = if (deployRedis && deployAlerts) {
  name: 'redis-metrics-krs'
  scope: krs
  params: { redisName: redis!.outputs.config.secondary.name, workspaceId: logs.outputs.id }
}

var environmentConfig = {
  schemaVersion: 1
  prefix: prefix
  primaryResourceGroup: krc.name
  secondaryResourceGroup: krs.name
  globalResourceGroup: global.name
  allowedClientCidrs: allowedClientCidrs
  aksVmSize: aksVmSize
  aksNodeCount: aksNodeCount
  postgresVmSize: postgresVmSize
  budget: deployBudget ? monthlyBudget : 0
  budgetName: deployBudget ? budget!.name : ''
  workspaceId: logs.outputs.id
  primary: {
    region: 'krc'
    location: primaryLocation
    aks: aksKrc.outputs.config
    identity: idKrc.outputs.app
    publicIp: netKrc.outputs.publicIp
    appGateway: deployAppGateway ? gatewayKrc!.outputs.config : {}
    storage: storage.outputs.config
    acr: acr.outputs.config
    eventHubs: deployEventHubs ? eventhubs!.outputs.config : {}
    pg: postgres.outputs.config.primary
    redis: deployRedis ? redis!.outputs.config.primary : {}
    search: deployAiSearch ? search!.outputs.config.primary : {}
  }
  secondary: {
    region: 'krs'
    location: secondaryLocation
    aks: aksKrs.outputs.config
    identity: idKrs.outputs.app
    publicIp: netKrs.outputs.publicIp
    appGateway: deployAppGateway ? gatewayKrs!.outputs.config : {}
    storage: storage.outputs.config
    acr: acr.outputs.config
    eventHubs: deployEventHubs ? eventhubs!.outputs.config : {}
    pg: postgres.outputs.config.secondary
    redis: deployRedis ? redis!.outputs.config.secondary : {}
    search: deployAiSearch ? search!.outputs.config.secondary : {}
  }
  postgres: postgres.outputs.config
  trafficManager: tm.outputs.config
  sampleData: {
    clientId: idKrc.outputs.sample.clientId
    principalId: idKrc.outputs.sample.principalId
    sizeGB: sampleDataSizeGB
    largeFileSizeGB: largeFileSizeGB
    smallFileCount: smallFileCount
    smallFileSizeMB: smallFileSizeMB
    skip: skipSampleData
    image: sampleDataImage
  }
  features: {
    deployEventHubs: deployEventHubs
    enableEventHubsGeoReplication: enableEventHubsGeoReplication
    deployRedis: deployRedis
    deployAiSearch: deployAiSearch
    enableAcrGeoReplication: enableAcrGeoReplication
    deployAppGateway: deployAppGateway
    deployDnsResolver: deployDnsResolver
    deployAlerts: deployAlerts
    enableStorageLastSyncCustomMetricAlert: enableStorageLastSyncCustomMetricAlert
    useEphemeralOsDisk: useEphemeralOsDisk
  }
}

resource bootstrapOperator 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (deployWorkshopBootstrap) {
  name: guid(subscription().id, prefix, 'workshop-bootstrap')
  properties: {
    roleName: '${prefix}-workshop-bootstrap'
    description: 'Run commands on the two test clusters and read only deployment metadata/Redis test keys.'
    type: 'CustomRole'
    assignableScopes: [subscription().id]
    permissions: [{
      actions: [
        'Microsoft.ContainerService/managedClusters/read'
        'Microsoft.ContainerService/managedClusters/runcommand/action'
        'Microsoft.ContainerService/managedClusters/commandResults/read'
        'Microsoft.ContainerRegistry/registries/read'
        'Microsoft.Cache/redisEnterprise/databases/read'
        'Microsoft.Cache/redisEnterprise/databases/listKeys/action'
        'Microsoft.Network/trafficManagerProfiles/read'
        'Microsoft.Storage/storageAccounts/read'
      ]
      notActions: []
      dataActions: []
      notDataActions: []
    }]
  }
}
module bootstrap 'modules/workshop-bootstrap.bicep' = if (deployWorkshopBootstrap) {
  name: 'workshop-bootstrap'
  scope: global
  params: {
    prefix: prefix
    location: primaryLocation
    tags: tags
    config: environmentConfig
    administratorLogin: administratorLogin
    administratorPassword: administratorPassword
    runbookUri: bootstrapRunbookUri
    runbookSha256: bootstrapRunbookSha256
    imageUri: appImageArchiveUri
    imageSha256: appImageArchiveSha256
  }
}
module bootstrapAccessKrc 'modules/workshop-access.bicep' = if (deployWorkshopBootstrap) {
  name: 'workshop-access-krc'
  scope: krc
  params: {
    clusterName: aksKrc.outputs.config.name
    registryName: acr.outputs.config.name
    operatorRoleId: bootstrapOperator!.id
    automationPrincipalId: bootstrap!.outputs.automationPrincipalId
    runnerPrincipalId: bootstrap!.outputs.runnerPrincipalId
  }
}
module bootstrapAccessKrs 'modules/workshop-access.bicep' = if (deployWorkshopBootstrap) {
  name: 'workshop-access-krs'
  scope: krs
  params: {
    clusterName: aksKrs.outputs.config.name
    operatorRoleId: bootstrapOperator!.id
    automationPrincipalId: bootstrap!.outputs.automationPrincipalId
    runnerPrincipalId: bootstrap!.outputs.runnerPrincipalId
  }
}
module bootstrapGlobalAccess 'modules/workshop-access.bicep' = if (deployWorkshopBootstrap) {
  name: 'workshop-access-global'
  scope: global
  params: {
    runnerPrincipalId: bootstrap!.outputs.runnerPrincipalId
    operatorRoleId: bootstrapOperator!.id
  }
}
module bootstrapStart 'modules/workshop-start.bicep' = if (deployWorkshopBootstrap) {
  name: 'workshop-start'
  scope: global
  params: {
    accountName: bootstrap!.outputs.accountName
    jobId: guid(deployment().name, prefix, bootstrapRunId)
  }
  dependsOn: [bootstrapAccessKrc, bootstrapAccessKrs, bootstrapGlobalAccess]
}

// ARM reports infrastructure/trigger completion, not asynchronous application success.
output config object = union(environmentConfig, {
  bootstrap: deployWorkshopBootstrap ? {
    accountName: bootstrap!.outputs.accountName
    jobId: bootstrapStart!.outputs.jobId
    operatorRoleId: bootstrapOperator!.id
    applicationStatus: 'Pending: verify Automation job Completed and Kubernetes workshop-bootstrap-status'
    sampleDataStatus: 'Pending: verify Kubernetes workshop-bootstrap Job Complete separately'
  } : {}
})
