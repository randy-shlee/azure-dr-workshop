param localVnetName string
param remoteVnetId string
resource local 'Microsoft.Network/virtualNetworks@2026-07-01' existing = { name: localVnetName }
resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2026-07-01' = {
  parent: local
  name: 'peer-other-region'
  properties: {
    remoteVirtualNetwork: { id: remoteVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}
