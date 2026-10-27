[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$MetadataPath,[Parameter(Mandatory=$true)][string]$InstallerPath,[string]$PythonPath='python')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspace=Join-Path $root ('dist/integration-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Force $workspace
foreach ($name in @('scripts','tests','src','docs')) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $workspace -Recurse }
foreach ($name in @('README.md','LICENSE','Start.cmd')) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $workspace }
$profiles=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'src/profiles.json')))
$baseline=@($profiles | Sort-Object { [version]$_.Version } | Select-Object -First 1)
[IO.File]::WriteAllText((Join-Path $workspace 'src/profiles.json'),(ConvertTo-Json -InputObject $baseline -Depth 10),[Text.UTF8Encoding]::new($false))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workspace 'scripts/Check-Upstream.ps1') -MetadataPath ([IO.Path]::GetFullPath($MetadataPath)) -InstallerPath ([IO.Path]::GetFullPath($InstallerPath)) -PythonPath $PythonPath
if ($LASTEXITCODE -ne 0) { throw 'Integrated upstream analysis failed.' }
$report=[IO.File]::ReadAllText((Join-Path $workspace 'dist/upstream/report.json')) | ConvertFrom-Json
if ($report.Status -ne 'review' -or $report.Analysis.Status -ne 'candidate' -or -not $report.CandidateValidated) { throw 'Expected validated review candidate.' }
Write-Output "Integrated acquisition/analysis/preview gate passed: $workspace"
