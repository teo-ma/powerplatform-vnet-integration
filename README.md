# Power Platform VNet integration demo

This demo configures **outbound Power Platform VNet support**, not a VNet data
gateway or an inbound private endpoint.

## 公开仓库与本地配置

公开版本发布可复用脚本、Bicep、五页离线幻灯片、报告模板及
[脱敏证据示例](reports/sample-private-network-proof.html)。**不上传真实账号/租户/订阅、
认证缓存、云资源清单、运行状态或实时证据。** 原始环境信息与证据仅保存在本机
`demo.config.json`、`.azure/` 和生成报告中，这些路径均被 Git 忽略。

只查看客户材料：下载仓库后直接打开
[五页 HTML 幻灯片](reports/customer-demo-slides.html)，无需 Azure 登录、Node 安装或服务器。
公开证据示例是历史结果的脱敏结构，不是你的环境的现场实测。

在自己的环境复现：

1. 将 [demo.config.example.json](demo.config.example.json) 复制为本地 `demo.config.json`。
   填写真实 `subscriptionId`、`tenantId`、`account`、`principalId` 和全球唯一的
   `privatePathStorageName`，把 `defaultEnvironmentId` 改为 `Default-<tenantId>`。
   示例占位 GUID/账号/存储名会被拒绝，不要提交真实配置。
2. 在项目外的私有目录保存 Azure CLI 登录缓存，通过系统浏览器/设备码登录自己的租户。
   确认 Azure 权限、Power Platform 管理权限、许可和 IPAM；本复现脚本固定演示
   `westus/eastus` 及文中网段，不是任意拓扑的自动生成器。
3. 运行 `Prepare-LocalDemo.ps1` 做身份核验和只读资源盘点，生成本地草稿。
   它不会修改云资源，也不会覆盖已有 `.azure` 状态；所有部署/费用/刷新批准标志默认是 `false`。
4. 检查本地 `.azure/infrastructure-plan.json` 中的环境、范围、网络和风险。
   只有在明确批准后，才把 `meta.status` 设为 `approved`、
   `meta.userRiskAcknowledged` 设为 `true`，再运行基础部署。
5. 基础部署后，从 `.azure/deployment-state.json` 把真实环境 ID 填入
   `.azure/private-path-plan.json` 的 `inputs.environmentId`。先批准管理诊断并执行能力预检；
   再独立审核 Private Endpoint/DNS 的持续费用和账户范围 Blob Reader，批准后运行目标部署与实测。
   需要刷新策略时必须另行批准 `networkPolicyRefreshApproved`，不要为了演示默认给出批准。

```sh
cp demo.config.example.json demo.config.json
# 编辑本地配置、完成认证之后：
pwsh -NoProfile -File scripts/Prepare-LocalDemo.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache
```

本地客户会议使用
[本地模式幻灯片](reports/customer-demo-slides.html?localDemo=1)，其报告链接指向自己生成的
`reports/private-network-proof.html`。默认公开模式则指向脱敏示例，避免仓库中的死链接或误把示例当成实时证据。

## 客户会议演示步骤（建议 8–10 分钟）

### 演示材料

- [五页中文 HTML 幻灯片](reports/customer-demo-slides.html)：第 1 页封面，第 2 页架构和官方配置，第 3 页网段规划，第 4 页权限，第 5 页封底和问答。
- 现场实际报告：本地生成的 `reports/private-network-proof.html`；未上传到公开仓库。
- 原始验收 JSON：本地 `.azure/private-path-verification.json`，核对新时间戳、源/目标 IP、证书和错误码；未公开。
- [公开脱敏证据示例](reports/sample-private-network-proof.html)：只解释证据结构，不替代现场验收。
- [架构和组件关系图源](.github/modernize/assessment/engines/facts/architecture-diagram.md)：供技术复盘，不是新增云端部署。

幻灯片是自包含文件，无 CDN、无需服务器，可离线打开。使用左右方向键、
Page Up / Page Down、空格或页码按钮切页；`F` 切换全屏，`T` 切换明暗主题，
打印按钮可输出全部 **5 页**。文档链接需联网；幻灯片和已生成的报告本身不需要联网。

