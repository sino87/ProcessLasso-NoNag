[CmdletBinding()]
param(
    [string]$Installation,
    [ValidateSet('Menu','Apply','Restore')][string]$Action = 'Menu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NoNag.psm1') -Force

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Action -ne 'Menu') {
    $code = 1
    try {
        if (-not (Test-Administrator)) { throw 'Administrator privileges are required for file changes.' }
        if (-not $Installation) { throw 'An installation path is required.' }
        $result = Invoke-NoNagChange -Directory $Installation -Action $Action
        Write-Host $result.Message
        if ($result.Success) { $code = 0 }
        if ($result.Restart) { $code = if ($result.Success) { 10 } else { 11 } }
    } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
    $null = Read-Host 'Press Enter to return to the menu'
    exit $code
}

if (-not $Installation) {
    $detected = @(Find-NoNagInstallation)
    if ($detected.Count -eq 1) { $Installation = $detected[0] }
}
while ($true) {
    Write-Host "`nProcess Lasso NoNag" -ForegroundColor Cyan
    Write-Host 'Accepts registered x64 executable hashes. See docs/TECHNICAL.md.'
    if (-not $Installation) {
        $Installation = ([string](Read-Host 'Installation folder (blank to exit)')).Trim().Trim('"')
        if (-not $Installation) { break }
    }
    try {
        $state = Get-NoNagState $Installation
        $Installation = $state.Directory
        Write-Host "Installation: $Installation"
        Write-Host "Status:       $($state.Status)"
        if ($state.Profile) { Write-Host "Version:      $($state.Profile.Version) x64" }
        Write-Host '[1] Apply patch'
        Write-Host '[2] Restore original'
        Write-Host '[3] Change installation folder'
        Write-Host '[0] Exit'
        $choice = Read-Host 'Select an option'
        if ($choice -eq '0') { break }
        if ($choice -eq '3') { $Installation = ''; continue }
        if ($choice -notin @('1','2')) { continue }
        $operation = if ($choice -eq '1') { 'Apply' } else { 'Restore' }
        if (($choice -eq '1' -and -not $state.CanApply) -or ($choice -eq '2' -and -not $state.CanRestore)) {
            Write-Host "Unavailable: $($state.Status)." -ForegroundColor Yellow
            continue
        }
        if ($choice -eq '1') { Write-Host 'This modifies the GUI executable and invalidates its digital signature.' }
        if ($choice -eq '1' -and -not $state.Profile.VmValidated) { Write-Host 'This build has passed static checks; VM validation is pending.' -ForegroundColor Yellow }
        if ($choice -eq '1' -and $state.ReplaceOldBackup) { Write-Host 'The verified older backup will be replaced with the current original.' }
        Write-Host 'Save any pending GUI changes. Do not run an updater during this operation.'
        if ((Read-Host "$operation on this installation? [y/N]") -cnotmatch '^[yY]$') { continue }
        $encoded = New-NoNagWorkerCommand -ScriptPath $PSCommandPath -Action $operation -Installation $Installation
        $shellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            $shellPath = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        }
        $child = Start-Process -FilePath $shellPath -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -Verb RunAs -Wait -PassThru
        if ($child.ExitCode -in @(10,11)) {
            $verified = Get-NoNagState $Installation
            $expectedState = if ($child.ExitCode -eq 10) { if ($operation -eq 'Apply') { 'Patched' } else { 'Original' } } else { $state.Status }
            if ($verified.Status -eq $expectedState) {
                try {
                    Start-Process -FilePath $verified.Target -WorkingDirectory $Installation
                    Write-Host 'Process Lasso restarted.'
                } catch { Write-Host 'File operation finished, but automatic restart failed. Start Process Lasso manually.' -ForegroundColor Yellow }
            } else { Write-Host 'Installation changed again. Automatic restart skipped.' -ForegroundColor Yellow }
        }
        if ($child.ExitCode -notin @(0,10)) { Write-Host 'Operation did not complete successfully. Review the status before retrying.' -ForegroundColor Yellow }
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        $null = Read-Host 'Press Enter to continue'
        $Installation = ''
    }
}
