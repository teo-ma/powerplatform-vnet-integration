# Power Platform VNet 集成与私网路径验证

基于 Azure VNet、子网委派和 NetworkInjection 企业策略的参考实现，包含基础设施代码、
PowerShell 部署与验证脚本、五页 HTML 技术幻灯片和 Markdown 报告。

本项目验证的是 **Power Platform 到私有后端的出站协议路径**，不是 VNet Data Gateway，
也不是通过入站 Private Endpoint 将整个 Power Platform 或 Dataverse 放入 VNet。

## 项目资料

| 资料 | 内容 |
| --- | --- |
| [五页技术幻灯片（HTML）](reports/customer-demo-slides.html) | 封面、架构与官方配置、IP 规划、权限分层、技术总结；离线导航与打印 |
| [公开脱敏证据示例（Markdown）](reports/sample-private-network-proof.md) | 参考部署的源 IP、目标 IP、协议检查和公网反向对照结构 |
| [私网协议报告模板](reports/private-network-proof.template.md) | 实际协议测试的 Markdown 输出结构 |
| [诊断能力报告模板](reports/private-path-report.template.md) | 能力预检的 Markdown 输出结构，明确区别于私有目标验收 |
| [架构与组件关系图](.github/modernize/assessment/engines/facts/architecture-diagram.md) | 数据路径、配置关系和脚本组件职责 |
| [配置示例](demo.config.example.json) | 不含真实租户、订阅或账号的本地配置模板 |
| [基础配置模板](infra/main.bicep) | 独立资源组、配对 VNet、专用委派子网、NSG 和企业策略 |
| [私有验证目标模板](infra/private-path.bicep) | 公网关闭的 Storage、Private Endpoint、Private DNS 和独立端点子网 |

技术幻灯片恢复为自包含 HTML，支持方向键、Page Up / Page Down、空格和页码导航，
`F` 全屏、`T` 明暗主题以及五页打印布局，无 CDN 或外部运行依赖。
三个报告资料均为 Markdown，可在 GitHub 或 Markdown 预览器中阅读。

幻灯片默认链接指向公开脱敏 Markdown 示例。
[本地报告模式](reports/customer-demo-slides.html?localDemo=1) 指向本机生成的
`reports/private-network-proof.md`，该文件不上传到仓库。示例和本地历史报告都不代表当前环境状态，
实际验收以新测试的时间戳及原始证据为准。

## 架构与验证范围

参考路径：

```text
Power Platform 托管环境
  → 委派子网中的运行容器 NIC
  → 独立子网内的 Blob Private Endpoint
  → Azure Private Link
  → 禁止公网访问的 Storage Blob 服务
```

PowerShell 通过官方管理诊断 API 发起测试；实际 DNS、TCP 和 TLS 探针运行在
Power Platform 的委派子网中，而非本地工作站。Private Endpoint 与 Storage 服务本体
不是同一概念：端点 NIC 位于 VNet，Storage 仍是 Azure 托管服务。

| 配置 | 参考部署 |
| --- | --- |
| Power Platform 环境 | 独立 Developer 环境，Managed Environments，`protectionLevel=Standard` |
| 企业策略 | `NetworkInjection`，geography 为 `unitedstates` |
| 实际环境区域 | `westus` |
| West US VNet / 委派子网 | `172.20.0.0/16` / `172.20.0.0/24` |
| East US VNet / 委派子网 | `172.21.0.0/16` / `172.21.0.0/24` |
| West US 独立端点子网 | 非委派 `172.20.1.0/27` |
| 私有目标 | StorageV2 `Standard_LRS`，单个 Blob Private Endpoint |

美国 geography 的配对网络要求同时适用于生产和非生产环境。当前代码固定为
`westus/eastus` 和上述 CIDR，不是面向任意 geography 的自动拓扑生成器。
其他区域应重新核对官方支持表、实际环境区域、地址规划和相关验证逻辑。

### 已完成的参考验收

| 验收层次 | 参考部署结果 | 结论边界 |
| --- | --- | --- |
| 配置关联 | 环境绑定预期策略，实际异步操作 `Succeeded` | 不单独证明协议流量可达 |
| 私有 DNS | 正常 Blob FQDN 在 Power Platform 内解析为 `172.20.1.4` | 必须匹配实际 PE NIC 地址 |
| 源地址 | `172.20.0.4` / `172.20.0.5` | 均在委派 `/24` 内；并非固定保留给某个用户 |
| TCP | 直接连接 `172.20.1.4:443` 成功 | 实际私网 IP 连接，不是本机连通性检查 |
| TLS | TLS 1.3、微软 Blob 证书与 CRL 检查通过 | 协议通信，不是业务对象读写 |
| 公网反向对照 | 有效身份、账户范围 Blob Reader，公网请求返回 `403 AuthorizationFailure` | 结合公网关闭和后端设置判断；任意 403 不足以证明路径 |
| 保留检查 | 默认环境不变，原有资源 ID 和类型均存在 | 不是所有既有资源的逐属性审计 |

