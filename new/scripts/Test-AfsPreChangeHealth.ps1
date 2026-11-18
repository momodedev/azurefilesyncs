#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Performs local Azure File Sync pre-change health checks before applying
    or changing StorageSyncNetworkLimit policies.

.DESCRIPTION
    Validates the Azure File Sync management module and cmdlets, FileSyncSvc,
    StorageSync and StorageSyncGuard filter drivers, registered-server state,
    reboot requirement, built-in diagnostics, network connectivity, current
    network-limit configuration, recent telemetry events, and performance
    counter availability.

    This script performs local validation only. Before approving a Production
    change, also verify in the Azure portal that the registered server is
    Online, the server endpoint is Healthy, persistent sync errors are zero,
    and the synchronization backlog is acceptable.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [int]$EventLookbackHours = 24,

    [string]$OutputDirectory =
        'C:\ProgramData\AzureFileSyncOps\HealthChecks',

    [switch]$SkipNetworkConnectivityTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath =
    'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll'

$telemetryLog = 'Microsoft-FileSync-Agent/Telemetry'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path $OutputDirectory $timestamp

New-Item `
    -Path $runDirectory `
    -ItemType Directory `
    -Force | Out-Null

$results = [System.Collections.Generic.List[object]]::new()

function Add-CheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'WARNING', 'FAIL', 'INFO')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Details,

        [bool]$Blocking = $false
    )

    $results.Add(
        [pscustomobject]@{
            Time     = Get-Date
            Check    = $Check
            Status   = $Status
            Blocking = $Blocking
            Details  = $Details
        }
    )
}

# -----------------------------------------------------------------------------
# 1. Operating system and PowerShell context
# -----------------------------------------------------------------------------
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem

    Add-CheckResult `
        -Check 'Operating system' `
        -Status 'INFO' `
        -Details (
            '{0}; Version {1}; Build {2}; PowerShell {3}' -f `
            $os.Caption,
            $os.Version,
            $os.BuildNumber,
            $PSVersionTable.PSVersion
        )
}
catch {
    Add-CheckResult `
        -Check 'Operating system' `
        -Status 'WARNING' `
        -Details $_.Exception.Message
}

# -----------------------------------------------------------------------------
# 2. Azure File Sync management module
# -----------------------------------------------------------------------------
$moduleImported = $false

