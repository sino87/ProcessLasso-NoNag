[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$InstallerPath,
    [string]$MetadataPath,
    [string]$SevenZipPath = 'C:\Program Files\7-Zip\7z.exe',
    [string]$PythonPath = 'python',
    [string]$DevelopmentDll
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Upstream.psm1') -Force
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $root 'dist/upstream' }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$work=Join-Path $OutputDirectory ([guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work)
$report=@{ Schema=3; Status='error'; Version=''; ExecutableHash=''; InstallerHash=''; DllHash=''; NoNagRelease='';
    Development=[bool]$DevelopmentDll; Reason=''; ErrorKey=''; CheckerRevision=(Get-CheckerRevision);
    SourceRevision=$env:GITHUB_SHA; CheckedAt=[DateTime]::UtcNow.ToString('o') }
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
    $resource=Join-Path $work 'pl_rsrc_english.dll'
    $stage='executable-verification'
    Assert-BitsumSignature $exe
    Assert-BitsumSignature $resource
    foreach ($path in @($exe,$resource)) {
        $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        $version='{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart
        if ($version -cne $release.Version) { throw 'File version differs from official metadata.' }
    }
    $report.ExecutableHash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    $stage='published-dll'
    if ($DevelopmentDll) {
        $dll=[IO.Path]::GetFullPath($DevelopmentDll)
        $report.NoNagRelease='development'
    } else {
        $payload=& (Join-Path $PSScriptRoot 'Get-PublishedDll.ps1') -Directory (Join-Path $work 'published')
        $dll=$payload.Path
        $report.NoNagRelease=$payload.Release
    }
    $report.DllHash=(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant()
    $stage='compatibility'
    $analysisPath=Join-Path $OutputDirectory 'compatibility.json'
    & $PythonPath (Join-Path $PSScriptRoot 'check_compatibility.py') --exe $exe --resources $resource --dll $dll --build (Join-Path $root 'build') --output $analysisPath
    if ($LASTEXITCODE -ne 0) { throw 'Compatibility checker failed.' }
    $result=[IO.File]::ReadAllText($analysisPath) | ConvertFrom-Json
    foreach ($key in @('Status','Reason','ExecutableHash','DllHash','CheckerRevision','Environment','SourceRevision')) { $report[$key]=$result.$key }
} catch {
    $report.Status='error'; $report.ErrorKey=$stage; $report.Reason="Check failed at stage: $stage."
} finally {
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'report.json'),($report | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    if ([IO.Directory]::Exists($work)) { [IO.Directory]::Delete($work,$true) }
}
$summary="## Upstream compatibility check`n`nStatus: $($report.Status)`n`nProcess Lasso: $($report.Version)`n`nNoNag: $($report.NoNagRelease)`n`n$($report.Reason)`n"
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary }
Write-Output $summary
if ($report.Status -eq 'error') { exit 1 }
exit 0
