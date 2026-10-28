param redisName string
param workspaceId string
resource redis 'Microsoft.Cache/redisEnterprise@2026-09-01' existing = { name: redisName }
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'geo-health-for-alert'
  scope: redis
  properties: {
    workspaceId: workspaceId
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}
