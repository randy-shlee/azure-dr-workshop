param prefix string
param tags object
param primarySubnetId string
param secondarySubnetId string
param primaryDnsZoneId string
param secondaryDnsZoneId string
@secure()
param administratorLogin string
@secure()
param administratorPassword string
param vmSize string = 'Standard_D2ds_v5'
param workspaceId string

module primary 'postgres-server.bicep' = {
  name: 'pg-primary'
  params: {
    name: 'pg-${prefix}-krc'
    location: 'koreacentral'
    tags: tags
    vmSize: vmSize
    administratorLogin: administratorLogin
    administratorPassword: administratorPassword
    workspaceId: workspaceId
    subnetId: primarySubnetId
    dnsZoneId: primaryDnsZoneId
  }
}
module secondary 'postgres-server.bicep' = {
  name: 'pg-replica'
  scope: resourceGroup('rg-${prefix}-krs')
  params: {
    name: 'pg-${prefix}-krs'
    location: 'koreasouth'
    tags: tags
    vmSize: vmSize
    sourceServerId: primary.outputs.config.id
    workspaceId: workspaceId
    subnetId: secondarySubnetId
    dnsZoneId: secondaryDnsZoneId
  }
}
resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2026-10-01' existing = { name: 'pg-${prefix}-krc' }
// One ReadWrite resource creates BOTH aliases; members selects the reader target.
resource endpoints 'Microsoft.DBforPostgreSQL/flexibleServers/virtualendpoints@2026-10-01' = {
  parent: server
  name: '${prefix}-pg-dr'
  properties: { endpointType: 'ReadWrite', members: [secondary.outputs.config.name] }
}
// Both regional zones need both server records: writer/reader aliases change
// targets after switchover, and peering alone does not share private DNS.
module remoteInPrimary 'dns-record.bicep' = {
  name: 'pg-krs-record-in-krc'
  params: {
    zoneName: 'privatelink.postgres.database.azure.com'
    recordName: secondary.outputs.config.name
    address: secondary.outputs.privateIp
  }
}
module remoteInSecondary 'dns-record.bicep' = {
  name: 'pg-krc-record-in-krs'
  scope: resourceGroup('rg-${prefix}-krs')
  params: {
    zoneName: 'privatelink.postgres.database.azure.com'
    recordName: primary.outputs.config.name
    address: primary.outputs.privateIp
  }
}
output config object = {
  database: 'postgres'
  primary: primary.outputs.config
  secondary: secondary.outputs.config
  writerEndpoint: '${endpoints.name}.writer.postgres.database.azure.com'
  readerEndpoint: '${endpoints.name}.reader.postgres.database.azure.com'
}
