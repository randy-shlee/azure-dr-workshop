param prefix string
param tags object
param primarySubnetId string
param secondarySubnetId string
param primaryDnsZoneId string
param secondaryDnsZoneId string
param kubeletPrincipalIds array
param enableGeoReplication bool = false
// Required: Private Link is only available in Premium.
// https://learn.microsoft.com/azure/container-registry/container-registry-private-link
resource registry 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: '${replace(prefix, '-', '')}acrkrc${uniqueString(subscription().id, prefix)}'
  location: 'koreacentral'
  tags: tags
  sku: { name: 'Premium' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'None'
    zoneRedundancy: 'Disabled'
    policies: { exportPolicy: { status: 'disabled' } }
  }
}
resource replication 'Microsoft.ContainerRegistry/registries/replications@2025-11-01' = if (enableGeoReplication) {
  parent: registry
  name: 'koreasouth'
  location: 'koreasouth'
  tags: tags
  properties: { zoneRedundancy: 'Disabled', regionEndpointEnabled: true }
}
resource grants 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in kubeletPrincipalIds: {
  name: guid(registry.id, principalId, 'acr-pull')
  scope: registry
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}]
module primaryPe 'pe.bicep' = {
  name: 'acr-pe-krc'
  params: {
    name: 'pe-${prefix}-acr-krc'
    location: 'koreacentral'
    tags: tags
    subnetId: primarySubnetId
    targetId: registry.id
    groupId: 'registry'
    dnsZoneId: primaryDnsZoneId
  }
  dependsOn: [replication]
}
module secondaryPe 'pe.bicep' = {
  name: 'acr-pe-krs'
  scope: resourceGroup('rg-${prefix}-krs')
  params: {
    name: 'pe-${prefix}-acr-krs'
    location: 'koreasouth'
    tags: tags
    subnetId: secondarySubnetId
    targetId: registry.id
    groupId: 'registry'
    dnsZoneId: secondaryDnsZoneId
  }
  dependsOn: [replication]
}
output config object = { id: registry.id, name: registry.name, loginServer: registry.properties.loginServer }
