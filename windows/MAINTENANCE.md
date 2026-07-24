# Windows 原生版维护与兼容性规范

本文是 `windows-native` 分支的规范性维护文档。用户操作见
[README](README.md)。本文中的“必须”“不得”“应”是发布验收要求，不是建议。

## 仓库与分支职责

| 对象 | 职责 |
|---|---|
| `FinalVar/IPQuality` | Windows 原生实现的当前仓库和报告归属 |
| `xykt/IPQuality` | Bash 原版、数据字段与兼容性语义的上游来源 |
| `main` | 尽量保持为上游镜像，便于观察和同步原版 |
| `windows-native` | Windows 产品分支，包含 PowerShell、安装器、文档和测试 |

公开仓库的默认分支应是 `windows-native`，否则访问仓库主页或普通 `git clone` 的
用户会落到不含 Windows 安装器的上游镜像。

报告可见抬头必须显示 `https://github.com/FinalVar/IPQuality`。JSON `Head` 必须同时
保存 `Repository=FinalVar/IPQuality` 与 `Upstream=xykt/IPQuality`，不得把二者混成
同一个字段。上游归属不能删除，日常报告也不得把上游地址冒充为当前仓库地址。

## 目录边界

- 根目录的 `Install.*` 和 `Uninstall.*` 是 Windows PowerShell 5.1 到 PowerShell 7
  的引导入口。
- `windows/Start-IPQuality.ps1` 是 `ipq` 的日常启动器，只负责单窗口路由选择、
  默认保存和参数收敛。
- `windows/IPQuality.ps1` 是自动化入口，负责地址族、控制台布局、JSON/文本输出。
- `windows/IPQuality.psm1` 保存检测、解析、判定和渲染逻辑。
- `windows/Test-Node.ps1` 与 `Prompt-Node.ps1` 负责临时 `ss://` 隧道。
- `windows/Compare-IPQuality.ps1` 只做原版/Windows JSON 的归一化比较。
- `windows/compatibility-baseline.json` 是已经人工审核的上游快照清单。
- `ref/` 与 `ip.sh` 继续由上游提供；Windows 代码不得另藏一份不可追踪的副本。

## 单屏显示合同

日常单地址族报告的硬性标准是：

| 项目 | 标准 |
|---|---|
| 字体 | Consolas，默认上限 18 |
| 窗口 | 74 列 × 47 行 |
| 缓冲区 | 74 列 × 47 行，与窗口完全相同 |
| 内容 | 46 行完整报告正文 + 第 47 行 PowerShell 提示符 |
| 滚动条 | 水平、垂直均不得出现 |
| 小屏幕 | 从 18 向下选择可容纳标准窗口的最大字号，最低 8 |

默认字号不得自动超过 18。不得通过增加缓冲区高度、隐藏报告行或缩小默认字号来掩盖
布局回归。新增可见报告行时，必须同时重新设计其它行并完成真实桌面验收。

IPv4 与 IPv6 在可见窗口中必须分别运行。双栈只用于 JSON、文件或重定向自动化，
不能声称两份 46 行报告能同时满足单屏合同。

## 路由合同

1. `ipq` 默认 IPv4，并优先探测 `socks5h://127.0.0.1:7890`。
2. 自动代理不可用时必须失败，绝不能静默降级为本机直连。
3. 本机直连必须由用户显式选择 `-Direct`，底层请求必须用 `--noproxy "*"` 绕过
   `ALL_PROXY`、`HTTPS_PROXY` 和 `HTTP_PROXY`。
4. `-Direct` 与 `-Proxy`、`-IPv4` 与 `-IPv6`、`-NoSave` 与 `-Output` 必须互斥。
5. 代理预检必须使用地址族专用端点；IPv6 不可用时不得拿 IPv4 结果冒充。
6. HTTP、风险库和媒体请求跟随显式代理；DNSBL 使用本机 DNS 对已发现出口 IP 查询。
7. 上游不把 SMTP 25 探测送进 HTTP/SOCKS 代理，Windows 版也必须明确显示“代理不测”。

## 数据与判定合同

