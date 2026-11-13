[CmdletBinding()]
param(
    [string]$SubscriptionId = '8d6bd1eb-ae31-4f2c-856a-0f8e47115c4b',
    [string]$TenantId = '16b3c013-d300-468d-ac64-7eda0820b6d3',
    [string]$ResourceGroupName = 'rgafslab2611',
    [int]$LimitKbps = 5000,
    [int]$FileSizeMiB = 64,
    [switch]$SkipSimulation,
    [switch]$PreviewOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repoRoot 'infra\main.bicep'
$parametersPath = Join-Path $repoRoot 'infra\main.parameters.json'
$bootstrapPath = Join-Path $PSScriptRoot 'Initialize-AfsLabServer.ps1'
$experimentPath = Join-Path $PSScriptRoot 'Run-AfsThrottleExperiment.ps1'
$deploymentName = 'afs-throttle-lab-stage4'

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

function Get-RunCommandOutput {
    param(
        [Parameter(Mandatory)]
        [string[]]$CommandOutput,

        [Parameter(Mandatory)]
        [string]$SuccessMarker,

        [Parameter(Mandatory)]
        [string]$StageName
    )

    $result = ($CommandOutput -join [Environment]::NewLine) | ConvertFrom-Json
    $failedStatus = @($result.value | Where-Object { $_.code -match '(?i)failed' })
    if ($failedStatus.Count) {
        throw "$StageName Run Command failed: $($failedStatus.message -join [Environment]::NewLine)"
    }

    $messages = @($result.value | Where-Object { $_.code -like 'ComponentStatus/StdOut*' } | ForEach-Object message)
    $messageText = $messages -join [Environment]::NewLine
    if ($messageText -notmatch [regex]::Escape($SuccessMarker)) {
        $stderr = @($result.value | Where-Object { $_.code -like 'ComponentStatus/StdErr*' } | ForEach-Object message)
        throw "$StageName did not return its success marker. $($stderr -join [Environment]::NewLine)"
    }

    return $messages
}

function Get-EndpointProperty {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$Query
    )

    try {
        $value = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $ResourceId, '--query', $Query, '--output', 'tsv')
        return ($value -join [Environment]::NewLine).Trim()
    }
    catch {
        if ($_.Exception.Message -match '(?i)\b(MgmtNotFound|ResourceNotFound)\b') {
            return $null
        }
        throw
    }
}

function Set-EndpointResource {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Body
    )

    $bodyPath = Join-Path $env:TEMP "afs-endpoint-$([guid]::NewGuid().ToString('N')).json"
    try {
        [System.IO.File]::WriteAllText($bodyPath, $Body, [System.Text.UTF8Encoding]::new($false))
        [void](Invoke-AzCli -Arguments @(
            'rest', '--method', 'put', '--uri', $Uri,
            '--body', "@$bodyPath",
            '--headers', 'Content-Type=application/json',
            '--output', 'none'
        ))
    }
    finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-EndpointWriteFailure {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$StartedAt
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & az monitor activity-log list --resource-id $ResourceId `
            --subscription $SubscriptionId --start-time $StartedAt --output json --only-show-errors 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        return $null
    }

    $events = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    $writeEvents = @($events | Where-Object { $_.operationName.value -match '(?i)/write$' })
    $startedOperations = @($writeEvents | Where-Object { $_.status.value -in @('Started', 'Accepted') } | ForEach-Object correlationId)
    $failure = $writeEvents | Where-Object {
        $_.status.value -eq 'Failed' -and $_.correlationId -in $startedOperations
    } | Sort-Object eventTimestamp -Descending | Select-Object -First 1
    if ($failure) {
        return $failure.properties.statusMessage
    }
    return $null
}

function Get-EndpointWorkflowFailure {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$SyncServiceId
    )

    try {
        $workflowId = Get-EndpointProperty -ResourceId $ResourceId -Query 'properties.lastWorkflowId'
        if (-not $workflowId) {
            return $null
        }
        $workflowName = ($workflowId -split '/')[-1]
        $uri = "https://management.azure.com$SyncServiceId/workflows/$workflowName`?api-version=2022-09-01"
        $output = Invoke-AzCli -Arguments @('rest', '--method', 'get', '--uri', $uri, '--output', 'json')
        $workflow = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        $steps = $workflow.properties.steps | ConvertFrom-Json
        $failedStep = $steps | Where-Object status -eq 'Failed' | Select-Object -First 1
        if ($failedStep.error.error) {
            return "$($failedStep.error.error.code): $($failedStep.error.error.message)"
        }
    }
    catch {
        return $null
    }
    return $null
}

