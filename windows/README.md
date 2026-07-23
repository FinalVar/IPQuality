# IPQuality for Windows

这是 `xykt/IPQuality` 的 Windows 原生 PowerShell 7 实现。它不依赖 Docker、WSL、Bash、`jq`、`dig` 或 `nc`。

## 功能

- IPv4/IPv6 出口发现与隐私掩码
- HTTP、HTTPS、SOCKS4、SOCKS5、SOCKS5H 代理
- 直接读取单条 `ss://` Shadowsocks 节点
- MaxMind 基础信息与 ASN、地区、注册地区
- IPinfo、Scamalytics、ipregistry、ipapi、AbuseIPDB、IP2Location、ipdata、IPQS、DB-IP
- 原生/广播 IP、家宽/机房、分库风险等级与风险因子
- TikTok、Disney+、Netflix、YouTube Premium、Amazon Prime Video、Reddit、ChatGPT
- 流媒体与 AI 的状态、地区及原生/DNS 解锁方式
- 接近上游的 72 列彩色六模块布局；窄终端自动退回纵向文本
- 12 家邮件服务的 SMTP 25 端口连通性
- 上游列表中的 439 个唯一 DNSBL
- 控制台、JSON、纯文本报告

## 环境要求

- Windows 10/11 或 Windows Server
- PowerShell 7.2 或更新版本
- Windows 自带的 `curl.exe`

检测普通网络和现成 HTTP/SOCKS 代理时，不会安装其他软件。

检测 `ss://` 节点时，首次运行会从 SagerNet 官方 GitHub Release 下载便携版 sing-box 1.13.14。下载包固定 SHA-256：

```text
f580782c6dd10f7691c66cea1d7c421813c5fbf7e305d1ee7ce0c3a40d196341
```

sing-box 放在 `windows/tools/`，已由 `.gitignore` 排除，不进入提交。

## 最简单的使用方法

双击：

```text
Start-IPQuality.cmd
```

检测单条 Shadowsocks 节点时，双击：

```text
Start-NodeCheck.cmd
```

节点输入使用隐藏模式。临时配置只写入当前用户的随机临时目录，目录 ACL 仅允许当前用户访问；检测结束后会停止 sing-box 并删除配置。

## PowerShell 命令

检测当前 IPv4：

```powershell
.\IPQuality.ps1 -IPv4
```

检测双栈并显示完整 IP：

```powershell
.\IPQuality.ps1 -FullIP
```

使用 SOCKS5H 代理：

```powershell
.\IPQuality.ps1 -IPv4 -Proxy 'socks5h://127.0.0.1:1080'
```

检测单条 `ss://` 节点：

```powershell
.\Test-Node.ps1 -Node 'ss://...'
```

如果 GitHub Release 暂时无法下载，也可以指定已有的 sing-box：

```powershell
.\Test-Node.ps1 -Node 'ss://...' -SingBoxPath 'D:\Tools\sing-box.exe'
```

保存 JSON：

```powershell
.\IPQuality.ps1 -IPv4 -Output .\reports\result.json
```

保存文本：

```powershell
.\IPQuality.ps1 -IPv4 -Output .\reports\result.txt
```

快速模式只查询 IPinfo 与 ipapi：

```powershell
.\IPQuality.ps1 -IPv4 -Lite
```

按需跳过较慢模块：

```powershell
.\IPQuality.ps1 -IPv4 -NoMedia -NoMail -NoDnsbl
```

## 参数摘要

| 参数 | 作用 |
|---|---|
| `-IPv4` / `-IPv6` | 只检测指定协议；都不写时检测双栈 |
| `-Proxy` | HTTP/HTTPS/SOCKS 代理地址 |
| `-Interface` | 交给 curl 的网卡名或源地址 |
| `-FullIP` | 报告中显示完整 IP；默认掩码 |
| `-Json` | 控制台输出 JSON |
| `-Output` | 保存 `.json` 或文本报告 |
| `-Force` | 允许覆盖既有报告 |
| `-Lite` | 只保留两个主要风险源 |
| `-NoRisk` | 跳过风险数据库 |
| `-NoMedia` | 跳过流媒体与 AI |
| `-NoMail` | 跳过 SMTP |
| `-NoDnsbl` | 跳过 DNSBL |

## 结果边界

- 多个数据库结论冲突时显示 `Mixed`，不会按多数票直接洗成低风险。
- `Score` 是各数据源自己的分数，定义并不统一，不应横向当作同一量表。
- SMTP 结果表示 TCP 25 端口能否建立连接，不代表允许发信、投递成功或不会进垃圾箱。
- DNSBL 查询使用 Windows 当前 DNS；失效或被停放的 DNSBL 可能返回普通公网地址，这类结果标为 `Marked`，不等同于确认拉黑。
- 流媒体页面和未公开 API 可能随时变化。连接失败标为 `Error`，HTTP 拒绝才标为 `Blocked`。
- 使用 `-Proxy` 时，HTTP 与流媒体请求走代理。DNSBL 是针对已发现出口 IP 的本地 DNS 查询。
- `ss://` 当前不支持 SIP003 `plugin=` 节点。
- 本实现不会自动上传报告。报告只在明确指定 `-Output` 时写入本地。

## 测试

离线语法和解析测试：

```powershell
.\tests\Smoke.Tests.ps1
```

附加真实网络与报告导出测试：

```powershell
.\tests\Smoke.Tests.ps1 -Online
```

## 许可证

本目录是 `xykt/IPQuality` 的衍生实现，继续使用仓库的 AGPL-3.0 许可证。
