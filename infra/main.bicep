targetScope = 'subscription'

@description('New dedicated demo resource group.')
@minLength(1)
@maxLength(90)
param resourceGroupName string

@description('Region for resource-group metadata and the deployment.')
param resourceGroupLocation string

@description('Power Platform enterprise-policy name.')
param policyName string

@description('Power Platform geography, not an Azure region.')
param policyLocation string

@description('Dedicated Power Platform subnet name in each VNet.')
param subnetName string

@description('Approved region-paired networks and their nonoverlapping address ranges.')
@minLength(2)
@maxLength(2)
param networks array

@description('Nonsecret ownership and cost-tracking tags.')
param tags object

resource group 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: resourceGroupLocation
  tags: tags
}

module networking './modules/networking.bicep' = {
  name: 'powerplatform-networking'
  scope: group
  params: {
    policyName: policyName
    policyLocation: policyLocation
    subnetName: subnetName
    networks: networks
    tags: tags
  }
}

output resourceGroupId string = group.id
output policyId string = networking.outputs.policyId
output virtualNetworks array = networking.outputs.virtualNetworks
