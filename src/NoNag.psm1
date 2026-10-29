Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Known = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'known-files.json')) | ConvertFrom-Json

function Get-DataHash([byte[]]$Data) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Data)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PathHash([string]$Path) {
    if ([IO.File]::Exists($Path)) { return Get-DataHash ([IO.File]::ReadAllBytes($Path)) }
    if (Test-Path -LiteralPath $Path) { throw "Expected a file: $Path" }
    return ''
}

function Assert-X64File([string]$Path) {
    $data = [IO.File]::ReadAllBytes($Path)
    if ($data.Length -lt 256 -or [BitConverter]::ToUInt16($data,0) -ne 0x5A4D) { throw 'Invalid executable format.' }
    $pe = [BitConverter]::ToInt32($data,0x3C)
    if ($pe -lt 64 -or $pe -gt $data.Length-26 -or [BitConverter]::ToUInt32($data,$pe) -ne 0x4550 -or
        [BitConverter]::ToUInt16($data,$pe+4) -ne 0x8664 -or [BitConverter]::ToUInt16($data,$pe+24) -ne 0x20B) { throw 'An x64 executable is required.' }
}

function Read-NoNagPayload {
    $directory = Join-Path $PSScriptRoot '../bin'
    $manifest = [IO.File]::ReadAllText((Join-Path $directory 'manifest.json')) | ConvertFrom-Json
    $path = Join-Path $directory 'version.dll'
    if ($manifest.Schema -ne 1 -or $manifest.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $manifest.Build -cnotmatch '^[A-Za-z0-9.-]+$' -or (Get-PathHash $path) -cne $manifest.Sha256) { throw 'Distribution DLL verification failed. Extract the complete release ZIP again.' }
    Assert-X64File $path
    [pscustomobject]@{ Path=$path; Hash=$manifest.Sha256; Build=$manifest.Build }
}

function Get-OfficialVersion([string]$Path) {
    Assert-X64File $Path
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'CN=Bitsum Technologies \(Bitsum LLC\)(?:,|$)') { throw 'A valid Bitsum signature is required.' }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    '{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart
}

function Get-NoNagState([string]$Directory) {
    $full = [IO.Path]::GetFullPath($Directory)
    $target = Join-Path $full 'ProcessLasso.exe'
    $backup = Join-Path $full 'ProcessLasso-Original.exe'
    $dll = Join-Path $full 'version.dll'
    $hash = Get-PathHash $target
    $backupHash = Get-PathHash $backup
    $dllHash = Get-PathHash $dll
    $payload = Read-NoNagPayload
    $legacy = @($script:Known.LegacyExecutables | Where-Object { $_.PatchedHash -ceq $hash })
    $legacy = if ($legacy.Count -eq 1) { $legacy[0] } else { $null }
    $version = ''
    $problem = ''
    if (-not $hash) { $problem = 'Executable missing' }
    elseif ($legacy) {
        $version = $legacy.Version
        if ($backupHash -cne $legacy.OriginalHash) { $problem = 'Legacy patch: matching original backup required' }
    } else {
        try { $version = Get-OfficialVersion $target } catch { $problem = $_.Exception.Message }
    }
    if (-not $problem -and -not $legacy -and $backupHash) {
        $knownBackup = @($script:Known.LegacyExecutables | Where-Object { $_.OriginalHash -ceq $backupHash -and [version]$_.Version -le [version]$version })
        if ($knownBackup.Count -ne 1) { $problem = 'Unrecognized or newer backup: inspect it before continuing' }
    }
    $knownDll = -not $dllHash -or $dllHash -ceq $payload.Hash -or $dllHash -cin $script:Known.DllHashes
    if (-not $knownDll) { $problem = 'Unrecognized version.dll: it will not be replaced or removed' }
    $status = if ($problem) { $problem } elseif ($legacy) { 'Legacy EXE patch; original will be restored' }
              elseif ($dllHash -ceq $payload.Hash) { 'Enabled' } elseif ($dllHash) { 'Enabled; DLL update available' } else { 'Disabled' }
    [pscustomobject]@{
        Directory=$full; Target=$target; Backup=$backup; Dll=$dll; Hash=$hash; BackupHash=$backupHash; DllHash=$dllHash
        Version=$version; Legacy=$legacy; Payload=$payload; Status=$status; CanEnable=(-not $problem); CanDisable=(-not $problem)
    }
}

