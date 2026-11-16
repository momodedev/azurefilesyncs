targetScope = 'resourceGroup'

@description('Azure region for the nested Azure File Sync lab.')
param location string = resourceGroup().location

@description('Short label used to derive unique storage and sync names.')
param environmentName string = 'afsNestedLab'

@minValue(32)
@maxValue(5120)
param shareQuotaGiB int = 32

@description('Create the Hyper-V host only after the cloud endpoint has succeeded.')
param deployHost bool = false

param vmSize string = 'Standard_D4s_v6'
param vmAdminUsername string = 'afsadmin'

@secure()
param vmAdminPassword string

@description('IPv4 CIDR permitted to RDP to the Hyper-V host. Use a single /32 address.')
param rdpSourceAddressPrefix string = '127.0.0.1/32'

var resourceToken = uniqueString(subscription().id, resourceGroup().id, location, environmentName)
var storageAccountName = 'afs${resourceToken}'
var shareName = 'sync${resourceToken}'
var syncServiceName = 'afss${resourceToken}'
var syncGroupName = 'afsg${resourceToken}'
var cloudEndpointName = 'afsc${resourceToken}'
var vmName = 'afsh${resourceToken}'
var vnetName = 'afsv${resourceToken}'
var subnetName = 'hosts'
var nsgName = 'afsn${resourceToken}'
var nicName = 'afsnic${resourceToken}'
var publicIpName = 'afspip${resourceToken}'
var labTags = {
  purpose: 'AzureFileSyncNestedThrottleLab'
  environment: environmentName
}

var fileSyncAdminRoleId = '92b92042-07d9-4307-87f7-36a593fc5850'
var storageAccountContributorRoleId = '17d1049b-9a84-46fb-8f53-869881c3d3ab'
var storageFileDataPrivilegedContributorRoleId = '69566ab7-960f-475b-8e7c-b3118f30c6bd'

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
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Allow'
    }
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

resource syncStorageAccountRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, syncService.id, storageAccountContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountContributorRoleId)
    principalId: syncService.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows the Storage Sync Service identity to access this lab storage account.'
  }
}

resource syncFileShareRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: fileShare
  name: guid(fileShare.id, syncService.id, storageFileDataPrivilegedContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageFileDataPrivilegedContributorRoleId)
    principalId: syncService.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows the Storage Sync Service identity to access this lab file share.'
  }
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (deployHost) {
  name: nsgName
  location: location
  tags: labTags
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromOperator'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: rdpSourceAddressPrefix
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployHost) {
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
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = if (deployHost) {
  name: vnetName
  location: location
  tags: labTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.92.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.92.1.0/24'
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
    ]
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (deployHost) {
  parent: virtualNetwork
  name: subnetName
  properties: {
    addressPrefix: '10.92.1.0/24'
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = if (deployHost) {
  name: nicName
  location: location
  tags: labTags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnet.id
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
  }
}

resource hyperVHost 'Microsoft.Compute/virtualMachines@2024-07-01' = if (deployHost) {
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
      computerName: take(vmName, 15)
      adminUsername: vmAdminUsername
      adminPassword: vmAdminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: 'os${resourceToken}'
        createOption: 'FromImage'
        diskSizeGB: 127
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          name: 'data${resourceToken}'
          lun: 0
          caching: 'None'
          createOption: 'Empty'
          deleteOption: 'Delete'
          diskSizeGB: 64
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
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
    securityProfile: {
      securityType: 'Standard'
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource hostFileSyncAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployHost) {
  scope: syncService
  name: guid(syncService.id, hyperVHost.id, fileSyncAdminRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', fileSyncAdminRoleId)
    principalId: hyperVHost!.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows the lab host identity to manage the nested server endpoint.'
  }
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output fileShareName string = fileShare.name
output syncServiceName string = syncService.name
output syncServiceId string = syncService.id
output syncGroupName string = syncGroup.name
output cloudEndpointName string = cloudEndpointName
output vmName string = deployHost ? hyperVHost.name : ''
output vnetName string = deployHost ? virtualNetwork.name : ''
output publicIpName string = deployHost ? publicIp.name : ''