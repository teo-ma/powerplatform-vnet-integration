[CmdletBinding()]
param([string]$AzureConfigDirectory)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($AzureConfigDirectory) { $env:AZURE_CONFIG_DIR = $AzureConfigDirectory }
. "$PSScriptRoot/Demo.Common.ps1"
$configPath = "$root/demo.config.json"
if (-not (Test-Path -LiteralPath $configPath)) {
    throw 'Copy demo.config.example.json to ignored demo.config.json and enter your own account, tenant, subscription, and principal before preparation.'
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
foreach ($field in @('subscriptionId', 'tenantId', 'principalId')) {
    $value = [guid]::Empty
    if (-not [guid]::TryParse($config.$field, [ref]$value) -or $value -eq [guid]::Empty) {
        throw "Replace the example with your own nonempty GUID: $field"
    }
}
if ($config.account -eq 'demo.user@contoso.onmicrosoft.com' -or $config.account -notmatch '^[^@\s]+@[^@\s]+$') {
    throw 'The private configuration must name your actual approved account.'
}
if ($config.privatePathStorageName -eq 'stpppathreplacewithunique' -or $config.privatePathStorageName -notmatch '^[a-z0-9]{3,24}$') {
    throw 'Choose your own globally unique lowercase Storage account name.'
}
if ($config.defaultEnvironmentId -ne "Default-$($config.tenantId)") {
    throw 'defaultEnvironmentId must match the configured tenant.'
}
foreach ($file in @('infrastructure-plan.json', 'private-path-plan.json', 'deployment-state.json', 'insights.json')) {
    if (Test-Path -LiteralPath "$root/.azure/$file") {
        throw "Existing private state will not be overwritten: .azure/$file. Reuse and review it instead."
    }
}
$null = Get-DemoToken $config 'https://management.azure.com/'
$resources = @(Invoke-DemoAz -Arguments @('resource', 'list', '--subscription', $config.subscriptionId,
    '--query', '[].{id:id,type:type,name:name}') -Json)
$insights = @($resources | ForEach-Object {
    $bytes = [Text.Encoding]::UTF8.GetBytes($_.id.ToLowerInvariant())
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).Substring(0, 16).ToLowerInvariant()
    [pscustomobject]@{
        id = "existing-resource-$hash"
        existingResource = [pscustomobject]@{
            id = $_.id
            type = $_.type
            name = $_.name
            role = 'ignore'
            must_not_recreate = $true
            integrationPoints = @()
        }
    }
})
Write-DemoJson "$root/.azure/insights.json" $insights
Write-DemoJson "$root/.azure/resource-inventory.json" ([ordered]@{
    subscriptionId = $config.subscriptionId
    capturedAt = [DateTime]::UtcNow.ToString('o')
    count = $resources.Count
    resourceIds = @($resources | ForEach-Object { $_.id })
})
$plan = [ordered]@{
    meta = [ordered]@{
        planId = $config.deploymentId
        generatedAt = [DateTime]::UtcNow.ToString('o')
        status = 'draft'
        userRiskAcknowledged = $false
    }
    inputs = [ordered]@{
        userGoal = 'Isolated managed Developer environment and paired Power Platform VNet configuration demo.'
        subscriptionId = $config.subscriptionId
        tenantId = $config.tenantId
        account = $config.account
    }
    plan = [ordered]@{
        regionPair = @('westus', 'eastus')
        environmentType = 'Developer'
        environmentName = $config.environmentName
        resourceGroupName = $config.resourceGroupName
        networks = $config.networks
        policyName = $config.policyName
        configurationOnly = $true
        runBusinessAssets = $false
        modifyExistingResources = $false
        requiredReview = 'Review CIDRs/IPAM, permissions, licenses, cost, service availability, and the what-if. Only the user may approve this draft before cloud changes.'
    }
}
Write-DemoJson "$root/.azure/infrastructure-plan.json" $plan
Write-DemoJson "$root/.azure/private-path-plan.json" ([ordered]@{
    meta = [ordered]@{
        planId = "$($config.deploymentId)-private-path"
        status = 'draft'
        backendDeploymentApproved = $false
        backendCostsAndRisksAcknowledged = $false
        accountScopedBlobDataReaderApproved = $false
        diagnosticOnlyScopeApproved = $false
        networkPolicyRefreshApproved = $false
    }
    inputs = [ordered]@{
        subscriptionId = $config.subscriptionId
        tenantId = $config.tenantId
        account = $config.account
        environmentId = $null
        region = 'westus'
    }
    plan = [ordered]@{
        scope = 'Actual private DNS/TCP/TLS diagnostic protocol proof only; no business payload or Premium enrollment.'
        storageAccountName = $config.privatePathStorageName
        targetSubnet = '172.20.1.0/27'
        requiredReview = 'After base deployment, set inputs.environmentId from deployment-state.json. Review endpoint/DNS recurring cost and account-scoped Blob Reader. Explicitly approve each applicable action before running it.'
    }
})
Write-Output "Prepared ignored local drafts and a read-only baseline of $($resources.Count) Azure resources."
Write-Output 'No cloud resources, role assignments, licenses, or billing configurations were changed. All approval flags remain false.'
