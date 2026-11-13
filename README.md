# Azure File Sync throttle lab

This lab targets subscription `8d6bd1eb-ae31-4f2c-856a-0f8e47115c4b` and resource group `rgafslab2611` by default. Authenticate the Azure CLI to the corresponding tenant and subscription before running the scripts.

```powershell
.\scripts\Deploy-AfsLab.ps1 -PreviewOnly
.\scripts\Deploy-AfsLab.ps1
```

Review the what-if output before deployment. `-SkipSimulation` provisions the endpoints without running the experiment. The template preserves the existing Bastion subnet in this lab; review its subnet and network security group settings before using it in a different resource group.

The VM bootstrap uses the non-system disk at data LUN 0. The experiment removes all Azure File Sync network limits on the VM before and after its baseline, 5 Mbps, and recovery phases. Use it only on a dedicated lab server. Results and any available telemetry are written on the VM under `C:\ProgramData\AzureFileSyncOps`. Inspect the results for actual upload activity before drawing conclusions.

## Storage access

The lab parameters preserve the storage account settings selected in Azure: shared-key access and public network access are enabled. The current account permits access from all networks, subject to authorization. Review this exposure with the storage or security owner and restrict access when the lab permits it. The template defaults both settings to disabled for deployments that do not use the lab parameter file.

The cloud endpoint is `Canceled` after a controlled deletion and recreation again failed with `MgmtForbidden2` and `0x80C83034` at `newReplicaGroup`. Do not redeploy, retry the endpoint, add roles, or start the VM until the failure has been investigated. Normal deployment runs check the endpoint recorded by the previous deployment before issuing an ARM deployment; `-PreviewOnly` remains available for read-only inspection. The VM is deallocated, and the SMB share is intact. No server endpoint or experiment has been completed.

The Storage Sync service has managed identity enabled, and its identity has Storage Account Contributor at the account and Storage File Data Privileged Contributor at the share. The registered server uses managed identity and has Storage File Data Privileged Contributor at the share. The service identity also has Reader and Data Access at the account; this role permits access to storage account keys. The separate `Microsoft.StorageSync` service principal has not been identified, and its access requirement for this managed-identity configuration has not been established. Do not assign roles based on that hypothesis alone.

Escalate to Azure Support to identify the principal and authorization or policy decision behind the failure. Provide these details:

- The captured [failed workflow JSON](diagnostics/failed-workflow.json).
- Storage Sync service `azssu6uodqr76fhiy`, sync group `azsgu6uodqr76fhiy`, endpoint `azceu6uodqr76fhiy`, storage account `azstu6uodqr76fhiy`, and share `azshu6uodqr76fhiy` in `rgafslab2611`.
- Latest failed workflow `173c76c8-11c4-4eae-9a07-dea3c2878753`, backend correlation ID `42ec139a-1a25-46ee-8b20-664bc81c2a4f`, at `2026-11-12 06:36:07 UTC`.
- An earlier, different failure, `MgmtFileShareAuthorizationFailed`, had correlation ID `4e6ee8e6-f6e9-40cd-a088-c80e652522f7` at approximately `2026-11-12 04:44 UTC`.
- Storage Resource Health reported Available through Azure CLI. AppLens access was denied to the VS Code Azure identity; Azure Files data-plane diagnostic logs were not configured. SMB settings returned null, which normally represents defaults unless deliberately set otherwise.

After the cloud endpoint succeeds, verify the server endpoint and actual upload activity before running or interpreting the throttling experiment.

## Costs and cleanup

The deployment script requests VM deallocation after success or failure. Disks, storage, private endpoints, NAT Gateway, public IPs, and the existing Bastion may continue to incur charges. The resource group contains a Bastion and other resources not created by this template; review ownership before deleting anything.