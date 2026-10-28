param prefix string
param tags object
param primarySubnetId string
param secondarySubnetId string
param primaryDnsZoneId string
param secondaryDnsZoneId string
// Create the first geo-enabled database, then join the second with both IDs.
// No cyclic deployment dependency or destructive force-link action is needed.
module primary 'redis-instance.bicep' = {
  name: 'redis-krc'
  params: {
    name: 'redis-${prefix}-krc'
    location: 'koreacentral'
    tags: tags
    subnetId: primarySubnetId
    dnsZoneId: primaryDnsZoneId
    groupNickname: '${prefix}-dr'
  }
}
module secondary 'redis-instance.bicep' = {
  name: 'redis-krs'
  scope: resourceGroup('rg-${prefix}-krs')
  params: {
    name: 'redis-${prefix}-krs'
    location: 'koreasouth'
    tags: tags
    subnetId: secondarySubnetId
    dnsZoneId: secondaryDnsZoneId
    groupNickname: '${prefix}-dr'
    existingDatabaseId: primary.outputs.databaseId
  }
}
output config object = { primary: primary.outputs.config, secondary: secondary.outputs.config }
