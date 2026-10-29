# Technical details

## DLL behavior

Process Lasso loads the adjacent `version.dll`. The proxy forwards 17 VERSION exports, by name and ordinal, to the absolute System32 DLL. x64 assembly thunks preserve argument registers and the caller's stack, including for the undocumented `GetFileVersionInfoByHandle` export. System DLLs are not bundled.

The real VERSION module is resolved lazily on the first forwarded call. `DllMain` only inspects the loaded image and replaces one import slot; it does not load another DLL or wait for a worker. VERSION calls from another DLL's initialization routine are outside the tested contract.

Only `ProcessLasso.exe`'s `DialogBoxParamW` import is changed in memory. Suppression requires a callback inside the main image and a `pl_rsrc_*.dll` in the same directory:

| Dialog | Additional condition | Result |
|---|---|---|
| `0xC3` | Readable reminder record: body `0x291`, nonnegative delay at offset 16, readable text pointer | Return `1` |
| `0x13BF` | Resource exists | Return `1` |
| Other calls | Includes body `0x1CE` (feature unavailable) | Forward unchanged |

Matching purchase dialogs requested by `/nag` are also suppressed. Licensing, activation and feature restrictions are unchanged. Other process names only receive VERSION forwarding.

## Installation and migration

The CLI requires an x64 executable with a valid Bitsum signature, or an exact registered legacy patched hash. Future signed versions are not rejected solely because their hash is new.

`src/known-files.json` identifies the original and patched EXEs from 18.3.0.34 and 18.4.0.48, plus previous NoNag DLLs. The current DLL is verified against the distribution manifest. Known older DLL hashes must be added before publishing an upgrade.

Legacy migration requires the matching original backup. A verified older backup left after a Process Lasso update is removed without replacing the newer executable. Unknown or newer backups are preserved and block the operation.

Changes use a directory lock, staged files, atomic replacement and rollback. Failed recovery retains its temporary directory and blocks automatic restart. Only the GUI is closed; the core engine is not stopped. `Enabled` describes the installed DLL, not a live suppression test.

## Automated checks

The daily/manual workflow verifies official installer checksums and Bitsum signatures, then checks the latest published NoNag DLL against the extracted x64 EXE and English resources:

1. Required VERSION exports and imports.
2. Reviewed dialog helper, callbacks, callers, record layout and resource roles, using normalized structural fingerprints.
3. Proxy ownership of the VERSION and dialog imports in an isolated executable copy, stopped before application entry. Nonempty TLS callback arrays require review and are never allowed to run.
4. Native dialog and VERSION forwarding tests with the extracted resources.

An EXE hash change alone does not fail compatibility. Structural differences produce `review`; acquisition, signature or tooling failures produce `error`. These checks cover the reviewed display routes and do not replace manual application testing.

Only a published-release pass updates the automated README row. Development runs do not publish results. Discord notifications use `DISCORD_WEBHOOK_URL`, deduplicate by executable/DLL/checker/result identity and retry failed deliveries. Reports contain hashes, release and environment information; vendor binaries are not uploaded.

See [Development and testing](https://github.com/sino87/ProcessLasso-NoNag/blob/master/docs/TESTING.md) for build and release steps.
