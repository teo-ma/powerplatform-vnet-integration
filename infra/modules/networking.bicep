@description('Power Platform enterprise-policy name.')
param policyName string

@description('Power Platform geography for the enterprise policy.')
param policyLocation string

@description('Dedicated delegated subnet name.')
param subnetName string

@description('Approved paired network definitions.')
param networks array

@description('Ownership and cost-tracking tags.')
param tags object

resource securityGroups 'Microsoft.Network/networkSecurityGroups@2026-05-01' = [for network in networks: {
  name: network.nsgName
  location: network.location
  tags: tags
  properties: {
    securityRules: []
  }
}]

resource virtualNetworks 'Microsoft.Network/virtualNetworks@2026-05-01' = [for (network, index) in networks: {
  name: network.name
  location: network.location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        network.addressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: network.subnetPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: securityGroups[index].id
          }
          delegations: [
            {
              name: 'powerplatform'
              properties: {
                serviceName: 'Microsoft.PowerPlatform/enterprisePolicies'
              }
            }
          ]
        }
      }
    ]
  }
}]

resource policy 'Microsoft.PowerPlatform/enterprisePolicies@2020-10-30' = {
  name: policyName
  location: policyLocation
  kind: 'NetworkInjection'
  tags: tags
  properties: {
    networkInjection: {
      virtualNetworks: [for (_, index) in networks: {
        id: virtualNetworks[index].id
        subnet: {
          name: subnetName
        }
      }]
    }
  }
}

output policyId string = policy.id
output virtualNetworks array = [for (network, index) in networks: {
  id: virtualNetworks[index].id
  location: network.location
  subnetName: subnetName
  subnetPrefix: network.subnetPrefix
}]
