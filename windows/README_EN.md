# IPQuality for Windows

[![Windows native tests](https://github.com/FinalVar/IPQuality/actions/workflows/windows-native.yml/badge.svg?branch=windows-native)](https://github.com/FinalVar/IPQuality/actions/workflows/windows-native.yml)

This is the native PowerShell 7 edition in
[FinalVar/IPQuality](https://github.com/FinalVar/IPQuality). It implements the
field and verdict semantics of the upstream
[xykt/IPQuality](https://github.com/xykt/IPQuality) script without requiring
Docker, WSL, Bash, `jq`, `dig`, or `nc`.

This document is the user guide. The normative console, compatibility,
upstream-sync, privacy, and release rules are in
[Windows maintenance](MAINTENANCE.md) (Chinese).

## Quick installation

Requirements:

- Windows 10/11 or Windows Server;
- PowerShell 7.2 or newer;
- the Windows-provided `curl.exe`.

Download and extract the
[`windows-native` ZIP](https://github.com/FinalVar/IPQuality/archive/refs/heads/windows-native.zip),
then double-click:

```text
Install.cmd
```

A new installation goes to `%LOCALAPPDATA%\Programs\IPQuality` and does not
require administrator rights. A supported legacy installation under
`%USERPROFILE%\Documents\Codex\Tools\IPQuality-Windows` is upgraded in place so
that existing reports are not moved or deleted.

Open a new PowerShell, Command Prompt, or Run dialog and type:

```powershell
ipq
```

## Daily commands

```powershell
# IPv4 through the detected local proxy
ipq

# Real local direct IPv4 egress
ipq -Direct

# IPv6 through the detected local proxy
ipq -IPv6

# Do not save this report
ipq -NoSave

# Show the complete address; take care before sharing
ipq -FullIP

# Reduce reputation sources
ipq -Lite

# Skip slower sections
ipq -NoMedia -NoMail -NoDnsbl

# Show launcher syntax
ipq -?
```

IPv4 and IPv6 should be run separately so that one complete report fits in each
window.

The default launcher probes common local HTTP/SOCKS endpoints, starting with
`socks5h://127.0.0.1:7890`. It fails when no usable proxy is found and never
silently switches to direct testing. Use `-Direct` explicitly for the physical
connection.

HTTP, reputation, and media requests follow the selected proxy. SMTP is not
tested in proxy mode, matching upstream behavior. DNSBL checks use the local DNS
resolver against the already discovered egress IP.

## Testing one `ss://` node

For interactive use, double-click:

```text
windows\Start-NodeCheck.cmd
```

Input is hidden and the one-click path produces an IPv4 report by default. The
temporary sing-box configuration is placed in a random current-user-only
directory and is removed after the test.

The automatic download is a pinned and SHA-256-verified Windows x64 sing-box
build. ARM64 users should supply a trusted binary with `-SingBoxPath`. SIP003
`plugin=` nodes are not currently supported.

The current asset is `sing-box-1.13.14-windows-amd64.zip`, with SHA-256:

```text
f580782c6dd10f7691c66cea1d7c421813c5fbf7e305d1ee7ce0c3a40d196341
```

Avoid placing a real node URI directly in a command because command-line and
PowerShell history can retain credentials. For automation, the underlying entry
point is:

```powershell
.\windows\Test-Node.ps1 -Node $node -IPv4
```

## What is checked

- MaxMind location, ASN, registration location, and native/broadcast verdict;
- nine reputation sources: IPinfo, Scamalytics, ipregistry, ipapi, AbuseIPDB,
  IP2Location, ipdata, IPQS, and DB-IP;
- residential/datacenter evidence, per-source scores, and risk factors;
- TikTok, Disney+, Netflix, YouTube Premium, Amazon Prime Video, Reddit, and
  ChatGPT status, region, and native/DNS unlock type;
- TCP port 25 connectivity for 12 mail providers;
- 439 unique DNSBL zones from the bundled upstream list;
- colored console, JSON, and plain-text reports.

`-Lite` retains four reputation sources—IPinfo, ipregistry, ipapi, and DB-IP.
It does not automatically skip media, mail, or DNSBL checks.

## Console contract

The daily single-family result window uses:

- Consolas, with a default maximum size of 18;
- a 74-column by 47-row window;
- a buffer exactly matching the window;
- 46 complete report rows plus the PowerShell prompt on row 47;
- no horizontal or vertical scrollbar.

Smaller displays select the largest usable size below 18. Redirected output,
non-ConsoleHost environments, and physically constrained displays use a
best-effort text layout.

## Reports and privacy

`ipq` saves a masked JSON report under the installed `windows\reports`
directory unless `-NoSave` is used. Existing reports are not overwritten.

```powershell
ipq -Output .\result.json
.\windows\IPQuality.ps1 -IPv4 -Output .\result.txt
.\windows\IPQuality.ps1 -IPv4 -Output .\result.json -Force
```

JSON `Head` distinguishes:

- `Repository`: the current `FinalVar/IPQuality` implementation;
- `Upstream`: the `xykt/IPQuality` compatibility source;
- `CompatibilityBaseline`: the bundled upstream `ip.sh` SHA-256;
- `CompatibilityReviewed`: whether code, upstream script, and DNSBL list match
  the reviewed baseline.

By default, reports do not retain the complete egress IP, proxy URI, `ss://`
URI, or password. `-FullIP` deliberately includes the full address.

The assembled report is not uploaded as a document. Network checks still send
requests from the tested egress to the named data and media services, so those
services can observe that IP. DNSBL query names are visible to the configured
local DNS resolver.

## Entry points

| Entry | Intended use | Important behavior |
|---|---|---|
| `ipq` / `Start-IPQuality.ps1` | Daily visible result | IPv4 by default, automatic proxy detection, explicit `-Direct`, optional `-NoSave` |
| `IPQuality.ps1` | Automation, dual-stack, JSON/files | No automatic proxy detection; supports `-Interface`, `-Json`, and `-Force` |
| `Test-Node.ps1` | One `ss://` node | Temporary sing-box tunnel; explicit IPv4 or IPv6 |
| `Compare-IPQuality.ps1` | Upstream/Windows JSON comparison | Separates core, availability, live-service, and resolver differences |

## Upgrade and uninstall

Run a newer `Install.cmd` again to upgrade in place while preserving reports.
Double-click `Uninstall.cmd` in either the source package or installed
directory to uninstall.

The default uninstall preserves reports and the small purge entry points. To
remove the entire installation and all reports:

```powershell
.\Uninstall.ps1 -PurgeReports
```

This purge is destructive and cannot be undone.

## Accuracy boundaries

- The Windows edition targets the same fields, thresholds, and verdict
  semantics as the bundled upstream script. It does not promise byte-for-byte
  equality between two live runs.
- APIs, page content, DNS resolvers, request time, and egress changes can produce
  different observations.
- Conflicting databases produce `Mixed`; scores from different providers are
  not a common scale.
- “Native IP” only means that MaxMind usage and registration countries agree.
  It is not proof that every provider considers the address residential.
- SMTP checks only test TCP port 25 connectivity, not successful delivery.
- DNSBL failures, parked zones, and non-standard answers remain visible as
  `Errors` or `Marked`; only upstream's `127.0.0.2` answer is `Blacklisted`.

## Verification

From the repository root:

```powershell
.\windows\tests\Smoke.Tests.ps1
.\windows\tests\Smoke.Tests.ps1 -Online
```

Compare same-egress upstream and Windows JSON:

```powershell
.\windows\Compare-IPQuality.ps1 `
  -OriginalPath .\original.json `
  -WindowsPath .\windows.json `
  -Output .\comparison.json
```

CI verifies logic and packaging. A real interactive desktop is still required
to accept the 18-point, 74×47, no-scroll window contract.

## License and attribution

This Windows implementation is derived from `xykt/IPQuality` and remains under
the repository's AGPL-3.0 license. The visible report identifies the current
`FinalVar/IPQuality` implementation while JSON and maintenance records preserve
the upstream attribution.
