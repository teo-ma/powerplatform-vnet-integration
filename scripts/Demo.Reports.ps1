Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-DemoMarkdownText {
    param([AllowNull()][object]$Value)
    $text = [string]$Value -replace '[\r\n\t]+', ' '
    return [regex]::Replace($text, '[\\`*_{}\[\]()|<>~&]', {
        param($match)
        return '\' + $match.Value
    })
}

function Write-DemoMarkdownReport {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )
    if ([IO.Path]::GetExtension($OutputPath) -ne '.md') {
        throw 'Generated reports must use the Markdown extension.'
    }
    $template = Get-Content -LiteralPath $TemplatePath -Raw
    $content = [regex]::Replace($template, '__([A-Z_]+)__', {
        param($match)
        $key = $match.Groups[1].Value
        if (-not $Values.Contains($key)) { throw "Required Markdown report value is missing: $key" }
        return ConvertTo-DemoMarkdownText $Values[$key]
    })
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
    $content | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

function Write-DemoPrivatePathReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    $sourceIps = @($Result.sourceIps.Values | Select-Object -Unique) -join ', '
    $crl = Get-DemoField $Result 'certificateRevocationCheckSucceeded'
    $values = @{
        STATUS = Get-DemoField $Result 'status' -Required
        PROVEN = Get-DemoField $Result 'privateNetworkPathProven' -Required
        ENVIRONMENT = $EnvironmentName
        ENVIRONMENT_ID = Get-DemoField $Result 'environmentId' -Required
        REGION = Get-DemoField $Result 'region' -Required
        SUBNET = Get-DemoField $Result 'delegatedSourceSubnet' -Required
        HOSTNAME = Get-DemoField $Result 'hostname' -Required
        TARGET_IP = Get-DemoField $Result 'privateEndpointIp' -Required
        SOURCE_IPS = if ($sourceIps) { $sourceIps } else { 'Not returned' }
        TIME = Get-DemoField $Result 'verifiedAt' -Required
        DETAILS = if ($Result.error) { $Result.error } elseif ($Result.status -eq 'Succeeded' -and $Result.privateNetworkPathProven) {
            'Actual private DNS, direct private-IP TCP, and TLS probes passed. Public access is disabled and the authenticated public-client request was denied. Business data read/write was not tested.'
        } else { 'A completed private-target protocol proof was not produced. See the raw evidence.' }
        CRL = if ($crl -eq $true) { 'Passed' } elseif ($crl -eq $false) { 'Failed; see raw evidence' } else { 'Not tested' }
        PUBLIC = if ($Result.publicControl) { "$($Result.publicControl.httpStatus) $($Result.publicControl.errorCode)" } else { 'Not tested' }
        PUBLIC_NETWORK = if ($Result.targetPublicNetworkAccess) { $Result.targetPublicNetworkAccess } else { 'Not verified' }
    }
    $path = Join-Path $ProjectRoot 'reports/private-network-proof.md'
    Write-DemoMarkdownReport -TemplatePath (Join-Path $ProjectRoot 'reports/private-network-proof.template.md') -OutputPath $path -Values $values
    return $path
}

function Write-DemoCapabilityReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Report,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    $values = @{
        STATUS = Get-DemoField $Report 'status' -Required
        ENVIRONMENT = Get-DemoField $Report 'environmentName' -Required
        ENVIRONMENT_ID = Get-DemoField $Report 'environmentId' -Required
        REGION = Get-DemoField $Report 'region' -Required
        SUBNET = Get-DemoField $Report 'expectedSourceSubnet' -Required
        SOURCE_IP = if ($Report.sourceContainerIp) { $Report.sourceContainerIp } else { 'Not returned' }
        TIME = Get-DemoField $Report 'completedAt' -Required
        ASSOCIATION = if ($Report.configurationAssociationLinked) { 'Linked' } else { 'Not verified' }
        ERROR = if ($Report.failure) { $Report.failure.message } elseif ($Report.status -eq 'CapabilityReady' -and $Report.sourceContainerIp) {
            'The diagnostic source is in the delegated subnet. A private target must still be deployed and tested; this report does not prove private-target traffic.'
        } else { 'The delegated-subnet capability check has not completed successfully. See the raw evidence.' }
    }
    $path = Join-Path $ProjectRoot 'reports/private-path-capability.md'
    Write-DemoMarkdownReport -TemplatePath (Join-Path $ProjectRoot 'reports/private-path-report.template.md') -OutputPath $path -Values $values
    return $path
}
