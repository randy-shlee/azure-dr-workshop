targetScope = 'subscription'

@description('Non-secret config output from the existing workshop deployment. Updates only Event Hubs; does not redeploy Storage, PostgreSQL, Redis or AKS.')
param existingConfig object
param enableEventHubsGeoRecovery bool = true

resource primaryGroup 'Microsoft.Resources/resourceGroups@2023-07-01' existing = {
  name: existingConfig.primaryResourceGroup
}
module eventhubs 'modules/eventhubs.bicep' = {
  name: 'eventhubs-standard-update'
  scope: primaryGroup
  params: {
    prefix: existingConfig.prefix
    tags: primaryGroup.tags
    primarySubnetId: resourceId(subscription().subscriptionId, existingConfig.primaryResourceGroup, 'Microsoft.Network/virtualNetworks/subnets', 'vnet-${existingConfig.prefix}-krc', 'snet-pe')
    secondarySubnetId: resourceId(subscription().subscriptionId, existingConfig.secondaryResourceGroup, 'Microsoft.Network/virtualNetworks/subnets', 'vnet-${existingConfig.prefix}-krs', 'snet-pe')
    primaryDnsZoneId: resourceId(subscription().subscriptionId, existingConfig.primaryResourceGroup, 'Microsoft.Network/privateDnsZones', 'privatelink.servicebus.windows.net')
    secondaryDnsZoneId: resourceId(subscription().subscriptionId, existingConfig.secondaryResourceGroup, 'Microsoft.Network/privateDnsZones', 'privatelink.servicebus.windows.net')
    principalIds: [existingConfig.primary.identity.principalId, existingConfig.secondary.identity.principalId]
    workspaceId: existingConfig.workspaceId
    enableGeoRecovery: enableEventHubsGeoRecovery
  }
}
var features = toObject(
  filter(items(existingConfig.features), item => item.key != 'enableEventHubsGeoReplication'),
  item => item.key,
  item => item.value
)
output config object = shallowMerge([existingConfig, {
  schemaVersion: 2
  eventHubs: eventhubs.outputs.config
  primary: shallowMerge([existingConfig.primary, { eventHubs: eventhubs.outputs.config.primary }])
  secondary: shallowMerge([existingConfig.secondary, { eventHubs: eventhubs.outputs.config.secondary }])
  features: union(features, { deployEventHubs: true, enableEventHubsGeoRecovery: enableEventHubsGeoRecovery })
}])
