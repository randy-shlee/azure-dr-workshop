param prefix string
param tags object
param owner string
param postgresIds array
param eventHubsIds array = []
param redisIds array = []
param storageId string
param trafficManagerId string
param workspaceId string
param workspaceLocation string = 'koreacentral'
param replicationLagSeconds int = 300
param enableStorageLastSyncCustomMetricAlert bool = false

resource action 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${prefix}-owner'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'drtest'
    enabled: true
    emailReceivers: [{ name: 'owner', emailAddress: owner, useCommonAlertSchema: true }]
  }
}
module pg 'metric-alert.bicep' = [for (id, i) in postgresIds: {
  name: 'pg-alert-${i}'
  params: {
    name: '${prefix}-pg-lag-${i}'
    tags: tags
    resourceId: id
    actionGroupId: action.id
    metricNamespace: 'Microsoft.DBforPostgreSQL/flexibleServers'
    metricName: 'physical_replication_delay_in_seconds'
    threshold: replicationLagSeconds
    description: 'Read-replica lag; monitor both servers so alerts survive switchover.'
  }
}]
module eh 'metric-alert.bicep' = [for (id, i) in eventHubsIds: {
  name: 'eh-alert-${i}'
  params: {
    name: '${prefix}-eh-server-errors-${i}'
    tags: tags
    resourceId: id
    actionGroupId: action.id
    metricNamespace: 'Microsoft.EventHub/namespaces'
    metricName: 'ServerErrors'
    threshold: 0
    aggregation: 'Total'
    description: 'Standard namespace server errors. Geo-DR replicates metadata only; no event-data replication lag exists.'
  }
}]
// A 1h metric window alone can fire on its first zero sample. Require all 60
// completed one-minute buckets to be present and unhealthy instead.
resource redis 'Microsoft.Insights/scheduledQueryRules@2026-03-01' = if (!empty(redisIds)) {
  name: '${prefix}-redis-unhealthy-60min'
  location: workspaceLocation
  tags: tags
  properties: {
    displayName: 'Redis geo replication unhealthy for 60 complete minutes'
    description: 'Missing samples prevent the sustained-unhealthy test, rather than counting as healthy or unhealthy.'
    severity: 3
    enabled: true
    scopes: [workspaceId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT1H'
    // Include the complete oldest minute even when evaluation runs mid-minute.
    overrideQueryTimeRange: 'PT2H'
    autoMitigate: true
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: replace('''
            let endTime = bin(now(), 1m);
            let startTime = endTime - 60m;
            let targets = dynamic(__TARGETS__);
            AzureMetrics
            | where TimeGenerated >= startTime and TimeGenerated < endTime
            | where tolower(_ResourceId) in (targets)
            | where MetricName =~ "geoReplicationHealthy"
            | where isnotnull(Maximum)
            | summarize Health=max(Maximum) by _ResourceId, bin(TimeGenerated, 1m)
            | summarize Samples=count(), MaxHealth=max(Health) by _ResourceId
            | where Samples == 60 and MaxHealth == 0
            ''', '__TARGETS__', string(map(redisIds, id => toLower(id))))
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          resourceIdColumn: '_ResourceId'
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [action.id] }
  }
}
module storageLag 'metric-alert.bicep' = {
  name: 'storage-replication-lag-alert'
  params: {
    name: '${prefix}-storage-replication-lag'
    tags: tags
    resourceId: storageId
    actionGroupId: action.id
    metricNamespace: 'Microsoft.Storage/storageAccounts'
    metricName: 'ReplicationLagSeconds'
    threshold: replicationLagSeconds
    description: 'Native blob replication lag, not a substitute for Last Sync Time age.'
  }
}
module storage 'metric-alert.bicep' = if (enableStorageLastSyncCustomMetricAlert) {
  name: 'storage-sync-alert'
  params: {
    name: '${prefix}-storage-last-sync-age'
    tags: tags
    resourceId: storageId
    actionGroupId: action.id
    metricNamespace: 'drtest'
    metricName: 'LastSyncAgeSeconds'
    threshold: replicationLagSeconds
    windowSize: 'PT15M'
    skipMetricValidation: true
    description: 'Requires publish-storage-sync-metric.sh every 10min; Last Sync Time is an ARM property, not a native metric. No publisher means no alert.'
  }
}
module tm 'metric-alert.bicep' = {
  name: 'tm-alert'
  params: {
    name: '${prefix}-tm-degraded'
    tags: tags
    resourceId: trafficManagerId
    actionGroupId: action.id
    metricNamespace: 'Microsoft.Network/trafficManagerProfiles'
    metricName: 'ProbeAgentCurrentEndpointStateByProfileResourceId'
    threshold: 1
    operator: 'LessThan'
    aggregation: 'Maximum'
    dimensions: [{ name: 'EndpointName', operator: 'Include', values: ['*'] }]
    description: 'Traffic Manager endpoint is not Online (Disabled during drills also needs operator interpretation).'
  }
}
