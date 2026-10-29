# Development and testing

Requires MSVC x64 with CMake, the Windows SDK, Python 3.12 and Windows PowerShell 5.1.

```powershell
python -m pip install --only-binary=:all: --require-hashes -r scripts/analysis-requirements.txt
./scripts/Build-Native.ps1
python -m unittest discover -s tests -p 'test_*.py'
./tests/Test-NoNag.ps1
./tests/Test-WorkerExitCodes.ps1
./tests/Test-Upstream.ps1
./tests/Test-Package.ps1
```

Native tests use self-authored dialog resources. To include local vendor fixtures, set `NONAG_FIXTURE_ROOT` to a directory containing version-named folders, each with `ProcessLasso.exe` and `pl_rsrc_english.dll`. These tests also check deliberately incompatible copies. Do not commit vendor binaries.

## Manual check

Use an installation where the original purchase reminder can be reproduced. Check Enable/Disable, legacy migration and DLL upgrades, then normal launch, tray redisplay, startup launch, process-list updates, settings and feature messages. Check administrator cancellation, GUI cancellation, restart and Process Lasso updates. Choose a test environment appropriate for your installation.

Update the manual README row with the Process Lasso version only after testing the actual NoNag build. Record the NoNag build and DLL hash separately.

## Draft release

Run **Draft release** from Actions with the chosen tag. It builds/tests the DLL and attaches a ZIP and `SHA256SUMS.txt` to a draft. Review and publish manually. Before releasing a replacement DLL, add the previous release's DLL hash to `src/known-files.json`.

For a local package:

```powershell
./scripts/Build-Native.ps1
./scripts/Build-Release.ps1 -Tag development
```

For a release build, use the chosen tag with `Build-Native.ps1 -BuildId` and `Build-Release.ps1 -Tag`.

## Upstream checks

Before the first DLL release, run **Upstream compatibility check** manually with `development_build` enabled. Results are retained without README updates or Discord notifications.

After publishing the first DLL release, run the default check once. Then set the repository Actions variable `DLL_CHECKS_ENABLED` to `true` to enable the daily 09:17 JST check. Keep the existing `DISCORD_WEBHOOK_URL` secret. The check job has read-only repository access; only the publication job can update README/state and access the webhook.

After reviewing changed dialog code, update the checker as needed and record the new structure with `check_compatibility.py --record-reference --expected-source-hash <reviewed SHA-256>` and the usual file arguments. Reference recording is a maintainer operation; scheduled checks never change the reference.
