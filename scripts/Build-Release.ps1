[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot '..\dist' }
if ($Tag -cne 'development' -and $Tag -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$') {
    throw 'Expected a version tag such as v1.0.0, or development for a local test package.'
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$files = @('Start.cmd', 'src/CLI.ps1', 'src/NoNag.psm1', 'src/known-files.json', 'bin/version.dll', 'bin/manifest.json', 'README.md', 'docs/TECHNICAL.md', 'LICENSE')
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) { throw "Missing release file: $file" }
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
$module = Import-Module (Join-Path $root 'src/NoNag.psm1') -Force -PassThru
$payload = & $module { Read-NoNagPayload }
if ($payload.Build -cne $Tag) { throw 'Build the native DLL with the release tag before packaging.' }
$null = [IO.Directory]::CreateDirectory($output)
$archive = Join-Path $output "ProcessLasso-NoNag-$Tag.zip"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [IO.File]::Open($archive, [IO.FileMode]::CreateNew)
try {
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($file in $files) {
            $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $root $file), "ProcessLasso-NoNag/$file")
        }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    if ($zip.Entries.Count -ne $files.Count) { throw 'Unexpected release file count.' }
    foreach ($file in $files) {
        $entry = $zip.GetEntry("ProcessLasso-NoNag/$file")
        if (-not $entry) { throw "Missing archive entry: $file" }
        $inputStream = $entry.Open()
        $memory = [IO.MemoryStream]::new()
        try {
            $inputStream.CopyTo($memory)
            $actual = [Convert]::ToBase64String($memory.ToArray())
            $expected = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $file)))
            if ($actual -cne $expected) { throw "Archive content mismatch: $file" }
        } finally { $inputStream.Dispose(); $memory.Dispose() }
    }
} finally { $zip.Dispose() }
$checksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($archive) + "`n"
[IO.File]::WriteAllText((Join-Path $output 'SHA256SUMS.txt'),$checksum,[Text.UTF8Encoding]::new($false))
Write-Output $archive
