param name string
param location string
param tags object
param subnetId string
param targetId string
param groupId string
param dnsZoneId string

resource endpoint 'Microsoft.Network/privateEndpoints@2026-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    customNetworkInterfaceName: '${name}-nic'
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: groupId
        properties: { privateLinkServiceId: targetId, groupIds: [groupId] }
      }
    ]
  }
}
resource dns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2026-07-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [{ name: 'service', properties: { privateDnsZoneId: dnsZoneId } }]
  }
}
output id string = endpoint.id
resource nic 'Microsoft.Network/networkInterfaces@2026-07-01' existing = { name: '${name}-nic' }
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
