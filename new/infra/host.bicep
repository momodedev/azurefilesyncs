targetScope = 'resourceGroup'

@description('Azure region for the nested Azure File Sync lab.')
param location string = resourceGroup().location

@description('Short label used to derive unique lab resource names.')
param environmentName string = 'afsNestedLab'

param vmSize string = 'Standard_D4s_v6'
param vmAdminUsername string = 'afsadmin'

@secure()
param vmAdminPassword string

var resourceToken = uniqueString(subscription().id, resourceGroup().id, location, environmentName)
var syncServiceName = 'afss${resourceToken}'
var vmName = 'afsh${resourceToken}'
var vnetName = 'afsv${resourceToken}'
var nicName = 'afsnic${resourceToken}'
var publicIpName = 'afspip${resourceToken}'
var labTags = {
  purpose: 'AzureFileSyncNestedThrottleLab'
  environment: environmentName
}
var fileSyncAdminRoleId = '92b92042-07d9-4307-87f7-36a593fc5850'

resource syncService 'Microsoft.StorageSync/storageSyncServices@2022-09-01' existing = {
  name: syncServiceName
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' existing = {
  name: publicIpName
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' existing = {
  name: nicName
}

resource hyperVHost 'Microsoft.Compute/virtualMachines@2024-07-01' = {
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
          patchMode: 'AutomaticByPlatform'
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

resource hostFileSyncAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: syncService
  name: guid(syncService.id, hyperVHost.id, fileSyncAdminRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', fileSyncAdminRoleId)
    principalId: hyperVHost.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows the lab host identity to manage the nested server endpoint.'
  }
}

output vmName string = hyperVHost.name
output vnetName string = virtualNetwork.name
output publicIpName string = publicIp.name