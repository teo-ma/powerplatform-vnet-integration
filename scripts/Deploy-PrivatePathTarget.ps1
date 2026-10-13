[CmdletBinding()]
param([string]$AzureConfigDirectory)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($AzureConfigDirectory) { $env:AZURE_CONFIG_DIR = $AzureConfigDirectory }
. "$PSScriptRoot/Demo.Common.ps1"
$config = Get-Content -LiteralPath "$root/demo.config.json" -Raw | ConvertFrom-Json
$plan = Get-Content -LiteralPath "$root/.azure/private-path-plan.json" -Raw | ConvertFrom-Json
if (-not $plan.meta.backendDeploymentApproved -or $plan.meta.status -ne 'approved') {
    throw 'Explicit approval of the backend resources, hourly costs, and limited Azure data-reader assignment is required.'
}
$capability = Get-Content -LiteralPath "$root/.azure/private-path-capability.json" -Raw | ConvertFrom-Json
if ($capability.status -ne 'CapabilityReady' -or $capability.environmentId -ne $plan.inputs.environmentId -or
    [DateTime]::UtcNow -gt ([DateTime]$capability.completedAt).AddMinutes(30)) {
    throw 'A fresh, successful delegated-subnet capability precheck is required before chargeable resources are created.'
}
Assert-DemoAdministrator $config
$null = Get-DemoToken $config 'https://management.azure.com/'
$storageName = Get-DemoField $config 'privatePathStorageName' -Required
if ($storageName -notmatch '^[a-z0-9]{3,24}$') { throw 'A globally unique lowercase Storage account name is required in the private local configuration.' }
$scope = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)"
$vnetId = "$scope/providers/Microsoft.Network/virtualNetworks/vnet-pp-demo-westus"
$storageId = "$scope/providers/Microsoft.Storage/storageAccounts/$storageName"
$availability = Invoke-DemoAz -Arguments @('storage', 'account', 'check-name', '--name', $storageName) -Json
if (-not $availability.nameAvailable) {
    $existing = Invoke-DemoAz -Arguments @('resource', 'show', '--subscription', $config.subscriptionId, '--ids', $storageId, '--api-version', '2025-01-01') -Json
    if ((Get-DemoField $existing.tags 'deploymentId') -ne $plan.meta.planId) {
        throw 'The storage name is already owned by an unrelated account.'
    }
}
$template = Invoke-DemoAz -Arguments @('bicep', 'build', '--file', "$root/infra/private-path.bicep", '--stdout') -Json
Write-DemoJson "$root/.azure/compiled/private-path.json" $template
$arguments = @('--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--name', $plan.meta.planId,
    '--template-file', "$root/.azure/compiled/private-path.json", '--parameters',
    "readerPrincipalId=$($config.principalId)", "storageName=$storageName", "deploymentTag=$($plan.meta.planId)")
$preview = Invoke-DemoAz -Arguments (@('deployment', 'group', 'what-if') + $arguments + @('--no-pretty-print')) -Json
Write-DemoJson "$root/.azure/private-path-what-if.json" $preview
foreach ($change in @(Get-DemoField $preview 'changes' -Required)) {
    if ($change.changeType -notin @('Create', 'NoChange', 'Ignore')) {
        throw "Private-target deployment proposes an unapproved change: $($change.changeType) $($change.resourceId)"
    }
    if ($change.changeType -eq 'Create' -and
        -not $change.resourceId.StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Private-target deployment proposes a creation outside the approved resource group.'
    }
    if ($change.resourceId -ieq $vnetId -and $change.changeType -ne 'NoChange' -and $change.changeType -ne 'Ignore') {
        throw 'The original VNet must not be recreated or replaced.'
    }
}
$deployment = Invoke-DemoAz -Arguments (@('deployment', 'group', 'create') + $arguments) -Json
if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'The private-target deployment failed.' }
$endpoint = Invoke-DemoAz -Arguments @('network', 'private-endpoint', 'show', '--subscription', $config.subscriptionId,
    '--resource-group', $config.resourceGroupName, '--name', 'pep-pp-path-blob') -Json
if ($endpoint.privateLinkServiceConnections[0].privateLinkServiceConnectionState.status -ne 'Approved') {
    throw 'The private endpoint connection is not approved.'
}
$nic = Invoke-DemoAz -Arguments @('network', 'nic', 'show', '--subscription', $config.subscriptionId, '--ids', $endpoint.networkInterfaces[0].id) -Json
$target = [ordered]@{
    deployedAt = [DateTime]::UtcNow.ToString('o')
    subscriptionId = $config.subscriptionId
    deploymentId = $plan.meta.planId
    environmentId = $plan.inputs.environmentId
    region = 'westus'
    storageAccountName = $storageName
    storageAccountId = $storageId
    hostname = "$storageName.blob.core.windows.net"
    privateEndpointId = $endpoint.id
    privateEndpointIp = $nic.ipConfigurations[0].privateIPAddress
    privateEndpointSubnetId = $nic.ipConfigurations[0].subnet.id
    delegatedSourceSubnet = '172.20.0.0/24'
    applicationDataStored = $false
}
if (-not $target.privateEndpointIp -or $target.privateEndpointSubnetId -ine "$vnetId/subnets/snet-private-path-target") {
    throw 'The private endpoint NIC did not identify the approved endpoint subnet and IP.'
}
Write-DemoJson "$root/.azure/private-path-target.json" $target
Write-Output 'The private-only test target is deployed. Its existence is not a passed network test.'
$target | ConvertTo-Json -Depth 8
