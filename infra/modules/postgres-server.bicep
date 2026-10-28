param name string
param location string
param tags object
param vmSize string
param sourceServerId string = ''
@secure()
param administratorLogin string = ''
@secure()
param administratorPassword string = ''
param workspaceId string
param subnetId string
param dnsZoneId string
// Required: read replicas are not supported in Burstable.
// https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas
resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2026-10-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: vmSize, tier: 'GeneralPurpose' }
  properties: {
    createMode: empty(sourceServerId) ? 'Default' : 'Replica'
    sourceServerResourceId: empty(sourceServerId) ? null : sourceServerId
    administratorLogin: empty(sourceServerId) ? administratorLogin : null
    administratorLoginPassword: empty(sourceServerId) ? administratorPassword : null
    version: '16'
    storage: { storageSizeGB: 32, autoGrow: 'Disabled', tier: 'P4', type: 'Premium_LRS' }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    network: { publicNetworkAccess: 'Disabled' }
  }
}
module pe 'pe.bicep' = {
  name: 'postgres-pe'
  params: {
    name: 'pe-${name}'
    location: location
    tags: tags
    subnetId: subnetId
    targetId: server.id
    groupId: 'postgresqlServer'
    dnsZoneId: dnsZoneId
  }
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'replication-metrics'
  scope: server
  properties: { workspaceId: workspaceId, metrics: [{ category: 'AllMetrics', enabled: true }] }
}
output config object = { id: server.id, name: server.name, host: server.properties.fullyQualifiedDomainName }
output privateIp string = pe.outputs.privateIp
