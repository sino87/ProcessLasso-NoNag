# Maintainer checks

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-NoNag.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WorkerExitCodes.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Upstream.ps1
python -m pip install --only-binary=:all: --require-hashes -r scripts/analysis-requirements.txt
python -m unittest discover -s tests -p "test_*.py"
```

Transaction tests use temporary synthetic files and stub GUI operations. To test a verified original executable without changing it, add `-FixturePath 'path\to\ProcessLasso.exe'` to the first command.

## Manual checks

Use a VM and keep a baseline checkpoint.

- Apply and restore with the GUI open and closed; check hashes against TECHNICAL.md.
- Confirm UAC, graceful exit, force-close acceptance/cancellation, and restart behavior.
- Check startup, normal launch, tray redisplay, list updates, settings, and core-engine reconnection.
- Check existing/missing/corrupt backups, unsupported targets, and concurrent operations.
- Check custom paths and another Windows session.

For 18.4.0.48, follow [VM checks](VM-18.4.0.48.md). To test replacement of a real older backup, run `Test-NoNag.ps1` with both `-FixturePath` pointing to the new original and `-OlderFixturePath` pointing to a registered older original.

## Distribution

Keep tests and CI configuration in Git. The user ZIP contains `Start.cmd`, `src/CLI.ps1`, `src/NoNag.psm1`, `src/profiles.json`, `README.md`, `docs/TECHNICAL.md`, and `LICENSE`. Exclude tests, analysis dependencies, templates, maintainer checklists, and vendor binaries.

Run **Draft release** from Actions and enter a tag such as `v1.0.0`. It runs tests, builds the ZIP, creates the tag, and creates a **draft** GitHub Release. Review its notes and attachment, then publish manually. Existing tags are refused.

To build the same ZIP locally:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1 -Tag v1.0.0
```

Output: `dist/ProcessLasso-NoNag-v1.0.0.zip`. Existing output files are not overwritten.

## Upstream checks

**Upstream static check** runs daily at approximately 09:17 JST and can be run manually. Scheduled Actions may be delayed; public repositories disable schedules after 60 days without activity.

Uncheck **Publish candidates, update README and notify Discord** for a diagnostic manual run without secrets or repository writes. Every manual run performs a fresh check and analysis when needed.

Register `DISCORD_WEBHOOK_URL` under Settings > Secrets and variables > Actions > Repository secrets. Use a Discord webhook URL without query parameters. Only the publication job receives the secret. Enable **Allow GitHub Actions to create and approve pull requests** under Settings > Actions > General. The publication job uses `GITHUB_TOKEN` with contents and pull-requests write permissions; the analysis job is read-only. No personal access token is required.

The checker selects stable x64 from the official download page, downloads the installer, verifies the published SHA-256 and valid Bitsum signature, and extracts `ProcessLasso.exe` and `pl_rsrc_english.dll` using 7-Zip. It verifies the executable signature, x64 PE headers, and numeric version. Neither vendor file is run or loaded as a DLL.

Every run downloads and inspects the current small installer, including manual reruns. A changed installer with the same version is detected. A metadata/checksum mismatch is a check error and is retried on the next run.

An executable passes only if its hash is registered, patch generation changes exactly the expected bytes for that build, and fixture Apply/Restore and worker-exit tests pass. Unregistered executables remain `review` even when an analysis candidate is found. Candidate generation does not establish runtime behavior or update the README's last-passing version.

On the default branch, a pass updates only the README's **Automated static check** row. **Manual test** is updated by a maintainer after VM testing. Other branches report results without sending notifications or writing repository state. No release is created by this workflow.

Discord receives candidate-generated, analysis-required, check-error, and recovery notifications. Candidate notifications include the draft PR link. `.github/upstream-state.json` preserves legacy notifications and records PRs and delivered events. Candidate notifications are deduplicated by source hash/PR; inconclusive results by source hash/reason. Failed sends remain eligible for retry. A state-push failure may cause duplicate delivery.

Default-branch commits update only README and notification state. Candidate branches add only a proposed registry profile (`VmValidated=false`) and its report. Open PRs are reused without overwriting human edits; closed PRs are not recreated unless **Reopen a candidate proposal** is selected manually and the branch still matches the generated files. A concurrent branch update or branch protection can block publication; rerun after resolving it. No force-push is used. Bot-created PR CI can require **Approve workflows to run**; candidate validation already runs explicitly before publication.

The Actions summary and a 30-day artifact contain JSON reports and any preview CLI ZIP. Vendor binaries and webhook URLs are excluded. Check errors, analysis tool errors, or publication failures fail the run; inconclusive analysis completes with `review`. README retains the last passing version on either result.

Run locally without notifications or repository updates:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Check-Upstream.ps1
```

Local runs require 7-Zip at `C:\Program Files\7-Zip\7z.exe`, or specify `-SevenZipPath`. Unregistered-build analysis requires Python 3.12 x64 and the pinned dependencies above; specify `-PythonPath` when needed. `-SkipAnalysis` performs only the registered-profile check. Reports and temporary vendor files remain under ignored `dist/upstream/`. `-MetadataPath` and `-InstallerPath` allow checking downloaded official files.

## Automatic candidate analysis

`scripts/analyze_patch.py` uses pefile and Capstone. It follows reachable x64 instructions within runtime-function ranges, resolves the supported switch-table pattern, and matches all three routes against reviewed templates. Addresses and consistently referenced stack slots are normalized; conditions, constants, imports, string fingerprints, helper structure, and branch relationships remain significant. Missing or ambiguous matches, unknown dispatch forms, or changed resource roles produce an inconclusive result without a patch. This is a restricted structural comparison, not a general semantic proof.

Templates under `scripts/templates/` are generated from verified originals. The analyzer reads no target patch offsets from the registry. Exact candidate hashes, original/modified instructions and targets, template identities, and analyzer revision appear in the report. Generation requires one shared predicate across all three routes, unchanged file size, exactly six modified bytes, and exact byte-for-byte reversal.

Run the historical gate locally with the privately held vendor files:

```powershell
./scripts/Test-HistoricalAnalysis.ps1 -BaselineDirectory path/to/18.3.0.34 -TargetDirectory path/to/18.4.0.48
```

This extracts a template from 18.3.0.34 only, discovers the 18.4.0.48 candidate, compares its hash against the previously verified patch, runs the production transaction/worker tests in an isolated workspace, and builds a preview ZIP. Synthetic instruction fixtures and malformed PE inputs exercise the analysis rules in ordinary CI; real vendor files are not committed.

When a candidate PR arrives, review the instructions and test the preview ZIP in a VM against a baseline that reproduces the reminders. After successful Apply/Restore and behavioral tests, set its profile's `VmValidated` to true, update the manual-test row and technical details, and merge. The next registered-build check can update the automated row. Releases remain manual drafts.
