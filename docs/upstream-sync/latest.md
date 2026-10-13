# Official upstream feature map — Windows 0.8.0 preview

Reviewed on 2026-10-13 against official `xykt/IPQuality/main` commit
`87397e2c3196ec796f5477c83343c2354df601ea` (2026-09-30), script `v2026-09-16`.
The previous baseline was `v2026-03-29`; the fork's mirror was 17 commits behind.
Source and reference files are copied from this exact upstream commit. Hashes
are recorded in `windows/compatibility-baseline.json`.

## Capability mapping

| Official capability | Native implementation / entry | Review and validation |
|---|---|---|
| IPv4 / IPv6, explicit proxy | `New-IPQContext`, `Get-IPQPublicAddress`; `-IPv4/-IPv6/-Proxy`, aliases `-4/-6/-x` | Family-specific discovery; no silent route fallback; IPv4 live check passed |
| Interface / local source address | `-Interface/-i`; Windows NIC alias converted to a local address before curl | Platform adaptation; local-address and alias fixture coverage |
| Both address families | Core entry defaults to both; daily launcher `-DualStack -Json` | Available for automation; one address family per visible window |
| Eight basic-information languages | `-Language/-l cn,en,jp,es,de,fr,ru,pt`; `-English/-E` | Selected locale plus English field fallback; non-cn report labels are English; cn/en live checks |
| MaxMind location and ASN | `Get-IPQMaxMindInfo`, DMS, map zoom, subdivision, registration, geo verdict | Official fields and thresholds; map locale propagated |
| Automatic Lite fallback | MaxMind failure selects IPinfo basic information and four-source risk checks | Offline failure fixture verifies country, city, ASN, coordinates and language |
| IPinfo | `Get-IPQSourceIPInfo` | Types and privacy flags retained; live available |
| Scamalytics | `Get-IPQSourceScamalytics` | Score, thresholds and risk flags retained; live available |
| ipregistry | `Get-IPQSourceIPRegistry` | Demo-page key discovery and API retained; live available |
| ipapi | `Get-IPQSourceIPApi` | Migrated to `ipinfo.check.place/{IP}?db=ipapi`; missing score stays null; HTML rejected; live available |
| AbuseIPDB | `Get-IPQSourceAbuseIPDB` | Usage, country and score retained; live available |
| IP2Location | `Get-IPQSourceIP2Location` | Usage, company, score and risk factors retained; live available |
| ipdata | `Get-IPQSourceIPData` | Threat flags retained; live available |
| IPQS | `Get-IPQSourceIPQS` | Score, thresholds and flags retained; live available |
| DB-IP | `Get-IPQSourceDBIP` | Replaced obsolete HTML parser with official core-page key discovery and currency POST API; request/response fixtures passed; live TLS handshake failed on current route |
| TikTok | `Test-IPQTikTok` | Official region field, challenge page, gzip/IDC fallback; unrelated country fields excluded; live request timed out |
| Disney+ | `Test-IPQDisneyPlus` | Device assertion, token, GraphQL and region rules; bundled official cookie templates retained; live TLS failure |
| Netflix | `Test-IPQNetflix` | Two title pages and originals-only decision retained; offline status fixtures; live TLS failure |
| YouTube Premium | `Test-IPQYouTube` | Premium availability and region rules retained; live result obtained |
| Prime Video | `Test-IPQPrimeVideo` | Only the first exact currentTerritory field determines region; regression fixtures and live check passed |
| Reddit | `Test-IPQReddit` | New `/svc/shreddit/reddit-chat` path, first country attribute, IPv6 AAAA/Fastly fallback; fixtures and IPv4 live check passed |
| ChatGPT | `Test-IPQChatGPT` | Web, iOS, favicon, trace and partial-access decisions retained; fixtures and live result obtained |
| Native/DNS unlock classification | `Invoke-IPQDnsCompatibilityProbe` | Updated empty/invalid address, missing answer-count and wildcard behavior; private/subnet/wildcard rules retained |
| Mail providers and port 25 | `Get-IPQMailChecks`, 12 providers | Native TCP/MX/source-binding adaptation; proxy mode explicitly unsupported; offline proxy/binding tests |
| DNSBL | `Get-IPQDnsblChecks` | Official 423 unique zones; `127.255.255.*` first answer clean, sole `127.0.0.2` blacklisted, other nonempty answers marked; live 423-zone run |
| Full/masked IP | `-FullIP/-f` | Default masking retained; reverse-IP DNS errors also masked; full-IP option remains explicit |
| JSON output | `-Json/-j`; `-UpstreamJson` | Rich native schema retained; seven-section official field mapping additionally available, including Company.IP2LOCATION and Factor.CountryCode |
| Plain text / ANSI / JSON file | `-Output/-o` | Extension-based export; ANSI color retained, plain text stripped; overwrite requires `-Force` |
| Online report and privacy | `-AllowOnlineReport`, `-Privacy/-p` | Official form endpoint and JSON/ANSI payload implemented; only explicit sharing uploads; mocked request/cleanup/URL validation passed |
| Interactive menu | `-Menu/-M` | Native menu selects route, family, language, output and sharing; no remote Bash execution |
| Help and dependency flags | `-Help/-h`, `-NoDependencyCheck/-n`, `-InstallDependencies/-y` | Native help; Windows installer/bootstrap handles PowerShell; built-in curl replaces Linux jq/dig/nc/awk dependencies |
| Authors and sponsors | `-ShowSponsors`, `docs/upstream/`, `ref/` | Official content retained; separate view preserves the requested report window dimensions |
| Official run counter | `-CountRun` | Optional official counter request, result in native JSON Head.RunCounter; no counter request by default |
| Reference data | Entire `ref/` at the pinned commit | DNSBL, ISO countries, cookie templates, IATA and sponsor assets synchronized; obsolete installed refs moved to a dated backup |

