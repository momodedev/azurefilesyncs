[CmdletBinding()]
param(
    [ValidateRange(1, 10000)][int]$LimitKbps = 500,
    [ValidateRange(1, 1024)][int]$FileSizeMiB = 32,
    [ValidateRange(30, 600)][int]$SamplesPerPhase = 120,
    [string]$LocalPath = 'F:\filestosync'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $LocalPath)) {
    throw "Server endpoint path '$LocalPath' does not exist."
}

$agentModule = 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll'
if (-not (Test-Path -LiteralPath $agentModule)) {
    throw 'Azure File Sync Agent is not installed on this nested server.'
}
Import-Module $agentModule -Force

$outputPath = 'C:\ProgramData\AzureFileSyncOps'
New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$counterPaths = @(
    '\AFS Bytes Transferred\Uploaded Bytes/sec',
    '\AFS Sync Operations\Uploaded Sync Files/sec'
)
$results = [System.Collections.Generic.List[object]]::new()
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$buffer = New-Object byte[] (1MB)

function New-TestData {
    param([Parameter(Mandatory)][string]$PhasePath)

    New-Item -Path $PhasePath -ItemType Directory -Force | Out-Null
    $bytesPerFile = [long]$FileSizeMiB * 1MB / 4
    for ($fileIndex = 1; $fileIndex -le 4; $fileIndex++) {
        $filePath = Join-Path $PhasePath ('file-{0:D2}.bin' -f $fileIndex)
        $stream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $remaining = $bytesPerFile
            while ($remaining -gt 0) {
                $rng.GetBytes($buffer)
                $bytesToWrite = [int][Math]::Min($buffer.Length, $remaining)
                $stream.Write($buffer, 0, $bytesToWrite)
                $remaining -= $bytesToWrite
            }
        }
        finally {
            $stream.Dispose()
        }
    }
}

function Measure-Phase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ConfiguredLimitKbps
    )

    $phasePath = Join-Path $LocalPath "$runId-$Name"
    New-TestData -PhasePath $phasePath
    $samples = Get-Counter -Counter $counterPaths -SampleInterval 5 -MaxSamples $SamplesPerPhase
    $counterSamples = @($samples | ForEach-Object CounterSamples)
    $uploadSamples = @($counterSamples | Where-Object Path -Like '*AFS Bytes Transferred*Uploaded Bytes/sec')
    $fileSamples = @($counterSamples | Where-Object Path -Like '*AFS Sync Operations*Uploaded Sync Files/sec')
    $positiveUpload = @($uploadSamples | Where-Object CookedValue -GT 0 | ForEach-Object CookedValue)
    $averageBytesPerSecond = if ($positiveUpload.Count) {
        ($positiveUpload | Measure-Object -Average).Average
    }
    else {
        0
    }

    return [pscustomobject]@{
        Phase = $Name
        ConfiguredLimitKbps = $ConfiguredLimitKbps
        AverageActiveUploadMbps = [Math]::Round($averageBytesPerSecond * 8 / 1000000, 3)
        PeakUploadMbps = [Math]::Round((($positiveUpload | Measure-Object -Maximum).Maximum) * 8 / 1000000, 3)
        PositiveUploadSamples = $positiveUpload.Count
        UploadedFileOperations = [Math]::Round((($fileSamples | Measure-Object -Property CookedValue -Sum).Sum) * 5, 0)
        DatasetMiB = $FileSizeMiB
    }
}

try {
    Get-StorageSyncNetworkLimit | ForEach-Object { Remove-StorageSyncNetworkLimit -Id $_.Id -Confirm:$false }
    $results.Add((Measure-Phase -Name 'baseline' -ConfiguredLimitKbps 0))

    New-StorageSyncNetworkLimit `
        -Day Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday `
        -StartHour 0 `
        -EndHour 0 `
        -LimitKbps $LimitKbps | Out-Null
    $results.Add((Measure-Phase -Name 'throttled' -ConfiguredLimitKbps $LimitKbps))

    Get-StorageSyncNetworkLimit | ForEach-Object { Remove-StorageSyncNetworkLimit -Id $_.Id -Confirm:$false }
    $results.Add((Measure-Phase -Name 'recovery' -ConfiguredLimitKbps 0))
}
finally {
    Get-StorageSyncNetworkLimit | ForEach-Object { Remove-StorageSyncNetworkLimit -Id $_.Id -Confirm:$false }
    $rng.Dispose()
}

$csvPath = Join-Path $outputPath "$runId-results.csv"
$results | Export-Csv -LiteralPath $csvPath -NoTypeInformation
$events = Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-FileSync-Agent/Telemetry'
    Id = 9102, 9121, 9302
    StartTime = (Get-Date).AddHours(-3)
} -ErrorAction SilentlyContinue | Select-Object -First 100 TimeCreated, Id, LevelDisplayName, Message
if ($events) {
    $events | Export-Csv -LiteralPath (Join-Path $outputPath "$runId-events.csv") -NoTypeInformation
}

$results | ConvertTo-Json -Compress
$throttledResult = $results | Where-Object { $_.Phase -eq 'throttled' } | Select-Object -First 1
if (-not $throttledResult -or $throttledResult.PositiveUploadSamples -le 0) {
    Write-Output 'AFSLAB_EXPERIMENT_STATUS=NO_UPLOAD'
    throw 'The throttled phase recorded no positive upload samples. Verify cloud/server endpoint state and telemetry before interpreting results.'
}
Write-Output 'AFSLAB_EXPERIMENT_STATUS=SUCCESS'