[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$InstallerPath,
    [string]$MetadataPath,
    [string]$SevenZipPath = 'C:\Program Files\7-Zip\7z.exe',
    [switch]$Publish,
    [switch]$PublishOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Upstream.psm1') -Force
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist\upstream' }
$null = New-Item -ItemType Directory -Force $OutputDirectory
$reportPath = Join-Path $OutputDirectory 'report.json'
if (-not $PublishOnly) {
$work = Join-Path $OutputDirectory ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $work
$report = @{ Status = 'error'; Version = ''; ExecutableHash = ''; InstallerHash = ''; Reason = ''; ErrorKey = ''; CheckedAt = [DateTime]::UtcNow.ToString('o') }
$stage = 'metadata'
try {
    $html = if ($MetadataPath) { [IO.File]::ReadAllText($MetadataPath) } else { (Invoke-WebRequest 'https://bitsum.com/download-process-lasso/' -UseBasicParsing -TimeoutSec 60).Content }
    $release = Get-UpstreamRelease $html
    $report.Version = $release.Version
    $stage = 'download'
    $installer = if ($InstallerPath) { [IO.Path]::GetFullPath($InstallerPath) } else { Join-Path $work 'setup.exe' }
    if (-not $InstallerPath) { Invoke-WebRequest $release.Url -UseBasicParsing -TimeoutSec 120 -OutFile $installer }
    $stage = 'installer-verification'
    $report.InstallerHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($report.InstallerHash -cne $release.InstallerHash) { throw 'Installer checksum differs from official metadata.' }
    Assert-BitsumSignature $installer
    $stage = 'extraction'
    & $SevenZipPath e $installer 'ProcessLasso.exe' "-o$work" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Extraction failed.' }
    $exe = Join-Path $work 'ProcessLasso.exe'
    $stage = 'executable-verification'
    Assert-BitsumSignature $exe
    $data = [IO.File]::ReadAllBytes($exe)
    if ($data.Length -lt 256 -or $data[0] -ne 0x4D -or $data[1] -ne 0x5A) { throw 'Invalid executable.' }
    $pe = [BitConverter]::ToInt32($data, 0x3C)
    if ($pe -lt 0 -or $pe + 26 -gt $data.Length -or [BitConverter]::ToUInt32($data, $pe) -ne 0x4550 -or [BitConverter]::ToUInt16($data, $pe + 4) -ne 0x8664 -or [BitConverter]::ToUInt16($data, $pe + 24) -ne 0x20B) { throw 'Expected x64 PE executable.' }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    $version = '{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart
    if ($version -cne $release.Version) { throw 'Executable version differs from official metadata.' }
    $stage = 'static-check'
    $result = Get-StaticResult $data (Join-Path $root 'src\NoNag.psm1')
    foreach ($key in $result.Keys) { $report[$key] = $result[$key] }
    if ($report.Status -eq 'pass') {
        $stage = 'transaction-test'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Test-NoNag.ps1') -FixturePath $exe
        if ($LASTEXITCODE -ne 0) { throw 'Fixture transaction tests failed.' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Test-WorkerExitCodes.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Worker tests failed.' }
    }
} catch {
    $report.Status = 'error'
    $report.ErrorKey = $stage
    $report.Reason = "Check failed at stage: $stage."
}
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 10))
$summary = "## Upstream static check`n`nStatus: $($report.Status)`n`nVersion: $($report.Version)`n`n$($report.Reason)`n`nExecutable SHA-256: $($report.ExecutableHash)`n"
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary }
Write-Output $summary
} else {
    $report = [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
}
$failed = $report.Status -eq 'error'
if ($Publish) {
    $statePath = Join-Path $root '.github\upstream-state.json'
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $stage = 'notification'
    try {
        foreach ($event in (Get-NotificationPlan $state $report)) {
            $webhook = $env:DISCORD_WEBHOOK_URL
            if (-not $webhook -or $webhook -notmatch '^https://(?:discord\.com|discordapp\.com)/api/webhooks/\d+/[A-Za-z0-9_-]+$') { throw 'Webhook secret missing or invalid.' }
            $label = switch ($event.Kind) { 'review' { 'Analysis required' }; 'error' { 'Check error' }; 'recovery' { 'Check recovered' } }
            $runUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
            $content = "Process Lasso NoNag: $label`nVersion: $($report.Version)`n$($report.Reason)`n$runUrl"
            $payload = @{ content = $content; allowed_mentions = @{ parse = @() } } | ConvertTo-Json -Depth 5
            Send-CheckNotification $state $event {
                Invoke-WebRequest -Uri $webhook -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -UseBasicParsing -TimeoutSec 30
            }.GetNewClosure()
        }
        $stage = 'readme-update'
        if ($report.Status -eq 'pass') {
            $readme = Join-Path $root 'README.md'
            $text = [IO.File]::ReadAllText($readme)
            $updated = Set-StaticReadme $text $report.Version
            if ($updated -cne $text) { [IO.File]::WriteAllText($readme, $updated, [Text.UTF8Encoding]::new($false)) }
        }
    } catch {
        Write-Warning "Publishing failed at stage: $stage. No secret details are logged."
        $failed = $true
    } finally {
        $json = ($state | ConvertTo-Json -Depth 5) + "`n"
        if ([IO.File]::ReadAllText($statePath) -cne $json) { [IO.File]::WriteAllText($statePath, $json, [Text.UTF8Encoding]::new($false)) }
    }
}
if ($failed) { exit 1 }
exit 0
