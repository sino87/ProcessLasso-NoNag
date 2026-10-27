[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AnalysisPath,
    [Parameter(Mandatory=$true)][string]$ExecutablePath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$analysis = [IO.File]::ReadAllText([IO.Path]::GetFullPath($AnalysisPath)) | ConvertFrom-Json
if ($analysis.Status -ne 'candidate' -or $analysis.Profile.VmValidated) { throw 'Expected an unvalidated candidate.' }
$workspace = Join-Path $OutputDirectory ('candidate-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force $workspace
foreach ($name in @('src','tests','scripts','docs')) { $null=New-Item -ItemType Directory (Join-Path $workspace $name) }
foreach ($file in @('Start.cmd','LICENSE','README.md','src/CLI.ps1','src/NoNag.psm1','docs/TECHNICAL.md','scripts/Build-Release.ps1','tests/Test-NoNag.ps1','tests/Test-WorkerExitCodes.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $workspace $file)
}
$readmePath=Join-Path $workspace 'README.md'
$notice = "> Candidate for Process Lasso $($analysis.Profile.Version) x64. VM validation is required before host use.`n`n"
[IO.File]::WriteAllText($readmePath, $notice + [IO.File]::ReadAllText($readmePath), [Text.UTF8Encoding]::new($false))
$profiles = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $root 'src/profiles.json')))
$profiles = @($profiles | Where-Object { $_.OriginalHash -ne $analysis.Profile.OriginalHash }) + @($analysis.Profile)
[IO.File]::WriteAllText((Join-Path $workspace 'src/profiles.json'), (ConvertTo-Json -InputObject @($profiles) -Depth 10), [Text.UTF8Encoding]::new($false))
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workspace 'tests/Test-NoNag.ps1') -FixturePath ([IO.Path]::GetFullPath($ExecutablePath))
if ($LASTEXITCODE -ne 0) { throw 'Candidate transaction tests failed.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workspace 'tests/Test-WorkerExitCodes.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Candidate worker tests failed.' }
$tag = 'v0.0.0-candidate.' + $analysis.Profile.Version + '.' + $analysis.Profile.OriginalHash.Substring(0,12)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workspace 'scripts/Build-Release.ps1') -Tag $tag -OutputDirectory ([IO.Path]::GetFullPath($OutputDirectory))
if ($LASTEXITCODE -ne 0) { throw 'Candidate packaging failed.' }
