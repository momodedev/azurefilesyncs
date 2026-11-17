function Initialize-ManualAfsExperiment {
    [CmdletBinding()]
    param(
        [string]$LocalPath = 'E:\filestosync',
        [string]$OutputPath = 'C:\ProgramData\AzureFileSyncOps'
    )

    $ErrorActionPreference = 'Stop'
    if ($script:ManualAfsExperiment -and $script:ManualAfsExperiment.LimitIds.Count) {
        throw 'Run Remove-ManualAfsLimits before initializing another experiment.'
    }
    if (-not (Test-Path -LiteralPath $LocalPath -PathType Container)) {
        throw "Endpoint directory '$LocalPath' does not exist."
    }
    $service = Get-Service FileSyncSvc
    if ($service.Status -ne 'Running') { throw 'FileSyncSvc must be Running.' }
    Import-Module 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll' -Force
    if (@(Get-StorageSyncNetworkLimit).Count) {
        throw 'Existing network limits found. Review them; this script will not replace them.'
    }
    $log = Get-WinEvent -ListLog 'Microsoft-FileSync-Agent/Telemetry'
    if (-not $log.IsEnabled) { throw 'The File Sync telemetry log is disabled.' }
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    $script:ManualAfsExperiment = [pscustomobject]@{
        RunId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
        LocalPath = $LocalPath
        OutputPath = $OutputPath
        LimitIds = @()
        Results = @()
        AttemptedPhases = @()
    }
    Write-Host 'Step 4 ready. Keep this administrator PowerShell session open.'
    Write-Host 'Use only on the dedicated lab host with no unrelated file writes or schedule changes.'
    $script:ManualAfsExperiment | Select-Object RunId, LocalPath, OutputPath
}

function Remove-ManualAfsLimits {
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'
    if (-not $script:ManualAfsExperiment) { throw 'Initialize the experiment first.' }
    $state = $script:ManualAfsExperiment
    foreach ($limit in @(Get-StorageSyncNetworkLimit)) {
        if ($state.LimitIds -contains [string]$limit.Id) {
            Remove-StorageSyncNetworkLimit -Id $limit.Id
        }
    }
    $remaining = @(Get-StorageSyncNetworkLimit)
    $state.LimitIds = @($remaining | Where-Object { $state.LimitIds -contains [string]$_.Id } | ForEach-Object { [string]$_.Id })
    if ($state.LimitIds.Count) { throw 'Some experiment limits could not be removed.' }
    Write-Host "Experiment limits removed. Total remaining server schedules: $($remaining.Count)."
}

function New-ManualAfsPhaseData {
    param([string]$Phase)

    $state = $script:ManualAfsExperiment
    $folder = Join-Path $state.LocalPath "$($state.RunId)-manual-$Phase"
    New-Item -Path $folder -ItemType Directory -ErrorAction Stop | Out-Null
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] (1MB)
    try {
        foreach ($fileIndex in 1..4) {
            $file = Join-Path $folder ('file-{0:D2}.bin' -f $fileIndex)
            $stream = [System.IO.File]::Open($file, 'CreateNew', 'Write', 'None')
            try {
                foreach ($blockIndex in 1..8) {
                    $random.GetBytes($buffer)
                    $stream.Write($buffer, 0, $buffer.Length)
                }
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $random.Dispose() }
    Write-Host "Created four 8-MiB files in $folder"
}

function Get-ManualAfsUploadResult {
    param([datetime]$Since, [string]$Phase)

    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-FileSync-Agent/Telemetry'
            Id = 9102
            StartTime = $Since
        } -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return }
        throw
    }
    $bytes = 0L
    $seconds = 0.0
    foreach ($event in $events) {
        $xml = [xml]$event.ToXml()
        $data = @{}
        foreach ($item in $xml.Event.EventData.Data) { $data[$item.Name] = $item.InnerText }
        if ($data.HResult -ne '0') {
            throw "Sync session failed with HResult '$($data.HResult)'. Inspect event 9102 before continuing."
        }
        if ([double]$data.TransferredBytes -le 0 -or [double]$data.UploadSyncBatchDataDurationMs -le 0) { continue }
        $bytes += [long]$data.TransferredBytes
        $seconds += [Math]::Max([double]$data.DurationSeconds, [double]$data.UploadSyncBatchDataDurationMs / 1000)
    }
    if ($bytes -gt 32MB) { throw 'More than 32 MiB uploaded. Unrelated traffic invalidates this isolated test.' }
    if ($bytes -eq 32MB -and $seconds -gt 0) {
        [pscustomobject]@{
            Phase = $Phase
            SessionUploadedBytes = $bytes
            SessionDurationSeconds = $seconds
            SessionUploadMbps = [Math]::Round($bytes * 8 / $seconds / 1000000, 3)
        }
    }
}

