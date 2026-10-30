#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?$')][string]$ReleaseTag,
    [Parameter(Mandatory)][string]$SourceReleasePath
)
$ErrorActionPreference = 'Stop'
$lab = Split-Path $PSScriptRoot -Parent
$root = Split-Path $lab -Parent
$source = (Resolve-Path -LiteralPath $SourceReleasePath).Path
$manifest = Get-Content -Raw -LiteralPath (Join-Path $source 'release-manifest.json') | ConvertFrom-Json
if ($manifest.imageSha256 -ieq '5520be362e606eb87bbdf4c60d2b5fcc2a8bf89c4415135e45ca6c4472e4c1de') {
    throw 'Security refresh required: rebuild the v1.0.7 image with current source and dependencies; use a new release.'
}
if ($manifest.releaseTag -in @('v1.0.6', 'v1.0.6-rc.1') -or
    $manifest.architecture -ne 'linux/amd64' -or $manifest.uploadMaxBytes -ne 10000000000) {
    throw 'Use an approved linux/amd64 release with the exact decimal 10 GB sample contract.'
}
if ($ReleaseTag -eq $manifest.releaseTag) { throw 'Use a new portal tag; do not overwrite the source release.' }
foreach ($asset in @(
    @{ name = 'app-image.tar.gz'; hash = $manifest.imageSha256 },
    @{ name = 'workshop-bootstrap.ps1'; hash = $manifest.runbookSha256 }
)) {
    if ($asset.hash -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath (Join-Path $source $asset.name) -Algorithm SHA256).Hash -ine $asset.hash) {
        throw "Release asset hash mismatch: $($asset.name)"
    }
}
$runbook = [IO.File]::ReadAllText((Join-Path $source 'workshop-bootstrap.ps1'))
if ($runbook.Contains('# __WORKSHOP_RELEASE_CONSTANTS__') -or $runbook -notmatch '\$script:WorkshopBundle\s*=') {
    throw 'The runbook must be packaged, with its source bundle and pinned tool checksums embedded.'
}
$destination = Join-Path $lab "releases/$ReleaseTag"
if (Test-Path -LiteralPath $destination) { throw 'Destination exists. Use a new portal tag; never overwrite a release.' }
$null = Get-Command bicep -ErrorAction Stop
$null = New-Item -ItemType Directory -Path $destination
[IO.File]::WriteAllText((Join-Path $destination '.gitattributes'), "workshop-bootstrap.ps1 -text`nuiFormDefinition.json -text`n", [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $source 'workshop-bootstrap.ps1') -Destination (Join-Path $destination 'workshop-bootstrap.ps1')
$templatePath = Join-Path $destination 'azuredeploy.json'
& bicep build (Join-Path $root 'infra/workshop.bicep') --no-restore --outfile $templatePath
if ($LASTEXITCODE -ne 0) { throw 'Portal entry point compilation failed.' }
$template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json -AsHashtable
$assetUri = "https://github.com/$Repository/releases/download/$ReleaseTag"
$rawReleaseUri = "https://raw.githubusercontent.com/$Repository/$ReleaseTag/Portal_DeployToAzure_lab/releases/$ReleaseTag"
$fixed = [ordered]@{
    deployWorkshopBootstrap = $true
    bootstrapRunbookUri = "$rawReleaseUri/workshop-bootstrap.ps1"
    bootstrapRunbookSha256 = $manifest.runbookSha256.ToLowerInvariant()
    appImageArchiveUri = "$assetUri/app-image.tar.gz"
    appImageArchiveSha256 = $manifest.imageSha256.ToLowerInvariant()
    deployEventHubs = $true; deployRedis = $true; deployAiSearch = $true
    enableEventHubsGeoRecovery = $true; skipSampleData = $false; enableSampleUpload = $true
    sampleDataSizeGB = 10; largeFileSizeGB = 1; smallFileCount = 2000; smallFileSizeMB = 1
    enableAcrGeoReplication = $false; deployAppGateway = $false; deployDnsResolver = $false; fastFailover = $false
}
foreach ($key in $fixed.Keys) {
    $template.parameters[$key].defaultValue = $fixed[$key]
    $template.parameters[$key].allowedValues = @($fixed[$key])
}
$null = $template.parameters.prefix.Remove('defaultValue')
$null = $template.parameters.allowedClientCidrs.Remove('defaultValue')
$template.parameters.allowedClientCidrs.minLength = 1
$null = $template.parameters.administratorPassword.Remove('defaultValue')
$template.metadata['portalLab'] = @{
    sourceReleaseTag = $manifest.releaseTag
    portalReleaseTag = $ReleaseTag
    applicationReadiness = 'Asynchronous: ARM Succeeded is not application or sample readiness.'
}
[IO.File]::WriteAllText($templatePath, (($template | ConvertTo-Json -Depth 100).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
& (Join-Path $root 'infra/tests/validate-template.ps1') -TemplatePath $templatePath
if (-not $?) { throw 'Shared template invariants failed.' }
$templateUri = "https://raw.githubusercontent.com/$Repository/$ReleaseTag/Portal_DeployToAzure_lab/releases/$ReleaseTag/azuredeploy.json"
$formPath = Join-Path $destination 'uiFormDefinition.json'
Copy-Item -LiteralPath (Join-Path $lab 'uiFormDefinition.json') -Destination $formPath
$formUri = "$rawReleaseUri/uiFormDefinition.json"
$button = "[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/$([Uri]::EscapeDataString($templateUri))/uiFormDefinitionUri/$([Uri]::EscapeDataString($formUri)))"
[IO.File]::WriteAllText((Join-Path $destination 'README.md'), @"
# Portal Deployment: $ReleaseTag

Not published or cloud-validated. Publish the exact tag-pinned template and both
hash-verified Release assets before using this button. ARM success only starts
the asynchronous app bootstrap; verify app and sample completion separately.

$button

Source assets: $($manifest.releaseTag). See ../../README.md for the lab and publication gates.

## Credential form

- Admin ID is visible and defaults to pgadmin + the current UTC MMdd (for example pgadmin1030).
- Password remains hidden, requires confirmation, and has no default.
- Password rules are shown above the input: 12-128 characters; at least 3 of uppercase,
  lowercase, digits and symbols; no admin ID within the password (case-insensitive).
- ID length, letters/digits and reserved names are checked before submission.
- Approved public CIDRs are comma separated without spaces or JSON brackets.
- These input checks do not prove Azure policy, quota, permissions or deployment success.

Before promoting the lab button, publish and verify both immutable JSON URLs and the
unchanged image/runbook assets. Preview the form in Azure Portal using synthetic values
only, including blank inputs, reserved IDs, weak passwords and mismatched confirmation.
Do not submit a deployment just to check the form. Never automate a filled secret form.
"@.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
@{
    repository = $Repository; releaseTag = $ReleaseTag; sourceReleaseTag = $manifest.releaseTag
    templateUri = $templateUri; templateSha256 = (Get-FileHash $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    uiFormDefinitionUri = $formUri; uiFormDefinitionSha256 = (Get-FileHash $formPath -Algorithm SHA256).Hash.ToLowerInvariant()
    imageUri = $fixed.appImageArchiveUri; imageSha256 = $fixed.appImageArchiveSha256
    runbookUri = $fixed.bootstrapRunbookUri; runbookSha256 = $fixed.bootstrapRunbookSha256
    publicationStatus = 'LocalOnly'; cloudValidation = 'NotRun'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'portal-manifest.json') -Encoding utf8NoBOM
Write-Output "Prepared locally: $destination"
Write-Output "Publish the source app-image.tar.gz and workshop-bootstrap.ps1 unchanged as $ReleaseTag Release assets."
Write-Output 'No Git publication, Azure login, resource deployment, image build or original file modification was performed.'