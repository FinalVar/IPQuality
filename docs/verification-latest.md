# Windows 0.8.0 preview verification scope

Reviewed on 2026-10-13 against official xykt/IPQuality commit
`87397e2c3196ec796f5477c83343c2354df601ea`, script `v2026-09-16`.
See [capability mapping and differences](upstream-sync/latest.md).

## Local evidence

- Offline parser, installer, upgrade, uninstall and Windows PowerShell 5.1
  bootstrap suite; byte-based UTF-8 decoding under code pages 936 and 65001.
- New upstream endpoint/rule fixtures: ipapi, DB-IP two-stage request, Amazon,
  Reddit/IPv6 fallback, TikTok region, DNS and 423-zone data integrity.
- Locale fallback, automatic IPinfo Lite, official JSON field mapping, ANSI/plain
  exports and upload-contract tests. Sharing tests did not upload real reports.
- Full-data report rendering has 46 rows and fits 74 columns in Chinese and English.
- Real current-proxy IPv4 full run: 8/9 risk sources returned data; ipapi and
  ipregistry now available. DB-IP, Disney+ and Netflix had TLS failures; TikTok
  timed out. YouTube, Amazon, Reddit and ChatGPT returned results.
- DNSBL queried 423 zones: 1 clean, 422 marked, 0 blacklisted, 1 error; marked
  answers used local FakeIP addresses. This is not evidence of real DNSBL listings.
- Chinese and English live basic-information requests returned valid masked JSON;
  the Chinese country/continent values were intact (香港 / 亚洲).

## Required package and CI gate

The exact release commit must pass the full offline suite and source archive
installation verification locally and on Windows GitHub Actions before publishing
its preview. Release metadata records the source commit and hashes. Current
runtime availability is distinct from the source compatibility baseline.

## Validation boundaries

Not revalidated: physical desktop display, all Windows versions, native ARM64,
IPv6 end-to-end, direct SMTP on a public NIC, playback/login, public online-report
rendering and a simultaneous same-exit Bash/native run. No stable-release or
universal service-availability claim is made.