#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,11}$')][string]$Prefix,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string[]]$AllowedClientCidrs,
    [string]$AdministratorLogin = 'dradmin',
    [Security.SecureString]$AdministratorPassword,
    [string]$Expiry = (Get-Date).AddDays(30).ToString('yyyy-MM-dd'),
    [string]$InfrastructureConfigPath,
    [switch]$SkipSampleData,
    [switch]$ConfirmCreate
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$state = Join-Path $root ".state\deployments\$Prefix"
$null = New-Item -ItemType Directory -Force -Path $state

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE)." }
}
function Save-DeploymentStatus {
    param([string]$Phase)
    @{
        phase = $Phase; prefix = $Prefix; utc = [DateTime]::UtcNow.ToString('o')
        releaseTag = $manifest.releaseTag; imageSha256 = $manifest.imageSha256
        configuration = $configPath; publicReleasePublished = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $state 'deployment-status.json') -Encoding utf8NoBOM
}
function Protect-Directory {
    param([string]$Path)
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } else {
        Invoke-Checked chmod @('700', $Path)
    }
}

$manifest = Get-Content -Raw -LiteralPath (Join-Path $release 'release-manifest.json') | ConvertFrom-Json
if ($manifest.blocked -eq $true) {
    throw 'This release is blocked by live validation. Use the corrected, verified package.'
}
foreach ($asset in @(
        @{ name = 'azuredeploy.json'; hash = $manifest.templateSha256 },
        @{ name = 'app-image.tar.gz'; hash = $manifest.imageSha256 },
        @{ name = 'deployment-tools.zip'; hash = $manifest.toolsSha256 })) {
    if ($asset.hash -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath (Join-Path $release $asset.name) -Algorithm SHA256).Hash -ine $asset.hash) {
        throw "Release asset integrity check failed: $($asset.name)"
    }
}
if ($manifest.uploadMaxBytes -ne 10000000000 -or -not $manifest.imageTag) {
    throw 'This package does not declare the supported 10 GB upload contract or image tag.'
}
$cidrs = @($AllowedClientCidrs | ForEach-Object { $_ -split ',' })
foreach ($cidr in $cidrs) {
    if ($cidr -notmatch '^\d{1,3}(\.\d{1,3}){3}/(2[4-9]|3[0-2])$') {
        throw 'Use explicit approved IPv4 client CIDRs (/24 through /32); public-wide access is not allowed.'
    }
    $address = [Net.IPAddress]::Parse(($cidr -split '/')[0])
    if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'IPv4 CIDRs are required.' }
}
if (-not $AdministratorPassword) {
    if (-not $env:PG_ADMIN_PASSWORD) { throw 'Supply AdministratorPassword as SecureString or set PG_ADMIN_PASSWORD privately.' }
    $AdministratorPassword = ConvertTo-SecureString $env:PG_ADMIN_PASSWORD -AsPlainText -Force
}
$password = [Net.NetworkCredential]::new('', $AdministratorPassword).Password
$null = Get-Command az, kubectl -ErrorAction Stop
$bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git\bin\bash.exe' } else { (Get-Command bash -ErrorAction Stop).Source }
if (-not (Test-Path -LiteralPath $bash)) { throw 'Git Bash is required on Windows.' }
Invoke-Checked az @('account', 'set', '--subscription', $SubscriptionId)
$configPath = Join-Path $state 'config.json'
$private = Join-Path $state ('private-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $private
Protect-Directory $private
$parameterFile = Join-Path $private 'parameters.json'
$engineState = Join-Path $private 'docker'
$engineStarted = $false
$variables = @('STATE_DIR', 'CONFIG_FILE', 'SUBSCRIPTION_ID', 'PG_USER', 'PG_PASSWORD', 'APP_IMAGE',
    'DOCKER_HOST', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH', 'PATH')
$previous = @{}
foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location $root
try {
    Save-DeploymentStatus 'Validating'
    if ($InfrastructureConfigPath) {
        $config = Get-Content -Raw -LiteralPath $InfrastructureConfigPath | ConvertFrom-Json
        if ($config.prefix -ne $Prefix -or $config.primary.aks.id -notlike "/subscriptions/$SubscriptionId/*") {
            throw 'Existing infrastructure configuration does not match the selected prefix/subscription.'
        }
        if ($SkipSampleData) { $config.sampleData.skip = $true }
        $config | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
    } else {
        if (-not $ConfirmCreate) { throw 'Specify ConfirmCreate to authorize creation of the distinct new Azure environment.' }
        foreach ($suffix in @('krc', 'krs', 'global')) {
            $exists = Invoke-Checked az @('group', 'exists', '--name', "rg-$Prefix-$suffix", '-o', 'tsv')
            if (($exists | Out-String).Trim() -ne 'false') { throw "Resource group rg-$Prefix-$suffix already exists; fresh deployment requires an unused prefix." }
        }
        $parameters = @{
            prefix = @{ value = $Prefix }; expiry = @{ value = $Expiry }
            administratorLogin = @{ value = $AdministratorLogin }
            administratorPassword = @{ value = $password }
            allowedClientCidrs = @{ value = $cidrs }
            deployWorkshopBootstrap = @{ value = $false }
            skipSampleData = @{ value = [bool]$SkipSampleData }
            sampleDataSizeGB = @{ value = 10 }; largeFileSizeGB = @{ value = 1 }
            smallFileCount = @{ value = 2000 }; smallFileSizeMB = @{ value = 1 }
        }
        @{ parameters = $parameters } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $parameterFile -Encoding utf8NoBOM
        Save-DeploymentStatus 'ProvisioningInfrastructure'
        $output = Invoke-Checked az @('deployment', 'sub', 'create', '--name', "$Prefix-local-package",
            '--location', 'koreacentral', '--template-file', (Join-Path $release 'azuredeploy.json'),
            '--parameters', "@$parameterFile", '--query', 'properties.outputs.config.value', '-o', 'json')
        $config = ($output | Out-String) | ConvertFrom-Json
        if (-not $config.primary.aks.id -or $config.prefix -ne $Prefix) { throw 'Infrastructure deployment returned no valid configuration.' }
        $config | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
        Remove-Item -LiteralPath $parameterFile
    }
    Save-DeploymentStatus 'ImportingImage'
    $engineStarted = $true
    & (Join-Path $PSScriptRoot 'azure-docker-engine.ps1') -Action Start -ConfigPath $configPath -StateDirectory $engineState -ApprovedClientCidr $cidrs[0]
    if ($LASTEXITCODE -ne 0) { throw 'Temporary Azure Docker engine startup failed.' }
    $engine = Get-Content -Raw -LiteralPath (Join-Path $engineState 'engine.json') | ConvertFrom-Json
    $env:DOCKER_HOST = $engine.dockerHost
    $env:DOCKER_TLS_VERIFY = '1'
    $env:DOCKER_CERT_PATH = $engine.certificatePath
    $docker = $engine.dockerPath
    Invoke-Checked $docker @('load', '--input', (Join-Path $release 'app-image.tar.gz'))
    $architecture = (Invoke-Checked $docker @('image', 'inspect', $manifest.imageTag, '--format', '{{.Os}}/{{.Architecture}}') | Out-String).Trim()
    if ($architecture -ne 'linux/amd64') { throw "Unsupported loaded image architecture: $architecture" }
    $image = "$($config.primary.acr.loginServer)/drtest-app:release-$($manifest.imageSha256)"
    Invoke-Checked $docker @('tag', $manifest.imageTag, $image)
    & (Join-Path $PSScriptRoot 'azure-docker-engine.ps1') -Action Push -ConfigPath $configPath -StateDirectory $engineState -Image $image
    if ($LASTEXITCODE -ne 0) { throw 'Private ACR image push failed.' }
    & (Join-Path $PSScriptRoot 'azure-docker-engine.ps1') -Action Stop -ConfigPath $configPath -StateDirectory $engineState
    if ($LASTEXITCODE -ne 0) { throw 'Temporary Azure Docker engine cleanup failed.' }
    $engineStarted = $false
    $env:STATE_DIR = $state.Replace('\', '/')
    $env:CONFIG_FILE = $configPath.Replace('\', '/')
    $env:SUBSCRIPTION_ID = $SubscriptionId
    $env:PG_USER = $AdministratorLogin
    $env:PG_PASSWORD = $password
    $env:APP_IMAGE = $image
    Save-DeploymentStatus 'ApplyingAndVerifyingApps'
    Invoke-Checked $bash @((Join-Path $PSScriptRoot 'apply-packaged-app.sh'))
    Save-DeploymentStatus 'Complete'
    Write-Host "Automatic application deployment verified: http://$($config.trafficManager.fqdn)/"
} catch {
    Save-DeploymentStatus 'Failed'
    throw
} finally {
    $password = $null
    try {
        if ($engineStarted) {
            & (Join-Path $PSScriptRoot 'azure-docker-engine.ps1') -Action Stop -ConfigPath $configPath -StateDirectory $engineState
            if ($LASTEXITCODE -ne 0) { throw 'Temporary Azure Docker engine cleanup failed; deployment is not complete.' }
            $engineStarted = $false
        }
    } finally {
        if (Test-Path -LiteralPath $parameterFile) { Remove-Item -LiteralPath $parameterFile }
        if ($engineStarted) {
            Write-Warning "Cleanup did not finish. Protected engine recovery state is retained at $engineState."
        } elseif (Test-Path -LiteralPath $private) {
            # Only the explicitly created, per-run private directory is removed.
            Remove-Item -LiteralPath $private -Recurse
        }
        foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
        Pop-Location
    }
}
