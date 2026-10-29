param name string
param location string
param tags object
param subnetId string
param targetId string
param groupId string
param dnsZoneId string

resource endpoint 'Microsoft.Network/privateEndpoints@2025-05-01' = {
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
resource dns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [{ name: 'service', properties: { privateDnsZoneId: dnsZoneId } }]
  }
}
output id string = endpoint.id
module address 'pe-nic.bicep' = {
  name: '${name}-address'
  params: { name: '${name}-nic' }
  dependsOn: [endpoint]
}
output privateIp string = address.outputs.privateIp
