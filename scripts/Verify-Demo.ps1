[CmdletBinding()]
param([string]$AzureConfigDirectory)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($AzureConfigDirectory) { $env:AZURE_CONFIG_DIR = $AzureConfigDirectory }
. "$PSScriptRoot/Demo.Common.ps1"
$config = Get-Content -LiteralPath "$root/demo.config.json" -Raw | ConvertFrom-Json
$state = Get-Content -LiteralPath "$root/.azure/deployment-state.json" -Raw | ConvertFrom-Json
if ($state.subscriptionId -ne $config.subscriptionId -or $state.account -ine $config.account -or
    -not $state.environmentId -or -not $state.policyId -or $state.environmentId -eq $config.defaultEnvironmentId) {
    throw 'Deployment state does not identify the approved isolated demo.'
}
$expectedPolicyId = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)/providers/Microsoft.PowerPlatform/enterprisePolicies/$($config.policyName)"
if ($state.policyId -ine $expectedPolicyId) { throw 'Saved policy ID is outside the approved scope.' }
if ($state.associationOperationUri -and
    (Get-DemoField $state 'associationOperationState') -ne 'Succeeded') {
    throw 'The asynchronous association operation has not been verified as Succeeded.'
}
if (-not $state.associationOperationUri) { throw 'The association operation URL is missing.' }
$operation = Invoke-DemoHttp $config $state.associationOperationUri
$operationState = Get-DemoField (Get-DemoField $operation.Body 'state' -Required) 'id' -Required
if ($operationState -ne 'Succeeded') { throw "The live association operation is not successful: $operationState" }
$environment = Get-DemoEnvironment $config $state.environmentId
$properties = Get-DemoField $environment 'properties' -Required
$marker = "Power Platform VNet configuration demo; deployment=$($config.deploymentId); configuration-only"
if ((Get-DemoField $properties 'environmentSku' -Required) -ne $config.environmentType -or
    (Get-DemoField $properties 'displayName' -Required) -ne $config.environmentName -or
    (Get-DemoField $properties 'description' -Required) -ne $marker -or
    (Get-DemoField $properties 'provisioningState' -Required) -ne 'Succeeded' -or
    (Get-DemoField $properties 'tenantId' -Required) -ne $config.tenantId) {
    throw 'The environment identity, ownership, or provisioning state differs from the approved demo.'
}
$governance = Get-DemoField $properties 'governanceConfiguration' -Required
$association = Get-DemoField (Get-DemoField $properties 'enterprisePolicies' -Required) 'VNets' -Required
if ($governance.protectionLevel -ne 'Standard' -or $association.id -ine $state.policyId) {
    throw 'The managed environment does not have the expected enterprise-policy association.'
}
$region = Get-DemoRegion $config $state.environmentId
if ($region -notin @($config.networks.location)) { throw 'The actual environment region does not match the deployed pair.' }
$policy = Invoke-DemoAz -Arguments @('resource', 'show', '--subscription', $config.subscriptionId, '--ids', $state.policyId, '--api-version', '2020-10-30') -Json
if ($policy.kind -ne 'NetworkInjection' -or $policy.location -ne $config.policyLocation -or
    @($policy.properties.networkInjection.virtualNetworks).Count -ne 2) {
    throw 'Enterprise policy kind, geography, or network count is incorrect.'
}
$verified = @()
foreach ($network in $config.networks) {
    $vnet = Invoke-DemoAz -Arguments @('network', 'vnet', 'show', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--name', $network.name) -Json
    if ($vnet.location -ne $network.location -or @($vnet.addressSpace.addressPrefixes).Count -ne 1 -or
        $vnet.addressSpace.addressPrefixes[0] -ne $network.addressPrefix) { throw "Unexpected VNet configuration: $($network.name)" }
    $subnets = @($vnet.subnets | Where-Object { $_.name -eq $config.subnetName })
    if ($subnets.Count -ne 1) { throw "Dedicated subnet is missing: $($network.name)" }
    $subnet = $subnets[0]
    $nsgId = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)/providers/Microsoft.Network/networkSecurityGroups/$($network.nsgName)"
    if ($subnet.addressPrefix -ne $network.subnetPrefix -or $subnet.defaultOutboundAccess -ne $false -or
        $subnet.networkSecurityGroup.id -ine $nsgId -or @($subnet.delegations).Count -ne 1 -or
        $subnet.delegations[0].serviceName -ne 'Microsoft.PowerPlatform/enterprisePolicies') {
        throw "Subnet prefix, NSG, outbound configuration, or delegation is incorrect: $($network.name)"
    }
    $policyNetwork = @($policy.properties.networkInjection.virtualNetworks | Where-Object { $_.id -ieq $vnet.id })
    if ($policyNetwork.Count -ne 1 -or $policyNetwork[0].subnet.name -ne $config.subnetName) {
        throw "The policy does not reference the exact approved VNet/subnet: $($network.name)"
    }
    $nsg = Invoke-DemoAz -Arguments @('network', 'nsg', 'show', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--name', $network.nsgName) -Json
    if (@($nsg.securityRules).Count -ne 0) { throw 'Unexpected custom NSG rules are present.' }
    $verified += [pscustomobject]@{ id = $vnet.id; location = $vnet.location; subnetPrefix = $subnet.addressPrefix; usableIpAddresses = (Get-DemoCidr $subnet.addressPrefix).Size - 5 }
}
$default = Get-DemoDefaultSnapshot $config
if ($default.protectionLevel -ne $state.defaultEnvironmentBefore.protectionLevel -or $default.vnetPolicy -ne $state.defaultEnvironmentBefore.vnetPolicy) {
    throw 'The default environment configuration differs from its initial snapshot.'
}
$preview = Get-Content -LiteralPath "$root/.azure/what-if.json" -Raw | ConvertFrom-Json
$changes = @(Get-DemoField $preview 'changes' -Required)
$scope = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)"
foreach ($change in $changes) {
    if ($change.changeType -notin @('Create', 'NoChange', 'Ignore') -or
        ($change.changeType -eq 'Create' -and $change.resourceId -ine $scope -and
         -not $change.resourceId.StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase))) {
        throw 'The saved what-if contains a modification, deletion, or out-of-scope creation.'
    }
}
$subscriptionDeployment = Invoke-DemoAz -Arguments @('deployment', 'sub', 'show', '--subscription', $config.subscriptionId, '--name', $config.deploymentId) -Json
$groupDeployment = Invoke-DemoAz -Arguments @('deployment', 'group', 'show', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--name', 'powerplatform-networking') -Json
if ($subscriptionDeployment.properties.provisioningState -ne 'Succeeded' -or $groupDeployment.properties.provisioningState -ne 'Succeeded') {
    throw 'The actual subscription or resource-group deployment is not successful.'
}
$operations = @(Invoke-DemoAz -Arguments @('deployment', 'operation', 'sub', 'list', '--subscription', $config.subscriptionId, '--name', $config.deploymentId) -Json) +
    @(Invoke-DemoAz -Arguments @('deployment', 'operation', 'group', 'list', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--name', 'powerplatform-networking') -Json)
$targets = @()
foreach ($item in $operations) {
    $target = Get-DemoField $item.properties 'targetResource'
    if ($null -eq $target) { continue }
    $id = Get-DemoField $target 'id' -Required
    $targetState = Get-DemoField $item.properties 'provisioningState' -Required
    if ($targetState -ne 'Succeeded' -or
        ($id -ine $scope -and -not $id.StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase))) {
        throw "Unsuccessful or out-of-scope ARM deployment operation: $id"
    }
    $targets += [pscustomobject]@{ resourceId = $id; state = $targetState }
}
if (-not $targets.Count) { throw 'The actual deployment operations did not identify any target resources.' }
$insights = Get-Content -LiteralPath "$root/.azure/insights.json" -Raw | ConvertFrom-Json
$baseline = @($insights | Where-Object { $_.id -like 'existing-resource-*' } | ForEach-Object { $_.existingResource })
if (-not $baseline.Count) {
    $inventoryPath = "$root/.azure/resource-inventory.json"
    if (-not (Test-Path -LiteralPath $inventoryPath)) { throw 'The pre-deployment resource inventory is missing.' }
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    if ($inventory.subscriptionId -ne $config.subscriptionId -or $inventory.count -ne 0) {
        throw 'An empty baseline must be supported by a matching captured zero-resource inventory.'
    }
}
$currentResources = @(Invoke-DemoAz -Arguments @('resource', 'list', '--subscription', $config.subscriptionId, '--query', '[].{id:id,type:type}') -Json)
$currentById = @{}
foreach ($resource in $currentResources) { $currentById[$resource.id] = $resource.type }
foreach ($resource in $baseline) {
    if (-not $currentById.ContainsKey($resource.id) -or $currentById[$resource.id] -ine $resource.type) {
        throw "A baseline resource is missing or has a different type: $($resource.id)"
    }
}
$watchers = @(Invoke-DemoAz -Arguments @('network', 'watcher', 'list', '--subscription', $config.subscriptionId, '--query', "[?location=='eastus' || location=='westus'].{id:id,location:location}") -Json)
$evidence = [pscustomobject]@{
    verifiedAt = [DateTime]::UtcNow.ToString('o')
    subscriptionDeploymentState = $subscriptionDeployment.properties.provisioningState
    groupDeploymentState = $groupDeployment.properties.provisioningState
    allDeploymentTargetResourcesInApprovedGroup = $true
    targetResources = $targets
    platformNetworkWatchers = $watchers
    propertyByPropertyExistingResourceAuditPerformed = $false
}
Write-DemoJson "$root/.azure/deployment-evidence.json" $evidence
$result = [pscustomobject]@{
    status = 'Succeeded'
    verifiedAt = [DateTime]::UtcNow.ToString('o')
    account = $config.account
    subscriptionId = $config.subscriptionId
    environmentId = $state.environmentId
    environmentName = $environment.properties.displayName
    azureRegion = $region
    protectionLevel = $governance.protectionLevel
    policyId = $state.policyId
    associationOperationId = Get-DemoField $operation.Body 'id' -Required
    associationOperationState = $operationState
    virtualNetworks = $verified
    defaultEnvironmentUnchanged = $true
    existingResourceInventory = @{
        baselineCount = $baseline.Count
        allBaselineResourcesPresent = $true
        verificationScope = 'Resource IDs and types; not a before/after comparison of every resource property.'
    }
    deploymentPreviewAddOnly = $true
    actualDeploymentTargetsInApprovedGroup = $true
    configurationOnly = $true
    runtimeWorkloadTested = $false
}
Write-DemoJson "$root/.azure/verification.json" $result
$result | ConvertTo-Json -Depth 10
