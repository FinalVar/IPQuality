# Windows 0.7.1 preview verification scope

This preview packages the existing Windows implementation with improved entry
pages, an offline demonstration and reproducible release tooling. Detection and
routing algorithms are unchanged from `6e7d3a572617cfd5c336dbf7720acf7e0a4fee08`;
the runtime version is updated to 0.7.1.

## Local evidence on 2026-10-10

- The existing offline smoke suite passed on the maintainer's Windows machine.
- Real IPv4 discovery and base-information requests returned one masked report,
  available base information and an ASN. Risk, media, SMTP and DNSBL were skipped.
- The demo uses synthetic data and the existing renderer. It sends no network
  requests and is not evidence of live service availability.

The release commit must also pass offline regression and archive installation in
CI before publication. See the linked run on the release.

## Unverified for this preview

This launch does not claim new physical desktop acceptance, all Windows
versions, native ARM64, live IPv6, all risk/media endpoints, SMTP delivery,
DNSBL accuracy, or a fresh same-exit comparison with upstream. No stable release
is claimed. These checks remain in the stable-release matrix.

The reviewed compatibility snapshot remains dated 2026-07-24. Matching hashes
attest to that saved baseline, not to today's remote service behavior or the
current upstream HEAD.
