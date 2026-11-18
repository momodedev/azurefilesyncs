[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$LocalPath = 'E:\filestosync',
    [ValidateRange(1, 15)][int]$PhaseTimeoutMinutes = 5
)

$ErrorActionPreference = 'Stop'
Import-Module 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll' -Force

if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
    throw "NO-GO: endpoint directory '$LocalPath' is missing."
}

$service = Get-CimInstance Win32_Service -Filter "Name='FileSyncSvc'"
if ($service.State -ne 'Running') { throw 'NO-GO: FileSyncSvc is not Running.' }
$originalProcessId = $service.ProcessId
$originalProcessStart = (Get-Process -Id $originalProcessId).StartTime

$before = @(Get-StorageSyncNetworkLimit)
$matching = @($before | Where-Object {
    $_.StartHour -eq 6 -and $_.StartMinute -eq 0 -and
    $_.EndHour -eq 22 -and $_.EndMinute -eq 0 -and $_.LimitKbps -eq 10000
})
if ($before.Count -ne 7 -or $matching.Count -ne 7 -or @($before.Day | Sort-Object -Unique).Count -ne 7) {
    throw 'NO-GO: expected exactly seven daily 06:00-22:00 10000-Kbps schedules; existing policies will not be modified.'
}

$startedAt = Get-Date
if ($startedAt.Hour -lt 6 -or $startedAt.Hour -ge 21) {
    throw 'NO-GO: inside-window test is restricted to 06:00-20:59 server-local time so it finishes before 22:00.'
}
$telemetryLog = 'Microsoft-FileSync-Agent/Telemetry'
if (-not (Get-WinEvent -ListLog $telemetryLog).IsEnabled) { throw 'NO-GO: File Sync telemetry is disabled.' }

function Assert-AgentUnchanged {
    $current = Get-CimInstance Win32_Service -Filter "Name='FileSyncSvc'"
    if ($current.State -ne 'Running' -or $current.ProcessId -ne $originalProcessId -or
        (Get-Process -Id $current.ProcessId).StartTime -ne $originalProcessStart) {
        throw 'FileSyncSvc stopped or restarted during the experiment.'
    }
}

function Read-InsideWindowSessions {
    param([datetime]$Since)

    try {
        $records = @(Get-WinEvent -FilterHashtable @{
            LogName = $telemetryLog
            Id = 9102, 9121
            StartTime = $Since
        } -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return }
        throw
    }

    foreach ($record in $records) {
        $xml = [xml]$record.ToXml()
        $data = @{}
        foreach ($item in $xml.Event.EventData.Data) { $data[$item.Name] = $item.InnerText }
        if ($record.Id -eq 9121) {
            foreach ($field in @('SessionHResult', 'ItemHResult')) {
                if (-not $data.ContainsKey($field) -or $data[$field] -ne '0') {
                    throw "Per-item error summary has a failing or missing $field."
                }
            }
            continue
        }
        if ($data.HResult -ne '0' -or -not $data.ContainsKey('PerItemErrorCount') -or
            [long]$data.PerItemErrorCount -ne 0) {
            throw 'A completed sync session failed or reported per-item errors.'
        }
        if ($data.SyncDirection -ne 'Upload' -or [long]$data.TransferredBytes -le 0 -or
            [double]$data.UploadSyncBatchDataDurationMs -le 0) { continue }
        [pscustomobject]@{
            TimeUtc = $record.TimeCreated.ToUniversalTime().ToString('o')
            Bytes = [long]$data.TransferredBytes
            Seconds = [Math]::Max([double]$data.DurationSeconds, [double]$data.UploadSyncBatchDataDurationMs / 1000)
            PerItemErrorCount = [long]$data.PerItemErrorCount
        }
    }
}

if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Upload a fresh 64-MiB dataset under the existing active-window policy without changing schedules')) {
    return
}

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path 'C:\ProgramData\AzureFileSyncOps' "$runId-native-inside-window"
$folder = Join-Path $LocalPath "$runId-native-insideWindow"
New-Item -Path $output -ItemType Directory -Force | Out-Null
ConvertTo-Json -InputObject $before -Depth 6 | Set-Content (Join-Path $output 'Before-Limits.json')
$before | Export-Clixml (Join-Path $output 'Before-Limits.clixml')
$result = $null