**未覆盖：**连接器或插件的业务数据读写、所有工作负载流量、East US 后端可达性、
灾备切换、生产吞吐或运行许可验收。双区域配置不等于双区域业务可用性已经通过测试。

参考测试没有创建 VM、NAT Gateway、付费日志工作区，也没有购买 Premium 或运行应用/流程资产。
配置和诊断成功不替代产品许可或后端数据授权。

## IP 用途与网段容量规划

### 三类地址分别规划

| 地址类型 | 分配对象与用途 | 容量依据 |
| --- | --- | --- |
| VNet 地址空间 | 子网划分和后续扩展的地址池，不是已运行实例数量 | 企业 IPAM、子网总需求、未来扩展及与本地/VPN/对等网络的不重叠约束 |
| Power Platform 委派子网 | 执行插件、受支持连接器等请求的运行容器 NIC；每容器使用一个 IP，可处理多个并发请求 | 同一策略承载的环境数、环境类型、各环境峰值容器需求和余量 |
| Private Endpoint 子网 | 服务私网接入 NIC 的目标地址；本参考 Blob PE 使用一个私有 IP | 各端点实际 IP 配置数量、5 个 Azure 保留地址和未来端点需求 |

委派 IP 不与用户、流程、单次请求或 Dataverse 数据记录一一对应。平台随负载伸缩，
不能将请求数量直接换算为 IP 数。

### 容量估算步骤

1. 统计同一企业策略及子网关联的所有环境。官方经验值可作为起点：
   生产每环境 **25–30 IP**，非生产每环境 **6–10 IP**。
   这些是规划参考，不是硬上限或容量保证。
2. 根据插件和受支持连接器的高峰并发、请求持续时间、压测结果和
   `Get-EnvironmentUsage` 等实际使用数据修正峰值需求，加入伸缩和环境增长余量。
3. 每个子网单独计入 Azure 保留的 **5 个地址**，选取满足条件的 CIDR：

   ```text
   2^(32 − 前缀长度) − 5 ≥ 各环境峰值 IP 预算之和 + 余量
   ```

4. 配对委派子网应有相同可用 IP 数，并各自满足预算，不能将需求对半分摊到两个区域。
5. Private Endpoint 子网按目标端点的实际 IP 配置单独估算，不套用 Power Platform
   每环境的容器预算，也不复用 Power Platform 专用委派子网。

例如：4 个生产环境 × 30 IP，加上示例余量 30 IP，需要 **150 个可用 IP**。
`/25` 只有 `128−5=123` 个可用 IP，容量不足；`/24` 有 `256−5=251` 个，可满足需求。
30 IP 余量是示例假设，不是官方固定比例。

参考部署中的 `/16`、委派 `/24` 和端点 `/27` 均为包含余量的设计选择，
**不是所有场景的最低网段要求**。`/27` 有 `32−5=27` 个可用 IP。

委派子网不能用于其他用途，也不能同时用于多个企业策略。同一策略可关联多个环境，
但需要合并计算容量。启用后修改 CIDR 或 VNet DNS 应遵循官方停用、支持及重新启用流程，
评估连接初始化和约 30 分钟影响窗口，不应直接在线调整。

