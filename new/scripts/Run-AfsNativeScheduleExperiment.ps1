[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$LocalPath = 'E:\filestosync',
    [ValidateRange(1, 15)][int]$PhaseTimeoutMinutes = 5,
    [switch]$RetainPolicy,
    [switch]$ReuseExistingPolicy,
    [switch]$OutsideWindowTest
)

$ErrorActionPreference = 'Stop'
function Assert-NoPerItemErrors {
    param([hashtable]$Data)
    foreach ($field in @('SessionHResult', 'ItemHResult')) {
        if (-not $Data.ContainsKey($field) -or $Data[$field] -ne '0') {
            throw "NO-GO: event 9121 field '$field' is missing or nonzero."
        }
    }
}

Import-Module 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll' -Force
if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) { throw 'The server endpoint path is missing.' }
$service = Get-CimInstance Win32_Service -Filter "Name='FileSyncSvc'"
if ($service.State -ne 'Running') { throw 'NO-GO: FileSyncSvc is not Running.' }
$originalProcessId = $service.ProcessId
$originalProcessStart = (Get-Process -Id $originalProcessId).StartTime
$before = @(Get-StorageSyncNetworkLimit)
if ($ReuseExistingPolicy) {
    $matching = @($before | Where-Object {
        $_.StartHour -eq 6 -and $_.EndHour -eq 22 -and $_.LimitKbps -eq 10000 -and
        $_.StartMinute -eq 0 -and $_.EndMinute -eq 0
    })
    if ($before.Count -ne 7 -or $matching.Count -ne 7 -or @($before.Day | Sort-Object -Unique).Count -ne 7) {
        throw 'NO-GO: reuse requires exactly the seven intended daily schedules, with no extras.'
    }
}
elseif ($before.Count) { throw 'NO-GO: existing network limits require separate review; no replacement is attempted.' }
$now = Get-Date
if ($OutsideWindowTest -and $now.Hour -ge 6 -and $now.Hour -lt 22) {
    throw 'Outside-window verification must run from 22:00 through 05:59 server-local time.'
}
if (-not $OutsideWindowTest -and ($now.Hour -lt 6 -or $now.Hour -ge 21)) {
    throw 'Run this bounded active-window test between 06:00 and 21:00 server-local time; the policy itself is 06:00-22:00.'
}
$telemetryLog = 'Microsoft-FileSync-Agent/Telemetry'
if (-not (Get-WinEvent -ListLog $telemetryLog).IsEnabled) { throw 'NO-GO: telemetry log disabled.' }
try {
    $recentErrors = @(Get-WinEvent -FilterHashtable @{LogName=$telemetryLog; Id=9121; StartTime=$now.AddMinutes(-30)} -ErrorAction Stop)
}
catch {
    if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
    $recentErrors = @()
}
foreach ($event in $recentErrors) {
    $xml = [xml]$event.ToXml()
    $data = @{}
    foreach ($item in $xml.Event.EventData.Data) { $data[$item.Name] = $item.InnerText }
    Assert-NoPerItemErrors -Data $data
}
$action = if ($OutsideWindowTest) { 'Upload 64 MiB outside the existing 06:00-22:00 schedule; preserve every policy object' } elseif ($ReuseExistingPolicy) { 'Upload 64 MiB under the existing native schedule; preserve every policy object' } else {
    'Run 64-MiB baseline, 06:00-22:00 10000-Kbps schedule, and rollback recovery; never stop FileSyncSvc'
}
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action)) { return }

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path 'C:\ProgramData\AzureFileSyncOps' "$runId-native-schedule"
New-Item $output -ItemType Directory | Out-Null
ConvertTo-Json -InputObject $before -Depth 6 | Set-Content (Join-Path $output 'Before-Limits.json')
$before | Export-Clixml (Join-Path $output 'Before-Limits.clixml')
$ownership = @{ Ids = @() }
$keep = $false
$results = @()

function Assert-AgentRunning {
    $current = Get-CimInstance Win32_Service -Filter "Name='FileSyncSvc'"
    if ($current.State -ne 'Running' -or $current.ProcessId -ne $originalProcessId -or
        (Get-Process -Id $current.ProcessId).StartTime -ne $originalProcessStart) {
        throw 'FileSyncSvc stopped or restarted during the experiment.'
    }
}

function Remove-OwnedLimits {
    foreach ($limit in @(Get-StorageSyncNetworkLimit)) {
        if ($ownership.Ids -contains [string]$limit.Id) { Remove-StorageSyncNetworkLimit -Id $limit.Id }
    }
    if (@(Get-StorageSyncNetworkLimit).Count) { throw 'Unexpected network limits remain; review the schedule manually.' }
    $ownership.Ids = @()
}

