# Process Lasso NoNag

Remove Process Lasso purchase reminders.

| Check | Last checked version |
|---|---|
| Automated static check | Not yet checked |
| Manual test | Process Lasso 18.3.0.34 x64 |

Currently accepts only the verified executable from the manually tested build.

## Usage

1. Extract the [ZIP](https://github.com/tatsuya087/ProcessLasso-NoNag/releases) and double-click `Start.cmd`.
2. Check the installation folder.
3. Select **Apply patch** or **Restore original**.
4. Confirm the operation and accept the administrator prompt.
5. Press Enter in the result window to return to the menu.

The original is saved as `ProcessLasso-Original.exe`. Keep it for restoration.
If the GUI was running, the tool closes and restarts it. Save pending changes first.

Requires Windows PowerShell 5.1. No additional software is needed.

## Notes

- Patching invalidates the executable's digital signature.
- Unsupported or modified executables are refused. Do not update Process Lasso during an operation.
- Existing backups are not overwritten.

Independent of Bitsum. Licensed under [MIT](LICENSE).

See [Technical details](docs/TECHNICAL.md) for supported hashes and patch behavior.

## References

Inspired by [NoProcessLassoNag](https://github.com/grandprixgp/NoProcessLassoNag).
