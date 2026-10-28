param prefix string
param location string
param tags object
param config object
@secure()
param administratorLogin string
@secure()
param administratorPassword string
@minLength(1)
param runbookUri string
@minLength(64)
@maxLength(64)
param runbookSha256 string
@minLength(1)
param imageUri string
@minLength(64)
@maxLength(64)
param imageSha256 string

// Explicit workshop-only exception approved for cloud runbooks. Private Link
// supports Hybrid Workers, not cloud jobs; all application PaaS remain private.
// https://learn.microsoft.com/azure/automation/how-to/private-link-security
resource account 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: 'aa-${prefix}-bootstrap'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
    disableLocalAuth: true
    encryption: { keySource: 'Microsoft.Automation' }
  }
}
resource runner 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${prefix}-bootstrap'
  location: location
  tags: tags
}
resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: runner
  name: 'krc-bootstrap'
  properties: {
    issuer: config.primary.aks.oidcIssuer
    subject: 'system:serviceaccount:drtest:workshop-bootstrap'
    audiences: ['api://AzureADTokenExchange']
  }
}
// No credentials in runbook parameters, deployment outputs, published artifacts
// or runCommand strings. ARM secure parameters become encrypted Automation assets.
resource settings 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = {
  parent: account
  name: 'workshop-settings'
  properties: {
    isEncrypted: true
    value: string({
      config: config
      pgUser: administratorLogin
      pgPassword: administratorPassword
      clientId: runner.properties.clientId
      imageUri: imageUri
      imageSha256: imageSha256
    })
  }
}
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: account
  name: 'workshop-bootstrap'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell'
    logVerbose: false
    logProgress: false
    description: 'Launch private AKS image transfer; verify both apps, IPs and Traffic Manager. Sample replication continues in AKS.'
    publishContentLink: {
      uri: runbookUri
      contentHash: { algorithm: 'SHA256', value: runbookSha256 }
    }
  }
  dependsOn: [settings, federation]
}
output accountName string = account.name
output automationPrincipalId string = account.identity.principalId
output runnerPrincipalId string = runner.properties.principalId