function Add-NativeLimits {
    if (@(Get-StorageSyncNetworkLimit).Count) { throw 'Refusing to overwrite an existing schedule.' }
    try {
        New-StorageSyncNetworkLimit -Day Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday `
            -StartHour 6 -EndHour 22 -LimitKbps 10000 | Out-Null
    }
    finally {
        $limits = @(Get-StorageSyncNetworkLimit)
        $ownership.Ids = @($limits | Where-Object {
            $_.StartHour -eq 6 -and $_.EndHour -eq 22 -and $_.LimitKbps -eq 10000
        } | ForEach-Object { [string]$_.Id })
        ConvertTo-Json -InputObject $limits -Depth 6 | Set-Content (Join-Path $output 'Scheduled-Limits.json')
    }
    if ($limits.Count -ne 7 -or $ownership.Ids.Count -ne 7 -or @($limits.Day | Sort-Object -Unique).Count -ne 7) {
        throw 'Expected seven unique daily 06:00-22:00 10000-Kbps schedule entries.'
    }
}

function Read-UploadSessions {
    param([datetime]$Since)
    try {
        $events = @(Get-WinEvent -FilterHashtable @{LogName=$telemetryLog; Id=9102,9121; StartTime=$Since} -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return }
        throw
    }
    foreach ($event in $events) {
        $xml = [xml]$event.ToXml()
        $data = @{}
        foreach ($item in $xml.Event.EventData.Data) { $data[$item.Name] = $item.InnerText }
        if ($event.Id -eq 9121) {
            Assert-NoPerItemErrors -Data $data
            continue
        }
        if ($data.HResult -ne '0' -or -not $data.ContainsKey('PerItemErrorCount') -or [long]$data.PerItemErrorCount -ne 0) {
            throw 'A session failed or did not confirm zero per-item errors.'
        }
        if ([double]$data.TransferredBytes -gt 0 -and [double]$data.UploadSyncBatchDataDurationMs -gt 0) {
            [pscustomobject]@{
                TimeUtc = $event.TimeCreated.ToUniversalTime().ToString('o')
                Bytes = [long]$data.TransferredBytes
                Seconds = [Math]::Max([double]$data.DurationSeconds, [double]$data.UploadSyncBatchDataDurationMs / 1000)
                PerItemErrorCount = [long]$data.PerItemErrorCount
            }
        }
    }
}

function Measure-NativePhase {
    param([string]$Name, [int]$LimitKbps)
    Assert-AgentRunning
    $started = Get-Date
    $withinSchedule = $started.Hour -ge 6 -and $started.Hour -lt 22
    if ($Name -eq 'scheduled' -and -not $withinSchedule) { throw 'Outside active schedule.' }
    if ($Name -eq 'outsideWindow' -and $withinSchedule) { throw 'Outside-window phase started during the active schedule.' }
    $folder = Join-Path $LocalPath "$runId-native-$Name"
    New-Item $folder -ItemType Directory | Out-Null
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] (1MB)
    try {
        foreach ($fileIndex in 1..4) {
            $stream = [System.IO.File]::Open((Join-Path $folder "file-$fileIndex.bin"), 'CreateNew', 'Write', 'None')
            try {
                foreach ($blockIndex in 1..16) { $random.GetBytes($buffer); $stream.Write($buffer, 0, $buffer.Length) }
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $random.Dispose() }
    do {
        Assert-AgentRunning
        $sessions = @(Read-UploadSessions -Since $started)
        $bytes = ($sessions | Measure-Object Bytes -Sum).Sum
        if ($bytes -gt 64MB) { throw 'Unrelated uploads contaminated the isolated workload.' }
        if ($bytes -eq 64MB) { break }
        Get-Counter -Counter '\AFS Bytes Transferred(_Total)\Uploaded Bytes/sec' -SampleInterval 5 -MaxSamples 2 |
            ForEach-Object CounterSamples | Select-Object Timestamp, Path, CookedValue, RawValue |
            Export-Csv (Join-Path $output "$Name-counters.csv") -Append -NoTypeInformation
    } while ((Get-Date) -lt $started.AddMinutes($PhaseTimeoutMinutes))
    if ($bytes -ne 64MB) { throw "Incomplete $Name upload; do not start another workload until outstanding uploads finish." }
    $finishedWithinSchedule = (Get-Date).Hour -ge 6 -and (Get-Date).Hour -lt 22
    if ($Name -eq 'scheduled' -and -not $finishedWithinSchedule) { throw 'Scheduled phase crossed the policy boundary.' }
    if ($Name -eq 'outsideWindow' -and $finishedWithinSchedule) { throw 'Outside-window phase crossed into the active policy window.' }
    $seconds = ($sessions | Measure-Object Seconds -Sum).Sum
    if ($seconds -le 0) { throw 'Invalid session duration.' }
    $sessions | Export-Csv (Join-Path $output "$Name-sessions.csv") -NoTypeInformation
    [pscustomobject]@{
        Phase = $Name
        LimitKbps = $LimitKbps
        Bytes = $bytes
        Seconds = $seconds
        Mbps = [Math]::Round($bytes * 8 / $seconds / 1000000, 3)
        PerItemErrors = 0
    }
}

try {
    if ($OutsideWindowTest) {
        $results += Measure-NativePhase -Name outsideWindow -LimitKbps 0
    }
    elseif ($ReuseExistingPolicy) {
        $results += Measure-NativePhase -Name scheduled -LimitKbps 10000
    }
    else {
        $results += Measure-NativePhase -Name baseline -LimitKbps 0
        Add-NativeLimits
        $results += Measure-NativePhase -Name scheduled -LimitKbps 10000
        Remove-OwnedLimits
        $results += Measure-NativePhase -Name rollbackRecovery -LimitKbps 0
    }
    $results | Export-Csv (Join-Path $output 'Results.csv') -NoTypeInformation
    $measuredPhase = if ($OutsideWindowTest) { $results | Where-Object Phase -EQ outsideWindow } else { $results | Where-Object Phase -EQ scheduled }
    if ($OutsideWindowTest) {
        if ($measuredPhase.Mbps -le 12.5) { throw 'Outside-window throughput did not exceed the 10-Mbps active-window ceiling.' }
    }
    elseif ($measuredPhase.Mbps -le 0 -or $measuredPhase.Mbps -gt 12.5) {
        throw 'Native 10-Mbps throttle not verified within 25 percent tolerance.'
    }
    if (-not $ReuseExistingPolicy -and -not $OutsideWindowTest -and
        ($results[0].Mbps -le $measuredPhase.Mbps -or $results[2].Mbps -le $measuredPhase.Mbps)) {
        throw 'Baseline and rollback recovery must be faster than scheduled upload.'
    }
    if ($RetainPolicy -and -not $ReuseExistingPolicy) { Add-NativeLimits }
    Assert-AgentRunning
    $finalLimits = @(Get-StorageSyncNetworkLimit)
    if ($ReuseExistingPolicy -and @(Compare-Object @($before.Id | Sort-Object) @($finalLimits.Id | Sort-Object)).Count) {
        throw 'Existing schedule IDs changed unexpectedly.'
    }
    $evidence = [pscustomobject]@{
        Status = if ($OutsideWindowTest) { 'BOUNDED_OUTSIDE_WINDOW_VALIDATION_PASSED' } else { 'BOUNDED_LAB_VALIDATION_PASSED' }
        RunId = $runId
        OutputPath = $output
        ServerTimeZone = (Get-TimeZone).Id
        ServerLocalTime = (Get-Date).ToString('o')
        UtcTime = [datetime]::UtcNow.ToString('o')
        AgentProcessId = $originalProcessId
        AgentProcessUnchanged = $true
        Results = $results
        FinalLimits = @($finalLimits | Select-Object Id, Day, StartHour, EndHour, LimitKbps)
        ExistingPolicyReused = $ReuseExistingPolicy.IsPresent -or $OutsideWindowTest.IsPresent
        FullPilot = 'NOT_COMPLETED: requires >=2h representative baseline, business-hours window, overnight automatic recovery, backlog forecast and SMB latency checks'
        RecoveryType = if ($OutsideWindowTest) { 'Outside-window release tested; exact 22:00 boundary was not observed' } elseif ($ReuseExistingPolicy) { 'NOT_TESTED: existing policy preserved; fresh baseline and rollback require approval' } else {
            'Explicit policy removal; NOT automatic 22:00 boundary verification'
        }
    }
    $evidence | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $output 'Evidence.json')
    $keep = $RetainPolicy.IsPresent -or $ReuseExistingPolicy.IsPresent -or $OutsideWindowTest.IsPresent
    $evidence | ConvertTo-Json -Depth 7 -Compress
}
finally {
    if (-not $keep -and $ownership.Ids.Count) { Remove-OwnedLimits }
    $results | Export-Csv (Join-Path $output 'Results.csv') -NoTypeInformation
    Get-WinEvent -FilterHashtable @{LogName=$telemetryLog; Id=9102,9121,9302; StartTime=$now} -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ToXml() } | ConvertTo-Json | Set-Content (Join-Path $output 'Telemetry.json')
}