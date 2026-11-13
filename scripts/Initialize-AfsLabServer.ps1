[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$StorageSyncServiceName,

    [string]$LocalPath = 'D:\AfsLab'
)

$ErrorActionPreference = 'Stop'
# Initial registration requires IE Enhanced Security Configuration to be off on Desktop Experience.
$installType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType
if ($installType -ne 'Server Core') {
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name IsInstalled -Value 0 -Force
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' -Name IsInstalled -Value 0 -Force
    Stop-Process -Name iexplore -ErrorAction SilentlyContinue
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$systemDriveLetter = $env:SystemDrive.TrimEnd(':')
$systemDiskNumber = (Get-Partition -DriveLetter $systemDriveLetter -ErrorAction Stop).DiskNumber
$dataDisks = @(Get-Disk | Where-Object {
    $_.Number -ne $systemDiskNumber -and $_.Location -match '(?i)\bLUN\s+0\s*$'
})
if ($dataDisks.Count -ne 1) {
    throw "Expected exactly one non-system disk at data LUN 0; found $($dataDisks.Count)."
}
$dataDisk = $dataDisks[0]

if ($dataDisk.PartitionStyle -eq 'RAW') {
    Initialize-Disk -Number $dataDisk.Number -PartitionStyle GPT | Out-Null
}

$dataPartitions = @(Get-Partition -DiskNumber $dataDisk.Number -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -in @('Basic', 'IFS') })
if ($dataPartitions.Count -gt 1) {
    throw 'The Azure File Sync data disk has multiple data partitions.'
}
$dataPartition = if ($dataPartitions.Count -eq 1) {
    $dataPartitions[0]
}
else {
    New-Partition -DiskNumber $dataDisk.Number -UseMaximumSize
}
$dataVolume = $dataPartition | Get-Volume -ErrorAction SilentlyContinue
if (-not $dataVolume -or -not $dataVolume.FileSystem -or $dataVolume.FileSystem -eq 'RAW') {
    Format-Volume -Partition $dataPartition `
        -FileSystem NTFS `
        -NewFileSystemLabel 'AFSLAB' `
        -Confirm:$false | Out-Null
    $dataVolume = $dataPartition | Get-Volume
}
if (-not $dataVolume.DriveLetter) {
    $usedLetters = @((Get-Volume | Where-Object DriveLetter | ForEach-Object { [string]$_.DriveLetter }))
    $availableLetter = @([char[]]'FGHIJKLMNOPQRSTUVWXYZ' | Where-Object { $usedLetters -notcontains [string]$_ } | Select-Object -First 1)
    if (-not $availableLetter) {
        throw 'No unused drive letter is available for the File Sync data disk.'
    }
    Set-Partition -DiskNumber $dataDisk.Number -PartitionNumber $dataPartition.PartitionNumber -NewDriveLetter ([char]$availableLetter[0])
    $dataVolume = Get-Partition -DiskNumber $dataDisk.Number -PartitionNumber $dataPartition.PartitionNumber | Get-Volume
}
$LocalPath = Join-Path "$($dataVolume.DriveLetter):\" 'AfsLab'
New-Item -Path $LocalPath -ItemType Directory -Force | Out-Null

if (-not (Get-Service -Name FileSyncSvc -ErrorAction SilentlyContinue)) {
    $installerPath = Join-Path $env:TEMP 'StorageSyncAgent.msi'
    $installerLog = Join-Path $env:TEMP 'AFSInstaller.log'
    Invoke-WebRequest -Uri 'https://aka.ms/afs/agent/Server2022' -OutFile $installerPath
    $installer = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList @('/i', $installerPath, 'ENABLE_MU_ENROLL=1', 'ENABLE_AGENT_AUTO_UPDATE=1', '/qn', '/norestart', '/l*v', $installerLog) `
        -Wait -PassThru
    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    if ($installer.ExitCode -notin @(0, 3010)) {
        throw "Azure File Sync agent installation failed with exit code $($installer.ExitCode). See $installerLog."
    }
    if ($installer.ExitCode -eq 3010) {
        throw 'Azure File Sync agent requires a restart. Restart the lab VM and rerun this script.'
    }
}

Set-Service -Name FileSyncSvc -StartupType Automatic
Start-Service -Name FileSyncSvc
if (-not (Get-Module -ListAvailable -Name Az.StorageSync)) {
    Install-Module -Name Az.StorageSync -Scope AllUsers -Force -AllowClobber -Confirm:$false
}
Import-Module Az.StorageSync -Force
Connect-AzAccount -Identity -Tenant $TenantId -ErrorAction Stop | Out-Null
Set-AzContext -Subscription $SubscriptionId -Tenant $TenantId | Out-Null

$registeredServer = Get-AzStorageSyncServer `
    -ResourceGroupName $ResourceGroupName `
    -StorageSyncServiceName $StorageSyncServiceName |
    Where-Object FriendlyName -eq $env:COMPUTERNAME |
    Select-Object -First 1

if (-not $registeredServer) {
    $registeredServer = Register-AzStorageSyncServer `
        -ResourceGroupName $ResourceGroupName `
        -StorageSyncServiceName $StorageSyncServiceName `
        -AssignIdentity
}

$syncServiceIdentity = Get-AzStorageSyncService `
    -ResourceGroupName $ResourceGroupName `
    -Name $StorageSyncServiceName
if (-not $syncServiceIdentity.UseIdentity -or $registeredServer.ActiveAuthType -ne 'ManagedIdentity') {
    Set-AzStorageSyncServiceIdentity `
        -ResourceGroupName $ResourceGroupName `
        -Name $StorageSyncServiceName `
        -Verbose | Out-Null
    $syncServiceIdentity = Get-AzStorageSyncService `
        -ResourceGroupName $ResourceGroupName `
        -Name $StorageSyncServiceName
}
if (-not $syncServiceIdentity.UseIdentity) {
    throw 'Set-AzStorageSyncServiceIdentity completed without enabling managed identity.'
}

Import-Module 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll' -Force
Debug-StorageSyncServer -TestNetworkConnectivity
Debug-StorageSyncServer -Diagnose

$bootstrapResult = [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    FileSyncService = (Get-Service FileSyncSvc).Status.ToString()
    RegisteredServerResourceId = $registeredServer.ResourceId
    LocalPath = $LocalPath
    AgentVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure\StorageSync\Agent' -ErrorAction SilentlyContinue).Version
    ManagedIdentityEnabled = [bool]$syncServiceIdentity.UseIdentity
} | ConvertTo-Json -Compress
Write-Output "AFSLAB_BOOTSTRAP_RESULT=$bootstrapResult"
Write-Output 'AFSLAB_BOOTSTRAP_STATUS=SUCCESS'