### 会前准备

1. 在系统浏览器完成认证并激活所需 PIM 角色。本项目诊断脚本要求活跃的
   Power Platform Administrator 或 Global Administrator；这不是给普通应用使用者的权限建议。
   再确认演示身份能读取网络/端点/存储配置，并在测试存储账户上具有 Blob Data Reader。
2. 在项目根目录预跑以下命令，预热 Power Platform 诊断容器，并检查本次报告为
   `Succeeded`。已观察到的热启动复跑为 **26.4 秒**，不保证每次相同；冷启动和权限过期可能导致等待或失败。
3. 打开幻灯片和报告两个窗口。建议共享报告窗口，不共享登录、MFA、令牌输出或认证缓存；
   不在会议中运行部署、策略刷新或带 `-Execute` 的清理命令。
4. 当前演示只验证 West US 的实际私网 DNS/TCP/TLS 协议路径。
   不把它描述成业务数据读写、全部流量均私网、East US 灾备切换或 Premium 许可验收。

```sh
pwsh -NoProfile -File scripts/Test-PrivateNetworkPath.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache \
  -OpenReport
```

### 现场流程与讲解词

| 时间 | 操作 | 建议讲解词与客户核对点 |
| --- | --- | --- |
| 0:00–1:30 | 第 1 页封面，然后第 2 页架构 | “Power Platform 在我们委派的子网中执行出站请求，经过 Private Endpoint 访问公网关闭的 Blob 服务。虚线是企业策略配置关系，不是业务数据路径。”美国 geography 要求 East US / West US 配对，Developer 环境也不能只配置一个 VNet。 |
| 1:30–2:30 | 展示第 3 页 | “委派子网与私有端点子网分离；两个区域的委派子网都是 `/24`，各有 251 个可用 IPv4。`/24` 是本 demo 的容量选择，不是所有客户的最低要求。”说明企业 IPAM、不重叠、扩容余量及变更窗口。 |
| 2:30–4:00 | 展示第 4 页 | “Azure 资源权限、Entra 管理权限、环境/Dataverse 权限、后端数据权限和产品许可是不同层次。Azure Owner 不是 Power Platform 管理员，网络连通也不自动授予读取数据的权限。”强调生产最小权限与 PIM。 |
| 4:00–4:45 | 打开已生成的私网报告 | 指出历史证据时间戳，并明确这是已完成的一次实测。来源 `172.20.0.4/.5` 在委派 `/24`，目标 `172.20.1.4` 是实际 Private Endpoint NIC；报告不是架构推断。 |
| 4:45–6:15 | 现场运行上面的命令 | “现在发起新测试，不重放成功截图。”等待新报告自动打开，核对时间戳已更新；源 IP 可能因诊断容器池变化，但必须仍在委派子网内。失败时如实展示失败状态，不沿用旧报告冒充实时成功。 |
| 6:15–7:15 | 展示证据链 | 顺序指出：正常服务域名在 Power Platform 内解析为 `172.20.1.4`；直接连接该私有 IP 的 TCP 443 成功；TLS 1.3、微软 Blob 证书和 CRL 检查通过。握手本身有真实网络数据包往返，但不是应用业务对象读写。 |
| 7:15–8:00 | 展示公网反向对照 | 存储 `publicNetworkAccess=Disabled`、共享密钥关闭、`bypass=None`。工作站使用已核验身份和账户范围 Blob Data Reader 请求相同服务域名，公网 DNS 返回地址后收到 `403 AuthorizationFailure`。不能用任意 403 或认证失败单独证明私网。 |
| 8:00–10:00 | 第 5 页封底、问答和成本说明 | “本次证明实际 West US 私网协议路径；业务读写和故障切换需要另做验收。”一个 Private Endpoint 约 US$0.01/小时，DNS 约 US$0.50/月，长期保留约 US$7.80/月起，另有微量请求/处理费用。会后仅清理新增测试目标，不删除原 VNet 集成。 |

### 权限与许可讲解要点

