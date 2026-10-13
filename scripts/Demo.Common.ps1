Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DemoField {
    param([AllowNull()][object]$Object, [string]$Name, [switch]$Required)
    if ($null -ne $Object) {
        if ($Object -is [System.Collections.IDictionary]) {
            foreach ($key in $Object.Keys) {
                if ([string]$key -ieq $Name) { return $Object[$key] }
            }
        } else {
            $property = $Object.PSObject.Properties[$Name]
            if ($null -ne $property) { return $property.Value }
        }
    }
    if ($Required) { throw "Required response field is missing: $Name" }
    return $null
}

function Invoke-DemoAz {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json)
    $errorFile = [IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments --only-show-errors --output json 2> $errorFile
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $detail = Get-Content -LiteralPath $errorFile -Raw
            throw "Azure CLI failed with exit code ${exitCode}: $detail"
        }
        $diagnostics = Get-Content -LiteralPath $errorFile -Raw
        if (-not [string]::IsNullOrWhiteSpace($diagnostics)) { Write-Warning $diagnostics.Trim() }
        $text = $output -join [Environment]::NewLine
        if ($Json) {
            if ([string]::IsNullOrWhiteSpace($text)) { throw 'Azure CLI returned no required JSON result.' }
            return $text | ConvertFrom-Json
        }
        return $text
    } finally {
        Remove-Item -LiteralPath $errorFile -Force
    }
}

function Get-DemoToken {
    param([object]$Config, [string]$Resource)
    $token = Invoke-DemoAz -Arguments @('account', 'get-access-token', '--subscription', $Config.subscriptionId, '--resource', $Resource) -Json
    $accessToken = Get-DemoField $token 'accessToken' -Required
    $parts = $accessToken.Split('.')
    if ($parts.Count -ne 3) { throw 'The authentication token is not a supported JWT.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '='[0])
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $account = @(
        (Get-DemoField $claims 'preferred_username')
        (Get-DemoField $claims 'upn')
        (Get-DemoField $claims 'unique_name')
    ) | Where-Object { $_ } | Select-Object -First 1
    if ($account -ine $Config.account -or (Get-DemoField $claims 'tid' -Required) -ne $Config.tenantId) {
        throw "Unexpected authenticated account or tenant for $Resource."
    }
    if ((Get-DemoField $claims 'oid' -Required) -ne $Config.principalId) {
        throw 'The authenticated principal does not match the approved demo principal.'
    }
    return $accessToken
}

function Invoke-DemoHttp {
    param(
        [object]$Config,
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [string]$Resource = 'https://service.powerapps.com/',
        [AllowNull()][object]$Body,
        [switch]$ReadOnlyDiagnostic
    )
    $target = [Uri]$Uri
    $hostName = $target.DnsSafeHost.ToLowerInvariant()
    $trusted = $hostName -in @('graph.microsoft.com', 'api.bap.microsoft.com') -or
        $hostName.EndsWith('.bap.microsoft.com') -or
        $hostName.EndsWith('.environment.api.powerplatform.com')
    if ($target.Scheme -ne 'https' -or -not $trusted -or $target.UserInfo) {
        throw "Refusing to send credentials to an untrusted operation URL: $Uri"
    }
    if ($ReadOnlyDiagnostic -and ($Method -ne 'POST' -or
        $target.AbsolutePath -notin @('/plex/resolveDns', '/plex/testConnection', '/plex/testTLSConnection'))) {
        throw 'Diagnostic retries are allowed only for the documented read-only DNS, TCP, and TLS probes.'
    }
    $attempts = if ($ReadOnlyDiagnostic) { 8 } elseif ($Method -eq 'GET') { 3 } else { 1 }
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $parameters = @{
            Uri = $Uri
            Method = $Method
            Headers = @{ Authorization = "Bearer $(Get-DemoToken $Config $Resource)"; Accept = 'application/json' }
            ContentType = 'application/json'
            TimeoutSec = 90
            SkipHttpErrorCheck = $true
        }
        if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 30 -Compress }
        $response = Invoke-WebRequest @parameters
        $status = [int]$response.StatusCode
        if ($status -ge 200 -and $status -lt 300) {
            $content = [string]$response.Content
            $parsed = if ([string]::IsNullOrWhiteSpace($content)) { $null } else { $content | ConvertFrom-Json }
            return [pscustomobject]@{ StatusCode = $status; Headers = $response.Headers; Body = $parsed; Content = $content }
        }
        $pendingDiagnosticMapping = $ReadOnlyDiagnostic -and $status -eq 404 -and
            ([string]$response.Content).Contains('Subnet information not found')
        if (($Method -eq 'GET' -or $ReadOnlyDiagnostic) -and
            ($status -in @(429, 500, 502, 503, 504) -or $pendingDiagnosticMapping) -and $attempt -lt $attempts) {
            $delay = if ($ReadOnlyDiagnostic) { [Math]::Min(5 * $attempt, 20) } else { 2 * $attempt }
            Write-Warning "Transient HTTP $status from $hostName; retrying $Method ($attempt/$attempts) after $delay seconds. $($response.Content)"
            Start-Sleep -Seconds $delay
            continue
        }
        $failure = [InvalidOperationException]::new("HTTP $status from ${Uri}: $($response.Content)")
        $failure.Data['HttpStatus'] = $status
        $failure.Data['RequestUri'] = $Uri
        $failure.Data['ResponseBody'] = [string]$response.Content
        throw $failure
    }
    throw "Request retries exhausted for $Uri."
}

