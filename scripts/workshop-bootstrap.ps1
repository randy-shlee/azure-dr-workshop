$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression

# __WORKSHOP_RELEASE_CONSTANTS__

function Invoke-Arm {
    param([string]$Method, [string]$Uri, [string]$Body)
    if (-not $Uri.StartsWith('https://management.azure.com/')) { throw 'Unexpected ARM endpoint.' }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $token = Invoke-RestMethod -Method Get -Uri "$($env:IDENTITY_ENDPOINT)?resource=https%3A%2F%2Fmanagement.azure.com%2F" `
                -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'true' } -TimeoutSec 30
            $request = @{
                Method = $Method; Uri = $Uri; UseBasicParsing = $true; TimeoutSec = 120
                Headers = @{ Authorization = "Bearer $($token.access_token)" }
            }
            if ($Body) { $request.Body = [Text.Encoding]::UTF8.GetBytes($Body); $request.ContentType = 'application/json' }
            return Invoke-WebRequest @request
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -eq 403 -and $attempt -lt 19) { Start-Sleep -Seconds 15; continue }
            throw "ARM request failed (HTTP $status). Check bootstrap RBAC/networking; request bodies are not logged."
        }
    }
}

function New-CommandContext {
    param([string]$Manifest)
    $memory = [IO.MemoryStream]::new()
    $archive = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        $entry = $archive.CreateEntry('bootstrap.json')
        $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write($Manifest) } finally { $writer.Dispose() }
    } finally { $archive.Dispose() }
    try { return [Convert]::ToBase64String($memory.ToArray()) } finally { $memory.Dispose() }
}

function Invoke-AksCommand {
    param([string]$Command, [string]$Context = '')
    $uri = "https://management.azure.com$script:ClusterId/runCommand?api-version=2026-08-01"
    $body = @{ command = "set -eu; $Command"; context = $Context } | ConvertTo-Json -Compress
    $response = Invoke-Arm Post $uri $body
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    while ($true) {
        if ([int]$response.StatusCode -eq 200) {
            $result = $response.Content | ConvertFrom-Json
            $properties = $result.properties
            if ($properties.provisioningState -eq 'Failed' -or
                ($null -ne $properties.PSObject.Properties['exitCode'] -and $properties.exitCode -ne 0)) {
                throw 'AKS command failed; inspect command results with authorized access. Secret attachments are not logged here.'
            }
            if ($null -ne $properties.PSObject.Properties['exitCode'] -and $properties.provisioningState -eq 'Succeeded') {
                if ($properties.logs -match '(?m)^(Error from server|error:|FATAL:|DR_REMOTE_ERROR)') { throw 'AKS command output contains an error.' }
                return [string]$properties.logs
            }
        }
        $location = [string]$response.Headers['Location']
        if (-not $location -or [DateTime]::UtcNow -ge $deadline) { throw 'AKS command returned no completed result or timed out.' }
        Start-Sleep -Seconds 10
        $response = Invoke-Arm Get $location
    }
}

function New-BootstrapManifest {
    param($Settings)
    $namespace = @{ apiVersion = 'v1'; kind = 'Namespace'; metadata = @{ name = 'drtest' } }
    $metadata = @{ name = 'workshop-bootstrap'; namespace = 'drtest' }
    $account = @{
        apiVersion = 'v1'; kind = 'ServiceAccount'
        metadata = @{ name = 'workshop-bootstrap'; namespace = 'drtest'; annotations = @{ 'azure.workload.identity/client-id' = $Settings.clientId } }
        automountServiceAccountToken = $false
    }
    $secret = @{
        apiVersion = 'v1'; kind = 'Secret'; type = 'Opaque'
        metadata = @{ name = 'workshop-bootstrap-input'; namespace = 'drtest' }
        stringData = @{
            'config.json' = ($Settings.config | ConvertTo-Json -Depth 80 -Compress)
            pgUser = [string]$Settings.pgUser; pgPassword = [string]$Settings.pgPassword
            imageUri = [string]$Settings.imageUri; imageSha256 = [string]$Settings.imageSha256
            bundle = $script:WorkshopBundle
        }
    }
    $job = @{
        apiVersion = 'batch/v1'; kind = 'Job'
        metadata = @{ name = $metadata.name; namespace = $metadata.namespace; annotations = @{ 'workshop/image-archive-sha256' = $Settings.imageSha256 } }
        spec = @{
            backoffLimit = 0; activeDeadlineSeconds = 270000
            template = @{
                metadata = @{ labels = @{ 'azure.workload.identity/use' = 'true'; app = 'workshop-bootstrap' } }
                spec = @{
                    serviceAccountName = 'workshop-bootstrap'; restartPolicy = 'Never'; automountServiceAccountToken = $false
                    securityContext = @{ runAsNonRoot = $true; runAsUser = 10001; runAsGroup = 10001; fsGroup = 10001 }
                    containers = @(@{
                        name = 'bootstrap'; image = 'mcr.microsoft.com/azure-cli:2.89.0'
                        command = @('/bin/bash', '-Eeuo', 'pipefail', '-c', @'
mkdir -p /work/source
python3 -c 'import base64,io,pathlib,zipfile; zipfile.ZipFile(io.BytesIO(base64.b64decode(pathlib.Path("/inputs/bundle").read_text()))).extractall("/work/source")'
exec bash /work/source/scripts/workshop-bootstrap-runner.sh
'@)
                        env = @(
                            @{ name = 'CRANE_URI'; value = $script:CraneUri }, @{ name = 'CRANE_SHA256'; value = $script:CraneSha256 },
                            @{ name = 'KUBECTL_URI'; value = $script:KubectlUri }, @{ name = 'KUBECTL_SHA256'; value = $script:KubectlSha256 }
                        )
                        resources = @{
                            requests = @{ cpu = '100m'; memory = '256Mi'; 'ephemeral-storage' = '2Gi' }
                            limits = @{ cpu = '1'; memory = '1Gi'; 'ephemeral-storage' = '8Gi' }
                        }
                        securityContext = @{ allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true; capabilities = @{ drop = @('ALL') } }
                        volumeMounts = @(
                            @{ name = 'work'; mountPath = '/work' }, @{ name = 'tmp'; mountPath = '/tmp' },
                            @{ name = 'inputs'; mountPath = '/inputs'; readOnly = $true }
                        )
                    })
                    volumes = @(
                        @{ name = 'work'; emptyDir = @{ sizeLimit = '7Gi' } }, @{ name = 'tmp'; emptyDir = @{ sizeLimit = '256Mi' } },
                        @{ name = 'inputs'; secret = @{ secretName = 'workshop-bootstrap-input'; defaultMode = 288 } }
                    )
                }
            }
        }
    }
    return @{ apiVersion = 'v1'; kind = 'List'; items = @($namespace, $account, $secret, $job) } | ConvertTo-Json -Depth 100 -Compress
}

$raw = Get-AutomationVariable -Name 'workshop-settings'
$settings = if ($raw -is [string]) { $raw | ConvertFrom-Json } else { $raw }
if ($settings.imageSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
    $settings.imageUri -notmatch '^https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/releases/download/[^/?#]+/app-image\.tar\.gz$') {
    throw 'A hash-pinned, anonymously accessible GitHub Release image asset is required.'
}
if (-not $script:WorkshopBundle -or -not $settings.pgUser -or -not $settings.pgPassword) { throw 'Bootstrap inputs are incomplete.' }
$script:ClusterId = [string]$settings.config.primary.aks.id
$null = Invoke-AksCommand 'kubectl create namespace drtest --dry-run=client -o json | kubectl apply -f -'
$existing = Invoke-AksCommand 'kubectl -n drtest get job workshop-bootstrap --ignore-not-found=true -o json'
if ($existing.Trim()) {
    $job = $existing | ConvertFrom-Json
    if ($job.metadata.annotations.'workshop/image-archive-sha256' -ne $settings.imageSha256) {
        throw 'A bootstrap Job for another image exists. Use the documented, explicitly approved recovery procedure.'
    }
} else {
    $context = New-CommandContext (New-BootstrapManifest $settings)
    $null = Invoke-AksCommand 'kubectl apply -f bootstrap.json' $context
    Write-Output 'Bootstrap Job submitted in KRC. Image download and private ACR transfer run inside AKS.'
}
$deadline = [DateTime]::UtcNow.AddMinutes(100)
while ([DateTime]::UtcNow -lt $deadline) {
    $job = (Invoke-AksCommand 'kubectl -n drtest get job workshop-bootstrap -o json') | ConvertFrom-Json
    if (@($job.status.conditions | Where-Object { $_.type -eq 'Failed' -and $_.status -eq 'True' }).Count -gt 0) {
        throw 'Bootstrap Job failed. Inspect its logs/conditions; application deployment is NOT successful.'
    }
    $statusText = Invoke-AksCommand 'kubectl -n drtest get configmap workshop-bootstrap-status --ignore-not-found=true -o json'
    if ($statusText.Trim()) {
        $status = $statusText | ConvertFrom-Json
        if ($status.data.phase -eq 'Failed') { throw 'Bootstrap reported failure. Inspect its Job; do not continue the workshop.' }
        if ($status.data.phase -in @('ApplicationReady', 'Complete')) {
            Write-Output "Application ready: http://$($settings.config.trafficManager.fqdn)/"
            Write-Output "Both apps, Service IPs and Traffic Manager verified. Sample state: $($status.data.phase). Check sample replication separately."
            return
        }
    }
    Start-Sleep -Seconds 30
}
throw 'Application readiness timed out. The AKS Job is retained for diagnosis; no success is reported. Automation cloud jobs have a 3-hour limit.'
