targetScope = 'resourceGroup'

@description('Azure region for the lab resources.')
param location string = resourceGroup().location

@description('Short environment label used to derive unique resource names.')
param environmentName string = 'afsThrottleLab'

@description('Small non-zonal VM size suitable for a short functional test.')
param vmSize string = 'Standard_B2s'

param vmAdminUsername string = 'afsadmin'

@secure()
param vmAdminPassword string

@minValue(32)
@maxValue(1024)
param dataDiskSizeGiB int = 32

@minValue(32)
@maxValue(5120)
param shareQuotaGiB int = 100

@description('Allow storage account key authentication.')
param allowStorageSharedKeyAccess bool = false

@description('Public network access for the storage account.')
@allowed([
  'Disabled'
  'Enabled'
])
param storagePublicNetworkAccess string = 'Enabled'

var resourceToken = uniqueString(subscription().id, resourceGroup().id, location, environmentName)
var storageAccountName = 'azst${resourceToken}'
var shareName = 'azsh${resourceToken}'
var syncServiceName = 'azss${resourceToken}'
var syncGroupName = 'azsg${resourceToken}'
var cloudEndpointName = 'azce${resourceToken}'
var vmName = 'azvm${resourceToken}'
var computerName = 'afs${take(resourceToken, 12)}'
var vnetName = 'azvn${resourceToken}'
var subnetName = 'azsn${resourceToken}'
var nsgName = 'azns${resourceToken}'
var nicName = 'azni${resourceToken}'
var publicIpName = 'azpip${resourceToken}'
var natGatewayName = 'aznat${resourceToken}'
var fileSyncAdminRoleId = '92b92042-07d9-4307-87f7-36a593fc5850'
var storageAccountContributorRoleId = '17d1049b-9a84-46fb-8f53-869881c3d3ab'
var storageFileDataPrivilegedContributorRoleId = '69566ab7-960f-475b-8e7c-b3118f30c6bd'
var labTags = {
  purpose: 'AzureFileSyncNetworkLimitLab'
  environment: environmentName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: labTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: allowStorageSharedKeyAccess
    publicNetworkAccess: storagePublicNetworkAccess
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: shareName
  properties: {
    shareQuota: shareQuotaGiB
    enabledProtocols: 'SMB'
    accessTier: 'TransactionOptimized'
  }
}

resource syncService 'Microsoft.StorageSync/storageSyncServices@2022-09-01' = {
  name: syncServiceName
  location: location
  tags: labTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
     useIdentity: true
    incomingTrafficPolicy: 'AllowAllTraffic'
  }
}

resource syncGroup 'Microsoft.StorageSync/storageSyncServices/syncGroups@2022-09-01' = {
  parent: syncService
  name: syncGroupName
  properties: {}
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  tags: labTags
  properties: {
    securityRules: []
  }
}

resource outboundPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  tags: labTags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    ddosSettings: {
      protectionMode: 'VirtualNetworkInherited'
    }
    ipTags: [
      {
        ipTagType: 'FirstPartyUsage'
        tag: '/Unprivileged'
      }
    ]
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: natGatewayName
  location: location
  tags: labTags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    idleTimeoutInMinutes: 4
    scope: 'Public'
    publicIpAddresses: [
      {
        id: outboundPublicIp.id
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: labTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.91.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.91.0.0/26'
          networkSecurityGroup: {
            id: resourceId('Microsoft.Network/networkSecurityGroups', '${vnetName}-AzureBastionSubnet-nsg-eastus')
          }
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        name: subnetName
        properties: {
          addressPrefix: '10.91.1.0/24'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          natGateway: {
            id: natGateway.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: subnetName
  properties: {
    addressPrefix: '10.91.1.0/24'
    privateEndpointNetworkPolicies: 'Enabled'
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
    natGateway: {
      id: natGateway.id
    }
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  tags: labTags
  kind: 'Regular'
  properties: {
    allowPort25Out: true
    auxiliaryMode: 'None'
    auxiliarySku: 'None'
    disableTcpStateTracking: false
    enableIPForwarding: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnet.id
          }
        }
      }
    ]
  }
}

resource fileSyncVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: labTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: computerName
      adminUsername: vmAdminUsername
      adminPassword: vmAdminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: 'azos${resourceToken}'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
      dataDisks: [
        {
          name: 'azdd${resourceToken}'
          lun: 0
          caching: 'None'
          createOption: 'Empty'
          deleteOption: 'Detach'
          diskSizeGB: dataDiskSizeGiB
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            primary: true
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource vmFileSyncAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: syncService
  name: guid(syncService.id, fileSyncVm.id, fileSyncAdminRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', fileSyncAdminRoleId)
    principalId: fileSyncVm.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows the lab VM identity to register and manage its Azure File Sync server endpoint.'
  }
}

resource vmFileSyncStorageAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, fileSyncVm.id, fileSyncAdminRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', fileSyncAdminRoleId)
    principalId: fileSyncVm.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows the lab VM identity to configure Azure File Sync managed identity on the lab storage account.'
  }
}

resource syncStorageAccountRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, syncService.id, storageAccountContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountContributorRoleId)
    principalId: syncService.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows the Storage Sync Service identity to access its lab storage account.'
  }
}

resource syncFileShareRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: fileShare
  name: guid(fileShare.id, syncService.id, storageFileDataPrivilegedContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageFileDataPrivilegedContributorRoleId)
    principalId: syncService.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows the Storage Sync Service identity to access the lab file share.'
  }
}

resource serverFileShareRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: fileShare
  name: guid(fileShare.id, fileSyncVm.id, storageFileDataPrivilegedContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageFileDataPrivilegedContributorRoleId)
    principalId: fileSyncVm.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows the lab server identity to access the lab file share.'
  }
}

output vmName string = fileSyncVm.name
output vmId string = fileSyncVm.id
output syncServiceName string = syncService.name
output syncServiceId string = syncService.id
output syncGroupName string = syncGroup.name
output cloudEndpointName string = cloudEndpointName
output serverEndpointName string = 'azse${resourceToken}'
output localPath string = 'D:\\AfsLab'
output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output fileShareName string = fileShare.name