# Technical details

## Supported binary

Registered builds are listed below. The SHA-256 identifies the executable; the version label alone is insufficient. Both builds have passed static and transaction checks and have been manually validated in a VM.

18.3.0.34 x64, 2,631,664 bytes:

| State | SHA-256 |
|---|---|
| Original | `2f6f1005b5d67a7e7468c66b106d45ac0e2537cbc82fb6b7edce3c89fe9a989a` |
| Patched | `b82a5b6f6cfe4e7ef416bb039ae986b348cea9e678978b17107b53bd3d562137` |

18.4.0.48 x64, 2,669,040 bytes:

| State | SHA-256 |
|---|---|
| Original | `3643982a58b21712add1b4c806412c48fec54b7ded78ec4e782e5bb8480cae2b` |
| Patched | `ab83d2421a41382b2a2ababf06eda9d98d3c4b833d148bf41fce91b5d40fe8a5` |

## Patch

Three branches skip startup purchase reminders, startup discount offers, and purchase reminders on GUI redisplay. Six bytes change.

| File offset | Original | Replacement |
|---|---|---|
| `0xDF00C` | `74 4D` | `EB 4D` |
| `0xE2532` | `0F 85 D9 00 00 00` | `E9 DA 00 00 00 90` |
| `0xE2618` | `75 38` | `EB 38` |

18.4.0.48:

| Route | File offset | Original | Replacement | Target RVA |
|---|---|---|---|---|
| GUI redisplay | `0xE168C` | `74 4D` | `EB 4D` | `0xE22DB` |
| Startup offer | `0xE4BF2` | `0F 85 D9 00 00 00` | `E9 DA 00 00 00 90` | `0xE58D1` |
| Startup reminder | `0xE4CD8` | `75 38` | `EB 38` | `0xE5912` |

These sites are instruction boundaries in executable sections and retain the existing branch targets. Resource `0x291` identifies the purchase reminder; dialog `0x13BF` identifies the discount offer. The three routes retain the corresponding control flow from 18.3.0.34. The host executable matches the signed file extracted from the official installer.

The shared predicate, generic dialog function, and core engine are unchanged. Explicit `/nag` invocation is not patched. This does not unlock Pro features. The modified signature reports `HashMismatch`.

## File operations

Apply stages and verifies the payload before replacing the target and retaining the original backup. Restore requires the known patched target and verified original backup. Updated targets cannot be downgraded using an old backup.

An existing backup is replaceable only when its hash matches a registered original from a strictly older version. Same-version, newer, patched, and unknown backups are refused. The older backup is moved to a unique `.old.tmp` file during Apply and deleted after successful verification. Caught failures restore the prior target and backup; incomplete recovery preserves both backups and temporary files and blocks automatic restart.

Operations use a directory lock and Windows file replacement. Caught failures attempt rollback; unexpected contents stop recovery. On incomplete recovery, preserve the backup and `ProcessLasso-NoNag-*.tmp` files. Recover from a verified installer or VM checkpoint if necessary.

## Process handling

Only the selected installation's GUI is closed. Another Windows session blocks the operation. After an eight-second graceful-exit attempt, force-close requires confirmation. The core engine is not stopped.

The elevated worker returns an exit code to the menu: 0 = success, 1 = failure, 10 = success and restart, 11 = recovered failure and restart. The encoded-command wrapper forwards the code explicitly. The menu verifies the resulting file state before restarting under its own privilege level.

This PowerShell implementation is separate from the referenced project; patch locations were derived from per-version analysis. Upstream Python code and vendor binaries are not included.
