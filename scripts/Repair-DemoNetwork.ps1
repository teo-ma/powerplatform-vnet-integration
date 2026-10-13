[CmdletBinding()]
param([string]$AzureConfigDirectory)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($AzureConfigDirectory) { $env:AZURE_CONFIG_DIR = $AzureConfigDirectory }
. "$PSScriptRoot/Demo.Common.ps1"
$config = Get-Content -LiteralPath "$root/demo.config.json" -Raw | ConvertFrom-Json
$plan = Get-Content -LiteralPath "$root/.azure/private-path-plan.json" -Raw | ConvertFrom-Json
$statePath = "$root/.azure/deployment-state.json"
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
if (-not $plan.meta.networkPolicyRefreshApproved -or $plan.inputs.environmentId -ne $state.environmentId -or
    $state.environmentId -eq $config.defaultEnvironmentId -or $state.subscriptionId -ne $config.subscriptionId) {
    throw 'Refreshing the network policy requires explicit risk approval for this isolated demo.'
}
Assert-DemoAdministrator $config
$expectedPolicy = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)/providers/Microsoft.PowerPlatform/enterprisePolicies/$($config.policyName)"
if ($state.policyId -ine $expectedPolicy) { throw 'The saved enterprise policy is outside the approved scope.' }
$environment = Get-DemoEnvironment $config $state.environmentId
$marker = "Power Platform VNet configuration demo; deployment=$($config.deploymentId); configuration-only"
if ($environment.properties.displayName -ne $config.environmentName -or
    $environment.properties.description -ne $marker -or
    $environment.properties.environmentSku -ne 'Developer') {
    throw 'Refusing to refresh an unrelated or non-Developer environment.'
}
$policy = Invoke-DemoAz -Arguments @('resource', 'show', '--subscription', $config.subscriptionId, '--ids', $state.policyId, '--api-version', '2020-10-30') -Json
$systemId = Get-DemoField $policy.properties 'systemId' -Required
$before = Get-DemoDefaultSnapshot $config
$repairPath = "$root/.azure/network-policy-refresh.json"
$repair = if (Test-Path -LiteralPath $repairPath) {
    Get-Content -LiteralPath $repairPath -Raw | ConvertFrom-Json -AsHashtable
} else {
    [ordered]@{
        status = 'Running'
        environmentId = $state.environmentId
        policyId = $state.policyId
        startedAt = [DateTime]::UtcNow.ToString('o')
        unlinkOperationUri = $null
        linkOperationUri = $null
    }
}
if ($repair.environmentId -ne $state.environmentId -or $repair.policyId -ine $state.policyId) {
    throw 'The saved refresh operation belongs to a different environment or policy.'
}
$repair.status = 'Running'
$state.completed = $false
$state.phase = 'refreshing-network-policy'
Write-DemoJson $statePath $state
Write-DemoJson $repairPath $repair
try {
    if (-not $repair.linkOperationUri) {
        $current = Get-DemoField (Get-DemoField $environment.properties 'enterprisePolicies') 'VNets'
        if ($current) {
            if ((Get-DemoField $current 'id' -Required) -ine $state.policyId) {
                throw 'The environment has a different policy; refusing to replace it.'
            }
            $unlink = Invoke-DemoHttp $config "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/$($state.environmentId)/enterprisePolicies/NetworkInjection/unlink?api-version=2019-10-01" -Method POST -Body @{ SystemId = $systemId }
            if ($unlink.StatusCode -ne 202 -or -not $unlink.Headers['operation-location']) {
                throw 'The unlink operation was not accepted with an operation-location.'
            }
            $repair.unlinkOperationUri = [string]@($unlink.Headers['operation-location'])[0]
            Write-DemoJson $repairPath $repair
            Wait-DemoPolicyOperation $config $repair.unlinkOperationUri
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        do {
            $environment = Get-DemoEnvironment $config $state.environmentId
            if (-not (Get-DemoField (Get-DemoField $environment.properties 'enterprisePolicies') 'VNets')) { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'The successful unlink has not propagated within five minutes.' }
            Write-Host 'Waiting for successful unlink metadata to propagate...'
            Start-Sleep -Seconds 10
        } while ($true)
        $link = Invoke-DemoHttp $config "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/$($state.environmentId)/enterprisePolicies/NetworkInjection/link?api-version=2019-10-01" -Method POST -Body @{ SystemId = $systemId }
        if ($link.StatusCode -ne 202 -or -not $link.Headers['operation-location']) {
            throw 'The relink operation was not accepted with an operation-location.'
        }
        $repair.linkOperationUri = [string]@($link.Headers['operation-location'])[0]
        Write-DemoJson $repairPath $repair
    }
    $state.associationOperationUri = $repair.linkOperationUri
    $state.associationOperationState = 'Running'
    Write-DemoJson $repairPath $repair
    Write-DemoJson $statePath $state
    Wait-DemoPolicyOperation $config $repair.linkOperationUri
    $state.associationOperationState = 'Succeeded'
    Write-DemoJson $statePath $state
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $environment = Get-DemoEnvironment $config $state.environmentId
        $association = Get-DemoField (Get-DemoField $environment.properties 'enterprisePolicies') 'VNets'
        if ((Get-DemoField $association 'id') -ieq $state.policyId -and
            (Get-DemoField $association 'linkStatus') -eq 'Linked') { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'The successful relink has not propagated within five minutes.' }
        Write-Host 'Waiting for successful relink metadata to propagate...'
        Start-Sleep -Seconds 10
    } while ($true)
    $after = Get-DemoDefaultSnapshot $config
    if ($before.protectionLevel -ne $after.protectionLevel -or $before.vnetPolicy -ne $after.vnetPolicy) {
        throw 'The default environment changed during the policy refresh.'
    }
    & "$PSScriptRoot/Verify-Demo.ps1" -AzureConfigDirectory $AzureConfigDirectory
    $repair.status = 'Succeeded'
    $repair.completedAt = [DateTime]::UtcNow.ToString('o')
    if ($repair.Contains('error')) { $repair.Remove('error') }
    $state.phase = 'completed'
    $state.completed = $true
    if ($state.Contains('lastError')) { $state.Remove('lastError') }
    Write-DemoJson $repairPath $repair
    Write-DemoJson $statePath $state
    Write-Output 'The original demo network policy was refreshed and its configuration reverified. Runtime protocol tests are still required.'
} catch {
    $repair.status = 'Failed'
    $repair.error = $_.Exception.Message
    $state.completed = $false
    $state.lastError = $_.Exception.Message
    Write-DemoJson $repairPath $repair
    Write-DemoJson $statePath $state
    throw
}
