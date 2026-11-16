$ErrorActionPreference = 'Stop'

$hyperVFeature = Get-WindowsFeature -Name Hyper-V
if (-not $hyperVFeature.Installed) {
    $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
    if (-not $result.Success) {
        throw 'Hyper-V installation failed.'
    }
    Write-Output 'AFSLAB_HYPERV_REBOOT_REQUIRED=true'
    return
}

Write-Output 'AFSLAB_HYPERV_READY=true'