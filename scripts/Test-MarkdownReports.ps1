[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Demo.Common.ps1"
. "$PSScriptRoot/Demo.Reports.ps1"
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pp-markdown-report-tests-' + [guid]::NewGuid().ToString('N'))
$reports = Join-Path $testRoot 'reports'
$null = [IO.Directory]::CreateDirectory($reports)
try {
    foreach ($name in @('private-network-proof.template.md', 'private-path-report.template.md')) {
        Copy-Item -LiteralPath (Join-Path "$root/reports" $name) -Destination (Join-Path $reports $name)
    }
    $result = [ordered]@{
        status = 'Succeeded'
        privateNetworkPathProven = $true
        environmentId = '00000000-0000-0000-0000-000000000000'
        region = 'westus'
        delegatedSourceSubnet = '172.20.0.0/24'
        hostname = 'example.blob.core.windows.net'
        privateEndpointIp = '172.20.1.4'
        sourceIps = [ordered]@{ dns = '172.20.0.4'; tcp = '172.20.0.4'; tls = '172.20.0.5' }
        verifiedAt = '2026-01-01T00:00:00Z'
        certificateRevocationCheckSucceeded = $true
        targetPublicNetworkAccess = 'Disabled'
        publicControl = @{ httpStatus = 403; errorCode = 'AuthorizationFailure' }
        error = $null
    }
    $path = Write-DemoPrivatePathReport -Result $result -EnvironmentName 'Offline test fixture' -ProjectRoot $testRoot
    $content = Get-Content -LiteralPath $path -Raw
    foreach ($expected in @(
        '| Overall status | Succeeded |',
        '| Private network path proven | True |',
        '| Actual probe source IPs | 172.20.0.4, 172.20.0.5 |',
        '| Authenticated public-client negative control | 403 AuthorizationFailure |',
        '| Certificate revocation check | Passed |'
    )) {
        if (-not $content.Contains($expected)) { throw "Missing successful report field: $expected" }
    }
    if ($path -notlike '*.md' -or $content -match '__[A-Z_]+__|<html|<script') {
        throw 'The successful report is not fully rendered Markdown.'
    }
    $result.certificateRevocationCheckSucceeded = $false
    $null = Write-DemoPrivatePathReport -Result $result -EnvironmentName 'Offline test fixture' -ProjectRoot $testRoot
    if (-not (Get-Content -LiteralPath $path -Raw).Contains('| Certificate revocation check | Failed; see raw evidence |')) {
        throw 'A failed CRL check must remain explicit.'
    }

    $unsafeMessage = @'
Failure | <script>test</script>
```untrusted
[label](https://example.invalid) __REGION__
'@
    $result.status = 'Failed'
    $result.privateNetworkPathProven = $false
    $result.sourceIps = [ordered]@{}
    $result.publicControl = $null
    $result.targetPublicNetworkAccess = $null
    $result.error = $unsafeMessage
    $result.Remove('certificateRevocationCheckSucceeded')
    $null = Write-DemoPrivatePathReport -Result $result -EnvironmentName 'Fixture | [name] <tag>' -ProjectRoot $testRoot
    $content = Get-Content -LiteralPath $path -Raw
    foreach ($expected in @(
        '| Overall status | Failed |',
        '| Private network path proven | False |',
        '| Actual probe source IPs | Not returned |',
        '| Target public network access | Not verified |',
        '| Authenticated public-client negative control | Not tested |',
        '| Certificate revocation check | Not tested |',
        'Fixture \| \[name\] \<tag\>',
        'Failure \| \<script\>'
    )) {
        if (-not $content.Contains($expected)) { throw "Missing failed or escaped report field: $expected" }
    }
    if ($content.Contains('<script>') -or $content.Contains('[label](https://example.invalid)') -or
        $content -match '__[A-Z_]+__' -or ([regex]::Matches($content, '(?m)^```')).Count -ne 2 -or
        $content.Contains('Actual private DNS, direct private-IP TCP, and TLS probes passed.')) {
        throw 'A failed report must not inject markup or claim protocol success.'
    }
    $result.status = 'Running'
    $result.error = $null
    $null = Write-DemoPrivatePathReport -Result $result -EnvironmentName 'Offline test fixture' -ProjectRoot $testRoot
    if (-not (Get-Content -LiteralPath $path -Raw).Contains('A completed private-target protocol proof was not produced.')) {
        throw 'An incomplete report must not use a success-shaped message.'
    }

    $report = [ordered]@{
        status = 'Blocked'
        environmentName = 'Offline capability fixture'
        environmentId = '00000000-0000-0000-0000-000000000000'
        region = 'westus'
        expectedSourceSubnet = '172.20.0.0/24'
        sourceContainerIp = $null
        completedAt = '2026-01-01T00:00:00Z'
        configurationAssociationLinked = $true
        failure = @{ message = $unsafeMessage }
    }
    $capabilityPath = Write-DemoCapabilityReport -Report $report -ProjectRoot $testRoot
    $capability = Get-Content -LiteralPath $capabilityPath -Raw
    if (-not $capability.Contains('| Capability status | Blocked |') -or
        -not $capability.Contains('| Observed container IP | Not returned |') -or
        -not $capability.Contains('This report does not prove a private-target network path.') -or
        $capability.Contains('<script>') -or $capability -match '__[A-Z_]+__') {
        throw 'The blocked capability result lost its explicit status or scope.'
    }
    $report.status = 'CapabilityReady'
    $report.sourceContainerIp = '172.20.0.4'
    $report.failure = $null
    $null = Write-DemoCapabilityReport -Report $report -ProjectRoot $testRoot
    $capability = Get-Content -LiteralPath $capabilityPath -Raw
    if (-not $capability.Contains('| Capability status | CapabilityReady |') -or
        -not $capability.Contains('| Observed container IP | 172.20.0.4 |') -or
        -not $capability.Contains('this report does not prove private-target traffic.')) {
        throw 'Capability readiness must not be confused with private-target proof.'
    }

    $rejected = $false
    try {
        Write-DemoMarkdownReport -TemplatePath "$reports/private-network-proof.template.md" -OutputPath "$reports/missing.md" -Values @{}
    } catch {
        if ($_.Exception.Message -notmatch 'Required Markdown report value is missing') { throw }
        $rejected = $true
    }
    if (-not $rejected -or (Test-Path -LiteralPath "$reports/missing.md")) {
        throw 'Missing template values must fail before a report is written.'
    }
    Write-Output 'PASS: offline Markdown rendering, success/failure/incomplete states, source-IP deduplication, explicit CRL status, escaped table/HTML/link/fence content, and missing-value rejection. No cloud calls.'
} finally {
    foreach ($name in @('private-network-proof.template.md', 'private-path-report.template.md', 'private-network-proof.md', 'private-path-capability.md', 'missing.md')) {
        $file = Join-Path $reports $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    Remove-Item -LiteralPath $reports -Force
    Remove-Item -LiteralPath $testRoot -Force
}
