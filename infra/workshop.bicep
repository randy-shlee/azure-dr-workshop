targetScope = 'subscription'

@minLength(3)
@maxLength(12)
param prefix string = 'kkbdrtest'
@description('ISO date for lifecycle tagging; not an automatic deletion schedule.')
param expiry string
@minLength(1)
param allowedClientCidrs array

param deployEventHubs bool = true
param deployRedis bool = true
param deployAiSearch bool = true
param enableAcrGeoReplication bool = false
param deployAppGateway bool = false
param deployDnsResolver bool = false
param enableEventHubsGeoReplication bool = true
@minValue(300)
@maxValue(86400)
param maxReplicationLagSeconds int = 300
param fastFailover bool = false
param aksVmSize string = 'Standard_D4s_v5'
@minValue(2)
param aksNodeCount int = 2
param useEphemeralOsDisk bool = false
param kubernetesVersion string = ''
@allowed(['Standard_D2ds_v5', 'Standard_D2ds_v4'])
param postgresVmSize string = 'Standard_D2ds_v5'
@secure()
param administratorLogin string
@secure()
@minLength(12)
param administratorPassword string
@minValue(1)
param sampleDataSizeGB int = 10
@minValue(1)
param largeFileSizeGB int = 1
@minValue(0)
param smallFileCount int = 2000
@minValue(1)
param smallFileSizeMB int = 1
param skipSampleData bool = false
param sampleDataImage string = 'mcr.microsoft.com/azure-cli:2.85.0'
param deployWorkshopBootstrap bool = true
param bootstrapRunbookUri string = ''
param bootstrapRunbookSha256 string = ''
param appImageArchiveUri string = ''
param appImageArchiveSha256 string = ''
param bootstrapRunId string = utcNow()

module infrastructure 'main.bicep' = {
  name: '${prefix}-infrastructure'
  params: {
    prefix: prefix
    owner: ''
    expiry: expiry
    deployBudget: false
    // Email alerts require an owner address and remain available through the CLI profile.
    deployAlerts: false
    enableStorageLastSyncCustomMetricAlert: false
    allowedClientCidrs: allowedClientCidrs
    deployEventHubs: deployEventHubs
    deployRedis: deployRedis
    deployAiSearch: deployAiSearch
    enableAcrGeoReplication: enableAcrGeoReplication
    deployAppGateway: deployAppGateway
    deployDnsResolver: deployDnsResolver
    enableEventHubsGeoReplication: enableEventHubsGeoReplication
    maxReplicationLagSeconds: maxReplicationLagSeconds
    fastFailover: fastFailover
    aksVmSize: aksVmSize
    aksNodeCount: aksNodeCount
    useEphemeralOsDisk: useEphemeralOsDisk
    kubernetesVersion: kubernetesVersion
    postgresVmSize: postgresVmSize
    administratorLogin: administratorLogin
    administratorPassword: administratorPassword
    sampleDataSizeGB: sampleDataSizeGB
    largeFileSizeGB: largeFileSizeGB
    smallFileCount: smallFileCount
    smallFileSizeMB: smallFileSizeMB
    skipSampleData: skipSampleData
    sampleDataImage: sampleDataImage
    deployWorkshopBootstrap: deployWorkshopBootstrap
    bootstrapRunbookUri: bootstrapRunbookUri
    bootstrapRunbookSha256: bootstrapRunbookSha256
    appImageArchiveUri: appImageArchiveUri
    appImageArchiveSha256: appImageArchiveSha256
    bootstrapRunId: bootstrapRunId
  }
}

output config object = infrastructure.outputs.config
