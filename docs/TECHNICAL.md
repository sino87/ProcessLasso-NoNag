# Technical details

## DLL behavior

Process Lasso loads `version.dll` from its own directory. The proxy forwards 17 VERSION exports by name and ordinal to the System32 DLL, using its full path. x64 assembly thunks preserve argument registers and the caller's stack, including calls to the undocumented `GetFileVersionInfoByHandle` export. System DLLs are not bundled.

The proxy resolves the real VERSION module on the first forwarded call. `DllMain` only inspects the loaded image and replaces one import slot, without loading another DLL or waiting for a worker. VERSION calls from another DLL's initialization routine have not been tested.

In memory, the hook changes only `ProcessLasso.exe`'s `DialogBoxParamW` import. Dialog suppression requires a callback in the main image and a `pl_rsrc_*.dll` in the same directory:

| Dialog | Additional condition | Result |
|---|---|---|
| `0xC3` | Readable reminder record: body `0x291`, nonnegative delay at offset 16, readable text pointer | Return `1` |
| `0x13BF` | Resource exists | Return `1` |
| Other calls | Includes body `0x1CE` (feature unavailable) | Forward unchanged |

The hook also suppresses matching purchase dialogs opened with `/nag`. Licensing, activation and feature restrictions are unchanged. For other process names, the proxy only forwards VERSION calls.

## Installation and migration

The CLI requires a valid Bitsum-signed x64 executable or a legacy patched executable with an exact registered hash. A new hash alone does not block a future signed version.

`src/known-files.json` identifies the original and patched EXEs from 18.3.0.34 and 18.4.0.48, plus previous NoNag DLLs. The CLI verifies the current DLL against the distribution manifest. Add known older DLL hashes before publishing an upgrade.

Legacy migration requires the matching original backup. After a Process Lasso update, the CLI removes verified older backups without replacing the newer executable. Unknown or newer backups are kept and block the operation.

The CLI locks the directory, stages files, replaces them atomically and rolls back failed changes. If recovery fails, it keeps the temporary directory and blocks automatic restart. Only the GUI is closed; the core engine keeps running. `Enabled` confirms DLL installation, not suppression in a running application.

## Automated checks

The workflow's daily and manual runs verify official installer checksums and Bitsum signatures, then check the latest published NoNag DLL against the extracted x64 EXE and English resources:

1. Required VERSION exports and imports.
2. Dialog helper, callbacks, callers, record layout and resource roles, compared with reviewed normalized structural fingerprints.
3. Proxy ownership of the VERSION and dialog imports in an isolated executable copy stopped before application entry. Nonempty TLS callback arrays require review and are never allowed to run.
4. Native dialog and VERSION forwarding tests with the extracted resources.

The workflow selects NoNag releases by publication date, including prereleases and excluding drafts.

An EXE hash change alone does not fail compatibility. Structural differences produce `review`; acquisition, signature or tooling failures produce `error`. The checks cover reviewed dialog display paths. Manual application testing is still needed.

The automated README row is updated only when a published-release check passes. Development results are not published. Discord notifications use `DISCORD_WEBHOOK_URL` and are deduplicated by executable, DLL, checker and result. Failed deliveries are retried. Reports contain hashes, release and environment information. Vendor binaries are not uploaded.

See [Development and testing](https://github.com/sino87/ProcessLasso-NoNag/blob/master/docs/TESTING.md) for build and release steps.
