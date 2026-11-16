# Azure File Sync throttle lab

This lab targets subscription `8d6bd1eb-ae31-4f2c-856a-0f8e47115c4b` and resource group `rgafslab2611` by default. Authenticate the Azure CLI to the corresponding tenant and subscription before running the scripts.

```powershell
.\scripts\Deploy-AfsLab.ps1 -PreviewOnly
.\scripts\Deploy-AfsLab.ps1
```

Review the what-if output before deployment. `-SkipSimulation` provisions the endpoints without running the experiment. The template preserves the existing Bastion subnet in this lab; review its subnet and network security group settings before using it in a different resource group.

The VM bootstrap uses the non-system disk at data LUN 0. The experiment removes all Azure File Sync network limits on the VM before and after its baseline, 5 Mbps, and recovery phases. Use it only on a dedicated lab server. Results and any available telemetry are written on the VM under `C:\ProgramData\AzureFileSyncOps`. Inspect the results for actual upload activity before drawing conclusions.

## Networking

The lab uses Azure File Sync and Azure Files public endpoints. Microsoft documents that the public endpoints require no private endpoint, service endpoint, VPN, or ExpressRoute for servers with internet access. Azure File Sync agent traffic is outbound HTTPS on TCP 443; certificate validation also needs outbound TCP 80 and 443 to the Microsoft PKI endpoints. The VNet and NAT Gateway remain to provide the lab VM with outbound internet access. See Microsoft's [Azure File Sync network endpoint guidance](https://learn.microsoft.com/azure/storage/file-sync/file-sync-networking-endpoints) and [firewall requirements](https://learn.microsoft.com/azure/storage/file-sync/file-sync-firewall-and-proxy).

The Bicep template no longer creates private endpoints, private DNS zones, or private DNS links. The storage account's public network access defaults to `Enabled`; `infra/main.parameters.json` also preserves the existing shared-key setting. The live storage account currently permits public network access from all networks, subject to authorization. This is intentionally broad for the lab and should be restricted after the test if required by the security owner.

The existing lab private endpoints and their VNet links were removed with targeted Azure operations. The private DNS zones were retained. A read-only what-if showed unrelated VM, disk, NIC, VNet, and role-assignment changes, so do not apply a full Bicep redeployment solely to remove private endpoints. An incremental deployment does not delete resources omitted from the template.

Public routing simplifies network setup but does not bypass Azure authorization. The cloud endpoint remains `Canceled` after repeated `MgmtForbidden2` / `0x80C83034` errors during `newReplicaGroup`; the cause has not been established. The Storage Sync service identity and required share/account roles were verified, but a subscription Owner role does not resolve a backend identity or policy denial automatically. The normal deployment script intentionally stops at its canceled-endpoint guard; use `-PreviewOnly` for read-only inspection until Azure Support identifies the cause. Do not retry endpoint creation or change roles based solely on the public-endpoint change.

The VM remains deallocated, and the SMB share is intact. No server endpoint or experiment has been completed. The current template provisions a single Windows Server VM; it does not create the nested Hyper-V guest described in the attached guide.

The Storage Sync service has managed identity enabled, and its identity has Storage Account Contributor at the account and Storage File Data Privileged Contributor at the share. The registered server uses managed identity and has Storage File Data Privileged Contributor at the share. The service identity also has Reader and Data Access at the account; this role permits access to storage account keys. The separate `Microsoft.StorageSync` service principal has not been identified, and its access requirement for this managed-identity configuration has not been established. Do not assign roles based on that hypothesis alone.

Escalate to Azure Support to identify the principal and authorization or policy decision behind the failure. Provide these details:

- The captured [failed workflow JSON](diagnostics/failed-workflow.json).
- The latest retry's [failed workflow JSON](diagnostics/failed-workflow-20261113.json), created `2026-11-13T03:31:38Z`; it again failed at `newReplicaGroup` with `MgmtForbidden2` / `0x80C83034`. The endpoint is `Canceled`.
- Latest endpoint write Activity Log correlation ID `60c10f02-7c5f-4683-b12a-b4d5dea0a510`; workflow ID `b6502a2f-a506-4e99-8cd4-0c0e87e0caee`; workflow operation ID `ea38c303-2a6c-4cc9-af2b-0abf36cabcb4`.
- Storage Sync service `azssu6uodqr76fhiy`, sync group `azsgu6uodqr76fhiy`, endpoint `azceu6uodqr76fhiy`, storage account `azstu6uodqr76fhiy`, and share `azshu6uodqr76fhiy` in `rgafslab2611`.
- Latest failed workflow `173c76c8-11c4-4eae-9a07-dea3c2878753`, backend correlation ID `42ec139a-1a25-46ee-8b20-664bc81c2a4f`, at `2026-11-12 06:36:07 UTC`.
- An earlier, different failure, `MgmtFileShareAuthorizationFailed`, had correlation ID `4e6ee8e6-f6e9-40cd-a088-c80e652522f7` at approximately `2026-11-12 04:44 UTC`.
- The prior retry's Activity Log correlation ID was `42ec139a-1a25-46ee-8b20-664bc81c2a4f`, workflow `173c76c8-11c4-4eae-9a07-dea3c2878753`.
- Storage Resource Health reported Available through Azure CLI. AppLens access was denied to the VS Code Azure identity; Azure Files data-plane diagnostic logs were not configured. SMB settings returned null, which normally represents defaults unless deliberately set otherwise.

After the cloud endpoint succeeds, verify the server endpoint and actual upload activity before running or interpreting the throttling experiment.

## Costs and cleanup

The deployment script requests VM deallocation after success or failure. Disks, storage, the retained private DNS zones, NAT Gateway, public IP, and the existing Bastion may continue to incur charges. The resource group contains a Bastion and other resources not created by this template; review ownership before deleting anything.