function New-TransientVmPassword {
    $randomBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($randomBytes)
        $randomPart = [Convert]::ToBase64String($randomBytes).TrimEnd('=').Replace('+', 'A').Replace('/', 'B')
        return "Q7!$randomPart"
    }
    finally {
        $rng.Dispose()
        [Array]::Clear($randomBytes, 0, $randomBytes.Length)
    }
}

$activeSubscription = (& az account show --query id --output tsv).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not signed in. Run 'az login --tenant $TenantId' and select $SubscriptionId."
}
if ($activeSubscription -ne $SubscriptionId) {
    [void](Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId))
}

if (-not (Test-Path -LiteralPath $templatePath) -or -not (Test-Path -LiteralPath $parametersPath)) {
    throw 'The Bicep template or parameter file is missing.'
}

if (-not $PreviewOnly) {
    $previousOutputs = $null
    $previousDeploymentFound = $true
    try {
        $previousOutputsJson = Invoke-AzCli -Arguments @(
            'deployment', 'group', 'show',
            '--name', $deploymentName,
            '--resource-group', $ResourceGroupName,
            '--subscription', $SubscriptionId,
            '--query', 'properties.outputs',
            '--output', 'json'
        )
        $previousOutputs = ($previousOutputsJson -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)\bDeploymentNotFound\b') {
            throw
        }
        $previousDeploymentFound = $false
    }

    if ($previousDeploymentFound) {
        $previousServiceId = $previousOutputs.syncServiceId.value
        $previousGroupName = $previousOutputs.syncGroupName.value
        $previousEndpointName = $previousOutputs.cloudEndpointName.value
        if (-not $previousServiceId -or -not $previousGroupName -or -not $previousEndpointName) {
            throw 'The previous deployment lacks cloud endpoint identifiers; inspect it before redeployment.'
        }
        $previousEndpointId = "$previousServiceId/syncGroups/$previousGroupName/cloudEndpoints/$previousEndpointName"
        $previousEndpointState = Get-EndpointProperty -ResourceId $previousEndpointId -Query 'properties.provisioningState'
        if ($previousEndpointState -in @('Failed', 'Canceled')) {
            $details = Get-EndpointWorkflowFailure -ResourceId $previousEndpointId -SyncServiceId $previousServiceId
            throw "Existing cloud endpoint is '$previousEndpointState'; no deployment or VM start was attempted. $details"
        }
    }
}

