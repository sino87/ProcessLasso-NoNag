Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '../src/NoNag.psm1') -Force -PassThru
$root = Join-Path ([IO.Path]::GetTempPath()) ('nonag-transactions-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$original = [Text.Encoding]::UTF8.GetBytes('original current')
$patched = [Text.Encoding]::UTF8.GetBytes('legacy patched')
$older = [Text.Encoding]::UTF8.GetBytes('original older')
$preview = [Text.Encoding]::UTF8.GetBytes('own preview dll')
$currentDll = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../bin/version.dll'))
$originalHash = & $module { param($b) Get-DataHash $b } $original
$patchedHash = & $module { param($b) Get-DataHash $b } $patched
$olderHash = & $module { param($b) Get-DataHash $b } $older
$previewHash = & $module { param($b) Get-DataHash $b } $preview
$dllHash = & $module { param($b) Get-DataHash $b } $currentDll
& $module {
    param($a,$b,$c,$d)
    $script:Known.LegacyExecutables[1].OriginalHash=$a
    $script:Known.LegacyExecutables[1].PatchedHash=$b
    $script:Known.LegacyExecutables[0].OriginalHash=$c
    $script:Known.DllHashes=@($d)
    $script:TestOfficialHash=$a
    function script:Get-OfficialVersion([string]$Path) {
        if ((Get-PathHash $Path) -ceq $script:TestOfficialHash) { return '18.4.0.48' }
        throw 'A valid Bitsum signature is required.'
    }
} $originalHash $patchedHash $olderHash $previewHash
$script:count=0
function Assert($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Pass([string]$Name) { ++$script:count; Write-Host "PASS $Name" }
function Reset-Mocks {
    & $module {
        $script:Calls=0; $script:FailAt=0; $script:After=$false; $script:RecoveryFail=$false; $script:MissingTarget=$false
        function script:Stop-TargetGui { param($Target) return $false }
        function script:Get-TargetGui { param($Target) }
        function script:Replace-NoNagFile([string]$Source,[string]$Target,[string]$Backup) {
            ++$script:Calls
            if ($script:Calls -eq $script:FailAt -and $script:MissingTarget) { [IO.File]::Move($Target,$Backup); throw 'Replacement stopped after moving original' }
            if ($script:Calls -eq $script:FailAt -and -not $script:After) { throw 'Injected replace failure' }
            if ($script:RecoveryFail -and $script:Calls -gt $script:FailAt) { throw 'Injected recovery failure' }
            if ($Backup) { [IO.File]::Replace($Source,$Target,$Backup) } else { [IO.File]::Replace($Source,$Target,$null) }
            if ($script:Calls -eq $script:FailAt -and $script:After) { throw 'Injected partial replace failure' }
        }
        function script:Move-NoNagFile([string]$Source,[string]$Target) {
            ++$script:Calls
            if ($script:Calls -eq $script:FailAt -and -not $script:After) { throw 'Injected move failure' }
            if ($script:RecoveryFail -and $script:Calls -gt $script:FailAt) { throw 'Injected recovery failure' }
            [IO.File]::Move($Source,$Target)
            if ($script:Calls -eq $script:FailAt -and $script:After) { throw 'Injected partial move failure' }
        }
    }
}
function New-Case([string]$Name,[switch]$Legacy,[switch]$PreviewDll) {
    Reset-Mocks
    $dir=Join-Path $root $Name
    $null=[IO.Directory]::CreateDirectory($dir)
    $data=if ($Legacy) { $patched } else { $original }
    [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso.exe'),$data)
    if ($Legacy) { [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso-Original.exe'),$original) }
    if ($PreviewDll) { [IO.File]::WriteAllBytes((Join-Path $dir 'version.dll'),$preview) }
    return $dir
}
function Snapshot([string]$Dir) {
    $s=Get-NoNagState $Dir
    return "$($s.Hash)|$($s.BackupHash)|$($s.DllHash)"
}
function Rejected([scriptblock]$Run) {
    $failed=$false
    try { $r=& $Run; $failed=$null -ne $r -and -not $r.Success } catch { $failed=$true }
    Assert $failed 'Operation should have failed'
}
try {
    $dir=New-Case "round trip ' quotes and spaces"
    $r=Invoke-NoNagChange $dir Enable
    Assert ($r.Success -and -not $r.Restart) $r.Message
    $s=Get-NoNagState $dir
    Assert ($s.Status -ceq 'Enabled' -and $s.Hash -ceq $originalHash -and $s.DllHash -ceq $dllHash) 'Enable changed the executable or wrong DLL'
    $r=Invoke-NoNagChange $dir Disable
    Assert ($r.Success -and (Get-NoNagState $dir).Status -ceq 'Disabled') $r.Message
    Assert (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 1) 'Recovery files remain'
    Pass 'Enable and Disable preserve original executable'
    foreach ($action in @('Enable','Disable')) {
        $dir=New-Case "idempotent-$action"
        $null=Invoke-NoNagChange $dir $action
        & $module { function script:Stop-TargetGui { throw 'No-op closed GUI' } }
        $r=Invoke-NoNagChange $dir $action
        Assert ($r.Success -and -not $r.Restart) $r.Message
        Pass "Idempotent $action"
    }
    foreach ($action in @('Enable','Disable')) {
        $dir=New-Case "legacy-$action" -Legacy
        $r=Invoke-NoNagChange $dir $action
        $s=Get-NoNagState $dir
        Assert ($r.Success -and $s.Hash -ceq $originalHash -and -not $s.BackupHash) $r.Message
        Assert ($s.DllHash -ceq $(if ($action -eq 'Enable') { $dllHash } else { '' })) 'Wrong migrated DLL state'
        Pass "Legacy migration $action"
        $dir=New-Case "preview-$action" -PreviewDll
        $r=Invoke-NoNagChange $dir $action
        Assert ($r.Success -and (Get-NoNagState $dir).DllHash -ceq $(if ($action -eq 'Enable') { $dllHash } else { '' })) $r.Message
        Pass "Preview DLL $action"
        $dir=New-Case "old-backup-$action"
        [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso-Original.exe'),$older)
        $r=Invoke-NoNagChange $dir $action
        $s=Get-NoNagState $dir
        Assert ($r.Success -and $s.Hash -ceq $originalHash -and -not $s.BackupHash) 'Older backup must not downgrade current executable'
        Pass "Remove verified stale backup $action"
    }
    foreach ($kind in @('missing-backup','wrong-backup','unknown-dll','unknown-exe','unknown-backup','newer-backup','missing-exe')) {
        $dir=New-Case $kind -Legacy:($kind -in @('missing-backup','wrong-backup'))
        switch ($kind) {
            'missing-backup' { [IO.File]::Delete((Join-Path $dir 'ProcessLasso-Original.exe')) }
            'wrong-backup' { [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso-Original.exe'),$older) }
            'unknown-dll' { [IO.File]::WriteAllText((Join-Path $dir 'version.dll'),'someone else') }
            'unknown-exe' { [IO.File]::WriteAllText((Join-Path $dir 'ProcessLasso.exe'),'modified') }
            'unknown-backup' { [IO.File]::WriteAllText((Join-Path $dir 'ProcessLasso-Original.exe'),'unknown') }
            'newer-backup' {
                [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso-Original.exe'),$older)
                & $module { $script:Known.LegacyExecutables[0].Version='99.0.0.0' }
            }
            'missing-exe' { [IO.File]::Delete((Join-Path $dir 'ProcessLasso.exe')) }
        }
        $before=Snapshot $dir
        foreach ($action in @('Enable','Disable')) { Rejected { Invoke-NoNagChange $dir $action } }
        Assert ((Snapshot $dir) -ceq $before) 'Refused files were changed'
        & $module { $script:Known.LegacyExecutables[0].Version='18.3.0.34' }
        Pass "Refuse $kind"
    }
    foreach ($action in @('Enable','Disable')) {
        $max=if ($action -eq 'Enable') { 3 } else { 2 }
        foreach ($at in 1..$max) {
            foreach ($after in @($false,$true)) {
                $dir=New-Case "failure-$action-$at-$after" -Legacy
                $before=Snapshot $dir
                & $module { param($n,$a) $script:FailAt=$n; $script:After=$a; function script:Stop-TargetGui { param($Target) return $true } } $at $after
                $r=Invoke-NoNagChange $dir $action
                Assert (-not $r.Success -and $r.Restart -and (Snapshot $dir) -ceq $before) $r.Message
                Assert (-not @(Get-ChildItem -LiteralPath $dir -Directory).Count) 'Successful recovery left artifacts'
                Pass "Rollback $action operation $at partial=$after"
            }
        }
    }
    $dir=New-Case 'missing target during replace' -Legacy
    $before=Snapshot $dir
    & $module { $script:FailAt=1; $script:MissingTarget=$true; function script:Stop-TargetGui { return $true } }
    $r=Invoke-NoNagChange $dir Enable
    Assert (-not $r.Success -and $r.Restart -and (Snapshot $dir) -ceq $before) $r.Message
    Pass 'Partial replacement with missing target is recovered'
    $dir=New-Case 'recovery failure' -Legacy
    & $module { $script:FailAt=1; $script:After=$true; $script:RecoveryFail=$true; function script:Stop-TargetGui { return $true } }
    $r=Invoke-NoNagChange $dir Enable
    Assert (-not $r.Success -and -not $r.Restart -and @(Get-ChildItem -LiteralPath $dir -Directory).Count -eq 1) $r.Message
    Pass 'Incomplete recovery keeps files and blocks restart'
    $dir=New-Case 'gui cancellation'
    & $module { function script:Stop-TargetGui { throw 'Cancelled' } }
    $before=Snapshot $dir
    $r=Invoke-NoNagChange $dir Enable
    Assert (-not $r.Success -and -not $r.Restart -and (Snapshot $dir) -ceq $before) $r.Message
    Pass 'GUI cancellation leaves files unchanged'
    $dir=New-Case 'updater race'
    & $module { function script:Stop-TargetGui([string]$Target) { [IO.File]::WriteAllText($Target,'official updater replaced exe'); return $true } }
    $r=Invoke-NoNagChange $dir Enable
    Assert (-not $r.Success -and -not $r.Restart -and -not [IO.File]::Exists((Join-Path $dir 'version.dll'))) $r.Message
    Pass 'Concurrent updater is preserved and restart blocked'
    $dir=New-Case 'concurrent lock'
    $lock=[IO.FileStream]::new((Join-Path $dir 'ProcessLasso-NoNag.lock'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { Rejected { Invoke-NoNagChange $dir Enable } } finally { $lock.Dispose() }
    Pass 'Concurrent operation refused'
    $dir=New-Case 'gui restarted'
    & $module { function script:Get-TargetGui { 'running again' } }
    $r=Invoke-NoNagChange $dir Enable
    Assert (-not $r.Success -and -not [IO.File]::Exists((Join-Path $dir 'version.dll'))) $r.Message
    Pass 'GUI relaunch during operation refused'
    Write-Host "$script:count transaction tests passed."
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