- **配置网络**：在目标范围授予 Network Contributor 或对应自定义权限。创建企业策略还需
  `Microsoft.PowerPlatform/enterprisePolicies/read`、`write` 等权限，例如目标资源组的
  Contributor 或精简自定义角色；不要认为 Network Contributor 自动包含所有 Power Platform 资源操作。
- **订阅准备**：注册资源提供程序、创建资源组涉及订阅级权限，可交给订阅管理员预先完成，
  避免为了演示给所有参与者订阅 Owner。
- **配置 Power Platform**：按官方前提使用 Power Platform Administrator；
  本次用 PIM 临时激活 Global Administrator 完成演示，不建议永久给普通用户该角色。
  关联策略的人必须能够读取该 Enterprise Policy；如果与创建者不同，可补该策略范围的 Azure Reader。
- **分配 Azure 数据角色**：需要目标范围的 `Microsoft.Authorization/roleAssignments/write`，
  例如适用范围的 Owner、User Access Administrator 或 Role Based Access Control Administrator。
  Contributor 本身不授予角色分配能力。
- **后续使用**：普通使用者需要应用/流程共享权限、相应环境和 Dataverse 数据安全角色；
  创建者可需要 Environment Maker，Dataverse 管理者才按需使用 System Administrator。
  不给所有使用者管理员角色，也不把 Environment Maker 当成数据访问授权。
- **后端身份**：连接所使用的用户、服务主体或受支持托管身份仍需后端数据权限；
  Blob 只读可用 Storage Blob Data Reader，读写按需用 Data Contributor，并缩小到账户/容器范围。
  Azure Reader、Contributor、Owner 的管理面权限不等于通过 Entra ID 获得 Blob 数据面权限。
- **产品许可**：托管环境中的应用、云流或代理运行需符合对应的 Premium、Dynamics 365 权益
  或适用计费配置。免费 Developer Plan 不替代托管环境中的资产运行许可；本 demo 只运行官方管理诊断探针。

### 现场异常与收尾

- 权限/MFA/PIM 过期：切回系统浏览器处理，不在客户共享窗口展示密码或令牌。
- 诊断冷启动或传播延迟：允许脚本有界重试；需要时查看
  本地 `reports/private-path-capability.html`。`CapabilityReady` 只是能力预检，不是私有目标验收。
- 实测失败：保留失败 JSON 和时间戳，明确失败在哪一阶段，不把配置 `Succeeded` 当成数据面成功。
- 演示结束：资源保留期间继续计费；先运行
  `pwsh -NoProfile -File scripts/Remove-PrivatePathTarget.ps1` 查看精确清理范围。
  真正删除另行确认。详见后文 “Cost and separate follow-up cleanup”。

## Scope

- Account / tenant / subscription: use your ignored local `demo.config.json`; none are published.
- New Developer environment: `PP VNet Demo`, United States, preferably West US
- New resource group: choose an isolated name in the private configuration.
- Paired VNets in `westus` and `eastus`, each with a dedicated `/24`
- Delegation: `Microsoft.PowerPlatform/enterprisePolicies`
- Enterprise policy: `ep-pp-vnet-demo`, kind `NetworkInjection`

## Verified deployment

The configuration demo is deployed and the policy association returned
`Succeeded`. The dedicated managed Developer environment is:

