param prefix string
param tags object
param primaryPublicIpId string
param secondaryPublicIpId string
param fastFailover bool = false
param workspaceId string

// DNS routing only: clients connect directly to each public IP, never through TM.
// Azure endpoints cannot target PE/private IPs. TTL/client caches govern cutover.
resource tm 'Microsoft.Network/trafficManagerProfiles@2026-09-01' = {
  name: 'tm-${prefix}-dr'
  location: 'global'
  tags: tags
  properties: {
    profileStatus: 'Enabled'
    trafficRoutingMethod: 'Priority'
    dnsConfig: { relativeName: '${prefix}-dr', ttl: fastFailover ? 0 : 60 }
    // Fast probing is billable at a higher rate; off for normal test operation.
    monitorConfig: {
      protocol: 'HTTP'
      port: 80
      path: '/healthz'
      intervalInSeconds: fastFailover ? 10 : 30
      timeoutInSeconds: fastFailover ? 5 : 10
      toleratedNumberOfFailures: fastFailover ? 1 : 3
    }
    endpoints: [
      {
        name: 'krc'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: primaryPublicIpId
          endpointStatus: 'Enabled'
          priority: 1
        }
      }
      {
        name: 'krs'
        type: 'Microsoft.Network/trafficManagerProfiles/azureEndpoints'
        properties: {
          targetResourceId: secondaryPublicIpId
          endpointStatus: 'Enabled'
          priority: 2
        }
      }
    ]
  }
}
// Diagnostic Settings has no GA API; this is the documented stable supported
// preview API: https://learn.microsoft.com/azure/templates/microsoft.insights/diagnosticsettings
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'endpoint-metrics'
  scope: tm
  properties: {
    workspaceId: workspaceId
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}
output config object = {
  id: tm.id
  name: tm.name
  fqdn: tm.properties.dnsConfig.fqdn
  primaryEndpointName: 'krc'
  secondaryEndpointName: 'krs'
}
