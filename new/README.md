# Azure File Sync Throttle Lab

This lab targets subscription `95642268-5116-484d-9b88-7dfce8c20ce4`, tenant `0e478cd4-3e52-496d-ac3a-419ca58ba7ac`, existing resource group `rg-infra-winmig-apac-v-chengzhiz-poc`, and West US 2. Its `IAM-ReadOnly-Lock` has been removed; a `CanNotDelete` lock remains on a migration storage account. Do not remove that lock or delete the group as part of this lab. It uses the existing Windows Server 2025 Azure VM directly with Azure File Sync and Azure Files public endpoints. It creates no private endpoints, private DNS zones, service endpoints, VPN, or ExpressRoute resources.

Microsoft documents that Azure File Sync uses outbound HTTPS for FileREST and sync traffic. See [Azure File Sync networking](https://learn.microsoft.com/azure/storage/file-sync/file-sync-networking-overview).

## Deployment Gate

The deployment script checks the target group for a `ReadOnly` lock before running Bicep what-if or creating resources. The cloud-only deployment has succeeded, creating the storage account, SMB share, Storage Sync service, sync group, and managed-identity role assignments. The host remains gated on a matching cloud endpoint reaching ARM state `Succeeded`. The host uses `infra/host.bicep`, which references the existing Sync Service and pre-created lab network resources. Pass `-SkipCloudEndpointCreation` to require reuse of the existing endpoint and prevent another endpoint request.

## Current Deployment Status

The cloud endpoint for storage account `afspqipi42iyfdsq` and share `syncpqipi42iyfdsq` is `Succeeded`; its generated ARM name is `095a7002-794a-47b0-8c5a-fe73f578877f`. Windows Server 2025 VM `afshpqipi42iyfdsq` is registered using its system-assigned managed identity. Its server endpoint uses `E:\filestosync`. Historical failed cloud-endpoint diagnostics are retained under `diagnostics`.

The completed full experiment uploaded 32 MiB in each phase. Successful event 9102 sessions report baseline and recovery durations of 2 seconds each (134.218 Mbps) and a throttled duration of 525 seconds (0.511 Mbps, approximately the configured 500 Kbps). No network limits remained afterward. Final endpoint upload/download health was Healthy with zero persistent failures, and the VM was deallocated to stop compute charges. See [verified results](diagnostics/latest-host-throttle-experiment.txt). The revised telemetry parser was replayed against the completed run; a second full workload was not needed. Counter-derived rates in the original VM CSV are diagnostic only and were not used to validate the throttle.

Checks confirm `useIdentity=true`, the correct Contoso tenant, the documented account/share roles, an existing SMB share, and `incomingTrafficPolicy=AllowAllTraffic`. The storage account reports `publicNetworkAccess=Enabled`, `allowSharedKeyAccess=true`, `defaultAction=Allow`, and no IP/VNet restrictions. The deployment script now discovers cloud endpoints by matching the storage account resource ID and share name, because Azure assigns the endpoint its own generated ARM name. Pass `-SkipCloudEndpointCreation` to require and reuse the existing succeeded endpoint without issuing another cloud endpoint write.

The prior authorization failure is retained for diagnosis, but the portal-created replacement endpoint is now provisioned. The script discovers endpoints by matching the storage account resource ID and share name because Azure assigns each endpoint a generated ARM name. The host-only template does not redeploy storage, share metadata, or Sync Service roles. The `-SkipCloudEndpointCreation` switch fails closed if no matching succeeded endpoint is found and never removes or replaces an endpoint.

The host uses `Standard_D4s_v6` in West US 2. The current workflow uses this VM directly; it does not require the previously created nested VM shell or interactive Windows setup.

## Run

From an Azure CLI session authenticated to the Contoso tenant and requested subscription:

```powershell
az login --tenant 0e478cd4-3e52-496d-ac3a-419ca58ba7ac
az account set --subscription 95642268-5116-484d-9b88-7dfce8c20ce4
.\new\scripts\Configure-ExistingHostAfs.ps1
```

The host workflow uses the VM's system-assigned identity for Azure authentication and Azure Run Command for guest configuration. It does not need the local Administrator password. It initializes the lab data disk only if unformatted, installs the File Sync agent, registers the host, creates an endpoint at `E:\filestosync` if one is not already present, and runs baseline, 500-Kbps, and recovery phases. Managed-identity configuration must already be complete, as it is for this host. For a newly registered server, an authorized operator must configure the Storage Sync Service identity before rerunning initialization; the guest identity is not granted role-assignment management permissions. On success the orchestrator saves the command output under `new/diagnostics` and deallocates the VM unless `-KeepVmRunning` is specified.

The host data disk is NTFS-formatted only if it is RAW or has no file system. Existing formatted data is preserved. The experiment creates test files under `E:\filestosync` and writes CSV results on the VM under `C:\ProgramData\AzureFileSyncOps`.

The run takes roughly 30 minutes at the default 120 five-second samples per phase. It requires successful session telemetry confirming complete uploads, throttled throughput within 25 percent above the configured limit, and faster baseline/recovery throughput. Low limits or larger datasets can require a longer measurement window. Performance-counter fields are retained with a `Counter` prefix for diagnosis, not throttle validation. The script does not reset or unregister a server and does not create a nested VM.

## Manual Experiment Runbook

Use this procedure on the existing lab VM. Do not redeploy the lab, recreate endpoints, or use the nested VM. The VM was deallocated after the last verified experiment. Starting it incurs compute charges.

Choose either the fully manual phases below or the existing-script alternative at the end. Do not run both simultaneously. The manual procedure does not require the experiment script to be copied to the VM.

### 1. Start the VM from your PC

In Azure Portal, select subscription `95642268-5116-484d-9b88-7dfce8c20ce4`, resource group `rg-infra-winmig-apac-v-chengzhiz-poc`, and VM `afshpqipi42iyfdsq`. Select **Start** and wait for **Running**.

Alternatively, run these commands in PowerShell on your PC, not inside the VM:

```powershell
Connect-AzAccount -Tenant '0e478cd4-3e52-496d-ac3a-419ca58ba7ac'
Set-AzContext -Subscription '95642268-5116-484d-9b88-7dfce8c20ce4'
$resourceGroup = 'rg-infra-winmig-apac-v-chengzhiz-poc'
$vmName = 'afshpqipi42iyfdsq'
Start-AzVM -ResourceGroupName $resourceGroup -Name $vmName
```

The PowerShell alternative requires the Az.Accounts and Az.Compute modules and an operator account authorized to start the VM and invoke Run Command. Portal operation does not require these modules on your PC.

### 2. Verify endpoints and connect to Windows

In Portal, open Storage Sync service `afsspqipi42iyfdsq`, then sync group `afsgpqipi42iyfdsq`. Confirm the cloud endpoint for share `syncpqipi42iyfdsq` and server endpoint `afshpqipi42iyfd` are provisioned. The server endpoint path must be `E:\filestosync`. Allow time after startup for the server heartbeat and health to refresh; do not recreate an endpoint just because its status is initially stale.

Open the VM's **Connect > Native RDP** page and connect using your Windows administrator account. Enter credentials only in the RDP credential dialog. The deployed computer name is truncated to `afshpqipi42iyfd`; the Azure VM resource name has the final `sq`. Inbound RDP is restricted to the configured operator public IP. If your IP changed, have the authorized operator update that specific `/32` rule; do not open RDP to the internet.

Inside the VM, open **Windows PowerShell as Administrator**. Run steps 3 through 8 in this same VM PowerShell session. These guest commands do not require Azure login or the Az modules.

### 3. Check the agent, disk, and existing limits

```powershell
$ErrorActionPreference = 'Stop'
hostname
Get-Volume -DriveLetter E
Test-Path 'E:\filestosync'
Get-Service FileSyncSvc
Import-Module 'C:\Program Files\Azure\StorageSyncAgent\StorageSync.Management.ServerCmdlets.dll'
$existingLimits = @(Get-StorageSyncNetworkLimit)
$existingLimits | Format-Table Id, Day, StartHour, EndHour, LimitKbps
if ($existingLimits.Count -gt 0) {
	throw 'Existing limits found. Stop and review them before changing the schedule.'
}
```

Expect NTFS on `E:`, `True` for the endpoint directory, a Running FileSyncSvc service, and no existing limits. Do not format disks or delete existing data. Stop other test writers and avoid unrelated uploads during this experiment, since session telemetry describes endpoint activity, not just individual test files. This is a dedicated lab procedure; network limits apply to all Azure File Sync traffic subject to throttling on this registered server.

### Executable Commands for Steps 4-7

The reusable [manual experiment script](scripts/Manual-AfsThrottleExperiment.ps1) implements steps 4-7 with automatic completion checks. It is an alternative to entering the individual helper blocks below, not an additional experiment. Run everything here in the same **administrator Windows PowerShell session inside the Windows Server VM**. Do not run these commands on your PC: they access the local AFS agent and sync directory.

To access the workspace script inside RDP without installing it on the VM, enable your PC's C: drive under the RDP client's **Show Options > Local Resources > More > Drives** before connecting. The redirected drive appears as `\\tsclient\C`. Drive redirection might be disabled by organizational policy; in that case, use an approved file-transfer method to make the script accessible on the VM and adjust `$manualScript` accordingly.

**Step 4: load the functions and initialize a run.** The leading dot followed by a space is required; it loads the functions into the current session. Loading the file alone does not start any experiment.

```powershell
$manualScript = '\\tsclient\C\Users\v-chengzhiz\OneDrive - Microsoft\Documents\azurefilesyncs\new\scripts\Manual-AfsThrottleExperiment.ps1'
. $manualScript
Initialize-ManualAfsExperiment
```

Initialization checks the endpoint directory, running FileSyncSvc service, readable enabled telemetry log, and absence of network limits. It creates a unique run ID and output directory but generates no test files and changes no network schedules. Keep the printed run ID for identifying results. Leave this PowerShell window open: phase state is held in this session. Do not initialize a second run while another phase is active or outstanding uploads remain.

**Step 5: generate and verify the baseline.**

```powershell
Invoke-ManualAfsPhase -Phase baseline -TimeoutMinutes 15
```

This creates four random 8-MiB files, checks event 9102 every ten seconds, and returns only after successful completed upload sessions account for exactly 33,554,432 bytes. It displays the baseline throughput and writes `<runId>-manual-results.csv` under `C:\ProgramData\AzureFileSyncOps`. Waiting occurs inside the function; no separate telemetry query is required. Do not start step 6 until this command returns with `Phase verified`.

**Step 6: apply the limit, generate files, and verify throttling.**

```powershell
Invoke-ManualAfsPhase -Phase throttled -TimeoutMinutes 15
Get-StorageSyncNetworkLimit | Format-Table Id, Day, StartHour, EndHour, LimitKbps
```

This requires a successful baseline. It creates and displays seven 24-hour 500-Kbps schedule entries, records their IDs, generates another 32-MiB dataset, and waits for completed upload telemetry. Expect about nine minutes of transfer time plus sync scheduling delay. Verification requires positive session throughput no greater than 0.625 Mbps (25 percent tolerance above 500 Kbps) and a faster baseline. Slower throughput can have other causes, so also inspect the displayed schedule and compare recovery.

On success, the limits intentionally remain active until step 7. IDs are saved in `<runId>-manual-limit-ids.txt` under the output directory so you can identify the test schedules if the session is lost. No unrelated operator should change schedules during this dedicated-lab test.

**Step 7: remove the test limits and verify recovery.**

```powershell
Invoke-ManualAfsPhase -Phase recovery -TimeoutMinutes 15
@(Get-StorageSyncNetworkLimit).Count
```

This removes schedules matching the recorded test IDs, requires no schedules to remain, generates the final 32-MiB dataset, and verifies complete successful uploads faster than the throttled phase. Expected final output is a three-row result table, `AFSLAB_MANUAL_EXPERIMENT_STATUS=SUCCESS`, and a remaining schedule count of `0`. Continue with the independent cloud-file and endpoint-health checks in step 8, then deallocate the VM using step 9.

**Cancel or recover from a failed phase.**

```powershell
Remove-ManualAfsLimits
Get-StorageSyncNetworkLimit | Format-Table Id, Day, StartHour, EndHour, LimitKbps
```

Ordinary phase errors attempt this cleanup automatically. Use the command explicitly if you cancel or stop after step 6. Forced process termination, closing PowerShell, or stopping the VM can bypass cleanup and lose in-memory state. If that happens, inspect the saved limit-ID file for this run, compare those IDs with `Get-StorageSyncNetworkLimit`, and remove only matching test IDs with `Remove-StorageSyncNetworkLimit -Id <ID>`. Do not reinitialize to try to recover lost phase state.

A failed or timed-out phase cannot be retried under the same run ID, preventing duplicate files and overlapping measurements. First clean up its limits, let any outstanding uploads finish, resolve the error, and initialize a new run. Existing phase CSV results and generated files remain available. No telemetry events, a failed session, excess upload bytes from unrelated writers, or a slower recovery prevents a success verdict. Neither this helper nor the manual commands deallocate the VM automatically.

### 4. Define the manual data and telemetry helpers

Run the following block once inside the VM. It defines helpers only; it does not apply a throttle. Every phase creates four random 8-MiB files, totaling 32 MiB. Random content avoids misleading compression effects.

```powershell
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputPath = 'C:\ProgramData\AzureFileSyncOps'
New-Item $outputPath -ItemType Directory -Force | Out-Null

function New-ManualAfsData {
	param([string]$Phase)
	$folder = Join-Path 'E:\filestosync' "$runId-manual-$Phase"
	New-Item $folder -ItemType Directory -ErrorAction Stop | Out-Null
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
	Get-ChildItem $folder | Select-Object Name, Length
}

function Get-ManualAfsSessions {
	param([datetime]$Since, [string]$Phase)
	$events = @(Get-WinEvent -FilterHashtable @{
		LogName = 'Microsoft-FileSync-Agent/Telemetry'
		Id = 9102
		StartTime = $Since
	} -ErrorAction SilentlyContinue)
	foreach ($event in $events) {
		$eventXml = [xml]$event.ToXml()
		$data = @{}
		foreach ($item in $eventXml.Event.EventData.Data) {
			$data[$item.Name] = $item.InnerText
		}
		if ([double]$data.TransferredBytes -le 0 -or
			[double]$data.UploadSyncBatchDataDurationMs -le 0) { continue }
		$seconds = [Math]::Max(
			[double]$data.DurationSeconds,
			[double]$data.UploadSyncBatchDataDurationMs / 1000
		)
		[pscustomobject]@{
			Phase = $Phase
			Time = $event.TimeCreated
			HResult = $data.HResult
			Bytes = [long]$data.TransferredBytes
			Seconds = $seconds
			Mbps = [Math]::Round([double]$data.TransferredBytes * 8 / $seconds / 1000000, 3)
		}
	}
}
```

The telemetry helper includes failed sessions so you can see their HResult rather than silently treating them as successful uploads. No output can mean no completed upload yet; verify the event log is accessible before assuming that is the cause.

### 5. Run the unthrottled baseline

```powershell
$baselineStart = Get-Date
New-ManualAfsData -Phase 'baseline'
```

Expect four files, each 8,388,608 bytes. Wait for sync, then run:

```powershell
$baseline = @(Get-ManualAfsSessions -Since $baselineStart -Phase 'baseline')
$baseline | Format-Table -AutoSize
```

Repeat the telemetry query until successful upload sessions account for all 33,554,432 bytes. On this isolated lab, the previous run produced one data-bearing upload session. If the upload is split across sessions, sum successful session bytes and durations; do not average their Mbps values. Do not proceed while the phase is still uploading. Record the baseline results before creating another phase's files.

### 6. Apply 500 Kbps and run the throttled upload

```powershell
$manualLimits = @(New-StorageSyncNetworkLimit `
	-Day Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday `
	-StartHour 0 -EndHour 0 -LimitKbps 500)
Get-StorageSyncNetworkLimit | Format-Table Id, Day, StartHour, EndHour, LimitKbps
$throttledStart = Get-Date
New-ManualAfsData -Phase 'throttled'
```

Confirm seven daily schedule entries, all at 500 Kbps. Both hours set to zero means a full 24-hour schedule, not a zero-length window. This setting is kilobits per second, not kilobytes per second.

Wait for the upload to finish, querying periodically:

```powershell
$throttled = @(Get-ManualAfsSessions -Since $throttledStart -Phase 'throttled')
$throttled | Format-Table -AutoSize
```

A 32-MiB payload at exactly 500 Kbps takes about 537 seconds, nearly 9 minutes, before scheduling and protocol effects. Allow roughly 10-12 minutes and longer if sync starts late. A completed event may not appear until the transfer finishes. Verify HResult `0` and successful uploaded bytes totaling 33,554,432 before proceeding. The prior run took 525 seconds and measured 0.511 Mbps. Small deviations from 0.500 Mbps are expected; instantaneous performance-counter spikes are not proof that the throttle is broken.

### 7. Remove the limit and verify recovery

The preflight required no pre-existing limits, so the limits present should be the ones created by this manual test. Do not remove unrelated schedules if another operator added any during the experiment.

```powershell
Get-StorageSyncNetworkLimit | ForEach-Object {
	Remove-StorageSyncNetworkLimit -Id $_.Id
}
if (@(Get-StorageSyncNetworkLimit).Count -ne 0) {
	throw 'Network limits remain; resolve cleanup before continuing.'
}
$recoveryStart = Get-Date
New-ManualAfsData -Phase 'recovery'
```

Wait for sync, then query and record recovery before any additional writes:

```powershell
$recovery = @(Get-ManualAfsSessions -Since $recoveryStart -Phase 'recovery')
$recovery | Format-Table -AutoSize
@($baseline) + @($throttled) + @($recovery) |
	Export-Csv (Join-Path $outputPath "$runId-manual-sessions.csv") -NoTypeInformation
Get-StorageSyncNetworkLimit
```

Expect no remaining limits, successful complete recovery uploads, and recovery substantially faster than the throttled phase. Do not add `-Confirm` to `Remove-StorageSyncNetworkLimit`; that cmdlet does not support it.

### 8. Independently verify the result

Use all of these checks, not just a success message:

- **Local files:** each phase directory has four 8-MiB files. Total new payload across phases is 96 MiB.
- **Cloud files:** in Portal, open storage account `afspqipi42iyfdsq`, **File shares > syncpqipi42iyfdsq > Browse**. Find the three directories beginning with your `$runId`, each containing `file-01.bin` through `file-04.bin` with matching lengths. Portal browsing requires your operator's data access permissions; do not enable account keys or broaden public access to bypass an authorization error.
- **Telemetry:** HResult is `0`, each phase uploaded the full dataset, throttled session throughput is near 0.500 Mbps, and baseline/recovery are faster. For multiple upload sessions, calculate throughput as total successful bytes times 8 divided by total duration seconds divided by 1,000,000. Treat unrelated traffic or overlapping phases as an invalid comparison.
- **Endpoint health:** Storage Sync service > sync group > server endpoint reports healthy upload/download and zero persistent sync failures. Azure Monitor/portal health can lag; local completed-session telemetry is the immediate check.
- **Cleanup:** `@(Get-StorageSyncNetworkLimit).Count` is `0`.

For stronger content validation, download one test file using the portal's authenticated file browser and compare its SHA-256 with `Get-FileHash` on the corresponding VM file. Matching length alone is not a content-integrity check.

Previous verified full-run reference, not a guaranteed speed for every rerun:

| Phase | Uploaded Bytes | Session Seconds | Session Mbps |
| --- | ---: | ---: | ---: |
| Baseline | 33,554,432 | 2 | 134.218 |
| 500-Kbps limit | 33,554,432 | 525 | 0.511 |
| Recovery | 33,554,432 | 2 | 134.218 |

The old full-run CSV on the VM contains misleading counter-derived rates. Do not use its `AverageWindowUploadMbps` or `AverageActiveUploadMbps` values as the throttle verdict. New script runs use `SessionUploadMbps`, `SessionUploadedBytes`, and `SessionDurationSeconds`; `Counter*` fields are diagnostic only. Very short baseline durations also make their Mbps values approximate.

### 9. Stop compute charges

First verify all uploads and network-limit cleanup. Then disconnect RDP and use **Stop** in the Azure VM's portal Overview, confirming the final state is **Stopped (deallocated)**. Shutting down Windows alone can leave the VM allocated and billed.

Alternatively, from your PC's authenticated Az PowerShell session:

```powershell
Stop-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force
(Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Status).Statuses |
	Where-Object Code -Like 'PowerState/*'
```

Expect `PowerState/deallocated`. Do not delete the VM, endpoints, or resource group. Disks and storage still incur charges. Test files are intentionally retained; deleting them from the sync root later also deletes the corresponding cloud files through sync.

### Existing-script alternative

To reproduce the automated measurement with manual launch and inspection, perform steps 1-2, then run this from your PC at the workspace root. RDP and the Windows password are not needed for this alternative:

```powershell
$resourceGroup = 'rg-infra-winmig-apac-v-chengzhiz-poc'
$vmName = 'afshpqipi42iyfdsq'
$scriptPath = (Resolve-Path '.\new\scripts\Run-NestedAfsThrottleExperiment.ps1').Path
$parameters = @{
	SamplesPerPhase = '120'
	FileSizeMiB = '32'
	LimitKbps = '500'
	LocalPath = 'E:\filestosync'
}
$result = Invoke-AzVMRunCommand -ResourceGroupName $resourceGroup -VMName $vmName `
	-CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $parameters
$result.Value | Select-Object Code, Message | Format-List
```

Allow about 30 minutes plus Run Command overhead; output can stay quiet until completion. Do not submit another guest Run Command while this one is active. The script removes all existing AFS network limits, so use it only on this dedicated lab with no schedules to preserve. It creates unique phase directories and attempts throttle cleanup in `finally`, but a forced process termination or VM stop can bypass cleanup. Always verify limits afterward if interrupted.

Expect `AFSLAB_EXPERIMENT_STATUS=SUCCESS` and three phase results. An Azure command exit code of zero alone is insufficient; inspect returned StdErr and the experiment marker. The direct invocation above does not automatically deallocate the VM. Use steps 8-9 after verification. The existing orchestrator performs extra setup and is unnecessary for a manual experiment on this already configured host.

The script writes results and event CSVs under `C:\ProgramData\AzureFileSyncOps` on the VM, not automatically on your PC. To inspect its newest CSV inside the VM:

```powershell
$latestCsv = Get-ChildItem 'C:\ProgramData\AzureFileSyncOps' -Filter '*-results.csv' |
	Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
Import-Csv $latestCsv.FullName |
	Format-Table Phase, ConfiguredLimitKbps, SessionUploadMbps, SessionUploadedBytes, SessionDurationSeconds
```

If the test reports `NO_UPLOAD`, let outstanding uploads finish and investigate telemetry/endpoint health before rerunning. A 32-MiB upload at 500 Kbps barely fits a ten-minute phase if there is a startup delay; use `SamplesPerPhase='180'` for 15-minute phases if necessary. Do not increase file size without extending the phase duration. For `THROTTLE_NOT_VERIFIED` or `RECOVERY_NOT_VERIFIED`, inspect successful event 9102 sessions, schedule entries, unrelated workloads, and completion of each phase before accepting any throughput figure.

References: [Microsoft network-limit guidance](https://learn.microsoft.com/azure/storage/file-sync/file-sync-server-registration#manage-azure-file-sync-network-and-storage-usage) and [monitoring, event 9102, and performance counters](https://learn.microsoft.com/azure/storage/file-sync/file-sync-monitoring).

## Cost and Cleanup

The Windows `Standard_D4s_v6` host compute rate is approximately `$0.386/hour` in West US 2. Four running hours are about `$1.54` for compute, excluding the OS/data disks, public IP, Azure Files storage/transactions, and network egress. Deallocating the VM stops compute charges but doesn't remove disk, IP, storage, or sync-service charges.

Do not delete the requested migration resource group: it contains unrelated migration and network resources and has management locks. To inventory only this lab before cleanup, list the resources bearing its purpose tag and review each resource ID:

```powershell
az resource list --resource-group rg-infra-winmig-apac-v-chengzhiz-poc --subscription 95642268-5116-484d-9b88-7dfce8c20ce4 --query "[?tags.purpose=='AzureFileSyncNestedThrottleLab'].{name:name,type:type,id:id}" --output table
```