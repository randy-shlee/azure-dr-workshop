#requires -Version 7.2
<#
.SYNOPSIS
Temporary, privileged Linux Docker engine in the config's private primary AKS.
.DESCRIPTION
Start requires an explicitly approved IPv4 client CIDR. Only port 2376 is exposed,
using the existing application IP, source filtering and mutually authenticated TLS.
The privileged daemon is trusted with build contexts; use only your own Azure cluster.
State and client private keys are stored in an ACL-protected, ignored .state directory.
Use -StateDirectory to select another protected builder folder; reuse it for Push/Stop.
Start emits a JSON config path and a dot-sourceable environment file (no embedded keys).
engine.json contains dockerHost, dockerPath and certificatePath for other helpers.
Push uses the workload identity inside AKS, never public ACR data-plane access.
Stop/Cleanup removes only helper-owned resources, certificates and temporary grants.
The drtest namespace and any preexisting drtest-app service account are preserved.
.EXAMPLE
.\scripts\azure-docker-engine.ps1 -Action Start -ConfigPath .state\config.json -ApprovedClientCidr 203.0.113.4/32
.EXAMPLE
.\scripts\azure-docker-engine.ps1 -Action Push -ConfigPath .state\config.json -Image myregistry.azurecr.io/drtest-app:v1
.EXAMPLE
.\scripts\azure-docker-engine.ps1 -Action Stop -ConfigPath .state\config.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'Stop', 'Cleanup', 'Push')][string]$Action,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$StateDirectory,
    [string]$ApprovedClientCidr,
    [string]$Image,
    [ValidateRange(60, 1800)][int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$owner = 'aztemplate-docker-engine'
$name = 'azure-docker-engine'
$namespace = 'drtest'
$ruleName = 'azure-docker-engine-mtls'
$previousWarnings = $env:PYTHONWARNINGS
$env:PYTHONWARNINGS = 'ignore'

function Invoke-Azure {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    # Never relay native stdout/stderr: AKS responses and ACR tokens may contain secrets.
    $result = & az @Arguments --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure operation '$($Arguments[0..1] -join ' ')' failed (output suppressed)." }
    $text = ($result | Where-Object { $_ -is [string] } | Out-String).Trim()
    if ($text) { return ($text | ConvertFrom-Json -Depth 100) }
}

function Invoke-Cluster {
    param([string]$Script)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("set -eu`n" + $Script.Replace("`r`n", "`n")))
    $response = Invoke-Azure @('aks', 'command', 'invoke', '--resource-group', $primary.aks.resourceGroup,
        '--name', $primary.aks.name, '--subscription', $subscription,
        '--command', "printf %s '$encoded' | base64 -d | bash")
    if ($null -eq $response.exitCode -or $response.exitCode -ne 0) {
        throw 'Private AKS command failed (remote output suppressed to protect credentials).'
    }
    return [string]$response.logs
}

function Save-State {
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Protect-Directory {
    param([string]$Path)
    $null = New-Item -ItemType Directory -Path $Path -Force
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-DockerCli {
    $existing = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }
    $tools = Join-Path $root '.state\azure-docker-cli-27.5.1'
    $exe = Join-Path $tools 'docker\docker.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        Protect-Directory $tools
        $zip = Join-Path $tools 'docker-27.5.1.zip'
        try {
            Invoke-WebRequest -Uri 'https://download.docker.com/win/static/stable/x86_64/docker-27.5.1.zip' -OutFile $zip
            Expand-Archive -LiteralPath $zip -DestinationPath $tools -Force
        } finally {
            if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
        }
    }
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Official Docker CLI extraction failed.' }
    return $exe
}

function Assert-OwnedRule {
    param($Rule)
    if ($Rule -and $Rule.description -ne $owner) { throw "NSG rule '$ruleName' is not helper-owned; refusing to modify it." }
}

function Assert-ApprovedClientCidr {
    param([string]$Cidr)
    if (-not $Cidr -or $Cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/([1-9]|[12][0-9]|3[0-2])$') {
        throw 'Start requires an explicitly approved, non-wildcard IPv4 -ApprovedClientCidr.'
    }
    $client = $null
    if (-not [Net.IPAddress]::TryParse(($Cidr -split '/')[0], [ref]$client)) { throw 'Invalid client CIDR.' }
}

