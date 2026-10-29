param prefix string
param tags object
param primarySubnetId string
param secondarySubnetId string
param primaryDnsZoneId string
param secondaryDnsZoneId string
param principalIds array
param samplePrincipalId string
var name = '${replace(prefix, '-', '')}stkrc${uniqueString(subscription().id, prefix)}'
resource account 'Microsoft.Storage/storageAccounts@2026-09-01' = {
  name: take(name, 24)
  location: 'koreacentral'
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_RAGRS' }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2026-09-01' = {
  parent: account
  name: 'default'
  properties: {
    isVersioningEnabled: false
    deleteRetentionPolicy: { enabled: false }
    containerDeleteRetentionPolicy: { enabled: false }
    changeFeed: { enabled: false }
  }
}
resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2026-09-01' = [for container in ['drtest', 'sampledata']: {
  parent: blobs
  name: container
  properties: { publicAccess: 'None' }
}]
resource grants 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in union(principalIds, [samplePrincipalId]): {
  name: guid(account.id, principalId, 'blob-contributor')
  scope: account
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}]
// Blob data RBAC does not allow ARM geoReplicationStats (Last Sync Time).
// Reader is scoped to this account only, for the DR dashboard.
resource dashboardReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in principalIds: {
  name: guid(account.id, principalId, 'dashboard-reader')
  scope: account
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}]
module primaryPe 'pe.bicep' = {
  name: 'storage-pe-krc'
  params: {
    name: 'pe-${prefix}-blob-krc'
    location: 'koreacentral'
    tags: tags
    subnetId: primarySubnetId
    targetId: account.id
    groupId: 'blob'
    dnsZoneId: primaryDnsZoneId
  }
}
module secondaryPe 'pe.bicep' = [for group in ['blob', 'blob_secondary']: {
  name: 'storage-pe-krs-${group}'
  scope: resourceGroup('rg-${prefix}-krs')
  params: {
    name: 'pe-${prefix}-${replace(group, '_', '-')}-krs'
    location: 'koreasouth'
    tags: tags
    subnetId: secondarySubnetId
    targetId: account.id
    groupId: group
    dnsZoneId: secondaryDnsZoneId
  }
}]
// The KRC dashboard also probes the read-only secondary. Its local zone must
// resolve that hostname to the KRS PE, reachable via global VNet peering.
module secondaryRecordInPrimary 'dns-record.bicep' = {
  name: 'storage-secondary-record-in-krc'
  params: {
    zoneName: 'privatelink.blob.${environment().suffixes.storage}'
    recordName: '${account.name}-secondary'
    address: secondaryPe[1].outputs.privateIp
  }
}
// Planned account failover preserves RA-GRS and the primary blob hostname.
// Both regional apps use that hostname; -secondary is a replication probe only.
// https://learn.microsoft.com/azure/storage/common/storage-disaster-recovery-guidance
output config object = {
  id: account.id
  name: account.name
  redundancy: 'Standard_RAGRS'
  failoverType: 'Planned'
  primaryEndpoint: account.properties.primaryEndpoints.blob
  secondaryEndpoint: account.properties.secondaryEndpoints.blob
  secondaryLocation: account.properties.secondaryLocation
}