- Windows 版的目标是字段、阈值、状态和错误语义兼容，不是承诺两次联网结果逐字相同。
- 所有外部数据源必须保留独立的 `Available`、原始分数、归一化风险等级、风险因子和
  错误；不得用空值伪造成低风险。
- 多源布尔结论冲突必须是 `Mixed`。只有所有有效来源一致时才可输出单一肯定/否定。
- 家宽/机房结论必须可追溯到各来源的使用类型和公司类型。
- “原生/广播”只比较 MaxMind 使用地与注册地，文档和 UI 不得扩张成“真实住宅”证明。
- 流媒体状态、地区与 DNS/原生方式是三组独立字段；网络错误不得直接等同于地区屏蔽。
- DNSBL 必须保留上游唯一列表数量及 `Clean`、`Marked`、`Blacklisted`、`Errors`
  四种统计。为保持上游语义，只有唯一答案 `127.0.0.2` 计为 `Blacklisted`。
- 报告时间必须转换为上游使用的 `Asia/Shanghai`，再标记 `CST`；不得把任意本地时间
  直接拼上 `CST`。

## 已审核上游基线

`compatibility-baseline.json` 锁定以下内容：

- 上游仓库、分支；
- `ip.sh` 的脚本版本和 SHA-256；
- 完成审核时的 Windows 版本；
- 唯一 DNSBL 数量；
- 审核日期。

模块启动时会比较实际文件与该清单，并在 JSON 写入
`Head.CompatibilityReviewed`。任一字段不匹配都必须变为 `false`，同时在报告警告中
保留“尚未审核”提示。

同步新的上游 `ip.sh` 或 `ref/dnsbl.list` 后，维护者必须先检查字段、端点、解析器、
阈值和布局，再更新清单。仅更新 SHA-256 让测试变绿不算完成兼容性审核。

## 隐私与凭据

- 默认报告必须掩码 IP，不得保存代理 URL、代理凭据、`ss://` URI 或节点密码。
- `-FullIP` 是明确的隐私降级选项，文档必须提示分享风险。
- 人工输入节点应使用 `Read-Host -AsSecureString`；README 不应鼓励把真实节点直接
  写进命令行历史。
- 临时 sing-box 配置目录必须随机生成、限制为当前用户 ACL，并在成功、失败和中断的
  `finally` 路径中删除。
- curl 参数必须通过 `ProcessStartInfo.ArgumentList` 传递，不得拼成可注入的 shell
  字符串。
- 完整组装报告不上传，但外部检测必然向服务方披露出口 IP；文档必须准确说明这个
  边界，不能简写成“完全不上传任何数据”。

自动节点依赖当前固定为 SagerNet `sing-box 1.13.14` 的
`sing-box-1.13.14-windows-amd64.zip`，SHA-256 为
`f580782c6dd10f7691c66cea1d7c421813c5fbf7e305d1ee7ce0c3a40d196341`。
升级时必须先从官方 Release 重新核对资产、哈希、配置语法和 Windows x64 启动测试，
不得只改版本字符串。

## 安装与卸载合同

- 全新安装默认使用 `%LOCALAPPDATA%\Programs\IPQuality`，已有受支持的旧安装原地升级。
- 默认按用户安装，不要求管理员权限。
- 根 `Install.ps1` 与 `Uninstall.ps1` 由 Windows PowerShell 5.1 首先解析，必须保存为
  UTF-8 BOM；其余 PowerShell 7 文件可使用仓库标准编码。CI 必须检查 BOM 和真实 5.1
  引导，不能仅用 PowerShell 7 语法解析代替。
- 用户 `PATH` 修改必须幂等；安装器只移除自己曾管理的路径。
- 升级必须保留 `windows/reports`，不得覆盖非 IPQuality 的非空目录。
- 安装清单必须记录目标、命令入口、受管文件，以及安装输入文件的确定性 SHA-256
  指纹。从 Git checkout 安装时还必须记录源提交；GitHub ZIP 没有 `.git`，允许
  `SourceCommit` 为空，但不得缺少 `SourceFingerprint`。
