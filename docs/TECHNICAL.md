# Technical details

## DLL behavior

Process Lasso loads the local `version.dll`. NoNag forwards Windows VERSION calls to the System32 DLL and hooks `ProcessLasso.exe`'s `DialogBoxParamW` import in memory. Other process names receive VERSION forwarding only.

`DllMain` installs the hook without loading another DLL or waiting for a worker. VERSION forwarding is resolved on first use. Calls from another DLL's initialization routine have not been tested.

Suppression requires a callback in the main EXE and a matching dialog resource in a `pl_rsrc_*.dll` in the same directory:

| Dialog | Additional condition | Result |
|---|---|---|
| `0xC3` | Readable reminder record and text pointer, body `0x291`, nonnegative delay | Suppress |
| `0x13BF` | No additional conditions | Suppress |
| Other calls | Includes body `0x1CE` (feature unavailable) | Forward unchanged |

Matching dialogs opened with `/nag` are also suppressed. Licensing, activation and feature restrictions are unchanged.

## Installation and migration

The CLI requires a valid Bitsum-signed x64 executable or a legacy patched executable with an exact registered hash. A new hash alone does not block a future signed version.

Legacy EXEs and previous DLLs are identified by hashes in `src/known-files.json`. The supplied DLL is checked against its distribution manifest.

Migration from v0.1.1 and earlier requires the matching `ProcessLasso-Original.exe`. Verified older backups left by a Process Lasso update are removed without replacing the newer EXE. An unknown DLL or an unknown/newer backup is left untouched and blocks the operation.

File changes use a directory lock, staging, atomic replacement and rollback. If recovery is incomplete, keep the reported temporary directory; automatic restart is blocked. Only the GUI is closed; the core engine keeps running.

`Enabled` means the DLL is installed. It does not confirm suppression in the running application.

## Automated checks

The workflow verifies official installer checksums and Bitsum signatures, then tests the latest published NoNag DLL with the extracted x64 EXE and English resources. It checks:

1. Required VERSION exports and imports.
2. Dialog code, call arguments, record layout and resource roles against reviewed structural fingerprints.
3. DLL loading and import hooks in an EXE copy stopped before application entry. Application TLS callbacks require review and are not allowed to run.
4. Native dialog and VERSION forwarding tests with the extracted resources.

An EXE hash change alone does not fail compatibility. Unrecognized structures or control flow produce `review`; acquisition, signature or tooling failures produce `error`. These checks cover reviewed dialog paths and still require manual application testing.

Only a successful published-release check updates the automated README row. Development results are not published. Discord notifications are deduplicated, and failed deliveries are retried. Reports contain hashes, release and environment details; vendor binaries are not uploaded.

See [Development and testing](https://github.com/sino87/ProcessLasso-NoNag/blob/master/docs/TESTING.md) for build and release steps.