[void](Invoke-AzCli -Arguments @('bicep', 'build', '--file', $templatePath, '--outfile', (Join-Path $env:TEMP 'afs-throttle-lab.json')))
$vmPassword = New-TransientVmPassword
$temporaryParametersPath = Join-Path $env:TEMP "afs-lab-$([guid]::NewGuid().ToString('N')).parameters.json"
$parameterData = Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json
$parameterData.parameters | Add-Member `
    -MemberType NoteProperty `
    -Name vmAdminPassword `
    -Value ([pscustomobject]@{ value = $vmPassword })
[System.IO.File]::WriteAllText(
    $temporaryParametersPath,
    ($parameterData | ConvertTo-Json -Depth 10),
    [System.Text.UTF8Encoding]::new($false)
)

try {
    Write-Host 'Running ARM what-if preview...'
    $whatIfOutput = Invoke-AzCli -Arguments @(
        'deployment', 'group', 'what-if',
        '--name', "$deploymentName-preview",
        '--resource-group', $ResourceGroupName,
        '--template-file', $templatePath,
        '--parameters', "@$temporaryParametersPath",
        '--subscription', $SubscriptionId,
        '--no-pretty-print'
    )
    $whatIfOutput | ForEach-Object { Write-Host $_ }

    if ($PreviewOnly) {
        Write-Host 'Preview completed; no resources were deployed.'
        return
    }

    Write-Host 'Deploying the isolated lab...'
    $deploymentArguments = @(
        'deployment', 'group', 'create',
        '--name', $deploymentName,
        '--resource-group', $ResourceGroupName,
        '--template-file', $templatePath,
        '--parameters', "@$temporaryParametersPath",
        '--subscription', $SubscriptionId,
        '--query', 'properties.provisioningState',
        '--output', 'tsv'
    )
    $maxAttempts = 8
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            [void](Invoke-AzCli -Arguments $deploymentArguments)
            break
        }
        catch {
            if ($attempt -eq $maxAttempts -or $_.Exception.Message -notmatch '(?i)MgmtFileShareAuthorizationFailed|failed to check azure file share existence') {
                throw
            }
            Write-Warning "Waiting for Storage Sync role assignments to propagate (attempt $attempt of $maxAttempts)."
            Start-Sleep -Seconds 60
        }
    }
}
catch {
    $labVmName = (& az vm list --resource-group $ResourceGroupName --subscription $SubscriptionId --query "[?tags.purpose=='AzureFileSyncNetworkLimitLab'].name | [0]" --output tsv 2>$null).Trim()
    if ($LASTEXITCODE -eq 0 -and $labVmName) {
        [void](& az vm deallocate --resource-group $ResourceGroupName --name $labVmName --subscription $SubscriptionId --no-wait 2>&1)
    }
    throw
}
finally {
    Remove-Item -LiteralPath $temporaryParametersPath -Force -ErrorAction SilentlyContinue
    $vmPassword = $null
}

$outputsJson = Invoke-AzCli -Arguments @(
    'deployment', 'group', 'show',
    '--name', $deploymentName,
    '--resource-group', $ResourceGroupName,
    '--subscription', $SubscriptionId,
    '--query', 'properties.outputs',
    '--output', 'json'
)
$outputs = ($outputsJson -join [Environment]::NewLine) | ConvertFrom-Json
$vmName = $outputs.vmName.value
$syncServiceName = $outputs.syncServiceName.value
$syncGroupName = $outputs.syncGroupName.value
$cloudEndpointName = $outputs.cloudEndpointName.value
$endpointName = $outputs.serverEndpointName.value
$localPath = $outputs.localPath.value
$storageAccountId = $outputs.storageAccountId.value
$storageAccountName = $outputs.storageAccountName.value
$fileShareName = $outputs.fileShareName.value

$cloudEndpointId = "$($outputs.syncServiceId.value)/syncGroups/$syncGroupName/cloudEndpoints/$cloudEndpointName"
$existingCloudEndpointState = Get-EndpointProperty -ResourceId $cloudEndpointId -Query 'properties.provisioningState'
if ($existingCloudEndpointState -in @('Failed', 'Canceled')) {
    $details = Get-EndpointWorkflowFailure -ResourceId $cloudEndpointId -SyncServiceId $outputs.syncServiceId.value
    throw "Existing cloud endpoint is '$existingCloudEndpointState'; resolve its cause and review the endpoint before retrying. $details"
}

try {
    [void](Invoke-AzCli -Arguments @('vm', 'start', '--resource-group', $ResourceGroupName, '--name', $vmName, '--subscription', $SubscriptionId))

    Write-Host 'Installing and registering Azure File Sync on the lab VM...'
    $bootstrapOutput = Invoke-AzCli -Arguments @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $ResourceGroupName,
        '--name', $vmName,
        '--command-id', 'RunPowerShellScript',
        '--scripts', "@$bootstrapPath",
        '--parameters',
        "ResourceGroupName=$ResourceGroupName",
        "SubscriptionId=$SubscriptionId",
        "TenantId=$TenantId",
        "StorageSyncServiceName=$syncServiceName",
        "LocalPath=$localPath",
        '--subscription', $SubscriptionId,
        '--output', 'json'
    )
    $bootstrapMessages = Get-RunCommandOutput `
        -CommandOutput $bootstrapOutput `
        -SuccessMarker 'AFSLAB_BOOTSTRAP_STATUS=SUCCESS' `
        -StageName 'File Sync bootstrap'
    $bootstrapMessages | ForEach-Object { Write-Host $_ }
    $bootstrapResultLine = ($bootstrapMessages -join [Environment]::NewLine) -split '\r?\n' |
        Where-Object { $_ -like 'AFSLAB_BOOTSTRAP_RESULT=*' } |
        Select-Object -Last 1
    if (-not $bootstrapResultLine) {
        throw 'File Sync bootstrap did not return the registered-server ID and data path.'
    }
    $bootstrapResult = ($bootstrapResultLine -replace '^AFSLAB_BOOTSTRAP_RESULT=', '') | ConvertFrom-Json
    $localPath = $bootstrapResult.LocalPath
    $registeredServerResourceId = $bootstrapResult.RegisteredServerResourceId
    if (-not $localPath -or -not $registeredServerResourceId -or -not $bootstrapResult.ManagedIdentityEnabled) {
        throw 'File Sync bootstrap returned incomplete registration or managed identity details.'
    }

    $syncServiceState = (& az resource show --ids $outputs.syncServiceId.value --query 'properties.useIdentity' --output tsv).Trim()
    if ($LASTEXITCODE -ne 0 -or $syncServiceState -ne 'true') {
        throw 'Azure File Sync managed identity is not enabled on the Storage Sync Service.'
    }

    $cloudEndpointUri = "https://management.azure.com$cloudEndpointId`?api-version=2022-09-01"
    $cloudEndpointBody = @{
        name = $cloudEndpointName
        properties = @{
            storageAccountResourceId = $storageAccountId
            azureFileShareName = $fileShareName
            storageAccountTenantId = $TenantId
            friendlyName = 'Azure File Sync throttle lab share'
        }
    } | ConvertTo-Json -Depth 8 -Compress

    $existingCloudEndpoint = Get-EndpointProperty -ResourceId $cloudEndpointId -Query 'id'
    $cloudEndpointStartedAt = $null
    if (-not $existingCloudEndpoint) {
        $cloudEndpointStartedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-EndpointResource -Uri $cloudEndpointUri -Body $cloudEndpointBody
    }

    $cloudEndpointState = ''
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $cloudEndpointState = Get-EndpointProperty -ResourceId $cloudEndpointId -Query 'properties.provisioningState'
        if ($cloudEndpointState -eq 'Succeeded') {
            break
        }
        if ($cloudEndpointState -in @('Failed', 'Canceled')) {
            $details = Get-EndpointWorkflowFailure -ResourceId $cloudEndpointId -SyncServiceId $outputs.syncServiceId.value
            throw "Cloud endpoint provisioning returned state '$cloudEndpointState'. $details"
        }
        if ($cloudEndpointStartedAt) {
            $failure = Get-EndpointWriteFailure -ResourceId $cloudEndpointId -StartedAt $cloudEndpointStartedAt
            if ($failure) {
                throw "Cloud endpoint provisioning failed: $failure"
            }
        }
        Start-Sleep -Seconds 30
    }
    if ($cloudEndpointState -ne 'Succeeded') {
        throw "Cloud endpoint did not reach Succeeded state; last state was '$cloudEndpointState'."
    }

    $serverEndpointId = "$($outputs.syncServiceId.value)/syncGroups/$syncGroupName/serverEndpoints/$endpointName"
    $serverEndpointUri = "https://management.azure.com$serverEndpointId`?api-version=2022-09-01"
    $serverEndpointBody = @{
        name = $endpointName
        properties = @{
            serverResourceId = $registeredServerResourceId
            serverLocalPath = $localPath
            cloudTiering = 'off'
            initialDownloadPolicy = 'AvoidTieredFiles'
            initialUploadPolicy = 'Merge'
            friendlyName = 'Azure File Sync throttle lab server endpoint'
        }
    } | ConvertTo-Json -Depth 8 -Compress

    $existingServerEndpoint = Get-EndpointProperty -ResourceId $serverEndpointId -Query 'id'
    $serverEndpointStartedAt = $null
    if (-not $existingServerEndpoint) {
        $serverEndpointStartedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-EndpointResource -Uri $serverEndpointUri -Body $serverEndpointBody
    }

    $serverEndpointState = ''
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $serverEndpointState = Get-EndpointProperty -ResourceId $serverEndpointId -Query 'properties.provisioningState'
        if ($serverEndpointState -eq 'Succeeded') {
            break
        }
        if ($serverEndpointState -in @('Failed', 'Canceled')) {
            $details = Get-EndpointWorkflowFailure -ResourceId $serverEndpointId -SyncServiceId $outputs.syncServiceId.value
            throw "Server endpoint provisioning returned state '$serverEndpointState'. $details"
        }
        if ($serverEndpointStartedAt) {
            $failure = Get-EndpointWriteFailure -ResourceId $serverEndpointId -StartedAt $serverEndpointStartedAt
            if ($failure) {
                throw "Server endpoint provisioning failed: $failure"
            }
        }
        Start-Sleep -Seconds 30
    }
    if ($serverEndpointState -ne 'Succeeded') {
        throw "Server endpoint did not reach Succeeded state; last state was '$serverEndpointState'."
    }

    if (-not $SkipSimulation) {
        Write-Host 'Running baseline, 5 Mbps throttle, and recovery phases...'
        $experimentOutput = Invoke-AzCli -Arguments @(
            'vm', 'run-command', 'invoke',
            '--resource-group', $ResourceGroupName,
            '--name', $vmName,
            '--command-id', 'RunPowerShellScript',
            '--scripts', "@$experimentPath",
            '--parameters',
            "LimitKbps=$LimitKbps",
            "FileSizeMiB=$FileSizeMiB",
            'SamplesPerPhase=60',
            "LocalPath=$localPath",
            '--subscription', $SubscriptionId,
            '--output', 'json'
        )
        $experimentMessages = Get-RunCommandOutput `
            -CommandOutput $experimentOutput `
            -SuccessMarker 'AFSLAB_EXPERIMENT_STATUS=SUCCESS' `
            -StageName 'Throttle experiment'
        $experimentMessages | ForEach-Object { Write-Host $_ }
    }
}
finally {
    Write-Host 'Deallocating the lab VM to stop compute charges...'
    [void](Invoke-AzCli -Arguments @('vm', 'deallocate', '--resource-group', $ResourceGroupName, '--name', $vmName, '--subscription', $SubscriptionId, '--no-wait'))
}

Write-Host "Lab resources and experiment evidence are in resource group '$ResourceGroupName'. The VM is deallocated; storage and outbound-network resources remain until the group is deleted."