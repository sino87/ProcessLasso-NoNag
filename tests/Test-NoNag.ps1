param([string]$FixturePath, [string]$OlderFixturePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '..\src\NoNag.psm1') -Force -PassThru
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('NoNag-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$original = New-Object byte[] 1000000
$original[0xDF00C] = 0x74; $original[0xDF00D] = 0x4D
[Array]::Copy([byte[]](0x0F,0x85,0xD9,0,0,0), 0, $original, 0xE2532, 6)
$original[0xE2618] = 0x75; $original[0xE2619] = 0x38
$patched = [byte[]]$original.Clone()
$patched[0xDF00C] = 0xEB
[Array]::Copy([byte[]](0xE9,0xDA,0,0,0,0x90), 0, $patched, 0xE2532, 6)
$patched[0xE2618] = 0xEB
if ($FixturePath) {
    $original = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $FixturePath).ProviderPath)
    $patched = & $module { param($data) New-PatchedData $data } $original
} else {
    & $module { param($a,$b) $script:OriginalHash = Get-DataHash $a; $script:PatchedHash = Get-DataHash $b } $original $patched
}
$fixtureHash = & $module { param($data) Get-DataHash $data } $original
$profile = & $module { param($hash) Get-NoNagProfiles | Where-Object { $_.OriginalHash -eq $hash } } $fixtureHash
$originalHash = $profile.OriginalHash
$patchedHash = $profile.PatchedHash
$script:count = 0

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Reset-Mocks {
    & $module {
        $script:ReplaceCount = 0
        function script:Stop-TargetGui { param($Target) return $false }
        function script:Replace-NoNagFile { param($Source,$Target,$Backup) [IO.File]::Replace($Source,$Target,$Backup) }
    }
}

function New-Case([string]$Name) {
    Reset-Mocks
    $folder = Join-Path $testRoot $Name
    $null = New-Item -ItemType Directory -Path $folder
    [IO.File]::WriteAllBytes((Join-Path $folder 'ProcessLasso.exe'), $original)
    return $folder
}

function Assert-Rejected([scriptblock]$Operation) {
    $rejected = $false
    try { $result = & $Operation; $rejected = $null -ne $result -and -not $result.Success }
    catch { $rejected = $true }
    Assert-True $rejected 'Operation should be rejected'
}

function Pass([string]$Name) { $script:count++; Write-Host "PASS $Name" }

