#requires -Version 7.2
param([string]$TemplatePath, [string]$PortalTemplatePath, [string]$EventHubsUpdateTemplatePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$failures = [Collections.Generic.List[string]]::new()
$script:passed = 0

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $caught = $false
    try { & $Body } catch { $caught = $true; Assert ($_.Exception.Message -match $Pattern) "Unexpected error: $($_.Exception.Message)" }
    Assert $caught 'Expected failure was not raised.'
}
function Test {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $failures.Add($Name); Write-Host "FAIL $Name : $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
}
foreach ($file in @('workshop-bootstrap.ps1', 'package-workshop-release.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root "scripts\$file"), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parse errors in $file : $errors" }
    foreach ($node in $ast.EndBlock.Statements) {
        if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) {
            Set-Item "Function:script:$($node.Name)" -Value $node.Body.GetScriptBlock()
        }
    }
}
$originalArm = (Get-Item Function:Invoke-Arm).ScriptBlock
function script:Start-Sleep { param($Seconds) }
$script:WorkshopBundle = New-SourceBundle $root
$script:CraneUri = 'https://github.com/google/go-containerregistry/releases/download/v0.20.6/go-containerregistry_Linux_x86_64.tar.gz'
$script:CraneSha256 = 'a' * 64
$script:KubectlUri = 'https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl'
$script:KubectlSha256 = 'b' * 64
$script:ClusterId = '/subscriptions/test/resourceGroups/rg-test-krc/providers/Microsoft.ContainerService/managedClusters/aks-test-krc'
$settings = @{
    config = @{ primary = @{ aks = @{ id = $script:ClusterId } }; features = @{ deployRedis = $false } }
    pgUser = 'dradmin'; pgPassword = " leading `n quoted`" password trailing `n"
    clientId = 'bootstrap-client'; imageUri = 'https://github.com/test-org/test-repo/releases/download/v1.0.0/app-image.tar.gz'
    imageSha256 = 'c' * 64
}

Test 'source bundle contains only canonical allowlisted files, with LF Bash' {
    $memory = [IO.MemoryStream]::new([Convert]::FromBase64String($script:WorkshopBundle))
    $zip = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read)
    try {
        Assert ($zip.Entries.Count -eq 14) 'Unexpected source allowlist.'
        Assert (@($zip.Entries | Where-Object { $_.FullName -match '\.state|\.env|app/main|image\.tar|secret' }).Count -eq 0) 'Sensitive/unnecessary file included.'
        foreach ($entry in $zip.Entries) {
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            Assert (-not $text.Contains("`r")) "CRLF in bundle: $($entry.FullName)"
            $source = [IO.File]::ReadAllText((Join-Path $root $entry.FullName)).Replace("`r`n", "`n")
            Assert ($source -ceq $text) "Bundle diverged from canonical source: $($entry.FullName)"
        }
    } finally { $zip.Dispose(); $memory.Dispose() }
}
Test 'Kubernetes bootstrap contract uses WI, bounded resources, private transfer and Secret volume' {
    $manifest = New-BootstrapManifest $settings | ConvertFrom-Json
    $job = $manifest.items | Where-Object kind -eq Job
    $secret = $manifest.items | Where-Object kind -eq Secret
    $pod = $job.spec.template.spec
    Assert ($secret.stringData.pgPassword -ceq $settings.pgPassword) 'Password whitespace changed.'
    Assert ($job.metadata.annotations.'workshop/image-archive-sha256' -eq $settings.imageSha256) 'Missing idempotency hash.'
    Assert ($job.spec.backoffLimit -eq 0) 'Unexpected automatic secret-bearing retry.'
    Assert ($pod.serviceAccountName -eq 'workshop-bootstrap') 'Incorrect WI subject.'
    Assert ($pod.securityContext.runAsNonRoot -and -not $pod.automountServiceAccountToken) 'Unexpected API token/root.'
    Assert ($pod.containers[0].resources.limits.memory -eq '1Gi') 'Bootstrap memory is not bounded.'
    Assert ($pod.volumes[2].secret.secretName -eq 'workshop-bootstrap-input') 'Missing restricted input volume.'
    Assert (($pod.containers[0].command -join ' ') -notmatch [regex]::Escape($settings.pgPassword)) 'Secret in command string.'
}
Test 'runCommand context is a UTF8 ZIP attachment, not a tar or command-secret string' {
    $json = New-BootstrapManifest $settings
    $context = New-CommandContext $json
    $memory = [IO.MemoryStream]::new([Convert]::FromBase64String($context))
    $zip = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read)
    try {
        Assert ($zip.Entries.Count -eq 1 -and $zip.Entries[0].FullName -eq 'bootstrap.json') 'Incorrect attachment.'
        $reader = [IO.StreamReader]::new($zip.Entries[0].Open())
        try { Assert ($reader.ReadToEnd() -ceq $json) 'Context altered JSON/secret bytes.' } finally { $reader.Dispose() }
    } finally { $zip.Dispose(); $memory.Dispose() }
}
Test 'ARM async command Location is polled and result properties are unwrapped' {
    $script:armCalls = @()
    function script:Invoke-Arm {
        param($Method, $Uri, $Body)
        $script:armCalls += @{ method = $Method; uri = $Uri; body = $Body }
        if ($Method -eq 'Post') { return @{ StatusCode = 202; Headers = @{ Location = "https://management.azure.com/result" } } }
        return @{ StatusCode = 200; Content = '{"properties":{"provisioningState":"Succeeded","exitCode":0,"logs":"ready"}}'; Headers = @{} }
    }
    Assert ((Invoke-AksCommand 'kubectl apply -f bootstrap.json' 'ZIP-SECRET') -eq 'ready') 'Async result missing.'
    Assert ($script:armCalls.Count -eq 2) 'Location not polled.'
    $body = $script:armCalls[0].body | ConvertFrom-Json
    Assert ($body.context -eq 'ZIP-SECRET' -and $body.command -notmatch 'ZIP-SECRET') 'Context leaked to command.'
}
Test 'remote nonzero exit is never success' {
    function script:Invoke-Arm { return @{ StatusCode = 200; Content = '{"properties":{"provisioningState":"Succeeded","exitCode":1,"logs":"failed"}}' } }
    Assert-Throws { Invoke-AksCommand 'false' } 'AKS command failed'
}
Test 'missing exitCode and kubectl error output are not success-shaped fallbacks' {
    function script:Invoke-Arm { return @{ StatusCode = 200; Content = '{"properties":{"provisioningState":"Succeeded","logs":"not ready"}}'; Headers = @{} } }
    Assert-Throws { Invoke-AksCommand 'test' } 'no completed result'
    function script:Invoke-Arm { return @{ StatusCode = 200; Content = '{"properties":{"provisioningState":"Succeeded","exitCode":0,"logs":"error: denied"}}'; Headers = @{} } }
    Assert-Throws { Invoke-AksCommand 'test' } 'output contains an error'
}
Test 'portal JSON defaults differ explicitly from CLI and contain no administrator defaults' {
    $template = @{ parameters = @{} }
    foreach ($key in @('deployWorkshopBootstrap','sampleDataSizeGB','smallFileCount','bootstrapRunbookUri','bootstrapRunbookSha256','appImageArchiveUri','appImageArchiveSha256')) {
        $template.parameters[$key] = @{}
    }
    Test 'unapproved remote Docker endpoints are rejected before build-context transfer' {
        Assert-DockerEndpoint 'npipe://local-test-engine' ''
        $previousTls = $env:DOCKER_TLS_VERIFY
        try {
            $env:DOCKER_TLS_VERIFY = ''
            Assert-Throws { Assert-DockerEndpoint 'tcp://untrusted.example:2376' '' } 'explicit AzureBuildConfigPath'
        } finally { $env:DOCKER_TLS_VERIFY = $previousTls }
    }
    Test 'local deployment rejects corrupt or blocked releases before Azure mutation' {
        $folder = Join-Path $root ".state\local-package-test-$PID"
        $prefix = 't' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
        $state = Join-Path $root ".state\deployments\$prefix"
        $null = New-Item -ItemType Directory -Path $folder
        try {
            '{}' | Set-Content -LiteralPath (Join-Path $folder 'azuredeploy.json')
            @{ templateSha256 = '0' * 64 } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $folder 'release-manifest.json')
            Assert-Throws {
                & (Join-Path $root 'scripts\deploy-local-package.ps1') -ReleaseDirectory $folder `
                    -Prefix $prefix -SubscriptionId test -AllowedClientCidrs '203.0.113.1/32'
            } 'Release asset integrity check failed'
            @{ blocked = $true } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $folder 'release-manifest.json')
            Assert-Throws {
                & (Join-Path $root 'scripts\deploy-local-package.ps1') -ReleaseDirectory $folder `
                    -Prefix $prefix -SubscriptionId test -AllowedClientCidrs '203.0.113.1/32'
            } 'release is blocked'
        } finally {
            Remove-Item -LiteralPath (Join-Path $folder 'azuredeploy.json'), (Join-Path $folder 'release-manifest.json')
            Remove-Item -LiteralPath $folder
            if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state }
        }
    }
    $template.parameters.allowedClientCidrs = @{ defaultValue = @('old-IP') }
    $result = Set-PortalDefaults $template 'https://github.com/a/b/releases/download/v1.0.0' ('a' * 64) ('b' * 64)
    Assert ($result.parameters.deployWorkshopBootstrap.defaultValue -eq $true) 'Bootstrap not enabled.'
    Assert ($result.parameters.sampleDataSizeGB.defaultValue -eq 10 -and $result.parameters.smallFileCount.defaultValue -eq 2000) 'Wrong workshop volume.'
    Assert (-not $result.parameters.allowedClientCidrs.ContainsKey('defaultValue') -and $result.parameters.allowedClientCidrs.minLength -eq 1) 'CIDR must be entered.'
    Assert ($result.parameters.bootstrapRunbookSha256.defaultValue -eq ('b' * 64)) 'Runbook hash mismatch.'
    Assert (-not $result.parameters.ContainsKey('administratorPassword')) 'Credentials added to portal artifact.'
}
Test 'Bash archive hash validation and Windows @parameter-file conversion execute real helpers' {
    $folder = [IO.Path]::GetFullPath((Join-Path $root ".state\bootstrap-shell-$PID"))
    Assert (-not (Test-Path $folder)) 'Shell test path already exists.'
    $null = New-Item -ItemType Directory -Path $folder
    $runner = Get-Content -Raw (Join-Path $root 'scripts\workshop-bootstrap-runner.sh')
    $download = [regex]::Match($runner, '(?ms)^download_verified\(\) \{.*?^\}').Value
    Assert ([bool]$download) 'Actual downloader helper missing.'
    $test = @'
set -Eeuo pipefail
root="$WORKSHOP_TEST_ROOT"; folder="$WORKSHOP_TEST_FOLDER"
if command -v cygpath >/dev/null; then root="$(cygpath -u "$root")"; folder="$(cygpath -u "$folder")"; fi
source "$root/scripts/common.sh"
export PATH="$folder:$PATH"
actual="$(az deployment sub what-if --parameters "@$folder/parameters.json")"
if command -v cygpath >/dev/null; then expected="@$(cygpath -w "$folder/parameters.json")"; else expected="@$folder/parameters.json"; fi
[[ "$actual" == *"$expected"* ]] || die 'Parameter file path was not converted.'
export DRTEST_WORKLOAD_LOGIN=true AZURE_CLIENT_ID=test-client AZURE_TENANT_ID=test-tenant
export AZURE_FEDERATED_TOKEN_FILE="$folder/token"
printf 'fresh-token-one' >"$folder/token"
az account show >/dev/null
printf 'fresh-token-two' >"$folder/token"
az account show >/dev/null
grep -q 'fresh-token-one' "$folder/login.txt" && grep -q 'fresh-token-two' "$folder/login.txt" || die 'Projected token was not reread.'
curl() {
  local target=''
  while (( $# )); do
    if [[ "$1" == -o ]]; then target="$2"; shift 2; else shift; fi
  done
  printf fixture >"$target"
}
'@ + "`n$download`n" + @'
download_verified https://github.com/test-org/test-repo/releases/download/v1.0.0/app-image.tar.gz "$WORKSHOP_TEST_HASH" "$folder/download.bin"
'@
    $scriptFile = Join-Path $folder 'test.sh'
    [IO.File]::WriteAllText($scriptFile, $test.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    $shim = @'
#!/usr/bin/env bash
if [[ "$1" == login ]]; then
  log="$WORKSHOP_TEST_FOLDER/login.txt"
  if command -v cygpath >/dev/null; then log="$(cygpath -u "$log")"; fi
  printf '%s\n' "$*" >>"$log"
else
  printf '%s\n' "$@"
fi
'@
    [IO.File]::WriteAllText((Join-Path $folder 'az'), $shim.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $folder 'parameters.json'), '{}')
    $oldRoot = $env:WORKSHOP_TEST_ROOT; $oldFolder = $env:WORKSHOP_TEST_FOLDER; $oldHash = $env:WORKSHOP_TEST_HASH
    $env:WORKSHOP_TEST_ROOT = $root; $env:WORKSHOP_TEST_FOLDER = $folder
    $env:WORKSHOP_TEST_HASH = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('fixture'))).ToLowerInvariant()
    $bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git\bin\bash.exe' } else { (Get-Command bash).Source }
    try {
        if (-not $IsWindows) { & chmod 700 (Join-Path $folder 'az') }
        $command = 'script="$WORKSHOP_TEST_FOLDER/test.sh"; if command -v cygpath >/dev/null; then script="$(cygpath -u "$script")"; fi; bash "$script"'
        $output = & $bash --noprofile --norc -c $command 2>&1
        Assert ($LASTEXITCODE -eq 0) "Valid hash/path rejected: $output"
        $env:WORKSHOP_TEST_HASH = '0' * 64
        $output = & $bash --noprofile --norc -c $command 2>&1
        Assert ($LASTEXITCODE -ne 0 -and ($output -join "`n") -match 'SHA256 mismatch') 'Corrupt archive was accepted.'
    } finally {
        $env:WORKSHOP_TEST_ROOT = $oldRoot; $env:WORKSHOP_TEST_FOLDER = $oldFolder; $env:WORKSHOP_TEST_HASH = $oldHash
        foreach ($name in @('test.sh','az','parameters.json','download.bin','token','login.txt')) {
            $path = Join-Path $folder $name
            if (Test-Path $path) { Remove-Item -LiteralPath $path }
        }
        Remove-Item -LiteralPath $folder
    }
}
Test 'real local packaging flow is mocked through build/save/compression/ARM/button generation' {
    $version = "v0.0.0-test-$PID"
    $stage = [IO.Path]::GetFullPath((Join-Path $root ".state\releases\$version"))
    Assert (-not (Test-Path $stage)) 'Test release path already exists.'
    $global:WorkshopTestDockerCalls = [Collections.Generic.List[object]]::new()
    $global:WorkshopTestFixtureParameters = @{}
    foreach ($key in @('deployWorkshopBootstrap','sampleDataSizeGB','smallFileCount','bootstrapRunbookUri','bootstrapRunbookSha256','appImageArchiveUri','appImageArchiveSha256','allowedClientCidrs')) {
        $global:WorkshopTestFixtureParameters[$key] = @{}
    }
    function script:docker {
        $global:LASTEXITCODE = 0
        $global:WorkshopTestDockerCalls.Add(@{ args = @($args); location = (Get-Location).Path })
        switch ($args[0]) {
            context { 'npipe://local-test-engine' }
            info { 'linux' }
            image { 'linux/amd64' }
            save { [IO.File]::WriteAllText($args[2], 'MOCK docker save bytes, not a real image') }
            build { }
            default { throw 'Unexpected Docker command.' }
        }
    }
    function script:az {
        $global:LASTEXITCODE = 0
        Assert ($args[0] -eq 'bicep' -and $args[1] -eq 'build') 'Unexpected Azure mutation.'
        Assert ($args[3] -eq (Join-Path $root 'infra\workshop.bicep')) 'Packager must compile the owner/budget-free portal entry point.'
        @{ '$schema' = 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'; parameters = $global:WorkshopTestFixtureParameters } |
            ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $args[-1]
    }
    function script:Invoke-WebRequest {
        param($Uri, $OutFile, $TimeoutSec)
        Assert ($Uri -eq 'https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl.sha256') 'Unexpected external download.'
        [IO.File]::WriteAllText($OutFile, ('d' * 64))
    }
    try {
        & (Join-Path $root 'scripts\package-workshop-release.ps1') -Repository test-org/test-repo -ReleaseTag $version
        $manifest = Get-Content -Raw (Join-Path $stage 'release-manifest.json') | ConvertFrom-Json
        $image = Join-Path $stage 'app-image.tar.gz'
        Assert ((Get-FileHash $image).Hash.ToLowerInvariant() -eq $manifest.imageSha256) 'Archive hash does not match.'
        Assert ((Get-FileHash (Join-Path $stage 'deployment-tools.zip')).Hash.ToLowerInvariant() -eq $manifest.toolsSha256) 'Deployment tool archive hash does not match.'
        Assert ($manifest.uploadMaxBytes -eq 10000000000 -and $manifest.imageTag -eq "drtest-app:$version") 'Local deployment image/cap metadata is missing.'
        Assert ($global:WorkshopTestDockerCalls[2].args[0] -eq 'build' -and $global:WorkshopTestDockerCalls[2].args[-1] -eq '.') 'Wrong build context.'
        Assert ($global:WorkshopTestDockerCalls[2].location -eq (Join-Path $root 'app')) 'Workspace sent instead of app-only context.'
        Assert (@($global:WorkshopTestDockerCalls | Where-Object { $_.args[0] -in @('push','login') }).Count -eq 0) 'Published without approval.'
        $button = Get-Content -Raw (Join-Path $stage 'deploy-button.md')
        $expectedTemplateUri = "https://raw.githubusercontent.com/test-org/test-repo/$version/workshop/releases/azuredeploy.json"
        Assert ($manifest.templateUri -ceq $expectedTemplateUri) 'Portal template must use a tag-pinned CORS-enabled raw URL.'
        Assert ($button.Contains([Uri]::EscapeDataString($expectedTemplateUri))) 'Template URI not encoded.'
        Assert (-not $button.Contains('https%3A%2F%2Fgithub.com%2F')) 'Release download URL is not browser-CORS compatible.'
        $templateText = [IO.File]::ReadAllText((Join-Path $stage 'azuredeploy.json'))
        Assert (-not $templateText.Contains("`r")) 'Portal template must use LF so Git normalization preserves its SHA256.'
        Assert ((Get-FileHash (Join-Path $stage 'azuredeploy.json')).Hash.ToLowerInvariant() -eq $manifest.templateSha256) 'Template hash does not match.'
        $compiled = Get-Content -Raw (Join-Path $stage 'azuredeploy.json') | ConvertFrom-Json
        Assert ($compiled.parameters.appImageArchiveSha256.defaultValue -eq $manifest.imageSha256) 'Portal image hash mismatch.'
        $errors = $null; $tokens = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $stage 'workshop-bootstrap.ps1'), [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0) 'Generated runbook does not parse.'
    } finally {
        Remove-Item Function:script:docker, Function:script:az, Function:script:Invoke-WebRequest
        foreach ($name in @('app-image.tar','app-image.tar.gz','workshop-bootstrap.ps1','azuredeploy.json','release-manifest.json','deploy-button.md','kubectl.sha256','deployment-tools.zip','DEPLOYMENT.md')) {
            $path = Join-Path $stage $name
            if (Test-Path $path) { Remove-Item -LiteralPath $path }
        }
        if (Test-Path $stage) { Remove-Item -LiteralPath $stage }
    }
}
if ($PortalTemplatePath) {
    Test 'compiled portal excludes owner and budget inputs and disables their dependent resources' {
        $portal = Get-Content -Raw $PortalTemplatePath | ConvertFrom-Json -AsHashtable
        foreach ($name in @('owner','monthlyBudget','budgetStartDate','deployBudget','deployAlerts','enableStorageLastSyncCustomMetricAlert')) {
            Assert (-not $portal.parameters.ContainsKey($name)) "Unexpected portal input: $name"
        }
        $module = @($portal.resources | Where-Object name -like '*-infrastructure*')
        Assert ($module.Count -eq 1) 'Expected one shared infrastructure deployment.'
        $parameters = $module[0].properties.parameters
        Assert ($parameters.owner.value -ceq '') 'Portal must not substitute a fictitious owner.'
        Assert ($parameters.deployBudget.value -eq $false) 'Portal must not deploy a budget.'
        Assert ($parameters.deployAlerts.value -eq $false) 'Email alerts require the CLI owner profile.'
        $inner = $module[0].properties.template
        $budget = @($inner.resources | Where-Object type -eq 'Microsoft.Consumption/budgets')
        Assert ($budget.Count -eq 1 -and $budget[0].condition -eq "[parameters('deployBudget')]") 'Budget resource is not gated.'
        Assert ($inner.parameters.deployBudget.defaultValue -eq $true) 'CLI budget default changed.'
        Assert ($inner.outputs.config.value.Contains("'budget', if(parameters('deployBudget'), parameters('monthlyBudget'), 0)")) 'Budget-free output amount must be zero.'
        Assert ($inner.outputs.config.value.Contains("'budgetName', if(parameters('deployBudget'), format('{0}-drtest-budget', parameters('prefix')), '')")) 'Budget-free cleanup output must be empty.'
        Assert ($portal.outputs.config.value -match 'outputs.config.value') 'Portal config output must forward the shared deployment.'
    }
}
if ($TemplatePath) {
    Test 'compiled bootstrap uses encrypted variables, gated jobs and no private ACR relaxation' {
        $template = Get-Content -Raw $TemplatePath | ConvertFrom-Json
        Assert ($template.parameters.deployWorkshopBootstrap.defaultValue -eq $false) 'CLI behavior changed.'
        $module = $template.resources | Where-Object name -eq 'workshop-bootstrap'
        $resources = $module.properties.template.resources
        $account = $resources | Where-Object type -eq 'Microsoft.Automation/automationAccounts'
        Assert ($account.properties.publicNetworkAccess -and $account.properties.disableLocalAuth) 'Network/auth boundary not explicit.'
        $variable = $resources | Where-Object type -eq 'Microsoft.Automation/automationAccounts/variables'
        Assert $variable.properties.isEncrypted 'Secrets not encrypted.'
        Assert (@($resources | Where-Object type -match 'webhooks').Count -eq 0) 'Unexpected webhook.'
        $start = $template.resources | Where-Object name -eq 'workshop-start'
        Assert ($start.dependsOn.Count -ge 3) 'Job can start before scoped RBAC.'
        $acrModule = $template.resources | Where-Object name -eq 'acr'
        $registry = $acrModule.properties.template.resources | Where-Object type -eq 'Microsoft.ContainerRegistry/registries'
        Assert ($registry.properties.publicNetworkAccess -eq 'Disabled' -and $registry.properties.networkRuleBypassOptions -eq 'None') 'ACR was relaxed.'
    }
}
if ($EventHubsUpdateTemplatePath) {
    Test 'Event Hubs migration touches no other data layer and scopes existing network IDs correctly' {
        $update = Get-Content -Raw $EventHubsUpdateTemplatePath | ConvertFrom-Json -AsHashtable
        function Get-UpdateResources($node) {
            foreach ($resource in $node.resources) {
                $resource
                if ($resource.properties.template) { Get-UpdateResources $resource.properties.template }
            }
        }
        $resources = @(Get-UpdateResources $update)
        $allowed = @(
            'Microsoft.Resources/deployments', 'Microsoft.EventHub/namespaces',
            'Microsoft.EventHub/namespaces/eventhubs', 'Microsoft.EventHub/namespaces/disasterRecoveryConfigs',
            'Microsoft.Authorization/roleAssignments', 'Microsoft.Insights/diagnosticSettings',
            'Microsoft.Network/privateEndpoints', 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
        )
        Assert (@($resources | Where-Object { $_.type -notin $allowed }).Count -eq 0) 'EH-only migration must not redeploy databases, clusters, storage or resource groups.'
        Assert (@($resources | Where-Object type -eq 'Microsoft.EventHub/namespaces').Count -eq 2) 'Expected two Standard namespaces.'
        Assert (@($resources | Where-Object type -eq 'Microsoft.EventHub/namespaces/disasterRecoveryConfigs').Count -eq 1) 'Expected one alias.'
        $parameters = $update.resources[0].properties.parameters
        foreach ($name in @('primarySubnetId','secondarySubnetId','primaryDnsZoneId','secondaryDnsZoneId')) {
            Assert ($parameters[$name].value.Contains('resourceId(subscription().subscriptionId,')) "Missing explicit subscription in existing $name."
        }
        Assert ($update.outputs.config.type -eq 'object') 'Migration must export a complete merged config.'
        Assert ($update.outputs.config.value.StartsWith('[shallowMerge(')) 'Recursive union would restore the removed legacy feature flag.'
        Assert ([regex]::Matches($update.outputs.config.value, 'shallowMerge\(').Count -eq 3) 'Replace both regional EH objects without retaining legacy namespace metadata.'
    }
}
Set-Item Function:script:Invoke-Arm -Value $originalArm
Remove-Item Function:script:Start-Sleep
Write-Host "Workshop bootstrap tests: $script:passed passed, $($failures.Count) failed."
if ($failures.Count) { exit 1 }
