param identityName string
param issuer string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: identityName
}
resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: identity
  name: 'aks-sampledata-krs'
  properties: {
    audiences: ['api://AzureADTokenExchange']
    issuer: issuer
    subject: 'system:serviceaccount:drtest:sampledata-upload'
  }
}
