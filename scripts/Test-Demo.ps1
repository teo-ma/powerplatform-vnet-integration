[CmdletBinding()]
param([string]$AzureConfigDirectory)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($AzureConfigDirectory) { $env:AZURE_CONFIG_DIR = $AzureConfigDirectory }
. "$PSScriptRoot/Demo.Common.ps1"
$config = Get-Content -LiteralPath "$root/demo.config.json" -Raw | ConvertFrom-Json

foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$($file.Name) has syntax errors: $($errors.Message -join '; ')" }
}

if ($config.networks.Count -ne 2 -or ((@($config.networks.location | Sort-Object) -join ',') -ne 'eastus,westus')) {
    throw 'The approved United States region pair must be eastus and westus.'
}
$ranges = @()
foreach ($network in $config.networks) {
    if ($network.name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}[a-zA-Z0-9_]$') { throw 'Invalid VNet name.' }
    $range = Get-DemoCidr $network.addressPrefix
    $subnet = Get-DemoCidr $network.subnetPrefix
    if ($subnet.Prefix -ne 24 -or $subnet.Start -lt $range.Start -or $subnet.End -gt $range.End) {
        throw 'Each approved subnet must be a /24 inside its VNet.'
    }
    foreach ($other in $ranges) {
        if ($range.Start -le $other.End -and $other.Start -le $range.End) { throw 'Approved VNet address ranges overlap.' }
    }
    $ranges += $range
}

$template = Invoke-DemoAz -Arguments @('bicep', 'build', '--file', "$root/infra/main.bicep", '--stdout') -Json
$parameterFile = Invoke-DemoAz -Arguments @('bicep', 'build-params', '--file', "$root/infra/main.bicepparam", '--stdout') -Json
$parameterJson = Get-DemoField $parameterFile 'parametersJson'
if ($parameterJson) { $parameterFile = $parameterJson | ConvertFrom-Json }
$parameters = Get-DemoField $parameterFile 'parameters' -Required
foreach ($name in @('resourceGroupName', 'resourceGroupLocation', 'policyName', 'policyLocation', 'subnetName')) {
    if ((Get-DemoField (Get-DemoField $parameters $name -Required) 'value' -Required) -ne $config.$name) {
        throw "Bicep and configuration disagree on $name."
    }
}
$parameterNetworks = Get-DemoField (Get-DemoField $parameters 'networks' -Required) 'value' -Required
if (@($parameterNetworks).Count -ne $config.networks.Count) { throw 'Bicep and configuration disagree on network count.' }
for ($index = 0; $index -lt $config.networks.Count; $index++) {
    foreach ($field in @('name', 'nsgName', 'location', 'addressPrefix', 'subnetPrefix')) {
        if ($parameterNetworks[$index].$field -ne $config.networks[$index].$field) {
            throw "Bicep and configuration disagree on network $index field $field."
        }
    }
}
$deployment = @($template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' })
if ($deployment.Count -ne 1) { throw 'Expected one networking deployment module.' }
$types = @($deployment[0].properties.template.resources.type)
if (@($types | Where-Object { $_ -notin @('Microsoft.Network/networkSecurityGroups', 'Microsoft.Network/virtualNetworks', 'Microsoft.PowerPlatform/enterprisePolicies') }).Count) {
    throw 'Unexpected resource type in the networking template.'
}
if ($types -notcontains 'Microsoft.PowerPlatform/enterprisePolicies') { throw 'Enterprise policy is missing.' }
$scanner = Get-Command checkov -CommandType Application -ErrorAction SilentlyContinue
$securityScan = @{
    status = if ($scanner) { 'NotRun' } else { 'Unavailable' }
    reason = if ($scanner) {
        'Record the separate scanner result; this validation does not run Checkov.'
    } else {
        'Checkov is not installed. Automated security scanning was not performed.'
    }
}
if (-not $scanner) { Write-Warning $securityScan.reason }
Write-DemoJson "$root/.azure/compiled/main.json" $template
Write-DemoJson "$root/.azure/compiled/parameters.json" $parameterFile
Write-DemoJson "$root/.azure/validation.json" ([ordered]@{
    verifiedAt = [DateTime]::UtcNow.ToString('o')
    status = 'Succeeded'
    powershellSyntax = 'Passed'
    networkRegionsNamesAndAddresses = 'Passed'
    bicepBuild = 'Passed'
    bicepParametersMatchConfig = 'Passed'
    approvedResourceTypes = 'Passed'
    checkov = $securityScan
})
Write-Output 'PASS: PowerShell syntax, region pair, names, equal /24 subnet sizes, nonoverlap, Bicep build, parameters, and approved resource types.'
