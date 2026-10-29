Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root=Join-Path ([IO.Path]::GetTempPath()) ('nonag-package-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $root 'repo'
$releaseDir=Join-Path $root 'release'
$tag='v0.0.0-test'
function Assert($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Rejected([scriptblock]$Run) { $failed=$false; try { & $Run | Out-Null } catch { $failed=$true }; Assert $failed 'Expected package rejection' }
function gh {
    if ($args[0] -eq 'api') { $global:LASTEXITCODE=0; return '{"tag_name":"v0.0.0-test","draft":false,"prerelease":false}' }
    if ($args[0] -ne 'release' -or $args[1] -ne 'download') { throw 'Unexpected GitHub command' }
    $destination=$args[$args.Count-1]
    Copy-Item -LiteralPath (Join-Path $releaseDir "ProcessLasso-NoNag-$tag.zip") -Destination $destination
    Copy-Item -LiteralPath (Join-Path $releaseDir 'SHA256SUMS.txt') -Destination $destination
    $global:LASTEXITCODE=0
}
try {
    foreach ($file in @('Start.cmd','src/CLI.ps1','src/NoNag.psm1','src/known-files.json','bin/version.dll','bin/manifest.json','README.md','docs/TECHNICAL.md','LICENSE','scripts/Build-Release.ps1')) {
        $destination=Join-Path $repo $file
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        Copy-Item -LiteralPath (Join-Path $source $file) -Destination $destination
    }
    $manifestPath=Join-Path $repo 'bin/manifest.json'
    $manifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    $manifest.Build=$tag
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json))
    $archive=& (Join-Path $repo 'scripts/Build-Release.ps1') -Tag $tag -OutputDirectory $releaseDir
    Assert ([IO.File]::Exists($archive)) 'Archive not produced'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($archive)
    try {
        Assert ($zip.Entries.Count -eq 9) 'Unexpected package contents'
        Assert (@($zip.Entries | Where-Object { $_.FullName -match 'ProcessLasso\.exe|tests/|\.cpp|analysis|profiles\.json' }).Count -eq 0) 'Private or obsolete content in archive'
    } finally { $zip.Dispose() }
    Write-Host 'PASS Distribution contains only the nine runtime/documentation files'
    Rejected { & (Join-Path $repo 'scripts/Build-Release.ps1') -Tag $tag -OutputDirectory $releaseDir }
    Write-Host 'PASS Existing archive is not overwritten'
    $payload=& (Join-Path $source 'scripts/Get-PublishedDll.ps1') -Directory (Join-Path $root 'download') -Repository 'owner/repository'
    Assert ($payload.Hash -ceq $manifest.Sha256 -and $payload.Release -ceq $tag) 'Wrong published payload'
    Write-Host 'PASS Published archive, checksum, manifest and DLL verified'
    [IO.File]::WriteAllText((Join-Path $releaseDir 'SHA256SUMS.txt'),('0'*64)+'  '+[IO.Path]::GetFileName($archive))
    Rejected { & (Join-Path $source 'scripts/Get-PublishedDll.ps1') -Directory (Join-Path $root 'bad-download') -Repository 'owner/repository' }
    Write-Host 'PASS Corrupt release checksum refused'
    $manifest.Sha256='0'*64
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json))
    Rejected { & (Join-Path $repo 'scripts/Build-Release.ps1') -Tag $tag -OutputDirectory (Join-Path $root 'bad-release') }
    Write-Host 'PASS Corrupt DLL manifest refused'
    Rejected { & (Join-Path $repo 'scripts/Build-Release.ps1') -Tag 'bad/tag' -OutputDirectory (Join-Path $root 'invalid-tag') }
    Write-Host 'PASS Invalid release tag refused'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
