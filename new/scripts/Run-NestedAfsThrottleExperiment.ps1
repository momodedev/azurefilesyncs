[CmdletBinding()]
param(
    [ValidateRange(1, 10000)][int]$LimitKbps = 500,
    [ValidateRange(1, 1024)][int]$FileSizeMiB = 32,
    [ValidateRange(30, 600)][int]$SamplesPerPhase = 120,
    [string]$LocalPath = 'E:\filestosync'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $LocalPath)) {
    throw "Server endpoint path '$LocalPath' does not exist."
}

$agentModule = 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll'
if (-not (Test-Path -LiteralPath $agentModule)) {
    throw 'Azure File Sync Agent is not installed on this server.'
}
Import-Module $agentModule -Force

$outputPath = 'C:\ProgramData\AzureFileSyncOps'
New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$counterPaths = @(
    '\AFS Bytes Transferred(*)\Uploaded Bytes/sec',
    '\AFS Sync Operations(*)\Uploaded Sync Files/sec'
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
    $phaseStart = Get-Date
    New-TestData -PhasePath $phasePath
    $samples = Get-Counter -Counter $counterPaths -SampleInterval 5 -MaxSamples $SamplesPerPhase
    $counterSamples = @($samples | ForEach-Object CounterSamples)
    $uploadSamples = @($counterSamples | Where-Object Path -Like '*AFS Bytes Transferred(_Total)*Uploaded Bytes/sec')
    $fileSamples = @($counterSamples | Where-Object Path -Like '*AFS Sync Operations(_Total)*Uploaded Sync Files/sec')
    $allUpload = @($uploadSamples | ForEach-Object CookedValue)
    $positiveUpload = @($uploadSamples | Where-Object CookedValue -GT 0 | ForEach-Object CookedValue)
    $averageBytesPerSecond = if ($positiveUpload.Count) {
        ($positiveUpload | Measure-Object -Average).Average
    }
    else {
        0
    }
    $windowAverageBytesPerSecond = if ($allUpload.Count) {
        ($allUpload | Measure-Object -Average).Average
    }
    else {
        0
    }

    $sessions = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-FileSync-Agent/Telemetry'
        Id = 9102
        StartTime = $phaseStart
    } -ErrorAction Stop | ForEach-Object {
        $eventXml = [xml]$_.ToXml()
        $data = @{}
        foreach ($item in $eventXml.Event.EventData.Data) {
            $data[$item.Name] = $item.InnerText
        }
        if ($data.HResult -eq '0' -and [double]$data.TransferredBytes -gt 0 -and [double]$data.UploadSyncBatchDataDurationMs -gt 0) {
            [pscustomobject]@{
                Bytes = [double]$data.TransferredBytes
                Seconds = [Math]::Max([double]$data.DurationSeconds, [double]$data.UploadSyncBatchDataDurationMs / 1000)
            }
        }
    })
    $sessionBytes = ($sessions | Measure-Object -Property Bytes -Sum).Sum
    $sessionSeconds = ($sessions | Measure-Object -Property Seconds -Sum).Sum
    $sessionMbps = if ($sessionSeconds -gt 0) { $sessionBytes * 8 / $sessionSeconds / 1000000 } else { 0 }

    return [pscustomobject]@{
        Phase = $Name
        ConfiguredLimitKbps = $ConfiguredLimitKbps
        SessionUploadMbps = [Math]::Round($sessionMbps, 3)
        SessionUploadedBytes = $sessionBytes
        SessionDurationSeconds = $sessionSeconds
        CounterActiveUploadMbps = [Math]::Round($averageBytesPerSecond * 8 / 1000000, 3)
        CounterWindowUploadMbps = [Math]::Round($windowAverageBytesPerSecond * 8 / 1000000, 3)
        CounterPeakUploadMbps = [Math]::Round((($allUpload | Measure-Object -Maximum).Maximum) * 8 / 1000000, 3)
        PositiveUploadSamples = $positiveUpload.Count
        CounterUploadedFileOperations = [Math]::Round((($fileSamples | Measure-Object -Property CookedValue -Sum).Sum) * 5, 0)
        DatasetMiB = $FileSizeMiB
    }
}

try {
    Get-StorageSyncNetworkLimit | ForEach-Object { Remove-StorageSyncNetworkLimit -Id $_.Id }
    $results.Add((Measure-Phase -Name 'baseline' -ConfiguredLimitKbps 0))

    New-StorageSyncNetworkLimit `
        -Day Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday `
        -StartHour 0 `
        -EndHour 0 `
        -LimitKbps $LimitKbps | Out-Null
    $results.Add((Measure-Phase -Name 'throttled' -ConfiguredLimitKbps $LimitKbps))

    Get-StorageSyncNetworkLimit | ForEach-Object { Remove-StorageSyncNetworkLimit -Id $_.Id }
    $results.Add((Measure-Phase -Name 'recovery' -ConfiguredLimitKbps 0))
}
finally {
    Get-StorageSyncNetworkLimit | ForEach-Object { Remove-StorageSyncNetworkLimit -Id $_.Id }
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
if (-not $throttledResult -or $throttledResult.SessionUploadedBytes -lt ([long]$FileSizeMiB * 1MB)) {
    Write-Output 'AFSLAB_EXPERIMENT_STATUS=NO_UPLOAD'
    throw 'Telemetry did not confirm the complete throttled upload. Increase the measurement window or reduce the dataset.'
}
if ($throttledResult.SessionUploadMbps -le 0 -or $throttledResult.SessionUploadMbps -gt ($LimitKbps / 1000 * 1.25)) {
    Write-Output 'AFSLAB_EXPERIMENT_STATUS=THROTTLE_NOT_VERIFIED'
    throw 'Session throughput did not verify the configured limit within 25 percent tolerance.'
}
foreach ($unlimitedResult in @($results | Where-Object Phase -NE 'throttled')) {
    if ($unlimitedResult.SessionUploadedBytes -lt ([long]$FileSizeMiB * 1MB) -or $unlimitedResult.SessionUploadMbps -le $throttledResult.SessionUploadMbps) {
        Write-Output 'AFSLAB_EXPERIMENT_STATUS=RECOVERY_NOT_VERIFIED'
        throw 'Telemetry did not confirm complete and faster baseline/recovery uploads.'
    }
}
Write-Output 'AFSLAB_EXPERIMENT_STATUS=SUCCESS'