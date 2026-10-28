param prefix string
param region string
param location string
param addressPrefix string
param subnetPrefix string
param tags object
param deployAppGateway bool = false
param deployDnsResolver bool = false
param allowedClientCidrs array = []

var zoneNames = [
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.servicebus.windows.net'
  'privatelink.postgres.database.azure.com'
  'privatelink.redis.azure.net'
  'privatelink.search.windows.net'
  'privatelink.azurecr.io'
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
]

resource gatewayNsg 'Microsoft.Network/networkSecurityGroups@2026-07-01' = if (deployAppGateway) {
  name: 'nsg-${prefix}-appgw-${region}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Clients'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefixes: allowedClientCidrs
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'TrafficManager'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'AzureTrafficManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'GatewayManager'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AzureLoadBalancer'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyOtherHttp'
        properties: {
          priority: 140
          access: 'Deny'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}
resource vnet 'Microsoft.Network/virtualNetworks@2026-07-01' = {
  name: 'vnet-${prefix}-${region}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: concat([
      {
        name: 'snet-aks'
        properties: { addressPrefix: '${subnetPrefix}.0.0/20' }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: '${subnetPrefix}.16.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ], deployAppGateway ? [
      {
        name: 'snet-appgw'
        properties: {
          addressPrefix: '${subnetPrefix}.17.0/24'
          networkSecurityGroup: { id: gatewayNsg!.id }
        }
      }
    ] : [], deployDnsResolver ? [
      {
        name: 'snet-resolver'
        properties: {
          addressPrefix: '${subnetPrefix}.18.0/28'
          delegations: [
            {
              name: 'dns'
              properties: { serviceName: 'Microsoft.Network/dnsResolvers' }
            }
          ]
        }
      }
    ] : [])
  }
}

// Separate resource groups give identical zone names distinct resource IDs.
// Never link a zone to the opposite region: split-horizon answers must stay local.
resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for name in zoneNames: {
  name: name
  location: 'global'
  tags: tags
}]
resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (name, i) in zoneNames: {
  parent: zones[i]
  name: 'link-${prefix}-${region}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

resource publicIp 'Microsoft.Network/publicIPAddresses@2026-07-01' = {
  name: 'pip-${prefix}-app-${region}'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: { domainNameLabel: '${prefix}-app-${region}' }
  }
}

// TODO: Check Korea South resolver availability before enabling (not needed for
// in-VNet PE resolution): https://learn.microsoft.com/azure/dns/dns-private-resolver-overview
resource resolver 'Microsoft.Network/dnsResolvers@2025-05-01' = if (deployDnsResolver) {
  name: 'dnsr-${prefix}-${region}'
  location: location
  tags: tags
  properties: { virtualNetwork: { id: vnet.id } }
}
resource inbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2025-05-01' = if (deployDnsResolver) {
  parent: resolver
  name: 'inbound'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Dynamic'
        subnet: { id: '${vnet.id}/subnets/snet-resolver' }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output aksSubnetId string = '${vnet.id}/subnets/snet-aks'
output peSubnetId string = '${vnet.id}/subnets/snet-pe'
output appGatewaySubnetId string = deployAppGateway ? '${vnet.id}/subnets/snet-appgw' : ''
output dnsZoneIds object = toObject(zoneNames, name => name, name => resourceId('Microsoft.Network/privateDnsZones', name))
output publicIp object = {
  id: publicIp.id
  name: publicIp.name
  address: publicIp.properties.ipAddress
  fqdn: publicIp.properties.dnsSettings.fqdn
}
