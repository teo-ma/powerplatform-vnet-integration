using './main.bicep'

var config = loadJsonContent('../demo.config.json')

param resourceGroupName = config.resourceGroupName
param resourceGroupLocation = config.resourceGroupLocation
param policyName = config.policyName
param policyLocation = config.policyLocation
param subnetName = config.subnetName
param networks = config.networks
param tags = {
  workload: 'powerplatform-vnet-demo'
  environment: 'demo'
  deploymentId: config.deploymentId
  owner: config.account
}
