param name string
param tags object
param resourceId string
param actionGroupId string
param metricNamespace string
param metricName string
param threshold int
param operator string = 'GreaterThan'
param aggregation string = 'Maximum'
param windowSize string = 'PT5M'
param dimensions array = []
param skipMetricValidation bool = false
param description string
resource alert 'Microsoft.Insights/metricAlerts@2026-01-01' = {
  name: name
  location: 'global'
  tags: tags
  properties: {
    description: description
    severity: 3
    enabled: true
    autoMitigate: true
    evaluationFrequency: 'PT1M'
    windowSize: windowSize
    scopes: [resourceId]
    actions: [{ actionGroupId: actionGroupId }]
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'threshold'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: metricNamespace
          metricName: metricName
          operator: operator
          threshold: threshold
          timeAggregation: aggregation
          dimensions: dimensions
          skipMetricValidation: skipMetricValidation
        }
      ]
    }
  }
}
