[CmdletBinding()]
param([string]$BuildDirectory, [string]$BuildId = 'development', [switch]$SkipTests)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $root 'build' }
if ($BuildId -cnotmatch '^[A-Za-z0-9.-]+$') { throw 'Invalid build identifier.' }
& cmake -S $root -B $BuildDirectory -A x64 "-DNONAG_BUILD=$BuildId"
if ($LASTEXITCODE -ne 0) { throw 'Native configuration failed.' }
& cmake --build $BuildDirectory --config Release
if ($LASTEXITCODE -ne 0) { throw 'Native build failed.' }
if (-not $SkipTests) {
    & ctest --test-dir $BuildDirectory -C Release --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw 'Native tests failed.' }
}
$output = Join-Path $root 'bin'
$null = [IO.Directory]::CreateDirectory($output)
$dll = Join-Path $output 'version.dll'
Copy-Item -LiteralPath (Join-Path $BuildDirectory 'bin/Release/version.dll') -Destination $dll -Force
$manifest = @{ Schema=1; Build=$BuildId; Sha256=(Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant() }
[IO.File]::WriteAllText((Join-Path $output 'manifest.json'), ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Write-Output $dll
