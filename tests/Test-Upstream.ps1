Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\Upstream.psm1') -Force
$count = 0
function Assert($Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Output "PASS $Name"
    $script:count++
}
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert $thrown $Name
}
$hash = 'a' * 64
$html = '<tbody id="pl-dl-body-beta"><tr data-arch="x64"><td>99.0.0.0</td></tr></tbody>' +
    '<tbody id="pl-dl-body-stable"><tr data-arch="x86"><td>1.0.0.0</td></tr><tr data-arch="x64"><td>18.4.0.48</td><span data-sha="' + $hash + '"></span><a href="https://dl.bitsum.com/files/processlassosetup64.exe">Download</a></tr></tbody>'
$release = Get-UpstreamRelease $html
Assert ($release.Version -eq '18.4.0.48' -and $release.InstallerHash -eq $hash) 'Stable x64 selected instead of beta or x86'
Assert-Throws { Get-UpstreamRelease ($html.Replace('data-sha=', 'checksum=')) } 'Missing checksum refused'
Assert-Throws { Get-UpstreamRelease ($html.Replace('https://dl.bitsum.com/', 'https://example.com/')) } 'Unofficial download refused'
Assert-Throws { Get-UpstreamRelease ($html.Replace('pl-dl-body-stable', 'changed-layout')) } 'Unknown page layout refused'
$state = [pscustomobject]@{ NotifiedHashes = @(); LastError = '' }
$report = @{ Status = 'review'; ExecutableHash = $hash; ErrorKey = '' }
Assert ((Get-NotificationPlan $state $report).Count -eq 1) 'New executable triggers analysis notification'
$state.NotifiedHashes = @($hash)
Assert ((Get-NotificationPlan $state $report).Count -eq 0) 'Previously notified executable suppressed'
$report.Status = 'error'
$report.ErrorKey = 'download'
Assert ((Get-NotificationPlan $state $report).Count -eq 1) 'New check error triggers notification'
$state.LastError = 'download'
Assert ((Get-NotificationPlan $state $report).Count -eq 0) 'Repeated error suppressed'
$report.ErrorKey = 'extraction'
Assert ((Get-NotificationPlan $state $report).Count -eq 1) 'Different error triggers notification'
$report.Status = 'review'
Assert ((Get-NotificationPlan $state $report)[0].Kind -eq 'recovery') 'Recovery reported even when analysis still required'
$state.NotifiedHashes = @()
Assert ((Get-NotificationPlan $state $report).Count -eq 2) 'Recovery and new analysis both reported'
$event = @{ Kind = 'review'; Key = $hash }
Assert-Throws { Send-CheckNotification $state $event { throw 'Simulated delivery failure' } } 'Failed delivery reported'
Assert ($state.NotifiedHashes.Count -eq 0 -and (Get-NotificationPlan $state $report).Count -eq 2) 'Failed delivery remains eligible for retry'
Send-CheckNotification $state $event { }
Assert ($state.NotifiedHashes.Count -eq 1 -and (Get-NotificationPlan $state $report).Count -eq 1) 'Successful delivery recorded'
Send-CheckNotification $state @{ Kind = 'recovery'; Key = '' } { }
Assert ($state.LastError -eq '' -and (Get-NotificationPlan $state $report).Count -eq 0) 'Successful recovery clears error state'
$readme = "| Automated compatibility check | Not yet implemented |`n| Manual test | Process Lasso 18.3.0.34 x64 |`n"
$updated = Set-StaticReadme $readme '18.4.0.48'
Assert ($updated.Contains('| Automated static check | Process Lasso 18.4.0.48 x64 |') -and $updated.Contains('| Manual test | Process Lasso 18.3.0.34 x64 |')) 'Only automated README row updated'
Assert ((Set-StaticReadme $updated '18.4.0.48') -ceq $updated) 'Same version leaves README unchanged'
Assert-Throws { Set-StaticReadme 'Missing row' '18.4.0.48' } 'Missing README row refused'
$result = Get-StaticResult ([byte[]](0,1,2)) (Join-Path $PSScriptRoot '..\src\NoNag.psm1')
Assert ($result.Status -eq 'review' -and @($result.Sites | Where-Object Matches).Count -eq 0) 'Unknown executable cannot pass'
$data = New-Object byte[] 1000000
$data[0xDF00C] = 0x74; $data[0xDF00D] = 0x4D
[Array]::Copy([byte[]](0x0F,0x85,0xD9,0,0,0), 0, $data, 0xE2532, 6)
$data[0xE2618] = 0x75; $data[0xE2619] = 0x38
$result = Get-StaticResult $data (Join-Path $PSScriptRoot '..\src\NoNag.psm1')
Assert ($result.Status -eq 'review' -and @($result.Sites | Where-Object Matches).Count -eq 3) 'Matching offset bytes cannot approve an unknown hash'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('NoNag-upstream-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory (Join-Path $temp 'scripts')
$null = New-Item -ItemType Directory (Join-Path $temp '.github')
$null = New-Item -ItemType Directory (Join-Path $temp 'dist\upstream')
$secret = $env:DISCORD_WEBHOOK_URL
try {
    $env:DISCORD_WEBHOOK_URL = ''
    foreach ($name in @('Check-Upstream.ps1','Upstream.psm1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\scripts\$name") -Destination (Join-Path $temp "scripts\$name")
    }
    $statePath = Join-Path $temp '.github\upstream-state.json'
    [IO.File]::WriteAllText($statePath, '{"NotifiedHashes":[],"LastError":""}')
    $readmePath = Join-Path $temp 'README.md'
    [IO.File]::WriteAllText($readmePath, $readme)
    $reportPath = Join-Path $temp 'dist\upstream\report.json'
    $report = @{ Status = 'review'; Version = '18.4.0.48'; ExecutableHash = $hash; Reason = 'Requires analysis'; ErrorKey = '' }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temp 'scripts\Check-Upstream.ps1') -Publish -PublishOnly | Out-Null
    Assert ($LASTEXITCODE -eq 1) 'Missing webhook fails publication'
    $saved = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert ($saved.NotifiedHashes.Count -eq 0 -and [IO.File]::ReadAllText($readmePath) -ceq $readme) 'Failed notification preserves state and manual README'
    $report.Status = 'pass'
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temp 'scripts\Check-Upstream.ps1') -Publish -PublishOnly | Out-Null
    Assert ($LASTEXITCODE -eq 0 -and [IO.File]::ReadAllText($readmePath) -ceq $updated) 'Passing report updates README without requiring notification'
} finally {
    $env:DISCORD_WEBHOOK_URL = $secret
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Output "$count upstream tests passed."
exit 0
