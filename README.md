# Process Lasso NoNag

Remove Process Lasso purchase reminders.

Requires x64 Process Lasso and Windows PowerShell 5.1.

| Check | Last checked version |
|---|---|
| Automated Compatibility Check | - |
| Manual Check | Process Lasso 18.4.0.48 x64 |

## Usage

1. Extract the [Release ZIP](https://github.com/sino87/ProcessLasso-NoNag/releases) and double-click `Start.cmd`.
2. Check the installation folder, then select **Enable** or **Disable**.
3. Confirm the operation and accept the administrator prompt.
4. Press Enter in the result window to return to the menu.

Enable installs `version.dll`; Disable removes it. If the GUI was running, the tool closes and restarts it. Save pending changes first.

## Notes

- Patches from v0.1.1 and earlier are restored automatically using the matching `ProcessLasso-Original.exe`. Keep this backup until migration finishes.
- Unknown DLLs, modified executables and unrecognized backups are refused.
- Do not update Process Lasso during an operation.

Independent of Bitsum.

See [Technical details](docs/TECHNICAL.md) for behavior and compatibility checks.

## References

Inspired by [NoProcessLassoNag](https://github.com/grandprixgp/NoProcessLassoNag).

## License

[MIT License](LICENSE).
