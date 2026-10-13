# IPQuality for Windows

**Inspect your proxy exit IP, risk signals and service reachability on Windows. No Docker or WSL.**

[中文](README.md) · [Download preview](https://github.com/FinalVar/IPQuality/releases/tag/windows-v0.8.0-preview.1) · [User guide](windows/README_EN.md) · [Report a problem](https://github.com/FinalVar/IPQuality/issues/new/choose)

[![Windows tests](https://github.com/FinalVar/IPQuality/actions/workflows/windows-native.yml/badge.svg?branch=windows-native)](https://github.com/FinalVar/IPQuality/actions/workflows/windows-native.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

<!-- windows-native:start -->
A community PowerShell port of [xykt/IPQuality](https://github.com/xykt/IPQuality),
maintained by FinalVar. It uses PowerShell 7 and Windows `curl.exe`, with per-user
installation, explicit proxy routing, masked reports and JSON export.
This is not an official upstream Windows release.

## Get started

1. Install [Microsoft PowerShell 7.2 or newer](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows).
2. Download `latest.zip` from the [versioned release](https://github.com/FinalVar/IPQuality/releases/tag/windows-v0.8.0-preview.1), extract it and double-click `Install.cmd`. Administrator rights are not required.
3. Open a new terminal:

```powershell
ipq           # Check a detected local proxy's IPv4 exit; fail if unavailable
ipq -Direct   # Explicitly check this machine's direct IPv4 exit
ipq -IPv6     # Check the proxy's IPv6 exit; do not substitute IPv4
```

To inspect the output before installing, run the offline demo from the extracted folder:

```powershell
pwsh -NoProfile -File .\windows\Show-Demo.ps1
```

![Offline synthetic data rendered by the real formatter; not a real IP measurement](docs/demo/latest.svg)

## What it tells you

| Question | Output |
| --- | --- |
| Which exit is being tested? | Address family, route, ASN and geography |
| How do risk providers classify it? | Separate sources, including conflicts, unknowns and errors |
| Are streaming and AI services reachable? | Status, region and evidence; not proof of account access or playback |
| Can I investigate further? | Masked JSON, text export and an upstream comparison tool |

Missing proxies never silently fall back to a direct connection. HTTP and media
requests follow the selected proxy; DNSBL uses local DNS, and SMTP is skipped
in proxy mode. See the [routing contract](windows/README_EN.md).

## Downloads and verification

The current release is **0.8.0 public preview**. Its versioned release contains
`latest.zip`, `latest.sha256`, and `latest.json` with the source commit and file
hashes. Use a versioned release for a repeatable download; branch ZIPs change.

```powershell
Get-FileHash .\latest.zip -Algorithm SHA256
Get-Content .\latest.sha256
```

Compare both hashes before installation. This verifies download integrity; it
is not a code signature. Use -English for English labels and -Language for the eight official basic-info languages. Demo data is synthetic.

## Privacy and limits

- IPs are masked by default. Assembled reports are uploaded only with -AllowOnlineReport; contacted
  services can observe the tested exit IP.
- Provider scores are different scales. Geographic registration does not
  establish that an IP is residential or accepted by every service.
- CI covers offline behavior and archive installation. Windows version coverage,
  physical desktop layout, IPv6 and all current third-party services have not
  been revalidated for this preview. See [verification scope](docs/verification-latest.md).
- Review reports before sharing. Do not post proxy URLs, node credentials,
  secrets or full IP addresses in issues.

Use the [issue templates](https://github.com/FinalVar/IPQuality/issues/new/choose)
with your OS, PowerShell version, command shape and sanitized error.
See the [full guide](windows/README_EN.md) for support and uninstall instructions.
<!-- windows-native:end -->

## Upstream and license

The Bash implementation and compatibility semantics originate from
**[xykt/IPQuality](https://github.com/xykt/IPQuality)**. This derivative remains
[AGPL-3.0](LICENSE). Acknowledgments, sponsors and history are retained in the
[upstream Chinese](docs/upstream/README.md) and [English](docs/upstream/README_EN.md)
snapshots, with [provenance](docs/upstream/PROVENANCE.md). Linux/macOS users should use upstream.

[Maintenance](windows/MAINTENANCE.md) · [Release procedure](docs/releasing.md)
