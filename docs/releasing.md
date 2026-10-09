# Releasing IPQuality for Windows

Use a clean committed `windows-native` checkout. Generated assets live outside
the repository by default, under a versioned `artifacts` directory.

```powershell
.\windows\tests\Smoke.Tests.ps1
.\scripts\Build-Release.ps1
.\scripts\Test-Release.ps1 -ArtifactDirectory ..\artifacts\windows-v0.7.1-preview.1
```

`Build-Release.ps1` uses `git archive` at HEAD, not a working-directory copy.
The ZIP contains all tracked source, license and build/test tools. External
`latest.json` records the commit, tree, ZIP hash and per-file SHA-256. Do not
reuse a populated output directory or replace an existing release asset.

Package verification checks the ZIP hash, membership, file hashes, required
entry points, demo privacy markers, and installation in a temporary directory
with `-NoPath`. The existing smoke suite covers upgrade and uninstall safety.
Neither substitutes for the stable desktop and network matrix.

Before publishing:

1. Run local offline and package checks; record live verification scope.
2. Push without force and verify the remote SHA.
3. Wait for that exact commit's Windows CI to pass.
4. Tag the commit and create a GitHub prerelease while preview limitations
   remain. Upload `latest.zip`, `latest.sha256` and `latest.json`.
5. Download public assets and compare hashes. Verify rendered pages and links.

For a stable release, complete the applicable
[maintenance matrix](../windows/MAINTENANCE.md), including physical desktop
and same-exit upstream comparison. Record new network failures rather than
relaxing the claim.
