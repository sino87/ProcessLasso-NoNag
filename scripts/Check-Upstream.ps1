[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$InstallerPath,
    [string]$MetadataPath,
    [string]$SevenZipPath = 'C:\Program Files\7-Zip\7z.exe',
    [string]$PythonPath = 'python',
    [switch]$SkipAnalysis
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Upstream.psm1') -Force
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist/upstream' }
$null=New-Item -ItemType Directory -Force $OutputDirectory
$work=Join-Path $OutputDirectory ([guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $work
$report=@{ Status='error'; Version=''; ExecutableHash=''; InstallerHash=''; Reason=''; ErrorKey=''; CheckedAt=[DateTime]::UtcNow.ToString('o') }
$stage='metadata'
try {
    $html=if ($MetadataPath) { [IO.File]::ReadAllText($MetadataPath) } else { (Invoke-WebRequest 'https://bitsum.com/download-process-lasso/' -UseBasicParsing -TimeoutSec 60).Content }
    $release=Get-UpstreamRelease $html
    $report.Version=$release.Version
    $stage='download'
    $installer=if ($InstallerPath) { [IO.Path]::GetFullPath($InstallerPath) } else { Join-Path $work 'setup.exe' }
    if (-not $InstallerPath) { Invoke-WebRequest $release.Url -UseBasicParsing -TimeoutSec 120 -OutFile $installer }
    $stage='installer-verification'
    $report.InstallerHash=(Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($report.InstallerHash -cne $release.InstallerHash) { throw 'Installer checksum differs from official metadata.' }
    Assert-BitsumSignature $installer
    $stage='extraction'
    & $SevenZipPath e $installer 'ProcessLasso.exe' 'pl_rsrc_english.dll' "-o$work" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Extraction failed.' }
    $exe=Join-Path $work 'ProcessLasso.exe'
    $stage='executable-verification'
    Assert-BitsumSignature $exe
    $data=[IO.File]::ReadAllBytes($exe)
    if ($data.Length -lt 256 -or $data[0] -ne 0x4D -or $data[1] -ne 0x5A) { throw 'Invalid executable.' }
    $pe=[BitConverter]::ToInt32($data,0x3C)
    if ($pe -lt 0 -or $pe+26 -gt $data.Length -or [BitConverter]::ToUInt32($data,$pe) -ne 0x4550 -or [BitConverter]::ToUInt16($data,$pe+4) -ne 0x8664 -or [BitConverter]::ToUInt16($data,$pe+24) -ne 0x20B) { throw 'Expected x64 PE executable.' }
    $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    $version='{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart
    if ($version -cne $release.Version) { throw 'Executable version differs from official metadata.' }
    $stage='static-check'
    $result=Get-StaticResult $data (Join-Path $root 'src/NoNag.psm1')
    foreach ($key in $result.Keys) { $report[$key]=$result[$key] }
    if ($report.Status -eq 'pass') {
        $stage='transaction-test'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests/Test-NoNag.ps1') -FixturePath $exe
        if ($LASTEXITCODE -ne 0) { throw 'Fixture transaction tests failed.' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests/Test-WorkerExitCodes.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Worker tests failed.' }
    } elseif (-not $SkipAnalysis) {
        $stage='analysis'
        $analysisPath=Join-Path $OutputDirectory 'analysis.json'
        & $PythonPath (Join-Path $PSScriptRoot 'analyze_patch.py') analyze --exe $exe --resources (Join-Path $work 'pl_rsrc_english.dll') --output $analysisPath
        if ($LASTEXITCODE -ne 0) { throw 'Analyzer failed.' }
        $analysis=[IO.File]::ReadAllText($analysisPath) | ConvertFrom-Json
        $report.Analysis=$analysis
        if ($analysis.Status -eq 'candidate') {
            $stage='candidate-validation'
            & (Join-Path $PSScriptRoot 'Prepare-Candidate.ps1') -AnalysisPath $analysisPath -ExecutablePath $exe -OutputDirectory $OutputDirectory
            $report.CandidateValidated=$true
        }
    } else {
        $report.Analysis=@{ Status='inconclusive'; Reason='Analysis skipped by manual request.'; AnalyzerHash=('0'*64) }
    }
} catch {
    $report.Status='error'; $report.ErrorKey=$stage; $report.Reason="Check failed at stage: $stage."
}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'report.json'),($report | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
$summary="## Upstream static check`n`nStatus: $($report.Status)`n`nVersion: $($report.Version)`n`n$($report.Reason)`n`nExecutable SHA-256: $($report.ExecutableHash)`n"
if ($report.ContainsKey('Analysis')) { $summary+="`nAnalysis: $($report.Analysis.Status)`n`n$($report.Analysis.Reason)`n" }
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary }
Write-Output $summary
if ($report.Status -eq 'error') { exit 1 }
exit 0
