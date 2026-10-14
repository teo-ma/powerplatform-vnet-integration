# Power Platform - actual private network path

> Evidence scope: actual DNS, TCP, and TLS diagnostic protocol traffic.
> This is not an application or connector payload read/write test, an East US
> failover test, or a Premium runtime license.

## Test result

| Field | Observed result |
| --- | --- |
| Overall status | __STATUS__ |
| Private network path proven | __PROVEN__ |
| Environment | __ENVIRONMENT__ |
| Environment ID | __ENVIRONMENT_ID__ |
| Region | __REGION__ |
| Evidence time (UTC) | __TIME__ |

__DETAILS__

## Private path evidence

| Check | Observed result |
| --- | --- |
| Power Platform delegated source subnet | __SUBNET__ |
| Actual probe source IPs | __SOURCE_IPS__ |
| Actual Private Endpoint NIC IP | __TARGET_IP__ |
| Normal Blob hostname | __HOSTNAME__ |
| Target public network access | __PUBLIC_NETWORK__ |
| Authenticated public-client negative control | __PUBLIC__ |
| Certificate revocation check | __CRL__ |

The source IPs must be inside the delegated subnet. The Power Platform DNS result
and direct TCP destination must match the actual Private Endpoint NIC IP.
The target must disable public network access, shared-key access, and firewall bypass.

The public-client control uses a verified identity with account-scoped Blob Data
Reader authorization. An authentication error or an arbitrary HTTP 403 is not
accepted as standalone network-path evidence. Raw DNS, TCP, TLS, certificate,
and public-response details are retained in the local
`.azure/private-path-verification.json` record.

## Reproducible protocol test

The command runs from the repository root:

```sh
pwsh -NoProfile -File scripts/Test-PrivateNetworkPath.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache \
  -OpenReport
```

Each run issues new requests, saves timestamped JSON, and regenerates this
Markdown report. Failed checks produce a failed report and a nonzero exit code.
`-OpenReport` uses the system's default application for Markdown files.

## Cost boundary

The minimal retained target uses one Private Endpoint (approximately US$0.01/hour)
and Private DNS (approximately US$0.50/month), plus variable processing and query
charges. Charges continue while those resources exist. No credentials are
included in this report.

[Test implementation](../scripts/Test-PrivateNetworkPath.ps1) ·
[Deployment and validation documentation](../README.md)
