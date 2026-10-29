param name string

resource nic 'Microsoft.Network/networkInterfaces@2025-05-01' existing = {
  name: name
}
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
