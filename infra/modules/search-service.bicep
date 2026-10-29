param name string
param location string
param tags object
param subnetId string
param dnsZoneId string
param principalIds array
// Required: Basic is the minimum tier for Private Link.
// https://learn.microsoft.com/azure/search/service-create-private-endpoint
resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'basic' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'Default'
    publicNetworkAccess: 'disabled'
    disableLocalAuth: true
    semanticSearch: 'disabled'
  }
}
var assignments = flatten(map(principalIds, principalId => [
  { principalId: principalId, role: '8ebe5a00-799e-43f5-93ac-243d3dce84a7' }
  // Schema REST calls need Service Contributor, not just data-plane CRUD.
  { principalId: principalId, role: '7ca78c08-252a-4471-8644-bb5ff32d4ba0' }
]))
resource grants 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for assignment in assignments: {
  name: guid(search.id, assignment.principalId, assignment.role)
  scope: search
  properties: {
    principalId: assignment.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', assignment.role)
  }
}]
module pe 'pe.bicep' = {
  name: 'search-pe'
  params: {
    name: 'pe-${name}'
    location: location
    tags: tags
    subnetId: subnetId
    targetId: search.id
    groupId: 'searchService'
    dnsZoneId: dnsZoneId
  }
}
output config object = { id: search.id, name: search.name, endpoint: 'https://${search.name}.search.windows.net' }
