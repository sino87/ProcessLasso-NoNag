[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Directory, [string]$Repository=$env:GITHUB_REPOSITORY)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository.' }
$text = & gh api "repos/$Repository/releases?per_page=100" --paginate --slurp
if ($LASTEXITCODE -ne 0) { throw 'Published release unavailable.' }
$pages = ($text -join "`n") | ConvertFrom-Json
$published = @(foreach ($page in $pages) { foreach ($item in $page) { if (-not $item.draft) { $item } } })
$release = $published | Sort-Object { [DateTimeOffset]$_.published_at } -Descending | Select-Object -First 1
if (-not $release) { throw 'Published release unavailable.' }
$tag = $release.tag_name
if ($tag -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$') { throw 'Expected a published versioned release.' }
$name = "ProcessLasso-NoNag-$tag.zip"
$null = [IO.Directory]::CreateDirectory($Directory)
& gh release download $tag --repo $Repository --pattern $name --pattern SHA256SUMS.txt --dir $Directory
if ($LASTEXITCODE -ne 0) { throw 'Published DLL package or checksum unavailable. Publish the first DLL release before enabling scheduled checks.' }
$archive = Join-Path $Directory $name
$checksum = [IO.File]::ReadAllText((Join-Path $Directory 'SHA256SUMS.txt'))
$expected = [regex]::Match($checksum,'(?m)^([a-f0-9]{64})  '+[regex]::Escape($name)+'\r?$')
if (-not $expected.Success -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected.Groups[1].Value) { throw 'Published package checksum mismatch.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $manifestEntry = $zip.GetEntry('ProcessLasso-NoNag/bin/manifest.json')
    $dllEntry = $zip.GetEntry('ProcessLasso-NoNag/bin/version.dll')
    if (-not $manifestEntry -or -not $dllEntry -or $manifestEntry.Length -gt 4096 -or $dllEntry.Length -gt 10485760) { throw 'Published release does not contain the expected DLL payload.' }
    $reader = [IO.StreamReader]::new($manifestEntry.Open())
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($manifest.Schema -ne 1 -or $manifest.Build -cne $tag -or $manifest.Sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid published DLL manifest.' }
    $dll = Join-Path $Directory 'version.dll'
    $inputStream = $dllEntry.Open()
    $outputStream = [IO.File]::Open($dll,[IO.FileMode]::CreateNew)
    try { $inputStream.CopyTo($outputStream) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
    if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.Sha256) { throw 'Published DLL checksum mismatch.' }
    [pscustomobject]@{ Path=$dll; Hash=$manifest.Sha256; Release=$tag }
} finally { $zip.Dispose() }
