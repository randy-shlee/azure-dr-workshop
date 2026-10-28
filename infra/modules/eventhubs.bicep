param prefix string
param tags object
param primarySubnetId string
param secondarySubnetId string
param primaryDnsZoneId string
param secondaryDnsZoneId string
param principalIds array
param enableGeoReplication bool = true
@minValue(300)
@maxValue(86400)
param maxReplicationLagSeconds int = 300
param workspaceId string
// Required: data geo-replication needs Premium. The secondary bills the same PU.
// TODO: Verify Korea South Premium geo capacity; disable enableGeoReplication if unavailable.
// https://learn.microsoft.com/azure/event-hubs/geo-replication
resource ns 'Microsoft.EventHub/namespaces@2026-01-01' = {
  name: 'eh-${prefix}-krc'
  location: 'koreacentral'
  tags: tags
  sku: { name: 'Premium', tier: 'Premium', capacity: 1 }
  properties: {
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
    zoneRedundant: false
    isAutoInflateEnabled: false
    geoDataReplication: enableGeoReplication ? {
      maxReplicationLagDurationInSeconds: maxReplicationLagSeconds
      locations: [
        { locationName: 'koreacentral', roleType: 'Primary' }
        { locationName: 'koreasouth', roleType: 'Secondary' }
      ]
    } : null
  }
}
resource hub 'Microsoft.EventHub/namespaces/eventhubs@2026-01-01' = {
  parent: ns
  name: 'drtest-events'
  properties: {
    partitionCount: 1
    retentionDescription: { cleanupPolicy: 'Delete', retentionTimeInHours: 24 }
  }
}
resource grants 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in principalIds: {
  name: guid(ns.id, principalId, 'eh-owner')
  scope: ns
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'f526a384-b230-433a-b45c-95f59c4a2dec')
  }
}]
module primaryPe 'pe.bicep' = {
  name: 'eh-pe-krc'
  params: {
    name: 'pe-${prefix}-eh-krc'
    location: 'koreacentral'
    tags: tags
    subnetId: primarySubnetId
    targetId: ns.id
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
    targetId: ns.id
    groupId: 'namespace'
    dnsZoneId: secondaryDnsZoneId
  }
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'application-metrics'
  scope: ns
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ category: 'ApplicationMetricsLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}
output config object = {
  id: ns.id
  name: ns.name
  host: '${ns.name}.servicebus.windows.net'
  maxReplicationLagSeconds: maxReplicationLagSeconds
}