function Invoke-DockerCheck {
    param([string[]]$Arguments)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($docker)
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $process.StartInfo.ArgumentList.Add($argument) }
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            $process.WaitForExit()
            return @{ success = $false; output = '' }
        }
        return @{ success = ($process.ExitCode -eq 0); output = $stdout.GetAwaiter().GetResult().Trim() }
    } finally { $process.Dispose() }
}

function Remove-PushGrant {
    if ($state.pushGrantId) {
        $null = Invoke-Azure @('role', 'assignment', 'delete', '--ids', $state.pushGrantId, '--subscription', $subscription)
        $state.pushGrantId = $null
        Save-State
    }
}

try {
    $null = Get-Command az -ErrorAction Stop
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 100
    $primary = $config.primary
    $subscription = ($primary.aks.id -split '/')[2]
    if ($subscription -notmatch '^[a-fA-F0-9-]{36}$') { throw 'Config must contain primary.aks.id with a subscription.' }
    foreach ($value in @($primary.aks.name, $primary.aks.resourceGroup, $primary.publicIp.name,
            $primary.publicIp.resourceGroup, $primary.identity.clientId, $primary.identity.principalId,
            $primary.acr.name, $primary.acr.loginServer)) {
        if (-not $value -or $value -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Config has a missing or invalid primary resource identifier.' }
    }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($primary.publicIp.address, [ref]$ip) -or
        $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'A primary public IPv4 address is required.' }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($primary.aks.id.ToLowerInvariant()))).Substring(0, 16).ToLowerInvariant()
    $directory = if ($StateDirectory) { [IO.Path]::GetFullPath($StateDirectory) } else {
        Join-Path $root ".state\azure-docker-engine\$hash"
    }
    $statePath = Join-Path $directory 'state.json'
    Protect-Directory $directory
    $state = if (Test-Path -LiteralPath $statePath) {
        Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
    } else {
        @{ clusterId = $primary.aks.id; owner = $owner; nsgId = $null; pushGrantId = $null }
    }
    if ($state.clusterId -ne $primary.aks.id -or $state.owner -ne $owner) { throw 'Engine state does not match this cluster.' }

    if ($Action -in @('Stop', 'Cleanup')) {
        # Delete by exact name only, after validating ownership of every object.
        $null = Invoke-Cluster @'
for resource in deployment/azure-docker-engine service/azure-docker-engine; do
  actual=$(kubectl get "$resource" -n drtest --ignore-not-found -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')
  if [ -n "$actual" ] && [ "$actual" != "aztemplate-docker-engine" ]; then exit 31; fi
  if kubectl get "$resource" -n drtest >/dev/null 2>&1; then
    [ "$actual" = "aztemplate-docker-engine" ] || exit 32
    kubectl delete "$resource" -n drtest --wait=true --timeout=120s >/dev/null
  fi
done
kubectl wait --for=delete pod -n drtest -l app=azure-docker-engine --timeout=120s >/dev/null
owned=$(kubectl get sa drtest-app -n drtest --ignore-not-found -o jsonpath='{.metadata.annotations.aztemplate-docker-engine/created-by}')
if [ "$owned" = "aztemplate-docker-engine" ]; then
  # A subsequently deployed app may now rely on this account. Preserve it then.
  users=$(kubectl get pods,deployments,statefulsets,daemonsets,jobs,cronjobs -n drtest -o jsonpath='{range .items[*]}{..serviceAccountName}{"\n"}{end}' | grep -c '^drtest-app$' || true)
  if [ "$users" = 0 ]; then kubectl delete sa drtest-app -n drtest --wait=true >/dev/null; fi
fi
'@
        Remove-PushGrant
        if ($state.nsgId) {
            $nsg = Invoke-Azure @('network', 'nsg', 'show', '--ids', $state.nsgId, '--subscription', $subscription)
            $rule = $nsg.securityRules | Where-Object name -EQ $ruleName
            Assert-OwnedRule $rule
            if ($rule) {
                $parts = $state.nsgId -split '/'
                $null = Invoke-Azure @('network', 'nsg', 'rule', 'delete', '-g', $parts[4], '--nsg-name', $parts[-1],
                    '-n', $ruleName, '--subscription', $subscription)
            }
        }
        foreach ($file in @('ca.pem', 'cert.pem', 'key.pem', 'docker-env.ps1', 'docker-config.json', 'engine.json', 'rendered.yaml')) {
            $path = Join-Path $directory $file
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        $state.stopped = $true
        Save-State
        Write-Output 'Temporary Docker deployment, Service, owned NSG rule and local credentials removed. Existing application resources preserved.'
        return
    }

    if ($Action -eq 'Push') {
        $null = Invoke-Cluster @'
actual=$(kubectl get deployment azure-docker-engine -n drtest -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')
[ "$actual" = "aztemplate-docker-engine" ] || exit 43
kubectl rollout status deployment/azure-docker-engine -n drtest --timeout=120s >/dev/null
'@
        $server = $primary.acr.loginServer.ToLowerInvariant()
        if (-not $Image -or -not $Image.StartsWith("$server/", [StringComparison]::Ordinal) -or
            $Image -notmatch '^[a-z0-9.-]+/[a-z0-9._/-]+:[a-zA-Z0-9_.-]+$') {
            throw 'Image must be a tagged image in the SAME config primary ACR (loginServer/repository:tag).'
        }
        $registry = Invoke-Azure @('acr', 'show', '-g', $primary.acr.resourceGroup, '-n', $primary.acr.name, '--subscription', $subscription)
        if ($registry.id -ne $primary.acr.id) { throw 'ACR ID does not match config.' }
        # Recover an interrupted push before creating a new grant. No existing grants are removed.
        Remove-PushGrant
        $grantName = [guid]::NewGuid().ToString()
        $scope = $registry.id
        $existing = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $scope, '--assignee-object-id',
            $primary.identity.principalId, '--role', 'AcrPush', '--subscription', $subscription))
        try {
            if (-not $existing.Count) {
                # Persist exact ID before creation, so Stop can recover an interrupted operation.
                $state.pushGrantId = "$scope/providers/Microsoft.Authorization/roleAssignments/$grantName"
                Save-State
                $grant = Invoke-Azure @('role', 'assignment', 'create', '--name', $grantName,
                    '--assignee-object-id', $primary.identity.principalId, '--assignee-principal-type', 'ServicePrincipal',
                    '--role', 'AcrPush', '--scope', $scope, '--subscription', $subscription)
                if ($grant.id -ne $state.pushGrantId) { throw 'Unexpected role assignment ID.' }
            }
            $python = @'
import base64, json, os, ssl, subprocess, sys, time, urllib.request, urllib.parse
def cli(args):
    p = subprocess.run(["az"] + args + ["--only-show-errors", "-o", "json"], capture_output=True, text=True, timeout=90)
    if p.returncode:
        raise RuntimeError("Azure authentication is not yet ready")
    return json.loads(p.stdout)
deadline = time.monotonic() + __TIMEOUT__
image = "__IMAGE__"
registry = "__REGISTRY__"
while time.monotonic() < deadline:
    try:
        with open(os.environ["AZURE_FEDERATED_TOKEN_FILE"]) as f:
            assertion = f.read()
        cli(["login", "--service-principal", "-u", os.environ["AZURE_CLIENT_ID"],
             "--tenant", os.environ["AZURE_TENANT_ID"], "--federated-token", assertion])
        token = cli(["acr", "login", "-n", "__ACR_NAME__", "--expose-token"])["accessToken"]
        auth = base64.b64encode(json.dumps({"username": "00000000-0000-0000-0000-000000000000",
            "password": token, "serveraddress": registry}).encode()).decode()
        ctx = ssl.create_default_context(cafile="/certs/client/ca.pem")
        ctx.load_cert_chain("/certs/client/cert.pem", "/certs/client/key.pem")
        repository, tag = image.rsplit(":", 1)
        url = "https://localhost:2376/v1.47/images/" + urllib.parse.quote(repository, safe="") + "/push?tag=" + urllib.parse.quote(tag)
        request = urllib.request.Request(url, data=b"", headers={"X-Registry-Auth": auth}, method="POST")
        with urllib.request.urlopen(request, context=ctx, timeout=300) as response:
            for line in response:
                if line.strip():
                    event = json.loads(line)
                    if "error" in event or "errorDetail" in event:
                        raise RuntimeError("Registry push was not accepted")
        print("Image pushed to config primary private ACR.")
        sys.exit(0)
    except Exception:
        # Exceptions/CLI output may include credentials. Never print them.
        time.sleep(15)
print("Private ACR push did not succeed before the bounded retry deadline.", file=sys.stderr)
sys.exit(1)
'@
            $python = $python.Replace('__IMAGE__', $Image).Replace('__REGISTRY__', $server).
                Replace('__ACR_NAME__', $primary.acr.name).Replace('__TIMEOUT__', [string]$TimeoutSeconds)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($python))
            $null = Invoke-Cluster "kubectl exec -n drtest deployment/azure-docker-engine -c registry -- python3 -c `"import base64; exec(base64.b64decode('$encoded'))`""
            Write-Output "Pushed $Image using the config's workload identity inside private AKS."
        } finally { Remove-PushGrant }
        return
    }

    Assert-ApprovedClientCidr $ApprovedClientCidr
    $docker = Get-DockerCli
    $aks = Invoke-Azure @('aks', 'show', '-g', $primary.aks.resourceGroup, '-n', $primary.aks.name, '--subscription', $subscription)
    if (-not $aks.apiServerAccessProfile.enablePrivateCluster -or -not $aks.securityProfile.workloadIdentity.enabled) {
        throw 'The target must be a private AKS cluster with workload identity enabled.'
    }
    $pip = Invoke-Azure @('network', 'public-ip', 'show', '--ids', $primary.publicIp.id, '--subscription', $subscription)
    if ($pip.ipAddress -ne $primary.publicIp.address -or $pip.publicIPAllocationMethod -ne 'Static') {
        throw 'Config must reference the existing, reserved static public IP.'
    }
    $subnet = Invoke-Azure @('network', 'vnet', 'subnet', 'show', '--ids', $aks.agentPoolProfiles[0].vnetSubnetId, '--subscription', $subscription)
    if (-not $subnet.networkSecurityGroup.id) { throw 'Expected an existing AKS subnet NSG.' }
    $state.nsgId = $subnet.networkSecurityGroup.id
    $state.approvedClientCidr = $ApprovedClientCidr
    $state.stopped = $false
    Save-State
    $nsg = Invoke-Azure @('network', 'nsg', 'show', '--ids', $state.nsgId, '--subscription', $subscription)
    $rule = $nsg.securityRules | Where-Object name -EQ $ruleName
    Assert-OwnedRule $rule
    $priority = if ($rule) { $rule.priority } else {
        200..299 | Where-Object { $_ -notin @($nsg.securityRules.priority) } | Select-Object -First 1
    }
    if (-not $priority) { throw 'No free NSG priority in the helper range 200-299.' }
    $parts = $state.nsgId -split '/'
    $null = Invoke-Azure @('network', 'nsg', 'rule', 'create', '-g', $parts[4], '--nsg-name', $parts[-1], '-n', $ruleName,
        '--priority', [string]$priority, '--direction', 'Inbound', '--access', 'Allow', '--protocol', 'Tcp',
        '--source-address-prefixes', $ApprovedClientCidr, '--source-port-ranges', '*',
        '--destination-address-prefixes', '*', '--destination-port-ranges', '2376',
        '--description', $owner, '--subscription', $subscription)
    $saScript = @'
kubectl get namespace drtest >/dev/null 2>&1 || kubectl create namespace drtest >/dev/null
if kubectl get sa drtest-app -n drtest >/dev/null 2>&1; then
  actual=$(kubectl get sa drtest-app -n drtest -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}')
  [ "$actual" = "__CLIENT_ID__" ] || exit 41
else
  kubectl create sa drtest-app -n drtest >/dev/null
  kubectl annotate sa drtest-app -n drtest azure.workload.identity/client-id=__CLIENT_ID__ aztemplate-docker-engine/created-by=aztemplate-docker-engine >/dev/null
fi
for resource in deployment/azure-docker-engine service/azure-docker-engine; do
  if kubectl get "$resource" -n drtest >/dev/null 2>&1; then
    actual=$(kubectl get "$resource" -n drtest -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')
    [ "$actual" = "aztemplate-docker-engine" ] || exit 42
  fi
done
'@
    $null = Invoke-Cluster $saScript.Replace('__CLIENT_ID__', $primary.identity.clientId)
    $manifest = Get-Content -LiteralPath (Join-Path $root 'k8s\jobs\docker-engine.yaml') -Raw
    $manifest = $manifest.Replace('__PUBLIC_IP__', $primary.publicIp.address).
        Replace('__PUBLIC_IP_RG__', $primary.publicIp.resourceGroup).Replace('__PUBLIC_IP_NAME__', $primary.publicIp.name).
        Replace('__CLIENT_CIDR__', $ApprovedClientCidr)
    $encodedManifest = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($manifest))
    $null = Invoke-Cluster "printf %s '$encodedManifest' | base64 -d | kubectl apply -f - >/dev/null`nkubectl rollout status deployment/azure-docker-engine -n drtest --timeout=$($TimeoutSeconds)s >/dev/null"
    # Client keys exist only in the AKS response held in memory and ACL-protected local files.
    $certScript = @'
kubectl exec -n drtest deployment/azure-docker-engine -c registry -- python3 -c 'import base64,json; print(json.dumps({n:base64.b64encode(open("/certs/client/"+n,"rb").read()).decode() for n in ["ca.pem","cert.pem","key.pem"]}))'
'@
    $certificates = (Invoke-Cluster $certScript).Trim() | ConvertFrom-Json
    foreach ($file in @('ca.pem', 'cert.pem', 'key.pem')) {
        [IO.File]::WriteAllBytes((Join-Path $directory $file), [Convert]::FromBase64String($certificates.$file))
    }
    $certificates = $null
    $hostUri = "tcp://$($primary.publicIp.address):2376"
    $dockerArguments = @('--host', $hostUri, '--tlsverify', '--tlscacert', (Join-Path $directory 'ca.pem'),
        '--tlscert', (Join-Path $directory 'cert.pem'), '--tlskey', (Join-Path $directory 'key.pem'))
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $verified = $false
    do {
        $info = Invoke-DockerCheck -Arguments ($dockerArguments + @('info', '--format', '{{.OSType}}/{{.Architecture}}'))
        if ($info.success -and $info.output -eq 'linux/x86_64') { $verified = $true; break }
        Start-Sleep -Seconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $verified) { throw 'mTLS Docker info did not return linux/x86_64 before deadline. Use Stop to clean up.' }
    $version = Invoke-DockerCheck -Arguments ($dockerArguments + @('version', '--format', '{{.Server.Version}}'))
    if (-not $version.success) { throw 'mTLS Docker version verification failed.' }
    $engineConfig = [ordered]@{
        dockerHost = $hostUri; dockerTlsVerify = '1'; dockerCertPath = $directory
        dockerCliPath = $docker; platform = 'linux/amd64'; serverVersion = $version.output
        dockerPath = $docker; certificatePath = $directory
        clusterId = $primary.aks.id; approvedClientCidr = $ApprovedClientCidr
        configPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    }
    $enginePath = Join-Path $directory 'docker-config.json'
    $engineConfig | ConvertTo-Json | Set-Content -LiteralPath $enginePath -Encoding utf8
    $engineConfig | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'engine.json') -Encoding utf8
    $environmentPath = Join-Path $directory 'docker-env.ps1'
    @(
        "`$env:DOCKER_HOST = '$hostUri'"
        "`$env:DOCKER_TLS_VERIFY = '1'"
        "`$env:DOCKER_CERT_PATH = '$($directory.Replace("'", "''"))'"
        "`$env:DOCKER_CONTEXT = `$null"
        "`$env:PATH = '$((Split-Path $docker -Parent).Replace("'", "''"))' + [IO.Path]::PathSeparator + `$env:PATH"
    ) | Set-Content -LiteralPath $environmentPath -Encoding utf8
    Write-Output "Verified Docker $($version.output) linux/amd64 over mTLS."
    Write-Output "Docker CLI: $docker"
    Write-Output "Environment: $environmentPath"
    Write-Output "AzureBuildConfigPath: $enginePath"
    Write-Output "Cleanup: .\scripts\azure-docker-engine.ps1 -Action Stop -ConfigPath '$((Resolve-Path -LiteralPath $ConfigPath).Path)' -StateDirectory '$directory'"
} finally {
    $env:PYTHONWARNINGS = $previousWarnings
}
