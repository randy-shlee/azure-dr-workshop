param zoneName string
param recordName string
param address string
resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = { name: zoneName }
resource record 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: zone
  name: recordName
  properties: { ttl: 60, aRecords: [{ ipv4Address: address }] }
}