function Invoke-ManualAfsPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('baseline', 'throttled', 'recovery')][string]$Phase,
        [ValidateRange(1, 60)][int]$TimeoutMinutes = 15
    )

    $ErrorActionPreference = 'Stop'
    $state = $script:ManualAfsExperiment
    if (-not $state) { throw 'Run Initialize-ManualAfsExperiment first (step 4).' }
    $sequence = @('baseline', 'throttled', 'recovery')
    if ($state.Results.Count -ge 3 -or $sequence[$state.Results.Count] -ne $Phase) {
        throw 'Run phases in order: baseline, throttled, recovery.'
    }
    if ($state.AttemptedPhases -contains $Phase) {
        throw 'This phase was already attempted. Finish outstanding uploads, clean up, and initialize a new run.'
    }
    if ($Phase -eq 'recovery') { Remove-ManualAfsLimits }
    if (@(Get-StorageSyncNetworkLimit).Count) { throw 'Unexpected network schedules remain. Stop and review them.' }
    $state.AttemptedPhases += $Phase
    try {
        if ($Phase -eq 'throttled') {
            try {
                New-StorageSyncNetworkLimit -Day Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday `
                    -StartHour 0 -EndHour 0 -LimitKbps 500 | Out-Null
            }
            finally {
                $limits = @(Get-StorageSyncNetworkLimit)
                $state.LimitIds = @($limits | Where-Object {
                    $_.LimitKbps -eq 500 -and $_.StartHour -eq 0 -and $_.EndHour -eq 0
                } | ForEach-Object { [string]$_.Id })
            }
            if ($limits.Count -ne 7 -or $state.LimitIds.Count -ne 7) { throw 'Expected seven daily 500-Kbps limits.' }
            $limits | Format-Table Id, Day, StartHour, EndHour, LimitKbps | Out-Host
            $state.LimitIds | Set-Content -LiteralPath (Join-Path $state.OutputPath "$($state.RunId)-manual-limit-ids.txt")
        }
        $started = Get-Date
        New-ManualAfsPhaseData -Phase $Phase
        $deadline = $started.AddMinutes($TimeoutMinutes)
        do {
            $result = Get-ManualAfsUploadResult -Since $started -Phase $Phase
            if ($result) { break }
            Write-Host "Waiting for the complete 32-MiB $Phase upload; deadline $($deadline.ToString('HH:mm:ss'))."
            Start-Sleep -Seconds 10
        } while ((Get-Date) -lt $deadline)
        if (-not $result) { throw 'Upload telemetry timed out. Outstanding uploads can continue; do not start another phase.' }
        if ($Phase -eq 'throttled' -and ($result.SessionUploadMbps -le 0 -or $result.SessionUploadMbps -gt 0.625)) {
            throw "500-Kbps throttle not verified: observed $($result.SessionUploadMbps) Mbps."
        }
        if ($Phase -eq 'throttled' -and $state.Results[0].SessionUploadMbps -le $result.SessionUploadMbps) {
            throw 'The baseline was not faster than the throttled upload.'
        }
        if ($Phase -eq 'recovery' -and $result.SessionUploadMbps -le $state.Results[1].SessionUploadMbps) {
            throw 'Recovery was not faster than the throttled upload.'
        }
        $state.Results += $result
        $csv = Join-Path $state.OutputPath "$($state.RunId)-manual-results.csv"
        $state.Results | Export-Csv -LiteralPath $csv -NoTypeInformation
        $state.Results | Format-Table -AutoSize | Out-Host
        Write-Host "Phase verified. Results: $csv"
        if ($Phase -eq 'throttled') { Write-Host 'Limits remain active. Run recovery (step 7), or Remove-ManualAfsLimits to cancel.' }
        if ($Phase -eq 'recovery') { Write-Host 'AFSLAB_MANUAL_EXPERIMENT_STATUS=SUCCESS' }
    }
    catch {
        Remove-ManualAfsLimits
        throw
    }
}