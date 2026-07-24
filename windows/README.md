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
- 接近上游的 74 列、47 行彩色六模块布局；独立窗口从 18 号 Consolas 向下自动选择能完整容纳报告的最大字号，并隐藏水平、垂直滚动条；窄终端自动退回纵向文本
- 12 家邮件服务的 SMTP 25 端口连通性
- 上游列表中的 439 个唯一 DNSBL
- 控制台、JSON、纯文本报告

## 环境要求

- Windows 10/11 或 Windows Server
- PowerShell 7.2 或更新版本
- Windows 自带的 `curl.exe`

默认按当前用户安装，不需要管理员权限。若机器尚未安装合格版本的
PowerShell 7，`Install.cmd` 会停止并显示 Microsoft 官方下载地址；标准
安装目录和用户 `PATH` 中的 PowerShell 7 都能自动识别。

检测普通网络和现成 HTTP/SOCKS 代理时，不会安装其他软件。

检测 `ss://` 节点时，首次运行会从 SagerNet 官方 GitHub Release 下载便携版 sing-box 1.13.14。下载包固定 SHA-256：

```text
f580782c6dd10f7691c66cea1d7c421813c5fbf7e305d1ee7ce0c3a40d196341
```

sing-box 放在 `windows/tools/`，已由 `.gitignore` 排除，不进入提交。

## 最简单的使用方法

在仓库根目录双击：

```text
Install.cmd
```

也可以在 PowerShell 中运行：

```powershell
.\Install.ps1
```

安装器会：

1. 优先复用既有安装，否则安装到当前用户的
   `%LOCALAPPDATA%\Programs\IPQuality`。
2. 创建 `ipq.cmd` 命令入口。
3. 幂等地加入用户 `PATH`，并通知 Windows 环境已经更新。
4. 保留既有的 `windows\reports`，因此重复安装就是安全升级。
5. 在安装目录放置独立的 `Uninstall.cmd`，源码 ZIP 删除后仍可卸载。

安装后新开一个 PowerShell、CMD 或“运行”窗口，输入：

```powershell
ipq
```

`ipq` 默认检测 IPv4，自动识别 v2rayN 当前节点常用的本地代理端口，
在独立 PowerShell 窗口中显示完整结果，并将 JSON 保存到安装目录的
`windows\reports`。不会在代理不可用时悄悄改测本机直连。

已经打开的终端不会自动获得新的用户 `PATH`；首次安装后关闭并重新打开
一次即可。资源管理器和随后启动的程序会收到安装器广播的环境更新。

升级只需再次运行 `Install.cmd`。卸载时双击：

```text
Uninstall.cmd
```

源码目录或安装目录里的 `Uninstall.cmd` 都可以使用。默认卸载会保留检测
报告，以及之后执行彻底清理所需的几个小卸载文件；不会笼统删除
`windows` 目录中的其他文件。若明确希望这些内容也一起删除：

```powershell
.\Uninstall.ps1 -PurgeReports
```

也可以在源码目录双击：

```text
Start-IPQuality.cmd
```

检测单条 Shadowsocks 节点时，双击：

```text
Start-NodeCheck.cmd
```

节点输入使用隐藏模式。临时配置只写入当前用户的随机临时目录，目录 ACL 仅允许当前用户访问；检测结束后会停止 sing-box 并删除配置。

## PowerShell 命令

直接调用底层脚本检测本机 IPv4：

```powershell
.\Start-IPQuality.ps1 -IPv4 -Direct
```

检测双栈并显示完整 IP：

```powershell
.\IPQuality.ps1 -FullIP
```

使用 SOCKS5H 代理：

```powershell
.\Start-IPQuality.ps1 -IPv4 -Proxy 'socks5h://127.0.0.1:1080'
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
| `-ConsoleFontSize` | 自动适配时允许使用的最大字号，默认 18 |

## 结果边界

- 多个数据库结论冲突时显示 `Mixed`，不会按多数票直接洗成低风险。
- `Score` 是各数据源自己的分数，定义并不统一，不应横向当作同一量表。
- SMTP 结果表示 TCP 25 端口能否建立连接，不代表允许发信、投递成功或不会进垃圾箱。
- DNSBL 查询使用 Windows 当前 DNS；失效或被停放的 DNSBL 可能返回普通公网地址，这类结果标为 `Marked`，不等同于确认拉黑。
- 流媒体页面和未公开 API 可能随时变化。连接失败标为 `Error`，HTTP 拒绝才标为 `Blocked`。
- 使用 `-Proxy` 时，HTTP 与流媒体请求走代理。DNSBL 是针对已发现出口 IP 的本地 DNS 查询。
- `ss://` 当前不支持 SIP003 `plugin=` 节点。
- 本实现不会上传报告。`ipq`/`Start-IPQuality.ps1` 默认只在本地保存 JSON；
  使用 `-NoSave` 可不落盘。直接调用底层 `IPQuality.ps1` 时仍只有明确指定
  `-Output` 才写文件。

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
