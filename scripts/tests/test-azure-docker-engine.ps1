#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$helper = Join-Path $root 'scripts\azure-docker-engine.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Operation, [string]$Message)
    $threw = $false
    try { & $Operation } catch { $threw = $true }
    Assert $threw $Message
}

foreach ($functionName in @('Assert-ApprovedClientCidr', 'Assert-OwnedRule', 'Invoke-Azure', 'Invoke-DockerCheck')) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Assert ($null -ne $definition) "Missing $functionName."
    . ([scriptblock]::Create($definition.Extent.Text))
}
foreach ($valid in @('4.230.26.165/32', '203.0.113.0/24', '10.0.0.0/8')) {
    Assert-ApprovedClientCidr $valid
}
foreach ($invalid in @('', '*', '0.0.0.0/0', '::/0', '4.230.26.165', '4.230.26.165/33', '999.230.26.165/32', '1.2.3/32', "1.2.3.4/32'")) {
    Assert-Throws { Assert-ApprovedClientCidr $invalid } "Accepted unsafe CIDR: $invalid."
}
$owner = 'aztemplate-docker-engine'
Assert-OwnedRule $null
Assert-OwnedRule @{ description = $owner }
Assert-Throws { Assert-OwnedRule @{ description = 'someone-else' } } 'Unowned NSG rule can be overwritten.'

# Mock only Azure's process boundary; stderr (including secrets) must never be returned.
function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $script:azureArguments = $Arguments
    $global:LASTEXITCODE = 0
    [Management.Automation.ErrorRecord]::new([Exception]::new('SECRET-STDERR'), 'mock', 'NotSpecified', $null)
    '{"safe":"value"}'
}
$result = Invoke-Azure @('aks', 'show', '-g', 'test-resource-group')
Assert ($result.safe -eq 'value') 'Azure stdout JSON was not parsed.'
Assert (($script:azureArguments -join '|') -eq 'aks|show|-g|test-resource-group|--only-show-errors|--output|json') 'Azure argument forwarding changed.'
function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $global:LASTEXITCODE = 1
    'SECRET-STDOUT'
}
try {
    Invoke-Azure @('aks', 'show')
    throw 'Expected Azure failure.'
} catch {
    Assert (-not $_.ToString().Contains('SECRET')) 'Azure failure leaked stdout/stderr.'
    Assert ($_.ToString().Contains('output suppressed')) 'Azure failure was not sanitized.'
}
Remove-Item Function:\az

$yaml = Get-Content -LiteralPath (Join-Path $root 'k8s\jobs\docker-engine.yaml') -Raw
Assert ($yaml.Contains('docker:27.5.1-dind')) 'Trusted Docker image pin missing.'
Assert ($yaml.Contains('privileged: true')) 'Real Docker engine privilege missing.'
Assert ($yaml.Contains('loadBalancerSourceRanges: ["__CLIENT_CIDR__"]')) 'Source filtering missing.'
Assert ($yaml.Contains('value: "IP:__PUBLIC_IP__"')) 'IP certificate SAN missing.'
Assert ($yaml.Contains('serviceAccountName: drtest-app')) 'Federated workload service account changed.'
Assert ($yaml.Contains('port: 2376')) 'mTLS port missing.'
Assert (-not $yaml.Contains('2375')) 'Plaintext Docker endpoint is exposed.'
Assert (-not $yaml.Contains('hostPath:')) 'Daemon must not mount the node Docker socket.'

$source = Get-Content -LiteralPath $helper -Raw
Assert ($source.Contains("'engine.json'")) 'Parent-facing engine config missing.'
Assert ($source.Contains('dockerPath = $docker; certificatePath = $directory')) 'Parent-facing config keys changed.'
Assert ($source.Contains('finally { Remove-PushGrant }')) 'Temporary push grants are not removed in finally.'
Assert (-not $source.Contains('--public-network-enabled')) 'Helper must never enable public ACR data plane.'
Assert ($source.Contains('https://download.docker.com/win/static/stable/x86_64/')) 'Docker CLI is not from its official source.'
Assert ($source.Contains('WaitForExit(30000)')) 'Docker readiness has an unbounded native process wait.'
Assert ($source.Contains('[IO.File]::WriteAllBytes')) 'Certificates must be written without printing their contents.'
Write-Output 'azure-docker-engine: CIDR, ownership, sanitized CLI, parameter/config contract and manifest safety tests passed.'
