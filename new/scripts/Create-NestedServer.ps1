$ErrorActionPreference = 'Stop'

if (-not (Get-WindowsFeature -Name Hyper-V).Installed) {
    throw 'Hyper-V is not installed. Run Initialize-HyperVHost.ps1 and restart the host first.'
}

$dataDisk = @(Get-Disk | Where-Object { -not $_.IsBoot -and $_.Size -ge 60GB })
if ($dataDisk.Count -ne 1) {
    throw "Expected one non-boot data disk of at least 60 GiB; found $($dataDisk.Count)."
}
if ($dataDisk[0].IsOffline) {
    Set-Disk -Number $dataDisk[0].Number -IsOffline $false
}
if ($dataDisk[0].IsReadOnly) {
    Set-Disk -Number $dataDisk[0].Number -IsReadOnly $false
}
if ($dataDisk[0].PartitionStyle -eq 'RAW') {
    Initialize-Disk -Number $dataDisk[0].Number -PartitionStyle GPT
}
$dataPartition = Get-Partition -DiskNumber $dataDisk[0].Number | Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1
if (-not $dataPartition) {
    $dataPartition = New-Partition -DiskNumber $dataDisk[0].Number -UseMaximumSize -AssignDriveLetter
}
if (-not $dataPartition.DriveLetter) {
    $dataPartition | Set-Partition -NewDriveLetter 'E'
}
$dataVolume = Get-Volume -DriveLetter E -ErrorAction SilentlyContinue
if (-not $dataVolume) {
    Format-Volume -Partition (Get-Partition -DiskNumber $dataDisk[0].Number | Where-Object DriveLetter -eq 'E') -FileSystem NTFS -NewFileSystemLabel 'AfsNestedLab' -Confirm:$false | Out-Null
}

$labRoot = 'E:\AfsNestedLab'
$vmRoot = Join-Path $labRoot 'VMs'
$isoPath = Join-Path $labRoot 'WindowsServer2025Evaluation.iso'
New-Item -Path $vmRoot -ItemType Directory -Force | Out-Null

if (-not (Get-VMSwitch -Name 'AfsLabNAT' -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name 'AfsLabNAT' -SwitchType Internal | Out-Null
}
$hostAdapter = Get-NetAdapter -Name 'vEthernet (AfsLabNAT)' -ErrorAction Stop
if (-not (Get-NetIPAddress -InterfaceIndex $hostAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq '192.168.100.1')) {
    New-NetIPAddress -InterfaceIndex $hostAdapter.ifIndex -IPAddress '192.168.100.1' -PrefixLength 24 | Out-Null
}
if (-not (Get-NetNat -Name 'AfsLabNAT' -ErrorAction SilentlyContinue)) {
    New-NetNat -Name 'AfsLabNAT' -InternalIPInterfaceAddressPrefix '192.168.100.0/24' | Out-Null
}

if (-not (Test-Path -LiteralPath $isoPath)) {
    $isoUri = 'https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us'
    Invoke-WebRequest -Uri $isoUri -OutFile $isoPath -UseBasicParsing
}
if ((Get-Item -LiteralPath $isoPath).Length -lt 2GB) {
    throw 'The downloaded Windows Server Evaluation ISO is unexpectedly small; refusing to create the guest from an invalid download.'
}

$vmName = 'NestedAfsServer'
$osVhd = Join-Path $vmRoot 'NestedAfsServer-OS.vhdx'
$dataVhd = Join-Path $vmRoot 'NestedAfsServer-Data.vhdx'
if (-not (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
    New-VHD -Path $osVhd -SizeBytes 40GB -Dynamic | Out-Null
    New-VHD -Path $dataVhd -SizeBytes 32GB -Dynamic | Out-Null
    New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath $osVhd -SwitchName 'AfsLabNAT' | Out-Null
    Set-VMProcessor -VMName $vmName -Count 2
    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -StartupBytes 4GB
    Set-VM -Name $vmName -AutomaticStartAction Start -AutomaticStopAction Save
    Add-VMHardDiskDrive -VMName $vmName -Path $dataVhd
    $dvdDrive = Get-VMDvdDrive -VMName $vmName
    Set-VMDvdDrive -VMName $vmName -ControllerNumber $dvdDrive.ControllerNumber -ControllerLocation $dvdDrive.ControllerLocation -Path $isoPath
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice (Get-VMDvdDrive -VMName $vmName)
}

if ((Get-VM -Name $vmName).State -ne 'Running') {
    Start-VM -Name $vmName | Out-Null
}

Write-Output "AFSLAB_NESTED_VM=$vmName"
Write-Output "AFSLAB_NESTED_INSTALL_ISO=$isoPath"
Write-Output 'Complete Windows Server Evaluation setup in the nested VM console, then run Configure-NestedGuest.ps1 from an elevated host PowerShell session.'