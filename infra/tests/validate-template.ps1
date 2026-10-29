param(
    [Parameter(Mandatory = $true)]
    [string] $TemplatePath
)
$ErrorActionPreference = 'Stop'
$template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -AsHashtable
$script:resources = @()
function Visit-Template($node) {
    foreach ($resource in $node.resources) {
        $script:resources += $resource
        if ($resource.properties.template) {
            Visit-Template $resource.properties.template
        }
    }
}
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
if (-not $template.parameters.ContainsKey('deployAlerts')) {
    Assert-True ($template.parameters.sampleDataSizeGB.defaultValue -eq 10 -and
        $template.parameters.sampleDataSizeGB.maxValue -eq 10) 'Packaged entry point must enforce the 10 GB sample budget.'
    $core = @($template.resources | Where-Object {
        $_.type -eq 'Microsoft.Resources/deployments' -and
        $_.properties.template.parameters.ContainsKey('deployAlerts')
    })
    Assert-True ($core.Count -eq 1) 'Expected exactly one shared infrastructure module in the workshop wrapper.'
    $template = $core[0].properties.template
}
Visit-Template $template
Assert-True ($template.'$schema' -like '*subscriptionDeploymentTemplate*') 'Entry point must be subscription scoped.'
foreach ($flag in @('deployEventHubs', 'deployRedis', 'deployAiSearch')) {
    Assert-True ($template.parameters[$flag].defaultValue -eq $true) "$flag must default true."
}
foreach ($flag in @('enableAcrGeoReplication', 'deployAppGateway', 'deployDnsResolver', 'deployAlerts', 'fastFailover', 'enableStorageLastSyncCustomMetricAlert')) {
    Assert-True ($template.parameters[$flag].defaultValue -eq $false) "$flag must default false."
}
Assert-True ($template.parameters.administratorPassword.type -eq 'secureString') 'PostgreSQL password must be secure.'
Assert-True ($template.parameters.aksNodeCount.defaultValue -eq 2) 'Approved AKS minimum is two nodes.'
Assert-True ($template.parameters.aksVmSize.defaultValue -eq 'Standard_D4s_v5') 'Approved default VM changed unexpectedly.'
Assert-True ($template.parameters.sampleDataSizeGB.defaultValue -eq 10 -and $template.parameters.sampleDataSizeGB.maxValue -eq 10) 'Sample size must default to 10 and cannot exceed its budget.'
Assert-True ($template.parameters.skipSampleData.defaultValue -eq $false) 'Upload must not silently default off.'
Assert-True ($template.parameters.enableEventHubsGeoRecovery.defaultValue -eq $true) 'Standard metadata Geo-DR must default on.'
Assert-True (-not $template.parameters.ContainsKey('enableEventHubsGeoReplication') -and -not $template.parameters.ContainsKey('maxReplicationLagSeconds')) 'Premium data replication controls must be removed.'
Assert-True ($template.parameters.replicationLagAlertSeconds.defaultValue -eq 300) 'PG/Storage alert lag threshold must default to 300 seconds.'
Assert-True ($template.outputs.config.type -eq 'object') 'Scripts require the config object output.'
$eventNamespaces = @($script:resources | Where-Object type -eq 'Microsoft.EventHub/namespaces')
$eventAliases = @($script:resources | Where-Object type -eq 'Microsoft.EventHub/namespaces/disasterRecoveryConfigs')
Assert-True ($eventNamespaces.Count -eq 2) 'Standard Geo-DR requires two independent namespace declarations.'
Assert-True ($eventAliases.Count -eq 1) 'Standard Geo-DR requires one metadata alias.'
$sampleFederation = @($script:resources | Where-Object {
    $_.type -eq 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials' -and
    $_.name -match 'aks-sampledata-krs'
})
Assert-True ($sampleFederation.Count -eq 1) 'The shared sample identity must also trust the KRS uploader service account.'
Assert-True ($sampleFederation[0].properties.subject -eq 'system:serviceaccount:drtest:sampledata-upload') 'KRS sample federation must use the exact uploader subject.'
$sampleFederationModule = @($script:resources | Where-Object name -eq 'sampledata-secondary-federation')
Assert-True ($sampleFederationModule.Count -eq 1) 'KRS sample federation requires its cross-resource-group module.'
Assert-True ($sampleFederationModule[0].properties.parameters.issuer.value -match "'aks-krs'") 'Secondary sample federation must use the KRS AKS issuer.'
foreach ($region in @('primary', 'secondary')) {
    $suffix = if ($region -eq 'primary') { 'krc' } else { 'krs' }
    $config = $template.outputs.config.value
    $wired = if ($config -is [string]) {
        $config -match "'Microsoft.Resources/deployments', 'network-$suffix'\), '[^']+'\)\.outputs\.publicIp\.value"
    } else {
        $config[$region].publicIp -match 'outputs.publicIp.value'
    }
    Assert-True $wired "$region public IP output is not wired to the network module."
}
$dashboardReaders = @($script:resources | Where-Object {
    $_.type -eq 'Microsoft.Authorization/roleAssignments' -and
    $_.properties.roleDefinitionId -match 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
})
Assert-True ($dashboardReaders.Count -eq 1) 'Dashboard Reader must be a single loop declaration.'
Assert-True ($dashboardReaders[0].scope -match "resourceId\('Microsoft.Storage/storageAccounts'") 'Last Sync Time Reader must be account scoped.'
Assert-True ($dashboardReaders[0].copy.count -eq "[length(parameters('principalIds'))]") 'Only the regional app identities need ARM Reader.'
$secondaryRecord = @($script:resources | Where-Object name -eq 'storage-secondary-record-in-krc')
Assert-True ($secondaryRecord.Count -eq 1) 'KRC local Storage secondary record is required for private fallback reads.'
Assert-True ($secondaryRecord[0].properties.parameters.recordName.value -match '-secondary') 'Secondary record must use the secondary hostname.'
Assert-True ($secondaryRecord[0].properties.parameters.address.value -match "createArray\('blob', 'blob_secondary'\)\[1\]") 'Secondary record must point to the KRS blob_secondary PE.'