try {
    $dir = New-Case "round trip ' with spaces"
    $result = Invoke-NoNagChange $dir Apply
    Assert-True $result.Success $result.Message
    Assert-True (-not $result.Restart) 'Closed GUI must stay closed'
    $state = Get-NoNagState $dir
    Assert-True ($state.Hash -eq $patchedHash -and $state.BackupHash -eq $originalHash) 'Apply hashes'
    Assert-True (@(Get-ChildItem $dir).Count -eq 2) 'Apply temporary files removed'
    $result = Invoke-NoNagChange $dir Restore
    Assert-True $result.Success $result.Message
    $state = Get-NoNagState $dir
    Assert-True ($state.Hash -eq $originalHash -and $state.BackupHash -eq '') 'Restore hashes'
    Assert-True (@(Get-ChildItem $dir).Count -eq 1) 'Restore cleanup'
    Pass 'Apply and restore exact bytes'

    $dir = New-Case 'existing backup'
    [IO.File]::WriteAllText((Join-Path $dir 'ProcessLasso-Original.exe'), 'do not overwrite')
    Assert-Rejected { Invoke-NoNagChange $dir Apply }
    Assert-True ([IO.File]::ReadAllText((Join-Path $dir 'ProcessLasso-Original.exe')) -eq 'do not overwrite') 'Backup preserved'
    Assert-True ((Get-NoNagState $dir).Hash -eq $originalHash) 'Target unchanged'
    Pass 'Existing backup refused'

    $dir = New-Case 'already patched'
    $null = Invoke-NoNagChange $dir Apply
    Assert-Rejected { Invoke-NoNagChange $dir Apply }
    Pass 'Double application refused'

    $dir = New-Case 'updated exe'
    $null = Invoke-NoNagChange $dir Apply
    [IO.File]::WriteAllText((Join-Path $dir 'ProcessLasso.exe'), 'new version')
    Assert-Rejected { Invoke-NoNagChange $dir Restore }
    Assert-True ([IO.File]::ReadAllText((Join-Path $dir 'ProcessLasso.exe')) -eq 'new version') 'Updated executable preserved'
    Assert-True ((Get-NoNagState $dir).BackupHash -eq $originalHash) 'Old backup preserved'
    Pass 'Update cannot be downgraded by restore'

    $dir = New-Case 'missing backup'
    [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso.exe'), $patched)
    Assert-Rejected { Invoke-NoNagChange $dir Restore }
    Pass 'Restore without backup refused'

    $dir = New-Case 'corrupt backup'
    [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso.exe'), $patched)
    [IO.File]::WriteAllText((Join-Path $dir 'ProcessLasso-Original.exe'), 'bad backup')
    Assert-Rejected { Invoke-NoNagChange $dir Restore }
    Pass 'Corrupt backup refused'

    $dir = New-Case 'gui cancel'
    & $module { function script:Stop-TargetGui { param($Target) throw 'User cancelled force close.' } }
    Assert-Rejected { Invoke-NoNagChange $dir Apply }
    Assert-True ((Get-NoNagState $dir).Hash -eq $originalHash) 'Cancellation preserved executable'
    Assert-True (@(Get-ChildItem $dir).Count -eq 1) 'Cancellation cleaned staging file'
    Pass 'GUI-close cancellation leaves files unchanged'

    $dir = New-Case 'concurrent updater'
    & $module { function script:Stop-TargetGui { param($Target) [IO.File]::WriteAllText($Target,'updated meanwhile'); return $false } }
    Assert-Rejected { Invoke-NoNagChange $dir Apply }
    Assert-True ([IO.File]::ReadAllText((Join-Path $dir 'ProcessLasso.exe')) -eq 'updated meanwhile') 'Concurrent update not overwritten'
    Pass 'Change during preparation detected'

    foreach ($action in @('Apply','Restore')) {
        $dir = New-Case "rollback $action"
        if ($action -eq 'Restore') { $null = Invoke-NoNagChange $dir Apply }
        $before = Get-NoNagState $dir
        & $module {
            function script:Stop-TargetGui { param($Target) return $true }
            function script:Replace-NoNagFile {
                param($Source,$Target,$Backup)
                [IO.File]::Replace($Source,$Target,$Backup)
                $script:ReplaceCount++
                if ($script:ReplaceCount -eq 1) { throw 'Injected failure after replacement.' }
            }
        }
        $result = Invoke-NoNagChange $dir $action
        Assert-True (-not $result.Success -and $result.Restart) 'Failure permits restart after recovery'
        $after = Get-NoNagState $dir
        Assert-True ($after.Hash -eq $before.Hash -and $after.BackupHash -eq $before.BackupHash) 'Complete rollback'
        Pass "$action rollback after replacement"
    }

    foreach ($action in @('Apply','Restore')) {
        $dir = New-Case "partial replacement $action"
        if ($action -eq 'Restore') { $null = Invoke-NoNagChange $dir Apply }
        $before = Get-NoNagState $dir
        & $module {
            function script:Replace-NoNagFile {
                param($Source,$Target,$Backup)
                [IO.File]::Move($Target,$Backup)
                throw 'Injected failure with target moved but replacement not installed.'
            }
        }
        $result = Invoke-NoNagChange $dir $action
        Assert-True (-not $result.Success) 'Partial replacement should fail'
        $after = Get-NoNagState $dir
        Assert-True ($after.Hash -eq $before.Hash -and $after.BackupHash -eq $before.BackupHash) 'Partial replacement rollback'
        Pass "$action recovers when target is temporarily absent"
    }

    $dir = New-Case 'failed recovery'
    & $module {
        function script:Stop-TargetGui { param($Target) return $true }
        function script:Replace-NoNagFile {
            param($Source,$Target,$Backup)
            $script:ReplaceCount++
            if ($script:ReplaceCount -eq 1) { [IO.File]::Replace($Source,$Target,$Backup) }
            throw 'Injected replacement and recovery failure.'
        }
    }
    $result = Invoke-NoNagChange $dir Apply
    Assert-True (-not $result.Success -and -not $result.Restart) 'Incomplete recovery must not restart'
    Assert-True ($result.Message -like '*Recovery incomplete*') 'Recovery error disclosed'
    Assert-True ((Get-NoNagState $dir).BackupHash -eq $originalHash) 'Recovery failure preserves original backup'
    Pass 'Failed rollback preserves original and blocks restart'

    $dir = New-Case 'locked target'
    $handle = [IO.File]::Open((Join-Path $dir 'ProcessLasso.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Assert-Rejected { Invoke-NoNagChange $dir Apply } } finally { $handle.Dispose() }
    Assert-True ((Get-NoNagState $dir).Hash -eq $originalHash) 'Locked executable preserved'
    Pass 'Locked target refuses replacement'

    $dir = New-Case 'concurrent tool'
    $handle = [IO.File]::Open((Join-Path $dir 'ProcessLasso-NoNag.lock'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-Rejected { Invoke-NoNagChange $dir Apply } } finally { $handle.Dispose() }
    Assert-True ((Get-NoNagState $dir).Hash -eq $originalHash) 'Concurrent tool leaves executable unchanged'
    Pass 'Concurrent operation refused'

    $dir = New-Case 'restart intent'
    & $module { function script:Stop-TargetGui { param($Target) return $true } }
    $result = Invoke-NoNagChange $dir Apply
    Assert-True ($result.Success -and $result.Restart) 'Running GUI should restart'
    Pass 'Running GUI restart intent preserved'
    $older = if ($OlderFixturePath) { [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $OlderFixturePath).ProviderPath) } else { [byte[]]$original.Clone() }
    if (-not $OlderFixturePath) { $older[0] = $older[0] -bxor 1 }
    $olderHash = & $module { param($data) Get-DataHash $data } $older
    if (-not $OlderFixturePath) { & $module {
        param($hash)
        $script:TestProfiles = @(Get-NoNagProfiles) + @(@{ Version = '18.2.0.0'; OriginalHash = $hash; PatchedHash = 'unused'; Patches = @() })
        function script:Get-NoNagProfiles { $script:TestProfiles }
    } $olderHash }
    foreach ($mode in @('success','before','after','partial','failed-recovery','cancel')) {
        $dir = New-Case "older backup $mode"
        [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso-Original.exe'), $older)
        Assert-True ((Get-NoNagState $dir).CanApply) 'Known older original can be replaced'
        & $module {
            param($mode)
            $script:FailureMode = $mode
            function script:Stop-TargetGui {
                param($Target)
                if ($script:FailureMode -eq 'cancel') { throw 'Cancelled.' }
                return $true
            }
            function script:Replace-NoNagFile {
                param($Source,$Target,$Backup)
                $script:ReplaceCount++
                if ($script:FailureMode -eq 'before') { throw 'Before replacement.' }
                if ($script:FailureMode -eq 'partial') { [IO.File]::Move($Target,$Backup); throw 'Partial replacement.' }
                if ($script:FailureMode -eq 'failed-recovery' -and $script:ReplaceCount -gt 1) { throw 'Recovery failed.' }
                [IO.File]::Replace($Source,$Target,$Backup)
                if ($script:ReplaceCount -eq 1 -and $script:FailureMode -in @('after','failed-recovery')) { throw 'After replacement.' }
            }
        } $mode
        $result = Invoke-NoNagChange $dir Apply
        $state = Get-NoNagState $dir
        if ($mode -eq 'success') {
            Assert-True ($result.Success -and $state.Hash -eq $patchedHash -and $state.BackupHash -eq $originalHash) 'New original replaces older backup'
            Assert-True (@(Get-ChildItem $dir).Count -eq 2) 'Older temporary backup removed'
            Reset-Mocks
            $restored = Invoke-NoNagChange $dir Restore
            Assert-True ($restored.Success -and (Get-NoNagState $dir).Hash -eq $originalHash) 'Restore returns new original'
        } elseif ($mode -eq 'failed-recovery') {
            Assert-True (-not $result.Success -and -not $result.Restart -and $state.BackupHash -eq $originalHash) 'Failed recovery preserves new original and blocks restart'
            $held = @(Get-ChildItem $dir -Filter '*.old.tmp')
            Assert-True ($held.Count -eq 1 -and (Get-FileHash $held[0].FullName).Hash.ToLowerInvariant() -eq $olderHash) 'Failed recovery preserves old backup'
        } else {
            Assert-True (-not $result.Success -and $state.Hash -eq $originalHash -and $state.BackupHash -eq $olderHash) 'Failure restores both original files'
            Assert-True (@(Get-ChildItem $dir).Count -eq 2) 'Recovered operation leaves no temporary files'
        }
        Pass "Older backup replacement: $mode"
    }
    $dir = New-Case 'same-version backup'
    [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso-Original.exe'), $original)
    Assert-Rejected { Invoke-NoNagChange $dir Apply }
    Pass 'Same-version backup refused'
    $dir = New-Case 'patched backup'
    [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso-Original.exe'), $patched)
    Assert-Rejected { Invoke-NoNagChange $dir Apply }
    Pass 'Patched backup refused'
    $future = [byte[]]$original.Clone()
    $future[1] = $future[1] -bxor 1
    $futureHash = & $module { param($data) Get-DataHash $data } $future
    & $module {
        param($hash)
        $script:TestProfiles = @(Get-NoNagProfiles) + @(@{ Version = '99.0.0.0'; OriginalHash = $hash; PatchedHash = 'unused-future'; Patches = @() })
        function script:Get-NoNagProfiles { $script:TestProfiles }
    } $futureHash
    $dir = New-Case 'newer backup'
    [IO.File]::WriteAllBytes((Join-Path $dir 'ProcessLasso-Original.exe'), $future)
    Assert-Rejected { Invoke-NoNagChange $dir Apply }
    Pass 'Known newer backup refused'
    Write-Host "$script:count tests passed."
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('NoNag-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    Remove-Module $module
}
