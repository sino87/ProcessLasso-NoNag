# Maintainer checks

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-NoNag.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WorkerExitCodes.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Upstream.ps1
```

Transaction tests use temporary synthetic files and stub GUI operations. To test a verified original executable without changing it, add `-FixturePath 'path\to\ProcessLasso.exe'` to the first command.

## Manual checks

Use a VM and keep a baseline checkpoint.

- Apply and restore with the GUI open and closed; check hashes against TECHNICAL.md.
- Confirm UAC, graceful exit, force-close acceptance/cancellation, and restart behavior.
- Check startup, normal launch, tray redisplay, list updates, settings, and core-engine reconnection.
- Check existing/missing/corrupt backups, unsupported targets, and concurrent operations.
- Check custom paths and another Windows session.

## Distribution

Keep tests and CI configuration in Git. The user ZIP contains `Start.cmd`, `src/CLI.ps1`, `src/NoNag.psm1`, `README.md`, `docs/TECHNICAL.md`, and `LICENSE`. Exclude tests, maintainer checklists, and vendor binaries.

Run **Draft release** from Actions and enter a tag such as `v1.0.0`. It runs tests, builds the ZIP, creates the tag, and creates a **draft** GitHub Release. Review its notes and attachment, then publish manually. Existing tags are refused.

To build the same ZIP locally:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1 -Tag v1.0.0
```

Output: `dist/ProcessLasso-NoNag-v1.0.0.zip`. Existing output files are not overwritten.

## Upstream checks

**Upstream static check** runs daily at approximately 09:17 JST and can be run manually. Scheduled Actions may be delayed; public repositories disable schedules after 60 days without activity.

Uncheck **Update README and send Discord notifications** for a diagnostic manual run without secrets or repository writes. Every manual run performs a fresh check.

Register `DISCORD_WEBHOOK_URL` under Settings > Secrets and variables > Actions > Repository secrets. Use a Discord webhook URL without query parameters. Only the notification step receives the secret. No personal access token is required.

The checker selects stable x64 from the official download page, downloads the installer, verifies the published SHA-256 and valid Bitsum signature, and extracts only `ProcessLasso.exe` using the runner's 7-Zip. It verifies the executable signature, x64 PE headers, and numeric version. Neither installer nor executable is run.

Every run downloads and inspects the current small installer, including manual reruns. A changed installer with the same version is detected. A metadata/checksum mismatch is a check error and is retried on the next run.

An executable passes only if its hash is supported by the current module, patch generation changes exactly the six expected bytes, and fixture Apply/Restore and worker-exit tests pass. Unregistered executables require analysis even when old offset bytes match. The report includes the original offsets and observed bytes for diagnosis; it does not locate or approve new patch sites automatically.

On the default branch, a pass updates only the README's **Automated static check** row. **Manual test** is updated by a maintainer after VM testing. Other branches report results without sending notifications or writing repository state. No release is created by this workflow.

Discord receives analysis-required, check-error, and recovery notifications with the version, reason, and run link. `.github/upstream-state.json` records successfully notified executable hashes and the last error stage. The same executable is notified once; repeated errors at the same stage are suppressed until recovery or a different stage. Failed sends are not recorded as successful and are retried. Exactly-once delivery is not guaranteed if state cannot be pushed after delivery.

The workflow uses `GITHUB_TOKEN` to commit only README and notification state. A concurrent branch update or branch protection may block the push; rerun after resolving it. Do not enable force-push. Bot pushes do not trigger the existing push test workflow.

The Actions summary and a 30-day JSON artifact contain the result. Vendor binaries and webhook URLs are excluded from artifacts. Check errors or notification failures fail the run; analysis-required is a completed check with a review result. README retains the last passing version on either result.

Run locally without notifications or repository updates:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Check-Upstream.ps1
```

Local runs require 7-Zip at `C:\Program Files\7-Zip\7z.exe`, or specify `-SevenZipPath`. Reports and temporary vendor files remain under ignored `dist/upstream/`. `-MetadataPath` and `-InstallerPath` allow checking previously downloaded official files.
