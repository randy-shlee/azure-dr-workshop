param accountName string
param jobId string

resource account 'Microsoft.Automation/automationAccounts@2024-10-23' existing = { name: accountName }
// The job is asynchronous: deployment success is NOT application readiness.
// https://learn.microsoft.com/azure/templates/microsoft.automation/automationaccounts/jobs
resource job 'Microsoft.Automation/automationAccounts/jobs@2024-10-23' = {
  parent: account
  name: jobId
  properties: { runbook: { name: 'workshop-bootstrap' } }
}
output jobId string = job.name
