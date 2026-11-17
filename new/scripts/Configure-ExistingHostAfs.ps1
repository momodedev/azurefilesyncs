[CmdletBinding()]
param(
    [string]$SubscriptionId = '95642268-5116-484d-9b88-7dfce8c20ce4',
    [string]$TenantId = '0e478cd4-3e52-496d-ac3a-419ca58ba7ac',
    [string]$ResourceGroupName = 'rg-infra-winmig-apac-v-chengzhiz-poc',
    [string]$VmName = 'afshpqipi42iyfdsq',
    [string]$StorageAccountName = 'afspqipi42iyfdsq',
    [string]$FileShareName = 'syncpqipi42iyfdsq',
    [string]$StorageSyncServiceName = 'afsspqipi42iyfdsq',
    [string]$SyncGroupName = 'afsgpqipi42iyfdsq',
    [switch]$KeepVmRunning
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$hostSetupPath = Join-Path $PSScriptRoot 'Initialize-FileSyncHost.ps1'
$experimentPath = Join-Path $PSScriptRoot 'Run-NestedAfsThrottleExperiment.ps1'
$diagnosticsPath = Join-Path $repoRoot 'diagnostics'

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & az @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-VmPowerState {
    param([Parameter(Mandatory)][string]$Name)

    $state = Invoke-AzCli -Arguments @(
        'vm', 'get-instance-view',
        '--resource-group', $ResourceGroupName,
        '--name', $Name,
        '--subscription', $SubscriptionId,
        '--query', "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]",
        '--output', 'tsv'
    )
    return ($state -join '').Trim()
}

function Wait-ForVmRunning {
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    do {
        if ((Get-VmPowerState -Name $VmName) -eq 'VM running') {
            return
        }
        Start-Sleep -Seconds 15
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "VM '$VmName' did not reach running state within 20 minutes."
}

function Invoke-RemoteScript {
    param([Parameter(Mandatory)][string]$Path)

    $result = Invoke-AzCli -Arguments @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $ResourceGroupName,
        '--name', $VmName,
        '--subscription', $SubscriptionId,
        '--command-id', 'RunPowerShellScript',
        '--scripts', "@$Path",
        '--output', 'json'
    )
    $response = ($result -join [Environment]::NewLine) | ConvertFrom-Json
    $messages = @($response.value | ForEach-Object message | Where-Object { $_ })
    $text = $messages -join [Environment]::NewLine
    if (@($response.value | Where-Object code -Match '/failed$').Count) {
        throw "Azure Run Command failed: $text"
    }
    Write-Host $text
    return $text
}

if (-not (Test-Path -LiteralPath $hostSetupPath) -or -not (Test-Path -LiteralPath $experimentPath)) {
    throw 'The host setup or experiment script is missing.'
}

$account = (& az account show --query id --output tsv).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not authenticated. Sign in to tenant '$TenantId' and subscription '$SubscriptionId'."
}
if ($account -ne $SubscriptionId) {
    [void](Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId))
}

$syncServiceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.StorageSync/storageSyncServices/$StorageSyncServiceName"
$cloudEndpointsJson = Invoke-AzCli -Arguments @(
    'rest', '--method', 'get',
    '--url', "https://management.azure.com$syncServiceId/syncGroups/$SyncGroupName/cloudEndpoints?api-version=2022-09-01",
    '--output', 'json'
)
$cloudEndpoints = (($cloudEndpointsJson -join [Environment]::NewLine) | ConvertFrom-Json).value
$cloudEndpoint = $cloudEndpoints | Where-Object {
    $_.properties.azureFileShareName -ieq $FileShareName -and
    $_.properties.provisioningState -eq 'Succeeded'
} | Select-Object -First 1
if (-not $cloudEndpoint) {
    throw "No succeeded cloud endpoint was found for share '$FileShareName'; server setup was not started."
}

$vmJson = Invoke-AzCli -Arguments @(
    'vm', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', $VmName,
    '--subscription', $SubscriptionId,
    '--query', '{id:id,principalId:identity.principalId}',
    '--output', 'json'
)
$vm = ($vmJson -join [Environment]::NewLine) | ConvertFrom-Json
if (-not $vm.principalId) {
    throw "VM '$VmName' has no system-assigned managed identity."
}

$shareScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName/fileServices/default/shares/$FileShareName"
$existingRole = Invoke-AzCli -Arguments @(
    'role', 'assignment', 'list',
    '--assignee-object-id', $vm.principalId,
    '--scope', $shareScope,
    '--query', "[?roleDefinitionName=='Storage File Data Privileged Contributor'].id | [0]",
    '--output', 'tsv'
)
if (-not ($existingRole -join '').Trim()) {
    Write-Host 'Granting the VM identity Storage File Data Privileged Contributor on the lab share.'
    [void](Invoke-AzCli -Arguments @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $vm.principalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', 'Storage File Data Privileged Contributor',
        '--scope', $shareScope,
        '--subscription', $SubscriptionId,
        '--output', 'none'
    ))
    Start-Sleep -Seconds 30
}

