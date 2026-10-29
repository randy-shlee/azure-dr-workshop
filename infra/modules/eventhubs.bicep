param prefix string
param tags object
param primarySubnetId string
param secondarySubnetId string
param primaryDnsZoneId string
param secondaryDnsZoneId string
param principalIds array
param enableGeoRecovery bool = true
param workspaceId string
module primary 'eventhub-namespace.bicep' = {
  name: 'eh-namespace-krc'
  params: {
    name: 'eh-${prefix}-krc'
    location: 'koreacentral'
    tags: tags
    principalIds: principalIds
    workspaceId: workspaceId
    createHub: true
  }
}
module secondary 'eventhub-namespace.bicep' = {
  name: 'eh-namespace-krs'
  scope: resourceGroup('rg-${prefix}-krs')
  params: {
    name: 'eh-${prefix}-krs'
    location: 'koreasouth'
    tags: tags
    principalIds: principalIds
    workspaceId: workspaceId
  }
}
module primaryPe 'pe.bicep' = {
  name: 'eh-pe-krc'
  params: {
    name: 'pe-${prefix}-eh-krc'
    location: 'koreacentral'
    tags: tags
    subnetId: primarySubnetId
    targetId: primary.outputs.config.id
    groupId: 'namespace'
    dnsZoneId: primaryDnsZoneId
  }
}
module secondaryPe 'pe.bicep' = {
  name: 'eh-pe-krs'
  scope: resourceGroup('rg-${prefix}-krs')
  params: {
    name: 'pe-${prefix}-eh-krs'
    location: 'koreasouth'
    tags: tags
    subnetId: secondarySubnetId
    targetId: secondary.outputs.config.id
    groupId: 'namespace'
    dnsZoneId: secondaryDnsZoneId
  }
}
// Both VNets must resolve both namespaces after an independent app failback.
module primaryInSecondary 'pe.bicep' = {
  name: 'eh-krc-pe-in-krs'
  scope: resourceGroup('rg-${prefix}-krs')
  params: {
    name: 'pe-${prefix}-eh-krc-in-krs'
    location: 'koreasouth'
    tags: tags
    subnetId: secondarySubnetId
    targetId: primary.outputs.config.id
    groupId: 'namespace'
    dnsZoneId: secondaryDnsZoneId
  }
}
module secondaryInPrimary 'pe.bicep' = {
  name: 'eh-krs-pe-in-krc'
  params: {
    name: 'pe-${prefix}-eh-krs-in-krc'
    location: 'koreacentral'
    tags: tags
    subnetId: primarySubnetId
    targetId: secondary.outputs.config.id
    groupId: 'namespace'
    dnsZoneId: primaryDnsZoneId
  }
}
resource ns 'Microsoft.EventHub/namespaces@2024-01-01' existing = { name: 'eh-${prefix}-krc' }
var aliasName = 'eh-${prefix}-dr'
resource alias 'Microsoft.EventHub/namespaces/disasterRecoveryConfigs@2024-01-01' = if (enableGeoRecovery) {
  parent: ns
  name: aliasName
  properties: { partnerNamespace: secondary.outputs.config.id }
  dependsOn: [primaryPe, secondaryPe, primaryInSecondary, secondaryInPrimary]
}
var host = enableGeoRecovery ? '${aliasName}.servicebus.windows.net' : primary.outputs.config.host
output config object = {
  aliasName: enableGeoRecovery ? aliasName : ''
  host: host
  recoveryMode: enableGeoRecovery ? 'MetadataOnlyGeoRecovery' : 'Unpaired'
  dataReplicated: false
  primary: union(primary.outputs.config, { host: host })
  secondary: union(secondary.outputs.config, { host: host })
}