function Get-DemoEnvironment {
    param([object]$Config, [string]$EnvironmentId)
    $uri = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/${EnvironmentId}?api-version=2023-06-01"
    return (Invoke-DemoHttp $Config $uri).Body
}

function Get-DemoDefaultSnapshot {
    param([object]$Config)
    # An unprovisioned tenant can list a default placeholder while its single-resource GET returns 404.
    $response = Invoke-DemoHttp $Config 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2023-06-01'
    if (Get-DemoField $response.Body 'nextLink') { throw 'The default-environment snapshot requires a complete environment list.' }
    $defaults = @((Get-DemoField $response.Body 'value' -Required) | Where-Object {
        (Get-DemoField $_ 'name') -eq $Config.defaultEnvironmentId
    })
    if ($defaults.Count -ne 1) { throw 'The default environment was not uniquely identified in the management collection.' }
    $properties = Get-DemoField $defaults[0] 'properties' -Required
    return [pscustomobject]@{
        source = 'Power Platform management collection'
        environmentId = $Config.defaultEnvironmentId
        protectionLevel = Get-DemoField (Get-DemoField $properties 'governanceConfiguration') 'protectionLevel'
        vnetPolicy = Get-DemoField (Get-DemoField (Get-DemoField $properties 'enterprisePolicies') 'VNets') 'id'
    }
}

function Get-DemoEnvironmentApiHost {
    param([string]$EnvironmentId)
    $compact = $EnvironmentId.Replace('-', '').ToLowerInvariant()
    if ($compact.Length -lt 3) { throw 'Invalid environment ID for the diagnostic route.' }
    return '{0}.{1}.environment.api.powerplatform.com' -f $compact.Substring(0, $compact.Length - 2), $compact.Substring($compact.Length - 2)
}

function Get-DemoRegion {
    param([object]$Config, [string]$EnvironmentId)
    $route = Get-DemoEnvironmentApiHost $EnvironmentId
    $response = Invoke-DemoHttp $Config "https://$route/plex/environmentRegion?api-version=2026-02-01" -Resource 'https://api.powerplatform.com/'
    if ($response.Body -isnot [string] -or [string]::IsNullOrWhiteSpace($response.Body)) {
        throw 'The region diagnostic did not return an Azure region.'
    }
    return $response.Body
}