function Find-NoNagInstallation {
    $paths = @()
    foreach ($base in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $paths += Join-Path $base 'Process Lasso' }
    }
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty $key -ErrorAction SilentlyContinue)) {
            if ($entry.PSObject.Properties['DisplayName'] -and $entry.DisplayName -like '*Process Lasso*' -and $entry.PSObject.Properties['InstallLocation'] -and $entry.InstallLocation) { $paths += $entry.InstallLocation }
        }
    }
    @($paths | Select-Object -Unique | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'ProcessLasso.exe') -PathType Leaf })
}

function Get-TargetGui([string]$Target) {
    foreach ($process in @(Get-Process -Name ProcessLasso -ErrorAction SilentlyContinue)) {
        try {
            $path = $process.MainModule.FileName
            if (-not $path) { throw 'Executable path unavailable.' }
        } catch {
            if ($process.HasExited) { continue }
            throw "Cannot identify ProcessLasso PID $($process.Id). No process will be force-closed."
        }
        if ([string]::Equals($path, $Target, [StringComparison]::OrdinalIgnoreCase)) {
            if ($process.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId) { throw 'Process Lasso is running in another Windows session. Close it there before continuing.' }
            $process
        }
    }
}

function Stop-TargetGui([string]$Target) {
    $processes = @(Get-TargetGui $Target)
    if ($processes.Count -eq 0) { return $false }
    Write-Host 'Closing Process Lasso...'
    foreach ($process in $processes) { if (-not $process.HasExited) { $null = $process.CloseMainWindow() } }
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $remaining = @($processes | Where-Object { -not $_.HasExited })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($remaining.Count -gt 0) {
        if ((Read-Host 'Process Lasso did not exit. Force close it? [y/N]') -cnotmatch '^[yY]$') { throw 'Cancelled. Files were not changed.' }
        foreach ($process in $remaining) {
            if (-not $process.HasExited) { $process.Kill(); if (-not $process.WaitForExit(5000)) { throw 'Process Lasso is still running.' } }
        }
    }
    if (@(Get-TargetGui $Target).Count -gt 0) { throw 'Process Lasso restarted itself. Close it and try again.' }
    return $true
}