- Environment ID: generated locally in `.azure/deployment-state.json`.
- Actual Azure region: `westus`
- Protection level: `Standard`
- Dataverse URL and Azure resource IDs: generated locally; intentionally not published.
- [Power Platform admin center](https://admin.powerplatform.microsoft.com/)
- [Azure portal](https://portal.azure.com/)

| VNet | Region | Address space | Delegated subnet |
| --- | --- | --- | --- |
| `vnet-pp-demo-westus` | West US | `172.20.0.0/16` | `172.20.0.0/24` |
| `vnet-pp-demo-eastus` | East US | `172.21.0.0/16` | `172.21.0.0/24` |

Local verification evidence, deployment state, and reviewed plan are recorded
under the ignored `.azure/` directory. Successful ARM operations and their
approved target scope are recorded in `.azure/deployment-evidence.json`. The real service-side
association status, exact policy and network IDs, managed protection, subnet
delegations, NSGs, disabled default outbound access, and unchanged default
environment are checked by the verification script. The pre-deployment Azure
inventory is also checked for retained resource IDs and types; this is not a
property-by-property audit of every existing resource.

Local PowerShell/Bicep checks passed. Checkov was unavailable; no automated
security scan is claimed. The user accepted the documented manual security
review. Business-payload read/write has **not** been tested. The separately
approved private-target DNS/TCP/TLS protocol test passed; see the customer
walkthrough and the actual private-path proof section below.

The United States geography requires **two VNets even for a Developer
environment**. Each subnet has 251 usable IPv4 addresses.

The scripts do not modify the default environment or existing Azure resources.
The initial configuration stage creates no app, flow, paid license, trial,
paid billing plan, public IP, NAT gateway, firewall, or private backend. A
separately approved private-only Storage/Private Endpoint target was added for
the subsequent protocol test. The administrative configuration demo does not
license or test business-workload execution. Running assets in a managed
environment requires appropriate premium licensing or eligible billing.

Azure can automatically add a regional Network Watcher in `NetworkWatcherRG`
when the first VNet is created in East US or West US. This platform side effect
was disclosed and approved. The demo does not enable flow logs or other paid
diagnostic features and does not modify existing Network Watchers.

Developer environments include Dataverse. The script stops if environment
creation is rejected due to licensing, capacity, permissions, or geography; it
does not fall back to a Trial environment or enable billing.

The initially unlicensed tenant returned `CRMLicenseRequired`. The user then
separately approved and completed the official free Power Apps Developer Plan
registration. `POWERAPPS_DEV` and `DYN365_CDS_DEV_VIRAL` were verified as active.
This is not a paid plan or a 30-day Trial and does not license running assets in
a managed environment. The scripts do not enroll users or assign licenses.

## Prerequisites

Use PowerShell 7, Azure CLI, and Bicep. Activate Global Administrator or Power
Platform Administrator in the target tenant, and use the approved Azure Owner
or equivalent resource permissions.

Directory-role token claims are optional. The scripts verify the account,
tenant, and principal, check actual Microsoft Graph directory-role membership,
and require successful service responses.

Authenticate in the **system browser**, not the VS Code embedded browser:

```sh
az login --tenant YOUR_TENANT_ID \
  --use-device-code --scope https://service.powerapps.com//.default
```

For isolation, set `AZURE_CONFIG_DIR` to a private directory **outside this
project** before login, and pass the same directory to the scripts. Never add
authentication caches, tokens, passwords, or client secrets to this project.
All CLI operations explicitly select the approved subscription.

## Validate

```sh
pwsh -NoProfile -File scripts/Test-Demo.ps1
```

If using an isolated login cache:

```sh
pwsh -NoProfile -File scripts/Test-Demo.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache
```

If Checkov is installed, also run `checkov -d infra/`. If it is unavailable,
report that limitation rather than claiming an automated security scan passed.

Validation writes the freshly compiled ARM template and parameter document to
`.azure/compiled/`. What-if and deployment use those exact validated artifacts,
so Azure CLI's Bicep-installation status messages cannot contaminate the JSON
what-if result.

## Deploy and verify

Review the private local `.azure/infrastructure-plan.json`, including its risks and
licensing boundaries. Cloud changes require explicit approval recorded in that
plan. The following creates only the approved demo resources:

```sh
pwsh -NoProfile -File scripts/Invoke-Demo.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache \
  -Deploy
```

Without `-Deploy`, this command performs authentication and local validation
only. Deployment:

1. Snapshots the default environment's protection level and VNet policy.
2. Creates the isolated Developer environment and Dataverse test database.
3. Verifies the actual Azure region before any network deployment.
4. Enables managed-environment configuration on the new environment only.
5. Checks IPv4 overlap and registers `Microsoft.PowerPlatform` if required.
6. Saves an ARM what-if and rejects modifications, deletions, or out-of-scope
   creations.
7. Deploys the paired networks, delegated subnets, NSGs, and enterprise policy.
8. Associates the policy and waits for the actual asynchronous `Succeeded`
   result.
9. Verifies the exact association, regions, addresses, subnet capacities, NSGs,
   delegation, disabled default outbound access, unchanged default environment,
   and retained baseline Azure resource IDs and types.

The PowerShell orchestration uses the same Microsoft management API operations
as the official administration and EnterprisePolicies modules, with the
already authenticated Azure CLI session. This avoids additional module-specific
interactive logins. It never logs or persists bearer tokens in the project.

Environment provisioning discovers the tenant's `tenantProvisioningMode` using
the current locations API. Macro-region tenants use `macroRegion` instead of
the mutually exclusive legacy `location` field. The North America macro region
is validated against tenant metadata, West US remains the requested Azure
region, and the actual geography/region is verified before network deployment.
This handles `MacroRegionRequired`, which the legacy administration module
cannot satisfy. Default-environment protection is snapshotted from the management
collection because a new tenant can list a default placeholder whose individual
resource is not yet provisioned.

Initialization can take about 30 minutes. Deployment state is saved after each
phase in `.azure/deployment-state.json`; rerunning resumes the same environment
instead of creating another. Errors remain failures and include the failing
phase. Do not manually change a failed deployment to completed.

Both legacy creation-operation URLs and the newer `lifecycleOperations` response
are supported. The operation URL is saved immediately after the accepted
request, and the environment ID is taken from the successful lifecycle
operation's environment link. An interrupted creation is resumed rather than
reissued.

Verify an existing completed deployment:

```sh
pwsh -NoProfile -File scripts/Verify-Demo.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache
```

Successful verification is recorded in `.azure/verification.json`. This proves
the configuration and association, **not a business call to a private backend**.
No general-purpose NAT gateway or firewall egress design is provisioned.
Production internet-bound dependencies need a separately reviewed egress
design; a configuration check alone does not prove how every workload is routed.

## Cleanup

Cleanup is destructive and is **not performed automatically**.

1. Reactivate the necessary administrator role.
2. Use the official `Disable-SubnetInjection -EnvironmentId <demo-environment-id>`
   command and wait for successful disassociation.
3. Delete only the demo environment recorded in `.azure/deployment-state.json`.
4. Confirm the resource group's `deploymentId` tag matches
   the private configuration's `deploymentId`, then delete only that isolated demo group.
5. Do not delete the default environment, other resource groups, or shared
   provider registrations.

## Actual private-path proof and meeting demo

**The separately approved minimum-cost private-path test has passed.** This is
actual diagnostic protocol traffic from Power Platform, not the original
configuration check and not a simulated screenshot.

| Evidence | Actual observed result |
| --- | --- |
| Power Platform probe sources | `172.20.0.4` and `172.20.0.5`, both inside the delegated `/24` |
| Normal target hostname | The private configuration's Storage name plus `.blob.core.windows.net` (service name redacted) |
| DNS resolved inside Power Platform | `172.20.1.4`, exactly the Private Endpoint NIC IP |
| TCP | Direct connection to `172.20.1.4:443` succeeded |
| TLS | TLS 1.3, `TLS_AES_256_GCM_SHA384`; Microsoft Blob certificate and CRL checks passed |
| Target public network access | `Disabled`; shared-key access disabled; firewall bypass `None` |
| Authenticated public-client control | Public DNS resolved `20.60.80.196`; HTTP `403 AuthorizationFailure` |

The Storage account uses `Standard_LRS`. Its Private Endpoint is in the new
nondelegated subnet `172.20.1.0/27`, protected by an NSG allowing only TCP 443
from the Power Platform subnet. Private DNS is linked to the existing West US
VNet. The original delegated subnet, East US VNet, and default environment are
retained. The demo principal received **Blob Data Reader only on this new
account**, for the authenticated public-client negative control.

The original raw JSON, target state and approved follow-up plan remain private
under `.azure/`. Each live run creates the local customer report
`reports/private-network-proof.html`. The repository includes only
[a clearly labelled redacted example](reports/sample-private-network-proof.html),
not the private runtime evidence or a fabricated current result.

### Three-minute meeting walkthrough

1. Activate the required PIM role and authenticate before the meeting. Run the
   test once to warm the diagnostic containers.
2. Share the local HTML report. Point to the actual Power Platform source
   IPs, private destination IP, TLS/certificate result, and public-client
   rejection.
3. Run the command below live. It issues fresh probes and an authenticated
   public request, saves new timestamped JSON, and opens the regenerated report.
   It does not create resources, execute an app/flow, or replay cached success.

The verified warm replay took **26.4 seconds**. This is an observed run, not a
latency guarantee; cold allocation, policy propagation, or a PIM/session issue
can take longer or cause an explicitly failed report.

```sh
pwsh -NoProfile -File scripts/Test-PrivateNetworkPath.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache \
  -OpenReport
```

This proves **the actual West US DNS/TCP/TLS private protocol path**. It does
not prove application/connector business-payload read/write, East US failover,
or Premium runtime entitlement. An arbitrary 403 or a local TLS handshake is
not accepted as proof: the script checks actual Power Platform source IPs,
the exact endpoint NIC, private DNS, direct private-IP TCP, certificate checks,
public-access settings, the public identity, and its account-scoped role.

### Cost and separate follow-up cleanup

Retail estimates before tax/discounts: approximately **US$0.01 per endpoint
hour** (US$0.24/day), **US$0.50 per Private DNS zone month**, and negligible
protocol/query volume. Leaving one endpoint for 730 hours is approximately
**US$7.80/month plus variable charges**. No VM, NAT gateway, paid log workspace,
Premium purchase, or business data was added. Charges continue while the
endpoint and DNS zone exist.

Preview removal of **only the added test target**:

```sh
pwsh -NoProfile -File scripts/Remove-PrivatePathTarget.ps1
```

When the meeting is over, deleting it requires a separate destructive
confirmation. `-Execute` prompts for confirmation and removes only the owned
test endpoint, DNS zone, Storage account and its data/reader role, NSG, and
nondelegated target subnet. **Do not delete the resource group or original
VNet integration resources merely to stop the follow-up test charges.**

The added template uses published, schema-backed Network `2024-07-01` and
Storage `2025-01-01` APIs. The installed Bicep `0.48.1` lacks type definitions
for the provider's newer 2026 APIs; pinning these compatible versions allows
full property type checking. Compilation and the add-only ARM what-if passed.
Checkov remained unavailable and the user accepted the manual security review.

### Runtime warm-up and troubleshooting

Initially, official diagnostics returned `Subnet information not found` after
container allocation. Both regions, API versions, and the original module
client reproduced it. The user approved refreshing only this demo's original
policy. The relink and bounded, explicit diagnostic retries eventually restored
real probes; the precise cause of the original error is not confirmed.

`Repair-DemoNetwork.ps1` resumes a saved accepted operation without repeatedly
unlinking the environment. Metadata propagation and diagnostic cold starts
are handled with bounded retries, not success-shaped fallbacks.

If capability fails in a future session:

```sh
pwsh -NoProfile -File scripts/Test-PrivatePathCapability.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache \
  -OpenReport
```

Immediately after an approved policy refresh, optionally use
`-WaitForPropagationMinutes 30`. A failed check exits nonzero and produces an
explicitly failed/blocked report. `CapabilityReady` alone is **not private-target
proof**; only a successful `Test-PrivateNetworkPath.ps1` result is.

## References

- [Official VNet setup](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure?pivots=powershell)
- [Supported regions and subnet sizing](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview)
- [Environment creation](https://learn.microsoft.com/en-us/power-platform/admin/create-environment)
- [Managed-environment licensing](https://learn.microsoft.com/en-us/power-platform/admin/managed-environment-licensing)
- [Official EnterprisePolicies module](https://github.com/microsoft/PowerPlatform-EnterprisePolicies)
- [Role scopes and Dataverse data security](https://learn.microsoft.com/en-us/power-platform/admin/database-security)
- [Azure networking roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/networking#network-contributor)
- [Assign Blob data roles](https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access)
