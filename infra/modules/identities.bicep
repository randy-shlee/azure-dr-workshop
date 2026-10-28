param prefix string
param region string
param location string
param tags object
param deploySampleIdentity bool = false

resource app 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${prefix}-app-${region}'
  location: location
  tags: tags
}
resource cluster 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${prefix}-aks-${region}'
  location: location
  tags: tags
}
resource kubelet 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${prefix}-kubelet-${region}'
  location: location
  tags: tags
}
resource sample 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (deploySampleIdentity) {
  name: 'id-${prefix}-sampledata'
  location: location
  tags: tags
}
output app object = {
  id: app.id
  name: app.name
  clientId: app.properties.clientId
  principalId: app.properties.principalId
}
output cluster object = {
  id: cluster.id
  principalId: cluster.properties.principalId
}
output kubelet object = {
  id: kubelet.id
  clientId: kubelet.properties.clientId
  principalId: kubelet.properties.principalId
}
output sample object = deploySampleIdentity ? {
  id: sample!.id
  name: sample!.name
  clientId: sample!.properties.clientId
  principalId: sample!.properties.principalId
} : {}
