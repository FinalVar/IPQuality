# Maintenance scope

This is the Windows product branch of `xykt/IPQuality`, under AGPL-3.0.
Read `windows/MAINTENANCE.md` before changing runtime behavior.

- Preserve upstream authorship, license and the reviewed compatibility baseline.
- Keep feature parity with the current official xykt/IPQuality source. Only
  Windows platform integration is implemented separately; retain all other
  capabilities, options, detection sources, decision rules and reference data.
  Do not silently reduce scope. Record a source-backed feature map and explicit
  unresolved differences; matching the fork HEAD or updating a bundled script
  alone does not prove parity. User-confirmed requirement: 2026-10-13.
- Root READMEs explain the Windows distribution. Preserve upstream README
  snapshots in `docs/upstream/` and their provenance when syncing.
- Runtime changes need the offline suite and relevant boundary tests. CI is not
  physical desktop acceptance. Keep live validation claims scoped to evidence.
- Build packages from a clean committed tree using `scripts/Build-Release.ps1`;
  verify with `scripts/Test-Release.ps1`. Never package the working directory.
- Generated deliverables use `latest`, under versioned parent directories.
  Never commit reports, credentials or generated release assets.
- Label demonstrations synthetic; never publish real IPs or proxy credentials.
- Retain preview labels until the stable-release matrix is complete.