function Assert-Unlinked([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked installation paths are not supported.' }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Assert-NoNagTarget([string]$Path, [string]$ExpectedHash) {
    if ((Get-PathHash $Path) -cne $ExpectedHash) { throw "File changed or verification failed: $Path" }
}

function Replace-NoNagFile([string]$Source, [string]$Target, [string]$Backup) {
    [IO.File]::Replace($Source,$Target,$Backup)
}
function Move-NoNagFile([string]$Source, [string]$Target) { [IO.File]::Move($Source, $Target) }

function Invoke-NoNagChange {
    param([string]$Directory, [ValidateSet('Enable','Disable')][string]$Action)
    $state = Get-NoNagState $Directory
    if (-not $state.CanEnable -or -not $state.CanDisable) { throw "Cannot continue: $($state.Status). No files were changed." }
    foreach ($path in @($state.Directory,$state.Target,$state.Backup,$state.Dll,$state.Payload.Path)) { Assert-Unlinked $path }
    $lockPath = Join-Path $state.Directory 'ProcessLasso-NoNag.lock'
    Assert-Unlinked $lockPath
    $lock = [IO.FileStream]::new($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose)
    $work = Join-Path $state.Directory ('ProcessLasso-NoNag-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $journal = [Collections.Generic.List[object]]::new()
    $before = [ordered]@{}
    $before[$state.Target]=$state.Hash; $before[$state.Backup]=$state.BackupHash; $before[$state.Dll]=$state.DllHash
    $expected = [ordered]@{}
    foreach ($path in $before.Keys) { $expected[$path]=$before[$path] }
    $wasRunning=$false; $success=$false; $restartSafe=$false; $message=''
    try {
        $plan = [ordered]@{}
        if ($state.Legacy) { $plan[$state.Target]=[pscustomobject]@{ Data=[IO.File]::ReadAllBytes($state.Backup); Hash=$state.Legacy.OriginalHash } }
        $desiredDll = if ($Action -eq 'Enable') { $state.Payload.Hash } else { '' }
        if ($state.DllHash -cne $desiredDll) { $plan[$state.Dll] = if ($desiredDll) { [pscustomobject]@{ Data=[IO.File]::ReadAllBytes($state.Payload.Path); Hash=$desiredDll } } else { $null } }
        if ($state.BackupHash) { $plan[$state.Backup]=$null }
        foreach ($path in $before.Keys) { Assert-NoNagTarget $path $before[$path] }
        Assert-NoNagTarget $state.Payload.Path $state.Payload.Hash
        if ($plan.Count) {
            $null = [IO.Directory]::CreateDirectory($work)
            $wasRunning = Stop-TargetGui $state.Target
        }
        foreach ($path in $plan.Keys) {
            foreach ($check in $expected.Keys) { Assert-NoNagTarget $check $expected[$check] }
            if (@(Get-TargetGui $state.Target).Count) { throw 'Process Lasso restarted during the operation.' }
            $stage = Join-Path $work ($journal.Count.ToString() + '.new')
            $undo = Join-Path $work ($journal.Count.ToString() + '.old')
            $after = ''
            if ($null -ne $plan[$path]) {
                $data = [byte[]]$plan[$path].Data
                $stream = [IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try { $stream.Write($data,0,$data.Length); $stream.Flush($true) } finally { $stream.Dispose() }
                $after = $plan[$path].Hash
                Assert-NoNagTarget $stage $after
            }
            $journal.Add([pscustomobject]@{ Path=$path; Before=$before[$path]; After=$after; Undo=$undo })
            if (-not $after) { Move-NoNagFile $path $undo }
            elseif ($before[$path]) { Replace-NoNagFile $stage $path $undo }
            else { Move-NoNagFile $stage $path }
            $expected[$path]=$after
            Assert-NoNagTarget $path $after
        }
        foreach ($path in $expected.Keys) { Assert-NoNagTarget $path $expected[$path] }
        $success=$true; $restartSafe=$true
        $message = if ($Action -eq 'Enable') { 'NoNag enabled.' } else { 'NoNag disabled.' }
        if (-not $plan.Count) { $message = 'Already ' + $Action.ToLowerInvariant() + 'd. No files changed.' }
    } catch {
        $message = $_.Exception.Message
        try {
            for ($i=$journal.Count-1; $i -ge 0; $i--) {
                $item = $journal[$i]
                $current = Get-PathHash $item.Path
                if ($current -ceq $item.Before) { continue }
                if (-not $current -and $item.Before) {
                    Assert-NoNagTarget $item.Undo $item.Before
                    Move-NoNagFile $item.Undo $item.Path
                    continue
                }
                if ($current -cne $item.After) { throw 'Unexpected file contents; automatic recovery stopped.' }
                if ($item.Before) {
                    Assert-NoNagTarget $item.Undo $item.Before
                    if ($current) { Replace-NoNagFile $item.Undo $item.Path ($item.Undo + '.replaced') } else { Move-NoNagFile $item.Undo $item.Path }
                } else { [IO.File]::Delete($item.Path) }
            }
            foreach ($path in $before.Keys) { Assert-NoNagTarget $path $before[$path] }
            $restartSafe=$true
            $message += ' Previous state preserved or restored.'
        } catch { $message += " Recovery incomplete: $($_.Exception.Message) Preserve recovery files in $work" }
    } finally {
        if (($success -or $restartSafe) -and [IO.Directory]::Exists($work)) {
            try { [IO.Directory]::Delete($work,$true) } catch { $message += " Recovery files remain in $work" }
        }
        $lock.Dispose()
    }
    [pscustomobject]@{ Success=$success; Restart=($wasRunning -and $restartSafe); Message=$message }
}

function New-NoNagWorkerCommand {
    param([string]$ScriptPath, [ValidateSet('Enable','Disable')][string]$Action, [string]$Installation)
    $scriptLiteral=$ScriptPath.Replace("'", "''")
    $pathLiteral=$Installation.Replace("'", "''")
    $command="`$ErrorActionPreference = 'Stop'; & '$scriptLiteral' -Action '$Action' -Installation '$pathLiteral'; exit `$LASTEXITCODE"
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

Export-ModuleMember -Function Get-NoNagState, Find-NoNagInstallation, Invoke-NoNagChange, New-NoNagWorkerCommand
