param prefix string
param tags object
param primarySubnetId string
param secondarySubnetId string
param primaryDnsZoneId string
param secondaryDnsZoneId string
param principalIds array
module primary 'search-service.bicep' = {
  name: 'search-krc'
  params: {
    name: 'srch-${prefix}-krc'
    location: 'koreacentral'
    tags: tags
    subnetId: primarySubnetId
    dnsZoneId: primaryDnsZoneId
    principalIds: principalIds
  }
}
module secondary 'search-service.bicep' = {
  name: 'search-krs'
  scope: resourceGroup('rg-${prefix}-krs')
  params: {
    name: 'srch-${prefix}-krs'
    location: 'koreasouth'
    tags: tags
    subnetId: secondarySubnetId
    dnsZoneId: secondaryDnsZoneId
    principalIds: principalIds
  }
}
output config object = { primary: primary.outputs.config, secondary: secondary.outputs.config }
