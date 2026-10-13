[CmdletBinding()]
param(
    [string]$AzureConfigDirectory,
    [switch]$Deploy,
    [int]$ProvisioningTimeoutMinutes = 45
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($AzureConfigDirectory) { $env:AZURE_CONFIG_DIR = $AzureConfigDirectory }
. "$PSScriptRoot/Demo.Common.ps1"
$config = Get-Content -LiteralPath "$root/demo.config.json" -Raw | ConvertFrom-Json
$plan = Get-Content -LiteralPath "$root/.azure/infrastructure-plan.json" -Raw | ConvertFrom-Json
$statePath = "$root/.azure/deployment-state.json"

Assert-DemoAdministrator $config
& "$PSScriptRoot/Test-Demo.ps1" -AzureConfigDirectory $AzureConfigDirectory
if (-not $Deploy) {
    Write-Output 'Preflight and local validation completed. No cloud changes. Use -Deploy only after approving the plan and risks.'
    return
}
if ($plan.meta.status -notin @('approved', 'deployed') -or -not $plan.meta.userRiskAcknowledged) {
    throw 'The deployment plan and risks require explicit user approval.'
}
if ($config.subscriptionId -ne $plan.inputs.subscriptionId -or $config.account -ine $plan.inputs.account -or -not $config.configurationOnly) {
    throw 'The runtime configuration differs from the approved scope.'
}

$state = if (Test-Path -LiteralPath $statePath) {
    Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
} else {
    [ordered]@{
        deploymentId = $config.deploymentId
        subscriptionId = $config.subscriptionId
        tenantId = $config.tenantId
        account = $config.account
        phase = 'starting'
        environmentId = $null
        policyId = $null
        associationOperationUri = $null
        defaultEnvironmentBefore = $null
        completed = $false
    }
}
if ($state.deploymentId -ne $config.deploymentId -or $state.subscriptionId -ne $config.subscriptionId -or $state.account -ine $config.account) {
    throw 'Saved deployment state belongs to a different scope.'
}

try {
    if ($state.completed) {
        & "$PSScriptRoot/Verify-Demo.ps1" -AzureConfigDirectory $AzureConfigDirectory
        Write-Output 'The completed demo was reverified without cloud changes.'
        return
    }
    if (-not $state.defaultEnvironmentBefore) {
        $state.defaultEnvironmentBefore = Get-DemoDefaultSnapshot $config
        Write-DemoJson $statePath $state
    }

    $marker = "Power Platform VNet configuration demo; deployment=$($config.deploymentId); configuration-only"
    $savedCreation = Get-DemoField $state 'environmentCreationOperationUri'
    if (-not $state.environmentId -and $savedCreation) {
        $state.environmentId = Wait-DemoEnvironmentCreation $config $savedCreation ($ProvisioningTimeoutMinutes * 60)
        Write-DemoJson $statePath $state
    }
    if (-not $state.environmentId) {
        $list = Invoke-DemoHttp $config 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2023-06-01'
        if (Get-DemoField $list.Body 'nextLink') { throw 'Environment list is paginated; resolve the existing environment ID before proceeding.' }
        $namedEnvironments = @((Get-DemoField $list.Body 'value' -Required) | Where-Object {
            (Get-DemoField (Get-DemoField $_ 'properties') 'displayName') -eq $config.environmentName
        })
        if ($namedEnvironments.Count -gt 1) { throw 'Multiple environments have the demo name; refusing to choose one.' }
        if ($namedEnvironments.Count -eq 1) {
            if ((Get-DemoField (Get-DemoField $namedEnvironments[0] 'properties') 'description') -ne $marker) {
                throw 'An unrelated environment already uses the demo name.'
            }
            $state.environmentId = Get-DemoField $namedEnvironments[0] 'name' -Required
        } else {
            $state.phase = 'creating-environment'
            Write-DemoJson $statePath $state
            $body = @{
                properties = @{
                    displayName = $config.environmentName
                    description = $marker
                    environmentSku = 'Developer'
                    azureRegion = $config.preferredAzureRegion
                    databaseType = 'CommonDataService'
                    linkedEnvironmentMetadata = @{
                        baseLanguage = [string]$config.baseLanguage
                        currency = @{ code = $config.currency }
                        templates = @()
                    }
                }
            }
            $locations = Invoke-DemoHttp $config 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/locations?api-version=2023-06-01'
            $mode = Get-DemoField $locations.Body 'tenantProvisioningMode' -Required
            if ($mode -eq 'macroRegion') {
                $macros = @(Get-DemoField $locations.Body 'macroRegions' -Required)
                if (-not @($macros | Where-Object {
                    (Get-DemoField $_ 'macroRegionId') -eq $config.environmentMacroRegion
                }).Count) {
                    throw 'The approved North America macro region is not supported by this tenant.'
                }
                $body.macroRegion = $config.environmentMacroRegion
            } elseif ($mode -eq 'location') {
                $body.location = $config.environmentLocation
            } else {
                throw "Unsupported tenant provisioning mode: $mode"
            }
            $state.environmentProvisioningMode = $mode
            Write-DemoJson "$root/.azure/environment-request.json" $body
            $created = Invoke-DemoHttp $config 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments?api-version=2023-06-01&id=/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments' -Method POST -Body $body
            if ($created.StatusCode -ne 202 -or -not $created.Headers['Location']) {
                throw "Environment creation did not return the expected asynchronous operation: $($created.Content)"
            }
            $operationUri = [string]@($created.Headers['Location'])[0]
            $state.environmentCreationOperationUri = $operationUri
            Write-DemoJson $statePath $state
            $state.environmentId = Wait-DemoEnvironmentCreation $config $operationUri ($ProvisioningTimeoutMinutes * 60)
        }
        Write-DemoJson $statePath $state
    }
    if ($state.environmentId -eq $config.defaultEnvironmentId) { throw 'The default environment can never be the demo target.' }

    $creationOperation = Get-DemoField $state 'environmentCreationOperationUri'
    $deadline = [DateTime]::UtcNow.AddMinutes($ProvisioningTimeoutMinutes)
    if ($creationOperation) {
        $createdEnvironmentId = Wait-DemoEnvironmentCreation $config $creationOperation ($ProvisioningTimeoutMinutes * 60)
        if ($createdEnvironmentId -ne $state.environmentId) { throw 'Saved creation operation identifies a different environment.' }
    }
    do {
        $environment = Get-DemoEnvironment $config $state.environmentId
        $properties = Get-DemoField $environment 'properties' -Required
        $provisioningState = Get-DemoField $properties 'provisioningState' -Required
        if ($provisioningState -eq 'Succeeded') { break }
        if ($provisioningState -eq 'Failed') { throw "Environment provisioning failed: $($environment | ConvertTo-Json -Depth 15 -Compress)" }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Developer environment provisioning timed out.' }
        Write-Host "Environment provisioning state: $provisioningState"
        Start-Sleep -Seconds 15
    } while ($true)
    if ((Get-DemoField $properties 'environmentSku' -Required) -ne 'Developer' -or
        (Get-DemoField $properties 'displayName' -Required) -ne $config.environmentName -or
        (Get-DemoField $properties 'description' -Required) -ne $marker) {
        throw 'The environment does not match the approved isolated Developer demo.'
    }
    $database = Get-DemoField $properties 'linkedEnvironmentMetadata' -Required
    $state.dataverseUrl = Get-DemoField $database 'instanceUrl' -Required
    if ([string]::IsNullOrWhiteSpace($state.dataverseUrl)) { throw 'The Developer Dataverse database URL is not available.' }
    $state.azureRegion = Get-DemoRegion $config $state.environmentId
    if ($state.azureRegion -notin @($config.networks.location) -or $environment.location -ne $config.policyLocation) {
        throw "The actual environment region/geography does not match the approved pair: $($state.azureRegion)/$($environment.location)"
    }
    $state.phase = 'enabling-managed-environment'
    Write-DemoJson $statePath $state
    $governance = Get-DemoField $properties 'governanceConfiguration'
    if ((Get-DemoField $governance 'protectionLevel') -ne 'Standard') {
        $null = Invoke-DemoHttp $config "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/$($state.environmentId)/governanceConfiguration?api-version=2021-04-01" -Method POST -Body @{ protectionLevel = 'Standard' }
    }
    $managedDeadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        $environment = Get-DemoEnvironment $config $state.environmentId
        $protection = Get-DemoField (Get-DemoField (Get-DemoField $environment 'properties') 'governanceConfiguration') 'protectionLevel'
        if ($protection -eq 'Standard') { break }
        if ([DateTime]::UtcNow -ge $managedDeadline) { throw 'Managed-environment configuration did not propagate within 10 minutes.' }
        Write-Host "Waiting for managed-environment configuration; current protection: $protection"
        Start-Sleep -Seconds 10
    } while ($true)
    $state.managedEnvironmentProtectionLevel = 'Standard'
    Write-DemoJson $statePath $state

    $state.phase = 'azure-preflight'
    Write-DemoJson $statePath $state
    $existingNetworks = @(Invoke-DemoAz -Arguments @('network', 'vnet', 'list', '--subscription', $config.subscriptionId) -Json)
    foreach ($network in $config.networks) {
        $range = Get-DemoCidr $network.addressPrefix
        foreach ($existing in $existingNetworks) {
            if ($existing.resourceGroup -eq $config.resourceGroupName) { continue }
            foreach ($prefix in $existing.addressSpace.addressPrefixes) {
                if ($prefix.Contains(':')) { continue }
                $other = Get-DemoCidr $prefix
                if ($range.Start -le $other.End -and $other.Start -le $range.End) {
                    throw "Approved address range overlaps an existing VNet: $($existing.id)"
                }
            }
        }
    }
    $groupExists = Invoke-DemoAz -Arguments @('group', 'exists', '--subscription', $config.subscriptionId, '--name', $config.resourceGroupName) -Json
    if ($groupExists) {
        $group = Invoke-DemoAz -Arguments @('group', 'show', '--subscription', $config.subscriptionId, '--name', $config.resourceGroupName) -Json
        if ((Get-DemoField (Get-DemoField $group 'tags') 'deploymentId') -ne $config.deploymentId) {
            throw 'The resource group already exists and is not owned by this demo.'
        }
    }
    $provider = Invoke-DemoAz -Arguments @('provider', 'show', '--subscription', $config.subscriptionId, '--namespace', 'Microsoft.PowerPlatform') -Json
    if ($provider.registrationState -ne 'Registered') {
        $null = Invoke-DemoAz -Arguments @('provider', 'register', '--subscription', $config.subscriptionId, '--namespace', 'Microsoft.PowerPlatform', '--wait')
        $provider = Invoke-DemoAz -Arguments @('provider', 'show', '--subscription', $config.subscriptionId, '--namespace', 'Microsoft.PowerPlatform') -Json
        if ($provider.registrationState -ne 'Registered') { throw 'Microsoft.PowerPlatform registration did not complete.' }
    }
    $deploymentArguments = @('--subscription', $config.subscriptionId, '--location', $config.resourceGroupLocation, '--name', $config.deploymentId, '--template-file', "$root/.azure/compiled/main.json", '--parameters', "$root/.azure/compiled/parameters.json")
    $preview = Invoke-DemoAz -Arguments (@('deployment', 'sub', 'what-if') + $deploymentArguments + @('--no-pretty-print')) -Json
    Write-DemoJson "$root/.azure/what-if.json" $preview
    $changes = @(Get-DemoField $preview 'changes' -Required)
    $scope = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)"
    foreach ($change in $changes) {
        if ($change.changeType -notin @('Create', 'NoChange', 'Ignore')) {
            throw "What-if proposes an unapproved change: $($change.changeType) $($change.resourceId)"
        }
        if ($change.changeType -eq 'Create' -and $change.resourceId -ine $scope -and
            -not $change.resourceId.StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase)) {
            throw "What-if proposes a creation outside the approved resource group: $($change.resourceId)"
        }
    }
    $state.phase = 'deploying-azure'
    Write-DemoJson $statePath $state
    $deployment = Invoke-DemoAz -Arguments (@('deployment', 'sub', 'create') + $deploymentArguments) -Json
    if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'Azure deployment did not succeed.' }
    $state.policyId = $deployment.properties.outputs.policyId.value
    $expectedPolicyId = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)/providers/Microsoft.PowerPlatform/enterprisePolicies/$($config.policyName)"
    if ($state.policyId -ine $expectedPolicyId) { throw 'Deployment returned an out-of-scope policy ID.' }
    $state.azureDeploymentId = $deployment.id
    Write-DemoJson $statePath $state

    $policy = Invoke-DemoAz -Arguments @('resource', 'show', '--subscription', $config.subscriptionId, '--ids', $state.policyId, '--api-version', '2020-10-30') -Json
    $systemId = Get-DemoField (Get-DemoField $policy 'properties' -Required) 'systemId' -Required
    $environment = Get-DemoEnvironment $config $state.environmentId
    $linkedPolicy = Get-DemoField (Get-DemoField (Get-DemoField (Get-DemoField $environment 'properties') 'enterprisePolicies') 'VNets') 'id'
    if ($linkedPolicy -and $linkedPolicy -ine $state.policyId) { throw 'The demo environment already has a different policy; refusing to replace it.' }
    if (-not $linkedPolicy) {
        $state.phase = 'associating-policy'
        Write-DemoJson $statePath $state
        $association = Invoke-DemoHttp $config "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/$($state.environmentId)/enterprisePolicies/NetworkInjection/link?api-version=2019-10-01" -Method POST -Body @{ SystemId = $systemId }
        if ($association.StatusCode -ne 202 -or -not $association.Headers['operation-location']) {
            throw "Policy association did not return an asynchronous operation: $($association.Content)"
        }
        $state.associationOperationUri = [string]@($association.Headers['operation-location'])[0]
        Write-DemoJson $statePath $state
    }
    if ($state.associationOperationUri) {
        Wait-DemoPolicyOperation $config $state.associationOperationUri
        $state.associationOperationState = 'Succeeded'
        Write-DemoJson $statePath $state
    }
    $state.phase = 'verifying'
    Write-DemoJson $statePath $state
    & "$PSScriptRoot/Verify-Demo.ps1" -AzureConfigDirectory $AzureConfigDirectory
    $state.phase = 'completed'
    $state.completed = $true
    $state.completedAt = [DateTime]::UtcNow.ToString('o')
    if ($state.Contains('lastError')) { $state.Remove('lastError') }
    Write-DemoJson $statePath $state
    $plan.meta.status = 'deployed'
    Write-DemoJson "$root/.azure/infrastructure-plan.json" $plan
    Write-Output "Demo verified. Environment: $($state.environmentId). Policy: $($state.policyId)."
} catch {
    $state.completed = $false
    $state.lastError = $_.Exception.Message
    Write-DemoJson $statePath $state
    Write-Error "Demo stopped at phase '$($state.phase)': $($_.Exception.Message)" -ErrorAction Continue
    throw
}
