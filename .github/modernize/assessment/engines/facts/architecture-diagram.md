# Architecture Diagram

This reference implementation combines an HTML slide deck and Markdown reports with
PowerShell/Bicep orchestration. The diagrams separate
configuration relationships from the actual West US private diagnostic path.

## Application Architecture

<!-- mermaid-checked: no \n, no em-dash/en-dash, no {} in labels, subgraphs are id["label"], arrows are -->|"label"|, all subgraphs closed by end, ids unique -->
```mermaid
flowchart TD
    subgraph PresentationA1["Local Presentation"]
        SlidesA1["Five-page HTML technical slides"]
        ReportA1["Timestamped Markdown proof report"]
        OperatorA1["PowerShell 7 and Azure CLI operator"]
    end
    subgraph PlatformA1["Microsoft Power Platform"]
        EnvironmentA1["Managed Developer environment"]
        PolicyA1["NetworkInjection enterprise policy"]
    end
    subgraph WestA1["Customer Azure VNet - West US"]
        SourceA1["Delegated subnet 172.20.0.0/24"]
        TargetA1["Private endpoint subnet 172.20.1.0/27"]
        EndpointA1["Blob Private Endpoint 172.20.1.4"]
        DnsA1["Linked Azure Private DNS zone"]
    end
    subgraph EastA1["Required Paired VNet - East US"]
        StandbyA1["Delegated subnet 172.21.0.0/24"]
    end
    subgraph BackendA1["Azure PaaS Backend"]
        BlobA1[("Standard LRS Blob - public disabled")]
    end
    PublicA1["Authenticated public-client control"]
    OperatorA1 -.->|"management diagnostic API"| EnvironmentA1
    OperatorA1 -->|"fresh evidence"| ReportA1
    SlidesA1 -.->|"links to evidence"| ReportA1
    PolicyA1 -.->|"association"| EnvironmentA1
    PolicyA1 -.->|"paired subnet configuration"| SourceA1
    PolicyA1 -.->|"paired subnet configuration"| StandbyA1
    EnvironmentA1 -->|"runtime diagnostic container"| SourceA1
    DnsA1 -.->|"normal Blob FQDN to private IP"| SourceA1
    SourceA1 -->|"TCP 443 and TLS 1.3"| EndpointA1
    EndpointA1 -.->|"located in"| TargetA1
    EndpointA1 -->|"Private Link"| BlobA1
    PublicA1 -.->|"HTTP 403 network denial"| BlobA1
```

### Technology Stack Summary

| Layer | Technology | Version | Purpose |
| --- | --- | --- | --- |
| Presentation | Self-contained HTML, CSS and JavaScript | Browser standards | Five-page technical slides with navigation and printing |
| Documentation and reports | Markdown and Mermaid | GitHub-compatible | Timestamped protocol evidence and architecture diagrams |
| Orchestration | PowerShell | 7 | Actual probes, strict assertions, JSON/Markdown evidence |
| Authentication | Azure CLI and Microsoft Entra OAuth | Installed CLI | Explicit tenant/account/subscription; no project credentials |
| Infrastructure | Bicep | Validated with 0.48.1 | Incremental, approved Azure deployments |
| Runtime | Power Platform managed diagnostics | Managed service | Probes originate in delegated subnet |
| Network/backend | Azure VNet, Private Link, Private DNS, StorageV2 | Managed service | Private target with public access disabled |

### Data Storage & External Services

The empty Standard_LRS Blob account is the protocol-test target, not a store
of business payloads. Microsoft management APIs provide role/configuration
checks and official Power Platform DNS/TCP/TLS diagnostics. Raw evidence is
stored locally as JSON; the generated Markdown report exposes no access tokens.

### Key Architectural Decisions

- Solid private-path edges represent observed protocol communication; dotted
  edges are control-plane, DNS, placement, or denied-public relationships.
- West US and East US satisfy the United States region-pair requirement; only
  the West US target path was tested. East US failover is not claimed.
- Delegated and Private Endpoint subnets are separate. Network access does
  not replace backend data authorization or managed-environment licensing.

## Component Relationships

<!-- mermaid-checked: no \n, no em-dash/en-dash, no {} in labels, subgraphs are id["label"], arrows are -->|"label"|, all subgraphs closed by end, ids unique -->
```mermaid
flowchart LR
    subgraph PresentationC2["Presentation"]
        DeckC2["HTML technical slide deck"]
        EvidencePageC2["Private network proof Markdown"]
    end
    subgraph OrchestrationC2["PowerShell Orchestration"]
        ConfigTestC2["Verify-Demo script"]
        CapabilityC2["Private-path capability test"]
        PrivateTestC2["Private network path test"]
        TargetDeployC2["Approved private-target deployment"]
        CleanupC2["Confirmed target-only cleanup"]
    end
    subgraph InfrastructureC2["Shared Infrastructure Components"]
        CommonC2["OAuth and trusted HTTP helpers"]
        BicepC2["Typed Bicep target template"]
        EvidenceC2["Local JSON evidence writer"]
    end
    DeckC2 -.->|"opens report"| EvidencePageC2
    CapabilityC2 -->|"fresh capability gate"| TargetDeployC2
    TargetDeployC2 -->|"target IDs and private IP"| PrivateTestC2
    TargetDeployC2 -->|"compile and preview"| BicepC2
    ConfigTestC2 -->|"identity and configuration reads"| CommonC2
    CapabilityC2 -->|"real diagnostic calls"| CommonC2
    PrivateTestC2 -->|"DNS TCP TLS and public control"| CommonC2
    CleanupC2 -->|"ownership guards and explicit confirmation"| CommonC2
    PrivateTestC2 -->|"strict results"| EvidenceC2
    EvidenceC2 -->|"timestamped rendering"| EvidencePageC2
```

### Component Inventory

| Component | Layer | Type | Responsibility |
| --- | --- | --- | --- |
| `customer-demo-slides.html` | Presentation | HTML/JavaScript | Five-page technical slides with navigation and printing |
| `private-network-proof.md` | Reports | Generated Markdown | Actual protocol evidence and limits |
| `Demo.Reports.ps1` | Infrastructure | Shared report renderer | Escaped Markdown templates with explicit status and missing-value errors |
| `Verify-Demo.ps1` | Orchestration | PowerShell script | Verify configuration, association and baseline preservation |
| `Test-PrivatePathCapability.ps1` | Orchestration | PowerShell script | Warm diagnostic containers and verify actual source subnet |
| `Test-PrivateNetworkPath.ps1` | Orchestration | PowerShell script | Assert exact private target, source IPs, TLS and public rejection |
| `Deploy-PrivatePathTarget.ps1` | Orchestration | PowerShell script | Risk-approved, add-only deployment with capability gate |
| `Remove-PrivatePathTarget.ps1` | Orchestration | PowerShell script | Preview or explicitly confirm target-only deletion |
| `Demo.Common.ps1` | Infrastructure | Shared helpers | Verified OAuth identity, trusted URLs, explicit bounded retries |
| `private-path.bicep` | Infrastructure | IaC | Reference existing VNet; add private-only test target |

The facts are sourced from `demo.config.json`, deployment state and
`private-path-verification.json`. No business application, payload read/write,
packet capture, or East US disaster-recovery test is inferred.