function Assert-DemoAdministrator {
    param([object]$Config)
    # Directory-role claims are optional; Graph membership and service authorization are authoritative.
    $response = Invoke-DemoHttp $Config 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName,roleTemplateId' -Resource 'https://graph.microsoft.com/'
    $roles = @(Get-DemoField $response.Body 'value' -Required)
    $allowed = @('62e90394-69f5-4237-9190-012177145e10', '11648597-926c-4cf3-9c36-bcebb0ba8dcc')
    if (-not @($roles | Where-Object { (Get-DemoField $_ 'roleTemplateId') -in $allowed }).Count) {
        throw 'Global Administrator or Power Platform Administrator must be active. No role assignment will be created by this script.'
    }
}

function Write-DemoJson {
    param([string]$Path, [object]$Value)
    $directory = Split-Path -Parent $Path
    $null = [IO.Directory]::CreateDirectory($directory)
    ConvertTo-Json -InputObject $Value -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-DemoCidr {
    param([string]$Cidr)
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { throw "Invalid IPv4 CIDR: $Cidr" }
    $ip = [Net.IPAddress]::Parse($parts[0])
    $prefix = [int]$parts[1]
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $prefix -lt 0 -or $prefix -gt 32) {
        throw "Invalid IPv4 CIDR: $Cidr"
    }
    $bytes = $ip.GetAddressBytes()
    [uint64]$start = [uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + $bytes[3]
    [uint64]$size = [math]::Pow(2, 32 - $prefix)
    if ($start % $size -ne 0) { throw "CIDR is not aligned to its network boundary: $Cidr" }
    return [pscustomobject]@{ Start = $start; End = $start + $size - 1; Prefix = $prefix; Size = $size }
}

function Wait-DemoPolicyOperation {
    param([object]$Config, [string]$OperationUri, [int]$TimeoutSeconds = 1800)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $response = Invoke-DemoHttp $Config $OperationUri
        $operationState = Get-DemoField (Get-DemoField $response.Body 'state' -Required) 'id' -Required
        if ($operationState -eq 'Succeeded') { return }
        if ($operationState -notin @('Running', 'NotStarted')) {
            throw "Policy operation ended with state ${operationState}: $($response.Content)"
        }
        Write-Host "Policy association: $operationState"
        Start-Sleep -Seconds 15
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Policy association exceeded $TimeoutSeconds seconds. The operation may still be running: $OperationUri"
}

function Wait-DemoEnvironmentCreation {
    param([object]$Config, [string]$OperationUri, [int]$TimeoutSeconds = 2700)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $response = Invoke-DemoHttp $Config $OperationUri
        $state = Get-DemoField (Get-DemoField $response.Body 'state') 'id'
        if ($state -and $state -notin @('Succeeded', 'Running', 'NotStarted')) {
            throw "Environment creation ended with state ${state}: $($response.Content)"
        }
        if ($state -eq 'Succeeded' -or (-not $state -and $response.StatusCode -eq 200)) {
            $links = Get-DemoField $response.Body 'links'
            $environmentPath = Get-DemoField (Get-DemoField $links 'environment') 'path'
            if ($environmentPath -and $environmentPath -match '/environments/([0-9a-fA-F-]{36})$') {
                return ([guid]$Matches[1]).ToString()
            }
            if ($OperationUri -match '/environments/([0-9a-fA-F-]{36})(?:/|\?)') {
                return ([guid]$Matches[1]).ToString()
            }
            throw 'Successful creation operation did not identify its environment.'
        }
        if (-not $state -and $response.StatusCode -ne 202) {
            throw "Unrecognized environment creation response: $($response.Content)"
        }
        Write-Host "Developer environment creation is still running: $OperationUri"
        Start-Sleep -Seconds 15
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Environment creation exceeded $TimeoutSeconds seconds. Resume the saved operation, not a new creation: $OperationUri"
}
