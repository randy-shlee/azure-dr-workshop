#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?$')][string]$ReleaseTag,
    [switch]$UpdateWorkshopButton,
    [string]$AzureBuildConfigPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE)." }
}

function New-SourceBundle {
    param([string]$Root)
    $files = @(
        'scripts/common.sh', 'scripts/gen-app-config.sh', 'scripts/app-apply.sh',
        'scripts/search-index.sh', 'scripts/upload-sampledata.sh', 'scripts/sampledata-program.sh',
        'scripts/workshop-bootstrap-runner.sh', 'app/sample_layout.py',
        'k8s/jobs/sampledata-upload.yaml', 'k8s/base/deployment.yaml',
        'k8s/base/namespace.yaml', 'k8s/base/serviceaccount.yaml', 'k8s/base/service.yaml',
        'k8s/base/kustomization.yaml'
    )
    $memory = [IO.MemoryStream]::new()
    $zip = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($file in $files) {
            $path = Join-Path $Root ($file.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $entry = $zip.CreateEntry($file)
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write([IO.File]::ReadAllText($path).Replace("`r`n", "`n")) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    try {
        if ($memory.Length -gt 400KB) { throw 'Source bundle exceeds the Kubernetes Secret/AKS command attachment safety budget.' }
        return [Convert]::ToBase64String($memory.ToArray())
    } finally { $memory.Dispose() }
}

function Set-PortalDefaults {
    param([System.Collections.IDictionary]$Template, [string]$ReleaseUri, [string]$ImageHash, [string]$RunbookHash)
    $defaults = @{
        deployWorkshopBootstrap = $true; sampleDataSizeGB = 10; smallFileCount = 2000
        bootstrapRunbookUri = "$ReleaseUri/workshop-bootstrap.ps1"; bootstrapRunbookSha256 = $RunbookHash
        appImageArchiveUri = "$ReleaseUri/app-image.tar.gz"; appImageArchiveSha256 = $ImageHash
    }
    foreach ($key in $defaults.Keys) { $Template.parameters[$key].defaultValue = $defaults[$key] }
    $null = $Template.parameters.allowedClientCidrs.Remove('defaultValue')
    $Template.parameters.allowedClientCidrs.minLength = 1
    return $Template
}

function Assert-DockerEndpoint {
    param([string]$Endpoint, [string]$AzureConfig)
    if ($Endpoint -match '^(npipe|unix)://') { return }
    if (-not $AzureConfig -or $env:DOCKER_TLS_VERIFY -ne '1' -or -not $env:DOCKER_CERT_PATH) {
        throw 'Remote Docker requires explicit AzureBuildConfigPath and verified mutual TLS.'
    }
    $config = Get-Content -Raw -LiteralPath $AzureConfig | ConvertFrom-Json
    $address = (Invoke-Native az @('network', 'public-ip', 'show', '--ids', $config.primary.publicIp.id, '--query', 'ipAddress', '-o', 'tsv') | Out-String).Trim()
    if ($Endpoint -cne "tcp://${address}:2376" -or $address -ne $config.primary.publicIp.address) {
        throw 'Remote build endpoint must be the verified public IP of the explicitly selected Azure environment.'
    }
    foreach ($name in @('ca.pem', 'cert.pem', 'key.pem')) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:DOCKER_CERT_PATH $name))) { throw "Missing Docker mutual TLS file: $name" }
    }
}

function New-DeploymentTools {
    param([string]$Root, [string]$Bundle, [string]$Destination)
    $memory = [IO.MemoryStream]::new()
    $bytes = [Convert]::FromBase64String($Bundle)
    $memory.Write($bytes, 0, $bytes.Length)
    $memory.Position = 0
    $zip = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Update, $true)
    try {
        foreach ($file in @('scripts/deploy-local-package.ps1', 'scripts/azure-docker-engine.ps1',
                'scripts/apply-packaged-app.sh', 'scripts/test-app.sh', 'k8s/jobs/docker-engine.yaml')) {
            $entry = $zip.CreateEntry($file)
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write([IO.File]::ReadAllText((Join-Path $Root $file)).Replace("`r`n", "`n")) }
            finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    try { [IO.File]::WriteAllBytes($Destination, $memory.ToArray()) } finally { $memory.Dispose() }
}

