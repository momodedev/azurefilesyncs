#requires -Version 5.1 
#requires -RunAsAdministrator 
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')] 
param( 
    [Parameter(Mandatory)] [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')] [string[]]$Days, 
    [Parameter(Mandatory)] [ValidateRange(0,23)] [int]$StartHour, 
    [Parameter(Mandatory)] [ValidateRange(0,23)] [int]$EndHour, 
    [Parameter(Mandatory)] [ValidateRange(1,100000000)] [int]$LimitKbps, 
    [switch]$RemoveAllExisting, 
    [string]$OperationsDirectory='C:\ProgramData\AzureFileSyncOps\Changes' 
) 
Set-StrictMode -Version Latest 
$ErrorActionPreference='Stop' 
$modulePath='C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll' 
$runDirectory=Join-Path $OperationsDirectory (Get-Date -Format 'yyyyMMdd-HHmmss') 
New-Item -Path $runDirectory -ItemType Directory -Force -WhatIf:$false | Out-Null 
function Write-Log([string]$Message,[ValidateSet('INFO','WARNING','ERROR')][string]$Level='INFO') { 
    $line='{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message 
    Write-Host $line; Add-Content (Join-Path $runDirectory 'Change.log') $line -Encoding UTF8 -WhatIf:$false 
} 
try { 
    if (-not (Test-Path $modulePath -PathType Leaf)) { throw "Azure File Sync module not found: $modulePath" } 
    Import-Module $modulePath -Force -ErrorAction Stop 
    foreach($cmd in 'Get-StorageSyncNetworkLimit','New-StorageSyncNetworkLimit','Remove-StorageSyncNetworkLimit') { if(-not(Get-Command $cmd -ErrorAction SilentlyContinue)){throw "Required command unavailable: $cmd"} } 
    if ((Get-Service FileSyncSvc -ErrorAction Stop).Status -ne 'Running') { throw 'FileSyncSvc is not running.' } 
    $existing=@(Get-StorageSyncNetworkLimit -ErrorAction Stop) 
    [pscustomobject]@{CapturedAt=Get-Date;ComputerName=$env:COMPUTERNAME;Count=$existing.Count;Limits=$existing} | Export-Clixml (Join-Path $runDirectory 'Before-Limits.xml') -WhatIf:$false 
    $existing | Format-List * | Out-String | Set-Content (Join-Path $runDirectory 'Before-Limits.txt') -Encoding UTF8 -WhatIf:$false 
    if($existing.Count -gt 0 -and -not $RemoveAllExisting){throw 'Existing limits detected. Review them first or rerun with -RemoveAllExisting only under approved change control.'} 
    if($RemoveAllExisting){ 
        foreach($item in $existing){ 
            if(-not($item.PSObject.Properties.Name -contains 'Id')){throw 'Existing limit object has no Id property; automatic removal stopped.'} 
            if($PSCmdlet.ShouldProcess("Network limit ID $($item.Id)",'Remove')){Remove-StorageSyncNetworkLimit -Id $item.Id -ErrorAction Stop} 
        } 
        if($WhatIfPreference){Write-Log 'WhatIf: removal simulated; post-removal verification skipped.'}else{$removedIds=@($existing|ForEach-Object{$_.Id}); $remaining=@(Get-StorageSyncNetworkLimit|Where-Object{$removedIds -contains $_.Id}); if($remaining.Count -gt 0){throw "$($remaining.Count) existing limit(s) remain after removal."}} 
    } 
    $requested=[pscustomobject]@{Days=$Days;StartHour=$StartHour;EndHour=$EndHour;LimitKbps=$LimitKbps} 
    $requested | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $runDirectory 'RequestedPolicy.json') -Encoding UTF8 -WhatIf:$false 
    if($PSCmdlet.ShouldProcess($env:COMPUTERNAME,"Create network limit: $($Days -join ',') $StartHour-$EndHour $LimitKbps Kbps")){ 
        New-StorageSyncNetworkLimit -Day $Days -StartHour $StartHour -EndHour $EndHour -LimitKbps $LimitKbps -ErrorAction Stop | Format-List * | Out-String | Set-Content (Join-Path $runDirectory 'NewPolicyCommandOutput.txt') -Encoding UTF8 -WhatIf:$false 
    } 
    $effective=@(Get-StorageSyncNetworkLimit -ErrorAction Stop) 
    $effective | Export-Clixml (Join-Path $runDirectory 'After-Limits.xml') -WhatIf:$false 
    $effective | Format-List * | Out-String | Set-Content (Join-Path $runDirectory 'After-Limits.txt') -Encoding UTF8 -WhatIf:$false 
    if($WhatIfPreference){Write-Log 'WhatIf: no configuration was changed.'}elseif($effective.Count -eq 0){throw 'Verification failed: no effective policy was returned.'} 
    if((Get-Service FileSyncSvc).Status -ne 'Running'){throw 'FileSyncSvc is not running after the change.'} 
    if(-not $WhatIfPreference){Write-Log 'Change completed. Review After-Limits.txt and portal health.'}else{Write-Log 'WhatIf run completed. Review Before-Limits.txt and RequestedPolicy.json.'} 
    [pscustomobject]@{Result='SUCCESS';ComputerName=$env:COMPUTERNAME;Days=$Days -join ',';StartHour=$StartHour;EndHour=$EndHour;LimitKbps=$LimitKbps;EvidenceLocation=$runDirectory} 
} catch { Write-Log $_.Exception.Message ERROR; throw } 