官方依据：[容量估算](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview#estimating-subnet-size-for-power-platform-environments)、
[容器如何使用委派子网](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview#how-does-power-platform-use-azure-subnet-delegation)、
[容器内并发请求](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview#can-multiple-plugins-run-within-the-same-container)。

## 权限与许可

Azure 管理权限、Entra 管理角色、环境/Dataverse 权限、后端数据权限和产品许可分别生效。
**Azure Owner 不等于 Power Platform 管理员；路径可达不等于数据可读。**

| 阶段 / 任务 | 授权要求与范围 |
| --- | --- |
| 创建 VNet、子网、NSG、PE 和 DNS | 目标资源范围的 Network Contributor 或等价自定义权限 |
| 创建 Storage 与企业策略 | 对应资源写入权限；目标 RG Contributor 或精简自定义角色可覆盖。Network Contributor 不自动包含 `Microsoft.PowerPlatform/enterprisePolicies/write` |
| 注册资源提供程序 / 创建资源组 | 对应订阅级权限，可由订阅管理员预先完成 |
| 分配 Azure 数据角色 | 目标范围的 `Microsoft.Authorization/roleAssignments/write`，例如适用范围的 Owner、User Access Administrator 或 Role Based Access Control Administrator |
| 配置托管环境、关联策略 | 官方前提为 Power Platform Administrator；关联者还需能读取 Enterprise Policy，不同关联人可补策略范围的 Azure Reader |
| 执行本项目管理诊断脚本 | 活跃的 Power Platform Administrator 或 Global Administrator，以及脚本所读取资源的 Azure 权限 |
| 公网负面对照 | 已核验身份在新增测试 Storage 上的 Blob Data Reader，仅用于带身份的公网请求 |
| 制作或使用应用 / 流程 | 对应共享权限和环境角色；Environment Maker 不是数据访问授权 |
| Dataverse 数据 | 按应用、表和行授予安全角色；System Administrator 限于确需环境数据管理的身份 |
| 后端数据 | 连接实际使用的用户、服务主体或受支持托管身份需要独立的数据面授权；Blob 只读可用 Storage Blob Data Reader |
| 托管环境运行资产 | 符合对应应用、云流、代理的 Premium、Dynamics 365 权益或适用计费配置 |

生产部署应采用最小权限和 PIM。参考部署曾使用临时 Global Administrator 完成配置，
不表示普通使用者需要该角色。Entra 管理权限不自动授予 Dataverse 或 Blob 数据访问权，
Azure 管理角色也不等于通过 Entra ID 获得 Blob 数据面权限。

免费 Power Apps Developer Plan 可提供开发环境/Dataverse 权益，
但**不替代 Managed Environment 中资产运行许可**。脚本不会自动购买许可、启用试用或配置付费计费。
服务拒绝许可、容量或权限时，部署保持失败状态，不通过切换 Trial 环境绕过。

## 本地配置与公开边界

公开仓库包含源码、模板和脱敏示例。以下内容仅保存在运行主机，并被 Git 忽略：

- `demo.config.json`：真实账号、租户、订阅、主体和目标名称。
- `.azure/`：批准计划、资源盘点、部署状态、请求与验收证据。
- `reports/private-network-proof.md`、`reports/private-path-capability.md`：本地生成报告。
- 旧版生成 HTML 仍被 Git 忽略，以免历史私有运行记录被意外发布。

认证缓存必须位于项目之外。访问令牌、密码、私钥和连接密钥不属于项目配置或证据。
公开示例不请求服务，不重放运行结果，也不替代部署环境内的新测试。

## 环境准备与复现

### 1. 配置与认证

依赖 PowerShell 7、Azure CLI 和 Bicep。HTML 资料本身不需要这些依赖。

```sh
cp demo.config.example.json demo.config.json
```

本地配置需填写 `subscriptionId`、`tenantId`、`account`、`principalId` 和全球唯一的
`privatePathStorageName`；`defaultEnvironmentId` 为 `Default-<tenantId>`。
示例空 GUID、示例账号和存储名会被准备脚本拒绝。

认证使用系统浏览器或设备码，登录缓存目录位于项目外：

```sh
export AZURE_CONFIG_DIR=/absolute/path/to/private/azure-cli-cache
az login --tenant YOUR_TENANT_ID \
  --use-device-code --scope https://service.powerapps.com//.default
```

所有云操作显式指定订阅，并校验账号、租户和主体。脚本通过 Microsoft Graph 活跃角色
及实际服务响应校验权限，不依赖可选的目录角色令牌声明。

### 2. 生成本地草稿

```sh
pwsh -NoProfile -File scripts/Prepare-LocalDemo.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache
```

该步骤仅做身份核验和只读资源盘点，生成本地计划，不创建云资源，也不覆盖已有状态。
所有部署、费用和策略刷新批准标志初始为 `false`。

### 3. 校验与基础部署

```sh
pwsh -NoProfile -File scripts/Test-Demo.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache
```

校验覆盖 PowerShell 语法、网络配对、IP 范围与容量、Bicep 编译和参数一致性。
编译产物保存在 `.azure/compiled/`，ARM what-if 与部署使用同一组产物。

基础部署前需审核 `.azure/infrastructure-plan.json` 中的 IPAM、资源范围、角色、许可、
成本和变更风险，批准后设置 `meta.status=approved` 和 `meta.userRiskAcknowledged=true`。
批准标志属于运行审批记录，不是绕过组织变更流程的手段。

```sh
pwsh -NoProfile -File scripts/Invoke-Demo.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache \
  -Deploy
```

基础部署顺序：

1. 记录默认环境的保护级别和 VNet 策略基线。
2. 创建独立 Developer 环境和 Dataverse 测试库，核验实际 Azure 区域。
3. 仅在该环境启用 Managed Environments。
4. 检查地址冲突，并按需注册 `Microsoft.PowerPlatform`。
5. 校验 add-only ARM what-if，部署配对 VNet、委派子网、NSG 和 NetworkInjection 策略。
6. 关联策略，等待实际异步操作 `Succeeded`，核验配置和原有资源保留情况。

不带 `-Deploy` 时仅进行认证和本地校验。部署状态在每阶段保存，
中断后恢复同一环境而非重复创建；失败结果保留阶段和错误，不会自动转换为成功。

仅复核配置：

```sh
pwsh -NoProfile -File scripts/Verify-Demo.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache
```

`.azure/verification.json` 证明配置与关联，不单独证明私有目标的协议路径。

### 4. 私网诊断能力预检

基础部署后，将 `.azure/deployment-state.json` 中的真实环境 ID 填入
`.azure/private-path-plan.json` 的 `inputs.environmentId`，
审核并批准 `diagnosticOnlyScopeApproved` 后运行：

```sh
pwsh -NoProfile -File scripts/Test-PrivatePathCapability.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache \
  -OpenReport
```

`CapabilityReady` 表示实际 DNS 诊断来源位于委派子网，**不是私有目标验收通过**。
`Blocked` 返回非零退出码和明确的阻塞报告。收费测试目标部署前要求 30 分钟内有效的成功预检。

### 5. 部署私有验证目标

独立审核 Private Endpoint/DNS 持续费用、目标资源和账户范围 Blob Reader。
批准后在 `.azure/private-path-plan.json` 中设置：

- `meta.status=approved`
- `meta.backendDeploymentApproved=true`
- 按审批结果记录费用、角色和相关风险确认字段。

```sh
pwsh -NoProfile -File scripts/Deploy-PrivatePathTarget.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache
```

该步骤引用已建 West US VNet，增加独立非委派端点子网、目标 NSG、私有 Storage、
单个 Blob PE 和 Private DNS，不替换原委派子网。目标仅允许委派子网的 HTTPS 入站；
Storage 禁止公网、共享密钥和防火墙旁路。Blob Data Reader 仅分配在新账户范围。

### 6. 实际协议路径验收

```sh
pwsh -NoProfile -File scripts/Test-PrivateNetworkPath.ps1 \
  -AzureConfigDirectory /absolute/path/to/private/azure-cli-cache \
  -OpenReport
```

验收检查：

1. 环境、策略、Storage、PE 和 NIC 均匹配批准的目标与资源范围。
2. 目标 `publicNetworkAccess=Disabled`、共享密钥关闭、`bypass=None`。
3. 正常 Blob 域名在 Power Platform 内仅解析为 PE 的实际私有 IP。
4. DNS/TCP/TLS 探针的实际来源均位于委派子网。
5. 直接私有 IP 的 TCP 443 成功，正常域名的 TLS 握手和证书检查通过。
6. 带有效身份和账户范围数据角色的公网请求被拒绝；认证失败不被当作网络路径证明。

结果写入 `.azure/private-path-verification.json` 和本地 Markdown。
每次运行都会发起新请求并记录时间戳；失败会返回非零退出码，不沿用旧成功结果。
`-OpenReport` 使用系统默认的 Markdown 文件应用；格式化预览由 Markdown 阅读器提供。
CRL 状态单独记录，失败时明确显示限制。参考部署曾通过 CRL 检查，
一次热启动复测为 26.4 秒；这不是延迟保证或性能 SLA。

## 验证证据与限制

| 本地记录 | 含义 |
| --- | --- |
| `.azure/deployment-state.json` | 环境、策略和实际异步操作状态 |
| `.azure/deployment-evidence.json` | 成功 ARM 操作及限定的目标范围 |
| `.azure/insights.json` | 配置事实和部署前资源 ID/类型基线 |
| `.azure/private-path-capability.json` | 实际诊断来源和运行时子网映射 |
| `.azure/private-path-target.json` | 目标资源 ID、端点 NIC IP 和子网 |
| `.azure/private-path-verification.json` | 新运行的 DNS/TCP/TLS 和公网对照结果 |

源 IP、端点 NIC、私有 DNS、TLS 证书、后端网络设置和公网请求应联合判断。
本机 `curl` 成功、策略显示 Linked、任意 403 或仅有使用量映射，都不能单独证明私网路径。

公开仓库只保留脱敏结构，不发布原始租户信息或私有运行清单。实际业务读写、连接执行身份、
数据授权及双区域故障切换需要额外验收。

## 成本与清理

参考零售价约为：单个 Private Endpoint **US$0.01/小时**（US$0.24/天），
Private DNS zone **US$0.50/月**，另有少量数据处理、DNS 和 Storage 请求费用。
按 730 小时持续保留，约 **US$7.80/月起**，未计税费、折扣及变量费用；
实际账单以区域、合同和当前价格为准。

### 仅删除新增验证目标

```sh
pwsh -NoProfile -File scripts/Remove-PrivatePathTarget.ps1
```

默认仅预览。`-Execute` 需要单独的破坏性操作确认，按所有权标签和目标 ID 检查后，
仅删除测试 PE、DNS zone、Storage 及数据/Reader 角色、目标 NSG 和非委派子网。
原 VNet、委派子网、策略、Power Platform 环境和资源组保留。

### 删除完整参考部署

完整清理是独立操作，不自动执行：

1. 使用所需管理权限，通过官方 `Disable-SubnetInjection` 解除记录的环境关联，等待成功。
2. 仅删除本地状态记录的专用环境。
3. 核对隔离资源组的 `deploymentId` 所有权标签后，删除该专用资源组。
4. 保留默认环境、其他工作负载和共享资源提供程序注册。

首次在区域创建 VNet 时，Azure 可能自动在 `NetworkWatcherRG` 添加 Network Watcher。
本项目不启用流量日志或付费诊断功能，也不把共享 Network Watcher 纳入目标清理。

## 故障诊断与实现说明

- **`MacroRegionRequired`：** 根据 locations API 返回的 `tenantProvisioningMode`，
  使用 `macroRegion` 或与其互斥的 `location`；实际部署区域仍需核验。
- **`CRMLicenseRequired`：** Dataverse 创建受许可、容量和服务条件约束；管理员角色不是许可证。
- **冷启动和传播延迟：** 官方诊断可能先返回容器分配信息，配置元数据也可能延迟传播。
  参考部署曾出现 `Subnet information not found`，经独立批准的原策略刷新和有界等待后恢复；
  精确根因未确认，不保证刷新策略适用于所有同类错误。
- **策略刷新：** `Repair-DemoNetwork.ps1` 需要单独批准 `networkPolicyRefreshApproved`，
  并恢复已接受的操作，避免重复解绑。刷新可能引起连接中断，不能作为普通测试的默认步骤。
- **PIM 或认证失败：** 使用系统浏览器刷新会话。凭据和 MFA 不写入配置、证据或公开日志。
- **版本与扫描：** 私有目标模板采用 schema-backed Network `2024-07-01` 和
  Storage `2025-01-01` API。参考验证使用 Bicep 0.48.1；未安装 Checkov，因此没有自动安全扫描结论。
  生产部署应独立完成安全审查和适用扫描。

诊断容器传播窗口可通过能力预检的 `-WaitForPropagationMinutes` 参数显式限定，
不是无限重试。运行失败时保留原始错误；配置成功不会被用作协议测试的成功替代。

报告格式的离线回归检查：

```sh
pwsh -NoProfile -File scripts/Test-MarkdownReports.ps1
```

该检查使用独立临时夹具，覆盖成功、失败、未完成、CRL 状态和 Markdown 特殊字符，
不会调用 Azure 或覆盖本地真实验收证据。

## 官方文档

- [VNet 配置流程](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure?pivots=powershell)
- [支持区域、IP 规划与限制](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview)
- [官方网络诊断](https://learn.microsoft.com/en-us/troubleshoot/power-platform/administration/virtual-network)
- [环境创建](https://learn.microsoft.com/en-us/power-platform/admin/create-environment)
- [托管环境许可](https://learn.microsoft.com/en-us/power-platform/admin/managed-environment-licensing)
- [环境与 Dataverse 安全角色](https://learn.microsoft.com/en-us/power-platform/admin/database-security)
- [Azure 网络角色](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/networking#network-contributor)
- [Blob 数据面授权](https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access)
- [Storage 私有端点](https://learn.microsoft.com/en-us/azure/storage/common/storage-private-endpoints)
- [EnterprisePolicies 模块](https://github.com/microsoft/PowerPlatform-EnterprisePolicies)
