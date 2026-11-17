$ErrorActionPreference = 'Stop'
$TenantId = '0e478cd4-3e52-496d-ac3a-419ca58ba7ac'
$SubscriptionId = '95642268-5116-484d-9b88-7dfce8c20ce4'
$ResourceGroupName = 'rg-infra-winmig-apac-v-chengzhiz-poc'
$StorageSyncServiceName = 'afsspqipi42iyfdsq'
$SyncGroupName = 'afsgpqipi42iyfdsq'

$dataDisks = @(Get-Disk | Where-Object { -not $_.IsBoot -and $_.Size -ge 60GB })
if ($dataDisks.Count -ne 1) {
    throw "Expected exactly one non-boot disk of at least 60 GiB; found $($dataDisks.Count)."
}

$dataDisk = $dataDisks[0]
if ($dataDisk.IsOffline) {
    Set-Disk -Number $dataDisk.Number -IsOffline $false
}
if ($dataDisk.IsReadOnly) {
    Set-Disk -Number $dataDisk.Number -IsReadOnly $false
}
if ($dataDisk.PartitionStyle -eq 'RAW') {
    Initialize-Disk -Number $dataDisk.Number -PartitionStyle GPT | Out-Null
}

$partition = Get-Partition -DiskNumber $dataDisk.Number | Where-Object Type -ne 'Reserved' | Select-Object -First 1
if (-not $partition) {
    $partition = New-Partition -DiskNumber $dataDisk.Number -UseMaximumSize -AssignDriveLetter
}
if ($partition.DriveLetter -ne 'E') {
    $existingEPartition = Get-Partition -DriveLetter E -ErrorAction SilentlyContinue
    if ($existingEPartition -and $existingEPartition.DiskNumber -ne $dataDisk.Number) {
        throw 'Drive E: belongs to a different disk; refusing to reassign it.'
    }
    if (-not $existingEPartition -and (Get-Volume -DriveLetter E -ErrorAction SilentlyContinue)) {
        throw 'Drive E: is already in use; refusing to reassign or format another volume.'
    }
    $partition | Set-Partition -NewDriveLetter E
    $partition = Get-Partition -DiskNumber $dataDisk.Number | Where-Object Type -ne 'Reserved' | Select-Object -First 1
}

$driveLetter = $partition.DriveLetter
if ($driveLetter -ne 'E' -or $driveLetter -eq $env:SystemDrive.TrimEnd(':')) {
    throw "The data disk has an unsafe drive letter '$driveLetter'."
}
$volume = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
if (-not $volume -or [string]::IsNullOrWhiteSpace($volume.FileSystem) -or $volume.FileSystem -eq 'RAW') {
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'AfsLabData' -Confirm:$false | Out-Null
    Update-HostStorageCache
    $volumeDeadline = [DateTime]::UtcNow.AddMinutes(2)
    do {
        $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        if ($volume -and $volume.FileSystem -eq 'NTFS') {
            break
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $volumeDeadline)
}
if ($volume.FileSystem -ne 'NTFS') {
    throw "The lab data disk must be NTFS; found '$($volume.FileSystem)'."
}

$serverEndpointPath = Join-Path "$driveLetter`:" 'filestosync'
New-Item -Path $serverEndpointPath -ItemType Directory -Force | Out-Null

$agentModulePath = 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll'
if (-not (Test-Path -LiteralPath $agentModulePath)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $agentInstaller = Join-Path $env:TEMP 'StorageSyncAgent-Server2025.msi'
    Invoke-WebRequest -Uri 'https://aka.ms/afs/agent/Server2025' -OutFile $agentInstaller -UseBasicParsing
    $install = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $agentInstaller, '/quiet', '/norestart') -Wait -PassThru
    if ($install.ExitCode -eq 3010) {
        Write-Output 'AFSLAB_AGENT_REBOOT_REQUIRED=true'
        return
    }
    if ($install.ExitCode -ne 0) {
        throw "Azure File Sync Agent installation failed with exit code $($install.ExitCode)."
    }
}
if (-not (Test-Path -LiteralPath $agentModulePath)) {
    throw 'The Azure File Sync Agent module was not found after installation.'
}
Import-Module $agentModulePath -Force

if (-not (Get-Module -ListAvailable -Name Az.StorageSync | Where-Object Version -ge ([version]'2.5.0'))) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module Az.StorageSync -Scope AllUsers -Force -AllowClobber -Confirm:$false -Repository PSGallery
}
Import-Module Az.Accounts -Force
Import-Module Az.StorageSync -Force

Disable-AzContextAutosave -Scope Process | Out-Null
$context = (Connect-AzAccount -Identity -Tenant $TenantId -ErrorAction Stop).Context
Set-AzContext -Subscription $SubscriptionId -DefaultProfile $context | Out-Null

$registeredServers = @(Get-AzStorageSyncServer -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName)
$registeredServer = $registeredServers | Where-Object {
    $_.FriendlyName -ieq $env:COMPUTERNAME -or $_.ServerName -ieq $env:COMPUTERNAME
} | Select-Object -First 1
if (-not $registeredServer) {
    $registeredServer = Register-AzStorageSyncServer -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName
}
if (-not $registeredServer.ResourceId) {
    throw 'Azure File Sync registration did not return a registered-server resource ID.'
}

$registeredServer = Get-AzStorageSyncServer -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName |
    Where-Object { $_.ServerId -eq $registeredServer.ServerId } |
    Select-Object -First 1
if ($registeredServer.ActiveAuthType -ne 'ManagedIdentity') {
    throw "Registered server authentication is '$($registeredServer.ActiveAuthType)'. Configure the Storage Sync Service managed identity from an operator account, then rerun host initialization."
}

$syncGroup = Get-AzStorageSyncGroup -ResourceGroupName $ResourceGroupName -StorageSyncServiceName $StorageSyncServiceName -Name $SyncGroupName
$serverEndpoints = @(Get-AzStorageSyncServerEndpoint -ParentObject $syncGroup)
$serverEndpoint = $serverEndpoints | Where-Object {
    $_.ServerResourceId -eq $registeredServer.ResourceId -and
    $_.ServerLocalPath.TrimEnd('\') -ieq $serverEndpointPath.TrimEnd('\')
} | Select-Object -First 1
if (-not $serverEndpoint) {
    $serverName = if ($registeredServer.FriendlyName) { $registeredServer.FriendlyName } else { $env:COMPUTERNAME }
    $serverEndpoint = New-AzStorageSyncServerEndpoint `
        -ParentObject $syncGroup `
        -Name $serverName `
        -ServerResourceId $registeredServer.ResourceId `
        -ServerLocalPath $serverEndpointPath `
        -InitialUploadPolicy Merge `
        -InitialDownloadPolicy NamespaceOnly `
        -Confirm:$false
}

[pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    ServerResourceId = $registeredServer.ResourceId
    ActiveAuthType = $registeredServer.ActiveAuthType
    ServerEndpointPath = $serverEndpointPath
    ServerEndpointId = $serverEndpoint.ResourceId
} | ConvertTo-Json -Compress | ForEach-Object { Write-Output "AFSLAB_HOST_SETUP=$_" }