try {
    $phaseStart = Get-Date
    if ($phaseStart.Hour -lt 6 -or $phaseStart.Hour -ge 22) { throw 'Active schedule ended before data generation.' }

    New-Item -Path $folder -ItemType Directory -ErrorAction Stop | Out-Null
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] (1MB)
    try {
        foreach ($fileIndex in 1..4) {
            $file = Join-Path $folder "file-$fileIndex.bin"
            $stream = [System.IO.File]::Open($file, 'CreateNew', 'Write', 'None')
            try {
                foreach ($blockIndex in 1..16) {
                    $random.GetBytes($buffer)
                    $stream.Write($buffer, 0, $buffer.Length)
                }
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $random.Dispose() }

    $deadline = $phaseStart.AddMinutes($PhaseTimeoutMinutes)
    do {
        Assert-AgentUnchanged
        $sessions = @(Read-InsideWindowSessions -Since $phaseStart)
        $uploadedBytes = ($sessions | Measure-Object Bytes -Sum).Sum
        if ($uploadedBytes -gt 64MB) { throw 'Unrelated uploads contaminated the isolated experiment.' }
        if ($uploadedBytes -eq 64MB) { break }
        if ((Get-Date).Hour -lt 6 -or (Get-Date).Hour -ge 22) { throw 'Test crossed the schedule boundary before completing.' }
        Get-Counter -Counter '\AFS Bytes Transferred(_Total)\Uploaded Bytes/sec' -MaxSamples 1 |
            ForEach-Object CounterSamples |
            Select-Object Timestamp, Path, CookedValue, RawValue |
            Export-Csv (Join-Path $output 'UploadCounters.csv') -Append -NoTypeInformation
        Start-Sleep -Seconds 9
    } while ((Get-Date) -lt $deadline)

    if ($uploadedBytes -ne 64MB) { throw 'Timed out before the complete 64-MiB upload was confirmed.' }
    if ((Get-Date).Hour -lt 6 -or (Get-Date).Hour -ge 22) { throw 'Test crossed the schedule boundary before telemetry completed.' }
    $durationSeconds = ($sessions | Measure-Object Seconds -Sum).Sum
    if ($durationSeconds -le 0) { throw 'Upload telemetry reported an invalid duration.' }
    $throughputMbps = [Math]::Round($uploadedBytes * 8 / $durationSeconds / 1000000, 3)
    if ($throughputMbps -le 0 -or $throughputMbps -gt 12.5) {
        throw "The active-window throttle was not verified: observed $throughputMbps Mbps."
    }
    $sessions | Export-Csv -LiteralPath (Join-Path $output 'UploadSessions.csv') -NoTypeInformation

    Assert-AgentUnchanged
    $after = @(Get-StorageSyncNetworkLimit)
    $beforeIds = @($before.Id | Sort-Object)
    $afterIds = @($after.Id | Sort-Object)
    if (@(Compare-Object $beforeIds $afterIds).Count -or $after.Count -ne 7) {
        throw 'The original seven schedule IDs were not preserved.'
    }
    foreach ($policy in $after) {
        if ($policy.StartHour -ne 6 -or $policy.StartMinute -ne 0 -or
            $policy.EndHour -ne 22 -or $policy.EndMinute -ne 0 -or $policy.LimitKbps -ne 10000) {
            throw 'A schedule property changed during the experiment.'
        }
    }

    $result = [pscustomobject]@{
        Status = 'BOUNDED_INSIDE_WINDOW_VALIDATION_PASSED'
        RunId = $runId
        Server = $env:COMPUTERNAME
        ServerTimeZone = (Get-TimeZone).Id
        PhaseStartLocal = $phaseStart.ToString('o')
        PhaseFinishLocal = (Get-Date).ToString('o')
        Phase = 'insideWindow'
        LimitKbps = 10000
        UploadedBytes = $uploadedBytes
        DurationSeconds = $durationSeconds
        ThroughputMbps = $throughputMbps
        PerItemErrorCount = 0
        FileSyncSvcProcessId = $originalProcessId
        FileSyncSvcUnchanged = $true
        ExistingPolicyIdsPreserved = $true
        ExistingPolicies = @($after | Select-Object Id, Day, StartHour, StartMinute, EndHour, EndMinute, LimitKbps)
        TestFolder = $folder
        EvidenceDirectory = $output
        FullProductionPilot = 'Not verified by this bounded sample; representative baseline, all-day observation, overnight backlog, and SMB latency remain separate checks.'
    }
    $result | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $output 'Evidence.json')
    $result | ConvertTo-Json -Depth 7 -Compress
}
finally {
    if ($sessions) { $sessions | Export-Csv -LiteralPath (Join-Path $output 'UploadSessions.csv') -NoTypeInformation }
    Get-WinEvent -FilterHashtable @{LogName=$telemetryLog; Id=9102,9121,9302; StartTime=$phaseStart} -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ToXml() } | ConvertTo-Json |
        Set-Content (Join-Path $output 'Telemetry.json')
}