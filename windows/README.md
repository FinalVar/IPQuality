# IPQuality for Windows

[![Windows native tests](https://github.com/FinalVar/IPQuality/actions/workflows/windows-native.yml/badge.svg?branch=windows-native)](https://github.com/FinalVar/IPQuality/actions/workflows/windows-native.yml)

这是 [FinalVar/IPQuality](https://github.com/FinalVar/IPQuality) 的 Windows
原生 PowerShell 7 版本，基于上游
[xykt/IPQuality](https://github.com/xykt/IPQuality) 的检测口径实现。它不依赖
Docker、WSL、Bash、`jq`、`dig` 或 `nc`。

日常用户先看本文；兼容性基线、窗口验收、上游同步和发布规则见
[维护与兼容性规范](MAINTENANCE.md)。

## 快速安装

环境要求：

- Windows 10/11 或 Windows Server；
- PowerShell 7.2 或更新版本；
- Windows 自带的 `curl.exe`。

下载并解压
[`windows-native` 分支 ZIP](https://github.com/FinalVar/IPQuality/archive/refs/heads/windows-native.zip)，
然后双击根目录的：

```text
Install.cmd
```

也可以在 PowerShell 中运行：

```powershell
.\Install.ps1
```

全新安装默认放在：

```text
%LOCALAPPDATA%\Programs\IPQuality
```

如果检测到早期版本位于
`%USERPROFILE%\Documents\Codex\Tools\IPQuality-Windows`，安装器会原地升级，
不会擅自迁移或删除历史报告。安装器按当前用户运行，不需要管理员权限。

安装完成后，在 PowerShell、CMD 或“运行”窗口输入：

```powershell
ipq
```

首次安装前已经打开的终端可能尚未获得新的用户 `PATH`，关闭后重新打开即可。

## 最常用的命令

`ipq` 默认检测 IPv4，并依次探测常见的本地 HTTP/SOCKS 入口。找到可用入口后，
检测流量会经过该代理；如果没有找到可用代理，它会报错，不会悄悄改测本机直连。

```powershell
# 当前代理节点的 IPv4
ipq

# 本机真实直连 IPv4
ipq -Direct

# 当前代理节点的 IPv6；节点没有 IPv6 出口时会明确失败
ipq -IPv6

# 显示完整 IP，分享截图或报告前请谨慎
ipq -FullIP

# 不保存本次 JSON 报告
ipq -NoSave

# 减少风险数据源；仍会运行媒体、邮件和 DNSBL
ipq -Lite

# 快速排障：跳过较慢模块
ipq -NoMedia -NoMail -NoDnsbl

# 查看启动器参数
ipq -?
```

IPv4 和 IPv6 应分别运行，以保证每个窗口都能完整显示一份报告。

## 路由语义

| 用法 | HTTP/媒体请求 | 出口发现 | SMTP | DNSBL |
|---|---|---|---|---|
| `ipq` | 自动识别到的本地代理 | 代理出口 | 代理模式不测 | 针对代理出口 IP，由本机 DNS 查询 |
| `ipq -Proxy URL` | 指定代理 | 代理出口 | 代理模式不测 | 针对代理出口 IP，由本机 DNS 查询 |
| `ipq -Direct` | 强制绕过环境代理 | 本机直连出口 | 本机/NAT 等价探测 | 针对直连出口 IP，由本机 DNS 查询 |

自动识别会优先尝试 `socks5h://127.0.0.1:7890`，随后尝试同端口的
SOCKS5、环境变量及其他常见本地端口。预检成功只说明该入口能够产生指定地址族的
公网出口；实际节点由 v2rayN 等本地客户端当时的活动配置决定。

## 检测单条 `ss://` 节点

推荐双击：

```text
windows\Start-NodeCheck.cmd
```

节点输入会隐藏，一键入口默认生成一份 IPv4 单屏报告。临时 sing-box 配置只写入
当前用户的随机临时目录，目录 ACL 仅允许当前用户访问；检测结束后会停止进程并删除
配置。

首次使用会从 SagerNet 官方 GitHub Release 下载已固定版本和 SHA-256 的便携版
sing-box。自动下载包目前是 Windows x64 版本；Windows ARM64 用户应使用自己验证过的
sing-box，并通过 `-SingBoxPath` 指定。

当前自动下载固定为 `sing-box 1.13.14` 的
`sing-box-1.13.14-windows-amd64.zip`，SHA-256：

```text
f580782c6dd10f7691c66cea1d7c421813c5fbf7e305d1ee7ce0c3a40d196341
```

如需 IPv6，可在仓库或安装目录根部运行：

```powershell
.\windows\Test-Node.ps1 -Node $node -IPv6
```

命令行参数和 PowerShell 历史可能保存节点凭据，因此人工使用时应优先选择上面的隐藏
输入窗口。当前不支持带 SIP003 `plugin=` 的 Shadowsocks 节点。

## 检测内容

- MaxMind 基础信息、ASN、地区、注册地区和原生/广播判断；
- 九个来源：IPinfo、Scamalytics、ipregistry、ipapi、AbuseIPDB、
  IP2Location、ipdata、IPQS、DB-IP；
- 使用类型、公司类型、家宽/机房综合判断、分库风险分数和风险因子；
- TikTok、Disney+、Netflix、YouTube Premium、Amazon Prime Video、
  Reddit、ChatGPT 的状态、地区和原生/DNS 解锁方式；
- 12 家邮件服务的 TCP 25 端口连通性；
- 上游列表中的 439 个唯一 DNSBL；
- 彩色控制台、JSON 和纯文本报告。

`-Lite` 当前保留 IPinfo、ipregistry、ipapi 和 DB-IP 四个风险来源，不等同于
跳过媒体、邮件或 DNSBL。

## 单屏窗口标准

日常 `ipq` 结果窗口遵守以下固定验收标准：

- 字体：Consolas，默认最大 18 号；
- 窗口：74 列 × 47 行；
- 缓冲区：与窗口同尺寸；
- 正文：完整 46 行，第 47 行同时显示 PowerShell 提示符；
- 不显示水平或垂直滚动条；
- 小屏幕从 18 号向下选择能容纳 74×47 的最大字号，默认不会超过 18 号。

重定向输出、非 ConsoleHost 或物理屏幕不足时会采用尽力而为的普通文本布局。单屏标准
针对一次一个地址族；高级双栈 JSON/文件输出不受单屏展示约束。

## 报告与隐私

`ipq` 默认把掩码后的 JSON 报告保存到安装目录的
`windows\reports`。文件名包含时间和地址族，不会覆盖旧报告。

```powershell
# 指定输出路径
ipq -Output .\result.json

# 从底层入口保存纯文本
.\windows\IPQuality.ps1 -IPv4 -Output .\result.txt

# 允许底层入口覆盖已有文件
.\windows\IPQuality.ps1 -IPv4 -Output .\result.json -Force
```

JSON 的 `Head` 明确区分：

- `Repository`：当前 Windows 实现 `FinalVar/IPQuality`；
- `Upstream`：兼容性来源 `xykt/IPQuality`；
- `CompatibilityBaseline`：本次随包携带的上游 `ip.sh` SHA-256；
- `CompatibilityReviewed`：代码、上游脚本和 DNSBL 列表是否匹配已审核清单。

默认报告不保存完整出口 IP、代理 URL、`ss://` 节点或密码。使用 `-FullIP` 会把完整
出口 IP 写入结果。工具不会上传组装后的完整报告，但检测必须向列出的地理、风险和
流媒体服务发送网络请求，因此这些服务能够看到被测出口 IP；DNSBL 查询还会把反向
查询名称交给本机配置的 DNS 解析器。

## 入口与参数边界

| 入口 | 用途 | 重要差异 |
|---|---|---|
| `ipq` / `Start-IPQuality.ps1` | 日常单窗口检测 | 默认 IPv4；自动代理；直连必须显式 `-Direct`；支持 `-NoSave` |
| `IPQuality.ps1` | 自动化、双栈、JSON/文件 | 不自动识别代理；支持 `-Interface`、`-Json`、`-Force` |
| `Test-Node.ps1` | 单条 `ss://` 节点 | 临时启动 sing-box；支持 `-IPv4` 或 `-IPv6` |
| `Compare-IPQuality.ps1` | 与原版 JSON 做归一化对比 | 区分核心字段、可用性、实时服务和解析器差异 |

底层入口示例：

```powershell
# 本机直连 IPv4；底层脚本默认绕过环境代理
.\windows\IPQuality.ps1 -IPv4

# 显式 SOCKS5H 代理
.\windows\IPQuality.ps1 -IPv4 -Proxy 'socks5h://127.0.0.1:1080'

# 双栈 JSON，适合重定向或文件处理
.\windows\IPQuality.ps1 -Json
```

## 升级与卸载

再次运行新版 `Install.cmd` 会原地升级，并保留 `windows\reports`。卸载时双击源码
包或安装目录中的：

```text
Uninstall.cmd
```

默认卸载会删除运行文件和 `ipq` 命令，但保留报告、安装清单和再次彻底清理所需的小
入口。明确需要删除整个安装目录及报告时：

```powershell
.\Uninstall.ps1 -PurgeReports
```

`-PurgeReports` 是不可恢复的彻底清理操作。

## 结果可信度与边界

- Windows 版追求与随包上游脚本相同的字段、阈值和判定语义，但不承诺两次联网检测
  逐字相同。API 可用性、页面内容、DNS 解析器、请求时刻和出口变化都会产生差异。
- 多个数据库结论冲突时显示 `Mixed`，不会用简单多数票洗成低风险。
- 各来源的 `Score` 定义不同，不能横向当成同一量表。
- “原生 IP”表示 MaxMind 使用地与注册地一致，不等于运营商、流媒体和所有风险库都
  认定它是住宅 IP。
- SMTP 只表示 TCP 25 端口能否建立连接，不代表允许发信、投递成功或不会进垃圾箱。
- DNSBL 中失效、停放或异常的区域可能返回普通公网地址；这类结果记为 `Marked`，
  只有上游定义的 `127.0.0.2` 记为 `Blacklisted`。查询错误在 JSON 中单独记录。
- 流媒体页面和未公开 API 会变化；网络错误、HTTP 拒绝和地区限制会分别保留，不把
  暂时失败伪装成“屏蔽”。

## 验证

从仓库根目录运行离线回归：

```powershell
.\windows\tests\Smoke.Tests.ps1
```

附加真实网络基础冒烟：

```powershell
.\windows\tests\Smoke.Tests.ps1 -Online
```

比较同一出口下的原版与 Windows JSON：

```powershell
.\windows\Compare-IPQuality.ps1 `
  -OriginalPath .\original.json `
  -WindowsPath .\windows.json `
  -Output .\comparison.json
```

维护者还必须完成真实 18 号、74×47、无滚动条窗口验收；CI 无法代替物理桌面检查。

## 许可证与归属

Windows 目录是 `xykt/IPQuality` 的衍生实现，继续使用仓库的 AGPL-3.0 许可证。
报告抬头显示当前实现仓库 `FinalVar/IPQuality`，上游来源和审核基线继续完整保留在
JSON 与维护文档中。
