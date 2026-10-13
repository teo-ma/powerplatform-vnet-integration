[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param([string]$AzureConfigDirectory, [switch]$Execute)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($AzureConfigDirectory) { $env:AZURE_CONFIG_DIR = $AzureConfigDirectory }
. "$PSScriptRoot/Demo.Common.ps1"
$config = Get-Content -LiteralPath "$root/demo.config.json" -Raw | ConvertFrom-Json
$target = Get-Content -LiteralPath "$root/.azure/private-path-target.json" -Raw | ConvertFrom-Json
$plan = Get-Content -LiteralPath "$root/.azure/private-path-plan.json" -Raw | ConvertFrom-Json
$scope = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)"
$resources = @(
    [pscustomobject]@{ id = "$scope/providers/Microsoft.Network/privateEndpoints/pep-pp-path-blob"; api = '2024-07-01' }
    [pscustomobject]@{ id = "$scope/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"; api = '2024-06-01' }
    [pscustomobject]@{ id = "$scope/providers/Microsoft.Storage/storageAccounts/$($target.storageAccountName)"; api = '2025-01-01' }
    [pscustomobject]@{ id = "$scope/providers/Microsoft.Network/networkSecurityGroups/nsg-pp-private-path"; api = '2024-07-01' }
)
$subnetId = "$scope/providers/Microsoft.Network/virtualNetworks/vnet-pp-demo-westus/subnets/snet-private-path-target"
if ($target.subscriptionId -ne $config.subscriptionId -or $target.deploymentId -ne $plan.meta.planId -or
    $target.storageAccountId -ine $resources[2].id -or $target.privateEndpointId -ine $resources[0].id -or
    $target.privateEndpointSubnetId -ine $subnetId) {
    throw 'Cleanup state does not identify exactly the approved added resources.'
}
if (-not $Execute) {
    Write-Output 'PREVIEW ONLY: no resources are deleted. -Execute requests a separate destructive confirmation.'
    $resources.id
    $subnetId
    Write-Output 'The base resource group, both VNets, delegated subnet, enterprise policy, and Power Platform environments are retained.'
    return
}
$null = Get-DemoToken $config 'https://management.azure.com/'
foreach ($resource in $resources) {
    $actual = Invoke-DemoAz -Arguments @('resource', 'show', '--subscription', $config.subscriptionId,
        '--ids', $resource.id, '--api-version', $resource.api) -Json
    if ((Get-DemoField $actual.tags 'deploymentId') -ne $target.deploymentId) {
        throw "Refusing to delete a resource without the exact private-test ownership tag: $($resource.id)"
    }
}
$subnet = Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'show', '--subscription', $config.subscriptionId,
    '--resource-group', $config.resourceGroupName, '--vnet-name', 'vnet-pp-demo-westus', '--name', 'snet-private-path-target') -Json
if ($subnet.addressPrefix -ne '172.20.1.0/27' -or @($subnet.delegations).Count -ne 0) {
    throw 'Refusing to delete a subnet with unexpected addresses or any delegation.'
}
if (-not $PSCmdlet.ShouldProcess('Only the private-path test endpoint, DNS zone, storage data, NSG, reader assignment, and nondelegated target subnet',
    'Permanently delete the added private-path test resources and stop their recurring charges')) { return }
$assignments = @(Invoke-DemoAz -Arguments @('role', 'assignment', 'list', '--subscription', $config.subscriptionId,
    '--scope', $target.storageAccountId, '--fill-principal-name', 'false') -Json)
foreach ($assignment in $assignments) {
    if ($assignment.scope -ieq $target.storageAccountId -and $assignment.principalId -eq $config.principalId -and
        $assignment.roleDefinitionId.EndsWith('/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')) {
        $null = Invoke-DemoAz -Arguments @('role', 'assignment', 'delete', '--subscription', $config.subscriptionId, '--ids', $assignment.id)
    }
}
$null = Invoke-DemoAz -Arguments @('resource', 'delete', '--subscription', $config.subscriptionId, '--ids', $resources[0].id, '--api-version', $resources[0].api)
$null = Invoke-DemoAz -Arguments @('resource', 'delete', '--subscription', $config.subscriptionId, '--ids', $resources[1].id, '--api-version', $resources[1].api)
$null = Invoke-DemoAz -Arguments @('resource', 'delete', '--subscription', $config.subscriptionId, '--ids', $resources[2].id, '--api-version', $resources[2].api)
$null = Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'delete', '--subscription', $config.subscriptionId,
    '--resource-group', $config.resourceGroupName, '--vnet-name', 'vnet-pp-demo-westus', '--name', 'snet-private-path-target')
$null = Invoke-DemoAz -Arguments @('resource', 'delete', '--subscription', $config.subscriptionId, '--ids', $resources[3].id, '--api-version', $resources[3].api)
Write-DemoJson "$root/.azure/private-path-cleanup.json" ([ordered]@{
    status = 'Succeeded'
    completedAt = [DateTime]::UtcNow.ToString('o')
    removedIds = @($resources.id) + @($subnetId)
    baseDemoRetained = $true
})
Write-Output 'Only the added private-path target was removed. The original VNet integration demo remains.'
