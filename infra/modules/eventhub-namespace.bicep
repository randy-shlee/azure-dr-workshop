param name string
param location string
param tags object
param principalIds array
param workspaceId string
param createHub bool = false

resource ns 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Standard', capacity: 1 }
  properties: {
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
    zoneRedundant: false
    isAutoInflateEnabled: false
    kafkaEnabled: false
  }
}
// The passive namespace must start empty; Geo-DR copies this entity's metadata.
resource hub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = if (createHub) {
  parent: ns
  name: 'drtest-events'
  properties: {
    partitionCount: 1
    retentionDescription: { cleanupPolicy: 'Delete', retentionTimeInHours: 24 }
  }
}
// Geo-DR does not replicate Entra role assignments.
resource grants 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in principalIds: {
  name: guid(ns.id, principalId, 'eh-owner')
  scope: ns
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'f526a384-b230-433a-b45c-95f59c4a2dec')
  }
}]
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'application-metrics'
  scope: ns
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ category: 'OperationalLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}
output config object = { id: ns.id, name: ns.name, host: '${ns.name}.servicebus.windows.net' }
