[CmdletBinding()]
param(
    [string]$VmName = 'NestedAfsServer',
    [string]$ExperimentScriptPath = (Join-Path $PSScriptRoot 'Run-NestedAfsThrottleExperiment.ps1')
)

$ErrorActionPreference = 'Stop'
if (-not (Get-VM -Name $VmName -ErrorAction SilentlyContinue)) {
    throw "Nested VM '$VmName' was not found."
}
if ((Get-VM -Name $VmName).State -ne 'Running') {
    Start-VM -Name $VmName | Out-Null
}

$credential = Get-Credential -UserName 'Administrator' -Message 'Enter the local Administrator credential created during nested Windows Server setup.'
$session = New-PSSession -VMName $VmName -Credential $credential
try {
    Invoke-Command -Session $session -ScriptBlock {
        $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        if (-not $adapter) {
            throw 'The nested VM has no active virtual network adapter.'
        }
        $existingAddress = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object IPAddress -eq '192.168.100.10'
        if (-not $existingAddress) {
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like '169.254.*' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress '192.168.100.10' -PrefixLength 24 -DefaultGateway '192.168.100.1' | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses '1.1.1.1'

        $dataDisk = @(Get-Disk | Where-Object { -not $_.IsBoot -and $_.PartitionStyle -eq 'RAW' })
        if ($dataDisk.Count -gt 1) {
            throw 'More than one uninitialized non-boot disk was found in the nested VM.'
        }
        if ($dataDisk.Count -eq 1) {
            Initialize-Disk -Number $dataDisk[0].Number -PartitionStyle GPT
            $partition = New-Partition -DiskNumber $dataDisk[0].Number -UseMaximumSize -DriveLetter F
            Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel 'AfsLabData' -Confirm:$false | Out-Null
        }
        if (-not (Test-Path -LiteralPath 'F:\')) {
            throw 'The nested data disk was not mounted as F:. Do not use the system or temporary volume for the server endpoint.'
        }
        New-Item -Path 'F:\filestosync' -ItemType Directory -Force | Out-Null

        $agentPath = Join-Path $env:TEMP 'StorageSyncAgent.msi'
        Invoke-WebRequest -Uri 'https://aka.ms/afs/agent/Server2025' -OutFile $agentPath -UseBasicParsing
        $install = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $agentPath, '/quiet', '/norestart') -Wait -PassThru
        if ($install.ExitCode -notin @(0, 3010)) {
            throw "Azure File Sync Agent installation failed with exit code $($install.ExitCode)."
        }
    }
    if (Test-Path -LiteralPath $ExperimentScriptPath) {
        Copy-Item -LiteralPath $ExperimentScriptPath -Destination 'C:\Users\Public\Documents\Run-NestedAfsThrottleExperiment.ps1' -ToSession $session -Force
    }
}
finally {
    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
}

Write-Host 'Nested guest networking, F:\filestosync, and the Azure File Sync agent are configured.'
Write-Host 'Open ServerRegistration.exe in the nested guest console and complete interactive registration. Then add a server endpoint for F:\filestosync before running the experiment.'