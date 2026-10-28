param prefix string
param location string
param tags object
resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: 'log-${prefix}-krc'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}
// Platform diagnostic export does not require public data-plane ingestion.
// No AMPLS/PE is added merely to query logs; use ARM metrics for basic drills.
output id string = workspace.id

resource scope 'Microsoft.Insights/privateLinkScopes@2021-09-01' = {
  name: 'ampls-${prefix}'
  location: 'global'
  tags: tags
  properties: { accessModeSettings: { ingestionAccessMode: 'PrivateOnly', queryAccessMode: 'PrivateOnly' } }
}
resource scopedWorkspace 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = {
  parent: scope
  name: 'workspace'
  properties: { linkedResourceId: workspace.id }
}
output scopeId string = scope.id