$prohibited = @(
    'Microsoft.Network/frontDoors', 'Microsoft.Cdn/profiles', 'Microsoft.Network/azureFirewalls',
    'Microsoft.Network/bastionHosts', 'Microsoft.Network/virtualNetworkGateways',
    'Microsoft.Network/natGateways', 'Microsoft.Compute/virtualMachines'
)
$privateTypes = @(
    'Microsoft.Storage/storageAccounts', 'Microsoft.ContainerRegistry/registries',
    'Microsoft.EventHub/namespaces', 'Microsoft.DBforPostgreSQL/flexibleServers',
    'Microsoft.Cache/redisEnterprise', 'Microsoft.Search/searchServices'
)
foreach ($resource in $script:resources) {
    Assert-True ($resource.type -notin $prohibited) "Prohibited service: $($resource.type)"
    if ($resource.apiVersion -match 'preview') {
        Assert-True ($resource.type -eq 'Microsoft.Insights/diagnosticSettings') "Unexpected preview API: $($resource.type)"
    }
    if ($resource.type -in $privateTypes) {
        $publicAccess = if ($resource.type -eq 'Microsoft.DBforPostgreSQL/flexibleServers') {
            $resource.properties.network.publicNetworkAccess
        } else { $resource.properties.publicNetworkAccess }
        Assert-True ($publicAccess -eq 'Disabled') "$($resource.type) public access is not disabled."
    }
    if ($resource.type -eq 'Microsoft.ContainerService/managedClusters') {
        Assert-True ($resource.sku.tier -eq 'Free') 'AKS must use Free tier.'
        Assert-True ($resource.properties.apiServerAccessProfile.enablePrivateCluster -eq $true) 'AKS API must be private.'
        Assert-True ($resource.properties.securityProfile.workloadIdentity.enabled -eq $true) 'AKS Workload Identity missing.'
        Assert-True ($resource.properties.networkProfile.networkPluginMode -eq 'overlay') 'AKS must use CNI Overlay.'
        Assert-True ($resource.properties.agentPoolProfiles.Count -eq 1) 'Extra AKS pool costs are prohibited.'
        Assert-True (-not $resource.properties.agentPoolProfiles[0].availabilityZones) 'AKS zones must not be set.'
        Assert-True ($resource.properties.agentPoolProfiles[0].enableAutoScaling -eq $false) 'Autoscaler must be off.'
        Assert-True (-not $resource.properties.agentPoolProfiles[0].upgradeSettings.ContainsKey('maxUnavailable')) 'System pools must not set maxUnavailable.'
        Assert-True ($resource.properties.agentPoolProfiles[0].upgradeSettings.maxSurge -eq '1') 'System pool upgrades require one surge node.'
    }
    if ($resource.type -eq 'Microsoft.Storage/storageAccounts') {
        Assert-True ($resource.sku.name -eq 'Standard_RAGRS') 'Storage must use RA-GRS.'
        Assert-True ($resource.properties.allowSharedKeyAccess -eq $false) 'Storage shared keys must be disabled.'
    }
    if ($resource.type -eq 'Microsoft.DBforPostgreSQL/flexibleServers') {
        Assert-True ($resource.sku.tier -eq 'GeneralPurpose') 'PG replica requires General Purpose.'
        Assert-True ($resource.properties.version -eq '16') 'PG must run version 16.'
        Assert-True ($resource.properties.storage.storageSizeGB -eq 32) 'PG storage must be the requested minimum.'
        Assert-True ($resource.properties.storage.autoGrow -eq 'Disabled') 'PG storage growth must be explicit.'
        Assert-True ($resource.properties.highAvailability.mode -eq 'Disabled') 'PG HA must be off.'
        Assert-True ($resource.properties.backup.geoRedundantBackup -eq 'Disabled') 'PG geo-backup must be off.'
        Assert-True (-not $resource.properties.network.delegatedSubnetResourceId) 'PG must use Private Link, not delegated networking.'
    }
    if ($resource.type -eq 'Microsoft.DBforPostgreSQL/flexibleServers/virtualendpoints') {
        Assert-True ($resource.properties.endpointType -eq 'ReadWrite') 'One ReadWrite resource must create the writer/reader pair.'
        Assert-True ($resource.properties.members[0] -match "'pg-replica'.*outputs.config.value.name") 'PG reader must initially target the replica deployment output.'
    }
    if ($resource.type -eq 'Microsoft.ContainerRegistry/registries') {
        Assert-True ($resource.sku.name -eq 'Premium') 'ACR Private Link requires Premium.'
        Assert-True ($resource.properties.adminUserEnabled -eq $false) 'ACR admin keys must be off.'
    }
    if ($resource.type -eq 'Microsoft.EventHub/namespaces') {
        Assert-True ($resource.sku.name -eq 'Standard' -and $resource.sku.capacity -eq 1) 'EH must use Standard one TU per namespace.'
        Assert-True ($resource.properties.disableLocalAuth -eq $true) 'EH must use Entra authentication.'
        Assert-True (-not $resource.properties.ContainsKey('geoDataReplication')) 'Standard Geo-DR must not configure event-data replication.'
        Assert-True ($resource.properties.kafkaEnabled -eq $false) 'Kafka endpoint charges must not be enabled.'
    }
    if ($resource.type -eq 'Microsoft.EventHub/namespaces/disasterRecoveryConfigs') {
        Assert-True ($resource.properties.partnerNamespace -match 'eh-namespace-krs.*outputs.config.value.id') 'Geo-DR must pair the separate Korea South namespace.'
        Assert-True ($resource.dependsOn.Count -ge 4) 'Both namespaces need private endpoints in both VNets before pairing.'
    }
    if ($resource.type -eq 'Microsoft.Search/searchServices') {
        Assert-True ($resource.sku.name -eq 'basic') 'Search must use Basic.'
        Assert-True ($resource.properties.replicaCount -eq 1 -and $resource.properties.partitionCount -eq 1) 'Search must have one replica/partition.'
        Assert-True ($resource.properties.disableLocalAuth -eq $true) 'Search must use Entra authentication.'
        Assert-True (-not $resource.properties.ContainsKey('authOptions')) 'Search authOptions conflicts with disabled local auth.'
    }
    if ($resource.type -eq 'Microsoft.Cache/redisEnterprise') {
        Assert-True ($resource.sku.name -eq 'Balanced_B3') 'Redis must use minimum geo-enabled B3.'
        Assert-True ($resource.properties.highAvailability -eq 'Enabled') 'Redis active geo requires HA.'
        Assert-True (-not $resource.zones) 'Redis must not request zones.'
    }
    if ($resource.type -eq 'Microsoft.Cache/redisEnterprise/databases') {
        Assert-True ($resource.properties.accessKeysAuthentication -eq 'Enabled') 'Workshop Secret-based Redis login requires access keys to be explicitly enabled.'
        Assert-True ($resource.properties.persistence.aofEnabled -eq $false -and $resource.properties.persistence.rdbEnabled -eq $false) 'Redis persistence must be off.'
        Assert-True ($resource.properties.geoReplication.groupNickname -ne '') 'Redis databases must join an active geo group.'
    }
    if ($resource.type -eq 'Microsoft.Consumption/budgets') {
        Assert-True ($resource.properties.notifications.Actual80.threshold -eq 80) '80% budget alert missing.'
        Assert-True ($resource.properties.notifications.Actual100.threshold -eq 100) '100% budget alert missing.'
        Assert-True ($resource.properties.filter.dimensions.values.Count -eq 5) 'Budget must include AKS managed groups.'
    }
    $endpoints = @($script:resources | Where-Object type -eq 'Microsoft.Network/privateEndpoints')
    $groups = @($script:resources | Where-Object type -eq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups')
    Assert-True ($endpoints.Count -gt 0 -and $groups.Count -ge $endpoints.Count) 'Every PE declaration needs a DNS zone group declaration.'
    if ($resource.type -eq 'Microsoft.Insights/scheduledQueryRules') {
        Assert-True ($resource.properties.overrideQueryTimeRange -eq 'PT2H') 'The oldest complete minute must not be clipped by the query time range.'
        $query = $resource.properties.criteria.allOf[0].query
        Assert-True ($query -notmatch '\$\{') 'Unexpanded Bicep interpolation in KQL.'
        Assert-True ($query -match 'Samples == 60 and MaxHealth == 0') 'Redis must remain unhealthy for 60 complete minutes.'
        Assert-True ($query -match 'isnotnull\(Maximum\)') 'Missing Redis samples must not count as unhealthy.'
        Assert-True ($query -match 'bin\(TimeGenerated, 1m\)') 'Duplicate Redis samples must not substitute for elapsed minutes.'
    }
}
$required = $privateTypes + @('Microsoft.Network/trafficManagerProfiles', 'Microsoft.Consumption/budgets')
foreach ($type in $required) {
    Assert-True (@($script:resources | Where-Object type -eq $type).Count -gt 0) "Missing resource type: $type"
}
Write-Output "PASS: compiled template invariants ($($script:resources.Count) resource declarations)."
