[CmdletBinding()]
param(
    [string]$SubscriptionId = '95642268-5116-484d-9b88-7dfce8c20ce4',
    [string]$TenantId = '0e478cd4-3e52-496d-ac3a-419ca58ba7ac',
        [string]$ResourceGroupName = 'rg-infra-winmig-apac-v-chengzhiz-poc',
    [string]$Location = 'westus2',
    [int]$EndpointWaitMinutes = 20,
    [switch]$SkipHost,
    [switch]$SkipCloudEndpointCreation,
    [switch]$PreviewOnly,
    [switch]$SupportConfirmedRetry
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repoRoot 'infra\main.bicep'
$hostTemplatePath = Join-Path $repoRoot 'infra\host.bicep'
$parametersPath = Join-Path $repoRoot 'infra\main.parameters.json'
$hostBootstrapPath = Join-Path $PSScriptRoot 'Initialize-HyperVHost.ps1'
$nestedProvisionPath = Join-Path $PSScriptRoot 'Create-NestedServer.ps1'
$cloudDeploymentName = 'afs-nested-cloud'
$retryCloudDeploymentName = 'afs-nested-cloud-identity-retry'
$hostDeploymentName = 'afs-nested-host'

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

function New-TemporaryParameters {
    param(
        [Parameter(Mandatory)][bool]$DeployHost,
        [Parameter(Mandatory)][string]$AdminPassword,
        [Parameter(Mandatory)][string]$RdpSource
    )

    $data = Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json
    $data.parameters.location.value = $Location
    $data.parameters.deployHost.value = $DeployHost
    $data.parameters.rdpSourceAddressPrefix.value = $RdpSource
    $data.parameters | Add-Member -MemberType NoteProperty -Name vmAdminPassword -Value ([pscustomobject]@{ value = $AdminPassword }) -Force
    $path = Join-Path $env:TEMP "afs-nested-$([guid]::NewGuid().ToString('N')).parameters.json"
    [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    return $path
}

function New-TemporaryHostParameters {
    param([Parameter(Mandatory)][string]$AdminPassword)

    $base = Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json
    $data = [ordered]@{
        '$schema' = $base.'$schema'
        contentVersion = $base.contentVersion
        parameters = [ordered]@{
            location = $base.parameters.location
            environmentName = $base.parameters.environmentName
            vmSize = $base.parameters.vmSize
            vmAdminUsername = $base.parameters.vmAdminUsername
            vmAdminPassword = [pscustomobject]@{ value = $AdminPassword }
        }
    }
    $path = Join-Path $env:TEMP "afs-nested-host-$([guid]::NewGuid().ToString('N')).parameters.json"
    [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-DeploymentStage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ParametersFile,
        [Parameter(Mandatory)][string]$TemplateFile,
        [switch]$PreviewOnly
    )

    Write-Host "Running what-if for $Name..."
    $preview = Invoke-AzCli -Arguments @(
        'deployment', 'group', 'what-if',
        '--name', "$Name-preview",
        '--resource-group', $ResourceGroupName,
        '--template-file', $TemplateFile,
        '--parameters', "@$ParametersFile",
        '--subscription', $SubscriptionId,
        '--no-pretty-print'
    )
    $preview | ForEach-Object { Write-Host $_ }
    if ($PreviewOnly) {
        return
    }

    Write-Host "Deploying $Name..."
    [void](Invoke-AzCli -Arguments @(
        'deployment', 'group', 'create',
        '--name', $Name,
        '--resource-group', $ResourceGroupName,
        '--template-file', $TemplateFile,
        '--parameters', "@$ParametersFile",
        '--subscription', $SubscriptionId,
        '--query', 'properties.provisioningState',
        '--output', 'tsv'
    ))
}

function Get-DeploymentOutputs {
    param([Parameter(Mandatory)][string]$Name)

    $json = Invoke-AzCli -Arguments @(
        'deployment', 'group', 'show',
        '--name', $Name,
        '--resource-group', $ResourceGroupName,
        '--subscription', $SubscriptionId,
        '--query', 'properties.outputs',
        '--output', 'json'
    )
    return (($json -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Wait-ForVmRunning {
    param([Parameter(Mandatory)][string]$VmName)

    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    do {
        try {
            $state = Invoke-AzCli -Arguments @(
                'vm', 'get-instance-view',
                '--resource-group', $ResourceGroupName,
                '--name', $VmName,
                '--subscription', $SubscriptionId,
                '--query', "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]",
                '--output', 'tsv'
            )
            if (($state -join '').Trim() -eq 'VM running') {
                return
            }
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
        Start-Sleep -Seconds 15
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "VM '$VmName' did not reach running state within 15 minutes."
}

function Get-CloudEndpointState {
    param([Parameter(Mandatory)][string]$ResourceId)

    try {
        $state = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $ResourceId, '--api-version', '2022-09-01', '--query', 'properties.provisioningState', '--output', 'tsv')
        return ($state -join [Environment]::NewLine).Trim()
    }
    catch {
        if ($_.Exception.Message -match '(?i)\b(MgmtNotFound|ResourceNotFound)\b|could not be found|does not exist') {
            return $null
        }
        throw
    }
}

function Get-CloudEndpointForShare {
    param(
        [Parameter(Mandatory)][string]$SyncServiceId,
        [Parameter(Mandatory)][string]$SyncGroupName,
        [Parameter(Mandatory)][string]$StorageAccountId,
        [Parameter(Mandatory)][string]$FileShareName
    )

    $collectionUri = "https://management.azure.com$SyncServiceId/syncGroups/$SyncGroupName/cloudEndpoints`?api-version=2022-09-01"
    $json = Invoke-AzCli -Arguments @('rest', '--method', 'get', '--uri', $collectionUri, '--output', 'json')
    $collection = ($json -join [Environment]::NewLine) | ConvertFrom-Json
    $matches = @($collection.value | Where-Object {
        $_.properties.azureFileShareName -ieq $FileShareName -and
        $_.properties.storageAccountResourceId -ieq $StorageAccountId
    })

    if ($matches.Count -gt 1) {
        throw "More than one cloud endpoint references file share '$FileShareName' in storage account '$StorageAccountId'; refusing to choose one."
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}

function Get-EndpointWriteFailures {
    param([Parameter(Mandatory)][string]$ResourceId)

    $diagnosticsDirectory = Join-Path $repoRoot 'diagnostics'
    $evidencePath = Join-Path $diagnosticsDirectory 'latest-cloud-endpoint-activity.json'
    if (Test-Path -LiteralPath $evidencePath) {
        $savedEvents = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
        if (@($savedEvents | Where-Object resourceId -eq $ResourceId).Count) {
            return @($savedEvents | Where-Object resourceId -eq $ResourceId)
        }
    }

    $startTime = [DateTime]::UtcNow.AddHours(-6).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $json = Invoke-AzCli -Arguments @(
        'monitor', 'activity-log', 'list',
        '--resource-id', $ResourceId,
        '--start-time', $startTime,
        '--subscription', $SubscriptionId,
        '--query', "[?ends_with(operationName.value, '/write') && status.value=='Failed'].{eventTimestamp:eventTimestamp,operation:operationName.value,status:status.value,correlationId:correlationId,operationId:operationId,resourceId:resourceId,statusMessage:properties.statusMessage}",
        '--output', 'json'
    )
    $jsonText = $json -join [Environment]::NewLine
    $jsonStart = $jsonText.IndexOf('[')
    if ($jsonStart -lt 0) {
        throw 'Azure CLI did not return JSON for the endpoint Activity Log query.'
    }
    $events = $jsonText.Substring($jsonStart) | ConvertFrom-Json
    return @($events | Sort-Object eventTimestamp -Descending)
}

function Assert-StorageAccountFileSyncAccess {
    param([Parameter(Mandatory)][string]$StorageAccountName)

    $accountJson = Invoke-AzCli -Arguments @(
        'storage', 'account', 'show',
        '--name', $StorageAccountName,
        '--resource-group', $ResourceGroupName,
        '--subscription', $SubscriptionId,
        '--query', '{publicNetworkAccess:publicNetworkAccess,allowSharedKeyAccess:allowSharedKeyAccess,defaultAction:networkRuleSet.defaultAction,bypass:networkRuleSet.bypass}',
        '--output', 'json'
    )
    $settings = ($accountJson -join [Environment]::NewLine) | ConvertFrom-Json
    if ($settings.publicNetworkAccess -ne 'Enabled' -or $settings.allowSharedKeyAccess -ne $true) {
        throw "Storage account '$StorageAccountName' is not configured for this public-endpoint File Sync lab (publicNetworkAccess='$($settings.publicNetworkAccess)', allowSharedKeyAccess='$($settings.allowSharedKeyAccess)', defaultAction='$($settings.defaultAction)', bypass='$($settings.bypass)'). No cloud endpoint request was sent. Review the effective storage policy with the subscription administrator."
    }
    return $settings
}

function Save-EndpointWriteFailure {
    param([Parameter(Mandatory)][object[]]$Events)

    $diagnosticsDirectory = Join-Path $repoRoot 'diagnostics'
    New-Item -Path $diagnosticsDirectory -ItemType Directory -Force | Out-Null
    $evidencePath = Join-Path $diagnosticsDirectory 'latest-cloud-endpoint-activity.json'
    $safeEvents = @($Events | ForEach-Object {
        [pscustomobject]@{
            eventTimestamp = $_.eventTimestamp
            operation = $_.operation
            status = $_.status
            correlationId = $_.correlationId
            operationId = $_.operationId
            resourceId = $_.resourceId
            statusMessage = $_.statusMessage
        }
    })
    [System.IO.File]::WriteAllText($evidencePath, ($safeEvents | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    return $evidencePath
}

function Write-CloudEndpointEvidence {
    param(
        [Parameter(Mandatory)][string]$EndpointId,
        [Parameter(Mandatory)][string]$SyncServiceId
    )

    $endpointJson = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $EndpointId, '--api-version', '2022-09-01', '--output', 'json')
    $endpoint = ($endpointJson -join [Environment]::NewLine) | ConvertFrom-Json
    $workflowId = $endpoint.properties.lastWorkflowId
    if (-not $workflowId) {
        Write-Host "Cloud endpoint state: $($endpoint.properties.provisioningState); workflow ID was not returned."
        return
    }

    $workflowName = ($workflowId -split '/')[-1]
    $workflowResourceId = "$SyncServiceId/workflows/$workflowName"
    $workflowJson = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $workflowResourceId, '--api-version', '2022-09-01', '--output', 'json')
    $workflow = ($workflowJson -join [Environment]::NewLine) | ConvertFrom-Json
    $diagnosticsDirectory = Join-Path $repoRoot 'diagnostics'
    New-Item -Path $diagnosticsDirectory -ItemType Directory -Force | Out-Null
    $evidencePath = Join-Path $diagnosticsDirectory 'latest-cloud-endpoint-workflow.json'
    [System.IO.File]::WriteAllText($evidencePath, ($workflow | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))

    Write-Host "Cloud endpoint state: $($endpoint.properties.provisioningState)"
    Write-Host "Workflow: $workflowName; status: $($workflow.properties.status); last step: $($workflow.properties.lastStepName)"
    Write-Host "Workflow evidence: $evidencePath"
}

$activeSubscription = (& az account show --query id --output tsv).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not signed in. Run 'az login --tenant $TenantId' and select $SubscriptionId."
}
if ($activeSubscription -ne $SubscriptionId) {
    [void](Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId))
}

if (-not (Test-Path -LiteralPath $templatePath) -or -not (Test-Path -LiteralPath $hostTemplatePath) -or -not (Test-Path -LiteralPath $parametersPath)) {
    throw 'A Bicep template or parameter file is missing.'
}

[void](Invoke-AzCli -Arguments @('bicep', 'build', '--file', $templatePath, '--outfile', (Join-Path $env:TEMP 'afs-nested-lab.json')))
[void](Invoke-AzCli -Arguments @('bicep', 'build', '--file', $hostTemplatePath, '--outfile', (Join-Path $env:TEMP 'afs-nested-host.json')))
$resourceGroupExists = (& az group exists --name $ResourceGroupName --subscription $SubscriptionId --output tsv).Trim()
if ($resourceGroupExists -ne 'true') {
    Write-Host "Creating isolated resource group $ResourceGroupName..."
    [void](Invoke-AzCli -Arguments @(
        'group', 'create',
        '--name', $ResourceGroupName,
        '--location', $Location,
        '--subscription', $SubscriptionId,
        '--tags',
        'Customer=KLN',
        'Purpose=AzureFileSyncNestedThrottleLab',
        'Region=APAC',
        'tower=Infra',
        'email-id=v-chengzhiz@microsoft.com',
        'Offering=Infra',
        '--output', 'none'
    ))
}
else {
    $locksJson = Invoke-AzCli -Arguments @(
        'lock', 'list',
        '--resource-group', $ResourceGroupName,
        '--subscription', $SubscriptionId,
        '--output', 'json'
    )
    $locks = @((($locksJson -join [Environment]::NewLine) | ConvertFrom-Json))
    $readOnlyLocks = @($locks | Where-Object level -eq 'ReadOnly')
    if ($readOnlyLocks.Count) {
        $lockNames = ($readOnlyLocks | ForEach-Object name) -join ', '
        throw "Resource group '$ResourceGroupName' has a ReadOnly lock ($lockNames); no deployment was attempted. Have the lock owner provide an approved deployment scope or unlock it."
    }
}

$deploymentRecordsJson = Invoke-AzCli -Arguments @(
    'deployment', 'group', 'list',
    '--resource-group', $ResourceGroupName,
    '--subscription', $SubscriptionId,
    '--query', "[?name=='$cloudDeploymentName' || name=='$retryCloudDeploymentName'].{name:name,state:properties.provisioningState}",
    '--output', 'json'
)
$deploymentRecords = @((($deploymentRecordsJson -join [Environment]::NewLine) | ConvertFrom-Json))
if ($null -eq $deploymentRecords) {
    throw 'Could not inspect the previous cloud-only deployment; refusing to deploy blindly.'
}

$cloudOutputs = $null
$primaryRecord = $deploymentRecords | Where-Object name -eq $cloudDeploymentName | Select-Object -First 1
$retryRecord = $deploymentRecords | Where-Object name -eq $retryCloudDeploymentName | Select-Object -First 1
$useExistingCloudDeployment = $false

if ($retryRecord) {
    if ($retryRecord.state -ne 'Succeeded') {
        throw "The one allowed identity-conflict retry deployment is '$($retryRecord.state)'; no further retry will be attempted."
    }
    $cloudDeploymentName = $retryCloudDeploymentName
    $useExistingCloudDeployment = $true
}
elseif ($primaryRecord -and $primaryRecord.state -eq 'Succeeded') {
    $useExistingCloudDeployment = $true
}
elseif ($primaryRecord -and $primaryRecord.state -eq 'Failed') {
    $failedOperationsJson = Invoke-AzCli -Arguments @(
        'deployment', 'operation', 'group', 'list',
        '--resource-group', $ResourceGroupName,
        '--name', $cloudDeploymentName,
        '--subscription', $SubscriptionId,
        '--output', 'json'
    )
    $failedOperationsText = $failedOperationsJson -join [Environment]::NewLine
    if ($failedOperationsText -notmatch '(?is)FailedIdentityOperation.*pending delete') {
        throw 'The previous cloud deployment failed for a reason other than the known transient identity conflict; inspect it before proceeding.'
    }
    Write-Warning 'The previous cloud deployment hit the Azure Storage Sync pending-delete identity conflict. One controlled retry will use a distinct ARM deployment name.'
    $cloudDeploymentName = $retryCloudDeploymentName
}
elseif ($primaryRecord) {
    throw "The previous cloud deployment is '$($primaryRecord.state)'; refusing to overlap deployments."
}

if ($useExistingCloudDeployment) {
    $cloudOutputs = Get-DeploymentOutputs -Name $cloudDeploymentName
    $null = Assert-StorageAccountFileSyncAccess -StorageAccountName $cloudOutputs.storageAccountName.value
    $existingEndpoint = Get-CloudEndpointForShare `
        -SyncServiceId $cloudOutputs.syncServiceId.value `
        -SyncGroupName $cloudOutputs.syncGroupName.value `
        -StorageAccountId $cloudOutputs.storageAccountId.value `
        -FileShareName $cloudOutputs.fileShareName.value

    if ($existingEndpoint) {
        $existingEndpointId = $existingEndpoint.id
        $existingEndpointState = Get-CloudEndpointState -ResourceId $existingEndpointId
        if ($existingEndpointState -in @('Failed', 'Canceled')) {
            Write-CloudEndpointEvidence -EndpointId $existingEndpointId -SyncServiceId $cloudOutputs.syncServiceId.value
            throw "Existing endpoint is '$existingEndpointState'; no retry or host deployment was attempted. Resolve the failure before rerunning."
        }
        if ($existingEndpointState -ne 'Succeeded') {
            throw "Existing cloud endpoint '$existingEndpointId' is '$existingEndpointState', not Succeeded; host deployment was not attempted."
        }
        Write-Host "Reusing provisioned cloud endpoint '$existingEndpointId'; endpoint creation is skipped."
    }
    else {
        $existingEndpointId = "$($cloudOutputs.syncServiceId.value)/syncGroups/$($cloudOutputs.syncGroupName.value)/cloudEndpoints/$($cloudOutputs.cloudEndpointName.value)"
        if ($SkipCloudEndpointCreation) {
            throw "-SkipCloudEndpointCreation was specified, but no cloud endpoint matches storage account '$($cloudOutputs.storageAccountName.value)' and share '$($cloudOutputs.fileShareName.value)'. No endpoint request or host deployment was attempted."
        }
        $previousFailures = @(Get-EndpointWriteFailures -ResourceId $existingEndpointId)
        if ($previousFailures.Count -and -not $SupportConfirmedRetry) {
            $evidencePath = Save-EndpointWriteFailure -Events $previousFailures
            throw "A previous cloud endpoint write failed; no retry was attempted. Activity Log evidence: $evidencePath"
        }
        if ($previousFailures.Count) {
            Write-Warning 'Proceeding with an endpoint retry because -SupportConfirmedRetry was explicitly supplied.'
        }
        $useExistingCloudDeployment = $false
    }
}

if (-not $useExistingCloudDeployment) {
    $placeholderPassword = "N7!$([guid]::NewGuid().ToString('N'))z"
    $cloudParametersPath = New-TemporaryParameters -DeployHost $false -AdminPassword $placeholderPassword -RdpSource '127.0.0.1/32'
    try {
        Invoke-DeploymentStage -Name $cloudDeploymentName -ParametersFile $cloudParametersPath -TemplateFile $templatePath -PreviewOnly:$PreviewOnly
    }
    finally {
        $placeholderPassword = $null
        Remove-Item -LiteralPath $cloudParametersPath -Force -ErrorAction SilentlyContinue
    }
    if ($PreviewOnly) {
        Write-Host 'Cloud-only what-if completed; no Azure resources other than the dedicated resource group were deployed.'
        return
    }

    $cloudOutputs = Get-DeploymentOutputs -Name $cloudDeploymentName
    $syncServiceId = $cloudOutputs.syncServiceId.value
    $syncGroupName = $cloudOutputs.syncGroupName.value
    $cloudEndpointName = $cloudOutputs.cloudEndpointName.value
    $storageAccountId = $cloudOutputs.storageAccountId.value
    $storageAccountName = $cloudOutputs.storageAccountName.value
    $fileShareName = $cloudOutputs.fileShareName.value
    $null = Assert-StorageAccountFileSyncAccess -StorageAccountName $storageAccountName
    $cloudEndpoint = Get-CloudEndpointForShare `
        -SyncServiceId $syncServiceId `
        -SyncGroupName $syncGroupName `
        -StorageAccountId $storageAccountId `
        -FileShareName $fileShareName

    if ($cloudEndpoint) {
        $cloudEndpointId = $cloudEndpoint.id
        $endpointState = Get-CloudEndpointState -ResourceId $cloudEndpointId
        if ($endpointState -ne 'Succeeded') {
            if ($endpointState -in @('Failed', 'Canceled')) {
                Write-CloudEndpointEvidence -EndpointId $cloudEndpointId -SyncServiceId $syncServiceId
            }
            throw "Existing cloud endpoint '$cloudEndpointId' is '$endpointState', not Succeeded. No endpoint write or host deployment was attempted."
        }
        Write-Host "Reusing provisioned cloud endpoint '$cloudEndpointId'; endpoint creation is skipped."
    }
    else {
        $cloudEndpointId = "$syncServiceId/syncGroups/$syncGroupName/cloudEndpoints/$cloudEndpointName"
        if ($SkipCloudEndpointCreation) {
            throw "-SkipCloudEndpointCreation was specified, but no cloud endpoint matches storage account '$storageAccountName' and share '$fileShareName'. No endpoint request or host deployment was attempted."
        }
        $endpointState = Get-CloudEndpointState -ResourceId $cloudEndpointId
    }

    if (-not $cloudEndpoint -and -not $endpointState) {
        $previousFailures = @(Get-EndpointWriteFailures -ResourceId $cloudEndpointId)
        if ($previousFailures.Count -and -not $SupportConfirmedRetry) {
            $evidencePath = Save-EndpointWriteFailure -Events $previousFailures
            throw "A previous cloud endpoint write failed; no retry was attempted. Activity Log evidence: $evidencePath"
        }
        if ($previousFailures.Count) {
            Write-Warning 'Proceeding with an endpoint retry because -SupportConfirmedRetry was explicitly supplied.'
        }
        Write-Host 'Allowing the new managed-identity role assignments time to propagate before the first endpoint request.'
        Start-Sleep -Seconds 45
        $startedAt = [DateTime]::UtcNow.ToString('o')
        $requestBodyPath = Join-Path $env:TEMP "afs-cloud-endpoint-$([guid]::NewGuid().ToString('N')).json"
        $requestBody = @{
            properties = @{
                storageAccountResourceId = $storageAccountId
                azureFileShareName = $fileShareName
                storageAccountTenantId = $TenantId
            }
        } | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($requestBodyPath, $requestBody, [System.Text.UTF8Encoding]::new($false))
        $endpointUri = "https://management.azure.com$cloudEndpointId`?api-version=2022-09-01"
        try {
            [void](Invoke-AzCli -Arguments @('rest', '--method', 'put', '--uri', $endpointUri, '--body', "@$requestBodyPath", '--headers', 'Content-Type=application/json', '--output', 'none'))
        }
        catch {
            Write-Warning "Cloud endpoint request returned an error: $($_.Exception.Message)"
        }
        finally {
            Remove-Item -LiteralPath $requestBodyPath -Force -ErrorAction SilentlyContinue
        }

        $deadline = [DateTime]::UtcNow.AddMinutes($EndpointWaitMinutes)
        do {
            $endpointState = Get-CloudEndpointState -ResourceId $cloudEndpointId
            if ($endpointState -in @('Succeeded', 'Failed', 'Canceled')) {
                break
            }
            $writeFailures = Get-EndpointWriteFailures -ResourceId $cloudEndpointId
            if ($writeFailures.Count) {
                $evidencePath = Save-EndpointWriteFailure -Events $writeFailures
                throw "Cloud endpoint write failed according to the Activity Log. The Hyper-V host was not created. Evidence: $evidencePath"
            }
            Start-Sleep -Seconds 20
        } while ([DateTime]::UtcNow -lt $deadline)

        if ($endpointState -ne 'Succeeded') {
            if ($endpointState -in @('Failed', 'Canceled')) {
                Write-CloudEndpointEvidence -EndpointId $cloudEndpointId -SyncServiceId $syncServiceId
            }
            throw "Cloud endpoint did not reach Succeeded (state '$endpointState'). The Hyper-V host was not created. Do not retry until the failure is diagnosed."
        }
    }
}

if ($SkipHost) {
    Write-Host 'Cloud endpoint succeeded; host deployment skipped by request.'
    return
}

$cloudOutputs = Get-DeploymentOutputs -Name $cloudDeploymentName
$syncServiceId = $cloudOutputs.syncServiceId.value
$syncGroupName = $cloudOutputs.syncGroupName.value
$cloudEndpoint = Get-CloudEndpointForShare `
    -SyncServiceId $syncServiceId `
    -SyncGroupName $syncGroupName `
    -StorageAccountId $cloudOutputs.storageAccountId.value `
    -FileShareName $cloudOutputs.fileShareName.value
if (-not $cloudEndpoint) {
    throw "No cloud endpoint matches storage account '$($cloudOutputs.storageAccountName.value)' and share '$($cloudOutputs.fileShareName.value)'; the Hyper-V host will not be created."
}
$cloudEndpointId = $cloudEndpoint.id
$endpointState = Get-CloudEndpointState -ResourceId $cloudEndpointId
if ($endpointState -ne 'Succeeded') {
    throw "The cloud endpoint is '$endpointState'; the Hyper-V host will not be created."
}
Write-Host "Confirmed provisioned cloud endpoint '$cloudEndpointId'; proceeding to the host stage."

if ($PreviewOnly) {
    $previewIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').ToString().Trim()
    $previewParametersPath = New-TemporaryHostParameters -AdminPassword "N7!$([guid]::NewGuid().ToString('N'))z"
    try {
        Invoke-DeploymentStage -Name $hostDeploymentName -ParametersFile $previewParametersPath -TemplateFile $hostTemplatePath -PreviewOnly
    }
    finally {
        Remove-Item -LiteralPath $previewParametersPath -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'Host-stage what-if completed; no host was created.'
    return
}

$operatorIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').ToString().Trim()
$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($operatorIp, [ref]$parsedIp) -or $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Could not determine an IPv4 source address for a restricted RDP rule.'
}
$rdpSource = "$operatorIp/32"

$hostPassword = "N7!$([guid]::NewGuid().ToString('N'))z"
$credentialDirectory = Join-Path $env:LOCALAPPDATA 'AzureFileSyncNestedLab'
New-Item -Path $credentialDirectory -ItemType Directory -Force | Out-Null
$credentialPath = Join-Path $credentialDirectory 'host-password.dpapi.txt'
$encryptedPassword = ConvertTo-SecureString $hostPassword -AsPlainText -Force | ConvertFrom-SecureString
[System.IO.File]::WriteAllText($credentialPath, $encryptedPassword, [System.Text.UTF8Encoding]::new($false))

$hostParametersPath = New-TemporaryHostParameters -AdminPassword $hostPassword
try {
    Invoke-DeploymentStage -Name $hostDeploymentName -ParametersFile $hostParametersPath -TemplateFile $hostTemplatePath
}
finally {
    $hostPassword = $null
    Remove-Item -LiteralPath $hostParametersPath -Force -ErrorAction SilentlyContinue
}

$hostOutputs = Get-DeploymentOutputs -Name $hostDeploymentName
$vmName = $hostOutputs.vmName.value
$publicIpName = $hostOutputs.publicIpName.value
$null = Wait-ForVmRunning -VmName $vmName
$publicIpJson = Invoke-AzCli -Arguments @('network', 'public-ip', 'show', '--resource-group', $ResourceGroupName, '--name', $publicIpName, '--subscription', $SubscriptionId, '--query', 'ipAddress', '--output', 'tsv')
$hostPublicIp = ($publicIpJson -join [Environment]::NewLine).Trim()

Write-Host 'Installing Hyper-V on the Azure host...'
[void](Invoke-AzCli -Arguments @(
    'vm', 'run-command', 'invoke',
    '--resource-group', $ResourceGroupName,
    '--name', $vmName,
    '--command-id', 'RunPowerShellScript',
    '--scripts', "@$hostBootstrapPath",
    '--subscription', $SubscriptionId,
    '--output', 'json'
))
[void](Invoke-AzCli -Arguments @('vm', 'restart', '--resource-group', $ResourceGroupName, '--name', $vmName, '--subscription', $SubscriptionId, '--no-wait'))
$null = Wait-ForVmRunning -VmName $vmName

Write-Host 'Creating the nested guest shell and host-NAT network...'
[void](Invoke-AzCli -Arguments @(
    'vm', 'run-command', 'invoke',
    '--resource-group', $ResourceGroupName,
    '--name', $vmName,
    '--command-id', 'RunPowerShellScript',
    '--scripts', "@$nestedProvisionPath",
    '--subscription', $SubscriptionId,
    '--output', 'json'
))
[void](Invoke-AzCli -Arguments @('vm', 'deallocate', '--resource-group', $ResourceGroupName, '--name', $vmName, '--subscription', $SubscriptionId, '--no-wait'))

Write-Host "Hyper-V host: $vmName; public IP: $hostPublicIp; RDP allowed only from $rdpSource."
Write-Host "The local host password is DPAPI-protected for this Windows user at: $credentialPath"
Write-Host 'The host is deallocated to limit compute charges. Start it before connecting; the nested guest will start with the host.'
Write-Host 'The nested guest is booted from the Windows Server Evaluation ISO. Complete its installation and Azure File Sync registration interactively before running the experiment.'