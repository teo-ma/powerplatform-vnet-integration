# Power Platform private-path diagnostic capability

## Capability result

| Field | Observed result |
| --- | --- |
| Capability status | __STATUS__ |
| Environment | __ENVIRONMENT__ |
| Environment ID | __ENVIRONMENT_ID__ |
| Diagnostic region | __REGION__ |
| Policy configuration | __ASSOCIATION__ |
| Expected delegated source subnet | __SUBNET__ |
| Observed container IP | __SOURCE_IP__ |
| Evidence time (UTC) | __TIME__ |
| Private target path proof | Not tested by this capability check |

## Observed diagnostic outcome

__ERROR__

**This report does not prove a private-target network path.** A linked enterprise
policy and runtime subnet mapping do not prove packet delivery to a private
target. This check covers diagnostic capability only; it does not perform the
private-target TCP/TLS test or application data read/write and does not create
a chargeable backend.

`CapabilityReady` means the actual DNS diagnostic source is inside the delegated
subnet and matches the runtime network mapping. `Blocked` is a failed precheck,
not a successful transfer result. Raw results remain in the local
`.azure/private-path-capability.json` record.

## Private-target acceptance criteria

1. The actual Power Platform source IP is inside the delegated subnet.
2. The normal service FQDN resolves to the exact Private Endpoint NIC IP.
3. Direct private-IP TCP and hostname-based TLS probes succeed.
4. The target has public network access disabled.
5. An authenticated public-client control is rejected by network policy.

These criteria concern protocol traffic, not a business payload read/write test.

## Reproducible capability test

An active administrator session is required. The command runs from the
repository root:

```sh
pwsh -NoProfile -File scripts/Test-PrivatePathCapability.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache \
  -OpenReport
```

Each run issues new diagnostic requests, records raw JSON, and regenerates
this timestamped Markdown report. `-OpenReport` uses the system's default
application for Markdown files.

This diagnostic does not create infrastructure, modify licensing, or replace
private-target acceptance tests.

[Capability implementation](../scripts/Test-PrivatePathCapability.ps1) ·
[Deployment and validation documentation](../README.md)
