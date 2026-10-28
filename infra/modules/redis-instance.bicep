param name string
param location string
param tags object
param subnetId string
param dnsZoneId string
param groupNickname string
param existingDatabaseId string = ''
// Required: B0/B1 cannot geo-replicate. Active geo also REQUIRES HA, even for
// this test. No zones or optional extra capacity are requested.
// TODO: Check Korea South B3 capacity; disable deployRedis if unavailable.
// https://learn.microsoft.com/azure/redis/how-to-active-geo-replication
resource redis 'Microsoft.Cache/redisEnterprise@2026-09-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Balanced_B3' }
  properties: { publicNetworkAccess: 'Disabled', minimumTlsVersion: '1.2', highAvailability: 'Enabled' }
}
var databaseId = '${redis.id}/databases/default'
resource database 'Microsoft.Cache/redisEnterprise/databases@2026-09-01' = {
  parent: redis
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'OSSCluster'
    evictionPolicy: 'NoEviction'
    persistence: { aofEnabled: false, rdbEnabled: false }
    geoReplication: {
      groupNickname: groupNickname
      linkedDatabases: empty(existingDatabaseId) ? [{ id: databaseId }] : [{ id: existingDatabaseId }, { id: databaseId }]
    }
  }
}
module pe 'pe.bicep' = {
  name: 'redis-pe'
  params: {
    name: 'pe-${name}'
    location: location
    tags: tags
    subnetId: subnetId
    targetId: redis.id
    groupId: 'redisEnterprise'
    dnsZoneId: dnsZoneId
  }
}
output config object = { id: redis.id, name: redis.name, host: redis.properties.hostName, port: 10000 }
output databaseId string = database.id