if ((Get-VmPowerState -Name $VmName) -ne 'VM running') {
    Write-Host "Starting VM '$VmName'..."
    [void](Invoke-AzCli -Arguments @('vm', 'start', '--resource-group', $ResourceGroupName, '--name', $VmName, '--subscription', $SubscriptionId, '--no-wait'))
    Wait-ForVmRunning
}

$hostSetupOutput = Invoke-RemoteScript -Path $hostSetupPath
if ($hostSetupOutput -match 'AFSLAB_AGENT_REBOOT_REQUIRED=true') {
    Write-Host 'Restarting the VM to finish agent installation...'
    [void](Invoke-AzCli -Arguments @('vm', 'restart', '--resource-group', $ResourceGroupName, '--name', $VmName, '--subscription', $SubscriptionId, '--no-wait'))
    Wait-ForVmRunning
    $hostSetupOutput = Invoke-RemoteScript -Path $hostSetupPath
}
if ($hostSetupOutput -notmatch 'AFSLAB_HOST_SETUP=') {
    throw 'Host registration and server-endpoint setup did not return a success marker.'
}
$setupMatch = [regex]::Match($hostSetupOutput, 'AFSLAB_HOST_SETUP=(\{[^\r\n]+\})')
if (-not $setupMatch.Success) {
    throw 'The host setup result could not be parsed.'
}
$hostSetup = $setupMatch.Groups[1].Value | ConvertFrom-Json
if (-not $hostSetup.ServerResourceId -or -not $hostSetup.ServerEndpointPath) {
    throw 'The host setup result is missing the registered server ID or endpoint path.'
}

$serverEndpointsUri = "https://management.azure.com$syncServiceId/syncGroups/$SyncGroupName/serverEndpoints?api-version=2022-09-01"
$serverEndpoint = $null
$endpointDeadline = [DateTime]::UtcNow.AddMinutes(20)
do {
    $endpointJson = Invoke-AzCli -Arguments @('rest', '--method', 'get', '--url', $serverEndpointsUri, '--output', 'json')
    $endpointCollection = ($endpointJson -join [Environment]::NewLine) | ConvertFrom-Json
    $serverEndpoint = @($endpointCollection.value | Where-Object {
        $_.properties.serverResourceId -ieq $hostSetup.ServerResourceId -and
        $_.properties.serverLocalPath -ieq $hostSetup.ServerEndpointPath
    }) | Select-Object -First 1
    if ($serverEndpoint -and $serverEndpoint.properties.provisioningState -in @('Succeeded', 'Failed', 'Canceled')) {
        break
    }
    Start-Sleep -Seconds 30
} while ([DateTime]::UtcNow -lt $endpointDeadline)

if (-not $serverEndpoint -or $serverEndpoint.properties.provisioningState -ne 'Succeeded') {
    $state = if ($serverEndpoint) { $serverEndpoint.properties.provisioningState } else { 'not found' }
    throw "Server endpoint did not reach Succeeded (state '$state'); experiment was not run."
}

Write-Host "Server endpoint '$($serverEndpoint.name)' for '$($hostSetup.ServerEndpointPath)' is Succeeded. Starting the 500-Kbps throttle experiment."
$experimentOutput = Invoke-RemoteScript -Path $experimentPath
if ($experimentOutput -notmatch 'AFSLAB_EXPERIMENT_STATUS=SUCCESS') {
    throw 'The throttle experiment did not report success; the VM is left running for diagnosis.'
}

New-Item -Path $diagnosticsPath -ItemType Directory -Force | Out-Null
$resultsPath = Join-Path $diagnosticsPath 'latest-host-throttle-experiment.txt'
[System.IO.File]::WriteAllText($resultsPath, $experimentOutput, [System.Text.UTF8Encoding]::new($false))
Write-Host "Experiment output saved to $resultsPath"

if (-not $KeepVmRunning) {
    [void](Invoke-AzCli -Arguments @('vm', 'deallocate', '--resource-group', $ResourceGroupName, '--name', $VmName, '--subscription', $SubscriptionId, '--no-wait'))
    Write-Host 'The host is deallocating to limit compute charges.'
}

Write-Host "Cloud endpoint: $($cloudEndpoint.id); server endpoint: $($serverEndpoint.id); state: Succeeded."