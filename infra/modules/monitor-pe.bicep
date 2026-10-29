param prefix string
param region string
param location string
param tags object
param subnetId string
param scopeId string
param dnsZoneIds object
var zones = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}'
]
// Required to keep the workspace data plane private as well as application PaaS.
resource endpoint 'Microsoft.Network/privateEndpoints@2025-05-01' = {
  name: 'pe-${prefix}-monitor-${region}'
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      { name: 'azuremonitor', properties: { privateLinkServiceId: scopeId, groupIds: ['azuremonitor'] } }
    ]
  }
}
resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (name, i) in zones: {
      name: 'zone-${i}'
      properties: { privateDnsZoneId: dnsZoneIds[name] }
    }]
  }
}
