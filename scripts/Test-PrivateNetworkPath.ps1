[CmdletBinding()]
param([string]$AzureConfigDirectory, [switch]$OpenReport)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($AzureConfigDirectory) { $env:AZURE_CONFIG_DIR = $AzureConfigDirectory }
. "$PSScriptRoot/Demo.Common.ps1"
. "$PSScriptRoot/Demo.Reports.ps1"
$config = Get-Content -LiteralPath "$root/demo.config.json" -Raw | ConvertFrom-Json
$target = Get-Content -LiteralPath "$root/.azure/private-path-target.json" -Raw | ConvertFrom-Json
$plan = Get-Content -LiteralPath "$root/.azure/private-path-plan.json" -Raw | ConvertFrom-Json
$coreState = Get-Content -LiteralPath "$root/.azure/deployment-state.json" -Raw | ConvertFrom-Json
if ($target.subscriptionId -ne $config.subscriptionId -or $target.region -ne 'westus' -or
    $target.hostname -ne "$($target.storageAccountName).blob.core.windows.net" -or
    $target.environmentId -ne $plan.inputs.environmentId -or $target.environmentId -ne $coreState.environmentId -or
    $target.deploymentId -ne $plan.meta.planId -or $target.delegatedSourceSubnet -ne '172.20.0.0/24') {
    throw 'Private-path target state differs from the approved subscription, region, or Storage FQDN.'
}
$scope = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)"
if ($target.storageAccountId -ine "$scope/providers/Microsoft.Storage/storageAccounts/$($target.storageAccountName)" -or
    $target.privateEndpointId -ine "$scope/providers/Microsoft.Network/privateEndpoints/pep-pp-path-blob") {
    throw 'The private target IDs are outside the approved demo scope.'
}
function Assert-PrivateProbeSource {
    param([object]$Body)
    $ip = Get-DemoField $Body 'ContainerIpAddress' -Required
    $source = Get-DemoCidr "$ip/32"
    $delegated = Get-DemoCidr $target.delegatedSourceSubnet
    if ($source.Start -lt $delegated.Start -or $source.End -gt $delegated.End) {
        throw "The actual Power Platform probe source is not in the delegated subnet: $ip"
    }
    return $ip
}
$result = [ordered]@{
    status = 'Running'
    startedAt = [DateTime]::UtcNow.ToString('o')
    verifiedAt = $null
    scope = 'Actual DNS, TCP, and TLS protocol traffic; not application payload read/write.'
    privateNetworkPathProven = $false
    applicationDataReadWriteTested = $false
    environmentId = $target.environmentId
    region = $target.region
    hostname = $target.hostname
    privateEndpointIp = $target.privateEndpointIp
    delegatedSourceSubnet = $target.delegatedSourceSubnet
    sourceIps = [ordered]@{}
    dns = $null
    tcp = $null
    tls = $null
    publicControl = $null
    targetPublicNetworkAccess = $null
    error = $null
}
$failure = $null
try {
    Assert-DemoAdministrator $config
    $environment = Get-DemoEnvironment $config $target.environmentId
    $association = Get-DemoField (Get-DemoField $environment.properties 'enterprisePolicies' -Required) 'VNets' -Required
    if ((Get-DemoField $association 'id' -Required) -ine $coreState.policyId -or
        (Get-DemoField $association 'linkStatus' -Required) -ne 'Linked' -or
        $environment.properties.displayName -ne $config.environmentName) {
        throw 'The actual probe environment is not the approved, policy-linked demo environment.'
    }
    $storage = Invoke-DemoAz -Arguments @('resource', 'show', '--subscription', $config.subscriptionId,
        '--ids', $target.storageAccountId, '--api-version', '2025-01-01') -Json
    if ($storage.properties.publicNetworkAccess -ne 'Disabled' -or
        $storage.properties.allowSharedKeyAccess -ne $false -or
        $storage.properties.networkAcls.bypass -ne 'None') {
        throw 'The target must disable public network access, shared-key access, and firewall bypass.'
    }
    $result.targetPublicNetworkAccess = 'Disabled'
    $endpoint = Invoke-DemoAz -Arguments @('network', 'private-endpoint', 'show', '--subscription', $config.subscriptionId,
        '--resource-group', $config.resourceGroupName, '--name', 'pep-pp-path-blob') -Json
    if ($endpoint.privateLinkServiceConnections[0].privateLinkServiceId -ine $target.storageAccountId -or
        $endpoint.privateLinkServiceConnections[0].privateLinkServiceConnectionState.status -ne 'Approved') {
        throw 'The endpoint is not approved for the exact Storage test account.'
    }
    $nic = Invoke-DemoAz -Arguments @('network', 'nic', 'show', '--subscription', $config.subscriptionId,
        '--ids', $endpoint.networkInterfaces[0].id) -Json
    if ($nic.ipConfigurations[0].privateIPAddress -ne $target.privateEndpointIp) {
        throw 'The expected destination is not the current Private Endpoint NIC IP.'
    }
    $hostName = Get-DemoEnvironmentApiHost $target.environmentId
    $base = "https://$hostName/plex"
    $query = "api-version=2026-02-01&region=$($target.region)"
    $dns = Invoke-DemoHttp $config "$base/resolveDns?$query" -Method POST -Resource 'https://api.powerplatform.com/' -Body @{ HostName = $target.hostname } -ReadOnlyDiagnostic
    $result.dns = $dns.Body
    $result.sourceIps.dns = Assert-PrivateProbeSource $dns.Body
    $addresses = @(Get-DemoField $dns.Body 'IPAddresses' -Required)
    if ((Get-DemoField $dns.Body 'Success' -Required) -ne $true -or $addresses.Count -ne 1 -or $addresses[0] -ne $target.privateEndpointIp) {
        throw 'The real Power Platform DNS result is not exclusively the approved Private Endpoint IP.'
    }
    $tcp = Invoke-DemoHttp $config "$base/testConnection?$query" -Method POST -Resource 'https://api.powerplatform.com/' -Body @{ Destination = $target.privateEndpointIp; Port = '443' } -ReadOnlyDiagnostic
    $result.tcp = $tcp.Body
    $result.sourceIps.tcp = Assert-PrivateProbeSource $tcp.Body
    if ((Get-DemoField $tcp.Body 'TCPSuccess' -Required) -ne $true) {
        throw 'The actual TCP connection directly to the private IP failed.'
    }
    $tls = Invoke-DemoHttp $config "$base/testTLSConnection?$query" -Method POST -Resource 'https://api.powerplatform.com/' -Body @{ Destination = $target.hostname; Port = '443' } -ReadOnlyDiagnostic
    $result.tls = $tls.Body
    $result.sourceIps.tls = Assert-PrivateProbeSource $tls.Body
    $ssl = Get-DemoField $tls.Body 'SSLWithoutCRL' -Required
    $certificate = Get-DemoField $tls.Body 'Certificate' -Required
    if ((Get-DemoField $tls.Body 'TCPConnectivity' -Required) -ne $true -or
        (Get-DemoField $ssl 'Success' -Required) -ne $true -or
        (Get-DemoField $ssl 'SslErrors' -Required) -notin @('None', '0', '') -or
        (Get-DemoField $certificate 'IsExpired' -Required) -ne $false -or
        (Get-DemoField $certificate 'IsSelfSigned' -Required) -ne $false) {
        throw 'The actual TLS handshake or certificate checks failed.'
    }
    $crl = Get-DemoField $tls.Body 'SSLWithCRL' -Required
    $result.certificateRevocationCheckSucceeded = (Get-DemoField $crl 'Success' -Required) -eq $true
    if (-not $result.certificateRevocationCheckSucceeded) {
        Write-Warning 'TLS succeeded without CRL checking, but the CRL check failed. The evidence explicitly records this limitation.'
    }
    $publicAddresses = @([Net.Dns]::GetHostAddresses($target.hostname) | ForEach-Object { $_.ToString() })
    if ($publicAddresses -contains $target.privateEndpointIp) { throw 'The workstation resolves the private IP; it is not a valid public-client control.' }
    $readerAssignments = @(Invoke-DemoAz -Arguments @('role', 'assignment', 'list', '--subscription', $config.subscriptionId,
        '--scope', $target.storageAccountId, '--fill-principal-name', 'false') -Json)
    if (-not @($readerAssignments | Where-Object {
        $_.principalId -eq $config.principalId -and $_.roleDefinitionId.EndsWith('/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
    }).Count) { throw 'The public-control identity has not been assigned the approved Blob Data Reader role.' }
    $clientRequestId = [guid]::NewGuid().ToString()
    $public = Invoke-WebRequest -Method Get -Uri "https://$($target.hostname)/?comp=list" -Headers @{
        Authorization = "Bearer $(Get-DemoToken $config 'https://storage.azure.com/')"
        'x-ms-version' = '2023-11-03'
        'x-ms-date' = [DateTime]::UtcNow.ToString('R')
        'x-ms-client-request-id' = $clientRequestId
    } -TimeoutSec 30 -MaximumRedirection 0 -SkipHttpErrorCheck
    $errorCode = [string]@($public.Headers['x-ms-error-code'])[0]
    $result.publicControl = [ordered]@{
        httpStatus = [int]$public.StatusCode
        errorCode = $errorCode
        clientRequestId = $clientRequestId
        publicDnsAddresses = $publicAddresses
        authenticatedIdentityVerified = $true
        accountScopedReaderAssignmentPresent = $true
        responseBody = [string]$public.Content
    }
    if ([int]$public.StatusCode -ne 403 -or $errorCode -ne 'AuthorizationFailure') {
        throw 'The public-client request did not produce the expected network-denial evidence. Authentication errors are not accepted as proof.'
    }
    $result.status = 'Succeeded'
    $result.privateNetworkPathProven = $true
} catch {
    $failure = $_
    $result.status = 'Failed'
    $result.privateNetworkPathProven = $false
    $result.error = $_.Exception.Message
    Write-Error "Actual private-path test failed: $($_.Exception.Message)" -ErrorAction Continue
} finally {
    $result.verifiedAt = [DateTime]::UtcNow.ToString('o')
    $result.durationSeconds = [Math]::Round(([DateTime]$result.verifiedAt - [DateTime]$result.startedAt).TotalSeconds, 1)
    Write-DemoJson "$root/.azure/private-path-verification.json" $result
    $path = Write-DemoPrivatePathReport -Result $result -EnvironmentName $config.environmentName -ProjectRoot $root
    if ($OpenReport) { if ($IsMacOS) { & /usr/bin/open $path } else { Start-Process $path } }
}
if ($failure) { throw $failure }
$result | ConvertTo-Json -Depth 20