- 默认卸载只删除清单列出的运行文件，并保留报告和用户自建文件。
- 只有显式 `-PurgeReports` 才能递归删除安装根目录；删除前必须拒绝磁盘根、用户目录、
  Documents、Desktop、Windows、Program Files 等宽目标。

## 测试矩阵

每次发布必须完成以下层级：

1. `windows/tests/Smoke.Tests.ps1`
   - 所有 PowerShell 文件语法；
   - 风险、类型、媒体、DNS 和节点解析器夹具；
   - JSON/文本导出与原版比较器；
   - 安装、升级、默认卸载、彻底卸载和异常清单安全边界；
   - Windows PowerShell 5.1 引导到 PowerShell 7；
   - 仓库/上游身份和兼容性基线。
2. GitHub Actions `windows-native.yml`
   - 在干净的 `windows-latest` 上运行离线测试；
   - 不把实时第三方 API 当作稳定 CI 依赖。
3. `Smoke.Tests.ps1 -Online`
   - 至少验证一个真实 IPv4 出口、隐私掩码和基础信息错误保留。
4. 原版对比
   - 同一时间窗口、同一代理出口、同一地址族分别生成 JSON；
   - 用 `Compare-IPQuality.ps1` 区分核心差异、数据源不可用、实时服务变化和解析器差异；
   - “核心一致”不能替代对所有不可用字段的审查。
5. 真实桌面窗口
   - Consolas 18、74×47、缓冲区同尺寸；
   - 两个滚动条均为 false；
   - `FinalVar/IPQuality` 抬头可见，无孤立 `ipq` 行；
   - 46 行正文和第 47 行提示符同时可见。
6. 发布包
   - 从公开 `windows-native` ZIP 安装到干净临时目录；
   - 安装清单提交号、命令入口、升级保留和卸载行为一致。

## 上游同步与 README 冲突策略

Windows 专有说明只放在 `windows/`，它们在上游不存在，正常同步不会冲突。根
`README.md` 和 `README_EN.md` 只允许在
`<!-- windows-native:start -->` 与 `<!-- windows-native:end -->` 之间维护一段短入口，
其余内容尽量保持上游原样。

同步建议：

```powershell
git fetch upstream main
git switch main
git merge --ff-only upstream/main
git push origin main
git switch windows-native
git merge main
```

发生 README 冲突时，先采用新的上游正文，再把完整 Windows 标记块放回标题下方。
不得为了减少冲突删除上游作者、赞助商、许可证、截图或历史。

## 版本与发布检查单

Windows 版本采用 `0.x.y`：

- 行为、JSON 结构或用户入口变化：至少增加次版本；
- 解析器、布局、安装器或文档修复：增加补丁版本；
- 每次版本变化都要更新 `compatibility-baseline.json` 的 `WindowsVersion` 并重新测试。

推送前逐项确认：

- 工作树只包含本次范围内的文件；
- 离线测试、语法解析和补丁格式全部通过；
- 在线错误保留而非被吞掉；
- Windows README、维护规范和参数行为一致；
- Git checkout 安装副本的 `SourceCommit` 指向最终提交，所有安装来源都有
  `SourceFingerprint`；
- 远端 `windows-native` 与本地提交相同；
- 公开 ZIP 包含安装器、基线文件和最新版 Windows 模块；
- 默认分支仍为 `windows-native`。

## 已知限制

- 外部网页和未公开 API 随时可能变化，CI 无法证明实时服务长期可用。
- DNSBL 上游列表含有失效、停放或特殊格式条目，错误和 `Marked` 必须结合明细解释。
- 自动下载的 sing-box 目前仅固定 Windows x64 包；SIP003 插件节点尚不支持。
- PowerShell 7 和 `curl.exe` 仍是运行依赖。
- 分支 ZIP 是可变安装源，没有代码签名或不可变发行资产；正式大范围分发前应增加带
  校验值的 GitHub Release。
- 真实窗口尺寸和字体需要交互式桌面，GitHub 托管 CI 只能覆盖静态合同和逻辑测试。
