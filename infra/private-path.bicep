targetScope = 'resourceGroup'

@description('Existing demo VNet. It is referenced, not recreated.')
param vnetName string = 'vnet-pp-demo-westus'

@description('New globally unique, private-only storage account.')
@minLength(3)
@maxLength(24)
param storageName string

@description('Approved test principal, granted read-only data access at this account.')
param readerPrincipalId string

param location string = 'westus'
param deploymentTag string

var tags = {
  workload: 'powerplatform-private-path-test'
  environment: 'demo'
  deploymentId: deploymentTag
}

// Published schema-backed versions keep all endpoint properties type-checked.
resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' existing = {
  name: vnetName
}

resource targetNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-pp-private-path'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowPowerPlatformHttps'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '172.20.0.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '172.20.1.0/27'
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyOtherInbound'
        properties: {
          priority: 300
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource targetSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = {
  parent: vnet
  name: 'snet-private-path-target'
  properties: {
    addressPrefix: '172.20.1.0/27'
    defaultOutboundAccess: false
    privateEndpointNetworkPolicies: 'Enabled'
    networkSecurityGroup: {
      id: targetNsg.id
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  tags: tags
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
      }
    }
  }
}

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, readerPrincipalId, 'Storage Blob Data Reader')
  scope: storage
  properties: {
    principalId: readerPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  }
}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource zoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'link-pp-private-path-westus'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

resource endpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: 'pep-pp-path-blob'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: targetSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: endpoint
  name: 'blob'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: zone.id
        }
      }
    ]
  }
}

output storageAccountId string = storage.id
output storageAccountName string = storage.name
output hostname string = '${storage.name}.blob.${environment().suffixes.storage}'
output privateEndpointId string = endpoint.id
output privateDnsZoneId string = zone.id
output targetSubnetId string = targetSubnet.id
