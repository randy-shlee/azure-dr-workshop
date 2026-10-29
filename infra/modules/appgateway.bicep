param prefix string
param region string
param location string
param tags object
param subnetId string
param aksSubnetPrefix string
param allowedClientCidrs array
param backendAddress string

// Required only when explicitly selected: WAF requires WAF_v2. Capacity 1,
// no zones/autoscale; this optional path costs much more than an AKS public LB.
resource pip 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: 'pip-${prefix}-appgw-${region}'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: '${prefix}-appgw-${region}' }
  }
}
var gatewayName = 'agw-${prefix}-${region}'
var gatewayId = resourceId('Microsoft.Network/applicationGateways', gatewayName)
resource policy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2025-05-01' = {
  name: 'waf-${prefix}-${region}'
  location: location
  tags: tags
  properties: {
    policySettings: { state: 'Enabled', mode: 'Prevention' }
    managedRules: { managedRuleSets: [{ ruleSetType: 'OWASP', ruleSetVersion: '3.2' }] }
    customRules: [
      {
        name: 'AllowTrafficManagerProbes'
        priority: 1
        ruleType: 'MatchRule'
        action: 'Allow'
        matchConditions: [
          { matchVariables: [{ variableName: 'RequestUri' }], operator: 'Equal', matchValues: ['/healthz'] }
        ]
      }
      {
        name: 'DenyOtherClients'
        priority: 2
        ruleType: 'MatchRule'
        action: 'Block'
        matchConditions: [
          {
            matchVariables: [{ variableName: 'RemoteAddr' }]
            operator: 'IPMatch'
            negationConditon: true
            matchValues: allowedClientCidrs
          }
        ]
      }
    ]
  }
}
resource gateway 'Microsoft.Network/applicationGateways@2025-05-01' = {
  name: gatewayName
  location: location
  tags: tags
  properties: {
    sku: { name: 'WAF_v2', tier: 'WAF_v2', capacity: 1 }
    firewallPolicy: { id: policy.id }
    enableHttp2: false
    gatewayIPConfigurations: [{ name: 'gateway', properties: { subnet: { id: subnetId } } }]
    frontendIPConfigurations: [{ name: 'public', properties: { publicIPAddress: { id: pip.id } } }]
    frontendPorts: [{ name: 'http', properties: { port: 80 } }]
    backendAddressPools: [{ name: 'aks', properties: { backendAddresses: [{ ipAddress: backendAddress }] } }]
    backendHttpSettingsCollection: [
      {
        name: 'http'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          probe: { id: '${gatewayId}/probes/health' }
        }
      }
    ]
    probes: [
      {
        name: 'health'
        properties: {
          protocol: 'Http'
          host: '127.0.0.1'
          path: '/healthz'
          interval: 30
          timeout: 10
          unhealthyThreshold: 3
          match: { statusCodes: ['200-399'] }
        }
      }
    ]
    httpListeners: [
      {
        name: 'http'
        properties: {
          frontendIPConfiguration: { id: '${gatewayId}/frontendIPConfigurations/public' }
          frontendPort: { id: '${gatewayId}/frontendPorts/http' }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'aks'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: { id: '${gatewayId}/httpListeners/http' }
          backendAddressPool: { id: '${gatewayId}/backendAddressPools/aks' }
          backendHttpSettings: { id: '${gatewayId}/backendHttpSettingsCollection/http' }
        }
      }
    ]
  }
}
output config object = {
  id: gateway.id
  name: gateway.name
  address: pip.properties.ipAddress
  fqdn: pip.properties.dnsSettings.fqdn
  publicIpId: pip.id
  backendAddress: backendAddress
  backendSourceCidr: aksSubnetPrefix
}
