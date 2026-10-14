[CmdletBinding()]
param(
    [string]$AzureConfigDirectory,
    [ValidateRange(0, 30)][int]$WaitForPropagationMinutes = 0,
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($AzureConfigDirectory) { $env:AZURE_CONFIG_DIR = $AzureConfigDirectory }
. "$PSScriptRoot/Demo.Common.ps1"
. "$PSScriptRoot/Demo.Reports.ps1"
$config = Get-Content -LiteralPath "$root/demo.config.json" -Raw | ConvertFrom-Json
$plan = Get-Content -LiteralPath "$root/.azure/private-path-plan.json" -Raw | ConvertFrom-Json
if (-not $plan.meta.diagnosticOnlyScopeApproved -or $plan.inputs.subscriptionId -ne $config.subscriptionId) {
    throw 'The private-path diagnostic precheck has not been approved for this subscription.'
}
$environmentId = $plan.inputs.environmentId
$region = $plan.inputs.region
$network = @($config.networks | Where-Object { $_.location -eq $region })
if ($network.Count -ne 1) { throw 'The selected diagnostic region does not identify exactly one approved VNet.' }
$report = [ordered]@{
    schemaVersion = '1'
    status = 'Checking'
    scope = 'Diagnostic capability precheck, not private-target data transfer.'
    environmentName = $config.environmentName
    environmentId = $environmentId
    region = $region
    targetHost = 'microsoft.com'
    expectedSourceSubnet = $network[0].subnetPrefix
    privateNetworkPathProven = $false
    applicationDataReadWriteTested = $false
    chargeableTestBackendCreated = $false
    configurationAssociationLinked = $false
    runtimeMapping = $null
    dnsProbe = $null
    sourceContainerIp = $null
    failure = $null
    attemptedAt = [DateTime]::UtcNow.ToString('o')
    completedAt = $null
}
$failureRecord = $null
$stage = 'administrator-check'
try {
    Assert-DemoAdministrator $config
    $stage = 'configuration-association'
    $environment = Get-DemoEnvironment $config $environmentId
    $association = Get-DemoField (Get-DemoField $environment.properties 'enterprisePolicies' -Required) 'VNets' -Required
    if ((Get-DemoField $association 'linkStatus' -Required) -ne 'Linked') { throw 'The demo policy is not linked.' }
    $report.configurationAssociationLinked = $true
    $hostName = Get-DemoEnvironmentApiHost $environmentId
    $stage = 'delegated-subnet-dns-probe'
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitForPropagationMinutes)
    do {
        try {
            $probe = Invoke-DemoHttp $config "https://$hostName/plex/resolveDns?api-version=2026-02-01&region=$region" -Method POST -Resource 'https://api.powerplatform.com/' -Body @{ HostName = $report.targetHost } -ReadOnlyDiagnostic
            break
        } catch {
            $pendingMapping = $_.Exception.Data['HttpStatus'] -eq 404 -and
                ([string]$_.Exception.Data['ResponseBody']).Contains('Subnet information not found')
            if (-not $pendingMapping -or [DateTime]::UtcNow -ge $deadline) { throw }
            Write-Warning 'The diagnostic service still reports Subnet information not found. Waiting 30 seconds within the explicitly bounded propagation window.'
            Start-Sleep -Seconds 30
        }
    } while ($true)
    $report.dnsProbe = $probe.Body
    if ((Get-DemoField $probe.Body 'Success' -Required) -ne $true) {
        throw "The actual DNS probe failed: $($probe.Content)"
    }
    $source = Get-DemoField $probe.Body 'ContainerIpAddress' -Required
    $sourceRange = Get-DemoCidr "$source/32"
    $expectedRange = Get-DemoCidr $network[0].subnetPrefix
    if ($sourceRange.Start -lt $expectedRange.Start -or $sourceRange.End -gt $expectedRange.End) {
        throw 'The actual diagnostic source IP is not in the delegated subnet.'
    }
    $report.sourceContainerIp = $source
    # An idle environment can have no networkUsage entry until a probe allocates a container.
    $stage = 'runtime-network-mapping'
    $usage = Invoke-DemoHttp $config "https://$hostName/plex/networkUsage?api-version=2024-10-01&region=$region" -Resource 'https://api.powerplatform.com/'
    $report.runtimeMapping = $usage.Body
    $actualVnet = Invoke-DemoAz -Arguments @('network', 'vnet', 'show', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--name', $network[0].name) -Json
    if ((Get-DemoField $usage.Body 'vNetId' -Required) -ne $actualVnet.resourceGuid -or
        (Get-DemoField $usage.Body 'subnetIpRange' -Required) -ne $network[0].subnetPrefix) {
        throw 'The runtime mapping does not match the actual demo VNet GUID and delegated subnet.'
    }
    $report.status = 'CapabilityReady'
    Write-Output 'The delegated-subnet DNS diagnostic is working. Private-target TCP/TLS tests have not yet been performed.'
} catch {
    $failureRecord = $_
    $report.status = 'Blocked'
    $report.failure = [ordered]@{
        stage = $stage
        message = $_.Exception.Message
        httpStatus = $_.Exception.Data['HttpStatus']
        requestUri = $_.Exception.Data['RequestUri']
        responseBody = $_.Exception.Data['ResponseBody']
        rootCauseConfirmed = $false
    }
    Write-Error "Private-path capability precheck blocked at ${stage}: $($_.Exception.Message)" -ErrorAction Continue
} finally {
    $report.completedAt = [DateTime]::UtcNow.ToString('o')
    Write-DemoJson "$root/.azure/private-path-capability.json" $report
    $reportPath = Write-DemoCapabilityReport -Report $report -ProjectRoot $root
    Write-Output "Evidence: $root/.azure/private-path-capability.json"
    Write-Output "Report: $reportPath"
    if ($OpenReport) {
        if ($IsMacOS) { & /usr/bin/open $reportPath } else { Start-Process $reportPath }
    }
}
if ($null -ne $failureRecord) { throw $failureRecord }