## Explicit differences and boundaries

Windows integration uses PowerShell, curl ArgumentList, Windows DNS/TCP APIs and
a 74×47 console with Consolas size at most 18. Report rendering has fixtures for
46 full-data rows in both languages; no desktop automation was used for this
update, so this is a programmatic layout check, not new physical GUI acceptance.

The daily launcher retains the user's existing IPv4, current-proxy, masked-IP,
local-save defaults. Unlike upstream defaults, assembled-report sharing and run
counting require explicit options. Both capabilities exist. Sponsors have their
own view so they do not occupy the 46-line report. The local menu replaces the
external Check.Place Bash menu for IPQuality options; other Check.Place products
are not bundled.

Requests keep the explicit route, including DB-IP/IPinfo on IPv6; the native
version does not silently clear a proxy to imitate upstream's IPv4-only fallback.
A service without support returns an unavailable result. Windows interface names
are resolved to local source addresses because Windows curl cannot use Linux
interface binding directly. SMTP preserves the existing documented NAT-equivalent
probe where the public egress address is not assigned to a local NIC.

Native JSON is intentionally richer than upstream JSON. `-UpstreamJson` maps the
seven official sections and English/CN labels; it uses real null/numeric values
instead of upstream's frequent string `"null"`/numeric strings. It preserves the
actual IPQS score instead of copying upstream's `ipapi[ipqs]` serialization typo.
The deprecated IPWHOIS factor columns remain null. Original source code is kept
unchanged for traceability; output is not claimed to be byte-identical.

The live current-proxy check returned 8 of 9 reputation sources. DB-IP, Disney+
and Netflix had TLS failures; TikTok timed out. Those observations do not establish
the root cause and are not evidence that these services are blocked by region.
The DNSBL run returned 1 clean / 422 marked / 0 blacklisted / 1 query error; the
marked answers were local FakeIP addresses, not proof of 422 actual listings.
The query error is counted with upstream's empty-response semantics and retained
in detailed JSON. No real reports or credentials are included in this repository.

Not revalidated: live IPv6 end-to-end, direct SMTP on a public NIC, actual media
playback/login, public upload rendering, and simultaneous Bash/native results on
the same exit. These remain release-validation boundaries, not removed features.
This build remains a preview.

## Maintenance procedure

Fetch **official** upstream/main, inspect all commits since the pinned baseline,
map every changed endpoint, flag, decision and reference file, then add relevant
boundary fixtures. Run the offline suite, a current-route live check and package
installation tests. Update the baseline only after reviewing behavior; source
hash equality alone is insufficient. Merge upstream history while retaining the
Windows landing pages and refreshing the original README snapshots. Future
unreviewed source/data changes must set CompatibilityReviewed false.
