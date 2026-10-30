#requires -Version 7.2
param([Parameter(Mandatory)][string]$TemplatePath, [string]$SourceReleasePath)
$ErrorActionPreference = 'Stop'
$template = Get-Content -Raw -LiteralPath $TemplatePath | ConvertFrom-Json -AsHashtable
function Assert-Portal([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
Assert-Portal ($template.'$schema' -like '*subscriptionDeploymentTemplate*') 'Subscription deployment is required.'
foreach ($name in @('deployWorkshopBootstrap', 'deployEventHubs', 'deployRedis', 'deployAiSearch', 'enableEventHubsGeoRecovery')) {
    Assert-Portal ($template.parameters[$name].defaultValue -eq $true -and
        $template.parameters[$name].allowedValues.Count -eq 1 -and $template.parameters[$name].allowedValues[0] -eq $true) "Automatic full deployment is not fixed: $name"
}
Assert-Portal ($template.parameters.skipSampleData.allowedValues[0] -eq $false) 'Sample stage cannot silently be skipped.'
Assert-Portal ($template.parameters.sampleDataSizeGB.allowedValues[0] -eq 10) 'Exact sample size must be pinned.'
Assert-Portal ($template.parameters.administratorPassword.type -eq 'secureString') 'Password must be a secure parameter.'
$folder = Split-Path $TemplatePath -Parent
$formPath = Join-Path $folder 'uiFormDefinition.json'
$hasForm = Test-Path -LiteralPath $formPath
$requiredInputs = @('prefix', 'allowedClientCidrs', 'administratorPassword')
if ($hasForm) {
    Assert-Portal ($template.parameters.administratorLogin.type -eq 'string') 'Admin ID must be visible, not secureString.'
    Assert-Portal ($template.parameters.administratorLogin.defaultValue -ceq "[format('pgadmin{0}', utcNow('MMdd'))]") 'Admin ID must default to pgadmin plus UTC MMdd.'
    Assert-Portal ($template.parameters.administratorLogin.minLength -eq 1 -and
        $template.parameters.administratorLogin.maxLength -eq 63) 'Admin ID length must be 1-63.'
    Assert-Portal ($template.parameters.administratorPassword.minLength -eq 12 -and
        $template.parameters.administratorPassword.maxLength -eq 128) 'Password length must be 12-128.'
    & node (Join-Path $PSScriptRoot 'test-portal-form.cjs') $formPath
    Assert-Portal ($LASTEXITCODE -eq 0) 'Portal form credential checks failed.'
    $form = Get-Content -Raw -LiteralPath $formPath | ConvertFrom-Json -AsHashtable
    foreach ($name in $form.view.outputs.parameters.Keys) {
        Assert-Portal ($template.parameters.ContainsKey($name)) "Unknown form parameter: $name"
    }
    foreach ($name in $template.parameters.Keys) {
        Assert-Portal ($template.parameters[$name].ContainsKey('defaultValue') -or
            $form.view.outputs.parameters.ContainsKey($name)) "Required parameter missing from form: $name"
    }
} else {
    $requiredInputs += 'administratorLogin'
}
foreach ($name in $requiredInputs) {
    Assert-Portal (-not $template.parameters[$name].ContainsKey('defaultValue')) "Operator input must not be inferred: $name"
}
$module = @($template.resources | Where-Object { $_.properties.template.parameters.ContainsKey('deployAlerts') })
Assert-Portal ($module.Count -eq 1) 'Exactly one existing infrastructure deployment is required.'
$core = $module[0].properties.template
Assert-Portal ($module[0].properties.parameters.deployWorkshopBootstrap.value -eq "[parameters('deployWorkshopBootstrap')]") 'Bootstrap must be forwarded.'
$start = @($core.resources | Where-Object name -eq 'workshop-start')
Assert-Portal ($start.Count -eq 1 -and $start[0].dependsOn.Count -ge 3) 'Bootstrap must start after regional/global RBAC.'
$bootstrap = @($core.resources | Where-Object name -eq 'workshop-bootstrap')[0].properties.template
$settings = @($bootstrap.resources | Where-Object type -eq 'Microsoft.Automation/automationAccounts/variables')
Assert-Portal ($settings.Count -eq 1 -and $settings[0].properties.isEncrypted) 'Automation inputs must be encrypted.'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $folder 'portal-manifest.json') | ConvertFrom-Json
Assert-Portal ((Get-FileHash $TemplatePath -Algorithm SHA256).Hash -ieq $manifest.templateSha256) 'Template bytes must match manifest.'
$expectedRunbookUri = "https://raw.githubusercontent.com/$($manifest.repository)/$($manifest.releaseTag)/Portal_DeployToAzure_lab/releases/$($manifest.releaseTag)/workshop-bootstrap.ps1"
Assert-Portal ($manifest.runbookUri -ceq $expectedRunbookUri) 'Automation requires the immutable raw runbook URL, not a redirected Release asset.'
$publishedRunbookPath = Join-Path $folder 'workshop-bootstrap.ps1'
Assert-Portal (Test-Path -LiteralPath $publishedRunbookPath) 'The tag-pinned raw runbook must be included in the release folder.'
$attributes = (Get-Content -Raw -LiteralPath (Join-Path $folder '.gitattributes')) -split '\r?\n'
Assert-Portal ($attributes -ccontains 'workshop-bootstrap.ps1 -text') 'Git must preserve packaged runbook bytes without newline conversion.'
if ($hasForm) {
    Assert-Portal ($attributes -ccontains 'uiFormDefinition.json -text') 'Git must preserve pinned form bytes without newline conversion.'
}
Assert-Portal ((Get-FileHash $publishedRunbookPath -Algorithm SHA256).Hash -ieq $manifest.runbookSha256) 'Raw runbook bytes must match the pinned asset SHA256.'
foreach ($pair in @(@('appImageArchiveUri', 'imageUri'), @('appImageArchiveSha256', 'imageSha256'),
        @('bootstrapRunbookUri', 'runbookUri'), @('bootstrapRunbookSha256', 'runbookSha256'))) {
    Assert-Portal ($template.parameters[$pair[0]].defaultValue -ceq $manifest.($pair[1])) 'Asset pin differs from manifest.'
}
$button = Get-Content -Raw -LiteralPath (Join-Path $folder 'README.md')
if ($hasForm) {
    $expectedFormUri = "https://raw.githubusercontent.com/$($manifest.repository)/$($manifest.releaseTag)/Portal_DeployToAzure_lab/releases/$($manifest.releaseTag)/uiFormDefinition.json"
    Assert-Portal ($manifest.uiFormDefinitionUri -ceq $expectedFormUri) 'Form must use the same immutable tag as the template.'
    Assert-Portal ((Get-FileHash $formPath -Algorithm SHA256).Hash -ieq $manifest.uiFormDefinitionSha256) 'Form bytes must match manifest.'
    Assert-Portal ($button.Contains('/uiFormDefinitionUri/' + [Uri]::EscapeDataString($expectedFormUri))) 'Button must load the validated form.'
    Assert-Portal ($button.Contains('#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/')) 'Custom deployment form blade is required.'
}
Assert-Portal ($button.Contains([Uri]::EscapeDataString($manifest.templateUri))) 'Button must encode the exact raw tag URL.'
Assert-Portal ($manifest.templateUri -like "https://raw.githubusercontent.com/*/$($manifest.releaseTag)/Portal_DeployToAzure_lab/releases/$($manifest.releaseTag)/azuredeploy.json") 'Button must reference the new folder on an immutable tag.'
if ($SourceReleasePath) {
    if ($manifest.imageSha256 -ieq '5520be362e606eb87bbdf4c60d2b5fcc2a8bf89c4415135e45ca6c4472e4c1de') {
        Assert-Portal ($manifest.publicationStatus -eq 'BlockedSecurityRefresh') 'Old image must be blocked from publication.'
        $rejected = $false
        try {
            & (Join-Path $PSScriptRoot '../scripts/prepare-portal.ps1') -Repository $manifest.repository `
                -ReleaseTag $manifest.releaseTag -SourceReleasePath $SourceReleasePath
        } catch {
            Assert-Portal ($_.Exception.Message -like 'Security refresh required:*') 'Expected the security gate before any preparation.'
            $rejected = $true
        }
        Assert-Portal $rejected 'Old image was accepted by the preparation tool.'
        Write-Output 'Security gate passed: known old image cannot be prepared for publication.'
    }
    $runbookPath = Join-Path $SourceReleasePath 'workshop-bootstrap.ps1'
    if ($manifest.bootstrapSource -eq 'CurrentRepository') {
        $pattern = '(?m)^\$script:WorkshopBundle\s*=\s*''[A-Za-z0-9+/=]+'''
        $sourceRunbook = [IO.File]::ReadAllText($runbookPath)
        $preparedRunbook = [IO.File]::ReadAllText($publishedRunbookPath)
        Assert-Portal ([regex]::Replace($sourceRunbook, $pattern, '<bundle>') -ceq
            [regex]::Replace($preparedRunbook, $pattern, '<bundle>')) 'Only the embedded source bundle may change; runbook logic and tool pins must remain unchanged.'
        $runbookPath = $publishedRunbookPath
    }
    Assert-Portal ((Get-FileHash $runbookPath -Algorithm SHA256).Hash -ieq $manifest.runbookSha256) 'Packaged runbook bytes changed.'
    Assert-Portal ((Get-FileHash (Join-Path $SourceReleasePath 'app-image.tar.gz') -Algorithm SHA256).Hash -ieq $manifest.imageSha256) 'Image archive bytes changed.'
    $runbook = [IO.File]::ReadAllText($runbookPath)
    $match = [regex]::Match($runbook, '(?m)^\$script:WorkshopBundle\s*=\s*''([A-Za-z0-9+/=]+)''')
    Assert-Portal $match.Success 'Packaged source bundle is missing.'
    $stream = [IO.MemoryStream]::new([Convert]::FromBase64String($match.Groups[1].Value))
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
    try {
        $reader = [IO.StreamReader]::new($archive.GetEntry('scripts/workshop-bootstrap-runner.sh').Open())
        try { $runner = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $previous = -1
        $stages = if ($manifest.bootstrapSource -eq 'CurrentRepository') {
            @('crane push', 'prepare_region primary &', 'prepare_region secondary &', 'prepare_samples &',
                'wait "$primary_pid"', 'wait "$secondary_pid"', 'publish_status ApplicationReady',
                'wait "$sample_pid"', 'publish_status Complete')
        } else {
            @('crane push', 'scripts/search-index.sh', 'scripts/app-apply.sh',
                'publish_status ApplicationReady', 'scripts/upload-sampledata.sh', 'publish_status Complete')
        }
        foreach ($stage in $stages) {
            $position = $runner.IndexOf($stage, [StringComparison]::Ordinal)
            Assert-Portal ($position -gt $previous) "Packaged application stage missing or out of order: $stage"
            $previous = $position
        }
        foreach ($entry in @('scripts/app-apply.sh', 'scripts/upload-sampledata.sh', 'scripts/gen-app-config.sh',
                'k8s/base/deployment.yaml', 'k8s/base/service.yaml', 'k8s/jobs/sampledata-upload.yaml')) {
            Assert-Portal ($null -ne $archive.GetEntry($entry)) "Packaged dependency missing: $entry"
        }
        if ($manifest.bootstrapSource -eq 'CurrentRepository') {
            $files = @('scripts/common.sh', 'scripts/gen-app-config.sh', 'scripts/app-apply.sh',
                'scripts/search-index.sh', 'scripts/upload-sampledata.sh', 'scripts/sampledata-program.sh',
                'scripts/workshop-bootstrap-runner.sh', 'app/sample_layout.py', 'k8s/jobs/sampledata-upload.yaml',
                'k8s/base/deployment.yaml', 'k8s/base/namespace.yaml', 'k8s/base/serviceaccount.yaml',
                'k8s/base/service.yaml', 'k8s/base/kustomization.yaml')
            Assert-Portal ($archive.Entries.Count -eq $files.Count) 'Unexpected bootstrap bundle contents.'
            foreach ($file in $files) {
                $entry = $archive.GetEntry($file)
                Assert-Portal ($null -ne $entry) "Canonical bootstrap source missing: $file"
                $reader = [IO.StreamReader]::new($entry.Open())
                try { $actual = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $expected = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "../../$file")).Replace("`r`n", "`n")
                Assert-Portal ($actual -ceq $expected) "Bootstrap bundle does not match current source: $file"
            }
        }
    } finally { $archive.Dispose(); $stream.Dispose() }
    Write-Output 'Packaged asset checks passed: pinned SHA256, embedded application dependencies and automatic phase ordering.'
}
Write-Output 'Portal contract checks passed: full bootstrap, protected inputs, RBAC order, fixed assets and tag-pinned button.'