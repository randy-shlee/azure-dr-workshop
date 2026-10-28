param prefix string
param region string
param location string
param tags object
param subnetId string
param publicIpId string
param clusterIdentity object
param kubeletIdentity object
param appIdentityName string
param sampleIdentityName string = ''
param vmSize string = 'Standard_D4s_v5'
param nodeCount int = 2
// D4s_v5 has no local temporary disk. Set true only with a verified capable SKU.
param useEphemeralOsDisk bool = false
param kubernetesVersion string = ''
param podCidr string

resource kubelet 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: last(split(kubeletIdentity.id, '/'))
}
resource app 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = { name: appIdentityName }
resource sample 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = if (!empty(sampleIdentityName)) {
  name: sampleIdentityName
}
resource networkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, clusterIdentity.principalId, 'network')
  properties: {
    principalId: clusterIdentity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
  }
}
resource identityOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kubelet.id, clusterIdentity.principalId, 'operator')
  scope: kubelet
  properties: {
    principalId: clusterIdentity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'f1a07417-d97a-45cb-824c-7a7467783830')
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2026-08-01' = {
  name: 'aks-${prefix}-${region}'
  location: location
  tags: tags
  sku: { name: 'Base', tier: 'Free' }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${clusterIdentity.id}': {} }
  }
  properties: {
    dnsPrefix: '${prefix}-${region}'
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    nodeResourceGroup: 'rg-${prefix}-${region}-aks-managed'
    apiServerAccessProfile: {
      enablePrivateCluster: true
      enablePrivateClusterPublicFQDN: false
      privateDNSZone: 'system'
    }
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    identityProfile: {
      kubeletidentity: {
        resourceId: kubeletIdentity.id
        clientId: kubeletIdentity.clientId
        objectId: kubeletIdentity.principalId
      }
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        // Required: current system-pool limits exclude B-series and require
        // >=4 vCPUs / >=2 nodes. User approved this cost increase.
        // https://learn.microsoft.com/azure/aks/use-system-pools
        vmSize: vmSize
        count: nodeCount
        enableAutoScaling: false
        osDiskType: useEphemeralOsDisk ? 'Ephemeral' : 'Managed'
        osDiskSizeGB: 64
        vnetSubnetID: subnetId
        maxPods: 30
        nodeLabels: { purpose: 'dr-test' }
        tags: tags
        upgradeSettings: { maxSurge: '0', maxUnavailable: '1' }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      podCidr: podCidr
      serviceCidr: '172.20.0.0/16'
      dnsServiceIP: '172.20.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      // Reuse the user-owned frontend IP for outbound SNAT on the shared AKS LB;
      // no NAT Gateway or extra managed outbound public IP is requested.
      loadBalancerProfile: { outboundIPs: { publicIPs: [{ id: publicIpId }] } }
    }
    autoUpgradeProfile: { upgradeChannel: 'none', nodeOSUpgradeChannel: 'None' }
  }
  dependsOn: [networkRole, identityOperator]
}
resource appFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: app
  name: 'aks-${region}'
  properties: {
    audiences: ['api://AzureADTokenExchange']
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:drtest:drtest-app'
  }
}
resource sampleFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = if (!empty(sampleIdentityName)) {
  parent: sample
  name: 'aks-sampledata'
  properties: {
    audiences: ['api://AzureADTokenExchange']
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:drtest:sampledata-upload'
  }
}
output config object = {
  id: aks.id
  name: aks.name
  privateFqdn: aks.properties.privateFQDN
  oidcIssuer: aks.properties.oidcIssuerProfile.issuerURL
}