$null = Get-Command docker, az -ErrorAction Stop
$endpoint = if ($env:DOCKER_HOST) { $env:DOCKER_HOST } else { (Invoke-Native docker @('context', 'inspect', '--format', '{{.Endpoints.docker.Host}}') | Out-String).Trim() }
Assert-DockerEndpoint $endpoint $AzureBuildConfigPath
if ((Invoke-Native docker @('info', '--format', '{{.OSType}}') | Out-String).Trim() -ne 'linux') { throw 'Docker must be running Linux containers.' }
$stage = Join-Path $root ".state\releases\$ReleaseTag"
if (Test-Path $stage) { throw "Release directory already exists: $stage. Use a new version; do not overwrite a published release." }
$null = New-Item -ItemType Directory -Path $stage
$tag = "drtest-app:$ReleaseTag"
Push-Location (Join-Path $root 'app')
try { Invoke-Native docker @('build', '--pull', '--platform', 'linux/amd64', '--tag', $tag, '.') } finally { Pop-Location }
$architecture = (Invoke-Native docker @('image', 'inspect', $tag, '--format', '{{.Os}}/{{.Architecture}}') | Out-String).Trim()
if ($architecture -ne 'linux/amd64') { throw "Unexpected image architecture: $architecture" }
$tar = Join-Path $stage 'app-image.tar'
Invoke-Native docker @('save', '--output', $tar, $tag)
if ((Get-Item -LiteralPath $tar).Length -gt 4GB) { throw 'Saved image exceeds the bootstrap disk budget (4GiB uncompressed).' }
$inputStream = [IO.File]::OpenRead($tar)
$outputStream = [IO.File]::Create("$tar.gz")
$gzip = [IO.Compression.GZipStream]::new($outputStream, [IO.Compression.CompressionLevel]::Optimal)
try { $inputStream.CopyTo($gzip) } finally { $inputStream.Dispose(); $gzip.Dispose(); $outputStream.Dispose() }
if ((Get-Item -LiteralPath "$tar.gz").Length -ge 2GB) { throw 'Compressed image exceeds the GitHub Release single-asset budget (below 2GiB required).' }
Remove-Item -LiteralPath $tar
$imageHash = (Get-FileHash "$tar.gz" -Algorithm SHA256).Hash.ToLowerInvariant()
$releaseUri = "https://github.com/$Repository/releases/download/$ReleaseTag"
$portalTemplateUri = "https://raw.githubusercontent.com/$Repository/$ReleaseTag/workshop/releases/azuredeploy.json"
$bundle = New-SourceBundle $root
$toolsPath = Join-Path $stage 'deployment-tools.zip'
New-DeploymentTools $root $bundle $toolsPath
$toolsHash = (Get-FileHash $toolsPath -Algorithm SHA256).Hash.ToLowerInvariant()
Copy-Item -LiteralPath (Join-Path $root 'workshop\local-package.md') -Destination (Join-Path $stage 'DEPLOYMENT.md')
$kubectlUri = 'https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl'
Invoke-WebRequest "$kubectlUri.sha256" -OutFile (Join-Path $stage 'kubectl.sha256') -TimeoutSec 60
$kubectlHash = ([IO.File]::ReadAllText((Join-Path $stage 'kubectl.sha256'))).Trim()
if ($kubectlHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid upstream kubectl checksum.' }
# Upstream v0.20.6 checksums.txt, Linux x86_64; binaries are not redistributed.
$craneUri = 'https://github.com/google/go-containerregistry/releases/download/v0.20.6/go-containerregistry_Linux_x86_64.tar.gz'
$craneHash = 'c1d593d01551f2c9a3df5ca0a0be4385a839bd9b86d4a76e18d7b17d16559127'
$constants = @"
`$script:WorkshopBundle = '$bundle'
`$script:CraneUri = '$craneUri'
`$script:CraneSha256 = '$craneHash'
`$script:KubectlUri = '$kubectlUri'
`$script:KubectlSha256 = '$kubectlHash'
"@
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'workshop-bootstrap.ps1')).Replace("`r`n", "`n")
$runbook = Join-Path $stage 'workshop-bootstrap.ps1'
[IO.File]::WriteAllText($runbook, $source.Replace('# __WORKSHOP_RELEASE_CONSTANTS__', $constants), [Text.UTF8Encoding]::new($false))
$runbookHash = (Get-FileHash $runbook -Algorithm SHA256).Hash.ToLowerInvariant()
$templatePath = Join-Path $stage 'azuredeploy.json'
Invoke-Native az @('bicep', 'build', '--file', (Join-Path $root 'infra\workshop.bicep'), '--outfile', $templatePath)
$template = Get-Content -Raw $templatePath | ConvertFrom-Json -AsHashtable
$template = Set-PortalDefaults $template $releaseUri $imageHash $runbookHash
$templateJson = ($template | ConvertTo-Json -Depth 100).Replace("`r`n", "`n") + "`n"
[IO.File]::WriteAllText($templatePath, $templateJson, [Text.UTF8Encoding]::new($false))
$templateHash = (Get-FileHash $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
@{
    repository = $Repository; releaseTag = $ReleaseTag; architecture = $architecture
    templateUri = $portalTemplateUri; templateSha256 = $templateHash
    imageUri = "$releaseUri/app-image.tar.gz"; imageSha256 = $imageHash
    runbookUri = "$releaseUri/workshop-bootstrap.ps1"; runbookSha256 = $runbookHash
    imageTag = $tag; toolsSha256 = $toolsHash
    publicationStatus = 'LocalOnly - not published; use deploy-local-package.ps1 until release assets are published'
    uploadMaxBytes = 10000000000
} | ConvertTo-Json | Set-Content (Join-Path $stage 'release-manifest.json') -Encoding utf8NoBOM
$button = "[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/$([Uri]::EscapeDataString($portalTemplateUri)))"
$button | Set-Content (Join-Path $stage 'deploy-button.md') -Encoding utf8NoBOM
if ($UpdateWorkshopButton) {
    $portalFolder = Join-Path $root 'workshop\releases'
    $null = New-Item -ItemType Directory -Force -Path $portalFolder
    Copy-Item -LiteralPath $templatePath -Destination (Join-Path $portalFolder 'azuredeploy.json')
    $document = Join-Path $root 'workshop\labs\01-infrastructure.md'
    $text = [IO.File]::ReadAllText($document)
    if ($text -notmatch '(?s)<!-- DEPLOY_BUTTON_START -->.*?<!-- DEPLOY_BUTTON_END -->') { throw 'Workshop button markers not found.' }
    $replacement = "<!-- DEPLOY_BUTTON_START -->`n$button`n`nRelease: ``$Repository@$ReleaseTag``. 게시된 공개 assets를 확인한 후 사용합니다.`n<!-- DEPLOY_BUTTON_END -->"
    [IO.File]::WriteAllText($document, [regex]::Replace($text, '(?s)<!-- DEPLOY_BUTTON_START -->.*?<!-- DEPLOY_BUTTON_END -->', [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement }), [Text.UTF8Encoding]::new($false))
}
Write-Host "Prepared: $stage"
Write-Host 'Local deployment: extract deployment-tools.zip and follow DEPLOYMENT.md. No public release is required for this path.'
Write-Host 'NOT PUBLISHED. Portal use requires separately approved publication of same-version assets and the tag-pinned template. No Azure resource deployment was executed by packaging.'
