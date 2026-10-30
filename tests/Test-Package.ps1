Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root=Join-Path ([IO.Path]::GetTempPath()) ('nonag-package-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $root 'repo'
$releaseDir=Join-Path $root 'release'
$tag='v0.0.0-test'
$mock=[pscustomobject]@{ ReleaseResponse='[[{"tag_name":"v0.0.0-test","draft":false,"prerelease":false,"published_at":"2026-10-29T00:00:00Z"}]]'; DownloadCalls=0 }
function Assert($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Rejected([scriptblock]$Run) { $failed=$false; try { & $Run | Out-Null } catch { $failed=$true }; Assert $failed 'Expected package rejection' }
function gh {
    if ($args[0] -eq 'api') {
        Assert ($args[1] -ceq 'repos/owner/repository/releases?per_page=100' -and $args -contains '--paginate' -and $args -contains '--slurp') 'Expected paginated release listing'
        $global:LASTEXITCODE=0
        return $mock.ReleaseResponse
    }
    if ($args[0] -ne 'release' -or $args[1] -ne 'download') { throw 'Unexpected GitHub command' }
    Assert ($args[2] -ceq $tag) 'Wrong release selected'
    ++$mock.DownloadCalls
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
    $cases=@(
        @{ Name='Newest published prerelease across pages selected over older stable and newer draft'; Json='[[{"tag_name":"v9.0.0","draft":true,"prerelease":false,"published_at":"2099-01-01T00:00:00Z"},{"tag_name":"v1.0.0","draft":false,"prerelease":false,"created_at":"2026-10-30T00:00:00Z","published_at":"2026-10-01T00:00:00Z"}],[{"tag_name":"v0.0.0-test","draft":false,"prerelease":true,"created_at":"2026-09-01T00:00:00Z","published_at":"2026-10-29T00:00:00Z"}]]' },
        @{ Name='Newest stable selected over older prerelease'; Json='[[{"tag_name":"v2.0.0-rc.1","draft":false,"prerelease":true,"published_at":"2026-10-01T00:00:00Z"},{"tag_name":"v0.0.0-test","draft":false,"prerelease":false,"published_at":"2026-10-29T00:00:00Z"}]]' },
        @{ Name='Prerelease-only repository supported'; Json='[[{"tag_name":"v0.0.0-test","draft":false,"prerelease":true,"published_at":"2026-10-29T00:00:00Z"}]]' }
    )
    $caseNumber=0
    foreach ($case in $cases) {
        $mock.ReleaseResponse=$case.Json
        $payload=& (Join-Path $source 'scripts/Get-PublishedDll.ps1') -Directory (Join-Path $root "selection-$caseNumber") -Repository 'owner/repository'
        Assert ($payload.Release -ceq $tag -and $payload.Hash -ceq $manifest.Sha256) 'Wrong selected payload'
        Write-Host "PASS $($case.Name)"
        ++$caseNumber
    }
    foreach ($response in @('[[]]','[[{"tag_name":"v9.0.0","draft":true,"prerelease":true,"published_at":null}]]')) {
        $mock.ReleaseResponse=$response
        $downloadsBefore=$mock.DownloadCalls
        Rejected { & (Join-Path $source 'scripts/Get-PublishedDll.ps1') -Directory (Join-Path $root 'unpublished') -Repository 'owner/repository' }
        Assert ($mock.DownloadCalls -eq $downloadsBefore) 'Unpublished payload downloaded'
        Write-Host 'PASS Repository without published releases refused'
    }
    $mock.ReleaseResponse=$cases[2].Json
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
