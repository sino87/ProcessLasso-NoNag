# Maintainer guide

## Tests

Run from the repository root on Windows with Python 3.12 x64:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-NoNag.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WorkerExitCodes.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Upstream.ps1
python -m pip install --only-binary=:all: --require-hashes -r scripts/analysis-requirements.txt
python -m unittest discover -s tests -p "test_*.py"
```

Transaction tests use temporary files and stub GUI operations. Add `-FixturePath path/to/ProcessLasso.exe` to test a registered original. Add `-OlderFixturePath path/to/older/ProcessLasso.exe` to test replacement of a registered older backup.

## VM checks

Keep a baseline checkpoint. Verify Apply/Restore with the GUI open and closed, hashes, UAC, graceful exit, force-close cancellation, and restart. Check startup, normal launch, tray redisplay, process-list updates, settings, and core-engine reconnection. Test invalid backups, unsupported targets, concurrent operations, custom paths, and another Windows session.

After validating a candidate, set its profile's `VmValidated` to `true`, update the README's **Manual test** row and `TECHNICAL.md`, then merge its PR.

## Upstream checks

Configure the `DISCORD_WEBHOOK_URL` repository secret and enable **Allow GitHub Actions to create and approve pull requests** under Settings > Actions > General.

**Upstream static check** runs daily around 09:17 JST and supports manual runs. Uncheck **Publish candidates, update README and notify Discord** for diagnostics without publishing. Select **Reopen a candidate proposal** only when retrying a closed candidate PR; edited branches are not overwritten.

Review the run summary and artifacts for candidate ZIPs and analysis results. Reports expire after 30 days. A generated candidate remains **review**, pending manual VM validation. Only a passing registered-build check updates the README's **Automated static check** row.

If publication fails, check workflow permissions, branch protection, webhook configuration, or concurrent branch updates before rerunning. Failed notifications are retried; a state-save failure can cause duplicate delivery. Public repositories disable scheduled workflows after 60 days without activity.

For local checks, install the analysis dependencies above and 7-Zip, then run `./scripts/Check-Upstream.ps1`. Override `-PythonPath` or `-SevenZipPath` as needed. `-MetadataPath` and `-InstallerPath` accept downloaded official files; `-SkipAnalysis` checks only registered profiles. Output stays under ignored `dist/upstream/`.

To repeat the historical analysis using locally held vendor files:

```powershell
./scripts/Test-HistoricalAnalysis.ps1 -BaselineDirectory path/to/18.3.0.34 -TargetDirectory path/to/18.4.0.48
```

## Release

Run **Draft release** from Actions and enter a new tag such as `v0.1.2`. Review the draft's notes and ZIP, then publish manually. Existing tags are refused.

To build locally, run `./scripts/Build-Release.ps1 -Tag v0.1.2`. Output is `dist/ProcessLasso-NoNag-v0.1.2.zip`; existing files are not overwritten. Vendor binaries are excluded from both the user ZIP and Git.
