param clusterName string = ''
param registryName string = ''
param operatorRoleId string
param automationPrincipalId string = ''
param runnerPrincipalId string

resource cluster 'Microsoft.ContainerService/managedClusters@2026-01-01' existing = if (!empty(clusterName)) { name: clusterName }
resource registry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = if (!empty(registryName)) {
  name: registryName
}
resource automationAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(clusterName)) {
  name: guid(cluster!.id, automationPrincipalId, operatorRoleId)
  scope: cluster!
  properties: {
    principalId: automationPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: operatorRoleId
  }
}
resource runnerAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, runnerPrincipalId, operatorRoleId)
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: operatorRoleId
  }
}
resource push 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(registryName)) {
  name: guid(registry!.id, runnerPrincipalId, 'AcrPush')
  scope: registry!
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')
  }
}