if (Test-Path -LiteralPath $modulePath -PathType Leaf) {
    try {
        Import-Module $modulePath -Force -ErrorAction Stop
        $moduleImported = $true

        Add-CheckResult `
            -Check 'Azure File Sync management module' `
            -Status 'PASS' `
            -Details $modulePath
    }
    catch {
        Add-CheckResult `
            -Check 'Azure File Sync management module' `
            -Status 'FAIL' `
            -Details $_.Exception.Message `
            -Blocking $true
    }
}
else {
    Add-CheckResult `
        -Check 'Azure File Sync management module' `
        -Status 'FAIL' `
        -Details "Module not found: $modulePath" `
        -Blocking $true
}

# -----------------------------------------------------------------------------
# 3. Required Azure File Sync commands
# -----------------------------------------------------------------------------
$requiredCommands = @(
    'Get-StorageSyncNetworkLimit',
    'New-StorageSyncNetworkLimit',
    'Remove-StorageSyncNetworkLimit',
    'Debug-StorageSyncServer'
)

foreach ($commandName in $requiredCommands) {
    $command = Get-Command `
        -Name $commandName `
        -ErrorAction SilentlyContinue

    if ($null -ne $command) {
        Add-CheckResult `
            -Check "Command $commandName" `
            -Status 'PASS' `
            -Details (
                '{0} from {1}' -f `
                $command.CommandType,
                $command.Source
            )
    }
    else {
        Add-CheckResult `
            -Check "Command $commandName" `
            -Status 'FAIL' `
            -Details 'Command not available after module import.' `
            -Blocking $true
    }
}

# -----------------------------------------------------------------------------
# 4. Storage Sync Agent service
# -----------------------------------------------------------------------------
try {
    $service = Get-CimInstance `
        -ClassName Win32_Service `
        -Filter "Name='FileSyncSvc'"

    if ($null -eq $service) {
        throw 'FileSyncSvc was not found.'
    }

    if ($service.State -eq 'Running') {
        Add-CheckResult `
            -Check 'Storage Sync Agent service' `
            -Status 'PASS' `
            -Details (
                'State={0}; StartMode={1}' -f `
                $service.State,
                $service.StartMode
            )
    }
    else {
        Add-CheckResult `
            -Check 'Storage Sync Agent service' `
            -Status 'FAIL' `
            -Details (
                'State={0}; StartMode={1}' -f `
                $service.State,
                $service.StartMode
            ) `
            -Blocking $true
    }

    if ($service.StartMode -eq 'Auto') {
        Add-CheckResult `
            -Check 'Storage Sync Agent start mode' `
            -Status 'PASS' `
            -Details 'StartMode=Auto'
    }
    else {
        Add-CheckResult `
            -Check 'Storage Sync Agent start mode' `
            -Status 'WARNING' `
            -Details (
                'Current StartMode is {0}; review the service configuration.' -f `
                $service.StartMode
            )
    }
}
catch {
    Add-CheckResult `
        -Check 'Storage Sync Agent service' `
        -Status 'FAIL' `
        -Details $_.Exception.Message `
        -Blocking $true
}

# -----------------------------------------------------------------------------
# 5. Azure File Sync filter drivers
#    Corrected: avoids the previous Regex.Escape construction error.
# -----------------------------------------------------------------------------
try {
    $fltmcPath = Join-Path $env:SystemRoot 'System32\fltmc.exe'

    if (-not (Test-Path -LiteralPath $fltmcPath -PathType Leaf)) {
        throw "fltmc.exe was not found: $fltmcPath"
    }

    $fltmcOutput = @(
        & $fltmcPath filters 2>&1
    )

    $fltmcExitCode = $LASTEXITCODE

    if ($fltmcExitCode -ne 0) {
        throw "fltmc.exe returned exit code $fltmcExitCode."
    }

    $fltmcText = $fltmcOutput | Out-String

    $fltmcText |
        Set-Content `
            -LiteralPath (
                Join-Path $runDirectory 'fltmc-filters.txt'
            ) `
            -Encoding UTF8

    foreach ($driver in @(
        'StorageSync',
        'StorageSyncGuard'
    )) {
        # Match the first column exactly enough to avoid StorageSync also
        # matching only the StorageSyncGuard row.
        $driverPattern = (
            '(?im)^\s*' +
            [regex]::Escape($driver) +
            '\s+'
        )

        if ($fltmcText -match $driverPattern) {
            Add-CheckResult `
                -Check "Filter driver $driver" `
                -Status 'PASS' `
                -Details "$driver is loaded and listed by fltmc.exe." `
                -Blocking $false
        }
        else {
            Add-CheckResult `
                -Check "Filter driver $driver" `
                -Status 'FAIL' `
                -Details (
                    "$driver is not listed by fltmc.exe. " +
                    'Review fltmc-filters.txt.'
                ) `
                -Blocking $true
        }
    }
}
catch {
    Add-CheckResult `
        -Check 'Azure File Sync filter drivers' `
        -Status 'FAIL' `
        -Details $_.Exception.Message `
        -Blocking $true
}

# -----------------------------------------------------------------------------
# 6. Registered-server information and reboot state
#    Corrected: does not use [bool] on the string value "False".
# -----------------------------------------------------------------------------
if (Get-Command Get-StorageSyncServer -ErrorAction SilentlyContinue) {
    try {
        $serverInfo = Get-StorageSyncServer -ErrorAction Stop

        $serverInfo |
            Export-Clixml `
                -LiteralPath (
                    Join-Path $runDirectory 'StorageSyncServer.xml'
                )

        $serverInfo |
            Format-List * |
            Out-String |
            Set-Content `
                -LiteralPath (
                    Join-Path $runDirectory 'StorageSyncServer.txt'
                ) `
                -Encoding UTF8

        Add-CheckResult `
            -Check 'Azure File Sync registered-server information' `
            -Status 'PASS' `
            -Details (
                'ServerId={0}; AgentVersion={1}; AgentExpirationStatus={2}' -f `
                $serverInfo.ServerId,
                $serverInfo.AgentVersion,
                $serverInfo.AgentExpirationStatus
            ) `
            -Blocking $false

        if (
            $serverInfo.PSObject.Properties.Name -contains
            'RebootNeeded'
        ) {
            $rawRebootValue = $serverInfo.RebootNeeded
            $rebootRequired = $false

            if ($null -eq $rawRebootValue) {
                Add-CheckResult `
                    -Check 'Azure File Sync agent reboot state' `
                    -Status 'WARNING' `
                    -Details 'RebootNeeded was returned with a null value.' `
                    -Blocking $false
            }
            else {
                $parsed = [bool]::TryParse(
                    ([string]$rawRebootValue).Trim(),
                    [ref]$rebootRequired
                )

                if (-not $parsed) {
                    Add-CheckResult `
                        -Check 'Azure File Sync agent reboot state' `
                        -Status 'FAIL' `
                        -Details (
                            'Unable to interpret RebootNeeded value: ' +
                            "'$rawRebootValue'."
                        ) `
                        -Blocking $true
                }
                elseif ($rebootRequired) {
                    Add-CheckResult `
                        -Check 'Azure File Sync agent reboot state' `
                        -Status 'FAIL' `
                        -Details (
                            'Get-StorageSyncServer reports ' +
                            'RebootNeeded=True. Restart the server before ' +
                            'the Production change.'
                        ) `
                        -Blocking $true
                }
                else {
                    Add-CheckResult `
                        -Check 'Azure File Sync agent reboot state' `
                        -Status 'PASS' `
                        -Details (
                            'Get-StorageSyncServer reports ' +
                            'RebootNeeded=False.'
                        ) `
                        -Blocking $false
                }
            }
        }
        else {
            Add-CheckResult `
                -Check 'Azure File Sync agent reboot state' `
                -Status 'WARNING' `
                -Details (
                    'The installed Azure File Sync agent did not return ' +
                    'a RebootNeeded property.'
                ) `
                -Blocking $false
        }
    }
    catch {
        Add-CheckResult `
            -Check 'Azure File Sync registered-server information' `
            -Status 'FAIL' `
            -Details $_.Exception.Message `
            -Blocking $true
    }
}
else {
    Add-CheckResult `
        -Check 'Get-StorageSyncServer' `
        -Status 'FAIL' `
        -Details (
            'Get-StorageSyncServer is unavailable. Verify the Azure ' +
            'File Sync agent installation.'
        ) `
        -Blocking $true
}

# -----------------------------------------------------------------------------
# 7. Built-in Azure File Sync diagnostics
# -----------------------------------------------------------------------------
if (Get-Command Debug-StorageSyncServer -ErrorAction SilentlyContinue) {
    try {
        $diagnoseOutput = Debug-StorageSyncServer `
            -Diagnose `
            -ErrorAction Stop

        $diagnoseOutput |
            Out-String |
            Set-Content `
                -LiteralPath (
                    Join-Path $runDirectory 'Debug-Diagnose.txt'
                ) `
                -Encoding UTF8

        Add-CheckResult `
            -Check 'Debug-StorageSyncServer -Diagnose' `
            -Status 'PASS' `
            -Details (
                'Diagnostic command completed. Review Debug-Diagnose.txt.'
            )
    }
    catch {
        Add-CheckResult `
            -Check 'Debug-StorageSyncServer -Diagnose' `
            -Status 'FAIL' `
            -Details $_.Exception.Message `
            -Blocking $true
    }

    if (-not $SkipNetworkConnectivityTest) {
        try {
            $networkOutput = Debug-StorageSyncServer `
                -TestNetworkConnectivity `
                -ErrorAction Stop

            $networkOutput |
                Out-String |
                Set-Content `
                    -LiteralPath (
                        Join-Path $runDirectory 'Debug-Network.txt'
                    ) `
                    -Encoding UTF8

            Add-CheckResult `
                -Check 'Azure File Sync network connectivity' `
                -Status 'PASS' `
                -Details (
                    'Connectivity test completed. Review Debug-Network.txt.'
                )
        }
        catch {
            Add-CheckResult `
                -Check 'Azure File Sync network connectivity' `
                -Status 'FAIL' `
                -Details $_.Exception.Message `
                -Blocking $true
        }
    }
    else {
        Add-CheckResult `
            -Check 'Azure File Sync network connectivity' `
            -Status 'INFO' `
            -Details 'Connectivity test skipped by parameter.'
    }
}

# -----------------------------------------------------------------------------
# 8. Existing StorageSyncNetworkLimit configuration
# -----------------------------------------------------------------------------
try {
    $existingLimits = @(
        Get-StorageSyncNetworkLimit -ErrorAction Stop
    )

    [pscustomobject]@{
        CapturedAt   = Get-Date
        ComputerName = $env:COMPUTERNAME
        Count        = $existingLimits.Count
        Limits       = $existingLimits
    } |
        Export-Clixml `
            -LiteralPath (
                Join-Path $runDirectory 'ExistingNetworkLimits.xml'
            )

    $existingLimits |
        Format-List * |
        Out-String |
        Set-Content `
            -LiteralPath (
                Join-Path $runDirectory 'ExistingNetworkLimits.txt'
            ) `
            -Encoding UTF8

    Add-CheckResult `
        -Check 'Existing network-limit configuration' `
        -Status 'INFO' `
        -Details (
            '{0} existing limit record(s). Review exported configuration.' -f `
            $existingLimits.Count
        )
}
catch {
    Add-CheckResult `
        -Check 'Existing network-limit configuration' `
        -Status 'FAIL' `
        -Details $_.Exception.Message `
        -Blocking $true
}

# -----------------------------------------------------------------------------
# 9. Azure File Sync telemetry events
# -----------------------------------------------------------------------------
try {
    $logInfo = Get-WinEvent `
        -ListLog $telemetryLog `
        -ErrorAction Stop

    if ($logInfo.IsEnabled) {
        Add-CheckResult `
            -Check 'Azure File Sync Telemetry log' `
            -Status 'PASS' `
            -Details "$telemetryLog is enabled."
    }
    else {
        Add-CheckResult `
            -Check 'Azure File Sync Telemetry log' `
            -Status 'FAIL' `
            -Details "$telemetryLog exists but is disabled." `
            -Blocking $true
    }

    $startTime = (Get-Date).AddHours(-$EventLookbackHours)

    $events = @(
        Get-WinEvent `
            -FilterHashtable @{
                LogName   = $telemetryLog
                Id        = 9102, 9121, 9301, 9302
                StartTime = $startTime
            } `
            -ErrorAction SilentlyContinue
    )

    $events |
        Select-Object `
            TimeCreated,
            Id,
            LevelDisplayName,
            MachineName,
            Message |
        Export-Csv `
            -LiteralPath (
                Join-Path $runDirectory 'RecentTelemetryEvents.csv'
            ) `
            -NoTypeInformation `
            -Encoding UTF8

    foreach ($eventId in @(9102, 9121, 9301, 9302)) {
        $count = @(
            $events | Where-Object Id -eq $eventId
        ).Count

        switch ($eventId) {
            9121 {
                if ($count -gt 0) {
                    Add-CheckResult `
                        -Check 'Recent event ID 9121' `
                        -Status 'WARNING' `
                        -Details (
                            '{0} per-item-error event(s) in the last ' +
                            '{1} hour(s). Review RecentTelemetryEvents.csv.' -f `
                            $count,
                            $EventLookbackHours
                        )
                }
                else {
                    Add-CheckResult `
                        -Check 'Recent event ID 9121' `
                        -Status 'PASS' `
                        -Details (
                            'No per-item-error events in the last ' +
                            "$EventLookbackHours hour(s)."
                        )
                }
            }

            default {
                $status = if ($count -gt 0) {
                    'INFO'
                }
                else {
                    'WARNING'
                }

                Add-CheckResult `
                    -Check "Recent event ID $eventId" `
                    -Status $status `
                    -Details (
                        '{0} event(s) in the last {1} hour(s).' -f `
                        $count,
                        $EventLookbackHours
                    )
            }
        }
    }
}
catch {
    Add-CheckResult `
        -Check 'Azure File Sync Telemetry events' `
        -Status 'FAIL' `
        -Details $_.Exception.Message `
        -Blocking $true
}

# -----------------------------------------------------------------------------
# 10. Azure File Sync performance counters
# -----------------------------------------------------------------------------
foreach ($counterSet in @(
    'AFS Bytes Transferred',
    'AFS Sync Operations'
)) {
    try {
        $counter = Get-Counter `
            -ListSet $counterSet `
            -ErrorAction Stop

        Add-CheckResult `
            -Check "Performance counter set $counterSet" `
            -Status 'PASS' `
            -Details (
                '{0} counter(s) available.' -f `
                $counter.Paths.Count
            )
    }
    catch {
        Add-CheckResult `
            -Check "Performance counter set $counterSet" `
            -Status 'WARNING' `
            -Details $_.Exception.Message
    }
}

# -----------------------------------------------------------------------------
# 11. Final result and evidence export
# -----------------------------------------------------------------------------
$blockingFailures = @(
    $results |
        Where-Object {
            $_.Status -eq 'FAIL' -and $_.Blocking
        }
)

$warningCount = @(
    $results |
        Where-Object Status -eq 'WARNING'
).Count

$summary = [pscustomobject]@{
    ComputerName     = $env:COMPUTERNAME
    CompletedAt      = Get-Date
    OutputDirectory  = $runDirectory
    OverallResult    = if ($blockingFailures.Count -eq 0) {
        'GO-LOCAL-CHECKS-PASSED'
    }
    else {
        'NO-GO'
    }
    BlockingFailures = $blockingFailures.Count
    WarningCount     = $warningCount
}

$results |
    Export-Csv `
        -LiteralPath (
            Join-Path $runDirectory 'HealthCheckResults.csv'
        ) `
        -NoTypeInformation `
        -Encoding UTF8

$summary |
    ConvertTo-Json -Depth 4 |
    Set-Content `
        -LiteralPath (
            Join-Path $runDirectory 'HealthCheckSummary.json'
        ) `
        -Encoding UTF8

$results |
    Format-Table Status, Blocking, Check, Details -Wrap -AutoSize

$summary | Format-List

if ($blockingFailures.Count -gt 0) {
    throw (
        'Azure File Sync pre-change health check failed. ' +
        "Review: $runDirectory"
    )
}

Write-Warning @'
Local checks passed. Before approving the Production network-throttling
change, also confirm in the Azure portal that:

1. The registered server is Online.
2. The applicable server endpoint is Healthy.
3. Persistent sync errors are 0.
4. Event 9102 HResult and PerItemErrorCount are acceptable.
5. Event 9121 per-item errors have been investigated.
6. The synchronization backlog and completion forecast are acceptable.
'@

$summary
